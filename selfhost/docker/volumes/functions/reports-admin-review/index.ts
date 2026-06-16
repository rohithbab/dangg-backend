/**
 * POST /functions/v1/reports-admin-review
 *
 * Admin transitions a submitted/under_review report to a terminal state:
 *
 *   dismissed         — close report, no side effect
 *   warning_issued    — close report, notify('account_warning') to reported
 *   account_suspended — close report, flip users.is_suspended=TRUE, notify
 *
 * Optimistic concurrency: the UPDATE is `eq.status IN ('submitted','under_review')`
 * so two admins racing on the same report can't both succeed.
 *
 * Auth:    JWT (admin)
 * Body:    { reportId, action, adminNotes }
 * Returns: { reportId, status, action, reportedUserSuspended }
 */
import { requireAdmin, requireAuth } from '../_shared/auth.ts';
import { handlePreflight } from '../_shared/cors.ts';
import { ConflictError, InternalError, NotFoundError, ValidationError } from '../_shared/errors.ts';
import { logger } from '../_shared/logger.ts';
import { notify } from '../_shared/notify.ts';
import { handler, ok } from '../_shared/responses.ts';
import { serviceClient } from '../_shared/supabase-client.ts';
import { parseBody, z } from '../_shared/validation.ts';

const Body = z.object({
  reportId: z.string().uuid(),
  action: z.enum(['dismissed', 'warning_issued', 'account_suspended']),
  adminNotes: z.string().trim().min(3).max(2000),
});

interface ReportRow {
  id: string;
  reporter_id: string;
  reported_id: string;
  status: string;
  reason: string;
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

    const { reportId, action, adminNotes } = await parseBody(req, Body);

    const svc = serviceClient();

    const { data: report, error: fetchErr } = await svc
      .from('reports')
      .select('id, reporter_id, reported_id, status, reason')
      .eq('id', reportId)
      .maybeSingle<ReportRow>();

    if (fetchErr) {
      logger.error('reports-admin-review: fetch failed', {
        reportId,
        error: fetchErr.message,
      });
      throw new InternalError('Could not load report');
    }
    if (!report) {
      throw new NotFoundError('Report not found');
    }
    if (report.status !== 'submitted' && report.status !== 'under_review') {
      throw new ConflictError(`Cannot review report in '${report.status}' state.`);
    }

    const reviewedAt = new Date().toISOString();
    const newStatus = action === 'dismissed' ? 'dismissed' : 'action_taken';
    const adminActionEnum = action === 'dismissed' ? 'none' : action;

    // Optimistic concurrency: the UPDATE guards the prior status.
    const { data: updated, error: updateErr } = await svc
      .from('reports')
      .update({
        status: newStatus,
        admin_id: user.id,
        admin_action: adminActionEnum,
        admin_notes: adminNotes,
        reviewed_at: reviewedAt,
      })
      .eq('id', reportId)
      .in('status', ['submitted', 'under_review'])
      .select('id');

    if (updateErr) {
      logger.error('reports-admin-review: update failed', {
        reportId,
        adminId: user.id,
        error: updateErr.message,
      });
      throw new InternalError('Failed to update report. Please try again.');
    }
    if (!updated || updated.length === 0) {
      throw new ConflictError(
        'Report transitioned to another state before we could review it.',
      );
    }

    // Apply side effects. Notifications are best-effort; suspension is not.
    let reportedUserSuspended = false;

    if (action === 'account_suspended') {
      const { error: suspendErr } = await svc
        .from('users')
        .update({ is_suspended: true })
        .eq('id', report.reported_id);

      if (suspendErr) {
        // The report row is already in action_taken state. Surface the
        // partial-failure rather than silently leaving the user un-suspended.
        logger.error('reports-admin-review: suspend failed AFTER report close', {
          reportId,
          reportedUserId: report.reported_id,
          error: suspendErr.message,
        });
        throw new InternalError(
          'Report closed but user suspension failed. Retry the suspension manually.',
        );
      }
      reportedUserSuspended = true;

      await notify(svc, {
        recipientId: report.reported_id,
        type: 'account_suspended',
        title: 'Account suspended',
        body: `Your account has been suspended. Reason: ${adminNotes}`,
        data: { report_id: reportId, admin_notes: adminNotes },
      });
    } else if (action === 'warning_issued') {
      await notify(svc, {
        recipientId: report.reported_id,
        type: 'account_warning',
        title: 'Account warning',
        body: adminNotes,
        data: { report_id: reportId, admin_notes: adminNotes },
      });
    }
    // dismissed → no notification.

    logger.info('Report reviewed', {
      reportId,
      adminId: user.id,
      action,
      reportedUserSuspended,
    });

    return ok({
      reportId,
      status: newStatus,
      action: adminActionEnum,
      reportedUserSuspended,
    });
  }),
);
