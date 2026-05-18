# API Reference

This document lists every API endpoint used by the mobile app. Use this as the source of truth when wiring up Flutter repository classes and when generating an OpenAPI/Swagger spec.

## Overview of Endpoint Types

The app talks to four kinds of APIs:

| Type | Base URL | Auth | Description |
|---|---|---|---|
| **Supabase Auth** | `{SUPABASE_URL}/auth/v1` | Anon key in header, JWT for authenticated | Built-in OTP, session, password reset |
| **Supabase PostgREST** | `{SUPABASE_URL}/rest/v1` | JWT | Auto-generated CRUD endpoints with RLS |
| **Supabase Edge Functions** | `{SUPABASE_URL}/functions/v1` | JWT | Custom server logic (payment, payout, chat, admin) |
| **Supabase Realtime** | `wss://{SUPABASE_URL}/realtime/v1` | JWT | WebSocket subscriptions |

Plus external direct calls from app to:

| Service | When |
|---|---|
| **Cloudinary** | Profile picture upload (with signed params from Edge Function) |
| **Razorpay SDK** | Payment checkout (after `razorpay-create-order` returns order_id) |

---

# 1. Authentication

## 1.1 Send OTP

```
POST /auth/v1/otp
Headers:
  apikey: {SUPABASE_ANON_KEY}
  Content-Type: application/json
Body:
  {
    "phone": "+919876543210"
  }
Response: 200 OK (empty body)
```

**Flow:** Supabase generates OTP → invokes `send-sms-hook` Edge Function → function calls MSG91 → MSG91 delivers SMS.

## 1.2 Verify OTP

```
POST /auth/v1/verify
Headers:
  apikey: {SUPABASE_ANON_KEY}
  Content-Type: application/json
Body:
  {
    "phone": "+919876543210",
    "token": "123456",
    "type": "sms"
  }
Response: 200 OK
  {
    "access_token": "...",
    "refresh_token": "...",
    "user": { ... }
  }
```

## 1.3 Refresh Session

```
POST /auth/v1/token?grant_type=refresh_token
Body: { "refresh_token": "..." }
Response: New access_token + refresh_token
```

## 1.4 Sign Out

```
POST /auth/v1/logout
Headers: Authorization: Bearer {JWT}
```

## 1.5 Password Sign-In (after first OTP signup)

```
POST /auth/v1/token?grant_type=password
Body:
  {
    "phone": "+919876543210",
    "password": "..."
  }
```

> **Note for password-based login:** Female users go through phone-entry → verification-status check → password entry. The verification status check happens via a `GET /rest/v1/females?phone=eq.<masked>` first; only on `verified` status does the app proceed to the password screen.

## 1.6 Forgot Password (OTP-based reset)

```
POST /auth/v1/recover
Body: { "phone": "+919876543210" }
```

Follow with `POST /auth/v1/verify` and then update password via:

```
PUT /auth/v1/user
Headers: Authorization: Bearer {JWT}
Body: { "password": "new_password" }
```

## 1.7 Change Password (authenticated)

```
PUT /auth/v1/user
Headers: Authorization: Bearer {JWT}
Body: { "password": "new_password" }
```

---

# 2. User Profile (Common)

## 2.1 Get current user profile

```
GET /rest/v1/users?id=eq.{auth.uid()}&select=*
Headers: Authorization: Bearer {JWT}
```

## 2.2 Update profile (name, avatar URL)

```
PATCH /rest/v1/users?id=eq.{auth.uid()}
Body: { "name": "...", "avatar_url": "..." }
```

## 2.3 Get signed Cloudinary upload params (for profile pic upload)

```
POST /functions/v1/upload-signature
Body: { "folder": "profile_pics", "user_id": "..." }
Response:
  {
    "signature": "...",
    "timestamp": ...,
    "api_key": "...",
    "cloud_name": "...",
    "folder": "profile_pics"
  }
```

App then uploads to `https://api.cloudinary.com/v1_1/{cloud_name}/image/upload` with these params, gets back a `secure_url`, and PATCHes `users.avatar_url`.

---

# 3. Female-Specific Endpoints

## 3.1 Submit verification photo

```
POST /functions/v1/female-submit-verification
Body: { "photo_url": "https://...supabase.../verification-photos/..." }
```

