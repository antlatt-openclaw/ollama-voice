# 🔍 Ollama-Voice Flutter Client — Code Audit Report

> ⚠️ **STALE SNAPSHOT (2026-04-25).** This report is a point-in-time observation
> from before commit `38145852` ("Vera audit fixes"), which addressed several
> items below — including AudioCoordinator dispose race (C6), `mounted` guards
> in MainScreen (C5), pong timeout in WebSocketService, wake-word lifecycle,
> barge-in race, and foreground service. The findings here have NOT been
> reconciled against the post-fix code. Use a fresh audit (e.g.
> `AUDIT_REPORT_2026-04-27.md`) for current state. Treat this file as historical
> context only.

**Auditor:** Vera (Verification Agent)  
**Date:** 2026-04-25 (pre-fix snapshot)  
**Scope:** `lib/` + config files (`pubspec.yaml`, Android native code, `AndroidManifest.xml`)

---

## Executive Summary

| Metric | Score |
|--------|-------|
| **Overall Health** | **58 / 100** |
| Code Correctness | 55/100 |
| Security | 42/100 |
| Flutter/Dart Best Practices | 60/100 |
| Architecture | 55/100 |
| Dependencies | 70/100 |
| Build & Runtime | 50/100 |
| Accessibility & UX | 65/100 |

### Top 3 Concerns

1. **🚨 Security — Hardcoded credentials & plaintext storage**  
   A default auth token is hardcoded in source (`config_service.dart`). The token is stored in unencrypted `SharedPreferences`. No TLS certificate validation is configured for WebSocket connections. These are blockers for any production deployment.

2. **🚨 Stability — Fragile async state management in `MainScreen`**  
   The main screen manages 8+ stream subscriptions, multiple timers, and cross-service state transitions in a single 1,000+ line widget. Race conditions between recording, playback, wake-word detection, and WebSocket events are likely. Several `BuildContext` usages occur after async gaps without `mounted` guards.

3. **⚠️ Architecture — God Widget anti-pattern**  
   `MainScreen` violates separation of concerns by directly orchestrating audio recording, WebSocket communication, Bluetooth monitoring, proximity sensors, wake-word detection, and UI rendering. This makes the code nearly impossible to unit test and highly prone to regression.

---

## Critical Issues (Must Fix Before Production)

### C1. Hardcoded Default Auth Token
**File:** `lib/services/config/config_service.dart`  
**Line:** ~43

```dart
static const String _defaultAuthToken = 'ollama-voice-token-change-me';
```

- Even with the `⚠️ SECURITY` comment, a hardcoded token in source is a liability. If a developer forgets to change it, the app ships with a known default credential.
- **Fix:** Remove the default. Make `authToken` nullable and require the user to set it during onboarding. Block connection attempts until a token is provided.

### C2. Auth Token Stored in Plaintext SharedPreferences
**File:** `lib/services/config/config_service.dart`

- `SharedPreferences` stores the auth token as plaintext. On rooted/jailbroken devices, this is trivially extractable.
- **Fix:** Use `flutter_secure_storage` or `encrypt` package to encrypt sensitive values at rest.

### C3. No TLS Certificate Validation / No Certificate Pinning
**File:** `lib/services/network/websocket_service.dart`

- `WebSocket.connect()` uses the platform default TLS handling. There is no certificate pinning, no custom `SecurityContext`, and no validation of the server certificate chain.
- A man-in-the-middle attack could intercept the WebSocket connection and steal the auth token or inject malicious audio/content.
- **Fix:** Implement certificate pinning for your server's certificate, or at minimum validate the hostname and certificate chain.

### C4. WebSocket Malformed JSON Crash
**File:** `lib/services/network/websocket_service.dart`  
**Line:** ~168

```dart
final event = WebSocketEvent.fromJson(jsonDecode(data));
```

- If the server sends malformed JSON, `jsonDecode` throws an uncaught exception that propagates through the stream listener and crashes the app.
- **Fix:** Wrap `jsonDecode` in a `try/catch` block inside `_handleMessage`.

### C5. Missing `mounted` Guard After Async Gap in Multiple Locations
**File:** `lib/screens/main_screen.dart`

