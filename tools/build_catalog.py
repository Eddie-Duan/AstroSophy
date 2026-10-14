#!/usr/bin/env python3
"""生成 APP 内置的亮星目录、星座数据和星座网格。

数据来源全部是可再分发的公开星表（通过 CDS VizieR 取数）：

* ``I/239/hip_main``  Hipparcos 主表（ESA 1997）：位置与 V 星等。
* ``V/50/catalog``    Bright Star Catalogue 5th ed.（Hoffleit & Warren 1991）：
  Bayer/Flamsteed 名称、B-V 色指数、光谱型。
* ``VI/42/data``      Constellation boundaries（Roman 1987）：用于判断
  一颗星属于哪个星座。

星座连线不是抄任何星图的现成画法，而是对每个星座最亮的若干成员跑一次
最小生成树（按角距加权）自动生成，所以只依赖上面这些公开星表，没有引入
第三方星图数据的授权问题。

用法::

    python -I tools/build_catalog.py --out assets/catalog --mag-limit 7.5

脚本是幂等的：重复运行会覆盖输出目录下的同名文件。
"""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import sys
import urllib.parse
import urllib.request

VIZIER = "https://vizier.cds.unistra.fr/viz-bin/asu-tsv"
USER_AGENT = "AstroSophy-catalog-builder/1.0 (+https://github.com/Eddie-Duan/Astrosophy)"

# BSC 的位置是上世纪测的，而 Hipparcos 是 1991.25 历元；对高自行星（南门二
# 一年走 3.7″）两者能差到一分多钟。90″ 足以覆盖，再靠星等一致做二次筛。
MATCH_TOLERANCE_DEG = 90.0 / 3600.0

# 88 个星座的中英文名。缩写用 IAU 三字母标准。
CONSTELLATION_NAMES: dict[str, tuple[str, str]] = {
    "And": ("仙女座", "Andromeda"),
    "Ant": ("唧筒座", "Antlia"),
    "Aps": ("天燕座", "Apus"),
    "Aqr": ("宝瓶座", "Aquarius"),
    "Aql": ("天鹰座", "Aquila"),
    "Ara": ("天坛座", "Ara"),
    "Ari": ("白羊座", "Aries"),
    "Aur": ("御夫座", "Auriga"),
    "Boo": ("牧夫座", "Boötes"),
    "Cae": ("雕具座", "Caelum"),
    "Cam": ("鹿豹座", "Camelopardalis"),
    "Cnc": ("巨蟹座", "Cancer"),
    "CVn": ("猎犬座", "Canes Venatici"),
    "CMa": ("大犬座", "Canis Major"),
    "CMi": ("小犬座", "Canis Minor"),
    "Cap": ("摩羯座", "Capricornus"),
    "Car": ("船底座", "Carina"),
    "Cas": ("仙后座", "Cassiopeia"),
    "Cen": ("半人马座", "Centaurus"),
    "Cep": ("仙王座", "Cepheus"),
    "Cet": ("鲸鱼座", "Cetus"),
    "Cha": ("蝘蜓座", "Chamaeleon"),
    "Cir": ("圆规座", "Circinus"),
    "Col": ("天鸽座", "Columba"),
    "Com": ("后发座", "Coma Berenices"),
    "CrA": ("南冕座", "Corona Australis"),
    "CrB": ("北冕座", "Corona Borealis"),
    "Crv": ("乌鸦座", "Corvus"),
    "Crt": ("巨爵座", "Crater"),
    "Cru": ("南十字座", "Crux"),
    "Cyg": ("天鹅座", "Cygnus"),
    "Del": ("海豚座", "Delphinus"),
    "Dor": ("剑鱼座", "Dorado"),
    "Dra": ("天龙座", "Draco"),
    "Equ": ("小马座", "Equuleus"),
    "Eri": ("波江座", "Eridanus"),
    "For": ("天炉座", "Fornax"),
    "Gem": ("双子座", "Gemini"),
    "Gru": ("天鹤座", "Grus"),
    "Her": ("武仙座", "Hercules"),
    "Hor": ("时钟座", "Horologium"),
    "Hya": ("长蛇座", "Hydra"),
    "Hyi": ("水蛇座", "Hydrus"),
    "Ind": ("印第安座", "Indus"),
    "Lac": ("蝎虎座", "Lacerta"),
    "Leo": ("狮子座", "Leo"),
    "LMi": ("小狮座", "Leo Minor"),
    "Lep": ("天兔座", "Lepus"),
    "Lib": ("天秤座", "Libra"),
    "Lup": ("豺狼座", "Lupus"),
    "Lyn": ("天猫座", "Lynx"),
    "Lyr": ("天琴座", "Lyra"),
    "Men": ("山案座", "Mensa"),
    "Mic": ("显微镜座", "Microscopium"),
    "Mon": ("麒麟座", "Monoceros"),
    "Mus": ("苍蝇座", "Musca"),
    "Nor": ("矩尺座", "Norma"),
    "Oct": ("南极座", "Octans"),
    "Oph": ("蛇夫座", "Ophiuchus"),
    "Ori": ("猎户座", "Orion"),
    "Pav": ("孔雀座", "Pavo"),
    "Peg": ("飞马座", "Pegasus"),
    "Per": ("英仙座", "Perseus"),
    "Phe": ("凤凰座", "Phoenix"),
    "Pic": ("绘架座", "Pictor"),
    "Psc": ("双鱼座", "Pisces"),
    "PsA": ("南鱼座", "Piscis Austrinus"),
    "Pup": ("船尾座", "Puppis"),
    "Pyx": ("罗盘座", "Pyxis"),
    "Ret": ("网罟座", "Reticulum"),
    "Sge": ("天箭座", "Sagitta"),
    "Sgr": ("人马座", "Sagittarius"),
    "Sco": ("天蝎座", "Scorpius"),
    "Scl": ("玉夫座", "Sculptor"),
    "Sct": ("盾牌座", "Scutum"),
    "Ser": ("巨蛇座", "Serpens"),
    "Sex": ("六分仪座", "Sextans"),
    "Tau": ("金牛座", "Taurus"),
    "Tel": ("望远镜座", "Telescopium"),
    "Tri": ("三角座", "Triangulum"),
    "TrA": ("南三角座", "Triangulum Australe"),
    "Tuc": ("杜鹃座", "Tucana"),
    "UMa": ("大熊座", "Ursa Major"),
    "UMi": ("小熊座", "Ursa Minor"),
    "Vel": ("船帆座", "Vela"),
    "Vir": ("室女座", "Virgo"),
    "Vol": ("飞鱼座", "Volans"),
    "Vul": ("狐狸座", "Vulpecula"),
}

