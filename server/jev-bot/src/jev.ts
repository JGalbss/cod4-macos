/** Protocol: https://docs.typesafe.ai/introduction/quickstart */
export const JEV_ENDPOINT = "https://api.typesafe.ai/v1/systemone";

export type JevQuestion =
  | { type: "choice"; instructions: string; criteria: Record<string, string | null> }
  | { type: "noul"; instructions: string };
export type JevQuestions = Record<string, JevQuestion>;
export type JevAnswer =
  | { type: "choice"; choice: string; confidence: number; probabilities: Record<string, number> }
  | { type: "noul"; noul: number };
export interface JevResult {
  model: string;
  answers: Record<string, JevAnswer>;
  usage: { input_tokens: number; output_tokens: number };
}

export type JevErrorCode = "configuration" | "auth" | "billing" | "rate_limit" | "unavailable" | "http" | "timeout" | "network" | "invalid_response";
export class JevError extends Error {
  readonly code: JevErrorCode;
  readonly status?: number;

  constructor(code: JevErrorCode, status?: number) {
    // Never include the server body, request headers, credentials, or original error.
    super(`Jev request failed: ${code}${status === undefined ? "" : ` (HTTP ${status})`}`);
    this.name = "JevError";
    this.code = code;
    this.status = status;
  }
}

export interface JevClientOptions {
  apiKey?: string;
  model?: string;
  timeoutMs?: number;
  /** Dependency injection for local tests. Real requests always use JEV_ENDPOINT. */
  fetch?: typeof globalThis.fetch;
}

export function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function isProbability(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value) && value >= 0 && value <= 1;
}

/** Runtime validation remains necessary even though the provider promises typed output. */
export function validateJevResult(value: unknown, questions: JevQuestions): JevResult {
  const invalid = () => { throw new JevError("invalid_response"); };
  if (!isRecord(value) || !isRecord(value.answers) || typeof value.model !== "string" || value.model.length > 128 || !isRecord(value.usage)) return invalid();
  const usage = value.usage;
  if (![usage.input_tokens, usage.output_tokens].every(v => typeof v === "number" && Number.isSafeInteger(v) && v >= 0)) return invalid();
  const answers: Record<string, JevAnswer> = {};
  for (const [name, question] of Object.entries(questions)) {
    const answer = value.answers[name];
    if (!isRecord(answer) || answer.type !== question.type) return invalid();
    if (question.type === "noul") {
      if (!isProbability(answer.noul)) return invalid();
      answers[name] = { type: "noul", noul: answer.noul };
    } else {
      if (typeof answer.choice !== "string" || !Object.hasOwn(question.criteria, answer.choice) || !isProbability(answer.confidence) || !isRecord(answer.probabilities)) return invalid();
      const probabilities: Record<string, number> = {};
      for (const option of Object.keys(question.criteria)) {
        const probability = answer.probabilities[option];
        if (!isProbability(probability)) return invalid();
        probabilities[option] = probability;
      }
      answers[name] = { type: "choice", choice: answer.choice, confidence: answer.confidence, probabilities };
    }
  }
  return { model: value.model, answers, usage: { input_tokens: usage.input_tokens as number, output_tokens: usage.output_tokens as number } };
}

async function readBoundedJson(response: Response): Promise<unknown> {
  if (!response.body) throw new JevError("invalid_response");
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > 128 * 1024) {
        void reader.cancel().catch(() => {});
        throw new JevError("invalid_response");
      }
      chunks.push(value);
    }
    return JSON.parse(Buffer.concat(chunks).toString("utf8"));
  } catch (error) {
    if (error instanceof JevError) throw error;
    throw new JevError("invalid_response");
  } finally {
    reader.releaseLock();
  }
}

export class JevClient {
  #apiKey: string;
  #fetch: typeof globalThis.fetch;
  readonly model: string;
  readonly timeoutMs: number;

  constructor(options: JevClientOptions = {}) {
    const key = options.apiKey ?? process.env.TYPESAFE_API_KEY;
    const timeoutMs = options.timeoutMs ?? 900;
    const model = options.model ?? process.env.JEV_MODEL ?? "jev-latest";
    if (!key?.trim() || /[\r\n]/.test(key) || !Number.isFinite(timeoutMs) || timeoutMs < 1 || timeoutMs > 30_000 || !/^[a-zA-Z0-9._-]{1,128}$/.test(model)) throw new JevError("configuration");
    this.#apiKey = key.trim();
    this.#fetch = options.fetch ?? globalThis.fetch;
    this.timeoutMs = timeoutMs;
    this.model = model;
  }

  async evaluate(state: unknown, questions: JevQuestions): Promise<JevResult> {
    const controller = new AbortController();
    let timer: ReturnType<typeof setTimeout> | undefined;
    const deadline = new Promise<never>((_, reject) => {
      timer = setTimeout(() => {
        controller.abort();
        reject(new JevError("timeout"));
      }, this.timeoutMs);
    });
    const request = async (): Promise<JevResult> => {
      const response = await this.#fetch(JEV_ENDPOINT, {
        method: "POST",
        redirect: "error",
        headers: { Authorization: `Bearer ${this.#apiKey}`, "Content-Type": "application/json", Accept: "application/json" },
        body: JSON.stringify({ model: this.model, state, questions }),
        signal: controller.signal,
      });
      if (!response.ok) {
        void response.body?.cancel().catch(() => {});
        const code = response.status === 402 ? "billing" : response.status === 401 || response.status === 403 ? "auth" : response.status === 429 ? "rate_limit" : [502, 503, 504, 529].includes(response.status) ? "unavailable" : "http";
        throw new JevError(code, response.status);
      }
      return validateJevResult(await readBoundedJson(response), questions);
    };
    try {
      return await Promise.race([request(), deadline]);
    } catch (error) {
      if (controller.signal.aborted) throw new JevError("timeout");
      if (error instanceof JevError) throw error;
      throw new JevError("network");
    } finally {
      clearTimeout(timer);
    }
  }
}