Multiple methods access `context.read<T>()` after `await` without checking `mounted`:

- `_saveAndContinue` in `onboarding_screen.dart` — partially guarded but reads `context.read<AppState>()` after `await`
- `_onPttPressed` — the inner closure is fire-and-forget but uses `ScaffoldMessenger.of(context)` after async work
- `_startHandsFreeStreaming` — `await _connectIfNeeded()` then accesses context
- `_showSettings` → `_SettingsSheet` → `onTap` handlers that do `await conn.manualReconnect()` then `Navigator.pop(context)` — if the sheet is dismissed during the await, `Navigator.pop` throws

**Fix:** Add `if (!mounted) return;` after every `await` before using `BuildContext`.

### C6. `AudioCoordinator.dispose()` — Async Cleanup Race
**File:** `lib/services/audio/audio_coordinator.dart`  
**Line:** ~284

```dart
@override
void dispose() {
  stopAll().then((_) => _cleanupAsync()).catchError((_) {});
  super.dispose();
}
```

- `super.dispose()` is called immediately while async cleanup is still in-flight. The `ChangeNotifier` may be garbage-collected before streams close, causing "Bad state: Cannot add event after closing" or use-after-free crashes.
- **Fix:** Override the lifecycle properly — Flutter `ChangeNotifier.dispose()` is synchronous. Either perform cleanup synchronously (close stream controllers immediately) or use a dedicated lifecycle manager that awaits disposal.

### C7. `RecorderService.dispose()` Method Named Incorrectly
**File:** `lib/services/audio/recorder_service.dart`  
**Line:** ~235

```dart
Future<void> dispose() async { ... }
```

- This is NOT overriding `ChangeNotifier.dispose()` (which is `void dispose()`). If `RecorderService` is ever used as a ChangeNotifier or placed in a Provider with `dispose`, Flutter will call the superclass `dispose()` synchronously and skip this async cleanup entirely.
- **Fix:** Rename to `close()` or `shutdown()`, or make it synchronous and fire the async work internally.

### C8. Foreground Service Missing Runtime Permission Check (Android 14+)
**File:** `android/app/src/main/AndroidManifest.xml`

- The app declares `FOREGROUND_SERVICE_MICROPHONE` but does not request `android.permission.FOREGROUND_SERVICE` at runtime on Android 14 (API 34+). Starting a foreground service without this permission will throw a `SecurityException`.
- **Fix:** Add runtime permission request for `FOREGROUND_SERVICE` on Android 14+ before calling `startForegroundService()`.

### C9. iOS Platform Completely Missing
**Directory:** `ios/` — **Does not exist.**

- The app cannot be built for iOS. All native features (proximity sensor, audio routing, Bluetooth SCO, foreground service) are Android-only via `Platform.isAndroid` checks, but the absence of an `ios/` directory means the Flutter project is incomplete.
- **Fix:** Run `flutter create . --platforms ios` and implement the required iOS native plugins (or document iOS as unsupported).

### C10. Potential WebSocket Reconnect Battery Drain
**File:** `lib/providers/connection_state.dart`

- `_maxRetries = 8` with exponential backoff capped at 30s means the app will retry for ~4 minutes before giving up. On mobile, this drains battery aggressively if the server is down.
- **Fix:** Reduce max retries, increase max delay, or stop retrying when the app is backgrounded.

---

## Warnings (Should Fix)

### W1. Unbounded Temporary File Growth
**File:** `lib/services/audio/player_service.dart`

- `_cleanOldTempFiles` keeps 20 most recent WAV files but doesn't limit total size. With long sessions, temp files can accumulate.
- **Fix:** Add a total size limit (e.g., 50MB) or time-based cleanup (delete files older than 1 hour).

### W2. `WakeWordService` — Dead Code & Duplicated Logic
**File:** `lib/services/audio/wake_word_service.dart`

- This entire file appears to be dead code. `AudioCoordinator` now contains a copy of all wake-word detection logic (DTW, energy templates, ring buffer). Having two copies of the same complex algorithm is a maintenance liability.
- **Fix:** Remove `WakeWordService` and rely solely on `AudioCoordinator`, or extract the wake-word logic into a shared class.

