# Ollama Voice Client — Audit Report
**Auditor:** Vera (verification agent)  
**Date:** 2026-04-25  
**Scope:** Hands-free, wake word, and mic-return-after-playback functionality  
**Key Files Analyzed:** `audio_coordinator.dart`, `wake_word_service.dart`, `recorder_service.dart`, `player_service.dart`, `websocket_service.dart`, `main_screen.dart`, `app_state.dart`, `connection_state.dart`, `audio_mode_service.dart`

---

## Executive Summary

All three reported issues are **confirmed** and stem from a single critical bug in `main_screen.dart` combined with several secondary bugs that compound the problems. The root cause is the `_handsFreeStreaming` flag being unconditionally reset to `false` in a `finally` block, which breaks nearly every hands-free guard check downstream.

| Issue | Root Cause | Severity |
|---|---|---|
| Hands-free does not work | `_handsFreeStreaming = false` in `finally` breaks VAD auto-stop and `_stopHandsFreeStreaming()` | **CRITICAL** |
| Wake word does not work | Duplicate listener accumulation + `stopWakeWordListening()` no-op after mode switch | **CRITICAL** |
| Mic doesn't return after playback | `onPlaybackEnded` never wired + `_playbackCompleteSub` clobbers wake-word phase | **CRITICAL** |

---

## Bug #1 — `_handsFreeStreaming` flag destroyed in `finally` block

**File:** `screens/main_screen.dart`  
**Lines:** ~490–560 (`_startHandsFreeStreaming()` method)  
**Severity:** CRITICAL

### The Code
```dart
Future<void> _startHandsFreeStreaming() async {
  if (_handsFreeStreaming) return;
  ...
  _handsFreeStreaming = true;
  try {
    ...
  } catch (e) { ... rethrow; }
  finally {
    _handsFreeStreaming = false;   // ← BUG
  }
}
```

### Impact
This single line breaks **three separate subsystems**:

1. **VAD auto end-of-speech is completely disabled.** The VAD listener checks `_handsFreeStreaming` before calling `_onHandsFreeSpeechEnd()`:
   ```dart
   _vadSub = coordinator.vadStateStream.listen((vadState) {
     if (vadState == VadState.speechEnd && _handsFreeStreaming) {
       _onHandsFreeSpeechEnd();   // NEVER CALLED after method returns
     }
   });
   ```
   Result: In hands-free mode, the app **never automatically detects that the user stopped speaking**. It relies entirely on server-side VAD, which defeats the purpose of client-side VAD and increases latency.

2. **`_stopHandsFreeStreaming()` is a no-op.** Its first guard is:
   ```dart
   Future<void> _stopHandsFreeStreaming() async {
     if (!_handsFreeStreaming) return;   // Always returns immediately!
     ...
   }
   ```
   Result: Calling `_stopHandsFreeStreaming()` does **nothing**. All subscriptions (`_recorderSub`, `_bargeInSub`, `_vadSub`, `_playbackCompleteSub`, `_proximitySub`) leak. The recorder keeps running. `AudioModeService.resetAudioMode()` is never called. Wake word listeners are never removed. This affects:
   - App going to background (`didChangeAppLifecycleState`)
   - WebSocket disconnect (`_onConnectionStateChanged`)
   - Manual disable of hands-free mode
   - PTT mode switch

3. **Resource leaks on reconnect / resume.** Because `_stopHandsFreeStreaming()` doesn't clean up, when the app reconnects or resumes, `_startHandsFreeStreaming()` creates **duplicate subscriptions** on top of the leaked ones.

### Recommended Fix
Remove the `finally` block. `_handsFreeStreaming` should remain `true` for the entire lifetime of the hands-free session. Set it to `false` only inside `_stopHandsFreeStreaming()` (and ensure that method is actually reached).

