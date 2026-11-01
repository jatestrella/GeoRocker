-- 合成岩石破裂音效，輸出 sounds/rockmech_crack.<n>.ogg（單聲道：Luanti 的定位音效只對單聲道有效）。
-- 遊戲不會載入這個檔案。在 rockmech 目錄下執行：lua devtools/synth_sounds.lua [原始 PCM 輸出目錄]
--
-- 聲音：主破裂（幾個高頻阻尼模態 + 極短的雜訊 + 低頻的岩體悶響），接著一串微破裂
-- （發生率隨時間 ∝ 1/(t + c) 衰減，Omori 餘震律），再過一段短的地下迴響。
--
-- 編碼器：只用 Vorbis 規格裡最簡單的組合 —— 固定區塊 256、平坦的 floor 1（只有兩個端點）、
-- residue type 1，每個 MDCT 係數用一本由這個檔案的統計做出來的 Huffman 碼書。

local RATE = 44100
local N, M = 256, 128          -- 區塊長度、每區塊的係數數
local STEP = 0.0004            -- 量化步距（對滿刻度）；越小越準、檔案越大
local PART = 16                -- residue 分區大小
local MAXQ = 127               -- 量化值 ±MAXQ

---------------------------------------------------------------------------
-- 合成
---------------------------------------------------------------------------

