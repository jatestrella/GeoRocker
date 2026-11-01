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
function stress.in_seam(s, x, y, z)
	return math.abs(stress.seam_offset(s, x, y, z)) <= s.t / 2
end
-- 煤的品位（param2 1..255）：煤層中央最好，靠頂底板變差（夾雜質），再加緩慢的橫向變化
function stress.seam_grade(s, x, y, z)
	local d = 2 * stress.seam_offset(s, x, y, z) / s.t
	local g = 215 - 120 * d * d + 12 * math.sin(x / 37) + 12 * math.sin(z / 29)
	return math.max(1, math.min(255, math.floor(g + 0.5)))
end

-- 露天坑（cfg.open_pit）：螺旋階梯，中心 (x0, z0)，底半徑 R、深 D（坑底 y = surface − D），
-- 階高 H、階寬 W。每一階是一圈上升 H 的坡道，接到外圈，就是運輸道路。
-- 回傳 (x, z) 這一欄的地面高度（小數，m）；坑外回傳 nil
function stress.pit_surface(p, surface, x, z)
	local dx, dz = x - p.x0, z - p.z0
	local r = math.sqrt(dx * dx + dz * dz)
	if r < p.R then return surface - p.D end
	local n = math.floor((r - p.R) / p.W)
	local turn = ((math.atan2 or math.atan)(dz, dx) / (2 * math.pi)) % 1     -- LuaJIT 的 math.atan 只收一個參數
	local h = surface - p.D + p.H * (n + turn)
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
