<div align="center">

<img src="assets/brand/astrosophy_social_preview.png" alt="AstroSophy: give it a phone photo of the night sky and it works out what you captured" width="100%">

# AstroSophy

**Give it a photo of the night sky. It works out which part of the sky you captured — on the device.**

[中文](./README.md) · [English](./README.en.md)

[![Version](https://img.shields.io/github/v/tag/Eddie-Duan/AstroSophy?label=version&style=flat-square&color=e8763a)](https://github.com/Eddie-Duan/AstroSophy/releases)
[![Downloads](https://img.shields.io/github/downloads/Eddie-Duan/AstroSophy/total?label=downloads&style=flat-square&color=1f9e6e)](https://github.com/Eddie-Duan/AstroSophy/releases)
![Platform](https://img.shields.io/badge/platform-Android-3ddc84?style=flat-square&logo=android&logoColor=white)
![Flutter](https://img.shields.io/badge/Flutter-%E2%89%A53.24-02569b?style=flat-square&logo=flutter&logoColor=white)
[![CI](https://github.com/Eddie-Duan/AstroSophy/actions/workflows/flutter-ci.yml/badge.svg)](https://github.com/Eddie-Duan/AstroSophy/actions/workflows/flutter-ci.yml)
[![License](https://img.shields.io/badge/license-AGPL--3.0-blue?style=flat-square)](./LICENSE)

**Welcome PR. Welcome Issue.**

</div>

AstroSophy is an Android app for amateur astronomers, built with Flutter. Pick a photo from your phone; it detects stars, plate-solves the field, labels what is in frame, and turns the result into a readable report. **It works offline.**

<!-- Screenshots: drop real device screenshots into docs/screenshots/ and uncomment
<p align="center">
  <img src="docs/screenshots/result.png" width="24%" alt="Interactive result page">
  <img src="docs/screenshots/report.png" width="24%" alt="Observation report">
  <img src="docs/screenshots/moon.png" width="24%" alt="Lunar analysis">
  <img src="docs/screenshots/sky-map.png" width="24%" alt="All-sky map">
</p>
-->

## What it does

| You give it | It does on-device | You get |
|---|---|---|
| One phone photo of the night sky | Detect stars → match the bundled catalogue → solve centre and pixel scale | Annotated image, observation record, measurements |

- **Fully offline**: the catalogue is bundled (41,394 Hipparcos stars to V=8.0 plus 1.2M Gaia DR3 stars to G=11, about 10 MB). Solving needs no network.
- **Narrow fields too**: 1.5°–2.5° frames from smart telescopes (Seestar, Dwarf) solve on the phone.
- **Human-readable**: constellations, Chinese star names, `M 45`-style deep-sky names, planets, asteroids and comets — four target classes, four distinct markers.
- **Auditable**: aperture photometry, FWHM, background noise and saturation are all listed, and "seen" is kept separate from "computed".
- **Honest about uploads**: Astrometry.net is used only after explicit consent; the switch is off by default.

The full 19-feature list is in [docs/FEATURES.en.md](./docs/FEATURES.en.md).

## Install

- **APK**: download `AstroSophy.apk` from [Releases](https://github.com/Eddie-Duan/AstroSophy/releases/latest)
- **Build from source**: Flutter stable, Android Studio, Android SDK, JDK 17/21. Then `flutter pub get` and `flutter run`; tests run with `flutter test`.
- Sideloading requires allowing installs from unknown sources.

## Docs

Most design notes are currently written in Chinese. Translations and English summaries are welcome — see [CONTRIBUTING.md](./CONTRIBUTING.en.md).

- [Feature list](./docs/FEATURES.en.md) · [中文](./docs/FEATURES.md)
- [Technical notes](./docs/TECHNICAL.md)
- [Catalogue roadmap](./docs/SUGGESTION.md)
- [AI roadmap](./docs/AI-ROADMAP.md)

## Contributing

**PRs and issues are welcome.** Start with [good first issues](./docs/GOOD-FIRST-ISSUES.en.md), and read [CONTRIBUTING.md](./CONTRIBUTING.en.md) and [CODE_OF_CONDUCT.md](./CODE_OF_CONDUCT.en.md) first.

You do not need to write code: sample photos from Seestar / Dwarf scopes, translations and device compatibility reports are just as useful.

## About this project

This is the author's first self-developed project, and the first time building and maintaining an app end to end. There will be naive decisions in the code, the docs and the astronomy. If you know a better way, please say so — an issue, a PR, or just "this could be better" all help. The hope is to build something useful, and to get better at it together.

## License

GNU Affero General Public License v3.0 (AGPL-3.0) — see [LICENSE](./LICENSE). You may use, modify and redistribute the code; if you run a modified version as a network service, you must publish the corresponding source under the same license. The brand name and icons are not covered by this license. For commercial use, contact the author.

## Credits

Catalogue data comes from Hipparcos and Gaia DR3 (ESA). See the data-sources and acknowledgements section in [docs/TECHNICAL.md](./docs/TECHNICAL.md) (Chinese) for deep-sky catalogues, names and third-party sources.
