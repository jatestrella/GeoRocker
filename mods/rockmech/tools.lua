-- rockmech/tools.lua
-- 除錯／地質工具（引擎端）：
--   rockmech:compass     地質羅盤，右鍵一格顯示岩性、深度、應力與六個面的節理
--   /rockmech_traces [r] 以 particle 標示附近臨空面上的節理跡線
--   /rockmech_failure    軸差破壞檢查（回報／apply）
--   /convert_rocks       stone 依深度換成岩性；既有岩性依目前節理設定重新上材質（舊世界用）
--   方位 HUD             畫面上方顯示面向（沿用 physics_core）
--   物品欄「rockmech」分頁 / /rockmech_toggle   遊戲中開關（破壞準則、安息角滑動、翻滾）

local cfg = rockmech.cfg
local S = rockmech.S

-- rockmech 管理權限：遊戲中開關、轉換岩石、測試指令。
-- Luanti 5.x 單人模式不會給 server 權限，所以另設一個單人模式自動擁有的權限。
core.register_privilege("rockmech", {
	description = S("Can use rockmech admin commands and in-game toggles"),
	give_to_singleplayer = true,
	give_to_admin = true,
})
local joints = rockmech.joints
local stress = rockmech.stress

local FACE_LABEL = {
	E = "E (+x)", W = "W (-x)", Up = S("Up (+y)"), Dn = S("Down (-y)"), N = "N (+z)", S = "S (-z)",
}

local function fmt_pos(p)
	return ("(%d,%d,%d)"):format(p.x, p.y, p.z)
end

