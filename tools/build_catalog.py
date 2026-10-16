#!/usr/bin/env python3
"""生成 APP 内置的亮星目录、深空目录、星座数据和星座网格。

数据来源全部是可再分发的公开星表（通过 CDS VizieR 取数）：

* ``I/239/hip_main``  Hipparcos 主表（ESA 1997）：位置与 V 星等。
* ``V/50/catalog``    Bright Star Catalogue 5th ed.（Hoffleit & Warren 1991）：
  Bayer/Flamsteed 名称、B-V 色指数、光谱型。
* ``VI/42/data``      Constellation boundaries（Roman 1987）：用于判断
  一颗星属于哪个星座。
* ``VII/118/ngc2000`` NGC 2000.0（Sky Publishing, ed. Sinnott 1988）：
  NGC/IC 天体的位置、类型、角尺寸和视星等。

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

# Gaia 那一层的来源。位置是 ICRS 的 2016.0 历元，和 Hipparcos 的 J2000 差在
# 毫角秒量级，标注和解算都用不到这个精度，不另做归算。
GAIA_SOURCE = "I/355/gaiadr3"
GAIA_COLUMNS = "Source,RA_ICRS,DE_ICRS,Gmag"

# Gaia 的星等到 Hipparcos 那层就算重复。两边的位置误差都在毫角秒量级，
# 5″ 的容差足够宽到不会漏掉同一颗星，又远小于任何一片天区里的星间距。
OVERLAP_DEG = 5.0 / 3600.0

# 星等按 0.05 等一格编进一个字节，覆盖 0 ~ 12.75 等。
GAIA_MAG_SCALE = 20.0

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
    # 昴星团（M 45）其余的亮成员。七颗正星是昴宿一～昴宿七，另两颗亮的增星
    # 一并收进来——爱好者认出「这是昴星团」之后，屏幕上却只有一颗星有名字，
    # 比一个名字都没有还费解。
    #
    # 编号按传统排法（《儀象考成》一路，Stellarium 的中国星空文化同源），
    # **不按弗兰斯蒂德编号从小到大**：昴宿三落在 21 Tau、昴宿四落在 20 Tau。
    # 这个「倒着走」是真的，不是笔误——照编号顺序顺手改过来，就把两颗星的名字
    # 对调了。
    #
    # 18 Tau 只有星官名、没有通行的西名，西名留空而不是编一个。
    "17 Tau": ("Electra", "昴宿一"),
    "19 Tau": ("Taygeta", "昴宿二"),
    "21 Tau": ("Asterope", "昴宿三"),
    "20 Tau": ("Maia", "昴宿四"),
    "23 Tau": ("Merope", "昴宿五"),
    "27 Tau": ("Atlas", "昴宿七"),
    "16 Tau": ("Celaeno", "昴宿增九"),
    "28 Tau": ("Pleione", "昴宿增十二"),
    "18 Tau": ("", "昴宿增八"),
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

def fetch(
    source: str,
    columns: str | None = None,
    constraints: dict[str, str] | None = None,
) -> str:
    """从 VizieR 取一张表的 TSV。

    必须显式带 ``-out.max=unlimited``：服务端默认只返回 50000 行，
    而 Hipparcos 主表有 118218 行，截断后 HIP 号大的那半个天区会整片丢失。
    Gaia 主表有一亿八千万行，不设星等约束的话连下载都下不完，所以
    [constraints] 是要紧的：``{"Gmag": "<9.0"}`` 由服务端筛，而不是拉下来
    再自己丢。
    """
    params = {"-source": source, "-out.max": "unlimited"}
    if columns:
        params["-out"] = columns
    if constraints:
        params.update(constraints)
    url = f"{VIZIER}?{urllib.parse.urlencode(params)}"
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=180) as response:
        text = response.read().decode("utf-8", errors="replace")
    # 回满就是被截断了，而 VizieR 不会说。
    #
    # 这个上限按行数算，和 `-out.max=unlimited` 无关：实测 G<11 的查询被切成
    # 十段并行拉，十段全部停在 50001 行（含表头）上，拼起来就是一份「看着完整、
    # 其实缺了大半」的星表——这种错会一路带到资产里，直到某片天区解不出来才
    # 露头。完整的结果落在整数上的概率可以忽略，所以正好撞上就是被截了。
    # 深于 G<10 的层请走 `tools/fetch_gaia.py`（ESA TAP + 盒子切分）。
    data_rows = sum(
        1 for line in text.splitlines() if line.strip() and not line.startswith("#")
    )
    if data_rows in (50000, 50001):
        raise RuntimeError(
            f"{source} 的返回正好停在 {data_rows} 行，这是 VizieR 的服务端上限，"
            "内容已经被截断。深星表请用 tools/fetch_gaia.py 生成缓存。"
        )
    return text


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


MESSIER_TO_NGC: dict[int, str] = {
    1: "1952", 2: "7089", 3: "5272", 4: "6121", 5: "5904", 6: "6405",
    7: "6475", 8: "6523", 9: "6333", 10: "6254", 11: "6705", 12: "6218",
    13: "6205", 14: "6402", 15: "7078", 16: "6611", 17: "6618", 18: "6613",
    19: "6273", 20: "6514", 21: "6531", 22: "6656", 23: "6494", 25: "I4725",
    26: "6694", 27: "6853", 28: "6626", 29: "6913", 30: "7099", 31: "224",
    32: "221", 33: "598", 34: "1039", 35: "2168", 36: "1960", 37: "2099",
    38: "1912", 39: "7092", 41: "2287", 42: "1976", 43: "1982", 44: "2632",
    46: "2437", 47: "2422", 48: "2548", 49: "4472", 50: "2323", 51: "5194",
    52: "7654", 53: "5024", 54: "6715", 55: "6809", 56: "6779", 57: "6720",
    58: "4579", 59: "4621", 60: "4649", 61: "4303", 62: "6266", 63: "5055",
    64: "4826", 65: "3623", 66: "3627", 67: "2682", 68: "4590", 69: "6637",
    70: "6681", 71: "6838", 72: "6981", 73: "6994", 74: "628", 75: "6864",
    76: "650", 77: "1068", 78: "2068", 79: "1904", 80: "6093", 81: "3031",
    82: "3034", 83: "5236", 84: "4374", 85: "4382", 86: "4406", 87: "4486",
    88: "4501", 89: "4552", 90: "4569", 91: "4548", 92: "6341", 93: "2447",
    94: "4736", 95: "3351", 96: "3368", 97: "3587", 98: "4192", 99: "4254",
    100: "4321", 101: "5457", 102: "5866", 103: "581", 104: "4594",
    105: "3379", 106: "4258", 107: "6171", 108: "3556", 109: "3992",
    110: "205",
}

# 不在 NGC 2000.0 里的四个 Messier 目标：编号 -> (RA 度, Dec 度, 类型, 角分, 星等)。
#
# M24 是银河里的一块星云（IC 4715），M40 是真正的双星 Winnecke 4，
# M45 是昴星团，三者都不是「星云星团表」里的条目，查表查不到，只能写死。
# M102 是有争议的编号，惯例按 NGC 5866（纺锤星系）处理，仍走上面的映射表。
MESSIER_EXTRA: dict[int, tuple[float, float, str, float, float]] = {
    24: (274.225, -18.483, "Ast", 90.0, 4.6),
    40: (185.600, 58.083, "D*", 0.8, 8.9),
    45: (56.850, 24.117, "OC", 110.0, 1.6),
}

# NGC 2000.0 的类型码。它自己的一套写法，和 SIMBAD 的 otype 不是一回事，
# 所以不能和 `lib/astrometry.dart` 里那张表合并。中文翻译放在 Dart 侧——
# 改措辞不该需要重新生成数据。
DEEPSKY_TYPES = frozenset(
    {"Gx", "OC", "Gb", "Pl", "Nb", "C+N", "SNR", "D*", "***", "Ast", "Kt", "PD", "?"}
)

# 不看星等、一律收进目录的那几类。
#
# NGC 2000.0 有 41% 的条目没有星等（13227 条里 5461 条），而「又大又弥漫」正是
# 最容易没有星等的那一类——星等那一列对这类天体本来就没多大意义（延展天体没有
# 「一个点」的星等，面纱星云五个部件在表里全是空的）。
#
# 按星等筛的后果是实打实的：2274 条里真正的星云只剩 59 条，而面纱星云
# （NGC 6960 / 6992 / 6995 / 6979 / 6974）一条都没有——它恰恰是爱好者最常拍的
# 目标之一。用户拍了半天，图上什么也没有。
#
# 这几类加起来一千二百多条，全部收进来只多 30 KB 上下，而它们正是照片里真会
# 出现的东西。剩下的绝大多数是星系（8682 条），继续按星等和尺寸筛。
NO_MAGNITUDE_TYPES = frozenset({"Nb", "Pl", "C+N", "Kt", "SNR", "OC", "Gb", "Ast"})

NGC2000_COLUMNS = "Name,Type,RAB2000,DEB2000,size,mag,n_mag,Desc"


def rebuild_deepsky_only(args, cached_fetch) -> int:
    """只重写 `deepsky.json`，顺带更新 `catalog_meta.json` 里和它有关的几个字段。

    meta 是**读改写**而不是重写：恒星数、星座顺序、Gaia 层那几个数值只有完整
    跑一遍才算得出来，这里不该动它们，更不该把它们抹成 null——那会让
    `catalog_meta.json` 看起来像一份残缺的构建记录。
    """
    ngc_rows = cached_fetch("ngc2000", "VII/118/ngc2000", NGC2000_COLUMNS)
    payload, missing = build_deepsky_payload(
        ngc_rows, args.deepsky_mag_limit, args.deepsky_size_min
    )
    write_json(os.path.join(args.out, "deepsky.json"), payload)
    if missing:
        print(
            "注意：这些 Messier 编号在 NGC 2000.0 里没找到，"
            f"深空目录会缺条目：{missing}",
            file=sys.stderr,
        )

    meta_path = os.path.join(args.out, "catalog_meta.json")
    meta: dict[str, object] = {}
    if os.path.exists(meta_path):
        with open(meta_path, encoding="utf-8") as handle:
            meta = json.load(handle)
    meta["deepsky_mag_limit"] = args.deepsky_mag_limit
    meta["deepsky_size_min"] = args.deepsky_size_min
    # 把「哪几类不看星等」也记进 meta：不然光看 mag_limit 会以为这套筛选只有
    # 一条规则，而深空目录里那些没有星等的星云正是靠这一项才留下来的。
    meta["deepsky_always_types"] = sorted(NO_MAGNITUDE_TYPES)
    meta["deepsky_count"] = len(payload)
    write_json(meta_path, meta)

    kinds: dict[str, int] = {}
    for row in payload:
        kinds[str(row[3])] = kinds.get(str(row[3]), 0) + 1
    print(
        f"只重建深空目录：{len(payload)} 个天体，"
        f"其中星云/星团 {sum(kinds.get(k, 0) for k in NO_MAGNITUDE_TYPES)} 个",
        file=sys.stderr,
    )
    return 0


def build_gaia_layer(
    hip_positions: list[tuple[float, float]],
    gaia_rows: list[dict[str, str]],
    mag_limit: float,
) -> tuple[bytes, int, int]:
    """把 Gaia 里比 Hipparcos 更深的那批星编成定长二进制。

    单独一层而不是并进 ``stars.json``，因为两层要的东西不一样：Hipparcos
    那层带名字、星座和 V 星等（测光零点的基准），这一层只有位置和星等——
    名字它本来也没有，而 JSON 的字段名和文本数字会让体积翻好几倍。定长
    7 字节一条，十七万颗星 1.2 MB，同样的内容写成 JSON 要 8 MB 以上。

    和 Hipparcos 重叠的丢掉：同一个位置放两颗星，解算器的近邻图里就多出
    一对零距离的点，那不是观测到的东西。亮星留在 Hipparcos 那层——它们的
    V 星等才是零点基准，Gaia 的 G 和它差着零点几个星等，混着用会把零点
    整体拉偏。

    返回 (二进制, 收录条数, 因重叠丢弃的条数)。
    """
    buckets: dict[tuple[int, int], list[tuple[float, float]]] = {}
    for ra, dec in hip_positions:
        buckets.setdefault(_cell(ra, dec), []).append((ra, dec))

    packed = bytearray()
    kept = 0
    overlapped = 0
    for row in gaia_rows:
        ra = parse_number(row.get("RA_ICRS", ""))
        dec = parse_number(row.get("DE_ICRS", ""))
        magnitude = parse_number(row.get("Gmag", ""))
        if ra is None or dec is None or magnitude is None:
            continue
        if magnitude > mag_limit:
            continue
        duplicate = False
        for dra in (-1, 0, 1):
            for ddec in (-1, 0, 1):
                for other_ra, other_dec in buckets.get(_cell(ra + dra, dec + ddec), []):
                    if angular_distance_deg(ra, dec, other_ra, other_dec) < OVERLAP_DEG:
                        duplicate = True
                        break
                if duplicate:
                    break
            if duplicate:
                break
        if duplicate:
            overlapped += 1
            continue
        packed += pack_gaia_star(ra, dec, magnitude)
        kept += 1
    return bytes(packed), kept, overlapped


def pack_gaia_star(ra_deg: float, dec_deg: float, magnitude: float) -> bytes:
    """一颗星 7 字节：赤经 3、赤纬 3、星等 1，全部大端定长。

    三字节的赤经在全天上是 0.077″ 一格，赤纬 0.039″ 一格——比任何一张手机
    照片的星点定位精度都高两个数量级，不值得为它多花一个字节。星等按 0.05
    等一格，一字节覆盖到 12.75 等，够到星等上限还有富余；解算只拿它排序和
    定暗星上限，不求测光。
    """
    ra_units = int(round((ra_deg % 360.0) / 360.0 * (1 << 24))) & 0xFFFFFF
    dec_units = int(round((dec_deg + 90.0) / 180.0 * (1 << 24))) & 0xFFFFFF
    mag_units = max(0, min(255, int(round(magnitude * GAIA_MAG_SCALE))))
    return (
        ra_units.to_bytes(3, "big")
        + dec_units.to_bytes(3, "big")
        + bytes([mag_units])
    )


def parse_ngc_name(raw: str) -> str | None:
    """``  224`` -> ``NGC 224``；``I5370`` -> ``IC 5370``。

    表里的名字是裸编号（IC 条目在前面加一个 ``I``），不给前缀的话用户在
    别处根本搜不到。
    """
    name = raw.strip()
    if not name:
        return None
    if name.startswith("I"):
        body = name[1:].strip()
        return f"IC {body}" if body.isdigit() else None
    return f"NGC {name}" if name.isdigit() else None


def build_deepsky_payload(
    rows: list[dict[str, str]], mag_limit: float, size_min: float
) -> tuple[list[list[object]], list[int]]:
    """把 NGC 2000.0 裁成 APP 用的深空目录。

    留下的有三类：

    * 全部 110 个 Messier 目标（爱好者真正会去拍的那批）；
    * [NO_MAGNITUDE_TYPES] 那几类——星云、行星状星云、疏散星团、球状星团——
      **不看星等**，理由见那张表的注释：按星等筛会把面纱星云这种大名鼎鼎的
      目标整片滤掉；
    * 其余（绝大多数是星系）按「亮于 [mag_limit] 等且长轴大于 [size_min] 角分」
      筛。这一万多条如果全收，画面会被十四等的暗星系糊满。

    返回 (目录, 没找到的 Messier 编号)。后者正常应该是空的；非空说明映射表
    或数据源变了，构建日志里要能看见。
    """
    by_name: dict[str, dict[str, str]] = {}
    for row in rows:
        name = parse_ngc_name(row.get("Name", ""))
        if name:
            by_name[name] = row

    messier_of: dict[str, int] = {}
    missing: list[int] = []
    for number, identifier in sorted(MESSIER_TO_NGC.items()):
        name = parse_ngc_name(identifier)
        if name is None or name not in by_name:
            missing.append(number)
            continue
        messier_of[name] = number

    payload: list[list[object]] = []
    for name, row in by_name.items():
        ra = parse_ra(row.get("RAB2000", ""))
        dec = parse_dec(row.get("DEB2000", ""))
        if ra is None or dec is None:
            continue
        number = messier_of.get(name)
        size = parse_number(row.get("size", ""))
        magnitude = parse_number(row.get("mag", ""))
        object_type = row.get("Type", "").strip()
        if object_type not in DEEPSKY_TYPES:
            object_type = ""
        if number is None and object_type not in NO_MAGNITUDE_TYPES:
            if magnitude is None or magnitude > mag_limit:
                continue
            if size is None or size < size_min:
                continue
        payload.append(
            [
                f"M {number}" if number else name,
                round(ra, 5),
                round(dec, 5),
                object_type,
                round(size, 1) if size is not None else None,
                round(magnitude, 1) if magnitude is not None else None,
            ]
        )

    for number, (ra, dec, object_type, size, magnitude) in MESSIER_EXTRA.items():
        payload.append(
            [f"M {number}", round(ra, 5), round(dec, 5), object_type,
             round(size, 1), round(magnitude, 1)]
        )

    # 按赤经排序：文件本身就是给人翻的，按天区排比按星等排更好找。
    payload.sort(key=lambda item: float(item[1]))
    return payload, missing


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", default="assets/catalog", help="输出目录")
    parser.add_argument("--mag-limit", type=float, default=8.0, help="保留的极限 V 星等")
    parser.add_argument("--line-mag-limit", type=float, default=4.6,
                        help="参与生成星座连线的极限星等")
    parser.add_argument("--max-line-stars", type=int, default=12,
                        help="每个星座参与连线的最大星数")
    parser.add_argument("--cache", default="tools/.cache", help="原始星表缓存目录")
    parser.add_argument("--deepsky-mag-limit", type=float, default=13.0,
                        help="深空目录保留的极限视星等（Messier 不受此限）")
    parser.add_argument("--deepsky-size-min", type=float, default=1.0,
                        help="深空目录保留的最小长轴角分（Messier 不受此限）")
    parser.add_argument("--skip-deepsky", action="store_true",
                        help="不生成 deepsky.json（只更新恒星目录时用）")
    parser.add_argument("--gaia-mag-limit", type=float, default=11.0,
                        help="Gaia 补充层保留的极限 G 星等（每深一等，星数约涨三倍）")
    parser.add_argument("--gaia-mid-mag-limit", type=float, default=9.0,
                        help="浅层补充与整层之间的界线：解算先用 V 星 + G 到这个限的星，"
                             "解不出来才动用整层")
    parser.add_argument("--skip-gaia", action="store_true",
                        help="不生成 gaia.bin（只更新名字或深空目录时用）")
    parser.add_argument("--only-deepsky", action="store_true",
                        help="只重建 deepsky.json，其余资产一律不动")
    args = parser.parse_args()

    # Windows 控制台默认是 GBK，拜耳编号里的上标（α²）会让 print 抛
    # UnicodeEncodeError。日志本来就是给人看的，编不出来就替换掉。
    for stream in (sys.stdout, sys.stderr):
        reconfigure = getattr(stream, "reconfigure", None)
        if reconfigure is not None:
            reconfigure(errors="replace")

    os.makedirs(args.out, exist_ok=True)
    os.makedirs(args.cache, exist_ok=True)

    def cached_fetch(
        name: str,
        source: str,
        columns: str | None = None,
        constraints: dict[str, str] | None = None,
    ) -> list[dict[str, str]]:
        path = os.path.join(args.cache, f"{name}.tsv")
        if os.path.exists(path):
            with open(path, encoding="utf-8") as handle:
                text = handle.read()
        else:
            print(f"下载 {source} …", file=sys.stderr)
            text = fetch(source, columns=columns, constraints=constraints)
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(text)
        return parse_tsv(text)

    # 只重建深空目录。
    #
    # 单独留一条窄路，是因为深空目录的筛选规则改起来很容易想到要改（「为什么
    # 面纱星云不在里面」），而完整跑一遍要重新拉 118218 行 Hipparcos 和
    # 十三万行 Gaia——为了调一个筛选条件重下几 MB，下次就没人愿意改了。
    if args.only_deepsky:
        return rebuild_deepsky_only(args, cached_fetch)

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
            # 有星官名、没有通行西名的星（18 Tau 这种）留空，不编一个出来。
            if proper[0]:
                star["en"] = proper[0]
            if proper[1]:
                star["zh"] = proper[1]

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

    # ---- 7. 离线深空目录 ------------------------------------------------
    # 在线解算能从 SIMBAD 拿到深空天体的名字，但那要联网。本机解算同样知道
    # 自己指着哪片天，缺的只是一张表——把表带上，标名字这件事就不必联网，
    # 还能顺带给出角尺寸（「它占了画面多大」，这是 SIMBAD 不给的）。
    deepsky_payload: list[list[object]] = []
    if not args.skip_deepsky:
        ngc_rows = cached_fetch("ngc2000", "VII/118/ngc2000", NGC2000_COLUMNS)
        deepsky_payload, missing_messier = build_deepsky_payload(
            ngc_rows, args.deepsky_mag_limit, args.deepsky_size_min
        )
        write_json(os.path.join(args.out, "deepsky.json"), deepsky_payload)
        if missing_messier:
            print(
                "注意：这些 Messier 编号在 NGC 2000.0 里没找到，"
                f"深空目录会缺条目：{missing_messier}",
                file=sys.stderr,
            )

    # ---- 8. Gaia 补充层 --------------------------------------------------
    # Hipparcos 到 V=8.0 只有 41394 颗，全天平均每平方度一颗。视场 4° 上下
    # 的照片，一片天区里就十来颗目录星——刚好卡在「解得出」和「解不出」的
    # 边界上，所以猎户座大星云这类星点稀的天区总是时灵时不灵。往下再要
    # 两个星等，天区里的目录星就有四倍，解算这才站得住。
    #
    # 这批星只做背景，不起名字：它们没有中文名、也没有拜耳编号，放进
    # names.json 只会多出一堆「HIP -12345」。
    gaia_count = 0
    if not args.skip_gaia:
        gaia_rows = cached_fetch(
            f"gaia{args.gaia_mag_limit:g}".replace(".", "_"),
            GAIA_SOURCE,
            GAIA_COLUMNS,
            constraints={"Gmag": f"<{args.gaia_mag_limit:g}"},
        )
        packed, gaia_count, overlapped = build_gaia_layer(
            [(float(row[1]), float(row[2])) for row in stars_payload],
            gaia_rows,
            args.gaia_mag_limit,
        )
        with open(os.path.join(args.out, "gaia.bin"), "wb") as handle:
            handle.write(packed)
        print(
            f"  写出 {os.path.join(args.out, 'gaia.bin')}"
            f"（{len(packed) / 1024:.0f} KB，{gaia_count} 颗，"
            f"与 Hipparcos 重叠丢弃 {overlapped} 颗）",
            file=sys.stderr,
        )
        if gaia_count < 1000:
            print("注意：Gaia 补充层几乎没有内容，V/8 等以下的暗天区仍然解不出来",
                  file=sys.stderr)

    write_json(
        os.path.join(args.out, "catalog_meta.json"),
        {
            "mag_limit": args.mag_limit,
            "line_mag_limit": args.line_mag_limit,
            "star_count": len(stars_payload),
            "constellation_order": abbreviations,
            "gaia_mag_limit": None if args.skip_gaia else args.gaia_mag_limit,
            "gaia_mid_mag_limit": None if args.skip_gaia else args.gaia_mid_mag_limit,
            "gaia_count": gaia_count,
            "deepsky_mag_limit": None if args.skip_deepsky else args.deepsky_mag_limit,
            "deepsky_size_min": None if args.skip_deepsky else args.deepsky_size_min,
            # 哪几类不看星等。光看 mag_limit 会以为这套筛选只有一条规则，而
            # 目录里那些没有星等的星云正是靠这一项才留下来的。`--only-deepsky`
            # 那条窄路一直写着它，主路径漏了很久——两条路都得写，否则「重跑
            # 一遍」和「只重建深空目录」得到的 meta 不一样。
            "deepsky_always_types": sorted(NO_MAGNITUDE_TYPES),
            "deepsky_count": len(deepsky_payload),
            "sources": [
                "I/239/hip_main (ESA 1997, Hipparcos)",
                "V/50/catalog (Hoffleit & Warren 1991, Bright Star Catalogue 5th ed.)",
                "VI/42/data (Roman 1987, constellation boundaries)",
                "VII/118/ngc2000 (Sky Publishing, ed. Sinnott 1988, NGC 2000.0)",
                "I/355/gaiadr3 (Gaia Collaboration 2022, Gaia DR3)",
            ],
        },
    )

    total = sum(
        os.path.getsize(os.path.join(args.out, name))
        for name in os.listdir(args.out)
    )
    print(
        f"完成：{len(stars_payload)} 颗星 + {gaia_count} 颗 Gaia 背景星，"
        f"{len(names_payload)} 条名称，"
        f"{len(constellation_payload)} 个星座，"
        f"{len(deepsky_payload)} 个深空天体，合计 {total / 1024:.0f} KB",
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
