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
rockmech.jointtex = dofile(modpath .. "/jointtex.lua")
rockmech.failure = assert(loadfile(modpath .. "/failure.lua"))(rockmech.stress)
rockmech.rockfall = dofile(modpath .. "/rockfall.lua")
rockmech.stability = dofile(modpath .. "/stability.lua")
rockmech.support = dofile(modpath .. "/support.lua")
rockmech.fem = dofile(modpath .. "/fem.lua")
rockmech.rigidfall = dofile(modpath .. "/rigidfall.lua")
rockmech.overhang = dofile(modpath .. "/overhang.lua")
rockmech.keyblock = dofile(modpath .. "/keyblock.lua")
rockmech.granular = dofile(modpath .. "/granular.lua")
rockmech.blast = dofile(modpath .. "/blast.lua")
rockmech.rockmass = dofile(modpath .. "/rockmass.lua")

-- 解析設定：世界資料夾的 rockmech.conf 優先於 minetest.conf（全域）
local world_conf_path = core.get_worldpath() .. "/rockmech.conf"
local world_conf = Settings(world_conf_path)
local function get_setting(key)
	local v = world_conf:get(key)
	if v ~= nil and v ~= "" then return v end
	return core.settings:get(key)
end
local cfg, warnings = rockmech.config.load(get_setting)
rockmech.cfg = cfg
for _, w in ipairs(warnings) do
	core.log("warning", "[rockmech] " .. w)
end

-- 世界第一次載入時，把決定節理幾何的設定凍結到該世界：之後改全域設定
-- 不會讓這個世界已生成的節理對不上。要改這個世界的節理，請編輯 rockmech.conf。
if not world_conf:has("rockmech_joint_lattice") then
	world_conf:set("rockmech_surface_y", tostring(cfg.surface_y))
	world_conf:set("rockmech_joint_persistence", cfg.joint_persistence)
	world_conf:set("rockmech_joint_lattice", tostring(cfg.joint_lattice))
	if not world_conf:has("rockmech_lith_mode") then
		world_conf:set("rockmech_lith_mode", cfg.lith_mode)
	end
	if not world_conf:has("rockmech_zone_width") then
		world_conf:set("rockmech_zone_width", tostring(cfg.zone_width))
	end
	for i, js in ipairs(cfg.joint_sets) do
		if i <= rockmech.config.MAX_SET_OVERRIDES then
			world_conf:set("rockmech_joint_set_" .. i, ("%g,%g,%g,%g,%g"):format(
				js.dip, js.dipdir, js.spacing, js.persistence, js.phi))
		end
	end
	if world_conf:write() then
		core.log("action", "[rockmech] 已建立世界設定 " .. world_conf_path)
	end
end
-- 片狀延續性加入之前建立的世界：維持舊的逐面延續性（已生成的節理貼圖才對得上）
if not world_conf:has("rockmech_joint_persistence") then
	world_conf:set("rockmech_joint_persistence", "face")
	cfg.joint_persistence = "face"
	world_conf:write()
end
-- mapgen 執行緒無法讀主環境的變數，以 IPC 傳遞世界設定
core.ipc_set("rockmech:world_settings", world_conf:to_table())

-- 節理組（依世界種子前處理）。延遲到第一次使用才計算，避免載入期種子尚未就緒。
local prepared_sets
function rockmech.get_joint_sets()
	if not prepared_sets then
		local seed_str = core.get_mapgen_setting("seed")
		if not seed_str then
			core.log("warning", "[rockmech] 讀不到世界種子，節理延續性改用種子 0")
		end
		rockmech.seed = rockmech.joints.seed_from_string(seed_str or "0")
		prepared_sets = rockmech.joints.prepare(cfg.joint_sets, rockmech.seed, cfg.joint_lattice,
			cfg.joint_persistence)
	end
	return prepared_sets
end

-- 引擎端模組
dofile(modpath .. "/nodes.lua")
dofile(modpath .. "/rockfall_entity.lua")
dofile(modpath .. "/rigidfall_entity.lua")
dofile(modpath .. "/collapse.lua") -- 沿用 physics_core 的坍塌機制，階段 3 由 keyblock.lua 取代
dofile(modpath .. "/tools.lua")
dofile(modpath .. "/ui.lua")
dofile(modpath .. "/blasting.lua")
dofile(modpath .. "/drilling.lua")
dofile(modpath .. "/groundsupport.lua")
dofile(modpath .. "/femstress.lua")
dofile(modpath .. "/rubble_tool.lua")
dofile(modpath .. "/vehicles.lua")
dofile(modpath .. "/crusher.lua")
dofile(modpath .. "/plant.lua")
dofile(modpath .. "/conveyor.lua")
dofile(modpath .. "/npc_skins.lua")
dofile(modpath .. "/career.lua")
dofile(modpath .. "/team.lua")
dofile(modpath .. "/preview.lua")
dofile(modpath .. "/restart.lua")
dofile(modpath .. "/drone.lua")
dofile(modpath .. "/research.lua")
dofile(modpath .. "/knowledge.lua")
dofile(modpath .. "/worldtools.lua")
dofile(modpath .. "/fsmask.lua")
dofile(modpath .. "/jointmesh.lua")

-- 地圖生成在 mapgen 執行緒中執行（另一個 Lua 環境），以 IPC 傳遞 modpath
core.ipc_set("rockmech:modpath", modpath)
core.register_mapgen_script(modpath .. "/mapgen.lua")

-- default 的倒木結構檔（apple_log 等）引用 flowers 模組的蘑菇；本遊戲沒有 flowers，
-- 每次載入都會出現 NodeResolver 錯誤。沒有 flowers 時把蘑菇指向空氣（倒木本來也不生成）
if not core.get_modpath("flowers") then
	core.register_alias("flowers:mushroom_brown", "air")
	core.register_alias("flowers:mushroom_red", "air")
end
