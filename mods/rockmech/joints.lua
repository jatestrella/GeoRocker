-- rockmech/joints.lua
-- 節理幾何（純函式，不依賴引擎）。
--
-- ## 座標系
-- Luanti 世界座標：+x = 東 (E)，+y = 上 (Up)，+z = 北 (N)。
-- （注意這是左手系；本檔只用內積，不受手性影響。之後若用外積求
--   走向/法向，需記得 E×N 在 Luanti 中指向 -y。）
--
-- 地質慣例：傾向 α 由北順時針量測（N=0°, E=90°, S=180°, W=270°），
-- 傾角 δ 由水平往下量測。
--
--   水平方位 α 的單位向量（Luanti）: (sin α, 0, cos α)
--   順傾向往下的單位向量 d          : (sin α·cos δ, -sin δ, cos α·cos δ)
--   走向（右手法則，α-90°）s        : (-cos α, 0, sin α)
--   平面向上的法向量（極點）n       : (sin α·sin δ, cos δ, cos α·sin δ)
--
-- 檢查：δ=0 → n=(0,1,0)；α=90°, δ=90° → n=(1,0,0)（朝東的直立面）。
--
-- ## 節理面判定
-- 一組節理是一族平行平面 n·p = (k - φ)·S，k 為整數平面編號，S 為間距，
-- φ ∈ [0,1) 為該組相位（由世界種子決定，或由 offset 指定）。
-- 令 s(p) = n·p / S + φ。相鄰兩格中心 p1, p2 之間的面被該組切過
-- ⇔ floor(s(p1)) ≠ floor(s(p2))，平面編號 k = max(floor(s1), floor(s2))。
-- 因 S ≥ 1 且 |n·(p2-p1)| ≤ 1，同一組在一個面上最多只切過一個平面。
--
-- ## 延續性
-- r = hash01(seed, set_id, k, fx, fy, fz, axis)，r < persistence 才算節理。
-- (fx,fy,fz) 為面「負側」那格的座標，axis ∈ {1,2,3} 對應 x,y,z。
-- 種子固定則結果固定；不需儲存任何資料。

local joints = {}

local floor = math.floor
local sin, cos, rad = math.sin, math.cos, math.rad

---------------------------------------------------------------------------
-- 決定性雜湊（不使用位元運算，Lua 5.1 / LuaJIT / 5.4 皆可得相同結果）
---------------------------------------------------------------------------
local TWO32 = 4294967296
local TWO16 = 65536

-- (a*b) mod 2^32，a, b ∈ [0, 2^32)。所有中間值 < 2^53，double 精確。
local function mul32(a, b)
	local bl = b % TWO16
	local bh = (b - bl) / TWO16
	return (a * bl + ((a * bh) % TWO16) * TWO16) % TWO32
end

-- 32-bit 混合函式：仿 lowbias32，用「加上右移」取代 xor 以避免位元運算。
local function mix(h)
	h = (h + floor(h / 65536)) % TWO32
	h = mul32(h, 0x7feb352d)
	h = (h + floor(h / 32768)) % TWO32
	h = mul32(h, 0x846ca68b)
	h = (h + floor(h / 65536)) % TWO32
	return h
end

-- 整數參數 → [0, 2^32) 整數
function joints.hash(...)
	local h = 0x9e3779b9
	local n = select("#", ...)
	for i = 1, n do
		local v = select(i, ...)
		h = mix((h + floor(v) % TWO32) % TWO32)
	end
	return h
end

-- 整數參數 → [0, 1)
function joints.hash01(...)
	return joints.hash(...) / TWO32
end

-- 世界種子字串（可能超過 2^53）→ 32-bit 整數。逐字元雜湊以免精度損失。
function joints.seed_from_string(s)
	s = tostring(s or "0")
	local h = 0x2545f491
	for i = 1, #s do
		h = mix((h + s:byte(i)) % TWO32)
	end
	return h
end

---------------------------------------------------------------------------
-- 向量
---------------------------------------------------------------------------

