-- rockmech/fuel.lua
-- 燃料費：車子引擎發動時吃柴油，油錢直接從那台車所屬的帳戶扣（不用油箱、不用加油）。
--   引擎發動 = 有人在駕駛座、無人駕駛在跑、或怪手上有操作員（vehicles.lua 有 driver 或 autopilot）。
--   車上沒人、停著沒開：引擎熄火，不耗油。
-- 耗油 = 比油耗 BSFC × 額定功率 × 負載率 × 時間：
--   行駛阻力：拉車要的功率 P = 總重 × g ×（滾動阻力 RR × 水平速度 + 爬升速度），負載率 = P ÷ 額定功率；
--   下坡、停著等（怠速）最少 IDLE；挖、鑽、倒車斗這些作業中（不是在跑）最少 WORK；最多 1。
--   額定功率 rockmech.config.engine_kw（沒列的車不耗油），柴油價 cfg.diesel_price（$/L）。
-- 結算：每 TICK 秒扣一次錢，記在 fuel:<帳戶>:<交易日> = {amt, L}；破碎站日結表多一行「燃料費」
-- （crusher.lua 呼叫 rockmech.fuel_take），沒被破碎站結到的由 wages.lua 換日後另外發單子。

local cfg = rockmech.cfg
local S = rockmech.S
local V = rockmech.vehicles
local storage = core.get_mod_storage()
local FUEL = "fuel:"
local BSFC = 0.22          -- 柴油引擎比油耗（L/kWh）
local RR = 0.03            -- 滾動阻力係數（礦場運輸道路）
local G = 9.81
local IDLE, WORK = 0.1, 0.6
local TICK = 5

local function kw_of(kind) return rockmech.config.engine_kw[kind] end
rockmech.engine_kw = kw_of

-- 這一刻的耗油率（L/h）；working：作業中（不是在跑）
local function rate(self, kind, working)
	local kw = kw_of(kind)
	if not kw then return 0 end
	local vel = self.object:get_velocity() or {x = 0, y = 0, z = 0}
	local vh = math.sqrt(vel.x * vel.x + vel.z * vel.z)
	local m = V.gross_mass(self, kind)                       -- t → P 單位 kW
	local lf = m * G * (RR * vh + vel.y) / kw
	if vh < 0.1 and working then lf = math.max(lf, WORK) end
	lf = math.max(IDLE, math.min(1, lf))
	return BSFC * kw * lf
end

local pending = {}          -- 帳戶 → 還沒扣錢的公升數

-- vehicles.lua 每步呼叫（引擎發動中才會呼叫）
function rockmech.fuel_step(self, kind, working, dtime)
	local lh = rate(self, kind, working)
	if lh <= 0 then return end
	local l = lh * dtime / 3600
	-- 廢氣（airq.lua）：從車頂附近冒出來
	if rockmech.airq_diesel then
		local p = self.object:get_pos()
		local def = V.TYPES[kind]
		if p then rockmech.airq_diesel({x = p.x, y = p.y + (def and (def.top or def.half) or 1), z = p.z}, l) end
	end
	local day = rockmech.market_day and rockmech.market_day() or 0
	if self.fuel_day ~= day then self.fuel_day, self.fuel_l = day, 0 end
	self.fuel_l = (self.fuel_l or 0) + l
	local acc = self.owner
	if cfg.career and acc and acc ~= "" then pending[acc] = (pending[acc] or 0) + l end
	-- HUD：耗油率每 5 L/h 、本日油耗每 1 L 更新一次
	local shown = math.floor(lh / 5 + 0.5) * 5
	local today = math.floor(self.fuel_l)
	if shown ~= self.fuel_lh or today ~= self.fuel_shown then
		self.fuel_lh, self.fuel_shown = shown, today
		if self.driver then V.update_hud(self) end
	end
end

-- 駕駛 HUD 的一段字
function rockmech.fuel_hud(self)
	if not kw_of(self.vkind) then return "" end
	return "  " .. S("Fuel @1 L/h (today @2 L)", ("%d"):format(self.fuel_lh or 0), ("%d"):format(math.floor(self.fuel_l or 0)))
end

local function bucket_key(acc, day) return FUEL .. acc .. ":" .. day end

-- 破碎站日結拿走某帳戶某交易日的燃料費：回傳 金額, 公升（沒有就 nil）
function rockmech.fuel_take(acc, day)
	local k = bucket_key(acc, day)
	local b = core.deserialize(storage:get_string(k))
	if not b then return nil end
	storage:set_string(k, "")
	return b.amt, b.l
end

-- 燃料費那一行：{項目, 數量, 單價, 金額}
function rockmech.fuel_row(amt, l)
	return {S("Fuel (diesel)"), ("%.0f L"):format(l), S("$@1/L", ("%g"):format(cfg.diesel_price)), -amt}
end

-- 還沒結的燃料費：{帳戶 → {交易日, ...}}（wages.lua 發單子用）
function rockmech.fuel_days(before)
	local out = {}
	for _, k in ipairs(storage:get_keys()) do
		local acc, d = k:match("^" .. FUEL .. "(.+):(%d+)$")
		d = tonumber(d)
		if acc and d and d < before then out[#out + 1] = {acc, d} end
	end
	return out
end

local function flush()
	local day = rockmech.market_day and rockmech.market_day() or 0
	for acc, l in pairs(pending) do
		local amt = l * cfg.diesel_price
		if amt > 0 then
			rockmech.add_money(acc, -amt)
			local k = bucket_key(acc, day)
			local b = core.deserialize(storage:get_string(k)) or {amt = 0, l = 0}
			b.amt, b.l = b.amt + amt, b.l + l
			storage:set_string(k, core.serialize(b))
		end
	end
	pending = {}
end

local acc_t = 0
core.register_globalstep(function(dtime)
	acc_t = acc_t + dtime
	if acc_t < TICK then return end
	acc_t = 0
	flush()
end)
core.register_on_shutdown(flush)
