# -*- coding: utf-8 -*-
# 從 DEM（GDAL 讀得到的格式，例如內政部 5 m DEM，TWD97 二度分帶 EPSG:3826）切一塊做成遊戲地形：
#   python tools/dem_extract.py <DEM 檔> <輸出.bin> <E 中心> <N 中心> <E1> <N1> <E2> <N2> [縮尺 0.5] [取樣間距 m 10]
# 中心點 = 遊戲的 (0, 0)（出生點、營地）；範圍 (E1,N1)-(E2,N2)；縮尺：遊戲 1 格 = 1/縮尺 公尺（長寬高同比例，坡度不變）。
# 輸出格式（mods/rockmech/config.lua 讀）：第一行文字 "RMDEM nx nz cell x0 z0\n"（cell、x0、z0 是遊戲公尺，
# x0、z0 是西南角），接著 nx*nz 個 uint16（little endian，遊戲高度 × 10，由南往北一列一列、每列由西往東）。
# 海面以下（DEM 0 或沒資料）記 0。
import sys, struct
import numpy as np
from osgeo import gdal

gdal.UseExceptions()
src, out = sys.argv[1], sys.argv[2]
Ec, Nc, E1, N1, E2, N2 = map(float, sys.argv[3:9])
scale = float(sys.argv[9]) if len(sys.argv) > 9 else 0.5
step = float(sys.argv[10]) if len(sys.argv) > 10 else 10.0

d = gdal.Open(src)
gt = d.GetGeoTransform()
b = d.GetRasterBand(1)
Ew, Ee, Ns, Nn = min(E1, E2), max(E1, E2), min(N1, N2), max(N1, N2)
c0 = int((Ew - gt[0]) / gt[1]); r0 = int((gt[3] - Nn) / -gt[5])
w = int((Ee - Ew) / gt[1]) + 1; h = int((Nn - Ns) / -gt[5]) + 1
a = b.ReadAsArray(c0, r0, w, h).astype(np.float64)
nd = b.GetNoDataValue()
if nd is not None: a[a == nd] = 0
a[a < 0] = 0
px = gt[1]
# 每 step 公尺取一點（區塊平均，去掉 5 m 網格的雜訊）
k = max(1, int(round(step / px)))
nz_r, nx_r = a.shape[0] // k, a.shape[1] // k
a = a[:nz_r * k, :nx_r * k].reshape(nz_r, k, nx_r, k).mean(axis=(1, 3))
a = a[::-1, :]          # 由南往北
cell = step * scale
x0 = (Ew + step / 2 - Ec) * scale
z0 = (Ns + step / 2 - Nc) * scale
g = np.clip(np.round(a * scale * 10), 0, 65535).astype('<u2')
with open(out, 'wb') as f:
	f.write(("RMDEM %d %d %g %g %g\n" % (nx_r, nz_r, cell, x0, z0)).encode('ascii'))
	f.write(g.tobytes())
print("ok %dx%d cell %g m, x0 %g z0 %g, height %.1f..%.1f m (game)" % (nx_r, nz_r, cell, x0, z0, g.min() / 10, g.max() / 10))
