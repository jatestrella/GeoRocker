-- rockmech/class/commands.lua（教學地圖才載入，init.lua）
-- 老師的聊天指令（原本在 orders.lua、market.lua）：/rockmech_order 全班同一張訂單、/rockmech_event 指定市場事件

local cfg = rockmech.cfg
local S = rockmech.S
local O = rockmech.orders
local function event_by_id(id)
	for _, e in ipairs(rockmech.market_events) do if e.id == id then return e end end
end
---------------------------------------------------------------------------
-- 老師：全班同一張訂單
---------------------------------------------------------------------------

if cfg.teacher then
	core.register_chatcommand("rockmech_order", {
		params = "<tons> <grade %> <days> [price/t]", privs = {rockmech = true},
		description = S("Give every team the same order (teams with an order already are skipped)"),
		func = function(_, param)
			local tons, spec, days, price = (param or ""):match("^%s*(%d+)%s+(%d+)%s+(%d+)%s*(%d*)%s*$")
			if not tons then return false, S("Usage: /rockmech_order <tons> <grade %> <days> [price/t]") end
			spec = tonumber(spec) / 100
			local ore = cfg.main_ore
			price = tonumber(price) or math.floor((rockmech.ore_price(ore) * spec - (ore.metal and ore.metal.tc or 0)) * 1.25 + 0.5)
			local n, skip = 0, 0
			for i = 0, cfg.career_teams or 0 do
				local acc = "team:" .. i
				if O.site_of(acc) then
					if O.get_order(acc) then skip = skip + 1
					else O.accept(acc, {tons = tonumber(tons), spec = spec, days = tonumber(days), price = price}); n = n + 1 end
				end
			end
			return true, S("Order sent to @1 teams (@2 skipped)", n, skip)
		end,
	})
end

-- 老師（教學地圖）可以指定事件：/rockmech_event 列出、/rockmech_event <代號> 觸發
if cfg.teacher then
	core.register_chatcommand("rockmech_event", {
		params = "[id]", privs = {rockmech = true},
		description = S("List market events, or start one"),
		func = function(_, param)
			param = (param or ""):match("^%s*(.-)%s*$")
			if param == "" then
				local ids = {}
				for _, e in ipairs(rockmech.market_events) do ids[#ids + 1] = e.id .. " " .. e.label end
				return true, table.concat(ids, "\n")
			end
			if not event_by_id(param) then return false, S("No such event: @1", param) end
			if not rockmech.market_start_event(param) then return false, S("That event is already happening") end
			for _, p in ipairs(core.get_connected_players()) do rockmech.show_money(p) end
			return true, "ok"
		end,
	})
end

