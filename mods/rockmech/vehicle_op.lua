-- rockmech/vehicle_op.lua
-- 重機操作員開露天鑽機、裝藥車（怪手的操作員在 vehicle_excavator.lua；雇用、休息、叫下車在 operator.lua）。
--   派上車：拿著「重機操作員」對沒人的車按右鍵。右鍵有操作員坐著的車 → 操作員頁面（叫下車、回基地休息）。
--   指揮：對講機／指揮無人機點車選定（vehicle_excavator.lua 的 rockmech.radio_click），然後
--     直接點地面：開過去（清掉排好的工作）；
--     按住 E 點：作業，排進工作清單（最多 MAX_JOBS 個），一個做完接下一個：
--       鑽機：開到桅桿腳對準點的那一格，照設定的孔深鑽一個垂直孔；
--       裝藥車：開到吊臂搆得到（車尾對著那一點），把吊臂範圍內往下的孔都灌好。
--   點正在工作的那台：停下、清掉工作清單。
-- 開法跟怪手的操作員一樣：原地轉向目標再直線開過去，卡住就倒車、轉一下再試，不會繞過大障礙。
-- 這裡只產生按鍵（self.autopilot，格式同 get_player_control），鑽孔、灌孔還是車子自己的 def.action／def.step。

local S = rockmech.S
local E = core.formspec_escape
local V = rockmech.vehicles
local OP_ITEM = "rockmech:operator"
local FORM = "rockmech:op_work"
local MAX_JOBS = 20
local STUCK_T, STUCK_TRIES = 4, 4
local atan2 = math.atan2

local function tell(name, msg) if name then rockmech.notify(name, S("[Radio] @1", msg)) end end
local function paid(self) return rockmech.cfg.career and self.owner and self.owner ~= "" and rockmech.wage_hire end
local function hyp(dx, dz) return math.sqrt(dx * dx + dz * dz) end
local function angle(a) return (a + math.pi) % (2 * math.pi) - math.pi end

local editing = {}          -- 玩家名稱 → 車

local function op_show(self)
	if not self.object:get_pos() then return end
	local op = self.op
	if op and op.on then
		local n = op.jobs and #op.jobs or 0
		V.nametag(self, S("Operator: @1", op.msg or (n > 0 and S("@1 jobs queued", tostring(n)) or S("Waiting for orders"))), "#ffe080")
	else
		V.nametag(self, "")
	end
	V.cab_figure(self)
end

local function say(self, msg)
	if self.op.msg ~= msg then self.op.msg = msg; op_show(self) end
end

-- 往 (tx, tz) 開：先原地轉向，對準了才往前。back = true：車尾對著目標倒車過去。
-- 想動卻 STUCK_T 秒沒進展就脫困（倒車、轉、往前），試 STUCK_TRIES 次還不行回傳 "stuck"
local function steer(self, ctx, tx, tz, back, tol)
	local op, pos = self.op, ctx.pos
	local esc = op.esc
	if esc then
		esc.t = esc.t - ctx.dtime
		if esc.t > 0 then return esc.steps[esc.i] end
		esc.i = esc.i + 1
		if esc.steps[esc.i] then esc.t = esc.times[esc.i]; return esc.steps[esc.i] end
		op.esc = nil
	end
	local dx, dz = tx - pos.x, tz - pos.z
	local head = atan2(-dx, dz)
	if back then head = head + math.pi end
	local diff = angle(head - ctx.yaw)
	local ap = {}
	tol = tol or 0.6
	if diff > 0.08 then ap.left = true elseif diff < -0.08 then ap.right = true end
	if math.abs(diff) < tol then if back then ap.down = true else ap.up = true end end
	local pr = op.prog
	if not pr then pr = {p = vector.copy(pos), yaw = ctx.yaw, t = 0}; op.prog = pr end
	pr.t = pr.t + ctx.dtime
	if vector.distance(pos, pr.p) > 0.8 or math.abs(angle(ctx.yaw - pr.yaw)) > 0.5 then
		op.prog = nil
	elseif pr.t > STUCK_T then
		op.prog = nil
		op.tries = (op.tries or 0) + 1
		if op.tries > STUCK_TRIES then return "stuck" end
		local side = op.tries % 2 == 1 and "left" or "right"
		local away, toward = back and {up = true} or {down = true}, back and {down = true} or {up = true}
		op.esc = {i = 1, t = 1.5, times = {1.5, 1.2, 2.5}, steps = {away, {[side] = true}, toward}}
		return op.esc.steps[1]
	end
	return ap
end

local function next_job(self)
	local op = self.op
	table.remove(op.jobs, 1)
	op.tries, op.esc, op.prog, op.issued = 0, nil, nil, nil
	if #op.jobs == 0 then op.msg = nil end
	op_show(self)
