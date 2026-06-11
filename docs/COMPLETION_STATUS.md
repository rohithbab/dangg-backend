# Dangg Backend — API Completion Status

**Last updated:** 2026-05-28  
**Source:** `DANGG_BACKEND_API_INVENTORY.md` + git history + deployed Edge Functions  
**Phase:** Phase 1 (active chat deferred to Phase 2)

---

## Summary

| Category | Done | Total | % |
|---|---:|---:|---:|
| **1. Authentication** | 2 | 7 | 29% |
| **2. User Profile** | 3 | 5 | 60% |
| **3. Female-Specific** | 10 | 13 | 77% |
| **4. Male-Specific** | 6 | 8 | 75% |
| **5. Browse Females** | 2 | 3 | 67% |
| **6. Coin Packages & Payments** | 5 | 5 | 100% ✅ |
| **7. Chat Requests** | 6 | 8 | 75% |
| **8. Chat Session (Phase 2)** | 0 | 5 | 0% |
| **9. Notifications** | 4 | 7 | 57% |
| **10. Block & Report** | 4 | 4 | 100% ✅ |
| **11. Support** | 0 | 2 | 0% |
| **12. App Configuration** | 1 | 2 | 50% |
| **13. Cloudinary Signed Uploads** | 1 | 1 | 100% ✅ |
| **14. DPDP Compliance** | 0 | 3 | 0% |
| **15. Admin Dashboard** | 5 | 17 | 29% |
| **16. Internal / Cron** | 4 | 7 | 57% |
| **17. Real-time Channels** | 3 | 4 | 75% |
| **TOTAL** | **57** | **96** | **59%** |

---

## Detailed Checklist

### 1. Authentication

| # | Endpoint | Method | Type | Status | Note |
|---|---|---|---|---|---|
| 1.1 | `/auth/v1/otp` | POST | SUPABASE SDK | ✅ | Built-in (via send-sms-hook) |
| 1.2 | `/auth/v1/verify` | POST | SUPABASE SDK | ✅ | Built-in |
| 1.3 | `/auth/v1/token` (refresh) | POST | SUPABASE SDK | ✅ | Built-in |
| 1.4 | `/auth/v1/logout` | POST | SUPABASE SDK | ✅ | Built-in |
| 1.5 | `/auth/v1/recover` | POST | SUPABASE SDK | ❌ | Not prioritized |
| 1.6 | `/functions/v1/send-sms-hook` | POST | WEBHOOK | ✅ | Deployed |
| 1.7 | `/functions/v1/delete-account` | POST | CUSTOM EF | ❌ | DPDP compliance, deferred |

---

### 2. User Profile (Shared)

| # | Endpoint | Method | Type | Status | Note |
|---|---|---|---|---|---|
| 2.1 | `/rest/v1/users` (get self) | GET | SUPABASE SDK | ✅ | RLS enforces self-only |
| 2.2 | `/rest/v1/users` (update) | PATCH | SUPABASE SDK | ✅ | RLS enforces self-only |
| 2.3 | `/functions/v1/profile-picture-upload` | POST | CUSTOM EF | ✅ | Deployed |
| 2.4 | `/functions/v1/profile-picture-confirm` | POST | CUSTOM EF | ✅ | Deployed |
| 2.5 | `/functions/v1/profile-picture` (delete) | DELETE | CUSTOM EF | ✅ | Deployed |

---

### 3. Female-Specific

