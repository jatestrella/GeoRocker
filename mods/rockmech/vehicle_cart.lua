-- rockmech/vehicle_cart.lua
-- 手推車：經營模式第一台買得起的車，比人多載一點（rockmech_cart_blocks 塊）。人走在車後面推，車斗在前面，看哪裡就推向哪裡，
-- 空白鍵把車斗往前翻，碎石倒在前方；手上拿著碎石時右鍵是裝上去。沒有引擎，也沒有無人駕駛。
-- 實體的車尾就是推車的前方（def.pushed：前後操作對調），車斗、倒土的邏輯和卡車共用。

local V = rockmech.vehicles
local S = rockmech.S
local NLEV, box_tex = V.NLEV, V.box_tex

local c = "#8a7050"
local cart = {desc = S("Hand cart"), short = S("Cart"), color = c, cap = rockmech.cfg.cart_blocks * NLEV, speed = 2.5,
	tire = 0.6, no_ahs = true, pushed = true, push_z = 0.9, look_limit = math.rad(50),
	select_box = {-1.4, -0.9, -3.2, 1.4, 1.6, 1.6}, aim_margin = 1.2,   -- 車子小，點選和怪手瞄準的範圍放大
	half = 0.9, top = 0.6, lat = {-1, 0, 1}, eye_up = V.EYE_HEIGHT - 0.9, eye_fwd = -0.9, rear = 2.4,
	tilt = {front = 0.4, rear = -2.0, side_z = -0.8, side_x = 0.6},
	max_grade = math.rad(17),
	item_desc = S("Right-click to push; Space tips the bed")}
do
	local r = {}
	r[#r + 1] = {4, 12, 22, 8, c}; r[#r + 1] = {2, 10, 26, 2, "#5a4a30"}
	V.icon_wheel(r, 15, 24, 4)
	cart.inv_image = V.icon(r)
end
do
	local wheel = {V.TREAD, V.TREAD, V.WHEEL, V.WHEEL, V.TREAD, V.TREAD}
	local wood = box_tex("#5a4a30")
	local body = {
		{pos = {x = 0, y = -0.45, z = -1.6}, size = {x = 0.9, y = 0.1, z = 1.8}, tex = wood},       -- 車斗下的底架
		{pos = {x = 0, y = -0.6, z = -2.1}, size = {x = 0.25, y = 0.6, z = 0.6}, tex = wheel},      -- 前面的輪子
		{pos = {x = -0.45, y = -0.15, z = -0.25}, size = {x = 0.1, y = 0.1, z = 1.1}, tex = wood},  -- 兩根握把，伸到人手上
		{pos = {x = 0.45, y = -0.15, z = -0.25}, size = {x = 0.1, y = 0.1, z = 1.1}, tex = wood},
	}
	V.hauler(cart, {
		hinge = {x = 0, y = -0.4, z = -2.4}, size = {x = 1.5, y = 0.8, z = 1.6}, body = body,
		floor_tex = "[fill:16x16:#4a3a24",
		side_tex = ("[fill:16x16:%s^[fill:16x2:0,0:#5a4a30"):format(c),
		overlap_lat = {-0.7, 0, 0.7}, overlap_dy = {0.6, 1.2}, aim_top = 0.4,
	})
	function cart.hud(self) return "\n" .. S("Space: tip the bed forward") end
end
V.register("cart", cart)
