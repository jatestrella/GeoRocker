-- rockmech/vehicle_haul.lua
-- 礦卡（中型露天礦用卡車，Cat 773／775 級：載重 55～65 t、車寬約 5 m、輪胎直徑約 2.4 m）。由 vehicles.lua 載入。
-- 5 寬 × 4 高 × 10 長，車斗約 36 m³（卡車的 3 倍）；操作同卡車（空白鍵把車斗倒在車尾），挖土機可以倒進車斗。
-- 原點在碰撞箱（5 × 5 × 4）底面中心上方 2.5 m；車頭 z +2.5、車尾 z −7.5；車底 y −2.5、碰撞箱上緣 y +1.5。
-- 前段：引擎、上方橫跨全寬的平台、平台左側的駕駛室。車斗像真的礦卡：底板後段往車尾上翹（duck tail）、
-- 沒有後擋板；前端的遮罩（canopy）伸到駕駛室上方，抬斗時跟著轉

local V = rockmech.vehicles
local NLEV, box_tex = V.NLEV, V.box_tex

local def = {desc = "礦卡 Haul truck", short = "礦卡", color = "#d89818", cap = 36 * NLEV, speed = 4.5,
	half = 2.5, top = 1.5, lat = {-2, -1, 0, 1, 2}, eye_up = 1.3, eye_fwd = 2.4, rear = 7.5,
	mirror = {x = 2.45, y = 1.3, z = 2.2}, rearcam = {x = 0, y = 1.4, z = -7.7},
	tilt = {front = 1.0, rear = -4.6, side_z = -4.6, side_x = 1.7},
	item_desc = "右鍵上車；空白鍵把車斗倒在車尾（載量 36 m³）"}
def.inv_image = V.inv_icon(def.color, "^[fill:6x4:2,3:#9fd0ff^[fill:16x2:0,0:#8a6a10")   -- 駕駛室窗、遮罩

local WHEEL, TREAD = V.WHEEL, V.TREAD
local c = def.color
local y = ("[fill:16x16:%s"):format(c)
local grille = ("[fill:16x16:#2a2a2a^[fill:14x10:1,2:#3a3a3a^[fill:14x1:1,4:#555555^[fill:14x1:1,7:#555555^[fill:14x1:1,10:#555555"
	.. "^[fill:3x2:1,13:#f0e070^[fill:3x2:12,13:#f0e070")
