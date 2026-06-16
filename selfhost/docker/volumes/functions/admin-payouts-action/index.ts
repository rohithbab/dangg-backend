/**
 * POST /functions/v1/admin-payouts-action
 *
 * Consolidated admin transition endpoint. The `action` field selects which
 * state-machine arrow to traverse:
 *
 *   approve  : pending  → approved   (no money movement — admin will pay manually)
 *   reject   : pending  → rejected   (refund — requires rejectionReason)
 *   complete : approved → completed  (no refund; admin paid manually — requires utrNumber)
 *   fail     : approved → failed     (refund — requires failureReason)
 *
 * All terminal UPDATEs carry `eq.status, '<expected>'` for optimistic
 * concurrency. If a refund happens before the UPDATE and the UPDATE then
 * loses the race, the refund is reversed via admin_adjustment.
 *
 * Auth:    JWT (admin)
 * Body:    { payoutId, action, utrNumber?, rejectionReason?, failureReason?, adminNotes? }
 * Returns: shape depends on action.
 */
import type { SupabaseClient } from '@supabase/supabase-js';
import { requireAdmin, requireAuth } from '../_shared/auth.ts';
import { handlePreflight } from '../_shared/cors.ts';
import { ConflictError, InternalError, NotFoundError, ValidationError } from '../_shared/errors.ts';
import { logger } from '../_shared/logger.ts';
import { notify } from '../_shared/notify.ts';
import { formatPaisa } from '../_shared/payout-math.ts';
import { handler, ok } from '../_shared/responses.ts';
import { serviceClient } from '../_shared/supabase-client.ts';
import { parseBody, z } from '../_shared/validation.ts';

const Body = z.object({
  payoutId: z.string().uuid(),
  action: z.enum(['approve', 'reject', 'complete', 'fail']),
  utrNumber: z.string().trim().min(1).max(50).optional(),
  rejectionReason: z.string().trim().min(1).max(500).optional(),
  failureReason: z.string().trim().min(1).max(500).optional(),
  adminNotes: z.string().trim().max(1000).optional(),
});

interface PayoutRow {
  id: string;
  female_id: string;
  status: string;
  coins_requested: number;
  payout_amount_paisa: number;
}

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
    requireAdmin(user);

    const body = await parseBody(req, Body);
    const svc = serviceClient();

    const { data: payout, error: fetchErr } = await svc
      .from('payouts')
      .select('id, female_id, status, coins_requested, payout_amount_paisa')
      .eq('id', body.payoutId)
      .maybeSingle<PayoutRow>();

    if (fetchErr) {
      logger.error('admin-payouts-action: fetch failed', {
        payoutId: body.payoutId,
        error: fetchErr.message,
      });
      throw new InternalError('Could not load payout');
    }
    if (!payout) {
      throw new NotFoundError('Payout not found');
    }

    const now = new Date().toISOString();

    switch (body.action) {
      case 'approve':
        return await handleApprove(svc, user.id, payout, body.adminNotes, now);
      case 'reject':
        if (!body.rejectionReason) {
          throw new ValidationError('rejectionReason is required for reject');
        }
        return await handleReject(
          svc,
          user.id,
          payout,
          body.rejectionReason,
          body.adminNotes,
          now,
        );
      case 'complete':
        if (!body.utrNumber) {
          throw new ValidationError('utrNumber is required for complete');
        }
        return await handleComplete(
          svc,
          user.id,
          payout,
          body.utrNumber,
          body.adminNotes,
          now,
        );
      case 'fail':
        if (!body.failureReason) {
          throw new ValidationError('failureReason is required for fail');
        }
        return await handleFail(
          svc,
          user.id,
          payout,
          body.failureReason,
          body.adminNotes,
          now,
        );
    }
  }),
);

// ---------------------------------------------------------------------------
// Per-action handlers
// ---------------------------------------------------------------------------

