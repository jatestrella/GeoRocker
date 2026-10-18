dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "helper.lua")
local granular = load_module("granular")

local TAN35 = math.tan(math.rad(35))

describe("granular 碎石顆粒流", function()
	it("表面高度：格 y 的 k 級碎石 = 8y − 4 + k；滿格實心頂面 = 8y + 4", function()
		assert.are.equal(-4 + 3, granular.surface(0, 3))
		assert.are.equal(4, granular.surface(0, 8))
		assert.are.equal(8 * 5 + 4, granular.surface(5, 8))
	end)

	it("由表面反推格與級數", function()
		for y = -3, 3 do
			for k = 1, 8 do
				local yy, kk = granular.cell_of_surface(granular.surface(y, k))
				assert.are.equal(y, yy)
				assert.are.equal(k, kk)
			end
		end
	end)

	it("坡度低於安息角不流", function()
		-- 落差 5/8 m、水平 1 m：tan = 0.625 < tan35 = 0.70
		local i = granular.choose_flow(10, 8, {{e = 5, d = 1}}, TAN35)
		assert.is_nil(i)
	end)

	it("超過安息角：流向超出最多的一側，流量為超出量的一半（取上整）", function()
		-- 鄰欄 A 落差 8（超出 8 − 5.6 = 2.4），鄰欄 B 落差 16（超出 10.4）
		local i, a = granular.choose_flow(16, 8, {{e = 8, d = 1}, {e = 0, d = 1}}, TAN35)
		assert.are.equal(2, i)
		assert.are.equal(math.ceil((16 - 8 * TAN35) / 2), a)
	end)

	it("流量不超過來源頂格的級數；擋住的方向不流", function()
		local i, a = granular.choose_flow(40, 3, {{e = nil, d = 1}, {e = 0, d = 1}}, TAN35)
		assert.are.equal(2, i)
		assert.are.equal(3, a)
	end)

	it("對角方向的臨界落差較大（√2 倍）", function()
		-- 落差 7：直向超出 7 − 5.6 = 1.4 → 流；對角 7 − 7.92 < 0 → 不流
		assert.is_true(granular.choose_flow(7, 8, {{e = 0, d = 1}}, TAN35) ~= nil)
		assert.is_nil(granular.choose_flow(7, 8, {{e = 0, d = math.sqrt(2)}}, TAN35))
	end)

	it("反覆流動後收斂到安息角以下", function()
		-- 一維：一堆 4 m 高的碎石（32 級）放在中央欄，兩側 6 欄平地
		local h = {}
		for x = -6, 6 do h[x] = 0 end
		h[0] = 32
		for _ = 1, 500 do
			local moved = false
			for x = -5, 5 do
				local nbs = {{e = h[x - 1], d = 1}, {e = h[x + 1], d = 1}}
				local i, a = granular.choose_flow(h[x], h[x], nbs, TAN35)
				if i then
					h[x] = h[x] - a
					local t = i == 1 and x - 1 or x + 1
					h[t] = h[t] + a
					moved = true
				end
			end
			if not moved then break end
		end
		local total = 0
		for x = -6, 6 do total = total + h[x] end
		assert.are.equal(32, total)   -- 體積守恆
		for x = -5, 5 do
			assert.is_true(math.abs(h[x] - h[x + 1]) < 8 * TAN35 + 1)
		end
	end)
end)
