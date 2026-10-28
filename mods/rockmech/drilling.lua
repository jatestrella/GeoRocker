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
--   裝藥被別的爆炸波及會殉爆。參數在設定 rockmech_blast_*。

if not rockmech.blast_charge then return end   -- 沒有 tnt mod

local bcfg = rockmech.cfg.blast
local HOLE = "rockmech:drill_hole"
local CHARGED = "rockmech:charged_hole"
local SURFACE = "rockmech:surface_charge"
local EMULSION = "rockmech:emulsion"
local ANFO = "rockmech:anfo"
-- 鑽孔的孔深（m）：鑽機鑽的垂直孔記在 meta depth，其他是 hole_depth
local function hole_len(pos)
	local d = core.get_meta(pos):get_float("depth")
	return d > 0 and d or bcfg.hole_depth
end

-- 方塊外觀：貼壁方塊（paramtype2 wallmounted）的 fixed 方塊以「貼在地上」的方向定義，引擎依 param2 轉到各面。
-- 上面（+Y）的貼圖就是朝外那一面；側面貼圖的最下一列對應貼著岩面的那層
local RING = {-0.25, -0.5, -0.25, 0.25, -0.45, 0.25}                       -- 孔口的圓環
local RING_TOP = "[fill:16x16:#00000000^[fill:8x6:4,5:#7a7268^[fill:6x8:5,4:#7a7268"
	.. "^[fill:6x4:5,6:#4a4440^[fill:4x6:6,5:#4a4440^[fill:2x4:7,6:#0c0c0c^[fill:4x2:6,7:#0c0c0c"
local RING_SIDE = "[fill:16x16:#00000000^[fill:16x1:0,15:#6a625a"
local CART = "#e8c070"     -- 乳膠炸藥藥卷
local WIRE = "#c02020"     -- 起爆線
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
	if node.name == CHARGED and meta:get_int("anfo") == 1 then
		meta:set_string("infotext", n > 0
			and ("ANFO 柱狀裝藥（孔深 %.0f m）＋ 起爆藥包 %d 條\n打火石點火、或用起爆器"):format(hole_len(pos), n)
			or ("ANFO 柱狀裝藥（孔深 %.0f m）\n還沒有起爆藥包：放一條乳膠炸藥，否則會拒爆"):format(hole_len(pos)))
	elseif node.name == CHARGED then
		meta:set_string("infotext", ("裝藥鑽孔：%d 條乳膠炸藥（最多 %d）\n打火石點火、或用起爆器"):format(n, bcfg.max_cartridges))
	elseif node.name == SURFACE then
		meta:set_string("infotext", ("貼面裝藥：%d 條（沒有鑽孔，威力 ×%.1f）\n打火石點火、或用起爆器"):format(n, bcfg.surface_factor))
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
	for _, hp in ipairs(core.find_nodes_in_area(vector.subtract(c0, reach), vector.add(c0, reach), {HOLE})) do
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
	if node.name ~= CHARGED and node.name ~= SURFACE then return end
	local meta = core.get_meta(pos)
	local dir = core.wallmounted_to_dir(node.param2)
	local depth = hole_len(pos)
	if node.name == CHARGED and meta:get_int("anfo") == 1 then
		if meta:get_int("n") < 1 then
			-- 拒爆：ANFO 沒有起爆藥包炸不響，留在孔裡
			meta:set_int("lit", 0)
			meta:set_string("infotext", "拒爆：ANFO 沒有起爆藥包（放一條乳膠炸藥再起爆）")
			core.log("action", "[rockmech] 拒爆（ANFO 沒有起爆藥包）" .. core.pos_to_string(pos))
			return
		end
		-- 柱狀裝藥：孔口留填塞，往下每 1.5 m 一段；夾制／自由面整根孔一起算
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
			rockmech.blast_charge(last, R * f)
			t = t + 1.5
		until t > depth + 0.5
		R = R * f + depth
		local center = last
		local r = math.ceil(R) + 1
		for _, hp in ipairs(core.find_nodes_in_area(vector.subtract(center, r), vector.add(center, r), {HOLE, CHARGED, SURFACE})) do
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
	if node.name == CHARGED then
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
	rockmech.blast_charge(center, R)
	-- 爆破直接改地圖、不會觸發貼壁方塊掉落：後面的岩石沒了的鑽孔、裝藥一起消失
	local r = math.ceil(R) + depth + 1
	for _, hp in ipairs(core.find_nodes_in_area(vector.subtract(center, r), vector.add(center, r), {HOLE, CHARGED, SURFACE})) do
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
	local def = node_base("鑽孔 Drill hole")
	def.node_box = {type = "fixed", fixed = {RING}}
	def.selection_box = {type = "fixed", fixed = {{-0.3, -0.5, -0.3, 0.3, -0.38, 0.3}}}
	def.tiles = {RING_TOP, RING_SIDE, RING_SIDE, RING_SIDE, RING_SIDE, RING_SIDE}
	def.drop = ""
	core.register_node(HOLE, def)
