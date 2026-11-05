-- rockmech/crusher.lua
-- 破碎站（賣礦）：放在平地上，朝玩家的方向挖一個受料倉：9×9 m、深 4 m 的階梯漏斗，壁坡 45° 比安息角陡，
-- 碎石不會留在壁上。底部 3×3 m 是格柵（給料口），只從這裡吃料，上方的料靠碎石流動自己補進來。
-- 卡車、挖土機、推土機倒進來都一樣；每秒最多 rockmech_crusher_rate 噸，倒太快就在倉裡排隊。
-- 過磅入帳：收入 = 噸數 ×（品位 × 回收率 × 價格 − 處理費），見 config.crush_income。廢石的品位是 0，
-- 運來破碎只會賠處理費，這就是貧化與截止品位。錢記在放置破碎站的玩家身上。
-- 右鍵可以切換成廢石場：倒進來的碎石直接棄置，不收入，每噸付 rockmech_dump_fee（預設 0）。
-- 受料倉、格柵、強制載入給選礦場（plant.lua）共用：rockmech.hopper_lib

local cfg = rockmech.cfg
local V = rockmech.vehicles
local storage = rockmech.collapse.storage

local CRUSHER, GRATE = "rockmech:crusher", "rockmech:crusher_grate"
local PLANT = "rockmech:plant"     -- 選礦場（plant.lua），同一種受料倉
local HOPPER_BODY = {[CRUSHER] = true, [PLANT] = true}
local SIZE, FEEDER = 9, 3    -- 受料倉開口、底部格柵的邊長 (m)
local DEPTH = (SIZE - FEEDER) / 2 + 1              -- 倉深 (m)：每往下一層四邊各內縮 1 m（壁坡 45°），最底層就是格柵的大小
local CAPACITY = 0          -- 容量（級），裝到倉口
for dy = 0, DEPTH - 1 do CAPACITY = CAPACITY + (SIZE - 2 * dy) ^ 2 * rockmech.vehicles.NLEV end
local PILE = 8              -- 格柵上往上找幾格碎石
local FIND_R = 15           -- 傾倒點離格柵中心多近（水平距離）算在破碎站
rockmech.HOPPER_RANGE = FIND_R
rockmech.HOPPER_HALF = SIZE / 2   -- 倉口中心到邊 (m)
local STEP = 1              -- 每幾秒吃一次
local MONEY = "money:"      -- mod storage 的鍵
local COIN_LEAD = 0.4       -- 金幣聲響完多久才出結算訊息 (s)

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
		money_hud[name] = player:hud_add({type = "text", position = {x = 0.98, y = 0.06}, alignment = {x = -1, y = 1},
			number = 0xFFE080, text = text, z_index = 100})
	end
end

function rockmech.money(name) return storage:get_float(MONEY .. name) end
function rockmech.add_money(name, amount)
	storage:set_float(MONEY .. name, storage:get_float(MONEY .. name) + amount)
	local player = core.get_player_by_name(name)
	if player then show_money(player) end
end

core.register_on_joinplayer(function(player)
	if storage:contains(MONEY .. player:get_player_name()) then show_money(player) end
end)
core.register_on_leaveplayer(function(player) money_hud[player:get_player_name()] = nil end)

-- pos 在破碎站的容許範圍內就回傳格柵的中心，否則 nil。給 search 就改找這個距離內最近的破碎站，不管容許範圍
function rockmech.grate_center(pos, search)
	local g = core.find_node_near(pos, search or FIND_R + FEEDER, GRATE)
	if not g then return nil end
	local x, y, z = g.x, g.y, g.z
	local function span(dx, dz)
		local k = 0
		while core.get_node({x = x + dx * (k + 1), y = y, z = z + dz * (k + 1)}).name == GRATE do k = k + 1 end
		return k
	end
	local c = {x = x + (span(1, 0) - span(-1, 0)) / 2, y = y, z = z + (span(0, 1) - span(0, -1)) / 2}
	if not search and (pos.x - c.x) ^ 2 + (pos.z - c.z) ^ 2 > FIND_R ^ 2 then return nil end
	return c
end

---------------------------------------------------------------------------
-- 破碎
---------------------------------------------------------------------------

local function grate_cells(meta)
	local x0, y, z0 = meta:get_int("gx"), meta:get_int("gy"), meta:get_int("gz")
	local cells = {}
	for x = x0, x0 + FEEDER - 1 do for z = z0, z0 + FEEDER - 1 do
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

