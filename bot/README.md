# AstroSophy NapCat bot

`napcat` 分支上的 QQ 群 bot。核心算法在 `packages/astrosophy_core`（纯 Dart），
bot 只负责 QQ 消息、图片下载和回复。

## 当前能做什么

- 连接 NapCat 的 OneBot 11 WebSocket；
- 只在白名单群响应；
- `/ping`、`/help`；
- `/解析` + 图片：本机星点分析 + 解算，回坐标/视场/匹配数；
- `/月亮` + 图片：月面圆心、半径、亮面占比；
- `/太阳` + 图片：日面半径、暗斑数量，并提示太阳滤镜；
- `/天象 城市`：月相、太阳高度、当前可见行星；
- 单群 20 秒冷却、全局串行队列；
- 断线自动重连。

`/天象` 支持北京、上海、广州、深圳、成都、西安、南京、杭州、武汉、重庆、
天津、昆明、拉萨、乌鲁木齐、哈尔滨、三亚。

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

也可以不用配置文件：

```bash
NAPCAT_WS=ws://127.0.0.1:3001 NAPCAT_TOKEN=xxx dart run bin/bot.dart
```

## 先验证核心

不接 QQ 也能跑：

```bash
cd bot
dart run bin/cli.dart ../assets/demo/demo_m31.jpg --scene auto
```

会输出星点数、月亮/太阳检测、解算坐标和耗时。M31 在本机应能解出约 4.18° 视场。

星表默认从仓库的 `assets/catalog` 读取；部署到别处时设置：

```bash
ASTRO_ASSETS=/path/to/assets/catalog
```

## 安全

- 不要把 NapCat 的 WebSocket 端口暴露到公网；
- 不要用主 QQ 号；
- `config.json` 已加入 `.gitignore`，不要提交 token；
- 非官方协议有掉线、限制、封号风险，先在测试群跑。

## 还没做

- 标注图（目前只回文字）；
- 在线解算回退；
- 按用户的每日次数限制；
- 官方 QQ bot 迁移。

## 分支

开发分支：`napcat`。  
主分支：`main`。  
不要把 `napcat` 直接合进 `main`，等 bot MVP 验证完再决定。
