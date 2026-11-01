# -*- coding: utf-8 -*-
"""从系统字体渲染 8x16 点阵，生成 Verilog 初始化表，并输出预览图供肉眼校验"""
import os
from PIL import Image, ImageDraw, ImageFont

OUT_VERILOG = r"C:\Users\liush\Documents\Codex\2026-10-15\sh\work\font_table.vh"
OUT_PREVIEW = r"C:\Users\liush\Documents\Codex\2026-10-15\sh\work\font_preview.png"

CHARS = [chr(c) for c in range(0x20, 0x5B)]      # ' '..'Z'，正好覆盖我们要用的所有字符
CW, CH = 8, 16


def find_font(size):
    for p in (r"C:\Windows\Fonts\consola.ttf", r"C:\Windows\Fonts\msyh.ttc",
              r"C:\Windows\Fonts\cour.ttf", r"C:\Windows\Fonts\arial.ttf"):
        if os.path.exists(p):
            try:
                return ImageFont.truetype(p, size), p
            except Exception:
                pass
    return ImageFont.load_default(), "default"


def render_glyph(ch, font):
    """返回 16 个 8bit 行位图（bit7 = 最左像素）"""
    img = Image.new("L", (CW, CH), 0)
    d = ImageDraw.Draw(img)
    # 垂直居中：字模 9 行，落在 16 行的第 3..11 行
    d.text((0, 1), ch, font=font, fill=255)
    px = img.load()
    rows = []
    for y in range(CH):
        b = 0
        for x in range(CW):
            if px[x, y] > 110:
                b |= (1 << (7 - x))
        rows.append(b)
    return rows


def main():
    font, fpath = find_font(14)
    print("font:", fpath)

    table = {}
    for ch in CHARS:
        table[ch] = render_glyph(ch, font)

    # 只保留真正使用到的字符集（省 ROM），其余置空
    used = " 0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ:./-+%"
    for ch in CHARS:
        if ch not in used:
            table[ch] = [0] * CH

    # ---- ASCII 预览（肉眼校验）----
    for ch in "8ABDE0GMSW:":
        print("--- %r ---" % ch)
        for r in table[ch]:
            print("".join("#" if (r >> (7 - i)) & 1 else "." for i in range(8)))

    # ---- 预览图 ----
    prev = Image.new("L", (CW * len(used), CH), 0)
    for i, ch in enumerate(used):
        for y, r in enumerate(table[ch]):
            for x in range(8):
                if (r >> (7 - x)) & 1:
                    prev.putpixel((i * CW + x, y), 255)
    prev.resize((CW * len(used) * 3, CH * 3), Image.NEAREST).save(OUT_PREVIEW)

    # ---- 生成 Verilog：地址 = {ascii[5:0], row[3:0]} ----
    lines = []
    lines.append("// 自动生成：8x16 点阵字库，地址 = {ascii[5:0], row[3:0]}，bit7 为最左像素")
    lines.append("// 由 work/gen_font.py 生成，勿手改")
    entries = []
    for ch in CHARS:
        idx = ord(ch) & 0x3F
        for y in range(CH):
            entries.append(((idx << 4) | y, table[ch][y]))
    entries.sort(key=lambda t: t[0])
    maxa = entries[-1][0]
    for i in range(0, len(entries), 8):
        chunk = entries[i:i + 8]
        lines.append("        " + " ".join("rom[%4d] = 8'h%02X;" % (a, v) for a, v in chunk))
    lines.append("// 表项数 = %d (最大地址 %d)" % (len(entries), maxa))
    open(OUT_VERILOG, "w", encoding="utf-8").write("\n".join(lines) + "\n")
    print("wrote:", OUT_VERILOG, "entries:", len(entries))


if __name__ == "__main__":
    main()
