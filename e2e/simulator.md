# Try Halo in the iOS Simulator (demo video as the camera)

The Simulator has no camera. In Simulator builds only, the Live Lens can play a local video file
through the real pipeline (detect, track, embed, match, labels) instead. Device builds can't do
this: the demo camera is compiled out (`#if targetEnvironment(simulator)` in
`AppDependencies.liveCamera`), and they never read `HALO_DEMO_VIDEO`.

Privacy: the video and photos are your own local files. The app reads the video in place and never
copies it into its store. Never commit clips, photos or the face model (the repo is public).

## Prerequisites

- Xcode with an iOS Simulator runtime, plus `brew install xcodegen`.
- The face model: `./scripts/fetch-models.sh` (without it the lens shows "Recognition unavailable"
  and nothing is labeled).

## 1. Record a clip and pick photos

- Record a short clip (10–30 s) of yourself, or of friends **who agreed to it**, with Photo Booth or
  QuickTime (File > New Movie Recording). Face the camera, move a little, good light. A portrait
  iPhone clip works too: its rotation is applied.
- Pick 5–10 photos of the same people (different days and angles), so the Photos scan has faces to
  cluster.
- Keep them outside the repo, in `~/Movies/halo-demo/`. Avoid the privacy-protected Mac folders
  (Desktop, Documents, Downloads, iCloud Drive): macOS may not let the Simulator read files there,
  and the lens then shows "The demo video ... could not be read" or "Demo video not found".

## 2. Run the script

```sh
./scripts/sim-run.sh --grant ~/Movies/halo-demo/clip.mov ~/Movies/halo-demo/photos/*.jpg
```

It generates the Xcode project, builds unsigned for the Simulator (derived data in
`.build/sim-derived`), boots an iPhone simulator (`HALO_SIM_DEVICE="iPhone 17"` to choose one),
enrolls Face ID, adds the photos to the Simulator's library, installs and launches the app with
`HALO_DEMO_VIDEO` set. `--grant` pre-grants Photos, Contacts, Camera and Microphone access.

If Simulator.app is not installed with your Xcode, the script says so: watch the simulator from
Xcode (open `App/Halo.xcodeproj`, pick the booted iPhone) or take screenshots:

```sh
xcrun simctl io booted screenshot halo.png
```

## 3. Walk through the app

1. **Unlock.** The app asks for Face ID first. Send a match:
   `xcrun simctl spawn booted notifyutil -p com.apple.BiometricKit_Sim.pearl.match`
   (or Simulator menu Features > Face ID > Matching Face).
2. **Onboard.** Continue through the welcome screens and allow Photos (and Contacts if you like).
3. **Scan Photos.** Let the on-device scan finish over the photos you added.
4. **Confirm.** In People > "Who is this?", confirm the cluster of the person in the clip and name
   them. Only confirmed people are ever recognized.
5. **Lens.** Open the Lens tab. The clip plays (looped) as the camera; within a second or two the
   hologram label locks onto the confirmed person's face. Unknown faces get a ring and no name.
   The speedometer button shows pipeline fps and latencies.
6. **Kill switch / background.** Backgrounding the app or erasing everything stops the demo video
   exactly like the real camera.

Without a video (`./scripts/sim-run.sh` with no arguments) the lens shows: "Simulator has no
camera. Run scripts/sim-run.sh <video> to play a demo video." A path that doesn't exist or isn't a
playable video shows that error in the lens instead.

## What the Simulator cannot test

- The real camera: capture session, preview rotation, interruptions. Use a device
  (`e2e/lens-geometry.md`).
- The 30 fps frame budget: the Simulator runs on the Mac's CPU/GPU, not the iPhone's Neural Engine,
  so its timings say nothing about device performance.
- Whisper's audio route (Bluetooth headphones, the private-output check).
- Foundation Models availability (memory hooks): depends on the Mac and the Simulator runtime.
- Real Face ID: the Simulator only fakes match / no-match.
