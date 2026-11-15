# What is kept

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
[docs/wire.md](wire.md).

Only programs on this Mac are answered. A web page can reach a local port, so a request that names
another host, or that a browser sent from a page, is refused. Each relayed request is one line in
the system log, with the account and the status and nothing of the request itself:

```sh
log stream --info --predicate 'subsystem == "dev.vikng.sluice"'
```
