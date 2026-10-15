"""生成仓库的社交预览图（开发期一次性素材）。

    python -I tools/make_social_preview.py

GitHub 的 Settings → Social preview 至少要 640×320，推荐 1280×640，这张图
就是按推荐尺寸出的。它只上传到仓库设置里，不进 APP 安装包，所以没有写进
pubspec.yaml 的 assets。

素材全部来自仓库里已有的品牌图：把 `astrosophy_mascot.png` 的纯色底抠掉，
合成到与 `lib/theme.dart` 同一套配色的深蓝渐变上；标题和副标题用系统自带的
Segoe UI / 微软雅黑渲染，不引入新的字体依赖。整体按 2 倍超采样绘制再缩小，
文字和小星点的边缘才干净。

换文案就改下面的 TITLE / TAGLINE 再跑一遍。星点位置由固定随机种子决定，
同一份代码每次跑出来的图完全一样。
"""

import argparse
import os
import random
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BRAND = os.path.join(ROOT, "assets", "brand")
MASCOT = os.path.join(BRAND, "astrosophy_mascot.png")
OUT = os.path.join(BRAND, "astrosophy_social_preview.png")

WIDTH, HEIGHT = 1280, 640
SUPERSAMPLE = 2

# 与 lib/theme.dart 一致：深蓝底、薄荷绿强调。
BACKDROP_TOP = (8, 14, 25)
BACKDROP_BOTTOM = (19, 30, 47)
HALO = (54, 84, 112)
MINT = (100, 217, 189)
CREAM = (233, 240, 208)
MUTED = (156, 172, 192)
FAINT = (110, 126, 146)

# 吉祥物 PNG 的纯色底，抠图时按这个颜色算透明度。
MASCOT_BACKDROP = (41, 65, 87)

# 抠图的灰度带：与底色差得比 KEY_SPAN 还远就是图形本身。
KEY_SPAN = 60.0

TITLE = "AstroSophy"
TAGLINE = "Point. Shoot. Know your sky."

SEED = 20261014


def backdrop(size):
    """竖直渐变打底，再叠一团偏蓝的光晕，给吉祥物一个落点。

    纯平色在缩略图里会显得很薄；渐变加上光晕之后，右侧那片区域自然亮起来，
    吉祥物的位置就不用再加描边或卡片去分隔。
    """
    width, height = size
    top = np.array(BACKDROP_TOP, dtype=np.float64)
    bottom = np.array(BACKDROP_BOTTOM, dtype=np.float64)
    ramp = np.linspace(0.0, 1.0, height)[:, None, None]
    canvas = np.broadcast_to(
        top * (1.0 - ramp) + bottom * ramp, (height, width, 3)
    ).copy()

    columns = np.arange(width)[None, :]
    rows = np.arange(height)[:, None]
    centre_x, centre_y = width * 0.70, height * 0.46
    distance = np.hypot(columns - centre_x, rows - centre_y) / (width * 0.40)
    falloff = np.clip(1.0 - distance, 0.0, 1.0) ** 2
    canvas += np.array(HALO, dtype=np.float64) * falloff[..., None] * 0.70

    return Image.fromarray(np.clip(canvas, 0, 255).astype(np.uint8), "RGB")


