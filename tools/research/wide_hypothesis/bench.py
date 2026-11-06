"""宽视场「星图描述子 → 天区」可行性基准（研究脚本，不进 App 运行时）。

问题：80° 以上的手机星野照片，本机的相似变换解算会失败。最初的想法是训练
一个小模型，输入一块星点图形，输出最可能的天区，再让曲率拟合 + 内点概率验收。
这个脚本只回答第一步「图形本身能不能定位」，不训练网络：

  1. 从内置 Hipparcos 星表合成「针孔像面」上的星点图形（随机天区、50–90°
     对角线视场、随机滚转/镜像、随机曝光极限 5–7 等、0.35 等测光噪声、8% 误检）；
  2. 描述子用旋转/平移/缩放/镜像都不变的量：最亮 N 颗星的**排序后两两距离**
     （归一化）＋排序后的星等差；
  3. 拿另一个随机样本当查询，看最近邻数据库里 Top-K 能不能把天区找回来。

实测（2026-11-07，40k 数据库 / 2k 查询）：
    合成数据 Top-200 召回（≤5°）：0.836
    真实 83° 照片查询：Top-200 里离真值最近 12.2°（真值由 astrometry.net 给出）

结论：合成数据上「图形 → 天区」确实能缩小到几度，但换到真实手机照片就退化到
12° —— 说明瓶颈是描述子的域差距（亮星选择、测光、误检、投影），不是搜索量。
这条路线要继续，得用真实照片微调、并把描述子换成对「哪颗星是哪颗」更稳的
结构（图网络/四点几何哈希），而且最终验收必须仍旧交给几何拟合，不能只信模型。

运行：
    python tools/research/wide_hypothesis/bench.py
"""
import csv
import json
import math
import os
import sys
import time

import numpy as np

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
CATALOG = os.path.join(REPO, "assets", "catalog", "stars.json")
DETECTIONS = os.path.join(REPO, "build", "repro", "detections.csv")
STAR_COUNT = 12
DB_SIZE = 40000
QUERY_SIZE = 2000
TOP_K = 200


def load_catalog():
    raw = json.load(open(CATALOG, encoding="utf-8"))
    ra = np.radians(np.array([row[1] for row in raw]))
    dec = np.radians(np.array([row[2] for row in raw]))
    mag = np.array([row[3] for row in raw])
    vectors = np.stack(
        [np.cos(dec) * np.cos(ra), np.cos(dec) * np.sin(ra), np.sin(dec)], axis=1
    ).astype(np.float32)
    return vectors, mag


def sample(vectors, mag, rng, count):
    """合成一批「手机视场」的星点图形描述子。"""
    features, centers = [], []
    made = 0
    while made < count:
        batch = rng.normal(size=(256, 3))
        batch /= np.linalg.norm(batch, axis=1, keepdims=True)
        dots = batch @ vectors.T
        for b in range(256):
            if made >= count:
                break
            center = batch[b]
            half = math.radians(rng.uniform(25, 45))  # 对角线视场 50°–90°
            idx = np.nonzero(dots[b] > math.cos(half + 0.05))[0]
            if idx.size < STAR_COUNT:
                continue
            star_vectors = vectors[idx]
            z = np.array([0.0, 0.0, 1.0], dtype=np.float32)
            east = np.cross(z, center)
            if np.linalg.norm(east) < 1e-6:
                east = np.array([1.0, 0.0, 0.0], dtype=np.float32)
            east /= np.linalg.norm(east)
            north = np.cross(center, east)
            forward = star_vectors @ center
            # 针孔像面：像素 ∝ tan(角)
            tx = (star_vectors @ east) / forward
            ty = (star_vectors @ north) / forward
            keep = (np.abs(tx) < math.tan(half)) & (np.abs(ty) < math.tan(half))
            if keep.sum() < STAR_COUNT:
                continue
            tx, ty, star_mag = tx[keep], ty[keep], mag[idx][keep]
            limit = rng.uniform(5.0, 7.0)
            detect = rng.random(star_mag.size) < 1.0 / (
                1.0 + np.exp((star_mag - limit) / 0.25)
            )
            if detect.sum() < STAR_COUNT:
                continue
            tx = tx[detect] + rng.normal(0, 5e-4, detect.sum())
            ty = ty[detect] + rng.normal(0, 5e-4, detect.sum())
            observed = star_mag[detect] + rng.normal(0, 0.35, detect.sum())
            false_count = rng.poisson(0.08 * tx.size)
            if false_count:
                tx = np.concatenate([tx, rng.uniform(-0.8, 0.8, false_count)])
                ty = np.concatenate([ty, rng.uniform(-0.8, 0.8, false_count)])
                observed = np.concatenate(
                    [observed, rng.uniform(limit - 1.0, limit + 2.0, false_count)]
                )
            order = np.argsort(observed)[:STAR_COUNT]
            xy = np.stack([tx[order], ty[order]], axis=1)
            roll = rng.uniform(0, 2 * math.pi)
            mirror = 1.0 if rng.random() < 0.5 else -1.0
            cos_r, sin_r = math.cos(roll), math.sin(roll)
            xy = np.stack(
                [
                    cos_r * xy[:, 0] - sin_r * xy[:, 1],
                    mirror * (sin_r * xy[:, 0] + cos_r * xy[:, 1]),
                ],
                axis=1,
            )
            dx = xy[:, 0][:, None] - xy[:, 0][None, :]
            dy = xy[:, 1][:, None] - xy[:, 1][None, :]
            dist = np.sqrt(dx * dx + dy * dy)
            upper = np.sort(dist[np.triu_indices(STAR_COUNT, 1)])
            scale = max(np.percentile(upper, 90), 1e-9)
            gaps = np.sort(observed[order][1:] - observed[order][0])
            features.append(
                np.concatenate([upper / scale, gaps / 3.0]).astype(np.float32)
            )
            centers.append(center)
            made += 1
    return np.stack(features), np.stack(centers)


