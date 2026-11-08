-- rockmech/conveyor.lua
-- 輸送帶：一格一格的方塊，每格 1 m，朝放的人面對的方向輸送；換個方向接就是轉彎。
-- 裝料：碎石落在任何一格輸送帶上（卡車倒的、怪手放的、旁邊料堆流下來的、選礦場放料臂放的）就被帶走。
-- 每格最多載「運量 ÷ 帶速」的料（rockmech_conveyor_rate t/s ÷ rockmech_conveyor_speed m/s），每 1/帶速 秒往前走一格；
-- 前面那格滿了就停著等，下游塞住整條會跟著停。最後一格往前倒出去，變回地上的碎石（品位跟著料走）：
-- 底下是破碎站、選礦場的受料倉或另一條輸送帶，就接著處理。
-- 坡度：輸送帶表面的高度以 1/8 m 為單位（輸送帶方塊有 8 種高度），每格最多升降 r/8 m，
-- r = floor(8·tan(最大傾角))，最大傾角 rockmech_conveyor_max_angle：碎石在輸送帶上不往回滑的上限
-- （料和輸送帶之間的摩擦，實務上約 15–18°）。轉彎的那一格是平的。
-- 拿著輸送帶右鍵放：點在輸送帶上就從那一格往前接，點在地上就從地面開始；左鍵點輸送帶收回那一格，點別的地方切換坡度。
-- 有輸送帶的區塊一直載入（每格放的時候強制載入它的區塊，拆掉時放掉）。

local cfg = rockmech.cfg
local S = rockmech.S
local V = rockmech.vehicles
local H = rockmech.hopper_lib
local storage = rockmech.collapse.storage

local ITEM = "rockmech:belt"
local BELT_H, BELT_ST, NAME = {}, {}, {}    -- node 名稱 → 表面高度 h（0..7，表面在 (h+1)/8 m）、外觀狀態（"" 空、"w" 載廢石、"o" 載礦）
local SAVE_EVERY = 10       -- 輸送帶上的料多久存檔一次 (s)

local function main_ore()
	for _, ore in pairs(cfg.ores) do return ore end
end
-- 每格最多升降幾個 1/8 m
local function rmax() return math.max(0, math.floor(8 * math.tan(math.rad(cfg.conveyor_max_angle)) + 1e-6)) end
-- 每格最多載幾級（1 級 = 1/8 m³）
local function base_cap() return cfg.conveyor_rate / cfg.conveyor_speed / H.tons_of(1) end
-- 每格的載量：運量 ÷ 帶速，乘上放這格的那一組的「輸送帶改良」研究。格子的帳戶存在 node meta 的 owner，查過就快取
local owner_cache = {}
local function cell_cap(h, p)
	local mult = 1
	if h and p and rockmech.eff_conveyor_mult then
		local o = owner_cache[h]
		if o == nil then o = core.get_meta(p):get_string("owner"); owner_cache[h] = o end
		mult = rockmech.eff_conveyor_mult(o)
	end
	return math.max(1, math.floor(base_cap() * mult))
end

---------------------------------------------------------------------------
-- 方塊
---------------------------------------------------------------------------

