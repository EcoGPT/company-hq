# Models

This page is about chat. Embeddings and the other capabilities are in
[AI services](ai.md).

HQ talks to models through one interface:

```ts
interface Provider {
  id: string;
  defaultModel?: string;
  complete(request: {
    model: string;
    messages: ChatMessage[]; // system | user | assistant (with toolCalls) | tool
    tools?: ToolSpec[]; // { name, description, parameters: JSON Schema }
    toolChoice?: 'auto' | 'none'; // 'none': answer in text even though tools are listed
    temperature?: number;
    maxTokens?: number;
    signal?: AbortSignal;
  }): Promise<{ content: string; toolCalls: ToolCall[]; finishReason: 'stop' | 'tool_calls' | 'length' | 'other' }>;
}
```

Messages and tool calls have one neutral shape, and each adapter translates it
to and from its vendor's wire format.

## Built in

**OpenAI-compatible** (`src/llm/openai-compatible.ts`). Anything that serves
`POST /chat/completions` with function calling:

|           | `HQ_LLM_BASE_URL`                |
| --------- | -------------------------------- |
| OpenAI    | `https://api.openai.com/v1`      |
| Groq      | `https://api.groq.com/openai/v1` |
| Together  | `https://api.together.xyz/v1`    |
| Mistral   | `https://api.mistral.ai/v1`      |
| DeepSeek  | `https://api.deepseek.com/v1`    |
| Ollama    | `http://localhost:11434/v1`      |
| LM Studio | `http://localhost:1234/v1`       |
| vLLM      | `http://<host>:8000/v1`          |

Set `HQ_LLM_API_KEY` if the endpoint needs one and `HQ_LLM_MODEL` to the
model's name there. Reasoning models that put `<think>…</think>` in their
output are cleaned up before posting, including servers whose chat template
opens the block so only `</think>` comes back.

**Anthropic** (`src/llm/anthropic.ts`). The native Messages API:

```sh
HQ_LLM_PROVIDER=anthropic
HQ_LLM_API_KEY=sk-ant-...
HQ_LLM_MODEL=<model id>
# HQ_LLM_BASE_URL=   # optional, for a gateway
```

**Mock** (`src/llm/mock.ts`). With nothing configured, HQ uses `echo()`, which
repeats what you said, so a fresh clone works offline. Tests use
`scripted([...])` to play back exact tool calls and replies.

## Timeouts, retries and fallbacks

Every provider HQ boots with, from env or `hq.config.ts`, is wrapped so a slow
or flaky endpoint doesn't take a turn down with it:

|                         | default  |                                                                                                                         |
| ----------------------- | -------- | ----------------------------------------------------------------------------------------------------------------------- |
| `HQ_LLM_TIMEOUT_MS`     | `120000` | give up on a call after this long (`0` turns it off)                                                                    |
| `HQ_LLM_RETRIES`        | `2`      | retries on 408, 429, 5xx and network errors, with jittered exponential backoff; a `Retry-After` header sets the wait    |
| `HQ_LLM_FALLBACK_MODEL` |          | comma-separated models to try in order when the main one still fails; a 401 or 403 skips fallbacks on the same provider |

The model that answered is recorded on each reply as `metadata.turn.model`.

The wrappers are exported, so you can build the chain yourself, including
fallbacks to a different provider:

```ts
import { resilient } from '@hq/sdk';

const provider = resilient(primary, {
  timeoutMs: 60_000,
  retries: 3,
  fallback: [{ model: 'smaller-model' }, { provider: localServer, model: 'qwen3:14b' }],
});
```

`withTimeout`, `withRetry` and `withFallback` are the individual pieces.

## Usage

Every model call is tallied per day, provider and model in the `ai_usage`
table: calls, failures, and tokens when the endpoint reports them. Each retry
and fallback attempt counts as its own call, so a failed main model shows up
even when a fallback answers. Each assistant reply also carries the turn's
total as `metadata.turn.usage`. `bun hq doctor` prints the last seven days.

## Writing your own

Any other API is one function. Translate the messages in, translate the
response out:

```ts
import { defineProvider } from '@hq/sdk';

export const myProvider = defineProvider({
  id: 'my-vendor',
  defaultModel: 'their-model',
  async complete({ model, messages, tools, signal }) {
    const response = await fetch('https://api.example.com/generate', {
      method: 'POST',
      signal,
      headers: { authorization: `Bearer ${process.env.MY_KEY}` },
      body: JSON.stringify({ model, messages: toTheirFormat(messages), tools: toTheirTools(tools) }),
    });
    const body = await response.json();
    return { content: body.text, toolCalls: fromTheirCalls(body), finishReason: 'stop' };
  },
});
```

Then set it in `hq.config.ts`, which takes precedence over the env vars:

```ts
export default defineConfig({ assistant, apps, provider: myProvider });
```

Use `src/llm/anthropic.ts` as the reference: it covers lifting system
messages, merging consecutive tool results into one turn, and mapping stop
reasons. Copy the tests in `test/llm-anthropic.test.ts` too.
