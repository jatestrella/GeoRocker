-- 開始畫面：先是標題畫面（背景插圖、標題、開始遊戲／加入連線／操作說明／設定／離開），點進去才是各頁。
-- 進了世界就直接玩，遊戲裡不再跳標題畫面（mm_title 只剩圖）。打包時（make_package.ps1）放到 builtin/mainmenu/init.lua，取代 Luanti 的主選單（沒有公開伺服器清單）。
--   開始遊戲：左邊開新遊戲（隨機地圖、自範本建立地圖、自訂地圖），右邊既有存檔（繼續、刪除）；存檔可以有很多個、自己取名。
--     地圖範本：standalone/maps/<id>/ 一個資料夾：map.conf（title、description、mode = solo|class、order）、
--     rockmech.conf（世界設定，建新遊戲時複製進世界資料夾）、其他檔案（例如 students.csv）也一起複製。
--     世界資料夾 worlds/gr_<日期時間>，名稱和來源記在裡面的 georocker.conf。
--     solo：單機（世界設定 rockmech_solo = true，沒有老師功能）。
--     random = true：每次新遊戲用新的種子，rockmech.conf 只放 rockmech_solo，地質由地圖產生器擲（mods/rockmech/worldgen.lua）。
--     custom = true：地圖頁多一組地質選項（地層、地形、0–100 的滑桿、種子），寫成 rockmech_gen_* 給地圖產生器。
--     class：在這台電腦開伺服器，開的人（名稱）是管理員＝老師；學生用「加入連線」連進來。
--   加入連線：輸入位址、埠、帳號、密碼，連到別人開的伺服器（課堂）。
--   設定：音量、全螢幕。
-- 遊戲裡 Esc →「回主選單」也會回到這裡。

local GAME = "mining_sim"
local F = core.formspec_escape
local DS = DIR_DELIM

gamedata = gamedata or {}

-- 點陣字型（俐方體11號 Cubic 11，OFL，games/mining_sim/fonts）：整個遊戲的文字都用它。
-- 每次開都檢查一次（絕對路徑：資料夾搬了也跟著改），舊的安裝 git pull 之後也會換上；字型設定改了引擎會馬上重載
do
	local FONT = core.get_builtin_path() .. ".." .. DS .. "games" .. DS .. GAME .. DS .. "fonts" .. DS .. "Cubic_11.ttf"
	-- georocker_font：設定版本（改字級時加 1，舊的設定也會跟著換）
	if core.settings:get("font_path") ~= FONT or core.settings:get("georocker_font") ~= "2" then
		for _, k in ipairs({"font_path", "font_path_bold", "font_path_italic", "font_path_bold_italic",
				"mono_font_path", "mono_font_path_bold", "mono_font_path_italic", "mono_font_path_bold_italic"}) do
			core.settings:set(k, FONT)
		end
		core.settings:set("font_size", "16")       -- 跟原本的字一樣大：22 會撐破 Luanti 內建選單的按鈕
		core.settings:set("mono_font_size", "16")
		core.settings:set("font_shadow", "0")
		core.settings:set("georocker_font", "2")
	end
end
-- 語言：沒設的話用繁中（系統是英文的電腦，遊戲裡的字才不會變英文）。語言要重開遊戲才生效
if (core.settings:get("language") or "") == "" then core.settings:set("language", "zh_TW") end

-- 上課世界（class_coal）的地形：平地、沒有洞穴和礦物，地形由遊戲自己造
local MAPGEN = {
	fixed_map_seed = "42", mg_name = "flat",
	mg_flags = "nocaves, nodungeons, light, nodecorations, nobiomes, noores",
	mgflat_spflags = "nolakes, nohills, nocaverns",
	mgflat_ground_level = "0", water_level = "-31000", mapgen_limit = "800", chunksize = "5",
}

local state = {page = "title", map = nil, msg = nil, confirm = false}

