# AstroSophy NapCat bot

`napcat` 分支上的 QQ 群 bot 雏形。当前只验证 **NapCat / OneBot 11 链路**，还没有接星点分析核心。

## 当前能做什么

- 连接 NapCat 的 OneBot 11 WebSocket；
- 只在白名单群响应；
- `/ping`、`/help`；
- `/解析`、`/月亮`、`/太阳` 收到图片时回“核心尚未接入”；
- 断线自动重连。

## 运行

1. 安装并登录 NapCat（建议单独小号、测试群）。
2. 在 NapCat 里启用 WebSocket 服务，记下地址和 token。
3. 复制配置：

```bash
cd bot
cp config.example.json config.json
```

4. 编辑 `config.json`：

```json
{
  "wsUrl": "ws://127.0.0.1:3001",
  "accessToken": "你的 token",
  "botName": "AstroSophy",
  "allowedGroups": [123456789],
  "maxImageMb": 25
}
```

5. 运行：

```bash
dart pub get
dart run bin/bot.dart
```

也可以不用配置文件，直接给环境变量：

```bash
NAPCAT_WS=ws://127.0.0.1:3001 NAPCAT_TOKEN=xxx dart run bin/bot.dart
```

## 安全

- 不要把 NapCat 的 WebSocket 端口暴露到公网；
- 不要用主 QQ 号；
- `config.json` 已加入 `.gitignore`，不要提交 token；
- 非官方协议有掉线、限制、封号风险，先在测试群跑。

## 下一步

1. 把 `analysis.dart` / `solver.dart` / `catalog.dart` / `report.dart` 拆成纯 Dart core；
2. 做一个 `tools/astrosophy_cli.dart`，先证明服务端能出同样的解算结果；
3. bot 里下载群图片 → 调 core → 回文字报告；
4. 加队列、限流、临时文件清理；
5. 月亮/太阳命令复用现有分支；
6. 标注图渲染；
7. 稳定后再考虑官方 QQ bot。

## 分支

开发分支：`napcat`。  
主分支：`main`。  
不要把 `napcat` 直接合进 `main`，等 bot MVP 验证完再决定。
