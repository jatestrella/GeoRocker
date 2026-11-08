-- rockmech/airflow.lua
-- 空氣品質（純函式，不依賴引擎）：只追蹤有污染的地方。
--
-- 世界切成 CELL³ 的格子（cell）。每格記一個值 m：裡面的有害氣體體積（m³，以 CO 當量算）；
-- 濃度 ppm = m ÷ 格子裡的空氣體積 V × 10⁶。沒被追蹤的格子都是乾淨空氣（0 ppm）。
-- 每一步：
--   擴散：相鄰兩格交換 K × A × Δt × (c₁ − c₂)；A = 兩格交界面上兩邊都是空氣的格數（m²）。
--         開放空間六個面都通、很快就淡掉；隧道只有前後兩面通，越深越散不掉；死巷、工作面最容易堆積
--   風：  看得到天空的空氣被風吹走，每秒帶走 W × 看得到天空的比例
--   風機：沿著風管的路線（格子序列）把空氣往風管口推，風管口吸進去排到外面（抽出式通風）
--   濃度 < DROP ppm 的格子就不再追蹤
--
-- 來源：
--   柴油引擎：每燒 1 L 柴油放出 DIESEL_CO m³。校準成「每 kW 給 0.06 m³/s 新鮮風量」
--             （常見的柴油機具稀釋通風量法規）時，滿載的濃度剛好是 CO 的 8 小時容許濃度 25 ppm
--   炸藥：    每 kg 放出 BLAST_CO m³（炮煙，CO 當量）

local A = {}

A.CELL = 8
A.K = 0.05             -- 擴散（m/s）：每 m² 通的交界面、每 1 的濃度差，每秒交換的空氣（m³）
A.WIND = 0.05          -- 風（1/s）：整格都看得到天空時，每秒吹走 5%
A.DROP = 1             -- 低於這個 ppm 的格子不再追蹤
A.LIMIT_PPM = 25       -- CO 8 小時容許濃度
A.DILUTION = 0.06      -- 柴油機具稀釋通風量（m³/s per kW）
A.BSFC = 0.22          -- 柴油引擎比油耗（L/kWh），跟 fuel.lua 一樣
A.DIESEL_CO = A.LIMIT_PPM * 1e-6 * A.DILUTION / (A.BSFC / 3600)   -- ≈ 0.0245 m³/L
A.BLAST_CO = 0.04      -- 炮煙（m³/kg 炸藥）

local DIRS = {{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}}
A.DIRS = DIRS

function A.key(x, y, z) return x .. "," .. y .. "," .. z end
function A.cell_of(p)
	local C = A.CELL
	return math.floor(p.x / C), math.floor(p.y / C), math.floor(p.z / C)
end
function A.key_of(p) return A.key(A.cell_of(p)) end

function A.ppm(cell) return cell.v > 0 and cell.m / cell.v * 1e6 or 0 end

-- state = {cells = {key → {x, y, z, m, v, sky}}}
-- geo：引擎那邊提供的地形
--   geo.vol(x, y, z) → 空氣體積（m³），geo.sky(x, y, z) → 看得到天空的比例 0..1，
--   geo.face(x, y, z, d) → 跟 DIRS[d] 方向那格的交界面上通的面積（m²）
function A.new() return {cells = {}} end

local function get(state, geo, x, y, z)
	local k = A.key(x, y, z)
	local c = state.cells[k]
	if not c then
		local v = geo.vol(x, y, z)
		if v <= 0 then return nil end
		c = {x = x, y = y, z = z, m = 0, v = v, sky = geo.sky(x, y, z)}
		state.cells[k] = c
	end
	return c
end
A.get = get

-- 在 (x, y, z) 那格放出 m3 的有害氣體；那格沒有空氣就放不進去（回傳 false）
function A.emit(state, geo, x, y, z, m3)
	local c = get(state, geo, x, y, z)
	if not c then return false end
	c.m = c.m + m3
	return true
