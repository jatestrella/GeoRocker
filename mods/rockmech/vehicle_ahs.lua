-- rockmech/vehicle_ahs.lua
-- 無人運輸（AHS，像 Komatsu FrontRunner／Cat MineStar Command）：有車斗的車（卡車、礦卡）沿教過的路線自己往返。
-- 由 vehicles.lua 載入，vehicle_truck.lua 的 hauler 接上（E 設定畫面、每一步、存檔）。
--   教路線：坐在車上按 E →「設為裝載點並開始錄製」→ 開到倒土的地方 →「設為傾倒點」（每 REC_STEP m 記一個路線點）。
--   指示線：錄製時自動顯示，貼著地面畫出路線（綠）、裝載點（藍）、傾倒點（紅）；設定畫面可以開關，只有自己看得到。
--   附近有破碎站時再畫一圈容許範圍：傾倒點設在圈內才會自己對準受料倉，人在圈內圈變綠，在圈外是橘色。
--   啟動後下車：在裝載點等裝滿 → 沿路線開到傾倒點 → 開到這一趟分配的傾倒位置前方的待命點 → 轉成車尾朝外
--   → 倒車進傾倒位置 → 抬斗倒在車尾 → 開回待命點 → 沿傾倒線開回路線 → 沿路線開回裝載點 → 再等。
--   傾倒區：沿傾倒點左右排成一排（中、左、右、更左、更右…，間距一個車寬＋1 m，共 DUMP_SPOTS 個），碎石都倒在
--   這條傾倒線外側，不會倒在進出的路上（像真的調度系統每趟分配不同的傾倒位置、倒車進位置）。位置被土堆佔住就跳過；
--   倒不乾淨就換下一個位置再倒，連兩個位置都倒不完就帶著剩下的開回去；全滿就在傾倒點等（推土機推平後在設定畫面重設）。
--   傾倒點設在破碎站旁邊：車子順著路線的方向開到受料倉前，自己倒車把車斗對準倉的中心，每趟都倒同一個位置；
--   倉裡放不下這一車就在待命點等。
--   綁定怪手：裝載點跟著怪手走，像真的礦場由怪手決定停車位置（spotting）。回到路線起點後直線開向怪手，在怪手前方
--   掉頭、倒車到車尾離怪手車身 rockmech_ahs_tail_gap，車斗在這台怪手的手臂範圍內，車頭朝外，裝滿直接開走。怪手移動就重新停車；前一台還在裝就在旁邊排隊。
--   會車：無人車被另一台無人車擋住，優先權低的那台往旁邊讓路，等對方過去再回來。裝滿出發的車最優先，再來是
--   正在裝的車，其他的最低；一樣就比編號。不然兩台會面對面互等。
--   路線共用：教好的路線（含傾倒點、綁定的怪手）按「儲存路線」存成「路線1」，別台車選它、按「套用路線」再啟動就好，
--   不必重開一遍。存在世界裡，車子壞了或賣掉路線還在。
--   前方有人或車就停（障礙偵測）；有人上車駕駛就暫停。爬坡限制、車尾碰撞照常。
--   只在玩家附近（引擎執行的區塊內）會動，跑太遠會停住，等玩家靠近才繼續。

local V = rockmech.vehicles

local REC_STEP = 3          -- 錄製路線點的間距 (m)
local TURN_ONLY = 0.6       -- 方向差超過這個角度 (rad) 就停下來原地轉
local DEAD = 0.08           -- 方向差小於這個角度就不轉
local LOOK = 6              -- 障礙偵測：車頭前方幾公尺有人就停
local LOOK_VEHICLE = 1.5    -- 其他車只看這麼近：要能開到怪手手臂範圍內。別台無人車看 LOOK，兩台對開才留得出讓路的空間
local TURN_AHEAD = 0.25     -- 原地轉之前先看這麼遠 (rad)，要大於一步轉的角度
local LATERAL = {0, 1, -1, 2, -2, 3, -3, 4, -4}   -- 傾倒位置的橫向順序（車寬＋1 m 為單位）
local DUMP_SPOTS = #LATERAL
local STANDOFF = 4          -- 待命點在傾倒位置前方（往回程）幾公尺
local APPROACH = 16         -- 進格柵的方向：看路線上離格柵這麼遠的點，別被最後幾公尺的轉彎帶偏
local HOPPER_WAIT = "受料倉滿了，等待中"
local QUEUE_R, QUEUE_SIDE = 25, 10  -- 排隊的位置：離怪手多遠、離進出的路線多遠 (m)
local ARM_USE = 0.9         -- 車斗中心要在手臂長度的這個比例內
local TAIL_MIN = 0.6        -- 手臂再短，車尾離怪手車身也至少留這麼多 (m)
local YIELD_AFTER = 1       -- 被別台無人車擋住多久才要它讓路 (s)
local YIELD_HOLD = 4        -- 對方不再要求之後，再等這麼久才回去 (s)
local YIELD_GAP = 2         -- 讓路時兩台車身之間留的距離 (m)
local cfg = rockmech.cfg

