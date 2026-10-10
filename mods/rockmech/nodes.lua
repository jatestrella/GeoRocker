-- rockmech/nodes.lua
-- 註冊岩性 node（引擎端）。
-- 有 default mod 時以 default_stone.png 著色；否則用 [fill 產生純色材質（devtest 可用）。

local cfg = rockmech.cfg
local has_default = core.get_modpath("default") ~= nil

local sounds
if has_default and default and default.node_sound_stone_defaults then
	sounds = default.node_sound_stone_defaults()
end

rockmech.node_of_lith = {} -- 岩性名稱 → node 名稱
rockmech.lith_of_node = {} -- node 名稱 → 岩性條目

for _, key in ipairs(cfg.lithology_order) do
	local lith = cfg.lithologies[key]
	local nodename = rockmech.modname .. ":" .. lith.name
	local tile
	if lith.texture then
		tile = lith.texture
	elseif has_default then
		tile = "default_stone.png^[colorize:" .. lith.color .. ":150"
	else
		tile = "[fill:16x16:" .. lith.color
	end

	core.register_node(nodename, {
		description = lith.description .. "\n" ..
			("γ=%.1f kN/m³  UCS=%g MPa  σt=%g MPa"):format(lith.gamma, lith.ucs, lith.tensile),
		tiles = {tile},
		is_ground_content = true,
		groups = {cracky = lith.cracky or 3, stone = 1, rockmech_rock = 1},
		sounds = sounds,
	})

	rockmech.node_of_lith[key] = nodename
	rockmech.lith_of_node[nodename] = lith
end

-- 依 y 取該深度分層的岩性條目
function rockmech.lith_at_y(y)
	local h = rockmech.stress.depth(y, cfg.surface_y)
	return cfg.lithologies[rockmech.stress.layer_at_depth(cfg.layers, h)]
end

-- physics_core 舊 node 相容：大岩塊已移除，舊世界中的回到 stone（可用 /convert_rocks 轉成岩性）
if core.registered_nodes["default:stone"] then
	core.register_alias("physics_core:large_rock", "default:stone")
end

-- 碎石：軸差破壞後的岩石。不參與軸差判定（非岩性），
-- 但在 collapse.lua 中套用懸空掉落與安息角滑動。
rockmech.RUBBLE = rockmech.modname .. ":rubble"
core.register_node(rockmech.RUBBLE, {
	description = "Rubble (碎石)\n軸差破壞後的破碎岩石",
	tiles = {has_default and "default_gravel.png^[colorize:#5a5048:90" or "[fill:16x16:#6a6058"},
	groups = {crumbly = 2, cracky = 3},
	sounds = has_default and default.node_sound_gravel_defaults and default.node_sound_gravel_defaults() or sounds,
})
