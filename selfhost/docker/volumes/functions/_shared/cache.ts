/**
 * Redis cache helper for Edge Functions.
 *
 * Connects lazily to REDIS_URL (the `redis` container) and degrades
 * GRACEFULLY: every method no-ops / returns null when Redis is unset or
 * unreachable, so callers can cache without guarding. Values are JSON.
 *
 *   const cached = await cacheGet<Foo>('foo:123');
 *   if (cached) return cached;
 *   const fresh = await load();
 *   await cacheSet('foo:123', fresh, 60); // TTL seconds
 */
import { connect, type Redis } from 'https://deno.land/x/redis@v0.32.0/mod.ts';
import { logger } from './logger.ts';

const REDIS_URL = Deno.env.get('REDIS_URL') ?? '';

let clientPromise: Promise<Redis | null> | null = null;

async function getClient(): Promise<Redis | null> {
  if (!REDIS_URL) {
    return null;
  }
  if (!clientPromise) {
    clientPromise = (async () => {
      try {
        const u = new URL(REDIS_URL);
        return await connect({
          hostname: u.hostname,
          port: Number(u.port || '6379'),
          password: u.password || undefined,
        });
      } catch (e) {
        logger.warn('cache: redis connect failed', { error: String(e) });
        return null;
      }
    })();
  }
  return await clientPromise;
}

/** Returns the cached JSON value for `key`, or null on miss/error. */
export async function cacheGet<T = unknown>(key: string): Promise<T | null> {
  try {
    const c = await getClient();
    if (!c) {
      return null;
    }
    const raw = await c.get(key);
    return raw ? (JSON.parse(raw) as T) : null;
  } catch {
    return null;
  }
}

/** Caches `value` (JSON) under `key` with a TTL in seconds. Best-effort. */
export async function cacheSet(key: string, value: unknown, ttlSeconds = 60): Promise<void> {
  try {
    const c = await getClient();
    if (!c) {
      return;
    }
    await c.set(key, JSON.stringify(value), { ex: ttlSeconds });
  } catch {
    /* best-effort */
  }
}

/** Deletes one or more keys. Best-effort. */
export async function cacheDel(...keys: string[]): Promise<void> {
  try {
    const c = await getClient();
    if (!c || keys.length === 0) {
      return;
    }
    await c.del(...keys);
  } catch {
    /* best-effort */
  }
}

export interface RateLimitResult {
  allowed: boolean;
  remaining: number;
  count: number;
}

/**
 * Fixed-window rate limiter — allows up to `limit` hits per `windowSeconds`
 * for `key`. FAILS OPEN (allowed) when Redis is unset/unreachable, so an infra
 * blip never blocks a legitimate flow; treat it as an abuse guard, not a hard
 * security control.
 */
export async function rateLimit(
  key: string,
  limit: number,
  windowSeconds: number,
): Promise<RateLimitResult> {
  try {
    const c = await getClient();
    if (!c) {
      return { allowed: true, remaining: limit, count: 0 };
    }
    const rlKey = `rl:${key}`;
    const count = await c.incr(rlKey);
    if (count === 1) {
      // First hit in this window — start the TTL.
      await c.expire(rlKey, windowSeconds);
    }
    return { allowed: count <= limit, remaining: Math.max(0, limit - count), count };
  } catch {
    return { allowed: true, remaining: limit, count: 0 };
  }
}
