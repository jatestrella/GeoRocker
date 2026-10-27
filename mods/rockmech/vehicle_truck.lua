-- rockmech/vehicle_truck.lua
-- 有車斗的車（hauler）共用的車斗、倒土、車斗段碰撞，與卡車（十輪砂石車）。由 vehicles.lua 載入。
--   空白鍵：車斗以後端下緣為軸抬起、把碎石倒在車尾再放下；名牌與車斗裡的碎石顯示載量。
--   碰撞箱是駕駛艙那段（half），車斗那段（往後到 −rear）倒車、轉彎前自己檢查。挖土機可以倒進車斗

local V = rockmech.vehicles
local TYPES, NLEV = V.TYPES, V.NLEV
local box_tex, load_total, update_hud = V.box_tex, V.load_total, V.update_hud

local TIP_ANGLE, TIP_UP, TIP_HOLD, TIP_DOWN = math.rad(50), 1.0, 0.4, 0.8   -- 車斗抬起
local TIP_TOTAL = TIP_UP + TIP_HOLD + TIP_DOWN
local BED_T = 0.1   -- 車斗鋼板厚度

-- 車斗與裡面的碎石：抬起角度 alpha（rad，前端往上）。掛載旋轉繞 X 轉 θx 時 +Z → (0, −sin θx, cos θx)，
-- 所以前端往上 alpha 用 θx = −alpha；相對軸心的點 (y, z) → (y cos α + z sin α, −y sin α + z cos α)。
-- 鋼板自己的傾角 rot（度，θx 同號：正 = 前端往下，例如礦卡往車尾上翹的尾段底板）疊加上去
local function place_bed(self, alpha)
	local parts = self.parts
	if not parts then return end
	local def = TYPES[self.vkind]
	local bed = def.bed
	local ca, sa = math.cos(alpha), math.sin(alpha)
	local function put(o, rel, rot)
		if not o then return end
		local y = bed.hinge.y + rel.y * ca + rel.z * sa
		local z = bed.hinge.z - rel.y * sa + rel.z * ca
		o:set_attach(self.object, "", {x = rel.x * 10, y = y * 10, z = z * 10}, {x = (rot or 0) - math.deg(alpha), y = 0, z = 0})
	end
	for _, p in ipairs(bed.plates) do put(parts[p.id], p.rel, p.rot) end
	-- 碎石（各段 bed.fills 躺在各段底板上）：厚度依載量（空 → 不顯示，各段有上限），貼圖用載最多的那種碎石
	local total, best = V.load_mix(self)
	local frac = math.min(1, total / def.cap)
	local h = frac > 0 and (0.1 + (bed.fill_hmax - 0.1) * frac) or 0
	local key = ("%.2f/%s"):format(h, tostring(best))
	local changed = self.fill_key ~= key
	self.fill_key = key
	for _, fp in ipairs(bed.fills) do
		local o = parts[fp.id]
		if o then
			local hh = math.min(h, fp.hmax or h)
			if changed then
				if hh > 0 then
					local t = V.rubble_tex(best)
					o:set_properties({is_visible = true, visual_size = {x = bed.fill_w, y = hh, z = fp.len}, textures = {t, t, t, t, t, t}})
				else
					o:set_properties({is_visible = false})
				end
			end
			put(o, {x = 0, y = fp.y0 + hh / 2, z = fp.z}, fp.rot)
		end
	end
end

-- 車斗那段（車身座標 z −rear..−half）卡進實心方塊的檢查點數（車底往上 bed.overlap_dy 的高度，
-- 更低的小台階、碎石讓碰撞箱自己爬）
local function bed_overlap(p, yaw, def)
	local c, sn = math.cos(yaw), math.sin(yaw)
	local bottom = p.y - def.half
	local n_hit = 0
	for lz = -def.rear + 0.05, -def.half - 0.25, 0.5 do   -- 從車尾最末端開始
		for _, lx in ipairs(def.bed.overlap_lat) do
			local wx, wz = p.x + lx * c - lz * sn, p.z + lx * sn + lz * c
			for _, dy in ipairs(def.bed.overlap_dy) do
				local n = core.get_node({x = math.floor(wx + 0.5), y = math.floor(bottom + dy + 0.5), z = math.floor(wz + 0.5)}).name
				local nd = core.registered_nodes[n]
				if n ~= "air" and (not nd or nd.walkable ~= false) then n_hit = n_hit + 1 end
			end
		end
	end
	return n_hit
