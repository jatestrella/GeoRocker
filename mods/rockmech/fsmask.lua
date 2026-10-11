-- rockmech/fsmask.lua
-- FS < 1 遮罩（除錯／檢視用，不修改地圖）：
--   /rockmech_fsmask [半徑] [秒數]   在玩家周圍標出「若被觸發就會破壞」的岩格
--   /rockmech_fsmask off             清除
-- 標示方式：
--   * 半透明發光方塊（實體）套在格子外：紅 = 節理滑動、橙 = 軸差破壞、紫 = 懸臂斷裂／被節理切離
--   * HUD 小方點（image_waypoint）：不受遮擋，洞穴裡、岩石後面的格子也看得到
-- 判定與遊戲中的破壞檢查、懸臂判定相同（同一組純函式與參數）。

local cfg = rockmech.cfg
local collapse = rockmech.collapse

local KINDS = {
	slip = {color = "#ff2020", label = "節理滑動"},
	axial = {color = "#ff9900", label = "軸差破壞"},
	overhang = {color = "#b040ff", label = "懸臂斷裂／被節理切離"},
}
local MAX_ENTITIES = 2000
local MAX_WAYPOINTS = 300
local DEFAULT_R, MAX_R = 12, 32
local DEFAULT_T, MAX_T = 60, 600

local function cube_textures(color)
	-- 外框不透明、內部半透明：疊在一起時仍看得出格子邊界
	-- （^ 疊加是 alpha 混合，挖不出洞；所以從透明底開始，分別畫四條邊與內部）
	local c = color
	local t = ("[fill:16x16:#00000000^[fill:16x2:0,0:%s^[fill:16x2:0,14:%s^[fill:2x12:0,2:%s^[fill:2x12:14,2:%s"
		.. "^[fill:12x12:2,2:%s70"):format(c, c, c, c, c)
	return {t, t, t, t, t, t}
end

for kind, k in pairs(KINDS) do
	core.register_entity("rockmech:fsmask_" .. kind, {
		initial_properties = {
			visual = "cube",
			visual_size = {x = 1.06, y = 1.06, z = 1.06},
			textures = cube_textures(k.color),
			use_texture_alpha = true,
			backface_culling = false,
			glow = 14,
			physical = false,
			collide_with_objects = false,
			pointable = false,
			static_save = false,
			shaded = false,
		},
	})
end

-- 玩家名稱 → {objs = {...}, huds = {...}, job = after 工作}
local active = {}

local function clear(name)
	local a = active[name]
	if not a then return end
	for _, obj in ipairs(a.objs) do
		if obj:get_pos() then obj:remove() end
	end
	local player = core.get_player_by_name(name)
	if player then
		for _, id in ipairs(a.huds) do player:hud_remove(id) end
	end
	if a.job then a.job:cancel() end
	active[name] = nil
end

core.register_on_leaveplayer(function(player)
	clear(player:get_player_name())
end)

local function pkey(p) return p.x .. "," .. p.y .. "," .. p.z end

