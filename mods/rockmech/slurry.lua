-- rockmech/slurry.lua
-- 液體：穩定液（皂土泥漿，連續壁溝槽的護壁液）和水，可以混在一起。液壓頂住溝壁（femstress.lua 當面壓）。
--
-- 自製的守恆流體（不用引擎的液體：引擎的液體一格源頭可以無限往下流）：
--   每格分 8 級（1/8 m）。總量守恆：灌多少就有多少。
--   每一步（rockmech_slurry_step 秒，慢慢流）：底下是空的 → 整格往下掉；底下不滿 → 先把底下補滿；
--   底下撐著 → 跟四周比液面，比最低的那一格高 2 級以上就分一半過去（差 1 級就算平了）。
--   流進洞裡、漏到坑裡，液面就降下來，要補液。
--   人、東西可以在裡面（不能站、會減速，像在水裡）；放方塊、碎石掉進去會把那一格的液往上擠（排開）
-- 成分：每格液體是幾種成分的混合（現在只有皂土 b：1 = 純穩定液、0 = 純水；之後可以加酸、銅……，COMPS）。
--   兩組方塊：rockmech:slurry(_l1…_l7) 一律是純穩定液（沒有 metadata，舊世界不用轉）；
--   rockmech:water(_l1…_l7) 是水和混合液：成分記在私有 metadata（lq_<成分>，不送給客戶端），純水不寫；
--   param2 = 皂土比例的顏色（調色盤從水的藍到穩定液的土黃，只是畫面和應力解單位重的快取）。
--   液體從一格搬到另一格，成分照體積加權混合（move），每種成分都守恆。液面升降用 swap_node，metadata 不會掉。
--   單位重 γ = 9.81 + b·(11 − 9.81) kN/m³
-- 碎石的孔隙：碎石格也裝得了液（孔隙率 n，rockmech_rubble_porosity）。r 級碎石的孔隙裝 round(n·r) 級，上面空的 8 − r 級
--   照常裝；水位在碎石裡時液面 = r·w / 孔隙容量。量和成分記在 mod storage 的位置表（碎石的 param2 已經存成分比例）。
--   碎石被挖走、流走：液留在原地；碎石變多：多的往上擠。只畫液面那一層（半格碎石上面的自由液，一格一個拉伸的方塊實體），
--   孔隙裡的液看不到也不畫

local S = rockmech.S
local cfg = rockmech.cfg

local NL = 8
local BASE = "rockmech:slurry"        -- 純穩定液
local WBASE = "rockmech:water"        -- 水、混合液
local GAMMA, GAMMA_W = 11, 9.81       -- kN/m³（皂土泥漿比重約 1.05–1.1；水）
local STEP = tonumber(core.settings:get("rockmech_slurry_step") or "") or 0.25
rockmech.SLURRY = BASE
rockmech.WATER = WBASE
rockmech.SLURRY_GAMMA = GAMMA
rockmech.WATER_GAMMA = GAMMA_W
rockmech.slurry_level = {}           -- 方塊名稱 → 級數（滿格 8），兩組都在
local is_water = {}                  -- 水那一組的方塊名稱 → true
rockmech.liquid_is_water = is_water
-- 應力解裡也算液壓的其他流體（concrete.lua 的新拌混凝土）：方塊名稱 → {級數比例, γ kN/m³}
rockmech.fluid_extra = rockmech.fluid_extra or {}

-- 成分 ---------------------------------------------------------------
local COMPS = {"b"}                  -- 成分名稱（metadata 鍵 lq_<名稱>）
local PRIV = {}
for i, c in ipairs(COMPS) do PRIV[i] = "lq_" .. c end
local SLURRY_C = {b = 1}             -- 純穩定液
local WATER_C = {}                   -- 純水
rockmech.LIQUID_SLURRY, rockmech.LIQUID_WATER = SLURRY_C, WATER_C
local function is_pure_slurry(c)
	if c == SLURRY_C then return true end
	if (c.b or 0) < 0.999 then return false end
	for k, v in pairs(c) do if k ~= "b" and v > 1e-6 then return false end end
	return true
end
local function is_pure_water(c)
	if c == WATER_C then return true end
	for _, v in pairs(c) do if v > 1e-6 then return false end end
	return true
end
-- 體積 v1 的 c1 和 v2 的 c2 混在一起
local function mix(c1, v1, c2, v2)
	if v2 <= 0 or c1 == c2 then return c1 end
	if v1 <= 0 then return c2 end
	local tot, out = v1 + v2, {}
	for k, x in pairs(c1) do out[k] = (x * v1 + (c2[k] or 0) * v2) / tot end
	for k, x in pairs(c2) do if out[k] == nil then out[k] = x * v2 / tot end end
	if is_pure_slurry(out) then return SLURRY_C end
	if is_pure_water(out) then return WATER_C end
	return out
end
rockmech.liquid_mix = mix
local function gamma_of(c) return GAMMA_W + (c.b or 0) * (GAMMA - GAMMA_W) end
rockmech.liquid_gamma = gamma_of
local function p2_of(c) return math.max(0, math.min(255, math.floor((c.b or 0) * 255 + 0.5))) end

local COLOR = "#8a7a5c"               -- 穩定液
local WCOLOR = "#3f73a8"              -- 水
local function rgb(hex) return tonumber(hex:sub(2, 3), 16), tonumber(hex:sub(4, 5), 16), tonumber(hex:sub(6, 7), 16) end
local function color_at(t)            -- t = 皂土比例
	local r0, g0, b0 = rgb(WCOLOR)
	local r1, g1, b1 = rgb(COLOR)
	return math.floor(r0 + (r1 - r0) * t + 0.5), math.floor(g0 + (g1 - g0) * t + 0.5), math.floor(b0 + (b1 - b0) * t + 0.5)
