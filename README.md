# WinSwitch

Minimal macOS window/app switcher. No screen capture, no SCStream, no battery drain.

| Shortcut | Action |
|----------|--------|
| `Cmd+Tab` | Switch between apps |
| `Cmd+Shift+Tab` | Switch between apps (reverse) |
| `Cmd+\`` | Switch between windows within current app |
| `Cmd+Shift+\`` | Switch between windows (reverse) |

Hold `Cmd`, tap to cycle. Release `Cmd` to activate. Click any item to jump directly.

## Why

AltTab and similar tools use `SCStream` (a video streaming API) to capture window thumbnails, firing once per second in the background. This keeps WindowServer at 40–50% CPU and drains ~25W continuously. WinSwitch uses only the Accessibility API — window titles and app icons, no screen capture.

## Build

```bash
git clone https://github.com/YOUR_USERNAME/winswitch
cd winswitch
bash build.sh
open WinSwitch.app
```

Requires macOS 13+. On first launch, grant **Accessibility** in System Settings → Privacy & Security → Accessibility.

## How it works

- **Global hotkey**: `CGEventTap` intercepts `Cmd+Tab` and `Cmd+\`` before the system handles them
- **App list**: `NSWorkspace.shared.runningApplications` (no capture)
- **Window list**: `AXUIElement` Accessibility API (no capture)
- **App icons**: `NSRunningApplication.icon` (system-provided, no capture)
- **No background polling**: event tap only activates on keypress
