# Pangea for Apple

A SwiftUI client for the LoRa mesh — designed for hikers, backcountry travellers, emergency communicators, and anyone else who needs to keep talking when the towers don't. Runs on iOS, iPadOS, macOS, visionOS, and watchOS.

Pangea is a downstream distribution of the open-source LoRa mesh client for Apple platforms. It ships the same core radio stack with a distinct identity, a beginner-safe **Expert Mode**, and a battery-first **Power Mode** system tailored for multi-day off-grid use.

## Getting Started

Requires the latest release of Xcode.

1. Clone the repo.
    ```sh
    git clone git@github.com:HabbTech/Pangea-Apple.git
    ```
2. Enter the project directory.
    ```sh
    cd Pangea-Apple
    ```
3. Set up git hooks to lint the project on commit.
    ```sh
    ./scripts/setup-hooks.sh
    ```
4. Open the Xcode workspace.
    ```sh
    open Meshtastic.xcworkspace
    ```
    > The workspace and project files retain their upstream names to keep the shared codebase easy to sync with the maintainer's public releases.
5. Build and run the primary target on any supported destination.

## Supported Operating Systems

The last two major releases of iOS, iPadOS, and macOS are supported.

## What's Distinct About Pangea

### Expert Mode

Pangea ships an **Expert Mode** toggle in `App Settings`. When off, the settings tree only shows the handful of controls a casual user actually needs (User info, Display, Channels, Share QR Code, Ambient Lighting, Firmware Updates). When on, the tree expands to the full radio/device/module configuration surface and any items gated behind Expert Mode are tagged with an orange `Expert Mode` caption so contributors know they were intentionally hidden.

An informational Expert Mode screen appears once during onboarding — it explains the trade-off and points users at the toggle. Enabling Expert Mode is always a deliberate action taken from Settings.

### Power Mode

A three-tier battery profile lives in `App Settings → Battery` and is also reachable from the logo in the top-left corner of every main tab.

| Mode | Behaviour |
|---|---|
| **Standard** | All features on. Default. |
| **Trail** | Smart Position only, cached weather, slower map refresh, lower BLE keep-alive cadence. Best for day trips. |
| **Expedition** | Continuous GPS off, WeatherKit off, Live Activities off, background auto-connect off. Best for multi-day off-grid trips. |

Pangea watches `ProcessInfo.processInfo.isLowPowerModeEnabled` and temporarily bumps the effective mode up to **Expedition** while iOS's own Low Power Mode is active. The App Settings picker shows an orange indicator during those bumps and reverts to the user's choice when the OS drops out of LPM.

Feature sites (WeatherKit rendering, BLE auto-connect on discovery, CarPlay and node Live Activities) consult a shared `PowerManager` before doing work, so the ceiling is enforced consistently without touching individual feature toggles.

## Updating Protobufs

```bash
./scripts/gen_protos.sh
```

Build, test, and commit the result.

## Deep Links

Pangea registers two URL schemes on iOS: the legacy `meshtastic://` scheme (still used by internal navigation and existing shortcuts) and the forward-facing `pangea://` scheme. Both resolve to the same routes.

### Messages

| URL | Description |
|-----|-------------|
| `meshtastic:///messages` | Messages tab |
| `meshtastic:///messages?channelId={channelId}&messageId={messageId}` | Channel messages (`messageId` optional) |
| `meshtastic:///messages?userNum={userNum}&messageId={messageId}` | Direct messages (`messageId` optional) |

### Connect

| URL | Description |
|-----|-------------|
| `meshtastic:///connect` | Connect tab |

### Nodes

| URL | Description |
|-----|-------------|
| `meshtastic:///nodes` | Nodes tab |
| `meshtastic:///nodes?nodenum={nodenum}` | Selected node |

### Mesh Map

| URL | Description |
|-----|-------------|
| `meshtastic:///map` | Map tab |
| `meshtastic:///map?nodenum={nodenum}` | Node on map |
| `meshtastic:///map?waypointId={waypointId}` | Waypoint on map |

### Settings

Each settings entry has a deep link. Parameters are not supported for settings URLs.

| URL | Description |
|-----|-------------|
| `meshtastic:///settings/about` | About Pangea |
| `meshtastic:///settings/appSettings` | App Settings |
| `meshtastic:///settings/routes` | Routes |
| `meshtastic:///settings/routeRecorder` | Route Recorder |
| **Radio Config** | |
| `meshtastic:///settings/lora` | LoRa Config |
| `meshtastic:///settings/channels` | Channels |
| `meshtastic:///settings/security` | Security Config |
| `meshtastic:///settings/shareQRCode` | Share QR Code |
| **Device Config** | |
| `meshtastic:///settings/user` | User Config |
| `meshtastic:///settings/bluetooth` | Bluetooth Config |
| `meshtastic:///settings/device` | Device Config |
| `meshtastic:///settings/display` | Display Config |
| `meshtastic:///settings/network` | Network Config |
| `meshtastic:///settings/position` | Position Config |
| `meshtastic:///settings/power` | Power Config |
| **Module Config** | |
| `meshtastic:///settings/ambientLighting` | Ambient Lighting |
| `meshtastic:///settings/cannedMessages` | Canned Messages |
| `meshtastic:///settings/detectionSensor` | Detection Sensor |
| `meshtastic:///settings/externalNotification` | External Notification |
| `meshtastic:///settings/mqtt` | MQTT |
| `meshtastic:///settings/paxCounter` | Pax Counter |
| `meshtastic:///settings/rangeTest` | Range Test |
| `meshtastic:///settings/ringtone` | Ringtone |
| `meshtastic:///settings/serial` | Serial |
| `meshtastic:///settings/storeAndForward` | Store & Forward |
| `meshtastic:///settings/telemetry` | Telemetry |
| **TAK** | |
| `meshtastic:///settings/tak` | TAK Config |
| **Logging** | |
| `meshtastic:///settings/debugLogs` | Debug Logs |
| **Developers** | |
| `meshtastic:///settings/appFiles` | App Files |
| `meshtastic:///settings/firmwareUpdates` | Firmware Updates |

