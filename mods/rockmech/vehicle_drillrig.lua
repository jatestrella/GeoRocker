-- rockmech/vehicle_drillrig.lua
-- 露天鑽機（履帶式台階鑽機，Epiroc SmartROC／Sandvik Pantera 類）。由 vehicles.lua 載入。
-- 3 寬 × 3 高 × 約 6 m；履帶底盤、左前方駕駛室、後方動力箱；車頭前方一根約 8 m 高的垂直桅桿。
--   E：在桅桿腳正下方往下鑽一個垂直孔（孔深照設定，碰到下方岩石不夠深就鑽到岩石底）；鑽的時候迴轉頭
--      沿桅桿往下走，每公尺 SEC_PER_M 秒，不能開車。一次鑽一孔，自己開車對位下一孔。
--   空白鍵：設定孔深（3～10 m）。駕駛艙上方中央有鑽孔攝影機畫面（從右前方看桅桿腳，色點 = 附近的孔）。
-- 垂直孔裝 ANFO（drilling.lua：倒進往下的鑽孔成柱狀裝藥，要一條乳膠炸藥當起爆藥包）。

local S = rockmech.S
local V = rockmech.vehicles
local box_tex, update_hud = V.box_tex, V.update_hud

local SEC_PER_M = 0.6       -- 鑽 1 m 的時間 (s)
local RETRACT = 0.4         -- 鑽好後迴轉頭升回頂端的時間（鑽孔時間的幾倍）
local MAST_FOOT = {x = 0, y = -1.5, z = 2.3}   -- 桅桿腳（孔口）在車身座標
local MAST_TOP = 6.7        -- 桅桿頂（車身座標 y）
local HEAD_TOP, HEAD_LOW = 6.0, -0.9   -- 迴轉頭在桅桿上的上下限

local def = {desc = S("Surface drill rig"), color = "#d8b020", cap = 0, speed = 1.2,
	half = 1.5, rear = 3.0, lat = {-1, 0, 1}, eye_up = 1.75, eye_fwd = 0.9, eye_side = -0.5,
	tail_lat = {-1.1, 0, 1.1}, tail_dy = {1.2, 2.2},
	mirror = {x = 1.35, y = 1.4, z = 0.6},
	tilt = {front = 1.3, rear = -2.6, side_z = -0.6, side_x = 1.1}, max_grade = math.rad(20),
	-- 鑽孔攝影機（駕駛艙上方中央的小畫面；駕駛座看不到孔位）：從桅桿右前方約 3 m 高往下看桅桿腳，
	-- 看得到孔位（畫面中央）和周圍的台階邊、已經鑽好的孔（色點）；鏡頭被岩石擋住就自動拉近
	cam = {o = {x = 2.6, y = 1.8, z = 5.2}, target = MAST_FOOT, holes = 8,
		hfov = math.rad(75), vfov = math.rad(46), w = 56, h = 31},
	item_desc = S("Right-click to get in; E drills, Space sets the depth")}