App first uploads the photo directly to Supabase Storage's `verification-photos` private bucket via:

```
POST /storage/v1/object/verification-photos/{user_id}/face.jpg
Headers: Authorization: Bearer {JWT}, Content-Type: image/jpeg
Body: <binary>
```

The function then sets `females.verification_status = 'pending'` and creates an entry in `verification_audit`.

## 3.2 Get my female profile (extended data)

```
GET /rest/v1/females?user_id=eq.{auth.uid()}&select=*
```

## 3.3 Toggle online/offline

```
PATCH /rest/v1/females?user_id=eq.{auth.uid()}
Body: { "online_status": "online" }    // or "offline"
```

This triggers a Postgres realtime event males subscribed to favourites can receive.

## 3.4 Update bank/UPI details

```
PATCH /rest/v1/females?user_id=eq.{auth.uid()}
Body:
  {
    "bank_account": { "holder_name": "...", "account_no": "...", "ifsc": "..." },
    "upi_id": "ramesh@upi"
  }
```

## 3.5 Get earnings dashboard data

```
GET /rest/v1/females?user_id=eq.{auth.uid()}&select=total_earnings,claimed_amount,requested_amount,available_balance,todays_earnings
```

For chat history (filtered by today/week/month):

```
GET /rest/v1/chat_sessions
  ?female_id=eq.{auth.uid()}
  &started_at=gte.{ISO_TIMESTAMP}
  &select=id,male:males(name,avatar_url),duration_seconds,started_at
  &order=started_at.desc
  &limit=20&offset=0
```

## 3.6 Request payout

```
POST /functions/v1/payout-request
Body: {}   // Always requests entire available_balance
Response:
  {
    "payout_id": "...",
    "amount": 450.00,
    "status": "pending"
  }
```

Returns 409 Conflict if a non-completed payout already exists for this female.

## 3.7 Get my payout history

```
GET /rest/v1/payouts?female_id=eq.{auth.uid()}&order=requested_at.desc
```

---

# 4. Male-Specific Endpoints

## 4.1 Get my male profile

```
GET /rest/v1/males?user_id=eq.{auth.uid()}&select=*
```

## 4.2 List available females (home screen)

```
GET /rest/v1/females
  ?online_status=in.(online,available)
  &verification_status=eq.verified
  &select=user_id,users(name,avatar_url),online_status,ratings_avg,favourited_count,age
  &order=online_status.asc,ratings_avg.desc
  &limit=20&offset=0
```

With optional search:

```
&users.name=ilike.*{search_query}*
```

## 4.3 Get female profile preview (when tapped)

```
GET /rest/v1/females?user_id=eq.{female_user_id}&select=user_id,users(name,avatar_url),age,ratings_avg,favourited_count,total_chats,bio,created_at,online_status
```

## 4.4 Favourite / unfavourite a female

```
# Add
POST /rest/v1/favourites
Body: { "male_id": "{auth.uid()}", "female_id": "..." }

# Remove
DELETE /rest/v1/favourites?male_id=eq.{auth.uid()}&female_id=eq.{female_id}
```

## 4.5 Get my favourites (for carousel)

```
GET /rest/v1/favourites
  ?male_id=eq.{auth.uid()}
  &select=female:females(user_id,users(name,avatar_url),online_status,ratings_avg)
  &order=created_at.desc
```

## 4.6 List coin packages

```
GET /rest/v1/coin_packages?is_active=eq.true&order=price_inr.asc
```

## 4.7 Create a Razorpay order for coin purchase

```
POST /functions/v1/razorpay-create-order
Body: { "package_id": "..." }
Response:
  {
    "razorpay_order_id": "order_xyz123",
    "amount_paise": 25000,
    "currency": "INR",
    "package": { "id": "...", "coin_amount": 250 }
  }
```

App then invokes Razorpay's mobile SDK with the `razorpay_order_id`.

## 4.8 Razorpay webhook (server-to-server, NOT called by app)

```
POST /functions/v1/razorpay-webhook
Headers: X-Razorpay-Signature: ...
Body: { "event": "payment.captured", "payload": { ... } }
```

On `payment.captured`, function credits coins to male's wallet, creates a `coin_transactions` row with `status = 'success'`.

