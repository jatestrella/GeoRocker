-- rockmech/team.lua
-- 經營模式的全班伺服器：分組共用資金、各組各自的營地、預先建好的帳號。
--   分組：每組一個帳戶 "team:<組>"（crusher.lua 的 rockmech.account_of），組員買東西、破碎站入帳都用這筆錢。
--   組別是數字 1..rockmech_career_teams（跟成績單的組別一樣）。
--   營地：第 i 組各有一條礦帶，沿 x 排開：第 1 組在第 −1 帶、第 2 組在 +1、第 3 組在 −2、第 4 組在 +2 …（第 0 帶是出生點，
--     給老師示範）。設了 rockmech_coal_seam_lanes 時，每帶有一條一模一樣的煤層，帶寬就是營地間距；
--     沒設就用 rockmech_career_site_spacing。每座營地跟出生點的一樣：帳篷和供應商、一座掛在組上的破碎站。
--     組第一次有人分進來時才發起始資金（rockmech_career_start）、蓋營地。
--   名單：世界資料夾裡的 students.csv（rockmech_career_roster），一行一位：帳號,密碼,組別[,真名]（真名只顯示在老師看到的名牌上，見 nametag.lua）
--     伺服器啟動時，還沒有的帳號用那個密碼建好；有寫組別就分進去（以名單為準）。
--     有名單時，名單外的名稱不能登入（rockmech_career_roster_only）。密碼學生自己在 Esc 選單「變更密碼」改。
--   道具：「回營地」旗子（每人一支，登入時沒有就補），左鍵或右鍵回自己組的營地（沒分組回出生點）。
--   學生沒有「我的組」分頁：資金在畫面右上角，回營地用旗子，參觀別組就走過去。
--   老師：背包（I）的「老師」分頁：各組資金、加扣錢、重讀名單、加入某組試玩、傳送到各組營地。
--   指令（備用）：/team、/team list、/team set <帳號> <組|none>、/team money <組> <金額>、/team reload、/site [組]

local cfg = rockmech.cfg
if not cfg.career then return end
local S = rockmech.S

local storage = rockmech.collapse.storage
local TEAM_OF, SITE, TP = "team_of:", "team_site:", "team_tp:"
local TEACHER = "server"     -- 老師指令要的權限（開伺服器的人自動有）

local function team_index(t)
	local i = tonumber(t)
	return i and i == math.floor(i) and i >= 0 and i <= cfg.career_teams and i or nil      -- 0 是老師組（出生點的營地）
end
local function team_name(i) return tostring(i) end
-- 名單、指令裡寫的組別（"3"、"3.0"、" 3 "）→ 正規的組名 "3"；不是組別就原樣回傳
local function norm(t)
	local i = team_index(t)
	return i and team_name(i) or t
end
local function all_teams()
	local out = {}
	out[1] = "0"
	for i = 1, cfg.career_teams do out[i + 1] = team_name(i) end
	return out
end

-- 第 i 組營地（礦帶中心）的 x：第 1 組 −1、2 組 +1、3 組 −2、4 組 +2 … 帶，出生點的營地（x = 0）留給老師示範
local SPACING = cfg.coal_seam and cfg.coal_seam.lane_w or cfg.career_site_spacing
local function site_x(t)
	local i = team_index(t)
	local k = math.ceil(i / 2)
	return (i % 2 == 1 and -k or k) * SPACING + cfg.career_camp_dx     -- 營地在礦帶中心往東 camp_dx
end
rockmech.team_site_x = site_x

-- pos 在第幾組的礦帶（第 k 帶：x 在 k·SPACING ± SPACING/2；第 0 帶是出生點、老師組）；不在任何一組的帶裡回傳 nil
function rockmech.lane_team(pos)
	local k = math.floor((pos.x + SPACING / 2) / SPACING)
	local i = k < 0 and (-2 * k - 1) or 2 * k
	return i <= cfg.career_teams and tostring(i) or nil
end
-- 在別組的礦帶裝炸藥無效（炸不到別組的礦區、車、設施）：回傳那一組（不能裝），nil = 可以。老師（/god、rockmech 權限）不受限制
function rockmech.blast_forbidden(player, pos)
	if not (player and player.is_player and player:is_player()) then return nil end
	local name = player:get_player_name()
	if player:get_meta():get_int("godmode:on") == 1 or core.check_player_privs(name, {rockmech = true}) then return nil end
	local lane = rockmech.lane_team(pos)
	if not lane then return nil end
	local mine = rockmech.team_of and rockmech.team_of(name)
	if mine and tostring(mine) == lane then return nil end
	return lane
