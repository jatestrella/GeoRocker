-- rockmech/powerplant.lua
-- 坑口電廠的存煤（rockmech_power_plant = true 的地圖）：測試階段，只累加、不燒煤、不限電。
--   賣出的煤（收煤站的煤噸 crusher.lua、火車的煤噸 trainline.lua）都進電廠存煤。
--   每個交易日（rockmech.market_day）的進煤噸數記在 mod storage，世界資料夾的 powerplant.csv 每筆進煤一行（調參數用）。
--   右上角資金下面一行「電廠存煤 N t」；/powerstats 顯示每日進煤和日平均。
-- 之後（另議）：存煤每天燒掉固定噸數、存煤不足時用電設施降速（供電率）。

local cfg = rockmech.cfg
local S = rockmech.S
if not cfg.power_plant then return end

local storage = core.get_mod_storage()
local STOCK, DAY = "pp_stock", "pp_day:"

function rockmech.power_stock() return storage:get_float(STOCK) end

function rockmech.power_text()
	return S("Power plant coal @1 t", ("%.0f"):format(storage:get_float(STOCK)))
end

local function log_line(day, t, src)
	local f = io.open(core.get_worldpath() .. "/powerplant.csv", "a")
	if not f then return end
	if f:seek("end") == 0 then f:write("gametime,day,tons,stock,source\n") end
	f:write(("%d,%d,%.2f,%.2f,%s\n"):format(core.get_gametime(), day, t, storage:get_float(STOCK), src))
	f:close()
end

-- t 噸的煤送到電廠（src：crusher / train）
function rockmech.power_add(t, src)
	if not t or t <= 0 then return end
	local day = rockmech.market_day()
	storage:set_float(STOCK, storage:get_float(STOCK) + t)
	storage:set_float(DAY .. day, storage:get_float(DAY .. day) + t)
	log_line(day, t, src or "")
	for _, p in ipairs(core.get_connected_players()) do
		if rockmech.show_money then rockmech.show_money(p) end
	end
end

core.register_chatcommand("powerstats", {
	description = S("Power plant coal: tons received each day and the daily average"),
	func = function()
		local today = rockmech.market_day()
		local lines, sum, first = {}, 0, nil
		for d = 0, today do
			local t = storage:get_float(DAY .. d)
			if t > 0 and not first then first = d end
			sum = sum + t
			if first then lines[#lines + 1] = ("  %d: %.0f t"):format(d, t) end
		end
		-- 經過的天數用遊戲時間算（含今天沒過完的部分）
		local days = math.max(1e-6, core.get_gametime() / cfg.price_period)
		local since = first and math.max(1e-6, days - first) or nil
		lines[#lines + 1] = S("Stock @1 t, @2 days: average @3 t/day (since first delivery @4 t/day)",
			("%.0f"):format(storage:get_float(STOCK)), ("%.1f"):format(days),
			("%.0f"):format(sum / days), ("%.0f"):format(since and sum / since or 0))
		return true, table.concat(lines, "\n")
	end,
})
