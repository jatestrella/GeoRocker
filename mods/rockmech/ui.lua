-- rockmech/ui.lua
-- 介面（引擎端）：
--   /rockmech        完整資訊頁（總覽、岩性、節理、應力、開關）
--   現地應力 HUD     畫面左側持續顯示所指岩石（或腳下位置）的應力；/rockmech_hud 開關

local cfg = rockmech.cfg
local joints = rockmech.joints
local stress = rockmech.stress
local F = core.formspec_escape

---------------------------------------------------------------------------
-- 應力報告（資訊頁與 HUD 共用）
---------------------------------------------------------------------------

-- 玩家所指的方塊（最近的節點，最遠 range 格）
local function pointed_node_pos(player, range)
	local eye = player:get_pos()
	eye.y = eye.y + (player:get_properties().eye_height or 1.625)
	local dir = player:get_look_dir()
	local to = vector.add(eye, vector.multiply(dir, range or 8))
	for pointed in core.raycast(eye, to, false, false) do
		if pointed.type == "node" then return pointed.under end
	end
	return nil
end
rockmech.pointed_node_pos = pointed_node_pos

-- pos 的應力報告。岩石格回傳初始應力＋局部應力；非岩石只回傳該處岩性的初始應力。
-- 回傳 {pos, name, lith, is_rock, init = stress.initial(...), local_state = failure.cell_state 或 nil}
local NEARBY_R = 4   -- 周圍最小 FS 的範圍 (m)

function rockmech.stress_report(pos)
	local node = core.get_node(pos)
	local lith = rockmech.lith_of_node[node.name]
	local is_rock = lith ~= nil
	if not lith then lith = rockmech.lith_at(pos.x, pos.y, pos.z) end
	local r = {pos = pos, name = node.name, lith = lith, is_rock = is_rock,
		init = rockmech.collapse.initial_stress(pos, lith)}
	if is_rock then
		local grid = rockmech.collapse.read_failure_grid(pos, pos, cfg.failure.window)
		r.local_state = rockmech.failure.cell_state(grid, pos.x, pos.y, pos.z,
			rockmech.collapse.failure_params(true))
		r.overhang = rockmech.collapse.overhang_state(pos)
		r.nearby = rockmech.collapse.nearby_min_fs(pos, NEARBY_R)
		if cfg.keyblock.enabled then r.keyblock = rockmech.collapse.keyblock_state(pos) end
		if cfg.shear.enabled then r.shear = rockmech.collapse.shear_state(pos) end
	end
	return r
end

-- GSI 剖面的文字（"45" 或 "35→65 @ 40 m"）
function rockmech.gsi_profile_str(prof)
	if not prof then return "100" end
	if prof.depth and prof.depth > 0 and prof.bottom and prof.bottom ~= prof.top then
		return ("%g→%g @ %g m"):format(prof.top, prof.bottom, prof.depth)
	end
	return ("%g"):format(prof.top)
end

-- 岩體強度的一行說明。rm = rockmass.params 的結果
function rockmech.rockmass_line(rm)
	if not rm then return "" end
	local n = rockmech.collapse.rock.N
	return ("GSI %d（mb %.3f  s %.2e  a %.3f）σci %.3g → 臨空單軸 %.3g、σt %.3g MPa%s"):format(
		rm.gsi, rm.mb, rm.s, rm.a, rm.sigci, rm.ucs_m, rm.sigt, n ~= 1 and ("（已 ÷ N=%g）"):format(n) or "")
end

-- 懸空格直剪的一行說明。sh = collapse.shear_state 的結果
function rockmech.shear_line(sh)
	if not sh then return "—（底下不是空的）" end
	if sh.isolated then return "範圍內找不到支撐處（倒掛的尖柱由懸臂／關鍵塊體判定，或支撐處在範圍外）" end
	return ("最短路徑 %d 步到支撐處 (%d, %d)：Q = 柱狀荷重和 %.0f kN；斷面 %d 格（到第一個有節理的格）R = Σ%g·σt = %.0f kN → FS %.2f"):format(
		sh.n, sh.ax, sh.az, sh.Q, sh.hs, cfg.shear.k, sh.R, sh.fs)
