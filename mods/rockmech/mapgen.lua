-- rockmech/mapgen.lua
-- 於 mapgen 執行緒（emerge environment）載入，見 core.register_mapgen_script。
-- 此環境無法存取主環境的全域變數，因此重新載入純模組並自行讀設定。
-- 依深度把地圖生成的 stone（mapgen_stone 別名）換成本 mod 的岩性。

local modpath = core.ipc_get("rockmech:modpath")
local config = dofile(modpath .. "/config.lua")
local stress = dofile(modpath .. "/stress.lua")

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
local c_lith = {}
for key, lith in pairs(cfg.lithologies) do
	c_lith[key] = core.get_content_id("rockmech:" .. lith.name)
end

local data = {}

core.register_on_generated(function(vm, minp, maxp, blockseed)
	local emin, emax = vm:get_emerged_area()
	local area = VoxelArea(emin, emax)
	vm:get_data(data)

	-- 每個 y 的目標 content id
	local layer = stress.layer_table(cfg, minp.y, maxp.y)
	local cid_y = {}
	for y = minp.y, maxp.y do
		cid_y[y] = c_lith[layer[y]]
	end

	local changed = false
	for z = minp.z, maxp.z do
		for y = minp.y, maxp.y do
			local c_new = cid_y[y]
			local vi = area:index(minp.x, y, z)
			for _ = minp.x, maxp.x do
				if data[vi] == c_stone then
					data[vi] = c_new
					changed = true
				end
				vi = vi + 1
			end
		end
	end

	if changed then
		-- stone → 岩性 皆為不透光實心方塊，光照不變，不需重算
		vm:set_data(data)
	end
end)
