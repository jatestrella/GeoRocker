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
--   落差 Δ = E_s − E_n，臨界落差 Δc = 8·d·tan(殘餘摩擦角)
--   超出量 x = Δ − Δc > 0 才流；取超出量最大的方向。
--   流量 a = min(來源頂格的級數, ⌈x / 2⌉)  —— 兩欄各差一半，趨向殘餘摩擦角
--   （x < 1，即不到 1/8 m，視為已穩定）
--
-- 回傳的流量以「級」（1/8 m³）為單位；搬運由引擎端執行。

local granular = {}

local floor, ceil, sqrt = math.floor, math.ceil, math.sqrt

-- 表面高度（八分之一公尺）。k：該格碎石級數（滿格實心格用 8）
function granular.surface(y, k)
	return 8 * y - 4 + k
end

-- 朗肯被動土壓係數：Kp = (1 + sinφ) / (1 − sinφ)
function granular.passive_k(phi_deg)
	local s = math.sin(math.rad(phi_deg))
	return (1 + s) / (1 - s)
end

-- 碎石受壓的換算高度（八分之一公尺）：荷重 q (kPa) 扣掉側向的被動抗力 Kp·γ·h 之後，等於多高的碎石。
-- h (m)：那一側的碎石比這一格高出多少。平面上 h = 0，陷進碎石堆就越來越推不動。
-- 回填、落石、車輛、應力解的碎石應力都走這一條，只差 q 怎麼來
function granular.squeeze_head(q, gamma, kp, h)
	return 8 * math.max(0, q - kp * gamma * math.max(0, h or 0)) / gamma
end

-- 由表面高度反推所在格與級數：回傳 y, k（1..8）
function granular.cell_of_surface(e)
	local y = ceil((e - 4) / 8)
	if e - (8 * y - 4) == 0 then y = y - 1 end
	return y, e - (8 * y - 4)
end

-- 選擇流向與流量。
-- src_e：來源表面；avail：來源頂格可流出的級數；tan_r：tan(殘餘摩擦角)
-- nbs：{{e = 鄰欄表面（nil = 擋住，不能流）, d = 水平距離}, ...}
-- cap（可選）：這一步最多流幾級
-- 回傳 index, amount（不流時回傳 nil）
function granular.choose_flow(src_e, avail, nbs, tan_r, cap)
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
	if cap then a = math.min(a, cap) end
	return best, a
end

-- 8 方向（含對角）與其水平距離
granular.DIRS = {
	{1, 0, 1}, {-1, 0, 1}, {0, 1, 1}, {0, -1, 1},
	{1, 1, sqrt(2)}, {1, -1, sqrt(2)}, {-1, 1, sqrt(2)}, {-1, -1, sqrt(2)},
}

return granular
