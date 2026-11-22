// Structured logs for Edge Functions: one JSON object per line, so the Supabase log explorer can
// search and filter on fields (e.g. `req`, `event`, `ms`). Never log secrets or image data.

export type Fields = Record<string, unknown>;

export interface Logger {
  /** Short id shared by every line of one request. */
  readonly req: string;
  info(event: string, fields?: Fields): void;
  warn(event: string, fields?: Fields): void;
  error(event: string, fields?: Fields): void;
  /** Milliseconds since the logger was created (the request started). */
  elapsed(): number;
}

export function logger(fn: string): Logger {
  const req = crypto.randomUUID().slice(0, 8);
  const start = performance.now();
  const line = (level: string, event: string, fields?: Fields) =>
    JSON.stringify({ fn, req, level, event, t_ms: Math.round(performance.now() - start), ...fields });
  return {
    req,
    info: (event, fields) => console.log(line("info", event, fields)),
    warn: (event, fields) => console.warn(line("warn", event, fields)),
    error: (event, fields) => console.error(line("error", event, fields)),
    elapsed: () => Math.round(performance.now() - start),
  };
}

/** Message, name and (trimmed) stack of anything thrown, for a log line. */
export function describeError(e: unknown): Fields {
  if (e instanceof Error) {
    return {
      error_name: e.name,
      error_message: e.message,
      error_cause: e.cause instanceof Error ? e.cause.message : e.cause ?? undefined,
      stack: e.stack?.split("\n").slice(0, 6).join(" | "),
    };
  }
  return { error_message: String(e) };
}
