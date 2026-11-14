-- rockmech/materials.lua
-- 材料表：每一種大地材料方塊（岩石、礦石、表土、鬆土、碎石、壓實碎石）用同一組參數描述，
-- 之後的應力解、破壞判定、地基承載都從這裡讀，不再各自寫死。
--
-- 參數（同一組欄位，用不到的留空）：
--   kind     "rock"（完整岩石，Hoek-Brown）或 "soil"（土類、鬆散材料，Mohr-Coulomb）
--   gamma    單位重 (kN/m³)
--   e_rel    勁度 / 岩石勁度（應力解的 E 只是數值尺度，相對值才有意義）
--   nu       帕松比
--   岩石：ucs、tensile (MPa，已除相似比 N)、mi、gsi（剖面在 rockmass.lua）
--   土類：c (kPa)、phi (°)、tensile (kPa，土取 0)
-- 預設值照材料種類（方塊名稱）給；個別方塊要不一樣時，寫在方塊 metadata 的 rm_mat（"c=10;phi=38"），
-- 只有跟預設不同的方塊才寫，其他方塊不佔儲存空間（跟 rm_assay 成分、param2 的 GSI 同一個做法）。
--
-- 用到的地方：femstress.lua（整格表土是應力解的土元素：γ、c、φ；鬆散材料的重量 γ）。

local cfg = rockmech.cfg
local S = rockmech.S
local M = {}

local META = "rm_mat"
local FIELDS = {gamma = true, e_rel = true, nu = true, ucs = true, tensile = true, mi = true, c = true, phi = true}

local function nscale() return cfg.model_scale or 1 end

-- 預設參數（每次呼叫都新建一份，呼叫端可以改）。強度跟岩石一樣除以相似比 N（rockmech_model_scale）；
-- 勁度：表土 rockmech_fem_soil_e（約 E 15 MPa ÷ 岩體 3–11 GPa；太硬的話岩石的變形會把土拉壞），
-- 鬆散材料 rockmech_fem_rubble_e
-- 張力強度取 Mohr-Coulomb 的頂點 c·cot φ（σt = 0 在數值上不適定：σ3 在 0 附近的正負號由收斂誤差決定）
local function soil(label, gamma, c, phi, e_rel)
	c = c / nscale()
	return {kind = "soil", label = label, gamma = gamma, e_rel = e_rel or cfg.fem.rubble_e, nu = cfg.fem.nu,
		c = c, phi = phi, tensile = c > 0 and c / math.tan(math.rad(phi)) or 0}
end
local DEFAULTS = {
	topsoil = function() return soil(S("Topsoil"), 18, cfg.topsoil_c, cfg.slope.phi_r, cfg.fem.soil_e) end,
	loose_soil = function() return soil(S("Loose soil"), 17, 0, cfg.slope.phi_r) end,
	rubble = function() return soil(S("Rubble"), 18, 0, cfg.slope.phi_r) end,
	compacted = function() return soil(S("Compacted rubble"), 20, 0, cfg.compact_phi) end,
}

-- 方塊名稱 → 材料種類（岩性的 key、或上面的土類）；不是大地材料回傳 nil
function M.kind_of(name)
	local lith = rockmech.lith_of_node[name]
	if lith then return "lith:" .. lith.name, lith end
	local def = core.registered_nodes[name]
	if def and def.groups and (def.groups.rockmech_topsoil or 0) > 0 then return "topsoil" end
	if rockmech.compacted and rockmech.compacted[name] then return "compacted" end
	if rockmech.rubble_level[name] then
		return rockmech.rubble_base[name] == rockmech.RUBBLE_SOIL and "loose_soil" or "rubble"
	end
	return nil
end

-- 材料種類的預設參數
function M.defaults(name)
	local key, lith = M.kind_of(name)
	if not key then return nil end
	if lith then
		return {kind = "rock", key = key, label = S(lith.description), gamma = lith.gamma, e_rel = 1, nu = cfg.fem.nu,
			ucs = lith.ucs / nscale(), tensile = (lith.tensile or 0) / nscale(), mi = lith.mi}
	end
	local p = DEFAULTS[key]()
	p.key = key
	return p
end

-- 某一格的參數：預設值，再套上這一格 metadata 的 rm_mat（有寫的欄位才蓋過去）
function M.at(pos, node)
	node = node or core.get_node(pos)
	local p = M.defaults(node.name)
	if not p then return nil end
	local s = core.get_meta(pos):get_string(META)
	if s ~= "" then
		for k, v in s:gmatch("([%w_]+)=([^;]+)") do
			if FIELDS[k] and tonumber(v) then p[k] = tonumber(v); p.custom = true end
		end
	end
	return p
end

-- 寫入這一格跟預設不同的參數（t = {c = 10, phi = 38}；值等於預設的欄位不寫，全部一樣就清掉）
function M.set(pos, t)
	local p = M.defaults(core.get_node(pos).name)
	if not p then return end
	local parts = {}
	for k, v in pairs(t) do
		if FIELDS[k] and math.abs((p[k] or 0) - v) > 1e-9 then parts[#parts + 1] = ("%s=%g"):format(k, v) end
	end
	table.sort(parts)
	core.get_meta(pos):set_string(META, table.concat(parts, ";"))
end

-- 顯示用的一行參數
function M.text(p)
	if p.kind == "rock" then
		return S("γ @1 kN/m³  σci @2 MPa  mi @3  σt @4 MPa",
			("%g"):format(p.gamma), ("%.3g"):format(p.ucs), ("%g"):format(p.mi or 0), ("%.2g"):format(p.tensile or 0))
	end
	return S("@1: γ @2 kN/m³  c @3 kPa  φ @4°", p.label, ("%g"):format(p.gamma), ("%g"):format(p.c), ("%g"):format(p.phi))
end

rockmech.materials = M
return M
