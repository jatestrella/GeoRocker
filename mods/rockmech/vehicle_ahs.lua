-- rockmech/vehicle_ahs.lua
-- 無人運輸（AHS，像 Komatsu FrontRunner／Cat MineStar Command）：有車斗的車（卡車、礦卡）沿教過的路線自己往返。
-- 由 vehicles.lua 載入，vehicle_truck.lua 的 hauler 接上（E 設定畫面、每一步、存檔）。
--   教路線：坐在車上按 E →「設為裝載點並開始錄製」→ 開到倒土的地方 →「設為傾倒點」（每 REC_STEP m 記一個路線點）。
--   啟動後下車：在裝載點等裝滿 → 沿路線開到傾倒點 → 原地掉頭（車尾朝外）→ 抬斗倒在車尾 → 沿路線開回裝載點 → 再等。
--   前方有人或車就停（障礙偵測）；有人上車駕駛就暫停。爬坡限制、車尾碰撞照常。
--   只在玩家附近（引擎執行的區塊內）會動，跑太遠會停住，等玩家靠近才繼續。

local V = rockmech.vehicles
local TYPES = V.TYPES

local REC_STEP = 3          -- 錄製路線點的間距 (m)
local TURN_ONLY = 0.6       -- 方向差超過這個角度 (rad) 就停下來原地轉
local DEAD = 0.08           -- 方向差小於這個角度就不轉
local LOOK = 6              -- 障礙偵測：車頭前方幾公尺

local AHS = {}
V.ahs = AHS

local PHASE = {wait = "在裝載點等裝滿", to_dump = "前往傾倒點", dumping = "倒土", to_load = "回裝載點"}

local function flat_dist(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.z - b.z) ^ 2) end
local function round(p) return {x = math.floor(p.x * 10 + 0.5) / 10, y = math.floor(p.y * 10 + 0.5) / 10, z = math.floor(p.z * 10 + 0.5) / 10} end

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
	if a.phase == "wait" then
		if V.load_total(self) >= def.cap then
			a.idx = 2
			set_phase(self, "to_dump")
		end
	elseif a.phase == "dumping" then
		-- 先原地掉頭（車頭朝回程、車尾朝外，像礦卡倒車進傾倒點），碎石才不會倒在回程的路上
		local back = a.route[#a.route - 1]
		local want = V.atan2(-(back.x - pos.x), back.z - pos.z)
		local diff = (want - ctx.yaw + math.pi) % (2 * math.pi) - math.pi
		if not self.tip and V.load_total(self) == 0 then
			a.idx = #a.route - 1
			set_phase(self, "to_load")
		elseif not self.tip and math.abs(diff) > 0.15 then
			if diff > 0 then ap.left = true else ap.right = true end
		elseif not self.tip then
			ap.jump = true
		end
	else
		local fwd = a.phase == "to_dump"
		local target = a.route[a.idx]
		local reach = def.half + 1
		if target and flat_dist(pos, target) < reach then
			a.idx = a.idx + (fwd and 1 or -1)
			target = a.route[a.idx]
		end
		if not target then
			-- 到了路線終點
			set_phase(self, fwd and "dumping" or "wait")
		else
			-- 朝下一個路線點：方向差大就原地轉，否則邊開邊修正
			local dx, dz = target.x - pos.x, target.z - pos.z
			local want = V.atan2(-dx, dz)
			local diff = (want - ctx.yaw + math.pi) % (2 * math.pi) - math.pi
			if diff > DEAD then ap.left = true elseif diff < -DEAD then ap.right = true end
			if math.abs(diff) < TURN_ONLY then
				-- 障礙偵測：前方有人或車就停
				local h = def.half
				if V.objects_in(self, pos, ctx.yaw, -h, h, h, h + LOOK) then
					if a.wait_msg ~= "前方有障礙，等待中" then a.wait_msg = "前方有障礙，等待中"; V.refresh(self) end
				else
					ap.up = true
					-- 卡住偵測：一直想往前卻 8 秒沒前進
					local moved = a.last_pos and flat_dist(pos, a.last_pos) or 1
					a.stuck_t = moved < 0.05 * ctx.dtime * def.speed and (a.stuck_t or 0) + ctx.dtime or 0
					local msg = a.stuck_t > 8 and "卡住了（路上有東西或坡太陡）" or nil
					if msg ~= a.wait_msg then a.wait_msg = msg; V.refresh(self) end
				end
			end
		end
	end
	a.last_pos = vector.copy(pos)
	self.autopilot = ap
end

-- 設定畫面
local editing = {}
local function fmt(p) return p and ("(%d, %d, %d)"):format(math.floor(p.x + 0.5), math.floor(p.y + 0.5), math.floor(p.z + 0.5)) or "未設定" end
local function formspec(self)
	local a = self.ahs or {}
	local st = a.rec and "錄製路線中（開到傾倒點後按「設為傾倒點」）"
		or a.on and (PHASE[a.phase] or "") or "停止"
	return table.concat({
		"formspec_version[6]size[9,7.6]",
		"label[0.5,0.6;無人駕駛（AHS）]",
		("label[0.5,1.2;裝載點：%s]"):format(fmt(a.load)),
		("label[0.5,1.7;傾倒點：%s]"):format(fmt(a.dump)),
		("label[0.5,2.2;路線：%d 個點]"):format(a.route and #a.route or 0),
		("label[0.5,2.7;狀態：%s]"):format(st),
		"button[0.5,3.2;8,0.8;rec;設為裝載點並開始錄製路線（目前位置）]",
		"button[0.5,4.1;8,0.8;dump;設為傾倒點（結束錄製）]",
		"button[0.5,5.0;3.9,0.8;start;啟動（啟動後請下車）]",
		"button[4.6,5.0;3.9,0.8;stop;停止]",
		"button[0.5,5.9;3.9,0.8;go;立即出發（不等裝滿）]",
		"button_exit[4.6,5.9;3.9,0.8;ok;關閉]",
		"label[0.5,7.1;裝載點等裝滿 → 沿路線開到傾倒點倒土 → 開回裝載點；前方有人或車會停]",
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
		a.load, a.dump, a.route, a.rec, a.on = round(pos), nil, {round(pos)}, true, false
		msg = "開始錄製：開到倒土的地方"
	elseif fields.dump then
		if not a.rec then msg = "要先設裝載點並開始錄製"
		else
			a.route[#a.route + 1] = round(pos)
			a.dump, a.rec = round(pos), false
			msg = ("路線錄好了（%d 個點）"):format(#a.route)
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
			msg = "已啟動：請下車"
		end
	elseif fields.stop then
		a.on = false
		self.autopilot = nil
		msg = "已停止"
	elseif fields.go then
		if a.on and a.phase == "wait" then a.idx = 2; a.phase = "to_dump"; msg = "出發" end
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
