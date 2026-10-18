# Contributing

[中文](./CONTRIBUTING.md) · [English](./CONTRIBUTING.en.md)

Thanks for helping. Please read the [Code of Conduct](./CODE_OF_CONDUCT.en.md) first.

This is the maintainer's first APP project. Experience is limited: if you see a better way to organise the docs, the workflow or the code, please open an issue and say so — no need to be polite about it.

## What you can contribute

| Type | Entry point | Skills |
|---|---|---|
| Code | [good first issues](./docs/GOOD-FIRST-ISSUES.en.md) | Dart / Flutter |
| Translation | `lib/l10n/app_<language>.arb` | Native speaker + a little JSON |
| Sample photos | Issue form "Sample photo" | Just take photos |
| Catalogues / names | `lib/deepsky_names.dart`, `tools/` | Python or research |
| Device compatibility | Issue form "Bug report" | One Android phone |
| Documentation | `docs/`, README | Writing |

## Development setup

1. Install Flutter stable, Android Studio, the Android SDK and JDK 17/21, and make `flutter doctor` all green.
2. Connect a phone with USB debugging enabled, then double-click [`START.bat`](./START.bat) on Windows, or run:
   ```bash
   flutter pub get
   flutter run
   ```
3. Run the tests before submitting:
   ```bash
   flutter test
   ```
4. After changing UI strings, regenerate the lookup table:
   ```bash
   python tools/build_strings.py
   ```

## Code map

| File | Responsibility |
|---|---|
| `lib/pipeline.dart` | The full analysis pipeline |
| `lib/analysis.dart` | Star detection, photometry, FWHM, background |
| `lib/solver.dart` / `lib/astrometry.dart` | Triangle-fingerprint matching and online fallback |
| `lib/catalog.dart` | Loading and tiering the bundled catalogue |
| `lib/deepsky.dart` / `lib/deepsky_names.dart` | Deep-sky catalogue and naming |
| `lib/moving.dart` / `lib/smallbodies.dart` | Planets, asteroids, comets |
| `lib/moon.dart` / `lib/moon_disc.dart` | Lunar analysis |
| `lib/report.dart` / `lib/export.dart` | Report and export |
| `lib/main.dart` / `lib/widgets.dart` / `lib/history_screen.dart` | UI |
| `lib/l10n/` + `tools/build_strings.py` | Localisation |

For a fuller design description see [docs/TECHNICAL.md](./docs/TECHNICAL.md) (Chinese).

## Submitting a PR

- One concern per PR; do not mix refactors with new features.
- Explain **why**, not just what changed.
- New behaviour needs tests; for a bug fix, add a failing test first when you can.
- Run `flutter test` and keep `flutter analyze` free of new findings.
- UI changes need a screenshot.
- Maintainers aim to reply within 72 hours; your first PR will get guidance.

## Adding a language

1. Copy `lib/l10n/app_en.arb` to `lib/l10n/app_<code>.arb`.
2. Translate values only — never change the keys (the keys are the Chinese source text).
3. Run `python tools/build_strings.py` to regenerate `lib/strings_map.dart`.
4. Run `flutter test test/strings_test.dart`.
5. Say in the PR whether you can maintain this language long-term.

## Submitting sample photos

- Prefer the original file; avoid versions recompressed by social apps.
- State the device, lens or telescope, focal length, capture time (to the minute is fine) and whether it was cropped.
- To protect privacy you can round the time and strip GPS; do not upload screenshots containing personal information.
- Submitting a sample means you allow the project to use it in tests and documentation (confirmed again in the PR).

## License and contribution grant

The project currently uses a [non-commercial learning and research license](./LICENSE). **By submitting a PR you agree that:** your contribution is distributed under the project's current license, and the maintainer may relicense the project as a whole in the future (for example to AGPL-3.0), with your attribution preserved.

If you cannot accept this, you are still welcome to file issues or submit sample photos. The relicensing discussion is in [docs/LICENSE-MIGRATION.en.md](./docs/LICENSE-MIGRATION.en.md).

---

## 中文摘要

本项目以中文为主，完整的中文贡献指南见 [CONTRIBUTING.md](./CONTRIBUTING.md)。要点：先读行为准则；一个 PR 只做一件事；提交前跑 `flutter test`；改界面文字后跑 `python tools/build_strings.py`；提交 PR 即同意贡献按项目当前许可证分发，并允许未来整体迁移许可证。
