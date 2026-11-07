# 產生建築物（設施）的物品圖示與施工單角標：python devtools/make_icons.py
# 32×32 像素圖，斜投影（深度往右上），光從左上：頂面亮、正面中、側面暗，外框深色。
# 輸出到 textures/：rockmech_icon_<name>.png、rockmech_order_badge.png（右下角 1/4 大小的施工單，疊在建築物圖示上）
import os
from PIL import Image, ImageDraw

OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "textures")
S = 32


def rgb(h, a=255):
    h = h.lstrip("#")
    return (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16), a)


def shade(c, k):
    return tuple(max(0, min(255, int(v * k))) for v in c[:3]) + (c[3],)


class Icon:
    def __init__(self):
        self.im = Image.new("RGBA", (S, S), (0, 0, 0, 0))
        self.px = self.im.load()

    def put(self, x, y, c):
        if 0 <= x < S and 0 <= y < S:
            self.px[x, y] = c

    def rect(self, x, y, w, h, c):
        for i in range(x, x + w):
            for j in range(y, y + h):
                self.put(i, j, c)

    def box(self, x, y, w, h, d, c, outline=True):
        """斜投影的方塊：正面左上角 (x, y + d)、寬 w、高 h、深 d（往右上）"""
        top, front, side = shade(c, 1.25), c, shade(c, 0.7)
        for r in range(d):                       # 頂面：每往後一列右移 1
            s = d - 1 - r
            for i in range(w):
                self.put(x + s + i, y + r, top)
        self.rect(x, y + d, w, h, front)         # 正面
        for k in range(1, d):                    # 側面：每往後一欄上移 1
            for j in range(h):
                self.put(x + w - 1 + k, y + d - k + j, side)
        if outline:
            o = shade(c, 0.35)
            for i in range(w):
                self.put(x + i, y + d + h - 1, o)                # 正面底邊
                self.put(x + d - 1 + i, y, o)                     # 頂面後緣
            for j in range(h):
                self.put(x, y + d + j, o)                         # 正面左邊
                self.put(x + w - 1 + d - 1, y + 1 + j, o)         # 側面右邊
            for r in range(d):
                self.put(x + d - 1 - r, y + r, o)                 # 頂面左斜邊
                self.put(x + w - 1 + r, y + d + h - 1 - r, o)     # 側面底斜邊

    def save(self, name):
        os.makedirs(OUT, exist_ok=True)
        self.im.save(os.path.join(OUT, name))


def crusher(body, stripe, name, big=False):
    ic = Icon()
    w, h, d = (16, 14, 5) if big else (12, 11, 4)
    x0, y0 = (3, 9) if big else (5, 12)
    ic.box(x0, y0, w, h, d, body)                     # 機身
    top = y0                                          # 機身頂面後緣
    # 受料斗：坐在機身頂上的漏斗，斗口比機身寬、往下收窄（左亮右暗）
    funnel = rgb("#6a6e74")
    fh = 6 if big else 5
    fw = w + 2
    fx = x0 - 1 + d // 2
    for j in range(fh):
        inset = j
        for i in range(inset, fw - inset):
            k = (i - inset) / max(1, fw - 2 * inset - 1)
            c = shade(funnel, 1.25) if k < 0.3 else (funnel if k < 0.7 else shade(funnel, 0.75))
            ic.put(fx + i, top - fh + 1 + j, c)
    ic.rect(fx - 1, top - fh, fw + 2, 2, shade(funnel, 0.35))   # 斗口外緣
    ic.rect(fx + 1, top - fh + 1, fw - 2, 1, rgb("#1a1a1a"))   # 斗口裡面（暗）
    ic.rect(fx + 3, top - fh + 1, 4, 1, rgb("#8a6a3a"))        # 斗裡的碎石
    # 機身上的橫帶、檢修口、指示燈
    fy = y0 + d
    for k in range(2 if not big else 3):
        ic.rect(x0 + 1, fy + 3 + k * 4, w - 2, 1, stripe)
    ic.rect(x0 + 2, fy + h - 5, 3, 3, rgb("#20242a"))
    ic.rect(x0 + w - 4, fy + 1, 2, 2, rgb("#c03020"))
    # 出料輸送帶（從機身右下往右上）
    belt, frame = rgb("#262626"), rgb("#7a7e84")
    bx, by = x0 + w + d - 2, fy + h - 3
    n = 30 - bx
    for k in range(n):
        x, y = bx + k, by - k
        ic.put(x, y, belt)
        ic.put(x, y + 1, belt)
        ic.put(x, y + 2, frame)
    ic.rect(bx + n - 2, by - n - 1, 2, 2, rgb("#8a6a3a"))
    for k in (2, n - 2):
        ic.rect(bx + k, by - k + 3, 1, 30 - (by - k + 3), frame)
    ic.save(name)


