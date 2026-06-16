/**
 * Response envelopes + central error-handling wrapper.
 *
 * Every Edge Function returns `{ ok: true, data: ... }` on success or
 * `{ ok: false, error: { code, message, details? } }` on failure. The
 * client knows which shape to expect from the `ok` discriminator.
 *
 * Wrap your handler with `handler(...)` and never write `try/catch` in
 * individual functions — let typed `AppError` subclasses propagate.
 */
import { corsHeaders } from './cors.ts';
import { AppError, InternalError } from './errors.ts';
import { logger } from './logger.ts';

const jsonHeaders = {
  ...corsHeaders,
  'Content-Type': 'application/json',
} as const;

/** Successful response envelope. Defaults to HTTP 200; pass 201 for creates. */
export function ok<T>(data: T, status = 200): Response {
  return new Response(JSON.stringify({ ok: true, data }), {
    status,
    headers: jsonHeaders,
  });
}

/** Error response envelope. Status code comes from the `AppError` subclass. */
export function err(error: AppError): Response {
  return new Response(
    JSON.stringify({
      ok: false,
      error: {
        code: error.code,
        message: error.message,
        details: error.details,
      },
    }),
    { status: error.statusCode, headers: jsonHeaders },
  );
}

/**
 * Wrap an Edge Function handler with central error handling. Catches
 * `AppError` instances and converts them to error envelopes; logs anything
 * else and returns a generic 500.
 *
 * Use at the top of every function:
 *
 *   Deno.serve(handler(async (req) => {
 *     const preflight = handlePreflight(req);
 *     if (preflight) return preflight;
 *     ...
 *     return ok({ ... });
 *   }));
 */
export function handler(
  fn: (req: Request) => Response | Promise<Response>,
): (req: Request) => Promise<Response> {
  return async (req: Request) => {
    try {
      return await fn(req);
    } catch (error: unknown) {
      if (error instanceof AppError) {
        logger.warn('Handled application error', {
          code: error.code,
          message: error.message,
          path: new URL(req.url).pathname,
        });
        return err(error);
      }
      logger.error('Unhandled error in Edge Function', {
        path: new URL(req.url).pathname,
        error: error instanceof Error
          ? { name: error.name, message: error.message, stack: error.stack }
          : String(error),
      });
      return err(new InternalError('Something went wrong. Please try again.'));
    }
  };
}
