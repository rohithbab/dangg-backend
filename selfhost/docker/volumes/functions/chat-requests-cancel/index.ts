/**
 * POST /functions/v1/chat-requests-cancel
 *
 * Male cancels a pending chat request they sent (before the female has
 * responded). Coins are refunded immediately.
 *
 * Auth:    JWT (male)
 * Body:    { chatRequestId: uuid }
 * Returns: { status:'cancelled', refundTransactionId, newCoinBalance }
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

    const user = await requireAuth(req);
    requireRole(user, 'male');

    const { chatRequestId } = await parseBody(req, Body);

    const svc = serviceClient();

    const { data: cr, error: fetchErr } = await svc
      .from('chat_requests')
      .select('id, male_id, female_id, status, chat_cost_coins')
      .eq('id', chatRequestId)
      .maybeSingle();

    if (fetchErr) {
      logger.error('chat-requests-cancel: fetch failed', {
        chatRequestId,
        error: fetchErr.message,
      });
      throw new InternalError('Could not load chat request');
    }
    if (!cr) {
      throw new NotFoundError('Chat request not found');
    }
    if (cr.male_id !== user.id) {
      throw new ForbiddenError('This chat request is not yours to cancel');
    }
    if (cr.status !== 'pending') {
      throw new ConflictError(
        `Chat request is already '${cr.status}' and cannot be cancelled`,
      );
    }

    // Duration-only billing: nothing was escrowed on send, so cancelling has
    // no refund. Just flip the request to cancelled.
    const { data: updatedRows, error: updateErr } = await svc
      .from('chat_requests')
      .update({
        status: 'cancelled',
        responded_at: new Date().toISOString(),
        response_reason: 'Cancelled by male',
      })
      .eq('id', cr.id)
      .eq('status', 'pending')
      .select('id');

    if (updateErr || !updatedRows || updatedRows.length === 0) {
      if (updateErr) {
        logger.error('chat-requests-cancel: state update failed', {
          chatRequestId,
          error: updateErr.message,
        });
        throw new InternalError('Failed to finalize cancel. Please retry.');
      }
      throw new ConflictError(
        'Chat request transitioned to another state before we could cancel it.',
      );
    }

    logger.info('Chat request cancelled', {
      chatRequestId,
      maleId: user.id,
    });

    // Notify the female that the male pulled the request — best-effort.
    const cancelName = await getUserDisplayName(svc, user.id);
    await notify(svc, {
      recipientId: cr.female_id,
      type: 'chat_request_cancelled',
      title: 'Chat request cancelled',
      body: `${cancelName} cancelled their chat request`,
      data: {
        chat_request_id: cr.id,
        from_user_id: user.id,
        from_user_name: cancelName,
      },
    });

    return ok({
      status: 'cancelled',
    });
  }),
);