local win = ("[fill:16x16:%s^[fill:12x7:2,2:#9fd0ff^[fill:16x2:0,14:#2a2a2a"):format(c)
local side = ("[fill:16x16:%s^[fill:9x7:4,2:#9fd0ff^[fill:16x2:0,14:#2a2a2a"):format(c)
local wheel = {TREAD, TREAD, WHEEL, WHEEL, TREAD, TREAD}   -- 上下前後是胎面，左右兩側是輪圈
local body = {
	{pos = {x = 0, y = -1.2, z = -2.2}, size = {x = 1.6, y = 0.8, z = 9.0}, tex = box_tex("#2a2a2a")},     -- 車架
	{pos = {x = 0, y = -0.6, z = 1.5}, size = {x = 2.6, y = 1.8, z = 1.8}, tex = {y, y, y, y, grille, y}},   -- 引擎與水箱
	{pos = {x = 0, y = 0.4, z = 1.5}, size = {x = 4.9, y = 0.2, z = 1.8}, tex = box_tex("#4a4a4a")},       -- 平台
	{pos = {x = -1.45, y = 1.2, z = 1.4}, size = {x = 1.8, y = 1.4, z = 1.6},                             -- 駕駛室（左側）
		tex = {y, "[fill:16x16:#2a2a2a", side, side, win, y}},
	{pos = {x = 1.25, y = 0.95, z = 2.35}, size = {x = 2.3, y = 0.06, z = 0.06}, tex = box_tex("#f0f0f0")}, -- 平台欄杆
	{pos = {x = 1.25, y = 0.75, z = 0.65}, size = {x = 2.3, y = 0.06, z = 0.06}, tex = box_tex("#f0f0f0")},
}
-- 前輪單輪、後輪雙輪（較寬）
for _, w in ipairs({{x = -1.95, z = 1.0, wd = 0.9}, {x = 1.95, z = 1.0, wd = 0.9},
		{x = -1.7, z = -4.6, wd = 1.5}, {x = 1.7, z = -4.6, wd = 1.5}}) do
	body[#body + 1] = {pos = {x = w.x, y = -1.3, z = w.z}, size = {x = w.wd, y = 2.4, z = 2.4}, tex = wheel}
end

-- 車斗：軸心在後端下緣（離地 2.5 m，底板在後輪頂上方 0.1 m），外尺寸 4.6 × 1.5 × 6.6（連堆尖約 36 m³）。各片相對軸心：
-- 底板前段平的、後段 TAIL_L 往車尾上翹 TAIL_RISE（約 16°，沒有後擋板）；側板後段：上半水平、下半是沿著上翹底板的斜條
-- （稍微往內縮，不和上半同一個面，免得閃爍）；裡面的碎石也分前後兩段，後段躺在上翹的底板上；
-- 前擋板往上加高到 CANOPY_Y、再往前接遮罩蓋住平台與駕駛室（駕駛室頂 y 1.9）
local S = {x = 4.6, y = 1.5, z = 6.6}
local T = 0.1
local TAIL_L, TAIL_RISE = 2.4, 0.7
local CANOPY_Y = 2.2
local tail_deg = math.deg(math.atan(TAIL_RISE / TAIL_L))
local tail_len = math.sqrt(TAIL_L ^ 2 + TAIL_RISE ^ 2)
local STRIP_H = 0.8                                -- 側板後段下半斜條的高度（從底板往上）
local plates = {
	{id = "floor_front", rel = {x = 0, y = T / 2, z = (TAIL_L + S.z) / 2}, size = {x = S.x, y = T, z = S.z - TAIL_L}, floor = true},
	{id = "floor_tail", rel = {x = 0, y = TAIL_RISE / 2 + T / 2, z = TAIL_L / 2}, rot = tail_deg,
		size = {x = S.x, y = T, z = tail_len + 0.05}, floor = true},
	{id = "front", rel = {x = 0, y = CANOPY_Y / 2, z = S.z - T / 2}, size = {x = S.x, y = CANOPY_Y, z = T}},
	{id = "canopy", rel = {x = 0, y = CANOPY_Y, z = S.z + 1.5}, size = {x = 4.8, y = 0.12, z = 3.0}},
}
for _, sx in ipairs({-1, 1}) do
	local x = sx * (S.x - T) / 2
	plates[#plates + 1] = {id = "side_front" .. sx, rel = {x = x, y = S.y / 2, z = (TAIL_L + S.z) / 2}, size = {x = T, y = S.y, z = S.z - TAIL_L}}
	plates[#plates + 1] = {id = "side_tail" .. sx, rel = {x = x, y = (S.y + TAIL_RISE) / 2, z = TAIL_L / 2},
		size = {x = T, y = S.y - TAIL_RISE, z = TAIL_L}}
	plates[#plates + 1] = {id = "side_strip" .. sx, rel = {x = x - sx * 0.02, y = TAIL_RISE / 2 + STRIP_H / 2, z = TAIL_L / 2}, rot = tail_deg,
		size = {x = T, y = STRIP_H, z = tail_len}}
end
V.hauler(def, {
	hinge = {x = 0, y = 0.0, z = -7.3}, size = S, body = body, plates = plates,
	fills = {
		{id = "fill_front", z = (TAIL_L + S.z - T - 0.05) / 2, len = S.z - T - 0.05 - TAIL_L, y0 = T},
		{id = "fill_tail", z = TAIL_L / 2, len = tail_len - 0.1, y0 = TAIL_RISE / 2 + T, rot = tail_deg, hmax = 0.6},
	},
	floor_tex = "[fill:16x16:#5a4010",
	side_tex = ("[fill:16x16:%s^[fill:16x2:0,0:#8a6a10^[fill:2x16:3,0:#b88a10^[fill:2x16:8,0:#b88a10^[fill:2x16:13,0:#b88a10"):format(c),
	overlap_lat = {-2.25, -1.1, 0, 1.1, 2.25}, overlap_dy = {1.2, 2.2, 3.2}, aim_top = 1.6, dump_rows = 2,
})
-- 擋人：車斗那段（碰撞箱後方 z −7.5..−2.5）從地面到車斗上緣
def.overhangs = {{x0 = -2.3, x1 = 2.3, z0 = -7.5, z1 = -2.5, y0 = -2.5, y1 = S.y, body = "z1"}}
V.register("haul", def)
