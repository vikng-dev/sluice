# Wire facts

What Sluice relies on about each client and provider, read off live traffic through a capture
relay. Each section names the client version it was captured from. Recapture when that moves.

## Claude Code 2.1.323 (captured 2026-11-13)

**Pointing it at a relay.** `ANTHROPIC_BASE_URL=http://127.0.0.1:<port>` sends everything there
over plain HTTP: a `HEAD /api/hello` first, then `POST /v1/messages?beta=true` as SSE.

**It must stay signed in to a subscription.** With `ANTHROPIC_AUTH_TOKEN` set to a placeholder and
no login, Claude Code sends a different request: no `oauth-2025-04-20` beta, no `cache_control`
markers at all, a smaller tool and system set. So the client keeps one real login and the relay
replaces the `Authorization: Bearer` header with the chosen account's token.

**Conversation identity.** `X-Claude-Code-Session-Id` (a UUID) on every request. The same id is in
the body: `metadata.user_id` is a JSON string holding `device_id`, `account_uuid` and
`session_id`. `account_uuid` is the client's own login, so the relay rewrites it to the serving account's.
Requests with the credential and that id swapped are served normally.

**Limits, on every response.**

| Header | Value |
|---|---|
| `anthropic-ratelimit-unified-status` | `allowed` when the request was served |
| `anthropic-ratelimit-unified-5h-utilization`, `-7d-utilization` | 0–1 |
| `anthropic-ratelimit-unified-5h-reset`, `-7d-reset` | Unix seconds |
| `anthropic-ratelimit-unified-5h-status`, `-7d-status` | `allowed` |
| `anthropic-ratelimit-unified-representative-claim` | which window binds, e.g. `five_hour` |
| `anthropic-ratelimit-unified-overage-status` | `rejected` when paid extra usage is off |
| `anthropic-organization-id` | the account's organization |

A window with no usage yet omits its headers (a fresh account sent no `5h-*`). Per-model weekly
limits are not in the headers; they need the usage endpoint.

**Cache.** Claude Code marks its system blocks `cache_control: {type: ephemeral, ttl: 1h}`. The
first SSE event, `message_start`, carries `usage.cache_read_input_tokens` and
`usage.cache_creation_input_tokens` (split into `ephemeral_5m` and `ephemeral_1h`), so the relay
knows the cache result before any text arrives. A second session on the same account read the
whole 24k-token prefix from cache: the cache belongs to the account, not the session.

**Cache across accounts.** Not shared, on the evidence so far. A prompt made unique by a nonce in the
system prompt was written and then fully read (20.8k tokens) on account A. The same client then sent
it on account B: B read only the part before the nonce, which B had cached itself earlier, and
wrote the rest. A's first request had likewise read nothing of what B cached minutes before. The
swapped requests read their own cache normally, so the id rewrite does not disturb caching.

**A spent account.** Not captured yet. Sluice follows teamclaude's routing notes: a `429` whose
`5h-status`, `7d-status` or `7d_oi-status` (a per-model weekly window) reads `rejected` is a spent
allowance; any other `429` is a rate limit. Confirm against the first real one.

**How far `claude -p` bends (probed 2026-11-13, all served from the plan through Sluice).** Its
`system` always opens with two blocks Claude Code writes itself: a billing header
(`x-anthropic-billing-header: cc_version=…; cc_entrypoint=sdk-…`) and the line "You are a Claude
agent, built on Anthropic's Claude Agent SDK." Everything after them is the caller's:
`--system-prompt` replaces the whole default prompt with the caller's text; `--tools ""` with
`--strict-mcp-config` sends no tools at all; `--mcp-config` adds the caller's own tools, named
`mcp__<server>__<tool>`; `--json-schema` returns structured output.

**Requests that are not Claude Code's (probed 2026-11-13).** A plain Messages request on a
subscription token is not served from the plan: it is refused with a bare `429` (`rate_limit_error`,
message `Error`, no rate-limit headers), and one carrying another app's tools is answered `400`,
"Third-party apps now draw from your extra usage, not your plan limits." Sluice therefore relays
Claude Code's own requests and does not translate other clients' requests for Claude.

