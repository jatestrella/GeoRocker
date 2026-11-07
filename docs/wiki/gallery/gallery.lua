-- wiki gallery: place components, move the camera, log [SHOT] id
local function L(...) core.log("action", string.format(...)) end
local X0, Z0, Y = 7000, 7000, 40
local GAP = 32
local SH = core.get_content_id("rockmech:shale")
local AIR = core.CONTENT_AIR

-- id, 蝔桅?, ?迂?撘? ?⊿頝
local LIST = {
	{"cart", "ent", "rockmech:cart", 5}, {"suv", "ent", "rockmech:suv", 8}, {"truck", "ent", "rockmech:truck", 12},
	{"haul", "ent", "rockmech:haul", 20}, {"excavator", "ent", "rockmech:excavator", 12}, {"excavator_big", "ent", "rockmech:excavator_big", 22},
	{"dozer", "ent", "rockmech:dozer", 10}, {"lowboy", "ent", "rockmech:lowboy", 16}, {"miner", "ent", "rockmech:miner", 18},
	{"drillrig", "ent", "rockmech:drillrig", 13}, {"jumbo", "ent", "rockmech:jumbo", 12}, {"charger", "ent", "rockmech:charger", 10},
	{"bulktruck", "ent", "rockmech:bulktruck", 12}, {"corerig", "ent", "rockmech:corerig", 13},
	{"crusher", "crusher", "rockmech:crusher", 18}, {"crusher_big", "crusher", "rockmech:crusher_big", 18},
	{"plant", "plant", nil, 26}, {"loadout", "loadout", nil, 14},
	{"corebox", "node", "rockmech:corebox", 2.2}, {"rain_gauge", "node", "rockmech:rain_gauge", 2.6},
	{"survey_prism", "prism", nil, 2.4}, {"sawbench", "node", "rockmech:sawbench", 2.6}, {"workbench", "node", "rockmech:workbench", 2.6},
	{"camp_bench", "node", "rockmech:camp_bench", 3}, {"timber_post", "post", nil, 4.5}, {"timber_plank", "node", "rockmech:timber_plank", 2.4},
	{"timber_slab", "node", "rockmech:timber_slab", 2.4}, {"timber_wall", "node", "rockmech:timber_wall", 2.6}, {"locker", "node", "rockmech:locker", 2.8},
	{"log", "log", nil, 3}, {"colluvium", "patch", "rockmech:colluvium", 5}, {"topsoil", "patch", "rockmech:topsoil", 5},
	{"rubble", "patch", "rockmech:rubble", 5}, {"rubble_soil", "patch", "rockmech:rubble_soil", 5}, {"rock", "rock", nil, 7},
	{"vendor_vehicle", "ent", "rockmech:vendor_vehicle", 3.6}, {"vendor_blast", "ent", "rockmech:vendor_blast", 3.6},
	{"vendor_tools", "ent", "rockmech:vendor_tools", 3.6}, {"npc_mechanic", "ent", "rockmech:npc_mechanic", 3.6},
	{"npc_geologist", "ent", "rockmech:npc_geologist", 3.6}, {"professor", "ent", "rockmech:npc_professor", 3.6},
	{"operator", "ent", "rockmech:operator_npc", 3.6},
}
local COLS = 7
local function spot(i) return {x = X0 + ((i - 1) % COLS) * GAP, y = Y + 1, z = Z0 + math.floor((i - 1) / COLS) * GAP} end

local fake = setmetatable({get_player_name = function() return "wikibot" end, is_player = function() return true end,
	get_look_dir = function() return {x = 0, y = -0.3, z = -1} end, get_look_horizontal = function() return math.pi end,
	get_player_control = function() return {} end, get_meta = function() return {get_string = function() return "" end, set_string = function() end, get_int = function() return 0 end} end},
	{__index = function() return function() end end})

local function vm_fill(p1, p2, cid)
	local vm = core.get_voxel_manip()
	local e1, e2 = vm:read_from_map(p1, p2)
	local a = VoxelArea(e1, e2)
	local d = vm:get_data()
	for z = p1.z, p2.z do for y = p1.y, p2.y do for x = p1.x, p2.x do d[a:index(x, y, z)] = cid end end end
	vm:set_data(d); vm:write_to_map(true)
end

