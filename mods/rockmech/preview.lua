-- rockmech/preview.lua
-- 放置預覽：手上拿著車輛、破碎站、選礦場時，在準星指到的地方把放下去會佔的地面格子一格一格標出來。
--   車輛：車身（車頭到車尾、車寬）蓋到的格子，跟著面向轉（放下去車頭朝向跟你的面向一樣）。
--   破碎站：機身 3×3 格，加上朝你這邊挖的受料倉 9×9 格；選礦場再加左右兩座塔。地不平時格子變紅色。
-- 每格是一片薄板，貼在那一欄地面（或碎石面）上方 LIFT：不跟地面的貼圖重疊（重疊會閃）。
-- 框只有拿東西的人自己看得到（set_observers）；指的位置、面向沒變就不重畫。

local V = rockmech.vehicles
local H = rockmech.hopper_lib
local NLEV = V.NLEV
local PREVIEW = "rockmech:preview"
local RANGE = 6             -- 準星往前找幾公尺（跟手的放置距離差不多）
local STEP = 0.15           -- 多久檢查一次 (s)
local LIFT = 0.03           -- 薄板離地面多高 (m)
local THICK = 0.01

local function tex(color)
	local t = "[fill:16x16:" .. color .. "^[fill:16x1:0,0:#ffffffd0^[fill:1x16:0,0:#ffffffd0^[fill:16x1:0,15:#ffffffd0^[fill:1x16:15,0:#ffffffd0"
	return {t, t, t, t, t, t}
end
local OK, BAD = tex("#40ff6060"), tex("#ff404070")

core.register_entity(PREVIEW, {
	initial_properties = {
		visual = "cube", visual_size = {x = 0.98, y = THICK, z = 0.98}, textures = OK,
		use_texture_alpha = true, backface_culling = false,
		physical = false, collide_with_objects = false, pointable = false, static_save = false,
		glow = 10, shaded = false,
	},
	on_activate = function(self) self.object:set_armor_groups({immortal = 1}) end,
})

local tiles = {}            -- 玩家名稱 → {entity, …}
local last = {}             -- 玩家名稱 → 上次畫的內容（沒變就不重畫）

local function clear(name)
	for _, o in ipairs(tiles[name] or {}) do if o:get_pos() then o:remove() end end
	tiles[name], last[name] = nil, nil
end

-- (x, z) 這一欄、從 y 往下找的地表高度（方塊頂面；不滿格的碎石用碎石頂面）
local function surface(x, y, z)
	for yy = y, y - 4, -1 do
		local n = core.get_node({x = x, y = yy, z = z}).name
		if n ~= "ignore" and not V.passable(n) then
			local k = rockmech.rubble_level[n]
			return yy - 0.5 + (k and k / NLEV or 1)
		end
		local k = rockmech.rubble_level[n]
		if k then return yy - 0.5 + k / NLEV end
	end
	return y - 0.5
end

-- 畫一組格子：cells = {{x, z}, …}，y0 = 從哪個高度往下找地面，ok 決定顏色
local function draw(name, cells, y0, ok)
	local list = tiles[name] or {}
	tiles[name] = list
	for i, c in ipairs(cells) do
		local p = {x = c[1], y = surface(c[1], y0, c[2]) + LIFT, z = c[2]}
		local o = list[i]
		if not (o and o:get_pos()) then
			o = core.add_entity(p, PREVIEW)
			list[i] = o
			if o and o.set_observers then o:set_observers({[name] = true}) end
		end
		if o then
			o:set_pos(p)
			o:set_properties({textures = ok and OK or BAD})
		end
	end
	for i = #list, #cells + 1, -1 do
		if list[i] and list[i]:get_pos() then list[i]:remove() end
		list[i] = nil
	end
end

-- 準星指到的方塊（跟放東西時一樣的 pointed_thing）
local function pointed_node(player)
	local eye = vector.add(player:get_pos(), {x = 0, y = player:get_properties().eye_height or 1.625, z = 0})
	eye = vector.add(eye, vector.divide(player:get_eye_offset(), 10))
	local to = vector.add(eye, vector.multiply(player:get_look_dir(), RANGE))
	for pt in core.raycast(eye, to, false, false) do
		if pt.type == "node" then return pt end
	end
