-- rockmech/jointmesh.lua
-- 節理跡線網格（rockmech_jointtex_style = mesh）：
-- 不再為每種跡線組合註冊方塊變體，改成每個 16³ 區塊產生一個網格，把露出岩面上的
-- 節理跡線畫成細長的四邊形，以動態媒體送給客戶端，掛在一個實體上顯示。
-- 節理組數、每格跡線數都沒有上限；跡線與力學用的節理面一致（同 jointtex 的延續性判定）。
--
-- 也可在 plane 模式下開 rockmech_jointtex_mesh_overlay，疊一層紅色網格跡線檢查是否與貼圖重合。
--
-- 幾何：平面 m·P + o = L·k（P 為連續世界座標，格中心為整數）。露出的面（格 c 往 e 方向、
-- 鄰格不是實心）是邊長 1 的正方形；求平面與正方形四邊的交點 → 線段 → 沿面內垂直方向
-- 加寬成四邊形，並沿 e 往外偏移一點避免與方塊重疊閃爍。
-- 網格座標：10 單位 = 1 格（Luanti 的 mesh 慣例），原點在區塊的最小角格中心。

local cfg = rockmech.cfg
local jt = cfg.jointtex
local overlay = jt.mesh_overlay and jt.style == "plane"
if not jt.enabled or (jt.style ~= "mesh" and not overlay) then return end

local joints, jtx = rockmech.joints, rockmech.jointtex
local api = {}
rockmech.jointmesh = api

local BS = 10
local XFLIP = -1   -- OBJ 載入時 X 會被反轉（右手 → 左手座標），預先反轉回來
local HW = jt.mesh_width / 2        -- 線寬的一半 (m)
local OFF = 0.004                   -- 往外偏移 (m)
local RANGE = jt.mesh_range          -- 玩家周圍幾個區塊（水平）
local VRANGE = math.max(1, RANGE - 1)
local PER_STEP = 4                   -- 新進入範圍的區塊：每 0.5 s 最多建幾個
local DIRTY_STEP = 8                 -- 地形改變的區塊：每 0.05 s 最多重建幾個（優先）
local DEBUG = jt.mesh_debug   -- 記錄改變到送達的延遲（rockmech_jointtex_mesh_debug）
local MIN_GAP = 0.2                  -- 同一區塊兩次重建的最短間隔 (s)：崩落過程中不一直重做
local ENT = "rockmech:jointmesh"
local TEX = overlay and "[fill:2x2:#ff2020" or ("[fill:2x2:" .. jt.line_color)

core.register_entity(ENT, {
	initial_properties = {
		visual = "mesh", mesh = "", textures = {TEX},
		physical = false, pointable = false, static_save = false,
		backface_culling = false, is_visible = false,
		collisionbox = {0, 0, 0, 0, 0, 0}, selectionbox = {0, 0, 0, 0, 0, 0},
		glow = overlay and 14 or 0, shaded = false,
	},
	on_step = function(self)
		if not self.rm_key then self.object:remove() end
	end,
})

local blocks = {}    -- key → {obj, dirty, serial, pending}
local media_dir = core.get_worldpath() .. DIR_DELIM .. "rockmech_jointmesh"
core.mkdir(media_dir)
-- 上次留下的暫存檔
for _, f in ipairs(core.get_dir_list(media_dir, false) or {}) do os.remove(media_dir .. DIR_DELIM .. f) end
local serial = 0
local function bkey(bx, by, bz) return bx .. "," .. by .. "," .. bz end

-- 會把岩面完全蓋住的鄰格：完整的不透明方塊（半格碎石、植物等蓋不住）
local solid_cid, rock_cid
local function build_cids()
	if solid_cid then return end
	solid_cid, rock_cid = {}, {}
	for name, def in pairs(core.registered_nodes) do
		solid_cid[core.get_content_id(name)] = (def.drawtype == nil or def.drawtype == "normal")
			and def.walkable ~= false
	end
	for _, n in ipairs(rockmech.lith_nodes) do
		-- 煤層不帶節理（init.lua 的 get_joint_sets）：煤的方塊不畫節理線
		if not ((rockmech.lith_of_node[n] or {}).name == "coal" and not rockmech.cfg.coal_joints) then rock_cid[core.get_content_id(n)] = true end
	end
	solid_cid[core.get_content_id("ignore")] = true
