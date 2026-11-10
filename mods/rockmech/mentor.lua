-- rockmech/mentor.lua
-- 老礦工：單機經營模式第一次進世界，他就在玩家附近晃（不跟著，走遠了才慢慢過來，太遠就換到附近）。
-- 他用聊天的口氣給小任務當教學，不下指令；看玩家做到了什麼才換話題（已經自己做到的就誇一句跳過），
-- 一個話題拖太久（PATIENCE 秒）他就算了換下一個。話題講完就說要去休息，之後不再出現。
-- 只在單機的經營模式（rockmech_solo 或單人遊戲，不是教學地圖）；世界設定 rockmech_mentor = false 可以關掉。
-- 進度存在玩家 meta（rockmech:mentor）。

local cfg = rockmech.cfg
if not cfg.career or cfg.teacher or not (cfg.solo or core.is_singleplayer()) then return end
if not cfg.mentor then return end
local S = rockmech.S
local storage = rockmech.collapse.storage

local NPC = "rockmech:npc_mentor"
local KEY = "rockmech:mentor"
local WHO = "mentor"
local TALK_R = 9          -- 玩家在幾公尺內才講話
local NEAR, FAR = 5, 30   -- 超過 NEAR 走過來，超過 FAR（或卡住）直接換到玩家附近
local HINT_T = 150        -- 沒做到，隔多久再提一次（秒）
local PATIENCE = 1200     -- 一個話題最多等多久（秒，玩家在線上的時間）
local GAP = 7             -- 兩句話之間至少隔幾秒（泡泡要看得完）

local function acc_of(name) return rockmech.account_of and rockmech.account_of(name) or name end
local function holding_ore(player)
	local c = rockmech.carry_get and rockmech.carry_get(player)
	return c and c.base and rockmech.ore_of_rubble and rockmech.ore_of_rubble[c.base] ~= nil and (c.p2 or 0) > 40
end
local function sold(name) return storage:get_float("strip_o:" .. acc_of(name)) > 0 end

-- 話題：intro 開場、hints 輪流提醒、done 做到了；check(player, name, near) → 做到了沒
local TOPICS = {
	{
		intro = S("See that black streak on the hill? Knock a piece off and show me."),
		hints = {S("The black one. If it won't break, you're hitting the wrong rock.")},
		done = S("Coal, sure enough. How much ash is in it? Only the scale at the coal yard knows."),
		check = function(player, name, near) return (near and holding_ore(player)) or sold(name) end,
	},
	{
		hints = {S("That noisy machine by the camp. Coal it pays for; rock it charges you for.")},
		done = S("Money in your pocket. That's how everyone starts."),
		check = function(_, name) return sold(name) end,
	},
	{
		intro = S("Carrying it by hand? You'll be hauling until you retire."),
		hints = {S("Even in my day we had wheels.")},
		done = S("Now you're working smart."),
		check = function(_, name)
			local V = rockmech.vehicles
			return V and V.count_owned and V.count_owned(acc_of(name), "") > 0
		end,
	},
	{
		intro = S("Look at the cracks in that rock face. You'd stand under that?"),
		hints = {S("Rock doesn't warn you twice. We used to prop it up with timber.")},
		done = S("Good. Respect the rock and it lets you go home."),
		check = function(player)
			local p = vector.round(player:get_pos())
			local r = vector.new(12, 6, 12)
			return #core.find_nodes_in_area(vector.subtract(p, r), vector.add(p, r),
				{"rockmech:timber_post", "rockmech:timber_post_top"}) > 0
		end,
	},
	{
		intro = S("In my day, one drill hole told us how thick the coal ran down below."),
		hints = {S("Digging blind costs more than drilling.")},
		done = S("Read that core carefully. The rock tells you everything."),
		check = function(_, name)
			local t = core.deserialize(storage:get_string("bh:" .. acc_of(name)))
			return type(t) == "table" and #t > 0
		end,
	},
}
local GREETING = S("Hey, kid. New here? I worked these hills for forty years.")
local SKIP = S("Oh, you've already figured that out.")
local GIVE_UP = S("Never mind. You'll learn it someday.")
local RETIRE = S("Alright, you'll do fine. I'm old, I'm going to go rest.")
local CHATTER = {
	S("My lungs aren't what they used to be."),
	S("Coal dust and sweet potato porridge. That was our life."),
	S("The mountain feeds you, and the mountain takes you back."),
	S("Listen to the rock. When it creaks, run."),
}

