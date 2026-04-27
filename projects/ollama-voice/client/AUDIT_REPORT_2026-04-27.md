# Ollama-Voice Flutter Client — Audit (2026-04-27)

> ⚠️ **PARTIALLY STALE (2026-04-27 morning).** This report was written before
> commits `ea3ede61` (server refactor + 135 tests) and `baea2d40` (client
> HandsFreeController + secure storage + bug fixes + dead-code purge) landed
> the same day. Many "critical issues" and "real bugs" listed below are now
> resolved — see the [Resolution Status](#resolution-status-as-of-2026-04-27-evening)
> section directly under the Executive Summary for the current picture. The
> body of the report is preserved verbatim as a snapshot of what was true at
> the moment of writing; do not treat its severity scores or open-issue lists
> as live state without consulting the resolution table.

**Auditor:** Claude (collaborative session with Anthony)
**Date:** 2026-04-27 (morning snapshot — see banner above for what changed since)
**Scope:** All `lib/*.dart` (23 files, ~5,200 lines), `pubspec.yaml`
**Method:** Full-file reads + targeted greps. Findings cite `file:line` against
the working tree as of this date. Cross-references to the prior 2026-04-25 audit
note which findings are persistent vs. addressed.

---

## Executive Summary

The codebase has stabilized noticeably since 2026-04-25 — `AudioCoordinator`
unified the mic ownership story, the WebSocket got pong-timeout handling, and
the dispose/lifecycle hot-spots in `MainScreen` got a 200-line rewrite. The
**wire format with the post-refactor server is exact** (verified separately):
all 8 outgoing message types match the server's discriminated union, all 18
incoming types are handled.

That said, three of the prior audit's critical items (hardcoded auth token,
plaintext credential storage, no TLS pinning) are **still unaddressed**, and
one of the items the fix-up commit *claimed* to fix (`AudioCoordinator.dispose`
race) is **not actually fixed in code**. Several hundred lines of dead code
(`RecorderService`, `WakeWordService`) and an unused heavy dependency
(`porcupine_flutter`) survive.

| Metric | Score |
|---|---|
| **Overall health** | **66 / 100** |
| Server↔client wire contract | 95/100 |
| Code correctness | 60/100 |
| Security | 40/100 |
| Architecture | 55/100 |
| Async/lifecycle | 65/100 |
| Dependencies | 70/100 |
| Dead code | 55/100 |

**Top three concerns**

1. **Security trio still open.** Hardcoded default token, plaintext
   `SharedPreferences`, no TLS pinning. Same as 2026-04-25. Blocks any
   non-personal deployment.
2. **`AudioCoordinator.dispose()` is still a fire-and-forget race**, despite
   commit `38145852` claiming "sync dispose."
3. **`MainScreen` is still a 1,066-line god widget** holding 9 stream
   subscriptions, 4 booleans + an enum to track HF state, and direct
   orchestration of audio recording, WS comms, Bluetooth, proximity, wake-word,
   notifications, and rendering.

---

## Resolution Status (as of 2026-04-27 evening)

The audit body below was written before commits `ea3ede61` (server) and
`baea2d40` (client) landed the same day. This section maps each finding to
its current state. Anything not listed here is still open or explicitly
deferred — the body of the report remains the authoritative description.

### Resolved by today's commits

