# 和平礦場植生圖：國土測繪中心 WMTS 正射影像（PHOTO2）每 5 m 一格分類 → rockmech_veg.bin（格點同 rockmech_dem.bin）
#   0 裸露（採場、道路、崩塌地、水池）、1 草地（淺綠：不種樹）、2 森林（深綠：種樹）
#   分類：綠色比例 G/(R+G+B) > 0.355 且 G − B > 4 → 有植生；亮度 < 100 → 森林
# 用法：python hoping_vegetation.py 正射影像.npy（TWD97 1 m 格網，列 0 = 北邊 N_top、欄 0 = 西邊 E_left） E_left N_top dem.bin 輸出.bin
import sys, numpy as np
from scipy import ndimage
photo, El, Nt, demf, out = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), sys.argv[4], sys.argv[5]
E0, N0 = 324189, 2688743         # 遊戲 (0, 0)
a = np.load(photo).astype(float)
H, W = a.shape[0] // 5 * 5, a.shape[1] // 5 * 5
c = a[:H, :W].reshape(H // 5, 5, W // 5, 5, 3).mean((1, 3))
R, G, B = c[..., 0], c[..., 1], c[..., 2]; s = R + G + B
veg = (G / s > 0.355) & (G - B > 4)
veg = ndimage.binary_opening(ndimage.binary_closing(veg, iterations=1), iterations=1)
cls = veg.astype(np.uint8) + (veg & (s / 3 < 100)).astype(np.uint8)
hdr = open(demf, 'rb').read(200).split(b'\n')[0].decode().split()
nx, nz, cell, x0, z0 = int(hdr[1]), int(hdr[2]), float(hdr[3]), float(hdr[4]), float(hdr[5])
outv = np.full((nz, nx), 2, np.uint8)
for j in range(nz):
    N = N0 + z0 + j * cell
    r = int((Nt - N) / 5)
    for i in range(nx):
        E = E0 + x0 + i * cell
        k = int((E - El) / 5)
        if 0 <= r < cls.shape[0] and 0 <= k < cls.shape[1]: outv[j, i] = cls[r, k]
open(out, 'wb').write(('RMVEG %d %d %g %g %g\n' % (nx, nz, cell, x0, z0)).encode() + outv.tobytes())
print('bare %.0f%% grass %.0f%% forest %.0f%%' % tuple(100 * (outv == v).mean() for v in (0, 1, 2)))
