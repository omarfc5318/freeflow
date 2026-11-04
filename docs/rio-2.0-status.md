# Rio 2.0 status (2026-11-04)

Installed: `/Applications/Rio Dictate.app`, version 2.0 build 123, branch `feat/rio-actions` (a86c2f3).
All tests pass (`PATH=/usr/bin:$PATH make check`). No crash reports since build 115's fixed crash.

## Keys
- Hold **Fn**: dictation. **Double-tap Fn**: hands-free dictation.
- Hold **Fn + Control**: action key (say what to do; "Rio" optional).
- **Left Fn + left Control + left Option** together: conversation mode on/off (also stops the translator).
- Lone **Right Command**: Fix Last Dictation.
- "Rio, what can you do" / "Rio, help": the command sheet.

## AI providers (all free tier)
- Groq free tier only; nothing is billed without a card on the Groq account.
- Speech to text: `whisper-large-v3` (2,000/day). Dictation cleanup: `openai/gpt-oss-20b` (1,000/day).
  Context: `qwen/qwen3.8-27b` (1,000/day). Rio's command brain: `openai/gpt-oss-120b` (1,000/day,
  its own allowance; setting `rio_smart_resolver_model`).
- Hands-free commands are recognised on the Mac (Apple on-device speech); Groq is used only for Fn
  recordings, Fn + Control, and AI fallbacks (questions, commands Rio can't parse, screen descriptions).
- Test agents must never call Groq (they used up the free limit on 2026-11-04).

## Test-and-fix rounds
| Round | Testers + audits | Findings (HIGH) | Fixer groups | Build |
|---|---|---|---|---|
| 1 | 8 personas/live + 2 Opus audits | 63 + 61 earlier (16) | 6 + dictionary fix | 120 |
| 2 | 8 + 2 | 97 (17) | 6 | 121 |
| 3 | 8 + 2 | 98 (16) | 6 | 122 |
| Lead security follow-ups | automated commit reviews | 9 | lead | 123 |

Lead security fixes after the rounds: planned clicks resolve before deciding; address-bar guard fails
closed; Claude Code send guarded (phone/automation refused, conversation asks, auto-accept asks);
confirmations show exact details; localhost owner-only; Claude Code approvals single-use; permission
prompt start must be a real column-0 boundary; terminal typing from conversation uses an allowlist
plus the live front app; planned links rebuilt only from the owner's words (no login part, port,
query or fragment; path in spoken order); every stop drops the queued conversation command.

## Rejected on purpose (owner direction: "You shouldn't hard-code commands")
Extra hard-coded phrasings the resolver already handles were rejected each round. New capabilities
deferred: now-playing, alarms/pause timer, calendar weekday ranges, Zoom mic/camera, relative volume
("up by 20"), video player controls, Slack/WhatsApp sending, extra window shapes.

## Owner decisions still open
1. Arabic Whisper re-listen in conversation mode is default OFF (privacy); turning it on sends room
   audio to Groq when the on-device guess looks Arabic.
2. Voice-run terminal commands ("run npm install") stay off: typing into a terminal from conversation
   mode always asks.
3. "Type my student ID" from memory is not built (privacy: room audio could type personal facts).

## Setup still needed (owner)
Full Disk Access (messages), Spotify client ID (redirect `http://127.0.0.1:8898/callback`), Notion
token, Canvas token, Location (Wi-Fi triggers), Screen & System Audio Recording.