## CarPlay

Pangea supports Apple CarPlay for hands-free mesh messaging while driving. The CarPlay interface integrates with the iOS messaging system and Siri so you can send and receive Pangea messages without looking at your phone.

### Requirements

- iPhone running iOS 16 or later
- A supported CarPlay head unit or the CarPlay Simulator in Xcode
- A Pangea device connected via Bluetooth, TCP, or serial
- Siri enabled — Pangea requests Siri authorization during onboarding

### Interface

The CarPlay screen presents a two-tab interface:

| Tab | Description |
|-----|-------------|
| **Channels** | Lists all active mesh channels |
| **Direct Messages** | Lists recent and favorite contacts |

When no device is connected, both tabs show a **Not Connected** status item and a prompt to open the app.

#### Channels Tab

Each channel row shows:
- The channel name (or `Primary Channel` for index 0)
- An unread message badge when there are unread messages
- `Primary` or `Ch N` as detail text

Tapping a row starts a Siri compose session for that channel.

#### Direct Messages Tab

Two sections:

- **Favorites** — nodes marked as favorites (⭐), sorted by last heard
- **Recent** — all other messageable contacts with history, sorted by last heard (capped at 24 entries)

Each contact row shows:
- Contact name and a person icon
- Unread message count when applicable
- Time since last heard (`Just now`, `5m ago`, `2h ago`, `3d ago`)

### Siri Voice Commands

| Voice Command | Example Phrase | Description |
|---|---|---|
| Send Message | "Send a message on Pangea" | Composes and sends a text message to a contact or channel |
| Search Messages | "Search Pangea messages" | Searches message history |
| Mark as Read | "Mark Pangea message as read" | Marks a conversation as read |

**Limitations:**
- Messages are capped at **200 bytes** (UTF-8). Siri will not send messages that exceed the limit.
- Only a **single recipient** per message — no group direct messages.
- Emoji-only and admin messages are excluded from CarPlay.

### Incoming Message Announcements

When CarPlay is connected and **Announce Notifications** is on in iOS Settings → Siri, Siri reads incoming messages aloud. Only non-emoji, non-admin text messages trigger announcements.

Up to 50 unread messages that arrived before the CarPlay session started are donated to Siri at connection time so they can be read back on demand.

### Live Activity

When a device connects during a CarPlay session, a Dynamic Island / Lock Screen Live Activity starts automatically (iOS only, not macOS). It displays:

- Node name and short name
- Uptime, channel utilization, and air-time TX percentage
- Packets sent, received, and relay statistics
- Online and total node counts
- A 15-minute countdown timer synced with the telemetry reporting interval

The Live Activity ends automatically when CarPlay disconnects — and while Power Mode is set to **Trail** or **Expedition**, or while iOS Low Power Mode is on, the Live Activity is suppressed to save battery.

### Architecture Notes (For Developers)

| Component | File | Description |
|---|---|---|
| `CarPlaySceneDelegate` | `Meshtastic/CarPlay/CarPlaySceneDelegate.swift` | `CPTemplateApplicationSceneDelegate` that builds and manages the two-tab UI |
| `CarPlayIntentDonation` | `Meshtastic/CarPlay/CarPlayIntentDonation.swift` | Donates incoming and outgoing `INSendMessageIntent` interactions so conversations appear in CarPlay Messages and Siri can read them aloud |
| `SendMessageIntentHandler` | `Meshtastic/Intents/SendMessageIntentHandler.swift` | Handles `INSendMessageIntent` — resolves recipients/channels and sends over the active transport |
| `SearchForMessagesIntentHandler` | `Meshtastic/Intents/SearchForMessagesIntentHandler.swift` | Handles `INSearchForMessagesIntent` |
| `SetMessageAttributeIntentHandler` | `Meshtastic/Intents/SetMessageAttributeIntentHandler.swift` | Handles `INSetMessageAttributeIntent` (mark as read) |
| `IntentHandler` | `Meshtastic/Intents/IntentHandler.swift` | Routes `INIntent`s to the appropriate handler |
| `PowerManager` | `Meshtastic/Helpers/PowerManager.swift` | Central source of truth for Power Mode. Feature sites read `allowsWeatherKit`, `allowsLiveActivities`, `allowsBackgroundAutoConnect`, and `locationIntervalFloor` instead of branching on the raw enum. |

The scene delegate subscribes to `AccessoryManager.shared.$isConnected` with a 300 ms debounce and calls `updateSections(_:)` on the existing `CPListTemplate` instances (rather than rebuilding the whole template tree) to minimise flicker during reconnects.

Intent donations are de-duplicated per CarPlay session using an in-memory set to avoid repeated IPC calls to the intents daemon on every list refresh.

## Release Process

See [RELEASING.md](./RELEASING.md).

## Code Standards

- SwiftUI for all views
- SF Symbols for icons
- Core Data for persistence

## License

GPL v3. See the [LICENSE](LICENSE) file for details.

Pangea is a downstream distribution of the open-source LoRa mesh client for Apple platforms. Credit and gratitude to the upstream maintainers whose work made this possible; app-level bugs unique to Pangea should be reported here rather than upstream.
