-- rockmech/coredrill.lua
-- 岩芯鑽探：手持岩芯鑽機（$3,000，工具室管理員）對地面按住右鍵往下鑽一個垂直孔（放開就停），每公尺 SEC_PER_M 秒，最深 HAND_DEPTH m；
-- 對著地面往下鑽、對著岩壁水平鑽。要待在孔旁 STAY_R m 內、手上拿著鑽機。更深的孔用岩芯鑽探車（rockmech.coredrill_start，60 m）。碰到空洞或設施就停。
-- 鑽完：孔口留一根套管（混凝土墊、橘色套管、管蓋），岩芯裝進藍色岩芯箱放在孔口旁邊的地上。
--   岩芯箱比照碎石搬：左鍵捧起來（一次一個，不進背包），右鍵放下（可以疊起來當岩芯庫）。只有自己組（和老師）搬得動。
--   野帳本（$10）：拿著對岩芯箱右鍵判讀（每公尺 LOG_SEC_PER_M 秒，要待在 LOG_STAY m 內、手上拿著），記進野帳本；
--   右鍵（對岩芯箱以外的地方）打開野帳本看記過的孔（最多 BOOK_MAX 孔）。記下來的內容照判讀的人「當時」的能力：
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
-- 打開岩芯箱的狀態（捧起箱子時要先關掉在看的人的介面，所以放在前面）
local OPEN_FORM = "rockmech:corebox_open"
local opened = {}                          -- 方塊位置 → {玩家名稱 = true}
local viewing_box = {}                     -- 玩家名稱 → 方塊位置
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
-- 反過來：RQD → λ（二分法）
local function lambda_of(rqd)
	if rqd >= 99.9 then return 0 end
	local lo, hi = 0, 80
	for _ = 1, 40 do
		local m = (lo + hi) / 2
		if rqd_of(m) > rqd then lo = m else hi = m end
	end
	return (lo + hi) / 2
end
local function frac(n, i, k) local v = math.sin(n * 12.9898 + i * 78.233 + k * 37.719) * 43758.5453; return v - math.floor(v) end

