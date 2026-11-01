-- rockmech/vehicle_ahs.lua
-- 無人運輸（AHS，像 Komatsu FrontRunner／Cat MineStar Command）：有車斗的車（卡車、礦卡）沿教過的路線自己往返。
-- 由 vehicles.lua 載入，vehicle_truck.lua 的 hauler 接上（E 設定畫面、每一步、存檔）。
--   教路線：坐在車上按 E →「設為裝載點並開始錄製」→ 開到倒土的地方 →「設為傾倒點」（每 REC_STEP m 記一個路線點）。
--   指示線：錄製時自動顯示，貼著地面畫出路線（綠）、裝載點（藍）、傾倒點（紅）；設定畫面可以開關，只有自己看得到。
--   啟動後下車：在裝載點等裝滿 → 沿路線開到傾倒點 → 開到這一趟分配的傾倒位置前方的待命點 → 轉成車尾朝外
--   → 倒車進傾倒位置 → 抬斗倒在車尾 → 開回待命點 → 沿傾倒線開回路線 → 沿路線開回裝載點 → 再等。
--   傾倒區：沿傾倒點左右排成一排（中、左、右、更左、更右…，間距一個車寬＋1 m，共 DUMP_SPOTS 個），碎石都倒在
--   這條傾倒線外側，不會倒在進出的路上（像真的調度系統每趟分配不同的傾倒位置、倒車進位置）。位置被土堆佔住就跳過；
--   倒不乾淨就換下一個位置再倒，連兩個位置都倒不完就帶著剩下的開回去；全滿就在傾倒點等（推土機推平後在設定畫面重設）。
--   傾倒點設在破碎站旁邊：車子順著路線的方向開到受料倉前，自己倒車把車斗對準倉的中心，每趟都倒同一個位置；
--   倉裡放不下這一車就在待命點等。
--   前方有人或車就停（障礙偵測）；有人上車駕駛就暫停。爬坡限制、車尾碰撞照常。
--   只在玩家附近（引擎執行的區塊內）會動，跑太遠會停住，等玩家靠近才繼續。

local V = rockmech.vehicles

local REC_STEP = 3          -- 錄製路線點的間距 (m)
local TURN_ONLY = 0.6       -- 方向差超過這個角度 (rad) 就停下來原地轉
local DEAD = 0.08           -- 方向差小於這個角度就不轉
local LOOK = 6              -- 障礙偵測：車頭前方幾公尺
local LATERAL = {0, 1, -1, 2, -2, 3, -3, 4, -4}   -- 傾倒位置的橫向順序（車寬＋1 m 為單位）
local DUMP_SPOTS = #LATERAL
local STANDOFF = 4          -- 待命點在傾倒位置前方（往回程）幾公尺
local APPROACH = 16         -- 進格柵的方向：看路線上離格柵這麼遠的點，別被最後幾公尺的轉彎帶偏
local HOPPER_WAIT = "受料倉滿了，等待中"

local AHS = {}
V.ahs = AHS

local PHASE = {wait = "在裝載點等裝滿", to_dump = "前往傾倒點", to_spot = "前往傾倒位置", align = "對準傾倒位置",
	back_in = "倒車進傾倒位置", dumping = "倒土", pull_out = "離開傾倒位置", to_route = "倒完，回到路線",
	to_load = "回裝載點", full = "傾倒區滿了（推平後在設定畫面重設）"}

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

-- 朝 target 開（方向差大就原地轉，否則邊開邊修正；前方有人或車就停；卡住會顯示）。ap 是這一步的操作
local function drive_to(self, def, ctx, a, ap, target)
	local pos = ctx.pos
	local diff = heading_diff(ctx.yaw, target.x - pos.x, target.z - pos.z)
	if diff > DEAD then ap.left = true elseif diff < -DEAD then ap.right = true end
	if math.abs(diff) >= TURN_ONLY then return end
	local h = def.half
	if V.objects_in(self, pos, ctx.yaw, -h, h, h, h + LOOK) then
		if a.wait_msg ~= "前方有障礙，等待中" then a.wait_msg = "前方有障礙，等待中"; V.refresh(self) end
		return
	end
	ap.up = true
	-- 卡住偵測：一直想往前卻 8 秒沒前進
	local moved = a.last_pos and flat_dist(pos, a.last_pos) or 1
	a.stuck_t = moved < 0.05 * ctx.dtime * def.speed and (a.stuck_t or 0) + ctx.dtime or 0
	local msg = a.stuck_t > 8 and "卡住了（路上有東西或坡太陡）" or nil
	if msg ~= a.wait_msg then a.wait_msg = msg; V.refresh(self) end
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
	if a.phase == "wait" then
		if V.load_total(self) >= def.cap then
			a.idx = 2
			set_phase(self, "to_dump")
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
			-- 到了傾倒點：找這一趟的傾倒位置
			a.fails = 0
			a.target = next_spot(a, def)
			set_phase(self, a.target and "to_spot" or "full")
		else
			set_phase(self, "wait")
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
			set_phase(self, "dumping")
		else
			ap.down = true
			local diff = heading_diff(ctx.yaw, -d.x, -d.z)
			if diff > DEAD then ap.left = true elseif diff < -DEAD then ap.right = true end
		end
	elseif a.phase == "dumping" then
		if self.tip then
			a.tipped = true
		elseif a.tipped then
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
	return c
end

-- 設定畫面
local editing = {}
local function fmt(p) return p and ("(%d, %d, %d)"):format(math.floor(p.x + 0.5), math.floor(p.y + 0.5), math.floor(p.z + 0.5)) or "未設定" end
local function formspec(self)
	local a = self.ahs or {}
	local st = a.rec and "錄製路線中（開到傾倒點後按「設為傾倒點」）"
		or a.on and (a.wait_msg or PHASE[a.phase] or "") or "停止"
	return table.concat({
		"formspec_version[6]size[9,8.4]",
		"label[0.5,0.6;無人駕駛（AHS）]",
		("label[0.5,1.2;裝載點：%s]"):format(fmt(a.load)),
		("label[0.5,1.7;傾倒點：%s]"):format(fmt(a.dump)),
		("label[0.5,2.2;路線：%d 個點　傾倒區：已用 %d / %d 個位置]"):format(a.route and #a.route or 0,
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
		"label[0.5,7.9;裝滿 → 沿路線到傾倒線，倒車進這趟的位置倒土 → 開回裝載點；前方有人或車會停]",
	})
end
function AHS.open(self, player)
	local name = player:get_player_name()
	editing[name] = self
	core.show_formspec(name, "rockmech:ahs", formspec(self))
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
	if fields.rec then
		a.load, a.dump, a.route, a.rec, a.on, a.spot = round(pos), nil, {round(pos)}, true, false, 0
		a.hopper = nil
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
			-- 從最近的路線點接上：在裝載點附近就等裝滿，否則先開回裝載點
			local best, bi = math.huge, 1
			for i, p in ipairs(a.route) do
				local dd = flat_dist(pos, p)
				if dd < best then best, bi = dd, i end
			end
			if bi == 1 then a.phase = "wait" else a.phase, a.idx = "to_load", bi end
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
		if a.on and a.phase == "wait" then a.idx = 2; a.phase = "to_dump"; msg = "出發" end
	elseif fields.reset then
		a.spot = 0
		msg = "傾倒區重設：從第一個位置開始"
	end
	if msg then core.chat_send_player(name, "[無人駕駛] " .. msg) end
	V.refresh(self)
	if fields.quit or fields.ok then editing[name] = nil
	else core.show_formspec(name, "rockmech:ahs", formspec(self)) end
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