async function handleApprove(
  svc: SupabaseClient,
  adminId: string,
  p: PayoutRow,
  notes: string | undefined,
  now: string,
) {
  if (p.status !== 'pending') {
    throw new ConflictError(`Cannot approve: payout is in '${p.status}' state`);
  }

  const { data: updated, error: updateErr } = await svc
    .from('payouts')
    .update({
      status: 'approved',
      approved_at: now,
      approved_by: adminId,
      admin_notes: notes ?? null,
    })
    .eq('id', p.id)
    .eq('status', 'pending')
    .select('id');

  if (updateErr || !updated || updated.length === 0) {
    if (updateErr) {
      logger.error('admin-payouts-action: approve update failed', {
        payoutId: p.id,
        error: updateErr.message,
      });
      throw new InternalError('Failed to approve payout');
    }
    throw new ConflictError(
      'Payout transitioned away from pending before we could approve.',
    );
  }

  await notify(svc, {
    recipientId: p.female_id,
    type: 'payout_approved',
    title: 'Payout approved',
    body: `Your payout of ${
      formatPaisa(p.payout_amount_paisa)
    } has been approved and is being processed.`,
    data: { payout_id: p.id },
  });

  logger.info('Payout approved', { payoutId: p.id, adminId });
  return ok({ status: 'approved', payoutId: p.id });
}

async function handleReject(
  svc: SupabaseClient,
  adminId: string,
  p: PayoutRow,
  reason: string,
  notes: string | undefined,
  now: string,
) {
  if (p.status !== 'pending') {
    throw new ConflictError(`Cannot reject: payout is in '${p.status}' state`);
  }

  // 1. Refund the escrow.
  const { data: refundRows, error: refundErr } = await svc.rpc(
    'credit_female_earnings',
    {
      p_female_id: p.female_id,
      p_amount: p.coins_requested,
      p_type: 'payout_failed_reversal',
      p_reference_id: p.id,
      p_description: `Payout rejected by admin: ${reason}`,
    },
  );

  if (refundErr || !refundRows || refundRows.length === 0) {
    logger.error('admin-payouts-action: reject refund failed', {
      payoutId: p.id,
      error: refundErr?.message,
    });
    throw new InternalError('Failed to process rejection');
  }
  const refundEarningId = refundRows[0].earning_id;

  // 2. Flip status.
  const { data: updated, error: updateErr } = await svc
    .from('payouts')
    .update({
      status: 'rejected',
      rejected_at: now,
      rejected_by: adminId,
      rejection_reason: reason,
      refund_earning_id: refundEarningId,
      admin_notes: notes ?? null,
    })
    .eq('id', p.id)
    .eq('status', 'pending')
    .select('id');

  if (updateErr || !updated || updated.length === 0) {
    // Reverse the refund — the row moved on without us.
    const { error: reverseErr } = await svc.rpc('credit_female_earnings', {
      p_female_id: p.female_id,
      p_amount: -p.coins_requested,
      p_type: 'admin_adjustment',
      p_reference_id: p.id,
      p_description: 'Reversed: reject lost race against another transition',
    });
    if (reverseErr) {
      logger.error('admin-payouts-action: reject refund reversal FAILED', {
        payoutId: p.id,
        refundEarningId,
        error: reverseErr.message,
      });
    }
    if (updateErr) {
      throw new InternalError('Failed to finalize rejection');
    }
    throw new ConflictError(
      'Payout transitioned away from pending before reject finalised.',
    );
  }

  await notify(svc, {
    recipientId: p.female_id,
    type: 'payout_rejected',
    title: 'Payout rejected',
    body: `Your payout of ${formatPaisa(p.payout_amount_paisa)} was rejected. ` +
      `Reason: ${reason}. Coins refunded to your balance.`,
    data: {
      payout_id: p.id,
      rejection_reason: reason,
      refunded_coins: p.coins_requested,
    },
  });

  logger.info('Payout rejected', { payoutId: p.id, adminId });
  return ok({ status: 'rejected', refundedCoins: p.coins_requested });
}

