-- rockmech/steelarch.lua
-- 鋼拱支保（H150）：玩家一格一格放，貼著岩面的半格鋼條。怎麼蓋就怎麼受力，不預設形狀：
--   蓋成一整圈 → 應力解裡是一圈相連的元素，自然受壓（拱作用）；只蓋平頂梁 → 中段受彎。
--
-- 放置：拿著鋼拱對岩面（頂板、牆、地板）按右鍵，放在那一面前方的空氣格。
--   隧道方向（鋼條所在的斷面跟它垂直）：旁邊已經有鋼拱就照它；對牆面放 → 牆面的法向在斷面裡；
--   對頂板、地板放 → 沿 x、z 哪個方向空得比較遠，那就是隧道方向。
--   外觀：貼著每一個相鄰的岩面（岩石、土、碎石）畫一片半格厚的鋼條（connected nodebox），
--   頂板和牆的轉角自動接成 L 形；沿隧道方向寬 0.3 m（一支 H150 加墊塊）。
-- 力學（應力解 femstress.lua，跟板樁、H 型鋼同一套）：
--   一格是 1 m 的元素，勁度比照「軸向勁度 EA 相同」（H150 每公尺一支，約岩石的 1/10），
--   沒有現地應力、不加重力，岩面收斂或碎石壓上來才受力；彎曲用板樁的減積分元素（不會剪力鎖定）。
--   軸力 N = 沿鋼條方向的應力 × 1 m²；彎矩 M = 鋼條厚度方向兩面（貼岩面、朝隧道）的應力差 / 12（同板樁）。
--   使用率 U = |N|/N_y + |M|/M_y（÷ 相似比）。U ≥ 1 → 降伏（變形、生鏽外觀、勁度剩 1/10）；
--   降伏過的再 U ≥ 1 → 那一格壓垮，變成建築廢棄物；靠它撐著的鋼拱沒有依靠就跟著掉。
-- 岩石力學網格裡鋼拱格算空格（group rockmech_steelarch，同木材，collapse.lua）：後面的岩面照樣判定，
--   鋼拱的反力（這一格垂直岩面的壓應力）就是那一面的圍壓（femstress.lua face_fs 的鬆散材料反力）。
-- 碎石、岩塊：鋼拱是可以站的方塊，碎石流不過去、岩塊滑不過去，停在鋼拱上（碎石的重量由應力解傳給鋼拱）。
-- 懸空：彼此相連的一組鋼拱，至少要有一格貼著岩石、土或其他實心的東西（碎石不算）；整組都沒有 → 掉下來。

local S = rockmech.S
local cfg = rockmech.cfg

local ITEM = "rockmech:steel_arch"
local E_STEEL, FY = 2.0e8, 295e3              -- kPa（同 retain.lua）
local E_ROCK_REF = 7.5e6
local A, Z = 4.014e-3, 2.19e-4                -- H150×150×7×10：斷面積 (m²)、強軸斷面模數 (m³)
local ARCH_R = E_STEEL * A / E_ROCK_REF       -- ≈ 0.107
local BENT_R = 0.1
local W = 0.15                                -- 沿隧道方向的半寬
local function n_scale() return cfg.model_scale or 1 end
local function Ny() return FY * A / n_scale() end
local function My() return FY * Z / n_scale() end
local function d(v) return ("%d"):format(math.floor(v + 0.5)) end

local TEX = "[fill:16x16:#6c737a^[fill:16x2:0,2:#4f555b^[fill:16x2:0,12:#4f555b"
local TEX_BENT = "[fill:16x16:#6e5440^[fill:16x2:0,2:#4e3a2c^[fill:16x2:0,12:#4e3a2c"
local ICON = "[fill:16x16:#00000000^[fill:14x4:1,2:#6c737a^[fill:4x12:1,2:#6c737a^[fill:4x12:11,2:#6c737a"

-- 噴凝土包住的鋼拱（groundsupport.lua 的噴凝土）：同一格，貼岩面的噴凝土層（每層 0.06 m）＋被包在裡面的鋼條。
-- 一個 nodebox 只能有一組貼圖，所以整格都是噴凝土的顏色：鋼條的地方看起來是凸出來的一條（現實裡噴凝土包住鋼拱也是這樣）
local SC_TEX = "[fill:16x16:#a4a29c^[fill:2x2:3,4:#8e8c86^[fill:2x2:10,2:#b4b2ac^[fill:2x2:6,11:#8e8c86^[fill:2x2:12,9:#b4b2ac"
local SC_TEX_BENT = SC_TEX .. "^[fill:1x12:5,2:#5a5650^[fill:8x1:4,9:#5a5650^[fill:1x5:11,4:#5a5650"     -- 裂縫
local MAX_LAYERS = rockmech.SHOTCRETE_LAYERS or 3

