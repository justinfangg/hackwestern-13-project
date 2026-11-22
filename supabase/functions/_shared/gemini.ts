// Photo verification with Gemini (docs/api.md §4). Called only from verify-quest.
// Gemini is intermittently overloaded (503) and slow, so: low thinking, JSON-only output,
// up to 3 tries on transient errors, and a hard ~10 s total budget. Throws VerifierUnavailable
// if it can't get an answer, which the caller turns into 502 verifier_unavailable (no attempt used).

import { describeError, type Logger } from "./log.ts";

export class VerifierUnavailable extends Error {}

export interface Verdict {
  isMatch: boolean;
  confidence: number;
  reason: string;
}

const MODEL = Deno.env.get("GEMINI_MODEL") ?? "gemini-3.8-flash";
const BUDGET_MS = Number(Deno.env.get("GEMINI_BUDGET_MS") ?? 10_000);
const TRANSIENT = new Set([429, 500, 503, 504]);

const prompt = (category: string, hint: string) => `You verify photos for a real-world scavenger hunt.
Today's object: a ${category.replaceAll("_", " ")}. Hint the player was given: "${hint}".

Does this photo show a real, physical ${category.replaceAll("_", " ")}, photographed in person with a phone camera?
Answer is_match = false if the object is missing, is a different kind of object, or if the photo shows a screen,
monitor, printout, drawing, toy or model instead of the real thing.

Return JSON only:
- is_match: boolean
- confidence: number from 0 to 1 (how sure you are of the whole answer)
- reason: one short, friendly sentence for the player (max 120 characters). If rejected, say what to fix.`;

export async function verifyPhoto(
  photoBase64: string,
  category: string,
  hint: string,
  log?: Logger,
): Promise<Verdict> {
  const key = Deno.env.get("GEMINI_API_KEY");
  if (!key) {
    log?.error("gemini.no_api_key");
    throw new VerifierUnavailable("GEMINI_API_KEY is not set");
  }

  const body = JSON.stringify({
    contents: [{
      role: "user",
      parts: [
        { inline_data: { mime_type: "image/jpeg", data: photoBase64 } },
        { text: prompt(category, hint) },
      ],
    }],
    generationConfig: {
      temperature: 0,
      responseMimeType: "application/json",
      responseSchema: {
        type: "OBJECT",
        properties: {
          is_match: { type: "BOOLEAN" },
          confidence: { type: "NUMBER" },
          reason: { type: "STRING" },
        },
        required: ["is_match", "confidence", "reason"],
      },
      thinkingConfig: { thinkingLevel: "low" },
    },
  });

  const started = performance.now();
  const sinceStart = () => Math.round(performance.now() - started);
  const deadline = Date.now() + BUDGET_MS;
  log?.info("gemini.start", {
    model: MODEL,
    budget_ms: BUDGET_MS,
    category,
    photo_kb: Math.round(photoBase64.length * 0.75 / 1024),
    request_kb: Math.round(body.length / 1024),
  });

  let lastError = "no attempt";
  let attempts = 0;
  for (let attempt = 0; attempt < 3 && Date.now() < deadline - 500; attempt++) {
    if (attempt > 0) {
      const backoff = 400 * attempt;
      log?.info("gemini.backoff", { attempt: attempt + 1, backoff_ms: backoff, last_error: lastError });
      await new Promise((r) => setTimeout(r, backoff));
    }
    attempts++;
    const timeoutMs = Math.max(500, deadline - Date.now());
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    const t0 = performance.now();
    const ms = () => Math.round(performance.now() - t0);
    log?.info("gemini.attempt", { attempt: attempt + 1, timeout_ms: timeoutMs, total_ms: sinceStart() });
    try {
      const res = await fetch(
        `https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:generateContent`,
        { method: "POST", headers: { "Content-Type": "application/json", "x-goog-api-key": key }, body, signal: controller.signal },
      );
      const headersMs = ms();
      const raw = await res.text();
      const responseFields = {
        attempt: attempt + 1,
        status: res.status,
        headers_ms: headersMs,
        attempt_ms: ms(),
        total_ms: sinceStart(),
        response_kb: Math.round(raw.length / 1024),
        server_timing: res.headers.get("server-timing") ?? undefined,
        google_request_id: res.headers.get("x-request-id") ?? res.headers.get("x-goog-request-id") ?? undefined,
      };
      if (!res.ok) {
        lastError = `HTTP ${res.status}`;
        // An empty 404 is how Gemini sometimes reports overload; treat it as transient too.
        const transient = TRANSIENT.has(res.status) || res.status === 404;
        log?.warn("gemini.http_error", { ...responseFields, transient, body: raw.slice(0, 1000) });
        if (transient) continue;
        throw new VerifierUnavailable(`${lastError}: ${raw.slice(0, 200)}`);
      }

      let data;
      try {
        data = JSON.parse(raw);
      } catch {
        lastError = "response was not JSON";
        log?.warn("gemini.bad_json", { ...responseFields, body: raw.slice(0, 1000) });
        continue;
      }
      const candidate = data?.candidates?.[0];
      const text: string | undefined = candidate?.content?.parts?.find((p: { text?: string }) => p.text)?.text;
      const resultFields = {
        ...responseFields,
        model_version: data?.modelVersion,
        finish_reason: candidate?.finishReason,
        block_reason: data?.promptFeedback?.blockReason,
        safety: candidate?.safetyRatings?.filter((r: { blocked?: boolean }) => r.blocked),
        usage: data?.usageMetadata,
      };
      let parsed;
      try {
        parsed = text ? JSON.parse(text) : null;
      } catch {
        parsed = null;
      }
      if (typeof parsed?.is_match !== "boolean" || typeof parsed?.confidence !== "number") {
        lastError = text ? "unparseable model output" : `no text in response (finish_reason ${candidate?.finishReason ?? "none"})`;
        log?.warn("gemini.unparseable", { ...resultFields, text: text?.slice(0, 500), body: text ? undefined : raw.slice(0, 1000) });
        continue;
      }
      const verdict = {
        isMatch: parsed.is_match,
        confidence: Math.min(1, Math.max(0, parsed.confidence)),
        reason: String(parsed.reason ?? "").slice(0, 200) || (parsed.is_match ? "Found it!" : "That doesn't look like it."),
      };
      log?.info("gemini.verdict", { ...resultFields, is_match: verdict.isMatch, confidence: verdict.confidence, reason: verdict.reason });
      return verdict;
    } catch (e) {
      if (e instanceof VerifierUnavailable) throw e;
      if (controller.signal.aborted) {
        lastError = `timed out after ${ms()} ms waiting for Gemini (budget ${BUDGET_MS} ms, ${sinceStart()} ms used)`;
        log?.warn("gemini.timeout", { attempt: attempt + 1, attempt_ms: ms(), timeout_ms: timeoutMs, total_ms: sinceStart() });
      } else {
        lastError = e instanceof Error ? e.message : String(e);
        log?.warn("gemini.fetch_failed", { attempt: attempt + 1, attempt_ms: ms(), total_ms: sinceStart(), ...describeError(e) });
      }
    } finally {
      clearTimeout(timer);
    }
  }
  log?.error("gemini.gave_up", {
    attempts,
    total_ms: sinceStart(),
    budget_ms: BUDGET_MS,
    budget_exhausted: Date.now() >= deadline - 500,
    last_error: lastError,
  });
  throw new VerifierUnavailable(lastError);
}