```dart
Future<void> _startHandsFreeStreaming() async {
  if (_handsFreeStreaming) return;
  _handsFreeStreaming = true;
  try {
    ...
  } catch (e) {
    _handsFreeStreaming = false;
    print('[MainScreen] _startHandsFreeStreaming error: $e');
    rethrow;
  }
  // NO finally block — flag stays true until _stopHandsFreeStreaming()
}
```

---

## Bug #2 — Duplicate wake-word listeners accumulate

**File:** `screens/main_screen.dart`  
**Lines:** ~640–690 (`_startWakeWordListening()`)  
**Severity:** CRITICAL

### The Code
```dart
Future<void> _startWakeWordListening() async {
  ...
  _wakeWordListener = () async { ... };
  context.read<AudioCoordinator>().addListener(_wakeWordListener!);
  ...
}
```

### Impact
`_startWakeWordListening()` is called from:
- `_startHandsFreeStreaming()` (initial startup)
- `_scheduleReturnToListening()` (after every response)
- `_startWakeWordInBackground()` (app to background)

**It never removes the old listener before adding a new one.** The `_removeWakeWordListener()` helper exists but is **not called** inside `_startWakeWordListening()`.

Each new call adds another `ChangeNotifier` listener. On wake-word detection, **all listeners fire simultaneously**, causing:
- Multiple concurrent calls to `acknowledgeWakeWord()`
- Multiple `_recorderSub` creations (each cancels the previous `_recorderSub` but they race)
- Multiple calls to `startRecording()` and `stopWakeWordListening()`
- Race conditions inside `AudioCoordinator` (recorder started/stopped multiple times in quick succession)

### Recommended Fix
Call `_removeWakeWordListener()` at the top of `_startWakeWordListening()`, before creating the new listener:

```dart
Future<void> _startWakeWordListening() async {
  ...
  _removeWakeWordListener();   // ← ADD THIS
  await context.read<AudioCoordinator>().stopAll();
  ...
  _wakeWordListener = () async { ... };
  context.read<AudioCoordinator>().addListener(_wakeWordListener!);
}
```

---

## Bug #3 — `PlayerService.onPlaybackEnded` is never assigned

**File:** `screens/main_screen.dart`  
**Severity:** CRITICAL

### Impact
`PlayerService` defines:
```dart
VoidCallback? onPlaybackEnded;
```

And schedules its invocation 200ms after playback stops:
```dart
_playbackEndTimer = Timer(
  const Duration(milliseconds: _micReenableDelayMs),
  () {
    _playbackEndTimer = null;
    onPlaybackEnded?.call();   // ← Never assigned, always null
  },
);
```

A full-text search of `main_screen.dart` shows **zero assignments** to `player.onPlaybackEnded`. The entire mic-re-enable-after-playback mechanism in `PlayerService` is dead code.