end

-- 每一步（包在車子的 def.step 前面）
local function operate(self, ctx, spec)
	local op = self.op
	if spec.busy(self) then self.autopilot = {}; return end
	local job = op.jobs and op.jobs[1]
	if not job then self.autopilot = {}; say(self, nil); return end
	-- 已經按了作業鍵：等車子做完（鑽完、灌完）再回報、接下一個
	if op.issued then
		op.issued = op.issued + ctx.dtime
		self.autopilot = {}
		if op.issued < 0.4 then return end
		tell(op.by, self.msg or S("Done"))
		self.msg = nil
		return next_job(self)
	end
	local pos = ctx.pos
	local ap, here
	if job.work then
		ap, here = spec.approach(self, ctx, job.p, steer)
	else
		local d = hyp(job.p.x - pos.x, job.p.z - pos.z)
		if d < math.max(1.5, spec.half) then here = true else ap = steer(self, ctx, job.p.x, job.p.z) end
	end
	if ap == "stuck" then
		self.autopilot = {}
		tell(op.by, S("Can't get there; skipping this one (@1 m short)", ("%d"):format(hyp(job.p.x - pos.x, job.p.z - pos.z) + 0.5)))
		return next_job(self)
	end
	if not here then
		self.autopilot = ap
		say(self, S("Heading to the target (@1 m to go)", ("%d"):format(hyp(job.p.x - pos.x, job.p.z - pos.z) + 0.5)))
		return
	end
	if not job.work then
		self.autopilot = {}
		tell(op.by, S("Arrived"))
		return next_job(self)
	end
	local why = spec.can_work and spec.can_work(self)
	if why then
		self.autopilot = {}
		tell(op.by, why)
		return next_job(self)
	end
	self.msg = nil
	self.autopilot = {aux1 = true}
	op.issued = 0
	say(self, spec.working)
end

