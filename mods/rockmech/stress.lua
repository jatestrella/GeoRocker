-- rockmech/stress.lua
-- 深度、岩性分層與初始應力（純函式，不依賴引擎）。
--
-- 1 格 = 1 m，深度 h = y0 - y（y0 為地表高程設定）。
-- σv = γ·h，σh = K0·σv。γ 單位 kN/m³，h 單位 m → γ·h 為 kPa，輸出換算為 MPa。
-- h ≤ 0（高於 y0）時應力取 0。
--
-- 之後的 Kirsch 解 / 外部求解器會以 stress.initial() 的結果作為遠場應力。

local stress = {}

function stress.depth(y, y0)
	return y0 - y
end

-- 依深度找分層。layers 由上往下，h < bottom 即屬該層；h < 0 歸第一層。
-- 回傳岩性名稱
function stress.layer_at_depth(layers, h)
	for i = 1, #layers do
		if h < layers[i].bottom then
			return layers[i].lith
		end
	end
	return layers[#layers].lith
end

-- σv (MPa)
function stress.sigma_v(gamma, h)
	if h <= 0 then return 0 end
	return gamma * h / 1000
end

-- σh (MPa)
function stress.sigma_h(sv, k0)
	return k0 * sv
end

-- 初始水平主應力 (MPa)：σH = K_H·σv + σH0、σh = K_h·σv + σh0。
-- σv ≤ 0（沒有上覆岩石）時為 0。cfg 未設 KH/Kh 時用 K0。
function stress.horizontal(cfg, sv)
	if sv <= 0 then return 0, 0 end
	local KH = cfg.KH or cfg.k0
	local Kh = cfg.Kh or cfg.k0
	return KH * sv + (cfg.sH0 or 0), Kh * sv + (cfg.sh0 or 0)
end

-- 水平主應力換到方塊座標（x = 東、z = 北）。θ 為 σH 方位（由北順時針，度）。
-- σH 方向單位向量 (sinθ, cosθ)。回傳 σxx, σzz, σxz
function stress.h_tensor(sH, sh, theta_deg)
	local t = math.rad(theta_deg or 0)
	local s, c = math.sin(t), math.cos(t)
	return sH * s * s + sh * c * c, sH * c * c + sh * s * s, (sH - sh) * s * c
end

-- 主應力（假設 σxy = σyz = 0，σyy 為主應力之一）。回傳 σ1, σ3, 水平兩主應力
function stress.principal(sxx, syy, szz, sxz)
	local cm = (sxx + szz) / 2
	local r = math.sqrt(((sxx - szz) / 2) ^ 2 + sxz * sxz)
	local a, b = cm + r, cm - r
	return math.max(syy, a, b), math.min(syy, a, b), a, b
end

-- 開挖前的上覆荷重：column[k] 為該格正上方第 k 格的單位重（kN/m³；非實心為 nil），
-- k = 1..n 由下往上。最高的實心格視為地表；其下的空隙（隧道、洞穴）視為原本是岩石，
-- 以 gamma_fill 補上。extra > 0 表示第 n 格之上仍是岩石（掃描範圍外），再加 extra 公尺。
-- 回傳 σv (MPa), h（地表高程 − 該格高程，m）
function stress.overburden(column, n, gamma_fill, extra)
	local top = 0
	extra = extra or 0
	if extra > 0 then
		top = n
	else
		for k = n, 1, -1 do
			if column[k] then top = k; break end
		end
	end
	local sum = 0
	for k = 1, top do
		sum = sum + (column[k] or gamma_fill)
	end
	return (sum + extra * gamma_fill) / 1000, top + extra
end

-- 由給定的 σv 與 h 組出初始應力表（水平主應力、方塊座標分量）
function stress.initial_from(cfg, sv, h)
	local sH, shmin = stress.horizontal(cfg, sv)
	local sxx, szz, sxz = stress.h_tensor(sH, shmin, cfg.sH_azimuth)
	return {h = h, sv = sv, sh = stress.sigma_h(sv, cfg.k0), sH = sH, shmin = shmin,
		sxx = sxx, szz = szz, sxz = sxz}
end

-- 位置的初始應力。lith 為岩性表條目（需有 gamma）。
-- 回傳 {h=, sv=, sh=, sH=, shmin=, sxx=, szz=, sxz=}（MPa）；sh 為舊欄位（= K0·σv）
function stress.initial(cfg, lith, y)
	local h = stress.depth(y, cfg.surface_y)
	local sv = stress.sigma_v(lith.gamma, h)
	local sH, shmin = stress.horizontal(cfg, sv)
	local sxx, szz, sxz = stress.h_tensor(sH, shmin, cfg.sH_azimuth)
	return {h = h, sv = sv, sh = stress.sigma_h(sv, cfg.k0), sH = sH, shmin = shmin,
		sxx = sxx, szz = szz, sxz = sxz}
end

-- 區帶模式：x 所在區帶的岩性名稱
function stress.zone_at_x(cfg, x)
	local W = cfg.zone_width
	local k = math.floor((x + W / 2) / W)
	local order = cfg.zone_order
	return order[k % #order + 1]
end

-- 某位置的岩性名稱（依 cfg.lith_mode）
function stress.lith_key_at(cfg, x, y, z)
	if cfg.strata and z then return (stress.strata_at(cfg.strata, x, y, z)) end
	if cfg.coal_seam and z and stress.in_seam(cfg.coal_seam, x, y, z) then return "coal" end
	if cfg.lith_mode == "zones" then
		return stress.zone_at_x(cfg, x)
	end
	return stress.layer_at_depth(cfg.layers, stress.depth(y, cfg.surface_y))
end

-- 煤層（cfg.coal_seam）：平面通過 (x0, y0, z0)，往 dipdir 傾 dip 度，真厚度 t。
-- 回傳點到煤層中面的垂直距離（m）
function stress.seam_offset(s, x, y, z)
	local along = (x - s.x0) * s.sin_dd + (z - s.z0) * s.cos_dd
	return ((y - s.y0) + s.tan_dip * along) * s.cos_dip
end
-- 礦帶（s.lane_w，見 config）：x 所在的帶號 k，和換算到第 0 帶的 x；帶外回傳 nil
function stress.seam_lane(s, x)
	local W = s.lane_w
	if not W then return 0, x end
	local k = math.floor((x + W / 2) / W)
	if k < s.lane_min or k > s.lane_max then return nil end
	local lx = x - k * W
	if s.lane_margin and lx < -W / 2 + s.lane_margin then return nil end
	return k, lx
end
-- 煤層透鏡（s.lens = {L = 尺度 m, thr = 門檻}，config 的 rockmech_coal_continuity）：
-- 厚度乘上雜訊鐘形，一塊塊鼓起來、邊緣變薄到尖滅；沒有 lens 是整片連續的。lx：礦帶內座標（各帶一樣）
function stress.seam_t(s, lx, z)
	local L = s.lens
	if not L then return s.t end
	if not L.thr then L.thr = stress.lens_threshold(L.c) end
	return s.t * stress.lens_factor(lx, z, L.L, L.thr, 401)
end
function stress.in_seam(s, x, y, z)
	if s.z_min and z < s.z_min then return false end      -- 礦帶地形：南邊的走廊沒有煤
	local k, lx = stress.seam_lane(s, x)
	if not k then return false end
	return math.abs(stress.seam_offset(s, lx, y, z)) <= stress.seam_t(s, lx, z) / 2
end

---------------------------------------------------------------------------
-- 礦帶地形（cfg.lane_terrain）：(x, z) 這一欄比 surface_y 高出幾公尺（≥ 0）。每帶由西到東：
--   交界山脊（跟隔壁帶共用）｜礦區的山丘（煤層從山中間切過）｜平地（營地）｜交界山脊
-- 起伏用帶內座標算，每帶完全一樣；z < z0 是各帶相連的平地走廊（沒有煤）
---------------------------------------------------------------------------

local function bump(u) u = math.abs(u); return u >= 1 and 0 or math.cos(math.pi / 2 * u) ^ 2 end   -- 0 → 1、|u| ≥ 1 → 0 的鐘形
local function smooth(t) t = math.max(0, math.min(1, t)); return t * t * (3 - 2 * t) end
-- 2D 值雜訊（0..1），純 Lua、跟引擎無關：mapgen 執行緒和主環境算出來一樣
local function hash(ix, iz, seed)
	local v = math.sin(ix * 127.1 + iz * 311.7 + seed * 74.7) * 43758.5453
	return v - math.floor(v)
end
local function vnoise(x, z, seed)
	local ix, iz = math.floor(x), math.floor(z)
	local fx, fz = smooth(x - ix), smooth(z - iz)
	local a, b = hash(ix, iz, seed), hash(ix + 1, iz, seed)
	local c, d = hash(ix, iz + 1, seed), hash(ix + 1, iz + 1, seed)
	return (a + (b - a) * fx) + ((c + (d - c) * fx) - (a + (b - a) * fx)) * fz
end
local function fbm(x, z, seed)      -- 兩層：大起伏 + 一半大小的細節
	return (vnoise(x, z, seed) * 2 + vnoise(x * 2.1, z * 2.1, seed + 17)) / 3
end
stress.terrain_noise = fbm
-- 透鏡：雜訊超過門檻的地方鼓起來（0..1，鐘形邊緣寬 0.15）
local LENS_W = 0.15
function stress.lens_factor(x, z, L, thr, seed)
	return smooth((fbm(x / L, z / L, seed) - thr) / LENS_W)
end
-- 連續性 c（有礦的面積比例，0..1）→ 門檻：雜訊的 (1 − c) 分位數（取樣算一次），扣半個邊緣寬（厚度一半的地方算有礦）
local lens_thr_cache = {}
function stress.lens_threshold(c)
	local key = math.floor(c * 1000 + 0.5)
	if lens_thr_cache[key] then return lens_thr_cache[key] end
	local v = {}
	for i = 0, 99 do for j = 0, 99 do v[#v + 1] = fbm(i * 1.37 + 0.11, j * 1.53 + 0.23, 401) end end
	table.sort(v)
	local q = v[math.max(1, math.min(#v, math.floor((1 - c) * #v + 0.5)))]
	lens_thr_cache[key] = q - LENS_W / 2
	return lens_thr_cache[key]
end
local HILL_PERIOD = 320     -- 礦區山丘段＋平地段一個循環的長度 (m)
local HILL_PHASE = -60      -- 山丘段從這個 z 開始：營地（z ≈ 0）旁邊是山丘，平地段在北邊遠一點的地方

-- 地圖四邊的山（cfg.lane_terrain.edge）：南（鐵路外）、北、東西（最外側礦帶的外緣）。
-- 山腳以外 beyond > 0；回傳 (高度, 離山腳最遠的那一邊超過幾公尺)
function stress.edge_rise(cfg, x, z)
	local T, s = cfg.lane_terrain, cfg.coal_seam
	local E = T and T.edge
	if not (E and s and s.lane_w) then return 0, -math.huge end
	local xw, xe = (s.lane_min - 0.5) * s.lane_w, (s.lane_max + 0.5) * s.lane_w
	local h, far = 0, -math.huge
	local function side(beyond, along, seed)
		if beyond > far then far = beyond end
		if beyond <= 0 then return end
		local H = E.h * (0.75 + 0.5 * vnoise(along / 110, 0.5, seed))
		local r = (H + 4 * (fbm(along / 14, beyond / 14, seed + 2) - 0.5)) * smooth(beyond / E.ramp)
		if r > h then h = r end
	end
	side(E.south - z, x, 41)
	side(z - E.north, x, 45)
	side(xw - x, z, 49)
	side(x - xe, z, 53)
	return math.max(0, h), far
end

function stress.lane_terrain(cfg, x, z)
	local T, s = cfg.lane_terrain, cfg.coal_seam
	if not (T and s and s.lane_w) then return 0 end
	local edge = stress.edge_rise(cfg, x, z)
	local W = s.lane_w
	local k = math.floor((x + W / 2) / W)
	if k < s.lane_min - 1 or k > s.lane_max + 1 then return edge, 0 end
	local lx = x - k * W
	-- 走廊：z0 以南漸變成平地
	local zf = z >= T.z0 and 1 or bump((T.z0 - z) / T.taper)
	if zf <= 0 then return edge, 0 end
	local h = 0
	-- 礦區的山丘：像 career_seam 的丘陵，雜訊超過門檻的地方隆起，煤層從山中間切過；兩側漸變
	if k >= s.lane_min and k <= s.lane_max then
		local c, hw = (T.hill_lx0 + T.hill_lx1) / 2, (T.hill_lx1 - T.hill_lx0) / 2
		local win = bump((lx - c) / hw) ^ 0.5
		if win > 0 then
			-- 沿走向（z）山丘段、平地段交替，各約一半（週期 HILL_PERIOD）：一半的煤層從山坡露頭、一半直接在平地上。
			-- 山丘段整段都有起伏（至少四成半高），雜訊高的地方再隆起成山頭
			local seg = smooth(math.sin(2 * math.pi * (z - HILL_PHASE) / HILL_PERIOD) / 0.5 + 0.5)
			if seg > 0 then
				local n = fbm(lx / 40, z / 40, 3)
				h = T.hill_h * (0.45 + 0.55 * smooth((n - 0.25) / 0.45)) * win * seg
			end
		end
	end
	local hill = h       -- 礦區山丘那一份（第二個回傳值：mapgen 的表土在礦區山丘鋪薄一點，看得到煤層）
	-- 交界山脊：高度、寬度沿 z 起伏，表面有細碎凹凸；用到交界的距離 d 算，兩側接得起來
	local other = lx > 0 and k + 1 or k - 1
	if (k >= s.lane_min and k <= s.lane_max) or (other >= s.lane_min and other <= s.lane_max) then
		local d = W / 2 - math.abs(lx)
		local zb = z      -- 每條脊都用同一個 z 雜訊：各帶一樣，同一條脊的兩側也接得起來
		local H = T.ridge_h * (0.8 + 0.4 * vnoise(zb / 90, 0.5, 11))
		local hw = T.ridge_hw * (0.8 + 0.4 * vnoise(zb / 120, 0.5, 23))
		local r = bump(d / hw)
		if r > 0 then
			local rough = 3 * (fbm(d / 12, zb / 12, 31) - 0.5)
			h = math.max(h, (H + rough) * r)
		end
	end
	return math.max(h * zf, edge), hill * zf
end

---------------------------------------------------------------------------
-- 地層柱狀圖（cfg.strata，地圖產生器）：由上往下一層一層（岩性、真厚度），整套往傾向傾斜、可以褶皺、每層厚度沿層面變化。
-- 地下一點的岩性 = 它離柱狀圖頂面多深（垂直層面量）落在哪一層
---------------------------------------------------------------------------

-- 多個地質區（S.faults，地圖產生器選了兩種以上的礦）：幾條平行的直立斷層把地圖切成幾區，每區一套柱狀圖（S.domains[k]，
-- 第 1 區就是 S 自己）。斷層 k 在沿法線方向 d 公尺、斷層帶寬 w：帶裡是斷層角礫岩（S.faults.lith）。
-- 回傳 (x, z) 這一欄的柱狀圖；在斷層帶裡回傳 nil
local block_of
local function domain_of(S, x, z)
	if S.blocks then return block_of(S, x, z) end
	local F = S.faults
	if not F then return S end
	local s = x * F.nx + z * F.nz
	for k, f in ipairs(F) do
		if s < f.d - f.w / 2 then return S.domains[k] end
		if s <= f.d + f.w / 2 then return nil end
	end
	return S.domains[#F + 1]
end
stress.strata_domain = domain_of

-- 重複的斷塊（S.blocks，config.lua 的 rockmech_fault_blocks）：沿斷層法線 s = x·nx + z·nz，第 k 塊在 bnd(k) … bnd(k + 1)；
-- 界線 = (k − ½)·平均寬 ± 隨機（寬度在最窄 … 最寬之間），第 0 塊包含營地。斷層帶（寬 fw）裡是斷層角礫岩（回傳 nil）
local function hseed(B) return (B.seed or 0) % 997 end
local function bnd(Bk, k)
	local Wm = (Bk.wmin + Bk.wmax) / 2
	return (k - 0.5) * Wm + (hash(k, 7, hseed(Bk) + 501) - 0.5) * (Bk.wmax - Bk.wmin) * 0.8
end
local function block_index(Bk, s)
	local k = math.floor(s / ((Bk.wmin + Bk.wmax) / 2) + 0.5)
	while s < bnd(Bk, k) do k = k - 1 end
	while s >= bnd(Bk, k + 1) do k = k + 1 end
	return k
end
stress.block_index = function(S, x, z)
	local Bk = S.blocks
	return Bk and block_index(Bk, x * Bk.nx + z * Bk.nz) or 0
end
local strata_column_raw
-- 第 k 塊的柱狀圖：第 (k mod 種類數) + 1 種，傾角 ±5°、傾向 ±10°、厚度 ×0.85–1.15，各自錯動：主礦層頂在塊裡
-- 離斷層 dist m 的地方露頭（沿走向隨機 ±200 m）。第 0 塊就是原本那一套（營地的露頭照地圖產生器算的）
function stress.block_strata(S, k, t)
	local cache = S._bk
	if not cache then cache = {}; S._bk = cache end
	local key = t and (k * 16 + t) or k
	local B = cache[key]
	if B then return B end
	local Bk, n = S.blocks, #S.domains
	local D = S.domains[t or (k % n + 1)]
	if k == 0 then cache[key] = D; return D end
	local sd = hseed(Bk)
	local dip = math.max(2, math.min(80, D.dip_deg + (hash(k, 11, sd) - 0.5) * 10))
	local dd = D.dipdir_deg + (hash(k, 13, sd) - 0.5) * 20
	B = setmetatable({}, {__index = D})
	B.dip_deg, B.dipdir_deg = dip, dd
	B.tan_dip, B.cos_dip = math.tan(math.rad(dip)), math.cos(math.rad(dip))
	B.sin_dd, B.cos_dd = math.sin(math.rad(dd)), math.cos(math.rad(dd))
	B.tmul = 0.85 + 0.3 * hash(k, 17, sd)
	local s0, s1 = bnd(Bk, k), bnd(Bk, k + 1)
	local so = math.min(s1 - Bk.fw, s0 + Bk.fw / 2 + (D.dist or 40))
	local w = (hash(k, 19, sd) - 0.5) * 400
	local px, pz = so * Bk.nx + w * Bk.nz, so * Bk.nz - w * Bk.nx
	B.y0 = 0
	local col = strata_column_raw(B, px, pz)
	local top = (D.main_i or 1) > 1 and col[D.main_i - 1] or 0
	local f = B.fold
	local fold = f and f.A * math.sin(2 * math.pi * (px * f.cx + pz * f.cz) / f.L) or 0
	B.y0 = top / B.cos_dip + B.tan_dip * (px * B.sin_dd + pz * B.cos_dd) - fold + (Bk.sy or 0)
	cache[key] = B
	return B
end

-- 地質區（S.prov，新世界）：照地質事件分區（沉積盆地、變質褶皺帶、火成岩侵入帶 = S.domains 的種類），扭曲過的 Voronoi，
-- 每區約 cell 大小；區界是大斷層（縫合帶，寬 bw 的斷層角礫岩）。營地在三區交界：營地周圍三格的區心各隔 120°，
-- 類型是第 1、2、3 種；其他格隨機。回傳 第幾種（S.domains 的索引）；在區界斷層帶裡回傳 nil
local function prov_point(P, i, j)
	local n, C, sd = #P.types, P.cell, (P.seed or 0) % 983
	local T = P.types
	if i == 0 and j == 0 then return 0.35 * C, 0.35 * C, T[1] end
	if i == -1 and j == 0 then return -0.35 * C, 0.35 * C, T[math.min(2, n)] end
	if i == 0 and j == -1 then return 0.02 * C, -0.5 * C, T[math.min(3, n)] end
	local px = (i + 0.1 + 0.8 * hash(i, j, sd + 31)) * C
	local pz = (j + 0.1 + 0.8 * hash(i, j, sd + 37)) * C
	if i == -1 and j == -1 then px, pz = (i + 0.1) * C, (j + 0.1) * C end
	return px, pz, T[math.floor(hash(i, j, sd + 41) * n) + 1]
end
-- 最近、第二近的區心：種類 t1, t2 和距離 d1, d2（座標先扭曲）
local function prov_nearest(P, x, z)
	local C = P.cell
	local wx = x + P.warp * 2 * (fbm(x / 1500, z / 1500, 271) - 0.5)
	local wz = z + P.warp * 2 * (fbm(x / 1500 + 7.7, z / 1500 - 3.3, 277) - 0.5)
	local ci, cj = math.floor(wx / C), math.floor(wz / C)
	local d1, d2, t1, t2 = math.huge, math.huge, nil, nil
	for i = ci - 1, ci + 1 do for j = cj - 1, cj + 1 do
		local px, pz, t = prov_point(P, i, j)
		local d = (wx - px) ^ 2 + (wz - pz) ^ 2
		if d < d1 then d2, t2 = d1, t1; d1, t1 = d, t
		elseif d < d2 then d2, t2 = d, t end
	end end
	return t1, t2, math.sqrt(d1), math.sqrt(d2)
end
function stress.province(S, x, z)
	local P = S.prov
	if not P then return nil end
	local c = P._c
	if c and c.x == x and c.z == z then return c.t end
	local t1, t2, d1, d2 = prov_nearest(P, x, z)
	local t = t1
	if t2 and t2 ~= t1 and (d2 - d1) < P.bw then t = nil end      -- 區界斷層帶
	P._c = {x = x, z = z, t = t}
	return t
end
block_of = function(S, x, z)
	local t
	if S.prov then
		t = stress.province(S, x, z)
		if not t then return nil end
	end
	local Bk = S.blocks
	local s = x * Bk.nx + z * Bk.nz
	local k = block_index(Bk, s)
	local hw = Bk.fw / 2
	if s - bnd(Bk, k) < hw or bnd(Bk, k + 1) - s < hw then return nil end
	return stress.block_strata(S, k, t)
end

-- 柱狀圖頂面在 (x, z) 的高程（S 是單一一區的柱狀圖）
function stress.strata_ref_y(S, x, z)
	local y = S.y0 - S.tan_dip * (x * S.sin_dd + z * S.cos_dd)
	local f = S.fold
	if f then y = y + f.A * math.sin(2 * math.pi * (x * f.cx + z * f.cz) / f.L) end
	return y
end
-- (x, z) 這一欄每層的底（離頂面的真厚度累計，m）。dmax：算到超過 dmax 再兩層就停（strata_at 單點查詢用）
-- 透鏡（b.lens = 尺度 m）：厚度乘上雜訊鐘形，大部分地方是 0、一塊塊鼓起來（水泥礦大理岩裡的片岩透鏡）
function stress.strata_column(S, x, z, dmax)
	S = domain_of(S, x, z)
	if not S then return {} end          -- 斷層帶
	return strata_column_raw(S, x, z, dmax)
end
-- 已經是某一區（某一塊）的柱狀圖 S：不再找區
strata_column_raw = function(S, x, z, dmax)
	local out, d = {}, 0
	local tm = S.tmul or 1
	local v = S.var
	local past = 0
	for i, b in ipairs(S.beds) do
		local m = 1
		if v then m = math.max(0, 1 + v.f * (2 * fbm(x / v.scale + i * 3.7, z / v.scale, 50 + i) - 1)) end
		if b.lens then m = m * smooth((fbm(x / b.lens + i * 7.3, z / b.lens - i * 3.1, 300 + i) - (b.lens_c and stress.lens_threshold(b.lens_c) or 0.45)) / 0.15) end
		d = d + b.t * m * tm
		out[i] = d
		if dmax and d > dmax then past = past + 1; if past > 2 then break end end
	end
	return out
end
-- 岩性、第幾層、在這層裡的位置（0 頂 … 1 底）。col：strata_column 的結果（同一欄重複用）
-- 位置：同一種岩性中間只隔著尖滅（厚度 0）的透鏡，當成同一層算（品位不會在看不到的界線跳）
function stress.strata_at(S, x, y, z, col)
	local cu, prop = S.cu, false
	if cu then           -- 斑岩體侵入任何岩層：核心、絹英岩化帶、表生分帶直接回傳；青盤岩化帶等圍岩算好再蓋上去
		local lith, p2, pr = stress.copper_point(cu, x, y, z)
		if lith then return lith, 1, 0.5, p2 end
		prop = pr
	end
	local D = domain_of(S, x, z)
	if not D then return prop and "propylitic" or (S.blocks or S.faults).lith, 0, 0.5 end
	if prop then
		local lith, i, fr = stress.strata_at_domain(D, x, y, z, col)
		local L = cu.cfg and cu.cfg.lithologies[lith]
		if L and L.ore then return lith, i, fr end            -- 礦層（煤、大理岩）不蓋
		return "propylitic", i, fr
	end
	return stress.strata_at_domain(D, x, y, z, col)
end
-- 已經是某一區（某一塊）的柱狀圖 S 裡的岩性
function stress.strata_at_domain(S, x, y, z, col)
	if S.body then       -- 斑岩銅礦：斑岩體裡照風化分帶，第 4 個回傳值是品位 param2
		local lith, p2 = stress.copper_at(S.body, x, y, z)
		if lith then return lith, 1, 0.5, p2 end
	end
	local d = (stress.strata_ref_y(S, x, z) - y) * S.cos_dip
	if d < 0 then return S.beds[1].lith, 1, 0 end           -- 柱狀圖頂面以上：最上面那層往上延伸
	col = col or strata_column_raw(S, x, z, d)
	local prev = 0
	for i, bot in ipairs(col) do
		if d < bot then
			local lith, beds = S.beds[i].lith, S.beds
			local top, k = prev, i
			while k > 2 and beds[k - 2].lith == lith and col[k - 1] - col[k - 2] < 0.05 do
				k = k - 2; top = col[k - 1] or 0
			end
			local btm, j = bot, i
			while col[j + 2] and beds[j + 2].lith == lith and col[j + 1] - col[j] < 0.05 do
				j = j + 2; btm = col[j]
			end
			return lith, i, btm > top and (d - top) / (btm - top) or 0.5
		end
		prev = bot
	end
	return S.beds[#S.beds].lith, #S.beds, 0.5
end
-- 互層裡的煤品位：煤層中央最好，靠頂底板變差，再加緩慢的橫向變化（同 seam_grade）
function stress.strata_grade(x, z, frac)
	local d = 2 * frac - 1
	local g = 228 - 75 * d * d + 7 * math.sin(x / 37) + 7 * math.sin(z / 29)
	return math.max(1, math.min(255, math.floor(g + 0.5)))
end

-- 斑岩銅礦（S.body，地圖產生器的 copper）：中心 (x0, z0)、半徑約 R 的直立圓柱，邊界有起伏。
-- 品位（param2）中心最高（g0），往外降到三成五左右，再加上下左右緩慢的變化。從地表往下的風化分帶看古地下水位 wt：
-- 地下水位是地形的平滑版（山丘底下比地表低得多、谷底比較淺）：wt = surface_y + 0.4·起伏 − D
--   wt + ox 以上：鐵帽（銅被淋走，不是礦）
--   wt … wt + ox：氧化帶（孔雀石），品位八成
--   wt − E … wt：次生富集帶（輝銅礦），品位 × fac
--   再往下：原生帶，品位隨深度 × e^(−深度/dd)（dd 有給才遞減；從富集帶底部算）
-- 鐵帽抗風化，地表在斑岩體上方是突起的小山丘（hg 有給才有；見 stress.body_hill）
-- ox、E 沿水平緩慢變化（0.6–1.4 倍）。回傳 岩性, param2；不在斑岩體裡回傳 nil
local function clamp_p2(v) return math.max(1, math.min(250, math.floor(v + 0.5))) end
function stress.copper_at(B, x, y, z)
	local dx, dz = x - B.x0, z - B.z0
	local R = B.R * (0.8 + 0.4 * fbm(x / 30, z / 30, 211))
	local rr = dx * dx + dz * dz
	if rr >= R * R then return nil end
	local c = B._col
	if not (c and c.x == x and c.z == z) then
		local C = B.cfg
		local rise = C and stress.has_terrain(C) and stress.terrain_rise(C, x, z) or 0
		local sy = C and C.surface_y or 0
		c = {x = x, z = z, wt = sy + 0.4 * rise - B.D,
			E = B.E * (0.6 + 0.8 * fbm(x / 20, z / 20, 223)), ox = B.ox * (0.6 + 0.8 * fbm(x / 17, z / 17, 227))}
		B._col = c
	end
	if y > c.wt + c.ox then return "gossan" end
	local u2 = rr / (R * R)
	local prim = B.g0 * (1 - 0.65 * u2) * (0.85 + 0.3 * fbm(x / 23 + y / 41, z / 23 - y / 37, 229))
	if y > c.wt then return "cu_oxide", clamp_p2(prim * 0.8) end
	if y > c.wt - c.E then return "cu_enriched", clamp_p2(prim * B.fac) end
	if B.dd then prim = prim * math.exp(-(c.wt - c.E - y) / B.dd) end      -- 原生帶：往深處品位遞減（礦底由截止品位決定）
	return "cu_primary", clamp_p2(prim)
end

---------------------------------------------------------------------------
-- 斑岩銅礦的礦區（cfg.strata.cu，新世界）：世界切成 cell 大小的格子，每格一個礦區（格子裡位置隨機），
-- 一根主礦體＋nsat 根衛星礦體（主礦體外 150–400 m）。營地那一格的主礦體邊緣在營地外 dist + 25 m。
-- 每根斑岩體：半徑 30–75 m × 規模（衛星 × 0.4–0.8）、軸線傾伏 60–85°（方位隨機，越深中心越往傾伏方向偏）、
-- 中心品位、富集倍率、富集帶和氧化帶厚、品位遞減深度、鐵帽山丘高、古地下水位深（礦區的 ± 5 m）各自隨機。全部由種子算，沒有清單
-- 由內往外：核心（鉀化帶，原生帶 cu_primary）→ 絹英岩化帶（R … 1.5R，低品位銅）→ 青盤岩化帶（1.5R … 2.3R，沒有銅）→ 圍岩；
-- 表生分帶（鐵帽、氧化帶、富集帶）照深度疊在核心和絹英岩化帶上
---------------------------------------------------------------------------
local CU_TOP, CU_BOT = 60, 400        -- 斑岩體軸線從地表上 60 m 到地表下 400 m（找附近礦體用的範圍）
local function cu_body(cu, sd, i, j, n, x0, z0, sat)
	local function h(a) return hash(i * 31 + n, j * 17 + a, sd) end
	local f = cu.f
	local R = (18 + 30 * h(1)) * f * (sat and (0.4 + 0.4 * h(2)) or 1)
	local pl = math.rad(60 + 25 * h(3))
	local paz = 2 * math.pi * h(4)
	return {x0 = x0, z0 = z0, R = math.max(4, R), cot = math.cos(pl) / math.sin(pl), dx = math.sin(paz), dz = math.cos(paz),
		g0 = math.floor((40 + 20 * h(5)) * (sat and (0.7 + 0.4 * h(6)) or 1) + 0.5), fac = 2 + 1.5 * h(7),
		E = 6 + 6 * h(8), ox = 3 + 3 * h(9), dd = (150 + 100 * h(10)) * f,      -- 富集帶、氧化帶是垂直的風化厚度，不跟礦體大小縮
		hg = (sat and h(11) < 0.5) and 0 or 8 * h(12) * f, D = math.max(3, cu.D + 10 * (h(13) - 0.5)),
		asp = 1 + 1.4 * h(14), sa = math.sin(2 * math.pi * h(15)), ca = math.cos(2 * math.pi * h(15)),      -- 橢圓：長短軸比、方向
		id = (i * 7 + j * 13 + n * 3) % 97, cfg = cu.cfg, sy = cu.sy or 0, new = true}
end
local function district(cu, i, j)
	local cache = cu._d
	if not cache then cache = {}; cu._d = cache end
	local key = i .. "," .. j
	local d = cache[key]
	if d then return d end
	local sd, C = (cu.seed or 0) % 991, cu.cell
	local cx, cz
	if i == 0 and j == 0 then
		local az = 2 * math.pi * hash(0, 0, sd + 3)
		local R0 = (18 + 30 * hash(0, 1, sd)) * cu.f
		local r = R0 + (cu.dist or 40) + 25
		cx, cz = r * math.sin(az), r * math.cos(az)
	else
		cx = (i + 0.7 * (hash(i, j, sd + 5) - 0.5)) * C
		cz = (j + 0.7 * (hash(i, j, sd + 7) - 0.5)) * C
	end
	d = {}
	-- 地質區：斑岩礦區主要在火成岩侵入帶（每格都有），沉積盆地 2 成、變質褶皺帶 3 成（侵入到隔壁的地質區）
	local St = cu.cfg and cu.cfg.strata
	if St and St.prov and not (i == 0 and j == 0) then
		local t = stress.province(St, cx, cz)
		local kind = t and St.domains[t] and St.domains[t].kind
		local p = kind == "copper" and 1 or kind == "marble" and 0.3 or 0.2
		if hash(i, j, sd + 13) >= p then cache[key] = d; return d end
	end
	local main = cu_body(cu, sd, i, j, 0, cx, cz, false)
	if i == 0 and j == 0 then main.R = (18 + 30 * hash(0, 1, sd)) * cu.f end
	d[1] = main
	for n = 1, cu.nsat do
		local a = 2 * math.pi * hash(i * 5 + n, j * 3 + n, sd + 9)
		local r = 150 + 250 * hash(i * 3 + n, j * 5 + n, sd + 11)
		d[#d + 1] = cu_body(cu, sd, i, j, n, cx + r * math.sin(a), cz + r * math.cos(a), true)
	end
	cache[key] = d
	return d
end
-- (x, z) 附近（32 m 一塊，有記住）可能碰得到的斑岩體：軸線（地表上 60 m … 地表下 400 m）離這塊 3.1R + 23 m 以內
local TILE_CU = 32
function stress.cu_near(cu, x, z)
	local tc = cu._t
	if not tc then tc = {}; cu._t = tc; cu._tn = 0 end
	local tx, tz = math.floor(x / TILE_CU), math.floor(z / TILE_CU)
	local key = tx * 65536 + tz
	local L = tc[key]
	if L then return L end
	L = {}
	local mx, mz = (tx + 0.5) * TILE_CU, (tz + 0.5) * TILE_CU
	local C = cu.cell
	local ci, cj = math.floor(mx / C + 0.5), math.floor(mz / C + 0.5)
	for i = ci - 1, ci + 1 do for j = cj - 1, cj + 1 do
		for _, B in ipairs(district(cu, i, j)) do
			-- 點到軸線線段（水平投影）的距離
			local ax, az = B.x0 - CU_TOP * B.cot * B.dx, B.z0 - CU_TOP * B.cot * B.dz
			local bx, bz = B.x0 + CU_BOT * B.cot * B.dx, B.z0 + CU_BOT * B.cot * B.dz
			local vx, vz = bx - ax, bz - az
			local t = ((mx - ax) * vx + (mz - az) * vz) / math.max(1e-9, vx * vx + vz * vz)
			t = math.max(0, math.min(1, t))
			local ex, ez = mx - (ax + t * vx), mz - (az + t * vz)
			local reach = 2.4 * B.R * 1.45 * math.sqrt(B.asp or 1) + TILE_CU * 0.72
			if ex * ex + ez * ez < reach * reach then L[#L + 1] = B end
		end
	end end
	if cu._tn > 4000 then tc = {}; cu._t = tc; cu._tn = 0 end
	tc[key], cu._tn = L, cu._tn + 1
	return L
end
-- 一根新式斑岩體在 (x, y, z)：回傳 岩性, param2（核心、絹英岩化帶、表生分帶）；在青盤岩化帶回傳 nil, nil, true；外面回傳 nil
-- 斑岩體的形狀（核心、蝕變帶、鐵帽山丘都用它）：隨機方向的橢圓（長短軸比 asp，面積不變），邊界再加兩層起伏
--（22 m 波長 0.55–1.45 倍、8 m 波長 ±15%）。回傳 (點到軸的「橢圓距離」)², 這裡的半徑
local function cu_shape(B, x, z, dx, dz)
	local asp = B.asp or 1
	local u, v = dx * (B.ca or 1) + dz * (B.sa or 0), -dx * (B.sa or 0) + dz * (B.ca or 1)
	local rr = u * u / asp + v * v * asp
	local R = B.R * (0.55 + 0.9 * fbm(x / 22, z / 22, 211 + B.id)) * (0.85 + 0.3 * fbm(x / 8, z / 8, 217 + B.id))
	return rr, R
end
stress.cu_shape = cu_shape
local function cu_eval(B, x, y, z)
	local h = B.sy - y
	local ax, az = B.x0 + h * B.cot * B.dx, B.z0 + h * B.cot * B.dz
	local rr, R = cu_shape(B, x, z, x - ax, z - az)
	if rr >= (2.3 * R) ^ 2 then return nil end
	if rr >= (1.5 * R) ^ 2 then return nil, nil, true end
	local c = B._col
	if not (c and c.x == x and c.z == z) then
		local C = B.cfg
		local rise = C and stress.has_terrain(C) and stress.terrain_rise(C, x, z) or 0
		-- 古地下水位：地形的緩和版，再加起伏（不是平的）：45 m 波長 ±35%、12 m 波長 ±20%；富集帶、氧化帶厚度 0.6–1.4 倍，
		-- 氧化帶底部沿裂隙鋸齒狀 ±2 m
		local wt = B.sy + 0.4 * rise - B.D + 0.7 * B.D * (fbm(x / 45, z / 45, 251 + B.id) - 0.5)
			+ 0.4 * B.D * (fbm(x / 12, z / 12, 263 + B.id) - 0.5)
		c = {x = x, z = z, wt = wt, E = B.E * (0.6 + 0.8 * fbm(x / 20, z / 20, 223 + B.id)),
			ox = math.max(0.5, B.ox * (0.6 + 0.8 * fbm(x / 17, z / 17, 227 + B.id)) + 4 * (fbm(x / 6, z / 6, 257) - 0.5))}
		B._col = c
	end
	if y > c.wt + c.ox then return "gossan" end
	local u2 = math.min(1, rr / (R * R))
	local prim = B.g0 * (1 - 0.65 * u2) * (0.85 + 0.3 * fbm(x / 23 + y / 41, z / 23 - y / 37, 229))
	local shell = rr >= R * R
	if shell then prim = prim * 0.3 end                  -- 絹英岩化帶：低品位
	if y > c.wt then return "cu_oxide", clamp_p2(prim * 0.8) end
	if y > c.wt - c.E then return "cu_enriched", clamp_p2(prim * B.fac) end
	prim = prim * math.exp(-(c.wt - c.E - y) / B.dd)
	return shell and "phyllic" or "cu_primary", clamp_p2(prim)
end
stress.cu_eval = cu_eval
-- (x, y, z) 的斑岩銅礦：岩性, param2, 在青盤岩化帶（true）, 礦體
function stress.copper_point(cu, x, y, z)
	local prop = false
	for _, B in ipairs(stress.cu_near(cu, x, z)) do
		local lith, p2, pr = cu_eval(B, x, y, z)
		if lith then return lith, p2, false, B end
		if pr then prop = true end
	end
	return nil, nil, prop
end
-- (x, y, z) 所在的斑岩體（舊世界的 S.body 或新世界的礦區）；鐵帽的化學成分要用
function stress.body_at(cfg, x, y, z)
	local S = cfg.strata
	if not S then return nil end
	if S.cu then
		local _, _, _, B = stress.copper_point(S.cu, x, y, z)
		return B
	end
	return S.body
end

-- 褐鐵礦（鐵帽）的化學成分（質量比例 0..1）：鐵、金、有害雜質（P、S、As）。
--   鐵 35–50%：銅被淋走後留下的氧化鐵，變化不大。
--   金 0.3–3 g/t：金不溶於地下水，留在鐵帽裡（殘留富集）；斑岩體中心高、往外降，鐵帽底部（靠氧化帶）比山頂富。
--   有害雜質 1–6%：一塊一塊的（有的地方雜質高到賣了反而虧錢）
local function stretch(v) return math.max(0, math.min(1, (v - 0.25) / 0.5)) end
function stress.gossan_chem(B, x, y, z)
	if B.new then cu_eval(B, x, y, z) else stress.copper_at(B, x, y, z) end      -- 算好這一欄的古地下水位（B._col）
	local c = B._col
	local C = B.cfg
	local top = (C and C.surface_y or 0) + (C and stress.has_terrain(C) and stress.terrain_rise(C, x, z) or 0)
	local bot = (c and c.x == x and c.z == z) and (c.wt + c.ox) or (top - 10)
	local f = math.max(0, math.min(1, (y - bot) / math.max(1, top - bot)))      -- 0 = 鐵帽底，1 = 地表
	local h0 = B.new and (B.sy - y) or 0
	local dx, dz = x - B.x0 - h0 * (B.cot or 0) * (B.dx or 0), z - B.z0 - h0 * (B.cot or 0) * (B.dz or 0)
	local u2 = math.min(1, (dx * dx + dz * dz) / (B.R * B.R))
	local fe = 0.35 + 0.15 * stretch(fbm(x / 19 + y / 31, z / 19 - y / 29, 233))
	local au = 0.3 + 2.7 * (1 - 0.6 * u2) * (1 - 0.5 * f) * stretch(fbm(x / 26 + y / 43, z / 26 + y / 37, 239))
	local harm = 0.01 + 0.05 * stretch(fbm(x / 15 - y / 23, z / 15 + y / 27, 241))
	return fe, au * 1e-6, harm
end

-- 自由地形（cfg.terrain，非礦帶世界）：(x, z) 這一欄比 surface_y 高出幾公尺（≥ 0），第二個值同第一個（礦區山丘：表土鋪薄，看得到岩層）
--   hills：雜訊起伏的丘陵，約一半是平地；cuesta：單面山。沿傾向鋸齒狀：順著層面的緩坡（坡度＝岩層傾角）＋朝上傾方向的陡崖，
--   陡崖沿走向蜿蜒；傾角大就成了豬背嶺。每一座的順向坡比前一座年輕（地層往傾向一直往下）
local CUESTA_SCARP = math.tan(math.rad(55))
-- 依地質的地形（cfg.terrain.mode = "geo"，參考 Minecraft 的做法）：多層碎形雜訊（6 層，頻率 ×2、振幅 ×½）、
-- 脊狀雜訊（1 − |雜訊|，尖的山脊和 V 形谷）、座標扭曲（形狀不沿格線）。地形種類照地質區：
--   沉積盆地 → 平原和緩丘（0.06–0.36 H）；火成岩侵入帶 → 丘陵（0.15–0.7 H）；
--   變質褶皺帶 → 山地，山脊順著褶皺軸排列（0.2–1 H）。區界 300 m 內平順過渡。營地附近起伏小一點（邊界不規則）
local function fbm6(x, z, seed)
	local s, a, f, n = 0, 1, 1, 0
	for o = 1, 6 do s = s + a * vnoise(x * f, z * f, seed + o * 13); n = n + a; a = a * 0.5; f = f * 2.03 end
	return s / n
end
local function ridged(x, z, seed)
	local s, a, f, n = 0, 1, 1, 0
	for o = 1, 5 do
		local v = 1 - math.abs(2 * vnoise(x * f, z * f, seed + o * 7) - 1)
		s = s + a * v * v; n = n + a; a = a * 0.5; f = f * 2.1
	end
	return s / n
end
local function geo_style(D, x, z, H)
	local kind = D and D.kind
	if kind == "coal" then
		local n = fbm6(x / 500, z / 500, 311)
		return H * (0.06 + 0.3 * n * n)
	elseif kind == "copper" then
		return H * (0.15 + 0.55 * fbm6(x / 260, z / 260, 331))
	end
	-- 變質褶皺帶：沿褶皺軸拉長的脊狀雜訊
	local f = D and D.fold
	local cx, cz = 1, 0
	if f then cx, cz = f.cx, f.cz end
	local across, along = x * cx + z * cz, -x * cz + z * cx
	local r = ridged(along / 700, across / 160, 351)
	local m = 0.5 + 0.5 * fbm6(x / 900, z / 900, 361)
	return H * (0.2 + 0.8 * r * m)
end
local function geo_terrain(cfg, x, z, H)
	local S = cfg.strata
	local wx = x + 160 * (fbm(x / 300, z / 300, 381) - 0.5)
	local wz = z + 160 * (fbm(x / 300 + 5.1, z / 300 - 2.7, 383) - 0.5)
	local t1, t2, d1, d2 = prov_nearest(S.prov, wx, wz)
	local a = 0.5 + 0.5 * smooth((d2 - d1) / 300)
	local h = geo_style(S.domains[t1], wx, wz, H)
	if t2 and a < 1 then h = a * h + (1 - a) * geo_style(S.domains[t2], wx, wz, H) end
	return h      -- 營地附近不再壓平（會變成一個碗）：村莊自己找平的地點（village.lua 的 V.site）
end

function stress.free_terrain(cfg, x, z)
	local T = cfg.terrain
	if T.height then local h = T.height(x, z); return h, h end      -- 真實地形（高程網格）
	local H = T.h
	if T.mode == "geo" and cfg.strata and cfg.strata.prov then
		local h = math.max(0, geo_terrain(cfg, x, z, H))
		return h, h
	end
	local h
	if T.mode == "cuesta" and cfg.strata then
		local S = domain_of(cfg.strata, x, z) or cfg.strata      -- 每個地質區照自己的傾角（跨過斷層地形就變了）
		local u = x * S.sin_dd + z * S.cos_dd              -- 沿傾向
		local w = x * S.cos_dd - z * S.sin_dd              -- 沿走向
		local tan = math.max(math.tan(math.rad(4)), S.tan_dip)
		local ld = math.min(300, H / tan)                  -- 順向坡長
		local ls = H / CUESTA_SCARP                        -- 陡崖寬
		local P = ld + ls
		u = u + P * 0.35 * (fbm(w / T.scale, 0.5, 71) - 0.5) * 2      -- 陡崖沿走向蜿蜒
		local s = u % P
		if s < ls then h = H * smooth(s / ls) else h = H * (1 - (s - ls) / ld) end
		h = h * (0.75 + 0.25 * fbm(w / (T.scale * 2), u / (T.scale * 2), 73)) + 1.5 * (fbm(x / 9, z / 9, 75) - 0.5)
	else
		local n = fbm(x / T.scale, z / T.scale, 61)
		h = H * smooth((n - 0.3) / 0.5) + 1.5 * (fbm(x / 9, z / 9, 75) - 0.5)
	end
	-- 出生點附近（營地）平地：60 m 內不起伏，100 m 以外完全起伏
	local rr = math.sqrt(x * x + z * z)
	h = math.max(0, h) * smooth((rr - 60) / 40)
	return h, h
end
-- 鐵帽山丘（cfg.body_hills：有 hg 的斑岩銅礦）：鐵帽比周圍的安山岩耐風化，留成突起的小山丘。
-- 邊界跟斑岩體一樣（copper_at 同一個起伏的半徑），外圈 35% 是山坡、裡面是起伏的山頂；回傳高出幾公尺
function stress.body_hill(cfg, x, z)
	local L = cfg.body_hills
	if not L then return 0 end
	local h = 0
	local cu = cfg.strata and cfg.strata.cu
	if cu then L = stress.cu_near(cu, x, z) end
	for _, B in ipairs(L) do
		if (B.hg or 0) > 0 then
		local dx, dz = x - B.x0, z - B.z0
		local rr = dx * dx + dz * dz
		local Rmax = B.R * (B.new and 1.45 * math.sqrt(B.asp or 1) or 1.2)
		if rr < Rmax * Rmax then
			local R = B.R * (0.8 + 0.4 * fbm(x / 30, z / 30, 211))
			if B.new then rr, R = cu_shape(B, x, z, dx, dz) end
			local r = math.sqrt(rr)
			if r < R then
				h = math.max(h, B.hg * smooth((1 - r / R) / 0.35) * (0.8 + 0.4 * fbm(x / 15, z / 15, 233)))
			end
		end
		end
	end
	return h
end
-- 有沒有公式地形（礦帶、自由地形或鐵帽山丘）；有的話 (x, z) 比 surface_y 高幾公尺
function stress.has_terrain(cfg) return cfg.lane_terrain ~= nil or cfg.terrain ~= nil or cfg.body_hills ~= nil end
local function terrain_raw(cfg, x, z)
	if cfg.lane_terrain then return stress.lane_terrain(cfg, x, z) end
	local t, hill = 0, 0
	if cfg.terrain then t, hill = stress.free_terrain(cfg, x, z) end
	if cfg.body_hills then
		local b = stress.body_hill(cfg, x, z)
		if b > 0 then t, hill = t + b, (hill or 0) + b end
	end
	return t, hill
end
stress.terrain_raw = terrain_raw

-- 設計坡度（cfg.design_slope，度）：公式地形「退化到穩定坡角」= 原本地形的 Lipschitz 下包絡線
--   h'(p) = min over q [ h(q) + tanβ·|p − q| ]：比 β 陡的地方削掉，緩的地方不動。
-- 分塊算（TILE × TILE，外圍多讀 margin = 最高山 ÷ tanβ），8 鄰格兩趟掃描（距離最多高估 8%，tanβ 先除掉）。
-- 每個環境（主環境、mapgen 執行緒）各自快取，算法固定，結果一樣
local TILE, HMAX = 64, 60
local tiles, ntiles = {}, 0
local function tile_of(cfg, tx, tz)
	local key = tx .. "," .. tz
	local t = tiles[key]
	if t then return t end
	local tan = math.tan(math.rad(cfg.design_slope)) / 1.0824
	local M = math.ceil(math.max(HMAX, (cfg.terrain and cfg.terrain.h or 0) * 1.3 + 10) / tan)
	local N = TILE + 2 * M
	local x0, z0 = tx * TILE - M, tz * TILE - M
	local h, hill = {}, {}
	for j = 0, N - 1 do for i = 0, N - 1 do
		local a, b = terrain_raw(cfg, x0 + i, z0 + j)
		h[j * N + i + 1], hill[j * N + i + 1] = a, b or 0
	end end
	local d1, d2 = tan, tan * math.sqrt(2)
	for j = 0, N - 1 do for i = 0, N - 1 do
		local c = j * N + i + 1
		local v = h[c]
		if i > 0 then v = math.min(v, h[c - 1] + d1) end
		if j > 0 then
			v = math.min(v, h[c - N] + d1)
			if i > 0 then v = math.min(v, h[c - N - 1] + d2) end
			if i < N - 1 then v = math.min(v, h[c - N + 1] + d2) end
		end
		h[c] = v
	end end
	for j = N - 1, 0, -1 do for i = N - 1, 0, -1 do
		local c = j * N + i + 1
		local v = h[c]
		if i < N - 1 then v = math.min(v, h[c + 1] + d1) end
		if j < N - 1 then
			v = math.min(v, h[c + N] + d1)
			if i < N - 1 then v = math.min(v, h[c + N + 1] + d2) end
			if i > 0 then v = math.min(v, h[c + N - 1] + d2) end
		end
		h[c] = v
	end end
	local out = {h = {}, hill = {}}
	for j = 0, TILE - 1 do for i = 0, TILE - 1 do
		local c = (j + M) * N + i + M + 1
		out.h[j * TILE + i + 1] = h[c]
		out.hill[j * TILE + i + 1] = math.min(hill[c], h[c])
	end end
	if ntiles >= 48 then tiles, ntiles = {}, 0 end
	tiles[key], ntiles = out, ntiles + 1
	return out
end
function stress.terrain_rise(cfg, x, z)
	if not cfg.design_slope then return terrain_raw(cfg, x, z) end
	x, z = math.floor(x + 0.5), math.floor(z + 0.5)
	local tx, tz = math.floor(x / TILE), math.floor(z / TILE)
	local t = tile_of(cfg, tx, tz)
	local c = (z - tz * TILE) * TILE + (x - tx * TILE) + 1
	return t.h[c], t.hill[c]
end

-- 煤的品位（param2 1..255，煤佔的比例）：煤層中央最好，靠頂底板變差（夾雜質），再加緩慢的橫向變化
function stress.seam_grade(s, x, y, z)
	local _, lx = stress.seam_lane(s, x)
	x = lx or x      -- 礦帶：各帶的品位分布一樣
	local d = 2 * stress.seam_offset(s, x, y, z) / math.max(0.5, stress.seam_t(s, x, z))
	local g = 228 - 75 * d * d + 7 * math.sin(x / 37) + 7 * math.sin(z / 29)
	return math.max(1, math.min(255, math.floor(g + 0.5)))
end

-- 露天坑（cfg.open_pit）：中心 (x0, z0)，底半徑 R、深 D（坑底 y = surface − D）。坑壁是一圈圈水平的階，
-- 階高 H、階寬 W，到地表結束。運輸坡道寬 W、坡度 G，從坑底螺旋切過各階上到地表：中線半徑 rc 隨高度
-- 線性往外，rc = R + cone·(h + D)，水平走 ds 上升 G·ds，所以 rc = R·e^(cone·G·θ)。
-- 回傳 (x, z) 這一欄的地面高度（小數，m）；坑外回傳 nil
function stress.pit_surface(p, surface, x, z)
	local dx, dz = x - p.x0, z - p.z0
	local r = math.sqrt(dx * dx + dz * dz)
	local bottom = surface - p.D
	local rim = p.R + p.W * math.max(p.D / p.H - 1, 1)     -- 最高一階的外緣
	local cone = (rim + p.W / 2 - p.R) / p.D                 -- 坡道到地表時整條路剛好在坑外
	local turn = ((math.atan2 or math.atan)(dz, dx) / (2 * math.pi)) % 1     -- LuaJIT 的 math.atan 只收一個參數
	for lap = 0, 20 do
		local rc = p.R * math.exp(cone * p.G * 2 * math.pi * (turn + lap))
		local h = bottom + (rc - p.R) / cone
		if h >= surface or rc - p.W / 2 > r then break end
		if r <= rc + p.W / 2 then return h end
	end
	if r < p.R then return bottom end
	local h = bottom + p.H * (math.floor((r - p.R) / p.W) + 1)
	if h >= surface then return nil end
	return h
end

-- 建立 y → 岩性名稱 的查表，供地圖生成在 [ymin, ymax] 內使用
function stress.layer_table(cfg, ymin, ymax)
	local t = {}
	for y = ymin, ymax do
		t[y] = stress.layer_at_depth(cfg.layers, stress.depth(y, cfg.surface_y))
	end
	return t
end

---------------------------------------------------------------------------
-- 天然表土（mapgen.lua 產生地圖時鋪的厚度；femstress.lua 用同一個公式算「開挖前的表土」當現地應力的參考狀態）
--   山坡（比地表 surface_y 高 MIN_RISE 以上）SOIL_MIN–SOIL_MAX m；礦帶地形的礦區山丘 HILL_MIN–HILL_MAX；
--   平地 FLAT_MIN–FLAT_MAX；山腳離山坡 1–4 m 的那一圈是漸薄的坡腳（不比平地薄）；礦石露頭不鋪。
--   樹的位置（稀疏、每個 mapgen chunk 內）那一欄取整格：山脊至少 2 m、礦區山丘 1 m
---------------------------------------------------------------------------
stress.SOIL = {min = 1, max = 3, hill_min = 0.25, hill_max = 1, flat_min = 0.25, flat_max = 0.75,
	min_rise = 1, tree_gap = 6, apron = {8, 6, 4, 2}, chunk = 80, chunk_off = -32}
local SOILC = stress.SOIL
function stress.soil_rnd(x, z, seed)      -- 每個位置固定的 0..1 亂數
	local v = math.sin(x * 12.9898 + z * 78.233 + seed * 37.719) * 43758.5453
	return v - math.floor(v)
end
local rnd = stress.soil_rnd
-- 露頭（rockmech_outcrop，山坡面積裸露的比例）：另一組平滑雜訊（約 10–20 m 一片）低於門檻的地方不鋪土，
-- 門檻上方一小段的土逐漸變薄。門檻是雜訊的分位數：取樣一次算出來（雜訊不是均勻分布）
local OUT_SCALE, OUT_SEED, OUT_EDGE = 18, 59, 0.06
local out_thr = {}
local function outcrop_threshold(frac)
	if frac <= 0 then return -1 end
	if out_thr[frac] then return out_thr[frac] end
	local v = {}
	for i = 0, 149 do for j = 0, 149 do v[#v + 1] = fbm(i * 0.37, j * 0.41, OUT_SEED) end end
	table.sort(v)
	out_thr[frac] = v[math.max(1, math.min(#v, math.floor(#v * frac + 0.5)))]
	return out_thr[frac]
end
-- 山坡 (x, z) 的表土要乘的比例：0 = 露頭，1 = 正常
function stress.outcrop_factor(cfg, x, z)
	local thr = outcrop_threshold(cfg.outcrop or 0.2)
	local o = fbm(x / OUT_SCALE, z / OUT_SCALE, OUT_SEED)
	if o <= thr then return 0 end
	return math.min(1, (o - thr) / OUT_EDGE)
end
-- (x, z) 是不是種樹的位置：間距 tree_gap 的格點、隨機偏移 ±2、四成跳過，整棵要在 mapgen chunk 裡（離邊 2 格）。
-- 是的話回傳這棵樹的種子
function stress.tree_at(x, z)
	local G = SOILC.tree_gap
	local gx, gz = math.ceil((x - 2) / G) * G, math.ceil((z - 2) / G) * G
	if gx > x + 2 or gz > z + 2 then return nil end
	if x ~= gx + math.floor(rnd(gx, gz, 1) * 5) - 2 or z ~= gz + math.floor(rnd(gx, gz, 2) * 5) - 2 then return nil end
	if rnd(gx, gz, 3) <= 0.4 then return nil end
	local C, o = SOILC.chunk, SOILC.chunk_off
	local mx, mz = math.floor((x - o) / C) * C + o, math.floor((z - o) / C) * C + o
	if x < mx + 2 or x > mx + C - 3 or z < mz + 2 or z > mz + C - 3 then return nil end
	return gx * 7 + gz
end
-- 天然表土厚度（1/8 m）。rise：這一欄岩石頂比地表高幾格；rise_at(x, z)：別欄的 rise（坡腳用）；ore_top：頂上是礦石
-- (x, z) 可不可以種樹：有植生圖照它（森林才種），沒有的話看露頭
function stress.tree_ok(cfg, x, z)
	local T = cfg.terrain
	local vc = T and T.veg and T.veg(x, z)
	if vc then return vc == 2 end
	return stress.outcrop_factor(cfg, x, z) >= 1
end
function stress.natural_soil(cfg, x, z, rise, rise_at, ore_top)
	-- 真實地形（DEM）：採場範圍裡是裸岩；採場外整片是山坡（頂上是大理岩也鋪土、種樹）
	-- 有植生圖（正射影像分類）的話照它：裸露不鋪土，草地、森林鋪土（森林才種樹）
	local T = cfg.terrain
	local vc = T and T.veg and T.veg(x, z)
	if vc then
		if vc == 0 then return 0 end
		ore_top, rise = false, math.max(rise, SOILC.min_rise)
	elseif T and T.quarry then
		if T.quarry(x, z) then return 0 end
		ore_top, rise = false, math.max(rise, SOILC.min_rise)
	end
	if ore_top or rise < 0 then return 0 end
	local NL = 8
	local function noise_t(lo, hi) return math.floor(NL * (lo + (hi - lo) * fbm(x / 14, z / 14, 41)) + 0.5) end
	if rise >= SOILC.min_rise then
		local tot, hill = 0, 0
		if stress.has_terrain(cfg) then tot, hill = stress.terrain_rise(cfg, x, z) end
		local of = vc and 1 or stress.outcrop_factor(cfg, x, z)          -- 露頭：不鋪或漸薄，也不種樹（有植生圖就不用）
		local tree = stress.tree_ok(cfg, x, z) and stress.tree_at(x, z)
		if (hill or 0) > 0 and hill >= tot - 0.5 then        -- 礦區山丘（不是交界山脊）：鋪薄一點，看得到煤層
			return tree and NL or math.floor(noise_t(SOILC.hill_min, SOILC.hill_max) * of + 0.5)
		end
		local t = noise_t(SOILC.min, SOILC.max)
		return tree and math.max(2 * NL, t - t % NL) or math.floor(t * of + 0.5)
	end
	local t = noise_t(SOILC.flat_min, SOILC.flat_max)
	for d = 1, #SOILC.apron do
		for dx = -d, d do for dz = -d, d do
			if (math.abs(dx) == d or math.abs(dz) == d) and (rise_at(x + dx, z + dz) or 0) >= SOILC.min_rise then
				return math.max(t, SOILC.apron[d])
			end
		end end
	end
	return t
end

return stress
