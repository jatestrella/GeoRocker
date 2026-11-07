-- rockmech/vehicle_corerig.lua
-- 岩芯鑽探車（履帶式探勘鑽機）：車頭前一根桅桿，E 在桅桿下方往下鑽岩芯孔，最深 MAX_DEPTH m（手持鑽機只有 10 m）。
-- 鑽孔、柱狀圖、岩芯箱、鑽孔日誌都跟手持鑽機共用（coredrill.lua 的 rockmech.coredrill_start）。
-- 鑽的時候迴轉頭沿桅桿往下走；駕駛可以下車，但車子一移動就停在那個深度。由 vehicles.lua 載入。

local S = rockmech.S
local V = rockmech.vehicles
local box_tex, update_hud = V.box_tex, V.update_hud

local MAX_DEPTH = 60
local MAST_FOOT = {x = 0, y = -1.5, z = 2.3}
local MAST_TOP = 6.2
local HEAD_TOP, HEAD_LOW = 5.6, -0.9

local def = {desc = S("Core drill rig"), short = S("Core rig"), color = "#e8e8e0", cap = 0, speed = 1.2,
	half = 1.5, rear = 3.0, lat = {-1, 0, 1}, eye_up = 1.75, eye_fwd = 0.9, eye_side = -0.5,
	tail_lat = {-1.1, 0, 1.1}, tail_dy = {1.2, 2.2},
	mirror = {x = 1.35, y = 1.4, z = 0.6},
	tilt = {front = 1.3, rear = -2.6, side_z = -0.6, side_x = 1.1}, max_grade = math.rad(20),
	cam = {o = {x = 2.6, y = 1.8, z = 5.2}, target = MAST_FOOT, mark = MAST_FOOT,
		hfov = math.rad(75), vfov = math.rad(46), w = 56, h = 31},
	exhaust = {x = 0.9, y = 1.4, z = -2.2},
	item_desc = S("Right-click to get in; E drills a core hole downward below the mast (up to @1 m) and gives you core boxes and a borehole log", ("%d"):format(MAX_DEPTH))}