end

-- fans：{{path = {{x, y, z}, ...}（從風機那端到風管口）, q = m³/s}, ...}
function A.step(state, geo, dt, fans)
	local cells = state.cells
	-- 擴散：先算每一對交界面的交換量（用這一步開始時的濃度），再一起加上去
	local delta, new = {}, {}
	for k, c in pairs(cells) do
		local cc = c.m / c.v
		for d = 1, 6 do
			local dx, dy, dz = DIRS[d][1], DIRS[d][2], DIRS[d][3]
			local nx, ny, nz = c.x + dx, c.y + dy, c.z + dz
			local nk = A.key(nx, ny, nz)
			local n = cells[nk]
			-- 兩格都有追蹤：只算一次（key 小的那格算）；沒追蹤的鄰居 = 乾淨空氣
			if not n or k < nk then
				local area = geo.face(c.x, c.y, c.z, d)
				if area > 0 then
					local nv = n and n.v or new[nk] and new[nk].v or geo.vol(nx, ny, nz)
					if nv > 0 then
						local cn = n and n.m / n.v or 0
						local f = A.K * area * dt * (cc - cn)
						-- 不要一步交換過頭：最多交換到兩邊一樣濃的 1/7（一格最多 6 個面同時在換）
						local cap = math.abs(cc - cn) / (1 / c.v + 1 / nv) / 7
						if f > cap then f = cap elseif f < -cap then f = -cap end
						if f ~= 0 then
							delta[k] = (delta[k] or 0) - f
							if not n and not new[nk] then
								new[nk] = {x = nx, y = ny, z = nz, m = 0, v = nv, sky = geo.sky(nx, ny, nz)}
							end
							delta[nk] = (delta[nk] or 0) + f
						end
					end
				end
			end
		end
	end
	for nk, c in pairs(new) do cells[nk] = c end
	for k, dm in pairs(delta) do
		local c = cells[k]
		c.m = math.max(0, c.m + dm)
	end
	-- 風
	for _, c in pairs(cells) do
		if c.sky > 0 then c.m = c.m * math.max(0, 1 - A.WIND * c.sky * dt) end
	end
	-- 風機：路線上每一格把 q·Δt 的空氣（連同裡面的氣體）推給下一格，最後一格被風管口吸走
	local removed = 0
	for _, fan in ipairs(fans or {}) do
		local path = fan.path
		local moved = {}
		for i, p in ipairs(path) do
			local c = cells[A.key(p[1], p[2], p[3])]
			if c and c.m > 0 then
				local frac = math.min(0.5, fan.q * dt / c.v)
				moved[i] = c.m * frac
				c.m = c.m - moved[i]
			end
		end
		for i, f in pairs(moved) do
			local nxt = path[i + 1]
			local c = nxt and get(state, geo, nxt[1], nxt[2], nxt[3])
			if c then c.m = c.m + f else removed = removed + f end
		end
	end
	-- 淡到看不出來就不追蹤；但旁邊還濃的話先留著（擴散的最前緣，丟掉的話每一步都漏一點）
	local drop = {}
	for k, c in pairs(cells) do
		if A.ppm(c) < A.DROP then
			local keep = false
			for d = 1, 6 do
				local n = cells[A.key(c.x + DIRS[d][1], c.y + DIRS[d][2], c.z + DIRS[d][3])]
				if n and A.ppm(n) >= A.DROP then keep = true; break end
			end
			if not keep then drop[#drop + 1] = k end
		end
	end
	for _, k in ipairs(drop) do cells[k] = nil end
	return removed
end

-- 炸藥量（kg）→ 放出的炮煙（m³）；燒掉的柴油（L）→ 放出的廢氣（m³）
function A.blast_m3(kg) return kg * A.BLAST_CO end
function A.diesel_m3(litre) return litre * A.DIESEL_CO end

return A
