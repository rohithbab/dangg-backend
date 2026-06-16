/**
 * POST /functions/v1/reports-submit
 *
 * Submit a report against another user. Anyone may report anyone; the
 * reporter sees the report in their own list (RLS) but the reported user
 * never sees reports against them.
 *
 * Anti-spam: at most 5 reports per reporter per rolling 24h.
 *
 * Auth:    JWT (any end-user)
 * Body:    { reportedUserId, reason, description?, contextChatRequestId? }
 * Returns: { reportId, status:'submitted' }
 */
import { requireAuth } from '../_shared/auth.ts';
import { handlePreflight } from '../_shared/cors.ts';
import { ConflictError, InternalError, NotFoundError, ValidationError } from '../_shared/errors.ts';
import { logger } from '../_shared/logger.ts';
import { handler, ok } from '../_shared/responses.ts';
import { serviceClient } from '../_shared/supabase-client.ts';
import { parseBody, z } from '../_shared/validation.ts';

const REASONS = [
  'harassment',
  'inappropriate_content',
  'fake_profile',
  'fraud_scam',
  'spam',
  'underage',
  'other',
] as const;

const Body = z.object({
  reportedUserId: z.string().uuid(),
  reason: z.enum(REASONS),
  description: z.string().trim().min(1).max(2000).optional(),
  contextChatRequestId: z.string().uuid().optional(),
});

const MAX_REPORTS_PER_24H = 5;

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
    const { reportedUserId, reason, description, contextChatRequestId } = await parseBody(
      req,
      Body,
    );

    if (user.id === reportedUserId) {
      throw new ValidationError('Cannot report yourself');
    }

    const svc = serviceClient();

    // Reported user must exist.
    const { data: reported, error: lookupErr } = await svc
      .from('users')
      .select('id')
      .eq('id', reportedUserId)
      .maybeSingle();

    if (lookupErr) {
      logger.error('reports-submit: lookup failed', {
        reporterId: user.id,
        reportedUserId,
        error: lookupErr.message,
      });
      throw new InternalError('Could not look up reported user');
    }
    if (!reported) {
      throw new NotFoundError('Reported user not found');
    }

    // Anti-spam — rolling 24h window per reporter.
    const since = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
    const { count: recent, error: countErr } = await svc
      .from('reports')
      .select('id', { count: 'exact', head: true })
      .eq('reporter_id', user.id)
      .gte('created_at', since);

    if (countErr) {
      logger.error('reports-submit: rate-limit count failed', {
        reporterId: user.id,
        error: countErr.message,
      });
      throw new InternalError('Could not check rate limit');
    }
    if ((recent ?? 0) >= MAX_REPORTS_PER_24H) {
      throw new ConflictError(
        `You have submitted too many reports in the last 24 hours (limit ${MAX_REPORTS_PER_24H}). Try again later.`,
      );
    }

    const { data: report, error: insertErr } = await svc
      .from('reports')
      .insert({
        reporter_id: user.id,
        reported_id: reportedUserId,
        reason,
        description: description ?? null,
        context_chat_request_id: contextChatRequestId ?? null,
        status: 'submitted',
      })
      .select('id')
      .single();

    if (insertErr || !report) {
      logger.error('reports-submit: insert failed', {
        reporterId: user.id,
        reportedUserId,
        error: insertErr?.message,
      });
      throw new InternalError('Failed to submit report. Please try again.');
    }

    logger.info('Report submitted', {
      reportId: report.id,
      reporterId: user.id,
      reportedId: reportedUserId,
      reason,
    });

    return ok({ reportId: report.id, status: 'submitted' });
  }),
);