def plant():
    ic = Icon()
    silo, cap = rgb("#c8ccd2"), rgb("#8a9098")
    for sx in (2, 22):                            # 兩座儲料塔（圓柱：左亮右暗）
        for j in range(4, 28):
            for i in range(8):
                c = silo if i < 3 else shade(silo, 0.85 if i < 6 else 0.68)
                ic.put(sx + i, j, c)
        ic.rect(sx + 1, 3, 6, 1, cap)
        ic.rect(sx, 4, 8, 1, cap)
        for j in (9, 15, 21):
            ic.rect(sx, j, 8, 1, shade(silo, 0.6))
        ic.rect(sx, 27, 8, 1, shade(silo, 0.4))
    ic.box(8, 12, 14, 14, 4, rgb("#3a7ab0"))     # 廠房
    ic.rect(9, 18, 12, 2, rgb("#a8c8e8"))          # 一整排橫向窗帶
    for i in (12, 15, 18):
        ic.rect(i, 18, 1, 2, rgb("#3a7ab0"))
    ic.rect(10, 22, 5, 7, rgb("#20242a"))          # 鐵捲門（偏左）
    for j in (23, 25, 27):
        ic.rect(10, j, 5, 1, rgb("#40464e"))
    ic.rect(10, 8, 12, 1, rgb("#262626"))          # 屋頂到塔的輸送帶
    ic.save("rockmech_icon_plant.png")


def belt():
    ic = Icon()
    frame, belt_c, roller = rgb("#8a8e94"), rgb("#262626"), rgb("#5a5e64")
    for k in range(24):                           # 斜向輸送帶：上皮帶、框、下皮帶
        x, y = 3 + k, 22 - k * 3 // 4
        ic.put(x, y, belt_c)
        ic.put(x, y + 1, belt_c)
        ic.put(x, y + 2, frame)
        ic.put(x, y + 3, shade(frame, 0.7))
    for k in range(0, 24, 4):                     # 托輥
        x, y = 3 + k, 22 - k * 3 // 4
        ic.put(x, y + 2, roller)
    for x, top in ((6, 22), (14, 16), (22, 10)):   # 支架
        ic.rect(x, top + 4, 1, 28 - top - 4, frame)
        ic.rect(x - 1, 28, 3, 1, shade(frame, 0.6))
    ic.rect(26, 2, 4, 3, rgb("#8a6a3a"))           # 帶頭上的料
    ic.rect(2, 22, 3, 3, roller)                   # 尾輪
    ic.save("rockmech_icon_belt.png")


def locker():
    ic = Icon()
    ic.box(7, 4, 15, 24, 4, rgb("#6a7078"))
    ic.rect(14, 9, 1, 22, shade(rgb("#6a7078"), 0.45))   # 兩扇門的中縫
    for x in (9, 16):
        for j in (10, 12, 14):                            # 通風口
            ic.rect(x, j, 4, 1, shade(rgb("#6a7078"), 0.55))
    ic.rect(12, 18, 1, 3, rgb("#e0c040"))                  # 把手
    ic.rect(16, 18, 1, 3, rgb("#e0c040"))
    ic.save("rockmech_icon_locker.png")


def badge():
    """施工單角標：右下角 15×16 的夾板＋紙（約整個圖示的 1/4），深色外框讓它在任何底圖上都看得清楚"""
    ic = Icon()
    ox, oy = 16, 15
    out, board, paper, line, clip = rgb("#101010"), rgb("#9a6a30"), rgb("#f4f0e4"), rgb("#7a7a7a"), rgb("#b0b4ba")
    ic.rect(ox, oy + 1, 15, 16, out)               # 外框
    ic.rect(ox + 1, oy + 2, 13, 14, board)          # 夾板
    ic.rect(ox + 3, oy + 4, 9, 11, paper)           # 紙
    for j in (6, 8, 10, 12):                      # 字
        ic.rect(ox + 4, oy + j, 7 if j != 12 else 4, 1, line)
    ic.rect(ox + 8, oy + 12, 3, 2, rgb("#c03020"))   # 紅色印章
    ic.rect(ox + 4, oy, 7, 3, out)                   # 夾子
    ic.rect(ox + 5, oy + 1, 5, 2, clip)
    ic.save("rockmech_order_badge.png")


crusher(rgb("#d8a020"), rgb("#7a5a10"), "rockmech_icon_crusher.png")
crusher(rgb("#5a6068"), rgb("#f0c020"), "rockmech_icon_crusher_big.png", big=True)
plant()
belt()
locker()
badge()
print("ok", OUT)
