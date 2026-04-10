# OnBlast

`OnBlast` is a macOS menu-bar helper for remapping headset and media-button events to actions like microphone mute, media transport controls, and extra function keys such as `F19`.

It is designed around Bose Bluetooth headset behavior on macOS, including the common case where the center button triggers Siri instead of exposing a normal keyboard shortcut.

Current tracked version: `1.0.0`

This workspace follows the plan in `/Users/gieseking/Downloads/Bose_Mac_Remapping_Plan.docx`:

- Menu-bar utility with a settings window
- Core Audio microphone mute control
- Public system-defined event interception
- Best-effort HID monitoring for Bose devices
- Experimental private `MediaRemote` bridge for deeper diagnostics

## Features

- Menu-bar app with a tray icon and settings window
- Remappable headset/media buttons, including mappings to mute, media transport, and function keys such as `F19`
- Tray icon mute indicators:
  - live microphone icon when unmuted
  - crossed-out red mute indicator when muted
- Spoken mic-state announcements:
  - configurable muted phrase
  - configurable live phrase
  - configurable announcement volume
  - optional custom sound files for mute and unmute
- Muted-speech reminder:
  - when enabled, OnBlast can replay the muted reminder if speech is detected while the microphone is muted
  - this reminder is intended to fire once per mute cycle
- Optional bundled virtual microphone backend:
  - included for devices where hardware mute prevents post-mute speech detection
  - proxies a selected physical microphone into a virtual microphone device for apps such as Teams to use
  - allows OnBlast to keep monitoring the real microphone path while apps receive muted or live audio through the virtual device

## Installation

If you just want to install the app, use the prebuilt release zip from GitHub Releases instead of building from source.

### 1. Build the app

```bash
./scripts/build_app.sh
```

That creates:

```text
.dist/OnBlast.app
```

### 2. Launch the app

```bash
open .dist/OnBlast.app
```

### 3. Grant permissions as needed

Depending on the route your headset exposes on your Mac, the app may need:

- Microphone
- Bluetooth
- Input Monitoring
- Accessibility

Accessibility is optional for some setups. For example, the Bose Bluetooth voice-command path can work without it, but other keyboards, remotes, or headset routes may still need the system-defined event tap.

### 4. Configure mappings

In `Settings`:

- choose the action for `Voice Command / Center Button`
- optionally remap volume, track, play/pause, mute, and other buttons
- configure spoken announcements and optional custom sound files
- enable muted-speech reminders if you want a reminder when you talk while muted

## Optional Virtual Microphone Driver

Some devices hard-mute the microphone in hardware. In those cases, macOS may expose silence after mute, which means muted-speech recognition cannot work from user space.

For those devices, OnBlast includes an optional bundled virtual microphone driver and `Virtual Mic Proxy` backend.

How it works:

- OnBlast captures the selected physical microphone
- OnBlast feeds that audio into `OnBlast Virtual Microphone`
- apps use the virtual microphone instead of the physical device directly
- when muted, the virtual microphone outputs silence to apps while OnBlast can still observe the physical microphone for muted-speech reminders

To install and use it:

1. Build and open `OnBlast.app`
2. Open `Settings > General > Microphone Backend`
3. Change `Mute strategy` to `Virtual Mic Proxy`
4. Click `Install Virtual Mic Driver` or `Reinstall Virtual Mic Driver`
5. Enter the administrator password when prompted
6. Choose the source microphone in `Proxy input mic`
7. In your calling app, select `OnBlast Virtual Microphone` as the input device

Reinstall the virtual mic driver after driver-side updates so Core Audio picks up the latest bundled build.

## Releases

Prebuilt app bundles should be distributed through GitHub Releases as versioned zip assets, for example:

- `OnBlast-1.0.0-macOS.zip`

The repository includes:

- `VERSION` for tracked release versioning
- `scripts/sync_version.sh` to stamp bundle versions
- `scripts/package_release.sh` to build a distributable zip that includes `OnBlast.app` and installation instructions
- `.github/workflows/release.yml` to publish release assets when a `v*` tag is pushed

The install guide included with release archives is also in [docs/INSTALL.md](/Users/gieseking/Repos/OnBlast/docs/INSTALL.md).

## Notes

- The public event tap can intercept standard media keys and may catch some headset paths.
- The HID monitor is filtered toward Bose devices and can attempt exclusive capture when a matching device is discovered.
- The private `MediaRemote` bridge is intentionally isolated and labeled experimental. It is not App Store safe.
- Some non-center headset buttons may only be observable through best-effort downstream routes on macOS, depending on how the device exposes AVRCP and HFP events.
