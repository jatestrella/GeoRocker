-- rockmech/nametag.lua
-- 頭上的名牌：學生互相看到「暱稱」，老師（有 server 權限的人）看到「暱稱(真名)」。
-- 內建名牌所有人看到的字都一樣，所以把它藏起來，改成每個玩家身上掛兩個看不見的小物件，各帶一個名牌，
-- 用 set_observers 分開：學生版只送給學生、老師版只送給老師（自己都不送）。有人上下線、權限改變時重算。
--   暱稱：玩家在背包「個人資料」頁自己設定（最多 NICK_MAX 個字、不能跟別人重複），沒設定時用帳號（學號）。
--   真名：名單 students.csv 第 4 欄（team.lua 讀進 rockmech.real_names）。
--   無人機飛行時名牌一起藏（drone.lua 呼叫 rockmech.nametag_hide）。

local storage = core.get_mod_storage()
local S = rockmech.S
local NICK = "nick:"
local NICK_MAX = 12
local TAG = "rockmech:nametag"

rockmech.real_names = rockmech.real_names or {}

local function is_teacher(name) return core.check_player_privs(name, {server = true}) end

local function nick_of(name)
	local n = storage:get_string(NICK .. name)
	return n ~= "" and n or name
end
rockmech.nick_of = nick_of

local function teacher_text(name)
	local real = rockmech.real_names[name]
	return real and (nick_of(name) .. "(" .. real .. ")") or nick_of(name)
end

---------------------------------------------------------------------------
-- 名牌物件
---------------------------------------------------------------------------

core.register_entity(TAG, {
	initial_properties = {
		visual = "sprite", textures = {"blank.png"}, visual_size = {x = 0.01, y = 0.01},
		-- 名牌畫在選取框頂端再上去一點：選取框跟玩家一樣高（物件掛在玩家腳底）
		selectionbox = {-0.01, 0, -0.01, 0.01, 1.8, 0.01}, collisionbox = {0, 0, 0, 0, 0, 0},
		physical = false, pointable = false, static_save = false,
		nametag = "", nametag_color = "#ffffff", nametag_bgcolor = "#00000060",
	},
	on_step = function(self)
		-- 主人下線或物件掉了：自己消失（on_leaveplayer 也會清）
		local parent = self.object:get_attach()
		if not parent or not parent:is_player() then self.object:remove() end
	end,
})

local tags = {}        -- 玩家名稱 → {student = obj, teacher = obj}
local hidden = {}      -- 玩家名稱 → true（無人機飛行中）

local function alive(o) return o and o:get_pos() ~= nil end

-- 依目前在線的人重算每個名牌給誰看
local function update_observers()
	local students, teachers = {}, {}
	for _, p in ipairs(core.get_connected_players()) do
		local n = p:get_player_name()
		if is_teacher(n) then teachers[n] = true else students[n] = true end
	end
	for name, t in pairs(tags) do
		local s, te = table.copy(students), table.copy(teachers)
		s[name], te[name] = nil, nil        -- 自己頭上的名牌自己不用看
		if hidden[name] then s, te = {}, {} end
		if alive(t.student) then t.student:set_observers(s) end
		if alive(t.teacher) then t.teacher:set_observers(te) end
	end
end

local function make(player, text)
	local o = core.add_entity(player:get_pos(), TAG)
	if not o then return nil end
	o:set_observers({})           -- 先誰都不給看，等 update_observers 分
	o:set_properties({nametag = text})
	o:set_attach(player, "", {x = 0, y = 0, z = 0}, {x = 0, y = 0, z = 0})
	return o
end

-- 建好（或更新文字）一個玩家的兩個名牌
local function refresh(name)
	local player = core.get_player_by_name(name)
	if not player then return end
	-- 藏內建名牌（無人機飛行中由 drone.lua 自己管，回來時還原成這個）
	player:set_nametag_attributes({text = " ", color = {a = 0, r = 255, g = 255, b = 255}, bgcolor = {a = 0, r = 0, g = 0, b = 0}})
	local t = tags[name] or {}
	tags[name] = t
	local st, tt = nick_of(name), teacher_text(name)
	if alive(t.student) then t.student:set_properties({nametag = st}) else t.student = make(player, st) end
	if alive(t.teacher) then t.teacher:set_properties({nametag = tt}) else t.teacher = make(player, tt) end
