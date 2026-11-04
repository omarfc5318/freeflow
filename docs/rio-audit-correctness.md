# Rio v2.0 correctness and reliability audit (Opus 5.5, 2026-11-03)

Scope: feat/rio-actions, c3082f4..HEAD. Verified by the auditor (with two Opus sub-auditors).
Fix all HIGH and MEDIUM items and the LOW batch, with regression tests.

## 1. The build-115 crash: ROOT CAUSE FOUND AND REPRODUCED

This is a stack overflow from a chain of reabstraction thunks, not a use-after-free.

**Root cause:** `Sources/AudioRecorder.swift:108-114`. `onLevelSample`'s lock state is a bare
function type: `OSAllocatedUnfairLock<(@Sendable (Float, TimeInterval) -> Void)?>`. Every
`withLock` passes it `inout` through generics and writes it back wrapped in a new reabstraction
thunk, so each read adds a layer. `updateAudioLevel` (:788) reads it once per sample buffer, so
the chain grows all recording. When main clears it (AppState:2244), the capture queue frees
about 3,000 nested contexts recursively and overflows its 544 KB stack (SIGBUS).

**Repro:** scratchpad `lockthunk/t4.swift`.

**Fix (verified: 100k reads, then release on a 544 KB thread):**
```swift
private struct LevelSampleSlot: Sendable { var callback: (@Sendable (Float, TimeInterval) -> Void)? }
private let levelSampleHandlerLock = OSAllocatedUnfairLock(initialState: LevelSampleSlot())
var onLevelSample: (@Sendable (Float, TimeInterval) -> Void)? {
    get { levelSampleHandlerLock.withLock { $0.callback } }
    set { levelSampleHandlerLock.withLock { $0.callback = newValue } }
}
```

**Same treatment for `onPCM16Samples` (:104):** it is an unlocked closure var, set and cleared
on main (AppState 3263/3593/3599/3627) and read per buffer on the capture queue
(`emitPCM16IfNeeded`, :855). That is a data race; use the same struct-slot lock.

**Regression test:** a pure slot type in TEST_PRODUCTION_SOURCES. Read it 100,000 times, then
release it on a `Thread` with `stackSize` 512 KB.

## 2. HIGH
- **H1.** Turning "Launch at login" off while launchd started Rio kills him:
  `RioLaunchAtLogin.swift:44` calls `agent.unregister()`. Fix: when `XPC_SERVICE_NAME == label`,
  defer unregister to `applicationWillTerminate`. Or keep the agent, store
  `launchAtLogin=false`, and have the agent copy `exit(0)` unless the crash marker is set.
- **H2.** A crash at launch loops forever (`KeepAlive{SuccessfulExit=false}`, ThrottleInterval 5).
  Fix: keep crash timestamps in the marker. At 3 or more within about 2 minutes, `exit(0)`
  before AppState is built, and alert on the next manual launch.
- **H3.** Bare "go back" is media Previous (`RioActionParser+Controls.swift:69`), but Help lists it
  as browser back. Fix: parse it as `.browser(.back)`. The browser handler falls back to the
  media key when no browser is frontmost. Update `RioActionParserTests.swift:216`.
- **H4.** Memory's whole-sentence pre-pass (`RioActionParser.swift:18`, `RioPersonalPhrases.wholeUtterance`)
  runs recall before everything else. "what's my next class / appointment / call", "upcoming
  meeting" all become recall and answer "I don't have anything saved…". Fix: keep only
  remember, note and calculate in the pre-pass, with recall back in its slot. Widen
  `systemTopics` with `(?:next|upcoming)\s+\S+`. A recall miss falls through instead of returning
  `.done`.

## 3. MEDIUM
- **M1.** A failed action-key recording leaves `rioActionSessionRequested` latched:
  `handleRecordingFailure` (AppState ~2811) and the permission-error stop (~3795) don't call
  `clearRioActionSession()`, and `toggleRecording()` doesn't reset it. Fix all three.
- **M2.** A conversation-started task can't be stopped by voice. `handleConversationCommand`
  drops commands while one runs, so "Rio, stop" and "stop listening" are lost. Fix: handle stop
  and stop-listening before the guard (`RioTaskActionHandler.shared.stop()` and/or
  `RioConversationMode.shared.stop(.stopListening)`).
- **M3.** WakeWordListener can stop itself (6 failures :273, resume failure :100, config-change
  :154) without telling `RioConversationMode`, which still shows "listening". Fix: an `onStopped`
  callback that turns the mode off with a reason.
