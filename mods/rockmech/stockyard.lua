-- rockmech/stockyard.lua
-- 煤礦堆置處（rockmech_stockyard = true 的地圖，取代小鎮的收煤站）：玩家自己插「堆置處告示牌」劃一塊地，把煤倒在上面；
-- 白天不定期有煤商開小貨車從地磅站（haulroad.lua）沿路開來，停在煤堆旁邊，人下車講幾句話，挖走不定量的煤、付錢，再開走。
--   範圍：以告示牌為中心往外 size × size m（10／16／24），範圍裡至少要有一格壓到道路（小鎮的路或往電廠的路），
--     買家的車才開得到。一個帳戶一處；外框在告示牌附近用粒子線畫出來（沒有圍籬，不擋車）。
--   售價：玩家自己訂（每噸純煤）。買家的行情價 = 市價 × rockmech_stockyard_ref（預設 0.8，小盤商要自己載、要賺價差）；
--     售價不超過行情一定買，超過越多越不想買：機率 = exp(−彈性 ×（售價 ÷ 行情 − 1）)（rockmech_stockyard_elasticity）。
--     煤堆平均品位低於 40% 再打折（石頭太多）。
--   買家：平均每 rockmech_stockyard_interval 秒（遊戲時間）一位（指數分布），每位要 rockmech_stockyard_tons（最少,最多）噸，
--     只挖含煤的碎石（純廢石留著）。付款 = 挖走的純煤噸數 × 售價。晚上（20:00–07:00）不來。
--   附近沒人時照樣成交（不放畫面，直接挖、付錢、通知）。

local cfg = rockmech.cfg
if not (cfg.career and cfg.stockyard) then return end
local S = rockmech.S
local V = rockmech.vehicles
local storage = rockmech.collapse.storage
local F = core.formspec_escape
local tons_of = rockmech.tons_of
local function money_text(v) return rockmech.money_text and rockmech.money_text(v) or ("$%.0f"):format(v) end
local function t1(t) return ("%.1f t"):format(t) end

local SIGN = "rockmech:yard_sign"
local SIZES = {10, 16, 24}
local KEY = "yard:"                 -- mod storage：帳戶 → {x, y, z, dx, dz, size, ask, sales = {...}, next_t}
local FORM = "rockmech:yard"
local HOURS = {7, 20}
local SPEED = 7                     -- 買家的車速 (m/s)
local SHOW_R = 48                   -- 堆置處這麼近有人，才放出買家的車和人（不然直接成交）
local ACTIVE = 44                   -- 車在離最近的玩家這麼遠的路上出現、開到這麼遠就收掉（引擎只讓玩家附近約 64 m 的區塊在跑）
local MIN_COAL = 3                  -- 煤堆少於幾噸純煤就當作沒煤（買家還是會來，看一看就走）
local LOW_G = 0.4                   -- 平均品位低於這個，買家意願打折
local DY = 16                       -- 煤堆在告示牌上下幾公尺內都算（斜坡上的堆置處、碎石往低處流）
local TRUCK = "rockmech:receiver"   -- orders.lua 的小貨車
local BUYER = "rockmech:yard_buyer"

local function yard_of(acc)
	local s = storage:get_string(KEY .. acc)
	return s ~= "" and core.deserialize(s) or nil
end
local function set_yard(acc, y) storage:set_string(KEY .. acc, y and core.serialize(y) or "") end
local function all_yards()
	local out = {}
	for _, k in ipairs(storage:get_keys()) do
		local acc = k:match("^" .. KEY .. "(.+)$")
		if acc then local y = yard_of(acc); if y then out[acc] = y end end
	end
	return out
end
local function hour() return (core.get_timeofday() or 0.5) * 24 end
local function daytime() local h = hour(); return h >= HOURS[1] and h < HOURS[2] end

-- 範圍：以告示牌為中心的 size × size（東西、南北對齊格線）。each_cell(y, fn) 對每一格呼叫 fn(x, z)
local function each_cell(y, fn)
	local h = math.floor(y.size / 2)
	for i = -h, y.size - h - 1 do for j = -h, y.size - h - 1 do fn(y.x + i, y.z + j) end end
