-- rockmech/groundwater.lua
-- 地下水：世界設定 rockmech_water_table_depth（天然地表下幾 m；slurry.lua 的 rockmech.water_table_y 算水位高程）。
--   冒水：水位以下的空格、碎石（騰得出空間的），每貼著一面水位以下的土（表土、底土），每 SOIL_IN 秒冒 1 級水。
--   地下水當成無限的水源（含水層補進來）；冒出來以後照 slurry.lua 守恆地流、積水、滲。
--   坑裡積水漲過水位就停（那幾格在水位以上）；水被抽走、流走騰出空間（slurry.lua 呼叫 rockmech.groundwater_poke）再冒。
--   事件驅動：只有騰出空間、還在冒的格在算。岩石先不冒（之後照節理）。
-- 排水溝：液體流到旁邊、上面就沒了（每步 DRAIN 級）。給深開挖的地圖把抽出來的水排掉。
-- 抽水機：放在坑邊，吸管朝前伸進坑裡（跟出液口一樣朝放的人那一側）；每秒從前面那一欄的液面抽 PUMP_RATE 級，
--   倒在機器後面那一格（守恆）；後面那一格是排水溝就直接排掉。

local S = rockmech.S
local setting = rockmech.get_setting or function(k) return core.settings:get(k) end
local NL = rockmech.RUBBLE_LEVELS
local WATER = rockmech.LIQUID_WATER

local SOIL_IN = tonumber(setting("rockmech_groundwater_soil_step") or "") or 10   -- 秒／級（每一面）
local IN_DT = 5                                                                   -- 冒水的判定間隔（秒）
local PUMP_RATE = tonumber(setting("rockmech_pump_rate") or "") or 1             -- 級／秒
local HOSE = 30                                                                   -- 吸管長（m）
local DRAIN = 8                                                                   -- 排水溝每步吃掉幾級

-- 冒水 -------------------------------------------------------------------
local storage = core.get_mod_storage()
local pending = {}                    -- 位置 hash → true（排了判定）
local acc = {}                        -- 位置 hash → 累積的小數級
local soil_frac = rockmech.soil_frac
local DIRS6 = {{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}}
local step
local function schedule(p, dt)
	local h = core.hash_node_position(p)
	if pending[h] then return end
	pending[h] = true
	core.after(dt or IN_DT, function() pending[h] = nil; step(p) end)
end
-- p 這一格旁邊有幾面水位以下的土
local function sources(p)
	local n = 0
	for _, d in ipairs(DIRS6) do
		local q = {x = p.x + d[1], y = p.y + d[2], z = p.z + d[3]}
		if soil_frac[core.get_node(q).name] then
			local wt = rockmech.water_table_y(q.x, q.z)
			if wt and q.y <= wt and p.y <= wt then n = n + 1 end
		end
	end
	return n
end
step = function(p)
	local r, w = rockmech.slurry_cell(p)
	if not r then return end
	local cap = rockmech.liquid_cap(r)
	if w >= cap then return end
	local n = sources(p)
	if n == 0 then return end
	local h = core.hash_node_position(p)
	local a = (acc[h] or 0) + n * IN_DT / SOIL_IN
	local add = math.floor(a)
	acc[h] = a - add
	if add > 0 then
		local left = rockmech.slurry_add_at(p, math.min(add, cap - w), WATER)
		if left < add then rockmech.slurry_schedule(p); rockmech.slurry_wake(p) end
	end
	schedule(p)
end
-- 一格騰出空間（slurry.lua 呼叫）：在水位以下就排冒水判定
function rockmech.groundwater_poke(p)
	local wt = rockmech.water_table_y(p.x, p.z)
	if not wt or p.y > wt + 1 then return end
	schedule(vector.copy(p))
end
-- 還在冒的格：關遊戲時記下來，下次開接著冒
if rockmech.GROUNDWATER_DEPTH then
	local saved = core.deserialize(storage:get_string("gw_pending")) or {}
	core.after(2, function() for h in pairs(saved) do schedule(core.get_position_from_hash(h), 1) end end)
	core.register_on_shutdown(function() storage:set_string("gw_pending", core.serialize(pending)) end)
end

-- 排水溝 -------------------------------------------------------------------
local DRAIN_NODE = "rockmech:drain"
core.register_node(DRAIN_NODE, {
	description = S("Drain\nWater that flows into it or onto it is carried away"),
	short_description = S("Drain"),
	drawtype = "nodebox",
	node_box = {type = "fixed", fixed = {
		{-0.5, -0.5, -0.5, 0.5, -0.375, 0.5},          -- 底
		{-0.5, -0.375, -0.5, -0.375, -0.0625, 0.5},    -- 兩側
		{0.375, -0.375, -0.5, 0.5, -0.0625, 0.5},
	}},
	selection_box = {type = "fixed", fixed = {-0.5, -0.5, -0.5, 0.5, -0.0625, 0.5}},
	tiles = {"[fill:16x16:#9a9a94^[fill:12x16:2,0:#5a6470", "[fill:16x16:#8a8a84", "[fill:16x16:#a2a29c"},
	paramtype = "light",
	paramtype2 = "facedir",
	is_ground_content = false,
	groups = {cracky = 2},
	on_construct = function(pos)
		rockmech.slurry_wake(pos)
		rockmech.slurry_schedule({x = pos.x, y = pos.y + 1, z = pos.z})
	end,
})
rockmech.liquid_drains[DRAIN_NODE] = DRAIN
rockmech.DRAIN = DRAIN_NODE

