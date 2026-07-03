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

## The relativistic scenes

Three scenes (`Sources/Videopaper/Services/BlackHoleRenderer.swift`) are real
Schwarzschild geodesic ray tracers in Metal, not video loops. The black hole:

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

The **pulsar** is an oblique-rotator neutron star with R = 4.2 GM/c^2
(compactness 0.48): the same geodesic integrator with a solid surface, so
gravitational self-lensing brings the far side into view — both magnetic polar
caps at once. A tilted corotating dipole drives hollow beam cones (the
lighthouse flash emerges from the volume integral along bent rays), aurora-like
L-shell glow, and a magnetic-thermal surface map (hot caps, cool ember belt on
the magnetic equator). The **quasar** adds volumetrics along the bent rays:
relativistic jets with per-sample Doppler boosting (beta = 0.88 — the
counter-jet nearly vanishes, like real one-sided quasar jets), a clumpy
absorbing dust torus with a disk-heated rim, an X-ray corona, and a hotter
near-Eddington disk.

## Features

- Built-in animated scenes: Black Hole, Pulsar, Quasar, Aurora, Stars,
  Sunrise, Daylight, Sunset, Moonlight, Prism, and Ember.
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
