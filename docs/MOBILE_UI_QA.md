# Mobile UI QA

> 最新更新时间：2026-10-22

This document records the Android visual test matrix used for SSH Mobile. It
keeps high-density phone checks reproducible without storing machine-local SDK
paths or emulator snapshots in the repository.

## Device matrix

| Profile | Physical display | Density | Approx. logical display | Control scale | Chrome scale |
| --- | ---: | ---: | ---: | ---: | ---: |
| Pixel 9 Pro (`ssh_mobile_15k`) | 1280 × 2856 | 480 dpi | 426.7 × 952.0 dp | 0.84 | 0.952 |
| Pixel 6 Pro (`ssh_mobile_2k`) | 1440 × 3120 | 560 dpi | 411.4 × 891.4 dp | 0.92 | 1.0 |

Both AVDs use the Android 35 Google Play x86_64 system image. The 1280 px and
1440 px physical short edges exercise the interpolation range in
`packages/core/app_ui/` instead of testing only one density bucket.
`MobileUiMetrics` is the single source for these mobile control, chrome, and
visual-density corrections. It deliberately leaves the system text scale
unchanged for accessibility.

The layout thresholds follow Android's current
[window size classes](https://developer.android.com/develop/adaptive-apps/guides/use-window-size-classes):
expanded width starts at 840 dp and compact height ends at 480 dp. SSH Mobile
uses an app-specific 720 dp minimum before rendering the denser Servers grid.

## Visual baseline

- Verify the light and dark palettes match the desktop design tokens in
  `packages/core/app_ui/lib/src/theme/app_theme.dart`.
- Compare relative header, card, navigation, input, and action sizes between
  both devices. Small differences are expected from their logical dimensions,
  but neither device should look materially denser or more oversized.
- Check system status/navigation insets, the software keyboard, long Chinese and
  English labels, empty states, dialogs, sheets, and landscape layouts.
- Capture the first-launch background-service guide and the settled Servers,
  SFTP, AI, System Admin, Logs, Settings, and connection-form screens.
- Treat any Flutter overflow or clipped tappable target as a failed visual gate.

## Baseline observations

- The current theme families (Monochrome, Indigo, Ocean, Emerald, Rose, and
  Amber) and shared empty-state styling render on both density classes;
  Monochrome remains the default.
- The home screen's main proportions are close across 1280 px and 1440 px short
  edges, so the physical-short-edge interpolation remains the correct basis for
  the mobile correction.
- The five mobile navigation targets remain fully visible, selectable, and
  semantically labeled on both profiles after applying the shared metrics. The
  1280 px profile uses slightly tighter chrome; the 1440 px profile keeps the
  standard 68 dp navigation height.
- The Servers header exposes a visible 48 dp settings action in portrait. A
  saved Grid preference safely falls back to the reorderable list below 720 dp,
  list drag handles remain 48 dp, unknown health no longer reads as score zero,
  and scroll padding clears both app navigation and the system inset.
- Both landscape profiles exceed 840 dp width but remain below 480 dp height,
  so they consistently use the icon-only compact rail. All five destinations
  plus Settings remain visible with no RenderFlex overflow on either AVD.
- The Settings drawer stays within both portrait viewports and removes feature-
  specific controls. Language exposes one semantic button with its current
  value, cache timeout displays its value only once, and the final import row
  clears the gesture inset. Servers keeps the 48 dp settings action plus a
  view-layout menu; terminal, SFTP, LAN Share, and MCP settings open from their
  owning feature pages. App text follows native system fonts; terminal font is
  configured only from terminal settings.
- The connection form uses shared icon-led section cards on both profiles. Its
  collapsible jump-host and advanced headers expose full-width semantic button
  targets, the password visibility action is labeled, and focusing an input
  hides the sticky save bar so the keyboard does not cover the active field.
  Long English authentication choices wrap without overflow.
- AI Chat keeps its header in normal document flow and re-aligns the selected
  page when rotation crosses the 840 dp navigation breakpoint. Its adaptive
  shell keeps the page subtree stable so focus and unsent drafts survive the
  bottom-navigation-to-rail transition. The composer is
  one rounded input surface with 48 dp Tools and Send targets, a single-line
  hint, and a height-limited scrolling area for plan, command, attachment, and
  tool content. On compact-height keyboard layouts, tools collapse and the
  decorative chat header and rail stop consuming the remaining input space.
  The 48 dp jump-to-latest action remains available after generation ends,
  announces a bilingual accessibility label, respects the trailing safe area,
  and stays above a 1.5K landscape keyboard. Background stream and completion
  updates preserve the user's reading position until this action is selected.
  Slash-command suggestions use bilingual summaries, stable 48 dp rows, and a
  bounded scroll region; completing `/compact` or `/skills` drops stale
  arguments, while `/tools` and `/plan` preserve their supported arguments
  without joining command and text accidentally.
  The tool selector canonicalizes names case-insensitively, removes stale
  whitelist entries, and keeps search, selection, cancel, clear, and save
  controls reachable above a 1.5K landscape keyboard and system safe area.
  Long tool names/descriptions ellipsize without losing their full semantics.
  The target-server picker removes stale connection IDs, formats IPv6 targets
  unambiguously, lazily builds large server lists, and keeps full names and
  addresses in accessibility semantics while visible rows ellipsize. Its
  48 dp clear, cancel, and save actions remain reachable on 320 dp screens and
  above a 1.5K landscape keyboard.
  Chat bootstrap failures no longer leave an infinite spinner: a bilingual,
  path-safe empty state exposes a real 48 dp retry action and recovers the
  draft when local settings become readable.
  Agent runtime preflight dialogs localize every known health code, announce
  warning/blocking severity without relying on color, keep long issue cards in
  a bounded list, and pin 48 dp actions above a 1.5K landscape keyboard.
  New chats use a centered bilingual empty state with three 48 dp starter
  actions; selecting one only fills and focuses the composer for review.
  Tool approvals keep the full risk reason, target, path, command, and preview
  in one scrollable details region while 48 dp Reject and Approve actions stay
  fixed and reachable on compact-height layouts.
  Chat history animates with normalized progress so an open panel remains full
  width after rotation. It blocks background semantics and Android Back closes
  the history layer before attempting to leave the current route.
  The AI tools grid derives three to six columns from available width, shows
  all rows through the composer's outer scrolling region, and keeps attachment
  removal actions at 48 dp while long filenames ellipsize safely. Image
  attachments decode once into DPR-sized thumbnails, degrade safely for broken
  Base64, expose filename-specific semantics, and open a zoomable full-screen
  preview that Android Back closes normally; file chips announce name/type/size.
  Message copy, edit, retry, branch, and trace controls expose 48 dp targets;
  action groups wrap on narrow messages, every action tooltip is bilingual,
  sent attachment names stay bounded,
  and trace summaries localize without overflowing their message column. The
  regenerate and branch confirmations use centralized bilingual copy, scroll
  safely at 2× text scale, dismiss composer focus, and keep 48 dp actions above
  a 1.5K landscape keyboard. The inline Agent run summary reads the lightweight
  summary already embedded in
  each persisted message without storage I/O, then falls back to compact run
  metrics and finally legacy trace data only when needed. Its bounded two-line
  chips retain full accessibility labels at 2× text scale, update with the live
  language, and map unknown outcomes to a safe generic result instead of
  exposing internal status codes. The message editor derives
  its height from the keyboard-visible viewport, keeps
  both actions at 48 dp in compact landscape, and rejects whitespace-only
  resubmissions without dismissing the draft. Embedded execution traces use
  bilingual 48 dp expansion rows, real Material ink surfaces, and a 280 dp
  vertically scrollable ceiling so long diagnostics do not inflate a message.
  The standalone Agent Trace debugger uses the shared page/card surfaces and a
  lazy sliver timeline, preserves expansion state by event ID, bounds raw JSON
  at 280 dp with two-axis scrolling, and keeps filter/copy/retry targets at
  48 dp. Its chrome, metrics, filters, empty states, and outcome descriptions
  react to live Chinese/English changes while raw diagnostic fields stay
  unchanged. A 320 dp regression covers the 300-event retention ceiling
  without eagerly building every row or exposing storage errors in the UI.
  Planned-operation TODO panels keep expansion state by task ID, constrain long
  server names and command/log output, and expose 48 dp step/retry/skip/revise
  targets. The skip-reason dialog disables blank confirmation and keeps its
  field and actions above a 1.5K landscape keyboard. Plan approval is a
  single-flight transaction: delayed runtime checks cannot double-submit or
  accept an ordinary send, switching chats invalidates the captured plan, and
  plan transitions and the final approved-turn save lock chat mutation until
  their persisted state is committed.
  Missing credentials or storage failures leave the plan pending, partial
  plans that remain in Plan Mode cannot execute, and `/plan` always clears an
  older approval. Attachments added while approval health checks are running
  remain queued for the next ordinary message and are never consumed by the
  synthetic approved-plan execution turn. The approved turn also keeps the
  server targets, allowed tools, RAG enablement/mode/top-N, Aliyun RAG key, and
  response language captured at approval time through both context preparation
  and the generation runner; later composer or settings changes apply only to
  the next message. Each selected server is represented by an immutable,
  non-secret routing/authentication binding rather than an ID alone, so context
  assembly and read-only tools cannot drift to a replacement server while a
  turn is waiting. Provider URL, model, API format, provider key, and Quark
  endpoint/key are loaded as one in-memory runtime snapshot at the
  action's first asynchronous boundary. `/plan <request>` captures it before
  Plan persistence, Plan approval captures it before runtime health checks,
  and a forced warning continuation reuses the original snapshot. Tool schema
  exposure and web-search execution use that same snapshot, so settings saved
  while a turn is pending cannot mix providers, endpoints, or credentials.
  Ordinary sends—including `/plan <request>`—capture composer inputs before
  any slash-command persistence await, so a late picker result cannot change
  the submitted turn. Client-tool TODO writes remain authoritative through
  success, cancellation, and failure while streamed response text and traces
  are kept.
  Stopping during send preparation prevents generation from starting, and
  deleting a streaming chat cancels its run without restoring the deleted
  record during asynchronous completion.
  Plan Mode UI uses the same exact, case-insensitive `/plan` token parser as
  the send path, so `/planet` and similar text remain ordinary input. Its
  neutral status card and selected tool semantics expose 48 dp actions, block
  mode changes during generation or approval, and preserve command arguments
  when a persisted mode change fails. Execution approval stays in a fixed
  decision area above the composer with explicit Revise and Approve actions;
  it stacks safely at 320 dp/2K DPR with 200% text, announces busy state, and
  dispatches every preflight result, including the forced result after a
  warning. Remote tool approval binds the exact non-secret target snapshot and
  resolves matching credentials atomically at the SSH/SFTP socket boundary;
  replacing or editing a target while approval is open invalidates the action.
  SSH reconnects also bind the exact session identity, while SFTP caches include
  the target fingerprint so a reused connection ID cannot expose stale data.
  Server-metadata approvals freeze both the full current and candidate
  connection snapshots and apply the update with compare-and-swap semantics.
  Playbook approvals additionally freeze command steps and compare-and-swap the
  saved playbook before every next step; skipping an in-flight step waits for
  that command rather than launching another command concurrently. Skill
  updates use the same resource guard, and monitor approvals require and bind
  the complete non-empty selected-server set across periodic samples and
  retries. The redundant AI tmux-restore tool is not exposed; startup-owned
  automatic restoration remains the sole path. Any target or resource drift
  executes nothing further until the user reviews and approves again. Missing
  API credentials open LLM settings once. Composer
  drafts are stored per chat ID, remain selectable in history before the first
  message, and survive creating another chat even after the user has switched to a
  saved conversation. New-chat model loading is single-flight and captures
  composer edits only after its asynchronous settings read, so text entered
  during that wait remains attached to the original chat. A stale New-chat
  request is discarded if the user selects another conversation while the
  model loads. If a newer send or persisted state write owns the chat lock when
  model loading completes, New chat reports a localized busy result instead of
  silently dropping the request. Pending diagnostic prompts no longer replace
  or consume an existing draft. On a nested-Scaffold
  landscape keyboard viewport, the
  actual body constraint—not a consumed MediaQuery inset—drives the compact
  layout: the header, fixed approval card, and Plan status card yield before
  any 48 dp action is clipped; the input remains reachable and the hidden Plan
  controls return when sufficient height is restored. Narrow 320 dp approval
  layouts account for stacked actions and scale their visibility threshold
  from 360 dp at standard text to 460 dp at 200% text before becoming visible.
  The decision card temporarily yields while the user is composing, browsing
  slash commands or tools, or staging attachments, then returns with an empty
  composer so auxiliary UI cannot collide with its actions.
  Whole-chat writes now share one save transaction across Plan changes, TODO
  retry/skip, regenerate, edit, and branch actions. Slow or failed persistence
  cannot apply a stale record, reactivate the prior chat, or let a late history
  snapshot replace a newer Plan state; streaming-chat deletion retains its
  existing cancellation exception to that lock. Failed history loads always
  clear their busy state and remain retryable, while branching before the
  first history open still loads older persisted conversations.
  Prompt customization keeps the active draft when switching type or toggling
  customization, confirms before discarding unsaved text, exposes retry/save
  failures, and reduces compact-height layouts to a 48 dp type selector plus
  the flexible editor so a landscape keyboard cannot hide the work area.
  The chat RAG sheet follows the global drag-handle and corner treatment,
  preserves the system navigation safe area, wraps at 1.3× text scale, and
  guards asynchronous preference updates when the sheet closes mid-write.
- LLM settings intercept Android Back and the close affordance when edits are
  pending, then require an explicit discard confirmation. Saving
  temporarily disables route dismissal, while model-refresh and save failures
  remain visible at the top of the form and in a floating snackbar.
  The chat header exposes a real 48 dp settings target and guards loading and
  navigation as one single-flight action, so rapid taps cannot stack routes.
  The pushed route retains the originating chat ViewModel scope, allowing save
  actions to complete without provider lookup failures.
  Leaving the kept-alive AI tab invalidates an in-flight open, so a completed
  load cannot push a route or snackbar over another page. Load/open failures
  restore the entry and show only a bilingual generic snackbar; failures after
  a successful save explain that only the active-chat refresh failed. That
  refresh persists before changing the in-memory chat, so a failed write stays
  retryable instead of leaving a false-success model selection. Settings-save
  failures likewise keep raw storage details out of the form and snackbar.
  Settings navigation and persistence logs record no Base URL, model, endpoint,
  API key, or raw storage-error value.
  The form uses the shared page and section surfaces, caps its desktop reading
  width at 760 dp, keeps connection essentials expanded, and folds advanced
  model routing and low-frequency groups behind semantic 48 dp headers. Its
  quiet filled fields avoid repeated card-within-field outlines on mobile.
  Settled 1.5K and 2K AVD captures show the same hierarchy and materially
  equivalent proportions without clipped labels or horizontal overflow. Base
  URL and API-key history sheets expose the active row through both selection
  semantics and theme color, with explicit 48 dp delete targets.
- The first-launch background-service guide now uses the shared page surface,
  icon badge, theme typography, and a 640 dp reading-width ceiling. Its
  unrestricted title, checklist, live status region, and naturally growing
  48 dp actions remain scrollable at 320 dp with 200% English text and inside
  1.5K landscape safe areas. The relaxed state promotes Continue to the primary
  action; Continue for now skips only the current launch, matching the reminder
  copy without permanently suppressing an unresolved warning.
- Connection history now uses the shared page surface, a real route app bar,
  an 820 dp content ceiling, an explanatory overview, and status-led record
  cards. Settled 1.5K Chinese populated/empty captures and a 2K English capture
  keep Back, Refresh, Delete, and command-copy targets at least 48 dp without
  clipped titles, host names, timestamps, or error text. Persisted connection
  errors are redacted and length-bounded before entering the visible or
  semantic tree. Widget regressions additionally cover 320 dp at 200% text,
  asymmetric short-landscape safe areas, load/retry states, serialized deletes,
  operation failure feedback, and completion after the route is disposed.
- The SFTP remote-text editor now uses the shared page surface, a focused
  Back/title/Save app bar, adaptive file metadata, a 48 dp font/wrap toolbar,
  and a bounded editor surface. Settled 1.5K Chinese captures cover pristine,
  discard-confirmation, and saving states; 2K English portrait and compact
  landscape captures retain the full remote path, save status, and editor
  controls without overflow. Save and wrap semantics expose real accessibility
  actions, including in the compact-height metadata row. Widget regressions
  cover 320 dp at 200% text, asymmetric safe areas, load/retry and safe error
  states, discard protection, UTF-8 edit limits, post-save IME races, late
  disposal, and dynamically expanding ASCII/CJK no-wrap lines. Saving disables
  edits and route dismissal, disconnected writes fail explicitly, and queued
  text after a saved snapshot remains in the editor for a follow-up save.
- Less common routes still need a consistency pass against the shared page
  surface and section components.
- Cold startup remained on the native black launch surface for a noticeable
  interval on fresh AVD data. Startup initialization and native launch styling
  require a dedicated performance-stage audit.

## Re-test commands

Resolve Flutter and the Android SDK from the environment or Flutter tooling;
do not add local absolute paths to scripts or documentation.

```powershell
flutter emulators
flutter build apk --debug
flutter devices
```

Install the generated debug APK on each AVD, clear app data when testing the
first-launch guide, and capture screenshots only after the frame is stable.
