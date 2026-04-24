# Ollama Voice — Client UI/UX Design Specs

**Version:** 1.0  
**Last Updated:** 2026-04-24  
**Platform:** Flutter (iOS/Android)  
**Target:** Single-person voice chat with Ollama AI agents

---

## 1. Design System

### 1.1 Color Palette

| Token | Dark | Light | Usage |
|-------|------|-------|-------|
| **Primary** | `#6366F1` | `#6366F1` | Buttons, active states, mic icon |
| **Secondary** | `#8B5CF6` | `#8B5CF6` | Gradients, accents |
| **Success** | `#10B981` | `#10B981` | Connected, listening |
| **Warning** | `#F59E0B` | `#F59E0B` | Connecting, processing |
| **Error** | `#EF4444` | `#EF4444` | Disconnected, interrupt, errors |
| **Background** | `#1A1B26` | `#F5F5F7` | App background |
| **Surface** | `#24283B` | `#EEEEF2` | Cards, input fields, sheets |
| **Card** | `#292E42` | `#E2E2E8` | Message bubbles (assistant) |
| **Text Primary** | `#FFFFFF` | `#1A1B26` | Headlines, body |
| **Text Secondary** | `#9CA3AF` | `#6B7280` | Subtitles, hints, timestamps |

### 1.2 Typography

| Style | Size | Weight | Color |
|-------|------|--------|-------|
| App Bar Title | 16px | w600 | textPrimary |
| App Bar Subtitle | 11px | w500 | secondary |
| Message Body | 14px (user-configurable 11–22px) | w400 | textPrimary |
| Section Header | 11px | w700 | textSecondary |
| Status Label | 11px | w500 | context-dependent |
| Timestamp | 11px | w400 | textSecondary @ 50% opacity |

### 1.3 Spacing & Shape

- **Border radius (buttons/cards):** 12px
- **Border radius (chips):** 8px
- **Border radius (bottom sheets):** 20px top corners
- **Standard padding:** 16px horizontal, 12–24px vertical
- **Message bubble padding:** 14px horizontal, 10px vertical
- **Bubble radii:** 16px all corners; bottom-left 4px (user), bottom-right 4px (assistant)

### 1.4 Motion Principles

- **Micro-interactions:** 80–150ms for button presses, chip toggles
- **Panel transitions:** 200–300ms easeOut
- **Status changes:** 300ms animated container (size, color, glow)
- **Waveform bars:** 80ms reactivity (tied to audio amplitude stream)
- **Typing dots:** 900ms looping sine-wave offset animation

---

## 2. Screen Architecture

```
AppShell
├── OnboardingScreen (if !isOnboarded)
│   ├── Step 0: Welcome
│   ├── Step 1: Microphone Permission
│   └── Step 2: Server URL + Auth Token
├── _ConnectingScreen (while status == connecting)
├── Error Screen (if disconnected + errorMessage)
└── MainScreen
    ├── AppBar (title + agent subtitle + actions)
    ├── Drawer (conversation list)
    ├── Body
    │   ├── ConnectionStatusBar (conditional)
    │   ├── LatencyOverlay (conditional, debug)
    │   ├── MessageList (scrollable, reverse)
    │   │   ├── Date separators
    │   │   ├── Message bubbles (user / assistant)
    │   │   ├── Live transcript bubble
    │   │   ├── Live response bubble
    │   │   └── TypingDots
    │   └── Scroll-to-bottom FAB
    ├── PlaybackControlsBar (conditional)
    └── Bottom Control Area
        ├── Text Input Row (if _isTextInput)
        └── PushToTalkButton (if !_isTextInput)
    └── Settings Bottom Sheet (modal)
```

---

## 3. Hands-Free Mode UI Layout

### 3.1 State Machine

```
[IDLE] ──→ [LISTENING] ──→ [PROCESSING] ──→ [RESPONDING] ──→ [IDLE]
   ↑                                                              │
   └──────────────── [BARGE-IN INTERRUPT] ←────────────────────────┘
```

