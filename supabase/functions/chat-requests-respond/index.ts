/**
 * POST /functions/v1/chat-requests-respond
 *
 * Female accepts or declines a pending chat request she received.
 *
 *   accept  → status='accepted'.  Earnings credited to the female.
 *             Male's escrowed coins stay deducted (this IS the spend).
 *   decline → status='declined'.  Male's coins refunded.
 *
 * Concurrency:
 *   The terminal UPDATE carries an `eq.status, 'pending'` guard so a
 *   concurrent expire / cancel cannot collide with us. If 0 rows match
 *   we know the request transitioned out from under us and the ledger
 *   movement we just made is reversed.
 *
 * Auth:    JWT (female)
 * Body:    { chatRequestId: uuid, action: 'accept' | 'decline' }
 * Returns: accept  → { status:'accepted', chatSessionId, earningId,
 *                       newEarningsBalanceCoins }
 *          decline → { status:'declined', refundTransactionId }
 */
import { requireAuth, requireRole } from '../_shared/auth.ts';
import { handlePreflight } from '../_shared/cors.ts';
import {
  ConflictError,
  ForbiddenError,
  InternalError,
  NotFoundError,
  ValidationError,
} from '../_shared/errors.ts';
import { logger } from '../_shared/logger.ts';
import { getUserDisplayName, notify } from '../_shared/notify.ts';
import { handler, ok } from '../_shared/responses.ts';
import { serviceClient } from '../_shared/supabase-client.ts';
import { parseBody, z } from '../_shared/validation.ts';

const Body = z.object({
  chatRequestId: z.string().uuid(),
  action: z.enum(['accept', 'decline']),
});