local AHS = {}
V.ahs = AHS

local PHASE = {wait = "在裝載點等裝滿", to_dump = "前往傾倒點", to_spot = "前往傾倒位置", align = "對準傾倒位置",
	back_in = "倒車進傾倒位置", dumping = "倒土", pull_out = "離開傾倒位置", to_route = "倒完，回到路線",
	to_load = "回裝載點", full = "傾倒區滿了（推平後在設定畫面重設）",
	to_exc = "前往怪手", exc_align = "掉頭對準怪手", exc_back = "倒車到怪手旁"}

local function flat_dist(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.z - b.z) ^ 2) end
local function round(p) return {x = math.floor(p.x * 10 + 0.5) / 10, y = math.floor(p.y * 10 + 0.5) / 10, z = math.floor(p.z * 10 + 0.5) / 10} end
-- 方向差（rad，−π..π）：從 yaw 轉到朝向水平向量 (hx, hz)
local function heading_diff(yaw, hx, hz)
	return (V.atan2(-hx, hz) - yaw + math.pi) % (2 * math.pi) - math.pi
end

-- 名牌上的無人駕駛狀態
function AHS.status(self)
	local a = self.ahs
	if not (a and a.on) then return nil end
	if self.driver then return "無人駕駛：暫停（有人駕駛）" end
	return "無人駕駛：" .. (a.wait_msg or PHASE[a.phase] or "")
end

local function set_phase(self, phase)
	local a = self.ahs
	a.phase, a.wait_msg = phase, nil
	V.refresh(self)
end

