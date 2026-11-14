-- rockmech/init.lua
-- 只負責載入模組與最小的接線。純計算模組（config/joints/stress）不碰引擎 API；
-- 引擎相關的註冊放在 nodes.lua / tools.lua，地圖生成放在 mapgen.lua（於 mapgen 執行緒載入）。

local modname = core.get_current_modname()
local modpath = core.get_modpath(modname)

rockmech = {modname = modname, modpath = modpath}
-- 多語言：程式裡的原文是英文，翻譯在 locale/rockmech.<語言>.tr（zh_TW 是繁體中文）。玩家的 client 照自己的語言顯示。
-- 用法：S("Rain @1 mm/h", tostring(i))，參數用 @1..@9（數字先格式化成字串）。抽字串、檢查缺翻譯：tools/i18n.py
rockmech.S = core.get_translator(modname)
-- 物品的短名稱（HUD、清單用）：翻譯過的字串不能再 gsub 切第一行，註冊物品時給 short_description = S("短名稱")
function rockmech.desc_short(def)
	if type(def) == "string" then def = core.registered_items[def] end
	if not def then return "" end
	return def.short_description or def.description or ""
end

dofile(modpath .. "/notify.lua")       -- 遊戲訊息顯示在左下角（rockmech.notify）

-- 純模組
rockmech.config = dofile(modpath .. "/config.lua")
rockmech.joints = dofile(modpath .. "/joints.lua")
rockmech.dfn = dofile(modpath .. "/dfn.lua")
rockmech.stress = dofile(modpath .. "/stress.lua")
rockmech.jointtex = dofile(modpath .. "/jointtex.lua")
rockmech.failure = assert(loadfile(modpath .. "/failure.lua"))(rockmech.stress)
rockmech.rockfall = dofile(modpath .. "/rockfall.lua")
rockmech.stability = dofile(modpath .. "/stability.lua")
rockmech.support = dofile(modpath .. "/support.lua")
rockmech.fem = dofile(modpath .. "/fem.lua")
rockmech.rigidfall = dofile(modpath .. "/rigidfall.lua")
rockmech.overhang = dofile(modpath .. "/overhang.lua")
rockmech.keyblock = dofile(modpath .. "/keyblock.lua")
rockmech.granular = dofile(modpath .. "/granular.lua")
rockmech.blast = dofile(modpath .. "/blast.lua")
rockmech.airflow = dofile(modpath .. "/airflow.lua")   -- 空氣品質（純函式；引擎那邊在 airq.lua）
rockmech.rockmass = dofile(modpath .. "/rockmass.lua")
rockmech.copper = dofile(modpath .. "/copper.lua")     -- 銅（金屬礦）的選礦與計價（純函式）

-- 解析設定：世界資料夾的 rockmech.conf 優先於 minetest.conf（全域）
local world_conf_path = core.get_worldpath() .. "/rockmech.conf"
local world_conf = Settings(world_conf_path)
-- 世界資料夾裡的檔案（高程網格這類設定引用的資料）
local function read_world_file(name)
	local f = io.open(core.get_worldpath() .. "/" .. name, "rb")
	if not f then return nil end
	local s = f:read("*a")
	f:close()
	return s
end
rockmech.read_world_file = read_world_file
-- 地圖產生器：新世界（還沒有 rockmech.conf）第一次啟動時擲一套地質寫進去（worldgen.lua）
local worldgen = dofile(modpath .. "/worldgen.lua")
if worldgen.generate(world_conf) then world_conf = Settings(world_conf_path) end
local function get_setting(key)
	local v = world_conf:get(key)
	if v ~= nil and v ~= "" then return v end
	return core.settings:get(key)
end
local cfg, warnings = rockmech.config.load(get_setting, {read_file = read_world_file})
rockmech.cfg = cfg
for _, w in ipairs(warnings) do
	core.log("warning", "[rockmech] " .. w)
end

-- 世界第一次載入時，把決定節理幾何的設定凍結到該世界：之後改全域設定
-- 不會讓這個世界已生成的節理對不上。要改這個世界的節理，請編輯 rockmech.conf。
if not world_conf:has("rockmech_joint_lattice") then
	world_conf:set("rockmech_surface_y", tostring(cfg.surface_y))
	world_conf:set("rockmech_joint_persistence", cfg.joint_persistence)
	world_conf:set("rockmech_joint_lattice", tostring(cfg.joint_lattice))
	if not world_conf:has("rockmech_lith_mode") then
		world_conf:set("rockmech_lith_mode", cfg.lith_mode)
	end
	if not world_conf:has("rockmech_zone_width") then
		world_conf:set("rockmech_zone_width", tostring(cfg.zone_width))
	end
	for i, js in ipairs(cfg.joint_sets) do
		if i <= rockmech.config.MAX_SET_OVERRIDES then
			world_conf:set("rockmech_joint_set_" .. i, js.jr and ("%g,%g,%g,%g,%g,%g"):format(
				js.dip, js.dipdir, js.spacing, js.persistence, js.jr, js.ja)
				or ("%g,%g,%g,%g,%g"):format(js.dip, js.dipdir, js.spacing, js.persistence, js.phi))
		end
	end
	if world_conf:write() then
		core.log("action", "[rockmech] 已建立世界設定 " .. world_conf_path)
	end