### W3. Bluetooth Scan Without Location Permission
**File:** `lib/services/audio/bluetooth_service.dart`

- `FlutterBluePlus.startScan()` requires `ACCESS_FINE_LOCATION` or `ACCESS_COARSE_LOCATION` on Android 6–11. The app does not request location permission.
- On Android 12+, `BLUETOOTH_SCAN` is declared, but the scan may still fail silently on older devices.
- **Fix:** Request location permission for Android <12, or use `bluetoothScan` permission properly.

### W4. No Backup Exclusion for Sensitive Data
**File:** `android/app/src/main/AndroidManifest.xml`

- The manifest doesn't set `android:allowBackup="false"` or `android:fullBackupContent`. Android's auto-backup could upload the SQLite database and SharedPreferences (including the auth token) to Google Drive.
- **Fix:** Add `android:allowBackup="false"` to the `<application>` tag.

### W5. Weak Barge-In Detection
**File:** `lib/screens/main_screen.dart`

- Barge-in uses a simple amplitude threshold (`_bargeInThreshold = 0.35`) with no AEC (Acoustic Echo Cancellation) verification. The comment acknowledges this requires headphones, but the UI doesn't enforce or warn about it.
- **Fix:** Detect if audio is routed through speaker vs. headset, and disable or warn about barge-in when using the speaker.

### W6. Missing Error Boundaries
**File:** `lib/app.dart`

- The app has no `ErrorWidget.builder` override or `FlutterError.onError` handler. Any uncaught framework error will show the red error screen.
- **Fix:** Add an error boundary that logs errors and shows a user-friendly fallback.

### W7. Database Migration Version 2 Is Minimal
**File:** `lib/services/storage/conversation_storage.dart`

- The `onUpgrade` only adds a `name` column for version 1→2. If the schema needs further changes, the migration strategy is underdeveloped.
- **Fix:** Add a proper migration framework or document the migration policy.

### W8. `AudioModeService` — Static State with Instance API Confusion
**File:** `lib/services/audio/audio_mode_service.dart`

- The class mixes static methods (`startProximitySensor`, `setVoiceCommunicationMode`) with instance methods (`startBluetoothMonitoring`). The static proximity sensor state (`_proximitySub`, `_proximityNear`) is shared globally but the instance-based Bluetooth monitoring is per-object. This is confusing and could lead to resource leaks if multiple instances are created.
- **Fix:** Make the class entirely static (singleton) or entirely instance-based with proper dependency injection.

### W9. Missing Input Validation for Server URL
**File:** `lib/services/config/config_service.dart` + `lib/screens/onboarding_screen.dart`

- The URL is only checked for `ws://` or `wss://` prefix. No validation of hostname, port, or path.
- A malformed URL could cause a crash in `Uri.parse()` inside the WebSocket service.
- **Fix:** Use `Uri.tryParse()` and validate the host is not empty.

### W10. Notification Channel Not Created on First Launch
**File:** `lib/services/notification_service.dart`

- `FlutterLocalNotificationsPlugin.initialize()` does not create notification channels on Android. `showResponseNotification` and `showBackgroundListeningNotification` specify channel IDs but never create the channels.
- **Fix:** Call `AndroidFlutterLocalNotificationsPlugin.createNotificationChannel()` for each channel before showing notifications.

---

## Recommendations (Nice to Have)

### R1. Add Unit & Widget Tests
- Zero test files exist despite `flutter_test` and `integration_test` being in `dev_dependencies`.
- The `AudioCoordinator`, `WebSocketService`, and `ConversationStorage` classes are all testable with mocked dependencies.

### R2. Extract Business Logic from `MainScreen`
- `MainScreen` is ~1,000 lines. Extract into:
  - `ConversationController` — handles message saving/loading/history
  - `AudioSessionController` — manages recording/playback/wake-word lifecycle
  - `ConnectionController` — WebSocket connection orchestration

### R3. Use `freezed` or `equatable` for Models
- `WebSocketEvent`, `Message`, and `Conversation` are plain classes with no value equality, making provider updates less predictable.

### R4. Add Analytics / Crash Reporting
- No crash reporting (Firebase Crashlytics, Sentry) is integrated. The app uses `print()` for all errors, which is invisible in production.