| # | Endpoint | Method | Type | Status | Note |
|---|---|---|---|---|---|
| **3.1 Verification** |
| 3.1.1 | `/rest/v1/females` (get verification_status) | GET | SUPABASE SDK | ✅ | RLS enforces self-only |
| 3.1.2 | `/functions/v1/verification-photo-upload-url` | POST | CUSTOM EF | ❌ | Missing (marked TODO) |
| 3.1.3 | `/functions/v1/verification-photo-submit` | POST | CUSTOM EF | ❌ | Missing (marked TODO) |
| 3.1.4 | `/functions/v1/verification-status-history` | GET | CUSTOM EF | ❌ | Missing (marked TODO) |
| **3.2 Availability** |
| 3.2.1 | `/rest/v1/females` (toggle is_online) | PATCH | SUPABASE SDK | ✅ | RLS + Realtime |
| 3.2.2 | `[REALTIME]` female-presence | — | REALTIME | ✅ | Enabled |
| **3.3 Payout Details** |
| 3.3.1 | `/rest/v1/payout_details` (get) | GET | SUPABASE SDK | ✅ | RLS enforces self-only |
| 3.3.2 | `/rest/v1/payout_details` (create) | POST | SUPABASE SDK | ✅ | RLS validates structure |
| 3.3.3 | `/rest/v1/payout_details` (update) | PATCH | SUPABASE SDK | ✅ | RLS validates structure |
| **3.4 Stats & Earnings** |
| 3.4.1 | `/functions/v1/stats-female` | GET | CUSTOM EF | ✅ | Deployed |
| 3.4.2 | `/rest/v1/female_earnings` (history) | GET | SUPABASE SDK | ✅ | RLS enforces self-only |
| 3.4.3 | `/rest/v1/recent_activity_view` | GET | SUPABASE SDK | ✅ | View-based |
| **3.5 Payouts** |
| 3.5.1 | `/functions/v1/payouts-request` | POST | CUSTOM EF | ✅ | Deployed |
| 3.5.2 | `/rest/v1/payouts` (history) | GET | SUPABASE SDK | ✅ | RLS enforces self-only |
| 3.5.3 | `/functions/v1/payouts-cancel` | PATCH | CUSTOM EF | ✅ | Deployed |

---

### 4. Male-Specific

| # | Endpoint | Method | Type | Status | Note |
|---|---|---|---|---|---|
| **4.1 Wallet & Transactions** |
| 4.1.1 | `/rest/v1/males` (coin_balance) | GET | SUPABASE SDK | ✅ | RLS enforces self-only |
| 4.1.2 | `/rest/v1/coin_transactions` (history) | GET | SUPABASE SDK | ✅ | RLS enforces self-only |
| 4.1.3 | `/functions/v1/stats-male` | GET | CUSTOM EF | ✅ | Deployed |
| **4.2 Favorites** |
| 4.2.1 | `/rest/v1/favorites` (list) | GET | SUPABASE SDK | ✅ | RLS enforces self-only |
| 4.2.2 | `/rest/v1/favorites` (add) | POST | SUPABASE SDK | ✅ | RLS enforces self-only |
| 4.2.3 | `/rest/v1/favorites` (remove) | DELETE | SUPABASE SDK | ✅ | RLS enforces self-only |

---

### 5. Browse Females

| # | Endpoint | Method | Type | Status | Note |
|---|---|---|---|---|---|
| 5.1 | `/rest/v1/females_available_view` (browse) | GET | SUPABASE SDK | ✅ | View-based, filters sensitive data |
| 5.2 | `/rest/v1/females_public_view` (single profile) | GET | SUPABASE SDK | ❌ | View not created; use females_available_view as workaround |
| 5.3 | `/functions/v1/female-stats-public/<id>` | GET | CUSTOM EF | ❌ | Missing |

---

### 6. Coin Packages & Payments

| # | Endpoint | Method | Type | Status | Note |
|---|---|---|---|---|---|
| 6.1 | `/rest/v1/coin_packages` (list) | GET | SUPABASE SDK | ✅ | RLS allows public read |
| 6.2 | `/functions/v1/payments-create-order` | POST | CUSTOM EF | ✅ | Deployed |
| 6.3 | `/functions/v1/payments-verify` | POST | CUSTOM EF | ✅ | Deployed |
| 6.4 | `/functions/v1/webhooks-razorpay` | POST | WEBHOOK | ✅ | Deployed, idempotent |
| 6.5 | `/rest/v1/payments` (history) | GET | SUPABASE SDK | ✅ | RLS enforces self-only |

