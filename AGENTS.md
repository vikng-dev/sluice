# Sluice

`README.md` says what Sluice is, how it is laid out, and how to build and release it.
The goal is the smallest codebase that does the job. Churn is welcome: when a new requirement
breaks an old assumption (a type, a name, a folder), change the old code in the same change.

## Rules

1. **Say each thing once, in the fewest words that keep it true.** A fact has one owner in code.
   A comment carries only what the code cannot: an invariant, a unit, a reason, a rejected
   alternative. The reason for a change goes in its commit or issue.
2. **Commit to one path.** A decided question leaves one way to do it. The losing alternative
   goes in the same change, with its flag, setting and tests. Every switch names who sets it.
3. **Every failure has one deliberate outcome.** A type rules it out; or a broken invariant
   traps with a message saying why it should have held; or outside input (network, provider,
   config file, Keychain) gets a typed error the user sees.
4. **Core names no provider.** Everything provider-specific lives in that provider's folder and
   answers the contract. Review test: would this line survive a third provider unchanged?
5. **A test names the bug it would catch.** Pin behaviour a caller can observe, derived
   independently of the code under test. Test count is not a metric.
6. **Wire facts are verified, not remembered.** A provider's endpoints, headers and limits come
   from captured traffic or pinned source, cited where the code relies on them.
7. **Tokens and prompts never leave the relay.** Never log, persist or display a credential or
   a request or response body.
8. **No dependencies** without a decision recorded in the README.

## Review lenses

Before a release, read the diff since the last tag once per lens. Each lens is one rule above;
these are the findings to look for. A finding names `file:line`, the class and the fix.

| Lens | Findings | Not a finding |
|---|---|---|
| **Brevity** (1) | A comment restating code, padding, or edit history. One fact encoded at two sites. A wrapper that forwards and hides nothing. A needless intermediate. A hand-written standard operation. Dead code. | A stated invariant, unit, reason or rejected alternative. Similar code stating different knowledge. Explicit failure handling. |
| **One path** (2) | A second way to do a decided thing. A switch nobody sets. A `legacy`/`v2` twin. Commented-out code. A test of a path the code no longer takes. | A switch whose user you can name. A rejected alternative described in prose. |
| **Failures** (3, 7) | A silent early return on a failure. An invented default standing in for missing data. A dropped or erased error. A check at first use that belongs at load. A credential or body reaching a log. | A named legitimate absence (no account yet, no conversation yet). A trap whose message says why the invariant holds. |
| **Seams** (4, 6) | A provider's name, header or endpoint in Core. A contract method only one provider can answer. A wire fact with no source. | The two providers differing inside their own folders. |
| **Tests** (5) | An assertion copying a constant, config or message text. An expectation computed by the code under test. A harness that rebuilds wiring it claims to test. A stored result whose only source is an earlier run. | A wire or file format pin. A tripwire naming the upstream contract it guards. |

Line count is evidence, never a target: a shorter form that hides a failure is a Failures finding.
When a breach slips past a lens, add it to that lens's findings.