-- 自訂地圖的地質選項（mods/rockmech/worldgen.lua 的 rockmech_gen_*）。滑桿 0–100，旁邊顯示換算的實際值
-- 礦種（隨機地圖也可以選）：煤礦，或大理岩（花蓮大南澳片岩：大理岩夾在黑色片岩裡，傾角比較陡）
local GEN_ORE = {{"coal", "煤礦"}, {"marble", "大理岩"}}
local gen = {ore = 1, strata = 2, terrain = 1, relief = 50, seams = 50, outcrop = 40, dip = 40, thickvar = 30, fold = 30, seed = ""}
local function marble() return GEN_ORE[gen.ore][1] == "marble" end
local GEN_STRATA = {{"single", "單一煤層", "單一大理岩層"}, {"inter", "砂頁岩煤互層", "片岩大理岩互層"}}
local GEN_TERRAIN = {{"hills", "丘陵"}, {"cuesta", "單面山"}}
local GEN_SLIDERS = {
	{"relief", "地形起伏", function(v) return ("%d m"):format(math.floor(40 * v / 100 + 0.5)) end},
	{"seams", "礦層數（互層）", function(v) return ("%d 層"):format(1 + math.floor(4 * v / 100 + 0.5)) end},
	{"outcrop", "主礦層露頭距離", function(v) return ("營地外 %d m"):format(math.floor(20 + 35 * v / 100 + 0.5)) end},
	{"dip", "地層傾角", function(v)
		if marble() then return ("%d°"):format(math.floor(20 + 50 * v / 100 + 0.5)) end
		return ("%d°"):format(math.max(3, math.floor(40 * v / 100 + 0.5))) end},
	{"thickvar", "厚度變化", function(v) return ("±%d%%"):format(math.floor(60 * v / 100 + 0.5)) end},
	{"fold", "褶皺", function(v) return ("振幅 %d m"):format(math.floor(25 * v / 100 + 0.5)) end},
}
local function gen_randomize()
	math.randomseed(os.time())
	gen.strata, gen.terrain = math.random(1, 2), math.random(1, 2)
	for _, sl in ipairs(GEN_SLIDERS) do gen[sl[1]] = math.random(0, 100) end
end

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
			mode = s:get("mode") or "solo", order = tonumber(s:get("order") or "") or 99, random = s:get("random") == "true",
			custom = s:get("custom") == "true"}
	end
	table.sort(out, function(a, b) return a.order < b.order end)
	return out
end

-- 存檔：本遊戲的世界。世界資料夾的 georocker.conf 記它的名稱（title，資料夾名是英數字）、
-- 從哪張地圖來（map）、mode（solo|class）、kind（隨機地圖、自訂地圖、範本名稱）。
-- 舊版一張地圖一個世界（map_<id>）也列出來
local function map_by_id(id)
	for _, m in ipairs(maps()) do if m.id == id then return m end end
