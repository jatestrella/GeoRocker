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
	["rockmech:npc_analyst"] = {S("My last forecast? Let's not talk about it."), S("Past performance does not guarantee future results.")},
	["rockmech:npc_buyer"] = {S("The plant burns two thousand tons a day."), S("Our boilers do not like shale.")},
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
	["rockmech:npc_analyst"] = {
		S("Low grade at a low price is just waste."),
		S("When prices fall, the cut-off grade rises."),
		S("Wars move oil; oil moves everything."),
	},
	["rockmech:npc_buyer"] = {
		S("Need an order? The price is locked when you sign."),
		S("Below spec and the whole truck goes back."),
		S("Mix high and low grade, just above spec."),
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
-- 考試科目的重點：不給題庫，分給跟它有關的 NPC 在閒聊裡講
local function more(who, list) for _, l in ipairs(list) do table.insert(LINES[who], l) end end
more("rockmech:npc_geologist", {
	S("Waste mixed into ore dilutes the grade. That is dilution."),
	S("A blended grade is weighted by tonnes, not a plain average."),
})
more("rockmech:npc_mechanic", {
	S("Recovery is the valuable part in the product over the valuable part in the feed."),
})
more("rockmech:vendor_geo", {
	S("RQD only counts intact core pieces of 10 cm or more."),
	S("GSI looks at two things: the rock structure and the joint surfaces."),
	S("A joint's attitude is its dip and dip direction."),
})
more("rockmech:vendor_geotech", {
	S("Vertical stress is about unit weight times depth."),
	S("A safety factor below 1 means the driving force wins."),
	S("Planar sliding needs a joint flatter than the slope but steeper than its friction angle."),
	S("If the joint strikes far off the slope face, the block cannot slide out."),
	S("Toppling comes from steep joints dipping into the slope."),
	S("For a wedge, look at the line where the two joints meet."),
})
more("rockmech:npc_professor", {
	S("Rock is weak in tension, about a tenth of its compressive strength."),
	S("The Mohr circle's centre is the mean of σ1 and σ3; its radius is half their difference."),
	S("Once the circle touches the envelope, the rock fails."),
	S("Raise σ3 and the circle shrinks away from the envelope."),
	S("Pore pressure pushes the Mohr circle toward failure."),
})
more("rockmech:vendor_civil", {
	S("The stripping ratio is waste over ore. It usually grows as the pit deepens."),
	S("When stripping costs too much, think about going underground."),
	S("Steeper walls mean less stripping. Check the safety factor first."),
})
-- 有火車的地圖（教學地圖，train.lua）：收煤站坑口價、火車原價、晚上沒車
local cfg = rockmech.cfg
if cfg.career and cfg.teacher and cfg.coal_seam and cfg.coal_seam.lane_w then
	more("rockmech:npc_buyer", {S("The coal yard pays less. Load the train yourself and you get more.")})
	more("rockmech:npc_analyst", {S("The coal yard pays a pit-head price. The train pays full price."), S("No trains at night. Stockpile your coal.")})
	more("rockmech:vendor_civil", {S("The coal yard buys any time, but not at full price.")})
end
LINES.chatter, LINES.own_chatter = chatter, own     -- 不是實體名稱（npc_talk.lua 會跳過）
return LINES
