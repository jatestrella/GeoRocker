-- rockmech/team.lua
-- 經營模式的全班伺服器：分組共用資金、各組各自的營地、預先建好的帳號。
--   分組：每組一個帳戶 "team:<組>"（crusher.lua 的 rockmech.account_of），組員買東西、破碎站入帳都用這筆錢。
--   組別是數字 1..rockmech_career_teams（跟成績單的組別一樣）。
--   營地：第 i 組各有一條礦帶，沿 x 排開：第 1 組在第 −1 帶、第 2 組在 +1、第 3 組在 −2、第 4 組在 +2 …（第 0 帶是出生點，
--     給老師示範）。設了 rockmech_coal_seam_lanes 時，每帶有一條一模一樣的煤層，帶寬就是營地間距；
--     沒設就用 rockmech_career_site_spacing。每座營地跟出生點的一樣：帳篷和供應商、一座掛在組上的破碎站。
--     組第一次有人分進來時才發起始資金（rockmech_career_start）、蓋營地。
--   名單：世界資料夾裡的 students.csv（rockmech_career_roster），一行一位：帳號,密碼,組別
--     伺服器啟動時，還沒有的帳號用那個密碼建好；有寫組別就分進去（以名單為準）。
--     有名單時，名單外的名稱不能登入（rockmech_career_roster_only）。密碼學生自己在 Esc 選單「變更密碼」改。
--   道具：「回營地」旗子（每人一支，登入時沒有就補），左鍵或右鍵回自己組的營地（沒分組回出生點）。
--   按鈕：背包（I）的「我的組」分頁：看資金和組員、回營地、參觀別組；老師另有各組資金、加扣錢、重讀名單。
--   指令（備用）：/team、/team list、/team set <帳號> <組|none>、/team money <組> <金額>、/team reload、/site [組]

local cfg = rockmech.cfg
if not cfg.career then return end

local storage = rockmech.collapse.storage
local TEAM_OF, SITE, TP = "team_of:", "team_site:", "team_tp:"
local TEACHER = "server"     -- 老師指令要的權限（開伺服器的人自動有）

local function team_index(t)
	local i = tonumber(t)
	return i and i == math.floor(i) and i >= 1 and i <= cfg.career_teams and i or nil
end
local function team_name(i) return tostring(i) end
-- 名單、指令裡寫的組別（"3"、"3.0"、" 3 "）→ 正規的組名 "3"；不是組別就原樣回傳
local function norm(t)
	local i = team_index(t)
	return i and team_name(i) or t