end
local function color_hex(c) local r, g, b = color_at(c.b or 0); return ("#%02x%02x%02x"):format(r, g, b) end
-- 調色盤（256 × 1）：param2 i → 皂土比例 i/255 的顏色
local PALETTE = "rockmech_liquid_palette.png"
do
	local px = {}
	for i = 0, 255 do
		local r, g, b = color_at(i / 255)
		px[i + 1] = string.char(r, g, b, 255)
	end
	local dir = core.get_worldpath() .. "/rockmech_media"
	core.mkdir(dir)
	local path = dir .. "/" .. PALETTE
	local fh = assert(io.open(path, "wb"))
	fh:write(core.encode_png(256, 1, table.concat(px)))
	fh:close()
	core.dynamic_add_media({filepath = path})
end

local function name_of(k)            -- 純穩定液那一組（舊 API）
	if k <= 0 then return "air" end
	if k >= NL then return BASE end
	return BASE .. "_l" .. k
end
rockmech.slurry_with_level = name_of
local function wname_of(k)
	if k <= 0 then return "air" end
	if k >= NL then return WBASE end
	return WBASE .. "_l" .. k
end
local function name_for(k, c) return is_pure_slurry(c) and name_of(k) or wname_of(k) end

-- 被擠掉（放方塊、碎石掉進來、之後灌混凝土）：那一格的液往上推（排開），不會憑空消失
local internal = false               -- 流動自己改的不算
local displace
local comp_of
for k = 1, NL do
	local top = -0.5 + k / NL
	for fam = 1, 2 do
		local water = fam == 2
		local name = water and wname_of(k) or name_of(k)
		core.register_node(name, {
			description = water and S("Water") or S("Bentonite slurry"),
			drawtype = "nodebox",
			node_box = {type = "fixed", fixed = {-0.5, -0.5, -0.5, 0.5, top, 0.5}},
			tiles = {water and "[fill:16x16:#ffffffb0" or ("[fill:16x16:" .. COLOR .. "c8")},
			use_texture_alpha = "blend",
			paramtype = "light",
			paramtype2 = water and "color" or nil,
			palette = water and PALETTE or nil,
			sunlight_propagates = true,
			walkable = false, pointable = false, diggable = false, buildable_to = true,
			liquid_move_physics = true, move_resistance = 1,
			post_effect_color = water and {a = 150, r = 0x3a, g = 0x5a, b = 0x80} or {a = 200, r = 0x6a, g = 0x5c, b = 0x44},
			drowning = 1,
			drop = "",
			is_ground_content = false,
			groups = {rockmech_slurry = k, rockmech_water = water and 1 or nil, not_in_creative_inventory = 1},
			on_destruct = function(pos)
				if internal then return end
				local p = vector.copy(pos)
				local c = comp_of(p, {name = name})
				core.after(0, function() displace(p, k, c) end)
			end,
		})
		rockmech.slurry_level[name] = k
		if water then is_water[name] = true end
	end
end

local function level_at(p)
	local n = core.get_node(p).name
	if n == "air" then return 0 end
	return rockmech.slurry_level[n]
end
-- 液體格的成分（node 可省略）；空氣回傳純水（空格沒有成分，混進來的會蓋過去）
comp_of = function(p, node)
	node = node or core.get_node(p)
	if not is_water[node.name] then return rockmech.slurry_level[node.name] and SLURRY_C or WATER_C end
	local m = core.get_meta(p)
	local c, any = {}, false
	for i, key in ipairs(COMPS) do
		local v = m:get_float(PRIV[i])
		if v ~= 0 then c[key] = v; any = true end
	end
	return any and c or WATER_C
end
rockmech.liquid_comp = comp_of

local schedule
-- 液量變了（流動、倒、抽、滲進碎石）：同一區累積變動 ≥ 1 m³（8 級），等那一區流平（安靜 QUIET 秒，持續流動最多等
-- MAXWAIT 秒）再排一次應力解（femstress.lua），應力解讀到的液面就是畫面上的液面
local QUIET, MAXWAIT = 1, 5
local changed = {}           -- 區 → {p, acc, first, last}
local function note_change(p, d)
	if d == 0 or not rockmech.fem_queue or not cfg.fem.drive then return end
	local s = math.max(1, math.floor(cfg.fem.radius / 2))
	local key = math.floor(p.x / s) .. "," .. math.floor(p.y / s) .. "," .. math.floor(p.z / s)
	local t = core.get_us_time() / 1e6
	local c = changed[key]
	if not c then c = {p = vector.copy(p), acc = 0, first = t}; changed[key] = c end
	c.acc, c.last = c.acc + math.abs(d), t
end
local fem_t = 0
core.register_globalstep(function(dt)
	fem_t = fem_t + dt
	if fem_t < 0.5 then return end
	fem_t = 0
	local t = core.get_us_time() / 1e6
	for key, c in pairs(changed) do
		if t - c.last >= QUIET or t - c.first >= MAXWAIT then
			changed[key] = nil
			if c.acc >= NL then rockmech.fem_queue(c.p, 1, false, true) end
		end
	end
end)
-- 把 p（空氣或液體的格）設成 k 級、成分 c。液面升降用 swap_node（不觸發排開、metadata 留著），成分寫私有 metadata
local function set_liquid(p, k, c)
	local node = core.get_node(p)
	local old = rockmech.slurry_level[node.name] or 0
	local name = name_for(k, c)
	local water = is_water[name]
	local p2 = water and p2_of(c) or 0
	if node.name ~= name or (water and node.param2 ~= p2) then
		internal = true
		if old > 0 or node.name == "air" then core.swap_node(p, {name = name, param2 = p2})
		else core.set_node(p, {name = name, param2 = p2}) end
		internal = false
	end
	if water and not is_pure_water(c) then
		local m = core.get_meta(p)
		for i, key in ipairs(COMPS) do m:set_float(PRIV[i], c[key] or 0) end
		m:mark_as_private(PRIV)
	elseif is_water[node.name] then
		local m = core.get_meta(p)
		for i = 1, #PRIV do m:set_string(PRIV[i], "") end
	end
	note_change(p, k - old)