-- 組合羅盤報告（回傳多行字串）
local function compass_report(pos, nodename, pname)
	local rm = not rockmech.can_see or rockmech.can_see(pname, "rockmass")    -- 岩性、材料性質要有岩體分類能力
	local sets = rockmech.get_joint_sets()
	local lines = {}
	local lith = rockmech.lith_of_node[nodename]
	local lith_note = ""
	if not lith then
		lith = rockmech.lith_at(pos.x, pos.y, pos.z)
		lith_note = " " .. core.colorize("#aaaaaa",
			S("[@1 is not a rockmech lithology; stress uses the layer at this depth, @2]", nodename, lith.name))
	end

	local st = rockmech.collapse.initial_stress(pos, lith)
	lines[#lines + 1] = core.colorize("#ffd080", S("[rockmech compass]")) .. " " .. fmt_pos(pos) ..
		"  " .. (rm and (S(lith.description) .. lith_note) or S("Rock (rock mass classification skill needed to identify the lithology)"))
	if rm then
		lines[#lines + 1] = "  " .. S("γ=@1 kN/m³  σci=@2 MPa  σt=@3 MPa  mi=@4 (intact rock)",
			("%.1f"):format(lith.gamma), ("%g"):format(lith.ucs), ("%g"):format(lith.tensile), ("%g"):format(lith.mi or 0))
	end
	lines[#lines + 1] = "  " .. S("Overburden h=@1 m (ground surface y=@2@3)  initial σv=Σγ·Δh=@4 MPa",
		("%d"):format(st.h), ("%d"):format(st.top_y), st.extrapolated and S(", extrapolated to y0") or "", ("%.3f"):format(st.sv))
	lines[#lines + 1] = "  " .. S("Initial horizontal principal stresses: σH=@1 (K_H=@2@3) σh=@4 (K_h=@5@6) MPa, σH azimuth @7°",
		("%.3f"):format(st.sH), ("%.2f"):format(cfg.KH), cfg.sH0 > 0 and ("+" .. cfg.sH0) or "",
		("%.3f"):format(st.shmin), ("%.2f"):format(cfg.Kh), cfg.sh0 > 0 and ("+" .. cfg.sh0) or "", ("%g"):format(cfg.sH_azimuth))

	-- 開挖後的局部應力與軸差破壞判定（只對本 mod 岩性）
	if rockmech.lith_of_node[nodename] then
		local w = 2 * cfg.failure.window + 1
		local grid = rockmech.collapse.read_grid(vector.subtract(pos, w), vector.add(pos, w))
		local fs = rockmech.failure.cell_state(grid, pos.x, pos.y, pos.z,
			rockmech.collapse.failure_params(true))
		if fs then
			lines[#lines + 1] = "  " .. S("Column load @1 → after spreading @2 MPa (×@3) @4",
				("%.3f"):format(fs.sv0), ("%.3f"):format(fs.sv), ("%.2f"):format(fs.factor), fs.exposed and S("(exposed)") or "")
			lines[#lines + 1] = ("  σxx=%.3f (×%.2f) σyy=%.3f σzz=%.3f (×%.2f) σxz=%.3f → σ1=%.3f σ3=%.3f MPa"):format(
				fs.sx, fs.fx, fs.sy, fs.sz, fs.fz, fs.sxz, fs.s1, fs.s3)
			if (fs.p_support or 0) > 0 then
				lines[#lines + 1] = "  " .. S("Normal pressure on the exposed face (support pᵢ, rubble lateral pressure) @1 MPa",
					("%.3f"):format(fs.p_support))
			end
			local verdict
			if fs.fails_axial then
				verdict = core.colorize("#ff6060", S("failure"))
			elseif fs.q >= fs.strength then
				verdict = core.colorize("#ffb060", S("exceeds strength but not exposed"))
			else
				verdict = core.colorize("#80ff80", S("stable"))
			end
			if fs.rm then lines[#lines + 1] = "  " .. rockmech.rockmass_line(fs.rm) end
			lines[#lines + 1] = "  " .. S("q=σ1−σ3=@1 MPa  rock mass strength q_f(σ3)=@2 MPa  FS=@3  → @4",
				("%.3f"):format(fs.q), ("%.3f"):format(fs.strength), ("%.2f"):format(fs.fs_axial), verdict)
			lines[#lines + 1] = "  " .. rockmech.slip_line(fs)
			lines[#lines + 1] = "  " .. rockmech.overhang_line(not cfg.fem.drive and rockmech.collapse.overhang_state(pos) or nil)
			if cfg.keyblock.enabled then
				lines[#lines + 1] = "  " .. rockmech.keyblock_line(rockmech.collapse.keyblock_state(pos))
			end
		end
	end

	local eff = {}
	for _, js in ipairs(sets) do
		eff[#eff + 1] = core.colorize(js.color or "#ffffff",
			("%s %.0f°/%.0f° S=%.2fm"):format(js.name, js.dip_eff, js.dipdir_eff, js.spacing_eff))
	end
	lines[#lines + 1] = "  " .. S("Joint sets (snapped to the grid):") .. " " .. table.concat(eff, "  ")

	for _, face in ipairs(joints.FACES) do
		local fx, fy, fz, axis = joints.face_key(pos.x, pos.y, pos.z, face)
		local info = joints.face_info(sets, fx, fy, fz, axis)
		local parts = {}
		for _, it in ipairs(info) do
			local js = sets[it.set]
			if it.joint then
				parts[#parts + 1] = core.colorize(js.color or "#ffffff",
					S("@1 joint (k=@2, r=@3<P=@4)", js.name, ("%d"):format(it.k), ("%.2f"):format(it.r), ("%.2f"):format(js.persistence)))
			else
				parts[#parts + 1] = core.colorize("#888888",
					S("@1 rock bridge (k=@2, r=@3≥P=@4)", js.name, ("%d"):format(it.k), ("%.2f"):format(it.r), ("%.2f"):format(js.persistence)))
			end
		end
		lines[#lines + 1] = "  " .. FACE_LABEL[face.name] .. ": " ..
			(#parts > 0 and table.concat(parts, "; ") or S("intact"))
	end
	return table.concat(lines, "\n")
end

local compass_img = "[fill:16x16:#00000000" ..
	"^[fill:12x12:2,2:#6b4a2a^[fill:10x10:3,3:#e8e0c8" ..
	"^[fill:2x5:7,3:#d02020^[fill:2x4:7,8:#303030"

core.register_tool("rockmech:compass", {
	description = S("Geological compass\nRight-click a rock face; sneak for more"),
	short_description = S("Geological compass"),
	inventory_image = compass_img,
	stack_max = 1,
	on_place = function(itemstack, placer, pointed_thing)
		if not placer or not placer:is_player() then return end
		if pointed_thing.type ~= "node" then return end
		local pos = pointed_thing.under
		local node = core.get_node(pos)
		local name = placer:get_player_name()
		-- 平常只回應力與 FS；蹲下才看完整資料（應力解關閉時也一樣）
		if placer:get_player_control().sneak or not rockmech.cfg.fem.enabled then
			core.chat_send_player(name, compass_report(pos, node.name, name))
		elseif rockmech.lith_of_node[node.name] then
			rockmech.fem_request(pos, name)
		else
			rockmech.notify(name, core.colorize("#80d0ff", S("[Compass]")) .. " " .. S("This is not rock"))
		end
		return nil
	end,
})

---------------------------------------------------------------------------
-- 節理跡線顯示
---------------------------------------------------------------------------

-- content id → 是否為岩石／是否為實心（延遲建立，確保所有 node 已註冊）
local is_rock_cid, is_solid_cid
local function build_cid_tables()
	if is_rock_cid then return end
	is_rock_cid, is_solid_cid = {}, {}
	for name, def in pairs(core.registered_nodes) do
		local cid = core.get_content_id(name)
		is_solid_cid[cid] = def.walkable ~= false
		is_rock_cid[cid] = (def.groups and (def.groups.stone or 0) > 0) or false
	end
end

local MAX_PARTICLES = 4000

core.register_chatcommand("rockmech_traces", {
	params = S("[radius 1-16, default 8]"),
	description = S("Show joint traces on nearby exposed rock faces with particles (color = joint set)"),
	func = function(name, param)
		local player = core.get_player_by_name(name)
		if not player then return false, S("Player not found") end
		build_cid_tables()
		local sets = rockmech.get_joint_sets()

		local r = math.floor(tonumber(param) or 8)
		r = math.max(1, math.min(16, r))
		local c = vector.round(player:get_pos())
		local vm = core.get_voxel_manip()
		local emin, emax = vm:read_from_map(vector.subtract(c, r + 1), vector.add(c, r + 1))
		local area = VoxelArea(emin, emax)
		local data = vm:get_data()
		vm:close()

		local AX = joints.AXIS
		local count, seen = 0, {}
		local t0 = core.get_us_time()

		for z = c.z - r, c.z + r do
		for y = c.y - r, c.y + r do
		for x = c.x - r, c.x + r do
			local vi = area:index(x, y, z)
			if is_rock_cid[data[vi]] then
				-- 每個臨空方向 d
				for da = 1, 3 do
					for ds = -1, 1, 2 do
						local ed = AX[da]
						local ni = area:index(x + ds * ed[1], y + ds * ed[2], z + ds * ed[3])
						if not is_solid_cid[data[ni]] then
							-- 與臨空面垂直的側面
							for la = 1, 3 do
								if la ~= da then
									local el = AX[la]
									for ls = -1, 1, 2 do
										local qx, qy, qz = x + ls * el[1], y + ls * el[2], z + ls * el[3]
										if is_rock_cid[data[area:index(qx, qy, qz)]] then
											local fx, fy, fz = x, y, z
											if ls < 0 then fx, fy, fz = qx, qy, qz end
											local si = joints.face_joint(sets, fx, fy, fz, la)
											if si then
												local px = x + 0.5 * ls * el[1] + 0.52 * ds * ed[1]
												local py = y + 0.5 * ls * el[2] + 0.52 * ds * ed[2]
												local pz = z + 0.5 * ls * el[3] + 0.52 * ds * ed[3]
												local key = px .. "," .. py .. "," .. pz
												if not seen[key] and count < MAX_PARTICLES then
													seen[key] = true
													count = count + 1
													core.add_particle({
														pos = {x = px, y = py, z = pz},
														expirationtime = 20,
														size = 1.5,
														texture = "[fill:4x4:" .. (sets[si].color or "#ffffff"),
														glow = 14,
														playername = name,
													})
												end
											end
										end
									end
								end
							end
						end
					end
				end
			end
		end
		end
		end

		local ms = (core.get_us_time() - t0) / 1000
		local legend = {}
		for _, js in ipairs(sets) do
			legend[#legend + 1] = core.colorize(js.color or "#ffffff",
				("%s %.0f/%.0f S=%.1fm P=%.2f"):format(js.name, js.dip_eff, js.dipdir_eff, js.spacing_eff, js.persistence))
		end
		return true, S("@1 joint trace points (radius @2, @3 ms@4)  @5",
			("%d"):format(count), ("%d"):format(r), ("%.1f"):format(ms), count >= MAX_PARTICLES and S(", limit reached") or "",
			table.concat(legend, "  "))
	end,
})

---------------------------------------------------------------------------
-- /convert_rocks：既有世界中把玩家附近的 stone 依深度換成岩性
-- （沿用 physics_core 的指令名稱；原本是換成 2×2×2 大岩塊）
---------------------------------------------------------------------------

---------------------------------------------------------------------------
-- /rockmech_jointtex_demo：檢查節理材質方向
-- 在玩家前方放 6 個花崗岩，各只有一個面是節理面
---------------------------------------------------------------------------

core.register_chatcommand("rockmech_jointcube", {
	params = S("[edge length 3-15, default 7]"),
	description = S("Place a granite cube with joint traces in front of you (using the current joint sets and world seed)"),
	privs = {rockmech = true},
	func = function(name, param)
		local player = core.get_player_by_name(name)
		if not player then return false, S("Player not found") end
		local L = math.max(3, math.min(15, math.floor(tonumber(param) or 7)))
		local p = vector.round(player:get_pos())
		local x0, y0, z0 = p.x + 3, p.y, p.z - math.floor(L / 2)
		local sets = rockmech.get_joint_sets()
		local style = cfg.jointtex.style
		for x = x0, x0 + L - 1 do for y = y0, y0 + L - 1 do for z = z0, z0 + L - 1 do
			local n
			if style == "plane" then
				n = rockmech.plane_variant_name("granite", sets, x, y, z)
			else
				n = rockmech.lith_variant.granite[joints.cell_mask(sets, x, y, z)]
			end
			core.set_node({x = x, y = y, z = z}, {name = n})
		end end end
		local legend = {}
		for _, js in ipairs(sets) do
			legend[#legend + 1] = ("%s %.1f°/%.1f° S=%.2fm P=%.2f"):format(js.name, js.dip_eff, js.dipdir_eff, js.spacing_eff, js.persistence)
		end
		return true, S("[rockmech] Placed a @1³ granite cube at x=@2..@3, y=@4..@5, z=@6..@7 (style @8).\n  Check: each trace should be continuous across adjacent blocks and adjacent faces (e.g. top face to side face).\n  Joint sets: @9",
			tostring(L), tostring(x0), tostring(x0 + L - 1), tostring(y0), tostring(y0 + L - 1), tostring(z0), tostring(z0 + L - 1),
			style, table.concat(legend, "; "))
	end,
})

core.register_chatcommand("rockmech_jointtex_demo", {
	description = S("(For the edges style) Place 6 granite blocks in front of you, each with only one jointed face, to check texture orientation"),
	privs = {rockmech = true},
	func = function(name)
		local player = core.get_player_by_name(name)
		if not player then return false, S("Player not found") end
		local p = vector.round(player:get_pos())
		local M = joints.MASK
		local list = {
			{bit = M.E, label = S("east (+x)")}, {bit = M.W, label = S("west (−x)")},
			{bit = M.N, label = S("north (+z)")}, {bit = M.S, label = S("south (−z)")},
			{bit = M.Up, label = S("top (+y)")}, {bit = M.Dn, label = S("bottom (−y)")},
		}
		local lines = {S("[rockmech] Placing at x=@1, every 2 blocks northward from z=@2 (y=@3):",
			tostring(p.x + 3), tostring(p.z - 5), tostring(p.y + 2))}
		for i, it in ipairs(list) do
			local q = {x = p.x + 3, y = p.y + 2, z = p.z - 5 + (i - 1) * 2}
			core.set_node(q, {name = rockmech.lith_variant.granite[it.bit]})
			lines[#lines + 1] = "  " .. S("No. @1 (z=@2): only the @3 face is jointed → that face is rust-colored, and its four neighboring faces have a dark line along the edge next to it",
				tostring(i), tostring(q.z), it.label)
		end
		lines[#lines + 1] = "  " .. S("(The placed blocks float in the air; digging nearby triggers the support check and makes them fall)")
		return true, table.concat(lines, "\n")
	end,
})

-- 轉換 [p1, p2]：default:stone 依深度換成岩性；既有岩性（任何材質變體）保留岩性、
-- 依目前節理設定重新選材質變體。回傳 n_stone, n_rock, n_changed, ms
function rockmech.convert_area(p1, p2)
		local t0 = core.get_us_time()

		local vm = core.get_voxel_manip()
		local emin, emax = vm:read_from_map(p1, p2)
		local area = VoxelArea(emin, emax)
		local data = vm:get_data()

		local c_stone = core.registered_nodes["default:stone"] and core.get_content_id("default:stone")
		-- content id → 岩性名稱（含所有材質變體）
		local lith_of_cid = {}
		for _, n in ipairs(rockmech.lith_nodes) do
			lith_of_cid[core.get_content_id(n)] = rockmech.lith_of_node[n].name
		end
		local sets = rockmech.get_joint_sets()
		local use_joints = cfg.jointtex.enabled and cfg.jointtex.style ~= "mesh"
		local plane = use_joints and cfg.jointtex.style == "plane"
		local cid_cache = {}
		local function variant_cid(key, x, y, z)
			local n
			if plane then
				n = rockmech.plane_variant_name(key, sets, x, y, z)
			else
				n = rockmech.lith_variant[key][use_joints and joints.cell_mask(sets, x, y, z) or 0]
			end
			local cid = cid_cache[n]
			if not cid then cid = core.get_content_id(n); cid_cache[n] = cid end
			return cid
		end

		local n_stone, n_rock, n_changed = 0, 0, 0
		for z = p1.z, p2.z do
			for y = p1.y, p2.y do
				local vi = area:index(p1.x, y, z)
				for x = p1.x, p2.x do
					local cid = data[vi]
					local key = lith_of_cid[cid]
					if cid == c_stone then
						data[vi] = variant_cid(rockmech.lith_at(x, y, z).name, x, y, z)
						n_stone = n_stone + 1
					elseif key then
						local new = variant_cid(key, x, y, z)
						n_rock = n_rock + 1
						if new ~= cid then
							data[vi] = new
							n_changed = n_changed + 1
						end
					end
					vi = vi + 1
				end
			end
		end

		-- VoxelManip 寫入不會呼叫 on_destruct，不會觸發坍塌
		if n_stone + n_changed > 0 then
			vm:set_data(data)
			vm:write_to_map(false)
		end
		vm:close()
		return n_stone, n_rock, n_changed, (core.get_us_time() - t0) / 1000
end

-- 移除 [p1, p2] 內的土壤（config.is_soil），露出岩盤。回傳移除格數, ms
function rockmech.strip_soil_area(p1, p2)
	local t0 = core.get_us_time()
	local strip = {}
	for name, def in pairs(core.registered_nodes) do
		if rockmech.config.is_soil(name, def.groups, def.is_ground_content) then
			strip[core.get_content_id(name)] = true
		end
	end
	local c_air = core.get_content_id("air")
	local vm = core.get_voxel_manip()
	local e1, e2 = vm:read_from_map(p1, p2)
	local area = VoxelArea(e1, e2)
	local data = vm:get_data()
	local n = 0
	for i in area:iterp(p1, p2) do
		if strip[data[i]] then
			data[i] = c_air
			n = n + 1
		end
	end
	if n > 0 then
		vm:set_data(data)
		vm:write_to_map(true)   -- 重算光照
		vm:update_liquids()     -- 讓水流進移除後的空間
	end
	vm:close()
	return n, (core.get_us_time() - t0) / 1000
end

core.register_chatcommand("rockmech_strip_soil", {
	params = S("[radius, default 20, max 64]"),
	description = S("Remove nearby soil (dirt, sand, gravel, clay, snow) to expose bedrock"),
	privs = {rockmech = true},
	func = function(name, param)
		local player = core.get_player_by_name(name)
		if not player then return false, S("Player not found") end
		local R = math.max(1, math.min(64, math.floor(tonumber(param) or 20)))
		local c = vector.round(player:get_pos())
		local n, ms = rockmech.strip_soil_area(vector.subtract(c, R), vector.add(c, R))
		return true, S("Radius @1: removed @2 soil blocks (@3 ms)", tostring(R), tostring(n), ("%.0f"):format(ms))
	end,
})

core.register_chatcommand("convert_rocks", {
	params = S("[radius, default 20, max 48]"),
	description = S("Convert nearby default:stone to rockmech lithologies by depth, and re-apply joint textures to existing lithology blocks using the current joint settings"),
	privs = {rockmech = true},
	func = function(name, param)
		local player = core.get_player_by_name(name)
		if not player then return false, S("Player not found") end
		local R = math.max(1, math.min(48, math.floor(tonumber(param) or 20)))
		local c = vector.round(player:get_pos())
		local n_stone, n_rock, n_changed, ms = rockmech.convert_area(vector.subtract(c, R), vector.add(c, R))
		return true, S("Radius @1: stone → lithology @2 blocks; existing lithology @3 blocks, of which @4 got updated joint textures (@5 ms)",
			tostring(R), tostring(n_stone), tostring(n_rock), tostring(n_changed), ("%.0f"):format(ms))
	end,
})

---------------------------------------------------------------------------
-- 方位 HUD（沿用 physics_core）
---------------------------------------------------------------------------

local player_huds = {}

local function get_direction_text(player)
	local angle = player:get_look_horizontal()
	local degrees = (math.deg(angle) % 360)
	if degrees >= 315 or degrees < 45 then return S("North (+Z)")
	elseif degrees >= 45 and degrees < 135 then return S("West (-X)")
	elseif degrees >= 135 and degrees < 225 then return S("South (-Z)")
	else return S("East (+X)") end
end

core.register_on_joinplayer(function(player)
	local name = player:get_player_name()
	player_huds[name] = player:hud_add({
		type = "text", position = {x = 0.5, y = 0.05},
		text = S("Heading: updating..."), number = 0xFFFFFF,
	})
end)

core.register_on_leaveplayer(function(player)
	player_huds[player:get_player_name()] = nil
end)

core.register_globalstep(function(dtime)
	for _, player in ipairs(core.get_connected_players()) do
		local name = player:get_player_name()
		if player_huds[name] then
			player:hud_change(player_huds[name], "text", S("Heading: @1", get_direction_text(player)))
		end
	end
end)

---------------------------------------------------------------------------
-- /rockmech_failure：對目前位置強制執行一次軸差破壞檢查
---------------------------------------------------------------------------

core.register_chatcommand("rockmech_failure", {
	params = S("[radius] [apply]"),
	description = S("Deviatoric failure check (by default only reports, does not change the map; add apply to actually spall)"),
	func = function(name, param)
		local player = core.get_player_by_name(name)
		if not player then return false, S("Player not found") end
		local r = cfg.failure.radius
		local apply = false
		for tok in (param or ""):gmatch("%S+") do
			if tok == "apply" then apply = true
			elseif tonumber(tok) then r = math.max(1, math.min(32, math.floor(tonumber(tok)))) end
		end
		local c = vector.round(player:get_pos())
		local failed, stats, ms = rockmech.collapse.evaluate_failure({c}, r)
		local msg = S("@1 exposed rock cells, @2 failed, @3 ms (radius @4, scale ratio N @5)",
			tostring(stats.evaluated), tostring(stats.failed), ("%.1f"):format(ms), tostring(r), ("%g"):format(cfg.model_scale))
		local s = stats.min_fs_state
		if s then
			local p = stats.min_fs_pos
			local f2 = function(v) return ("%.2f"):format(v) end
			msg = msg .. "\n  " .. S("Lowest FS=@1 @ @2 @3 h=@4 m", f2(s.fs), fmt_pos(p), tostring(s.lith), ("%.0f"):format(s.h)) ..
				"  " .. S("column load=@1 ×@2  σ1=@3 σ3=@4  q=@5 / strength @6 MPa",
					f2(s.sv0), f2(s.factor), f2(s.s1), f2(s.s3), f2(s.q), f2(s.strength))
		end
		if apply and #failed > 0 then
			rockmech.collapse.apply_failure(failed)
			msg = msg .. "\n  " .. S("Turned @1 cells into rubble (one round only, no cascade)", tostring(#failed))
		end
		return true, msg
	end,
})

---------------------------------------------------------------------------
-- 遊戲中開關：破壞準則、翻滾落石
-- 即時生效，並存入 mod storage（重開世界後保留）。設定選單中的
-- rockmech_failure_enabled / rockmech_rockfall_enabled 只作為尚未在遊戲中
-- 切換過時的預設值。
---------------------------------------------------------------------------

local storage = core.get_mod_storage()
local TOGGLE_PRIV = "rockmech"

-- 開關表（依顯示順序）
local TOGGLES = {
	{
		id = "failure", tbl = cfg.failure,
		label = S("Deviatoric failure criterion  Hoek-Brown rock mass strength (GSI)"),
		short = S("Deviatoric failure criterion"),
		info = function()
			local f = cfg.failure
			return S("Scale ratio N @1, check radius @2 m, cascade limit @3 rounds",
				("%g"):format(cfg.model_scale), tostring(f.radius), tostring(f.max_cascade))
		end,
		off_note = S("Off: intact rock never fails (unsupported rock only falls when completely isolated)"),
	},
	{
		id = "keyblock", tbl = cfg.keyblock,
		label = S("Key blocks (joint-bounded blocks fall / slide on a plane / slide as a wedge under gravity)"),
		short = S("Key blocks"),
		info = function()
			return S("Block limit @1 cells; block boundary joints c @2 MPa, φj @3°",
				tostring(cfg.keyblock.max_cells), ("%g"):format(cfg.keyblock.c), ("%g"):format(cfg.weakness.phi))
		end,
		off_note = S("Off: joint-bounded blocks never slide out under gravity"),
	},
	{
		id = "induced", tbl = cfg.induced,
		label = S("Only excavation-induced deterioration causes failure (generated terrain is treated as in equilibrium)"),
		short = S("Excavation-induced failure only"),
		info = function()
			return S("Compares before and after excavation: fails only if FS > 1 before and FS ≤ 1 after (pre-existing instability only falls once completely unsupported)")
		end,
		off_note = S("Off: nearby rock that already has FS ≤ 1 fails as soon as it is triggered"),
	},
	{
		id = "weakness", tbl = cfg.weakness,
		label = S("Joint plane sliding  τ ≥ cj + σn·tan φj"),
		short = S("Joint plane sliding"),
		info = function()
			local w = cfg.weakness
			return S("cj @1 MPa, φj @2° (same for all three sets); @3", ("%g"):format(w.c), ("%g"):format(w.phi),
				w.daylight and S("must dip toward the free face (lateral limit ±@1°)", ("%g"):format(w.lateral_limit)) or S("no kinematic check"))
		end,
		off_note = S("Off: joints do not affect strength (deviatoric failure only)"),
	},
	{
		id = "blast", tbl = cfg.blast,
		label = S("TNT blast fragmentation (by rock strength)"),
		short = S("Blast fragmentation"),
		info = function()
			return S("Fragmentation radius = blast radius × (@1/UCS)^@2; inner @3% ejected", ("%g"):format(cfg.blast.ucs_ref),
				tostring(cfg.blast.ucs_exp), ("%d"):format(math.floor(cfg.blast.inner * 100 + 0.5)))
		end,
		off_note = S("Off: rock is unaffected by TNT (only other blocks are blown away)"),
	},
	{
		id = "overhang", tbl = cfg.overhang,
		label = S("Cantilever / roof fracture (by tensile strength and thickness)"),
		short = S("Cantilever fracture"),
		info = function()
			return S("L_max = √(σt,m·t/(3γ)), σt,m from GSI and N; @1",
				cfg.overhang.joints and S("root sections cut by joints carry no tension") or S("joints not considered"))
		end,
		off_note = S("Off: overhanging rock attached to the rock mass never breaks from being too long"),
	},
	{
		id = "fallbreak", tbl = cfg.fallbreak,
		label = S("Intact rock may turn into rubble when it falls"),
		short = S("Breakage on falling"),
		info = function() return S("Probability p = 1 − exp(−fall height / h_ref), h_ref depends on lithology") end,
		off_note = S("Off: intact rock stays intact after falling"),
	},
	{
		id = "slope", tbl = cfg.slope,
		label = S("Rubble granular flow (8 levels per cell, spreads into slopes at the angle of repose; intact rock unaffected)"),
		short = S("Rubble granular flow"),
		info = function() return S("Angle of repose @1°; unsupported rubble still falls vertically", ("%g"):format(cfg.slope.angle)) end,
		off_note = S("Off: rubble does not move even beyond the angle of repose"),
	},
	{
		id = "rockfall", tbl = cfg.rockfall,
		label = S("Show key blocks that slide out as tumbling rockfall"),
		short = S("Tumbling rockfall"),
		info = function()
			return S("@1 currently tumbling, limit @2",
				tostring(rockmech.rockfall_entity and rockmech.rockfall_entity.active_count() or 0),
				tostring(cfg.rockfall.max_active))
		end,
		off_note = S("Off: key blocks that slide out turn into rubble in place, then flow at the angle of repose"),
	},
}
rockmech.toggles = TOGGLES
local TOGGLE_BY_ID = {}
for _, t in ipairs(TOGGLES) do
	TOGGLE_BY_ID[t.id] = t
	local saved = storage:get_string(t.id .. "_enabled")
	if saved == "true" then
		t.tbl.enabled = true
	elseif saved == "false" then
		t.tbl.enabled = false
	end
end

-- 切換開關。回傳 ok, 訊息
function rockmech.set_toggle(id, on, by_name)
	local t = TOGGLE_BY_ID[id]
	if not t then return false, S("No such toggle: @1", tostring(id)) end
	if by_name and not core.check_player_privs(by_name, {[TOGGLE_PRIV] = true}) then
		return false, S("You need the @1 privilege to change this", TOGGLE_PRIV)
	end
	t.tbl.enabled = on and true or false
	storage:set_string(id .. "_enabled", tostring(t.tbl.enabled))
	local state = t.tbl.enabled and "開啟" or "關閉"   -- 只給 log
	core.log("action", ("[rockmech] %s 將%s%s"):format(by_name or "?", t.id, state))
	return true, t.tbl.enabled and S("@1: on", t.short) or S("@1: off", t.short)
end

local ids = {}
for _, t in ipairs(TOGGLES) do ids[#ids + 1] = t.id end

core.register_chatcommand("rockmech_toggle", {
	params = "<" .. table.concat(ids, "|") .. "> [on|off]",
	description = S("In-game toggle (switches if on/off is omitted)"),
	privs = {[TOGGLE_PRIV] = true},
	func = function(name, param)
		local id, state = param:match("^%s*(%S+)%s*(%S*)")
		local t = id and TOGGLE_BY_ID[id]
		if not t then
			return false, S("Usage: /rockmech_toggle <@1> [on|off]", table.concat(ids, "|"))
		end
		local on
		if state == "on" then on = true
		elseif state == "off" then on = false
		elseif state == "" then on = not t.tbl.enabled
		else return false, S("State must be on or off") end
		return rockmech.set_toggle(id, on, name)
	end,
})

-- 物品欄分頁（需要 sfinv；devtest 等沒有 sfinv 的遊戲改用 /rockmech_toggle）
if core.get_modpath("sfinv") and sfinv then
	local F = core.formspec_escape

	sfinv.register_page("rockmech:settings", {
		title = "rockmech",
		-- 經營模式：除錯用的開關頁只給開了 /god 或有 server 權限的人
		is_in_nav = function(self, player)
			return not rockmech.debug_allowed or rockmech.debug_allowed(player:get_player_name())
		end,
		get = function(self, player, context)
			local can = core.check_player_privs(player, {[TOGGLE_PRIV] = true})
			-- 精簡版：每個開關一行；說明與數值在完整資訊頁
			local parts = {"label[0,0;", F(S("Rock mechanics toggles (take effect immediately)")), "]"}
			local y = 0.6
			for _, t in ipairs(TOGGLES) do
				parts[#parts + 1] = ("checkbox[0,%g;rm_%s;%s;%s]"):format(
					y, t.id, F(t.label), tostring(t.tbl.enabled))
				y = y + 0.75
			end
			if not can then
				parts[#parts + 1] = ("label[0,%g;%s]"):format(y,
					F(S("(You need the @1 privilege to change these)", TOGGLE_PRIV)))
				y = y + 0.6
			end
			-- 個人顯示設定（不需要權限）
			if rockmech.fsmask_live then
				parts[#parts + 1] = ("checkbox[0,%g;rm_fsmask;%s;%s]"):format(y,
					F(S("Mark rock cells with FS ≤ 1 around you (personal display)")), tostring(rockmech.fsmask_live(player)))
				y = y + 0.75
				parts[#parts + 1] = ("checkbox[0,%g;rm_fswarn;%s;%s]"):format(y,
					F(S("Warning cracks: 1 < FS < @1 after being affected (personal display)", ("%g"):format(cfg.fswarn.max))), tostring(rockmech.fswarn_enabled(player)))
				y = y + 0.75
			end
			parts[#parts + 1] = ("button[0,%g;5,0.8;rm_open;%s]"):format(y + 0.2, F(S("Full info page (/rockmech)")))
			return sfinv.make_formspec(player, context, table.concat(parts), false)
		end,
		on_player_receive_fields = function(self, player, context, fields)
			local name = player:get_player_name()
			if fields.rm_open and rockmech.show_info then
				rockmech.show_info(name)
				return true
			end
			local handled = false
			if fields.rm_fsmask and rockmech.set_fsmask_live then
				rockmech.set_fsmask_live(player, fields.rm_fsmask == "true")
				handled = true
			end
			if fields.rm_fswarn and rockmech.set_fswarn then
				rockmech.set_fswarn(player, fields.rm_fswarn == "true")
				handled = true
			end
			for _, t in ipairs(TOGGLES) do
				local v = fields["rm_" .. t.id]
				if v ~= nil then
					local _, msg = rockmech.set_toggle(t.id, v == "true", name)
					rockmech.notify(name, "[rockmech] " .. msg)
					handled = true
				end
			end
			if handled then
				sfinv.set_player_inventory_formspec(player)
				return true
			end
		end,
	})
end

---------------------------------------------------------------------------
-- /rockmech_orient：材質方向測試方塊
-- 6 面各畫一個「F」（不對稱：鏡像或旋轉一看就知道），底色區分是哪一面。
-- 用來確認 joints.TILE_EDGES / jointtex.FACES 的貼圖方向假設。
---------------------------------------------------------------------------

do
	local F = "^[fill:2x10:4,3:#000000^[fill:8x2:4,3:#000000^[fill:6x2:4,7:#000000"
	local FACE_COLORS = {
		{"top", "#ffffff"}, {"bottom", "#404040"}, {"east", "#e04040"},
		{"west", "#40c040"}, {"north", "#4080ff"}, {"south", "#f0d020"},
	}
	local tiles = {}
	for i, fc in ipairs(FACE_COLORS) do
		tiles[i] = "[fill:16x16:" .. fc[2] .. F
	end
	core.register_node("rockmech:orient_test", {
		description = S("Texture orientation test block (/rockmech_orient)"),
		tiles = tiles,
		groups = {cracky = 3, oddly_breakable_by_hand = 3, not_in_creative_inventory = 1},
	})

	core.register_chatcommand("rockmech_orient", {
		description = S("Place texture orientation test blocks in front of you (an F on each of the 6 faces, colors tell the faces apart)"),
		privs = {rockmech = true},
		func = function(name)
			local player = core.get_player_by_name(name)
			if not player then return false, S("Player not found") end
			local p = vector.round(player:get_pos())
			-- 放兩個：一個在眼睛高度（看側面與頂面），一個在頭頂上方（看底面）
			local a = {x = p.x + 2, y = p.y + 1, z = p.z}
			local b = {x = p.x + 2, y = p.y + 3, z = p.z + 2}
			core.set_node(a, {name = "rockmech:orient_test"})
			core.set_node(b, {name = "rockmech:orient_test"})
			return true, table.concat({
				S("[rockmech] Placed two test blocks to the east (one at eye level, one above so you can see its bottom face)."),
				"  " .. S("Colors: top=white bottom=dark gray east=red west=green north=blue south=yellow"),
				"  " .. S("My assumption (tell me which face doesn't match):"),
				"  " .. S("・Red, green, blue, yellow (the four sides): seen from outside, a normal 'F' (upright, not mirrored)"),
				"  " .. S("・White (top face): looking down while facing north, a normal 'F' (top of the F points north)"),
				"  " .. S("・Dark gray (bottom face): standing below, facing north and looking up, a normal 'F'"),
				"  " .. S("(The HUD at the top right shows your heading)"),
			}, "\n")
		end,
	})
end
