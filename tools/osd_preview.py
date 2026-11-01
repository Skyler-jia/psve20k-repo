# -*- coding: utf-8 -*-
"""按 osd.v 的布局逻辑逐像素渲染 OSD 预览图（含模拟背景），用于上板前校验"""
import re
from PIL import Image, ImageDraw

SRC = r"C:\Users\liush\Documents\Codex\2026-10-15\sh\outputs\psve20k\rtl\osd.v"
OUT = r"C:\Users\liush\Documents\Codex\2026-10-15\sh\work\osd_preview.png"

W, H = 1280, 720

# ---------------- 解析字库 ----------------
rom = {}
for m in re.finditer(r"rom\[\s*(\d+)\]\s*=\s*8'h([0-9A-Fa-f]{2});", open(SRC, encoding="utf-8").read()):
    rom[int(m.group(1))] = int(m.group(2), 16)
print("rom entries:", len(rom))


def glyph(a, r):
    return rom.get(((a & 0x3F) << 4) | r, 0)


# ---------------- osd.v 的布局逻辑 ----------------
NAMES = {0: "GRAY    ", 1: "BINARY  ", 2: "SOBEL   ", 3: "OVERLAY ",
         4: "LAPLACE ", 5: "MEDIAN  ", 6: "FULLEDGE", 7: "LIVE    "}


def char_at(row, col, mode, dly, edge_k, bw):
    if row == 0:
        if col == 0: return "M"
        if col == 1: return "O"
        if col == 2: return "D"
        if col == 3: return "E"
        if col == 4: return ":"
        if 6 <= col <= 13: return NAMES[mode][col - 6]
        if col == 23: return "P"
        if col == 24: return "0"
        return " "
    if row == 2:
        s = "BW:%03dMB/S" % bw
        return s[col] if col < len(s) else " "
    m = {0: "D", 1: "L", 2: "Y", 3: ":", 4: str(dly),
         6: "E", 7: "C", 8: "N", 9: "T", 10: ":"}
    if col in m: return m[col]
    if 11 <= col <= 13: return f"{edge_k:03d}"[col - 11]
    return " "


# ---------------- 模拟视频背景（近似 img_gen 的观感）----------------
img = Image.new("RGB", (W, H))
px = img.load()
for y in range(H):
    for x in range(W):
        grad = (x >> 3) + (y >> 3)
        base = (grad >> 1) & 0xFF
        proj = (x * 0.94 + y * 0.34) / 4.0           # 近似旋转投影
        stripe = (int(proj) >> 5) & 1
        chk = (((x >> 5) & 1) ^ ((y >> 5) & 1))
        r = min(255, base + (120 if stripe else 0))
        g = min(255, base + (140 if chk else 0))
        b = min(255, base + (60 if stripe else 0))
        px[x, y] = (r, g, b)

# ---------------- OSD 合成 ----------------
import sys
PAGE   = int(sys.argv[1]) if len(sys.argv) > 1 else 0
MODE, DLY, ECNT, BW = 2, 3, 412, 112
RD_KB, WR_KB, TURN, BUSY = 900, 900, 48, 39
UP_S, FRM_K, ACC_M = 123, 12, 173
NAMES[10] = "WATERFAL"
NAMES[11] = "WF-SOBEL"


def char_at_page(row, col):
    if PAGE == 0:
        return char_at(row, col, MODE, DLY, ECNT, BW)
    if PAGE == 2:
        if row == 0:
            s = "RUN DASHBOARD"
            if col < len(s): return s[col]
            if col == 23: return "P"
            if col == 24: return "2"
            return " "
        if row == 1:
            s = "UP:%03dS FRM:%03dK" % (UP_S, FRM_K)
            return s[col] if col < len(s) else " "
        s = "ACC:%03dM BURSTS" % ACC_M
        return s[col] if col < len(s) else " "
    if row == 0:
        s = "SDRAM STAT"
        if col < len(s): return s[col]
        if col == 23: return "P"
        if col == 24: return "1"
        return " "
    if row == 1:
        s = "RD:%03dKB WB:%03dKB" % (RD_KB, WR_KB)
        return s[col] if col < len(s) else " "
    s = "TO:%03d BU:%03d%%" % (TURN, BUSY)
    return s[col] if col < len(s) else " "


d = ImageDraw.Draw(img)
SC = 2                                   # 与 osd.v 的 parameter SC 保持一致
for yy in range(16, 16 + 3 * 16 * SC):
    for xx in range(16, 16 + 26 * 8 * SC):
        col = (xx - 16) >> (4 if SC == 2 else 3)
        row = (yy - 16) >> (5 if SC == 2 else 4)
        grow = ((yy - 16) >> (1 if SC == 2 else 0)) & 15
        bitx = ((xx - 16) >> (1 if SC == 2 else 0)) & 7
        ch = char_at_page(row, col) if row < 3 else " "
        on = (glyph(ord(ch), grow) >> (7 - bitx)) & 1
        px[xx, yy] = (0, 255, 128) if on else (0, 16, 8)

out = OUT.replace(".png", "_p%d.png" % PAGE)
img.save(out)
print("wrote:", out)
