-- rockmech/nodes.lua
-- 註冊岩性 node（引擎端）。
-- 有 default mod 時以 default_stone.png 著色；否則用 [fill 產生純色材質（devtest 可用）。
--
-- 節理材質變體：每種岩性另有 63 種變體 <岩性>_jNN（NN = 節理遮罩 1..63，
-- 見 joints.cell_mask），各面依遮罩畫節理跡線（邊緣深色線）與節理面（上色）。
-- 遮罩 0 即原本的 node。變體不出現在創造模式物品欄。

local S = rockmech.S
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

-- 動態產生貼圖：寫到世界資料夾 rockmech_media/，再以 dynamic_add_media（filepath）傳給客戶端
local function add_png(fname, w, h, px)
	local dir = core.get_worldpath() .. "/rockmech_media"
	core.mkdir(dir)
	local path = dir .. "/" .. fname
	local fh = assert(io.open(path, "wb"))
	fh:write(core.encode_png(w, h, px))
	fh:close()
	core.dynamic_add_media({filepath = path})
	return fname
end
local function rgb(hex)
	return tonumber(hex:sub(2, 3), 16), tonumber(hex:sub(4, 5), 16), tonumber(hex:sub(6, 7), 16)
end
-- 礦石方塊的調色盤：param2 i → 廢石與純礦的 RGB 線性混合（0 = 沒指定品位，用 default）
-- lith（可選）：岩性有自己的 pure（銅礦的氧化帶、富集帶、原生帶顏色不一樣）就用自己的調色盤
local lith_palette = {}
local function ore_palette(key, lith)
	local ore = cfg.ores[key]
	local own = lith and lith.pure
	local fname = own and ("rockmech_ore_" .. lith.name .. ".png") or ("rockmech_ore_" .. key .. ".png")
	if own then
		if lith_palette[lith.name] then return lith_palette[lith.name] end
	elseif ore.palette then return ore.palette end
	local r0, g0, b0 = rgb(ore.waste_color)
	local r1, g1, b1 = rgb(own or ore.pure)
	local px = {}
	for i = 0, 255 do
		local t = (i == 0 and ore.default or i) / 255
		px[i + 1] = string.char(math.floor(r0 + (r1 - r0) * t + 0.5), math.floor(g0 + (g1 - g0) * t + 0.5),
			math.floor(b0 + (b1 - b0) * t + 0.5), 255)
	end
	local png = add_png(fname, 256, 1, table.concat(px))
	if own then lith_palette[lith.name] = png else ore.palette = png end
	return png
end

-- 礦石方塊 param2 那一格的顏色（跟調色盤同一個公式），岩芯箱畫岩芯用
function rockmech.ore_color(key, p2, lith)
	local ore = cfg.ores[key]
	if not ore then return "#ffffff" end
	local r0, g0, b0 = rgb(ore.waste_color)
	local r1, g1, b1 = rgb(lith and lith.pure or ore.pure)
	local t = ((p2 or 0) == 0 and ore.default or p2) / 255
	return ("#%02x%02x%02x"):format(math.floor(r0 + (r1 - r0) * t + 0.5), math.floor(g0 + (g1 - g0) * t + 0.5), math.floor(b0 + (b1 - b0) * t + 0.5))
end

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
		-- 遮罩變體只有 edges 樣式用得到：其他樣式（plane、mesh、q5e）只註冊基本方塊，其餘做成別名（舊地圖裡的變體變回基本方塊）
		if mask > 0 and jt.style ~= "edges" then
			core.register_alias(name, base)
			rockmech.lith_variant[key][mask] = base
			goto continue
		end
		local groups = {cracky = lith.cracky or 3, stone = 1, rockmech_rock = 1, rockmech_ore = lith.ore and 1 or nil, rockmech_ore = lith.ore and 1 or nil}
		if mask ~= 0 then groups.not_in_creative_inventory = 1 end
		core.register_node(name, {
			description = S("@1",
				S(lith.description)),
			short_description = S(lith.description),
			tiles = mask == 0 and {base_tile} or joint_tiles(base_tile, mask),
			is_ground_content = true,
			paramtype2 = lith.ore and "color" or nil, palette = lith.ore and ore_palette(lith.ore, lith),
			groups = groups,
			sounds = sounds,
		})
		rockmech.lith_of_node[name] = lith
		rockmech.lith_nodes[#rockmech.lith_nodes + 1] = name
		rockmech.lith_variant[key][mask] = name
		::continue::
	end
end

-- 平面跡線變體（style = plane）：<岩性>_p<組字母><級>…，例如 shale_pa3c5
-- 跡線貼圖於啟動時以 core.encode_png 產生，寫入世界資料夾 rockmech_media/，
-- 再以 dynamic_add_media（filepath）傳給客戶端。
-- （用 filedata 直接傳在 Windows 上會有部分檔案「failed writing media file」。）
rockmech.lith_plane_variant = {} -- 岩性名稱 → {[後綴] = node 名稱}，後綴 "" 為基本 node
if jt.style == "plane" then      -- 只有 plane 樣式才註冊（DFN 地圖是 mesh 或 q5e，用不到這幾千個方塊）
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
					short_description = base_def.short_description,
					tiles = tiles,
					is_ground_content = true,
					paramtype2 = lith.ore and "color" or nil, palette = lith.ore and ore_palette(lith.ore, lith),
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
	if not jt.enabled or jt.style == "mesh" or jt.style == "q5e" then return rockmech.node_of_lith[key] end
	local sets = rockmech.get_joint_sets()
	if jt.style == "plane" then
		return rockmech.plane_variant_name(key, sets, pos.x, pos.y, pos.z)
	end
	return rockmech.lith_variant[key][joints.cell_mask(sets, pos.x, pos.y, pos.z)]
end

-- 依 y 取該深度分層的岩性條目
function rockmech.lith_at(x, y, z)
	return cfg.lithologies[rockmech.stress.lith_key_at(cfg, x, y, z)]
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
	description = S("Rubble"),
	short_description = S("Rubble"),
	tiles = {has_default and "default_gravel.png^[colorize:#5a5048:90" or "[fill:16x16:#6a6058"},
	groups = {crumbly = 2, cracky = 3, rockmech_rubble = 1},
	sounds = gravel_sounds,
})

