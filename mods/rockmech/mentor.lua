-- rockmech/mentor.lua
-- 老礦工：單機經營模式的提示 NPC。待在營地出生點旁邊（附近晃晃、敲敲石頭），不主動出題、不會離開。
-- 右鍵點他：照玩家還沒做到的第一件事給一句提示（聊天口氣，不下指令）；都做過了就講閒話。
-- 第一次走近他會打招呼。只在單機的經營模式（rockmech_solo 或單人遊戲，不是教學地圖）；世界設定 rockmech_mentor = false 關掉。

local cfg = rockmech.cfg
if not cfg.career or cfg.teacher or not (cfg.solo or core.is_singleplayer()) then return end
if not cfg.mentor then return end
local S = rockmech.S
local storage = rockmech.collapse.storage

local NPC = "rockmech:npc_mentor"
local WHO = "mentor"
local GREETED = "rockmech:mentor_greeted"
local HOME_DX, HOME_DZ = -4, 4      -- 站在出生點西北邊（往煤層露頭那邊）
local ROAM = 4                      -- 在家附近幾公尺內晃
local NEAR_SPAWN, FAR_DROP = 64, 90 -- 玩家多近才放他出來、多遠收掉（不存檔）

local function acc_of(name) return rockmech.account_of and rockmech.account_of(name) or name end
local function holding_ore(player)
	local c = rockmech.carry_get and rockmech.carry_get(player)
	return c and c.base and rockmech.ore_of_rubble and rockmech.ore_of_rubble[c.base] ~= nil and (c.p2 or 0) > 40
end
local function sold(name) return storage:get_float("strip_o:" .. acc_of(name)) > 0 end

-- 提示：照順序，第一個還沒做到的（check 為假）就講它的提示（輪流）
local TOPICS = {
	{
		hints = {S("See that black streak on the hill? Knock a piece off and show me."),
			S("The black one. If it won't break, you're hitting the wrong rock.")},
		check = function(player, name) return holding_ore(player) or sold(name) end,
	},
	{
		hints = {S("Coal, sure enough. How much ash is in it? Only the scale at the coal yard knows."),
			S("That noisy machine by the camp. Coal it pays for; rock it charges you for.")},
		check = function(_, name) return sold(name) end,
	},
	{
		hints = {S("Carrying it by hand? You'll be hauling until you retire."), S("Even in my day we had wheels.")},
		check = function(_, name)
			local V = rockmech.vehicles
			return V and V.count_owned and V.count_owned(acc_of(name), "") > 0
		end,
	},
	{
		hints = {S("In my day, one drill hole told us how thick the coal ran down below."),
			S("Digging blind costs more than drilling.")},
		check = function(_, name)
			local t = core.deserialize(storage:get_string("bh:" .. acc_of(name)))
			return type(t) == "table" and #t > 0
		end,
	},
}
local GREETING = S("Hey, kid. New here? I worked these hills for forty years.")
-- 都做過了：閒話和老經驗
local CHATTER = {
	S("My lungs aren't what they used to be."),
	S("Coal dust and sweet potato porridge. That was our life."),
	S("The mountain feeds you, and the mountain takes you back."),
	S("Listen to the rock. When it creaks, run."),
	S("Look at the cracks in that rock face. You'd stand under that?"),
	S("Rock doesn't warn you twice. We used to prop it up with timber."),
	S("Read that core carefully. The rock tells you everything."),
	S("Good. Respect the rock and it lets you go home."),
}

local function translate(player, str)
	local info = core.get_player_information(player:get_player_name())
	return core.get_translated_string(info and info.lang_code ~= "" and info.lang_code or "zh_TW", str)
end

