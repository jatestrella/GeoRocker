-- rockmech/coredrill.lua
-- 岩芯鑽探：拿著岩芯鑽機（$3,000，工具室管理員）對地面右鍵，往下鑽一個垂直孔，每公尺 SEC_PER_M 秒，最深 MAX_DEPTH m。
-- 鑽的時候要待在孔旁 STAY_R m 內、手上拿著鑽機，不然就停在那個深度。碰到空洞（開挖過的地方）或設施也停。
-- 每公尺記錄：岩性、品位（param2）、穿過的節理條數；RQD 由節理頻率 λ（前後 1 m 的平均，條/m）用
-- Priest & Hudson（1976）RQD = 100·e^(−0.1λ)·(0.1λ + 1) 換算（模型裡只有明確的節理，沒有次網格裂隙）。
-- 孔口留一根套管（BH-n，第 N 組），右鍵看柱狀圖；全組共用的鑽孔日誌在背包「我的組」頁。
-- 柱狀圖照看的人的知識能力顯示（knowledge.lua）：岩性、節理、RQD 要岩體分類，品位要品位判讀；能力之後學會，舊的紀錄也看得到。

local storage = rockmech.collapse.storage
local joints = rockmech.joints

local ITEM, CASING = "rockmech:core_drill", "rockmech:borehole"
local SEC_PER_M, MAX_DEPTH, STAY_R = 1, 30, 3
local LOG = "bh:"            -- mod storage：bh:<帳戶> = {{n, pos, depth, rows = {{lith, grade, joints}}}, ...}
local FORM, LIST = "rockmech:borehole", "rockmech:borehole_list"

local function see(name, ab) return not rockmech.can_see or rockmech.can_see(name, ab) end
local function logs_of(acc) return core.deserialize(storage:get_string(LOG .. acc)) or {} end
local function save_logs(acc, list) storage:set_string(LOG .. acc, core.serialize(list)) end

-- Priest & Hudson：節理頻率 λ（條/m）→ RQD（%）
local function rqd_of(lambda) return 100 * math.exp(-0.1 * lambda) * (0.1 * lambda + 1) end

---------------------------------------------------------------------------
-- 柱狀圖
---------------------------------------------------------------------------

local function lith_label(key)
	if key == "rubble" then return "碎石" end
	local l = rockmech.cfg.lithologies[key]
	return l and (l.description:match("（(.-)）") or l.description:match("%((.-)%)") or key) or key
end
local function lith_color(key)
	if key == "rubble" then return "#8a8070" end
	local l = rockmech.cfg.lithologies[key]
	return l and l.color or "#808080"
end

