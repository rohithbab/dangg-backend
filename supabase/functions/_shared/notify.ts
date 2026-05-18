/**
 * notify() — the single helper used by every Edge Function that needs to
 * drop a row into the in-app notification inbox.
 *
 * BEST-EFFORT BY DESIGN: this function never throws. Callers `await` it but
 * the outer flow is not allowed to fail because a notification didn't make
 * it through. Insert failures are logged via the structured logger.
 *
 * Realtime fan-out happens automatically — `public.notifications` is on
 * the `supabase_realtime` publication, so a single INSERT broadcasts to
 * the recipient's `postgres_changes` subscription.
 *
 * FUTURE: when FCM push delivery lands, the dispatch call goes inside
 * this function. Every existing caller keeps working unchanged — that's
 * the design intent.
 */
import type { SupabaseClient } from '@supabase/supabase-js';
import { logger } from './logger.ts';

export type NotificationType =
  // Chat-request flow
  | 'chat_request_received'
  | 'chat_request_accepted'
  | 'chat_request_declined'
  | 'chat_request_cancelled'
  | 'chat_request_expired'
  | 'chat_request_missed'
  // Payout flow
  | 'payout_requested'
  | 'payout_approved'
  | 'payout_processed' // = completed (re-uses the existing enum slot)
  | 'payout_rejected'
  | 'payout_failed'
  | 'payout_cancelled'
  // Reserved for future prompts
  | 'payment_success'
  | 'payment_failed'
  | 'verification_approved'
  | 'verification_rejected'
  | 'account_suspended'
  | 'system';

export interface NotifyArgs {
  recipientId: string;
  type: NotificationType;
  title: string;
  body: string;
  data?: Record<string, unknown>;
}

/**
 * Create an in-app notification. Never throws.
 *
 * @param svc  Service-role Supabase client (bypasses RLS for the insert).
 * @returns    true on success, false on failure (already logged).
 */
export async function notify(svc: SupabaseClient, args: NotifyArgs): Promise<boolean> {
  const { recipientId, type, title, body, data = {} } = args;

  try {
    const { error } = await svc.from('notifications').insert({
      recipient_id: recipientId,
      type,
      title,
      body,
      data,
    });

    if (error) {
      logger.error('notify: failed to insert notification', {
        recipientId,
        type,
        error: error.message,
      });
      return false;
    }

    logger.info('notify: notification created', { recipientId, type });
    return true;
  } catch (err) {
    logger.error('notify: unexpected error', {
      recipientId,
      type,
      error: err instanceof Error ? err.message : String(err),
    });
    return false;
  }
}

/**
 * Returns a user's display name for use in notification copy. Falls back
 * to 'Someone' if the lookup fails or the row has no name — keeps the
 * notification body sensible without forcing callers to handle nulls.
 */
export async function getUserDisplayName(
  svc: SupabaseClient,
  userId: string,
): Promise<string> {
  try {
    const { data } = await svc
      .from('users')
      .select('name')
      .eq('id', userId)
      .maybeSingle();
    return data?.name ?? 'Someone';
  } catch {
    return 'Someone';
  }
}
