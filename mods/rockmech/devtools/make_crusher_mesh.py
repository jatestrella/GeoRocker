# -*- coding: utf-8 -*-
# 破碎站的模型（OBJ）：一般破碎站（露天的顎式破碎機機台）、大型破碎站（一棟破碎廠房）。
# 座標單位 = 1 格（1 m），原點在機身那一格的中心，地面 y = −0.5；受料倉在 +Z（方塊用 facedir 轉向受料倉）。
# 每一種材質一個群組（g）＋材質（usemtl）：Luanti 讀 OBJ 時要有群組名才會分成不同的面組，
# 各面組照第一次出現的順序對應節點定義 tiles 的一個。貼圖座標用公尺：貼圖每 1 m 重複一次。
# 用法：python make_crusher_mesh.py  → 寫到 ../models/
import math, os

class Mesh:
    def __init__(self, names):
        self.names = names
        self.v, self.vt, self.vn, self.faces, self.order = [], [], [], {}, []
    def quad(self, mat, pts, n, uvs):
        if mat not in self.faces:
            self.faces[mat] = []; self.order.append(mat)
        self.vn.append(n); ni = len(self.vn)
        idx = []
        for p, uv in zip(pts, uvs):
            self.v.append(p); self.vt.append(uv)
            idx.append((len(self.v), len(self.vt), ni))
        self.faces[mat].append(idx)
    def box(self, mat, x0, y0, z0, x1, y1, z1):
        self.quad(mat, [(x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1)], (0, 0, 1), [(x0, y0), (x1, y0), (x1, y1), (x0, y1)])
        self.quad(mat, [(x1, y0, z0), (x0, y0, z0), (x0, y1, z0), (x1, y1, z0)], (0, 0, -1), [(-x1, y0), (-x0, y0), (-x0, y1), (-x1, y1)])
        self.quad(mat, [(x1, y0, z1), (x1, y0, z0), (x1, y1, z0), (x1, y1, z1)], (1, 0, 0), [(-z1, y0), (-z0, y0), (-z0, y1), (-z1, y1)])
        self.quad(mat, [(x0, y0, z0), (x0, y0, z1), (x0, y1, z1), (x0, y1, z0)], (-1, 0, 0), [(z0, y0), (z1, y0), (z1, y1), (z0, y1)])
        self.quad(mat, [(x0, y1, z1), (x1, y1, z1), (x1, y1, z0), (x0, y1, z0)], (0, 1, 0), [(x0, -z1), (x1, -z1), (x1, -z0), (x0, -z0)])
        self.quad(mat, [(x0, y0, z0), (x1, y0, z0), (x1, y0, z1), (x0, y0, z1)], (0, -1, 0), [(x0, z0), (x1, z0), (x1, z1), (x0, z1)])
    def panel(self, mat, pts, uvs=None):
        # 任意四邊形（屋頂斜面、三角牆）：法向由頂點算
        a, b, c = pts[0], pts[1], pts[2]
        u = [b[i] - a[i] for i in range(3)]; v = [c[i] - a[i] for i in range(3)]
        n = (u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0])
        l = math.sqrt(sum(q * q for q in n)) or 1
        n = tuple(q / l for q in n)
        if uvs is None:
            # 投影到法向以外最大的兩軸
            ax = sorted(range(3), key=lambda i: abs(n[i]))[:2]
            uvs = [(p[ax[0]], p[ax[1]]) for p in pts]
        self.quad(mat, pts, n, uvs)
    def cyl(self, mat, axis, a0, a1, c1, c2, r, seg=20, caps=True):
        # axis = 'x' 或 'y'：沿這一軸的圓柱，c1、c2 是另外兩軸的中心
        def P(t, s, ang):
            if axis == 'x': return (t, c1 + r * math.cos(ang) * s, c2 + r * math.sin(ang) * s)
            return (c1 + r * math.cos(ang) * s, t, c2 + r * math.sin(ang) * s)
        for i in range(seg):
            g0, g1 = 2 * math.pi * i / seg, 2 * math.pi * (i + 1) / seg
            p = [P(a0, 1, g0), P(a0, 1, g1), P(a1, 1, g1), P(a1, 1, g0)]
            gm = (g0 + g1) / 2
            n = (0, math.cos(gm), math.sin(gm)) if axis == 'x' else (math.cos(gm), 0, math.sin(gm))
            self.quad(mat, p, n, [(i / seg * 4, a0), ((i + 1) / seg * 4, a0), ((i + 1) / seg * 4, a1), (i / seg * 4, a1)])
            if caps:
                for t, sg in ((a1, 1), (a0, -1)):
                    q = [P(t, 0, g0), P(t, 1, g0), P(t, 1, g1), P(t, 0, g0)]
                    nn = (sg, 0, 0) if axis == 'x' else (0, sg, 0)
                    uv = [(0.5 + 0.5 * math.cos(g0) * k, 0.5 + 0.5 * math.sin(g0) * k) for k in (0, 1)] + \
                         [(0.5 + 0.5 * math.cos(g1), 0.5 + 0.5 * math.sin(g1)), (0.5, 0.5)]
                    self.quad(mat, q, nn, uv)
    def write(self, path):
        with open(path, 'w', newline='\n') as f:
            f.write('# rockmech crusher (devtools/make_crusher_mesh.py)\n')
            for p in self.v: f.write('v %.4f %.4f %.4f\n' % p)
            for t in self.vt: f.write('vt %.4f %.4f\n' % t)
            for n in self.vn: f.write('vn %.4f %.4f %.4f\n' % n)
            for m in self.order:
                f.write('g %s\nusemtl %s\n' % (self.names[m], self.names[m]))
                for q in self.faces[m]:
                    f.write('f ' + ' '.join('%d/%d/%d' % t for t in q) + '\n')
        print('wrote', os.path.basename(path), 'tiles:', [self.names[m] for m in self.order])

