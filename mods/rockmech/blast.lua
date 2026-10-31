-- rockmech/blast.lua
-- 爆破破碎的範圍計算（純函式，不依賴引擎）。
--
-- 爆炸半徑 R（原版 TNT：R = ⌊R0 · n^(1/3)⌋，n 為一起引爆的 TNT 數）。
-- 岩石的破碎半徑依強度縮放：r_out = R · (UCS_ref / UCS)^(1/3)
--   （同樣的炸藥，岩石越弱破碎範圍越大；UCS_ref 預設 60 MPa = 砂岩為 1 倍）
-- 距爆心 d：
--   d ≤ inner · r_out → "eject"：炸飛（變成噴出的碎石物品）
--   d ≤ r_out         → "rubble"：原地破碎成碎石
--   其他              → nil：不受影響

local blast = {}

-- exp：強度指數。炸開的體積 ∝ 半徑³ ∝ UCS^(−3·exp)，1/6 就是單位炸藥量 ∝ √UCS
function blast.factor(ucs, ucs_ref, exp)
	if not ucs or ucs <= 0 then return 1 end
	return ((ucs_ref or 60) / ucs) ^ (exp or 1 / 6)
end

function blast.effective_radius(r0, n_tnt)
	return math.floor(r0 * math.max(1, n_tnt) ^ (1 / 3))
end

function blast.zone(d, R, ucs, ucs_ref, inner, exp)
	local r_out = R * blast.factor(ucs, ucs_ref, exp)
	if d <= (inner or 0.5) * r_out then return "eject" end
	if d <= r_out then return "rubble" end
	return nil
end

return blast
