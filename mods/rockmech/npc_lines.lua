-- rockmech/npc_lines.lua
-- NPC 的台詞：右鍵跟 NPC 互動時，頭上冒出對話泡泡說一句（npc_talk.lua）。
-- 每種 NPC 一個清單，隨機挑一句（不會連續兩次同一句）。要改說什麼就改這裡（中文在 locale/rockmech.zh_TW.tr）。

local S = rockmech.S

return {
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