local function form(self, spec)
	local op = self.op
	local out = {
		"formspec_version[6]size[11.5,5.2]",
		("label[0.5,0.6;%s]"):format(E(S("@1 operator", spec.label))),
		("label[0.5,1.2;%s]"):format(E(S("Status: @1", op.msg or (#op.jobs > 0 and S("@1 jobs queued", tostring(#op.jobs)) or S("Waiting for orders"))))),
		("label[0.5,1.8;%s]"):format(E(S("Radio: click the ground to drive there; hold E and click to @1", spec.verb))),
		("button[0.5,2.5;3.4,0.8;off;%s]"):format(E(S("Step down (so a player can drive)"))),
		("button[4.05,2.5;3.4,0.8;rest;%s]"):format(E(S("Rest at base"))),
	}
	if #op.jobs > 0 then out[#out + 1] = ("button[7.6,2.5;3.4,0.8;clear;%s]"):format(E(S("Clear the jobs"))) end
	if spec.form then out[#out + 1] = spec.form(self) end
	if paid(self) then
		out[#out + 1] = ("label[0.5,4.3;%s]"):format(E(S("Daily wage $@1 (one trading day = @2 min), deducted pro rata while team members are online",
			("%g"):format(rockmech.operator_wage(self.vkind)), tostring(math.floor(rockmech.cfg.price_period / 60 + 0.5)))))
	end
	return table.concat(out)
end

local specs = {}            -- 車種 → spec

core.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= FORM then return end
	local name = player:get_player_name()
	local self = editing[name]
	if not (self and self.object:get_pos() and self.op and self.op.on) then editing[name] = nil; return true end
	local spec = specs[self.vkind]
	if spec.fields then spec.fields(self, fields) end
	if fields.off then
		rockmech.op_step_down(self)
		rockmech.notify(name, S("[Operator] Stepped down and waiting beside the vehicle; right-click him to send him back to work or to rest at base"))
	elseif fields.rest then
		rockmech.op_send_rest(self, player)
	elseif fields.clear then
		self.op.jobs, self.op.issued = {}, nil
		self.autopilot = {}
		op_show(self)
	end
	if fields.quit or fields.off or fields.rest then
		editing[name] = nil
		if not fields.quit then core.close_formspec(name, FORM) end
	else
		core.show_formspec(name, FORM, form(self, spec))
	end
	return true
end)

-- 對講機下的指令（vehicle_excavator.lua 的 rockmech.radio_click）：work = 按住 E
function V.op_order(self, name, pointed, work)
	local op = self.op
	if not (op and op.on) then tell(name, S("That vehicle has no operator")); return end
	local spec = specs[self.vkind]
	op.by = name
	op.jobs = op.jobs or {}
	local g = work and pointed.under or pointed.above
	local p = {x = g.x, y = g.y, z = g.z}
	if work then
		if #op.jobs > 0 and not op.jobs[#op.jobs].work then op.jobs = {} end
		for _, j in ipairs(op.jobs) do
			if j.p.x == p.x and j.p.z == p.z then tell(name, S("Already on the list")); return end
		end
		if #op.jobs >= MAX_JOBS then tell(name, S("The list is full (@1 jobs)", tostring(MAX_JOBS))); return end
		op.jobs[#op.jobs + 1] = {p = p, work = true}
		tell(name, S("Copy, @1 at (@2, @3, @4); @5 jobs queued", spec.verb, ("%d"):format(p.x), ("%d"):format(p.y), ("%d"):format(p.z), tostring(#op.jobs)))
	else
		op.jobs, op.issued = {{p = p}}, nil
		tell(name, S("Copy, heading to (@1, @2, @3), @4 m", ("%d"):format(p.x), ("%d"):format(p.y), ("%d"):format(p.z),
			("%d"):format(vector.distance(self.object:get_pos(), p))))
	end
	if op.jobs[1] and #op.jobs == 1 then op.tries, op.esc, op.prog = 0, nil, nil end
	core.add_particlespawner({amount = 30, time = 2, pos = {min = vector.subtract(p, 0.3), max = vector.add(p, {x = 0.3, y = 2, z = 0.3})},
		vel = {x = 0, y = 1, z = 0}, exptime = 1, size = 3, texture = work and "[fill:4x4:#ffb030" or "[fill:4x4:#40a0ff", glow = 14, playername = name})
	op_show(self)
end
-- 點正在工作的那台：停下
function V.op_stop(self, name)
	local op = self.op
	if not (op and op.on and op.jobs and #op.jobs > 0) then return false end
	op.jobs, op.issued, op.esc, op.prog = {}, nil, nil, nil
	self.autopilot = {}
	op_show(self)
	tell(name, S("Stopped"))
	return true
end

-- 給車種加上操作員。spec：label（車名）、verb（作業的說法）、working（作業中的狀態）、half、
--   busy(self)（鑽孔中、灌孔中）、approach(self, ctx, p, steer) → 按鍵, 到了沒、can_work(self) → 不能作業的原因、
--   seat（坐姿人偶的位置，車身座標）、form(self)／fields(self, fields)（操作員頁面多的設定）
function V.op_setup(kind, def, spec)
	specs[kind] = spec
	def.op_work = true
	def.op_show = op_show
	def.figure_pos = def.figure_pos or function() return spec.seat end
	def.figure_skin = function(self)
		if self.op and self.op.on then return rockmech.npc_skin and rockmech.npc_skin("operator") or "character.png" end
	end
	local load, save, step = def.on_load, def.on_save, def.step
	function def.on_load(self, data)
		if load then load(self, data) end
		self.op = data.op
		if self.op then self.op.jobs = self.op.jobs or {}; self.op.issued = nil end
		if self.op and (self.op.on or self.op.standby) and not self.op.counted then
			self.op.counted = true
			if rockmech.op_adopt then rockmech.op_adopt(data.owner) end
		end
		if self.op and self.op.on then core.after(0.5, function() if self.object:get_pos() then op_show(self) end end) end
	end
	function def.on_save(self, data)
		if save then save(self, data) end
		data.op = self.op
	end
	function def.step(self, ctx)
		local op = self.op
		if op and op.on and not ctx.d then operate(self, ctx, spec) end
		if op and op.standby and rockmech.op_standby_step then rockmech.op_standby_step(self) end
		if step then step(self, ctx) end
	end
	local rclick = def.rightclick
	function def.rightclick(self, clicker)
		local name = clicker:get_player_name()
		local op = self.op
		if op and op.on then
			editing[name] = self
			core.show_formspec(name, FORM, form(self, spec))
			return true
		end
		if clicker:get_wielded_item():get_name() ~= OP_ITEM then return rclick and rclick(self, clicker) or false end
		if op and op.standby then
			rockmech.notify(name, S("[Operator] This vehicle's operator is waiting beside it: right-click him to send him in"))
			return true
		end
		local stack = clicker:get_wielded_item()
		if not rockmech.op_card_ok(stack, clicker, self) then return true end
		self.op = {on = true, t = 0, counted = true, jobs = {}}
		if paid(self) then rockmech.wage_hire(self.uid, self.owner, self.vkind) end
		if not core.is_creative_enabled(name) then
			stack:take_item()
			clicker:set_wielded_item(stack)
		end
		op_show(self)
		rockmech.notify(name, paid(self) and S("[Operator] Getting in to work, daily wage $@1 (paid while team members are online)", ("%g"):format(rockmech.operator_wage(self.vkind)))
			or S("[Operator] Getting in to work"))
		editing[name] = self
		core.show_formspec(name, FORM, form(self, spec))
		return true
	end
end
