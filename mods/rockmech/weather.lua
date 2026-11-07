-- rockmech/weather.lua
-- 降雨：老師用 /rain 下雨。下雨時鬆土的安息角暫時降低 rockmech_slope_rain_drop 度（collapse.lua granular_settle
-- 讀 rockmech.rain_tan），原本剛好穩住的鬆土坡會開始流，流動再拖動旁邊的表土（woodwork.lua），可能連成整片邊坡滑動。
-- 碎石（岩石碎塊）透水、不受影響。雨停馬上回到原本的安息角。
-- 畫面：每個玩家身邊下雨（粒子）、雲變厚變灰。雨的結束時間存在 mod storage，伺服器重開照樣下完

local store = core.get_mod_storage()
local cfg = rockmech.cfg.slope
local RAIN_TAN = math.tan(math.rad(math.max(1, cfg.angle - math.max(0, cfg.rain_drop))))
local DEFAULT_MIN = 10

local spawners = {}         -- 玩家名稱 → particlespawner id
local clouds = {}           -- 玩家名稱 → 下雨前的雲設定

local function rain_end() return store:get_int("rain_end") end
local function raining() return rain_end() > core.get_gametime() end
function rockmech.raining() return raining() end
-- 土佔 s（0..1）的碎石，下雨時的安息角 tan（沒下雨回傳 nil）：降低 rain_drop × s 度
function rockmech.rain_tan_for(s)
	if not rockmech.raining_now then return nil end
	return math.tan(math.rad(math.max(1, cfg.angle - math.max(0, cfg.rain_drop) * s)))
end

local function start_fx(player)
	local name = player:get_player_name()
	if spawners[name] then return end
	spawners[name] = core.add_particlespawner({
		amount = 400, time = 0, attached = player,
		minpos = {x = -12, y = 8, z = -12}, maxpos = {x = 12, y = 10, z = 12},
		minvel = {x = 0, y = -14, z = 0}, maxvel = {x = 0, y = -12, z = 0},
		minexptime = 0.8, maxexptime = 1.0, minsize = 0.8, maxsize = 1.2,
		collisiondetection = true, collision_removal = true, vertical = true,
		texture = "[fill:1x8:#a8c0e0b0", playername = name,
	})
	clouds[name] = clouds[name] or player:get_clouds()
	player:set_clouds({density = 0.9, color = "#8a9098f0", height = 90, thickness = 32})
end

local function stop_fx(player)
	local name = player:get_player_name()
	if spawners[name] then core.delete_particlespawner(spawners[name]); spawners[name] = nil end
	if clouds[name] then player:set_clouds(clouds[name]); clouds[name] = nil end
end

-- 狀態跟畫面同步（每 2 秒，加上 /rain 當下）
local was
local function sync()
	local on = raining()
	rockmech.rain_tan = on and RAIN_TAN or nil
	rockmech.raining_now = on
	for _, p in ipairs(core.get_connected_players()) do
		if on then start_fx(p) else stop_fx(p) end
	end
	if was ~= nil and was ~= on then
		core.chat_send_all(on and "開始下雨：鬆土的安息角暫時降低，邊坡要小心" or "雨停了")
	end
	was = on
end
local t = 0
core.register_globalstep(function(dtime)
	t = t + dtime
	if t < 2 then return end
	t = 0
	sync()
end)
core.register_on_joinplayer(function(player) if raining() then start_fx(player) end end)
core.register_on_leaveplayer(function(player)
	local name = player:get_player_name()
	spawners[name], clouds[name] = nil, nil       -- 粒子跟著玩家一起消失
end)

core.register_chatcommand("rain", {
	params = "[分鐘 | off]",
	description = ("下雨（預設 %d 分鐘）：鬆土安息角降低 %g°。/rain off 停雨，不加參數看現在的狀態"):format(DEFAULT_MIN, cfg.rain_drop),
	privs = {rockmech = true},
	func = function(name, param)
		param = (param or ""):trim()
		local now = core.get_gametime()
		if param == "" then
			if not raining() then return true, "沒有下雨" end
			return true, ("下雨中，還有 %.1f 分鐘"):format((rain_end() - now) / 60)
		end
		if param == "off" then
			store:set_int("rain_end", 0)
			sync()
			return true, "停雨"
		end
		local m = tonumber(param)
		if not m or m <= 0 then return false, "用法：/rain [分鐘 | off]" end
		store:set_int("rain_end", now + math.floor(m * 60))
		sync()
		return true, ("下雨 %g 分鐘：鬆土安息角 %g° → %g°"):format(m, cfg.angle, math.max(1, cfg.angle - cfg.rain_drop))
	end,
})
