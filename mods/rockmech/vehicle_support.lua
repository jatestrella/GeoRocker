-- rockmech/vehicle_support.lua
-- 隧道支撐台車（由 vehicles.lua 載入，單機版商店才有）。底盤同鑽堡（vehicle_jumbo.lua 的 carrier）。
-- 實務上通常分成三台，也有合成一台的多功能台車：
--   岩栓台車（rock bolter）：E 在前方斷面的頂拱、側牆自己鑽孔再插岩栓。空白鍵設定長度 2～6 m、間距 1／2 m。
--   噴凝土台車（shotcrete sprayer）：E 把前方斷面露出的岩面噴一層（最多 3 層，按幾次噴幾層）。用量同手噴：一袋 9 格。
--   鋼支保安裝台車（steel set erector）：E 在前方斷面沿岩面架整圈鋼拱（從牆腳往頂拱）。空白鍵設定間距 1／2 m。
--   多功能支撐台車：三種都會，空白鍵選工作。比三台貴：省掉在隧道裡換車的功夫。
-- 前方斷面：車頭外第 2～4 m 三個斷面，橫向車身中心線左右各 SIDE m、高度從地面那層往上 HIGH m；
-- 從車頭正前方的空間往外找（同一個開挖空間），貼著岩石的頂拱、側牆格（地板、工作面不算）。
-- 材料從駕駛的物品欄扣（創造模式不扣）：岩栓、噴凝土、鋼拱都是五金行、大地工程顧問的商品。
-- 手做照舊（鑿岩機鑽孔再一支一支插、噴凝土一次 3×3、鋼拱一格一格放）：機器省事才有市場。

local S = rockmech.S
local V = rockmech.vehicles
local box_tex, seg_attach, to_local, update_hud = V.box_tex, V.seg_attach, V.to_local, V.update_hud
local carrier, carrier_move = V.jumbo_carrier, V.jumbo_carrier_move

local D0, D1 = 2, 4          -- 前方斷面：車頭方向離車身中心 D0..D1 m
local SIDE, HIGH = 8, 10     -- 橫向左右各幾 m、地面那層往上幾 m
local BOLT_ITEM, SHOT, ARCH = "rockmech:rock_bolt", "rockmech:shotcrete", "rockmech:steel_arch"
local TIME = {bolt = 1.5, arch = 0.3, spray = 0.07}   -- 一支岩栓（鑽孔＋插）、一格鋼拱、一格噴凝土（一袋 9 格約 0.6 s）
local ITEM_OF = {bolt = BOLT_ITEM, spray = SHOT, arch = ARCH}
local SPRAY_PER_BAG = 9

local BOOM_BASE = {x = 0, y = 0.3, z = 1.2}       -- 作業臂根部（車身座標）
local HEAD_REST = {x = 0, y = 0.2, z = 2.2}       -- 收起時臂端
local HEAD = {x = 0.6, y = 0.6, z = 0.8}
local FRONT = 1.3

local function is_rock(name) return core.get_item_group(name, "rockmech_rock") > 0 end
local function is_arch(name) return core.get_item_group(name, "rockmech_steelarch") > 0 end
-- 開挖空間裡的格：空氣、噴凝土、孔、岩栓、燈（不能站的）、鋼拱
local function open_cell(name)
	if name == "air" or is_arch(name) then return true end
	local d = core.registered_nodes[name]
	return d ~= nil and d.walkable == false and (d.liquidtype or "none") == "none"
end

