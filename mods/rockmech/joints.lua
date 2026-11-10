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
-- 一組節理是一族平行平面。為了讓跡線材質在方塊間完美連接，法向量對齊到
-- 整數格點 m（見 joints.prepare），平面寫成 m·p + o = L·k（k 為平面編號）。
-- 相鄰兩格中心 p1, p2 之間的面被該組切過
-- ⇔ floor((m·p1+o)/L) ≠ floor((m·p2+o)/L)，平面編號 k 取兩者較大者。
-- 因 L ≥ max|m_i|，同一組在一個面上最多只切過一個平面。
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

-- 雜湊前綴：hash(a, b, …) 的中間狀態，之後可接著混入其餘參數
function joints.hash_prefix(...)
	local h = 0x9e3779b9
	for i = 1, select("#", ...) do
		h = mix((h + floor(select(i, ...)) % TWO32) % TWO32)
	end
	return h
end

-- 面的延續性雜湊（熱路徑）：等同 hash01(js.seed, js.id, k, x, y, z, axis)，
-- 但 (seed, id) 已預先混入 js.hp，且不用可變參數。
-- 片狀延續性（js.patch = P）：同一個平面 k 在同一個 P×P×P 粗格內共用一個值
-- （一整片要嘛是節理、要嘛是岩橋），與面的方向無關。
local function face_hash01(js, k, x, y, z, axis)
	local P = js.patch
	if P then
		x, y, z, axis = (x - x % P) / P, (y - y % P) / P, (z - z % P) / P, 0
	end
	local h = js.hp
	h = mix((h + k % TWO32) % TWO32)
	h = mix((h + x % TWO32) % TWO32)
	h = mix((h + y % TWO32) % TWO32)
	h = mix((h + z % TWO32) % TWO32)
	h = mix((h + axis % TWO32) % TWO32)
	return h / TWO32
end
joints.face_hash01 = face_hash01
joints.mix = mix

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
-- 節理組前處理（格點對齊）
---------------------------------------------------------------------------
-- 為了讓節理跡線在方塊之間完美連接，平面的法向量對齊到整數格點：
--   m = round(n · D)（整數向量，D 為格點密度 lattice，預設 8）
-- 平面族寫成 m·p + o = L·k（k 為整數平面編號），其中
--   L = round(S · |m|)（整數），有效間距 S_eff = L / |m|
--   o ∈ [0, L) 為整數相位（由世界種子決定，或由 offset 指定）
-- 格中心 p 為整數 → m·p + o 為整數 → 平面編號以整數除法精確求得。
-- 有效位態（dip_eff / dipdir_eff）由 m 反算，與輸入值差約 1°（D=8）。
--
-- sets: config 的節理組陣列；seed: 32-bit 整數；lattice: D（預設 8）。
-- persistence_mode: "patch"（片狀延續性，片的大小 ≈ 間距）或 "face"（舊：每個格面各自判定）。
-- opts.dfn（dfn.lua 模組）：改用離散裂隙網路（圓盤），回傳的陣列多一個 .dfn 物件；
--   opts.where(x, y, z) → 地質區編號（組的 zone）、opts.cell 粗格大小。有效位態 = 輸入位態（不對齊格點）。
-- 回傳前處理後的陣列（原表不修改），每組多出：
--   n（輸入位態的單位法向）、mx,my,mz、m_axis、L、o、
--   n_eff、dip_eff、dipdir_eff、spacing_eff、dvec（有效位態的順傾向向量）
function joints.prepare(sets, seed, lattice, persistence_mode, opts)
	local D = lattice or 8
	local out = {}
	for i, js in ipairs(sets) do
		local p = {}
		for k, v in pairs(js) do p[k] = v end
		p.index = i
		p.tanphi = js.phi and math.tan(math.rad(js.phi)) or nil      -- 這一組的摩擦係數（滑動、楔形、關鍵塊體用）
		p.n = joints.normal(js.dip, js.dipdir)
		local mx = floor(p.n.x * D + 0.5)
		local my = floor(p.n.y * D + 0.5)
		local mz = floor(p.n.z * D + 0.5)
		if mx == 0 and my == 0 and mz == 0 then my = 1 end
		p.mx, p.my, p.mz = mx, my, mz
		p.m_axis = {mx, my, mz}
		local mlen = math.sqrt(mx * mx + my * my + mz * mz)
		p.L = math.max(1, floor(js.spacing * mlen + 0.5))
		-- 保證同一組在一個面上最多只切過一個平面：L ≥ max|m_i|
		p.L = math.max(p.L, math.abs(mx), math.abs(my), math.abs(mz))
		if js.offset then
			p.o = floor(js.offset * mlen + 0.5) % p.L
		else
			p.o = floor(joints.hash01(seed, js.id, 0x5eed) * p.L)
		end
		p.n_eff = {x = mx / mlen, y = my / mlen, z = mz / mlen}
		p.dip_eff = math.deg(math.acos(math.max(-1, math.min(1, p.n_eff.y))))
		p.dipdir_eff = (math.deg(math.atan2 and math.atan2(mx, mz) or math.atan(mx, mz))) % 360
		if mx == 0 and mz == 0 then p.dipdir_eff = js.dipdir end
		p.spacing_eff = p.L / mlen
		p.dvec = joints.dip_vector(p.dip_eff, p.dipdir_eff)
		p.seed = seed
		p.hp = joints.hash_prefix(seed, js.id)
		if persistence_mode == "patch" then
			p.patch = math.max(2, floor(p.spacing_eff + 0.5))
		end
		if opts and opts.dfn then
			p.dfn = true
			p.n_eff, p.dip_eff, p.dipdir_eff, p.spacing_eff = p.n, js.dip, js.dipdir, js.spacing
			p.dvec = joints.dip_vector(js.dip, js.dipdir)
			p.patch = nil
		end
		out[i] = p
	end
	if opts and opts.dfn then
		out.dfn = opts.dfn.new(out, seed, {mix = mix, hash = joints.hash, where = opts.where, cell = opts.cell})
	end
	return out