---

### 7. Chat Requests (Phase 1)

| # | Endpoint | Method | Type | Status | Note |
|---|---|---|---|---|---|
| **7.1 Male initiates** |
| 7.1.1 | `/functions/v1/chat-requests-send` | POST | CUSTOM EF | ✅ | Deployed |
| 7.1.2 | `/rest/v1/chat_requests` (poll) | GET | SUPABASE SDK | ✅ | RLS enforces owner-only |
| 7.1.3 | `/functions/v1/chat-requests-cancel` | PATCH | CUSTOM EF | ✅ | Deployed |
| **7.2 Female responds** |
| 7.2.1 | `/rest/v1/chat_requests` (incoming) | GET | SUPABASE SDK | ✅ | RLS enforces recipient-only |
| 7.2.2 | `/functions/v1/chat-requests-respond` (accept) | PATCH | CUSTOM EF | ✅ | Deployed (dual action: accept/decline) |
| 7.2.3 | `/functions/v1/chat-requests-respond` (decline) | PATCH | CUSTOM EF | ✅ | (same function) |
| **7.3 Real-time & cron** |
| 7.3.1 | `[REALTIME]` chat-requests:user_id | — | REALTIME | ✅ | Enabled |
| 7.3.2 | `[CRON]` Expire stale requests (30s) | — | CRON | ✅ | Deployed: `expire_pending_chat_requests()` |

---

### 8. Chat Session (Phase 2 — Deferred)

| # | Endpoint | Method | Type | Status | Note |
|---|---|---|---|---|---|
| 8.1 | `/functions/v1/chats-start` | POST | CUSTOM EF | ❌ | Phase 2 |
| 8.2 | `/rest/v1/chat_messages` (history) | GET | SUPABASE SDK | ❌ | Phase 2 |
| 8.3 | `/rest/v1/chat_messages` (send) | POST | SUPABASE SDK | ❌ | Phase 2 |
| 8.4 | `[REALTIME]` chat:<chatId> | — | REALTIME | ❌ | Phase 2 |
| 8.5 | `/functions/v1/chats/<id>/end` | POST | CUSTOM EF | ❌ | Phase 2 |
| 8.6 | `/functions/v1/chats/<id>/rating` | POST | CUSTOM EF | ❌ | Phase 2 |
| 8.7 | `[CRON]` End stale chat sessions | — | CRON | ❌ | Phase 2 |

---

### 9. Notifications

| # | Endpoint | Method | Type | Status | Note |
|---|---|---|---|---|---|
| 9.1 | `/rest/v1/notifications` (list) | GET | SUPABASE SDK | ✅ | RLS enforces self-only |
| 9.2 | `/functions/v1/notifications-unread-count` | GET | CUSTOM EF | ❌ | Missing |
| 9.3 | `/rest/v1/notifications` (mark read) | PATCH | SUPABASE SDK | ✅ | RLS enforces self-only |
| 9.4 | `/functions/v1/notifications-mark-all-read` | POST | CUSTOM EF | ❌ | Missing |
| 9.5 | `/functions/v1/notifications-register-device` | POST | CUSTOM EF | ❌ | Missing (FCM token registration) |
| 9.6 | `/functions/v1/notifications-unregister-device` | DELETE | CUSTOM EF | ❌ | Missing |
| 9.7 | `[REALTIME]` notifications:user_id | — | REALTIME | ✅ | Enabled |

---

### 10. Block & Report

| # | Endpoint | Method | Type | Status | Note |
|---|---|---|---|---|---|
| **10.1 Blocks** |
| 10.1.1 | `/rest/v1/user_blocks` (list) | GET | SUPABASE SDK | ✅ | RLS enforces self-only |
| 10.1.2 | `/rest/v1/user_blocks` (create) | POST | SUPABASE SDK | ✅ | RLS prevents self-block |
| 10.1.3 | `/rest/v1/user_blocks` (remove) | DELETE | SUPABASE SDK | ✅ | RLS enforces self-only |
| **10.2 Reports** |
| 10.2.1 | `/functions/v1/reports-submit` | POST | CUSTOM EF | ✅ | Deployed |
| 10.2.2 | `/functions/v1/reports-admin-review` | PATCH | CUSTOM EF | ✅ | Deployed |