def starfield(size, seed):
    """撒一层随机星点。

    只画点、不做模糊：整体缩小的时候超采样已经会把点磨圆，再模糊只会让暗星
    糊成一团灰雾。
    """
    width, height = size
    layer = Image.new("RGBA", size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    rng = random.Random(seed)
    tones = ((255, 255, 255), (224, 238, 255), (242, 246, 216))
    for _ in range(300):
        x = rng.uniform(0, width)
        y = rng.uniform(0, height)
        radius = rng.uniform(0.5, 1.7) * SUPERSAMPLE
        alpha = int(rng.triangular(22, 165, 55))
        draw.ellipse(
            (x - radius, y - radius, x + radius, y + radius),
            fill=rng.choice(tones) + (alpha,),
        )
    return layer


def cutout(path, backdrop_color, span=KEY_SPAN):
    """把吉祥物从纯色底上抠下来。

    底是一整块纯色，所以每个像素只要看它和底色的最大通道差：差得远是图形，
    差得近是底。中间那段算成半透明，再按这个透明度把混进去的底色减掉——
    不减的话边缘会留一圈深色的描边，放到深蓝背景上特别明显。
    """
    pixels = np.asarray(Image.open(path).convert("RGB"), dtype=np.float64)
    backdrop_array = np.array(backdrop_color, dtype=np.float64)
    difference = np.abs(pixels - backdrop_array).max(axis=2)
    alpha = np.clip(difference / span, 0.0, 1.0)

    safe = np.maximum(alpha, 1e-6)[..., None]
    straight = np.clip((pixels - (1.0 - safe) * backdrop_array) / safe, 0, 255)

    rgba = np.concatenate([straight, (alpha * 255.0)[..., None]], axis=2)
    return Image.fromarray(rgba.astype(np.uint8), "RGBA")


def font(path, size):
    return ImageFont.truetype(path, size)


def draw_text(draw, xy, text, face, fill):
    draw.text(xy, text, font=face, fill=fill)


def compose(mascot_path, seed):
    size = (WIDTH * SUPERSAMPLE, HEIGHT * SUPERSAMPLE)
    canvas = backdrop(size).convert("RGBA")

    halo = Image.new("RGBA", size, (0, 0, 0, 0))
    ImageDraw.Draw(halo).ellipse(
        (
            WIDTH * SUPERSAMPLE * 0.62,
            HEIGHT * SUPERSAMPLE * 0.06,
            WIDTH * SUPERSAMPLE * 1.02,
            HEIGHT * SUPERSAMPLE * 0.94,
        ),
        fill=MINT + (30,),
    )
    # 椭圆的边要化开：留一圈能看出形状的硬边，比不加光晕更显得像贴上去的。
    halo = halo.filter(ImageFilter.GaussianBlur(70 * SUPERSAMPLE))
    canvas = Image.alpha_composite(canvas, halo)
    canvas = Image.alpha_composite(canvas, starfield(size, seed))

    mascot = cutout(mascot_path, MASCOT_BACKDROP)
    height = 420 * SUPERSAMPLE
    mascot = mascot.resize((height, height), Image.LANCZOS)
    canvas.alpha_composite(
        mascot,
        (
            int(WIDTH * SUPERSAMPLE * 0.63),
            int((HEIGHT * SUPERSAMPLE - height) / 2),
        ),
    )

    draw = ImageDraw.Draw(canvas)
    windows = os.environ.get("WINDIR", r"C:\Windows")
    latin_bold = font(os.path.join(windows, "Fonts", "segoeuib.ttf"), 82 * SUPERSAMPLE)
    han_bold = font(os.path.join(windows, "Fonts", "msyhbd.ttc"), 32 * SUPERSAMPLE)

    left = 84 * SUPERSAMPLE
    draw.rectangle(
        (left, 224 * SUPERSAMPLE, left + 96 * SUPERSAMPLE, 229 * SUPERSAMPLE),
        fill=MINT,
    )
    draw_text(draw, (left, 250 * SUPERSAMPLE), TITLE, latin_bold, MINT)
    draw_text(draw, (left, 370 * SUPERSAMPLE), TAGLINE, han_bold, CREAM)

    return canvas.convert("RGB").resize((WIDTH, HEIGHT), Image.LANCZOS)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mascot", default=MASCOT, help="吉祥物 PNG 路径")
    parser.add_argument("--out", default=OUT, help="输出 PNG 路径")
    parser.add_argument("--seed", type=int, default=SEED, help="星点随机种子")
    args = parser.parse_args()

    preview = compose(args.mascot, args.seed)
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    preview.save(args.out, optimize=True)
    print("写入 %s（%d×%d，%d 字节）" % (
        args.out,
        preview.width,
        preview.height,
        os.path.getsize(args.out),
    ))
    return 0


if __name__ == "__main__":
    sys.exit(main())