-- 平面的向上法向量（極點），Luanti 座標
function joints.normal(dip, dipdir)
	local d, a = rad(dip), rad(dipdir)
	return {x = sin(a) * sin(d), y = cos(d), z = cos(a) * sin(d)}
end

-- 順傾向往下的單位向量（平面滑動方向）
function joints.dip_vector(dip, dipdir)
	local d, a = rad(dip), rad(dipdir)
	return {x = sin(a) * cos(d), y = -sin(d), z = cos(a) * cos(d)}
end

-- 走向單位向量（右手法則：走向 = 傾向 - 90°）
function joints.strike_vector(dipdir)
	local a = rad(dipdir)
	return {x = -cos(a), y = 0, z = sin(a)}
end

---------------------------------------------------------------------------
-- 節理組前處理
---------------------------------------------------------------------------

-- sets: config 的節理組陣列；seed: 32-bit 整數。
-- 回傳前處理後的陣列（原表不修改），每組多出：
--   n, nx, ny, nz, inv_s (=1/spacing), phase, dvec
function joints.prepare(sets, seed)
	local out = {}
	for i, js in ipairs(sets) do
		local p = {}
		for k, v in pairs(js) do p[k] = v end
		p.index = i
		p.n = joints.normal(js.dip, js.dipdir)
		p.nx, p.ny, p.nz = p.n.x, p.n.y, p.n.z
		p.n_axis = {p.nx, p.ny, p.nz}
		p.inv_s = 1 / js.spacing
		if js.offset then
			p.phase = (js.offset / js.spacing) % 1
		else
			p.phase = joints.hash01(seed, js.id, 0x5eed)
		end
		p.dvec = joints.dip_vector(js.dip, js.dipdir)
		p.seed = seed
		out[i] = p
	end
	return out
end

-- 位置 (x,y,z) 的平面座標 s = n·p/S + φ
function joints.plane_coord(js, x, y, z)
	return (js.nx * x + js.ny * y + js.nz * z) * js.inv_s + js.phase
end

-- 第 k 號平面上距原點最近的點（除錯用）：n·p = (k - φ)·S
function joints.plane_distance(js, k)
	return (k - js.phase) * js.spacing
end

-- 軸向單位位移
joints.AXIS = {
	{1, 0, 0}, -- 1: x (東)
	{0, 1, 0}, -- 2: y (上)
	{0, 0, 1}, -- 3: z (北)
}

-- 六個面方向：{名稱, axis, sign}
-- sign = +1：面在 (x,y,z) 與 (x,y,z)+e 之間；-1：在 (x,y,z)-e 與 (x,y,z) 之間
joints.FACES = {
	{name = "E",  axis = 1, sign =  1},
	{name = "W",  axis = 1, sign = -1},
	{name = "Up", axis = 2, sign =  1},
	{name = "Dn", axis = 2, sign = -1},
	{name = "N",  axis = 3, sign =  1},
	{name = "S",  axis = 3, sign = -1},
}

-- 面 (x,y,z | axis) = 格 (x,y,z) 與 (x,y,z)+e_axis 之間的面。
-- 回傳此組切過該面的平面編號 k，以及延續性雜湊值 r；未切過回傳 nil。
function joints.face_crossing(js, x, y, z, axis)
	local s1 = (js.nx * x + js.ny * y + js.nz * z) * js.inv_s + js.phase
	local s2 = s1 + js.n_axis[axis] * js.inv_s
	local k1, k2 = floor(s1), floor(s2)
	if k1 == k2 then return nil end
	local k = k1 > k2 and k1 or k2
	local r = joints.hash01(js.seed, js.id, k, x, y, z, axis)
	return k, r
end

-- 該組是否在此面形成節理（含延續性判斷）
function joints.face_is_joint_set(js, x, y, z, axis)
	local k, r = joints.face_crossing(js, x, y, z, axis)
	return k ~= nil and r < js.persistence, k, r
end

