#!/usr/bin/env python3
"""生成 APP 内置的太阳系小天体目录（亮小行星、矮行星、彗星）。

数据来源两个公开接口：

* JPL 小行星星历服务 ``https://ssd-api.jpl.nasa.gov/sbdb.api``：逐个对象取
  轨道根数（含历元）、绝对星等 H、斜率 G、直径。**必须带 ``phys-par=1``**，
  否则响应里没有 ``phys_par``，H 拿回来是空的——根数是对的，亮度却算不出来，
  而亮度正是这条判据先要用的那一半。
* 国际小行星中心 MPC 的彗星根数表 ``/iau/MPCORB/CometEls.txt``（约 160 KB，
  全部彗星）。注意 ``/iau/Ephemerides/Comets/CometEls.txt`` 这个老路径现在
  返回 404，能取到的是 ``MPCORB`` 下面这个。

为什么只挑这些对象，而不是整份 MPCORB（140 万颗，压缩后 89 MB）：
手机照片上够得着的是「视星等 ≲ 13 等」的那一小撮，其余 140 万颗永远不可能
出现在候选里，进来只是每张图白算一遍。所以内置**全部亮小行星与矮行星**加
**全部彗星**——彗星不能挑：新的亮彗星是这条判据最值得报的东西，而它恰恰是
每年才冒出来一两个的。

亮度公式（两条都在运行时用同一套实现，见 ``lib/smallbodies.dart``）：

* 小行星与矮行星：H/G 相位律
  ``V = H + 5·log10(r·Δ) − 2.5·log10((1−G)·Φ₁(α) + G·Φ₂(α))``
* 彗星：``m = M1 + 5·log10(Δ) + 2.5·k1·log10(r)``

用法::

    python -I tools/build_smallbodies.py --out assets/catalog

脚本是幂等的：重复运行会覆盖输出文件。抓下来的原始响应缓存在 ``tools/.cache``。
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import sys
import urllib.parse
import urllib.request

SBDB = "https://ssd-api.jpl.nasa.gov/sbdb.api"
COMET_ELEMENTS = "https://www.minorplanetcenter.net/iau/MPCORB/CometEls.txt"
USER_AGENT = "AstroSophy-catalog-builder/1.0 (+https://github.com/Eddie-Duan/Astrosophy)"

# 列进来的理由是「手机可能拍得到」：17 颗亮小行星实测最亮视星等（历元当天，
# H/G 相位律）全部 ≤ 12.9 等，最亮的那几张里灶神星到 6.5 等。
ASTEROIDS: list[tuple[str, str]] = [
    ("2", "智神星"),
    ("3", "婚神星"),
    ("4", "灶神星"),
    ("6", "韶神星"),
    ("7", "虹神星"),
    ("8", "花神星"),
    ("9", "颖神星"),
    ("10", "健神星"),
    ("15", "司宁星"),
    ("16", "灵神星"),
    ("52", "欧罗巴星"),
    ("65", "休神星"),
    ("324", "班贝加星"),
    ("433", "爱神星"),
    ("511", "大卫星"),
    ("704", "际神星"),
]

DWARF_PLANETS: list[tuple[str, str]] = [
    ("1", "谷神星"),
    ("134340", "冥王星"),
    ("136199", "阅神星"),
    ("136108", "妊神星"),
    ("136472", "鸟神星"),
    # 下面这五颗是 IAU 承认的矮行星之外、被普遍当作矮行星的那一批。全都只有
    # 17–21 等，手机和小口径望远镜一颗都拍不到——收进来正是为了**说得出它们
    # 拍不到**：报告里写「共工星今天在这个位置，亮度 21 等，这个器材拍不到」，
    # 比什么都不写强得多。什么都不写，用户只会以为这个 APP 不认识它。
    ("50000", "创神星"),
    ("90377", "塞德娜"),
    ("90482", "亡神星"),
    ("225088", "共工星"),
    ("120347", "潫神星"),
]

# 彗星的中文名只给最常被提起的那几颗，其余用 MPC 的正式编号。彗星不像小行星
# 有一份稳定的中文名表——每年新发现的几十颗都还没有通用译名，硬凑一个反而
# 让人对不上号。
COMET_NAMES: dict[str, str] = {
    "1P": "哈雷彗星",
    "2P": "恩克彗星",
    "8P": "塔特尔彗星",
    "9P": "坦普尔彗星",
    "12P": "庞斯-布鲁克斯彗星",
    "21P": "贾可比尼-秦诺彗星",
    "22P": "科佩夫彗星",
    "46P": "维塔宁彗星",
    "55P": "坦普尔-塔特尔彗星",
    "62P": "紫金山彗星",
    "67P": "楚留莫夫-格拉西缅科彗星",
    "81P": "怀尔德彗星",
    "103P": "哈特雷彗星",
    "109P": "斯威夫特-塔特尔彗星",
}

# e 超过这个值的真双曲轨道需要通用变量法（Stumpff 级数）才解得动。全部 940
# 颗彗星里只有一颗（1I/'Oumuamua，e=1.1993，视星等 23 等）落在这边——为它写
# 一整套新解法不划算，所以构建时就滤掉，运行时也就不必再判。
MAX_ECCENTRICITY = 1.05


def fetch(url: str, cache_path: str, *, refresh: bool) -> str:
    if not refresh and os.path.exists(cache_path):
        with open(cache_path, encoding="utf-8") as handle:
            return handle.read()
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=180) as response:
        text = response.read().decode("utf-8", errors="replace")
    with open(cache_path, "w", encoding="utf-8") as handle:
        handle.write(text)
    return text


def sbdb_object(query: str, cache_dir: str, *, refresh: bool) -> dict:
    params = urllib.parse.urlencode(
        {"sstr": query, "phys-par": "1", "full-prec": "true"}
    )
    name = query.replace("/", "_").replace(" ", "")
    text = fetch(f"{SBDB}?{params}", os.path.join(cache_dir, f"sbdb_{name}.json"),
                 refresh=refresh)
    return json.loads(text)


def rounded(value: float | None, digits: int = 6) -> float | None:
    return None if value is None else round(value, digits)


def build_small_body(entry: dict, kind: str, chinese: str) -> dict:
    elements = {item["name"]: item["value"] for item in entry["orbit"]["elements"]}
    physical = {item.get("name"): item.get("value") for item in (entry.get("phys_par") or [])}
    magnitude = physical.get("H")
    if magnitude is None:
        raise ValueError(f"{chinese}：SBDB 没有给绝对星等 H，亮度算不出来")

    return {
        "kind": kind,
        "name": chinese,
        "designation": entry["object"].get("fullname") or "",
        # 根数历元（TT 儒略日）。运行时从它往前推平近点角，所以它必须跟着
        # 一起存——少了它，平近点角就没有起算点，位置会整体错开。
        "epoch": round(float(entry["orbit"]["epoch"]), 1),
        # 精度按「够用」取，不按「有多少位给多少位」：这条链路自己的误差都在
        # 角分量级，多留几位既换不来位置，又要让资产文件白白大一倍。
        "a": rounded(float(elements["a"]), 8),
        "e": rounded(float(elements["e"]), 8),
        "i": rounded(float(elements["i"]), 6),
        "om": rounded(float(elements["om"]), 6),
        "w": rounded(float(elements["w"]), 6),
        "ma": rounded(float(elements["ma"]), 6),
        "H": rounded(float(magnitude), 2),
        # G 缺省 0.15 是 IAU 的推荐值，SBDB 不给的时候用这个。相位角小的时候
        # G 的影响很小，而小行星冲日前后正是相位角小的时候。
        "G": rounded(float(physical["G"]), 2) if physical.get("G") else 0.15,
        "diameter_km": rounded(float(physical["diameter"]), 1) if physical.get("diameter") else None,
    }


def julian_day(moment: datetime.datetime) -> float:
    return 2440587.5 + moment.replace(tzinfo=datetime.timezone.utc).timestamp() / 86400


def build_comet(line: str) -> dict | None:
    """从 CometEls.txt 的一行里取出这颗彗星。

    这份表是**定长**的，不是空格分隔的：名字占 [102, 151)，后面 [151, ) 是
    出处（``MPC194091``），出处里也可能带逗号。之前按空格切，结果把出处并进了
    名字——``C/1947 X1-B (Southern comet)    38,  189`` 这种，用户看到的就是
    一串谁也认不出的东西。
    """
    if len(line) < 151:
        return None
    designation = line[102:151].strip()
    if not designation:
        return None
    row = line.split(None, 12)
    try:
        moment = datetime.datetime.strptime(f"{row[1]}-{row[2]}-{row[3]}", "%Y-%m-%d.%f")
        perihelion_distance = float(row[4])
        eccentricity = float(row[5])
        argument = float(row[6])
        node = float(row[7])
        inclination = float(row[8])
        magnitude = float(row[10])
        slope = float(row[11])
    except (ValueError, IndexError):
        return None

    if not (0 < perihelion_distance < 60 and 0 < eccentricity <= MAX_ECCENTRICITY):
        return None
    if not (0 < slope < 25):
        return None

    period_prefix = designation.split("/")[0].strip()
    return {
        "kind": "comet",
        "name": COMET_NAMES.get(period_prefix, designation),
        "designation": designation,
        # 过近日点时刻，按儒略日存：彗星的根数是「q、e、i、ω、Ω ＋ Tp」，
        # 没有平近点角，传播要从 Tp 反推真近点角。
        "tp": round(julian_day(moment), 4),
        "q": rounded(perihelion_distance, 8),
        "e": rounded(eccentricity, 8),
        "i": rounded(inclination, 5),
        "om": rounded(node, 5),
        "w": rounded(argument, 5),
        "M1": rounded(magnitude, 1),
        # k1 = 4.0 是 MPC 在没有实测光变曲线时填的缺省值，占全部彗星的 80%。
        # 用缺省值算出来的亮度可能差好几等，所以标出来——报告里就只写「可能
        # 够亮」，不给数字。
        "k1": rounded(slope, 1),
        "magnitude_is_default": abs(slope - 4.0) < 1e-9,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", default="assets/catalog", help="输出目录")
    parser.add_argument("--cache", default="tools/.cache", help="原始响应缓存目录")
    parser.add_argument("--refresh", action="store_true", help="忽略缓存重新下载")
    args = parser.parse_args()

    for stream in (sys.stdout, sys.stderr):
        reconfigure = getattr(stream, "reconfigure", None)
        if reconfigure is not None:
            reconfigure(errors="replace")

    os.makedirs(args.out, exist_ok=True)
    os.makedirs(args.cache, exist_ok=True)

    bodies: list[dict] = []
    for query, chinese in ASTEROIDS:
        print(f"取 {chinese}（{query}）…", file=sys.stderr)
        bodies.append(build_small_body(
            sbdb_object(query, args.cache, refresh=args.refresh), "asteroid", chinese))
    for query, chinese in DWARF_PLANETS:
        print(f"取 {chinese}（{query}）…", file=sys.stderr)
        bodies.append(build_small_body(
            sbdb_object(query, args.cache, refresh=args.refresh), "dwarf_planet", chinese))

    print("取 MPC 彗星根数表 …", file=sys.stderr)
    raw = fetch(COMET_ELEMENTS, os.path.join(args.cache, "CometEls.txt"),
                refresh=args.refresh)
    comets: list[dict] = []
    skipped = 0
    discarded = 0
    for line in raw.splitlines():
        if not line.strip():
            continue
        comet = build_comet(line)
        if comet is None:
            # 分不清「这一行本来就不该用」和「改坏了格式」是这类脚本最容易
            # 自欺的地方，所以两种都数出来：格式差得离谱的（短于定长表的宽度）
            # 单独报警。
            if len(line) < 151:
                discarded += 1
            else:
                skipped += 1
        else:
            comets.append(comet)
    print(f"  彗星 {len(comets)} 颗（偏心率/根数不合用 {skipped} 行，"
          f"格式不符 {discarded} 行）", file=sys.stderr)

    payload = {
        # 建构日期必须跟着数据走：内置表会过时，报告里要说明用的是哪一天的表。
        "built": datetime.date.today().isoformat(),
        "sources": [
            "JPL Small-Body Database (ssd-api.jpl.nasa.gov/sbdb.api, 根数与 H/G)",
            "Minor Planet Center CometEls.txt (iau/MPCORB, 彗星根数与 M1/k1)",
        ],
        "bodies": bodies,
        "comets": comets,
    }
    path = os.path.join(args.out, "smallbodies.json")
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, ensure_ascii=False, separators=(",", ":"))
    print(f"  写出 {path}（{os.path.getsize(path) / 1024:.0f} KB）", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