# ---------- 一般破碎站：露天機台 ----------
FRAME, BODY, DECK, WHEEL, MOTOR, BELT, RAIL, CHUTE = range(8)
def machine():
    m = Mesh(['frame', 'body', 'deck', 'wheel', 'motor', 'belt', 'rail', 'chute'])
    H = 0.6
    for sx in (-1, 1):
        for sz in (-1, 1):
            m.box(FRAME, sx * 1.3 - 0.09, -0.5, sz * 1.3 - 0.09, sx * 1.3 + 0.09, H, sz * 1.3 + 0.09)
    m.box(FRAME, -1.45, H - 0.15, -1.45, 1.45, H, -1.3)
    m.box(BODY, -0.75, H + 0.08, -0.55, 0.75, 2.0, 0.75)
    m.box(BODY, -0.6, 2.0, -0.4, 0.6, 2.22, 0.6)
    m.box(DECK, -1.45, H, -1.45, 1.45, H + 0.08, 1.45)
    for sx in (-1, 1):
        xa, xb = (0.78, 0.92) if sx > 0 else (-0.92, -0.78)
        m.cyl(WHEEL, 'x', xa, xb, 1.45, 0.1, 0.55)
    m.box(MOTOR, 0.25, H + 0.08, -1.35, 0.95, 1.15, -0.85)
    m.cyl(MOTOR, 'x', 0.95, 1.05, 0.92, -1.1, 0.16, 12)
    m.box(BELT, -0.35, H + 0.15, -1.6, 0.35, H + 0.27, -0.5)
    m.box(FRAME, -0.4, H + 0.08, -1.6, -0.35, H + 0.3, -0.5)
    m.box(FRAME, 0.35, H + 0.08, -1.6, 0.4, H + 0.3, -0.5)
    m.box(RAIL, 0.92, 0.95, -1.05, 1.02, 1.6, 0.15)
    for x in (-1.4, -0.45, 0.45, 1.4):
        m.box(RAIL, x - 0.03, H + 0.08, -1.43, x + 0.03, H + 1.0, -1.37)
    for sx in (-1, 1):
        for z in (-1.4, -0.3, 0.8, 1.4):
            m.box(RAIL, sx * 1.4 - 0.03, H + 0.08, z - 0.03, sx * 1.4 + 0.03, H + 1.0, z + 0.03)
        m.box(RAIL, sx * 1.4 - 0.03, H + 0.95, -1.43, sx * 1.4 + 0.03, H + 1.02, 1.43)
        m.box(RAIL, sx * 1.4 - 0.025, H + 0.5, -1.43, sx * 1.4 + 0.025, H + 0.55, 1.43)
    m.box(RAIL, -1.43, H + 0.95, -1.43, 1.43, H + 1.02, -1.37)
    m.box(RAIL, -1.43, H + 0.5, -1.43, 1.43, H + 0.55, -1.37)
    m.box(CHUTE, -0.75, 1.95, 0.6, 0.75, 2.05, 1.45)
    m.box(CHUTE, -0.85, 1.95, 0.6, -0.75, 2.45, 1.45)
    m.box(CHUTE, 0.75, 1.95, 0.6, 0.85, 2.45, 1.45)
    return m

