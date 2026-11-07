-- 開始畫面：先是標題畫面（背景插圖、標題、開始遊戲／加入連線／操作說明／設定／離開），點進去才是各頁。
-- 進了世界就直接玩，遊戲裡不再跳標題畫面（mm_title 只剩圖）。打包時（make_package.ps1）放到 builtin/mainmenu/init.lua，取代 Luanti 的主選單（沒有公開伺服器清單）。
--   選地圖：standalone/maps/<id>/ 一張地圖一個資料夾：map.conf（title、description、mode = solo|class、order）、
--     rockmech.conf（世界設定，建新遊戲時複製進世界資料夾）、其他檔案（例如 students.csv）也一起複製。
--     每張地圖一個世界（worlds/map_<id>）：「繼續遊戲」進去、「新遊戲」刪掉重建。
--     solo：單機（世界設定 rockmech_solo = true，沒有老師功能）。
--     class：在這台電腦開伺服器，開的人（名稱）是管理員＝老師；學生用「加入連線」連進來。
--   加入連線：輸入位址、埠、帳號、密碼，連到別人開的伺服器（課堂）。
--   設定：音量、全螢幕。
-- 遊戲裡 Esc →「回主選單」也會回到這裡。

local GAME = "mining_sim"
local F = core.formspec_escape
local DS = DIR_DELIM

gamedata = gamedata or {}

-- 上課世界（class_coal）的地形：平地、沒有洞穴和礦物，地形由遊戲自己造
local MAPGEN = {
	fixed_map_seed = "42", mg_name = "flat",
	mg_flags = "nocaves, nodungeons, light, nodecorations, nobiomes, noores",
	mgflat_spflags = "nolakes, nohills, nocaverns",
	mgflat_ground_level = "0", water_level = "-31000", mapgen_limit = "800", chunksize = "5",
}

local state = {page = "title", map = nil, msg = nil, confirm = false}

local function game_info()
	for _, g in ipairs(core.get_games()) do
		if g.id == GAME then return g end
	end
end

local function list_dir(path, dirs)
	local ok, t = pcall(core.get_dir_list, path, dirs)
	return ok and t or {}
end

-- 地圖清單（照 order 排）
local function maps()
	local g = game_info()
	if not g then return {} end
	local base = g.path .. DS .. "standalone" .. DS .. "maps"
	local out = {}
	for _, id in ipairs(list_dir(base, true)) do
		local dir = base .. DS .. id
		local s = Settings(dir .. DS .. "map.conf")
		out[#out + 1] = {id = id, dir = dir, title = s:get("title") or id, description = s:get("description") or "",
			mode = s:get("mode") or "solo", order = tonumber(s:get("order") or "") or 99}
	end
	table.sort(out, function(a, b) return a.order < b.order end)
	return out
end

local function world_name(m) return "map_" .. m.id end
local function find_world(m)
	for i, w in ipairs(core.get_worlds()) do
		if w.name == world_name(m) and w.gameid == GAME then return i, w end
	end
end

local function copy_file(src, dst)
	local f = io.open(src, "rb")
	if not f then return false end
	local s = f:read("*a")
	f:close()
	local o = io.open(dst, "wb")
	if not o then return false end
	o:write(s)
	o:close()
	return true
end

local function new_world(m)
	local i = find_world(m)
	if i then core.delete_world(i) end
	local err = core.create_world(world_name(m), GAME, MAPGEN)
	if err then return err end
	local _, w = find_world(m)
	if not w then return "建立世界失敗" end
	-- 地圖資料夾裡除了 map.conf 都複製進世界（rockmech.conf、students.csv…）
	for _, f in ipairs(list_dir(m.dir, false)) do
		if f ~= "map.conf" and not copy_file(m.dir .. DS .. f, w.path .. DS .. f) then return "複製 " .. f .. " 失敗" end
	end
	return nil
end

