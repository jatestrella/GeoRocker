-- rockmech/conveyor.lua
-- 皮帶輸送機：一格一格的方塊，每格 1 m，朝放的人面對的方向輸送；換個方向接就是轉彎。
-- 裝料：碎石落在任何一格皮帶上（卡車倒的、怪手放的、旁邊料堆流下來的、選礦場放料臂放的）就被帶走。
-- 每格最多載「運量 ÷ 帶速」的料（rockmech_conveyor_rate t/s ÷ rockmech_conveyor_speed m/s），每 1/帶速 秒往前走一格；
-- 前面那格滿了就停著等，下游塞住整條會跟著停。最後一格往前倒出去，變回地上的碎石（品位跟著料走）：
-- 底下是破碎站、選礦場的受料倉或另一條皮帶，就接著處理。
-- 坡度：皮帶表面的高度以 1/8 m 為單位（皮帶方塊有 8 種高度），每格最多升降 r/8 m，
-- r = floor(8·tan(最大傾角))，最大傾角 rockmech_conveyor_max_angle：碎石在皮帶上不往回滑的上限
-- （料和皮帶之間的摩擦，實務上約 15–18°）。轉彎的那一格是平的。
-- 拿著皮帶右鍵放：點在皮帶上就從那一格往前接，點在地上就從地面開始；左鍵點皮帶收回那一格，點別的地方切換坡度。
-- 有皮帶的區塊一直載入（每格放的時候強制載入它的區塊，拆掉時放掉）。

local cfg = rockmech.cfg
local V = rockmech.vehicles
local H = rockmech.hopper_lib
local storage = rockmech.collapse.storage

local ITEM = "rockmech:belt"
local BELT_H, BELT_ST, NAME = {}, {}, {}    -- node 名稱 → 表面高度 h（0..7，表面在 (h+1)/8 m）、外觀狀態（"" 空、"w" 載廢石、"o" 載礦）
local SAVE_EVERY = 10       -- 皮帶上的料多久存檔一次 (s)

local function main_ore()
	for _, ore in pairs(cfg.ores) do return ore end
end
-- 每格最多升降幾個 1/8 m
local function rmax() return math.max(0, math.floor(8 * math.tan(math.rad(cfg.conveyor_max_angle)) + 1e-6)) end
-- 每格最多載幾級（1 級 = 1/8 m³）
local function cell_cap() return math.max(1, math.floor(cfg.conveyor_rate / cfg.conveyor_speed / H.tons_of(1))) end

---------------------------------------------------------------------------
-- 方塊
---------------------------------------------------------------------------