end

local function refresh_all()
	for _, p in ipairs(core.get_connected_players()) do refresh(p:get_player_name()) end
	update_observers()
end
rockmech.nametag_refresh_all = refresh_all

function rockmech.nametag_hide(name, on)
	hidden[name] = on or nil
	update_observers()
end

core.register_on_joinplayer(function(player)
	local name = player:get_player_name()
	core.after(0.5, function()
		if not core.get_player_by_name(name) then return end
		refresh(name)
		update_observers()
	end)
	if storage:get_string(NICK .. name) == "" and not is_teacher(name) then
		core.after(4, function()
			rockmech.notify(name, S("[Name tag] You have not set a nickname, so classmates see your account name. Press I → \"Profile\" to set a nickname"))
		end)
	end
end)

core.register_on_leaveplayer(function(player)
	local name = player:get_player_name()
	local t = tags[name]
	if t then
		if alive(t.student) then t.student:remove() end
		if alive(t.teacher) then t.teacher:remove() end
	end
	tags[name], hidden[name] = nil, nil
	core.after(0, update_observers)
end)

-- 有人被給或拿掉 server 權限：換看的名牌
core.register_on_priv_grant(function(name, _, priv) if priv == "server" then core.after(0, update_observers) end end)
core.register_on_priv_revoke(function(name, _, priv) if priv == "server" then core.after(0, update_observers) end end)

-- 名牌物件偶爾會掉（玩家重生、被傳送到沒載入的地方…）：每 5 秒補一次
local acc = 0
core.register_globalstep(function(dtime)
	acc = acc + dtime
	if acc < 5 then return end
	acc = 0
	local fix = false
	for _, p in ipairs(core.get_connected_players()) do
		local t = tags[p:get_player_name()]
		if not t or not alive(t.student) or not alive(t.teacher) then
			refresh(p:get_player_name())
			fix = true
		end
	end
	if fix then update_observers() end
end)

---------------------------------------------------------------------------
-- 設定暱稱（個人資料頁）
---------------------------------------------------------------------------

local function ulen(s) return select(2, s:gsub("[^\128-\191]", "")) end

-- 回傳 nil = 成功，否則是錯誤訊息
function rockmech.set_nick(name, nick)
	nick = (nick or ""):gsub("[%c]", ""):match("^%s*(.-)%s*$")
	if nick == "" or nick == name then
		storage:set_string(NICK .. name, "")
	else
		if ulen(nick) > NICK_MAX then return S("A nickname can have at most @1 characters", tostring(NICK_MAX)) end
		if nick:find("[()（）]") then return S("A nickname cannot contain parentheses") end
		local low = nick:lower()
		for _, k in ipairs(storage:get_keys()) do
			local other = k:match("^" .. NICK .. "(.+)$")
			if other and other ~= name and storage:get_string(k):lower() == low then return S("This nickname is already taken") end
		end
		if core.player_exists(nick) and nick ~= name then return S("A nickname cannot be someone else's account name") end
		storage:set_string(NICK .. name, nick)
	end
	core.log("action", ("[rockmech] %s 的暱稱改成「%s」"):format(name, nick_of(name)))
	refresh(name)
	update_observers()
	return nil
end

-- 個人資料頁用的一段 formspec（sfinv 舊座標），y = 起始高度
function rockmech.nick_formspec(name, y)
	local F = core.formspec_escape
	local fs = {
		("label[0,%g;%s]"):format(y, F(S("Nickname (the name classmates see above your head, at most @1 characters; blank = use your account name)", tostring(NICK_MAX)))),
		("field[0.3,%g;4.5,0.8;rm_nick;;%s]"):format(y + 0.8, F(storage:get_string(NICK .. name))),
		("field_close_on_enter[rm_nick;false]"),
		("button[4.6,%g;1.8,0.8;rm_nick_set;%s]"):format(y + 0.45, F(S("Set nickname"))),
	}
	return table.concat(fs)
