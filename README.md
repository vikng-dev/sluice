# Sluice

A macOS menu bar app that pools your AI coding subscriptions behind one local address.
Claude Code and Codex talk to Sluice on localhost; Sluice decides which of your accounts answers.

**Status: early.** Claude Code and Codex are relayed across pools of accounts. The menu shows the
relay's state and switches the routing on and off; usage is read with `sluice status`.

## Use it

```sh
brew install --cask vikng-dev/tap/sluice
```

Open Sluice once; it relays from then on and starts with the Mac. The app is also the `sluice`
command, which Homebrew puts on your PATH. Then turn on **Route claude and codex through Sluice**
in the menu, or run:

```sh
sluice setup
```

`setup` links `sluice`, and stand-ins for `claude` and `codex`, into `~/.config/sluice/bin` and
tells you the line that puts that folder first on your PATH. A stand-in points the real client at
Sluice when Sluice is running, and otherwise just runs it, so nothing breaks when Sluice is off.
Your own client settings are not edited, and `sluice setup --undo` (or the same switch) removes them.

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

Only programs on this Mac are answered. A web page can reach a local port, so a request that names
another host, or that a browser sent from a page, is refused. Each relayed request is one line in
the system log, with the account and the status and nothing of the request itself:

```sh
log stream --info --predicate 'subsystem == "dev.vikng.sluice"'
```

To remove Sluice: `sluice setup --undo`, then `brew uninstall --zap sluice`. The signed-in accounts
stay in the Keychain item `dev.vikng.sluice` until you delete it.

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
git-ignored `.release.env`. With `TAP` set to a checkout of a Homebrew tap, its `Casks/sluice.rb`
is moved to the new version and pushed. Extra arguments go to `gh release create` (for example
`--prerelease`).

## License

MIT