### R5. Consider `riverpod` over `provider`
- `provider` is fine, but `riverpod` provides better testability, compile-time safety, and disposal handling for complex multi-service apps.

### R6. Add a Loading State for Conversation Loading
- `ConversationStorage.init()` opens the database synchronously on the main thread. For large databases, this could cause jank.
- **Fix:** Use `compute()` or isolate for DB initialization.

### R7. Use `flutter_analyze` CI Pipeline
- Several files have unused imports (`import 'dart:math' as math;` in `message_list.dart`, `import 'dart:io';` in `audio_coordinator.dart`, etc.).

### R8. Document the Missing iOS Story
- The README should clearly state iOS is unsupported and list the missing native implementations.

---

## Per-File Notes

### `pubspec.yaml`
- ✅ Good dependency hygiene overall — no obvious unnecessary packages.
- ⚠️ `flutter_sound: ^9.2.13` — check for latest stable; audio packages can have platform-specific bugs.
- ⚠️ `porcupine_flutter: ^3.0.3` is listed but `WakeWordService` uses its own energy-based detection instead. Either remove the dependency or implement Porcupine integration.
- ⚠️ `sqflite: ^2.3.0` — consider `drift` for type-safe SQL if the schema grows.

### `lib/main.dart`
- ✅ Clean initialization sequence with `WidgetsFlutterBinding.ensureInitialized()`.
- ✅ Proper provider disposal with `dispose` callbacks.
- ⚠️ `NotificationService.init()` is not awaited — if it fails, the app starts without notifications silently.

### `lib/app.dart`
- ✅ Clean separation of app shell vs. connection logic.
- ⚠️ `_friendlyError()` uses `raw.toLowerCase().contains('auth')` which could match unrelated strings (e.g., "author").

### `lib/models/websocket_event.dart`
- ✅ Null-safe `fromJson` with fallback to `EventType.unknown`.
- ⚠️ `print()` on unknown events — should use a proper logger.

### `lib/providers/app_state.dart`
- ✅ Well-organized state with many convenience setters.
- ⚠️ `notifyListeners()` is called on every setter, even when the value hasn't changed. Some setters already have early returns, but not all.

### `lib/providers/connection_state.dart`
- ✅ Exponential backoff reconnect logic is solid.
- ✅ Network connectivity listener is a nice touch.
- ⚠️ `_subscribeToEvents()` doesn't handle stream errors — if the event stream throws, the subscription dies silently.
- ⚠️ `dispose()` fires `_wsService?.disconnect()` asynchronously but doesn't await it, potentially leaking the WebSocket.

### `lib/providers/conversation_state.dart`
- ✅ Good use of `Uuid` for IDs.
- ⚠️ `exportAsText()` builds the entire history in memory — for long conversations this could be large. Consider streaming.
- ⚠️ `recentHistory()` returns a mutable list. Callers could accidentally mutate it.

### `lib/services/network/websocket_service.dart`
- ✅ Clean event-driven architecture.
- ✅ Keepalive/ping-pong handling.
- ⚠️ `sendAudio` accepts `dynamic` but only handles `Uint8List`. Should be typed.
- ⚠️ `disconnect()` closes stream controllers, but if called multiple times, the second call will attempt to close already-closed controllers. Need a `_isDisposed` flag.

### `lib/services/audio/audio_coordinator.dart`
- ✅ Single-recorder design eliminates the race condition mentioned in comments.
- ✅ Comprehensive VAD implementation.
- ⚠️ The DTW wake-word detection is clever but fragile. False positives are likely in noisy environments.
- ⚠️ `_computeBandEnergies` uses Goertzel-like filters on every chunk — this is CPU-intensive and may cause frame drops on low-end devices. Consider moving to an isolate.

### `lib/services/audio/player_service.dart`
- ✅ Good buffer size limiting (`_maxBufferBytes`).
- ✅ Temp file cleanup.
- ⚠️ `AudioSessionConfiguration.speech()` is re-created every time `_configureAudioSession` is called — minor inefficiency.

