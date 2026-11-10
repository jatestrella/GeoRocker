# 新聞快訊的點陣圖（market.lua 的事件）：80×50，上面台標條、中間畫面、下面標題條（中文標題由遊戲疊字）
# 用法：python tools/news_art.py  → mods/rockmech/textures/rockmech_news_<事件>.png
import math, os, random
from PIL import Image, ImageDraw

OUT = os.path.join(os.path.dirname(__file__), '..', 'mods', 'rockmech', 'textures')
W, H, TOP, BOT = 80, 50, 8, 8
SH = H - TOP - BOT          # 畫面高 34

FONT = {  # 3×5 點陣字
    'G': ['111', '100', '101', '101', '111'], 'R': ['110', '101', '110', '101', '101'],
    'N': ['101', '111', '111', '111', '101'], 'E': ['111', '100', '110', '100', '111'],
    'W': ['101', '101', '111', '111', '101'], 'S': ['111', '100', '111', '001', '111'],
    'L': ['100', '100', '100', '100', '111'], 'I': ['111', '010', '010', '010', '111'],
    'V': ['101', '101', '101', '101', '010'], 'C': ['111', '100', '100', '100', '111'],
    'O': ['111', '101', '101', '101', '111'], '2': ['111', '001', '111', '100', '111'],
    '$': ['111', '110', '111', '011', '111'], 'A': ['111', '101', '111', '101', '101'], ' ': ['000'] * 5,
}

def text(d, x, y, s, c):
    for ch in s:
        g = FONT[ch]
        for j, row in enumerate(g):
            for i, b in enumerate(row):
                if b == '1': d.point((x + i, y + j), c)
        x += len(g[0]) + 1
    return x

def sky(d, top, bottom, h=SH):
    for y in range(h):
        t = y / max(1, h - 1)
        c = tuple(int(top[k] + (bottom[k] - top[k]) * t) for k in range(3))
        d.line([(0, y), (W - 1, y)], c)

def ground(d, y0, c, c2=None, seed=1):
    r = random.Random(seed)
    d.rectangle([0, y0, W - 1, SH - 1], c)
    if c2:
        for _ in range(60): d.point((r.randrange(W), r.randrange(y0, SH)), c2)

def disc(d, x, y, r, c): d.ellipse([x - r, y - r, x + r, y + r], c)

def tank(d, x, y, body, dark):
    d.rectangle([x, y - 4, x + 15, y], body)                # 車身
    d.rectangle([x + 4, y - 7, x + 10, y - 4], body)        # 砲塔
    d.line([(x + 10, y - 6), (x + 19, y - 8)], dark)        # 砲管
    d.rectangle([x - 1, y, x + 16, y + 2], dark)            # 履帶
    for i in range(x + 1, x + 16, 3): d.point((i, y + 1), (90, 90, 90))

def boom(d, x, y, r=6):
    disc(d, x, y, r, (230, 80, 30)); disc(d, x, y - 1, r - 2, (255, 170, 40)); disc(d, x, y - 1, max(1, r - 4), (255, 240, 160))

def smoke(d, x, y, n=4, c=(90, 90, 95)):
    for i in range(n): disc(d, x + i * 2 - n, y - i * 4, 3 + i, c)

def derrick(d, x, y, c):
    d.line([(x, y), (x + 4, y - 14)], c); d.line([(x + 8, y), (x + 4, y - 14)], c)
    for k in range(3): d.line([(x + 1 + k, y - 4 - k * 4), (x + 7 - k, y - 4 - k * 4)], c)

def barrel(d, x, y, c):
    d.rectangle([x, y - 7, x + 5, y], c)
    d.line([(x, y - 5), (x + 5, y - 5)], (40, 40, 40)); d.line([(x, y - 2), (x + 5, y - 2)], (40, 40, 40))