-- 開進傾倒點的方向（水平單位向量）：倒的時候車尾朝這邊
local function dir_in(a)
	if a.hopper then return a.hopper.d end
	local p, q = a.route[#a.route - 1], a.route[#a.route]
	local dx, dz = q.x - p.x, q.z - p.z
	local l = math.sqrt(dx * dx + dz * dz)
	if l < 1e-6 then return {x = 0, z = 1} end
	return {x = dx / l, z = dz / l}
end
-- 第 i 個傾倒位置（0 起算；超出傾倒區回傳 nil）。破碎站只有一個位置：車尾後面的第一排倒在格柵中心
local function spot_pos(a, def, i)
	if i >= DUMP_SPOTS then return nil end
	local d = dir_in(a)
	if a.hopper then
		local back = def.rear + 1
		return {x = a.hopper.x - d.x * back, y = a.dump.y, z = a.hopper.z - d.z * back}
	end
	local lat = LATERAL[i + 1] * (2 * def.half + 1)
	return {x = a.dump.x - d.z * lat, y = a.dump.y, z = a.dump.z + d.x * lat}
end
-- 往回程方向退 k 公尺的點
local function standoff(a, p, k)
	local d = dir_in(a)
	return {x = p.x - d.x * k, y = p.y, z = p.z - d.z * k}
end
-- 傾倒位置能不能用：車停的地方地面上沒有碎石，車尾後面的土堆還沒超過 3 格高
local function spot_free(a, def, sp)
	local y0 = V.ground_y(sp, def.half)
	local c = {x = math.floor(sp.x + 0.5), y = y0, z = math.floor(sp.z + 0.5)}
	if not V.passable(core.get_node(c).name) then return false end
	local d = dir_in(a)
	local back = def.rear + 1
	local q = {x = math.floor(sp.x + d.x * back + 0.5), y = y0 + 2, z = math.floor(sp.z + d.z * back + 0.5)}
	return V.passable(core.get_node(q).name)
end
-- 從 a.spot 起找下一個能用的傾倒位置
local function next_spot(a, def)
	if a.hopper then return spot_pos(a, def, 0) end
	while true do
		local sp = spot_pos(a, def, a.spot or 0)
		if not sp then return nil end
		if spot_free(a, def, sp) then return sp end
		a.spot = (a.spot or 0) + 1
	end
end

-- 會車的優先權：在傾倒位置上 > 裝滿出發 > 正在裝 > 其他，一樣就比編號
-- 在傾倒位置上的車馬上就走，叫它讓路只會把它推到倉口邊
local AT_DUMP = {to_spot = true, align = true, back_in = true, dumping = true, pull_out = true}
local function rank(t)
	local p = t.ahs.phase
	if AT_DUMP[p] then return 4 end
	if p == "to_dump" then return 3 end
	if p == "wait" or p == "exc_align" or p == "exc_back" then return 2 end
	return 1
end
local function outranks(s, b)
	if rank(s) ~= rank(b) then return rank(s) > rank(b) end
	return s.uid < b.uid
end
-- self 開不過去：要擋路的 b 讓到路線旁邊。旁邊不能站（坑、岩壁）就換另一邊
local function ask_yield(self, def, ctx, b)
	local td = V.TYPES[b.vkind]
	local bp = b.object:get_pos()
	local fx, fz = ctx.dir.x, ctx.dir.z
	local rx, rz = bp.x - ctx.pos.x, bp.z - ctx.pos.z
	local along, lat = rx * fx + rz * fz, rx * fz - rz * fx
	local clear = def.half + td.half + YIELD_GAP
	local first = lat >= 0 and 1 or -1
	local target
	for _, side in ipairs({first, -first}) do
		local x = ctx.pos.x + fx * along + fz * clear * side
		local z = ctx.pos.z + fz * along - fx * clear * side
		local g = V.ground_top(x, bp.y + 2, z, 6)
		target = target or {x = x, y = bp.y, z = z}
		if g and math.abs(g - (bp.y - td.half)) < 1.2 then
			target = {x = x, y = bp.y, z = z}
			break
		end
	end
	-- 每次都重算：對方轉了向、車頭換了方向，上次的位置可能還擋在路上
	b.ahs.yield = {x = target.x, y = target.y, z = target.z, left = YIELD_HOLD}
end

-- 車尾往 diff 那邊掃得過去嗎：TURN_AHEAD 以內每一段都要過，只看最遠的會漏掉中途的岩壁，以為轉得動卻一步也轉不了
local function can_swing(self, def, ctx, diff)
	if not def.can_turn then return true end
	local side = diff > 0 and 1 or -1
	for k = 1, 5 do
		if not def.can_turn(self, ctx.pos, ctx.yaw, ctx.yaw + side * TURN_AHEAD * k / 5) then return false end
	end
	return true
end

-- 朝 target 開（方向差大就原地轉，否則邊開邊修正；前方有人或車就停；卡住會顯示）。ap 是這一步的操作
local function drive_to(self, def, ctx, a, ap, target)
	local pos = ctx.pos
	local diff = heading_diff(ctx.yaw, target.x - pos.x, target.z - pos.z)
	if diff > DEAD then ap.left = true elseif diff < -DEAD then ap.right = true end
	if math.abs(diff) >= TURN_ONLY then
		-- 車尾會掃到東西（常是旁邊的怪手）：先往前開，拉開距離再轉
		if can_swing(self, def, ctx, diff) then return end
		ap.left, ap.right = nil, nil
	end
	local h = def.half
	local _, car = V.objects_in(self, pos, ctx.yaw, -h, h, h, h + LOOK, "vehicle")
	if car and not (car.ahs and car.ahs.on) then
		_, car = V.objects_in(self, pos, ctx.yaw, -h, h, h, h + LOOK_VEHICLE, "vehicle")
	end
	if car or V.objects_in(self, pos, ctx.yaw, -h, h, h, h + LOOK, "player") then
		a.block_t = (a.block_t or 0) + ctx.dtime
		if car and a.block_t > YIELD_AFTER and car.ahs and car.ahs.on and not car.driver and outranks(self, car) then
			ask_yield(self, def, ctx, car)
		end
		if a.wait_msg ~= "前方有障礙，等待中" then a.wait_msg = "前方有障礙，等待中"; V.refresh(self) end
		return
	end
	a.block_t = 0
	ap.up = true
	-- 卡住偵測：一直想往前卻 8 秒沒前進
	local moved = a.last_pos and flat_dist(pos, a.last_pos) or 1
	a.stuck_t = moved < 0.05 * ctx.dtime * def.speed and (a.stuck_t or 0) + ctx.dtime or 0
	local msg = a.stuck_t > 8 and "卡住了（路上有東西或坡太陡）" or nil
	if msg ~= a.wait_msg then a.wait_msg = msg; V.refresh(self) end
end

-- 車尾離怪手中心多遠：離車身留 ahs_tail_gap，但車斗中心要搆得到；手臂短的怪手車就停近一點
local function tail_gap(kind, def)
	local ex = V.TYPES[kind]
	local reach = ex.arm_reach * ARM_USE - def.bed.size.z / 2
	return math.max(ex.half + TAIL_MIN, math.min(ex.half + cfg.ahs_tail_gap, reach))
end
-- 綁定的怪手：回傳 位置、路線那一側的單位向量 u、車身中心要停在離怪手多遠。怪手沒載入時用最後看到的位置
local function exc_spot(a, def)
	local b = a.bound
	local e = V.by_uid[b.uid]
	local p = e and e.object:get_pos()
	if p then b.pos, b.kind = round(p), e.vkind end
	local start = a.route[1]
	local dx, dz = start.x - b.pos.x, start.z - b.pos.z
	local l = math.sqrt(dx * dx + dz * dz)
	local u = l < 1 and {x = 0, z = 1} or {x = dx / l, z = dz / l}
	return b.pos, u, def.rear + tail_gap(b.kind or "excavator_big", def), l
end
-- 怪手這裡有別台綁同一台的車：正在裝，或裝滿還沒開遠（只有一條進出的路，重車先走，不然會面對面停住）
local function exc_busy(self, a, e)
	for _, o in ipairs(core.get_objects_inside_radius(e, QUEUE_R)) do
		local t = o:get_luaentity()
		local ta = t and t ~= self and t.ahs
		if ta and ta.on and ta.bound and ta.bound.uid == a.bound.uid
				and (ta.phase == "wait" or ta.phase == "exc_align" or ta.phase == "exc_back" or ta.phase == "to_dump") then
			return ta
		end
	end
end
local function say(self, a, msg)
	if a.wait_msg ~= msg then a.wait_msg = msg; V.refresh(self) end
end
-- 受料倉一次一台：有別台正在這座倉倒料，就在倒車的距離外等
local function hopper_busy(self, a)
	for _, o in ipairs(core.get_objects_inside_radius(a.hopper, QUEUE_R)) do
		local t = o:get_luaentity()
		local ta = t and t ~= self and t.ahs
		if ta and ta.on and ta.hopper and ta.hopper.x == a.hopper.x and ta.hopper.z == a.hopper.z and AT_DUMP[ta.phase] then
			return true
		end
	end
end

-- 每一步：錄製路線點；無人駕駛時決定下一步的操作（self.autopilot）
function AHS.step(self, def, ctx)
	local a = self.ahs
	if not a then return end
	local pos = ctx.pos
	if a.rec and ctx.d then
		local last = a.route[#a.route]
		if flat_dist(pos, last) >= REC_STEP then a.route[#a.route + 1] = round(pos) end
	end
	if not a.on then return end
	if ctx.d then self.autopilot = nil; return end   -- 有人駕駛：暫停
	local ap = {}
	local reach = def.half + 1
	if a.yield then
		-- 讓路：開到旁邊等對方過去；讓路前在裝的車，回來重新停車
		a.yield.left = a.yield.left - ctx.dtime
		if a.yield.left <= 0 then
			a.yield = nil
			if a.bound and a.phase == "wait" then set_phase(self, "to_exc")
			elseif a.phase == "align" or a.phase == "back_in" then set_phase(self, "to_spot") end   -- 回待命點重新對準
		else
			say(self, a, "讓路中")
			if flat_dist(pos, a.yield) > 1.5 then
				drive_to(self, def, ctx, a, ap, a.yield)
				if not (ap.up or ap.left or ap.right) then ap.down = true end   -- 已經貼住了：先倒車退開
			end
			a.last_pos = vector.copy(pos)
			self.autopilot = ap
			return
		end
	end
	if a.phase == "wait" then
		if V.load_total(self) >= def.cap then
			a.idx = a.bound and 1 or 2      -- 綁定怪手：從怪手旁邊先開回路線起點
			set_phase(self, "to_dump")
		elseif a.bound and flat_dist(exc_spot(a, def), a.spot_at or pos) > cfg.ahs_follow then
			set_phase(self, "to_exc")       -- 怪手走了，跟過去
		end
	elseif a.phase == "to_dump" or a.phase == "to_load" then
		local fwd = a.phase == "to_dump"
		local target = a.route[a.idx]
		if target and flat_dist(pos, target) < reach then
			a.idx = a.idx + (fwd and 1 or -1)
			target = a.route[a.idx]
		end
		-- 破碎站：路線畫到格柵上，開到倒車的距離就夠了
		if fwd and a.hopper and flat_dist(pos, a.hopper) < def.rear + 1 + STANDOFF + reach then target = nil end
		if target then
			drive_to(self, def, ctx, a, ap, target)
		elseif fwd then
			if a.hopper and hopper_busy(self, a) then
				say(self, a, "等前車倒完")
			else
				-- 到了傾倒點：找這一趟的傾倒位置
				a.fails = 0
				a.target = next_spot(a, def)
				set_phase(self, a.target and "to_spot" or "full")
			end
		else
			set_phase(self, a.bound and "to_exc" or "wait")
		end
	elseif a.phase == "to_exc" then
		local e, u, stop, far = exc_spot(a, def)
		if far > cfg.ahs_max_dist then
			say(self, a, ("怪手離路線起點太遠（%d m）"):format(far))
		else
			local busy = exc_busy(self, a, e)
			local out = busy and busy.route[1]
			if busy then
				-- 前一台還在裝：在路線旁邊等，站在它出去那條路的另一側（兩台的路線不同時，排隊點才不會擋路）
				local side = (out.z - e.z) * u.x - (out.x - e.x) * u.z > 0 and -1 or 1
				local q = {x = e.x + u.x * QUEUE_R - u.z * QUEUE_SIDE * side, y = e.y,
					z = e.z + u.z * QUEUE_R + u.x * QUEUE_SIDE * side}
				if flat_dist(pos, q) < reach then say(self, a, "等前一台裝完")
				else drive_to(self, def, ctx, a, ap, q) end
			else
				local far_pt = {x = e.x + u.x * (stop + cfg.ahs_back_in), y = e.y, z = e.z + u.z * (stop + cfg.ahs_back_in)}
				if flat_dist(pos, far_pt) < 1.5 then set_phase(self, "exc_align")
				else drive_to(self, def, ctx, a, ap, far_pt) end
			end
		end
	elseif a.phase == "exc_align" then
		-- 原地轉成車頭朝路線、車尾朝怪手
		local _, u = exc_spot(a, def)
		local diff = heading_diff(ctx.yaw, u.x, u.z)
		if math.abs(diff) > 0.12 then
			if not can_swing(self, def, ctx, diff) then ap.up = true    -- 車尾掃到岩壁：往前開，拉開距離再轉
			elseif diff > 0 then ap.left = true else ap.right = true end
		else
			a.stuck_t = 0
			set_phase(self, "exc_back")
		end
	elseif a.phase == "exc_back" then
		-- 倒車到車尾離怪手 ahs_tail_gap；到了、或頂到東西 3 秒沒動，就在這裡裝
		local e, u, stop = exc_spot(a, def)
		local moved = a.last_pos and flat_dist(pos, a.last_pos) or 1
		a.stuck_t = moved < 0.01 and (a.stuck_t or 0) + ctx.dtime or 0
		if flat_dist(pos, e) - stop < 0.3 or a.stuck_t > 3 then
			a.spot_at = {x = e.x, y = e.y, z = e.z}
			set_phase(self, "wait")
		else
			ap.down = true
			local diff = heading_diff(ctx.yaw, u.x, u.z)
			if diff > DEAD then ap.left = true elseif diff < -DEAD then ap.right = true end
		end
	elseif a.phase == "to_spot" then
		-- 先到傾倒位置前方的待命點
		local sp = standoff(a, a.target, STANDOFF)
		if flat_dist(pos, sp) < 1.0 then
			if a.hopper and rockmech.hopper_room(a.hopper) < V.load_total(self) then
				if a.wait_msg ~= HOPPER_WAIT then a.wait_msg = HOPPER_WAIT; V.refresh(self) end
			else
				set_phase(self, "align")
			end
		else
			drive_to(self, def, ctx, a, ap, sp)
		end
	elseif a.phase == "align" then
		-- 原地轉成車頭朝回程、車尾朝外
		local d = dir_in(a)
		local diff = heading_diff(ctx.yaw, -d.x, -d.z)
		if math.abs(diff) > 0.12 then
			if diff > 0 then ap.left = true else ap.right = true end
			say(self, a, not can_swing(self, def, ctx, diff) and "車尾被擋住，等待中" or nil)
		else
			a.stuck_t = 0
			set_phase(self, "back_in")
		end
	elseif a.phase == "back_in" then
		-- 倒車進傾倒位置；到了、或車尾頂到東西 3 秒沒動，就在這裡倒
		local d = dir_in(a)
		local left = (a.target.x - pos.x) * d.x + (a.target.z - pos.z) * d.z   -- 還要往外倒車多遠
		local moved = a.last_pos and flat_dist(pos, a.last_pos) or 1
		a.stuck_t = moved < 0.01 and (a.stuck_t or 0) + ctx.dtime or 0
		if left < 0.3 or a.stuck_t > 3 then
			a.tipped = nil
			set_phase(self, "dumping")
		else
			ap.down = true
			local diff = heading_diff(ctx.yaw, -d.x, -d.z)
			if diff > DEAD then ap.left = true elseif diff < -DEAD then ap.right = true end
		end
	elseif a.phase == "dumping" then
		if self.tip then
			a.tipped = true
		elseif a.tipped or V.load_total(self) == 0 then     -- 空車不會抬斗（「立即出發」空車來，或讓路時已經倒完）
			-- 倒完一次：這個位置用掉了；倒乾淨就離開，倒不乾淨換下一個位置，連兩個都倒不完就帶著剩下的回去
			a.tipped = nil
			if not a.hopper then a.spot = (a.spot or 0) + 1 end
			if V.load_total(self) == 0 then
				set_phase(self, "pull_out")
			else
				a.fails = (a.fails or 0) + 1
				local nxt = a.fails < 2 and next_spot(a, def)
				set_phase(self, "pull_out")
				if nxt then a.next_target = nxt else a.wait_msg = "傾倒區滿了，帶著剩下的回去" end
			end
		else
			ap.jump = true
		end
	elseif a.phase == "pull_out" then
		-- 往前開回待命點，再去下一個位置或回路線
		local sp = standoff(a, a.target, STANDOFF)
		if flat_dist(pos, sp) < 1.0 then
			if a.next_target then
				a.target, a.next_target = a.next_target, nil
				set_phase(self, "to_spot")
			else
				set_phase(self, "to_route")
			end
		else
			drive_to(self, def, ctx, a, ap, sp)
		end
	elseif a.phase == "to_route" then
		-- 沿傾倒線前方回到傾倒點前的待命點，接上路線（破碎站：倒完的位置就在路線旁，直接接上）
		local sp = a.hopper and pos or standoff(a, a.dump, STANDOFF)
		if flat_dist(pos, sp) < reach then
			local best, bi = math.huge, #a.route
			for i = #a.route, 1, -1 do
				local dd = flat_dist(sp, a.route[i])
				if dd < best then best, bi = dd, i end
			end
			a.idx = math.max(1, bi - 1)
			set_phase(self, "to_load")
		else
			drive_to(self, def, ctx, a, ap, sp)
		end
	elseif a.phase == "full" then
		-- 等重設；重設後找得到位置就繼續
		a.target = next_spot(a, def)
		if a.target then set_phase(self, "to_spot") end
	end
	a.last_pos = vector.copy(pos)
	self.autopilot = ap
end

-- 路線指示線：粒子只送給設定的玩家，每秒畫一次他附近的路段
local LINE_EVERY, LINE_STEP, LINE_RANGE = 1, 1, 48
local RING_STEP = 1.5       -- 容許範圍圈上粒子的間距 (m)
local lines = {}            -- 玩家名稱 → self.ahs
local function mark(name, p, size, color)
	local g = V.ground_top(p.x, p.y + 2, p.z, 8)
	core.add_particle({pos = {x = p.x, y = (g or p.y) + 0.3, z = p.z}, expirationtime = LINE_EVERY * 1.1,
		size = size, texture = "[fill:4x4:" .. color, glow = 14, playername = name})
end
local function draw_line(name, a)
	local player = core.get_player_by_name(name)
	if not player or not a.route then return end
	local me = player:get_pos()
	for i = 1, #a.route - 1 do
		local p, q = a.route[i], a.route[i + 1]
		if flat_dist(me, p) < LINE_RANGE then
			local n = math.max(1, math.floor(flat_dist(p, q) / LINE_STEP))
			for s = 0, n - 1 do mark(name, vector.add(p, vector.multiply(vector.subtract(q, p), s / n)), 3, "#40ff70") end
		end
	end
	if a.load and flat_dist(me, a.load) < LINE_RANGE then mark(name, a.load, 12, "#40a0ff") end
	if a.dump and flat_dist(me, a.dump) < LINE_RANGE then mark(name, a.dump, 12, "#ff4040") end
	if a.bound and a.route[1] and flat_dist(me, a.bound.pos) < LINE_RANGE then
		-- 綁定的怪手：藍點，路線起點到怪手畫一段
		local p, q = a.route[1], a.bound.pos
		local n = math.max(1, math.floor(flat_dist(p, q) / LINE_STEP))
		for s = 0, n - 1 do mark(name, vector.add(p, vector.multiply(vector.subtract(q, p), s / n)), 3, "#40ff70") end
		mark(name, q, 12, "#40a0ff")
	end
	local c = rockmech.grate_center(me, LINE_RANGE)
	if c then
		local R = rockmech.HOPPER_RANGE
		local color = flat_dist(me, c) <= R and "#60ff60" or "#ffb040"
		local n = math.floor(2 * math.pi * R / RING_STEP)
		for i = 1, n do
			local t = 2 * math.pi * i / n
			mark(name, {x = c.x + R * math.cos(t), y = c.y + 6, z = c.z + R * math.sin(t)}, 4, color)
		end
	end
end
local line_t = 0
core.register_globalstep(function(dtime)
	line_t = line_t + dtime
	if line_t < LINE_EVERY then return end
	line_t = 0
	for name, a in pairs(lines) do draw_line(name, a) end
end)
core.register_on_leaveplayer(function(player) lines[player:get_player_name()] = nil end)

-- 傾倒點在破碎站旁邊：記下格柵中心和進格柵的方向
local function find_hopper(a)
	local c = rockmech.grate_center(a.dump)
	if not c then return nil end
	local from = a.route[1]
	for i = #a.route, 1, -1 do
		if flat_dist(a.route[i], c) >= APPROACH then from = a.route[i]; break end
	end
	local dx, dz = c.x - from.x, c.z - from.z
	local l = math.sqrt(dx * dx + dz * dz)
	c.d = l < 1e-6 and {x = 0, z = 1} or {x = dx / l, z = dz / l}
	-- 從機身那一側來的話，倒車會頂到機身、料倒不進倉：改從旁邊倒進去
	local b = core.find_node_near(c, 7, "rockmech:crusher")
	if b then
		local bx, bz = b.x - c.x, b.z - c.z
		local bl = math.sqrt(bx * bx + bz * bz)
		bx, bz = bx / bl, bz / bl
		if -(c.d.x * bx + c.d.z * bz) > 0.5 then
			local side = c.d.z * bx - c.d.x * bz >= 0 and 1 or -1
			c.d = {x = -bz * side, z = bx * side}
		end
	end
	return c
end

-- 存下來的路線：名稱 → {route, load, dump, bound}，所有車共用
local ROUTES_KEY = "ahs_routes"
local storage = rockmech.collapse.storage
local routes = core.deserialize(storage:get_string(ROUTES_KEY)) or {}
local NO_ROUTE = "（還沒有路線）"
local function route_names()
	local names = {}
	for k in pairs(routes) do names[#names + 1] = k end
	table.sort(names, function(p, q) return #p < #q or (#p == #q and p < q) end)   -- 路線2 排在 路線10 前面
	return names
end
-- 第一次存取新名字；這條路線本來就有名字就更新它
local function save_route(a)
	if not a.route_name then
		local n = 1
		while routes["路線" .. n] do n = n + 1 end
		a.route_name = "路線" .. n
	end
	routes[a.route_name] = table.copy({route = a.route, load = a.load, dump = a.dump, bound = a.bound})
	storage:set_string(ROUTES_KEY, core.serialize(routes))
end
local function use_route(a, name)
	local r = table.copy(routes[name])
	a.route, a.load, a.dump, a.bound, a.route_name = r.route, r.load, r.dump, r.bound, name
	a.on, a.rec, a.spot, a.spot_at, a.yield = false, false, 0, nil, nil
	a.hopper = find_hopper(a)
end

-- 設定畫面
local editing = {}
local picked = {}           -- 玩家名稱 → 下拉選單選到的路線
local function fmt(p) return p and ("(%d, %d, %d)"):format(math.floor(p.x + 0.5), math.floor(p.y + 0.5), math.floor(p.z + 0.5)) or "未設定" end
local function formspec(self, name)
	local a = self.ahs or {}
	local names = route_names()
	local sel = 1
	for i, n in ipairs(names) do
		if n == (picked[name] or a.route_name) then sel = i end
	end
	local st = a.rec and (rockmech.grate_center(self.object:get_pos())
			and "錄製中：在受料倉範圍內，在這裡按「設為傾倒點」會自己對準"
			or "錄製路線中（開到傾倒點後按「設為傾倒點」）")
		or a.on and (a.wait_msg or PHASE[a.phase] or "") or "停止"
	return table.concat({
		"formspec_version[6]size[9,10.2]",
		"label[0.5,0.6;無人駕駛（AHS）]",
		("label[0.5,1.2;裝載點：%s]"):format(a.bound and "跟著怪手" or fmt(a.load)),
		("label[0.5,1.7;傾倒點：%s%s]"):format(fmt(a.dump), a.hopper and "（破碎站受料倉）" or ""),
		("label[0.5,2.2;%s：%d 個點　傾倒區：已用 %d / %d 個位置]"):format(a.route_name or "路線", a.route and #a.route or 0,
			math.min(a.spot or 0, DUMP_SPOTS), DUMP_SPOTS),
		("label[0.5,2.7;狀態：%s]"):format(st),
		"button[0.5,3.2;8,0.8;rec;設為裝載點並開始錄製路線（目前位置）]",
		"button[0.5,4.1;8,0.8;dump;設為傾倒點（結束錄製）]",
		"button[0.5,5.0;3.9,0.8;start;啟動（啟動後請下車）]",
		"button[4.6,5.0;3.9,0.8;stop;停止]",
		"button[0.5,5.9;3.9,0.8;go;立即出發（不等裝滿）]",
		"button[4.6,5.9;3.9,0.8;reset;重設傾倒區]",
		"button[0.5,6.8;3.9,0.8;line;顯示／隱藏路線]",
		"button_exit[4.6,6.8;3.9,0.8;ok;關閉]",
		("button[0.5,7.7;8,0.8;bind;%s]"):format(a.bound and "解除綁定怪手" or "綁定最近的怪手（裝載點跟著怪手走）"),
		"button[0.5,8.6;2.6,0.8;save;儲存路線]",
		("dropdown[3.2,8.6;2.7,0.8;route_pick;%s;%d;false]"):format(#names > 0 and table.concat(names, ",") or NO_ROUTE, sel),
		"button[6,8.6;2.5,0.8;use;套用路線]",
		"label[0.5,9.7;裝滿 → 沿路線到傾倒線，倒車進這趟的位置倒土 → 開回裝載點；前方有人或車會停]",
	})
end
function AHS.open(self, player)
	local name = player:get_player_name()
	editing[name] = self
	core.show_formspec(name, "rockmech:ahs", formspec(self, name))
end
core.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= "rockmech:ahs" then return end
	local name = player:get_player_name()
	local self = editing[name]
	if not self or not self.object:get_pos() then return true end
	local a = self.ahs or {}
	self.ahs = a
	local pos = self.object:get_pos()
	local msg
	picked[name] = fields.route_pick or picked[name]
	if fields.rec then
		a.load, a.dump, a.route, a.rec, a.on, a.spot = round(pos), nil, {round(pos)}, true, false, 0
		a.hopper, a.route_name = nil, nil
		lines[name] = a
		msg = "開始錄製：開到倒土的地方"
	elseif fields.dump then
		if not a.rec then msg = "要先設裝載點並開始錄製"
		else
			a.route[#a.route + 1] = round(pos)
			a.dump, a.rec = round(pos), false
			a.hopper = find_hopper(a)
			msg = ("路線錄好了（%d 個點）%s"):format(#a.route, a.hopper and "：傾倒點在破碎站，會自己倒車對準受料倉" or "")
		end
	elseif fields.start then
		if not (a.route and #a.route >= 2 and a.dump) then msg = "要先錄好路線（裝載點 → 傾倒點）"
		else
			a.on = true
			a.hopper = find_hopper(a)        -- 破碎站可能是錄完路線才蓋的，或錄的時候差一點在範圍外
			-- 從最近的路線點接上：在裝載點附近就等裝滿，否則先開回裝載點
			local best, bi = math.huge, 1
			for i, p in ipairs(a.route) do
				local dd = flat_dist(pos, p)
				if dd < best then best, bi = dd, i end
			end
			if bi == 1 then a.phase = a.bound and "to_exc" or "wait" else a.phase, a.idx = "to_load", bi end
			a.wait_msg = nil
			msg = "已啟動：請下車"
		end
	elseif fields.line then
		lines[name] = lines[name] ~= a and a or nil
	elseif fields.stop then
		a.on = false
		self.autopilot = nil
		msg = "已停止"
	elseif fields.go then
		if a.on and a.phase == "wait" then a.idx = a.bound and 1 or 2; a.phase = "to_dump"; msg = "出發" end
	elseif fields.bind then
		if a.bound then
			a.bound, a.spot_at = nil, nil
			msg = "解除綁定怪手"
		else
			local best, bd
			for _, o in ipairs(core.get_objects_inside_radius(pos, cfg.ahs_max_dist)) do
				local e = o:get_luaentity()
				if e and e.uid and e.vkind and e.vkind:find("excavator", 1, true) then
					local d = vector.distance(pos, o:get_pos())
					if not bd or d < bd then best, bd = e, d end
				end
			end
			if best then
				a.bound = {uid = best.uid, pos = round(best.object:get_pos()), kind = best.vkind}
				msg = ("綁定怪手（%d m 外）：裝載點跟著它走"):format(bd)
			else
				msg = ("%d m 內沒有怪手"):format(cfg.ahs_max_dist)
			end
		end
	elseif fields.reset then
		a.spot = 0
		msg = "傾倒區重設：從第一個位置開始"
	elseif fields.save then
		if not (a.route and #a.route >= 2 and a.dump) then msg = "要先錄好路線（裝載點 → 傾倒點）"
		else
			save_route(a)
			picked[name] = a.route_name
			msg = "已存成" .. a.route_name .. "：別台車選它、按「套用路線」就能用"
		end
	elseif fields.use then
		local pick = picked[name]
		if not routes[pick or ""] then msg = "還沒有存好的路線"
		else
			use_route(a, pick)
			self.autopilot = nil
			lines[name] = a
			msg = "已套用" .. pick .. "：按「啟動」後下車"
		end
	end
	if msg then core.chat_send_player(name, "[無人駕駛] " .. msg) end
	V.refresh(self)
	if fields.quit or fields.ok then editing[name], picked[name] = nil, nil
	else core.show_formspec(name, "rockmech:ahs", formspec(self, name)) end
	return true
end)

function AHS.save(self, data) data.ahs = self.ahs end
function AHS.load(self, data)
	if type(data.ahs) == "table" then
		self.ahs = data.ahs
		self.ahs.rec = false
	end
end
rockmech.ahs_spot_pos = spot_pos   -- 測試用
