// HTTP helpers shared by every Edge Function (docs/api.md §1).

/** An error with our contract's shape: { "error": { code, message, details } }. */
export class ApiError extends Error {
  constructor(
    public status: number,
    public code: string,
    message: string,
    public details?: Record<string, unknown>,
  ) {
    super(message);
  }
}

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

/** ISO 8601 UTC with whole seconds, e.g. "2026-11-21T17:16:04Z" (docs/api.md §1). */
export function iso(d: Date | string | null | undefined): string | null {
  if (d == null) return null;
  return new Date(d).toISOString().replace(/\.\d{3}Z$/, "Z");
}

export function invalid(fields: string[], message = `Missing or invalid: ${fields.join(", ")}.`): ApiError {
  return new ApiError(400, "invalid_request", message, { fields });
}

/** Wraps a handler: method check, error envelope, and a 500 for anything unexpected. */
export function handle(
  methods: string[],
  fn: (req: Request) => Promise<Response>,
): (req: Request) => Promise<Response> {
  return async (req) => {
    try {
      if (!methods.includes(req.method)) {
        throw new ApiError(405, "method_not_allowed", `Use ${methods.join(" or ")}.`);
      }
      return await fn(req);
    } catch (e) {
      if (e instanceof ApiError) {
        const error: Record<string, unknown> = { code: e.code, message: e.message };
        if (e.details) error.details = e.details;
        return json({ error }, e.status);
      }
      console.error(e);
      return json({ error: { code: "internal", message: "Something went wrong. Try again later." } }, 500);
    }
  };
}

/** Reads a JSON body, enforcing a size limit (413 payload_too_large / batch limits). */
export async function readJson(req: Request, maxBytes: number): Promise<Record<string, unknown>> {
  const text = await req.text();
  if (text.length > maxBytes) {
    throw new ApiError(413, "payload_too_large", `Request body is over ${Math.round(maxBytes / 1e6)} MB.`);
  }
  try {
    const body = JSON.parse(text);
    if (body && typeof body === "object" && !Array.isArray(body)) return body;
  } catch { /* fall through */ }
  throw new ApiError(400, "invalid_request", "Body must be a JSON object.");
}

export const isNum = (v: unknown): v is number => typeof v === "number" && Number.isFinite(v);
export const isLat = (v: unknown): v is number => isNum(v) && v >= -90 && v <= 90;
export const isLng = (v: unknown): v is number => isNum(v) && v >= -180 && v <= 180;
export const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
