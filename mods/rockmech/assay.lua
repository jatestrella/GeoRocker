-- rockmech/assay.lua
-- 碎石的成分（化驗值）：存在方塊的 metadata，跟著碎石走（掉落、搬運、混合、出售）。
-- 原地的岩石不存：含量看 param2（礦石岩性的品位）或地質公式，挖下來變成碎石的那一刻才寫進 metadata。
--
-- 成分 c 是一個表：c.g = 第一種成分的比例，刻度跟 param2 一樣（0..255；礦石碎石就是品位）。
-- 之後的多元素（副產品）會在 c 裡加其他鍵；param2 仍然照 c.g 寫，給外觀（品位段的顏色）和沒有 metadata 時備用。
--
-- 岩石組成（體積表）：c["v:<成分>"] = 體積比例（總和 1；成分是 mix.lua 的成分：碎石 base 或 "ore:<礦種>"）。
--   只有混了三種以上成分才記（兩種的話 方塊種類＋param2 就是完整的比例，跟原本一樣）；
--   方塊的種類和外觀照體積最大的兩種（mix.compose），其餘的比例留在表裡不會被併掉。
--
-- 規則：
--   讀：assay.get(pos, node) —— 碎石讀 metadata（沒有就用 param2）；礦石岩石用 rubble_p2；其他是 0
--   寫：assay.place(pos, base, k, c[, swap]) 放好方塊並寫 metadata；VoxelManip 寫完後對每格呼叫 assay.set
--   檢查：/rockmech_assay [半徑] 找出 metadata 不見或跟 param2 對不上的碎石（漏改的路徑）

local A = {}
rockmech.assay = A

local KEY = "rm_assay"
A.KEY = KEY

-- 這種碎石要不要記成分（混合碎石：礦石＋廢石、崩積土……，param2 是第一種成分的比例）
function A.tracked(name)
	local b = rockmech.rubble_base[name]
	return b ~= nil and rockmech.mix_of[b] ~= nil
end

function A.new(g) return {g = g or 0} end
local VP = "v:"                    -- 體積表的鍵前綴
A.VP = VP
local function is_v(k) return type(k) == "string" and k:sub(1, 2) == VP end
A.is_v = is_v
function A.has_v(c)
	if type(c) ~= "table" then return false end
	for k in pairs(c) do if is_v(k) then return true end end
	return false
end
-- 呼叫端傳的「品位」可以是數字（param2）或成分表：統一成表／取主成分的數字
function A.c(x)
	if type(x) == "table" then return x end
	return {g = x or 0}
end
function A.g(x)
	if type(x) == "table" then return x.g or 0 end
	return x or 0
end
-- 副產品（g 以外的鍵）的累加器：acc[k] += w × c[k]
function A.extras_add(acc, c, w)
	if type(c) ~= "table" then return acc end
	for k, v in pairs(c) do
		if k ~= "g" then
			acc = acc or {}
			acc[k] = (acc[k] or 0) + w * v
		end
	end
	return acc
end
function A.copy(c)
	local t = {}
	for k, v in pairs(c or {}) do t[k] = v end
	if t.g == nil then t.g = 0 end
	return t
end
-- 成分 → param2（外觀、備用）
function A.p2(c)
	return math.max(0, math.min(255, math.floor((c and c.g or 0) + 0.5)))
end

