# My Goal Tracker

Native iPhone app: SwiftUI, SwiftData, Swift Charts, local data and manual backup.
Product decisions live in [docs/SPEC.md](docs/SPEC.md). Read the relevant section before changing behavior.

## Delivery

For implementation, fixes, or repository workflow changes, read
[goal-tracker-delivery](.agents/skills/goal-tracker-delivery/SKILL.md).
Use Orca-managed worktrees for app development; keep the primary checkout on `main` for integration.
Default to one implementation owner. Delegate through Orca only when the user requests delegation or parallel work.
Use the user's current Orca launcher/model settings.
Authorized app work defaults to implementation, verification, PR/CI, merge, and installation
of `GoalTrackerWithWidget` on the user's connected iPhone. Continue without routine approval;
an explicit review/no-merge gate overrides this default. Coordinate Simulator tests and device
deployment through one integration owner when the user requests parallel work.

## Engineering

- Trace the affected behavior and all callers before editing. Reuse native frameworks and existing code.
- Keep UI and its state on the main actor; move expensive work only when measurements justify it.
- Use APIs supported by the installed compiler and deployment target. Skill examples can describe newer toolchains.
- Calendar-based periods, recorded local dates, and numeric precision are product data; preserve them during edits, exports, and migrations.
- Save photo copies owned by the app. Backup/restore failure must preserve existing data.
- Provide stable accessibility identifiers for UI test actions, Dynamic Type, VoiceOver, and semantic light/dark colors.
- Keep all user-facing strings, including notifications and errors, localized in `zh-Hant`, `ja`, and `en`.

## Verification and safety

Run `python3 scripts/dev.py check` before committing.
For app changes, also run the affected tests and Simulator verification described in
[docs/SIMULATOR.md](docs/SIMULATOR.md). Add the smallest meaningful regression check for new logic.
Report repository checks, Simulator execution, visual inspection, and physical-device behavior separately.
Missing tools, no tests, skipped tests, or a build-only result cannot count as app acceptance.

The current release route is free Personal Team deployment to the user's own iPhone.
Keep signing identities, certificates, provisioning profiles, device IDs, real photos, and backup files outside Git.
Paid memberships, cloud services, public publication, and changes to other projects need their own task authorization.
Preserve user-owned edits. Keep destructive Git cleanup out of routine delivery; remove only owned worktrees whose changes are verified integrated.
