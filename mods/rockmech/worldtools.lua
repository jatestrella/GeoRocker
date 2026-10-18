-- rockmech/worldtools.lua
-- 建構地形的指令（引擎端）：
--   /rockmech_slope [高度] [寬度] [深度] [坡角]
--     在玩家面前堆出一座岩山，正面朝向玩家（方向取最接近的東西南北），可以直接往前挖隧道。
--     岩性依該位置（rockmech.lith_at），節理依世界設定；堆出的岩石視為天然地形（不記為開挖，
--     「只算開挖造成的破壞」把它的初始狀態視為平衡）。
--     坡角 90 = 直立的正面；小於 90 時正面依坡角往後傾。

local cfg = rockmech.cfg

local DIRS = {
	{name = "北 (+z)", d = {0, 1}}, {name = "東 (+x)", d = {1, 0}},
	{name = "南 (−z)", d = {0, -1}}, {name = "西 (−x)", d = {-1, 0}},
}

-- 正面（朝向 −d）上會順向滑動的節理（Markland：傾向與正面外法向夾角 ≤ λ，且傾角 < 坡角、> φ）
local function daylighting_sets(face_dx, face_dz, angle)
	local out = {}
	local lim = math.cos(math.rad(cfg.weakness.lateral_limit))
	local phi = cfg.weakness.phi
	for _, js in ipairs(rockmech.get_joint_sets()) do
		local n = js.n_eff
		local h = math.sqrt(n.x * n.x + n.z * n.z)
		if h > 1e-6 and js.dip_eff < angle and js.dip_eff > phi
				and (n.x * face_dx + n.z * face_dz) / h >= lim then
			out[#out + 1] = ("%s（%.0f°/%.0f°）"):format(js.name, js.dip_eff, js.dipdir_eff)
		end
	end
	return out
end

core.register_chatcommand("rockmech_slope", {
	params = "[高度=24] [寬度=31] [深度=40] [坡角=90]",
	description = "在面前堆出一座岩山（正面朝向你），可以直接往前挖隧道",
	privs = {rockmech = true},
	func = function(name, param)
		local player = core.get_player_by_name(name)
		if not player then return false, "找不到玩家" end
		local args = {}
		for tok in (param or ""):gmatch("%S+") do args[#args + 1] = tonumber(tok) end
		local H = math.max(4, math.min(64, math.floor(args[1] or 24)))
		local Wd = math.max(5, math.min(81, math.floor(args[2] or 31)))
		local D = math.max(5, math.min(96, math.floor(args[3] or 40)))
		local ang = math.max(30, math.min(90, args[4] or 90))
		-- 面向：取最接近的軸向
		local yaw = player:get_look_horizontal()
		local lx, lz = -math.sin(yaw), math.cos(yaw)
		local dir = DIRS[1]
		for _, c in ipairs(DIRS) do
			if c.d[1] * lx + c.d[2] * lz > dir.d[1] * lx + dir.d[2] * lz then dir = c end
		end
		local dx, dz = dir.d[1], dir.d[2]
		local px, pz = math.floor(player:get_pos().x + 0.5), math.floor(player:get_pos().z + 0.5)
		local base = math.floor(player:get_pos().y + 0.5) - 1   -- 腳下那格
		-- 範圍：正面在玩家前方 4 格
		local half = math.floor(Wd / 2)
		local cells = {}
		local tan = ang < 90 and math.tan(math.rad(ang)) or math.huge
		local a = {x = math.huge, y = base - 3, z = math.huge}
		local b = {x = -math.huge, y = base + H, z = -math.huge}
		for s = 0, D - 1 do
			local hmax = math.min(H, math.floor((s + 0.5) * tan + 0.5))
			for t = -half, half do
				local x = px + dx * (4 + s) + (dz ~= 0 and t or 0)
				local z = pz + dz * (4 + s) + (dx ~= 0 and t or 0)
				cells[#cells + 1] = {x, z, hmax}
				a.x = math.min(a.x, x); a.z = math.min(a.z, z)
				b.x = math.max(b.x, x); b.z = math.max(b.z, z)
			end
		end
		local vm = core.get_voxel_manip()
		local e1, e2 = vm:read_from_map(a, b)
		local area = VoxelArea(e1, e2)
		local data = vm:get_data()
		local cid_cache = {}
		local function cid(n)
			local c = cid_cache[n]
			if not c then c = core.get_content_id(n); cid_cache[n] = c end
			return c
		end
		local n = 0
		for _, c in ipairs(cells) do
			local x, z, hmax = c[1], c[2], c[3]
			for y = base - 3, base + hmax do
				local vi = area:index(x, y, z)
				local nn = core.get_name_from_content_id(data[vi])
				local def = core.registered_nodes[nn]
				-- 只填空氣與非實心（不覆蓋既有的岩石）
				if not def or def.walkable == false or rockmech.is_rubble(nn) then
					local lith = rockmech.lith_at(x, y, z)
					data[vi] = cid(rockmech.joint_variant_for(lith.name, {x = x, y = y, z = z}))
					n = n + 1
				end
			end
		end
		vm:set_data(data)
		vm:write_to_map(true)
		vm:close()
		if rockmech.jointmesh then rockmech.jointmesh.dirty_box(a, b) end
		local warn = daylighting_sets(-dx, -dz, ang)
		core.log("action", ("[rockmech] %s 建岩山：往 %s 挖進山、高 %d、寬 %d、深 %d、坡角 %g°，填入 %d 格"):format(
			name, dir.name, H, Wd, D, ang, n))
		return true, ("已在前方建好岩山：高 %d m、寬 %d m、深 %d m、正面坡角 %g°，往 %s 挖就是進山。%s"):format(
			H, Wd, D, ang, dir.name,
			#warn > 0 and ("注意：正面有順向的節理 " .. table.concat(warn, "、") .. "，正面可能會滑。")
				or "正面沒有順向的節理。")
	end,
})
