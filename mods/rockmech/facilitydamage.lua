-- rockmech/facilitydamage.lua
-- 設施的耐久度（破碎站、大型破碎站、選礦場、裝車料斗、受料斗）：一整座共用一條血，記在控制方塊的 meta（fdmg = 損傷 %）。
--   爆炸（tnt.lua 的 on_blast）碰到設施的方塊：不移除方塊，改成扣整座的血：每被炸到 1 格 HIT %，一次爆炸最多 CAP %。
--   損傷到 25／50／75 % 時，設施地面上的部分外面套一層裂紋（三段越來越密，用挖礦的裂紋圖）。
--   損傷 100 %：整座倒塌消失（拆掉控制方塊，裡面的料也沒了）。
--   修理：研究帳篷的機械技工（research.lua）跟修車一樣派人來修；受損的設施記在 mod storage fdmg:<位置>
--   指著設施任何一格：準心右上的資訊泡泡顯示耐久度（ui.lua 呼叫 rockmech.facility_info）。

local S = rockmech.S
local storage = rockmech.collapse.storage

local HIT, CAP = 10, 60
local SHELL = "rockmech:crack_shell"
local CONTROLS = {
	["rockmech:crusher"] = true, ["rockmech:crusher_big"] = true, ["rockmech:plant"] = true,
	["rockmech:loadout"] = true, ["rockmech:dump_hopper"] = true, ["rockmech:dump_hopper_big"] = true,
}
local CTRL_LIST = {}
for n in pairs(CONTROLS) do CTRL_LIST[#CTRL_LIST + 1] = n end
local FIND_R = 12            -- 炸到的方塊離控制方塊多遠以內算同一座
local PART = {}              -- 設施的方塊名稱（mods 載入完才收集）

local function key_of(pos) return "fdmg:" .. core.pos_to_string(pos) end
local function dmg_of(pos) return core.get_meta(pos):get_float("fdmg") end

-- 這一格屬於哪一座設施：回傳控制方塊的位置（離最近的那座）
local function control_of(pos)
	if CONTROLS[core.get_node(pos).name] then return pos end
	local best, bd
	for _, c in ipairs(core.find_nodes_in_area(vector.subtract(pos, FIND_R), vector.add(pos, FIND_R), CTRL_LIST)) do
		local d = vector.distance(c, pos)
		if not bd or d < bd then best, bd = c, d end
	end
	return best
end

-- 設施地面上的部分（套裂紋的範圍）：回傳 中心, 大小
local function bounds(pos)
	local name = core.get_node(pos).name
	if name == "rockmech:dump_hopper" then
		return {x = pos.x + 0.5, y = pos.y + 0.5, z = pos.z + 0.5}, {x = 4, y = 2, z = 4}
	elseif name == "rockmech:dump_hopper_big" then
		return {x = pos.x + 0.5, y = pos.y + 0.5, z = pos.z + 0.5}, {x = 6, y = 2, z = 6}
	elseif name == "rockmech:loadout" then
		return {x = pos.x, y = pos.y + 2, z = pos.z}, {x = 3, y = 5, z = 3}
	end
	-- 破碎站、選礦場：控制方塊的 node box（轉向用最大的半寬，正方形）
	local def = core.registered_nodes[name]
	local nb = def and def.node_box and def.node_box.fixed
	local h, y0, y1 = 0.5, -0.5, 0.5
	if type(nb) == "table" then
		local boxes = type(nb[1]) == "table" and nb or {nb}
		for _, b in ipairs(boxes) do
			h = math.max(h, math.abs(b[1]), math.abs(b[3]), math.abs(b[4]), math.abs(b[6]))
			y0, y1 = math.min(y0, b[2]), math.max(y1, b[5])
		end
	end
	return {x = pos.x, y = pos.y + (y0 + y1) / 2, z = pos.z}, {x = 2 * h, y = y1 - y0, z = 2 * h}
end

-- 裂紋外殼：貼著挖礦裂紋圖（每 1 m 一格，跳脫過放進 [combine）
core.register_entity(SHELL, {
	initial_properties = {
		visual = "cube", textures = {"blank.png"}, use_texture_alpha = true, backface_culling = false,
		physical = false, pointable = false, static_save = false, collisionbox = {0, 0, 0, 0, 0, 0},
	},
	on_step = function(self, dtime)
		self.t = (self.t or 0) + dtime
		if self.t < 2 then return end
		self.t = 0
		-- 設施沒了、或修好了：自己消失
		if not self.ctrl or not CONTROLS[core.get_node(self.ctrl).name] or dmg_of(self.ctrl) < 25 then self.object:remove() end
	end,
})
local function face_tex(w, h, frame)
	local tile = ("crack_anylength.png^[verticalframe:5:%d"):format(frame):gsub("%^", "\\^"):gsub(":", "\\:")
	local t = {("[combine:%dx%d"):format(w * 16, h * 16)}
	for i = 0, w - 1 do for j = 0, h - 1 do t[#t + 1] = (":%d,%d=%s"):format(i * 16, j * 16, tile) end end
	return table.concat(t)
end
local function stage_of(dmg) return dmg >= 75 and 3 or dmg >= 50 and 2 or dmg >= 25 and 1 or 0 end
local function find_shell(pos)
	local c = bounds(pos)
	for _, o in ipairs(core.get_objects_inside_radius(c, 8)) do
		local e = o:get_luaentity()
		if e and e.name == SHELL and e.ctrl and vector.equals(e.ctrl, pos) then return o, e end
	end
end
local function update_shell(pos)
	local st = stage_of(dmg_of(pos))
	local o, e = find_shell(pos)
	if st == 0 then
		if o then o:remove() end
		return
	end
	if e and e.stage == st then return end
	local c, sz = bounds(pos)
	if not o then
		o = core.add_entity(c, SHELL)
		if not o then return end
		e = o:get_luaentity()
		e.ctrl = vector.copy(pos)
	end
	e.stage = st
	local frame = ({1, 2, 4})[st]
	local W, H, D = math.max(1, math.ceil(sz.x)), math.max(1, math.ceil(sz.y)), math.max(1, math.ceil(sz.z))
	local top, side_x, side_z = face_tex(W, D, frame), face_tex(D, H, frame), face_tex(W, H, frame)
	o:set_properties({visual_size = {x = sz.x + 0.04, y = sz.y + 0.04, z = sz.z + 0.04},
		textures = {top, top, side_x, side_x, side_z, side_z}})
end
rockmech.facility_update_shell = update_shell

local function label_of(name)
	local d = core.registered_nodes[name]
	return d and (d.short_description or rockmech.desc_short(d)) or name
end

-- 倒塌：拆掉控制方塊（各設施的 on_destruct 會拆掉整座），一陣塵土
local function collapse_facility(pos)
	local name = core.get_node(pos).name
	local owner = core.get_meta(pos):get_string("owner")
	storage:set_string(key_of(pos), "")
	local c, sz = bounds(pos)
	core.add_particlespawner({amount = 80, time = 1.0,
		minpos = vector.subtract(c, vector.divide(sz, 2)), maxpos = vector.add(c, vector.divide(sz, 2)),
		minvel = {x = -2, y = 0, z = -2}, maxvel = {x = 2, y = 3, z = 2}, minacc = {x = 0, y = -9, z = 0}, maxacc = {x = 0, y = -9, z = 0},
		minexptime = 0.8, maxexptime = 1.8, minsize = 3, maxsize = 6, texture = "[fill:4x4:#6a6458"})
	core.remove_node(pos)
	local o = find_shell(pos)
	if o then o:remove() end
	if owner ~= "" and rockmech.account_members then
		for _, m in ipairs(rockmech.account_members(owner)) do
			rockmech.notify(m, S("@1 was destroyed by the blast", label_of(name)))
		end
	end
	core.log("action", ("[rockmech] 設施 %s %s 被炸毀"):format(name, core.pos_to_string(pos)))
end

-- 扣血（%）
function rockmech.facility_damage(pos, amount)
	if not CONTROLS[core.get_node(pos).name] then return end
	local meta = core.get_meta(pos)
	local dmg = math.min(100, meta:get_float("fdmg") + amount)
	meta:set_float("fdmg", dmg)
	if dmg >= 100 then collapse_facility(pos); return end
	storage:set_string(key_of(pos), core.serialize({hp = 100 - dmg, owner = meta:get_string("owner"),
		kind = core.get_node(pos).name, pos = vector.copy(pos)}))
	update_shell(pos)
end
-- 修好（research.lua 的機械技工）
function rockmech.facility_repaired(pos)
	if CONTROLS[core.get_node(pos).name] then core.get_meta(pos):set_float("fdmg", 0) end
	storage:set_string(key_of(pos), "")
	update_shell(pos)
end
-- 指著設施的方塊：回傳一行說明（名稱、耐久度），不是設施回傳 nil
function rockmech.facility_info(pos, name)
	if not PART[name] then return nil end
	local c = control_of(pos)
	if not c then return nil end
	return S("@1  durability @2%", label_of(core.get_node(c).name), ("%d"):format(math.floor(100 - dmg_of(c) + 0.5)))
end

-- 爆炸：同一步裡被炸到的格子先記下來，下一步一起算（一次爆炸最多扣 CAP %）
local pending = {}
local function on_blast(pos)
	local c = control_of(pos)
	if not c then return {} end
	local k = core.pos_to_string(c)
	if not pending[k] then
		pending[k] = {pos = c, n = 0}
		core.after(0, function()
			local p = pending[k]
			pending[k] = nil
			if p then rockmech.facility_damage(p.pos, math.min(CAP, HIT * p.n)) end
		end)
	end
	pending[k].n = pending[k].n + 1
	return {}
end

-- 這個檔案在破碎站、選礦場、料斗之後載入，方塊都註冊好了；要在 tnt 建快取（mods 載入完）之前掛上 on_blast
for name in pairs(core.registered_nodes) do
	if CONTROLS[name] or name:find("^rockmech:hopper_lining") or name:find("^rockmech:crusher_grate")
			or name:find("^rockmech:plant") or name:find("^rockmech:loadout") or name:find("^rockmech:dump_hopper") then
		PART[name] = true
		core.override_item(name, {on_blast = on_blast})
	end
end

-- 重新載入後補上裂紋外殼
core.register_abm({
	label = "rockmech: 設施裂紋", nodenames = CTRL_LIST, interval = 10, chance = 1,
	action = function(pos) if dmg_of(pos) >= 25 then update_shell(pos) end end,
})