---

### 11. Support

| # | Endpoint | Method | Type | Status | Note |
|---|---|---|---|---|---|
| 11.1 | `/functions/v1/support-submit-issue` | POST | CUSTOM EF | ❌ | Not yet implemented |
| 11.2 | `/rest/v1/faq_items` (list) | GET | SUPABASE SDK | ❌ | Table/RLS not created |

---

### 12. App Configuration

| # | Endpoint | Method | Type | Status | Note |
|---|---|---|---|---|---|
| 12.1 | `/functions/v1/config-app` | GET | CUSTOM EF | ✅ | Deployed |
| 12.2 | `/rest/v1/faq_items` (admin) | GET/POST/PATCH/DELETE | SUPABASE SDK | ❌ | Table not created |

---

### 13. Cloudinary Signed Uploads

| # | Endpoint | Method | Type | Status | Note |
|---|---|---|---|---|---|
| 13.1 | `/functions/v1/cloudinary-sign` | POST | CUSTOM EF | ✅ | Deployed |

---

### 14. DPDP Compliance

| # | Endpoint | Method | Type | Status | Note |
|---|---|---|---|---|---|
| 14.1 | `/functions/v1/me/data-export` | POST | CUSTOM EF | ❌ | Not yet implemented |
| 14.2 | `/functions/v1/me/data-export/<id>` | GET | CUSTOM EF | ❌ | Not yet implemented |
| 14.3 | `/functions/v1/me/data-deletion-request` | POST | CUSTOM EF | ❌ | Not yet implemented |
| 14.4 | `[CRON]` Process pending deletions | — | CRON | ❌ | Not yet implemented |

---

### 15. Admin Dashboard APIs

| # | Endpoint | Method | Type | Status | Note |
|---|---|---|---|---|---|
| **15.1 Admin auth** |
| 15.1.1 | `/functions/v1/admin/auth-login` | POST | CUSTOM EF | ❌ | Not yet implemented |
| 15.1.2 | `/functions/v1/admin/auth-refresh` | POST | CUSTOM EF | ❌ | Not yet implemented |
| **15.2 User management** |
| 15.2.1 | `/functions/v1/admin/users` | GET | CUSTOM EF | ❌ | Not yet implemented |
| 15.2.2 | `/functions/v1/admin/users/<id>` | GET | CUSTOM EF | ❌ | Not yet implemented |
| 15.2.3 | `/functions/v1/admin/users/<id>/suspend` | PATCH | CUSTOM EF | ❌ | Not yet implemented |
| 15.2.4 | `/functions/v1/admin/users/<id>/unsuspend` | PATCH | CUSTOM EF | ❌ | Not yet implemented |
| 15.2.5 | `/functions/v1/admin/users/<id>` (delete) | DELETE | CUSTOM EF | ❌ | Not yet implemented |
| **15.3 Verification management** |
| 15.3.1 | `/functions/v1/admin/verifications-pending` | GET | CUSTOM EF | ❌ | Not yet implemented |
| 15.3.2 | `/functions/v1/admin/verifications/<id>/photo` | GET | CUSTOM EF | ❌ | Not yet implemented |
| 15.3.3 | `/functions/v1/admin/verifications/<id>/approve` | PATCH | CUSTOM EF | ✅ | (covered by payout action) |
| 15.3.4 | `/functions/v1/admin/verifications/<id>/reject` | PATCH | CUSTOM EF | ❌ | Not yet implemented |
| **15.4 Payout management** |
| 15.4.1 | `/functions/v1/admin/payouts-pending` | GET | CUSTOM EF | ❌ | Not yet implemented |
| 15.4.2 | `/functions/v1/admin/payouts/<id>/approve` | PATCH | CUSTOM EF | ✅ | via admin-payouts-action |
| 15.4.3 | `/functions/v1/admin/payouts/<id>/complete` | PATCH | CUSTOM EF | ✅ | via admin-payouts-action |
| 15.4.4 | `/functions/v1/admin/payouts/<id>/reject` | PATCH | CUSTOM EF | ✅ | via admin-payouts-action |
| **15.5–15.9 Other admin** |
| 15.5+ | (Chat oversight, Reports, Analytics, Config, Audit) | — | CUSTOM EF | ❌ | Not yet implemented |

