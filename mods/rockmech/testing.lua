-- rockmech/testing.lua
-- 現場的岩石強度試驗（工具室管理員賣）：
--   施密特錘（rockmech:schmidt_hammer）：對岩面左鍵，敲 10 次讀回彈值 R（取中位數），
--     用 Katz 等人（2000）的經驗式換算單軸抗壓強度：UCS ≈ 2.208 · e^(0.067 R)（MPa）。
--     遊戲裡反過來：由這一格岩石的 UCS 算 R，每次敲加一點散布（± 2）。
--   點荷重試驗機（rockmech:point_load）：對地上的岩芯箱右鍵，每一段岩芯（同一種岩性連續的一段）做 3 次試驗，
--     讀點荷重強度指數 Is(50)，用 UCS ≈ K · Is(50)（K = 22，ISRM 建議的範圍 20–25）換算。每次試驗散布 ± 10 %。
-- 試驗量的是完整岩石（實驗室尺度）的強度：遊戲裡用的是 lithology 的 UCS ÷ 相似比 N（rockmech_model_scale）。
-- 岩性名稱要有岩體分類能力才看得到（knowledge.lua），強度數字就是儀器讀數，人人看得到。

local cfg = rockmech.cfg
local HAMMER, PLT = "rockmech:schmidt_hammer", "rockmech:point_load"
local PLT_FORM = "rockmech:point_load"
local K_PLT = 22
local function see(name, ab) return not rockmech.can_see or rockmech.can_see(name, ab) end
local function ucs_of(key)
	local l = cfg.lithologies[key]
	return l and l.ucs / (cfg.model_scale or 1)
end
local function tell(name, msg) core.chat_send_player(name, msg) end

-- 回彈值 R ↔ UCS（Katz et al. 2000）
local function r_of_ucs(ucs) return math.log(math.max(2.3, ucs) / 2.208) / 0.067 end
local function ucs_of_r(R) return 2.208 * math.exp(0.067 * R) end

core.register_tool(HAMMER, {
	description = "施密特錘 Schmidt hammer\n對岩面左鍵：敲 10 次讀回彈值 R，換算單軸抗壓強度（Katz 2000：UCS ≈ 2.21·e^(0.067R)）",
	inventory_image = "[fill:16x16:#00000000^[fill:4x12:6,2:#c8c8c0^[fill:4x3:6,1:#303030^[fill:6x3:5,12:#2050a0",
	on_use = function(itemstack, user, pointed)
		if not (user and user:is_player()) or pointed.type ~= "node" then return itemstack end
		local name = user:get_player_name()
		local node = core.get_node(pointed.under)
		local lith = rockmech.lith_of_node[node.name]
		if not lith then tell(name, "[施密特錘] 要敲在完整的岩面上（碎石、土敲不出讀數）"); return itemstack end
		local R0 = r_of_ucs(ucs_of(lith.name))
		local rs = {}
		for i = 1, 10 do rs[i] = math.floor(R0 + (math.random() + math.random() + math.random() - 1.5) * 2.6 + 0.5) end
		table.sort(rs)
		local med = (rs[5] + rs[6]) / 2
		local who = see(name, "rockmass") and (lith.description or ""):gsub("\n.*", "") or "這裡的岩石"
		tell(name, ("[施密特錘] %s %s：回彈值 %s → 中位數 R = %.1f → UCS ≈ 2.21·e^(0.067R) = %.0f MPa"):format(
			who, core.pos_to_string(pointed.under), table.concat(rs, " "), med, ucs_of_r(med)))
		core.sound_play("default_dig_cracky", {pos = pointed.under, gain = 0.5, max_hear_distance = 12}, true)
		return itemstack
	end,
})

