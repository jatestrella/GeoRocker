# -*- coding: utf-8 -*-
# 破碎站的模型（OBJ）：一般破碎站（顎式破碎機）、大型破碎站（加控制室）。
# 座標單位 = 1 格（1 m），原點在機身那一格的中心，地面 y = −0.5；受料倉在 +Z（方塊用 facedir 轉向受料倉）。
# 每一種材質（usemtl）對應節點定義 tiles 的一個（照第一次出現的順序）。貼圖座標用公尺：貼圖每 1 m 重複一次。
# 用法：python make_crusher_mesh.py  → 寫到 ../models/
import math, os

class Mesh:
    def __init__(self):
        self.v, self.vt, self.vn, self.faces = [], [], [], {}
        self.order = []
    def _v(self, p):
        self.v.append(p); return len(self.v)
    def _vt(self, uv):
        self.vt.append(uv); return len(self.vt)
    def _vn(self, n):
        self.vn.append(n); return len(self.vn)
    def quad(self, mat, pts, n, uvs):
        if mat not in self.faces:
            self.faces[mat] = []; self.order.append(mat)
        ni = self._vn(n)
        idx = [(self._v(p), self._vt(uv), ni) for p, uv in zip(pts, uvs)]
        self.faces[mat].append(idx)
    def box(self, mat, x0, y0, z0, x1, y1, z1):
        # 六面，法向朝外，頂點逆時針（從外面看）
        X = [(x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1)]  # +Z
        self.quad(mat, X, (0, 0, 1), [(x0, y0), (x1, y0), (x1, y1), (x0, y1)])
        X = [(x1, y0, z0), (x0, y0, z0), (x0, y1, z0), (x1, y1, z0)]  # −Z
        self.quad(mat, X, (0, 0, -1), [(-x1, y0), (-x0, y0), (-x0, y1), (-x1, y1)])
        X = [(x1, y0, z1), (x1, y0, z0), (x1, y1, z0), (x1, y1, z1)]  # +X
        self.quad(mat, X, (1, 0, 0), [(-z1, y0), (-z0, y0), (-z0, y1), (-z1, y1)])
        X = [(x0, y0, z0), (x0, y0, z1), (x0, y1, z1), (x0, y1, z0)]  # −X
        self.quad(mat, X, (-1, 0, 0), [(z0, y0), (z1, y0), (z1, y1), (z0, y1)])
        X = [(x0, y1, z1), (x1, y1, z1), (x1, y1, z0), (x0, y1, z0)]  # +Y
        self.quad(mat, X, (0, 1, 0), [(x0, -z1), (x1, -z1), (x1, -z0), (x0, -z0)])
        X = [(x0, y0, z0), (x1, y0, z0), (x1, y0, z1), (x0, y0, z1)]  # −Y
        self.quad(mat, X, (0, -1, 0), [(x0, z0), (x1, z0), (x1, z1), (x0, z1)])
    def cyl_x(self, mat, xa, xb, cy, cz, r, seg=20):
        # 沿 X 軸的圓柱（飛輪）：側面一圈＋兩個端面（扇形用四邊形：中心點重複）
        pts = [(cy + r * math.cos(2 * math.pi * i / seg), cz + r * math.sin(2 * math.pi * i / seg)) for i in range(seg)]
        for i in range(seg):
            (y0, z0), (y1, z1) = pts[i], pts[(i + 1) % seg]
            a = 2 * math.pi * (i + 0.5) / seg
            n = (0, math.cos(a), math.sin(a))
            self.quad(mat, [(xa, y0, z0), (xa, y1, z1), (xb, y1, z1), (xb, y0, z0)], n,
                      [(0, i / seg * 4), (0, (i + 1) / seg * 4), (1, (i + 1) / seg * 4), (1, i / seg * 4)])
        for x, sgn in ((xb, 1), (xa, -1)):
            for i in range(seg):
                (y0, z0), (y1, z1) = pts[i], pts[(i + 1) % seg]
                p = [(x, cy, cz), (x, y0, z0), (x, y1, z1), (x, cy, cz)]
                if sgn < 0: p = [p[0], p[2], p[1], p[3]]
                uv = [(0.5 + (q[2] - cz) / (2 * r), 0.5 + (q[1] - cy) / (2 * r)) for q in p]
                self.quad(mat, p, (sgn, 0, 0), uv)
    def write(self, path, names):
        with open(path, 'w', newline='\n') as f:
            f.write('# rockmech crusher (devtools/make_crusher_mesh.py)\n')
            for p in self.v: f.write('v %.4f %.4f %.4f\n' % p)
            for t in self.vt: f.write('vt %.4f %.4f\n' % t)
            for n in self.vn: f.write('vn %.4f %.4f %.4f\n' % n)
            for m in self.order:
                f.write('usemtl %s\n' % names[m])
                for q in self.faces[m]:
                    f.write('f ' + ' '.join('%d/%d/%d' % t for t in q) + '\n')
        print('wrote', path, 'materials:', [names[m] for m in self.order])