# BSC 名称字段里的三字母希腊字母缩写。
GREEK = {
    "Alp": "α", "Bet": "β", "Gam": "γ", "Del": "δ", "Eps": "ε", "Zet": "ζ",
    "Eta": "η", "The": "θ", "Iot": "ι", "Kap": "κ", "Lam": "λ", "Mu": "μ",
    "Nu": "ν", "Xi": "ξ", "Omi": "ο", "Pi": "π", "Rho": "ρ", "Sig": "σ",
    "Tau": "τ", "Ups": "υ", "Phi": "φ", "Chi": "χ", "Psi": "ψ", "Ome": "ω",
}

# 最常被爱好者提起的亮星：拜耳编号 -> (英文正式名, 中文名)。
# 用「希腊字母 + 星座」做键而不是 HIP 编号，是因为编号一旦记错就会把名字
# 贴到另一颗星上，而拜耳编号在 BSC 里是明确唯一的。没有收录的星在界面上
# 退回显示拜耳编号（例如「ν Ori」）。
PROPER_STAR_NAMES = {
    "α CMa": ("Sirius", "天狼星"),
    "α Car": ("Canopus", "老人星"),
    "α Cen": ("Rigil Kentaurus", "南门二"),
    "α Boo": ("Arcturus", "大角星"),
    "α Lyr": ("Vega", "织女星"),
    "α Aur": ("Capella", "五车二"),
    "β Ori": ("Rigel", "参宿七"),
    "α CMi": ("Procyon", "南河三"),
    "α Eri": ("Achernar", "水委一"),
    "α Ori": ("Betelgeuse", "参宿四"),
    "β Cen": ("Hadar", "马腹一"),
    "α Aql": ("Altair", "河鼓二"),
    "α Cru": ("Acrux", "十字架二"),
    "α Tau": ("Aldebaran", "毕宿五"),
    "α Sco": ("Antares", "心宿二"),
    "α Vir": ("Spica", "角宿一"),
    "β Gem": ("Pollux", "北河三"),
    "α PsA": ("Fomalhaut", "北落师门"),
    "α Cyg": ("Deneb", "天津四"),
    "β Cru": ("Mimosa", "十字架三"),
    "α Leo": ("Regulus", "轩辕十四"),
    "ε CMa": ("Adhara", "弧矢七"),
    "α Gem": ("Castor", "北河二"),
    "γ Cru": ("Gacrux", "十字架一"),
    "λ Sco": ("Shaula", "尾宿八"),
    "γ Ori": ("Bellatrix", "参宿五"),
    "β Tau": ("Elnath", "五车五"),
    "β Car": ("Miaplacidus", "南船五"),
    "ε Ori": ("Alnilam", "参宿二"),
    "α Gru": ("Alnair", "鹤一"),
    "ε UMa": ("Alioth", "北斗五"),
    "ζ Ori": ("Alnitak", "参宿一"),
    "α UMa": ("Dubhe", "北斗一"),
    "α Per": ("Mirfak", "天船三"),
    "δ CMa": ("Wezen", "弧矢一"),
    "θ Sco": ("Sargas", "尾宿五"),
    "ε Sgr": ("Kaus Australis", "箕宿三"),
    "ε Car": ("Avior", "海石一"),
    "η UMa": ("Alkaid", "北斗七"),
    "β Aur": ("Menkalinan", "五车三"),
    "α TrA": ("Atria", "三角形三"),
    "γ Gem": ("Alhena", "井宿三"),
    "α Pav": ("Peacock", "孔雀十一"),
    "β CMa": ("Mirzam", "军市一"),
    "α UMi": ("Polaris", "北极星"),
    "α Hya": ("Alphard", "星宿一"),
    "α Ari": ("Hamal", "娄宿三"),
    "β Cet": ("Diphda", "土司空"),
    "σ Sgr": ("Nunki", "斗宿四"),
    "θ Cen": ("Menkent", "库楼三"),
    "α And": ("Alpheratz", "壁宿二"),
    "κ Ori": ("Saiph", "参宿六"),
    "β UMi": ("Kochab", "北极二"),
    "β Leo": ("Denebola", "五帝座一"),
    "β Per": ("Algol", "大陵五"),
    "ζ UMa": ("Mizar", "开阳"),
    "80 UMa": ("Alcor", "辅"),
    "η Tau": ("Alcyone", "昴宿六"),
    "β UMa": ("Merak", "北斗二"),
    "γ UMa": ("Phecda", "北斗三"),
    "δ UMa": ("Megrez", "北斗四"),
    "ε Vir": ("Vindemiatrix", "东次将"),
    "λ Vel": ("Suhail", "天记"),
    "α Oph": ("Rasalhague", "候"),
    "α CrB": ("Alphecca", "贯索四"),
    "δ Ori": ("Mintaka", "参宿三"),
    "γ Cyg": ("Sadr", "天津一"),
    "γ And": ("Almach", "天大将军一"),
    "β Cyg": ("Albireo", "辇道增七"),
    "ε Boo": ("Izar", "梗河一"),
    "α Ser": ("Unukalhai", "蜀"),
    "α Lib": ("Zubenelgenubi", "氐宿一"),
    "β Lib": ("Zubeneschamali", "氐宿四"),
    "α Her": ("Rasalgethi", "帝座"),
    "β Peg": ("Scheat", "室宿二"),
    "α Peg": ("Markab", "室宿一"),
    "ε Peg": ("Enif", "危宿三"),
    "γ Peg": ("Algenib", "壁宿一"),
    "γ Dra": ("Eltanin", "天棓四"),
    "ζ Cet": ("Baten Kaitos", "天仓五"),
    "γ Vel": ("Regor", "天社一"),
    "θ Eri": ("Acamar", "天园六"),
    "γ Eri": ("Zaurak", "天苑四"),
    "α Tri": ("Mothallah", "娄宿一"),
    "β Cas": ("Caph", "王良一"),
    "α Cas": ("Schedar", "王良四"),
    "δ Cas": ("Ruchbah", "阁道三"),
    "η Cas": ("Achird", "王良三"),
    "γ Aql": ("Tarazed", "河鼓三"),
    "β Aql": ("Alshain", "河鼓一"),
    "δ Gem": ("Wasat", "天樽二"),
    "ζ Gem": ("Alzirr", "井宿一"),
    "ε Gem": ("Mebsuta", "井宿五"),
    "μ Gem": ("Tejat", "井宿四"),
    "η Gem": ("Propus", "钺"),
    "α Lep": ("Arneb", "厕二"),
    "β Lep": ("Nihal", "厕三"),
    "γ Leo": ("Algieba", "轩辕十二"),
    "δ Leo": ("Zosma", "西上相"),
    "θ Leo": ("Chertan", "西次相"),
    "ζ Leo": ("Adhafera", "轩辕十一"),
    "β And": ("Mirach", "奎宿九"),
    "γ Cas": ("Tsih", "策"),
    "ε Cas": ("Segin", "阁道二"),
    "α Phe": ("Ankaa", "火鸟六"),
    "β Gru": ("Tiaki", "鹤二"),
    "α Tuc": ("Lang-Exster", "鸟喙一"),
    "σ Oct": ("Polaris Australis", "南极星"),
}

