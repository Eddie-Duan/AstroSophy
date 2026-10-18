# 参与贡献

[中文](./CONTRIBUTING.md) · [English](./CONTRIBUTING.en.md)

感谢你愿意帮忙。动手之前请先了解 [CODE_OF_CONDUCT.md](./CODE_OF_CONDUCT.md)。

这是维护者的第一个APP项目，经验有限：如果你觉得文档、流程或代码组织有更合适的做法，欢迎直接开 issue 指出，不必客气。

## 你可以贡献什么

| 类型 | 入口 | 需要的技能 |
|---|---|---|
| 代码 | [good first issues](./docs/GOOD-FIRST-ISSUES.md) | Dart / Flutter |
| 翻译 | `lib/l10n/app_<语言>.arb` | 母语 + 一点 JSON |
| 样片 | issue 模板「样片征集」 | 会拍照就行 |
| 星表 / 星名 | `lib/deepsky_names.dart`、`tools/` | Python 或查资料 |
| 设备兼容 | issue 模板「Bug 报告」 | 一台 Android 手机 |
| 文档 | `docs/`、README | 写作 |

## 开发环境

1. 安装 Flutter stable、Android Studio、Android SDK、JDK 17/21，并让 `flutter doctor` 全绿。
2. 连接手机并开启 USB 调试，Windows 双击 [`START.bat`](./START.bat)，或运行：
   ```bash
   flutter pub get
   flutter run
   ```
3. 提交前跑测试：
   ```bash
   flutter test
   ```
4. 改过界面文字后重新生成查表：
   ```bash
   python tools/build_strings.py
   ```

## 代码地图

| 文件 | 负责什么 |
|---|---|
| `lib/pipeline.dart` | 一次分析的完整流水线 |
| `lib/analysis.dart` | 星点检测、测光、FWHM、背景 |
| `lib/solver.dart` / `lib/astrometry.dart` | 三角形指纹匹配与在线兜底 |
| `lib/catalog.dart` | 内置星表的加载与分层 |
| `lib/deepsky.dart` / `lib/deepsky_names.dart` | 深空目录与命名 |
| `lib/moving.dart` / `lib/smallbodies.dart` | 行星、小行星、彗星 |
| `lib/moon.dart` / `lib/moon_disc.dart` | 月面分析 |
| `lib/report.dart` / `lib/export.dart` | 报告与导出 |
| `lib/main.dart` / `lib/widgets.dart` / `lib/history_screen.dart` | 界面 |
| `lib/l10n/` + `tools/build_strings.py` | 多语言 |

更完整的设计说明见 [docs/TECHNICAL.md](./docs/TECHNICAL.md)。

## 提交 PR

- 一个 PR 只做一件事，不要把重构和新功能混在一起。
- 说明「为什么」，而不只是「改了什么」。
- 新行为要带测试；修 bug 最好先补一个会失败的测试。
- 跑 `flutter test`，并保证 `flutter analyze` 没有新增问题。
- 界面改动附截图。
- 维护者会尽量在 72 小时内回复。

## 加一门语言

1. 复制 `lib/l10n/app_en.arb` 为 `lib/l10n/app_<code>.arb`。
2. 只翻译 value，不要动 key（key 是中文原文）。
3. 运行 `python tools/build_strings.py` 更新 `lib/strings_map.dart`。
4. 运行 `flutter test test/strings_test.dart`。
5. 在 PR 里说明你能否长期维护这门语言。

## 提交样片

- 优先原始文件，不要用社交软件二次压缩过的版本。
- 说明设备、镜头或望远镜、焦距、拍摄时间（到分钟即可）、是否裁剪。
- 想保留隐私可以只给大致时间、去掉 GPS；不要提交含个人信息的截图。
- 提交即表示你允许项目在测试与文档中使用这张样片（PR 里会再确认）。

## 许可与贡献授权

项目当前使用[非商业学习与研究许可](./LICENSE)。**提交 PR 即表示你同意：**你的贡献按项目当前许可证分发，并允许维护者在未来把项目整体迁移到另一个许可证（例如 AGPL-3.0），你的署名会保留。

如果你不能接受这一点，欢迎只提交 issue 或样片。许可证迁移的讨论见 [docs/LICENSE-MIGRATION.md](./docs/LICENSE-MIGRATION.md)。

---

## English summary

- Read the [Code of Conduct](./CODE_OF_CONDUCT.md) first.
- Small PRs, one concern each; explain the motivation, not just the diff.
- Run `flutter test` before submitting; add tests for new behaviour.
- Regenerate `lib/strings_map.dart` with `python tools/build_strings.py` after changing UI strings.
- By submitting a PR you agree your contribution is licensed under the project's current license and may be relicensed with the project in the future.
- Sample photos, translations and device reports are welcome too.