# ---------- 大型破碎站：破碎廠房 ----------
# 材質：基座、外牆、屋頂、鋼柱、捲門、窗帶、皮帶廊道、集塵筒倉、警示條
PLINTH, WALL, ROOF, COLUMN, DOOR, WINDOW, GALLERY, SILO, HAZARD = range(9)
def plant():
    m = Mesh(['plinth', 'wall', 'roof', 'column', 'door', 'window', 'gallery', 'silo', 'hazard'])
    X0, X1, Z0, Z1 = -1.4, 0.7, -1.3, 1.3       # 外牆（右邊留給集塵筒倉）
    XM = (X0 + X1) / 2                           # 屋脊
    Y0, YE, YR = -0.2, 2.3, 2.95                 # 牆底、簷口、屋脊
    m.box(PLINTH, -1.45, -0.5, -1.45, 1.45, Y0, 1.45)
    # 外牆（前面 +Z 留捲門的開口另外蓋）
    m.box(WALL, X0, Y0, Z0, X1, YE, Z1 - 0.02)
    # 四角鋼柱、簷口的鋼梁
    for sx in (-1, 1):
        for sz in (-1, 1):
            cx = X0 - 0.02 if sx < 0 else X1 + 0.02
            m.box(COLUMN, cx - 0.08, Y0, sz * 1.32 - 0.08, cx + 0.08, YE, sz * 1.32 + 0.08)
    m.box(COLUMN, X0 - 0.04, YE - 0.12, Z0 - 0.04, X1 + 0.04, YE, Z1 + 0.04)
    # 窗帶（兩側高處）、通風百葉（窗帶下面）
    for x in (X0 - 0.01, X1 + 0.01):
        m.box(WINDOW, x - 0.01, 1.75, -1.0, x + 0.01, 2.05, 1.0)
    # 斜屋頂（屋脊沿 Z：前後兩坡朝 ±X），屋簷伸出 0.15
    o = 0.15
    m.panel(ROOF, [(X0 - o, YE - 0.05, Z1 + o), (XM, YR, Z1 + o), (XM, YR, Z0 - o), (X0 - o, YE - 0.05, Z0 - o)])
    m.panel(ROOF, [(XM, YR, Z1 + o), (X1 + o, YE - 0.05, Z1 + o), (X1 + o, YE - 0.05, Z0 - o), (XM, YR, Z0 - o)])
    # 屋頂底面（從下面看）
    m.panel(ROOF, [(X0 - o, YE - 0.05, Z0 - o), (XM, YR, Z0 - o), (XM, YR, Z1 + o), (X0 - o, YE - 0.05, Z1 + o)])
    m.panel(ROOF, [(XM, YR, Z0 - o), (X1 + o, YE - 0.05, Z0 - o), (X1 + o, YE - 0.05, Z1 + o), (XM, YR, Z1 + o)])
    # 前後的三角牆
    for z, sg in ((Z1 - 0.02, 1), (Z0, -1)):
        tri = [(X0, YE, z), (X1, YE, z), (XM, YR - 0.05, z), (XM, YR - 0.05, z)]
        if sg < 0: tri = [tri[1], tri[0], tri[2], tri[3]]
        m.panel(WALL, tri)
    # 前面（朝受料倉）的捲門進料口、周圍的黃黑警示條
    m.box(HAZARD, XM - 0.85, Y0, Z1 - 0.02, XM + 0.85, 1.95, Z1 + 0.02)
    m.box(DOOR, XM - 0.7, Y0, Z1 + 0.02, XM + 0.7, 1.8, Z1 + 0.04)
    # 後面：出料皮帶廊道（有頂蓋的斜皮帶，一段一段往上）
    for k in range(4):
        z0, z1 = Z0 - 0.35 * (k + 1), Z0 - 0.35 * k
        y = 0.6 + 0.18 * k
        m.box(GALLERY, XM - 0.4, y, z0, XM + 0.4, y + 0.55, z1)
    m.box(COLUMN, XM - 0.35, -0.5, Z0 - 1.25, XM - 0.25, 1.0, Z0 - 1.15)
    m.box(COLUMN, XM + 0.25, -0.5, Z0 - 1.25, XM + 0.35, 1.0, Z0 - 1.15)
    # 側面的集塵筒倉（圓柱）、錐底、頂上的排氣管
    SX = 1.08
    m.cyl(SILO, 'y', 0.7, 2.6, SX, -0.5, 0.33, 16)
    m.cyl(COLUMN, 'y', -0.2, 0.7, SX, -0.5, 0.08, 8)
    m.cyl(COLUMN, 'y', 2.6, 3.2, SX, -0.5, 0.06, 8)
    m.box(GALLERY, X1, 1.6, -0.62, SX - 0.3, 1.8, -0.38)      # 集塵風管接到廠房
    return m

here = os.path.dirname(os.path.abspath(__file__))
out = os.path.join(here, '..', 'models')
os.makedirs(out, exist_ok=True)
machine().write(os.path.join(out, 'rockmech_crusher.obj'))
plant().write(os.path.join(out, 'rockmech_crusher_big.obj'))
