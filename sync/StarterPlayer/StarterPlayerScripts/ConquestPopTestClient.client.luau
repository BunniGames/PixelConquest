--!strict
-- Conquest :: /testmaxpop + /testpop + /testsfx  (client only)
--
-- HEARING THE CEILING WITHOUT PLAYING A BLITZ (owner, 2026-09-12). The pop
-- rate is the one part of the mix that only shows itself at the TOP of its
-- range, and the top of its range wants a front moving a hundred and forty
-- tiles a second -- a late round, on a big map, with an empire already
-- collapsing. That is a long way to walk to find out whether two strikes a
-- packet smear into a buzz.
--
-- NO SERVER HALF, and the only Conquest command without one. Every other
-- (/gold, /endgame, /world, /simulate) is caught on the client because the
-- SERVER is what has to act on it; this one changes nothing but what comes out
-- of the local speakers, so there is nothing to send and nobody to tell. The
-- TextChatCommand is therefore MADE here rather than waited for -- one
-- parented to TextChatService on the client is triggered by that client's own
-- chat, and needs no replication to do it.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TextChatService = game:GetService("TextChatService")

local Sfx = require(ReplicatedStorage:WaitForChild("Conquest"):WaitForChild("Sfx"))

-- The same gate the server commands use, asked locally. A courtesy rather than
-- a boundary -- the worst a stranger does with this is pop their own speakers
-- for six seconds -- but a stray /testmaxpop in a live round should not be
-- something a player can do to themselves by accident.
local function allowed(): boolean
	if RunService:IsStudio() then
		return true
	end
	local me = Players.LocalPlayer
	return game.CreatorType == Enum.CreatorType.User and me ~= nil and me.UserId == game.CreatorId
end

local function channel(): TextChannel?
	local channels = TextChatService:FindFirstChild("TextChannels")
	if not channels then
		return nil
	end
	return (channels:FindFirstChild("RBXGeneral") or channels:FindFirstChildWhichIsA("TextChannel")) :: TextChannel?
end

local function tell(line: string)
	print("[pop] " .. line)
	local ch = channel()
	if ch then
		ch:DisplaySystemMessage('<font color="#8CD5FF">' .. line .. "</font>")
	end
end

local function command(name: string, primary: string, secondary: string): TextChatCommand
	local found = TextChatService:FindFirstChild(name)
	if found and found:IsA("TextChatCommand") then
		return found
	end
	local c = Instance.new("TextChatCommand")
	c.Name = name
	c.PrimaryAlias = primary
	c.SecondaryAlias = secondary
	c.Parent = TextChatService
	return c
end

command("TestMaxPopCommand", "/testmaxpop", "/popmax").Triggered:Connect(function(_source, text)
	if not allowed() then
		tell("/testmaxpop is for the owner only.")
		return
	end
	-- An optional length, because six seconds is the right answer to "does it
	-- smear" and far too short for tuning POP_SPACING against the sample by ear.
	local secs = math.clamp(tonumber(string.match(text, "%d+%.?%d*") or "") or 6, 1, 30)
	tell(string.format("ceiling for %.0fs -- pitch sweeps low to high", secs))
	Sfx.testMaxPop(secs)
end)

-- THE LADDER -- "fit to different expansion speeds", in order, so the fit can
-- be judged by ear instead of from a table.
--
-- Every rung is a front speed the /simulate harness actually measured on a
-- human-weighted empire, and the PITCH IS PINNED across all of them, so the
-- only thing changing from rung to rung is the rate. Under the old linear map
-- every rung from p50 up was the same twenty a second; now only the last two
-- are, and that is the packet ceiling being honest rather than the curve
-- failing -- a map-wide collapse genuinely cannot sound faster than a blitz.
local LADDER: { { n: string, s: number } } = {
	{ n = "p10  crawl", s = 40 },
	{ n = "p25  slow push", s = 100 },
	{ n = "p50  typical", s = 180 },
	{ n = "p75  strong push", s = 300 },
	{ n = "p95  blitz", s = 670 },
	{ n = "max  collapse", s = 1400 },
}