end
local function inside(y, x, z)
	local h = math.floor(y.size / 2)
	local rx, rz = x - y.x, z - y.z
	return rx >= -h and rx <= y.size - h - 1 and rz >= -h and rz <= y.size - h - 1
end

---------------------------------------------------------------------------
-- 道路：小鎮的路（village.lua 的 road_cells，3 m 寬）、往電廠的路（haulroad.lua 的中線，8 m 寬）
---------------------------------------------------------------------------

local road_set
local function roads()
	if road_set then return road_set end
	local set = {}
	local P = rockmech.village and rockmech.village.get()
	if P and rockmech.village.road_cells then
		for k in pairs(rockmech.village.road_cells(P.roads)) do set[k] = true end
	end
	local hl = rockmech.haul_line and rockmech.haul_line()
	if hl then
		local w = (rockmech.haul_road_width or 8) / 2
		for _, p in ipairs(hl) do
			for dx = -w, w do for dz = -w, w do
				if dx * dx + dz * dz <= w * w then set[math.floor(p[1] + dx + 0.5) .. "," .. math.floor(p[2] + dz + 0.5)] = true end
			end end
		end
		road_set = set          -- 往電廠的路蓋好了才快取（之前的話下次再算）
	end
	return set
end
local function touches_road(y)
	local set, hit = roads(), false
	each_cell(y, function(x, z) if set[x .. "," .. z] then hit = true end end)
	return hit
end