def plant(d, x, y, wall=(150, 150, 155), smoke_on=True):
    d.rectangle([x, y - 8, x + 18, y], wall)
    d.rectangle([x + 13, y - 20, x + 16, y - 8], (170, 60, 50)); d.line([(x + 13, y - 17), (x + 16, y - 17)], (230, 230, 230))
    d.polygon([(x + 2, y - 8), (x + 4, y - 18), (x + 9, y - 18), (x + 11, y - 8)], (200, 200, 200))   # 冷卻塔
    for wx in range(x + 2, x + 12, 3): d.point((wx, y - 4), (60, 80, 120))
    if smoke_on: smoke(d, x + 15, y - 22, 3, (120, 120, 120))

def arrow(d, x, y, up, c):
    if up:
        d.polygon([(x, y), (x + 5, y - 6), (x + 10, y)], c); d.rectangle([x + 3, y, x + 7, y + 6], c)
    else:
        d.polygon([(x, y), (x + 5, y + 6), (x + 10, y)], c); d.rectangle([x + 3, y - 6, x + 7, y], c)

def thermo(d, x, y, level, c):
    d.rectangle([x, y - 16, x + 3, y], (240, 240, 240)); disc(d, x + 1, y + 1, 2, c)
    d.rectangle([x + 1, y - level, x + 2, y], c)

# ---- 各事件的畫面（80×34）----
def miyi_war(d):
    sky(d, (120, 40, 30), (240, 150, 60)); ground(d, 26, (200, 160, 90), (170, 130, 70), 2)
    derrick(d, 56, 26, (40, 30, 30)); boom(d, 60, 10, 5); smoke(d, 62, 5, 3, (60, 50, 50))
    tank(d, 10, 26, (110, 100, 60), (50, 45, 30)); boom(d, 38, 22, 4)

def wue_war(d):
    sky(d, (90, 140, 210), (170, 200, 235)); ground(d, 22, (220, 180, 60), (180, 140, 40), 3)
    for x in range(0, W, 2): d.line([(x, 22), (x, 20)], (200, 160, 50))
    tank(d, 44, 29, (90, 100, 80), (40, 45, 40)); smoke(d, 16, 18, 5, (80, 80, 85)); smoke(d, 70, 16, 4, (100, 100, 105))
    boom(d, 22, 24, 5)

def opec_cut(d):
    sky(d, (230, 190, 120), (250, 220, 160)); ground(d, 26, (190, 150, 90), (160, 120, 70), 4)
    # 抽油機
    d.line([(18, 26), (22, 14)], (40, 40, 40)); d.line([(26, 26), (22, 14)], (40, 40, 40))
    d.line([(10, 12), (34, 16)], (30, 30, 30)); d.rectangle([7, 10, 11, 16], (30, 30, 30)); d.line([(33, 16), (33, 26)], (60, 60, 60))
    for i, x in enumerate((44, 51, 58)): barrel(d, x, 26, (40, 90, 170))
    arrow(d, 66, 12, True, (40, 200, 60))

def cold_wave(d):
    sky(d, (150, 180, 220), (210, 225, 245)); ground(d, 25, (245, 248, 255), (210, 220, 235), 5)
    plant(d, 46, 25, smoke_on=True); thermo(d, 12, 22, 3, (40, 90, 220))
    r = random.Random(7)
    for _ in range(40):
        x, y = r.randrange(W), r.randrange(24); d.point((x, y), (255, 255, 255))
    for x, y in ((28, 6), (68, 9), (36, 16)):
        d.line([(x - 2, y), (x + 2, y)], (255, 255, 255)); d.line([(x, y - 2), (x, y + 2)], (255, 255, 255))

def warm_winter(d):
    sky(d, (90, 170, 240), (170, 215, 250)); ground(d, 25, (90, 170, 70), (70, 140, 50), 6)
    disc(d, 62, 9, 6, (255, 220, 60))
    for a in range(0, 360, 45):
        x, y = 62 + 9 * math.cos(math.radians(a)), 9 + 9 * math.sin(math.radians(a)); d.point((round(x), round(y)), (255, 200, 40))
    thermo(d, 12, 22, 14, (220, 40, 40))
    for x in (30, 38, 47): d.point((x, 24), (240, 80, 120)); d.point((x, 23), (250, 220, 60))

