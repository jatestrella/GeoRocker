-- rockmech/stressmeter.lua
-- 量應力的兩樣工具（工具室管理員賣），讀數記進野帳本的「野外調查」頁、也顯示在準心右上：
--   平板千斤頂（flat jack）：右鍵牆面，在岩面切一道槽、放進平板千斤頂加壓到槽口回到原位，讀到「垂直於槽」的應力。
--     垂直槽 → 量沿著牆面的水平應力；水平槽 → 量垂直應力。拿著按 E 切換槽的方向（記在這把平板千斤頂上）。
--     讀到的就是那一格的初始地應力（不算開挖造成的應力集中，保持簡單）。
--   孔內應力計（undercoring）：右鍵一個鑽孔（鑿岩機鑽的），把應力計放到孔底，讀孔底的三向應力 σv、σH、σh 和 σH 方位。
--     讀到的是孔底那一格的初始地應力。
--   讀數有 ±5 % 的量測誤差。

local S = rockmech.S
local cfg = rockmech.cfg
local FLATJACK, CELL = "rockmech:flatjack", "rockmech:stress_cell"
local NOISE = 0.05

local function noisy(v) return v * (1 + NOISE * (math.random() + math.random() - 1)) end
local function mpa(v) return ("%.2f"):format(v) end

local function bubble(player, lines, pos)
	if rockmech.info_bubble then rockmech.info_bubble(player, lines, pos) end
end
local function record(player, pos, lith, txt)
	if not rockmech.fieldbook_add_schmidt then return false end
	return rockmech.fieldbook_add_schmidt(player, {x = pos.x, y = pos.y, z = pos.z, lith = lith and lith.name, txt = txt}) ~= nil
end

core.register_tool(FLATJACK, {
	description = S("Flat jack\nRight-click a rock wall to measure; E switches between a vertical slot (horizontal stress) and a horizontal slot (vertical stress)"),
	short_description = S("Flat jack"),
	inventory_image = "[fill:16x16:#00000000^[fill:12x3:2,7:#b8bcc2^[fill:12x1:2,6:#8a8e92^[fill:12x1:2,10:#8a8e92^[fill:2x6:13,4:#3a3a3a^[fill:3x2:12,2:#c03020",
	stack_max = 1,
	on_place = function(itemstack, player, pointed)
		if not (player and player:is_player()) or pointed.type ~= "node" then return itemstack end
		local pos, n = pointed.under, vector.subtract(pointed.above, pointed.under)
		if not rockmech.lith_of_node[core.get_node(pos).name] then bubble(player, {S("Use it on a rock face")}, pos); return itemstack end
		if n.y ~= 0 then bubble(player, {S("Use it on a wall, not the floor or roof")}, pos); return itemstack end
		local r = rockmech.stress_report(pos)
		local i = r.init
		local horizontal_slot = itemstack:get_meta():get_string("slot") == "h"
		local val, what
		if horizontal_slot then
			val, what = noisy(i.sv or 0), S("vertical stress")
		else
			-- 沿著牆面的水平方向 t 上的初始水平應力：σH cos²θ + σh sin²θ（θ：t 跟 σH 方位的夾角）
			local az = math.rad(cfg.sH_azimuth or 0)
			local cth = math.abs(-n.z * math.sin(az) + n.x * math.cos(az))
			val, what = noisy(((i.sH or 0) * cth * cth + (i.shmin or 0) * (1 - cth * cth))), S("horizontal stress along the wall")
		end
		local slot = horizontal_slot and S("horizontal slot") or S("vertical slot")
		local txt = S("Flat jack (@1): @2 @3 MPa", slot, what, mpa(val))
		local ok = record(player, pos, r.lith, txt)
		bubble(player, {txt, ok and S("Written into the field notebook") or S("No field notebook: not recorded")}, pos)
		return itemstack
	end,
})

-- E：切換槽的方向（拿著平板千斤頂、沒坐在車上；按下去那一下才算）
local e_down = {}
core.register_globalstep(function()
	for _, pl in ipairs(core.get_connected_players()) do
		local name = pl:get_player_name()
		local e = pl:get_player_control().aux1
		if e and not e_down[name] and not pl:get_attach() then
			local st = pl:get_wielded_item()
			if st:get_name() == FLATJACK then
				local h = st:get_meta():get_string("slot") ~= "h"
				st:get_meta():set_string("slot", h and "h" or "")
				st:get_meta():set_string("description", h and S("Flat jack (horizontal slot: vertical stress)") or "")
				pl:set_wielded_item(st)
				bubble(pl, {h and S("Horizontal slot: measures vertical stress") or S("Vertical slot: measures horizontal stress along the wall")})
			end
		end
		e_down[name] = e
	end
end)
core.register_on_leaveplayer(function(pl) e_down[pl:get_player_name()] = nil end)

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
		local i = r.init
		local sv, sH, sh = noisy(i.sv or 0), noisy(i.sH or 0), noisy(i.shmin or 0)
		local azm = (cfg.sH_azimuth or 0) + 5 * (math.random() + math.random() - 1)
		local txt = S("Stress cell @1 m deep: σv @2  σH @3  σh @4 MPa, σH azimuth @5°", ("%.0f"):format(depth), mpa(sv), mpa(sH), mpa(sh), ("%03.0f"):format(azm % 360))
		local ok = record(player, bottom, r.lith, txt)
		bubble(player, {txt, ok and S("Written into the field notebook") or S("No field notebook: not recorded")}, hp)
		return itemstack
	end,
})
