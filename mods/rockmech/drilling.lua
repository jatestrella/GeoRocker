-- rockmech/drilling.lua
-- 鑽孔爆破：鑿岩機在岩面鑽孔（按住左鍵 drill_time 秒，像挖礦）→ 乳膠炸藥裝進鑽孔 → 打火石點火（只爆那一孔）或起爆器（範圍內的裝藥依序起爆）。
--   鑽孔：貼在岩面上的小圓環（中間黑色的孔），是空氣格裡的貼壁方塊；後面的岩石沒了就跟著消失。
--   孔內裝藥：爆心在孔底（岩面往內 hole_depth 格），破碎半徑 R = charge_radius · n^(1/3)（n 條），
--             再依岩石強度縮放（blast.lua）；炸飛、碎石化、支撐判定照 blasting.lua。
--   夾制與側向自由面：只有孔口一個自由面時岩石夾住炸藥，半徑 × confine_factor；炮孔旁 R 內有不是岩石的格子
--             （空氣、碎石…，孔口岩面那側不算），距離 = 抵抗線 B，再 × (1 + free_face_k·(1 − B/R))。
--             沒裝藥的鑽孔（空孔）也算自由面（空孔掏槽）。先炸中間的孔（拔心），外圈的孔就有自由面。
--   貼面裝藥：沒有鑽孔也能貼在岩面上（無約束），爆心在岩面上，半徑再乘 surface_factor。
--   ANFO（露天台階的垂直孔，vehicle_drillrig.lua 鑽）：倒進往下的鑽孔成柱狀裝藥（孔口留 anfo_stemming 填塞），
--             沿孔每 1.5 m 一段、每段半徑 anfo_radius（再乘夾制／自由面）；ANFO 對雷管不敏感，孔裡要有一條乳膠炸藥
--             當起爆藥包，沒有就拒爆（留在原地）。孔深記在鑽孔的 meta depth（沒有就是 hole_depth）。
--             外觀：孔裡是粉紅色的 ANFO（anfo_hole）；放了起爆藥包多一條起爆線（anfo_primed）。
--             破碎不超過孔底（孔底 = 底板），台階炸完是平的。
--   裝藥被別的爆炸波及會殉爆。參數在設定 rockmech_blast_*。

rockmech.SHOTCRETE_LAYERS = 3     -- 噴凝土最多幾層
rockmech.spray_next = {}          -- 方塊 → 再噴一層之後的方塊（這裡是孔，groundsupport.lua 加上噴凝土層與岩栓）

if not rockmech.blast_charge then return end   -- 沒有 tnt mod

local S = rockmech.S
local bcfg = rockmech.cfg.blast
local HOLE = "rockmech:drill_hole"
local CHARGED = "rockmech:charged_hole"
local SURFACE = "rockmech:surface_charge"
local EMULSION = "rockmech:emulsion"
local ANFO = "rockmech:anfo"
local ANFO_HOLE = "rockmech:anfo_hole"       -- 倒了 ANFO、還沒有起爆藥包
local ANFO_PRIMED = "rockmech:anfo_primed"   -- ANFO ＋ 起爆藥包（meta n 條乳膠炸藥）
-- 噴過凝土的孔：每種狀態、每個層數一個方塊，功能同一般的孔、外觀是同樣的圖案疊在噴凝土上，這格也算噴凝土
local VAR = {}          -- 狀態 → {[層數] = 方塊}
local PLAIN, LAYERS = {}, {}
for _, kind in ipairs({HOLE, CHARGED, ANFO_HOLE, ANFO_PRIMED}) do
	VAR[kind] = {}
	for n = 1, rockmech.SHOTCRETE_LAYERS do
		local name = kind .. "_sprayed" .. (n > 1 and ("_" .. n) or "")
		VAR[kind][n] = name
		PLAIN[name], LAYERS[name] = kind, n
		rockmech.spray_next[n > 1 and VAR[kind][n - 1] or kind] = name
	end
end
local function kind_of(name) return PLAIN[name] or name end
local function is_hole(name) return kind_of(name) == HOLE end
-- 換成狀態 kind，層數不變
local function become(pos, node, kind)
	local n = LAYERS[node.name]
	core.swap_node(pos, {name = n and VAR[kind][n] or kind, param2 = node.param2})
