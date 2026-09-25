--!strict
-- Conquest :: /scene  (client only -- there is no server half)
--
--   /scene   clears the screen down to the board.
--   /scene1  puts it back.
--
-- V2, AFTER V1 FOUGHT THE HUD AND LOST. The first cut hid panels one at a
-- time and re-hid them on a timer. The HUD re-shows itself constantly -- the
-- shop, the alliance tab, the bar across the top -- so everything strobed at
-- 4 Hz, and whatever was rebuilt between two passes (cards) simply stayed up.
--
-- So do not hide the HUD. COVER IT. The map is lifted into a ScreenGui at the
-- maximum DisplayOrder, which draws over every other ScreenGui no matter what
-- any of them do with Enabled or Visible, and the desk inside the map's own
-- viewport is opaque and full-screen, so the cover is total. Nothing else on
-- screen is touched, which means there is nothing to restore but one Parent --
-- and no property for another script to fight over.
--
-- WHY THE MAP CAN BE LIFTED. ConquestClient builds ONE ScreenGui ("Conquest")
-- holding the map ("Viewport") and every panel as SIBLINGS of it. The new gui
-- copies the two properties the map's layout depends on -- IgnoreGuiInset and
-- ZIndexBehavior.Sibling -- so geometry is unchanged, and panning, zooming and
-- clicking the map keep working while the scene is up.
--
-- Nation names, cities, boats and warheads live inside the map container and
-- come along: they are the board. The tutorial's ring, pulse and off-screen
-- chevron ride along too but are coaching, not board, so those go by name.
--
-- CHAT AND THE ROBLOX TOPBAR ARE LEFT ALONE. CoreGui draws above every
-- ScreenGui, so they cannot be covered, and with chat off there would be no
-- way left to type /scene1.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local TextChatService = game:GetService("TextChatService")

local MAP_GUI = "Conquest"
local MAP_LAYER = "Viewport"
local MAP_BODY = "Map"
local SCENE_GUI = "SceneView"
local COACH = "Tutorial"

-- Core gui that is safe to drop for a clean shot. Chat is not in this list.
local CORE = {
	Enum.CoreGuiType.PlayerList,
	Enum.CoreGuiType.Backpack,
	Enum.CoreGuiType.Health,
	Enum.CoreGuiType.EmotesMenu,
}

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local scene = false
local cover: ScreenGui? = nil
local held: GuiObject? = nil -- the map layer, while it is ours
local home: Instance? = nil -- the gui it came out of
local coachWas: { [GuiObject]: boolean } = {}
local coreWas: { [Enum.CoreGuiType]: boolean } = {}
local tick: RBXScriptConnection? = nil

local function sceneGui(): ScreenGui
	local g = cover
	if g ~= nil and g.Parent == nil then
		g = nil
	end
	if g == nil then
		g = Instance.new("ScreenGui")
		g.Name = SCENE_GUI
		g.IgnoreGuiInset = true
		g.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		g.ResetOnSpawn = false
		g.DisplayOrder = 2147483647
		g.Parent = playerGui
		cover = g
	end
	g.Enabled = true
	return g
end