def fetch(source: str, columns: str | None = None) -> str:
    """从 VizieR 取一张表的 TSV。

    必须显式带 ``-out.max=unlimited``：服务端默认只返回 50000 行，
    而 Hipparcos 主表有 118218 行，截断后 HIP 号大的那半个天区会整片丢失。
    """
    params = {"-source": source, "-out.max": "unlimited"}
    if columns:
        params["-out"] = columns
    url = f"{VIZIER}?{urllib.parse.urlencode(params)}"
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=180) as response:
        return response.read().decode("utf-8", errors="replace")


def parse_tsv(text: str) -> list[dict[str, str]]:
    """把 VizieR 的 asu-tsv 输出解析成字典列表。

    表头之前有一堆 ``#`` 注释，随后是列名行、单位行和一行短横线分隔符；
    数据从分隔符之后开始。
    """
    lines = text.splitlines()
    header_index = None
    for index in range(len(lines) - 1, -1, -1):
        stripped = lines[index].strip()
        if stripped and set(stripped) <= {"-", "\t", " "} and "-" in stripped:
            header_index = index
            break
    if header_index is None:
        raise RuntimeError("没有找到 VizieR TSV 的数据分隔行")
    names = [name.strip() for name in lines[header_index - 2].split("\t")]
    rows: list[dict[str, str]] = []
    for line in lines[header_index + 1:]:
        if not line.strip():
            continue
        values = [value.strip() for value in line.split("\t")]
        if len(values) < len(names):
            values += [""] * (len(names) - len(values))
        rows.append(dict(zip(names, values)))
    return rows


