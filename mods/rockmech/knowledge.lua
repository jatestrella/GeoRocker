-- rockmech/knowledge.lua
-- 知識能力（經營模式）：玩家一開始看不到品位、岩性、GSI、應力、FS 這些數字（那是除錯用的），要靠下面任一方式：
--   1. 儀器（放在背包裡就有效，一種儀器一種能力）：XRF 分析儀 → 品位判讀、GSI 評估圖卡 → 岩體分類、地質羅盤 → 岩石力學
--   2. 雇用地質學家（研究帳篷的駐點地質師）：$8,000、20 分鐘，雇用期間全組三種能力都有；只在組員在線上時倒數
--   3. 進修（研究帳篷南邊的大學教授）：從題庫抽 5 題，答對 4 題就永久取得那一科的能力（個人）；沒過要等 3 分鐘才能再考同一科
-- 背包（I）的「個人資料」分頁列出自己掌握的能力和來源。
--   開了 /god 全部看得到（除錯）。不是經營模式全部看得到。
-- 題庫：世界資料夾的 questions.txt（沒有就寫一份預設的），老師可以自己改，格式見檔案開頭。
-- 能力：grade 品位判讀（品位）、rockmass 岩體分類（岩性、GSI、上覆厚度）、mechanics 岩石力學（σ、FS、節理、裂紋）

local S = rockmech.S
local TR = rockmech.config.TR
local E = core.formspec_escape
local cfg = rockmech.cfg
local storage = rockmech.collapse.storage

local ABILITIES = {
	{key = "grade", label = TR("Grade assessment"), item = "rockmech:xrf"},
	{key = "rockmass", label = TR("Rock mass classification"), item = "rockmech:gsi_card"},
	{key = "mechanics", label = TR("Rock mechanics"), item = "rockmech:compass"},
	-- 剝採比（破碎站顯示）：沒有儀器，要進修（教授考試）或研究帳篷研發「採礦規劃」（全組），雇用的地質學家不算
	{key = "planning", label = TR("Mine planning"), research = "mine_planning"},
}
local AB = {}
for _, a in ipairs(ABILITIES) do AB[a.key] = a end
rockmech.abilities = ABILITIES

local HIRE_COST, HIRE_SECS = 8000, 20 * 60
local EXAM_N, EXAM_PASS, EXAM_COOLDOWN = 5, 4, 180
local KNOW = "rockmech:know_"           -- 玩家 meta：考過的科目
local COOL = "rockmech:exam_cd_"        -- 玩家 meta：這一科下次能考的時間（os.time）
local HIRE = "hire:"                    -- mod storage：hire:<帳戶> = 剩幾秒
local HIRED_BY = "hire_by:"             -- mod storage：hire_by:<帳戶> = 雇用者（地質學家跟著他）

local function money_text(v) return ("%s$%.0f"):format(v < 0 and "−" or "", math.abs(v)) end
local function mmss(s) s = math.max(0, math.ceil(s)); return ("%d:%02d"):format(math.floor(s / 60), s % 60) end

---------------------------------------------------------------------------
-- 看不看得到
---------------------------------------------------------------------------

local function hire_left(acc) return storage:get_float(HIRE .. acc) end

-- name 這位玩家看不看得到 ability（grade／rockmass／mechanics）的資訊
-- no_items：不算背包裡的儀器（指著岩石自動顯示、車斗品位只看自己會的；儀器要右鍵用。岩芯箱判讀時背包有就算）
function rockmech.can_see(name, ability, no_items)
	if not cfg.career then return true end
	local player = name and core.get_player_by_name(name)
	if not player then return false end
	local meta = player:get_meta()
	if meta:get_int("godmode:on") == 1 then return true end
	if meta:get_string(KNOW .. ability) == "1" then return true end
	local a = AB[ability]
	if a and a.item and not no_items and player:get_inventory():contains_item("main", a.item) then return true end
	if a and a.research and rockmech.research_level and rockmech.research_level(name, a.research) >= 1 then return true end
	if not (a and a.research) and rockmech.account_of and hire_left(rockmech.account_of(name)) > 0 then return true end
	return false
end

