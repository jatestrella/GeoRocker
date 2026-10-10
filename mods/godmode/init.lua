-- godmode/init.lua
-- 開發測試用：/god 一次開啟無敵與飛行、快速、穿牆、給物品權限。
--   無敵：armor group immortal（跳過所有傷害與呼吸處理，也會隱藏血量列）
--   權限：只撤銷由 /god 授予的權限（原本就有的不動）
-- 狀態存在玩家 meta，重新登入後自動恢復。

local PRIVS = {"fly", "fast", "noclip", "give"}
local META_ON = "godmode:on"
local META_GRANTED = "godmode:granted"

local huds = {}

local function set_immortal(player, on)
	local groups = player:get_armor_groups()
	groups.immortal = on and 1 or nil
	player:set_armor_groups(groups)
	if on then
		player:set_hp(player:get_properties().hp_max)
		player:set_breath(player:get_properties().breath_max)
	end
end

local function show_hud(player, on)
	local name = player:get_player_name()
	if on and not huds[name] then
		huds[name] = player:hud_add({
			type = "text", position = {x = 0.98, y = 0.03}, alignment = {x = -1, y = 1},
			text = "GOD", number = 0xFFD040,
		})
	elseif not on and huds[name] then
		player:hud_remove(huds[name])
		huds[name] = nil
	end
end

local function enable(player)
	local name = player:get_player_name()
	local meta = player:get_meta()
	local have = core.get_player_privs(name)
	local granted, changes = {}, {}
	for _, p in ipairs(PRIVS) do
		if not have[p] then
			granted[#granted + 1] = p
			changes[p] = true
		end
	end
	core.change_player_privs(name, changes)
	-- 保留先前已授予的紀錄（重複 /god on 不會遺失）
	local prev = meta:get_string(META_GRANTED)
	if prev ~= "" then
		for p in prev:gmatch("[^,]+") do
			local dup = false
			for _, g in ipairs(granted) do if g == p then dup = true end end
			if not dup then granted[#granted + 1] = p end
		end
	end
	meta:set_string(META_GRANTED, table.concat(granted, ","))
	meta:set_int(META_ON, 1)
	set_immortal(player, true)
	show_hud(player, true)
end

local function disable(player)
	local name = player:get_player_name()
	local meta = player:get_meta()
	local changes = {}
	for p in meta:get_string(META_GRANTED):gmatch("[^,]+") do changes[p] = false end
	core.change_player_privs(name, changes)
	meta:set_string(META_GRANTED, "")
	meta:set_int(META_ON, 0)
	set_immortal(player, false)
	show_hud(player, false)
end

core.register_chatcommand("god", {
	params = "[on|off]",
	description = "開關無敵模式（無敵＋飛行、快速、穿牆、給物品權限）；不加參數則切換",
	privs = {privs = true},
	func = function(name, param)
		local player = core.get_player_by_name(name)
		if not player then return false, "找不到玩家" end
		local on = player:get_meta():get_int(META_ON) == 1
		if param == "on" then on = false elseif param == "off" then on = true
		elseif param ~= "" then return false, "用法：/god [on|off]" end
		if on then
			disable(player)
			return true, "無敵模式：關閉（只撤銷由 /god 授予的權限）"
		end
		enable(player)
		return true, "無敵模式：開啟。按 K 飛行、J 快速、H 穿牆（按鍵可在設定中修改）"
	end,
})

core.register_on_joinplayer(function(player)
	if player:get_meta():get_int(META_ON) == 1 then
		-- 登入時引擎會重設護甲群組，重新套用
		core.after(0, function()
			if player:is_player() then
				set_immortal(player, true)
				show_hud(player, true)
			end
		end)
	end
end)

core.register_on_leaveplayer(function(player)
	huds[player:get_player_name()] = nil
end)
