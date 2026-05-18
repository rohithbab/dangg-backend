# Dangg — Complete Backend API Inventory

This document lists every backend API the Dangg application needs, organized by domain. Use this as the source for building the Swagger / OpenAPI specification.

For each endpoint, you'll see:
- **Method + Path** — HTTP method and URL pattern
- **Auth** — what authentication is required
- **Type** — `[CUSTOM EF]` = custom Edge Function | `[SUPABASE SDK]` = handled directly by Supabase client | `[WEBHOOK]` = external system calls our endpoint | `[CRON]` = scheduled job | `[REALTIME]` = Supabase Realtime channel
- **Description** — one-line purpose
- **Notes** — anything non-obvious

> **Convention:** All paths are relative to the API base. Custom Edge Functions live at `https://{project}.supabase.co/functions/v1/{name}`. Direct SDK calls go through `https://{project}.supabase.co/rest/v1/{table}`.

---

## 1. Authentication

Most of this is handled by Supabase Auth SDK directly. The frontend calls `supabase.auth.*` methods; you don't build these endpoints yourself.

| Method + Path | Auth | Type | Description |
|---|---|---|---|
| `POST /auth/v1/otp` | None | `[SUPABASE SDK]` | Send OTP for signup or login — Supabase routes through your custom Send SMS Hook |
| `POST /auth/v1/verify` | None | `[SUPABASE SDK]` | Verify OTP, returns session (access + refresh tokens) |
| `POST /auth/v1/token?grant_type=refresh_token` | Refresh token | `[SUPABASE SDK]` | Refresh access token |
| `POST /auth/v1/logout` | Bearer JWT | `[SUPABASE SDK]` | Invalidate session |
| `POST /auth/v1/recover` | None | `[SUPABASE SDK]` | Forgot password — send OTP for reset |
| `PUT /auth/v1/user` | Bearer JWT | `[SUPABASE SDK]` | Update password (after OTP recover or while authenticated) |
| `GET /auth/v1/user` | Bearer JWT | `[SUPABASE SDK]` | Get current session user info |

**Custom Edge Functions for auth:**

| Method + Path | Auth | Type | Description |
|---|---|---|---|
| `POST /functions/v1/send-sms-hook` | Supabase webhook secret | `[WEBHOOK]` | Receives Supabase Auth's "Send OTP" event, calls MSG91 with the OTP. Body: `{ user, sms: { otp, phone } }` |
| `POST /functions/v1/delete-account` | Bearer JWT | `[CUSTOM EF]` | Initiates account deletion: marks account as deletion-pending, schedules cleanup after 30-day grace period |
| `POST /functions/v1/cancel-account-deletion` | Bearer JWT | `[CUSTOM EF]` | User changes mind within grace period — restores account |

---

## 2. User Profile (shared across roles)

| Method + Path | Auth | Type | Description |
|---|---|---|---|
| `GET /rest/v1/users?select=*` (filter `id=eq.<self>`) | Bearer JWT | `[SUPABASE SDK]` | Get own user record — RLS enforces "self only" |
| `PATCH /rest/v1/users?id=eq.<self>` | Bearer JWT | `[SUPABASE SDK]` | Update mutable fields (name, age, dob, etc.) |
| `POST /functions/v1/profile-picture-upload` | Bearer JWT | `[CUSTOM EF]` | Returns signed Cloudinary upload params for client to upload directly. Returns: `{ uploadUrl, signature, timestamp, apiKey, folder }` |
| `POST /functions/v1/profile-picture-confirm` | Bearer JWT | `[CUSTOM EF]` | After client uploads to Cloudinary, this confirms the upload and saves the public URL to the user record. Body: `{ publicUrl, secureUrl }` |
| `DELETE /functions/v1/profile-picture` | Bearer JWT | `[CUSTOM EF]` | Removes profile picture from user record AND deletes from Cloudinary |

---

## 3. Female-Specific Endpoints

### 3.1 Verification