-- 點荷重：岩芯箱那個鑽孔的岩芯，一段一段（同一種岩性連續）做試驗
local function plt_form(name, pos)
	local m = core.get_meta(pos)
	local acc, n = m:get_string("acc"), m:get_int("n")
	local b = rockmech.find_borehole and rockmech.find_borehole(acc, n)
	local label = rockmech.borehole_label and rockmech.borehole_label(acc, n) or ("BH-" .. n)
	local out = {"formspec_version[6]size[12,9]",
		("label[0.4,0.5;%s]"):format(core.formspec_escape(("點荷重試驗：%s 的岩芯（每段 3 次，UCS ≈ %d · Is(50)）"):format(label, K_PLT)))}
	if not (b and b.rows and #b.rows > 0) then
		out[#out + 1] = "label[0.4,1.3;這箱沒有岩芯資料]"
	else
		local segs = {}
		for i, r in ipairs(b.rows) do
			local last = segs[#segs]
			if last and last.lith == r.lith then last.to = i else segs[#segs + 1] = {lith = r.lith, from = i - 1, to = i} end
		end
		out[#out + 1] = "tablecolumns[text;text;text;text;text]"
		local cells = {"深度 (m)", "岩芯", "Is(50) 三次 (MPa)", "平均 Is(50)", "UCS ≈ K·Is(50)"}
		for _, sgm in ipairs(segs) do
			local ucs = ucs_of(sgm.lith)
			local lab = see(name, "rockmass") and (rockmech.lith_label and rockmech.lith_label(sgm.lith) or sgm.lith) or "岩樣"
			if not ucs then
				cells[#cells + 1], cells[#cells + 2] = ("%d–%d"):format(sgm.from, sgm.to), lab
				cells[#cells + 1], cells[#cells + 2], cells[#cells + 3] = "（碎石，取不到岩樣）", "", ""
			else
				local is, sum = {}, 0
				for k = 1, 3 do
					is[k] = ucs / K_PLT * (1 + (math.random() * 2 - 1) * 0.1)
					sum = sum + is[k]
				end
				local avg = sum / 3
				cells[#cells + 1] = ("%d–%d"):format(sgm.from, sgm.to)
				cells[#cells + 1] = lab
				cells[#cells + 1] = ("%.2f  %.2f  %.2f"):format(is[1], is[2], is[3])
				cells[#cells + 1] = ("%.2f"):format(avg)
				cells[#cells + 1] = ("%.0f MPa"):format(K_PLT * avg)
			end
		end
		for i, c in ipairs(cells) do cells[i] = core.formspec_escape(c) end
		out[#out + 1] = "table[0.4,1.0;11.2,6.6;plt;" .. table.concat(cells, ",") .. ";0]"
		out[#out + 1] = "label[0.4,8.0;Is(50)：直徑 50 mm 岩芯的點荷重強度指數。每次按「重做」是新的一組試驗（試體不同，讀數會散布）]"
	end
	out[#out + 1] = "button[0.4,8.3;2.6,0.6;again;重做]"
	out[#out + 1] = "button_exit[9,8.3;2.6,0.6;close;關閉]"
	return table.concat(out)
end
local viewing = {}
core.register_craftitem(PLT, {
	description = ("點荷重試驗機 Point load tester\n對地上的岩芯箱右鍵：每段岩芯做 3 次試驗，讀 Is(50)，UCS ≈ %d·Is(50)"):format(K_PLT),
	inventory_image = "[fill:16x16:#00000000^[fill:12x2:2,2:#606870^[fill:12x2:2,12:#606870^[fill:2x12:3,2:#404850^[fill:2x12:11,2:#404850^[fill:4x4:6,6:#d0a040",
	stack_max = 1,
	on_place = function(itemstack, placer, pointed)
		if pointed.type ~= "node" or not (placer and placer:is_player()) then return itemstack end
		local name = placer:get_player_name()
		if core.get_node(pointed.under).name ~= rockmech.COREBOX then
			tell(name, "[點荷重] 對地上的岩芯箱右鍵（先用岩芯鑽機鑽孔、把岩芯箱放在地上）")
			return itemstack
		end
		viewing[name] = vector.copy(pointed.under)
		core.show_formspec(name, PLT_FORM, plt_form(name, pointed.under))
		return itemstack
	end,
})
core.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= PLT_FORM then return end
	local name = player:get_player_name()
	if fields.quit then viewing[name] = nil; return true end
	local pos = viewing[name]
	if fields.again and pos and core.get_node(pos).name == rockmech.COREBOX then
		core.show_formspec(name, PLT_FORM, plt_form(name, pos))
	end
	return true
end)
core.register_on_leaveplayer(function(player) viewing[player:get_player_name()] = nil end)

rockmech.schmidt_r_of_ucs, rockmech.schmidt_ucs_of_r = r_of_ucs, ucs_of_r