rockmech.RUBBLE_GRANITE = rockmech.modname .. ":rubble_granite"
core.register_node(rockmech.RUBBLE_GRANITE, {
	description = S("Granite rubble"),
	short_description = S("Granite rubble"),
	-- 與花崗岩本身相同的粉紅色調（cfg 的岩性顏色），以礫石紋理呈現
	tiles = {has_default and ("default_gravel.png^[colorize:" .. cfg.lithologies.granite.color .. ":150")
		or ("[fill:16x16:" .. cfg.lithologies.granite.color)},
	groups = {crumbly = 2, cracky = 3, rockmech_rubble = 1},
	sounds = gravel_sounds,
})

-- 土壤：跟碎石同一套（顆粒流、安息角、8 級高度、有重量、可以搬、可以壓實），表面長草，樹苗種得活（group soil）。
-- 營地的林地鋪這個（woodwork.lua）。以後深開挖時，上覆的土壤一樣是荷重
rockmech.RUBBLE_SOIL = rockmech.modname .. ":rubble_soil"
core.register_node(rockmech.RUBBLE_SOIL, {
	description = S("Loose soil"),
	short_description = S("Loose soil"),
	tiles = {has_default and "default_dirt.png" or "[fill:16x16:#6a5030"},     -- 遊戲內建的泥土：沒有草（表土才有草）
	groups = {crumbly = 3, rockmech_rubble = 1, soil = 1},
	sounds = has_default and default.node_sound_dirt_defaults and default.node_sound_dirt_defaults() or gravel_sounds,
	is_ground_content = false,   -- 否則相鄰區塊生成時，會被 rockmech_strip_soil 當成土壤剝掉（半格也是，見下面）
})

rockmech.rubble_nodes = {rockmech.RUBBLE, rockmech.RUBBLE_GRANITE, rockmech.RUBBLE_SOIL}