end

-- 弱面滑動的一行說明（HUD、資訊頁、羅盤共用）
function rockmech.slip_line(s)
	if not cfg.weakness.enabled then return "節理滑動：關閉" end
	local js = s.slip_set
	if not js then
		return "節理滑動：" .. (s.n_joints == 0 and "完整岩塊（無節理面穿過）" or "無可滑出的節理（未傾向臨空面）")
	end
	if s.slip_set2 then
		local l = s.slip_line
		local trend = math.deg(math.atan2 and math.atan2(l.x, l.z) or math.atan(l.x, l.z)) % 360
		local plunge = math.deg(math.asin(-l.y))
		return ("楔形滑動 %s∩%s（交線 %.0f°/%.0f°）：σn %.3f / %.3f  τ∥ %.3f MPa  FS %.2f%s"):format(
			js.name, s.slip_set2.name, trend, plunge, s.slip_sn, s.slip_sn2, s.slip_tau, s.fs_joint,
			s.fails_slip and "  滑動" or "")
	end
	return ("節理滑動 %s（%.0f°/%.0f°）：σn %.3f  τ %.3f MPa  FS %.2f%s"):format(
		js.name, js.dip_eff, js.dipdir_eff, s.slip_sn, s.slip_tau, s.fs_joint,
		s.fails_slip and "  滑動" or "")
end

-- 懸臂斷裂的一行說明（HUD、資訊頁、羅盤共用）。o = collapse.overhang_state 的結果
local function fs_str(f)
	return f == math.huge and "∞" or ("%.2f"):format(f)
end
function rockmech.overhang_line(o)
	if not cfg.overhang.enabled then return "懸臂斷裂：關閉" end
	if not o then return "懸臂：—" end
	if o.supported then return "懸臂：此欄下方有支撐（FS ∞）" end
	if o.aborted then return ("懸臂：懸空群超過 %d 格，不判定"):format(cfg.overhang.max_voxels) end
	if not o.d then return "懸臂：被節理切離、碰不到有支撐的岩柱（FS 0，會掉落）" end
	if o.d == 0 then
		return ("懸臂：坐在下層懸空岩體上，由下層承擔；整段最小 FS %s"):format(fs_str(o.group_fs))
	end
	local c = o.crit
	local root = ""
	if o.rho and o.rho < 1 then
		root = ("、根部斷面被節理切過，完好 %.0f%%"):format(o.rho * 100)
	end
	return ("懸臂 d %d m、t %d m%s：σb=3γ·t·d²/t_eff² %.3f / σt %.2f MPa  FS %s（L_max %.1f m）；整段最小 FS %s @ (%d,%d)%s"):format(
		o.d, o.t, root, o.sigma_b, o.tensile, fs_str(o.fs), o.lmax * (o.rho or 1), fs_str(o.group_fs), c.x, c.z,
		o.edge and ("（懸空群超出 ±%d m 檢查範圍，FS 可能高估）"):format((rockmech.collapse.overhang_radius())) or "")
		.. ((o.cut_cells or 0) > 0 and ("；相鄰有 %d 格被節理切離、會掉落"):format(o.cut_cells) or "")
end