end
-- 從 (p, yaw) 動到 (p2, yaw2) 會不會讓車斗撞得更多（已經卡住時，不會更糟的動作照樣允許，才能脫困）
local function bed_blocked(p, yaw, p2, yaw2, def)
	local after = bed_overlap(p2, yaw2, def)
	if after == 0 then return false end
	return after > bed_overlap(p, yaw, def)
end

-- 車斗中心上方（挖土機倒進來的位置，世界座標）
function V.bed_target(e)
	local bed = TYPES[e.vkind].bed
	local tp, ty = e.object:get_pos(), e.object:get_yaw()
	local bz = bed.hinge.z + bed.size.z / 2
	local by = bed.hinge.y + bed.size.y + 0.8
	return {x = tp.x - bz * math.sin(ty), y = tp.y + by, z = tp.z + bz * math.cos(ty)}   -- 車身 +Z → (−sin, cos)
end

-- 把 def 做成有車斗的車。spec：
--   hinge：車斗軸心（車斗後端下緣，車身座標）；size：車斗外尺寸；body：車斗以外的零件；
--   floor_tex／side_tex：車斗底板與側板貼圖；overlap_lat／overlap_dy：車斗段碰撞的檢查點（橫向位置、離車底高度）；
--   aim_top：挖土機瞄準時車身的上緣（相對車身中心）；plates：車斗各片（省略 → 方盒車斗），
--   每片 {id, rel（相對軸心的中心，車斗放平時）, size, rot（可選，度）, floor（可選，用底板貼圖）}；
--   fills：車斗裡的碎石分段（省略 → 一整塊），每段 {id, z（中心）, len, y0（底面）, rot（可選）, hmax（可選，厚度上限）}；
--   dump_rows：倒在車尾幾排（預設 1）
local function hauler(def, spec)
	local bed = spec
	local S = bed.size
	-- 預設：空心方盒車斗的 5 片。碎石塊放在裡面，四周與上緣都留空隙，
	-- 不和車斗的任何一面重疊（重疊會 z-fighting 閃爍）
	bed.plates = spec.plates or {
		{id = "bed_floor", rel = {x = 0, y = BED_T / 2, z = S.z / 2}, size = {x = S.x, y = BED_T, z = S.z}, floor = true},
		{id = "bed_left", rel = {x = -(S.x - BED_T) / 2, y = S.y / 2, z = S.z / 2}, size = {x = BED_T, y = S.y, z = S.z}},
		{id = "bed_right", rel = {x = (S.x - BED_T) / 2, y = S.y / 2, z = S.z / 2}, size = {x = BED_T, y = S.y, z = S.z}},
		{id = "bed_front", rel = {x = 0, y = S.y / 2, z = S.z - BED_T / 2}, size = {x = S.x, y = S.y, z = BED_T}},
		{id = "bed_back", rel = {x = 0, y = S.y / 2, z = BED_T / 2}, size = {x = S.x, y = S.y, z = BED_T}},
	}
	bed.fill_w = S.x - 2 * BED_T - 0.1
	bed.fill_hmax = S.y - BED_T - 0.1
	bed.fills = spec.fills or {{id = "bedfill", z = S.z / 2, len = S.z - 2 * BED_T - 0.1, y0 = BED_T}}
	def.bed = bed
	def.look_limit = def.look_limit or math.rad(75)   -- 駕駛只看車頭前方 150°（不會轉頭看到自己的車斗）
	-- 零件：車斗以外的部分、車斗各片（位置由 place_bed 擺）、車斗裡的碎石
	local parts = {}
	for _, p in ipairs(spec.body) do parts[#parts + 1] = p end
	for _, fp in ipairs(bed.fills) do
		parts[#parts + 1] = {id = fp.id, pos = {x = 0, y = 0, z = 0}, size = {x = bed.fill_w, y = 0.2, z = fp.len}, tex = box_tex("#6a6058")}
	end
	for _, p in ipairs(bed.plates) do
		local t = p.floor and spec.floor_tex or spec.side_tex
		parts[#parts + 1] = {id = p.id, pos = {x = 0, y = 0, z = 0}, size = p.size, tex = {t, t, t, t, t, t}}
	end
	def.parts = parts

	function def.on_spawn(self) self.fill_key = nil; place_bed(self, 0) end
	function def.refresh(self)
		local t, cap = load_total(self), def.cap
		self.object:set_properties({
			nametag = ("載量 %d / %d 級（%.1f / %.0f m³）"):format(t, cap, t / NLEV, cap / NLEV),
			nametag_color = t >= cap and "#ff8060" or "#ffffff",
		})
		if not self.tip then place_bed(self, 0) end
	end
	function def.hud() return "\n空白鍵 把車斗倒在車尾" end
	-- 車斗那段會撞到（或正在倒土）：不轉
	function def.can_turn(self, pos, yaw, yaw2)
		return not (self.tip or bed_blocked(pos, yaw, pos, yaw2, def)
			or V.objects_in(self, pos, yaw2, -def.half, def.half, -def.rear, -def.half))
	end
	-- 前進時車斗跟著駕駛艙走過的路，不必檢查；倒車看後面一點（全速 0.1 s 走的距離）；倒土時不動。
	-- 伺服器卡頓時一步會退很遠、預判擋不住：倒車後車斗撞得比上一步多，就退回上一步的位置
	function def.move(self, ctx)
		local pos, dir = ctx.pos, ctx.dir
		if self.bed_safe then
			local safe = self.bed_safe
			self.bed_safe = nil
			if bed_overlap(pos, ctx.yaw, def) > safe.n then
				ctx.obj:set_pos(safe.pos)
				ctx.speed = 0
				return
			end
		end
		if ctx.speed == 0 then return end
		local la = ctx.speed * 0.1
		local p2 = {x = pos.x + dir.x * la, y = pos.y, z = pos.z + dir.z * la}
		if self.tip or (ctx.speed < 0 and (bed_blocked(pos, ctx.yaw, p2, ctx.yaw, def)
				or V.objects_in(self, p2, ctx.yaw, -def.half, def.half, -def.rear, -def.half))) then
			ctx.speed = 0
		elseif ctx.speed < 0 then
			self.bed_safe = {pos = vector.copy(pos), n = bed_overlap(pos, ctx.yaw, def)}
		end
	end
	function def.step(self, ctx)
		-- 倒土：車斗抬起 TIP_UP 秒到 TIP_ANGLE → 倒在車尾 → 停 TIP_HOLD 秒 → 放下 TIP_DOWN 秒
		if self.tip then
			local tp = self.tip
			tp.t = tp.t + ctx.dtime
			local a
			if tp.t < TIP_UP then a = TIP_ANGLE * tp.t / TIP_UP
			elseif tp.t < TIP_UP + TIP_HOLD then a = TIP_ANGLE
			else a = TIP_ANGLE * math.max(0, 1 - (tp.t - TIP_UP - TIP_HOLD) / TIP_DOWN) end
			if not tp.done and tp.t >= TIP_UP then
				tp.done = true
				local pos, dir = ctx.pos, ctx.dir
				local y0 = V.ground_y(pos, def.half)
				-- 車尾正後方（用實際朝向，不對齊格線：車子斜停時倒的位置才會在車尾）
				local cells = {}
				for r = 0, (spec.dump_rows or 1) - 1 do
					local d0 = def.rear + 0.5 + r
					local cx, cz = pos.x - dir.x * d0, pos.z - dir.z * d0
					for _, l in ipairs(def.lat) do
						cells[#cells + 1] = {x = math.floor(cx - dir.z * l + 0.5), y = y0, z = math.floor(cz + dir.x * l + 0.5)}
					end
				end
				V.dump_to_ground(self, cells, y0 + 1)
				self.fill_key = nil
				update_hud(self)
			end
			place_bed(self, a)
			if tp.t >= TIP_TOTAL then self.tip = nil; place_bed(self, 0) end
		end
		-- 載量一有變化就重畫車斗裡的碎石與名牌（不管是誰改的）
		if not self.tip then
			local tot = load_total(self)
			if tot ~= self.shown_total then
				self.shown_total = tot
				V.refresh(self)
			end
		end
	end
	function def.action(self, ctx)
		if ctx.ctrl.jump and load_total(self) > 0 and not self.tip then
			self.t_act = TIP_TOTAL + 0.1
			self.tip = {t = 0}
		end
	end
	return def
end
V.hauler = hauler

-- 卡車（原點在駕駛艙那段 3×3×3 的中心；車頭 z +1.5、車尾 z −5.5；車底 y −1.5）。
-- 尺寸接近真實的十輪砂石車：車寬 2.4～2.6 m、駕駛室頂離地約 3.1 m、車斗上緣約 2.3 m、輪胎直徑 1.0 m
-- （碰撞箱仍是 3 格寬）
local WHEEL = "[fill:16x16:#1c1c1c^[fill:10x10:3,3:#3a3a3a^[fill:6x6:5,5:#8a8a8a^[fill:2x2:7,7:#c0c0c0"
local TREAD = "[fill:16x16:#1c1c1c^[fill:16x1:0,3:#2e2e2e^[fill:16x1:0,8:#2e2e2e^[fill:16x1:0,13:#2e2e2e"
V.WHEEL, V.TREAD = WHEEL, TREAD

local truck = {desc = "卡車 Dump truck", short = "卡車", color = "#c84020", cap = 12 * NLEV, speed = 5.0,
	half = 1.5, lat = {-1, 0, 1}, eye_up = 1.55, eye_fwd = 1.35, rear = 5.5, mirror = {x = 1.35, y = 1.3, z = 1.2},
	rearcam = {x = 0, y = 1.0, z = -5.7}, tilt = {front = 0.5, rear = -3.8, side_z = -1.6, side_x = 1.1},
	item_desc = "右鍵上車；空白鍵把車斗倒在車尾（載量 12 m³）"}
truck.inv_image = V.inv_icon(truck.color, "^[fill:10x4:3,3:#9fd0ff")   -- 擋風玻璃
do
	local c = truck.color
	local cab_front = ("[fill:16x16:%s^[fill:12x6:2,2:#9fd0ff^[fill:4x2:2,12:#f0e070^[fill:4x2:10,12:#f0e070"):format(c)
	local cab_side = ("[fill:16x16:%s^[fill:6x6:8,2:#9fd0ff"):format(c)
	local wheel = {TREAD, TREAD, WHEEL, WHEEL, TREAD, TREAD}   -- 上下前後是胎面，左右兩側是輪圈
	local body = {
		{pos = {x = 0, y = -0.55, z = -2.0}, size = {x = 1.6, y = 0.3, z = 6.6}, tex = box_tex("#2a2a2a")},   -- 底盤
		{pos = {x = 0, y = 0.6, z = 0.5}, size = {x = 2.4, y = 2.0, z = 2.0},
			tex = {("[fill:16x16:%s"):format(c), "[fill:16x16:#2a2a2a", cab_side, cab_side, cab_front, ("[fill:16x16:%s"):format(c)}},
	}
	-- 前軸單輪、後兩軸雙輪（較寬），外緣在車斗外側
	for _, w in ipairs({{x = -1.15, z = 0.5, wd = 0.35}, {x = 1.15, z = 0.5, wd = 0.35},
			{x = -1.1, z = -3.2, wd = 0.6}, {x = 1.1, z = -3.2, wd = 0.6}, {x = -1.1, z = -4.4, wd = 0.6}, {x = 1.1, z = -4.4, wd = 0.6}}) do
		body[#body + 1] = {pos = {x = w.x, y = -1.0, z = w.z}, size = {x = w.wd, y = 1.0, z = 1.0}, tex = wheel}
	end
	hauler(truck, {
		hinge = {x = 0, y = -0.4, z = -5.5}, size = {x = 2.6, y = 1.2, z = 4.8}, body = body,
		floor_tex = "[fill:16x16:#4a2010",
		side_tex = ("[fill:16x16:%s^[fill:16x2:0,0:#8a2a10^[fill:2x16:4,0:#a83418^[fill:2x16:10,0:#a83418"):format(c),
		overlap_lat = {-1.25, 0, 1.25}, overlap_dy = {1.2, 2.2}, aim_top = 1.0,
	})
	-- 車斗那段（碰撞箱後方 z −5.5..−1.5）從地面到車斗上緣
	truck.colliders = V.colliders({-0.8, 0, 0.8}, {-5, -4, -3, -2}, -1.5, 0.8)
end
V.register("truck", truck)
