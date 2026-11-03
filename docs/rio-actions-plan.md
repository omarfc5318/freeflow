# Rio Actions: plan and builder brief

Owner request (2026-11-03): make Rio "so much more than a dictation app". Hold a key, say
"open Chrome", and Rio does it. Plus a hands-free conversation mode toggled with a three-finger
trackpad tap. Owner decisions:

| Decision | Choice |
|---|---|
| Dictation key | **Fn (hold)**: unchanged, pure dictation, never runs a command |
| Action key | **Fn + Control held together** (either order; Control pressed at any point before Fn is released counts). Never types text |
| Saying "Rio" on the action key | **Optional**: "open Chrome" and "Rio, open Chrome" both work |
| Abilities | Apps & websites, Mac controls, Smart AI actions, Window control (all four) |
| Conversation mode | **Three-finger tap** toggles an always-listening mode; every command must start with "Rio" |

Existing keys that must keep working: Fn hold = dictation, Right Option tap = toggle dictation,
lone Right Command tap = Fix Last Dictation. Edit Mode is OFF for the owner (Control is free).

## Shared contract

`Sources/RioActions/RioActionTypes.swift` (committed by the lead) defines `RioAction`,
`RioActionParse`, `RioActionResult`, `WindowCommand`, `InstalledApp` and friends. **Do not change
it.** If you truly need a change, add a note to your final report; the lead merges contract
changes. All new production code goes under `Sources/RioActions/` unless your package says
otherwise.

Pinned APIs. Implement exactly these signatures so the waves fit together:

```swift
// Builder B
struct RioActionParser {
    init(installedApps: [InstalledApp])
    func parse(_ transcript: String) -> RioActionParse
}
enum InstalledAppCatalog { static func scan() -> [InstalledApp] }   // /Applications, /System/Applications(+Utilities), ~/Applications
enum AppNameMatcher { static func bestMatch(for spoken: String, in apps: [InstalledApp]) -> InstalledApp? }
@MainActor final class RioActionExecutor {
    init(windowController: WindowControlling, typeText: @escaping @MainActor (String) async -> Bool)
    func execute(_ action: RioAction) async -> RioActionResult
}

// Builder C
@MainActor protocol WindowControlling { func apply(_ command: WindowCommand) -> RioActionResult }
@MainActor final class WindowController: WindowControlling { init() }
final class ThreeFingerTapMonitor { init(onTap: @escaping @MainActor () -> Void); func start() -> Bool; func stop() }
@MainActor final class WakeWordListener {
    init(onCommand: @escaping @MainActor (String) -> Void)   // text AFTER "Rio", already trimmed
    func start() async -> WakeWordListenerStartResult            // enum: started, permissionDenied, unavailable(String)
    func stop()
    var isListening: Bool { get }
}
```

`WindowControlling` is declared by builder C in `Sources/RioActions/WindowControlling.swift`.
Builder B needs it to compile. B may add a throwaway copy in
`Sources/RioActions/STUB_B_WindowControlling.swift`, which the lead deletes at merge. Builder A
may stub B/C types the same way in files named `STUB_A_*.swift`. Never edit another builder's
files.

## Wave 1 (parallel, one git worktree each)

### Builder A: action key and pipeline (`feat/rio-actions-a`)
Owns: `Sources/ShortcutCore/*`, `Sources/AppState.swift`, `Sources/RecordingOverlay.swift`,
`Sources/SettingsView.swift`, `Sources/MenuBarView.swift`, new
`Sources/RioActions/RioActionCoordinator.swift`, related tests.
- New session intent for Fn+Control. Today the hold binding is Fn with exact modifier
  matching: pressing Control must NOT cancel or end the Fn session. Look at
  `permittedAdditionalExactMatchModifiers` (AppState ~2014) and how Edit Mode's manual
  modifier is detected (`resolveSessionIntent`, ~2315). Control held at press time OR pressed
  any time before Fn is released → action intent. Control alone does nothing. Right Option tap
  toggle and Fix Last must behave exactly as before (add regression tests in ShortcutCoreTests).