-- 面上是否有任何一組節理。回傳第一個成立的組索引或 nil。
-- （階段 3 建圖用的熱路徑）
function joints.face_joint(sets, x, y, z, axis)
	for i = 1, #sets do
		local js = sets[i]
		local s1 = (js.nx * x + js.ny * y + js.nz * z) * js.inv_s + js.phase
		local s2 = s1 + js.n_axis[axis] * js.inv_s
		local k1, k2 = floor(s1), floor(s2)
		if k1 ~= k2 then
			local k = k1 > k2 and k1 or k2
			if joints.hash01(js.seed, js.id, k, x, y, z, axis) < js.persistence then
				return i
			end
		end
	end
	return nil
end

-- 面上所有切過的組（含未達延續性者），供除錯工具使用。
-- 回傳 {{set=index, k=, r=, joint=bool}, ...}
function joints.face_info(sets, x, y, z, axis)
	local out = {}
	for i = 1, #sets do
		local js = sets[i]
		local k, r = joints.face_crossing(js, x, y, z, axis)
		if k then
			out[#out + 1] = {set = i, k = k, r = r, joint = r < js.persistence}
		end
	end
	return out
end

-- 以格座標與面方向（joints.FACES 的元素）換算成 (fx,fy,fz,axis)
function joints.face_key(x, y, z, face)
	if face.sign > 0 then
		return x, y, z, face.axis
	end
	local e = joints.AXIS[face.axis]
	return x - e[1], y - e[2], z - e[3], face.axis
end

---------------------------------------------------------------------------
-- 節理遮罩（給材質變體用）
---------------------------------------------------------------------------
-- 每格 6 個面各一個位元：E=1 W=2 Up=4 Dn=8 N=16 S=32（順序同 joints.FACES）
joints.MASK = {E = 1, W = 2, Up = 4, Dn = 8, N = 16, S = 32}

-- 格 (x,y,z) 的節理遮罩 0..63
function joints.cell_mask(sets, x, y, z)
	local m = 0
	if joints.face_joint(sets, x, y, z, 1) then m = m + 1 end
	if joints.face_joint(sets, x - 1, y, z, 1) then m = m + 2 end
	if joints.face_joint(sets, x, y, z, 2) then m = m + 4 end
	if joints.face_joint(sets, x, y - 1, z, 2) then m = m + 8 end
	if joints.face_joint(sets, x, y, z, 3) then m = m + 16 end
	if joints.face_joint(sets, x, y, z - 1, 3) then m = m + 32 end
	return m
end

function joints.has_bit(mask, bit)
	return math.floor(mask / bit) % 2 == 1
end

-- Luanti 方塊 6 個面（tiles 順序 +Y, -Y, +X, -X, +Z, -Z）的貼圖邊緣對應的方位位元。
-- self：此面本身是節理面時上色；top/bottom/left/right：貼圖該邊緣對應的側面，
-- 那個側面是節理時，在這條邊畫跡線。
-- 推導：從外側看該面、貼圖不鏡像；側面的貼圖上方 = +y；
-- Luanti 為左手系，right = up × forward（forward 為視線方向）。
--   頂面：視線 −y、上方 +z → 右 = +x
--   東面：視線 −x → 右 = +z；西面 → 右 = −z
--   北面：視線 −z → 右 = −x；南面 → 右 = +x
--   底面：假設貼圖上方 = −z → 右 = +x（未經畫面確認，見 /rockmech_jointtex_demo）
local M = joints.MASK
joints.TILE_EDGES = {
	{self = M.Up, top = M.N,  bottom = M.S,  left = M.W, right = M.E}, -- +Y
	{self = M.Dn, top = M.S,  bottom = M.N,  left = M.W, right = M.E}, -- -Y
	{self = M.E,  top = M.Up, bottom = M.Dn, left = M.S, right = M.N}, -- +X
	{self = M.W,  top = M.Up, bottom = M.Dn, left = M.N, right = M.S}, -- -X
	{self = M.N,  top = M.Up, bottom = M.Dn, left = M.E, right = M.W}, -- +Z
	{self = M.S,  top = M.Up, bottom = M.Dn, left = M.W, right = M.E}, -- -Z
}

return joints
