-- rockmech/retain.lua
-- 擋土：鋼板樁、內支撐（H 型鋼）。都是應力解（femstress.lua）裡有勁度的元素，跟木柱、鋼支保同一套：
--   勁度 = 岩石勁度 × 勁度比（等效斷面），沒有現地應力、不加重力，土壓過來才受力。
--   土是彈塑性（fem.lua 的 job.plastic，Drucker-Prager 配 Mohr-Coulomb）：牆後的土到了強度上限就以主動土壓推牆，
--   牆腳被擠的土最多頂到被動土壓；土的破壞 = 塑性迭代到上限還在流動（形成機構）。
--   牆後的土破壞變成碎石，碎石的側壓（K0·γ·z）也推在板樁上（femstress.lua 的鬆散材料荷重）。
--
--   鋼板樁（SP-III 型，寬 1 m）：拿著對地面按右鍵，那一欄從地面往下打，打到 PILE_LEN m 或打不進去為止，一片就是一整欄。
--     打得進：土、碎石，和岩體強度 σcm 不超過可裂性門檻的軟岩（跟推土機松土同一個門檻、同一個研發）。
--     方塊是整格的土夾一片鋼板：鋼板在打樁的人那一側（要開挖的那一側），挖開後露出一整排鋼板，後面是擋住的土。
--     一格是 1 m 厚的實心元素，勁度比照「抗彎勁度 EI 相同」換算（E_eff = EI / (1/12)）；
--     彎矩 M = 板厚方向兩面的鉛直應力差 / 12（一格元素裡應力沿板厚線性變化）→ 就是真實板樁的彎矩。
--     M 超過降伏彎矩 M_y = fy·Z（÷ 相似比）→ 整欄降伏變形（勁度剩 1/10，荷重轉給土）。
--     打下去的格記成開挖過（天然地形那一解照原本的土、岩石算，不會多出一條溝）。
--     挖它：整欄拔起來、退還一片（降伏過的不退）；接在上面的支撐跟著拆、退還。
--   內支撐（H300×300）：拿著對板樁露出來的那一面按右鍵，從那裡水平往前鋪到對面第一個實心的東西（最長 MAX_SPAN m），
--     每 1 m 用一支。勁度比照「軸向勁度 EA 相同」；軸力 N = 支撐方向的應力 × 1 m²，
--     超過 min(降伏 fy·A, 尤拉挫屈 π²EI/L²)（L = 支撐全長）÷ 相似比 → 挫屈，整支掉下來（不退還）。
--     支撐兩端碰到板樁，板樁自動換成有圍令（橫向的 H 型鋼橫擋）的樣子。挖支撐：整支拆下、退還。

local S = rockmech.S
local cfg = rockmech.cfg
local collapse = rockmech.collapse

local PILE, PILE_W, PILE_B = "rockmech:sheet_pile", "rockmech:sheet_pile_wale", "rockmech:sheet_pile_bent"
local STRUT = "rockmech:strut"
local IS_PILE = {[PILE] = true, [PILE_W] = true, [PILE_B] = true}
local PILE_LEN = math.max(2, tonumber(core.settings:get("rockmech_sheet_pile_len") or "") or 9)   -- 一片板樁的長度 (m)
local MAX_SPAN = 30

-- 斷面與材料（kN、m）。勁度比的基準：岩體 E 約 7.5 GPa（materials.lua：土 15 MPa ÷ 岩體 3–11 GPa 的那個比例）
local E_STEEL, FY = 2.0e8, 295e3            -- kPa（SY295）
local E_ROCK_REF = 7.5e6
local PILE_I, PILE_Z = 1.68e-4, 1.34e-3      -- SP-III：每公尺寬 I (m⁴/m)、Z (m³/m)
local STRUT_A, STRUT_I = 1.184e-2, 6.75e-5   -- H300×300×10×15：A (m²)、弱軸 I (m⁴)
local PILE_R = E_STEEL * PILE_I * 12 / E_ROCK_REF      -- ≈ 0.054
local STRUT_R = E_STEEL * STRUT_A / E_ROCK_REF         -- ≈ 0.32
local BENT_R = 0.1
local function n_scale() return cfg.model_scale or 1 end
local function pile_my() return FY * PILE_Z / n_scale() end                           -- kN·m/m
local function strut_cap(L) return math.min(FY * STRUT_A, math.pi ^ 2 * E_STEEL * STRUT_I / (L * L)) / n_scale() end   -- kN

