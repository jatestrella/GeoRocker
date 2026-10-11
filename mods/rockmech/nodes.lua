-- rockmech/nodes.lua
-- 註冊岩性 node（引擎端）。
-- 有 default mod 時以 default_stone.png 著色；否則用 [fill 產生純色材質（devtest 可用）。
--
-- 節理材質變體：每種岩性另有 63 種變體 <岩性>_jNN（NN = 節理遮罩 1..63，
-- 見 joints.cell_mask），各面依遮罩畫節理跡線（邊緣深色線）與節理面（上色）。
-- 遮罩 0 即原本的 node。變體不出現在創造模式物品欄。

local cfg = rockmech.cfg
local joints = rockmech.joints
local has_default = core.get_modpath("default") ~= nil

local sounds
if has_default and default and default.node_sound_stone_defaults then
	sounds = default.node_sound_stone_defaults()
end

rockmech.node_of_lith = {}    -- 岩性名稱 → 基本 node 名稱（遮罩 0）
rockmech.lith_of_node = {}    -- node 名稱（含變體）→ 岩性條目
rockmech.lith_nodes = {}      -- 所有岩性 node 名稱（含變體）
rockmech.lith_variant = {}    -- 岩性名稱 → {[遮罩] = node 名稱}，遮罩 0..63

-- 節理材質參數
local jt = cfg.jointtex
local TEX = 16 -- 基底材質解析度（default_stone.png 為 16×16）
local W = math.max(1, math.min(8, math.floor(jt.line_width)))
local line_color = jt.line_color .. string.format("%02x", jt.line_alpha)

local function variant_name(base, mask)
	if mask == 0 then return base end
	return ("%s_j%02d"):format(base, mask)
end
rockmech.variant_name = variant_name

-- 依遮罩產生 6 面材質（tiles 順序 +Y, -Y, +X, -X, +Z, -Z）
local function joint_tiles(base_tile, mask)
	local tiles = {}
	for i, e in ipairs(joints.TILE_EDGES) do
		local t = base_tile
		if joints.has_bit(mask, e.self) then
			t = t .. "^[colorize:" .. jt.face_color .. ":" .. jt.face_ratio
		end
		if joints.has_bit(mask, e.top) then
			t = t .. ("^[fill:%dx%d:0,0:%s"):format(TEX, W, line_color)
		end
		if joints.has_bit(mask, e.bottom) then
			t = t .. ("^[fill:%dx%d:0,%d:%s"):format(TEX, W, TEX - W, line_color)
		end
		if joints.has_bit(mask, e.left) then
			t = t .. ("^[fill:%dx%d:0,0:%s"):format(W, TEX, line_color)
		end
		if joints.has_bit(mask, e.right) then
			t = t .. ("^[fill:%dx%d:%d,0:%s"):format(W, TEX, TEX - W, line_color)
		end
		tiles[i] = t
	end
	return tiles
end
rockmech.joint_tiles = joint_tiles

for _, key in ipairs(cfg.lithology_order) do
	local lith = cfg.lithologies[key]
	local base = rockmech.modname .. ":" .. lith.name
	local base_tile
	if lith.texture then
		base_tile = lith.texture
	elseif has_default then
		base_tile = "default_stone.png^[colorize:" .. lith.color .. ":150"
	else
		base_tile = ("[fill:%dx%d:%s"):format(TEX, TEX, lith.color)
	end

	rockmech.node_of_lith[key] = base
	rockmech.lith_variant[key] = {}
	for mask = 0, 63 do
		local name = variant_name(base, mask)
		local groups = {cracky = lith.cracky or 3, stone = 1, rockmech_rock = 1}
		if mask ~= 0 then groups.not_in_creative_inventory = 1 end
		core.register_node(name, {
			description = lith.description .. "\n" ..
				("γ=%.1f kN/m³  UCS=%g MPa  σt=%g MPa"):format(lith.gamma, lith.ucs, lith.tensile) ..
				"\n放置後依所在位置顯示節理",
			tiles = mask == 0 and {base_tile} or joint_tiles(base_tile, mask),
			is_ground_content = true,
			groups = groups,
			sounds = sounds,
		})
		rockmech.lith_of_node[name] = lith
		rockmech.lith_nodes[#rockmech.lith_nodes + 1] = name
		rockmech.lith_variant[key][mask] = name
	end
end

-- 平面跡線變體（style = plane）：<岩性>_p<組字母><級>…，例如 shale_pa3c5
-- 跡線貼圖於啟動時以 core.encode_png 產生，寫入世界資料夾 rockmech_media/，
-- 再以 dynamic_add_media（filepath）傳給客戶端。
-- （用 filedata 直接傳在 Windows 上會有部分檔案「failed writing media file」。）
rockmech.lith_plane_variant = {} -- 岩性名稱 → {[後綴] = node 名稱}，後綴 "" 為基本 node
do
	local jtx = rockmech.jointtex
	local R, MAXL = jt.plane_res, jt.max_lines
	-- 只需法向量與級數，與種子無關
	local sets = joints.prepare(cfg.joint_sets, 0, cfg.joint_lattice)
	local nsets = math.min(#sets, 4)
	local levels = {}
	for i = 1, nsets do levels[i] = jtx.levels(sets[i]) end
	local r = tonumber(jt.line_color:sub(2, 3), 16)
	local g = tonumber(jt.line_color:sub(4, 5), 16)
	local b = tonumber(jt.line_color:sub(6, 7), 16)

	-- tex[face][set][level] = 貼圖檔名（該面沒有跡線則為 nil）
	local tex, n_png = {}, 0
	local media_dir = core.get_worldpath() .. "/rockmech_media"
	core.mkdir(media_dir)
	for f, face in ipairs(jtx.FACES) do
		tex[f] = {}
		for i = 1, nsets do
			tex[f][i] = {}
			for bin = 0, levels[i] - 1 do
				local alpha = jtx.face_line_alpha(sets[i], face, bin, R, jt.plane_width)
				if alpha then
					local px = {}
					for k = 1, R * R do
						px[k] = string.char(r, g, b, math.floor(alpha[k] * jt.line_alpha + 0.5))
					end
					local fname = ("rockmech_jl_f%d_s%d_b%d.png"):format(f, i, bin)
					local path = media_dir .. "/" .. fname
					local fh = io.open(path, "wb")
					if fh then
						fh:write(core.encode_png(R, R, table.concat(px)))
						fh:close()
						if core.dynamic_add_media({filepath = path}) then
							tex[f][i][bin] = fname
							n_png = n_png + 1
						else
							core.log("warning", "[rockmech] 無法加入跡線貼圖 " .. fname)
						end
					else
						core.log("warning", "[rockmech] 無法寫入 " .. path)
					end
				end
			end
		end
	end

	local combos = jtx.all_combos(levels, MAXL)
	for _, key in ipairs(cfg.lithology_order) do
		local lith = cfg.lithologies[key]
		local base = rockmech.node_of_lith[key]
		local base_def = core.registered_nodes[base]
		local base_tile = base_def.tiles[1]
		base_tile = type(base_tile) == "table" and base_tile.name or base_tile
		rockmech.lith_plane_variant[key] = {[""] = base}
		for _, combo in ipairs(combos) do
			if #combo > 0 then
				local name = base .. jtx.suffix(combo)
				local tiles = {}
				for f = 1, 6 do
					local t = base_tile
					for _, tr in ipairs(combo) do
						local fn = tex[f][tr.set][tr.level]
						if fn then t = t .. "^" .. fn end
					end
					tiles[f] = t
				end
				core.register_node(name, {
					description = base_def.description,
					tiles = tiles,
					is_ground_content = true,
					groups = {cracky = lith.cracky or 3, stone = 1, rockmech_rock = 1,
						not_in_creative_inventory = 1},
					sounds = sounds,
				})
				rockmech.lith_of_node[name] = lith
				rockmech.lith_nodes[#rockmech.lith_nodes + 1] = name
				rockmech.lith_plane_variant[key][jtx.suffix(combo)] = name
			end
		end
	end
	local eff = {}
	for i = 1, nsets do
		local js = sets[i]
		eff[#eff + 1] = ("%s %g°/%g° → %.1f°/%.1f° m=(%d,%d,%d) S=%.2f 級數 %d"):format(js.name,
			js.dip, js.dipdir, js.dip_eff, js.dipdir_eff, js.mx, js.my, js.mz, js.spacing_eff, levels[i])
	end
	core.log("action", ("[rockmech] 平面跡線：%d 張貼圖、每岩性 %d 種變體；格點 D=%d；%s"):format(
		n_png, #combos - 1, cfg.joint_lattice, table.concat(eff, "；")))

	-- 依格位置取 node 名稱（style = plane；sets 需為依世界種子前處理者）
	function rockmech.plane_variant_name(key, world_sets, x, y, z)
		local tr = jtx.cell_traces(joints, world_sets, x, y, z, MAXL)
		return rockmech.lith_plane_variant[key][jtx.suffix(tr)]
	end
end

-- 依目前的節理材質設定，取得某岩性在某位置應顯示的 node 名稱
function rockmech.joint_variant_for(key, pos)
	if not jt.enabled then return rockmech.node_of_lith[key] end
	local sets = rockmech.get_joint_sets()
	if jt.style == "plane" then
		return rockmech.plane_variant_name(key, sets, pos.x, pos.y, pos.z)
	end
	return rockmech.lith_variant[key][joints.cell_mask(sets, pos.x, pos.y, pos.z)]
end

-- 依 y 取該深度分層的岩性條目
function rockmech.lith_at(x, y, z)
	return cfg.lithologies[rockmech.stress.lith_key_at(cfg, x, y)]
end

function rockmech.lith_at_y(y)
	local h = rockmech.stress.depth(y, cfg.surface_y)
	return cfg.lithologies[rockmech.stress.layer_at_depth(cfg.layers, h)]
end

-- physics_core 舊 node 相容：大岩塊已移除，舊世界中的回到 stone（可用 /convert_rocks 轉成岩性）
if core.registered_nodes["default:stone"] then
	core.register_alias("physics_core:large_rock", "default:stone")
end

-- 碎石：軸差破壞後的岩石。不參與軸差判定（非岩性），
-- 但在 collapse.lua 中套用懸空掉落與安息角滑動。
-- 碎石種類：一般碎石（灰）與花崗岩碎石（粉紅，同花崗岩色調）。皆屬 group rockmech_rubble。
local gravel_sounds = has_default and default.node_sound_gravel_defaults and default.node_sound_gravel_defaults() or sounds

rockmech.RUBBLE = rockmech.modname .. ":rubble"
core.register_node(rockmech.RUBBLE, {
	description = "Rubble (碎石)\n破碎的岩石",
	tiles = {has_default and "default_gravel.png^[colorize:#5a5048:90" or "[fill:16x16:#6a6058"},
	groups = {crumbly = 2, cracky = 3, rockmech_rubble = 1},
	sounds = gravel_sounds,
})

rockmech.RUBBLE_GRANITE = rockmech.modname .. ":rubble_granite"
core.register_node(rockmech.RUBBLE_GRANITE, {
	description = "Granite rubble (花崗岩碎石)\n破碎的花崗岩",
	-- 與花崗岩本身相同的粉紅色調（cfg 的岩性顏色），以礫石紋理呈現
	tiles = {has_default and ("default_gravel.png^[colorize:" .. cfg.lithologies.granite.color .. ":150")
		or ("[fill:16x16:" .. cfg.lithologies.granite.color)},
	groups = {crumbly = 2, cracky = 3, rockmech_rubble = 1},
	sounds = gravel_sounds,
})

rockmech.rubble_nodes = {rockmech.RUBBLE, rockmech.RUBBLE_GRANITE}
-- 岩性 → 碎石；未列出的岩性用一般碎石
rockmech.rubble_of_lith = {granite = rockmech.RUBBLE_GRANITE}

function rockmech.is_rubble(name)
	return core.get_item_group(name, "rockmech_rubble") > 0
end

-- 某個岩石 node 破碎後變成哪種碎石（碎石本身不變）
function rockmech.rubble_for(nodename)
	if rockmech.is_rubble(nodename) then return nodename end
	local lith = rockmech.lith_of_node[nodename]
	return lith and rockmech.rubble_of_lith[lith.name] or rockmech.RUBBLE
end