end
-- list 加上每個狀態噴過凝土的方塊
local function with_sprayed(list)
	local all = {}
	for _, kind in ipairs(list) do
		all[#all + 1] = kind
		for _, name in ipairs(VAR[kind] or {}) do all[#all + 1] = name end
	end
	return all
end
local HOLES = with_sprayed({HOLE})
local CHARGES = with_sprayed({CHARGED, SURFACE, ANFO_HOLE, ANFO_PRIMED})
local ALL = with_sprayed({HOLE, CHARGED, SURFACE, ANFO_HOLE, ANFO_PRIMED})   -- 爆完要清掉的孔與裝藥
-- 鑽孔的孔深（m）：鑽機鑽的垂直孔記在 meta depth，其他是 hole_depth
local function hole_len(pos)
	local d = core.get_meta(pos):get_float("depth")
	return d > 0 and d or bcfg.hole_depth
end

-- 方塊外觀：貼壁方塊（paramtype2 wallmounted）的 fixed 方塊以「貼在地上」的方向定義，引擎依 param2 轉到各面。
-- 上面（+Y）的貼圖就是朝外那一面；側面貼圖的最下一列對應貼著岩面的那層
local RING = {-0.25, -0.5, -0.25, 0.25, -0.45, 0.25}                       -- 孔口的圓環
local RING_MARK = "[fill:8x6:4,5:#7a7268^[fill:6x8:5,4:#7a7268"
	.. "^[fill:6x4:5,6:#4a4440^[fill:4x6:6,5:#4a4440^[fill:2x4:7,6:#0c0c0c^[fill:4x2:6,7:#0c0c0c"
local RING_TOP = "[fill:16x16:#00000000^" .. RING_MARK
local RING_SIDE = "[fill:16x16:#00000000^[fill:16x1:0,15:#6a625a"
local CART = "#e8c070"     -- 乳膠炸藥藥卷
local WIRE = "#c02020"     -- 起爆線
local PINK = "#e890b0"     -- ANFO（粉紅色顆粒）
local function node_base(desc)
	return {
		description = desc,
		drawtype = "nodebox", paramtype = "light", paramtype2 = "wallmounted", sunlight_propagates = true,
		use_texture_alpha = "clip", walkable = false, is_ground_content = false,
		groups = {dig_immediate = 3, attached_node = 1, not_in_creative_inventory = 1},
	}
end

local function set_info(pos)
	local node = core.get_node(pos)
	local n = core.get_meta(pos):get_int("n")
	local meta = core.get_meta(pos)
	local kind = kind_of(node.name)
	if kind == ANFO_PRIMED then
		meta:set_string("infotext", S("ANFO column charge (hole depth @1 m) + @2 primer cartridge(s)\nLight it with flint and steel, or use the blasting machine", ("%.0f"):format(hole_len(pos)), tostring(n)))
	elseif kind == ANFO_HOLE then
		meta:set_string("infotext", S("ANFO column charge (hole depth @1 m)\nNo primer yet: add one emulsion cartridge, otherwise it will misfire", ("%.0f"):format(hole_len(pos))))
	elseif kind == CHARGED then
		meta:set_string("infotext", S("Charged hole: @1 emulsion cartridge(s) (max @2)\nLight it with flint and steel, or use the blasting machine", tostring(n), tostring(bcfg.max_cartridges)))
	elseif kind == SURFACE then
		meta:set_string("infotext", S("Surface charge: @1 cartridge(s) (no drill hole, power ×@2)\nLight it with flint and steel, or use the blasting machine", tostring(n), ("%.1f"):format(bcfg.surface_factor)))
	end
end

-- 引爆一個裝藥
-- 抵抗線 B：炮孔（孔口岩面 → 孔底 center，沿 dir）到最近的側向自由面（不是岩石的格子，空氣、碎石等都算）的距離。
-- 孔口岩面前方那一側（鑽孔就是從那裡鑽進去的，每個孔都有）不算。R 內沒有就回傳 nil
-- 沒裝藥的鑽孔（空孔）也是自由面（空孔掏槽）：空孔從孔口岩面到孔底這段，到炮孔的最短距離
local function burden(center, dir, R, depth)
	local face_t = 0.5 - (depth or bcfg.hole_depth)   -- 孔口岩面在軸上的位置（以孔底為 0、往岩石裡為正）
	-- 點到炮孔線段（軸上 face_t..0）的距離；點在孔口岩面前方（t ≤ face_t）回傳 nil
	local function dist(px, py, pz)
		local dx, dy, dz = px - center.x, py - center.y, pz - center.z
		local t = dx * dir.x + dy * dir.y + dz * dir.z
		if t <= face_t then return nil end
		local tc = math.min(0, t)
		local ex, ey, ez = dx - tc * dir.x, dy - tc * dir.y, dz - tc * dir.z
		return math.sqrt(ex * ex + ey * ey + ez * ez)
	end
	local r = math.ceil(R)
	local c0 = vector.round(center)
	local best
	local function take(d) if d and d <= R and (not best or d < best) then best = d end end
	for x = c0.x - r, c0.x + r do for y = c0.y - r, c0.y + r do for z = c0.z - r, c0.z + r do
		if not rockmech.lith_of_node[core.get_node({x = x, y = y, z = z}).name] then take(dist(x, y, z)) end
	end end end
	-- 空孔：沿孔軸每 0.5 m 取一點
	local reach = r + math.max(depth or 0, bcfg.hole_depth)
	for _, hp in ipairs(core.find_nodes_in_area(vector.subtract(c0, reach), vector.add(c0, reach), HOLES)) do
		local hd = core.wallmounted_to_dir(core.get_node(hp).param2)
		for s = 0.5, hole_len(hp), 0.5 do
			take(dist(hp.x + hd.x * s, hp.y + hd.y * s, hp.z + hd.z * s))
		end
	end
	return best
end
rockmech.blast_burden = burden   -- 測試用

local function detonate(pos)
	local node = core.get_node(pos)
	local kind = kind_of(node.name)
	if kind ~= CHARGED and kind ~= SURFACE and kind ~= ANFO_HOLE and kind ~= ANFO_PRIMED then return end
	local meta = core.get_meta(pos)
	local dir = core.wallmounted_to_dir(node.param2)
	local depth = hole_len(pos)
	if kind == ANFO_HOLE or kind == ANFO_PRIMED then
		if kind == ANFO_HOLE then
			-- 拒爆：ANFO 沒有起爆藥包炸不響，留在孔裡
			meta:set_int("lit", 0)
			meta:set_string("infotext", S("Misfire: the ANFO has no primer (add one emulsion cartridge and fire again)"))
			core.log("action", "[rockmech] 拒爆（ANFO 沒有起爆藥包）" .. core.pos_to_string(pos))
			return
		end
		-- 柱狀裝藥：孔口留填塞，往下每 1.5 m 一段；夾制／自由面整根孔一起算。
		-- 底板：孔底那一格以下不破碎（實際台階孔會超鑽到底板以下，炸完底板就在孔底附近）
		local floor_y = math.floor(pos.y - depth + 0.5)
		local R = bcfg.anfo_radius
		local bottom = vector.add(pos, vector.multiply(dir, depth))
		local B = burden(bottom, dir, R, depth)
		local f = bcfg.confine_factor * (B and (1 + bcfg.free_face_k * (1 - B / R)) or 1)
		core.log("action", ("[rockmech] ANFO 柱狀裝藥 %s 孔深 %.0f m：抵抗線 B = %s，每段半徑 %.1f × %.2f"):format(
			core.pos_to_string(pos), depth, B and ("%.1f m"):format(B) or "（沒有側向自由面）", R, f))
		core.remove_node(pos)
		local t = 0.5 + bcfg.anfo_stemming + 0.75
		local last
		repeat
			last = vector.add(pos, vector.multiply(dir, math.min(t, depth)))
			rockmech.blast_charge(last, R * f, floor_y, 1.0)      -- 台階生產爆破：擾動 D = 1.0
			t = t + 1.5
		until t > depth + 0.5
		R = R * f + depth
		local center = last
		local r = math.ceil(R) + 1
		for _, hp in ipairs(core.find_nodes_in_area(vector.subtract(center, r), vector.add(center, r), ALL)) do
			local hn = core.get_node(hp)
			local back = core.get_node(vector.add(hp, core.wallmounted_to_dir(hn.param2))).name
			local nd = core.registered_nodes[back]
			local held = hn.name == SURFACE and nd and nd.walkable ~= false or rockmech.lith_of_node[back]
			if not held then core.remove_node(hp) end
		end
		return
	end
	local n = math.max(1, meta:get_int("n"))
	local R = bcfg.charge_radius * n ^ (1 / 3)
	-- wallmounted 的方向指向貼著的岩面。孔內：孔底（從岩面往裡孔深 depth 格）；貼面：岩面上（半格）
	local center
	if kind == CHARGED then
		center = vector.add(pos, vector.multiply(dir, depth))
		-- 夾制：只有孔口一個自由面時岩石夾住炸藥，R × confine；
		-- 側向自由面：抵抗線 B < R 時往自由面破裂，再 × (1 + k·(1 − B/R))
		local B = burden(center, dir, R, depth)
		local f = bcfg.confine_factor * (B and (1 + bcfg.free_face_k * (1 - B / R)) or 1)
		core.log("action", ("[rockmech] 鑽孔裝藥 %s：抵抗線 B = %s，半徑 %.1f × %.2f"):format(
			core.pos_to_string(center), B and ("%.1f m"):format(B) or "（沒有側向自由面）", R, f))
		R = R * f
	else
		center = vector.add(pos, vector.multiply(dir, 0.5))
		R = R * bcfg.surface_factor
	end
	core.remove_node(pos)
	-- 擾動 D：每孔 1 條（控制爆破、平滑爆破）0.5；2 條以上或貼面裝藥 0.8（Hoek 2002）
	rockmech.blast_charge(center, R, nil, (kind == CHARGED and n <= 1) and 0.5 or 0.8)
	-- 爆破直接改地圖、不會觸發貼壁方塊掉落：後面的岩石沒了的鑽孔、裝藥一起消失
	local r = math.ceil(R) + depth + 1
	for _, hp in ipairs(core.find_nodes_in_area(vector.subtract(center, r), vector.add(center, r), ALL)) do
		local hn = core.get_node(hp)
		local back = core.get_node(vector.add(hp, core.wallmounted_to_dir(hn.param2))).name
		local nd = core.registered_nodes[back]
		local held = hn.name == SURFACE and nd and nd.walkable ~= false or rockmech.lith_of_node[back]
		if not held then core.remove_node(hp) end
	end
end
rockmech.detonate_charge = detonate

-- 點火：冒煙，fuse_time 秒後爆
local function ignite(pos)
	local meta = core.get_meta(pos)
	if meta:get_int("lit") == 1 then return end
	meta:set_int("lit", 1)
	core.add_particlespawner({
		amount = math.floor(bcfg.fuse_time * 8), time = bcfg.fuse_time,
		minpos = vector.subtract(pos, 0.1), maxpos = vector.add(pos, 0.1),
		minvel = {x = -0.2, y = 0.5, z = -0.2}, maxvel = {x = 0.2, y = 1.2, z = 0.2},
		minexptime = 0.8, maxexptime = 1.6, minsize = 1, maxsize = 2.5,
		texture = "[fill:4x4:#c8c8c8", glow = 4,
	})
	core.after(bcfg.fuse_time, detonate, pos)
end

-- 拆掉裝藥：還給乳膠炸藥
local function dig_charge(pos, node, digger)
	local n = math.max(1, core.get_meta(pos):get_int("n"))
	core.remove_node(pos)
	if digger and digger:is_player() then
		local left = digger:get_inventory():add_item("main", ItemStack(EMULSION .. " " .. n))
		if not left:is_empty() then core.add_item(pos, left) end
	end
	return true
end

-- 鑽孔
do
	local def = node_base(S("Drill hole"))
	def.node_box = {type = "fixed", fixed = {RING}}
	def.selection_box = {type = "fixed", fixed = {{-0.3, -0.5, -0.3, 0.3, -0.38, 0.3}}}
	def.tiles = {RING_TOP, RING_SIDE, RING_SIDE, RING_SIDE, RING_SIDE, RING_SIDE}
	def.drop = ""
	def.diggable = false   -- 孔是岩石上的洞，挖不掉（後面的岩石沒了才會消失）
	core.register_node(HOLE, def)
end
-- 裝了炸藥的鑽孔：孔口露出一截藥卷與起爆線
do
	local def = node_base(S("Charged hole"))
	def.node_box = {type = "fixed", fixed = {RING, {-0.08, -0.45, -0.08, 0.08, -0.15, 0.08}, {0.08, -0.45, -0.03, 0.4, -0.42, 0.03}}}
	def.selection_box = {type = "fixed", fixed = {{-0.3, -0.5, -0.3, 0.3, -0.12, 0.3}}}
	local top = RING_TOP .. "^[fill:3x3:7,7:" .. CART .. "^[fill:6x2:9,7:" .. WIRE
	local side = RING_SIDE .. "^[fill:4x5:6,10:" .. CART .. "^[fill:6x1:9,14:" .. WIRE
	def.tiles = {top, RING_SIDE, side, side, side, side}
	def.groups.rockmech_charge = 1
	def.drop = ""
	def.diggable = false   -- 裝好的藥不能隨手掏出來；拒爆的孔要再起爆（補起爆藥包）
	def.on_ignite = ignite
	def.on_blast = function(pos) core.after(0.05, detonate, pos) end   -- 殉爆
	core.register_node(CHARGED, def)
end
-- 倒了 ANFO 的鑽孔：孔裡是粉紅色顆粒（和乳膠炸藥的黃色藥卷分得出來）；有起爆藥包的多一條起爆線
local ANFO_TOP = RING_TOP .. "^[fill:6x4:5,6:" .. PINK .. "^[fill:4x6:6,5:" .. PINK
for _, v in ipairs({
	{ANFO_HOLE, S("ANFO hole"), {RING}, ANFO_TOP, RING_SIDE},
	{ANFO_PRIMED, S("ANFO hole (primed)"), {RING, {0.08, -0.45, -0.03, 0.4, -0.42, 0.03}},
		ANFO_TOP .. "^[fill:6x2:9,7:" .. WIRE, RING_SIDE .. "^[fill:6x1:9,14:" .. WIRE},
}) do
	local def = node_base(v[2])
	def.node_box = {type = "fixed", fixed = v[3]}
	def.selection_box = {type = "fixed", fixed = {{-0.3, -0.5, -0.3, 0.3, -0.38, 0.3}}}
	def.tiles = {v[4], RING_SIDE, v[5], v[5], v[5], v[5]}
	def.groups.rockmech_charge = 1
	def.drop = ""
	def.diggable = false
	def.on_ignite = ignite
	def.on_blast = function(pos) core.after(0.05, detonate, pos) end
	core.register_node(v[1], def)
end
-- 噴過凝土的版本：同樣的方塊與貼圖，底下多一層噴凝土（孔口圓環埋在裡面，圖案畫在表面）
do
	local LINING_TEX = "[fill:16x16:#a4a29c^[fill:2x2:3,4:#8e8c86^[fill:2x2:10,2:#b4b2ac^[fill:2x2:6,11:#8e8c86^[fill:2x2:12,9:#b4b2ac"
	for kind, names in pairs(VAR) do
		for n, name in ipairs(names) do
			local def = table.copy(core.registered_nodes[kind])
			local top = -0.5 + 0.06 * n
			def.description = S("@1 (shotcrete, @2 layers)", def.description, tostring(n))
			table.insert(def.node_box.fixed, 1, {-0.5, -0.5, -0.5, 0.5, top, 0.5})
			local sel = def.selection_box.fixed[1]
			sel[1], sel[3], sel[4], sel[6] = -0.5, -0.5, 0.5, 0.5        -- 整面噴凝土都點得到
			sel[5] = math.max(sel[5], top + 0.02)
			for i, t in ipairs(def.tiles) do def.tiles[i] = LINING_TEX .. "^(" .. t .. ")" end
			def.groups.shotcrete = n
			-- 敲噴凝土：和噴凝土層一樣整格的層數一起敲掉（不退還），孔與裝藥留著
			def.groups.dig_immediate = nil
			def.groups.cracky = 3
			def.groups.shotcrete_hole = 1
			def.diggable = true
			def.node_dig_prediction = ""
			def.on_dig = function(pos, node)
				core.swap_node(pos, {name = kind, param2 = node.param2})
				if rockmech.cfg.fem.drive then rockmech.fem_queue(pos, 1) end
				return true
			end
			core.register_node(name, def)
		end
	end
end
-- 舊版存檔：ANFO 記在 charged_hole 的 meta anfo，換成新方塊
core.register_lbm({
	label = "rockmech: ANFO 鑽孔換外觀", name = "rockmech:anfo_hole_look", nodenames = {CHARGED},
	action = function(pos, node)
		local meta = core.get_meta(pos)
		if meta:get_int("anfo") ~= 1 then return end
		meta:set_string("anfo", "")
		core.swap_node(pos, {name = meta:get_int("n") > 0 and ANFO_PRIMED or ANFO_HOLE, param2 = node.param2})
		set_info(pos)
	end,
})

-- 貼面裝藥：一束藥卷貼在岩面上
do
	local def = node_base(S("Surface charge"))
	def.node_box = {type = "fixed", fixed = {{-0.3, -0.5, -0.1, 0.3, -0.32, 0.1}, {0.3, -0.5, -0.03, 0.45, -0.46, 0.03}}}
	def.selection_box = {type = "fixed", fixed = {{-0.35, -0.5, -0.15, 0.45, -0.28, 0.15}}}
	local top = "[fill:16x16:#00000000^[fill:10x4:3,6:" .. CART .. "^[fill:10x1:3,7:#c09040^[fill:3x1:13,7:" .. WIRE
	local side = "[fill:16x16:#00000000^[fill:10x3:3,13:" .. CART .. "^[fill:3x1:13,15:" .. WIRE
	def.tiles = {top, side, side, side, side, side}
	def.groups.rockmech_charge = 1
	def.drop = ""
	def.on_dig = dig_charge
	def.on_ignite = ignite
	def.on_blast = function(pos) core.after(0.05, detonate, pos) end
	core.register_node(SURFACE, def)
end

local function tell(player, msg)
	if player and player:is_player() then core.chat_send_player(player:get_player_name(), S("[Blasting]") .. " " .. msg) end
end

-- 能不能在這個岩面鑽孔（under 是岩石、above 是空的）：回傳 nil 或不能的原因
local function cannot_drill(under, above)
	if not rockmech.lith_of_node[core.get_node(under).name] then return S("You can only drill into rock (rubble cannot be drilled)") end
	local an = core.get_node(above).name
	if an ~= "air" and core.get_item_group(an, "shotcrete_lining") == 0 then return S("The space in front of the hole collar must be empty") end   -- 噴凝土可以鑽穿（那格換成孔）
end
-- 鑽好一個孔
function rockmech.make_hole(under, above)
	if cannot_drill(under, above) then return false end
	local n = core.get_item_group(core.get_node(above).name, "shotcrete_lining")
	core.set_node(above, {name = n > 0 and VAR[HOLE][n] or HOLE, param2 = core.dir_to_wallmounted(vector.subtract(under, above))})
	return true
end

-- 鑽孔：拿著鑿岩機按住左鍵（像挖礦）、一直指著同一個岩面 drill_time 秒。伺服器每一步看玩家的按鍵與視線；
-- 放開或指到別處就重來。鑿岩機有 on_use，按左鍵不會把岩石挖掉
local DRILL = "rockmech:rock_drill"
local drilling = {}   -- 玩家名 → {key, under, above, t, hud, deepen}
-- 加深：對著已經鑽好的孔繼續按住，每 drill_time 秒多 1 m，最深 hand_max_depth。回傳孔、下一公尺的岩格與現在孔深；
-- 不能加深回傳 nil
local function deepen_site(hole)
	local node = core.get_node(hole)
	if not is_hole(node.name) then return nil end
	local d = core.wallmounted_to_dir(node.param2)
	local n = math.floor(hole_len(hole) + 0.5)
	if n >= bcfg.hand_max_depth then return nil end
	local nxt = vector.add(hole, vector.multiply(d, n + 1))
	if not rockmech.lith_of_node[core.get_node(nxt).name] then return nil end
	return n
end
local function drill_hud(player, st, text)
	if st.hud then player:hud_change(st.hud, "text", text)
	else
		st.hud = player:hud_add({type = "text", position = {x = 0.5, y = 0.56}, alignment = {x = 0, y = 0},
			text = text, number = 0xFFFFFF, z_index = 50})
	end
end
local function drill_stop(player, name)
	local st = drilling[name]
	if st and st.hud and player then player:hud_remove(st.hud) end
	drilling[name] = nil
end
core.register_globalstep(function(dtime)
	for _, pl in ipairs(core.get_connected_players()) do
		local name = pl:get_player_name()
		local ctrl = pl:get_player_control()
		local hit
		if (ctrl.dig or ctrl.LMB) and pl:get_wielded_item():get_name() == DRILL and not pl:get_attach() then
			local eye = vector.add(pl:get_pos(), {x = 0, y = pl:get_properties().eye_height, z = 0})
			for pt in core.raycast(eye, vector.add(eye, vector.multiply(pl:get_look_dir(), 4)), false, false) do
				if pt.type == "node" then hit = pt; break end
			end
		end
		if hit and core.get_item_group(core.get_node(hit.under).name, "shotcrete_lining") > 0 then
			-- 指著噴凝土：鑽它後面的岩面（那格噴凝土會被孔取代）
			local back = vector.subtract(hit.under, hit.above)
			hit = {under = vector.add(hit.under, back), above = hit.under}
		end
		local deep = hit and is_hole(core.get_node(hit.under).name) and deepen_site(hit.under)
		if not hit then
			if drilling[name] then drill_stop(pl, name) end
		else
			local key = core.pos_to_string(hit.under) .. core.pos_to_string(hit.above)
			local st = drilling[name]
			if not st or st.key ~= key then
				if st and st.hud then pl:hud_remove(st.hud) end
				st = {key = key, under = hit.under, above = hit.above, t = 0}
				drilling[name] = st
			end
			if deep then
				-- 加深鑽孔
				st.t = st.t + dtime
				local frac = math.min(1, st.t / bcfg.drill_time)
				local bars = math.floor(frac * 10 + 0.5)
				drill_hud(pl, st, S("Deepening @1 → @2 m @3", tostring(deep), tostring(deep + 1), ("■"):rep(bars) .. ("□"):rep(10 - bars)))
				if st.t >= bcfg.drill_time then
					local meta = core.get_meta(st.under)
					meta:set_float("depth", deep + 1)
					meta:set_string("infotext", S("Drill hole (depth @1 m)", tostring(deep + 1)))
					st.t = 0   -- 繼續按住就再加深一公尺
				end
			elseif is_hole(core.get_node(hit.under).name) then
				-- 不能再加深：手持風鑽到最深了，或再往前不是岩石（鑽穿到空洞、地表、碎石）
				local n = math.floor(hole_len(hit.under) + 0.5)
				drill_hud(pl, st, n >= bcfg.hand_max_depth
					and S("Hole depth @1 m (hand-held drill max @2 m)", tostring(n), ("%d"):format(bcfg.hand_max_depth))
					or S("Hole depth @1 m (no rock ahead, cannot drill further)", tostring(n)))
			elseif cannot_drill(st.under, st.above) then
				-- 鑽不了（碎石、孔口被擋住）：什麼都不顯示
				if st.hud then pl:hud_remove(st.hud); st.hud = nil end
			else
				st.t = st.t + dtime
				local frac = math.min(1, st.t / bcfg.drill_time)
				local bars = math.floor(frac * 10 + 0.5)
				drill_hud(pl, st, S("Drilling @1", ("■"):rep(bars) .. ("□"):rep(10 - bars)))
				-- 粉塵
				local dir = vector.subtract(st.under, st.above)
				local face = vector.add(st.above, vector.multiply(dir, 0.45))
				core.add_particlespawner({
					amount = 3, time = dtime,
					minpos = vector.subtract(face, 0.1), maxpos = vector.add(face, 0.1),
					minvel = {x = -1, y = 0, z = -1}, maxvel = {x = 1, y = 1.5, z = 1},
					minacc = {x = 0, y = -6, z = 0}, maxacc = {x = 0, y = -6, z = 0},
					minexptime = 0.3, maxexptime = 0.8, minsize = 0.5, maxsize = 1.2,
					texture = "[fill:4x4:#9a9088",
				})
				if st.t >= bcfg.drill_time then
					if rockmech.make_hole(st.under, st.above) then
						core.get_meta(st.above):set_string("infotext", S("Drill hole (depth @1 m)\nKeep holding to deepen it (max @2 m)",
							("%d"):format(bcfg.hole_depth), ("%d"):format(bcfg.hand_max_depth)))
					end
					drill_stop(pl, name)
				end
			end
		end
	end
end)
core.register_on_leaveplayer(function(player) drilling[player:get_player_name()] = nil end)

-- 裝藥：pointed 是鑽孔 → 裝進去；已裝藥 → 加一條；沒有鑽孔的實心面 → 貼面裝藥。回傳 true 表示用掉一條
function rockmech.load_charge(under, above, player)
	local node = core.get_node(under)
	local kind = kind_of(node.name)
	if kind == HOLE or kind == ANFO_HOLE then
		become(under, node, kind == HOLE and CHARGED or ANFO_PRIMED)
		core.get_meta(under):set_int("n", 1)
		set_info(under)
		return true
	elseif kind == ANFO_PRIMED then
		tell(player, S("This ANFO hole already has a primer"))
		return false
	elseif kind == CHARGED or kind == SURFACE then
		local meta = core.get_meta(under)
		local n = meta:get_int("n")
		if n >= bcfg.max_cartridges then
			tell(player, S("Full (max @1 cartridges)", tostring(bcfg.max_cartridges)))
			return false
		end
		meta:set_int("n", n + 1)
		set_info(under)
		return true
	end
	local nd = core.registered_nodes[node.name]
	if not (nd and nd.walkable ~= false) or core.get_node(above).name ~= "air" then return false end
	core.set_node(above, {name = SURFACE, param2 = core.dir_to_wallmounted(vector.subtract(under, above))})
	core.get_meta(above):set_int("n", 1)
	set_info(above)
	tell(player, S("No drill hole: surface charge, power only ×@1 (drill a hole with the rock drill first)", ("%.1f"):format(bcfg.surface_factor)))
	return true
end

-- 倒 ANFO：只能倒進往下的鑽孔（靠重力）；一袋裝滿整根孔。回傳 true 表示用掉一袋
function rockmech.pour_anfo(pos, player)
	local node = core.get_node(pos)
	local kind = kind_of(node.name)
	if kind == ANFO_HOLE or kind == ANFO_PRIMED then
		tell(player, S("This hole is already full of ANFO"))
		return false
	end
	if kind ~= HOLE and kind ~= CHARGED then
		tell(player, S("ANFO goes into drill holes (downward holes drilled by the surface drill rig)"))
		return false
	end
	if core.wallmounted_to_dir(node.param2).y >= 0 then
		tell(player, S("ANFO can only be poured into downward drill holes"))
		return false
	end
	local meta = core.get_meta(pos)
	-- 空孔 → 只有 ANFO；先放了乳膠炸藥的孔 → 那條就是起爆藥包
	become(pos, node, kind == HOLE and ANFO_HOLE or ANFO_PRIMED)
	if kind == HOLE then meta:set_int("n", 0) end
	set_info(pos)
	if meta:get_int("n") < 1 then tell(player, S("No primer yet: add one emulsion cartridge, otherwise it will misfire")) end
	return true
end

rockmech.hole_kind = kind_of        -- 噴過凝土的孔 → 同狀態的一般孔
rockmech.with_sprayed = with_sprayed
function rockmech.hole_variant(kind, n) return n > 0 and VAR[kind][n] or kind end    -- 狀態 kind、噴了 n 層的方塊

-- 起爆器：range 內所有裝藥倒數後依序起爆。回傳裝藥數
function rockmech.fire_round(pos, player)
	local r = bcfg.detonator_range
	local list = core.find_nodes_in_area(vector.subtract(pos, r), vector.add(pos, r), CHARGES)
	local charges = {}
	for _, p in ipairs(list) do
		if vector.distance(p, pos) <= r then charges[#charges + 1] = p end
	end
	if #charges == 0 then
		tell(player, S("No charges within @1 m", ("%d"):format(r)))
		return 0
	end
	-- 離起爆器近的先爆（段發）
	table.sort(charges, function(a, b) return vector.distance(a, pos) < vector.distance(b, pos) end)
	local delay = bcfg.detonator_delay
	tell(player, S("@1 charges, firing in @2 seconds, move to a safe distance!", tostring(#charges), ("%d"):format(math.ceil(delay))))
	-- 畫面正中央的大倒數：5、4、3、2、1，起爆時消失
	local name = player and player:is_player() and player:get_player_name()
	local hud
	local function show(text)
		local pl = name and core.get_player_by_name(name)
		if not pl then return end
		if hud then pl:hud_change(hud, "text", text)
		else
			hud = pl:hud_add({type = "text", position = {x = 0.5, y = 0.4}, alignment = {x = 0, y = 0},
				text = text, number = 0xFF3030, size = {x = 8, y = 8}, style = 1, z_index = 200})
		end
	end
	local n = math.ceil(delay)
	for t = n, 1, -1 do
		core.after(delay - t, show, tostring(t))
	end
	core.after(delay, function()
		local pl = name and core.get_player_by_name(name)
		if pl and hud then pl:hud_remove(hud) end
	end)
	for i, p in ipairs(charges) do
		core.after(delay + (i - 1) * bcfg.hole_interval, detonate, p)
	end
	return #charges
end

core.register_tool(DRILL, {
	description = S("Rock drill\nHold left-click on a rock face to drill a hole (@1 s, @2 m); keep holding on a hole to deepen it 1 m every @3 s (max @4 m)",
		("%g"):format(bcfg.drill_time), ("%d"):format(bcfg.hole_depth), ("%g"):format(bcfg.drill_time), ("%d"):format(bcfg.hand_max_depth)),
	short_description = S("Rock drill"),
	inventory_image = "[fill:16x16:#00000000^[fill:9x5:2,5:#d0a020^[fill:5x1:11,7:#b0b0b0^[fill:3x5:3,10:#404040^[fill:2x1:15,7:#e0e0e0",
	-- 有 on_use 的物品按左鍵只會「使用」、不會挖方塊（只有 groupcaps 空的話會改用手挖，創造模式的手什麼都挖得動）。
	-- 鑽孔看的是左鍵有沒有按住（上面的 globalstep），這裡什麼都不做
	tool_capabilities = {full_punch_interval = 1.0, max_drop_level = 0, groupcaps = {}, damage_groups = {fleshy = 1}},
	on_use = function() return nil end,
	on_place = function(itemstack, placer)
		tell(placer, S("Rock drill: hold left-click on a rock face to drill a hole"))
		return itemstack
	end,
})
core.register_craftitem(EMULSION, {
	description = S("Emulsion explosive\nRight-click a drill hole to load it (max @1 per hole); without a hole it can only be stuck on the surface, with little power",
		tostring(bcfg.max_cartridges)),
	short_description = S("Emulsion explosive"),
	inventory_image = "[fill:16x16:#00000000^[fill:4x12:6,2:" .. CART .. "^[fill:4x1:6,2:#c09040^[fill:4x1:6,13:#c09040^[fill:1x3:8,0:" .. WIRE,
	on_place = function(itemstack, placer, pointed)
		if pointed.type ~= "node" then return itemstack end
		if rockmech.load_charge(pointed.under, pointed.above, placer)
			and not core.is_creative_enabled(placer and placer:get_player_name() or "") then
			itemstack:take_item()
		end
		return itemstack
	end,
})
core.register_craftitem(ANFO, {
	description = S("ANFO (ammonium nitrate/fuel oil, one bag)\nRight-click a downward drill hole to pour it in as a column charge; needs one emulsion cartridge as a primer"),
	short_description = S("ANFO"),
	inventory_image = "[fill:16x16:#00000000^[fill:10x12:3,3:#e8e4d8^[fill:10x2:3,3:#c8c0a8^[fill:6x3:5,8:#d03020",
	on_place = function(itemstack, placer, pointed)
		if pointed.type ~= "node" then return itemstack end
		if rockmech.pour_anfo(pointed.under, placer)
			and not core.is_creative_enabled(placer and placer:get_player_name() or "") then
			itemstack:take_item()
		end
		return itemstack
	end,
})
core.register_craftitem("rockmech:detonator", {
	description = S("Blasting machine\nRight-click: charges within @1 m count down @2 seconds, then fire in sequence",
		tostring(bcfg.detonator_range), tostring(bcfg.detonator_delay)),
	short_description = S("Blasting machine"),
	inventory_image = "[fill:16x16:#00000000^[fill:10x7:3,8:#b03020^[fill:2x6:7,2:#606060^[fill:6x1:5,2:#404040^[fill:4x2:6,10:#202020",
	stack_max = 1,
	on_place = function(itemstack, placer)
		if placer then rockmech.fire_round(placer:get_pos(), placer) end
		return itemstack
	end,
	on_secondary_use = function(itemstack, user)
		if user then rockmech.fire_round(user:get_pos(), user) end
		return itemstack
	end,
})
