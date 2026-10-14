"""用 Recraft 生成引导页的吉祥物插画（开发期一次性素材）。

    python -I tools/make_mascot.py

Recraft 的 `vector_illustration` 风格返回的是 SVG，而 Flutter 不认 SVG（要渲
染得再引一个 flutter_svg）。所以脚本拿到 SVG 之后会顺手用本机已有的 Chrome
或 Edge 无头模式把它栅格化成 PNG——`assets/brand/astrosophy_mascot.png` 是
APP 真正用的那张，`.svg` 只是留着当矢量源稿，方便日后重新导出别的尺寸。

API 令牌放在仓库根目录的 .env.recraft（已 gitignore），运行时读取，不写进
任何产物，也不打到终端上。

换提示词就直接改下面的 PROMPT 再跑一遍——这个脚本只负责「把一句话变成一张
图」，不做任何后处理。分辨率固定 1024×1024：引导页那个 136×116 的框用三倍
图，够任何屏幕密度了。
"""

import argparse
import base64
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import urllib.request

API = "https://external.api.recraft.ai/v1/images/generations"

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BRAND = os.path.join(ROOT, "assets", "brand")
OUT_SVG = os.path.join(BRAND, "astrosophy_mascot.svg")
OUT_PNG = os.path.join(BRAND, "astrosophy_mascot.png")

# 和 APP 图标同一套配色和画法：扁平矢量、没有描边内的渐变和噪点，薄荷绿和
# 奶油白为主体、一点琥珀色。吉祥物就是图标里那颗星长出了眼睛——用户在图标
# 上见过它，进 APP 再见到就不用重新认识一遍。
PROMPT = (
    "flat vector mascot: a chubby four-pointed star with two small round eyes "
    "and a tiny smile, hugging a small telescope, clean geometric shapes, "
    "mint green and pale aqua body, cream white highlights, one warm amber "
    "accent, plain deep navy background, centered, no text, no letters, "
    "no outline, no gradient, no texture, no shading"
)

STYLE = "vector_illustration"
SIZE = "1024x1024"

# 无头浏览器：Chrome 和 Edge 的渲染引擎是同一个，谁在就用谁。
BROWSERS = (
    r"C:\Program Files\Google\Chrome\Application\chrome.exe",
    r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
    r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
    r"C:\Program Files\Microsoft\Edge\Application\msedge.exe",
)


def token():
    path = os.path.join(ROOT, ".env.recraft")
    with io.open(path, encoding="utf-8") as handle:
        for line in handle:
            if line.startswith("RECRAFT_API_TOKEN="):
                value = line.split("=", 1)[1].strip()
                if value:
                    return value
    raise SystemExit("没有在 .env.recraft 里找到 RECRAFT_API_TOKEN")


def post(payload, key):
    request = urllib.request.Request(
        API,
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Authorization": "Bearer " + key,
            "Content-Type": "application/json",
        },
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=180) as response:
        return json.loads(response.read().decode("utf-8"))


def browser():
    for path in BROWSERS:
        if os.path.exists(path):
            return path
    for name in ("chrome", "msedge"):
        found = shutil.which(name)
        if found:
            return found
    raise SystemExit("没找到 Chrome 或 Edge，无法把 SVG 转成 PNG")


def rasterize(svg_path, png_path):
    """用无头浏览器截一张 1024×1024 的图。

    SVG 自己声明了 1024×1024 的尺寸，所以窗口开成一样大就正好是原分辨率，
    不需要再缩放。
    """
    with tempfile.TemporaryDirectory() as scratch:
        shot = os.path.join(scratch, "shot.png")
        subprocess.run(
            [
                browser(),
                "--headless=new",
                "--disable-gpu",
                "--hide-scrollbars",
                "--force-device-scale-factor=1",
                "--window-size=1024,1024",
                "--screenshot=" + shot,
                # 让浏览器不要垫白底：SVG 之外的留白保持透明，之后要换深色
                # 背景也不用重新出图。
                "--default-background-color=00000000",
                "file:///" + svg_path.replace("\\", "/"),
            ],
            check=True,
            capture_output=True,
        )
        shutil.copyfile(shot, png_path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prompt", default=PROMPT, help="换一句话重画")
    parser.add_argument("--style", default=STYLE, help="Recraft 风格名")
    parser.add_argument("--png", default=OUT_PNG, help="PNG 输出路径")
    parser.add_argument("--svg", default=OUT_SVG, help="SVG 输出路径")
    args = parser.parse_args()

    payload = post(
        {
            "model": "recraftv3",
            "prompt": args.prompt,
            "style": args.style,
            "size": SIZE,
            "n": 1,
        },
        token(),
    )
    items = payload.get("data") or []
    if not items:
        raise SystemExit("接口没有返回图片：" + json.dumps(payload)[:300])

    if "b64_json" in items[0]:
        raw = base64.b64decode(items[0]["b64_json"])
    else:
        with urllib.request.urlopen(items[0]["url"], timeout=180) as response:
            raw = response.read()

    os.makedirs(os.path.dirname(args.png), exist_ok=True)
    if raw[:4] == b"<svg" or raw[:5] == b"<?xml":
        with open(args.svg, "wb") as handle:
            handle.write(raw)
        rasterize(args.svg, args.png)
        print("写入 %s（矢量源稿）" % args.svg)
    else:
        with open(args.png, "wb") as handle:
            handle.write(raw)
    print("写入 %s（%d 字节）" % (args.png, os.path.getsize(args.png)))


if __name__ == "__main__":
    sys.exit(main())