end
local function sx(t) return ("%d"):format(site_x(t)) end      -- 營地 x 的文字（訊息用）

---------------------------------------------------------------------------
-- 組的營地與資金
---------------------------------------------------------------------------

local building = {}
local function ensure_team(t)
	local acc = "team:" .. t
	if not rockmech.has_account(acc) then
		rockmech.add_money(acc, cfg.career_start)
		core.log("action", ("[rockmech] team %s opened with $%.0f"):format(t, cfg.career_start))
	end
	if storage:get_string(SITE .. t) ~= "" or building[t] then return end
	-- 老師組（第 0 組）用出生點的營地：已經蓋好就不再蓋，還沒蓋就由這裡蓋（不讓 career.lua 另外蓋一座給第一個進來的人）
	if t == "0" then
		if storage:get_string("career_site") ~= "" then storage:set_string(SITE .. t, "1"); return end
		storage:set_string("career_site", "2")
	end
	building[t] = true
	rockmech.career_build_camp(acc, site_x(t), function()
		storage:set_string(SITE .. t, "1")
		building[t] = nil
		core.log("action", ("[rockmech] camp of team %s built at x = %d"):format(t, site_x(t)))
	end)
end

-- 把玩家送到 x0 那座營地（地圖先生成好，才知道地面多高）
local function send_to(name, x0)
	core.emerge_area({x = x0 - 2, y = -30, z = -2}, {x = x0 + 2, y = 40, z = 2}, function(_, _, rem)
		if rem > 0 then return end
		local p = core.get_player_by_name(name)
		if p then
			if p:get_attach() then p:set_detach() end
			p:set_pos(rockmech.career_spawn(x0))
			p:set_look_horizontal(math.pi / 2)     -- 臉朝西：礦區（煤層露頭）在營地西邊
		end
	end)
end
-- 回自己組的營地
local function send_home(name, t) send_to(name, site_x(t)) end

-- 單機版（rockmech_solo）：引擎在單機時會給玩家幾乎所有權限（含 server，等於老師），這裡只留基本的
local SOLO_PRIVS = {interact = true, shout = true}
if cfg.solo then
	core.register_on_mods_loaded(function()
		if not core.is_singleplayer() then return end
		for priv, def in pairs(core.registered_privileges) do
			if not SOLO_PRIVS[priv] then def.give_to_singleplayer = false end
		end
	end)
end
if cfg.solo then
	core.register_on_joinplayer(function(player)
		local n = player:get_player_name()
		core.log("action", ("[rockmech] solo: %s privs = %s"):format(n, core.privs_to_string(core.get_player_privs(n))))
	end)
end

---------------------------------------------------------------------------
-- 「回營地」旗子：拿著按左鍵或右鍵就回營地（教學地圖每人發一支，其他地圖向工具室管理員買）
---------------------------------------------------------------------------

local FLAG = "rockmech:camp_flag"
local function go_camp(itemstack, user)
	if not (user and user:is_player()) then return itemstack end
	local name = user:get_player_name()
	local t = rockmech.team_of(name)
	if t then
		send_home(name, t)
		core.chat_send_player(name, S("[Back to camp] Camp of team @1", t))
	else
		send_to(name, cfg.career_camp_dx)
		core.chat_send_player(name, S("[Back to camp] Spawn"))
	end
	return itemstack
end
core.register_craftitem(FLAG, {
	description = S("Back to camp\nClick to go back to your team's camp"),
	short_description = S("Back to camp"),
	inventory_image = "[fill:16x16:#00000000^[fill:2x15:3,1:#6a4a28^[fill:9x6:5,1:#c04030^[fill:9x2:5,3:#f0e0b0",
	stack_max = 1,
	groups = {not_in_creative_inventory = 1},
	on_use = go_camp,
	on_secondary_use = go_camp,
	on_place = go_camp,
	on_drop = function(itemstack) return itemstack end,     -- 丟不掉
})
-- 教學地圖每人登入時沒有就補一支；其他地圖不發，要的話向工具室管理員買
if cfg.teacher then
	core.register_on_joinplayer(function(player)
		local inv = player:get_inventory()
		if not inv:contains_item("main", FLAG) then inv:add_item("main", FLAG) end
	end)
end

-- 不是教學地圖（單機、自訂、隨機地圖）：沒有分組、名單、老師示範區、別組礦帶不能炸、老師分頁和指令
if not cfg.teacher then
	function rockmech.lane_team() return nil end
	function rockmech.blast_forbidden() return nil end
	return