Deno.serve(
  handler(async (req: Request): Promise<Response> => {
    const preflight = handlePreflight(req);
    if (preflight) {
      return preflight;
    }
    if (req.method !== 'POST') {
      throw new ValidationError('Only POST is accepted');
    }

    // 1. Auth.
    const user = await requireAuth(req);
    requireRole(user, 'female');

    // 2. Input.
    const { chatRequestId, action } = await parseBody(req, Body);

    const svc = serviceClient();

    // 3. Load + ownership + state + expiry checks.
    const { data: cr, error: fetchErr } = await svc
      .from('chat_requests')
      .select(
        'id, male_id, female_id, status, chat_cost_coins, expires_at',
      )
      .eq('id', chatRequestId)
      .maybeSingle();

    if (fetchErr) {
      logger.error('chat-requests-respond: fetch failed', {
        chatRequestId,
        error: fetchErr.message,
      });
      throw new InternalError('Could not load chat request');
    }
    if (!cr) {
      throw new NotFoundError('Chat request not found');
    }
    if (cr.female_id !== user.id) {
      throw new ForbiddenError('This chat request is not addressed to you');
    }
    if (cr.status !== 'pending') {
      throw new ConflictError(
        `Chat request is already '${cr.status}' and cannot be changed`,
      );
    }
    if (new Date(cr.expires_at).getTime() <= Date.now()) {
      // The expiry cron will pick this up on the next minute; refusing here
      // prevents a race where we credit female earnings on an already-stale
      // request that the cron is about to refund.
      throw new ConflictError('This chat request has expired');
    }

    const respondedAt = new Date().toISOString();

    if (action === 'accept') {
      // 4·0. Busy guard — one active chat per female. If she already has a live
      //      session, refuse this accept so she is never double-booked. The
      //      partial unique index chat_sessions_one_active_per_female is the
      //      race-proof backstop; this returns a friendly message first.
      const { data: liveSession, error: liveErr } = await svc
        .from('chat_sessions')
        .select('id')
        .eq('female_id', user.id)
        .eq('status', 'active')
        .limit(1)
        .maybeSingle();
      if (liveErr) {
        logger.error('chat-requests-respond: active-session lookup failed', {
          femaleId: user.id,
          error: liveErr.message,
        });
        throw new InternalError('Could not check availability');
      }
      if (liveSession) {
        throw new ConflictError(
          'You are already in an active chat. End it before accepting another.',
        );
      }

      // Duration-only billing: NOTHING is credited or charged at accept time.
      // The male is charged and the female credited at chat END by actual
      // duration (chat-sessions-end). Here we just open the live session.
      const { data: sessionRow, error: sessionErr } = await svc
        .from('chat_sessions')
        .insert({
          chat_request_id: cr.id,
          male_id: cr.male_id,
          female_id: user.id,
          status: 'active',
          started_at: respondedAt,
        })
        .select('id')
        .single();

      if (sessionErr || !sessionRow) {
        logger.error('chat-requests-respond: session create failed', {
          chatRequestId,
          femaleId: user.id,
          maleId: cr.male_id,
          error: sessionErr?.message,
        });
        throw new InternalError('Failed to start chat session. Please try again.');
      }

      const chatSessionId = sessionRow.id as string;

      // Atomic state flip — eq.status='pending' guards against concurrent
      // decline / cancel / expire. If it loses the race, drop the session.
      const { data: updatedRows, error: updateErr } = await svc
        .from('chat_requests')
        .update({
          status: 'accepted',
          responded_at: respondedAt,
          response_reason: 'Accepted by female',
        })
        .eq('id', cr.id)
        .eq('status', 'pending')
        .select('id');

      if (updateErr || !updatedRows || updatedRows.length === 0) {
        await svc.from('chat_sessions').delete().eq('id', chatSessionId);
        if (updateErr) {
          logger.error('chat-requests-respond: accept update failed', {
            chatRequestId,
            error: updateErr.message,
          });
          throw new InternalError('Failed to finalize acceptance. Please retry.');
        }
        throw new ConflictError(
          'Chat request transitioned to another state before we could accept it.',
        );
      }

      logger.info('Chat request accepted', {
        chatRequestId,
        chatSessionId,
        femaleId: user.id,
        maleId: cr.male_id,
      });

      // Notify the male — best-effort.
      const acceptName = await getUserDisplayName(svc, user.id);
      await notify(svc, {
        recipientId: cr.male_id,
        type: 'chat_request_accepted',
        title: 'Chat request accepted!',
        body: `${acceptName} accepted your chat request`,
        data: {
          chat_request_id: cr.id,
          chat_session_id: chatSessionId,
          from_user_id: user.id,
          from_user_name: acceptName,
        },
      });

      return ok({
        status: 'accepted',
        chatSessionId,
      });
    }

    // action === 'decline' — duration-only billing means nothing was escrowed,
    // so there is no refund. Just flip the request to declined.
    const { data: updatedRows, error: updateErr } = await svc
      .from('chat_requests')
      .update({
        status: 'declined',
        responded_at: respondedAt,
        response_reason: 'Declined by female',
      })
      .eq('id', cr.id)
      .eq('status', 'pending')
      .select('id');

    if (updateErr || !updatedRows || updatedRows.length === 0) {
      if (updateErr) {
        logger.error('chat-requests-respond: decline update failed', {
          chatRequestId,
          error: updateErr.message,
        });
        throw new InternalError('Failed to finalize decline. Please retry.');
      }
      throw new ConflictError(
        'Chat request transitioned to another state before we could decline it.',
      );
    }

    logger.info('Chat request declined', {
      chatRequestId,
      femaleId: user.id,
      maleId: cr.male_id,
    });

    // Notify the male — best-effort.
    const declineName = await getUserDisplayName(svc, user.id);
    await notify(svc, {
      recipientId: cr.male_id,
      type: 'chat_request_declined',
      title: 'Chat request declined',
      body: `${declineName} declined your chat request`,
      data: {
        chat_request_id: cr.id,
        from_user_id: user.id,
        from_user_name: declineName,
      },
    });

    return ok({
      status: 'declined',
    });
  }),
);
