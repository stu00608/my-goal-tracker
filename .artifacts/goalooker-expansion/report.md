# Goalooker views delivery

## Scope and setup

Owned worktree: `/Users/stu00608/orca/workspaces/my-goal-tracker/goalooker-views`, branch `stu00608/goalooker-views`, verified clean base `37769249cf755cd27dd2daa6d30b5b79985ad46e`.
Orca runtime was ready/reachable; worktree identity and base were confirmed through `orca worktree current --json`.
`python3 scripts/dev.py setup` completed successfully with repository-local hook, fast-forward pull and prune configuration.
Read AGENTS.md, goal-tracker-delivery, GOALOOKER-PLAN including Accepted decisions, SPEC, UX-QUALITY, ORCA and SIMULATOR instructions.
Only the eight assigned Swift files and these two handoff artifacts changed. No Domain, Editors, TrackerEditor, Conditions, Reminders, App, project, plist, localization catalog or SPEC changes were made.

## Delivered behavior

- Native iOS 17 Today / Goals / Settings tabs, Settings at index 2; removed gear route and Settings Done action. Widget URLs preserve existing UUID selection and record sheets and reset both Today and Goals navigation identities.
- Settings global `L.defaults` key `remindersEnabled`, default true. A user toggle asynchronously calls `Reminders.sync(_:requestPermission:)`, has busy state and local error feedback; appearance does not request notification authorization. Root startup continues its existing no-permission `Reminders.sync` task. Gated daily quick creation opens EntryEditor; undo/delete stays ungated.
- Tracker detail shows optional description, validated http/https website Link, and the first-class tracker-photo gallery using existing PhotoViewer. IDs: `tracker.description`, `tracker.website`, `tracker.photoGallery`, `tracker.photo.<index>`.
- Numeric summary, timeline, detail charts, Grid and Widget read resolved display copies; entry sheets retrieve the raw entry by ID. Timeline displays the retained raw signed change separately and labels its derived absolute value. Statistics exclude future records when showing current numeric summaries.
- Detail has native Chart / Goal progress segmented control (`snapshot.view`), with explicit no-goal/no-baseline unavailable copy. Signed Decimal progress uses the latest baseline on or before the active rule effective date (otherwise first eligible record), and current on or before min(now, deadline). An earlier deadline-qualified threshold hit keeps the ring full even after rollback; zero/negative/decreasing targets work. Daily card rings use current-period actual count/target, preserving overachievement text.
- Carry coordinates live in a separate `CardCarrySegment` series, drawn dashed and without PointMark. Prior records can supply a leading horizontal baseline; trailing carry stops at min(now, selected range end). Historical empty intervals retain carried baseline and Last recorded caption; future-only ranges have no carry. Actual detail-point hit testing and accessibility actions select only real entry IDs. Period change, best, achievement and raw export data receive no synthetic records.
- Shared CardPlotScale accepts optional lower/upper strings without breaking old callers. One-bound auto fallback keeps a positive representable span; both-bound ordering is checked in Decimal before selecting representable drawing coordinates, and invalid/equal/reversed bounds fall back safely. Plots clip drawing to the domain, with visible brief Grid/Widget notice and accessible count, and a detailed preserved-values count below the detail chart. A clipped prior carry value also has an explicit notice. Bounds and raw values are independent.
- Grid/Widget use full-surface plot, tracker first-photo, latest available record-photo, map or a lightweight stroked progress ring. No inner text/card plates were added. Photo backgrounds use a bottom full-surface gradient with white full-color text, and semantic text/gradient in tinted/clear rendering modes. Original Widget family and native UUID configuration remain unchanged.
- WidgetRow adds only optional `progress`, `axisLower`, `axisUpper`, `lastRecordedAt` fields. Published plot remains bounded to 24 real numeric samples; carry is calculated from timeline entry date and adds only two drawing coordinates, never stored samples. Daily rings recompute from the bounded published recorded days and effective rules at the timeline date, so a new period resets rather than retaining yesterday's fill. Future entries do not supply current value, last-recorded date, photo or map data.
- Tracker photos are included in photo storage bytes and backup preview counts. Export names are `Goalooker-backup-yyyyMMdd-HHmmss-SSS` and `Goalooker-export-yyyyMMdd-HHmmss-SSS`, UTC / en_US_POSIX / Gregorian. Names are generated only during prepare, remain stable while the exporter is visible, and avoid repeated timestamps within the Settings session, including a backwards clock.
- Concise localized Goalooker About text replaces the redundant private-data panel, with no additional navigation route.

