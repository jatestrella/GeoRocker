-- rockmech/vehicles.lua
-- 載具共用部分：實體註冊（上下車、駕駛、追蹤相機、隨地形傾斜、收回成物品）、零件、碎石的取放。
-- 各種車在自己的檔案：vehicle_excavator.lua（挖土機）、vehicle_truck.lua（卡車；有車斗的車共用部分）、
-- vehicle_haul.lua（礦卡）、vehicle_dozer.lua（推土機）、vehicle_jumbo.lua（鑽堡、裝藥台車）、vehicle_drillrig.lua（露天鑽機）；
-- 駕駛艙 HUD、後照鏡與倒車攝影機畫面在 vehicle_views.lua。
-- 只處理碎石：完整岩石要先爆破或用魔杖弄碎（爆破 → 裝載 → 運輸）。
-- 操作：右鍵上車；駕駛中 Shift 下車，W/S 前進後退，A/D 轉向；Z 切換追蹤相機（從車子後上方看作動）。
-- 駕駛的相機在車頂（挖土機：駕駛艙頂）前緣。不在車上時左鍵：收回成物品（車上的碎石換成碎石物品，8 級 = 1 個）
-- 碎石的增減用 set_node／remove_node，照常觸發開挖記錄、支撐判定；動過的碎石再依安息角流動。

local NLEV = rockmech.RUBBLE_LEVELS
local collapse = rockmech.collapse

local V = {NLEV = NLEV}
rockmech.vehicles = V

-- 各種車的設定（各車的檔案用 V.register 加入）。
-- desc、color；cap：載量（級）；speed：m/s；half：碰撞箱半邊長；lat：車頭外一排的橫向位置（相對中心）；
-- eye_up／eye_fwd／eye_side：相機在車身中心上方、沿視線往前、往右（負 = 左）的距離（m）；mirror：右後照鏡位置（車身座標，左鏡 x 取負）；
-- rearcam：倒車攝影機位置；tilt：外觀隨地形傾斜時量地面的位置（前、後端的 z，左右兩側的 z 與 ±x）；
-- rear：車身伸出碰撞箱後方到 z = −rear（選取框跟著加長；tail_lat／tail_dy 是倒車、轉彎檢查點，見 V.tail_guard）；top：碰撞箱上緣（預設 half，車身不是立方體時用）；
-- overhangs：伸出碰撞箱那段擋人的範圍（見 V.overhang_push）；overhangs_now(self)：會動的擋人範圍（挖土機鏟斗）；max_grade：最大爬坡角（rad；行進方向整台車長的平均坡度）；
-- top_speed／accel：直線前進時從 speed 加速到 top_speed（m/s、m/s²）；stepheight（預設 1.1）；look_limit：第一人稱視線離車頭最多幾度（rad，省略 → 不限）；inv_image、item_desc：物品。
-- 各車的行為（都可省略）：parts（零件清單）、on_spawn(self)（零件生成後）、on_load(self, data)／on_save(self, data)、
-- refresh(self)（外觀與名牌）、hud(self)（HUD 加的文字）、can_turn(self, pos, yaw, yaw2)、
-- move(self, ctx)（設定 ctx.speed）、step(self, ctx)（設定速度之後）、action(self, ctx)（作業鍵）。
-- ctx：obj、pos、yaw、dir（車頭方向）、s（對齊格線的方向）、fwd、dtime、d（駕駛）、ctrl、speed
local TYPES = {}
V.TYPES = TYPES
local TURN_RATE = 1.6        -- rad/s

-- 駕駛視線：第一人稱相機不受 set_attach 位移影響（遊戲內確認：改位移視角不變），改用 set_eye_offset。
-- 玩家掛在車身中心（腳在中心），相機往上 eye_up、沿視線方向往前 eye_fwd（m）：坐在車頂前緣，
-- 往前看得到自己的車頂前緣與車頭正前方的地面（車身方塊從裡面看不透明，相機不能放進車身）
local EYE_HEIGHT = 1.625
V.EYE_HEIGHT = EYE_HEIGHT
local function eye_offset(def)
	return {x = (def.eye_side or 0) * 10, y = (def.eye_up - EYE_HEIGHT) * 10, z = def.eye_fwd * 10}
end

