-- rockmech/market.lua
-- 市場：煤價以外再加三種會波動的價格（柴油、炸藥、鋼材），加上偶發事件（戰爭、寒流、政策…）讓價格大幅波動；
-- 研究帳篷裡的經濟分析師收錢估算截止品位和價格走勢（想省錢就自己算：破碎站的結算單有回收率和處理費）。
--
-- 每種價格 = 基準 × 倍率；倍率的對數 x 每個交易日走一步（均值回歸的隨機漫步，跟煤價一樣）：
--   x ← x − θ·(x − m) + σ·z，m = 進行中事件的影響加總（沒有事件時 0 = 回到基準）
--   z：柴油自己的亂數；煤價、炸藥有一部分跟著柴油的亂數走（能源互相替代；炸藥的硝酸銨用天然氣做）
-- 事件：每個交易日有 EVENT_P 的機率發生一件（同時最多 MAX_ACTIVE 件）；發生當天價格先跳 JUMP 倍的影響，
--   持續期間往 m 拉；結束後慢慢回到基準。
-- 煤價的那一步在 crusher.lua 的 open_market（每天先呼叫 rockmech.market_day_step，再用 market_target("coal")）。
-- 用到價格的地方：柴油 → fuel.lua（rockmech.diesel_price）；炸藥、鋼材 → 商店（rockmech.shop_price，career.lua）

local S = rockmech.S
local cfg = rockmech.cfg
local storage = rockmech.collapse.storage

local EVENT_P = 1 / 12          -- 每個交易日發生事件的機率（平均 12 天一次）
local MAX_ACTIVE = 2
local JUMP = 0.6                -- 發生當天先跳到影響的幾成

-- 三種新指數（煤價在 crusher.lua）：σ 每天波動、θ 拉回比例、oil 跟柴油亂數的相關、上下限（倍）
local INDEX = {
	diesel = {label = S("Diesel"), vol = 0.10, revert = 0.15, oil = 1, lo = 0.5, hi = 3},
	explosive = {label = S("Explosives"), vol = 0.06, revert = 0.12, oil = 0.6, lo = 0.5, hi = 2.5},
	steel = {label = S("Steel"), vol = 0.04, revert = 0.10, oil = 0.2, lo = 0.6, hi = 2},
}
local ORDER = {"diesel", "explosive", "steel"}
local COAL_OIL = 0.4            -- 煤價跟柴油亂數的相關

-- 商店的東西跟哪一種指數走（沒列的固定價）
local SHOP_INDEX = {}
for _, k in ipairs({"detonator", "emulsion", "anfo"}) do SHOP_INDEX[k] = "explosive" end
for _, k in ipairs({"cart", "suv", "truck", "excavator", "lowboy", "heavyhaul", "dozer", "bulktruck", "charger", "corerig",
		"aerial", "crane", "drillrig", "jumbo", "haul", "excavator_big", "miner", "breaker_kit",
		"crusher", "crusher_big", "plant", "belt", "belt_switch", "loadout", "dump_hopper", "dump_hopper_big",
		"vent_fan", "vent_duct", "bolt", "drill"}) do SHOP_INDEX[k] = "steel" end

