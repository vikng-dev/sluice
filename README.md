# Sluice

A macOS menu bar app that pools your AI coding subscriptions behind one local address.
Claude Code and Codex talk to Sluice on localhost; Sluice decides which of your accounts answers.

**Status: early.** Claude Code and Codex are relayed across pools of accounts. The menu bar panel shows
each profile's accounts with how much of each allowance is used and when it resets, marks the
account answering now, and switches the routing on and off. `sluice status` prints the same.

## Use it

```sh
brew install --cask vikng-dev/tap/sluice
```

Open Sluice once. macOS keeps it running from then on: it starts with the Mac and comes back if it
stops. The app is also the `sluice` command, which Homebrew puts on your PATH. Then turn on
**Route Claude Code and Codex through Sluice** in the menu, or run:

```sh
sluice setup
```

That does two things, and `sluice setup --undo` reverses both:

- It writes Sluice's address into each client's own settings (`settings.json` in every profile's
  Claude Code folder, `~/.codex/config.toml`) and touches nothing else in them.
- It links a stand-in for `claude` into `~/.config/sluice/bin` and puts that folder first on your
  PATH with one marked line in your shell's startup file. The stand-in opens the profile the
  current folder belongs to, then runs the real Claude Code.

The menu switch, and quitting from the menu, turn only the address off: the clients go back to
their providers, and work still opens in its own profile.

```sh
sluice login                  # sign a Claude account in through the browser; repeat per account
sluice login codex            # the same for a ChatGPT account
sluice status                 # each profile's accounts, their windows, and warm conversations
```

Claude Code keeps its own sign-in, one per profile: run `claude auth login` in a folder of that
profile. Sluice replaces its credential and account id on each relayed request with those of the
account it picked, so that sign-in decides only what Claude Code does outside the relay: connectors,
the browser, published pages, and what `/usage` shows. Codex needs no login of its own.

Anything that runs Claude Code underneath is relayed the same way: `claude -p` and the Agent SDK
included. A client that calls Anthropic's API itself is not; see [docs/wire.md](docs/wire.md).

## Profiles

A profile is a separate setup: its own Claude Code folder (history, memory, sign-in, connectors) and
its own pool of accounts. Work belongs to one profile, and a profile's requests are only ever served
by that profile's accounts. They are written in `~/.config/sluice/config.json`, read on every request
and launch:

```json
{
  "profiles": {
    "default": { "main": "me@home.example" },
    "work": {
      "main": "me@work.example",
      "accounts": ["spare@work.example"],
      "folders": ["~/work"],
      "owners": ["acme"]
    }
  }
}
```

- **`main`** is the account Claude Code is signed in as in that profile. **`accounts`** are further
  ones, used for relayed requests only. An account no profile lists belongs to `default`.
- **`folders`** and **`owners`** say what work is the profile's: anything under a folder, the deepest
  claim winning; failing that, any git repository whose origin remote has that owner. Everything
  else is `default`'s.
- `default` keeps Claude Code's usual folder, `~/.claude`; another profile keeps `~/.claude-<name>`.
- A provider a profile has no account at is served by `default`'s accounts.

The relay finds the profile itself: it asks macOS which program sent a request and which folder that
program runs in. So a client started some way that skips the stand-in still has its requests served
by the right profile's accounts. A harness can also name one account outright:
`http://localhost:7483/claude/pin/<email>`.

## How an account is picked

Within a profile's pool:

- **Soonest reset first.** A request goes to the unspent account whose longest window resets
  soonest; an account with no usage yet goes last, so an idle window is not started early.
- **Stay warm.** A conversation stays on the account that last served it for as long as its prompt
  cache lives there (an hour for Claude Code, assumed half an hour for Codex). After that it is
  placed afresh.
- **Keep going.** When an account refuses because an allowance is spent, the request is resent on
  the next account before the client sees anything. A plain rate limit is passed through.

Sluice signs in to each account itself and keeps the tokens in its own Keychain item. What it
observed (windows, warm conversations) is kept in `~/Library/Application Support/Sluice`, so a
restart forgets nothing. Each answer updates the account it came through, and every five minutes
Sluice asks the providers about all of them, so an idle account's numbers are current too. It never spends paid extra usage. What it knows about each provider's wire format is in
[docs/wire.md](docs/wire.md).

Only programs on this Mac are answered. A web page can reach a local port, so a request that names
another host, or that a browser sent from a page, is refused. Each relayed request is one line in
the system log, with the account and the status and nothing of the request itself:

```sh
log stream --info --predicate 'subsystem == "dev.vikng.sluice"'
```

To remove Sluice: quit it from the menu, then `brew uninstall --zap sluice`. The signed-in accounts
stay in the Keychain item `dev.vikng.sluice` until you delete it.

## Layout

One Swift package, no dependencies.

| Folder | Holds |
|---|---|
| `Sources/Core` | Accounts, Keychain storage, relay, router, the provider contract. No UI. |
| `Sources/Providers` | One folder per provider (Claude, Codex), each answering the contract. |
| `Sources/App` | The one program: the menu bar app and the `sluice` command. |
| `Assets` | The app icon: its drawing, and the built `.icns`. The menu bar glyph is drawn in code from the same shapes. |

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
git-ignored `.release.env`. With `TAP` set to a Homebrew tap's GitHub name (`owner/repo`), its
`Casks/sluice.rb` is moved to the new version and pushed. Extra arguments go to `gh release create` (for example
`--prerelease`).

## License

MIT