local turn = {}     -- 玩家名 → 每個話題講到第幾句（輪流）
local function hint_for(player)
	local name = player:get_player_name()
	for i, T in ipairs(TOPICS) do
		if not T.check(player, name) then
			turn[name] = turn[name] or {}
			turn[name][i] = (turn[name][i] or 0) % #T.hints + 1
			return T.hints[turn[name][i]]
		end
	end
	return CHATTER[math.random(#CHATTER)]
end

---------------------------------------------------------------------------
-- 站的地方、走動
---------------------------------------------------------------------------

local function walkable(pos)
	local def = core.registered_nodes[core.get_node(pos).name]
	return def and def.walkable
end
local function clear(pos)
	local def = core.registered_nodes[core.get_node(pos).name]
	return def and not def.walkable and (def.liquidtype or "none") == "none"
end
-- pos 附近站得住的地方（腳下實心、上面兩格空）
local function spot_near(pos, rmin, rmax)
	local p0 = vector.round(pos)
	for _ = 1, 24 do
		local a = math.random() * 2 * math.pi
		local r = rmin + math.random() * (rmax - rmin)
		local x, z = math.floor(p0.x + math.cos(a) * r + 0.5), math.floor(p0.z + math.sin(a) * r + 0.5)
		for dy = 4, -6, -1 do
			local f = {x = x, y = p0.y + dy - 1, z = z}
			if walkable(f) and clear({x = x, y = f.y + 1, z = z}) and clear({x = x, y = f.y + 2, z = z}) then
				return {x = x, y = f.y + 1, z = z}
			end
		end
	end
end
local function home()
	local x0 = cfg.career_camp_dx or 0
	local p = rockmech.career_spawn and rockmech.career_spawn(x0) or {x = x0, y = 1, z = 0}
	return {x = p.x + HOME_DX, y = p.y, z = p.z + HOME_DZ}
end
local function yaw_to(from, to) return (math.atan2 or math.atan)(-(to.x - from.x), to.z - from.z) end

local mentor     -- 唯一的物件

core.register_entity(NPC, {
	initial_properties = {
		physical = true, collide_with_objects = false, collisionbox = {-0.3, 0, -0.3, 0.3, 1.7, 0.3},
		visual = "mesh", mesh = "character.b3d", textures = {rockmech.npc_skin(WHO)},
		nametag = S("Old Miner"), nametag_color = "#e8d8a0", stepheight = 1.1, static_save = false,
	},
	on_activate = function(self)
		self.object:set_armor_groups({immortal = 1})
		self.object:set_acceleration({x = 0, y = -9.81, z = 0})
		self.object:set_animation({x = 0, y = 79}, 30)
		rockmech.npc_dress(self.object, WHO)
		self.idle = math.random(4, 10)
	end,
	on_step = function(self, dtime)
		if mentor ~= self.object then self.object:remove(); return end
		local pos = self.object:get_pos()
		local vel = self.object:get_velocity()
		local function anim(kind)
			if self.anim == kind then return end
			self.anim = kind
			if kind == "walk" then self.object:set_animation({x = 168, y = 187}, 20)
			elseif kind == "work" then self.object:set_animation({x = 189, y = 198}, 20)
			else self.object:set_animation({x = 0, y = 79}, 30) end
		end
		local function stop(kind)
			self.object:set_velocity({x = 0, y = vel.y, z = 0})
			anim(kind or "stand")
		end
		local h = self.home or home()
		self.home = h
		-- 掉下去、卡住、跑太遠：回家
		if (self.stuck or 0) > 6 or pos.y < h.y - 10 or vector.distance(pos, h) > 20 then
			local s = spot_near(h, 0, 2)
			if s then self.object:set_pos(s) end
			self.stuck, self.best, self.tgt = 0, nil, nil
			return
		end
		-- 有人在旁邊：停下來看著他
		local near
		for _, p in ipairs(core.get_connected_players()) do
			local pp = p:get_pos()
			if vector.distance(pp, pos) < 4 then near = pp; break end
		end
		if near then
			self.tgt = nil
			stop()
			self.object:set_yaw(yaw_to(pos, near))
			return
		end
		if self.tgt then
			local dx, dz = self.tgt.x - pos.x, self.tgt.z - pos.z
			local dt = math.sqrt(dx * dx + dz * dz)
			if dt < 0.7 then
				self.tgt, self.best, self.stuck = nil, nil, 0
				stop()
			else
				if not self.best or dt < self.best - 0.2 then self.best, self.stuck = dt, 0
				else self.stuck = (self.stuck or 0) + dtime end
				self.object:set_velocity({x = dx / dt * 1.2, y = vel.y, z = dz / dt * 1.2})
				self.object:set_yaw(yaw_to(pos, self.tgt))
				anim("walk")
			end
			return
		end
		-- 沒事：偶爾在家附近走兩步，或敲敲石頭
		self.idle = (self.idle or 5) - dtime
		if self.idle <= 0 then
			self.idle = math.random(6, 14)
			local r = math.random()
			if r < 0.4 then self.tgt = spot_near(h, 0, ROAM)
			elseif r < 0.65 then self.work = 3
			else self.object:set_yaw(math.random() * 2 * math.pi) end
		end
		if self.work and self.work > 0 then
			self.work = self.work - dtime
			stop("work")
		else
			stop()
		end
	end,
	on_rightclick = function(self, clicker)
		if not (clicker and clicker:is_player()) then return end
		if rockmech.hand_first and rockmech.hand_first(clicker) then return end
		rockmech.npc_say(self.object, clicker, translate(clicker, hint_for(clicker)))
	end,
	on_punch = function() return true end,
})

-- 玩家在營地附近才放他出來，走遠了收掉；第一次走近打招呼
local t = 0
core.register_globalstep(function(dtime)
	t = t + dtime
	if t < 1 then return end
	t = 0
	local h = home()
	local near
	for _, p in ipairs(core.get_connected_players()) do
		local d = vector.distance(p:get_pos(), h)
		if d < FAR_DROP then near = math.min(near or d, d) end
	end
	local alive = mentor and mentor:get_pos()
	if alive and not near then mentor:remove(); mentor = nil; return end
	if not alive and near and near < NEAR_SPAWN then
		local s = spot_near(h, 0, 2)
		if s then mentor = core.add_entity(s, NPC) end
		return
	end
	if not alive then return end
	for _, p in ipairs(core.get_connected_players()) do
		local m = p:get_meta()
		if m:get_int(GREETED) == 0 and vector.distance(p:get_pos(), mentor:get_pos()) < 7 then
			m:set_int(GREETED, 1)
			rockmech.npc_say(mentor, p, translate(p, GREETING))
		end
	end
end)
