-- rockmech/mapgen.lua
-- 於 mapgen 執行緒（emerge environment）載入，見 core.register_mapgen_script。
-- 此環境無法存取主環境的全域變數，因此重新載入純模組並自行讀設定。
-- 依深度把地圖生成的 stone（mapgen_stone 別名）換成本 mod 的岩性。

local modpath = core.ipc_get("rockmech:modpath")
local config = dofile(modpath .. "/config.lua")
local stress = dofile(modpath .. "/stress.lua")
local joints = dofile(modpath .. "/joints.lua")
local jointtex = dofile(modpath .. "/jointtex.lua")

-- 與主環境相同：世界的 rockmech.conf（經 IPC 傳來）優先於 minetest.conf
local world_settings = core.ipc_get("rockmech:world_settings") or {}
local cfg = config.load(function(key)
	local v = world_settings[key]
	if v ~= nil and v ~= "" then return v end
	return core.settings:get(key)
end)
if not cfg.replace_stone then
	return
end

local stone_name = core.registered_aliases["mapgen_stone"] or "default:stone"
if not core.registered_nodes[stone_name] then
	core.log("warning", "[rockmech] 找不到 mapgen stone 節點 '" .. stone_name ..
		"'，不替換岩性")
	return
end

local c_stone = core.get_content_id(stone_name)
-- c_var[岩性][遮罩] = content id（遮罩 0 為基本 node）
local c_var = {}
for key, lith in pairs(cfg.lithologies) do
	c_var[key] = {}
	for mask = 0, 63 do
		local name = "rockmech:" .. lith.name
		if mask > 0 then name = ("%s_j%02d"):format(name, mask) end
		c_var[key][mask] = core.get_content_id(name)
	end
end

-- 節理組（與主環境相同的種子與前處理，結果一致）
-- mesh 模式：方塊不帶跡線（跡線由 jointmesh.lua 疊上），一律用基本方塊
local use_joints = cfg.jointtex.enabled and cfg.jointtex.style ~= "mesh"
local sets = joints.prepare(cfg.joint_sets,
	joints.seed_from_string(core.get_mapgen_setting("seed") or "0"), cfg.joint_lattice, cfg.joint_persistence)
local cell_mask = joints.cell_mask
local logged = 0