## 4.9 Get transaction history

```
# Purchases
GET /rest/v1/coin_transactions
  ?male_id=eq.{auth.uid()}
  &type=eq.purchase
  &order=created_at.desc

# Spends
GET /rest/v1/coin_transactions
  ?male_id=eq.{auth.uid()}
  &type=eq.spend
  &select=*,female:females(user_id,users(name,avatar_url))
  &order=created_at.desc
```

---

# 5. Chat Requests (Phase 1 scope)

## 5.1 Male sends chat request

```
POST /functions/v1/chat-request-create
Body: { "female_id": "..." }
Response:
  {
    "request_id": "...",
    "status": "pending",
    "queue_position": 0     // 0 if delivered immediately
  }
```

Returns 402 Payment Required if male has insufficient coins, 404 if female offline, 429 if queue full.

## 5.2 Male cancels pending request

```
PATCH /rest/v1/chat_requests?id=eq.{request_id}&male_id=eq.{auth.uid()}
Body: { "status": "cancelled" }
```

## 5.3 Female responds to request (accept / decline)

```
POST /functions/v1/chat-request-respond
Body:
  {
    "request_id": "...",
    "action": "accept"    // or "decline"
  }
```

On `accept`, function creates a `chat_sessions` row and returns a `session_id` for Phase 2 chat init.

## 5.4 Realtime — female subscribes to incoming requests

```javascript
supabase
  .channel('chat_requests')
  .on('postgres_changes', {
    event: 'INSERT',
    schema: 'public',
    table: 'chat_requests',
    filter: `female_id=eq.${auth.uid()}`
  }, payload => showIncomingPopup(payload.new))
  .subscribe();
```

## 5.5 Realtime — male subscribes to his request status

```javascript
supabase
  .channel('my_requests')
  .on('postgres_changes', {
    event: 'UPDATE',
    schema: 'public',
    table: 'chat_requests',
    filter: `male_id=eq.${auth.uid()}`
  }, payload => handleStatusChange(payload.new))
  .subscribe();
```

## 5.6 Submit like/dislike rating (after chat ends)

```
POST /functions/v1/chat-rate
Body:
  {
    "chat_session_id": "...",
    "rating": "like",         // or "dislike"
    "comment": "..."          // optional
  }
```

Function updates the female's `ratings_avg` (recalculated from all ratings).

---

# 6. Notifications

## 6.1 List notifications

```
GET /rest/v1/notifications
  ?user_id=eq.{auth.uid()}
  &order=created_at.desc
  &limit=20&offset=0
```

## 6.2 Mark as read

```
PATCH /rest/v1/notifications?id=eq.{notification_id}
Body: { "is_read": true }
```

## 6.3 Mark all as read

```
PATCH /rest/v1/notifications?user_id=eq.{auth.uid()}&is_read=eq.false
Body: { "is_read": true }
```

## 6.4 Register FCM device token

```
POST /functions/v1/fcm-register
Body:
  {
    "token": "fcm_token_string",
    "platform": "android"   // or "ios"
  }
```

Function upserts into `fcm_tokens`, replacing any previous token for the same device.

## 6.5 Unregister FCM token (on logout)

```
DELETE /rest/v1/fcm_tokens?user_id=eq.{auth.uid()}&token=eq.{token}
```

---

# 7. Reports & Blocks

## 7.1 Submit a report

```
POST /rest/v1/reports
Body:
  {
    "reporter_id": "{auth.uid()}",
    "target_id": "...",
    "reason": "harassment",     // enum
    "comment": "..."             // optional
  }
```

## 7.2 Block a user

```
POST /rest/v1/blocks
Body: { "blocker_id": "{auth.uid()}", "blocked_id": "..." }
```

## 7.3 Unblock

```
DELETE /rest/v1/blocks?blocker_id=eq.{auth.uid()}&blocked_id=eq.{target_id}
```

## 7.4 Submit a support ticket

```
POST /functions/v1/support-ticket
Body:
  {
    "category": "payment",       // enum
    "description": "...",
    "screenshot_url": "..."      // optional, Cloudinary-uploaded
  }
```

---

# 8. Account Management

## 8.1 Soft-delete account

```
POST /functions/v1/account-delete
Body: { "password": "..." }
```