| Method + Path | Auth | Type | Description |
|---|---|---|---|
| `GET /rest/v1/females?id=eq.<self>&select=verification_status` | Bearer JWT (female) | `[SUPABASE SDK]` | Get own verification status: `none`, `pending`, `verified`, `rejected` |
| `POST /functions/v1/verification-photo-upload-url` | Bearer JWT (female) | `[CUSTOM EF]` | Returns a signed Supabase Storage URL for private verification bucket upload |
| `POST /functions/v1/verification-photo-submit` | Bearer JWT (female) | `[CUSTOM EF]` | Confirms photo uploaded; sets `verification_status = 'pending'`; notifies admin |
| `GET /functions/v1/verification-status-history` | Bearer JWT (female) | `[CUSTOM EF]` | Returns history of verification attempts (helpful if rejected and re-submitting) |

### 3.2 Availability

| Method + Path | Auth | Type | Description |
|---|---|---|---|
| `PATCH /rest/v1/females?id=eq.<self>` body `{ is_online: true/false }` | Bearer JWT (female, verified) | `[SUPABASE SDK]` | Toggle availability. RLS rejects if not verified. Triggers a Realtime broadcast for online presence. |
| `[REALTIME]` channel: `female-presence` | Bearer JWT (male) | `[REALTIME]` | Males subscribed see females going on/offline in real-time. Filtered per-row. |

### 3.3 Bank/UPI Payout Details

| Method + Path | Auth | Type | Description |
|---|---|---|---|
| `GET /rest/v1/payout_details?female_id=eq.<self>` | Bearer JWT (female) | `[SUPABASE SDK]` | Get current bank/UPI details |
| `POST /rest/v1/payout_details` | Bearer JWT (female) | `[SUPABASE SDK]` | First-time setup |
| `PATCH /rest/v1/payout_details?female_id=eq.<self>` | Bearer JWT (female) | `[SUPABASE SDK]` | Update — RLS validates structure (either bank fields OR upi_id, not both) |

### 3.4 Stats & Earnings

| Method + Path | Auth | Type | Description |
|---|---|---|---|
| `GET /functions/v1/female-stats` | Bearer JWT (female) | `[CUSTOM EF]` | Aggregated stats: today's earnings, week, month, total; chats today; rating average; rank/percentile. Custom EF because needs joins across tables |
| `GET /rest/v1/transactions?female_id=eq.<self>&order=created_at.desc&limit=20` | Bearer JWT (female) | `[SUPABASE SDK]` | Earnings history, paginated via offset/cursor |
| `GET /rest/v1/recent_activity_view?female_id=eq.<self>&limit=10` | Bearer JWT (female) | `[SUPABASE SDK]` | Recent chats, ratings received, payments. Reads from a database view that joins multiple tables |

### 3.5 Payouts

| Method + Path | Auth | Type | Description |
|---|---|---|---|
| `POST /functions/v1/payout-request` | Bearer JWT (female) | `[CUSTOM EF]` | Initiate payout: validates balance ≥ min payout (₹500), no pending payout exists, payout details configured. Locks the amount, sets status to `pending`. Body: `{ amount }` |
| `GET /rest/v1/payouts?female_id=eq.<self>&order=created_at.desc` | Bearer JWT (female) | `[SUPABASE SDK]` | Payout history |
| `PATCH /functions/v1/payout/<id>/cancel` | Bearer JWT (female) | `[CUSTOM EF]` | Cancel a pending payout (only if still in `pending` state, not yet approved) |

---

## 4. Male-Specific Endpoints

### 4.1 Wallet & Transactions

| Method + Path | Auth | Type | Description |
|---|---|---|---|
| `GET /rest/v1/males?id=eq.<self>&select=coin_balance` | Bearer JWT (male) | `[SUPABASE SDK]` | Get current coin balance |
| `GET /rest/v1/coin_transactions?male_id=eq.<self>&order=created_at.desc` | Bearer JWT (male) | `[SUPABASE SDK]` | Coin transaction history (purchases, chat spends, refunds), paginated |
| `GET /functions/v1/male-stats` | Bearer JWT (male) | `[CUSTOM EF]` | Aggregate: total coins purchased, total chats, member since, money spent |

