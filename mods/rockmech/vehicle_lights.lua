-- rockmech/vehicle_lights.lua
-- 車燈：車上有人（駕駛、乘客、怪手操作員）而且天色暗（晚上、坑道裡照不到太陽）時，車頭前方照亮。
--   天色用自然光判斷（core.get_natural_light：太陽光，不含燈光），不會因為自己的燈亮了就以為天亮而關掉。
-- Luanti 的物件本身不會發光，所以在車頭前方的空氣格放看不見的光源方塊（LIGHT），車子動了就搬、熄火就收：
--   近燈：車頭前 NEAR m（亮度 13）；遠燈：再往前 FAR m（亮度 11）；大車（車身長）照得比較遠。
--   只放在空氣格（從車底高度往上找 3 格）；碎石流過、掉下來就壓掉（group rubble_breaks，見 collapse.lua）。
--   光源方塊有計時器，沒被續期就自己消失（車子卸載、伺服器當掉也不會留在地圖上）；重開時清掉殘留的

local V = rockmech.vehicles
local LIGHT = "rockmech:vehicle_light"
local NEAR, FAR = 3, 8
local STEP = 0.25           -- 每幾秒更新一次
local TTL = 1.0             -- 光源方塊沒續期多久就消失 (s)

core.register_node(LIGHT, {
	description = "Vehicle light",
	drawtype = "airlike", paramtype = "light", sunlight_propagates = true,
	walkable = false, pointable = false, diggable = false, buildable_to = true, floodable = true,
	light_source = 13, drop = "",
	groups = {not_in_creative_inventory = 1, rubble_breaks = 1},
	on_timer = function(pos) core.remove_node(pos) end,
})
core.register_node(LIGHT .. "_dim", {
	description = "Vehicle light",
	drawtype = "airlike", paramtype = "light", sunlight_propagates = true,
	walkable = false, pointable = false, diggable = false, buildable_to = true, floodable = true,
	light_source = 11, drop = "",
	groups = {not_in_creative_inventory = 1, rubble_breaks = 1},
	on_timer = function(pos) core.remove_node(pos) end,
})
core.register_lbm({
	label = "rockmech: 清掉殘留的車燈",
	name = "rockmech:vehicle_light_cleanup",
	nodenames = {LIGHT, LIGHT .. "_dim"},
	run_at_every_load = true,
	action = function(pos) core.remove_node(pos) end,
})

local DARK = 10             -- 自然光低於這個就開燈（白天露天約 15，黃昏、坑道口以下）
-- 車上有人：駕駛、乘客、怪手操作員（無人駕駛的空車不開）
local function occupied(self)
	return self.driver ~= nil or (self.pass and next(self.pass) ~= nil) or (self.op and self.op.on) or false
end
local function dark(pos)
	local p = {x = math.floor(pos.x + 0.5), y = math.floor(pos.y + 0.5) + 2, z = math.floor(pos.z + 0.5)}
	local l = core.get_natural_light(p)
	return l == nil or l < DARK
end
rockmech.vehicle_light_on = function(self, pos) return occupied(self) and dark(pos) end      -- 測試可以換掉
-- 從 p 往上找 3 格內第一個空氣格（或已經是車燈的格）
local function air_at(p)
	for dy = 0, 2 do
		local q = {x = math.floor(p.x + 0.5), y = math.floor(p.y + 0.5) + dy, z = math.floor(p.z + 0.5)}
		local n = core.get_node_or_nil(q)
		if not n then return nil end
		if n.name == "air" or n.name == LIGHT or n.name == LIGHT .. "_dim" then return q end
	end
end
local function put(q, name)
	local n = core.get_node(q)
	if n.name ~= name then core.set_node(q, {name = name}) end
	core.get_node_timer(q):start(TTL)
end

-- 每台車放的燈記在 lit[uid]：不亮了、換位置了、車子卸載或收起來了就把舊的收掉（計時器只是保險）
local lit = {}
local function clear(uid, keep)
	for _, q in ipairs(lit[uid] or {}) do
		local k = core.hash_node_position(q)
		if not (keep and keep[k]) then
			local n = core.get_node_or_nil(q)
			if n and (n.name == LIGHT or n.name == LIGHT .. "_dim") then core.remove_node(q) end
		end
	end
	lit[uid] = nil
end
local t = 0
core.register_globalstep(function(dtime)
	t = t + dtime
	if t < STEP then return end
	t = 0
	for _, self in pairs(V.by_uid) do
		local obj = self.object
		local pos = obj and obj:get_pos()
		if pos and rockmech.vehicle_light_on(self, pos) then
			local def = V.TYPES[self.vkind] or {}
			local half = def.half or 1.5
			local dir = core.yaw_to_dir(obj:get_yaw() or 0)
			local base = {x = pos.x, y = pos.y + 0.5, z = pos.z}
			local reach = half + NEAR
			local far = reach + FAR + half * 0.5
			local q1 = air_at(vector.add(base, vector.multiply(dir, reach)))
			local q2 = air_at(vector.add(base, vector.multiply(dir, far)))
			local now, keep = {}, {}
			if q1 then put(q1, LIGHT); now[#now + 1] = q1; keep[core.hash_node_position(q1)] = true end
			if q2 then put(q2, LIGHT .. "_dim"); now[#now + 1] = q2; keep[core.hash_node_position(q2)] = true end
			clear(self.uid, keep)
			lit[self.uid] = now
		elseif lit[self.uid] then
			clear(self.uid)
		end
	end
	for uid in pairs(lit) do
		if not V.by_uid[uid] then clear(uid) end
	end
end)
