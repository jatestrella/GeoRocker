-- rockmech/operator.lua
-- 怪手操作員是真的人（怪手上的作業邏輯在 vehicle_excavator.lua）：
--   雇用：機械設備課長那裡（免費，照日薪計），拿到一張「怪手操作員」（記著哪個帳戶雇的）。
--     全組的操作員（在車上、站在怪手旁邊、在營地休息、手上還沒派出去的）不能比全組的怪手多。
--   派上車：拿著對沒人的怪手按右鍵，這張用掉、他坐上去作業。右鍵有操作員坐著的怪手 → 操作員頁面（不上車）。
--   叫下車：他站到怪手旁邊等（看得到的人，怪手開走他會走路跟上，離太遠就直接過去），人才能上車。
--     對他按右鍵：上車作業／回基地休息。
--   回基地休息：人回到營地，只記成人數（不是一個個角色）：貨櫃辦公室南邊一張長椅，最多坐 4 個，
--     超過的寫在名牌上。對長椅或坐著的人按右鍵 → 休息室：上工（拿一張「怪手操作員」）、解雇（名額空出來）。
--     拿著「怪手操作員」對長椅按右鍵：交給他休息。
--   計薪（wages.lua 的 hire:<怪手>）：在車上、站在旁邊等都計薪；休息、手上的卡不計薪。

local V = rockmech.vehicles
local cfg = rockmech.cfg
local storage = rockmech.collapse.storage
local OP_ITEM = "rockmech:operator"
local NPC = "rockmech:operator_npc"
local SEATED = "rockmech:operator_seated"
local BENCH = "rockmech:camp_bench"
local NPC_FORM, REST_FORM = "rockmech:op_npc", "rockmech:op_rest"
local REST, HIRED = "oprest:", "ophired:"
local BENCH_SPOTS = "opbench_spots"            -- {{acc, seats = {pos...}}...}
local SEATS = 4
local FOLLOW_GAP, WALK, TELEPORT = 1.5, 4, 30  -- 站在怪手邊緣外幾公尺、走路速度 (m/s)、離太遠就直接過去 (m)

local function tell(name, msg) if name then core.chat_send_player(name, "[操作員] " .. msg) end end
local function geti(k) return storage:get_int(k) end
local function addi(k, d) storage:set_int(k, math.max(0, storage:get_int(k) + d)) end
function rockmech.op_rest_count(acc) return geti(REST .. acc) end
function rockmech.op_hired_count(acc) return geti(HIRED .. acc) end
local function excavators(acc) return V.count_owned(acc, "excavator") end

-- 舊版的操作員（已經坐在怪手上、還沒算進雇用人數）：補算
function rockmech.op_adopt(acc)
	if acc and acc ~= "" then addi(HIRED .. acc, 1) end
end

-- 雇用一個（商店）：回傳 ok, 訊息
function rockmech.op_hire(name)
	if not cfg.career then return true end
	local acc = rockmech.account_of(name)
	local hired, cap = geti(HIRED .. acc), excavators(acc)
	if hired >= cap then
		return false, ("操作員已經跟怪手一樣多了（%d 台怪手、%d 個操作員）：先買怪手，或到營地長椅解雇休息中的操作員"):format(cap, hired)
	end
	addi(HIRED .. acc, 1)
	return true
end
local function card(acc)
	local s = ItemStack(OP_ITEM)
	if acc then
		local m = s:get_meta()
		m:set_string("acc", acc)
		m:set_string("description", ("怪手操作員（%s）\n拿著對沒人的怪手按右鍵：派他上車作業\n對營地長椅按右鍵：交給他休息"):format(
			rockmech.account_label and rockmech.account_label(acc) or acc))
	end
	return s
end
rockmech.op_card = card

