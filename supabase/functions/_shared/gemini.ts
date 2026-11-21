// Photo verification with Gemini (docs/api.md §4). Called only from verify-quest.
// Gemini is intermittently overloaded (503) and slow, so: low thinking, JSON-only output,
// up to 3 tries on transient errors, and a hard ~10 s total budget. Throws VerifierUnavailable
// if it can't get an answer, which the caller turns into 502 verifier_unavailable (no attempt used).

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

export async function verifyPhoto(photoBase64: string, category: string, hint: string): Promise<Verdict> {
  const key = Deno.env.get("GEMINI_API_KEY");
  if (!key) throw new VerifierUnavailable("GEMINI_API_KEY is not set");

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

  const deadline = Date.now() + BUDGET_MS;
  let lastError = "no attempt";
  for (let attempt = 0; attempt < 3 && Date.now() < deadline - 500; attempt++) {
    if (attempt > 0) await new Promise((r) => setTimeout(r, 400 * attempt));
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), Math.max(500, deadline - Date.now()));
    try {
      const res = await fetch(
        `https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:generateContent`,
        { method: "POST", headers: { "Content-Type": "application/json", "x-goog-api-key": key }, body, signal: controller.signal },
      );
      if (!res.ok) {
        lastError = `HTTP ${res.status}`;
        // An empty 404 is how Gemini sometimes reports overload; treat it as transient too.
        if (TRANSIENT.has(res.status) || res.status === 404) continue;
        throw new VerifierUnavailable(`${lastError}: ${(await res.text()).slice(0, 200)}`);
      }
      const data = await res.json();
      const text: string | undefined = data?.candidates?.[0]?.content?.parts?.find((p: { text?: string }) => p.text)?.text;
      const parsed = text ? JSON.parse(text) : null;
      if (typeof parsed?.is_match !== "boolean" || typeof parsed?.confidence !== "number") {
        lastError = "unparseable model output";
        continue;
      }
      return {
        isMatch: parsed.is_match,
        confidence: Math.min(1, Math.max(0, parsed.confidence)),
        reason: String(parsed.reason ?? "").slice(0, 200) || (parsed.is_match ? "Found it!" : "That doesn't look like it."),
      };
    } catch (e) {
      if (e instanceof VerifierUnavailable) throw e;
      lastError = e instanceof Error ? e.message : String(e);
    } finally {
      clearTimeout(timer);
    }
  }
  throw new VerifierUnavailable(lastError);
}
