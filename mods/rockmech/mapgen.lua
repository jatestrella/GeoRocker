-- rockmech/mapgen.lua
-- 於 mapgen 執行緒（emerge environment）載入，見 core.register_mapgen_script。
-- 此環境無法存取主環境的全域變數，因此重新載入純模組並自行讀設定。
-- 依深度把地圖生成的 stone（mapgen_stone 別名）換成本 mod 的岩性。

local modpath = core.ipc_get("rockmech:modpath")
local config = dofile(modpath .. "/config.lua")
local stress = dofile(modpath .. "/stress.lua")
local joints = dofile(modpath .. "/joints.lua")

local cfg = config.load(function(key) return core.settings:get(key) end)
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
local use_joints = cfg.jointtex.enabled
local sets = joints.prepare(cfg.joint_sets,
	joints.seed_from_string(core.get_mapgen_setting("seed") or "0"))
local cell_mask = joints.cell_mask
local logged = 0

local data = {}

core.register_on_generated(function(vm, minp, maxp, blockseed)
	local emin, emax = vm:get_emerged_area()
	local area = VoxelArea(emin, emax)
	vm:get_data(data)

	-- 每個 y 的目標 content id
	local layer = stress.layer_table(cfg, minp.y, maxp.y)
	local var_y = {}
	for y = minp.y, maxp.y do
		var_y[y] = c_var[layer[y]]
	end

	local t0 = os.clock()
	local changed, n = false, 0
	for z = minp.z, maxp.z do
		for y = minp.y, maxp.y do
			local cv = var_y[y]
			local vi = area:index(minp.x, y, z)
			for x = minp.x, maxp.x do
				if data[vi] == c_stone then
					data[vi] = cv[use_joints and cell_mask(sets, x, y, z) or 0]
					changed = true
					n = n + 1
				end
				vi = vi + 1
			end
		end
	end
	if logged < 3 and n > 0 then
		logged = logged + 1
		core.log("action", ("[rockmech] mapgen 岩性＋節理遮罩：%d 格，%.0f ms"):format(
			n, (os.clock() - t0) * 1000))
	end

	if changed then
		-- stone → 岩性 皆為不透光實心方塊，光照不變，不需重算
		vm:set_data(data)
	end
end)
