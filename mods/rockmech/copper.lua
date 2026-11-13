-- rockmech/copper.lua
-- 銅（金屬礦）的選礦與計價：純函式，不依賴引擎（crusher.lua、plant.lua、orders.lua、單元測試共用）。
-- 銅礦物是浸染狀的，挑不出純礦塊：碎石的 param2 直接是含銅量 c = param2/255 × metal.scale（config.lua 的 ores.copper）。
--
-- 浮選（選礦場）：回收率 R = R0 × c ÷ (c + k)，進料越貧越難選；精礦品位固定 Cg（研發可提高）。
--   精礦的銅 = 量 × c × R，精礦量 = 精礦的銅 ÷ Cg，其餘是尾礦。進料 c ≥ Cg（例如精礦倒回去）：全部進精礦、品位不變、沒有尾礦。
-- 精礦計價：含銅噸數 × 銅價 − 精礦噸數 × 冶煉費 tc（冶煉廠按每噸精礦收，所以精礦品位高比較划算）。
-- 外包選礦（原礦直接送破碎站）：照同一條浮選公式，回收率再乘 outsource，精礦照起始品位計價；尾礦每噸付廢料處理費。

local M = {}

-- 碎石的含銅量（0..1）；不是金屬礦回傳 nil
function M.content(ore, g)
	local m = ore and ore.metal
	return m and g * m.scale or nil
end

-- 浮選回收率
function M.recovery(c, R0, k)
	if c <= 0 then return 0 end
	return R0 * c / (c + k)
end

-- 浮選：量 t（噸或級都可以）、含銅 c → 精礦量, 精礦的銅, 尾礦量, 尾礦的銅
function M.float(t, c, Cg, R0, k)
	if t <= 0 then return 0, 0, 0, 0 end
	if c >= Cg then return t, t * c, 0, 0 end
	if c <= 0 then return 0, 0, t, 0 end
	local cu = t * c * M.recovery(c, R0, k)
	local pt = cu / Cg
	return pt, cu, t - pt, t * c - cu
end

-- 精礦的貨款：精礦 t 噸、含銅 cu 噸
function M.conc_value(t, cu, price, tc)
	return cu * price - t * tc
end

-- 外包選礦（原礦送破碎站）的帳：t 噸、含銅 c → 貨款, 尾礦噸數, 精礦噸數, 回收的銅
--   m = ore.metal；price：今天的銅價；R0：回收率（含研發）；fee：每噸尾礦的處理費
function M.toll(t, c, m, price, R0, fee)
	local pt, cu, tail = M.float(t, c, m.conc_grade, R0 * (m.outsource or 1), m.k)
	return M.conc_value(pt, cu, price, m.tc), tail, pt, cu
end

-- 截止品位：外包選礦不賺不賠的含銅量（二分法；貨款隨 c 單調增加）
function M.cutoff(m, price, R0, fee)
	local lo, hi = 0, m.conc_grade
	for _ = 1, 40 do
		local c = (lo + hi) / 2
		local v, tail = M.toll(1, c, m, price, R0, fee)
		if v - tail * fee > 0 then hi = c else lo = c end
	end
	return (lo + hi) / 2
end

-- 同一族金屬的碎石成分（例如原礦、精礦、尾礦）互相混合：按含銅量合併成一種。
-- parts：成分 → 體積；fam：成分 → {scale, waste（混合用的廢石成分）}（只列金屬礦的成分）。
-- 選刻度最細、裝得下的那一種（銅 ÷ 刻度 ≤ 這一族的總體積），多出來的體積變成它的廢石。直接改 parts
function M.merge_family(parts, fam)
	local groups = {}
	for c, v in pairs(parts) do
		local f = fam[c]
		if f and v > 0 then
			local g = groups[f.family]
			if not g then g = {cu = 0, vol = 0, list = {}}; groups[f.family] = g end
			g.cu = g.cu + v * f.scale
			g.vol = g.vol + v
			g.list[#g.list + 1] = c
		end
	end
	for name, g in pairs(groups) do
		if #g.list > 1 then
			local cands = {}
			for c, f in pairs(fam) do if f.family == name then cands[#cands + 1] = c end end
			table.sort(cands, function(a, b) return fam[a].scale < fam[b].scale end)
			local pick
			for _, c in ipairs(cands) do
				if g.cu / fam[c].scale <= g.vol + 1e-9 then pick = c; break end
			end
			pick = pick or cands[#cands]
			for _, c in ipairs(g.list) do parts[c] = nil end
			local v = math.min(g.vol, g.cu / fam[pick].scale)
			parts[pick] = v
			local w = fam[pick].waste
			if g.vol - v > 1e-9 then parts[w] = (parts[w] or 0) + (g.vol - v) end
		end
	end
	return parts
end

return M