do   -- 圖示：履帶、車身、駕駛室、車頭前的高桅桿與迴轉頭
	local c, r = def.color, {}
	V.icon_track(r, 2, 24, 20, 7)
	r[#r + 1] = {3, 16, 17, 8, c}; r[#r + 1] = {11, 13, 8, 3, "#3a3a3a"}
	r[#r + 1] = {3, 9, 7, 8, c}; r[#r + 1] = {5, 10, 4, 5, "#9fd0ff"}
	r[#r + 1] = {19, 18, 4, 2, c}
	r[#r + 1] = {23, 1, 3, 29, "#3a3a3a"}; r[#r + 1] = {23, 12, 3, 1, c}; r[#r + 1] = {23, 22, 3, 1, c}
	r[#r + 1] = {22, 4, 5, 4, c}; r[#r + 1] = {21, 29, 7, 2, "#5a5a5a"}
	def.inv_image = V.icon(r)
end

do
	local c = def.color
	local o = ("[fill:16x16:%s"):format(c)
	local win = V.cab_glass(c, 2, 2, 12, 9) .. "^[fill:16x2:0,14:#2a2a2a"
	local side = V.cab_side(c, {win = {x = 3, y = 2, w = 10, h = 8}, clear = true, sill = "#2a2a2a", doors = {{x = 2, y = 1, w = 12, h = 12.8}}})
	local side_l = V.flip_side(side)
	local grille = ("[fill:16x16:%s^[fill:12x8:2,4:#2a2a2a^[fill:12x1:2,6:#4a4a4a^[fill:12x1:2,9:#4a4a4a"):format(c)
	local mast = "[fill:16x16:#3a3a3a^[fill:4x16:6,0:#5a5a5a^[fill:16x1:0,3:" .. c .. "^[fill:16x1:0,11:" .. c
	local TRACK = V.TRACK
	local trk = {TRACK, TRACK, TRACK, TRACK, TRACK, TRACK}
	def.parts = {
		{pos = {x = -1.1, y = -1.0, z = -0.6}, size = {x = 0.7, y = 1.0, z = 4.2}, tex = trk},
		{pos = {x = 1.1, y = -1.0, z = -0.6}, size = {x = 0.7, y = 1.0, z = 4.2}, tex = trk},
		{pos = {x = 0, y = -0.35, z = -0.7}, size = {x = 2.2, y = 0.5, z = 4.4}, tex = box_tex("#3a3a3a")},   -- 甲板
		{pos = {x = -0.5, y = 0.6, z = 0.2}, size = {x = 1.2, y = 1.5, z = 1.4}, alpha = true, tex = {o, "[fill:16x16:#2a2a2a", side, side_l, win, o}},   -- 駕駛室（車窗半透明）
		{pos = {x = -0.5, y = 0.6, z = -0.46}, size = {x = 1.16, y = 1.46, z = 0.04}, tex = box_tex(c)},   -- 駕駛室後牆
		{pos = {x = 0.4, y = 0.45, z = -1.9}, size = {x = 1.8, y = 1.4, z = 2.0}, tex = {o, o, grille, grille, o, o}},   -- 動力箱
		{pos = {x = 0, y = -0.2, z = 1.75}, size = {x = 0.6, y = 0.5, z = 1.0}, tex = box_tex(c)},   -- 桅桿臂
		{pos = {x = 0, y = (MAST_FOOT.y + MAST_TOP) / 2, z = MAST_FOOT.z}, size = {x = 0.35, y = MAST_TOP - MAST_FOOT.y, z = 0.45},
			tex = {mast, mast, mast, mast, mast, mast}},   -- 桅桿
		{pos = {x = 0, y = MAST_FOOT.y + 0.15, z = MAST_FOOT.z}, size = {x = 0.8, y = 0.3, z = 0.8}, tex = box_tex("#4a4a4a")},   -- 桅桿腳
		{id = "head", pos = {x = 0, y = HEAD_TOP, z = MAST_FOOT.z}, size = {x = 0.6, y = 0.7, z = 0.6}, tex = box_tex(c)},   -- 迴轉頭
	}
end

-- 擋人：桅桿（車頭外）與車尾
def.overhangs = {
	{x0 = -0.6, x1 = 0.6, z0 = 1.5, z1 = 2.8, y0 = -1.5, y1 = MAST_TOP, body = "z0"},
	{x0 = -1.2, x1 = 1.2, z0 = -3.0, z1 = -1.5, y0 = -1.5, y1 = 1.2, body = "z1"},
}

local function place_head(self, y)
	local h = self.parts and self.parts.head
	if h then h:set_attach(self.object, "", {x = MAST_FOOT.x * 10, y = y * 10, z = MAST_FOOT.z * 10}, {x = 0, y = 0, z = 0}) end
end
local function depth_setting(self) return self.depth or 6 end

-- 桅桿腳下的孔位：孔口那格（空氣，下面是岩石）與往下的岩石有幾格（最多 want 格）。找不到回傳 nil 與原因
local function hole_site(self, want)
	local foot = V.to_world(self, MAST_FOOT)
	local x, z = math.floor(foot.x + 0.5), math.floor(foot.z + 0.5)
	local y = math.floor(foot.y + 0.5)
	-- 孔口往上找空氣、往下找岩面（桅桿腳可能稍微懸空或卡進地面）
	for _ = 1, 3 do
		if V.passable(core.get_node({x = x, y = y, z = z}).name) then break end
		y = y + 1
	end
	for _ = 1, 3 do
		if not V.passable(core.get_node({x = x, y = y - 1, z = z}).name) then break end
		y = y - 1
	end
	local above = {x = x, y = y, z = z}
	if core.get_node(above).name ~= "air" then return nil, S("The hole collar must be clear") end
	if not rockmech.lith_of_node[core.get_node({x = x, y = y - 1, z = z}).name] then return nil, S("There is no rock under the mast (rubble cannot be drilled)") end
	local n = 0
	for k = 1, want do
		if not rockmech.lith_of_node[core.get_node({x = x, y = y - k, z = z}).name] then break end
		n = k
	end
	if n < 2 then return nil, S("Less than 2 m of rock below") end
	return above, n
end

function def.hud(self)
	local s = "\n" .. S("Hole depth setting @1 m", ("%d"):format(depth_setting(self)))
	if self.boring and self.boring.up then s = s .. "  " .. S("Pulling out the drill rods")
	elseif self.boring then s = s .. "  " .. S("Drilling @1 / @2 m", ("%.0f"):format(self.boring.t / SEC_PER_M), ("%d"):format(self.boring.depth)) end
	return s
end
function def.keys(self) return {{"E", S("Drill (below the mast)"), on = self.boring ~= nil}, {S("Space"), S("Set hole depth")}} end
function def.on_load(self, data) self.depth = data.depth end
function def.on_save(self, data) data.depth = self.depth end
function def.on_spawn(self) place_head(self, HEAD_TOP) end

function def.can_turn(self, pos, yaw, yaw2)
	return not self.boring and V.tail_can_turn(self, pos, yaw, yaw2, def)
end
function def.move(self, ctx)
	if self.boring then ctx.speed = 0; return end
	if ctx.speed > 0 then
		-- 桅桿伸出車頭：前方一排（車身高度上）有岩石、人或車就停
		local y0 = V.ground_y(ctx.pos, def.half)
		for _, dy in ipairs({1, 2}) do
			for _, c in ipairs(V.face_cells(ctx.pos, ctx.s, 1, 2, y0 + dy, 1, {0})) do
				local n = core.get_node(c).name
				if not rockmech.rubble_level[n] and not V.passable(n) then ctx.speed = 0; return end
			end
		end
		local la = ctx.speed * 0.1
		local p2 = {x = ctx.pos.x + ctx.dir.x * la, y = ctx.pos.y, z = ctx.pos.z + ctx.dir.z * la}
		if V.objects_in(self, p2, ctx.yaw, -0.6, 0.6, def.half, 2.8) then ctx.speed = 0 end
		return
	end
	V.tail_guard(self, def, ctx)
end

function def.step(self, ctx)
	local b = self.boring
	if not b then return end
	b.t = b.t + ctx.dtime * rockmech.eff_dig_mult(self.owner)
	local total = b.depth * SEC_PER_M
	if b.up then
		-- 鑽好了：迴轉頭沿桅桿升回頂端（抽出鑽桿，比鑽的時候快）
		local up = total * RETRACT
		place_head(self, HEAD_LOW + (HEAD_TOP - HEAD_LOW) * math.min(1, b.t / up))
		if b.t >= up then
			self.boring = nil
			place_head(self, HEAD_TOP)
			update_hud(self)
		end
		return
	end
	place_head(self, HEAD_TOP - (HEAD_TOP - HEAD_LOW) * math.min(1, b.t / total))
	local face = {x = b.above.x, y = b.above.y - 0.45, z = b.above.z}
	core.add_particlespawner({
		amount = 4, time = ctx.dtime,
		minpos = vector.subtract(face, 0.2), maxpos = vector.add(face, 0.2),
		minvel = {x = -1.2, y = 0.5, z = -1.2}, maxvel = {x = 1.2, y = 2, z = 1.2},
		minacc = {x = 0, y = -6, z = 0}, maxacc = {x = 0, y = -6, z = 0},
		minexptime = 0.4, maxexptime = 1.0, minsize = 0.6, maxsize = 1.4,
		texture = "[fill:4x4:#a89c90",
	})
	if b.t >= total then
		local under = {x = b.above.x, y = b.above.y - 1, z = b.above.z}
		if rockmech.make_hole(under, b.above) then
			local meta = core.get_meta(b.above)
			meta:set_float("depth", b.depth)
			meta:set_string("infotext", S("Vertical hole (@1 m deep)\nFill with ANFO and add one emulsion stick as a primer", ("%d"):format(b.depth)))
			self.msg = S("Drilled a @1 m hole", ("%d"):format(b.depth))
		else
			self.msg = S("The hole position is blocked")
		end
		b.up, b.t = true, 0
		update_hud(self)
	end
end

local editing = {}
local function depth_formspec(self)
	return ("formspec_version[6]size[6,3.2]label[0.5,0.6;%s]"
		.. "button[0.5,1.2;1.2,0.9;dec;−]button[1.9,1.2;1.2,0.9;inc;+]button_exit[3.5,2.2;2,0.7;ok;%s]"):format(
		core.formspec_escape(S("Hole depth (bench height + subdrill): @1 m", ("%d"):format(depth_setting(self)))),
		core.formspec_escape(S("Done")))
end
core.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= "rockmech:drillrig_depth" then return end
	local name = player:get_player_name()
	local self = editing[name]
	if not self or not self.object:get_pos() then return true end
	if fields.dec then self.depth = math.max(3, depth_setting(self) - 1) end
	if fields.inc then self.depth = math.min(10, depth_setting(self) + 1) end
	if fields.quit or fields.ok then editing[name] = nil
	else core.show_formspec(name, "rockmech:drillrig_depth", depth_formspec(self)) end
	update_hud(self)
	return true
end)

function def.action(self, ctx)
	local ctrl, d = ctx.ctrl, ctx.d
	if ctrl.aux1 and not self.boring then
		self.t_act = 0.5
		local above, n = hole_site(self, depth_setting(self))
		if not above then
			self.msg = n
		else
			self.boring = {above = above, depth = n, t = 0}
			self.msg = n < depth_setting(self) and S("Only @1 m of rock below: drilling to the bottom of the rock", ("%d"):format(n)) or nil
		end
		update_hud(self)
	elseif ctrl.jump and d and not self.boring then
		self.t_act = 0.5
		editing[d:get_player_name()] = self
		core.show_formspec(d:get_player_name(), "rockmech:drillrig_depth", depth_formspec(self))
	end
end

-- 重機操作員（vehicle_op.lua）：按住 E 點岩面 → 開到桅桿腳對準那一格，照設定的孔深鑽一個孔
do
	local function angle(a) return (a + math.pi) % (2 * math.pi) - math.pi end
	V.op_setup("drillrig", def, {
		label = S("Surface drill rig"), verb = S("drill a hole"), working = S("Drilling"), half = def.half,
		seat = {x = -0.5, y = 0.1, z = 0.2},
		busy = function(self) return self.boring ~= nil end,
		-- 遠：直接開過去；近（桅桿腳距離 + 4 m 內）：原地轉到正對那一格，再前後微調到桅桿腳落在那一格
		approach = function(self, ctx, p, steer)
			local foot = V.to_world(self, MAST_FOOT)
			if math.floor(foot.x + 0.5) == p.x and math.floor(foot.z + 0.5) == p.z then self.op.near = nil; return nil, true end
			local pos = ctx.pos
			local dx, dz = p.x - pos.x, p.z - pos.z
			local d = math.sqrt(dx * dx + dz * dz)
			if d > MAST_FOOT.z + 4 then return steer(self, ctx, p.x, p.z) end
			local op = self.op
			op.near = (op.near or 0) + ctx.dtime
			if op.near > 30 then op.near = nil; return "stuck" end
			if d < 1.2 then return {down = true} end
			local diff = angle(math.atan2(-dx, dz) - ctx.yaw)
			if diff > 0.08 then return {left = true} elseif diff < -0.08 then return {right = true} end
			if d > MAST_FOOT.z then return {up = true} end
			return {down = true}
		end,
		form = function(self)
			return ("label[0.5,3.7;%s]button[7.6,3.35;0.8,0.7;dec;−]button[8.5,3.35;0.8,0.7;inc;+]"):format(
				core.formspec_escape(S("Hole depth (bench height + subdrill): @1 m", ("%d"):format(depth_setting(self)))))
		end,
		fields = function(self, fields)
			if fields.dec then self.depth = math.max(3, depth_setting(self) - 1) end
			if fields.inc then self.depth = math.min(10, depth_setting(self) + 1) end
		end,
	})
end

V.register("drillrig", def)