- An action session never pastes, types, touches `lastTranscript`, the correction learner, undo
  or Paste Again. After transcription (same Groq Whisper path, same vocabulary prompt), strip an
  optional "Rio"/"yo Rio"/"… bro" (reuse `TeddyCommand`'s name handling; make the helper
  internal if needed). Then: a Teddy trick phrase → run the trick, as today. Otherwise
  `RioActionCoordinator.run(transcript)`, which does `parser.parse` → `.actions` executes in
  order, stopping at the first failure; `.unknown` → smart resolver hook (a `RioSmartResolving`
  protocol you declare in the coordinator file with `func resolve(_ text: String) async throws
  -> [RioAction]`, nil in wave 1, so unknown → shrug "I don't know how to do that yet"); `.empty`
  → nothing.
- Pill feedback: reuse the bear pill. Show a short status ("Opening Google Chrome",
  "Volume 40%") and the shrug moment on failure/unknown, with the result message. Look at how
  `finishWithTeddyTrick` and moments work.
- History: record action sessions with a distinguishable intent and the result summary (no
  new user-content logging beyond what history already stores).
- Settings: a "Rio Actions" section with an Enable toggle (default ON), the key shown as
  "Fn + Control", and a note that Fn alone is still dictation. If Edit Mode is enabled with
  manual modifier Control, show a collision message and make Fn+Control go to Rio Actions.
- Wiring: AppState gets the parser/executor through one small factory function
  `RioActionsWiring.make…()` in `Sources/RioActions/RioActionsWiring.swift`. Ship it backed by
  your `STUB_A_*` types. The lead rewrites this file at merge to use B's and C's real types.

### Builder B: parser and executors (`feat/rio-actions-b`)
Owns: `RioActionParser.swift`, `InstalledAppCatalog.swift`, `AppNameMatcher.swift`,
`RioActionExecutor.swift`, `MacControls.swift` (all under `Sources/RioActions/`),
`Tests/RioActionParserTests.swift`, `Tests/AppNameMatcherTests.swift`.
- Parser: deterministic, pure, case-insensitive, punctuation-tolerant, tolerant of Whisper
  quirks (trailing ".", "Open Chrome." / "open up chrome" / "launch" / "start" / "fire up";
  "close/quit/kill X"; "switch to/go to/show me X"; "hide X"). Optional leading "Rio"/"hey Rio"/
  "yo Rio" and trailing "please"/"bro". Compound: "open Chrome and Spotify", "put Chrome on the
  left and Warp on the right" → multiple actions.
- Websites: "open YouTube/Gmail/GitHub/Netflix/…" with a built-in map of ~30 popular sites; an
  installed app with that name wins (YouTube has no app, but "open Spotify" is the app). Spoken
  domains ("open hala discover dot com") → URL. Only http(s) URLs are ever built.
- Search: "search (for) X", "google X", "look up X", "search YouTube for X" → `webSearch` or a
  YouTube search URL.
- Mac controls: "volume up/down", "turn it up", "volume 40 / to 40 percent", "mute",
  "unmute"; "play/pause/next song/skip/previous"; "lock (my) screen"; "take a screenshot
  (of the window / of a selection)"; "turn on/off do not disturb / focus".
- Windows phrases → `.window(WindowCommand)`: "put/move/snap X (to the) left/right/top/bottom",
  "maximize/full screen (X)", "center (X)", "minimize (X)", "move X to the other screen /
  next screen". No app → nil appName (frontmost).
- "type …" / "write …" → `.typeText` (conversation mode uses it); "stop listening" /
  "go to sleep" / "that's all" → `.stopListening`.
- Anything else → `.unknown(textWithoutName)`. Never guess wildly: an unmatched app name in
  "open X" stays `.openApp(name: X)` so the executor can say "I couldn't find X", unless X is a
  known website.
- AppNameMatcher: aliases (chrome→Google Chrome, vs code/vscode→Visual Studio Code,
  settings/system preferences→System Settings, messages/imessage→Messages, terminal, finder,
  facetime, word/excel/powerpoint→Microsoft …), normalised exact, prefix, token and edit-distance
  matching with a strict threshold (no "Mail" for "Maps"). Deterministic tie-breaks.