### 3.2 Hands-Free Indicator Component (`PushToTalkButton` variant)

**Location:** Centered in bottom control area, replacing the PTT button when `handsFreeEnabled == true`.

#### State Visuals

| State | Visual | Size | Glow |
|-------|--------|------|------|
| **Idle** | `Icons.hearing_rounded` @ 30px, white @ 70% opacity | 72px circle | Primary @ 50% opacity, 14px blur, 1px spread |
| **Listening** | 5-bar live waveform, white @ 90% opacity | 88px circle | Green @ 50% opacity, 28px blur, 4px spread |
| **Processing** | `CircularProgressIndicator` (white, 2.5px stroke) | 72px circle | Warning @ 20% opacity, 14px blur, 1px spread |
| **Responding** | Interrupt button (`Icons.stop_rounded`) | 80px circle | Error @ 40% opacity, 20px blur, 2px spread |

#### Waveform Behavior (Listening State)

```
Bar heights (center-tallest):
  [0.45] [0.70] [1.00] [0.70] [0.45]

Each bar = AnimatedContainer(duration: 80ms)
Height = clamp(6px … 40px) based on normalized amplitude
Width = 4px, Padding = 2.5px horizontal, Radius = 2px
Color = white @ 90% opacity
```

#### Label Below Indicator

| State | Text | Color | Weight |
|-------|------|-------|--------|
| Idle | "Hands-free" | textSecondary | normal |
| Listening | "Listening…" | green | w600 |
| Processing | "Processing…" | warning | w600 |

Uses `AnimatedSwitcher(duration: 200ms)` for text transitions.

### 3.3 Microphone Button States (PTT Mode)

**Default State:**
- 80px circle, Primary color
- `Icons.mic_none_rounded` @ 36px, white
- BoxShadow: Primary @ 40% opacity, 16px blur, 2px spread

**Recording State:**
- 88px circle, Error color
- 5-bar waveform (same as hands-free listening)
- BoxShadow: Error @ 40% opacity, 30px blur, 4px spread
- Below: elapsed timer in `mm:ss`, Error color, 12px, w600

**Tap-Toggle Mode:**
- Same visual as hold, but with label "Tap to speak" below (11px, textSecondary)

### 3.4 Interaction Matrix

| Mode | Gesture | Action |
|------|---------|--------|
| PTT (hold) | `onPointerDown` | Start recording, haptic medium |
| PTT (hold) | `onPointerUp` / `onPointerCancel` | Stop recording, haptic light |
| Tap-Toggle | Tap while idle | Start recording, haptic medium |
| Tap-Toggle | Tap while recording | Stop recording, haptic light |
| Hands-Free | N/A (always on) | Auto-streams; tap button to interrupt |
| Any mode | Tap interrupt button | `sendInterrupt()`, haptic medium |

---

## 4. Connection State Visualization

### 4.1 Status Bar (`ConnectionStatusBar`)

**Visibility:** Only when `status != connected`. Collapses to `SizedBox.shrink()` when connected.

**Layout:** Full-width container, 6px vertical padding, 12px horizontal padding.

| Status | Background | Dot Color | Text |
|--------|-----------|-----------|------|
| Connected | Hidden | Success | Hidden |
| Connecting | Warning @ 15% | Warning | "Connecting…" |
| Reconnecting | Warning @ 15% | Warning | "Reconnecting…" |
| Disconnected (no network) | Error @ 15% | Error | "No network connection" |
| Disconnected (server down) | Error @ 15% | Error | "Server unreachable" |
| Disconnected (generic) | Error @ 15% | Error | "Disconnected" |

**Disconnected State Actions:**
- Right side: "Reconnect" pill button
  - Background: Primary @ 15%
  - Border: Primary @ 40%, 1px
  - Text: Primary, 11px, w600
  - Padding: 10px horizontal, 3px vertical
  - Radius: 10px

