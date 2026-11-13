# Sluice

A macOS menu bar app that pools your AI coding subscriptions behind one local address.
Claude Code and Codex talk to Sluice on localhost; Sluice decides which of your accounts answers.

**Status: early.** The relay works for Claude Code with one account at a time: sign-in, token
renewal, and the swap of credential and account id on each request. Pooling, sticky conversations,
resend-on-spent, Codex and the menu bar view are not built yet.

## Use it today

```sh
sluice serve                  # or open Sluice.app
sluice login                  # sign an account in through the browser
sluice status                 # list signed-in accounts
ANTHROPIC_BASE_URL=http://localhost:7483/claude claude
```

Claude Code stays signed in to any one subscription; Sluice replaces its credential on the way out.
Add `/pin/<email>` after `/claude` to choose the account.

## What it will do

- **Pool.** Accounts in the pool share the work. A new conversation goes to the account with
  allowance left whose weekly window resets soonest.
- **Pin.** A launch can name one account and only ever use that one:
  `http://127.0.0.1:<port>/pin/<account>`. An account can be pin-only, outside the pool.
- **Stay warm.** A conversation stays on its account while its prompt cache is warm, read from the
  cache counts on each response. It moves only when the cache is cold or the account is spent.
- **Keep going.** When an account runs out mid-conversation, the request is resent on the next one.
- **Show.** The menu bar shows each account's windows and which account is serving.

Sluice signs in to each account itself and keeps the tokens in its own Keychain service. It never
spends paid extra usage.

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
