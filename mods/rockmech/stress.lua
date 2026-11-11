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
function stress.in_seam(s, x, y, z)
	if s.z_min and z < s.z_min then return false end      -- 礦帶地形：南邊的走廊沒有煤
	local k, lx = stress.seam_lane(s, x)
	if not k then return false end
	return math.abs(stress.seam_offset(s, lx, y, z)) <= s.t / 2
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
local function domain_of(S, x, z)
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
	local out, d = {}, 0
	if not S then return out end          -- 斷層帶
	local v = S.var
	local past = 0
	for i, b in ipairs(S.beds) do
		local m = 1
		if v then m = math.max(0, 1 + v.f * (2 * fbm(x / v.scale + i * 3.7, z / v.scale, 50 + i) - 1)) end
		if b.lens then m = m * smooth((fbm(x / b.lens + i * 7.3, z / b.lens - i * 3.1, 300 + i) - 0.45) / 0.15) end
		d = d + b.t * m
		out[i] = d
		if dmax and d > dmax then past = past + 1; if past > 2 then break end end
	end
	return out
end
-- 岩性、第幾層、在這層裡的位置（0 頂 … 1 底）。col：strata_column 的結果（同一欄重複用）
-- 位置：同一種岩性中間只隔著尖滅（厚度 0）的透鏡，當成同一層算（品位不會在看不到的界線跳）
function stress.strata_at(S, x, y, z, col)
	local D = domain_of(S, x, z)
	if not D then return S.faults.lith, 0, 0.5 end
	S = D
	local d = (stress.strata_ref_y(S, x, z) - y) * S.cos_dip
	if d < 0 then return S.beds[1].lith, 1, 0 end           -- 柱狀圖頂面以上：最上面那層往上延伸
	col = col or stress.strata_column(S, x, z, d)
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

-- 自由地形（cfg.terrain，非礦帶世界）：(x, z) 這一欄比 surface_y 高出幾公尺（≥ 0），第二個值同第一個（礦區山丘：表土鋪薄，看得到岩層）
--   hills：雜訊起伏的丘陵，約一半是平地；cuesta：單面山。沿傾向鋸齒狀：順著層面的緩坡（坡度＝岩層傾角）＋朝上傾方向的陡崖，
--   陡崖沿走向蜿蜒；傾角大就成了豬背嶺。每一座的順向坡比前一座年輕（地層往傾向一直往下）
local CUESTA_SCARP = math.tan(math.rad(55))
function stress.free_terrain(cfg, x, z)
	local T = cfg.terrain
	if T.height then local h = T.height(x, z); return h, h end      -- 真實地形（高程網格）
	local H = T.h
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
-- 有沒有公式地形（礦帶或自由地形）；有的話 (x, z) 比 surface_y 高幾公尺
function stress.has_terrain(cfg) return cfg.lane_terrain ~= nil or cfg.terrain ~= nil end
function stress.terrain_rise(cfg, x, z)
	if cfg.lane_terrain then return stress.lane_terrain(cfg, x, z) end
	if cfg.terrain then return stress.free_terrain(cfg, x, z) end
	return 0, 0
end

-- 煤的品位（param2 1..255，煤佔的比例）：煤層中央最好，靠頂底板變差（夾雜質），再加緩慢的橫向變化
function stress.seam_grade(s, x, y, z)
	local _, lx = stress.seam_lane(s, x)
	x = lx or x      -- 礦帶：各帶的品位分布一樣
	local d = 2 * stress.seam_offset(s, x, y, z) / s.t
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
function stress.natural_soil(cfg, x, z, rise, rise_at, ore_top)
	-- 真實地形（DEM）：採場範圍裡是裸岩；採場外整片是山坡（頂上是大理岩也鋪土、種樹）
	local T = cfg.terrain
	if T and T.quarry then
		if T.quarry(x, z) then return 0 end
		ore_top, rise = false, math.max(rise, SOILC.min_rise)
	end
	if ore_top or rise < 0 then return 0 end
	local NL = 8
	local function noise_t(lo, hi) return math.floor(NL * (lo + (hi - lo) * fbm(x / 14, z / 14, 41)) + 0.5) end
	if rise >= SOILC.min_rise then
		local tot, hill = 0, 0
		if stress.has_terrain(cfg) then tot, hill = stress.terrain_rise(cfg, x, z) end
		local of = stress.outcrop_factor(cfg, x, z)          -- 露頭：不鋪或漸薄，也不種樹
		local tree = of >= 1 and stress.tree_at(x, z)
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