end

-- 破碎站、選礦場：受料倉朝玩家這邊（跟 on_place 一樣）
local function hopper_dir(player)
	local look = player:get_look_dir()
	if math.abs(look.x) > math.abs(look.z) then return look.x > 0 and -1 or 1, 0 end
	return 0, look.z > 0 and -1 or 1
end

local function square(cells, cx, cz, r)
	for x = cx - r, cx + r do for z = cz - r, cz + r do cells[#cells + 1] = {x, z} end end
end

-- 車輛：車身中心（跟 on_place 一樣）、車頭方向 yaw；格子中心落在車頭 half、車尾 rear、半寬 w/2 的長方形裡就算
local function vehicle_cells(def, a, yaw)
	local off = ((def.half * 2) % 2 == 1) and 0 or 0.5
	local cx, cz = a.x + off, a.z + off
	local front, back = def.half, def.rear or def.half
	local hw = 0.5
	for _, l in ipairs(def.lat or {0}) do hw = math.max(hw, math.abs(l) + 0.5) end
	local dir = core.yaw_to_dir(yaw)
	local px, pz = dir.z, -dir.x            -- 橫向
	local R = math.ceil(math.max(front, back, hw)) + 1
	local cells = {}
	for x = math.floor(cx) - R, math.ceil(cx) + R do
		for z = math.floor(cz) - R, math.ceil(cz) + R do
			local dx, dz = x - cx, z - cz
			local along, side = dx * dir.x + dz * dir.z, dx * px + dz * pz
			if along <= front - 0.01 and along >= -back + 0.01 and math.abs(side) <= hw - 0.01 then cells[#cells + 1] = {x, z} end
		end
	end
	return cells
end

local t = 0
core.register_globalstep(function(dtime)
	t = t + dtime
	if t < STEP then return end
	t = 0
	for _, player in ipairs(core.get_connected_players()) do
		local name = player:get_player_name()
		local item = player:get_wielded_item():get_name()
		local order = rockmech.order_target and rockmech.order_target(item)   -- 施工單（delivery.lua）照原本的設施畫
		if order then item = order end
		local ent = item:sub(-5) == "_item" and core.registered_entities[item:sub(1, -6)]
		local vdef = ent and ent.vkind and V.TYPES[ent.vkind]
		local is_crusher, is_plant = item == "rockmech:crusher" or item == "rockmech:crusher_big", item == "rockmech:plant" and rockmech.plant_site_ok
		local pt = (vdef or is_crusher or is_plant) and not player:get_attach() and pointed_node(player)
		if not pt then
			if tiles[name] then clear(name) end
		else
			local a = pt.above
			local key, yaw, dx, dz
			if vdef then
				yaw = player:get_look_horizontal() + (vdef.pushed and math.pi or 0)
				key = ("%s|%d,%d,%d|%.2f"):format(item, a.x, a.y, a.z, yaw)
			else
				dx, dz = hopper_dir(player)
				key = ("%s|%d,%d,%d|%d,%d"):format(item, a.x, a.y, a.z, dx, dz)
			end
			if key ~= last[name] then
				last[name] = key
				if vdef then
					local cells = vehicle_cells(vdef, a, yaw)
					draw(name, cells, a.y, not (rockmech.cells_blocked and rockmech.cells_blocked(cells, a.y, a.y + 2 * vdef.half)))
				else
					-- 機身、受料倉（選礦場再加兩座塔）；地不平，或範圍裡有人、有車（delivery.lua）就標紅色
					local cells = rockmech.facility_cells(item, a, dx, dz)
					local ok = is_plant and rockmech.plant_site_ok(a, dx, dz) or (not is_plant and H.site_ok(a, dx, dz))
					if ok and rockmech.cells_blocked(cells, a.y - 1, a.y + 4) then ok = false end
					draw(name, cells, a.y, ok)
				end
			end
		end
	end
end)

core.register_on_leaveplayer(function(player) clear(player:get_player_name()) end)