### 4.2 Full-Screen Connection States

#### `_ConnectingScreen`
```
Scaffold(body: Center(
  Column(mainAxisSize: MainAxisSize.min, children: [
    CircularProgressIndicator(),
    SizedBox(height: 16),
    Text('Connecting to OpenClaw…'),
  ]),
))
```

#### Error Screen (`AppShell`)
```
Scaffold(body: Center(
  Padding(24px, Column(mainAxisSize: MainAxisSize.min, children: [
    Icon(Icons.error_outline, 48px, red),
    SizedBox(height: 16),
    Text('Connection Failed', headlineSmall),
    SizedBox(height: 8),
    Text(<friendly_error>, textAlign: center),
    SizedBox(height: 24),
    FilledButton('Retry', onPressed: manualReconnect),
  ])))
```

**Friendly Error Mapping:**
| Raw Error | Friendly Message |
|-----------|-----------------|
| "authentication failed" | "Authentication failed. Check your token in Settings." |
| "timeout" | "Connection timed out. Check your server URL and network." |
| "host lookup" / "SocketException" | "Cannot reach the server. Check your network and server URL." |
| default | "Could not connect to the server. Tap Retry to try again." |

### 4.3 AppBar Connection Indicator

- When connected: Agent name shown as subtitle in AppBar (11px, secondary color)
- When disconnected + error: Consider pulsing the settings icon or showing a dot badge (not currently implemented — opportunity)

---

## 5. Voice Recording Waveform Visualization

### 5.1 5-Bar Waveform (`_buildWaveform()`)

**Used in:**
- PTT recording state
- Hands-free listening state

**Geometry:**
```
Row(mainAxisAlignment: MainAxisAlignment.center)
  ├─ Bar 0: height = clamp(88 * (0.15 + amp * 0.45), 6, 40)
  ├─ Bar 1: height = clamp(88 * (0.15 + amp * 0.70), 6, 40)
  ├─ Bar 2: height = clamp(88 * (0.15 + amp * 1.00), 6, 40)
  ├─ Bar 3: height = clamp(88 * (0.15 + amp * 0.70), 6, 40)
  └─ Bar 4: height = clamp(88 * (0.15 + amp * 0.45), 6, 40)
```

- **Width per bar:** 4px
- **Gap:** 2.5px horizontal padding
- **Color:** white @ 90% opacity
- **Border radius:** 2px
- **Animation:** `AnimatedContainer(duration: 80ms)`

**Amplitude normalization (from RecorderService):**
```
raw dBFS → normalized = clamp((db + 80) / 70, 0.0, 1.0)
// Maps typical speech range (-80 … -10 dBFS) → 0.0 … 1.0
```

### 5.2 Recording Timer

- Positioned below the mic button (PTT mode only)
- Format: `mm:ss`
- Color: Error
- Size: 12px, weight: w600
- Updates every 1 second via `Timer.periodic`

### 5.3 Processing Indicator (Non-Recording)

- 72px circle
- Background: Warning @ 12%
- Border: Warning @ 40%, 2px
- Center: `CircularProgressIndicator` (Warning color, 2.5px stroke)
- Label below: "Processing…" (Warning, 11px, w500)

---

## 6. Settings/Config Screen Layout

### 6.1 Entry Point

- Accessed via `Icons.settings` in AppBar actions (rightmost)
- Opens as `showModalBottomSheet` with `DraggableScrollableSheet`
  - Initial: 75% screen height
  - Min: 40%
  - Max: 95%
  - Top radius: 20px
  - Grab handle: 40×4px pill, textSecondary @ 40%

### 6.2 Sheet Structure