-- 岩性 → 碎石（未列出的岩性用一般碎石）、碎石 → 岩性
rockmech.rubble_of_lith = {granite = rockmech.RUBBLE_GRANITE}
rockmech.lith_of_rubble = {[rockmech.RUBBLE_GRANITE] = "granite"}
-- 混合碎石：一格碎石最多記兩種成分（礦石、一般碎石、花崗岩碎石、鬆土），param2 存第一種成分 a 的比例（0..255）。
--   礦石＋X：param2 就是品位（礦石佔的比例），rockmech.ore_of_rubble[base] = 礦石。X 是礦石的廢石時沿用舊名 rubble_<礦>
--   鬆土＋碎石＝崩積土（colluvium），花崗岩＋一般碎石＝混合碎石。外觀依比例分 8 段（_g<段>，第 4 段就是 base 本身）：
--   b 的貼圖上透過遮罩疊 a 的貼圖，遮罩的像素隨段數一顆顆增加（兩種交錯）
-- 混進第三種：留體積最大的兩種，其餘的體積併進兩者裡價值低的那種（礦石 > 碎石 > 土；品位只會被稀釋）。見 rubble_merge
rockmech.RUBBLE_STEPS = 8
rockmech.ore_of_rubble = {}           -- 碎石 base → 礦石
rockmech.mix_of = {}                  -- 混合碎石 base → {a = 成分, b = 成分, ore = 礦石或 nil}；p2 = a 的比例
local mix_pair = {}                   -- 成分 a → 成分 b → base
local ore_root = {}                   -- 各段的滿格 node → base
local COMP_LABEL = {[rockmech.RUBBLE] = S("Rubble"), [rockmech.RUBBLE_GRANITE] = S("Granite rubble"), [rockmech.RUBBLE_SOIL] = S("Soil")}   -- 顯示用（已翻譯）
local COMP_RANK = {[rockmech.RUBBLE] = 2, [rockmech.RUBBLE_GRANITE] = 2, [rockmech.RUBBLE_SOIL] = 1}   -- 礦石 3
do
	local order, seed = {}, 12345     -- 固定順序：比例變高時 a 的像素只增不減
	for i = 1, 256 do order[i] = i end
	for i = 256, 2, -1 do
		seed = (seed * 1103515245 + 12345) % 2147483648
		local j = seed % i + 1
		order[i], order[j] = order[j], order[i]
	end
	local masks = {}
	for step = 1, rockmech.RUBBLE_STEPS do
		local on, px = {}, {}
		for i = 1, 256 * step / rockmech.RUBBLE_STEPS do on[order[i]] = true end
		for i = 1, 256 do px[i] = string.char(255, 255, 255, on[i] and 255 or 0) end
		masks[step] = add_png(("rockmech_ore_mask_%d.png"):format(step), 16, 16, table.concat(px))
	end
	local function tile(name) return core.registered_nodes[name].tiles[1] end
	-- 一種混合：base 名稱、成分 a（貼圖 ta）、成分 b
	local function family(base, a, ta, b, desc, ore, short)
		for step = 1, rockmech.RUBBLE_STEPS do
			local name = step == 4 and base or base .. "_g" .. step
			core.register_node(name, {
				description = desc,
				short_description = short or desc,
				tiles = {("%s^(%s^[mask:%s)"):format(tile(b), ta, masks[step])},
				groups = {crumbly = 2, cracky = 3, rockmech_rubble = 1, not_in_creative_inventory = step ~= 4 and 1 or nil},
				sounds = gravel_sounds,
				is_ground_content = false,
			})
			rockmech.rubble_nodes[#rockmech.rubble_nodes + 1] = name
			ore_root[name] = base
		end
		rockmech.mix_of[base] = {a = a, b = b, ore = ore}
		mix_pair[a] = mix_pair[a] or {}
		mix_pair[a][b] = base
		if ore then rockmech.ore_of_rubble[base] = ore end
	end
	local SHORT = {[rockmech.RUBBLE] = "", [rockmech.RUBBLE_GRANITE] = "_granite", [rockmech.RUBBLE_SOIL] = "_soil"}
	for key, ore in pairs(cfg.ores) do
		ore.key = key
		local comp = "ore:" .. key
		COMP_LABEL[comp], COMP_RANK[comp] = S(ore.label), 3
		local waste = rockmech.rubble_of_lith[ore.waste] or rockmech.RUBBLE
		local to = "default_gravel.png^[colorize:" .. ore.pure .. ":235"
		for _, x in ipairs({rockmech.RUBBLE, rockmech.RUBBLE_GRANITE, rockmech.RUBBLE_SOIL}) do
			local base = rockmech.modname .. ":rubble_" .. key .. (x == waste and "" or SHORT[x])
			if x == waste and SHORT[x] ~= "" then base = rockmech.modname .. ":rubble_" .. key end
			family(base, comp, to, x, x == waste and S("@1 rubble", S(ore.label))
				or S("@1 rubble, mixed with @2", S(ore.label), COMP_LABEL[x]), ore)
		end
		ore.rubble, ore.waste_rubble, ore.comp = mix_pair[comp][waste], waste, comp
		if ore.lith then        -- 銅精礦、尾礦沒有岩性（只從選礦場出來）
			rockmech.rubble_of_lith[ore.lith] = ore.rubble
			rockmech.lith_of_rubble[ore.rubble] = ore.lith
		end
	end
	-- 同一種礦有好幾種岩性（銅礦的氧化帶、富集帶、原生帶）：碎了都是那種礦的碎石
	for key, lith in pairs(cfg.lithologies) do
		local ore = lith.ore and cfg.ores[lith.ore]
		if ore and ore.rubble and not rockmech.rubble_of_lith[key] then rockmech.rubble_of_lith[key] = ore.rubble end
	end
	family(rockmech.modname .. ":colluvium", rockmech.RUBBLE_SOIL, tile(rockmech.RUBBLE_SOIL), rockmech.RUBBLE,
		S("Colluvium\nRubble and soil mixed together"), nil, S("Colluvium"))
	family(rockmech.modname .. ":colluvium_granite", rockmech.RUBBLE_SOIL, tile(rockmech.RUBBLE_SOIL), rockmech.RUBBLE_GRANITE,
		S("Granite colluvium\nGranite rubble and soil mixed together"), nil, S("Granite colluvium"))
	family(rockmech.modname .. ":rubble_mixed", rockmech.RUBBLE_GRANITE, tile(rockmech.RUBBLE_GRANITE), rockmech.RUBBLE,
		S("Mixed rubble\nGranite rubble and ordinary rubble mixed together"), nil, S("Mixed rubble"))
end
-- 合併規則是純函式（mix.lua，單元測試 tests/mix_spec.lua 也用）
local mix = dofile(rockmech.modpath .. "/mix.lua")
rockmech.mix = mix
local mix_ctx = {mix_of = rockmech.mix_of, pair = mix_pair, rank = COMP_RANK, ore_rubble = {}}
rockmech.mix_ctx = mix_ctx      -- assay.lua：三種以上成分的體積表也用同一套規則決定方塊外觀
for key, ore in pairs(cfg.ores) do mix_ctx.ore_rubble["ore:" .. key] = ore.rubble end
-- 金屬礦（銅）：同一族的成分（原礦、精礦、尾礦）混在一起時按含銅量合併（copper.lua）
do
	local fam = {}
	for key, ore in pairs(cfg.ores) do
		if ore.metal then fam["ore:" .. key] = {family = ore.metal.family, scale = ore.metal.scale, waste = ore.waste_rubble} end
	end
	if next(fam) then mix_ctx.merge_family = function(parts) return rockmech.copper.merge_family(parts, fam) end end
end

-- 兩份碎石能不能放在同一格：都可以（混合碎石，最多記兩種成分）
function rockmech.rubble_mixable(a, b)
	return a ~= nil and b ~= nil
end
-- 兩份碎石合併：依級數加權的品位。廢石的品位是 0
function rockmech.mix_grade(k1, p1, k2, p2)
	if k1 + k2 <= 0 then return 0 end
	return math.floor((k1 * p1 + k2 * p2) / (k1 + k2) + 0.5)
end
-- 合併一格的碎石（base 1 的 k1 級、param2 p1，加 base 2 的 k2 級、param2 p2）。回傳 種類, param2
function rockmech.rubble_merge(b1, k1, p1, b2, k2, p2)
	local b, p = mix.merge(mix_ctx, b1, k1, p1, b2, k2, p2)
	return b or b1, p
end
-- 混合碎石的成分文字（HUD、資訊頁）：礦石顯示品位，其他顯示兩種成分的比例
function rockmech.mix_text(base, p2)
	local m = rockmech.mix_of[base]
	if not m then return nil end
	local f = (p2 or 0) / 255
	if m.ore then
		local t = rockmech.ore_text(m.ore, f)
		return m.b == m.ore.waste_rubble and t or S("@1, mixed with @2", t, COMP_LABEL[m.b])
	end
	return S("@1 @2%, @3 @4%", COMP_LABEL[m.a], ("%.0f"):format(f * 100), COMP_LABEL[m.b], ("%.0f"):format((1 - f) * 100))
end
-- 混合碎石裡土的比例（0..1）：下雨時安息角照比例降低（collapse.lua）
function rockmech.soil_fraction(base, p2)
	if base == rockmech.RUBBLE_SOIL then return 1 end
	local m = rockmech.mix_of[base]
	if not m then return 0 end
	if m.a == rockmech.RUBBLE_SOIL then return (p2 or 0) / 255 end
	if m.b == rockmech.RUBBLE_SOIL then return 1 - (p2 or 0) / 255 end
	return 0
end
-- 岩石破碎或碎石本身的品位 param2：礦石沒指定品位時用 default；其他岩石的 param2 是 GSI，碎石用不到
function rockmech.rubble_p2(node)
	local lith = rockmech.lith_of_node[node.name]
	local ore = lith and lith.ore and cfg.ores[lith.ore]
	if ore then return node.param2 > 0 and node.param2 or ore.default end
	return rockmech.mix_of[rockmech.rubble_base[node.name]] and node.param2 or 0
end

-- 礦石品位的顯示文字（grade 0..1）：HUD、車輛載量共用
-- 顯示用的品位數字（不含 %，grade 0..1 是 param2/255）：一般的礦是礦石佔的比例；
-- 金屬礦（銅）是含銅量：原礦兩位小數、精礦一位、尾礦三位
function rockmech.grade_num(ore, grade)
	local m = ore and ore.metal
	if not m then return ("%.0f"):format(grade * 100) end
	local digits = m.scale >= 0.2 and 1 or m.scale < 0.02 and 3 or 2
	return ("%." .. digits .. "f"):format(grade * m.scale * 100)
end
function rockmech.ore_text(ore, grade)
	return S("@1 grade @2%", S(ore.label), rockmech.grade_num(ore, grade))
end
-- 顯示用的價格：一般的礦是每噸（品位 100%），金屬礦是每噸銅
function rockmech.price_str(ore, p)
	if ore and ore.metal then return S("$@1/t of copper", ("%.0f"):format(p)) end
	return ("$%.0f/t"):format(p)
end

-- 不滿格的碎石（顆粒流用，granular.lua）：每格分 8 級，<碎石>_l1 … _l7 高度 1/8 … 7/8 m；
-- 滿格仍是原本的碎石 node。都屬於 rockmech_rubble 群組（實心、可站立）。
rockmech.RUBBLE_LEVELS = 8
rockmech.rubble_level = {}    -- node 名稱 → 級數（滿格 = 8）
rockmech.rubble_base = {}     -- node 名稱 → 滿格碎石的名稱
local partial_nodes = {}
for _, base in ipairs(rockmech.rubble_nodes) do
	local bdef = core.registered_nodes[base]
	local root = ore_root[base] or base
	rockmech.rubble_level[base] = rockmech.RUBBLE_LEVELS
	rockmech.rubble_base[base] = ore_root[base] or base
	for k = 1, rockmech.RUBBLE_LEVELS - 1 do
		local name = base .. "_l" .. k
		local top = -0.5 + k / rockmech.RUBBLE_LEVELS
		local groups = table.copy(bdef.groups)
		groups.not_in_creative_inventory = 1
		groups.rockmech_rubble_level = k
		core.register_node(name, {
			description = bdef.description,
			short_description = bdef.short_description,
			tiles = bdef.tiles,
			drawtype = "nodebox",
			paramtype = "light",
			node_box = {type = "fixed", fixed = {-0.5, -0.5, -0.5, 0.5, top, 0.5}},
			groups = groups,
			sounds = bdef.sounds,
			is_ground_content = bdef.is_ground_content,
			drop = k >= rockmech.RUBBLE_LEVELS / 2 and base or "",
		})
		rockmech.rubble_level[name] = k
		rockmech.rubble_base[name] = root
		partial_nodes[#partial_nodes + 1] = name
	end
end
for _, name in ipairs(partial_nodes) do rockmech.rubble_nodes[#rockmech.rubble_nodes + 1] = name end

-- 壓實的碎石（交通壓實、噴凝土）：每一種碎石（各級數、各品位段）都有一個壓實版 <名稱>_c，顏色較淡。
-- 它還是碎石：挖土機、鏟子挖得起來（挖起來是一般碎石），推土機推得動，底下掏空會掉，礦種和品位不變；
-- 只是自己不流動、壓不出車轍（collapse.lua granular_settle）。級數一變（被削掉一部分、上面倒碎石合併）就變回一般碎石
rockmech.compacted = {}       -- 壓實版名稱 → true
rockmech.compact_of = {}      -- 一般碎石名稱 → 壓實版名稱
local compacted_nodes = {}
for _, name in ipairs(rockmech.rubble_nodes) do
	local def = core.registered_nodes[name]
	local cname = name .. "_c"
	local tiles = {}
	for i, t in ipairs(def.tiles) do tiles[i] = (type(t) == "table" and t.name or t) .. "^[colorize:#ffffff:80" end
	local groups = table.copy(def.groups)
	groups.not_in_creative_inventory = 1
	core.register_node(cname, {
		description = S("@1 (compacted)", def.description),
		short_description = S("@1 (compacted)", def.short_description or def.description),
		tiles = tiles,
		drawtype = def.drawtype,
		paramtype = def.paramtype,
		paramtype2 = def.paramtype2,
		node_box = def.node_box,
		groups = groups,
		sounds = def.sounds,
		drop = def.drop,
		is_ground_content = false,   -- 否則相鄰區塊生成時，會被 rockmech_strip_soil 當成土壤剝掉
	})
	rockmech.rubble_level[cname] = rockmech.rubble_level[name]
	rockmech.rubble_base[cname] = rockmech.rubble_base[name]
	rockmech.compacted[cname] = true
	rockmech.compact_of[name] = cname
	compacted_nodes[#compacted_nodes + 1] = cname
end
for _, name in ipairs(compacted_nodes) do rockmech.rubble_nodes[#rockmech.rubble_nodes + 1] = name end

-- 某種碎石（滿格名稱 base）的 k 級 node 名稱（k = 0 → nil，k ≥ 8 → 滿格）。p2：礦石碎石的品位，決定外觀的段
function rockmech.rubble_with_level(base, k, p2)
	if k <= 0 then return nil end
	if rockmech.mix_of[base] and p2 then
		local step = math.max(1, math.min(rockmech.RUBBLE_STEPS, math.ceil(p2 / 255 * rockmech.RUBBLE_STEPS)))
		if step ~= 4 then base = base .. "_g" .. step end
	end
	if k >= rockmech.RUBBLE_LEVELS then return base end
	return base .. "_l" .. k
end

function rockmech.is_rubble(name)
	return core.get_item_group(name, "rockmech_rubble") > 0
end

-- 舊版的夯實碎石（路面）：另一種方塊，不算碎石，底下掏空會懸空、挖土機挖不動。
-- 現在改用壓實的碎石（上面的 rockmech.compact_of），舊世界的這些方塊載入時換掉（最下面的 LBM）
rockmech.road_level = {}      -- node 名稱 → 級數
for k = 1, rockmech.RUBBLE_LEVELS do
	local name = rockmech.modname .. ":road_l" .. k
	local rubble = core.registered_nodes[rockmech.RUBBLE]
	core.register_node(name, {
		description = S("Compacted rubble"),
		tiles = {rubble.tiles[1] .. "^[colorize:#a89878:110"},
		drawtype = "nodebox",
		paramtype = "light",
		node_box = {type = "fixed", fixed = {-0.5, -0.5, -0.5, 0.5, -0.5 + k / rockmech.RUBBLE_LEVELS, 0.5}},
		groups = {crumbly = 2, cracky = 3, not_in_creative_inventory = 1},
		is_ground_content = false,   -- 否則相鄰區塊生成時，會被 rockmech_strip_soil 當成土壤剝掉
		sounds = rubble.sounds,
		drop = k >= rockmech.RUBBLE_LEVELS / 2 and rockmech.RUBBLE or "",
	})
	rockmech.road_level[name] = k
end
core.register_lbm({
	label = "rockmech: 舊版夯實碎石換成壓實的碎石",
	name = "rockmech:road_to_compacted_rubble",
	nodenames = (function()
		local t = {}
		for n in pairs(rockmech.road_level) do t[#t + 1] = n end
		return t
	end)(),
	run_at_every_load = false,
	action = function(pos, node)
		local k = rockmech.road_level[node.name]
		core.swap_node(pos, {name = rockmech.compact_of[rockmech.rubble_with_level(rockmech.RUBBLE, k)]})
	end,
})

-- 某個岩石 node 破碎後變成哪種碎石（碎石本身不變；不滿格的碎石回傳其滿格種類）
function rockmech.rubble_for(nodename)
	if rockmech.is_rubble(nodename) then return rockmech.rubble_base[nodename] or nodename end
	local lith = rockmech.lith_of_node[nodename]
	return lith and rockmech.rubble_of_lith[lith.name] or rockmech.RUBBLE
end
-- 岩石破碎：回傳 碎石的滿格 node 名稱, param2
function rockmech.rubble_node(node)
	local p = rockmech.rubble_p2(node)
	return rockmech.rubble_with_level(rockmech.rubble_for(node.name), rockmech.RUBBLE_LEVELS, p), p
end

-- 物品欄裡不滿格的碎石（舊版爆破噴出的）：依級數併成滿格碎石（8 級 = 1 個，四捨五入），才會疊在同一堆
function rockmech.merge_partial_rubble(inv, listname)
	local lv = {}
	local changed = false
	for i, st in ipairs(inv:get_list(listname) or {}) do
		local name = st:get_name()
		local k = rockmech.rubble_level[name]
		if k and k < rockmech.RUBBLE_LEVELS then
			local base = rockmech.rubble_base[name]
			lv[base] = (lv[base] or 0) + k * st:get_count()
			inv:set_stack(listname, i, ItemStack(""))
			changed = true
		end
	end
	for base, l in pairs(lv) do
		local n = math.floor(l / rockmech.RUBBLE_LEVELS + 0.5)
		if n > 0 then inv:add_item(listname, ItemStack(base .. " " .. n)) end
	end
	return changed
end
core.register_on_joinplayer(function(player)
	rockmech.merge_partial_rubble(player:get_inventory(), "main")
end)

-- 早期分三類的煤與碎煤：放過的方塊換成現在的（品位回到中間值）
for _, old in ipairs({"high", "mid", "low"}) do
	for _, n in ipairs(rockmech.lith_nodes) do
		if n:find("^" .. rockmech.modname .. ":coal") then
			core.register_alias(n:gsub(":coal", ":coal_" .. old, 1), n)
		end
	end
	local coal_rubble = cfg.ores.coal.rubble
	local oldr = coal_rubble .. "_" .. old
	core.register_alias(oldr, coal_rubble)
	for k = 1, rockmech.RUBBLE_LEVELS - 1 do
		core.register_alias(oldr .. "_l" .. k, coal_rubble .. "_l" .. k)
	end
end
