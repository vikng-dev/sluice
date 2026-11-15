# Profiles

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
question, and a failure says what to do, so an agent can run them: [skills/sluice/SKILL.md](../skills/sluice/SKILL.md)
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

Beside `profiles`, `"statusLine"` lists what the [status line](status-line.md) says.

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
