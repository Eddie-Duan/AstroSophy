# Good first issues

[中文](./GOOD-FIRST-ISSUES.md) · [English](./GOOD-FIRST-ISSUES.en.md)

Candidate tasks for first-time contributors. Each one states where to change things and what counts as done.

To claim one: comment "I'd like to work on this" on the issue and a maintainer will assign it to you. If no issue exists yet, open one first and follow the scope below. If you get stuck, ask in the issue — don't struggle alone.

Maintainers can turn each title below into an issue labelled `good first issue`.

---

## 1. Add a language

- **Where**: copy `lib/l10n/app_en.arb` to `lib/l10n/app_<code>.arb`; run `python tools/build_strings.py` to regenerate `lib/strings_map.dart`
- **Done when**: `flutter test test/strings_test.dart` passes; untranslated keys fall back to Chinese rather than placeholders; the PR says whether you can maintain the language
- **Effort**: low · about half a day
- **Note**: translate values only; never change keys (the keys are the Chinese source text)

## 2. Complete English common names for deep-sky objects

- **Where**: `lib/deepsky_names.dart`, tests in `test/deepsky_names_test.dart`
- **Done when**: common M / NGC / IC objects have English common names; new entries are covered by tests; style matches the Chinese names
- **Effort**: low · research involved

## 3. Add accessibility labels to the result page and list

- **Current state**: only `lib/main.dart` and `lib/onboarding.dart` use `Semantics`; TalkBack cannot read star number, class or coordinates
- **Where**: `lib/main.dart`, `lib/widgets.dart`
- **Done when**: TalkBack reads something like "number 3, bright star, Lyra, Vega"; no visual change; one widget test added
- **Effort**: low–medium

## 4. Export the observation report as PDF

- **Where**: `lib/export.dart`, `lib/report.dart`
- **Done when**: PDF is offered in the share sheet; Chinese text renders correctly; annotated image and measurement table included; tested
- **Effort**: medium

## 5. Edge cases for label placement

- **Where**: `test/label_placer_test.dart`
- **Done when**: at least 5 extreme scenarios added (dense star fields, labels beyond image bounds, duplicate labels for one target, overlap after zoom, very long object names), and the problems they expose are fixed
- **Effort**: low–medium

## 6. Device compatibility matrix

- **Where**: new `docs/DEVICES.md`, collecting data with the "Bug report" form
- **Done when**: install, solve and export results recorded on at least 5 devices / Android versions; failing models and symptoms noted
- **Effort**: low · no code required

## 7. Reproducible catalogue build documentation

- **Where**: `tools/build_catalog.py`, `tools/fetch_gaia.py`, `docs/TECHNICAL.md`
- **Done when**: the catalogue can be rebuilt from scratch by following the docs; sources, commands, runtime, output size and checksums recorded
- **Effort**: medium

## 8. Lunar phase names: English mapping and localisation

- **Where**: `lib/moon.dart`, `lib/l10n/app_en.arb`
- **Done when**: phase names go through the lookup table instead of being hard-coded; English names follow common astronomical usage (Waxing Gibbous, etc.); tests added
- **Effort**: low

## 9. Share the observation record as an image

- **Current state**: only the annotated image can be exported; the report itself cannot be shared
- **Where**: `lib/export.dart`, `lib/report.dart`
- **Done when**: a portrait long-image is produced (what you captured + measurement table + annotated thumbnail) and passed to the system share sheet
- **Effort**: medium

## 10. Sample-photo regression set (no code)

- **What**: submit originals through the "Sample photo" form, covering different devices, focal lengths, fields and failure cases
- **Done when**: each sample has device, field, capture time and local-solve result; publishable ones go into `test/` fixtures, private ones stay in the issue
- **Effort**: low · high value for the project

## 11. Translate the core technical chapters into English

- **Where**: `docs/TECHNICAL.md` (46 KB; no need to do it all at once)
- **Done when**: the "本机天区解算", "隐私与联网" and "代码结构" sections are translated into `docs/TECHNICAL.en.md`; the two versions link to each other
- **Effort**: medium · some astronomy/image-processing vocabulary helps

---

## Maintainer checklist

When creating issues:

- Start titles with a verb, e.g. "Complete English common names for deep-sky objects"
- Paste the "Where / Done when / Effort" lines into the body
- Labels: `good first issue` plus a domain label (`solver`, `ui`, `i18n`, `docs`, `data`)
- Keep 5–8 open at a time and add more as they close; a long stale list signals neglect
