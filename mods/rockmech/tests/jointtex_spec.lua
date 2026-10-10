dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "helper.lua")
local joints = load_module("joints")
local jt = load_module("jointtex")

local function prep(t, seed)
	t.id = t.id or 1; t.name = t.name or "T"; t.phi = t.phi or 30
	return joints.prepare({t}, seed or 1)[1]
end

-- 從 alpha 圖找出每一欄 alpha 最大的列（線的位置）
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

describe("jointtex 跡線圖", function()
	local R, Q = 32, 8

	it("水平節理：側面為水平線，頂面平行不畫", function()
		local js = prep({dip = 0, dipdir = 0, spacing = 4, persistence = 1, offset = 0})
		local a = jt.face_line_alpha(js, jt.FACES[3], 4, Q, R, 1.5) -- +X 面、第 4 級（t = 0.5625）
		local rows = line_rows(a, R)
		for i = 0, R - 1 do assert.are.equal(rows[0], rows[i]) end
		-- t = 0.5625 → 從上方算 (1 − 0.5625)·32 = 14 列
		assert.truthy(math.abs(rows[0] - 14) <= 1)
		assert.is_nil(jt.face_line_alpha(js, jt.FACES[1], 4, Q, R, 1.5))
	end)

	it("向東傾 30°：南面上的跡線往東下降 30°", function()
		local js = prep({dip = 30, dipdir = 90, spacing = 4, persistence = 1})
		local a = jt.face_line_alpha(js, jt.FACES[6], 4, Q, R, 1.2) -- -Z（南）面：右 = +x、上 = +y
		local rows = line_rows(a, R)
		-- 取線上兩點算斜率（列往下增加 = 往下）
		local i1, i2 = 4, 27
		assert.is_not_nil(rows[i1]); assert.is_not_nil(rows[i2])
		local slope = (rows[i2] - rows[i1]) / (i2 - i1)
		assert.near(math.tan(math.rad(30)), slope, 0.06)
	end)

	it("向東傾的直立面（90°）：南面為垂直線", function()
		local js = prep({dip = 90, dipdir = 90, spacing = 3, persistence = 1})
		local a = jt.face_line_alpha(js, jt.FACES[6], 2, Q, R, 1.2)
		-- 每一列最亮的像素在同一欄
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

	it("同一平面在相鄰兩面交界處接得起來（頂面與南面共用的邊）", function()
		local js = prep({dip = 40, dipdir = 150, spacing = 4, persistence = 1})
		for b = 0, Q - 1 do
			local top = jt.face_line_alpha(js, jt.FACES[1], b, Q, R, 1.5)
			local south = jt.face_line_alpha(js, jt.FACES[6], b, Q, R, 1.5)
			if top and south then
				-- 頂面的下緣（u_z = 0）與南面的上緣（u_y = 1）是同一條邊，x 方向一致
				local function edge_peak(alpha, row)
					local best, bi = 0, nil
					for i = 0, R - 1 do
						if alpha[row * R + i + 1] > best then best, bi = alpha[row * R + i + 1], i end
					end
					return bi
				end
				local pt, ps = edge_peak(top, R - 1), edge_peak(south, 0)
				if pt and ps then assert.truthy(math.abs(pt - ps) <= 2, ("b=%d: %d vs %d"):format(b, pt, ps)) end
			end
		end
	end)
end)

describe("jointtex 每格跡線", function()
	local Q = 8

	it("水平組 offset 0：平面通過格中心 → 中間級，其他格沒有", function()
		local sets = {prep({dip = 0, dipdir = 0, spacing = 4, persistence = 1, offset = 0})}
		for y = -8, 8 do
			local tr = jt.cell_traces(joints, sets, 3, y, -2, Q, 2)
			if y % 4 == 0 then
				assert.are.equal(1, #tr)
				assert.truthy(tr[1].bin == 3 or tr[1].bin == 4)
			else
				assert.are.equal(0, #tr)
			end
		end
	end)

	it("延續性 0 時沒有跡線、1 時與幾何一致", function()
		local s0 = {prep({dip = 35, dipdir = 70, spacing = 3, persistence = 0})}
		local s1 = {prep({dip = 35, dipdir = 70, spacing = 3, persistence = 1})}
		local n1 = 0
		for x = -5, 5 do for y = -5, 5 do
			assert.are.equal(0, #jt.cell_traces(joints, s0, x, y, 0, Q, 2))
			n1 = n1 + #jt.cell_traces(joints, s1, x, y, 0, Q, 2)
		end end
		assert.truthy(n1 > 20)
	end)

	it("跡線與力學節理面一致：有跡線的格，至少一個面被同組判為節理（或只擦過格角）", function()
		local sets = joints.prepare({
			{id = 1, name = "A", dip = 30, dipdir = 90, spacing = 3, persistence = 0.6, phi = 30},
		}, 99)
		local with_face, total = 0, 0
		for x = -8, 8 do for y = -8, 8 do for z = -2, 2 do
			local tr = jt.cell_traces(joints, sets, x, y, z, Q, 2)
			if #tr > 0 then
				total = total + 1
				local m = joints.cell_mask(sets, x, y, z)
				if m > 0 then with_face = with_face + 1 end
			end
		end end end
		assert.truthy(total > 50)
		assert.truthy(with_face / total > 0.8, ("%d / %d"):format(with_face, total))
	end)

	it("組合數與命名唯一", function()
		local combos = jt.all_combos(3, Q, 2)
		assert.are.equal(1 + 3 * Q + 3 * Q * Q, #combos)
		local seen = {}
		for _, c in ipairs(combos) do
			local s = jt.suffix(c)
			assert.is_nil(seen[s]); seen[s] = true
		end
		assert.are.equal("", jt.suffix({}))
		assert.are.equal("_pa3c5", jt.suffix({{set = 1, bin = 3}, {set = 3, bin = 5}}))
	end)
end)