end

local nick_msg = {}    -- 玩家名稱 → 上次設定的結果（顯示在頁面上）
function rockmech.nick_message(name) return nick_msg[name] end

core.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= "" or not (fields.rm_nick_set or (fields.key_enter_field == "rm_nick")) then return end
	local name = player:get_player_name()
	local err = rockmech.set_nick(name, fields.rm_nick)
	nick_msg[name] = err or S("Set: classmates see \"@1\"", nick_of(name))
	if sfinv and sfinv.set_player_inventory_formspec then sfinv.set_player_inventory_formspec(player) end
	return true
end)

---------------------------------------------------------------------------
-- NPC 的名牌（攤主、技工、地質師、教授、怪手操作員…）：只給 NPC_NEAR 公尺內的人看。
-- 內建名牌所有人都看得到、多遠都看得到，所以 NPC 自己的名牌清空，改由一個掛在腳底、看不見的小物件帶名牌，
-- 用 set_observers 只送給附近的玩家。NPC 自己改名牌（set_properties nametag）也沒關係：每 0.5 秒把它搬過來。
-- NPC：有名牌、外觀是人物模型（character.b3d）的 rockmech 實體
---------------------------------------------------------------------------
local NPC_TAG = "rockmech:npc_tag"
local NPC_NEAR = 10
core.register_entity(NPC_TAG, {
	initial_properties = {
		visual = "sprite", textures = {"blank.png"}, visual_size = {x = 0.01, y = 0.01},
		selectionbox = {-0.01, 0, -0.01, 0.01, 1.8, 0.01}, collisionbox = {0, 0, 0, 0, 0, 0},
		physical = false, pointable = false, static_save = false,
		nametag = "", nametag_color = "#ffffff", nametag_bgcolor = "#00000060",
	},
	on_step = function(self)
		if not self.object:get_attach() then self.object:remove() end
	end,
})
local npc_names = {}
core.register_on_mods_loaded(function()
	for name, def in pairs(core.registered_entities) do
		local ip = def.initial_properties or {}
		if name:find("^rockmech:") and ip.nametag ~= nil and ip.mesh == "character.b3d" then npc_names[name] = true end
	end
end)
local npc_tags = {}      -- NPC 物件 → 名牌物件
local npc_t = 0
core.register_globalstep(function(dtime)
	npc_t = npc_t + dtime
	if npc_t < 0.5 then return end
	npc_t = 0
	local players = core.get_connected_players()
	for _, e in pairs(core.luaentities) do
		if npc_names[e.name] then
			local o = e.object
			local p = o:get_pos()
			if p then
				local props = o:get_properties()
				local tag = npc_tags[o]
				if props.nametag ~= "" then
					if not (tag and tag:get_pos()) then
						tag = core.add_entity(p, NPC_TAG)
						if tag then tag:set_attach(o, "", {x = 0, y = 0, z = 0}, {x = 0, y = 0, z = 0}) end
						npc_tags[o] = tag
					end
					if tag then tag:set_properties({nametag = props.nametag, nametag_color = props.nametag_color}) end
					o:set_properties({nametag = ""})
				end
				if tag and tag:get_pos() then
					local near = {}
					for _, pl in ipairs(players) do
						if vector.distance(pl:get_pos(), p) <= NPC_NEAR then near[pl:get_player_name()] = true end
					end
					tag:set_observers(near)
				end
			end
		end
	end
	for o, tag in pairs(npc_tags) do
		if not o:get_pos() then
			if tag and tag:get_pos() then tag:remove() end
			npc_tags[o] = nil
		end
	end
end)
-- NPC 改名牌用這個：已經有名牌物件就直接改它（不要先出現在 NPC 身上讓遠處的人看到一下）
function rockmech.npc_set_tag(o, text)
	local tag = npc_tags[o]
	if tag and tag:get_pos() then tag:set_properties({nametag = text}) else o:set_properties({nametag = text}) end
end