```
_SettingsSheet (ListView)
├── Grab Handle
├── "Settings" Title (titleLarge)
│
├── _SectionHeader("CHAT")
│   ├── Font Size Slider (11–22px, 11 divisions)
│   ├── Clear Conversation (destructive)
│   └── Export Conversation
│
├── _SectionHeader("INPUT")
│   ├── Hands-free mode (Switch)
│   ├── Tap to toggle (Switch, disabled if hands-free)
│   └── Barge-in (Switch, disabled if !hands-free)
│
├── _SectionHeader("OUTPUT")
│   └── (playback speed lives in PlaybackControlsBar, not here)
│
├── _SectionHeader("AGENT")
│   └── Agent selector list (avatar + name + description + check)
│
├── _SectionHeader("APPEARANCE")
│   └── Theme SegmentedButton (Dark / Light / Auto)
│
├── _SectionHeader("POWER")
│   └── Keep screen on (Switch)
│
├── _SectionHeader("DEVELOPER")
│   └── Latency overlay (Switch)
│
└── _SectionHeader("CONNECTION")
    ├── Server URL (editable)
    ├── Auth Token (editable, obscured)
    └── System Prompt (editable, multiline)
```

### 6.3 Section Header Style

```dart
Text(
  title,
  style: TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w700,
    color: AppColors.textSecondary,
    letterSpacing: 0.8,
  ),
)
```

### 6.4 Config Edit Dialog

**Trigger:** Tap any CONNECTION list tile.

**Layout:** AlertDialog
- Title: Config name
- Content: TextField
  - Single-line for URL/token
  - Multi-line (maxLines: 8) for system prompt
  - `obscureText` with visibility toggle for token
- Actions: Cancel, Save
- On save: persists to SharedPreferences, triggers `manualReconnect()` (for URL/token/agent/mode changes)

**System Prompt Special Handling:**
- Save locally → `_config.setSystemPrompt()`
- Send to server → `conn.sendSetConfig(systemPrompt: changed)`
- No reconnect needed for prompt-only changes

### 6.5 Visual Design Notes

- **Switches:** Standard Material 3 `SwitchListTile` with icon leading
- **Disabled switches:** Flutter default opacity/grey
- **Sliders:** Value label shown as "14px" to the right
- **Agent list:** CircleAvatar (16px radius) with initial letter; selected shows `Icons.check_circle_rounded` (Primary, 20px)
- **Theme selector:** `SegmentedButton<ThemeMode>` with icon+label segments

---

## 7. Offline/Cache Handling Indicators

### 7.1 Current Cache Strategy

The app uses `sqflite` for local persistence with the following tables:

| Table | Purpose |
|-------|---------|
| `conversations` | Chat metadata (id, name, created_at, updated_at) |
| `messages` | Message content (id, conversation_id, role, content, timestamp) |

**Auto-pruning:** Keep last 50 conversations; prune once per day on init.

### 7.2 Missing Offline Indicators (Opportunities)

The current codebase has **no explicit offline/cache UI indicators**. Below are the recommended additions:

#### 7.2.1 Offline Banner

**When to show:** `!connState.hasNetwork && connState.isConnected`

**Design:**
- Position: Below ConnectionStatusBar (or replace it)
- Background: Warning @ 10%
- Border bottom: Warning @ 30%, 1px
- Icon: `Icons.cloud_off` (Warning, 16px)
- Text: "Working offline. Messages saved locally." (Warning, 12px)
- Right action: "Retry now" text button

#### 7.2.2 Cached Message Badges

**When to show:** Messages that were created while offline.

**Design:**
- Small cloud icon (`Icons.cloud_off`, 10px) next to timestamp
- Tooltip: "Saved locally; will sync when reconnected"

#### 7.2.3 Send Queue Indicator

**When to show:** User sends a message while offline.

**Design:**
- Message bubble appears immediately (optimistic UI)
- Spinner overlay on the bubble: `CircularProgressIndicator` (12px, textSecondary)
- Text: "Queued" label below bubble
- On reconnect: spinner fades, "Queued" label removed, normal timestamp appears

#### 7.2.4 Conversation Sync Status

