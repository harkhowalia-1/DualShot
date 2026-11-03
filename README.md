<p align="center"><img src="docs/img/icon.png" width="128" alt="DualShot icon"></p>

<h1 align="center">DualShot</h1>
<p align="center"><b>Record yourself and the world around you, on the iPhone you already have.</b></p>
<p align="center"><a href="https://github.com/harkhowalia-1/DualShot/releases/latest/download/DualShot-unsigned.ipa"><b>⬇︎ Download unsigned IPA</b></a> · <a href="https://harkhowalia-1.github.io/DualShot/">Website</a> · Version 1.0 is in App Store review ($2.99)</p>

---

Apple's **Dual Capture**, which records the front and back cameras at once, only exists on the iPhone 17 lineup (iPhone 17, iPhone Air, iPhone 17 Pro and Pro Max). But every iPhone with an A12 chip or newer, from **iPhone XS and XR** on, has been able to run two cameras at once since iOS 13.

DualShot uses that ability, so you get dual-camera video and photos on the iPhone you already own.

<p align="center">
  <img src="docs/img/store/1-mountain.jpg" width="250" alt="Record yourself and the world around you">
  <img src="docs/img/store/3-tokyo.jpg" width="250" alt="Two cameras, two separate files">
  <img src="docs/img/store/4-beach.jpg" width="250" alt="Picture in picture or split screen">
</p>
<p align="center">
  <img src="docs/img/store/2-concert.jpg" width="250" alt="Works on the iPhone you already have">
  <img src="docs/img/store/5-birthday.jpg" width="250" alt="Both sides of every moment">
  <img src="docs/img/store/6-festival.jpg" width="250" alt="Made for long takes">
</p>

## Features

- **Two cameras, two files.** The back and front cameras are saved as separate videos, ready to edit, plus a combined video in your layout (choose in Export Options).
- **Picture in picture or split.** Drag the front window to any corner, or split the screen.
- **Photo mode.** Take a photo with both cameras at once, in HEIF or JPEG, with flash and a self-timer.
- **Zoom while recording.** Change zoom mid-take across every back lens your iPhone has (up to 3× on Pro models). On Pros that can't run all three lenses next to the front camera, a Back Lenses control picks the pair; iPhones with one or two back lenses never see it.
- **Heat-Up Settings.** Lowers the frame rate as the iPhone warms up, so long takes keep going.
- **Matched to your iPhone.** On first launch it measures what your iPhone can do, and offers only the resolutions and frame rates that will work, up to 4K.
- **Feels like the Camera app.** Controls are laid out the way iOS 27's Camera arranges them, including a customisable top row.

## Requirements

- iPhone XS, XS Max, XR or newer (A12 chip or later), iOS 17 or later
- Tested on iPhone 14 Pro. Reports from other models are welcome in [Issues](https://github.com/harkhowalia-1/DualShot/issues).
- iPad support is planned.

## Install

1. Download [DualShot-unsigned.ipa](https://github.com/harkhowalia-1/DualShot/releases/latest/download/DualShot-unsigned.ipa) from the [latest release](https://github.com/harkhowalia-1/DualShot/releases/latest).
2. Install it with a sideloading tool that signs it with your Apple ID, such as [AltStore](https://altstore.io) or [Sideloadly](https://sideloadly.io).
3. On the iPhone, allow it in Settings › General › VPN & Device Management.

With a free Apple ID, sideloaded apps need re-signing every 7 days.

## Build it yourself

1. Install [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
2. Create `Config/Local.xcconfig` with your Apple team ID:
   ```
   DEVELOPMENT_TEAM = YOURTEAMID
   ```
3. Generate the project and open it:
   ```
   xcodegen generate
   open DualShot.xcodeproj
   ```
4. Run it on an iPhone. The Simulator has no cameras, but you can preview the interface with the launch argument `-DualShotDemo pip` (add `-DemoBack <image> -DemoFront <image>` to show real photos).

## App Store screenshots

`AppStore/make-screenshots.swift` turns the app screens in `AppStore/AppScreens` into the App Store images in `AppStore/Screenshots-6.3in` and `-6.9in`.

`BLUEPRINT.md` explains how the capture engine works.

---

iPhone and iPad are trademarks of Apple Inc. DualShot is not affiliated with or endorsed by Apple.
