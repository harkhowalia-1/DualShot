# DualShot — Blueprint

> **iPhone 17's Dual Capture, on every iPhone since XS.**
> Front and back cameras record at the same time. You get each camera as its own file plus the combined picture-in-picture video.

Name: **DualShot** (chosen 2 Nov 2026; the working name was DualShot). Several App Store apps already use "DualShot", so the store listing needs a distinct full name.

Status: v0.1 built (19 Oct 2026). It compiles for iPhone and the Simulator; real-camera testing on an iPhone 14 Pro is next.

## Scope

**In v1**
- Front + back recording at once, like iPhone 17's Dual Capture.
- **Picture-in-picture**: drag the window to any corner; tap it to swap which camera is big.
- **Split** (top/bottom); double-tap to swap.
- **Saves up to 3 videos** (*SAVE* setting):
  - **All** (default): back file + front file + combined video.
  - **Angles**: just the two camera files.
  - **Combined**: just one video, like the native app.
- Resolution and frame rate: whatever this iPhone can run with two cameras (HD / 4K; 24 / 25 / 30 / 60).
- HEVC or H.264.
- Back camera zoom (.5× / 1× / 2× / 3×) works *while recording* when the hardware allows it.
- Heat handling with a "This will run hot" prompt and a Smart / Force choice.

**Out, by decision:** ProRes, Apple Log, Cinematic mode, the all-three-back-cameras idea.

## How it works

### Capture (`Sources/Camera/CaptureGraph.swift`)
- One `AVCaptureMultiCamSession`.
- Two inputs (back, front), each wired by hand to its own `AVCaptureMovieFileOutput` and its own preview layer. Each file is written by the hardware with the least overhead, which is what lets older iPhones go higher.
- Microphones are beamformed: the back file hears the scene, the front file hears the person holding the phone. An external mic feeds both.
- Files are written in 5-second fragments. A crash or overheat loses at most the last few seconds, and leftovers are finished on the next launch.
- Constant frame rate and one shared clock keep the files in step. On iOS 18.2+ each file's exact start time is recorded, so the combined video lines them up to the frame.

### What each iPhone can do (`DualPlanner.swift`)
- **First launch:** the app measures the real hardware cost of every back camera × resolution × frame rate, using `supportedMultiCamDeviceSets`, multi-cam formats and `hardwareCost` / `systemPressureCost`. The result is cached per model and iOS version.
- **Back camera choice:** it prefers the multi-lens camera (lens switching while recording) and falls back to the plain wide camera when that's the only way to reach a resolution.
- **Front camera:** if it can't match the back's resolution, it records its own maximum and the FORMAT panel says so.
- **The FORMAT panel shows only what runs.** A 🔥 marks settings the phone can start but not sustain (`systemPressureCost > 1`). The footer shows "Runs cool / Runs hot", which lenses are available, minutes of free space, and a camera-budget bar.

### Heat (`HeatGuard.swift`)
| | Smart (default) | Force |
|---|---|---|
| Before recording a 🔥 setting, or when the phone is already hot | Prompt: *Record in HD · 30* / *Record anyway* / *Don't ask again* | No prompt |
| Serious while recording | 60 → 30 → 24 fps, one step every 45 s while it stays hot | — |
| Critical while recording | 24 fps and stop the front file (closed cleanly); the back keeps recording | Warning only |
| Idle and hot | Preview slows to 20 fps until it cools | Same |

Every step shows a yellow pill and is logged in the take's `take.json`.

### Combined video (`Sources/Media/CombinedRenderer.swift`)
- Made *after* recording from the two files (custom Core Image compositor + `AVAssetExportSession`), so all the heat budget goes to the cameras while you shoot.
- Replays every layout change you made while recording, with the same animation, rounded window and corners.
- Turns the layout to match how you held the phone (portrait or landscape).
- Sound follows the big camera, crossfading on each swap. If the front stopped early, the back takes over.
- Files are moved (not copied) into Photos, so a full iPhone doesn't need double the space. If Photos access is off, they stay in the Files app.

