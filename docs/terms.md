# The providers' terms

This is what the terms say where they bear on Sluice, as read on 2026-11-15, and what Sluice does. It
is not legal advice. The terms are the providers' to read and to change, and where they are stricter
than this page, they win.

## What Sluice does

- **It relays your own clients through your own accounts.** Claude Code's and Codex's requests from
  this Mac go to whichever of your subscriptions in the pool has room. Nobody else's requests are
  answered, and no other client is served on a subscription.
- **It signs in to each account itself**, with the client's own sign-in, and keeps the tokens in your
  Keychain.
- **It asks Anthropic for an account's limit resets under Claude Code's name and version.** Asked
  under its own, it is told there are none: they are told to Claude Code alone. With "Use resets for
  me" on, it also uses them.
- **It never spends paid extra usage.**

## Anthropic

[Usage Policy](https://www.anthropic.com/legal/aup), effective 2026-11-12, under "Do Not Abuse Our
Platform": not to provide access to Claude through unauthorized means,

> including services that route requests through consumer subscriptions or misrepresent the product or client being used

and not to "create multiple accounts, to avoid detection" or to get around product guardrails.

[Claude Code's legal page](https://code.claude.com/docs/en/legal-and-compliance):

> Advertised usage limits for Pro, Max, and Ultra plans assume ordinary, individual usage of Claude Code and the Agent SDK.

> Anthropic does not permit third-party developers to offer Claude.ai login into their own applications, or to route requests through Free, Pro, Max, or Ultra plan credentials on behalf of their users. Moreover, developers may not collect, store, or intermediate Claude.ai credentials or session tokens — sign-in to a Claude account must complete through Anthropic's own flow.

[Consumer Terms](https://www.anthropic.com/legal/consumer-terms), effective 2025-10-08: no access
"through automated or non-human means" except with an API key or where Anthropic permits it, and no
"bypassing any of our systems or protective measures".

## OpenAI

[Terms of Use](https://openai.com/policies/terms-of-use), effective 2026-01-01: not to "circumvent any
rate limits or restrictions", and not to share an account's credentials with anyone else. Nothing was
found there about a relay or about one person's several subscriptions.

## What is not settled

Neither provider says anything of one person holding several paid subscriptions as such, or of a relay
that runs only on its owner's Mac for its owner's clients. Whether that is a "service" that "provides
access" is theirs to say, and neither has said Sluice is allowed. Asking for resets under Claude
Code's name is the part the words "misrepresent the product or client" fit most plainly.

A provider may limit or close an account used this way, without notice.
