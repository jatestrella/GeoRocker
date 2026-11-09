-- rockmech/delivery.lua
-- 大東西不進背包（人身上只放小東西）：
--   車輛：買了就停在自己營地東南邊的交車區（營地中心往東 YARD.x1..x2、z = YARD.z1..z2），要自己開去工地。
--     兩排：北排車頭朝北、南排車頭朝南，車頭都貼著交車區的邊，前面是空地；左右隔 1 m。
--     一台一個車位：找得到空車位（車身加左右 1 m 沒有車、人，地平、上面沒有碎石）就交車，停滿了才跳警示。
--   設施（破碎站、大型破碎站、選礦場、輸送帶、置物箱）：買了拿到「施工單」（一張紙），拿著對地面按右鍵，照原本的放置規則在那裡施工。
--     施工前先檢查施工範圍（機身、受料倉、塔）裡有沒有人或車：有就不施工（人會掉進挖開的倉裡）。
--     放置預覽（preview.lua）跟著施工單走，範圍內有人或車也標紅色。
-- 障礙物偵測給預覽共用：rockmech.cells_blocked(cells, y0, y1, except)；放東西的人自己不算，
-- 施工完人站在受料倉範圍裡就移到倉外。

local V = rockmech.vehicles
local cfg = rockmech.cfg
local H = rockmech.hopper_lib
local S = rockmech.S

local YARD = {x1 = 10, x2 = 36, z1 = -36, z2 = -54}   -- 交車區（相對營地中心 x0；z 是絕對座標，營地中心在 z = 0）：研究帳篷、講堂（z −31..−24）南邊，看板（z −48，x0−4..x0+3）東邊

---------------------------------------------------------------------------
-- 障礙物偵測
---------------------------------------------------------------------------

-- 車身蓋到的格子：中心 (cx, cz)、車頭朝 yaw；回傳 {{x, z}, ...}（preview.lua 也用）
local function body_cells(def, cx, cz, yaw)
	local front, back = def.half, def.rear or def.half
	local hw = 0.5
	for _, l in ipairs(def.lat or {0}) do hw = math.max(hw, math.abs(l) + 0.5) end
	local dir = core.yaw_to_dir(yaw)
	local px, pz = dir.z, -dir.x
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
rockmech.vehicle_body_cells = body_cells

-- 這些格子（y0..y1 之間）有沒有人或車：回傳說明（"人"／"卡車"…）或 nil。except：不算的那個玩家（放東西的人自己）
function rockmech.cells_blocked(cells, y0, y1, except)
	local skip = except and except.is_player and except:is_player() and except:get_player_name()
	if #cells == 0 then return nil end
	local set, x1, x2, z1, z2 = {}, math.huge, -math.huge, math.huge, -math.huge
	for _, c in ipairs(cells) do
		set[c[1] .. "," .. c[2]] = true
		x1, x2, z1, z2 = math.min(x1, c[1]), math.max(x2, c[1]), math.min(z1, c[2]), math.max(z2, c[2])
	end
	local function hit(x, z) return set[math.floor(x + 0.5) .. "," .. math.floor(z + 0.5)] end
	-- 車身最長大約 8 m：中心在範圍外 8 m 內的車也要看車身蓋不蓋到
	for _, o in ipairs(core.get_objects_in_area({x = x1 - 8, y = y0 - 4, z = z1 - 8}, {x = x2 + 8, y = y1 + 4, z = z2 + 8})) do
		local p = o:get_pos()
		if o:is_player() then
			if o:get_player_name() ~= skip and p.y >= y0 - 2 and p.y <= y1 and hit(p.x, p.z) then return S("a person") end
		else
			local e = o:get_luaentity()
			local def = e and e.vkind and V.TYPES[e.vkind]
			if def then
				for _, c in ipairs(body_cells(def, p.x, p.z, o:get_yaw())) do
					if set[c[1] .. "," .. c[2]] then return def.short or def.desc end      -- 翻譯過的名稱不能再 match 切字
				end
			end
		end
	end
	return nil
end

---------------------------------------------------------------------------
-- 交車區
---------------------------------------------------------------------------

local function ground_y(x, z, from)
	for y = from + 8, from - 8, -1 do
		local n = core.get_node({x = x, y = y, z = z}).name
		if n == "ignore" then return nil end
		if not V.passable(n) then return y end
	end
end