-- 前方斷面的頂拱、側牆格：{p, dir（往岩面）, roof, t（沿隧道的座標）, c（斷面內的座標：頂拱用橫向、側牆用高度）, j}
-- 每個斷面從車頭正前方（中心線、地面那三層）往外找相連的開挖空間
local function section_cells(pos, s, half)
	local y0 = V.ground_y(pos, half)
	local px, pz = -s.z, s.x   -- 往右
	local out = {}
	for dist = D0, D1 do
		local function at(l, j)
			return {x = math.floor(pos.x + s.x * dist + px * l + 0.5), y = y0 + j, z = math.floor(pos.z + s.z * dist + pz * l + 0.5)}
		end
		local seen, queue = {}, {}
		for j = 0, 2 do
			if open_cell(core.get_node(at(0, j)).name) then queue[#queue + 1] = {0, j}; seen[0 .. ":" .. j] = true end
		end
		local qi = 1
		while qi <= #queue do
			local l, j = queue[qi][1], queue[qi][2]
			qi = qi + 1
			local p = at(l, j)
			local up = at(l, j + 1)
			local roof = is_rock(core.get_node(up).name)
			local side
			for _, dl in ipairs({-1, 1}) do
				if is_rock(core.get_node(at(l + dl, j)).name) then side = dl end
			end
			if roof or side then
				local dir = roof and {x = 0, y = 1, z = 0} or {x = px * side, y = 0, z = pz * side}
				out[#out + 1] = {p = p, dir = dir, roof = roof, t = p.x * s.x + p.z * s.z, c = roof and l or j, j = j, l = l}
			end
			for _, nb in ipairs({{l - 1, j}, {l + 1, j}, {l, j + 1}, {l, j - 1}}) do
				local k = nb[1] .. ":" .. nb[2]
				if not seen[k] and math.abs(nb[1]) <= SIDE and nb[2] >= 0 and nb[2] <= HIGH then
					seen[k] = true
					if open_cell(core.get_node(at(nb[1], nb[2])).name) then queue[#queue + 1] = nb end
				end
			end
		end
	end
	-- 由下往上、由中間往兩側（鋼拱從牆腳架到頂拱）
	table.sort(out, function(a, b)
		if a.t ~= b.t then return a.t < b.t end
		if a.j ~= b.j then return a.j < b.j end
		return math.abs(a.l) < math.abs(b.l)
	end)
	return out
end
rockmech.vehicle_support_cells = section_cells    -- 測試用

-- 間距 2 m：沿隧道、斷面內都隔一格
local function on_grid(c, spacing) return spacing == 1 or (c.t % 2 == 0 and c.c % 2 == 0) end
local function on_ring(c, spacing) return spacing == 1 or c.t % 2 == 0 end

-- 沿 dir 從 under 往裡連續幾格岩石（最多 n）
local function rock_run(under, dir, n)
	for k = 0, n - 1 do
		if not rockmech.lith_of_node[core.get_node(vector.add(under, vector.multiply(dir, k))).name] then return k end
	end
	return n
end

-- 工作清單：{kind, p, dir, depth}
local function task_list(self, mode, pos, s, half)
	local cells = section_cells(pos, s, half)
	if #cells == 0 then return nil end
	local list = {}
	if mode == "bolt" then
		for _, c in ipairs(cells) do
			local n = core.get_node(c.p)
			local under = vector.add(c.p, c.dir)
			if on_grid(c, self.spacing or 2) and not is_arch(n.name) then        -- 岩栓打在兩支鋼拱之間
				local hk = rockmech.hole_kind(n.name)
				if hk == "rockmech:drill_hole" then
					list[#list + 1] = {kind = "bolt", p = c.p, hole = true}
				elseif rockmech.air_like(n.name) and rockmech.lith_of_node[core.get_node(under).name] then
					local depth = rock_run(under, c.dir, self.len or 4)
					list[#list + 1] = {kind = "bolt", p = c.p, under = under, depth = depth}
				end
			end
		end
	elseif mode == "arch" then
		local axis = s.x ~= 0 and "x" or "z"
		for _, c in ipairs(cells) do
			local n = core.get_node(c.p).name
			if on_ring(c, self.spacing or 1) and (n == "air" or core.get_item_group(n, "shotcrete_lining") > 0) then
				list[#list + 1] = {kind = "arch", p = c.p, axis = axis}
			end
		end
	else
		for _, c in ipairs(cells) do list[#list + 1] = {kind = "spray", p = c.p} end
	end
	return list
end

-- 駕駛物品欄裡有幾個 item（創造模式不限）
local function stock(d, item)
	if not d then return 0 end
	if core.is_creative_enabled(d:get_player_name()) then return math.huge end
	local n = 0
	for _, st in ipairs(d:get_inventory():get_list("main") or {}) do
		if st:get_name() == item then n = n + st:get_count() end
	end
	return n
end
local function take(d, item)
	if core.is_creative_enabled(d:get_player_name()) then return end
	d:get_inventory():remove_item("main", ItemStack(item))
end

local MODE_NAME = {bolt = S("Rock bolting"), spray = S("Shotcrete"), arch = S("Steel sets")}
local OUT_OF = {bolt = S("Out of rock bolts"), spray = S("Out of shotcrete"), arch = S("Out of steel arches")}

-- 一台支撐台車：kind、名稱、顏色、會做的工作（第一個是預設）、價格寫在 config.lua 的商店
local function make(kind, desc, color, modes)
	local def = {desc = desc, color = color, cap = 0}
	local multi = #modes > 1
	local can = {}
	for _, m in ipairs(modes) do can[m] = true end
	def.item_desc = multi and S("Right-click to get in; E works on the tunnel section ahead, Space chooses the job")
		or S("Right-click to get in; E works on the tunnel section ahead, Space for settings")
	do   -- 圖示：輪式車身、往前上方伸的作業臂、臂端的工具
		local r = {}
		r[#r + 1] = {2, 17, 19, 7, color}; r[#r + 1] = {2, 10, 8, 7, color}; r[#r + 1] = {3, 11, 6, 4, "#2a2a2a"}
		V.icon_line(r, 16, 16, 25, 6, 2, color)
		r[#r + 1] = {23, 2, 7, 6, "#3a3a3a"}
		if can.bolt then r[#r + 1] = {29, 4, 3, 1, "#b0b0b0"} end
		if can.spray then r[#r + 1] = {26, 8, 2, 3, "#a4a29c"} end
		if can.arch then r[#r + 1] = {22, 1, 1, 6, "#6c737a"} end
		V.icon_wheel(r, 7, 26, 4); V.icon_wheel(r, 17, 26, 4)
		def.inv_image = V.icon(r)
	end
	carrier(def, {
		{id = "boom", pos = {x = 0, y = 0, z = 0}, size = {x = 0.3, y = 1, z = 0.3}, tex = box_tex(color)},
		{id = "head", pos = HEAD_REST, size = HEAD, tex = box_tex("#3a3a3a")},
	})
	def.overhangs[#def.overhangs + 1] = {x0 = -0.6, x1 = 0.6, z0 = 1.5, z1 = 1.5 + FRONT, y0 = -0.5, y1 = 0.8, body = "z0"}

	local function place_head(self, b)
		local ps = self.parts
		if not ps then return end
		if ps.boom then
			ps.boom:set_properties({visual_size = {x = 0.3, y = math.max(0.1, vector.distance(BOOM_BASE, b)), z = 0.3}})
			seg_attach(self, ps.boom, BOOM_BASE, b)
		end
		if ps.head then ps.head:set_attach(self.object, "", {x = b.x * 10, y = b.y * 10, z = b.z * 10}, {x = 0, y = 0, z = 0}) end
	end
	local function mode_of(self) return can[self.mode] and self.mode or modes[1] end

	function def.hud(self)
		local m = mode_of(self)
		local d = self.driver and core.get_player_by_name(self.driver)
		local s = "\n" .. (multi and (MODE_NAME[m] .. "  ") or "")
		if m == "bolt" then s = s .. S("Bolt length @1 m, spacing @2 m", ("%d"):format(self.len or 4), ("%d"):format(self.spacing or 2))
		elseif m == "arch" then s = s .. S("Steel set spacing @1 m", ("%d"):format(self.spacing or 1)) end
		local n = stock(d, ITEM_OF[m])
		s = s .. "  " .. (n == math.huge and S("(not used up in creative mode)") or S("@1 in inventory", ("%d"):format(n)))
		local w = self.work
		if w then s = s .. "  " .. S("Working @1 / @2", ("%d"):format(w.i - 1), ("%d"):format(#w.list)) end
		return s
	end
	function def.keys(self)
		return {{"E", MODE_NAME[mode_of(self)], on = self.work ~= nil}, {S("Space"), multi and S("Choose job") or S("Settings")}}
	end
	function def.on_load(self, data) self.mode, self.len, self.spacing = data.mode, data.len, data.spacing end
	function def.on_save(self, data) data.mode, data.len, data.spacing = self.mode, self.len, self.spacing end
	function def.on_spawn(self) place_head(self, HEAD_REST) end
	carrier_move(def, FRONT, function(self) return self.work ~= nil end)

	local function finish(self, msg)
		local w = self.work
		self.work = nil
		self.msg = msg
		place_head(self, HEAD_REST)
		if w and w.done > 0 and rockmech.cfg.fem.drive and w.center then rockmech.fem_queue(w.center, 1) end
		update_hud(self)
	end
	local DONE = {
		bolt = function(n) return S("Installed @1 rock bolts", ("%d"):format(n)) end,
		spray = function(n) return S("Sprayed @1 m² of shotcrete", ("%d"):format(n)) end,
		arch = function(n) return S("Erected @1 m of steel arch", ("%d"):format(n)) end,
	}

	function def.step(self, ctx)
		local w = self.work
		if not w then return end
		local d = ctx.d
		if not d then return end           -- 沒人開：停著等
		local tk = w.list[w.i]
		if not tk then return finish(self, DONE[w.mode](w.done)) end
		if w.t == 0 then
			local lp = to_local(self, vector.add(tk.p, vector.multiply(tk.dir or {x = 0, y = 0, z = 0}, 0.3)))
			place_head(self, {x = lp.x, y = lp.y, z = lp.z - 0.6})
		end
		w.t = w.t + ctx.dtime * (w.mode == "bolt" and rockmech.eff_dig_mult(self.owner) or 1)
		if w.t < TIME[w.mode] then return end
		w.t = 0
		w.i = w.i + 1
		local item = ITEM_OF[w.mode]
		if w.mode == "spray" then
			if w.credit <= 0 then
				if stock(d, item) <= 0 then return finish(self, OUT_OF.spray .. " (" .. DONE.spray(w.done) .. ")") end
				take(d, item)
				w.credit = SPRAY_PER_BAG
			end
			if rockmech.spray_cell(tk.p) then w.credit = w.credit - 1; w.done = w.done + 1 end
		else
			if stock(d, item) <= 0 then return finish(self, OUT_OF[w.mode] .. " (" .. DONE[w.mode](w.done) .. ")") end
			local ok = false
			if w.mode == "bolt" then
				if tk.hole then ok = rockmech.install_bolt(tk.p)
				elseif tk.depth >= 1 and rockmech.make_hole(tk.under, tk.p) then
					core.get_meta(tk.p):set_float("depth", tk.depth)
					ok = rockmech.install_bolt(tk.p)
				end
			else
				local n = core.get_node(tk.p).name
				if n == "air" or core.get_item_group(n, "shotcrete_lining") > 0 then
					rockmech.steelarch_place(tk.p, tk.axis)
					ok = true
				end
			end
			if ok then take(d, item); w.done = w.done + 1 end
		end
		if w.i % 4 == 0 then update_hud(self) end
	end

	-- 設定畫面
	local editing = {}
	local FORM = "rockmech:support_" .. kind
	local function formspec(self)
		local m = mode_of(self)
		local fs = {"formspec_version[6]size[8.5,5.2]"}
		local y = 0.5
		if multi then
			fs[#fs + 1] = ("label[0.5,%.2f;%s]"):format(y + 0.1, core.formspec_escape(S("Job")))
			for i, mm in ipairs(modes) do
				fs[#fs + 1] = ("button[%.2f,%.2f;2.4,0.8;m_%s;%s]"):format(0.5 + (i - 1) * 2.55, y + 0.4, mm,
					core.formspec_escape((mm == m and "▶ " or "") .. MODE_NAME[mm]))
			end
			y = y + 1.6
		end
		if m == "bolt" then
			fs[#fs + 1] = ("label[0.5,%.2f;%s]button[4.2,%.2f;0.8,0.7;l_dec;−]button[5.1,%.2f;0.8,0.7;l_inc;+]"):format(y + 0.35,
				core.formspec_escape(S("Bolt length @1 m", ("%d"):format(self.len or 4))), y, y)
			y = y + 0.9
		end
		if m == "bolt" or m == "arch" then
			local sp = self.spacing or (m == "bolt" and 2 or 1)
			fs[#fs + 1] = ("label[0.5,%.2f;%s]button[4.2,%.2f;1.7,0.7;sp;%s]"):format(y + 0.35,
				core.formspec_escape(S("Spacing")), y, core.formspec_escape(S("@1 m", ("%d"):format(sp))))
			y = y + 0.9
		end
		if m == "spray" then
			fs[#fs + 1] = ("label[0.5,%.2f;%s]"):format(y + 0.35, core.formspec_escape(S("Each press sprays one more layer (max @1)", ("%d"):format(rockmech.SHOTCRETE_LAYERS or 3))))
			y = y + 0.9
		end
		fs[#fs + 1] = ("button_exit[5.8,%.2f;2.2,0.8;ok;%s]"):format(math.max(y + 0.2, 4.1), core.formspec_escape(S("Done")))
		return table.concat(fs)
	end
	core.register_on_player_receive_fields(function(player, formname, fields)
		if formname ~= FORM then return end
		local name = player:get_player_name()
		local self = editing[name]
		if not self or not self.object:get_pos() then return true end
		for _, mm in ipairs(modes) do
			if fields["m_" .. mm] and mm ~= self.mode then self.mode = mm; self.spacing = nil end
		end
		local m = mode_of(self)
		if fields.l_dec then self.len = math.max(2, (self.len or 4) - 1) end
		if fields.l_inc then self.len = math.min(6, (self.len or 4) + 1) end
		if fields.sp then self.spacing = (self.spacing or (m == "bolt" and 2 or 1)) == 1 and 2 or 1 end
		if fields.quit or fields.ok then editing[name] = nil
		else core.show_formspec(name, FORM, formspec(self)) end
		update_hud(self)
		return true
	end)

	function def.action(self, ctx)
		local ctrl, d = ctx.ctrl, ctx.d
		if ctrl.aux1 and not self.work and d then
			self.t_act = 0.5
			local m = mode_of(self)
			local list = task_list(self, m, ctx.pos, ctx.s, def.half)
			if not list then
				self.msg = S("No tunnel wall or roof to work on in the @1 m ahead", ("%d"):format(D1 - D0 + 1))
			elseif #list == 0 then
				self.msg = m == "bolt" and S("Nothing to bolt in the @1 m ahead (bolts go between steel arches)", ("%d"):format(D1 - D0 + 1))
					or S("Already done in the @1 m ahead", ("%d"):format(D1 - D0 + 1))
			elseif stock(d, ITEM_OF[m]) <= 0 then
				self.msg = OUT_OF[m]
			else
				local c = list[math.ceil(#list / 2)].p
				self.work = {mode = m, list = list, i = 1, t = 0, done = 0, credit = 0, center = vector.copy(c)}
				self.msg = nil
			end
			update_hud(self)
		elseif ctrl.jump and d and not self.work then
			self.t_act = 0.5
			editing[d:get_player_name()] = self
			core.show_formspec(d:get_player_name(), FORM, formspec(self))
		end
	end

	V.register(kind, def)
end

make("bolter", S("Rock bolter"), "#3a8a4a", {"bolt"})
make("sprayer", S("Shotcrete sprayer"), "#c8a828", {"spray"})
make("erector", S("Steel set erector"), "#a83a30", {"arch"})
make("support_rig", S("Multi-purpose support rig"), "#5a4a9a", {"bolt", "arch", "spray"})