### `lib/services/audio/recorder_service.dart`
- ⚠️ **C7** applies here — `dispose()` signature mismatch.
- ⚠️ Duplicated VAD logic with `AudioCoordinator`. Maintenance burden.

### `lib/services/audio/audio_mode_service.dart`
- ⚠️ **W8** applies — mixed static/instance API.
- ⚠️ `bluetoothConnectionStream` polls every 3 seconds — this is inefficient. Use `FlutterBluePlus.connectedDevices` with an event-driven approach.

### `lib/services/audio/bluetooth_service.dart`
- ⚠️ Heuristic device name matching (`contains('headset')`, `contains('airpods')`) is fragile. Device names can be localized or customized.
- ⚠️ Scan results only check `advName`, not the actual service UUIDs.

### `lib/services/audio/wake_word_service.dart`
- ⚠️ **Dead code** — fully duplicated in `AudioCoordinator`.

### `lib/services/notification_service.dart`
- ⚠️ **W10** applies — missing channel creation.
- ✅ Clean separation of response vs. background listening notifications.

### `lib/services/storage/conversation_storage.dart`
- ✅ Parameterized SQL queries prevent injection.
- ✅ Pruning logic with daily rate limiting.
- ⚠️ `_database` getter throws `StateError` — this is fine but could be a more specific exception.

### `lib/screens/main_screen.dart`
- 🚨 **Major concern** — 1,000+ lines, 10+ stream subscriptions, multiple async state machines.
- ⚠️ `_eventChain` serializes event handling but doesn't handle errors in the chain. If one event handler throws, the chain breaks.
- ⚠️ `_scheduleReturnToListening()` uses a hardcoded 500ms timer — this is a magic number without explanation.
- ⚠️ The `_onPttPressed` closure is an immediately-invoked function expression (IIFE) — unusual in Dart and harder to debug.
- ⚠️ `context.read<app.AppState>()` is called inside `_onConnectionStateChanged` which is a listener callback. Using `context.read` inside a listener is safe, but mixing it with `setState` in the same method is confusing.
- ✅ Good hands-free phase management with clear state transitions.

### `lib/screens/onboarding_screen.dart`
- ✅ Clean multi-step onboarding.
- ⚠️ URL validation only checks prefix — **W9**.
- ⚠️ `_saveAndContinue` doesn't validate that the token is not the default placeholder.

### `lib/theme/app_theme.dart`
- ✅ Consistent dark/light theme.
- ⚠️ `CardThemeData` — verify this exists in the Flutter version being used (it was renamed from `CardTheme` in some versions).

### `lib/theme/colors.dart`
- ✅ Clean color palette with theme-aware helpers.

### `lib/widgets/connection_status.dart`
- ✅ Clear status bar with reconnect button.
- ⚠️ Uses `withValues(alpha: ...)` which requires Flutter 3.27+ — verify minimum Flutter version compatibility.

### `lib/widgets/message_list.dart`
- ✅ Good Markdown rendering with syntax highlighting support.
- ✅ Date separators and relative time formatting.
- ⚠️ `_buildItems()` rebuilds the entire list on every `build()` call — for long conversations, this is O(n) every frame. Consider caching or using `ListView.builder` with a stable item count.
- ⚠️ `Dismissible` on messages could accidentally trigger while scrolling. Consider requiring a longer drag.

### `lib/widgets/playback_controls.dart`
- ✅ Clean, compact playback controls.
- ⚠️ `_SpeedChip` uses `GestureDetector` instead of a tappable widget like `InkWell`, so there's no visual feedback on tap.

### `lib/widgets/push_to_talk_button.dart`
- ✅ Excellent visual feedback with waveform animation.
- ✅ Proper `HapticFeedback` usage.
- ⚠️ `_buildHandsFreeIndicator()` is called on every build but switches on `widget.handsFreePhase` — this is fine but the switch could be extracted for readability.

### `android/app/src/main/AndroidManifest.xml`
- ✅ Comprehensive permission declarations.
- ⚠️ **W4** — missing `android:allowBackup="false"`.
- ⚠️ `android:theme="@style/LaunchTheme"` — verify `LaunchTheme` and `NormalTheme` are defined in `styles.xml`.