| Audit ID | Finding | Resolution |
|---|---|---|
| **C1** | Hardcoded default auth token (`'ollama-voice-token-change-me'`) | Removed. `authToken` getter returns `''` when unset; `connect()` refuses to attempt with no token and surfaces a clear error. |
| **C2** | Auth token in plaintext `SharedPreferences` | Migrated to `flutter_secure_storage` 9.x with Android `encryptedSharedPreferences: true`. One-time silent migration from legacy storage on first launch. |
| **C4** | Malformed JSON crashes the app | Both `jsonDecode` sites in `WebSocketService` now `try/catch` and drop the frame on `FormatException`. |
| **C5** | `AudioCoordinator.dispose()` async-fire-and-forget race | Synchronous teardown: subs cancelled and stream controllers closed before `super.dispose()`; recorder shutdown via `unawaited()` after streams are closed so any late callbacks become no-ops. |
| **A1** | `MainScreen` god widget (1,066 lines, 9 subs, mixed concerns) | `VoiceController` extracted (`lib/providers/voice_controller.dart`, ~800 lines). `_MainScreenState` body is now ~265 lines of UI-only code. (Note: `main_screen.dart` file is still 929 lines because of inline widget classes `_ConversationDrawer`, `_LatencyOverlay`, `_SettingsSheet` that weren't part of the god-widget concern.) |
| **A6** | `manualReconnect` / `reconnectWithNewConnectionId` near-duplicates | Merged into `manualReconnect`; `connection_replaced` event handler now calls it directly. |
| **DC1** | `RecorderService` (192 lines) unused | Deleted. |
| **DC2** | `WakeWordService` (440 lines) unused | Deleted. |
| **DC3** | `_stopWakeWordListeningOnly` duplicate of `_stopWakeWordListening` | Deleted. |
| **DC4** | Unused `final appState = …` local in `_onConnectionStateChanged` | Removed. (Side note: this dead-code line was the original developer's intent-marker for a HF-toggle bug fix; once removed, the underlying bug surfaced and was also fixed — see "New finding" below.) |
| **DC6** | `porcupine_flutter` declared but unused | Removed from `pubspec.yaml`. Saved ~10 MB of bundled ML model assets. |
| **L2** | `_startHandsFreeStreaming` partial-failure leaves recorder running | Catch path now tears down recorder + Bluetooth SCO + audio mode before rethrowing. |
| **Q3** | Verbose `print()` on every WS frame in production | All 25 sites in `WebSocketService` now gated on `kDebugMode`. |
| **Q4** | Server URL has no validation | Settings dialog rejects invalid input inline (must `Uri.tryParse`, have non-empty host, scheme in `{ws, wss, http, https}`). |

### New finding surfaced and fixed during the controller refactor

- **HF toggle didn't start the mic until app-resume.** A pre-existing gap
  (the dead-code DC4 line was the original developer's intent-marker for
  this fix). `_onConnectionStateChanged` now starts HF streaming when
  connected AND `handsFreeEnabled`. Idempotent. Verified by manual test
  (path #3).

### Still open or explicitly deferred

| Audit ID | Status | Note |
|---|---|---|
| **C3** TLS pinning | Deferred | Overkill for personal-use deployment. Revisit if shipping to others. |
| **C6** Auth handshake brittle | Open | Listener treats first non-`auth_ok` event as failure. Defensive issue, not a known live bug. |
| **A2** 5-way HF state split | Partial | Fields moved into `VoiceController`; consolidation into a single phase enum still pending. |
| **A3** Homegrown DTW wake-word matcher | Open | `porcupine_flutter` was removed without a replacement. Decision deferred: keep the DTW matcher, integrate `sherpa-onnx` keyword spotting, or accept the current accuracy. |
| **A4** PlayerService dual notification API (`onPlaybackEnded` callback + `playbackCompleteStream`) | Open | Pick one — the stream is the canonical pattern. |
| **A5** Stream-controller defensive `if (!_stream.isClosed)` checks | Partially mitigated | The dispose race fix (C5) removed the underlying cause, but the defensive checks remain. Could remove most of them. |
| **L1** `BuildContext` after async without `mounted` checks | Mostly resolved | The big offender (`MainScreen`) is now thin; remaining sites are in the Settings sheet. |
| **L3** `_eventChain` swallows sync exceptions | Open | `Future.then().catchError()` only catches async errors; pre-await throws escape. Wrap in `try/catch` or `Future.sync(() => …)`. |
| **L4** `audio_session` vs MethodChannel mode conflict | Open | Two APIs touching the same Android audio mode. |
| **L5** Bluetooth continuous scan | Open | Battery cost. |
| **Q1** No client-side audio backpressure | Deferred | Needs sink-rewrite (`WebSocket.done` per-chunk or pause-the-source). Not a real-world problem under current network conditions. |
| **Q2** `connection_id` rotates per reconnect | Open (design choice) | Server can't dedupe reconnects from the same client. Fix would be to persist + reuse the UUID with a TTL. |
| **Q5** Magic numbers throughout | Open | Cosmetic until tuning is needed. |
| **Q6** SQLite no migration path | Open | Schema changes will require a wipe. Add `onUpgrade` when adding fields. |
| **Q7** `bufferChunk` drops silently on overflow | Open | Per-chunk log; should escalate to UI error so users know audio was clipped. |

### Updated scores (post-commits)

| Metric | Before | After | Δ |
|---|---|---|---|
| Overall health | 66/100 | ~80/100 | +14 |
| Code correctness | 60 | 80 | +20 (C4, C5, HF-toggle bug all fixed) |
| Security | 40 | 75 | +35 (C1, C2 fixed; C3 deferred) |
| Architecture | 55 | 75 | +20 (A1 controller extraction; A6 dedup) |
| Async/lifecycle | 65 | 75 | +10 (L2 fixed, L1 mostly resolved by controller move) |
| Dependencies | 70 | 80 | +10 (porcupine removed; flutter_secure_storage added) |
| Dead code | 55 | 95 | +40 (632 lines removed) |
| Server↔client wire contract | 95 | 95 | unchanged |

---

## 1. Wire contract with server — clean

| Direction | Coverage |
|---|---|
| Client → server | 8/8 server-defined incoming types match exactly (`auth`, `interrupt`, `end_recording`, `tts_request`, `text_query`, `ping`, `get_config`, `set_config`) |
| Server → client | 18/18 outgoing types mapped in `EventType` enum + `pong` handled inline for keepalive |

No mismatches. Today's server-side refactors (typed dispatch, connection-replacement
race fix, detailed Ollama errors) are all observable from the existing client.

**Dormant fields (no current bug, but worth cleaning up):**
- Server's `AuthMessage.agent` — sent by client, never read by server. Dead either way.
- Server's `AuthMessage.system_prompt` — supported in the protocol but client
  comments at `websocket_service.dart:113, 122` say it's "intentionally omitted —
  use set_config instead." About 20 lines of unreachable server-side code.

---

## 2. Critical issues

### C1. Auth token hardcoded in source — UNFIXED (was C1 in prior audit)

**File:** `lib/services/config/config_service.dart:31`
```dart
static const String _defaultAuthToken = 'ollama-voice-token-change-me';
```
Even with the `⚠️ SECURITY` comment, a default credential in source ships in
every binary and may be missed during onboarding. The token is also returned by
`authToken` getter at `:47` if the user never set one, meaning the app *will*
attempt to authenticate with this default.

**Fix:** Make `authToken` nullable, return `null` when unset. Block
`VoiceConnectionState.connect()` until a token has been explicitly stored.

### C2. Auth token stored in plaintext — UNFIXED (was C2)

**File:** `lib/services/config/config_service.dart:52`
```dart
Future<void> setAuthToken(String token) => _prefs.setString(_authTokenKey, token);
```
Plain `SharedPreferences`. On a rooted Android device or via ADB backup,
trivially extractable.

**Fix:** Use `flutter_secure_storage` (Android Keystore / iOS Keychain).

### C3. No TLS certificate validation or pinning — UNFIXED (was C3)

**File:** `lib/services/network/websocket_service.dart:62-68`
```dart
final socket = await WebSocket.connect(
  uri.toString(),
  protocols: ['openclaw-voice'],
).timeout(...);
```
No `SecurityContext`, no certificate pinning. A network attacker who can swap
DNS or intercept TLS could capture the auth token sent on the first frame.

**Fix:** Pin the server certificate or at minimum validate the chain via a
custom `SecurityContext`. Document that anything pointing at `wss://` from
outside the LAN must use a real CA-issued cert.

### C4. Malformed JSON crashes the app

**File:** `lib/services/network/websocket_service.dart:81, 176`
```dart
final event = WebSocketEvent.fromJson(jsonDecode(data));
```
Bare `jsonDecode` propagates `FormatException` through the stream listener and
crashes the whole isolate. The current server (post-2026-04-27 refactor) only
sends well-formed JSON, but corrupted frames, mitm, or future protocol changes
trip this.

**Fix:** Wrap both call sites in `try/catch` and log+drop on `FormatException`.

### C5. `AudioCoordinator.dispose()` is async fire-and-forget — STILL BROKEN

**File:** `lib/services/audio/audio_coordinator.dart:259-262`
```dart
@override
void dispose() {
  stopAll().then((_) => _cleanupAsync()).catchError((_) {});
  super.dispose();
}
```
Commit `38145852` claims "AudioCoordinator: sync dispose" but this is still
the same async fire-and-forget pattern flagged in the 2026-04-25 audit (C6).
`super.dispose()` runs immediately while `stopAll()` is mid-execution.
Subsequent `_amplitudeStream.add(...)` calls in the recorder progress callback
race against the closing of the stream controllers in `_cleanupAsync()`.
Symptom: `Bad state: Cannot add event after closing.`

**Fix:** Cancel `_progressSub` synchronously *before* `super.dispose()`.
Close stream controllers synchronously. The recorder's `closeRecorder()` can
stay async via `unawaited()` — it's the controller close that must precede
the dispose.

### C6. Auth handshake brittle to multi-message pre-auth

**File:** `lib/services/network/websocket_service.dart:79-91`
```dart
if (event.type == EventType.authOk) {
  _authenticated = true;
  completer.complete(true);
} else {
  print('[WebSocket] Unexpected event: ${event.type}');
  completer.complete(false);
}
```
Treats *any* non-`auth_ok` event during connect as authentication failure.
Today the server only sends `auth_ok` or `auth_failed` pre-auth, but a future
protocol addition (e.g. `server_hello` with version info) would break the
client. Auth-failed correctly fails; first-event-wins is overly strict.

**Fix:** Loop until `auth_ok` (success), `auth_failed` (failure), or timeout
(failure). Drop other events.

---

## 3. Architectural issues

### A1. `MainScreen` is a 1,066-line god widget

Down from 1,200+ pre-fix, but the structure didn't change — only the line count.
It owns:

- 9 `StreamSubscription` references (lines 32-40)
- 4 boolean lifecycle flags (`_pttActive`, `_handsFreeStreaming`, `_isResponding`,
  `_isProcessing`) — duplicated by `appState.handsFreePhase` enum
- All state transitions for hands-free (start, stop, return-to-listening,
  background/foreground, barge-in)
- Direct WebSocket event dispatch (`_handleEvent` is 130 lines with 10 branches)
- Direct PlayerService control via `onPlaybackEnded` callback
- Audio mode + Bluetooth + proximity coordination
- Text-input UI + voice-input UI + settings sheet + drawer + latency overlay

**Recommendation:** Extract a `HandsFreeController` or `ConversationCoordinator`
class that:
1. Holds the 9 subscriptions
2. Drives the phase enum (single source of truth)
3. Exposes a simple imperative API (`startHandsFree()`, `stopHandsFree()`,
   `onPttPressed()`, `onPttReleased()`, `interrupt()`, `sendText(text)`)
4. Surfaces a single `Stream<MainScreenViewModel>` for the widget to render

`MainScreen` then becomes ~200 lines of pure rendering. The hands-free state
machine becomes independently testable.

### A2. Hands-free state is split across 5 fields

| Field | Owner | Purpose |
|---|---|---|
| `_handsFreeStreaming` | MainScreen | Whether the streaming pipeline is active |
| `_isResponding` | MainScreen | Whether the LLM is mid-response |
| `_isProcessing` | MainScreen | Whether STT is running |
| `_pttActive` | MainScreen | Whether the PTT button is pressed |
| `appState.handsFreePhase` | AppState | UI phase (idle/wakeWord/recording/processing/speaking) |

These can disagree. E.g. `_isResponding=true` while `handsFreePhase=recording`
is reachable if `responseStart` arrives during a barge-in race. The phase enum
should be the only state; the booleans should be derived from it.

### A3. Wake-word detection is ~250 lines of homegrown DTW

**File:** `lib/services/audio/audio_coordinator.dart:329-570`

Energy-based pattern matching with hand-tuned 4-snapshot × 5-band templates per
phrase + DTW distance scoring. Maintenance liability:

- Adding a new wake phrase requires hand-authoring a template (`_heyKimiTemplate`,
  etc. at lines 421-446). No way to "train" or test these.
- Templates are fragile to mic position, voice pitch, accent.
- False-positive rate is uncontrollable without dataset evaluation.
- `pubspec.yaml:52` has `porcupine_flutter: ^3.0.3` — a production-grade
  on-device wake-word engine — that is **not used anywhere**. Only mentioned in
  a comment in dead code (`wake_word_service.dart:11`).

**Recommendation:** Either (a) actually wire up porcupine and delete the
homegrown matcher, or (b) drop the porcupine dependency since it's adding APK
weight for nothing.

### A4. Two state-management libraries are in play

`Provider` is the official choice (per `main.dart`), but `PlayerService`
exposes a callback (`onPlaybackEnded`) **and** a stream (`playbackCompleteStream`)
that both fire on playback end. `MainScreen._scheduleReturnToListening` listens
to one, `_startHandsFreeStreaming` registers a callback for the other. Two
ways to do the same thing → easy to update one and miss the other.

**Fix:** Drop `onPlaybackEnded`, use the stream everywhere.

### A5. Stream controllers are guarded with `if (!_stream.isClosed)` checks

`audio_coordinator.dart` has 6 such checks (lines 108, 170, 253, 311, 322, 403);
several others elsewhere. This pattern reflects an underlying lifecycle
mismatch — the streams' lifetime isn't aligned with the data sources, so
defensive checks are needed. Consolidating ownership (A1, C5) would remove
most of these.

### A6. `manualReconnect` and `reconnectWithNewConnectionId` duplicate logic

**File:** `lib/providers/connection_state.dart:132-154`

The two methods are nearly identical. The only difference is reset of
`_retryCount`, but `reconnectWithNewConnectionId` also resets it (line 151).
True duplication.

**Fix:** Single method `reconnect({bool fresh = true})`.

---

## 4. Dead code

### DC1. `RecorderService` (192 lines) — UNUSED

**File:** `lib/services/audio/recorder_service.dart`

Replaced by `AudioCoordinator`. Only self-reference (`class RecorderService`).
No imports of this class anywhere in `lib/`.

### DC2. `WakeWordService` (440 lines) — UNUSED

**File:** `lib/services/audio/wake_word_service.dart`

Replaced by the wake-word logic now embedded in `AudioCoordinator`. The class
declaration and an internal `print()` are the only references in the codebase.

### DC3. `_stopWakeWordListeningOnly` is identical to `_stopWakeWordListening`

**File:** `lib/screens/main_screen.dart:730-738`
```dart
Future<void> _stopWakeWordListeningOnly() async {
  _removeWakeWordListener();
  await context.read<AudioCoordinator>().stopWakeWordListening();
}

Future<void> _stopWakeWordListening() async {
  _removeWakeWordListener();
  await context.read<AudioCoordinator>().stopWakeWordListening();
}
```
Bit-for-bit identical, both private. Either was meant to do something different
(check git blame for intent) or one is dead.

### DC4. Unused local variable

**File:** `lib/screens/main_screen.dart:117`
```dart
} else {
  // ...
} else {
  unawaited(_stopHandsFreeStreaming()...);
}
// inside the if-isConnected branch above:
final appState = context.read<app.AppState>();  // ← assigned, never used
```
`appState` declared at line 117 is unused inside its scope.

### DC5. `ConversationStorage.pruneOldConversations[IfNeeded]` exists but never called

**File:** `lib/services/storage/conversation_storage.dart:142, 152`

Pruning logic is implemented but no caller invokes it. Conversations grow
unbounded. Either wire up a periodic prune (e.g. on app start, after a
threshold) or document why pruning isn't needed.

### DC6. `porcupine_flutter` dependency unused

`pubspec.yaml:52` declares it. `grep -r porcupine` finds it only in a comment
inside dead code. Adds APK weight (~10 MB) for zero benefit.

---

## 5. Async / lifecycle

### L1. `BuildContext` after async without `mounted` checks

The 2026-04-25 audit (C5) flagged this; the 2026-04-25 fix-up commit added
guards in many places, but several remain in the settings sheet. Examples:

`lib/screens/main_screen.dart:1316-1318` (and similar at 1373, 1478, 1565, 1586):
```dart
onChanged: (v) async {
  await appState.setHandsFreeEnabled(v);
  if (context.mounted) {
    Navigator.pop(context);
    await conn.manualReconnect();
  }
},
```
`context.mounted` is checked, but inside the block, `Navigator.pop(context)`
is followed by `await conn.manualReconnect()` — between those, the route is
already popped. The await on `manualReconnect` then completes against a
disposed sheet. Currently survives because nothing else needs the sheet's
context, but fragile.

`lib/screens/main_screen.dart:171-176` in `didChangeAppLifecycleState`:
```dart
if (appState.backgroundListeningEnabled && appState.wakeWordEnabled) {
  unawaited(_startWakeWordInBackground().catchError(...));
} else {
  unawaited(_stopHandsFreeStreaming().catchError(...));
  unawaited(context.read<AudioCoordinator>().stopAll().catchError(...));
  appState.setRecording(false);
}
```
`context.read` here is called from `didChangeAppLifecycleState` which can fire
after dispose. `appState` was captured pre-call though, so it's fine — but the
inline `context.read<AudioCoordinator>()` is sketchy.

### L2. `_startHandsFreeStreaming` partial-failure leaves recorder running

**File:** `lib/screens/main_screen.dart:502-620`

Sets `_handsFreeStreaming = true` at the top. On exception inside the try
block, the catch sets it back to false and rethrows. But by that point,
`recorder.startRecording()` may have already started — the recorder is left
running with no listener. The rethrow propagates out and the caller's
`catchError` only logs.

**Fix:** `try/catch` should `await recorder.stopAll()` in the catch block
before rethrowing.

### L3. `_eventChain` chain swallows sync exceptions

**File:** `lib/screens/main_screen.dart:209-213`
```dart
_wsEventSub = conn.eventStream?.listen((event) {
  _eventChain = _eventChain
      .then((_) => _handleEvent(event))
      .catchError((e) => print('[MainScreen] Event handler error: $e'));
});
```
`Future.then()` catches *async* errors; if `_handleEvent` throws synchronously
before its first `await`, the error escapes. Defensive — wrap `_handleEvent`
body in try/catch or use `Future.sync(() => _handleEvent(event))`.

### L4. `_initServices` doesn't await most of its work

**File:** `lib/screens/main_screen.dart:130-137`
```dart
Future<void> _initServices() async {
  final player = context.read<PlayerService>();
  final config = context.read<ConfigService>();
  await player.init();
  await player.setSpeed(config.playbackSpeed);
  _startBluetoothMonitoring();
  unawaited(_connectIfNeeded()...);
}
```
The fire-and-forget `_connectIfNeeded` means `_initServices` returns before
connection attempts begin. `initState` doesn't await it either. Race: if the
user taps PTT before connection is up, the call no-ops. Probably intended,
but worth documenting.

### L5. `flutter_blue_plus` scans continuously

**File:** `lib/services/audio/bluetooth_service.dart:35-65`

`_startScan()` is called whenever the BT adapter turns on, and the scan is
left running. BLE scans are battery-expensive on Android. Should scan briefly
(e.g. 5 s on adapter-on, or only when entering hands-free mode) and stop.

---

## 6. Code-quality / robustness

### Q1. No client-side audio backpressure

**File:** `lib/services/network/websocket_service.dart:187-194`
```dart
void sendAudio(dynamic pcmData) {
  if (pcmData is Uint8List) {
    _channel?.sink.add(pcmData);
  }
}
```
No flow control. The server has a bounded `hf_audio_q` (drops oldest when
full); the client has no equivalent. On a slow uplink in hands-free mode, the
WS sink's internal buffer can grow unboundedly. Less catastrophic than a
crash, but on bad networks could OOM.

**Fix:** Track `_audioBufferLength` against a cap (e.g. `5 MB`); drop chunks
above the cap and log once per session like the server does.

### Q2. `connection_id` rotates on every reconnect

**File:** `lib/services/network/websocket_service.dart:56`
```dart
_connectionId = const Uuid().v4();
```
A new UUID per connect attempt. The server's `auth.connection_id` field exists
to let a returning client preserve identity across reconnects (for, e.g.,
preserving server-side session state) — but the client never persists or
reuses its UUID. If you want continuity, persist the UUID in `ConfigService`
and reuse on reconnects within a TTL.

### Q3. Verbose `print()` on every WS frame

**File:** `lib/services/network/websocket_service.dart:78`
```dart
print('[WebSocket] Received data: ${data is String ? data.substring(0, ...) : "binary"}');
```
Logs the prefix of every incoming text frame — including each `response_delta`
token (so dozens of log lines per LLM reply). On Android these go to logcat
where they may be visible to other apps with `READ_LOGS` permission. Should be
behind a debug flag.

### Q4. Server URL has no validation

**File:** `lib/screens/main_screen.dart:1556-1566`

Tapping "Server URL" opens `_showEditDialog` which writes the raw text
back into config. No `wss://` requirement, no `Uri.parse` check. A user can
enter `ws://` (cleartext) or `https://api.example.com/ws` (wrong scheme) or
non-URL garbage; connection then fails with a cryptic error.

**Fix:** Validate with `Uri.tryParse` + scheme check before saving.

### Q5. Magic numbers throughout

VAD thresholds (`0.04`), frame counts (3, 8, 20), buffer sizes (64000, 1024,
4800), timeouts (60s, 25s, 200ms). Hard to tune for different mics or use
cases without code changes. At minimum, name them at module scope (some are,
some aren't).

### Q6. SQLite schema has no migration path

**File:** `lib/services/storage/conversation_storage.dart:17-50`

Single-version `CREATE TABLE` with no `onUpgrade`. Future schema changes
require deleting the DB and losing all conversations.

### Q7. `bufferChunk` drops silently on overflow

**File:** `lib/services/audio/player_service.dart:166-174`
```dart
if (_audioBufferLength + data.length > _maxBufferBytes) {
  print('[Player] Audio buffer limit reached (${_maxBufferBytes ~/ 1024}KB), dropping chunk');
  return;
}
```
Logs once per chunk (so could spam logs during a stuck stream) and silently
truncates audio. Better: stop accepting and surface an error to the UI so the
user knows audio was clipped.

---

## 7. Dependencies

| Package | Version | Status |
|---|---|---|
| flutter_sound | ^9.2.13 | Fine; FlutterSound has known Android lifecycle quirks but no active concern |
| just_audio | ^0.9.36 | Fine |
| audio_session | ^0.1.18 | Conflicts mildly with `AudioModeService.setVoiceCommunicationMode()` MethodChannel — both touch Android audio mode |
| provider | ^6.1.1 | Fine |
| shared_preferences | ^2.2.2 | **Fine for non-secret data only** (see C2) |
| sqflite | ^2.3.0 | Fine |
| connectivity_plus | ^5.0.2 | Outdated (7.x exists with API changes) — comment at `connection_state.dart:51` already notes 5.x quirks |
| **porcupine_flutter** | **^3.0.3** | **UNUSED — remove or wire up** (see DC6) |
| flutter_blue_plus | ^1.32.0 | Used continuously, see L5 |
| share_plus | ^10.0.0 | Fine |
| flutter_markdown | ^0.7.0 | Used (in MessageList, presumed) |
| wakelock_plus | ^1.0.0 | Fine |
| flutter_local_notifications | ^17.0.0 | Fine |
| flutter_lints | ^3.0.1 | Declared, but no `analysis_options.yaml` enables them. Lints aren't enforced. |

---

## 8. Recommended next steps (ordered)

1. **Fix C5** (AudioCoordinator dispose race). One-file edit. Real bug.
2. **Fix C4** (malformed JSON crash). Two `try/catch` blocks. Trivial.
3. **Delete dead code** (DC1 RecorderService, DC2 WakeWordService, DC3 duplicate
   helper, DC4 unused var, DC6 unused dependency). About 600 lines + an APK-bloat
   dependency. No risk — confirmed unreferenced.
4. **Address security trio** (C1, C2, C3) before any non-personal deployment.
   Migrate to `flutter_secure_storage`, remove default token, document or
   implement TLS pinning.
5. **Extract `HandsFreeController`** from MainScreen (A1). Biggest architectural
   win remaining; downstream of A2, A4, A5 cleanups.
6. **Decide on wake-word strategy** (A3): wire porcupine or delete the homegrown
   DTW matcher (and the porcupine dep).
7. **Polish bundle**: Q1 backpressure, Q3 debug-flag prints, Q4 URL validation,
   A6 reconnect dedup, L2 partial-failure cleanup, L5 scan budget.

The codebase is fundamentally sound and deployable for personal use today (it
already is). The blockers for anything beyond personal use are the security
trio. Architecture is the main cost-of-ownership concern long-term.