-- 受料倉裡的碎石（級）。c：格柵中心
local function hopper_levels(c)
	local r = (SIZE - 1) / 2
	local n = 0
	for x = c.x - r, c.x + r do for z = c.z - r, c.z + r do for y = c.y + 1, c.y + PILE do
		n = n + (rockmech.rubble_level[core.get_node({x = x, y = y, z = z}).name] or 0)
	end end end
	return n
end
-- 受料倉還放得下幾級（無人駕駛用來判斷要不要等）
function rockmech.hopper_room(c) return CAPACITY - hopper_levels(c) end

-- 倉裡的碎石往給料口流：每次掃整個倉，每欄走一步。只叫給料口旁邊的格子的話，外圈階梯上的料不會動
local function drain(c)
	local r = (SIZE - 1) / 2
	for x = c.x - r, c.x + r do for z = c.z - r, c.z + r do
		for y = c.y + PILE, c.y + 1, -1 do
			local q = {x = x, y = y, z = z}
			if rockmech.rubble_level[core.get_node(q).name] then
				rockmech.collapse.granular_settle(q, 1)
				break
			end
		end
	end end
end

local function hopper_center(meta)
	return {x = meta:get_int("gx") + (FEEDER - 1) / 2, y = meta:get_int("gy"), z = meta:get_int("gz") + (FEEDER - 1) / 2}
end

-- 每級碎石的噸數：1/8 m³，密度用 γ/10
local function tons_of(levels) return levels / V.NLEV * cfg.failure.gamma_other / 10 end

