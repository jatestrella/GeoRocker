-- rockmech/tools.lua
-- 除錯／地質工具（引擎端）：
--   rockmech:compass     地質羅盤，右鍵一格顯示岩性、深度、應力與六個面的節理
--   /rockmech_traces [r] 以 particle 標示附近臨空面上的節理跡線
--   /rockmech_failure    軸差破壞檢查（回報／apply）
--   /convert_rocks       把附近的 stone 依深度換成岩性（舊世界測試用）
--   方位 HUD             畫面上方顯示面向（沿用 physics_core）
--   物品欄「rockmech」分頁 / /rockmech_toggle   遊戲中開關（破壞準則、安息角滑動、翻滾）

local cfg = rockmech.cfg
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
		lith = rockmech.lith_at_y(pos.y)
		lith_note = core.colorize("#aaaaaa",
			(" [%s 非本 mod 岩性，應力以該深度分層 %s 計]"):format(nodename, lith.name))
	end

	local st = stress.initial(cfg, lith, pos.y)
	lines[#lines + 1] = core.colorize("#ffd080", "[rockmech 羅盤] ") .. fmt_pos(pos) ..
		"  " .. lith.description .. lith_note
	lines[#lines + 1] = ("  γ=%.1f kN/m³  UCS=%g MPa  σt=%g MPa"):format(
		lith.gamma, lith.ucs, lith.tensile)
	lines[#lines + 1] = ("  深度 h=%.1f m (y0=%d)  σv=%.3f MPa  σh=%.3f MPa (K0=%.2f)"):format(
		st.h, cfg.surface_y, st.sv, st.sh, cfg.k0)

	-- 開挖後的局部應力與軸差破壞判定（只對本 mod 岩性）
	if rockmech.lith_of_node[nodename] then
		local w = cfg.failure.window + 1
		local grid = rockmech.collapse.read_grid(vector.subtract(pos, w), vector.add(pos, w))
		local fs = rockmech.failure.cell_state(grid, pos.x, pos.y, pos.z,
			rockmech.collapse.failure_params())
		if fs then
			lines[#lines + 1] = ("  柱狀荷重 %.3f → 擴散後 %.3f MPa（×%.2f）  σx=%.3f σy=%.3f σz=%.3f MPa%s"):format(
				fs.sv0, fs.sv, fs.factor, fs.sx, fs.sy, fs.sz,
				fs.exposed and "（臨空）" or "")
			local verdict
			if fs.fails then
				verdict = core.colorize("#ff6060", "破壞")
			elseif fs.q >= fs.strength then
				verdict = core.colorize("#ffb060", "超過強度但未臨空")
			else
				verdict = core.colorize("#80ff80", "穩定")
			end
			lines[#lines + 1] = ("  q=σ1−σ3=%.2f MPa  強度=%.2f MPa  FS=%.2f  → %s"):format(
				fs.q, fs.strength, fs.fs, verdict)
		end
	end

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
				("%s %g/%g S=%gm P=%.2f"):format(js.name, js.dip, js.dipdir, js.spacing, js.persistence))
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

core.register_chatcommand("convert_rocks", {
	params = "[半徑，預設 20，上限 48]",
	description = "把玩家附近的 default:stone（含舊的 physics_core:large_rock）依深度換成 rockmech 岩性",
	privs = {server = true},
	func = function(name, param)
		local player = core.get_player_by_name(name)
		if not player then return false, "找不到玩家" end
		if not core.registered_nodes["default:stone"] then
			return false, "沒有 default:stone，無需轉換"
		end
		local R = math.max(1, math.min(48, math.floor(tonumber(param) or 20)))
		local c = vector.round(player:get_pos())
		local p1, p2 = vector.subtract(c, R), vector.add(c, R)

		local vm = core.get_voxel_manip()
		local emin, emax = vm:read_from_map(p1, p2)
		local area = VoxelArea(emin, emax)
		local data = vm:get_data()

		local c_stone = core.get_content_id("default:stone")
		local cid_y = {}
		for y = p1.y, p2.y do
			local lith = rockmech.lith_at_y(y)
			cid_y[y] = core.get_content_id(rockmech.node_of_lith[lith.name])
		end

		local replaced = 0
		for z = p1.z, p2.z do
			for y = p1.y, p2.y do
				local vi = area:index(p1.x, y, z)
				for _ = p1.x, p2.x do
					if data[vi] == c_stone then
						data[vi] = cid_y[y]
						replaced = replaced + 1
					end
					vi = vi + 1
				end
			end
		end

		-- VoxelManip 寫入不會呼叫 on_destruct，不會觸發坍塌
		vm:set_data(data)
		vm:write_to_map(false)
		vm:close()
		return true, ("替換了 %d 格 stone（半徑 %d）"):format(replaced, R)
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
		local msg = ("臨空岩格 %d 格，破壞 %d 格，%.1f ms（半徑 %d，強度縮放 %g）"):format(
			stats.evaluated, stats.failed, ms, r, cfg.failure.strength_scale)
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
local TOGGLE_PRIV = "server"

-- 開關表（依顯示順序）
local TOGGLES = {
	{
		id = "failure", tbl = cfg.failure,
		label = "軸差破壞準則  q = σ1 − σ3 ≥ UCS × 縮放",
		short = "軸差破壞準則",
		info = function()
			local f = cfg.failure
			return ("強度縮放 %g，檢查半徑 %d m，連鎖上限 %d 輪"):format(
				f.strength_scale, f.radius, f.max_cascade)
		end,
		off_note = "關閉：完整岩石不會破壞（懸空時只有完全孤立才掉落）",
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
		label = "碎石安息角滑動（完整岩石不受影響）",
		short = "碎石安息角滑動",
		info = function() return ("安息角 %g°；碎石懸空時仍會垂直落下"):format(cfg.slope.angle) end,
		off_note = "關閉：碎石超過安息角也不移動",
	},
	{
		id = "rockfall", tbl = cfg.rockfall,
		label = "碎石滑動時以翻滾方式移動",
		short = "翻滾落石",
		info = function()
			return ("目前翻滾中 %d 顆，上限 %d"):format(
				rockmech.rockfall_entity and rockmech.rockfall_entity.active_count() or 0,
				cfg.rockfall.max_active)
		end,
		off_note = "關閉：改回原本的平移滑動（安息角滑動關閉時此項無作用）",
	},
}
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
			local parts = {"label[0,0;", F("岩石力學開關（即時生效）"), "]"}
			local y = 0.6
			for _, t in ipairs(TOGGLES) do
				parts[#parts + 1] = ("checkbox[0,%g;rm_%s;%s;%s]"):format(
					y, t.id, F(t.label), tostring(t.tbl.enabled))
				parts[#parts + 1] = ("label[0.4,%g;%s]"):format(y + 0.75, F(t.info()))
				parts[#parts + 1] = ("label[0.4,%g;%s]"):format(y + 1.15, F(t.off_note))
				y = y + 1.9
			end
			if not can then
				parts[#parts + 1] = ("label[0,%g;%s]"):format(y,
					F("（需要 " .. TOGGLE_PRIV .. " 權限才能修改）"))
			end
			return sfinv.make_formspec(player, context, table.concat(parts), true)
		end,
		on_player_receive_fields = function(self, player, context, fields)
			local name = player:get_player_name()
			local handled = false
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