def typhoon(d):
    sky(d, (45, 50, 65), (85, 90, 105))
    # 颱風眼：兩條白色螺旋臂
    cx, cy = 22, 11
    for arm in (0, math.pi):
        for k in range(40):
            a = arm + k * 0.16; r = 1.5 + k * 0.28
            disc(d, round(cx + r * math.cos(a)), round(cy + r * math.sin(a) * 0.75), 1, (225, 230, 240))
    disc(d, cx, cy, 1, (45, 50, 65))
    # 海浪
    d.rectangle([0, 23, W - 1, SH - 1], (35, 65, 110))
    for x in range(W):
        y = 22 + round(2 * math.sin(x / 3.0))
        d.line([(x, y), (x, y + 1)], (230, 240, 250)); d.line([(x, y + 2), (x, 24)], (60, 100, 150))
    # 傾斜的貨船
    d.polygon([(46, 21), (70, 25), (68, 29), (48, 27)], (170, 55, 40)); d.polygon([(54, 22), (60, 23), (59, 17), (54, 16)], (225, 225, 225))
    r = random.Random(9)
    for _ in range(35):
        x, y = r.randrange(W), r.randrange(22); d.line([(x, y), (x - 2, y + 3)], (140, 160, 195))

def coal_cut(d):
    sky(d, (140, 180, 220), (200, 220, 240)); ground(d, 27, (120, 120, 110), (90, 90, 85), 10)
    plant(d, 18, 27, smoke_on=True)
    d.ellipse([48, 4, 72, 28], outline=(220, 30, 30), width=3); d.line([(52, 24), (68, 8)], (220, 30, 30), 3)
    disc(d, 60, 16, 3, (30, 30, 30))   # 煤

def carbon_fee(d):
    sky(d, (150, 160, 170), (200, 205, 210)); ground(d, 27, (110, 110, 105))
    plant(d, 6, 27, smoke_on=False)
    for i, (x, y, r) in enumerate(((26, 10, 5), (34, 7, 6), (43, 10, 5), (35, 13, 5))): disc(d, x, y, r, (90, 90, 95))
    text(d, 28, 8, 'CO2', (255, 255, 255))
    disc(d, 64, 18, 8, (240, 190, 40)); disc(d, 64, 18, 6, (255, 215, 80)); text(d, 63, 16, '$', (150, 100, 10))

def recession(d):
    d.rectangle([0, 0, W - 1, SH - 1], (15, 20, 30))
    for x in range(0, W, 8): d.line([(x, 0), (x, SH - 1)], (30, 40, 55))
    for y in range(0, SH, 6): d.line([(0, y), (W - 1, y)], (30, 40, 55))
    pts = [(2, 8), (12, 6), (20, 12), (28, 10), (38, 18), (46, 16), (56, 24), (66, 22), (76, 30)]
    d.line(pts, (240, 60, 60), 2)
    arrow(d, 62, 8, False, (240, 60, 60))

def infrastructure(d):
    sky(d, (100, 170, 235), (180, 215, 245)); ground(d, 27, (150, 130, 100), (120, 100, 80), 11)
    # 塔吊
    d.rectangle([14, 4, 16, 27], (240, 190, 30)); d.line([(6, 4), (44, 4)], (240, 190, 30), 2)
    d.rectangle([4, 4, 8, 8], (80, 80, 80)); d.line([(36, 5), (36, 14)], (60, 60, 60)); d.rectangle([33, 14, 39, 17], (150, 150, 160))
    for k in range(5, 27, 4): d.line([(14, k), (16, k + 3)], (200, 150, 20))
    # 蓋到一半的大樓（鋼骨）
    for x in (50, 58, 66, 74):
        d.line([(x, 27), (x, 10)], (120, 120, 130))
    for y in (10, 15, 20, 25): d.line([(50, y), (74, y)], (120, 120, 130))
    d.rectangle([50, 21, 74, 27], (180, 180, 185))