- **M4/M5.** Two ThreeFingerTapMonitors share devices, and `stop()` holds a lock while calling
  MT, risking a deadlock. **Moot: the owner replaced the trackpad tap with a key chord; delete the
  tap monitor (see the plan's fix-round notes).**
- **M6.** `voice.$level` (30 Hz) is mirrored into `@Published rioSpeechLevel` on AppState, which
  re-renders every AppState-observing view 30 times a second while Rio speaks. Fix: the bear
  observes RioVoice and RioCompanionCenter directly; no high-rate values on AppState.
- **M7.** Idle CPU:
  - a running timer keeps the bear at 10 fps plus a 0.2 s tier timer (`RioCompanionMachine.swift:204`,
    `RioCompanionModel.swift:101`, `RioCompanionHub.swift:313`);
  - the sleeping `TimelineView(.animation(minimumInterval: 0.25))` redraws even with the display
    asleep or locked.

  Fix: a 1 s or sleepy tier during timers, `.periodic` for sleep, and pause on occlusion,
  `screensDidSleep` and session resign. Measured: about 5.3 wakeups a second with the bear visible.
- **M8.** Memory matching accepts 2 of 3 words (`RioMemoryMatcher.swift:33`): "forget my mom's
  phone number" deletes dad's. Fix: forget requires every content word; recall must match the
  subject nouns.
- **M9.** A corrupt memory file loads as [] and the next write wipes it (`RioMemoryStore.swift:124`).
  Fix: rename it to `.corrupt-<date>.json` and tell the user.
- **M10.** "the last one" (answering "Which one?") skips a track (`Controls.swift:69`). Fix: "last"
  needs "song" or "track".
- **M11.** "tonight at 12 / at 1 / 12:30 am" resolve to earlier today (`RioDateTimeParser.swift:298`).
  Fix: with tonight or evening, 12 means 00 and 1–4 mean the next morning. Roll an implied
  tonight forward if it's already past.
- **M12.** ".5" parses as 5 (`RioCalculator.swift:41`). Fix: rewrite `(?<![\d.])\.(?=\d)` to "0." first.
- **M13.** A failed undo re-pushes its record (`RioUndoJournal.swift:89`), so a finished timer's
  undo answers "no timer" for 15 minutes. The timer inverse goes through `cancelTimer()`, which
  STOPS A RUNNING TASK. Fix: drop records whose target is gone, and have the timer inverse cancel
  only that countdown.
- **M14.** The Help catalogue has no wave-3 commands (screen, click, the second one, fill,
  tasks, memory, email, notes, math/units/time zones, translator, Arabic). Add them, plus tests.
- **M15.** The "Trust conversation mode" toggle isn't implemented, and the coordinator has no
  command source. See also security M1.
- **M16.** Crash relaunch only covers agent-started copies. A copy launched from the Dock isn't
  relaunched, and turning the toggle on mid-session leaves the job stopped. Fix by handing over
  with `launchctl kickstart`, or document it.

## 4. LOW (fix)
- **Dictation and audio**
  - The translator can capture the first 250 ms of a dictation. AppState should call
    `RioTranslatorMode.shared.setBusy(.dictation, …)` from the same CombineLatest sink as
    conversation mode.
  - `RioOfflineTranscriber`: no cancel or timeout, and "no speech" maps to `.failed`.
  - `typeTextForRioAction` restores the clipboard after a fixed 350 ms; use the dictation
    path's timing.
  - The coordinator is cached for the app's life and scans installed apps once, on main. Rescan
    in the background on app install or launch notifications, or when a match fails.
- **Lifecycle**
  - Every UserDefaults write re-runs the bear's `applyStyle`, relayout and Dock walk
    (`RioCompanionHub.swift:53`). Observe only the bear's keys.
  - The clipboard `ownChangeCounts` set is never pruned.
  - RioVoice tracks utterances by `ObjectIdentifier` and has no `didFinish` watchdog, so
    `isSpeaking` can stick.
  - WakeWordListener:
    - repeated empty finals have no backoff;
    - the rolling buffer is O(n) per tap (use a ring buffer).
  - The duplicate-instance check runs after `AppState()` init, and the `getppid()==1` test misses
    Terminal-started copies.
  - The `setLaunchAtLogin` catch re-enters `didSet`.
  - `networksetup` output is read only in the termination handler.
  - Screen follow polls while the display sleeps.
- **Logic**
  - "for me" and "…and look for" task patterns can never fire.
  - "book a table at Nobu Friday at 8" becomes a calendar event.
  - "add game night Friday" gets the title "Game".
  - Explicit past times are accepted silently.
  - "remember that" saves the fact "that".
  - "say that again" with no translation should repeat Rio's last line.
  - "Rio, stop" while translating says "There's no timer running"; it should stop the translator.
  - A second timer silently replaces the first; say so.
  - Timer notification scheduling and a ghost notification after relaunch.
  - "1 divided by 3 billion" gives 0.
  - "50% of 50% of 80" fails.
  - The meeting picker opens a link up to 24 h away; limit it to now or the next 15 minutes,
    otherwise say when it is.
  - "-2^2" loses its minus in `stripEnvelope`.
  - Notes appends to a deleted "Rio Notes" note (it's in Recently Deleted). Check the note's folder.

## Verified OK
- Fn-only dictation (the action flag latches and resets correctly; action sessions never paste).
- Shortcut isolation.
- Every `MainActor.assumeIsolated` site runs on main.
- Mic hand-off between the wake listener and AudioRecorder.
- Continuations and timeouts.
- Panel and monitor cleanup.
- Parser order.
- One handler per action.
- Calculator precedence.
- The EventKit version gates.
- Translator VAD.
- Info.plist usage strings.
