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
		local w = 2 * cfg.failure.window + 1
		local grid = rockmech.collapse.read_grid(vector.subtract(pos, w), vector.add(pos, w))
		r.local_state = rockmech.failure.cell_state(grid, pos.x, pos.y, pos.z,
			rockmech.collapse.failure_params(true))
		r.overhang = rockmech.collapse.overhang_state(pos)
		r.nearby = rockmech.collapse.nearby_min_fs(pos, NEARBY_R)
	end
	return r
end

-- 弱面滑動的一行說明（HUD、資訊頁、羅盤共用）
function rockmech.slip_line(s)
	if not cfg.weakness.enabled then return "節理滑動：關閉" end
	local js = s.slip_set
	if not js then
		return "節理滑動：" .. (s.n_joints == 0 and "完整岩塊（無節理面穿過）" or "無可滑出的節理（未傾向臨空面）")
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
	if not o.d then return "懸臂：整段碰不到支撐（由支撐判定處理）" end
	local c = o.crit
	return ("懸臂 d %d m、t %d m：σb=3γd²/t %.3f / σt %.2f MPa  FS %s（L_max %.1f m）；整段最小 FS %s @ (%d,%d)%s"):format(
		o.d, o.t, o.sigma_b, o.tensile, fs_str(o.fs), o.lmax, fs_str(o.group_fs), c.x, c.z,
		o.edge and ("（懸空群超出 ±%d m 檢查範圍，FS 可能高估）"):format(cfg.overhang.radius) or "")
end

-- 周圍臨空格的最小 FS 一行說明
function rockmech.nearby_line(nb)
	if not nb then return "" end
	local parts = {}
	if nb.joint then
		local j = nb.joint
		parts[#parts + 1] = ("節理 %s @ (%d,%d,%d) %s%s"):format(fs_str(j.fs), j.x, j.y, j.z, j.set.name,
			j.fs <= 1 and " 會滑" or "")
	elseif cfg.weakness.enabled then
		parts[#parts + 1] = "節理：無可滑出的面"
	end
	if nb.axial then
		parts[#parts + 1] = ("軸差 %s @ (%d,%d,%d)"):format(fs_str(nb.axial.fs), nb.axial.x, nb.axial.y, nb.axial.z)
	end
	return ("周圍 ±%d m 臨空格（%d 格）最小 FS：%s"):format(NEARBY_R, nb.exposed, table.concat(parts, "；"))
end

local function fmt_report_lines(r)
	local p, i = r.pos, r.init
	local lines = {}
	lines[#lines + 1] = ("(%d,%d,%d) %s%s  上覆 h=%d m%s"):format(p.x, p.y, p.z,
		r.lith.description:gsub("\n.*", ""), r.is_rock and "" or "（非岩石，以該處岩性計）", i.h,
		i.extrapolated and "（外插至 y0）" or "")
	lines[#lines + 1] = ("初始：σv %.3f  σH %.3f  σh %.3f MPa（σH %g°）"):format(
		i.sv, i.sH, i.shmin, cfg.sH_azimuth)
	local s = r.local_state
	if s then
		lines[#lines + 1] = ("局部：σxx %.3f(×%.2f)  σyy %.3f  σzz %.3f(×%.2f)  σxz %.3f"):format(
			s.sx, s.fx, s.sy, s.sz, s.fz, s.sxz)
		local verdict = s.fails_axial and "破壞" or (s.q >= s.strength and "超過強度但未臨空" or "穩定")
		lines[#lines + 1] = ("σ1 %.3f  σ3 %.3f  q %.3f / 強度 %.2f MPa  FS %.2f  %s%s"):format(
			s.s1, s.s3, s.q, s.strength, s.fs_axial, verdict, s.exposed and "（臨空）" or "")
		lines[#lines + 1] = rockmech.slip_line(s)
		lines[#lines + 1] = rockmech.overhang_line(r.overhang)
		lines[#lines + 1] = rockmech.nearby_line(r.nearby)
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
				local lines = fmt_report_lines(rockmech.stress_report(target))
				table.insert(lines, 1, "[rockmech 現地應力]" .. (target == pos and "" or " 腳下"))
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
		{"軸差破壞", ("%s；強度縮放 %g、半徑 %d、窗格 ±%d、連鎖 %d 輪"):format(
			f.enabled and "開" or "關", f.strength_scale, f.radius, f.window, f.max_cascade)},
		{"懸臂斷裂", ("%s；張力強度縮放 %g、半徑 %d"):format(o.enabled and "開" or "關", o.scale, o.radius)},
		{"支撐判定", ("%s；半徑 %d、剛體上限 %d 格"):format(sp.enabled and "開" or "關", sp.radius, sp.rigid_max)},
		{"碎石安息角", ("%s；%g°"):format(sl.enabled and "開" or "關", sl.angle)},
		{"落石翻滾", ("%s；其他表面 Rn %.2f Rt %.2f μr %.2f"):format(rf.enabled and "開" or "關", rf.rn, rf.rt, rf.mu_roll)},
		{"掉落破碎", cfg.fallbreak.enabled and "開" or "關"},
		{"節理材質", ("%s；%s"):format(cfg.jointtex.enabled and "開" or "關", cfg.jointtex.style)},
	})
	return table_el(0.3, 0.9, 16.4, 9.2, "rm_t1", "text;text", rows)
end

local function tab_lith()
	local rows = {{"岩性", "γ (kN/m³)", "UCS (MPa)", "σt (MPa)", "Rn", "Rt", "μr", "破碎 h_ref (m)",
		"L_max 1 m 厚", "L_max 4 m 厚"}}
	for _, key in ipairs(cfg.lithology_order) do
		local l = cfg.lithologies[key]
		local function lm(t) return ("%.1f m"):format(rockmech.overhang.lmax(l.tensile, l.gamma, t, cfg.overhang.scale)) end
		rows[#rows + 1] = {l.description, l.gamma, l.ucs, l.tensile, l.rn or "-", l.rt or "-",
			l.mu_roll or "-", l.break_height or "-", lm(1), lm(4)}
	end
	local c = "text;text,align=right;text,align=right;text,align=right;text,align=right;text,align=right;" ..
		"text,align=right;text,align=right;text,align=right;text,align=right"
	return table_el(0.3, 0.9, 16.4, 4, "rm_t2", c, rows) ..
		("label[0.3,5.4;%s]"):format(F("L_max = √(σt·縮放·t / (3γ))：懸臂自重彎曲的極限長度；頂板跨度約為其 2 倍。"))
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
			{"q = σ1 − σ3 / 強度", ("%.3f / %.2f MPa"):format(s.q, s.strength)},
			{"軸差 FS", ("%.2f"):format(s.fs_axial)},
			{"節理弱面", rockmech.slip_line(s)},
			{"懸臂", rockmech.overhang_line(r.overhang)},
			{"周圍臨空格", rockmech.nearby_line(r.nearby)},
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
		y = y + 1.2
	end
	out[#out + 1] = ("checkbox[0.3,%g;rm_hud;%s;%s]"):format(y, F("畫面上顯示現地應力（HUD）"),
		tostring(player and hud_enabled(player) or false))
	out[#out + 1] = ("label[0.3,%g;%s]"):format(y + 1.0, F("修改開關需要 rockmech 權限；HUD 每個玩家各自設定。"))
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