The actual mic re-enable relies on `_scheduleReturnToListening()`, which is triggered by the **`responseEnd` WebSocket event**. The server sends `responseEnd` when text generation finishes, but **TTS audio may still be buffering or playing**. This causes:
- Premature microphone re-enable while TTS is still audible
- Echo / false wake-word triggers (mic hears its own speaker)
- Race condition with `_playbackCompleteSub` (see Bug #4)

### Recommended Fix
Assign `onPlaybackEnded` inside `_startHandsFreeStreaming()`:

```dart
player.onPlaybackEnded = () {
  if (mounted && appState.handsFreeEnabled && appState.wakeWordEnabled) {
    _scheduleReturnToListening();
  }
};
```

Then remove `_scheduleReturnToListening()` from the `responseEnd` handler and only call it from `onPlaybackEnded`, ensuring the mic re-enables **after audio actually finishes playing**.

---

## Bug #4 — `_playbackCompleteSub` overwrites phase to `idle`, clobbering wake-word state

**File:** `screens/main_screen.dart`  
**Lines:** ~530 (`_playbackCompleteSub` setup)  
**Severity:** CRITICAL

### The Code
```dart
_playbackCompleteSub = player.playbackCompleteStream.listen((_) {
  if (appState.handsFreeEnabled && mounted) {
    appState.setHandsFreePhase(app.HandsFreePhase.idle);   // ← BUG
  }
});
```

### Impact
After `responseEnd`, `_scheduleReturnToListening()` waits 500ms, then:
1. Calls `stopAll()`
2. Sets phase to `wakeWordListening`
3. Calls `_startWakeWordListening()`

Then, when TTS playback **actually** completes, `_playbackCompleteSub` fires and **overwrites** the phase to `idle`. The UI now shows "idle" even though wake-word listening is active underneath. This is confusing and makes the wake-word feature appear broken — the mic is listening, but the user has no visual indication.

### Recommended Fix
Either:
1. **Remove `_playbackCompleteSub` entirely** and let `_scheduleReturnToListening()` be the single source of truth for phase transitions after playback.
2. **Or** make `_playbackCompleteSub` aware of the current phase:
   ```dart
   if (appState.handsFreePhase == app.HandsFreePhase.speaking) {
     appState.setHandsFreePhase(app.HandsFreePhase.idle);
   }
   ```
   But this still conflicts with wake-word mode. Better to remove it.

---

## Bug #5 — `AudioCoordinator.stopWakeWordListening()` does not set `_mode = idle`

**File:** `services/audio/audio_coordinator.dart`  
**Lines:** ~175–183  
**Severity:** HIGH

### The Code
```dart
Future<void> stopWakeWordListening() async {
  if (_mode != AudioMode.wakeWord) return;
  _audioSub?.cancel();
  _audioSub = null;
  await _stopRecorderOnly();
  _resetWakeWord();
  // _mode is NEVER reset to idle!
}
```

### Impact
After `stopWakeWordListening()`, `_mode` remains `AudioMode.wakeWord`. Then, when `startRecording()` is called (from the wake-word detection handler), it sees `_mode == AudioMode.wakeWord` and performs the transition:
```dart
if (_mode == AudioMode.wakeWord) {
  _audioSub?.cancel();
  _audioSub = null;
  await _stopRecorderOnly();
}
```

This works, but it's fragile. More importantly, if `stopWakeWordListening()` is called **after** `_mode` has already been changed to `recording` (which happens in `startRecording()`), the guard `if (_mode != AudioMode.wakeWord) return;` causes it to return early. The `_wakeWordListener` in `main_screen.dart` calls `stopWakeWordListening()` AFTER `startRecording()`, so `stopWakeWordListening()` is a no-op in the normal flow.

This isn't directly harmful because `startRecording()` already does the necessary cleanup, but it means `stopWakeWordListening()` is misleading — it doesn't actually stop wake-word listening in the normal post-detection flow.

### Recommended Fix
Set `_mode = AudioMode.idle` in `stopWakeWordListening()`:
```dart
Future<void> stopWakeWordListening() async {
  if (_mode != AudioMode.wakeWord) return;
  _audioSub?.cancel();
  _audioSub = null;
  await _stopRecorderOnly();
  _resetWakeWord();
  _mode = AudioMode.idle;   // ← ADD
}
```

---

## Bug #6 — `AudioCoordinator.dispose()` has a race condition

**File:** `services/audio/audio_coordinator.dart`  
**Lines:** ~215–225  
**Severity:** HIGH

### The Code
```dart
@override
void dispose() {
  stopAll().catchError((_) {});     // ← async, not awaited
  _cleanupAsync().catchError((_) {}); // ← async, not awaited
  super.dispose();
}
```

### Impact
`stopAll()` and `_cleanupAsync()` run **concurrently**. `_cleanupAsync()` closes stream controllers:
```dart
await _audioStream.close();
await _amplitudeStream.close();
```

Meanwhile, `stopAll()` tries to add to `_amplitudeStream`:
```dart
if (!_amplitudeStream.isClosed) _amplitudeStream.add(0.0);
```

This is a TOCTOU race. Between the `isClosed` check and the `add()`, `_cleanupAsync()` could close the controller, causing an unhandled exception. While `.catchError` swallows it, the exception indicates a real cleanup problem.

### Recommended Fix
Await `stopAll()` before calling `_cleanupAsync()`:
```dart
@override
void dispose() {
  stopAll().then((_) => _cleanupAsync()).catchError((_) {});
  super.dispose();
}
```

---

## Bug #7 — `_scheduleReturnToListening()` fires on `responseEnd`, before TTS finishes

**File:** `screens/main_screen.dart`  
**Lines:** ~380 (`responseEnd` handler) and ~600 (`_scheduleReturnToListening()`)  
**Severity:** HIGH

### Impact
The server sends `responseEnd` when **text generation** is complete. TTS audio chunks may still be buffered in `PlayerService` and playing. By calling `_scheduleReturnToListening()` immediately on `responseEnd`, the mic re-enables ~500ms later, potentially **while TTS is still speaking**.

This causes:
- Echo picked up by the microphone
- False wake-word triggers (the app hears its own TTS)
- Barge-in false positives

### Recommended Fix
Do NOT call `_scheduleReturnToListening()` from `responseEnd`. Instead, rely on `PlayerService.onPlaybackEnded` (once wired up, per Bug #3) to trigger the return to listening **after audio actually finishes**.

If you must keep `responseEnd` as a fallback, add a check that `player.isPlaying` is false before starting wake-word listening.

---

## Bug #8 — After `interruptAck`, hands-free never returns to listening

**File:** `screens/main_screen.dart`  
**Lines:** ~430–445 (`interruptAck` handler)  
**Severity:** HIGH

### The Code
```dart
case EventType.interruptAck:
  _responseWasInterrupted = true;
  await _saveResponse();
  if (mounted) setState(() {
    _isResponding = false;
    _isProcessing = false;
    _currentResponse = '';
    if (appState.handsFreeEnabled) {
      appState.setHandsFreePhase(app.HandsFreePhase.idle);
    }
  });
```

### Impact
After an interrupt (barge-in), the phase is set to `idle` and **`_scheduleReturnToListening()` is never called**. The user must manually trigger the next turn. In a hands-free conversation, this breaks the flow.

### Recommended Fix
Call `_scheduleReturnToListening()` after handling `interruptAck`, similar to `responseEnd`:
```dart
case EventType.interruptAck:
  ...
  if (appState.handsFreeEnabled) {
    _scheduleReturnToListening();
  }
```

---

## Bug #9 — Wake-word cooldown logic in `_checkForWakeWord()` is partially dead

**File:** `services/audio/audio_coordinator.dart`  
**Lines:** ~420–430  
**Severity:** MEDIUM

### The Code
```dart
void _checkForWakeWord() {
  if (_lastDetectionTime != null &&
      DateTime.now().difference(_lastDetectionTime!) < _wwCooldown) {
    _wwEnergyGateOpen = false;
    _wwPatternMatchCount = 0;
    return;
  }
  ...
}
```

### Impact
`_onWakeWordDetected()` already sets `_wwEnergyGateOpen = false`. So the guard `if (_wwEnergyGateOpen && ...)` in `_onWakeWordAudioChunk()` prevents `_checkForWakeWord()` from being called at all after detection. The cooldown check inside `_checkForWakeWord()` is only reachable if the energy gate re-opens **before** `stopWakeWordListening()` is called.

In the normal flow, `stopWakeWordListening()` is called immediately after detection, so the cooldown doesn't matter. But if there's a race (e.g., `_wakeWordListener` async body delays), the cooldown does provide some protection.

However, the cooldown **also resets `_wwEnergyGateOpen = false`** inside `_checkForWakeWord()`. This is redundant with `_onWakeWordDetected()` but not harmful.

The real issue: after the 3-second cooldown expires, if `stopWakeWordListening()` was never called, the wake-word could re-trigger immediately. This is a corner case but worth noting.

### Recommended Fix
Not critical. The cooldown logic is defensive. But ensure `stopWakeWordListening()` is always called promptly after detection (which it is, in `_wakeWordListener`).

---

## Bug #10 — `WakeWordService` is dead code

**File:** `services/audio/wake_word_service.dart`  
**Severity:** MEDIUM

### Impact
`WakeWordService` is a full duplicate of the wake-word detection logic, but **nothing in the app uses it**. `AudioCoordinator` has its own copy of all the wake-word code (ring buffer, energy snapshots, DTW, templates). This is confusing for maintenance and means any bug fixes must be applied in two places (or one place, if the unused one is forgotten).

### Recommended Fix
Remove `WakeWordService` entirely, or refactor so `AudioCoordinator` delegates to it. Keeping dead code increases the risk of divergence.

---

## Bug #11 — `_handsFreeStreaming` flag leak causes audio mode to stay stuck in `MODE_IN_COMMUNICATION`

**File:** `screens/main_screen.dart` + `services/audio/audio_mode_service.dart`  
**Severity:** MEDIUM

### Impact
Because `_stopHandsFreeStreaming()` is a no-op (Bug #1), `AudioModeService.resetAudioMode()` is never called when hands-free stops. The Android AudioManager stays in `MODE_IN_COMMUNICATION`, which:
- Affects other apps' audio behavior
- May keep the microphone "hot" even when not needed
- Can cause echo/feedback issues in subsequent PTT sessions

The only path that resets audio mode is `_onPttReleased()` — and only when `!handsFreeEnabled`.

### Recommended Fix
Fix Bug #1 (make `_stopHandsFreeStreaming()` actually work), which will restore the audio mode cleanup path.

---

## Bug #12 — `++_wwPatternMatchCount >= _wwFramesNeeded` is correct but fragile

**File:** `services/audio/audio_coordinator.dart`  
**Lines:** ~440  
**Severity:** LOW

### Analysis
```dart
if (score >= 0.72 || (score >= 0.68 && ++_wwPatternMatchCount >= _wwFramesNeeded)) {
```

With `_wwFramesNeeded = 2`:
- Frame 1 (score ≥ 0.68): count becomes 1, 1 ≥ 2 is **false**
- Frame 2 (score ≥ 0.68): count becomes 2, 2 ≥ 2 is **true**

This correctly requires **2 consecutive frames** with score ≥ 0.68. The pre-increment is intentional, not a bug.

The decay logic `if (_wwPatternMatchCount > 0) _wwPatternMatchCount--;` means a single non-matching frame decrements the count, so you need near-consecutive matches. This is a design choice, not a code bug.

However, the threshold values (0.72 / 0.68) and energy threshold (0.06 RMS) are tuned heuristically and may need field adjustment for different microphones/acoustic environments.

---

## Bug #13 — `_computeEnergySnapshots` ring-buffer extraction is inefficient

**File:** `services/audio/audio_coordinator.dart`  
**Lines:** ~560–590  
**Severity:** LOW

### The Code
```dart
final window = <int>[];
final start = (_ringBufferPos - _ringBufferLen + _bufferSize) % _bufferSize;
for (int i = 0; i < _ringBufferLen; i++) {
  window.add(_ringBuffer[(start + i) % _bufferSize]);
}
```

### Impact
For every chunk that passes the energy gate, the code allocates a new `List<int>` of up to 64,000 elements and copies the entire ring buffer into it. This happens every ~32ms while the user is speaking. For a 2-second wake-word utterance, that's ~60 allocations of 64KB each = ~4MB of garbage. On low-end devices, this could cause GC pauses and missed detections.

### Recommended Fix
Operate directly on the ring buffer without copying. `_computeBandEnergies()` can accept a `Uint8List` view, but since the data wraps around, you need either two slices or a pre-allocated linearization buffer that is reused.

---

## Bug #14 — `BluetoothService` scans indefinitely

**File:** `services/audio/bluetooth_service.dart`  
**Lines:** ~35–55  
**Severity:** LOW

### Impact
`_startScan()` calls `FlutterBluePlus.startScan(timeout: const Duration(seconds: 15))`, but the subscription to `scanResults` is never cancelled. The scan results stream may keep emitting if the platform doesn't respect the timeout. Additionally, the heuristic for detecting audio devices by advertisement name is unreliable — a paired headset may not advertise with "headset" in its name.

### Recommended Fix
Cancel `_scanSub` when disposing or when a device is found. Use `FlutterBluePlus.connectedDevices` as the primary signal instead of scanning, since the app cares about **connected** audio devices, not nearby advertisements.

---

## Architectural Issues

### 1. State machine is split across three files
The hands-free phase (`HandsFreePhase`) lives in `AppState`, but the actual phase transitions are scattered across `main_screen.dart` event handlers, `_scheduleReturnToListening()`, and `_playbackCompleteSub`. There is no single source of truth enforcing valid transitions.

**Recommended:** Create a `HandsFreeStateMachine` class that owns all transitions and emits phase changes. `main_screen.dart` should only react to phase changes, not drive them.

### 2. `AudioCoordinator` mixes three responsibilities
- PCM streaming to server
- VAD processing
- Wake-word detection

This violates single-responsibility principle. The wake-word logic is complex enough to deserve its own class (which `WakeWordService` was intended to be).

### 3. Flutter lifecycle + async subscriptions are poorly coordinated
Multiple `StreamSubscription`s are created in `_startHandsFreeStreaming()` and cleaned up in `_stopHandsFreeStreaming()`, but there is no centralized subscription manager. When the widget disposes, `dispose()` cancels subscriptions one by one, but it's easy to miss one.

### 4. `onPlaybackEnded` callback pattern is fragile
Using a nullable `VoidCallback?` on `PlayerService` is error-prone (as proven by the fact that it was never assigned). A stream or `ValueNotifier` would be more discoverable and harder to forget.

---

## Recommended Fix Priority

| Priority | Bug | Fix Effort |
|---|---|---|
| P0 | #1 — Remove `finally { _handsFreeStreaming = false }` | 1 line |
| P0 | #2 — Call `_removeWakeWordListener()` before adding | 1 line |
| P0 | #3 — Wire up `player.onPlaybackEnded` | ~5 lines |
| P0 | #4 — Remove or fix `_playbackCompleteSub` | 1 line |
| P1 | #6 — Await `stopAll()` before `_cleanupAsync()` | 1 line |
| P1 | #7 — Move `_scheduleReturnToListening()` to `onPlaybackEnded` | ~3 lines |
| P1 | #8 — Add `_scheduleReturnToListening()` after `interruptAck` | 1 line |
| P2 | #5 — Set `_mode = idle` in `stopWakeWordListening()` | 1 line |
| P2 | #10 — Remove dead `WakeWordService` | Delete file |
| P3 | #13 — Optimize ring buffer copy | Small refactor |
| P3 | #14 — Fix Bluetooth scan | Small refactor |

---

## Verification Steps After Fixes

1. Enable hands-free mode (no wake word). Speak. Verify VAD `speechEnd` triggers `_onHandsFreeSpeechEnd()` and `end_recording` is sent.
2. Enable hands-free + wake word. Say wake word. Verify single transition to recording. Check `AudioCoordinator` listener count (should be 1).
3. Complete a full turn (speak → response → TTS). Verify mic returns to wake-word listening **after TTS finishes**, not before.
4. Interrupt during TTS. Verify hands-free returns to listening state.
5. Disconnect WebSocket while hands-free active. Verify `_stopHandsFreeStreaming()` runs (add a log), recorder stops, and audio mode resets.
6. Put app in background (no background listening). Verify recorder stops and hands-free cleans up.
7. Resume app. Verify no duplicate subscriptions (check log for "Wake word detected" firing once per utterance).
