"""生成解析方式/拍摄场景的选项背景图（开发期一次性素材）。

用法：python tools/make_mode_art.py [--force]
令牌从 .env.recraft 读取，不写进仓库。生成 1024×1024 的 JPEG，再压到卡片尺寸。
已有的图默认跳过；加 --force 才全部重画。
"""

import io
import json
import os
import sys
import urllib.error
import urllib.request

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "assets", "ui")
API = "https://external.api.recraft.ai/v1/images/generations"
SIZE = 1024

PALETTE = (
    "deep navy #0B1626 background filling the canvas, mint green #64D9BD, "
    "pale aqua #A7E8DA, warm amber #F0B96B, soft white #E8F1F5"
)
NO_TEXT = (
    "absolutely no text, no letters, no numbers, no words, no UI labels, "
    "no watermark, no logo, no border"
)
NEGATIVE = (
    "text, letters, numbers, words, typography, labels, watermark, signature, "
    "logo, border, frame, photograph, realistic photo, white background, "
    "bright background"
)

ART = {
    "analysis_local": (
        "flat vector illustration, a smartphone with a plain glowing screen "
        "showing only a few dots and constellation lines, a small shield icon "
        "beside it, a few four-pointed stars, offline and private, "
        + PALETTE + ", centered, " + NO_TEXT
    ),
    "analysis_online": (
        "flat vector illustration, a smartphone sending a thin light beam up to a "
        "small cloud with a satellite dish, stars in the background, plain screen, "
        + PALETTE + ", centered, " + NO_TEXT
    ),
    "analysis_local_first": (
        "flat vector illustration, a smartphone in front with a small cloud behind it, "
        "a short arrow from phone to cloud, stars, plain screen, "
        + PALETTE + ", centered, " + NO_TEXT
    ),
    "analysis_online_first": (
        "flat vector illustration, a small cloud with a satellite dish in front, a "
        "smartphone behind it, a short arrow from cloud to phone, stars, plain screen, "
        + PALETTE + ", centered, " + NO_TEXT
    ),
    "scene_auto": (
        "flat vector illustration, a compass rose merged with a small constellation, "
        "a phone tilted at the sky, neutral and automatic, "
        + PALETTE + ", centered, " + NO_TEXT
    ),
    "scene_wide": (
        "flat vector illustration, ultra-wide fisheye night-sky panorama, a strongly "
        "curved horizon near the bottom, the Milky Way arch wrapping around the frame, "
        "several constellation patterns and bright stars, tiny landscape and a small "
        "phone silhouette, exaggerated wide-angle distortion at the edges, "
        + PALETTE + ", centered, " + NO_TEXT
    ),
    "scene_medium": (
        "flat digital illustration, very wide-field astrophotography view: a tiny "
        "blue Iris Nebula only about one fifth of the frame width, alone in the "
        "center of a vast dark star field, hundreds of small stars spread across "
        "the whole frame, lots of empty black sky around the small nebula, "
        "medium-field context, " + PALETTE + ", centered, " + NO_TEXT
    ),
    "scene_long": (
        "flat vector illustration, narrow-field telescope close-up: the Ring "
        "Nebula fills almost the entire frame, huge ring-shaped planetary "
        "nebula with a bright central star, only three or four faint stars at the "
        "edges, no wide star field, high magnification, black sky, "
        + PALETTE + ", centered, " + NO_TEXT
    ),
    "scene_trails": (
        "flat vector illustration, long-exposure star trails: hundreds of "
        "concentric circular light arcs around a still centre in the night sky, "
        "a dark landscape and a small tripod silhouette below, motion blur arcs "
        "in teal, amber and pale white, no star points, "
        + PALETTE + ", centered, " + NO_TEXT
    ),
    "scene_moon": (
        "flat vector illustration, a large detailed full moon with silver lit crescent "
        "and warm yellow earthshine, two brown craters, a small telescope silhouette "
        "at the lower edge, deep navy night sky, "
        + PALETTE + ", centered, " + NO_TEXT
    ),
    "scene_sun": (
        "flat vector illustration, a large orange solar disc with a few tiny dark "
        "sunspots, a safe solar filter in front of a small telescope silhouette, "
        "deep navy sky, warm amber highlights, astronomy observation, "
        + PALETTE + ", centered, " + NO_TEXT
    ),
}


def token():
    path = os.path.join(ROOT, ".env.recraft")
    with io.open(path, encoding="utf-8") as handle:
        for line in handle:
            if line.startswith("RECRAFT_API_TOKEN="):
                value = line.split("=", 1)[1].strip()
                if value:
                    return value
    raise SystemExit("没有在 .env.recraft 里找到 RECRAFT_API_TOKEN")


def generate(name, prompt, key):
    payload = {
        "prompt": prompt,
        "style": "digital_illustration",
        "model": "recraftv3",
        "size": f"{SIZE}x{SIZE}",
        "n": 1,
        "response_format": "url",
        "negative_prompt": NEGATIVE,
    }
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
            data = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", "replace")
        raise SystemExit("Recraft HTTP %d for %s: %s" % (error.code, name, detail[:500]))
    url = data["data"][0]["url"]
    with urllib.request.urlopen(url, timeout=180) as response:
        raw = response.read()
    image = Image.open(io.BytesIO(raw)).convert("RGB")
    image = image.resize((SIZE, SIZE), Image.LANCZOS)
    path = os.path.join(OUT, name + ".jpg")
    image.save(path, "JPEG", quality=86, optimize=True)
    print("%-24s %8d bytes" % (name, os.path.getsize(path)))


def main():
    os.makedirs(OUT, exist_ok=True)
    key = token()
    for name, prompt in ART.items():
        path = os.path.join(OUT, name + ".jpg")
        if os.path.exists(path) and '--force' not in sys.argv:
            continue
        generate(name, prompt, key)


if __name__ == "__main__":
    main()
