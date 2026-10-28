-- mm_title：進入世界時的標題畫面（背景插圖、標題、開始遊戲／操作說明）。
-- 圖由 games/mining_sim/menu/make_menu_art.ps1 產生（主選單的 background.png、header.png 也是）

local W, H = 19.2, 10.8

local function frame()
	return "formspec_version[6]size[" .. W .. "," .. H .. "]padding[0,0]no_prepend[]"
		.. "bgcolor[#000000;both;#000000]"
		.. "image[0,0;" .. W .. "," .. H .. ";mm_title_bg.png]"
end

local BUTTONS = "style_type[button;font=bold;font_size=*1.5;textcolor=#f4e6c8;bgcolor=#2a2016;border=false]"
	.. "style_type[button:hovered;bgcolor=#6a4a18;textcolor=#ffffff]"

local function main_formspec()
	return frame()
		.. "image[3.6,1.0;12,2.49;mm_title_logo.png]"
		.. BUTTONS
		.. "button[7.1,6.2;5,1;start;開始遊戲]"
		.. "button[7.1,7.5;5,1;help;操作說明]"
		.. "style_type[label;font_size=*0.9;textcolor=#a09080]"
		.. "label[0.4," .. (H - 0.4) .. ";Mining Mechanics · rockmech]"
end

local HELP = table.concat({
	"<global margin=12 color=#f4e6c8 size=17>",
	"<big><b><style color=#ffcf60>操作說明</style></b></big>\n\n",
	"<b><style color=#ffcf60>基本</style></b>\n",
	"WASD 移動　空白鍵 跳　Shift 蹲下　I 物品欄（創造模式可拿所有工具與車輛）\n\n",
	"<b><style color=#ffcf60>地質與岩石力學</style></b>\n",
	"<b>地質羅盤</b>：右鍵一格岩石，顯示岩性、深度、應力、節理與破壞判定\n",
	"岩面出現<b>裂紋</b>代表快撐不住（安全係數 1～1.5）；安全係數 ≤ 1 就崩落。用岩柱撐住，或縮小開挖跨度\n\n",
	"<b><style color=#ffcf60>鑽孔爆破</style></b>\n",
	"<b>鑿岩機</b>：對岩面按住左鍵鑽孔\n",
	"<b>乳膠炸藥</b>：對鑽孔按右鍵裝藥（一孔最多 4 條）；沒鑽孔只能貼面，威力很小\n",
	"<b>打火石</b>：點一個裝藥孔，4 秒後爆　<b>起爆器</b>：右鍵，30 m 內的裝藥倒數 5 秒後依序起爆\n",
	"旁邊有<b>自由面</b>（空間、碎石、沒裝藥的空孔）威力較大：先鑽空孔或先炸中間的孔（拔心），外圈再炸\n\n",
	"<b><style color=#ffcf60>車輛</style></b>\n",
	"右鍵上車　Shift 下車　W／S 前進後退　A／D 轉向　Z 切換追蹤相機　左鍵（不在車上）收回\n",
	"<b>挖土機</b>：E 挖滑鼠指的位置、空白鍵倒出（指著卡車就倒進車斗）\n",
	"<b>卡車／礦卡</b>：空白鍵抬起車斗倒在車尾；直線行駛會加速，陡坡上不去\n",
	"<b>推土機</b>：E 放鏟／收鏟；放鏟往前開把碎石推走\n",
})

local function help_formspec()
	return frame()
		.. "box[1.2,0.6;" .. (W - 2.4) .. "," .. (H - 2.2) .. ";#0c0a08d8]"
		.. "hypertext[1.6,0.9;" .. (W - 3.2) .. "," .. (H - 2.8) .. ";help;" .. core.formspec_escape(HELP) .. "]"
		.. BUTTONS
		.. "button[7.1," .. (H - 1.35) .. ";5,0.9;back;返回]"
end

core.register_on_joinplayer(function(player)
	local name = player:get_player_name()
	core.after(0.3, function()
		if core.get_player_by_name(name) then core.show_formspec(name, "mm_title:main", main_formspec()) end
	end)
end)

core.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= "mm_title:main" and formname ~= "mm_title:help" then return end
	local name = player:get_player_name()
	if fields.start then
		core.close_formspec(name, formname)
	elseif fields.help then
		core.show_formspec(name, "mm_title:help", help_formspec())
	elseif fields.back then
		core.show_formspec(name, "mm_title:main", main_formspec())
	end
	return true
end)
