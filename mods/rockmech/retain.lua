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
--   H 型鋼（輕型 H200、重型 H300；支柱、橫撐都是它，見下面 place_hbeam）：對地板按右鍵往上到頂板、對頂板往下、對牆面水平往前，
--     到第一個實心的東西為止（最長 MAX_SPAN m，碰不到就只放 1 m），每 1 m 用一支。相交處像柵欄一樣自動接起來。勁度比照「軸向勁度 EA 相同」；軸力 N = 支撐方向的應力 × 1 m²，
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
local STEEL_FRAC = 0.0191                    -- SP-III 每公尺寬斷面積 191 cm² → 一格 1 m³ 裡鋼的體積比例（倒塌變建築廢棄物）
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
local PILE_ICON = "[fill:16x16:#00000000^[fill:10x14:3,1:#5c6268^[fill:2x14:5,1:#41474c^[fill:2x14:9,1:#41474c"
local FILLS = {soil = {suffix = "", tex = DIRT}, rubble = {suffix = "_r", tex = RUBBLE_TEX}}
local STATES = {plain = {suffix = "", face = STEEL}, wale = {suffix = "_wale", face = WALE_FACE}, bent = {suffix = "_bent", face = RUST}}
local PILE_INFO = {}          -- 方塊名稱 → {fill, state}
local function pile_name(fill, state) return "rockmech:sheet_pile" .. FILLS[fill].suffix .. STATES[state].suffix end
for fk, f in pairs(FILLS) do
	for sk, st in pairs(STATES) do
		local name = pile_name(fk, sk)
		local first = fk == "soil" and sk == "plain"       -- 物品就是這一種
		local t = f.tex
		-- 鋼板的厚度：上面、左右兩面靠鋼板（−z）那一邊畫一條 2 px（約 12 cm）的鋼板色，從上面、側面都看得到板樁的邊。
		-- 貼圖方向（從外面看那一面）：+Y 面圖的下緣是 −z；+X 面（站東邊往西看）圖的左緣是 −z；−X 面圖的右緣是 −z
		local edge = sk == "bent" and "#6e5440" or "#41474c"
		local top = "(" .. t .. ")^[fill:16x2:0,14:" .. edge
		local east = "(" .. t .. ")^[fill:2x16:0,0:" .. edge
		local west = "(" .. t .. ")^[fill:2x16:14,0:" .. edge
		core.register_node(name, def_with({
			description = first and S("Sheet pile\nRight-click the ground: drives a 1 m wide sheet pile down (@1 m, until it meets hard rock); the steel face is on your side, the side you will dig", tostring(PILE_LEN))
				or (sk == "bent" and S("Sheet pile (yielded)") or S("Sheet pile")),
			short_description = first and S("Sheet pile") or nil,
			tiles = {top, t, east, west, t, st.face},      -- +Y −Y +X −X +Z −Z
			inventory_image = first and PILE_ICON or nil,
			wield_image = first and PILE_ICON or nil,      -- 手上拿的是一片鋼板（不是整格土）
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

-- H 型鋼（統一：支柱、橫撐都是它）：輕型 H200（物品就是原本的鋼支保 rockmech:steel_set）、重型 H300（物品是原本的內支撐 rockmech:strut）。
-- 放下去的方塊依方向分三種（x 東西、z 南北、y 直立），本身是一整條 H 斷面；旁邊有「別的方向」的 H 型鋼時，
-- 像柵欄一樣自動長出接過去的一段＋中間一塊接頭板（connected nodebox）：T 字、十字、支柱頂到橫撐都接得起來
local HB = {
	light = {item = "rockmech:steel_set", A = 6.353e-3, I = 1.6e-5, w = 0.10, tf = 0.05, tex = "[fill:16x16:#9aa0a6^[fill:16x2:0,7:#7c8288"},     -- H200×200×8×12：A、弱軸 I
	heavy = {item = STRUT, A = STRUT_A, I = STRUT_I, w = 0.15, tf = 0.07, tex = "[fill:16x16:#5a6068^[fill:16x2:0,7:#454a50"},                    -- H300×300×10×15
}
local HB_INFO = {}             -- 方塊名稱 → {kind, axis}
local HB_NODES = {}            -- 所有 H 型鋼方塊
local function hb_name(kind, axis) return "rockmech:hbeam_" .. kind .. "_" .. axis end
local AXIS_DIR = {x = {x = 1, y = 0, z = 0}, y = {x = 0, y = 1, z = 0}, z = {x = 0, y = 0, z = 1}}
-- 沿 axis 的 H 斷面（從 lo 到 hi），寬 w、深 w，翼板厚 0.06、腹板半厚 0.03；腹板在 y（水平梁）或 x（直立）方向
local function h_boxes(axis, w, lo, hi, tf)
	tf = tf or 0.06
	local tw = tf / 2
	local raw = {{-w, -w, w, -w + tf}, {-w, w - tf, w, w}, {-tw, -w + tf, tw, w - tf}}   -- 斷面上的三個矩形（u1, v1, u2, v2）
	local out = {}
	for _, r in ipairs(raw) do
		if axis == "z" then out[#out + 1] = {r[1], r[2], lo, r[3], r[4], hi}             -- u = x、v = y
		elseif axis == "x" then out[#out + 1] = {lo, r[2], r[1], hi, r[4], r[3]}          -- u = z、v = y
		else out[#out + 1] = {r[2], lo, r[1], r[4], hi, r[3]} end                        -- 直立：u = z、v = x（翼板朝 x）
	end
	return out
end
local function add(t, list) for _, b in ipairs(list) do t[#t + 1] = b end return t end
for kind, k in pairs(HB) do
	for axis in pairs(AXIS_DIR) do
		local w = k.w
		local gus = {-w - 0.02, -w - 0.02, -w - 0.02, w + 0.02, w + 0.02, w + 0.02}     -- 接頭板（相接處中間）
		local function arm(ax, lo, hi) return add({gus}, h_boxes(ax, w, lo, hi, k.tf)) end
		local nb = {type = "connected", fixed = h_boxes(axis, w, -0.5, 0.5, k.tf)}
		local others = {}
		if axis ~= "x" then nb.connect_left, nb.connect_right = arm("x", -0.5, 0), arm("x", 0, 0.5); others[#others + 1] = "group:rockmech_hbeam_x" end
		if axis ~= "z" then nb.connect_front, nb.connect_back = arm("z", -0.5, 0), arm("z", 0, 0.5); others[#others + 1] = "group:rockmech_hbeam_z" end
		if axis ~= "y" then nb.connect_bottom, nb.connect_top = arm("y", -0.5, 0), arm("y", 0, 0.5); others[#others + 1] = "group:rockmech_hbeam_y" end
		local name = hb_name(kind, axis)
		core.register_node(name, {
			description = kind == "light" and S("Light H-beam") or S("Heavy H-beam"),
			drawtype = "nodebox", paramtype = "light", sunlight_propagates = true, is_ground_content = false,
			tiles = {k.tex}, node_box = nb, connects_to = others,
			groups = {cracky = 2, rockmech_retain = 1, rockmech_hbeam = 1, ["rockmech_hbeam_" .. axis] = 1, not_in_creative_inventory = 1},
			sounds = base.sounds, drop = k.item,
		})
		HB_INFO[name] = {kind = kind, axis = axis}
		HB_NODES[#HB_NODES + 1] = name
	end
end
local function hb_cap(kind, L)      -- 承載力 min(降伏, 尤拉挫屈) ÷ 相似比（kN）
	local k = HB[kind]
	return math.min(FY * k.A, math.pi ^ 2 * E_STEEL * k.I / (L * L)) / n_scale()
end
-- 舊世界的內支撐方塊（rockmech:strut，facedir 0/2 = 南北、1/3 = 東西）換成新的重型 H 型鋼
core.register_lbm({
	label = "rockmech: 內支撐換成重型 H 型鋼", name = "rockmech:strut_to_hbeam", nodenames = {STRUT}, run_at_every_load = true,
	action = function(pos, node) core.swap_node(pos, {name = hb_name("heavy", (node.param2 % 2 == 1) and "x" or "z")}) end,
})

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

-- H 型鋼的軸向（方塊名稱決定）
local function hb_axis(name) local i = HB_INFO[name]; return i and AXIS_DIR[i.axis] end
-- 板樁格 p 有沒有橫撐接著（四周水平的 H 型鋼，軸向指著它）
local function strut_at(p)
	for _, v in ipairs({{x = 1, y = 0, z = 0}, {x = -1, y = 0, z = 0}, {x = 0, y = 0, z = 1}, {x = 0, y = 0, z = -1}}) do
		local a = hb_axis(core.get_node(vector.add(p, v)).name)
		if a and (a.x ~= 0 and v.x ~= 0 or a.z ~= 0 and v.z ~= 0) then return true end
	end
	return false
end
-- 板樁換樣子：有橫撐接著 → 有圍令；沒有 → 一般（降伏過的不變）
local function refresh_wale(p)
	local n = core.get_node(p)
	local info = PILE_INFO[n.name]
	if not info or info.state == "bent" then return end
	local want = pile_name(info.fill, strut_at(p) and "wale" or "plain")
	if want ~= n.name then core.swap_node(p, {name = want, param2 = n.param2}) end
end
-- 一支 H 型鋼（從 p 沿軸向兩邊連續、同一種同方向的格）：回傳 格清單、兩端外面那一格
local function strut_line(p)
	local name = core.get_node(p).name
	local a = hb_axis(name)
	local cells, ends = {p}, {}
	if not a then return cells, ends end
	for _, s in ipairs({1, -1}) do
		local q = vector.add(p, vector.multiply(a, s))
		while core.get_node(q).name == name do
			cells[#cells + 1] = q
			q = vector.add(q, vector.multiply(a, s))
		end
		ends[#ends + 1] = q
	end
	return cells, ends
end

-- 放 H 型鋼（輕型、重型同一套）：
--   對地板（方塊頂面）按右鍵 → 往上；對頂板（方塊底面）→ 往下；對牆面 → 水平往前。
--   一路經過空的格，碰到第一個實心的東西就停：中間整段放滿（支柱、橫撐），每 1 m 用一支；
--   MAX_SPAN 內都沒碰到（上面是天空、對面太遠）→ 只放 1 m
local function place_hbeam(kind, itemstack, placer, pointed)
	if pointed.type ~= "node" or not placer then return itemstack end
	local name = placer:get_player_name()
	local from, a0 = pointed.under, pointed.above
	local v = vector.subtract(a0, from)
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
	if #cells == 0 then return itemstack end
	if not stop then cells = {cells[1]} end
	local have = itemstack:get_count()
	if not core.is_creative_enabled(name) and have < #cells then
		rockmech.notify(name, S("[H-beam] This span needs @1 (1 per metre), you have @2", tostring(#cells), tostring(have))); return itemstack
	end
	for _, c in ipairs(cells) do
		if core.is_protected(c, name) then return itemstack end
	end
	local axis = v.x ~= 0 and "x" or v.y ~= 0 and "y" or "z"
	for _, c in ipairs(cells) do core.set_node(c, {name = hb_name(kind, axis)}) end
	refresh_wale(from)
	if stop then refresh_wale(stop) end
	rockmech.notify(name, S("[H-beam] @1 m placed", tostring(#cells)))
	if rockmech.fem_queue then rockmech.fem_queue(cells[math.ceil(#cells / 2)], 1, false, false) end
	if not core.is_creative_enabled(name) then itemstack:take_item(#cells) end
	return itemstack
end
core.override_item(STRUT, {
	description = S("Heavy H-beam\nRight-click the floor: a post up to the roof; a wall: a strut across to the opposite side (1 per metre)"),
	short_description = S("Heavy H-beam"),
	on_place = function(itemstack, placer, pointed) return place_hbeam("heavy", itemstack, placer, pointed) end,
})
if core.registered_items[HB.light.item] then
	core.override_item(HB.light.item, {
		description = S("Light H-beam\nRight-click the floor: a post up to the roof; a wall: a strut across to the opposite side (1 per metre)"),
		short_description = S("Light H-beam"),
		on_place = function(itemstack, placer, pointed) return place_hbeam("light", itemstack, placer, pointed) end,
	})
end
-- 拆：整支／整欄，退還給挖的人
local function give(digger, item, n)
	if not (digger and digger.is_player and digger:is_player()) or n <= 0 then return end
	local left = digger:get_inventory():add_item("main", ItemStack(item .. " " .. n))
	if not left:is_empty() then core.add_item(digger:get_pos(), left) end
end
-- 拆一支 H 型鋼（整條）：回傳 格數、物品名稱（輕型、重型）
local function remove_strut(p, digger, refund)
	local info = HB_INFO[core.get_node(p).name]
	local item = info and HB[info.kind].item or STRUT
	local cells, ends = strut_line(p)
	for _, c in ipairs(cells) do core.remove_node(c) end
	for _, e in ipairs(ends) do refresh_wale(e) end
	if refund then give(digger, item, #cells) end
	return #cells, item
end
-- H 型鋼壞掉（挫屈、跟著板樁倒、懸空掉下來）：變成建築廢棄物，量 = 鋼的體積（斷面積 × 長度，至少 1 級），
-- 放在那一組最低的那一格，照碎石的規則往下掉。不退還物品
local function beams_to_waste(cells)
	if #cells == 0 then return end
	local vol, low = 0, cells[1]
	for _, c in ipairs(cells) do
		local info = HB_INFO[core.get_node(c).name]
		vol = vol + (info and HB[info.kind].A or STRUT_A)
		if c.y < low.y then low = c end
	end
	for _, c in ipairs(cells) do core.remove_node(c) end
	local NL = rockmech.RUBBLE_LEVELS
	local lv = math.max(1, math.min(NL, math.floor(vol * NL + 0.5)))
	rockmech.assay.place(low, rockmech.RUBBLE_DEBRIS, lv, rockmech.assay.new(0))
	if rockmech.collapse and rockmech.collapse.update_affected_area then
		core.after(0.1, rockmech.collapse.update_affected_area, vector.copy(low))
	end
end
-- 懸空檢測：彼此相連（六個面相鄰）的一組 H 型鋼，只要有一格碰到實心的東西（地面、岩壁、土、碎石、板樁）就撐得住；
-- 整組都沒碰到 → 整組掉下來變建築廢棄物。p 附近 ±r 找起點，沿著相連的 H 型鋼走（一組最多 MAX_GROUP 格，太大的不處理）
local MAX_GROUP = 800
local function supports_beam(n)
	if n == "air" or HB_INFO[n] then return false end
	local def = core.registered_nodes[n]
	return def and def.walkable ~= false
end
local SIX = {{x = 1, y = 0, z = 0}, {x = -1, y = 0, z = 0}, {x = 0, y = 1, z = 0}, {x = 0, y = -1, z = 0}, {x = 0, y = 0, z = 1}, {x = 0, y = 0, z = -1}}
local function check_hbeams_near(p, r)
	local seen = {}
	for _, q in ipairs(core.find_nodes_in_area(vector.subtract(p, r), vector.add(p, r), HB_NODES)) do
		local h = core.hash_node_position(q)
		if not seen[h] then
			seen[h] = true
			local comp, stack, supported = {}, {q}, false
			while #stack > 0 and #comp < MAX_GROUP do
				local c = table.remove(stack)
				comp[#comp + 1] = c
				for _, d in ipairs(SIX) do
					local nb = vector.add(c, d)
					local nn = core.get_node(nb).name
					if HB_INFO[nn] then
						local hn = core.hash_node_position(nb)
						if not seen[hn] then seen[hn] = true; stack[#stack + 1] = nb end
					elseif supports_beam(nn) then
						supported = true
					end
				end
			end
			if not supported and #stack == 0 then
				beams_to_waste(comp)
				tell_near(q, S("[H-beam] An unsupported H-beam fell down"))
				core.log("action", ("[rockmech] H 型鋼懸空掉落 %s（%d 格）"):format(core.pos_to_string(q), #comp))
			end
		end
	end
end
rockmech.retain_check_beams = check_hbeams_near
-- 載入區塊時也檢查（舊存檔裡已經懸空的 H 型鋼、崩落時沒在範圍內的）
core.register_lbm({
	label = "rockmech: 懸空的 H 型鋼掉下來", name = "rockmech:hbeam_hanging", nodenames = {"group:rockmech_hbeam"}, run_at_every_load = true,
	action = function(pos) core.after(1, check_hbeams_near, vector.copy(pos), 0) end,
})

for _, name in ipairs(HB_NODES) do
	core.override_item(name, {on_dig = function(pos, node, digger)
		if digger and core.is_protected(pos, digger:get_player_name()) then return false end
		remove_strut(pos, digger, true)
		return true
	end})
end
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

-- 板樁的支撐：埋入段 = 前後兩側（板的法向）都夾著東西（土、碎石、岩石…，空氣不算）的格數。
-- 埋入 ≥ 2 m，或埋入 ≥ 1 m 且底下有東西頂著，才站得住；否則（開挖挖過板樁底、土從底下被掏空）整欄倒進坑裡：
-- 鋼板變成建築廢棄物，跟夾著的材料（土 → 鬆土；碎石照原樣，含礦也是）照體積比例混成一格碎石掉下去；接在上面的支撐一起掉
-- 隔壁是另一片板樁也算夾著（轉角：一面牆的端板正對著另一面牆的板樁，兩片咬在一起）
local function holds(n)
	if IS_PILE[n] then return true end
	if n == "air" or HB_INFO[n] then return false end
	local def = core.registered_nodes[n]
	return def and def.walkable ~= false
end
local function pile_supported(cells)
	local emb = 0
	for _, c in ipairs(cells) do
		local dv = core.facedir_to_dir(core.get_node(c).param2 % 4)
		if holds(core.get_node(vector.add(c, dv)).name) and holds(core.get_node(vector.subtract(c, dv)).name) then emb = emb + 1 end
	end
	local bottom = cells[#cells]
	local below = bottom and holds(core.get_node({x = bottom.x, y = bottom.y - 1, z = bottom.z}).name)
	return emb >= 2 or (emb >= 1 and below), emb
end
local function topple(cells)
	local bent = false
	for _, c in ipairs(cells) do
		local info = PILE_INFO[core.get_node(c).name]
		if info and info.state == "bent" then bent = true end
		for _, v in ipairs({{x = 1, y = 0, z = 0}, {x = -1, y = 0, z = 0}, {x = 0, y = 0, z = 1}, {x = 0, y = 0, z = -1}}) do
			local q = vector.add(c, v)
			if HB_INFO[core.get_node(q).name] then      -- 接在上面的 H 型鋼跟著壞掉：變建築廢棄物
				local sc, ends = strut_line(q)
				beams_to_waste(sc)
				for _, e in ipairs(ends) do refresh_wale(e) end
			end
		end
	end
	-- 每一格：夾著的材料（土 → 鬆土；碎石照原樣，品位、成分都在；軟岩 → 它的碎石）混進鋼板那一份的建築廢棄物，
	-- 照體積比例（SP-III 每公尺寬斷面積 → 每格約 2% 是鋼）。碎石的合併規則照 assay.lua（含量照質量加權）
	local A = rockmech.assay
	local NLEV = rockmech.RUBBLE_LEVELS
	for _, c in ipairs(cells) do
		local keep = core.deserialize(core.get_meta(c):get_string("fill"))
		local name = keep and keep.name
		local base, k, comp
		if name and core.get_item_group(name, "rockmech_topsoil") > 0 then
			base, k, comp = rockmech.RUBBLE_SOIL, NLEV, A.new(0)              -- 擾動過的土 → 鬆土
		elseif name and core.registered_nodes[name] and (rockmech.is_rubble(name) or rockmech.lith_of_node[name]) then
			core.set_node(c, {name = name, param2 = keep.param2 or 0})
			core.get_meta(c):from_table(keep.meta)
			local node = core.get_node(c)
			base, k, comp = rockmech.rubble_for(name), rockmech.rubble_level[name] or NLEV, A.get(c, node)
		end
		if base then
			local kd = NLEV * STEEL_FRAC
			local b2, c2 = A.merge(base, k - kd, comp, rockmech.RUBBLE_DEBRIS, kd, A.new(0))
			A.place(c, b2, k, c2)
		else
			A.place(c, rockmech.RUBBLE_DEBRIS, 1, A.new(0))                -- 沒記到材料（舊版打的）：只剩鋼板的廢料
		end
	end
	local top = cells[1]
	for _, c in ipairs(cells) do
		if rockmech.collapse and rockmech.collapse.update_affected_area then
			core.after(0.1, rockmech.collapse.update_affected_area, vector.copy(c))
		end
	end
	core.sound_play("default_dug_metal", {pos = top, gain = 1.0, max_hear_distance = 32}, true)
	tell_near(top, S("[Sheet pile] The sheet pile at @1 lost its embedment and fell into the pit", core.pos_to_string(top)))
	core.log("action", ("[rockmech] 鋼板樁倒塌（埋入段被掏空）%s（%d m）"):format(core.pos_to_string(top), #cells))
	core.after(0.3, check_hbeams_near, vector.copy(top), #cells + 2)
end
-- p 附近（±r）的板樁欄：站不住的倒掉
local function check_piles_near(p, r)
	local seen = {}
	for _, q in ipairs(core.find_nodes_in_area(vector.subtract(p, r), vector.add(p, r), {"group:rockmech_retain"})) do
		if IS_PILE[core.get_node(q).name] and not seen[q.x .. "," .. q.z] then
			seen[q.x .. "," .. q.z] = true
			local cells = pile_column(q)
			if #cells > 0 and not pile_supported(cells) then topple(cells) end
		end
	end
end
rockmech.retain_check_piles = check_piles_near
core.register_on_dignode(function(pos, oldnode)
	if not IS_PILE[oldnode.name] and not HB_INFO[oldnode.name] then core.after(0.3, check_piles_near, vector.copy(pos), 2) end
	core.after(0.4, check_hbeams_near, vector.copy(pos), 2)      -- 挖掉撐著 H 型鋼的東西：懸空的掉下來
end)
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
				if HB_INFO[core.get_node(q).name] then remove_strut(q, digger, true) end
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
	local mid = vector.copy(cells[math.ceil(#cells / 2)])
	beams_to_waste(cells)           -- 挫屈：整支變建築廢棄物
	for _, e in ipairs(ends) do refresh_wale(e) end
	core.after(0.2, check_hbeams_near, mid, 3)      -- 靠它撐著的其他 H 型鋼
	core.add_particlespawner({amount = 30, time = 0.3,
		minpos = vector.subtract(mid, 0.4), maxpos = vector.add(mid, 0.4),
		minvel = {x = -2, y = -1, z = -2}, maxvel = {x = 2, y = 2, z = 2}, minacc = {x = 0, y = -9.8, z = 0}, maxacc = {x = 0, y = -9.8, z = 0},
		minexptime = 0.5, maxexptime = 1.2, minsize = 1, maxsize = 2, texture = "[fill:4x4:#7a8086"})
	core.sound_play("default_dug_metal", {pos = mid, gain = 1.0, max_hear_distance = 32}, true)
	tell_near(mid, S("[Strut] The strut at @1 buckled", core.pos_to_string(mid)))
	core.log("action", ("[rockmech] 支撐挫屈 %s（%d m）"):format(core.pos_to_string(mid), #cells))
end

---------------------------------------------------------------------------
-- 彈性支承梁法（wallbeam.lua）：每一欄板樁是一根薄梁，兩側的土是彈簧（夾在主動、被動土壓之間），
-- 接著的 H 型鋼是只受壓的彈簧（圍令把一支的勁度分攤到兩支之間的寬度）。
-- 應力解裡板樁是 1 m 厚、跟土黏在一起的元素，彎矩算不準（土的拖曳、樁腳被咬住…），所以彎矩、支撐力改由這裡算；
-- 土會不會破壞（牆後、坑底）仍由應力解判定。土的參數跟應力解同一組（materials.lua：c、φ、γ、E）
---------------------------------------------------------------------------
local WB = dofile(rockmech.modpath .. "/wallbeam.lua")
rockmech.wallbeam = WB
local EI_PILE = E_STEEL * PILE_I
local function cells_min(cells)
	local m = cells[1]
	for _, c in ipairs(cells) do
		if c.x < m.x or (c.x == m.x and (c.y < m.y or (c.y == m.y and c.z < m.z))) then m = c end
	end
	return m
end
-- 板旁邊那一格的土：回傳 σv（kPa）、c、φ、kh；岩石回傳 rigid = true；不是土回傳 nil。
-- σv：應力解有解到這裡（天然的土）就用應力解的 σv（地面上的荷重、堆的碎石、空洞上方的拱效應、轉角的幾何都在裡面）；
-- 取離板再遠一格的土（貼著板的那一格被應力解裡的厚板樁拖著，σv 偏小）。沒有就用那一欄土的重量 γ·h
local function soil_at(p, out, sv_of)
	local n = core.get_node(p).name
	if not holds(n) or IS_PILE[n] then return nil end
	if rockmech.lith_of_node[n] and not rockmech.is_rubble(n) then return {rigid = true} end
	local sp = rockmech.materials.defaults("rockmech:topsoil")
	local sv = sv_of and (sv_of(vector.add(p, out)) or sv_of(p))
	if not sv then
		local h, q = 0, {x = p.x, y = p.y + 1, z = p.z}
		for _ = 1, 40 do
			local m = core.get_node(q).name
			if not holds(m) or IS_PILE[m] then break end
			h = h + 1
			q.y = q.y + 1
		end
		sv = sp.gamma * (h + 0.5)
	end
	local wet = 1 - (cfg.slope.rain_c_loss or 0) * (rockmech.rain_level and rockmech.rain_level() or 0)
	local natural = core.get_item_group(n, "rockmech_topsoil") > 0
	return {sv = sv, c = natural and sp.c * math.max(0, wet) or 0,
		phi = natural and sp.phi or cfg.slope.phi_r, kh = (sp.e_rel or cfg.fem.soil_e) * E_ROCK_REF}
end
-- lo..hi 裡的每一欄板樁解一次。sv_of(位置) → 應力解的 σv（kPa）或 nil
local function wall_solve(lo, hi, sv_of)
	local cols, seen = {}, {}
	for _, p in ipairs(core.find_nodes_in_area(lo, hi, {"group:rockmech_retain"})) do
		local key = p.x .. "," .. p.z
		if IS_PILE[core.get_node(p).name] and not seen[key] then
			seen[key] = true
			local cells = pile_column(p)
			local dv = core.facedir_to_dir(core.get_node(cells[1]).param2 % 4)
			local xaxis = dv.x ~= 0
			local bent = false
			for _, c in ipairs(cells) do
				local info = PILE_INFO[core.get_node(c).name]
				if info and info.state == "bent" then bent = true end
			end
			cols[#cols + 1] = {cells = cells, ax = xaxis and {x = 1, y = 0, z = 0} or {x = 0, y = 0, z = 1}, xaxis = xaxis,
				t = xaxis and p.z or p.x, plane = xaxis and p.x or p.z, bent = bent}
		end
	end
	-- 支撐：同一面牆（同軸向、同一個平面）、同一個高度、同一側 → 沿牆的位置清單
	local lines = {}
	local function line_key(col, y, s) return (col.xaxis and "x" or "z") .. col.plane .. ":" .. y .. ":" .. s end
	for _, col in ipairs(cols) do
		for _, q in ipairs(col.cells) do
			for _, s in ipairs({1, -1}) do
				local nb = vector.add(q, vector.multiply(col.ax, s))
				local name = core.get_node(nb).name
				local a = hb_axis(name)
				if a and (col.xaxis and a.x ~= 0 or not col.xaxis and a.z ~= 0) then
					local sc, ends = strut_line(nb)
					local far_pile = false
					for _, e in ipairs(ends) do
						if not vector.equals(e, q) and IS_PILE[core.get_node(e).name] then far_pile = true end
					end
					local kind = HB_INFO[name].kind
					local ks = (far_pile and 2 or 1) * E_STEEL * HB[kind].A / #sc        -- kN/m（兩邊都是板樁：各頂一半長度）
					local lk = line_key(col, q.y, s)
					lines[lk] = lines[lk] or {}
					table.insert(lines[lk], {t = col.t, k = ks, id = core.hash_node_position(cells_min(sc))})
				end
			end
		end
	end
	for _, l in pairs(lines) do table.sort(l, function(u, v) return u.t < v.t end) end
	-- 圍令分攤：這一欄在 t 的位置分到的支撐勁度（kN/m，每公尺寬）；自己就是那一支的話一併回傳
	local function prop_k(l, t)
		local m = #l
		local function gap(j)
			local g = math.huge
			if j > 1 then g = math.min(g, l[j].t - l[j - 1].t) end
			if j < m then g = math.min(g, l[j + 1].t - l[j].t) end
			return g == math.huge and 3 or g
		end
		for j = 1, m do
			if l[j].t == t then return l[j].k / gap(j), l[j] end
		end
		if t < l[1].t then
			local g = gap(1)
			return (l[1].t - t <= math.floor(g / 2)) and l[1].k / g or nil
		end
		if t > l[m].t then
			local g = gap(m)
			return (t - l[m].t <= math.floor(g / 2)) and l[m].k / g or nil
		end
		for j = 1, m - 1 do
			if l[j].t < t and t < l[j + 1].t then
				local g = l[j + 1].t - l[j].t
				if g <= 12 then return (l[j].k + l[j + 1].k) / 2 / g end
				return nil
			end
		end
	end
	-- 每一欄每一格兩側的土彈簧（p0, pa, pp, k）
	local raw = {}
	for _, col in ipairs(cols) do
		for _, q in ipairs(col.cells) do
			for _, s in ipairs({1, -1}) do
				local nb = vector.add(q, vector.multiply(col.ax, s))
				local so = soil_at(nb, vector.multiply(col.ax, s), sv_of)
				local sp
				if so and so.rigid then sp = {0, 0, 0, 0, 1e6, 1e6}
				elseif so then sp = WB.soil_spring(0, s, so.sv, so.c, so.phi, so.kh) end
				if sp then raw[line_key(col, q.y, s) .. ":" .. col.t] = sp end
			end
		end
	end
	local out = {}
	for _, col in ipairs(cols) do
		local n = #col.cells
		local t = {n = n, EI = EI_PILE * (col.bent and BENT_R or 1), soil = {}, props = {}}
		local own = {}          -- props 的序號 → 這一欄自己的那一支支撐
		for i, q in ipairs(col.cells) do
			for _, s in ipairs({1, -1}) do
				-- 鋼板互相咬合、連成一片：土彈簧取沿牆 ±1 m（同一面牆、同高度、同一側）的平均，
				-- 不會因為一格背後的土剛好被判破壞，就只有那 1 m 寬倒下去
				local lk = line_key(col, q.y, s)
				local own_sp = raw[lk .. ":" .. col.t]
				if own_sp then
					local sum, cnt = {0, 0, 0, 0}, 0
					for dt = -1, 1 do
						local o = raw[lk .. ":" .. (col.t + dt)]
						if o then
							for f = 1, 4 do sum[f] = sum[f] + o[f + 2] end
							cnt = cnt + 1
						end
					end
					t.soil[#t.soil + 1] = {i, s, sum[1] / cnt, sum[2] / cnt, sum[3] / cnt, sum[4] / cnt}
				end
				local l = lines[line_key(col, q.y, s)]
				if l then
					local k, mine = prop_k(l, col.t)
					if k then
						t.props[#t.props + 1] = {i, s, k}
						if mine then own[#t.props] = mine end
					end
				end
			end
		end
		out[#out + 1] = {col = col, t = t, r = WB.solve(t), own = own}
	end
	return out
end
-- 回傳 {[支撐最小格的 hash] = 軸力 kN}（接在板樁上的支撐）
local function wall_check(lo, hi, sv_of)
	local strut_N = {}
	local My = pile_my()
	for _, e in ipairs(wall_solve(lo, hi, sv_of)) do
		local col, t, r, own = e.col, e.t, e.r, e.own
		if not r.ok then
			topple(col.cells)                -- 撐不住：埋入不夠、整片倒進坑裡
		else
			for k, mine in pairs(own) do
				local N = (r.prop[k] or 0) / t.props[k][3] * mine.k            -- 這一支的軸力 = 它自己的勁度 × 位移
				strut_N[mine.id] = math.max(strut_N[mine.id] or 0, N)
			end
			if not col.bent then
				local Mmax = r.Mmax
				if Mmax > My then
					bend_column(col.cells)
				else
					local txt = S("Bending moment @1 kN·m/m / yield @2 kN·m/m (@3%)", d(Mmax), d(My), d(Mmax / My * 100))
					for _, q in ipairs(col.cells) do pile_info(q, txt) end
				end
			end
		end
	end
	return strut_N
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
	-- 埋入段被掏空的板樁先倒掉（崩落連鎖把土從板樁底下帶走，不會觸發挖掘的檢查）
	local half = math.floor((n - 2) / 2)
	check_piles_near(vector.add(lo, half), half)
	check_hbeams_near(vector.add(lo, half), half)    -- 崩落把撐著 H 型鋼的土帶走：懸空的掉下來
	-- 板樁的彎矩、接在板樁上的支撐軸力：彈性支承梁法（wall_check）。其他支撐（柱、撐在岩壁之間的）照應力解
	-- 應力解的 σv：只取天然的土格（碎石格在應力解裡沒有重量、沒有現地應力，照那一欄的重量算）
	local strut_N = wall_check(lo, hi, function(p)
		local c = cell(p)
		if c and job.soil and job.soil[c] then return math.max(0, res.syy[c]) end
	end)
	-- 支撐：每一支取最大的軸力
	local done = {}
	for _, p in ipairs(core.find_nodes_in_area(lo, hi, HB_NODES)) do
		local key = core.hash_node_position(p)
		if not done[key] then
			local cells = strut_line(p)
			for _, q in ipairs(cells) do done[core.hash_node_position(q)] = true end
			local N = 0
			local beamN = strut_N[core.hash_node_position(cells_min(cells))]
			if beamN then N = beamN
			else
				for _, q in ipairs(cells) do
					local c = cell(q)
					if c then
						local dv = hb_axis(core.get_node(q).name)
						N = math.max(N, (dv.x ~= 0 and res.sxx or dv.y ~= 0 and res.syy or res.szz)[c])      -- kPa × 1 m² = kN（壓為正）
					end
				end
			end
			local info = HB_INFO[core.get_node(p).name]
			local P = hb_cap(info and info.kind or "heavy", #cells)
			if N > P then
				buckle_strut(p)
			else
				local txt = (info and info.kind == "light" and S("Light H-beam") or S("Heavy H-beam")) .. "\n" .. S("Axial force @1 kN / capacity @2 kN (@3%)", d(N), d(P), d(N / P * 100))
				for _, q in ipairs(cells) do core.get_meta(q):set_string("infotext", txt) end
			end
		end
	end
end

-- 應力解的勁度比（femstress.lua 的 make_job：support_ids.retain_r，方塊 id → 勁度比）
core.register_on_mods_loaded(function()
	rockmech.support_ids = rockmech.support_ids or {}
	local r = {[core.get_content_id(STRUT)] = STRUT_R}
	for name, info in pairs(HB_INFO) do r[core.get_content_id(name)] = E_STEEL * HB[info.kind].A / E_ROCK_REF end
	local piles = {}
	for name, info in pairs(PILE_INFO) do
		local cid = core.get_content_id(name)
		r[cid] = info.state == "bent" and PILE_R * BENT_R or PILE_R
		piles[cid] = true
	end
	rockmech.support_ids.retain_r = r
	rockmech.support_ids.pile = piles
end)
rockmech.retain = {PILE_R = PILE_R, STRUT_R = STRUT_R, pile_my = pile_my, strut_cap = strut_cap, PILE_LEN = PILE_LEN}
