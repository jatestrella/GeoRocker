-- rockmech/init.lua
-- 只負責載入模組與最小的接線。純計算模組（config/joints/stress）不碰引擎 API；
-- 引擎相關的註冊放在 nodes.lua / tools.lua，地圖生成放在 mapgen.lua（於 mapgen 執行緒載入）。

local modname = core.get_current_modname()
local modpath = core.get_modpath(modname)

rockmech = {modname = modname, modpath = modpath}

-- 純模組
rockmech.config = dofile(modpath .. "/config.lua")
rockmech.joints = dofile(modpath .. "/joints.lua")
rockmech.stress = dofile(modpath .. "/stress.lua")
rockmech.failure = assert(loadfile(modpath .. "/failure.lua"))(rockmech.stress)
rockmech.rockfall = dofile(modpath .. "/rockfall.lua")
rockmech.support = dofile(modpath .. "/support.lua")
rockmech.rigidfall = dofile(modpath .. "/rigidfall.lua")

-- 解析設定
local cfg, warnings = rockmech.config.load(function(key)
	return core.settings:get(key)
end)
rockmech.cfg = cfg
for _, w in ipairs(warnings) do
	core.log("warning", "[rockmech] " .. w)
end

-- 節理組（依世界種子前處理）。延遲到第一次使用才計算，避免載入期種子尚未就緒。
local prepared_sets
function rockmech.get_joint_sets()
	if not prepared_sets then
		local seed_str = core.get_mapgen_setting("seed")
		if not seed_str then
			core.log("warning", "[rockmech] 讀不到世界種子，節理延續性改用種子 0")
		end
		rockmech.seed = rockmech.joints.seed_from_string(seed_str or "0")
		prepared_sets = rockmech.joints.prepare(cfg.joint_sets, rockmech.seed)
	end
	return prepared_sets
end

-- 引擎端模組
dofile(modpath .. "/nodes.lua")
dofile(modpath .. "/rockfall_entity.lua")
dofile(modpath .. "/rigidfall_entity.lua")
dofile(modpath .. "/collapse.lua") -- 沿用 physics_core 的坍塌機制，階段 3 由 keyblock.lua 取代
dofile(modpath .. "/tools.lua")

-- 地圖生成在 mapgen 執行緒中執行（另一個 Lua 環境），以 IPC 傳遞 modpath
core.ipc_set("rockmech:modpath", modpath)
core.register_mapgen_script(modpath .. "/mapgen.lua")
