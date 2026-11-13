---
name: sluice
description: Inspect and manage Sluice, the local relay that pools Claude and ChatGPT subscriptions on this Mac. Use to check each account's plan and remaining usage, see which profile work belongs to, or change profiles and accounts with the `sluice` command.
---

# Sluice

Sluice relays Claude Code and Codex through a pool of subscription accounts on `localhost:7483`.
Accounts are grouped into **profiles**. Work belongs to one profile, by folder or by the owner of the
repository's origin remote, and is only served by that profile's accounts. Everything unclaimed
belongs to `default`.

Use the `sluice` command. It never asks a question, prints results on standard output and messages
on standard error, and exits with 1 on failure with a message that says what to do. A change holds
at once, without a restart.

## Read

```sh
sluice status --json         # every account: provider, label, profile, main, plan, windows, problem
sluice profile list --json   # every profile: name, main, accounts, folders, owners
```

- A window's `used` runs from 0 to 1 and `resetsAt` is ISO 8601. An account with `used` at 1 in any
  window is spent until that window resets.
- `plan.multiple` is the plan's published usage relative to the provider's basic plan, `plan.price`
  its list price in dollars a month, `plan.business` whether it is a seat in an organization.
- `problem` is set when an account cannot serve, and says why.
- A field that does not apply is left out.

## Change

```sh
sluice profile add <name>
sluice profile claim <name> --folder <path>      # or --owner <owner>; both may repeat
sluice profile unclaim <name> --folder <path>
sluice profile remove <name>                     # its accounts go back to default
sluice account move <account> <profile>
sluice account main <account>
sluice account remove <provider> <account>       # forgets the sign-in; signing in again needs a browser
```

An account is named by its label, the email in `sluice status`.

## Limits

- Signing an account in (`sluice login [provider]`) opens a browser and needs the person.
- Making an account a profile's main one does not sign Claude Code in as it; the person does that
  with `/login` inside that profile.
- Do not remove an account or a profile unless asked to: other sessions on this Mac are served by them.