Function: validates password, checks for pending payouts (blocks deletion if any), sets `users.deleted_at = NOW()`, anonymizes PII, invalidates session.

## 8.2 Export my data (DPDP requirement)

```
POST /functions/v1/account-export
Response: { "download_url": "..." }   // signed URL to JSON dump, expires in 24h
```

---

# 9. Admin Endpoints (called from admin dashboard, not mobile)

Listed here for completeness. These endpoints require `role = 'admin'` claim in JWT.

## 9.1 Approve / reject female verification

```
POST /functions/v1/admin-verification-action
Body:
  {
    "female_id": "...",
    "action": "approve",        // or "reject"
    "notes": "..."
  }
```

## 9.2 Payout actions (two-stage)

```
POST /functions/v1/admin-payout-action
Body:
  {
    "payout_id": "...",
    "action": "approve",        // approve | complete | reject
    "notes": "..."
  }
```

- `approve` → status: `pending` → `approved`
- `complete` → status: `approved` → `completed` (after admin manually sends money)
- `reject` → status: any → `rejected` (with reason)

## 9.3 List pending verifications

```
GET /rest/v1/females
  ?verification_status=eq.pending
  &select=user_id,users(name,phone,avatar_url),created_at
  &order=created_at.asc
```

## 9.4 List payouts by status

```
GET /rest/v1/payouts?status=eq.pending&order=requested_at.asc
```

## 9.5 Admin user search

```
GET /rest/v1/users
  ?or=(name.ilike.*{q}*,phone.ilike.*{q}*)
  &role=eq.{male|female|all}
  &created_at=gte.{date}
  &order=created_at.desc
  &limit=50
```

## 9.6 Analytics summary

```
# Custom view in Postgres
GET /rest/v1/admin_analytics_summary
```

Returns aggregated counts: revenue, net profit, actual profit, pending payouts, total chat count, user counts by gender.

## 9.7 Chat transcript fetch

```
GET /rest/v1/chat_sessions?id=eq.{session_id}
GET /rest/v1/chat_messages?session_id=eq.{session_id}&order=sent_at.asc
```

Phase 2 will populate `chat_messages` table; for Phase 1 leave it empty.

---

# 10. External Direct Calls

## 10.1 Cloudinary Upload

```
POST https://api.cloudinary.com/v1_1/{cloud_name}/image/upload
Body (multipart/form-data):
  file: <binary>
  api_key: ...
  timestamp: ...
  signature: ...           // from /functions/v1/upload-signature
  folder: profile_pics
```

Response includes `secure_url` to save to DB.

## 10.2 Razorpay Checkout (mobile SDK)

Called from app code, not as HTTP. SDK takes `razorpay_order_id` from `/functions/v1/razorpay-create-order` and renders the native checkout sheet.

## 10.3 MSG91 Send OTP (called from `send-sms-hook` Edge Function, NOT from app)

```
POST https://control.msg91.com/api/v5/otp
Headers: authkey: {MSG91_AUTH_KEY}
Body:
  {
    "mobile": "919876543210",
    "template_id": "...",
    "otp": "123456"
  }
```

---

# Status Code Conventions

| Code | Meaning |
|---|---|
| 200 / 201 | Success |
| 204 | Success, no content (DELETE) |
| 400 | Bad request (validation error) |
| 401 | Not authenticated |
| 403 | Authenticated but forbidden (RLS rejection) |
| 404 | Resource not found |
| 409 | Conflict (e.g. duplicate payout request, female already verified) |
| 402 | Payment required (insufficient coins) |
| 422 | Unprocessable (business rule violation) |
| 429 | Rate limited (queue full, too many OTP attempts) |
| 500 | Server error |

---

# Generating Swagger / OpenAPI from this Document

Two options:

1. **Manual:** Convert each section above into an OpenAPI 3.0 path entry. Use `swagger-jsdoc` or write `openapi.yaml` by hand.
2. **Supabase auto-generated:** Supabase exposes `{SUPABASE_URL}/rest/v1/?apikey={ANON_KEY}` as an OpenAPI 2.0 spec for all PostgREST endpoints. Edge Functions need to be documented separately.

For the admin dashboard and external integrations, an OpenAPI spec is worth maintaining. For internal mobile app development, this markdown reference is usually sufficient.
