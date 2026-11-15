# Sluice

A macOS menu bar app that pools your AI coding subscriptions behind one local address.
Claude Code and Codex talk to Sluice on localhost; Sluice decides which of your accounts answers.

**Status: early.** Claude Code and Codex are relayed across pools of accounts.

## The panel

Each profile's accounts sit on a card under its name, a pool per provider.

- **An account** is two lines: who it is (its address, whether a client is itself signed in as it,
  its plan), and its week as a bar with the share used and the time until it resets. Where another
  of its limits is fuller than its week and near its end, such as its five hours or one model's own
  share of the week, the bar is that one's, named. Left of an account that answered within the last
  minute, three green bars rise and fall.
- **A click on an account** lists every limit it has, and under them the resets it holds. Each is a
  chip saying what it refills and how long until it lapses; a click on a chip and then on the red
  check beside it uses it, which cannot be taken back.
- **A pool's header** says how much of the pool is used, as [How a pool is counted](#how-a-pool-is-counted)
  says. Its star puts the pool in the menu bar as its provider's mark and its share, a profile's pools
  together after a short bar in the profile's color, in place of the glyph while the clients are routed.
- **A click on any share** reads them all as left, and on any clock reads them all as the time itself.
- **What can be done to a thing shows when the pointer is on it.** A profile's **+** adds an account
  to it, at the provider you pick, or work that belongs to it (folders, or a repository owner), and
  removes the profile. An account is removed by its bin. Removing waits for a red check where it is,
  beside a cross that leaves it.
- **An account is moved by its handle**: it lifts off the panel and drops onto another profile, or
  onto **New profile** to get a profile of its own, named from its address unless you type another.
- **A profile's name and color dot** are changed where they are: click the name to type another,
  click the dot to pick a color. Beside the name is a count of the folders and repository owners
  whose work the profile claims; click it to lay them out, each let go by the × it shows under the
  pointer. The default profile has everything else.
- **New profile**, after the last profile, is typed in place: what you type is what it is shown as,
  its name is made from it, and the check after it makes it.
- **A repository owner** is asked for in a dialog. While it is typed, the ones offered are those of
  the repositories the clients have worked in on this Mac, and then the accounts GitHub's public
  search finds for the letters typed, which are all that is sent to it.