-- 事件：影響是對數（+0.15 ≈ 漲 16%、+0.3 ≈ 35%、+0.5 ≈ 65%），days 持續幾個交易日
local U1, U2, U3 = 0.15, 0.3, 0.5
local EVENTS = {
	{id = "miyi_war", label = S("Miyi War"), days = 12, fx = {coal = U1, diesel = U3, explosive = U2, steel = U1},
		news = S("War breaks out between Mi and Yi; oil tankers cannot get through")},
	{id = "wue_war", label = S("Wu-E War"), days = 20, fx = {coal = U2, diesel = U2, explosive = U2, steel = U2},
		news = S("War between Wu and E; energy and metals both scarce")},
	{id = "opec_cut", label = S("Oupeike output cut"), days = 7, fx = {coal = U1, diesel = U2, explosive = U1},
		news = S("Oil producers agree to cut output")},
	{id = "cold_wave", label = S("Cold wave"), days = 4, fx = {coal = U2, diesel = U1},
		news = S("A strong cold wave; power plants burn more coal")},
	{id = "warm_winter", label = S("Warm winter"), days = 4, fx = {coal = -U2, diesel = -U1},
		news = S("A warm winter; heating demand falls")},
	{id = "typhoon", label = S("Typhoon closes ports"), days = 2, fx = {coal = U1, diesel = U1, steel = U1},
		news = S("A typhoon closes the ports; shipments are delayed")},
	{id = "coal_cut", label = S("Coal-fired power reduction"), days = 12, fx = {coal = -U2},
		news = S("The government orders power plants to burn less coal")},
	{id = "carbon_fee", label = S("Carbon fee"), days = 12, fx = {coal = -U1, diesel = U1},
		news = S("A carbon fee takes effect")},
	{id = "recession", label = S("Recession"), days = 12, fx = {coal = -U1, diesel = -U1, explosive = -U1, steel = -U2},
		news = S("The economy slows; demand falls everywhere")},
	{id = "infrastructure", label = S("Infrastructure boom"), days = 7, fx = {explosive = U1, steel = U2},
		news = S("A big public works budget passes; steel and explosives in demand")},
}
local EVENT_BY_ID = {}
for _, e in ipairs(EVENTS) do EVENT_BY_ID[e.id] = e end
rockmech.market_events = EVENTS

local IDX, PREV, ACTIVE = "mkt:", "mkt_prev:", "mkt_events"

local function gauss()
	return math.sqrt(-2 * math.log(1 - math.random())) * math.cos(2 * math.pi * math.random())
end
local function factor(key) return storage:contains(IDX .. key) and storage:get_float(IDX .. key) or 1 end
rockmech.market_factor = factor
local function active()
	return core.deserialize(storage:get_string(ACTIVE)) or {}
end
local function set_active(list) storage:set_string(ACTIVE, core.serialize(list)) end

-- 進行中事件對某指數的影響（對數）
local function target(key)
	local m = 0
	for _, a in ipairs(active()) do
		local e = EVENT_BY_ID[a.id]
		if e and e.fx[key] then m = m + e.fx[key] end
	end
	return m
end
rockmech.market_target = target

-- 漲跌的箭頭
local function arrows(v)
	if v >= U3 then return "▲▲▲" elseif v >= U2 then return "▲▲" elseif v > 0 then return "▲"
	elseif v <= -U3 then return "▼▼▼" elseif v <= -U2 then return "▼▼" elseif v < 0 then return "▼" end
	return ""
end
local function effects_text(e)
	local out = {}
	local coal = cfg.ores.coal
	if e.fx.coal then out[#out + 1] = S(coal and coal.label or "Coal") .. arrows(e.fx.coal) end
	for _, k in ipairs(ORDER) do
		if e.fx[k] then out[#out + 1] = INDEX[k].label .. arrows(e.fx[k]) end
	end
	return table.concat(out, "  ")
end

-- 新聞快訊卡：螢幕右邊中間，點陣新聞畫面（tools/news_art.py 畫的 80×50，放大 4 倍）＋疊字，NEWS_SECS 秒後收掉
--   圖：上面台標條、中間畫面、下面標題條（左邊紅底疊「快訊」、右邊白底疊事件名稱）；圖下面一條黑底寫新聞和漲跌
local NEWS_SECS, NEWS_SCALE = 15, 4
local news_hud = {}         -- 玩家 → {hud id...}
local function news_clear(player)
	local name = player:get_player_name()
	for _, id in ipairs(news_hud[name] or {}) do player:hud_remove(id) end
	news_hud[name] = nil
end
function rockmech.news_card(player, e)
	news_clear(player)
	local name = player:get_player_name()
	local w, h = 80 * NEWS_SCALE, 50 * NEWS_SCALE
	local right = -16
	local left = right - w
	local function add(def)
		def.position, def.z_index = {x = 1, y = 0.5}, 900
		return player:hud_add(def)
	end
	local ids = {}
	ids[#ids + 1] = add({type = "image", text = "rockmech_news_" .. e.id .. ".png", scale = {x = NEWS_SCALE, y = NEWS_SCALE},
		alignment = {x = -1, y = 0}, offset = {x = right, y = 0}})
	local bar_y = h / 2 - 4 * NEWS_SCALE
	ids[#ids + 1] = add({type = "text", text = S("Breaking"), number = 0xFFFFFF, style = 1,
		alignment = {x = 0, y = 0}, offset = {x = left + 9 * NEWS_SCALE, y = bar_y}})
	ids[#ids + 1] = add({type = "text", text = e.label, number = 0x101010, style = 1,
		alignment = {x = 1, y = 0}, offset = {x = left + 18 * NEWS_SCALE + 8, y = bar_y}})
	-- 黑底兩行：新聞內容、漲跌
	ids[#ids + 1] = add({type = "image", text = "[fill:1x1:#000000", scale = {x = w, y = 48},
		alignment = {x = -1, y = 1}, offset = {x = right, y = h / 2}})
	ids[#ids + 1] = add({type = "text", text = e.news, number = 0xFFFFFF,
		alignment = {x = 1, y = 1}, offset = {x = left + 8, y = h / 2 + 4}})
	ids[#ids + 1] = add({type = "text", text = effects_text(e), number = 0xFFD060,
		alignment = {x = 1, y = 1}, offset = {x = left + 8, y = h / 2 + 26}})
	news_hud[name] = ids
	core.after(NEWS_SECS, function()
		local p = core.get_player_by_name(name)
		if p and news_hud[name] == ids then news_clear(p) end
	end)