local function log_form(name, bh)
	local rm, gr = see(name, "rockmass"), see(name, "grade")
	local out = {"formspec_version[6]size[15,12.4]",
		("label[0.5,0.6;%s]"):format(core.formspec_escape(("BH-%d　孔口 (%d, %d, %d)　深 %d m%s"):format(bh.n, bh.pos.x, bh.pos.y, bh.pos.z, bh.depth,
			bh.stop and ("（" .. bh.stop .. "）") or ""))),
		"label[0.5,1.2;深度]label[3.0,1.2;柱狀]label[4.4,1.2;岩性]label[7.4,1.2;品位]label[9.6,1.2;節理]label[11.6,1.2;RQD]"}
	local rows = bh.rows or {}
	-- 節理頻率：前後 1 m 平均
	local function lambda(i)
		local s, n = 0, 0
		for j = math.max(1, i - 1), math.min(#rows, i + 1) do s = s + (rows[j].joints or 0); n = n + 1 end
		return n > 0 and s / n or 0
	end
	local H = 0.34
	for i, r in ipairs(rows) do
		local y = 1.5 + (i - 1) * H
		local is_ore = rockmech.cfg.ores[r.lith] ~= nil or (rockmech.cfg.lithologies[r.lith] or {}).ore ~= nil
		out[#out + 1] = ("label[0.5,%g;%d–%d m]"):format(y + H / 2, i - 1, i)
		out[#out + 1] = ("box[3.0,%g;1.0,%g;%s]"):format(y + 0.02, H - 0.04, rm and lith_color(r.lith) or "#707070")
		out[#out + 1] = ("label[4.4,%g;%s]"):format(y + H / 2, core.formspec_escape(rm and lith_label(r.lith) or "岩石"))
		local g = "—"
		if is_ore or r.grade then g = gr and r.grade and ("%.0f%%"):format(r.grade / 255 * 100) or (gr and "—" or "?") end
		out[#out + 1] = ("label[7.4,%g;%s]"):format(y + H / 2, core.formspec_escape(g))
		out[#out + 1] = ("label[9.6,%g;%s]"):format(y + H / 2, rm and tostring(r.joints or 0) or "?")
		out[#out + 1] = ("label[11.6,%g;%s]"):format(y + H / 2, rm and ("%.0f%%"):format(rqd_of(lambda(i))) or "?")
	end
	if not (rm and gr) then
		out[#out + 1] = ("label[0.5,%g;%s]"):format(1.6 + #rows * H, core.formspec_escape(
			"看不懂的欄位：岩性、節理、RQD 要「岩體分類」，品位要「品位判讀」（儀器、雇用地質學家或找大學教授進修）"))
	end
	out[#out + 1] = ("button_exit[6,%g;3,0.8;ok;關閉]"):format(math.max(2.4 + #rows * H, 3))
	return table.concat(out)
end

local function list_form(name)
	local acc = rockmech.account_of and rockmech.account_of(name) or name
	local list = logs_of(acc)
	local out = {"formspec_version[6]size[12,10]", ("label[0.5,0.6;%s]"):format(core.formspec_escape(("鑽孔日誌（%s，共 %d 孔）"):format(
		rockmech.account_label and rockmech.account_label(acc) or acc, #list)))}
	local y = 1.2
	for i = #list, math.max(1, #list - 9), -1 do
		local b = list[i]
		out[#out + 1] = ("button[0.5,%g;11,0.7;bh_%d;%s]"):format(y, i, core.formspec_escape(
			("BH-%d　(%d, %d, %d)　深 %d m%s"):format(b.n, b.pos.x, b.pos.y, b.pos.z, b.depth, b.by and ("　" .. b.by) or "")))
		y = y + 0.8
	end
	if #list == 0 then out[#out + 1] = "label[0.5,1.6;還沒有鑽孔。到工具室管理員買岩芯鑽機，拿著對地面右鍵。]" end
	return table.concat(out)
end
function rockmech.borehole_list(name) core.show_formspec(name, LIST, list_form(name)) end

core.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= LIST then return end
	local name = player:get_player_name()
	local acc = rockmech.account_of and rockmech.account_of(name) or name
	for k in pairs(fields) do
		local i = tonumber(k:match("^bh_(%d+)$"))
		local b = i and logs_of(acc)[i]
		if b then core.show_formspec(name, FORM, log_form(name, b)); return true end
	end
	return true
end)

---------------------------------------------------------------------------
-- 孔口套管
---------------------------------------------------------------------------

core.register_node(CASING, {
	description = "鑽孔套管", drawtype = "nodebox", paramtype = "light", is_ground_content = false,
	tiles = {"[fill:16x16:#6a6e72^[fill:6x6:5,5:#202020", "[fill:16x16:#6a6e72", "[fill:16x16:#8a8e92^[fill:16x2:0,3:#c03020"},
	node_box = {type = "fixed", fixed = {-0.12, -0.5, -0.12, 0.12, -0.05, 0.12}},
	walkable = false, groups = {not_in_creative_inventory = 1, oddly_breakable_by_hand = 3},
	drop = "",
	on_rightclick = function(pos, node, clicker)
		if not (clicker and clicker:is_player()) then return end
		local meta = core.get_meta(pos)
		local acc, n = meta:get_string("acc"), meta:get_int("n")
		for _, b in ipairs(logs_of(acc)) do
			if b.n == n then core.show_formspec(clicker:get_player_name(), FORM, log_form(clicker:get_player_name(), b)); return end
		end
	end,
})

---------------------------------------------------------------------------
-- 鑽孔
---------------------------------------------------------------------------

local drilling = {}         -- 玩家名稱 → {pos（孔口那一格）, top（第一格 y）, rows, t}

local function finish(name, d, why)
	drilling[name] = nil
	if #d.rows == 0 then
		core.chat_send_player(name, "[岩芯鑽探] 沒鑽到東西" .. (why and ("（" .. why .. "）") or ""))
		return
	end
	local acc = rockmech.account_of and rockmech.account_of(name) or name
	local list = logs_of(acc)
	local n = #list + 1
	local bh = {n = n, pos = d.collar, depth = #d.rows, rows = d.rows, stop = why, by = name}
	list[n] = bh
	save_logs(acc, list)
	-- 孔口放一根套管（空的才放）
	local cp = d.collar
	local cn = core.get_node(cp)
	if cn.name == "air" or (core.registered_nodes[cn.name] or {}).buildable_to then
		core.set_node(cp, {name = CASING})
		local meta = core.get_meta(cp)
		meta:set_string("acc", acc)
		meta:set_int("n", n)
		meta:set_string("infotext", ("BH-%d（%s）深 %d m\n右鍵看柱狀圖"):format(n,
			rockmech.account_label and rockmech.account_label(acc) or acc, #d.rows))
	end
	if rockmech.account_members then
		for _, m in ipairs(rockmech.account_members(acc)) do
			core.chat_send_player(m, ("[岩芯鑽探] %s 鑽好 BH-%d，深 %d m%s（背包「我的組」→ 鑽孔日誌）"):format(name, n, #d.rows,
				why and ("，" .. why) or ""))
		end
	end
	core.show_formspec(name, FORM, log_form(name, bh))
end

local function start(player, pointed)
	local name = player:get_player_name()
	if drilling[name] then core.chat_send_player(name, "[岩芯鑽探] 正在鑽"); return end
	if pointed.type ~= "node" then return end
	local under = pointed.under
	if pointed.above.y ~= under.y + 1 then
		core.chat_send_player(name, "[岩芯鑽探] 要對著地面（方塊的上面）往下鑽")
		return
	end
	drilling[name] = {collar = pointed.above, x = under.x, z = under.z, y = under.y, rows = {}, t = 0}
	core.chat_send_player(name, ("[岩芯鑽探] 開始往下鑽（每公尺 %d 秒，最深 %d m）；走開或換掉手上的鑽機就停"):format(SEC_PER_M, MAX_DEPTH))
end

core.register_globalstep(function(dtime)
	for name, d in pairs(drilling) do
		local p = core.get_player_by_name(name)
		if not p then
			drilling[name] = nil
		else
			local pp = p:get_pos()
			if math.sqrt((pp.x - d.x) ^ 2 + (pp.z - d.z) ^ 2) > STAY_R or p:get_wielded_item():get_name() ~= ITEM then
				finish(name, d, "人離開了")
			else
				d.t = d.t + dtime
				-- 孔口冒岩粉
				core.add_particlespawner({amount = 3, time = 0.1, minpos = {x = d.x - 0.1, y = d.y + 0.5, z = d.z - 0.1},
					maxpos = {x = d.x + 0.1, y = d.y + 0.6, z = d.z + 0.1}, minvel = {x = -0.6, y = 0.8, z = -0.6},
					maxvel = {x = 0.6, y = 1.6, z = 0.6}, minacc = {x = 0, y = -5, z = 0}, maxacc = {x = 0, y = -5, z = 0},
					minexptime = 0.4, maxexptime = 0.8, minsize = 0.6, maxsize = 1.2, texture = "[fill:4x4:#a89c90"})
				while d.t >= SEC_PER_M and drilling[name] do
					d.t = d.t - SEC_PER_M
					local cell = {x = d.x, y = d.y - #d.rows, z = d.z}
					local node = core.get_node(cell)
					local lith = rockmech.lith_of_node[node.name]
					local row
					if lith then
						row = {lith = lith.name, grade = lith.ore and node.param2 or nil}
					elseif rockmech.is_rubble(node.name) then
						local base = rockmech.rubble_base[node.name]
						row = {lith = "rubble", grade = rockmech.ore_of_rubble[base] and node.param2 or nil}
					end
					if not row then
						finish(name, d, node.name == "air" and "鑽到空洞" or node.name == "ignore" and "地圖還沒載入" or "碰到設施")
					else
						-- 這 1 m 有幾條節理穿過鑽孔（格子的上、下兩個面，上面那個算這一格）
						local sets = rockmech.get_joint_sets()
						row.joints = (joints.face_joint(sets, cell.x, cell.y, cell.z, 2) and 1 or 0)
						d.rows[#d.rows + 1] = row
						if #d.rows >= MAX_DEPTH then finish(name, d, nil) end
					end
				end
			end
		end
	end
end)
core.register_on_leaveplayer(function(player) drilling[player:get_player_name()] = nil end)

core.register_tool(ITEM, {
	description = ("岩芯鑽機\n對著地面右鍵：往下鑽一個垂直孔取岩芯（每公尺 %d 秒、最深 %d m），鑽的時候不能走開\n"
		.. "得到鑽孔柱狀圖（岩性、品位、節理、RQD），全組共用鑽孔日誌"):format(SEC_PER_M, MAX_DEPTH),
	inventory_image = "[fill:16x16:#00000000^[fill:4x10:6,1:#d0a020^[fill:2x5:7,11:#808488^[fill:8x3:4,3:#303030^[fill:2x1:7,15:#c0c0c0",
	stack_max = 1,
	on_place = function(itemstack, placer, pointed) if placer then start(placer, pointed) end return itemstack end,
	on_use = function(itemstack, user, pointed) if user then start(user, pointed) end return itemstack end,
})
