/**
 * Tangerene Proxy / Adapter Worker
 *
 * The macOS app speaks the Anthropic Messages API (see ClaudeAPI.swift). This
 * Worker translates that into an OpenAI-compatible Chat Completions request and
 * forwards it to a self-hosted vision model (Qwen2.5-VL on GCP, served by vLLM/
 * Ollama/TGI), then translates the streamed response back into the small slice
 * of Anthropic SSE the app actually parses (`content_block_delta` / `text_delta`).
 *
 * Net effect: the app is unchanged, but the "brain" is now your own model — no
 * Anthropic key required.
 *
 * Config (set in wrangler.toml [vars] or as secrets):
 *   LLM_ENDPOINT  full URL of the OpenAI-compatible chat-completions endpoint
 *                 e.g. https://your-gcp-host/v1/chat/completions
 *   LLM_MODEL     model name to request, e.g. "Qwen/Qwen2.5-VL-7B-Instruct"
 *   LLM_API_KEY   (optional) bearer token, if your endpoint requires auth
 *
 * Routes:
 *   POST /chat → your model (vision + streaming chat)
 */

interface Env {
  LLM_ENDPOINT: string;
  LLM_MODEL: string;
  LLM_API_KEY?: string;
}

// ---- Anthropic request shapes the app sends (loosely typed) ----
interface AnthropicImageSource {
  type: string;
  media_type: string;
  data: string;
}
interface AnthropicContentBlock {
  type: string;
  text?: string;
  source?: AnthropicImageSource;
}
interface AnthropicMessage {
  role: string;
  content: string | AnthropicContentBlock[];
}
interface AnthropicRequest {
  model?: string;
  max_tokens?: number;
  system?: string;
  stream?: boolean;
  messages?: AnthropicMessage[];
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (request.method !== "POST") {
      return new Response("Method not allowed", { status: 405 });
    }

    try {
      if (url.pathname === "/chat") {
        return await handleChat(request, env);
      }
    } catch (error) {
      console.error(`[${url.pathname}] Unhandled error:`, error);
      return new Response(
        JSON.stringify({ error: String(error) }),
        { status: 500, headers: { "content-type": "application/json" } }
      );
    }

    return new Response("Not found", { status: 404 });
  },
};

async function handleChat(request: Request, env: Env): Promise<Response> {
  if (!env.LLM_ENDPOINT || !env.LLM_MODEL) {
    return new Response(
      JSON.stringify({ error: "LLM_ENDPOINT and LLM_MODEL must be configured on the Worker." }),
      { status: 500, headers: { "content-type": "application/json" } }
    );
  }

  const anthropicBody = (await request.json()) as AnthropicRequest;

  const openaiBody = {
    model: env.LLM_MODEL,
    max_tokens: anthropicBody.max_tokens ?? 1024,
    stream: true,
    messages: toOpenAIMessages(anthropicBody),
  };

  const headers: Record<string, string> = { "content-type": "application/json" };
  if (env.LLM_API_KEY) {
    headers["authorization"] = `Bearer ${env.LLM_API_KEY}`;
  }

  const upstream = await fetch(env.LLM_ENDPOINT, {
    method: "POST",
    headers,
    body: JSON.stringify(openaiBody),
  });

  if (!upstream.ok || !upstream.body) {
    const errorBody = await upstream.text();
    console.error(`[/chat] LLM endpoint error ${upstream.status}: ${errorBody}`);
    return new Response(errorBody || `LLM endpoint error ${upstream.status}`, {
      status: upstream.status || 502,
      headers: { "content-type": "application/json" },
    });
  }

  // Translate the OpenAI SSE stream into the Anthropic SSE the app parses.
  return new Response(translateOpenAIStreamToAnthropic(upstream.body), {
    status: 200,
    headers: { "content-type": "text/event-stream", "cache-control": "no-cache" },
  });
}

/**
 * Convert the Anthropic Messages request into OpenAI Chat Completions messages.
 * - `system` becomes a leading system message.
 * - String message content passes through unchanged (conversation history).
 * - Anthropic content blocks become OpenAI parts: base64 image → `image_url`
 *   data URI; text → text.
 */
function toOpenAIMessages(body: AnthropicRequest): unknown[] {
  const messages: unknown[] = [];

  if (body.system) {
    messages.push({ role: "system", content: body.system });
  }

  for (const message of body.messages ?? []) {
    if (typeof message.content === "string") {
      messages.push({ role: message.role, content: message.content });
      continue;
    }

    if (Array.isArray(message.content)) {
      const parts = message.content
        .map((block) => {
          if (block.type === "image" && block.source?.type === "base64") {
            return {
              type: "image_url",
              image_url: {
                url: `data:${block.source.media_type};base64,${block.source.data}`,
              },
            };
          }
          if (block.type === "text") {
            return { type: "text", text: block.text ?? "" };
          }
          return null;
        })
        .filter((part) => part !== null);

      messages.push({ role: message.role, content: parts });
    }
  }

  return messages;
}

/**
 * Reads an OpenAI-style SSE stream (`data: {choices:[{delta:{content}}]}`) and
 * re-emits only what the app consumes: Anthropic `content_block_delta` events
 * carrying `text_delta` text, followed by a final `[DONE]`.
 */
function translateOpenAIStreamToAnthropic(
  upstream: ReadableStream<Uint8Array>
): ReadableStream<Uint8Array> {
  const decoder = new TextDecoder();
  const encoder = new TextEncoder();
  const reader = upstream.getReader();
  let buffer = "";

  return new ReadableStream<Uint8Array>({
    async pull(controller) {
      const { done, value } = await reader.read();

      if (done) {
        controller.enqueue(encoder.encode("data: [DONE]\n\n"));
        controller.close();
        return;
      }

      buffer += decoder.decode(value, { stream: true });
      const lines = buffer.split("\n");
      buffer = lines.pop() ?? ""; // keep the trailing partial line for next read

      for (const rawLine of lines) {
        const line = rawLine.trim();
        if (!line.startsWith("data:")) continue;

        const payload = line.slice(5).trim();
        if (payload === "" || payload === "[DONE]") continue; // we emit our own [DONE] on close

        try {
          const chunk = JSON.parse(payload) as {
            choices?: { delta?: { content?: string } }[];
          };
          const textChunk = chunk.choices?.[0]?.delta?.content;
          if (typeof textChunk === "string" && textChunk.length > 0) {
            const anthropicEvent = {
              type: "content_block_delta",
              delta: { type: "text_delta", text: textChunk },
            };
            controller.enqueue(encoder.encode(`data: ${JSON.stringify(anthropicEvent)}\n\n`));
          }
        } catch {
          // Ignore keep-alive comments or any non-JSON line.
        }
      }
    },
    cancel(reason) {
      reader.cancel(reason);
    },
  });
}