local FRAME = "[fill:16x16:#6c6c6c^[fill:16x2:0,0:#4a4a4a"
local RUBBER = "[fill:16x16:#262626^[fill:16x2:0,7:#363636"
local function top_of(h) return (h + 1) / 8 - 0.5 end
local function boxes(h, loaded)
	local top, b = top_of(h), {}
	local function add(x0, y0, z0, x1, y1, z1)
		y0 = math.max(-0.5, y0)
		if y1 > y0 then b[#b + 1] = {x0, y0, z0, x1, y1, z1} end
	end
	add(-0.42, top - 0.1, -0.5, 0.42, top, 0.5)            -- 皮帶
	add(-0.5, top - 0.25, -0.5, -0.42, top + 0.12, 0.5)    -- 兩側框架
	add(0.42, top - 0.25, -0.5, 0.5, top + 0.12, 0.5)
	if top - 0.25 > -0.5 then                               -- 支腳
		add(-0.48, -0.5, -0.06, -0.4, top - 0.25, 0.06)
		add(0.4, -0.5, -0.06, 0.48, top - 0.25, 0.06)
	end
	if loaded then add(-0.32, top, -0.5, 0.32, top + 0.14, 0.5) end   -- 皮帶上的料
	return b
end

local cells = {}            -- 位置 hash → 位置（目前知道的皮帶格）
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

for h = 0, 7 do
	NAME[h] = {}
	for _, st in ipairs({"", "w", "o"}) do
		local name = "rockmech:belt_" .. h .. (st ~= "" and ("_" .. st) or "")
		NAME[h][st], BELT_H[name], BELT_ST[name] = name, h, st
		local ore = main_ore()
		local top = st == "" and RUBBER or V.rubble_tex(st == "o" and ore and ore.rubble or rockmech.RUBBLE)
		local sel = {-0.5, -0.5, -0.5, 0.5, top_of(h) + 0.12, 0.5}
		core.register_node(name, {
			description = "皮帶輸送機",
			drawtype = "nodebox",
			paramtype = "light",
			paramtype2 = "4dir",
			sunlight_propagates = true,
			node_box = {type = "fixed", fixed = boxes(h, st ~= "")},
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

-- 載入的區塊裡的皮帶記到 cells（重開遊戲後，強制載入的區塊一開始就會載入）
core.register_lbm({
	label = "rockmech: 皮帶登記",
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

-- 下一格皮帶：前方那一欄、表面高度差不超過 rmax、不是迎面對著的。
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

-- 把 a 格的料往 b 格移，最多移到 b 滿
local function move(ha, hb, C)
	local A = loads[ha]
	if not A then return end
	local room = C - total(loads[hb])
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

-- 粒子：皮帶上滾動的碎石顆粒、頭端倒出去的料流。只給附近（PARTICLE_R m 內）有玩家的格子，一步最多 PARTICLE_MAX 格
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
-- 頭端倒料：從皮帶前緣以帶速拋出去、往下掉的料流
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

-- 頭：往前倒出去（前方那格或再上一格是空的才倒；前面堆滿了皮帶就停）
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

local function tick()
	local C = cell_cap()
	local nodes = {}
	-- 1. 裝料：每格正上方那一格的碎石
	for h, p in pairs(cells) do
		local n, is = belt_at(p)
		if n and not is then
			cells[h] = nil          -- 已經不是皮帶了（被別的東西蓋掉）
		elseif n then
			nodes[h] = n
			local room = C - total(loads[h])
			if room > 0 then
				local up = {x = p.x, y = p.y + 1, z = p.z}
				local t, b, g = V.take_rubble(up, room)
				if t > 0 then add_load(h, b, t, g) end
			end
		end
	end
	-- 2. 往前走一格：從頭往回處理，每份料一次只走一格
	local done = {}
	for h0 in pairs(nodes) do
		if not done[h0] then
			local chain, seen = {}, {}
			local h, head_dir, wait = h0, nil, false
			while h and nodes[h] and not done[h] and not seen[h] do
				seen[h] = true
				chain[#chain + 1] = h
				local q, d, w = next_of(cells[h], nodes[h])
				if q then
					h = core.hash_node_position(q)
				else
					h, head_dir, wait = nil, d, w
				end
			end
			-- chain 最後一格：是頭就倒出去；後面接的是已經走過的格（或迴圈）就只是往它移
			local last = chain[#chain]
			if head_dir and not wait then discharge(cells[last], head_dir)
			elseif h then move(last, h, C) end
			for i = #chain - 1, 1, -1 do move(chain[i], chain[i + 1], C) end
			for _, hc in ipairs(chain) do done[hc] = true end
		end
	end
	-- 3. 外觀：有料的格子表面換成碎石，附近有人的話加上沿著皮帶走的碎石顆粒
	local v, np = cfg.conveyor_speed, 0
	for h, n in pairs(nodes) do
		local st = want_state(loads[h])
		if BELT_ST[n.name] ~= st then core.swap_node(cells[h], {name = NAME[BELT_H[n.name]][st], param2 = n.param2}) end
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

-- 離 pivot 水平 r 以內、表面在 pivot 下方、還有空位的皮帶格（最近的那格）：回傳 位置, 表面的 y
function rockmech.belt_near(pivot, r)
	local C, best, bd = cell_cap(), nil, nil
	for h, p in pairs(cells) do
		local d2 = (p.x - pivot.x) ^ 2 + (p.z - pivot.z) ^ 2
		if d2 <= r * r and p.y < pivot.y and (not bd or d2 < bd) and total(loads[h]) < C then
			local n, is = belt_at(p)
			if is then best, bd = p, d2 end
		end
	end
	if not best then return nil end
	return best, best.y + top_of(BELT_H[core.get_node(best).name])
end
-- 放 k 級到這格皮帶上，回傳實際放了幾級
function rockmech.belt_put(p, b, k, g)
	local h = core.hash_node_position(p)
	local put = math.min(k, cell_cap() - total(loads[h]))
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
	if r == 0 then return "平" end
	return ("%s坡 %.0f°"):format(r > 0 and "上" or "下", math.deg(math.atan(math.abs(r) / 8)))
end
local function describe(stack, r)
	stack:get_meta():set_string("description", ("皮帶輸送機（%s）\n右鍵放：點皮帶從那格往前接，點地面從地上開始\n左鍵點皮帶收回那一格，點別的地方切換坡度"):format(slope_text(r)))
end

core.register_craftitem(ITEM, {
	description = "皮帶輸送機\n右鍵放：點皮帶從那格往前接，點地面從地上開始\n左鍵點皮帶收回那一格，點別的地方切換坡度",
	inventory_image = "[fill:16x16:#00000000^[fill:16x6:0,5:#6c6c6c^[fill:14x3:1,6:#262626^[fill:2x5:2,11:#4a4a4a^[fill:2x5:12,11:#4a4a4a",
	stack_max = 99,
	on_use = function(itemstack, user, pointed)
		if not user then return end
		-- 左鍵點在皮帶上：收回這一格（上面的料倒在原地）
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
		core.chat_send_player(user:get_player_name(), ("[皮帶] 坡度：%s（最大傾角 %g°）"):format(slope_text(r), cfg.conveyor_max_angle))
		return itemstack
	end,
	on_place = function(itemstack, placer, pointed)
		if pointed.type ~= "node" or not placer then return itemstack end
		local un = core.get_node(pointed.under)
		local udef = core.registered_nodes[un.name]
		if udef and udef.on_rightclick and not placer:get_player_control().sneak then
			return udef.on_rightclick(pointed.under, un, placer, itemstack, pointed) or itemstack
		end
		local name = placer:get_player_name()
		local function say(s) core.chat_send_player(name, "[皮帶] " .. s) end
		local look = placer:get_look_dir()
		local fd = core.dir_to_fourdir({x = look.x, y = 0, z = look.z})
		local d = core.fourdir_to_dir(fd)
		-- 從哪一格接過來：點到的皮帶，或前方正好指向這一欄的皮帶
		local fpos, fnode
		if BELT_H[un.name] then
			fpos, fnode = pointed.under, un
		else
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
		local tx, tz, S
		if fpos then
			local d0 = dir_of(fnode)
			if d0.x == -d.x and d0.z == -d.z then say("不能往回接"); return itemstack end
			local r = (d0.x == d.x and d0.z == d.z) and itemstack:get_meta():get_int("slope") or 0   -- 轉彎那格是平的
			r = math.max(-rmax(), math.min(rmax(), r))
			tx, tz, S = fpos.x + d0.x, fpos.z + d0.z, surf(fpos, fnode) + r
		else
			tx, tz, S = pointed.above.x, pointed.above.z, pointed.above.y * 8
		end
		local p = {x = tx, y = math.floor(S / 8), z = tz}
		local h = S - p.y * 8
		local nd = core.registered_nodes[core.get_node(p).name]
		if not (nd and nd.buildable_to) then
			say(("下一格 %s 有東西，要先挖開"):format(core.pos_to_string(p)))
			return itemstack
		end
		if core.is_protected(p, name) then core.record_protection_violation(p, name); return itemstack end
		core.set_node(p, {name = NAME[h][""], param2 = fd})
		if not core.is_creative_enabled(name) then itemstack:take_item() end
		return itemstack
	end,
})
