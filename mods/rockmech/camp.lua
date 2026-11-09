-- rockmech/camp.lua
-- 營地的位置與混凝土地坪（原本在 orders.lua）：每座營地在哪、地坪範圍、收料區（收料車停的地磅）、保護。
-- 地坪：建築區（講堂、研究帳篷、貨櫃辦公室、長椅的外框）、交車區、收料區鋪混凝土，交車區和收料區畫黃線外框；
--   地坪上不能放東西、建築和地面挖不掉，往下 UNDER m 內也不能挖（碎石、自己放的置物櫃這類還是拿得走）；
--   有 rockmech 權限（老師）的人不受限。新蓋的營地整地完先鋪（career.lua 呼叫 rockmech.camp_pave），舊的營地補鋪。
-- 其他受保護的長條（鐵路，train.lua）用 rockmech.camp.protect 加。

local S = rockmech.S
local cfg = rockmech.cfg
local storage = rockmech.collapse.storage

---------------------------------------------------------------------------
-- 營地的位置
---------------------------------------------------------------------------

-- 地坪範圍（x 相對營地中心 x0，z 是絕對座標）；line：邊上一圈黃色外框
--   建築區：講堂、研究帳篷、貨櫃辦公室、長椅的外框再外推 2 m
--   交車區：delivery.lua 的 YARD（有東西擋著就不交車）
--   收料區：營地南邊外側、礦帶之間的平地走廊上（卡車從礦區往南開就到）。只鋪收料車加地磅那一條（7 m 寬），
--     兩側不鋪：自己放裝車料斗（放料臂 10 m）、接輸送帶裝進收料車
local PADS = {{x1 = 11, x2 = 32, z1 = -33, z2 = -1},
	{x1 = 10, x2 = 36, z1 = -54, z2 = -36, line = true},
	{x1 = -17, x2 = -11, z1 = -72, z2 = -59, line = true}}
-- 舊版鋪過的範圍（第一版整個南半部；之後的收料區在 z −50..−34、交車區到 z −34）：在新範圍外的換回表土
local OLD_PADS = {{x1 = -21, x2 = 33, z1 = -56, z2 = -1}, {x1 = 10, x2 = 36, z1 = -56, z2 = -34}}
local UNDER = 10                         -- 地坪下幾公尺內不能挖
-- 收料車：停在地磅上，車頭朝北；車身原點（駕駛艙中心）的位置
local BAY = {x = -14, z = -62}
local SCALE = {x1 = -15, x2 = -13, z1 = -69, z2 = -61}     -- 地磅鋼板
local CONCRETE = "rockmech:camp_concrete"
local SCALE_NODE = "rockmech:camp_scale"
local LINE = "rockmech:camp_concrete_line"           -- 黃色外框

