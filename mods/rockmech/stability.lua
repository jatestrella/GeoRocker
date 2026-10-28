-- rockmech/stability.lua
-- 穩定判定（與岩體是否相連）：找出「與大岩體斷開、也沒有坐在其他東西上」的岩石群（純函式，不依賴引擎）。
-- 這是階段 3 關鍵塊搜尋的骨架；目前鍵結只看相鄰的實心岩石，尚未用節理切開。
--
-- ## 規則
-- 從起點（被移除格的鄰格）沿「鍵結格」(bonded) 的面相鄰關係搜尋一群，
-- 符合任一條件即判定有支撐（anchored），立即停止：
--   1. 碰到網格邊界（假設網格外連回大岩體）
--   2. 群內某格的正下方是「群外的實心格」（例如坐在碎石堆上）
--   3. 展開格數超過 max_voxels（大塊體保守視為穩定）
-- 都不符合 → 整群懸空，應掉落。
--
-- ## 為什麼快
-- 以 y 由低到高的順序展開（bucket queue）：一般地形中往下很快就碰到網格底部，
-- 只走一條往下的路徑就能結束；只有真正懸空的小群才會被完整走完。
-- 多個起點共用已搜尋結果：碰到「已知有支撐」的格子也立即結束。
--
-- ## 網格格式（與 VoxelManip / VoxelArea 相同的扁平陣列）
-- grid = {
--   data, ox, oy, oz, nx, ny, nz,
--   bonded_of = {[cid] = true},  -- 會互相黏結、可以一起掉落的格（完整岩石、土、礦石…）
--   solid_of  = {[cid] = true},  -- 可以承托東西的實心格（含碎石、沙等非黏結者）
-- }

local stability = {}

local floor = math.floor

local ANCHORED, FALLING = 1, 2

-- starts：世界座標陣列。回傳 components, stats
--   components = {{cells = {{x=,y=,z=}, ...}}, ...}（只含懸空的群；cells 依 y 由低到高）
--   stats = {visited = 展開總格數, searches = 搜尋次數}
function stability.find_detached(g, starts, max_voxels)
	local nx, ny, nz = g.nx, g.ny, g.nz
	local sy, sz = nx, nx * ny
	local data, bonded_of, solid_of = g.data, g.bonded_of, g.solid_of
	max_voxels = max_voxels or 2000

	local state = {}       -- index → ANCHORED / FALLING（跨搜尋共用）
	local components = {}
	local stats = {visited = 0, searches = 0}

	for _, s in ipairs(starts) do
		local lx, ly, lz = s.x - g.ox, s.y - g.oy, s.z - g.oz
		if lx >= 0 and ly >= 0 and lz >= 0 and lx < nx and ly < ny and lz < nz then
			local i0 = 1 + lx + ly * sy + lz * sz
			if bonded_of[data[i0]] and not state[i0] then
				stats.searches = stats.searches + 1
				-- 最佳優先：buckets[ly] 為該高度待展開的格
				local buckets, lowest = {}, ly
				local seen, list = {[i0] = true}, {i0}
				buckets[ly] = {i0}
				local anchored = false

				while not anchored do
					-- 取最低的非空 bucket
					local b = buckets[lowest]
					while (not b or #b == 0) and lowest < ny do
						lowest = lowest + 1
						b = buckets[lowest]
					end
					if not b or #b == 0 then break end
					local i = b[#b]
					b[#b] = nil
					stats.visited = stats.visited + 1

					local k = i - 1
					local cx = k % nx
					local cy = floor(k / sy) % ny
					local cz = floor(k / sz)

					-- 1. 網格邊界
					if cx == 0 or cy == 0 or cz == 0 or cx == nx - 1 or cy == ny - 1 or cz == nz - 1 then
						anchored = true
						break
					end
					-- 2. 坐在群外的實心格上（正下方不是鍵結格但能承托）
					local below = i - sy
					local cb = data[below]
					if solid_of[cb] and not bonded_of[cb] then
						anchored = true
						break
					end

					-- 展開 6 個鄰格（只沿鍵結格）
					local nbs = {i - sy, i + 1, i - 1, i + sz, i - sz, i + sy} -- 先下後上
					for n = 1, 6 do
						local j = nbs[n]
						if not seen[j] and bonded_of[data[j]] then
							local st = state[j]
							if st == ANCHORED then
								anchored = true
								break
							end
							seen[j] = true
							list[#list + 1] = j
							if #list > max_voxels then
								anchored = true
								break
							end
							local jy = floor((j - 1) / sy) % ny
							local bj = buckets[jy]
							if not bj then bj = {}; buckets[jy] = bj end
							bj[#bj + 1] = j
							if jy < lowest then lowest = jy end
						end
					end
				end

				local mark = anchored and ANCHORED or FALLING
				for _, j in ipairs(list) do state[j] = mark end

				if not anchored then
					local cells = {}
					for _, j in ipairs(list) do
						local k = j - 1
						cells[#cells + 1] = {
							x = g.ox + k % nx,
							y = g.oy + floor(k / sy) % ny,
							z = g.oz + floor(k / sz),
						}
					end
					table.sort(cells, function(a, b) return a.y < b.y end)
					components[#components + 1] = {cells = cells}
				end
			end
		end
	end
	return components, stats
end

return stability