end

-- 分組（t = nil 取消分組）。在線上就馬上送到營地，否則下次登入時送
local function set_team(name, t)
	if t then
		storage:set_string(TEAM_OF .. name, t)
		ensure_team(t)
	else
		storage:set_string(TEAM_OF .. name, "")
	end
	local player = core.get_player_by_name(name)
	if player then
		rockmech.show_money(player)
		if t then
			core.chat_send_player(name, S("[Teams] You are in team @1. The whole team shares one fund; your camp is at x = @2 (hold the \"Back to camp\" flag and left-click to return to camp)", t, sx(t)))
			send_home(name, t)
		else
			core.chat_send_player(name, S("[Teams] You are no longer in any team"))
		end
	elseif t then
		storage:set_string(TP .. name, "1")
	end
end
rockmech.set_team = set_team

local function members_of(t)
	local out = {}
	for _, k in ipairs(storage:get_keys()) do
		local name = k:match("^" .. TEAM_OF .. "(.+)$")
		if name and storage:get_string(k) == t then out[#out + 1] = name end
	end
	table.sort(out)
	return out
end

core.register_on_joinplayer(function(player)
	local name = player:get_player_name()
	local t = rockmech.team_of(name)
	if t then
		ensure_team(t)      -- 組數設定改過、或營地還沒蓋完伺服器就關了
		if storage:get_string(TP .. name) ~= "" then
			storage:set_string(TP .. name, "")
			core.after(0.5, function()
				core.chat_send_player(name, S("[Teams] Welcome! You are in team @1; the whole team shares one fund. The funds are shown at the top right of the screen; hold the \"Back to camp\" flag and left-click to return to camp", t))
				send_home(name, t)
			end)
		end
	elseif not core.is_singleplayer() and not rockmech.has_account(name) then
		core.after(1, function()
			core.chat_send_player(name, S("[Teams] You are not in a team yet, so you cannot buy equipment. Please ask the teacher to assign you to a team"))
		end)
	end
end)

core.register_on_respawnplayer(function(player)
	local t = rockmech.team_of(player:get_player_name())
	if not t then return false end
	send_home(player:get_player_name(), t)
	return true
end)

---------------------------------------------------------------------------
-- 名單：建帳號、分組
---------------------------------------------------------------------------

local roster_path = core.get_worldpath() .. "/" .. cfg.career_roster
local roster_file = io.open(roster_path, "r")
local has_roster = roster_file ~= nil
if roster_file then roster_file:close() end

local function trim(s) return (s or ""):match("^%s*(.-)%s*$") end

rockmech.real_names = rockmech.real_names or {}       -- 帳號 → 真名（名單第 4 欄）
local function load_roster()
	local f = io.open(roster_path, "r")
	if not f then return end
	local auth = core.get_auth_handler()
	local created, moved, bad, badlog = 0, 0, {}, {}       -- bad：給老師看的訊息（翻譯）、badlog：寫進 log
	local n = 0
	for line in f:lines() do
		n = n + 1
		line = line:gsub("^\239\187\191", ""):gsub("\r", "")          -- UTF-8 BOM（Excel 存的）
		if not line:match("^%s*#") and trim(line) ~= "" then
			local fields = {}
			for v in (line .. ","):gmatch("([^,]*),") do fields[#fields + 1] = trim(v) end
			local name, pw, t = fields[1], fields[2] or "", norm(fields[3] or "")
			if name == "帳號" or name:lower() == "name" or name:lower() == "account" then
				-- 標題列（帳號,密碼,組別）
			elseif not name:match("^[%w_%-]+$") or #name > 20 then
				bad[#bad + 1] = S("Line @1: account \"@2\" may only use English letters, digits, - and _, at most 20 characters", tostring(n), name)
				badlog[#badlog + 1] = ("第 %d 行：帳號「%s」只能用英文字母、數字、- 和 _，最多 20 字"):format(n, name)
			else
				rockmech.real_names[name] = fields[4] ~= "" and fields[4] or nil     -- 第 4 欄：真名（名牌只給老師看）
				if not auth.get_auth(name) then
					auth.create_auth(name, pw == "" and "" or core.get_password_hash(name, pw))
					created = created + 1
				end
				if t ~= "" then
					if not team_index(t) then
						bad[#bad + 1] = S("Line @1: team \"@2\" is not between 1 and @3", tostring(n), t, team_name(cfg.career_teams))
						badlog[#badlog + 1] = ("第 %d 行：組別「%s」不在 1–%s 之間"):format(n, t, team_name(cfg.career_teams))
					elseif rockmech.team_of(name) ~= t then
						set_team(name, t)
						moved = moved + 1
					end
				end
			end
		end
	end
	f:close()
	core.log("action", ("[rockmech] roster %s: %d accounts created, %d team changes"):format(cfg.career_roster, created, moved))
	if rockmech.nametag_refresh_all then rockmech.nametag_refresh_all() end
	for _, b in ipairs(badlog) do core.log("warning", "[rockmech] 名單 " .. b) end
	return created, moved, bad
end

-- 伺服器跑起來第一步就讀名單（auth 資料庫這時可以用）
core.after(0, load_roster)

-- 有名單時，名單外的名稱不能登入（開伺服器的人、單人模式不受限）
core.register_on_prejoinplayer(function(name)
	if not (has_roster and cfg.career_roster_only) or core.is_singleplayer() then return end
	if name == core.settings:get("name") then return end
	if core.get_auth_handler().get_auth(name) then return end
	-- 還沒進遊戲，client 還沒有翻譯檔：中英並列，不用 S()
	return "This server is for our class only: log in with the account your teacher gave you (case-sensitive).\n"
		.. "這個伺服器只開放班上同學：請用老師給的帳號登入（大小寫要一樣）"
end)

---------------------------------------------------------------------------
-- 指令
---------------------------------------------------------------------------

local function money_text(v) return ("%s$%.0f"):format(v < 0 and "−" or "", math.abs(v)) end

local function is_teacher(name) return core.check_player_privs(name, {[TEACHER] = true}) end

core.register_chatcommand("team", {
	params = S("| list | set <account> <team|none> | money <team> <amount> | reload"),
	description = S("Teams: show your own team; the teacher can list the teams, assign teams, adjust funds and reload the roster"),
	func = function(name, param)
		local args = param:split(" ")
		local cmd = args[1]
		if not cmd then
			local t = rockmech.team_of(name)
			if not t then return true, S("You are not in a team yet") end
			return true, S("You are in team @1, funds @2, camp at x = @3. Members: @4", t, money_text(rockmech.money(name)), sx(t),
				table.concat(members_of(t), ", "))
		end
		if not is_teacher(name) then return false, S("This command is for the teacher only (@1 privilege)", TEACHER) end
		if cmd == "list" then
			local lines = {}
			for _, t in ipairs(all_teams()) do
				local m = members_of(t)
				local acc = "team:" .. t
				lines[#lines + 1] = S("Team @1 (x = @2) @3   @4 players: @5", t, sx(t),
					rockmech.has_account(acc) and money_text(rockmech.money(acc)) or S("not opened"),
					tostring(#m), table.concat(m, ", "))
			end
			return true, table.concat(lines, "\n")
		elseif cmd == "set" then
			local who, t = args[2], norm((args[3] or ""):upper())
			if not who or t == "" then return false, S("Usage: /team set <account> <team|none>") end
			if not core.get_auth_handler().get_auth(who) then return false, S("No such account: @1", who) end
			if t == "NONE" then set_team(who, nil); return true, S("@1 is no longer in a team", who) end
			if not team_index(t) then return false, S("The team must be between 1 and @1", team_name(cfg.career_teams)) end
			set_team(who, t)
			return true, S("@1 → team @2", who, t)
		elseif cmd == "money" then
			local t, amount = norm(args[2] or ""), tonumber(args[3] or "")
			if not team_index(t) or not amount then return false, S("Usage: /team money <team> <amount> (negative to deduct)") end
			rockmech.add_money("team:" .. t, amount)
			for _, m in ipairs(rockmech.account_members("team:" .. t)) do
				core.chat_send_player(m, S("[Team @1] The teacher adjusted the funds by @2@3", t, amount >= 0 and "+" or "", money_text(amount)))
			end
			core.log("action", ("[rockmech] %s adjusted team %s money by %g"):format(name, t, amount))
			return true, S("Team @1 funds are now @2", t, money_text(rockmech.money("team:" .. t)))
		elseif cmd == "reload" then
			if not has_roster then
				local f = io.open(roster_path, "r")
				if not f then return false, S("Roster file not found: @1", roster_path) end
				f:close()
				has_roster = true
			end
			local created, moved, bad = load_roster()
			return true, S("Roster: @1 accounts created, @2 players changed teams@3", tostring(created), tostring(moved),
				#bad > 0 and ("\n" .. table.concat(bad, "\n")) or "")
		end
		return false, S("Usage: /team [list | set <account> <team|none> | money <team> <amount> | reload]")
	end,
})

core.register_chatcommand("site", {
	params = S("[team]"),
	description = S("Go back to your team's camp (the teacher can specify a team)"),
	func = function(name, param)
		local t = norm(trim(param))
		if t ~= "" then
			if not is_teacher(name) then return false, S("You can only go back to your own team's camp: /site") end
			if not team_index(t) then return false, S("The team must be between 1 and @1", team_name(cfg.career_teams)) end
		else
			t = rockmech.team_of(name)
			if not t then return false, S("You are not in a team yet") end
		end
		send_home(name, t)
		return true, S("Heading to the camp of team @1 (x = @2)", t, sx(t))
	end,
})

---------------------------------------------------------------------------
-- 背包（I）的「老師」分頁（只有老師看得到）：不用打指令，全部用按鈕
---------------------------------------------------------------------------

if core.get_modpath("sfinv") and sfinv then
	local F = core.formspec_escape
	local PAGE = "rockmech:team"

	-- 老師打開背包先看到這一頁，學生看到一般的背包
	function sfinv.get_homepage_name(player)
		return player and is_teacher(player:get_player_name()) and PAGE or "sfinv:crafting"
	end

	local function refresh(player)
		if sfinv.get_page(player) == PAGE then sfinv.set_player_inventory_formspec(player) end
	end
	-- 資金變了，開著這一頁的人跟著更新
	local add_money = rockmech.add_money
	function rockmech.add_money(name, amount)
		add_money(name, amount)
		for _, p in ipairs(core.get_connected_players()) do refresh(p) end
	end

	-- 名字一行放 per 個
	local function name_lines(names, per)
		local out = {}
		for i = 1, #names, per do
			out[#out + 1] = table.concat(names, ", ", i, math.min(i + per - 1, #names))
		end
		return out
	end

	local function online_marked(t)
		local out = {}
		for _, m in ipairs(members_of(t)) do
			out[#out + 1] = core.get_player_by_name(m) and S("@1 (online)", m) or m
		end
		return out
	end

	sfinv.register_page(PAGE, {
		title = S("Teacher"),
		is_in_nav = function(self, player) return is_teacher(player:get_player_name()) end,
		get = function(self, player, context)
			local name = player:get_player_name()
			local t = rockmech.team_of(name)
			local teacher = is_teacher(name)
			local fs = {}
			local function add(f, ...) fs[#fs + 1] = f:format(...) end
			local y = 0
			if t then
				add("label[0,%g;%s]", y, F(S("Team @1   Funds @2", t, money_text(rockmech.money(name)))))
				y = y + 0.5
				add("label[0,%g;%s]", y, F(S("Members:")))
				for _, line in ipairs(name_lines(online_marked(t), 3)) do
					add("label[0.8,%g;%s]", y, F(line))
					y = y + 0.4
				end
				y = y + 0.3
				add("button[0,%g;4,0.8;rm_home;%s]", y, F(S("Back to team @1's camp", t)))
			else
				add("label[0,%g;%s]", y, F(teacher and S("Teacher (not in a team)") or S("You are not in a team yet; please ask the teacher to assign you to a team")))
				y = y + 0.6
				add("button[0,%g;4,0.8;rm_spawn;%s]", y, F(S("Back to spawn")))
			end
			y = y + 1.1
			add("label[0,%g;%s]", y, F(S("Teleport to the team camps:")))
			y = y + 0.45
			for i = 1, cfg.career_teams do
				local col, row = (i - 1) % 4, math.floor((i - 1) / 4)
				add("button[%g,%g;2,0.8;rm_go_%d;%s]", col * 2, y + row * 0.85, i, F(S("Team @1", tostring(i))))
			end
			y = y + math.ceil(cfg.career_teams / 4) * 0.85 + 0.2
			if teacher then
				add("label[0,%g;%s]", y, F(S("[Teacher] Funds of each team:")))
				y = y + 0.45
				local half = math.ceil(cfg.career_teams / 2)
				for i = 1, cfg.career_teams do
					local tn = team_name(i)
					local acc = "team:" .. tn
					local col, row = i <= half and 0 or 4, (i - 1) % half
					add("label[%g,%g;%s]", col, y + row * 0.4, F(S("Team @1 @2 (@3 players)", tn,
						rockmech.has_account(acc) and money_text(rockmech.money(acc)) or S("not opened"), tostring(#members_of(tn)))))
				end
				y = y + half * 0.4 + 0.5
				local teams = {}
				for i = 0, cfg.career_teams do teams[i + 1] = team_name(i) end
				add("field[0.3,%g;1.9,0.8;rm_amt;%s;]", y + 0.3, F(S("Amount (negative to deduct)")))
				add("dropdown[2.1,%g;1.3;rm_team;%s;1]", y + 0.05, table.concat(teams, ","))
				add("button[3.5,%g;1.6,0.8;rm_pay;%s]", y, F(S("Add/deduct")))
				add("button[5.3,%g;2.7,0.8;rm_reload;%s]", y, F(S("Reload student roster")))
				add("field_close_on_enter[rm_amt;false]")
				-- 老師自己加入某組，用學生的身分試玩（資金、營地都是那一組的）
				y = y + 1
				add("label[0,%g;%s]", y + 0.15, F(S("Teacher test play:")))
				add("dropdown[1.6,%g;1.3;rm_join_team;%s;%d]", y + 0.05, table.concat(teams, ","), (team_index(t or "") or 0) + 1)
				add("button[3,%g;2.3,0.8;rm_join;%s]", y, F(S("Join this team")))
				if t then add("button[5.3,%g;2.7,0.8;rm_leave;%s]", y, F(S("Leave my team"))) end
				y = y + 0.9
			end
			if y > 8.4 then return sfinv.make_formspec(player, context, table.concat(fs), false, ("size[8,%g]"):format(y + 0.6)) end
			return sfinv.make_formspec(player, context, table.concat(fs), false)
		end,
		on_player_receive_fields = function(self, player, context, fields)
			local name = player:get_player_name()
			local t = rockmech.team_of(name)
			if not is_teacher(name) then return end      -- 這一頁只有老師能用
			if fields.rm_home and t then
				core.close_formspec(name, "")
				send_home(name, t)
				return
			end
			if fields.rm_spawn then
				core.close_formspec(name, "")
				send_to(name, cfg.career_camp_dx)
				return
			end
			for i = 1, cfg.career_teams do
				if fields["rm_go_" .. i] then
					core.close_formspec(name, "")
					send_to(name, site_x(team_name(i)))
					core.chat_send_player(name, S("[Teacher] Camp of team @1", tostring(i)))
					return
				end
			end
			if not is_teacher(name) then return end
			if fields.rm_join then
				local tn = norm(fields.rm_join_team or "")
				if team_index(tn) then
					core.close_formspec(name, "")
					set_team(name, tn)      -- 會送到那組的營地
					core.log("action", ("[rockmech] teacher %s joined team %s"):format(name, tn))
				end
				return
			elseif fields.rm_leave then
				set_team(name, nil)
				refresh(player)
				return
			end
			if fields.rm_pay then
				local amount, tn = tonumber(fields.rm_amt or ""), norm(fields.rm_team or "")
				if not amount or not team_index(tn) then
					core.chat_send_player(name, S("[Teacher] The amount must be a number"))
					return
				end
				rockmech.add_money("team:" .. tn, amount)
				for _, m in ipairs(rockmech.account_members("team:" .. tn)) do
					core.chat_send_player(m, S("[Team @1] The teacher adjusted the funds by @2@3", tn, amount >= 0 and "+" or "", money_text(amount)))
				end
				core.log("action", ("[rockmech] %s adjusted team %s money by %g"):format(name, tn, amount))
				core.chat_send_player(name, S("[Teacher] Team @1 funds are now @2", tn, money_text(rockmech.money("team:" .. tn))))
				refresh(player)
			elseif fields.rm_reload then
				local created, moved, bad = load_roster()
				if created then has_roster = true end
				if not created then
					core.chat_send_player(name, S("[Teacher] Roster file not found: @1", roster_path))
				else
					core.chat_send_player(name, S("[Teacher] Roster: @1 accounts created, @2 players changed teams@3", tostring(created), tostring(moved),
						#bad > 0 and ("\n" .. table.concat(bad, "\n")) or ""))
				end
				refresh(player)
			end
		end,
	})

	-- 進遊戲提示一次按鈕在哪（單機版沒有旗子、沒有分組，不提示）
	if not cfg.solo then core.register_on_joinplayer(function(player)
		local name = player:get_player_name()
		core.after(2, function()
			core.chat_send_player(name, S("[Tip] Hold the \"Back to camp\" flag and left-click to return to camp; your team's funds are at the top right of the screen"))
		end)
	end) end
end

