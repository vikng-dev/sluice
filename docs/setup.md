# Use it

```sh
brew install --cask vikng-dev/tap/sluice
```

Open Sluice once. macOS keeps it running from then on: it starts with the Mac and comes back if it
stops. An upgrade needs nothing more: the running copy sees that its app was replaced and starts again
from the new one, within a second. The app is also the `sluice` command, which Homebrew puts on your PATH. Then press
**Turn on** in the panel, or run:

```sh
sluice setup
```

That does three things, and `sluice setup --undo` reverses them all:

- It writes Sluice's address into each client's own settings (`settings.json` in every profile's
  Claude Code folder, `config.toml` in every profile's Codex folder) and touches nothing else in them.
- It links stand-ins for `claude` and `codex` into `~/.config/sluice/bin` and puts that folder first on your
  PATH with one marked line in your shell's startup file. The stand-in opens the profile the
  current folder belongs to, then runs the real client. A launch that names a profile's folder itself, in
  the client's own variable (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`), opens that profile; a folder that is no
  profile's is passed over.
- It has Claude Code run Sluice for [the status line](status-line.md), in the same `settings.json`.

Turning routing off in the panel's settings, and quitting, take the address and the status line out: the
clients go back to their providers, and work still opens in its own profile.

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
included. A client that calls Anthropic's API itself is not; see [docs/wire.md](wire.md).

## Removing it

To remove Sluice: `brew uninstall --zap sluice`. A running copy sees its app gone and quits within a
minute, as from the menu. Before removing it while it is not running, run `sluice setup --undo`: the
clients' settings would otherwise still name a relay that is gone. The signed-in accounts stay in the Keychain item `dev.vikng.sluice` until
you delete it.