def angular(a, b):
    return np.degrees(np.arccos(np.clip((a * b).sum(-1), -1, 1)))


def query_from_image(path):
    rows = list(csv.DictReader(open(path, encoding="utf-8")))
    stars = sorted(rows, key=lambda r: float(r["instrumentalMagnitude"]))[:STAR_COUNT]
    xy = np.array([[float(r["x"]), float(r["y"])] for r in stars])
    mags = np.sort(
        np.array([float(r["instrumentalMagnitude"]) for r in stars])
    )
    gaps = mags[1:] - mags[0]
    dx = xy[:, 0][:, None] - xy[:, 0][None, :]
    dy = xy[:, 1][:, None] - xy[:, 1][None, :]
    dist = np.sqrt(dx * dx + dy * dy)
    upper = np.sort(dist[np.triu_indices(STAR_COUNT, 1)])
    scale = max(np.percentile(upper, 90), 1e-9)
    return np.concatenate([upper / scale, np.sort(gaps) / 3.0])[None, :]


def main():
    vectors, mag = load_catalog()
    rng = np.random.default_rng(31)
    print(f"catalog stars: {vectors.shape[0]}")

    started = time.time()
    db_x, db_c = sample(vectors, mag, rng, DB_SIZE)
    print(f"database: {db_x.shape} ({time.time() - started:.1f}s)")
    db_norm = (db_x**2).sum(axis=1)

    started = time.time()
    val_x, val_c = sample(vectors, mag, rng, QUERY_SIZE)
    hits = 0
    for start in range(0, val_x.shape[0], 200):
        q = val_x[start : start + 200]
        norm = (q**2).sum(axis=1)
        distances = norm[:, None] - 2 * q @ db_x.T + db_norm[None, :]
        idx = np.argpartition(distances, TOP_K, axis=1)[:, :TOP_K]
        for row in range(q.shape[0]):
            angles = angular(db_c[idx[row]], val_c[start + row])
            hits += int((angles <= 5.0).any())
    print(f"synthetic top-{TOP_K} recall <=5deg: {hits / QUERY_SIZE:.3f} ({time.time() - started:.1f}s)")

    if os.path.exists(DETECTIONS):
        query = query_from_image(DETECTIONS)
        norm = (query**2).sum(axis=1)
        distances = norm[:, None] - 2 * query @ db_x.T + db_norm[None, :]
        idx = np.argsort(distances[0])[:TOP_K]
        # 真实照片的真值中心（astrometry.net 解，换算到分析图中心）
        truth = np.array([330.52, 49.39])
        truth_vector = np.array(
            [
                math.cos(math.radians(truth[1])) * math.cos(math.radians(truth[0])),
                math.cos(math.radians(truth[1])) * math.sin(math.radians(truth[0])),
                math.sin(math.radians(truth[1])),
            ]
        )
        angles = angular(db_c[idx], truth_vector)
        print(
            f"real photo: nearest db hit is {angles.min():.1f}deg from truth "
            f"(top-20 best {angles[:20].min():.1f}deg)"
        )
    else:
        print("no real-photo query (build/repro/detections.csv missing)")


if __name__ == "__main__":
    sys.exit(main())