-- 方塊：axis = 隧道方向（x 或 z），鋼條在跟它垂直的斷面裡；bent = 降伏過；layers = 噴凝土層數（0 = 沒噴）
local INFO = {}               -- 方塊名稱 → {axis, bent, layers}
local NODES = {}
local function arch_name(axis, bent, layers)
	return "rockmech:steel_arch_" .. axis .. (bent and "_bent" or "") .. ((layers or 0) > 0 and ("_sc" .. layers) or "")
end
-- 貼著這些東西就畫一片鋼條（岩石、土、碎石）
local CONNECT = {"group:rockmech_rock", "group:stone", "group:crumbly", "group:rockmech_rubble"}
local sounds = default and default.node_sound_metal_defaults and default.node_sound_metal_defaults() or nil
local function add(t, b) t[#t + 1] = b; return t end
rockmech.spray_next = rockmech.spray_next or {}
for _, axis in ipairs({"x", "z"}) do
	for _, bent in ipairs({false, true}) do
		for layers = 0, MAX_LAYERS do
			local T = 0.06 * layers
			local nb = {type = "connected"}
			if axis == "z" then        -- 斷面 = x-y，沿 z 寬 2W
				nb.disconnected = {{-0.5, -0.25, -W, 0.5, 0.25, W}}
				nb.connect_top = {{-0.5, 0, -W, 0.5, 0.5, W}}
				nb.connect_bottom = {{-0.5, -0.5, -W, 0.5, 0, W}}
				nb.connect_left = {{-0.5, -0.5, -W, 0, 0.5, W}}
				nb.connect_right = {{0, -0.5, -W, 0.5, 0.5, W}}
			else                       -- 斷面 = z-y，沿 x 寬 2W
				nb.disconnected = {{-W, -0.25, -0.5, W, 0.25, 0.5}}
				nb.connect_top = {{-W, 0, -0.5, W, 0.5, 0.5}}
				nb.connect_bottom = {{-W, -0.5, -0.5, W, 0, 0.5}}
				nb.connect_front = {{-W, -0.5, -0.5, W, 0.5, 0}}
				nb.connect_back = {{-W, -0.5, 0, W, 0.5, 0.5}}
			end
			if layers > 0 then         -- 噴凝土層：貼著每一個岩面（六個方向都有，沿隧道的端面也算）
				nb.connect_top = add(nb.connect_top or {}, {-0.5, 0.5 - T, -0.5, 0.5, 0.5, 0.5})
				nb.connect_bottom = add(nb.connect_bottom or {}, {-0.5, -0.5, -0.5, 0.5, -0.5 + T, 0.5})
				nb.connect_front = add(nb.connect_front or {}, {-0.5, -0.5, -0.5, 0.5, 0.5, -0.5 + T})
				nb.connect_back = add(nb.connect_back or {}, {-0.5, -0.5, 0.5 - T, 0.5, 0.5, 0.5})
				nb.connect_left = add(nb.connect_left or {}, {-0.5, -0.5, -0.5, -0.5 + T, 0.5, 0.5})
				nb.connect_right = add(nb.connect_right or {}, {0.5 - T, -0.5, -0.5, 0.5, 0.5, 0.5})
			end
			local name = arch_name(axis, bent, layers)
			local desc = bent and S("Steel arch (yielded)") or S("Steel arch")
			if layers > 0 then desc = desc .. " + " .. S("Shotcrete lining (@1 layers)", tostring(layers)) end
			core.register_node(name, {
				description = desc,
				drawtype = "nodebox", paramtype = "light", sunlight_propagates = true, is_ground_content = false,
				tiles = {layers > 0 and (bent and SC_TEX_BENT or SC_TEX) or (bent and TEX_BENT or TEX)},
				node_box = nb, connects_to = CONNECT,
				-- group shotcrete = 層數：支護判定（support.scan）照噴凝土給後面的岩面 層數 × p_sc
				groups = {cracky = 2, rockmech_steelarch = 1, not_in_creative_inventory = 1, shotcrete = layers > 0 and layers or nil},
				sounds = sounds, drop = bent and "" or ITEM,
			})
			INFO[name] = {axis = axis, bent = bent, layers = layers}
			NODES[#NODES + 1] = name
			-- 對鋼拱噴凝土：加一層（groundsupport.lua 的噴凝土照 spray_next 換方塊）
			if layers > 0 then rockmech.spray_next[arch_name(axis, bent, layers - 1)] = name end
		end
	end
end

local function tell_near(p, msg)
	for _, pl in ipairs(core.get_connected_players()) do
		if vector.distance(pl:get_pos(), p) <= 32 then rockmech.notify(pl:get_player_name(), msg) end
	end
end

-- 斷面裡的兩個方向：u（水平、垂直隧道）、y
local function u_dir(axis) return axis == "z" and {x = 1, y = 0, z = 0} or {x = 0, y = 0, z = 1} end
local UP = {x = 0, y = 1, z = 0}
-- 貼著的東西（鋼條靠的那一面）：岩石、土、碎石…（可以站、不是鋼拱）
local function backs(name)
	if INFO[name] or name == "air" then return false end
	local def = core.registered_nodes[name]
	return def ~= nil and def.walkable ~= false
end

---------------------------------------------------------------------------
-- 放置
---------------------------------------------------------------------------

local function free_run(p, v)
	local n = 0
	for k = 1, 10 do
		local nm = core.get_node(vector.add(p, vector.multiply(v, k))).name
		local def = core.registered_nodes[nm]
		if nm ~= "air" and not (def and def.buildable_to) then break end
		n = n + 1
	end
	return n
end
local function pick_axis(p, normal, placer)
	-- 旁邊已經有鋼拱：同一圈或下一圈，隧道方向都一樣
	for _, v in ipairs({{x = 1, y = 0, z = 0}, {x = -1, y = 0, z = 0}, {x = 0, y = 1, z = 0}, {x = 0, y = -1, z = 0},
			{x = 0, y = 0, z = 1}, {x = 0, y = 0, z = -1}}) do
		local i = INFO[core.get_node(vector.add(p, v)).name]
		if i then return i.axis end
	end
	if normal.x ~= 0 then return "z" end           -- 對牆面放：牆的法向在斷面裡
	if normal.z ~= 0 then return "x" end
	local rx = free_run(p, {x = 1, y = 0, z = 0}) + free_run(p, {x = -1, y = 0, z = 0})
	local rz = free_run(p, {x = 0, y = 0, z = 1}) + free_run(p, {x = 0, y = 0, z = -1})
	if rx ~= rz then return rx > rz and "x" or "z" end
	local look = placer:get_look_dir()
	return math.abs(look.x) > math.abs(look.z) and "x" or "z"
end

-- 在 p 放一格鋼拱（axis = 隧道方向 "x"／"z"）；噴凝土層留著。手放、鋼支保安裝台車（vehicle_support.lua）共用
function rockmech.steelarch_place(p, axis)
	local layers = core.get_item_group(core.get_node(p).name, "shotcrete_lining")
	core.set_node(p, {name = arch_name(axis, false, math.min(layers, MAX_LAYERS))})
	core.get_meta(p):set_string("infotext", S("Steel arch"))
end

core.register_craftitem(ITEM, {
	description = S("Steel arch (H150)\nRight-click a rock face: places 1 m of steel arch against it. Build a full ring and it works in compression"),
	short_description = S("Steel arch"),
	inventory_image = ICON, wield_image = ICON,
	on_place = function(itemstack, placer, pointed)
		if pointed.type ~= "node" or not placer then return itemstack end
		local name = placer:get_player_name()
		local p = pointed.above
		local nm = core.get_node(p).name
		local def = core.registered_nodes[nm]
		if nm ~= "air" and not (def and def.buildable_to) then return itemstack end
		if core.is_protected(p, name) then return itemstack end
		local axis = pick_axis(p, vector.subtract(pointed.above, pointed.under), placer)
		-- 放在噴凝土層上：噴凝土留著（鋼拱貼著噴凝土，之後再噴就包起來）
		rockmech.steelarch_place(p, axis)
		if rockmech.fem_queue then rockmech.fem_queue(p, 1, false, false) end
		if not core.is_creative_enabled(name) then itemstack:take_item() end
		return itemstack
	end,
})

---------------------------------------------------------------------------
-- 壞掉、懸空
---------------------------------------------------------------------------

-- 壓垮：變成建築廢棄物（鋼的體積，至少 1 級），照碎石的規則往下掉
local function to_waste(cells)
	if #cells == 0 then return end
	local NL = rockmech.RUBBLE_LEVELS
	for _, c in ipairs(cells) do
		core.remove_node(c)
		rockmech.assay.place(c, rockmech.RUBBLE_DEBRIS, math.max(1, math.floor(A * NL + 0.5)), rockmech.assay.new(0))
		if rockmech.collapse and rockmech.collapse.update_affected_area then
			core.after(0.1, rockmech.collapse.update_affected_area, vector.copy(c))
		end
	end
end

local SIX = {{x = 1, y = 0, z = 0}, {x = -1, y = 0, z = 0}, {x = 0, y = 1, z = 0}, {x = 0, y = -1, z = 0}, {x = 0, y = 0, z = 1}, {x = 0, y = 0, z = -1}}
local MAX_GROUP = 2000
-- 撐得住鋼拱的：可以站、不是鋼拱、不是碎石（碎石自己也會掉）
local function anchors(name)
	return backs(name) and not rockmech.is_rubble(name)
end
local function check_near(p, r)
	local seen = {}
	for _, q in ipairs(core.find_nodes_in_area(vector.subtract(p, r), vector.add(p, r), NODES)) do
		local h = core.hash_node_position(q)
		if not seen[h] then
			seen[h] = true
			local comp, stack, held = {}, {q}, false
			while #stack > 0 and #comp < MAX_GROUP do
				local c = table.remove(stack)
				comp[#comp + 1] = c
				for _, v in ipairs(SIX) do
					local nb = vector.add(c, v)
					local nn = core.get_node(nb).name
					if INFO[nn] then
						local hn = core.hash_node_position(nb)
						if not seen[hn] then seen[hn] = true; stack[#stack + 1] = nb end
					elseif anchors(nn) then
						held = true
					end
				end
			end
			if not held and #stack == 0 then
				to_waste(comp)
				tell_near(q, S("[Steel arch] Steel arch with nothing to hold it fell down"))
				core.log("action", ("[rockmech] 鋼拱懸空掉落 %s（%d 格）"):format(core.pos_to_string(q), #comp))
			end
		end
	end
end
rockmech.steelarch_check = check_near
core.register_on_dignode(function(pos, oldnode)
	core.after(0.4, check_near, vector.copy(pos), 2)
end)
core.register_lbm({
	label = "rockmech: 懸空的鋼拱掉下來", name = "rockmech:steelarch_hanging", nodenames = {"group:rockmech_steelarch"}, run_at_every_load = true,
	action = function(pos) core.after(1, check_near, vector.copy(pos), 0) end,
})
for name, info in pairs(INFO) do
	core.override_item(name, {on_dig = function(pos, node, digger)
		if digger and core.is_protected(pos, digger:get_player_name()) then return false end
		core.remove_node(pos)
		if not info.bent and digger and digger.is_player and digger:is_player() then
			local left = digger:get_inventory():add_item("main", ItemStack(ITEM))
			if not left:is_empty() then core.add_item(digger:get_pos(), left) end
		end
		if rockmech.fem_queue then rockmech.fem_queue(pos, 1, false, false) end
		return true
	end})
end

---------------------------------------------------------------------------
-- 應力解（femstress.lua 每次解完呼叫）：每格的軸力、彎矩、使用率
---------------------------------------------------------------------------

-- 一格鋼拱的受力：回傳 N (kN，壓為正), M (kN·m), U（使用率）
-- 鋼條的方向：貼著上下（頂板、地板）→ 沿 u；貼著左右（牆）→ 沿 y；都有（轉角）→ 兩個都算取大；
-- 都沒有（只接著別的鋼拱）→ 照相鄰鋼拱的方向
local function cell_force(job, res, x, y, z, p, axis)
	local fem = rockmech.fem
	local u = u_dir(axis)
	local function solid_at(v) return backs(core.get_node(vector.add(p, v)).name) end
	local function arch_at(v) return INFO[core.get_node(vector.add(p, v)).name] ~= nil end
	local mu = vector.multiply(u, -1)
	local along_u = solid_at(UP) or solid_at({x = 0, y = -1, z = 0})
	local along_y = solid_at(u) or solid_at(mu)
	if not along_u and not along_y then
		along_y = arch_at(UP) or arch_at({x = 0, y = -1, z = 0})
		along_u = not along_y
	end
	-- 斷面座標：u 是 x（axis z）或 z（axis x）；point_stress 回傳 sxx, syy, szz（壓為正）
	local ui = axis == "z" and 1 or 3
	local function pt(a, b)            -- a = u 方向的格內座標，b = y 方向
		local xi, eta, zeta = 0.5, b, 0.5
		if axis == "z" then xi = a else zeta = a end
		return {fem.point_stress(job, res, x, y, z, xi, eta, zeta)}
	end
	local best
	local function try(N, M)
		local U = math.abs(N) / Ny() + math.abs(M) / My()
		if not best or U > best[3] then best = {N, M, U} end
	end
	local c0 = pt(0.5, 0.5)
	if along_u then
		local top, bot = pt(0.5, 1), pt(0.5, 0)
		try(c0[ui], (top[ui] - bot[ui]) / 12)
	end
	if along_y then
		local hi, lo = pt(1, 0.5), pt(0, 0.5)
		try(c0[2], (hi[2] - lo[2]) / 12)
	end
	return best[1], best[2], best[3]
end

function rockmech.steelarch_fem_check(job, res, meta)
	local n, a = job.nx, meta.a
	local lo, hi = vector.add(a, 1), vector.add(a, n - 2)
	local half = math.floor((n - 2) / 2)
	check_near(vector.add(lo, half), half)        -- 崩落把撐著鋼拱的岩石帶走：懸空的掉下來
	local yielded, broken = {}, {}
	for _, p in ipairs(core.find_nodes_in_area(lo, hi, NODES)) do
		local x, y, z = p.x - a.x, p.y - a.y, p.z - a.z
		local c = 1 + x + y * n + z * n * n
		local info = INFO[core.get_node(p).name]
		if info and job.solid[c] then
			local N, M, U = cell_force(job, res, x, y, z, p, info.axis)
			if U >= 1 then
				if info.bent then broken[#broken + 1] = p else yielded[#yielded + 1] = p end
			end
			core.get_meta(p):set_string("infotext", (info.bent and S("Steel arch (yielded)") or S("Steel arch")) .. "\n"
				.. S("Axial force @1 kN, bending moment @2 kN·m", d(N), d(math.abs(M))) .. "\n"
				.. S("Utilisation @1%", d(U * 100)))
		end
	end
	for _, p in ipairs(yielded) do
		local i = INFO[core.get_node(p).name]
		core.swap_node(p, {name = arch_name(i.axis, true, i.layers)})
	end
	if #yielded > 0 then
		core.sound_play("default_dug_metal", {pos = yielded[1], gain = 1.0, max_hear_distance = 32}, true)
		tell_near(yielded[1], S("[Steel arch] @1 m of steel arch yielded and bent", tostring(#yielded)))
		core.log("action", ("[rockmech] 鋼拱降伏 %s（%d 格）"):format(core.pos_to_string(yielded[1]), #yielded))
	end
	if #broken > 0 then
		to_waste(broken)
		tell_near(broken[1], S("[Steel arch] @1 m of steel arch was crushed", tostring(#broken)))
		core.log("action", ("[rockmech] 鋼拱壓垮 %s（%d 格）"):format(core.pos_to_string(broken[1]), #broken))
		core.after(0.3, check_near, vector.copy(broken[1]), 4)
	end
	-- 勁度變了（降伏、壓垮）：荷重重新分配，再解一次
	if (#yielded > 0 or #broken > 0) and rockmech.fem_queue then
		rockmech.fem_queue((yielded[1] or broken[1]), 1, false, false)
	end
end

-- 應力解的勁度比、彎曲元素（retain.lua 先建好 support_ids.retain_r、pile，這裡補上）
core.register_on_mods_loaded(function()
	local ids = rockmech.support_ids
	if not (ids and ids.retain_r and ids.pile) then return end
	for name, info in pairs(INFO) do
		local cid = core.get_content_id(name)
		ids.retain_r[cid] = info.bent and ARCH_R * BENT_R or ARCH_R
		ids.pile[cid] = true
	end
end)
rockmech.steelarch = {ITEM = ITEM, ARCH_R = ARCH_R, Ny = Ny, My = My, INFO = INFO, cell_force = cell_force, arch_name = arch_name}