end
local function all_teams()
	local out = {}
	for i = 1, cfg.career_teams do out[i] = team_name(i) end
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
			core.chat_send_player(name, ("[分組] 你在第 %s 組。全組共用一筆資金，營地在 x = %d（按 I →「我的組」回營地）"):format(t, site_x(t)))
			send_home(name, t)
		else
			core.chat_send_player(name, "[分組] 你已經不在任何一組")
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
				core.chat_send_player(name, ("[分組] 歡迎！你在第 %s 組，全組共用一筆資金。按 I →「我的組」可以看資金、回營地"):format(t))
				send_home(name, t)
			end)
		end
	elseif not core.is_singleplayer() and not rockmech.has_account(name) then
		core.after(1, function()
			core.chat_send_player(name, "[分組] 你還沒分組，還不能買設備。請找老師分組")
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

local function load_roster()
	local f = io.open(roster_path, "r")
	if not f then return end
	local auth = core.get_auth_handler()
	local created, moved, bad = 0, 0, {}
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
				bad[#bad + 1] = ("第 %d 行：帳號「%s」只能用英文字母、數字、- 和 _，最多 20 字"):format(n, name)
			else
				if not auth.get_auth(name) then
					auth.create_auth(name, pw == "" and "" or core.get_password_hash(name, pw))
					created = created + 1
				end
				if t ~= "" then
					if not team_index(t) then
						bad[#bad + 1] = ("第 %d 行：組別「%s」不在 1–%s 之間"):format(n, t, team_name(cfg.career_teams))
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
	for _, b in ipairs(bad) do core.log("warning", "[rockmech] 名單 " .. b) end
	return created, moved, bad
end

-- 伺服器跑起來第一步就讀名單（auth 資料庫這時可以用）
core.after(0, load_roster)

-- 有名單時，名單外的名稱不能登入（開伺服器的人、單人模式不受限）
core.register_on_prejoinplayer(function(name)
	if not (has_roster and cfg.career_roster_only) or core.is_singleplayer() then return end
	if name == core.settings:get("name") then return end
	if core.get_auth_handler().get_auth(name) then return end
	return "這個伺服器只開放班上同學：請用老師給的帳號登入（大小寫要一樣）"
end)

---------------------------------------------------------------------------
-- 指令
---------------------------------------------------------------------------

local function money_text(v) return ("%s$%.0f"):format(v < 0 and "−" or "", math.abs(v)) end

local function is_teacher(name) return core.check_player_privs(name, {[TEACHER] = true}) end

core.register_chatcommand("team", {
	params = "| list | set <帳號> <組|none> | money <組> <金額> | reload",
	description = "分組：看自己的組；老師可以列出各組、分組、調整資金、重讀名單",
	func = function(name, param)
		local args = param:split(" ")
		local cmd = args[1]
		if not cmd then
			local t = rockmech.team_of(name)
			if not t then return true, "你還沒分組" end
			return true, ("你在第 %s 組，資金 %s，營地 x = %d。組員：%s"):format(t, money_text(rockmech.money(name)), site_x(t),
				table.concat(members_of(t), "、"))
		end
		if not is_teacher(name) then return false, "這個指令要老師（" .. TEACHER .. " 權限）才能用" end
		if cmd == "list" then
			local lines = {}
			for _, t in ipairs(all_teams()) do
				local m = members_of(t)
				local acc = "team:" .. t
				lines[#lines + 1] = ("第 %s 組（x = %d）%s　%d 人：%s"):format(t, site_x(t),
					rockmech.has_account(acc) and money_text(rockmech.money(acc)) or "未開",
					#m, table.concat(m, "、"))
			end
			return true, table.concat(lines, "\n")
		elseif cmd == "set" then
			local who, t = args[2], norm((args[3] or ""):upper())
			if not who or t == "" then return false, "用法：/team set <帳號> <組|none>" end
			if not core.get_auth_handler().get_auth(who) then return false, "沒有這個帳號：" .. who end
			if t == "NONE" then set_team(who, nil); return true, who .. " 已取消分組" end
			if not team_index(t) then return false, ("組別要在 1–%s 之間"):format(team_name(cfg.career_teams)) end
			set_team(who, t)
			return true, ("%s → 第 %s 組"):format(who, t)
		elseif cmd == "money" then
			local t, amount = norm(args[2] or ""), tonumber(args[3] or "")
			if not team_index(t) or not amount then return false, "用法：/team money <組> <金額>（負數是扣錢）" end
			rockmech.add_money("team:" .. t, amount)
			for _, m in ipairs(rockmech.account_members("team:" .. t)) do
				core.chat_send_player(m, ("[第 %s 組] 老師調整資金 %s%s"):format(t, amount >= 0 and "+" or "", money_text(amount)))
			end
			core.log("action", ("[rockmech] %s adjusted team %s money by %g"):format(name, t, amount))
			return true, ("第 %s 組資金現在 %s"):format(t, money_text(rockmech.money("team:" .. t)))
		elseif cmd == "reload" then
			if not has_roster then
				local f = io.open(roster_path, "r")
				if not f then return false, "找不到名單檔：" .. roster_path end
				f:close()
				has_roster = true
			end
			local created, moved, bad = load_roster()
			return true, ("名單：新建 %d 個帳號、%d 人換組%s"):format(created, moved,
				#bad > 0 and ("\n" .. table.concat(bad, "\n")) or "")
		end
		return false, "用法：/team [list | set <帳號> <組|none> | money <組> <金額> | reload]"
	end,
})

core.register_chatcommand("site", {
	params = "[組]",
	description = "回自己組的營地（老師可以指定組別）",
	func = function(name, param)
		local t = norm(trim(param))
		if t ~= "" then
			if not is_teacher(name) then return false, "只能回自己組的營地：/site" end
			if not team_index(t) then return false, ("組別要在 1–%s 之間"):format(team_name(cfg.career_teams)) end
		else
			t = rockmech.team_of(name)
			if not t then return false, "你還沒分組" end
		end
		send_home(name, t)
		return true, ("前往第 %s 組營地（x = %d）"):format(t, site_x(t))
	end,
})

---------------------------------------------------------------------------
-- 背包（I）的「我的組」分頁：不用打指令，全部用按鈕
---------------------------------------------------------------------------

if core.get_modpath("sfinv") and sfinv then
	local F = core.formspec_escape
	local PAGE = "rockmech:team"

	-- 打開背包先看到這一頁
	function sfinv.get_homepage_name() return PAGE end

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
			out[#out + 1] = table.concat(names, "、", i, math.min(i + per - 1, #names))
		end
		return out
	end

	local function online_marked(t)
		local out = {}
		for _, m in ipairs(members_of(t)) do
			out[#out + 1] = core.get_player_by_name(m) and (m .. "（在線）") or m
		end
		return out
	end

	sfinv.register_page(PAGE, {
		title = "我的組",
		get = function(self, player, context)
			local name = player:get_player_name()
			local t = rockmech.team_of(name)
			local teacher = is_teacher(name)
			local fs = {}
			local function add(f, ...) fs[#fs + 1] = f:format(...) end
			local y = 0
			if t then
				add("label[0,%g;%s]", y, F(("第 %s 組　　資金 %s"):format(t, money_text(rockmech.money(name)))))
				y = y + 0.5
				add("label[0,%g;%s]", y, F("組員："))
				for _, line in ipairs(name_lines(online_marked(t), 3)) do
					add("label[0.8,%g;%s]", y, F(line))
					y = y + 0.4
				end
				y = y + 0.3
				add("button[0,%g;4,0.8;rm_home;%s]", y, F(("回第 %s 組營地"):format(t)))
			else
				add("label[0,%g;%s]", y, F(teacher and "老師（沒有分組）" or "你還沒分組，請找老師分組"))
				y = y + 0.6
				add("button[0,%g;4,0.8;rm_spawn;%s]", y, F("回出生點"))
			end
			y = y + 1.1
			add("label[0,%g;%s]", y, F("參觀其他組的礦帶："))
			y = y + 0.45
			for i = 1, cfg.career_teams do
				local col, row = (i - 1) % 4, math.floor((i - 1) / 4)
				add("button[%g,%g;2,0.8;rm_go_%d;%s]", col * 2, y + row * 0.85, i, F(("第 %d 組"):format(i)))
			end
			y = y + math.ceil(cfg.career_teams / 4) * 0.85 + 0.2
			if teacher then
				add("label[0,%g;%s]", y, F("【老師】各組資金："))
				y = y + 0.45
				local half = math.ceil(cfg.career_teams / 2)
				for i = 1, cfg.career_teams do
					local tn = team_name(i)
					local acc = "team:" .. tn
					local col, row = i <= half and 0 or 4, (i - 1) % half
					add("label[%g,%g;%s]", col, y + row * 0.4, F(("第 %s 組 %s（%d 人）"):format(tn,
						rockmech.has_account(acc) and money_text(rockmech.money(acc)) or "未開", #members_of(tn))))
				end
				y = y + half * 0.4 + 0.5
				local teams = {}
				for i = 1, cfg.career_teams do teams[i] = team_name(i) end
				add("field[0.3,%g;1.9,0.8;rm_amt;%s;]", y + 0.3, F("金額（負數扣錢）"))
				add("dropdown[2.1,%g;1.3;rm_team;%s;1]", y + 0.05, table.concat(teams, ","))
				add("button[3.5,%g;1.6,0.8;rm_pay;%s]", y, F("加/扣錢"))
				add("button[5.3,%g;2.7,0.8;rm_reload;%s]", y, F("重讀學生名單"))
				add("field_close_on_enter[rm_amt;false]")
				-- 老師自己加入某組，用學生的身分試玩（資金、營地都是那一組的）
				y = y + 1
				add("label[0,%g;%s]", y + 0.15, F("老師試玩："))
				add("dropdown[1.6,%g;1.3;rm_join_team;%s;%d]", y + 0.05, table.concat(teams, ","), team_index(t or "") or 1)
				add("button[3,%g;2.3,0.8;rm_join;%s]", y, F("我加入這組"))
				if t then add("button[5.3,%g;2.7,0.8;rm_leave;%s]", y, F("我退出分組")) end
				y = y + 0.9
			end
			if y > 8.4 then return sfinv.make_formspec(player, context, table.concat(fs), false, ("size[8,%g]"):format(y + 0.6)) end
			return sfinv.make_formspec(player, context, table.concat(fs), false)
		end,
		on_player_receive_fields = function(self, player, context, fields)
			local name = player:get_player_name()
			local t = rockmech.team_of(name)
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
					core.chat_send_player(name, ("[參觀] 第 %d 組的營地。按 I →「我的組」可以回去"):format(i))
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
					core.chat_send_player(name, "[老師] 金額要填數字")
					return
				end
				rockmech.add_money("team:" .. tn, amount)
				for _, m in ipairs(rockmech.account_members("team:" .. tn)) do
					core.chat_send_player(m, ("[第 %s 組] 老師調整資金 %s%s"):format(tn, amount >= 0 and "+" or "", money_text(amount)))
				end
				core.log("action", ("[rockmech] %s adjusted team %s money by %g"):format(name, tn, amount))
				core.chat_send_player(name, ("[老師] 第 %s 組資金現在 %s"):format(tn, money_text(rockmech.money("team:" .. tn))))
				refresh(player)
			elseif fields.rm_reload then
				local created, moved, bad = load_roster()
				if created then has_roster = true end
				if not created then
					core.chat_send_player(name, "[老師] 找不到名單檔：" .. roster_path)
				else
					core.chat_send_player(name, ("[老師] 名單：新建 %d 個帳號、%d 人換組%s"):format(created, moved,
						#bad > 0 and ("\n" .. table.concat(bad, "\n")) or ""))
				end
				refresh(player)
			end
		end,
	})

	-- 進遊戲提示一次按鈕在哪
	core.register_on_joinplayer(function(player)
		local name = player:get_player_name()
		core.after(2, function()
			core.chat_send_player(name, "[提示] 拿著「回營地」旗子按左鍵就回營地；按 I →「我的組」看資金、參觀別組")
		end)
	end)
end

---------------------------------------------------------------------------
-- 「回營地」旗子：每人一支，拿著按左鍵或右鍵就回營地
---------------------------------------------------------------------------

local FLAG = "rockmech:camp_flag"
local function go_camp(itemstack, user)
	if not (user and user:is_player()) then return itemstack end
	local name = user:get_player_name()
	local t = rockmech.team_of(name)
	if t then
		send_home(name, t)
		core.chat_send_player(name, ("[回營地] 第 %s 組營地"):format(t))
	else
		send_to(name, cfg.career_camp_dx)
		core.chat_send_player(name, "[回營地] 出生點")
	end
	return itemstack
end
core.register_craftitem(FLAG, {
	description = "回營地\n拿在手上按左鍵或右鍵，回到自己組的營地",
	inventory_image = "[fill:16x16:#00000000^[fill:2x15:3,1:#6a4a28^[fill:9x6:5,1:#c04030^[fill:9x2:5,3:#f0e0b0",
	stack_max = 1,
	groups = {not_in_creative_inventory = 1},
	on_use = go_camp,
	on_secondary_use = go_camp,
	on_place = go_camp,
	on_drop = function(itemstack) return itemstack end,     -- 丟不掉
})
core.register_on_joinplayer(function(player)
	local inv = player:get_inventory()
	if not inv:contains_item("main", FLAG) then inv:add_item("main", FLAG) end
end)