async function handleComplete(
  svc: SupabaseClient,
  adminId: string,
  p: PayoutRow,
  utr: string,
  notes: string | undefined,
  now: string,
) {
  if (p.status !== 'approved') {
    throw new ConflictError(
      `Cannot complete: payout is in '${p.status}' state. Must be 'approved'.`,
    );
  }

  const { data: updated, error: updateErr } = await svc
    .from('payouts')
    .update({
      status: 'completed',
      completed_at: now,
      completed_by: adminId,
      utr_number: utr,
      admin_notes: notes ?? null,
    })
    .eq('id', p.id)
    .eq('status', 'approved')
    .select('id');

  if (updateErr || !updated || updated.length === 0) {
    if (updateErr) {
      logger.error('admin-payouts-action: complete update failed', {
        payoutId: p.id,
        error: updateErr.message,
      });
      throw new InternalError('Failed to mark as completed');
    }
    throw new ConflictError(
      'Payout transitioned away from approved before complete finalised.',
    );
  }

  await notify(svc, {
    recipientId: p.female_id,
    // Re-use the existing 'payout_processed' enum slot — semantically the
    // same as the prompt's 'payout_completed'. Keeps the enum lean.
    type: 'payout_processed',
    title: 'Payout completed!',
    body: `Your payout of ${formatPaisa(p.payout_amount_paisa)} has been sent. UTR: ${utr}`,
    data: {
      payout_id: p.id,
      utr_number: utr,
      amount_paisa: p.payout_amount_paisa,
    },
  });

  logger.info('Payout completed', { payoutId: p.id, adminId, utr });
  return ok({ status: 'completed', utrNumber: utr });
}

async function handleFail(
  svc: SupabaseClient,
  adminId: string,
  p: PayoutRow,
  reason: string,
  notes: string | undefined,
  now: string,
) {
  if (p.status !== 'approved') {
    throw new ConflictError(
      `Cannot mark as failed: payout is in '${p.status}' state. Must be 'approved'.`,
    );
  }

  const { data: refundRows, error: refundErr } = await svc.rpc(
    'credit_female_earnings',
    {
      p_female_id: p.female_id,
      p_amount: p.coins_requested,
      p_type: 'payout_failed_reversal',
      p_reference_id: p.id,
      p_description: `Payout failed: ${reason}`,
    },
  );

  if (refundErr || !refundRows || refundRows.length === 0) {
    logger.error('admin-payouts-action: fail refund failed', {
      payoutId: p.id,
      error: refundErr?.message,
    });
    throw new InternalError('Failed to process failure');
  }
  const refundEarningId = refundRows[0].earning_id;

  const { data: updated, error: updateErr } = await svc
    .from('payouts')
    .update({
      status: 'failed',
      failed_at: now,
      failed_by: adminId,
      failure_reason: reason,
      refund_earning_id: refundEarningId,
      admin_notes: notes ?? null,
    })
    .eq('id', p.id)
    .eq('status', 'approved')
    .select('id');

  if (updateErr || !updated || updated.length === 0) {
    const { error: reverseErr } = await svc.rpc('credit_female_earnings', {
      p_female_id: p.female_id,
      p_amount: -p.coins_requested,
      p_type: 'admin_adjustment',
      p_reference_id: p.id,
      p_description: 'Reversed: fail lost race against another transition',
    });
    if (reverseErr) {
      logger.error('admin-payouts-action: fail refund reversal FAILED', {
        payoutId: p.id,
        refundEarningId,
        error: reverseErr.message,
      });
    }
    if (updateErr) {
      throw new InternalError('Failed to finalize failure');
    }
    throw new ConflictError(
      'Payout transitioned away from approved before fail finalised.',
    );
  }

  await notify(svc, {
    recipientId: p.female_id,
    type: 'payout_failed',
    title: 'Payout failed',
    body: `Your payout attempt failed. Reason: ${reason}. Coins refunded to your balance.`,
    data: {
      payout_id: p.id,
      failure_reason: reason,
      refunded_coins: p.coins_requested,
    },
  });

  logger.info('Payout failed', { payoutId: p.id, adminId, reason });
  return ok({ status: 'failed', refundedCoins: p.coins_requested });
}