local function get_state(player)
	local t = core.deserialize(player:get_meta():get_string(KEY))
	return type(t) == "table" and t or {i = 0, said = false, wait = 0}
end
local function put_state(player, st) player:get_meta():set_string(KEY, core.serialize(st)) end

local function translate(player, str)
	local info = core.get_player_information(player:get_player_name())
	return core.get_translated_string(info and info.lang_code ~= "" and info.lang_code or "zh_TW", str)
end

---------------------------------------------------------------------------
-- 走動
---------------------------------------------------------------------------

local mentors = {}      -- 玩家名 → 物件
local last_say = {}     -- 玩家名 → 上次講話的時間

local function walkable(pos)
	local def = core.registered_nodes[core.get_node(pos).name]
	return def and def.walkable
end
local function clear(pos)
	local def = core.registered_nodes[core.get_node(pos).name]
	return def and not def.walkable and (def.liquidtype or "none") == "none"
end
-- 玩家附近站得住的地方（腳下是實心、上面兩格空）
local function spot_near(pos, rmin, rmax)
	local p0 = vector.round(pos)
	for _ = 1, 24 do
		local a = math.random() * 2 * math.pi
		local r = rmin + math.random() * (rmax - rmin)
		local x, z = math.floor(p0.x + math.cos(a) * r + 0.5), math.floor(p0.z + math.sin(a) * r + 0.5)
		for dy = 3, -4, -1 do
			local f = {x = x, y = p0.y + dy - 1, z = z}
			local feet, head = {x = x, y = f.y + 1, z = z}, {x = x, y = f.y + 2, z = z}
			if walkable(f) and clear(feet) and clear(head) then return {x = x, y = feet.y, z = z} end
		end
	end
end

local function yaw_to(from, to) return (math.atan2 or math.atan)(-(to.x - from.x), to.z - from.z) end

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
		local name = self.who
		local player = name and core.get_player_by_name(name)
		if not player or mentors[name] ~= self.object then self.object:remove(); return end
		local pos, pp = self.object:get_pos(), player:get_pos()
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
		-- 要走了：往遠處走，看不到就消失
		if self.leaving then
			self.leaving = self.leaving - dtime
			if self.leaving <= 0 then self.object:remove(); mentors[name] = nil; return end
			local dx, dz = pos.x - pp.x, pos.z - pp.z
			local d = math.max(0.1, math.sqrt(dx * dx + dz * dz))
			self.object:set_velocity({x = dx / d * 1.4, y = vel.y, z = dz / d * 1.4})
			self.object:set_yaw(yaw_to(pp, pos))
			anim("walk")
			return
		end
		local d = vector.distance(pos, pp)
		-- 太遠、掉下去、卡住：換到玩家附近（玩家在車上跑遠了也是）
		if d > FAR or (self.stuck or 0) > 6 or pos.y < pp.y - 8 then
			local s = spot_near(pp, 4, 7)
			if s then self.object:set_pos(s) end
			self.stuck, self.best, self.tgt = 0, nil, nil
			return
		end
		if self.tgt then
			local dx, dz = self.tgt.x - pos.x, self.tgt.z - pos.z
			local dt = math.sqrt(dx * dx + dz * dz)
			if dt < 0.7 or vector.distance(self.tgt, pp) < 2.5 then
				self.tgt, self.best, self.stuck = nil, nil, 0
				stop()
			else
				if not self.best or dt < self.best - 0.2 then self.best, self.stuck = dt, 0
				else self.stuck = (self.stuck or 0) + dtime end
				local v = d > 12 and 3 or 1.5
				self.object:set_velocity({x = dx / dt * v, y = vel.y, z = dz / dt * v})
				self.object:set_yaw(yaw_to(pos, self.tgt))
				anim("walk")
			end
			return
		end
		if d > NEAR + 3 then
			-- 走到玩家旁邊 3 m 左右
			local k = (d - 3) / d
			self.tgt = {x = pos.x + (pp.x - pos.x) * k, y = pp.y, z = pos.z + (pp.z - pos.z) * k}
			return
		end
		-- 在旁邊：看著玩家，偶爾自己晃一下或敲敲石頭
		self.idle = (self.idle or 5) - dtime
		if d < 4 then self.object:set_yaw(yaw_to(pos, pp)) end
		if self.idle <= 0 then
			self.idle = math.random(6, 14)
			local r = math.random()
			if r < 0.35 then
				local s = spot_near(pos, 1.5, 3.5)
				if s and vector.distance(s, pp) > 2.5 then self.tgt = s end
			elseif r < 0.55 then
				self.work = 3
			end
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
		local st = get_state(clicker)
		local T = TOPICS[st.i]
		local str = (T and st.said and math.random() < 0.7) and T.hints[math.random(#T.hints)] or CHATTER[math.random(#CHATTER)]
		rockmech.npc_say(self.object, clicker, translate(clicker, str))
	end,
	on_punch = function() return true end,
})

