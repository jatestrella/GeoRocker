-- rockmech/notify.lua
-- 遊戲訊息顯示在畫面左下角（聊天區在左上，是 client 自己畫的，伺服器移不動）：
--   rockmech.notify(玩家, 訊息)、rockmech.notify_all(訊息)。訊息可以是翻譯過的字串（S(...)）、可以有 core.colorize。
--   每則一行 HUD 文字，新的在最下面，最多 MAX 則；每則顯示 BASE 秒，字多的多留一點，到時間自己消失。
-- 玩家之間的聊天、指令的回覆、長的報告（地質羅盤的完整資料、老師的名單）照樣走聊天區。

local MAX = 6
local BASE, PER_CHAR, LONGEST = 6, 0.04, 16
local LINE_H = 22                       -- 一行的高度（像素）
local X, BOTTOM = 14, -96               -- 離左邊、離底部（像素）：在血條、物品欄左邊的空位
local shown = {}                        -- 玩家名稱 → {{id, text, t, lines}, …}，舊的在前

local function relayout(player, list)
	local y = BOTTOM
	for i = #list, 1, -1 do
		local m = list[i]
		player:hud_change(m.id, "offset", {x = X, y = y})
		y = y - LINE_H * m.lines
	end
end

local function remove(player, list, i)
	player:hud_remove(list[i].id)
	table.remove(list, i)
end

function rockmech.notify(name, text)
	if type(name) ~= "string" then name = name and name.get_player_name and name:get_player_name() end
	local player = name and core.get_player_by_name(name)
	if not player then return end
	text = tostring(text or "")
	local list = shown[name] or {}
	shown[name] = list
	while #list >= MAX do remove(player, list, 1) end
	local lines = 1
	for _ in text:gmatch("\n") do lines = lines + 1 end
	local id = player:hud_add({type = "text", position = {x = 0, y = 1}, alignment = {x = 1, y = -1},
		offset = {x = X, y = BOTTOM}, text = text, number = 0xFFFFFF, z_index = 120, style = 0})
	list[#list + 1] = {id = id, t = math.min(LONGEST, BASE + #text * PER_CHAR), lines = lines}
	relayout(player, list)
end

function rockmech.notify_all(text)
	for _, p in ipairs(core.get_connected_players()) do rockmech.notify(p:get_player_name(), text) end
end

local acc = 0
core.register_globalstep(function(dtime)
	acc = acc + dtime
	if acc < 0.5 then return end
	local dt = acc
	acc = 0
	for name, list in pairs(shown) do
		local player = core.get_player_by_name(name)
		if not player then shown[name] = nil
		else
			local changed = false
			for i = #list, 1, -1 do
				list[i].t = list[i].t - dt
				if list[i].t <= 0 then remove(player, list, i); changed = true end
			end
			if changed then relayout(player, list) end
		end
	end
end)
core.register_on_leaveplayer(function(player) shown[player:get_player_name()] = nil end)
