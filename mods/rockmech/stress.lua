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

-- 位置的初始應力。lith 為岩性表條目（需有 gamma）。
-- 回傳 {h=, sv=, sh=}（MPa）
function stress.initial(cfg, lith, y)
	local h = stress.depth(y, cfg.surface_y)
	local sv = stress.sigma_v(lith.gamma, h)
	return {h = h, sv = sv, sh = stress.sigma_h(sv, cfg.k0)}
end

-- 區帶模式：x 所在區帶的岩性名稱
function stress.zone_at_x(cfg, x)
	local W = cfg.zone_width
	local k = math.floor((x + W / 2) / W)
	local order = cfg.zone_order
	return order[k % #order + 1]
end

-- 某位置的岩性名稱（依 cfg.lith_mode）
function stress.lith_key_at(cfg, x, y)
	if cfg.lith_mode == "zones" then
		return stress.zone_at_x(cfg, x)
	end
	return stress.layer_at_depth(cfg.layers, stress.depth(y, cfg.surface_y))
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
