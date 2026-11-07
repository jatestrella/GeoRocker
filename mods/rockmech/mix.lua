-- rockmech/mix.lua
-- 混合碎石的合併規則（純函式，不依賴引擎；nodes.lua 和 tests/mix_spec.lua 共用）。
-- 一格碎石最多記兩種成分，param2 = 第一種成分 a 的比例（0..255）。成分是碎石 base 名稱，礦石用 "ore:<礦種>"。
-- ctx：
--   mix_of[base] = {a = 成分, b = 成分, ore = 礦石或 nil}   混合碎石
--   pair[a][b] = base                                        兩種成分 → 混合碎石
--   rank[成分]                                               價值（礦石 3 > 碎石 2 > 土 1）
--   ore_rubble[成分]                                         礦石成分 → 礦石＋廢石那種混合碎石（純礦石用它，param2 255）
-- 規則：同一種直接相加；不同的拆成各成分的體積相加，留體積最大的兩種，其餘併進兩者裡價值低的那種
--（一樣低併進第二多的；品位只會被稀釋）。比例到 0 或 1 變回純的那種（礦石＋X 到 1 還是那種混合碎石）。

local M = {}

local function rank(ctx, c) return ctx.rank[c] or 2 end

-- 一份碎石（base、k 級、param2）拆成各成分的體積，加進 into
function M.parts(ctx, base, k, p2, into)
	local m = ctx.mix_of[base]
	if m then
		local f = (p2 or 0) / 255
		into[m.a] = (into[m.a] or 0) + k * f
		into[m.b] = (into[m.b] or 0) + k * (1 - f)
	else
		into[base] = (into[base] or 0) + k
	end
	return into
end

local function pair_base(ctx, x, y)
	if ctx.pair[x] and ctx.pair[x][y] then return ctx.pair[x][y], x end
	if ctx.pair[y] and ctx.pair[y][x] then return ctx.pair[y][x], y end
end

-- 各成分的體積 → 一種碎石（base, param2）
function M.compose(ctx, v)
	local list = {}
	for c, x in pairs(v) do if x > 0 then list[#list + 1] = c end end
	table.sort(list, function(p, q)
		if v[p] ~= v[q] then return v[p] > v[q] end
		if rank(ctx, p) ~= rank(ctx, q) then return rank(ctx, p) > rank(ctx, q) end
		return p < q
	end)
	local c1, c2 = list[1], list[2]
	if not c1 then return nil, 0 end
	local rest = 0
	for i = 3, #list do rest = rest + v[list[i]] end
	local v1, v2 = v[c1], c2 and v[c2] or 0
	if c2 and rank(ctx, c1) < rank(ctx, c2) then v1 = v1 + rest else v2 = v2 + rest end
	if not c2 then
		if ctx.ore_rubble[c1] then return ctx.ore_rubble[c1], 255 end
		return c1, 0
	end
	local base, a = pair_base(ctx, c1, c2)
	if not base then       -- 沒有這種組合（兩種礦石）：第二種當第一種的廢石
		return ctx.ore_rubble[c1] or ctx.ore_rubble[c2], math.floor(255 * v1 / (v1 + v2) + 0.5)
	end
	local p2 = math.floor(255 * (a == c1 and v1 or v2) / (v1 + v2) + 0.5)
	local m = ctx.mix_of[base]
	if p2 <= 0 then return m.b, 0 end
	if p2 >= 255 and not m.ore then return m.a, 0 end
	return base, p2
end

-- 合併兩份碎石（b1 的 k1 級 param2 p1，加 b2 的 k2 級 param2 p2）→ base, param2
function M.merge(ctx, b1, k1, p1, b2, k2, p2)
	if b1 == b2 and not ctx.mix_of[b1] then return b1, 0 end
	return M.compose(ctx, M.parts(ctx, b2, k2, p2, M.parts(ctx, b1, k1, p1, {})))
end

-- 有凝聚力的土能自立的臨空高度（m）：H_c = 4c/γ·tan(45° + φ/2)。c kPa、γ kN/m³、φ 度
function M.standing_height(c, gamma, phi)
	return 4 * c / math.max(1, gamma) * math.tan(math.rad(45 + phi / 2))
end

return M
