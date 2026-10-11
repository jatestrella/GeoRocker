-- rockmech/fsmask.lua
-- FS < 1 遮罩（除錯／檢視用，不修改地圖）：
--   /rockmech_fsmask [半徑] [秒數]   在玩家周圍標出「若被觸發就會破壞」的岩格
--   /rockmech_fsmask on | off        即時模式（每個玩家各自設定、會記住；也可在資訊頁／物品欄勾選）
-- 標示方式：
--   * 半透明發光方塊（實體）套在格子外：紅 = 節理滑動、橙 = 軸差破壞、紫 = 懸臂斷裂／被節理切離、
--     黃 = 關鍵塊體（被節理圍住、會因重力滑出或落下）
--   * HUD 小方點（image_waypoint）：不受遮擋，洞穴裡、岩石後面的格子也看得到
-- 判定與遊戲中的破壞檢查、懸臂判定相同（同一組純函式與參數）。

local cfg = rockmech.cfg
local collapse = rockmech.collapse

local KINDS = {
	slip = {color = "#ff2020", label = "節理滑動"},
	axial = {color = "#ff9900", label = "軸差破壞"},
	overhang = {color = "#b040ff", label = "懸臂斷裂／被節理切離"},
	keyblock = {color = "#ffe000", label = "關鍵塊體"},
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

local function pkey(p) return p.x .. "," .. p.y .. "," .. p.z end

-- 找出 center ±r 內 FS < 1 的格子。回傳 cells = {{pos, kind}...}, counts, ms
function rockmech.fsmask_scan(center, r)
	local t0 = core.get_us_time()
	local a, b = vector.subtract(center, r), vector.add(center, r)
	local cells, seen = {}, {}
	local counts = {slip = 0, axial = 0, overhang = 0, keyblock = 0}

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

	-- 3. 關鍵塊體：以範圍內所有臨空的鍵結格為起點（同一岩塊只算一次）
	if cfg.keyblock.enabled then
		local kr = math.min(24, math.ceil(cfg.keyblock.max_cells ^ (1 / 3)) + 6)
		local grid = collapse.read_grid(vector.subtract(a, kr), vector.add(b, kr), true)
		local nx, ny = grid.nx, grid.ny
		local data, bonded_of, solid_of = grid.data, grid.bonded_of, grid.solid_of
		local function idx(x, y, z) return 1 + (x - grid.ox) + (y - grid.oy) * nx + (z - grid.oz) * nx * ny end
		local starts = {}
		for z = a.z, b.z do
			for y = a.y, b.y do
				for x = a.x, b.x do
					if bonded_of[data[idx(x, y, z)]] and (not solid_of[data[idx(x + 1, y, z)]]
							or not solid_of[data[idx(x - 1, y, z)]] or not solid_of[data[idx(x, y + 1, z)]]
							or not solid_of[data[idx(x, y - 1, z)]] or not solid_of[data[idx(x, y, z + 1)]]
							or not solid_of[data[idx(x, y, z - 1)]]) then
						starts[#starts + 1] = {x = x, y = y, z = z}
					end
				end
			end
		end
		for _, blk in ipairs(rockmech.keyblock.find_blocks(grid, collapse.keyblock_params(), starts)) do
			if blk.fs < 1 then
				for _, p in ipairs(blk.cells) do
					local k = pkey(p)
					if not seen[k] then
						seen[k] = true
						cells[#cells + 1] = {pos = p, kind = "keyblock"}
						counts.keyblock = counts.keyblock + 1
					end
				end
			end
		end
	end
	return cells, counts, (core.get_us_time() - t0) / 1000
end

-- 玩家名稱 → {marks = {[座標] = {kind, obj, hud}}, live, center, t, dirty, hold, job}
local active = {}
local META = "rockmech:fsmask"
local LIVE_R = 10          -- 即時模式的範圍 (m)
local LIVE_MOVE = 3        -- 玩家移動超過此距離就重新掃描 (m)
local LIVE_PERIOD = 10     -- 保底重新掃描間隔 (s)
local LIVE_TICK = 1        -- 檢查間隔 (s)

local function now() return core.get_us_time() / 1e6 end

local function remove_mark(player, m)
	if m.obj and m.obj:get_pos() then m.obj:remove() end
	if m.hud and player then player:hud_remove(m.hud) end
end

local function clear(name)
	local a = active[name]
	if not a then return end
	local player = core.get_player_by_name(name)
	for _, m in pairs(a.marks) do remove_mark(player, m) end
	if a.job then a.job:cancel() end
	active[name] = nil
end

core.register_on_leaveplayer(function(player)
	clear(player:get_player_name())
end)

-- 依 cells 更新標記：只增減有變化的（不閃爍、少送封包）
local function apply(player, a, center, cells)
	table.sort(cells, function(u, v)
		return vector.distance(u.pos, center) < vector.distance(v.pos, center)
	end)
	local want = {}
	for _, c in ipairs(cells) do want[pkey(c.pos)] = c end
	for k, m in pairs(a.marks) do
		local c = want[k]
		if not c or c.kind ~= m.kind then
			remove_mark(player, m)
			a.marks[k] = nil
		end
	end
	for i, c in ipairs(cells) do
		local k = pkey(c.pos)
		local m = a.marks[k]
		if not m then m = {kind = c.kind}; a.marks[k] = m end
		if m.obj and not m.obj:get_pos() then m.obj = nil end   -- 區塊卸載時實體會消失
		if i <= MAX_ENTITIES then
			if not m.obj then m.obj = core.add_entity(c.pos, "rockmech:fsmask_" .. c.kind) end
		elseif m.obj then
			m.obj:remove(); m.obj = nil
		end
		if i <= MAX_WAYPOINTS then
			if not m.hud then
				m.hud = player:hud_add({
					type = "image_waypoint",
					world_pos = c.pos,
					text = ("[fill:10x10:#000000^[fill:8x8:1,1:%s"):format(KINDS[c.kind].color),
					scale = {x = 1, y = 1},
					alignment = {x = 0, y = 0},
					offset = {x = 0, y = 0},
					z_index = -100,
				})
			end
		elseif m.hud then
			player:hud_remove(m.hud); m.hud = nil
		end
	end
end

local function summary(cells, counts)
	local parts = {}
	for _, kind in ipairs({"slip", "axial", "overhang", "keyblock"}) do
		parts[#parts + 1] = core.colorize(KINDS[kind].color, ("■ %s %d"):format(KINDS[kind].label, counts[kind]))
	end
	local note = ""
	if #cells > MAX_ENTITIES then note = ("；方塊只標最近的 %d 格"):format(MAX_ENTITIES) end
	if #cells > MAX_WAYPOINTS then note = note .. ("；穿牆小方點只標最近的 %d 格"):format(MAX_WAYPOINTS) end
	return table.concat(parts, "  "), note
end

-- 單次顯示 seconds 秒（即時模式開啟時，期間暫停即時更新）
local function show(name, r, seconds)
	local player = core.get_player_by_name(name)
	if not player then return false, "找不到玩家" end
	local live = rockmech.fsmask_live(player)
	clear(name)
	local a = {marks = {}, live = live, hold = now() + seconds}
	active[name] = a
	local center = vector.round(player:get_pos())
	local cells, counts, ms = rockmech.fsmask_scan(center, r)
	apply(player, a, center, cells)
	a.center, a.t = center, now()
	if not live then a.job = core.after(seconds, clear, name) end
	local parts, note = summary(cells, counts)
	return true, ("[rockmech FS 遮罩] 以 %s 為中心 ±%d m，FS ≤ 1 共 %d 格：%s（%.0f ms；%d 秒%s%s）"):format(
		core.pos_to_string(center), r, #cells, parts, ms, seconds,
		live and "後回到即時模式" or "後消失", note)
end

---------------------------------------------------------------------------
-- 即時模式（每個玩家各自設定，存在玩家資料裡）
---------------------------------------------------------------------------

function rockmech.fsmask_live(player)
	return player:get_meta():get_string(META) == "1"
end

function rockmech.set_fsmask_live(player, on)
	local name = player:get_player_name()
	player:get_meta():set_string(META, on and "1" or "0")
	clear(name)
	if on then active[name] = {marks = {}, live = true, dirty = true} end
end

-- 地形改變（挖掘、放置、坍塌、爆破都會經過 queue_support_check）：附近的即時遮罩標記為需更新
local orig_queue = collapse.queue_support_check
collapse.queue_support_check = function(pos, prev)
	orig_queue(pos, prev)
	for _, a in pairs(active) do
		if a.live and a.center and vector.distance(pos, a.center) <= LIVE_R + 2 * cfg.failure.window + 2 then
			a.dirty = true
		end
	end
end

local tick = 0
core.register_globalstep(function(dtime)
	tick = tick + dtime
	if tick < LIVE_TICK then return end
	tick = 0
	local t = now()
	for _, player in ipairs(core.get_connected_players()) do
		if rockmech.fsmask_live(player) then
			local name = player:get_player_name()
			local a = active[name]
			if not a then a = {marks = {}, live = true, dirty = true}; active[name] = a end
			if not (a.hold and t < a.hold) then
				local pos = vector.round(player:get_pos())
				if a.dirty or not a.center or vector.distance(pos, a.center) > LIVE_MOVE
						or t - (a.t or 0) > LIVE_PERIOD then
					local cells = rockmech.fsmask_scan(pos, LIVE_R)
					apply(player, a, pos, cells)
					a.center, a.t, a.dirty, a.hold = pos, t, false, nil
				end
			end
		end
	end
end)

core.register_chatcommand("rockmech_fsmask", {
	params = "on | off | [半徑 1-32，預設 12] [秒數，預設 60]",
	description = "標出周圍若被觸發就會破壞（FS ≤ 1）的岩格（紅 = 節理滑動、橙 = 軸差、紫 = 懸臂／被節理切離）。"
		.. "on/off：即時模式（跟著玩家與地形變化自動更新）",
	func = function(name, param)
		local player = core.get_player_by_name(name)
		if not player then return false, "找不到玩家" end
		local args = param:split(" ")
		if args[1] == "on" or args[1] == "off" then
			rockmech.set_fsmask_live(player, args[1] == "on")
			return true, args[1] == "on"
				and ("[rockmech FS 遮罩] 即時模式開啟（±%d m，移動或地形改變時自動更新）"):format(LIVE_R)
				or "[rockmech FS 遮罩] 已關閉"
		end
		local r = math.max(1, math.min(MAX_R, math.floor(tonumber(args[1]) or DEFAULT_R)))
		local t = math.max(1, math.min(MAX_T, math.floor(tonumber(args[2]) or DEFAULT_T)))
		return show(name, r, t)
	end,
})
