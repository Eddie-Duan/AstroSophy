"""用 Recraft 生成引导页的插画（开发期一次性素材）。

    python -I tools/make_onboarding_art.py               # 全部重画
    python -I tools/make_onboarding_art.py --only local result
    python -I tools/make_onboarding_art.py --list

四页各一张，刻意用四个不同风格：吉祥物 Nox 走扁平矢量（和 APP 图标同一套画
法），后面三页分别是线稿、数字插画和色块图形。四页要是同一张图换个台词，用
户翻到第二页就知道后面还有什么，直接跳过；风格拉开才有"一页一个新东西"的
节奏。但配色收在同一套上——薄荷绿、奶油白、一点琥珀，压在深蓝底上——所以风
格不同，看起来还是一家人。

Recraft 的矢量风格返回的是 SVG，而 Flutter 不认 SVG（要渲染得再引一个
flutter_svg）。所以脚本拿到 SVG 之后会顺手用本机已有的 Chrome 或 Edge 无头
模式把它栅格化成 PNG——PNG 才是 APP 真正加载的那张，`.svg` 只留着当矢量源
稿，方便日后重新导出别的尺寸。

API 令牌放在仓库根目录的 .env.recraft（已 gitignore），运行时读取，不写进
任何产物，也不打到终端上。
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
import urllib.error
import urllib.request

from PIL import Image

API = "https://external.api.recraft.ai/v1/images/generations"

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BRAND = os.path.join(ROOT, "assets", "brand")

SIZE = 1024

# 成品落盘后的最长边。引导页里这些图最宽也就显示一百多逻辑像素，3 倍屏 540
# 像素就封顶了；留着 1024 的成品只会让安装包白白变胖——`Illustration` 那张
# 带颗粒，1024 时是 1.3 MB，压到 640 只剩零头。矢量源稿还在仓库里，真要更大
# 尺寸随时能重新导出。
TARGET_EDGE = 640

# 默认模型。矢量风格（`Vector art`、`Icon`）要配 `recraftv3_vector`，条目里
# 可以单独覆盖。
MODEL = "recraftv3"
MODEL_VECTOR = "recraftv3_vector"

# 四张图共用的配色和禁令。分开写是为了让每条的 prompt 只说自己那件事——风
# 格和主体各不相同，画法上的约束却是同一套。
#
# 配色必须点到具体色号：只写 "deep navy"、"mint green" 这类形容词，Risograph
# 和 Illustration 会各自套上自己那套色板（实测出来过宝蓝底配大片橙色，还有
# 米白底），放进深色界面就是四块抢眼的补丁。背景尤其要写死「铺满整幅」——
# 引导页本身是深色的，图上再留一圈浅色底，四页就变成四个亮方块。
PALETTE = (
    "the background is a solid deep navy #0E1A2B filling the entire canvas, "
    "the only other colours are mint green #64D9BD, pale aqua #A7E8DA, "
    "cream white #F2F7E8, and one small warm amber #F0B96B accent"
)
NO_TEXT = "no text, no letters, no numbers, no watermark, no logo"
NO_FLUFF = "no gradient, no texture, no noise"

# 负向提示是 V2/V3 模型的参数，比在正向里堆 "no ..." 管用得多。
NEGATIVE = (
    "white background, cream background, light background, pale background, "
    "bright background, blue background, text, letters, numbers, words, "
    "watermark, signature, logo, frame, border, photograph"
)

ART = (
    {
        "name": "astrosophy_mascot",
        "page": "第 1 页 · 欢迎",
        "style": "vector_illustration",
        "note": "社交预览图也用这张，改名之前先看 tools/make_social_preview.py",
        # 社交预览按 840 像素用它，所以这张不压。
        "resize": 0,
        # 这张的成品已经在仓库里了，参数原样留着，重新生成才和现在这张一致。
        "negative_prompt": "",
        "prompt": (
            "flat vector mascot: a chubby four-pointed star with two small round "
            "eyes and a tiny smile, hugging a small telescope, clean geometric "
            "shapes, mint green and pale aqua body, cream white highlights, one "
            "warm amber accent, plain deep navy background, centered, " + NO_TEXT +
            ", no outline, no gradient, no texture, no shading"
        ),
    },
    {
        "name": "astrosophy_onboarding_local",
        "page": "第 2 页 · 本机解析",
        "style": "vector_illustration",
        "prompt": (
            "flat vector illustration: a smartphone standing upright with a small "
            "star chart glowing on its screen, three tiny four-pointed stars and a "
            "thin constellation line above the phone, clean geometric shapes, "
            + PALETTE + ", centered, " + NO_TEXT + ", no outline, no gradient, "
            "no texture, no shading"
        ),
    },
    {
        "name": "astrosophy_onboarding_result",
        "page": "第 3 页 · 交互解读",
        "style": "Illustration",
        "prompt": (
            "flat 2d illustration: a hand with one finger tapping a bright "
            "four-pointed star, a thin mint circle drawn around the tapped star, "
            "a few smaller stars scattered around, " + PALETTE + ", centered, "
            + NO_TEXT + ", " + NO_FLUFF
        ),
    },
    {
        "name": "astrosophy_onboarding_keep",
        "page": "第 4 页 · 保存回看",
        "style": "Vector art",
        "model": MODEL_VECTOR,
        "prompt": (
            "flat vector illustration: an open photo album holding two small "
            "square star photos, with a warm amber bookmark ribbon across the "
            "page, " + PALETTE + ", centered, " + NO_TEXT + ", no outline, "
            "no gradient, no texture, no shading"
        ),
    },
)

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
    try:
        with urllib.request.urlopen(request, timeout=180) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as error:
        # 400 基本都是风格名或尺寸写错了。只报 "HTTP Error 400" 等于什么都没
        # 说，所以把服务方那句话原样带出来。
        detail = error.read().decode("utf-8", "replace")
        raise SystemExit("Recraft 返回 HTTP %d：%s" % (error.code, detail[:500]))


def browser():
    for path in BROWSERS:
        if os.path.exists(path):
            return path
    for name in ("chrome", "msedge"):
        found = shutil.which(name)
        if found:
            return found
    raise SystemExit("没找到 Chrome 或 Edge，无法把 SVG 转成 PNG")


def rasterize(svg_path, png_path, size):
    """用无头浏览器截一张 size×size 的图。

    SVG 自己声明了同样的尺寸，所以窗口开成一样大就正好是原分辨率，不需要再
    缩放。
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
                "--window-size=%d,%d" % (size, size),
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