**In drawer:**
- Conversations with unsynced messages show a dot badge (Warning, 6px) on the trailing edge
- Tooltip on long-press: "Has unsaved changes"

#### 7.2.5 Last Sync Timestamp

**In settings sheet:**
- Add under CONNECTION section:
  - "Last synced: Just now" / "Last synced: 2 hours ago" / "Never synced"
  - Text: textSecondary, 11px

### 7.3 Cache Error States

| Scenario | UI Response |
|----------|-------------|
| SQLite init fails | SnackBar: "Failed to load conversations. Restart the app." |
| Message save fails | SnackBar: "Message saved temporarily. Will retry." |
| Pruning fails (rare) | Silent failure; retried next init |

---

## 8. Component Inventory

### 8.1 Existing Components

| Component | File | Description |
|-----------|------|-------------|
| `PushToTalkButton` | `widgets/push_to_talk_button.dart` | Mic button with waveform, timer, mode switching |
| `ConnectionStatusBar` | `widgets/connection_status.dart` | Top status banner |
| `MessageList` | `widgets/message_list.dart` | Scrollable message list with date separators, search, actions |
| `PlaybackControlsBar` | `widgets/playback_controls.dart` | Floating playback speed + mute + skip controls |
| `_SettingsSheet` | `screens/main_screen.dart` (inline) | Draggable settings bottom sheet |
| `_ConversationDrawer` | `screens/main_screen.dart` (inline) | Side drawer with conversation history |
| `_LatencyOverlay` | `screens/main_screen.dart` (inline) | Debug timing overlay |
| `_TypingDots` | `widgets/message_list.dart` (inline) | Animated typing indicator |

### 8.2 Recommended New Components

| Component | Purpose | File Suggestion |
|-----------|---------|-----------------|
| `OfflineBanner` | Network loss indicator | `widgets/offline_banner.dart` |
| `SyncBadge` | Unsynced message marker | `widgets/sync_badge.dart` |
| `WaveformVisualizer` | Extracted reusable waveform | `widgets/waveform_visualizer.dart` |
| `ConnectionStateIcon` | Compact status dot/indicator | `widgets/connection_state_icon.dart` |
| `ConfigTextField` | Reusable edit dialog | `widgets/config_text_field.dart` |
| `EmptyState` | No messages placeholder | `widgets/empty_state.dart` |

---

## 9. Accessibility Considerations

- **VoiceOver/TalkBack:** All interactive elements have semantic labels
- **PTT button:** `onPointerDown`/`Up` should trigger haptics for physical feedback
- **Waveform:** Decorative — add `ExcludeSemantics` or describe as "Recording audio"
- **Color alone:** Never use color as the sole indicator of state (always pair with icon/text)
- **Minimum touch targets:** 48×48dp for all tappable elements
- **Contrast ratios:** All text meets WCAG AA against both dark and light backgrounds

---

## 10. Responsive Behavior

| Breakpoint | Layout Changes |
|------------|---------------|
| Phone portrait (default) | Current layout |
| Phone landscape | Consider side-by-side: conversation list + messages |
| Tablet | Use `NavigationRail` instead of drawer; split-pane conversation view |
| Foldable (unfolded) | Same as tablet |

---

## 11. Asset Requirements

| Asset | Type | Notes |
|-------|------|-------|
| App icon | SVG/PNG | `Icons.mic_rounded` used as placeholder in onboarding |
| No messages illustration | SVG/PNG | Currently uses `Icons.mic_none_rounded` @ 64px |
| Agent avatars | Generated | CircleAvatar with initial letter (current) |

---

## Appendix A: State-to-Visual Mapping

### PushToTalkButton Render Logic

```
if (isPlaying || (isHandsFreeMode && isResponding)):
    → _buildInterruptButton()
else if (isHandsFreeMode):
    → _buildHandsFreeIndicator()
else if (isProcessing && !isRecording):
    → _buildProcessingIndicator()
else:
    → tapToggleMode ? _buildTapToggleButton() : _buildHoldButton()
```