### 4.2 Favorites

| Method + Path | Auth | Type | Description |
|---|---|---|---|
| `GET /rest/v1/favorites?male_id=eq.<self>&select=*,females(*)` | Bearer JWT (male) | `[SUPABASE SDK]` | List favorited females with their profile data |
| `POST /rest/v1/favorites` body `{ female_id }` | Bearer JWT (male) | `[SUPABASE SDK]` | Add favorite (insert) |
| `DELETE /rest/v1/favorites?male_id=eq.<self>&female_id=eq.<id>` | Bearer JWT (male) | `[SUPABASE SDK]` | Remove favorite |

---

## 5. Browse Females (male-facing list)

| Method + Path | Auth | Type | Description |
|---|---|---|---|
| `GET /rest/v1/females_available_view?<filters>&order=...&limit=20&offset=N` | Bearer JWT (male) | `[SUPABASE SDK]` | Browse available females. View hides sensitive data (verification photo path, bank details). Filters: `is_online`, age range, rating min, price range. Sort: `last_active`, `rating_avg`, `coin_price`. |
| `GET /rest/v1/females_public_view?id=eq.<id>` | Bearer JWT (male) | `[SUPABASE SDK]` | Single female profile preview — only public fields |
| `GET /functions/v1/female-stats-public/<id>` | Bearer JWT (male) | `[CUSTOM EF]` | Public stats: total chats, average response time, rating |

> **Important:** Use a Postgres VIEW (`females_available_view`) that joins females + payout_details + profile_picture and exposes ONLY the fields males should see. Bank/UPI details and verification photos must NEVER be returned to males. RLS on the view enforces this.

---

## 6. Coin Packages & Payments (Razorpay)

| Method + Path | Auth | Type | Description |
|---|---|---|---|
| `GET /rest/v1/coin_packages?is_active=eq.true&order=display_order` | Bearer JWT (any) | `[SUPABASE SDK]` | List available coin packages — coins, price (INR), bonus, tag (POPULAR/BEST DEAL) |
| `POST /functions/v1/payments/create-order` | Bearer JWT (male) | `[CUSTOM EF]` | Create a Razorpay order. Body: `{ packageId }`. Returns: `{ orderId, amount, currency, razorpayKeyId }`. Server creates an order with Razorpay API using secret key (NEVER expose to client) |
| `POST /functions/v1/payments/verify` | Bearer JWT (male) | `[CUSTOM EF]` | After Razorpay payment success, client calls this with `{ razorpay_order_id, razorpay_payment_id, razorpay_signature }`. Server verifies signature using webhook secret, credits coins to male's wallet, creates transaction record |
| `POST /functions/v1/webhooks/razorpay` | Razorpay signature | `[WEBHOOK]` | Razorpay-to-backend webhook for payment events (payment.captured, payment.failed, refund.processed). Verifies signature, idempotent (uses event ID), updates transaction status |
| `GET /rest/v1/payments?male_id=eq.<self>&order=created_at.desc` | Bearer JWT (male) | `[SUPABASE SDK]` | Payment history with Razorpay metadata |

---

## 7. Chat Requests (Phase 1 — initiation + outcome only)

### 7.1 Male initiates

| Method + Path | Auth | Type | Description |
|---|---|---|---|
| `POST /functions/v1/chat-requests/send` | Bearer JWT (male) | `[CUSTOM EF]` | Send chat request. Body: `{ femaleId }`. Server validates: female is online, male has enough coins, no existing pending request to this female. Deducts coins (escrow). Creates request with 5-min TTL. Pushes FCM to female. Body returns: `{ requestId, expiresAt, coinsDeducted }` |
| `GET /rest/v1/chat_requests?id=eq.<requestId>` | Bearer JWT (male, owner) | `[SUPABASE SDK]` | Poll request status |
| `PATCH /functions/v1/chat-requests/<requestId>/cancel` | Bearer JWT (male, owner) | `[CUSTOM EF]` | Male cancels while waiting. Refunds coins. Sets status to `cancelled`. Notifies female |