### Lessons from the first iPhone 14 Pro test (19 Oct)
- **Previews are fixed at portrait (90°).** The screen never rotates; asking a rotation coordinator before the view is on screen returned 0° and showed the picture sideways.
- **The app owns its audio session.** It shares audio with other apps (`mixWithOthers`) and records from the iPhone's microphones even with Bluetooth headphones on. Letting the capture session configure audio made iOS refuse the mic ('!pri') while headphones were in call mode, and every refusal stopped the cameras. That caused a 0.8 s freeze every 1.2 s.
- **If iOS still refuses the mic (a real call):** the cameras run without sound, a mic-off icon shows, and the app re-asks every 4 s and on audio route changes.
- **Live previews are UIKit views** whose layers *are* the preview layers. Swaps and moves animate with Core Animation, with no SwiftUI clipping, shadows or per-frame layout on live video.
- **Lens pairs on the 14 Pro:** the triple camera can't run next to the front camera. The zoom bar shows .5 · 1 · 2 · 3, and .5 / 3 switch between ultra wide + wide and wide + telephoto, even mid-recording (the back file restarts and is joined on save).
- **Saving (combined render, joining) waits while recording** and runs at low GPU priority.
- **Frame-rate changes don't restart anything (measured 0–8 ms).** The cameras are budgeted for the top frame rate of the current resolution (`videoMinFrameDurationOverride`), so 24 ↔ 30 ↔ 60 only retimes them. Resolution changes swap formats in place (about 1 s, behind a blur).
- **The screen never reads an `AVCaptureDevice`.** Zoom ranges, torch and recording angles come from the session queue; reading them on the main thread while the session reconfigured caused stutter.
- **A mid-take lens switch closes both files.** iOS ends every recording when an input is swapped, so the app closes both, switches (about 0.9 s on the 14 Pro), and starts both again; the new pieces start within 1 ms of each other.
  - The joined angle files close up the gap (both by the same amount, so they still match).
  - The combined video keeps real time and holds the last frame through the gap.
  - Stretching a frame inside the composition fails to export (-12780), which is why the hold is done by the compositor.
- **Debug builds write `Library/Caches/diagnostics.json`** (angles, formats, audio route, session state, missed screen frames, events), readable over USB with `devicectl device copy from`. Launch with `-SelfTest` to step through frame rates, 4K, lens pairs and an 8 s test recording (kept out of Photos, copied to `Library/Caches/LastTake`); `-ClearLastTake` deletes that copy.

## Design

SmartShot's language, copied as-is:
- Black canvas.
- Liquid Glass buttons (material fallback before iOS 26).
- Yellow accent, the FORMAT panel, the zoom bar, the yellow notice pill.
- Icons that turn with the phone.

Video additions:
- Red record button (dot → square) and the red timer.
- Thermometer chip that appears as the phone warms up.

App icon: SmartShot's construction (gradient base, yellow brackets) with a big back lens and a small front-camera window.

## Files
```
Sources/
├── App/DualShotApp.swift
├── Camera/   CaptureGraph (AVFoundation), DualCamera (screen model), DualPlanner (formats, plans), HeatGuard
├── Media/    DualLayout (geometry + timeline), CombinedRenderer, Take (files + recorder), TakeSaver (Photos)
├── Views/    CameraView, DualViewfinder, FormatPanel, HeatPrompt, Controls
├── Demo/     DemoScene (Simulator / screenshots: -DualShotDemo pip|split|recording|format|hot)
└── AppIcon.icon
```

## Next
1. **Test on the iPhone 14 Pro.**
   - First launch measures the cameras.
   - Check which modes appear, and whether .5×–3× works in HD and 4K.
   - Record 1-, 5- and 20-minute takes.
   - Check the combined video in portrait and landscape.
2. Tune the heat steps from real 14 Pro behavior.
3. Later: HDR (Dolby Vision) video, an in-app takes browser, Final Cut multicam export, Camera Control / volume-button shutter, a Lock Screen launch.
