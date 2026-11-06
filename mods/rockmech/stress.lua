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

function stress.lane_terrain(cfg, x, z)
	local T, s = cfg.lane_terrain, cfg.coal_seam
	if not (T and s and s.lane_w) then return 0 end
	local W = s.lane_w
	local k = math.floor((x + W / 2) / W)
	if k < s.lane_min - 1 or k > s.lane_max + 1 then return 0 end
	local lx = x - k * W
	-- 走廊：z0 以南漸變成平地
	local zf = z >= T.z0 and 1 or bump((T.z0 - z) / T.taper)
	if zf <= 0 then return 0 end
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
	return h * zf
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

return stress
