-- rockmech/crusher.lua
-- 破碎站（賣礦）：放在平地上，朝玩家的方向鋪一片受料格柵。碎石落在格柵上就被吃進去，卡車、挖土機、推土機、
-- 碎石自己流過來都一樣；每秒最多 rockmech_crusher_rate 噸，倒太快就在格柵上排隊。
-- 過磅入帳：收入 = 噸數 ×（品位 × 回收率 × 價格 − 處理費），見 config.crush_income。廢石的品位是 0，
-- 運來破碎只會賠處理費，這就是貧化與截止品位。錢記在放置破碎站的玩家身上。

local cfg = rockmech.cfg
local V = rockmech.vehicles
local storage = rockmech.collapse.storage

local CRUSHER, GRATE = "rockmech:crusher", "rockmech:crusher_grate"
local SIZE = 7              -- 格柵 SIZE × SIZE m
local PILE = 8              -- 格柵上往上找幾格碎石
local STEP = 1              -- 每幾秒吃一次
local MONEY = "money:"      -- mod storage 的鍵

---------------------------------------------------------------------------
-- 資金
---------------------------------------------------------------------------

local money_hud = {}        -- 玩家名稱 → HUD id

local function show_money(player)
	local name = player:get_player_name()
	local text = ("資金 $%.0f"):format(storage:get_float(MONEY .. name))
	if money_hud[name] then
		player:hud_change(money_hud[name], "text", text)
	else
		money_hud[name] = player:hud_add({type = "text", position = {x = 0.99, y = 0.03}, alignment = {x = -1, y = 1},
			number = 0xFFE080, text = text, z_index = 100})
	end
end

function rockmech.add_money(name, amount)
	storage:set_float(MONEY .. name, storage:get_float(MONEY .. name) + amount)
	local player = core.get_player_by_name(name)
	if player then show_money(player) end
end

core.register_on_joinplayer(function(player)
	if storage:contains(MONEY .. player:get_player_name()) then show_money(player) end
end)
core.register_on_leaveplayer(function(player) money_hud[player:get_player_name()] = nil end)

---------------------------------------------------------------------------
-- 破碎
---------------------------------------------------------------------------