local function start_world(m, fields)
	local i = find_world(m)
	if not i then state.msg = "這張地圖還沒有存檔，請按「新遊戲」"; return end
	core.settings:set("creative_mode", "false")
	core.settings:set("enable_damage", "true")
	gamedata.selected_world = i
	gamedata.address = ""
	if m.mode == "class" then
		-- 開伺服器：名稱就是管理員（老師）
		local name = (fields and fields.host_name or core.settings:get("name") or ""):match("^%s*(.-)%s*$")
		if not name:match("^[%w_%-]+$") or #name > 20 then state.msg = "名稱只能用英文字母、數字、- 和 _（最多 20 字）"; return end
		local port = tonumber(fields and fields.host_port or core.settings:get("port") or "30000")
		if not port or port < 1 or port > 65535 then state.msg = "埠要是 1–65535 的數字"; return end
		core.settings:set("name", name)
		core.settings:set("port", tostring(port))
		core.settings:set("enable_server", "true")
		core.settings:set("server_announce", "false")
		gamedata.playername = name
		gamedata.password = fields and fields.host_pass or ""
		gamedata.port = tostring(port)
		gamedata.singleplayer = false
	else
		core.settings:set("enable_server", "false")
		gamedata.playername = "singleplayer"
		gamedata.password = ""
		gamedata.port = core.settings:get("port") or "30000"
		gamedata.singleplayer = true
	end
	core.start()
end

-- 記住密碼：明碼存在這台電腦的 minetest.conf（standalone_pass_<位址>_<帳號>），勾選框 standalone_remember
local function pass_key(addr, name) return (("standalone_pass_%s_%s"):format(addr, name):gsub("[^%w_]", "_")) end
local function remember() return core.settings:get("standalone_remember") ~= "false" end

local function join(fields)
	local addr = (fields.j_addr or ""):match("^%s*(.-)%s*$")
	local port = tonumber(fields.j_port or "")
	local name = (fields.j_name or ""):match("^%s*(.-)%s*$")
	if addr == "" then state.msg = "請輸入老師給的位址（IP）"; return end
	if not port then state.msg = "埠要是數字（老師沒說就用 30000）"; return end
	if name == "" then state.msg = "請輸入帳號"; return end
	core.settings:set("address", addr)
	core.settings:set("remote_port", tostring(port))
	core.settings:set("name", name)
	gamedata.address = addr
	gamedata.port = tostring(port)
	gamedata.playername = name
	local key = pass_key(addr, name)
	local pass = fields.j_pass or ""
	if pass == "" then pass = core.settings:get(key) or "" end
	if remember() and pass ~= "" then core.settings:set(key, pass)
	elseif not remember() then core.settings:remove(key) end
	gamedata.password = pass
	gamedata.selected_world = 0
	gamedata.singleplayer = false
	core.start()
end

local function vol() return math.floor((tonumber(core.settings:get("sound_volume")) or 0.8) * 100 + 0.5) end

