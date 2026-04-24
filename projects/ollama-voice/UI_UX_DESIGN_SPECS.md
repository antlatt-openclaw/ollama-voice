# Ollama Voice — Client UI/UX Design Specs

> **Status:** Draft v1.0  
> **Scope:** Flutter client (`/projects/ollama-voice/client/`)  
> **Reference codebase:** `/root/.openclaw/antlatt-workspace/projects/ollama-voice/client/lib/`

---

## Table of Contents
1. [Design System](#1-design-system)
2. [Screen Architecture](#2-screen-architecture)
3. [Hands-Free Mode UI](#3-hands-free-mode-ui)
4. [Connection State Visualization](#4-connection-state-visualization)
5. [Voice Recording Waveform](#5-voice-recording-waveform)
6. [Settings / Config Screen](#6-settings--config-screen)
7. [Offline & Cache Indicators](#7-offline--cache-indicators)
8. [Component Breakdown](#8-component-breakdown)
9. [Accessibility Notes](#9-accessibility-notes)

---

## 1. Design System

### 1.1 Color Palette
Based on existing `AppColors`. Enhancements marked ⭐.

| Token | Hex | Usage |
|-------|-----|-------|
| `primary` | `#6366F1` | Active states, CTAs, user bubbles, accent |
| `secondary` | `#8B5CF6` | Agent avatar rings, secondary accents |
| `success` | `#10B981` | Connected, listening active, online |
| `warning` | `#F59E0B` | Processing, connecting, reconnecting, offline sync pending |
| `error` | `#EF4444` | Disconnected, recording active, interrupt, delete |
| `background` | `#1A1B26` | Dark scaffold bg |
| `surface` | `#24283B` | Cards, sheets, input fields (dark) |
| `textPrimary` | `#FFFFFF` | Headings, body text (dark) |
| `textSecondary` | `#9CA3AF` | Labels, hints, timestamps |
| `onlineGlow` ⭐ | `#10B981` at 40% | Hands-free listening pulse shadow |
| `offlineBadge` ⭐ | `#F59E0B` at 20% bg | Cache/sync badge background |

### 1.2 Typography
All existing text styles preserved. Add:
- **Status label:** 11px, weight 500/600, uses status color
- **Waveform label:** 12px, weight 600, monospace-optional for timing
- **Cache badge:** 10px, weight 700, uppercase, letter-spacing 0.6

### 1.3 Easing & Motion
- **State transitions:** `Duration(milliseconds: 300)`, curve `easeInOut`
- **Waveform bars:** `Duration(milliseconds: 80)` for amplitude response
- **Glow pulse:** `Duration(milliseconds: 1500)`, looped, sine-wave opacity
- **Snackbar enter/exit:** 225ms / 175ms

### 1.4 Spacing Grid
- Base unit: 4px
- AppBar height: 56px + safe area
- Sheet handle: 40×4px rounded pill
- Section dividers: 24px vertical gap, 1px `Colors.white12`
- Button touch target: minimum 80×80px (PTT), 48×48px (icon buttons)

---

## 2. Screen Architecture

```
┌─────────────────────────────────────┐
│  AppBar (title + agent + actions)   │  <- 56dp
├─────────────────────────────────────┤
│  ConnectionStatusBar (conditional)  │  <- 28dp when visible
├─────────────────────────────────────┤
│                                     │
│         MessageList (flex)          │  <- Scrollable, reverse
│         (bubbles + live items)      │
│                                     │
├─────────────────────────────────────┤
│  PlaybackControlsBar (conditional)  │  <- 48dp when playing
├─────────────────────────────────────┤
│  LatencyOverlay (debug, cond.)    │  <- 20dp
├─────────────────────────────────────┤
│  TextInputRow  OR  PushToTalkButton │  <- 80dp + safe area
└─────────────────────────────────────┘
         ↑ BottomSheet: Settings
         ↑ Drawer: Conversations
```

**Navigation:**
- `MainScreen` → `OnboardingScreen` (first launch)
- `MainScreen` → Settings BottomSheet (modal, draggable)
- `MainScreen` → Conversation Drawer (slide from left)

---

## 3. Hands-Free Mode UI

### 3.1 Overview
Hands-free replaces the PTT button with an **always-visible ambient indicator**. The mic is always hot (with hardware AEC). The UI must communicate four sub-states clearly without being intrusive.

### 3.2 State Machine

```
                    ┌─────────────┐
    ┌──────────────►│   IDLE      │◄──────────────┐
    │               │ (hands-free │               │
    │               │   enabled,  │               │
    │               │   not       │               │
    │               │   listening)│               │
    │               └──────┬──────┘               │
    │                      │ user speaks /        │
    │                      │ server sends         │
    │                      │ listeningStart       │
    │                      ▼                      │
    │               ┌─────────────┐             │
    │    interrupt  │  LISTENING  │               │
    │    / barge-in │  (green,    │               │
    │    ──────────►│   pulsing)  │               │
    │               └──────┬──────┘               │
    │                      │ server sends         │
    │                      │ listeningEnd         │
    │                      ▼                      │
    │               ┌─────────────┐             │
    │    response   │ PROCESSING  │             │
    │    starts     │  (amber,    │             │
    │◄──────────────│   spinner)  │             │
    │               └──────┬──────┘             │
    │                      │ server sends       │
    │                      │ responseStart        │
    │                      ▼                      │
    │               ┌─────────────┐               │
    │               │  RESPONDING │───────────────┘
    │               │  (TTS       │   responseEnd
    │               │   playing)  │
    │               └─────────────┘
```

### 3.3 Component: `HandsFreeIndicator`

**Replace the existing `_buildHandsFreeIndicator()` in `PushToTalkButton`** with a richer, standalone component.

#### Visual Spec

```
    ┌─────────────────┐
    │   ╭───────╮     │   ← Circular container
    │  ( ◠‿◠  )      │     88dp diameter when listening
    │   ╰───────╯     │     72dp diameter when idle/processing
    │                 │
    │  ┌─┐ ┌─┐ ┌─┐   │   ← 5-bar waveform inside circle
    │  │ │ │ │ │ │   │     (only when listening)
    │  └─┘ └─┘ └─┘   │
    │                 │
    │   Listening…    │   ← Label below
    └─────────────────┘
```

#### Properties
| Prop | Type | Description |
|------|------|-------------|
| `state` | `HandsFreeState` | `idle` / `listening` / `processing` / `responding` |
| `amplitude` | `double` | 0.0–1.0, drives waveform bar heights |
| `onInterrupt` | `VoidCallback` | Tap to stop TTS / interrupt response |

#### State Visuals

**IDLE**
- Circle: 72dp, `primary` at 30% opacity, no pulse
- Icon: `Icons.hearing_rounded`, white at 50%
- Label: "Hands-free" — `textSecondary`, weight 400

**LISTENING** ⭐ enhanced
- Circle: 88dp, `success`, **animated glow shadow**
  - Shadow: `success` at 50% opacity, blurRadius oscillates 20→40dp over 1.5s
- Inner waveform: 5 bars reacting to `amplitude` stream
  - Bar width: 4dp, gap: 3dp
  - Height: `clamp(6dp, 88dp × (0.15 + amplitude × 0.75 × multiplier), 44dp)`
  - Color: white at 90%
  - Animation duration: 80ms
- Label: "Listening…" — `success`, weight 600
- Optional: tiny red dot in top-right corner = "Recording active"

**PROCESSING**
- Circle: 72dp, `warning` at 15% bg, border: `warning` at 40%
- Inner: `CircularProgressIndicator`, strokeWidth 2.5, `warning` color
- Label: "Processing…" — `warning`, weight 500

**RESPONDING**
- Circle: 80dp, `primary`
- Icon: `Icons.volume_up_rounded`, white, size 30
- **Swipe/tap anywhere on circle = interrupt** (haptic medium)
- Glow shadow: `primary` at 30%, blurRadius 16dp (static)
- Label: "Speaking…" — `primary`, weight 500
- Below circle: subtle "Tap to interrupt" hint (8s fade out)

#### Implementation Notes
```dart
// New enum in push_to_talk_button.dart or models/
enum HandsFreeState { idle, listening, processing, responding }

// GestureDetector wraps the entire indicator for responding state:
GestureDetector(
  onTap: state == HandsFreeState.responding ? onInterrupt : null,
  child: AnimatedContainer(/* ... */),
)
```

---

## 4. Connection State Visualization

### 4.1 Overview
The existing `ConnectionStatusBar` is minimal. Enhance to give users **at-a-glance understanding** of what's wrong and what they can do.

### 4.2 Enhanced `ConnectionStatusBar`

#### Visibility Rule
- **Hidden** when `status == ConnectionStatus.connected`
- **Always visible** otherwise (including onboarding)

#### States Spec

| Status | Background | Dot | Text | Action |
|--------|-----------|-----|------|--------|
| `connecting` | `warning` at 12% | 8dp spinner (rotation) | "Connecting…" | none |
| `reconnecting` | `warning` at 12% | 8dp spinner | "Reconnecting in 4s…" | none (shows countdown) |
| `disconnected` — no network | `error` at 12% | 7dp solid `error` | "No network connection" | **Settings** button |
| `disconnected` — server error | `error` at 12% | 7dp solid `error` | "Server unreachable" | **Reconnect** button |
| `disconnected` — auth failed | `error` at 15% | 7dp solid `error` | "Authentication failed" | **Settings** button |
| `disconnected` — generic | `error` at 12% | 7dp solid `error` | "Disconnected" | **Reconnect** button |

#### Visual Layout
```
┌──────────────────────────────────────────────────────┐
│ ●  Connecting…                                  [⚙️] │  <- Full width bar
└──────────────────────────────────────────────────────┘
```
- Height: 32dp (up from 28dp)
- Padding: horizontal 12dp, vertical 6dp
- Left: status dot + text
- Right: optional action chip (`Reconnect` or `Settings` icon)
- Border-bottom: 1px divider (subtle, `Colors.white8`)

#### Reconnect Button Chip
```dart
Container(
  padding: EdgeInsets.symmetric(horizontal: 10, vertical: 4),
  decoration: BoxDecoration(
    color: AppColors.primary.withValues(alpha: 0.15),
    borderRadius: BorderRadius.circular(10),
    border: Border.all(color: AppColors.primary.withValues(alpha: 0.4)),
  ),
  child: Text('Reconnect', style: /* primary, 11px, weight 600 */),
)
```

#### Reconnect Countdown
During `reconnecting`, show dynamic text:
- "Reconnecting in 4s… (attempt 2/8)"
- The countdown text updates every second without rebuilding the entire bar — use a `Timer` inside the widget with a localized `ValueKey`.

#### Implementation Notes
```dart
class ConnectionStatusBar extends StatefulWidget {
  // Add countdown ticker for reconnecting state
}

class _ConnectionStatusBarState extends State<ConnectionStatusBar> {
  Timer? _countdownTimer;
  int _secondsRemaining = 0;

  @override
  void didUpdateWidget(ConnectionStatusBar old) {
    super.didUpdateWidget(old);
    if (widget.status == ConnectionStatus.reconnecting) {
      _startCountdown(widget.retryDelaySeconds);
    } else {
      _countdownTimer?.cancel();
    }
  }
}
```

---

## 5. Voice Recording Waveform

### 5.1 Overview
Existing 5-bar waveform is functional but basic. Design a **richer, more informative** waveform that also serves as a confidence indicator for speech detection.

### 5.2 Enhanced Waveform (`RecordingWaveform`)

#### Two Contexts
1. **Inside PTT button** (hold-to-talk): compact, 5 bars, white on colored circle
2. **Standalone overlay** (optional enhancement): full-width at bottom of screen during recording

#### Compact Waveform (inside button) — Current + Polish
```
Bar specs:
- Count: 5 bars
- Width: 4dp each
- Gap: 3dp between bars
- Corner radius: 2dp
- Color: white at 90% opacity
- Bar multipliers (center-tall): [0.45, 0.70, 1.0, 0.70, 0.45]

Height calculation:
  baseHeight = 0.15
  amplitudeFactor = amplitude * 0.75
  multiplier = _barMult[i]
  barHeight = containerHeight * (baseHeight + amplitudeFactor * multiplier)
  clamp: 6.0 .. containerHeight * 0.55
```

#### Full-Width Waveform ⭐ NEW
When recording in PTT mode, optionally show a thin waveform strip above the button:

```
┌────────────────────────────────────────────────────┐
│  ~  ~  ~  ~~  ~~~  ~~~~  ~~~  ~~  ~  ~  ~  ~  ~   │  <- 24dp strip
│                                                    │     above button
├────────────────────────────────────────────────────┤
│              [  ●═══●  ]                           │  <- PTT button
└────────────────────────────────────────────────────┘
```

**Specs:**
- Height: 24dp
- Background: `surface` at 50% opacity (dark) / `lightSurface` (light)
- Bar count: 24 thin bars (width 2dp, gap 1dp)
- Same amplitude → height mapping, but with noise floor at 0.05
- Color gradient: `primary` → `secondary` based on amplitude (low=blue, high=purple)

#### Recording Timer ⭐
Below the button during recording:
```
02:14  🔴
```
- Format: `MM:SS`
- Color: `error` when > 2min (warns user about long recordings)
- Font: 12px, weight 600, monospace

---

## 6. Settings / Config Screen

### 6.1 Overview
Currently implemented as a `DraggableScrollableSheet` inside `_showSettings()`. The design is solid but needs **organization, search, and validation** improvements.

### 6.2 Sheet Layout

```
┌──────────────────────────────────────────────────────┐
│  ════  (drag handle, 40×4)                          │  <- 12dp padding top
│                                                      │
│  Settings                           [✕]              │  <- Title + close
│                                                      │
│  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━  │  <- Divider
│                                                      │
│  🔍  Search settings…                               │  ⭐ NEW
│                                                      │
│  ── CHAT ─────────────────────────────────────────   │
│  Font size                    [11px  ●━━━━━━━  22px] │
│  Clear conversation           [>]                    │
│  Export conversation          [>]                    │
│                                                      │
│  ── INPUT ────────────────────────────────────────   │
│  ☐ Hands-free mode                                   │
│     Always listening — no button needed              │
│  ☐ Tap to toggle                                     │
│  ☐ Barge-in                                          │
│     Speak to interrupt — headphones recommended      │
│                                                      │
│  ── OUTPUT ───────────────────────────────────────   │
│  ☐ Keep screen on                                    │
│                                                      │
│  ── AGENT ────────────────────────────────────────   │
│  ●  Default         Uncensored Ollama model    ✓     │
│                                                      │
│  ── APPEARANCE ───────────────────────────────────   │
│  Theme  [Dark] [Light] [Auto]                        │
│                                                      │
│  ── DEVELOPER ────────────────────────────────────  │
│  ☐ Latency overlay                                   │
│                                                      │
│  ── CONNECTION ───────────────────────────────────  │
│  🌐 Server URL          wss://…              [edit] │
│  🔑 Auth Token          ••••••••           [edit]  │
│  🧠 System Prompt       Tap to customize…    [edit] │
│  🔁 Playback Speed       1.0×               [edit] ⭐ │
│                                                      │
│  ── ABOUT ────────────────────────────────────────  │  ⭐ NEW
│  Version 1.0.0                                       │
│  Build 20250424                                       │
└──────────────────────────────────────────────────────┘
```

### 6.3 Section Details

#### Search Bar ⭐
- Placed immediately below title
- Filters sections/items in real-time
- Debounce: 200ms
- Highlight matching text in results

#### Connection Section — Validation ⭐
Each connection field gets inline validation:

**Server URL**
- Must start with `ws://` or `wss://`
- On save: show "Testing connection…" → green check or red X
- Invalid: red border + helper text "Must start with ws:// or wss://"

**Auth Token**
- Minimum length: 8 chars
- Show strength indicator (weak / fair / strong) based on entropy
- Obscured by default, toggle visibility

**System Prompt**
- Multi-line text field (8 lines visible)
- Character counter: "0 / 4000 chars"
- Warning at > 3500: "Long prompts may increase latency"
- Preview button: sends test message with prompt

#### Inline Editing ⭐
Instead of `AlertDialog`, use inline expansion:
```dart
AnimatedContainer(
  duration: Duration(milliseconds: 250),
  child: isEditing
      ? TextField(/* with save/cancel inline */)
      : ListTile(/* display mode */),
)
```

---

## 7. Offline & Cache Indicators

### 7.1 Overview
Currently **not implemented**. The app assumes always-online. Design graceful degradation for:
- No network (airplane mode, tunnel, rural)
- Server temporarily down
- Messages queued for later sync
- Cached conversation history available offline

### 7.2 Offline Strategy Matrix

| Scenario | User Sees | Can Do | Sync Behavior |
|----------|-----------|--------|---------------|
| Network lost mid-convo | 🟡 Offline badge + "Messages saved locally" | View history, type text (queued) | Auto-retry when online |
| Open app with no network | 🟡 "Working offline" status bar | Read cached conversations | Queue new messages |
| Server down | 🔴 "Server unreachable" | Same as above | Exponential backoff |
| Network restored | 🟢 Brief "Back online" snackbar | Resume normal operation | Flush queue |

### 7.3 Components

#### A. Offline Badge ⭐
A persistent chip in the AppBar when offline:

```
┌──────────────────────────────────────────────────┐
│  Conversation Name                    [🟡 Offline]│
│  Default Agent                                     │
└──────────────────────────────────────────────────┘
```

**Specs:**
- Position: AppBar trailing area, right of search icon
- Size: Compact chip, 28dp height
- Background: `warning` at 15%
- Border: `warning` at 40%, 1px
- Text: "Offline" — 10px, `warning`, weight 700
- Icon: `Icons.cloud_off_rounded`, 14px
- Tap: opens a bottom sheet explaining "You're offline. Messages will sync when connection returns."

#### B. Cache Status Bar ⭐
Appears below `ConnectionStatusBar` when offline:

```
┌──────────────────────────────────────────────────────┐
│ 🟡  Working offline · 3 messages queued              │
└──────────────────────────────────────────────────────┘
```

- Height: 28dp
- Background: `warning` at 8%
- Text: "Working offline · {N} messages queued"
- Updates in real-time as user sends messages
- Disappears when connection restored + queue flushed

#### C. Message Queue Indicator ⭐
On individual messages that are queued:

```
┌────────────────────────┐
│ This is my message     │
│                ⏳ 12:34│  <- timestamp with clock icon
└────────────────────────┘
```

- Clock icon (`Icons.schedule_rounded`) before timestamp
- Color: `textSecondary` at 60%
- Replaced with checkmark (`Icons.done_rounded`) when synced
- Failed after max retries: red exclamation + retry button

#### D. "Back Online" Snackbar ⭐
```
┌──────────────────────────────────────────────────────┐
│  ✅  Back online · Messages synced                   │
│                                              [DISMISS]│
└──────────────────────────────────────────────────────┘
```
- Auto-dismiss: 4 seconds
- Background: `success` at 90%, text: dark
- Action: "DISMISS" button

#### E. Cached Conversation List ⭐
In the conversation drawer, show sync status per conversation:

```
┌──────────────────────────────────────────────────┐
│ 💬 Today                                        │
│    · 12:34 PM  ⏳ (not synced)                  │
│                                                  │
│ 💬 Yesterday                                    │
│    · Hello world  ✓ (synced)                    │
└──────────────────────────────────────────────────┘
```

- ⏳ = `warning` at 70%
- ✓ = `success` at 70%
- Tooltip on icon: "Not yet synced" / "Synced"

### 7.4 Implementation Notes

```dart
// New provider: offline_state.dart
class OfflineState extends ChangeNotifier {
  bool get isOffline;
  int get queuedMessageCount;
  List<QueuedMessage> get queue;
  void queueMessage(String text);
  Future<void> flushQueue();
}

// New widget: offline_badge.dart
class OfflineBadge extends StatelessWidget {
  // Shows in AppBar when offline
}

// New widget: cache_status_bar.dart
class CacheStatusBar extends StatelessWidget {
  // Shows below connection bar
}
```

---

## 8. Component Breakdown

### 8.1 Existing Components — Refactor List

| Component | File | Changes Needed |
|-----------|------|----------------|
| `PushToTalkButton` | `widgets/push_to_talk_button.dart` | Extract `HandsFreeIndicator` into sub-widget; add full-width waveform strip; enhance timer |
| `ConnectionStatusBar` | `widgets/connection_status.dart` | Add countdown for reconnecting; add action buttons; increase height to 32dp |
| `_SettingsSheet` | `screens/main_screen.dart` | Extract to standalone `settings_screen.dart`; add search; add inline editing; add validation |
| `MessageList` | `widgets/message_list.dart` | Add sync status icons; add offline state handling |

### 8.2 New Components ⭐

| Component | File | Purpose |
|-----------|------|---------|
| `HandsFreeIndicator` | `widgets/hands_free_indicator.dart` | Standalone hands-free state visualization |
| `RecordingWaveform` | `widgets/recording_waveform.dart` | Reusable compact + full-width waveform |
| `OfflineBadge` | `widgets/offline_badge.dart` | AppBar offline indicator chip |
| `CacheStatusBar` | `widgets/cache_status_bar.dart` | Queue count + offline notice |
| `SyncStatusIcon` | `widgets/sync_status_icon.dart` | ⏳ / ✓ icon for message bubbles |
| `SettingsSearch` | `widgets/settings_search.dart` | Real-time settings filter |
| `ValidatedTextField` | `widgets/validated_text_field.dart` | Inline validation for URL/token/prompt |
| `ReconnectCountdown` | `widgets/reconnect_countdown.dart` | "Reconnecting in Xs" ticker |

### 8.3 File Structure Proposal

```
lib/
├── screens/
│   ├── main_screen.dart              # (refactor) Remove _SettingsSheet inline
│   ├── onboarding_screen.dart
│   └── settings_screen.dart          # ⭐ NEW — standalone settings
├── widgets/
│   ├── push_to_talk_button.dart      # (refactor) Extract hands-free
│   ├── hands_free_indicator.dart     # ⭐ NEW
│   ├── recording_waveform.dart       # ⭐ NEW
│   ├── connection_status.dart        # (refactor) Add countdown + actions
│   ├── offline_badge.dart            # ⭐ NEW
│   ├── cache_status_bar.dart         # ⭐ NEW
│   ├── sync_status_icon.dart         # ⭐ NEW
│   ├── settings_search.dart          # ⭐ NEW
│   ├── validated_text_field.dart     # ⭐ NEW
│   ├── reconnect_countdown.dart      # ⭐ NEW
│   ├── message_list.dart             # (refactor) Add sync icons
│   ├── playback_controls.dart
│   └── typing_dots.dart              # ⭐ Extract from message_list.dart
├── providers/
│   ├── app_state.dart
│   ├── connection_state.dart         # (refactor) Add retry delay stream
│   ├── conversation_state.dart       # (refactor) Add sync status
│   └── offline_state.dart            # ⭐ NEW
├── models/
│   ├── websocket_event.dart
│   └── queued_message.dart           # ⭐ NEW
└── theme/
    ├── colors.dart                   # (refactor) Add onlineGlow, offlineBadge
    └── app_theme.dart
```

---

## 9. Accessibility Notes

### 9.1 Screen Reader Support
- `ConnectionStatusBar`: `Semantics(label: _getStatusText(), button: hasAction)`
- `PushToTalkButton`: Announce state changes — "Recording started", "Recording stopped", "Interrupting"
- `HandsFreeIndicator`: Announce "Listening", "Processing", "Speaking" on state change
- `OfflineBadge`: `Semantics(label: "Offline mode, messages will sync when connection returns")`

### 9.2 TalkBack / VoiceOver
- All icon-only buttons must have `tooltip` or `Semantics(label: ...)`
- Waveform bars: `excludeFromSemantics: true` (decorative)
- Recording timer: `Semantics(label: "Recording, 2 minutes 14 seconds")`

### 9.3 Color Contrast
| Element | FG | BG | Ratio | Pass |
|---------|----|-----|-------|------|
| Status text (error) | `#EF4444` | `#1A1B26` | 5.8:1 | ✅ AA |
| Status text (warning)| `#F59E0B` | `#1A1B26` | 8.2:1 | ✅ AA |
| Listening label | `#10B981` | `#1A1B26` | 6.9:1 | ✅ AA |
| PTT button text | `#FFFFFF` | `#6366F1` | 4.6:1 | ✅ AA |

### 9.4 Motion
- Respect `MediaQuery.of(context).disableAnimations`
- All animated containers should check `!disableAnimations` before triggering
- Waveform: when animations disabled, show static bars at current amplitude

---

## Appendix A: Wireframe Quick Reference

### Main Screen — PTT Mode (Connected)
```
┌─────────────────────────────┐
│ Ollama Voice     [+] [⚙️]   │
│ Default Agent               │
├─────────────────────────────┤
│                             │
│ ┌─────────────────────────┐ │
│ │ How can I help?         │ │  <- assistant bubble
│ └─────────────────────────┘ │
│   ┌──────────────────────┐  │
│   │ What's the weather?  │  │  <- user bubble
│   └──────────────────────┘  │
│                             │
├─────────────────────────────┤
│  [↺] | 0.75 1.0 1.25 1.5 │ │  <- playback controls (cond.)
├─────────────────────────────┤
│                             │
│          ╭─────╮            │
│         ( 🎙️  )             │  <- PTT button (idle)
│          ╰─────╯            │
│        Hold to speak        │
│                             │
└─────────────────────────────┘
```

### Main Screen — Hands-Free Listening
```
┌─────────────────────────────┐
│ Ollama Voice     [+] [⚙️]   │
│ Default Agent               │
├─────────────────────────────┤
│                             │
│ ┌─────────────────────────┐ │
│ │ How can I help?         │ │
│ └─────────────────────────┘ │
│                             │
├─────────────────────────────┤
│          ╭─────╮            │
│         ( ≋≋≋ )  ✨ glow   │  <- hands-free listening
│          ╰─────╯            │
│        Listening…           │
│                             │
└─────────────────────────────┘
```

### Main Screen — Offline
```
┌─────────────────────────────┐
│ Ollama Voice [🔍] [🟡Offline][⚙️]│
│ Default Agent               │
├─────────────────────────────┤
│ 🟡 Working offline · 2 msg  │  <- cache status bar
├─────────────────────────────┤
│                             │
│   ┌──────────────────────┐  │
│   │ Hello there!      ⏳  │  │  <- queued message
│   └──────────────────────┘  │
│                             │
│          ╭─────╮            │
│         ( 🎙️  )             │
│          ╰─────╯            │
│        Hold to speak        │
└─────────────────────────────┘
```

### Settings Sheet
```
┌─────────────────────────────┐
│         ═══════             │  <- drag handle
│                             │
│  Settings              [✕]  │
│  ═══════════════════════    │
│  🔍 Search settings…       │
│  ═══════════════════════    │
│  ── CHAT ──                 │
│  Font size  [━━━●━━━━] 16px │
│  Clear conversation      >  │
│  Export conversation     >  │
│  ── INPUT ──                │
│  ☑ Hands-free mode          │
│  ☐ Tap to toggle            │
│  ☐ Barge-in                 │
│  ── CONNECTION ──            │
│  🌐 Server URL    [edit]    │
│  🔑 Auth Token    [edit]    │
│  🧠 System Prompt [edit]    │
└─────────────────────────────┘
```

---

## Appendix B: Priority / Phasing

### Phase 1 — Core Polish (existing code cleanup)
- [ ] Extract `_SettingsSheet` → `settings_screen.dart`
- [ ] Extract `HandsFreeIndicator` from `PushToTalkButton`
- [ ] Add reconnect countdown to `ConnectionStatusBar`
- [ ] Add `Reconnect` / `Settings` action buttons to `ConnectionStatusBar`

### Phase 2 — Waveform Enhancement
- [ ] Create standalone `RecordingWaveform` widget
- [ ] Add full-width waveform strip option
- [ ] Add recording timer with color warning

### Phase 3 — Settings UX
- [ ] Add search bar to settings
- [ ] Add inline editing (no AlertDialog)
- [ ] Add validation for URL/token/prompt
- [ ] Add character counter for system prompt

### Phase 4 — Offline/Cache (new feature)
- [ ] Create `OfflineState` provider
- [ ] Create `QueuedMessage` model + persistence
- [ ] Implement `OfflineBadge` widget
- [ ] Implement `CacheStatusBar` widget
- [ ] Implement `SyncStatusIcon` for message bubbles
- [ ] Implement queue flush on reconnect

---

*End of design specs. Reference existing code at `/root/.openclaw/antlatt-workspace/projects/ollama-voice/client/lib/` for current implementations.*