-- rockmech/coredrill.lua
-- 岩芯鑽探：手持岩芯鑽機（$3,000，工具室管理員）對地面右鍵往下鑽一個垂直孔，每公尺 SEC_PER_M 秒，最深 HAND_DEPTH m；
-- 要待在孔旁 STAY_R m 內、手上拿著鑽機。更深的孔用岩芯鑽探車（rockmech.coredrill_start，60 m）。碰到空洞或設施就停。
-- 鑽完：孔口留一根套管（混凝土墊、橘色套管、管蓋），岩芯裝進藍色岩芯箱放在孔口旁邊的地上。
--   岩芯箱比照碎石搬：左鍵捧起來（一次一個，不進背包），右鍵放下（可以疊起來當岩芯庫）。只有自己組（和老師）搬得動。
--   野帳本（$10）：拿著對岩芯箱右鍵判讀（每公尺 LOG_SEC_PER_M 秒，要待在 LOG_STAY m 內、手上拿著），記進野帳本；
--   左鍵打開野帳本看記過的孔（最多 BOOK_MAX 孔）。記下來的內容照判讀的人「當時」的能力：
--   沒有岩體分類就記不了岩性、節理、RQD，沒有品位判讀就記不了品位（學會之後重新判讀同一箱補上）。
-- 每公尺記錄：岩性、品位（param2）、穿過的節理條數；RQD 由節理頻率 λ（前後 1 m 的平均，條/m）用
-- Priest & Hudson（1976）RQD = 100·e^(−0.1λ)·(0.1λ + 1) 換算（模型裡只有明確的節理，沒有次網格裂隙）。
-- 孔口套管右鍵只看孔號和深度。舊版放在背包裡的岩芯箱（rockmech:core_box 物品）照樣看得到柱狀圖。
-- 知識能力見 knowledge.lua：岩性、節理、RQD 要岩體分類，品位要品位判讀。

local storage = rockmech.collapse.storage
local S = rockmech.S
local joints = rockmech.joints

local ITEM, CASING = "rockmech:core_drill", "rockmech:borehole"
local SEC_PER_M, HAND_DEPTH, STAY_R = 1, 10, 3      -- 手持鑽機最深 10 m；更深要用岩芯鑽探車（vehicle_corerig.lua，60 m）
local LOG = "bh:"            -- mod storage：bh:<帳戶> = {{n, pos, depth, rows = {{lith, grade, joints}}}, ...}
local FORM, BOOK_FORM = "rockmech:borehole", "rockmech:fieldbook"
local COREBOX, BOOK = "rockmech:corebox", "rockmech:fieldbook"
local COREBOX_OPEN = "rockmech:corebox_open"   -- 打開的岩芯箱（有人在看）：箱蓋掀起來、看得到岩芯
local corebox_rightclick                       -- 下面定義（打開岩芯箱那段）
local LOG_SEC_PER_M, LOG_STAY, BOOK_MAX = 0.5, 3, 20

local box_spot             -- 下面定義（岩芯箱那段）
local function see(name, ab) return not rockmech.can_see or rockmech.can_see(name, ab) end
local function logs_of(acc) return core.deserialize(storage:get_string(LOG .. acc)) or {} end
local function save_logs(acc, list) storage:set_string(LOG .. acc, core.serialize(list)) end
local function find_bh(acc, n)
	for _, b in ipairs(logs_of(acc)) do if b.n == n then return b end end
end
-- 鑽孔的名字：玩家取的名字，沒有就是 BH-n
local function label_of(b) return b and b.name and b.name ~= "" and b.name or ("BH-" .. (b and b.n or "?")) end
local function bh_label(acc, n)
	local b = find_bh(acc, n)
	return b and label_of(b) or ("BH-" .. n)
end
rockmech.borehole_label = bh_label
rockmech.find_borehole = find_bh          -- 點荷重試驗（testing.lua）讀岩芯
local NAME_MAX = 20          -- 名字最多幾個字

-- Priest & Hudson：節理頻率 λ（條/m）→ RQD（%）
local function rqd_of(lambda) return 100 * math.exp(-0.1 * lambda) * (0.1 * lambda + 1) end

---------------------------------------------------------------------------
-- 柱狀圖
---------------------------------------------------------------------------

local function lith_label(key)
	if key == "rubble" then return S("Rubble") end
	if key == "soil" then return S("Soil") end
	local l = rockmech.cfg.lithologies[key]
	return l and l.description and S(l.description) or key
end
rockmech.lith_label = lith_label
local function lith_color(key)
	if key == "rubble" then return "#8a8070" end
	if key == "soil" then return "#6e5236" end
	local l = rockmech.cfg.lithologies[key]
	return l and l.color or "#808080"
end

