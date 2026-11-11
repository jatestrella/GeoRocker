# 和平礦場採場現況：用國土測繪中心 WMTS 通用電子地圖（EMAP15 含等高線、EMAP16 不含）相減取得等高線與高程點，
# 底盤 = 高程點內插，邊坡坡度 = 等高線密度（範圍外用舊 DEM 校正），從底盤往外爬升，跟舊 DEM 取低的。
# 輸入：dens.npy、flat.npy、spots.pkl（由圖磚判讀產生）；用法：E0=出生點E N0=出生點N python hoping_quarry_surface.py 舊.bin 新.bin
# 採場現況地形：底盤 = 高程點內插；邊坡 = 從底盤往外，坡度照等高線密度（範圍外用舊 DEM 校正）；跟舊 DEM 取低的
import numpy as np, pickle, heapq, sys
from scipy import ndimage
from scipy.interpolate import griddata
fn = sys.argv[1]
import os
E0, N0 = float(os.environ.get('E0', 324189)), float(os.environ.get('N0', 2688743))      # 遊戲 (0, 0) 的 TWD97 座標（出生點）
b = open(fn, 'rb').read(); nl = b.index(b'\n'); _, nx, nz, cell, x0, z0 = b[:nl].decode().split()
nx, nz, x0, z0 = int(nx), int(nz), float(x0), float(z0)
a = np.frombuffer(b[nl + 1:], dtype='<u2').reshape(nz, nx).copy(); h = (a & 0x7fff) / 10.; q = a >= 0x8000
dens = np.load('dens.npy'); flat = np.load('flat.npy')
D = [0.01, 0.03, 0.05, 0.07, 0.09, 0.115, 0.15, 0.21, 0.32]; T = [0.19, 0.36, 0.45, 0.58, 0.74, 0.89, 1.08, 1.31, 1.66]
tan = np.interp(dens, D, T)
F = ndimage.binary_closing(flat, iterations=3) & q
F = ndimage.binary_opening(F, iterations=1)
spots = pickle.load(open('spots.pkl', 'rb'))
X = np.array([(E - E0 - x0) / 5 for E, N, v in spots]); Z = np.array([(N - N0 - z0) / 5 for E, N, v in spots]); V = np.array([v for _, _, v in spots], float)
ii = np.clip(np.round(X).astype(int), 0, nx - 1); jj = np.clip(np.round(Z).astype(int), 0, nz - 1)
inq = q[jj, ii]
# 底盤上的高程點（離底盤 10 m 內）
nearF = inq
J, I = np.mgrid[0:nz, 0:nx]
pts = np.c_[Z[nearF], X[nearF]]
Sf = griddata(pts, V[nearF], (J, I), method='linear')
Sn = griddata(pts, V[nearF], (J, I), method='nearest')
Sf = np.where(np.isnan(Sf), Sn, Sf)
Sf = ndimage.uniform_filter(Sf, 9)
print('floor spots', nearF.sum(), 'floor cells', F.sum())
# Dijkstra：從底盤往外
INF = 1e9
QB = ndimage.binary_dilation(q, iterations=12)      # 邊坡可以延伸到範圍外 60 m
Ed = np.full((nz, nx), INF)
pq = []
for j, i in zip(*np.where(F)):
    Ed[j, i] = min(Sf[j, i], h[j, i]); pq.append((Ed[j, i], j, i))
heapq.heapify(pq)
NB = [(-1, 0, 5), (1, 0, 5), (0, -1, 5), (0, 1, 5), (-1, -1, 7.07), (-1, 1, 7.07), (1, -1, 7.07), (1, 1, 7.07)]
while pq:
    e, j, i = heapq.heappop(pq)
    if e > Ed[j, i]: continue
    for dj, di, L in NB:
        jn, iN = j + dj, i + di
        if 0 <= jn < nz and 0 <= iN < nx and QB[jn, iN] and not F[jn, iN]:
            ne = e + L * 0.5 * (tan[j, i] + tan[jn, iN])
            if ne < Ed[jn, iN]: Ed[jn, iN] = ne; heapq.heappush(pq, (ne, jn, iN))
new = h.copy()
m = QB & (Ed < INF)
new[m] = np.minimum(h[m], Ed[m])
# 驗算：採場內的高程點
err = new[jj[inq], ii[inq]] - V[inq]
print('quarry spots n=%d  err median %.1f  |err|<5: %d  |err|>15: %d' % (inq.sum(), np.median(err), (abs(err) < 5).sum(), (abs(err) > 15).sum()))
cut = h - new
print('cut max %.0f mean (in quarry) %.0f' % (cut.max(), cut[q].mean()))
np.save('new_h.npy', new)
out = (np.clip(np.round(new * 10), 0, 32767).astype('<u2')) | (a & 0x8000)
open(sys.argv[2], 'wb').write(b[:nl + 1] + out.astype('<u2').tobytes())
