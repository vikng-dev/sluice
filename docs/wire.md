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

**Open.** What a spent account's response looks like (status, headers, body) is not captured yet.

## Codex CLI 0.160.0 (captured 2026-11-13)

**Pointing it at a relay.** A custom model provider, not `chatgpt_base_url`:

```toml
model_provider = "sluice"
[model_providers.sluice]
name = "sluice"
base_url = "http://127.0.0.1:<port>/backend-api/codex"
wire_api = "responses"
requires_openai_auth = true
```

It then sends `GET /backend-api/codex/models` and `POST /backend-api/codex/responses` as SSE over
plain HTTP, with the ChatGPT login's `authorization` and `chatgpt-account-id` headers.
`chatgpt_base_url` is the wrong lever: it refuses a non-HTTPS origin for turns, tries WebSockets
first, and carries plugin, settings and analytics traffic as well.

**Conversation identity.** `session-id` and `thread-id` headers, and `prompt_cache_key` in the body.

**Limits, on every response.** `x-codex-primary-used-percent`, `x-codex-primary-window-minutes`,
`x-codex-primary-reset-at` (Unix seconds), the same three for `secondary`, `x-codex-plan-type`,
and `x-codex-credits-has-credits` / `-balance`.

**Cache.** The `response.completed` event's `usage.input_tokens_details` has `cached_tokens` and
`cache_write_tokens`. Unlike Claude, this arrives at the end of the stream.