-- 路網（買家開的路）：小鎮各條路的點、往電廠道路的中線；點跟點沿線相連，不同條路 6 m 內的點也相連
local graph
local function build_graph()
	local nodes, adj = {}, {}
	local lines = {}
	local P = rockmech.village and rockmech.village.get()
	if P then for _, r in ipairs(P.roads) do lines[#lines + 1] = r.points end end
	local hl = rockmech.haul_line and rockmech.haul_line()
	local gate
	if hl and #hl > 0 then lines[#lines + 1] = hl end
	local function add(p) nodes[#nodes + 1] = {x = p[1], z = p[2]}; adj[#nodes] = {}; return #nodes end
	local function link(a, b)
		local d = math.sqrt((nodes[a].x - nodes[b].x) ^ 2 + (nodes[a].z - nodes[b].z) ^ 2)
		adj[a][#adj[a] + 1] = {b, d}; adj[b][#adj[b] + 1] = {a, d}
	end
	local owner = {}
	for li, pts in ipairs(lines) do
		local prev
		for _, p in ipairs(pts) do
			local i = add(p)
			owner[i] = li
			if prev then link(prev, i) end
			prev = i
		end
		if li == #lines and hl and #hl > 0 then gate = prev end      -- 往電廠道路的最後一點 = 地磅站
	end
	for a = 1, #nodes do for b = a + 1, #nodes do
		if owner[a] ~= owner[b] and (nodes[a].x - nodes[b].x) ^ 2 + (nodes[a].z - nodes[b].z) ^ 2 <= 36 then link(a, b) end
	end end
	-- 沒有往電廠的路：從離中心最遠的路點來
	if not gate then
		local best = -1
		for i, n in ipairs(nodes) do local d = n.x * n.x + n.z * n.z; if d > best then best, gate = d, i end end
	end
	graph = {nodes = nodes, adj = adj, gate = gate, with_haul = hl ~= nil}
	return graph
end
-- 地磅站 → 堆置處旁邊（離範圍最近的路點）的路線：{{x, z}, …}
local function route_to(y)
	if not graph or (not graph.with_haul and rockmech.haul_line and rockmech.haul_line()) then build_graph() end
	local G = graph
	if not G.gate then return nil end
	local goal, gd = nil, math.huge
	for i, n in ipairs(G.nodes) do
		local cx, cz = y.x, y.z
		local d = (n.x - cx) ^ 2 + (n.z - cz) ^ 2
		if d < gd then gd, goal = d, i end
	end
	local dist, prev, done = {[G.gate] = 0}, {}, {}
	while true do
		local u, ud
		for i, dd in pairs(dist) do if not done[i] and (not ud or dd < ud) then u, ud = i, dd end end
		if not u or u == goal then break end
		done[u] = true
		for _, e in ipairs(G.adj[u]) do
			local v, w = e[1], e[2]
			if not dist[v] or ud + w < dist[v] then dist[v], prev[v] = ud + w, u end
		end
	end
	if not dist[goal] then return nil end
	local path, k = {}, goal
	while k do table.insert(path, 1, {x = G.nodes[k].x, z = G.nodes[k].z}); k = prev[k] end
	return path
end

---------------------------------------------------------------------------
-- 煤堆：範圍裡的碎石（統計、挖走）
---------------------------------------------------------------------------

-- 範圍那塊地圖載入（附近沒人時也要能統計、成交）
local function load_yard(y)
	local h = y.size + 2
	core.load_area({x = y.x - h, y = y.y - DY - 1, z = y.z - h}, {x = y.x + h, y = y.y + DY + 1, z = y.z + h})
end
local function scan(y)
	load_yard(y)
	local list = {}
	each_cell(y, function(x, z)
		for yy = y.y + DY, y.y - DY, -1 do
			local p = {x = x, y = yy, z = z}
			local node = core.get_node(p)
			local lv = rockmech.rubble_level[node.name]
			if lv then
				local base = rockmech.rubble_base[node.name]
				local g = rockmech.grade_for(base, node.param2, cfg.main_ore)
				list[#list + 1] = {p = p, name = node.name, base = base, lv = lv, p2 = node.param2, g = g}
			end
		end
	end)
	return list
end
local function stats(y)
	local tot, coal_rock, coal = 0, 0, 0
	for _, c in ipairs(scan(y)) do
		local t = tons_of(c.lv)
		tot = tot + t
		if c.g > 0 then coal_rock, coal = coal_rock + t, coal + t * c.g end
	end
	return tot, coal_rock, coal
end
-- 從上往下挖走 want 噸含煤的碎石：回傳 挖走的噸數, 純煤噸數
local function take(y, want)
	local list = {}
	for _, c in ipairs(scan(y)) do if c.g > 0 then list[#list + 1] = c end end
	table.sort(list, function(a, b) return a.p.y > b.p.y end)
	local need = want
	local got, coal = 0, 0
	for _, c in ipairs(list) do
		if need <= 0.01 then break end
		local per = tons_of(1)
		local k = math.min(c.lv, math.ceil(need / per))
		local left = c.lv - k
		if left <= 0 then core.remove_node(c.p)
		else core.swap_node(c.p, {name = rockmech.rubble_with_level(c.base, left, c.p2), param2 = c.p2}) end
		local t = tons_of(k)
		got, coal, need = got + t, coal + t * c.g, need - t
	end
	return got, coal
end

---------------------------------------------------------------------------
-- 告示牌
---------------------------------------------------------------------------

local function tell(acc, msg) rockmech.notify_account(acc, S("[Stockyard] @1", msg)) end
local function sign_pos(y) return {x = y.x, y = y.y, z = y.z} end

core.register_node(SIGN, {
	description = S("Stockyard sign\nPlace it in the middle of the stockyard"),
	short_description = S("Stockyard sign"),
	drawtype = "nodebox", paramtype = "light", paramtype2 = "facedir", sunlight_propagates = true,
	node_box = {type = "fixed", fixed = {{-0.06, -0.5, -0.06, 0.06, 1.0, 0.06}, {-0.5, 0.8, -0.04, 0.5, 1.45, 0.04}}},
	tiles = {"[fill:16x16:#6a4a2a^[fill:14x9:1,2:#e8d8a0^[fill:10x2:3,4:#3a2a1a^[fill:8x2:4,8:#3a2a1a"},
	inventory_image = "[fill:16x16:#00000000^[fill:2x10:7,6:#6a4a2a^[fill:14x8:1,1:#e8d8a0^[fill:10x2:3,3:#3a2a1a^[fill:8x2:4,6:#3a2a1a",
	groups = {choppy = 3, oddly_breakable_by_hand = 2, dig_immediate = 2},      -- 什麼工具（徒手也行）都拔得起來
	is_ground_content = false,
	on_place = function(itemstack, placer, pointed)
		if pointed.type ~= "node" or not placer then return itemstack end
		local name = placer:get_player_name()
		local acc = rockmech.account_of(name)
		if yard_of(acc) then
			rockmech.notify(name, S("[Stockyard] You already have one. Take the old sign out first"))
			return itemstack
		end
		local pos = pointed.above
		local look = placer:get_look_dir()
		local dx, dz = 0, 0
		if math.abs(look.x) > math.abs(look.z) then dx = look.x > 0 and 1 or -1 else dz = look.z > 0 and 1 or -1 end
		local y = {x = pos.x, y = pos.y, z = pos.z, dx = dx, dz = dz, size = 16, sales = {}}
		if not touches_road(y) then
			y.size = 24
			if not touches_road(y) then
				rockmech.notify(name, S("[Stockyard] The stockyard must touch a road, so the buyers' trucks can reach it"))
				return itemstack
			end
		end
		if core.is_protected(pos, name) then return itemstack end
		core.set_node(pos, {name = SIGN, param2 = core.dir_to_facedir({x = -dx, y = 0, z = -dz})})
		y.ask = math.floor(rockmech.ore_price(cfg.main_ore) * cfg.stockyard_ref + 0.5)
		set_yard(acc, y)
		core.get_meta(pos):set_string("owner", acc)
		core.get_meta(pos):set_string("infotext", S("Stockyard (right-click)"))
		rockmech.notify(name, S("[Stockyard] Set up @1 × @2 m. Dump coal inside the outline; buyers come in the daytime", y.size, y.size))
		if not core.is_creative_enabled(name) then itemstack:take_item() end
		return itemstack
	end,
	can_dig = function(pos, player)
		return player and rockmech.owner_ok(core.get_meta(pos):get_string("owner"), player:get_player_name())
	end,
	after_dig_node = function(pos, oldnode, oldmeta)
		local acc = oldmeta and oldmeta.fields and oldmeta.fields.owner
		local y = acc and yard_of(acc)
		if y and y.x == pos.x and y.y == pos.y and y.z == pos.z then set_yard(acc, nil) end
	end,
	on_rightclick = function(pos, node, clicker)
		if clicker and clicker:is_player() then rockmech.yard_form(clicker, core.get_meta(pos):get_string("owner")) end
	end,
})

-- 外框：告示牌 30 m 內的人看得到（每秒畫一次，只給那個人）
local ot = 0
core.register_globalstep(function(dtime)
	ot = ot + dtime
	if ot < 1 then return end
	ot = 0
	local players = core.get_connected_players()
	if #players == 0 then return end
	for acc, y in pairs(all_yards()) do
		local sp = sign_pos(y)
		for _, pl in ipairs(players) do
			if vector.distance(pl:get_pos(), sp) < 30 then
				local name = pl:get_player_name()
				local h = math.floor(y.size / 2)
				local function mark(i, j)
					local x, z = y.x + i, y.z + j
					local gy = rockmech.ground_y(math.floor(x + 0.5), math.floor(z + 0.5), y.y + 8, y.y - 6) or y.y - 1
					core.add_particle({pos = {x = x, y = gy + 0.6, z = z}, expirationtime = 1.1, size = 3, playername = name,
						texture = "[fill:4x4:#ffd040", glow = 8})
				end
				local lo, hi = -h - 0.5, y.size - h - 0.5
				for t = lo, hi, 1 do mark(t, lo); mark(t, hi); mark(lo, t); mark(hi, t) end
			end
		end
	end
end)

---------------------------------------------------------------------------
-- 買家：煤商（人）、小貨車（orders.lua 的 receiver）
---------------------------------------------------------------------------

local LINES = {
	S("Morning. Business is slow lately."), S("The road from the plant is full of potholes."),
	S("Your pile looks decent."), S("The power plant pays late again."), S("Rain makes the coal heavy."),
}
local EMPTY_LINES = {                -- 堆置處沒煤
	S("Hello? Anyone selling coal?"), S("Where's the coal? I drove all the way here."), S("Empty again?"),
}
core.register_entity(BUYER, {
	initial_properties = {
		physical = false, collisionbox = {-0.3, 0, -0.3, 0.3, 1.7, 0.3},
		visual = "mesh", mesh = "character.b3d", textures = {rockmech.npc_skin("buyer")},
		nametag = S("Coal trader"), nametag_color = "#ffd080", static_save = false,
	},
	on_activate = function(self)
		self.object:set_armor_groups({immortal = 1})
		self.object:set_animation({x = 0, y = 79}, 30)
		rockmech.npc_dress(self.object, "buyer")
	end,
	on_step = function(self)
		if not self.live then self.object:remove() end
	end,
})

local visits = {}          -- 帳戶 → 進行中的拜訪（畫面）
local function players_near(p, r)
	for _, pl in ipairs(core.get_connected_players()) do
		if vector.distance(pl:get_pos(), p) < r then return true end
	end
	return false
end
-- 離最近的玩家多遠（測試開關 force_show：當作有人站在告示牌）
local function near_dist(p, sp)
	local best = math.huge
	for _, pl in ipairs(core.get_connected_players()) do best = math.min(best, vector.distance(pl:get_pos(), p)) end
	if rockmech.stockyard_debug.force_show and sp then best = math.min(best, vector.distance(sp, p)) end
	return best
end
local function say_near(o, text)
	local p = o and o:get_pos()
	if not p then return end
	for _, pl in ipairs(core.get_connected_players()) do
		if vector.distance(pl:get_pos(), p) < 16 then rockmech.npc_say(o, pl, text) end
	end
end

-- 要不要買：回傳 機率, 理由（"price"／"grade"）
local function willing(y, avg_g)
	local ref = rockmech.ore_price(cfg.main_ore) * cfg.stockyard_ref
	local r = (y.ask or ref) / math.max(1, ref)
	local pf = math.exp(-cfg.stockyard_elasticity * math.max(0, r - 1))      -- 價錢
	local gf = avg_g < LOW_G and (avg_g / LOW_G) ^ 2 or 1                       -- 石頭太多
	return pf * gf, gf < pf and "grade" or "price"
end

-- 成交（畫面或直接）：挖、付錢、記錄、通知。回傳挖走的噸數
local function close_deal(acc, y, want)
	local got, coal = take(y, want)
	if got <= 0 then return 0 end
	local pay = math.floor(coal * y.ask + 0.5)
	rockmech.add_money(acc, pay)
	y = yard_of(acc) or y
	y.sales = y.sales or {}
	table.insert(y.sales, 1, {t = core.get_gametime(), tons = got, coal = coal, pay = pay, ask = y.ask})
	while #y.sales > 5 do table.remove(y.sales) end
	set_yard(acc, y)
	tell(acc, S("A coal trader took @1 (@2 of coal) and paid @3", t1(got), t1(coal), money_text(pay)))
	for _, m in ipairs(rockmech.account_members(acc)) do core.sound_play("rockmech_coin", {to_player = m, gain = 0.8}, true) end
	return got
end

local function pose_at(path, s)
	local acc = 0
	for i = 2, #path do
		local a, b = path[i - 1], path[i]
		local L = math.sqrt((b.x - a.x) ^ 2 + (b.z - a.z) ^ 2)
		if acc + L >= s or i == #path then
			local t = L > 0 and math.min(1, math.max(0, (s - acc) / L)) or 1
			return a.x + (b.x - a.x) * t, a.z + (b.z - a.z) * t, (math.atan2 or math.atan)(-(b.x - a.x), b.z - a.z)
		end
		acc = acc + L
	end
	return path[1].x, path[1].z, 0
end
local function path_len(path)
	local L = 0
	for i = 2, #path do L = L + math.sqrt((path[i].x - path[i - 1].x) ^ 2 + (path[i].z - path[i - 1].z) ^ 2) end
	return L
end

-- 一位買家上門
local function start_visit(acc, y)
	local _, coal_rock, coal = stats(y)
	local avg = coal_rock > 0 and coal / coal_rock or 0
	local want = cfg.stockyard_tmin + math.random() * (cfg.stockyard_tmax - cfg.stockyard_tmin)
	local p, why = willing(y, avg)
	if coal < MIN_COAL then p, why = 0, "empty" end      -- 沒煤：還是會來，看一看就走
	local buy = math.random() < p
	local sp = sign_pos(y)
	local path = route_to(y)
	local show = path and #path >= 2 and (rockmech.stockyard_debug.force_show or players_near(sp, SHOW_R)) and core.get_node(sp).name ~= "ignore"
	if not show then
		if buy then close_deal(acc, y, want)
		else tell(acc, why == "empty" and S("A coal trader came by: no coal in the pile")
			or why == "grade" and S("A coal trader came by: too much rock in the pile, no deal") or S("A coal trader came by: too expensive, no deal")) end
		return
	end
	-- 出現的位置：從煤堆沿路往回找，第一個離最近的玩家超過 ACTIVE 的點
	local L = path_len(path)
	local s0 = 0
	for s = L, 0, -2 do
		local x, z = pose_at(path, s)
		if near_dist({x = x, y = sp.y, z = z}, sp) > ACTIVE then s0 = s; break end
	end
	visits[acc] = {path = path, L = L, s = s0, s0 = s0, phase = "wait", wait = s0 / SPEED, buy = buy, why = why, want = want, y = y, sp = sp}
end

-- 路面高度：先在上一步附近找，找不到再整欄找（車剛出現時離煤堆遠，高度可能差很多）
local function ground_at(x, z, near)
	local xi, zi = math.floor(x + 0.5), math.floor(z + 0.5)
	return rockmech.ground_y(xi, zi, near + 6, near - 8) or rockmech.ground_y(xi, zi, near + 60, near - 60) or near
end
local function spawn_truck(v)
	local x, z, yaw = pose_at(v.path, v.s)
	local xi, zi = math.floor(x + 0.5), math.floor(z + 0.5)
	local gy = rockmech.ground_y(xi, zi, v.y.y + 60, v.y.y - 60) or v.y.y
	v.gy = gy
	local obj = core.add_entity({x = x, y = gy + 2.0, z = z}, TRUCK, core.serialize({uid = ("yard-%x"):format(math.random(0, 0xffffff)), yard = true, wall = os.time()}))
	local e = obj and obj:get_luaentity()
	if not e then
		core.log("action", ("[rockmech] 堆置處：買家的車放不出來（%.0f, %.0f, %.0f，obj=%s）"):format(x, gy + 2, z, tostring(obj)))
		return false
	end
	e.yard_live = true
	obj:set_yaw(yaw)
	obj:set_acceleration({x = 0, y = 0, z = 0})
	v.truck = obj
	return true
end
local function drop_visit(acc)
	local v = visits[acc]
	if not v then return end
	if v.truck and v.truck:get_pos() then
		local e = v.truck:get_luaentity()
		if e then V.registry_drop(e.uid); V.snapshot_clear(e.uid) end
		v.truck:remove()
	end
	if v.npc and v.npc:get_pos() then v.npc:remove() end
	visits[acc] = nil
end

local function step_visit(acc, v, dt)
	if v.phase == "wait" then          -- 還在遠處的路上（不放畫面）
		v.wait = v.wait - dt
		if v.wait <= 0 then
			if not spawn_truck(v) then
				drop_visit(acc)
				if v.buy then close_deal(acc, v.y, v.want) end
				return
			end
			v.phase = "in"
		end
	elseif v.phase == "in" or v.phase == "out" then
		if not (v.truck and v.truck:get_pos()) then
			core.log("action", ("[rockmech] 堆置處：買家的車不見了（%s，s = %.0f）"):format(v.phase, v.s))
			if v.phase == "in" and v.buy then close_deal(acc, v.y, v.want) end
			drop_visit(acc); return
		end
		local dir = v.phase == "in" and 1 or -1
		v.s = v.s + dir * SPEED * dt
		local x, z, yaw = pose_at(v.path, math.max(0, math.min(v.L, v.s)))
		v.gy = ground_at(x, z, v.gy or v.y.y)
		v.truck:move_to({x = x, y = v.gy + 2.0, z = z}, true)
		v.truck:set_yaw(dir > 0 and yaw or yaw + math.pi)
		if v.phase == "in" and v.s >= v.L then
			-- 停好：煤商下車
			v.phase, v.t = "talk", 0
			local tp = v.truck:get_pos()
			local fx, fz = -math.sin(v.truck:get_yaw()), math.cos(v.truck:get_yaw())
			local npc = core.add_entity({x = tp.x + fz * 2.2, y = v.gy + 0.5, z = tp.z - fx * 2.2}, BUYER)
			local ne = npc and npc:get_luaentity()
			if ne then ne.live = true; v.npc = npc end
		elseif v.phase == "out" and (v.s <= v.s0 or near_dist(v.truck:get_pos(), v.sp) > ACTIVE) then
			drop_visit(acc)
		end
	elseif v.phase == "talk" then
		v.t = v.t + dt
		local function line(k, text) if not v["said" .. k] and v.t >= k then v["said" .. k] = true; say_near(v.npc, text) end end
		local talk = v.why == "empty" and EMPTY_LINES or LINES
		line(1, talk[math.random(#talk)])
		if v.buy then
			line(6, S("I'll take some. Loading now."))
			-- 6–14 秒：裝車（煤堆變小、車斗滿起來），14 秒成交
			if v.t >= 6 and not v.loaded then
				local e = v.truck and v.truck:get_luaentity()
				if e then
					local k = math.min(1, (v.t - 6) / 8)
					local lv = math.floor(k * V.TYPES[e.vkind].cap * math.min(1, v.want / tons_of(V.TYPES[e.vkind].cap)) + 0.5)
					e.load, e.loadq = {[rockmech.RUBBLE] = lv}, {[rockmech.RUBBLE] = lv * 120}
					V.refresh(e)
				end
				if v.t >= 14 then v.loaded = true; close_deal(acc, v.y, v.want) end
			end
			line(15, S("See you next time."))
			if v.t >= 17 then
				if v.npc and v.npc:get_pos() then v.npc:remove() end
				v.phase = "out"
			end
		else
			line(6, v.why == "empty" and S("No coal. I'll come back another day.")
				or v.why == "grade" and S("Too much rock in this pile. Not today.") or S("At that price? Not today."))
			if v.t >= 10 then
				if v.npc and v.npc:get_pos() then v.npc:remove() end
				v.phase = "out"
			end
		end
	end
end

-- 每秒：排下一位買家；每 0.1 秒：畫面
local function next_gap() return -math.log(1 - math.random()) * cfg.stockyard_interval end
local tick = 0
core.register_globalstep(function(dtime)
	tick = tick + dtime
	if tick < 1 then return end
	tick = 0
	local now = core.get_gametime()
	for acc, y in pairs(all_yards()) do
		if not visits[acc] then
			if not y.next_t then y.next_t = now + next_gap(); set_yard(acc, y)
			elseif now >= y.next_t then
				y.next_t = now + next_gap()
				set_yard(acc, y)
				if daytime() and not y.closed then start_visit(acc, y) end   -- 關閉了就不來；沒煤也會來（看一看就走）
			end
		end
	end
end)
local vt = 0
core.register_globalstep(function(dtime)
	vt = vt + dtime
	if vt < 0.1 then return end
	local dt = vt
	vt = 0
	for acc, v in pairs(visits) do step_visit(acc, v, dt) end
end)

---------------------------------------------------------------------------
-- 視窗：煤堆、售價、範圍大小、最近的成交
---------------------------------------------------------------------------

local open_for = {}
local function form(name, acc)
	local y = yard_of(acc)
	if not y then return nil end
	local tot, coal_rock, coal = stats(y)
	local market = rockmech.ore_price(cfg.main_ore)
	local out = {"formspec_version[6]size[11,9.2]", ("label[0.5,0.6;%s]"):format(F(S("Stockyard  @1 × @2 m", y.size, y.size)))}
	out[#out + 1] = ("label[0.5,1.3;%s]"):format(F(S("Pile @1, coal-bearing @2, pure coal @3", t1(tot), t1(coal_rock), t1(coal))))
	out[#out + 1] = ("label[0.5,1.8;%s]"):format(F(S("Market price $@1/t, traders' price about $@2/t", ("%.0f"):format(market), ("%.0f"):format(market * cfg.stockyard_ref))))
	out[#out + 1] = ("label[0.5,2.6;%s]"):format(F(S("Your price ($ per t of coal)")))
	out[#out + 1] = ("field[5,2.25;2.5,0.7;ask;;%d]"):format(y.ask or 0)
	out[#out + 1] = ("button[7.7,2.25;2.8,0.7;set;%s]"):format(F(S("Set price")))
	out[#out + 1] = ("label[0.5,3.5;%s]"):format(F(S("Size")))
	local items, sel = {}, 2
	for i, s in ipairs(SIZES) do items[i] = s .. " × " .. s; if s == y.size then sel = i end end
	out[#out + 1] = ("dropdown[2,3.15;2.5,0.7;size;%s;%d;true]"):format(table.concat(items, ","), sel)
	out[#out + 1] = ("button[7.7,3.15;2.8,0.7;toggle;%s]"):format(F(y.closed and S("Reopen") or S("Close")))
	if y.closed then out[#out + 1] = ("label[5,3.5;%s]"):format(F(S("Closed"))) end
	out[#out + 1] = ("label[0.5,4.5;%s]"):format(F(S("Recent sales")))
	local yy = 5
	for _, s in ipairs(y.sales or {}) do
		out[#out + 1] = ("label[0.8,%g;%s]"):format(yy, F(S("@1 (@2 of coal) at $@3/t: @4", t1(s.tons), t1(s.coal), ("%.0f"):format(s.ask or 0), money_text(s.pay))))
		yy = yy + 0.45
	end
	if not y.sales or #y.sales == 0 then out[#out + 1] = ("label[0.8,5;%s]"):format(F(S("None yet"))) end
	return table.concat(out)
end
function rockmech.yard_form(player, acc)
	local name = player:get_player_name()
	if acc == "" or not acc then acc = rockmech.account_of(name) end
	local f = form(name, acc)
	if not f then return end
	open_for[name] = acc
	core.show_formspec(name, FORM, f)
end
core.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= FORM then return end
	local name = player:get_player_name()
	local acc = open_for[name]
	if fields.quit then open_for[name] = nil; return true end
	if not acc then return true end
	if rockmech.account_of(name) ~= acc and not core.check_player_privs(name, {server = true}) then return true end
	local y = yard_of(acc)
	if not y then return true end
	if (fields.set or fields.key_enter_field == "ask") and tonumber(fields.ask) then
		y.ask = math.max(0, math.floor(tonumber(fields.ask) + 0.5))
		set_yard(acc, y)
		rockmech.notify(name, S("[Stockyard] Price set to $@1/t", y.ask))
	end
	if fields.toggle then
		y.closed = not y.closed or nil
		set_yard(acc, y)
		rockmech.notify(name, y.closed and S("[Stockyard] Closed: no traders will come") or S("[Stockyard] Open again"))
	end
	if fields.size then
		local s = SIZES[tonumber(fields.size) or 0]
		if s and s ~= y.size then
			local old = y.size
			y.size = s
			if touches_road(y) then set_yard(acc, y)
			else
				y.size = old
				rockmech.notify(name, S("[Stockyard] The stockyard must touch a road, so the buyers' trucks can reach it"))
			end
		end
	end
	core.show_formspec(name, FORM, form(name, acc))
	return true
end)

-- 測試用：不經告示牌直接劃一處
local function make(acc, pos, dx, dz, size, ask)
	local y = {x = pos.x, y = pos.y, z = pos.z, dx = dx, dz = dz, size = size, ask = ask, sales = {}}
	if not touches_road(y) then return nil end
	core.set_node(pos, {name = SIGN, param2 = core.dir_to_facedir({x = -dx, y = 0, z = -dz})})
	core.get_meta(pos):set_string("owner", acc)
	set_yard(acc, y)
	return y
end
rockmech.stockyard_debug = {make = make, set_yard = set_yard, yard_of = yard_of, stats = stats, take = take, route_to = route_to, start_visit = start_visit, visits = visits,
	touches_road = touches_road, roads = roads}