-- rm、gr：看得懂岩體、品位嗎（野帳本：判讀當時的能力；舊版岩芯箱：看的人現在的能力）
local function log_form(name, bh, rm, gr)
	if rm == nil then rm = see(name, "rockmass") end
	if gr == nil then gr = see(name, "grade") end
	local title = (bh.name and bh.name ~= "") and S("@1 (BH-@2)", label_of(bh), tostring(bh.n)) or label_of(bh)
	local out = {"formspec_version[6]size[15,12.4]",
		("label[0.5,0.6;%s]"):format(core.formspec_escape(bh.stop
			and S("@1   Collar (@2, @3, @4)   Depth @5 m (@6)", title, tostring(bh.pos.x), tostring(bh.pos.y), tostring(bh.pos.z), tostring(bh.depth), bh.stop)
			or S("@1   Collar (@2, @3, @4)   Depth @5 m", title, tostring(bh.pos.x), tostring(bh.pos.y), tostring(bh.pos.z), tostring(bh.depth)))),
		"label[0.5,1.2;" .. core.formspec_escape(S("Depth")) .. "]label[3.0,1.2;" .. core.formspec_escape(S("Log")) ..
		"]label[4.4,1.2;" .. core.formspec_escape(S("Lithology")) .. "]label[7.4,1.2;" .. core.formspec_escape(S("Grade")) ..
		"]label[9.6,1.2;" .. core.formspec_escape(S("Joints")) .. "]label[11.6,1.2;RQD]"}
	local rows = bh.rows or {}
	-- 節理頻率：前後 1 m 平均
	local function lambda(i)
		local s, n = 0, 0
		for j = math.max(1, i - 1), math.min(#rows, i + 1) do s = s + (rows[j].joints or 0); n = n + 1 end
		return n > 0 and s / n or 0
	end
	-- 資料列放在捲動區（60 m 的孔有 60 行，視窗放不下）；表頭和關閉鈕固定
	local H = 0.34
	local TOP, VIEW = 1.5, 9.5          -- 捲動區的上緣、高度
	local note = not (rm and gr)
	local content = #rows * H + (note and 0.6 or 0) + 0.1
	local scroll = content > VIEW
	out[#out + 1] = ("scroll_container[0,%g;14.4,%g;bh_scroll;vertical;0.1]"):format(TOP, VIEW)
	for i, r in ipairs(rows) do
		local y = (i - 1) * H
		local is_ore = rockmech.cfg.ores[r.lith] ~= nil or (rockmech.cfg.lithologies[r.lith] or {}).ore ~= nil
		out[#out + 1] = ("label[0.5,%g;%d–%d m]"):format(y + H / 2, i - 1, i)
		out[#out + 1] = ("box[3.0,%g;1.0,%g;%s]"):format(y + 0.02, H - 0.04, rm and lith_color(r.lith) or "#707070")
		out[#out + 1] = ("label[4.4,%g;%s]"):format(y + H / 2, core.formspec_escape(rm and lith_label(r.lith) or S("Rock")))
		local g = "—"
		if is_ore or r.grade then g = gr and r.grade and ("%.0f%%"):format(r.grade / 255 * 100) or (gr and "—" or "?") end
		out[#out + 1] = ("label[7.4,%g;%s]"):format(y + H / 2, core.formspec_escape(g))
		local soil = r.lith == "soil"
		out[#out + 1] = ("label[9.6,%g;%s]"):format(y + H / 2, soil and "—" or rm and tostring(r.joints or 0) or "?")
		out[#out + 1] = ("label[11.6,%g;%s]"):format(y + H / 2, soil and "—" or rm and ("%.0f%%"):format(rqd_of(lambda(i))) or "?")
	end
	if note then
		out[#out + 1] = ("label[0.5,%g;%s]"):format(0.1 + #rows * H + 0.2, core.formspec_escape(
			S("?: could not be interpreted at logging time. Lithology, joints and RQD need \"Rock mass classification\", grade needs \"Grade interpretation\"; once learned, log the core box again with the field notebook")))
	end
	out[#out + 1] = "scroll_container_end[]"
	if scroll then
		-- 捲軸：每格 0.1（scroll_container 的係數），拉到底剛好看到最後一行
		out[#out + 1] = ("scrollbaroptions[max=%d;smallstep=%d;largestep=%d]"):format(
			math.ceil((content - VIEW) * 10), math.floor(H * 10 * 3), math.floor(VIEW * 10))
		out[#out + 1] = ("scrollbar[14.4,%g;0.4,%g;vertical;bh_scroll;0]"):format(TOP, VIEW)
		out[#out + 1] = ("label[0.5,%g;%s]"):format(TOP + VIEW + 0.4, core.formspec_escape(S("Use the mouse wheel or the scrollbar on the right to scroll down")))
	end
	out[#out + 1] = ("button_exit[6,%g;3,0.8;ok;%s]"):format(TOP + VIEW + 0.3, core.formspec_escape(S("Close")))
	return table.concat(out)
end

---------------------------------------------------------------------------
-- 孔口套管
---------------------------------------------------------------------------

-- 孔口：一塊 1 m 見方的混凝土墊、中間一根橘色套管伸出地面、上面一個深灰色管蓋。
-- nodebox 的貼圖照每個盒子在方塊裡的位置裁切：側面貼圖由上而下是 管蓋（深灰）→ 套管（橘）→ 混凝土（灰），
-- 頂面是混凝土、中間管蓋的深灰
local CONCRETE, PIPE, CAP = "#a8a8a0", "#f07818", "#3a3a3a"
core.register_node(CASING, {
	description = S("Borehole casing"), drawtype = "nodebox", paramtype = "light", is_ground_content = false, sunlight_propagates = true,
	tiles = {
		("[fill:16x16:%s^[fill:16x1:0,0:#909088^[fill:16x1:0,15:#909088^[fill:5x5:6,6:%s^[fill:1x1:8,8:#5a5a5a"):format(CONCRETE, CAP),
		("[fill:16x16:%s"):format(CONCRETE),
		("[fill:16x16:%s^[fill:16x2:0,3:%s^[fill:16x9:0,5:%s^[fill:16x1:0,9:#d06010^[fill:16x2:0,14:%s"):format(PIPE, CAP, PIPE, CONCRETE),
	},
	node_box = {type = "fixed", fixed = {
		{-0.5, -0.5, -0.5, 0.5, -0.38, 0.5},           -- 混凝土墊
		{-0.1, -0.38, -0.1, 0.1, 0.2, 0.1},            -- 套管（伸出地面約 0.6 m）
		{-0.14, 0.2, -0.14, 0.14, 0.3, 0.14},          -- 管蓋
	}},
	selection_box = {type = "fixed", fixed = {-0.5, -0.5, -0.5, 0.5, 0.3, 0.5}},
	collision_box = {type = "fixed", fixed = {-0.5, -0.5, -0.5, 0.5, -0.38, 0.5}},
	groups = {not_in_creative_inventory = 1},
	drop = "",
	on_rightclick = function(pos, node, clicker)
		if not (clicker and clicker:is_player()) then return end
		rockmech.borehole_name_form(clicker, pos)
	end,
})

-- 鑽孔取名：對套管右鍵。自己組（和老師）可以改；名字存在鑽孔紀錄（bh:<帳戶>）裡，空白就回到 BH-n
local NAME_FORM = "rockmech:borehole_name"
local naming = {}            -- 玩家名稱 → 套管位置
local function casing_info(pos, acc, n, depth)
	core.get_meta(pos):set_string("infotext", S("@1 (@2) depth @3 m\nRight-click to name it", bh_label(acc, n),
		rockmech.account_label and rockmech.account_label(acc) or acc, tostring(depth)))
end
function rockmech.borehole_name_form(player, pos)
	local name = player:get_player_name()
	local meta = core.get_meta(pos)
	local acc, n, depth = meta:get_string("acc"), meta:get_int("n"), meta:get_int("depth")
	local b = find_bh(acc, n)
	if not b then rockmech.notify(name, S("[Borehole] No record found for this hole")); return end
	local mine = not rockmech.owner_ok or rockmech.owner_ok(acc, name)
	naming[name] = pos
	local out = {"formspec_version[6]size[10,5]",
		("label[0.5,0.6;%s]"):format(core.formspec_escape(S("@1 (BH-@2) depth @3 m   @4", label_of(b), tostring(n), tostring(depth),
			rockmech.account_label and rockmech.account_label(acc) or acc))),
		("label[0.5,1.2;%s]"):format(core.formspec_escape(S("The core is in the blue core box; right-click the core box with a field notebook to log it"))),
	}
	if mine then
		out[#out + 1] = ("field[0.5,2.2;9,0.8;bhname;%s;%s]"):format(
			core.formspec_escape(S("Borehole name (up to @1 characters, blank = BH-@2)", tostring(NAME_MAX), tostring(n))), core.formspec_escape(b.name or ""))
		out[#out + 1] = "field_close_on_enter[bhname;false]"
		out[#out + 1] = "button[0.5,3.6;4,0.8;save;" .. core.formspec_escape(S("Save name")) .. "]"
	else
		out[#out + 1] = "label[0.5,2.4;" .. core.formspec_escape(S("Another team's borehole; you cannot rename it")) .. "]"
	end
	out[#out + 1] = "button_exit[5.5,3.6;4,0.8;close;" .. core.formspec_escape(S("Close")) .. "]"
	core.show_formspec(name, NAME_FORM, table.concat(out))
end
core.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= NAME_FORM then return end
	local name = player:get_player_name()
	local pos = naming[name]
	if not pos then return true end
	if fields.quit and not fields.save and not fields.key_enter_field then naming[name] = nil; return true end
	if not (fields.save or fields.key_enter_field == "bhname") then return true end
	local meta = core.get_meta(pos)
	local acc, n = meta:get_string("acc"), meta:get_int("n")
	if core.get_node(pos).name ~= CASING or (rockmech.owner_ok and not rockmech.owner_ok(acc, name)) then return true end
	-- 名字：去掉換行和前後空白，最多 NAME_MAX 個字
	local s = (fields.bhname or ""):gsub("[%c]", " "):gsub("^%s+", ""):gsub("%s+$", "")
	local chars = {}
	for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
		if #chars >= NAME_MAX then break end
		chars[#chars + 1] = ch
	end
	s = table.concat(chars)
	local list = logs_of(acc)
	local b
	for _, x in ipairs(list) do if x.n == n then b = x end end
	if not b then return true end
	local old = label_of(b)
	b.name = s ~= "" and s or nil
	save_logs(acc, list)
	casing_info(pos, acc, n, meta:get_int("depth"))
	-- 附近（48 m 內）這一孔的岩芯箱跟著改名牌；遠處的在下次放下時更新
	for _, p in ipairs(core.find_nodes_in_area(vector.subtract(pos, 48), vector.add(pos, 48), {COREBOX})) do
		local m = core.get_meta(p)
		if m:get_string("acc") == acc and m:get_int("n") == n then
			m:set_string("infotext", S("Core box @1 (@2, depth @3 m)\nLeft-click to pick it up; right-click with a field notebook to log it", label_of(b),
				rockmech.account_label and rockmech.account_label(acc) or acc, tostring(m:get_int("depth"))))
		end
	end
	local msg = S("[Borehole] @1 renamed @2 to @3", name, old, label_of(b))
	for _, m in ipairs(rockmech.account_members and rockmech.account_members(acc) or {name}) do rockmech.notify(m, msg) end
	rockmech.borehole_name_form(player, pos)
	return true
end)
core.register_on_leaveplayer(function(player) naming[player:get_player_name()] = nil end)
-- 舊的套管：名牌補上「右鍵取名字」（一次）
core.register_lbm({
	label = "rockmech: 鑽孔套管名牌", name = "rockmech:borehole_name_tag", nodenames = {CASING}, run_at_every_load = false,
	action = function(pos)
		local m = core.get_meta(pos)
		if m:get_int("n") > 0 then casing_info(pos, m:get_string("acc"), m:get_int("n"), m:get_int("depth")) end
	end,
})

-- 舊版的岩芯箱（物品，鑽完放進背包）：留著讓已經拿到的人看得到柱狀圖
core.register_craftitem("rockmech:core_box", {
	description = S("Core box"), stack_max = 1, groups = {not_in_creative_inventory = 1},
	inventory_image = "[fill:16x16:#00000000^[fill:14x9:1,5:#8a6a3a^[fill:12x1:2,7:#5a4020^[fill:12x1:2,10:#5a4020"
		.. "^[fill:10x1:3,6:#6a6e72^[fill:10x1:3,9:#2a2a2a^[fill:10x1:3,12:#6a6e72",
	on_secondary_use = function(itemstack, user) return core.registered_items["rockmech:core_box"].on_use(itemstack, user) end,
	on_use = function(itemstack, user)
		if not (user and user:is_player()) then return end
		local meta = itemstack:get_meta()
		local acc, n = meta:get_string("acc"), meta:get_int("n")
		for _, b in ipairs(logs_of(acc)) do
			if b.n == n then core.show_formspec(user:get_player_name(), FORM, log_form(user:get_player_name(), b)); return end
		end
		rockmech.notify(user:get_player_name(), S("[Core box] No record found for this hole"))
	end,
})

---------------------------------------------------------------------------
-- 岩芯箱（地上的方塊）：比照碎石搬（career.lua 呼叫 rockmech.corebox_take、corebox_put）
---------------------------------------------------------------------------

local BLUE = "#2a62c8"
local function box_tex(top)
	if top then return ("[fill:16x16:%s^[fill:14x1:1,5:#1a3a80^[fill:14x1:1,10:#1a3a80"):format(BLUE) end
	return ("[fill:16x16:%s^[fill:16x2:0,0:#1a3a80"):format(BLUE)
end
rockmech.corebox_tex = box_tex(true)
rockmech.corebox_side_tex = box_tex(false)
core.register_node(COREBOX, {
	description = S("Core box"), drawtype = "nodebox", paramtype = "light", paramtype2 = "facedir",
	tiles = {box_tex(true), box_tex(false), box_tex(false)},
	node_box = {type = "fixed", fixed = {-0.45, -0.5, -0.3, 0.45, -0.5 + 0.4 / 3, 0.3}},
	-- 高度 0.4/3 m（實際的岩芯箱約 10 cm 高）；疊起來時一箱佔一格，上面那箱放在上一格
	selection_box = {type = "fixed", fixed = {-0.45, -0.5, -0.3, 0.45, -0.5 + 0.4 / 3, 0.3}},
	groups = {crumbly = 3, falling_node = 1, not_in_creative_inventory = 1},
	is_ground_content = false, drop = "",
	on_rightclick = function(...) return corebox_rightclick(...) end,
})
-- 打開的岩芯箱：箱蓋立在後面，上面看得到五條岩芯
local BOX_H = 0.4 / 3
local open_top = ("[fill:16x16:%s"):format(BLUE)
for k = 0, 4 do open_top = open_top .. ("^[fill:14x2:1,%d:#a09a90"):format(1 + k * 3) end
core.register_node(COREBOX_OPEN, {
	description = S("Core box"), drawtype = "nodebox", paramtype = "light", paramtype2 = "facedir",
	tiles = {open_top, box_tex(false), box_tex(false), box_tex(false), box_tex(false), "[fill:16x16:#3a72d8"},
	node_box = {type = "fixed", fixed = {
		{-0.45, -0.5, -0.3, 0.45, -0.5 + BOX_H, 0.3},
		{-0.45, -0.5 + BOX_H, 0.3, 0.45, -0.5 + BOX_H + 0.6, 0.34},
	}},
	selection_box = {type = "fixed", fixed = {-0.45, -0.5, -0.3, 0.45, -0.5 + BOX_H, 0.3}},
	groups = {crumbly = 3, falling_node = 1, not_in_creative_inventory = 1},
	is_ground_content = false, drop = "",
	on_rightclick = function(...) return corebox_rightclick(...) end,
})

-- 放一箱在 pos（空的那一格）：data = {acc, n, depth}
function rockmech.corebox_put(pos, data)
	local nd = core.registered_nodes[core.get_node(pos).name]
	if not (nd and nd.buildable_to) then return false end
	core.set_node(pos, {name = COREBOX, param2 = math.random(0, 3)})
	local meta = core.get_meta(pos)
	meta:set_string("acc", data.acc)
	meta:set_int("n", data.n)
	meta:set_int("depth", data.depth)
	meta:set_string("infotext", S("Core box @1 (@2, depth @3 m)\nRight-click to open it; left-click to pick it up; right-click with a field notebook to log it", bh_label(data.acc, data.n),
		rockmech.account_label and rockmech.account_label(data.acc) or data.acc, tostring(data.depth)))
	return true
end
-- 捧起 pos 那一箱：回傳 data，或 nil（不是自己組的）
function rockmech.corebox_take(pos, player)
	local meta = core.get_meta(pos)
	local data = {acc = meta:get_string("acc"), n = meta:get_int("n"), depth = meta:get_int("depth")}
	if rockmech.owner_ok and not rockmech.owner_ok(data.acc, player:get_player_name()) then return nil end
	for name, p in pairs(viewing_box) do
		if vector.equals(p, pos) then core.close_formspec(name, OPEN_FORM); viewing_box[name] = nil end
	end
	opened[core.hash_node_position(pos)] = nil
	core.remove_node(pos)
	core.check_for_falling({x = pos.x, y = pos.y + 1, z = pos.z})
	return data
end
rockmech.COREBOX = COREBOX

---------------------------------------------------------------------------
-- 打開岩芯箱：右鍵打開（旁人看到箱蓋掀起來、裡面一排排岩芯），自己看到一個大的岩芯箱介面：
--   藍色箱子、一槽一條 5 m 的岩芯、一次看 5 槽（25 m），更深的往下捲。
--   岩芯照實際岩石的顏色畫，節理是岩芯上的黑色裂縫、碎石段是碎塊；
--   自己有「岩體分類」才在每公尺下面標岩性、RQD、節理，有「品位判讀」才標品位（看的人「現在」的能力）。
---------------------------------------------------------------------------

local OPEN_FORM = "rockmech:corebox_open"
local PER_ROW, VIEW_ROWS = 5, 5            -- 一槽幾公尺、一次看幾槽
local opened = {}                          -- 方塊位置 → {玩家名稱 = true}
local viewing_box = {}                     -- 玩家名稱 → 方塊位置
local function is_corebox(name) return name == COREBOX or name == COREBOX_OPEN end
rockmech.is_corebox = is_corebox

local function close_for(name)
	local pos = viewing_box[name]
	viewing_box[name] = nil
	if not pos then return end
	local key = core.hash_node_position(pos)
	local set = opened[key]
	if set then set[name] = nil; if next(set) then return end end
	opened[key] = nil
	local node = core.get_node(pos)
	if node.name == COREBOX_OPEN then core.swap_node(pos, {name = COREBOX, param2 = node.param2}) end
end

-- 0..1 的假亂數（同一孔同一公尺每次一樣）：節理裂縫畫在那一公尺的哪裡、碎石段的碎塊
local function frac(n, i, k) local v = math.sin(n * 12.9898 + i * 78.233 + k * 37.719) * 43758.5453; return v - math.floor(v) end

local function corebox_form(name, bh, acc)
	local rm, gr = see(name, "rockmass"), see(name, "grade")
	local rows = bh.rows or {}
	local nrow = math.max(1, math.ceil(#rows / PER_ROW))
	local RH, X0, W = 2.2, 1.0, 17.6          -- 一槽高、岩芯起點、5 m 岩芯的長度
	local MW = W / PER_ROW
	local TOP, VIEW = 1.2, VIEW_ROWS * RH
	local out = {"formspec_version[6]size[20.4,14.6]",
		"style_type[label;font_size=*0.85]",
		("label[0.5,0.6;%s]"):format(core.formspec_escape(S("Core box @1 (@2)   Collar (@3, @4, @5)   Depth @6 m", label_of(bh),
			rockmech.account_label and rockmech.account_label(acc) or acc,
			tostring(bh.pos.x), tostring(bh.pos.y), tostring(bh.pos.z), tostring(bh.depth)))),
		("box[0.3,%g;19.4,%g;#2a62c8]"):format(TOP - 0.1, VIEW + 0.2),
		("scroll_container[0.3,%g;19.4,%g;cb_scroll;vertical;0.1]"):format(TOP, VIEW)}
	local function lambda(i)
		local s, c = 0, 0
		for j = math.max(1, i - 1), math.min(#rows, i + 1) do s = s + (rows[j].joints or 0); c = c + 1 end
		return c > 0 and s / c or 0
	end
	for k = 0, nrow - 1 do
		local y0 = k * RH
		-- 一槽：深藍色的槽，槽和槽之間是箱子的藍色隔板
		out[#out + 1] = ("box[0.2,%g;19.0,%g;#173d8a]"):format(y0 + 0.12, RH - 0.24)
		out[#out + 1] = ("label[0.3,%g;%s]"):format(y0 + 0.9, ("%d m"):format(k * PER_ROW))
		for m = 1, PER_ROW do
			local i = k * PER_ROW + m
			local r = rows[i]
			if not r then break end
			local x = X0 + (m - 1) * MW
			local cy, ch = y0 + 0.5, 0.58
			out[#out + 1] = ("label[%g,%g;%d]"):format(x, y0 + 0.36, i - 1)
			if r.lith == "rubble" or r.lith == "soil" then
				-- 碎石段、土：一堆碎塊（取出來的土不成柱）
				local px = x + 0.04
				local c = 0
				while px < x + MW - 0.15 do
					c = c + 1
					local w = 0.15 + 0.35 * frac(bh.n, i, c)
					local hh = ch * (0.45 + 0.5 * frac(bh.n, i, c + 50))
					w = math.min(w, x + MW - 0.04 - px)
					out[#out + 1] = ("box[%g,%g;%g,%g;%s]"):format(px, cy + ch - hh, w, hh, lith_color(r.lith))
					px = px + w + 0.06
				end
			else
				out[#out + 1] = ("box[%g,%g;%g,%g;%s]"):format(x + 0.04, cy, MW - 0.08, ch, lith_color(r.lith))
				-- 岩芯的亮面（圓柱的反光）
				out[#out + 1] = ("box[%g,%g;%g,0.08;#ffffff30]"):format(x + 0.04, cy + 0.12, MW - 0.08)
				for j = 1, math.min(r.joints or 0, 8) do
					local jx = x + 0.2 + (MW - 0.4) * frac(bh.n, i, j)
					out[#out + 1] = ("box[%g,%g;0.06,%g;#141414]"):format(jx, cy, ch)
				end
			end
			if rm then
				local is_ore = rockmech.cfg.ores[r.lith] ~= nil or (rockmech.cfg.lithologies[r.lith] or {}).ore ~= nil
				out[#out + 1] = ("label[%g,%g;%s]"):format(x + 0.06, y0 + 1.27, core.formspec_escape(lith_label(r.lith)))
				local info = r.lith == "soil" and "" or S("RQD @1%  joints @2", ("%.0f"):format(rqd_of(lambda(i))), tostring(r.joints or 0))
				if is_ore or r.grade then
					out[#out + 1] = ("label[%g,%g;%s]"):format(x + 0.06, y0 + 1.93, core.formspec_escape((gr and r.grade) and S("grade @1%", ("%.0f"):format(r.grade / 255 * 100)) or S("grade ?")))
				end
				out[#out + 1] = ("label[%g,%g;%s]"):format(x + 0.06, y0 + 1.6, core.formspec_escape(info))
			end
		end
		local last = math.min(#rows, (k + 1) * PER_ROW)
		if last == (k + 1) * PER_ROW then
			out[#out + 1] = ("label[%g,%g;%d]"):format(X0 + W - 0.2, y0 + 0.36, last)
		elseif last < (k + 1) * PER_ROW then
			out[#out + 1] = ("label[%g,%g;%s]"):format(X0 + (last - k * PER_ROW) * MW + 0.1, y0 + 0.9,
				core.formspec_escape(S("End of hole @1 m", tostring(#rows))))
		end
	end
	out[#out + 1] = "scroll_container_end[]"
	local bottom = TOP + VIEW + 0.3
	if nrow > VIEW_ROWS then
		out[#out + 1] = ("scrollbaroptions[max=%d;smallstep=%d;largestep=%d;arrows=show]"):format(
			math.floor((nrow - VIEW_ROWS) * RH * 10 + 0.5), math.floor(RH * 10 + 0.5), math.floor(VIEW * 10 + 0.5))
		out[#out + 1] = ("scrollbar[19.75,%g;0.45,%g;vertical;cb_scroll;0]"):format(TOP - 0.1, VIEW + 0.2)
	end
	local hint
	if not rm then
		hint = S("You can see the core, but not read it: learn \"Rock mass classification\" to see lithology, joints and RQD (and \"Grade interpretation\" for grade)")
	elseif not gr then
		hint = S("Grade needs \"Grade interpretation\"")
	end
	local tail = nrow > VIEW_ROWS and S("@1 m per row; scroll down with the mouse wheel or the scrollbar", tostring(PER_ROW))
		or S("@1 m per row", tostring(PER_ROW))
	out[#out + 1] = ("label[0.5,%g;%s]"):format(bottom + 0.1, core.formspec_escape(tail))
	if hint then out[#out + 1] = ("label[0.5,%g;%s]"):format(bottom + 1.0, core.formspec_escape(hint)) end
	out[#out + 1] = ("button_exit[16.7,%g;3,0.8;close;%s]"):format(bottom, core.formspec_escape(S("Close")))
	return table.concat(out)
end

local function open_box(pos, clicker)
	if not (clicker and clicker:is_player()) then return end
	local name = clicker:get_player_name()
	local meta = core.get_meta(pos)
	local acc, n = meta:get_string("acc"), meta:get_int("n")
	local bh = find_bh(acc, n)
	if not bh then rockmech.notify(name, S("[Core box] No borehole record found for this box")); return end
	close_for(name)
	local node = core.get_node(pos)
	if node.name == COREBOX then core.swap_node(pos, {name = COREBOX_OPEN, param2 = node.param2}) end
	local key = core.hash_node_position(pos)
	opened[key] = opened[key] or {}
	opened[key][name] = true
	viewing_box[name] = vector.copy(pos)
	core.sound_play("default_dig_choppy", {pos = pos, gain = 0.3, max_hear_distance = 10}, true)
	core.show_formspec(name, OPEN_FORM, corebox_form(name, bh, acc))
end
corebox_rightclick = function(pos, node, clicker, itemstack)
	open_box(pos, clicker)
	return itemstack
end
core.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= OPEN_FORM then return end
	if fields.quit then close_for(player:get_player_name()) end
	return true
end)
core.register_on_leaveplayer(function(player) close_for(player:get_player_name()) end)
-- 重開伺服器時沒人在看：打開的箱子蓋回去
core.register_lbm({
	label = "Close open core boxes", name = "rockmech:corebox_close", nodenames = {COREBOX_OPEN}, run_at_every_load = true,
	action = function(pos, node)
		if not opened[core.hash_node_position(pos)] then core.swap_node(pos, {name = COREBOX, param2 = node.param2}) end
	end,
})

-- 孔口旁邊放岩芯箱的格子：四邊、再斜角、再外一圈；那格空的、下面是實心、沒有人或車
box_spot = function(c)
	for r = 1, 3 do
		for dx = -r, r do for dz = -r, r do
			if math.max(math.abs(dx), math.abs(dz)) == r then
				for dy = 1, -1, -1 do
					local p = {x = c.x + dx, y = c.y + dy, z = c.z + dz}
					local nd = core.registered_nodes[core.get_node(p).name]
					local below = core.registered_nodes[core.get_node({x = p.x, y = p.y - 1, z = p.z}).name]
					if nd and nd.buildable_to and below and below.walkable
							and not (rockmech.cells_blocked and rockmech.cells_blocked({{p.x, p.z}}, p.y, p.y + 1)) then
						return p
					end
				end
			end
		end end
	end
end

---------------------------------------------------------------------------
-- 野帳本：右鍵對岩芯箱判讀，左鍵看記過的孔。記在物品 meta：{{acc, n, rm, gr, by}, ...}
---------------------------------------------------------------------------

local function book_entries(stack) return core.deserialize(stack:get_meta():get_string("logs")) or {} end
-- 施密特錘的讀數（testing.lua）：記在野帳本的 meta schmidt = {{x, y, z, r, lith}, …}
local SCHMIDT_MAX = 200
local function schmidt_of(stack) return core.deserialize(stack:get_meta():get_string("schmidt")) or {} end
-- 記一筆到玩家背包裡的第一本野帳本，回傳這本現在幾筆；沒有野帳本回傳 nil
function rockmech.fieldbook_add_schmidt(player, rec)
	local inv = player:get_inventory()
	for i, st in ipairs(inv:get_list("main") or {}) do
		if st:get_name() == BOOK then
			local list = schmidt_of(st)
			if #list >= SCHMIDT_MAX then table.remove(list, 1) end
			list[#list + 1] = rec
			st:get_meta():set_string("schmidt", core.serialize(list))
			inv:set_stack("main", i, st)
			return #list
		end
	end
end
local SCHMIDT_FORM = "rockmech:fieldbook_schmidt"
local function schmidt_form(name, list)
	local out = {"formspec_version[6]size[12,11]",
		("label[0.5,0.6;%s]"):format(core.formspec_escape(S("Field notebook: Schmidt hammer readings (@1)", tostring(#list))))}
	if #list == 0 then
		out[#out + 1] = "label[0.5,1.4;" .. core.formspec_escape(S("No readings yet: right-click a rock face with the Schmidt hammer")) .. "]"
	else
		out[#out + 1] = "tablecolumns[text,align=right;text;text;text,align=right]"
		local cells = {core.formspec_escape(S("No.")), core.formspec_escape(S("Position")), core.formspec_escape(S("Rock")),
			core.formspec_escape(S("Rebound R"))}
		for i, e in ipairs(list) do
			cells[#cells + 1] = tostring(i)
			cells[#cells + 1] = core.formspec_escape(("(%d,%d,%d)"):format(e.x, e.y, e.z))
			cells[#cells + 1] = core.formspec_escape(e.lith and lith_label(e.lith) or "?")
			cells[#cells + 1] = tostring(e.r)
		end
		out[#out + 1] = "table[0.5,1.0;11,7.6;sch;" .. table.concat(cells, ",") .. ";0]"
	end
	out[#out + 1] = "textarea[0.5,8.8;11,1.2;;;" .. core.formspec_escape(S("Take about 10 readings at the same spot, sort them and take the median R. Uniaxial compressive strength (Katz 2000): UCS ≈ 2.21·e^(0.067R) MPa.")) .. "]"
	out[#out + 1] = "button[0.5,10.1;3,0.7;back;" .. core.formspec_escape(S("Back")) .. "]"
	out[#out + 1] = "button[4.5,10.1;3,0.7;clear;" .. core.formspec_escape(S("Clear readings")) .. "]"
	out[#out + 1] = "button_exit[8.5,10.1;3,0.7;close;" .. core.formspec_escape(S("Close")) .. "]"
	return table.concat(out)
end
local logging = {}          -- 玩家名稱 → {pos, acc, n, depth, t, need, hud}
local book_view = {}        -- 玩家名稱 → 打開的那本的紀錄

local function book_form(name, entries)
	local out = {"formspec_version[6]size[12,11]", ("label[0.5,0.6;%s]"):format(core.formspec_escape(
		S("Field notebook (@1 / @2 holes)", tostring(#entries), tostring(BOOK_MAX))))}
	for i, e in ipairs(entries) do
		local col, row = (i - 1) % 2, math.floor((i - 1) / 2)
		out[#out + 1] = ("button[%g,%g;5.4,0.7;e_%d;%s]"):format(0.5 + col * 5.6, 1.2 + row * 0.8, i, core.formspec_escape(
			S("@1 (@2)", bh_label(e.acc, e.n), rockmech.account_label and rockmech.account_label(e.acc) or e.acc)
				.. (e.rm and "" or " " .. S("rock mass?")) .. (e.gr and "" or " " .. S("grade?"))))
	end
	if #entries == 0 then
		out[#out + 1] = "label[0.5,1.6;" .. core.formspec_escape(S("No holes logged yet: hold the field notebook and right-click a core box to log it")) .. "]"
	end
	local player = core.get_player_by_name(name)
	local st = player and player:get_wielded_item()
	local nsch = st and st:get_name() == BOOK and #schmidt_of(st) or 0
	out[#out + 1] = "button[0.5,10.1;6,0.7;schmidt;" .. core.formspec_escape(S("Schmidt hammer readings (@1)", tostring(nsch))) .. "]"
	return table.concat(out)
end

core.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= BOOK_FORM then return end
	local name = player:get_player_name()
	if fields.schmidt then
		local st = player:get_wielded_item()
		core.show_formspec(name, SCHMIDT_FORM, schmidt_form(name, st:get_name() == BOOK and schmidt_of(st) or {}))
		return true
	end
	for k in pairs(fields) do
		local i = tonumber(k:match("^e_(%d+)$"))
		local e = i and (book_view[name] or {})[i]
		if e then
			local b = find_bh(e.acc, e.n)
			if b then core.show_formspec(name, FORM, log_form(name, b, e.rm, e.gr)) end
			return true
		end
	end
	if fields.quit then book_view[name] = nil end
	return true
end)

core.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= SCHMIDT_FORM then return end
	local name = player:get_player_name()
	local st = player:get_wielded_item()
	if st:get_name() ~= BOOK then return true end
	if fields.clear then
		st:get_meta():set_string("schmidt", "")
		player:set_wielded_item(st)
		core.show_formspec(name, SCHMIDT_FORM, schmidt_form(name, {}))
	elseif fields.back then
		book_view[name] = book_entries(st)
		core.show_formspec(name, BOOK_FORM, book_form(name, book_view[name]))
	end
	return true
end)

local function stop_logging(name, msg)
	local L = logging[name]
	if not L then return end
	logging[name] = nil
	local p = core.get_player_by_name(name)
	if p and L.hud then p:hud_remove(L.hud) end
	if msg then rockmech.notify(name, S("[Field notebook]") .. " " .. msg) end
end

local function start_logging(player, pos)
	local name = player:get_player_name()
	local meta = core.get_meta(pos)
	local acc, n, depth = meta:get_string("acc"), meta:get_int("n"), meta:get_int("depth")
	if not find_bh(acc, n) then rockmech.notify(name, S("[Field notebook] No borehole record found for this box")); return end
	local entries = book_entries(player:get_wielded_item())
	local have = false
	for _, e in ipairs(entries) do if e.acc == acc and e.n == n then have = true end end
	if not have and #entries >= BOOK_MAX then
		rockmech.notify(name, S("[Field notebook] Full (@1 holes): buy a new one", tostring(BOOK_MAX)))
		return
	end
	stop_logging(name)
	logging[name] = {pos = pos, acc = acc, n = n, depth = depth, t = 0, need = math.max(1, depth) * LOG_SEC_PER_M,
		hud = player:hud_add({type = "text", position = {x = 0.5, y = 0.7}, alignment = {x = 0, y = 0},
			number = 0x9fe0ff, text = "", z_index = 100})}
	rockmech.notify(name, S("[Field notebook] Logging @1 (depth @2 m, about @3 s): stay next to the core box and keep holding the field notebook",
		bh_label(acc, n), tostring(depth), tostring(math.ceil(depth * LOG_SEC_PER_M))))
end

core.register_globalstep(function(dtime)
	for name, L in pairs(logging) do
		local p = core.get_player_by_name(name)
		if not p then logging[name] = nil
		else
			local pp = p:get_pos()
			local m = core.get_meta(L.pos)
			if not is_corebox(core.get_node(L.pos).name) or m:get_int("n") ~= L.n or m:get_string("acc") ~= L.acc then
				stop_logging(name, S("The core box was moved; logging interrupted"))
			elseif vector.distance(pp, L.pos) > LOG_STAY or p:get_wielded_item():get_name() ~= BOOK then
				stop_logging(name, S("You walked away (or are not holding the field notebook); logging interrupted"))
			else
				L.t = L.t + dtime
				local m_done = math.min(L.depth, math.floor(L.t / LOG_SEC_PER_M))
				p:hud_change(L.hud, "text", S("Logging @1   @2 / @3 m", bh_label(L.acc, L.n), tostring(m_done), tostring(L.depth)))
				if L.t >= L.need then
					local stack = p:get_wielded_item()
					local entries = book_entries(stack)
					local e = {acc = L.acc, n = L.n, rm = see(name, "rockmass"), gr = see(name, "grade"), by = name}
					local at
					for i, x in ipairs(entries) do if x.acc == e.acc and x.n == e.n then at = i end end
					entries[at or (#entries + 1)] = e
					stack:get_meta():set_string("logs", core.serialize(entries))
					stack:get_meta():set_string("description", S("Field notebook (@1 / @2 holes)\nRight-click a core box to log it; left-click to see logged holes", tostring(#entries), tostring(BOOK_MAX)))
					p:set_wielded_item(stack)
					stop_logging(name, (e.rm and e.gr)
						and S("@1 logged: left-click to open the field notebook", bh_label(L.acc, L.n))
						or S("@1 logged (some fields you cannot interpret were recorded as ?): left-click to open the field notebook", bh_label(L.acc, L.n)))
					local b = find_bh(L.acc, L.n)
					if b then core.show_formspec(name, FORM, log_form(name, b, e.rm, e.gr)) end
				end
			end
		end
	end
end)
core.register_on_leaveplayer(function(player) logging[player:get_player_name()] = nil; book_view[player:get_player_name()] = nil end)

core.register_craftitem(BOOK, {
	description = S("Field notebook\nRight-click a core box to log it (@1 s per metre, stay nearby) into a borehole log\nLeft-click to see logged holes (up to @2 holes)\nWhat you record depends on your skills at logging time: fields you cannot interpret are recorded as ?",
		("%g"):format(LOG_SEC_PER_M), tostring(BOOK_MAX)),
	short_description = S("Field notebook"),
	inventory_image = "[fill:16x16:#00000000^[fill:11x14:3,1:#d8c048^[fill:2x14:3,1:#8a7020^[fill:7x1:6,4:#5a4a10^[fill:7x1:6,7:#5a4a10^[fill:5x1:6,10:#5a4a10",
	stack_max = 1,
	on_place = function(itemstack, placer, pointed)
		if not placer or pointed.type ~= "node" then return itemstack end
		if is_corebox(core.get_node(pointed.under).name) then start_logging(placer, pointed.under)
		else
			local un = core.get_node(pointed.under)
			local nd = core.registered_nodes[un.name]
			if nd and nd.on_rightclick then return nd.on_rightclick(pointed.under, un, placer, itemstack, pointed) end
			rockmech.notify(placer:get_player_name(), S("[Field notebook] Right-click a core box to log it"))
		end
		return itemstack
	end,
	on_use = function(itemstack, user)
		if not user then return end
		local name = user:get_player_name()
		book_view[name] = book_entries(itemstack)
		core.show_formspec(name, BOOK_FORM, book_form(name, book_view[name]))
	end,
})

---------------------------------------------------------------------------
-- 鑽孔（手持鑽機、岩芯鑽探車共用）
---------------------------------------------------------------------------

local drilling = {}         -- 玩家名稱 → {collar, x, y, z, rows, t, max, ok（還能繼續鑽嗎：回傳 nil 或停下的原因）}

local function finish(name, d, why)
	drilling[name] = nil
	if d.on_done then d.on_done() end
	if #d.rows == 0 then
		rockmech.notify(name, why and S("[Core drilling] Nothing was drilled (@1)", why) or S("[Core drilling] Nothing was drilled"))
		return
	end
	local acc = rockmech.account_of and rockmech.account_of(name) or name
	local list = logs_of(acc)
	local n = #list + 1
	local bh = {n = n, pos = d.collar, depth = #d.rows, rows = d.rows, stop = why, by = name}
	list[n] = bh
	save_logs(acc, list)
	-- 孔口：混凝土墊＋套管（空的才放）
	local cp = d.collar
	local cn = core.get_node(cp)
	if cn.name == "air" or (core.registered_nodes[cn.name] or {}).buildable_to then
		core.set_node(cp, {name = CASING})
		local meta = core.get_meta(cp)
		meta:set_string("acc", acc)
		meta:set_int("n", n)
		meta:set_int("depth", #d.rows)
		meta:set_string("infotext", S("@1 (@2) depth @3 m\nRight-click to name it", "BH-" .. n,
			rockmech.account_label and rockmech.account_label(acc) or acc, tostring(#d.rows)))
	end
	-- 岩芯裝箱，放在孔口旁邊的地上
	local bp = box_spot(cp)
	if bp then rockmech.corebox_put(bp, {acc = acc, n = n, depth = #d.rows}) end
	local msg
	local sn, sd = tostring(n), tostring(#d.rows)
	if bp then
		msg = why and S("[Core drilling] @1 finished BH-@2, depth @3 m, @4: the blue core box is next to the collar; right-click it with a field notebook to log it", name, sn, sd, why)
			or S("[Core drilling] @1 finished BH-@2, depth @3 m: the blue core box is next to the collar; right-click it with a field notebook to log it", name, sn, sd)
	else
		msg = why and S("[Core drilling] @1 finished BH-@2, depth @3 m, @4: no room next to the collar, so the core box was not placed (ask the teacher)", name, sn, sd, why)
			or S("[Core drilling] @1 finished BH-@2, depth @3 m: no room next to the collar, so the core box was not placed (ask the teacher)", name, sn, sd)
	end
	if rockmech.account_members then
		for _, m in ipairs(rockmech.account_members(acc)) do
			rockmech.notify(m, msg)
		end
	end
end

-- 從 collar（孔口那一格，空的）往下鑽到 max m。ok() 每一步檢查還能不能繼續（回傳停下的原因或 nil）
function rockmech.coredrill_start(name, collar, max, ok, on_done)
	if drilling[name] then rockmech.notify(name, S("[Core drilling] Already drilling")); return false end
	drilling[name] = {collar = collar, x = collar.x, y = collar.y - 1, z = collar.z, rows = {}, t = 0, max = max, ok = ok, on_done = on_done}
	rockmech.notify(name, S("[Core drilling] Drilling down (@1 s per metre, max @2 m)", tostring(SEC_PER_M), tostring(max)))
	return true
end
function rockmech.coredrill_depth(name) local d = drilling[name]; return d and #d.rows, d and d.max end

local function start_hand(player, pointed)
	if pointed.type ~= "node" then return end
	if pointed.above.y ~= pointed.under.y + 1 then
		rockmech.notify(player:get_player_name(), S("[Core drilling] Aim at the ground (the top of a block) to drill down"))
		return
	end
	local name = player:get_player_name()
	local c = pointed.above
	rockmech.coredrill_start(name, c, HAND_DEPTH, function()
		local p = core.get_player_by_name(name)
		local pp = p:get_pos()
		if math.sqrt((pp.x - c.x) ^ 2 + (pp.z - c.z) ^ 2) > STAY_R or p:get_wielded_item():get_name() ~= ITEM then return S("you walked away") end
	end)
end

core.register_globalstep(function(dtime)
	for name, d in pairs(drilling) do
		local p = core.get_player_by_name(name)
		if not p then
			drilling[name] = nil
			if d.on_done then d.on_done() end
		else
			local why = d.ok and d.ok()
			if why then
				finish(name, d, why)
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
					if core.get_item_group(node.name, "rockmech_topsoil") > 0
							or (rockmech.is_rubble(node.name) and rockmech.rubble_base[node.name] == rockmech.RUBBLE_SOIL) then
						row = {lith = "soil"}         -- 表土、鬆土：鑽得過去，岩芯裡是一段土
					elseif lith then
						row = {lith = lith.name, grade = lith.ore and node.param2 or nil}
					elseif rockmech.is_rubble(node.name) then
						local base = rockmech.rubble_base[node.name]
						row = {lith = "rubble", grade = rockmech.ore_of_rubble[base] and node.param2 or nil}
					end
					if not row then
						finish(name, d, node.name == "air" and S("hit a void") or node.name == "ignore" and S("map not loaded yet") or S("hit a facility"))
					else
						-- 這 1 m 有幾條節理穿過鑽孔（格子的上面那個面）
						local sets = rockmech.get_joint_sets()
						row.joints = row.lith ~= "soil" and (joints.face_joint(sets, cell.x, cell.y, cell.z, 2) and 1 or 0) or 0
						d.rows[#d.rows + 1] = row
						if #d.rows >= d.max then finish(name, d, nil) end
					end
				end
			end
		end
	end
end)
core.register_on_leaveplayer(function(player) drilling[player:get_player_name()] = nil end)

core.register_tool(ITEM, {
	description = S("Hand-held core drill\nRight-click the ground: drill a vertical hole and take core (@1 s per metre, max @2 m; deeper holes need the core drill rig); don't walk away while drilling\nThe core goes into a blue core box next to the collar; log it with a field notebook into a borehole log (lithology, grade, joints, RQD)",
		tostring(SEC_PER_M), tostring(HAND_DEPTH)),
	short_description = S("Hand-held core drill"),
	inventory_image = "[fill:16x16:#00000000^[fill:4x10:6,1:#d0a020^[fill:2x5:7,11:#808488^[fill:8x3:4,3:#303030^[fill:2x1:7,15:#c0c0c0",
	stack_max = 1,
	on_place = function(itemstack, placer, pointed) if placer then start_hand(placer, pointed) end return itemstack end,
	on_use = function(itemstack, user, pointed) if user then start_hand(user, pointed) end return itemstack end,
})
