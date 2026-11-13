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
sluice status --json         # every account: provider, label, profile, plan, windows, problem
sluice profile list --json   # every profile: name, label, color, signedIn, accounts, folders, owners
```

- A window's `used` runs from 0 to 1 and `resetsAt` is ISO 8601. An account with `used` at 1 in any
  window is spent until that window resets.
- `plan.multiple` is the plan's published usage relative to the provider's basic plan, `plan.price`
  its list price in dollars a month, `plan.business` whether it is a seat in an organization.
- `problem` is set when an account cannot serve, and says why.
- `signedIn` names, by client, the account that client is itself signed in as in the profile. What the
  client does outside the relay (connectors, the browser, published pages) is that account's; the
  profile's `accounts` only share their usage. A client that is signed out there is left out.
- A field that does not apply is left out.

## Change

```sh
sluice profile add <name>
sluice profile claim <name> --folder <path>      # or --owner <owner>; both may repeat
sluice profile unclaim <name> --folder <path>
sluice profile remove <name>                     # its accounts go back to default
sluice profile rename <name> [label]             # what it is shown as; commands keep using <name>
sluice profile color <name> <color>              # red orange yellow green teal blue purple pink, or none
sluice profile star <name> <provider>            # show how much of that pool is used in the menu bar
sluice profile unstar <name> <provider>
sluice account move <account> <profile>
sluice account remove <provider> <account>       # forgets the sign-in; signing in again needs a browser
```

An account is named by its label, the email in `sluice status`.

## Limits

- A profile's work is paid only by its own accounts. At a provider where it has none, requests are
  refused with 403 and a message naming the profile; that is the wall working, not a fault.
- Signing an account in (`sluice login [provider] [--profile <name>]`) opens a browser and needs the
  person. With `--profile` the account lands in that profile; without, it stays where it is.
- Whom Claude Code is signed in as in a profile is not Sluice's to change; the person does that with
  `/login` inside that profile.
- Do not remove an account or a profile unless asked to: other sessions on this Mac are served by them.