end
-- 片狀延續性加入之前建立的世界：維持舊的逐面延續性（已生成的節理貼圖才對得上）
if not world_conf:has("rockmech_joint_persistence") then
	world_conf:set("rockmech_joint_persistence", "face")
	cfg.joint_persistence = "face"
	world_conf:write()
end
worldgen.register_command()       -- /rockmech_geology：老師查這個世界的地質
-- mapgen 執行緒無法讀主環境的變數，以 IPC 傳遞世界設定
core.ipc_set("rockmech:world_settings", world_conf:to_table())

-- 節理組（依世界種子前處理）。延遲到第一次使用才計算，避免載入期種子尚未就緒。
local prepared_sets
function rockmech.get_joint_sets()
	if not prepared_sets then
		local seed_str = core.get_mapgen_setting("seed")
		if not seed_str then
			core.log("warning", "[rockmech] 讀不到世界種子，節理延續性改用種子 0")
		end
		rockmech.seed = rockmech.joints.seed_from_string(seed_str or "0")
		local opts
		if cfg.dfn then
			-- 離散裂隙網路：多個地質區時，每組只長在自己的區（斷層帶裡沒有）
			opts = {dfn = rockmech.dfn}
			local S = cfg.strata
			if S and S.faults then
				local idx, dom = {}, rockmech.stress.strata_domain
				for k, D in ipairs(S.domains) do idx[D] = k end
				opts.where = function(x, y, z) local D = dom(S, x, z); return D and idx[D] end
			end
			for _, js in ipairs(cfg.joint_sets) do
				if js.lith or js.lith_p32 then
					local key_at, c = rockmech.stress.lith_key_at, cfg
					opts.lith_at = function(x, y, z) return key_at(c, x, y, z) end
					break
				end
			end
		end
		prepared_sets = rockmech.joints.prepare(cfg.joint_sets, rockmech.seed, cfg.joint_lattice,
			cfg.joint_persistence, opts)
		-- 煤層不帶節理（煤是軟弱的層狀岩，節理組只發育在頂底板的頁岩裡）：煤層裡、和煤層接觸的面都不算節理
		local s = cfg.coal_seam
		if cfg.strata then
			-- 互層：煤那幾層不帶節理；斷層角礫岩（多個地質區之間的斷層帶）已經磨碎了，也不畫節理
			local st, at, cj = cfg.strata, rockmech.stress.strata_at, cfg.coal_joints
			prepared_sets.skip = function(x, y, z)
				local k = at(st, x, y, z)
				return k == "breccia" or (k == "coal" and not cj)
			end
		elseif s and not cfg.coal_joints then
			local in_seam = rockmech.stress.in_seam
			prepared_sets.skip = function(x, y, z) return in_seam(s, x, y, z) end
		end
		-- 豎井外圍那圈硬大理岩不帶節理（oreshaft.lua）
		if cfg.shafts then
			local prev, ring = prepared_sets.skip, cfg.in_shaft_ring
			prepared_sets.skip = function(x, y, z) return ring(x, z) or (prev ~= nil and prev(x, y, z)) end
		end
	end
	return prepared_sets
end

