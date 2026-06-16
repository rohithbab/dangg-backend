/**
 * Input validation helpers built on Zod. Every Edge Function should call
 * `parseBody` or `parseQuery` before touching the database — never trust
 * the wire format.
 *
 *   const Body = z.object({ packageId: z.string().uuid() });
 *   const { packageId } = await parseBody(req, Body);
 *
 * Validation failures throw a `ValidationError` with structured `details`
 * (a list of `{ path, message }` entries) that the central `handler()`
 * translates into the standard error envelope.
 */
import { z, type ZodError, type ZodSchema } from 'zod';
import { ValidationError } from './errors.ts';

/**
 * Parse and validate a JSON request body against a Zod schema. Throws
 * `ValidationError` on malformed JSON or schema failure.
 */
export async function parseBody<T>(req: Request, schema: ZodSchema<T>): Promise<T> {
  let json: unknown;
  try {
    json = await req.json();
  } catch {
    throw new ValidationError('Invalid JSON body');
  }

  const result = schema.safeParse(json);
  if (!result.success) {
    throw new ValidationError('Validation failed', formatZodError(result.error));
  }
  return result.data;
}

/**
 * Parse and validate URL search parameters against a Zod schema. All
 * values come through as strings — use `z.coerce.number()` etc. in the
 * schema to convert.
 */
export function parseQuery<T>(req: Request, schema: ZodSchema<T>): T {
  const params = Object.fromEntries(new URL(req.url).searchParams);
  const result = schema.safeParse(params);
  if (!result.success) {
    throw new ValidationError('Invalid query parameters', formatZodError(result.error));
  }
  return result.data;
}

function formatZodError(error: ZodError): Array<{ path: string; message: string }> {
  return error.issues.map((issue) => ({
    path: issue.path.join('.'),
    message: issue.message,
  }));
}

export { z };
