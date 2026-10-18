# Good first issues

[中文](./GOOD-FIRST-ISSUES.md) · [English](./GOOD-FIRST-ISSUES.en.md)

给第一次参与的人准备的候选任务。每条都写清了改哪里、做到什么程度算完成。

认领方式：在对应 issue 下留言「我想做这个」，维护者会把你 assign 上；如果还没建 issue，先开一个再按下面的范围做。卡住了就在 issue 里问，不用硬扛。

维护者可以把下面的标题直接建成 issue，并打上 `good first issue` 标签。

---

## 1. 新增一门语言

- **改哪里**：复制 `lib/l10n/app_en.arb` 为 `lib/l10n/app_<code>.arb`；运行 `python tools/build_strings.py` 生成 `lib/strings_map.dart`
- **完成标准**：`flutter test test/strings_test.dart` 通过；未翻译的 key 回退为中文原文而不是占位符；PR 里说明能否长期维护
- **难度**：低 · 约半天
- **注意**：只翻译 value，不要动 key（key 是中文原文）

## 2. 补全深空天体的英文常用名

- **改哪里**：`lib/deepsky_names.dart`，测试在 `test/deepsky_names_test.dart`
- **完成标准**：常见 M / NGC / IC 天体都有英文常用名；新增条目有测试覆盖；与中文名的写法风格一致
- **难度**：低 · 需要查资料

## 3. 给结果页和列表补无障碍标签

- **现状**：全仓库只有 `lib/main.dart` 和 `lib/onboarding.dart` 用了 `Semantics`，TalkBack 读不出星点编号、类型和坐标
- **改哪里**：`lib/main.dart`、`lib/widgets.dart`
- **完成标准**：TalkBack 能依次读出「第 3 号，亮星，天琴座 Vega」这类信息；不改变任何视觉表现；补一个 widget 测试
- **难度**：低–中

## 4. 把观测报告导出为 PDF

- **改哪里**：`lib/export.dart`、`lib/report.dart`
- **完成标准**：分享面板里能选 PDF；中文字体正常显示；包含标注图与测量表；有测试
- **难度**：中

## 5. 标注避让的边界用例

- **改哪里**：`test/label_placer_test.dart`
- **完成标准**：至少新增 5 个极端场景（密集星场、标注超出图像边界、同一目标重复标注、放大后重叠、长天体名），并修掉其中暴露的问题
- **难度**：低–中

## 6. 设备兼容性矩阵

- **改哪里**：新建 `docs/DEVICES.md`，并按「Bug 报告」模板收集信息
- **完成标准**：至少记录 5 台设备 / Android 版本上的安装、解算、导出结果；注明失败机型与现象
- **难度**：低 · 不需要写代码

## 7. 星表构建的可复现文档

- **改哪里**：`tools/build_catalog.py`、`tools/fetch_gaia.py`、`docs/TECHNICAL.md`
- **完成标准**：从零开始按文档能重建星表；记录数据源、命令、耗时、产物体积与校验和
- **难度**：中

## 8. 月相名称的中英对照与本地化

- **改哪里**：`lib/moon.dart`、`lib/l10n/app_en.arb`
- **完成标准**：相名走查表而不是硬编码；英文名称符合常见天文写法（Waxing Gibbous 等）；补测试
- **难度**：低

## 9. 分享「观星记录」为图片

- **现状**：目前只能导出带标注的原图，报告本身不能分享
- **改哪里**：`lib/export.dart`、`lib/report.dart`
- **完成标准**：生成一张竖版长图（拍到什么 + 测量表 + 标注缩略图），走系统分享面板
- **难度**：中

## 10. 样片回归集（不需要写代码）

- **做什么**：按「样片征集」模板提交原片，覆盖不同设备、焦距、视场和失败场景
- **完成标准**：每张样片带设备、视场、拍摄时间、本机解算结果；能公开的放进 `test/` fixture，不能公开的留在 issue 里
- **难度**：低 · 对项目价值很高

## 11. 把技术文档的核心章节翻成英文

- **改哪里**：`docs/TECHNICAL.md`（46 KB，不必一次翻完）
- **完成标准**：先翻「本机天区解算」「隐私与联网」「代码结构」三节，放到 `docs/TECHNICAL.en.md`；与中文版互相链接
- **难度**：中 · 需要一点天文/图像处理词汇

---

## 维护者清单

建 issue 时建议：

- 标题用动词开头，例如「补全深空天体英文常用名」
- 正文贴上面的「改哪里 / 完成标准 / 难度」
- 标签：`good first issue` + 领域标签（`solver`、`ui`、`i18n`、`docs`、`data`）
- 一次只放 5–8 个，做完再补；挂太多会显得没人管
