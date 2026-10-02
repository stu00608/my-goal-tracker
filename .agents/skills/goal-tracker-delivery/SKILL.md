---
name: goal-tracker-delivery
description: Implement or fix My Goal Tracker and its development workflow using Orca worktrees, native iOS verification, and GitHub PR delivery.
---

# Goal Tracker Delivery

## Outcome

Deliver the requested change with evidence from the current commit. Distinguish repo checks,
Simulator tests, visual inspection, and physical-device checks; report unmet acceptance criteria.

## Flow

1. Read the request, AGENTS.md, the relevant product spec, and affected code/callers.
   Define observable acceptance and preserve existing user edits. Investigate a bug before choosing a fix.
2. Load the current Orca guide with `orca skills get orca-cli`, then confirm `orca status --json`.
   Create a named worktree from the current verified base using [Orca setup](../../../docs/ORCA.md).
   Default to one owner. When the user requests delegation, load `orca skills get orchestration`
   and use real Orca Dispatches with narrow file ownership and acceptance evidence.
3. Make the smallest native change that satisfies the request. Use the relevant skills below.
   A task touching the shared Xcode project, schema, or Simulator has one integration owner.
4. Run repo checks and the smallest relevant regression tests. For app/UI changes,
   follow [Simulator verification](../../../docs/SIMULATOR.md), execute the changed interaction,
   inspect actual screenshots, and retain test results for the commit under review.
5. Review the full diff against the request and product invariants. Resolve actionable findings,
   commit, push the task branch, and create a PR using the pr skill.
   Check CI on the latest PR head; a previous head's evidence is stale.
6. For an authorized implementation task, continue through green checks and integration unless
   the user set a review/no-merge gate. Follow branch protection. Fast-forward a clean primary checkout.
   Remove only task-owned worktrees after proving their changes are integrated; squash merges need diff/patch evidence.
   End with the result, checks, and concrete remaining limitations.

## Skills by need

| Work | Skill |
| --- | --- |
| Swift implementation | write-swift; follow installed toolchain availability |
| UI and interaction design | apple-design; emil-design-eng for focused polish |
| Hard-to-localize failure | diagnosing-bugs |
| Substantive review | code-review |
| Agent instructions or skills | writing-for-agents, skill-creator |
| iOS Simulator interaction | `orca skills get orca-emulator`; computer-use for desktop UI fallback |
| Explicit TDD or simplification request | tdd or ponytail; respect the requested intensity |

Use available skills when their instructions change the task's decisions; load them when needed.
Keep product rules in the spec and command details in the executable/docs instead of copying them here.