- Executor: NSWorkspace open (re-scan once if not found), activate/hide via
  NSRunningApplication, quit via `terminate()` (never force). Open URLs in the default browser.
  Volume via `NSAppleScript("set volume output volume N")` (in-process Standard Additions, no
  Automation prompt), media and volume keys via NX_SYSDEFINED CGEvents, lock screen via the
  Ctrl+Cmd+Q CGEvent, screenshots via `/usr/sbin/screencapture` with FIXED arguments to
  `~/Desktop/Rio Screenshot <date>.png` (`-i` selection, `-w`… use `-l`/`-W` as appropriate), DND
  best-effort: run the user's Shortcut named "Rio Focus On"/"Rio Focus Off" through
  `/usr/bin/shortcuts run` if it exists, else fail with a helpful message. `.window` → injected
  WindowControlling. `.typeText` → injected closure. Smart cases → `.failed("…coming soon")` in
  wave 1. No Process call may ever take user text as an executable or a flag.
- Tests: 120+ parser cases (real Whisper-style phrasing, mishearings like "Crome", negative
  cases that must be `.unknown`), matcher tests, and a pure test of how volume/screenshot
  arguments are built.

### Builder C: windows and conversation-mode building blocks (`feat/rio-actions-c`)
Owns: `WindowControlling.swift`, `WindowController.swift`, `WindowGeometry.swift` (pure frame
math), `ThreeFingerTapMonitor.swift`, `TapGestureDetector.swift` (pure),
`WakeWordListener.swift`, `WakePhraseExtractor.swift` (pure), plus tests
`Tests/WindowGeometryTests.swift`, `Tests/TapGestureDetectorTests.swift`,
`Tests/WakePhraseExtractorTests.swift`.
- WindowController: Accessibility API (Rio already has Accessibility). Resolve the app by spoken
  name (reuse `AppNameMatcher` if B has it; otherwise match against running apps' localized
  names with a small private helper), pick its focused/main window, compute frames on the
  window's current screen `visibleFrame` (menu bar/Dock aware; AX uses top-left origin, so
  convert carefully, multi-display safe), and set position then size then position again
  (the known AX resize quirk). Minimize via kAXMinimizedAttribute. Next screen keeps the
  relative frame. User-facing results: "Moved Google Chrome to the left".
- ThreeFingerTapMonitor: global trackpad touches through the private MultitouchSupport
  framework, loaded with `dlopen`/`dlsym` (MTDeviceCreateList, MTRegisterContactFrameCallback,
  MTDeviceStart, MTDeviceStop, MTUnregisterContactFrameCallback). All built-in and Magic
  Trackpads. Callback is on a background thread: feed frames to the pure `TapGestureDetector`,
  hop to the main actor only on a detected tap. A tap = exactly 3 fingers down together
  (within ~120 ms), total contact ≤ 300 ms, movement ≤ small threshold, all lift, no 4th
  finger, debounce 600 ms. Return false from `start()` if the framework or a device is
  unavailable. The owner's system three-finger tap (Look Up) is OFF; 3-finger swipes are ON
  (must not trigger: movement threshold).
- WakeWordListener: on-device only (`SFSpeechRecognizer(locale: en-US)`,
  `requiresOnDeviceRecognition = true`, refuse to start if on-device isn't supported, so no
  audio ever leaves the Mac in this mode). AVAudioEngine input tap → recognition request.
  Restart the task before Apple's ~1 min limit and after each command. A command = speech
  containing the name ("Rio" + variants from `TeddyCommand.names`, plus "hey Rio") followed
  by words, finished by ~1.2 s of silence or a final result. Emit only the text after the name
  (via the pure `WakePhraseExtractor`). Speech without the name is dropped and never stored.
  Expose `pause()`/`resume()` so dictation can take the mic. Request speech permission only
  from `start()`. Info.plist already has NSSpeechRecognitionUsageDescription. Update its
  wording to mention Rio.

## Wave 2 (after the lead merges wave 1)

