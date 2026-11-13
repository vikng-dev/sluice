# Sluice

A macOS menu bar app that pools your AI coding subscriptions behind one local address.
Claude Code and Codex talk to Sluice on localhost; Sluice decides which of your accounts answers.

**Status: early.** Claude Code and Codex are relayed across pools of accounts, from the terminal.
The menu bar view is not built yet.

## Use it

Open Sluice.app once; it relays from then on and starts with the Mac. The app is also the
command-line tool. Run this once, and `sluice` is on your PATH with the rest:

```sh
/Applications/Sluice.app/Contents/MacOS/Sluice setup
```

`setup` links `sluice`, and stand-ins for `claude` and `codex`, into `~/.config/sluice/bin` and
tells you the line that puts that folder first on your PATH. A stand-in points the real client at
Sluice when Sluice is running, and otherwise just runs it, so nothing breaks when Sluice is off.
Your own client settings are not edited.

```sh
sluice login                  # sign a Claude account in through the browser; repeat per account
sluice login codex            # the same for a ChatGPT account
sluice status                 # accounts, their windows, and warm conversations
```

Claude Code stays signed in to any one subscription: Sluice replaces its credential and account id
on the way out with those of the account it picked. Codex needs no login of its own.

Anything that runs Claude Code underneath is relayed the same way: `claude -p` and the Agent SDK
included. A client that calls Anthropic's API itself is not; see [docs/wire.md](docs/wire.md).

## How an account is picked

- **Pool.** Every signed-in account is in the pool. A request goes to the unspent account whose
  longest window resets soonest; an account with no usage yet goes last, so an idle window is not
  started early.
- **Stay warm.** A conversation stays on the account that last served it for as long as its prompt
  cache lives there (an hour for Claude Code, assumed half an hour for Codex). After that it is
  placed afresh.
- **Keep going.** When an account refuses because an allowance is spent, the request is resent on
  the next account before the client sees anything. A plain rate limit is passed through.
- **Pin.** Work in a pinned folder uses one account and no other. An account can also be pin-only:
  outside the pool, reachable only by pin. Both are rules in `~/.config/sluice/config.json`, read
  on every launch and request:

  ```json
  {
    "pins": { "~/work": "me@work.example" },
    "pinOnly": ["me@work.example"]
  }
  ```

  The deepest folder rule wins. Under the hood a pin is an address,
  `http://localhost:7483/claude/pin/<email>`, which a harness can use directly.

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
| `Sources/App` | The one program: the menu bar app, the `sluice` command, and the stand-in for each client. |

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