-- 關鍵塊體的一行說明。kb = collapse.keyblock_state 的結果
function rockmech.keyblock_line(kb)
	if not cfg.keyblock.enabled then return "關鍵塊體：關閉" end
	if kb == nil then return "關鍵塊體：—" end
	if kb == false then return "關鍵塊體：與岩體相連（有岩橋，或超過 " .. cfg.keyblock.max_cells .. " 格）" end
	local mode = rockmech.collapse.keyblock_mode_name[kb.mode]
	local sets = {}
	for _, pl in ipairs(kb.planes or {}) do
		local js = pl.set and rockmech.get_joint_sets()[pl.set]
		sets[#sets + 1] = js and js.name or "接觸面"
	end
	if not mode then
		return ("關鍵塊體 %d 格（W %.0f kN）：卡住，沒有可行的運動方向"):format(#kb.cells, kb.W)
	end
	return ("關鍵塊體 %d 格（W %.0f kN）：%s%s FS %s%s"):format(#kb.cells, kb.W, mode,
		#sets > 0 and ("（" .. table.concat(sets, "＋") .. "）") or "", fs_str(kb.fs),
		kb.fs < 1 and "  會滑出" or "")
end

-- 周圍臨空格的最小 FS 一行說明
function rockmech.nearby_line(nb)
	if not nb then return "" end
	local parts = {}
	if nb.joint then
		local j = nb.joint
		parts[#parts + 1] = ("節理 %s @ (%d,%d,%d) %s%s"):format(fs_str(j.fs), j.x, j.y, j.z,
			j.set.name .. (j.set2 and ("∩" .. j.set2.name) or ""),
			j.fs <= 1 and " 會滑" or "")
	elseif cfg.weakness.enabled then
		parts[#parts + 1] = "節理：無可滑出的面"
	end
	if nb.axial then
		parts[#parts + 1] = ("軸差 %s @ (%d,%d,%d)"):format(fs_str(nb.axial.fs), nb.axial.x, nb.axial.y, nb.axial.z)
	end
	return ("周圍 ±%d m 臨空格（%d 格）最小 FS：%s"):format(NEARBY_R, nb.exposed, table.concat(parts, "；"))
end

-- HUD 用的精簡數字：∞、>99、兩位小數
local function fs_short(f)
	if not f or f == math.huge then return "∞" end
	if f > 99 then return ">99" end
	return ("%.2f"):format(f)
end

-- HUD 的精簡報告（4 行）。詳細數值在資訊頁（/rockmech）與羅盤
local function fmt_report_lines(r, header, pname)
	local p, i = r.pos, r.init
	local lines = {}
	lines[#lines + 1] = ("%s (%d,%d,%d) %s%s　上覆 %d m%s"):format(header, p.x, p.y, p.z,
		r.lith.description:gsub("\n.*", ""), r.is_rock and "" or "（非岩石）", i.h,
		r.local_state and r.local_state.rm and ("　GSI %d"):format(r.local_state.rm.gsi) or "")
	local s = r.local_state
	if s then
		lines[#lines + 1] = ("應力 σv %.3f｜σ1 %.3f　σ3 %.3f MPa"):format(i.sv, s.s1, s.s3)
	else
		lines[#lines + 1] = ("初始應力 σv %.3f　σH %.3f　σh %.3f MPa"):format(i.sv, i.sH, i.shmin)
		return lines
	end
	-- 四種機制的 FS
	local parts = {"軸差 " .. fs_short(s.fs_axial)}
	if cfg.weakness.enabled then
		parts[#parts + 1] = "節理 " .. (s.slip_set and (fs_short(s.fs_joint) .. " " .. s.slip_set.name
			.. (s.slip_set2 and ("∩" .. s.slip_set2.name) or "")) or "—")
	end
	local o = r.overhang
	if cfg.overhang.enabled then
		local v = "—"
		if o and o.supported then v = "∞"
		elseif o and o.group_fs then v = fs_short(o.group_fs) end
		parts[#parts + 1] = "懸臂 " .. v
	end
	if r.shear then
		parts[#parts + 1] = "直剪 " .. (r.shear.isolated and "—" or fs_short(r.shear.fs))
	end
	local kb = r.keyblock
	if cfg.keyblock.enabled then
		local v = "—"
		if kb then
			local mode = ({fall = "落下", plane = "平面", wedge = "楔形"})[kb.mode]
			v = mode and (fs_short(kb.fs) .. " " .. mode) or "卡住"
		end
		parts[#parts + 1] = "塊體 " .. v
	end
	lines[#lines + 1] = "FS　" .. table.concat(parts, "｜")
	-- 這格有警戒裂紋：是哪種破壞、FS 多少
	local w = pname and rockmech.fswarn_at and rockmech.fswarn_at(pname, p)
	if w then
		lines[#lines + 1] = core.colorize("#ffb040", ("裂紋：%s　FS %s"):format(w.label,
			w.kind == "shear" and w.fs <= 1.011 and "≤ 1" or fs_short(w.fs)))
	end
	-- 周圍最低
	local nb = r.nearby
	if nb then
		local best, what, at = math.huge, nil, nil
		if nb.joint and nb.joint.fs < best then best, what, at = nb.joint.fs, "節理 " .. nb.joint.set.name, nb.joint end
		if nb.axial and nb.axial.fs < best then best, what, at = nb.axial.fs, "軸差", nb.axial end
		if what then
			lines[#lines + 1] = ("周圍最低 FS %s　%s @(%d,%d,%d)"):format(fs_short(best), what, at.x, at.y, at.z)
		end
	end
	return lines
end

---------------------------------------------------------------------------
-- HUD
---------------------------------------------------------------------------

local HUD_META = "rockmech:hud"
local huds = {}        -- 玩家名稱 → {id, key, t}
local hud_timer = 0

local function hud_enabled(player)
	return player:get_meta():get_string(HUD_META) ~= "0"
end

local function hud_set(player, text)
	local name = player:get_player_name()
	local h = huds[name]
	if not h then
		h = {id = player:hud_add({
			type = "text", position = {x = 0.01, y = 0.30}, alignment = {x = 1, y = 1},
			offset = {x = 0, y = 0}, number = 0xFFFFFF, text = text,
		}), key = nil, t = 0}
		huds[name] = h
	else
		player:hud_change(h.id, "text", text)
	end
end

local function hud_remove(player)
	local name = player:get_player_name()
	local h = huds[name]
	if h then
		player:hud_remove(h.id)
		huds[name] = nil
	end
end

function rockmech.set_hud(player, on)
	player:get_meta():set_string(HUD_META, on and "1" or "0")
	if not on then hud_remove(player) end
end

core.register_globalstep(function(dtime)
	hud_timer = hud_timer + dtime
	if hud_timer < 0.3 then return end
	local dt = hud_timer
	hud_timer = 0
	for _, player in ipairs(core.get_connected_players()) do
		if hud_enabled(player) then
			local name = player:get_player_name()
			local h = huds[name]
			local pos = pointed_node_pos(player, 8)
			local target = pos
			if not (pos and rockmech.lith_of_node[core.get_node(pos).name]) then
				target = vector.round(player:get_pos())
			end
			local key = core.pos_to_string(target)
			-- 指向改變時立即更新；同一格每 2 秒更新一次（周圍可能已被開挖）
			if not h or h.key ~= key or h.t > 2 then
				local lines = fmt_report_lines(rockmech.stress_report(target),
					target == pos and "[rockmech]" or "[rockmech 腳下]", name)
				hud_set(player, table.concat(lines, "\n"))
				huds[name].key = key
				huds[name].t = 0
			else
				h.t = h.t + dt
			end
		end
	end
end)

core.register_on_leaveplayer(function(player)
	huds[player:get_player_name()] = nil
end)

core.register_chatcommand("rockmech_hud", {
	params = "[on|off]",
	description = "開關畫面上的現地應力 HUD（不加參數則切換）",
	func = function(name, param)
		local player = core.get_player_by_name(name)
		if not player then return false, "找不到玩家" end
		local on
		if param == "on" then on = true elseif param == "off" then on = false
		else on = not hud_enabled(player) end
		rockmech.set_hud(player, on)
		return true, "現地應力 HUD：" .. (on and "開啟" or "關閉")
	end,
})

---------------------------------------------------------------------------
-- 完整資訊頁
---------------------------------------------------------------------------

local FORM = "rockmech:info"
local TABS = {"總覽", "岩性", "節理", "應力", "開關"}
local state = {}       -- 玩家名稱 → {tab, report}

local function table_el(x, y, w, h, name, columns, rows)
	local cells = {}
	for _, row in ipairs(rows) do
		for _, c in ipairs(row) do cells[#cells + 1] = F(tostring(c)) end
	end
	return ("tablecolumns[%s]table[%g,%g;%g,%g;%s;%s;0]"):format(
		columns, x, y, w, h, name, table.concat(cells, ","))
end

local function kv_rows(list)
	local rows = {}
	for _, kv in ipairs(list) do rows[#rows + 1] = {kv[1], kv[2]} end
	return rows
end

local function tab_overview()
	local f, o, rf, sp, sl = cfg.failure, cfg.overhang, cfg.rockfall, cfg.support, cfg.slope
	local rows = kv_rows({
		{"世界資料夾", core.get_worldpath()},
		{"地表高程 y0", cfg.surface_y},
		{"岩性分布", cfg.lith_mode == "zones" and ("區帶（寬 " .. cfg.zone_width .. " m）") or "依深度分層"},
		{"只保留岩性 / 剝除土壤", ("%s / %s"):format(cfg.only_lithologies and "是" or "否", cfg.strip_soil and "是" or "否")},
		{"K0", cfg.k0},
		{"σH = K_H·σv + σH0", ("K_H %.2f，σH0 %g MPa"):format(cfg.KH, cfg.sH0)},
		{"σh = K_h·σv + σh0", ("K_h %.2f，σh0 %g MPa"):format(cfg.Kh, cfg.sh0)},
		{"σH 方位", cfg.sH_azimuth .. "°（由北順時針）"},
		{"節理格點密度", cfg.joint_lattice},
		{"相似比 N", ("%g（遊戲 1 m = 實際 %g m；σci、σt、節理 c 都 ÷ N）"):format(cfg.model_scale, cfg.model_scale)},
		{"岩體 GSI（地表→深部 @ 過渡深度）", (function()
			local t = {}
			for _, key in ipairs(cfg.lithology_order) do
				local l = cfg.lithologies[key]
				t[#t + 1] = ("%s %s"):format(l.description:gsub(" ?%(.*", ""), rockmech.gsi_profile_str(l.gsi))
			end
			return table.concat(t, "，") .. ("；D %g"):format(cfg.rockmass.d)
		end)()},
		{"軸差破壞", ("%s；Hoek-Brown 岩體強度、半徑 %d、窗格 ±%d、連鎖 %d 輪%s"):format(
			f.enabled and "開" or "關", f.radius, f.window, f.max_cascade,
			f.strength_scale ~= 1 and ("；舊設定 strength_scale %g"):format(f.strength_scale) or "")},
		{"懸臂斷裂", ("%s；半徑 %d%s"):format(o.enabled and "開" or "關", o.radius,
			o.scale ~= 1 and ("；舊設定 overhang_scale %g"):format(o.scale) or "")},
		{"支撐判定", ("%s；半徑 %d、剛體上限 %d 格"):format(sp.enabled and "開" or "關", sp.radius, sp.rigid_max)},
		{"碎石安息角", ("%s；%g°"):format(sl.enabled and "開" or "關", sl.angle)},
		{"落石翻滾", ("%s；其他表面 Rn %.2f Rt %.2f μr %.2f"):format(rf.enabled and "開" or "關", rf.rn, rf.rt, rf.mu_roll)},
		{"掉落破碎", cfg.fallbreak.enabled and "開" or "關"},
		{"節理材質", ("%s；%s"):format(cfg.jointtex.enabled and "開" or "關", cfg.jointtex.style)},
	})
	return table_el(0.3, 0.9, 16.4, 9.2, "rm_t1", "text;text", rows)
end

local function tab_lith()
	local rows = {{"岩性", "γ (kN/m³)", "σci (MPa)", "σt (MPa)", "mi", "GSI", "地表 σc,m / σt,m",
		"深部 σc,m / σt,m", "L_max 1 / 4 m 厚（地表）", "破碎 h_ref (m)"}}
	local rock = rockmech.collapse.rock
	for _, key in ipairs(cfg.lithology_order) do
		local l = cfg.lithologies[key]
		local top = rock.at(key, cfg.surface_y, nil)
		local deep = rock.at(key, cfg.surface_y - 1e6, nil)
		local function lm(t) return ("%.1f"):format(rockmech.overhang.lmax(top.sigt, l.gamma, t, cfg.overhang.scale)) end
		rows[#rows + 1] = {l.description, l.gamma, l.ucs, l.tensile, l.mi or "-", rockmech.gsi_profile_str(l.gsi),
			("%.3g / %.3g"):format(top.ucs_m, top.sigt), ("%.3g / %.3g"):format(deep.ucs_m, deep.sigt),
			lm(1) .. " / " .. lm(4) .. " m", l.break_height or "-"}
	end
	local c = "text;text,align=right;text,align=right;text,align=right;text,align=right;text,align=right;" ..
		"text,align=right;text,align=right;text,align=right;text,align=right"
	return table_el(0.3, 0.9, 16.4, 4, "rm_t2", c, rows) ..
		("label[0.3,5.4;%s]"):format(F(("σci、σt 為完整岩石（實驗室）值；岩體強度依 Hoek-Brown（GSI、mi、D）並 ÷ 相似比 N=%g。"):format(cfg.model_scale))) ..
		("label[0.3,5.9;%s]"):format(F("σc,m = σci·s^a（臨空面單軸）；σt,m = σt·s·mi/mb；L_max = √(σt,m·t / (3γ))，頂板跨度約為其 2 倍。"))
end

local function tab_joints()
	local rows = {{"組", "輸入 傾角/傾向", "對齊後 傾角/傾向", "整數法向 m", "間距 輸入→有效", "延續性", "φj", "材質級數"}}
	local sets = rockmech.get_joint_sets()
	for _, js in ipairs(sets) do
		rows[#rows + 1] = {js.name, ("%g° / %g°"):format(js.dip, js.dipdir),
			("%.1f° / %.1f°"):format(js.dip_eff, js.dipdir_eff),
			("(%d, %d, %d)"):format(js.mx, js.my, js.mz),
			("%g → %.2f m"):format(js.spacing, js.spacing_eff),
			js.persistence, js.phi .. "°", rockmech.jointtex.levels(js)}
	end
	return table_el(0.3, 0.9, 16.4, 3.5, "rm_t3", "text;text;text;text;text;text,align=right;text,align=right;text,align=right", rows) ..
		("label[0.3,4.9;%s]"):format(F("座標：x = 東、y = 上、z = 北；傾向由北順時針。節理法向對齊整數格點，使跡線跨方塊連續。"))
end

local function tab_stress(name)
	local st = state[name]
	local r = st and st.report
	local out = {("button[0.3,0.7;5,0.7;rm_refresh;%s]"):format(F("以目前指向的方塊重新計算"))}
	if not r then
		out[#out + 1] = ("label[0.3,1.9;%s]"):format(F("（沒有指向任何方塊）"))
		return table.concat(out)
	end
	local i, s = r.init, r.local_state
	local rows = kv_rows({
		{"位置", core.pos_to_string(r.pos)},
		{"方塊", r.name},
		{"岩性", r.lith.description:gsub("\n.*", "") .. (r.is_rock and "" or "（非岩石，以該處岩性計）")},
		{"上覆岩層厚度 h", ("%d m（地表 y=%d%s）"):format(i.h, i.top_y,
			i.extrapolated and "，超出掃描範圍、外插至 y0" or "")},
		{"初始 σv = Σγ·Δh", ("%.3f MPa（開挖前，空洞視為岩石）"):format(i.sv)},
		{"初始 σH / σh", ("%.3f / %.3f MPa（σH %g°）"):format(i.sH, i.shmin, cfg.sH_azimuth)},
		{"初始 σxx / σzz / σxz", ("%.3f / %.3f / %.3f MPa"):format(i.sxx, i.szz, i.sxz)},
	})
	if s then
		for _, kv in ipairs({
			{"柱狀荷重 → 擴散後 σyy", ("%.3f → %.3f MPa（×%.2f）"):format(s.sv0, s.sv, s.factor)},
			{"局部 σxx（×集中）", ("%.3f MPa（×%.2f）"):format(s.sx, s.fx)},
			{"局部 σyy", ("%.3f MPa"):format(s.sy)},
			{"局部 σzz（×集中）", ("%.3f MPa（×%.2f）"):format(s.sz, s.fz)},
			{"局部 σxz", ("%.3f MPa"):format(s.sxz)},
			{"主應力 σ1 / σ3", ("%.3f / %.3f MPa"):format(s.s1, s.s3)},
			{"岩體強度", rockmech.rockmass_line(s.rm)},
			{"q = σ1 − σ3 / 岩體強度 q_f(σ3)", ("%.3f / %.3f MPa"):format(s.q, s.strength)},
			{"軸差 FS", ("%.2f"):format(s.fs_axial)},
			{"節理弱面", rockmech.slip_line(s)},
			{"懸臂", rockmech.overhang_line(r.overhang)},
			{"懸空直剪", rockmech.shear_line(r.shear)},
			{"周圍臨空格", rockmech.nearby_line(r.nearby)},
			{"關鍵塊體", rockmech.keyblock_line(r.keyblock)},
			{"臨空面", (s.exposed_x and "東西 " or "") .. (s.exposed_z and "南北 " or "") ..
				(s.exposed_up and "上 " or "") .. (s.exposed_down and "下" or "")},
			{"判定", s.fails_axial and "軸差破壞" or s.fails_slip and "沿節理滑動"
				or (s.q >= s.strength and "超過強度但未臨空" or "穩定")},
		}) do rows[#rows + 1] = {kv[1], kv[2]} end
	end
	-- 六個面的節理
	local sets = rockmech.get_joint_sets()
	local label = {E = "東面 (+x)", W = "西面 (-x)", Up = "上面 (+y)", Dn = "下面 (-y)", N = "北面 (+z)", S = "南面 (-z)"}
	for _, face in ipairs(joints.FACES) do
		local fx, fy, fz, axis = joints.face_key(r.pos.x, r.pos.y, r.pos.z, face)
		local parts = {}
		for _, it in ipairs(joints.face_info(sets, fx, fy, fz, axis)) do
			parts[#parts + 1] = sets[it.set].name .. (it.joint and " 節理" or " 岩橋")
		end
		rows[#rows + 1] = {label[face.name], #parts > 0 and table.concat(parts, "、") or "完整"}
	end
	out[#out + 1] = table_el(0.3, 1.6, 16.4, 8.6, "rm_t4", "text;text", rows)
	return table.concat(out)
end

local function tab_toggles(name)
	local player = core.get_player_by_name(name)
	local out = {}
	local y = 1.0
	for _, t in ipairs(rockmech.toggles or {}) do
		out[#out + 1] = ("checkbox[0.3,%g;rm_%s;%s;%s]"):format(y, t.id, F(t.label), tostring(t.tbl.enabled))
		out[#out + 1] = ("label[0.8,%g;%s]"):format(y + 0.45, F(t.off_note))
		y = y + 0.88
	end
	out[#out + 1] = ("checkbox[0.3,%g;rm_hud;%s;%s]"):format(y, F("畫面上顯示現地應力（HUD）"),
		tostring(player and hud_enabled(player) or false))
	y = y + 0.6
	out[#out + 1] = ("checkbox[0.3,%g;rm_fsmask;%s;%s]"):format(y,
		F("標出周圍 FS ≤ 1 的岩格（紅 = 節理滑動、橙 = 軸差、紫 = 懸臂／被節理切離）"),
		tostring(player and rockmech.fsmask_live and rockmech.fsmask_live(player) or false))
	y = y + 0.6
	out[#out + 1] = ("checkbox[0.3,%g;rm_fswarn;%s;%s]"):format(y,
		F(("警戒裂紋：受開挖影響、FS 降到 1 < FS < %g 的岩格加上裂紋（越接近 1 裂得越嚴重）"):format(cfg.fswarn.max)),
		tostring(player and rockmech.fswarn_enabled and rockmech.fswarn_enabled(player) or false))
	out[#out + 1] = ("label[0.3,%g;%s]"):format(y + 0.6, F("修改力學開關需要 rockmech 權限；HUD、FS 遮罩、警戒裂紋每個玩家各自設定。"))
	return table.concat(out)
end

local function build(name)
	local st = state[name] or {tab = 1}
	state[name] = st
	local body
	if st.tab == 1 then body = tab_overview()
	elseif st.tab == 2 then body = tab_lith()
	elseif st.tab == 3 then body = tab_joints()
	elseif st.tab == 4 then body = tab_stress(name)
	else body = tab_toggles(name) end
	return table.concat({
		"formspec_version[6]size[17,10.6]",
		("tabheader[0,0;17,0.6;rm_tab;%s;%d;false;true]"):format(table.concat(TABS, ","), st.tab),
		body,
	})
end

-- ���ա������ΡG���ͬY���a�Y������ formspec �r��
function rockmech.info_formspec(name, tab, report)
	state[name] = {tab = tab, report = report}
	return build(name)
end

function rockmech.show_info(name)
	local player = core.get_player_by_name(name)
	if not player then return end
	local st = state[name] or {tab = 1}
	state[name] = st
	local pos = pointed_node_pos(player, 8)
	if pos then st.report = rockmech.stress_report(pos) end
	core.show_formspec(name, FORM, build(name))
end

core.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= FORM then return end
	local name = player:get_player_name()
	local st = state[name] or {tab = 1}
	state[name] = st
	local redraw = false
	if fields.rm_tab then
		st.tab = tonumber(fields.rm_tab) or 1
		redraw = true
	end
	if fields.rm_refresh then
		local pos = pointed_node_pos(player, 8)
		st.report = pos and rockmech.stress_report(pos) or nil
		redraw = true
	end
	if fields.rm_hud then
		rockmech.set_hud(player, fields.rm_hud == "true")
		redraw = true
	end
	if fields.rm_fsmask and rockmech.set_fsmask_live then
		rockmech.set_fsmask_live(player, fields.rm_fsmask == "true")
		redraw = true
	end
	if fields.rm_fswarn and rockmech.set_fswarn then
		rockmech.set_fswarn(player, fields.rm_fswarn == "true")
		redraw = true
	end
	for _, t in ipairs(rockmech.toggles or {}) do
		local v = fields["rm_" .. t.id]
		if v ~= nil then
			local _, msg = rockmech.set_toggle(t.id, v == "true", name)
			core.chat_send_player(name, "[rockmech] " .. msg)
			redraw = true
		end
	end
	if redraw and not fields.quit then
		core.show_formspec(name, FORM, build(name))
	end
	return true
end)

core.register_on_leaveplayer(function(player)
	state[player:get_player_name()] = nil
end)

core.register_chatcommand("rockmech", {
	description = "開啟 rockmech 完整資訊頁（總覽、岩性、節理、應力、開關）",
	func = function(name)
		rockmech.show_info(name)
		return true
	end,
})
