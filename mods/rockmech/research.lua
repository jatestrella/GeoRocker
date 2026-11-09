-- rockmech/research.lua
-- 研究所（經營模式）：每組營地貨櫃辦公室西邊一頂研究帳篷，裡面有「機械技工」「駐點地質師」。
--   右鍵研究員打開研發清單（像商店，之後可以改成天賦樹）：每個項目有等級，第 n 級要 基準價 × n、基準時間 × n。
--   研發用整組的錢、效果整組共用；每位研究員一次一項（不同研究員可以同時研發）。研發中的那一列有進度條和倒數。
--   進度只在該組有組員在線上時才走（每秒）；完成時通知全組。
--   等級存在 mod storage 的 research:<帳戶>:<項目>（crusher.lua 的 rockmech.research_level），
--   各項的效果由 crusher.lua 的 rockmech.eff_* 算：選礦場、破碎站、輸送帶照放置那一組的等級。
--   進行中的研發存在 research_job:<研究員>:<帳戶> = {key, level, left（剩幾秒）, total}。

local S = rockmech.S
local TR = rockmech.config.TR
local E = core.formspec_escape
local cfg = rockmech.cfg
if not cfg.career then return end
local storage = rockmech.collapse.storage

local FORM = "rockmech:research"
local JOB = "research_job:"

-- 研發項目。per：每級的效果（顯示用，實際算在 crusher.lua 的 rockmech.eff_*）
local ITEMS = {
	{key = "plant_recovery", who = "mechanic", label = TR("Plant recovery"), max = 5, base = 20000, minutes = 10,
		desc = TR("Share of coal recovered into clean coal at the pre-sorting plant +1%"),
		value = function(acc) return ("%.0f%%"):format(rockmech.eff_plant_recovery(acc) * 100) end},
	{key = "plant_misplaced", who = "mechanic", label = TR("Cleaner clean coal"), max = 4, base = 20000, minutes = 10,
		desc = TR("Share of waste rock misplaced into clean coal at the pre-sorting plant −2%"),
		value = function(acc) return ("%.0f%%"):format(rockmech.eff_plant_misplaced(acc) * 100) end},
	{key = "crusher_rate", who = "mechanic", label = TR("Crusher upgrade"), max = 5, base = 30000, minutes = 15,
		desc = TR("Crushing station throughput +10%"),
		value = function(acc) return ("×%.1f"):format(rockmech.eff_crusher_mult(acc)) end},
	{key = "conveyor_rate", who = "mechanic", label = TR("Conveyor upgrade"), max = 5, base = 15000, minutes = 10,
		desc = TR("Conveyor capacity +10%"),
		value = function(acc) return ("×%.1f"):format(rockmech.eff_conveyor_mult(acc)) end},
	{key = "maintenance", who = "mechanic", label = TR("Regular maintenance"), max = 5, base = 20000, minutes = 10,
		desc = TR("The team's vehicles move 5% faster"),
		value = function(acc) return ("×%.2f"):format(rockmech.eff_vehicle_mult(acc)) end},
	{key = "eco_driving", who = "mechanic", label = TR("Eco driving"), max = 5, base = 20000, minutes = 10,
		desc = TR("The team's vehicles use 5% less fuel"),
		value = function(acc) return ("×%.2f"):format(rockmech.eff_fuel_mult(acc)) end},
	{key = "ore_recovery", who = "geologist", label = TR("Grade control"), max = 5, base = 25000, minutes = 10,
		desc = TR("Recovery of ore sold at the crushing station +1%"),
		value = function(acc)
			for _, ore in pairs(cfg.ores) do return ("%.0f%%"):format(rockmech.eff_ore_recovery(acc, ore) * 100) end
			return "—"
		end},
	{key = "blast_design", who = "geologist", label = TR("Blast design"), max = 4, base = 25000, minutes = 10,
		desc = TR("Blast breakage radius +5%"),
		value = function(acc) return ("×%.2f"):format(rockmech.eff_blast_mult(acc)) end},
	{key = "support_method", who = "geologist", label = TR("Support method"), max = 5, base = 25000, minutes = 10,
		desc = TR("Rock bolt and shotcrete strength +10%"),
		value = function(acc) return ("×%.1f"):format(rockmech.eff_support_mult(acc)) end},
	{key = "skilled_miner", who = "geologist", label = TR("Skilled miner"), max = 5, base = 25000, minutes = 10,
		desc = TR("Digging and drilling 10% faster"),
		value = function(acc) return ("×%.1f"):format(rockmech.eff_dig_mult(acc)) end},
}
-- 研發面板的圖示：設施的圖示＋角落的小徽章（綠加號：提升、紅減號：減少、黃箭頭：加快）
local BADGE = {
	plus = "[fill:16x16:#00000000^[fill:7x7:9,9:#1e1e1e^[fill:5x1:10,12:#50d050^[fill:1x5:12,10:#50d050",
	minus = "[fill:16x16:#00000000^[fill:7x5:9,10:#1e1e1e^[fill:5x1:10,12:#f05050",
	up = "[fill:16x16:#00000000^[fill:7x8:9,8:#1e1e1e^[fill:1x1:12,9:#f0c020^[fill:3x1:11,10:#f0c020^[fill:5x1:10,11:#f0c020^[fill:1x3:12,12:#f0c020",
}
local function badged(base, badge) return "(" .. base .. ")^[resize:32x32^(" .. BADGE[badge] .. "^[resize:32x32)" end
local function item_img(name) local d = core.registered_items[name]; return d and d.inventory_image or "blank.png" end
local ICON = {
	plant_recovery = function() return badged("rockmech_icon_plant.png", "plus") end,
	plant_misplaced = function() return badged("rockmech_icon_plant.png", "minus") end,
	crusher_rate = function() return badged("rockmech_icon_crusher.png", "up") end,
	conveyor_rate = function() return badged("rockmech_icon_belt.png", "up") end,
	maintenance = function() return badged(item_img("rockmech:truck_item"), "up") end,
	ore_recovery = function() return badged(item_img("rockmech:xrf"), "plus") end,
	eco_driving = function() return badged(item_img("rockmech:truck_item"), "minus") end,
	blast_design = function() return badged(item_img("rockmech:detonator"), "plus") end,
	support_method = function() return badged(item_img("rockmech:rock_bolt"), "plus") end,
	skilled_miner = function() return badged(item_img("rockmech:rock_drill"), "up") end,
}

