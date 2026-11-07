-- 外觀調整器（tools/ui_tuner）用：在無頭伺服器上產生幾個畫面的 formspec，翻成中文，寫到世界資料夾的 ui_screens.json
-- build.py 把這個檔案放進暫時世界的 worldmods，跑完自己關掉伺服器
local out = {screens = {}, colors = {}}
local function add(id, title, fs)
	out.screens[#out.screens + 1] = {id = id, title = title, fs = core.get_translated_string("zh_TW", fs)}
end

-- 客戶端是先把 formspec 的跳脫拿掉再翻譯；伺服器端整串翻譯時，跳脫過的逗號會讓原文對不上。
-- 所以這裡在跳脫之前先翻好
local orig_escape = core.formspec_escape
core.formspec_escape = function(s) return orig_escape(core.get_translated_string("zh_TW", s)) end

local st = rockmech.collapse.storage
local inv = core.create_detached_inventory("uidump_inv", {})
inv:set_size("main", 8)
local fake = setmetatable({
	get_player_name = function() return "uidump" end,
	is_player = function() return true end,
	get_pos = function() return {x = 3, y = 2, z = 3} end,
	get_inventory = function() return inv end,
	get_wielded_item = function() return inv:get_stack("main", 2) end,
	set_wielded_item = function(_, s) inv:set_stack("main", 2, s) end,
}, {__index = function() return function() end end})
local orig_get = core.get_player_by_name
core.get_player_by_name = function(n) if n == "uidump" then return fake end return orig_get(n) end
local captured
core.show_formspec = function(_, _, fs) captured = fs end
local function send(formname, fields)
	for _, f in ipairs(core.registered_on_player_receive_fields) do
		if f(fake, formname, fields) then return end
	end
end

local function run()
	rockmech.can_see = function() return true end
	local acc = rockmech.account_of and rockmech.account_of("uidump") or "uidump"
	-- 範例鑽孔：表土、碎石、頁岩、煤層、砂岩、花崗岩，共 32 m
	local L = rockmech.node_of_lith
	local rows = {
		{lith = "soil", node = "rockmech:topsoil", joints = 0},
		{lith = "rubble", node = rockmech.RUBBLE, joints = 0},
	}
	for i = 3, 8 do rows[i] = {lith = "shale", node = L.shale, joints = (i % 3 == 0) and 1 or 0} end
	for i = 9, 11 do rows[i] = {lith = "coal", node = L.coal, grade = 150 + i * 8, joints = 0} end
	for i = 12, 20 do rows[i] = {lith = "sandstone", node = L.sandstone, joints = (i % 4 == 0) and 1 or 0} end
	for i = 21, 32 do rows[i] = {lith = "granite", node = L.granite, joints = (i % 5 == 0) and 1 or 0} end
	st:set_string("bh:" .. acc, core.serialize({
		{n = 1, pos = {x = 12, y = 2, z = -30}, depth = #rows, rows = rows, name = "北側探孔"},
		{n = 2, pos = {x = 40, y = 2, z = -28}, depth = 8, rows = {unpack(rows, 1, 8)}},
	}))
	-- 野帳本：判讀過 BH-1，BH-2 只做過點荷重；施密特錘幾筆
	local book = ItemStack("rockmech:fieldbook")
	local m = book:get_meta()
	m:set_string("logs", core.serialize({{acc = acc, n = 1, rm = true, gr = true}}))
	m:set_string("plt", core.serialize({{acc = acc, n = 1, d = 9, is = 0.70}, {acc = acc, n = 1, d = 9, is = 0.66},
		{acc = acc, n = 1, d = 14, is = 2.70}, {acc = acc, n = 1, d = 25, is = 8.10}, {acc = acc, n = 2, d = 4, is = 1.30}}))
	local sch = {}
	for i = 1, 12 do sch[i] = {x = 20 + i, y = 3, z = -12, r = 26 + (i * 7) % 6, lith = "shale"} end
	m:set_string("schmidt", core.serialize(sch))
	inv:set_stack("main", 2, book)

	core.registered_items["rockmech:fieldbook"].on_use(book, fake, {type = "nothing"})
	add("book_toc", "野帳本：岩芯目錄", captured)
	send("rockmech:fieldbook", {h_1 = ""})
	add("book_hole", "野帳本：鑽孔柱狀圖", captured)
	send("rockmech:fieldbook", {tab_field = ""})
	add("book_field", "野帳本：野外調查", captured)
	send("rockmech:fieldbook", {quit = "true"})

	-- 岩芯箱：放在地上、旁邊一台點荷重試驗機
	local bp = {x = 2, y = 3, z = 2}
	core.set_node({x = 2, y = 2, z = 2}, {name = "default:stone"})
	core.set_node(bp, {name = "air"})
	rockmech.corebox_put(bp, {acc = acc, n = 1, depth = #rows})
	core.set_node({x = 4, y = 3, z = 2}, {name = "rockmech:point_load"})
	local nd = core.registered_nodes[core.get_node(bp).name]
	nd.on_rightclick(bp, core.get_node(bp), fake, ItemStack(""))
	add("corebox", "岩芯箱：打開", captured)
	send("rockmech:corebox_open", {seg_9 = ""})
	add("corebox_sel", "岩芯箱：選一段岩芯", captured)
	send("rockmech:corebox_open", {quit = "true"})

	for k, v in pairs(rockmech.ui_color_defaults or {}) do out.colors[k] = v end
	local f = io.open(core.get_worldpath() .. "/ui_screens.json", "w")
	f:write(core.write_json(out))
	f:close()
	core.log("action", "[uidump] " .. #out.screens .. " screens")
	core.request_shutdown()
end

core.after(1, function()
	core.emerge_area({x = -4, y = -4, z = -4}, {x = 8, y = 8, z = 8}, function(_, _, rem)
		if rem == 0 then core.after(0.5, run) end
	end)
end)