def parse_ra(text: str) -> float | None:
    """解析 ``00 05 09.9`` 形式的赤经，返回度。"""
    parts = text.replace(":", " ").split()
    if len(parts) < 2:
        return None
    try:
        hours = float(parts[0])
        minutes = float(parts[1])
        seconds = float(parts[2]) if len(parts) > 2 else 0.0
    except ValueError:
        return None
    return (hours + minutes / 60 + seconds / 3600) * 15.0


def parse_dec(text: str) -> float | None:
    """解析 ``+45 13 45`` 形式的赤纬，返回度。"""
    stripped = text.strip()
    if not stripped:
        return None
    sign = -1.0 if stripped[0] == "-" else 1.0
    parts = stripped.lstrip("+-").replace(":", " ").split()
    try:
        degrees = float(parts[0])
        minutes = float(parts[1]) if len(parts) > 1 else 0.0
        seconds = float(parts[2]) if len(parts) > 2 else 0.0
    except (ValueError, IndexError):
        return None
    return sign * (degrees + minutes / 60 + seconds / 3600)


def parse_number(text: str) -> float | None:
    try:
        value = float(text)
    except (TypeError, ValueError):
        return None
    return value


def precess_j2000_to_b1875(ra_deg: float, dec_deg: float) -> tuple[float, float]:
    """把 J2000 坐标岁动到 B1875 —— 星座边界表使用的历元。

    采用 IAU 1976 岁动角公式（和 astropy 的星座判定实现一致）。
    """
    t = (1875.0 - 2000.0) / 100.0
    zeta = (2306.2181 * t + 0.30188 * t * t + 0.017998 * t ** 3) / 3600.0
    z = (2306.2181 * t + 1.09468 * t * t + 0.018203 * t ** 3) / 3600.0
    theta = (2004.3109 * t - 0.42665 * t * t - 0.041833 * t ** 3) / 3600.0

    ra = math.radians(ra_deg)
    dec = math.radians(dec_deg)
    a = math.cos(dec) * math.sin(ra + math.radians(zeta))
    b = math.cos(math.radians(theta)) * math.cos(dec) * math.cos(ra + math.radians(zeta)) \
        - math.sin(math.radians(theta)) * math.sin(dec)
    c = math.sin(math.radians(theta)) * math.cos(dec) * math.cos(ra + math.radians(zeta)) \
        + math.cos(math.radians(theta)) * math.sin(dec)
    new_ra = (math.degrees(math.atan2(a, b)) + z) % 360.0
    new_dec = math.degrees(math.asin(max(-1.0, min(1.0, c))))
    return new_ra, new_dec


