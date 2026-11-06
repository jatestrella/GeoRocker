-- rockmech/restart.lua
-- 每日定時重開（常駐伺服器用）：到了 rockmech_daily_restart（"HH:MM"，電腦的本地時間；空字串＝不重開）就正常關機
-- （core.request_shutdown 會先存檔），外面的 start_class_server.bat 迴圈接著備份世界、git pull、再啟動。
-- 前 5 分鐘、1 分鐘全服廣播；剛啟動 RECENT 秒內不觸發（不然 4:00 關機、4:01 重開會再關一次）。

local cfg = rockmech.cfg
local at = cfg.daily_restart
if not at then return end
local hh, mm = at:match("^(%d%d?):(%d%d)$")
if not hh then
	core.log("warning", "[rockmech] rockmech_daily_restart 要寫成 HH:MM（例如 04:00），現在是：" .. at)
	return
end
local target = tonumber(hh) * 60 + tonumber(mm)       -- 一天裡的第幾分鐘
local RECENT = 600          -- 啟動後這麼多秒內不重開 (s)
local WARN = {5, 1}         -- 前幾分鐘廣播

local said = {}
local t = 0
core.register_globalstep(function(dtime)
	t = t + dtime
	if t < 10 then return end
	t = 0
	if core.get_server_uptime() < RECENT then return end
	local now = os.date("*t")
	local left = (target - (now.hour * 60 + now.min)) % (24 * 60)    -- 還有幾分鐘
	for _, w in ipairs(WARN) do
		if left == w and not said[w] then
			said[w] = true
			core.chat_send_all(("[伺服器] %d 分鐘後重開維護（約 1 分鐘），請先把車停好、手上的碎石放下"):format(w))
		end
	end
	if left == 0 then
		core.log("action", "[rockmech] 每日定時重開：" .. at)
		core.request_shutdown("每日維護重開，約 1 分鐘後就能再連線", true, 5)
		t = -1e9            -- 不再觸發
	end
end)