### 7.2 Female responds

| Method + Path | Auth | Type | Description |
|---|---|---|---|
| `GET /rest/v1/chat_requests?female_id=eq.<self>&status=eq.pending` | Bearer JWT (female) | `[SUPABASE SDK]` | List incoming pending requests |
| `PATCH /functions/v1/chat-requests/<requestId>/accept` | Bearer JWT (female, recipient) | `[CUSTOM EF]` | Accept request. Transitions to `accepted`. Bridges to Phase 2 chat session creation. Notifies male via FCM + Realtime |
| `PATCH /functions/v1/chat-requests/<requestId>/decline` | Bearer JWT (female, recipient) | `[CUSTOM EF]` | Decline. Refunds male's coins. Notifies male |

### 7.3 Real-time + scheduled

| Method + Path | Auth | Type | Description |
|---|---|---|---|
| `[REALTIME]` channel: `chat-requests:user_id=<self>` | Bearer JWT | `[REALTIME]` | Both male (outgoing) and female (incoming) subscribe to changes on their requests |
| `[CRON]` Expire stale chat requests | — | `[CRON]` | Every 30 seconds, find requests with `status=pending` and `expires_at < now()`. Refund coins, set status to `timeout`, notify male |

---

## 8. Chat Session (Phase 2 — placeholders, build later)

These will be implemented in Phase 2. Listing here so they're in the spec from the start.

| Method + Path | Auth | Type | Description |
|---|---|---|---|
| `POST /functions/v1/chats/start` | Bearer JWT | `[CUSTOM EF]` | Phase 2: After chat request accepted, create chat session with TTL |
| `GET /rest/v1/chat_messages?chat_id=eq.<id>&order=created_at` | Bearer JWT (participant) | `[SUPABASE SDK]` | Phase 2: Message history |
| `POST /rest/v1/chat_messages` | Bearer JWT (participant) | `[SUPABASE SDK]` | Phase 2: Send message (with coin deduction trigger) |
| `[REALTIME]` channel: `chat:<chatId>` | Bearer JWT (participant) | `[REALTIME]` | Phase 2: Real-time messages |
| `POST /functions/v1/chats/<id>/end` | Bearer JWT (participant) | `[CUSTOM EF]` | Phase 2: End chat session, finalize coin transfer |
| `POST /functions/v1/chats/<id>/rating` | Bearer JWT (male) | `[CUSTOM EF]` | Phase 2: Male submits like/dislike rating after chat. Affects female's rating average |
| `[CRON]` End stale chat sessions | — | `[CRON]` | Phase 2: End chats inactive beyond TTL |

---

## 9. Notifications

| Method + Path | Auth | Type | Description |
|---|---|---|---|
| `GET /rest/v1/notifications?user_id=eq.<self>&order=created_at.desc&limit=20` | Bearer JWT | `[SUPABASE SDK]` | Paginated notifications list |
| `GET /functions/v1/notifications/unread-count` | Bearer JWT | `[CUSTOM EF]` | Just the unread count (cheap call for badge) |
| `PATCH /rest/v1/notifications?id=eq.<id>` body `{ is_read: true }` | Bearer JWT | `[SUPABASE SDK]` | Mark single notification read |
| `POST /functions/v1/notifications/mark-all-read` | Bearer JWT | `[CUSTOM EF]` | Mark all as read in one call |
| `POST /functions/v1/notifications/register-device` | Bearer JWT | `[CUSTOM EF]` | Register FCM token for current device. Body: `{ token, platform: 'ios'\|'android', deviceId }` |
| `DELETE /functions/v1/notifications/unregister-device` | Bearer JWT | `[CUSTOM EF]` | Unregister on logout |
| `POST /functions/v1/notifications/push` | Internal (service role) | `[CUSTOM EF]` | Internal trigger to send a push to a user. Called by other Edge Functions (e.g., chat-request creation triggers this) |
| `[REALTIME]` channel: `notifications:user_id=<self>` | Bearer JWT | `[REALTIME]` | In-app real-time notifications without polling |

