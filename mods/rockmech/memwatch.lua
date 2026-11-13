-- rockmech/memwatch.lua
-- 查伺服器當機用：每 rockmech_memwatch 秒（預設 300；0 = 關）在 debug.txt 記一行
--   Lua 記憶體 (MB)、玩家數、實體數（車輛、落石、NPC…），以及數量最多的 5 種實體。
-- 配合 standalone/mem_log.ps1（整個 luanti.exe 的記憶體）：
--   程序記憶體一直漲、Lua 也跟著漲 → mod 的資料在累積；Lua 平平 → 引擎（地圖區塊、網路）在漲；
--   某種實體一直變多 → 那種東西沒清掉。單機不記

if core.is_singleplayer() then return end
local every = tonumber(core.settings:get("rockmech_memwatch") or "") or 300
if every <= 0 then return end

local t = 0
core.register_globalstep(function(dtime)
	t = t + dtime
	if t < every then return end
	t = 0
	local count, total = {}, 0
	for _, ent in pairs(core.luaentities) do
		local n = ent.name or "?"
		count[n] = (count[n] or 0) + 1
		total = total + 1
	end
	local top = {}
	for n, c in pairs(count) do top[#top + 1] = {n, c} end
	table.sort(top, function(a, b) return a[2] > b[2] end)
	local parts = {}
	for i = 1, math.min(5, #top) do parts[i] = ("%s=%d"):format(top[i][1]:gsub("^rockmech:", ""), top[i][2]) end
	core.log("action", ("[rockmech] memwatch lua=%.0fMB players=%d entities=%d uptime=%.0fmin %s"):format(
		collectgarbage("count") / 1024, #core.get_connected_players(), total, core.get_server_uptime() / 60,
		table.concat(parts, " ")))
end)