-- 拿這張卡派人上車可以嗎（經營模式：要是這台怪手主人的組雇的；舊版沒記帳戶的卡照雇用規則補雇）
function rockmech.op_card_ok(stack, player, ex)
	if not cfg.career or not ex.owner or ex.owner == "" then return true end
	local name = player:get_player_name()
	local acc = stack:get_meta():get_string("acc")
	if acc == "" then
		local ok, msg = rockmech.op_hire(name)
		if not ok then tell(name, msg); return false end
		return true
	end
	if acc ~= ex.owner then tell(name, "這是別組的操作員，不能派到這台怪手"); return false end
	return true
end

---------------------------------------------------------------------------
-- 站在怪手旁邊等的操作員
---------------------------------------------------------------------------

local npcs = {}        -- 怪手編號 → entity

local function op_show(ex)
	local d = V.TYPES[ex.vkind]
	if d and d.op_show then d.op_show(ex) end
end
local function remove_npc(uid)
	local o = npcs[uid]
	if o and o:get_pos() then o:remove() end
	npcs[uid] = nil
end

-- 叫下車：站到怪手旁邊（照樣計薪）
function rockmech.op_step_down(ex)
	local op = ex.op
	op.on, op.standby, op.msg, op.go, op.esc = false, true, nil, nil, nil
	ex.autopilot = nil
	op_show(ex)
end

-- 上車作業（站在旁邊的那個）
local function step_up(ex, name)
	if ex.driver then tell(name, "怪手上有人在開，先下車"); return false end
	local op = ex.op
	op.on, op.standby, op.msg, op.t = true, false, nil, 0
	remove_npc(ex.uid)
	op_show(ex)
	tell(name, "上車作業")
	return true
end

-- 回基地休息：停止計薪，營地休息的人數 +1（不是經營模式就把卡還給叫他的人）
function rockmech.op_send_rest(ex, player)
	local name = player and player:is_player() and player:get_player_name()
	local op = ex.op
	op.on, op.standby, op.msg, op.go, op.esc = false, false, nil, nil, nil
	ex.autopilot = nil
	remove_npc(ex.uid)
	if rockmech.wage_fire then rockmech.wage_fire(ex.uid) end
	op_show(ex)
	if cfg.career and ex.owner and ex.owner ~= "" then
		addi(REST .. ex.owner, 1)
		tell(name, "回營地休息了（停止計薪）：到營地貨櫃辦公室南邊的長椅找他上工")
	elseif player and player:is_player() and not core.is_creative_enabled(name) then
		local left = player:get_inventory():add_item("main", card(nil))
		if not left:is_empty() then core.add_item(player:get_pos(), left) end
		tell(name, "下班了，操作員回到你的物品欄")
	end
end

local function npc_form(ex)
	return table.concat({
		"formspec_version[6]size[11,3.4]",
		("label[0.5,0.6;%s 操作員：在旁邊等]"):format(core.formspec_escape(V.TYPES[ex.vkind].short or "怪手")),
		"label[0.5,1.2;等候中照樣計薪]",
		"button[0.5,2;3.2,0.8;up;上車作業]",
		"button[3.9,2;3.2,0.8;rest;回基地休息]",
		"button_exit[7.3,2;3.2,0.8;close;關閉]",
	})
end
local npc_editing = {}
core.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= NPC_FORM then return end
	local name = player:get_player_name()
	local ex = npc_editing[name] and V.by_uid[npc_editing[name]]
	if not (ex and ex.object:get_pos() and ex.op and ex.op.standby) then npc_editing[name] = nil; return true end
	if fields.up then
		if step_up(ex, name) then core.close_formspec(name, NPC_FORM) end
	elseif fields.rest then
		rockmech.op_send_rest(ex, player)
		core.close_formspec(name, NPC_FORM)
	end
	if fields.quit or fields.close or fields.up or fields.rest then npc_editing[name] = nil end
	return true
end)