local function build()
	local rows = math.ceil(#LIST / COLS)
	local p1 = {x = X0 - 20, y = Y - 12, z = Z0 - 20}
	local p2 = {x = X0 + COLS * GAP + 10, y = Y, z = Z0 + rows * GAP + 10}
	vm_fill(p1, p2, SH)
	vm_fill({x = p1.x, y = Y + 1, z = p1.z}, {x = p2.x, y = Y + 30, z = p2.z}, AIR)
	for i, it in ipairs(LIST) do
		local p = spot(i)
		local kind = it[2]
		if kind == "ent" then
			local o = core.add_entity(p, it[3])
			if o then o:set_yaw(0) end
		elseif kind == "node" then core.set_node(p, {name = it[3]})
		elseif kind == "crusher" then rockmech.crusher_build(p, -1, 0, "wikibot", it[3])
		elseif kind == "plant" then if rockmech.plant_build then rockmech.plant_build(p, -1, 0, "wikibot") end
		elseif kind == "loadout" then
			core.registered_items["rockmech:loadout"].on_place(ItemStack("rockmech:loadout"), fake,
				{type = "node", under = {x = p.x, y = p.y - 1, z = p.z}, above = p})
		elseif kind == "prism" then
			for y = 0, 2 do core.set_node({x = p.x, y = p.y + y, z = p.z + 1}, {name = "rockmech:shale"}) end
			core.set_node({x = p.x, y = p.y + 1, z = p.z}, {name = "rockmech:survey_prism", param2 = core.dir_to_wallmounted({x = 0, y = 0, z = 1})})
		elseif kind == "post" then
			for y = 0, 2 do core.set_node({x = p.x, y = p.y + y, z = p.z}, {name = "rockmech:timber_post"}) end
			for x = -1, 1 do for z = -1, 1 do core.set_node({x = p.x + x, y = p.y + 3, z = p.z + z}, {name = "rockmech:shale"}) end end
		elseif kind == "log" then
			core.set_node(p, {name = "default:tree", param2 = 12})
			core.set_node({x = p.x, y = p.y, z = p.z + 1}, {name = "default:tree", param2 = 12})
		elseif kind == "patch" then
			for x = -1, 1 do for z = -1, 1 do core.set_node({x = p.x + x, y = p.y, z = p.z + z}, {name = it[3]}) end end
		elseif kind == "rock" then
			for x = -1, 1 do for z = -1, 1 do for y = 0, 1 do
				core.set_node({x = p.x + x, y = p.y + y, z = p.z + z}, {name = "rockmech:shale"})
			end end end
		end
	end
	core.fix_light(p1, {x = p2.x, y = Y + 30, z = p2.z})
	L("[GALLERY] built %d", #LIST)
end

local function shoot(player, i)
	if i > #LIST then L("[SHOTS DONE]"); return end
	local it = LIST[i]
	local p = spot(i)
	local d = it[4]
	local target = {x = p.x, y = p.y + (d > 6 and d * 0.12 or 0.25), z = p.z}
	local cam = {x = p.x - 0.62 * d, y = target.y + 0.42 * d, z = p.z + 0.78 * d}
	player:set_pos({x = cam.x, y = cam.y - 1.625, z = cam.z})
	local dx, dy, dz = target.x - cam.x, target.y - cam.y, target.z - cam.z
	player:set_look_horizontal(math.atan2(-dx, dz))
	player:set_look_vertical(math.atan2(-dy, math.sqrt(dx * dx + dz * dz)))
	core.after(3.5, function()
		L("[SHOT] %s", it[1])
		core.after(2.0, function() shoot(player, i + 1) end)
	end)
end

core.register_on_joinplayer(function(player)
	if player:get_player_name() ~= "wikibot" then return end
	local privs = core.get_player_privs("wikibot")
	privs.fly, privs.noclip, privs.fast = true, true, true
	core.set_player_privs("wikibot", privs)
	player:set_physics_override({gravity = 0})
	player:hud_set_flags({hotbar = false, healthbar = false, crosshair = false, wielditem = false, breathbar = false,
		minimap = false, minimap_radar = false, basic_debug = false, chat = false})
	player:set_properties({visual_size = {x = 0, y = 0}})
	core.after(20, function() shoot(player, 1) end)
end)

core.after(1, function()
	core.settings:set("time_speed", "0")
	core.set_timeofday(0.5)
	local rows = math.ceil(#LIST / COLS)
	core.emerge_area({x = X0 - 40, y = Y - 20, z = Z0 - 40}, {x = X0 + COLS * GAP + 30, y = Y + 40, z = Z0 + rows * GAP + 30}, function(_, _, rem)
		if rem == 0 then
			for x = X0 - 32, X0 + COLS * GAP + 32, 16 do for z = Z0 - 32, Z0 + rows * GAP + 32, 16 do
				core.forceload_block({x = x, y = Y, z = z}, true, -1)
			end end
			core.after(1, build)
		end
	end)
end)

