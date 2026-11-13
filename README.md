# Sluice

A macOS menu bar app that pools your AI coding subscriptions behind one local address.
Claude Code and Codex talk to Sluice on localhost; Sluice decides which of your accounts answers.

**Status: early.** Claude Code and Codex are relayed across pools of accounts, from the terminal.
The menu bar view is not built yet.

## Use it

```sh
sluice serve                  # or open Sluice.app
sluice login                  # sign a Claude account in through the browser; repeat per account
sluice login codex            # the same for a ChatGPT account
sluice status                 # accounts, their windows, and warm conversations
ANTHROPIC_BASE_URL=http://localhost:7483/claude claude
```

Claude Code stays signed in to any one subscription. Sluice replaces its credential and account id
on the way out, with the tokens of the account it picked.

Codex needs no login of its own. Point it at Sluice in `~/.codex/config.toml`:

```toml
model_provider = "sluice"

[model_providers.sluice]
name = "sluice"
base_url = "http://localhost:7483/codex"
wire_api = "responses"
```

## How an account is picked

- **Pool.** Every signed-in account is in the pool. A request goes to the unspent account whose
  longest window resets soonest; an account with no usage yet goes last, so an idle window is not
  started early.
- **Stay warm.** A conversation stays on the account that last served it for as long as its prompt
  cache lives there (an hour for Claude Code, assumed half an hour for Codex). After that it is
  placed afresh.
- **Keep going.** When an account refuses because an allowance is spent, the request is resent on
  the next account before the client sees anything. A plain rate limit is passed through.
- **Pin.** `http://localhost:7483/claude/pin/<email>` uses that one account and no other; the same
  after `/codex`.
- **Pin-only.** An account listed in `~/.config/sluice/config.json` is outside the pool and
  reachable only by pin. The file is read on every request:

  ```json
  { "pinOnly": ["me@work.example"] }
  ```

Sluice signs in to each account itself and keeps the tokens in its own Keychain item. What it
observed (windows, warm conversations) is kept in `~/Library/Application Support/Sluice`, so a
restart forgets nothing. It never spends paid extra usage. What it knows about each provider's wire format is in
[docs/wire.md](docs/wire.md).

## Layout

One Swift package, no dependencies.

| Folder | Holds |
|---|---|
| `Sources/Core` | Accounts, Keychain storage, relay, router, the provider contract. No UI. |
| `Sources/Providers` | One folder per provider (Claude, Codex), each answering the contract. |
| `Sources/App` | The menu bar app. |
| `Sources/CLI` | `sluice`: sign-in, status and pin from the terminal. |

## Build

```sh
swift build            # debug build
swift test
script/bundle.sh       # universal dist/Sluice.app
```

Needs macOS 14 and Swift 6.

## Release

Bump `Sources/Core/Version.swift`, commit, push, then:

```sh
script/release.sh
```

It builds, signs with a Developer ID, notarizes, tags `v<version>` and publishes a GitHub release
with the zipped app. `SIGN_IDENTITY` and `NOTARY_PROFILE` come from the environment or a
git-ignored `.release.env`. Extra arguments go to `gh release create` (for example `--prerelease`).

## License

MIT
