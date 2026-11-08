-- rockmech/stressmeter.lua
-- 量應力的兩樣工具（工具室管理員賣），讀數記進野帳本的「野外調查」頁、也顯示在準心右上：
--   扁千斤頂（flat jack）：右鍵牆面，在岩面切一道槽、放進扁千斤頂加壓到槽口回到原位，讀到「垂直於槽」的應力。
--     平常切垂直槽 → 量沿著牆面的水平應力；蹲下（Shift）切水平槽 → 量垂直應力。
--     量的是開挖面上的應力：初始地應力 × 開挖造成的應力集中（局部 σ1 ÷ 初始最大主應力，1～3 倍）。
--   孔內應力計（undercoring）：右鍵一個鑽孔（鑿岩機鑽的），把應力計放到孔底，讀孔底的三向應力 σv、σH、σh 和 σH 方位。
--     孔底離開挖面越遠越接近初始地應力；孔太淺（孔底還在應力集中區）讀數會偏大。
--   讀數有 ±5 % 的量測誤差。

local S = rockmech.S
local cfg = rockmech.cfg
local FLATJACK, CELL = "rockmech:flatjack", "rockmech:stress_cell"
local NOISE = 0.05

local function noisy(v) return v * (1 + NOISE * (math.random() + math.random() - 1)) end
local function mpa(v) return ("%.2f"):format(v) end

-- 開挖造成的應力集中：局部最大主應力 ÷ 初始最大主應力（1～3）
local function concentration(r)
	local i, ls = r.init, r.local_state
	local m = math.max(i.sv or 0, i.sH or 0, i.shmin or 0)
	if not ls or m <= 0 then return 1 end
	return math.max(1, math.min(3, (ls.s1 or m) / m))
end

local function bubble(player, lines, pos)
	if rockmech.info_bubble then rockmech.info_bubble(player, lines, pos) end
end
local function record(player, pos, lith, txt)
	if not rockmech.fieldbook_add_schmidt then return false end
	return rockmech.fieldbook_add_schmidt(player, {x = pos.x, y = pos.y, z = pos.z, lith = lith and lith.name, txt = txt}) ~= nil
end

core.register_tool(FLATJACK, {
	description = S("Flat jack\nRight-click a rock wall: stress across a vertical slot (horizontal stress); Shift: horizontal slot (vertical stress)"),
	short_description = S("Flat jack"),
	inventory_image = "[fill:16x16:#00000000^[fill:12x3:2,7:#b8bcc2^[fill:12x1:2,6:#8a8e92^[fill:12x1:2,10:#8a8e92^[fill:2x6:13,4:#3a3a3a^[fill:3x2:12,2:#c03020",
	stack_max = 1,
	on_place = function(itemstack, player, pointed)
		if not (player and player:is_player()) or pointed.type ~= "node" then return itemstack end
		local pos, n = pointed.under, vector.subtract(pointed.above, pointed.under)
		if not rockmech.lith_of_node[core.get_node(pos).name] then bubble(player, {S("Use it on a rock face")}, pos); return itemstack end
		if n.y ~= 0 then bubble(player, {S("Use it on a wall, not the floor or roof")}, pos); return itemstack end
		local r = rockmech.stress_report(pos)
		local c = concentration(r)
		local i = r.init
		local horizontal_slot = player:get_player_control().sneak
		local val, what
		if horizontal_slot then
			val, what = noisy((i.sv or 0) * c), S("vertical stress")
		else
			-- 沿著牆面的水平方向 t 上的初始水平應力：σH cos²θ + σh sin²θ（θ：t 跟 σH 方位的夾角）
			local az = math.rad(cfg.sH_azimuth or 0)
			local cth = math.abs(-n.z * math.sin(az) + n.x * math.cos(az))
			val, what = noisy(((i.sH or 0) * cth * cth + (i.shmin or 0) * (1 - cth * cth)) * c), S("horizontal stress along the wall")
		end
		local slot = horizontal_slot and S("horizontal slot") or S("vertical slot")
		local txt = S("Flat jack (@1): @2 @3 MPa", slot, what, mpa(val))
		local ok = record(player, pos, r.lith, txt)
		bubble(player, {txt, ok and S("Written into the field notebook") or S("No field notebook: not recorded")}, pos)
		return itemstack
	end,
})

core.register_tool(CELL, {
	description = S("Borehole stress cell\nRight-click a drill hole: in-situ stresses at the bottom of the hole"),
	short_description = S("Borehole stress cell"),
	inventory_image = "[fill:16x16:#00000000^[fill:4x12:6,2:#d8d8d0^[fill:4x2:6,2:#3a6a9a^[fill:4x1:6,7:#c03020^[fill:4x1:6,10:#2a8a2a^[fill:2x3:7,13:#3a3a3a",
	stack_max = 1,
	on_place = function(itemstack, player, pointed)
		if not (player and player:is_player()) or pointed.type ~= "node" then return itemstack end
		local hp = pointed.under
		local node = core.get_node(hp)
		if not (rockmech.hole_kind and rockmech.hole_kind(node.name) == "rockmech:drill_hole") then
			bubble(player, {S("Put it into an empty drill hole (drill one with the rock drill)")}, hp)
			return itemstack
		end
		-- 孔底：從孔口沿著孔的方向往裡 depth 公尺
		local dir = core.wallmounted_to_dir(node.param2)
		local depth = core.get_meta(hp):get_float("depth")
		if depth <= 0 then depth = (cfg.blast and cfg.blast.hole_depth) or 2 end
		local bottom = vector.round(vector.add(hp, vector.multiply(dir, depth)))
		local r = rockmech.stress_report(bottom)
		local c = concentration(r)
		local i = r.init
		local sv, sH, sh = noisy((i.sv or 0) * c), noisy((i.sH or 0) * c), noisy((i.shmin or 0) * c)
		local azm = (cfg.sH_azimuth or 0) + 5 * (math.random() + math.random() - 1)
		local txt = S("Stress cell @1 m deep: σv @2  σH @3  σh @4 MPa, σH azimuth @5°", ("%.0f"):format(depth), mpa(sv), mpa(sH), mpa(sh), ("%03.0f"):format(azm % 360))
		local ok = record(player, bottom, r.lith, txt)
		bubble(player, {txt, ok and S("Written into the field notebook") or S("No field notebook: not recorded")}, hp)
		return itemstack
	end,
})
