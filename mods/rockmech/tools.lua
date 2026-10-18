-- rockmech/tools.lua
-- 除錯／地質工具（引擎端）：
--   rockmech:compass     地質羅盤，右鍵一格顯示岩性、深度、應力與六個面的節理
--   /rockmech_traces [r] 以 particle 標示附近臨空面上的節理跡線
--   /rockmech_failure    軸差破壞檢查（回報／apply）
--   /convert_rocks       stone 依深度換成岩性；既有岩性依目前節理設定重新上材質（舊世界用）
--   方位 HUD             畫面上方顯示面向（沿用 physics_core）
--   物品欄「rockmech」分頁 / /rockmech_toggle   遊戲中開關（破壞準則、安息角滑動、翻滾）

local cfg = rockmech.cfg

-- rockmech 管理權限：遊戲中開關、轉換岩石、測試指令。
-- Luanti 5.x 單人模式不會給 server 權限，所以另設一個單人模式自動擁有的權限。
core.register_privilege("rockmech", {
	description = "可使用 rockmech 的管理指令與遊戲中開關",
	give_to_singleplayer = true,
	give_to_admin = true,
})
local joints = rockmech.joints
local stress = rockmech.stress

local FACE_LABEL = {
	E = "E (+x)", W = "W (-x)", Up = "上 (+y)", Dn = "下 (-y)", N = "N (+z)", S = "S (-z)",
}

local function fmt_pos(p)
	return ("(%d,%d,%d)"):format(p.x, p.y, p.z)
end

