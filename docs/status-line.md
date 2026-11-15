# The status line

Claude Code shows a line under its prompt, and with Sluice set up that line is of the pool that
pays for the work, not of the one account the last answer came through:

```
● work | ━━━━━━━━ 62% | 1d 4h
```

What it says is one ordered list for every profile, changed in the panel's settings or with the command:

```sh
sluice statusline items profile share reset
sluice statusline off                         # or: on
sluice statusline claude                      # the line for the folder you are in
```

| Item | Says |
|---|---|
| `profile` | the profile's name after a dot in its color |
| `bar`, `share` | how much of the pool is used, as the panel counts it |
| `reset` | how long until any of it comes back |
| `dry` | when the pool has nothing left at the rate of the last day; nothing while it lasts |
| `account` | the account that answered last |
| `today` | today's use against the pace that uses the pool up in a week |

A status line of your own in the client's settings is kept: Sluice runs it too and puts what it
says after the pool, and `sluice setup --undo` leaves the setting as you had it. Codex's status
line takes no command, so it shows none.