---

### 16. Internal / Cron Jobs

| # | Job | Frequency | Status | Note |
|---|---|---|---|---|
| 16.1 | Refresh online presence | 60s | ✅ | Auto-mark offline if no heartbeat > 2min |
| 16.2 | Expire stale chat requests | 30s | ✅ | Deployed: `expire_pending_chat_requests()` |
| 16.3 | Daily analytics rollup | Daily | ❌ | Not yet implemented |
| 16.4 | Payment reconciliation | 1h | ❌ | Not yet implemented |
| 16.5 | Notification cleanup | Daily | ❌ | Not yet implemented |
| 16.6 | Stale FCM token cleanup | Weekly | ❌ | Not yet implemented |
| 16.7 | `[CRON]` Process pending deletions | Daily | ❌ | DPDP compliance, deferred |

---

### 17. Real-time Channels

| # | Channel | Subscribers | Status | Note |
|---|---|---|---|---|
| 17.1 | `chat-requests:user_id=<id>` | Both parties | ✅ | Enabled |
| 17.2 | `notifications:user_id=<id>` | All users | ✅ | Enabled |
| 17.3 | `female-presence` | Males browsing | ✅ | Enabled |
| 17.4 | `chat:<chatId>` | Both participants | ❌ | Phase 2 |

---

## Next Priorities

### **Phase 1 Completions (Medium effort)**

1. **Verification flow** (3.1.2–3.1.4) — Female verification photo upload + history
2. **Notification badges** (9.2, 9.4) — Unread count + mark all read
3. **FCM device registration** (9.5–9.6) — Push token lifecycle
4. **Public female stats** (5.3) — Stats visible to males
5. **Support & FAQ** (11.1–11.2) — Support issue submission + FAQ admin CRUD
6. **App config FAQs** (12.2) — FAQ management endpoints

### **Phase 1 Hard blocks (Legal/Compliance)**

7. **DPDP data export/deletion** (14.1–14.4) — Required by law
8. **Password reset flow** (1.5–1.6) — Account recovery

### **Admin Dashboard** (Lower priority for v1 launch)

9. Admin auth system (15.1)
10. Admin user management (15.2)
11. Admin verification queue (15.3)
12. Admin payout queue (15.4)
13. Admin reports management
14. Admin analytics

### **Phase 2** (Deferred to later)

15. Active chat session (8.*)
16. Chat messaging + real-time
17. Queue management (5-person, 20-min)
18. Coin deduction during chat

---

## Git Log (Recent Work)

```
7a5b6f9 stats, block and report implementation done
dcb5072 payout flow implementation done
9c2c688 basic notification implementation done
977a7aa chat flow implementation done
df6ed9f razor pay payment setup
1e4e231 browse and fav section code
ae6cc3c until prompt c covered
```

**Latest deployed Edge Functions:** 23  
**Latest deployed migrations:** 21  
**Latest deployed cron jobs:** 2  

---

## How to Use This Document

1. **Check overall progress:** Use the Summary table to see Phase 1 status.
2. **Before starting work:** Pick the next task from "Next Priorities" and find it here.
3. **Verify deployment:** Once an EF is deployed, mark its row ✅ and update git.
4. **Track blockers:** If an endpoint is ❌ and blocks something in progress, escalate it.

Keep this document in sync with code changes — update the date at the top after each major push.
