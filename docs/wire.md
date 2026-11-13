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

A window with no usage yet omits its headers (a fresh account sent no `5h-*`). The headers
captured carried no per-model weekly limit; that is read from the usage endpoint.

**The model asked for (captured 2026-11-13).** Claude Code's `/v1/messages` body and Codex's
`/backend-api/codex/responses` body both carry it as a top-level `model` string. The model that
answered is read from the stream: `message.model` in Claude's `message_start` event, and
`response.model` in Codex's `response.completed`.

**Usage, on request (captured 2026-11-13).** `GET https://api.anthropic.com/api/oauth/usage` with
the bearer token and `anthropic-beta: oauth-2025-04-20`; the `user:inference` scope is enough.
`five_hour` and `seven_day` are each `{utilization, resets_at}` or null: `utilization` is 0–100,
`resets_at` is ISO 8601 with fractional seconds. An account on the 20x tier sends `five_hour: null`; a
window not yet started has `resets_at: null`. `limits[]` has an entry per limit, each `{kind, group,
percent, resets_at, is_active, severity, scope}`: `session`, `weekly_all`, and `weekly_scoped` for a
model's own share of the week, whose `scope.model.display_name` names the model (`Fable` seen) and
whose `percent` is of that share. `weekly_scoped_shares[]` says how large the share is
(`allowance_percent_of_weekly: 50` seen). Sluice keeps the scoped limits in its history and
routes on them: a request for a model draws on that model's share. `extra_usage` and `spend` are the paid overage, which Sluice does not read.

**Limit resets (captured 2026-11-13).** The same address with `?cedar_ember=1&skip_spend=1` fills
`cedar_ember`: `{eligible, ineligible_reason, at_limit, cooldown_until, exhausted, grants,
next_grant_id, weekly_resets_at}`. Asked as Sluice, every account answered `eligible: false,
ineligible_reason: "surface"` with no grants. Asked with `User-Agent: claude-cli/2.1.323 (external,
cli)`, every account answered `eligible: true` with its grants, each `{id, label, type, clears,
resets_left, resets_total, starts_at, ends_at, usable_now, use_requires_limit, paused,
gives_back_weekly, percent_used, blocking, unavailable_reason}`. `clears` names windows as
`five_hour`, `seven_day` and `seven_day_overage_included`, the last being the Fable share of the
week; `ends_at` is ISO 8601 without fractional seconds and the block's `cooldown_until` is with them; a
used-up grant stays listed with `resets_left: 0`; `next_grant_id` names the one to use first. Claude Code's own requests through
the relay carry `User-Agent: claude-cli/<version> (external, <entrypoint>)` (`sdk-cli` seen for
`claude -p`), which is where Sluice takes the version from.