local function sites()
	local out = {}
	if storage:get_string("career_site") == "2" then out[#out + 1] = cfg.career_camp_dx end
	if rockmech.team_site_x then
		for i = 1, cfg.career_teams or 0 do
			if storage:get_string("team_site:" .. i) == "1" then out[#out + 1] = rockmech.team_site_x(tostring(i)) end
		end
	end
	return out
end
-- 帳戶的營地：分組是那一組的營地；單人地圖是唯一那座
local function site_of(acc)
	local t = acc:match("^team:(%d+)$")
	if t and rockmech.team_site_x and storage:get_string("team_site:" .. t) == "1" then return rockmech.team_site_x(t) end
	if storage:get_string("career_site") == "2" then return cfg.career_camp_dx end
end
local function sy() return math.floor(cfg.surface_y or 0) end
local function in_rect(x0, r, x, z) return x >= x0 + r.x1 and x <= x0 + r.x2 and z >= r.z1 and z <= r.z2 end
local EXTRA = {}             -- 其他受保護的長條（鐵路，train.lua 用 rockmech.camp.protect 加）
local function in_pad(x0, pos)
	for _, r in ipairs(PADS) do if in_rect(x0, r, pos.x, pos.z) then return true end end
	for _, r in ipairs(EXTRA) do if in_rect(x0, r, pos.x, pos.z) then return true end end
	return false
end
-- (x, z) 地面最上面那格的 y（走得上去的方塊）
local function ground_y(x, z)
	for y = sy() + 8, sy() - 6, -1 do
		local n = core.get_node({x = x, y = y, z = z}).name
		if n == "ignore" then return nil end
		local d = core.registered_nodes[n]
		if n ~= "air" and d and d.walkable ~= false and not n:find("leaves") then return y end
	end
end

---------------------------------------------------------------------------
-- 方塊：混凝土地坪、地磅
---------------------------------------------------------------------------

local function noop() end
core.register_node(CONCRETE, {
	description = S("Concrete slab"),
	tiles = {"[fill:16x16:#a8a49c^[fill:16x1:0,0:#96928a^[fill:1x16:0,0:#96928a^[fill:2x1:5,6:#b8b4ac^[fill:1x1:11,11:#8e8a82"},
	is_ground_content = false, groups = {not_in_creative_inventory = 1}, on_blast = noop,
})
core.register_node(LINE, {
	description = S("Painted line"),
	tiles = {"[fill:16x16:#e0b428^[fill:16x1:0,0:#c89c20^[fill:3x1:4,9:#f0cc58^[fill:1x1:12,4:#b8901c",
		"[fill:16x16:#a8a49c^[fill:16x1:0,0:#96928a"},
	is_ground_content = false, groups = {not_in_creative_inventory = 1}, on_blast = noop,
})
core.register_node(SCALE_NODE, {
	description = S("Weighbridge"),
	tiles = {"[fill:16x16:#5a5e64^[fill:16x1:0,7:#3a3e44^[fill:1x16:7,0:#3a3e44^[fill:2x2:2,2:#7a7e84^[fill:2x2:12,12:#7a7e84"},
	is_ground_content = false, groups = {not_in_creative_inventory = 1}, on_blast = noop,
})

-- 地面方塊（表土、土、岩石）才鋪；建築的地板、家具、樹、玩家放的東西不動
local function pavable(n)
	if n == "air" or n == "ignore" then return false end
	if n:find("^rockmech:office_") or n:find("^rockmech:camp_") or n:find("^rockmech:tent_") or n:find("^rockmech:sign_") then return false end
	local d = core.registered_nodes[n]
	local g = d and d.groups or {}
	return (g.soil or g.crumbly or g.cracky or g.rockmech_topsoil) and not n:find("leaves") and not n:find("tree")
		and not rockmech.rubble_level[n] or rockmech.rubble_base and rockmech.rubble_base[n] == rockmech.RUBBLE_SOIL
end
-- 鋪地坪；舊版鋪過的（pad:x0 = 1、沒有 pad3）先把新範圍外面的混凝土換回表土
local TOPSOIL = "rockmech:topsoil"
local function pave(x0)
	local base = sy()
	if storage:get_string("pad:" .. x0) == "1" then
		local n = 0
		for _, o in ipairs(OLD_PADS) do for x = x0 + o.x1, x0 + o.x2 do
			for z = o.z1, o.z2 do
				if not in_pad(x0, {x = x, z = z}) then
					for y = base - 1, base + 2 do
						local p = {x = x, y = y, z = z}
						local nn = core.get_node(p).name
						if nn == CONCRETE or nn == SCALE_NODE or nn == LINE then core.set_node(p, {name = TOPSOIL}); n = n + 1 end
					end
				end
			end
		end end
		core.log("action", ("[rockmech] 營地 x = %d 地坪縮小：%d 格混凝土換回表土"):format(x0, n))
	end
	-- 每一欄往下找地面那一層：上面有椅子、長椅、樹、看板也照鋪（擺設留在地坪上）；
	-- 碰到建築的地板或已經鋪好的就停（地板就是建築自己的地面）
	local PAD_NODE = {[CONCRETE] = true, [SCALE_NODE] = true, [LINE] = true}
	for _, r in ipairs(PADS) do
		for x = x0 + r.x1, x0 + r.x2 do
			for z = r.z1, r.z2 do
				local want = in_rect(x0, SCALE, x, z) and SCALE_NODE
					or r.line and (x == x0 + r.x1 or x == x0 + r.x2 or z == r.z1 or z == r.z2) and LINE or CONCRETE
				for y = base + 2, base - 1, -1 do
					local p = {x = x, y = y, z = z}
					local n = core.get_node(p).name
					if n == "ignore" or n == want or n:find("floor") then break end
					if PAD_NODE[n] or pavable(n) then core.set_node(p, {name = want}); break end
				end
			end
		end
	end
	storage:set_string("pad:" .. x0, "1")
	storage:set_string("pad6:" .. x0, "1")
	core.log("action", ("[rockmech] 營地 x = %d 鋪好混凝土地坪、收料區"):format(x0))
end
local function done(x0) return storage:get_string("pad6:" .. x0) == "1" end
local function pave_when_loaded(x0)
	local a, b = {x = math.huge, y = sy() - 8, z = math.huge}, {x = -math.huge, y = sy() + 10, z = -math.huge}
	for _, list in ipairs({PADS, OLD_PADS}) do
		for _, r in ipairs(list) do
			a.x, a.z = math.min(a.x, x0 + r.x1), math.min(a.z, r.z1)
			b.x, b.z = math.max(b.x, x0 + r.x2), math.max(b.z, r.z2)
		end
	end
	core.emerge_area(a, b, function(_, _, rem)
		if rem > 0 or done(x0) then return end
		local col = rockmech.collapse
		col.quiet = col.quiet + 1
		local ok, err = pcall(pave, x0)
		col.quiet = col.quiet - 1
		if not ok then core.log("error", "[rockmech] pave: " .. tostring(err)) end
	end)
end
-- 新蓋的營地：career.lua 蓋營地時整地完先鋪（rockmech.camp_pave），建築、擺設再蓋在地坪上；
-- 舊的營地開服 4 秒後補鋪（或縮小）
function rockmech.camp_pave(x0) if not done(x0) then pave(x0) end end
core.after(4, function()
	for _, x0 in ipairs(sites()) do
		if not done(x0) then pave_when_loaded(x0) end
	end
end)

-- 保護：地坪範圍、地坪下 UNDER m 到上方 40 m。碎石隨時可以清；地面以上玩家自己放的東西（置物櫃…）拿得走
local BUILT = {"^rockmech:office_", "^rockmech:camp_", "^rockmech:tent_", "^rockmech:sign_", "^doors:", "^default:glass$", "^stairs:"}
local function pad_protected(pos, name)
	if not cfg.career then return false end
	local base = sy()
	if pos.y < base - UNDER or pos.y > base + 40 then return false end
	local x0
	for _, s in ipairs(sites()) do
		if storage:get_string("pad:" .. s) == "1" and in_pad(s, pos) then x0 = s; break end
	end
	if not x0 then return false end
	if name and name ~= "" and core.check_player_privs(name, {rockmech = true}) then return false end
	local n = core.get_node(pos).name
	if rockmech.rubble_level[n] then return false end
	if n == "air" then return true end                     -- 放東西（放進空格）
	if pos.y <= base + 1 then return true end              -- 地坪、地面、地下
	for _, pat in ipairs(BUILT) do if n:find(pat) then return true end end
	return false
end
rockmech.pad_protected = pad_protected
-- 地圖四邊的山（礦帶地圖，stress.edge_rise）：山腳以外整片不能挖、不能放（碎石可以清）
local function edge_protected(pos, name)
	if not (cfg.lane_terrain and cfg.lane_terrain.edge) then return false end
	local _, far = rockmech.stress.edge_rise(cfg, pos.x, pos.z)
	if far <= 0 then return false end
	if name and name ~= "" and core.check_player_privs(name, {rockmech = true}) then return false end
	if rockmech.rubble_level[core.get_node(pos).name] then return false end
	return true
end
rockmech.edge_protected = edge_protected
local old_protected = core.is_protected
function core.is_protected(pos, name)
	if pad_protected(pos, name) or edge_protected(pos, name) then return true end
	return old_protected(pos, name)
end
local last_warn = {}
core.register_on_protection_violation(function(pos, name)
	local msg
	if pad_protected(pos, name) then msg = S("Concrete slab: nothing can be built or dug here")
	elseif edge_protected(pos, name) then msg = S("Edge of the map: nothing can be built or dug here") end
	if not msg then return end
	local now = core.get_us_time()
	if last_warn[name] and now - last_warn[name] < 3e6 then return end
	last_warn[name] = now
	rockmech.notify(name, msg)
end)

rockmech.camp = {sites = sites, site_of = site_of, sy = sy, ground_y = ground_y, in_pad = in_pad,
	protect = function(r) EXTRA[#EXTRA + 1] = r end, PADS = PADS, BAY = BAY, SCALE = SCALE}