-- 文字格式："g=123;au=0.6"（鍵照字母排，同樣的成分一定是同樣的字串）
function A.encode(c)
	local keys = {}
	for k in pairs(c) do keys[#keys + 1] = k end
	table.sort(keys)
	local parts = {}
	for _, k in ipairs(keys) do parts[#parts + 1] = k .. "=" .. ("%.6g"):format(c[k]) end
	return table.concat(parts, ";")
end
function A.decode(s)
	if not s or s == "" then return nil end
	local c = {}
	for k, v in s:gmatch("([^=;]+)=([^;]+)") do c[k] = tonumber(v) end
	if c.g == nil then return nil end
	return c
end

-- 礦石岩性的方塊（原地的礦石：沒有 metadata；被搬動過的礦石岩塊，例如翻滾落石停下來，才有）
local function ore_rock(name)
	local lith = rockmech.lith_of_node[name]
	return lith ~= nil and lith.ore ~= nil
end
function A.carries(name) return A.tracked(name) or ore_rock(name) end

-- 某格的成分。node 可省（自己讀）
function A.get(pos, node)
	node = node or core.get_node(pos)
	if A.tracked(node.name) then
		local c = A.decode(core.get_meta(pos):get_string(KEY))
		if c then return c end
		return A.new(node.param2)                       -- 舊世界、還沒改到的路徑：照 param2
	end
	if rockmech.rubble_level[node.name] then             -- 一般碎石：混了三種以上成分才有 metadata
		return A.decode(core.get_meta(pos):get_string(KEY)) or A.new(0)
	end
	if ore_rock(node.name) then
		local c = A.decode(core.get_meta(pos):get_string(KEY))
		if c then return c end
	end
	return A.new(rockmech.rubble_p2(node))              -- 岩石破碎：礦石的品位（其他岩石是 0）
end

-- 方塊已經放好（name），寫上成分；不需要記的就清掉（換成別的方塊時 swap_node 會留下舊的 metadata）。
-- 原地的礦石不寫（成分看 param2）；被搬動過的礦石岩塊才寫
function A.set(pos, name, c)
	local meta = core.get_meta(pos)
	if A.carries(name) or A.has_v(c) then
		meta:set_string(KEY, A.encode(c))
		meta:mark_as_private(KEY)
	elseif meta:get_string(KEY) ~= "" then
		meta:set_string(KEY, "")
	end
end

-- 放 k 級 base 碎石、成分 c（swap = true 用 swap_node，不觸發 on_construct／on_destruct）。
-- k ≤ 0 移除那格。回傳放下的方塊名稱或 nil
function A.place(pos, base, k, c, swap)
	local p2 = A.p2(c)
	local name = rockmech.rubble_with_level(base, k, p2)
	if not name then
		core.remove_node(pos)
		return nil
	end
	if swap then core.swap_node(pos, {name = name, param2 = p2}) else core.set_node(pos, {name = name, param2 = p2}) end
	A.set(pos, name, c)
	return name
end

-- 岩石（pos 的 node）破碎 → 滿格碎石名稱, 成分。成分要在移除岩石之前讀（被搬動過的礦石岩塊有 metadata）
function A.break_rock(pos, node)
	local c = A.get(pos, node)
	return rockmech.rubble_with_level(rockmech.rubble_for(node.name), rockmech.RUBBLE_LEVELS, A.p2(c)), c
end
-- 從 metadata 的表（after_dig_node 的 oldmetadata、掉落方塊的 self.meta）和 node 取成分
function A.from_metatable(mt, node)
	local c = A.decode(mt and mt.fields and mt.fields[KEY])
	if c then return c end
	if A.tracked(node.name) then return A.new(node.param2) end
	if rockmech.rubble_level[node.name] then return A.new(0) end
	return A.new(rockmech.rubble_p2(node))
end

-- 副產品（g 以外的鍵；含量是「每單位碎石體積」的，所以混合照體積加權）：x1 是 k1 份、x2 是 k2 份 → 混合後
function A.extras_mix(x1, k1, x2, k2)
	if k1 + k2 <= 0 then return nil end
	local out
	for _, pair in ipairs({{x1, k1}, {x2, k2}}) do
		local x, k = pair[1], pair[2]
		if type(x) == "table" then
			for key, v in pairs(x) do
				if key ~= "g" and not is_v(key) then
					out = out or {}
					out[key] = (out[key] or 0) + k * v
				end
			end
		end
	end
	if out then for key, v in pairs(out) do out[key] = v / (k1 + k2) end end
	return out
end
-- 只取副產品（g 以外）；沒有回傳 nil
function A.extras(c)
	if type(c) ~= "table" then return nil end
	local out
	for k, v in pairs(c) do if k ~= "g" then out = out or {}; out[k] = v end end
	return out
end
-- 主成分 g 加上副產品 x → 成分表
function A.with(g, x)
	local c = {g = g or 0}
	if x then for k, v in pairs(x) do c[k] = v end end
	return c
end

-- base 的 k 份、成分 c（數字或表）拆成各成分的體積，加進 into：有體積表照表，沒有照 base＋param2（mix.parts）
function A.vol(base, c, k, into)
	into = into or {}
	if A.has_v(c) then
		for key, v in pairs(c) do
			if is_v(key) then local n = key:sub(3); into[n] = (into[n] or 0) + k * v end
		end
	elseif base then
		rockmech.mix.parts(rockmech.mix_ctx, base, k, A.g(c), into)
	end
	return into
end
-- 體積表 → 方塊種類, param2, 成分數（同族金屬礦合併後；compose 會改表，所以用複本）
local function compose(v)
	local t = {}
	for n, x in pairs(v) do t[n] = x end
	local b, p = rockmech.mix.compose(rockmech.mix_ctx, t)
	local cnt = 0
	for _, x in pairs(t) do if x > 1e-9 then cnt = cnt + 1 end end
	return b, p, cnt
end
A.compose = compose
-- 把體積表 v（總量 w）寫進成分 c
local function put_v(c, v, w)
	for n, x in pairs(v) do if x > 1e-9 * w then c[VP .. n] = x / w end end
end

-- 兩份碎石合併（b1 的 k1 級成分 c1，加 b2 的 k2 級成分 c2）→ 碎石種類, 成分。
-- 各成分的體積相加；方塊照最大的兩種（mix.lua 的規則，param2 四捨五入；兩種成分時跟原本完全一樣），
-- 三種以上時完整的體積表記在成分裡。副產品照體積加權
function A.merge(b1, k1, c1, b2, k2, c2)
	local v = A.vol(b2, c2, k2, A.vol(b1, c1, k1, {}))
	local b, p, cnt = compose(v)
	local c = A.with(p, A.extras_mix(c1, k1, c2, k2))
	if cnt > 2 then put_v(c, v, k1 + k2) end
	return b or b1, c
end
-- 體積表只剩兩種以下成分：拿掉（方塊種類＋param2 就夠了）
function A.slim(c)
	if not A.has_v(c) then return c end
	local cnt = 0
	for k, v in pairs(c) do if is_v(k) and v > 1e-9 then cnt = cnt + 1 end end
	if cnt <= 2 then for k in pairs(c) do if is_v(k) then c[k] = nil end end end
	return c
end
-- 同一種碎石的累加器（車斗）：acc 裡已經有 lv0 級（主成分總和 q0），再放 lv 級成分 c。
-- 有一方帶體積表時，另一方照 base＋param2 展開，加權才對
function A.acc_put(acc, base, lv0, q0, c, lv)
	local cv, av = A.has_v(c), A.has_v(acc)
	if cv and not av and lv0 > 0 then
		acc = acc or {}
		for n, x in pairs(A.vol(base, q0 / lv0, lv0, {})) do acc[VP .. n] = (acc[VP .. n] or 0) + x end
		av = true
	end
	if av and not cv then
		for n, x in pairs(A.vol(base, c, lv, {})) do acc[VP .. n] = (acc[VP .. n] or 0) + x end
	end
	if type(c) == "table" then
		for k, v in pairs(c) do
			if k ~= "g" then acc = acc or {}; acc[k] = (acc[k] or 0) + lv * v end
		end
	end
	return acc
end

-- 累加器（車斗、輸送帶、料倉）：acc = Σ 量 × 成分
function A.acc_add(acc, c, w)
	acc = acc or {}
	for k, v in pairs(c or {g = 0}) do acc[k] = (acc[k] or 0) + w * v end
	return acc
end
-- 累加器 → 平均成分（總量 w）。g 照舊四捨五入成整數（跟 param2 一樣的刻度）
function A.acc_avg(acc, w)
	if not acc or not w or w <= 0 then return A.new(0) end
	local c = {}
	for k, v in pairs(acc) do c[k] = v / w end
	c.g = math.floor((c.g or 0) + 0.5)
	return c
end
-- 累加器只留下 f（0..1）的量
function A.acc_scale(acc, f)
	if not acc then return nil end
	if f <= 0 then return nil end
	for k, v in pairs(acc) do acc[k] = v * f end
	return acc
end

-- 檢查：範圍內要記成分的碎石，metadata 不見或跟 param2 對不上的格數
function A.scan(minp, maxp, limit)
	local missing, mismatch, total, where, multi = 0, 0, 0, {}, 0
	local list = core.find_nodes_in_area(minp, maxp, {"group:rockmech_rubble"})
	for _, p in ipairs(list) do
		local n = core.get_node(p)
		local mc = A.decode(core.get_meta(p):get_string(KEY))
		if A.has_v(mc) then                  -- 三種以上成分：方塊要是體積表最大的兩種
			multi = multi + 1
			local b, p2 = compose(A.vol(nil, mc, 1, {}))
			if b ~= rockmech.rubble_base[n.name] or (rockmech.mix_of[b] and p2 ~= n.param2) then
				mismatch = mismatch + 1
				if #where < (limit or 5) then where[#where + 1] = ("%s %s≠%s"):format(core.pos_to_string(p), tostring(b), tostring(rockmech.rubble_base[n.name])) end
			end
		elseif A.tracked(n.name) then
			total = total + 1
			local c = A.decode(core.get_meta(p):get_string(KEY))
			if not c then
				missing = missing + 1
				if #where < (limit or 5) then where[#where + 1] = core.pos_to_string(p) .. " 沒有" end
			elseif A.p2(c) ~= n.param2 then
				mismatch = mismatch + 1
				if #where < (limit or 5) then where[#where + 1] = ("%s %d≠%d"):format(core.pos_to_string(p), A.p2(c), n.param2) end
			end
		end
	end
	return total, missing, mismatch, where, multi
end

core.register_chatcommand("rockmech_assay", {
	params = "[radius]",
	privs = {rockmech = true},
	description = "Check that ore rubble nearby carries its assay metadata (debug)",
	func = function(name, param)
		local player = core.get_player_by_name(name)
		if not player then return false end
		local r = math.max(1, math.min(48, tonumber(param) or 16))
		local p = vector.round(player:get_pos())
		local total, missing, mismatch, where, multi = A.scan(vector.subtract(p, r), vector.add(p, r))
		return true, ("assay: %d ore rubble, %d missing, %d mismatch, %d with 3+ parts %s"):format(total, missing, mismatch, multi, table.concat(where, ", "))
	end,
})

return A