-- 抽水機 -------------------------------------------------------------------
local PUMP = "rockmech:water_pump"
local function pump_dirs(node)
	local f = core.facedir_to_dir(node.param2)       -- 吸管伸出去的方向
	return f, {x = -f.x, y = 0, z = -f.z}
end
local function pump_info(pos, txt)
	core.get_meta(pos):set_string("infotext", S("Water pump") .. "\n" .. txt)
end
local function may(pos, name)
	local owner = core.get_meta(pos):get_string("owner")
	return rockmech.owner_ok and rockmech.owner_ok(owner, name) or owner == "" or owner == name
end
local level_of = rockmech.slurry_level
local function pump_tick(pos)
	local node = core.get_node(pos)
	local f, b = pump_dirs(node)
	local col = vector.add(pos, f)
	-- 吸管：往下穿過空氣、液體，找第一格有液的（最多 HOSE m）
	local q, intake = vector.copy(col), nil
	for _ = 0, HOSE do
		local n = core.get_node(q).name
		local k = n == "air" and 0 or level_of[n]
		if not k then break end
		if k > 0 then intake = q; break end
		q.y = q.y - 1
	end
	if not intake then pump_info(pos, S("No water in reach")); return end
	local c = rockmech.liquid_comp(intake)
	local took = rockmech.slurry_take(intake, PUMP_RATE)
	if took <= 0 then pump_info(pos, S("No water in reach")); return end
	local out = vector.add(pos, b)
	if rockmech.liquid_drains[core.get_node(out).name] then       -- 後面接著排水溝：直接排掉
		pump_info(pos, S("Pumping @1 m³/h", math.floor(took / NL * 3600 + 0.5)))
		return
	end
	local left = rockmech.slurry_add_up(out, took, nil, c)
	if left > 0 then                                -- 出水的地方擋住了：放回去
		rockmech.slurry_add_up(intake, left, nil, c)
		pump_info(pos, S("Outlet blocked"))
	else
		pump_info(pos, S("Pumping @1 m³/h", math.floor(took / NL * 3600 + 0.5)))
	end
	rockmech.slurry_schedule(out); rockmech.slurry_wake(out)
end
core.register_node(PUMP, {
	description = S("Water pump\nThe suction hose points back at you: stand at the pit edge and place it on the far side. Pumps water from the pit and pours it out behind the pump; lead it into a drain"),
	short_description = S("Water pump"),
	drawtype = "nodebox",
	node_box = {type = "fixed", fixed = {
		{-0.35, -0.5, -0.3, 0.35, 0.1, 0.3},           -- 機身
		{-0.06, -0.1, 0.3, 0.06, 0.02, 1.06},          -- 吸管（往前）
		{-0.06, -0.5, 0.94, 0.06, 0.02, 1.06},         -- 往下垂
		{-0.08, -0.45, -0.5, 0.08, -0.29, -0.3},       -- 出水口（往後）
	}},
	selection_box = {type = "fixed", fixed = {-0.35, -0.5, -0.3, 0.35, 0.1, 0.3}},
	collision_box = {type = "fixed", fixed = {-0.35, -0.5, -0.3, 0.35, 0.1, 0.3}},
	tiles = {"[fill:16x16:#3f73a8^[fill:10x10:3,3:#2a4e78", "[fill:16x16:#3a3f44", "[fill:16x16:#4a80b8^[fill:16x2:0,7:#2a4e78"},
	paramtype = "light",
	paramtype2 = "facedir",
	is_ground_content = false,
	groups = {cracky = 2},
	on_construct = function(pos) core.get_node_timer(pos):start(1) end,
	after_place_node = function(pos, placer)
		if placer and placer.get_look_dir then
			local d = placer:get_look_dir()
			core.swap_node(pos, {name = PUMP, param2 = core.dir_to_facedir({x = -d.x, y = 0, z = -d.z})})
		end
		core.get_meta(pos):set_string("owner", placer and rockmech.account_of and rockmech.account_of(placer:get_player_name())
			or (placer and placer:get_player_name()) or "")
		pump_info(pos, S("No water in reach"))
	end,
	on_timer = function(pos) pump_tick(pos); return true end,
	can_dig = function(pos, player) return player and may(pos, player:get_player_name()) end,
})
core.register_lbm({
	label = "rockmech: 抽水機計時器", name = "rockmech:water_pump_timer", nodenames = {PUMP}, run_at_every_load = true,
	action = function(pos)
		local t = core.get_node_timer(pos)
		if not t:is_started() then t:start(1) end
	end,
})
rockmech.WATER_PUMP = PUMP