end

-- 六個方向：{dx, dy, dz, 軸, 正負}
local DIRS = {{1, 0, 0, 1, 1}, {-1, 0, 0, 1, -1}, {0, 1, 0, 2, 1}, {0, -1, 0, 2, -1}, {0, 0, 1, 3, 1}, {0, 0, -1, 3, -1}}
local OTHER = {{2, 3}, {1, 3}, {1, 2}}   -- 每個軸的另外兩軸

-- 區塊 (bx,by,bz) 的網格（OBJ 文字）；沒有任何跡線回傳 nil
local function build_mesh(bx, by, bz)
	build_cids()
	local sets = rockmech.get_joint_sets()
	local minp = {x = bx * 16, y = by * 16, z = bz * 16}
	local maxp = {x = minp.x + 15, y = minp.y + 15, z = minp.z + 15}
	local vm = core.get_voxel_manip()
	local e1, e2 = vm:read_from_map(vector.subtract(minp, 1), vector.add(maxp, 1))
	local area = VoxelArea(e1, e2)
	local data = vm:get_data()
	vm:close()
	local verts, faces = {}, {}
	local nv = 0
	local function vert(p)
		nv = nv + 1
		-- X 預先反轉（見 XFLIP）
		verts[nv] = ("v %.4f %.4f %.4f"):format(XFLIP * (p[1] - minp.x) * BS, (p[2] - minp.y) * BS, (p[3] - minp.z) * BS)
		return nv
	end
	local live = {}
	for i = 1, #sets do
		if (sets[i].persistence or 1) > 0 then live[#live + 1] = sets[i] end
	end
	local D = sets.dfn          -- 離散裂隙網路：跡線是圓盤和岩面的交線（dfn.face_traces）
	if D then live = {} end
	-- 一條跡線（面內座標 a → b）加寬成四邊形
	local function quad(c, ax, sg, u, v, a, b)
		local function world(q)
			local p = {c[1], c[2], c[3]}
			p[ax] = p[ax] + 0.5 * sg + OFF * sg
			p[u] = p[u] + q[1]
			p[v] = p[v] + q[2]
			return p
		end
		local du, dv = b[1] - a[1], b[2] - a[2]
		local l = math.sqrt(du * du + dv * dv)
		if l > 1e-4 then
			local nu, nv_ = -dv / l * HW, du / l * HW
			local i1 = vert(world({a[1] + nu, a[2] + nv_}))
			local i2 = vert(world({b[1] + nu, b[2] + nv_}))
			local i3 = vert(world({b[1] - nu, b[2] - nv_}))
			local i4 = vert(world({a[1] - nu, a[2] - nv_}))
			faces[#faces + 1] = ("f %d/1 %d/1 %d/1 %d/1"):format(i1, i2, i3, i4)
		end
	end
	for z = minp.z, maxp.z do for y = minp.y, maxp.y do
		local vi = area:index(minp.x, y, z)
		for x = minp.x, maxp.x do
			if rock_cid[data[vi]] then
				local c = {x, y, z}
				for _, d in ipairs(DIRS) do
					local nb = data[area:index(x + d[1], y + d[2], z + d[3])]
					if not solid_cid[nb] then
						local ax, sg = d[4], d[5]
						local u, v = OTHER[ax][1], OTHER[ax][2]
						if D then
							for _, t in ipairs(D:face_traces(x, y, z, ax, sg, D.where and D.where(x, y, z))) do
								quad(c, ax, sg, u, v, {t[1], t[2]}, {t[3], t[4]})
							end
						end
						for _, js in ipairs(live) do
							local m = {js.mx, js.my, js.mz}
							if m[u] ~= 0 or m[v] ~= 0 then
								-- 四個角（u−v−, u+v−, u+v+, u−v+）的 m·P + o
								local fc = js.mx * x + js.my * y + js.mz * z + js.o + m[ax] * 0.5 * sg
								local corners = {{-0.5, -0.5}, {0.5, -0.5}, {0.5, 0.5}, {-0.5, 0.5}}
								local fv, lo, hi = {}, math.huge, -math.huge
								for ci, cc in ipairs(corners) do
									local f = fc + m[u] * cc[1] + m[v] * cc[2]
									fv[ci] = f
									if f < lo then lo = f end
									if f > hi then hi = f end
								end
								local L = js.L
								for k = math.floor(lo / L), math.ceil(hi / L) do
									local T = L * k
									if T > lo and T < hi and jtx.plane_present(joints, js, k, x, y, z) then
										local pts = {}
										for ci = 1, 4 do
											local cj = ci % 4 + 1
											local fa, fb = fv[ci] - T, fv[cj] - T
											if (fa < 0) ~= (fb < 0) then
												local t = fa / (fa - fb)
												local a, b = corners[ci], corners[cj]
												pts[#pts + 1] = {a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t}
											end
										end
										if #pts >= 2 then
											-- 面內座標 → 世界座標
											local function world(q, w)
												local p = {c[1], c[2], c[3]}
												p[ax] = p[ax] + 0.5 * sg + OFF * sg
												p[u] = p[u] + q[1]
												p[v] = p[v] + q[2]
												return p
											end
											local a, b = pts[1], pts[2]
											local du, dv = b[1] - a[1], b[2] - a[2]
											local l = math.sqrt(du * du + dv * dv)
											if l > 1e-4 then
												local nu, nv_ = -dv / l * HW, du / l * HW
												local i1 = vert(world({a[1] + nu, a[2] + nv_}))
												local i2 = vert(world({b[1] + nu, b[2] + nv_}))
												local i3 = vert(world({b[1] - nu, b[2] - nv_}))
												local i4 = vert(world({a[1] - nu, a[2] - nv_}))
												faces[#faces + 1] = ("f %d/1 %d/1 %d/1 %d/1"):format(i1, i2, i3, i4)
											end
										end
									end
								end
							end
						end
					end
				end
			end
			vi = vi + 1
		end
	end end
	if #faces == 0 then return nil, 0 end
	return table.concat(verts, "\n") .. "\nvt 0.5 0.5\n" .. table.concat(faces, "\n") .. "\n", #faces
end

local function remove_block(key)
	local b = blocks[key]
	if b and b.obj then
		local le = b.obj:get_luaentity()
		if le then le.rm_key = nil end
		b.obj:remove()
	end
	blocks[key] = nil
end

local function rebuild(bx, by, bz)
	local key = bkey(bx, by, bz)
	local b = blocks[key] or {}
	blocks[key] = b
	b.dirty = false
	b.bx, b.by, b.bz = bx, by, bz
	b.built = core.get_us_time()
	local obj_text, n = build_mesh(bx, by, bz)
	if not obj_text then
		if b.obj then b.obj:remove(); b.obj = nil end
		return
	end
	serial = serial + 1
	local name = ("rockmech_jm_%s_%d.obj"):format(key:gsub("-", "m"):gsub(",", "_"), serial)
	b.pending = name
	-- 寫到世界資料夾的暫存目錄，再以檔案路徑加入（非 ephemeral：伺服器執行期間檔案不可刪，下次啟動時清掉）
	local path = media_dir .. DIR_DELIM .. name
	local fh = io.open(path, "wb")
	if not fh then core.log("warning", "[rockmech] 節理網格無法寫入 " .. path); return end
	fh:write(obj_text)
	fh:close()
	local ok = core.dynamic_add_media({filepath = path}, function()
		if blocks[key] ~= b or b.pending ~= name then return end
		local pos = {x = bx * 16, y = by * 16, z = bz * 16}
		if not (b.obj and b.obj:get_pos()) then
			b.obj = core.add_entity(pos, ENT)
			if not b.obj then return end
			b.obj:get_luaentity().rm_key = key
		end
		b.obj:set_properties({mesh = name, is_visible = true})
		if DEBUG and b.dirty_at then
			core.log("action", ("[rockmech] 節理網格 %s：改變 → 送達 %.0f ms"):format(key,
				(core.get_us_time() - b.dirty_at) / 1000))
		end
		b.dirty_at = nil
	end)
	if not ok then core.log("warning", "[rockmech] 節理網格無法加入媒體 " .. name) end
end

-- 標記某位置所在的區塊（以及位在區塊邊界時的相鄰區塊）需要重建
function api.dirty(pos)
	local p = vector.round(pos)
	for dx = -1, 1 do for dy = -1, 1 do for dz = -1, 1 do
		local q = {x = p.x + dx, y = p.y + dy, z = p.z + dz}
		local b = blocks[bkey(math.floor(q.x / 16), math.floor(q.y / 16), math.floor(q.z / 16))]
		if b then
			b.dirty = true
			if DEBUG and not b.dirty_at then b.dirty_at = core.get_us_time() end
		end
	end end end
end
function api.dirty_box(a, b)
	for x = math.floor(a.x / 16) - 1, math.floor(b.x / 16) + 1 do
		for y = math.floor(a.y / 16) - 1, math.floor(b.y / 16) + 1 do
			for z = math.floor(a.z / 16) - 1, math.floor(b.z / 16) + 1 do
				local bl = blocks[bkey(x, y, z)]
				if bl then bl.dirty = true end
			end
		end
	end
end

-- 單格改變（挖掘、放置、物理移除／換成碎石）→ 標記
for _, fname in ipairs({"set_node", "swap_node", "remove_node", "add_node"}) do
	local orig = core[fname]
	core[fname] = function(pos, ...)
		local r = orig(pos, ...)
		if pos then api.dirty(pos) end
		return r
	end
end

-- 地形改變的區塊：每 0.05 s 優先重建（舊網格在新網格送達前仍會顯示，所以要快）
local dirty_timer = 0
core.register_globalstep(function(dtime)
	dirty_timer = dirty_timer + dtime
	if dirty_timer < 0.05 then return end
	dirty_timer = 0
	local now = core.get_us_time()
	local n = 0
	for _, b in pairs(blocks) do
		if b.dirty and b.bx and (now - (b.built or 0)) / 1e6 >= MIN_GAP then
			rebuild(b.bx, b.by, b.bz)
			n = n + 1
			if n >= DIRTY_STEP then break end
		end
	end
end)

-- 玩家附近的區塊：缺的建、遠的刪（每 0.5 s 最多 PER_STEP 個，由近到遠）
local timer = 0
core.register_globalstep(function(dtime)
	timer = timer + dtime
	if timer < 0.5 then return end
	timer = 0
	local want = {}
	local todo = {}
	for _, player in ipairs(core.get_connected_players()) do
		local pp = player:get_pos()
		local pb = {x = math.floor(pp.x / 16), y = math.floor(pp.y / 16), z = math.floor(pp.z / 16)}
		for bx = pb.x - RANGE, pb.x + RANGE do
			for by = pb.y - VRANGE, pb.y + VRANGE do
				for bz = pb.z - RANGE, pb.z + RANGE do
					local key = bkey(bx, by, bz)
					if not want[key] then
						want[key] = true
						local b = blocks[key]
						if not b then
							local d = (bx - pb.x) ^ 2 + (by - pb.y) ^ 2 + (bz - pb.z) ^ 2
							todo[#todo + 1] = {bx, by, bz, d}
						end
					end
				end
			end
		end
	end
	for key in pairs(blocks) do
		if not want[key] then remove_block(key) end
	end
	table.sort(todo, function(a, b) return a[4] < b[4] end)
	for i = 1, math.min(PER_STEP, #todo) do
		local t = todo[i]
		rebuild(t[1], t[2], t[3])
	end
end)

core.register_on_leaveplayer(function()
	if #core.get_connected_players() <= 1 then
		for key in pairs(blocks) do remove_block(key) end
	end
end)

api.build_mesh = build_mesh
