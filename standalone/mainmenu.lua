-- 單機版的開始畫面：打包時（make_package.ps1）放到 builtin/mainmenu/init.lua，取代 Luanti 的主選單。
-- 只有一個世界（WORLD）：「繼續遊戲」進去、「新遊戲」刪掉重建（照上課世界的地形與煤層，rockmech.conf 用 standalone/rockmech.conf）。
-- 玩家名稱固定 PLAYER；權限由遊戲自己管（世界設定 rockmech_solo = true：沒有老師功能、沒有 /god）。
-- 遊戲裡 Esc →「回主選單」也會回到這裡。

local GAME = "mining_sim"
local WORLD = "solo"
local PLAYER = "player"
local F = core.formspec_escape
local DS = DIR_DELIM

gamedata = gamedata or {}

-- 上課世界（class_coal）的地形設定：平地、沒有洞穴和礦物，地形由遊戲自己造
local MAPGEN = {
	fixed_map_seed = "42", mg_name = "flat",
	mg_flags = "nocaves, nodungeons, light, nodecorations, nobiomes, noores",
	mgflat_spflags = "nolakes, nohills, nocaverns",
	mgflat_ground_level = "0", water_level = "-31000", mapgen_limit = "800", chunksize = "5",
}

local state = {page = "main", msg = nil, confirm = false}

local function game_info()
	for _, g in ipairs(core.get_games()) do
		if g.id == GAME then return g end
	end
end

local function find_world()
	for i, w in ipairs(core.get_worlds()) do
		if w.name == WORLD and w.gameid == GAME then return i, w end
	end
end

local function read_file(path)
	local f = io.open(path, "rb")
	if not f then return nil end
	local s = f:read("*a")
	f:close()
	return s
end

local function new_world()
	local i = find_world()
	if i then core.delete_world(i) end
	local err = core.create_world(WORLD, GAME, MAPGEN)
	if err then return err end
	local _, w = find_world()
	local g = game_info()
	if not (w and g) then return "建立世界失敗" end
	local conf = read_file(g.path .. DS .. "standalone" .. DS .. "rockmech.conf")
	if not conf then return "找不到 standalone/rockmech.conf" end
	local f = io.open(w.path .. DS .. "rockmech.conf", "wb")
	if not f then return "寫不進世界資料夾" end
	f:write(conf)
	f:close()
	return nil
end

local function start()
	local i = find_world()
	if not i then state.msg = "還沒有存檔，請按「新遊戲」"; return end
	core.settings:set("creative_mode", "false")
	core.settings:set("enable_damage", "true")
	core.settings:set("enable_server", "false")
	gamedata.playername = PLAYER
	gamedata.password = ""
	gamedata.address = ""
	gamedata.port = core.settings:get("port") or "30000"
	gamedata.selected_world = i
	gamedata.singleplayer = true
	core.start()
end

local function vol() return math.floor((tonumber(core.settings:get("sound_volume")) or 0.8) * 100 + 0.5) end

local function formspec()
	local g = game_info()
	local title = g and g.title or "Mining Mechanics"
	local fs = {"formspec_version[6]size[12,9]bgcolor[#00000000;true]",
		"box[0,0;12,9;#000000a0]",
		("hypertext[0.5,0.5;11,1.4;title;<center><style size=40><b>%s</b></style></center>]"):format(F(title)),
		("label[0.5,2.2;%s]"):format(F("岩石力學 × 採礦經營：開挖、支撐、爆破、運輸，看應力與節理決定穩不穩")),
	}
	if gamedata.errormessage then
		state.msg = gamedata.errormessage
		gamedata.errormessage = nil
	end
	if state.page == "main" then
		local has = find_world() ~= nil
		if has then fs[#fs + 1] = "button[3,3;6,1;continue;" .. F("繼續遊戲") .. "]" end
		fs[#fs + 1] = ("button[3,%g;6,1;new;%s]"):format(has and 4.2 or 3, F(state.confirm and "確定：刪掉舊存檔、重新開始" or "新遊戲"))
		fs[#fs + 1] = ("button[3,%g;6,1;settings;%s]"):format(has and 5.4 or 4.2, F("設定"))
		fs[#fs + 1] = ("button[3,%g;6,1;quit;%s]"):format(has and 6.6 or 5.4, F("離開"))
		if state.confirm then
			fs[#fs + 1] = "label[3,7.9;" .. F("新遊戲會刪掉現在的存檔，再按一次確定") .. "]"
		end
	else
		fs[#fs + 1] = "label[1,3.2;" .. F(("音量 %d%%"):format(vol())) .. "]"
		fs[#fs + 1] = "scrollbaroptions[min=0;max=100;smallstep=5;largestep=10]"
		fs[#fs + 1] = ("scrollbar[3,2.95;7,0.5;horizontal;vol;%d]"):format(vol())
		fs[#fs + 1] = ("checkbox[1,4.2;fullscreen;%s;%s]"):format(F("全螢幕（重開後生效）"),
			tostring(core.settings:get_bool("fullscreen") or false))
		fs[#fs + 1] = "label[1,5.2;" .. F("按鍵設定：進遊戲後按 Esc →「設定」") .. "]"
		fs[#fs + 1] = "button[3,6.6;6,1;back;" .. F("返回") .. "]"
	end
	if state.msg then
		fs[#fs + 1] = ("textarea[0.5,7.9;11,1;;;%s]"):format(F(state.msg))
	end
	return table.concat(fs)
end

local function refresh() core.update_formspec(formspec()) end

core.button_handler = function(fields)
	if fields.continue then
		state.confirm = false
		start()
	elseif fields.new then
		if find_world() and not state.confirm then
			state.confirm = true
		else
			state.confirm = false
			local err = new_world()
			if err then state.msg = err else start() end
		end
	elseif fields.settings then
		state.page, state.confirm = "settings", false
	elseif fields.back then
		state.page = "main"
	elseif fields.vol then
		local e = core.explode_scrollbar_event(fields.vol)
		if e.type == "CHG" then core.settings:set("sound_volume", tostring(e.value / 100)) end
	elseif fields.fullscreen then
		core.settings:set("fullscreen", fields.fullscreen)
	elseif fields.quit then
		core.close()
		return true
	end
	refresh()
	return true
end

core.event_handler = function(event)
	if event == "MenuQuit" then core.close() end
end

-- 畫面：背景用遊戲的 menu/background.png，不要雲
core.set_clouds(false)
core.set_topleft_text("")
local g = game_info()
if g then
	local bg = g.path .. DS .. "menu" .. DS .. "background.png"
	if io.open(bg, "rb") then core.set_background("background", bg, true, 256) end
end
refresh()

-- 測試用：設定 standalone_autotest = new → 開起來就按「新遊戲」進去（make_package 的檢查用，玩家不會設）
if core.settings:get("standalone_autotest") == "new" and not gamedata.autotested then
	gamedata.autotested = true
	local err = new_world()
	if err then core.log("error", "[standalone] " .. err) else start() end
end