-- 平面跡線樣式：c_plane[岩性][後綴] = content id
local plane = use_joints and cfg.jointtex.style == "plane"
local MAXL = cfg.jointtex.max_lines
local c_plane = {}
if plane then
	local levels = {}
	for i = 1, math.min(#sets, 4) do levels[i] = jointtex.levels(sets[i]) end
	local combos = jointtex.all_combos(levels, MAXL)
	for key, lith in pairs(cfg.lithologies) do
		c_plane[key] = {}
		for _, combo in ipairs(combos) do
			local sfx = jointtex.suffix(combo)
			c_plane[key][sfx] = core.get_content_id("rockmech:" .. lith.name .. sfx)
		end
	end
end
local cell_traces, suffix = jointtex.cell_traces, jointtex.suffix
local zones = cfg.lith_mode == "zones"

-- 只保留岩性（世界設定 rockmech_only_lithologies）：其他天然實心方塊（非土壤，
-- 例如礦石、凍土、冰、沙漠石）視同 stone，換成該位置的岩性
local as_stone = {[c_stone] = true}
if cfg.only_lithologies then
	for name, def in pairs(core.registered_nodes) do
		local g = def.groups or {}
		if def.walkable ~= false and def.is_ground_content ~= false and name ~= "ignore"
				and not name:find("^rockmech:")
				and not config.is_soil(name, def.groups, def.is_ground_content) then
			as_stone[core.get_content_id(name)] = true
		end
	end
end

-- 剝除土壤（世界設定 rockmech_strip_soil）：土壤改成空氣，露出岩盤
local strip = {}
local c_air = core.get_content_id("air")
if cfg.strip_soil then
	for name, def in pairs(core.registered_nodes) do
		if config.is_soil(name, def.groups, def.is_ground_content) then
			strip[core.get_content_id(name)] = true
		end
	end
end

local data, p2data = {}, {}
local seam, pit = cfg.coal_seam, cfg.open_pit
local c_road = {}
for k = 1, 7 do c_road[k] = core.get_content_id("rockmech:rubble_l" .. k .. "_c") end   -- 壓實的碎石（nodes.lua）

-- 表土和樹（世界設定 rockmech_mapgen_topsoil，預設開）：任何世界、任何地形都一樣，不綁礦帶、營地。
--   比地表（surface_y）高 MIN_RISE 以上、頂上是天然岩石的每一欄，鋪 SOIL_MIN–SOIL_MAX m 的表土（平滑雜訊，有厚有薄；
--   不滿一格的零頭用薄的表土）；地表上離山坡 1–4 m 的那一圈鋪漸薄的坡腳（1 m、6/8、4/8、2/8）；
--   山坡上稀疏種蘋果樹（間距 TREE_GAP、隨機偏移、四成跳過；樹那一欄的表土取整格，至少 2 m）。
--   只寫這個 chunk 自己的範圍（外圍那圈屬於隔壁 chunk，之後產生時會被蓋掉）；樹整棵要在 chunk 裡面
local TS = cfg.mapgen_topsoil and core.registered_nodes["rockmech:topsoil"] and core.registered_nodes["default:tree"] and true
local NL = 8
local SOIL_MIN, SOIL_MAX, MIN_RISE, TREE_GAP = 1, 3, 1, 6
local APRON = {8, 6, 4, 2}
local c_soil, c_log, c_leaf, c_apple = {}, nil, nil, nil
local is_rock = {[c_stone] = true}
if TS then
	for k = 1, NL - 1 do c_soil[k] = core.get_content_id("rockmech:topsoil_" .. k) end
	c_soil[NL] = core.get_content_id("rockmech:topsoil")
	c_log = core.get_content_id("default:tree")
	c_leaf = core.get_content_id("default:leaves")
	c_apple = core.get_content_id(core.registered_nodes["default:apple"] and "default:apple" or "default:leaves")
	for _, t in pairs(c_var) do for _, id in pairs(t) do is_rock[id] = true end end
	for _, t in pairs(c_plane) do for _, id in pairs(t) do is_rock[id] = true end end
end
local function rnd(x, z, seed)      -- 每個位置固定的 0..1 亂數
	local v = math.sin(x * 12.9898 + z * 78.233 + seed * 37.719) * 43758.5453
	return v - math.floor(v)
end
local function lay_topsoil(area, minp, maxp)
	local sy = math.floor(cfg.surface_y)
	local n_soil = 0
	-- 這一欄在 chunk 裡的岩石頂（上面是空氣）；不是岩石（建築、已有的東西）回傳 nil
	local function top_of(x, z)
		for y = maxp.y, minp.y, -1 do
			local c = data[area:index(x, y, z)]
			if c ~= c_air then return is_rock[c] and y or nil end
		end
	end
	-- 坡腳要知道旁邊 4 格的欄是不是山坡：礦帶地形用公式算（隔壁 chunk 還沒產生也算得出來），否則看這個 chunk 的資料
	local rise = {}
	local R = #APRON
	for x = minp.x - R, maxp.x + R do for z = minp.z - R, maxp.z + R do
		local r
		if cfg.lane_terrain then r = math.floor(stress.lane_terrain(cfg, x, z) + 0.5)
		elseif x >= minp.x and x <= maxp.x and z >= minp.z and z <= maxp.z then
			local t = top_of(x, z)
			r = t and t - sy or 0
		else r = 0 end
		rise[x .. "," .. z] = r
	end end
	-- 樹的位置（整棵在 chunk 裡）
	local trees = {}
	for gx = math.floor(minp.x / TREE_GAP) * TREE_GAP, maxp.x, TREE_GAP do
		for gz = math.floor(minp.z / TREE_GAP) * TREE_GAP, maxp.z, TREE_GAP do
			local x = gx + math.floor(rnd(gx, gz, 1) * 5) - 2
			local z = gz + math.floor(rnd(gx, gz, 2) * 5) - 2
			if rnd(gx, gz, 3) > 0.4 and x >= minp.x + 2 and x <= maxp.x - 2 and z >= minp.z + 2 and z <= maxp.z - 2 then
				trees[x .. "," .. z] = gx * 7 + gz
			end
		end
	end
	for z = minp.z, maxp.z do for x = minp.x, maxp.x do
		local top = top_of(x, z)
		if top and top < maxp.y then
			local key = x .. "," .. z
			local t      -- 表土厚度（1/8 m）
			if top - sy >= MIN_RISE then
				t = math.floor(NL * (SOIL_MIN + (SOIL_MAX - SOIL_MIN) * stress.terrain_noise(x / 14, z / 14, 41)) + 0.5)
				if trees[key] then t = math.max(2 * NL, t - t % NL) end
			elseif top - sy >= 0 then
				-- 坡腳：離最近的山坡欄幾格（8 方向，切比雪夫距離）
				for d = 1, R do
					local hit = false
					for dx = -d, d do for dz = -d, d do
						if (math.abs(dx) == d or math.abs(dz) == d) and (rise[(x + dx) .. "," .. (z + dz)] or 0) >= MIN_RISE then hit = true end
					end end
					if hit then t = APRON[d]; break end
				end
			end
			if t then
				local full, r = math.floor(t / NL), t % NL
				local done = 0
				for dy = 1, full + (r > 0 and 1 or 0) do
					local y = top + dy
					if y > maxp.y then break end
					local vi = area:index(x, y, z)
					if data[vi] ~= c_air then break end
					data[vi] = c_soil[dy <= full and NL or r]
					n_soil = n_soil + 1
					if dy <= full then done = dy end
				end
				-- 樹：表土整格都鋪上了，樹幹 4–5 m、樹冠半徑 2 m，整棵在 chunk 裡
				local seed = trees[key]
				if seed and done * NL == t then
					local g = top + done
					local h = 4 + (rnd(x, z, 5) > 0.5 and 1 or 0)
					if g + h + 1 <= maxp.y then
						for dy = 1, h do
							local vi = area:index(x, g + dy, z)
							if data[vi] == c_air then data[vi] = c_log end
						end
						for dy = h - 2, h + 1 do
							local rr = dy == h + 1 and 1 or 2
							for dx = -rr, rr do for dz = -rr, rr do
								local corner = math.abs(dx) == rr and math.abs(dz) == rr
								if not (corner and rnd(x + dx, z + dz, seed + dy) < 0.6) then
									local vi = area:index(x + dx, g + dy, z + dz)
									if data[vi] == c_air then
										data[vi] = (dy <= h and rnd(x + dx * 3, z + dz * 5, seed + dy) < 0.06) and c_apple or c_leaf
									end
								end
							end end
						end
					end
				end
			end
		end
	end end
	return n_soil
end

-- 露天坑：把地面以上的格挖成空氣，路面的零頭鋪不滿格的夯實碎石（車才開得順）
local function cut_pit(area, minp, maxp)
	local cut = 0
	for z = minp.z, maxp.z do
		for x = minp.x, maxp.x do
			local h = stress.pit_surface(pit, cfg.surface_y, x, z)
			if h then
				local base = math.floor(h)
				local k = math.floor((h - base) * 8)
				for y = math.max(minp.y, base + 1), maxp.y do
					local vi = area:index(x, y, z)
					if data[vi] ~= c_air then
						data[vi] = y == base + 1 and k > 0 and c_road[k] or c_air
						p2data[vi] = 0
						cut = cut + 1
					end
				end
			end
		end
	end
	return cut
end

core.register_on_generated(function(vm, minp, maxp, blockseed)
	local emin, emax = vm:get_emerged_area()
	local area = VoxelArea(emin, emax)
	vm:get_data(data)
	if seam or pit then vm:get_param2_data(p2data) end

	-- 每個 y 的目標 content id
	local layer = stress.layer_table(cfg, minp.y, maxp.y)
	local var_y, plane_y = {}, {}
	for y = minp.y, maxp.y do
		var_y[y] = c_var[layer[y]]
		plane_y[y] = c_plane[layer[y]]
	end
	-- 區帶模式：岩性依 x 而定
	local var_x, plane_x = {}, {}
	if zones then
		for x = minp.x, maxp.x do
			local key = stress.zone_at_x(cfg, x)
			var_x[x] = c_var[key]
			plane_x[x] = c_plane[key]
		end
	end

	local t0 = os.clock()
	local changed, n, stripped = false, 0, 0
	-- 礦帶地形：地面以上的山丘先填成 stone，下面的迴圈再換成岩性（含節理與煤層）
	if cfg.lane_terrain then
		local sy = math.floor(cfg.surface_y)
		for z = minp.z, maxp.z do
			for x = minp.x, maxp.x do
				local top = sy + math.floor(stress.lane_terrain(cfg, x, z) + 0.5)
				for y = math.max(minp.y, sy + 1), math.min(maxp.y, top) do
					local vi = area:index(x, y, z)
					if data[vi] == c_air then data[vi] = c_stone; stripped = stripped + 1 end
				end
			end
		end
	end
	for z = minp.z, maxp.z do
		for y = minp.y, maxp.y do
			local cv = var_y[y]
			local pv = plane_y[y]
			local vi = area:index(minp.x, y, z)
			for x = minp.x, maxp.x do
				if as_stone[data[vi]] then
					if zones then
						cv, pv = var_x[x], plane_x[x]
					end
					local coal = seam and stress.in_seam(seam, x, y, z)
					if plane then
						data[vi] = (coal and c_plane.coal or pv)[suffix(cell_traces(joints, sets, x, y, z, MAXL))]
					else
						data[vi] = (coal and c_var.coal or cv)[use_joints and cell_mask(sets, x, y, z) or 0]
					end
					if coal then p2data[vi] = stress.seam_grade(seam, x, y, z) end
					changed = true
					n = n + 1
				end
				vi = vi + 1
			end
		end
	end
	-- 剝除土壤：處理整個 VoxelManip 範圍（含 chunk 外圍一圈 mapblock）。
	-- 相鄰 chunk 生成時，引擎會把地表的土壤也寫進已生成 chunk 的邊緣，
	-- 只處理 minp..maxp 會留下邊緣的土壤。
	if next(strip) or cfg.only_lithologies then
		for i = 1, #data do
			local cid = data[i]
			if strip[cid] then
				data[i] = c_air
				stripped = stripped + 1
			elseif cid ~= c_stone and as_stone[cid] then
				-- 鄰近 chunk 寫進邊緣的其他天然方塊（礦石、凍土、冰…）→ 該位置的岩性
				local p = area:position(i)
				local key = stress.lith_key_at(cfg, p.x, p.y, p.z)
				if key == "coal" then p2data[i] = stress.seam_grade(seam, p.x, p.y, p.z) end
				if plane then
					data[i] = c_plane[key][suffix(cell_traces(joints, sets, p.x, p.y, p.z, MAXL))]
				else
					data[i] = c_var[key][use_joints and cell_mask(sets, p.x, p.y, p.z) or 0]
				end
				changed = true
			end
		end
		if stripped > 0 then changed = true end
	end

	if pit and cut_pit(area, minp, maxp) > 0 then
		changed = true
		stripped = stripped + 1
	end

	-- 表土和樹（岩性、坑都弄好之後）
	if TS and lay_topsoil(area, minp, maxp) > 0 then
		changed = true
		stripped = stripped + 1      -- 要重算光照
	end

	if logged < 3 and n > 0 then
		logged = logged + 1
		core.log("action", ("[rockmech] mapgen 岩性＋節理遮罩：%d 格、剝除土壤 %d 格，%.0f ms"):format(
			n, stripped, (os.clock() - t0) * 1000))
	end

	if changed then
		vm:set_data(data)
		if seam or pit then vm:set_param2_data(p2data) end
		-- stone → 岩性 光照不變；剝除土壤會改變光照與水的流動
		if stripped > 0 then
			vm:calc_lighting()
			vm:update_liquids()
		end
	end
end)