### Hands-Free Indicator Sub-States

```
if (processing && !listening):
    → Warning color, 72px, spinner, "Processing…"
else if (listening):
    → Green color, 88px, waveform, "Listening…"
else:
    → Primary @ 50%, 72px, hearing icon, "Hands-free"
```

---

## Appendix B: Wireframe ASCII

### Main Screen (PTT Mode, Connected)

```
┌─────────────────────────────────────┐
│ ≡  Ollama Voice              + ⌨ 🔍 ⚙ │  ← AppBar
│        Default                      │
├─────────────────────────────────────┤
│                                     │
│    [Today]                          │
│         ┌──────────────┐            │
│         │ Hey, what's  │            │  ← User bubble
│         │ up?          │            │
│         └──────────────┘            │
│   ┌─────────────────────────┐       │
│   │ Not much! Just thinking │       │  ← Assistant bubble
│   │ about what to make for  │       │
│   │ dinner tonight.         │       │
│   └─────────────────────────┘       │
│                                     │
│         ┌──────────────┐            │
│         │ What should  │            │
│         │ I cook?      │            │
│         └──────────────┘            │
│   ┌─────────────────────────┐       │
│   │ How about pasta? It's   │       │
│   │ quick and —             │       │  ← Live response
│   └─────────────────────────┘       │
│         ●  ●  ●                     │  ← Typing dots
│                                     │
├─────────────────────────────────────┤
│  [Replay] [0.75] [1×] [1.25] [1.5] [Skip] [Mute]  ← PlaybackControlsBar
├─────────────────────────────────────┤
│              ┌─────┐                │
│              │  🎙  │                │  ← PushToTalkButton
│              └─────┘                │
│                                     │
└─────────────────────────────────────┘
```

### Main Screen (Hands-Free, Listening)

```
┌─────────────────────────────────────┐
│ ≡  Ollama Voice              + ⌨ 🔍 ⚙ │
│        Default                      │
├─────────────────────────────────────┤
│                                     │
│   (Message history same as above)   │
│                                     │
├─────────────────────────────────────┤
│                                     │
│              ╭─────╮                │
│              │▁ ▂ ▄ ▂ ▁│                │  ← Waveform (green glow)
│              ╰─────╯                │
│            Listening…               │
│                                     │
└─────────────────────────────────────┘
```

### Settings Sheet (75% height)

```
┌─────────────────────────────────────┐
│           ═══════                   │  ← Grab handle
│  Settings                           │
│                                     │
│  CHAT                               │
│  [Font size ───────●─────]  14px    │
│  🗑  Clear Conversation            │
│  ⤴  Export Conversation            │
│  ─────────────────────────────────  │
│  INPUT                              │
│  🎧  Hands-free mode      [══]      │
│  👆  Tap to toggle        [  ]      │
│  🎧  Barge-in             [  ]      │
│  ─────────────────────────────────  │
│  AGENT                              │
│  Ⓓ  Default              ✓         │
│  ─────────────────────────────────  │
│  APPEARANCE                         │
│  🎨  Theme    [🌙 Dark] [☀ Light] [📱 Auto] │
│  ─────────────────────────────────  │
│  CONNECTION                         │
│  🌐  Server URL   wss://...   ✎    │
│  🔑  Auth Token   ••••••••    ✎    │
│  🧠  System Prompt  Tap to...  ✎    │
│                                     │
└─────────────────────────────────────┘
```

### Connection Status Bar

```
┌─────────────────────────────────────┐
│ ●  Reconnecting…            Retry   │  ← Warning state
│ ●  Disconnected — No network  Retry │  ← Error state
│ ●  Connecting…                      │  ← Warning, no retry button
│ (hidden when connected)             │
└─────────────────────────────────────┘
```

---

*End of Design Specs*