local function d(v) return ("%d"):format(math.floor(v + 0.5)) end
local function tell_near(p, msg)
	for _, pl in ipairs(core.get_connected_players()) do
		if vector.distance(pl:get_pos(), p) <= 32 then rockmech.notify(pl:get_player_name(), msg) end
	end
end

---------------------------------------------------------------------------
-- 方塊
---------------------------------------------------------------------------

local STEEL = "[fill:16x16:#5c6268^[fill:2x16:2,0:#41474c^[fill:2x16:7,0:#41474c^[fill:2x16:12,0:#41474c"
local RUST = "[fill:16x16:#6e5440^[fill:2x16:2,0:#4e3a2c^[fill:2x16:7,0:#4e3a2c^[fill:2x16:12,0:#4e3a2c"
local BEAM = "[fill:16x16:#7a8086^[fill:16x2:0,7:#5a6066"
-- 板樁格 = 土裡夾一片鋼板：整格方塊，五面是泥土，朝打樁的人那一面（−z，facedir 轉過）是鋼板。
-- 打下去地面看起來還是一整片土；在你這一側往下挖，挖開的牆面露出一整排鋼板，後面是擋住的土。
-- 圍令（接了支撐）：鋼板面上畫一條橫向的 H 型鋼
local DIRT = core.registered_nodes["default:dirt"] and "default_dirt.png" or "[fill:16x16:#6a5030"
local WALE_FACE = STEEL .. "^[fill:16x5:0,6:#7a8086^[fill:16x1:0,8:#5a6066"
local base = {
	paramtype2 = "facedir", is_ground_content = false, groups = {cracky = 2, rockmech_retain = 1},
	sounds = default and default.node_sound_metal_defaults and default.node_sound_metal_defaults() or nil,
}
local function def_with(t)
	local o = table.copy(base)
	for k, v in pairs(t) do o[k] = v end
	return o
end
-- 填充材料（打進去的那一格原本是什麼）：土 → 泥土外觀；碎石、鬆土、軟岩（打樁把它擠碎）→ 碎石外觀。
-- 含礦、品位不同的碎石都用同一個外觀；原本的方塊、品位、成分記在板樁格的 meta（fill），拔起來照原樣填回去
local RUBBLE_TEX = (function()
	local d = rockmech.RUBBLE and core.registered_nodes[rockmech.RUBBLE]
	local t = d and d.tiles and d.tiles[1]
	if type(t) == "table" then t = t.name end
	return t or "[fill:16x16:#7a7470"
end)()
local FILLS = {soil = {suffix = "", tex = DIRT}, rubble = {suffix = "_r", tex = RUBBLE_TEX}}
local STATES = {plain = {suffix = "", face = STEEL}, wale = {suffix = "_wale", face = WALE_FACE}, bent = {suffix = "_bent", face = RUST}}
local PILE_INFO = {}          -- 方塊名稱 → {fill, state}
local function pile_name(fill, state) return "rockmech:sheet_pile" .. FILLS[fill].suffix .. STATES[state].suffix end
for fk, f in pairs(FILLS) do
	for sk, st in pairs(STATES) do
		local name = pile_name(fk, sk)
		local first = fk == "soil" and sk == "plain"       -- 物品就是這一種
		local t = f.tex
		core.register_node(name, def_with({
			description = first and S("Sheet pile\nRight-click the ground: drives a 1 m wide sheet pile down (@1 m, until it meets hard rock); the steel face is on your side, the side you will dig", tostring(PILE_LEN))
				or (sk == "bent" and S("Sheet pile (yielded)") or S("Sheet pile")),
			short_description = first and S("Sheet pile") or nil,
			tiles = {t, t, t, t, t, st.face},      -- +Y −Y +X −X +Z −Z
			inventory_image = first and "[fill:16x16:#00000000^[fill:10x14:3,1:#5c6268^[fill:2x14:5,1:#41474c^[fill:2x14:9,1:#41474c" or nil,
			drop = sk == "bent" and "" or PILE,
			groups = first and {cracky = 2, rockmech_retain = 1} or {cracky = 2, rockmech_retain = 1, not_in_creative_inventory = 1},
		}))
		PILE_INFO[name] = {fill = fk, state = sk}
		IS_PILE[name] = true
	end