end
local function set_level(p, k) set_liquid(p, k, comp_of(p)) end

-- 碎石孔隙裡的液 ---------------------------------------------------------
local PORE = tonumber(core.settings:get("rockmech_rubble_porosity") or "") or 0.35
rockmech.RUBBLE_POROSITY = PORE
local storage = core.get_mod_storage()
local wet = core.deserialize(storage:get_string("slurry_wet")) or {}    -- 位置 hash → 級數（1/8 m³）
local wetc = core.deserialize(storage:get_string("slurry_wetc")) or {}  -- 位置 hash → 成分（沒有 = 純穩定液：舊存檔）
local wet_dirty = false
local function pore_cap(r) return math.floor(PORE * r + 0.5) end
local function wcap(r) return pore_cap(r) + NL - r end                 -- r 級碎石的格最多裝幾級
local function surface(r, w)                                           -- 液面高度（1/8 m）
	if w <= 0 then return 0 end
	local pc = pore_cap(r)
	if w <= pc then return r * w / pc end
	return r + w - pc
end
-- 一格裝液的狀態：r（碎石級數，空氣、液體是 0）、w（液的級數）、c（成分）。實心的格回傳 nil
local function cell(p)
	local node = core.get_node(p)
	local n = node.name
	if n == "air" then return 0, 0, WATER_C end
	local k = rockmech.slurry_level[n]
	if k then return 0, k, comp_of(p, node) end
	local r = rockmech.rubble_level[n]
	if r then
		local h = core.hash_node_position(p)
		return r, wet[h] or 0, wetc[h] or SLURRY_C
	end
end
local function cap_of(r) return r == 0 and NL or wcap(r) end

-- 液面那一層的畫面：半格碎石上面的自由液，一格一個拉伸的方塊實體（顏色照成分）
local SHOW = "rockmech:slurry_free"
local SHOW_RANGE = 48
local shown = {}                       -- 位置 hash → 實體
local function free_tex(hex) return "[fill:16x16:" .. hex .. "c8" end
core.register_entity(SHOW, {
	initial_properties = {
		visual = "cube", textures = {free_tex(COLOR), free_tex(COLOR), free_tex(COLOR), free_tex(COLOR), free_tex(COLOR), free_tex(COLOR)},
		use_texture_alpha = true, backface_culling = false,
		physical = false, pointable = false, static_save = false, collisionbox = {0, 0, 0, 0, 0, 0},
	},
	on_activate = function(self) self.object:set_armor_groups({immortal = 1}) end,
})
local function near_player(p)
	if rockmech.slurry_show_all then return true end     -- 測試用
	for _, pl in ipairs(core.get_connected_players()) do
		if vector.distance(pl:get_pos(), p) < SHOW_RANGE then return true end
	end
end
local function show(p, r, w, c)
	local h = core.hash_node_position(p)
	local free = r < NL and w - pore_cap(r) or 0
	local o = shown[h]
	if o and not o:get_pos() then o = nil; shown[h] = nil end
	if free <= 0 or not near_player(p) then
		if o then o:remove(); shown[h] = nil end
		return
	end
	free = math.min(free, NL - r)
	local hex = color_hex(c or SLURRY_C)
	local key = r * 16 + free .. hex
	if o and o:get_luaentity().key == key then return end
	local pos = {x = p.x, y = p.y - 0.5 + (r + free / 2) / NL, z = p.z}
	if not o then
		o = core.add_entity(pos, SHOW)
		if not o then return end
		shown[h] = o
	else
		o:set_pos(pos)
	end
	o:get_luaentity().key = key
	local t = free_tex(hex)
	o:set_properties({visual_size = {x = 1, y = free / NL, z = 1}, textures = {t, t, t, t, t, t}})
end
local function set_cell(p, r, w, c)
	if r == 0 then set_liquid(p, w, c); return end
	local h = core.hash_node_position(p)
	note_change(p, w - (wet[h] or 0))
	wet[h] = w > 0 and w or nil
	wetc[h] = (w > 0 and c ~= SLURRY_C) and c or nil
	wet_dirty = true
	show(p, r, w, c)
end
-- 從 a 搬 t 級到 b，成分照體積混合
local function move(pa, ra, wa, ca, pb, rb, wb, cb, t)
	set_cell(pb, rb, wb + t, mix(cb, wb, ca, t))
	set_cell(pa, ra, wa - t, ca)
end
-- 把 k 級成分 c 加進一格（混合），回傳加不進去的級數
local function add_into(q, k, c)
	local r, w, cq = cell(q)
	if not r then return k end
	local put = math.min(cap_of(r) - w, k)
	if put > 0 then set_cell(q, r, w + put, mix(cq, w, c, put)) end
	return k - put
end
-- 從 p 往上一格一格加 k 級（碎石格加進孔隙、上面的空隙），回傳加不進去的級數
local function push_up(p, k, c)
	local q = {x = p.x, y = p.y + 1, z = p.z}
	for _ = 1, 32 do
		if k <= 0 then return 0 end
		if not cell(q) then return k end
		local left = add_into(q, k, c)
		if left < k then schedule(q) end
		k = left
		q.y = q.y + 1
	end
	return k
end
-- 側向一級一級流：流完 a 的液面還不比 b 低才流。回傳流了幾級
local function seep_amount(ra, wa, rb, wb)
	local cb, t = cap_of(rb), 0
	while wa - t > 0 and wb + t < cb and surface(ra, wa - t - 1) >= surface(rb, wb + t + 1) do t = t + 1 end
	return t