local function grate_cells(meta)
	local x0, y, z0 = meta:get_int("gx"), meta:get_int("gy"), meta:get_int("gz")
	local cells = {}
	for x = x0, x0 + SIZE - 1 do for z = z0, z0 + SIZE - 1 do
		cells[#cells + 1] = {x = x, y = y, z = z}
	end end
	return cells
end

-- 格柵這一格上方最高的碎石
local function top_rubble(c)
	if core.get_node(c).name ~= GRATE then return nil end
	for y = c.y + PILE, c.y + 1, -1 do
		local p = {x = c.x, y = y, z = c.z}
		if rockmech.rubble_level[core.get_node(p).name] then return p end
	end
end

-- 每級碎石的噸數：1/8 m³，密度用 γ/10
local function tons_of(levels) return levels / V.NLEV * cfg.failure.gamma_other / 10 end

local function crush(pos, dtime)
	local meta = core.get_meta(pos)
	local budget = meta:get_float("carry") + cfg.crusher_rate * dtime / tons_of(1)
	local want = math.floor(budget)
	local eaten, income, ore_t = 0, 0, 0
	local cells = grate_cells(meta)
	local start = meta:get_int("next")
	for i = 1, #cells do
		if want <= 0 then break end
		local p = top_rubble(cells[(start + i - 1) % #cells + 1])
		if p then
			local t, base, p2 = V.take_rubble(p, want)
			local ore = rockmech.ore_of_rubble[base]
			local grade = ore and p2 / 255 or 0
			want = want - t
			eaten = eaten + t
			income = income + rockmech.config.crush_income(tons_of(t), grade, ore, cfg.crusher_fee)
			ore_t = ore_t + tons_of(t) * grade
			meta:set_int("next", (start + i) % #cells)
		end
	end
	local owner = meta:get_string("owner")
	if eaten == 0 then
		-- 吃完了：回報這一批
		meta:set_float("carry", 0)
		local bt = meta:get_float("batch_t")
		if bt > 0 then
			core.chat_send_player(owner, ("[破碎站] 這批 %.1f t，品位 %.0f%%，收入 $%.0f"):format(bt,
				100 * meta:get_float("batch_q") / bt, meta:get_float("batch_m")))
			meta:set_float("batch_t", 0)
			meta:set_float("batch_q", 0)
			meta:set_float("batch_m", 0)
		end
		return
	end
	meta:set_float("carry", budget - math.floor(budget))
	local t = tons_of(eaten)
	rockmech.add_money(owner, income)
	rockmech.collapse.rubble_sound(pos, eaten)
	for key, v in pairs({batch_t = t, batch_q = ore_t, batch_m = income, total_t = t, total_q = ore_t, total_m = income}) do
		meta:set_float(key, meta:get_float(key) + v)
	end
end

local function formspec(pos)
	local meta = core.get_meta(pos)
	local queue = 0
	for _, c in ipairs(grate_cells(meta)) do
		if core.get_node(c).name == GRATE then
			for y = c.y + 1, c.y + PILE do
				queue = queue + (rockmech.rubble_level[core.get_node({x = c.x, y = y, z = c.z}).name] or 0)
			end
		end
	end
	local total = meta:get_float("total_t")
	local prices = {}
	for _, ore in pairs(cfg.ores) do
		prices[#prices + 1] = ("%s 品位 100%% 每噸 $%g，回收率 %.0f%%"):format(ore.label, ore.price, ore.recovery * 100)
	end
	return table.concat({
		"formspec_version[6]size[9,6]",
		"label[0.5,0.6;破碎站]",
		("label[0.5,1.2;處理能力：%g t/s　處理費：每噸 $%g]"):format(cfg.crusher_rate, cfg.crusher_fee),
		("label[0.5,1.8;%s]"):format(core.formspec_escape(table.concat(prices, "；"))),
		("label[0.5,2.4;格柵上排隊：%.1f t]"):format(tons_of(queue)),
		("label[0.5,3.0;累計處理：%.1f t，平均品位 %.0f%%]"):format(total, total > 0 and 100 * meta:get_float("total_q") / total or 0),
		("label[0.5,3.6;累計收入：$%.0f]"):format(meta:get_float("total_m")),
		("label[0.5,4.2;資金（%s）：$%.0f]"):format(core.formspec_escape(meta:get_string("owner")),
			storage:get_float(MONEY .. meta:get_string("owner"))),
		"button_exit[3,4.8;3,0.8;ok;關閉]",
	})
end

---------------------------------------------------------------------------
-- 方塊
---------------------------------------------------------------------------

local BODY = "[fill:16x16:#b08a20^[fill:16x2:0,0:#303030^[fill:16x2:0,14:#303030"

core.register_node(GRATE, {
	description = "Crusher grate (破碎站受料格柵)",
	tiles = {"[fill:16x16:#181818^[fill:16x3:0,1:#8a8a8a^[fill:16x3:0,9:#8a8a8a^[fill:3x16:1,0:#8a8a8a^[fill:3x16:9,0:#8a8a8a"},
	groups = {cracky = 2, not_in_creative_inventory = 1},
	is_ground_content = false,
	drop = "",
})

core.register_node(CRUSHER, {
	description = "Crusher (破碎站)\n對著平地按右鍵放置，朝自己的方向鋪 7×7 m 受料格柵\n碎石落在格柵上就過磅入帳；廢石要賠處理費",
	drawtype = "nodebox",
	paramtype = "light",
	node_box = {type = "fixed", fixed = {-1.45, -0.5, -1.45, 1.45, 2.4, 1.45}},
	tiles = {BODY},
	inventory_image = BODY,
	groups = {cracky = 2},
	is_ground_content = false,
	on_place = function(itemstack, placer, pointed)
		if pointed.type ~= "node" or not placer then return itemstack end
		local pos = pointed.above
		local look = placer:get_look_dir()
		local dx, dz = 0, 0
		if math.abs(look.x) > math.abs(look.z) then dx = look.x > 0 and -1 or 1
		else dz = look.z > 0 and -1 or 1 end
		local half = (SIZE - 1) / 2
		local cx, cz = pos.x + dx * (2 + half), pos.z + dz * (2 + half)    -- 格柵中心，緊貼機身
		local function solid(p) return not V.passable(core.get_node(p).name) end
		local ok = true
		for x = cx - half, cx + half do for z = cz - half, cz + half do
			if not solid({x = x, y = pos.y - 1, z = z}) or solid({x = x, y = pos.y, z = z}) then ok = false end
		end end
		for x = pos.x - 1, pos.x + 1 do for z = pos.z - 1, pos.z + 1 do
			if not solid({x = x, y = pos.y - 1, z = z}) then ok = false end
			for y = pos.y, pos.y + 2 do
				if solid({x = x, y = y, z = z}) then ok = false end
			end
		end end
		local name = placer:get_player_name()
		if not ok then
			core.chat_send_player(name, "[破碎站] 要放在平地上：機身 3×3 m 和前方 7×7 m 要平坦、上方淨空")
			return itemstack
		end
		for x = cx - half, cx + half do for z = cz - half, cz + half do
			core.swap_node({x = x, y = pos.y - 1, z = z}, {name = GRATE})
		end end
		core.set_node(pos, {name = CRUSHER})
		local meta = core.get_meta(pos)
		meta:set_string("owner", name)
		meta:set_int("gx", cx - half)
		meta:set_int("gy", pos.y - 1)
		meta:set_int("gz", cz - half)
		meta:set_string("infotext", "破碎站（右鍵查看）")
		core.get_node_timer(pos):start(STEP)
		if not storage:contains(MONEY .. name) then rockmech.add_money(name, 0) end
		if not core.is_creative_enabled(name) then itemstack:take_item() end
		return itemstack
	end,
	on_rightclick = function(pos, node, clicker)
		core.show_formspec(clicker:get_player_name(), CRUSHER, formspec(pos))
	end,
	on_timer = function(pos, elapsed)
		crush(pos, math.min(elapsed, 5 * STEP))
		return true
	end,
	on_destruct = function(pos)
		for _, c in ipairs(grate_cells(core.get_meta(pos))) do
			if core.get_node(c).name == GRATE then core.swap_node(c, {name = rockmech.RUBBLE}) end
		end
	end,
})