## Codex CLI 0.160.0 (captured 2026-11-13)

**Pointing it at a relay.** A custom model provider, not `chatgpt_base_url`:

```toml
model_provider = "sluice"
[model_providers.sluice]
name = "sluice"
base_url = "http://127.0.0.1:<port>/backend-api/codex"
wire_api = "responses"
```

It then sends `POST /backend-api/codex/responses` as SSE over plain HTTP. `chatgpt_base_url` is the
wrong lever: it refuses a non-HTTPS origin for turns, tries WebSockets first, and carries plugin,
settings and analytics traffic as well.

**Only the user's config can name the provider.** A project's `.codex/config.toml` with
`model_provider` or `model_providers` is ignored with a warning ("unsupported project-local config
keys"), codex-cli 0.160.0. The same entry also works as `-c` overrides placed last on the command line.

**It needs no login of its own.** With no login it sends the same headers and body keys, minus
`authorization` and `chatgpt-account-id`; the relay adds both and the turn is served. With
`requires_openai_auth = true` it sends its own two headers and also `GET …/models`.

**Sign-in.** The Codex CLI's OAuth client (`app_EMoamEEZ73f0CkXaXp7hrann`) redirects only to
`http://localhost:1455/auth/callback`. The token endpoint takes form posts; the access token is a
JWT whose `exp` is its expiry and whose `https://api.openai.com/auth` claim holds
`chatgpt_account_id`; the email is in the id token.

**Conversation identity.** `session-id` and `thread-id` headers, and `prompt_cache_key` in the body.

**Limits, on every response.** `x-codex-primary-used-percent`, `x-codex-primary-window-minutes`,
`x-codex-primary-reset-at` (Unix seconds), the same three for `secondary`, `x-codex-plan-type`,
and `x-codex-credits-has-credits` / `-balance`.

**A spent account.** Not captured. Sluice treats any `429` as a refusal and tries the next account.

**Cache.** How long a prefix stays cached is assumed to be 30 minutes, unverified. The `response.completed` event's `usage.input_tokens_details` has `cached_tokens` and
`cache_write_tokens`. Unlike Claude, this arrives at the end of the stream.

**Requests that are not the Codex CLI's (probed 2026-11-13).** The backend serves a plain client,
with no Codex headers, when the body is in its dialect: `stream: true`, `store: false`,
`instructions`, and `input` as a list of messages (a bare string is refused: "Input must be a
list"). Another app's function tools are called normally. Fields outside the dialect are refused
by name ("Unsupported parameter: temperature").

## Who is calling

The relay pins by the caller's folder, which no request carries. For a loopback connection macOS
tells it: `proc_pidfdinfo` finds the process of this user whose TCP socket runs from the
connection's port to the relay's, and `proc_pidinfo(PROC_PIDVNODEPATHINFO)` gives that process's
working folder. Checked with Claude Code 2.1.323 (`claude -p`) and codex-cli 0.160.0: both make their
requests from the process started in the project folder. The folder is where the client was
started, with links resolved (`/tmp` reads as `/private/tmp`).

Claude Code reads `env.ANTHROPIC_BASE_URL` from its settings files. A project's
`.claude/settings.json` applies in that exact folder only, not in folders beneath it, which is why
pins are not done there.

## Claude Code with no login

Claude Code 2.1.323 with no login refuses to run. With `CLAUDE_CODE_OAUTH_TOKEN` set to any value
it runs and sends the subscription request: `oauth-2025-04-20`, `extended-cache-ttl-2025-04-11`,
one-hour `cache_control`, an empty `account_uuid` in `metadata.user_id`; cache reads were seen on a
second run, and tools, a subagent and web search worked. Against a logged-in client it lacks two
betas, `advisor-tool-2026-03-01` and `inline-tools-2026-09-15`. `ANTHROPIC_AUTH_TOKEN` instead
drops the oauth beta and the one-hour cache.

`/usage` asks Anthropic directly, never through `ANTHROPIC_BASE_URL`: logged in, it shows the
login's own windows whatever account served; with the placeholder, "No usage limits to show for
this sign-in".