V.MASS.corerig = 22
do   -- 圖示：履帶、白色車身、藍色高桅桿
	local c, r = def.color, {}
	V.icon_track(r, 2, 24, 20, 7)
	r[#r + 1] = {3, 16, 17, 8, c}; r[#r + 1] = {3, 9, 7, 8, c}; r[#r + 1] = {5, 10, 4, 5, "#9fd0ff"}
	r[#r + 1] = {23, 1, 3, 29, "#2f5f9f"}; r[#r + 1] = {22, 6, 5, 4, "#3a3a3a"}; r[#r + 1] = {21, 29, 7, 2, "#5a5a5a"}
	r[#r + 1] = {3, 20, 17, 1, "#2f5f9f"}
	def.inv_image = V.icon(r)
end
do
	local c = def.color
	local o = ("[fill:16x16:%s^[fill:16x2:0,11:#2f5f9f"):format(c)
	local win = ("[fill:16x16:%s^[fill:12x9:2,2:#9fd0ff^[fill:16x2:0,14:#2a2a2a"):format(c)
	local side = ("[fill:16x16:%s^[fill:10x8:3,2:#9fd0ff^[fill:16x2:0,14:#2a2a2a"):format(c)
	local grille = ("[fill:16x16:%s^[fill:12x8:2,4:#2a2a2a^[fill:12x1:2,6:#4a4a4a^[fill:12x1:2,9:#4a4a4a"):format(c)
	local mast = "[fill:16x16:#2f5f9f^[fill:4x16:6,0:#4a7abf^[fill:16x1:0,3:#e8e8e0^[fill:16x1:0,11:#e8e8e0"
	local rods = "[fill:16x16:#8a8e92^[fill:16x1:0,4:#6a6e72^[fill:16x1:0,10:#6a6e72"
	local TRACK = V.TRACK
	local trk = {TRACK, TRACK, TRACK, TRACK, TRACK, TRACK}
	def.parts = {
		{pos = {x = -1.1, y = -1.0, z = -0.6}, size = {x = 0.7, y = 1.0, z = 4.2}, tex = trk},
		{pos = {x = 1.1, y = -1.0, z = -0.6}, size = {x = 0.7, y = 1.0, z = 4.2}, tex = trk},
		{pos = {x = 0, y = -0.35, z = -0.7}, size = {x = 2.2, y = 0.5, z = 4.4}, tex = box_tex("#3a3a3a")},   -- 甲板
		{pos = {x = -0.5, y = 0.6, z = 0.2}, size = {x = 1.2, y = 1.5, z = 1.4}, tex = {o, "[fill:16x16:#2a2a2a", side, side, win, o}},   -- 駕駛室
		{pos = {x = 0.4, y = 0.45, z = -1.9}, size = {x = 1.8, y = 1.4, z = 2.0}, tex = {o, o, grille, grille, o, o}},   -- 動力箱
		{pos = {x = 0.9, y = 0.0, z = -0.5}, size = {x = 0.6, y = 0.9, z = 1.6}, tex = {rods, rods, rods, rods, rods, rods}},   -- 鑽桿架
		{pos = {x = 0, y = -0.2, z = 1.75}, size = {x = 0.6, y = 0.5, z = 1.0}, tex = box_tex("#2f5f9f")},   -- 桅桿臂
		{pos = {x = 0, y = (MAST_FOOT.y + MAST_TOP) / 2, z = MAST_FOOT.z}, size = {x = 0.35, y = MAST_TOP - MAST_FOOT.y, z = 0.45},
			tex = {mast, mast, mast, mast, mast, mast}},   -- 桅桿
		{pos = {x = 0, y = MAST_FOOT.y + 0.15, z = MAST_FOOT.z}, size = {x = 0.8, y = 0.3, z = 0.8}, tex = box_tex("#4a4a4a")},   -- 桅桿腳
		{id = "head", pos = {x = 0, y = HEAD_TOP, z = MAST_FOOT.z}, size = {x = 0.6, y = 0.6, z = 0.6}, tex = box_tex("#3a3a3a")},   -- 迴轉頭
	}
end
def.overhangs = {
	{x0 = -0.6, x1 = 0.6, z0 = 1.5, z1 = 2.8, y0 = -1.5, y1 = MAST_TOP, body = "z0"},
	{x0 = -1.2, x1 = 1.2, z0 = -3.0, z1 = -1.5, y0 = -1.5, y1 = 1.2, body = "z1"},
}

local function place_head(self, y)
	local h = self.parts and self.parts.head
	if h then h:set_attach(self.object, "", {x = MAST_FOOT.x * 10, y = y * 10, z = MAST_FOOT.z * 10}, {x = 0, y = 0, z = 0}) end
end

-- 桅桿腳下的孔口那一格（空的，下面是岩石或碎石）
local function collar_of(self)
	local foot = V.to_world(self, MAST_FOOT)
	local x, z, y = math.floor(foot.x + 0.5), math.floor(foot.z + 0.5), math.floor(foot.y + 0.5)
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
	local below = core.get_node({x = x, y = y - 1, z = z}).name
	if not (rockmech.lith_of_node[below] or rockmech.is_rubble(below) or core.get_item_group(below, "rockmech_topsoil") > 0) then return nil, S("There is no rock under the mast") end
	return above
end

function def.action(self, ctx)
	if not ctx.ctrl.aux1 or not rockmech.coredrill_start then return end
	self.t_act = 0.6
	local name = self.driver
	if self.coring then self.msg = S("Already drilling"); update_hud(self); return end
	local collar, why = collar_of(self)
	if not collar then self.msg = why; update_hud(self); return end
	local p0 = self.object:get_pos()
	local obj = self.object
	local ok = rockmech.coredrill_start(name, collar, MAX_DEPTH, function()
		local p = obj:get_pos()
		if not p then return S("The core rig is gone") end
		if vector.distance(p, p0) > 0.4 then return S("The core rig moved") end
	end, function()
		self.coring = nil
		place_head(self, HEAD_TOP)
		update_hud(self)
	end)
	if ok then self.coring = name; self.msg = nil end
	update_hud(self)
end

function def.step(self, ctx)
	if not self.coring then return end
	local d, max = rockmech.coredrill_depth(self.coring)
	if not d then return end
	-- 迴轉頭沿桅桿往下走（鑽到最深時到桅桿腳）
	place_head(self, HEAD_TOP - (HEAD_TOP - HEAD_LOW) * math.min(1, d / max))
	self.hud_t = (self.hud_t or 0) + ctx.dtime
	if self.hud_t > 1 then self.hud_t = 0; update_hud(self) end
end
function def.busy(self) return self.coring ~= nil end

function def.hud(self)
	local s = "\n"
	if self.coring then
		local d, max = rockmech.coredrill_depth(self.coring)
		s = s .. S("Coring @1 / @2 m (the rig cannot move)", ("%d"):format(d or 0), ("%d"):format(max or MAX_DEPTH))
	end
	if self.msg then s = s .. "\n" .. self.msg end
	return s
end
function def.keys(self) return {{"E", S("Core drilling (up to @1 m)", ("%d"):format(MAX_DEPTH)), on = self.coring ~= nil}} end
function def.on_spawn(self) place_head(self, HEAD_TOP) end

V.register("corerig", def)