def cement_works(d, x, y, smoke_on=True):
    # 水泥廠：兩支筒倉、斜放的旋窯、預熱塔
    d.rectangle([x, y - 16, x + 5, y], (205, 205, 200)); d.rectangle([x + 7, y - 16, x + 12, y], (205, 205, 200))
    d.rectangle([x + 15, y - 22, x + 19, y], (170, 170, 175))
    d.line([(x + 19, y - 6), (x + 36, y - 2)], (150, 140, 130), 3)
    if smoke_on: smoke(d, x + 17, y - 26, 3, (200, 200, 200))

def housing_cool(d):
    sky(d, (150, 160, 175), (205, 210, 215)); ground(d, 27, (120, 120, 115))
    for x, h in ((4, 14), (14, 20), (26, 11), (36, 17)):
        d.rectangle([x, 27 - h, x + 8, 27], (175, 170, 160))
        for wy in range(27 - h + 2, 26, 3):
            for wx in range(x + 1, x + 8, 3): d.point((wx, wy), (70, 80, 100))
    d.rectangle([24, 2, 44, 8], (240, 240, 235)); text(d, 26, 3, 'SALE', (200, 30, 40))
    arrow(d, 60, 10, False, (240, 60, 60))

def cement_export(d):
    sky(d, (100, 170, 235), (180, 215, 245))
    d.rectangle([0, 22, W - 1, SH - 1], (40, 90, 150))
    for x in range(0, W, 6): d.line([(x, 25), (x + 3, 25)], (90, 140, 200))
    d.polygon([(6, 18), (54, 18), (50, 25), (10, 25)], (60, 60, 70))          # 船身
    for x in (12, 22, 32): d.rectangle([x, 12, x + 7, 18], (205, 205, 200))   # 水泥艙
    d.rectangle([44, 9, 50, 18], (230, 230, 230))
    arrow(d, 62, 14, True, (60, 200, 90))

def kiln_overhaul(d):
    sky(d, (140, 180, 220), (200, 220, 240)); ground(d, 27, (150, 150, 140), (120, 120, 110), 12)
    cement_works(d, 8, 27, smoke_on=False)
    for x in range(50, 76, 6): d.polygon([(x, 27), (x + 3, 19), (x + 5, 19), (x + 2, 27)], (240, 140, 30))   # 三角錐
    d.rectangle([48, 14, 77, 17], (240, 200, 40))
    for x in range(48, 78, 6): d.rectangle([x, 14, x + 2, 17], (30, 30, 30))

SCENES = {'miyi_war': miyi_war, 'wue_war': wue_war, 'opec_cut': opec_cut, 'cold_wave': cold_wave,
          'warm_winter': warm_winter, 'typhoon': typhoon, 'coal_cut': coal_cut, 'carbon_fee': carbon_fee,
          'recession': recession, 'infrastructure': infrastructure,
          'housing_cool': housing_cool, 'cement_export': cement_export, 'kiln_overhaul': kiln_overhaul}

def frame(scene):
    im = Image.new('RGBA', (W, H), (0, 0, 0, 255))
    d = ImageDraw.Draw(im)
    # 台標條
    d.rectangle([0, 0, W - 1, TOP - 1], (16, 32, 70))
    d.rectangle([1, 1, 29, 6], (200, 30, 40))
    text(d, 2, 1, 'GR NEWS', (255, 255, 255))
    d.rectangle([60, 2, 62, 4], (255, 40, 40)); text(d, 64, 1, 'LIVE', (255, 255, 255))
    # 畫面
    s = Image.new('RGB', (W, SH)); scene(ImageDraw.Draw(s)); im.paste(s, (0, TOP))
    # 標題條：左邊紅底（疊「快訊」），右邊白底（疊事件名稱）
    d.rectangle([0, H - BOT, 17, H - 1], (200, 30, 40)); d.rectangle([18, H - BOT, W - 1, H - 1], (245, 245, 240))
    d.line([(0, H - BOT), (W - 1, H - BOT)], (250, 200, 40))
    return im

if __name__ == '__main__':
    for k, f in SCENES.items():
        frame(f).save(os.path.join(OUT, 'rockmech_news_%s.png' % k))
    print('wrote', len(SCENES))