---

## 10. Block & Report

| Method + Path | Auth | Type | Description |
|---|---|---|---|
| `GET /rest/v1/blocks?blocker_id=eq.<self>` | Bearer JWT | `[SUPABASE SDK]` | List users I've blocked |
| `POST /rest/v1/blocks` body `{ blocked_user_id, reason? }` | Bearer JWT | `[SUPABASE SDK]` | Block a user. RLS prevents blocking self |
| `DELETE /rest/v1/blocks?blocker_id=eq.<self>&blocked_user_id=eq.<id>` | Bearer JWT | `[SUPABASE SDK]` | Unblock |
| `POST /functions/v1/reports` | Bearer JWT | `[CUSTOM EF]` | Submit report against a user. Body: `{ reportedUserId, category, description, evidenceUrls?, chatId? }`. Notifies admin |

---

## 11. Support

| Method + Path | Auth | Type | Description |
|---|---|---|---|
| `POST /functions/v1/support/submit-issue` | Bearer JWT | `[CUSTOM EF]` | User submits issue from Help & Support. Body: `{ category, description, screenshotUrl?, appVersion, deviceInfo }`. Creates ticket; emails support inbox |
| `GET /rest/v1/faq_items?is_active=eq.true&order=display_order` | None (public) | `[SUPABASE SDK]` | FAQ items for Help & Support screen — manageable via admin |

---

## 12. App Configuration (Important — frontend reads this on every app launch)

| Method + Path | Auth | Type | Description |
|---|---|---|---|
| `GET /functions/v1/config/app` | None (public) | `[CUSTOM EF]` | Returns: `{ minSupportedVersion, latestVersion, forceUpdate: boolean, maintenanceMode: boolean, defaultChatCost, payoutMinAmount, payoutMaxPending, supportEmail, supportPhone, termsUrl, privacyUrl }`. App fetches at startup and on resume from background |
| `GET /rest/v1/faq_items` | None | `[SUPABASE SDK]` | (see Support above) |

---

## 13. Cloudinary Signed Uploads