end
-- 從 p 往上加 k 級成分 c：穿過滿格的液體，加在第一個不滿或空的格，滿了再往上（最多 32 格）。回傳加不進去的級數
local function add_up(p, k, ymax, c)
	c = c or SLURRY_C
	local q = vector.copy(p)
	for _ = 1, 32 do
		if ymax and q.y > ymax then return k end
		if k <= 0 then return 0 end
		if not level_at(q) then return k end         -- 擋住了
		k = add_into(q, k, c)
		q.y = q.y + 1
	end
	return k
end
displace = function(p, k, c)
	c = c or SLURRY_C
	-- 擠進來的是碎石：先裝進它的孔隙、上面的空隙
	local r = cell(p)
	if r and r > 0 then
		local left = add_into(p, k, c)
		if left < k then schedule(p) end
		k = left
		if k <= 0 then return end
	end
	local up = {x = p.x, y = p.y + 1, z = p.z}
	local left = add_up(up, k, nil, c)
	if left < k then schedule(up) end
end

-- 排一次流動判定（同一格合併）
local pending = {}
local step
schedule = function(p)
	local key = core.hash_node_position(p)
	if pending[key] then return end
	pending[key] = true
	core.after(STEP, function()
		pending[key] = nil
		step(p)
	end)
end
local function wake_around(p)
	schedule({x = p.x, y = p.y + 1, z = p.z})
	schedule({x = p.x + 1, y = p.y, z = p.z}); schedule({x = p.x - 1, y = p.y, z = p.z})
	schedule({x = p.x, y = p.y, z = p.z + 1}); schedule({x = p.x, y = p.y, z = p.z - 1})
end
rockmech.slurry_wake = wake_around

