/**
 * Auth helpers for Edge Functions.
 *
 * Every authenticated endpoint should start with `requireAuth(req)` and
 * (if it's role-gated) follow with `requireRole(user, 'female')` etc.
 * Throwing the typed errors lets the central `handler()` wrapper return
 * the correct HTTP status without per-function boilerplate.
 */
import { ForbiddenError, UnauthorizedError } from './errors.ts';
import { userClient } from './supabase-client.ts';

export type UserRole = 'female' | 'male' | 'admin';

export interface AuthenticatedUser {
  /** Supabase auth.users.id (UUID). */
  id: string;
  /** E.164 phone number, e.g. `+919876543210`. May be `''` if missing. */
  phone: string;
  /** Resolved from `user_metadata.role` set during signup. */
  role: UserRole;
}

/**
 * Verify the request carries a valid JWT and return the authenticated user.
 * Throws `UnauthorizedError` if the token is missing, expired, or invalid,
 * or if the user's metadata lacks a valid role claim.
 */
export async function requireAuth(req: Request): Promise<AuthenticatedUser> {
  const client = userClient(req);
  const { data: { user }, error } = await client.auth.getUser();

  if (error || !user) {
    throw new UnauthorizedError('Authentication required');
  }

  const rawRole = user.user_metadata?.role;
  if (rawRole !== 'female' && rawRole !== 'male' && rawRole !== 'admin') {
    throw new UnauthorizedError('User role missing or invalid in metadata');
  }

  return {
    id: user.id,
    phone: user.phone ?? '',
    role: rawRole,
  };
}

/**
 * Assert the authenticated user has one of the required roles. Throws
 * `ForbiddenError` if not.
 */
export function requireRole(user: AuthenticatedUser, ...roles: UserRole[]): void {
  if (!roles.includes(user.role)) {
    throw new ForbiddenError(
      `This action requires role: ${roles.join(' or ')}`,
    );
  }
}