-- 引擎端模組
dofile(modpath .. "/nodes.lua")
dofile(modpath .. "/assay.lua")         -- 碎石的成分存在 metadata（跟著碎石走；rockmech.assay）
dofile(modpath .. "/rockfall_entity.lua")
dofile(modpath .. "/rigidfall_entity.lua")
dofile(modpath .. "/collapse.lua") -- 沿用 physics_core 的坍塌機制，階段 3 由 keyblock.lua 取代
dofile(modpath .. "/tools.lua")
dofile(modpath .. "/ui.lua")
dofile(modpath .. "/blasting.lua")
dofile(modpath .. "/drilling.lua")
dofile(modpath .. "/mixtrough.lua")      -- 硝酸銨、柴油、拌和槽（手拌 ANFO）
dofile(modpath .. "/groundsupport.lua")
dofile(modpath .. "/timber.lua")
dofile(modpath .. "/femstress.lua")
dofile(modpath .. "/rubble_tool.lua")
dofile(modpath .. "/vehicles.lua")
dofile(modpath .. "/vehicle_lights.lua")   -- 車燈：引擎發動時照亮車頭前方
dofile(modpath .. "/worklight.lua")        -- 工作照明燈（像火把一樣放）
dofile(modpath .. "/nocraft.lua")          -- 拿掉內建合成（只靠商店、鋸木台、木工桌）
dofile(modpath .. "/impact.lua")
dofile(modpath .. "/crusher.lua")
dofile(modpath .. "/plant.lua")
dofile(modpath .. "/goldplant.lua")       -- 提金廠（褐鐵礦的金：碳浸法），營地的貴金屬商
dofile(modpath .. "/conveyor.lua")
dofile(modpath .. "/beltswitch.lua")   -- 輸送帶控制箱：運轉／停止／依礦價
dofile(modpath .. "/loadout.lua")
dofile(modpath .. "/dumphopper.lua")   -- 受料斗：卡車倒進來、交給輸送帶運走
dofile(modpath .. "/facilitydamage.lua")   -- 設施耐久度：爆炸扣整座的血、裂紋、炸毀、技工修理
dofile(modpath .. "/npc_skins.lua")
dofile(modpath .. "/career.lua")
dofile(modpath .. "/team.lua")
dofile(modpath .. "/nametag.lua")
dofile(modpath .. "/npc_talk.lua")      -- NPC 對話泡泡（台詞在 npc_lines.lua）
dofile(modpath .. "/preview.lua")
dofile(modpath .. "/locker.lua")
dofile(modpath .. "/delivery.lua")
dofile(modpath .. "/restart.lua")
dofile(modpath .. "/memwatch.lua")
dofile(modpath .. "/drone.lua")
dofile(modpath .. "/research.lua")
dofile(modpath .. "/wages.lua")
dofile(modpath .. "/operator.lua")
dofile(modpath .. "/woodwork.lua")
dofile(modpath .. "/weather.lua")
dofile(modpath .. "/monitor.lua")
dofile(modpath .. "/testing.lua")
dofile(modpath .. "/stereonet.lua")
dofile(modpath .. "/fuel.lua")
dofile(modpath .. "/market.lua")           -- 市場：柴油、炸藥、鋼材價格波動、偶發事件、經濟分析師
dofile(modpath .. "/camp.lua")             -- 營地的位置、混凝土地坪、收料區、保護
dofile(modpath .. "/orders.lua")           -- 訂單：採購員、收料車
dofile(modpath .. "/train.lua")            -- 火車出貨（教學地圖原型）：鐵路、裝車點、列車
dofile(modpath .. "/airq.lua")         -- 空氣品質：柴油廢氣、炮煙、通風、氣體偵測器
dofile(modpath .. "/knowledge.lua")
dofile(modpath .. "/coredrill.lua")
dofile(modpath .. "/oreshaft.lua")       -- 豎井：井口倒礦，井底的破碎站收料
dofile(modpath .. "/shaftroad.lua")      -- 豎井道路：營地到每口豎井的壓碎大理岩路
dofile(modpath .. "/mentor.lua")         -- 老礦工：單機經營模式一開始在附近晃、聊天式的小任務
dofile(modpath .. "/mohr.lua")         -- Mohr 圓的畫圖
dofile(modpath .. "/tablet.lua")       -- 數值分析平板：手上的螢幕畫指著那一格的 Mohr 圓
dofile(modpath .. "/stressmeter.lua")   -- 量應力：平板千斤頂、孔內應力計
dofile(modpath .. "/worldtools.lua")
dofile(modpath .. "/fsmask.lua")
dofile(modpath .. "/jointmesh.lua")

-- 地圖生成在 mapgen 執行緒中執行（另一個 Lua 環境），以 IPC 傳遞 modpath
core.ipc_set("rockmech:modpath", modpath)
core.register_mapgen_script(modpath .. "/mapgen.lua")

-- default 的倒木結構檔（apple_log 等）引用 flowers 模組的蘑菇；本遊戲沒有 flowers，
-- 每次載入都會出現 NodeResolver 錯誤。沒有 flowers 時把蘑菇指向空氣（倒木本來也不生成）
if not core.get_modpath("flowers") then
	core.register_alias("flowers:mushroom_brown", "air")
	core.register_alias("flowers:mushroom_red", "air")
end

-- 營地炸不壞：要在所有方塊註冊完之後（最後載入）
dofile(modpath .. "/campguard.lua")
