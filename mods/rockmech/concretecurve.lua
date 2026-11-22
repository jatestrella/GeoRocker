-- rockmech/concretecurve.lua
-- 混凝土的強度發展與材料參數（純函式，不依賴引擎；concrete.lua、單元測試用）。單位 MPa、天。
--   強度發展（ACI 209R-92，一般水泥、濕治養）：f_c(t) = f_c28 · t / (4 + 0.85 t)。1 天約 21 %、7 天約 70 %、28 天 100 %，
--   之後還會慢慢長（極限約 1.18 倍）。
--   破裂模數（素混凝土受拉開裂，ACI 318）：f_r = 0.62 √f_c
--   彈性模數（ACI 318）：E_c = 4700 √f_c

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

return M