class ConstellationBoundaries:
    """Roman (1987) 星座边界表：按下标顺序扫描，最后一个命中的区域有效。"""

    def __init__(self, rows: list[dict[str, str]]):
        self.rows: list[tuple[float, float, float, str]] = []
        for row in rows:
            ra_low = parse_number(row.get("RA_low", ""))
            ra_up = parse_number(row.get("RA_up", ""))
            dec_low = parse_number(row.get("DE_low", ""))
            const = row.get("const", "").strip()
            if ra_low is None or ra_up is None or dec_low is None or not const:
                continue
            if const not in CONSTELLATION_NAMES:
                continue
            self.rows.append((ra_low, ra_up, dec_low, const))

    def lookup(self, ra_deg: float, dec_deg: float) -> str | None:
        ra_hours, dec = precess_j2000_to_b1875(ra_deg, dec_deg)
        ra_hours /= 15.0
        # 表是按赤纬上限从北往南排的，每个区域都是「半开」的长方体，
        # 相邻区域互相重叠。所以必须取**第一个**命中的行：南极那块
        # （DE_low = -90 且 RA 覆盖 0–24h）会和所有点重叠，放最后是兜底。
        for ra_low, ra_up, dec_low, const in self.rows:
            if ra_low <= ra_hours < ra_up and dec >= dec_low:
                return const
        return None


def angular_distance_deg(ra1: float, dec1: float, ra2: float, dec2: float) -> float:
    ra1r, dec1r, ra2r, dec2r = map(math.radians, (ra1, dec1, ra2, dec2))
    delta_ra = ra1r - ra2r
    cos_sep = math.sin(dec1r) * math.sin(dec2r) + \
        math.cos(dec1r) * math.cos(dec2r) * math.cos(delta_ra)
    return math.degrees(math.acos(max(-1.0, min(1.0, cos_sep))))


def _cell(ra_deg: float, dec_deg: float) -> tuple[int, int]:
    """1° × 1° 天区分桶的键；对 RA 取模，让 359° 和 0° 能互相做邻居。"""
    return (int(math.floor(ra_deg)) % 360, int(math.floor(dec_deg + 90)))


def unit_vector(ra_deg: float, dec_deg: float) -> tuple[float, float, float]:
    ra, dec = math.radians(ra_deg), math.radians(dec_deg)
    return (math.cos(dec) * math.cos(ra), math.cos(dec) * math.sin(ra), math.sin(dec))


def chord_distance(
    first: tuple[float, float, float], second: tuple[float, float, float]
) -> float:
    return math.dist(first, second)


def minimum_spanning_edges(
    nodes: list[tuple[int, tuple[float, float, float]]]
) -> list[tuple[int, int]]:
    """Prim 算法；节点是 (hip, 单位向量)，返回按角距最小的连通边。"""
    if len(nodes) < 2:
        return []
    in_tree = {0}
    edges: list[tuple[int, int]] = []
    while len(in_tree) < len(nodes):
        best: tuple[float, int, int] | None = None
        for i in in_tree:
            for j in range(len(nodes)):
                if j in in_tree:
                    continue
                distance = chord_distance(nodes[i][1], nodes[j][1])
                if best is None or distance < best[0]:
                    best = (distance, i, j)
        if best is None:
            break
        _, i, j = best
        in_tree.add(j)
        edges.append((nodes[i][0], nodes[j][0]))
    return edges


