# OnBlast Installation

## Download

Download the latest `OnBlast-<version>-macOS.zip` asset from the repository's GitHub Releases page.

## Install

1. Unzip the release archive.
2. Move `OnBlast.app` into `/Applications` or another stable location.
3. Open `OnBlast.app`.

If macOS warns that the app is from an unidentified developer:

1. Right-click `OnBlast.app`
2. Choose `Open`
3. Confirm the prompt

This project is currently distributed as an ad-hoc signed app, not a notarized App Store build.

## Initial Permissions

Depending on which route your headset exposes on your Mac, OnBlast may ask for or require:

- Microphone
- Bluetooth
- Input Monitoring
- Accessibility

Accessibility is optional for some setups. For example, Bose Bluetooth voice-command handling can work without it, but other keyboard, remote, or headset routes may still need it.

## First-Time Setup

1. Open `Settings` from the menu-bar icon.
2. Configure your button mappings.
3. If you want voice prompts, configure spoken phrases, volume, and optional sound files in `Announcements`.

## Optional Virtual Microphone Driver

Use `Virtual Mic Proxy` only when your device hard-mutes the microphone in hardware and muted-speech detection does not work with normal device mute.

To enable it:

1. Open `Settings > General > Microphone Backend`
2. Set `Mute strategy` to `Virtual Mic Proxy`
3. Click `Install Virtual Mic Driver` or `Reinstall Virtual Mic Driver`
4. Enter the administrator password when prompted
5. Choose the physical source microphone in `Proxy input mic`
6. In your calling app, select `OnBlast Virtual Microphone` as the input device

## Updates

When installing a newer version:

1. Quit the running app
2. Replace the old `OnBlast.app` with the new one
3. Reopen the app

If the virtual microphone driver changed between releases, use `Reinstall Virtual Mic Driver` after launching the new version.