---------------------------------------------------------------------------
-- 話題進度
---------------------------------------------------------------------------

local function say(player, str)
	local o = mentors[player:get_player_name()]
	if not (o and o:get_pos()) then return false end
	rockmech.npc_say(o, player, translate(player, str))
	last_say[player:get_player_name()] = core.get_us_time() / 1e6
	return true
end

local function ensure(player, st)
	local name = player:get_player_name()
	local o = mentors[name]
	if o and o:get_pos() then return o end
	local s = spot_near(player:get_pos(), 3, 6)
	if not s then return end
	o = core.add_entity(s, NPC)
	local e = o and o:get_luaentity()
	if not e then return end
	e.who = name
	mentors[name] = o
	return o
end

local function tick(player, dt)
	local name = player:get_player_name()
	local st = get_state(player)
	if st.retired then return end
	local o = ensure(player, st)
	if not o then return end
	local e = o:get_luaentity()
	if e and e.leaving then return end
	local now = core.get_us_time() / 1e6
	local near = vector.distance(o:get_pos(), player:get_pos()) < TALK_R
	if not near or now - (last_say[name] or 0) < GAP then
		if st.said then st.wait = (st.wait or 0) + dt; put_state(player, st) end
		return
	end
	if st.i == 0 then
		say(player, GREETING)
		st.i, st.said, st.wait = 1, false, 0
		put_state(player, st)
		return
	end
	local T = TOPICS[st.i]
	if not T then
		say(player, RETIRE)
		st.retired = true
		put_state(player, st)
		if e then e.leaving = 12 end
		return
	end
	if T.check(player, name, near) then
		-- 接著上一句的話題（沒有開場白）已經做到了：不用多講
		if st.said or T.intro then say(player, st.said and T.done or SKIP) end
		st.i, st.said, st.wait, st.next = st.i + 1, false, 0, nil
	elseif not st.said then
		-- 沒有開場白的話題（接著上一句講的）直接進入等待，過一陣子才提醒
		if T.intro then say(player, T.intro) end
		st.said, st.wait, st.next, st.h = true, 0, now + (T.intro and HINT_T or 60), 0
	elseif (st.wait or 0) > PATIENCE then
		say(player, GIVE_UP)
		st.i, st.said, st.wait, st.next = st.i + 1, false, 0, nil
	else
		st.wait = (st.wait or 0) + dt
		if now >= (st.next or 0) then
			st.h = (st.h or 0) % #T.hints + 1
			say(player, T.hints[st.h])
			st.next = now + HINT_T
		end
	end
	put_state(player, st)
end

local acc = 0
core.register_globalstep(function(dtime)
	acc = acc + dtime
	if acc < 1 then return end
	local dt = acc
	acc = 0
	for _, player in ipairs(core.get_connected_players()) do tick(player, dt) end
end)

core.register_on_leaveplayer(function(player)
	local name = player:get_player_name()
	local o = mentors[name]
	if o and o:get_pos() then o:remove() end
	mentors[name], last_say[name] = nil, nil
end)

-- 重來一次（除錯）：/rockmech_mentor_reset
core.register_chatcommand("rockmech_mentor_reset", {
	description = S("Old miner starts over"), privs = {server = true},
	func = function(name)
		local p = core.get_player_by_name(name)
		if not p then return false end
		p:get_meta():set_string(KEY, "")
		return true, S("Old miner starts over")
	end,
})
