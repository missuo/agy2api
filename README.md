# agy2api

Serve the [Antigravity CLI](https://github.com/google-antigravity/antigravity-cli) (`agy`)
as the three APIs coding agents speak:

| Endpoint | Wire | Tested with |
|---|---|---|
| `POST /v1/responses` | OpenAI Responses | Codex 0.172 |
| `POST /v1/chat/completions` | OpenAI Chat Completions | OpenCode 2.4 |
| `POST /v1/messages` (+ `/count_tokens`) | Anthropic Messages | Claude Code 2.1.332 (see [Claude Code](#claude-code)) |
| `GET /v1/models` | OpenAI or Anthropic list | |

Streaming and non-streaming, tool calls (including Codex's free-form `apply_patch`),
images, reasoning and `previous_response_id` all work. Paths also answer without
the `/v1` prefix.

## How it works

```
client ──HTTP (any of the three wires)──▶ agy2api ──ACP JSON-RPC (stdio)──▶ agy acp ──▶ Google
          Authorization: Bearer sk-agy-…     │
                                             └── loopback MCP server ◀── agy calls the client's tools
```

- **One parsed form.** Each wire is parsed into the same turns of text, images,
  tool calls and results, and each reply is encoded back into the wire it came in
  on. A conversation can even change wires mid-way.
- **agy accounts live on the server.** `agy2api account login <name>` signs an agy
  account in (each has its own `HOME`; agy keeps and refreshes the credential).
  Requests go to the account with the fewest live sessions.
- **API keys.** `agy2api key add <name>` prints an `sk-agy-…` key once; only its
  SHA-256 is stored. Clients send it as `Authorization: Bearer` or `x-api-key`.
  Conversations are scoped to the key that opened them.
- **Sessions.** Requests are stateless, ACP sessions are not: a request whose
  transcript extends a session's (matched on text and tool-call ids) sends only
  the new input; anything else opens a session seeded with a replay.
- **Client tools.** A request's tools reach agy over a loopback MCP server. When
  agy calls one, the response ends with that tool call and the call is parked;
  the next request's tool result resumes the same agy turn.
- **agy's own tools** are refused at agy's permission prompt; sessions run in an
  empty placeholder workspace.
- **Limits.** Each live session holds an agy worker (~250 MB): at most
  `AGY2API_MAX_SESSIONS` per account (least recently used idle one evicted), idle
  sessions closed after `AGY2API_SESSION_IDLE`.

## Model names

Clients send their own model names; agy2api maps them to agy models. First match wins:

1. an alias from `models.json`: `agy2api model map <client-name> <agy-model>` (`*` globs allowed);
2. an agy model id, with or without `agy/` (`gemini-4-neon-high`, `agy/claude-opus-5-5-low`);
3. the agy family: vendor prefixes and dates dropped, `5.5` read as `5-5`
   (`claude-opus-5-5` → `claude-opus-5-5-high`);
4. small-model names (haiku, mini, flash, nano…) → the fast model;
5. anything else → the default model.

An alias target may be a family (`gemini-4-neon`); the variant then follows the
effort the client asked for (Codex `reasoning.effort`, Chat `reasoning_effort`,
Claude Code `output_config.effort` / thinking budget), else `high`.

```sh
agy2api model map claude-opus-5-5 gemini-4-neon   # Claude Code's Opus runs on Gemini 4 Neon
agy2api model map 'gpt-*' gemini-4-neon           # every gpt-… name Codex sends
agy2api model default gemini-4-carbon-high
agy2api model fast gemini-3.8-flash-low
agy2api model resolve claude-opus-5-5 --effort medium
agy2api model list
```

## System prompts

Coding agents open their system prompt by naming themselves, and agy's backend
refuses those sessions (it answers `RESOURCE_EXHAUSTED`, 429). By default agy2api
removes just the self-identification lines ("You are Codex…", "You are Claude
Code…", Claude Code's billing header) and forwards the rest. Set per server or per wire:

| Variable | Values |
|---|---|
| `AGY2API_SYSTEM_PROMPT` | `strip-identity` (default), `keep`, `drop` |
| `AGY2API_SYSTEM_PROMPT_ANTHROPIC` / `_CHAT` / `_RESPONSES` | override for one wire |

### Claude Code

agy's backend recognises Claude Code's system prompt by more than its first line,
so Claude Code only works with the Messages wire set to drop it:
`AGY2API_SYSTEM_PROMPT_ANTHROPIC=drop`. Claude Code then runs without its own
instructions (CLAUDE.md and the environment still arrive in its messages), so it
behaves less like Claude Code. Google blocks this use on purpose; running it puts
the agy account at risk.

## Clients

**Codex** (`~/.codex/config.toml`):

```toml
model = "gpt-5.5"                 # any name; see Model names
model_provider = "agy2api"

[model_providers.agy2api]
name = "agy2api"
base_url = "https://agy.example.com/v1"
env_key = "AGY2API_KEY"           # export AGY2API_KEY=sk-agy-…
wire_api = "responses"
```

**Claude Code**:

```sh
export ANTHROPIC_BASE_URL=https://agy.example.com
export ANTHROPIC_AUTH_TOKEN=sk-agy-…
claude --model claude-opus-5-5
```

**OpenCode** (`opencode.json`):

```json
{
  "provider": {
    "agy2api": {
      "npm": "@ai-sdk/openai-compatible",
      "options": { "baseURL": "https://agy.example.com/v1", "apiKey": "sk-agy-…" },
      "models": { "gemini-4-neon-high": {}, "claude-sonnet-5-5-high": {} }
    }
  }
}
```

**Any OpenAI SDK**: `base_url="https://agy.example.com/v1"`, `api_key="sk-agy-…"`.

## Run

```sh
swift build -c release                    # macOS
Scripts/build-linux-static.sh x86_64      # static Linux binary → dist/agy2api-linux-x86_64

agy2api account login main                # once per agy account (Google sign-in link)
agy2api key add laptop                    # prints sk-agy-… once
agy2api serve --host 127.0.0.1 --port 8317
```

Put TLS in front for remote use (Caddy: `reverse_proxy 127.0.0.1:8317 { flush_interval -1 }`).
`deploy/agy2api.service` is an example systemd unit.

| Variable / flag | Meaning |
|---|---|
| `--data-root` / `AGY2API_HOME` | State: accounts, keys, `models.json` (default `~/.agy2api`) |
| `--agy` / `AGY_PATH` | `agy` executable |
| `--host`, `--port` / `AGY2API_HOST`, `AGY2API_PORT` | Bind address (default `127.0.0.1:8317`) |
| `--system-account` | Development: use this machine's own agy login, no API keys |
| `AGY2API_MAX_SESSIONS` | Live sessions per account (default 4) |
| `AGY2API_SESSION_IDLE` / `AGY2API_ACCOUNT_IDLE` | Idle seconds before a session / an account's agy is stopped (600 / 1800) |
| `AGY2API_TOOL_TIMEOUT` | Seconds a parked tool call waits for its result (900) |
| `AGY2API_DUMP` | Directory to save every request body (debugging) |
| `AGY2API_LOG=0` | Silence the per-session log |

## Development

```sh
swift test                                 # unit tests
AGY2API_LIVE=1 swift test --filter Live    # tool round trips on all three wires against your local agy
```

## Caveats

agy signs in with Antigravity's own OAuth client, and Google limits which clients
may use it. Serving it to others, or to agents Google blocks, may break
Antigravity's terms and get the account suspended.
