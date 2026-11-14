-- rockmech/ui.lua
-- 介面（引擎端）：
--   /rockmech        完整資訊頁（總覽、岩性、節理、應力、開關）
--   現地應力 HUD     指著岩石時，畫面左側顯示岩性、品位、應力與最低的 FS；指著碎石時顯示種類與品位；
--                    /rockmech_hud 開關

local cfg = rockmech.cfg
local joints = rockmech.joints
local stress = rockmech.stress
local F = core.formspec_escape
local S = rockmech.S
local function onoff(b) return b and S("on") or S("off") end

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
	local r = {pos = pos, name = node.name, p2 = rockmech.rubble_p2(node), lith = lith, is_rock = is_rock,
		init = rockmech.collapse.initial_stress(pos, lith)}
	if is_rock then
		local grid = rockmech.collapse.read_failure_grid(pos, pos, cfg.failure.window)
		r.local_state = rockmech.failure.cell_state(grid, pos.x, pos.y, pos.z,
			rockmech.collapse.failure_params(true))
		if not cfg.fem.drive then r.overhang = rockmech.collapse.overhang_state(pos) end
		r.nearby = rockmech.collapse.nearby_min_fs(pos, NEARBY_R)
		if cfg.keyblock.enabled then r.keyblock = rockmech.collapse.keyblock_state(pos) end
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
	return S("GSI @1 (mb @2  s @3  a @4) σci @5 → unconfined rock mass @6, σt @7 MPa@8",
		("%d"):format(rm.gsi), ("%.3f"):format(rm.mb), ("%.2e"):format(rm.s), ("%.3f"):format(rm.a),
		("%.3g"):format(rm.sigci), ("%.3g"):format(rm.ucs_m), ("%.3g"):format(rm.sigt),
		n ~= 1 and (" " .. S("(already ÷ N=@1)", ("%g"):format(n))) or "")
end

-- 弱面滑動的一行說明（HUD、資訊頁、羅盤共用）
function rockmech.slip_line(s)
	if not cfg.weakness.enabled then return S("Joint sliding: off") end
	local js = s.slip_set
	if not js then
		return s.n_joints == 0 and S("Joint sliding: intact rock (no joint plane passes through)")
			or S("Joint sliding: no joint can slide out (none dips toward a free face)")
	end
	if s.slip_set2 then
		local l = s.slip_line
		local trend = math.deg(math.atan2 and math.atan2(l.x, l.z) or math.atan(l.x, l.z)) % 360
		local plunge = math.deg(math.asin(-l.y))
		return S("Wedge sliding @1∩@2 (line of intersection @3°/@4°): σn @5 / @6  τ∥ @7 MPa  FS @8@9",
			js.name, s.slip_set2.name, ("%.0f"):format(trend), ("%.0f"):format(plunge), ("%.3f"):format(s.slip_sn),
			("%.3f"):format(s.slip_sn2), ("%.3f"):format(s.slip_tau), ("%.2f"):format(s.fs_joint),
			s.fails_slip and ("  " .. S("sliding")) or "")
	end
	return S("Joint sliding @1 (@2°/@3°): σn @4  τ @5 MPa  FS @6@7",
		js.name, ("%.0f"):format(js.dip_eff), ("%.0f"):format(js.dipdir_eff), ("%.3f"):format(s.slip_sn),
		("%.3f"):format(s.slip_tau), ("%.2f"):format(s.fs_joint),
		s.fails_slip and ("  " .. S("sliding")) or "")
end

-- 懸臂斷裂的一行說明（HUD、資訊頁、羅盤共用）。o = collapse.overhang_state 的結果
local function fs_str(f)
	return f == math.huge and "∞" or ("%.2f"):format(f)