-- 怪手旁邊的位置：車身右側邊緣外 FOLLOW_GAP m
local function beside(ex)
	local p, yaw = ex.object:get_pos(), ex.object:get_yaw()
	local d = V.TYPES[ex.vkind]
	local off = (d and d.half or 1.5) + FOLLOW_GAP
	return {x = p.x + math.cos(yaw) * off, y = p.y, z = p.z + math.sin(yaw) * off}
end
-- p 附近站得下的位置（腳下實心、身體兩格是空的）
local function standable(p)
	local x, z = math.floor(p.x + 0.5), math.floor(p.z + 0.5)
	local y0 = math.floor(p.y + 0.5)
	local function free(y)
		for h = 0, 1 do
			local def = core.registered_nodes[core.get_node({x = x, y = y + h, z = z}).name]
			if not def or def.walkable ~= false then return false end
		end
		local below = core.registered_nodes[core.get_node({x = x, y = y - 1, z = z}).name]
		return below and below.walkable ~= false
	end
	for dy = 0, 4 do
		if free(y0 + dy) then return {x = x, y = y0 + dy - 0.5, z = z} end
		if free(y0 - dy) then return {x = x, y = y0 - dy - 0.5, z = z} end
	end
end

-- 怪手每一步（vehicle_excavator.lua）：站在旁邊的操作員不在就放一個
function rockmech.op_standby_step(ex)
	local o = npcs[ex.uid]
	if o and o:get_pos() then return end
	local p = standable(beside(ex)) or vector.add(ex.object:get_pos(), {x = 0, y = 2, z = 0})
	o = core.add_entity(p, NPC)
	if o then
		o:get_luaentity().uid = ex.uid
		npcs[ex.uid] = o
	end
end

core.register_entity(NPC, {
	initial_properties = {
		physical = true, collide_with_objects = false, collisionbox = {-0.3, 0, -0.3, 0.3, 1.7, 0.3},
		visual = "mesh", mesh = "character.b3d", textures = {rockmech.npc_skin("operator")},
		nametag = "怪手操作員（右鍵）", nametag_color = "#ffe080", static_save = false, stepheight = 0.6,
	},
	on_activate = function(self)
		self.object:set_armor_groups({immortal = 1})
		self.object:set_acceleration({x = 0, y = -9.81, z = 0})
		self.object:set_animation({x = 0, y = 79}, 30)
		self.anim = "stand"
		rockmech.npc_dress(self.object, "operator")
	end,
	on_step = function(self, dtime)
		local ex = self.uid and V.by_uid[self.uid]
		if not (ex and ex.object:get_pos() and ex.op and ex.op.standby and npcs[self.uid] == self.object) then
			self.object:remove()
			return
		end
		local p, goal = self.object:get_pos(), beside(ex)
		local dx, dz = goal.x - p.x, goal.z - p.z
		local dist = math.sqrt(dx * dx + dz * dz)
		local vel = self.object:get_velocity()
		if dist > TELEPORT or math.abs(goal.y - p.y) > 8 then
			local q = standable(goal)
			if q then self.object:set_pos(q) end
			self.object:set_velocity({x = 0, y = 0, z = 0})
			return
		end
		local anim
		if dist > 1 then
			local s = math.min(WALK, dist * 2)
			self.object:set_velocity({x = dx / dist * s, y = vel.y, z = dz / dist * s})
			self.object:set_yaw(math.atan2(-dx, dz))
			-- 被擋住（想走卻幾乎沒動）：跳一下
			self.t_stuck = (math.abs(vel.x) + math.abs(vel.z) < 0.3 and (self.t_stuck or 0) + dtime) or 0
			if self.t_stuck > 0.4 and math.abs(vel.y) < 0.01 then
				self.object:set_velocity({x = dx / dist * s, y = 5.5, z = dz / dist * s})
				self.t_stuck = 0
			end
			anim = "walk"
		else
			self.object:set_velocity({x = 0, y = vel.y, z = 0})
			local ep = ex.object:get_pos()
			self.object:set_yaw(math.atan2(-(ep.x - p.x), ep.z - p.z))     -- 看著怪手
			anim = "stand"
		end
		if anim ~= self.anim then
			self.anim = anim
			if anim == "walk" then self.object:set_animation({x = 168, y = 187}, 30)
			else self.object:set_animation({x = 0, y = 79}, 30) end
		end
	end,
	on_rightclick = function(self, clicker)
		if not (clicker and clicker:is_player()) then return end
		local ex = self.uid and V.by_uid[self.uid]
		if not ex then return end
		local name = clicker:get_player_name()
		if not V.may_use(ex, name) then return end
		npc_editing[name] = self.uid
		core.show_formspec(name, NPC_FORM, npc_form(ex))
	end,
	on_punch = function() return true end,
})