local function damped(buf, i0, f, tau, amp)
	local n = math.floor(math.min(#buf - i0, tau * 8 * RATE))
	local w, d = 2 * math.pi * f / RATE, math.exp(-1 / (tau * RATE))
	local e = amp
	for i = 1, n do
		buf[i0 + i] = buf[i0 + i] + e * math.sin(w * i)
		e = e * d
	end
end

local function noise_burst(buf, i0, tau, amp)
	local n = math.floor(math.min(#buf - i0, tau * 8 * RATE))
	local d = math.exp(-1 / (tau * RATE))
	local e = amp
	for i = 1, n do
		buf[i0 + i] = buf[i0 + i] + e * (2 * math.random() - 1)
		e = e * d
	end
end

local function log_uniform(a, b) return a * (b / a) ^ math.random() end

-- 一次破裂：amp 大小；band = {f1, f2} 模態頻帶；body = 低頻悶響的比例
local function crack(buf, t, amp, band, body)
	local i0 = math.floor(t * RATE)
	if i0 >= #buf then return end
	noise_burst(buf, i0, 0.0012, amp * 0.9)
	for _ = 1, 5 do
		damped(buf, i0, log_uniform(band[1], band[2]), log_uniform(0.003, 0.012), amp * (0.2 + 0.25 * math.random()))
	end
	if body > 0 then damped(buf, i0, log_uniform(85, 190), log_uniform(0.025, 0.055), amp * body) end
end

-- 碎屑的沙沙聲：帶通雜訊，指數衰減
local function grit(buf, t, tau, amp)
	local i0 = math.floor(t * RATE)
	local n = #buf - i0
	local lp, slow, e = 0, 0, amp
	local d = math.exp(-1 / (tau * RATE))
	for i = 1, n do
		local x = 2 * math.random() - 1
		lp = lp + 0.45 * (x - lp)
		slow = slow + 0.03 * (lp - slow)
		buf[i0 + i] = buf[i0 + i] + e * (lp - slow)
		e = e * d
	end
end

local function reverb(buf)
	local taps = {{0.023, 0.22}, {0.031, 0.18}, {0.041, 0.15}, {0.053, 0.12}}
	for _, t in ipairs(taps) do t[1] = math.floor(t[1] * RATE) end
	for i = 1, #buf do
		local s = buf[i]
		for _, t in ipairs(taps) do
			local j = i - t[1]
			if j >= 1 then s = s + t[2] * buf[j] end
		end
		buf[i] = s
	end
end

local function render(v)
	math.randomseed(v.seed)
	local buf = {}
	for i = 1, math.floor(v.len * RATE) do buf[i] = 0 end
	for _, e in ipairs(v.main) do crack(buf, e[1], e[2], v.band, v.body) end
	local c, T = 0.015, v.len * 0.75
	for _ = 1, v.micro do
		local t = c * ((1 + T / c) ^ math.random() - 1)
		crack(buf, 0.004 + t, 0.32 * math.random() ^ 2 * math.exp(-t / T), v.band, v.body * 0.3)
	end
	grit(buf, 0.002, 0.14, 0.05)
	reverb(buf)
	local fade = math.floor(0.2 * RATE)
	for i = 1, fade do buf[#buf - i + 1] = buf[#buf - i + 1] * ((i - 1) / fade) ^ 2 end
	local peak = 0
	for i = 1, #buf do peak = math.max(peak, math.abs(buf[i])) end
	for i = 1, #buf do buf[i] = buf[i] / peak * 0.85 end
	return buf
end

local VARIANTS = {
	{seed = 11, len = 0.8, band = {1100, 5200}, body = 0.5, micro = 8, main = {{0, 1}}},           -- 單聲脆裂
	{seed = 23, len = 1.2, band = {900, 4600}, body = 0.4, micro = 32, main = {{0, 0.8}}},         -- 破裂接一串細碎聲
	{seed = 37, len = 0.9, band = {700, 3600}, body = 0.7, micro = 14, main = {{0, 0.9}, {0.17, 0.6}}}, -- 連續兩聲
	{seed = 53, len = 1.1, band = {500, 2800}, body = 1.0, micro = 18, main = {{0, 1}}},           -- 低沉的悶裂
}

---------------------------------------------------------------------------
-- Vorbis 編碼
---------------------------------------------------------------------------

local function bitwriter()
	local bytes, cur, nbits = {}, 0, 0
	local w = {}
	function w.put(v, n)
		for b = 0, n - 1 do
			cur = cur | (((v >> b) & 1) << nbits)
			nbits = nbits + 1
			if nbits == 8 then bytes[#bytes + 1] = string.char(cur); cur, nbits = 0, 0 end
		end
	end
	function w.done()
		if nbits > 0 then bytes[#bytes + 1] = string.char(cur); cur, nbits = 0, 0 end
		return table.concat(bytes)
	end
	return w
end

local function ilog(v)
	local n = 0
	while v > 0 do n, v = n + 1, v >> 1 end
	return n
end

local RATIO = 1.0649863        -- floor1_inverse_dB_table[y] = RATIO^(y − 255)
local function floor_value(y) return RATIO ^ (y - 255) end

local WIN, BASIS = {}, {}
for i = 0, N - 1 do
	WIN[i] = math.sin(math.pi / 2 * math.sin((i + 0.5) * math.pi / N) ^ 2)
end
for k = 0, M - 1 do
	local b = {}
	for i = 0, N - 1 do b[i] = math.cos(2 * math.pi / N * (i + 0.5 + N / 4) * (k + 0.5)) end
	BASIS[k] = b
end

-- 各區塊量化後的係數 {y, q[0..M-1]}（y = nil 是全零區塊）
local function analyse(pcm)
	local L = #pcm
	local x = {}
	for i = 0, M - 1 do x[i] = 0 end
	for i = 1, L do x[M + i - 1] = pcm[i] end
	local packets = math.ceil(L / M) + 1
	for i = M + L, (packets + 1) * M do x[i] = 0 end
	local blocks = {}
	for b = 0, packets - 1 do
		local wx = {}
		for i = 0, N - 1 do wx[i] = WIN[i] * x[b * M + i] end
		local X, peak = {}, 0
		for k = 0, M - 1 do
			local s, B = 0, BASIS[k]
			for i = 0, N - 1 do s = s + wx[i] * B[i] end
			X[k] = s * 4 / N
			peak = math.max(peak, math.abs(X[k]))
		end
		local y = math.ceil(255 + math.log(math.max(STEP, peak / MAXQ)) / math.log(RATIO))
		y = math.max(0, math.min(255, y))
		local step, q, any = floor_value(y), {}, false
		for k = 0, M - 1 do
			q[k] = math.max(-MAXQ, math.min(MAXQ, math.floor(X[k] / step + 0.5)))
			any = any or q[k] ~= 0
		end
		blocks[#blocks + 1] = {y = any and y or nil, q = q}
	end
	return blocks
end

-- 每個值都要有碼字（非稀疏碼書），沒出現過的算 1 次
local function huffman_lengths(hist, n)
	local nodes = {}
	for i = 0, n - 1 do nodes[#nodes + 1] = {c = (hist[i] or 0) + 1, leaf = {i}} end
	local len = {}
	for i = 0, n - 1 do len[i] = 0 end
	while #nodes > 1 do
		table.sort(nodes, function(a, b) return a.c > b.c end)
		local a, b = table.remove(nodes), table.remove(nodes)
		local leaf = {}
		for _, l in ipairs({a.leaf, b.leaf}) do
			for _, i in ipairs(l) do len[i] = len[i] + 1; leaf[#leaf + 1] = i end
		end
		nodes[#nodes + 1] = {c = a.c + b.c, leaf = leaf}
	end
	return len
end

-- 規格的碼字分配（依序取最小的空葉）；同 libvorbis _make_words
local function codewords(len, n)
	local marker, out = {}, {}
	for j = 0, 33 do marker[j] = 0 end
	for i = 0, n - 1 do
		local length = len[i]
		local entry = marker[length]
		assert(length >= 32 or entry >> length == 0, "碼書過度指定")
		out[i] = entry
		for j = length, 1, -1 do
			if marker[j] & 1 == 1 then
				if j == 1 then marker[1] = marker[1] + 1 else marker[j] = marker[j - 1] << 1 end
				break
			end
			marker[j] = marker[j] + 1
		end
		for j = length + 1, 32 do
			if marker[j] >> 1 == entry then
				entry = marker[j]
				marker[j] = marker[j - 1] << 1
			else
				break
			end
		end
	end
	return out
end

local function put_codeword(w, code, length)
	for b = length - 1, 0, -1 do w.put((code >> b) & 1, 1) end
end

local function put_book_header(w, dim, len, entries)
	w.put(0x564342, 24)
	w.put(dim, 16)
	w.put(entries, 24)
	w.put(0, 1)     -- ordered
	w.put(0, 1)     -- sparse
	for i = 0, entries - 1 do w.put(len[i] - 1, 5) end
end

local function float32(sign, mantissa)  -- mantissa · 2^0
	return (sign << 31) | (788 << 21) | mantissa
end

local function headers(len, entries)
	local id = bitwriter()
	id.put(1, 8)
	for c in ("vorbis"):gmatch(".") do id.put(c:byte(), 8) end
	id.put(0, 32)
	id.put(1, 8)
	id.put(RATE, 32)
	id.put(0, 32); id.put(0, 32); id.put(0, 32)
	id.put(ilog(N - 1), 4)
	id.put(ilog(N - 1), 4)
	id.put(1, 1)

	local co = bitwriter()
	co.put(3, 8)
	for c in ("vorbis"):gmatch(".") do co.put(c:byte(), 8) end
	local vendor = "rockmech synth"
	co.put(#vendor, 32)
	for c in vendor:gmatch(".") do co.put(c:byte(), 8) end
	co.put(0, 32)
	co.put(1, 1)

	local s = bitwriter()
	s.put(5, 8)
	for c in ("vorbis"):gmatch(".") do s.put(c:byte(), 8) end
	s.put(1, 8)            -- 碼書 2 本
	-- 0：分區分類（0 = 全零、1 = 有值）
	put_book_header(s, 1, {[0] = 1, 1}, 2)
	s.put(0, 4)
	-- 1：係數，第 i 個碼字 = i − MAXQ
	put_book_header(s, 1, len, entries)
	s.put(1, 4)
	s.put(float32(1, MAXQ), 32)
	s.put(float32(0, 1), 32)
	s.put(7, 4)            -- 8 bits
	s.put(0, 1)
	for i = 0, entries - 1 do s.put(i, 8) end
	s.put(0, 6); s.put(0, 16)                 -- time
	-- floor 1：沒有分區，只有 x = 0 與 x = 2^rangebits 兩個端點
	s.put(0, 6); s.put(1, 16)
	s.put(0, 5)            -- partitions
	s.put(0, 2)            -- multiplier 1，range 256
	s.put(ilog(M - 1), 4)  -- rangebits
	-- residue 1
	s.put(0, 6); s.put(1, 16)
	s.put(0, 24); s.put(M, 24); s.put(PART - 1, 24)
	s.put(1, 6)            -- 2 類
	s.put(0, 8)            -- 分類碼書
	s.put(0, 3); s.put(0, 1)                  -- 第 0 類沒有碼書
	s.put(1, 3); s.put(0, 1)                  -- 第 1 類第 0 階用碼書 1
	s.put(1, 8)
	-- mapping 0
	s.put(0, 6); s.put(0, 16)
	s.put(0, 1); s.put(0, 1); s.put(0, 2)
	s.put(0, 8); s.put(0, 8); s.put(0, 8)
	-- mode
	s.put(0, 6)
	s.put(0, 1); s.put(0, 16); s.put(0, 16); s.put(0, 8)
	s.put(1, 1)
	return id.done(), co.done(), s.done()
end

local CRC = {}
for i = 0, 255 do
	local r = i << 24
	for _ = 1, 8 do
		r = (r & 0x80000000 ~= 0) and (((r << 1) ~ 0x04C11DB7) & 0xFFFFFFFF) or ((r << 1) & 0xFFFFFFFF)
	end
	CRC[i] = r
end

local function ogg_page(flags, granule, seq, packets)
	local lacing, body = {}, {}
	for _, p in ipairs(packets) do
		local n = #p
		while n >= 255 do lacing[#lacing + 1] = string.char(255); n = n - 255 end
		lacing[#lacing + 1] = string.char(n)
		body[#body + 1] = p
	end
	assert(#lacing <= 255)
	local head = "OggS\0" .. string.pack("<BI8I4I4I4B", flags, granule, 0x524D4348, seq, 0, #lacing) .. table.concat(lacing)
	local page = head .. table.concat(body)
	local crc = 0
	for i = 1, #page do crc = ((crc << 8) & 0xFFFFFFFF) ~ CRC[((crc >> 24) ~ page:byte(i)) & 0xFF] end
	return page:sub(1, 22) .. string.pack("<I4", crc) .. page:sub(27)
end

local function encode(pcm, path)
	local blocks = analyse(pcm)
	local entries = 2 * MAXQ + 1
	local hist = {}
	for _, b in ipairs(blocks) do
		if b.y then
			for p = 0, M / PART - 1 do
				local any = false
				for k = p * PART, p * PART + PART - 1 do any = any or b.q[k] ~= 0 end
				if any then
					for k = p * PART, p * PART + PART - 1 do
						local e = b.q[k] + MAXQ
						hist[e] = (hist[e] or 0) + 1
					end
				end
			end
		end
	end
	local len = huffman_lengths(hist, entries)
	local code = codewords(len, entries)

	local id, co, setup = headers(len, entries)
	local out = {ogg_page(2, 0, 0, {id}), ogg_page(0, 0, 1, {co, setup})}
	local seq, page, segs, done = 2, {}, 0, 0
	local function flush(eos, granule)
		out[#out + 1] = ogg_page(eos and 4 or 0, granule, seq, page)
		seq, page, segs = seq + 1, {}, 0
	end
	for i, b in ipairs(blocks) do
		local w = bitwriter()
		w.put(0, 1)
		if b.y then
			w.put(1, 1); w.put(b.y, 8); w.put(b.y, 8)
			for p = 0, M / PART - 1 do
				local any = false
				for k = p * PART, p * PART + PART - 1 do any = any or b.q[k] ~= 0 end
				w.put(any and 1 or 0, 1)     -- 分類碼書的兩個碼字長度都是 1
				if any then
					for k = p * PART, p * PART + PART - 1 do
						local e = b.q[k] + MAXQ
						put_codeword(w, code[e], len[e])
					end
				end
			end
		else
			w.put(0, 1)
		end
		local packet = w.done()
		local need = #packet // 255 + 1
		local last = i == #blocks
		if segs + need > 255 then flush(false, math.min(done, #pcm)) end
		page[#page + 1] = packet
		segs = segs + need
		done = (i - 1) * M
		if last then flush(true, #pcm) end
	end
	local f = assert(io.open(path, "wb"))
	f:write(table.concat(out))
	f:close()
	return #table.concat(out)
end

---------------------------------------------------------------------------

local raw_dir = arg and arg[1]
for i, v in ipairs(VARIANTS) do
	local pcm = render(v)
	local size = encode(pcm, ("sounds/rockmech_crack.%d.ogg"):format(i))
	print(("%d：%.2f 秒，%d bytes"):format(i, #pcm / RATE, size))
	if raw_dir then
		local f = assert(io.open(("%s/orig_%d.raw"):format(raw_dir, i), "wb"))
		for j = 1, #pcm do f:write(string.pack("<i2", math.floor(pcm[j] * 32767 + 0.5))) end
		f:close()
	end
end
