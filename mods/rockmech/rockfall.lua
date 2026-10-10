-- rockmech/rockfall.lua
-- 落石翻滾的物理（純函式，不依賴引擎）。概念同集中質量落石分析（RocFall / CRSP）：
--   飛行：只受重力（引擎以 acceleration 處理）。
--   撞擊：速度分解為坡面法向 vn 與切向 vt，vn' = -Rn·vn，vt' = Rt·vt；
--         撞擊後角速度 ω = |vt'| / r（轉成滾動）。
--   貼地滾動：加速度 = 重力沿坡面分量 − μr·g·cosθ（與速度反向）。
--   停止：貼地且速度 < v_stop 持續一段時間。
-- 回彈係數與滾動阻力取「被撞擊的坡面材料」的值。
--
-- 向量為 {x=,y=,z=}，座標系同 Luanti（y 向上）。

local rockfall = {}

local sqrt = math.sqrt
local atan2 = math.atan2 or math.atan -- Lua 5.4 移除了 atan2

local function dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
local function scale(a, s) return {x = a.x * s, y = a.y * s, z = a.z * s} end
local function add(a, b) return {x = a.x + b.x, y = a.y + b.y, z = a.z + b.z} end
local function sub(a, b) return {x = a.x - b.x, y = a.y - b.y, z = a.z - b.z} end
local function len(a) return sqrt(dot(a, a)) end
local function normalize(a)
	local l = len(a)
	if l == 0 then return {x = 0, y = 1, z = 0} end
	return scale(a, 1 / l)
end
rockfall.dot, rockfall.len, rockfall.normalize = dot, len, normalize

rockfall.G = 9.81
rockfall.RADIUS = 0.5

-- 由周圍地表高度估計坡面法向（中央差分）。
-- h_xm, h_xp, h_zm, h_zp：x-1、x+1、z-1、z+1 欄的地表高度；缺值傳 nil 時以 h0 代替。
function rockfall.surface_normal(h0, h_xm, h_xp, h_zm, h_zp)
	h_xm, h_xp = h_xm or h0, h_xp or h0
	h_zm, h_zp = h_zm or h0, h_zp or h0
	local hx = (h_xp - h_xm) / 2
	local hz = (h_zp - h_zm) / 2
	return normalize({x = -hx, y = 1, z = -hz})
end

-- 坡度角 θ（rad）
function rockfall.slope_angle(n)
	return math.acos(math.max(-1, math.min(1, n.y)))
end

-- 撞擊：v 為撞擊前速度，n 為坡面單位法向（指向離開坡面的一側）。
-- 回傳 撞擊後速度, 撞擊法向速度大小 |vn|（≥ 0）, 撞擊後切向速度
function rockfall.impact(v, n, rn, rt)
	local vn_s = dot(v, n)            -- < 0 表示朝坡面運動
	local vn = scale(n, vn_s)
	local vt = sub(v, vn)
	local vt_out = scale(vt, rt)
	local v_out = add(vt_out, scale(n, -rn * vn_s))
	return v_out, math.abs(vn_s), vt_out
end

-- 貼地時的加速度（不含引擎已施加的垂直重力 -g）。
-- 回傳要額外加上的加速度：重力切向分量的水平部分 + 滾動阻力。
-- 靜止（|v| 很小）時，若切向重力 ≤ μr·g·cosθ 則不動（回傳零向量）。
function rockfall.contact_accel(v, n, mu, g)
	g = g or rockfall.G
	local cos_t = n.y
	-- 重力 (0,-g,0) 的切向分量 g_t = g_vec - (g_vec·n) n = (g·n.y)·n + (0,-g,0)
	local gt = {x = g * cos_t * n.x, y = -g + g * cos_t * n.y, z = g * cos_t * n.z}
	local gt_mag = len(gt)
	local fr = mu * g * cos_t        -- 滾動阻力大小
	local speed = len(v)
	local a
	if speed < 1e-3 then
		if gt_mag <= fr then
			a = {x = 0, y = 0, z = 0}
		else
			a = scale(gt, (gt_mag - fr) / gt_mag)
		end
	else
		a = sub(gt, scale(v, fr / speed))
	end
	-- 引擎已對物體施加 (0,-g,0)；貼地時垂直分量由碰撞抵銷，
	-- 這裡只補上水平分量（切向重力造成的下坡加速 + 阻力的水平部分）
	return {x = a.x, y = 0, z = a.z}
end

-- 滾動角速度大小 (rad/s)
function rockfall.roll_rate(vt, r)
	return len(vt) / (r or rockfall.RADIUS)
end

-- 由速度方向算 yaw（Luanti：yaw 0 朝 +z，逆時針為正）
function rockfall.heading_yaw(v)
	if v.x == 0 and v.z == 0 then return nil end
	return atan2(-v.x, v.z)
end

-- 外觀旋轉向量（給 ObjectRef:set_rotation）。
-- set_rotation 為右手系 Z-X-Y：yaw 決定朝向（本地 +z 指向前進方向），
-- 正 pitch 會讓物體頂部往本地 -z（後方）倒——已用 builtin vector.rotate 驗證：
--   rotate((0,1,0), {x=0.3,y=0,z=0}) = (0, 0.96, -0.30)。
-- 因此向前滾動（頂部往前）須用負的 pitch。
function rockfall.roll_rotation(roll, yaw)
	return {x = -roll, y = yaw, z = 0}
end

rockfall.add, rockfall.sub, rockfall.scale = add, sub, scale

return rockfall
