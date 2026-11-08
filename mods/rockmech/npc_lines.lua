-- rockmech/npc_lines.lua
-- NPC 的台詞：右鍵跟 NPC 互動時，頭上冒出對話泡泡說一句（npc_talk.lua）。
-- 每種 NPC 一個清單，隨機挑一句（不會連續兩次同一句）。要改說什麼就改這裡（中文在 locale/rockmech.zh_TW.tr）。

local S = rockmech.S


-- 廢話：偶爾（npc_talk.lua 的 CHATTER_P）不講正事，從大家都會講的和自己的廢話裡挑一句
local chatter = {
	S("Pork chop lunch box again today."),
	S("Is it going to rain this afternoon?"),
	S("My back is killing me."),
	S("I could really use a bubble tea."),
	S("The office AC is broken again."),
	S("Payday is still so far away."),
	S("Who took my hard hat?"),
	S("The mosquitoes up here are huge."),
	S("My kid says I smell like diesel."),
	S("The vending machine coffee tastes like rock dust."),
	S("I parked my scooter around here somewhere..."),
	S("Did you watch the game last night?"),
	S("The boss visits this week. Look busy."),
	S("The phone signal out here is awful."),
}
local own = {
	["rockmech:vendor_vehicle"] = {S("I washed that truck yesterday. Look at it now.")},
	["rockmech:vendor_blast"] = {S("Huh? Say again? My ears aren't great."), S("TSMC is no fun compared with the mine.")},
	["rockmech:npc_professor"] = {S("In my day we drew stereonets by hand."), S("Three papers due and still no data."), S("Sigh, you little miners."), S("Please don't use this game as material for your admission report."), S("Anyone want to do a PhD?")},
	["rockmech:npc_mechanic"] = {S("Who keeps getting gravel in the gearbox?")},
	["rockmech:npc_geologist"] = {S("What a beautiful rock. Please don't blast it."), S("We should grab a beer later.")},
	["rockmech:operator_seated"] = {S("Five more minutes.")},
	["rockmech:vendor_civil"] = {S("Did you know there are fewer than ten practicing mining engineers in all of Taiwan?")},
	["rockmech:vendor_geotech"] = {S("I heard someone took ten years to pass the engineer exam.")},
}

local LINES = {
	["rockmech:vendor_vehicle"] = {
		S("What do you need? Trucks, excavators, crushers, all here."),
		S("Every machine burns diesel. Count the fuel bill."),
		S("Keep loaded trucks off steep ramps."),
	},
	["rockmech:vendor_blast"] = {
		S("Stay well back from the face when you fire."),
		S("Fire the cut holes first, then the outer ring has a free face."),
		S("Wait for the fumes to clear before you go back in."),
	},
	["rockmech:vendor_tools"] = {
		S("Bolts and shotcrete hold the face up."),
		S("Tap the rock with a Schmidt hammer first."),
		S("Anything small, I've got it."),
	},
	["rockmech:vendor_geo"] = {
		S("Measure the joints before you dig."),
		S("Keep everything in the field notebook."),
		S("The core never lies."),
	},
	["rockmech:vendor_geotech"] = {
		S("Test the rock first, then design the support."),
		S("Bolt it before it moves."),
		S("A prism tells you a slope is moving long before you see it."),
	},
	["rockmech:vendor_civil"] = {
		S("Crushers, plants, belts, ventilation: I design them all."),
		S("A hopper needs flat ground."),
		S("Dig deeper and you will need a fan."),
	},
	["rockmech:vendor"] = {
		S("Need supplies?"),
	},
	["rockmech:npc_mechanic"] = {
		S("Broken machine? I can fix it."),
		S("Worn vehicles run slow."),
	},
	["rockmech:npc_geologist"] = {
		S("Joints decide how the rock fails."),
		S("Read the cores before you dig."),
	},
	["rockmech:geologist_follower"] = {
		S("Take me to the rock."),
		S("Dense joints here. Watch for falls."),
	},
	["rockmech:npc_professor"] = {
		S("Ready for an exam?"),
		S("Rock mechanics is stress against strength."),
	},
	["rockmech:operator_npc"] = {
		S("Tell me where to dig."),
		S("Bucket's ready."),
	},
	["rockmech:operator_seated"] = {
		S("Taking a break."),
		S("Need me on a machine?"),
	},
}
LINES.chatter, LINES.own_chatter = chatter, own     -- 不是實體名稱（npc_talk.lua 會跳過）
return LINES