**Using a reset (captured 2026-11-13, one real use; the other answers read in Claude Code
2.1.323's program).** `POST https://api.anthropic.com/api/organizations/<organization uuid>/reset_rate_limits`
with the same headers and `{program: "cedar_ember", grant_id, request_id}` answered `200` with
`{result: "reset", reason: null, reset: true, grant_id, resets_left: 0, cleared: ["five_hour",
"seven_day_overage_included"], weekly_resets_at, cooldown_until}`. What it showed:

- It was taken on an account at no limit (Fable share at 53%; the grant read `use_requires_limit:
  false`), and though `next_grant_id` named another grant: the order is advice.
- The Fable share went to 0 and the week from 66% to 39% (`gives_back_weekly`); the week's reset
  time did not move.
- For fifteen minutes the account's other grant read `usable_now: false, unavailable_reason:
  "cooldown"`, with `cooldown_until` at the top of the block.

Not seen: `result` may also be `already_used` (it took), `not_limited`, `cooldown`, `ineligible`,
or `unavailable` with a `reason`, for which the program has the words `not_next_grant`, `paused`,
`low_priority_active`, `no_grant` and `unknown_grant`; Sluice reads each of those as a refusal that
spent nothing. A `result` not named here is taken for an error, not a refusal, so that automatic
use stops instead of trying another.

**Plan (captured 2026-11-13).** `GET https://api.anthropic.com/api/oauth/profile`, same headers.
`organization.organization_type` is `claude_max` or `claude_team`; `organization.rate_limit_tier`
ends in the multiple (`default_claude_max_20x`, and `default_claude_max_5x` on a Team seat). A Max
20x account also carried `plan_display_name: "Ultra"`; the Team accounts carried none. Not
captured, and assumed: `claude_pro` (OpenUsage's reading, 35e88e9) and `claude_enterprise` as the
other organization types, and that a basic tier names no multiple. Prices are those of
claude.com/pricing on 2026-11-13, where a seat with five times the usage is a Premium one.

**Cache.** Claude Code marks its system blocks `cache_control: {type: ephemeral, ttl: 1h}`. The
first SSE event, `message_start`, carries `usage.cache_read_input_tokens` and
`usage.cache_creation_input_tokens` (split under `usage.cache_creation` into `ephemeral_5m_input_tokens`
and `ephemeral_1h_input_tokens`) and `usage.speed` (`standard` seen), so the relay
knows the cache result before any text arrives. A later event, `message_delta`, carries `usage` at
its top with `output_tokens` as the total so far; `input_tokens` in either leaves out what was read
from the cache or written to it (a first request showed 2 read new and 23,042 written to the cache). A second session on the same account read the
whole 24k-token prefix from cache: the cache belongs to the account, not the session.

**Cache across accounts.** Not shared, on the evidence so far. A prompt made unique by a nonce in the
system prompt was written and then fully read (20.8k tokens) on account A. The same client then sent
it on account B: B read only the part before the nonce, which B had cached itself earlier, and
wrote the rest. A's first request had likewise read nothing of what B cached minutes before. The
swapped requests read their own cache normally, so the id rewrite does not disturb caching.

**A spent account.** Not captured yet. Sluice follows teamclaude's routing notes: a `429` whose
`5h-status`, `7d-status` or `7d_oi-status` (a per-model weekly window, a header those notes name
and no capture here has shown) reads `rejected` is a spent allowance; any other `429` is a rate limit. Confirm against the first real one.

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

**Its own sign-in and folder (checked 2026-11-13).** `CODEX_HOME` names the folder that holds its
config, sessions, memories and sign-in; in a new one `codex login status` says "Not logged in". A
ChatGPT sign-in kept in a file is `auth.json` there, and its `tokens.id_token` carries the `email`
claim; a sign-in by API key has no tokens. Each folder it was asked to trust has a table of its own
in `config.toml`, `[projects."<absolute path>"]`.

**Sign-in.** The Codex CLI's OAuth client (`app_EMoamEEZ73f0CkXaXp7hrann`) redirects only to
`http://localhost:1455/auth/callback`. The token endpoint takes form posts; the access token is a
JWT whose `exp` is its expiry and whose `https://api.openai.com/auth` claim holds
`chatgpt_account_id`; the email is in the id token.

**Conversation identity.** `session-id` and `thread-id` headers, and `prompt_cache_key` in the body.

**Limits, on every response.** `x-codex-primary-used-percent`, `x-codex-primary-window-minutes`,
`x-codex-primary-reset-at` (Unix seconds), the same three for `secondary`, `x-codex-plan-type`,
and `x-codex-credits-has-credits` / `-balance`.

**Usage, on request (captured 2026-11-13).** `GET https://chatgpt.com/backend-api/wham/usage` with
the bearer token and `chatgpt-account-id`. `rate_limit.primary_window` and `.secondary_window` are
each `{used_percent, limit_window_seconds, reset_at}` or null: `used_percent` is 0–100, `reset_at`
Unix seconds. `plan_type` names the plan in one lowercase word (`prolite` seen, on the $100 Pro tier), which has
one window, of a week. `rate_limit_reset_credits` is `{available_count, applicable_available_count}`:
the resets the account holds, and those usable now. `credits` is the paid balance.

**Resets (captured 2026-11-13).** `GET https://chatgpt.com/backend-api/wham/rate-limit-reset-credits`
with the same two headers answers `{available_count, credits[]}`, each credit `{id, status, title,
reset_type, granted_at, expires_at, is_supported_by_plan, redeemed_at}`: `status` `available` seen,
`expires_at` ISO 8601 with fractional seconds, `title` "Full reset". Using one is not captured;
openai/codex (69231e1, `codex-rs/backend-client/src/client/rate_limit_resets.rs`) posts
`{redeem_request_id, credit_id}` to `…/rate-limit-reset-credits/consume` and reads `code`: `reset`,
`already_redeemed`, `nothing_to_reset` or `no_credit`. Confirm against the first real one. Two
things are assumed until then: that a full reset refills both windows, and that of the credits
listed the first `applicable_available_count` are the usable ones, since the answer counts them
without saying which.

**A spent account.** Not captured. Sluice treats any `429` as a refusal and tries the next account.

**Cache.** How long a prefix stays cached is assumed to be 30 minutes, unverified. The `response.completed` event's `usage.input_tokens_details` has `cached_tokens` and
`cache_write_tokens`. Unlike Claude, this arrives at the end of the stream. `usage.input_tokens`
and `usage.output_tokens` there add up to what Codex itself reports as "tokens used" (13,127 + 5 for
13,132, checked 2026-11-13); that the cached and written tokens are counted within `input_tokens` is
assumed from that total, with none cached in the request checked.

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

## Claude Code's own sign-in

What Claude Code does outside `ANTHROPIC_BASE_URL` uses its stored sign-in and needs a full one:
Claude in Chrome, claude.ai connectors, publishing, file attachments, cloud sessions, Remote Control,
Projects, voice, `/usage`. Claude Code 2.1.323:

- With `CLAUDE_CODE_OAUTH_TOKEN` set to anything it runs with no sign-in and sends the subscription
  request (one-hour cache, cache reads seen), but such a token is "limited to inference-only": the
  features above refuse it. It also lacks two betas a signed-in client sends.
- With a stored sign-in and `ANTHROPIC_BASE_URL` set, the connectors and the Chrome tools are present
  exactly as without the relay, while the relay serves the requests from another account.
- A sign-in is one per config folder (`CLAUDE_CONFIG_DIR`), read before any settings file, so only
  something that runs before the client can choose it.
- `claude auth login` with `CLAUDE_CODE_OAUTH_REFRESH_TOKEN` and `CLAUDE_CODE_OAUTH_SCOPES` signs in
  with no browser and stores the result; the refresh token is rotated by it.
- `/usage` shows the sign-in's own windows, whatever account served.
- Whom it is signed in as is recorded in its state file, `oauthAccount.emailAddress`; signed out, there is
  no `oauthAccount`. The file is `~/.claude.json` for the usual folder and `<folder>/.claude.json` when
  `CLAUDE_CONFIG_DIR` names another. Each write replaces the file whole, so a read never sees half of one.
- The folders it has worked in are the keys of `projects` in the same file, each an absolute path
  (checked 2026-11-13).

## GitHub's account search (checked 2026-11-13)

`GET https://api.github.com/search/users?q=<text>+in:login&per_page=<n>` with
`Accept: application/vnd.github+json` and no sign-in answers 200 with `items[].login`, users and
organizations alike. Asked as nobody it allows ten searches a minute (`x-ratelimit-limit: 10`,
`x-ratelimit-resource: search`).
