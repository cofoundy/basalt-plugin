# ADR 0002 — `.mdx` and the publish signal: the emitted CI template moves, the plugin does not

- **Status:** accepted
- **Date:** 2026-08-17
- **Issue:** #13
- **Note (#19):** the orphan bucket and `is_doc()` described below were removed. The
  no-vault warning moved to the CLI (`no_vault_binding`, at publish time).

## Context

The plugin and the `basalt` CLI disagree about what `.mdx` means, and issue #13 asks
for the product call: which of the two is wrong.

The CI template the CLI emits (`basalt onboard --print-workflow`) filters on `.md` in
**three** places — the `push` trigger's `paths:`, the `pull_request` trigger's `paths:`,
and the run step's `git ls-files '*.md'`. None of the three matches `.mdx`.

So a user who authors `.mdx` and installs the emitted workflow gets docs that never
publish. Nothing errors; the doc simply never appears.

## What we measured before deciding

Issue #13 names `hooks/lib.sh:is_doc()` as the place the plugin "treats `.mdx` as the
PRIMARY intent-to-publish signal". We instrumented that claim rather than reading it
off the source, and it does not hold:

- **`is_doc()` has exactly one caller** — `post-edit.sh`, in the `elif` branch. That is
  the **orphan** bucket: a doc edited in a tree with no `vault.yaml` above it.
- **Under a `vault.yaml`, the dirty-list append is unconditional.** Every edited file is
  recorded regardless of extension — a `.ts` source file lands on the list too.
  `is_doc()` never runs on that path.
- With no vault, `is_doc()` does discriminate: a `.mdx` anywhere raises the orphan
  warning, a root-level `.md` and a `.ts` raise nothing.

So `is_doc()` gates the orphan warning, not the publish nag. **Changing it would not
touch the symptom #13 reports.**

The nag comes from `published_by_repo_action()`, which reads the workflow's *actual*
`paths:` list instead of assuming an extension. The test suite already pins both shapes:

| workflow `paths:` | doc | Stop hook |
|---|---|---|
| `['**.md']` (the emitted template) | `.mdx` | **nags** — correctly: the Action will not publish it |
| `['**.md','**.mdx']` (hand-widened) | `.mdx` | **silent** — correctly: the Action will publish it |

The hook is already right under both shapes. It is honest about the inconsistency; it
cannot resolve it.

## Decision

**The emitted CI template moves. The plugin does not.**

Three reasons, in the order they decided it:

1. **The plugin is not the mechanism.** `is_doc()` is not on the code path that produces
   the un-satisfiable nudge, so editing it would be a cosmetic change to the wrong
   sensor while the symptom stayed exactly as reported.

2. **`.mdx` is first-class to the product the template automates.** `basalt pull` writes
   canonical **MDX**, and the CLI's own slug derivation strips `.md` and `.mdx` without
   distinguishing them. The template the CLI emits is therefore narrower than the CLI
   emitting it — this is an internal contradiction inside the tooling, not a
   plugin-versus-CLI disagreement.

3. **Narrowing `is_doc()` would make things worse.** Dropping `.mdx` from it would blind
   the orphan sensor to precisely the extension `basalt pull` writes — and the orphan
   sensor exists for the one Basalt failure that does not announce itself (publishing
   with no `vault.yaml` lands in the wrong space at exit 0).

### What that means concretely

The fix belongs to `basalt onboard --print-workflow`: emit `['**.md','**.mdx']` for both
`paths:` filters **and** widen the run step's `git ls-files` glob. All three, not two —
a workflow that triggers on a file it then does not pass to `basalt publish` swaps a
silent no-publish for a silent no-op.

That template lives in the private `cofoundy/basalt` repo (per ADR 0001), so it ships
from there. This ADR is the plugin's half of the answer: it records that the plugin's
behavior is deliberate and stays.

## Consequences

- **No plugin code changes for #13.** That is the finding, not an omission.
- The plugin keeps nagging on `.mdx` under the un-widened template, and that nag is
  **correct** — the doc genuinely will not publish. It stops on its own, with no plugin
  change, the moment a repo adopts a widened workflow.
- When the template does widen, the suite's canonical fixture (`WF_CANON`) should widen
  with it, and the `.mdx` discriminating cell flips from *nags* to *silent* legitimately.
  Keep the paired negative arm: a doc that is edited and **not** pushed must still nag,
  or the change deleted the feature instead of fixing it.
- Until then the two repos disagree in public. That is preferable to the plugin lying
  about what will publish.
