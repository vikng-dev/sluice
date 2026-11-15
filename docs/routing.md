# How an account is picked

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
