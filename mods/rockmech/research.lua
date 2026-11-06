-- rockmech/research.lua
-- 研究所（經營模式）：每組營地貨櫃辦公室西邊一頂研究帳篷，裡面有「機械技工」「駐點地質師」。
--   右鍵研究員打開研發清單（像商店，之後可以改成天賦樹）：每個項目有等級，第 n 級要 基準價 × n、基準時間 × n。
--   研發用整組的錢、效果整組共用；每位研究員一次一項（不同研究員可以同時研發）。研發中的那一列有進度條和倒數。
--   進度只在該組有組員在線上時才走（每秒）；完成時通知全組。
--   等級存在 mod storage 的 research:<帳戶>:<項目>（crusher.lua 的 rockmech.research_level），
--   各項的效果由 crusher.lua 的 rockmech.eff_* 算：選礦場、破碎站、輸送帶照放置那一組的等級。
--   進行中的研發存在 research_job:<研究員>:<帳戶> = {key, level, left（剩幾秒）, total}。

local cfg = rockmech.cfg
if not cfg.career then return end
local storage = rockmech.collapse.storage

local FORM = "rockmech:research"
local JOB = "research_job:"

-- 研發項目。per：每級的效果（顯示用，實際算在 crusher.lua 的 rockmech.eff_*）
local ITEMS = {
	{key = "plant_recovery", who = "mechanic", label = "選礦回收率", max = 5, base = 20000, minutes = 10,
		desc = "選礦場的煤進精煤的比例 +1%",
		value = function(acc) return ("%.0f%%"):format(rockmech.eff_plant_recovery(acc) * 100) end},
	{key = "plant_misplaced", who = "mechanic", label = "降低精煤混入", max = 4, base = 20000, minutes = 10,
		desc = "選礦場的矸石混進精煤的比例 −2%",
		value = function(acc) return ("%.0f%%"):format(rockmech.eff_plant_misplaced(acc) * 100) end},
	{key = "crusher_rate", who = "mechanic", label = "破碎機改良", max = 5, base = 30000, minutes = 15,
		desc = "破碎站處理能力 +10%",
		value = function(acc) return ("×%.1f"):format(rockmech.eff_crusher_mult(acc)) end},
	{key = "conveyor_rate", who = "mechanic", label = "輸送帶改良", max = 5, base = 15000, minutes = 10,
		desc = "輸送帶運量 +10%（之後放的、已經放的都算）",
		value = function(acc) return ("×%.1f"):format(rockmech.eff_conveyor_mult(acc)) end},
	{key = "ore_recovery", who = "geologist", label = "品位控制", max = 5, base = 25000, minutes = 10,
		desc = "破碎站賣礦的回收率 +1%",
		value = function(acc)
			for _, ore in pairs(cfg.ores) do return ("%.0f%%"):format(rockmech.eff_ore_recovery(acc, ore) * 100) end
			return "—"
		end},
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
	mechanic = {entity = "rockmech:npc_mechanic", title = "機械技工", color = "#ffb060", tint = "#c06010", sit = false},
	geologist = {entity = "rockmech:npc_geologist", title = "駐點地質師", color = "#e0d0a0", tint = "#806040", sit = true},
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

-- 進度條：底色、已完成的部分、百分比與倒數
local function bar(x, y, w, job)
	local total = job.total or job.left
	local frac = total > 0 and math.max(0, math.min(1, 1 - job.left / total)) or 1
	return ("box[%g,%g;%g,0.35;#2a2a2a]box[%g,%g;%g,0.35;#3fbf5f]label[%g,%g;%s]"):format(
		x, y, w, x, y, math.max(0.01, w * frac), x + w + 0.2, y + 0.18,
		core.formspec_escape(("%d%%　剩 %s"):format(math.floor(frac * 100), mmss(job.left))))
end

local viewing = {}          -- 玩家名稱 → 正在看哪位研究員

local function form(name, who)
	local acc = rockmech.account_of(name)
	local npc = NPCS[who]
	local job = job_of(acc, who)
	local head = rockmech.team_of(name) and ("%s　第 %s 組資金 %s"):format(npc.title, rockmech.team_of(name), money_text(rockmech.money(name)))
		or ("%s　資金 %s"):format(npc.title, money_text(rockmech.money(name)))
	local out = {"formspec_version[6]size[15,10]", ("label[0.5,0.6;%s]"):format(core.formspec_escape(head))}
	local status
	if job then
		local it = BY_KEY[job.key]
		status = ("研發中：%s Lv%d（組員在線上時才會進行）"):format(it and it.label or job.key, job.level)
	else
		status = ("%s目前沒有研發中的項目。每位研究員同時研發一項，不同研究員可以同時進行。"):format(npc.title)
	end
	out[#out + 1] = ("label[0.5,1.2;%s]"):format(core.formspec_escape(status))
	out[#out + 1] = "label[0.5,2.0;項目]label[3.6,2.0;效果]label[8.6,2.0;目前 → 下一級]label[11.4,2.0;價格／時間]"
	local y = 2.6
	for i, it in ipairs(ITEMS) do
		if it.who == who then
			local lv = rockmech.research_level(acc, it.key)
			local maxed = lv >= it.max
			out[#out + 1] = ("label[0.5,%g;%s　Lv%d/%d]"):format(y + 0.4, core.formspec_escape(it.label), lv, it.max)
			out[#out + 1] = ("label[3.6,%g;%s]"):format(y + 0.4, core.formspec_escape(it.desc))
			local now = it.value(acc)
			local nxt = maxed and "已達最高" or ("→ Lv" .. (lv + 1))
			out[#out + 1] = ("label[8.6,%g;%s　%s]"):format(y + 0.4, core.formspec_escape(now), core.formspec_escape(nxt))
			if maxed then
				out[#out + 1] = ("label[11.4,%g;—]"):format(y + 0.4)
			else
				out[#out + 1] = ("label[11.4,%g;%s　%d 分鐘]"):format(y + 0.4, money_text(cost_of(it, lv + 1)), secs_of(it, lv + 1) / 60)
				if not job then out[#out + 1] = ("button[13.5,%g;1.3,0.8;go_%d;研發]"):format(y, i) end
			end
			y = y + 1.0
			if job and job.key == it.key then
				out[#out + 1] = bar(0.5, y - 0.1, 10.5, job)
				y = y + 0.5
			end
		end
	end
	-- 駐點地質師：雇用（跟著人跑的地質學家）、進修考試（knowledge.lua）
	if who == "geologist" and rockmech.knowledge_form then
		local fs, h = rockmech.knowledge_form(name, y + 0.4)
		out[#out + 1] = fs
		y = y + 0.4 + h
	end
	out[#out + 1] = ("button_exit[6,%g;3,0.8;close;關閉]"):format(math.max(y + 0.4, 8.6))
	return table.concat(out)
end

local function open(player, who)
	local name = player:get_player_name()
	viewing[name] = who
	core.show_formspec(name, FORM, form(name, who))
end

local function tell(acc, msg)
	for _, m in ipairs(rockmech.account_members(acc)) do core.chat_send_player(m, "[研究所] " .. msg) end
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
		local i = tonumber(key:match("^go_(%d+)$"))
		local it = i and ITEMS[i]
		if it and it.who == who then
			local acc = rockmech.account_of(name)
			local lv = rockmech.research_level(acc, it.key)
			local cost = cost_of(it, lv + 1)
			if job_of(acc, who) then
				core.chat_send_player(name, "[研究所] 已經在研發別的項目，研究員一次只能研發一項")
			elseif lv >= it.max then
				core.chat_send_player(name, "[研究所] 已達最高等級")
			elseif not rockmech.has_account(name) then
				core.chat_send_player(name, "[研究所] 你還沒分組，沒有資金")
			elseif rockmech.money(name) < cost then
				core.chat_send_player(name, ("[研究所] 錢不夠：%s Lv%d 要 %s"):format(it.label, lv + 1, money_text(cost)))
			else
				rockmech.add_money(name, -cost)
				set_job(acc, who, {key = it.key, level = lv + 1, left = secs_of(it, lv + 1), total = secs_of(it, lv + 1)})
				tell(acc, ("%s 開始研發 %s Lv%d（%s、%d 分鐘，組員在線上時才會進行）"):format(name, it.label, lv + 1, money_text(cost), secs_of(it, lv + 1) / 60))
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
					if it then tell(acc, ("%s 升到 Lv%d（%s → %s）"):format(it.label, job.level, before, it.value(acc))) end
					core.log("action", ("[rockmech] research %s %s reached Lv%d"):format(acc, job.key, job.level))
					for _, m in ipairs(rockmech.account_members(acc)) do
						core.sound_play("rockmech_coin", {to_player = m, gain = 0.6}, true)
					end
				else
					set_job(acc, who, job)
				end
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
			nametag = npc.title, nametag_color = npc.color, static_save = false,
		},
		on_activate = function(self)
			self.object:set_armor_groups({immortal = 1})
			self.object:set_yaw(0)
			rockmech.npc_dress(self.object, who)
			if npc.sit then self.object:set_animation({x = 81, y = 160}, 30)
			else self.object:set_animation({x = 0, y = 79}, 30) end
		end,
		on_rightclick = function(self, clicker) if clicker and clicker:is_player() then open(clicker, who) end end,
		on_punch = function() return true end,
	})
	-- 由 career.lua 的 ensure_vendors 補人（攤主位置清單裡 kind = who）
	rockmech.career_npcs[who] = npc
end

---------------------------------------------------------------------------
-- 研究帳篷：貨櫃辦公室南邊、跟它和破碎站排成一排，面向西（礦區那邊），7×7 的帳篷，白底藍條棚布
---------------------------------------------------------------------------

local RES_Z = -16           -- 帳篷中心的 z（貨櫃辦公室在 z −6..6）；x 跟貨櫃辦公室一樣
core.register_node("rockmech:tent_canvas_research", {
	description = "Tent canvas (帳篷布)", is_ground_content = false, groups = {not_in_creative_inventory = 1},
	tiles = {"[fill:16x16:#eef2f4^[fill:16x2:0,5:#2f6fbf^[fill:16x2:0,12:#2f6fbf"},
})

-- 擺設：{dx, dz, 高度層, 節點}（帳篷的本地座標：dz 朝正面、dx 往右；career_placer 轉成面向西）
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
	local cx, cz = x0 + rockmech.career_office_dx, RES_Z
	local y = ground_y(cx, cz) or 0
	local set, at = rockmech.career_placer(cx, cz, y)
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
	list[#list + 1] = {kind = "mechanic", pos = {x = m.x, y = y + 0.5, z = m.z}, yaw = math.pi / 2}
	list[#list + 1] = {kind = "geologist", pos = {x = g.x, y = y + 1.05, z = g.z}, yaw = math.pi / 2}
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
				if old then rockmech.career_relayout(s.x0)       -- 舊配置：搬到新配置（會一起蓋研究帳篷）
				else rockmech.career_build_research(s.x0) end
			end)
		end
	end
end)