SUPERSCRIPT = {"1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵"}


def format_designation(bsc_name: str) -> tuple[str, str] | None:
    """把 BSC 的 ``21Alp And`` 拆成 ``('α', 'And')``、``33    Psc`` 拆成 ``('33', 'Psc')``。

    返回的是 (不含星座的编号, BSC 自己标注的星座缩写)。星座归属最终以
    Roman 边界表为准，这里的缩写只在边界表查不到时兜底。

    BSC 的 Name 字段长度固定，星座缩写总在最后三位，前面可能紧跟数字
    （Flamsteed 编号）或希腊字母缩写 + 上标数字。
    """
    if not bsc_name:
        return None
    compact = re.sub(r"\s+", "", bsc_name)
    if len(compact) < 3:
        return None
    body, constellation = compact[:-3], compact[-3:]
    if not body:
        return None
    match = re.fullmatch(r"(\d*)([A-Za-z]{3})(\d?)", body)
    if match:
        flamsteed, greek, suffix = match.groups()
        if greek in GREEK:
            # 上标数字区分同一拜耳字母下的多颗星，例如 α¹ α²。
            # 同时有拜耳字母和 Flamsteed 编号时只用拜耳字母：
            # 「α CMa」是通行叫法，「9 α CMa」在星图上根本不存在。
            return GREEK[greek] + SUPERSCRIPT.get(suffix, suffix), constellation
        if flamsteed:
            return flamsteed, constellation
    return body, constellation


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", default="assets/catalog", help="输出目录")
    parser.add_argument("--mag-limit", type=float, default=7.5, help="保留的极限 V 星等")
    parser.add_argument("--line-mag-limit", type=float, default=4.6,
                        help="参与生成星座连线的极限星等")
    parser.add_argument("--max-line-stars", type=int, default=12,
                        help="每个星座参与连线的最大星数")
    parser.add_argument("--cache", default="tools/.cache", help="原始星表缓存目录")
    args = parser.parse_args()

    # Windows 控制台默认是 GBK，拜耳编号里的上标（α²）会让 print 抛
    # UnicodeEncodeError。日志本来就是给人看的，编不出来就替换掉。
    for stream in (sys.stdout, sys.stderr):
        reconfigure = getattr(stream, "reconfigure", None)
        if reconfigure is not None:
            reconfigure(errors="replace")

    os.makedirs(args.out, exist_ok=True)
    os.makedirs(args.cache, exist_ok=True)

    def cached_fetch(name: str, source: str, columns: str | None = None) -> list[dict[str, str]]:
        path = os.path.join(args.cache, f"{name}.tsv")
        if os.path.exists(path):
            with open(path, encoding="utf-8") as handle:
                text = handle.read()
        else:
            print(f"下载 {source} …", file=sys.stderr)
            text = fetch(source, columns=columns)
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(text)
        return parse_tsv(text)

    # ---- 1. 取三张表 -----------------------------------------------------
    bsc_rows = cached_fetch(
        "bsc", "V/50/catalog", "HR,Name,RAJ2000,DEJ2000,Vmag,B-V,SpType"
    )
    hip_rows = cached_fetch(
        "hip", "I/239/hip_main", "HIP,RAICRS,DEICRS,Vmag"
    )
    boundary_rows = cached_fetch("boundaries", "VI/42/data")
    boundaries = ConstellationBoundaries(boundary_rows)
    print(f"BSC {len(bsc_rows)} 行，Hipparcos {len(hip_rows)} 行，边界 {len(boundaries.rows)} 行",
          file=sys.stderr)

    # ---- 2. BSC 按位置交叉匹配到 Hipparcos --------------------------------
    bsc_entries: list[tuple[float, float, dict[str, str]]] = []
    for row in bsc_rows:
        ra = parse_ra(row.get("RAJ2000", ""))
        dec = parse_dec(row.get("DEJ2000", ""))
        if ra is None or dec is None:
            continue
        bsc_entries.append((ra, dec, row))

    # 用 1 度的天区分桶，避免 9000 × 120000 的暴力匹配。
    buckets: dict[tuple[int, int], list[int]] = {}
    for index, (ra, dec, _) in enumerate(bsc_entries):
        buckets.setdefault(_cell(ra, dec), []).append(index)

    hip_stars: list[dict[str, object]] = []
    for row in hip_rows:
        hip = parse_number(row.get("HIP", ""))
        ra = parse_number(row.get("RAICRS", ""))
        dec = parse_number(row.get("DEICRS", ""))
        vmag = parse_number(row.get("Vmag", ""))
        if hip is None or ra is None or dec is None or vmag is None:
            continue
        if vmag > args.mag_limit:
            continue
        hip_stars.append({"hip": int(hip), "ra": ra, "dec": dec, "vmag": vmag})

    matched = 0
    widest = 0.0
    for star in hip_stars:
        ra = float(star["ra"])
        dec = float(star["dec"])
        vmag = float(star["vmag"])
        best: tuple[float, dict[str, str]] | None = None
        for dra in (-1, 0, 1):
            for ddec in (-1, 0, 1):
                for index in buckets.get(_cell(ra + dra, dec + ddec), []):
                    other_ra, other_dec, row = bsc_entries[index]
                    separation = angular_distance_deg(ra, dec, other_ra, other_dec)
                    if separation >= MATCH_TOLERANCE_DEG:
                        continue
                    # 星等也要对得上：两星表都收到 V≈6.5，如果差 0.8 等以上
                    # 那多半是空间上凑巧靠近的两颗不同星，宁可不给名字。
                    other_vmag = parse_number(row.get("Vmag", ""))
                    if other_vmag is not None and abs(other_vmag - vmag) > 0.8:
                        continue
                    if best is None or separation < best[0]:
                        best = (separation, row)
        if best is not None:
            row = best[1]
            widest = max(widest, best[0])
            designation = format_designation(row.get("Name", ""))
            if designation is not None:
                star["designation"], star["bscConst"] = designation
            bv = parse_number(row.get("B-V", ""))
            if bv is not None:
                star["bv"] = bv
            spectral = row.get("SpType", "").replace(" ", "")
            if spectral:
                star["spType"] = spectral[:12]
            matched += 1
    print(f"位置交叉匹配到 BSC 的恒星数：{matched}（最大偏差 {widest * 3600:.0f}″）",
          file=sys.stderr)

    # ---- 3. 判定每颗星属于哪个星座 ----------------------------------------
    for star in hip_stars:
        constellation = boundaries.lookup(float(star["ra"]), float(star["dec"]))
        if constellation is None:
            constellation = star.pop("bscConst", None)
        star.pop("bscConst", None)
        if constellation:
            star["const"] = constellation
        # 编号要和最终采用的星座缩写拼在一起，否则会出现「α 猎户座里的
        # 名字却写着 Ori 以外星座」这种自相矛盾。
        body = star.get("designation")
        if body and constellation:
            star["designation"] = f"{body} {constellation}"
        designation = star.get("designation", "")
        # 「α¹ Cen」「α² Cen」这类重复拜耳编号在表里是按字母为单位收的，
        # 查不到就去掉上标再查一次。
        proper = PROPER_STAR_NAMES.get(designation) or \
            PROPER_STAR_NAMES.get(re.sub(r"[¹²³⁴⁵]", "", designation))
        if proper:
            star["en"], star["zh"] = proper

    # ---- 4. 输出恒星表 ----------------------------------------------------
    abbreviations = sorted(CONSTELLATION_NAMES)
    constellation_index = {name: position + 1 for position, name in enumerate(abbreviations)}

    # stars.json 用「数组的数组」而不是对象：几万颗星的字段名开销要几百 KB，
    # 而每一列的次序是固定的。星座直接存下标（1 起，0 表示查不到），
    # 这样运行时不必再查网格，边界附近的星也不会因为 1° 网格而归属错误。
    stars_sorted = sorted(hip_stars, key=lambda item: float(item["vmag"]))
    stars_payload = [
        [
            int(star["hip"]),
            round(float(star["ra"]), 5),
            round(float(star["dec"]), 5),
            round(float(star["vmag"]), 2),
            constellation_index.get(str(star.get("const")), 0),
        ]
        for star in stars_sorted
    ]
    write_json(os.path.join(args.out, "stars.json"), stars_payload)

    # names.json 只收录「有名字可说」的星，绝大多数暗星不出现在这里。
    names_payload = {}
    for star in stars_sorted:
        entry: dict[str, object] = {}
        if "designation" in star:
            entry["bayer"] = star["designation"]
        if "en" in star:
            entry["en"] = star["en"]
        if "zh" in star:
            entry["zh"] = star["zh"]
        if "bv" in star:
            entry["bv"] = round(float(star["bv"]), 3)
        if "spType" in star:
            entry["sp"] = star["spType"]
        if entry:
            names_payload[str(int(star["hip"]))] = entry
    write_json(os.path.join(args.out, "names.json"), names_payload)

    # ---- 5. 星座：连线用最小生成树自动生成 --------------------------------
    by_constellation: dict[str, list[dict[str, object]]] = {}
    for star in stars_sorted:
        constellation = star.get("const")
        if constellation:
            by_constellation.setdefault(str(constellation), []).append(star)

    constellation_payload = {}
    faint: list[str] = []
    for abbreviation, (chinese, english) in sorted(CONSTELLATION_NAMES.items()):
        members = [
            star for star in by_constellation.get(abbreviation, [])
            if float(star["vmag"]) <= args.line_mag_limit
        ][: args.max_line_stars]
        if len(members) < 2:
            # 望远镜座、山案座这类整片天区没有亮星的星座，按星等截断后
            # 只剩一两颗星，画不出连线。退而取它自己最亮的几颗。
            faint.append(abbreviation)
            members = by_constellation.get(abbreviation, [])[: args.max_line_stars]
        nodes = [
            (int(star["hip"]), unit_vector(float(star["ra"]), float(star["dec"])))
            for star in members
        ]
        edges = minimum_spanning_edges(nodes)
        constellation_payload[abbreviation] = {
            "zh": chinese,
            "en": english,
            "lines": [[a, b] for a, b in edges],
        }
    write_json(os.path.join(args.out, "constellations.json"), constellation_payload)
    if faint:
        print(f"这些星座没有亮于 {args.line_mag_limit} 等的成员，连线改用各自最亮的星："
              f"{'、'.join(faint)}", file=sys.stderr)

    # ---- 6. 星座查找网格：1° × 1° 的纯二进制表，运行时 O(1) 查询 -------
    # 用于「天区中心落在哪个星座」这类没有具体恒星可依托的查询。
    grid = bytearray(181 * 360)
    for dec_index in range(181):
        dec = -90.0 + dec_index
        for ra_index in range(360):
            ra = ra_index + 0.5
            constellation = boundaries.lookup(ra, dec)
            if constellation:
                grid[dec_index * 360 + ra_index] = constellation_index[constellation]
    with open(os.path.join(args.out, "constellation_grid.bin"), "wb") as handle:
        handle.write(bytes(grid))

    write_json(
        os.path.join(args.out, "catalog_meta.json"),
        {
            "mag_limit": args.mag_limit,
            "line_mag_limit": args.line_mag_limit,
            "star_count": len(stars_payload),
            "constellation_order": abbreviations,
            "sources": [
                "I/239/hip_main (ESA 1997, Hipparcos)",
                "V/50/catalog (Hoffleit & Warren 1991, Bright Star Catalogue 5th ed.)",
                "VI/42/data (Roman 1987, constellation boundaries)",
            ],
        },
    )

    total = sum(
        os.path.getsize(os.path.join(args.out, name))
        for name in os.listdir(args.out)
    )
    print(
        f"完成：{len(stars_payload)} 颗星，{len(names_payload)} 条名称，"
        f"{len(constellation_payload)} 个星座，合计 {total / 1024:.0f} KB",
        file=sys.stderr,
    )
    unassigned = sum(1 for row in stars_payload if row[4] == 0)
    if unassigned:
        print(f"注意：{unassigned} 颗星没有查到星座归属", file=sys.stderr)
    return 0


def write_json(path: str, payload: object) -> None:
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, ensure_ascii=False, separators=(",", ":"))
    print(f"  写出 {path}（{os.path.getsize(path) / 1024:.0f} KB）", file=sys.stderr)


if __name__ == "__main__":
    raise SystemExit(main())