### `android/app/src/main/kotlin/.../MainActivity.kt`
- ✅ Clean MethodChannel and EventChannel implementation.
- ⚠️ `requestAudioFocus` is called with `AUDIOFOCUS_GAIN_TRANSIENT` but never released on activity pause — could block other apps.
- ⚠️ `onDestroy()` unregisters the proximity sensor but doesn't clean up the MethodChannel or EventChannel handlers.

### `android/app/src/main/kotlin/.../ForegroundAudioService.kt`
- ✅ Proper foreground service with notification.
- ✅ `ACTION_STOP` intent for graceful shutdown.
- ⚠️ `NOTIFICATION_ID = 1001` conflicts with `NotificationService._responseNotificationId = 1` — actually no, different IDs. But the foreground service notification and Flutter notification use different systems. Good.
- ⚠️ The service doesn't actually do any audio work — it's just a keep-alive service. Document this clearly.

### `android/app/build.gradle`
- ✅ `minSdk = 24` is reasonable.
- ⚠️ `signingConfig = signingConfigs.debug` in release builds — **this must be changed before any store release**.
- ⚠️ No ProGuard/R8 obfuscation rules for release.

---

## Dependency Audit

| Package | Version | Notes |
|---------|---------|-------|
| `web_socket_channel` | ^2.4.0 | ✅ Current stable |
| `flutter_sound` | ^9.2.13 | ⚠️ Check for v10+; v9 may have Android 14 issues |
| `just_audio` | ^0.9.36 | ✅ Current stable |
| `audio_session` | ^0.1.18 | ✅ Current stable |
| `provider` | ^6.1.1 | ✅ Current stable |
| `shared_preferences` | ^2.2.2 | ⚠️ Not encrypted — see **C2** |
| `sqflite` | ^2.3.0 | ✅ Current stable |
| `connectivity_plus` | ^5.0.2 | ✅ Current stable |
| `permission_handler` | ^11.1.0 | ⚠️ v11 is older; v12+ adds Android 14 support |
| `wakelock_plus` | ^1.0.0 | ✅ Current stable |
| `flutter_local_notifications` | ^17.0.0 | ✅ Current stable |
| `porcupine_flutter` | ^3.0.3 | ⚠️ Unused — see **W2** / remove or integrate |
| `flutter_blue_plus` | ^1.32.0 | ✅ Current stable |

---

## Summary Action Items

| Priority | Action | Files |
|----------|--------|-------|
| 🔴 P0 | Remove hardcoded auth token; require onboarding input | `config_service.dart`, `onboarding_screen.dart` |
| 🔴 P0 | Encrypt auth token at rest | `config_service.dart` |
| 🔴 P0 | Add TLS certificate pinning / validation | `websocket_service.dart` |
| 🔴 P0 | Fix `AudioCoordinator.dispose()` async race | `audio_coordinator.dart` |
| 🔴 P0 | Fix `RecorderService.dispose()` signature | `recorder_service.dart` |
| 🔴 P0 | Add `mounted` guards after all async gaps | `main_screen.dart`, `onboarding_screen.dart` |
| 🔴 P0 | Wrap `jsonDecode` in try/catch | `websocket_service.dart` |
| 🔴 P0 | Add Android 14+ foreground service runtime permission | `main_screen.dart`, `AndroidManifest.xml` |
| 🟡 P1 | Create iOS platform directory or document unsupported | Root |
| 🟡 P1 | Remove or integrate dead `WakeWordService` | `wake_word_service.dart`, `pubspec.yaml` |
| 🟡 P1 | Disable Android auto-backup | `AndroidManifest.xml` |
| 🟡 P1 | Add notification channel creation | `notification_service.dart` |
| 🟡 P1 | Add error boundaries | `app.dart` |
| 🟢 P2 | Add unit/widget tests | `test/` |
| 🟢 P2 | Extract business logic from `MainScreen` | `main_screen.dart` |
| 🟢 P2 | Replace `print()` with proper logging | All files |
| 🟢 P2 | Add release signing config | `android/app/build.gradle` |

---

*Report generated by Vera, the verification agent. This audit is a snapshot-in-time assessment based on static code analysis. Runtime testing may reveal additional issues.*
