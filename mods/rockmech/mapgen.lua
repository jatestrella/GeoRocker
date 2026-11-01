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
for k = 1, 7 do c_road[k] = core.get_content_id("rockmech:rubble_l" .. k) end

-- 露天坑：把地面以上的格挖成空氣，路面的零頭鋪不滿格的碎石（車才開得順）
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
