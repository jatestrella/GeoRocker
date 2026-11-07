-- rockmech/wages.lua
-- 雇員薪水（目前只有怪手操作員）：雇用時記在 mod storage 的 hire:<車輛編號> = 帳戶，解雇就刪掉。
-- 每 TICK 秒：帳戶有組員在線上，每個雇員扣 薪水 × TICK ÷ 交易日長度（日薪 cfg.operator_wage，交易日 cfg.price_period 秒），
-- 記在 wage:<帳戶>:<交易日>。沒人在線不計薪（跟研究一樣）。
-- 結算：破碎站的日結表多一行「人事費」（crusher.lua 呼叫 rockmech.wage_take）；那天破碎站沒處理到東西、沒出日結表，
-- 換日後 BILL_GRACE 秒由這裡另外發一張人事費的單子。

local cfg = rockmech.cfg
local storage = core.get_mod_storage()
local HIRE, WAGE = "hire:", "wage:"
local TICK, BILL_GRACE = 5, 5

local function wage_rate() return cfg.operator_wage or 3000 end
rockmech.operator_wage = wage_rate

function rockmech.wage_hire(uid, acc)
	if not uid or not acc or acc == "" then return end
	storage:set_string(HIRE .. uid, acc)
	core.log("action", ("[rockmech] %s 雇用怪手操作員（車輛 %s）"):format(acc, tostring(uid)))
end
function rockmech.wage_fire(uid)
	if not uid or storage:get_string(HIRE .. uid) == "" then return end
	core.log("action", ("[rockmech] %s 解雇怪手操作員（車輛 %s）"):format(storage:get_string(HIRE .. uid), tostring(uid)))
	storage:set_string(HIRE .. uid, "")
end
function rockmech.wage_hired(uid) return uid and storage:get_string(HIRE .. uid) ~= "" end

local function bucket_key(acc, day) return WAGE .. acc .. ":" .. day end
local function get_bucket(acc, day)
	return core.deserialize(storage:get_string(bucket_key(acc, day))) or {amt = 0, sec = 0}
end

-- 破碎站日結拿走某帳戶某交易日的人事費：回傳 金額, 人·秒（沒有就 nil）
function rockmech.wage_take(acc, day)
	local k = bucket_key(acc, day)
	local b = core.deserialize(storage:get_string(k))
	if not b then return nil end
	storage:set_string(k, "")
	return b.amt, b.sec
end

-- 人事費那一行：{項目, 數量, 單價, 金額}
function rockmech.wage_row(amt, sec)
	return {"人事費（怪手操作員）", ("%.1f 人·日"):format(sec / cfg.price_period), ("$%g／日"):format(wage_rate()), -amt}
end

local acc_t = 0
core.register_globalstep(function(dtime)
	acc_t = acc_t + dtime
	if acc_t < TICK then return end
	local dt = acc_t
	acc_t = 0
	local day = rockmech.market_day and rockmech.market_day() or 0
	local V = rockmech.vehicles
	local per = {}          -- 帳戶 → 雇員數
	for _, k in ipairs(storage:get_keys()) do
		local uid = k:match("^" .. HIRE .. "(.+)$")
		if uid then
			local acc = storage:get_string(k)
			-- 怪手在載入中、操作員卻不在了（不在車上也沒站在旁邊等）：當作解雇
			local e = V and V.by_uid and (V.by_uid[uid] or V.by_uid[tonumber(uid) or -1])
			if e and e.object:get_pos() and not (e.op and (e.op.on or e.op.standby)) then
				storage:set_string(k, "")
			elseif acc ~= "" then
				per[acc] = (per[acc] or 0) + 1
			end
		end
	end
	for acc, n in pairs(per) do
		if #rockmech.account_members(acc) > 0 then
			local amt = wage_rate() * dt / cfg.price_period * n
			rockmech.add_money(acc, -amt)
			local b = get_bucket(acc, day)
			b.amt, b.sec = b.amt + amt, b.sec + dt * n
			storage:set_string(bucket_key(acc, day), core.serialize(b))
		end
	end
	-- 前幾天沒被破碎站日結拿走的人事費、燃料費（fuel.lua）：另外發一張營運費單子
	-- （換日後等 BILL_GRACE 秒，讓破碎站先結）
	local into = core.get_gametime() - day * cfg.price_period
	if into >= BILL_GRACE then
		local due = {}          -- "帳戶|交易日" → {acc, d}
		for _, k in ipairs(storage:get_keys()) do
			local acc, d = k:match("^" .. WAGE .. "(.+):(%d+)$")
			d = tonumber(d)
			if acc and d and d < day then due[acc .. "|" .. d] = {acc, d} end
		end
		for _, ad in ipairs(rockmech.fuel_days and rockmech.fuel_days(day) or {}) do due[ad[1] .. "|" .. ad[2]] = ad end
		for _, ad in pairs(due) do
			local acc, d = ad[1], ad[2]
			local rows, total = {}, 0
			local amt, sec = rockmech.wage_take(acc, d)
			if amt and amt > 0 then
				local r = rockmech.wage_row(amt, sec)
				rows[#rows + 1] = {r[1], r[2], r[3], rockmech.money_text(r[4]), 0xFF8080}
				total = total + amt
			end
			local famt, fl = (rockmech.fuel_take or function() end)(acc, d)
			if famt and famt > 0 then
				local r = rockmech.fuel_row(famt, fl)
				rows[#rows + 1] = {r[1], r[2], r[3], rockmech.money_text(r[4]), 0xFF8080}
				total = total + famt
			end
			if #rows > 0 then
				for _, m in ipairs(rockmech.account_members(acc)) do
					core.chat_send_player(m, ("[營運費] 第 %d 個交易日 −$%.0f"):format(d + 1, total))
					if rockmech.show_bill then
						rockmech.show_bill(m, ("營運費日結　第 %d 個交易日"):format(d + 1), rows)
					end
				end
			end
		end
	end
end)