end
function rockmech.overhang_line(o)
	if cfg.fem.drive then return S("Overhang: not computed separately; the stress solution checks each cell") end
	if not cfg.overhang.enabled then return S("Overhang failure: off") end
	if not o then return S("Overhang: —") end
	if o.supported then return S("Overhang: supported below this column (FS ∞)") end
	if o.aborted then return S("Overhang: overhanging group exceeds @1 cells, not evaluated", ("%d"):format(cfg.overhang.max_voxels)) end
	if not o.d then return S("Overhang: cut off by joints, not connected to any supported rock column (FS 0, will fall)") end
	if o.d == 0 then
		return S("Overhang: rests on the overhanging rock below, which carries it; minimum FS of the whole span @1", fs_str(o.group_fs))
	end
	local c = o.crit
	local root = ""
	if o.rho and o.rho < 1 then
		root = S(", root section cut by joints, @1% intact", ("%.0f"):format(o.rho * 100))
	end
	-- 支護：底面往上托的 pᵢ（≥ γt 整欄被托住）
	local sup = ""
	if o.p_sup then
		sup = S("; support pushes up @1 kPa (load γh @2 kPa)", ("%.0f"):format(o.p_sup), ("%.0f"):format(o.gamma * (o.h or o.t)))
	end
	if o.fs_shear then sup = S("; shear FS @1@2", fs_str(o.fs_shear), sup) end
	local geom = S("Overhang @1, t @2 m, relaxed zone k @3, clear height @4 m, load height h @5 m@6",
		S("overhanging @1 m² / supported perimeter @2 m", ("%d"):format(o.area), ("%d"):format(o.perim)),
		("%d"):format(o.t), ("%.2f"):format(o.k or 0), ("%.1f"):format(o.ht or 0), ("%.1f"):format(o.h or o.t), root)
	local cut = (o.cut_cells or 0) > 0 and S("; @1 adjacent cells are cut off by joints and will fall", ("%d"):format(o.cut_cells)) or ""
	local result = S("bending moment @1 kN·m/m, σb=6M/t_eff² @2 / σt @3 MPa  FS @4; minimum FS of the whole span @5 @@ (@6,@7)@8@9",
		("%.0f"):format(o.m or 0), ("%.3f"):format(o.sigma_b), ("%.3f"):format(o.tensile), fs_str(o.fs), fs_str(o.group_fs),
		("%d"):format(c.x), ("%d"):format(c.z),
		o.edge and (" " .. S("(the overhanging group extends beyond the ±@1 m check range; FS may be overestimated)",
			("%d"):format((rockmech.collapse.overhang_radius())))) or "",
		cut .. sup)
	return S("@1: @2", geom, result)
end

