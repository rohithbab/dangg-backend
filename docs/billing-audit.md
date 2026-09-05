# Dangg — Coin Billing & Female Earnings: System Audit

## Intended Business Model

Every **3 seconds** of active chat consumes **1 coin** from the male's balance. The rupee value of those coins is split **40% to the female, 60% to the platform**. Settlement happens entirely at chat end based on actual duration — no flat fees, no upfront escrow.

Base rate reference: **₹9 for 30 coins = 30 paisa per coin.** Since 3 seconds = 1 coin, the per-second cost is 10 paisa. The female's 40% share is **4 paisa per second**.

---

## Active Coin Packages (verified from production DB)

| Package | Coins | Price   | Per-coin value | Female earns/sec | Platform/sec |
|---------|-------|---------|----------------|-----------------|--------------|
| Spark *(base)* | 30 | ₹9 | 30 paisa | 4 paisa | 6 paisa |
| Starter | 70 | ₹19 | 27.1 paisa | 4 paisa | 5.3 paisa |
| Value | 200 | ₹49 | 24.5 paisa | 4 paisa | 4.2 paisa |
| Popular | 450 | ₹99 | 22 paisa | 4 paisa | 3.3 paisa |
| Power | 1000 | ₹199 | 19.9 paisa | 4 paisa | 2.6 paisa |
| Mega | 2800 | ₹499 | 17.8 paisa | 4 paisa | 1.8 paisa |

The female always earns a flat **4 paisa per second** regardless of which package the male used. Bulk packages are a discount to the male only.

---

## Correct Settlement Math (60-second chat, Spark package)

| Step | Calculation | Result |
|------|-------------|--------|
| Male coins spent | `ceil(60 ÷ 3)` = 20 coins | 20 coins |
| Male rupee spend | 20 × 30 paisa | 600 paisa = **₹6.00** |
| Female earning-coins | 1 per second × 60s | 60 earning-coins |
| Female payout | `60 × COIN_VALUE_PAISA(10) × (1 − 60%)` | 240 paisa = **₹2.40** |
| Platform revenue | ₹6.00 − ₹2.40 | **₹3.60** |
| Split check | ₹2.40 ÷ ₹6.00 | **40% female, 60% platform ✓** |

> **Note on `COIN_VALUE_PAISA`:** This parameter is not the price a male pays per purchased coin. It is the value per *earning-coin* (i.e., per second of chat), already adjusted for the 3:1 billing ratio (30 paisa ÷ 3 = 10 paisa). The correct value is **10**. Setting it to 30 triples the payout; setting it to 100 pays out 10× too much.

---

## Findings

### ✅ Correct — Male billing rate

In `chat-sessions-end/index.ts`, the male charge is `Math.ceil(durationSeconds / 3)`. This correctly implements the 3-second = 1 coin rule. The cap against the male's live balance is also correct.

### ✅ Correct — Female earning-coin rate

The female is credited `earnCoins = durationSeconds` — one earning-coin per second. This is architecturally correct *as long as* `COIN_VALUE_PAISA = 10` in the payout formula. The two parameters are coupled: changing one without the other breaks the split.

### ✅ Correct — `female_inr_per_coin()` DB function

The PostgreSQL function `female_inr_per_coin()` returns `0.04` (₹0.04 per earning-coin). This is mathematically correct: `10 paisa × 40% ÷ 100 = ₹0.04`. In-app displays that use this function will show correct amounts once the env is fixed.

### ✅ Correct — Payout formula structure

`_shared/payout-math.ts` implements `floor(coins × COIN_VALUE_PAISA × (1 − commission/100))`. The formula is correct; only the env values fed into it are wrong.

---

### ❌ Bug — `COIN_VALUE_PAISA` is 100, should be 10

| | Value | Effect |
|--|-------|--------|
| **Currently set** | `COIN_VALUE_PAISA=100` | ₹1.00 per earning-coin |
| **Should be** | `COIN_VALUE_PAISA=10` | ₹0.10 per earning-coin (before commission) |

This single misconfiguration inflates female payouts by **10×**.

### ❌ Bug — `PLATFORM_COMMISSION_PCT` is 30, should be 60

The intended split is 40% female / 60% platform. `PLATFORM_COMMISSION_PCT` is the platform's share and must be `60`. The env currently has `30`, giving the female 70% — the inverse of the intended model.

| | Value | Effect |
|--|-------|--------|
| **Currently set** | `PLATFORM_COMMISSION_PCT=30` | Female gets 70% |
| **Should be** | `PLATFORM_COMMISSION_PCT=60` | Female gets 40% |

Combined, the two bugs multiply: payout is 10× inflated **and** the split is inverted → **17.5× overpayment** on every chat.

---

## Financial Impact (live production data)

A female user currently has `earnings_balance_coins = 1040` in the DB. The males whose chats generated those 1040 seconds paid approximately **₹104** in coins.

| Config | Female payout | Platform result |
|--------|--------------|----------------|
| **Current (buggy)** | `1040 × 100 × 0.70 / 100` = **₹728** | Loss of **₹624** |
| **Correct** | `1040 × 10 × 0.40 / 100` = **₹41.60** | Profit of **₹62.40** |

Every minute of chat at current config costs the platform approximately **₹36**.

---

## Fix Required

**No code changes.** The edge function logic, payout formula, and DB function are all correct.

Change two env values in Dokploy → Dangg project → Mobile App Backend → Environment:

```
COIN_VALUE_PAISA=10
PLATFORM_COMMISSION_PCT=60
```

Redeploy the Mobile App Backend service after saving. Do not approve any pending payout requests until the env is updated — recalculate amounts for any pending payouts after the fix.
