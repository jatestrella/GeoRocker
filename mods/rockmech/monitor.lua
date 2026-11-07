-- rockmech/monitor.lua
-- 監測儀器：監測稜鏡（rockmech:survey_prism，工具室管理員）貼在岩面上，讀那一格岩石的位移。
--   應力解（femstress.lua）每算一次涵蓋到它，就記一筆：從安裝那一刻算起的位移變化（mm），跟真的儀器一樣只量變化。
--   收斂：隧道兩壁各貼一個，看兩邊往內移多少。右鍵打開看歷史曲線。
-- 位移的大小：應力解的勁度只是數值尺度（fem.lua 的 E = 1 GPa），換成岩體變形模數 E_rm（Hoek & Diederichs 2006）：
--   E_rm = E_i · (0.02 + (1 − D/2) / (1 + e^((60 + 15D − GSI)/11)))，E_i = MR · UCS
--   MR（模數比）照 Hoek 的表：頁岩 150、砂岩 275、花崗岩 425、煤 200；D 是爆破擾動（rockmass.lua）。

local cfg = rockmech.cfg
local PRISM = "rockmech:survey_prism"
local FORM = "rockmech:survey_prism"
local HIST_N = 60
local E_FEM = 1e6           -- kPa，fem.lua 的數值勁度
local MR = {shale = 150, sandstone = 275, granite = 425, coal = 200}

-- 岩體變形模數 (MPa)
function rockmech.erm(lith_key, gsi, D)
	local lith = cfg.lithologies[lith_key]
	if not lith then return nil end
	D = D or 0
	local ei = (lith.mr or MR[lith_key] or 300) * lith.ucs
	return ei * (0.02 + (1 - D / 2) / (1 + math.exp((60 + 15 * D - gsi) / 11)))
end

local function attached(pos, node)
	return vector.add(pos, core.wallmounted_to_dir(node.param2))
end

local function hist_of(meta)
	local h = core.deserialize(meta:get_string("hist"))
	return type(h) == "table" and h or {}
end