command("TestPopCommand", "/testpop", "/popladder").Triggered:Connect(function(_source, _text)
	if not allowed() then
		tell("/testpop is for the owner only.")
		return
	end
	task.spawn(function()
		for _, rung in LADDER do
			-- The rate is asked of the CURVE rather than written down here, so a
			-- retune can never leave the ladder announcing numbers the mix has
			-- stopped playing.
			tell(string.format("%s -- %d tiles/s -> %.1f pops/s", rung.n, rung.s, Sfx.popRateAt(rung.s)))
			Sfx.testSpeed(rung.s, 2.5)
			-- A beat of silence between rungs, or the ear carries the last rate
			-- into the next one and every step sounds smaller than it is.
			task.wait(3.1)
		end
		tell("ladder done")
	end)
end)

-- ==================================================================== /testsfx

-- AUDITION A CUE WITHOUT PLAYING THE GAME (owner, 2026-09-15, after three
-- rounds of "I can't hear it"). The countdown beep only happens in a spawn
-- phase and the interception only when a tower you own kills a warhead somebody
-- else fired -- so "is it silent?" was taking a whole round to ask, and could
-- not distinguish the two things it might mean:
--
--   THE LEVEL IS WRONG        -- you hear it, quietly
--   THE TRIGGER NEVER FIRED   -- you hear nothing, and no volume fixes that
--
-- This asks the first question directly. If /testsfx is loud and the game is
-- silent, the mix is fine and the fault is upstream in whatever was supposed to
-- call it. That is the split three passes of turning knobs could not make.
--
--   /testsfx              the countdown run, then the interception
--   /testsfx intercept    one cue by name (any cue: blast, pop, click...)
--   /testsfx tick

-- A DIAGNOSTIC MIRROR of Sfx's own cue lookup, deliberately duplicated: the
-- point is to report what the lookup FINDS (or fails to), which the module has
-- no public way to ask. Keep it in step with `resolve` -- exact name first,
-- then the child leading with "<cue> - ".
local function soundFor(cue: string): Sound?
	local SoundService = game:GetService("SoundService")
	local exact = SoundService:FindFirstChild(cue)
	if exact and exact:IsA("Sound") then
		return exact
	end
	local lead = cue .. " - "
	for _, c in SoundService:GetDescendants() do
		if c:IsA("Sound") and string.sub(c.Name, 1, #lead) == lead then
			return c
		end
	end
	return nil
end

-- Says what the cue resolved to BEFORE playing it, so a silent result is
-- already explained on the line above it.
local function announce(cue: string): boolean
	local s = soundFor(cue)
	if s == nil then
		tell(string.format("%s -- NO SOUND BEHIND THIS CUE. Nothing in SoundService is named "
			.. "'%s' or starts with '%s - ', so it is silent by design, not broken.", cue, cue, cue))
		return false
	end
	tell(string.format("%s -> '%s'  vol=%.2f  len=%.2fs  group=%s",
		cue, s.Name, s.Volume, s.TimeLength, tostring(s.SoundGroup and s.SoundGroup.Name or "none")))
	return true
end

command("TestSfxCommand", "/testsfx", "/sfx").Triggered:Connect(function(_source, text)
	if not allowed() then
		tell("/testsfx is for the owner only.")
		return
	end
	local arg = string.lower(string.match(text, "^%s*/%a+%s+(%S+)") or "")
	if arg ~= "" then
		-- Cue names are capitalised; the chat box will not be.
		local cue = string.upper(string.sub(arg, 1, 1)) .. string.sub(arg, 2)
		if announce(cue) then
			Sfx.play(cue)
		end
		return
	end

	task.spawn(function()
		-- THE COUNTDOWN, at the pitches HUD.setTimer actually uses, so this is
		-- the run you will hear in a real round rather than an approximation.
		-- Mirrors CLOCK_LAST_SECONDS = 5 and the 1 + 0.15k ramp; if that is
		-- retuned, retune it here or this quietly starts telling lies.
		if announce("Tick") then
			tell("countdown 5..1 -- pitch rises; zero is SILENT")
			-- The zero tick is gone from HUD.setTimer (it dropped below the
			-- ramp's opening note); this mirrors that, or the harness lies.
			for whole = 5, 1, -1 do
				Sfx.play("Tick", { pitch = 1 + 0.15 * ((5 - whole) / 5) })
				task.wait(1)
			end
		end
		task.wait(0.6)
		-- THE INTERCEPTION. `play`, not `playAt`: this is the cue at full gain,
		-- which is what the floor of 0.9 in Missiles very nearly delivers anyway.
		if announce("Intercept") then
			tell("interception")
			Sfx.play("Intercept")
		end
		tell("done -- if THIS was audible and the game is not, the sound is fine "
			.. "and the trigger is the problem")
	end)
end)