---------------------------------------------------------------------------
-- 營地的休息長椅
---------------------------------------------------------------------------

local WOOD = "default_wood.png"
core.register_node(BENCH, {
	description = "長椅（操作員休息）",
	drawtype = "nodebox", paramtype = "light", paramtype2 = "facedir", sunlight_propagates = true,
	is_ground_content = false, groups = {not_in_creative_inventory = 1},
	tiles = {WOOD},
	-- 椅面、椅背在南邊（−z），坐的人臉朝北（辦公室那邊）
	node_box = {type = "fixed", fixed = {
		{-0.5, -0.05, -0.35, 0.5, 0.05, 0.35},
		{-0.5, 0.05, -0.35, 0.5, 0.7, -0.27},
		{-0.45, -0.5, -0.3, -0.35, -0.05, 0.3}, {0.35, -0.5, -0.3, 0.45, -0.05, 0.3}}},
	on_rightclick = function(pos, node, clicker, itemstack)
		if clicker and clicker:is_player() then rockmech.op_bench_click(pos, clicker) end
		return itemstack
	end,
})

local function spots() return core.deserialize(storage:get_string(BENCH_SPOTS)) or {} end
local function spot_at(pos)
	for i, s in ipairs(spots()) do
		for _, q in ipairs(s.seats) do
			if math.abs(q.x - pos.x) < 0.6 and math.abs(q.z - pos.z) < 0.6 and math.abs(q.y - pos.y) < 1.6 then return s, i end
		end
	end
end