end

-- 整數除法取下界（Lua 5.1 / 5.4 皆精確；L > 0）
local function idiv(a, L)
	return (a - a % L) / L
end
joints.idiv = idiv

-- 位置 (x,y,z) 的平面座標 s = (m·p + o) / L（平面位於 s 為整數處）
function joints.plane_coord(js, x, y, z)
	return (js.mx * x + js.my * y + js.mz * z + js.o) / js.L
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
	local a1 = js.mx * x + js.my * y + js.mz * z + js.o
	local a2 = a1 + js.m_axis[axis]
	local k1, k2 = idiv(a1, js.L), idiv(a2, js.L)
	if k1 == k2 then return nil end
	local k = k1 > k2 and k1 or k2
	return k, face_hash01(js, k, x, y, z, axis)
end

-- 該組是否在此面形成節理（含延續性判斷）
function joints.face_is_joint_set(js, x, y, z, axis)
	local k, r = joints.face_crossing(js, x, y, z, axis)
	return k ~= nil and r < js.persistence, k, r
end

-- 面上是否有任何一組節理。回傳第一個成立的組索引或 nil。
-- （階段 3 建圖用的熱路徑）
-- sets.skip(x, y, z)（可選）：這一格不帶節理（例如煤層）。面的任一側是這種格子，面就不是節理
local AX = {{1, 0, 0}, {0, 1, 0}, {0, 0, 1}}
local function skipped(sets, x, y, z, axis)
	local skip = sets.skip
	if not skip then return false end
	local e = AX[axis]
	return skip(x, y, z) or skip(x + e[1], y + e[2], z + e[3])
end
joints.face_skipped = skipped

function joints.face_joint(sets, x, y, z, axis)
	local D = sets.dfn
	if D then
		-- 先查圓盤（快），切到了才判斷這兩格帶不帶節理（煤層、斷層角礫岩；要查岩性，比較慢）
		local d = D:face(x, y, z, axis)
		if not d or skipped(sets, x, y, z, axis) then return nil end
		return d.set, d
	end
	if skipped(sets, x, y, z, axis) then return nil end
	for i = 1, #sets do
		local js = sets[i]
		local L = js.L
		local a1 = js.mx * x + js.my * y + js.mz * z + js.o
		local a2 = a1 + js.m_axis[axis]
		local k1, k2 = (a1 - a1 % L) / L, (a2 - a2 % L) / L
		if k1 ~= k2 then
			local k = k1 > k2 and k1 or k2
			if face_hash01(js, k, x, y, z, axis) < js.persistence then
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
	local skip = skipped(sets, x, y, z, axis)
	if sets.dfn then
		-- DFN：k = 圓盤編號、r = 0（圓盤有限大，沒有延續性雜湊）
		for _, d in ipairs(sets.dfn:face_all(x, y, z, axis)) do
			out[#out + 1] = {set = d.set, k = d.id, r = 0, joint = not skip, disc = d}
		end
		return out
	end
	for i = 1, #sets do
		local js = sets[i]
		local k, r = joints.face_crossing(js, x, y, z, axis)
		if k then
			out[#out + 1] = {set = i, k = k, r = r, joint = not skip and r < js.persistence}
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