def shrink(png_path, edge):
    """把成品压到 edge 见方以内，并转成调色板 PNG；edge 为 0 表示不动它。

    这些图本来就没几种颜色（深蓝底、薄荷、奶油、一点琥珀），转成 256 色调色
    板肉眼看不出差别，体积却差一个数量级——带颗粒的 `Illustration` 那张在
    RGBA 下 743 KB，转完 115 KB。四张图全算上，安装包里省下一兆多。
    """
    if not edge:
        return
    with Image.open(png_path) as source:
        image = source.convert("RGBA")
        if max(image.size) > edge:
            image = image.resize((edge, edge), Image.LANCZOS)
    image.convert("P", palette=Image.ADAPTIVE, colors=256).save(png_path, optimize=True)


def draw(spec, key):
    """把一条 spec 变成 PNG（矢量风格会先落一份 SVG 源稿）。"""
    payload = {
        "model": spec.get("model", MODEL),
        "prompt": spec["prompt"],
        "style": spec["style"],
        "size": "%dx%d" % (SIZE, SIZE),
        "n": 1,
    }
    # 负向提示留空表示这条不吃默认值（吉祥物那张要原样复现）。
    negative = spec.get("negative_prompt", NEGATIVE)
    if negative:
        payload["negative_prompt"] = negative
    payload = post(payload, key)
    items = payload.get("data") or []
    if not items:
        raise SystemExit(
            "%s：接口没有返回图片：%s" % (spec["name"], json.dumps(payload)[:300])
        )

    if "b64_json" in items[0]:
        raw = base64.b64decode(items[0]["b64_json"])
    else:
        with urllib.request.urlopen(items[0]["url"], timeout=180) as response:
            raw = response.read()

    os.makedirs(BRAND, exist_ok=True)
    png = os.path.join(BRAND, spec["name"] + ".png")
    svg = os.path.join(BRAND, spec["name"] + ".svg")

    if raw[:4] == b"<svg" or raw[:5] == b"<?xml":
        with open(svg, "wb") as handle:
            handle.write(raw)
        rasterize(svg, png, SIZE)
    else:
        with open(png, "wb") as handle:
            handle.write(raw)
        # 上一次跑留下过矢量源稿的话，现在这张已经不是矢量了，留着会误导。
        if os.path.exists(svg):
            os.remove(svg)

    shrink(png, spec.get("resize", TARGET_EDGE))
    print("  %-34s %-40s %8d 字节" % (spec["name"], spec["style"], os.path.getsize(png)))
    return png


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--only",
        nargs="+",
        metavar="NAME",
        help="只重画这几张（默认全部）",
    )
    parser.add_argument("--list", action="store_true", help="只列出现有的条目")
    parser.add_argument(
        "--resize-only",
        action="store_true",
        help="不调接口，只把已有成品重新压到目标尺寸",
    )
    args = parser.parse_args()

    if args.list:
        for spec in ART:
            print("%-34s %-30s %s" % (spec["name"], spec["style"], spec["page"]))
        return 0

    unknown = [name for name in (args.only or []) if name not in {s["name"] for s in ART}]
    if unknown:
        raise SystemExit("没有这些条目：" + "、".join(unknown))

    selected = [s for s in ART if not args.only or s["name"] in set(args.only)]

    if args.resize_only:
        # 重压不花钱，所以不必先取令牌。
        for spec in selected:
            png = os.path.join(BRAND, spec["name"] + ".png")
            if not os.path.exists(png):
                raise SystemExit("%s：还没有成品，先正常跑一遍" % spec["name"])
            shrink(png, spec.get("resize", TARGET_EDGE))
            print("  %-34s %8d 字节" % (spec["name"], os.path.getsize(png)))
        print("完成，共 %d 张。" % len(selected))
        return 0

    key = token()
    for spec in selected:
        print("%s（%s，%s）" % (spec["name"], spec["page"], spec["style"]))
        draw(spec, key)
    print("完成，共 %d 张。" % len(selected))
    return 0


if __name__ == "__main__":
    sys.exit(main())