local BY_KEY = {}
for _, it in ipairs(ITEMS) do BY_KEY[it.key] = it end

local function cost_of(it, lv) return it.base * lv end
local function secs_of(it, lv) return it.minutes * 60 * lv end
local function mmss(s) s = math.max(0, math.ceil(s)); return ("%d:%02d"):format(math.floor(s / 60), s % 60) end
local function money_text(v) return ("%s$%.0f"):format(v < 0 and "−" or "", math.abs(v)) end

---------------------------------------------------------------------------
-- 研究員：機械技工（站著，旁邊工具箱）、駐點地質師（坐著，桌上岩樣和文件）
---------------------------------------------------------------------------

local NPCS = {
	mechanic = {entity = "rockmech:npc_mechanic", title = TR("Mechanic"), color = "#ffb060", tint = "#c06010", sit = false},
	geologist = {entity = "rockmech:npc_geologist", title = TR("Site geologist"), color = "#e0d0a0", tint = "#806040", sit = true},
}

-- 進行中的研發：每位研究員各自一項（同一組的機械技工、駐點地質師可以同時研發）。
-- mod storage 的 research_job:<研究員>:<帳戶> = {key, level, left（剩幾秒）, total（總秒數）}
local function job_of(acc, who)
	local s = storage:get_string(JOB .. who .. ":" .. acc)
	return s ~= "" and core.deserialize(s) or nil
end
local function set_job(acc, who, job) storage:set_string(JOB .. who .. ":" .. acc, job and core.serialize(job) or "") end
-- 舊版（一組只有一項）：research_job:<帳戶> 搬到那個項目的研究員名下
core.after(0, function()
	for _, k in ipairs(storage:get_keys()) do
		local rest = k:match("^" .. JOB .. "(.+)$")
		local first = rest and rest:match("^([^:]+):")
		if rest and not (first and NPCS[first]) then
			local job = core.deserialize(storage:get_string(k))
			local it = job and BY_KEY[job.key]
			if it then set_job(rest, it.who, job) end
			storage:set_string(k, "")
		end
	end
end)