-- 關鍵塊體的一行說明。kb = collapse.keyblock_state 的結果
function rockmech.keyblock_line(kb)
	if not cfg.keyblock.enabled then return S("Key block: off") end
	if kb == nil then return S("Key block: —") end
	if kb == false then return S("Key block: connected to the rock mass (rock bridge, or more than @1 cells)", tostring(cfg.keyblock.max_cells)) end
	local mode = rockmech.collapse.keyblock_mode_name[kb.mode]
	local sets = {}
	for _, pl in ipairs(kb.planes or {}) do
		local js = pl.set and rockmech.get_joint_sets()[pl.set]
		sets[#sets + 1] = js and js.name or S("contact face")
	end
	if not mode then
		return S("Key block of @1 cells (W @2 kN): locked, no kinematically feasible movement", ("%d"):format(#kb.cells), ("%.0f"):format(kb.W))
	end
	return S("Key block of @1 cells (W @2 kN): @3@4 FS @5@6", ("%d"):format(#kb.cells), ("%.0f"):format(kb.W), mode,
		#sets > 0 and S("(@1)", table.concat(sets, " + ")) or "", fs_str(kb.fs),
		kb.fs < 1 and ("  " .. S("slides out")) or "")
end

-- 周圍臨空格的最小 FS 一行說明
function rockmech.nearby_line(nb)
	if not nb then return "" end
	local parts = {}
	if nb.joint then
		local j = nb.joint
		parts[#parts + 1] = S("joint @1 @@ (@2,@3,@4) @5@6", fs_str(j.fs), ("%d"):format(j.x), ("%d"):format(j.y), ("%d"):format(j.z),
			j.set.name .. (j.set2 and ("∩" .. j.set2.name) or ""),
			j.fs <= 1 and (" " .. S("will slide")) or "")
	elseif cfg.weakness.enabled then
		parts[#parts + 1] = S("joints: no plane can slide out")
	end
	if nb.axial then
		parts[#parts + 1] = S("deviatoric @1 @@ (@2,@3,@4)", fs_str(nb.axial.fs),
			("%d"):format(nb.axial.x), ("%d"):format(nb.axial.y), ("%d"):format(nb.axial.z))
	end
	return S("Minimum FS of free-face cells within ±@1 m (@2 cells): @3", ("%d"):format(NEARBY_R), ("%d"):format(nb.exposed),
		table.concat(parts, "; "))
end

-- HUD 用的精簡數字：∞、>99、兩位小數
local function fs_short(f)
	if not f or f == math.huge then return "∞" end
	if f > 99 then return ">99" end
	return ("%.2f"):format(f)
end

-- HUD 的精簡報告：岩性、應力、最低的 FS 與它的機制。詳細數值在資訊頁（/rockmech）與羅盤（蹲下＋右鍵）
-- 經營模式要有知識能力才看得到（knowledge.lua）：岩性、GSI、上覆厚度＝岩體分類，品位＝品位判讀，應力、FS、裂紋＝岩石力學
-- 知識能力（knowledge.lua）：give = 正在用的儀器給的能力；沒有就看自己會的（考試、雇用的地質師；背包裡的儀器不算）
local function see(name, ab, give)
	if give then return give[ab] == true end
	return not rockmech.can_see or rockmech.can_see(name, ab, true)
end
local function fmt_report_lines(r, pname, give)
	local i = r.init
	local s = r.local_state
	local lines = {}
	if see(pname, "rockmass", give) then
		lines[#lines + 1] = S("@1@2　overburden @3 m", S(r.lith.description),
			s and s.rm and ("　GSI %d"):format(s.rm.gsi) or "", ("%d"):format(i.h))
		local D = rockmech.collapse.damage_at_xyz and r.pos and rockmech.collapse.damage_at_xyz(r.pos.x, r.pos.y, r.pos.z)
		if D then lines[#lines + 1] = S("Blast damage D = @1 (strength and deformation modulus reduced)", ("%.1f"):format(D)) end
	end
	local ore = cfg.ores[r.lith.ore]
	if ore and r.is_rock and see(pname, "grade", give) then lines[#lines + 1] = rockmech.ore_text(ore, r.p2 / 255) end
	if r.lith.chem and r.is_rock and r.pos and see(pname, "grade", give) then           -- 褐鐵礦：鐵、金、有害雜質
		local ct = rockmech.assay.chem_text(rockmech.assay.get(r.pos))
		if ct then lines[#lines + 1] = ct end
	end
	if not s or not see(pname, "mechanics", give) then return lines end
	-- 應力解決定崩落時，應力與 FS 看應力解（這一格還沒解過就先用現有估算）
	local fc = rockmech.fem_cell and rockmech.fem_cell(r.pos)
	lines[#lines + 1] = ("σ1 %.2f　σ3 %.2f MPa"):format(fc and fc.s1 or s.s1, fc and fc.s3 or s.s3)
	-- 最低的 FS
	local best, what = fc and fc.fs or s.fs_axial, fc and S("stress solution") or S("deviatoric")
	local function take(f, name) if f and f < best then best, what = f, name end end
	if cfg.weakness.enabled and s.slip_set then
		take(s.fs_joint, S("joint @1", s.slip_set.name .. (s.slip_set2 and ("∩" .. s.slip_set2.name) or "")))
	end
	local o = r.overhang
	if cfg.overhang.enabled and not cfg.fem.drive and o and not o.supported then take(o.group_fs, S("overhang")) end
	local kb = r.keyblock
	if cfg.keyblock.enabled and kb and kb.mode then take(kb.fs, S("key block")) end
	lines[#lines + 1] = best == math.huge and "FS ∞" or S("FS @1 (@2)", fs_short(best), what)
	-- 這格有警戒裂紋：是哪種破壞、FS 多少
	local w = pname and rockmech.fswarn_at and rockmech.fswarn_at(pname, r.pos)
	if w then
		local fsv = w.kind == "shear" and w.fs <= 1.011 and "≤ 1" or fs_short(w.fs)
		local joint = rockmech.fswarn_joint_kind and rockmech.fswarn_joint_kind[w.kind]
		lines[#lines + 1] = core.colorize("#ffb040", joint and (w.label .. "　FS " .. fsv) or S("Crack: @1　FS @2", w.label, fsv))
	end
	return lines
end
rockmech.hud_lines = fmt_report_lines   -- 測試用

-- 指著碎石時的 HUD：種類（岩體分類），礦石碎石再加品位（品位判讀）
local function rubble_lines(node, pname, give, pos)
	local base = rockmech.rubble_base[node.name] or node.name
	local lines = {}
	if see(pname, "rockmass", give) then lines[#lines + 1] = rockmech.desc_short(base) end
	-- 混合碎石：礦石的品位要有品位判讀；崩積土這類（土、碎石的比例）看岩體分類就看得出來
	local m = rockmech.mix_of[base]
	local A = rockmech.assay
	local c = pos and A and A.get(pos, node)
	if A and A.has_v(c) then                       -- 三種以上成分：列出全部的比例（要有品位判讀）
		if see(pname, "grade", give) then lines[#lines + 1] = A.parts_text(c) end
	elseif m and see(pname, m.ore and "grade" or "rockmass", give) then lines[#lines + 1] = rockmech.mix_text(base, node.param2) end
	local ct = c and A.chem_text(c)
	if ct and see(pname, "grade", give) then lines[#lines + 1] = ct end      -- 化學成分（鐵、金、有害雜質）
	return lines
end

---------------------------------------------------------------------------
-- HUD
---------------------------------------------------------------------------

-- 資訊泡泡：準心右上一個半透明深色框，裡面是文字（往右、往上長）。
--   儀器（羅盤、XRF、GSI 圖卡）右鍵：rockmech.info_bubble 顯示 BUBBLE_HOLD 秒，視線移開那一格就收掉
--   自己會的能力（考過試、雇了地質師）：指著岩石、碎石就一直顯示（/rockmech_hud 開關）
local HUD_META = "rockmech:hud"
local BUBBLE_HOLD = 6
local huds = {}        -- 玩家名稱 → {bg, txt, text, key, t}
local active = {}      -- 玩家名稱 → {text, key, untl}
local hud_timer = 0

local function hud_enabled(player)
	return player:get_meta():get_string(HUD_META) ~= "0"
end

-- 文字的寬高（像素，估計）：中日韓字 18 px、其他 9 px，一行 20 px
local function text_size(text)
	local w, n = 0, 0
	for line in (core.strip_colors(text) .. "\n"):gmatch("(.-)\n") do
		n = n + 1
		local lw = 0
		for ch in line:gmatch("[%z\1-\127\194-\244][\128-\191]*") do lw = lw + (#ch >= 3 and 18 or 9) end
		if lw > w then w = lw end
	end
	return w, n * 20
end

local function hud_set(player, text)
	local name = player:get_player_name()
	local h = huds[name]
	if h and h.text == text then return end
	local w, ht = text_size(text)
	if not h then
		h = {
			bg = player:hud_add({type = "image", position = {x = 0.5, y = 0.5}, alignment = {x = 1, y = -1},
				offset = {x = 26, y = -18}, scale = {x = w + 16, y = ht + 10}, text = "[fill:1x1:#101418b4", z_index = 90}),
			txt = player:hud_add({type = "text", position = {x = 0.5, y = 0.5}, alignment = {x = 1, y = -1},
				offset = {x = 34, y = -23}, number = 0xFFFFFF, text = text, z_index = 91}),
		}
		huds[name] = h
	else
		player:hud_change(h.txt, "text", text)
		player:hud_change(h.bg, "scale", {x = w + 16, y = ht + 10})
	end
	h.text = text
end

local function text_remove(player)
	local name = player:get_player_name()
	local h = huds[name]
	if h then
		player:hud_remove(h.bg)
		player:hud_remove(h.txt)
		huds[name] = nil
	end
end
local function hud_remove(player)
	text_remove(player)
end
local last = {}        -- 玩家名稱 → {key（指著哪一格）, t}：被動顯示多久重算一次

-- 儀器的結果：顯示在泡泡裡（pos：指著的那一格，視線移開就收掉；nil：只看時間）
function rockmech.info_bubble(player, text, pos)
	if type(text) == "table" then text = table.concat(text, "\n") end
	if text == "" then return end
	local name = player:get_player_name()
	active[name] = {text = text, key = pos and core.pos_to_string(pos), untl = core.get_us_time() / 1e6 + BUBBLE_HOLD}
	hud_set(player, text)
end

-- 用儀器看 pos 那一格：give = 這個儀器給的能力（{grade = true} …）。回傳顯示的行（空的就是看不出東西）
function rockmech.instrument_lines(player, pos, give)
	local name = player:get_player_name()
	local node = core.get_node(pos)
	if rockmech.is_rubble(node.name) or rockmech.road_level[node.name] then return rubble_lines(node, name, give, pos) end
	if rockmech.lith_of_node[node.name] then
		local lines = fmt_report_lines(rockmech.stress_report(pos), name, give)
		if #lines == 0 and give.grade then lines[1] = S("No ore") end      -- XRF 對著不含礦的岩石
		return lines
	end
	return {}
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
	local now = core.get_us_time() / 1e6
	for _, player in ipairs(core.get_connected_players()) do
		local name = player:get_player_name()
		local pos = pointed_node_pos(player, 8)
		local key = pos and core.pos_to_string(pos)
		-- 儀器的結果還在：時間到、或視線移開那一格就收掉
		local a = active[name]
		if a and (now > a.untl or (a.key and a.key ~= key)) then active[name], a = nil, nil end
		if a then
			hud_set(player, a.text)
		else
			-- 自己會的能力：指著岩石或碎石就顯示（什麼都不會就不顯示）
			local node = hud_enabled(player) and pos and core.get_node(pos)
			local rubble = node and (rockmech.is_rubble(node.name) or rockmech.road_level[node.name])
			local h = huds[name]
			local fac = node and not rubble and not rockmech.lith_of_node[node.name] and rockmech.facility_info
				and rockmech.facility_info(pos, node.name)
			if fac then
				hud_set(player, fac)                 -- 設施：名稱、耐久度（不用知識能力）
				huds[name].key = nil
				last[name] = nil
			elseif rubble or node and rockmech.lith_of_node[node.name] then
				-- 指向改變時立即更新；同一格每 2 秒更新一次（周圍可能已被開挖）
				local l = last[name]
				if not l or l.key ~= key or l.t > 2 then
					last[name] = {key = key, t = 0}
					local rep = not rubble and rockmech.stress_report(pos)
					local lines = rubble and rubble_lines(node, name, nil, pos) or fmt_report_lines(rep, name)
					local text = #lines > 0 and table.concat(lines, "\n") or nil
					if text then
						hud_set(player, text)
						huds[name].key, huds[name].t = key, 0
					else
						text_remove(player)
					end
				else
					l.t = l.t + dt
				end
			else
				hud_remove(player)
				last[name] = nil
			end
		end
	end
end)

core.register_on_leaveplayer(function(player)
	huds[player:get_player_name()] = nil
	last[player:get_player_name()] = nil
	active[player:get_player_name()] = nil
end)

core.register_chatcommand("rockmech_hud", {
	params = "[on|off]",
	description = S("Turn the on-screen in-situ stress HUD on or off (no argument toggles it)"),
	func = function(name, param)
		local player = core.get_player_by_name(name)
		if not player then return false, S("Player not found") end
		local on
		if param == "on" then on = true elseif param == "off" then on = false
		else on = not hud_enabled(player) end
		rockmech.set_hud(player, on)
		return true, S("In-situ stress HUD: @1", onoff(on))
	end,
})

---------------------------------------------------------------------------
-- 完整資訊頁
---------------------------------------------------------------------------

local FORM = "rockmech:info"
local TABS = {F(S("Overview")), F(S("Lithology")), F(S("Joints")), F(S("Stress")), F(S("Toggles"))}
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
	local f, o, rf, sp, sl = cfg.failure, cfg.overhang, cfg.rockfall, cfg.stability, cfg.slope
	local rows = kv_rows({
		{S("World folder"), core.get_worldpath()},
		{S("Surface elevation y0"), cfg.surface_y},
		{S("Lithology layout"), cfg.lith_mode == "zones" and S("zones (width @1 m)", tostring(cfg.zone_width)) or S("layered by depth")},
		{S("Lithologies only / strip soil"), ("%s / %s"):format(cfg.only_lithologies and S("yes") or S("no"), cfg.strip_soil and S("yes") or S("no"))},
		{"K0", cfg.k0},
		{"σH = K_H·σv + σH0", ("K_H %.2f，σH0 %g MPa"):format(cfg.KH, cfg.sH0)},
		{"σh = K_h·σv + σh0", ("K_h %.2f，σh0 %g MPa"):format(cfg.Kh, cfg.sh0)},
		{S("σH azimuth"), S("@1° (clockwise from north)", tostring(cfg.sH_azimuth))},
		{S("Joint lattice density"), cfg.joint_lattice},
		{S("Scale factor N"), S("@1 (1 m in game = @2 m in reality; σci, σt and joint c are all ÷ N)",
			("%g"):format(cfg.model_scale), ("%g"):format(cfg.model_scale))},
		{S("Rock mass GSI (surface→depth @@ transition depth)"), (function()
			local t = {}
			for _, key in ipairs(cfg.lithology_order) do
				local l = cfg.lithologies[key]
				t[#t + 1] = ("%s %s"):format(S(l.description), rockmech.gsi_profile_str(l.gsi))
			end
			return table.concat(t, ", ") .. ("; D %g"):format(cfg.rockmass.d)
		end)()},
		{S("Deviatoric failure"), S("@1; Hoek-Brown rock mass strength, radius @2, window ±@3, cascade @4 rounds@5",
			onoff(f.enabled), ("%d"):format(f.radius), ("%d"):format(f.window), ("%d"):format(f.max_cascade),
			f.strength_scale ~= 1 and S("; legacy setting strength_scale @1", ("%g"):format(f.strength_scale)) or "")},
		{S("Overhang failure"), S("@1; radius @2@3", onoff(o.enabled), ("%d"):format(o.radius),
			o.scale ~= 1 and S("; legacy setting overhang_scale @1", ("%g"):format(o.scale)) or "")},
		{S("Stability check"), S("@1; radius @2, rigid-body limit @3 cells", onoff(sp.enabled), ("%d"):format(sp.radius), ("%d"):format(sp.rigid_max))},
		{S("Rubble angle of repose"), ("%s; %g°"):format(onoff(sl.enabled), sl.angle)},
		{S("Rockfall rolling"), S("@1; other surfaces Rn @2 Rt @3 μr @4", onoff(rf.enabled),
			("%.2f"):format(rf.rn), ("%.2f"):format(rf.rt), ("%.2f"):format(rf.mu_roll))},
		{S("Breakage on falling"), onoff(cfg.fallbreak.enabled)},
		{S("Joint textures"), ("%s; %s"):format(onoff(cfg.jointtex.enabled), cfg.jointtex.style)},
	})
	return table_el(0.3, 0.9, 16.4, 9.2, "rm_t1", "text;text", rows)
end

local function tab_lith()
	local rows = {{S("Lithology"), "γ (kN/m³)", "σci (MPa)", "σt (MPa)", "mi", "GSI", S("Surface σc,m / σt,m"),
		S("Deep σc,m / σt,m"), S("L_max for 1 / 4 m thickness (surface)"), S("Breakage h_ref (m)")}}
	local rock = rockmech.collapse.rock
	for _, key in ipairs(cfg.lithology_order) do
		local l = cfg.lithologies[key]
		local top = rock.at(key, cfg.surface_y, nil)
		local deep = rock.at(key, cfg.surface_y - 1e6, nil)
		local function lm(t) return ("%.1f"):format(rockmech.overhang.lmax(top.sigt, l.gamma, t, cfg.overhang.scale)) end
		rows[#rows + 1] = {S(l.description), l.gamma, l.ucs, l.tensile, l.mi or "-", rockmech.gsi_profile_str(l.gsi),
			("%.3g / %.3g"):format(top.ucs_m, top.sigt), ("%.3g / %.3g"):format(deep.ucs_m, deep.sigt),
			lm(1) .. " / " .. lm(4) .. " m", l.break_height or "-"}
	end
	local c = "text;text,align=right;text,align=right;text,align=right;text,align=right;text,align=right;" ..
		"text,align=right;text,align=right;text,align=right;text,align=right"
	return table_el(0.3, 0.9, 16.4, 4, "rm_t2", c, rows) ..
		("label[0.3,5.4;%s]"):format(F(S("σci and σt are intact rock (laboratory) values; rock mass strength follows Hoek-Brown (GSI, mi, D) and is divided by the scale factor N=@1.",
			("%g"):format(cfg.model_scale)))) ..
		("label[0.3,5.9;%s]"):format(F(S("σc,m = σci·s^a (unconfined, at a free face); σt,m = σt·s·mi/mb; L_max = √(σt,m·t / (3γ)); the roof span is about twice that.")))
end

local function tab_joints()
	local rows = {{S("Joint set"), S("Input dip / dip direction"), S("Aligned dip / dip direction"), S("Integer normal m"),
		S("Spacing input → effective"), S("Persistence"), "Jr / Ja → φj", S("Texture levels")}}
	local sets = rockmech.get_joint_sets()
	for _, js in ipairs(sets) do
		rows[#rows + 1] = {js.name, ("%g° / %g°"):format(js.dip, js.dipdir),
			("%.1f° / %.1f°"):format(js.dip_eff, js.dipdir_eff),
			("(%d, %d, %d)"):format(js.mx, js.my, js.mz),
			("%g → %.2f m"):format(js.spacing, js.spacing_eff),
			js.persistence, (js.jr and ("%g / %g → "):format(js.jr, js.ja) or "") .. ("%.1f°"):format(js.phi), rockmech.jointtex.levels(js)}
	end
	return table_el(0.3, 0.9, 16.4, 3.5, "rm_t3", "text;text;text;text;text;text,align=right;text,align=right;text,align=right", rows) ..
		("label[0.3,4.9;%s]"):format(F(S("Coordinates: x = east, y = up, z = north; dip direction is clockwise from north. Joint normals are aligned to the integer lattice so traces stay continuous across blocks.")))
end

local function tab_stress(name)
	local st = state[name]
	local r = st and st.report
	local out = {("button[0.3,0.7;5,0.7;rm_refresh;%s]"):format(F(S("Recalculate for the block you are pointing at")))}
	if not r then
		out[#out + 1] = ("label[0.3,1.9;%s]"):format(F(S("(not pointing at any block)")))
		return table.concat(out)
	end
	local i, s = r.init, r.local_state
	local rows = kv_rows({
		{S("Position"), core.pos_to_string(r.pos)},
		{S("Node"), r.name},
		{S("Lithology"), r.is_rock and S(r.lith.description) or S("@1 (not rock; using the lithology at this location)", S(r.lith.description))},
		{S("Overburden thickness h"), S("@1 m (surface y=@2@3)", ("%d"):format(i.h), ("%d"):format(i.top_y),
			i.extrapolated and S(", beyond the scan range, extrapolated to y0") or "")},
		{S("Initial σv = Σγ·Δh"), S("@1 MPa (before excavation, voids treated as rock)", ("%.3f"):format(i.sv))},
		{S("Initial σH / σh"), ("%.3f / %.3f MPa (σH %g°)"):format(i.sH, i.shmin, cfg.sH_azimuth)},
		{S("Initial σxx / σzz / σxz"), ("%.3f / %.3f / %.3f MPa"):format(i.sxx, i.szz, i.sxz)},
	})
	if s then
		for _, kv in ipairs({
			{S("Column load → spread σyy"), ("%.3f → %.3f MPa (×%.2f)"):format(s.sv0, s.sv, s.factor)},
			{S("Local σxx (×concentration)"), ("%.3f MPa (×%.2f)"):format(s.sx, s.fx)},
			{S("Local σyy"), ("%.3f MPa"):format(s.sy)},
			{S("Local σzz (×concentration)"), ("%.3f MPa (×%.2f)"):format(s.sz, s.fz)},
			{S("Local σxz"), ("%.3f MPa"):format(s.sxz)},
			{S("Principal stresses σ1 / σ3"), ("%.3f / %.3f MPa"):format(s.s1, s.s3)},
			{S("Normal pressure on free faces (support pᵢ, rubble lateral pressure)"), ("%.3f MPa"):format(s.p_support or 0)},
			{S("Rock mass strength"), rockmech.rockmass_line(s.rm)},
			{S("q = σ1 − σ3 / rock mass strength q_f(σ3)"), ("%.3f / %.3f MPa"):format(s.q, s.strength)},
			{S("Deviatoric FS"), ("%.2f"):format(s.fs_axial)},
			{S("Joint weakness planes"), rockmech.slip_line(s)},
			{S("Overhang"), rockmech.overhang_line(r.overhang)},
			{S("Nearby free-face cells"), rockmech.nearby_line(r.nearby)},
			{S("Key block"), rockmech.keyblock_line(r.keyblock)},
			{S("Free faces"), (function()
				local ex = {}
				if s.exposed_x then ex[#ex + 1] = S("east-west") end
				if s.exposed_z then ex[#ex + 1] = S("north-south") end
				if s.exposed_up then ex[#ex + 1] = S("top") end
				if s.exposed_down then ex[#ex + 1] = S("bottom") end
				return table.concat(ex, " ")
			end)()},
			{S("Verdict"), s.fails_axial and S("deviatoric failure") or s.fails_slip and S("sliding along a joint")
				or (s.q >= s.strength and S("exceeds strength but no free face") or S("stable"))},
		}) do rows[#rows + 1] = {kv[1], kv[2]} end
	end
	-- 六個面的節理
	local sets = rockmech.get_joint_sets()
	local label = {E = S("East face (+x)"), W = S("West face (-x)"), Up = S("Top face (+y)"), Dn = S("Bottom face (-y)"),
		N = S("North face (+z)"), S = S("South face (-z)")}
	for _, face in ipairs(joints.FACES) do
		local fx, fy, fz, axis = joints.face_key(r.pos.x, r.pos.y, r.pos.z, face)
		local parts = {}
		for _, it in ipairs(joints.face_info(sets, fx, fy, fz, axis)) do
			parts[#parts + 1] = it.joint and S("@1 joint", sets[it.set].name) or S("@1 rock bridge", sets[it.set].name)
		end
		rows[#rows + 1] = {label[face.name], #parts > 0 and table.concat(parts, ", ") or S("intact")}
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
	out[#out + 1] = ("checkbox[0.3,%g;rm_hud;%s;%s]"):format(y, F(S("Show in-situ stress on screen (HUD)")),
		tostring(player and hud_enabled(player) or false))
	y = y + 0.6
	out[#out + 1] = ("checkbox[0.3,%g;rm_fsmask;%s;%s]"):format(y,
		F(S("Mark nearby rock cells with FS ≤ 1 (red = joint sliding, orange = deviatoric, purple = overhang / cut off by joints)")),
		tostring(player and rockmech.fsmask_live and rockmech.fsmask_live(player) or false))
	y = y + 0.6
	out[#out + 1] = ("checkbox[0.3,%g;rm_fswarn;%s;%s]"):format(y,
		F(S("Warning cracks: rock cells whose FS drops to 1 < FS < @1 because of excavation get cracks (the closer to 1, the worse the cracks)",
			("%g"):format(cfg.fswarn.max))),
		tostring(player and rockmech.fswarn_enabled and rockmech.fswarn_enabled(player) or false))
	out[#out + 1] = ("label[0.3,%g;%s]"):format(y + 0.6, F(S("Changing the mechanics toggles needs the rockmech privilege; the HUD, FS mask and warning cracks are set per player.")))
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

-- 測試／除錯用：產生某玩家某分頁的 formspec 字串
function rockmech.info_formspec(name, tab, report)
	state[name] = {tab = tab, report = report}
	return build(name)
end

-- 經營模式：完整資訊頁是除錯用的，只有開了 /god 或有 server 權限的人看得到
local function debug_allowed(name)
	if not cfg.career then return true end
	local p = core.get_player_by_name(name)
	return (p and p:get_meta():get_int("godmode:on") == 1) or core.check_player_privs(name, {server = true})
end
rockmech.debug_allowed = debug_allowed
function rockmech.show_info(name)
	if not debug_allowed(name) then
		rockmech.notify(name, S("[rockmech] The info page is for debugging (only visible with /god on)"))
		return
	end
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
			rockmech.notify(name, "[rockmech] " .. msg)
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
	description = S("Open the full rockmech info page (overview, lithology, joints, stress, toggles)"),
	func = function(name)
		rockmech.show_info(name)
		return true
	end,
})
