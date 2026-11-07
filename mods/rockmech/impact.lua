-- rockmech/impact.lua
-- 落石傷害：翻滾的落石（rockfall）、整塊落下或滑動的岩塊（rigid_block）、單格掉落（__builtin:falling_node）
-- 砸到人或車時，依動能 E = ½ m v² 算傷害（m：一格 1 m³ 的質量 = γ / g，γ 用岩性的單位重）。
--   人：每 HP_KJ kJ 扣 1 點血，一次最多 HP_MAX 點（20 = 滿血）；開了 /god（immortal）不扣。
--   坐在車上的人：駕駛艙有防落物保護（FOPS），人不扣血，傷害算在車上。
--   車：耐久度 100%，每 kJ 扣 VEHICLE_KJ_PER_PCT 的倒數（100 kJ 扣到 0 報廢），見 vehicles.lua 的 V.damage。
--   速度低於 MIN_SPEED 不算（慢慢滾過來的碎石不傷人）；同一塊石頭對同一個目標 1 秒內只算一次。
-- 掩埋：岩石、碎石方塊設 drowning，頭被埋住就像溺水一樣耗氧，耗完扣血（Luanti 內建的呼吸機制）。
-- 傷害要伺服器開 enable_damage 才有效。

local S = rockmech.S
local G = 9.81
local HP_KJ, HP_MAX = 2, 20
local MIN_SPEED = 2.0       -- m/s
local HIT_R = 0.9           -- 石頭中心離人或車多近算砸到 (m)

local function mass_of(node_name)
	local lith = node_name and (rockmech.lith_of_node[node_name] or rockmech.lith_of_rubble and rockmech.lith_of_rubble[rockmech.rubble_base[node_name] or ""])
	local gamma = type(lith) == "table" and lith.gamma
		or (type(lith) == "string" and rockmech.cfg.lithologies[lith] and rockmech.cfg.lithologies[lith].gamma) or 25
	return gamma / G          -- t（1 m³）
end

local function key_of(o)
	if o:is_player() then return "p:" .. o:get_player_name() end
	local e = o:get_luaentity()
	return e and e.uid and ("v:" .. e.uid) or nil
end

-- pos 這一格以速度 v（向量）、質量 m（t）撞到附近的人或車；hits：這塊石頭打過誰（1 秒冷卻）
-- dtime：這一步的時間。石頭一步可以走 1 m 以上，判定範圍沿著它前進的方向延伸 speed × dtime，高速落下也打得到
function rockmech.impact_hit(pos, m, v, hits, now, dtime)
	local speed = math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
	if speed < MIN_SPEED then return end
	local reach = speed * (dtime or 0.1) + 0.3
	local kj = 0.5 * m * speed * speed         -- t·(m/s)² = kJ
	for _, o in ipairs(core.get_objects_inside_radius(pos, HIT_R + 2.5 + reach)) do
		local op = o:get_pos()
		local target, key
		if o:is_player() then
			-- 玩家的身體從腳到頭約 1.7 m：石頭中心在這段高度、水平距離 HIT_R 內才算
			if pos.y >= op.y - 0.3 and pos.y <= op.y + 2.0 + reach and math.sqrt((pos.x - op.x) ^ 2 + (pos.z - op.z) ^ 2) <= HIT_R + reach * 0.3 then
				target = o
			end
		else
			local e = o:get_luaentity()
			if e and e.vkind then
				local d = rockmech.vehicles.TYPES[e.vkind]
				local half, top = d.half or 1, d.top or d.half or 1
				-- 車身（水平半寬 half）上方：石頭在車頂上 reach 以內、或已經在車身範圍內
				if math.sqrt((pos.x - op.x) ^ 2 + (pos.z - op.z) ^ 2) <= half + 0.5 and pos.y <= op.y + top + 0.5 + reach
						and pos.y >= op.y - half then
					target = o
				end
			end
		end
		if target then
			-- 坐在車上：算在車上（駕駛艙防落物）
			local parent = target:is_player() and target:get_attach()
			local pe = parent and parent:get_luaentity()
			if pe and pe.vkind then target = parent end
			key = key_of(target)
			if key and (not hits[key] or now - hits[key] > 1) then
				hits[key] = now
				if target:is_player() then
					local dmg = math.min(HP_MAX, math.floor(kj / HP_KJ))
					if dmg >= 1 and not target:get_armor_groups().immortal then
						target:set_hp(target:get_hp() - dmg, {type = "set_hp", from = "mod", rockmech = "rockfall"})
						core.chat_send_player(target:get_player_name(), S("[Rockfall] You were hit (@1 kJ) and lost @2 HP", ("%.0f"):format(kj), ("%d"):format(dmg)))
					end
				elseif rockmech.vehicles.damage then
					rockmech.vehicles.damage(target:get_luaentity(), kj)
				end
			end
		end
	end
end

-- 翻滾的落石
do
	local ent = core.registered_entities[rockmech.modname .. ":rockfall"]
	local step = ent.on_step
	ent.on_step = function(self, dtime, moveresult)
		step(self, dtime, moveresult)
		if self.node_name == "" or not self.object:get_pos() then return end
		self.rm_hits = self.rm_hits or {}
		self.rm_t = (self.rm_t or 0) + dtime
		rockmech.impact_hit(self.object:get_pos(), mass_of(self.node_name), self.object:get_velocity(), self.rm_hits, self.rm_t, dtime)
	end
end

-- 整塊落下、沿節理滑動的岩塊：每一格各自算（一格 1 m³）
do
	local ent = core.registered_entities[rockmech.modname .. ":rigid_block"]
	local step = ent.on_step
	ent.on_step = function(self, dtime, moveresult)
		local pos = self.object:get_pos()
		local v = self.object:get_velocity()
		if pos and self.cells and not self.restored then
			self.rm_hits = self.rm_hits or {}
			self.rm_t = (self.rm_t or 0) + dtime
			for _, c in ipairs(self.cells) do
				rockmech.impact_hit({x = pos.x + c.dx, y = pos.y + c.dy, z = pos.z + c.dz}, mass_of(c.name), v, self.rm_hits, self.rm_t, dtime)
			end
		end
		return step(self, dtime, moveresult)
	end
end

-- 單格掉落（崩落的岩石、碎石）
do
	local ent = core.registered_entities["__builtin:falling_node"]
	local step = ent.on_step
	ent.on_step = function(self, dtime, moveresult)
		local pos = self.object:get_pos()
		local name = self.node and self.node.name
		if pos and name and (rockmech.lith_of_node[name] or rockmech.is_rubble(name)) then
			self.rm_hits = self.rm_hits or {}
			self.rm_t = (self.rm_t or 0) + dtime
			-- 碎石不滿格：質量照級數
			local m = mass_of(name) * ((rockmech.rubble_level[name] or rockmech.RUBBLE_LEVELS) / rockmech.RUBBLE_LEVELS)
			rockmech.impact_hit(pos, m, self.object:get_velocity(), self.rm_hits, self.rm_t, dtime)
		end
		return step(self, dtime, moveresult)
	end
end

-- 掩埋：頭被岩石或碎石蓋住會窒息（像溺水一樣耗氧，耗完每 2 秒扣血）
core.register_on_mods_loaded(function()
	local n = 0
	for name, def in pairs(core.registered_nodes) do
		if (rockmech.lith_of_node[name] or rockmech.is_rubble(name)) and (def.drowning or 0) == 0 then
			core.override_item(name, {drowning = 1})
			n = n + 1
		end
	end
	core.log("action", ("[rockmech] 掩埋窒息：%d 種岩石、碎石方塊"):format(n))
end)