-- 岩芯第 i 公尺的裂面：
--   細線 = 方塊尺度的小節理：RQD 由那裡的 GSI 反推（GSI = 52·r/(1+r) + RQD/2，r = 岩性的 Jr/Ja），
--          換成頻率 λ（Priest & Hudson），用指數分布的間距排位置（同一孔、同一公尺每次都一樣）
--   粗線 = 大尺度的節理組（類似斷層）穿過鑽孔的位置
-- 回傳 fine = {位置 0..1}, thick = {位置}, rqd（照畫出來的岩芯段算：≥ 10 cm 的段加起來）
local FINE_MAX = 30
local core_cache = setmetatable({}, {__mode = "k"})
local function core_breaks(bh, i)
	local r = bh.rows[i]
	local c = core_cache[r]
	if c then return c end
	local thick = {}
	for j = 1, math.min(r.joints or 0, 8) do thick[#thick + 1] = 0.1 + 0.8 * frac(bh.n, i, j) end
	local fine = {}
	local lith = rockmech.cfg.lithologies[r.lith]
	if lith and rockmech.collapse and rockmech.collapse.rock then
		local gsi = rockmech.collapse.rock.gsi(r.lith, bh.pos.y + (bh.dir and bh.dir.y or -1) * i)
		local q = (lith.jr or 2) / (lith.ja or 1)
		local target = math.max(0, math.min(100, 2 * (gsi - 52 * q / (1 + q))))
		local lam = lambda_of(target)
		if lam > 0 then
			local x, k = 0, 0
			while #fine < FINE_MAX do
				k = k + 1
				x = x - math.log(math.max(1e-6, frac(bh.n, i, 100 + k))) / lam
				if x >= 1 then break end
				fine[#fine + 1] = x
			end
		end
	end
	local all = {0, 1}
	for _, p in ipairs(fine) do all[#all + 1] = p end
	for _, p in ipairs(thick) do all[#all + 1] = p end
	table.sort(all)
	local sum = 0
	for k = 2, #all do
		local len = all[k] - all[k - 1]
		if len >= 0.1 then sum = sum + len end
	end
	c = {fine = fine, thick = thick, rqd = 100 * sum}
	core_cache[r] = c
	return c
end
rockmech.core_breaks = core_breaks        -- 測試用
local function rqd_txt(bh, i) return ("%.0f%%"):format(core_breaks(bh, i).rqd) end

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
	local out = {"formspec_version[6]size[15,11.4]",
		("label[0.5,0.6;%s]"):format(core.formspec_escape(bh.stop
			and S("@1   Collar (@2, @3, @4)   Depth @5 m (@6)", title, tostring(bh.pos.x), tostring(bh.pos.y), tostring(bh.pos.z), tostring(bh.depth), bh.stop)
			or S("@1   Collar (@2, @3, @4)   Depth @5 m", title, tostring(bh.pos.x), tostring(bh.pos.y), tostring(bh.pos.z), tostring(bh.depth)))),
		"label[0.5,1.2;" .. core.formspec_escape(S("Depth")) .. "]label[3.0,1.2;" .. core.formspec_escape(S("Log")) ..
		"]label[4.4,1.2;" .. core.formspec_escape(S("Lithology")) .. "]label[7.4,1.2;" .. core.formspec_escape(S("Grade")) ..
		"]label[9.6,1.2;" .. core.formspec_escape(S("Joints")) .. "]label[11.6,1.2;RQD]"}
	local rows = bh.rows or {}
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
		out[#out + 1] = ("label[11.6,%g;%s]"):format(y + H / 2, (soil or r.lith == "rubble") and "—" or rm and rqd_txt(bh, i) or "?")
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
	-- 底下的方塊被挖掉就跟著消失（attached_node：貼著下面那格）
	groups = {not_in_creative_inventory = 1, attached_node = 1},
	drop = "",
	on_rightclick = function(pos, node, clicker)
		if not (clicker and clicker:is_player()) then return end
		rockmech.borehole_name_form(clicker, pos)
	end,
})

-- 鑽孔取名：對套管右鍵。自己組（和老師）可以改；名字存在鑽孔紀錄（bh:<帳戶>）裡，空白就回到 BH-n
-- 爆破、崩塌直接改地圖，不會觸發貼附檢查：每 10 秒看一次，底下空了（不是可以站的方塊）就拿掉
core.register_abm({
	label = "Borehole casing without ground", nodenames = {CASING}, interval = 10, chance = 1,
	action = function(pos)
		local below = core.registered_nodes[core.get_node({x = pos.x, y = pos.y - 1, z = pos.z}).name]
		if below and below.walkable == false then core.remove_node(pos) end
	end,
})

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
	for _, p in ipairs(core.find_nodes_in_area(vector.subtract(pos, 48), vector.add(pos, 48), rockmech.corebox_names)) do
		local m = core.get_meta(p)
		if m:get_string("acc") == acc and m:get_int("n") == n then rockmech.corebox_relabel(p) end
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
-- 岩芯箱可以疊：一格裡最多 STACK_MAX 箱（一箱高 BOX_H = 0.4/3 m，實際的岩芯箱約 10 cm 高），滿了再往上一格疊。
-- 一格一個方塊：corebox（1 箱）、corebox_2 … corebox_7；最上面那箱的資料在 meta 的 acc、n、depth、core，
-- 下面幾箱在 meta below = {{acc, n, depth, core}, …}（由下往上）。打開、判讀、點荷重、捧起來都是對最上面那箱。
-- 有人在看：換成打開的版本（最上面那箱的箱蓋立在後面、看得到岩芯）
local BOX_H, STACK_MAX = 0.4 / 3, 7
-- 側面：每箱之間一條深色接縫（貼圖 30 px = 1 m，一箱 4 px，從底下往上）
local SIDE = "[fill:30x30:" .. BLUE
for k = 1, STACK_MAX do SIDE = SIDE .. ("^[fill:30x1:0,%d:#1a3a80"):format(30 - 4 * k) end
local open_top = ("[fill:16x16:%s"):format(BLUE)
for k = 0, 4 do open_top = open_top .. ("^[fill:14x2:1,%d:#a09a90"):format(1 + k * 3) end
local closed_of, open_of, count_of = {}, {}, {}      -- 箱數 → 名稱；名稱 → 箱數
for k = 1, STACK_MAX do
	closed_of[k] = k == 1 and COREBOX or (COREBOX .. "_" .. k)
	open_of[k] = k == 1 and COREBOX_OPEN or (COREBOX_OPEN .. "_" .. k)
	count_of[closed_of[k]], count_of[open_of[k]] = k, k
	local top = -0.5 + k * BOX_H
	local body = {-0.45, -0.5, -0.3, 0.45, top, 0.3}
	local common = {
		description = S("Core box"), drawtype = "nodebox", paramtype = "light", paramtype2 = "facedir",
		selection_box = {type = "fixed", fixed = body},
		groups = {crumbly = 3, falling_node = 1, not_in_creative_inventory = 1},
		is_ground_content = false, drop = "",
		on_rightclick = function(...) return corebox_rightclick(...) end,
	}
	local c = table.copy(common)
	c.tiles = {box_tex(true), box_tex(false), SIDE}
	c.node_box = {type = "fixed", fixed = body}
	core.register_node(closed_of[k], c)
	local o = table.copy(common)
	o.tiles = {open_top, box_tex(false), SIDE, SIDE, SIDE, "[fill:16x16:#3a72d8"}
	o.node_box = {type = "fixed", fixed = {body, {-0.45, top, 0.3, 0.45, top + 0.6, 0.34}}}
	core.register_node(open_of[k], o)
end

local function box_infotext(meta, data, k)
	meta:set_string("infotext", S("Core box @1 (@2, depth @3 m)\nRight-click to open it; left-click to pick it up; right-click with a field notebook to log it", bh_label(data.acc, data.n),
		rockmech.account_label and rockmech.account_label(data.acc) or data.acc, tostring(data.depth))
		.. (k > 1 and ("\n" .. S("@1 boxes stacked", tostring(k))) or ""))
end
local function top_of(meta)
	return {acc = meta:get_string("acc"), n = meta:get_int("n"), depth = meta:get_int("depth"), core = meta:get_string("core")}
end
local function set_top(meta, data)
	meta:set_string("acc", data.acc)
	meta:set_int("n", data.n)
	meta:set_int("depth", data.depth)
	-- 岩芯（每公尺的地層紀錄）裝在箱子裡：打開時直接讀，不用每次去翻全組的鑽孔紀錄；捧著走也跟著走
	local cs = data.core
	if not cs or cs == "" then
		local b = find_bh(data.acc, data.n)
		cs = b and core.serialize({pos = b.pos, rows = b.rows, stop = b.stop}) or ""
	end
	meta:set_string("core", cs)
end
-- 放一箱在 pos：空的那一格就放一箱（facedir：朝向，省略就隨機）；pos 已經是一疊岩芯箱就疊上去，滿了往上一格。
-- data = {acc, n, depth, core}。回傳放下了沒
function rockmech.corebox_put(pos, data, facedir)
	for _ = 1, 3 do
		local node = core.get_node(pos)
		local k = count_of[node.name]
		if k then
			if k < STACK_MAX then
				local meta = core.get_meta(pos)
				local below = core.deserialize(meta:get_string("below")) or {}
				below[#below + 1] = top_of(meta)
				meta:set_string("below", core.serialize(below))
				set_top(meta, data)
				local opened_now = node.name == open_of[k]
				core.swap_node(pos, {name = (opened_now and open_of or closed_of)[k + 1], param2 = node.param2})
				box_infotext(meta, data, k + 1)
				if rockmech.corebox_label_update then rockmech.corebox_label_update(pos) end
				return true
			end
			pos = {x = pos.x, y = pos.y + 1, z = pos.z}
		else
			local nd = core.registered_nodes[node.name]
			if not (nd and nd.buildable_to) then return false end
			core.set_node(pos, {name = COREBOX, param2 = facedir or math.random(0, 3)})
			local meta = core.get_meta(pos)
			set_top(meta, data)
			box_infotext(meta, data, 1)
			if rockmech.corebox_label_update then rockmech.corebox_label_update(pos) end
			return true
		end
	end
	return false
end
-- 捧起 pos 那一疊最上面的一箱：回傳 data，或 nil（不是自己組的）
function rockmech.corebox_take(pos, player)
	local node = core.get_node(pos)
	local k = count_of[node.name]
	if not k then return nil end
	local meta = core.get_meta(pos)
	local data = top_of(meta)
	if rockmech.owner_ok and not rockmech.owner_ok(data.acc, player:get_player_name()) then return nil end
	for name, p in pairs(viewing_box) do
		if vector.equals(p, pos) then core.close_formspec(name, OPEN_FORM); viewing_box[name] = nil end
	end
	opened[core.hash_node_position(pos)] = nil
	if k > 1 then
		local below = core.deserialize(meta:get_string("below")) or {}
		local nxt = table.remove(below) or data
		meta:set_string("below", core.serialize(below))
		set_top(meta, nxt)
		core.swap_node(pos, {name = closed_of[k - 1], param2 = node.param2})
		box_infotext(meta, nxt, k - 1)
	else
		core.remove_node(pos)
		core.check_for_falling({x = pos.x, y = pos.y + 1, z = pos.z})
	end
	if rockmech.corebox_label_update then rockmech.corebox_label_update(pos) end
	return data
end
rockmech.COREBOX = COREBOX

-- 箱蓋上的編號牌：白底黑字「BH-n」（最上面那箱的孔號）。方塊表面沒辦法每格不同，所以用一片薄薄的實體貼在箱蓋上；
-- 字是 3×5 的像素字（只有數字、B、H、-）。實體不存檔：放下、拿起、疊上去時更新，載入時（LBM）補上
local LABEL = "rockmech:corebox_label"
local GLYPH = {
	["0"] = "111101101101111", ["1"] = "010110010010111", ["2"] = "111001111100111", ["3"] = "111001111001111",
	["4"] = "101101111001001", ["5"] = "111100111001111", ["6"] = "111100111101111", ["7"] = "111001010010010",
	["8"] = "111101111101111", ["9"] = "111101111001111", B = "110101110101110", H = "101101111101101", ["-"] = "000000111000000",
}
local label_tex_cache = {}
local function label_tex(text)
	if label_tex_cache[text] then return label_tex_cache[text] end
	local w = #text * 4 + 1
	local t = {("[fill:%dx7:#f2efe4"):format(w)}
	for i = 1, #text do
		local g = GLYPH[text:sub(i, i)]
		if g then
			for j = 1, 15 do
				if g:sub(j, j) == "1" then
					t[#t + 1] = ("[fill:1x1:%d,%d:#1c1c1c"):format((i - 1) * 4 + 1 + (j - 1) % 3, 1 + math.floor((j - 1) / 3))
				end
			end
		end
	end
	label_tex_cache[text] = {tex = table.concat(t, "^"), w = w}
	return label_tex_cache[text]
end
core.register_entity(LABEL, {
	initial_properties = {visual = "cube", physical = false, pointable = false, static_save = false,
		textures = {"blank.png"}, use_texture_alpha = true},
	on_step = function(self, dtime)
		self.t = (self.t or 0) + dtime
		if self.t < 2 then return end
		self.t = 0
		-- 底下的箱子不見了、換了一箱：自己消失（新的那箱會再貼一張）
		local p = self.node_pos
		local m = p and core.get_meta(p)
		if not (p and count_of[core.get_node(p).name] and m:get_int("n") == self.n and m:get_string("acc") == self.acc) then
			self.object:remove()
		end
	end,
})
local function label_update(pos)
	for _, o in ipairs(core.get_objects_inside_radius(pos, 0.9)) do
		local e = o:get_luaentity()
		if e and e.name == LABEL and e.node_pos and vector.equals(e.node_pos, pos) then o:remove() end
	end
	local node = core.get_node(pos)
	local k = count_of[node.name]
	if not k then return end
	local meta = core.get_meta(pos)
	local n = meta:get_int("n")
	local lt = label_tex("BH-" .. n)
	local h = 0.17
	local o = core.add_entity({x = pos.x, y = pos.y - 0.5 + k * BOX_H + 0.004, z = pos.z}, LABEL)
	if not o then return end
	local tex = lt.tex
	o:set_properties({visual_size = {x = h * lt.w / 7, y = 0.006, z = h}, textures = {tex, tex, "blank.png", "blank.png", "blank.png", "blank.png"}})
	o:set_yaw(-(node.param2 % 4) * math.pi / 2)
	local e = o:get_luaentity()
	e.node_pos, e.n, e.acc = vector.copy(pos), n, meta:get_string("acc")
end
rockmech.corebox_label_update = label_update
core.register_lbm({
	label = "Core box number labels", name = "rockmech:corebox_labels", run_at_every_load = true,
	nodenames = (function() local t = {} for k = 1, STACK_MAX do t[#t + 1] = closed_of[k]; t[#t + 1] = open_of[k] end return t end)(),
	action = function(pos) core.after(0, label_update, vector.copy(pos)) end,
})

rockmech.corebox_names = {}
for k = 1, STACK_MAX do table.insert(rockmech.corebox_names, closed_of[k]); table.insert(rockmech.corebox_names, open_of[k]) end
function rockmech.corebox_relabel(p)
	local k = count_of[core.get_node(p).name]
	if k then local meta = core.get_meta(p); box_infotext(meta, top_of(meta), k) end
end

---------------------------------------------------------------------------
-- 打開岩芯箱：右鍵打開（旁人看到箱蓋掀起來、裡面一排排岩芯），自己看到一個大的岩芯箱介面：
--   藍色箱子、一槽一條 5 m 的岩芯、一次看 5 槽（25 m），更深的往下捲。
--   岩芯照實際岩石的顏色畫，節理是岩芯上的黑色裂縫、碎石段是碎塊；
--   自己有「岩體分類」才在每公尺下面標岩性、RQD、節理，有「品位判讀」才標品位（看的人「現在」的能力）。
---------------------------------------------------------------------------

local PER_ROW, VIEW_ROWS = 5, 5            -- 一槽幾公尺、一次看幾槽
local function is_corebox(name) return count_of[name] ~= nil end
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
	local k = count_of[node.name]
	if k and node.name == open_of[k] then core.swap_node(pos, {name = closed_of[k], param2 = node.param2}) end
end

-- 0..1 的假亂數（同一孔同一公尺每次一樣）：節理裂縫畫在那一公尺的哪裡、碎石段的碎塊
-- 岩芯的外觀：鑽到的是什麼方塊就畫什麼方塊的貼圖（礦石方塊再乘上那一格品位的顏色，跟世界裡看到的一樣）
local PLT_NODE, PLT_R = "rockmech:point_load", 3
local cb_state = {}                        -- 玩家名稱 → {sel = 選的那一公尺, scroll = 捲軸位置, last = 上一次試驗的結果}
local function row_node(r)
	if r.node and core.registered_nodes[r.node] then return r.node end
	if r.lith == "soil" then return rockmech.RUBBLE_SOIL end
	if r.lith == "rubble" then return rockmech.RUBBLE end
	return rockmech.node_of_lith[r.lith]
end
local function seg_tex(r)
	local name = row_node(r)
	local def = name and core.registered_nodes[name]
	if not def then return "[fill:16x16:" .. lith_color(r.lith) end
	local tiles = def.tiles or {}
	local t = tiles[3] or tiles[#tiles] or tiles[1] or "blank.png"
	if type(t) == "table" then t = t.name or "blank.png" end
	local lith = rockmech.lith_of_node[name]
	if def.paramtype2 == "color" and lith and lith.ore and rockmech.ore_color then
		t = t .. "^[multiply:" .. rockmech.ore_color(lith.ore, r.p2 or r.grade or 0)
	end
	return t
end
local function crumbly(r) return r.lith == "rubble" or r.lith == "soil" end
-- 同一張方塊貼圖橫排 n 格拼成一張（[combine 裡的 ^ 和 : 要用 \ 跳脫）
local function strip_tex(t, n)
	local e = t:gsub("\\", "\\\\"):gsub("%^", "\\^"):gsub(":", "\\:")
	local parts = {("[combine:%dx16"):format(16 * n)}
	for q = 0, n - 1 do parts[#parts + 1] = ("%d,0=%s\\^[resize\\:16x16"):format(16 * q, e) end
	return table.concat(parts, ":")
end
local function plt_near(pos) return pos and core.find_node_near(pos, PLT_R, {PLT_NODE}, true) ~= nil end

local function corebox_form(name, bh, acc, pos)
	local st = cb_state[name] or {}
	cb_state[name] = st
	local rm, gr = see(name, "rockmass"), see(name, "grade")
	local rows = bh.rows or {}
	local nrow = math.max(1, math.ceil(#rows / PER_ROW))
	local RH, X0, W = 2.2, 1.0, 17.6          -- 一槽高、岩芯起點、5 m 岩芯的長度
	local MW = W / PER_ROW
	local TOP, VIEW = 1.2, VIEW_ROWS * RH
	local esc = core.formspec_escape
	local out = {"formspec_version[6]size[20.4,14.6]",
		"style_type[label;font_size=*0.85]",
		("label[0.5,0.6;%s]"):format(esc(S("Core box @1 (@2)   Collar (@3, @4, @5)   Depth @6 m", label_of(bh),
			rockmech.account_label and rockmech.account_label(acc) or acc,
			tostring(bh.pos.x), tostring(bh.pos.y), tostring(bh.pos.z), tostring(bh.depth)))),
		("box[0.3,%g;19.4,%g;#2a62c8]"):format(TOP - 0.1, VIEW + 0.2),
		("scroll_container[0.3,%g;19.4,%g;cb_scroll;vertical;0.1]"):format(TOP, VIEW)}
	local buttons = {}
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
			local tex = esc(seg_tex(r))
			out[#out + 1] = ("label[%g,%g;%d]"):format(x, y0 + 0.36, i - 1)
			if st.sel == i then
				out[#out + 1] = ("box[%g,%g;%g,%g;#ffd040]"):format(x, cy - 0.05, MW, ch + 0.1)
			end
			if crumbly(r) then
				-- 碎石、土：一堆碎塊（取出來不成柱）
				local px, c = x + 0.04, 0
				while px < x + MW - 0.15 do
					c = c + 1
					local w = math.min(0.15 + 0.35 * frac(bh.n, i, c), x + MW - 0.04 - px)
					local hh = ch * (0.45 + 0.5 * frac(bh.n, i, c + 50))
					out[#out + 1] = ("image[%g,%g;%g,%g;%s]"):format(px, cy + ch - hh, w, hh, tex)
					px = px + w + 0.06
				end
			else
				-- 岩芯：方塊貼圖一格一格排成一條，拼成一張圖（一公尺一個元件，介面才不會卡）
				local L = MW - 0.08
				local nq = math.max(1, math.floor(L / ch + 0.5))
				out[#out + 1] = ("image[%g,%g;%g,%g;%s]"):format(x + 0.04, cy, L, ch, esc(strip_tex(seg_tex(r), nq)))
				out[#out + 1] = ("box[%g,%g;%g,0.06;#ffffff28]"):format(x + 0.04, cy + 0.1, L)
				-- 裂面：細線是小節理（RQD），粗線是大尺度的節理組
				local br = core_breaks(bh, i)
				for _, p in ipairs(br.fine) do
					out[#out + 1] = ("box[%g,%g;0.025,%g;#1a1a1acc]"):format(x + 0.04 + L * p, cy, ch)
				end
				for _, p in ipairs(br.thick) do
					out[#out + 1] = ("box[%g,%g;0.1,%g;#0a0a0a]"):format(x + 0.04 + L * p - 0.05, cy - 0.04, ch + 0.08)
				end
			end
			-- 點一段岩芯：選它（上面再疊一個透明的按鈕）
			buttons[#buttons + 1] = ("image_button[%g,%g;%g,%g;blank.png;seg_%d;;true;false]"):format(x + 0.04, cy, MW - 0.08, ch, i)
			if rm then
				local is_ore = rockmech.cfg.ores[r.lith] ~= nil or (rockmech.cfg.lithologies[r.lith] or {}).ore ~= nil
				out[#out + 1] = ("label[%g,%g;%s]"):format(x + 0.06, y0 + 1.27, esc(lith_label(r.lith)))
				if not crumbly(r) then
					out[#out + 1] = ("label[%g,%g;%s]"):format(x + 0.06, y0 + 1.6,
						esc(S("RQD @1  joints @2", rqd_txt(bh, i), tostring(r.joints or 0))))
				end
				if is_ore or r.grade then
					out[#out + 1] = ("label[%g,%g;%s]"):format(x + 0.06, y0 + 1.93, esc((gr and r.grade)
						and S("grade @1%", ("%.0f"):format(r.grade / 255 * 100)) or S("grade ?")))
				end
			end
		end
		local last = math.min(#rows, (k + 1) * PER_ROW)
		if last == (k + 1) * PER_ROW then
			out[#out + 1] = ("label[%g,%g;%d]"):format(X0 + W - 0.2, y0 + 0.36, last)
		elseif last < (k + 1) * PER_ROW then
			out[#out + 1] = ("label[%g,%g;%s]"):format(X0 + (last - k * PER_ROW) * MW + 0.1, y0 + 0.9,
				esc(S("End of hole @1 m", tostring(#rows))))
		end
	end
	for _, b in ipairs(buttons) do out[#out + 1] = b end
	-- 選了一段：旁邊浮出選項
	local r = st.sel and rows[st.sel]
	if r then
		local k, m = math.floor((st.sel - 1) / PER_ROW), (st.sel - 1) % PER_ROW
		local px, py = X0 + m * MW, k * RH + 1.15
		if m == PER_ROW - 1 then px = X0 + W - 3.6 end
		out[#out + 1] = ("box[%g,%g;3.6,0.9;#101820e8]"):format(px, py)
		if crumbly(r) then
			out[#out + 1] = ("label[%g,%g;%s]"):format(px + 0.15, py + 0.45, esc(S("No specimen")))
		elseif not plt_near(pos) then
			out[#out + 1] = ("label[%g,%g;%s]"):format(px + 0.15, py + 0.45, esc(S("No point load tester nearby")))
		else
			out[#out + 1] = ("button[%g,%g;3.4,0.7;plt_go;%s]"):format(px + 0.1, py + 0.1, esc(S("Point load test")))
		end
	end
	out[#out + 1] = "scroll_container_end[]"
	local bottom = TOP + VIEW + 0.3
	if nrow > VIEW_ROWS then
		out[#out + 1] = ("scrollbaroptions[max=%d;smallstep=%d;largestep=%d;arrows=show]"):format(
			math.floor((nrow - VIEW_ROWS) * RH * 10 + 0.5), math.floor(RH * 10 + 0.5), math.floor(VIEW * 10 + 0.5))
		out[#out + 1] = ("scrollbar[19.75,%g;0.45,%g;vertical;cb_scroll;%d]"):format(TOP - 0.1, VIEW + 0.2, st.scroll or 0)
	end
	if st.last then out[#out + 1] = ("label[0.5,%g;%s]"):format(bottom + 0.1, esc(st.last)) end
	return table.concat(out)
end

-- 點荷重試驗：一個試體，讀 Is(50)（± 10 % 散布），記進野帳本
local function point_load(player, pos, bh, acc, i)
	local name = player:get_player_name()
	local r = bh.rows[i]
	local lith = r and rockmech.cfg.lithologies[r.lith]
	if not lith or crumbly(r) or not plt_near(pos) then return end
	local K = rockmech.PLT_K or 22
	local is50 = lith.ucs / (rockmech.cfg.model_scale or 1) / K * (1 + (math.random() * 2 - 1) * 0.1)
	is50 = math.floor(is50 * 100 + 0.5) / 100
	local rec = {acc = acc, n = bh.n, d = i - 1, lith = see(name, "rockmass") and r.lith or nil, is = is50}
	local cnt = rockmech.fieldbook_add_plt and rockmech.fieldbook_add_plt(player, rec)
	local where = ("%s %d–%d m"):format(label_of(bh), i - 1, i)
	local msg = cnt and S("[Point load] @1: Is(50) = @2 MPa (field notebook, @3)", where, ("%.2f"):format(is50), tostring(cnt))
		or S("[Point load] @1: Is(50) = @2 MPa (no field notebook: not recorded)", where, ("%.2f"):format(is50))
	cb_state[name].last = msg
	rockmech.notify(name, msg)
	core.sound_play("default_dig_cracky", {pos = pos, gain = 0.6, max_hear_distance = 10}, true)
end

local function open_box(pos, clicker)
	if not (clicker and clicker:is_player()) then return end
	local name = clicker:get_player_name()
	local meta = core.get_meta(pos)
	local acc, n = meta:get_string("acc"), meta:get_int("n")
	-- 岩芯從箱子裡拿（舊的箱子沒有就去翻一次鑽孔紀錄，順便裝進箱子）
	local c = core.deserialize(meta:get_string("core"))
	if not (c and c.rows) then
		local b = find_bh(acc, n)
		if not b then rockmech.notify(name, S("[Core box] No borehole record found for this box")); return end
		c = {pos = b.pos, rows = b.rows, stop = b.stop}
		meta:set_string("core", core.serialize(c))
	end
	local bh = {n = n, pos = c.pos, rows = c.rows, stop = c.stop, depth = #c.rows, name = (find_bh(acc, n) or {}).name}
	close_for(name)
	local node = core.get_node(pos)
	local k = count_of[node.name]
	if k and node.name == closed_of[k] then core.swap_node(pos, {name = open_of[k], param2 = node.param2}) end
	local key = core.hash_node_position(pos)
	opened[key] = opened[key] or {}
	opened[key][name] = true
	viewing_box[name] = vector.copy(pos)
	cb_state[name] = {bh = bh, acc = acc}      -- 打開期間點來點去都用這份，不再讀
	core.sound_play("default_dig_choppy", {pos = pos, gain = 0.3, max_hear_distance = 10}, true)
	core.show_formspec(name, OPEN_FORM, corebox_form(name, bh, acc, pos))
end
corebox_rightclick = function(pos, node, clicker, itemstack)
	open_box(pos, clicker)
	return itemstack
end
core.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= OPEN_FORM then return end
	local name = player:get_player_name()
	if fields.quit then close_for(name); cb_state[name] = nil; return true end
	local pos = viewing_box[name]
	local st = cb_state[name]
	if not (pos and st and is_corebox(core.get_node(pos).name)) then return true end
	local v = fields.cb_scroll and tonumber(fields.cb_scroll:match(":(%d+)"))
	if v then st.scroll = v end
	local bh, acc = st.bh, st.acc
	if not bh then return true end
	local changed = false
	for k in pairs(fields) do
		local i = tonumber(k:match("^seg_(%d+)$"))
		if i then st.sel = st.sel ~= i and i or nil; changed = true end
	end
	if fields.plt_go and st.sel then point_load(player, pos, bh, acc, st.sel); changed = true end
	if changed then core.show_formspec(name, OPEN_FORM, corebox_form(name, bh, acc, pos)) end
	return true
end)
core.register_on_leaveplayer(function(player) close_for(player:get_player_name()) end)
-- 重開伺服器時沒人在看：打開的箱子蓋回去
core.register_lbm({
	label = "Close open core boxes", name = "rockmech:corebox_close", nodenames = open_of, run_at_every_load = true,
	action = function(pos, node)
		if not opened[core.hash_node_position(pos)] then core.swap_node(pos, {name = closed_of[count_of[node.name]], param2 = node.param2}) end
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
-- 野帳本：右鍵對岩芯箱判讀，右鍵其他地方翻開。記在物品 meta：logs = {{acc, n, rm, gr, by}, ...}、schmidt、plt
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
-- 點荷重的讀數（打開的岩芯箱裡做）：meta plt = {{acc, n, d（從幾公尺）, lith, is}, …}
local function plt_of(stack) return core.deserialize(stack:get_meta():get_string("plt")) or {} end
function rockmech.fieldbook_add_plt(player, rec)
	local inv = player:get_inventory()
	for i, st in ipairs(inv:get_list("main") or {}) do
		if st:get_name() == BOOK then
			local list = plt_of(st)
			if #list >= SCHMIDT_MAX then table.remove(list, 1) end
			list[#list + 1] = rec
			st:get_meta():set_string("plt", core.serialize(list))
			inv:set_stack("main", i, st)
			return #list
		end
	end
end
---------------------------------------------------------------------------
-- 野帳本的樣子：一本直式的書（咖啡色硬皮、米色紙、淡藍橫線、紅色邊線、看得到一疊書頁的邊、紅色書籤繩），
-- 分頁像便條紙貼在書的右邊外面：
--   野外調查：施密特錘的讀數
--   岩芯：目錄是記過的鑽孔（判讀過的、或做過點荷重的），點一孔翻到那一孔的柱狀圖；
--         點荷重做過的那幾公尺，強度欄自動標上 Is(50) 和換算的 UCS（同一公尺做過幾次取平均）
-- 顏色都在 BOOK_COLORS，可以用 rockmech.ui_color 在世界裡改（mod storage ui_color:<名字>）
---------------------------------------------------------------------------
local BOOK_COLORS = {
	book_cover = "#5a3a22", book_cover_edge = "#7a5232", book_page = "#f4eddb", book_page_edge = "#ddd3b8",
	book_ink = "#2b2620", book_rule = "#bfd0de", book_margin = "#d88080", book_ribbon = "#a02828",
	book_tab_field = "#f2d65c", book_tab_core = "#8cc0e8", book_tab_stereo = "#9ad08a", book_hover = "#00000018",
}
function rockmech.ui_color(key)
	local v = storage:get_string("ui_color:" .. key)
	return v ~= "" and v or BOOK_COLORS[key] or rockmech.ui_color_defaults and rockmech.ui_color_defaults[key]
end
rockmech.ui_color_defaults = rockmech.ui_color_defaults or {}
for k, v in pairs(BOOK_COLORS) do rockmech.ui_color_defaults[k] = v end
local C = rockmech.ui_color

local book_state = {}       -- 玩家名稱 → {tab = "core" | "field", hole = 目錄第幾孔}
local logging = {}          -- 玩家名稱 → {pos, acc, n, depth, t, need, hud}
local function ink(t) return core.formspec_escape(core.colorize(C("book_ink"), t)) end

-- 這本記到的鑽孔：判讀過的（logs）在前，只做過點荷重的接在後面（岩性、品位看不懂，記成 ?）
local function book_holes(stack)
	local list, seen = {}, {}
	for _, e in ipairs(book_entries(stack)) do
		local k = e.acc .. "#" .. e.n
		if not seen[k] then seen[k] = true; list[#list + 1] = {acc = e.acc, n = e.n, rm = e.rm, gr = e.gr, logged = true} end
	end
	for _, p in ipairs(plt_of(stack)) do
		local k = p.acc .. "#" .. p.n
		if not seen[k] then seen[k] = true; list[#list + 1] = {acc = p.acc, n = p.n, rm = false, gr = false} end
	end
	return list
end
-- 某一孔每公尺的點荷重平均：d（從幾公尺）→ {sum, c}
local function plt_by_metre(stack, acc, n)
	local t = {}
	for _, p in ipairs(plt_of(stack)) do
		if p.acc == acc and p.n == n then
			local s = t[p.d] or {sum = 0, c = 0}
			s.sum, s.c = s.sum + p.is, s.c + 1
			t[p.d] = s
		end
	end
	return t
end

-- 版面（單位：formspec 格）
local BW, BH = 10.8, 14.2             -- 書（硬皮）的寬、高
local PX, PY, PW, PH = 0.45, 0.35, 9.8, 13.3   -- 紙
local LX, RX = 1.75, PX + PW - 0.25   -- 紅色邊線右邊開始寫字、右邊界
local LINE = 0.5                      -- 橫線間距（表格一列一格）
local BODY_Y, BODY_H = 2.35, 10.5     -- 表格內容（可以捲動）

local function book_frame(st, page_no)
	local out = {("formspec_version[6]size[%g,%g]bgcolor[#00000000;false]"):format(BW + 2.1, BH + 0.3)}
	-- 便條紙分頁（先畫，被封皮蓋住一半，看起來是夾在書裡、從右邊露出來）
	local tabs = {{"field", S("Field survey"), 1.3}, {"core", S("Cores"), 2.75}, {"stereo", S("Stereonet"), 4.2}}
	for _, t in ipairs(tabs) do
		local on = st.tab == t[1]
		local x = BW - 0.6 + (on and 0.25 or 0)
		out[#out + 1] = ("box[%g,%g;2.4,1.25;%s]"):format(x + 0.08, t[3] + 0.08, "#00000040")
		out[#out + 1] = ("box[%g,%g;2.4,1.25;%s]"):format(x, t[3], C("book_tab_" .. t[1]) .. (on and "" or "c0"))
	end
	-- 陰影、硬皮、書頁的邊（一疊紙）
	out[#out + 1] = ("box[0.18,0.22;%g,%g;#00000055]"):format(BW, BH)
	out[#out + 1] = ("box[0,0;%g,%g;%s]"):format(BW, BH, C("book_cover"))
	out[#out + 1] = ("box[0,0;%g,0.06;%s]box[0,0;0.06,%g;%s]"):format(BW, C("book_cover_edge"), BH, C("book_cover_edge"))
	for i = 3, 1, -1 do
		out[#out + 1] = ("box[%g,%g;%g,%g;%s]"):format(PX, PY, PW + i * 0.05, PH + i * 0.05, i % 2 == 1 and C("book_page_edge") or C("book_page"))
	end
	out[#out + 1] = ("box[%g,%g;%g,%g;%s]"):format(PX, PY, PW, PH, C("book_page"))
	-- 裝訂邊的陰影
	for i = 0, 3 do out[#out + 1] = ("box[%g,%g;%g,%g;#0000000c]"):format(PX, PY, 0.35 - i * 0.08, PH) end
	-- 橫線、紅色邊線
	for y = BODY_Y, PY + PH - 0.6, LINE do out[#out + 1] = ("box[%g,%g;%g,0.02;%s]"):format(PX + 0.1, y, PW - 0.2, C("book_rule")) end
	out[#out + 1] = ("box[%g,%g;0.03,%g;%s]"):format(LX - 0.15, PY, PH, C("book_margin"))
	-- 書籤繩
	out[#out + 1] = ("box[%g,%g;0.22,0.95;%s]"):format(PX + PW - 1.4, PY, C("book_ribbon"))
	-- 頁碼
	if page_no then out[#out + 1] = ("label[%g,%g;%s]"):format(PX + PW / 2 - 0.3, PY + PH - 0.35, ink("— " .. page_no .. " —")) end
	-- 分頁的字和按鈕（蓋在露出來的那一截上）
	for _, t in ipairs(tabs) do
		local on = st.tab == t[1]
		local x = BW + 0.05 + (on and 0.25 or 0)
		out[#out + 1] = ("style[tab_%s;bgcolor=#00000000;border=false;textcolor=%s]"):format(t[1], C("book_ink"))
		out[#out + 1] = ("button[%g,%g;1.7,1.25;tab_%s;%s]"):format(x, t[3], t[1], core.formspec_escape(t[2]))
	end
	out[#out + 1] = ("style[close;bgcolor=#00000000;border=false;textcolor=%s]"):format(C("book_ink"))
	out[#out + 1] = ("button_exit[%g,%g;0.6,0.6;close;×]"):format(PX + PW - 0.75, PY + 0.1)
	return out
end
local function title(out, text)
	out[#out + 1] = ("label[%g,1.05;%s]"):format(LX, ink(text))
	out[#out + 1] = ("box[%g,1.4;%g,0.03;%s]"):format(LX, RX - LX, C("book_ink"))
end
local function scroll_body(out, n)
	local content = n * LINE
	out[#out + 1] = "scroll_container_end[]"
	if content > BODY_H then
		out[#out + 1] = ("scrollbaroptions[max=%d;smallstep=%d;largestep=%d]"):format(
			math.floor(math.ceil((content - BODY_H) / LINE) * LINE * 10 + 0.5), math.floor(LINE * 10 + 0.5), math.floor(math.floor(BODY_H / LINE) * LINE * 10 + 0.5))
		out[#out + 1] = ("scrollbar[%g,%g;0.25,%g;vertical;bk_scroll;0]"):format(PX + PW - 0.3, BODY_Y, BODY_H)
	end
end

local function core_toc(out, holes)
	title(out, S("Cores"))
	out[#out + 1] = ("scroll_container[0,%g;%g,%g;bk_scroll;vertical;0.1]"):format(BODY_Y, BW, BODY_H)
	for i, h in ipairs(holes) do
		local y = (i - 1) * LINE
		local text = S("@1 (@2)", bh_label(h.acc, h.n), rockmech.account_label and rockmech.account_label(h.acc) or h.acc)
			.. (h.rm and "" or " " .. S("rock mass?")) .. (h.gr and "" or " " .. S("grade?"))
		out[#out + 1] = ("label[%g,%g;%s]"):format(LX, y + LINE / 2, ink(text))
		out[#out + 1] = ("style[h_%d;bgcolor=#00000000;border=false]style[h_%d:hovered;bgcolor=%s]"):format(i, i, C("book_hover"))
		out[#out + 1] = ("button[%g,%g;%g,%g;h_%d;]"):format(LX - 0.1, y + 0.02, RX - LX, LINE - 0.04, i)
	end
	scroll_body(out, #holes)
end

local function core_page(out, h, stack)
	local b = find_bh(h.acc, h.n)
	out[#out + 1] = ("style[back;bgcolor=#00000000;border=false;textcolor=%s]"):format(C("book_ink"))
	out[#out + 1] = ("button[%g,0.45;1.6,0.5;back;%s]"):format(LX - 0.1, core.formspec_escape("← " .. S("Cores")))
	if not b then
		title(out, "?")
		out[#out + 1] = ("label[%g,%g;%s]"):format(LX, BODY_Y + 0.25, ink(S("[Core box] No record found for this hole")))
		return
	end
	local rm, gr = h.rm, h.gr
	title(out, S("@1   Collar (@2, @3, @4)   Depth @5 m", label_of(b), tostring(b.pos.x), tostring(b.pos.y), tostring(b.pos.z), tostring(b.depth)))
	local X = {LX, LX + 1.0, LX + 1.8, LX + 3.5, LX + 4.45, LX + 5.25, LX + 6.2, LX + 7.4}
	local heads = {S("Depth"), S("Log"), S("Lithology"), S("Grade"), S("Joints"), "RQD", "Is(50)", "UCS"}
	for i, t in ipairs(heads) do out[#out + 1] = ("label[%g,1.75;%s]"):format(X[i], ink(t)) end
	out[#out + 1] = ("label[%g,2.08;%s]label[%g,2.08;%s]"):format(X[7], ink("MPa"), X[8], ink("MPa"))
	local rows = b.rows or {}
	local plt = plt_by_metre(stack, h.acc, h.n)
	local K = rockmech.PLT_K or 22
	out[#out + 1] = ("scroll_container[0,%g;%g,%g;bk_scroll;vertical;0.1]"):format(BODY_Y, BW, BODY_H)
	for i, r in ipairs(rows) do
		local y = (i - 1) * LINE
		local soil = r.lith == "soil"
		local is_ore = rockmech.cfg.ores[r.lith] ~= nil or (rockmech.cfg.lithologies[r.lith] or {}).ore ~= nil
		local g = "—"
		if is_ore or r.grade then g = gr and r.grade and ("%.0f%%"):format(r.grade / 255 * 100) or (gr and "—" or "?") end
		local p = plt[i - 1]
		local cells = {("%d–%d"):format(i - 1, i), nil, rm and lith_label(r.lith) or "?", g,
			soil and "—" or rm and tostring(r.joints or 0) or "?",
			(soil or r.lith == "rubble") and "—" or rm and rqd_txt(b, i) or "?",
			p and ("%.2f"):format(p.sum / p.c) .. (p.c > 1 and (" ×" .. p.c) or "") or "",
			p and ("%.0f"):format(K * p.sum / p.c) or ""}
		for k = 1, 8 do
			if cells[k] then out[#out + 1] = ("label[%g,%g;%s]"):format(X[k], y + LINE / 2, ink(cells[k])) end
		end
		out[#out + 1] = ("image[%g,%g;0.6,%g;%s]"):format(X[2], y + 0.08, LINE - 0.14, core.formspec_escape(strip_tex(seg_tex(r), 2)))
	end
	scroll_body(out, #rows)
end

local function field_page(out, list)
	title(out, S("Field survey"))
	local X = {LX, LX + 1.0, LX + 3.9, LX + 6.4}
	local heads = {S("No."), S("Position"), S("Rock"), S("Reading")}
	for i, t in ipairs(heads) do out[#out + 1] = ("label[%g,1.9;%s]"):format(X[i], ink(t)) end
	out[#out + 1] = ("scroll_container[0,%g;%g,%g;bk_scroll;vertical;0.1]"):format(BODY_Y, BW, BODY_H)
	-- 施密特錘的讀數是數字（R），寫在第 4 欄；應力量測的讀數是一行字（txt），寫在下一行
	local row = 0
	for i, e in ipairs(list) do
		local y = row * LINE
		local cells = {tostring(i), ("(%d, %d, %d)"):format(e.x, e.y, e.z), e.lith and lith_label(e.lith) or "?", e.r and ("R " .. tostring(e.r)) or ""}
		for k = 1, 4 do out[#out + 1] = ("label[%g,%g;%s]"):format(X[k], y + LINE / 2, ink(cells[k])) end
		row = row + 1
		if e.txt then
			out[#out + 1] = ("label[%g,%g;%s]"):format(X[2], row * LINE + LINE / 2, ink(e.txt))
			row = row + 1
		end
	end
	scroll_body(out, row)
	if #list > 0 then
		out[#out + 1] = "style[clear_sch;bgcolor=#00000000;border=false;textcolor=#8a3a30]"
		out[#out + 1] = ("button[%g,%g;2.6,0.5;clear_sch;%s]"):format(LX - 0.1, PY + PH - 0.6, core.formspec_escape(S("Tear out this page")))
	end
end

-- 赤平投影頁：圖（伺服器畫的 PNG，先傳給玩家，st.stereo = {fname, info}）＋各組平均位態、坡面、摩擦圓
local function stereo_page(out, st)
	title(out, S("Stereonet (lower hemisphere, equal-angle)"))
	local sv = st.stereo
	if not sv then
		out[#out + 1] = ("label[%g,%g;%s]"):format(LX, BODY_Y + 0.25, ink(S("Drawing…")))
		return
	end
	out[#out + 1] = ("image[%g,1.55;7.2,7.2;%s]"):format(LX + 0.5, sv.fname)
	local sets = rockmech.get_joint_sets()
	local y = 9.05
	local function row(color, text)
		if color then out[#out + 1] = ("box[%g,%g;0.25,0.25;%s]"):format(LX, y - 0.12, color) end
		out[#out + 1] = ("label[%g,%g;%s]"):format(LX + 0.4, y, ink(text))
		y = y + 0.4
	end
	if #sv.info.means == 0 then row(nil, S("No joint readings yet (compass: right-click a rock face, then E)")) end
	for _, m in ipairs(sv.info.means) do
		local js = sets[m.s]
		row(js and js.color, S("@1: @2 readings, mean @3°/@4°", js and js.name or "?", tostring(m.n), ("%02.0f"):format(m.d), ("%03.0f"):format(m.a))
			.. (js and js.phi and ("   φj %.0f°"):format(js.phi) or ""))
	end
	local sl = sv.info.slope
	row("#202020", sl and S("Slope: @1°/@2° (thick black line; the square is its pole)", ("%02.0f"):format(sl.d), ("%03.0f"):format(sl.a))
		or S("Slope: not measured yet (Shift + E to measure the slope)"))
	if sv.info.kin then
		-- 會赤平投影穩定性分析：可能的破壞模式（顏色跟圖上的危險區一樣）
		if not sl then row(nil, S("Measure the slope first to see the failure modes"))
		else for _, v in ipairs(sv.info.kin) do row(v.color, v.text) end end
	else
		if #sv.info.means > 0 then row(nil, S("Circles: friction circle of each measured set, in its colour (φj = atan(Jr/Ja))")) end
		row(nil, S("Markland: pole outside the circle, same side as the slope pole, flatter than the slope → may slide"))
	end
	out[#out + 1] = "style[clear_stereo;bgcolor=#00000000;border=false;textcolor=#8a3a30]"
	out[#out + 1] = ("button[%g,%g;2.6,0.5;clear_stereo;%s]"):format(LX - 0.1, PY + PH - 0.6, core.formspec_escape(S("Tear out this page")))
end

local function book_form(name, stack)
	local st = book_state[name] or {tab = "core"}
	book_state[name] = st
	local out
	if st.tab == "stereo" then
		out = book_frame(st, nil)
		stereo_page(out, st)
	elseif st.tab == "field" then
		out = book_frame(st, 1)
		field_page(out, schmidt_of(stack))
	else
		local holes = book_holes(stack)
		local h = st.hole and holes[st.hole]
		out = book_frame(st, h and (st.hole + 2) or 2)
		if h then core_page(out, h, stack) else st.hole = nil; core_toc(out, holes) end
	end
	return table.concat(out)
end
-- 打開野帳本（hole：直接翻到這一孔 {acc, n}）
local function open_book(player, stack, hole)
	local name = player:get_player_name()
	local st = {tab = "core"}
	if hole then
		for i, h in ipairs(book_holes(stack)) do
			if h.acc == hole.acc and h.n == hole.n then st.hole = i end
		end
	end
	book_state[name] = st
	core.show_formspec(name, BOOK_FORM, book_form(name, stack))
end

core.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= BOOK_FORM then return end
	local name = player:get_player_name()
	if fields.quit then book_state[name] = nil; return true end
	local stack = player:get_wielded_item()
	local st = book_state[name]
	if stack:get_name() ~= BOOK or not st then return true end
	local changed = false
	if fields.tab_field then st.tab, st.hole, changed = "field", nil, true end
	if fields.tab_core then st.tab, st.hole, changed = "core", nil, true end
	if fields.clear_stereo and rockmech.stereonet_clear then
		rockmech.stereonet_clear(stack)
		player:set_wielded_item(stack)
		fields.tab_stereo = true
	end
	if fields.tab_stereo and rockmech.stereonet_media then
		-- 先畫圖、傳給玩家，傳到了才顯示這一頁
		st.tab, st.hole, st.stereo = "stereo", nil, nil
		core.show_formspec(name, BOOK_FORM, book_form(name, stack))
		rockmech.stereonet_media(name, rockmech.stereonet_data(stack), function(fname, info)
			if book_state[name] ~= st or st.tab ~= "stereo" then return end
			st.stereo = {fname = fname, info = info}
			local p = core.get_player_by_name(name)
			if p and p:get_wielded_item():get_name() == BOOK then
				core.show_formspec(name, BOOK_FORM, book_form(name, p:get_wielded_item()))
			end
		end)
		return true
	end
	if fields.back then st.hole, changed = nil, true end
	if fields.clear_sch then
		stack:get_meta():set_string("schmidt", "")
		player:set_wielded_item(stack)
		changed = true
	end
	for k in pairs(fields) do
		local i = tonumber(k:match("^h_(%d+)$"))
		if i then st.hole, changed = i, true end
	end
	if changed then core.show_formspec(name, BOOK_FORM, book_form(name, stack)) end
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
	-- 按住右鍵時 on_place 會一直重複觸發：同一箱已經在判讀就不重來
	if logging[name] and vector.equals(logging[name].pos, pos) then return end
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
	rockmech.notify(name, S("[Field notebook] Logging @1 (depth @2 m, about @3 s): keep holding right-click on the core box",
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
			elseif not p:get_player_control().place then
				stop_logging(name, S("You let go of right-click; logging interrupted"))
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
					stack:get_meta():set_string("description", S("Field notebook (@1 / @2 holes)\nRight-click a core box to log it; right-click anywhere else to see logged holes", tostring(#entries), tostring(BOOK_MAX)))
					p:set_wielded_item(stack)
					stop_logging(name, (e.rm and e.gr)
						and S("@1 logged: right-click to open the field notebook", bh_label(L.acc, L.n))
						or S("@1 logged (some fields you cannot interpret were recorded as ?): right-click to open the field notebook", bh_label(L.acc, L.n)))
					open_book(p, stack, {acc = L.acc, n = L.n})
				end
			end
		end
	end
end)
core.register_on_leaveplayer(function(player) logging[player:get_player_name()] = nil; book_state[player:get_player_name()] = nil end)

core.register_craftitem(BOOK, {
	description = S("Field notebook\nRight-click a core box to log it; right-click anywhere else to read"),
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
			open_book(placer, itemstack)
		end
		return itemstack
	end,
	-- 對空中右鍵：翻開
	on_secondary_use = function(itemstack, user)
		if user and user:is_player() then open_book(user, itemstack) end
		return itemstack
	end,
})

---------------------------------------------------------------------------
-- 鑽孔（手持鑽機、岩芯鑽探車共用）
---------------------------------------------------------------------------

local drilling = {}         -- 玩家名稱 → {collar, x, y, z, rows, t, max, ok（還能繼續鑽嗎：回傳 nil 或停下的原因）}

-- 鑽孔進度條（畫面中間，比照鑿岩機）：已鑽深度 / 最深，加上目前這一公尺的進度
local function progress_hud(p, d)
	local depth = #d.rows + math.min(1, d.t / SEC_PER_M)
	local bars = math.floor(math.min(1, depth / d.max) * 10 + 0.5)
	local text = S("Core drilling @1 / @2 m @3", ("%.1f"):format(depth), tostring(d.max), ("■"):rep(bars) .. ("□"):rep(10 - bars))
	if d.hud then p:hud_change(d.hud, "text", text)
	else
		d.hud = p:hud_add({type = "text", position = {x = 0.5, y = 0.56}, alignment = {x = 0, y = 0},
			text = text, number = 0xFFFFFF, z_index = 50})
	end
end
local function finish(name, d, why)
	drilling[name] = nil
	local p = core.get_player_by_name(name)
	if p and d.hud then p:hud_remove(d.hud) end
	if d.on_done then d.on_done() end
	if #d.rows == 0 then
		rockmech.notify(name, why and S("[Core drilling] Nothing was drilled (@1)", why) or S("[Core drilling] Nothing was drilled"))
		return
	end
	local acc = rockmech.account_of and rockmech.account_of(name) or name
	local list = logs_of(acc)
	local n = #list + 1
	local bh = {n = n, pos = d.collar, depth = #d.rows, rows = d.rows, stop = why, by = name, dir = d.dir}
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
		msg = why and S("[Core drilling] @1 finished BH-@2, depth @3 m, @4: no room next to the collar, so the core box was not placed; clear a spot next to the collar", name, sn, sd, why)
			or S("[Core drilling] @1 finished BH-@2, depth @3 m: no room next to the collar, so the core box was not placed; clear a spot next to the collar", name, sn, sd)
	end
	if rockmech.account_members then
		for _, m in ipairs(rockmech.account_members(acc)) do
			rockmech.notify(m, msg)
		end
	end
end

-- 從 collar（孔口那一格，空的）沿 dir（省略 = 往下；手持鑽機也可以水平）鑽到 max m。
-- ok() 每一步檢查還能不能繼續（回傳停下的原因或 nil）
function rockmech.coredrill_start(name, collar, max, ok, on_done, dir)
	if drilling[name] then rockmech.notify(name, S("[Core drilling] Already drilling")); return false end
	dir = dir or {x = 0, y = -1, z = 0}
	drilling[name] = {collar = collar, dir = dir, x = collar.x + dir.x, y = collar.y + dir.y, z = collar.z + dir.z,
		rows = {}, t = 0, max = max, ok = ok, on_done = on_done}
	rockmech.notify(name, dir.y < 0 and S("[Core drilling] Drilling down (@1 s per metre, max @2 m)", tostring(SEC_PER_M), tostring(max))
		or S("[Core drilling] Drilling horizontally (@1 s per metre, max @2 m)", tostring(SEC_PER_M), tostring(max)))
	return true
end
function rockmech.coredrill_depth(name) local d = drilling[name]; return d and #d.rows, d and d.max end

local function start_hand(player, pointed)
	if pointed.type ~= "node" then return end
	-- 對著地面（方塊頂面）往下鑽；對著岩壁（側面）往牆裡水平鑽；頂板不行
	local nrm = vector.subtract(pointed.above, pointed.under)
	if nrm.y < 0 then
		rockmech.notify(player:get_player_name(), S("[Core drilling] Aim at the ground to drill down, or at a wall to drill horizontally"))
		return
	end
	local name = player:get_player_name()
	if drilling[name] then return end          -- 按住右鍵時 on_place 會一直重複觸發
	local c = pointed.above
	rockmech.coredrill_start(name, c, HAND_DEPTH, function()
		local p = core.get_player_by_name(name)
		local pp = p:get_pos()
		if math.sqrt((pp.x - c.x) ^ 2 + (pp.z - c.z) ^ 2) > STAY_R or p:get_wielded_item():get_name() ~= ITEM then return S("you walked away") end
		-- 要一直按住右鍵才會鑽（比照鑿岩機按住左鍵），放開就停在目前的深度
		local ctrl = p:get_player_control()
		if not (ctrl.place or ctrl.RMB) then return S("you let go") end
	end, nil, vector.multiply(nrm, -1))
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
				d.t = d.t + dtime * rockmech.eff_dig_mult(name)
				-- 孔口冒岩粉
				local m = vector.add(d.collar, vector.multiply(d.dir, 0.5))         -- 孔口（岩面上）
				core.add_particlespawner({amount = 3, time = 0.1, minpos = {x = m.x - 0.1, y = m.y, z = m.z - 0.1},
					maxpos = {x = m.x + 0.1, y = m.y + 0.1, z = m.z + 0.1}, minvel = {x = -0.6, y = 0.8, z = -0.6},
					maxvel = {x = 0.6, y = 1.6, z = 0.6}, minacc = {x = 0, y = -5, z = 0}, maxacc = {x = 0, y = -5, z = 0},
					minexptime = 0.4, maxexptime = 0.8, minsize = 0.6, maxsize = 1.2, texture = "[fill:4x4:#a89c90"})
				d.hud_t = (d.hud_t or 0) + dtime
				if d.hud_t >= 0.2 or not d.hud then d.hud_t = 0; progress_hud(p, d) end
				while d.t >= SEC_PER_M and drilling[name] do
					d.t = d.t - SEC_PER_M
					local cell = vector.add({x = d.x, y = d.y, z = d.z}, vector.multiply(d.dir, #d.rows))
					local node = core.get_node(cell)
					local lith = rockmech.lith_of_node[node.name]
					local row
					if core.get_item_group(node.name, "rockmech_topsoil") > 0
							or (rockmech.is_rubble(node.name) and rockmech.rubble_base[node.name] == rockmech.RUBBLE_SOIL) then
						row = {lith = "soil", node = node.name}         -- 表土、鬆土：鑽得過去，岩芯裡是一段土
					elseif lith then
						row = {lith = lith.name, grade = lith.ore and node.param2 or nil, node = rockmech.node_of_lith[lith.name]}
					elseif rockmech.is_rubble(node.name) then
						local base = rockmech.rubble_base[node.name]
						row = {lith = "rubble", grade = rockmech.ore_of_rubble[base] and node.param2 or nil, node = node.name}
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
	description = S("Hand-held core drill\nHold right-click on the ground to drill down"),
	short_description = S("Hand-held core drill"),
	inventory_image = "[fill:16x16:#00000000^[fill:4x10:6,1:#d0a020^[fill:2x5:7,11:#808488^[fill:8x3:4,3:#303030^[fill:2x1:7,15:#c0c0c0",
	stack_max = 1,
	on_place = function(itemstack, placer, pointed) if placer then start_hand(placer, pointed) end return itemstack end,
})