end
local function saves()
	local out = {}
	for i, w in ipairs(core.get_worlds()) do
		if w.gameid == GAME then
			local c = Settings(w.path .. DS .. "georocker.conf")
			local sv = {index = i, folder = w.name, path = w.path, title = c:get("title"), mode = c:get("mode"), kind = c:get("kind") or ""}
			if not sv.mode then
				local m = map_by_id(w.name:match("^map_(.+)$") or "")
				sv.mode, sv.kind = m and m.mode or "solo", m and m.title or ""
			end
			sv.title = sv.title or w.name
			out[#out + 1] = sv
		end
	end
	table.sort(out, function(a, b) return a.title:lower() < b.title:lower() end)
	return out
end
local function title_used(t)
	for _, sv in ipairs(saves()) do if sv.title == t then return true end end
	return false
end
local function unique_title(base)
	local t, k = base, 1
	while title_used(t) do k = k + 1; t = base .. " " .. k end
	return t
end
local function world_index(folder)
	for i, w in ipairs(core.get_worlds()) do if w.name == folder and w.gameid == GAME then return i, w end end
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

-- 從地圖 m 建立一個新存檔，名稱 title（空白就自動取 kind 加編號）。回傳 存檔 或 nil, 錯誤訊息
local function create_save(m, title, kind)
	title = (title or ""):match("^%s*(.-)%s*$")
	if title == "" then title = unique_title(kind) end
	if title_used(title) then return nil, "已經有叫「" .. title .. "」的存檔，換個名字" end
	-- 隨機地圖、自訂地圖：每次新的（或指定的）種子，地圖產生器（worldgen.lua）依種子擲地質
	local mg = MAPGEN
	if m.random or m.custom then
		mg = {}
		for k, v in pairs(MAPGEN) do mg[k] = v end
		math.randomseed(os.time())
		local sd = m.custom and gen.seed:match("^%s*(.-)%s*$") or ""
		mg.fixed_map_seed = sd ~= "" and sd or tostring(math.random(1, 2000000000))
	end
	local folder = "gr_" .. os.date("%Y%m%d_%H%M%S")
	while world_index(folder) do folder = folder .. "x" end
	local err = core.create_world(folder, GAME, mg)
	if err then return nil, err end
	local _, w = world_index(folder)
	if not w then return nil, "建立世界失敗" end
	-- 地圖資料夾裡除了 map.conf 都複製進世界（rockmech.conf、students.csv…）
	for _, f in ipairs(list_dir(m.dir, false)) do
		if f ~= "map.conf" and not copy_file(m.dir .. DS .. f, w.path .. DS .. f) then return nil, "複製 " .. f .. " 失敗" end
	end
	if m.random then
		local c = Settings(w.path .. DS .. "rockmech.conf")
		c:set("rockmech_gen_ore", GEN_ORE[gen.ore][1])
		if not c:write() then return nil, "寫入地質選項失敗" end
	end
	if m.custom then
		local c = Settings(w.path .. DS .. "rockmech.conf")
		c:set("rockmech_gen_ore", GEN_ORE[gen.ore][1])
		c:set("rockmech_gen_strata", GEN_STRATA[gen.strata][1])
		c:set("rockmech_gen_terrain", GEN_TERRAIN[gen.terrain][1])
		for _, sl in ipairs(GEN_SLIDERS) do c:set("rockmech_gen_" .. sl[1], tostring(gen[sl[1]])) end
		if not c:write() then return nil, "寫入地質選項失敗" end
	end
	local c = Settings(w.path .. DS .. "georocker.conf")
	c:set("title", title)
	c:set("map", m.id)
	c:set("mode", m.mode)
	c:set("kind", kind)
	c:write()
	for _, sv in ipairs(saves()) do if sv.folder == folder then return sv end end
	return nil, "建立世界失敗"
end

local function start_world(sv, fields)
	if not sv then state.msg = "請先選一個存檔"; return end
	core.settings:set("creative_mode", "false")
	core.settings:set("enable_damage", "true")
	gamedata.selected_world = sv.index
	gamedata.address = ""
	if sv.mode == "class" then
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
local function host_fields(fs, y)
	fs[#fs + 1] = ("field[0.5,%g;4.2,0.8;host_name;%s;%s]"):format(y + 0.4, F("你的名稱（老師帳號）"), F(core.settings:get("name") or ""))
	fs[#fs + 1] = ("pwdfield[4.9,%g;4.2,0.8;host_pass;%s]"):format(y + 0.4, F("密碼（可以空白）"))
	fs[#fs + 1] = ("field[9.3,%g;4.2,0.8;host_port;%s;%s]"):format(y + 0.4, F("埠（學生連線用）"), F(core.settings:get("port") or "30000"))
	return y + 1.6
end
local function random_map() for _, m in ipairs(maps()) do if m.random then return m end end end
local function custom_map() for _, m in ipairs(maps()) do if m.custom then return m end end end
local function templates()
	local out = {}
	for _, m in ipairs(maps()) do if not (m.random or m.custom) then out[#out + 1] = m end end
	return out
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
	local cm = state.page == "new_custom"
	local PH = cm and 15 or 10.5
	local fs = {("formspec_version[6]size[14,%g]bgcolor[#00000000;true]"):format(PH), ("box[0,0;14,%g;#000000b0]"):format(PH)}
	header(fs)
	if state.page == "main" then
		-- 左邊：開新遊戲的三種方式；右邊：既有存檔
		fs[#fs + 1] = "label[0.5,2.1;" .. F("開新遊戲") .. "]"
		fs[#fs + 1] = "button[0.5,2.5;5,0.9;go_random;" .. F("隨機地圖") .. "]"
		fs[#fs + 1] = "button[0.5,3.6;5,0.9;go_template;" .. F("自範本建立地圖") .. "]"
		fs[#fs + 1] = "button[0.5,4.7;5,0.9;go_custom;" .. F("自訂地圖") .. "]"
		fs[#fs + 1] = "button[0.5,6.4;5,0.9;back;" .. F("返回") .. "]"
		local list = saves()
		fs[#fs + 1] = "label[6.2,2.1;" .. F("既有存檔") .. "]"
		local items = {}
		for _, sv in ipairs(list) do items[#items + 1] = F(("%s　（%s）"):format(sv.title, sv.kind)) end
		if #items == 0 then items[1] = F("（還沒有存檔）") end
		local sel = state.sel and list[state.sel] and state.sel or 0
		fs[#fs + 1] = ("textlist[6.2,2.5;7.3,%g;saves;%s;%d;false]"):format(list[sel] and list[sel].mode == "class" and 2.6 or 4.2, table.concat(items, ","), sel)
		local sv = list[sel]
		if sv then
			local y = 7.0
			if sv.mode == "class" then
				fs[#fs + 1] = ("field[6.2,5.6;3.6,0.8;host_name;%s;%s]"):format(F("你的名稱（老師）"), F(core.settings:get("name") or ""))
				fs[#fs + 1] = ("pwdfield[9.9,5.6;3.6,0.8;host_pass;%s]"):format(F("密碼（可以空白）"))
				fs[#fs + 1] = ("field[6.2,6.8;3.6,0.8;host_port;%s;%s]"):format(F("埠"), F(core.settings:get("port") or "30000"))
				fs[#fs + 1] = ("button[9.9,6.8;3.6,0.8;open_dir;%s]"):format(F("打開存檔資料夾"))
				y = 7.8
			end
			fs[#fs + 1] = ("button[6.2,%g;3.6,0.9;continue;%s]"):format(y, F(sv.mode == "class" and "開伺服器上課" or "繼續遊戲"))
			fs[#fs + 1] = ("button[9.9,%g;3.6,0.9;delete;%s]"):format(y, F(state.confirm and "確定刪除" or "刪除"))
			if state.confirm then
				fs[#fs + 1] = ("label[6.2,%g;%s]"):format(y + 1.2, F("「" .. sv.title .. "」會永久刪掉，再按一次確定"))
			end
		end
	elseif state.page == "new_random" or state.page == "new_template" or state.page == "new_custom" then
		local m
		if state.page == "new_random" then m = random_map()
		elseif state.page == "new_custom" then m = custom_map()
		else m = templates()[state.tpl or 0] end
		local y
		if state.page == "new_template" and not m then
			-- 範本清單
			fs[#fs + 1] = "label[0.5,2.1;" .. F("自範本建立地圖：選一個範本") .. "]"
			y = 2.4
			for i, t in ipairs(templates()) do
				fs[#fs + 1] = ("button[0.5,%g;5,0.9;tpl_%d;%s]"):format(y, i, F(t.title))
				fs[#fs + 1] = ("textarea[5.8,%g;7.7,1.1;;;%s]"):format(y - 0.05, F(t.description))
				y = y + 1.25
			end
			fs[#fs + 1] = ("button[0.5,%g;5,0.9;back_main;%s]"):format(math.max(y + 0.2, 6.4), F("返回"))
		elseif m then
			fs[#fs + 1] = ("label[0.5,2.1;%s]"):format(F(state.page == "new_random" and "隨機地圖" or state.page == "new_custom" and "自訂地圖" or m.title))
			fs[#fs + 1] = ("textarea[0.5,2.4;13,1.2;;;%s]"):format(F(m.description))
			y = 3.8
			local function dd(x, name, label, opts, idx, col)
				local t = {}
				for _, o in ipairs(opts) do t[#t + 1] = F(o[col or 2]) end
				fs[#fs + 1] = ("label[%g,%g;%s]"):format(x, y, F(label))
				fs[#fs + 1] = ("dropdown[%g,%g;3.0,0.7;%s;%s;%d;true]"):format(x + 1.2, y - 0.35, name, table.concat(t, ","), idx)
			end
			if m.random or m.custom then
				dd(0.5, "g_ore", "礦種", GEN_ORE, gen.ore)
			end
			if m.random then y = y + 0.9 end
			if m.custom then
				-- 地質選項
				dd(5.0, "g_strata", "地層", GEN_STRATA, gen.strata, marble() and 3 or 2)
				dd(9.5, "g_terrain", "地形", GEN_TERRAIN, gen.terrain)
				y = y + 0.9
				fs[#fs + 1] = "scrollbaroptions[min=0;max=100;smallstep=1;largestep=10]"
				for _, sl in ipairs(GEN_SLIDERS) do
					fs[#fs + 1] = ("label[0.5,%g;%s]"):format(y, F(sl[2]))
					fs[#fs + 1] = ("scrollbar[3.4,%g;7.2,0.45;horizontal;g_%s;%d]"):format(y - 0.22, sl[1], gen[sl[1]])
					fs[#fs + 1] = ("label[10.9,%g;%s]"):format(y, F(("%d　%s"):format(gen[sl[1]], sl[3](gen[sl[1]]))))
					y = y + 0.7
				end
				fs[#fs + 1] = ("field[0.5,%g;6.4,0.8;g_seed;%s;%s]"):format(y + 0.4, F("種子（空白＝隨機；同一個種子同一套地質）"), F(gen.seed))
				fs[#fs + 1] = "field_close_on_enter[g_seed;false]"
				fs[#fs + 1] = ("button[7.1,%g;6.4,0.8;g_random;%s]"):format(y + 0.4, F("全部隨機"))
				y = y + 1.6
			end
			fs[#fs + 1] = ("field[0.5,%g;6.4,0.8;new_title;%s;%s]"):format(y + 0.4, F("存檔名稱（空白就自動取名）"), F(state.new_title or ""))
			fs[#fs + 1] = "field_close_on_enter[new_title;false]"
			y = y + 1.4
			if m.mode == "class" then y = host_fields(fs, y) end
			fs[#fs + 1] = ("button[0.5,%g;6.4,0.9;create;%s]"):format(y, F(m.mode == "class" and "建立並開伺服器" or "建立並開始"))
			fs[#fs + 1] = ("button[7.1,%g;6.4,0.9;%s;%s]"):format(y, state.page == "new_template" and "back_tpl" or "back_main", F("返回"))
		end
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
		fs[#fs + 1] = ("textarea[0.5,%g;13,1.4;;;%s]"):format(PH - 1.6, F(state.msg))
	end
	return table.concat(fs)
end

local function refresh() core.update_formspec(formspec()) end

core.button_handler = function(fields)
	if fields.quit then core.close(); return true end
	if fields.new_title then state.new_title = fields.new_title end
	-- 自訂煤礦的選項（每次送出都記下來，種子欄位也是）
	if fields.g_seed then gen.seed = fields.g_seed end
	if fields.g_ore then gen.ore = tonumber(fields.g_ore) or gen.ore end
	if fields.g_strata then gen.strata = tonumber(fields.g_strata) or gen.strata end
	if fields.g_terrain then gen.terrain = tonumber(fields.g_terrain) or gen.terrain end
	for _, sl in ipairs(GEN_SLIDERS) do
		local v = fields["g_" .. sl[1]]
		if v then
			local e = core.explode_scrollbar_event(v)
			if e.type == "CHG" then gen[sl[1]] = e.value end
		end
	end
	if fields.g_random then gen_randomize() end
	for k in pairs(fields) do
		local i = tonumber(k:match("^tpl_(%d+)$"))
		if i and templates()[i] then state.tpl, state.msg = i, nil end
	end
	if fields.saves then
		local e = core.explode_textlist_event(fields.saves)
		if e.type == "CHG" or e.type == "DCL" then
			state.sel, state.confirm, state.msg = e.index, false, nil
			local sv = saves()[e.index]
			if e.type == "DCL" and sv and sv.mode ~= "class" then start_world(sv, fields) end
		end
	end
	if fields.go_random then state.page, state.new_title, state.msg = "new_random", "", nil
	elseif fields.go_template then state.page, state.tpl, state.new_title, state.msg = "new_template", nil, "", nil
	elseif fields.go_custom then state.page, state.new_title, state.msg = "new_custom", "", nil
	elseif fields.back_main then state.page, state.msg = "main", nil
	elseif fields.back_tpl then state.tpl, state.msg = nil, nil
	elseif fields.create then
		local m = state.page == "new_random" and random_map() or state.page == "new_custom" and custom_map()
			or state.page == "new_template" and templates()[state.tpl or 0]
		if m then
			local kind = state.page == "new_random" and "隨機地圖" or state.page == "new_custom" and "自訂地圖" or m.title
			if (m.random or m.custom) and marble() then kind = "大理岩" .. kind end
			local sv, err = create_save(m, state.new_title, kind)
			if sv then
				state.page, state.sel, state.msg = "main", nil, nil
				for i, x in ipairs(saves()) do if x.folder == sv.folder then state.sel = i end end
				start_world(sv, fields)
			else state.msg = err end
		end
	elseif fields.delete then
		local sv = saves()[state.sel or 0]
		if sv then
			if not state.confirm then state.confirm = true
			else
				state.confirm = false
				core.delete_world(sv.index)
				state.sel, state.msg = nil, "已刪除「" .. sv.title .. "」"
			end
		end
	end
	if fields.play then
		state.page, state.confirm, state.msg, state.sel = "main", false, nil, nil
	elseif fields.help then
		state.page, state.msg = "help", nil
	elseif fields.back then
		state.page, state.confirm, state.msg = "title", false, nil
	elseif fields.join_page then
		state.page, state.msg = "join", nil
	elseif fields.settings then
		state.page, state.msg = "settings", nil
	elseif fields.connect or (fields.key_enter and state.page == "join") then
		join(fields)
	elseif fields.continue then
		state.confirm = false
		start_world(saves()[state.sel or 0], fields)
	elseif fields.open_dir then
		local sv = saves()[state.sel or 0]
		if sv then core.open_dir(sv.path) end
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
		if state.page:find("^new_") then state.page, state.confirm = "main", false; refresh()
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
			local sv, err = create_save(m, "autotest " .. m.id, m.title)
			if not sv then core.log("error", "[standalone] " .. err)
			else start_world(sv, {host_name = core.settings:get("name") or "teacher", host_pass = "", host_port = core.settings:get("port") or "30010"}) end
		end
	end
end