local DIRS = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}}
local equalize            -- 連通管（靜水平衡），下面定義
local LAYER_MAX = 256        -- 連通管：同一層最多找幾格
-- p 這一層連通的格子（液體或空氣，底下是實心或滿格的液體）裡，級數最低、比 k 低 2 級以上的那一格
local function level_low(p, k)
	local seen, queue = {[core.hash_node_position(p)] = true}, {p}
	local best, bk
	local i = 1
	while queue[i] and #queue < LAYER_MAX do
		local c = queue[i]; i = i + 1
		for _, d in ipairs(DIRS) do
			local n = {x = c.x + d[1], y = c.y, z = c.z + d[2]}
			local h = core.hash_node_position(n)
			if not seen[h] then
				seen[h] = true
				local kn = level_at(n)
				local kb = kn and level_at({x = n.x, y = n.y - 1, z = n.z})
				-- 連通：這格有液（或是空的、但旁邊有液接過來），底下撐著
				if kn and (kb == nil or kb == NL) and (kn > 0 or (level_at(c) or 0) > 0) then
					queue[#queue + 1] = n
					if k - kn >= 2 and (not bk or kn < bk) then best, bk = n, kn end
				end
			end
		end
	end
	return best, bk
end
-- 碎石格裡的液：先往下滲，再往旁邊液面低的格流，碎石變多裝不下就往上擠
local function rubble_step(p, r, w, c)
	if w <= 0 then return end
	local cap = wcap(r)
	if w > cap then
		local left = push_up(p, w - cap, c)
		set_cell(p, r, cap + left, c)
		wake_around(p)
		return
	end
	local below = {x = p.x, y = p.y - 1, z = p.z}
	local rb, wb, cb = cell(below)
	if rb and wb < cap_of(rb) then
		local t = math.min(cap_of(rb) - wb, w)
		move(p, r, w, c, below, rb, wb, cb, t)
		schedule(below); wake_around(p)
		if w - t > 0 then schedule(p) end
		return
	end
	local best, bt
	local s = math.random(4)
	for j = 0, 3 do
		local d = DIRS[(s + j - 1) % 4 + 1]
		local q = {x = p.x + d[1], y = p.y, z = p.z + d[2]}
		local rq, wq, cq = cell(q)
		if rq then
			local t = seep_amount(r, w, rq, wq)
			if t > 0 and (not bt or t > bt) then best, bt = {q, rq, wq, cq}, t end
		end
	end
	if best then
		move(p, r, w, c, best[1], best[2], best[3], best[4], bt)
		schedule(best[1]); wake_around(p); schedule(p)
		return
	end
	show(p, r, w, c)
end

step = function(p)
	local r, k, c = cell(p)
	if not r then return end
	if r > 0 then rubble_step(p, r, k, c); return end
	if k <= 0 then return end
	-- 往下：先把底下補滿（底下是碎石就滲進孔隙、補滿它上面的空隙）
	local below = {x = p.x, y = p.y - 1, z = p.z}
	local rb, wb, cb = cell(below)
	if rb and wb < cap_of(rb) then
		local t = math.min(cap_of(rb) - wb, k)
		move(p, 0, k, c, below, rb, wb, cb, t)
		schedule(below)
		wake_around(p)
		if k - t > 0 then schedule(p) end
		return
	end
	-- 底下撐著：往四周液面最低的那一格分一半
	local best, bk
	local s = math.random(4)
	for j = 0, 3 do
		local d = DIRS[(s + j - 1) % 4 + 1]
		local q = {x = p.x + d[1], y = p.y, z = p.z + d[2]}
		local kq = level_at(q)
		if kq and (not bk or kq < bk) then best, bk = q, kq end
	end
	if best and k - bk >= 2 then
		local t = math.floor((k - bk) / 2)
		local _, _, cq = cell(best)
		move(p, 0, k, c, best, 0, bk, cq, t)
		schedule(best)
		wake_around(p)
		schedule(p)
		return
	end
	-- 旁邊是碎石：液面比它的高就滲過去
	for j = 0, 3 do
		local d = DIRS[(s + j - 1) % 4 + 1]
		local q = {x = p.x + d[1], y = p.y, z = p.z + d[2]}
		local rq, wq, cq = cell(q)
		if rq and rq > 0 then
			local t = seep_amount(0, k, rq, wq)
			if t > 0 then
				move(p, 0, k, c, q, rq, wq, cq, t)
				schedule(q); wake_around(p); schedule(p)
				return
			end
		end
	end
	-- 旁邊都只差 1 級（一格一格差 1/8 m 的階梯，長溝槽兩端差很多、遠端流不到）：連通管——
	-- 同一層連通的液面（含底下撐著的空格）裡最低的那一格比這格低 2 級以上，就搬差距的一半過去。流平，最後整片差不到 1 級
	if k >= 2 then
		local low, lk = level_low(p, k)
		if low then
			local t = math.floor((k - lk) / 2)       -- 搬差距的一半
			local _, _, cl = cell(low)
			move(p, 0, k, c, low, 0, lk, cl, t)
			schedule(low)
			wake_around(p)
			schedule(p)
			return
		end
	end
	-- 局部都平了：整片做一次靜水平衡（不同層之間的落差）
	if equalize then equalize(p) end
end
rockmech.slurry_step = step

-- 連通管（靜水平衡）：p 所在的整片連通液體，加上片內比最高液面低的空格（溝槽裡還沒流到的地方、新挖的槽段），
-- 總級數不變，從最低層往上填滿，最上面那層平均分（差不到 1 級）。兩段液面落在不同層時，局部的流動要靠邊緣
-- 那一格慢慢往下倒、量少了會卡住，液面一段高一段低，低的那段溝壁就沒撐住。
-- 成分：給出液體的格子成分不變；得到液體的格子混進「給出去的那些液體」的平均成分（每種成分都守恆）。
-- 整片超過 EQ_MAX 格（溢到地面上攤開）就不算，交給局部的流動。同一片（約 16 m 範圍）每 EQ_DT 秒最多算一次
local EQ_MAX, EQ_DT = 3000, 1.0
local eq_last, eq_retry = {}, {}
local NB6 = {{1, 0, 0}, {-1, 0, 0}, {0, 0, 1}, {0, 0, -1}, {0, -1, 0}, {0, 1, 0}}
equalize = function(p)
	local key = math.floor(p.x / 16) .. "," .. math.floor(p.y / 16) .. "," .. math.floor(p.z / 16)
	local now = core.get_us_time() / 1e6
	if eq_last[key] and now - eq_last[key] < EQ_DT then
		-- 剛算過：時間到再算一次（不然倒液時被擋掉的這次就沒了，液面停在一邊高一邊低）
		if not eq_retry[key] then
			eq_retry[key] = true
			local pp = vector.copy(p)
			core.after(EQ_DT - (now - eq_last[key]) + 0.05, function() eq_retry[key] = nil; equalize(pp) end)
		end
		return
	end
	eq_last[key] = now
	-- 第一遍：連通的液體（有液的格）
	local seen, cells, total, ymax = {}, {}, 0, -math.huge
	local queue = {p}
	seen[core.hash_node_position(p)] = true
	local i = 1
	while queue[i] do
		local c = queue[i]; i = i + 1
		local k = level_at(c)
		cells[#cells + 1] = {p = c, k = k}
		total = total + k
		if c.y > ymax then ymax = c.y end
		if #cells > EQ_MAX then return end
		for _, d in ipairs(NB6) do
			local n = {x = c.x + d[1], y = c.y + d[2], z = c.z + d[3]}
			local h = core.hash_node_position(n)
			if not seen[h] then
				local kn = level_at(n)
				if kn and kn > 0 then seen[h] = true; queue[#queue + 1] = n end
			end
		end
	end
	-- 第二遍：片內比最高液面低（或同一層）的空格，從有液的格往外、往下找
	i = 1
	local q2 = {}
	for _, c in ipairs(cells) do q2[#q2 + 1] = c.p end
	while q2[i] do
		local c = q2[i]; i = i + 1
		for _, d in ipairs(NB6) do
			local n = {x = c.x + d[1], y = c.y + d[2], z = c.z + d[3]}
			local h = core.hash_node_position(n)
			if not seen[h] and n.y <= ymax then
				seen[h] = true
				if level_at(n) == 0 then
					cells[#cells + 1] = {p = n, k = 0}
					q2[#q2 + 1] = n
					if #cells > EQ_MAX then return end
				end
			end
		end
	end
	-- 由下往上填
	table.sort(cells, function(a, b) return a.p.y < b.p.y end)
	local want = {}
	local j = 1
	local left = total
	while j <= #cells do
		local y = cells[j].p.y
		local layer = {}
		while j <= #cells and cells[j].p.y == y do layer[#layer + 1] = cells[j]; j = j + 1 end
		local n = #layer
		if left >= NL * n then
			for _, c in ipairs(layer) do want[c] = NL end
			left = left - NL * n
		else
			-- 最上面那層：平均分，原本比較多的先多拿 1 級（少搬一點）
			table.sort(layer, function(a, b) return a.k > b.k end)
			local base, extra = math.floor(left / n), left % n
			for idx, c in ipairs(layer) do want[c] = base + (idx <= extra and 1 or 0) end
			left = 0
		end
	end
	-- 給出去的液體的平均成分
	local donated, given = nil, 0
	for _, c in ipairs(cells) do
		local w = want[c] or 0
		if w < c.k then
			c.c = comp_of(c.p)
			donated = donated and mix(donated, given, c.c, c.k - w) or c.c
			given = given + c.k - w
		end
	end
	for _, c in ipairs(cells) do
		local w = want[c] or 0
		if w > c.k then
			set_liquid(c.p, w, mix(c.k > 0 and comp_of(c.p) or WATER_C, c.k, donated or SLURRY_C, w - c.k))
			schedule(c.p)
		elseif w < c.k then
			set_liquid(c.p, w, c.c)
			schedule(c.p)
		end
	end
end
rockmech.slurry_equalize = equalize
-- (p, 級數, 最高到哪一格, 成分：省略 = 純穩定液) → 加不進去的級數
rockmech.slurry_add_up = function(p, k, ymax, c) return add_up(p, k, ymax, c) end
rockmech.slurry_schedule = function(p) schedule(p) end
-- 把 p 換成別的方塊（特密管灌混凝土），不觸發排開：回傳原本那一格的液體級數和成分，排去哪裡由呼叫的人決定
function rockmech.slurry_replace(p, node)
	local k = level_at(p) or 0
	local c = k > 0 and comp_of(p) or SLURRY_C
	internal = true
	core.set_node(p, node)
	internal = false
	if k > 0 then wake_around(p) end
	return k, c
end
-- 改 p 這一格的液面（成分不變；儲槽抽回、測試用）
function rockmech.slurry_set_level(p, k)
	if not level_at(p) then return end
	set_level(p, k)
	wake_around(p)
end
-- 把 k 級成分 c（省略 = 純穩定液）加進 p 這一格（混合），回傳加不進去的級數
function rockmech.slurry_add_at(p, k, c) return add_into(p, k, c or SLURRY_C) end

-- p 剛被挖空（抓斗咬走）：上面那一欄液體馬上往下補（由下往上一格一格掉一層），液面跟著降。
-- 不等慢慢流：泥漿裡挖出來的空洞不會撐著不動，不然應力解會把空洞當成臨空面
function rockmech.slurry_settle(p)
	if level_at(p) ~= 0 then return end
	local q = {x = p.x, y = p.y + 1, z = p.z}
	for _ = 1, 64 do
		local k = level_at(q)
		if not k or k <= 0 then break end
		local below = {x = q.x, y = q.y - 1, z = q.z}
		local kb = level_at(below)
		if not kb or kb >= NL then break end
		local put = math.min(NL - kb, k)
		move(q, 0, k, comp_of(q), below, 0, kb, comp_of(below), put)
		schedule(below)
		q.y = q.y + 1
	end
	wake_around({x = q.x, y = q.y - 1, z = q.z})
end

-- 旁邊、底下的方塊被挖掉：液體往那裡流
core.register_on_dignode(function(pos)
	for _, v in ipairs({{x = 0, y = 1, z = 0}, {x = 1, y = 0, z = 0}, {x = -1, y = 0, z = 0}, {x = 0, y = 0, z = 1}, {x = 0, y = 0, z = -1}}) do
		local q = vector.add(pos, v)
		if (level_at(q) and level_at(q) > 0) or wet[core.hash_node_position(q)] then schedule(q) end
	end
end)

-- 任何程式把一格變成空氣、不滿格的碎石（崩塌、碎石流走、車子取料……用 set_node，不會觸發 on_dignode）：
-- 上面、四周的液體叫起來。液體自己流動改的不算（internal）
local NB5 = {{0, 1, 0}, {1, 0, 0}, {-1, 0, 0}, {0, 0, 1}, {0, 0, -1}}
local function poke(pos)
	for _, v in ipairs(NB5) do
		local q = {x = pos.x + v[1], y = pos.y + v[2], z = pos.z + v[3]}
		local k = level_at(q)
		if (k and k > 0) or wet[core.hash_node_position(q)] then schedule(q) end
	end
end
for _, fname in ipairs({"set_node", "add_node", "swap_node", "remove_node"}) do
	local orig = core[fname]
	core[fname] = function(pos, node, ...)
		local r = orig(pos, node, ...)
		if not internal then
			local n = fname == "remove_node" and "air" or (node and node.name)
			local lv = n and rockmech.rubble_level[n]
			if n == "air" or (lv and lv < NL) then poke(pos) end
		end
		return r
	end
end

-- 孔隙液的帳：碎石被挖走、流走、換成別的（滿格、壓實、VoxelManip 大崩塌都不會通知），每 0.5 s 對一次。
-- 碎石沒了：液留在原地（空氣、液體的格）或往上擠；碎石變多裝不下：多的往上擠。順便更新液面那一層的畫面
local REC_DT, SAVE_DT = 0.5, 5
local rec_t, save_t = 0, 0
rockmech.slurry_wet_stats = {n = 0, us = 0, shown = 0}
local function reconcile()
	local t0 = core.get_us_time()
	local todo, n = {}, 0
	for h, w in pairs(wet) do
		n = n + 1
		local p = core.get_position_from_hash(h)
		local node = core.get_node_or_nil(p)
		if node then
			local r = rockmech.rubble_level[node.name]
			if not r or w > wcap(r) then todo[#todo + 1] = {p, h, w, r}
			else show(p, r, w, wetc[h] or SLURRY_C) end
		end
	end
	for _, a in ipairs(todo) do
		local p, h, w, r = a[1], a[2], a[3], a[4]
		local c = wetc[h] or SLURRY_C
		if r then
			local left = push_up(p, w - wcap(r), c)
			wet[h] = wcap(r) + left
			show(p, r, wet[h], c)
		else
			wet[h], wetc[h] = nil, nil
			if shown[h] then shown[h]:remove(); shown[h] = nil end
			if level_at(p) then w = add_into(p, w, c) end
			if w > 0 then
				local left = push_up(p, w, c)
				if left > 0 then core.log("warning", ("[rockmech] 孔隙液 %d 級沒地方放（%s）"):format(left, core.pos_to_string(p))) end
			end
			schedule(p)
		end
		wet_dirty = true
		wake_around(p)
	end
	local st = rockmech.slurry_wet_stats
	st.n, st.us = n, core.get_us_time() - t0
	st.shown = 0
	for _ in pairs(shown) do st.shown = st.shown + 1 end
end
local function save_wet()
	if not wet_dirty then return end
	wet_dirty = false
	storage:set_string("slurry_wet", core.serialize(wet))
	storage:set_string("slurry_wetc", core.serialize(wetc))
end
core.register_globalstep(function(dt)
	rec_t, save_t = rec_t + dt, save_t + dt
	if rec_t >= REC_DT then rec_t = 0; reconcile() end
	if save_t >= SAVE_DT then save_t = 0; save_wet() end
end)
core.register_on_shutdown(save_wet)
core.after(1, function()
	for h in pairs(wet) do schedule(core.get_position_from_hash(h)) end
end)
rockmech.slurry_wet = wet
rockmech.slurry_wetc = wetc          -- 孔隙液的成分（沒有 = 純穩定液）
rockmech.slurry_cell = cell
-- 流動是事件驅動的（挖掉、倒液、流過去才排判定）：靜止的液體跟一般方塊一樣不計算（像 Minecraft 的水）。
-- 沒有定時掃描；區塊載入、VoxelManip 改寫地圖時，用幾次查表確認真的會流（底下有空位、旁邊低 2 級以上、
-- 旁邊的碎石還吸得了）才排判定
local function can_flow(p, k)
	local rb, wb = cell({x = p.x, y = p.y - 1, z = p.z})
	if rb and wb < cap_of(rb) then return true end
	for _, d in ipairs(DIRS) do
		local q = {x = p.x + d[1], y = p.y, z = p.z + d[2]}
		local kq = level_at(q)
		if kq then
			if k - kq >= 2 then return true end
		else
			local rq, wq = cell(q)
			if rq and rq > 0 and seep_amount(0, k, rq, wq) > 0 then return true end
		end
	end
	return false
end
-- 區塊載入時（重開遊戲、走回來）：還沒流完的液體接著流
core.register_lbm({
	label = "rockmech: 穩定液接著流",
	name = "rockmech:slurry_resume",
	nodenames = {"group:rockmech_slurry"},
	run_at_every_load = true,
	action = function(pos, node)
		local k = rockmech.slurry_level[node.name]
		if k and can_flow(pos, k) then schedule(pos) end
	end,
})
-- 地圖被 VoxelManip 直接改寫（大崩塌、爆破、整地工具；這些不會觸發任何事件）：範圍裡（外擴 1 格）會流的液體、
-- 含液的碎石叫起來。寫入的地方呼叫 rockmech.map_written(a, b)
local function wake_box(a, b)
	local p1 = {x = math.min(a.x, b.x) - 1, y = math.min(a.y, b.y) - 1, z = math.min(a.z, b.z) - 1}
	local p2 = {x = math.max(a.x, b.x) + 1, y = math.max(a.y, b.y) + 1, z = math.max(a.z, b.z) + 1}
	for _, q in ipairs(core.find_nodes_in_area(p1, p2, {"group:rockmech_slurry"})) do
		local k = level_at(q)
		if k and can_flow(q, k) then schedule(q) end
	end
	for h in pairs(wet) do
		local q = core.get_position_from_hash(h)
		if q.x >= p1.x and q.x <= p2.x and q.y >= p1.y and q.y <= p2.y and q.z >= p1.z and q.z <= p2.z then schedule(q) end
	end
end
local prev_written = rockmech.map_written
function rockmech.map_written(a, b)
	if prev_written then prev_written(a, b) end
	core.after(0, wake_box, vector.copy(a), vector.copy(b))
end

-- 從 p（空氣或液體的格）倒 k 級成分 c（省略 = 純穩定液）進去：沉到那一欄液體的底，從第一個不滿的格往上加
-- （液面上升，不會疊成一根柱子），最多到溝槽的頂（cap：再低一點的上限）；這一欄放不下的分給同一層相連的格。
-- partial = false：整份放得下才倒（守恆：不倒一半丟一半）。回傳倒進去的級數
local function pour(p, k, cap, partial, c)
	c = c or SLURRY_C
	p = vector.copy(p)
	if not level_at(p) then return 0 end
	while level_at({x = p.x, y = p.y - 1, z = p.z}) do p.y = p.y - 1 end
	-- 最多倒到溝槽的頂：這一欄往上，旁邊還有溝壁（實心）的最高那格；平地上就是一層（液體指不到，
	-- 準心會穿過液面指到溝底，所以不能用指到的高度）
	local function walled(q)
		for _, d in ipairs(DIRS) do
			if not level_at({x = q.x + d[1], y = q.y, z = q.z + d[2]}) then return true end
		end
	end
	local ymax, w = p.y, vector.copy(p)
	for _ = 1, 48 do
		if not level_at(w) or not walled(w) then break end
		ymax = w.y
		w.y = w.y + 1
	end
	if cap then ymax = math.min(ymax, cap) end
	if ymax < p.y then return 0 end
	local room, q = 0, vector.copy(p)
	while q.y <= ymax and level_at(q) do room = room + NL - level_at(q); q.y = q.y + 1 end
	-- 這一欄放不下（液面還沒流平）：分給溝槽裡連通、底下撐著的格子（同一層往旁邊、也往下找，低的先填；
	-- 不往上找，最高到 ymax）
	local spill = {}
	if room < k then
		local seen, queue = {[core.hash_node_position(p)] = true}, {vector.copy(p)}
		local cand = {}
		local i = 1
		while queue[i] and #queue < 256 do
			local cc = queue[i]; i = i + 1
			for _, d in ipairs({{1, 0, 0}, {-1, 0, 0}, {0, 0, 1}, {0, 0, -1}, {0, -1, 0}, {0, 1, 0}}) do
				local n = {x = cc.x + d[1], y = cc.y + d[2], z = cc.z + d[3]}
				local h = core.hash_node_position(n)
				local kn = not seen[h] and n.y <= ymax and level_at(n)
				if kn and walled(n) and not (n.x == p.x and n.z == p.z) then
					seen[h] = true
					queue[#queue + 1] = n
					local kb = level_at({x = n.x, y = n.y - 1, z = n.z})
					if kn < NL and (kb == nil or kb == NL) then cand[#cand + 1] = {n = n, k = kn} end
				end
			end
		end
		table.sort(cand, function(u, v) if u.n.y ~= v.n.y then return u.n.y < v.n.y end return u.k < v.k end)
		for _, cc in ipairs(cand) do
			if room >= k then break end
			spill[#spill + 1] = cc.n
			room = room + NL - cc.k
		end
	end
	if room <= 0 or (room < k and not partial) then return 0 end
	k = math.min(k, room)
	local left = add_up(p, k, ymax, c)
	for _, n in ipairs(spill) do
		if left <= 0 then break end
		left = add_into(n, left, c)
		schedule(n)
	end
	wake_around(p)
	schedule(p)
	for y = p.y, p.y + 16 do
		local qq = {x = p.x, y = y, z = p.z}
		if not level_at(qq) or level_at(qq) == 0 then break end
		schedule(qq)
	end
	return k - left
end
rockmech.slurry_pour = pour

-- 穩定液（1 m³）：對著地面、溝槽按右鍵倒進去（加在對準的那一格；滿了往上疊），然後自己流
local ITEM = "rockmech:slurry_m3"
core.register_craftitem(ITEM, {
	description = S("Bentonite slurry\n1 m³ each. Right-click to pour; it flows slowly and holds up trench walls"),
	short_description = S("Bentonite slurry"),
	inventory_image = "[fill:16x16:#00000000^[fill:10x12:3,3:" .. COLOR .. "^[fill:10x2:3,3:#a8987a",
	stack_max = 99,
	on_place = function(itemstack, placer, pointed)
		if pointed.type ~= "node" then return itemstack end
		-- 指著有右鍵功能的方塊（穩定液儲槽：存進去）：交給它；按住 Shift 才倒
		local un = core.get_node(pointed.under)
		local udef = core.registered_nodes[un.name]
		if udef and udef.on_rightclick and not (placer and placer.get_player_control and placer:get_player_control().sneak) then
			return udef.on_rightclick(pointed.under, un, placer, itemstack, pointed) or itemstack
		end
		local name = placer and placer:get_player_name() or ""
		local p = level_at(pointed.under) and pointed.under or pointed.above
		if core.is_protected(p, name) or not level_at(p) then return itemstack end
		if pour(p, NL) == 0 then return itemstack end
		if not (core.is_creative_enabled and core.is_creative_enabled(name)) then itemstack:take_item() end
		return itemstack
	end,
})
rockmech.SLURRY_ITEM = ITEM

-- 從 p 那一欄的液面往下抽 k 級（測試用：不守恆）。回傳抽了幾級
function rockmech.slurry_take(p, k)
	local q = vector.copy(p)
	while (level_at({x = q.x, y = q.y + 1, z = q.z}) or 0) > 0 do q.y = q.y + 1 end
	local took = 0
	for _ = 1, 64 do
		local kq = level_at(q)
		if not kq or kq <= 0 or took >= k then break end
		local t = math.min(kq, k - took)
		set_level(q, kq - t)
		took = took + t
		wake_around(q)
		q.y = q.y - 1
	end
	return took
end

-- 無限水桶、無限穩定液桶（測試用，創造模式物品欄）：右鍵在指的地方倒 1 m³（往上疊，不限溝頂），
-- 左鍵從視線碰到的那一欄液面抽 1 m³；按住 Shift 是 5 m³。不消耗、不收錢
local function amount(user) return (user and user:get_player_control().sneak) and 5 * NL or NL end
local function bucket(item, desc, short, comp, color, what)
	core.register_tool(item, {
		description = desc,
		short_description = short,
		inventory_image = "[fill:16x16:#00000000^[fill:10x10:3,5:#606870^[fill:8x7:4,5:" .. color .. "^[fill:12x1:2,4:#909aa4^[fill:2x2:13,1:#b070ff",
		stack_max = 1,
		on_place = function(itemstack, placer, pointed)
			if pointed.type ~= "node" or not placer then return itemstack end
			local p = level_at(pointed.under) and pointed.under or pointed.above
			if not level_at(p) or core.is_protected(p, placer:get_player_name()) then return itemstack end
			local k = amount(placer)
			local left = add_up(p, k, nil, comp)
			schedule(p); wake_around(p)
			for y = p.y, p.y + 8 do schedule({x = p.x, y = y, z = p.z}) end
			core.log("action", ("[rockmech] 無限%s桶 倒 %d 級 %s"):format(what, k - left, core.pos_to_string(p)))
			return itemstack
		end,
		on_use = function(itemstack, user)
			if not user then return itemstack end
			-- 液體指不到：沿視線一小步一小步找第一格有液的
			local eye = vector.add(user:get_pos(), {x = 0, y = user:get_properties().eye_height or 1.625, z = 0})
			local look = user:get_look_dir()
			for i = 1, 80 do
				local q = vector.round(vector.add(eye, vector.multiply(look, i * 0.1)))
				local k = level_at(q)
				if k == nil then break end              -- 碰到實心
				if k > 0 then
					local took = rockmech.slurry_take(q, amount(user))
					core.log("action", ("[rockmech] 無限%s桶 抽 %d 級 %s"):format(what, took, core.pos_to_string(q)))
					break
				end
			end
			return itemstack
		end,
	})
end
bucket("rockmech:slurry_bucket_infinite",
	S("Infinite slurry bucket\nRight-click: pour 1 m³ (Shift: 5 m³); left-click: drain 1 m³ (Shift: 5 m³). For testing"),
	S("Infinite slurry bucket"), SLURRY_C, COLOR, "穩定液")
bucket("rockmech:water_bucket_infinite",
	S("Infinite water bucket\nRight-click: pour 1 m³ (Shift: 5 m³); left-click: drain 1 m³ (Shift: 5 m³). For testing"),
	S("Infinite water bucket"), WATER_C, WCOLOR, "水")