# 材質（順序就是 tiles 的順序）
FRAME, BODY, DECK, WHEEL, MOTOR, BELT, RAIL, CHUTE, CABIN = range(9)
NAMES = ['frame', 'body', 'deck', 'wheel', 'motor', 'belt', 'rail', 'chute', 'cabin']

def crusher(big):
    m = Mesh()
    # 依材質順序先各放一個（讓 usemtl 順序固定 = tiles 順序）
    H = 0.6                       # 平台面
    # 鋼構：四支柱、四邊的梁
    for sx in (-1, 1):
        for sz in (-1, 1):
            m.box(FRAME, sx * 1.3 - 0.09, -0.5, sz * 1.3 - 0.09, sx * 1.3 + 0.09, H, sz * 1.3 + 0.09)
    m.box(FRAME, -1.45, H - 0.15, -1.45, 1.45, H, -1.3)
    # 破碎機主體（顎式）、上面收窄的頂蓋
    m.box(BODY, -0.75, H + 0.08, -0.55, 0.75, 2.0, 0.75)
    m.box(BODY, -0.6, 2.0, -0.4, 0.6, 2.22, 0.6)
    # 平台（格柵）
    m.box(DECK, -1.45, H, -1.45, 1.45, H + 0.08, 1.45)
    # 飛輪（兩側）、輪轂
    for sx in (-1, 1):
        xa, xb = (0.78, 0.92) if sx > 0 else (-0.92, -0.78)
        m.cyl_x(WHEEL, xa, xb, 1.45, 0.1, 0.55)
        m.cyl_x(FRAME, (xb if sx > 0 else xa - 0.08), (xb + 0.08 if sx > 0 else xa), 1.45, 0.1, 0.12, 12)
    # 馬達（後方右側）
    m.box(MOTOR, 0.25, H + 0.08, -1.35, 0.95, 1.15, -0.85)
    m.cyl_x(MOTOR, 0.95, 1.05, 0.92, -1.1, 0.16, 12)
    # 出料皮帶（後方中央，伸出機身外一點）、兩端的滾筒
    m.box(BELT, -0.35, H + 0.15, -1.6, 0.35, H + 0.27, -0.5)
    m.box(FRAME, -0.4, H + 0.08, -1.6, -0.35, H + 0.3, -0.5)
    m.box(FRAME, 0.35, H + 0.08, -1.6, 0.4, H + 0.3, -0.5)
    # 皮帶護蓋（黃，飛輪到馬達之間）、扶手欄杆（後面、兩側；前面是進料口不擋）
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
    # 進料溜槽（朝受料倉 +Z）：底板、兩側擋板
    m.box(CHUTE, -0.75, 1.95, 0.6, 0.75, 2.05, 1.45)
    m.box(CHUTE, -0.85, 1.95, 0.6, -0.75, 2.45, 1.45)
    m.box(CHUTE, 0.75, 1.95, 0.6, 0.85, 2.45, 1.45)
    if big:
        # 控制室（左後角）＋屋頂
        m.box(CABIN, -1.38, H + 0.08, -1.36, -0.8, 1.95, -0.62)
        m.box(FRAME, -1.42, 1.95, -1.4, -0.76, 2.03, -0.58)
        # 上面再一層：大型機的二級破碎頂座
        m.box(BODY, -0.5, 2.22, -0.3, 0.5, 2.7, 0.45)
    return m

here = os.path.dirname(os.path.abspath(__file__))
out = os.path.join(here, '..', 'models')
os.makedirs(out, exist_ok=True)
crusher(False).write(os.path.join(out, 'rockmech_crusher.obj'), NAMES)
crusher(True).write(os.path.join(out, 'rockmech_crusher_big.obj'), NAMES)
