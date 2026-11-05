# AI services

Chat is one of several AI capabilities HQ can use. Each one has a small
neutral interface, an OpenAI-compatible adapter (most vendors and local
servers speak that dialect), a mock for tests, and its own env vars. Chat is
always on; the rest are off until you give them a model.

| Capability     | Endpoint                | Turn it on with                     | Used by                                             |
| -------------- | ----------------------- | ----------------------------------- | --------------------------------------------------- |
| chat           | `/chat/completions`     | `HQ_LLM_*` ([models](providers.md)) | the assistant, `ai.chat`                            |
| embeddings     | `/embeddings`           | `HQ_EMBED_MODEL`                    | Docs semantic search, `ai.embed`                    |
| speech-to-text | `/audio/transcriptions` | `HQ_STT_MODEL`                      | [Meetings](meetings.md) recordings, `ai.transcribe` |

## Configuring

Each capability reads `HQ_<NAME>_MODEL`, `HQ_<NAME>_BASE_URL`,
`HQ_<NAME>_API_KEY` and `HQ_<NAME>_PROVIDER`:

- Setting the model turns it on.
- With no base URL, it uses `HQ_LLM_BASE_URL` and `HQ_LLM_API_KEY`, as long
  as chat is OpenAI-compatible. A capability pointed at its own base URL never
  gets the chat key; give it its own.
- `HQ_<NAME>_PROVIDER=mock` uses the offline mock; `none` forces it off.

```sh
# One local server for chat and embeddings
HQ_LLM_BASE_URL=http://localhost:11434/v1
HQ_LLM_MODEL=qwen3:14b
HQ_EMBED_MODEL=nomic-embed-text

# Speech-to-text somewhere else
HQ_STT_BASE_URL=https://api.groq.com/openai/v1
HQ_STT_API_KEY=gsk_...
HQ_STT_MODEL=whisper-large-v3
```

Speech-to-text works with any server that takes OpenAI's multipart
`/audio/transcriptions` upload: OpenAI (`whisper-1`, `gpt-4o-transcribe`),
Groq (`whisper-large-v3`), and local whisper servers such as Speaches or
LocalAI. Uploads are named with an extension that matches their content
type (`recording.webm`), since these servers detect the format from it.
Recordings over `HQ_STT_MAX_MB` (default 25, the OpenAI and Groq limit) are
refused before they are sent; raise it for a server that takes more, or set
it to 0 for no limit.

`bun hq doctor` shows which capabilities are on and the last seven days of
calls, failures and tokens for each. Every capability retries on 408, 429,
5xx and network errors, like chat. A call with no answer gives up after 2
minutes (10 for speech-to-text, since recordings can be long).

## Semantic search in Docs

With embeddings on, `search_docs` also searches by meaning: "when do we
launch?" finds the launch plan even though the words differ. Exact keyword
matches still come first. Each doc's vector is stored in `doc_embeddings` and
only recomputed when the doc or the embedding model changes, so the first
search after turning it on embeds the whole shelf and later ones embed only the
query. If the embedding endpoint fails, search falls back to keywords and logs
why.

## From an app

`AppContext` (in `setup`, routes and automations) and `ToolContext` (in tool
`run`) both carry `ai`:

```ts
run: async ({ question }, { ai }) => {
	if (!ai?.has('embed')) return keywordSearch(question);
	const [vector] = await ai.embed([question]);
	...
},
```

|                                                                                  |                                                                     |
| -------------------------------------------------------------------------------- | ------------------------------------------------------------------- |
| `ai.has(capability)`                                                             | whether it is configured                                            |
| `ai.describe()`                                                                  | `{ chat, embed, transcribe }`, each `{ provider, model }` or `null` |
| `ai.chat(prompt \| messages, { system, model, temperature, maxTokens, signal })` | the reply text, reasoning blocks removed                            |
| `ai.embed(texts, { model, signal })`                                             | one vector per text, batched for you                                |
| `ai.transcribe(blob, { filename, language, prompt, model, signal })`             | `{ text, language?, durationSeconds? }`                             |

An unconfigured capability throws `AiUnavailable`, whose message says which
env var to set. Check `ai.has` first when you have a fallback.

## Plugging in your own

Anything with the right shape works. Build it with `defineEmbedder` or
`defineTranscriber` and pass it in `hq.config.ts`, where it overrides the env
vars for that capability:

```ts
import { defineConfig, defineEmbedder } from '@hq/sdk';

const embeddings = defineEmbedder({
  id: 'my-vendor',
  defaultModel: 'embed-v3',
  async embed({ model, input, signal }) {
    const response = await fetch('https://api.example.com/embed', {
      method: 'POST',
      signal,
      body: JSON.stringify({ model, texts: input }),
    });
    return { vectors: (await response.json()).embeddings };
  },
});

export default defineConfig({ assistant, apps, ai: { embed: embeddings } });
```

The built-in adapters are exported too (`openAICompatibleEmbedder` and
`openAICompatibleTranscriber`, each taking
`{ baseUrl, apiKey, defaultModel, headers }`, plus `maxBytes` for the
transcriber) for an endpoint that needs extra headers. A transcriber of your
own can set `maxBytes` too; larger recordings throw `AudioTooLarge`.

For tests and offline work there is a mock for each:

- `hashEmbedder()` gives deterministic bag-of-words vectors, so texts that
  share words score as similar.
- `scriptedTranscriber(['first transcript', ...])` plays back transcripts and
  records each request.
