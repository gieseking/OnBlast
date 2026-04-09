# OnBlast

`OnBlast` is a macOS menu-bar helper for remapping headset and media-button events to actions like microphone mute, media transport controls, and extra function keys such as `F19`.

This workspace follows the plan in `/Users/gieseking/Downloads/Bose_Mac_Remapping_Plan.docx`:

- Menu-bar utility with a settings window
- Core Audio microphone mute control
- Public system-defined event interception
- Best-effort HID monitoring for Bose devices
- Experimental private `MediaRemote` bridge for deeper diagnostics

## Build

```bash
./scripts/build_app.sh
```

That creates:

```text
.dist/OnBlast.app
```

## Run

```bash
open .dist/OnBlast.app
```

## Permissions

The app may need these permissions depending on which capture route succeeds on your Mac:

- Accessibility
- Input Monitoring
- Microphone

## Notes

- The public event tap can intercept standard media keys and may catch some headset paths.
- The HID monitor is filtered toward Bose devices and can attempt exclusive capture when a matching device is discovered.
- The private `MediaRemote` bridge is intentionally isolated and labeled experimental. It is not App Store safe.
