# -*- coding: utf-8 -*-
"""算法栅格预览：8 条带 = 同一帧 + 8 种算法，右侧标注算法名
   算法公式与 img_proc.v 完全一致（Sobel/Laplace/中值/二值/运动）"""
import math
import re
import numpy as np
from PIL import Image

OSD = r"C:\Users\liush\Documents\Codex\2026-10-15\sh\outputs\psve20k\rtl\osd.v"
OUT = r"C:\Users\liush\Documents\Codex\2026-10-15\sh\work\algogrid_preview.png"
W, H, BAND = 1280, 720, 90

rom = {}
for m in re.finditer(r"rom\[\s*(\d+)\]\s*=\s*8'h([0-9A-Fa-f]{2});", open(OSD, encoding="utf-8").read()):
    rom[int(m.group(1))] = int(m.group(2), 16)


def pattern(angle_deg):
    x = np.arange(W)[None, :].astype(np.int64)
    y = np.arange(H)[:, None].astype(np.int64)
    a = math.radians(angle_deg)
    u = (x - 640) * math.cos(a) - (y - 360) * math.sin(a)
    stripe = ((u.astype(np.int64) >> 5) & 1)
    chk = (((x >> 5) & 1) ^ ((y >> 5) & 1))
    grad = ((x >> 3) + (y >> 3)) >> 1
    return np.clip(grad + 130 * stripe + 55 * chk, 0, 255).astype(np.int64)


src = pattern(25)                 # 当前帧
old = pattern(25 - 1 * 4.22)      # 延迟 1 帧（用于运动检测）
p = src

# ---- Sobel (Gx=(p1+2p2+p3)-(p7+2p8+p9), Gy=(p1+2p4+p7)-(p3+2p6+p9)) ----
gx = (p[:-2, :-2] + 2 * p[:-2, 1:-1] + p[:-2, 2:]) - (p[2:, :-2] + 2 * p[2:, 1:-1] + p[2:, 2:])
gy = (p[:-2, :-2] + 2 * p[1:-1, :-2] + p[2:, :-2]) - (p[:-2, 2:] + 2 * p[1:-1, 2:] + p[2:, 2:])
sobel = np.zeros_like(p)
sobel[1:-1, 1:-1] = np.clip((np.abs(gx) + np.abs(gy)) >> 3, 0, 255)

# ---- Laplacian (4*p5-(p2+p4+p6+p8)) ----
lap = 4 * p[1:-1, 1:-1] - (p[:-2, 1:-1] + p[1:-1, :-2] + p[1:-1, 2:] + p[2:, 1:-1])
lapa = np.zeros_like(p)
lapa[1:-1, 1:-1] = np.clip(np.abs(lap) >> 2, 0, 255)

# ---- 3x3 精确中值 ----
stack = np.stack([p[i:i + H - 2, j:j + W - 2] for i in range(3) for j in range(3)], axis=0)
med = np.zeros_like(p)
med[1:-1, 1:-1] = np.median(stack, axis=0)

# ---- 运动检测：|当前帧 - 延迟帧| ----
motion = np.clip(np.abs(src - old), 0, 255) > 24

gray = src
binary = np.where(src >= 128, 255, 0)
overlay = np.where(sobel > 48, 255, src)

bands = [gray, binary, sobel, overlay, lapa, med, motion.astype(np.int64) * 255, motion]
NAMES = ["GRAY", "BINARY", "SOBEL", "OVERLAY", "LAPLACE", "MEDIAN", "MOTION", "MOTIONOV"]

out = np.zeros((H, W, 3), np.uint8)
for k in range(8):
    y0 = k * BAND
    b = bands[k][y0:y0 + BAND]
    if k == 7:                                        # 运动叠加：红/灰
        rgb = np.stack([np.where(b, 255, b * 0), np.where(b, 32, b * 0), np.where(b, 0, b * 0)], -1)
        rgb = np.stack([np.where(b, 255, gray[y0:y0 + BAND]),
                        np.where(b, 32, gray[y0:y0 + BAND]),
                        np.where(b, 0, gray[y0:y0 + BAND])], -1)
    elif k == 3:                                      # 边缘叠加：白边+灰底
        rgb = np.stack([b, b, b], -1)
    else:
        rgb = np.stack([b, b, b], -1)
    out[y0:y0 + BAND] = rgb.astype(np.uint8)
    out[y0:y0 + 2] = 16                               # 每带头 2 行 = 分隔线

img = Image.fromarray(out)
px = img.load()


def text(col, row, s, x0=16, y0=16):
    for i, ch in enumerate(s):
        for gy in range(16):
            bits = rom.get(((ord(ch) & 0x3F) << 4) | gy, 0)
            for gx in range(8):
                if (bits >> (7 - gx)) & 1:
                    for sy in range(2):
                        for sx in range(2):
                            X = x0 + (col + i) * 16 + gx * 2 + sx
                            Y = y0 + row * 32 + gy * 2 + sy
                            if 0 <= X < W and 0 <= Y < H:
                                px[X, Y] = (0, 255, 128)


for row in range(3):                                  # 左上主 OSD 底
    for xx in range(16, 16 + 26 * 16):
        for yy in range(16 + row * 32, 16 + (row + 1) * 32):
            px[xx, yy] = (0, 16, 8)
text(0, 0, "MODE:ALGOGRID")
text(23, 0, "P0")
text(0, 1, "STP:0 ECNT:412")
text(0, 2, "BW:112MB/S")

for k in range(8):                                    # 每带右侧标签
    y0 = k * BAND + 4
    for xx in range(1152, 1280):
        for yy in range(y0 - 4, y0 + 28):
            if 0 <= yy < H:
                px[xx, yy] = (0, 16, 8)
    text(0, 0, NAMES[k], x0=1152, y0=y0)

img.save(OUT)
print("wrote:", OUT)