local function header(fs)
	local g = game_info()
	fs[#fs + 1] = ("hypertext[0.5,0.4;13,1.3;title;<center><style size=40><b>%s</b></style></center>]"):format(F(g and g.title or GAME))
end

-- 標題畫面的圖（mods/mm_title/textures，menu/make_menu_art.ps1 產生）
local function art(file)
	local g = game_info()
	return g and F(g.path .. DS .. "mods" .. DS .. "mm_title" .. DS .. "textures" .. DS .. file) or ""
end
local TW, TH = 19.2, 10.8
local BUTTONS = "style_type[button;font=bold;font_size=*1.4;textcolor=#f4e6c8;bgcolor=#2a2016;border=false]"
	.. "style_type[button:hovered;bgcolor=#6a4a18;textcolor=#ffffff]"
local function title_frame()
	return {("formspec_version[6]size[%g,%g]padding[0,0]no_prepend[]bgcolor[#000000;both;#000000]"):format(TW, TH),
		("image[0,0;%g,%g;%s]"):format(TW, TH, art("mm_title_bg.png"))}
end

local HELP = table.concat({
	"<global margin=12 color=#f4e6c8 size=17>",
	"<big><b><style color=#ffcf60>操作說明</style></b></big>\n\n",
	"<b><style color=#ffcf60>基本</style></b>\n",
	"WASD 移動　空白鍵 跳　Shift 蹲下　I 物品欄　右鍵帳篷下的供應商買東西（車輛停到營地的交車區，設施給施工單）\n",
	"挖碎石就是把它拿起來（一次一塊，不進物品欄），右鍵放下或裝進車斗；拿著「回營地」旗子按左鍵回營地\n\n",
	"<b><style color=#ffcf60>地質與岩石力學</style></b>\n",
	"<b>地質羅盤</b>：右鍵一格岩石，顯示岩性、深度、應力、節理與破壞判定\n",
	"岩面出現<b>裂紋</b>代表快撐不住（安全係數 1～1.5）；安全係數 ≤ 1 就崩落。用岩柱、岩栓、噴凝土撐住，或縮小開挖跨度\n",
	"<b>岩芯鑽探</b>：鑽完岩芯箱放在孔口旁邊，拿野帳本對它右鍵判讀\n\n",
	"<b><style color=#ffcf60>鑽孔爆破</style></b>\n",
	"<b>鑿岩機</b>：對岩面按住左鍵鑽孔　<b>乳膠炸藥</b>：對鑽孔按右鍵裝藥（一孔最多 4 條）\n",
	"<b>打火石</b>：點一個裝藥孔，4 秒後爆　<b>起爆器</b>：右鍵，30 m 內的裝藥倒數 5 秒後依序起爆\n",
	"旁邊有<b>自由面</b>（空間、碎石、沒裝藥的空孔）威力較大：先鑽空孔或先炸中間的孔（拔心），外圈再炸\n\n",
	"<b><style color=#ffcf60>車輛</style></b>\n",
	"右鍵上車　Shift 下車　W／S 前進後退　A／D 轉向　Z 切換追蹤相機\n",
	"各車的作業鍵（E、空白鍵…）顯示在儀表板的按鈕上，開著的功能按鈕會亮\n",
})

local function formspec()
	if gamedata.errormessage then
		state.msg = gamedata.errormessage
		gamedata.errormessage = nil
	end
	if state.page == "title" then
		local fs = title_frame()
		fs[#fs + 1] = ("image[3.6,0.9;12,2.49;%s]"):format(art("mm_title_logo.png"))
		fs[#fs + 1] = BUTTONS
		local y = 4.3
		for _, b in ipairs({{"play", "開始遊戲"}, {"join_page", "加入連線"}, {"help", "操作說明"}, {"settings", "設定"}, {"quit", "離開"}}) do
			fs[#fs + 1] = ("button[7.1,%g;5,0.95;%s;%s]"):format(y, b[1], F(b[2]))
			y = y + 1.15
		end
		if state.msg then
			fs[#fs + 1] = ("box[0.4,%g;%g,1.2;#000000c0]textarea[0.6,%g;%g,1.1;;;%s]"):format(TH - 1.5, TW - 0.8, TH - 1.45, TW - 1.2, F(state.msg))
		end
		return table.concat(fs)
	elseif state.page == "help" then
		local fs = title_frame()
		fs[#fs + 1] = ("box[1.2,0.6;%g,%g;#0c0a08d8]"):format(TW - 2.4, TH - 2.2)
		fs[#fs + 1] = ("hypertext[1.6,0.9;%g,%g;help;%s]"):format(TW - 3.2, TH - 2.8, F(HELP))
		fs[#fs + 1] = BUTTONS
		fs[#fs + 1] = ("button[7.1,%g;5,0.9;back;%s]"):format(TH - 1.35, F("返回"))
		return table.concat(fs)
	end
	local fs = {"formspec_version[6]size[14,10.5]bgcolor[#00000000;true]", "box[0,0;14,10.5;#000000b0]"}
	header(fs)
	local list = maps()
	if state.page == "main" then
		fs[#fs + 1] = "label[0.5,2.1;" .. F("選地圖") .. "]"
		local y = 2.4
		for i, m in ipairs(list) do
			local has = find_world(m) ~= nil
			fs[#fs + 1] = ("button[0.5,%g;6,0.9;map_%d;%s]"):format(y, i, F(m.title))
			fs[#fs + 1] = ("textarea[6.8,%g;6.7,1.1;;;%s]"):format(y - 0.05, F(m.description .. (has and "　（有存檔）" or "")))
			y = y + 1.25
		end
		y = math.max(y + 0.2, 5.4)
		fs[#fs + 1] = ("button[4.9,%g;4.2,0.9;back;%s]"):format(y, F("返回"))
	elseif state.page == "map" and list[state.map] then
		local m = list[state.map]
		local has = find_world(m) ~= nil
		fs[#fs + 1] = ("label[0.5,2.1;%s]"):format(F(m.title))
		fs[#fs + 1] = ("textarea[0.5,2.4;13,1.2;;;%s]"):format(F(m.description))
		local y = 3.8
		if m.mode == "class" then
			fs[#fs + 1] = ("field[0.5,%g;4.2,0.8;host_name;%s;%s]"):format(y + 0.4, F("你的名稱（老師帳號）"), F(core.settings:get("name") or ""))
			fs[#fs + 1] = ("pwdfield[4.9,%g;4.2,0.8;host_pass;%s]"):format(y + 0.4, F("密碼（可以空白）"))
			fs[#fs + 1] = ("field[9.3,%g;4.2,0.8;host_port;%s;%s]"):format(y + 0.4, F("埠（學生連線用）"), F(core.settings:get("port") or "30000"))
			y = y + 1.6
		end
		if has then fs[#fs + 1] = ("button[0.5,%g;6.4,0.9;continue;%s]"):format(y, F(m.mode == "class" and "繼續上課（開伺服器）" or "繼續遊戲")) end
		fs[#fs + 1] = ("button[%g,%g;6.4,0.9;new;%s]"):format(has and 7.1 or 0.5, y,
			F(state.confirm and "確定：刪掉舊存檔、重新開始" or (m.mode == "class" and "新課堂（開伺服器）" or "新遊戲")))
		y = y + 1.2
		if state.confirm then
			fs[#fs + 1] = ("label[0.5,%g;%s]"):format(y, F("新遊戲會刪掉這張地圖現在的存檔，再按一次確定"))
			y = y + 0.6
		end
		if has and m.mode == "class" then
			fs[#fs + 1] = ("button[0.5,%g;6.4,0.9;open_dir;%s]"):format(y, F("打開地圖資料夾（編輯學生名單）"))
			y = y + 1.2
		end
		fs[#fs + 1] = ("button[0.5,%g;6.4,0.9;back_maps;%s]"):format(y, F("返回"))
	elseif state.page == "join" then
		fs[#fs + 1] = "label[0.5,2.1;" .. F("加入連線：輸入老師給的位址和你的帳號密碼") .. "]"
		fs[#fs + 1] = ("field[0.5,3.0;8.5,0.8;j_addr;%s;%s]"):format(F("位址（IP）"), F(core.settings:get("address") or ""))
		fs[#fs + 1] = ("field[9.3,3.0;4.2,0.8;j_port;%s;%s]"):format(F("埠"), F(core.settings:get("remote_port") or "30000"))
		fs[#fs + 1] = ("field[0.5,4.4;6.4,0.8;j_name;%s;%s]"):format(F("帳號"), F(core.settings:get("name") or ""))
		local saved = core.settings:get(pass_key(core.settings:get("address") or "", core.settings:get("name") or ""))
		fs[#fs + 1] = ("pwdfield[7.1,4.4;6.4,0.8;j_pass;%s]"):format(F(saved and saved ~= "" and "密碼（已記住：空白就用記住的）" or "密碼"))
		fs[#fs + 1] = ("checkbox[0.5,5.5;remember;%s;%s]"):format(F("記住密碼（明碼存在這台電腦，公用電腦不要勾）"), tostring(remember()))
		fs[#fs + 1] = "button[0.5,6.2;6.4,0.9;connect;" .. F("連線") .. "]"
		fs[#fs + 1] = "button[7.1,6.2;6.4,0.9;back;" .. F("返回") .. "]"
	else
		state.page = "settings"
		fs[#fs + 1] = "label[1,2.4;" .. F(("音量 %d%%"):format(vol())) .. "]"
		fs[#fs + 1] = "scrollbaroptions[min=0;max=100;smallstep=5;largestep=10]"
		fs[#fs + 1] = ("scrollbar[3,2.15;9,0.5;horizontal;vol;%d]"):format(vol())
		fs[#fs + 1] = ("checkbox[1,3.4;fullscreen;%s;%s]"):format(F("全螢幕（重開後生效）"),
			tostring(core.settings:get_bool("fullscreen") or false))
		fs[#fs + 1] = "label[1,4.4;" .. F("按鍵設定：進遊戲後按 Esc →「設定」") .. "]"
		fs[#fs + 1] = "button[3.8,5.8;6.4,0.9;back;" .. F("返回") .. "]"
	end
	if state.msg then
		fs[#fs + 1] = ("textarea[0.5,8.9;13,1.4;;;%s]"):format(F(state.msg))
	end
	return table.concat(fs)
end

local function refresh() core.update_formspec(formspec()) end

core.button_handler = function(fields)
	local list = maps()
	local m = list[state.map or 0]
	if fields.quit then core.close(); return true end
	for k in pairs(fields) do
		local i = tonumber(k:match("^map_(%d+)$"))
		if i and list[i] then state.page, state.map, state.confirm, state.msg = "map", i, false, nil end
	end
	if fields.play then
		state.page, state.confirm, state.msg = "main", false, nil
	elseif fields.help then
		state.page, state.msg = "help", nil
	elseif fields.back_maps then
		state.page, state.confirm, state.msg = "main", false, nil
	elseif fields.back then
		state.page, state.confirm, state.msg = "title", false, nil
	elseif fields.join_page then
		state.page, state.msg = "join", nil
	elseif fields.settings then
		state.page, state.msg = "settings", nil
	elseif fields.connect or (fields.key_enter and state.page == "join") then
		join(fields)
	elseif fields.continue and m then
		state.confirm = false
		start_world(m, fields)
	elseif fields.new and m then
		if find_world(m) and not state.confirm then
			state.confirm = true
		else
			state.confirm = false
			local err = new_world(m)
			if err then state.msg = err else start_world(m, fields) end
		end
	elseif fields.open_dir and m then
		local _, w = find_world(m)
		if w then core.open_dir(w.path) end
	elseif fields.vol then
		local e = core.explode_scrollbar_event(fields.vol)
		if e.type == "CHG" then core.settings:set("sound_volume", tostring(e.value / 100)) end
	elseif fields.remember then
		core.settings:set("standalone_remember", fields.remember)
		if fields.remember == "false" then
			core.settings:remove(pass_key(core.settings:get("address") or "", core.settings:get("name") or ""))
		end
	elseif fields.fullscreen then
		core.settings:set("fullscreen", fields.fullscreen)
	end
	refresh()
	return true
end

core.event_handler = function(event)
	if event == "MenuQuit" then
		if state.page == "map" then state.page, state.confirm = "main", false; refresh()
		elseif state.page ~= "title" then state.page, state.confirm = "title", false; refresh()
		else core.close() end
	end
end

-- 畫面：背景用遊戲的 menu/background.png，不要雲
core.set_clouds(false)
core.set_topleft_text("")
do
	local g = game_info()
	if g then
		local bg = g.path .. DS .. "menu" .. DS .. "background.png"
		local f = io.open(bg, "rb")
		if f then f:close(); core.set_background("background", bg, true, 256) end
	end
end
refresh()

-- 測試用：設定 standalone_autotest = <地圖 id> → 開起來就對那張地圖按「新遊戲」（make_package 的檢查用，玩家不會設）
local auto = core.settings:get("standalone_autotest")
if auto and auto ~= "" and not gamedata.autotested then
	gamedata.autotested = true
	for _, m in ipairs(maps()) do
		if m.id == auto then
			local err = new_world(m)
			if err then core.log("error", "[standalone] " .. err)
			else start_world(m, {host_name = core.settings:get("name") or "teacher", host_pass = "", host_port = core.settings:get("port") or "30010"}) end
		end
	end
end