-- 營地中心 x0 的交車區裡，第一個放得下 kind 的位置：回傳 車身中心（跟手放的高度一樣）或 nil、原因
local function find_slot(x0, kind)
	local def = V.TYPES[kind]
	-- 交車區不一定有人在附近：先從資料庫讀進來，再從中央往下找地面當基準
	core.load_area({x = x0 + YARD.x1, y = -40, z = YARD.z2}, {x = x0 + YARD.x2, y = 60, z = YARD.z1})
	local mx, mz = x0 + math.floor((YARD.x1 + YARD.x2) / 2), math.floor((YARD.z1 + YARD.z2) / 2)
	local base
	for y = 60, -40, -1 do
		local n = core.get_node({x = mx, y = y, z = mz}).name
		if n ~= "ignore" and not V.passable(n) then base = y; break end
	end
	if not base then return nil, S("The delivery yard is not loaded yet") end
	local off = ((def.half * 2) % 2 == 1) and 0 or 0.5
	local height = def.half + (def.top or def.half)
	local why = S("The delivery yard has no free space")
	-- 兩排：北排車頭朝北、車頭貼著交車區北緣；南排車頭朝南、貼著南緣。每台車前面都是空地，直接開得出去；
	-- 左右跟別的車至少隔 GAP m（從西往東找）
	local GAP = 1
	local rows = {{yaw = 0, z0 = YARD.z1, step = -1}, {yaw = math.pi, z0 = YARD.z2, step = 1}}
	for _, r in ipairs(rows) do
		for ix = x0 + YARD.x1 + 1, x0 + YARD.x2 - 1 do
			-- 這一欄：從交車區邊緣往內，第一個整台車都在交車區裡的位置
			for iz = r.z0, r.z0 + r.step * 12, r.step do
				local cx, cz = ix + off, iz + off
				local cells = body_cells(def, cx, cz, r.yaw)
				local inside = true
				for _, c in ipairs(cells) do
					if c[1] < x0 + YARD.x1 or c[1] > x0 + YARD.x2 or c[2] > YARD.z1 or c[2] < YARD.z2 then inside = false; break end
				end
				if inside then
					local gy, ok = nil, true
					for _, c in ipairs(cells) do
						local g = ground_y(c[1], c[2], base)
						if not g or (gy and g ~= gy) then ok = false; break end     -- 地要平
						gy = g
						for y = g + 1, g + math.ceil(height) + 1 do
							if not V.passable(core.get_node({x = c[1], y = y, z = c[2]}).name) then ok = false; break end
						end
						if not ok then break end
					end
					if ok and gy then
						local wide = {}
						for _, c in ipairs(cells) do
							for d = -GAP, GAP do wide[#wide + 1] = {c[1] + d, c[2]} end
						end
						local who = rockmech.cells_blocked(wide, gy + 1, gy + 1 + height)
						if not who then return {x = cx, y = gy + 0.5 + def.half, z = cz}, nil, r.yaw end
						why = S("The delivery yard is full (@1 is in the way)", who)
					end
					break
				end
			end
		end
	end
	return nil, why
end

-- 交車區裡有沒有東西擋著：回傳是什麼（車名、人、地上的東西），淨空回傳 nil
function rockmech.yard_obstacle(x0)
	core.load_area({x = x0 + YARD.x1, y = -40, z = YARD.z2}, {x = x0 + YARD.x2, y = 60, z = YARD.z1})
	local mx, mz = x0 + math.floor((YARD.x1 + YARD.x2) / 2), math.floor((YARD.z1 + YARD.z2) / 2)
	local base
	for y = 60, -40, -1 do
		local n = core.get_node({x = mx, y = y, z = mz}).name
		if n ~= "ignore" and not V.passable(n) then base = y; break end
	end
	if not base then return nil end
	local cells = {}
	for x = x0 + YARD.x1, x0 + YARD.x2 do
		for z = YARD.z2, YARD.z1 do
			cells[#cells + 1] = {x, z}
			for y = base + 1, base + 3 do
				local n = core.get_node({x = x, y = y, z = z}).name
				if n ~= "ignore" and not V.passable(n) then
					local d = core.registered_nodes[n]
					return rockmech.rubble_level[n] and S("rubble") or (d and d.description ~= "" and d.description:match("^[^\n]*")) or n
				end
			end
		end
	end
	return rockmech.cells_blocked(cells, base + 1, base + 5)
end

local function camp_x(name)
	local t = rockmech.team_of and rockmech.team_of(name)
	if t and rockmech.team_site_x then return rockmech.team_site_x(t) end
	return cfg.career_camp_dx
end

-- 商店（career.lua）買車：先找交車區的位置，找得到才收錢。回傳 是否成功, 訊息
function rockmech.deliver_vehicle(name, kind)
	local def = V.TYPES[kind]
	if not def then return false, S("No such vehicle") end
	local x0 = camp_x(name)
	-- 找空車位（別的車、人、碎石佔著的位置跳過），沒有空位才不交車
	local pos, why, yaw = find_slot(x0, kind)
	if not pos then return false, S("@1: drive the vehicles out of the delivery yard first", why), true end
	local obj = core.add_entity(pos, "rockmech:" .. kind)
	if not obj then return false, S("Delivery failed (that area is not loaded yet)") end
	obj:set_yaw(yaw)
	local e = obj:get_luaentity()
	if e then V.set_owner(e, rockmech.account_of(name)) end
	core.log("action", ("[rockmech] delivered %s to %s at %s"):format(kind, name, core.pos_to_string(vector.round(pos))))
	local vname, px, pz = def.short or def.desc, ("%d"):format(math.floor(pos.x + 0.5)), ("%d"):format(math.floor(pos.z + 0.5))
	if yaw == 0 then return true, S("@1 is parked in the delivery yard southeast of the camp (@2, @3), facing north", vname, px, pz) end
	return true, S("@1 is parked in the delivery yard southeast of the camp (@2, @3), facing south", vname, px, pz)
end

-- 是不是交車的車（商店不給物品）：rockmech:<kind>_item 而且 kind 是車
function rockmech.vehicle_kind_of_item(item)
	local kind = item:match("^rockmech:(.+)_item$")
	return kind and V.TYPES[kind] and kind or nil
end

---------------------------------------------------------------------------
-- 施工單
---------------------------------------------------------------------------

-- 施工單的圖示：建築物的圖示，右下角疊一張小施工單（devtools/make_icons.py）
local BADGE = "rockmech_order_badge.png"
local ORDERS = {      -- 施工單 → 原本的物品、標籤顏色、名稱、有沒有受料倉（要檢查施工範圍）
	{order = "rockmech:order_crusher", item = "rockmech:crusher", color = "#b08a20", label = S("Crusher"), hopper = true},
	{order = "rockmech:order_crusher_big", item = "rockmech:crusher_big", color = "#4a5058", label = S("Large crusher"), hopper = true},
	{order = "rockmech:order_plant", item = "rockmech:plant", color = "#3a7ab0", label = S("Pre-sorting plant"), hopper = true, plant = true},
	{order = "rockmech:order_belt", item = "rockmech:belt", color = "#262626", label = S("Conveyor belt"),
		how = S("same as a conveyor belt: point at a belt to extend it, point at the ground to start on the ground")},
	{order = "rockmech:order_locker", item = "rockmech:locker", color = "#6a7078", label = S("Locker"), how = S("placed where you point")},
	{order = "rockmech:order_loadout", item = "rockmech:loadout", color = "#8a8e92", label = S("Loadout bin"),
		how = S("3×3 m flat ground, 6 m clear above; the discharge arm faces you, the grating on top takes a conveyor belt")},
}
local by_order, by_item = {}, {}
for _, o in ipairs(ORDERS) do by_order[o.order], by_item[o.item] = o, o end
function rockmech.order_target(name) local o = by_order[name]; return o and o.item end
function rockmech.order_of_item(item) local o = by_item[item]; return o and o.order end

-- 受料倉朝玩家這邊（跟破碎站的 on_place 一樣）
local function hopper_dir(player)
	local look = player:get_look_dir()
	if math.abs(look.x) > math.abs(look.z) then return look.x > 0 and -1 or 1, 0 end
	return 0, look.z > 0 and -1 or 1
end
local function square(cells, cx, cz, r)
	for x = cx - r, cx + r do for z = cz - r, cz + r do cells[#cells + 1] = {x, z} end end
end
-- 破碎站、選礦場的施工範圍（機身、受料倉、塔）；preview.lua 也用
function rockmech.facility_cells(item, a, dx, dz)
	local cells = {}
	square(cells, a.x, a.z, 1)
	local half = ((H.size_for and H.size_for(item) or H.SIZE) - 1) / 2
	square(cells, a.x + dx * (2 + half), a.z + dz * (2 + half), half)
	if item == "rockmech:plant" and rockmech.plant_towers then
		for _, tc in ipairs((rockmech.plant_towers(a, dx, dz))) do square(cells, tc.x, tc.z, 1) end
	end
	return cells
end

for _, o in ipairs(ORDERS) do
	local orig = core.registered_items[o.item]
	local how = o.hopper and S("the hopper is dug on your side; check the preview frame on the ground first") or o.how
	local desc = o.item == "rockmech:belt"
		and S("@1 work order\nHold it and right-click the ground to build there (@2)\nLeft-click a conveyor belt to take that section back (added to the work order); click elsewhere to change the slope", o.label, how)
		or S("@1 work order\nHold it and right-click the ground to build there (@2)", o.label, how)
	core.register_craftitem(o.order, {
		description = desc,
		short_description = S("@1 work order", o.label),
		inventory_image = (orig and orig.inventory_image ~= "" and orig.inventory_image or "rockmech_icon_crusher.png") .. "^" .. BADGE,
		stack_max = o.item == "rockmech:belt" and 99 or 1,
		on_place = function(itemstack, placer, pointed)
			if pointed.type ~= "node" or not placer or not orig then return itemstack end
			local name = placer:get_player_name()
			if o.hopper then
				local dx, dz = hopper_dir(placer)
				local a = pointed.above
				local cells = rockmech.facility_cells(o.item, a, dx, dz)
				local who = rockmech.cells_blocked(cells, a.y - 1, a.y + 4, placer)
				if who then
					rockmech.notify(name, S("[Construction] There is @1 in the construction area: move it away first", who))
					return itemstack
				end
				local tmp = ItemStack(o.item)
				local res = orig.on_place(tmp, placer, pointed)
				if core.get_node(a).name ~= o.item then return itemstack end      -- 沒蓋成（地不平…，原本的訊息已經講了）
				if not core.is_creative_enabled(name) and res and res:get_count() == 0 then itemstack:take_item() end
				-- 自己站在施工範圍裡：移到受料倉外（倉朝自己這邊挖，不移會掉進去）
				local pp = placer:get_pos()
				local px, pz = math.floor(pp.x + 0.5), math.floor(pp.z + 0.5)
				for _, c in ipairs(cells) do
					if c[1] == px and c[2] == pz then
						local far = 2 + H.SIZE + 1
						local q = {x = a.x + dx * far + (dx == 0 and (pp.x - a.x) or 0), y = a.y + 2, z = a.z + dz * far + (dz == 0 and (pp.z - a.z) or 0)}
						for y = a.y + 6, a.y - 6, -1 do
							local nd = core.registered_nodes[core.get_node({x = math.floor(q.x + 0.5), y = y, z = math.floor(q.z + 0.5)}).name]
							if nd and nd.walkable then q.y = y + 0.5; break end
						end
						placer:set_pos(q)
						rockmech.notify(name, S("[Construction] You were standing where the hopper goes, so you were moved outside it"))
						break
					end
				end
				return itemstack
			end
			local tmp = ItemStack(o.item)
			tmp:get_meta():set_int("slope", itemstack:get_meta():get_int("slope"))
			local res = orig.on_place(tmp, placer, pointed)
			if not core.is_creative_enabled(name) and res and res:get_count() == 0 then itemstack:take_item() end
			return itemstack
		end,
		on_use = o.item == "rockmech:belt" and function(itemstack, user, pointed)
			if not orig.on_use then return end
			local tmp = ItemStack(o.item)
			local slope = itemstack:get_meta():get_int("slope")
			if slope ~= 0 then tmp:get_meta():set_int("slope", slope) end
			-- 收回的輸送帶可能加在 tmp 上，也可能（坡度設定不同、疊不起來）進物品欄：都算回施工單
			local inv = user:get_inventory()
			local function belts()
				local n = 0
				for _, s in ipairs(inv:get_list("main") or {}) do if s:get_name() == o.item then n = n + s:get_count() end end
				return n
			end
			local before = belts()
			local res = orig.on_use(tmp, user, pointed) or tmp
			local got = belts() - before
			if got > 0 then inv:remove_item("main", ItemStack(o.item .. " " .. got)) end
			got = got + math.max(0, res:get_count() - 1)
			if got > 0 then itemstack:set_count(math.min(99, itemstack:get_count() + got)) end
			local m = itemstack:get_meta()
			m:set_int("slope", res:get_meta():get_int("slope"))
			local d = res:get_meta():get_string("description")
			if d ~= "" then m:set_string("description", S("@1 work order   @2", o.label, d)) end
			return itemstack
		end or nil,
	})
end