---------------------------------------------------------------------------
-- 修車（機械技工）：全組耐久不到 100% 的車（vehicles.lua 存在 vhp:<編號>），付費派技工去修，
-- 費用 = 車價 × REPAIR_COST × 損壞比例、時間 = REPAIR_SECS × 損壞比例，一次修一台，組員在線上才倒數
---------------------------------------------------------------------------

local REPAIR_COST, REPAIR_SECS = 0.2, 5 * 60
local REPAIR = "repair_job:"         -- repair_job:<帳戶> = {uid, kind, left, total}
local function price_of(kind)
	local item = kind:find("^rockmech:") and kind or ("rockmech:" .. kind .. "_item")     -- 設施（facilitydamage.lua）的 kind 是方塊名稱
	for _, it in ipairs(cfg.shop) do if it.item == item then return rockmech.shop_price(it) end end      -- 鋼材價會波動（market.lua）
	return 10000
end
local function damaged_list(acc)
	local out = {}
	for _, k in ipairs(storage:get_keys()) do
		local uid = k:match("^vhp:(.+)$")
		if uid then
			local d = core.deserialize(storage:get_string(k))
			if d and d.owner == acc and (d.hp or 100) < 100 then
				d.uid = uid
				out[#out + 1] = d
			end
		end
		-- 受損的設施（facilitydamage.lua 存在 fdmg:<位置>）：uid 用 f:<位置>
		local fp = k:match("^fdmg:(.+)$")
		if fp then
			local d = core.deserialize(storage:get_string(k))
			if d and d.owner == acc and (d.hp or 100) < 100 then
				d.uid = "f:" .. fp
				out[#out + 1] = d
			end
		end
	end
	table.sort(out, function(a, b) return (a.hp or 0) < (b.hp or 0) end)
	return out
end
local function repair_quote(d)
	local frac = 1 - math.max(0, d.hp or 0) / 100
	return math.ceil(price_of(d.kind) * REPAIR_COST * frac), math.ceil(REPAIR_SECS * frac)
end
local function repair_job(acc)
	local s2 = storage:get_string(REPAIR .. acc)
	return s2 ~= "" and core.deserialize(s2) or nil
end
local function set_repair(acc, job) storage:set_string(REPAIR .. acc, job and core.serialize(job) or "") end
local function vname(kind)
	local d = rockmech.vehicles and rockmech.vehicles.TYPES[kind]
	if d then return d.short or d.desc end
	local nd = core.registered_nodes[kind]
	return nd and (nd.short_description or rockmech.desc_short(nd)) or kind
end

-- 進度條：底色、已完成的部分、百分比與倒數
local function bar(x, y, w, job)
	local total = job.total or job.left
	local frac = total > 0 and math.max(0, math.min(1, 1 - job.left / total)) or 1
	return ("box[%g,%g;%g,0.35;#2a2a2a]box[%g,%g;%g,0.35;#3fbf5f]label[%g,%g;%s]"):format(
		x, y, w, x, y, math.max(0.01, w * frac), x + w + 0.2, y + 0.18,
		E(S("@1%  @2 left", tostring(math.floor(frac * 100)), mmss(job.left))))
end
-- 格子裡的進度條：字寫在條上，不會超出格子
local function tile_bar(x, y, w, job)
	local total = job.total or job.left
	local frac = total > 0 and math.max(0, math.min(1, 1 - job.left / total)) or 1
	return ("box[%g,%g;%g,0.45;#2a2a2a]box[%g,%g;%g,0.45;#3fbf5f]label[%g,%g;%s]"):format(
		x, y, w, x, y, math.max(0.01, w * frac), x + 0.1, y + 0.22,
		E(S("@1%  @2 left", tostring(math.floor(frac * 100)), mmss(job.left))))
end

local viewing = {}          -- 玩家名稱 → 正在看哪位研究員

local function form(name, who)
	local acc = rockmech.account_of(name)
	local npc = NPCS[who]
	local job = job_of(acc, who)
	local head = rockmech.team_of(name) and S("@1  Team @2 funds: @3", S(npc.title), tostring(rockmech.team_of(name)), money_text(rockmech.money(name)))
		or S("@1  Funds: @2", S(npc.title), money_text(rockmech.money(name)))
	local out = {"formspec_version[6]size[15,16]", ("label[0.5,0.6;%s]"):format(core.formspec_escape(head))}
	if job then
		local it = BY_KEY[job.key]
		out[#out + 1] = ("label[0.5,1.2;%s]"):format(core.formspec_escape(
			S("Researching: @1 Lv@2 (progresses only while team members are online)", it and S(it.label) or job.key, tostring(job.level))))
	end
	-- 研發項目：一個項目一個圖示，下面名稱和等級格子；滑鼠移上去看說明，點一下開始研發
	local y = 2.0
	local col = 0
	local TW = 3.4                     -- 每格寬
	for i, it in ipairs(ITEMS) do
		if it.who == who then
			local lv = rockmech.research_level(acc, it.key)
			local maxed = lv >= it.max
			local x = 0.5 + col * TW
			local active = job and job.key == it.key
			-- 底框（正在研發：黃框；練滿：綠框）
			out[#out + 1] = ("box[%g,%g;%g,%g;%s]"):format(x - 0.1, y - 0.1, TW - 0.3, 3.8, active and "#806010" or maxed and "#2f5a2f" or "#2a2e34")
			out[#out + 1] = ("box[%g,%g;%g,%g;#1e2228]"):format(x, y, TW - 0.5, 3.6)
			local icon = ICON[it.key] and ICON[it.key]() or "blank.png"
			out[#out + 1] = ("image_button[%g,%g;1.8,1.8;%s;go_%d;]"):format(x + (TW - 0.5 - 1.8) / 2, y + 0.15, E(icon), i)
			-- 名稱、等級格子
			out[#out + 1] = ("label[%g,%g;%s]"):format(x + 0.15, y + 2.25, E(S(it.label)))
			local pw = math.min(0.42, (TW - 0.8) / it.max)
			for k = 1, it.max do
				out[#out + 1] = ("box[%g,%g;%g,0.22;%s]"):format(x + 0.15 + (k - 1) * pw, y + 2.6, pw - 0.06, k <= lv and "#f0c020" or "#4a4e54")
			end
			if active then out[#out + 1] = tile_bar(x + 0.15, y + 2.95, TW - 0.8, job) end
			-- 滑鼠移上去的說明
			local tip = {S(it.label) .. "  Lv" .. lv .. "/" .. it.max, S(it.desc), S("Now: @1", it.value(acc))}
			if maxed then tip[#tip + 1] = S("Max level")
			else
				tip[#tip + 1] = S("Next: Lv@1   @2   @3 min", tostring(lv + 1), money_text(cost_of(it, lv + 1)), ("%d"):format(secs_of(it, lv + 1) / 60))
				tip[#tip + 1] = active and S("Researching…") or job and S("Another item is being researched") or S("Click to start this research")
			end
			out[#out + 1] = ("tooltip[go_%d;%s;#101418;#ffffff]"):format(i, E(table.concat(tip, "\n")))
			col = col + 1
			if col >= 4 then col = 0; y = y + 4.1 end
		end
	end
	if col > 0 then y = y + 4.1 end
	-- 機械技工：修車
	if who == "mechanic" then
		local rj = repair_job(acc)
		out[#out + 1] = ("label[0.5,%g;%s]"):format(y + 0.5, E(S("Repairs: the team's damaged vehicles and facilities. Pay to send a mechanic")))
		y = y + 1.0
		if rj then
			out[#out + 1] = ("label[0.5,%g;%s]"):format(y + 0.2, E(S("Repairing: @1", vname(rj.kind))))
			out[#out + 1] = bar(4.0, y + 0.05, 7.0, rj)
			y = y + 0.7
		end
		local list = damaged_list(acc)
		if #list == 0 and not rj then
			out[#out + 1] = ("label[0.5,%g;%s]"):format(y + 0.2, E(S("No damaged vehicles")))
			y = y + 0.6
		end
		for i, d in ipairs(list) do
			if i > 5 then break end
			if not (rj and rj.uid == d.uid) then
				local cost, secs = repair_quote(d)
				local p = d.pos and ("(%d, %d, %d)"):format(d.pos.x, d.pos.y, d.pos.z) or ""
				out[#out + 1] = ("label[0.5,%g;%s]"):format(y + 0.4, E(("%s  %s  %s"):format(vname(d.kind),
					(d.hp or 0) <= 0 and S("Wrecked") or S("Condition @1%", ("%d"):format(math.floor(d.hp + 0.5))), p)))
				out[#out + 1] = ("label[8.6,%g;%s]"):format(y + 0.4, core.formspec_escape(("%s　%s"):format(money_text(cost), mmss(secs))))
				if not rj then out[#out + 1] = ("button[13.0,%g;1.8,0.8;fix_%s;%s]"):format(y, d.uid, E(S("Repair"))) end
				y = y + 0.9
			end
		end
	end
	-- 駐點地質師：雇用（跟著人跑的地質學家）、進修考試（knowledge.lua）
	if who == "geologist" and rockmech.knowledge_form then
		local fs, h = rockmech.knowledge_form(name, y + 0.4)
		out[#out + 1] = fs
		y = y + 0.4 + h
	end
	out[1] = ("formspec_version[6]size[15,%g]"):format(y + 0.6)     -- 高度跟著內容；沒有關閉鈕，點畫面外就關
	return table.concat(out)
end
rockmech.research_form_test = form      -- 測試用

local function open(player, who)
	local name = player:get_player_name()
	viewing[name] = who
	core.show_formspec(name, FORM, form(name, who))
end

local function tell(acc, msg)
	for _, m in ipairs(rockmech.account_members(acc)) do rockmech.notify(m, S("[Research lab] @1", msg)) end
end

core.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= FORM then return end
	local name = player:get_player_name()
	local who = viewing[name]
	if fields.quit then viewing[name] = nil; return true end
	if fields.hire and rockmech.knowledge_hire then
		rockmech.knowledge_hire(name)
		if who then core.show_formspec(name, FORM, form(name, who)) end
		return true
	end
	for key in pairs(fields) do
		local ab = key:match("^study_(%w+)$")
		if ab and rockmech.knowledge_exam then
			viewing[name] = nil
			rockmech.knowledge_exam(player, ab)
			return true
		end
	end
	for key in pairs(fields) do
		local uid = key:match("^fix_(.+)$")
		if uid and who == "mechanic" then
			local acc = rockmech.account_of(name)
			local d
			for _, x in ipairs(damaged_list(acc)) do if x.uid == uid then d = x end end
			if repair_job(acc) then
				rockmech.notify(name, S("[Mechanic] Already repairing another vehicle; one at a time"))
			elseif d then
				local cost, secs = repair_quote(d)
				if rockmech.money(name) < cost then
					rockmech.notify(name, S("[Mechanic] Not enough money: repairing this one costs @1", money_text(cost)))
				else
					rockmech.add_money(name, -cost)
					set_repair(acc, {uid = uid, kind = d.kind, left = secs, total = secs})
					tell(acc, S("@1 sent a mechanic to repair the @2 (@3, @4; progresses only while team members are online)", name, vname(d.kind), money_text(cost), mmss(secs)))
				end
			end
			core.show_formspec(name, FORM, form(name, who))
			return true
		end
	end
	for key in pairs(fields) do
		local i = tonumber(key:match("^go_(%d+)$"))
		local it = i and ITEMS[i]
		if it and it.who == who then
			local acc = rockmech.account_of(name)
			local lv = rockmech.research_level(acc, it.key)
			local cost = cost_of(it, lv + 1)
			if job_of(acc, who) then
				rockmech.notify(name, S("[Research lab] Already researching another item; a researcher can only work on one item at a time"))
			elseif lv >= it.max then
				rockmech.notify(name, S("[Research lab] Already at the maximum level"))
			elseif not rockmech.has_account(name) then
				rockmech.notify(name, S("[Research lab] You are not in a team yet, so you have no funds"))
			elseif rockmech.money(name) < cost then
				rockmech.notify(name, S("[Research lab] Not enough money: @1 Lv@2 costs @3", S(it.label), tostring(lv + 1), money_text(cost)))
			else
				rockmech.add_money(name, -cost)
				set_job(acc, who, {key = it.key, level = lv + 1, left = secs_of(it, lv + 1), total = secs_of(it, lv + 1)})
				tell(acc, S("@1 started researching @2 Lv@3 (@4, @5 min; progresses only while team members are online)", name, S(it.label), tostring(lv + 1), money_text(cost), ("%d"):format(secs_of(it, lv + 1) / 60)))
				core.log("action", ("[rockmech] research %s %s Lv%d by %s ($%d)"):format(acc, it.key, lv + 1, name, cost))
			end
			if who then core.show_formspec(name, FORM, form(name, who)) end
			return true
		end
	end
	return true
end)

-- 進度：每秒，有組員在線上的帳戶才扣時間
local tick = 0
core.register_globalstep(function(dtime)
	tick = tick + dtime
	if tick < 1 then return end
	local dt = tick
	tick = 0
	local accs = {}
	for _, p in ipairs(core.get_connected_players()) do
		local acc = rockmech.account_of(p:get_player_name())
		accs[acc] = true
	end
	for acc in pairs(accs) do
		local any = false
		for who in pairs(NPCS) do
			local job = job_of(acc, who)
			if job then
				any = true
				job.left = job.left - dt
				if job.left <= 0 then
					local it = BY_KEY[job.key]
					local before = it and it.value(acc)
					rockmech.research_set(acc, job.key, job.level)
					set_job(acc, who, nil)
					if it then tell(acc, S("@1 reached Lv@2 (@3 → @4)", S(it.label), tostring(job.level), before, it.value(acc))) end
					core.log("action", ("[rockmech] research %s %s reached Lv%d"):format(acc, job.key, job.level))
					for _, m in ipairs(rockmech.account_members(acc)) do
						core.sound_play("rockmech_coin", {to_player = m, gain = 0.6}, true)
					end
				else
					set_job(acc, who, job)
				end
			end
		end
		-- 修車
		local rj = repair_job(acc)
		if rj then
			any = true
			rj.left = rj.left - dt
			if rj.left <= 0 and rj.uid:find("^f:") then
				-- 設施修好
				set_repair(acc, nil)
				local p = core.string_to_pos(rj.uid:sub(3))
				if p and rockmech.facility_repaired then rockmech.facility_repaired(p) end
				tell(acc, S("@1 repaired; condition back to 100%", vname(rj.kind)))
			elseif rj.left <= 0 then
				set_repair(acc, nil)
				storage:set_string("vhp:" .. rj.uid, "")
				local V = rockmech.vehicles
				local e = V and V.by_uid[rj.uid]
				if e and e.object:get_pos() then
					e.hp = 100
					V.update_infotext(e)
					if V.update_hud then V.update_hud(e) end
				end
				tell(acc, S("@1 repaired; condition back to 100%", vname(rj.kind)))
			else
				set_repair(acc, rj)
			end
		end
		-- 開著研究畫面的人跟著更新進度條和倒數
		if any then
			for _, m in ipairs(rockmech.account_members(acc)) do
				if viewing[m] then core.show_formspec(m, FORM, form(m, viewing[m])) end
			end
		end
	end
end)
core.register_on_leaveplayer(function(player) viewing[player:get_player_name()] = nil end)

for who, npc in pairs(NPCS) do
	core.register_entity(npc.entity, {
		initial_properties = {
			physical = true, collisionbox = npc.sit and {-0.3, 0, -0.3, 0.3, 1.2, 0.3} or {-0.3, 0, -0.3, 0.3, 1.7, 0.3},
			visual = "mesh", mesh = "character.b3d", textures = {rockmech.npc_skin(who)},      -- 造型：npc_skins.lua
			nametag = S(npc.title), nametag_color = npc.color, static_save = false,
		},
		on_activate = function(self)
			self.object:set_armor_groups({immortal = 1})
			self.object:set_yaw(0)
			rockmech.npc_dress(self.object, who)
			if npc.sit then self.object:set_animation({x = 81, y = 160}, 30)
			else self.object:set_animation({x = 0, y = 79}, 30) end
		end,
		on_rightclick = function(self, clicker) if rockmech.hand_first and rockmech.hand_first(clicker) then return end if clicker and clicker:is_player() then open(clicker, who) end end,
		on_punch = function() return true end,
	})
	-- 由 career.lua 的 ensure_vendors 補人（攤主位置清單裡 kind = who）
	rockmech.career_npcs[who] = npc
end

---------------------------------------------------------------------------
-- 研究帳篷：貨櫃辦公室南邊、跟它和破碎站排成一排，面向西（礦區那邊），7×7 的帳篷，白底藍條棚布
---------------------------------------------------------------------------

-- 帳篷中心：L 形的轉角（貨櫃辦公室在東邊 z −16..−4 面向西；帳篷在它南邊、面向北，講堂在帳篷西邊）
local RES_DX, RES_Z = 23, -28
core.register_node("rockmech:tent_canvas_research", {
	description = S("Tent canvas"), is_ground_content = false, groups = {not_in_creative_inventory = 1},
	tiles = {"[fill:16x16:#eef2f4^[fill:16x2:0,5:#2f6fbf^[fill:16x2:0,12:#2f6fbf"},
})

-- 擺設：{dx, dz, 高度層, 節點}（帳篷的本地座標：dz 朝正面、dx 往右；career_placer 轉成面向北）
local PROPS = {
	-- 機械技工（西半邊）：工作台、工具箱、木箱、油桶
	{-2, 1, 1, "table"}, {-1, 1, 1, "table"}, {-2, 1, 2, "toolbox"}, {-3, -2, 1, "crate"}, {-3, -2, 2, "crate"},
	{-3, -1, 1, "barrel"}, {-2, -2, 1, "shelf"},
	-- 駐點地質師（東半邊）：書桌、椅子、文件、岩樣（木箱）、工具架當書架
	{1, 1, 1, "table"}, {2, 1, 1, "table"}, {2, 1, 2, "papers"}, {2, 0, 1, "chair"},
	{3, -2, 1, "shelf"}, {3, -2, 2, "shelf"}, {2, -2, 1, "crate"}, {1, 1, 2, "helmets"},
}

local function ground_y(x, z)
	for y = 40, -30, -1 do
		local n = core.get_node({x = x, y = y, z = z}).name
		if n ~= "air" and n ~= "ignore" then return y end
	end
end

local function flag_of(x0) return "research_site:" .. x0 end
function rockmech.career_build_research(x0)
	storage:set_string(flag_of(x0), "1")       -- 這座營地蓋過研究帳篷了（下面補蓋時看這個）
	local cx, cz = x0 + RES_DX, RES_Z
	local y = ground_y(cx, cz) or 0
	local set, at, yaw = rockmech.career_placer(cx, cz, y, "north")
	for _, s in ipairs({{-3, -3}, {3, -3}, {-3, 3}, {3, 3}}) do
		for h = 1, 3 do set(s[1], h, s[2], "rockmech:tent_pole") end
	end
	for layer = 0, 2 do
		local r = 3 - layer
		for x = -r, r do for z = -r, r do set(x, 4 + layer, z, "rockmech:tent_canvas_research") end end
	end
	for _, p in ipairs(PROPS) do set(p[1], p[3], p[2], "rockmech:camp_" .. p[4]) end
	local key = rockmech.career_vendor_spots
	local list = core.deserialize(storage:get_string(key)) or {}
	local m, g = at(-2, 0, 0), at(2, 0, 0)
	list[#list + 1] = {kind = "mechanic", pos = {x = m.x, y = y + 0.5, z = m.z}, yaw = yaw}
	list[#list + 1] = {kind = "geologist", pos = {x = g.x, y = y + 1.05, z = g.z}, yaw = yaw}
	storage:set_string(key, core.serialize(list))
end

-- 已經蓋好的營地：舊配置的搬到新配置（career.lua 的 career_relayout），沒有研究帳篷的補上
core.after(2, function()
	local sites = {}
	if storage:get_string("career_site") == "2" then sites[#sites + 1] = {x0 = cfg.career_camp_dx} end
	if rockmech.team_site_x then
		for i = 1, cfg.career_teams do
			local t = tostring(i)
			if storage:get_string("team_site:" .. t) == "1" then
				sites[#sites + 1] = {x0 = rockmech.team_site_x(t)}
			end
		end
	end
	for _, s in ipairs(sites) do
		local old = storage:get_string("camp_layout2:" .. s.x0) == ""
		if old or storage:get_string(flag_of(s.x0)) == "" then
			local a, b = rockmech.career_area(s.x0)
			core.emerge_area(a, b, function(_, _, rem)
				if rem > 0 then return end
				-- 載入完再看一次：新世界的營地這時可能剛蓋好（新配置），不要再搬一次
				if storage:get_string("camp_layout2:" .. s.x0) == "" then rockmech.career_relayout(s.x0)   -- 舊配置：搬到新配置（會一起蓋研究帳篷）
				elseif storage:get_string(flag_of(s.x0)) == "" then rockmech.career_build_research(s.x0) end
			end)
		end
	end
end)