end
-- 裝了炸藥的鑽孔：孔口露出一截藥卷與起爆線
do
	local def = node_base("裝藥鑽孔 Charged hole")
	def.node_box = {type = "fixed", fixed = {RING, {-0.08, -0.45, -0.08, 0.08, -0.15, 0.08}, {0.08, -0.45, -0.03, 0.4, -0.42, 0.03}}}
	def.selection_box = {type = "fixed", fixed = {{-0.3, -0.5, -0.3, 0.3, -0.12, 0.3}}}
	local top = RING_TOP .. "^[fill:3x3:7,7:" .. CART .. "^[fill:6x2:9,7:" .. WIRE
	local side = RING_SIDE .. "^[fill:4x5:6,10:" .. CART .. "^[fill:6x1:9,14:" .. WIRE
	def.tiles = {top, RING_SIDE, side, side, side, side}
	def.groups.rockmech_charge = 1
	def.drop = ""
	def.on_dig = dig_charge
	def.on_ignite = ignite
	def.on_blast = function(pos) core.after(0.05, detonate, pos) end   -- 殉爆
	core.register_node(CHARGED, def)
end
-- 貼面裝藥：一束藥卷貼在岩面上
do
	local def = node_base("貼面裝藥 Surface charge")
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
	if player and player:is_player() then core.chat_send_player(player:get_player_name(), "[爆破] " .. msg) end
end

-- 能不能在這個岩面鑽孔（under 是岩石、above 是空的）：回傳 nil 或不能的原因
local function cannot_drill(under, above)
	if not rockmech.lith_of_node[core.get_node(under).name] then return "只能在岩石上鑽孔（碎石鑽不了）" end
	if core.get_node(above).name ~= "air" then return "孔口前面要是空的" end
end
-- 鑽好一個孔
function rockmech.make_hole(under, above)
	if cannot_drill(under, above) then return false end
	core.set_node(above, {name = HOLE, param2 = core.dir_to_wallmounted(vector.subtract(under, above))})
	return true
end

-- 鑽孔：拿著鑿岩機按住左鍵（像挖礦）、一直指著同一個岩面 drill_time 秒。伺服器每一步看玩家的按鍵與視線；
-- 放開或指到別處就重來。鑿岩機有 on_use，按左鍵不會把岩石挖掉
local DRILL = "rockmech:rock_drill"
local drilling = {}   -- 玩家名 → {key, under, above, t, hud}
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
			if cannot_drill(st.under, st.above) then
				-- 鑽不了（碎石、孔口被擋住）：什麼都不顯示
				if st.hud then pl:hud_remove(st.hud); st.hud = nil end
			else
				st.t = st.t + dtime
				local frac = math.min(1, st.t / bcfg.drill_time)
				local bars = math.floor(frac * 10 + 0.5)
				drill_hud(pl, st, "鑽孔 " .. ("■"):rep(bars) .. ("□"):rep(10 - bars))
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
					rockmech.make_hole(st.under, st.above)
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
	if node.name == HOLE then
		core.swap_node(under, {name = CHARGED, param2 = node.param2})
		core.get_meta(under):set_int("n", 1)
		set_info(under)
		return true
	elseif node.name == CHARGED or node.name == SURFACE then
		local meta = core.get_meta(under)
		local n = meta:get_int("n")
		if n >= bcfg.max_cartridges then
			tell(player, ("裝滿了（最多 %d 條）"):format(bcfg.max_cartridges))
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
	tell(player, ("沒有鑽孔：貼面裝藥，威力只有 ×%.1f（先用鑿岩機鑽孔）"):format(bcfg.surface_factor))
	return true