-- Coaching marks are the one thing inside the map that is not the map.
local function dropCoaching(parent: Instance)
	for _, c in parent:GetChildren() do
		if c:IsA("GuiObject") and string.sub(c.Name, 1, #COACH) == COACH then
			if coachWas[c] == nil then
				coachWas[c] = c.Visible
			end
			c.Visible = false
		end
	end
end

-- Idempotent, and cheap enough to run on a slow timer: that timer is only
-- here to catch a map that arrives AFTER the scene was asked for (the lobby,
-- or a round starting) and to keep new coaching marks down. It is not fighting
-- anybody, so nothing flickers.
local function apply()
	local g = sceneGui()
	if held ~= nil and held.Parent == nil then
		held, home = nil, nil
	end
	if held == nil then
		local gui = playerGui:FindFirstChild(MAP_GUI)
		local v = if gui ~= nil then gui:FindFirstChild(MAP_LAYER) else nil
		if v ~= nil and v:IsA("GuiObject") then
			held, home = v, v.Parent
		end
	end
	local v = held
	if v ~= nil then
		if v.Parent ~= g then
			v.Parent = g
		end
		dropCoaching(v)
		local body = v:FindFirstChild(MAP_BODY)
		if body ~= nil then
			dropCoaching(body)
		end
	end
end

local function release()
	local v = held
	local back = home
	if v ~= nil and v.Parent ~= nil and back ~= nil and back.Parent ~= nil then
		-- THE MAP COMES HOME AS THE LAST CHILD, AND THAT MATTERS. Every panel in
		-- that gui sits at ZIndex 1, exactly like the map layer, and a tie under
		-- ZIndexBehavior.Sibling is broken by CHILD ORDER -- so a map put back at
		-- the end of the list draws over the whole HUD and /scene1 looks like it
		-- did nothing (measured: standings, rail, command bar and clock all gone,
		-- while the shop and alliance tabs, which are separate ScreenGuis at a
		-- higher DisplayOrder, came back fine and made it look half-broken).
		-- ZIndex 0 says "bottom" without depending on order at all, which is what
		-- being the first child always meant here, so it is left at 0.
		v.ZIndex = 0
		v.Parent = back
	end
	held, home = nil, nil
	for obj, was in coachWas do
		if obj.Parent ~= nil then
			obj.Visible = was
		end
	end
	table.clear(coachWas)
	local g = cover
	if g ~= nil then
		-- Only destroy it empty. If the match gui went away while the scene
		-- was up there is nowhere to put the map back, and taking the cover
		-- with it would take the map too.
		if g:FindFirstChildWhichIsA("GuiObject") == nil then
			g:Destroy()
			cover = nil
		else
			g.Enabled = false
		end
	end
end

local function core(on: boolean)
	for _, kind in CORE do
		if on then
			local was = coreWas[kind]
			if was ~= nil then
				pcall(function()
					StarterGui:SetCoreGuiEnabled(kind, was)
				end)
			end
		else
			if coreWas[kind] == nil then
				local ok, v = pcall(function()
					return StarterGui:GetCoreGuiEnabled(kind)
				end)
				if ok and typeof(v) == "boolean" then
					coreWas[kind] = v
				else
					coreWas[kind] = true
				end
			end
			pcall(function()
				StarterGui:SetCoreGuiEnabled(kind, false)
			end)
		end
	end
	if on then
		table.clear(coreWas)
	end
end

local function enter()
	if scene then
		apply()
		return
	end
	scene = true
	apply()
	core(false)
	local t = 0
	tick = RunService.Heartbeat:Connect(function(dt: number)
		t += dt
		if t >= 0.5 then
			t = 0
			apply()
		end
	end)
	if held == nil then
		print("[scene] no map on screen yet -- it will be cleared the moment one is")
	else
		print("[scene] board only -- type /scene1 to bring the HUD back")
	end
end

local function leave()
	if not scene then
		return
	end
	scene = false
	if tick ~= nil then
		tick:Disconnect()
		tick = nil
	end
	release()
	core(true)
	print("[scene] HUD restored")
end

-- The command is caught HERE and nowhere else: nothing about this leaves the
-- local screen, so there is no remote and no server half. A command saved in
-- the place is used when it is there; if it is missing, one is made locally,
-- which the chat matches just the same.
local function bind(name: string, alias: string, fn: () -> ())
	local cmd = TextChatService:FindFirstChild(name)
	if cmd == nil then
		cmd = TextChatService:WaitForChild(name, 10)
	end
	if cmd == nil or not cmd:IsA("TextChatCommand") then
		local made = Instance.new("TextChatCommand")
		made.Name = name
		made.PrimaryAlias = alias
		made.AutocompleteVisible = false
		made.Parent = TextChatService
		cmd = made
	end
	if cmd ~= nil and cmd:IsA("TextChatCommand") then
		cmd.Triggered:Connect(fn)
	end
end

bind("SceneCommand", "/scene", enter)
bind("SceneOnCommand", "/scene1", leave)
