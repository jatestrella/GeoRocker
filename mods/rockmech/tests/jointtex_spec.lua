dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "helper.lua")
local joints = load_module("joints")
local jt = load_module("jointtex")

local function prep(t, seed)
	t.id = t.id or 1; t.name = t.name or "T"; t.phi = t.phi or 30
	return joints.prepare({t}, seed or 1, 8)[1]
end

-- 每一欄 alpha 最大的列
local function line_rows(alpha, R)
	local rows = {}
	for i = 0, R - 1 do
		local best, bj = 0, nil
		for j = 0, R - 1 do
			local a = alpha[j * R + i + 1]
			if a > best then best, bj = a, j end
		end
		rows[i] = bj
	end
	return rows
end

-- 第 level 級的 t（m·u = t）
local function t_of(js, level)
	local first = 2 * (math.min(0, js.mx) + math.min(0, js.my) + math.min(0, js.mz))
	local sum = js.mx + js.my + js.mz
	first = first + ((sum % 2 == 0) and 2 or 1)
	return (first + 2 * level) / 2
end

describe("jointtex 跡線圖", function()
	local R = 32

	it("水平節理：側面為水平線，頂面平行不畫", function()
		local js = prep({dip = 0, dipdir = 0, spacing = 4, persistence = 1, offset = 0})
		assert.are.equal(7, jt.levels(js)) -- m = (0,8,0) → 2t ∈ {2,4,…,14}
		local a = jt.face_line_alpha(js, jt.FACES[3], 3, R, 1.5) -- +X 面、第 3 級（t = 4/8 = 0.5）
		local rows = line_rows(a, R)
		for i = 0, R - 1 do assert.are.equal(rows[0], rows[i]) end
		assert.truthy(math.abs(rows[0] - 15.5) <= 1)
		assert.is_nil(jt.face_line_alpha(js, jt.FACES[1], 3, R, 1.5))
	end)

	it("向東傾 30°：南面上的跡線往東下降約 30°", function()
		local js = prep({dip = 30, dipdir = 90, spacing = 4, persistence = 1})
		local a = jt.face_line_alpha(js, jt.FACES[6], 5, R, 1.2)
		local rows = line_rows(a, R)
		local pts = {}
		for i = 0, R - 1 do if rows[i] then pts[#pts + 1] = {i, rows[i]} end end
		assert.truthy(#pts > 10)
		local slope = (pts[#pts][2] - pts[1][2]) / (pts[#pts][1] - pts[1][1])
		assert.near(math.tan(math.rad(js.dip_eff)), slope, 0.08)
		assert.near(30, js.dip_eff, 1.5)
	end)

	it("向東傾的直立面（90°）：南面為垂直線", function()
		local js = prep({dip = 90, dipdir = 90, spacing = 3, persistence = 1})
		local a = jt.face_line_alpha(js, jt.FACES[6], 3, R, 1.2)
		local col
		for j = 0, R - 1 do
			local best, bi = 0, nil
			for i = 0, R - 1 do
				if a[j * R + i + 1] > best then best, bi = a[j * R + i + 1], i end
			end
			col = col or bi
			assert.are.equal(col, bi)
		end
	end)
end)

describe("jointtex 每格跡線", function()
	it("水平組 offset 0：平面通過格中心 → 中間級，其他格沒有", function()
		local sets = {prep({dip = 0, dipdir = 0, spacing = 4, persistence = 1, offset = 0})}
		for y = -8, 8 do
			local tr = jt.cell_traces(joints, sets, 3, y, -2, 2)
			if y % 4 == 0 then
				assert.are.equal(1, #tr)
				assert.are.equal(3, tr[1].level) -- t = 0.5，正中間
			else
				assert.are.equal(0, #tr)
			end
		end
	end)

	it("跨方塊完全連續：相鄰兩格在共用的垂直邊上，跡線高度相同", function()
		-- 南面牆 z = 0：跡線為 m_x·u_x + m_y·u_y = t（u_z = 0）
		-- 格 (x,y) 右緣 u_x = 1 與右鄰格 (x+1,y) 左緣 u_x = 0 為同一條邊
		local js = prep({dip = 70, dipdir = 40, spacing = 3, persistence = 1})
		local sets = {js}
		local checked = 0
		for x = -10, 10 do for y = -10, 10 do
			local a = jt.cell_traces(joints, sets, x, y, 0, 1)
			local b = jt.cell_traces(joints, sets, x + 1, y, 0, 1)
			if #a == 1 and #b == 1 then
				local ua = (t_of(js, a[1].level) - js.mx * 1) / js.my -- 左格右緣的 u_y
				local ub = (t_of(js, b[1].level) - js.mx * 0) / js.my -- 右格左緣的 u_y
				if ua >= 0 and ua <= 1 and ub >= 0 and ub <= 1 then
					assert.near(ua, ub, 1e-9)
					checked = checked + 1
				end
			end
		end end
		assert.truthy(checked > 10, "checked " .. checked)
	end)

	it("延續性 0 時沒有跡線、1 時有", function()
		local s0 = {prep({dip = 35, dipdir = 70, spacing = 3, persistence = 0})}
		local s1 = {prep({dip = 35, dipdir = 70, spacing = 3, persistence = 1})}
		local n1 = 0
		for x = -5, 5 do for y = -5, 5 do
			assert.are.equal(0, #jt.cell_traces(joints, s0, x, y, 0, 2))
			n1 = n1 + #jt.cell_traces(joints, s1, x, y, 0, 2)
		end end
		assert.truthy(n1 > 20)
	end)

	it("跡線與力學節理面一致", function()
		local sets = joints.prepare({
			{id = 1, name = "A", dip = 30, dipdir = 90, spacing = 3, persistence = 0.6, phi = 30},
		}, 99, 8)
		local with_face, total = 0, 0
		for x = -8, 8 do for y = -8, 8 do for z = -2, 2 do
			if #jt.cell_traces(joints, sets, x, y, z, 2) > 0 then
				total = total + 1
				if joints.cell_mask(sets, x, y, z) > 0 then with_face = with_face + 1 end
			end
		end end end
		assert.truthy(total > 50)
		assert.truthy(with_face / total > 0.8, ("%d / %d"):format(with_face, total))
	end)

	it("組合數與命名唯一", function()
		local combos = jt.all_combos({3, 4, 2}, 2)
		assert.are.equal(1 + (3 + 4 + 2) + (3 * 4 + 3 * 2 + 4 * 2), #combos)
		local seen = {}
		for _, c in ipairs(combos) do
			local s = jt.suffix(c)
			assert.is_nil(seen[s]); seen[s] = true
		end
		assert.are.equal("_pa3c5", jt.suffix({{set = 1, level = 3}, {set = 3, level = 5}}))
		assert.are.equal("_pa12b3", jt.suffix({{set = 1, level = 12}, {set = 2, level = 3}}))
	end)
end)
