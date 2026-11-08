-- rockmech/fsmask.lua
-- FS < 1 遮罩（除錯／檢視用，不修改地圖）：
--   /rockmech_fsmask [半徑] [秒數]   在玩家周圍標出「若被觸發就會破壞」的岩格
--   /rockmech_fsmask on | off        即時模式（每個玩家各自設定、會記住；也可在資訊頁／物品欄勾選）
--   /rockmech_fswarn on | off        警戒裂紋：玩家周圍 1 < FS < 2 的岩格加上裂紋（預設開啟；應力解決定崩落時，來源是應力解的面 FS）
-- 標示方式：
--   * 半透明發光方塊（實體）套在格子外：紅 = 節理滑動、橙 = 軸差破壞、紫 = 懸臂斷裂／被節理切離、
--     黃 = 關鍵塊體（被節理圍住、會因重力滑出或落下）
--   * HUD 小方點（image_waypoint）：不受遮擋，洞穴裡、岩石後面的格子也看得到
-- 判定與遊戲中的破壞檢查、懸臂判定相同（同一組純函式與參數）。

local cfg = rockmech.cfg
local collapse = rockmech.collapse
local S = rockmech.S

local KINDS = {
	slip = {color = "#ff2020", label = S("Joint sliding")},
	axial = {color = "#ff9900", label = S("Deviatoric failure")},
	overhang = {color = "#b040ff", label = S("Overhang failure / cut off by joints")},
	keyblock = {color = "#ffe000", label = S("Key block")},
	mass = {color = "#ff6a00", label = S("Mass sliding (prism)")},
}
-- 只用於警戒裂紋（不會造成破壞）：明確節理的逐格受剪。節理面剪應力接近強度 → 開始滑移、張開
local SHEAR_KIND = "shear"
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


-- 警戒裂紋：1 < FS < max 的岩格套上一層裂紋，用挖礦的裂紋（crack_anylength.png 的 5 格，由淺到深）；
-- FS 越接近 1 裂得越深。看起來就像這格已經被敲到一半
local WARN_STAGES = 5
local function crack_textures(stage)
	local t = ("crack_anylength.png^[verticalframe:%d:%d"):format(WARN_STAGES, stage)
	return {t, t, t, t, t, t}
end
core.register_entity("rockmech:fswarn", {
	initial_properties = {
		visual = "cube",
		visual_size = {x = 1.02, y = 1.02, z = 1.02},
		textures = crack_textures(0),
		use_texture_alpha = true,
		backface_culling = false,
		glow = 10,
		physical = false,
		collide_with_objects = false,
		pointable = false,
		static_save = false,
	},
})
local function warn_stage(fs)
	local frac = (fs - 1) / (cfg.fswarn.max - 1)
	return math.max(0, math.min(WARN_STAGES - 1, WARN_STAGES - 1 - math.floor(frac * WARN_STAGES)))
end

