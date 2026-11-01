-- rockmech/vehicle_cart.lua
-- 手推車：經營模式第一台買得起的車，比人多載一點（rockmech_cart_blocks 塊）。操作同卡車：右鍵上車、空白鍵倒在車尾，
-- 手上拿著碎石時右鍵是裝上去。沒有無人駕駛。

local V = rockmech.vehicles
local NLEV, box_tex = V.NLEV, V.box_tex

local c = "#8a7050"
local cart = {desc = "手推車 Hand cart", short = "推車", color = c, cap = rockmech.cfg.cart_blocks * NLEV, speed = 2.5,
	tire = 0.6, no_ahs = true,
	half = 0.9, top = 0.6, lat = {-1, 0, 1}, eye_up = 1.2, eye_fwd = 0.3, rear = 2.4, mirror = {x = 0.8, y = 0.8, z = 0.2},
	rearcam = {x = 0, y = 0.9, z = -2.6}, tilt = {front = 0.4, rear = -2.0, side_z = -0.8, side_x = 0.6},
	max_grade = math.rad(17),
	item_desc = ("右鍵上車；空白鍵把車斗倒在車尾（載量 %d 塊）\n手上拿著碎石時右鍵是裝上去"):format(rockmech.cfg.cart_blocks)}
do
	local r = {}
	r[#r + 1] = {4, 12, 22, 8, c}; r[#r + 1] = {2, 10, 26, 2, "#5a4a30"}
	V.icon_wheel(r, 15, 24, 4)
	cart.inv_image = V.icon(r)
end
do
	local wheel = {V.TREAD, V.TREAD, V.WHEEL, V.WHEEL, V.TREAD, V.TREAD}
	local body = {
		{pos = {x = 0, y = -0.5, z = -0.8}, size = {x = 1.0, y = 0.12, z = 3.0}, tex = box_tex("#5a4a30")},   -- 底架
		{pos = {x = -0.8, y = -0.55, z = -1.5}, size = {x = 0.2, y = 0.7, z = 0.7}, tex = wheel},
		{pos = {x = 0.8, y = -0.55, z = -1.5}, size = {x = 0.2, y = 0.7, z = 0.7}, tex = wheel},
	}
	V.hauler(cart, {
		hinge = {x = 0, y = -0.4, z = -2.4}, size = {x = 1.5, y = 0.8, z = 1.6}, body = body,
		floor_tex = "[fill:16x16:#4a3a24",
		side_tex = ("[fill:16x16:%s^[fill:16x2:0,0:#5a4a30"):format(c),
		overlap_lat = {-0.7, 0, 0.7}, overlap_dy = {0.6, 1.2}, aim_top = 0.4,
	})
	function cart.hud(self) return "\n空白鍵 把車斗倒在車尾" end
end
V.register("cart", cart)