local FRAME = "[fill:16x16:#6c6c6c^[fill:16x2:0,0:#4a4a4a"
-- 空的輸送帶面上兩個箭頭（貼圖往上 = 方塊的 +z = 輸送方向）
local ARROW_C = "#8a8a80"
local function chevron(y)
	local t = {}
	for i = 0, 3 do
		t[#t + 1] = ("^[fill:2x1:%d,%d:%s^[fill:2x1:%d,%d:%s"):format(7 - i, y + i, ARROW_C, 7 + i, y + i, ARROW_C)
	end
	return table.concat(t)
end
local RUBBER = "[fill:16x16:#262626" .. chevron(2) .. chevron(9)
local function top_of(h) return (h + 1) / 8 - 0.5 end
-- 形狀（方塊座標：輸送帶往 +z 走，左邊是 −x）：從哪一側有輸送帶接進來，那一側的框架就打開。
--   ""：直的（兩側框架）；cl／cr：轉彎，料從左／右邊進來（那側打開、後端封起來）；
--   ml／mr：直的、左／右邊另外有一條從側面併進來（那側打開）
local SHAPES = {"", "cl", "cr", "ml", "mr"}
-- 支腳：""：正下方是實心方塊，腳到這格底；"l"：正下方是空的或碎石、再下面 1 m 內有東西，腳伸到下一格底（插進碎石裡）；
-- "n"：下面 1 m 內什麼都沒有，不畫腳（不要懸空的短腳）
local LEGS = {"", "l", "n"}
local function boxes(h, loaded, sh, leg)
	local top, b = top_of(h), {}
	local floor = leg == "l" and -1.5 or -0.5
	local function add(x0, y0, z0, x1, y1, z1)
		y0 = math.max(floor, y0)
		if y1 > y0 then b[#b + 1] = {x0, y0, z0, x1, y1, z1} end
	end
	local open_l, open_r = sh == "cl" or sh == "ml", sh == "cr" or sh == "mr"
	add(-0.5, top - 0.1, -0.5, 0.5, top, 0.5)              -- 輸送帶
	if not open_l then add(-0.5, top - 0.25, -0.5, -0.42, top + 0.12, 0.5) end   -- 兩側框架
	if not open_r then add(0.42, top - 0.25, -0.5, 0.5, top + 0.12, 0.5) end
	if sh == "cl" or sh == "cr" then add(-0.5, top - 0.25, -0.5, 0.5, top + 0.12, -0.42) end   -- 轉彎：後端封起來
	if leg ~= "n" and top - 0.25 > floor then               -- 支腳
		add(-0.48, floor, -0.06, -0.4, top - 0.25, 0.06)
		add(0.4, floor, -0.06, 0.48, top - 0.25, 0.06)
	end
	if loaded then                                          -- 輸送帶上的料：從進料的那一側走到前端
		local y0, y1 = top, top + 0.14
		if sh == "cl" or sh == "cr" then add(-0.32, y0, -0.32, 0.32, y1, 0.5) else add(-0.32, y0, -0.5, 0.32, y1, 0.5) end
		if open_l then add(-0.5, y0, -0.32, -0.32, y1, 0.32) end
		if open_r then add(0.32, y0, -0.32, 0.5, y1, 0.32) end
	end
	return b
end

local reverse_line          -- 下面定義（整條反向）
-- 支腳的樣子：看正下方和再下面一格
local function solid_at(p)
	local nm = core.get_node(p).name
	if nm == "air" or nm == "ignore" then return false end
	local d = core.registered_nodes[nm]
	return d ~= nil and d.walkable ~= false
end
local function leg_of(p)
	local b1 = {x = p.x, y = p.y - 1, z = p.z}
	if rockmech.rubble_level and rockmech.rubble_level[core.get_node(b1).name] then return "l" end
	if solid_at(b1) then return "" end
	if solid_at({x = p.x, y = p.y - 2, z = p.z}) then return "l" end
	return "n"
end
local cells = {}            -- 位置 hash → 位置（目前知道的輸送帶格）
local loads = {}            -- 位置 hash → {{b = 碎石種類, k = 級數, g = 品位 param2}, ...}（空的不存）
local dirty = false
do
	local s = storage:get_string("belt_loads")
	loads = s ~= "" and core.deserialize(s) or {}
end

local function total(L)
	local n = 0
	if L then for _, q in ipairs(L) do n = n + q.k end end
	return n
end
-- 加料到一格（能混的併在一起，品位依級數加權）
local function add_load(h, b, k, g)
	if k <= 0 then return end
	local L = loads[h] or {}
	loads[h] = L
	dirty = true
	for _, q in ipairs(L) do
		if rockmech.rubble_mixable(q.b, b) then
			q.b, q.g = rockmech.rubble_merge(q.b, q.k, q.g, b, k, g)
			q.k = q.k + k
			return
		end
	end
	L[#L + 1] = {b = b, k = k, g = g or 0}
end

local function register_cell(pos)
	cells[core.hash_node_position(pos)] = vector.new(pos)
end

local BELT_SH = {}           -- node 名稱 → 形狀（SHAPES）
for h = 0, 7 do
	NAME[h] = {}
	for _, st in ipairs({"", "w", "o"}) do
	NAME[h][st] = {}
	for _, sh in ipairs(SHAPES) do
	NAME[h][st][sh] = {}
	for _, leg in ipairs(LEGS) do
		local name = "rockmech:belt_" .. h .. (st ~= "" and ("_" .. st) or "") .. (sh ~= "" and ("_" .. sh) or "") .. (leg ~= "" and ("_" .. leg) or "")
		NAME[h][st][sh][leg], BELT_H[name], BELT_ST[name], BELT_SH[name] = name, h, st, sh
		local ore = main_ore()
		local top = st == "" and RUBBER or V.rubble_tex(st == "o" and ore and ore.rubble or rockmech.RUBBLE)
		local sel = {-0.5, -0.5, -0.5, 0.5, top_of(h) + 0.12, 0.5}
		core.register_node(name, {
			description = S("Conveyor belt"),
			drawtype = "nodebox",
			paramtype = "light",
			paramtype2 = "4dir",
			sunlight_propagates = true,
			node_box = {type = "fixed", fixed = boxes(h, st ~= "", sh, leg)},
			selection_box = {type = "fixed", fixed = sel},
			collision_box = {type = "fixed", fixed = sel},
			tiles = {top, FRAME, FRAME, FRAME, FRAME, FRAME},
			groups = {cracky = 3, oddly_breakable_by_hand = 2, rockmech_belt = 1, not_in_creative_inventory = 1},
			drop = ITEM,
			is_ground_content = false,
			on_construct = function(pos)
				register_cell(pos)
				core.forceload_block(pos, false, -1)
				core.get_meta(pos):set_int("forceload", 1)
			end,
			on_destruct = function(pos)
				owner_cache[core.hash_node_position(pos)] = nil
				if core.get_meta(pos):get_int("forceload") == 1 then core.forceload_free_block(pos, false) end
			end,
			-- 拆掉：這格上的料倒在原地
			after_destruct = function(pos)
				local hh = core.hash_node_position(pos)
				cells[hh] = nil
				for _, q in ipairs(loads[hh] or {}) do V.deposit_column(pos.x, pos.z, pos.y, q.b, q.k, nil, nil, q.g) end
				loads[hh], dirty = nil, true
			end,
		})
	end
	end
	end
end

-- 載入的區塊裡的輸送帶記到 cells（重開遊戲後，強制載入的區塊一開始就會載入）
core.register_lbm({
	label = "rockmech: 輸送帶登記",
	name = "rockmech:belt_register",
	nodenames = {"group:rockmech_belt"},
	run_at_every_load = true,
	action = function(pos) register_cell(pos) end,
})

---------------------------------------------------------------------------
-- 輸送
---------------------------------------------------------------------------

local function belt_at(p)
	local n = core.get_node_or_nil(p)
	return n, n and BELT_H[n.name] ~= nil
end
local function surf(p, n) return p.y * 8 + BELT_H[n.name] end   -- 表面高度（1/8 m 為單位）
local function dir_of(n) return core.fourdir_to_dir(n.param2 % 4) end

-- 下一格輸送帶：前方那一欄、表面高度差不超過 rmax、不是迎面對著的。
-- 回傳 位置（或 nil = 這格是頭）, 方向, 前方還沒載入（"wait"）
local function next_of(p, n)
	local d = dir_of(n)
	local S, R = surf(p, n), math.max(1, rmax())
	local best, bs
	for dy = -1, 1 do
		local q = {x = p.x + d.x, y = p.y + dy, z = p.z + d.z}
		local m, is = belt_at(q)
		if not m then return nil, d, "wait" end
		if is then
			local d2 = dir_of(m)
			local dS = math.abs(surf(q, m) - S)
			if dS <= R and not (d2.x == -d.x and d2.z == -d.z) and (not bs or dS < bs) then best, bs = q, dS end
		end
	end
	return best, d
end

-- 上一格：旁邊（高低差一格內）把料送進 c 的輸送帶；正後方那格優先
local function same(a, b) return a and b and a.x == b.x and a.y == b.y and a.z == b.z end
local function prev_of(c, cn)
	local d = dir_of(cn or core.get_node(c))
	local found
	for _, s in ipairs({{-d.x, -d.z}, {d.z, -d.x}, {-d.z, d.x}, {d.x, d.z}}) do
		for dy = -1, 1 do
			local q = {x = c.x + s[1], y = c.y + dy, z = c.z + s[2]}
			local m, is = belt_at(q)
			if is and same(next_of(q, m), c) then
				if s[1] == -d.x and s[2] == -d.z then return q end
				found = found or q
			end
		end
	end
	return found
end

-- 整條反向：從 p 往上游找到頭、往下游找到尾，每格改成朝原本的上一格
reverse_line = function(p, name)
	local seen = {}
	local start = p
	while true do
		seen[core.hash_node_position(start)] = true
		local q = prev_of(start)
		if not q or seen[core.hash_node_position(q)] then break end
		start = q
	end
	local chain, cur, seen2 = {}, start, {}
	while cur and not seen2[core.hash_node_position(cur)] do
		seen2[core.hash_node_position(cur)] = true
		chain[#chain + 1] = cur
		local n, is = belt_at(cur)
		if not is then break end
		cur = next_of(cur, n)
	end
	if #chain < 2 then
		-- 只有一格：轉 180°
		local n = core.get_node(p)
		core.swap_node(p, {name = n.name, param2 = (n.param2 + 2) % 4})
	else
		for i = 1, #chain do
			local a = chain[i]
			local b = i > 1 and chain[i - 1] or nil
			local dx, dz
			if b then dx, dz = b.x - a.x, b.z - a.z else dx, dz = a.x - chain[2].x, a.z - chain[2].z end
			local n = core.get_node(a)
			core.swap_node(a, {name = n.name, param2 = core.dir_to_fourdir({x = dx, y = 0, z = dz})})
		end
	end
	if name then rockmech.notify(name, S("[Conveyor]") .. " " .. S("Reversed (@1 m)", tostring(math.max(1, #chain)))) end
end
rockmech.belt_reverse = reverse_line

-- 對著輸送帶按 E（aux1）：整條反向。按下去那一下才算；坐在車上不算（車上的 E 是作業鍵）
local e_down = {}
local function e_check(pl)
	local name = pl:get_player_name()
	local down = pl:get_player_control().aux1
	if down and not e_down[name] and not pl:get_attach() then
		local eye = vector.add(pl:get_pos(), {x = 0, y = pl:get_properties().eye_height or 1.625, z = 0})
		local tip = vector.add(eye, vector.multiply(pl:get_look_dir(), 6))
		for th in core.raycast(eye, tip, false, false) do
			if th.type == "node" then
				if BELT_H[core.get_node(th.under).name] and not core.is_protected(th.under, name) then
					reverse_line(th.under, name)
				end
				break
			end
		end
	end
	e_down[name] = down
end
rockmech.belt_e_check = e_check      -- 測試用
core.register_globalstep(function()
	for _, pl in ipairs(core.get_connected_players()) do e_check(pl) end
end)
core.register_on_leaveplayer(function(pl) e_down[pl:get_player_name()] = nil end)

-- 把 a 格的料往 b 格移，最多移到 b 滿（b 格自己的載量：各組的研究加成不同）
local function move(ha, hb)
	local A = loads[ha]
	if not A then return end
	local room = cell_cap(hb, cells[hb]) - total(loads[hb])
	while room > 0 and #A > 0 do
		local q = A[1]
		local k = math.min(q.k, room)
		add_load(hb, q.b, k, q.g)
		q.k, room = q.k - k, room - k
		if q.k <= 0 then table.remove(A, 1) end
	end
	if #A == 0 then loads[ha] = nil end
	dirty = true
end

-- 粒子：輸送帶上滾動的碎石顆粒、頭端倒出去的料流。只給附近（PARTICLE_R m 內）有玩家的格子，一步最多 PARTICLE_MAX 格
local PARTICLE_R, PARTICLE_MAX = 64, 80
local function near_player(p)
	for _, pl in ipairs(core.get_connected_players()) do
		local pp = pl:get_pos()
		if pp and vector.distance(pp, p) <= PARTICLE_R then return true end
	end
	return false
end
-- 顆粒的顏色：以礦為主是礦的顏色，否則是廢石的顏色
local function bits_tex(L)
	local k, kg = 0, 0
	for _, q in ipairs(L) do
		k = k + q.k
		if rockmech.ore_of_rubble[q.b] then kg = kg + q.k * q.g / 255 end
	end
	local ore = main_ore()
	local c = ore and (kg >= 0.5 * k and ore.pure or ore.waste_color) or "#6a6058"
	return "default_gravel.png^[colorize:" .. c .. ":160"
end
-- 頭端倒料：從輸送帶前緣以帶速拋出去、往下掉的料流
local function discharge_particles(p, d, h, out, tex)
	local v = cfg.conveyor_speed
	local edge = {x = p.x + d.x * 0.5, y = p.y + top_of(h) + 0.1, z = p.z + d.z * 0.5}
	local lat = {x = math.abs(d.z) * 0.3, y = 0, z = math.abs(d.x) * 0.3}
	core.add_particlespawner({amount = math.min(40, 6 + out * 2), time = 1 / v,
		pos = {min = vector.subtract(edge, lat), max = vector.add(vector.add(edge, lat), {x = 0, y = 0.12, z = 0})},
		vel = {min = {x = d.x * v * 0.7, y = -0.2, z = d.z * v * 0.7}, max = {x = d.x * v * 1.1, y = 0.4, z = d.z * v * 1.1}},
		acc = {x = 0, y = -9.81, z = 0},
		exptime = {min = 0.6, max = 1.2}, size = {min = 1.5, max = 3},
		collisiondetection = true, collision_removal = true, texture = tex})
	-- 落地揚起的灰
	core.add_particlespawner({amount = math.min(12, 2 + out), time = 1 / v,
		pos = {min = vector.subtract(edge, {x = 0.6, y = 1.5, z = 0.6}), max = vector.add(edge, {x = 0.6 + d.x, y = -0.5, z = 0.6 + d.z})},
		vel = {min = {x = -0.3, y = 0.2, z = -0.3}, max = {x = 0.3, y = 0.6, z = 0.3}},
		exptime = {min = 1, max = 2}, size = {min = 3, max = 6},
		texture = "default_gravel.png^[colorize:#8a8070:200^[opacity:110"})
end

-- 頭：往前倒出去（前方那格或再上一格是空的才倒；前面堆滿了輸送帶就停）
local function discharge(p, d)
	local L = loads[core.hash_node_position(p)]
	if not L then return end
	local tex = bits_tex(L)
	local f = {x = p.x + d.x, y = p.y, z = p.z + d.z}
	local fu = {x = f.x, y = f.y + 1, z = f.z}
	local nf, nu = core.get_node_or_nil(f), core.get_node_or_nil(fu)
	if not (nf and nu) then return end
	local ytop = V.passable(nu.name) and fu.y or V.passable(nf.name) and f.y
	if not ytop then return end
	local out = 0
	for i = #L, 1, -1 do
		local q = L[i]
		local rest = V.deposit_column(f.x, f.z, ytop, q.b, q.k, nil, nil, q.g)
		out = out + q.k - rest
		q.k = rest
		if rest <= 0 then table.remove(L, i) end
	end
	if #L == 0 then loads[core.hash_node_position(p)] = nil end
	if out > 0 then
		dirty = true
		rockmech.collapse.rubble_sound(f, out)
		if near_player(f) then discharge_particles(p, d, BELT_H[core.get_node(p).name] or 0, out, tex) end
	end
end

local function want_state(L)
	if not L then return "" end
	local k, kg = 0, 0
	for _, q in ipairs(L) do
		k = k + q.k
		if rockmech.ore_of_rubble[q.b] then kg = kg + q.k * q.g / 255 end
	end
	return kg >= 0.5 * k and "o" or "w"
end

-- 這一格的形狀：送料進來的格子在它的左邊、右邊還是後面（方塊座標：往 +z 走，左邊是 −x）
local function shape_of(h, n, from)
	if not from then return "" end
	local p, d = cells[h], dir_of(n)
	local left, right, back = false, false, false
	for _, hf in ipairs(from) do
		local f = cells[hf]
		local rx, rz = f.x - p.x, f.z - p.z
		local lx = rx * d.z - rz * d.x          -- 右邊為正
		if lx < 0 then left = true elseif lx > 0 then right = true else back = true end
	end
	if left and not right then return back and "ml" or "cl" end
	if right and not left then return back and "mr" or "cr" end
	return ""
end

local function tick()
	local nodes = {}
	local stop = rockmech.belt_stopped and rockmech.belt_stopped() or {}   -- 控制箱停住的格（beltswitch.lua）
	-- 1. 裝料：每格正上方那一格的碎石
	for h, p in pairs(cells) do
		local n, is = belt_at(p)
		if n and not is then
			cells[h] = nil          -- 已經不是輸送帶了（被別的東西蓋掉）
		elseif n then
			nodes[h] = n
			local C = stop[h] and 0 or cell_cap(h, p)      -- 停住的格不吸料
			local room = C - total(loads[h])
			if room > 0 then
				local up = {x = p.x, y = p.y + 1, z = p.z}
				local t, b, g = V.take_rubble(up, room)
				if t > 0 then add_load(h, b, t, g) end
			end
		end
	end
	-- 2. 往前走一格：從頭往回處理，每份料一次只走一格
	local done, feeds = {}, {}      -- feeds[格] = 往這一格送料的格子（決定轉彎、併入的形狀）
	for h0 in pairs(nodes) do
		if not done[h0] then
			local chain, seen = {}, {}
			local h, head_dir, wait = h0, nil, false
			while h and nodes[h] and not done[h] and not seen[h] do
				seen[h] = true
				chain[#chain + 1] = h
				if stop[h] then h = nil; break end      -- 停住的格：不往前送，上游送到這裡就塞住
				local q, d, w = next_of(cells[h], nodes[h])
				if q then
					local hq = core.hash_node_position(q)
					feeds[hq] = feeds[hq] or {}
					table.insert(feeds[hq], h)
					h = hq
				else
					h, head_dir, wait = nil, d, w
				end
			end
			-- chain 最後一格：是頭就倒出去；後面接的是已經走過的格（或迴圈）就只是往它移
			local last = chain[#chain]
			if head_dir and not wait then discharge(cells[last], head_dir)
			elseif h then move(last, h) end
			for i = #chain - 1, 1, -1 do move(chain[i], chain[i + 1]) end
			for _, hc in ipairs(chain) do done[hc] = true end
		end
	end
	-- 3. 外觀：有料的格子表面換成碎石，附近有人的話加上沿著輸送帶走的碎石顆粒
	local v, np = cfg.conveyor_speed, 0
	for h, n in pairs(nodes) do
		local st, sh = want_state(loads[h]), shape_of(h, n, feeds[h])
		local want = NAME[BELT_H[n.name]][st][sh][leg_of(cells[h])]
		if n.name ~= want then core.swap_node(cells[h], {name = want, param2 = n.param2}) end
		if st ~= "" and np < PARTICLE_MAX and near_player(cells[h]) then
			np = np + 1
			local p = cells[h]
			local q, d = next_of(p, n)
			local m = q and core.get_node(q)
			local rise = m and BELT_H[m.name] and (surf(q, m) - surf(p, n)) / 8 or 0   -- 往下一格的升降 (m)
			local y = p.y + top_of(BELT_H[n.name]) + 0.16
			local lat = {x = math.abs(d.z) * 0.25, y = 0, z = math.abs(d.x) * 0.25}
			local c = {x = p.x - d.x * 0.4, y = y, z = p.z - d.z * 0.4}
			core.add_particlespawner({amount = 3, time = 1 / v,
				pos = {min = vector.subtract(c, lat), max = vector.add(vector.add(c, lat), {x = d.x * 0.6, y = 0.05, z = d.z * 0.6})},
				vel = {min = {x = d.x * v, y = rise * v, z = d.z * v}, max = {x = d.x * v, y = rise * v, z = d.z * v}},
				exptime = 1 / v, size = {min = 1, max = 2}, texture = bits_tex(loads[h])})
		end
	end
end

local acc, save_t = 0, 0
core.register_globalstep(function(dtime)
	acc, save_t = acc + dtime, save_t + dtime
	local dt = 1 / cfg.conveyor_speed
	if acc >= dt then
		acc = acc >= 2 * dt and 0 or acc - dt
		tick()
	end
	if save_t >= SAVE_EVERY then
		save_t = 0
		if dirty then storage:set_string("belt_loads", core.serialize(loads)); dirty = false end
	end
end)
core.register_on_shutdown(function() storage:set_string("belt_loads", core.serialize(loads)) end)

---------------------------------------------------------------------------
-- 給選礦場的放料臂（plant.lua）
---------------------------------------------------------------------------

-- 離 pivot 水平 r 以內、表面在 pivot 下方、還有空位的輸送帶格（最近的那格）：回傳 位置, 表面的 y
function rockmech.belt_near(pivot, r)
	local best, bd = nil, nil
	for h, p in pairs(cells) do
		local d2 = (p.x - pivot.x) ^ 2 + (p.z - pivot.z) ^ 2
		if d2 <= r * r and p.y < pivot.y and (not bd or d2 < bd) and total(loads[h]) < cell_cap(h, p) then
			local n, is = belt_at(p)
			if is then best, bd = p, d2 end
		end
	end
	if not best then return nil end
	return best, best.y + top_of(BELT_H[core.get_node(best).name])
end
-- 放 k 級到這格輸送帶上，回傳實際放了幾級
function rockmech.belt_put(p, b, k, g)
	local h = core.hash_node_position(p)
	local put = math.min(k, cell_cap(h, p) - total(loads[h]))
	if put > 0 then add_load(h, b, put, g) end
	return math.max(0, put)
end
rockmech.belt_state = function() return cells, loads end     -- 測試用

---------------------------------------------------------------------------
-- 物品：左鍵切換坡度，右鍵放
---------------------------------------------------------------------------

local function slopes()
	local R, list = rmax(), {0}
	for r = 1, R do list[#list + 1] = r end
	for r = 1, R do list[#list + 1] = -r end
	return list
end
local function slope_text(r)
	if r == 0 then return S("flat") end
	local a = ("%.0f"):format(math.deg(math.atan(math.abs(r) / 8)))
	return r > 0 and S("uphill @1°", a) or S("downhill @1°", a)
end
local function describe(stack, r)
	stack:get_meta():set_string("description", S("Conveyor belt (@1)\nRight-click to place: click a belt to extend from that block, click the ground to start from the ground\nLeft-click a belt to pick up that block; left-click elsewhere to change the slope", slope_text(r)))
end

core.register_craftitem(ITEM, {
	description = S("Conveyor belt\nRight-click to lay; left-click a belt to take it back"),
	short_description = S("Conveyor belt"),
	inventory_image = "rockmech_icon_belt.png",      -- devtools/make_icons.py
	stack_max = 99,
	on_use = function(itemstack, user, pointed)
		if not user then return end
		-- 左鍵點在輸送帶上：收回這一格（上面的料倒在原地）
		if pointed and pointed.type == "node" and BELT_H[core.get_node(pointed.under).name] then
			local p, name = pointed.under, user:get_player_name()
			if core.is_protected(p, name) then core.record_protection_violation(p, name); return end
			core.remove_node(p)
			local left = itemstack:add_item(ItemStack(ITEM))
			if not left:is_empty() then
				left = user:get_inventory():add_item("main", left)
				if not left:is_empty() then core.add_item(p, left) end
			end
			return itemstack
		end
		local list = slopes()
		local cur = itemstack:get_meta():get_int("slope")
		local i = 1
		for j, r in ipairs(list) do if r == cur then i = j end end
		local r = list[i % #list + 1]
		itemstack:get_meta():set_int("slope", r)
		describe(itemstack, r)
		rockmech.notify(user:get_player_name(), S("[Conveyor] Slope: @1 (maximum inclination @2°)", slope_text(r), ("%g"):format(cfg.conveyor_max_angle)))
		return itemstack
	end,
	on_place = function(itemstack, placer, pointed)
		if pointed.type ~= "node" or not placer then return itemstack end
		local un = core.get_node(pointed.under)
		local udef = core.registered_nodes[un.name]
		if udef and udef.on_rightclick and not BELT_H[un.name] and not placer:get_player_control().sneak then
			return udef.on_rightclick(pointed.under, un, placer, itemstack, pointed) or itemstack
		end
		local name = placer:get_player_name()
		local function say(s) rockmech.notify(name, S("[Conveyor]") .. " " .. s) end
		local look = placer:get_look_dir()
		local fd = core.dir_to_fourdir({x = look.x, y = 0, z = look.z})
		local d = core.fourdir_to_dir(fd)
		local slope = math.max(-rmax(), math.min(rmax(), itemstack:get_meta():get_int("slope")))
		-- via：新的這格的進料來源（從尾巴往下游接時的那格）
		local function put(p, sf, pd, via)
			local q = {x = p.x, y = math.floor(sf / 8), z = p.z}
			local h = sf - q.y * 8
			-- 一進一出：送進這格的最多一條；前面接到的那條原本不能已經有進料
			local ins, n_in = {}, 0
			if via then ins[core.hash_node_position(via)] = true; n_in = 1 end
			for _, s in ipairs({{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) do
				for dy = -1, 1 do
					local r = {x = q.x + s[1], y = q.y + dy, z = q.z + s[2]}
					local m, is = belt_at(r)
					if is then
						local md = dir_of(m)
						local hr = core.hash_node_position(r)
						if r.x + md.x == q.x and r.z + md.z == q.z and not (md.x == -pd.x and md.z == -pd.z) and not ins[hr] then
							ins[hr] = true; n_in = n_in + 1
						end
					end
				end
			end
			local blocked = n_in > 1
			for dy = -1, 1 do
				local t = {x = q.x + pd.x, y = q.y + dy, z = q.z + pd.z}
				local m, is = belt_at(t)
				if is then
					local md = dir_of(m)
					if not (md.x == -pd.x and md.z == -pd.z) and prev_of(t, m) then blocked = true end
				end
			end
			if blocked then
				say(S("A conveyor belt can only have one way in and one way out"))
				return false
			end
			local nd = core.registered_nodes[core.get_node(q).name]
			if not (nd and nd.buildable_to) then
				say(S("The next block @1 is occupied; dig it out first", core.pos_to_string(q)))
				return false
			end
			if core.is_protected(q, name) then core.record_protection_violation(q, name); return false end
			core.set_node(q, {name = NAME[h][""][""][leg_of(q)], param2 = core.dir_to_fourdir(pd)})
			if rockmech.account_of then core.get_meta(q):set_string("owner", rockmech.account_of(name)) end   -- 研究加成照這一組
			if not core.is_creative_enabled(name) then itemstack:take_item() end
			return true
		end
		-- 點在輸送帶上：從這條的兩頭都可以接，往看的方向放下一格
		--   尾巴（後面沒有接下去）或照原方向直走：往下游接（尾巴可以轉彎；轉彎那格是平的）
		--   頭（前面沒有東西送進來）：往上游接，新的那格把料送進這格（從料斗接出來的線，可以從料斗旁邊往回鋪）
		-- 點在輸送帶上：跟一般方塊一樣放在點的那一面旁邊；點上面、下面才往看的方向延伸。
		-- 方向照新的那格在原本那格的哪一邊：前方 → 接在下游；後方 → 接在上游；側邊 → 尾巴還沒接下去就轉彎往這邊接，
		-- 不然頭還沒有進料就從側邊送進去；都不行 → 一進一出
		if BELT_H[un.name] then
			local c, cn = pointed.under, un
			local d0 = dir_of(cn)
			local s = d
			if pointed.above.y == c.y then s = {x = pointed.above.x - c.x, y = 0, z = pointed.above.z - c.z} end
			local n = {x = c.x + s.x, z = c.z + s.z}
			local down, up = next_of(c, cn), prev_of(c, cn)
			local ahead = d0.x == s.x and d0.z == s.z
			local behind = d0.x == -s.x and d0.z == -s.z
			local back_s = {x = -s.x, y = 0, z = -s.z}
			if ahead and not down then
				put(n, surf(c, cn) + slope, s, c)
			elseif behind and not up then
				put(n, surf(c, cn) - slope, back_s)
			elseif not ahead and not behind and not down then
				if put(n, surf(c, cn), s, c) then
					core.swap_node(c, {name = cn.name, param2 = core.dir_to_fourdir(s)})      -- 尾巴轉彎（轉彎那格是平的）
				end
			elseif not ahead and not behind and not up then
				put(n, surf(c, cn), back_s)
			else
				say(S("A conveyor belt can only have one way in and one way out"))
			end
			return itemstack
		end
		-- 從哪一格接過來：前方正好指向這一欄的輸送帶
		local fpos, fnode
		do
			local a = pointed.above
			for _, s in ipairs({{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) do
				for dy = -1, 1 do
					local q = {x = a.x + s[1], y = a.y + dy, z = a.z + s[2]}
					local m = core.get_node(q)
					if BELT_H[m.name] then
						local md = dir_of(m)
						if q.x + md.x == a.x and q.z + md.z == a.z and not fpos then fpos, fnode = q, m end
					end
				end
			end
		end
		-- 點在地上：從地面開始一格，朝看的方向（前方有輸送帶正好指向這一欄就接著它的高度）
		local sf = pointed.above.y * 8
		if fpos then
			local d0 = dir_of(fnode)
			if d0.x == -d.x and d0.z == -d.z then say(S("Cannot extend backwards")); return itemstack end
			sf = surf(fpos, fnode) + ((d0.x == d.x and d0.z == d.z) and slope or 0)    -- 轉彎那格是平的
		end
		put(pointed.above, sf, d)
		return itemstack
	end,
})