-- 找出 center ±r 內 FS < 1 的格子。回傳 cells = {{pos, kind}...}, counts, ms
function rockmech.fsmask_scan(center, r)
	local t0 = core.get_us_time()
	local a, b = vector.subtract(center, r), vector.add(center, r)
	local cells, seen = {}, {}
	local counts = {slip = 0, axial = 0, overhang = 0}

	-- 1. 軸差破壞與節理滑動（同遊戲中的破壞檢查）
	if cfg.failure.enabled or cfg.weakness.enabled then
		local failed = collapse.evaluate_failure_boxes({{a, b}})
		for _, f in ipairs(failed) do
			local kind = f.state.fails_axial and "axial" or "slip"
			local p = {x = f.x, y = f.y, z = f.z}
			seen[pkey(p)] = true
			cells[#cells + 1] = {pos = p, kind = kind}
			counts[kind] = counts[kind] + 1
		end
	end

	-- 2. 懸臂斷裂／被節理切離：以範圍內所有「下方懸空的鍵結格」為起點
	if cfg.overhang.enabled then
		local orad = cfg.overhang.radius
		local grid = collapse.read_grid(vector.subtract(a, orad), vector.add(b, orad), true)
		local nx, ny = grid.nx, grid.ny
		local data, bonded_of, solid_of = grid.data, grid.bonded_of, grid.solid_of
		local starts = {}
		for z = a.z, b.z do
			for y = a.y, b.y do
				for x = a.x, b.x do
					local i = 1 + (x - grid.ox) + (y - grid.oy) * nx + (z - grid.oz) * nx * ny
					if bonded_of[data[i]] and not solid_of[data[i - nx]] then
						starts[#starts + 1] = {x = x, y = y, z = z}
					end
				end
			end
		end
		local groups = rockmech.overhang.find_failing_local(grid, collapse.overhang_params(), starts)
		for _, g in ipairs(groups) do
			for _, p in ipairs(g.cells) do
				local k = pkey(p)
				if not seen[k] then
					seen[k] = true
					cells[#cells + 1] = {pos = p, kind = "overhang"}
					counts.overhang = counts.overhang + 1
				end
			end
		end
	end
	return cells, counts, (core.get_us_time() - t0) / 1000
end

local function show(name, r, seconds)
	clear(name)
	local player = core.get_player_by_name(name)
	if not player then return false, "找不到玩家" end
	local center = vector.round(player:get_pos())
	local cells, counts, ms = rockmech.fsmask_scan(center, r)

	-- 近的先標
	table.sort(cells, function(u, v)
		return vector.distance(u.pos, center) < vector.distance(v.pos, center)
	end)
	local a = {objs = {}, huds = {}}
	active[name] = a
	for i, c in ipairs(cells) do
		if i <= MAX_ENTITIES then
			local obj = core.add_entity(c.pos, "rockmech:fsmask_" .. c.kind)
			if obj then a.objs[#a.objs + 1] = obj end
		end
		if i <= MAX_WAYPOINTS then
			a.huds[#a.huds + 1] = player:hud_add({
				type = "image_waypoint",
				world_pos = c.pos,
				text = ("[fill:10x10:#000000^[fill:8x8:1,1:%s"):format(KINDS[c.kind].color),
				scale = {x = 1, y = 1},
				alignment = {x = 0, y = 0},
				offset = {x = 0, y = 0},
				z_index = -100,
			})
		end
	end
	a.job = core.after(seconds, clear, name)

	local parts = {}
	for _, kind in ipairs({"slip", "axial", "overhang"}) do
		parts[#parts + 1] = core.colorize(KINDS[kind].color, ("■ %s %d"):format(KINDS[kind].label, counts[kind]))
	end
	local note = ""
	if #cells > MAX_ENTITIES then note = ("；方塊只標最近的 %d 格"):format(MAX_ENTITIES) end
	if #cells > MAX_WAYPOINTS then note = note .. ("；穿牆小方點只標最近的 %d 格"):format(MAX_WAYPOINTS) end
	return true, ("[rockmech FS 遮罩] 以 %s 為中心 ±%d m，FS ≤ 1 共 %d 格：%s（%.0f ms；%d 秒後消失%s）"):format(
		core.pos_to_string(center), r, #cells, table.concat(parts, "  "), ms, seconds, note)
end

core.register_chatcommand("rockmech_fsmask", {
	params = "[半徑 1-32，預設 12] [秒數，預設 60] | off",
	description = "標出周圍若被觸發就會破壞（FS ≤ 1）的岩格：紅 = 節理滑動、橙 = 軸差、紫 = 懸臂／被節理切離",
	func = function(name, param)
		local args = param:split(" ")
		if args[1] == "off" then
			clear(name)
			return true, "[rockmech FS 遮罩] 已清除"
		end
		local r = math.max(1, math.min(MAX_R, math.floor(tonumber(args[1]) or DEFAULT_R)))
		local t = math.max(1, math.min(MAX_T, math.floor(tonumber(args[2]) or DEFAULT_T)))
		return show(name, r, t)
	end,
})