-- 儀器（工具室管理員賣；地質羅盤在 tools.lua）：右鍵用，結果顯示在準心右上的資訊泡泡（ui.lua）
local function use_on_node(player, pointed, give)
	if pointed.type ~= "node" or not rockmech.instrument_lines then return end
	local lines = rockmech.instrument_lines(player, pointed.under, give)
	rockmech.info_bubble(player, #lines > 0 and lines or {S("Nothing to read here")}, pointed.under)
end
core.register_craftitem("rockmech:xrf", {
	description = S("Handheld XRF analyzer\nRight-click rock, rubble or a truck bed"),
	short_description = S("Handheld XRF analyzer"),
	inventory_image = "[fill:16x16:#00000000^[fill:8x12:4,3:#e8e8e0^[fill:6x4:5,4:#3a6a9a^[fill:4x3:6,11:#3a3a3a^[fill:2x2:7,0:#c03020",
	stack_max = 1,
	on_place = function(itemstack, player, pointed)
		if player and player:is_player() then use_on_node(player, pointed, {grade = true}) end
		return itemstack
	end,
	-- 指著車：車斗裡的料的品位
	on_secondary_use = function(itemstack, player, pointed)
		if not (player and player:is_player() and pointed and pointed.type == "object") then return itemstack end
		local e = pointed.ref:get_luaentity()
		local V = rockmech.vehicles
		if e and e.vkind and V and V.TYPES[e.vkind] and (V.TYPES[e.vkind].cap or 0) > 0 then
			local ore, grade = V.load_ore(e)
			rockmech.info_bubble(player, {V.TYPES[e.vkind].desc, ore and rockmech.ore_text(ore, grade)
				or (V.load_total(e) > 0 and S("No ore in the load") or S("Empty"))})
		end
		return itemstack
	end,
})
core.register_craftitem("rockmech:gsi_card", {
	description = S("GSI chart\nRight-click a rock face"),
	short_description = S("GSI chart"),
	inventory_image = "[fill:16x16:#00000000^[fill:14x12:1,2:#f4f0e0^[fill:12x2:2,4:#c08040^[fill:12x2:2,7:#80a060^[fill:12x2:2,10:#6080c0",
	stack_max = 1,
	on_place = function(itemstack, player, pointed)
		if player and player:is_player() then use_on_node(player, pointed, {rockmass = true}) end
		return itemstack
	end,
})

---------------------------------------------------------------------------
-- 雇用地質學家（全組、在線上才倒數）
---------------------------------------------------------------------------

local function tell(acc, msg)
	for _, m in ipairs(rockmech.account_members(acc)) do rockmech.notify(m, S("[Geologist] @1", msg)) end
end

function rockmech.knowledge_hire(name)
	local acc = rockmech.account_of(name)
	if hire_left(acc) > 0 then
		rockmech.notify(name, S("[Geologist] Already hired, @1 left", mmss(hire_left(acc))))
	elseif not rockmech.has_account(name) then
		rockmech.notify(name, S("[Geologist] You are not in a team yet, so you have no funds"))
	elseif rockmech.money(name) < HIRE_COST then
		rockmech.notify(name, S("[Geologist] Not enough money: hiring costs @1", money_text(HIRE_COST)))
	else
		rockmech.add_money(name, -HIRE_COST)
		storage:set_float(HIRE .. acc, HIRE_SECS)
		storage:set_string(HIRED_BY .. acc, name)       -- 地質學家跟著這個人
		tell(acc, S("@1 hired a geologist (@2, @3 min; the timer only runs while team members are online): the whole team can see grade, lithology, GSI, stress and factor of safety",
			name, money_text(HIRE_COST), ("%d"):format(HIRE_SECS / 60)))
	end
end
function rockmech.knowledge_hire_text(name)
	local left = hire_left(rockmech.account_of(name))
	return left > 0 and S("Hired, @1 left", mmss(left)) or S("@1 / @2 min, all three abilities for the whole team", money_text(HIRE_COST), ("%d"):format(HIRE_SECS / 60))
end

-- 跟著雇用者跑的地質學家：雇用期間出現在雇用者身邊，遠了就走過去（更遠用跑的，超過 FOLLOW_TP 直接到身邊），
-- 頭上顯示剩下的時間；雇用期滿或雇用者下線就消失（雇用者回來、還在雇用期內就再出現）
local FOLLOWER = "rockmech:geologist_follower"
local FOLLOW_NEAR, FOLLOW_RUN, FOLLOW_TP = 2.5, 8, 30
local WALK, RUN = 3, 6
local followers = {}                    -- 帳戶 → entity

core.register_entity(FOLLOWER, {
	initial_properties = {
		physical = true, collide_with_objects = false, collisionbox = {-0.3, 0, -0.3, 0.3, 1.7, 0.3},
		visual = "mesh", mesh = "character.b3d", textures = {rockmech.npc_skin("geologist")},
		nametag = S("Geologist"), nametag_color = "#e0d0a0", stepheight = 1.1, static_save = false,
	},
	on_activate = function(self)
		self.object:set_armor_groups({immortal = 1})
		self.object:set_acceleration({x = 0, y = -9.81, z = 0})
		self.object:set_animation({x = 0, y = 79}, 30)
		rockmech.npc_dress(self.object, "geologist")
	end,
	on_step = function(self, dtime)
		local acc = self.acc
		local who = acc and storage:get_string(HIRED_BY .. acc)
		local p = who and who ~= "" and core.get_player_by_name(who)
		if not (p and hire_left(acc) > 0 and followers[acc] == self.object) then self.object:remove(); return end
		local pos, tp = self.object:get_pos(), p:get_pos()
		local dx, dz = tp.x - pos.x, tp.z - pos.z
		local d = math.sqrt(dx * dx + dz * dz)
		local vel = self.object:get_velocity()
		if d > FOLLOW_TP or math.abs(tp.y - pos.y) > 12 or p:get_attach() and d > FOLLOW_RUN then
			-- 太遠、或玩家在車上／無人機上跑遠了：直接到玩家身邊（後方一點）
			local back = core.yaw_to_dir(p:get_look_horizontal())
			self.object:set_pos({x = tp.x - back.x * 2, y = tp.y + 0.5, z = tp.z - back.z * 2})
			self.object:set_velocity({x = 0, y = 0, z = 0})
		elseif d > FOLLOW_NEAR then
			local v = d > FOLLOW_RUN and RUN or WALK
			self.object:set_velocity({x = dx / d * v, y = vel.y, z = dz / d * v})
			self.object:set_yaw(math.atan2 and math.atan2(-dx, dz) or math.atan(-dx, dz))
			if self.anim ~= "walk" then self.anim = "walk"; self.object:set_animation({x = 168, y = 187}, v * 10) end
		else
			self.object:set_velocity({x = 0, y = vel.y, z = 0})
			self.object:set_yaw(math.atan2 and math.atan2(-dx, dz) or math.atan(-dx, dz))
			if self.anim ~= "stand" then self.anim = "stand"; self.object:set_animation({x = 0, y = 79}, 30) end
		end
		self.tag_t = (self.tag_t or 1) + dtime
		if self.tag_t >= 1 then
			self.tag_t = 0
			rockmech.npc_set_tag(self.object, S("Geologist  @1 left", mmss(hire_left(acc))))
		end
	end,
	on_punch = function() return true end,
	on_rightclick = function(self, clicker) if rockmech.hand_first and rockmech.hand_first(clicker) then return end
		if clicker and clicker:is_player() then
			rockmech.notify(clicker:get_player_name(), S("[Geologist] @1 left on my contract. While I'm here, the whole team can see grade, lithology, GSI, stress and factor of safety.",
				mmss(hire_left(self.acc or ""))))
		end
	end,
})

local t = 0
core.register_globalstep(function(dtime)
	t = t + dtime
	if t < 1 then return end
	local dt = t
	t = 0
	local accs = {}
	for _, p in ipairs(core.get_connected_players()) do accs[rockmech.account_of(p:get_player_name())] = true end
	for acc in pairs(accs) do
		local left = hire_left(acc)
		if left > 0 then
			left = left - dt
			if left <= 0 then
				storage:set_float(HIRE .. acc, 0)
				tell(acc, S("The contract is over; the geologist has gone back"))
				if followers[acc] and followers[acc]:get_pos() then followers[acc]:remove() end
				followers[acc] = nil
			else
				storage:set_float(HIRE .. acc, left)
				-- 雇用者在線上、地質學家不在就放一個到他身邊
				local o = followers[acc]
				local who = core.get_player_by_name(storage:get_string(HIRED_BY .. acc))
				if who and not (o and o:get_pos()) then
					local pp = who:get_pos()
					local e = core.add_entity({x = pp.x + 1.5, y = pp.y + 0.5, z = pp.z + 1.5}, FOLLOWER)
					if e then e:get_luaentity().acc = acc; followers[acc] = e end
				end
			end
		end
	end
end)

---------------------------------------------------------------------------
-- 題庫：世界資料夾的 questions.txt
---------------------------------------------------------------------------

local BANK_FILE = core.get_worldpath() .. "/questions.txt"
local DEFAULT_BANK = [[
# GeoRocker 進修題庫（老師可以自己改；改完重開伺服器生效）
#
# 格式：
#   [品位判讀]、[岩體分類]、[岩石力學] 開始一個科目（科目名稱要跟這三個一樣）
#   Q: 題目（一行；要換行就寫 \n）
#   選擇題：A: … B: … C: … D: …（兩到六個選項），ANS: 正確選項的字母（顯示時選項順序會打亂）
#   填數字：NUM: 正確答案，TOL: 容許誤差（省略就是 0），UNIT: 單位（可省略）
#   題目之間空一行。# 開頭是註解。
# 每次考試從那一科隨機抽 5 題，答對 4 題就取得能力。每科最好 10 題以上，重考時題目才會不一樣。

[品位判讀]
Q: 「品位」指的是什麼？
A: 礦石中有用成分所佔的比例
B: 礦石的單位重
C: 礦體的埋藏深度
D: 礦石的單軸抗壓強度
ANS: A

Q: 「截止品位」（cutoff grade）的意思是？
A: 礦體裡最高的品位
B: 低於這個品位的料開採、處理不划算，當作廢石
C: 選礦後精礦的品位
D: 礦價跌停時的品位
ANS: B

Q: 開採時廢石混進礦石，使送去處理的料品位下降，這叫做？
A: 回收
B: 貧化（dilution）
C: 富集
D: 剝離
ANS: B

Q: 10 t 品位 60% 的礦，混進 2 t 品位 0% 的廢石，混合後品位是多少？
NUM: 50
TOL: 0.5
UNIT: %

Q: 5 t 品位 80% 的料和 15 t 品位 40% 的料混在一起，平均品位是多少？
NUM: 50
TOL: 0.5
UNIT: %

Q: 選礦「回收率」的定義是？
A: 精礦中的有用成分 ÷ 原礦中的有用成分
B: 精礦重量 ÷ 原礦重量
C: 廢石重量 ÷ 原礦重量
D: 精礦品位 ÷ 原礦品位
ANS: A

Q: 遊戲裡破碎站的收入 = 噸數 ×（品位 × 回收率 × 礦價 − 處理費）。10 t、品位 50%、回收率 90%、礦價 $120/t、處理費 $30/t，收入是多少元？
NUM: 240
TOL: 1
UNIT: $

Q: 手持式 XRF 分析儀量測元素含量的原理是？
A: X 射線激發樣品放出的特徵螢光
B: 量測樣品的磁化率
C: 量測樣品的密度
D: 量測超音波波速
ANS: A

Q: 煤的灰分越高，代表？
A: 可燃成分越少，煤質越差
B: 發熱量越高
C: 煤越年輕
D: 跟煤質無關
ANS: A

Q: 品位控制（grade control）的主要目的是？
A: 把礦和廢石分開送，減少貧化和礦損
B: 提高炸藥的威力
C: 降低卡車油耗
D: 增加邊坡角
ANS: A

[岩體分類]
Q: GSI 的全名是？
A: Geological Strength Index
B: Ground Stress Indicator
C: Grain Size Index
D: General Stability Index
ANS: A

Q: GSI 是依據哪兩項來評估的？
A: 岩體結構（塊狀程度）與不連續面的表面狀況
B: 單軸抗壓強度與單位重
C: 地下水壓與地應力
D: 開挖跨度與支撐壓力
ANS: A

Q: GSI 越高代表？
A: 岩體越完整、不連續面狀況越好，岩體強度越高
B: 岩體越破碎
C: 地下水越多
D: 開挖越危險
ANS: A

Q: RQD 是長度至少多少公分的完整岩芯段，佔鑽孔長度的百分比？
NUM: 10
TOL: 0
UNIT: cm

Q: 鑽了 1.5 m 的岩芯，長度 ≥ 10 cm 的岩芯段加起來 1.2 m，RQD 是多少？
NUM: 80
TOL: 0.5
UNIT: %

Q: 頁岩屬於哪一類岩石？
A: 沉積岩
B: 火成岩
C: 變質岩
D: 礦物
ANS: A

Q: 花崗岩屬於哪一類岩石？
A: 火成岩（深成岩）
B: 沉積岩
C: 變質岩
D: 火山碎屑岩
ANS: A

Q: 一般岩石的單位重大約是多少 kN/m³？
A: 25～27
B: 10
C: 50
D: 2.5
ANS: A

Q: 不連續面（節理）的位態通常用哪兩個量表示？
A: 傾角與傾向
B: 間距與延續性
C: 粗糙度與充填物
D: 長度與寬度
ANS: A

Q: RMR 岩體評分系統是誰提出的？
A: Bieniawski
B: Hoek
C: Terzaghi
D: Barton
ANS: A

[岩石力學]
Q: 完整岩石的 Hoek-Brown 破壞準則是哪一個？
A: σ1 = σ3 + σci (mi σ3/σci + 1)^0.5
B: τ = c + σn tanφ
C: σ1 = σci + σ3
D: σ1 = σ3 · tan²(45° + φ/2)
ANS: A

Q: Mohr-Coulomb 破壞準則是哪一個？
A: τ = c + σn tanφ
B: σ1 = σ3 + σci (mi σ3/σci + 1)^0.5
C: σ = E ε
D: τ = G γ
ANS: A

Q: 安全係數 FS 小於 1 代表？
A: 驅動力大於抗力，會破壞
B: 非常安全
C: 剛好平衡
D: 跟穩定無關
ANS: A

Q: 單位重 25 kN/m³、深 100 m 處的垂直應力 σv 是多少 MPa？
NUM: 2.5
TOL: 0.05
UNIT: MPa

Q: 垂直應力 σv = 2.5 MPa、側壓係數 K = 0.5，水平應力是多少 MPa？
NUM: 1.25
TOL: 0.02
UNIT: MPa

Q: σ1 = 10 MPa、σ3 = 2 MPa，最大剪應力是多少 MPa？
NUM: 4
TOL: 0.05
UNIT: MPa

Q: 邊坡發生平面滑動，除了節理面走向接近坡面以外，還需要？
A: 節理傾角大於摩擦角、小於坡角（在坡面出露）
B: 節理傾角小於摩擦角
C: 節理傾角大於坡角
D: 節理是垂直的
ANS: A

Q: 岩石的張力強度大約是單軸抗壓強度的多少？
A: 1/10～1/20
B: 2 倍
C: 一樣
D: 1/2
ANS: A

Q: Terzaghi 岩載理論中，隧道頂拱上方鬆動岩體的高度 Hp 跟什麼成正比？
A: 隧道寬度加高度（B + Ht）
B: 隧道長度
C: 覆土深度的平方
D: 地下水位
ANS: A

Q: 碎石自然堆積、不再往下滑的最大坡角叫做？
A: 安息角
B: 摩擦角的兩倍
C: 傾角
D: 剪脹角
ANS: A
]]

local SUBJECT = {["品位判讀"] = "grade", ["岩體分類"] = "rockmass", ["岩石力學"] = "mechanics", ["採礦規劃"] = "planning"}
-- 採礦規劃的預設題目：舊世界的 questions.txt 沒有這一科時用這些（不改老師的檔案）
local PLANNING_BANK = [[
[採礦規劃]
Q: 露天開採的「剝採比」（stripping ratio）指的是？
A: 要挖掉的廢石量 ÷ 開採的礦石量
B: 礦石量 ÷ 廢石量
C: 礦石的品位 ÷ 截止品位
D: 開挖深度 ÷ 礦體厚度
ANS: A

Q: 剝採比越高，代表？
A: 每開採一噸礦要搬越多廢石，成本越高
B: 礦石品位越高
C: 邊坡越穩定
D: 礦石越容易選礦
ANS: A

Q: 「平衡剝採比」（break-even stripping ratio）的意思是？
A: 剝採比達到這個值時，開採一噸礦的收入剛好等於成本（含剝廢石）
B: 礦石和廢石一樣多
C: 邊坡安全係數等於 1
D: 礦價等於處理費
ANS: A

Q: 露天礦越挖越深，剝採比通常會？
A: 變大（要剝的廢石越來越多）
B: 變小
C: 不變
D: 變成零
ANS: A

Q: 當露天開採的剝採比太高、不划算時，常見的做法是？
A: 改成地下開採
B: 把邊坡挖得更緩
C: 提高處理費
D: 停止鑽探
ANS: A

Q: 某礦帶挖了 300 t 廢石、100 t 礦石，剝採比是多少？
NUM: 3
TOL: 0.01

Q: 某礦帶剝採比 4，開採了 50 t 礦石，總共要搬多少噸的料（礦石加廢石）？
NUM: 250
TOL: 0.5
UNIT: t

Q: 邊坡挖得越陡，對剝採比的影響是？
A: 剝採比變小（少挖廢石），但邊坡風險變高
B: 剝採比變大
C: 沒有影響
D: 品位變高
ANS: A

Q: 礦體上方的覆蓋層（表土、廢石）在開採前要先移除，這叫做？
A: 剝離（stripping）
B: 選礦
C: 回填
D: 貧化
ANS: A

Q: 截止品位提高時，算進礦石的量會減少、當廢石的量增加，剝採比會？
A: 變大
B: 變小
C: 不變
D: 變成負的
ANS: A
]]

local function load_bank()
	local f = io.open(BANK_FILE, "r")
	local text
	if f then
		text = f:read("*a")
		f:close()
	else
		text = DEFAULT_BANK .. PLANNING_BANK
		local w = io.open(BANK_FILE, "w")
		if w then w:write(text); w:close() end
	end
	if not text:find("[採礦規劃]", 1, true) then text = text .. "\n" .. PLANNING_BANK end
	local bank = {grade = {}, rockmass = {}, mechanics = {}, planning = {}}
	local subj, q
	local function finish()
		if q and subj and q.text and (q.num or (#q.opts >= 2 and q.ans)) then table.insert(bank[subj], q) end
		q = nil
	end
	for line in (text .. "\n"):gmatch("([^\n]*)\n") do
		line = line:gsub("\r", ""):gsub("^\239\187\191", "")
		local s = line:match("^%s*(.-)%s*$")
		if s == "" then finish()
		elseif s:sub(1, 1) == "#" then
		elseif s:match("^%[.+%]$") then
			finish()
			subj = SUBJECT[s:sub(2, -2)]
			if not subj then core.log("warning", "[rockmech] questions.txt：不認得的科目 " .. s) end
		else
			local k, v = s:match("^(%u+):%s*(.*)$")
			if k == "Q" then
				finish()
				q = {text = v:gsub("\\n", "\n"), opts = {}, letters = {}}
			elseif q and k and #k == 1 and k:match("[A-F]") then
				q.opts[#q.opts + 1] = v
				q.letters[k] = #q.opts
			elseif q and k == "ANS" then q.ans = q.letters[v:upper()]
			elseif q and k == "NUM" then q.num = tonumber(v)
			elseif q and k == "TOL" then q.tol = tonumber(v) or 0
			elseif q and k == "UNIT" then q.unit = v
			end
		end
	end
	finish()
	for _, a in ipairs(ABILITIES) do
		core.log("action", ("[rockmech] 題庫 %s：%d 題"):format(a.label, #bank[a.key]))
	end
	return bank
end
local BANK = load_bank()

---------------------------------------------------------------------------
-- 考試
---------------------------------------------------------------------------

local EXAM = "rockmech:exam"
local sessions = {}         -- 玩家名稱 → {ab, qs = {{q, order（選項顯示順序）}}}
rockmech.knowledge_sessions = sessions     -- 測試用

local function shuffle(t)
	for i = #t, 2, -1 do local j = math.random(i); t[i], t[j] = t[j], t[i] end
	return t
end

local function exam_form(name)
	local s = sessions[name]
	local out = {"formspec_version[6]size[17,16]",
		("label[0.5,0.6;%s]"):format(E(S("Training exam: @1 (@2 questions, @3 correct to pass)", S(AB[s.ab].label), tostring(#s.qs), tostring(EXAM_PASS))))}
	local y = 1.2
	for i, e in ipairs(s.qs) do
		out[#out + 1] = ("textarea[0.5,%g;16,1.2;;;%s]"):format(y, core.formspec_escape(("%d. %s"):format(i, e.q.text)))
		if e.q.num then
			out[#out + 1] = ("field[0.5,%g;4,0.8;q%d;;]"):format(y + 1.35, i)
			if e.q.unit then out[#out + 1] = ("label[4.7,%g;%s]"):format(y + 1.75, core.formspec_escape(e.q.unit)) end
		else
			local items = {E(S("(choose one)"))}
			for _, k in ipairs(e.order) do items[#items + 1] = core.formspec_escape(e.q.opts[k]) end
			out[#out + 1] = ("dropdown[0.5,%g;16,0.8;q%d;%s;1;true]"):format(y + 1.35, i, table.concat(items, ","))
		end
		y = y + 2.7
	end
	out[#out + 1] = ("button[6,%g;2.4,0.8;submit;%s]button_exit[8.8,%g;2.4,0.8;cancel;%s]"):format(y + 0.1, E(S("Hand in")), y + 0.1, E(S("Give up")))
	return table.concat(out)
end

function rockmech.knowledge_exam(player, ab)
	local name = player:get_player_name()
	local meta = player:get_meta()
	if meta:get_string(KNOW .. ab) == "1" then
		rockmech.notify(name, S("[Training] You have already passed \"@1\"", S(AB[ab].label)))
		return
	end
	local wait = meta:get_int(COOL .. ab) - os.time()
	if wait > 0 then
		rockmech.notify(name, S("[Training] You have to wait @1 before retaking \"@2\"", mmss(wait), S(AB[ab].label)))
		return
	end
	local pool = BANK[ab]
	if #pool < EXAM_N then
		rockmech.notify(name, S("[Training] The \"@1\" question bank only has @2 questions; at least @3 are needed (ask the teacher to add some to questions.txt)",
			S(AB[ab].label), tostring(#pool), tostring(EXAM_N)))
		return
	end
	local idx = {}
	for i = 1, #pool do idx[i] = i end
	shuffle(idx)
	local qs = {}
	for i = 1, EXAM_N do
		local q = pool[idx[i]]
		local order = {}
		for k = 1, #q.opts do order[k] = k end
		qs[i] = {q = q, order = shuffle(order)}
	end
	sessions[name] = {ab = ab, qs = qs}
	core.show_formspec(name, EXAM, exam_form(name))
end

local function answer_text(e)
	if e.q.num then return ("%g%s"):format(e.q.num, e.q.unit and (" " .. e.q.unit) or "") end
	return e.q.opts[e.q.ans]
end

core.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= EXAM then return end
	local name = player:get_player_name()
	local s = sessions[name]
	if not s then return true end
	if fields.cancel or (fields.quit and not fields.submit) then sessions[name] = nil; return true end
	if not fields.submit then return true end
	local right, wrong = 0, {}
	for i, e in ipairs(s.qs) do
		local ok = false
		local v = fields["q" .. i]
		if e.q.num then
			local x = tonumber((v or ""):gsub(",", ""):match("^%s*(.-)%s*$"))
			ok = x ~= nil and math.abs(x - e.q.num) <= (e.q.tol or 0) + 1e-9
		else
			local k = tonumber(v or "")          -- 選了第幾項（1 是「請選擇」）
			ok = k and k >= 2 and e.order[k - 1] == e.q.ans or false
		end
		if ok then right = right + 1 else wrong[#wrong + 1] = S("@1. Correct answer: @2", tostring(i), answer_text(e)) end
	end
	local ab = s.ab
	sessions[name] = nil
	local meta = player:get_meta()
	local pass = right >= EXAM_PASS
	local msg
	if pass then
		meta:set_string(KNOW .. ab, "1")
		msg = S("@1/@2 correct: passed! You have learned \"@3\".", tostring(right), tostring(#s.qs), S(AB[ab].label))
		core.log("action", ("[rockmech] exam %s passed %s (%d/%d)"):format(name, ab, right, #s.qs))
		if rockmech.account_of then
			for _, m in ipairs(rockmech.account_members(rockmech.account_of(name))) do
				rockmech.notify(m, S("[Training] @1 passed \"@2\"", name, S(AB[ab].label)))
			end
		end
	else
		meta:set_int(COOL .. ab, os.time() + EXAM_COOLDOWN)
		msg = S("@1/@2 correct: not passed (@3 needed). You can retake it in @4 minutes.", tostring(right), tostring(#s.qs), tostring(EXAM_PASS),
			("%d"):format(EXAM_COOLDOWN / 60))
	end
	local out = {"formspec_version[6]size[14,8]", ("label[0.5,0.7;%s]"):format(core.formspec_escape(msg))}
	if #wrong > 0 then
		out[#out + 1] = ("textarea[0.5,1.4;13,5.4;;%s;%s]"):format(E(S("Questions you got wrong")), E(table.concat(wrong, "\n")))
	end
	out[#out + 1] = ("button_exit[5.5,7;3,0.8;ok;%s]"):format(E(S("OK")))
	core.show_formspec(name, EXAM .. "_result", table.concat(out))
	return true
end)
core.register_on_leaveplayer(function(player) sessions[player:get_player_name()] = nil end)

-- 駐點地質師畫面裡的「雇用」「進修」區塊（research.lua 呼叫）。回傳 formspec 片段、用掉的高度
function rockmech.knowledge_form(name, y)
	local out = {}
	out[#out + 1] = ("label[0.5,%g;%s]"):format(y + 0.4, E(S("Hire a geologist: @1", rockmech.knowledge_hire_text(name))))
	if hire_left(rockmech.account_of(name)) <= 0 then out[#out + 1] = ("button[11.4,%g;3.4,0.8;hire;%s]"):format(y, E(S("Hire"))) end
	y = y + 1.1
	out[#out + 1] = ("label[0.5,%g;%s]"):format(y + 0.4, E(S("Want to learn it yourself? Take the training exams with the university professor next door")))
	return table.concat(out), 1.9
end

---------------------------------------------------------------------------
-- 能力的來源（個人資料頁、教授用）
---------------------------------------------------------------------------

-- 回傳 有沒有, 來源說明
local function ability_status(name, key)
	local player = core.get_player_by_name(name)
	if not player then return false, "" end
	local meta = player:get_meta()
	local a = AB[key]
	local src = {}
	if meta:get_string(KNOW .. key) == "1" then src[#src + 1] = S("Passed the exam (permanent)") end
	if a.item and player:get_inventory():contains_item("main", a.item) then
		local d = core.registered_items[a.item]
		src[#src + 1] = S("@1 in your inventory (right-click to use)", d and rockmech.desc_short(d) or a.item)
	end
	if a.research and rockmech.research_level and rockmech.research_level(name, a.research) >= 1 then
		src[#src + 1] = S("Researched at the research lab (whole team)")
	end
	local left = (not a.research) and rockmech.account_of and hire_left(rockmech.account_of(name)) or 0
	if left > 0 then src[#src + 1] = S("Hired geologist (@1 left)", mmss(left)) end
	if meta:get_int("godmode:on") == 1 then src[#src + 1] = "/god" end
	return #src > 0, table.concat(src, S(", "))
end
local function cooldown_left(player, key) return player:get_meta():get_int(COOL .. key) - os.time() end

---------------------------------------------------------------------------
-- 大學教授：研究帳篷南邊的戶外講堂（黑板、講桌、學生椅），右鍵選科目考試
---------------------------------------------------------------------------

local PROF_SKIN = rockmech.npc_skin("professor")     -- 造型：npc_skins.lua

-- 講堂的擺設
core.register_node("rockmech:camp_blackboard", {
	description = S("Blackboard"), drawtype = "nodebox", paramtype = "light", paramtype2 = "facedir", is_ground_content = false,
	tiles = {"default_wood.png", "default_wood.png", "default_wood.png", "default_wood.png",
		"[fill:16x16:#2f4a3a^[fill:16x1:0,0:#6a4a28^[fill:16x1:0,15:#6a4a28^[fill:10x1:2,4:#d8d8c8^[fill:6x1:3,7:#d8d8c8"
		.. "^[fill:1x3:10,6:#d8d8c8^[fill:4x1:9,10:#d8d8c8^[fill:8x1:2,12:#d8d8c8", "default_wood.png"},
	node_box = {type = "fixed", fixed = {-0.5, -0.5, -0.1, 0.5, 0.5, 0.0}},
	groups = {not_in_creative_inventory = 1},
})
core.register_node("rockmech:camp_lectern", {
	description = S("Lectern"), drawtype = "nodebox", paramtype = "light", paramtype2 = "facedir", is_ground_content = false,
	tiles = {"default_wood.png"},
	node_box = {type = "fixed", fixed = {{-0.3, -0.5, -0.25, 0.3, 0.3, 0.25}, {-0.4, 0.3, -0.35, 0.4, 0.42, 0.3},
		{-0.15, 0.42, -0.1, 0.15, 0.46, 0.15}}},
	groups = {not_in_creative_inventory = 1},
})

local PROF = "rockmech:npc_professor"
local PROF_FORM = "rockmech:professor"
local PROF_DX, PROF_Z = 11, -28   -- 講堂中心：研究帳篷（營地中心往東 23）的西邊，同一排、面向北

local function prof_form(name)
	local player = core.get_player_by_name(name)
	local out = {("formspec_version[6]size[13,%g]"):format(3.6 + #ABILITIES * 1.1),
		("label[0.5,0.6;%s]"):format(E(S("University professor: training exams"))),
		("label[0.5,1.2;%s]"):format(E(S("Each subject draws @1 questions from the bank; get @2 right to learn it for good. If you fail, wait @3 minutes before retaking the same subject.",
			tostring(EXAM_N), tostring(EXAM_PASS), ("%d"):format(EXAM_COOLDOWN / 60))))}
	local y = 2.0
	for _, a in ipairs(ABILITIES) do
		local status
		if player and player:get_meta():get_string(KNOW .. a.key) == "1" then status = S("Already learned")
		elseif player and cooldown_left(player, a.key) > 0 then status = S("Retake in @1", mmss(cooldown_left(player, a.key)))
		else status = S("@1 questions in the bank", tostring(#BANK[a.key])) end
		out[#out + 1] = ("label[0.5,%g;%s]"):format(y + 0.4, E(S(a.label)))
		out[#out + 1] = ("label[3.5,%g;%s]"):format(y + 0.4, core.formspec_escape(status))
		out[#out + 1] = ("button[9.4,%g;3,0.8;study_%s;%s]"):format(y, a.key, E(S("Take exam")))
		y = y + 1.1
	end
	out[#out + 1] = ("button_exit[5,%g;3,0.8;close;%s]"):format(y + 0.4, E(S("Close")))
	return table.concat(out)
end
core.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= PROF_FORM then return end
	for key in pairs(fields) do
		local ab = key:match("^study_(%w+)$")
		if ab and AB[ab] then rockmech.knowledge_exam(player, ab); return true end
	end
	return true
end)

core.register_entity(PROF, {
	initial_properties = {
		physical = true, collisionbox = {-0.3, 0, -0.3, 0.3, 1.7, 0.3},
		visual = "mesh", mesh = "character.b3d", textures = {PROF_SKIN},
		nametag = S("University professor"), nametag_color = "#c0d8ff", static_save = false,
	},
	on_activate = function(self)
		self.object:set_armor_groups({immortal = 1})
		self.object:set_animation({x = 0, y = 79}, 20)
	end,
	on_rightclick = function(self, clicker) if rockmech.hand_first and rockmech.hand_first(clicker) then return end
		if clicker and clicker:is_player() then core.show_formspec(clicker:get_player_name(), PROF_FORM, prof_form(clicker:get_player_name())) end
	end,
	on_punch = function() return true end,
})
if rockmech.career_npcs then rockmech.career_npcs.professor = {entity = PROF, sit = false} end

-- 講堂：教授站在講桌後、背後一排黑板，前面兩排學生椅（面向教授）；面向北（營地中間的空地），跟研究帳篷排成一排
local function prof_flag(x0) return "professor_site:" .. x0 end
function rockmech.career_build_professor(x0)
	if not rockmech.career_placer then return end
	storage:set_string(prof_flag(x0), "1")
	local cx, cz = x0 + PROF_DX, PROF_Z
	local y
	for yy = 40, -30, -1 do
		local n = core.get_node({x = cx, y = yy, z = cz}).name
		if n ~= "air" and n ~= "ignore" then y = yy; break end
	end
	y = y or 0
	local set, at, yaw = rockmech.career_placer(cx, cz, y, "north")
	for dx = -2, 2 do
		set(dx, 1, -2, "rockmech:camp_blackboard"); set(dx, 2, -2, "rockmech:camp_blackboard")
	end
	set(0, 1, 1, "rockmech:camp_lectern")
	for _, c in ipairs({{-2, 3}, {0, 3}, {2, 3}, {-1, 4}, {1, 4}}) do
		set(c[1], 1, c[2], "rockmech:camp_chair", 2)       -- 學生椅轉過來面向教授
	end
	local key = rockmech.career_vendor_spots
	local list = core.deserialize(storage:get_string(key)) or {}
	local pp = at(0, 0, 0)
	list[#list + 1] = {kind = "professor", pos = {x = pp.x, y = y + 0.5, z = pp.z}, yaw = yaw}
	storage:set_string(key, core.serialize(list))
end

-- 已經蓋好的營地補上講堂
if cfg.career then
	core.after(3, function()
		local sites = {}
		if storage:get_string("career_site") == "2" then sites[#sites + 1] = cfg.career_camp_dx end
		if rockmech.team_site_x then
			for i = 1, cfg.career_teams do
				if storage:get_string("team_site:" .. i) == "1" then sites[#sites + 1] = rockmech.team_site_x(tostring(i)) end
			end
		end
		for _, x0 in ipairs(sites) do
			if storage:get_string(prof_flag(x0)) == "" then
				local cx = x0 + PROF_DX
				core.emerge_area({x = cx - 8, y = -30, z = PROF_Z - 8}, {x = cx + 8, y = 40, z = PROF_Z + 8}, function(_, _, rem)
					if rem > 0 then return end
					if storage:get_string(prof_flag(x0)) == "" then
						rockmech.career_build_professor(x0)
						core.log("action", ("[rockmech] 營地 x = %d 加上大學教授的講堂"):format(x0))
					end
				end)
			end
		end
	end)
end

---------------------------------------------------------------------------
-- 個人資料頁（背包 I 的分頁）：組別、資金、三種能力有沒有、從哪來、怎麼取得
---------------------------------------------------------------------------

if core.get_modpath("sfinv") and sfinv and cfg.career then
	local F = core.formspec_escape
	local HOW = {
		grade = S("Buy an XRF analyzer, hire a geologist, or take the professor's exam"),
		rockmass = S("Buy a GSI chart, hire a geologist, or take the professor's exam"),
		mechanics = S("Buy a geological compass, hire a geologist, or take the professor's exam"),
	}
	sfinv.register_page("rockmech:profile", {
		title = S("Profile"),
		get = function(self, player, context)
			local name = player:get_player_name()
			local team = rockmech.team_of and rockmech.team_of(name)
			local fs = {("label[0,0;%s]"):format(F(("%s  %s"):format(name, team and S("Team @1", tostring(team)) or S("No team"))))}
			if rockmech.has_account and rockmech.has_account(name) then
				fs[#fs + 1] = ("label[0,0.5;%s]"):format(F(S("Funds: $@1", ("%.0f"):format(rockmech.money(name)))))
			end
			fs[#fs + 1] = ("label[0,1.2;%s]"):format(F(S("Your abilities")))
			local y = 1.7
			for _, a in ipairs(ABILITIES) do
				local has, src = ability_status(name, a.key)
				fs[#fs + 1] = ("label[0,%g;%s]"):format(y, F((has and "● " or "○ ") .. S(a.label)))
				if has then
					fs[#fs + 1] = ("label[2.4,%g;%s]"):format(y, F(S("Source: @1", src)))
				else
					local cd = cooldown_left(player, a.key)
					local how = HOW[a.key] or ""
				fs[#fs + 1] = ("label[2.4,%g;%s]"):format(y, F(cd > 0 and S("@1 (retake in @2)", how, mmss(cd)) or how))
				end
				y = y + 0.6
			end
			fs[#fs + 1] = ("label[0,%g;%s]"):format(y + 0.3, F(S("Grade assessment: grades   Rock mass classification: lithology, GSI, overburden thickness   Rock mechanics: stress, factor of safety, cracks")))
			if rockmech.nick_formspec then
				fs[#fs + 1] = rockmech.nick_formspec(name, y + 1.2)
				local m = rockmech.nick_message(name)
				if m then fs[#fs + 1] = ("label[0,%g;%s]"):format(y + 2.6, F(m)) end
			end
			return sfinv.make_formspec(player, context, table.concat(fs), false)
		end,
	})
end
