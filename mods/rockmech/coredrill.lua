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
local joints = rockmech.joints

local ITEM, CASING = "rockmech:core_drill", "rockmech:borehole"
local SEC_PER_M, HAND_DEPTH, STAY_R = 1, 10, 3      -- 手持鑽機最深 10 m；更深要用岩芯鑽探車（vehicle_corerig.lua，60 m）
local LOG = "bh:"            -- mod storage：bh:<帳戶> = {{n, pos, depth, rows = {{lith, grade, joints}}}, ...}
local FORM, BOOK_FORM = "rockmech:borehole", "rockmech:fieldbook"
local COREBOX, BOOK = "rockmech:corebox", "rockmech:fieldbook"
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
	if key == "rubble" then return "碎石" end
	local l = rockmech.cfg.lithologies[key]
	return l and (l.description:match("（(.-)）") or l.description:match("%((.-)%)") or key) or key
end
rockmech.lith_label = lith_label
local function lith_color(key)
	if key == "rubble" then return "#8a8070" end
	local l = rockmech.cfg.lithologies[key]
	return l and l.color or "#808080"
end

-- rm、gr：看得懂岩體、品位嗎（野帳本：判讀當時的能力；舊版岩芯箱：看的人現在的能力）
local function log_form(name, bh, rm, gr)
	if rm == nil then rm = see(name, "rockmass") end
	if gr == nil then gr = see(name, "grade") end
	local out = {"formspec_version[6]size[15,12.4]",
		("label[0.5,0.6;%s]"):format(core.formspec_escape(("%s%s　孔口 (%d, %d, %d)　深 %d m%s"):format(label_of(bh),
			(bh.name and bh.name ~= "") and ("（BH-" .. bh.n .. "）") or "", bh.pos.x, bh.pos.y, bh.pos.z, bh.depth,
			bh.stop and ("（" .. bh.stop .. "）") or ""))),
		"label[0.5,1.2;深度]label[3.0,1.2;柱狀]label[4.4,1.2;岩性]label[7.4,1.2;品位]label[9.6,1.2;節理]label[11.6,1.2;RQD]"}
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
		out[#out + 1] = ("label[4.4,%g;%s]"):format(y + H / 2, core.formspec_escape(rm and lith_label(r.lith) or "岩石"))
		local g = "—"
		if is_ore or r.grade then g = gr and r.grade and ("%.0f%%"):format(r.grade / 255 * 100) or (gr and "—" or "?") end
		out[#out + 1] = ("label[7.4,%g;%s]"):format(y + H / 2, core.formspec_escape(g))
		out[#out + 1] = ("label[9.6,%g;%s]"):format(y + H / 2, rm and tostring(r.joints or 0) or "?")
		out[#out + 1] = ("label[11.6,%g;%s]"):format(y + H / 2, rm and ("%.0f%%"):format(rqd_of(lambda(i))) or "?")
	end
	if note then
		out[#out + 1] = ("label[0.5,%g;%s]"):format(0.1 + #rows * H + 0.2, core.formspec_escape(
			"?：判讀的時候不會。岩性、節理、RQD 要「岩體分類」，品位要「品位判讀」；學會之後拿野帳本重新判讀岩芯箱"))
	end
	out[#out + 1] = "scroll_container_end[]"
	if scroll then
		-- 捲軸：每格 0.1（scroll_container 的係數），拉到底剛好看到最後一行
		out[#out + 1] = ("scrollbaroptions[max=%d;smallstep=%d;largestep=%d]"):format(
			math.ceil((content - VIEW) * 10), math.floor(H * 10 * 3), math.floor(VIEW * 10))
		out[#out + 1] = ("scrollbar[14.4,%g;0.4,%g;vertical;bh_scroll;0]"):format(TOP, VIEW)
		out[#out + 1] = ("label[0.5,%g;%s]"):format(TOP + VIEW + 0.4, core.formspec_escape("滑鼠滾輪或右邊捲軸往下看"))
	end
	out[#out + 1] = ("button_exit[6,%g;3,0.8;ok;關閉]"):format(TOP + VIEW + 0.3)
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
	description = "鑽孔套管", drawtype = "nodebox", paramtype = "light", is_ground_content = false, sunlight_propagates = true,
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
	core.get_meta(pos):set_string("infotext", ("%s（%s）深 %d m\n右鍵取名字"):format(bh_label(acc, n),
		rockmech.account_label and rockmech.account_label(acc) or acc, depth))
end
function rockmech.borehole_name_form(player, pos)
	local name = player:get_player_name()
	local meta = core.get_meta(pos)
	local acc, n, depth = meta:get_string("acc"), meta:get_int("n"), meta:get_int("depth")
	local b = find_bh(acc, n)
	if not b then core.chat_send_player(name, "[鑽孔] 找不到這一孔的紀錄"); return end
	local mine = not rockmech.owner_ok or rockmech.owner_ok(acc, name)
	naming[name] = pos
	local out = {"formspec_version[6]size[10,5]",
		("label[0.5,0.6;%s]"):format(core.formspec_escape(("%s（BH-%d）深 %d m　%s"):format(label_of(b), n, depth,
			rockmech.account_label and rockmech.account_label(acc) or acc))),
		("label[0.5,1.2;%s]"):format(core.formspec_escape("岩芯在藍色岩芯箱裡，拿野帳本對岩芯箱右鍵判讀")),
	}
	if mine then
		out[#out + 1] = ("field[0.5,2.2;9,0.8;bhname;%s;%s]"):format(
			core.formspec_escape(("鑽孔名稱（最多 %d 個字，空白 = BH-%d）"):format(NAME_MAX, n)), core.formspec_escape(b.name or ""))
		out[#out + 1] = "field_close_on_enter[bhname;false]"
		out[#out + 1] = "button[0.5,3.6;4,0.8;save;儲存名稱]"
	else
		out[#out + 1] = "label[0.5,2.4;" .. core.formspec_escape("別組的鑽孔，不能改名字") .. "]"
	end
	out[#out + 1] = "button_exit[5.5,3.6;4,0.8;close;關閉]"
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
			m:set_string("infotext", ("岩芯箱 %s（%s，深 %d m）\n左鍵捧起來；拿野帳本右鍵判讀"):format(label_of(b),
				rockmech.account_label and rockmech.account_label(acc) or acc, m:get_int("depth")))
		end
	end
	local msg = ("[鑽孔] %s 把 %s 改名為 %s"):format(name, old, label_of(b))
	for _, m in ipairs(rockmech.account_members and rockmech.account_members(acc) or {name}) do core.chat_send_player(m, msg) end
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
	description = "岩芯箱", stack_max = 1, groups = {not_in_creative_inventory = 1},
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
		core.chat_send_player(user:get_player_name(), "[岩芯箱] 找不到這一孔的紀錄")
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
	description = "岩芯箱", drawtype = "nodebox", paramtype = "light", paramtype2 = "facedir",
	tiles = {box_tex(true), box_tex(false), box_tex(false)},
	node_box = {type = "fixed", fixed = {-0.45, -0.5, -0.3, 0.45, -0.5 + 0.4 / 3, 0.3}},
	-- 高度 0.4/3 m（實際的岩芯箱約 10 cm 高）；疊起來時一箱佔一格，上面那箱放在上一格
	selection_box = {type = "fixed", fixed = {-0.45, -0.5, -0.3, 0.45, -0.5 + 0.4 / 3, 0.3}},
	groups = {crumbly = 3, falling_node = 1, not_in_creative_inventory = 1},
	is_ground_content = false, drop = "",
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
	meta:set_string("infotext", ("岩芯箱 %s（%s，深 %d m）\n左鍵捧起來；拿野帳本右鍵判讀"):format(bh_label(data.acc, data.n),
		rockmech.account_label and rockmech.account_label(data.acc) or data.acc, data.depth))
	return true
end
-- 捧起 pos 那一箱：回傳 data，或 nil（不是自己組的）
function rockmech.corebox_take(pos, player)
	local meta = core.get_meta(pos)
	local data = {acc = meta:get_string("acc"), n = meta:get_int("n"), depth = meta:get_int("depth")}
	if rockmech.owner_ok and not rockmech.owner_ok(data.acc, player:get_player_name()) then return nil end
	core.remove_node(pos)
	core.check_for_falling({x = pos.x, y = pos.y + 1, z = pos.z})
	return data
end
rockmech.COREBOX = COREBOX

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
local logging = {}          -- 玩家名稱 → {pos, acc, n, depth, t, need, hud}
local book_view = {}        -- 玩家名稱 → 打開的那本的紀錄

local function book_form(name, entries)
	local out = {"formspec_version[6]size[12,11]", ("label[0.5,0.6;%s]"):format(core.formspec_escape(
		("野帳本（%d / %d 孔）"):format(#entries, BOOK_MAX)))}
	for i, e in ipairs(entries) do
		local col, row = (i - 1) % 2, math.floor((i - 1) / 2)
		out[#out + 1] = ("button[%g,%g;5.4,0.7;e_%d;%s]"):format(0.5 + col * 5.6, 1.2 + row * 0.8, i, core.formspec_escape(
			("%s（%s）%s%s"):format(bh_label(e.acc, e.n), rockmech.account_label and rockmech.account_label(e.acc) or e.acc,
				e.rm and "" or "岩體?", e.gr and "" or "品位?")))
	end
	if #entries == 0 then
		out[#out + 1] = "label[0.5,1.6;" .. core.formspec_escape("還沒記任何孔：拿著野帳本對岩芯箱按右鍵判讀") .. "]"
	end
	return table.concat(out)
end

core.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= BOOK_FORM then return end
	local name = player:get_player_name()
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

local function stop_logging(name, msg)
	local L = logging[name]
	if not L then return end
	logging[name] = nil
	local p = core.get_player_by_name(name)
	if p and L.hud then p:hud_remove(L.hud) end
	if msg then core.chat_send_player(name, "[野帳本] " .. msg) end
end

local function start_logging(player, pos)
	local name = player:get_player_name()
	local meta = core.get_meta(pos)
	local acc, n, depth = meta:get_string("acc"), meta:get_int("n"), meta:get_int("depth")
	if not find_bh(acc, n) then core.chat_send_player(name, "[野帳本] 找不到這一箱的鑽孔紀錄"); return end
	local entries = book_entries(player:get_wielded_item())
	local have = false
	for _, e in ipairs(entries) do if e.acc == acc and e.n == n then have = true end end
	if not have and #entries >= BOOK_MAX then
		core.chat_send_player(name, ("[野帳本] 寫滿了（%d 孔）：買一本新的"):format(BOOK_MAX))
		return
	end
	stop_logging(name)
	logging[name] = {pos = pos, acc = acc, n = n, depth = depth, t = 0, need = math.max(1, depth) * LOG_SEC_PER_M,
		hud = player:hud_add({type = "text", position = {x = 0.5, y = 0.7}, alignment = {x = 0, y = 0},
			number = 0x9fe0ff, text = "", z_index = 100})}
	core.chat_send_player(name, ("[野帳本] 開始判讀 %s（深 %d m，約 %d 秒）：待在岩芯箱旁邊、手上拿著野帳本"):format(
		bh_label(acc, n), depth, math.ceil(depth * LOG_SEC_PER_M)))
end

core.register_globalstep(function(dtime)
	for name, L in pairs(logging) do
		local p = core.get_player_by_name(name)
		if not p then logging[name] = nil
		else
			local pp = p:get_pos()
			local m = core.get_meta(L.pos)
			if core.get_node(L.pos).name ~= COREBOX or m:get_int("n") ~= L.n or m:get_string("acc") ~= L.acc then
				stop_logging(name, "岩芯箱被搬走了，判讀中斷")
			elseif vector.distance(pp, L.pos) > LOG_STAY or p:get_wielded_item():get_name() ~= BOOK then
				stop_logging(name, "人走開了（或手上沒拿野帳本），判讀中斷")
			else
				L.t = L.t + dtime
				local m_done = math.min(L.depth, math.floor(L.t / LOG_SEC_PER_M))
				p:hud_change(L.hud, "text", ("判讀 %s　%d / %d m"):format(bh_label(L.acc, L.n), m_done, L.depth))
				if L.t >= L.need then
					local stack = p:get_wielded_item()
					local entries = book_entries(stack)
					local e = {acc = L.acc, n = L.n, rm = see(name, "rockmass"), gr = see(name, "grade"), by = name}
					local at
					for i, x in ipairs(entries) do if x.acc == e.acc and x.n == e.n then at = i end end
					entries[at or (#entries + 1)] = e
					stack:get_meta():set_string("logs", core.serialize(entries))
					stack:get_meta():set_string("description", ("野帳本（%d / %d 孔）\n右鍵對岩芯箱判讀，左鍵看記過的孔"):format(#entries, BOOK_MAX))
					p:set_wielded_item(stack)
					stop_logging(name, ("%s 記好了%s：左鍵打開野帳本看"):format(bh_label(L.acc, L.n),
						(e.rm and e.gr) and "" or "（有些欄位不會判讀，記成 ?）"))
					local b = find_bh(L.acc, L.n)
					if b then core.show_formspec(name, FORM, log_form(name, b, e.rm, e.gr)) end
				end
			end
		end
	end
end)
core.register_on_leaveplayer(function(player) logging[player:get_player_name()] = nil; book_view[player:get_player_name()] = nil end)

core.register_craftitem(BOOK, {
	description = ("野帳本\n右鍵對岩芯箱判讀（每公尺 %g 秒，要待在旁邊），記成柱狀圖\n左鍵看記過的孔（最多 %d 孔）\n"
		.. "記下來的照你判讀時的能力：不會的欄位記成 ?"):format(LOG_SEC_PER_M, BOOK_MAX),
	inventory_image = "[fill:16x16:#00000000^[fill:11x14:3,1:#d8c048^[fill:2x14:3,1:#8a7020^[fill:7x1:6,4:#5a4a10^[fill:7x1:6,7:#5a4a10^[fill:5x1:6,10:#5a4a10",
	stack_max = 1,
	on_place = function(itemstack, placer, pointed)
		if not placer or pointed.type ~= "node" then return itemstack end
		if core.get_node(pointed.under).name == COREBOX then start_logging(placer, pointed.under)
		else
			local un = core.get_node(pointed.under)
			local nd = core.registered_nodes[un.name]
			if nd and nd.on_rightclick then return nd.on_rightclick(pointed.under, un, placer, itemstack, pointed) end
			core.chat_send_player(placer:get_player_name(), "[野帳本] 對著岩芯箱按右鍵判讀")
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
		core.chat_send_player(name, "[岩芯鑽探] 沒鑽到東西" .. (why and ("（" .. why .. "）") or ""))
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
		meta:set_string("infotext", ("BH-%d（%s）深 %d m\n右鍵取名字"):format(n,
			rockmech.account_label and rockmech.account_label(acc) or acc, #d.rows))
	end
	-- 岩芯裝箱，放在孔口旁邊的地上
	local bp = box_spot(cp)
	local where = "孔口旁邊"
	if bp then rockmech.corebox_put(bp, {acc = acc, n = n, depth = #d.rows})
	else where = "（孔口旁邊沒地方放，岩芯箱沒放出來，找老師）" end
	if rockmech.account_members then
		for _, m in ipairs(rockmech.account_members(acc)) do
			core.chat_send_player(m, ("[岩芯鑽探] %s 鑽好 BH-%d，深 %d m%s：藍色岩芯箱在%s，拿野帳本對它右鍵判讀"):format(
				name, n, #d.rows, why and ("，" .. why) or "", where))
		end
	end
end

-- 從 collar（孔口那一格，空的）往下鑽到 max m。ok() 每一步檢查還能不能繼續（回傳停下的原因或 nil）
function rockmech.coredrill_start(name, collar, max, ok, on_done)
	if drilling[name] then core.chat_send_player(name, "[岩芯鑽探] 正在鑽"); return false end
	drilling[name] = {collar = collar, x = collar.x, y = collar.y - 1, z = collar.z, rows = {}, t = 0, max = max, ok = ok, on_done = on_done}
	core.chat_send_player(name, ("[岩芯鑽探] 開始往下鑽（每公尺 %d 秒，最深 %d m）"):format(SEC_PER_M, max))
	return true
end
function rockmech.coredrill_depth(name) local d = drilling[name]; return d and #d.rows, d and d.max end

local function start_hand(player, pointed)
	if pointed.type ~= "node" then return end
	if pointed.above.y ~= pointed.under.y + 1 then
		core.chat_send_player(player:get_player_name(), "[岩芯鑽探] 要對著地面（方塊的上面）往下鑽")
		return
	end
	local name = player:get_player_name()
	local c = pointed.above
	rockmech.coredrill_start(name, c, HAND_DEPTH, function()
		local p = core.get_player_by_name(name)
		local pp = p:get_pos()
		if math.sqrt((pp.x - c.x) ^ 2 + (pp.z - c.z) ^ 2) > STAY_R or p:get_wielded_item():get_name() ~= ITEM then return "人離開了" end
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
					if lith then
						row = {lith = lith.name, grade = lith.ore and node.param2 or nil}
					elseif rockmech.is_rubble(node.name) then
						local base = rockmech.rubble_base[node.name]
						row = {lith = "rubble", grade = rockmech.ore_of_rubble[base] and node.param2 or nil}
					end
					if not row then
						finish(name, d, node.name == "air" and "鑽到空洞" or node.name == "ignore" and "地圖還沒載入" or "碰到設施")
					else
						-- 這 1 m 有幾條節理穿過鑽孔（格子的上面那個面）
						local sets = rockmech.get_joint_sets()
						row.joints = (joints.face_joint(sets, cell.x, cell.y, cell.z, 2) and 1 or 0)
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
	description = ("手持岩芯鑽機\n對著地面右鍵：往下鑽一個垂直孔取岩芯（每公尺 %d 秒、最深 %d m，更深要用岩芯鑽探車），鑽的時候不能走開\n"
		.. "岩芯裝在藍色岩芯箱裡放在孔口旁邊，拿野帳本判讀成柱狀圖（岩性、品位、節理、RQD）"):format(SEC_PER_M, HAND_DEPTH),
	inventory_image = "[fill:16x16:#00000000^[fill:4x10:6,1:#d0a020^[fill:2x5:7,11:#808488^[fill:8x3:4,3:#303030^[fill:2x1:7,15:#c0c0c0",
	stack_max = 1,
	on_place = function(itemstack, placer, pointed) if placer then start_hand(placer, pointed) end return itemstack end,
	on_use = function(itemstack, user, pointed) if user then start_hand(user, pointed) end return itemstack end,
})