## Integration contracts

`nonisolated GoalProgress.available(for: Tracker, now: Date = Date()) -> Bool` is the configuration eligibility helper for the metadata background selector. It does not require records. Construct a draft Tracker with its configured active goal and call this shared helper; do not duplicate eligibility.
`nonisolated GoalProgress.current(for: Tracker, now: Date = Date()) -> GoalProgress?` supplies `baseline`, `current`, `target`, `fraction`, `achieved` for presentation.
Read-only ledger source confirms `Tracker.resolvedEntries` (absolute display value and retained change) and `resolvedValue(for:)`; `sortedEntries` is raw. Read-only location source confirms `Reminders.sync(_:requestPermission: Bool = false)` and `L.defaults` default-true `remindersEnabled`.
All new UI keys are supplied in `strings.json` with zh-Hant/ja/en. Master owns catalog incorporation, PBX/plists, early condition app-delegate startup, integration and native acceptance.

## Design comparison and critique

For navigation, compared (A) native three tabs, (B) two tabs plus gear sheet, and (C) an extra Settings item in the Goals list. A is the accepted decision: one persistent route, no dismissal action, familiar accessibility, and no additional scroll/tap to reach preferences. B duplicates presentation/dismissal state; C mixes preferences with goal management.
For numeric analysis, compared (A) a native Chart / Goal progress segmented control, (B) simultaneous chart and ring, and (C) a menu or another detail destination. A keeps one workspace and clear modes; B adds vertical scrolling and repeated metrics; C hides the alternative or adds navigation. Existing period menu remains within Chart mode; no-goal ring state is explicit.
Source critique fixed the old raw numeric chart path, bogus progress-as-line fallback, tracker-photo fallback to record photos, future-current values, synthetic-point selection, non-positive partial domains, duplicate Settings route and unstable export naming. The old malformed nil/NaN numeric test fixture was separated from the now-strict ledger into direct defensive ChartSnapshot filtering, retaining valid precision projection coverage.
No rendered screenshots or visual/interaction acceptance are claimed. Master must inspect real final three-language, light/dark, maximum AX screenshots, actual chart taps and carry non-selection, photos/links, errors, and Widget full-color/tinted/clear modes.

## Regression checks and evidence

Added Swift Testing regressions for historical empty carry/baseline, leading/trailing/future cutoff, untouched raw ledger and statistics, delta projection, effective-date signed/zero/decreasing rings, first-baseline fallback, early-hit rollback and deadline cutoff, daily overachievement, partial/invalid/clipping domains, optional old Widget JSON decode, bounded timeline-time carry, tracker-photo absence without record-photo substitution, progress encode/decode and UTC export uniqueness.
Executed `python3 scripts/dev.py check`: passed. This command's developer-tool regression checks are not native app tests.
Executed `xcrun swiftc -frontend -parse` on all eight owned Swift files: passed; syntax parsing only, not SDK typechecking or build acceptance.
Validated every newly referenced direct localized key against existing catalog plus `strings.json`: covered; each supplied key has all three languages.
Native compile is explicitly deferred to Master per coordinator message `msg_b0b29e86361c`; no stubs, copied integration tree, native tests, Simulator operations or device actions were performed.

## Master acceptance remaining

Integrate other owners and strings, compile both hosts / Widget, execute the Swift Testing suites and native UI tests, render/critique/fix the final visuals and interactions, then run the authorized PR/CI/merge flow. Physical condition callbacks, location accuracy/permissions, notification delivery and native Widget rendering remain device acceptance, separate from this source delivery.