end

-- 倒 ANFO：只能倒進往下的鑽孔（靠重力）；一袋裝滿整根孔。回傳 true 表示用掉一袋
function rockmech.pour_anfo(pos, player)
	local node = core.get_node(pos)
	if node.name ~= HOLE and node.name ~= CHARGED then
		tell(player, "ANFO 要倒進鑽孔（露天鑽機鑽的往下的孔）")
		return false
	end
	if core.wallmounted_to_dir(node.param2).y >= 0 then
		tell(player, "ANFO 只能倒進往下的鑽孔")
		return false
	end
	local meta = core.get_meta(pos)
	if meta:get_int("anfo") == 1 then
		tell(player, "這個孔已經裝滿 ANFO 了")
		return false
	end
	if node.name == HOLE then
		core.swap_node(pos, {name = CHARGED, param2 = node.param2})
		meta:set_int("n", 0)
	end
	meta:set_int("anfo", 1)
	set_info(pos)
	if meta:get_int("n") < 1 then tell(player, "還沒有起爆藥包：放一條乳膠炸藥，否則會拒爆") end
	return true
end

-- 起爆器：range 內所有裝藥倒數後依序起爆。回傳裝藥數
function rockmech.fire_round(pos, player)
	local r = bcfg.detonator_range
	local list = core.find_nodes_in_area(vector.subtract(pos, r), vector.add(pos, r), {CHARGED, SURFACE})
	local charges = {}
	for _, p in ipairs(list) do
		if vector.distance(p, pos) <= r then charges[#charges + 1] = p end
	end
	if #charges == 0 then
		tell(player, ("%d m 內沒有裝藥"):format(r))
		return 0
	end
	-- 離起爆器近的先爆（段發）
	table.sort(charges, function(a, b) return vector.distance(a, pos) < vector.distance(b, pos) end)
	local delay = bcfg.detonator_delay
	tell(player, ("%d 個裝藥，%d 秒後起爆，退到安全距離！"):format(#charges, math.ceil(delay)))
	-- 畫面正中央的大倒數：5、4、3、2、1，起爆時消失
	local name = player and player:is_player() and player:get_player_name()
	local hud
	local function show(text)
		local pl = name and core.get_player_by_name(name)
		if not pl then return end
		if hud then pl:hud_change(hud, "text", text)
		else
			hud = pl:hud_add({type = "text", position = {x = 0.5, y = 0.4}, alignment = {x = 0, y = 0},
				text = text, number = 0xFF3030, size = {x = 8}, style = 1, z_index = 200})
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
	description = "鑿岩機 Rock drill\n對岩面按住左鍵鑽孔（" .. bcfg.drill_time .. " 秒）",
	inventory_image = "[fill:16x16:#00000000^[fill:9x5:2,5:#d0a020^[fill:5x1:11,7:#b0b0b0^[fill:3x5:3,10:#404040^[fill:2x1:15,7:#e0e0e0",
	-- 有 on_use 的物品按左鍵只會「使用」、不會挖方塊（只有 groupcaps 空的話會改用手挖，創造模式的手什麼都挖得動）。
	-- 鑽孔看的是左鍵有沒有按住（上面的 globalstep），這裡什麼都不做
	tool_capabilities = {full_punch_interval = 1.0, max_drop_level = 0, groupcaps = {}, damage_groups = {fleshy = 1}},
	on_use = function() return nil end,
	on_place = function(itemstack, placer)
		tell(placer, "鑿岩機：對岩面按住左鍵鑽孔")
		return itemstack
	end,
})
core.register_craftitem(EMULSION, {
	description = "乳膠炸藥 Emulsion explosive\n對鑽孔按右鍵裝藥（一孔最多 " .. bcfg.max_cartridges .. " 條）；沒有鑽孔只能貼面，威力很小",
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
	description = "ANFO（銨油炸藥，一袋）\n對往下的鑽孔按右鍵倒進去成柱狀裝藥；要有一條乳膠炸藥當起爆藥包",
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
	description = "起爆器 Blasting machine\n按右鍵：" .. bcfg.detonator_range .. " m 內的裝藥倒數 " .. bcfg.detonator_delay .. " 秒後依序起爆",
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
