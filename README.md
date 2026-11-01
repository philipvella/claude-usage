# Claude Usage – macOS Menu Bar App

A lightweight native macOS menu bar app that shows your **claude.ai plan usage** as a pie chart with a percentage. It refreshes automatically every 5 minutes.

```
 ◔ 42%      ← the pie fills clockwise from 0% to 100%
```

Written in Swift with AppKit and WebKit. No Electron and no third-party dependencies.

---

## Features

- **Menu bar pie chart**: fills from 0 to 100% of the selected usage limit, with the percentage next to it.
- **Colour warnings**: the pie follows the light/dark menu bar normally, turns **orange at 80%** and **red at 95%**.
- **Auto refresh**: every 5 minutes, and again when your Mac wakes from sleep.
- **All limits in one menu**: current 5-hour session, weekly (all models), weekly Opus/Sonnet, each with its reset time.
- **Choose what the menu bar shows**: pick which limit drives the pie.
- **Web sign-in**: sign in once in a built-in browser window and you stay signed in.
- **Launch at Login** toggle.
- **Menu bar only**: no Dock icon.

## Requirements

- macOS 13 (Ventura) or later
- Xcode or the Xcode Command Line Tools (Swift 5.9+), needed to build
- A claude.ai account (Free, Pro, Max, Team…)

## Installation

```bash
git clone https://github.com/philipvella/claude-usage.git
cd claude-usage
./build.sh install
```

This builds the app, copies **Claude Usage.app** to `/Applications` and launches it.

To build without installing:

```bash
./build.sh            # output: build/Claude Usage.app
```

To use your own bundle identifier:

```bash
BUNDLE_ID=com.yourname.ClaudeUsage ./build.sh install
```

> The app is ad-hoc signed. If macOS Gatekeeper blocks it, right-click the app → **Open** once.

## Usage

1. **First launch:** a window opens on the claude.ai login page. Sign in as you normally would. The window closes by itself once sign-in succeeds.
2. The pie and percentage appear in the menu bar.
3. Click the icon to open the menu:

| Menu item | What it does |
|---|---|
| *Usage rows* | Each limit's % used and when it resets |
| **Refresh Now** (⌘R) | Fetch usage immediately |
| **Open Usage on claude.ai** | Opens the official usage page |
| **Show in Menu Bar ›** | Pick which limit the pie shows |
| **Launch at Login** | Start automatically when you log in |
| **Sign In… / Sign Out** | Re-authenticate or clear the stored session |
| **Paste Session Key…** | Manual fallback sign-in (see below) |

### If web sign-in doesn't work

Google sign-in sometimes refuses to run inside built-in browsers. You can:

- use **email login** and type in the code that is emailed to you, or
- use **Paste Session Key…**: in a browser where you're signed in to claude.ai, open Developer Tools → Application/Storage → Cookies → `https://claude.ai`, and copy the value of the `sessionKey` cookie.

## How it works

```
┌──────────────┐   sign in (WKWebView)   ┌───────────┐
│  Menu bar    │ ──────────────────────▶ │ claude.ai │
│  app         │ ◀── session cookies ─── │           │
│              │                         │           │
│  every 5 min │ ── GET /api/organizations/{org}/usage ──▶
└──────────────┘ ◀── { five_hour, seven_day, … utilization % }
```

- Sign-in uses claude.ai's own login page in a `WKWebView`. The session cookies stay in the app's own WebKit data store on your Mac.
- Usage comes from `https://claude.ai/api/organizations/{org}/usage`, the same endpoint the claude.ai **Settings → Usage** page uses.
- The parser handles any field that has a `utilization` value, so new limit types show up automatically.

### Project structure

```
Sources/ClaudeUsage/
├── main.swift                    # App entry point (menu-bar-only app)
├── AppDelegate.swift             # Status item, menu, 5-minute timer
├── UsageService.swift            # Cookie handling + claude.ai API calls + parsing
├── LoginWindowController.swift   # Web sign-in window
└── PieIcon.swift                 # Draws the pie chart icon
build.sh                          # Builds, bundles, signs (and installs) the .app
```

## Privacy & security

- Your credentials and session cookies **never leave your Mac**. They are only sent to `claude.ai`.
- No analytics or telemetry, and no third-party servers.
- **Sign Out** deletes all stored claude.ai cookies and website data.
- Never commit or share your `sessionKey`. It gives full access to your Claude account.

## Disclaimer

This is an **unofficial** project and is not affiliated with Anthropic. It uses an undocumented claude.ai web endpoint that may change or stop working at any time.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Menu bar shows `!` | Open the menu to see the error. Usually choosing **Sign In…** again fixes it. |
| "Request blocked by claude.ai (Cloudflare)" | Sign in again through the web window to refresh cookies. |
| Launch at Login does nothing | Make sure the app is in `/Applications` (`./build.sh install`). |
| Icon doesn't appear | The menu bar may be full. Quit some menu bar apps or use a menu bar manager. |