-- 從格柵吃料：這一步最多 rate (t/s) × dtime，也不超過 limit 級（選礦場的倉快滿了）。
-- 每吃一塊呼叫 take(級數, 碎石種類, 品位 param2)；回傳吃了幾級。倉裡的料順便往格柵流一步
local function eat(pos, dtime, rate, limit, take)
	local meta = core.get_meta(pos)
	local budget = meta:get_float("carry") + rate * dtime / tons_of(1)
	local want = math.min(math.floor(budget), limit or math.huge)
	local eaten = 0
	local cells = grate_cells(meta)
	local start = meta:get_int("next")
	for i = 1, #cells do
		if want <= 0 then break end
		local p = top_rubble(cells[(start + i - 1) % #cells + 1])
		if p then
			local t, base, p2 = V.take_rubble(p, want)
			want = want - t
			eaten = eaten + t
			take(t, base, p2)
			meta:set_int("next", (start + i) % #cells)
		end
	end
	drain(hopper_center(meta))
	meta:set_float("carry", eaten > 0 and budget - math.floor(budget) or 0)
	if eaten > 0 then rockmech.collapse.rubble_sound(pos, eaten) end
	return eaten
end

local function crush(pos, dtime)
	local meta = core.get_meta(pos)
	local dump = meta:get_string("mode") == "dump"
	local income, ore_t = 0, 0
	local eaten = eat(pos, dtime, cfg.crusher_rate, nil, function(t, base, p2)
		local ore = rockmech.ore_of_rubble[base]
		local grade = ore and p2 / 255 or 0
		if dump then income = income - tons_of(t) * cfg.dump_fee
		else income = income + rockmech.config.crush_income(tons_of(t), grade, ore, cfg.crusher_fee) end
		ore_t = ore_t + tons_of(t) * grade
	end)
	local owner = meta:get_string("owner")
	if eaten == 0 then
		-- 吃完了：回報這一批（破碎：先響金幣聲，再出結算）
		local bt = meta:get_float("batch_t")
		if bt > 0 then
			if dump then
				core.chat_send_player(owner, ("[廢石場] 這批 %.1f t 棄置%s"):format(bt,
					cfg.dump_fee > 0 and ("，棄置費 $%.0f"):format(-meta:get_float("batch_m")) or ""))
			else
				core.sound_play("rockmech_coin", {to_player = owner, gain = 0.8}, true)
				core.after(COIN_LEAD, core.chat_send_player, owner, ("[破碎站] 這批 %.1f t，品位 %.0f%%，收入 $%.0f"):format(bt,
					100 * meta:get_float("batch_q") / bt, meta:get_float("batch_m")))
			end
			meta:set_float("batch_t", 0)
			meta:set_float("batch_q", 0)
			meta:set_float("batch_m", 0)
		end
		return
	end
	local t = tons_of(eaten)
	if income ~= 0 then rockmech.add_money(owner, income) end
	for key, v in pairs({batch_t = t, batch_q = ore_t, batch_m = income, total_t = t, total_q = ore_t, total_m = income}) do
		meta:set_float(key, meta:get_float(key) + v)
	end
end

local function formspec(pos)
	local meta = core.get_meta(pos)
	local queue = hopper_levels(hopper_center(meta))
	local total = meta:get_float("total_t")
	local dump = meta:get_string("mode") == "dump"
	local prices = {}
	for _, ore in pairs(cfg.ores) do
		prices[#prices + 1] = ("%s 品位 100%% 每噸 $%g，回收率 %.0f%%"):format(ore.label, ore.price, ore.recovery * 100)
	end
	return table.concat({
		"formspec_version[6]size[9,7]",
		("label[0.5,0.6;%s]"):format(dump and "廢石場（倒進來的碎石直接棄置，不收入）" or "破碎站"),
		dump and ("label[0.5,1.2;處理能力：%g t/s　棄置費：每噸 $%g]"):format(cfg.crusher_rate, cfg.dump_fee)
			or ("label[0.5,1.2;處理能力：%g t/s　處理費：每噸 $%g]"):format(cfg.crusher_rate, cfg.crusher_fee),
		("label[0.5,1.8;%s]"):format(core.formspec_escape(dump and "礦石倒進來也當廢石丟掉" or table.concat(prices, "；"))),
		("button[0.5,5.8;8,0.8;mode;%s]"):format(dump and "切換成破碎站（賣礦）" or ("切換成廢石場（棄置，每噸 $%g）"):format(cfg.dump_fee)),
		("label[0.5,2.4;受料倉：%.1f / %.0f t]"):format(tons_of(queue), tons_of(CAPACITY)),
		("label[0.5,3.0;累計處理：%.1f t，平均品位 %.0f%%]"):format(total, total > 0 and 100 * meta:get_float("total_q") / total or 0),
		("label[0.5,3.6;累計收入：$%.0f]"):format(meta:get_float("total_m")),
		("label[0.5,4.2;資金（%s）：$%.0f]"):format(core.formspec_escape(meta:get_string("owner")),
			storage:get_float(MONEY .. meta:get_string("owner"))),
		"button_exit[3,4.8;3,0.8;ok;關閉]",
	})
end
local editing = {}          -- 玩家名稱 → 正在看的破碎站
core.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= CRUSHER then return end
	local name = player:get_player_name()
	local pos = editing[name]
	if not pos or core.get_node(pos).name ~= CRUSHER then return true end
	if fields.mode then
		local meta = core.get_meta(pos)
		meta:set_string("mode", meta:get_string("mode") == "dump" and "" or "dump")
		meta:set_string("infotext", meta:get_string("mode") == "dump" and "廢石場（右鍵查看）" or "破碎站（右鍵查看）")
		core.show_formspec(name, CRUSHER, formspec(pos))
	end
	if fields.quit or fields.ok then editing[name] = nil end
	return true
end)

---------------------------------------------------------------------------
-- 方塊
---------------------------------------------------------------------------

-- 機身在 pos、受料倉朝 (dx, dz)：挖階梯漏斗（每往下一層四邊各內縮 1 m）、放格柵、記到機身的 meta。
-- 倉裡原有的碎石不挖，之後逐欄疊到新的倉底（舊倉擴建）
local function dig_hopper(pos, dx, dz)
	local half = (SIZE - 1) / 2
	local cx, cz = pos.x + dx * (2 + half), pos.z + dz * (2 + half)    -- 受料倉中心，緊貼機身
	local gy = pos.y - 1 - DEPTH
	for dy = 0, DEPTH - 1 do
		local r = half - dy
		for x = cx - r, cx + r do for z = cz - r, cz + r do
			local p = {x = x, y = pos.y - 1 - dy, z = z}
			if not rockmech.rubble_level[core.get_node(p).name] then
				rockmech.collapse.mark_excavated(p)
				core.swap_node(p, {name = "air"})
			end
		end end
	end
	local r = (FEEDER - 1) / 2
	for x = cx - r, cx + r do for z = cz - r, cz + r do
		core.swap_node({x = x, y = gy, z = z}, {name = GRATE})
	end end
	-- 懸空的碎石往下疊：每欄由下往上，保留種類、級數、品位
	for x = cx - half, cx + half do for z = cz - half, cz + half do
		local floor, stack = nil, {}
		for y = gy, pos.y + PILE do
			local p = {x = x, y = y, z = z}
			local n = core.get_node(p)
			if rockmech.rubble_level[n.name] then
				stack[#stack + 1] = n
				core.swap_node(p, {name = "air"})
			elseif n.name ~= "air" and #stack == 0 then
				floor = y
			end
		end
		for i, n in ipairs(stack) do core.swap_node({x = x, y = floor + i, z = z}, n) end
	end end
	local meta = core.get_meta(pos)
	meta:set_int("gx", cx - r)
	meta:set_int("gy", gy)
	meta:set_int("gz", cz - r)
	meta:set_int("size", SIZE)
end

-- 破碎站不管人在哪裡都要運作：引擎只在玩家附近的區塊跑節點計時器，人到礦場去了倉裡的料就停著。
-- 機身和受料倉（含倉上 PILE 格）所在的區塊強制載入，存在世界裡；一座最多 8 塊。不受 max_forceloaded_blocks（預設 16）
-- 限制：無人卡車、怪手沿途也會暫時強制載入（vehicles.lua），合起來常超過 16
local function each_block(pos, fn)
	local meta = core.get_meta(pos)
	local c, h = hopper_center(meta), (SIZE - 1) / 2
	local a = {x = math.min(pos.x - 1, c.x - h), y = meta:get_int("gy"), z = math.min(pos.z - 1, c.z - h)}
	local b = {x = math.max(pos.x + 1, c.x + h), y = pos.y + PILE, z = math.max(pos.z + 1, c.z + h)}
	for bx = math.floor(a.x / 16), math.floor(b.x / 16) do
		for by = math.floor(a.y / 16), math.floor(b.y / 16) do
			for bz = math.floor(a.z / 16), math.floor(b.z / 16) do fn({x = bx * 16, y = by * 16, z = bz * 16}) end
		end
	end
end
local function keep_loaded(pos)
	local meta = core.get_meta(pos)
	if not HOPPER_BODY[core.get_node(pos).name] or meta:get_int("forceload") == 1 then return end
	local n = 0
	each_block(pos, function(p) n = n + 1; core.forceload_block(p, false, -1) end)
	meta:set_int("forceload", 1)
	core.log("action", ("[rockmech] %s %s 強制載入 %d 個區塊"):format(core.get_node(pos).name, core.pos_to_string(pos), n))
end

-- 機身在 pos、受料倉朝 (dx, dz) 的地形可以蓋嗎：機身 3×3 m 和受料倉要平坦、地下是實心、上方淨空
local function site_ok(pos, dx, dz)
	local half = (SIZE - 1) / 2
	local cx, cz = pos.x + dx * (2 + half), pos.z + dz * (2 + half)    -- 受料倉中心，緊貼機身
	local function solid(p) return not V.passable(core.get_node(p).name) end
	for x = cx - half, cx + half do for z = cz - half, cz + half do
		if solid({x = x, y = pos.y, z = z}) then return false end
		for y = pos.y - 1 - DEPTH, pos.y - 1 do
			if not solid({x = x, y = y, z = z}) then return false end
		end
	end end
	for x = pos.x - 1, pos.x + 1 do for z = pos.z - 1, pos.z + 1 do
		if not solid({x = x, y = pos.y - 1, z = z}) then return false end
		for y = pos.y, pos.y + 2 do
			if solid({x = x, y = y, z = z}) then return false end
		end
	end end
	return true
end

-- 在 pos 蓋破碎站（機身），受料倉朝 (dx, dz)。地不平回傳 false
function rockmech.crusher_build(pos, dx, dz, name)
	if not site_ok(pos, dx, dz) then return false end
	core.set_node(pos, {name = CRUSHER})
	dig_hopper(pos, dx, dz)
	local meta = core.get_meta(pos)
	meta:set_string("owner", name)
	meta:set_string("infotext", "破碎站（右鍵查看）")
	core.get_node_timer(pos):start(STEP)
	keep_loaded(pos)
	if not storage:contains(MONEY .. name) then rockmech.add_money(name, 0) end
	return true
end

local BODY = "[fill:16x16:#b08a20^[fill:16x2:0,0:#303030^[fill:16x2:0,14:#303030"

core.register_node(GRATE, {
	description = "Crusher grate (破碎站受料格柵)",
	tiles = {"[fill:16x16:#181818^[fill:16x3:0,1:#8a8a8a^[fill:16x3:0,9:#8a8a8a^[fill:3x16:1,0:#8a8a8a^[fill:3x16:9,0:#8a8a8a"},
	groups = {cracky = 2, not_in_creative_inventory = 1},
	is_ground_content = false,
	drop = "",
})

core.register_node(CRUSHER, {
	description = "Crusher (破碎站)\n對著平地按右鍵放置，朝自己的方向挖 " .. SIZE .. "×" .. SIZE .. " m 受料倉\n碎石倒進倉裡就過磅入帳；廢石要賠處理費",
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
		local name = placer:get_player_name()
		if not rockmech.crusher_build(pos, dx, dz, name) then
			core.chat_send_player(name, "[破碎站] 要放在平地上：機身 3×3 m 和前方 " .. SIZE .. "×" .. SIZE .. " m 要平坦、地下是實心、上方淨空")
			return itemstack
		end
		if not core.is_creative_enabled(name) then itemstack:take_item() end
		return itemstack
	end,
	on_rightclick = function(pos, node, clicker)
		editing[clicker:get_player_name()] = pos
		core.show_formspec(clicker:get_player_name(), CRUSHER, formspec(pos))
	end,
	on_timer = function(pos, elapsed)
		crush(pos, math.min(elapsed, 5 * STEP))
		return true
	end,
	on_destruct = function(pos)
		local meta = core.get_meta(pos)
		for _, c in ipairs(grate_cells(meta)) do
			if core.get_node(c).name == GRATE then core.swap_node(c, {name = rockmech.RUBBLE}) end
		end
		if meta:get_int("forceload") == 1 then each_block(pos, function(p) core.forceload_free_block(p, false) end) end
	end,
})

-- 舊版小倉擴建成現在的大小：舊格柵回填成下面的岩石，再照新尺寸挖（倉裡的碎石留著，疊到新的倉底）
local function enlarge(pos)
	local meta = core.get_meta(pos)
	if core.get_node(pos).name ~= CRUSHER or meta:get_int("size") >= SIZE then return end
	local old = hopper_center(meta)
	local dx, dz = 0, 0
	if math.abs(old.x - pos.x) > math.abs(old.z - pos.z) then dx = old.x > pos.x and 1 or -1
	else dz = old.z > pos.z and 1 or -1 end
	local reach = 2 + SIZE
	core.load_area({x = pos.x - reach, y = pos.y - DEPTH - 2, z = pos.z - reach}, {x = pos.x + reach, y = pos.y + PILE, z = pos.z + reach})
	for _, c in ipairs(grate_cells(meta)) do
		core.swap_node(c, core.get_node({x = c.x, y = c.y - 1, z = c.z}))
	end
	dig_hopper(pos, dx, dz)
	core.log("action", ("[rockmech] 受料倉擴建成 %d×%d m：機身 %s"):format(SIZE, SIZE, core.pos_to_string(pos)))
end
core.register_lbm({
	label = "rockmech: 舊版受料倉擴建",
	name = "rockmech:hopper_size_" .. SIZE,
	nodenames = {CRUSHER},
	run_at_every_load = false,
	action = function(pos) core.after(0, enlarge, pos) end,
})
-- 舊世界的破碎站：走近一次就補上強制載入（在擴建之後，區塊照新的倉算）
core.register_lbm({
	label = "rockmech: 破碎站強制載入",
	name = "rockmech:crusher_forceload",
	nodenames = {CRUSHER},
	run_at_every_load = false,
	action = function(pos) core.after(1, keep_loaded, pos) end,
})

-- 給選礦場（plant.lua）共用
rockmech.hopper_lib = {
	SIZE = SIZE, PILE = PILE, STEP = STEP, GRATE = GRATE, tons_of = tons_of, eat = eat,
	hopper_center = hopper_center, hopper_levels = hopper_levels, grate_cells = grate_cells, dig_hopper = dig_hopper,
	site_ok = site_ok, keep_loaded = keep_loaded, each_block = each_block,
}
