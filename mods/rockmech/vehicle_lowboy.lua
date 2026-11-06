-- rockmech/vehicle_lowboy.lua
-- 平板拖車（lowboy）：牽引車＋低平板，載怪手、推土機這類慢的機具，或把報廢的車拖回來。由 vehicles.lua 載入。
--   E：平板上沒車 → 把平板旁邊 LOAD_R m 內、自己組（或沒有組）的車拉上來（自重 ≤ MAX_T t；有人在開的不行）；
--      平板上有車 → 卸在車尾後方。
--   載車時速度 LOADED_SPEED。載的車掛在平板上（附著），拖車存檔時記著它的編號，區塊重新載入後自己再掛回去。
-- 車身：牽引車在前（車頭 z +1.5），平板從 z −1.5 到 −9.5，平板面離車底 0.5 m。

local V = rockmech.vehicles
local box_tex = V.box_tex
local WHEEL, TREAD = V.WHEEL, V.TREAD

local MAX_T = 60            -- 載得動的自重 (t)
local LOAD_R = 8            -- 平板中心多近的車拉得上來 (m)
local LOADED_SPEED = 2.5    -- 載車時的速度 (m/s)
local DECK_Z, DECK_TOP = -5.6, -1.0     -- 平板中心（車身座標 z）、平板面（車身座標 y；車底 −1.5）

local c = "#d86018"
local def = {desc = "平板拖車 Lowboy", short = "拖車", color = c, cap = 0, speed = 4,
	tire = 1.0, max_grade = math.rad(15),
	half = 1.5, top = 1.4, lat = {-1, 0, 1}, eye_up = 1.5, eye_fwd = 0.9, rear = 9.5,
	mirror = {x = 1.35, y = 1.2, z = 0.6}, rearcam = {x = 0, y = 1.0, z = -9.7},
	tilt = {front = 0.9, rear = -8.5, side_z = -4.0, side_x = 1.1},
	tail_lat = {-1.3, 0, 1.3}, tail_dy = {0.6},
	item_desc = ("右鍵上車；E 把平板旁邊的車拉上平板（自重 ≤ %d t：怪手、推土機、鑽機、卡車…，報廢的也行），再按 E 卸在車尾"):format(MAX_T)}
