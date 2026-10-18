# 许可证迁移方案

[中文](./LICENSE-MIGRATION.md) · [English](./LICENSE-MIGRATION.en.md)

> 现状：[LICENSE](../LICENSE) 是自定义的「非商业学习与研究许可」，GitHub 识别为 `Other / NOASSERTION`。
> 本文只做方案对比与操作清单，不构成法律意见。

## 为什么值得改

当前许可证的正文明确写着「It is not an open-source license」，并且只允许分享**未修改**的副本。直接后果：

- 别人 fork 后提 PR，法律上处于灰色地带——你能收 PR，但贡献者没有分发修改版的明确许可。
- F-Droid / IzzyOnDroid 要求自由许可证，收不了。
- 多数 awesome 列表要求开源项目，很难通过。
- 学校、社团、公司不敢在课堂或内部流程里用。
- GitHub 的许可证筛选器无法把你归类，少一个被发现的人口。

好消息：`git log --format='%an <%ae>' | sort -u` 显示目前只有你一个版权人，迁移成本最低。**一旦有外部代码贡献，再迁移就需要逐个征求同意。**

## 三个选项

| | 维持现状 | PolyForm Noncommercial 1.0.0 | AGPL-3.0 |
|---|---|---|---|
| OSI 认证开源 | 否 | 否 | 是 |
| GitHub 可识别 | 否（Other） | 是 | 是 |
| 能收代码 PR | 灰色 | 可以 | 可以 |
| F-Droid / IzzyOnDroid | 否 | 否 | 可以 |
| 多数 awesome 列表 | 很难 | 很难 | 可以 |
| 阻止闭源商用 | 是 | 是 | 是（含 SaaS，但要求开源） |
| 阻止「拿去参赛」 | 是 | 否 | 否 |
| 社区信任度 | 低 | 中 | 高 |

关键取舍：**AGPL 不能禁止别人用你的代码参赛或做竞品，只能要求他们开源。** 如果你最在意「别被拿去比赛、别被商用」，就只能牺牲 awesome、F-Droid 和大部分代码合作者。二者不可兼得。

折中做法：**代码用 AGPL-3.0，品牌（名称、图标、社交预览图）保留商标权**，README 写明「比赛或商业使用请先联系」。商标能阻止别人冒名发布，但管不住代码本身的使用。

## 迁移步骤（以 AGPL-3.0 为例）

1. **确认版权人**：`git log --format='%an <%ae>' | sort -u`。目前只有 `duanbaiyang25@mails.ucas.ac.cn`。
2. **放入官方全文**：从 <https://www.gnu.org/licenses/agpl-3.0.txt> 获取 `LICENSE`，不要手改正文。
3. **加 `NOTICE`**：分别写明代码许可、品牌不授权、第三方数据（Hipparcos / Gaia DR3）各自的许可与署名要求。
4. **同步门面**：README / README.en.md 的许可证徽章与「许可」段落、`pubspec.yaml` 的 `version` 说明、Release notes。
5. **CHANGELOG 记一条**：`license: migrate to AGPL-3.0 from vX.Y.Z`。
6. **已发布版本不追溯**：旧 tag 和 APK 仍按旧许可分发，新版本起生效。
7. **贡献授权**：`CONTRIBUTING.md` 已加入「贡献可按当前或未来许可证分发」的条款，避免下次迁移再卡住。
8. **可选双许可**：AGPL + 商业授权，给需要闭源集成的公司留一条付费路径。
9. **检查依赖与数据**：Flutter/Dart 依赖多为 BSD/MIT，兼容；星表与深空目录可能自带署名或共享要求，代码许可覆盖不了数据，需在 `NOTICE` 里单列。

## 建议

- 想要社区、贡献者、awesome、F-Droid → **AGPL-3.0**。
- 只想小范围分享、不接受别人改完再发布 → 维持现状，但把预期降到「测试者 + 翻译 + 样片」，不要指望代码合作者。
- 无论选哪个，都在 README 里用一句话说清楚，别让用户猜。

## 如果想保留「非商业」但让条款更清楚

`PolyForm Noncommercial 1.0.0` 是 SPDX 可识别的标准文本，比自拟条款更容易被机构接受；但它仍然不是开源许可证，F-Droid 和多数 awesome 列表依旧不收。适合「明确不想让别人商用，但希望条款可读、可被 GitHub 识别」的场景。
