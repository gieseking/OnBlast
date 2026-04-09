# OnBlast Virtual Audio Device

This folder contains the bundled virtual microphone backend used by the menu-bar app's `Virtual Mic Proxy` mute strategy.

## Goal

The app keeps listening to a chosen physical microphone, but other apps talk to a separate virtual microphone device named `OnBlast Virtual Microphone`.

When the helper is:

- live: physical mic audio is proxied into the virtual device
- muted: the helper feeds silence into the virtual device

That design keeps speech detection available inside the helper even when headset or hardware mute paths would otherwise zero the input stream before user-space can inspect it.

## Components

1. `AudioServerPlugIn/`
   User-space Core Audio HAL plug-in installed under `/Library/Audio/Plug-Ins/HAL`.

2. `XPCService/`
   Reserved helper service scaffold for a future control plane if the shared-memory transport path needs to grow into a richer IPC layer.

3. `DriverExtension/`
   Reserved scaffold for a DriverKit path if the user-space plug-in alone is not sufficient for the final shipping device.

4. Main app integration
   The Swift app already exposes `Device Mute` versus `Virtual Mic Proxy` in Settings and allows selecting the physical source microphone for the proxy path.

## Current Status

The repo now has:

- app-side configuration for `Device Mute` versus `Virtual Mic Proxy`
- a generated Xcode project at `VirtualAudioDevice/OnBlastVirtualAudioDevice.xcodeproj`
- a buildable HAL plug-in that publishes an input-only `OnBlast Virtual Microphone` device
- a buildable XPC service stub that produces `OnBlastVirtualAudioXPC.xpc`
- a shared-memory transport that lets the app write captured mono float audio into the HAL plug-in's input ring buffer
- app-side AVFoundation capture that proxies the selected physical microphone into the virtual device when live and outputs silence when muted

The main remaining work is production hardening: end-to-end validation across more hardware, signing/notarization, and installer polish. The current transport path is implemented with a shared memory ring buffer rather than the XPC service scaffold.

## Build

Generate the project:

```sh
./scripts/generate_virtual_audio_project.sh
```

Build the stubs:

```sh
./scripts/build_virtual_audio_device.sh
```

Artifacts are written under:

- `VirtualAudioDevice/.derived/Build/Products/Debug/OnBlastVirtualAudioPlugIn.driver`
- `VirtualAudioDevice/.derived/Build/Products/Debug/OnBlastVirtualAudioXPC.xpc`

## Why This Exists

Apple's Core Audio docs note that voice activity detection works with a process mute but not with a hardware mute. For headsets that hard-mute at the device path, a virtual microphone backend is the clean way to preserve local speech detection while still presenting a muted mic to conferencing apps.

## Next Implementation Steps

1. Validate end-to-end capture and mute behavior across more physical microphones and conferencing apps.
2. Add installer/signing logic so the app can place the `.driver` bundle in `/Library/Audio/Plug-Ins/HAL` cleanly for distribution.
3. Decide whether the shared-memory transport is sufficient long-term or whether the XPC service should become the control plane.
4. Decide whether the Driver Extension path is actually needed or whether the HAL plug-in alone is enough.
