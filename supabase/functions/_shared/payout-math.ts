/**
 * Payout calculation helpers.
 *
 * All amounts in PAISA (1 INR = 100 paisa). Integer-only — never float
 * money around. The single conversion formula lives in calculatePayoutPaisa
 * and is mirrored verbatim into the payouts table comment / README so the
 * three sources of truth (code, schema doc, README) can't diverge silently.
 *
 * Rates are read from env at call time so changing them is a config-only
 * change with no code deploy. Each payout snapshots the values it used at
 * request time — see `payouts.coin_value_paisa_snapshot` +
 * `payouts.commission_pct_snapshot`.
 */

const COIN_VALUE_PAISA_DEFAULT = 22; // 1 coin = ₹0.22 (₹99 pack ÷ 450 coins)
const PLATFORM_COMMISSION_PCT_DEFAULT = 60; // platform keeps 60%, female nets 40%
const MIN_PAYOUT_COINS_DEFAULT = 100; // floor on a single payout request
const PAYOUT_PROCESSING_DAYS_DEFAULT = 3; // display only

export interface PayoutRates {
  coinValuePaisa: number;
  commissionPct: number;
  minPayoutCoins: number;
  processingDays: number;
}

/**
 * Resolve the current payout rates. Each call re-reads the environment so
 * a runtime change (e.g. a config push) is picked up by the next request
 * without redeploying the function.
 */
export function getPayoutRates(): PayoutRates {
  return {
    coinValuePaisa: parsePositiveInt(Deno.env.get('COIN_VALUE_PAISA'), COIN_VALUE_PAISA_DEFAULT),
    commissionPct: parsePercent(
      Deno.env.get('PLATFORM_COMMISSION_PCT'),
      PLATFORM_COMMISSION_PCT_DEFAULT,
    ),
    minPayoutCoins: parsePositiveInt(Deno.env.get('MIN_PAYOUT_COINS'), MIN_PAYOUT_COINS_DEFAULT),
    processingDays: parsePositiveInt(
      Deno.env.get('PAYOUT_PROCESSING_DAYS'),
      PAYOUT_PROCESSING_DAYS_DEFAULT,
    ),
  };
}

/**
 * Net INR payable in paisa.
 *
 *   gross_paisa      = coins × coin_value_paisa
 *   commission_paisa = gross_paisa × (commission_pct / 100)
 *   net_paisa        = floor(gross_paisa - commission_paisa)
 *
 * Floored so the platform never accidentally over-pays by a sub-paisa
 * rounding artefact. The platform's share absorbs any rounding remainder.
 */
export function calculatePayoutPaisa(
  coins: number,
  coinValuePaisa: number,
  commissionPct: number,
): number {
  const grossPaisa = coins * coinValuePaisa;
  const commissionPaisa = grossPaisa * (commissionPct / 100);
  return Math.floor(grossPaisa - commissionPaisa);
}

/**
 * Format paisa as a human-readable INR string for notification copy.
 *   7000 → "₹70.00"   35000 → "₹350.00"   100000 → "₹1,000.00"
 */
export function formatPaisa(paisa: number): string {
  const rupees = paisa / 100;
  return `₹${
    rupees.toLocaleString('en-IN', {
      minimumFractionDigits: 2,
      maximumFractionDigits: 2,
    })
  }`;
}

function parsePositiveInt(raw: string | undefined, fallback: number): number {
  const n = raw == null ? NaN : parseInt(raw, 10);
  return Number.isFinite(n) && n > 0 ? n : fallback;
}

function parsePercent(raw: string | undefined, fallback: number): number {
  const n = raw == null ? NaN : parseFloat(raw);
  return Number.isFinite(n) && n >= 0 && n < 100 ? n : fallback;
}