end
core.register_on_leaveplayer(function(player) news_hud[player:get_player_name()] = nil end)

-- 開始一個事件：煤價先跳一下（crusher.lua 存的倍率），其他指數也跳
local function start_event(e, today)
	local list = active()
	for _, a in ipairs(list) do if a.id == e.id then return false end end
	list[#list + 1] = {id = e.id, from = today, to = today + e.days}
	set_active(list)
	for key, v in pairs(e.fx) do
		local k = key == "coal" and "price:coal" or (IDX .. key)
		local f = storage:contains(k) and storage:get_float(k) or 1
		storage:set_float(k, f * math.exp(JUMP * v))
	end
	rockmech.notify_all(core.colorize("#ffd060", S("[News] @1: @2", e.label, e.news)) .. "  " .. effects_text(e))
	for _, p in ipairs(core.get_connected_players()) do rockmech.news_card(p, e) end
	core.log("action", "[rockmech] market event " .. e.id)
	return true
end
rockmech.market_start_event = function(id)
	local e = EVENT_BY_ID[id]
	if not e then return false end
	return start_event(e, rockmech.market_day())
end

-- 每過一個交易日呼叫一次（crusher.lua 的 open_market）：結束到期的事件、擲骰子看有沒有新事件、三種指數走一步。
-- 回傳柴油的亂數（煤價那一步拿去用）
function rockmech.market_day_step(today)
	local list, keep = active(), {}
	for _, a in ipairs(list) do
		if a.to > today then keep[#keep + 1] = a
		else
			local e = EVENT_BY_ID[a.id]
			if e then rockmech.notify_all(S("[News] @1 is over; prices will drift back", e.label)) end
		end
	end
	set_active(keep)
	if #keep < MAX_ACTIVE and math.random() < EVENT_P then
		local pool = {}
		for _, e in ipairs(EVENTS) do
			local busy = false
			for _, a in ipairs(keep) do if a.id == e.id then busy = true end end
			if not busy then pool[#pool + 1] = e end
		end
		if #pool > 0 then start_event(pool[math.random(#pool)], today) end
	end
	local z_oil = gauss()
	for _, key in ipairs(ORDER) do
		local d = INDEX[key]
		local f = factor(key)
		storage:set_float(PREV .. key, f)
		local z = d.oil * z_oil + math.sqrt(1 - d.oil * d.oil) * gauss()
		local x = math.log(f)
		x = x - d.revert * (x - target(key)) + d.vol * z
		x = math.max(math.log(d.lo), math.min(math.log(d.hi), x))
		storage:set_float(IDX .. key, math.exp(x))
	end
	return z_oil
end
rockmech.market_coal_oil = COAL_OIL

---------------------------------------------------------------------------
-- 用到價格的地方
---------------------------------------------------------------------------

function rockmech.diesel_price() return cfg.diesel_price * factor("diesel") end
-- 商店的價錢（免費的還是免費）
function rockmech.shop_price(it)
	local k = SHOP_INDEX[it.key]
	if not k or it.price == 0 then return it.price end
	return math.floor(it.price * factor(k) / 10 + 0.5) * 10
end

local function change(key)
	local prev = storage:contains(PREV .. key) and storage:get_float(PREV .. key) or 1
	return factor(key) / prev - 1
end
local function pct(c) return (c >= 0 and "▲" or "▼") .. ("%.0f%%"):format(math.abs(c) * 100) end
-- 右上角資金下面的幾行（crusher.lua 的 show_money）：柴油、炸藥、鋼材，有事件就加事件名稱
function rockmech.market_hud()
	local out = {S("Diesel $@1/L (@2)", ("%.0f"):format(rockmech.diesel_price()), pct(change("diesel"))),
		S("Explosives @1%  Steel @2%", ("%.0f"):format(factor("explosive") * 100), ("%.0f"):format(factor("steel") * 100))}
	local today = rockmech.market_day()
	for _, a in ipairs(active()) do
		local e = EVENT_BY_ID[a.id]
		if e then out[#out + 1] = S("@1 (day @2)", e.label, today - a.from + 1) end
	end
	return table.concat(out, "\n")
end

-- 老師（教學地圖）可以指定事件：/rockmech_event 列出、/rockmech_event <代號> 觸發
if cfg.teacher then
	core.register_chatcommand("rockmech_event", {
		params = "[id]", privs = {rockmech = true},
		description = S("List market events, or start one"),
		func = function(_, param)
			param = (param or ""):match("^%s*(.-)%s*$")
			if param == "" then
				local ids = {}
				for _, e in ipairs(EVENTS) do ids[#ids + 1] = e.id .. " " .. e.label end
				return true, table.concat(ids, "\n")
			end
			if not EVENT_BY_ID[param] then return false, S("No such event: @1", param) end
			if not rockmech.market_start_event(param) then return false, S("That event is already happening") end
			for _, p in ipairs(core.get_connected_players()) do rockmech.show_money(p) end
			return true, "ok"
		end,
	})
end

---------------------------------------------------------------------------
-- 經濟分析師：研究帳篷後面中間。付錢看今天的報告（同一個交易日再看不用再付）：
--   今天的價格、截止品位（只算破碎站的處理費：品位 × 回收率 × 價格 = 處理費）、5 天後的價格預估、進行中的事件
---------------------------------------------------------------------------

local REPORT_COST = 1500
local FORM = "rockmech:analyst"
local PAID = "analyst_paid:"     -- 帳戶 → 付過錢的交易日
local WHO = "analyst"
local ENTITY = "rockmech:npc_analyst"
local F = core.formspec_escape

-- 5 天後倍率的期望值（均值回歸）：m + (x − m)(1 − θ)^5
local function forecast(x_now, m, revert, days)
	return math.exp(m + (math.log(x_now) - m) * (1 - revert) ^ days)
end

local function report(name)
	local acc = rockmech.account_of(name)
	local ore = cfg.ores.coal
	local today = rockmech.market_day()
	local lines = {}
	local function add(s, c) lines[#lines + 1] = c and core.colorize(c, s) or s end
	if ore then
		local p = rockmech.ore_price(ore)
		local rec = rockmech.eff_ore_recovery and rockmech.eff_ore_recovery(acc, ore) or ore.recovery
		local fee, r = cfg.crusher_fee, rockmech.yard_ratio()
		-- 不賺不賠：g × 回收率 × 價格 × 收購比例 = (1 − g) × 廢石處理費
		local function cutoff(price) return fee / (price * rec * r + fee) end
		local cut = cutoff(p)
		local p5 = ore.price * forecast(p / ore.price, target("coal"), cfg.price_revert, 5)
		add(S("@1 today: $@2/t", S(ore.label), ("%.0f"):format(p)), "#ffe080")
		add(S("Cut-off grade at the crusher: @1%", ("%.1f"):format(cut * 100)), "#80ff80")
		local v = p * rec * r + fee
		add(S("  = gangue fee $@1 ÷ $@2", fee, ("%.0f"):format(v)))
		add(S("  $@1 = price $@2 × recovery @3% × @4% + gangue fee", ("%.0f"):format(v), ("%.0f"):format(p), ("%.0f"):format(rec * 100), ("%.0f"):format(r * 100)))
		add(S("  Rubble below this grade loses money even before hauling and fuel"))
		add(S("In 5 days: about $@1/t, cut-off @2%", ("%.0f"):format(p5), ("%.1f"):format(cutoff(p5) * 100)))
	end
	add("")
	for _, key in ipairs(ORDER) do
		local d = INDEX[key]
		local f5 = forecast(factor(key), target(key), d.revert, 5)
		local now = key == "diesel" and S("$@1/L", ("%.0f"):format(rockmech.diesel_price())) or (("%.0f%%"):format(factor(key) * 100))
		local later = key == "diesel" and S("$@1/L", ("%.0f"):format(cfg.diesel_price * f5)) or (("%.0f%%"):format(f5 * 100))
		add(S("@1: now @2, in 5 days about @3", d.label, now, later))
	end
	local list = active()
	if #list > 0 then
		add("")
		for _, a in ipairs(list) do
			local e = EVENT_BY_ID[a.id]
			if e then add(S("@1: @2 more days  @3", e.label, math.max(0, a.to - today), effects_text(e)), "#ffd060") end
		end
	end
	return lines
end

local function form(name)
	local acc = rockmech.account_of(name)
	local paid = storage:get_int(PAID .. acc) == rockmech.market_day() + 1     -- 存 day + 1（0 = 沒付過）
	local out = {"formspec_version[6]size[11,8.6]", ("label[0.5,0.6;%s]"):format(F(S("Economic Analyst")))}
	if paid then
		local y = 1.3
		for _, l in ipairs(report(name)) do
			out[#out + 1] = ("label[0.5,%g;%s]"):format(y, F(l))
			y = y + 0.42
		end
	else
		out[#out + 1] = ("label[0.5,1.4;%s]"):format(F(S("I estimate today's cut-off grade and where prices are heading over the next 5 days")))
		out[#out + 1] = ("label[0.5,1.9;%s]"):format(F(S("Want to save money? Work it out yourself from the crusher statement")))
		out[#out + 1] = ("button[0.5,2.6;4,0.8;buy;%s]"):format(F(S("Today's report $@1", REPORT_COST)))
	end
	return table.concat(out)
end

local function open(player)
	local name = player:get_player_name()
	if not rockmech.has_account(name) then
		rockmech.notify(name, S("[Analyst] You have no funds account yet"))
		return
	end
	core.show_formspec(name, FORM, form(name))
end

core.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= FORM then return end
	local name = player:get_player_name()
	if fields.buy then
		local acc = rockmech.account_of(name)
		local day1 = rockmech.market_day() + 1
		if storage:get_int(PAID .. acc) ~= day1 then
			if rockmech.money(name) < REPORT_COST then
				rockmech.notify(name, S("[Analyst] Not enough money: the report costs $@1", REPORT_COST))
				return true
			end
			rockmech.add_money(name, -REPORT_COST)
			storage:set_int(PAID .. acc, day1)
		end
		core.show_formspec(name, FORM, form(name))
	end
	return true
end)

local npc = {entity = ENTITY, title = S("Economic Analyst"), sells = S("Cut-off grade and price outlook"),
	color = "#e0c0ff", tint = "#503070", sit = false}
core.register_entity(ENTITY, {
	initial_properties = {
		physical = true, collisionbox = {-0.3, 0, -0.3, 0.3, 1.7, 0.3},
		visual = "mesh", mesh = "character.b3d", textures = {rockmech.npc_skin(WHO)},
		nametag = npc.title, nametag_color = npc.color, static_save = false,
	},
	on_activate = function(self)
		self.object:set_armor_groups({immortal = 1})
		rockmech.npc_dress(self.object, WHO)
		self.object:set_animation({x = 0, y = 79}, 30)
	end,
	on_rightclick = function(self, clicker)
		if rockmech.hand_first and rockmech.hand_first(clicker) then return end
		if clicker and clicker:is_player() then open(clicker) end
	end,
	on_punch = function() return true end,
})
rockmech.career_npcs[WHO] = npc

-- 站在研究帳篷後面中間（帳篷本地座標 dx 0、dz −2，面向北）：新蓋的帳篷一起放，舊的營地補上
local RES_DX, RES_Z = 23, -28      -- 跟 research.lua 一樣
local function flag_of(x0) return "analyst_site:" .. x0 end
local function add_spot(x0, y)
	storage:set_string(flag_of(x0), "1")
	local _, at, yaw = rockmech.career_placer(x0 + RES_DX, RES_Z, y, "north")
	local p = at(0, 0, -2)
	local key = rockmech.career_vendor_spots
	local list = core.deserialize(storage:get_string(key)) or {}
	list[#list + 1] = {kind = WHO, pos = {x = p.x, y = y + 0.5, z = p.z}, yaw = yaw}
	storage:set_string(key, core.serialize(list))
end
local build = rockmech.career_build_research
if build then
	function rockmech.career_build_research(x0)
		build(x0)
		-- 地面高度：帳篷柱子底下那格（research.lua 用同一個 ground_y）
		local y
		for yy = 40, -30, -1 do
			local n = core.get_node({x = x0 + RES_DX - 3, y = yy, z = RES_Z - 3}).name
			if n ~= "air" and n ~= "ignore" and n ~= "rockmech:tent_pole" and not n:find("canvas") then y = yy; break end
		end
		if y and storage:get_string(flag_of(x0)) == "" then add_spot(x0, y) end
	end
end
-- 已經有研究帳篷的營地補分析師
core.after(3, function()
	local sites = {}
	if storage:get_string("career_site") == "2" then sites[#sites + 1] = cfg.career_camp_dx end
	if rockmech.team_site_x then
		for i = 1, cfg.career_teams or 0 do
			if storage:get_string("team_site:" .. i) == "1" then sites[#sites + 1] = rockmech.team_site_x(tostring(i)) end
		end
	end
	for _, x0 in ipairs(sites) do
		if storage:get_string("research_site:" .. x0) == "1" and storage:get_string(flag_of(x0)) == "" then
			local p = {x = x0 + RES_DX - 3, y = 0, z = RES_Z - 3}
			core.emerge_area(vector.offset(p, 0, -30, 0), vector.offset(p, 0, 40, 0), function(_, _, rem)
				if rem > 0 or storage:get_string(flag_of(x0)) ~= "" then return end
				for yy = 40, -30, -1 do
					local n = core.get_node({x = p.x, y = yy, z = p.z}).name
					if n ~= "air" and n ~= "ignore" and n ~= "rockmech:tent_pole" and not n:find("canvas") then
						add_spot(x0, yy)
						return
					end
				end
			end)
		end
	end
end)

---------------------------------------------------------------------------
-- 告示板（貨櫃辦公室 1 樓門旁的外牆）：右鍵看今天的價格、漲跌和新聞。
-- 廣播收音機：帶在身上，右上角跟著顯示價格和新聞（沒帶就只有資金）
---------------------------------------------------------------------------

local BOARD = "rockmech:office_news_board"       -- 名字 office_ 開頭：營地地坪保護（camp.lua 的 BUILT）
local BOARD_FORM = "rockmech:news_board"
local RADIO = "rockmech:broadcast_radio"

local function board_form()
	local today = rockmech.market_day()
	local lines = {}
	local function add(s, c) lines[#lines + 1] = c and core.colorize(c, s) or s end
	add(S("Trading day @1", today + 1), "#ffe080")
	add("")
	add(rockmech.coal_price_text and rockmech.coal_price_text() or "")
	add(rockmech.market_hud and rockmech.market_hud():match("^[^\n]*\n?[^\n]*") or "")
	add("")
	add(S("News"), "#ffd060")
	local any
	for _, a in ipairs(active()) do
		local e = EVENT_BY_ID[a.id]
		if e then
			any = true
			add(S("@1: day @2 of @3", e.label, today - a.from + 1, a.to - a.from), "#ffd060")
			add("  " .. e.news)
			add("  " .. effects_text(e))
		end
	end
	if not any then add(S("No news today")) end
	return "formspec_version[6]size[11,8]"
		.. ("label[0.5,0.6;%s]"):format(F(S("Notice board")))
		.. ("textarea[0.5,1.1;10,6.4;;;%s]"):format(F(table.concat(lines, "\n")))
end

core.register_node(BOARD, {
	description = S("Notice board"),
	drawtype = "nodebox", paramtype = "light", paramtype2 = "wallmounted", sunlight_propagates = true,
	walkable = false,
	node_box = {type = "wallmounted", wall_side = {-0.5, -0.45, -0.48, -0.42, 0.45, 0.48},
		wall_top = {-0.48, 0.42, -0.45, 0.48, 0.5, 0.45}, wall_bottom = {-0.48, -0.5, -0.45, 0.48, -0.42, 0.45}},
	-- 軟木板、木框、釘著幾張紙
	tiles = {"[fill:16x16:#6a4a2a^[fill:14x14:1,1:#b08a58^[fill:5x6:2,2:#f4f0e0^[fill:6x4:8,3:#ffe680"
		.. "^[fill:5x5:9,9:#f4f0e0^[fill:4x4:3,10:#e8c0c0^[fill:3x1:3,4:#606060^[fill:3x1:10,11:#606060"},
	groups = {not_in_creative_inventory = 1}, diggable = false, on_blast = function() end,
	is_ground_content = false,
	on_rightclick = function(pos, node, clicker)
		if clicker and clicker:is_player() then core.show_formspec(clicker:get_player_name(), BOARD_FORM, board_form()) end
	end,
})

-- 放告示板：pos 是板子那一格，wall 是貼著的牆
function rockmech.news_board_put(pos, wall)
	core.set_node(pos, {name = BOARD, param2 = core.dir_to_wallmounted(vector.subtract(wall, pos))})
end

-- 已經蓋好的貨櫃辦公室補告示板（1 樓東牆門旁）：找牆的底樑定高度
local OFFICE_RX = 6
core.after(4, function()
	local dx = rockmech.career_office_dx
	if not dx then return end
	for _, x0 in ipairs(rockmech.camp and rockmech.camp.sites() or {}) do
		-- board2：第一版從上往下找底樑，找到 2 樓那根（2 樓地板也是底樑），板子掛到 2 樓去了：拔掉重掛
		if storage:get_string("board2:" .. x0) == "" then
			local _, at = rockmech.career_placer(x0 + dx, -10, 0)
			local w0 = at(OFFICE_RX, 0, -1)
			core.emerge_area(vector.offset(w0, -2, -30, -2), vector.offset(w0, 2, 40, 2), function(_, _, rem)
				if rem > 0 or storage:get_string("board2:" .. x0) ~= "" then return end
				for y = -30, 40 do      -- 從下往上：1 樓的底樑
					if core.get_node({x = w0.x, y = y, z = w0.z}).name == "rockmech:office_wall_base" then
						local _, at2 = rockmech.career_placer(x0 + dx, -10, y - 1)
						for h = 3, 8 do
							local q = at2(OFFICE_RX + 1, h, -1)
							if core.get_node(q).name == BOARD then core.remove_node(q) end
						end
						local p = at2(OFFICE_RX + 1, 2, -1)
						if core.get_node(p).name == "air" then rockmech.news_board_put(p, at2(OFFICE_RX, 2, -1)) end
						storage:set_string("board1:" .. x0, "1")
						storage:set_string("board2:" .. x0, "1")
						core.log("action", ("[rockmech] 營地 x = %d 的貨櫃辦公室補上告示板"):format(x0))
						return
					end
				end
			end)
		end
	end
end)

core.register_craftitem(RADIO, {
	description = S("Broadcast radio\nKeep it on you to see prices and news at the top right"),
	short_description = S("Broadcast radio"),
	inventory_image = "[fill:16x16:#00000000^[fill:14x9:1,5:#3a3a3a^[fill:12x7:2,6:#5a5a5a^[fill:5x5:3,7:#9a9a9a"
		.. "^[fill:1x5:4,7:#6a6a6a^[fill:1x5:6,7:#6a6a6a^[fill:4x2:9,7:#e0b428^[fill:2x2:10,10:#c0c0c0^[fill:1x5:12,0:#8a8a8a",
	stack_max = 1,
})
function rockmech.has_radio(player)
	local inv = player and player:get_inventory()
	return inv and inv:contains_item("main", RADIO) or false
end
-- 收音機拿進拿出：右上角跟著換（每 2 秒看一次）
local radio_state, rt = {}, 0
core.register_globalstep(function(dtime)
	rt = rt + dtime
	if rt < 2 then return end
	rt = 0
	for _, p in ipairs(core.get_connected_players()) do
		local name, has = p:get_player_name(), rockmech.has_radio(p)
		if radio_state[name] ~= has then
			radio_state[name] = has
			if rockmech.show_money then rockmech.show_money(p) end
		end
	end
end)
core.register_on_leaveplayer(function(p) radio_state[p:get_player_name()] = nil end)
