# Videopaper

Live wallpapers for macOS — including a **scientifically accurate, ray-traced
black hole** rendered in real time on your GPU.

**Website & DMG download: [videopaper.ssh.codes](https://videopaper.ssh.codes)**

![the black hole wallpaper](https://videopaper.ssh.codes/assets/poster.jpg)

Videopaper is a SwiftUI app that turns an ambient animation or a local video
file into a desktop wallpaper across one or more monitors. macOS does not
expose a public API for setting a video as the system wallpaper asset, so
Videopaper uses desktop-level, click-through AppKit windows: motion renders
over the static wallpaper while staying behind normal app windows.

## The black hole

The headline scene (`Sources/Videopaper/Services/BlackHoleRenderer.swift`) is a
real Schwarzschild geodesic ray tracer in Metal, not a video loop:

- every pixel integrates the exact null-geodesic (Binet) equation
  `d²u/dφ² = 3u² − u` through curved spacetime with RK4 — gravitational
  lensing, the shadow, and the photon ring emerge from the math
- accretion disk with the Novikov–Thorne temperature profile, exact
  Doppler + gravitational redshift `g = √(1−3M/r) / ((1−ΩL_z)√f_cam)`,
  relativistic beaming (`I ∝ g⁴`), and Planck-spectrum colors
- disk-plane crossings found analytically per half-winding and refined with
  cubic Hermite interpolation, so higher-order photon-ring images come from
  the same integrator
- HDR (rgba16Float) render → bright pass → separable Gaussian bloom → ACES
  tonemap, driven by a `CVDisplayLink` capped at 60 fps
- fully halts (zero CPU/GPU) when the wallpaper is occluded or the screen locks

## Features

- Built-in animated scenes: Black Hole, Aurora, Stars, Sunrise, Daylight,
  Sunset, Moonlight, Prism, and Ember.
- Local video wallpaper playback with looping, speed, fit mode, audio
  mute/volume, and dimming controls.
- Multi-monitor detection with per-display enable toggles and per-monitor
  assignments — each display can use its own scene or video.
- Menu bar controls for applying, stopping, and changing the wallpaper.
- Local persistence for saved source, playback, display, and launch
  preferences.

## Build & run

```bash
./script/build_and_run.sh
```

The script builds the SwiftPM app (macOS 14+), stages `dist/Videopaper.app`,
and launches it. Or grab the prebuilt DMG from
[videopaper.ssh.codes](https://videopaper.ssh.codes).

## License

[MIT](LICENSE)