local function info(meta)
	local h = hist_of(meta)
	local last = h[#h]
	if not last then return "監測稜鏡\n還沒有讀數（附近開挖、算過應力後才有）" end
	local prev = h[#h - 1]
	return ("監測稜鏡\n位移 %.2f mm%s（%d 筆，右鍵看曲線）"):format(last.d,
		prev and ("（上次 %+.2f mm）"):format(last.d - prev.d) or "", #h)
end

-- 應力解算完（femstress.lua 的 fem_run 呼叫）：範圍裡的稜鏡記一筆
function rockmech.monitor_update(job, res, meta)
	if not (res and res.u) then return end
	local n, a = job.nx, meta.a
	local Nx, Ny = n + 1, n + 1
	local u = res.u
	for _, pos in ipairs(core.find_nodes_in_area(vector.subtract(a, 1), vector.add(a, n), {PRISM})) do
		local node = core.get_node(pos)
		local q = attached(pos, node)
		local x, y, z = q.x - a.x, q.y - a.y, q.z - a.z
		if x >= 0 and y >= 0 and z >= 0 and x < n and y < n and z < n then
			local c = 1 + x + y * n + z * n * n
			local key = meta.lith[c]
			if job.solid[c] and not job.soft[c] and key then
				-- 格中心的位移 = 8 個角的平均（Δu / h，h = 1 m，勁度 E_FEM）
				local ux, uy, uz = 0, 0, 0
				for k = 0, 7 do
					local i, j, l = k % 2, math.floor(k / 2) % 2, math.floor(k / 4)
					local ni = ((x + i) + (y + j) * Nx + (z + l) * Nx * Ny) * 3
					ux, uy, uz = ux + (u[ni + 1] or 0), uy + (u[ni + 2] or 0), uz + (u[ni + 3] or 0)
				end
				local rm = rockmech.collapse.rock.at(key, q.y, meta.p2[c], meta.dmg and meta.dmg[c])
				local D = rockmech.damage_at and rockmech.damage_at(q) or (cfg.rockmass.d or 0)
				local erm = rockmech.erm(key, rm.gsi, D) or 1000
				local s = E_FEM / (erm * 1000) * 1000 / 8      -- → mm
				ux, uy, uz = ux * s, uy * s, uz * s
				local m = core.get_meta(pos)
				local h = hist_of(m)
				-- 第一筆是安裝時的基準：之後記的是從安裝算起的變化
				if m:get_string("base") == "" then m:set_string("base", core.serialize({ux, uy, uz})) end
				local b = core.deserialize(m:get_string("base")) or {0, 0, 0}
				local dx, dy, dz = ux - b[1], uy - b[2], uz - b[3]
				h[#h + 1] = {t = core.get_gametime() or 0, d = math.sqrt(dx * dx + dy * dy + dz * dz), x = dx, y = dy, z = dz}
				while #h > HIST_N do table.remove(h, 1) end
				m:set_string("hist", core.serialize(h))
				m:set_string("infotext", info(m))
			end
		end
	end
end

-- 歷史曲線：橫軸是讀數的順序，縱軸是位移 (mm)
local function form(pos)
	local m = core.get_meta(pos)
	local h = hist_of(m)
	local out = {"formspec_version[6]size[12,8.4]",
		("label[0.4,0.5;%s]"):format(core.formspec_escape(("監測稜鏡 %s　從安裝算起的位移"):format(core.pos_to_string(pos))))}
	if #h == 0 then
		out[#out + 1] = "label[0.4,1.4;還沒有讀數：附近開挖、算過應力之後才會記錄]"
	else
		local maxd = 0.1
		for _, e in ipairs(h) do maxd = math.max(maxd, e.d) end
		local X0, Y0, W, H = 1.4, 1.2, 10.2, 5
		out[#out + 1] = ("box[%g,%g;%g,%g;#20242a]"):format(X0, Y0, W, H)
		for k = 0, 4 do
			local yy = Y0 + H - H * k / 4
			out[#out + 1] = ("box[%g,%g;%g,0.02;#3a4048]"):format(X0, yy, W)
			out[#out + 1] = ("label[0.3,%g;%s]"):format(yy, ("%.2f"):format(maxd * k / 4))
		end
		local bw = W / HIST_N
		for i, e in ipairs(h) do
			local bh = math.max(0.03, H * e.d / maxd)
			out[#out + 1] = ("box[%g,%g;%g,%g;#40c0ff]"):format(X0 + (i - 1) * bw + bw * 0.15, Y0 + H - bh, bw * 0.7, bh)
		end
		local last = h[#h]
		out[#out + 1] = ("label[0.4,6.7;%s]"):format(core.formspec_escape(("最新：位移 %.2f mm（東西 %+.2f、上下 %+.2f、南北 %+.2f mm），共 %d 筆")
			:format(last.d, last.x, last.y, last.z, #h)))
		out[#out + 1] = "label[0.4,7.2;mm（縱軸）／每次應力解一筆（橫軸）。讀數一直變大要小心；加了支撐之後應該會趨於穩定]"
	end
	out[#out + 1] = "button[0.4,7.6;3,0.6;reset;重新歸零]"
	out[#out + 1] = "button_exit[8.6,7.6;3,0.6;close;關閉]"
	return table.concat(out)
end

local viewing = {}
core.register_node(PRISM, {
	description = "監測稜鏡 Survey prism\n貼在岩面上，記錄那裡的岩石位移（附近開挖、算應力時更新）；右鍵看曲線",
	drawtype = "nodebox", paramtype = "light", paramtype2 = "wallmounted", sunlight_propagates = true,
	node_box = {type = "wallmounted",
		wall_top = {-0.15, 0.4, -0.15, 0.15, 0.5, 0.15},
		wall_bottom = {-0.15, -0.5, -0.15, 0.15, -0.4, 0.15},
		wall_side = {-0.5, -0.15, -0.15, -0.4, 0.15, 0.15}},
	tiles = {"[fill:16x16:#f0f0f0^[fill:8x8:4,4:#e85020^[fill:4x4:6,6:#202020"},
	walkable = false, is_ground_content = false,
	groups = {dig_immediate = 2, attached_node = 1},
	on_place = function(itemstack, placer, pointed)
		if pointed.type ~= "node" or not rockmech.lith_of_node[core.get_node(pointed.under).name] then
			if placer and placer:is_player() then core.chat_send_player(placer:get_player_name(), "[監測] 要貼在岩面上") end
			return itemstack
		end
		return core.item_place_node(itemstack, placer, pointed)
	end,
	after_place_node = function(pos)
		local m = core.get_meta(pos)
		m:set_string("infotext", info(m))
	end,
	on_rightclick = function(pos, node, clicker, itemstack)
		if clicker and clicker:is_player() then
			viewing[clicker:get_player_name()] = pos
			core.show_formspec(clicker:get_player_name(), FORM, form(pos))
		end
		return itemstack
	end,
})
core.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= FORM then return end
	local name = player:get_player_name()
	local pos = viewing[name]
	if fields.quit then viewing[name] = nil; return true end
	if fields.reset and pos and core.get_node(pos).name == PRISM then
		local m = core.get_meta(pos)
		m:set_string("hist", ""); m:set_string("base", "")
		m:set_string("infotext", info(m))
		core.show_formspec(name, FORM, form(pos))
	end
	return true
end)
core.register_on_leaveplayer(function(player) viewing[player:get_player_name()] = nil end)