Cloudinary uploads must be signed server-side (the API secret can't be in the mobile app).

| Method + Path | Auth | Type | Description |
|---|---|---|---|
| `POST /functions/v1/cloudinary/sign` | Bearer JWT | `[CUSTOM EF]` | Generate a signed upload signature. Body: `{ folder, publicId? }`. Returns: `{ signature, timestamp, apiKey, cloudName, folder }`. Client uses these to upload directly to Cloudinary |

---

## 14. DPDP Compliance (data export & deletion)

| Method + Path | Auth | Type | Description |
|---|---|---|---|
| `POST /functions/v1/me/data-export` | Bearer JWT | `[CUSTOM EF]` | Initiate data export. Returns `{ exportId, statusUrl }`. Server queues a background job to compile JSON export of all user data |
| `GET /functions/v1/me/data-export/<id>` | Bearer JWT | `[CUSTOM EF]` | Poll status. Returns `{ status: 'queued'\|'processing'\|'ready'\|'failed', downloadUrl?, expiresAt? }`. Ready downloads are signed Cloudinary URLs with 7-day expiry |
| `POST /functions/v1/me/data-deletion-request` | Bearer JWT | `[CUSTOM EF]` | Initiate account deletion (30-day cooldown). Body: `{ reason?, confirmation: 'DELETE MY ACCOUNT' }`. Account immediately marked as deletion-pending, user logged out |
| `[CRON]` Process pending deletions | — | `[CRON]` | Daily: for accounts where `deletion_requested_at + 30 days < now()`, fully delete: PII redaction, photos deleted from Cloudinary/Supabase Storage, payment records anonymized but retained per legal req |

---

## 15. Admin Dashboard APIs (separate auth)

Admin endpoints use a separate auth flow with role-based access. Admin users authenticate via Supabase Auth with `role: 'admin'` claim, OR a separate admin auth system.

### 15.1 Admin auth

| Method + Path | Auth | Type | Description |
|---|---|---|---|
| `POST /functions/v1/admin/auth/login` | Admin credentials | `[CUSTOM EF]` | Admin login with email + password (separate from user auth). Returns admin JWT |
| `POST /functions/v1/admin/auth/refresh` | Refresh token | `[CUSTOM EF]` | Refresh admin token |

### 15.2 User management

| Method + Path | Auth | Type | Description |
|---|---|---|---|
| `GET /functions/v1/admin/users` | Admin JWT | `[CUSTOM EF]` | List all users with pagination + filters (role, status, registered date range, etc.) |
| `GET /functions/v1/admin/users/<id>` | Admin JWT | `[CUSTOM EF]` | Full user detail incl. PII, payouts, transactions, reports against them |
| `PATCH /functions/v1/admin/users/<id>/suspend` | Admin JWT | `[CUSTOM EF]` | Suspend user account. Logs to audit trail |
| `PATCH /functions/v1/admin/users/<id>/unsuspend` | Admin JWT | `[CUSTOM EF]` | Reactivate suspended user |
| `DELETE /functions/v1/admin/users/<id>` | Admin JWT (super-admin) | `[CUSTOM EF]` | Force-delete account (different from user-initiated deletion) |

### 15.3 Verification management

| Method + Path | Auth | Type | Description |
|---|---|---|---|
| `GET /functions/v1/admin/verifications/pending` | Admin JWT | `[CUSTOM EF]` | Queue of pending female verifications |
| `GET /functions/v1/admin/verifications/<femaleId>/photo` | Admin JWT | `[CUSTOM EF]` | Signed URL to view the verification photo (private bucket) |
| `PATCH /functions/v1/admin/verifications/<id>/approve` | Admin JWT | `[CUSTOM EF]` | Approve. Sets `verification_status = 'verified'`. Notifies female via push + in-app notification |
| `PATCH /functions/v1/admin/verifications/<id>/reject` | Admin JWT | `[CUSTOM EF]` | Reject. Body: `{ reason }`. Notifies female; female can resubmit |

### 15.4 Payout management

| Method + Path | Auth | Type | Description |
|---|---|---|---|
| `GET /functions/v1/admin/payouts/pending` | Admin JWT | `[CUSTOM EF]` | Queue of pending payout requests |
| `PATCH /functions/v1/admin/payouts/<id>/approve` | Admin JWT | `[CUSTOM EF]` | Approve. Status → `approved`. Female sees "Approved — processing" |
| `PATCH /functions/v1/admin/payouts/<id>/complete` | Admin JWT | `[CUSTOM EF]` | After bank transfer done. Body: `{ utrNumber, completedAt }`. Status → `completed`. Female sees "Completed" |
| `PATCH /functions/v1/admin/payouts/<id>/reject` | Admin JWT | `[CUSTOM EF]` | Reject (either before approval, or after if UPI failed). Body: `{ reason }`. Refunds amount back to female's balance |

### 15.5 Chat oversight

| Method + Path | Auth | Type | Description |
|---|---|---|---|
| `GET /functions/v1/admin/chats` | Admin JWT | `[CUSTOM EF]` | List chat sessions with filters (date range, female, male, duration, has reports) |
| `GET /functions/v1/admin/chats/<id>` | Admin JWT | `[CUSTOM EF]` | Chat summary metadata |
| `GET /functions/v1/admin/chats/<id>/transcript` | Admin JWT | `[CUSTOM EF]` | Read chat transcript (Phase 2). Logged to audit trail |

### 15.6 Reports management

| Method + Path | Auth | Type | Description |
|---|---|---|---|
| `GET /functions/v1/admin/reports` | Admin JWT | `[CUSTOM EF]` | List user reports with filter (status, category) |
| `GET /functions/v1/admin/reports/<id>` | Admin JWT | `[CUSTOM EF]` | Report detail with full context (chat, parties involved, evidence) |
| `PATCH /functions/v1/admin/reports/<id>/resolve` | Admin JWT | `[CUSTOM EF]` | Resolve report. Body: `{ action: 'no-action'\|'warning'\|'suspension'\|'ban', notes }` |

### 15.7 Analytics

| Method + Path | Auth | Type | Description |
|---|---|---|---|
| `GET /functions/v1/admin/analytics/overview` | Admin JWT | `[CUSTOM EF]` | Top-level metrics: DAU, MAU, total users, revenue today/week/month |
| `GET /functions/v1/admin/analytics/revenue` | Admin JWT | `[CUSTOM EF]` | Revenue breakdown by day/week/month, by package, by region |
| `GET /functions/v1/admin/analytics/users` | Admin JWT | `[CUSTOM EF]` | User funnel: signup → verified → first chat → repeat |
| `GET /functions/v1/admin/analytics/chats` | Admin JWT | `[CUSTOM EF]` | Chat metrics: avg duration, completion rate, ratings distribution |
| `GET /functions/v1/admin/analytics/payouts` | Admin JWT | `[CUSTOM EF]` | Payout summary: total processed, pending, by time period |

### 15.8 Configuration management

| Method + Path | Auth | Type | Description |
|---|---|---|---|
| `GET /functions/v1/admin/coin-packages` | Admin JWT | `[CUSTOM EF]` | List all packages (including inactive) |
| `POST /functions/v1/admin/coin-packages` | Admin JWT | `[CUSTOM EF]` | Create new package |
| `PATCH /functions/v1/admin/coin-packages/<id>` | Admin JWT | `[CUSTOM EF]` | Update package (price, bonus, display order, tag) |
| `DELETE /functions/v1/admin/coin-packages/<id>` | Admin JWT | `[CUSTOM EF]` | Soft-delete (sets `is_active=false`) |
| `GET /functions/v1/admin/config` | Admin JWT | `[CUSTOM EF]` | Get app config values |
| `PATCH /functions/v1/admin/config` | Admin JWT (super-admin) | `[CUSTOM EF]` | Update app config (force update version, maintenance mode, chat cost defaults) |
| `GET /functions/v1/admin/faq` | Admin JWT | `[CUSTOM EF]` | List FAQ items |
| `POST /functions/v1/admin/faq` | Admin JWT | `[CUSTOM EF]` | Create FAQ |
| `PATCH /functions/v1/admin/faq/<id>` | Admin JWT | `[CUSTOM EF]` | Update FAQ |
| `DELETE /functions/v1/admin/faq/<id>` | Admin JWT | `[CUSTOM EF]` | Delete FAQ |

### 15.9 Audit log

| Method + Path | Auth | Type | Description |
|---|---|---|---|
| `GET /functions/v1/admin/audit-log` | Admin JWT (super-admin) | `[CUSTOM EF]` | Read admin action history with filters (admin user, action type, date range, target user) |

---

## 16. Internal / System (no client-facing)

| Method + Path | Auth | Type | Description |
|---|---|---|---|
| `[CRON]` Refresh online presence | — | `[CRON]` | Every 60s, mark as `offline` any female whose `last_heartbeat_at` is > 2 min ago |
| `[CRON]` Daily analytics rollup | — | `[CRON]` | Pre-compute daily metrics for fast admin dashboard queries |
| `[CRON]` Pending payment reconciliation | — | `[CRON]` | Every hour, check stuck Razorpay payments (initiated but no webhook in 10+ min). Query Razorpay API to confirm status |
| `[CRON]` Notification cleanup | — | `[CRON]` | Daily, delete notifications older than 90 days |
| `[CRON]` Stale FCM token cleanup | — | `[CRON]` | Weekly, remove FCM tokens not used in 30 days |

---

## 17. Real-time Channels Summary (NOT REST — Supabase Realtime subscriptions)

For completeness, these channels are subscribed to from the client. They're not endpoints, but they're part of the API surface.

| Channel | Subscribers | Events | Purpose |
|---|---|---|---|
| `chat-requests:user_id=<id>` | Both male & female | INSERT, UPDATE | Real-time chat request status changes |
| `notifications:user_id=<id>` | All users | INSERT | New in-app notifications without polling |
| `female-presence` (filtered) | Males who are browsing | UPDATE on `is_online` | See females go on/off in browse list |
| `chat:<chatId>` | Both participants | INSERT on `chat_messages` | Phase 2 chat messages |

---

# Implementation Priority

Suggested order for Phase 1:

**Phase 1A — Core auth & user (foundation):**
1. Send SMS Hook (so OTP signup works) — Section 1
2. User profile endpoints — Section 2
3. App config endpoint — Section 12

**Phase 1B — Female onboarding:**
4. Verification photo upload + submit — Section 3.1
5. Cloudinary signature endpoint — Section 13
6. Admin: verification approval — Section 15.3

**Phase 1C — Browse & request flow:**
7. Female availability — Section 3.2
8. Browse females view (DB view + RLS) — Section 5
9. Coin packages — Section 6
10. Razorpay integration (create order, verify, webhook) — Section 6
11. Chat request flow (send, accept, decline, cancel) — Section 7
12. Notifications + FCM device registration — Section 9

**Phase 1D — Earnings & payouts:**
13. Earnings stats EF — Section 3.4
14. Payout request EF — Section 3.5
15. Admin payout management — Section 15.4
16. Bank/UPI details endpoints — Section 3.3

**Phase 1E — Admin:**
17. Admin auth — Section 15.1
18. User management — Section 15.2
19. Reports management — Section 15.6
20. Analytics — Section 15.7
21. Config management — Section 15.8

**Phase 1F — Compliance & polish:**
22. Block & report — Section 10
23. Support submit issue — Section 11
24. DPDP data export & deletion — Section 14
25. Audit logging — Section 15.9
26. All cron jobs — Section 16

**Phase 2 (later):**
27. Chat session, messages, end, rating — Section 8
28. Phase 2 cron jobs — Section 16

---

# How to use this with Swagger

**Step 1 — Pick a tool.** Stoplight Studio or Swagger Editor (editor.swagger.io). Stoplight is friendlier for beginners; both work.

**Step 2 — Define common schemas first.** Before listing endpoints, define the data models (`User`, `Female`, `Male`, `ChatRequest`, `Transaction`, `Notification`, `Payout`, etc.) in the OpenAPI `components/schemas` section. Most endpoints reference these.

**Step 3 — Use AI to generate, one domain at a time.** Paste a section of this document (e.g., Section 6 Coin Packages & Payments) into the AI assistant with a prompt like:
> "Generate OpenAPI 3.0 YAML for these endpoints. Use bearer JWT auth. Use the schemas I've already defined. Include request body schemas, response schemas with example values, and error responses (400, 401, 403, 404, 500)."

Review the generated YAML, fix anything wrong, commit. Move to the next domain.

**Step 4 — Validate the spec.** Run it through Swagger Editor's linter. Fix any errors.

**Step 5 — Generate client types.** Once the spec is solid, run:
```
npx openapi-typescript ./openapi.yaml --output ./mobile/src/types/api.ts
```
This gives your React Native app perfectly-typed API responses. Any backend change reflects immediately in the types.

**Step 6 — Generate server stubs.** Use `openapi-generator` or `swagger-codegen` to scaffold Express route handlers for the custom Edge Functions. Each handler is empty — you fill in the business logic.

**Step 7 — Mock server.** Stoplight's Prism (`npx @stoplight/prism mock ./openapi.yaml`) lets the React Native app hit a fake backend that returns the example responses from your spec. Useful when backend isn't ready yet.

---

# Counts at a glance

- **Total custom Edge Functions:** ~58
- **Direct Supabase SDK calls (auto via PostgREST):** ~25
- **Webhooks:** 2 (Razorpay, Supabase Auth SMS Hook)
- **Cron jobs:** 7
- **Real-time channels:** 4

Total API surface area: ~96 distinct endpoints/operations.