end
-- 會受力的板樁（一般、有圍令；降伏的不再算彎矩）
local PILE_LIVE = {}
for name, i in pairs(PILE_INFO) do if i.state ~= "bent" then PILE_LIVE[#PILE_LIVE + 1] = name end end
-- 支撐（H 型鋼，nodebox）
base = {
	drawtype = "nodebox", paramtype = "light", paramtype2 = "facedir", sunlight_propagates = true,
	is_ground_content = false, groups = {cracky = 2, rockmech_retain = 1},
	sounds = base.sounds,
}
core.register_node(STRUT, def_with({
	description = S("Strut (H-beam)\nRight-click a sheet pile face: lays a horizontal strut across to the opposite side (1 per metre)"),
	short_description = S("Strut"),
	tiles = {BEAM}, node_box = {type = "fixed", fixed = {
		{-0.18, -0.18, -0.5, 0.18, -0.12, 0.5}, {-0.18, 0.12, -0.5, 0.18, 0.18, 0.5}, {-0.03, -0.12, -0.5, 0.03, 0.12, 0.5}}},
	inventory_image = "[fill:16x16:#00000000^[fill:14x3:1,3:#7a8086^[fill:14x3:1,10:#7a8086^[fill:14x4:1,6:#5a6066",
}))

---------------------------------------------------------------------------
-- 打板樁
---------------------------------------------------------------------------

-- 打得進去：土、碎石、岩體強度 σcm ≤ 可裂性門檻的軟岩（研發「推土機推力」一起提高）
local function drivable(p, who)
	local node = core.get_node(p)
	local n = node.name
	if rockmech.is_rubble(n) or core.get_item_group(n, "rockmech_topsoil") > 0 then return true end
	local lith = rockmech.lith_of_node[n]
	if not lith then return false end
	local D = collapse.damage_at_xyz and collapse.damage_at_xyz(p.x, p.y, p.z)
	local sc = collapse.rock.at(lith.name, p.y, node.param2, D).sigcm
	local limit = rockmech.eff_rip_sigcm and rockmech.eff_rip_sigcm(who) or cfg.dozer_rip_sigcm
	return sc <= limit, sc, limit
end

local function horizontal_facedir(v)
	if math.abs(v.x) > math.abs(v.z) then return v.x > 0 and 1 or 3 end
	return v.z > 0 and 0 or 2
end

local function pile_info(p, extra)
	local m = core.get_meta(p)
	m:set_string("infotext", S("Sheet pile") .. (extra and ("\n" .. extra) or ""))
end

core.override_item(PILE, {on_place = function(itemstack, placer, pointed)
	if pointed.type ~= "node" or not placer then return itemstack end
	local name = placer:get_player_name()
	local top = pointed.under
	if IS_PILE[core.get_node(top).name] then
		rockmech.notify(name, S("[Sheet pile] Already driven here")); return itemstack
	end
	local dir = horizontal_facedir(placer:get_look_dir())
	local cells, why = {}, nil
	for k = 0, PILE_LEN - 1 do
		local p = {x = top.x, y = top.y - k, z = top.z}
		if core.is_protected(p, name) then break end
		local ok, sc, limit = drivable(p, name)
		if not ok then
			if sc then why = S("Rock too hard to drive into (rock mass strength @1 MPa > @2 MPa)", d(sc), d(limit)) end
			break
		end
		cells[#cells + 1] = p
	end
	if #cells == 0 then
		rockmech.notify(name, "[" .. S("Sheet pile") .. "] " .. (why or S("Can't drive here: only soil, rubble and soft rock")))
		return itemstack
	end
	for _, p in ipairs(cells) do
		-- 原本那一格（方塊、param2 品位、meta 成分）記下來，拔樁時填回去
		local old = core.get_node(p)
		local meta = core.get_meta(p)
		local keep = core.serialize({name = old.name, param2 = old.param2, meta = meta:to_table()})
		local fill = core.get_item_group(old.name, "rockmech_topsoil") > 0 and "soil" or "rubble"
		core.swap_node(p, {name = pile_name(fill, "plain"), param2 = dir})
		meta:from_table(nil)
		meta:set_string("fill", keep)
		collapse.mark_excavated(p)          -- 天然地形那一解照原本的材料（femstress.lua）
		pile_info(p)
	end
	rockmech.notify(name, S("[Sheet pile] Driven @1 m", tostring(#cells)) .. (why and ("; " .. why) or ""))
	if rockmech.fem_queue then rockmech.fem_queue(cells[1], 1, false, false) end
	if not core.is_creative_enabled(name) then itemstack:take_item() end
	return itemstack
end})

---------------------------------------------------------------------------
-- 內支撐
---------------------------------------------------------------------------

local function axis_dir(param2) return core.facedir_to_dir(param2 % 4) end
-- 板樁格 p 有沒有支撐接著（四周水平的支撐，軸向指著它）
local function strut_at(p)
	for _, v in ipairs({{x = 1, y = 0, z = 0}, {x = -1, y = 0, z = 0}, {x = 0, y = 0, z = 1}, {x = 0, y = 0, z = -1}}) do
		local q = vector.add(p, v)
		local nd = core.get_node(q)
		if nd.name == STRUT then
			local a = axis_dir(nd.param2)
			if a.x ~= 0 and v.x ~= 0 or a.z ~= 0 and v.z ~= 0 then return true end
		end
	end
	return false
end
-- 板樁換樣子：有支撐接著 → 有圍令；沒有 → 一般（降伏過的不變）
local function refresh_wale(p)
	local n = core.get_node(p)
	local info = PILE_INFO[n.name]
	if not info or info.state == "bent" then return end
	local want = pile_name(info.fill, strut_at(p) and "wale" or "plain")
	if want ~= n.name then core.swap_node(p, {name = want, param2 = n.param2}) end
end
-- 一支支撐（從 p 沿軸向兩邊連續的支撐格）：回傳 格清單、兩端外面那一格
local function strut_line(p)
	local nd = core.get_node(p)
	local a = axis_dir(nd.param2)
	local cells = {p}
	local ends = {}
	for _, s in ipairs({1, -1}) do
		local q = vector.add(p, vector.multiply(a, s))
		while core.get_node(q).name == STRUT do
			cells[#cells + 1] = q
			q = vector.add(q, vector.multiply(a, s))
		end
		ends[#ends + 1] = q
	end
	return cells, ends
end

core.override_item(STRUT, {on_place = function(itemstack, placer, pointed)
	if pointed.type ~= "node" or not placer then return itemstack end
	local name = placer:get_player_name()
	local from, a0 = pointed.under, pointed.above
	local v = vector.subtract(a0, from)
	if v.y ~= 0 then rockmech.notify(name, S("[Strut] Point at the side face of a sheet pile")); return itemstack end
	local cells, stop = {}, nil
	local q = vector.copy(a0)
	for _ = 1, MAX_SPAN do
		local n = core.get_node(q).name
		local def = core.registered_nodes[n]
		if n == "air" or (def and def.buildable_to) then
			cells[#cells + 1] = vector.copy(q)
			q = vector.add(q, v)
		else
			stop = q
			break
		end
	end
	if not stop or #cells == 0 then
		rockmech.notify(name, S("[Strut] Nothing to brace against within @1 m", tostring(MAX_SPAN))); return itemstack
	end
	local have = itemstack:get_count()
	if not core.is_creative_enabled(name) and have < #cells then
		rockmech.notify(name, S("[Strut] This span needs @1 struts (1 per metre), you have @2", tostring(#cells), tostring(have))); return itemstack
	end
	for _, c in ipairs(cells) do
		if core.is_protected(c, name) then rockmech.notify(name, S("[Strut] Protected area")); return itemstack end
	end
	local p2 = horizontal_facedir(v)
	for _, c in ipairs(cells) do core.set_node(c, {name = STRUT, param2 = p2}) end
	refresh_wale(from); refresh_wale(stop)
	rockmech.notify(name, S("[Strut] Strut @1 m placed", tostring(#cells)))
	if rockmech.fem_queue then rockmech.fem_queue(cells[math.ceil(#cells / 2)], 1, false, false) end
	if not core.is_creative_enabled(name) then itemstack:take_item(#cells) end
	return itemstack
end})

-- 拆：整支／整欄，退還給挖的人
local function give(digger, item, n)
	if not (digger and digger.is_player and digger:is_player()) or n <= 0 then return end
	local left = digger:get_inventory():add_item("main", ItemStack(item .. " " .. n))
	if not left:is_empty() then core.add_item(digger:get_pos(), left) end
end
local function remove_strut(p, digger, refund)
	local cells, ends = strut_line(p)
	for _, c in ipairs(cells) do core.remove_node(c) end
	for _, e in ipairs(ends) do refresh_wale(e) end
	if refund then give(digger, STRUT, #cells) end
	return #cells
end
core.override_item(STRUT, {on_dig = function(pos, node, digger)
	if digger and core.is_protected(pos, digger:get_player_name()) then return false end
	remove_strut(pos, digger, true)
	return true
end})
local function pile_column(p)
	local cells = {}
	local y = p.y
	while IS_PILE[core.get_node({x = p.x, y = y + 1, z = p.z}).name] do y = y + 1 end
	while IS_PILE[core.get_node({x = p.x, y = y, z = p.z}).name] do
		cells[#cells + 1] = {x = p.x, y = y, z = p.z}
		y = y - 1
	end
	return cells
end
for name in pairs(IS_PILE) do
	core.override_item(name, {on_dig = function(pos, node, digger)
		if digger and core.is_protected(pos, digger:get_player_name()) then return false end
		local cells = pile_column(pos)
		local bent = false
		for _, c in ipairs(cells) do
			local info = PILE_INFO[core.get_node(c).name]
			if info and info.state == "bent" then bent = true end
			-- 接在這片上的支撐跟著拆、退還
			for _, v in ipairs({{x = 1, y = 0, z = 0}, {x = -1, y = 0, z = 0}, {x = 0, y = 0, z = 1}, {x = 0, y = 0, z = -1}}) do
				local q = vector.add(c, v)
				if core.get_node(q).name == STRUT then remove_strut(q, digger, true) end
			end
		end
		-- 拔掉：每一格照打下去時記住的原樣填回去（土、碎石、礦石的品位和成分）；沒記到的（舊版打的）留下空的孔
		for _, c in ipairs(cells) do
			local keep = core.deserialize(core.get_meta(c):get_string("fill"))
			if keep and keep.name and core.registered_nodes[keep.name] then
				core.set_node(c, {name = keep.name, param2 = keep.param2 or 0})
				core.get_meta(c):from_table(keep.meta)
			else
				core.remove_node(c)
			end
		end
		if not bent then give(digger, PILE, 1) end
		if rockmech.fem_queue then rockmech.fem_queue(pos, 1, false, false) end
		return true
	end})
end

---------------------------------------------------------------------------
-- 應力解（femstress.lua 每次解完呼叫）：板樁彎矩、支撐軸力
---------------------------------------------------------------------------

local function bend_column(cells)
	for _, c in ipairs(cells) do
		local n = core.get_node(c)
		local info = PILE_INFO[n.name]
		core.swap_node(c, {name = pile_name(info and info.fill or "soil", "bent"), param2 = n.param2})
		core.get_meta(c):set_string("infotext", S("Sheet pile (yielded)"))
	end
	-- 降伏的板樁不再有圍令；接在上面的支撐照舊（還頂著）
	local top = cells[1]
	core.sound_play("default_dug_metal", {pos = top, gain = 1.0, max_hear_distance = 32}, true)
	tell_near(top, S("[Sheet pile] The sheet pile at @1 yielded and bent: the soil behind it now takes the load; add struts", core.pos_to_string(top)))
	core.log("action", ("[rockmech] 鋼板樁降伏 %s（%d m）"):format(core.pos_to_string(top), #cells))
end
local function buckle_strut(p)
	local cells, ends = strut_line(p)
	for _, c in ipairs(cells) do core.remove_node(c) end
	for _, e in ipairs(ends) do refresh_wale(e) end
	local mid = cells[math.ceil(#cells / 2)]
	core.add_particlespawner({amount = 30, time = 0.3,
		minpos = vector.subtract(mid, 0.4), maxpos = vector.add(mid, 0.4),
		minvel = {x = -2, y = -1, z = -2}, maxvel = {x = 2, y = 2, z = 2}, minacc = {x = 0, y = -9.8, z = 0}, maxacc = {x = 0, y = -9.8, z = 0},
		minexptime = 0.5, maxexptime = 1.2, minsize = 1, maxsize = 2, texture = "[fill:4x4:#7a8086"})
	core.sound_play("default_dug_metal", {pos = mid, gain = 1.0, max_hear_distance = 32}, true)
	tell_near(mid, S("[Strut] The strut at @1 buckled", core.pos_to_string(mid)))
	core.log("action", ("[rockmech] 支撐挫屈 %s（%d m）"):format(core.pos_to_string(mid), #cells))
end

-- job, res（fem.lua 的結果，lazy）, meta（femstress.lua：a 原點）
function rockmech.retain_fem_check(job, res, meta)
	local n, a = job.nx, meta.a
	local fem = rockmech.fem
	local function cell(p)
		local x, y, z = p.x - a.x, p.y - a.y, p.z - a.z
		if x < 1 or y < 1 or z < 1 or x >= n - 1 or y >= n - 1 or z >= n - 1 then return nil end
		local c = 1 + x + y * n + z * n * n
		if not job.solid[c] then return nil end
		return c, x, y, z
	end
	local lo, hi = vector.add(a, 1), vector.add(a, n - 2)
	-- 板樁：每一欄取最大的彎矩
	local done = {}
	local My = pile_my()
	for _, p in ipairs(core.find_nodes_in_area(lo, hi, PILE_LIVE)) do
		local key = p.x .. "," .. p.z
		if not done[key] then
			done[key] = true
			local cells = pile_column(p)
			local Mmax = 0
			for _, q in ipairs(cells) do
				local c, x, y, z = cell(q)
				if c then
					local dv = axis_dir(core.get_node(q).param2)
					local s0, s1
					if dv.x ~= 0 then
						s0 = select(2, fem.point_stress(job, res, x, y, z, 0, 0.5, 0.5))
						s1 = select(2, fem.point_stress(job, res, x, y, z, 1, 0.5, 0.5))
					else
						s0 = select(2, fem.point_stress(job, res, x, y, z, 0.5, 0.5, 0))
						s1 = select(2, fem.point_stress(job, res, x, y, z, 0.5, 0.5, 1))
					end
					Mmax = math.max(Mmax, math.abs(s1 - s0) / 12)
				end
			end
			if Mmax > My then
				bend_column(cells)
			else
				local txt = S("Bending moment @1 kN·m/m / yield @2 kN·m/m (@3%)", d(Mmax), d(My), d(Mmax / My * 100))
				for _, q in ipairs(cells) do pile_info(q, txt) end
			end
		end
	end
	-- 支撐：每一支取最大的軸力
	done = {}
	for _, p in ipairs(core.find_nodes_in_area(lo, hi, {STRUT})) do
		local key = core.hash_node_position(p)
		if not done[key] then
			local cells = strut_line(p)
			for _, q in ipairs(cells) do done[core.hash_node_position(q)] = true end
			local N = 0
			for _, q in ipairs(cells) do
				local c = cell(q)
				if c then
					local dv = axis_dir(core.get_node(q).param2)
					N = math.max(N, (dv.x ~= 0 and res.sxx or res.szz)[c])      -- kPa × 1 m² = kN（壓為正）
				end
			end
			local P = strut_cap(#cells)
			if N > P then
				buckle_strut(p)
			else
				local txt = S("Strut") .. "\n" .. S("Axial force @1 kN / capacity @2 kN (@3%)", d(N), d(P), d(N / P * 100))
				for _, q in ipairs(cells) do core.get_meta(q):set_string("infotext", txt) end
			end
		end
	end
end

-- 應力解的勁度比（femstress.lua 的 make_job：support_ids.retain_r，方塊 id → 勁度比）
core.register_on_mods_loaded(function()
	rockmech.support_ids = rockmech.support_ids or {}
	local r = {[core.get_content_id(STRUT)] = STRUT_R}
	for name, info in pairs(PILE_INFO) do
		r[core.get_content_id(name)] = info.state == "bent" and PILE_R * BENT_R or PILE_R
	end
	rockmech.support_ids.retain_r = r
end)
rockmech.retain = {PILE_R = PILE_R, STRUT_R = STRUT_R, pile_my = pile_my, strut_cap = strut_cap, PILE_LEN = PILE_LEN}