local rest_view = {}     -- 玩家名稱 → 帳戶
local function rest_form(name, acc)
	local n, hired, cap = geti(REST .. acc), geti(HIRED .. acc), excavators(acc)
	local mine = rockmech.account_of(name) == acc
	local out = {
		"formspec_version[6]size[11,4.4]",
		("label[0.5,0.6;%s 的休息室]"):format(core.formspec_escape(rockmech.account_label and rockmech.account_label(acc) or acc)),
		("label[0.5,1.2;休息中 %d 人（全組雇用 %d 人、怪手 %d 台；休息不計薪）]"):format(n, hired, cap),
	}
	if mine then
		out[#out + 1] = "button[0.5,2;3.2,0.8;work;上工（拿一張操作員）]"
		out[#out + 1] = "button[3.9,2;3.2,0.8;fire;解雇一個]"
		out[#out + 1] = "label[0.5,3.4;拿著「怪手操作員」對長椅按右鍵：交給他休息]"
	else
		out[#out + 1] = "label[0.5,2.3;這是別組的營地]"
	end
	out[#out + 1] = "button_exit[7.3,2;3.2,0.8;close;關閉]"
	return table.concat(out)
end

function rockmech.op_bench_click(pos, player)
	local s = spot_at(pos)
	if not s then return end
	local name = player:get_player_name()
	local stack = player:get_wielded_item()
	if stack:get_name() == OP_ITEM and rockmech.account_of(name) == s.acc then
		local acc = stack:get_meta():get_string("acc")
		if acc ~= "" and acc ~= s.acc then tell(name, "這是別組的操作員"); return end
		if acc == "" and cfg.career then
			-- 舊版沒記帳戶的卡：照雇用規則算進這組
			local ok, msg = rockmech.op_hire(name)
			if not ok then tell(name, msg); return end
		end
		stack:take_item()
		player:set_wielded_item(stack)
		addi(REST .. s.acc, 1)
		tell(name, ("交給他休息了（休息中 %d 人）"):format(geti(REST .. s.acc)))
		return
	end
	rest_view[name] = s.acc
	core.show_formspec(name, REST_FORM, rest_form(name, s.acc))
end

core.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= REST_FORM then return end
	local name = player:get_player_name()
	local acc = rest_view[name]
	if not acc or rockmech.account_of(name) ~= acc then rest_view[name] = nil; return true end
	if fields.work then
		if geti(REST .. acc) <= 0 then tell(name, "沒有人在休息")
		else
			local left = player:get_inventory():add_item("main", card(acc))
			if left:is_empty() then
				addi(REST .. acc, -1)
				tell(name, "操作員跟你走了：拿著對沒人的怪手按右鍵派他上車")
			else tell(name, "物品欄滿了") end
		end
	elseif fields.fire then
		if geti(REST .. acc) <= 0 then tell(name, "沒有人在休息（只能解雇休息中的）")
		else
			addi(REST .. acc, -1)
			addi(HIRED .. acc, -1)
			core.log("action", ("[rockmech] %s 解雇一個休息中的操作員（%s）"):format(name, acc))
			tell(name, "解雇了一個操作員，名額空出來")
		end
	end
	if fields.quit or fields.close then rest_view[name] = nil
	else core.show_formspec(name, REST_FORM, rest_form(name, acc)) end
	return true
end)

-- 卡片不能丟在地上（人不會被丟在路邊）
core.register_craftitem(OP_ITEM, {
	description = "怪手操作員 Excavator operator\n拿著對沒人的怪手按右鍵：派他上車作業\n對營地長椅按右鍵：交給他休息",
	inventory_image = "[fill:16x16:#00000000^[fill:6x6:5,1:#e0b080^[fill:8x7:4,7:#e8a818^[fill:8x2:4,7:#303030^[fill:2x2:7,3:#303030",
	stack_max = 1,
	on_drop = function(itemstack, dropper)
		if cfg.career then
			tell(dropper and dropper:get_player_name(), "操作員不能丟在地上：帶回營地長椅交給他休息")
			return itemstack
		end
		return core.item_drop(itemstack, dropper, dropper:get_pos())
	end,
})

-- 長椅上坐著的操作員（最多 SEATS 個，第一個的名牌寫總人數）：玩家走近才放，不存檔
core.register_entity(SEATED, {
	initial_properties = {
		physical = true, collisionbox = {-0.3, 0, -0.3, 0.3, 1.2, 0.3},
		visual = "mesh", mesh = "character.b3d", textures = {rockmech.npc_skin("operator")},
		nametag = "", nametag_color = "#ffe080", static_save = false,
	},
	on_activate = function(self)
		self.object:set_armor_groups({immortal = 1})
		self.object:set_yaw(0)
		self.object:set_animation({x = 81, y = 160}, 30)
		rockmech.npc_dress(self.object, "operator")
	end,
	on_rightclick = function(self, clicker)
		if clicker and clicker:is_player() then rockmech.op_bench_click(self.object:get_pos(), clicker) end
	end,
	on_punch = function() return true end,
})

local seated = {}     -- 長椅序號 → {entity...}
local NEAR = 40
local seat_t = 0
core.register_globalstep(function(dtime)
	seat_t = seat_t + dtime
	if seat_t < 2 then return end
	seat_t = 0
	local players = core.get_connected_players()
	for i, s in ipairs(spots()) do
		local near = false
		for _, pl in ipairs(players) do
			if vector.distance(pl:get_pos(), s.seats[1]) < NEAR then near = true; break end
		end
		local list = seated[i] or {}
		seated[i] = list
		local n = near and math.min(SEATS, #s.seats, geti(REST .. s.acc)) or 0
		for k = 1, math.max(#s.seats, SEATS) do
			local o = list[k]
			local alive = o and o:get_pos()
			if k <= n and not alive then
				local q = s.seats[k]
				list[k] = core.add_entity({x = q.x, y = q.y + 0.05, z = q.z}, SEATED)      -- 同營地攤主坐椅子：椅子那格 + 0.05
			elseif k > n and alive then
				o:remove(); list[k] = nil
			end
		end
		local total = geti(REST .. s.acc)
		local first = list[1]
		if first and first:get_pos() then
			first:set_properties({nametag = total > SEATS and ("操作員休息中 %d 人（長椅坐不下的在辦公室裡）"):format(total)
				or ("操作員休息中 %d 人（右鍵）"):format(total)})
		end
	end
end)

-- 在營地蓋長椅：貨櫃辦公室南邊（辦公室中心往南 9 m），4 個座位排成東西向，臉朝北
local function ground_y(x, z)
	for y = 40, -30, -1 do
		local n = core.get_node({x = x, y = y, z = z}).name
		if n ~= "air" and n ~= "ignore" then return y end
	end
end
local BENCH_Z = -9
local function flag_of(x0) return "opbench_site:" .. x0 end
function rockmech.career_build_opbench(x0, acc)
	storage:set_string(flag_of(x0), "1")
	local cx = x0 + (rockmech.career_office_dx or 27)
	local y = ground_y(cx, BENCH_Z) or 0
	local seats = {}
	for k = 0, SEATS - 1 do
		local p = {x = cx - 2 + k, y = y + 1, z = BENCH_Z}
		core.set_node(p, {name = BENCH, param2 = 0})
		for h = 1, 2 do core.set_node({x = p.x, y = p.y + h, z = p.z}, {name = "air"}) end
		seats[#seats + 1] = p
	end
	local list = spots()
	list[#list + 1] = {acc = acc, seats = seats, x0 = x0}
	storage:set_string(BENCH_SPOTS, core.serialize(list))
	core.log("action", ("[rockmech] 營地 x = %d 加上操作員休息長椅（%s）"):format(x0, acc))
end

-- 已經蓋好的營地補上長椅：出生點的營地歸它破碎站的主人，各組的營地歸 team:<組>
if cfg.career then
	core.after(4, function()
		local sites = {}
		if storage:get_string("career_site") == "2" then sites[#sites + 1] = {x0 = cfg.career_camp_dx} end
		if rockmech.team_site_x then
			for i = 1, cfg.career_teams do
				local t = tostring(i)
				if storage:get_string("team_site:" .. t) == "1" then sites[#sites + 1] = {x0 = rockmech.team_site_x(t), acc = "team:" .. t} end
			end
		end
		for _, s in ipairs(sites) do
			if storage:get_string(flag_of(s.x0)) == "" then
				local cx = s.x0 + (rockmech.career_office_dx or 27)
				core.emerge_area({x = s.x0 - 10, y = -30, z = BENCH_Z - 8}, {x = cx + 8, y = 40, z = 20}, function(_, _, rem)
					if rem > 0 or storage:get_string(flag_of(s.x0)) ~= "" then return end
					local acc = s.acc
					if not acc then
						local c = core.find_nodes_in_area({x = s.x0 + 10, y = -30, z = 0}, {x = s.x0 + 30, y = 40, z = 20},
							{"rockmech:crusher", "rockmech:crusher_big"})[1]
						acc = c and core.get_meta(c):get_string("owner") or ""
						if acc == "" then acc = "team:0" end
					end
					rockmech.career_build_opbench(s.x0, acc)
				end)
			end
		end
	end)
end
