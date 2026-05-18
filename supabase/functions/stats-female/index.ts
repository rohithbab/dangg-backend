/**
 * POST /functions/v1/stats-female
 *
 * Female dashboard payload. Runs 7 parallel queries against indexes from
 * Prompts D/F/G and returns one shaped JSON object the mobile app renders
 * directly.
 *
 * Schema-adapted from the prompt template:
 *   * females.id (NOT user_id) is the PK / FK to users.id.
 *   * females.coin_price (NOT chat_cost).
 *   * females.average_response_minutes (NOT response_time_avg).
 *   * females.last_online_at (NOT last_seen_at).
 *
 * Auth:    JWT (female)
 * Body:    none — POST with empty body.
 * Returns: { balance, earnings, requests, profile, recent_activity }
 */
import { requireAuth, requireRole } from '../_shared/auth.ts';
import { handlePreflight } from '../_shared/cors.ts';
import { InternalError } from '../_shared/errors.ts';
import { logger } from '../_shared/logger.ts';
import { handler, ok } from '../_shared/responses.ts';
import { serviceClient } from '../_shared/supabase-client.ts';

// Net-payout preview using the current default rates. Authoritative payout
// math lives in _shared/payout-math.ts; this preview is for the dashboard
// only and intentionally tracks the same defaults to avoid surprising the
// female with a different number when she opens the payout sheet.
const COIN_VALUE_PAISA = 100;
const PLATFORM_COMMISSION_PCT = 30;

function startOfMonthUtc(): string {
  const d = new Date();
  d.setUTCDate(1);
  d.setUTCHours(0, 0, 0, 0);
  return d.toISOString();
}
function startOfWeekUtc(): string {
  const d = new Date();
  d.setUTCDate(d.getUTCDate() - d.getUTCDay()); // Sunday = 0
  d.setUTCHours(0, 0, 0, 0);
  return d.toISOString();
}

interface EarningRow {
  amount_coins: number;
}
interface RequestRow {
  status: string;
}
interface RecentRow {
  id: string;
  status: string;
  chat_cost_coins: number;
  sent_at: string;
  responded_at: string | null;
  male_id: string;
}

Deno.serve(
  handler(async (req: Request): Promise<Response> => {
    const preflight = handlePreflight(req);
    if (preflight) {
      return preflight;
    }

    const user = await requireAuth(req);
    requireRole(user, 'female');

    const svc = serviceClient();
    const monthStart = startOfMonthUtc();
    const weekStart = startOfWeekUtc();

    const [
      femaleRow,
      allRequests,
      monthEarnings,
      weekEarnings,
      lifetimeEarnings,
      pendingRequestsCount,
      recentActivity,
    ] = await Promise.all([
      svc.from('females')
        .select(
          'earnings_balance_coins, is_online, rating_avg, average_response_minutes, total_chats, coin_price',
        )
        .eq('id', user.id)
        .maybeSingle(),
      svc.from('chat_requests')
        .select('status')
        .eq('female_id', user.id),
      svc.from('female_earnings')
        .select('amount_coins')
        .eq('female_id', user.id)
        .eq('type', 'chat_earning')
        .gte('created_at', monthStart),
      svc.from('female_earnings')
        .select('amount_coins')
        .eq('female_id', user.id)
        .eq('type', 'chat_earning')
        .gte('created_at', weekStart),
      svc.from('female_earnings')
        .select('amount_coins')
        .eq('female_id', user.id)
        .eq('type', 'chat_earning'),
      svc.from('chat_requests')
        .select('id', { count: 'exact', head: true })
        .eq('female_id', user.id)
        .eq('status', 'pending'),
      svc.from('chat_requests')
        .select('id, status, chat_cost_coins, sent_at, responded_at, male_id')
        .eq('female_id', user.id)
        .order('created_at', { ascending: false })
        .limit(10),
    ]);

    if (femaleRow.error || !femaleRow.data) {
      logger.error('stats-female: female row missing', {
        userId: user.id,
        error: femaleRow.error?.message,
      });
      throw new InternalError('Stats unavailable');
    }

    const statusCounts = { pending: 0, accepted: 0, declined: 0, cancelled: 0, expired: 0 };
    for (const r of (allRequests.data ?? []) as RequestRow[]) {
      if (r.status in statusCounts) {
        statusCounts[r.status as keyof typeof statusCounts]++;
      }
    }

    const totalReceived = Object.values(statusCounts).reduce((a, b) => a + b, 0);
    const totalMissed = statusCounts.expired + statusCounts.cancelled;
    const acceptanceRatePct = totalReceived > 0
      ? Math.round((statusCounts.accepted / totalReceived) * 100)
      : null;

    const sumCoins = (rows: EarningRow[] | null) =>
      (rows ?? []).reduce((s, r) => s + r.amount_coins, 0);

    const lifetimeCoins = sumCoins(lifetimeEarnings.data as EarningRow[] | null);
    const monthCoins = sumCoins(monthEarnings.data as EarningRow[] | null);
    const weekCoins = sumCoins(weekEarnings.data as EarningRow[] | null);

    const previewPaisa = (coins: number) =>
      Math.floor(coins * COIN_VALUE_PAISA * (1 - PLATFORM_COMMISSION_PCT / 100));

    return ok({
      balance: {
        earnings_balance_coins: femaleRow.data.earnings_balance_coins,
        earnings_balance_paisa_preview: previewPaisa(femaleRow.data.earnings_balance_coins),
      },
      earnings: {
        lifetime_coins: lifetimeCoins,
        lifetime_paisa_preview: previewPaisa(lifetimeCoins),
        this_month_coins: monthCoins,
        this_week_coins: weekCoins,
      },
      requests: {
        total_received: totalReceived,
        total_accepted: statusCounts.accepted,
        total_declined: statusCounts.declined,
        total_missed: totalMissed,
        pending_count: pendingRequestsCount.count ?? 0,
        acceptance_rate_pct: acceptanceRatePct,
      },
      profile: {
        is_online: femaleRow.data.is_online,
        coin_price: femaleRow.data.coin_price,
        rating_avg: femaleRow.data.rating_avg,
        average_response_minutes: femaleRow.data.average_response_minutes,
        total_chats: femaleRow.data.total_chats,
      },
      recent_activity: ((recentActivity.data ?? []) as RecentRow[]).map((r) => ({
        id: r.id,
        status: r.status,
        chat_cost_coins: r.chat_cost_coins,
        sent_at: r.sent_at,
        responded_at: r.responded_at,
        male_id: r.male_id,
      })),
    });
  }),
);
