-- rockmech/vehicle_lowboy.lua
-- 拖車：牽引車＋平板，載慢的機具，或把報廢的車拖回來。由 vehicles.lua 載入。兩種：
--   平板拖車（lowboy）：60 t，怪手、推土機、鑽機這類
--   重型拖車（heavyhaul）：多軸線模組化平板，150 t，礦用挖土機、礦卡（真實的大型礦用機具也是這樣運，或自己開、拆開運）
--   E：把平板旁邊 LOAD_R m 內、自己組（或沒有組）的車拉上來（有人在開的不行），可以載好幾台：
--      總重不超過 MAX_T t、平板排得下（從前端往後排）。空白鍵：卸下最後載上去的那一台，卸在車尾後方。拖車不能載拖車。
--   直線加速：空車到 top_speed，載車時上限 LOADED_SPEED、加速度減半。載的車掛在平板上（附著），拖車存檔時記著它的編號，
--   區塊重新載入後自己再掛回去。

local V = rockmech.vehicles
local S = rockmech.S
local box_tex = V.box_tex
local WHEEL, TREAD = V.WHEEL, V.TREAD

local function trailer(kind, P)
	local def, MAX_T, LOAD_R, LOADED_SPEED = P.def, P.max_t, P.load_r, P.loaded_speed
	local DECK_Z, DECK_TOP, DECK_LEN = P.deck_z, P.deck_top, P.deck_len
	local FRONT = DECK_Z + DECK_LEN / 2          -- 平板前端（車身座標 z）
	def.trailer = true

	-- 車子前後的實際範圍（零件伸出碰撞箱的也算：挖土機收起的鏟斗、礦用挖土機的配重）：回傳 車頭往前, 車尾往後
	local ext_cache = {}
	local function extent(d)
		local e = ext_cache[d]
		if e then return e[1], e[2] end
		local front, back = d.half, d.rear or d.half
		for _, pt in ipairs(d.parts or {}) do
			if pt.pos and pt.size then
				front = math.max(front, pt.pos.z + pt.size.z / 2)
				back = math.max(back, -(pt.pos.z - pt.size.z / 2))
			end
		end
		ext_cache[d] = {front, back}
		return front, back
	end
	local function len_of(d) local f, b = extent(d); return f + b end     -- 車子前後的長度
	-- 載著的車：self.carry = {{uid, z（掛在平板上的位置）}, ...}，照載上去的順序
	local function list_of(self)
		if self.carry_uid and not self.carry then self.carry = {{uid = self.carry_uid}}; self.carry_uid = nil end   -- 舊存檔（只載一台）
		self.carry = self.carry or {}
		return self.carry
	end
	local function ent(c)
		local e = V.by_uid[c.uid]
		return e and e.object:get_pos() and e or nil
	end
	local function total_t(self)
		local t = 0
		for _, c in ipairs(list_of(self)) do
			local e = ent(c)
			t = t + (e and V.MASS[e.vkind] or c.t or 0)
		end
		return t
	end
	local function used_len(self)
		local l = 0
		for _, c in ipairs(list_of(self)) do l = l + (c.len or 0) end
		return l
	end

	-- 把 e 掛到平板上（車底貼著平板面，車身中心在 z）
	local function attach(self, e, z)
		local d = V.TYPES[e.vkind]
		e.object:set_velocity({x = 0, y = 0, z = 0})
		e.object:set_acceleration({x = 0, y = 0, z = 0})
		e.object:set_attach(self.object, "", {x = 0, y = (DECK_TOP + d.half) * 10, z = z * 10}, {x = 0, y = 0, z = 0})
		e.on_lowboy = self.uid
	end

	local put_on          -- 下面定義：把 best 掛上平板（檢查總重、長度）
	local function load_vehicle(self)
		local deck = V.to_world(self, {x = 0, y = 0, z = DECK_Z})
		local best, bd
		for _, o in ipairs(core.get_objects_inside_radius(deck, LOAD_R + 8)) do
			local e = o:get_luaentity()
			local ed = e and e.vkind and V.TYPES[e.vkind]
			if e and e ~= self and ed and not ed.trailer and not e.driver and not o:get_attach()
					and (not self.owner or not e.owner or e.owner == self.owner) then
				local d = vector.distance(o:get_pos(), deck)
				if d <= LOAD_R and (not bd or d < bd) then best, bd = e, d end
			end
		end
		if not best then return S("No vehicle to load within @1 m of the deck", ("%d"):format(LOAD_R)) end
		return put_on(self, best)
	end
	put_on = function(self, best)
		local d = V.TYPES[best.vkind]
		local t = V.MASS[best.vkind] or 20
		local now = total_t(self)
		if now + t > MAX_T then
			return S("@1 weighs @2 t; with @3 t already on, that is more than the @4 t it can carry", d.desc, ("%d"):format(t), ("%d"):format(now), ("%d"):format(MAX_T))
		end
		local used, l = used_len(self), len_of(d)
		if used + l > DECK_LEN + 0.5 then return S("No room left on the deck for @1", d.desc) end
		-- 從平板前端往後排：車頭朝前，車身中心離前端 used + 車頭往前的長度
		local z = FRONT - used - (extent(d))
		-- 挖土機：手臂收回原位再運
		if best.arm_h ~= nil or (best.swing or 0) ~= 0 then
			best.arm_h, best.swing = nil, 0
			if d.show_tool then d.show_tool(best) end
		end
		attach(self, best, z)
		local list = list_of(self)
		list[#list + 1] = {uid = best.uid, z = z, len = l, t = t}
		return nil, d.desc
	end

	-- 卸下一台（i：清單裡第幾台，預設最後載上去的那一台）：卸在車尾後方
	local function unload_vehicle(self, i)
		local list = list_of(self)
		local c = table.remove(list, i or #list)
		if not c then return end
		local e = ent(c)
		if not e then return end
		local d = V.TYPES[e.vkind]
		e.object:set_detach()
		e.on_lowboy = nil
		local p = V.to_world(self, {x = 0, y = -def.half + d.half + 0.3, z = -def.rear - (d.half + 1)})
		e.object:set_pos(p)
		e.object:set_yaw(self.object:get_yaw())
		e.object:set_acceleration({x = 0, y = -9.81, z = 0})
		return d.desc
	end

	-- 開著車對拖車按右鍵（vehicles.lua）：開上平板；已經在這台平板上就開下來（卸在車尾後方）。人一直坐在車上
	function def.drive_on(self, e, player)
		local name = player:get_player_name()
		local list = list_of(self)
		for i, c in ipairs(list) do
			if c.uid == e.uid then
				local what = unload_vehicle(self, i)
				if what then rockmech.notify(name, S("[Trailer] Drove @1 off the deck", what)) end
				V.update_hud(self)
				return
			end
		end
		if V.TYPES[e.vkind].trailer then return end
		local deck = V.to_world(self, {x = 0, y = 0, z = DECK_Z})
		if vector.distance(e.object:get_pos(), deck) > LOAD_R then
			rockmech.notify(name, S("[Trailer] Get within @1 m of the deck first", ("%d"):format(LOAD_R)))
			return
		end
		local why, what = put_on(self, e)
		if why then rockmech.notify(name, S("[Trailer] @1", why))
		else rockmech.notify(name, S("[Trailer] @1 is on the deck: Shift to get out, right-click the trailer to drive off", what)) end
		V.update_hud(self)
	end

	function def.action(self, ctx)
		if ctx.ctrl.aux1 then
			self.t_act = 0.6
			local why, what = load_vehicle(self)
			self.msg = why or S("Loaded @1", what)
			V.update_hud(self)
		elseif ctx.ctrl.jump then
			self.t_act = 0.6
			local what = unload_vehicle(self)
			self.msg = what and S("Unloaded @1", what) or S("Nothing on the deck")
			V.update_hud(self)
		end
	end

	function def.move(self, ctx)
		local list = list_of(self)
		if #list > 0 then
			-- 載車：直線加速的上限 LOADED_SPEED，加速度減半（vehicles.lua 這一步已經加了 accel·dt，扣回一半）
			if self.cruise and self.cruise > def.speed and ctx.fwd > 0 then
				self.cruise = math.max(def.speed, math.min(LOADED_SPEED, self.cruise - 0.5 * def.accel * ctx.dtime))
				if ctx.speed > 0 then ctx.speed = math.min(ctx.speed, self.cruise) end
			end
			ctx.speed = math.max(-LOADED_SPEED, math.min(LOADED_SPEED, ctx.speed))
			-- 區塊重新載入後，載的車載入了卻沒掛在平板上（附著不會存檔，它會照自己存的位置出現、掉到地上）：掛回來。
			-- 要看它是不是真的掛在這台上（ObjectRef 不能用 == 比，比 luaentity）
			for _, c in ipairs(list) do
				local e = ent(c)
				if e then
					if not c.z then local d = V.TYPES[e.vkind]; c.z, c.len = FRONT - (extent(d)), len_of(d) end    -- 舊存檔
					local parent = e.object:get_attach()
					if not parent then attach(self, e, c.z) end
				end
			end
		end
	end

	function def.hud(self)
		local list = list_of(self)
		if #list == 0 then return "\n" .. S("Deck: @1", S("empty")) end
		local names = {}
		for _, c in ipairs(list) do
			local e = ent(c)
			names[#names + 1] = e and V.TYPES[e.vkind].desc or S("(carried vehicle not loaded yet)")
		end
		return "\n" .. S("Deck: @1", table.concat(names, S(", "))) .. "  " .. S("@1 / @2 t", ("%d"):format(total_t(self)), ("%d"):format(MAX_T))
	end
	function def.keys(self)
		local n = #list_of(self)
		return {{"E", S("Load vehicle (next to the deck)"), on = n > 0}, {S("Space"), S("Unload vehicle")}}
	end
	function def.on_save(self, data) data.carry = list_of(self) end
	function def.on_load(self, data)
		self.carry = data.carry
		if not self.carry and data.carry_uid then self.carry = {{uid = data.carry_uid}} end
	end
	V.register(kind, def)
end
rockmech.vehicle_trailer = trailer

---------------------------------------------------------------------------
-- 平板拖車：牽引車在前（車頭 z +1.5），平板 10 m（z −2.1 到 −12.1），平板面離車底 0.5 m
---------------------------------------------------------------------------
do
	local c = "#d86018"
	local def = {desc = S("Lowboy trailer"), short = S("Trailer"), color = c, cap = 0, speed = 4,
		top_speed = 12, accel = 1.5,   -- 直線加速到約 43 km/h（同卡車）；載車時見 def.move
		tire = 1.0, max_grade = math.rad(15),
		half = 1.5, top = 1.4, lat = {-1, 0, 1}, eye_up = 1.5, eye_fwd = 0.9, rear = 12.5,
		mirror = {x = 1.35, y = 1.2, z = 0.6}, rearcam = {x = 0, y = 1.0, z = -12.7},
		tilt = {front = 0.9, rear = -11.5, side_z = -5.5, side_x = 1.1},
		tail_lat = {-1.3, 0, 1.3}, tail_dy = {0.6},
		item_desc = S("Right-click to get in; E loads / unloads a vehicle")}
	V.MASS.lowboy = 25
	do   -- 圖示：橘色牽引車、長長的低平板、上面一台小怪手的輪廓
		local r = {}
		r[#r + 1] = {22, 12, 8, 9, c}; r[#r + 1] = {24, 13, 4, 4, "#9fd0ff"}
		r[#r + 1] = {1, 19, 23, 3, "#3a3a3a"}; r[#r + 1] = {18, 16, 6, 3, "#3a3a3a"}
		r[#r + 1] = {5, 12, 9, 6, "#e8c828"}; r[#r + 1] = {12, 8, 6, 2, "#e8c828"}
		V.icon_wheel(r, 26, 24, 3); V.icon_wheel(r, 5, 24, 3); V.icon_wheel(r, 11, 24, 3)
		def.inv_image = V.icon(r)
	end
	local DECK_Z, DECK_TOP = -7.1, -1.0
	local paint = ("[fill:16x16:%s"):format(c)
	local glass = ("[fill:16x16:%s^[fill:12x8:2,2:#9fd0ff^[fill:16x2:0,14:#2a2a2a"):format(c)
	local side = V.cab_side(c, {win = {x = 2, y = 2, w = 12, h = 8}, sill = "#2a2a2a", doors = {{x = 1, y = 1, w = 14, h = 12.8}}})
	local side_l = V.flip_side(side)
	local nose = ("[fill:16x16:%s^[fill:12x7:2,5:#2a2a2a^[fill:12x1:2,7:#4a4a4a^[fill:12x1:2,10:#4a4a4a^[fill:3x2:1,1:#f0e070^[fill:3x2:12,1:#f0e070"):format(c)
	local deck = "[fill:16x16:#4a4c50^[fill:16x1:0,4:#3a3c40^[fill:16x1:0,9:#3a3c40^[fill:16x1:0,14:#3a3c40"
	local steel = box_tex("#3a3a3a")
	local stripe = "[fill:16x16:#3a3c40^[fill:4x16:0,0:#f0c020^[fill:4x16:8,0:#f0c020"
	local wheel = {TREAD, TREAD, WHEEL, WHEEL, TREAD, TREAD}
	def.parts = {
		{pos = {x = 0, y = -0.9, z = -0.4}, size = {x = 1.6, y = 0.4, z = 3.6}, tex = steel},                     -- 牽引車車架
		{pos = {x = 0, y = -0.2, z = 1.0}, size = {x = 2.3, y = 1.0, z = 1.0}, tex = {paint, paint, paint, paint, nose, paint}},  -- 引擎蓋
		{pos = {x = 0, y = 0.4, z = -0.1}, size = {x = 2.4, y = 1.8, z = 1.3}, tex = {paint, steel[2], side, side_l, glass, paint}}, -- 駕駛室
		{pos = {x = 0.8, y = 1.2, z = -0.85}, size = {x = 0.14, y = 1.2, z = 0.14}, tex = box_tex("#202020")},  -- 排氣管
		{pos = {x = 0, y = -0.55, z = -1.9}, size = {x = 2.6, y = 0.5, z = 1.4}, tex = steel},                   -- 鵝頸
		{pos = {x = 0, y = DECK_TOP - 0.12, z = DECK_Z}, size = {x = 2.9, y = 0.25, z = 10.0}, tex = {deck, steel[2], stripe, stripe, stripe, stripe}},  -- 平板
		{pos = {x = -0.85, y = -1.25, z = -12.6}, size = {x = 0.7, y = 0.08, z = 1.0}, tex = box_tex("#5a5c60"), rot = {x = -20, y = 0, z = 0}},  -- 後坡道
		{pos = {x = 0.85, y = -1.25, z = -12.6}, size = {x = 0.7, y = 0.08, z = 1.0}, tex = box_tex("#5a5c60"), rot = {x = -20, y = 0, z = 0}},
	}
	for _, w in ipairs({{x = -1.1, z = 1.0}, {x = 1.1, z = 1.0}, {x = -1.1, z = -1.2}, {x = 1.1, z = -1.2},
			{x = -1.3, z = -11.0}, {x = 1.3, z = -11.0}, {x = -1.3, z = -10.0}, {x = 1.3, z = -10.0}}) do
		def.parts[#def.parts + 1] = {pos = {x = w.x, y = -1.0, z = w.z}, size = {x = 0.35, y = 1.0, z = 1.0}, tex = wheel}
	end
	def.exhaust = {x = 0.8, y = 1.85, z = -0.85}
	-- 擋人：平板（碰撞箱後方）
	def.overhangs = {{x0 = -1.5, x1 = 1.5, z0 = -12.5, z1 = -1.5, y0 = -1.5, y1 = -0.85, body = "z1"}}
	trailer("lowboy", {def = def, max_t = 60, load_r = 8, loaded_speed = 8, deck_z = DECK_Z, deck_top = DECK_TOP, deck_len = 10.0})
end

---------------------------------------------------------------------------
-- 重型拖車：大牽引車（車頭 z +1.5）＋多軸線模組化平板，平板從 z −2.5 到 −15.5（13 m）、寬 3.6 m，
-- 平板面離車底 1.0 m，底下 8 排小輪子。150 t：礦用挖土機（100 t）、礦卡（70 t）
---------------------------------------------------------------------------
do
	local c = "#2a4a8a"
	local def = {desc = S("Heavy haul trailer"), short = S("Heavy trailer"), color = c, cap = 0, speed = 4,
		top_speed = 12, accel = 1.2,   -- 空車約 43 km/h（同卡車）
		tire = 1.0, max_grade = math.rad(12),
		half = 1.5, top = 1.8, lat = {-1, 0, 1}, eye_up = 1.9, eye_fwd = 0.9, rear = 15.5,
		mirror = {x = 1.45, y = 1.5, z = 0.6}, rearcam = {x = 0, y = 1.4, z = -15.7},
		tilt = {front = 0.9, rear = -14.5, side_z = -6.0, side_x = 1.6},
		tail_lat = {-1.8, 0, 1.8}, tail_dy = {0.6},
		item_desc = S("Right-click to get in; E loads / unloads a vehicle")}
	V.MASS.heavyhaul = 45
	do   -- 圖示：藍色牽引車、長平板、底下一排小輪子、上面一台大挖土機的輪廓
		local r = {}
		r[#r + 1] = {23, 9, 8, 12, c}; r[#r + 1] = {25, 10, 4, 4, "#9fd0ff"}
		r[#r + 1] = {0, 18, 24, 3, "#3a3a3a"}
		r[#r + 1] = {2, 9, 13, 8, "#e8a818"}; r[#r + 1] = {12, 4, 9, 3, "#e8a818"}
		for x = 1, 21, 4 do r[#r + 1] = {x, 21, 3, 3, "#1c1c1c"} end
		V.icon_wheel(r, 27, 24, 3)
		def.inv_image = V.icon(r)
	end
	local DECK_Z, DECK_TOP = -9.0, -0.5
	local paint = ("[fill:16x16:%s"):format(c)
	local glass = ("[fill:16x16:%s^[fill:12x8:2,2:#9fd0ff^[fill:16x2:0,14:#2a2a2a"):format(c)
	local side = V.cab_side(c, {win = {x = 2, y = 2, w = 12, h = 8}, sill = "#2a2a2a", doors = {{x = 1, y = 1, w = 14, h = 12.8}}})
	local side_l = V.flip_side(side)
	local nose = ("[fill:16x16:%s^[fill:12x8:2,4:#2a2a2a^[fill:12x1:2,6:#4a4a4a^[fill:12x1:2,9:#4a4a4a^[fill:3x2:1,1:#f0e070^[fill:3x2:12,1:#f0e070"):format(c)
	local deck = "[fill:16x16:#4a4c50^[fill:16x1:0,4:#3a3c40^[fill:16x1:0,9:#3a3c40^[fill:16x1:0,14:#3a3c40"
	local steel = box_tex("#3a3a3a")
	local stripe = "[fill:16x16:#3a3c40^[fill:4x16:0,0:#f07020^[fill:4x16:8,0:#f07020"
	local wheel = {TREAD, TREAD, WHEEL, WHEEL, TREAD, TREAD}
	def.parts = {
		{pos = {x = 0, y = -0.85, z = -0.5}, size = {x = 1.8, y = 0.5, z = 3.8}, tex = steel},                    -- 牽引車車架
		{pos = {x = 0, y = 0.0, z = 1.0}, size = {x = 2.6, y = 1.4, z = 1.0}, tex = {paint, paint, paint, paint, nose, paint}},   -- 引擎蓋
		{pos = {x = 0, y = 0.7, z = -0.15}, size = {x = 2.7, y = 2.2, z = 1.4}, tex = {paint, steel[2], side, side_l, glass, paint}},  -- 駕駛室
		{pos = {x = 0.95, y = 1.6, z = -0.95}, size = {x = 0.16, y = 1.4, z = 0.16}, tex = box_tex("#202020")},  -- 排氣管
		{pos = {x = -0.95, y = 1.6, z = -0.95}, size = {x = 0.16, y = 1.4, z = 0.16}, tex = box_tex("#202020")},
		{pos = {x = 0, y = -0.4, z = -2.2}, size = {x = 3.0, y = 0.6, z = 1.4}, tex = steel},                    -- 鵝頸
		{pos = {x = 0, y = DECK_TOP - 0.2, z = DECK_Z}, size = {x = 3.6, y = 0.4, z = 13.0}, tex = {deck, steel[2], stripe, stripe, stripe, stripe}},  -- 平板
	}
	for _, w in ipairs({{x = -1.25, z = 1.0}, {x = 1.25, z = 1.0}, {x = -1.25, z = -1.4}, {x = 1.25, z = -1.4}}) do
		def.parts[#def.parts + 1] = {pos = {x = w.x, y = -1.0, z = w.z}, size = {x = 0.4, y = 1.0, z = 1.0}, tex = wheel}
	end
	-- 多軸線：8 排、每排 4 個小輪子（直徑 0.7 m）
	for i = 0, 7 do
		local z = -4.0 - i * 1.5
		for _, x in ipairs({-1.45, -0.75, 0.75, 1.45}) do
			def.parts[#def.parts + 1] = {pos = {x = x, y = -1.15, z = z}, size = {x = 0.35, y = 0.7, z = 0.7}, tex = wheel}
		end
	end
	def.exhaust = {x = 0.95, y = 2.35, z = -0.95}
	def.overhangs = {{x0 = -1.8, x1 = 1.8, z0 = -15.5, z1 = -1.5, y0 = -1.5, y1 = -0.3, body = "z1"}}
	trailer("heavyhaul", {def = def, max_t = 150, load_r = 12, loaded_speed = 6, deck_z = DECK_Z, deck_top = DECK_TOP, deck_len = 13.0})   -- 載車約 22 km/h
end
