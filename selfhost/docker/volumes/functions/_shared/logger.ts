/**
 * Structured logger. Every line is a single JSON object written to stdout —
 * Supabase's log UI parses these natively and they're easy to grep.
 *
 * Never call `console.log` directly from a handler; always use `logger.*`
 * so logs include the timestamp, level, and any context you pass.
 *
 * The log level is read once at module load from `LOG_LEVEL`. Default
 * is `info`. Allowed values: `debug`, `info`, `warn`, `error`.
 */
type LogLevel = 'debug' | 'info' | 'warn' | 'error';

const levelOrder: Record<LogLevel, number> = {
  debug: 0,
  info: 1,
  warn: 2,
  error: 3,
};

function readLevel(): LogLevel {
  const raw = Deno.env.get('LOG_LEVEL')?.toLowerCase();
  if (raw === 'debug' || raw === 'info' || raw === 'warn' || raw === 'error') {
    return raw;
  }
  return 'info';
}

const currentLevel: LogLevel = readLevel();

function emit(level: LogLevel, message: string, context?: Record<string, unknown>): void {
  if (levelOrder[level] < levelOrder[currentLevel]) {
    return;
  }
  const entry = {
    timestamp: new Date().toISOString(),
    level,
    message,
    ...context,
  };
  // eslint-disable-next-line no-console — this IS the console wrapper.
  console.log(JSON.stringify(entry));
}

export const logger = {
  debug: (msg: string, ctx?: Record<string, unknown>): void => emit('debug', msg, ctx),
  info: (msg: string, ctx?: Record<string, unknown>): void => emit('info', msg, ctx),
  warn: (msg: string, ctx?: Record<string, unknown>): void => emit('warn', msg, ctx),
  error: (msg: string, ctx?: Record<string, unknown>): void => emit('error', msg, ctx),
};