-- 組合羅盤報告（回傳多行字串）
local function compass_report(pos, nodename)
	local sets = rockmech.get_joint_sets()
	local lines = {}
	local lith = rockmech.lith_of_node[nodename]
	local lith_note = ""
	if not lith then
		lith = rockmech.lith_at(pos.x, pos.y, pos.z)
		lith_note = core.colorize("#aaaaaa",
			(" [%s 非本 mod 岩性，應力以該深度分層 %s 計]"):format(nodename, lith.name))
	end

	local st = rockmech.collapse.initial_stress(pos, lith)
	lines[#lines + 1] = core.colorize("#ffd080", "[rockmech 羅盤] ") .. fmt_pos(pos) ..
		"  " .. lith.description .. lith_note
	lines[#lines + 1] = ("  γ=%.1f kN/m³  σci=%g MPa  σt=%g MPa  mi=%g（完整岩石）"):format(
		lith.gamma, lith.ucs, lith.tensile, lith.mi or 0)
	lines[#lines + 1] = ("  上覆岩層 h=%d m（地表 y=%d%s）  初始 σv=Σγ·Δh=%.3f MPa"):format(
		st.h, st.top_y, st.extrapolated and "，外插至 y0" or "", st.sv)
	lines[#lines + 1] = ("  初始水平主應力：σH=%.3f（K_H=%.2f%s）σh=%.3f（K_h=%.2f%s）MPa，σH 方位 %g°"):format(
		st.sH, cfg.KH, cfg.sH0 > 0 and ("+" .. cfg.sH0) or "",
		st.shmin, cfg.Kh, cfg.sh0 > 0 and ("+" .. cfg.sh0) or "", cfg.sH_azimuth)

	-- 開挖後的局部應力與軸差破壞判定（只對本 mod 岩性）
	if rockmech.lith_of_node[nodename] then
		local w = 2 * cfg.failure.window + 1
		local grid = rockmech.collapse.read_grid(vector.subtract(pos, w), vector.add(pos, w))
		local fs = rockmech.failure.cell_state(grid, pos.x, pos.y, pos.z,
			rockmech.collapse.failure_params(true))
		if fs then
			lines[#lines + 1] = ("  柱狀荷重 %.3f → 擴散後 %.3f MPa（×%.2f）%s"):format(
				fs.sv0, fs.sv, fs.factor, fs.exposed and "（臨空）" or "")
			lines[#lines + 1] = ("  σxx=%.3f（×%.2f）σyy=%.3f σzz=%.3f（×%.2f）σxz=%.3f → σ1=%.3f σ3=%.3f MPa"):format(
				fs.sx, fs.fx, fs.sy, fs.sz, fs.fz, fs.sxz, fs.s1, fs.s3)
			local verdict
			if fs.fails_axial then
				verdict = core.colorize("#ff6060", "破壞")
			elseif fs.q >= fs.strength then
				verdict = core.colorize("#ffb060", "超過強度但未臨空")
			else
				verdict = core.colorize("#80ff80", "穩定")
			end
			if fs.rm then lines[#lines + 1] = "  " .. rockmech.rockmass_line(fs.rm) end
			lines[#lines + 1] = ("  q=σ1−σ3=%.3f MPa  岩體強度 q_f(σ3)=%.3f MPa  FS=%.2f  → %s"):format(
				fs.q, fs.strength, fs.fs_axial, verdict)
			lines[#lines + 1] = "  " .. rockmech.slip_line(fs)
			lines[#lines + 1] = "  " .. rockmech.overhang_line(rockmech.collapse.overhang_state(pos))
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
	lines[#lines + 1] = "  節理組（格點對齊後）：" .. table.concat(eff, "  ")

	for _, face in ipairs(joints.FACES) do
		local fx, fy, fz, axis = joints.face_key(pos.x, pos.y, pos.z, face)
		local info = joints.face_info(sets, fx, fy, fz, axis)
		local parts = {}
		for _, it in ipairs(info) do
			local js = sets[it.set]
			if it.joint then
				parts[#parts + 1] = core.colorize(js.color or "#ffffff",
					("%s 節理 (k=%d, r=%.2f<P=%.2f)"):format(js.name, it.k, it.r, js.persistence))
			else
				parts[#parts + 1] = core.colorize("#888888",
					("%s 岩橋 (k=%d, r=%.2f≥P=%.2f)"):format(js.name, it.k, it.r, js.persistence))
			end
		end
		lines[#lines + 1] = "  " .. FACE_LABEL[face.name] .. ": " ..
			(#parts > 0 and table.concat(parts, "; ") or "完整")
	end
	return table.concat(lines, "\n")
end

local compass_img = "[fill:16x16:#00000000" ..
	"^[fill:12x12:2,2:#6b4a2a^[fill:10x10:3,3:#e8e0c8" ..
	"^[fill:2x5:7,3:#d02020^[fill:2x4:7,8:#303030"

core.register_tool("rockmech:compass", {
	description = "Geological compass (地質羅盤)\n右鍵岩面：岩性、深度、初始應力、六面節理",
	inventory_image = compass_img,
	stack_max = 1,
	on_place = function(itemstack, placer, pointed_thing)
		if not placer or not placer:is_player() then return end
		if pointed_thing.type ~= "node" then return end
		local pos = pointed_thing.under
		local node = core.get_node(pos)
		core.chat_send_player(placer:get_player_name(), compass_report(pos, node.name))
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
	params = "[半徑 1-16，預設 8]",
	description = "以 particle 顯示附近臨空岩面上的節理跡線（顏色 = 節理組）",
	func = function(name, param)
		local player = core.get_player_by_name(name)
		if not player then return false, "找不到玩家" end
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
		return true, ("節理跡線點 %d 個（半徑 %d，%.1f ms%s）  %s"):format(
			count, r, ms, count >= MAX_PARTICLES and "，已達上限" or "",
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
	params = "[邊長 3-15，預設 7]",
	description = "在前方放一個帶節理跡線的花崗岩立方體（依目前節理組與世界種子）",
	privs = {rockmech = true},
	func = function(name, param)
		local player = core.get_player_by_name(name)
		if not player then return false, "找不到玩家" end
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
		return true, ("[rockmech] 已在 x=%d..%d、y=%d..%d、z=%d..%d 放置 %d³ 花崗岩（樣式 %s）。\n" ..
			"  檢查：同一條跡線在相鄰方塊、相鄰面（例如頂面接側面）之間應連續。\n  節理組：%s"):format(
			x0, x0 + L - 1, y0, y0 + L - 1, z0, z0 + L - 1, L, style, table.concat(legend, "；"))
	end,
})

core.register_chatcommand("rockmech_jointtex_demo", {
	description = "（edges 樣式用）在前方放 6 個花崗岩方塊，各只有一個面是節理面，用來檢查材質方向",
	privs = {rockmech = true},
	func = function(name)
		local player = core.get_player_by_name(name)
		if not player then return false, "找不到玩家" end
		local p = vector.round(player:get_pos())
		local M = joints.MASK
		local list = {
			{bit = M.E, label = "東(+x)"}, {bit = M.W, label = "西(−x)"},
			{bit = M.N, label = "北(+z)"}, {bit = M.S, label = "南(−z)"},
			{bit = M.Up, label = "上(+y)"}, {bit = M.Dn, label = "下(−y)"},
		}
		local lines = {"[rockmech] 在 x=" .. (p.x + 3) .. "、z 由 " .. (p.z - 5) ..
			" 往北每隔 2 格放置（y=" .. (p.y + 2) .. "）："}
		for i, it in ipairs(list) do
			local q = {x = p.x + 3, y = p.y + 2, z = p.z - 5 + (i - 1) * 2}
			core.set_node(q, {name = rockmech.lith_variant.granite[it.bit]})
			lines[#lines + 1] = ("  第 %d 個（z=%d）：只有%s面是節理 → 該面為鏽色，與它相鄰的四個面在靠%s的邊上有深色線")
				:format(i, q.z, it.label, it.label)
		end
		lines[#lines + 1] = "  （放置的方塊浮在空中，附近挖掘會觸發支撐判定讓它掉落）"
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
		local use_joints = cfg.jointtex.enabled
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
	params = "[半徑，預設 20，上限 64]",
	description = "移除附近的土壤（泥土、沙、礫石、黏土、雪），露出岩盤",
	privs = {rockmech = true},
	func = function(name, param)
		local player = core.get_player_by_name(name)
		if not player then return false, "找不到玩家" end
		local R = math.max(1, math.min(64, math.floor(tonumber(param) or 20)))
		local c = vector.round(player:get_pos())
		local n, ms = rockmech.strip_soil_area(vector.subtract(c, R), vector.add(c, R))
		return true, ("半徑 %d：移除土壤 %d 格（%.0f ms）"):format(R, n, ms)
	end,
})

core.register_chatcommand("convert_rocks", {
	params = "[半徑，預設 20，上限 48]",
	description = "把附近的 default:stone 依深度換成 rockmech 岩性，並把既有岩性方塊依目前的節理設定重新上節理材質",
	privs = {rockmech = true},
	func = function(name, param)
		local player = core.get_player_by_name(name)
		if not player then return false, "找不到玩家" end
		local R = math.max(1, math.min(48, math.floor(tonumber(param) or 20)))
		local c = vector.round(player:get_pos())
		local n_stone, n_rock, n_changed, ms = rockmech.convert_area(vector.subtract(c, R), vector.add(c, R))
		return true, ("半徑 %d：stone → 岩性 %d 格；既有岩性 %d 格，其中 %d 格更新節理材質（%.0f ms）"):format(
			R, n_stone, n_rock, n_changed, ms)
	end,
})

---------------------------------------------------------------------------
-- 方位 HUD（沿用 physics_core）
---------------------------------------------------------------------------

local player_huds = {}

local function get_direction_text(player)
	local angle = player:get_look_horizontal()
	local degrees = (math.deg(angle) % 360)
	if degrees >= 315 or degrees < 45 then return "北 (+Z)"
	elseif degrees >= 45 and degrees < 135 then return "西 (-X)"
	elseif degrees >= 135 and degrees < 225 then return "南 (-Z)"
	else return "東 (+X)" end
end

core.register_on_joinplayer(function(player)
	local name = player:get_player_name()
	player_huds[name] = player:hud_add({
		type = "text", position = {x = 0.5, y = 0.05},
		text = "方位: 更新中...", number = 0xFFFFFF,
	})
end)

core.register_on_leaveplayer(function(player)
	player_huds[player:get_player_name()] = nil
end)

core.register_globalstep(function(dtime)
	for _, player in ipairs(core.get_connected_players()) do
		local name = player:get_player_name()
		if player_huds[name] then
			player:hud_change(player_huds[name], "text", "方位: " .. get_direction_text(player))
		end
	end
end)

---------------------------------------------------------------------------
-- /rockmech_failure：對目前位置強制執行一次軸差破壞檢查
---------------------------------------------------------------------------

core.register_chatcommand("rockmech_failure", {
	params = "[半徑] [apply]",
	description = "軸差破壞檢查（預設只回報，不改地圖；加 apply 才實際剝落）",
	func = function(name, param)
		local player = core.get_player_by_name(name)
		if not player then return false, "找不到玩家" end
		local r = cfg.failure.radius
		local apply = false
		for tok in (param or ""):gmatch("%S+") do
			if tok == "apply" then apply = true
			elseif tonumber(tok) then r = math.max(1, math.min(32, math.floor(tonumber(tok)))) end
		end
		local c = vector.round(player:get_pos())
		local failed, stats, ms = rockmech.collapse.evaluate_failure({c}, r)
		local msg = ("臨空岩格 %d 格，破壞 %d 格，%.1f ms（半徑 %d，相似比 N %g）"):format(
			stats.evaluated, stats.failed, ms, r, cfg.model_scale)
		local s = stats.min_fs_state
		if s then
			local p = stats.min_fs_pos
			msg = msg .. ("\n  最低 FS=%.2f @ (%d,%d,%d) %s h=%.0f m  柱荷重=%.2f ×%.2f  σ1=%.2f σ3=%.2f  q=%.2f / 強度 %.2f MPa")
				:format(s.fs, p.x, p.y, p.z, s.lith, s.h, s.sv0, s.factor, s.s1, s.s3, s.q, s.strength)
		end
		if apply and #failed > 0 then
			rockmech.collapse.apply_failure(failed)
			msg = msg .. "\n  已破壞為碎石 " .. #failed .. " 格（只做一輪，不連鎖）"
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
		label = "軸差破壞準則  Hoek-Brown 岩體強度（GSI）",
		short = "軸差破壞準則",
		info = function()
			local f = cfg.failure
			return ("相似比 N %g，檢查半徑 %d m，連鎖上限 %d 輪"):format(
				cfg.model_scale, f.radius, f.max_cascade)
		end,
		off_note = "關閉：完整岩石不會破壞（懸空時只有完全孤立才掉落）",
	},
	{
		id = "keyblock", tbl = cfg.keyblock,
		label = "關鍵塊體（被節理圍住的岩塊依重力落下／平面滑動／楔形滑動）",
		short = "關鍵塊體",
		info = function()
			return ("岩塊上限 %d 格；岩塊邊界節理 c %g MPa、φj %g°"):format(
				cfg.keyblock.max_cells, cfg.keyblock.c, cfg.weakness.phi)
		end,
		off_note = "關閉：被節理圍住的岩塊不會因重力滑出",
	},
	{
		id = "induced", tbl = cfg.induced,
		label = "只有開挖造成的惡化才破壞（生成的地形視為已平衡）",
		short = "只算開挖造成的破壞",
		info = function()
			return "比較開挖前後：只有開挖前 FS > 1、開挖後 FS ≤ 1 才破壞（既有的不穩定要到完全懸空才掉）"
		end,
		off_note = "關閉：附近原本就 FS ≤ 1 的岩體，一被觸發就會破壞",
	},
	{
		id = "weakness", tbl = cfg.weakness,
		label = "節理弱面滑動  τ ≥ cj + σn·tan φj",
		short = "節理弱面滑動",
		info = function()
			local w = cfg.weakness
			return ("cj %g MPa，φj %g°（三組相同）；%s"):format(w.c, w.phi,
				w.daylight and "需傾向臨空面" or "不檢查運動學")
		end,
		off_note = "關閉：節理不影響強度（只有軸差破壞）",
	},
	{
		id = "blast", tbl = cfg.blast,
		label = "TNT 爆破破碎（依岩石強度）",
		short = "爆破破碎",
		info = function()
			return ("破碎半徑 = 爆炸半徑 × (%g/UCS)^(1/3)；內 %d%% 炸飛"):format(cfg.blast.ucs_ref, cfg.blast.inner * 100)
		end,
		off_note = "關閉：岩石不受 TNT 影響（只炸掉其他方塊）",
	},
	{
		id = "overhang", tbl = cfg.overhang,
		label = "懸臂／頂板斷裂（依張力強度與厚度）",
		short = "懸臂斷裂",
		info = function()
			return ("L_max = √(σt,m·t/(3γ))，σt,m 依 GSI 與 N；%s"):format(
				cfg.overhang.joints and "節理切過的根部斷面不傳張力" or "不考慮節理")
		end,
		off_note = "關閉：連著岩體的懸空岩石不會因為伸太長而斷",
	},
	{
		id = "fallbreak", tbl = cfg.fallbreak,
		label = "完整岩石掉落時有機率變成碎石",
		short = "掉落破碎",
		info = function() return "機率 p = 1 − exp(−落下高度 / h_ref)，h_ref 依岩性" end,
		off_note = "關閉：完整岩石掉落後仍是完整岩石",
	},
	{
		id = "slope", tbl = cfg.slope,
		label = "碎石顆粒流（每格分 8 級，依安息角攤成斜坡；完整岩石不受影響）",
		short = "碎石顆粒流",
		info = function() return ("安息角 %g°；碎石懸空時仍會垂直落下"):format(cfg.slope.angle) end,
		off_note = "關閉：碎石超過安息角也不移動",
	},
	{
		id = "rockfall", tbl = cfg.rockfall,
		label = "關鍵塊體滑出時以翻滾落石呈現",
		short = "翻滾落石",
		info = function()
			return ("目前翻滾中 %d 顆，上限 %d"):format(
				rockmech.rockfall_entity and rockmech.rockfall_entity.active_count() or 0,
				cfg.rockfall.max_active)
		end,
		off_note = "關閉：滑出的關鍵塊體原地變成碎石，再依安息角流動",
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
	if not t then return false, "沒有這個開關: " .. tostring(id) end
	if by_name and not core.check_player_privs(by_name, {[TOGGLE_PRIV] = true}) then
		return false, "需要 " .. TOGGLE_PRIV .. " 權限才能切換"
	end
	t.tbl.enabled = on and true or false
	storage:set_string(id .. "_enabled", tostring(t.tbl.enabled))
	local state = t.tbl.enabled and "開啟" or "關閉"
	core.log("action", ("[rockmech] %s 將%s%s"):format(by_name or "?", t.short, state))
	return true, t.short .. "：" .. state
end

local ids = {}
for _, t in ipairs(TOGGLES) do ids[#ids + 1] = t.id end

core.register_chatcommand("rockmech_toggle", {
	params = "<" .. table.concat(ids, "|") .. "> [on|off]",
	description = "遊戲中開關（不加 on/off 則切換）",
	privs = {[TOGGLE_PRIV] = true},
	func = function(name, param)
		local id, state = param:match("^%s*(%S+)%s*(%S*)")
		local t = id and TOGGLE_BY_ID[id]
		if not t then
			return false, "用法：/rockmech_toggle <" .. table.concat(ids, "|") .. "> [on|off]"
		end
		local on
		if state == "on" then on = true
		elseif state == "off" then on = false
		elseif state == "" then on = not t.tbl.enabled
		else return false, "狀態只能是 on 或 off" end
		return rockmech.set_toggle(id, on, name)
	end,
})

-- 物品欄分頁（需要 sfinv；devtest 等沒有 sfinv 的遊戲改用 /rockmech_toggle）
if core.get_modpath("sfinv") and sfinv then
	local F = core.formspec_escape

	sfinv.register_page("rockmech:settings", {
		title = "rockmech",
		get = function(self, player, context)
			local can = core.check_player_privs(player, {[TOGGLE_PRIV] = true})
			-- 精簡版：每個開關一行；說明與數值在完整資訊頁
			local parts = {"label[0,0;", F("岩石力學開關（即時生效）"), "]"}
			local y = 0.6
			for _, t in ipairs(TOGGLES) do
				parts[#parts + 1] = ("checkbox[0,%g;rm_%s;%s;%s]"):format(
					y, t.id, F(t.label), tostring(t.tbl.enabled))
				y = y + 0.75
			end
			if not can then
				parts[#parts + 1] = ("label[0,%g;%s]"):format(y,
					F("（需要 " .. TOGGLE_PRIV .. " 權限才能修改）"))
				y = y + 0.6
			end
			-- 個人顯示設定（不需要權限）
			if rockmech.fsmask_live then
				parts[#parts + 1] = ("checkbox[0,%g;rm_fsmask;%s;%s]"):format(y,
					F("標出周圍 FS ≤ 1 的岩格（個人顯示）"), tostring(rockmech.fsmask_live(player)))
				y = y + 0.75
				parts[#parts + 1] = ("checkbox[0,%g;rm_fswarn;%s;%s]"):format(y,
					F(("警戒裂紋：受影響後 1 < FS < %g（個人顯示）"):format(cfg.fswarn.max)), tostring(rockmech.fswarn_enabled(player)))
				y = y + 0.75
			end
			parts[#parts + 1] = ("button[0,%g;5,0.8;rm_open;%s]"):format(y + 0.2, F("完整資訊頁（/rockmech）"))
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
					core.chat_send_player(name, "[rockmech] " .. msg)
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
		{"上", "#ffffff"}, {"下", "#404040"}, {"東", "#e04040"},
		{"西", "#40c040"}, {"北", "#4080ff"}, {"南", "#f0d020"},
	}
	local tiles = {}
	for i, fc in ipairs(FACE_COLORS) do
		tiles[i] = "[fill:16x16:" .. fc[2] .. F
	end
	core.register_node("rockmech:orient_test", {
		description = "材質方向測試方塊（/rockmech_orient）",
		tiles = tiles,
		groups = {cracky = 3, oddly_breakable_by_hand = 3, not_in_creative_inventory = 1},
	})

	core.register_chatcommand("rockmech_orient", {
		description = "在前方放材質方向測試方塊（6 面各一個 F，顏色區分哪一面）",
		privs = {rockmech = true},
		func = function(name)
			local player = core.get_player_by_name(name)
			if not player then return false, "找不到玩家" end
			local p = vector.round(player:get_pos())
			-- 放兩個：一個在眼睛高度（看側面與頂面），一個在頭頂上方（看底面）
			local a = {x = p.x + 2, y = p.y + 1, z = p.z}
			local b = {x = p.x + 2, y = p.y + 3, z = p.z + 2}
			core.set_node(a, {name = "rockmech:orient_test"})
			core.set_node(b, {name = "rockmech:orient_test"})
			return true, table.concat({
				"[rockmech] 已在東邊放兩個測試方塊（一個眼睛高度、一個在上方可看底面）。",
				"  顏色：上=白 下=深灰 東=紅 西=綠 北=藍 南=黃",
				"  我的假設（請告訴我哪一面不符合）：",
				"  ・紅、綠、藍、黃（四個側面）：從外面看是正常的「F」（直立、不左右顛倒）",
				"  ・白（頂面）：面向北方往下看時，是正常的「F」（F 的頂端朝北）",
				"  ・深灰（底面）：站在下方、面向北方抬頭往上看時，是正常的「F」",
				"  （右上角 HUD 有方位顯示）",
			}, "\n")
		end,
	})
end
