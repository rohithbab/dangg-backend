/**
 * Typed error hierarchy used by every Edge Function.
 *
 * Each subclass maps to a specific HTTP status code via `statusCode`. The
 * `code` field is a stable machine-readable identifier — the client logic
 * keys off it, not the human-readable `message`.
 *
 * Always throw a specific subclass — never the abstract `AppError`. The
 * central handler in `responses.ts` converts these to the standard error
 * envelope; anything else gets wrapped as `InternalError`.
 */
export abstract class AppError extends Error {
  abstract readonly statusCode: number;
  abstract readonly code: string;

  constructor(message: string, public readonly details?: unknown) {
    super(message);
    this.name = this.constructor.name;
  }
}

/** 400 — request body / params failed validation. */
export class ValidationError extends AppError {
  readonly statusCode = 400;
  readonly code = 'VALIDATION_ERROR';
}

/** 401 — missing or invalid JWT. Client should re-authenticate. */
export class UnauthorizedError extends AppError {
  readonly statusCode = 401;
  readonly code = 'UNAUTHORIZED';
}

/** 402 — insufficient coins, payment required for the requested action. */
export class PaymentRequiredError extends AppError {
  readonly statusCode = 402;
  readonly code = 'PAYMENT_REQUIRED';
}

/** 403 — authenticated but the caller's role / ownership forbids the action. */
export class ForbiddenError extends AppError {
  readonly statusCode = 403;
  readonly code = 'FORBIDDEN';
}

/** 404 — resource doesn't exist (or the caller can't see it). */
export class NotFoundError extends AppError {
  readonly statusCode = 404;
  readonly code = 'NOT_FOUND';
}

/** 409 — state conflict (e.g. payout already pending, duplicate request). */
export class ConflictError extends AppError {
  readonly statusCode = 409;
  readonly code = 'CONFLICT';
}

/** 429 — rate limited (queue full, too many OTP attempts, etc.). */
export class RateLimitError extends AppError {
  readonly statusCode = 429;
  readonly code = 'RATE_LIMIT';
}

/** 500 — unexpected. Anything we wrap as `InternalError` is a bug to fix. */
export class InternalError extends AppError {
  readonly statusCode = 500;
  readonly code = 'INTERNAL_ERROR';
}

/** 503 — downstream dependency (MSG91, Razorpay, FCM) is down. */
export class ServiceUnavailableError extends AppError {
  readonly statusCode = 503;
  readonly code = 'SERVICE_UNAVAILABLE';
}