### Builder D: conversation mode integration (`feat/rio-actions-d`)
AppState toggle `isConversationModeOn`; three-finger tap toggles it; a menu bar item too;
"stop listening" turns it off; auto-off after 15 min without a command (setting); a soft
sound on/off; while on, the menu bar teddy shows a listening variant
(`RioMenuBarIcon.listeningTemplateImage`: teddy plus a small dot/waves) and the pill shows a
small "Listening…" bear between commands; pause the listener during Fn/Fn+Ctrl sessions and
resume after. Each heard command → `RioActionCoordinator` (same feedback as the action key).
Settings: gesture toggle, auto-off minutes, and an explanation that the mic stays on and
nothing leaves the Mac until it hears "Rio".

### Builder E: smart AI actions (`feat/rio-actions-e`)
`SmartActionResolver: RioSmartResolving` uses the configured LLM (same API key, base URL and
transport as post-processing, `LLMAPITransport`) with a strict JSON schema / tool list that maps
ONLY to the closed `RioAction` set; unknown → `[]`. Validate every field; drop anything
malformed. Then the executors:
- `sendMessage`: resolve the contact (Contacts framework name match, ask permission on first
  use) and ALWAYS confirm in a Rio panel showing the recipient and the exact text, with Send
  (Return) and Cancel (Esc; 20 s timeout = cancel). Send through Messages via NSAppleScript.
  Needs entitlement `com.apple.security.automation.apple-events` and
  NSAppleEventsUsageDescription and NSContactsUsageDescription in Info.plist.
- `createReminder`: EventKit (`requestFullAccessToReminders` on macOS 14+, legacy on 13), with
  NSRemindersFullAccessUsageDescription and NSRemindersUsageDescription.
- `selectionTask`: read the selection with the existing selection snapshot; summarize, explain
  and translate show the answer in a small Rio result panel with Copy; improve replaces the
  selection the same way Edit Mode does.
- Settings toggle "Smart actions" (default ON) with the disclosure that unrecognised commands
  and, for selection tasks, the selected text are sent to the configured LLM provider.

## Rules for every builder
- Read `AGENTS.md` first and follow it. No new dependencies, no SPM/Xcode project. Swift 6.2
  toolchain, deployment target macOS 13, `-warnings-as-errors`. Use `#available` for newer APIs.
- Build and test with `PATH=/usr/bin:$PATH make check` (conda's codesign shadows Apple's). New
  test files need registering in `Tests/TestMain.swift` and their production sources in
  `TEST_PRODUCTION_SOURCES` in the Makefile. Keep testable logic in pure files without AppKit.
- Tests never touch the network, the real mic, the real trackpad or real apps.
- Privacy: never log or persist transcripts, selected text or contacts. No telemetry.
- Do NOT install into /Applications, quit the running Rio Dictate, change system permissions,
  push, or touch other branches. Commit to your own branch only, with conventional messages
  ending in `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Plain `git commit`
  (`--no-verify` is blocked by a hook; the repo has no git hooks anyway).
- A "Fact-Forcing Gate" hook may block Write/Edit/Bash until you state some facts (callers,
  affected APIs, the user's instruction). State them briefly and retry. The user's instruction
  is: "Deploy multiple agents to build this and then you can have a separate agent test it,
  make sure it is accurate, and do an audit of errors and stuff before you give me the final
  product."
- Finish with: files added/changed, test count added, `make check` result, anything
  stubbed, any contract change you need, and anything you could not verify.

## After the waves
1. A separate **tester** agent builds the merged app and exercises it on the real Mac (parser
   corpus, open/quit/switch safe apps, websites, volume set-and-restore, window placement on
   TextEdit, conversation mode with `say` through the speakers). It never locks the screen,
   sends a message, or quits the owner's apps.
2. An **Opus 5.5 auditor** reviews the full diff for correctness, safety (closed action set,
   no injection into Process/AppleScript), privacy, concurrency and regressions in dictation.
3. A **fixer** addresses the confirmed findings, and the lead re-verifies the fix diff, runs
   `make check`, builds the signed Rio Dictate.app (build 116+), installs it and does a final
   smoke test.
