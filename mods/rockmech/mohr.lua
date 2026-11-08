-- rockmech/mohr.lua
-- Mohr 圓（伺服器畫的 PNG，只傳給看的人）：準心旁的小圖（會「Mohr 圓分析」：只能考試學會）
--   指著的那一格，應力解的 σ1、σ3 一個圓，加上遊戲用的強度包絡線：完整岩石（虛線）、岩體（紅線，GSI、D）。
-- Hoek-Brown 換成 τ–σn 的包絡線：Balmaz 的參數式（Hoek 2002）
--   σ1 = σ3 + σci (mb σ3/σci + s)^a，dσ1/dσ3 = 1 + a mb (mb σ3/σci + s)^(a−1)
--   σn = (σ1+σ3)/2 − (σ1−σ3)/2 · (d−1)/(d+1)，τ = (σ1−σ3) √d / (d+1)

local M = {}
local floor, sqrt, max, min = math.floor, math.sqrt, math.max, math.min

-- 包絡線的點 {{σn, τ}...}，σ3 從張力強度到 s3max
function M.envelope(sigci, mb, s, a, s3max)
	local s3t = -s * sigci / mb
	local pts = {{s3t, 0}}
	for k = 1, 80 do
		local s3 = s3t + (s3max - s3t) * (k / 80) ^ 1.6
		local base = mb * s3 / sigci + s
		if base > 0 then
			local s1 = s3 + sigci * base ^ a
			local d = 1 + a * mb * base ^ (a - 1)
			pts[#pts + 1] = {(s1 + s3) / 2 - (s1 - s3) / 2 * (d - 1) / (d + 1), (s1 - s3) * sqrt(d) / (d + 1)}
		end
	end
	return pts
end
-- σ3 下的破壞 σ1
function M.s1_fail(sigci, mb, s, a, s3)
	local base = mb * s3 / sigci + s
	if base <= 0 then return s3 end
	return s3 + sigci * base ^ a
end

local function rgba(hex, al)
	hex = hex:gsub("#", "")
	return string.char(tonumber(hex:sub(1, 2), 16), tonumber(hex:sub(3, 4), 16), tonumber(hex:sub(5, 6), 16), al or 255)
end
local function nice(x)
	local e = 10 ^ floor(math.log10 and math.log10(x) or (math.log(x) / math.log(10)))
	local f = x / e
	return (f < 1.5 and 1 or f < 3.5 and 2 or f < 7.5 and 5 or 10) * e
end

-- 畫圖：opt = {w, h, circles = {{s1, s3, color}...}, envs = {{pts, color, dashed}...}, bg}
-- 回傳 png, axis = {x0（σ = 0 的像素）, y0（τ = 0 的像素）, k（像素/MPa）, step（格線 MPa）}
function M.draw(opt)
	local W, H = opt.w, opt.h
	local px = {}
	local bg = opt.bg or rgba("#ffffff")
	for i = 1, W * H do px[i] = bg end
	local function dot(x, y, col, r)
		x, y = floor(x + 0.5), floor(y + 0.5)
		r = r or 1
		for dy = -r + 1, r - 1 do for dx = -r + 1, r - 1 do
			local xx, yy = x + dx, y + dy
			if xx >= 0 and yy >= 0 and xx < W and yy < H and dx * dx + dy * dy < r * r then px[yy * W + xx + 1] = col end
		end end
	end
	-- 範圍：σ 從（張力強度、0）到最大 σ1 的 1.15 倍；τ 用同一個比例（圓才是圓）
	local smin, smax, tmax = 0, 1, 0.5
	for _, c in ipairs(opt.circles) do
		smin, smax = min(smin, c[2]), max(smax, c[1])
		tmax = max(tmax, (c[1] - c[2]) / 2)
	end
	local sx_max = smax
	for _, e in ipairs(opt.envs) do
		for _, p in ipairs(e.pts) do if p[1] <= sx_max * 1.15 then smin = min(smin, p[1]) end end
	end
	smin = max(smin, -0.3 * sx_max)          -- 完整岩石的張力端可能很遠：左邊最多留 σ1 的 30 %（超出的線裁掉）
	smax = smax * 1.15
	local span = smax - smin
	local mx, my = 0.06 * W, 0.08 * H
	local k = min((W - 2 * mx) / span, (H - 2 * my) / (tmax * 1.35))
	local x0 = mx - smin * k
	local y0 = H - my
	local function P(sn, tau) return x0 + sn * k, y0 - tau * k end
	-- 格線
	local step = nice(span / 6)
	local grid, axis = rgba("#dcdcdc"), rgba("#303030")
	for v = math.ceil(smin / step) * step, smax, step do
		local x = P(v, 0)
		for y = 0, H - 1 do dot(x, y, grid, 1) end
	end
	for v = step, (y0) / k, step do
		local _, y = P(0, v)
		for x = 0, W - 1 do dot(x, y, grid, 1) end
	end
	for x = 0, W - 1 do dot(x, y0, axis, 1) end
	for y = 0, H - 1 do dot(x0, y, axis, 1) end
	-- 包絡線
	for _, e in ipairs(opt.envs) do
		local col = rgba(e.color)
		for i = 2, #e.pts do
			local a, b = e.pts[i - 1], e.pts[i]
			local ax, ay = P(a[1], a[2])
			local bx, by = P(b[1], b[2])
			local n = max(1, floor(sqrt((bx - ax) ^ 2 + (by - ay) ^ 2)))
			for t = 0, n do
				local x, y = ax + (bx - ax) * t / n, ay + (by - ay) * t / n
				if not e.dashed or floor((x + y) / 6) % 2 == 0 then dot(x, y, col, 2) end
			end
		end
	end
	-- 圓（上半圓）
	for _, c in ipairs(opt.circles) do
		local col = rgba(c[3] or "#1f5fbf")
		local cx, r = (c[1] + c[2]) / 2, (c[1] - c[2]) / 2
		local n = max(60, floor(r * k * 3))
		for t = 0, n do
			local th = math.pi * t / n
			local x, y = P(cx + r * math.cos(th), r * math.sin(th))
			dot(x, y, col, c[4] or 2)
		end
	end
	return core.encode_png(W, H, table.concat(px)), {x0 = x0, y0 = y0, k = k, step = step, smin = smin, smax = smax}
end

-- 存成檔案、傳給玩家（暫時的），好了呼叫 cb(檔名)
local serial = 0
function M.send(name, png, cb)
	serial = serial + 1
	local fname = ("rockmech_mohr_%s_%d.png"):format(name:gsub("[^%w_]", "_"), serial)
	local dir = core.get_worldpath() .. "/rockmech_media"
	core.mkdir(dir)
	local path = dir .. "/" .. fname
	local fh = io.open(path, "wb")
	if not fh then return end
	fh:write(png)
	fh:close()
	core.dynamic_add_media({filepath = path, to_player = name, ephemeral = true}, function()
		cb(fname)
		core.after(30, function() os.remove(path) end)
	end)
end

M.COLOR = {circle = "#1f5fbf", intact = "#606060", mass = "#d03030"}
rockmech.mohr = M