-- 貼圖（[fill 組合）。cube 的六面：上、下、+X、−X、+Z（車頭：yaw 0 朝 +Z）、−Z
function V.box_tex(c, front)
	local t = ("[fill:16x16:%s"):format(c)
	return {t, t, t, t, front or t, t}
end
-- 物品圖示：32×32 透明底的側面剪影（車頭朝右）。r = {{x, y, w, h, 顏色}, …}，後面的蓋前面的。
-- 下面的 icon_* 把輪子、履帶、斜的手臂加進 r
function V.icon(r)
	local t = {"[fill:32x32:#00000000"}
	for _, q in ipairs(r) do t[#t + 1] = ("^[fill:%dx%d:%d,%d:%s"):format(q[3], q[4], q[1], q[2], q[5]) end
	return table.concat(t)
end
function V.icon_wheel(r, cx, cy, rad)   -- 輪子（切角的方塊近似圓）＋輪轂
	r[#r + 1] = {cx - rad + 1, cy - rad, 2 * rad - 2, 2 * rad, "#1c1c1c"}
	r[#r + 1] = {cx - rad, cy - rad + 1, 2 * rad, 2 * rad - 2, "#1c1c1c"}
	r[#r + 1] = {cx - 1, cy - 1, 2, 2, "#9a9a9a"}
end
function V.icon_track(r, x, y, w, h)   -- 履帶（圓角長條＋負重輪）
	r[#r + 1] = {x + 1, y, w - 2, h, "#2a2a2a"}
	r[#r + 1] = {x, y + 1, w, h - 2, "#2a2a2a"}
	for k = x + 2, x + w - 4, 4 do r[#r + 1] = {k, y + math.floor(h / 2) - 1, 2, 2, "#5a5a5a"} end
end
function V.icon_line(r, x0, y0, x1, y1, w, c)   -- 斜的手臂：從 (x0, y0) 到 (x1, y1)、粗 w
	local n = math.max(math.abs(x1 - x0), math.abs(y1 - y0), 1)
	for i = 0, n do
		r[#r + 1] = {math.floor(x0 + (x1 - x0) * i / n + 0.5), math.floor(y0 + (y1 - y0) * i / n + 0.5), w, w, c}
	end
end
V.TRACK = "[fill:16x16:#2a2a2a^[fill:16x2:0,0:#454545^[fill:16x2:0,14:#454545^[fill:2x12:3,2:#383838^[fill:2x12:9,2:#383838"

-- 零件：掛在車身上的 cube 實體。外觀都由零件組成，車身本體全透明
local CLEAR = "[fill:1x1:#00000000"
local PART = "rockmech:vehicle_part"
V.CLEAR, V.PART = CLEAR, PART
core.register_entity(PART, {
	initial_properties = {
		physical = false, collide_with_objects = false, pointable = false, static_save = false,
		visual = "cube", textures = V.box_tex("#808080"), backface_culling = true,
	},
	-- 沒有掛在載具上的零件自己消失：載具卸載、重新載入或被收起來時，引擎可能先把零件拆下來
	-- （載具就找不到它們），留在原地像壞掉、重疊的車。每 0.5 s 檢查一次（生成時同一步就掛上去了）
	on_step = function(self, dtime)
		self.t_check = (self.t_check or 0) + dtime
		if self.t_check < 0.5 then return end
		self.t_check = 0
		if not self.object:get_attach() then self.object:remove() end
	end,
})
local function remove_parts(self)
	for _, c in ipairs(self.object:get_children()) do
		local e = c:get_luaentity()
		if e and e.name == PART then c:remove() end
	end
	-- 已經被拆下來（不在 children 裡）的也一起清掉
	for _, o in ipairs(self.part_list or {}) do
		if o:get_pos() then o:remove() end
	end
	self.part_list = nil
end
-- parts：{id（可選，存到 self.parts[id]）, pos（m）, size, tex, rot（可選）}
local function spawn_parts(self, parts)
	remove_parts(self)
	self.parts, self.part_list = {}, {}
	for _, pt in ipairs(parts) do
		local o = core.add_entity(self.object:get_pos(), PART)
		if o then
			o:set_properties({visual_size = pt.size, textures = pt.tex})
			o:set_attach(self.object, "", {x = pt.pos.x * 10, y = pt.pos.y * 10, z = pt.pos.z * 10}, pt.rot or {x = 0, y = 0, z = 0})
			if pt.id then self.parts[pt.id] = o end
			self.part_list[#self.part_list + 1] = o
		end
	end
end

-- 伸出碰撞箱那段（車斗、鏟刀、車尾、鏟斗）擋人：玩家的碰撞只認碰撞箱（不轉、也不認掛在車上的東西；
-- 而且只看中心在玩家附近約 3.4 m 內的物件，礦卡這種大車的邊緣離中心太遠也擋不住），
-- 所以由伺服器每一步檢查，站進那段的玩家往最近的開放側推出去（不往車身那側推）。
-- regions：車身座標的長方體 {x0, x1, z0, z1, y0, y1, body = "z0"／"z1"（貼著車身的那側，可省略）}
local PLAYER_R, PLAYER_H = 0.3, 1.7
-- 玩家腳底 p（世界座標）在車身 pos、朝向 yaw 時要推到哪裡（世界座標）；不在任何一段裡回傳 nil
function V.overhang_push(regions, pos, yaw, p)
	local c, sn = math.cos(yaw), math.sin(yaw)
	local dx, dz = p.x - pos.x, p.z - pos.z
	local lx, lz, ly = dx * c + dz * sn, -dx * sn + dz * c, p.y - pos.y
	for _, r in ipairs(regions) do
		local m = PLAYER_R
		if lx > r.x0 - m and lx < r.x1 + m and lz > r.z0 - m and lz < r.z1 + m and ly + PLAYER_H > r.y0 and ly < r.y1 then
			-- 往最近的開放側推（左、右、不貼車身的前或後）；剛好在上緣附近 → 站上去
			local best, ox, oz = math.huge, 0, 0
			local function try(d, x, z) if math.abs(d) < best then best, ox, oz = math.abs(d), x, z end end
			try(r.x0 - m - lx, r.x0 - m - lx, 0)
			try(r.x1 + m - lx, r.x1 + m - lx, 0)
			if r.body ~= "z0" then try(r.z0 - m - lz, 0, r.z0 - m - lz) end
			if r.body ~= "z1" then try(r.z1 + m - lz, 0, r.z1 + m - lz) end
			if r.y1 - ly < math.min(best, 0.6) then
				return {x = p.x, y = pos.y + r.y1, z = p.z}
			end
			return {x = p.x + ox * c - oz * sn, y = p.y, z = p.z + ox * sn + oz * c}
		end
	end
end
local function push_players(self, pos, yaw, def, regions)
	local reach = (def.rear or def.half) + 8
	for _, pl in ipairs(core.get_connected_players()) do
		if not pl:get_attach() then
			local p = pl:get_pos()
			if math.abs(p.x - pos.x) < reach and math.abs(p.z - pos.z) < reach then
				local q = V.overhang_push(regions, pos, yaw, p)
				if q then pl:set_pos(q) end
			end
		end
	end
end

-- (x, z) 這一欄、y_from 往下 depth 格內最上面的實心面高度（不滿格碎石照級數），找不到回傳 nil
local function ground_top(x, y_from, z, depth)
	local xi, zi = math.floor(x + 0.5), math.floor(z + 0.5)
	for y = math.floor(y_from + 0.5), math.floor(y_from + 0.5) - depth, -1 do
		local n = core.get_node({x = xi, y = y, z = zi}).name
		local nd = core.registered_nodes[n]
		if n ~= "air" and (not nd or nd.walkable ~= false) then
			local k = rockmech.rubble_level[n]
			return k and (y - 0.5 + k / NLEV) or (y + 0.5)
		end
	end
end

-- 隨地形傾斜：量前後軸（履帶前後端）、左右輪（履帶）下方的地面（def.tilt），算俯仰（前高為正）
-- 與側傾（右側低為正，set_rotation 是右手 Z-X-Y：X 正 = 抬頭、Z 正 = 向右傾）。只有外觀傾斜，碰撞箱維持水平
-- 爬坡：行進方向上（f = 1 前進、−1 倒車）從後端接地點到前端前方 1 m 的平均坡度（rad，上坡為正）。
-- 沿車身每 0.5 m 量地面高度、最小平方法擬合斜率（方塊地形是台階，只比兩點會差一整階）；
-- 量整台車長的平均，單一一格台階對長車只是小坡；地面在車底往上 1.6 m 以內找
local function travel_grade(p, yaw, def, f)
	local t = def.tilt
	local c, sn = math.cos(yaw), math.sin(yaw)
	local za, zb = t.rear, t.front + 1
	if f < 0 then za, zb = t.rear - 1, t.front end
	local from = p.y - def.half + 1.6
	local n, sz, sh, szz, szh = 0, 0, 0, 0, 0
	for z = za, zb, 0.5 do
		local h = ground_top(p.x - z * sn, from, p.z + z * c, 10)
		if h then
			n, sz, sh, szz, szh = n + 1, sz + z, sh + h, szz + z * z, szh + z * h
		end
	end
	local var = n * szz - sz * sz
	if n < 3 or var <= 0 then return 0 end
	return math.atan(f * (n * szh - sz * sh) / var)
end

local function ground_tilt(p, yaw, def)
	local TILT_AXLES = def.tilt
	local c, sn = math.cos(yaw), math.sin(yaw)
	local function at(lx, lz)
		return p.x + lx * c - lz * sn, p.z + lx * sn + lz * c
	end
	local from, depth = p.y + 0.5, 8   -- 1:1 坡上車尾量測點的地面可比車身中心低 5 m 以上
	local fx, fz = at(0, TILT_AXLES.front)
	local rx, rz = at(0, TILT_AXLES.rear)
	local lx, lz = at(-TILT_AXLES.side_x, TILT_AXLES.side_z)
	local qx, qz = at(TILT_AXLES.side_x, TILT_AXLES.side_z)
	local hf, hr = ground_top(fx, from, fz, depth), ground_top(rx, from, rz, depth)
	local hl, hq = ground_top(lx, from, lz, depth), ground_top(qx, from, qz, depth)
	local pitch, roll = 0, 0
	if hf and hr then pitch = math.atan((hf - hr) / (TILT_AXLES.front - TILT_AXLES.rear)) end
	if hl and hq then roll = math.atan((hl - hq) / (2 * TILT_AXLES.side_x)) end
	local lim = math.rad(25)
	return math.max(-lim, math.min(lim, pitch)), math.max(-lim, math.min(lim, roll))
end

function V.lerp(a, b, t) return {x = a.x + (b.x - a.x) * t, y = a.y + (b.y - a.y) * t, z = a.z + (b.z - a.z) * t} end
local atan2 = math.atan2 or math.atan
V.atan2 = atan2
-- 繞垂直軸轉 ψ（rad）：+Z 轉 ψ 後指向 (sin ψ, cos ψ)，與掛載旋轉的 Y 角同一個方向（見 seg_attach）。
-- 挖土機上部結構迴轉：上部座標 → 車身座標；實體 yaw 對應 h2v(·, −yaw)
local function h2v(p, psi)
	local c, sn = math.cos(psi), math.sin(psi)
	return {x = p.x * c + p.z * sn, y = p.y, z = -p.x * sn + p.z * c}
end
V.h2v = h2v
function V.v2h(p, psi)
	local c, sn = math.cos(psi), math.sin(psi)
	return {x = p.x * c - p.z * sn, y = p.y, z = p.x * sn + p.z * c}
end
-- 角度內插（走最短的方向）
function V.lerp_angle(a, b, t)
	local d = (b - a + math.pi) % (2 * math.pi) - math.pi
	return a + d * t
end
-- 長方體零件（長軸是自身 +Y）擺在 a → c 之間。
-- 掛載旋轉：左手座標、外旋 X → Y → Z（度）。+Y 軸先繞 X 轉 θx、再繞 Y 轉 θy 後指向
-- (sin θx·sin θy, cos θx, sin θx·cos θy)：θx = acos(v.y)、θy = atan2(v.x, v.z)
function V.seg_attach(self, o, a, c)
	if not o then return end
	local v = {x = c.x - a.x, y = c.y - a.y, z = c.z - a.z}
	local len = math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
	if len < 1e-6 then return end
	local tx = math.deg(math.acos(math.max(-1, math.min(1, v.y / len))))
	local ty = math.deg(atan2(v.x, v.z))
	o:set_attach(self.object, "", {x = (a.x + c.x) * 5, y = (a.y + c.y) * 5, z = (a.z + c.z) * 5}, {x = tx, y = ty, z = 0})
end

-- 世界座標 → 車身座標（車頭 +Z；含隨地形傾斜：實體旋轉依序是側傾 Z、俯仰 X、偏航 Y，這裡反過來解）。
-- 挖臂在這個座標裡解，車身傾斜時挖斗照樣落在目標上
function V.to_local(self, wp)
	local p, yaw = self.object:get_pos(), self.object:get_yaw()
	local dx, dy, dz = wp.x - p.x, wp.y - p.y, wp.z - p.z
	local c, sn = math.cos(yaw), math.sin(yaw)
	local x, y, z = dx * c + dz * sn, dy, -dx * sn + dz * c
	local cp, sp = math.cos(self.pitch or 0), math.sin(self.pitch or 0)
	y, z = y * cp - z * sp, y * sp + z * cp
	local cr, sr = math.cos(self.roll or 0), math.sin(self.roll or 0)
	return {x = x * cr - y * sr, y = x * sr + y * cr, z = z}
end
-- 車身座標 → 世界座標（to_local 的反向）
function V.to_world(self, lp)
	local p, yaw = self.object:get_pos(), self.object:get_yaw()
	local cr, sr = math.cos(self.roll or 0), math.sin(self.roll or 0)
	local x, y, z = lp.x * cr + lp.y * sr, -lp.x * sr + lp.y * cr, lp.z
	local cp, sp = math.cos(self.pitch or 0), math.sin(self.pitch or 0)
	y, z = y * cp + z * sp, -y * sp + z * cp
	local c, sn = math.cos(yaw), math.sin(yaw)
	return {x = p.x + x * c - z * sn, y = p.y + y, z = p.z + x * sn + z * c}
end

-- 追蹤相機：Z 鍵時把駕駛掛到一個看不見、跟著車子的點上（Luanti 內建第三人稱拉不遠）。
-- 位置：車尾後 3.5 m、車頂上方 4 m（眼睛）
local CHASE = "rockmech:chasecam"
core.register_entity(CHASE, {
	initial_properties = {
		physical = false, collide_with_objects = false, pointable = false, static_save = false,
		visual = "sprite", textures = {"[fill:1x1:#00000000"}, use_texture_alpha = true,
	},
	on_activate = function(self)
		core.after(1, function()
			if self.object:get_pos() and #self.object:get_children() == 0 then self.object:remove() end
		end)
	end,
})
local function chase_pos(self, def)
	local p, yaw = self.object:get_pos(), self.object:get_yaw()
	local back = (def.rear or def.half) + 3.5   -- 車尾後 3.5 m
	local up = def.half + 4.0                 -- 車頂上方 4 m（眼睛）
	return {x = p.x + math.sin(yaw) * back, y = p.y + up - EYE_HEIGHT, z = p.z - math.cos(yaw) * back}
end

function V.passable(name)
	local def = core.registered_nodes[name]
	return name == "air" or (def and def.walkable == false)
end
local passable = V.passable

-- 車頭方向（連續）與對齊格線的方向
local function dirs(yaw)
	local dx, dz = -math.sin(yaw), math.cos(yaw)
	local sx, sz
	if math.abs(dx) > math.abs(dz) then sx, sz = dx > 0 and 1 or -1, 0 else sx, sz = 0, dz > 0 and 1 or -1 end
	return {x = dx, z = dz}, {x = sx, z = sz}
end
V.dirs = dirs

-- 車頭（f = 1）或車尾（f = −1）外側、距車身中心 dist 的一排（地面層 + 上方 h−1 層）。
-- lat：橫向位置（預設 2 格寬 {−0.5, 0.5}）
function V.face_cells(pos, s, f, dist, y0, h, lat)
	local px, pz = -s.z, s.x
	local cx, cz = pos.x + f * s.x * dist, pos.z + f * s.z * dist
	local cells = {}
	for _, l in ipairs(lat or {-0.5, 0.5}) do
		local x = math.floor(cx + px * l + 0.5)
		local z = math.floor(cz + pz * l + 0.5)
		for dy = 0, h - 1 do cells[#cells + 1] = {x = x, y = y0 + dy, z = z} end
	end
	return cells
end

-- 地面層（車身最下面那層格子的高程）。half：碰撞箱半邊長（預設 1）
function V.ground_y(pos, half) return math.floor(pos.y - (half or 1) + 0.5) end

-- 從 cell 取走最多 want 級碎石。回傳 取走的級數, 碎石種類
function V.take_rubble(cell, want)
	local name = core.get_node(cell).name
	local k = rockmech.rubble_level[name]
	if not k or want <= 0 then return 0 end
	local base = rockmech.rubble_base[name]
	local t = math.min(k, want)
	local rest = rockmech.rubble_with_level(base, k - t)
	if rest then core.swap_node(cell, {name = rest}) else core.remove_node(cell) end
	collapse.check_cell({x = cell.x, y = cell.y + 1, z = cell.z})   -- 上方的碎石往下掉
	return t, base
end

-- 在 (x, z) 這一欄、從 ytop 往下找落點，倒 a 級 base 碎石；滿了往上堆（最多 max_h 格，預設 8）。
-- placed（可選）：收集倒下的格子，不立即做安息角流動（推土機推著的那堆）。回傳倒不下的級數
local function deposit_column(x, z, ytop, base, a, max_h, placed)
	local y = ytop
	for _ = 1, 8 do
		if not passable(core.get_node({x = x, y = y - 1, z = z}).name) then break end
		y = y - 1
	end
	for _ = 1, max_h or 8 do
		if a <= 0 then break end
		local p = {x = x, y = y, z = z}
		local n = core.get_node(p).name
		local k = rockmech.rubble_level[n]
		if passable(n) then
			local put = math.min(NLEV, a)
			core.set_node(p, {name = rockmech.rubble_with_level(base, put)})
			a = a - put
			if placed then placed[#placed + 1] = p else collapse.check_cell(p) end
		elseif k and k < NLEV and rockmech.rubble_base[n] == base then
			local put = math.min(NLEV - k, a)
			core.swap_node(p, {name = rockmech.rubble_with_level(base, k + put)})
			a = a - put
			if placed then placed[#placed + 1] = p else collapse.check_cell(p) end
		end
		y = y + 1
	end
	return a
end
V.deposit_column = deposit_column

local function load_total(self)
	local t = 0
	for _, v in pairs(self.load) do t = t + v end
	return t
end
V.load_total = load_total

-- 車輛的自重 (t)，車種沒列的用 20
V.MASS = {truck = 15, haul = 70, bulktruck = 30, dozer = 20, excavator = 20, excavator_big = 100,
	jumbo = 30, charger = 20, drillrig = 25}

-- 接地壓力 (kPa) = (自重 + 車上的碎石) / 兩條輪跡的面積（各寬 1 m、長 = 車長），g 取 10。
-- 重量都在輪子或履帶下面，不能平均到整個車身
function V.ground_pressure(self, def, kind)
	local kn = (V.MASS[kind] or 20) * 10 + load_total(self) / NLEV * rockmech.cfg.failure.gamma_other
	return kn / (2 * (def.half + (def.rear or def.half)))
end

-- 車頭（倒車時車尾）的左右兩條輪跡壓到碎石：每一格每趟判定一次，碎石只往外側擠（往前後流會把車轍填回去）。
-- 車速快時一步走超過 1 m，沿著這一步的路徑逐格補上
function V.press_rubble(self, kind, def, pos, dir, f)
	local j = f > 0 and def.half or -(def.rear or def.half)
	local cx, cz = pos.x + dir.x * j, pos.z + dir.z * j
	local gy = math.floor(pos.y - def.half + 0.5)
	local q = V.ground_pressure(self, def, kind)
	self.pressed = self.pressed or {}
	local last = self.press_at or {x = cx, z = cz}
	self.press_at = {x = cx, z = cz}
	local steps = math.min(8, math.max(1, math.ceil(math.max(math.abs(cx - last.x), math.abs(cz - last.z)))))
	for t = 1, steps do
		local px, pz = last.x + (cx - last.x) * t / steps, last.z + (cz - last.z) * t / steps
		local lat = def.lat or {-0.5, 0.5}
		for _, l in ipairs({lat[1], lat[#lat]}) do
			local x, z = math.floor(px + dir.z * l + 0.5), math.floor(pz - dir.x * l + 0.5)
			local key = x + 65536 * z
			if self.pressed[l] ~= key then
				self.pressed[l] = key
				-- 車子傾斜時，車頭、車尾的地面和車身中心差好幾格
				for y = gy + 3, gy - 4, -1 do
					local p = {x = x, y = y, z = z}
					local name = core.get_node(p).name
					if rockmech.rubble_level[name] then
						rockmech.collapse.squeeze(p, q, {x = dir.z * l, z = -dir.x * l})
						break
					end
					if not V.passable(name) then break end
				end
			end
		end
	end
end

-- 倒出車上的碎石：平均分到 cells 所在的欄（每欄往上最多堆 8 格），之後依安息角流開
function V.dump_to_ground(self, cells, ytop)
	for base, lv in pairs(self.load) do
		local rest = 0
		for i, c in ipairs(cells) do
			local share = math.ceil(lv / (#cells - i + 1))
			lv = lv - share
			rest = rest + deposit_column(c.x, c.z, ytop, base, share)
		end
		self.load[base] = rest > 0 and rest or nil
	end
end

-- 車身在 pos、朝向 yaw 時，車身座標的長方形範圍 x0..x1、z0..z1（高度在車底到車頂之間）裡有沒有
-- 沒在車上的玩家（半徑 0.3）或別台車（碰撞箱半邊長當半徑）。碰撞箱只蓋到車身那段，
-- 伸出去的車斗、鏟刀、車尾移動前用這個檢查人和車（方塊另外檢查）
-- 長車尾（車身座標 z −rear..−half：卡車車斗、鑽堡後段）不在碰撞箱裡，倒車、轉彎前自己檢查。
-- def.tail_lat／tail_dy：檢查點的橫向位置與離車底高度（更低的小台階、碎石讓碰撞箱自己爬）。
-- 回傳車尾卡進實心方塊的檢查點數
local function tail_overlap(p, yaw, def)
	local c, sn = math.cos(yaw), math.sin(yaw)
	local bottom = p.y - def.half
	local n_hit = 0
	for lz = -def.rear + 0.05, -def.half - 0.25, 0.5 do   -- 從車尾最末端開始
		for _, lx in ipairs(def.tail_lat) do
			local wx, wz = p.x + lx * c - lz * sn, p.z + lx * sn + lz * c
			for _, dy in ipairs(def.tail_dy) do
				local n = core.get_node({x = math.floor(wx + 0.5), y = math.floor(bottom + dy + 0.5), z = math.floor(wz + 0.5)}).name
				local nd = core.registered_nodes[n]
				if n ~= "air" and (not nd or nd.walkable ~= false) then n_hit = n_hit + 1 end
			end
		end
	end
	return n_hit
end
-- 從 (p, yaw) 動到 (p2, yaw2) 會不會讓車尾撞得更多（已經卡住時，不會更糟的動作照樣允許，才能脫困）
local function tail_blocked(p, yaw, p2, yaw2, def)
	local after = tail_overlap(p2, yaw2, def)
	if after == 0 then return false end
	return after > tail_overlap(p, yaw, def)
end
-- 轉彎：車尾會撞到方塊、人或車就不轉
function V.tail_can_turn(self, pos, yaw, yaw2, def)
	return not (tail_blocked(pos, yaw, pos, yaw2, def)
		or V.objects_in(self, pos, yaw2, -def.half, def.half, -def.rear, -def.half))
end
-- 倒車：看後面一點（全速 0.1 s 走的距離）；前進時車尾跟著車頭走過的路，不必檢查。
-- 伺服器卡頓時一步會退很遠、預判擋不住：倒車後車尾撞得比上一步多，就退回上一步的位置
function V.tail_guard(self, def, ctx)
	local pos, dir = ctx.pos, ctx.dir
	if self.tail_safe then
		local safe = self.tail_safe
		self.tail_safe = nil
		if tail_overlap(pos, ctx.yaw, def) > safe.n then
			ctx.obj:set_pos(safe.pos)
			ctx.speed = 0
			return
		end
	end
	if ctx.speed >= 0 then return end
	local la = ctx.speed * 0.1
	local p2 = {x = pos.x + dir.x * la, y = pos.y, z = pos.z + dir.z * la}
	if tail_blocked(pos, ctx.yaw, p2, ctx.yaw, def)
			or V.objects_in(self, p2, ctx.yaw, -def.half, def.half, -def.rear, -def.half) then
		ctx.speed = 0
	else
		self.tail_safe = {pos = vector.copy(pos), n = tail_overlap(pos, ctx.yaw, def)}
	end
end

function V.objects_in(self, pos, yaw, x0, x1, z0, z1)
	local def = TYPES[self.vkind]
	local c, sn = math.cos(yaw), math.sin(yaw)
	local cx, cz = (x0 + x1) / 2, (z0 + z1) / 2
	local center = {x = pos.x + cx * c - cz * sn, y = pos.y, z = pos.z + cx * sn + cz * c}
	local r = math.sqrt(((x1 - x0) / 2) ^ 2 + ((z1 - z0) / 2) ^ 2) + 3
	local bottom, top = pos.y - def.half, pos.y + (def.top or def.half)
	for _, o in ipairs(core.get_objects_inside_radius(center, r)) do
		local e = o:get_luaentity()
		local p, m, lo, hi = o:get_pos()
		if o:is_player() and not o:get_attach() then
			m, lo, hi = 0.3, p.y, p.y + 1.8
		elseif e and e ~= self and e.vkind and TYPES[e.vkind] then
			local od = TYPES[e.vkind]
			m, lo, hi = od.half, p.y - od.half, p.y + (od.top or od.half)
		end
		if m and hi > bottom and lo < top then
			local dx, dz = p.x - pos.x, p.z - pos.z
			local lx, lz = dx * c + dz * sn, -dx * sn + dz * c
			if lx > x0 - m and lx < x1 + m and lz > z0 - m and lz < z1 + m then return true end
		end
	end
	return false
end

-- 載的碎石裡最多的那種（給車斗、鏟斗裡的碎石塊用貼圖）：回傳 總級數, 種類
function V.load_mix(self)
	local total, best, bl = 0, nil, 0
	for base, lv in pairs(self.load or {}) do
		total = total + lv
		if lv > bl then best, bl = base, lv end
	end
	return total, best
end
-- 碎石種類的貼圖（給碎石塊零件）
function V.rubble_tex(base)
	local nd = core.registered_nodes[base]
	local t = nd and nd.tiles and nd.tiles[1]
	return type(t) == "table" and t.name or t or "[fill:16x16:#6a6058"
end

dofile(rockmech.modpath .. "/vehicle_views.lua")
local hud_clear, update_hud, update_mirrors = V.hud_clear, V.update_hud, V.update_mirrors

-- 車上存放：def.store = {{物品, 容量, 名稱}, …}，self.store[物品] = 數量（跟著車存檔，收車時還給玩家）。
-- V.open_store 打開存放畫面：「裝滿」從背包拿（創造模式直接裝滿）、「卸下」放回背包；作業時用 V.store_take 消耗
function V.store_count(self, item) return self.store[item] or 0 end
function V.store_take(self, item, n)
	local have = self.store[item] or 0
	n = math.min(n, have)
	self.store[item] = have - n
	return n
end
local store_open = {}
local function store_formspec(self)
	local list = TYPES[self.vkind].store
	local fs = {("formspec_version[6]size[8.2,%.1f]"):format(1.5 + #list * 1.2)}
	for i, s in ipairs(list) do
		local y = 0.4 + (i - 1) * 1.2
		fs[#fs + 1] = ("item_image[0.4,%.1f;0.9,0.9;%s]label[1.5,%.2f;%s　%d / %d]button[4.5,%.1f;1.6,0.9;fill_%d;裝滿]button[6.2,%.1f;1.6,0.9;out_%d;卸下]")
			:format(y, s[1], y + 0.45, s[3], V.store_count(self, s[1]), s[2], y, i, y, i)
	end
	fs[#fs + 1] = ("button_exit[5.8,%.1f;2,0.7;ok;完成]"):format(0.5 + #list * 1.2)
	return table.concat(fs)
end
function V.open_store(self, player)
	store_open[player:get_player_name()] = self
	core.show_formspec(player:get_player_name(), "rockmech:store", store_formspec(self))
end
core.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= "rockmech:store" then return end
	local name = player:get_player_name()
	local self = store_open[name]
	if not self or not self.object:get_pos() then return true end
	local inv = player:get_inventory()
	for i, s in ipairs(TYPES[self.vkind].store) do
		local item, cap = s[1], s[2]
		local have = V.store_count(self, item)
		if fields["fill_" .. i] and have < cap then
			local got = core.is_creative_enabled(name) and cap - have
				or inv:remove_item("main", ItemStack(item .. " " .. (cap - have))):get_count()
			self.store[item] = have + got
		elseif fields["out_" .. i] and have > 0 then
			self.store[item] = inv:add_item("main", ItemStack(item .. " " .. have)):get_count()
		end
	end
	if fields.quit or fields.ok then store_open[name] = nil
	else core.show_formspec(name, "rockmech:store", store_formspec(self)) end
	update_hud(self)
	return true
end)

-- 駕駛的姿勢（有 player_api 時）：上車坐著、下車恢復
local function set_seated(player, on)
	if not player then return end
	-- 開車時收起快捷欄與手上拿的東西（不擋駕駛艙畫面），下車再顯示
	player:hud_set_flags({hotbar = not on, wielditem = not on})
	if not player_api then return end
	local name = player:get_player_name()
	player_api.player_attached[name] = on or nil
	player_api.set_animation(player, on and "sit" or "stand")
end

local function drop_chase(self)
	if self.chase then
		if self.chase:get_pos() then self.chase:remove() end
		self.chase = nil
	end
end

local function get_off(self)
	local d = self.driver and core.get_player_by_name(self.driver)
	drop_chase(self)
	if d then
		d:set_detach()
		d:set_eye_offset({x = 0, y = 0, z = 0}, {x = 0, y = 0, z = 0})
		d:set_camera({mode = "any"})
		set_seated(d, false)
		hud_clear(self, d)
		-- 放到車身左側外 1 m（不能放進車身或碰撞塊裡，會卡住）
		local p = self.object:get_pos()
		local _, s = dirs(self.object:get_yaw())
		local side = TYPES[self.vkind].half + 1
		core.after(0.1, function()
			if d:get_pos() then d:set_pos({x = p.x - s.z * side, y = p.y + 0.5, z = p.z + s.x * side}) end
		end)
	end
	self.driver = nil
	hud_clear(self, nil)
end

-- 註冊一種車：實體 rockmech:<kind> 與物品 rockmech:<kind>_item
function V.register(kind, def)
	TYPES[kind] = def
	local ename = "rockmech:" .. kind
	core.register_entity(ename, {
		initial_properties = {
			physical = true,
			collide_with_objects = true,   -- 玩家擋得住、車子之間會相撞（只有碰撞箱那段；伸出去的車斗、鏟刀、挖臂不算）
			collisionbox = {-def.half + 0.02, -def.half, -def.half + 0.02, def.half - 0.02, (def.top or def.half) - 0.02, def.half - 0.02},
			selectionbox = def.rear and {-def.half, -def.half, -def.rear, def.half, def.top or def.half, def.half, rotate = true}
				or {-def.half, -def.half, -def.half, def.half, def.top or def.half, def.half},
			visual = "cube",
			-- 外觀都由零件組成：車身不能放大（掛在上面的零件位置與大小會跟著放大），
			-- 用全透明貼圖（不能設 is_visible = false，掛在上面的零件會一起被隱藏）
			visual_size = {x = 1, y = 1, z = 1},
			textures = {CLEAR, CLEAR, CLEAR, CLEAR, CLEAR, CLEAR},
			use_texture_alpha = true,
			backface_culling = true,       -- 從車身裡面往外看是透明的
			stepheight = def.stepheight or 1.1,
			static_save = true,
		},
		vkind = kind,
		on_activate = function(self, staticdata)
			self.load, self.store = {}, {}
			local data = staticdata ~= "" and core.deserialize(staticdata) or nil
			if data then
				self.load = data.load or {}
				self.store = data.store or {}
				if data.yaw then self.object:set_yaw(data.yaw) end
			end
			if def.on_load then def.on_load(self, data or {}) end
			self.object:set_acceleration({x = 0, y = -9.81, z = 0})
			self.object:set_armor_groups({immortal = 1})
			V.refresh(self)
			self.t_act = 0
			if def.parts then
				core.after(0, function()
					if self.object:get_pos() then
						spawn_parts(self, def.parts)
						if def.on_spawn then def.on_spawn(self) end
					end
				end)
			end
		end,
		on_deactivate = function(self)
			remove_parts(self)
			drop_chase(self)
		end,
		get_staticdata = function(self)
			local data = {load = self.load, store = self.store, yaw = self.object:get_yaw()}
			if def.on_save then def.on_save(self, data) end
			return core.serialize(data)
		end,
		on_rightclick = function(self, clicker)
			if not clicker or not clicker:is_player() then return end
			local name = clicker:get_player_name()
			if self.driver == name then get_off(self); return end
			if self.driver then return end
			-- 從別台車直接換過來：先把原本那台的駕駛清掉（否則兩台都聽這個玩家的）
			local parent = clicker:get_attach()
			local pe = parent and parent:get_luaentity()
			if pe and pe ~= self and pe.driver == name then
				hud_clear(pe, clicker)
				pe.driver = nil
			end
			self.driver = name
			clicker:set_attach(self.object, "", {x = 0, y = 0, z = 0}, {x = 0, y = 0, z = 0})
			-- 第三人稱：盡量抬高（上限 y 1.5 m、前後 ±0.5 m），從後上方看得到駕駛艙與手臂
			clicker:set_eye_offset(eye_offset(def), {x = 0, y = 15, z = -5})
			clicker:set_camera({mode = "first"})
			set_seated(clicker, true)
			update_hud(self)
		end,
		on_punch = function(self, puncher)
			if not puncher or not puncher:is_player() or self.driver then return true end
			local inv = puncher:get_inventory()
			local left = inv:add_item("main", ItemStack(ename .. "_item"))
			if not left:is_empty() then core.add_item(self.object:get_pos(), left) end
			for base, lv in pairs(self.load) do
				local n = math.floor(lv / NLEV + 0.5)
				if n > 0 then
					local l2 = inv:add_item("main", ItemStack(base .. " " .. n))
					if not l2:is_empty() then core.add_item(self.object:get_pos(), l2) end
				end
			end
			for item, n in pairs(self.store) do
				if n > 0 then
					local l3 = inv:add_item("main", ItemStack(item .. " " .. n))
					if not l3:is_empty() then core.add_item(self.object:get_pos(), l3) end
				end
			end
			remove_parts(self)
			self.object:remove()
			return true
		end,
		on_step = function(self, dtime)
			local obj = self.object
			local pos = obj:get_pos()
			local yaw = obj:get_yaw()
			local vel = obj:get_velocity()
			-- 零件被引擎拆掉了（見 PART 的 on_step）：每秒檢查一次，少了就整組重新生成
			if self.part_list then
				self.t_parts = (self.t_parts or 0) + dtime
				if self.t_parts >= 1 then
					self.t_parts = 0
					for _, o in ipairs(self.part_list) do
						local par = o:get_pos() and o:get_attach()
						if par ~= obj then
							spawn_parts(self, def.parts)
							if def.on_spawn then def.on_spawn(self) end
							V.refresh(self)
							break
						end
					end
				end
			end
			local d = self.driver and core.get_player_by_name(self.driver)
			if self.driver and not d then self.driver = nil; hud_clear(self, nil) end
			-- 駕駛已經不在這台車上（換到別台、被傳送、死亡等）：不再聽他的
			if d then
				local parent = d:get_attach()
				local pe = parent and parent:get_luaentity()
				if not (pe == self or (self.chase and parent and pe and pe.name == CHASE and pe.vehicle == self)) then
					hud_clear(self, d)
					if not parent then
						d:set_eye_offset({x = 0, y = 0, z = 0}, {x = 0, y = 0, z = 0})
						d:set_camera({mode = "any"})
						set_seated(d, false)
					end
					self.driver, d = nil, nil
				end
			end
			if d then update_mirrors(self, d, dtime) end
			-- 第一人稱視線限制在車頭左右 look_limit 以內（看後面用後照鏡、倒車攝影機）
			if d and def.look_limit and not self.chase then
				local rel = (d:get_look_horizontal() - yaw + math.pi) % (2 * math.pi) - math.pi
				if math.abs(rel) > def.look_limit then
					d:set_look_horizontal(yaw + (rel > 0 and def.look_limit or -def.look_limit))
				end
			end
			local fwd, turn = 0, 0
			-- self.autopilot：沒有駕駛時的控制輸入（測試、指令用），格式同 get_player_control
			local ctrl = d and d:get_player_control() or self.autopilot or {}
			local driven = d or self.autopilot
			if driven then
				if d and ctrl.sneak then get_off(self); return end
				fwd = (ctrl.up and 1 or 0) - (ctrl.down and 1 or 0)
				turn = (ctrl.left and 1 or 0) - (ctrl.right and 1 or 0)
			end
			if turn ~= 0 and def.can_turn and not def.can_turn(self, pos, yaw, yaw + turn * TURN_RATE * dtime) then
				turn = 0
			end
			if turn ~= 0 then
				yaw = yaw + turn * TURN_RATE * dtime
				obj:set_yaw(yaw)
			end
			-- 外觀隨地形傾斜（角度平滑趨近）
			if def.tilt then
				local tp, tr = ground_tilt(pos, yaw, def)
				local k = math.min(1, dtime * 6)
				self.pitch = (self.pitch or 0) + (tp - (self.pitch or 0)) * k
				self.roll = (self.roll or 0) + (tr - (self.roll or 0)) * k
				obj:set_rotation({x = self.pitch, y = yaw, z = self.roll})
			end
			local regions = def.overhangs_now and def.overhangs_now(self) or def.overhangs
			if regions then push_players(self, pos, yaw, def, regions) end
			local dir, s = dirs(yaw)
			if fwd ~= 0 then V.press_rubble(self, kind, def, pos, dir, fwd) end
			-- 直線前進一段時間後慢慢加速到 top_speed；轉彎時減速回 speed，停下、倒車就回到 speed
			local speed = def.speed * fwd
			if def.top_speed then
				local cur = self.cruise or def.speed
				if fwd > 0 and turn == 0 then cur = math.min(def.top_speed, cur + def.accel * dtime)
				elseif fwd > 0 then cur = math.max(def.speed, cur - 4 * dtime)
				else cur = def.speed end
				self.cruise = cur
				if fwd > 0 then speed = cur end
			end
			local ctx = {obj = obj, pos = pos, yaw = yaw, dir = dir, s = s, fwd = fwd, dtime = dtime, d = d, ctrl = ctrl,
				speed = speed}
			-- 爬坡能力：上坡超過最大爬坡角就上不去；坡上越陡越慢（到最大爬坡角剩 30%）
			local steep
			if def.max_grade and fwd ~= 0 then
				local g = travel_grade(pos, yaw, def, fwd)
				if g > def.max_grade then
					ctx.speed, ctx.fwd = 0, 0
					steep = ("坡太陡（%d° > %d°）"):format(math.floor(math.deg(g) + 0.5), math.floor(math.deg(def.max_grade) + 0.5))
				elseif g > 0 then
					ctx.speed = ctx.speed * (1 - 0.7 * g / def.max_grade)
				end
			end
			if steep ~= self.steep then self.steep = steep; update_hud(self) end
			if def.move then def.move(self, ctx) end
			obj:set_velocity({x = dir.x * ctx.speed, y = vel.y, z = dir.z * ctx.speed})
			-- HUD 時速（每 5 km/h 更新一次）
			if def.top_speed then
				local kmh = math.floor(math.abs(ctx.speed) * 3.6 / 5 + 0.5) * 5
				if kmh ~= self.kmh then self.kmh = kmh; update_hud(self) end
			end
			if def.step then def.step(self, ctx) end
			-- Z（zoom 鍵）：切換追蹤相機（駕駛掛到車子後上方的點上）／車頂第一人稱
			if d then
				if ctrl.zoom and not self.zoom_held then
					if self.chase then
						drop_chase(self)
						d:set_detach()
						d:set_attach(obj, "", {x = 0, y = 0, z = 0}, {x = 0, y = 0, z = 0})
						d:set_eye_offset(eye_offset(def), {x = 0, y = 15, z = -5})
					else
						local c = core.add_entity(chase_pos(self, def), CHASE)
						if c then
							c:get_luaentity().vehicle = self
							self.chase = c
							d:set_detach()
							d:set_attach(c, "", {x = 0, y = 0, z = 0}, {x = 0, y = 0, z = 0})
							d:set_eye_offset({x = 0, y = 0, z = 0}, {x = 0, y = 0, z = 0})
						end
					end
					d:set_camera({mode = "first"})
					set_seated(d, true)
					update_hud(self)   -- 追蹤相機時收起駕駛艙框與後照鏡，回到車上再顯示
				end
				self.zoom_held = ctrl.zoom
			end
			-- 追蹤相機跟著車子
			if self.chase then
				if self.chase:get_pos() and d then self.chase:move_to(chase_pos(self, def), true)
				else drop_chase(self) end
			end
			-- 作業鍵（防連按：各車自己設 self.t_act）
			self.t_act = self.t_act - dtime
			if driven and self.t_act <= 0 and def.action then def.action(self, ctx) end
		end,
	})
	core.register_craftitem(ename .. "_item", {
		description = def.desc .. "\n" .. def.item_desc,
		inventory_image = def.inv_image,
		stack_max = 1,
		on_place = function(itemstack, placer, pointed)
			if pointed.type ~= "node" then return itemstack end
			local a = pointed.above
			local odd = (def.half * 2) % 2 == 1
			local off = odd and 0 or 0.5
			local obj = core.add_entity({x = a.x + off, y = a.y - 0.5 + def.half, z = a.z + off}, ename)
			if obj and placer then obj:set_yaw(placer:get_look_horizontal()) end
			if not core.is_creative_enabled(placer and placer:get_player_name() or "") then itemstack:take_item() end
			return itemstack
		end,
	})
end

dofile(rockmech.modpath .. "/vehicle_excavator.lua")
dofile(rockmech.modpath .. "/vehicle_ahs.lua")
dofile(rockmech.modpath .. "/vehicle_truck.lua")
dofile(rockmech.modpath .. "/vehicle_haul.lua")
dofile(rockmech.modpath .. "/vehicle_dozer.lua")
dofile(rockmech.modpath .. "/vehicle_jumbo.lua")
dofile(rockmech.modpath .. "/vehicle_drillrig.lua")
dofile(rockmech.modpath .. "/vehicle_bulktruck.lua")
