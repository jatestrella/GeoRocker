-- rockmech/vehicle_suv.lua
-- 四輪驅動休旅車（代步用）。由 vehicles.lua 載入。
-- 只載人：沒有車斗、沒有作業鍵。輕、快（直線加速到約 79 km/h），四輪驅動爬坡可到 30°（卡車、礦卡 17°）。
-- 太輕不會壓實碎石（rockmech_compact_mass），在鬆碎石上一樣會壓出淺車轍。

local V = rockmech.vehicles
local S = rockmech.S
local box_tex = V.box_tex
local WHEEL, TREAD = V.WHEEL, V.TREAD

local c = "#3a5a8a"
local def = {desc = S("4WD SUV"), short = S("SUV"), color = c, cap = 0, speed = 6,
	top_speed = 22, accel = 3,    -- 直線加速到約 79 km/h
	max_grade = math.rad(30),     -- 四輪驅動
	tire = 0.75,
	half = 1.0, top = 0.8, lat = {-0.6, 0.6}, eye_up = 1.1, eye_fwd = 0.15, rear = 3.5,
	seat = {x = -0.45, y = 0, z = -0.7},      -- 駕駛（左前，左駕）；乘客：副駕駛、後座兩人
	passengers = {{x = 0.45, y = 0, z = -0.7, front = true}, {x = -0.45, y = 0, z = -1.9}, {x = 0.45, y = 0, z = -1.9}},
	mirror = {x = 1.1, y = 0.5, z = -0.1}, rearcam = {x = 0, y = 0.6, z = -3.6},   -- 後照鏡（A 柱旁）、倒車攝影機（車尾）
	exhaust = {x = 0.6, y = -0.55, z = -3.6},     -- 排氣管：車尾下方右側
	tilt = {front = 0.9, rear = -3.0, side_z = -1.2, side_x = 0.8},
	tail_lat = {-0.8, 0, 0.8}, tail_dy = {0.6, 1.2},
	item_desc = S("Right-click to get in")}
do   -- 圖示：車身、車窗、兩個輪子
	local r = {}
	r[#r + 1] = {2, 14, 27, 8, c}
	r[#r + 1] = {6, 8, 18, 7, c}; r[#r + 1] = {8, 9, 6, 5, "#9fd0ff"}; r[#r + 1] = {16, 9, 6, 5, "#9fd0ff"}
	r[#r + 1] = {27, 15, 2, 2, "#f0e070"}
	V.icon_wheel(r, 8, 23, 4); V.icon_wheel(r, 23, 23, 4)
	def.inv_image = V.icon(r)
end
do
	local glass = "[fill:16x16:%s^[fill:12x9:2,2:#9fd0ff"
	local side = (glass .. "^[fill:2x9:7,2:%s"):format(c, c)
	local front = (glass):format(c)
	local nose = ("[fill:16x16:%s^[fill:4x3:1,4:#f0e070^[fill:4x3:11,4:#f0e070^[fill:6x2:5,10:#2a2a2a"):format(c)
	local tail = ("[fill:16x16:%s^[fill:3x3:1,4:#c03030^[fill:3x3:12,4:#c03030"):format(c)
	local paint = ("[fill:16x16:%s"):format(c)
	local wheel = {TREAD, TREAD, WHEEL, WHEEL, TREAD, TREAD}
	def.parts = {
		-- 下半車身（車頭 z +1.0 到車尾 −3.5）
		{pos = {x = 0, y = -0.3, z = -1.25}, size = {x = 2.0, y = 0.7, z = 4.5}, tex = {paint, "[fill:16x16:#2a2a2a", paint, paint, tail, nose}},
		-- 車廂（擋風玻璃在 z = 0，相機在它前面、引擎蓋上方）
		{pos = {x = 0, y = 0.4, z = -1.5}, size = {x = 1.9, y = 0.7, z = 3.0}, tex = {paint, paint, side, side, front, front}},
	}
	for _, w in ipairs({{x = -0.95, z = 0.35}, {x = 0.95, z = 0.35}, {x = -0.95, z = -2.6}, {x = 0.95, z = -2.6}}) do
		def.parts[#def.parts + 1] = {pos = {x = w.x, y = -0.62, z = w.z}, size = {x = 0.3, y = 0.75, z = 0.75}, tex = wheel}
	end
end
-- 擋人：車身後段（碰撞箱後方）
def.overhangs = {{x0 = -1.0, x1 = 1.0, z0 = -3.5, z1 = -1.0, y0 = -1.0, y1 = 0.8, body = "z1"}}
function def.hud() return "  " .. S("Personnel carrier") end

V.register("suv", def)
