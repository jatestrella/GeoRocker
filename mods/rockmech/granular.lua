-- rockmech/granular.lua
-- 碎石的顆粒流（純函式，不依賴引擎）。
--
-- 碎石不再一定是整格：每格分 8 級（1/8 m），滿格 = 8。一欄碎石的表面高度以
-- 「八分之一公尺」為單位的整數表示：
--   E = 8·y − 4 + k      （k = 該格碎石級數；格 y 佔 [y − 0.5, y + 0.5]）
--   滿格的實心格頂面：E = 8·y + 4
--
-- ## 流動
-- 來源欄的表面 E_s，與 8 個方向的鄰欄表面 E_n 比較（水平距離 d = 1 或 √2）：
--   落差 Δ = E_s − E_n，臨界落差 Δc = 8·d·tan(安息角)
--   超出量 x = Δ − Δc > 0 才流；取超出量最大的方向。
--   流量 a = min(來源頂格的級數, ⌈x / 2⌉)  —— 兩欄各差一半，趨向安息角
--   （x < 1，即不到 1/8 m，視為已穩定）
--
-- 回傳的流量以「級」（1/8 m³）為單位；搬運由引擎端執行。

local granular = {}

local floor, ceil, sqrt = math.floor, math.ceil, math.sqrt

-- 表面高度（八分之一公尺）。k：該格碎石級數（滿格實心格用 8）
function granular.surface(y, k)
	return 8 * y - 4 + k
end

-- 超載換算高度（八分之一公尺）：上方的荷重 q (kPa) 等於多高的碎石（q / γ_r，地工的等效超載高度），
-- 加到來源表面上，受壓的碎石就照安息角往旁邊擠
function granular.surcharge(q, gamma)
	return 8 * q / gamma
end

-- 由表面高度反推所在格與級數：回傳 y, k（1..8）
function granular.cell_of_surface(e)
	local y = ceil((e - 4) / 8)
	if e - (8 * y - 4) == 0 then y = y - 1 end
	return y, e - (8 * y - 4)
end

-- 選擇流向與流量。
-- src_e：來源表面；avail：來源頂格可流出的級數；tan_r：tan(安息角)
-- nbs：{{e = 鄰欄表面（nil = 擋住，不能流）, d = 水平距離}, ...}
-- 回傳 index, amount（不流時回傳 nil）
function granular.choose_flow(src_e, avail, nbs, tan_r)
	if avail <= 0 then return nil end
	local best, best_x
	for i, n in ipairs(nbs) do
		if n.e then
			local x = (src_e - n.e) - 8 * n.d * tan_r
			if x >= 1 and (not best_x or x > best_x) then best, best_x = i, x end
		end
	end
	if not best then return nil end
	local a = math.min(avail, math.max(1, ceil(best_x / 2)))
	return best, a
end

-- 8 方向（含對角）與其水平距離
granular.DIRS = {
	{1, 0, 1}, {-1, 0, 1}, {0, 1, 1}, {0, -1, 1},
	{1, 1, sqrt(2)}, {1, -1, sqrt(2)}, {-1, 1, sqrt(2)}, {-1, -1, sqrt(2)},
}

return granular
