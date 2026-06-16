/**
 * POST /functions/v1/stats-male
 *
 * Male dashboard payload. 7 parallel queries, single shaped response.
 *
 * Schema-adapted:
 *   * males.id (NOT user_id) is the PK / FK to users.id.
 *
 * Auth:    JWT (male)
 * Body:    none
 * Returns: { balance, lifetime_purchase, spending, requests,
 *            favorites_count, pending_request, recent_activity }
 */
import { requireAuth, requireRole } from '../_shared/auth.ts';
import { cacheGet, cacheSet } from '../_shared/cache.ts';
import { handlePreflight } from '../_shared/cors.ts';
import { InternalError } from '../_shared/errors.ts';
import { logger } from '../_shared/logger.ts';
import { handler, ok } from '../_shared/responses.ts';
import { serviceClient } from '../_shared/supabase-client.ts';

interface PaymentRow {
  amount_paisa: number;
  coins_to_credit: number;
}
interface CoinTxnRow {
  type: string;
  amount: number;
}
interface RequestRow {
  status: string;
}
interface RecentRow {
  id: string;
  status: string;
  female_id: string;
  chat_cost_coins: number;
  sent_at: string;
  responded_at: string | null;
}

Deno.serve(
  handler(async (req: Request): Promise<Response> => {
    const preflight = handlePreflight(req);
    if (preflight) {
      return preflight;
    }

    const user = await requireAuth(req);
    requireRole(user, 'male');

    // Short-TTL cache: this dashboard runs 7 DB queries and is hit on every
    // home open / pull-to-refresh. 10s absorbs remounts & refresh bursts while
    // keeping balance/pending fresh enough (the client also updates its wallet
    // store immediately after a purchase/charge).
    const cacheKey = `stats:male:${user.id}`;
    const cached = await cacheGet<Record<string, unknown>>(cacheKey);
    if (cached) {
      return ok(cached);
    }

    const svc = serviceClient();

    const [
      maleRow,
      paymentsCaptured,
      coinTxns,
      allRequests,
      favoritesCount,
      pendingRequest,
      recentActivity,
    ] = await Promise.all([
      svc.from('males').select('coin_balance').eq('id', user.id).maybeSingle(),
      svc.from('payments')
        .select('amount_paisa, coins_to_credit')
        .eq('male_id', user.id)
        .eq('status', 'captured'),
      svc.from('coin_transactions')
        .select('type, amount')
        .eq('male_id', user.id)
        .in('type', ['chat_charge', 'chat_refund']),
      svc.from('chat_requests')
        .select('status')
        .eq('male_id', user.id),
      svc.from('favorites')
        .select('male_id', { count: 'exact', head: true })
        .eq('male_id', user.id),
      svc.from('chat_requests')
        .select('id, female_id, chat_cost_coins, expires_at, sent_at')
        .eq('male_id', user.id)
        .eq('status', 'pending')
        .maybeSingle(),
      svc.from('chat_requests')
        .select('id, status, female_id, chat_cost_coins, sent_at, responded_at')
        .eq('male_id', user.id)
        .order('created_at', { ascending: false })
        .limit(10),
    ]);

    if (maleRow.error || !maleRow.data) {
      logger.error('stats-male: male row missing', {
        userId: user.id,
        error: maleRow.error?.message,
      });
      throw new InternalError('Stats unavailable');
    }

    const lifetimePurchasedPaisa = ((paymentsCaptured.data ?? []) as PaymentRow[])
      .reduce((s, p) => s + p.amount_paisa, 0);
    const lifetimePurchasedCoins = ((paymentsCaptured.data ?? []) as PaymentRow[])
      .reduce((s, p) => s + p.coins_to_credit, 0);

    // Charges are negative in the ledger; refunds are positive. Take absolute
    // values for a clean "spent vs refunded" pair.
    const txns = (coinTxns.data ?? []) as CoinTxnRow[];
    const chatChargedCoins = txns
      .filter((t) => t.type === 'chat_charge')
      .reduce((s, t) => s + Math.abs(t.amount), 0);
    const chatRefundedCoins = txns
      .filter((t) => t.type === 'chat_refund')
      .reduce((s, t) => s + t.amount, 0);

    const statusCounts = { pending: 0, accepted: 0, declined: 0, cancelled: 0, expired: 0 };
    for (const r of (allRequests.data ?? []) as RequestRow[]) {
      if (r.status in statusCounts) {
        statusCounts[r.status as keyof typeof statusCounts]++;
      }
    }
    const totalSent = Object.values(statusCounts).reduce((a, b) => a + b, 0);
    const acceptanceRatePct = totalSent > 0
      ? Math.round((statusCounts.accepted / totalSent) * 100)
      : null;

    const payload = {
      balance: {
        coin_balance: maleRow.data.coin_balance,
      },
      lifetime_purchase: {
        total_coins_purchased: lifetimePurchasedCoins,
        total_paisa_paid: lifetimePurchasedPaisa,
      },
      spending: {
        net_chat_spend_coins: chatChargedCoins - chatRefundedCoins,
        chat_charges_coins: chatChargedCoins,
        chat_refunds_coins: chatRefundedCoins,
      },
      requests: {
        total_sent: totalSent,
        total_accepted: statusCounts.accepted,
        total_declined: statusCounts.declined,
        total_cancelled: statusCounts.cancelled,
        total_expired: statusCounts.expired,
        acceptance_rate_pct: acceptanceRatePct,
      },
      favorites_count: favoritesCount.count ?? 0,
      pending_request: pendingRequest.data
        ? {
          id: pendingRequest.data.id,
          female_id: pendingRequest.data.female_id,
          chat_cost_coins: pendingRequest.data.chat_cost_coins,
          sent_at: pendingRequest.data.sent_at,
          expires_at: pendingRequest.data.expires_at,
        }
        : null,
      recent_activity: ((recentActivity.data ?? []) as RecentRow[]).map((r) => ({
        id: r.id,
        status: r.status,
        female_id: r.female_id,
        chat_cost_coins: r.chat_cost_coins,
        sent_at: r.sent_at,
        responded_at: r.responded_at,
      })),
    };
    await cacheSet(cacheKey, payload, 10);
    return ok(payload);
  }),
);