- **The first line** holds the two views, the bolt and **⋯**. The bolt has Sluice use resets for
  you, as [How an account is picked](#how-an-account-is-picked) says. **⋯** holds the version,
  **Stop routing** and **Quit**.
- **The second view** is the last seven days of use. Each pool has a bar for every day: how much of
  the pool that day used, in the colors of the accounts that gave it, against a dashed line at the
  pace that uses the pool up in a week. Over the bars is how much went in the last 24 hours, and
  when the pool runs dry at that rate if it does. Under the profiles, the tokens of each hour and
  where they went by folder and by model. Whatever the pointer is on says more beside it: a day's
  share by account, an hour's tokens, a folder's path and share.

The panel also says when the clients are not going through Sluice. `sluice status` prints the same accounts.

## Use it

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

That does two things, and `sluice setup --undo` reverses both:

- It writes Sluice's address into each client's own settings (`settings.json` in every profile's
  Claude Code folder, `config.toml` in every profile's Codex folder) and touches nothing else in them.
- It links stand-ins for `claude` and `codex` into `~/.config/sluice/bin` and puts that folder first on your
  PATH with one marked line in your shell's startup file. The stand-in opens the profile the
  current folder belongs to, then runs the real client. A launch that names a profile's folder itself, in
  the client's own variable (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`), opens that profile; a folder that is no
  profile's is passed over.

**Stop routing** in the panel's menu, and quitting, turn only the address off: the clients go back to
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

A profile is a separate setup: its own Claude Code and Codex folders (history, memory, sign-in,
connectors) and its own pool of accounts at each provider. Work belongs to one profile, and a profile's requests are only ever served
by that profile's accounts. They are changed with the `sluice` command, and a change holds at once:

```sh
sluice profile add work
sluice profile claim work --folder ~/work --owner acme
sluice account move me@work.example work
sluice profile rename work "Day job"         # what it is shown as; its name stays `work`
sluice profile color work purple
sluice profile star work claude              # that pool's share is shown in the menu bar
sluice resets auto                           # pools use the resets they hold when they are out (or: manual)
sluice profile list
```

Every command is listed by `sluice` alone. `status` and `profile list` take `--json`, nothing asks a
question, and a failure says what to do, so an agent can run them: [skills/sluice/SKILL.md](skills/sluice/SKILL.md)
is the skill to give it.

The profiles are kept in `~/.config/sluice/config.json`, read on every request and launch, and may be
edited by hand too:

```json
{
  "profiles": {
    "work": {
      "label": "Day job",
      "color": "purple",
      "accounts": ["me@work.example", "spare@work.example"],
      "folders": ["~/work"],
      "owners": ["acme"]
    }
  }
}
```

- **`label`** and **`color`** are how the profile is shown: the label in place of its name, the color
  as a dot beside it. The name stays what its folders and the commands go by, and `default` can be
  given both like any other.
- **`accounts`** are the ones whose usage the profile shares. An account no profile lists belongs to
  `default`.
- **`folders`** and **`owners`** say what work is the profile's: anything under a folder, the deepest
  claim winning; failing that, any git repository whose origin remote has that owner. Everything
  else is `default`'s.
- `default` keeps the clients' usual folders, `~/.claude` and `~/.codex`; another profile keeps
  `~/.claude-<name>` and `~/.codex-<name>`, which start empty.
- A profile's work is paid only by its own accounts. At a provider where it has none, its requests
  are refused; no other profile's account serves them, pinned or not.

A client is itself signed in as one account in each profile (`/login` in Claude Code, `codex login`).
That account owns what the client does outside the relay: connectors, the browser, published pages.
It has nothing to do with paying: every request is paid by the pool, and Codex runs signed out. Sluice
does not set it; it reads it from the client and marks that account in the panel and in
`sluice profile list`.

The relay finds the profile itself: it asks macOS which program sent a request and which folder that
program runs in. So a client started some way that skips the stand-in still has its requests served
by the right profile's accounts. A harness can also name one account outright:
`http://localhost:7483/claude/pin/<email>`.

## How an account is picked

Within a profile's pool:

- **Soonest lost first.** A request goes to the unspent account whose remaining allowance is lost
  soonest: at its longest window's reset, or sooner where a reset it holds lapses first, since that
  reset gives back what is used before then. An account with no usage yet goes last, so an idle
  window is not started early.
- **A model's own share.** A request for a model that has its own share of the week passes over an
  account that has spent that share; the account still answers for other models.
- **Stay warm.** A conversation stays on the account that last served it for as long as its prompt
  cache lives there (an hour for Claude Code, assumed half an hour for Codex). After that it is
  placed afresh.
- **Keep going.** When an account refuses because an allowance is spent, the request is resent on
  the next account before the client sees anything. When the last one refuses too, each is asked
  how it stands now, and one that is back after all gets the request. A plain rate limit is passed
  through.
- **Resets, with the bolt on.** A reset is used when it gives the most back. When every account of
  the pool has refused a request, one that refills everything an account has spent is used and the
  request is answered by that account: the one that refills the fewest limits, so that a wider one
  is kept, unless a wider one lapses before those limits come back. A reset that refills a week is
  not spent to skip a five-hour wait. With no request waiting, a reset is used when its account has
  spent a limit and the reset lapses before that limit comes back, and in its last six hours on
  whatever it refills that is used at all. A reset is only used on an account that has just said
  how it stands. Where a use's outcome is not known, or it did not bring the account back, no more
  are used on that account by Sluice until you use one there yourself or Sluice restarts.

Claude tells of resets to Claude Code alone, so Sluice asks for them under the name and version
Claude Code itself last came through with, and until it has come through none are shown.

## How a pool is counted

A pool's share is each account's week, counted by the account's size: what a point of its week is
seen to hold, learned from what the account answered with between one rise of its week and the next.
Until ten rises were seen, it is what the account's plan is taken to hold. The tokens are weighed as
the provider's meter is found to weigh them, a formula that is fitted with `script/fit.py`, shipped,
and only checked by the app: `sluice status` says how far each account's size varies. A provider
without a formula has its accounts sized by their plans' multiples.

## What is kept

- **Sign-ins.** Sluice signs in to each account itself and keeps the tokens in its own Keychain item.
- **What it observed** (each account's plan, limits, resets and size, and the warm conversations) is
  in `~/Library/Application Support/Sluice`, so a restart forgets nothing.
- **Two histories** are there too, a line at a time, as numbers and never as what was asked or
  answered. `readings.jsonl` has an account and how full its windows and any model's own share of
  the week were, whenever that changed. `requests.jsonl` has each answered request with its account,
  profile, folder, conversation, model, how long it took and the tokens it cost as the provider
  counted them. Usage over time is read from these.
- **Usage stays current.** Each answer updates the account it came through, and every five minutes
  Sluice asks the providers about all of them, so an idle account's numbers are current too. Opening
  the panel asks again for usage told more than a minute ago and for resets asked for more than ten
  minutes ago.

Sluice never spends paid extra usage. What it knows about each provider's wire format is in
[docs/wire.md](docs/wire.md).

Only programs on this Mac are answered. A web page can reach a local port, so a request that names
another host, or that a browser sent from a page, is refused. Each relayed request is one line in
the system log, with the account and the status and nothing of the request itself:

```sh
log stream --info --predicate 'subsystem == "dev.vikng.sluice"'
```

To remove Sluice: `brew uninstall --zap sluice`. A running copy sees its app gone and quits within a
minute, as from the menu. The signed-in accounts stay in the Keychain item `dev.vikng.sluice` until
you delete it.

## Layout

One Swift package, no dependencies.

| Folder | Holds |
|---|---|
| `Sources/Core` | Accounts, Keychain storage, relay, router, the provider contract. No UI. |
| `Sources/Providers` | One folder per provider (Claude, Codex), each answering the contract. |
| `Sources/App` | The one program: the menu bar app and the `sluice` command. |
| `Tests` | What a caller can observe of Core and the providers. |
| `script` | Building the app, releasing it, and fitting a provider's meter to the histories. |
| `docs` | What is known of each provider's wire format. |
| `skills` | A skill that teaches an agent to run the `sluice` command. |
| `Assets` | The app icon: its drawing, and the built `.icns`. The menu bar glyph is drawn in code from the same shapes. Each provider's mark, named by provider, and GitHub's. |

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