V.MASS.lowboy = 25
do   -- 圖示：橘色牽引車、長長的低平板、上面一台小怪手的輪廓
	local r = {}
	r[#r + 1] = {22, 12, 8, 9, c}; r[#r + 1] = {24, 13, 4, 4, "#9fd0ff"}
	r[#r + 1] = {1, 19, 23, 3, "#3a3a3a"}; r[#r + 1] = {18, 16, 6, 3, "#3a3a3a"}
	r[#r + 1] = {5, 12, 9, 6, "#e8c828"}; r[#r + 1] = {12, 8, 6, 2, "#e8c828"}
	V.icon_wheel(r, 26, 24, 3); V.icon_wheel(r, 5, 24, 3); V.icon_wheel(r, 11, 24, 3)
	def.inv_image = V.icon(r)
end
do
	local paint = ("[fill:16x16:%s"):format(c)
	local glass = ("[fill:16x16:%s^[fill:12x8:2,2:#9fd0ff^[fill:16x2:0,14:#2a2a2a"):format(c)
	local nose = ("[fill:16x16:%s^[fill:12x7:2,5:#2a2a2a^[fill:12x1:2,7:#4a4a4a^[fill:12x1:2,10:#4a4a4a^[fill:3x2:1,1:#f0e070^[fill:3x2:12,1:#f0e070"):format(c)
	local deck = "[fill:16x16:#4a4c50^[fill:16x1:0,4:#3a3c40^[fill:16x1:0,9:#3a3c40^[fill:16x1:0,14:#3a3c40"
	local steel = box_tex("#3a3a3a")
	local stripe = "[fill:16x16:#3a3c40^[fill:4x16:0,0:#f0c020^[fill:4x16:8,0:#f0c020"
	local wheel = {TREAD, TREAD, WHEEL, WHEEL, TREAD, TREAD}
	def.parts = {
		{pos = {x = 0, y = -0.9, z = -0.4}, size = {x = 1.6, y = 0.4, z = 3.6}, tex = steel},                     -- 牽引車車架
		{pos = {x = 0, y = -0.2, z = 1.0}, size = {x = 2.3, y = 1.0, z = 1.0}, tex = {paint, paint, paint, paint, nose, paint}},  -- 引擎蓋
		{pos = {x = 0, y = 0.4, z = -0.1}, size = {x = 2.4, y = 1.8, z = 1.3}, tex = {paint, steel[2], glass, glass, glass, paint}}, -- 駕駛室
		{pos = {x = 0.8, y = 1.2, z = -0.85}, size = {x = 0.14, y = 1.2, z = 0.14}, tex = box_tex("#202020")},  -- 排氣管
		{pos = {x = 0, y = -0.55, z = -1.9}, size = {x = 2.6, y = 0.5, z = 1.4}, tex = steel},                   -- 鵝頸
		{pos = {x = 0, y = DECK_TOP - 0.12, z = DECK_Z}, size = {x = 2.9, y = 0.25, z = 7.0}, tex = {deck, steel[2], stripe, stripe, stripe, stripe}},  -- 平板
		{pos = {x = -0.85, y = -1.25, z = -9.6}, size = {x = 0.7, y = 0.08, z = 1.0}, tex = box_tex("#5a5c60"), rot = {x = -20, y = 0, z = 0}},  -- 後坡道
		{pos = {x = 0.85, y = -1.25, z = -9.6}, size = {x = 0.7, y = 0.08, z = 1.0}, tex = box_tex("#5a5c60"), rot = {x = -20, y = 0, z = 0}},
	}
	for _, w in ipairs({{x = -1.1, z = 1.0}, {x = 1.1, z = 1.0}, {x = -1.1, z = -1.2}, {x = 1.1, z = -1.2},
			{x = -1.3, z = -8.0}, {x = 1.3, z = -8.0}, {x = -1.3, z = -7.0}, {x = 1.3, z = -7.0}}) do
		def.parts[#def.parts + 1] = {pos = {x = w.x, y = -1.0, z = w.z}, size = {x = 0.35, y = 1.0, z = 1.0}, tex = wheel}
	end
end
def.exhaust = {x = 0.8, y = 1.85, z = -0.85}
-- 擋人：平板（碰撞箱後方）
def.overhangs = {{x0 = -1.5, x1 = 1.5, z0 = -9.5, z1 = -1.5, y0 = -1.5, y1 = -0.85, body = "z1"}}

---------------------------------------------------------------------------
-- 載車、卸車
---------------------------------------------------------------------------

local function carried(self)
	local e = self.carry_uid and V.by_uid[self.carry_uid]
	return e and e.object:get_pos() and e or nil
end

-- 把 e 掛到平板上（車底貼著平板面）
local function attach(self, e)
	local d = V.TYPES[e.vkind]
	e.object:set_velocity({x = 0, y = 0, z = 0})
	e.object:set_acceleration({x = 0, y = 0, z = 0})
	e.object:set_attach(self.object, "", {x = 0, y = (DECK_TOP + d.half) * 10, z = DECK_Z * 10}, {x = 0, y = 0, z = 0})
	e.on_lowboy = self.uid
end

local function load_vehicle(self, name)
	local pos = self.object:get_pos()
	local deck = V.to_world(self, {x = 0, y = 0, z = DECK_Z})
	local best, bd
	for _, o in ipairs(core.get_objects_inside_radius(deck, LOAD_R + 6)) do
		local e = o:get_luaentity()
		if e and e ~= self and e.vkind and e.vkind ~= "lowboy" and not e.driver and not o:get_attach()
				and (not self.owner or not e.owner or e.owner == self.owner) then
			local d = vector.distance(o:get_pos(), deck)
			if d <= LOAD_R and (not bd or d < bd) then best, bd = e, d end
		end
	end
	if not best then return "平板旁邊 " .. LOAD_R .. " m 內沒有可以載的車" end
	local t = V.MASS[best.vkind] or 20
	if t > MAX_T then return ("%s 自重 %d t，超過 %d t 載不動"):format(V.TYPES[best.vkind].desc, t, MAX_T) end
	attach(self, best)
	self.carry_uid = best.uid
	return nil, V.TYPES[best.vkind].desc
end

local function unload_vehicle(self)
	local e = carried(self)
	if not e then self.carry_uid = nil; return end
	local d = V.TYPES[e.vkind]
	e.object:set_detach()
	e.on_lowboy = nil
	-- 卸在車尾後方：平板尾端再往後 車頭長 + 1 m
	local p = V.to_world(self, {x = 0, y = -def.half + d.half + 0.3, z = -def.rear - (d.half + 1)})
	e.object:set_pos(p)
	e.object:set_yaw(self.object:get_yaw())
	e.object:set_acceleration({x = 0, y = -9.81, z = 0})
	self.carry_uid = nil
	return d.desc
end

function def.action(self, ctx)
	if not ctx.ctrl.aux1 then return end
	self.t_act = 0.6
	if self.carry_uid then
		local what = unload_vehicle(self)
		self.msg = what and ("卸下 " .. what) or nil
	else
		local why, what = load_vehicle(self, self.driver)
		self.msg = why or ("載上 " .. what)
	end
	V.update_hud(self)
end

function def.move(self, ctx)
	if self.carry_uid then
		ctx.speed = math.max(-LOADED_SPEED, math.min(LOADED_SPEED, ctx.speed))
		-- 區塊重新載入後，載的車還沒掛回來：找到就掛
		if not carried(self) then
			local e = V.by_uid[self.carry_uid]
			if e and e.object:get_pos() and not e.object:get_attach() then attach(self, e) end
		end
	end
end

function def.hud(self)
	local e = carried(self)
	return "\n平板：" .. (e and V.TYPES[e.vkind].desc or (self.carry_uid and "（載的車還沒載入）" or "空的"))
		.. ("　E %s"):format(self.carry_uid and "卸車" or "載車（平板旁邊的車）")
		.. (self.msg and ("\n" .. self.msg) or "")
end
function def.on_save(self, data) data.carry_uid = self.carry_uid end
function def.on_load(self, data) self.carry_uid = data.carry_uid end

V.register("lowboy", def)
