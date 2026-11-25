-- rockmech/concretecurve.lua
-- 混凝土的強度發展與材料參數（純函式，不依賴引擎；concrete.lua、單元測試用）。單位 MPa、天。
--   強度發展（ACI 209R-92，一般水泥、濕治養）：f_c(t) = f_c28 · t / (4 + 0.85 t)。1 天約 21 %、7 天約 70 %、28 天 100 %，
--   之後還會慢慢長（極限約 1.18 倍）。
--   破裂模數（素混凝土受拉開裂，ACI 318）：f_r = 0.62 √f_c
--   彈性模數（ACI 318）：E_c = 4700 √f_c
--   鋼筋混凝土的極限彎矩：M_u = A_s·f_y·(d − a/2)

local M = {}

function M.ratio(t)
	if not t or t <= 0 then return 0 end
	return t / (4 + 0.85 * t)
end
function M.fc(fc28, t) return fc28 * M.ratio(t) end
function M.fr(fc) return 0.62 * math.sqrt(math.max(0, fc)) end
function M.ec(fc) return 4700 * math.sqrt(math.max(0, fc)) end
-- 1 m 厚的素混凝土牆（每公尺寬）：開裂彎矩 M_cr = f_r · h² / 6（kN·m/m）、EI = E_c · h³ / 12（kN·m²/m）
function M.mcr(fc, h) h = h or 1; return M.fr(fc) * 1000 * h * h / 6 end
function M.ei(fc, h) h = h or 1; return M.ec(fc) * 1000 * h * h * h / 12 end
-- 鋼筋混凝土的極限彎矩（矩形斷面、拉力筋降伏、Whitney 應力塊）：每公尺寬，As (mm²/m)、fy (MPa)、有效深度 d (m)、
-- a = As·fy / (0.85·f_c·b)，M_u = As·fy·(d − a/2)（kN·m/m；名義強度，不打折減因數）
function M.mu(fc, As, fy, d)
	local T = As * 1e-6 * fy * 1000                    -- kN/m
	local a = T / (0.85 * math.max(1e-3, fc) * 1000)     -- m
	return T * (d - a / 2)
end

-- 水灰比（拌合廠，batching.lua）：Abrams 定律 f_c = A / B^(w/c)。取 w/c 0.50 → 28 MPa（跟預拌車一樣）、0.40 → 38 MPa，
-- 回傳相對於 w/c 0.50 的強度比例（0.40 約 1.36、0.70 約 0.54）。用水量固定 WATER m³/m³ → 水泥 WATER/(w/c) t/m³
M.WATER = 0.18
M.WC_REF = 0.5
local AB = 38 / 28          -- 水灰比每少 0.1 強度乘幾倍
function M.abrams(wc) return AB ^ ((M.WC_REF - wc) / 0.1) end
function M.cement_per_m3(wc) return M.WATER / wc end

return M
