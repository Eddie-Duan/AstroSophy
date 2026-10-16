"""从 ESA 的 Gaia DR3 取一层背景星，写成 `build_catalog.py` 认识的缓存文件。

为什么不用 `build_catalog.py` 里那条 VizieR 通道：VizieR 的同步接口一次最多
回 50000 行，而 G < 11 的星有一百二十多万颗——按星等切十段并行拉，十段**全部**
停在 50001 行上，回来的是一份悄悄缺了大半的数据。就算绕开这个上限，单条连接
实测也只有十几 KB/s，拉完要几个小时。

ESA 的 TAP 同步接口同样是 50000 行封顶，但它不会假装成功：**回满就是这个盒子
里有更多东西**。所以这里按「半个天区一个盒子」起步，哪个盒子回满了就把盒子切
成两半再来，切到每个盒子都在上限以内为止——这个信号是可信的，切分因此收敛得
很快。并发开到 3：再高会被服务端卡住，反而更慢。

写出的文件就是 `build_catalog.py` 的缓存格式（列名行、单位行、分隔行、数据行），
放到 `tools/.cache/gaia<星等>.tsv` 之后，构建脚本会直接用它，不会再联网。

    python tools/fetch_gaia.py --mag 11
"""

import argparse
import os
import sys
import time
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor

BASE = "https://gea.esac.esa.int/tap-server/tap/sync"

# 服务端单次返回的行数上限。回满即「这个盒子里还有」，不是错误。
LIMIT = 50000

# 最多切几层。15° × 180° 的盒子切十层是 0.03°，远小于 G<11 的星间距尺度，
# 真到了这一层说明数据源变了，不该再默默切下去。
MAX_DEPTH = 10

THREADS = 3


def fetch(box: tuple[float, float, float, float], magnitude: float) -> str:
    dec_lo, dec_hi, ra_lo, ra_hi = box
    query = (
        "select ra, dec, phot_g_mean_mag from gaiadr3.gaia_source "
        f"where phot_g_mean_mag < {magnitude} and dec >= {dec_lo} and dec < {dec_hi} "
        f"and ra >= {ra_lo} and ra < {ra_hi}"
    )
    url = BASE + "?" + urllib.parse.urlencode(
        {"REQUEST": "doQuery", "LANG": "ADQL", "FORMAT": "csv", "QUERY": query}
    )
    for attempt in range(4):
        try:
            with urllib.request.urlopen(url, timeout=900) as response:
                return response.read().decode("utf-8", "replace")
        except Exception:  # noqa: BLE001 - 网络抖就重试，最后一遍才抛
            if attempt == 3:
                raise
            time.sleep(5 * (attempt + 1))
    raise AssertionError("unreachable")


def data_rows(text: str) -> list[str]:
    lines = text.split("\n")
    if lines and lines[0].startswith("ra,"):
        lines = lines[1:]
    return [line for line in lines if line.strip() and "," in line]


def collect(
    box: tuple[float, float, float, float],
    out: list[str],
    magnitude: float,
    depth: int = 0,
) -> None:
    rows = data_rows(fetch(box, magnitude))
    if len(rows) >= LIMIT and depth < MAX_DEPTH:
        dec_lo, dec_hi, ra_lo, ra_hi = box
        # 沿长的那条边切，层数最少。
        if (dec_hi - dec_lo) >= (ra_hi - ra_lo):
            mid = (dec_lo + dec_hi) / 2
            collect((dec_lo, mid, ra_lo, ra_hi), out, magnitude, depth + 1)
            collect((mid, dec_hi, ra_lo, ra_hi), out, magnitude, depth + 1)
        else:
            mid = (ra_lo + ra_hi) / 2
            collect((dec_lo, dec_hi, ra_lo, mid), out, magnitude, depth + 1)
            collect((dec_lo, dec_hi, mid, ra_hi), out, magnitude, depth + 1)
        return
    out.extend(rows)
    print(f"  盒子 {box}（第 {depth} 层）：{len(rows)} 行，累计 {len(out)}", flush=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mag", type=float, default=11.0, help="保留的极限 G 星等")
    parser.add_argument("--cache", default=os.path.join("tools", ".cache"),
                        help="缓存目录")
    args = parser.parse_args()

    for stream in (sys.stdout, sys.stderr):
        reconfigure = getattr(stream, "reconfigure", None)
        if reconfigure is not None:
            reconfigure(errors="replace")

    os.makedirs(args.cache, exist_ok=True)
    boxes = []
    for index in range(12):
        lo = -90 + index * 15
        hi = lo + 15
        boxes.append((lo, hi, 0.0, 180.0))
        boxes.append((lo, hi, 180.0, 360.0))

    results: dict[tuple[float, float, float, float], list[str]] = {}

    def work(box):
        rows: list[str] = []
        collect(box, rows, args.mag)
        results[box] = rows
        return len(rows)

    with ThreadPoolExecutor(max_workers=THREADS) as pool:
        list(pool.map(work, boxes))

    total = [row for rows in results.values() for row in rows]
    path = os.path.join(args.cache, f"gaia{args.mag:g}".replace(".", "_") + ".tsv")
    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        # 列名、单位、分隔行——`build_catalog.py` 的 `parse_tsv` 认这三行，
        # 而且只认最后一个分隔行，所以整个文件里只能有这么一块表头。
        handle.write("RA_ICRS\tDE_ICRS\tGmag\n")
        handle.write("\tdeg\tdeg\tmag\n")
        handle.write("\t-------\t-------\t------\n")
        for row in total:
            handle.write(row.replace(",", "\t") + "\n")
    print(
        f"共 {len(total)} 行，写出 {path}"
        f"（{os.path.getsize(path) / 1024 / 1024:.1f} MB）",
        flush=True,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