-- 掃描狀態：center ±r 內每個岩格在各機制中的最小 FS（只保留 FS < fs_max 者）
local function scan_state(center, r, fs_max)
	local st = {a = vector.subtract(center, r), b = vector.add(center, r), best = {}, fs_max = fs_max}
	local a, b, best = st.a, st.b, st.best
	function st.put(p, fs, kind)
		if fs >= fs_max then return end
		if p.x < a.x or p.x > b.x or p.y < a.y or p.y > b.y or p.z < a.z or p.z > b.z then return end
		local k = pkey(p)
		local e = best[k]
		if not e or fs < e.fs then best[k] = {pos = {x = p.x, y = p.y, z = p.z}, fs = fs, kind = kind} end
	end
	function st.result()
		local out = {}
		for _, e in pairs(best) do out[#out + 1] = e end
		return out
	end
	return st
end

local scan_parts = {}

-- 1. 軸差破壞與節理滑動（臨空的岩格）
scan_parts[1] = function(st)
	local a, b, put, fs_max = st.a, st.b, st.put, st.fs_max
	if cfg.failure.enabled or cfg.weakness.enabled then
		local f = rockmech.failure
		local grid = collapse.read_failure_grid(a, b)
		-- 前置篩選：FS ≥ 2c/q，2c/q ≥ fs_max 的格不可能落在顯示範圍內
		local prm = collapse.failure_params(false)
		prm.fs_cut = fs_max
		f.compute_loads(grid, prm)
		-- 明確節理（間距 > weakness.max_spacing）不做逐格破壞，但仍算逐格受剪的 FS 當作警示：
		-- 節理面上剪應力接近強度 → 裂紋（不會因此掉落；超過強度時以最強的裂紋顯示）
		local all_sets = rockmech.get_joint_sets()
		local prm_all
		if prm.weakness and #prm.joint_sets < #all_sets then
			prm_all = {}
			for k, v in pairs(prm) do prm_all[k] = v end
			prm_all.joint_sets = all_sets
			prm_all.axial = false
		end
		for z = a.z, b.z do
			for y = a.y, b.y do
				for x = a.x, b.x do
					local i = f.index(grid, x, y, z)
					if i and grid.lith_of[grid.data[i]] and f.is_exposed(grid, x, y, z) then
						local st = f.cell_state(grid, x, y, z, prm)
						local fa = prm.axial ~= false and st.fs_axial or math.huge
						local fj = st.fs_joint
						if fa <= fj then put({x = x, y = y, z = z}, fa, "axial")
						else put({x = x, y = y, z = z}, fj, "slip") end
						if prm_all then
							local s2 = f.cell_state(grid, x, y, z, prm_all)
							if s2 and s2.fs_joint < fs_max then
								put({x = x, y = y, z = z}, math.max(s2.fs_joint, 1.01), SHEAR_KIND)
							end
						end
					end
				end
			end
		end
	end

end

-- 2. 懸臂：以範圍內所有臨空的鍵結格為起點（所在的懸空段底部可能在範圍外），每個懸空段取段內最小 FS
scan_parts[2] = function(st)
	local a, b, put = st.a, st.b, st.put
	if cfg.overhang.enabled and not cfg.fem.drive then
		local grid = collapse.read_overhang_grid(a, b)
		local nx, ny = grid.nx, grid.ny
		local data, bonded_of, solid_of = grid.data, grid.bonded_of, grid.solid_of
		local starts = {}
		for z = a.z, b.z do
			for y = a.y, b.y do
				for x = a.x, b.x do
					local i = 1 + (x - grid.ox) + (y - grid.oy) * nx + (z - grid.oz) * nx * ny
					local gs = nx * ny
					if bonded_of[data[i]] and (not solid_of[data[i - nx]] or not solid_of[data[i + 1]]
							or not solid_of[data[i - 1]] or not solid_of[data[i + gs]] or not solid_of[data[i - gs]]) then
						starts[#starts + 1] = {x = x, y = y, z = z}
					end
				end
			end
		end
		for _, sg in ipairs(rockmech.overhang.scan_segments(grid, collapse.overhang_params(), starts)) do
			for _, p in ipairs(sg.cells) do put(p, sg.fs, "overhang") end
		end
	end

end

-- 3. 關鍵塊體：以範圍內所有臨空的鍵結格為起點（同一岩塊只算一次）
scan_parts[3] = function(st)
	local a, b, put = st.a, st.b, st.put
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
			for _, p in ipairs(blk.cells) do put(p, blk.fs, "keyblock") end
		end
	end
end

-- 4. 整體滑動（楔形稜柱）：以範圍內臨空的鍵結格為起點，所有分析過的稜柱都取其 FS
scan_parts[4] = function(st)
	local a, b, put = st.a, st.b, st.put
	local kc = cfg.keyblock
	if kc.enabled and kc.mass then
		local R = math.min(kc.mass_radius, 20)
		local grid = collapse.read_grid(vector.subtract(a, R), vector.add(b, R), true)
		local nx, ny = grid.nx, grid.ny
		local data, bonded_of, solid_of = grid.data, grid.bonded_of, grid.solid_of
		local function idx(x, y, z) return 1 + (x - grid.ox) + (y - grid.oy) * nx + (z - grid.oz) * nx * ny end
		local starts = {}
		for z = a.z, b.z do
			for y = a.y, b.y do
				for x = a.x, b.x do
					if bonded_of[data[idx(x, y, z)]] and (not solid_of[data[idx(x + 1, y, z)]]
							or not solid_of[data[idx(x - 1, y, z)]] or not solid_of[data[idx(x, y - 1, z)]]
							or not solid_of[data[idx(x, y, z + 1)]] or not solid_of[data[idx(x, y, z - 1)]]) then
						starts[#starts + 1] = {x = x, y = y, z = z}
					end
				end
			end
		end
		local kp = collapse.keyblock_params()
		kp.max_mass, kp.max_floods, kp.collect_all = kc.mass_max, kc.mass_floods, true
		local c = vector.divide(vector.add(a, b), 2)
		local lith = rockmech.lith_at(c.x, c.y, c.z)
		kp.bridge_c = collapse.rock.at(lith.name, c.y).sigt * 1000
		for _, m in ipairs(rockmech.keyblock.find_masses(grid, kp, starts)) do
			for _, p in ipairs(m.cells) do put(p, m.fs, "mass") end
		end
	end
end

-- 5. 應力解：最近幾次解判定過的面（femstress.lua），與崩落判定同一個 FS
scan_parts[5] = function(st)
	if not cfg.fem.drive then return end
	rockmech.fem_watch(vector.divide(vector.add(st.a, st.b), 2))
	for _, c in ipairs(rockmech.fem_warned(st.a, st.b)) do
		st.put(c.pos, c.fs, c.mode == "拉" and "fem_tension" or "fem_shear")
	end
end

-- 一次算完。回傳 {{pos, fs, kind = "slip"|"axial"|"overhang"|"keyblock"|"mass"}...}, ms
function rockmech.fs_scan(center, r, fs_max)
	local t0 = core.get_us_time()
	local st = scan_state(center, r, fs_max)
	for _, part in ipairs(scan_parts) do part(st) end
	return st.result(), (core.get_us_time() - t0) / 1000
end

-- 分三個伺服器步執行（每步一種機制，避免單次卡頓太久），完成後呼叫 cb(cells)
function rockmech.fs_scan_async(center, r, fs_max, cb)
	local st = scan_state(center, r, fs_max)
	local i = 0
	local function step()
		i = i + 1
		local part = scan_parts[i]
		if not part then return cb(st.result()) end
		part(st)
		core.after(0, step)
	end
	step()
end

-- center ±r 內 FS ≤ 1 的格子（FS 遮罩用）。回傳 cells = {{pos, kind, fs}...}, counts, ms
function rockmech.fsmask_scan(center, r)
	local all, ms = rockmech.fs_scan(center, r, 1 + 1e-9)
	local counts = {slip = 0, axial = 0, overhang = 0, keyblock = 0, mass = 0, shear = 0}
	for _, c in ipairs(all) do counts[c.kind] = counts[c.kind] + 1 end
	return all, counts, ms
end

-- 玩家名稱 → {marks（FS 遮罩）, wmarks（警戒裂紋）, mask, warn, center, t, dirty, hold, job}
local active = {}
local META = "rockmech:fsmask"
local META_W = "rockmech:fswarn"
local LIVE_R = 10          -- 即時模式的範圍 (m)
local LIVE_MOVE = 3        -- 玩家移動超過此距離就重新掃描 (m)
local LIVE_PERIOD = 30     -- 保底重新掃描間隔 (s)
local LIVE_TICK = 1        -- 檢查間隔 (s)

local function now() return core.get_us_time() / 1e6 end

local function remove_mark(player, m)
	if m.obj and m.obj:get_pos() then m.obj:remove() end
	if m.hud and player then player:hud_remove(m.hud) end
end

local function clear_marks(player, marks)
	for k, m in pairs(marks) do remove_mark(player, m); marks[k] = nil end
end

local function clear(name)
	local a = active[name]
	if not a then return end
	local player = core.get_player_by_name(name)
	clear_marks(player, a.marks)
	clear_marks(player, a.wmarks)
	if a.job then a.job:cancel() end
	active[name] = nil
end

core.register_on_leaveplayer(function(player)
	clear(player:get_player_name())
end)

local function by_distance(cells, center)
	table.sort(cells, function(u, v)
		return vector.distance(u.pos, center) < vector.distance(v.pos, center)
	end)
end

-- FS 遮罩標記：只增減有變化的（不閃爍、少送封包）
local function apply(player, a, center, cells)
	by_distance(cells, center)
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

-- 警戒裂紋的破壞機制名稱（HUD 用）
local WARN_LABEL = {
	slip = S("Joint sliding"), axial = S("Deviatoric failure"), overhang = S("Overhang failure"), keyblock = S("Key block"),
	mass = S("Mass sliding (prism)"), shear = S("Joint in shear (warning only; nothing falls because of it)"),
	fem_tension = S("Stress solution: tensile failure"), fem_shear = S("Stress solution: shear failure"),
}

-- 玩家看到的某格裂紋：回傳 {kind, label, fs} 或 nil
function rockmech.fswarn_at(name, pos)
	local a = active[name]
	local m = a and a.wmarks[pkey(vector.round(pos))]
	if not (m and m.kind) then return nil end
	return {kind = m.kind, label = WARN_LABEL[m.kind] or m.kind, fs = m.fs}
end

-- 破裂聲的字幕（左下角）：連續響時延長同一個字幕
local CAPTION_TIME = 2.5
local function crack_caption(player, a)
	a.wcap_t = now() + CAPTION_TIME
	if a.wcap then return end
	a.wcap = player:hud_add({type = "text", position = {x = 0.01, y = 0.95}, alignment = {x = 1, y = -1},
		text = S("*rock cracking*"), number = 0xFFC080, z_index = 100})
	local name = player:get_player_name()
	local function check()
		if active[name] ~= a then return end
		local left = a.wcap_t - now()
		if left > 0 then core.after(left, check); return end
		local pl = core.get_player_by_name(name)
		if pl then pl:hud_remove(a.wcap) end
		a.wcap = nil
	end
	core.after(CAPTION_TIME, check)
end

-- 破裂聲：這次掃描新出現或變嚴重的裂紋，在最近的那格響一聲（定位音效隨距離衰減，放在遠處的頂板中央會聽不到）；
-- 這些裂紋裡最接近 FS = 1 的決定音量。
-- 只比前後兩次都掃到的範圍，走動帶進範圍的舊裂紋不算；重開顯示後的第一次掃描也不算。
-- 附近地形剛改變（SOUND_WINDOW 秒內）才響：換個解的範圍時，同一格的 FS 會有小幅差異，那不是岩石裂了
local SOUND_WINDOW = 5
local function crack_sound(player, a, center, cells)
	local seen, near, worst = {}, nil, -1
	for _, c in ipairs(cells) do         -- 由近到遠
		local k = pkey(c.pos)
		local stage = warn_stage(c.fs)
		seen[k] = stage
		if a.wseen and stage > (a.wseen[k] or -1)
				and math.max(math.abs(c.pos.x - a.wcenter.x), math.abs(c.pos.y - a.wcenter.y), math.abs(c.pos.z - a.wcenter.z)) <= LIVE_R then
			near = near or c
			worst = math.max(worst, stage)
		end
	end
	a.wseen, a.wcenter = seen, center
	if near and cfg.fswarn.sound_gain > 0 and now() - (a.wchange or -math.huge) <= SOUND_WINDOW then
		local gain = cfg.fswarn.sound_gain * (0.5 + 0.5 * worst / (WARN_STAGES - 1))
		core.sound_play("rockmech_crack", {
			pos = near.pos, to_player = player:get_player_name(), gain = gain,
			pitch = 0.9 + 0.2 * math.random(), max_hear_distance = cfg.fswarn.sound_distance,
		}, true)
		crack_caption(player, a)
		core.log("action", ("[rockmech] 破裂聲 %s 距離 %.1f m、音量 %.2f"):format(
			core.pos_to_string(near.pos), vector.distance(near.pos, center), gain))
	end
end

-- 節理滑動（slip、shear）不套裂紋，改成偶爾從臨空的那一面噴出一小撮碎石（FS 越接近 1 越常噴、噴越多）
local JOINT_KIND = {slip = true, shear = true}
local SPURT_TICK = 0.5                 -- 每幾秒擲一次
local SPURT_MAX = 2                    -- 每位玩家每次最多噴幾處
local function spurt_chance(stage) return 0.006 + 0.008 * stage end    -- 每次擲到的機率：一格平均一分多鐘到十幾秒噴一次
local SIDES = {{x = 1, y = 0, z = 0}, {x = -1, y = 0, z = 0}, {x = 0, y = 0, z = 1}, {x = 0, y = 0, z = -1},
	{x = 0, y = -1, z = 0}, {x = 0, y = 1, z = 0}}
local function spurt(name, pos, stage)
	local node = core.get_node(pos).name
	if not rockmech.lith_of_node[node] then return end
	local player = core.get_player_by_name(name)
	if not player then return end
	local eye = vector.add(player:get_pos(), {x = 0, y = player:get_properties().eye_height or 1.5, z = 0})
	-- 噴的那一面：外面是空氣、而且玩家看得到（中間沒有岩層、煤層或其他東西擋住）
	local n
	for _, d in ipairs(SIDES) do
		if core.get_node(vector.add(pos, d)).name == "air" then
			local face = vector.add(pos, vector.multiply(d, 0.51))
			local seen = true
			for pt in core.raycast(eye, face, false, false) do
				if pt.type == "node" and not vector.equals(pt.under, pos) then
					local nd = core.registered_nodes[core.get_node(pt.under).name]
					if nd and nd.walkable ~= false then seen = false; break end
				end
			end
			if seen then n = d; break end
		end
	end
	if not n then return end
	local f = vector.add(pos, vector.multiply(n, 0.52))
	local sp = 1.2 + 0.4 * stage
	local spread = {x = n.x == 0 and 0.45 or 0.02, y = n.y == 0 and 0.45 or 0.02, z = n.z == 0 and 0.45 or 0.02}
	local common = {
		time = 0.25, playername = name, collisiondetection = true,
		minpos = vector.subtract(f, spread), maxpos = vector.add(f, spread),
		minvel = {x = n.x * sp - 0.4, y = n.y * sp + 0.2, z = n.z * sp - 0.4},
		maxvel = {x = n.x * sp * 1.8 + 0.4, y = n.y * sp * 1.8 + 1.2, z = n.z * sp * 1.8 + 0.4},
		minacc = {x = 0, y = -9.8, z = 0}, maxacc = {x = 0, y = -9.8, z = 0},
	}
	-- 碎屑（這一格岩石的碎片）
	local deb = table.copy(common)
	deb.amount, deb.minexptime, deb.maxexptime, deb.minsize, deb.maxsize = 3 + stage * 2, 0.5, 1.2, 0, 0
	deb.node = {name = node}
	core.add_particlespawner(deb)
end
local spurt_t = 0
core.register_globalstep(function(dtime)
	spurt_t = spurt_t + dtime
	if spurt_t < SPURT_TICK then return end
	spurt_t = 0
	for name, a in pairs(active) do
		local done = 0
		for _, m in pairs(a.wmarks or {}) do
			if done >= SPURT_MAX then break end
			if m.spurt and m.pos and math.random() < spurt_chance(m.spurt) then
				spurt(name, m.pos, m.spurt)
				done = done + 1
			end
		end
	end
end)

-- 警戒裂紋標記（1 < FS < max）：裂紋級數變了就換貼圖；節理滑動改成噴碎屑（上面）
local function apply_warn(player, a, center, cells)
	by_distance(cells, center)
	crack_sound(player, a, center, cells)
	local want = {}
	for i, c in ipairs(cells) do
		if i <= MAX_ENTITIES then want[pkey(c.pos)] = c end
	end
	for k, m in pairs(a.wmarks) do
		if not want[k] then remove_mark(player, m); a.wmarks[k] = nil end
	end
	for k, c in pairs(want) do
		local stage = warn_stage(c.fs)
		local m = a.wmarks[k]
		if m and m.obj and not m.obj:get_pos() then m.obj = nil end
		if not m then m = {}; a.wmarks[k] = m end
		m.kind, m.fs, m.pos = c.kind, c.fs, c.pos
		if JOINT_KIND[c.kind] then
			if m.obj and m.obj:get_pos() then m.obj:remove() end
			m.obj, m.stage, m.spurt = nil, nil, stage
		elseif not m.obj then
			m.spurt = nil
			m.obj = core.add_entity(c.pos, "rockmech:fswarn")
			m.stage = nil
		end
		if m.obj and m.stage ~= stage then
			m.obj:set_properties({textures = crack_textures(stage)})
			m.stage = stage
		end
	end
end

local function summary(cells, counts)
	local parts = {}
	for _, kind in ipairs(cfg.fem.drive and {"slip", "keyblock", "mass"} or {"slip", "axial", "overhang", "keyblock", "mass"}) do
		parts[#parts + 1] = core.colorize(KINDS[kind].color, ("■ %s %d"):format(KINDS[kind].label, counts[kind]))
	end
	local note = ""
	if #cells > MAX_ENTITIES then note = S("; boxes only mark the nearest @1 cells", ("%d"):format(MAX_ENTITIES)) end
	if #cells > MAX_WAYPOINTS then note = note .. S("; see-through dots only mark the nearest @1 cells", ("%d"):format(MAX_WAYPOINTS)) end
	return table.concat(parts, "  "), note
end

---------------------------------------------------------------------------
-- 個人設定（存在玩家資料裡）
---------------------------------------------------------------------------

function rockmech.fsmask_live(player)
	return player:get_meta():get_string(META) == "1"
end

-- 警戒裂紋：預設開啟
function rockmech.fswarn_enabled(player)
	return player:get_meta():get_string(META_W) ~= "0"
end

local function ensure(name)
	local a = active[name]
	if not a then a = {marks = {}, wmarks = {}, dirty = true}; active[name] = a end
	return a
end

function rockmech.set_fsmask_live(player, on)
	local name = player:get_player_name()
	player:get_meta():set_string(META, on and "1" or "0")
	local a = ensure(name)
	if a.job then a.job:cancel(); a.job = nil end
	a.hold = nil
	if not on then clear_marks(player, a.marks) end
	a.dirty = true
end

function rockmech.set_fswarn(player, on)
	local name = player:get_player_name()
	player:get_meta():set_string(META_W, on and "1" or "0")
	local a = ensure(name)
	if not on then clear_marks(player, a.wmarks); a.wseen = nil end
	a.dirty = true
end

-- 單次顯示 FS 遮罩 seconds 秒（即時模式開啟時，期間暫停即時更新）
local function show(name, r, seconds)
	local player = core.get_player_by_name(name)
	if not player then return false, S("Player not found") end
	local live = rockmech.fsmask_live(player)
	local a = ensure(name)
	if a.job then a.job:cancel(); a.job = nil end
	a.hold = now() + seconds
	local center = vector.round(player:get_pos())
	local cells, counts, ms = rockmech.fsmask_scan(center, r)
	apply(player, a, center, cells)
	if not live then
		a.job = core.after(seconds, function()
			local p = core.get_player_by_name(name)
			local aa = active[name]
			if aa then clear_marks(p, aa.marks); aa.hold = nil; aa.job = nil end
		end)
	end
	local parts, note = summary(cells, counts)
	local sec = ("%d"):format(seconds)
	return true, S("[rockmech FS mask] centered on @1 ±@2 m, @3 cells with FS ≤ 1: @4 (@5 ms; @6@7)",
		core.pos_to_string(center), ("%d"):format(r), ("%d"):format(#cells), parts, ("%.0f"):format(ms),
		live and S("back to live mode after @1 s", sec) or S("disappears after @1 s", sec), note)
end

---------------------------------------------------------------------------
-- 即時更新（FS 遮罩即時模式、警戒裂紋共用一次掃描）
---------------------------------------------------------------------------

-- 地形改變（挖掘、放置、坍塌、爆破都會經過 queue_stability_check）：附近的即時顯示標記為需更新

-- 放置非岩石方塊（墊支撐等）不經過 queue_stability_check，另外標記附近需更新
core.register_on_placenode(function(pos)
	for _, a in pairs(active) do
		if a.center and vector.distance(pos, a.center) <= LIVE_R + 2 * cfg.failure.window + 2 then
			a.dirty = true
		end
	end
end)

local orig_queue = collapse.queue_stability_check
local block_check = false      -- 應力解完的塊體判定也走這裡，那不是地形改變
collapse.queue_stability_check = function(pos, prev)
	orig_queue(pos, prev)
	for _, a in pairs(active) do
		if a.center and vector.distance(pos, a.center) <= LIVE_R + 2 * cfg.failure.window + 2 then
			a.dirty = true
			if not block_check then a.wchange = now() end
		end
	end
end
local orig_block = collapse.queue_block_check
collapse.queue_block_check = function(pos)
	block_check = true
	orig_block(pos)
	block_check = false
end

-- 應力解完：附近的即時顯示重新掃描
function rockmech.fswarn_refresh(pos)
	for _, a in pairs(active) do
		if a.center and vector.distance(pos, a.center) <= LIVE_R + cfg.fem.radius then a.dirty = true end
	end
end

-- 從 cells（這次掃描：玩家周圍 ±LIVE_R、FS < 門檻者）挑出要顯示裂紋的：1 < FS < 門檻
local function select_warned(cells)
	local out = {}
	for _, c in ipairs(cells) do
		if c.fs > 1 then out[#out + 1] = c end
	end
	return out
end

-- FS ≤ 1 理論上就該壞：掃描看到 FS ≤ 1、還沒處理的格子，觸發該位置的判定
-- （判定照常套用「只有開挖造成的才壞」；同一格 60 秒內不重複觸發，每次掃描最多 24 個位置）
local TRIGGER_COOLDOWN, TRIGGER_MAX = 60, 24
local triggered = {}
local STABILITY_KINDS = {overhang = true, keyblock = true}
local FAILURE_KINDS = {axial = true, slip = true, mass = true}
local function trigger_failed(cells)
	local t, n = now(), 0
	for _, c in ipairs(cells) do
		if c.fs <= 1 and (STABILITY_KINDS[c.kind] or FAILURE_KINDS[c.kind]) then
			local k = pkey(c.pos)
			if not triggered[k] or t - triggered[k] > TRIGGER_COOLDOWN then
				triggered[k] = t
				if STABILITY_KINDS[c.kind] then collapse.queue_stability_check(c.pos)
				else collapse.queue_failure_check(c.pos) end
				n = n + 1
				if n >= TRIGGER_MAX then break end
			end
		end
	end
	if n > 0 then
		for k, v in pairs(triggered) do
			if t - v > TRIGGER_COOLDOWN then triggered[k] = nil end
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
		local mask, warn = rockmech.fsmask_live(player), rockmech.fswarn_enabled(player)
		if mask or warn then
			local name = player:get_player_name()
			local a = ensure(name)
			local pos = vector.round(player:get_pos())
			if not a.busy and (a.dirty or not a.center or vector.distance(pos, a.center) > LIVE_MOVE
					or t - (a.t or 0) > LIVE_PERIOD) then
				a.busy = true
				a.center, a.t, a.dirty = pos, t, false
				rockmech.fs_scan_async(pos, LIVE_R, warn and cfg.fswarn.max or (1 + 1e-9), function(cells)
					a.busy = false
					local pl = core.get_player_by_name(name)
					if not pl or active[name] ~= a then return end
					local masked = {}
					for _, c in ipairs(cells) do
						if c.fs <= 1 then masked[#masked + 1] = c end
					end
					local m2, w2 = rockmech.fsmask_live(pl), rockmech.fswarn_enabled(pl)
					if m2 and not (a.hold and now() < a.hold) then apply(pl, a, pos, masked) end
					if w2 then
						apply_warn(pl, a, pos, select_warned(cells))
					end
					trigger_failed(cells)
				end)
			end
		end
	end
end)

core.register_chatcommand("rockmech_fsmask", {
	params = S("on | off | [radius 1-32, default 12] [seconds, default 60]"),
	description = S("Mark nearby rock cells that would fail if triggered (FS ≤ 1) (red = joint sliding, orange = deviatoric, purple = overhang / cut off by joints, yellow = key block). on/off: live mode (updates automatically as you move and the terrain changes)"),
	func = function(name, param)
		local player = core.get_player_by_name(name)
		if not player then return false, S("Player not found") end
		local args = param:split(" ")
		if args[1] == "on" or args[1] == "off" then
			rockmech.set_fsmask_live(player, args[1] == "on")
			return true, args[1] == "on"
				and S("[rockmech FS mask] live mode on (±@1 m, updates automatically when you move or the terrain changes)", ("%d"):format(LIVE_R))
				or S("[rockmech FS mask] off")
		end
		local r = math.max(1, math.min(MAX_R, math.floor(tonumber(args[1]) or DEFAULT_R)))
		local t = math.max(1, math.min(MAX_T, math.floor(tonumber(args[2]) or DEFAULT_T)))
		return show(name, r, t)
	end,
})

core.register_chatcommand("rockmech_fswarn", {
	params = "on | off",
	description = S("Warning cracks: rock cells whose FS drops to 1 < FS < threshold (default 2) because of excavation get cracks; the closer FS is to 1, the worse the cracks (on by default)"),
	func = function(name, param)
		local player = core.get_player_by_name(name)
		if not player then return false, S("Player not found") end
		local on
		if param == "on" then on = true elseif param == "off" then on = false
		else on = not rockmech.fswarn_enabled(player) end
		rockmech.set_fswarn(player, on)
		return true, on and S("[rockmech] warning cracks on (1 < FS < @1, ±@2 m)", ("%g"):format(cfg.fswarn.max), ("%d"):format(LIVE_R))
			or S("[rockmech] warning cracks off")
	end,
})

-- 有裂紋的岩石比較好挖：接近破壞的岩石已有微裂（損傷），強度較低。挖的時間 = 原本的時間 × 係數，
-- FS → 1 時係數是 rockmech_fswarn_dig_min，FS = max 時是 1，中間線性。
-- 挖的時間是引擎依方塊種類算的，不能每格不同：伺服器跟著玩家按住左鍵挖的那一格計時，時間到了直接敲破
-- （引擎自己的挖礦進度照舊，只是方塊提早破）
local digging = {}          -- 玩家名稱 → {key, pos, t}
local function pointed_node(player)
	local def = player:get_wielded_item():get_definition()
	local range = def and def.range or 4
	local eye = vector.add(player:get_pos(), {x = 0, y = player:get_properties().eye_height or 1.625, z = 0})
	for pt in core.raycast(eye, vector.add(eye, vector.multiply(player:get_look_dir(), range)), false, false) do
		if pt.type == "node" then return pt.under end
	end
end
core.register_globalstep(function(dtime)
	for _, player in ipairs(core.get_connected_players()) do
		local name = player:get_player_name()
		local pos = player:get_player_control().dig and not player:get_attach() and pointed_node(player)
		local w = pos and rockmech.fswarn_at(name, pos)
		local node = w and core.get_node(pos)
		if not (node and rockmech.lith_of_node[node.name]) then
			digging[name] = nil
		else
			local k = pkey(pos)
			local dg = digging[name]
			if not dg or dg.key ~= k then dg = {key = k, t = 0}; digging[name] = dg end
			dg.t = dg.t + dtime
			local item = player:get_wielded_item()
			local params = core.get_dig_params(core.registered_nodes[node.name].groups, item:get_tool_capabilities(), item:get_wear())
			if params.diggable then
				local frac = math.max(0, math.min(1, (w.fs - 1) / (cfg.fswarn.max - 1)))
				local need = params.time * (cfg.fswarn.dig_min + (1 - cfg.fswarn.dig_min) * frac)
				if dg.t >= need then
					digging[name] = nil
					core.node_dig(pos, node, player)
				end
			end
		end
	end
end)
core.register_on_leaveplayer(function(player) digging[player:get_player_name()] = nil end)
