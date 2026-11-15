# Sluice

A macOS menu bar app that pools your AI coding subscriptions behind one local address.
Claude Code and Codex talk to Sluice on localhost; Sluice decides which of your accounts answers.

**Status: early.**

## Install

```sh
brew install --cask vikng-dev/tap/sluice
```

Open Sluice once and press **Turn on**. Then sign your accounts in, once each:

```sh
sluice login            # a Claude account
sluice login codex      # a ChatGPT account
```

`sluice setup --undo` puts the clients' settings back as they were.

## Scope

- **One person, their own accounts.** Not account sharing, not a hosted service, not resale.
- **The providers' own clients.** Claude Code on Claude accounts, Codex on ChatGPT accounts, and nothing else.
- **Not made or endorsed by Anthropic or OpenAI.** A provider may limit or close an account used this
  way; what their terms say of it is in [docs/terms.md](docs/terms.md). The accounts are yours, and so is the risk.

## More

- [Setting up and removing](docs/setup.md)
- [The panel](docs/panel.md)
- [Profiles](docs/profiles.md): separate pools for separate work
- [The status line](docs/status-line.md)
- [How an account is picked, and a pool counted](docs/routing.md)
- [What is kept on your Mac](docs/kept.md)
- [Building and releasing](docs/develop.md)
- [The providers' terms](docs/terms.md)
- [The providers' wire formats](docs/wire.md)

## License

MIT
