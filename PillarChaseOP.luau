--[[
	Pillar Chase - Role Highlight Hub  (v2)
	Place 121255181515820  (Pillar Chase 2 / Halloween PT1)

	UI
	  Dark "Product Faker"-style window: Roboto Condensed typography, near
	  black panels, a centred floating window with shadow + hairline stroke,
	  a bottom icon rail with a sliding indicator, toast notifications and
	  scramble / fade / scale animations. Seven tabs: Roles, Visuals, HUD,
	  Tasks, Teleport, Extras, Info.

	FEATURES
	  * Role highlights: Monster=red, Survivor=green, Sentinel=amber (+Unknown)
	  * See-through-walls, fill opacity, per-role colour presets
	  * Name / role / distance labels
	  * Off-screen direction arrows, tracers, monster proximity alert
	  * Always-on status HUD (survivors alive, monster distance, your role)
	  * Tasks: objective ESP on every map + auto-collect.  It scans the map
	    and round FIRST; if you are not in a game (no map) or you are dead it
	    does nothing and the readout says "Not in game.".  Collection handles
	    both touch shards and ProximityPrompt objectives (snow, trash, blood,
	    keypads, valves, generators).
	  * Utility: anti-AFK, fullbright, no fog, noclip, FOV zoom, exit ESP,
	    crosshair, fps/ping
	  * Unlocks the mouse while the window is open (the game force-locks it,
	    which is why buttons were unclickable), restored automatically

	SAFETY
	  Everything here is LOCAL: Highlight, BillboardGui and the overlay are
	  never replicated, the server never sees them, and no game logic,
	  movement or hit detection is touched. No hooks, no remotes.

	ROLE DETECTION (verified live)
	  Character:GetAttribute("Type") == "Monster" / "Survivor" / "Sentinel"
	  Player:GetAttribute("EndCondition") == "MONSTER" (backup)
	  Anything else -> "Unknown" (never silently hidden).
]]

if game.PlaceId ~= 121255181515820 then
	return
end

-- single instance: if a previous build of this hub is still running (e.g. an
-- autoexec copy plus a manual run), tear it down first so two windows never
-- fight over the same key and the same scratch folders.
do
	local prev = getgenv and getgenv().PillarChaseHub
	if prev and type(prev.destroy) == "function" then
		pcall(prev.destroy)
	end
end

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local CoreGui = game:GetService("CoreGui")
local Workspace = workspace

local LP = Players.LocalPlayer
local genv = (type(getgenv) == "function" and getgenv()) or _G

-- replace a previous instance from this session (never stack on re-run)
local previous = genv.PillarChaseHub
if type(previous) == "table" and type(previous.destroy) == "function" then
	pcall(previous.destroy)
end

-- ==========================================================================
-- state
-- ==========================================================================

local DEFAULTS = {
	enabled = true,
	throughWalls = true,
	fillTransparency = 0.55,
	outlineTransparency = 0.05,
	labels = true,
	showRole = true,
	showDistance = true,
	maxDist = 5000,
	self = false,
	freeMouse = true,
	hud = true,
	tracers = false,
	offscreen = true,
	monsterAlert = true,
	alertDist = 150,
	shardEsp = true,
	shardColor = { 90, 240, 255 },
	autoCollect = true,
	collectDelay = 0.05,
	collectHeight = 2,
	-- which ObjectiveInteract* group the auto-collector works on: "All", or a
	-- group's own folder name (e.g. "ObjectiveInteract2").  Doing one task at a
	-- time is far more reliable than sweeping every objective on a map.
	taskGroup = "All",
	-- utility
	infiniteStamina = true,
	antiAfk = true,
	fullbright = false,
	noFog = false,
	noclip = false,
	voidRescue = true,
	speedMult = 1,
	shiftlock = false,
	taskSafety = true,
	taskSafetyDist = 40,
	instantPrompt = true,
	hitboxMult = 1,
	skinSpoof = true,
	cameraFov = 70,
	exitEsp = true,
	exitColor = { 255, 140, 40 },
	crosshair = false,
	crosshairColor = { 120, 255, 160 },
	fpsCounter = true,
	pingCounter = true,
	roles = {
		Monster = true,
		Survivor = true,
		Sentinel = true,
		Unknown = false,
	},
	colors = {
		Monster = { 255, 45, 60 },
		Survivor = { 60, 220, 110 },
		Sentinel = { 255, 190, 40 },
		Unknown = { 170, 175, 190 },
		Self = { 80, 200, 255 },
	},
	keybind = "K",
}

local STATE = {}
for k, v in pairs(DEFAULTS) do
	if type(v) == "table" then
		local t = {}
		for k2, v2 in pairs(v) do
			t[k2] = (type(v2) == "table") and { v2[1], v2[2], v2[3] } or v2
		end
		STATE[k] = t
	else
		STATE[k] = v
	end
end

local CONFIG_FILE = "pillar-chase-hub.json"

-- Toggles that must NOT be restored from disk.  The auto-farm is meant to be on
-- out of the box; a stale saved value (from a session where it was toggled off,
-- or a config written by an older build) would otherwise silently ship the hub
-- with the farm disabled.  The code default is the single source of truth here.
local NO_PERSIST = { autoCollect = true }

local function deepCopy(t)
	local out = {}
	for k, v in pairs(t) do
		out[k] = (type(v) == "table") and deepCopy(v) or v
	end
	return out
end

local function saveConfig()
	pcall(function()
		if type(writefile) ~= "function" then
			return
		end
		local function ser(v)
			local tv = type(v)
			if tv == "number" or tv == "boolean" then
				return tostring(v)
			elseif tv == "string" then
				return string.format("%q", v)
			elseif tv == "table" then
				local parts = {}
				for k, vv in pairs(v) do
					-- numeric keys (e.g. colour channels {255,45,60}) must stay
					-- numeric, otherwise they reload as c["1"] and every colour
					-- silently breaks.
					local key
					if type(k) == "number" then
						key = string.format("[%d]", k)
					else
						key = string.format("[%q]", tostring(k))
					end
					parts[#parts + 1] = key .. "=" .. ser(vv)
				end
				return "{" .. table.concat(parts, ",") .. "}"
			end
			return "nil"
		end
		local persist = {}
		for k, v in pairs(STATE) do
			if not NO_PERSIST[k] then
				persist[k] = v
			end
		end
		writefile(CONFIG_FILE, "return " .. ser(persist))
	end)
end

local function loadConfig()
	pcall(function()
		if type(isfile) ~= "function" or type(readfile) ~= "function" then
			return
		end
		if not isfile(CONFIG_FILE) then
			return
		end
		local fn = loadstring(readfile(CONFIG_FILE))
		if not fn then
			return
		end
		local saved = fn()
		if type(saved) ~= "table" then
			return
		end
		for k, v in pairs(saved) do
			if NO_PERSIST[k] then
				-- skip: keep the code default for this key
			elseif type(v) == "table" and type(STATE[k]) == "table" then
				for k2, v2 in pairs(v) do
					-- heal old configs where numeric keys were saved as strings
					local key = k2
					if type(k2) == "string" then
						local num = tonumber(k2)
						if num and tostring(num) == k2 then
							key = num
						end
					end
					STATE[k][key] = v2
				end
			else
				STATE[k] = v
			end
		end
	end)
end

loadConfig()

-- ==========================================================================
-- UI toolkit  ·  dark "Product Faker"-style skin
--   * Roboto Condensed typography, near-black panels
--   * centred floating window with shadow + hairline stroke
--   * bottom icon rail with a sliding active indicator
--   * toast notifications, scramble text, fade + scale animations
-- ==========================================================================

-- --------------------------------------------------------------------------
-- The UI layer is wrapped in a `do` block: its many one-off helpers must not
-- stay alive for the whole chunk (Luau allows 200 locals per function). Only
-- the names below are needed by the engines further down.
-- --------------------------------------------------------------------------
local THEME, rgb, new, corner, stroke, parentGui
local gui, win, Main, topbar, statusDot, selectTab, showWindow, hideWindow, closeNotice
local connections, colorSyncers, collectOneShard, hud
local infoStatus, infoMap, infoObj1, infoObj2, infoExit, infoShards
local infoRole, infoMonster, infoSurvivors, infoTracked, infoMouse
local keybindBtn, keybindCapturing, bannerText, bannerMap, bannerDot
local TP
do

local TweenService = game:GetService("TweenService")
local TextService = game:GetService("TextService")

THEME = {
	bg = Color3.fromRGB(8, 8, 10),
	panel = Color3.fromRGB(16, 16, 19),
	panel2 = Color3.fromRGB(26, 26, 30),
	line = Color3.fromRGB(255, 255, 255),
	accent = Color3.fromRGB(236, 238, 243),
	text = Color3.fromRGB(240, 242, 246),
	dim = Color3.fromRGB(150, 153, 162),
	icon = Color3.fromRGB(192, 195, 204),
	button = Color3.fromRGB(30, 30, 35),
	buttonHi = Color3.fromRGB(48, 49, 56),
	cardHover = Color3.fromRGB(22, 22, 26),
	active = Color3.fromRGB(70, 72, 80),
	on = Color3.fromRGB(236, 238, 243),
	off = Color3.fromRGB(40, 42, 48),
	danger = Color3.fromRGB(255, 72, 72),
	blue = Color3.fromRGB(150, 170, 210),
	yellow = Color3.fromRGB(238, 240, 200),
	-- legacy names still used by the world-space labels / overlay
	font = Enum.Font.Gotham,
	fontBold = Enum.Font.GothamBold,
}

local FONT = Font.new("rbxasset://fonts/families/RobotoCondensed.json", Enum.FontWeight.Regular, Enum.FontStyle.Normal)
local FONT_BOLD = Font.new("rbxasset://fonts/families/RobotoCondensed.json", Enum.FontWeight.Bold, Enum.FontStyle.Normal)
local FONT_ITALIC = Font.new("rbxasset://fonts/families/RobotoCondensed.json", Enum.FontWeight.Regular, Enum.FontStyle.Italic)

function rgb(c)
	if type(c) ~= "table" then
		return Color3.fromRGB(170, 175, 190)
	end
	local function ch(i)
		local v = c[i]
		if type(v) ~= "number" then
			v = c[tostring(i)]
		end
		if type(v) ~= "number" then
			v = 0
		end
		return math.floor(v + 0.5)
	end
	return Color3.fromRGB(ch(1), ch(2), ch(3))
end

-- Outline weight for the whole window.  Every UIStroke in the hub is built
-- through new(), so scaling Thickness right here makes the entire chrome
-- bolder at once - the window frame, cards, buttons, sliders, toggles and
-- icons - instead of hand-editing forty call sites.  Relative weights are
-- preserved (a 2 still reads twice as heavy as a 1).
local OUTLINE_SCALE = 2

function new(class, props, parent)
	local o = Instance.new(class)
	for k, v in pairs(props or {}) do
		if k ~= "Parent" then
			if class == "UIStroke" and k == "Thickness" and type(v) == "number" then
				v = v * OUTLINE_SCALE
			end
			o[k] = v
		end
	end
	if parent then
		o.Parent = parent
	end
	return o
end

local function onClick(button, fn)
	-- connect every click signal a GuiButton can emit, but never run twice for
	-- one physical press (a mouse click fires MouseButton1Click AND Activated).
	local last = 0
	local function fire()
		local now = os.clock()
		if now - last < 0.05 then
			return
		end
		last = now
		fn()
	end
	pcall(function() button.MouseButton1Click:Connect(fire) end)
	pcall(function() button.Activated:Connect(fire) end)
	pcall(function() button.TouchTap:Connect(fire) end)
end

function corner(parent, radius)
	return new("UICorner", { CornerRadius = UDim.new(0, radius or 10) }, parent)
end

-- hairline helper; new() applies OUTLINE_SCALE to the thickness
function stroke(parent, colour, thickness, transparency)
	return new("UIStroke", {
		Color = colour or Color3.fromRGB(255, 255, 255),
		Thickness = thickness or 1,
		Transparency = transparency or 0.86,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	}, parent)
end

function parentGui(g)
	local ok = pcall(function()
		g.Parent = CoreGui
	end)
	if not ok or g.Parent == nil then
		g.Parent = LP:WaitForChild("PlayerGui")
	end
end

local function tween(obj, t, props, style, dir)
	local tw = TweenService:Create(obj, TweenInfo.new(t, style or Enum.EasingStyle.Quint, dir or Enum.EasingDirection.Out), props)
	tw:Play()
	return tw
end

-- every connection we make goes here so destroy() can tear them all down
connections = {}
local function bind(signal, fn)
	local c = signal:Connect(fn)
	table.insert(connections, c)
	return c
end

-- fade: group transparency animation used for open / close / tab changes ----
local fadeProps = {
	{ "GuiObject", "BackgroundTransparency" },
	{ "TextLabel", "TextTransparency" },
	{ "TextButton", "TextTransparency" },
	{ "TextBox", "TextTransparency" },
	{ "ImageLabel", "ImageTransparency" },
	{ "ImageButton", "ImageTransparency" },
	{ "ScrollingFrame", "ScrollBarImageTransparency" },
	{ "UIStroke", "Transparency" },
}
local originals = {}
local fadeExclude = {}

local function getOriginal(inst)
	local o = originals[inst]
	if o then
		return o
	end
	o = {}
	for _, pair in ipairs(fadeProps) do
		local okIs, is = pcall(inst.IsA, inst, pair[1])
		if okIs and is then
			local ok, v = pcall(function()
				return inst[pair[2]]
			end)
			if ok and type(v) == "number" then
				o[pair[2]] = v
			end
		end
	end
	originals[inst] = o
	inst.Destroying:Connect(function()
		originals[inst] = nil
	end)
	return o
end

local function isExcluded(inst)
	for _, root in ipairs(fadeExclude) do
		if inst == root or inst:IsDescendantOf(root) then
			return true
		end
	end
	return false
end

local function fade(root, alpha, t)
	local list = root:GetDescendants()
	table.insert(list, root)
	for _, inst in ipairs(list) do
		if not isExcluded(inst) then
			local goal
			for prop, v in pairs(getOriginal(inst)) do
				goal = goal or {}
				goal[prop] = v + (1 - v) * (1 - alpha)
			end
			if goal then
				if t and t > 0 then
					tween(inst, t, goal, Enum.EasingStyle.Quad)
				else
					for p, v in pairs(goal) do
						pcall(function()
							inst[p] = v
						end)
					end
				end
			end
		end
	end
end

-- scramble text reveal ------------------------------------------------------
local glyphs = "!<>-_\\/[]{}=+*^?#@$%&"
local scrambleIds = {}

local function scramble(lbl, text, duration)
	local id = (scrambleIds[lbl] or 0) + 1
	scrambleIds[lbl] = id
	task.spawn(function()
		local start, len = os.clock(), #text
		while lbl.Parent and scrambleIds[lbl] == id do
			local p = (os.clock() - start) / duration
			if p >= 1 then
				break
			end
			local revealed = math.floor(p * len)
			local out = table.create(len)
			for i = 1, len do
				local ch = text:sub(i, i)
				if i <= revealed or ch == " " then
					out[i] = ch
				else
					local r = math.random(1, #glyphs)
					out[i] = glyphs:sub(r, r)
				end
			end
			lbl.Text = table.concat(out)
			task.wait(0.03)
		end
		if scrambleIds[lbl] == id then
			lbl.Text = text
		end
	end)
end

-- hover / press feedback ----------------------------------------------------
local function fxGoal(btn, goal)
	local out = {}
	for k, v in pairs(goal) do
		if k ~= "ImageColor3" or btn:IsA("ImageLabel") or btn:IsA("ImageButton") then
			out[k] = v
		end
	end
	return out
end

local idleFx = { BackgroundColor3 = Color3.fromRGB(56, 56, 56), TextColor3 = Color3.fromRGB(193, 193, 193), ImageColor3 = Color3.fromRGB(193, 193, 193) }
local hoverFx = { BackgroundColor3 = Color3.fromRGB(72, 72, 72), TextColor3 = Color3.fromRGB(255, 255, 255), ImageColor3 = Color3.fromRGB(255, 255, 255) }
local activeFx = { BackgroundColor3 = Color3.fromRGB(84, 84, 84), TextColor3 = Color3.fromRGB(255, 255, 255), ImageColor3 = Color3.fromRGB(255, 255, 255) }

local function buttonFx(btn, normal, hovered, isActive)
	normal = normal or idleFx
	hovered = hovered or hoverFx
	local scale = btn:FindFirstChildOfClass("UIScale") or new("UIScale", {}, btn)
	local function active()
		return isActive and isActive()
	end
	btn.MouseEnter:Connect(function()
		if not active() then
			tween(btn, 0.15, fxGoal(btn, hovered))
		end
	end)
	btn.MouseLeave:Connect(function()
		tween(scale, 0.2, { Scale = 1 })
		if not active() then
			tween(btn, 0.2, fxGoal(btn, normal))
		end
	end)
	btn.MouseButton1Down:Connect(function()
		tween(scale, 0.08, { Scale = 0.92 })
	end)
	btn.MouseButton1Up:Connect(function()
		tween(scale, 0.35, { Scale = 1 }, Enum.EasingStyle.Back)
	end)
end

-- ==========================================================================
-- window
-- ==========================================================================

local TITLE = "REZURXHUB"

gui = new("ScreenGui", {
	Name = "PillarChaseHub",
	ResetOnSpawn = false,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	IgnoreGuiInset = true,
	DisplayOrder = 10000,
	Enabled = false,
})
parentGui(gui)

win = new("Frame", {
	Name = "Main",
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromOffset(468, 548),
	BackgroundColor3 = THEME.bg,
	BorderSizePixel = 0,
	Visible = false,
	ZIndex = 2,
}, gui)
win.Active = true
corner(win, 16)
new("UIShadow", { Transparency = 0.5, BlurRadius = UDim.new(0, 30) }, win)
stroke(win, THEME.line, 2, 0.7)
new("UIGradient", {
	Rotation = 90,
	Color = ColorSequence.new(THEME.panel, THEME.bg),
}, win)
new("UISizeConstraint", { MinSize = Vector2.new(400, 470), MaxSize = Vector2.new(680, 820) }, win)
local MainScale = new("UIScale", { Scale = 1 }, win)
Main = win

topbar = new("Frame", {
	Name = "TopBar",
	Size = UDim2.new(1, 0, 0, 46),
	BackgroundColor3 = THEME.panel,
	BorderSizePixel = 0,
	ZIndex = 4,
}, win)
new("UICorner", {
	CornerRadius = UDim.new(0, 16),
	BottomLeftRadius = UDim.new(0, 0),
	BottomRightRadius = UDim.new(0, 0),
}, topbar)
-- hairline of white along the bottom of the header
local topAccent = new("Frame", {
	Name = "Accent",
	AnchorPoint = Vector2.new(0.5, 1),
	Position = UDim2.new(0.5, 0, 1, 0),
	Size = UDim2.new(1, 0, 0, 2),
	BackgroundColor3 = THEME.line,
	BorderSizePixel = 0,
	ZIndex = 6,
}, topbar)
new("UIGradient", {
	Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.5, 0.2),
		NumberSequenceKeypoint.new(1, 1),
	}),
}, topAccent)

-- logo mark
local logo = new("Frame", {
	Name = "Logo",
	AnchorPoint = Vector2.new(0, 0.5),
	Position = UDim2.new(0, 16, 0.5, 0),
	Size = UDim2.fromOffset(20, 20),
	BackgroundColor3 = THEME.line,
	BorderSizePixel = 0,
	ZIndex = 6,
}, topbar)
corner(logo, 6)
-- hub mark: a centre node, a ring, and three spokes fanning out
for _, rot in ipairs({ 0, 60, 120 }) do
	new("Frame", {
		Name = "Spoke",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(15, 1),
		Rotation = rot,
		BackgroundColor3 = THEME.bg,
		BorderSizePixel = 0,
		ZIndex = 7,
	}, logo)
end
local logoRing = new("Frame", {
	Name = "Ring",
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromOffset(9, 9),
	BackgroundTransparency = 1,
	ZIndex = 8,
}, logo)
corner(logoRing, 20)
stroke(logoRing, THEME.bg, 2, 0)
new("Frame", {
	Name = "Node",
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromOffset(3, 3),
	BackgroundColor3 = THEME.bg,
	BorderSizePixel = 0,
	ZIndex = 9,
}, logo)

local Title = new("TextLabel", {
	Name = "Title",
	BackgroundTransparency = 1,
	Position = UDim2.fromOffset(44, 0),
	Size = UDim2.new(1, -180, 1, 0),
	FontFace = FONT_BOLD,
	Text = TITLE,
	TextSize = 15,
	TextColor3 = THEME.text,
	TextXAlignment = Enum.TextXAlignment.Left,
	ZIndex = 5,
}, topbar)
new("UIGradient", {
	Rotation = 0,
	Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 255)),
		ColorSequenceKeypoint.new(0.55, Color3.fromRGB(214, 217, 228)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(138, 143, 160)),
	}),
}, Title)

statusDot = new("TextLabel", {
	Name = "Dot",
	AnchorPoint = Vector2.new(1, 0.5),
	Position = UDim2.new(1, -52, 0.5, 0),
	Size = UDim2.fromOffset(38, 20),
	BackgroundTransparency = 1,
	FontFace = FONT_BOLD,
	Text = "ON",
	TextSize = 12,
	TextColor3 = THEME.on,
	TextXAlignment = Enum.TextXAlignment.Center,
	ZIndex = 5,
}, topbar)

local closeBtn = new("TextButton", {
	Name = "CloseButton",
	AnchorPoint = Vector2.new(1, 0.5),
	Position = UDim2.new(1, -12, 0.5, 0),
	Size = UDim2.fromOffset(30, 30),
	BackgroundColor3 = THEME.button,
	BorderSizePixel = 0,
	FontFace = FONT_BOLD,
	Text = "×",
	TextSize = 18,
	TextColor3 = THEME.icon,
	AutoButtonColor = false,
	ZIndex = 6,
}, topbar)
corner(closeBtn, 8)
stroke(closeBtn, Color3.fromRGB(255, 255, 255), 1, 0.9)
new("UIScale", {}, closeBtn)
buttonFx(closeBtn,
	{ BackgroundColor3 = THEME.button, TextColor3 = THEME.icon },
	{ BackgroundColor3 = Color3.fromRGB(150, 40, 40), TextColor3 = Color3.fromRGB(255, 255, 255) })

local bottomBar = new("Frame", {
	Name = "BottomBar",
	AnchorPoint = Vector2.new(0, 1),
	Position = UDim2.fromScale(0, 1),
	Size = UDim2.new(1, 0, 0, 56),
	BackgroundColor3 = THEME.panel,
	BorderSizePixel = 0,
	ZIndex = 4,
}, win)
new("UICorner", {
	CornerRadius = UDim.new(0, 16),
	TopLeftRadius = UDim.new(0, 0),
	TopRightRadius = UDim.new(0, 0),
}, bottomBar)
-- matching hairline along the top of the rail
local botAccent = new("Frame", {
	Name = "Accent",
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.new(0.5, 0, 0, 0),
	Size = UDim2.new(1, 0, 0, 2),
	BackgroundColor3 = THEME.line,
	BorderSizePixel = 0,
	ZIndex = 6,
}, bottomBar)
new("UIGradient", {
	Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.5, 0.2),
		NumberSequenceKeypoint.new(1, 1),
	}),
}, botAccent)

local buttonContainer = new("Frame", {
	Name = "ButtonContainer",
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.42),
	Size = UDim2.new(1, -20, 0, 40),
	BackgroundTransparency = 1,
	ZIndex = 5,
}, bottomBar)
new("UIListLayout", {
	FillDirection = Enum.FillDirection.Horizontal,
	HorizontalAlignment = Enum.HorizontalAlignment.Center,
	VerticalAlignment = Enum.VerticalAlignment.Center,
	Padding = UDim.new(0, 6),
	SortOrder = Enum.SortOrder.LayoutOrder,
}, buttonContainer)

local indicator = new("Frame", {
	Name = "TabIndicator",
	AnchorPoint = Vector2.new(0.5, 1),
	Position = UDim2.new(0, 0, 1, -6),
	Size = UDim2.fromOffset(22, 3),
	BackgroundColor3 = THEME.line,
	BorderSizePixel = 0,
	ZIndex = 6,
}, bottomBar)
corner(indicator, 3)
new("UIStroke", {
	Color = THEME.line,
	Thickness = 3,
	Transparency = 0.55,
	ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
}, indicator)

local sections = new("Frame", {
	Name = "Sections",
	Position = UDim2.fromOffset(10, 86),
	Size = UDim2.new(1, -20, 1, -148),
	BackgroundTransparency = 1,
	ClipsDescendants = true,
	ZIndex = 2,
}, win)

-- live round banner -----------------------------------------------------------
-- always-visible strip under the header: a state dot, the current phase
-- (lobby / in round / dead / round over) and the map's name, refreshed by the
-- task cadence so it never lies about where you are.
local banner = new("Frame", {
	Name = "RoundBanner",
	Position = UDim2.fromOffset(10, 50),
	Size = UDim2.new(1, -20, 0, 30),
	BackgroundColor3 = THEME.panel2,
	BorderSizePixel = 0,
	ZIndex = 2,
}, win)
corner(banner, 8)
local bannerStroke = stroke(banner, THEME.line, 1, 0.85)
new("UIGradient", {
	Rotation = 0,
	Color = ColorSequence.new(Color3.fromRGB(38, 39, 45), Color3.fromRGB(24, 24, 28)),
}, banner)
bannerDot = new("Frame", {
	Name = "Dot",
	AnchorPoint = Vector2.new(0, 0.5),
	Position = UDim2.fromOffset(10, 15),
	Size = UDim2.fromOffset(7, 7),
	BackgroundColor3 = THEME.off,
	BorderSizePixel = 0,
	ZIndex = 3,
}, banner)
corner(bannerDot, 4)
new("UIStroke", {
	Color = THEME.on,
	Thickness = 2,
	Transparency = 0.5,
	ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
}, bannerDot)
bannerText = new("TextLabel", {
	Name = "Phase",
	BackgroundTransparency = 1,
	Position = UDim2.fromOffset(24, 0),
	Size = UDim2.new(0.5, -30, 1, 0),
	FontFace = FONT_BOLD,
	Text = "Not in game.",
	TextSize = 12,
	TextColor3 = THEME.dim,
	TextXAlignment = Enum.TextXAlignment.Left,
	ZIndex = 3,
}, banner)
bannerMap = new("TextLabel", {
	Name = "Map",
	BackgroundTransparency = 1,
	AnchorPoint = Vector2.new(1, 0.5),
	Position = UDim2.new(1, -10, 0.5, 0),
	Size = UDim2.new(0.5, -30, 1, 0),
	FontFace = FONT,
	Text = "",
	TextSize = 11,
	TextColor3 = THEME.dim,
	TextXAlignment = Enum.TextXAlignment.Right,
	TextTruncate = Enum.TextTruncate.AtEnd,
	ZIndex = 3,
}, banner)

local NAV_LABEL = { Roles = "Players", Visuals = "Style", HUD = "Overlay", Tasks = "Tasks", Teleport = "Teleport", Extras = "Tools", Info = "Info" }
local nav = {}
local currentTab = nil

-- toast ---------------------------------------------------------------------
local ToastStroke = new("UIStroke", {
	Color = Color3.fromRGB(255, 255, 255),
	Transparency = 1,
	ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
})
local Toast = new("TextLabel", {
	Name = "Toast",
	AnchorPoint = Vector2.new(0.5, 1),
	Position = UDim2.new(0.5, 0, 1, -64),
	Size = UDim2.fromOffset(0, 28),
	AutomaticSize = Enum.AutomaticSize.X,
	BackgroundColor3 = THEME.panel,
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	FontFace = FONT,
	TextSize = 14,
	TextColor3 = Color3.fromRGB(255, 255, 255),
	TextTransparency = 1,
	Text = "",
	ZIndex = 30,
}, win)
corner(Toast, 13)
new("UIPadding", { PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12) }, Toast)
ToastStroke.Parent = Toast
table.insert(fadeExclude, Toast)

local toastId = 0
local function toast(text, color)
	toastId += 1
	local id = toastId
	Toast.TextColor3 = color or Color3.fromRGB(255, 255, 255)
	Toast.Position = UDim2.new(0.5, 0, 1, -56)
	tween(Toast, 0.3, { BackgroundTransparency = 0, TextTransparency = 0, Position = UDim2.new(0.5, 0, 1, -64) })
	tween(ToastStroke, 0.3, { Transparency = 0.8 })
	scramble(Toast, text, 0.25)
	task.delay(1.8, function()
		if id ~= toastId then
			return
		end
		tween(Toast, 0.3, { BackgroundTransparency = 1, TextTransparency = 1 })
		tween(ToastStroke, 0.3, { Transparency = 1 })
	end)
end

-- ascii backdrop -------------------------------------------------------------
-- The signature "Product Faker V2" look: an animated ASCII field breathing
-- behind the window, driven by noise plus a sine shimmer and a ripple that
-- follows the mouse.  Three stacked labels at different transparencies keep it
-- cheap (one label per brightness band instead of per-character RichText).
local AsciiHolder = new("Frame", {
	Name = "AsciiBackdrop",
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	BackgroundTransparency = 1,
	ClipsDescendants = true,
	Visible = false,
	ZIndex = 1,
}, gui)
table.insert(fadeExclude, AsciiHolder)

local asciiCfg = {
	textSize = 13,
	padding = 110,
	fps = 30,
	ramp = " .,:;-=+*x#%@",
	color = Color3.fromRGB(255, 255, 255),
	mouse = true,
}
local ascii = {}
local asciiAlpha = new("NumberValue", { Value = 0, Name = "AsciiAlpha" })

do
	local font = Enum.Font.Code
	local huge = Vector2.new(1e5, 1e5)
	local size = asciiCfg.textSize

	local cw = TextService:GetTextSize(string.rep("M", 40), size, font, huge).X / 40
	local h1 = TextService:GetTextSize("M", size, font, huge).Y
	local h11 = TextService:GetTextSize(string.rep("M\n", 10) .. "M", size, font, huge).Y
	local ch = (h11 - h1) / 10
	if cw <= 0 then
		cw = size * 0.6
	end
	if ch <= 0 then
		ch = size
	end

	local layers = {
		{ min = 0.1, transparency = 0.82 },
		{ min = 0.4, transparency = 0.55 },
		{ min = 0.7, transparency = 0.22 },
	}
	local labels = {}
	for i in ipairs(layers) do
		labels[i] = new("TextLabel", {
			Name = "Layer" .. i,
			BackgroundTransparency = 1,
			Font = font,
			TextSize = size,
			TextColor3 = asciiCfg.color,
			TextTransparency = 1,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
			TextWrapped = false,
			RichText = false,
			Text = "",
			ZIndex = 1,
		}, AsciiHolder)
	end

	local ramp = {}
	for i = 1, #asciiCfg.ramp do
		ramp[i] = asciiCfg.ramp:sub(i, i)
	end
	local rampLen = #ramp

	local cols, rows, offX, offY = 0, 0, 0, 0
	local glow = {}
	local bufs = { {}, {}, {} }
	local lines = { {}, {}, {} }

	function ascii.rebuild(area, inner)
		cols = math.max(1, math.floor(area.X / cw))
		rows = math.max(1, math.floor(area.Y / ch))
		offX = (area.X - cols * cw) / 2
		offY = (area.Y - rows * ch) / 2
		for _, l in ipairs(labels) do
			l.Position = UDim2.fromOffset(offX, offY)
			l.Size = UDim2.fromOffset(cols * cw + 4, rows * ch + 4)
		end
		local cx, cy = area.X / 2, area.Y / 2
		local hw, hh = inner.X / 2, inner.Y / 2
		local pad = asciiCfg.padding
		table.clear(glow)
		for y = 0, rows - 1 do
			local qy = math.max(math.abs(offY + (y + 0.5) * ch - cy) - hh, 0)
			for x = 0, cols - 1 do
				local qx = math.max(math.abs(offX + (x + 0.5) * cw - cx) - hw, 0)
				local i = y * cols + x + 1
				if qx == 0 and qy == 0 then
					glow[i] = -1
				else
					local g = math.clamp(1 - math.sqrt(qx * qx + qy * qy) / pad, 0, 1)
					glow[i] = g * g * (3 - 2 * g)
				end
			end
		end
		for _, b in ipairs(bufs) do
			table.clear(b)
		end
	end

	local noise, sin, sqrt, exp, floor = math.noise, math.sin, math.sqrt, math.exp, math.floor
	local min1, min2, min3 = layers[1].min, layers[2].min, layers[3].min
	local aspect = ch / cw

	function ascii.render(t, alpha, mx, my)
		local mcx, mcy
		if mx then
			mcx, mcy = (mx - offX) / cw, (my - offY) / ch
		end
		local b1, b2, b3 = bufs[1], bufs[2], bufs[3]
		local l1, l2, l3 = lines[1], lines[2], lines[3]
		for y = 0, rows - 1 do
			local base = y * cols
			local ny = y * 0.11 - t * 0.35
			local wy = math.cos(y * 0.21 - t * 0.7)
			for x = 0, cols - 1 do
				local g = glow[base + x + 1]
				local c1, c2, c3 = " ", " ", " "
				if g > 0 then
					local v = 0.45 + noise(x * 0.055, ny, t * 0.12) * 1.3 + sin(x * 0.12 + t * 1.1) * wy * 0.18
					if mcx then
						local dx, dy = x - mcx, (y - mcy) * aspect
						local d = sqrt(dx * dx + dy * dy)
						v += sin(d * 0.45 - t * 7) * exp(-d * 0.09) * 0.45
					end
					v *= g * alpha
					if v >= min1 then
						local idx = math.clamp(floor(v * rampLen) + 1, 2, rampLen)
						local glyph = ramp[idx]
						if v >= min3 then
							c3 = glyph
						elseif v >= min2 then
							c2 = glyph
						else
							c1 = glyph
						end
					end
				end
				b1[x + 1], b2[x + 1], b3[x + 1] = c1, c2, c3
			end
			l1[y + 1] = table.concat(b1, "", 1, cols)
			l2[y + 1] = table.concat(b2, "", 1, cols)
			l3[y + 1] = table.concat(b3, "", 1, cols)
		end
		labels[1].Text = table.concat(l1, "\n", 1, rows)
		labels[2].Text = table.concat(l2, "\n", 1, rows)
		labels[3].Text = table.concat(l3, "\n", 1, rows)
		for i, layer in ipairs(layers) do
			labels[i].TextTransparency = 1 - (1 - layer.transparency) * alpha
		end
	end
end

do
	local acc, lastArea = 0, nil
	local start = os.clock()
	bind(RunService.RenderStepped, function(dt)
		AsciiHolder.Position = Main.Position
		local alpha = asciiAlpha.Value
		if alpha <= 0.001 or not Main.Visible then
			return
		end
		acc += dt
		if acc < 1 / asciiCfg.fps then
			return
		end
		acc = 0
		local s = MainScale.Scale > 0 and MainScale.Scale or 1
		local abs = Main.AbsoluteSize
		local inner = Vector2.new(math.floor(abs.X / s + 0.5), math.floor(abs.Y / s + 0.5))
		local area = inner + Vector2.new(asciiCfg.padding * 2, asciiCfg.padding * 2)
		if area ~= lastArea then
			lastArea = area
			AsciiHolder.Size = UDim2.fromOffset(area.X, area.Y)
			ascii.rebuild(area, inner)
		end
		local mx, my
		if asciiCfg.mouse then
			local m = UserInputService:GetMouseLocation() - AsciiHolder.AbsolutePosition
			if m.X >= 0 and m.Y >= 0 and m.X <= area.X and m.Y <= area.Y then
				mx, my = m.X, m.Y
			end
		end
		ascii.render(os.clock() - start, alpha, mx, my)
	end)
end

-- open / close animation ----------------------------------------------------
local moveIndicator -- forward declaration

function showWindow()
	if gui.Enabled then
		return
	end
	gui.Enabled = true
	Main.Visible = true
	AsciiHolder.Visible = true
	MainScale.Scale = 0.9
	fade(Main, 0, 0)
	tween(MainScale, 0.4, { Scale = 1 }, Enum.EasingStyle.Back)
	fade(Main, 1, 0.3)
	tween(asciiAlpha, 0.5, { Value = 1 }, Enum.EasingStyle.Sine)
	scramble(Title, TITLE, 0.5)
	task.defer(function()
		if moveIndicator then
			moveIndicator(true)
		end
	end)
end

function hideWindow(cb)
	if not gui.Enabled then
		if cb then
			cb()
		end
		return
	end
	if closeNotice then
		pcall(closeNotice)
	end
	tween(MainScale, 0.18, { Scale = 0.9 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	fade(Main, 0, 0.18)
	tween(asciiAlpha, 0.3, { Value = 0 }, Enum.EasingStyle.Quad)
	task.delay(0.2, function()
		Main.Visible = false
		gui.Enabled = false
		AsciiHolder.Visible = false
		if cb then
			cb()
		end
	end)
end

onClick(closeBtn, function()
	hideWindow()
end)

-- ==========================================================================
-- rows
-- ==========================================================================

local function section(page, text, order)
	local holder = new("Frame", {
		Size = UDim2.new(1, 0, 0, 20),
		BackgroundTransparency = 1,
		LayoutOrder = order,
		ZIndex = 1,
	}, page)
	local bar = new("Frame", {
		Name = "Accent",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 2, 0.5, 0),
		Size = UDim2.fromOffset(3, 11),
		BackgroundColor3 = THEME.line,
		BorderSizePixel = 0,
		ZIndex = 1,
	}, holder)
	corner(bar, 2)
	new("UIStroke", {
		Color = THEME.line,
		Thickness = 2,
		Transparency = 0.7,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	}, bar)
	new("TextLabel", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(12, 0),
		Size = UDim2.new(1, -12, 1, 0),
		FontFace = FONT_BOLD,
		Text = string.upper(text),
		TextSize = 11,
		TextColor3 = THEME.dim,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 1,
	}, holder)
	return holder
end

local function card(page, order)
	local c = new("Frame", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = THEME.panel,
		BorderSizePixel = 0,
		LayoutOrder = order,
		ZIndex = 1,
	}, page)
	corner(c, 10)
	local cStroke = stroke(c, Color3.fromRGB(255, 255, 255), 1, 0.9)
	new("UIListLayout", {
		Padding = UDim.new(0, 2),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, c)
	new("UIPadding", {
		PaddingTop = UDim.new(0, 6),
		PaddingBottom = UDim.new(0, 6),
		PaddingLeft = UDim.new(0, 6),
		PaddingRight = UDim.new(0, 6),
	}, c)
	-- a little life: the panel warms and its hairline brightens on hover
	bind(c.MouseEnter, function()
		tween(c, 0.15, { BackgroundColor3 = THEME.cardHover })
		tween(cStroke, 0.15, { Transparency = 0.6 })
	end)
	bind(c.MouseLeave, function()
		tween(c, 0.2, { BackgroundColor3 = THEME.panel })
		tween(cStroke, 0.2, { Transparency = 0.9 })
	end)
	return c
end

local function toggleRow(parent, order, text, get, set)
	local row = new("TextButton", {
		Size = UDim2.new(1, 0, 0, 34),
		BackgroundTransparency = 1,
		Text = "",
		AutoButtonColor = false,
		LayoutOrder = order,
		ZIndex = 2,
	}, parent)
	local label = new("TextLabel", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(6, 0),
		Size = UDim2.new(1, -70, 1, 0),
		FontFace = FONT,
		Text = text,
		TextSize = 13,
		TextColor3 = THEME.text,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 2,
	}, row)

	local sw = new("Frame", {
		Position = UDim2.new(1, -50, 0.5, -10),
		Size = UDim2.fromOffset(44, 20),
		BackgroundColor3 = THEME.off,
		BorderSizePixel = 0,
		ZIndex = 2,
	}, row)
	corner(sw, 10)
	stroke(sw, Color3.fromRGB(255, 255, 255), 1, 0.86)
	local knob = new("Frame", {
		Size = UDim2.fromOffset(16, 16),
		Position = UDim2.fromOffset(2, 2),
		BackgroundColor3 = Color3.fromRGB(240, 243, 250),
		BorderSizePixel = 0,
		ZIndex = 3,
	}, sw)
	corner(knob, 8)
	local knobGlow = new("UIStroke", {
		Color = THEME.bg,
		Thickness = 2,
		Transparency = 1,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	}, knob)

	local function refresh()
		local on = get()
		tween(sw, 0.22, { BackgroundColor3 = on and THEME.on or THEME.off })
		knob.BackgroundColor3 = on and THEME.bg or Color3.fromRGB(240, 243, 250)
		knob.Position = on and UDim2.new(1, -18, 0, 2) or UDim2.fromOffset(2, 2)
		knobGlow.Transparency = on and 0.6 or 1
	end
	refresh()
	onClick(row, function()
		local on = not get()
		set(on)
		-- spring the knob into place for a tactile feel
		refresh()
		local goal = on and UDim2.new(1, -18, 0, 2) or UDim2.fromOffset(2, 2)
		knob.Position = on and UDim2.fromOffset(2, 2) or UDim2.new(1, -18, 0, 2)
		tween(knob, 0.28, { Position = goal }, Enum.EasingStyle.Back)
		saveConfig()
	end)
	bind(row.MouseEnter, function()
		tween(label, 0.15, { TextColor3 = Color3.fromRGB(255, 255, 255) })
	end)
	bind(row.MouseLeave, function()
		tween(label, 0.2, { TextColor3 = THEME.text })
	end)
	return refresh
end

local function buttonRow(parent, order, text, callback)
	local b = new("TextButton", {
		Size = UDim2.new(1, 0, 0, 32),
		BackgroundColor3 = THEME.button,
		BorderSizePixel = 0,
		FontFace = FONT_BOLD,
		Text = text,
		TextSize = 13,
		TextColor3 = THEME.text,
		AutoButtonColor = false,
		LayoutOrder = order,
		ZIndex = 2,
	}, parent)
	corner(b, 9)
	stroke(b, Color3.fromRGB(255, 255, 255), 1, 0.9)
	new("UIScale", {}, b)
	buttonFx(b,
		{ BackgroundColor3 = THEME.button, TextColor3 = THEME.text },
		{ BackgroundColor3 = THEME.buttonHi, TextColor3 = Color3.fromRGB(255, 255, 255) })
	onClick(b, callback)
	return b
end

local function sliderRow(parent, order, text, min, max, get, set, fmt, snap)
	local row = new("Frame", {
		Size = UDim2.new(1, 0, 0, 46),
		BackgroundTransparency = 1,
		LayoutOrder = order,
		ZIndex = 2,
	}, parent)
	new("TextLabel", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(6, 2),
		Size = UDim2.new(1, -12, 0, 18),
		FontFace = FONT,
		Text = text,
		TextSize = 13,
		TextColor3 = THEME.text,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 2,
	}, row)
	local valLbl = new("TextLabel", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(6, 2),
		Size = UDim2.new(1, -12, 0, 18),
		FontFace = FONT_BOLD,
		Text = "",
		TextSize = 12,
		TextColor3 = THEME.accent,
		TextXAlignment = Enum.TextXAlignment.Right,
		ZIndex = 2,
	}, row)

	local track = new("Frame", {
		Position = UDim2.fromOffset(6, 30),
		Size = UDim2.new(1, -12, 0, 8),
		BackgroundColor3 = THEME.panel2,
		BorderSizePixel = 0,
		ZIndex = 2,
	}, row)
	corner(track, 4)
	stroke(track, Color3.fromRGB(255, 255, 255), 1, 0.92)
	local fill = new("Frame", {
		Size = UDim2.fromScale(0, 1),
		BackgroundColor3 = THEME.accent,
		BorderSizePixel = 0,
		ZIndex = 2,
	}, track)
	corner(fill, 4)
	new("UIStroke", {
		Color = THEME.accent,
		Thickness = 2,
		Transparency = 0.5,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	}, fill)
	local knob = new("Frame", {
		Size = UDim2.fromOffset(15, 15),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0, 0, 0.5, 0),
		BackgroundColor3 = THEME.bg,
		BorderSizePixel = 0,
		ZIndex = 3,
	}, track)
	corner(knob, 8)
	new("UIStroke", {
		Color = Color3.fromRGB(255, 255, 255),
		Thickness = 1.5,
		Transparency = 0.15,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	}, knob)

	local function render()
		local v = get()
		local a = math.clamp((v - min) / (max - min), 0, 1)
		fill.Size = UDim2.fromScale(a, 1)
		knob.Position = UDim2.new(a, 0, 0.5, 0)
		valLbl.Text = (fmt and fmt(v)) or string.format("%.2f", v)
	end
	render()

	local dragging = false
	local function apply(input)
		local rel = math.clamp((input.Position.X - track.AbsolutePosition.X) / math.max(1, track.AbsoluteSize.X), 0, 1)
		local v = min + rel * (max - min)
		if snap and snap > 0 then
			v = math.floor(v / snap + 0.5) * snap
		else
			v = math.floor(v * 100 + 0.5) / 100
		end
		set(v)
		render()
	end

	local hit = new("TextButton", {
		Position = UDim2.fromOffset(0, 20),
		Size = UDim2.new(1, 0, 0, 26),
		BackgroundTransparency = 1,
		Text = "",
		AutoButtonColor = false,
		ZIndex = 4,
	}, row)
	bind(hit.InputBegan, function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			apply(input)
		end
	end)
	bind(hit.InputEnded, function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
			saveConfig()
		end
	end)
	bind(UserInputService.InputChanged, function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			apply(input)
		end
	end)
	return render
end

local PALETTE = {
	{ 255, 45, 60 },   -- red
	{ 255, 140, 40 },  -- orange
	{ 255, 210, 60 },  -- amber
	{ 96, 255, 148 },  -- green
	{ 60, 210, 110 },  -- green
	{ 60, 220, 220 },  -- cyan
	{ 80, 200, 255 },  -- sky
	{ 94, 160, 255 },  -- blue
	{ 200, 90, 255 },  -- violet
	{ 255, 105, 180 }, -- pink
	{ 245, 245, 250 }, -- white
	{ 150, 160, 175 }, -- grey
}

-- every colorRow registers a refresher here so its swatch / hex / sliders stay
-- in sync when the value is changed from anywhere (palette, sliders, config).
colorSyncers = {}

local function colorRow(parent, order, text, get, set)
	-- read a colour channel whether the table uses numeric (1) or string ("1")
	-- keys, so a stale saved config can never wedge the picker.
	local function comp(c, i)
		local v = c[i]
		if type(v) ~= "number" then
			v = c[tostring(i)]
		end
		if type(v) ~= "number" then
			v = 0
		end
		return math.clamp(v, 0, 255)
	end

	local refresh -- forward declaration (palette callbacks call it)

	local row = new("Frame", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = order,
		ZIndex = 2,
	}, parent)
	new("UIListLayout", {
		Padding = UDim.new(0, 4),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, row)

	-- header: name + preview + quick palette
	local head = new("Frame", {
		Size = UDim2.new(1, 0, 0, 30),
		BackgroundTransparency = 1,
		LayoutOrder = 1,
		ZIndex = 2,
	}, row)
	new("TextLabel", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(6, 0),
		Size = UDim2.new(0, 90, 1, 0),
		FontFace = FONT,
		Text = text,
		TextSize = 13,
		TextColor3 = THEME.text,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 2,
	}, head)

	local preview = new("TextButton", {
		Position = UDim2.fromOffset(92, 4),
		Size = UDim2.fromOffset(42, 22),
		BackgroundColor3 = rgb(get()),
		BorderSizePixel = 0,
		Text = "",
		AutoButtonColor = false,
		ZIndex = 3,
	}, head)
	corner(preview, 6)
	stroke(preview, Color3.fromRGB(255, 255, 255), 1, 0.45)
	new("UIStroke", {
		Color = THEME.accent,
		Thickness = 2,
		Transparency = 0.6,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	}, preview)

	for i, c in ipairs(PALETTE) do
		local s = new("TextButton", {
			Position = UDim2.fromOffset(140 + (i - 1) * 22, 5),
			Size = UDim2.fromOffset(18, 18),
			BackgroundColor3 = rgb(c),
			BorderSizePixel = 0,
			Text = "",
			AutoButtonColor = false,
			ZIndex = 3,
		}, head)
		corner(s, 5)
		s.MouseEnter:Connect(function()
			tween(s, 0.1, { Size = UDim2.fromOffset(20, 20) })
		end)
		s.MouseLeave:Connect(function()
			tween(s, 0.15, { Size = UDim2.fromOffset(18, 18) })
		end)
		onClick(s, function()
			set({ c[1], c[2], c[3] })
			saveConfig()
			refresh()
		end)
	end

	-- expandable custom picker: red / green / blue sliders + hex readout
	local picker = new("Frame", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = 2,
		Visible = false,
		ZIndex = 2,
	}, row)
	new("UIListLayout", {
		Padding = UDim.new(0, 2),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, picker)

	local hexRow = new("Frame", {
		Size = UDim2.new(1, 0, 0, 22),
		BackgroundTransparency = 1,
		LayoutOrder = 0,
		ZIndex = 2,
	}, picker)
	new("TextLabel", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(6, 0),
		Size = UDim2.new(0, 30, 1, 0),
		FontFace = FONT_BOLD,
		Text = "HEX",
		TextSize = 11,
		TextColor3 = THEME.dim,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 2,
	}, hexRow)
	local hexBox = new("TextBox", {
		Position = UDim2.fromOffset(38, 1),
		Size = UDim2.new(0, 96, 0, 20),
		BackgroundColor3 = THEME.panel2,
		BorderSizePixel = 0,
		FontFace = FONT_BOLD,
		Text = "#FFFFFF",
		PlaceholderText = "#RRGGBB",
		TextSize = 12,
		TextColor3 = THEME.text,
		TextXAlignment = Enum.TextXAlignment.Center,
		ClearTextOnFocus = false,
		ZIndex = 3,
	}, hexRow)
	corner(hexBox, 5)
	stroke(hexBox, Color3.fromRGB(255, 255, 255), 1, 0.85)
	local bigPrev = new("Frame", {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -2, 0, 1),
		Size = UDim2.fromOffset(44, 20),
		BackgroundColor3 = rgb(get()),
		BorderSizePixel = 0,
		ZIndex = 3,
	}, hexRow)
	corner(bigPrev, 6)
	stroke(bigPrev, Color3.fromRGB(255, 255, 255), 1, 0.5)

	local function parseHex(str)
		if type(str) ~= "string" then
			return nil
		end
		local s = str:gsub("%s", ""):gsub("^#", "")
		if #s ~= 6 or not s:match("^%x%x%x%x%x%x$") then
			return nil
		end
		return { tonumber(s:sub(1, 2), 16), tonumber(s:sub(3, 4), 16), tonumber(s:sub(5, 6), 16) }
	end

	local rR = sliderRow(picker, 1, "Red", 0, 255,
		function() local c = get(); return comp(c, 1) end,
		function(v) local c = get(); set({ v, comp(c, 2), comp(c, 3) }) end,
		function(v) return string.format("%d", v) end, 1)
	local rG = sliderRow(picker, 2, "Green", 0, 255,
		function() local c = get(); return comp(c, 2) end,
		function(v) local c = get(); set({ comp(c, 1), v, comp(c, 3) }) end,
		function(v) return string.format("%d", v) end, 1)
	local rB = sliderRow(picker, 3, "Blue", 0, 255,
		function() local c = get(); return comp(c, 3) end,
		function(v) local c = get(); set({ comp(c, 1), comp(c, 2), v }) end,
		function(v) return string.format("%d", v) end, 1)

	function refresh()
		local c = get()
		preview.BackgroundColor3 = rgb(c)
		bigPrev.BackgroundColor3 = rgb(c)
		hexBox.Text = string.format("#%02X%02X%02X",
			math.floor(comp(c, 1) + 0.5), math.floor(comp(c, 2) + 0.5), math.floor(comp(c, 3) + 0.5))
		pcall(rR)
		pcall(rG)
		pcall(rB)
	end
	colorSyncers[#colorSyncers + 1] = refresh
	refresh()

	-- typed hex commits on Enter or when the box loses focus; bad input snaps back
	bind(hexBox.FocusLost, function()
		local c = parseHex(hexBox.Text)
		if c then
			set(c)
			saveConfig()
		end
		refresh()
	end)

	onClick(preview, function()
		picker.Visible = not picker.Visible
		refresh()
	end)

	return refresh
end

local function infoRow(parent, order, text)
	local row = new("Frame", {
		Size = UDim2.new(1, 0, 0, 22),
		BackgroundTransparency = 1,
		LayoutOrder = order,
		ZIndex = 1,
	}, parent)
	local lbl = new("TextLabel", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(6, 0),
		Size = UDim2.new(1, -12, 1, 0),
		FontFace = FONT,
		Text = text,
		TextSize = 12,
		TextColor3 = THEME.dim,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 1,
	}, row)
	return lbl
end

-- ==========================================================================
-- tabs (bottom rail + sliding indicator)
-- ==========================================================================

moveIndicator = function(instant)
	if not currentTab then
		return
	end
	local btn = nav[currentTab].btn
	local s = MainScale.Scale > 0 and MainScale.Scale or 1
	local x = (btn.AbsolutePosition.X + btn.AbsoluteSize.X / 2 - bottomBar.AbsolutePosition.X) / s
	local pos = UDim2.new(0, x, 1, -6)
	if instant then
		indicator.Position = pos
	else
		tween(indicator, 0.3, { Position = pos })
	end
end

-- staggered entrance: each section/card fades in a beat after the last so a tab
-- switch feels alive instead of snapping.  Runs once per switch, not per frame.
local function entrance(screen)
	local kids = {}
	for _, c in ipairs(screen:GetChildren()) do
		if c:IsA("GuiObject") then
			kids[#kids + 1] = c
		end
	end
	table.sort(kids, function(a, b)
		return (a.LayoutOrder or 0) < (b.LayoutOrder or 0)
	end)
	for i, c in ipairs(kids) do
		fade(c, 0, 0)
		task.delay((i - 1) * 0.03, function()
			if c.Parent then
				fade(c, 1, 0.22)
			end
		end)
	end
	-- restore the frame chrome (scrollbar) that lives on the page itself
	local so = getOriginal(screen)
	for prop, v in pairs(so) do
		pcall(function()
			screen[prop] = v
		end)
	end
end

local function setTab(index, instant)
	if index == currentTab then
		return
	end
	local prev = currentTab
	local dir = (prev and index < prev) and -1 or 1
	currentTab = index

	for i, tab in ipairs(nav) do
		local goal = (i == index) and activeFx or idleFx
		if instant then
			for k, v in pairs(fxGoal(tab.btn, goal)) do
				tab.btn[k] = v
			end
		else
			tween(tab.btn, 0.2, fxGoal(tab.btn, goal))
		end
	end
	moveIndicator(instant)

	local screen = nav[index].page
	if prev then
		local old = nav[prev].page
		if instant then
			old.Visible = false
		else
			fade(old, 0, 0.12)
			tween(old, 0.2, { Position = UDim2.fromScale(-0.06 * dir, 0) })
			task.delay(0.2, function()
				if nav[currentTab] and nav[currentTab].page ~= old then
					old.Visible = false
				end
			end)
		end
	end

	screen.Visible = true
	if instant then
		screen.Position = UDim2.new()
		fade(screen, 1, 0)
	else
		screen.Position = UDim2.fromScale(0.06 * dir, 0)
		tween(screen, 0.3, { Position = UDim2.new() })
		entrance(screen)
	end
	if TP then
		TP.active = (nav[index].name == "Teleport")
		if TP.active and TP.refresh then
			task.defer(TP.refresh)
		end
	end
end

selectTab = function(idx)
	-- accept a tab name as well as an index, so scripts can call
	-- PillarChaseHub.setTab("Teleport") without knowing the ordering
	if type(idx) == "string" then
		for i, t in ipairs(nav) do
			if t.name == idx or string.lower(t.name) == string.lower(idx) then
				idx = i
				break
			end
		end
	end
	if type(idx) ~= "number" then
		return
	end
	setTab(idx, not gui.Enabled)
end

local function makeTab(name, order)
	local btn = new("TextButton", {
		Name = name,
		Size = UDim2.fromOffset(58, 38),
		BackgroundColor3 = THEME.button,
		BorderSizePixel = 0,
		FontFace = FONT_BOLD,
		Text = NAV_LABEL[name] or name,
		TextSize = 10,
		TextColor3 = THEME.icon,
		AutoButtonColor = false,
		LayoutOrder = order,
		ZIndex = 6,
	}, buttonContainer)
	corner(btn, 10)
	stroke(btn, Color3.fromRGB(255, 255, 255), 1, 0.9)
	new("UIScale", {}, btn)

	local page = new("ScrollingFrame", {
		Name = name .. "Page",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 3,
		ScrollBarImageColor3 = THEME.button,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		Visible = false,
		ZIndex = 1,
	}, sections)
	new("UIListLayout", {
		Padding = UDim.new(0, 8),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, page)
	new("UIPadding", {
		PaddingTop = UDim.new(0, 2),
		PaddingBottom = UDim.new(0, 12),
		PaddingLeft = UDim.new(0, 2),
		PaddingRight = UDim.new(0, 2),
	}, page)

	nav[#nav + 1] = { btn = btn, page = page, name = name }
	local idx = #nav
	buttonFx(btn, idleFx, hoverFx, function()
		return currentTab == idx
	end)
	onClick(btn, function()
		setTab(idx)
	end)
	return page
end

bind(bottomBar:GetPropertyChangedSignal("AbsoluteSize"), function()
	moveIndicator(true)
end)
bind(bottomBar:GetPropertyChangedSignal("AbsolutePosition"), function()
	moveIndicator(true)
end)

-- ==========================================================================
-- pages
-- ==========================================================================

-- forward declaration: the task engine (defined after the highlight engine)
-- assigns to this local, so the Tasks tab button can call it.

local espPage = makeTab("Roles", 1)
local stylePage = makeTab("Visuals", 2)
local hudPage = makeTab("HUD", 3)
local tasksPage = makeTab("Tasks", 4)
local tpPage = makeTab("Teleport", 5)
local extrasPage = makeTab("Extras", 6)
local infoPage = makeTab("Info", 7)

-- Highlights
section(espPage, "highlights", 1)
local c1 = card(espPage, 1)
toggleRow(c1, 1, "Enable highlights", function()
	return STATE.enabled
end, function(v)
	STATE.enabled = v
end)

section(espPage, "roles to show", 2)
local c2 = card(espPage, 2)
for i, role in ipairs({ "Monster", "Survivor", "Sentinel", "Unknown" }) do
	toggleRow(c2, i, role, function()
		return STATE.roles[role]
	end, function(v)
		STATE.roles[role] = v
	end)
end
toggleRow(c2, 5, "Highlight yourself", function()
	return STATE.self
end, function(v)
	STATE.self = v
end)

section(espPage, "detection range", 3)
local c3 = card(espPage, 3)
sliderRow(c3, 1, "Max distance", 50, 10000, function()
	return STATE.maxDist
end, function(v)
	STATE.maxDist = v
end, function(v)
	return string.format("%d studs", v)
end, 50)

section(espPage, "name labels", 4)
local c4 = card(espPage, 4)
toggleRow(c4, 1, "Show name / role labels", function()
	return STATE.labels
end, function(v)
	STATE.labels = v
end)
toggleRow(c4, 2, "Show distance", function()
	return STATE.showDistance
end, function(v)
	STATE.showDistance = v
end)

-- Style
section(stylePage, "highlight style", 1)
local s1 = card(stylePage, 1)
toggleRow(s1, 1, "See through walls", function()
	return STATE.throughWalls
end, function(v)
	STATE.throughWalls = v
end)
sliderRow(s1, 2, "Fill opacity", 0, 1, function()
	return STATE.fillTransparency
end, function(v)
	STATE.fillTransparency = v
end, function(v)
	return string.format("%d%% solid", math.floor((1 - v) * 100 + 0.5))
end)

section(stylePage, "role colours", 2)
local s2 = card(stylePage, 2)
for i, role in ipairs({ "Monster", "Survivor", "Sentinel", "Unknown", "Self" }) do
	colorRow(s2, i, role, function()
		return STATE.colors[role]
	end, function(c)
		STATE.colors[role] = c
	end)
end

section(stylePage, "window look", 3)
local s3 = card(stylePage, 3)
toggleRow(s3, 1, "Unlock mouse while open", function()
	return STATE.freeMouse
end, function(v)
	STATE.freeMouse = v
end)
local s3note = infoRow(s3, 2, "The game locks your cursor to screen centre for")
local s3note2 = infoRow(s3, 3, "shiftlock. This frees it ONLY while the window is")
local s3note3 = infoRow(s3, 4, "open, then restores shiftlock exactly as it was.")

section(stylePage, "world lighting", 4)
local s4 = card(stylePage, 4)
toggleRow(s4, 1, "Fullbright", function()
	return STATE.fullbright
end, function(v)
	STATE.fullbright = v
end)
toggleRow(s4, 2, "No fog", function()
	return STATE.noFog
end, function(v)
	STATE.noFog = v
end)
sliderRow(s4, 3, "Field of view", 70, 120, function()
	return STATE.cameraFov
end, function(v)
	STATE.cameraFov = v
end, function(v)
	return string.format("%d deg", v)
end, 1)
infoRow(s4, 4, "Fullbright, no fog and zoom are local only -")
infoRow(s4, 5, "they change what you see, never the map.")

-- HUD
section(hudPage, "hud overlay", 1)
local h1 = card(hudPage, 1)
toggleRow(h1, 1, "Status HUD", function()
	return STATE.hud
end, function(v)
	STATE.hud = v
end)
toggleRow(h1, 2, "Off-screen arrows", function()
	return STATE.offscreen
end, function(v)
	STATE.offscreen = v
end)
toggleRow(h1, 3, "Tracers", function()
	return STATE.tracers
end, function(v)
	STATE.tracers = v
end)
toggleRow(h1, 4, "FPS counter", function()
	return STATE.fpsCounter
end, function(v)
	STATE.fpsCounter = v
end)
toggleRow(h1, 5, "Ping (ms)", function()
	return STATE.pingCounter
end, function(v)
	STATE.pingCounter = v
end)

section(hudPage, "hud position", 2)
local hpos = card(hudPage, 2)
infoRow(hpos, 1, "While the hub is open you can drag the status")
infoRow(hpos, 2, "box anywhere - it is saved for next time.")
buttonRow(hpos, 3, "Reset HUD position", function()
	STATE.hudPos = nil
	if hud then
		hud.AnchorPoint = Vector2.new(1, 0)
		hud.Position = UDim2.new(1, -12, 0, 32)
	end
	saveConfig()
end)

section(hudPage, "monster alert", 3)
local h2 = card(hudPage, 2)
toggleRow(h2, 1, "Monster proximity alert", function()
	return STATE.monsterAlert
end, function(v)
	STATE.monsterAlert = v
end)
sliderRow(h2, 2, "Alert distance", 20, 400, function()
	return STATE.alertDist
end, function(v)
	STATE.alertDist = v
end, function(v)
	return string.format("%d studs", v)
end, 5)

-- Tasks
section(tasksPage, "objectives", 1)
local tk1 = card(tasksPage, 1)
toggleRow(tk1, 1, "Highlight objectives", function()
	return STATE.shardEsp
end, function(v)
	STATE.shardEsp = v
end)
toggleRow(tk1, 2, "Auto tasks  (teleport + interact)", function()
	return STATE.autoCollect
end, function(v)
	STATE.autoCollect = v
end)
sliderRow(tk1, 3, "Teleport delay", 0.05, 0.5, function()
	return STATE.collectDelay
end, function(v)
	STATE.collectDelay = v
end, function(v)
	return string.format("%.2fs / object", v)
end, 0.05)
sliderRow(tk1, 4, "Collect height offset", 0, 6, function()
	return STATE.collectHeight
end, function(v)
	STATE.collectHeight = v
end, function(v)
	return string.format("%d studs", v)
end, 1)

-- single-task picker ---------------------------------------------------------
-- Every map splits its objectives into ObjectiveInteract* groups (cells vs
-- vents, trash vs snow, blood vs keypads).  Auto tasks sweeping all of them at
-- once is what makes it unreliable, so each group gets its own button and the
-- collector can be pinned to exactly one.
local taskBtns = {}
local taskBtnFolders = { [0] = "All" }
local taskPickerDirty = true
local taskPickerShownMap = nil

section(tasksPage, "single task", 2)
local tkTask = card(tasksPage, 2)
infoRow(tkTask, 1, "Pick one group and Auto tasks finishes just that")
infoRow(tkTask, 2, "one, instead of hopping between objectives.")
for i = 1, 6 do
	local slot = i - 1
	taskBtns[slot] = buttonRow(tkTask, i + 2, "-", function()
		STATE.taskGroup = taskBtnFolders[slot] or "All"
		taskPickerDirty = true
	end)
end

section(tasksPage, "objective colour", 3)
local tk2 = card(tasksPage, 3)
colorRow(tk2, 1, "Colour", function()
	return STATE.shardColor
end, function(c)
	STATE.shardColor = c
end)

section(tasksPage, "other objectives", 4)
local tk3 = card(tasksPage, 4)
infoRow(tk3, 1, "Every 'ObjectiveInteract*' folder is scanned and")
infoRow(tk3, 2, "highlighted; 'Auto tasks' walks you to each one.")
infoRow(tk3, 3, "Touch objectives (shards) clear by standing on")
infoRow(tk3, 4, "them. Prompt / click objectives (lockpicking,")
infoRow(tk3, 5, "cleaning, keypads, valves) are server-side: firing")
infoRow(tk3, 6, "them from the client does NOT advance the count,")
infoRow(tk3, 7, "so the hub moves on instead of looping on one.")
infoRow(tk3, 8, "Off = it never moves you anywhere.")

section(tasksPage, "progress", 5)
local tk4 = card(tasksPage, 5)
infoStatus = infoRow(tk4, 1, "Status: -")
infoMap = infoRow(tk4, 2, "Map: -")
infoObj1 = infoRow(tk4, 3, "Objective 1: -")
infoObj2 = infoRow(tk4, 4, "Objective 2: -")
infoExit = infoRow(tk4, 5, "Exit located: -")
infoShards = infoRow(tk4, 6, "Objectives left: -")

section(tasksPage, "how it works", 6)
local tk5 = card(tasksPage, 6)
infoRow(tk5, 1, "Step 1: work out the round. If there's no map,")
infoRow(tk5, 2, "you're in the lobby, or you died and are now")
infoRow(tk5, 3, "spectating, nothing runs - status shows it.")
infoRow(tk5, 4, "Step 2: objective ESP marks every live task")
infoRow(tk5, 5, "object (shards, snow, trash, valves, keypads).")
infoRow(tk5, 6, "'Auto tasks' (ON by default) does the real")
infoRow(tk5, 7, "interaction, not a fake poke: it walks you onto")
infoRow(tk5, 8, "touch shards, fires live prompts, and on the")
infoRow(tk5, 9, "bone/firepit task grabs each bone and carries it")
infoRow(tk5, 10, "onto the fire for real. Off = never moves you.")
buttonRow(tk5, 11, "Collect nearest objective now", function()
	collectOneShard()
end)

-- Teleport
TP = {}
section(tpPage, "where you are", 1)
local tp1 = card(tpPage, 1)
TP.status = infoRow(tp1, 1, "Status: -")
TP.map = infoRow(tp1, 2, "Map: -")
TP.obj1 = infoRow(tp1, 3, "Objective 1: -")
TP.obj2 = infoRow(tp1, 4, "Objective 2: -")
TP.exit = infoRow(tp1, 5, "Exit located: -")
buttonRow(tp1, 6, "Rescan now", function()
	if TP.refresh then
		TP.refresh()
	end
end)

section(tpPage, "objective teleports", 2)
TP.list = card(tpPage, 2)

section(tpPage, "quick jump", 3)
local tp3 = card(tpPage, 3)
buttonRow(tp3, 1, "Nearest available task", function()
	if TP.goNearest then
		TP.goNearest()
	end
end)
buttonRow(tp3, 2, "Exit", function()
	if TP.goExit then
		TP.goExit()
	end
end)
infoRow(tp3, 3, "Moves your character onto the objective.")
infoRow(tp3, 4, "Only works in a live round - nothing happens")
infoRow(tp3, 5, "in the lobby or while you are dead and")
infoRow(tp3, 6, "spectating.")

section(tpPage, "player teleports", 4)
TP.players = card(tpPage, 4)

section(tpPage, "how it works", 5)
local tp4 = card(tpPage, 5)
infoRow(tp4, 1, "The scan works out where you are first (lobby,")
infoRow(tp4, 2, "in round, dead, round over) and which map.")
infoRow(tp4, 3, "Each row below is one of the game's own task")
infoRow(tp4, 4, "groups, with how many objects are still live.")
infoRow(tp4, 5, "This is movement + the game's own interaction,")
infoRow(tp4, 6, "so the server just sees a normal player moving.")

-- Extras
section(extrasPage, "session tools", 1)
local x1 = card(extrasPage, 1)
toggleRow(x1, 1, "Anti-AFK", function()
	return STATE.antiAfk
end, function(v)
	STATE.antiAfk = v
end)
infoRow(x1, 2, "Stops Roblox's 20-minute idle kick by tapping")
infoRow(x1, 3, "the movement keys virtually. Safe and local.")

section(extrasPage, "exit / escape", 2)
local x2 = card(extrasPage, 2)
toggleRow(x2, 1, "Highlight the exit", function()
	return STATE.exitEsp
end, function(v)
	STATE.exitEsp = v
end)
colorRow(x2, 2, "Exit", function()
	return STATE.exitColor
end, function(c)
	STATE.exitColor = c
end)
infoRow(x2, 3, "Draws an outline + EXIT tag over the escape")
infoRow(x2, 4, "doors once the map has located them.")

section(extrasPage, "crosshair", 3)
local x3 = card(extrasPage, 3)
toggleRow(x3, 1, "Crosshair", function()
	return STATE.crosshair
end, function(v)
	STATE.crosshair = v
end)
colorRow(x3, 2, "Colour", function()
	return STATE.crosshairColor
end, function(c)
	STATE.crosshairColor = c
end)

section(extrasPage, "movement", 4)
local x5 = card(extrasPage, 4)
toggleRow(x5, 1, "Infinite stamina (ON)", function()
	return STATE.infiniteStamina
end, function(v)
	STATE.infiniteStamina = v
end)
infoRow(x5, 2, "Pins your stamina at max and cancels the drain")
infoRow(x5, 3, "while you sprint. Client-side / cosmetic on most")
infoRow(x5, 4, "servers, so it may not register on the server.")
toggleRow(x5, 5, "Noclip (walk through walls)", function()
	return STATE.noclip
end, function(v)
	STATE.noclip = v
end)
infoRow(x5, 6, "Turns off collision on your own character parts.")
infoRow(x5, 7, "Moving the character is normal; the server just")
infoRow(x5, 8, "sees you where you are, like any other step.")
sliderRow(x5, 9, "Speed multiplier", 1, 10, function()
	return STATE.speedMult
end, function(v)
	STATE.speedMult = v
end, function(v)
	return string.format("%.1fx", v)
end, 0.1)
infoRow(x5, 10, "Scales walk + sprint together through the game's")
infoRow(x5, 11, "own movement. 1.0x is off; slide up to 10.0x.")

section(extrasPage, "camera & safety", 6)
local x6 = card(extrasPage, 6)
toggleRow(x6, 1, "Shift lock", function()
	return STATE.shiftlock
end, function(v)
	STATE.shiftlock = v
end)
infoRow(x6, 2, "Locks the cursor to the centre and pulls the")
infoRow(x6, 3, "camera over your shoulder while it is on.")
infoRow(x6, 4, "Turns itself off whenever the hub is open.")
buttonRow(x6, 5, "Free camera (unstick)", function()
	freeCamera()
end)
infoRow(x6, 6, "Use when the camera has been scripted/locked")
infoRow(x6, 7, "and you can no longer swing it back.")
toggleRow(x6, 8, "Bail out near a monster", function()
	return STATE.taskSafety
end, function(v)
	STATE.taskSafety = v
end)
infoRow(x6, 9, "While a task runs, leave it and move to the")
infoRow(x6, 10, "next one if a monster comes within range.")
sliderRow(x6, 11, "Safety distance", 20, 80, function()
	return STATE.taskSafetyDist
end, function(v)
	STATE.taskSafetyDist = v
end, function(v)
	return string.format("%.0f m", v)
end, 5)

section(extrasPage, "interaction", 7)
local x7 = card(extrasPage, 7)
toggleRow(x7, 1, "Instant prompts", function()
	return STATE.instantPrompt
end, function(v)
	STATE.instantPrompt = v
end)
infoRow(x7, 2, "Fires objective prompts with no E hold, so")
infoRow(x7, 3, "tasks that normally take a hold complete at once.")

section(extrasPage, "monster tools", 8)
local x8 = card(extrasPage, 8)
sliderRow(x8, 1, "Survivor hitbox", 1, 10, function()
	return STATE.hitboxMult
end, function(v)
	STATE.hitboxMult = v
end, function(v)
	return string.format("%.1fx", v)
end, 0.5)
infoRow(x8, 2, "Enlarges every survivor's hitbox while you are")
infoRow(x8, 3, "the Monster. 1.0x is off and restores the game's")
infoRow(x8, 4, "own sizes; it also resets when you are not the")
infoRow(x8, 5, "Monster or the round ends.")

section(extrasPage, "skins (cosmetic)", 9)
local x9 = card(extrasPage, 9)
toggleRow(x9, 1, "Vapor tier spoof (ON)", function()
	return STATE.skinSpoof
end, function(v)
	STATE.skinSpoof = v
end)
infoRow(x9, 2, "Makes the lobby show every Vapor tier as owned")
infoRow(x9, 3, "and tier IV as equipped. This only changes your")
infoRow(x9, 4, "own client's copy - the game's in-round monster")
infoRow(x9, 5, "is still chosen by the server, and everything")
infoRow(x9, 6, "resets on rejoin. Purely visual, nothing earned.")

section(extrasPage, "hotkeys", 5)
local x4 = card(extrasPage, 5)
infoRow(x4, 1, "K  -  open / close the hub")
infoRow(x4, 2, "1 - 7  -  jump to a tab")
infoRow(x4, 3, "H  -  panic: instantly hide hub + overlay")
infoRow(x4, 4, "Press H again to bring everything back.")
keybindBtn = buttonRow(x4, 5, "Toggle key: " .. tostring(STATE.keybind) .. "   (click to rebind)", function()
	keybindCapturing = true
	keybindBtn.Text = "Press any key…"
end)

-- rebind capture: while armed, the next real key press becomes the toggle key.
bind(UserInputService.InputBegan, function(input)
	if not keybindCapturing then
		return
	end
	if input.UserInputType ~= Enum.UserInputType.Keyboard then
		return
	end
	local name = input.KeyCode and input.KeyCode.Name or nil
	keybindCapturing = false
	if name and name ~= "Unknown" and Enum.KeyCode[name] then
		STATE.keybind = name
		saveConfig()
		keybindBtn.Text = "Toggle key: " .. name .. "   (click to rebind)"
		toast("Toggle key set to " .. name, THEME.on)
	else
		keybindBtn.Text = "Toggle key: " .. tostring(STATE.keybind) .. "   (click to rebind)"
		toast("That key can't be used.", THEME.danger)
	end
end)

-- Info
section(infoPage, "live stats", 1)
local i1 = card(infoPage, 1)
infoRole = infoRow(i1, 1, "Your role: -")
infoMonster = infoRow(i1, 2, "Monster: -")
infoSurvivors = infoRow(i1, 3, "Survivors: -")
infoTracked = infoRow(i1, 4, "Highlighted: -")
infoMouse = infoRow(i1, 5, "Mouse: -")

section(infoPage, "about", 2)
local i2 = card(infoPage, 2)
infoRow(i2, 1, "Place 121255181515820 · Pillar Chase")
infoRow(i2, 2, "Highlights are local; the server never sees them.")
infoRow(i2, 3, "Tabs: keys 1-7 · Window: " .. tostring(STATE.keybind) .. " · Panic: H")
infoRow(i2, 4, "Anti-AFK keeps you in the round while idle.")

section(infoPage, "settings", 3)
local i3 = card(infoPage, 3)
buttonRow(i3, 1, "Save config now", saveConfig)
buttonRow(i3, 2, "Reset to defaults", function()
	for k, v in pairs(DEFAULTS) do
		STATE[k] = (type(v) == "table") and deepCopy(v) or v
	end
	saveConfig()
end)

selectTab(1)
showWindow()
end

-- ==========================================================================
-- overlay (HUD, arrows, tracers, alert) - kept BELOW the window
-- ==========================================================================

local overlay = new("ScreenGui", {
	Name = "PillarChaseOverlay",
	ResetOnSpawn = false,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	IgnoreGuiInset = true,
	DisplayOrder = 9999,
})
parentGui(overlay)

-- close notice: lives on the overlay ScreenGui (which stays enabled when the hub
-- window hides itself) so closing the hub leaves the "press K" hint on screen.
local closeNote = new("TextLabel", {
	Name = "CloseNotice",
	AnchorPoint = Vector2.new(0.5, 1),
	Position = UDim2.new(0.5, 0, 1, -48),
	Size = UDim2.fromOffset(0, 30),
	AutomaticSize = Enum.AutomaticSize.X,
	BackgroundColor3 = THEME.panel,
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	FontFace = FONT,
	TextSize = 14,
	TextColor3 = THEME.text,
	TextTransparency = 1,
	Text = "",
	Visible = false,
	ZIndex = 40,
}, overlay)
corner(closeNote, 15)
new("UIPadding", { PaddingLeft = UDim.new(0, 14), PaddingRight = UDim.new(0, 14) }, closeNote)
local closeNoteStroke = stroke(closeNote, THEME.line, 1, 1)

local closeNoteId = 0
function closeNotice()
	-- grab the service here: this chunk is right at Luau's local-variable
	-- limit, so the file-level `TweenService` local is not reliably captured
	-- as an upvalue down here (it silently resolves to a nil global).
	local TS = game:GetService("TweenService")
	closeNoteId += 1
	local id = closeNoteId
	closeNote.Text = "Press  K  to reopen the hub"
	closeNote.Visible = true
	closeNote.Position = UDim2.new(0.5, 0, 1, -40)
	TS:Create(closeNote, TweenInfo.new(0.2), { BackgroundTransparency = 0.05, TextTransparency = 0, Position = UDim2.new(0.5, 0, 1, -48) }):Play()
	TS:Create(closeNoteStroke, TweenInfo.new(0.2), { Transparency = 0.5 }):Play()
	task.delay(1.6, function()
		if id ~= closeNoteId then
			return
		end
		TS:Create(closeNote, TweenInfo.new(0.25), { BackgroundTransparency = 1, TextTransparency = 1 }):Play()
		TS:Create(closeNoteStroke, TweenInfo.new(0.25), { Transparency = 1 }):Play()
		task.delay(0.3, function()
			if id ~= closeNoteId then
				return
			end
			closeNote.Visible = false
			closeNote.Text = ""
		end)
	end)
end

-- monster alert: pulsing edge + banner
local edge = new("Frame", {
	Name = "Edge",
	Size = UDim2.fromScale(1, 1),
	BackgroundTransparency = 1,
	Active = false,
	Visible = false,
	ZIndex = 1,
}, overlay)
local edgeStroke = new("UIStroke", {
	Color = THEME.danger,
	Thickness = 6,
	Transparency = 1,
	ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
}, edge)

local alert = new("TextLabel", {
	Name = "Alert",
	Size = UDim2.fromOffset(420, 40),
	Position = UDim2.new(0.5, -210, 0, 70),
	BackgroundColor3 = Color3.fromRGB(120, 18, 24),
	BackgroundTransparency = 0.15,
	BorderSizePixel = 0,
	Font = THEME.fontBold,
	Text = "",
	TextSize = 16,
	TextColor3 = Color3.fromRGB(255, 235, 235),
	Visible = false,
	ZIndex = 3,
}, overlay)
corner(alert, 9)

-- tracer + arrow holders (never capture input)
local tracerHolder = new("Frame", {
	Name = "Tracers",
	Size = UDim2.fromScale(1, 1),
	BackgroundTransparency = 1,
	Active = false,
	ZIndex = 2,
}, overlay)
local arrowHolder = new("Frame", {
	Name = "Arrows",
	Size = UDim2.fromScale(1, 1),
	BackgroundTransparency = 1,
	Active = false,
	ZIndex = 3,
}, overlay)

-- status hud ---------------------------------------------------------------
-- A single horizontal strip docked to the right edge.  The old layout stacked
-- three lines vertically; this reads left-to-right like a scoreboard - role,
-- then the survivor/sentinel tally, then the monster distance - so it is one
-- row tall and never buries the game's own bottom-right UI.  It is draggable
-- and remembers where you put it, and is interactive only while the menu is
-- open (so you can grab it, but it never eats your clicks mid-fight).
hud = new("Frame", {
	Name = "HUD",
	AnchorPoint = Vector2.new(1, 0),
	Position = UDim2.new(1, -12, 0, 32),
	Size = UDim2.new(0, 0, 0, 30),
	AutomaticSize = Enum.AutomaticSize.X,
	BackgroundColor3 = THEME.bg,
	BackgroundTransparency = 0.22,
	BorderSizePixel = 0,
	Active = false,
	ZIndex = 4,
}, overlay)
corner(hud, 8)
local hudStroke = stroke(hud, THEME.line, 1)
new("UIListLayout", {
	FillDirection = Enum.FillDirection.Horizontal,
	VerticalAlignment = Enum.VerticalAlignment.Center,
	HorizontalAlignment = Enum.HorizontalAlignment.Left,
	Padding = UDim.new(0, 9),
	SortOrder = Enum.SortOrder.LayoutOrder,
}, hud)
new("UIPadding", {
	PaddingLeft = UDim.new(0, 11),
	PaddingRight = UDim.new(0, 12),
	PaddingTop = UDim.new(0, 6),
	PaddingBottom = UDim.new(0, 6),
}, hud)
if STATE.hudPos and type(STATE.hudPos) == "table" and type(STATE.hudPos[1]) == "number" then
	hud.AnchorPoint = Vector2.new(0, 0)
	hud.Position = UDim2.fromOffset(STATE.hudPos[1], STATE.hudPos[2])
end
-- a small coloured role dot that mirrors the highlight colour of your own role
local hudDot = new("Frame", {
	Name = "RoleDot",
	LayoutOrder = 1,
	Size = UDim2.fromOffset(8, 8),
	BackgroundColor3 = THEME.dim,
	BorderSizePixel = 0,
	ZIndex = 5,
}, hud)
corner(hudDot, 4)
local function hudSep(order)
	local s = new("Frame", {
		Name = "Sep",
		LayoutOrder = order,
		Size = UDim2.fromOffset(1, 14),
		BackgroundColor3 = THEME.line,
		BorderSizePixel = 0,
		BackgroundTransparency = 0.4,
		ZIndex = 5,
	}, hud)
	return s
end
local function hudLabel(order, font, size, colour)
	return new("TextLabel", {
		BackgroundTransparency = 1,
		LayoutOrder = order,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.new(0, 0, 1, 0),
		Font = font,
		Text = "",
		TextSize = size,
		TextColor3 = colour,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Center,
		ZIndex = 5,
	}, hud)
end
hudRole = hudLabel(2, THEME.fontBold, 13, THEME.text)
local hudSep1 = hudSep(3)
hudLine1 = hudLabel(4, THEME.font, 12, THEME.dim)
local hudSep2 = hudSep(5)
hudLine2 = hudLabel(6, THEME.font, 12, THEME.dim)

-- centre reticle
local crosshair = new("Frame", {
	Name = "Crosshair",
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromOffset(6, 6),
	BackgroundColor3 = Color3.fromRGB(120, 255, 160),
	BorderSizePixel = 0,
	Visible = false,
	ZIndex = 5,
}, overlay)
corner(crosshair, 3)
new("UIStroke", {
	Color = Color3.fromRGB(0, 0, 0),
	Thickness = 1,
	Transparency = 0.4,
}, crosshair)

-- top-right stats (fps / ping)
local statsLbl = new("TextLabel", {
	Name = "Stats",
	AnchorPoint = Vector2.new(1, 0),
	Position = UDim2.new(1, -12, 0, 10),
	Size = UDim2.fromOffset(180, 18),
	BackgroundTransparency = 1,
	Font = THEME.fontBold,
	Text = "",
	TextSize = 12,
	TextColor3 = THEME.dim,
	TextXAlignment = Enum.TextXAlignment.Right,
	ZIndex = 5,
}, overlay)

-- ==========================================================================
-- highlight engine
-- ==========================================================================

local espFolder = new("Folder", { Name = "PCHub_ESP" }, Workspace)
local labelHolder = new("Folder", { Name = "PCHub_Labels" }, gui)

local tracked = {} --- [model] = { hl=, bb=, txt=, head= }
local targets = {} --- array of {model, head, pos, role, name, dist, colour, isSelf, dead}
local fx = {} --- [model] = { tracer=, arrow=, role= }

local ROLE_LABEL = { Monster = "MONSTER", Survivor = "SURVIVOR", Sentinel = "SENTINEL", Unknown = "?" }
local HUD_ROLE = { Monster = "Monster", Survivor = "Survivor", Sentinel = "Sentinel" }

local function colourFor(role, isSelf)
	if isSelf then
		return STATE.colors.Self
	end
	return STATE.colors[role] or STATE.colors.Unknown
end

local function roleOf(char, plr)
	local t = char:GetAttribute("Type")
	if t == "Monster" or t == "Survivor" or t == "Sentinel" then
		return t
	end
	if plr and plr:GetAttribute("EndCondition") == "MONSTER" then
		return "Monster"
	end
	return "Unknown"
end

local function ensureRecord(model)
	local rec = tracked[model]
	if rec and rec.hl and rec.hl.Parent then
		return rec
	end
	local hl = new("Highlight", {
		Name = "PCHub_HL",
		FillColor = Color3.fromRGB(255, 255, 255),
		OutlineColor = Color3.fromRGB(255, 255, 255),
		FillTransparency = STATE.fillTransparency,
		OutlineTransparency = STATE.outlineTransparency,
		Adornee = model,
	}, espFolder)

	local bb = new("BillboardGui", {
		Name = "PCHub_LBL",
		Size = UDim2.fromOffset(190, 30),
		StudsOffsetWorldSpace = Vector3.new(0, 3.2, 0),
		AlwaysOnTop = true,
		MaxDistance = math.huge,
		LightInfluence = 0,
		Enabled = false,
	}, labelHolder)
	local txt = new("TextLabel", {
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Font = Enum.Font.GothamBold,
		Text = "",
		TextSize = 14,
		TextColor3 = Color3.fromRGB(255, 255, 255),
		TextStrokeTransparency = 0.35,
		TextStrokeColor3 = Color3.fromRGB(0, 0, 0),
	}, bb)

	rec = { hl = hl, bb = bb, txt = txt, head = nil }
	tracked[model] = rec
	return rec
end

local counts = { Monster = 0, Survivor = 0, Sentinel = 0, Unknown = 0 }
local trackedCount = 0
local monsterDist = nil

local function stepHighlights()
	counts = { Monster = 0, Survivor = 0, Sentinel = 0, Unknown = 0 }
	trackedCount = 0
	monsterDist = nil
	local newTargets = {}

	if not STATE.enabled then
		for model, rec in pairs(tracked) do
			if rec.hl then
				rec.hl:Destroy()
			end
			if rec.bb then
				rec.bb:Destroy()
			end
			tracked[model] = nil
		end
		targets = newTargets
		return
	end

	local cam = Workspace.CurrentCamera
	local origin = cam and cam.CFrame.Position or Vector3.new(0, 0, 0)
	local seen = {}

	for _, plr in ipairs(Players:GetPlayers()) do
		local char = plr.Character
		if char and char.Parent then
			local isSelf = (plr == LP)
			local role = roleOf(char, plr)
			counts[role] = (counts[role] or 0) + 1

			local wantRole
			if isSelf then
				wantRole = STATE.self
			else
				wantRole = STATE.roles[role] == true
			end

			local hrp = char:FindFirstChild("HumanoidRootPart") or char.PrimaryPart
			local head = char:FindFirstChild("Head") or hrp
			local hum = char:FindFirstChildOfClass("Humanoid")
			local dead = hum ~= nil and hum.Health <= 0
			local dist = hrp and (hrp.Position - origin).Magnitude or 99999

			if (role == "Monster") and hrp and not isSelf then
				if monsterDist == nil or dist < monsterDist then
					monsterDist = dist
				end
			end

			local visible = wantRole and dist <= STATE.maxDist
			if visible then
				local rec = ensureRecord(char)
				seen[char] = true
				trackedCount = trackedCount + 1

				local colour = rgb(colourFor(role, isSelf))
				rec.hl.FillColor = colour
				rec.hl.OutlineColor = colour
				rec.hl.Adornee = char
				rec.hl.Enabled = true
				rec.hl.FillTransparency = STATE.fillTransparency
				rec.hl.OutlineTransparency = STATE.outlineTransparency
				rec.hl.DepthMode = STATE.throughWalls and Enum.HighlightDepthMode.AlwaysOnTop
					or Enum.HighlightDepthMode.Occluded

				if head ~= rec.head then
					rec.bb.Adornee = head
					rec.head = head
				end

				if STATE.labels then
					local bits = { plr.Name }
					if STATE.showRole then
						bits[#bits + 1] = "(" .. (ROLE_LABEL[role] or role) .. ")"
					end
					if STATE.showDistance then
						bits[#bits + 1] = string.format("%dm", math.floor(dist + 0.5))
					end
					if isSelf then
						bits[#bits + 1] = "· you"
					end
					if dead then
						bits[#bits + 1] = "· dead"
					end
					rec.txt.Text = table.concat(bits, " ")
					rec.txt.TextColor3 = colour
					rec.bb.Enabled = true
				else
					rec.bb.Enabled = false
				end

				if hrp then
					newTargets[#newTargets + 1] = {
						model = char,
						head = head,
						pos = hrp.Position,
						role = role,
						name = plr.Name,
						dist = dist,
						colour = colour,
						isSelf = isSelf,
						dead = dead,
					}
				end
			end
		end
	end

	for model, rec in pairs(tracked) do
		if not seen[model] then
			if rec.hl then
				rec.hl:Destroy()
			end
			if rec.bb then
				rec.bb:Destroy()
			end
			tracked[model] = nil
		end
	end

	targets = newTargets
end

-- ==========================================================================
-- task engine  ·  "Collect soul shards" (Objectives1) + trash (Objectives2)
-- ==========================================================================
--
-- Verified live (place 121255181515820):
--   * The survivor task is "Collect soul shards".  workspace.Map.Objectives1
--     goes 0 -> 100 (Max).  Each of the 100 Shard models under
--     Map.ObjectiveInteract1 exposes a HumanoidRootPart that is "available"
--     while hrp.CanTouch == true and hrp.Transparency < 1.
--   * Map.ScriptHandler.SetupObjectives.ClientTaskScript owns a handle on the
--     shard's Touched event; on touch it bumps Objectives1 locally and fires
--     its no-argument AddStuff RemoteEvent.  The server then re-validates.
--   * Firing AddStuff directly is REJECTED (we tested: count unchanged), and a
--     distant touch is ignored.  Moving the character ONTO a shard collects it
--     reliably (tested 16 -> 38).  That is exactly what auto-collect does, so
--     the game's own code does the collecting - we only reposition you.

local shardFolder = new("Folder", { Name = "PCHub_Shards" }, Workspace)
local shardRecs = {} --- [model] = Highlight
local shardAvail = 0
local shardLastTotal = 0

local function mapNow()
	local m = Workspace:FindFirstChild("Map")
	if m and m.Parent == Workspace then
		return m
	end
	return nil
end

local function shardContainer(map)
	return map and map:FindFirstChild("ObjectiveInteract1") or nil
end

-- every "ObjectiveInteract*" folder in the current map.  Names vary by map:
-- ObjectiveInteract1 = soul shards, ObjectiveInteract = valves,
-- ObjectiveInteract2 = trash / generators.
local function objectiveFolders(map)
	local list = {}
	if not map then
		return list
	end
	for _, c in ipairs(map:GetChildren()) do
		if type(c.Name) == "string" and string.sub(c.Name, 1, 17) == "ObjectiveInteract" then
			list[#list + 1] = c
		end
	end
	-- stable order so the single-task picker's slots never swap between scans
	table.sort(list, function(a, b)
		return tostring(a.Name) < tostring(b.Name)
	end)
	return list
end

-- a short, player-facing name for one objective group: the task's own action
-- text when there is one ("shovel snow", "complete matrix"), otherwise the
-- number the map gave the folder.
local function taskGroupLabel(folder)
	for _, d in ipairs(folder:GetDescendants()) do
		if d:IsA("ProximityPrompt") and d.Enabled and type(d.ActionText) == "string" and d.ActionText ~= "" then
			return d.ActionText
		end
	end
	local n = string.match(tostring(folder.Name), "(%d+)$")
	return n and ("Task " .. n) or "Objectives"
end

-- fill the single-task picker from whatever groups this map actually has.
-- slot 0 is always "All"; slots 1..5 mirror the map's objective folders.  It
-- runs at most once a frame from stepShardEsp, only when the map changes or a
-- button was pressed.
local function refreshTaskPicker(map)
	local folders = objectiveFolders(map)
	-- keep the pin if that group still exists; otherwise fall back to All
	local keep = STATE.taskGroup
	if not (keep == nil or keep == "" or keep == "All") then
		local found = false
		for _, f in ipairs(folders) do
			if f.Name == keep then
				found = true
			end
		end
		if not found then
			STATE.taskGroup = "All"
		end
	end
	for k in pairs(taskBtnFolders) do
		taskBtnFolders[k] = nil
	end
	taskBtnFolders[0] = "All"
	for slot = 0, 5 do
		local b = taskBtns[slot]
		if b then
			local f = folders[slot]
			if slot == 0 then
				b.Visible = true
				b.Text = "All objectives"
			elseif f then
				taskBtnFolders[slot] = f.Name
				b.Visible = true
				b.Text = taskGroupLabel(f)
			else
				b.Visible = false
				b.Text = "-"
			end
			local active = (taskBtnFolders[slot] or "All") == (STATE.taskGroup or "All")
			b.BackgroundColor3 = active and THEME.buttonHi or THEME.button
			b.TextColor3 = active and Color3.fromRGB(255, 255, 255) or THEME.text
		end
	end
end

-- A "task" prompt is an enabled ProximityPrompt that advances an objective.
-- Most actions are the task ("clean debris", "shovel snow", "to grab/drop" on
-- an EnergyCell).  The one prop that shares this shape but is NOT an objective
-- is the trash map's TrashBag, whose grab/drop prompt lives inside the same
-- ObjectiveInteract2 folder - counting or firing it would grab a prop instead
-- of doing the task, so it is excluded by name.
local function isTaskPrompt(d)
	if not (d:IsA("ProximityPrompt") and d.Enabled) then
		return false
	end
	local p = d.Parent
	if p and (p.Name == "TrashBag" or p:FindFirstAncestor("TrashBag")) then
		return false
	end
	return true
end

local function hasEnabledPrompt(model)
	for _, d in ipairs(model:GetDescendants()) do
		if isTaskPrompt(d) then
			return d
		end
	end
	return nil
end

local function isShardAvailable(hrp)
	return hrp ~= nil and hrp.CanTouch == true and hrp.Transparency < 1
end

-- ---------------------------------------------------------------------------
-- bone / firepit task ("Burn bones in firepit")
--
-- This one is entirely LOCAL: the map's Bone.DragHandler clones a DragDetector
-- plus an enabled ProximityPrompt onto every bone in ObjectiveInteract1, and the
-- bone's own Touched handler does the objective work the instant a HELD bone
-- touches the map's FireBox part (it bumps Objectives1 locally, then fires
-- AddStuff).  So the genuine interaction is two steps - grab the bone, carry it
-- onto the fire - and that is exactly what the collector reproduces below;
-- firing the prompt alone only grabs/drops it and never scores.
-- ---------------------------------------------------------------------------
local function findFireBox(map)
	local fb = map and map:FindFirstChild("FireBox", true)
	if fb and fb:IsA("BasePart") then
		return fb
	end
	return nil
end

local function boneDragParts(model, map)
	local dd = model:FindFirstChild("DragDetector")
	local prompt = model:FindFirstChild("ProximityPrompt")
	if not (dd and prompt) then
		return nil
	end
	local fb = findFireBox(map)
	if not fb then
		return nil
	end
	return dd, fb
end

-- grab a bone and carry it onto the fire; the game's Touched code completes it
local function carryBoneToFire(char, model, dd, fb)
	if not (char and char.Parent and dd and dd.Parent and model.Parent) then
		return false
	end
	-- stand at the firepit: the game's own drag watch drops a held bone once it
	-- is 9+ studs from the holder, so we hold it right on top of the fire.
	pcall(function()
		char:PivotTo(CFrame.new(fb.Position + Vector3.new(0, 3, 0)))
	end)
	-- grab exactly the way Bone.DragHandler's prompt handler does
	pcall(function()
		dd.ReferenceInstance = char
		char:SetAttribute("HoldingItem", true)
	end)
	-- drive the bone onto the fire (a real touch, not a fake prompt fire)
	pcall(function()
		model.CFrame = fb.CFrame
	end)
	pcall(function()
		if type(firetouchinterest) == "function" then
			firetouchinterest(model, fb, 1)
		end
	end)
	return true
end

-- snow-pile task ("Remove snow piles") -------------------------------------
-- A pile is a SnowPile model holding a SnowPile part with a LockLeft counter and
-- an E ProximityPrompt whose ActionText reads "shovel snow (N)".  Each press of
-- E removes one, spread over time, so the collector stands on the pile and
-- presses again on a short cadence until it clears.
local function snowPileParts(model)
	if model.Name ~= "SnowPile" and not model:FindFirstChild("SnowPile") then
		return nil
	end
	local prompt = model:FindFirstChildWhichIsA("ProximityPrompt", true)
	if not prompt then
		return nil
	end
	-- the counter lives on the pile's "FinishedSnowPile" part (it counts UP to
	-- its Max attribute), not on the model root, so search the whole subtree.
	local lock
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("NumberValue") and d.Name == "LockLeft" then
			lock = d
			break
		end
	end
	if not lock then
		local inner = model:FindFirstChild("SnowPile")
		lock = inner and inner:FindFirstChild("LockLeft")
	end
	return prompt, lock
end

-- The snow task only accepts a dig when the player's shovel tool is equipped:
-- the game's own SwingAxe refuses to run otherwise, and the server rejects the
-- dig remote.  The game equips through EquipToggle, which is client-side, so
-- the hub can put the tool in hand itself.
local function shovelTool(char)
	local inv = char and char:FindFirstChild("Inventory")
	if not inv then
		return nil
	end
	local fallback
	for _, c in ipairs(inv:GetChildren()) do
		local stuff = c:FindFirstChild("ItemStuff")
		if stuff and stuff:FindFirstChild("Equipped") then
			local nm = string.lower(c.Name)
			local handle = c:FindFirstChild("Handle")
			-- the shovel is what actually authorises a dig; match it by name or by
			-- its Dig sound rather than grabbing whatever tool happens to be first.
			if string.find(nm, "shovel", 1, true) or string.find(nm, "snow", 1, true) then
				return c
			end
			if handle and handle:FindFirstChild("Dig") then
				return c
			end
			if not fallback then
				fallback = c
			end
		end
	end
	return fallback
end

local function equipTool(char, tool)
	if not (char and tool) then
		return false
	end
	local asp = char:FindFirstChild("Aspects")
	local stuff = tool:FindFirstChild("ItemStuff")
	local handle = tool:FindFirstChild("Handle")
	if not (asp and stuff and handle) then
		return false
	end
	local equipped = stuff:FindFirstChild("Equipped")
	local cur = asp:FindFirstChild("CurrentItem")
	if equipped and equipped.Value and cur and cur.Value == tool then
		return true
	end
	pcall(function()
		for _, d in ipairs(tool:GetDescendants()) do
			if d:IsA("BasePart") then
				d.Massless = true
				d.CanCollide = false
			end
		end
		local motor = handle:FindFirstChild("ItemMotor")
		if motor then
			local rs = game:GetService("ReplicatedStorage")
			local ge = rs:FindFirstChild("GlobalEvents")
			local ev = ge and ge:FindFirstChild("ItemMotor")
			if ev then
				ev:FireServer(motor, true)
			end
			motor.Enabled = true
		end
		handle.Massless = true
		handle.CanCollide = false
		if cur then
			cur.Value = tool
		end
		if equipped then
			equipped.Value = true
		end
	end)
	return true
end

-- the remote the game's own shovel swing fires; replicating it skips the
-- 0.75s swing animation entirely.
local function snowDigRemote(map)
	local sh = map and map:FindFirstChild("ScriptHandler")
	local handler = sh and sh:FindFirstChild("SnowPileHandler")
	return handler and handler:FindFirstChild("DigSnow") or nil
end

-- carry-to-destination tasks ("Bring cells to panels", "Remove trash piles")
-- ---------------------------------------------------------------------------
-- These props are grabbed with the game's own drag prompt and have to be
-- carried across the map to a fixed drop-off.  Firing the prompt remotely
-- only half-works: it sets DragDetector.ReferenceInstance (so the prop
-- follows you visually) but never sets Aspects.CurrentItem, and the server
-- therefore ignores the drop.  Driving the prompt's own hold -
-- InputHoldBegin()/InputHoldEnd() - is what the game actually listens to, so
-- the grab / carry / drop cycle below is the real thing, not a prompt poke.
local function carryPos(model)
	if model:IsA("BasePart") then
		return model.Position
	end
	local p = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
	return p and p.Position
end

-- where a held prop has to end up: the map names a folder (PowerHolders for
-- energy cells) or the prop carries a Target attribute naming it.  Returns
-- the drag detector plus every still-free slot part.
local function carryDropOff(model, map)
	if not map then
		return nil
	end
	local dd = model:FindFirstChild("DragDetector")
	if not dd then
		return nil
	end
	local target = model:GetAttribute("Target")
	local folder
	if target then
		folder = map:FindFirstChild(target) or map:FindFirstChild(target .. "s")
	end
	-- props with no Target attribute are not carry objects at all; leave them
	-- to their own branch rather than dragging them somewhere by guesswork.
	if not folder then
		return nil
	end
	local slots = {}
	for _, holder in ipairs(folder:GetChildren()) do
		-- a holder that is already full stops taking cells; its slots would
		-- otherwise look free forever and the bot would keep feeding it.
		local req = holder:FindFirstChild("Required")
		local rmax = req and req:GetAttribute("Max")
		local full = req and rmax and req.Value >= rmax
		if not full then
			local group = holder:FindFirstChild("EnergySlots") or holder:FindFirstChild("Slots")
			if group then
				for _, slot in ipairs(group:GetChildren()) do
					local part = slot:FindFirstChild("CellSpot") or slot:FindFirstChild("Slot") or slot:FindFirstChildWhichIsA("BasePart", true)
					if part then
						local taken = slot:FindFirstChild("Taken")
						-- the slot's CellSpot part is fully transparent while it is
						-- still open and turns opaque (or gains Taken) once a cell
						-- sits in it.
						local spot = slot:FindFirstChild("CellSpot")
						local open = (taken == nil) and (spot == nil or spot.Transparency >= 0.9)
						open = open or (taken ~= nil and taken.Transparency >= 0.9)
						if open then
							slots[#slots + 1] = part
						end
					end
				end
			else
				local part = holder:FindFirstChildWhichIsA("BasePart", true)
				if part then
					slots[#slots + 1] = part
				end
			end
		end
	end
	return dd, slots
end

-- walks up from a slot part to the PowerHolder that owns it (the model that
-- carries the Required counter), so a drop can be confirmed by that counter.
local function slotHolder(part)
	local p = part
	while p and p ~= workspace do
		if p:FindFirstChild("Required") then
			return p
		end
		p = p.Parent
	end
	return nil
end

local function nearestSlot(slots, origin)
	local best, bestD
	for _, p in ipairs(slots) do
		if p.Parent then
			local d = origin and (p.Position - origin).Magnitude or 0
			if not bestD or d < bestD then
				best, bestD = p, d
			end
		end
	end
	return best
end

-- press-and-release a prompt through the game's own hold handler
local function holdPrompt(prompt)
	if not prompt then
		return
	end
	pcall(function()
		if not prompt.Enabled then
			prompt.Enabled = true
		end
		prompt:InputHoldBegin()
	end)
	local delay = math.max(0.6, (prompt.HoldDuration or 0) + 0.3)
	task.delay(delay, function()
		pcall(function()
			prompt:InputHoldEnd()
		end)
	end)
end

-- nearest live monster distance from a position (nil if none seen)
local function nearestMonsterDist(origin)
	local best
	for _, plr in ipairs(Players:GetPlayers()) do
		if plr ~= LP then
			local c = plr.Character
			if c then
				local r = roleOf(c, plr)
				if r == "Monster" then
					local h = c:FindFirstChild("HumanoidRootPart")
					if h then
						local d = (h.Position - origin).Magnitude
						if not best or d < best then
							best = d
						end
					end
				end
			end
		end
	end
	return best
end

-- ---------------------------------------------------------------------------
-- round / map awareness
--
-- Step one is ALWAYS to work out whether we are actually in a live round on a
-- real map, and who/what we are.  Nothing (ESP, auto-collect) runs until that
-- is true, so the hub never behaves as if it were mid-game when it is not.
-- ---------------------------------------------------------------------------

local function mapObjectName(map)
	local o1 = map and map:FindFirstChild("Objectives1")
	local n = o1 and o1:FindFirstChild("ObjName")
	if n and type(n.Value) == "string" and n.Value ~= "" then
		return n.Value
	end
	local o2 = map and map:FindFirstChild("Objectives2")
	local n2 = o2 and o2:FindFirstChild("ObjName")
	if n2 and type(n2.Value) == "string" and n2.Value ~= "" then
		return n2.Value
	end
	return nil
end

-- latest round state, refreshed on the task cadence and read by the HUD
local ROUND = { inRound = false, status = "Not in game.", map = nil }

-- Which phase are we in?  The old version guessed from the LobbyGUI frames, but
-- ResultsScreen is Visible for most of a round too, so it reported "over" while
-- you were alive.  These are the signals the GAME itself drives (verified from
-- its own scripts):
--   LobbyGUI.Lobby.Visible               the pre-round menu is open
--   workspace.Map.GameOver               a child appears when the round ends
--   workspace.Server.Timer.Value         counts down while a round runs
--   char.Aspects.Health.Value            the REAL health (Humanoid is cosmetic)
--   char.Aspects.Escaped.Value           you reached the exit
--   Player:GetAttribute("EndCondition")  set once you are out ("You died.")
local function uiPhase()
	local map = mapNow()
	if not map then
		return "nogame"
	end

	local pg = LP:FindFirstChildOfClass("PlayerGui")
	local lg = pg and pg:FindFirstChild("LobbyGUI")
	local lobby = lg and lg:FindFirstChild("Lobby")
	if lobby and lobby.Visible then
		return "lobby"
	end

	if map:FindFirstChild("GameOver") then
		return "over"
	end

	local char = LP.Character
	if not char or not char:FindFirstChildOfClass("Humanoid") then
		return "load"
	end
	local asp = char:FindFirstChild("Aspects")
	local esc = asp and asp:FindFirstChild("Escaped")
	if esc and esc.Value == true then
		return "escaped"
	end
	local h = asp and asp:FindFirstChild("Health")
	local hum = char:FindFirstChildOfClass("Humanoid")
	local hp = (h and h.Value) or (hum and hum.Health) or 0
	if hp <= 0 then
		return "dead"
	end
	return "round"
end

-- returns (inRound, statusText, mapName)
local function roundInfo()
	local map = mapNow()
	if not (map and map.Parent) then
		return false, "Not in game.", nil
	end
	local phase = uiPhase()
	if phase == "nogame" then
		return false, "Not in game.", nil
	end
	if phase == "lobby" then
		return false, "Waiting for a round...", mapObjectName(map)
	end
	if phase == "over" then
		return false, "Round over.", mapObjectName(map)
	end
	if phase == "escaped" then
		return false, "You escaped!", mapObjectName(map)
	end
	if phase == "dead" then
		return false, "Dead - spectating.", mapObjectName(map)
	end
	if phase == "load" then
		return false, "Loading into the round...", mapObjectName(map)
	end
	return true, "In round.", mapObjectName(map)
end

-- ---------------------------------------------------------------------------
-- task completion + teardown
--
-- Every task the game runs carries its own progress counter on the model: a
-- LockLeft NumberValue (snow, generators, matrix, valve) or a holder's Required
-- NumberValue (power cells).  Reading that counter is how the collector tells a
-- FINISHED task from a live one -- without it a cleared task that stays in the
-- world (a maxed power matrix, a spent vent, a repaired generator) keeps getting
-- fired at forever, which is what made the collector look like it "spams every
-- task".
-- ---------------------------------------------------------------------------
local TASK = {}

TASK.counter = function(model)
	local lock, req
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("NumberValue") then
			if d.Name == "LockLeft" then
				lock = d
			elseif d.Name == "Required" then
				req = d
			end
		end
	end
	return lock, req
end

-- Some LockLeft counters count UP to Max (snow, generators, matrix, valve, note
-- pages) and some count DOWN: the blood drain has no Max and the Slimey Dungeon
-- chest starts AT its Max of 23 and falls to 0.  Reading the direction is what
-- stops a fresh chest (LockLeft == Max) being mistaken for a finished one.
TASK.countsDown = function(model, lock)
	local max = lock and lock:GetAttribute("Max")
	if not max then
		return true
	end
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("ProximityPrompt") and string.find(string.lower(tostring(d.ActionText)), "lockpick", 1, true) then
			return true
		end
	end
	return false
end

-- Slimey Dungeon chest: a Part "Lock" carrying the "Lockpick chest" prompt, a
-- "Pickup treasure" prompt, and a LockLeft that starts at its Max (23) and
-- counts down to 0.  Returns lock, lockPrompt, pickupPrompt.
TASK.chest = function(model)
	local lock
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("NumberValue") and d.Name == "LockLeft" then
			lock = d
			break
		end
	end
	if not lock then
		return nil
	end
	local lockP, pickP
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("ProximityPrompt") then
			local at = string.lower(tostring(d.ActionText))
			if string.find(at, "lockpick", 1, true) then
				lockP = d
			elseif string.find(at, "pickup", 1, true) then
				pickP = d
			end
		end
	end
	if not (lockP or pickP) then
		return nil
	end
	return lock, lockP, pickP
end

TASK.done = function(model)
	local lock, req = TASK.counter(model)
	if lock then
		local max = lock:GetAttribute("Max")
		if TASK.countsDown(model, lock) then
			if lock.Value <= 0 then
				-- a picked chest is not finished until its treasure is taken
				local _, _, pickP = TASK.chest(model)
				if not (pickP and pickP.Enabled) then
					return true
				end
			end
		elseif max and lock.Value >= max then
			return true
		end
	end
	if req then
		local max = req:GetAttribute("Max")
		if max and req.Value >= max then
			return true
		end
	end
	return false
end

-- The per-task WorkTask script (blood drain, power matrix, valve, generator)
-- keeps a Prompt ObjectValue pointing at the model's own prompt and a RemoveMe
-- RemoteEvent.  RemoveMe is the game's own teardown -- exactly what pressing E
-- does -- so firing it always closes the task GUI and clears any full-screen
-- effect it had applied.
TASK.workTasks = function(map)
	local list = {}
	local so = map and map:FindFirstChild("SetupObjectives", true)
	if not so then
		return list
	end
	for _, d in ipairs(so:GetDescendants()) do
		if d:FindFirstChild("Prompt") and d:FindFirstChild("RemoveMe") then
			list[#list + 1] = d
		end
	end
	return list
end

TASK.forModel = function(map, model)
	for _, wt in ipairs(TASK.workTasks(map)) do
		local pv = wt:FindFirstChild("Prompt")
		local p = pv and pv.Value
		if p and p.Parent and (p.Parent == model or p.Parent.Parent == model) then
			return wt
		end
	end
	return nil
end

TASK.close = function(map, model)
	local wt = TASK.forModel(map, model)
	local ok = false
	if wt then
		pcall(function()
			wt.RemoveMe:FireServer()
		end)
		ok = true
	end
	-- the valve/turn task grabs the camera (CameraType = Scriptable) and only
	-- hands it back inside its own ExitTask.  We tear the task down with
	-- RemoveMe instead, so restore the camera here or it can stay stuck at a
	-- single angle after a valve/generator attempt.
	pcall(function()
		local cam = Workspace.CurrentCamera
		if cam and cam.CameraType == Enum.CameraType.Scriptable then
			cam.CameraType = Enum.CameraType.Custom
			local char = LP.Character
			local hum = char and char:FindFirstChildOfClass("Humanoid")
			if hum then
				cam.CameraSubject = hum
			end
		end
	end)
	return ok
end

-- shut-off-valve task (Haunted Sewers "TurnTask"): the player opens the task and
-- drags the valve round; each notch of turn adds to the prompt's own LockLeft
-- and, at Max, the WorkTask fires its AddStuff and shuts itself down.  The
-- collector opens the task and fills that counter so the game's own completion
-- runs, then dismisses the GUI either way.
TASK.valve = function(model, map)
	local valve = model:FindFirstChild("Valve", true)
	if not valve then
		return nil
	end
	local prompt
	for _, d in ipairs(valve:GetChildren()) do
		if d:IsA("ProximityPrompt") and d.Name == "ObjectivePrompt" then
			prompt = d
			break
		end
	end
	if not prompt then
		return nil
	end
	if not TASK.forModel(map, model) then
		return nil
	end
	return prompt, prompt:FindFirstChild("LockLeft")
end

-- Hallow Ridge snow pile: the Twigs folder holds one branch per prompt ("to
-- remove branch"), and the pile only lets you shovel once every branch is gone.
TASK.snowBranch = function(model)
	local tw = model:FindFirstChild("Twigs")
	if not tw then
		return nil
	end
	-- do NOT require Enabled: the game leaves branch prompts disabled until the
	-- player is close, and sweeping only enabled ones made the pile look clear
	-- when it was not.  The driver enables the prompt itself before firing.
	for _, d in ipairs(tw:GetDescendants()) do
		if d:IsA("ProximityPrompt") then
			return d
		end
	end
	return nil
end

-- power matrix (Slime PadTask): a folder of 9 key parts, each with a
-- ClickDetector.  The task lights the next key bright green; pressing that key
-- is what a real click sends, so the hub presses the lit key's ClickDetector
-- rather than poking the completion remote (which the client ignores until the
-- key code is actually entered).
TASK.matrixKeys = function(model)
	local keys = model:FindFirstChild("Keys", true)
	if not keys then
		return nil
	end
	local list = {}
	for _, k in ipairs(keys:GetChildren()) do
		local cd = k:FindFirstChildOfClass("ClickDetector")
		if cd then
			list[#list + 1] = { part = k, cd = cd }
		end
	end
	if #list == 0 then
		return nil
	end
	return list
end

-- available = touchable root part (shards) or a live interaction prompt
-- (valves, generators, snow piles, trash).  A task whose own counter is full is
-- never available, whatever its prompt still says.
local function isObjectiveAvailable(model)
	if TASK.done(model) then
		return false
	end
	local hrp = model:FindFirstChild("HumanoidRootPart")
	if hrp and isShardAvailable(hrp) then
		return true
	end
	if hasEnabledPrompt(model) then
		return true
	end
	-- snow piles gate their ObjectivePrompt behind equipping the shovel (the game
	-- disables it again the moment the shovel is put away), so a pile whose
	-- prompt is currently disabled would otherwise look unavailable and get
	-- skipped forever.  The pile is a real, unfinished task regardless.
	if snowPileParts(model) then
		return true
	end
	return false
end

-- ---------------------------------------------------------------------------
-- objective auto-collect (unified)
--
-- Two collection styles exist in Pillar Chase:
--   * touch shards - Map.ObjectiveInteract1, each model owns a touchable
--     HumanoidRootPart; standing on it makes the game's own Touched code
--     collect it (verified live).
--   * prompts      - snow piles (ObjectiveInteract: Twigs + a SnowPile part)
--     and trash (ObjectiveInteract2: TrashPile debris).  Every part exposes a
--     ProximityPrompt and the game's client task script does the work when the
--     prompt fires (trash: 3 fires per debris part, 12 parts per pile).
--
-- The tick picks the nearest available objective across every
-- ObjectiveInteract* folder and does whichever style applies.
-- ---------------------------------------------------------------------------

-- world position to stand on for an objective model
local function objectivePosition(model)
	if model:IsA("BasePart") then
		return model.Position
	end
	local hrp = model:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		return hrp.Position
	end
	for _, name in ipairs({ "SnowPile", "TrashPile", "Trash", "Union" }) do
		local p = model:FindFirstChild(name, true)
		if p and p:IsA("BasePart") then
			return p.Position
		end
	end
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			return d.Position
		end
	end
	return nil
end

-- How long to wait between fires for one target.  With "Instant prompts" on
-- there is no hold to respect, so fires go out as fast as the tick allows -
-- trash needs several fires per debris part and a flat 0.9s cadence made it
-- crawl.  Without it, the prompt's own hold duration must be respected or the
-- press is lost.
local function fireCadence(model)
	if STATE.instantPrompt then
		return 0.04
	end
	local hold = 0
	for _, d in ipairs(model:GetDescendants()) do
		if isTaskPrompt(d) then
			if d.HoldDuration > hold then
				hold = d.HoldDuration
			end
		end
	end
	return math.max(0.22, hold + 0.2)
end

-- fire every live prompt under a model (trash needs 3 fires per part; the tick
-- re-fires until the part is gone)
local function fireObjectivePrompts(model)
	local fired = 0
	for _, d in ipairs(model:GetDescendants()) do
		if isTaskPrompt(d) then
			fired = fired + 1
			-- Instant prompts skip the E hold entirely; otherwise give the
			-- prompt its own hold time plus a little slack.
			local hold = STATE.instantPrompt and 0 or (d.HoldDuration + 0.05)
			pcall(function()
				if type(fireproximityprompt) == "function" then
					fireproximityprompt(d, hold)
				end
			end)
		end
	end
	return fired
end

-- objective value that a task model feeds, so the collector can tell when a
-- task actually landed and move straight on to the next one.
local function objectiveValueFor(model)
	local c = model.Parent
	while c and not (type(c.Name) == "string" and string.sub(c.Name, 1, 17) == "ObjectiveInteract") do
		c = c.Parent
	end
	if not c or not c.Parent then
		return nil
	end
	local n = string.match(c.Name, "(%d+)$") or "1"
	local obj = c.Parent:FindFirstChild("Objectives" .. n)
	if obj and type(obj.Value) == "number" then
		return obj.Value
	end
	return nil
end

-- vent task ("Clean off vents"): the lever alone completes a vent, debris and
-- all, so the collector just teleports vent to vent and pulls it.
local function ventLever(model)
	if not model:FindFirstChild("DebrisFolder") then
		return nil
	end
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("ProximityPrompt") and tostring(d.ActionText) == "restart vent" then
			return d
		end
	end
	return nil
end

-- gear / generator task ("Generators repaired with gears") ----------------
-- Gears lie around the map with a pickup prompt; picking one up puts a "Gear"
-- into Character.Inventory.  The generator's prompt opens a drag-the-gear UI,
-- and every gear dropped in fires the AddGear remote, which raises the
-- generator's LockLeft counter.  Fill it to Max and the generator is repaired.
local function gearFolder(map)
	return map and map:FindFirstChild("Gears") or nil
end

local function invGearCount(char)
	local inv = char and char:FindFirstChild("Inventory")
	if not inv then
		return 0
	end
	local n = 0
	for _, c in ipairs(inv:GetChildren()) do
		if c.Name == "Gear" then
			n = n + 1
		end
	end
	return n
end

local function nearestGear(origin)
	local folder = gearFolder(mapNow())
	if not folder then
		return nil
	end
	local best, bestD, bestPart, bestPrompt
	for _, g in ipairs(folder:GetChildren()) do
		local pp = g:FindFirstChildWhichIsA("ProximityPrompt", true)
		local part = g:FindFirstChildWhichIsA("BasePart", true)
		if pp and pp.Enabled and part then
			local d = origin and (part.Position - origin).Magnitude or 0
			if not bestD or d < bestD then
				best, bestD, bestPart, bestPrompt = g, d, part, pp
			end
		end
	end
	return best, bestPart, bestPrompt
end

local function generatorParts(model)
	if model.Name ~= "Generator" then
		return nil
	end
	local prom
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("ProximityPrompt") and d.Name == "ObjectivePrompt" then
			prom = d
			break
		end
	end
	if not prom then
		return nil
	end
	return prom, prom:FindFirstChild("LockLeft")
end

-- containers this session services.
--
-- There is ONE master switch (STATE.autoCollect, shown as "Auto tasks"): when
-- it is off this returns nothing, so the hub never teleports you anywhere on
-- its own.  It is off by default and is fully independent of the ESP.
local function collectorFolders(map, force)
	local list = {}
	if not (STATE.autoCollect or force) then
		return list
	end
	local only = STATE.taskGroup
	for _, c in ipairs(objectiveFolders(map)) do
		-- "All" sweeps every group; anything else pins the collector to one
		-- task group so a single objective gets finished instead of the tick
		-- hopping between them.
		if only == nil or only == "" or only == "All" or c.Name == only then
			list[#list + 1] = c
		end
	end
	return list
end

-- `skip` (optional) is a set of models the auto-collector has already found it
-- cannot clear (e.g. a drag-to-turn valve). They are ignored while their
-- cooldown is live so the tick moves on to something it can actually finish.
--
-- Tasks the collector has a purpose-built, verified driver for are preferred
-- over generic prompt objects, so a nearby unsupported prop never starves a
-- task we can actually finish (e.g. cells vs vents on Rusted Stronghold).
local function taskRank(model, map)
	if ventLever(model) then
		return 1
	end
	if snowPileParts(model) then
		return 2
	end
	if generatorParts(model) then
		return 3
	end
	if TASK.valve(model, map) then
		return 3
	end
	-- a scripted minigame (power matrix / blood drain): completable through the
	-- WorkTask's own AddStuff, so it beats a plain prompt object.
	if TASK.forModel(map, model) then
		return 4
	end
	local dd, fb = boneDragParts(model, map)
	if dd and fb then
		return 5
	end
	return 6
end

local function findNearestObjective(origin, force, skip)
	local map = mapNow()
	local now = os.clock()
	local best, bestD, bestPos, bestRank
	for _, container in ipairs(collectorFolders(map, force)) do
		for _, model in ipairs(container:GetChildren()) do
			local skipped = skip and skip[model] and skip[model] > now
			if not skipped and isObjectiveAvailable(model) then
				local p = objectivePosition(model)
				if p then
					local d = origin and (p - origin).Magnitude or 0
					local rank = taskRank(model, map)
					if not bestD or rank < bestRank or (rank == bestRank and d < bestD) then
						best, bestD, bestPos, bestRank = model, d, p, rank
					end
				end
			end
		end
	end
	return best, bestD, bestPos
end

-- objective ESP + progress readout (runs on the task cadence, not per frame)
local function stepShardEsp()
	local inRound, status, mapName = roundInfo()
	ROUND.inRound = inRound
	ROUND.status = status
	ROUND.map = mapName

	local map = mapNow()
	local seen = {}
	local avail = 0

	-- single-task picker: rescan only when the map changes or a button was hit,
	-- so the per-frame cost is nothing.
	if taskPickerDirty or taskPickerShownMap ~= mapName then
		taskPickerDirty = false
		taskPickerShownMap = mapName
		pcall(refreshTaskPicker, map)
	end

	if inRound and map then
		for _, container in ipairs(objectiveFolders(map)) do
			for _, model in ipairs(container:GetChildren()) do
				if isObjectiveAvailable(model) then
					avail = avail + 1
					if STATE.shardEsp then
						seen[model] = true
						local hl = shardRecs[model]
						if not (hl and hl.Parent) then
							hl = new("Highlight", {
								Name = "PCHub_ShardHL",
								FillTransparency = 0.6,
								OutlineTransparency = 0.05,
								DepthMode = Enum.HighlightDepthMode.AlwaysOnTop,
								Adornee = model,
							}, shardFolder)
							shardRecs[model] = hl
						end
						local colour = rgb(STATE.shardColor)
						hl.FillColor = colour
						hl.OutlineColor = colour
						hl.Adornee = model
						hl.Enabled = true
					end
				end
			end
		end
	end

	for model, hl in pairs(shardRecs) do
		if not seen[model] then
			hl:Destroy()
			shardRecs[model] = nil
		end
	end

	shardAvail = avail

	-- shared readout (also consumed by the Info tab and the round banner)
	pcall(function()
		if infoStatus then
			infoStatus.Text = "Status: " .. status
			infoStatus.TextColor3 = inRound and THEME.on or THEME.dim
		end
		if infoMap then
			infoMap.Text = "Map: " .. (mapName or "-")
		end
		if bannerText then
			bannerText.Text = status
			bannerText.TextColor3 = inRound and THEME.on or THEME.dim
		end
		if bannerMap then
			bannerMap.Text = mapName or ""
		end
		if bannerDot then
			bannerDot.BackgroundColor3 = inRound and THEME.on or THEME.off
		end
	end)

	if not (inRound and map) then
		pcall(function()
			infoObj1.Text = "Objective 1: -"
			infoObj2.Text = "Objective 2: -"
			infoExit.Text = "Exit located: -"
			infoShards.Text = "Objectives left: -"
		end)
		return
	end

	pcall(function()
		local o1 = map:FindFirstChild("Objectives1")
		local o2 = map:FindFirstChild("Objectives2")
		local exit = map:FindFirstChild("ExitLocated")
		local n1 = o1 and o1:FindFirstChild("ObjName")
		local n2 = o2 and o2:FindFirstChild("ObjName")
		if o1 then
			local mx = o1:FindFirstChild("Max")
			infoObj1.Text = string.format("%s: %d / %d",
				(n1 and n1.Value ~= "" and n1.Value) or "Objective 1", o1.Value, mx and mx.Value or 100)
		else
			infoObj1.Text = "Objective 1: -"
		end
		if o2 then
			local mx = o2:FindFirstChild("Max")
			infoObj2.Text = string.format("%s: %d / %d",
				(n2 and n2.Value ~= "" and n2.Value) or "Objective 2", o2.Value, mx and mx.Value or 10)
		else
			infoObj2.Text = "Objective 2: -"
		end
		infoExit.Text = "Exit located: " .. (exit and tostring(exit.Value) or "-")
		infoShards.Text = "Objectives left: " .. avail
		if bannerMap then
			local function prog(o)
				if not o then
					return nil
				end
				local mx = o:FindFirstChild("Max")
				return string.format("%d/%d", o.Value, mx and mx.Value or 0)
			end
			local p1, p2 = prog(o1), prog(o2)
			local parts = { mapName or "" }
			if p1 then
				parts[#parts + 1] = p1
			end
			if p2 then
				parts[#parts + 1] = p2
			end
			bannerMap.Text = table.concat(parts, "   ·   ")
		end
	end)
end

-- manual collection (Tasks tab button + handle.collectOneShard)
function collectOneShard()
	local inRound = roundInfo()
	if not inRound then
		return false
	end
	local char = LP.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not char or not hrp then
		return false
	end
	local model, _, pos = findNearestObjective(hrp.Position, true)
	if not model or not pos then
		return false
	end
	local dd, fb = boneDragParts(model, mapNow())
	if dd and fb then
		return carryBoneToFire(char, model, dd, fb)
	end
	pcall(function()
		char:PivotTo(CFrame.new(pos + Vector3.new(0, STATE.collectHeight, 0)))
	end)
	fireObjectivePrompts(model)
	return true
end

-- ---------------------------------------------------------------------------
-- Teleport tab engine
--
-- Scan-first: work out where we are (lobby / in round / dead / over) and which
-- map, THEN list each of the game's own task groups with the number of objects
-- still live.  Teleporting is just moving the character and letting the game's
-- own prompt fire - the server sees an ordinary player.
-- ---------------------------------------------------------------------------

-- ExitLocations is a direct child of Map on most maps, but on a few it is nested
-- deeper or wrapped in a folder, so find it by name recursively.  A map's exit
-- can be a single part, a model, or a folder holding either.
local function exitLocationFolder(map)
	if not map then
		return nil
	end
	return map:FindFirstChild("ExitLocations") or map:FindFirstChild("ExitLocations", true)
end

local function collectExitParts(container, out, depth)
	depth = depth or 0
	if depth > 3 or #out >= 24 then
		return
	end
	if container:IsA("BasePart") then
		out[#out + 1] = container
	elseif container:IsA("Model") then
		if container:FindFirstChildWhichIsA("BasePart", true) then
			out[#out + 1] = container
		end
	else
		for _, c in ipairs(container:GetChildren()) do
			collectExitParts(c, out, depth + 1)
		end
	end
end

-- a real exit carries the game's own escape prompt; a decorative twin (some maps
-- ship two Exit models) does not, so we can use that to put the tag on the right one.
local function hasEscapePrompt(inst)
	for _, d in ipairs(inst:GetDescendants()) do
		if d:IsA("ProximityPrompt") then
			if d.Name == "EscapePrompt" or string.find(string.lower(tostring(d.ActionText)), "escape") then
				return true
			end
		end
	end
	return false
end

-- the instances that represent the exit (for the ESP)
local function exitTargets(map)
	local all = {}
	local loc = exitLocationFolder(map)
	if not loc then
		return all
	end
	if loc:IsA("BasePart") or loc:IsA("Model") then
		all[#all + 1] = loc
	else
		for _, c in ipairs(loc:GetChildren()) do
			collectExitParts(c, all)
		end
	end
	-- prefer the exit(s) that actually carry the escape prompt, so the outline
	-- and EXIT tag sit on the real escape rather than a look-alike model
	local real = {}
	for _, t in ipairs(all) do
		if hasEscapePrompt(t) then
			real[#real + 1] = t
		end
	end
	if #real > 0 then
		return real
	end
	return all
end

local function exitPosition(map)
	for _, t in ipairs(exitTargets(map)) do
		if t:IsA("BasePart") then
			return t.Position
		elseif t:IsA("Model") then
			local primary = t.PrimaryPart or t:FindFirstChildWhichIsA("BasePart", true)
			if primary then
				return primary.Position
			end
		end
	end
	return nil
end

local function nearestInFolder(folder, origin)
	local best, bestD, bestPos
	for _, model in ipairs(folder:GetChildren()) do
		if isObjectiveAvailable(model) then
			local p = objectivePosition(model)
			if p then
				local d = origin and (p - origin).Magnitude or 0
				if not bestD or d < bestD then
					best, bestD, bestPos = model, d, p
				end
			end
		end
	end
	return best, bestD, bestPos
end

local function teleportTo(pos)
	if not pos then
		return false
	end
	local char = LP.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not char or not hrp then
		return false
	end
	return pcall(function()
		char:PivotTo(CFrame.new(pos + Vector3.new(0, STATE.collectHeight, 0)))
	end)
end

local function clearGuiList(list)
	if not (list and list.Parent) then
		return
	end
	for _, c in ipairs(list:GetChildren()) do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
end

local function clearTPList()
	clearGuiList(TP and TP.list)
	clearGuiList(TP and TP.players)
end

local function addTPRow(order, text, enabled, action, parent)
	parent = parent or (TP and TP.list)
	if not (TP and parent) then
		return
	end
	local row = new("Frame", {
		Size = UDim2.new(1, 0, 0, 28),
		BackgroundTransparency = 1,
		LayoutOrder = order,
		ZIndex = 2,
	}, parent)
	new("TextLabel", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(6, 0),
		Size = UDim2.new(1, -74, 1, 0),
		Font = Enum.Font.Gotham,
		Text = text,
		TextSize = 12,
		TextColor3 = enabled and THEME.text or THEME.dim,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 2,
	}, row)
	if enabled and action then
		local go = new("TextButton", {
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -2, 0.5, 0),
			Size = UDim2.fromOffset(58, 22),
			BackgroundColor3 = THEME.button,
			BorderSizePixel = 0,
			Font = Enum.Font.GothamBold,
			Text = "GO",
			TextSize = 12,
			TextColor3 = THEME.accent,
			AutoButtonColor = false,
			ZIndex = 3,
		}, row)
		corner(go, 6)
		stroke(go, THEME.accent, 1, 0.8)
		go.MouseEnter:Connect(function()
			go.BackgroundColor3 = THEME.buttonHi
		end)
		go.MouseLeave:Connect(function()
			go.BackgroundColor3 = THEME.button
		end)
		go.MouseButton1Click:Connect(function()
			action()
		end)
	end
	return row
end

local function liveOrigin()
	local char = LP.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	return hrp and hrp.Position or nil
end

TP = TP or {}
TP.active = false
TP.refresh = function()
	if not (TP.list and TP.list.Parent) then
		return
	end
	local inRound, status, mapName = roundInfo()
	local map = mapNow()

	if TP.status then
		TP.status.Text = "Status: " .. status
		TP.status.TextColor3 = inRound and THEME.on or THEME.dim
	end
	if TP.map then
		TP.map.Text = "Map: " .. (mapName or "-")
	end

	clearTPList()

	if not (inRound and map) then
		if TP.obj1 then
			TP.obj1.Text = "Objective 1: -"
		end
		if TP.obj2 then
			TP.obj2.Text = "Objective 2: -"
		end
		if TP.exit then
			TP.exit.Text = "Exit located: -"
		end
		addTPRow(1, "Not in a live round right now.", false)
		if TP.players then
			addTPRow(1, "Players list only fills in a live round.", false, nil, TP.players)
		end
		return
	end

	local o1 = map:FindFirstChild("Objectives1")
	local o2 = map:FindFirstChild("Objectives2")
	local ex = map:FindFirstChild("ExitLocated")
	local n1 = o1 and o1:FindFirstChild("ObjName")
	local n2 = o2 and o2:FindFirstChild("ObjName")
	if TP.obj1 then
		local mx = o1 and o1:FindFirstChild("Max")
		TP.obj1.Text = o1
				and string.format("%s: %d / %d", (n1 and n1.Value ~= "" and n1.Value) or "Objective 1", o1.Value, mx and mx.Value or 100)
			or "Objective 1: -"
	end
	if TP.obj2 then
		local mx = o2 and o2:FindFirstChild("Max")
		TP.obj2.Text = o2
				and string.format("%s: %d / %d", (n2 and n2.Value ~= "" and n2.Value) or "Objective 2", o2.Value, mx and mx.Value or 10)
			or "Objective 2: -"
	end
	if TP.exit then
		TP.exit.Text = "Exit located: " .. (ex and (ex.Value and "Yes" or "Not yet") or "-")
	end

	local order = 0
	for _, folder in ipairs(objectiveFolders(map)) do
		order += 1
		local count = 0
		for _, model in ipairs(folder:GetChildren()) do
			if isObjectiveAvailable(model) then
				count += 1
			end
		end
		local label = string.format("%s  -  %d left", folder.Name, count)
		if count == 0 then
			addTPRow(order, label .. "  (cleared)", false)
		else
			addTPRow(order, label, true, function()
				local _, _, pos = nearestInFolder(folder, liveOrigin())
				teleportTo(pos)
			end)
		end
	end
	if order == 0 then
		addTPRow(1, "No task groups found on this map yet.", false)
		order = 1
	end

	order += 1
	local epos = exitPosition(map)
	local located = ex ~= nil and ex.Value == true
	if epos then
		addTPRow(order, located and "Exit  -  teleport to the exit" or "Exit  -  teleport to the exit (not revealed yet)", true, function()
			teleportTo(epos)
		end)
	else
		addTPRow(order, "Exit  -  no exit found on this map", false)
	end

	-- players: nearest first, with role + distance, tap GO to drop onto them
	if TP.players then
		clearGuiList(TP.players)
		local char = LP.Character
		local h0 = char and char:FindFirstChild("HumanoidRootPart")
		local origin = h0 and h0.Position or nil
		local rows = {}
		for _, p in ipairs(Players:GetPlayers()) do
			if p ~= LP then
				local c = p.Character
				local hrp = c and c:FindFirstChild("HumanoidRootPart")
				if hrp then
					local d = origin and (hrp.Position - origin).Magnitude or 0
					rows[#rows + 1] = { name = p.Name, pos = hrp.Position, d = d, role = roleOf(c, p) }
				end
			end
		end
		table.sort(rows, function(a, b)
			return a.d < b.d
		end)
		local po = 0
		for _, r in ipairs(rows) do
			po += 1
			local label = string.format("%s  -  %s  -  %d studs", r.name, tostring(r.role), math.floor(r.d + 0.5))
			addTPRow(po, label, true, function()
				teleportTo(r.pos)
			end, TP.players)
		end
		if po == 0 then
			addTPRow(1, "No other players in the round right now.", false, nil, TP.players)
		end
	end
end

TP.goNearest = function()
	local inRound = roundInfo()
	if not inRound then
		return false
	end
	local _, _, pos = findNearestObjective(liveOrigin(), true)
	return teleportTo(pos)
end

TP.goExit = function()
	local map = mapNow()
	if not map then
		return false
	end
	return teleportTo(exitPosition(map))
end

-- auto-collect state machine: lock onto one objective, keep touching / firing
-- until it clears, pause collectDelay, then move on.  A target that survives
-- the whole dwell without clearing is remembered in `skip` for a while: some
-- tasks (the "Turn valve" panels) are drag gestures that no prompt fire can
-- satisfy, so re-locking onto them forever would stall everything else.
local AC = { target = nil, started = 0, nextAt = 0, touch = false, lastFire = 0, value0 = nil, genOpened = false, addGear = nil, gearTries = 0, gearTarget = nil, gearDisabled = false, skip = {} }

local function autoCollectTick(now)
	if not STATE.autoCollect then
		AC.target = nil
		return
	end
	-- never act outside a live round (no map, dead, loading)
	local inRound = roundInfo()
	if not inRound then
		AC.target = nil
		return
	end
	local char = LP.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not char or not hrp then
		AC.target = nil
		return
	end
	local map = mapNow()

	-- new map / round: forget per-map caches so nothing carries over
	if AC.gearMap ~= map then
		AC.gearMap = map
		AC.gearDisabled = false
		AC.gearTarget = nil
		AC.gearTries = 0
		AC.addGear = nil
		AC.skip = {}
	end

	-- the single-task pin changed: drop the current target so the tick re-picks
	-- inside the newly selected group instead of finishing the old one.
	if AC.group ~= STATE.taskGroup then
		AC.group = STATE.taskGroup
		AC.target = nil
		AC.skip = {}
		AC.carry = nil
		AC.cadenceTarget = nil
	end

	-- Monsters never run survivor objectives: walking around firing their
	-- prompts would sabotage the round and never advances anything.
	if roleOf(char, LP) == "Monster" then
		AC.target = nil
		return
	end

	-- gear / generator maps: keep a gear in hand before heading to a panel
	if gearFolder(map) and not AC.gearDisabled and invGearCount(char) == 0 then
		local gear, gpart, gprom = nearestGear(hrp.Position)
		if gear and gpart and gprom then
			pcall(function()
				char:PivotTo(CFrame.new(gpart.Position + Vector3.new(0, STATE.collectHeight, 0)))
			end)
			if AC.gearTarget ~= gear then
				AC.gearTarget = gear
				AC.gearTries = 0
			end
			if now - AC.lastFire >= 0.2 then
				AC.lastFire = now
				AC.gearTries = AC.gearTries + 1
				-- a pickup prompt still needs its own hold -- firing it with a
				-- zero hold is refused and the gear never enters the inventory.
				pcall(function()
					fireproximityprompt(gprom, math.max(gprom.HoldDuration, 0.05))
				end)
				if AC.gearTries >= 5 and invGearCount(char) == 0 then
					-- pickup is not landing: stop trying and go straight at the
					-- generators with prompts only
					AC.gearDisabled = true
				end
			end
			AC.target = nil
			return
		end
	end

	if AC.target then
		local t = AC.target
		if not t.Parent or not isObjectiveAvailable(t) then
			-- cleared (or gone): brief pause, then find the next one.  If we had
			-- a task GUI open on it, dismiss it so no screen effect is left on.
			if AC.genOpened or AC.valveOpened or AC.mgOpened then
				TASK.close(map, t)
			end
			AC.target = nil
			AC.skip[t] = nil
			AC.nextAt = now + STATE.collectDelay
			pcall(function()
				char:SetAttribute("HoldingItem", nil)
			end)
			return
		end
		-- task landed: the objective value rose, so sideline this model and move
		-- on immediately (vents stay in the world after completion, so this is
		-- what stops us pulling the same lever over and over).
		local v0 = objectiveValueFor(t)
		if v0 and AC.value0 and v0 > AC.value0 then
			if AC.genOpened or AC.valveOpened or AC.mgOpened then
				TASK.close(map, t)
			end
			AC.skip[t] = now + 60
			AC.target = nil
			AC.nextAt = now
			pcall(function()
				char:SetAttribute("HoldingItem", nil)
			end)
			return
		end
		-- monster safety: if a monster is inside the bail-out radius, drop the
		-- task and move on rather than stand still in the open.
		if STATE.taskSafety then
			local md = nearestMonsterDist(hrp.Position)
			if md and md <= STATE.taskSafetyDist then
				AC.skip[t] = now + 6
				AC.target = nil
				AC.nextAt = now + STATE.collectDelay
				pcall(function()
					char:SetAttribute("HoldingItem", nil)
				end)
				return
			end
		end
		-- generators: open the repair task, then feed gears in through the same
		-- AddGear remote the drag UI uses; LockLeft counts them.
		local gprom, glock = generatorParts(t)
		if gprom then
			local gmax = (glock and glock:GetAttribute("Max")) or 5
			if glock and glock.Value >= gmax then
				TASK.close(map, t)
				AC.skip[t] = now + 60
				AC.target = nil
				AC.nextAt = now
				return
			end
			-- no gear in hand: never open the repair UI (it freezes you).  Drop
			-- the target so the tick goes and fetches one instead.
			if invGearCount(char) == 0 then
				if AC.genOpened then
					TASK.close(map, t)
					AC.genOpened = false
				end
				AC.target = nil
				AC.nextAt = now
				return
			end
			local gpos = objectivePosition(t)
			if gpos then
				pcall(function()
					char:PivotTo(CFrame.new(gpos + Vector3.new(0, STATE.collectHeight, 0)))
				end)
			end
			if not AC.genOpened then
				AC.genOpened = true
				pcall(function()
					fireproximityprompt(gprom, STATE.instantPrompt and 0 or gprom.HoldDuration)
				end)
				return
			end
			if now - AC.lastFire >= 0.12 then
				AC.lastFire = now
				if not AC.addGear then
					local wg = mapNow()
					wg = wg and wg:FindFirstChild("WorkGear", true)
					AC.addGear = wg and wg:FindFirstChild("AddGear") or nil
				end
				if AC.addGear then
					pcall(function()
						AC.addGear:FireServer()
					end)
				end
			end
			if glock and gmax and glock.Value >= gmax then
				TASK.close(map, t)
				AC.skip[t] = now + 60
				AC.target = nil
				AC.nextAt = now
			elseif now - AC.started > 12 then
				TASK.close(map, t)
				AC.skip[t] = now + 20
				AC.target = nil
				AC.nextAt = now + STATE.collectDelay
			end
			return
		end
		-- vents: one pull of the lever completes the whole vent, so teleport
		-- vent-to-vent and yank it instantly.
		local lever = ventLever(t)
		if lever then
			local vpos = objectivePosition(t)
			if vpos then
				pcall(function()
					char:PivotTo(CFrame.new(vpos + Vector3.new(0, STATE.collectHeight, 0)))
				end)
			end
			if now - AC.lastFire >= 0.12 then
				AC.lastFire = now
				if not lever.Enabled then
					lever.Enabled = true
				end
				pcall(function()
					fireproximityprompt(lever, STATE.instantPrompt and 0 or lever.HoldDuration)
				end)
			end
			if now - AC.started > 10 then
				-- lever never landed: sideline this vent and move on
				AC.skip[t] = now + 20
				AC.target = nil
				AC.nextAt = now
			end
			return
		end
		-- shut-off valve: open the task once, then drive its own counter to Max
		-- so the game's completion (AddStuff + GUI teardown) runs.  RemoveMe is
		-- fired on every exit so the task screen never sticks.
		local vprompt, vlock = TASK.valve(t, map)
		if vprompt then
			local vpos = objectivePosition(t)
			if vpos then
				pcall(function()
					char:PivotTo(CFrame.new(vpos + Vector3.new(0, STATE.collectHeight, 0)))
				end)
			end
			local vmax = vlock and vlock:GetAttribute("Max")
			if vlock and vmax and vlock.Value >= vmax then
				TASK.close(map, t)
				AC.skip[t] = now + 60
				AC.target = nil
				AC.nextAt = now
				return
			end
			if not AC.valveOpened then
				AC.valveOpened = true
				AC.valveTries = 0
				AC.valveAt = now
				pcall(function()
					if not vprompt.Enabled then
						vprompt.Enabled = true
					end
					fireproximityprompt(vprompt, STATE.instantPrompt and 0 or vprompt.HoldDuration)
				end)
				return
			end
			-- the task GUI is up: run the game's own completion by filling the
			-- counter; the WorkTask then fires AddStuff and closes itself.
			if vlock and vmax and now - AC.valveAt >= 0.4 then
				AC.valveTries = (AC.valveTries or 0) + 1
				pcall(function()
					vlock.Value = vmax
				end)
				local v0 = objectiveValueFor(t)
				if v0 and AC.value0 and v0 > AC.value0 then
					TASK.close(map, t)
					AC.skip[t] = now + 60
					AC.target = nil
					AC.nextAt = now
					return
				end
				if AC.valveTries >= 3 then
					local wt = TASK.forModel(map, t)
					local add = wt and wt:FindFirstChild("AddStuff")
					if add then
						pcall(function()
							add:FireServer()
						end)
					end
				end
				if AC.valveTries >= 6 or now - AC.valveAt > 4 then
					TASK.close(map, t)
					AC.skip[t] = now + 20
					AC.target = nil
					AC.nextAt = now + STATE.collectDelay
				end
			end
			return
		end
		-- Slimey Dungeon / Rusted Stronghold chest.  Lockpicking is a ring/zone
		-- QTE whose client script only runs once the SERVER assigns its
		-- CurrentTask; firing the prompt or AddStuff from the client does not
		-- start it (verified live -- LockLeft never moves).  So don't waste
		-- round time trying: only take the treasure out of a chest someone
		-- else already picked (LockLeft <= 0), and skip untouched chests fast.
		local clock, _, pickP = TASK.chest(t)
		if clock then
			if clock.Value <= 0 and pickP and pickP.Enabled then
				local cpos = objectivePosition(t)
				if cpos then
					pcall(function()
						char:PivotTo(CFrame.new(cpos + Vector3.new(0, STATE.collectHeight, 0)))
					end)
				end
				pcall(function()
					fireproximityprompt(pickP, STATE.instantPrompt and 0 or math.max(pickP.HoldDuration, 0.05))
				end)
				AC.skip[t] = now + 30
			else
				-- can't pick it ourselves: skip fast so the collector keeps moving
				AC.skip[t] = now + 20
			end
			AC.target = nil
			AC.nextAt = now
			return
		end
		-- scripted minigame.  Two shapes share this WorkTask:
		--   * power matrix (LockLeft HAS a Max, counts UP): the game lights the
		--     next key bright green; only a real click (the key's own
		--     ClickDetector) advances it, so press the lit key.
		--   * blood drain (LockLeft has NO Max, counts DOWN): completion is
		--     client-driven -- its Changed handler fires AddStuff and bumps the
		--     objective the instant the counter hits zero -- so drive it to zero.
		-- Either way the task GUI is only ever dismissed through the game's own
		-- RemoveMe, so no full-screen effect is left behind.
		local mwt = TASK.forModel(map, t)
		if mwt then
			local mlock = TASK.counter(t)
			local mmax = mlock and mlock:GetAttribute("Max")
			local mpos = objectivePosition(t)
			if mpos then
				pcall(function()
					char:PivotTo(CFrame.new(mpos + Vector3.new(0, STATE.collectHeight, 0)))
				end)
			end
			if not AC.mgOpened then
				AC.mgOpened = true
				AC.mgTries = 0
				AC.mgAt = now
				AC.mgStart = now
				local mprompt = hasEnabledPrompt(t)
				if mprompt then
					pcall(function()
						if not mprompt.Enabled then
							mprompt.Enabled = true
						end
						fireproximityprompt(mprompt, STATE.instantPrompt and 0 or mprompt.HoldDuration)
					end)
				end
				return
			end
			local v0 = objectiveValueFor(t)
			if v0 and AC.value0 and v0 > AC.value0 then
				TASK.close(map, t)
				AC.skip[t] = now + 60
				AC.target = nil
				AC.nextAt = now
				return
			end
			if mlock and mmax and mlock.Value >= mmax then
				TASK.close(map, t)
				AC.skip[t] = now + 60
				AC.target = nil
				AC.nextAt = now
				return
			end
			-- blood drain: push the countdown to zero and let the game finish it
			if mlock and not mmax then
				if mlock.Value > 0 then
					pcall(function()
						mlock.Value = 0
					end)
				end
				if now - AC.mgAt >= 0.12 then
					AC.mgAt = now
					AC.mgTries = (AC.mgTries or 0) + 1
					if AC.mgTries >= 8 or now - AC.mgStart > 8 then
						TASK.close(map, t)
						AC.skip[t] = now + 20
						AC.target = nil
						AC.nextAt = now + STATE.collectDelay
					end
				end
				return
			end
			-- power matrix: press whichever key is lit bright green
			local keys = TASK.matrixKeys(t)
			if keys then
				if now - AC.mgAt >= 0.06 then
					AC.mgAt = now
					AC.mgTries = (AC.mgTries or 0) + 1
					local green = Color3.fromRGB(25, 255, 25)
					local lit
					for _, k in ipairs(keys) do
						if k.part.Color == green then
							lit = k
							break
						end
					end
					if lit then
						pcall(function()
							fireclickdetector(lit.cd)
						end)
					end
					if AC.mgTries >= 40 or now - AC.mgStart > 14 then
						TASK.close(map, t)
						AC.skip[t] = now + 20
						AC.target = nil
						AC.nextAt = now + STATE.collectDelay
					end
				end
				return
			end
			-- fallback: no key parts found -- poke the completion remote briefly
			if now - AC.mgAt >= 0.08 then
				AC.mgAt = now
				AC.mgTries = (AC.mgTries or 0) + 1
				local add = mwt:FindFirstChild("AddStuff")
				if add then
					pcall(function()
						add:FireServer()
					end)
				end
				if AC.mgTries >= 12 or now - AC.mgStart > 8 then
					TASK.close(map, t)
					AC.skip[t] = now + 20
					AC.target = nil
					AC.nextAt = now + STATE.collectDelay
				end
			end
			return
		end
		-- snow pile: the counter counts UP to its Max (8 digs per pile).  The
		-- game only lets its own swing fire the dig, and only with the shovel
		-- equipped, so equip it and then fire the dig remote directly - that
		-- skips the ~0.75s swing animation entirely.  If the remote is refused
		-- (not equipped / gated) we fall back to the prompt at the swing tempo.
		local sprompt, slock = snowPileParts(t)
		if sprompt then
			local spos = objectivePosition(t)
			if spos then
				pcall(function()
					char:PivotTo(CFrame.new(spos + Vector3.new(0, STATE.collectHeight, 0)))
				end)
			end
			local smax = slock and slock:GetAttribute("Max")
			-- done? the game keeps the pile around for its clear animation, so
			-- stop the moment its own counter is full and move on.
			if slock and smax and slock.Value >= smax then
				AC.skip[t] = now + 30
				AC.target = nil
				AC.nextAt = now
				return
			end
			-- branches first: the pile will not let you shovel until every Twig
			-- is picked up, and each pickup is its own prompt.  Pull the next
			-- live branch on a relaxed cadence so its pickup animation can land
			-- -- firing them in a burst just loses the presses.
			local branch = TASK.snowBranch(t)
			if branch then
				if now - AC.lastFire >= 0.45 then
					AC.lastFire = now
					pcall(function()
						if not branch.Enabled then
							branch.Enabled = true
						end
						fireproximityprompt(branch, math.max(branch.HoldDuration, 0.1) + 0.1)
					end)
				end
				if now - AC.started > 25 then
					AC.skip[t] = now + 15
					AC.target = nil
					AC.nextAt = now + STATE.collectDelay
				end
				return
			end
			local tool = shovelTool(char)
			if tool then
				equipTool(char, tool)
			end
			local dig = slock and snowDigRemote(map)
			local direct = dig ~= nil and AC.snowMode ~= "prompt"
			-- direct digs are quick but still leave the game room to register
			-- each one; the prompt route needs the whole 0.75s swing.
			local cadence = direct and 0.12 or 0.5
			if now - AC.lastFire >= cadence then
				AC.lastFire = now
				if direct then
					AC.snowTries = (AC.snowTries or 0) + 1
					if AC.snowVal0 == nil then
						AC.snowVal0 = slock.Value
					end
					pcall(function()
						dig:FireServer(slock)
					end)
					-- six digs with the counter never moving means the server is
					-- not taking the remote: switch to the prompt route.
					if AC.snowTries >= 6 and slock.Value == (AC.snowVal0 or slock.Value) then
						AC.snowMode = "prompt"
					end
				else
					pcall(function()
						if not sprompt.Enabled then
							sprompt.Enabled = true
						end
						fireproximityprompt(sprompt, STATE.instantPrompt and 0 or sprompt.HoldDuration)
					end)
				end
			end
			if now - AC.started > 20 then
				-- stalled (pile not ready / already cleared elsewhere): move on
				AC.skip[t] = now + 15
				AC.target = nil
				AC.nextAt = now + STATE.collectDelay
			end
			return
		end
		-- carry-to-destination: grab with the game's own drag prompt, walk the
		-- prop to a free slot, drop it there.  Firing the prompt alone only
		-- half-works (the prop follows you but the server never sees it held),
		-- so this drives the real hold/begin/end cycle instead.
		local cdd, cslots = carryDropOff(t, map)
		if cdd and cslots and #cslots > 0 and not AC.touch and not boneDragParts(t, map) then
			local carry = AC.carry
			if not carry or carry.model ~= t then
				carry = { model = t, stage = "grab", at = now, press = 0, tries = 0, bad = {} }
				AC.carry = carry
			end
			local cprompt = t:FindFirstChildWhichIsA("ProximityPrompt", true)
			local here = carryPos(t)
			-- slots that have already refused this cell are not offered again
			local usable = {}
			for _, s in ipairs(cslots) do
				if not carry.bad[s] then
					usable[#usable + 1] = s
				end
			end
			local slot = nearestSlot(usable, here)
			if carry.stage == "grab" then
				local tpos = objectivePosition(t)
				if tpos then
					pcall(function()
						char:PivotTo(CFrame.new(tpos + Vector3.new(0, STATE.collectHeight, 0)))
					end)
				end
				if cdd.ReferenceInstance == char then
					-- grabbed: start walking it to the panel
					carry.stage = "carry"
					carry.at = now
					carry.press = 0
				elseif now - carry.press >= 0.5 then
					carry.press = now
					holdPrompt(cprompt)
				end
			elseif carry.stage == "carry" then
				if slot then
					pcall(function()
						char:PivotTo(CFrame.new(slot.Position + Vector3.new(0, STATE.collectHeight, 0)))
					end)
				end
				-- the game keeps a held prop glued to the character, so wait for
				-- it to arrive (or give it a few seconds) before dropping.
				if not here or not slot or (here - slot.Position).Magnitude <= 9 or now - carry.at > 2.0 then
					carry.stage = "drop"
					carry.at = now
					carry.press = 0
					carry.tries = 0
					-- remember the target holder's progress so a real placement
					-- can be told apart from a drop that silently did nothing.
					local holder = slot and slotHolder(slot)
					local req = holder and holder:FindFirstChild("Required")
					carry.req0 = req and req.Value or nil
				end
			else
				if slot then
					pcall(function()
						char:PivotTo(CFrame.new(slot.Position + Vector3.new(0, STATE.collectHeight, 0)))
					end)
				end
				-- confirmed by the holder's own counter: once it ticks up the cell
				-- is really seated, so move straight on to the next cell.
				local holder = slot and slotHolder(slot)
				local req = holder and holder:FindFirstChild("Required")
				if req and carry.req0 and req.Value > carry.req0 then
					AC.carry = nil
					AC.target = nil
					AC.skip[t] = now + 2
					AC.nextAt = now + STATE.collectDelay
					pcall(function()
						char:SetAttribute("HoldingItem", nil)
					end)
					return
				end
				if now - carry.at > 0.3 and now - carry.press >= 0.45 then
					carry.press = now
					carry.tries = carry.tries + 1
					holdPrompt(cprompt)
				end
				if carry.tries >= 3 then
					-- this slot is not taking it: blacklist it and try another
					if slot then
						carry.bad[slot] = true
					end
					carry.tries = 0
					if #usable <= 1 then
						-- nothing else to try for this cell right now; come back later
						AC.skip[t] = now + 8
						AC.carry = nil
						AC.target = nil
						AC.nextAt = now + STATE.collectDelay
					else
						carry.stage = "carry"
						carry.at = now
					end
				end
			end
			return
		end
		if now - AC.started > 12 then
			-- not progressing (unreachable, or a gesture we cannot fire):
			-- sideline it for a while so the tick can service other targets.
			-- 12s leaves room for multi-fire tasks (trash needs several fires
			-- per debris part) instead of abandoning them half-cleared.  Any
			-- task GUI we opened is dismissed so its screen effect never sticks.
			TASK.close(map, t)
			AC.skip[t] = now + 20
			AC.target = nil
			AC.nextAt = now + STATE.collectDelay
			return
		end
		-- bone / firepit: the real grab-then-carry, driven by the game's touch
		local dd, fb = boneDragParts(t, map)
		if dd and fb then
			if roleOf(char, LP) ~= "Monster" then
				pcall(function()
					carryBoneToFire(char, t, dd, fb)
				end)
			end
			return
		end
		local pos = objectivePosition(t)
		if pos then
			pcall(function()
				char:PivotTo(CFrame.new(pos + Vector3.new(0, STATE.collectHeight, 0)))
			end)
			-- fire on a cadence, not every tick: a prompt with a hold duration
			-- needs the whole press to count, and re-firing restarts it.
			if not AC.touch then
				if AC.cadenceTarget ~= t then
					AC.cadenceTarget = t
					AC.cadence = fireCadence(t)
				end
				if now - AC.lastFire >= AC.cadence then
					AC.lastFire = now
					-- an instant prompt has nothing to wait for, so send the
					-- whole burst a debris part needs in one go instead of one
					-- fire per cadence.
					local bursts = STATE.instantPrompt and 4 or 1
					for _ = 1, bursts do
						fireObjectivePrompts(t)
					end
				end
			end
		end
		return
	end

	if now < AC.nextAt then
		return
	end
	local model, _, pos = findNearestObjective(hrp.Position, nil, AC.skip)
	if model then
		AC.target = model
		AC.started = now
		AC.lastFire = 0
		AC.genOpened = false
		AC.snowMode = nil
		AC.snowTries = 0
		AC.snowVal0 = nil
		AC.valveOpened = false
		AC.mgOpened = false
		AC.chestOpened = false
		AC.qteAdd = nil
		AC.value0 = objectiveValueFor(model)
		local shrp = model:FindFirstChild("HumanoidRootPart")
		AC.touch = shrp ~= nil and isShardAvailable(shrp)
		if pos then
			pcall(function()
				char:PivotTo(CFrame.new(pos + Vector3.new(0, STATE.collectHeight, 0)))
			end)
			if not AC.touch then
				fireObjectivePrompts(model)
				AC.lastFire = now
			end
		end
	else
		-- nothing available (or everything is on a skip cooldown); prune dead
		-- skip entries while we wait, then re-check shortly
		for m, until_ in pairs(AC.skip) do
			if not m.Parent or until_ < now then
				AC.skip[m] = nil
			end
		end
		AC.nextAt = now + 0.2
	end
end

-- forward declaration: defined with the utility engine below, but called here.
local stepExitEsp

-- shared run flag (declared here so taskLoop below can capture it as an upvalue)
local running = true

local function taskLoop()
	local lastScan = 0
	local lastTP = 0
	while running do
		local now = os.clock()
		-- objective/exit scan is comparatively heavy (descendant walks), so
		-- run it on a slower cadence; auto-collect stays responsive.
		if now - lastScan >= 0.6 then
			lastScan = now
			pcall(stepShardEsp)
			pcall(stepExitEsp)
		end
		pcall(autoCollectTick, now)
		pcall(stepSprintAssist)
		-- refresh the Teleport readout once a second, only while it is shown
		if TP and TP.active and TP.refresh and gui.Enabled and now - lastTP >= 1.0 then
			lastTP = now
			pcall(TP.refresh)
		end
		task.wait(0.03)
	end
end

-- ==========================================================================
-- utility engine  ·  anti-AFK, fullbright, FOV, exit ESP, stats, panic
-- ==========================================================================

local Lighting = game:GetService("Lighting")
local VirtualUser = game:GetService("VirtualUser")
local Stats = game:GetService("Stats")

-- exit ESP ----------------------------------------------------------------
-- ExitLocations children are named differently per map ("ExitDoors", "Exit",
-- ...), so highlight every Model / BasePart directly under ExitLocations.
local exitFolder = new("Folder", { Name = "PCHub_Exit" }, Workspace)
local exitRecs = {} --- [instance] = { hl=, bb=, txt= }
local exitLocated = false

local function clearExit()
	for inst, rec in pairs(exitRecs) do
		if rec.hl then
			rec.hl:Destroy()
		end
		if rec.bb then
			rec.bb:Destroy()
		end
		exitRecs[inst] = nil
	end
end

local function makeExitRec(inst)
	local hl = new("Highlight", {
		Name = "PCHub_ExitHL",
		FillTransparency = 0.6,
		OutlineTransparency = 0.05,
		DepthMode = Enum.HighlightDepthMode.AlwaysOnTop,
		Adornee = inst,
	}, exitFolder)
	local bb = new("BillboardGui", {
		Name = "PCHub_ExitLBL",
		Size = UDim2.fromOffset(120, 22),
		StudsOffsetWorldSpace = Vector3.new(0, 4, 0),
		AlwaysOnTop = true,
		MaxDistance = math.huge,
		LightInfluence = 0,
		Enabled = true,
		Adornee = inst,
	}, exitFolder)
	local txt = new("TextLabel", {
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Font = Enum.Font.GothamBold,
		Text = "EXIT",
		TextSize = 14,
		TextColor3 = Color3.fromRGB(255, 255, 255),
		TextStrokeTransparency = 0.35,
		TextStrokeColor3 = Color3.fromRGB(0, 0, 0),
	}, bb)
	return { hl = hl, bb = bb, txt = txt }
end

function stepExitEsp()
	local map = mapNow()
	local flag = map and map:FindFirstChild("ExitLocated")
	exitLocated = flag ~= nil and flag.Value == true

	local want = {}
	if STATE.exitEsp and map then
		for _, inst in ipairs(exitTargets(map)) do
			want[inst] = true
		end
	end

	for inst, rec in pairs(exitRecs) do
		if not (want[inst] and inst.Parent) then
			rec.hl:Destroy()
			rec.bb:Destroy()
			exitRecs[inst] = nil
		end
	end

	local colour = rgb(STATE.exitColor)
	for inst in pairs(want) do
		local rec = exitRecs[inst]
		if not (rec and rec.hl.Parent) then
			rec = makeExitRec(inst)
			exitRecs[inst] = rec
		end
		rec.hl.Adornee = inst
		rec.hl.FillColor = colour
		rec.hl.OutlineColor = colour
		rec.hl.Enabled = true
		rec.bb.Adornee = inst
		rec.bb.Enabled = true
		rec.txt.TextColor3 = colour
		rec.txt.Text = exitLocated and "EXIT" or "EXIT ?"
	end
end

-- fullbright (local lighting only) -----------------------------------------
-- Put the sun up and lift the lighting so a graded-dark round is plainly lit.
-- We change only client-side Lighting; GlobalShadows is left alone.
local fbSaved = nil
local fbEffectSaved = nil

local function applyFullbright()
	if STATE.fullbright then
		if not fbSaved then
			fbSaved = {
				Ambient = Lighting.Ambient,
				OutdoorAmbient = Lighting.OutdoorAmbient,
				Brightness = Lighting.Brightness,
				ClockTime = Lighting.ClockTime,
				ExposureCompensation = Lighting.ExposureCompensation,
			}
		end
		Lighting.ClockTime = 14
		Lighting.Brightness = 3
		Lighting.Ambient = Color3.fromRGB(255, 255, 255)
		Lighting.OutdoorAmbient = Color3.fromRGB(255, 255, 255)
		if Lighting.ExposureCompensation < 0.4 then
			Lighting.ExposureCompensation = 0.4
		end
		-- clear the round's desaturation + haze so bright stays bright
		fbEffectSaved = fbEffectSaved or {}
		for _, c in ipairs(Lighting:GetChildren()) do
			if c:IsA("ColorCorrectionEffect") then
				if not fbEffectSaved[c] then
					fbEffectSaved[c] = { Saturation = c.Saturation, Contrast = c.Contrast, Brightness = c.Brightness, TintColor = c.TintColor }
				end
				c.Saturation = 1
				c.Contrast = 0
				c.Brightness = 0.05
				c.TintColor = Color3.fromRGB(255, 255, 255)
			elseif c:IsA("Atmosphere") then
				if not fbEffectSaved[c] then
					fbEffectSaved[c] = { Density = c.Density, Haze = c.Haze, Glare = c.Glare }
				end
				c.Density = 0
				c.Haze = 0
				c.Glare = 0
			end
		end
	elseif fbSaved then
		for k, v in pairs(fbSaved) do
			pcall(function()
				Lighting[k] = v
			end)
		end
		fbSaved = nil
		if fbEffectSaved then
			for inst, props in pairs(fbEffectSaved) do
				if inst.Parent then
					for k, v in pairs(props) do
						pcall(function()
							inst[k] = v
						end)
					end
				end
			end
			fbEffectSaved = nil
		end
	end
end

-- no fog (independent of fullbright) ---------------------------------------
local fogSaved = nil

local function applyNoFog()
	if STATE.noFog then
		local atm = Lighting:FindFirstChildOfClass("Atmosphere")
		if not fogSaved then
			fogSaved = {
				FogEnd = Lighting.FogEnd,
				FogStart = Lighting.FogStart,
				FogColor = Lighting.FogColor,
				atm = atm,
				atmDensity = atm and atm.Density or nil,
			}
		end
		Lighting.FogEnd = 100000
		Lighting.FogStart = 100000
		local a = fogSaved.atm
		if a and a.Parent then
			pcall(function()
				a.Density = 0
			end)
		end
	elseif fogSaved then
		pcall(function()
			Lighting.FogEnd = fogSaved.FogEnd
			Lighting.FogStart = fogSaved.FogStart
			Lighting.FogColor = fogSaved.FogColor
		end)
		local a = fogSaved.atm
		if a and a.Parent and fogSaved.atmDensity then
			pcall(function()
				a.Density = fogSaved.atmDensity
			end)
		end
		fogSaved = nil
	end
end

-- noclip (local collision only) --------------------------------------------
local noclipParts = {}

local function restoreNoclip()
	for p in pairs(noclipParts) do
		if p.Parent then
			pcall(function()
				p.CanCollide = true
			end)
		end
	end
	noclipParts = {}
end

local function applyNoclip()
	local char = LP.Character
	if not char then
		noclipParts = {}
		return
	end
	if not STATE.noclip then
		if next(noclipParts) then
			restoreNoclip()
		end
		return
	end
	-- prune parts from a previous life, then disable collision on this one
	for p in pairs(noclipParts) do
		if not p.Parent then
			noclipParts[p] = nil
		end
	end
	for _, p in ipairs(char:GetDescendants()) do
		if p:IsA("BasePart") and p.CanCollide and not noclipParts[p] then
			noclipParts[p] = true
			pcall(function()
				p.CanCollide = false
			end)
		end
	end
end

-- field of view ------------------------------------------------------------
local function applyFov()
	local cam = Workspace.CurrentCamera
	if cam and math.abs(cam.FieldOfView - STATE.cameraFov) > 0.1 then
		pcall(function()
			cam.FieldOfView = STATE.cameraFov
		end)
	end
end

-- anti-AFK -----------------------------------------------------------------
local antiAfkConn = nil

local function ensureAntiAfk()
	if antiAfkConn or type(LP.Idled) ~= "RBXScriptSignal" then
		return
	end
	antiAfkConn = LP.Idled:Connect(function()
		if not STATE.antiAfk then
			return
		end
		pcall(function()
			VirtualUser:CaptureController()
			VirtualUser:ClickButton2(Vector2.new(0, 0))
		end)
	end)
end

-- infinite stamina ----------------------------------------------------------
-- The LOCAL player's Aspects live on LocalPlayer.Character, not on the round
-- rig under workspace.Map (those rigs are the OTHER players, named by display
-- name).  Stamina is a NumberValue with Max / DrainAmount / DrainSpeed /
-- RegenAmount / Delay children.  The game's own Control script stops a sprint
-- only when Stamina.Value <= 0, so we (a) zero the drain tuning once and (b)
-- re-pin the value to Max the instant the game lowers it, via a change signal
-- AND the 0.4s status poll so a mapped round can never run the bar down.
-- This is client-side; the server keeps its own copy, so treat it as cosmetic.
local applyStamina
do
	local staminaBound = nil
	local staminaConn = nil
	local staminaRestore = nil

	local function currentStamina()
		local char = LP.Character
		local aspects = char and char:FindFirstChild("Aspects")
		if not aspects then
			local map = Workspace:FindFirstChild("Map")
			local rig = map and (map:FindFirstChild(LP.Name) or map:FindFirstChild(LP.DisplayName))
			aspects = rig and rig:FindFirstChild("Aspects")
		end
		return aspects and aspects:FindFirstChild("Stamina") or nil
	end

	-- pin the bar at Max and keep the sprint gate open
	local function pin(st)
		local m = st:FindFirstChild("Max")
		local cap = (m and m:IsA("ValueBase")) and m.Value or st.Value
		if st.Value ~= cap then
			pcall(function()
				st.Value = cap
			end)
		end
		local aspects = st.Parent
		local cs = aspects and aspects:FindFirstChild("CanSprint")
		if cs and cs:IsA("BoolValue") and not cs.Value then
			pcall(function()
				cs.Value = true
			end)
		end
	end

	-- put the tuning back the way the game had it
	local function restore(st)
		if not staminaRestore then
			return
		end
		for n, val in pairs(staminaRestore) do
			local v = st:FindFirstChild(n)
			if v and v:IsA("ValueBase") then
				pcall(function()
					v.Value = val
				end)
			end
		end
		staminaRestore = nil
	end

	applyStamina = function()
		local st = currentStamina()
		if st ~= staminaBound then
			if staminaConn then
				pcall(function()
					staminaConn:Disconnect()
				end)
				staminaConn = nil
			end
			if staminaBound and staminaBound.Parent then
				restore(staminaBound)
			end
			staminaRestore = nil
			staminaBound = st
		end
		if not st then
			return
		end
		if STATE.infiniteStamina then
			if not staminaRestore then
				staminaRestore = {}
				for _, n in ipairs({ "DrainAmount", "DrainSpeed" }) do
					local v = st:FindFirstChild(n)
					if v and v:IsA("ValueBase") then
						staminaRestore[n] = v.Value
						pcall(function()
							v.Value = 0
						end)
					end
				end
			end
			pin(st)
			if not staminaConn then
				staminaConn = st:GetPropertyChangedSignal("Value"):Connect(function()
					if STATE.infiniteStamina and st.Parent then
						pin(st)
					end
				end)
			end
		else
			restore(st)
			if staminaConn then
				pcall(function()
					staminaConn:Disconnect()
				end)
				staminaConn = nil
			end
		end
	end
end

-- speed booster --------------------------------------------------------------
-- The game derives movement from the character's own Aspects: walking writes
-- Humanoid.WalkSpeed = Aspects.WalkSpeed.Value and sprinting writes
-- Humanoid.WalkSpeed = Aspects.SprintSpeed.Value * SpeedValue.  So scaling the
-- two Aspects values scales both gaits THROUGH the game's own code, with no
-- per-frame movement loop fighting it.  The base is captured once per character
-- and put straight back the moment the slider returns to 1.0x.
local applySpeed
do
	local speedBound = nil
	local speedBase = nil

	local function restore(asp, base)
		for n, v in pairs(base) do
			local o = asp:FindFirstChild(n)
			if o and o:IsA("ValueBase") and v then
				pcall(function()
					o.Value = v
				end)
			end
		end
	end

	applySpeed = function()
		local char = LP.Character
		local asp = char and char:FindFirstChild("Aspects")
		local mult = math.clamp(tonumber(STATE.speedMult) or 1, 1, 10)

		-- character switched (respawn / role change): drop the old base
		if asp ~= speedBound then
			if speedBound and speedBound.Parent and speedBase then
				restore(speedBound, speedBase)
			end
			speedBound = asp
			speedBase = nil
		end
		if not asp then
			return
		end

		-- 1.0x = fully off: restore the game's own numbers, then leave it alone
		if mult <= 1 then
			if speedBase then
				restore(asp, speedBase)
				speedBase = nil
				local hum = asp.Parent and asp.Parent:FindFirstChildOfClass("Humanoid")
				local w = asp:FindFirstChild("WalkSpeed")
				if hum and w then
					pcall(function()
						hum.WalkSpeed = w.Value
					end)
				end
			end
			return
		end

		local walk = asp:FindFirstChild("WalkSpeed")
		local sprint = asp:FindFirstChild("SprintSpeed")
		if not speedBase then
			speedBase = {
				WalkSpeed = walk and walk.Value or nil,
				SprintSpeed = sprint and sprint.Value or nil,
			}
		end
		local tw = speedBase.WalkSpeed and speedBase.WalkSpeed * mult or nil
		local ts = speedBase.SprintSpeed and speedBase.SprintSpeed * mult or nil
		if walk and tw and math.abs(walk.Value - tw) > 0.001 then
			pcall(function()
				walk.Value = tw
			end)
		end
		if sprint and ts and math.abs(sprint.Value - ts) > 0.001 then
			pcall(function()
				sprint.Value = ts
			end)
		end
		-- make walking feel instant; still leave an active sprint to the game.
		-- The game only rewrites Humanoid.WalkSpeed on its own events, and its
		-- sprint loop refuses to run unless Aspects.WalkSpeed.Value <=
		-- Humanoid.WalkSpeed.  So if a previous multiplier left the humanoid
		-- below the walk target the character can no longer sprint at all
		-- (sprint dies the moment the slider passes ~1.2x).  Nudge it up
		-- whenever it sits below the target, never down, so an active sprint -
		-- which runs far above the walk target - is left entirely to the game.
		local hum = asp.Parent and asp.Parent:FindFirstChildOfClass("Humanoid")
		if hum and tw and hum.WalkSpeed < tw - 0.05 then
			pcall(function()
				hum.WalkSpeed = tw
			end)
		end
	end
end

-- sprint assist ---------------------------------------------------------------
-- The game's own sprint watcher stops engaging once the booster has walked the
-- humanoid up to the scaled walk speed: it only applies its sprint line while
-- Aspects.WalkSpeed.Value <= Humanoid.WalkSpeed, so a fresh Shift press above
-- roughly 1.2x is refused outright (holding Shift from before 1.2x keeps
-- working, which is why the bug reads as "sprint dies at 1.3x").  While the
-- booster is on we reproduce the game's own line exactly -
-- Humanoid.WalkSpeed = SprintSpeed * SpeedValue - for as long as Shift is
-- held, then hand movement straight back to the game's walk speed on release.
-- At 1.0x this does nothing at all, so vanilla movement is untouched.
local sprintAssist = false

local function stepSprintAssist()
	local char = LP.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local asp = char and char:FindFirstChild("Aspects")
	local boosted = (tonumber(STATE.speedMult) or 1) > 1

	if not (boosted and hum and asp) then
		if sprintAssist and hum and asp then
			sprintAssist = false
			local w = asp:FindFirstChild("WalkSpeed")
			if w and hum.WalkSpeed > 0 then
				pcall(function()
					hum.WalkSpeed = w.Value
				end)
			end
		end
		return
	end

	-- Keep the game's sprint gate open.  Its own sprint loop only applies
	-- Humanoid.WalkSpeed = SprintSpeed * SpeedValue while
	-- Aspects.WalkSpeed.Value <= Humanoid.WalkSpeed.  Scaling the walk aspect up
	-- while the humanoid still sat at the old, lower speed made every fresh
	-- Shift press fail outright - the "can't sprint above ~1.2x" bug.  Running
	-- on the fast tick means the gate is already open when Shift goes down.
	local wa = asp:FindFirstChild("WalkSpeed")
	local knocked = char:FindFirstChild("Knockback") ~= nil
	if wa and hum.WalkSpeed > 1 and not knocked and hum.WalkSpeed < wa.Value - 0.05 then
		pcall(function()
			hum.WalkSpeed = wa.Value
		end)
	end

	local sprint = asp:FindFirstChild("SprintSpeed")
	if not sprint then
		return
	end
	local held = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
	if not held then
		if sprintAssist then
			sprintAssist = false
			local w = asp:FindFirstChild("WalkSpeed")
			if w and hum.WalkSpeed > 0 then
				pcall(function()
					hum.WalkSpeed = w.Value
				end)
			end
		end
		return
	end
	local can = asp:FindFirstChild("CanSprint")
	local stam = asp:FindFirstChild("Stamina")
	local sv = char:GetAttribute("SpeedValue") or 1
	local target = sprint.Value * sv
	-- mirror the game's own bail-outs: never touch a ragdolled, grabbed or
	-- knocked-back character, and never sprint on an empty tank.
	local ok = hum.WalkSpeed > 1
		and (can == nil or can.Value)
		and (stam == nil or stam.Value > 0)
		and not knocked
	if ok and hum.WalkSpeed < target - 0.05 then
		pcall(function()
			hum.WalkSpeed = target
		end)
		sprintAssist = true
	end
end

-- survivor hitbox scale (monster tool) --------------------------------------
-- Survivors carry a PlrHitbox part used for monster hit detection.  While the
-- local player is the Monster this scales those parts so they are easier to
-- hit; at 1.0x (or when not the monster) every size is restored exactly.
local hitboxSaved = {}
local applyHitbox

applyHitbox = function()
	local char = LP.Character
	local active = (tonumber(STATE.hitboxMult) or 1) > 1 and char and roleOf(char, LP) == "Monster"
	local mult = math.clamp(tonumber(STATE.hitboxMult) or 1, 1, 10)
	for part, base in pairs(hitboxSaved) do
		if not active or not part.Parent then
			if part.Parent then
				pcall(function()
					part.Size = base
				end)
			end
			hitboxSaved[part] = nil
		end
	end
	if not active then
		return
	end
	for _, plr in ipairs(Players:GetPlayers()) do
		if plr ~= LP then
			local c = plr.Character
			if c then
				local r = roleOf(c, plr)
				if r == "Survivor" or r == "Sentinel" then
					local part = c:FindFirstChild("PlrHitbox")
					if part and part:IsA("BasePart") then
						local base = hitboxSaved[part]
						if not base then
							base = part.Size
							hitboxSaved[part] = base
						end
						local want = Vector3.new(base.X * mult, base.Y * mult, base.Z * mult)
						if (part.Size - want).Magnitude > 0.001 then
							pcall(function()
								part.Size = want
							end)
						end
					end
				end
			end
		end
	end
end

-- fps / ping ---------------------------------------------------------------
local frameCount = 0
local fps = 0
local fpsClock = os.clock()
local pingMs = nil

local function tickFps()
	frameCount = frameCount + 1
	local now = os.clock()
	if now - fpsClock >= 1 then
		fps = frameCount / (now - fpsClock)
		frameCount = 0
		fpsClock = now
		local ok, v = pcall(function()
			return Stats.Network.ServerStatsItem["Data Ping"]:GetValue()
		end)
		pingMs = ok and v or nil
	end
end

-- panic hide ---------------------------------------------------------------
local panicked = false

local function setPanic(hidden)
	panicked = hidden
	overlay.Enabled = not hidden
	if hidden then
		-- instant hide (no animation) so H is reliable for a screenshot
		Main.Visible = false
		gui.Enabled = false
	else
		showWindow()
		selectTab(1)
	end
end

-- ==========================================================================
-- overlay engine (runs per frame for smooth arrows / tracers)
-- ==========================================================================

local function fxFor(model)
	local f = fx[model]
	if not f then
		local tracer = new("Frame", {
			Name = "Tracer",
			AnchorPoint = Vector2.new(0, 0.5),
			BackgroundColor3 = Color3.fromRGB(255, 255, 255),
			BorderSizePixel = 0,
			Visible = false,
			ZIndex = 2,
		}, tracerHolder)
		local arrow = new("TextLabel", {
			Name = "Arrow",
			Size = UDim2.fromOffset(26, 26),
			AnchorPoint = Vector2.new(0.5, 0.5),
			BackgroundTransparency = 1,
			Font = THEME.fontBold,
			Text = "▲",
			TextSize = 26,
			TextColor3 = Color3.fromRGB(255, 255, 255),
			Visible = false,
			ZIndex = 3,
		}, arrowHolder)
		f = { tracer = tracer, arrow = arrow }
		fx[model] = f
	end
	return f
end

local pulse = 0

local function stepOverlay(dt)
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end
	local vp = cam.ViewportSize
	local cx, cy = vp.X * 0.5, vp.Y * 0.5
	local alive = {}

	for _, t in ipairs(targets) do
		alive[t.model] = true
		local f = fxFor(t.model)
		local sp, onScreen = cam:WorldToViewportPoint(t.pos)
		local on = onScreen and sp.Z > 0

		if STATE.tracers and on and not t.isSelf then
			local dx, dy = sp.X - cx, vp.Y - sp.Y
			local len = math.sqrt(dx * dx + dy * dy)
			local ang = math.deg(math.atan2(dy, dx))
			f.tracer.Position = UDim2.fromOffset(cx, vp.Y)
			f.tracer.Size = UDim2.fromOffset(len, 2)
			f.tracer.Rotation = ang
			f.tracer.BackgroundColor3 = t.colour
			f.tracer.BackgroundTransparency = t.dead and 0.7 or 0.25
			f.tracer.Visible = true
		else
			f.tracer.Visible = false
		end

		if STATE.offscreen and not on and not t.isSelf then
			local dirX = sp.X - cx
			local dirY = sp.Y - cy
			if math.abs(dirX) < 0.01 and math.abs(dirY) < 0.01 then
				dirX = 1
			end
			local margin = 40
			local scale = math.min(
				(vp.X * 0.5 - margin) / math.max(1e-3, math.abs(dirX)),
				(vp.Y * 0.5 - margin) / math.max(1e-3, math.abs(dirY))
			)
			local ax = cx + dirX * scale
			local ay = cy + dirY * scale
			f.arrow.Position = UDim2.fromOffset(ax, ay)
			f.arrow.Rotation = math.deg(math.atan2(dirY, dirX)) + 90
			f.arrow.TextColor3 = t.colour
			f.arrow.TextTransparency = t.dead and 0.7 or 0
			f.arrow.Visible = true
		else
			f.arrow.Visible = false
		end
	end

	for model, f in pairs(fx) do
		if not alive[model] then
			f.tracer:Destroy()
			f.arrow:Destroy()
			fx[model] = nil
		end
	end

	-- HUD (horizontal right-side strip)
	if STATE.hud then
		hud.Visible = true
		hud.Active = gui.Enabled
		if not ROUND.inRound then
			hudDot.BackgroundColor3 = THEME.off
			hudRole.Text = ROUND.map and ROUND.map or "Not in game."
			hudRole.TextColor3 = THEME.dim
			hudLine1.Text = string.upper(ROUND.status or "Idle")
			hudLine1.TextColor3 = THEME.dim
			hudLine2.Text = ""
		else
			local myRole = (LP.Character and LP.Character:GetAttribute("Type")) or "-"
			local rc = STATE.colors and STATE.colors[myRole]
			local col = rc and rgb(rc) or THEME.text
			hudDot.BackgroundColor3 = col
			hudRole.Text = HUD_ROLE[myRole] or tostring(myRole)
			hudRole.TextColor3 = col
			hudLine1.Text = string.format("Survivor %d  ·  Sentinel %d", counts.Survivor, counts.Sentinel)
			hudLine1.TextColor3 = THEME.dim
			if counts.Monster > 0 and monsterDist then
				hudLine2.Text = string.format("%d m", math.floor(monsterDist + 0.5))
				hudLine2.TextColor3 = monsterDist <= STATE.alertDist and THEME.danger or THEME.dim
			else
				hudLine2.Text = "no monster"
				hudLine2.TextColor3 = THEME.dim
			end
		end
	else
		hud.Visible = false
	end

	-- monster alert
	local alerting = STATE.monsterAlert and monsterDist ~= nil and monsterDist <= STATE.alertDist
	if alerting then
		pulse += dt or 0.016
		local a = (math.sin(pulse * 6) + 1) * 0.5
		alert.Visible = true
		alert.Text = string.format("MONSTER NEARBY  ·  %dm", math.floor(monsterDist + 0.5))
		edge.Visible = true
		edgeStroke.Transparency = 0.35 + a * 0.5
		edgeStroke.Thickness = 5 + a * 5
	else
		alert.Visible = false
		edge.Visible = false
		edgeStroke.Transparency = 1
	end

	-- crosshair
	if STATE.crosshair then
		crosshair.Visible = true
		crosshair.BackgroundColor3 = rgb(STATE.crosshairColor)
	else
		crosshair.Visible = false
	end

	-- fps / ping
	if STATE.fpsCounter or STATE.pingCounter then
		local parts = {}
		if STATE.fpsCounter then
			parts[#parts + 1] = string.format("%d fps", math.floor(fps + 0.5))
		end
		if STATE.pingCounter then
			parts[#parts + 1] = pingMs and string.format("%d ms", math.floor(pingMs + 0.5)) or "-- ms"
		end
		statsLbl.Text = table.concat(parts, "   ")
		statsLbl.Visible = true
	else
		statsLbl.Visible = false
	end
end

-- ==========================================================================
-- window chrome
-- ==========================================================================

local function makeDraggable(frame, handle)
	local dragging, dragStart, startPos
	handle.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			dragStart = input.Position
			startPos = frame.Position
		end
	end)
	handle.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			local delta = input.Position - dragStart
			frame.Position = UDim2.new(
				startPos.X.Scale,
				startPos.X.Offset + delta.X,
				startPos.Y.Scale,
				startPos.Y.Offset + delta.Y
			)
		end
	end)
end
makeDraggable(win, topbar)

-- HUD drag: only while the menu is open, clamped to the screen, position saved
-- into the config so it comes back where you left it.
local hudDragging, hudDragStart, hudStartPos = false, nil, nil
local function hudSave()
	STATE.hudPos = { hud.Position.X.Offset, hud.Position.Y.Offset }
	saveConfig()
end
hud.InputBegan:Connect(function(input)
	if not gui.Enabled then
		return
	end
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		hudDragging = true
		hudDragStart = input.Position
		-- normalise to a plain top-left offset so clamping is simple
		local ap = hud.AbsolutePosition
		hud.AnchorPoint = Vector2.new(0, 0)
		hud.Position = UDim2.fromOffset(ap.X, ap.Y)
		hudStartPos = hud.Position
	end
end)
UserInputService.InputChanged:Connect(function(input)
	if not hudDragging then
		return
	end
	if input.UserInputType ~= Enum.UserInputType.MouseMovement and input.UserInputType ~= Enum.UserInputType.Touch then
		return
	end
	local delta = input.Position - hudDragStart
	local screen = overlay.AbsoluteSize
	local maxX = math.max(0, screen.X - hud.AbsoluteSize.X)
	local maxY = math.max(0, screen.Y - hud.AbsoluteSize.Y)
	local x = math.clamp(hudStartPos.X.Offset + delta.X, 0, maxX)
	local y = math.clamp(hudStartPos.Y.Offset + delta.Y, 0, maxY)
	hud.Position = UDim2.fromOffset(x, y)
end)
UserInputService.InputEnded:Connect(function(input)
	if hudDragging and (input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch) then
		hudDragging = false
		hudSave()
	end
end)

-- the keybind (default K) toggles the whole window. `panicked` (H) always
-- wins: if we are hidden by panic, the toggle brings everything back first.
local function toggleWindow()
	if panicked then
		setPanic(false)
		return
	end
	if gui.Enabled then
		hideWindow()
	else
		showWindow()
	end
end

-- ==========================================================================
-- loops
-- ==========================================================================

ensureAntiAfk()

local function highlightLoop()
	while running do
		local ok = pcall(stepHighlights)
		pcall(function()
			if not ROUND.inRound then
				infoRole.Text = "Status: " .. (ROUND.status or "Not in game.")
				infoMonster.Text = ROUND.map and ("Map: " .. ROUND.map) or "Map: -"
				infoSurvivors.Text = "Survivors: -"
				infoTracked.Text = "Highlighted: -"
				return
			end
			local lr = LP.Character and LP.Character:GetAttribute("Type")
			infoRole.Text = "Your role: " .. tostring(lr or "-")
			infoMonster.Text = "Monster: "
				.. (counts.Monster > 0 and (monsterDist and string.format("%dm", math.floor(monsterDist + 0.5)) or "present") or "none")
			infoSurvivors.Text = "Survivors: " .. tostring(counts.Survivor)
			infoTracked.Text = "Highlighted: " .. tostring(trackedCount)
		end)
		task.wait(ok and 0.12 or 0.4)
	end
end
task.spawn(highlightLoop)
task.spawn(taskLoop)

RunService.RenderStepped:Connect(function(dt)
	if running then
		pcall(tickFps)
		pcall(applyFov)
		pcall(applyNoclip)
		pcall(applySpeed)
		pcall(stepOverlay, dt)
	end
end)

-- free the cursor only while the hub window is open -------------------------
-- The game's shiftlock does NOT just set UserInputService.MouseBehavior: it
-- goes through PlayerModule.CameraModule.CameraUtils, which remembers the
-- value it displaced and puts it back later.  Writing MouseBehavior directly
-- (as this used to) beat the game's own bookkeeping out of step, which is what
-- left shiftlock "disturbed" after closing the hub.
--
-- So we push our unlock through that SAME utility instead of around it:
--   open  -> CameraUtils.setMouseBehaviorOverride(Default)
--   close -> CameraUtils.restoreMouseBehavior()  (pops our override, then we
--            settle on exactly the value the game had when we opened).
-- Shiftlock's own state therefore stays consistent and keeps working.
local cameraUtils
do
	local ok, mod = pcall(function()
		local pm = LP.PlayerScripts:FindFirstChild("PlayerModule")
		local cm = pm and pm:FindFirstChild("CameraModule")
		local cu = cm and cm:FindFirstChild("CameraUtils")
		return cu and require(cu)
	end)
	if ok and type(mod) == "table" and type(mod.setMouseBehaviorOverride) == "function" then
		cameraUtils = mod
	end
end

local mouseHeld = false
local savedMouseBehavior = nil
local savedMouseIcon = nil
local mouseGuard = nil
local iconGuard = nil

-- ask for a free cursor through the game's own camera utility when we can, so
-- its override bookkeeping stays correct; fall back to a plain write if the
-- module is not there (lobby / not loaded yet).
local function wantFreeCursor()
	if cameraUtils then
		local ok = pcall(cameraUtils.setMouseBehaviorOverride, Enum.MouseBehavior.Default)
		if ok then
			return
		end
	end
	pcall(function()
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	end)
end

local function holdMouse()
	if mouseHeld then
		return
	end
	mouseHeld = true
	savedMouseBehavior = UserInputService.MouseBehavior
	savedMouseIcon = UserInputService.MouseIconEnabled
	wantFreeCursor()
	pcall(function()
		UserInputService.MouseIconEnabled = true
	end)
	if mouseGuard then
		mouseGuard:Disconnect()
	end
	mouseGuard = UserInputService:GetPropertyChangedSignal("MouseBehavior"):Connect(function()
		if mouseHeld and UserInputService.MouseBehavior ~= Enum.MouseBehavior.Default then
			wantFreeCursor()
		end
	end)
	if iconGuard then
		iconGuard:Disconnect()
	end
	iconGuard = UserInputService:GetPropertyChangedSignal("MouseIconEnabled"):Connect(function()
		if mouseHeld and not UserInputService.MouseIconEnabled then
			pcall(function()
				UserInputService.MouseIconEnabled = true
			end)
		end
	end)
end

local function giveMouseBack()
	if not mouseHeld then
		return
	end
	mouseHeld = false
	if mouseGuard then
		mouseGuard:Disconnect()
		mouseGuard = nil
	end
	if iconGuard then
		iconGuard:Disconnect()
		iconGuard = nil
	end
	-- pop our override the game's way first (keeps its state consistent)...
	if cameraUtils then
		pcall(cameraUtils.restoreMouseBehavior)
	end
	-- ...then make sure we end on exactly the behaviour the game had before.
	if savedMouseBehavior ~= nil and UserInputService.MouseBehavior ~= savedMouseBehavior then
		pcall(function()
			UserInputService.MouseBehavior = savedMouseBehavior
		end)
	end
	if savedMouseIcon ~= nil then
		pcall(function()
			UserInputService.MouseIconEnabled = savedMouseIcon
		end)
	end
	savedMouseBehavior = nil
	savedMouseIcon = nil
end

local function stepMouse()
	local want = gui.Enabled and STATE.freeMouse and not panicked
	if want then
		holdMouse()
		if UserInputService.MouseBehavior ~= Enum.MouseBehavior.Default then
			wantFreeCursor()
		end
		if not UserInputService.MouseIconEnabled then
			UserInputService.MouseIconEnabled = true
		end
	else
		giveMouseBack()
	end
end

RunService.RenderStepped:Connect(stepMouse)

-- shift lock ----------------------------------------------------------------
-- Plain client-side shift lock: lock the cursor to the screen centre and pull
-- the camera over the shoulder.  Only active while the hub window is closed, so
-- it never fights the free cursor.
local shiftSaved = nil

local function stepShiftlock()
	local want = STATE.shiftlock and not (gui.Enabled and not panicked)
	local char = LP.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not want or not hum then
		if shiftSaved then
			if shiftSaved.behavior ~= nil and UserInputService.MouseBehavior ~= shiftSaved.behavior then
				pcall(function()
					UserInputService.MouseBehavior = shiftSaved.behavior
				end)
			end
			if hum and shiftSaved.offset then
				pcall(function()
					hum.CameraOffset = shiftSaved.offset
				end)
			end
			shiftSaved = nil
		end
		return
	end
	if not shiftSaved then
		shiftSaved = { behavior = UserInputService.MouseBehavior, offset = hum.CameraOffset }
	end
	if UserInputService.MouseBehavior ~= Enum.MouseBehavior.LockCenter then
		pcall(function()
			UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
		end)
	end
	local over = Vector3.new(1.75, 0, 0)
	if hum.CameraOffset ~= over then
		pcall(function()
			hum.CameraOffset = over
		end)
	end
end

RunService.RenderStepped:Connect(stepShiftlock)

-- free camera (unstick) -----------------------------------------------------
-- A one-shot fix for when the game has scripted/locked the camera and you can no
-- longer swing it.  Hands camera control back to the normal player camera.
function freeCamera()
	local cam = Workspace.CurrentCamera
	local char = LP.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if cam then
		pcall(function()
			cam.CameraType = Enum.CameraType.Custom
		end)
		if hum then
			pcall(function()
				cam.CameraSubject = hum
			end)
		end
	end
	if cameraUtils and cameraUtils.restoreMouseBehavior then
		pcall(cameraUtils.restoreMouseBehavior)
	end
	if not STATE.shiftlock then
		pcall(giveMouseBack)
	end
	if toast then
		toast("Camera re-freed.", THEME.on)
	end
	return true
end

-- void rescue
-- Noclip (or an occasional server fling) can leave the character falling
-- forever below the map with no floor to catch it.  On each status tick, if we
-- are far below any sane floor, put us back on a spawn point.
local function voidRescue()
	if not STATE.voidRescue then
		return
	end
	local char = LP.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not (hrp and hrp:IsA("BasePart")) then
		return
	end
	if hrp.Position.Y > -300 then
		return
	end
	local map = mapNow()
	local sp = map and map:FindFirstChild("Spawns")
	local bestY, target
	if sp then
		for _, d in ipairs(sp:GetDescendants()) do
			if d:IsA("BasePart") then
				local y = d.Position.Y
				if not bestY or y > bestY then
					bestY = y
					target = d.Position
				end
			end
		end
	end
	if not target then
		local sl = Workspace:FindFirstChildWhichIsA("SpawnLocation", true)
		if sl then
			target = sl.Position
		end
	end
	if target then
		pcall(function()
			char:PivotTo(CFrame.new(target + Vector3.new(0, 3, 0)))
		end)
	end
end

-- vapor skin spoof (client-only cosmetic) ----------------------------------
-- The lobby reads these Inventory values to decide what is owned/equipped.
-- We cannot change the real (server-owned) profile, so this only edits the
-- local replica: the lobby shows every tier as owned and tier IV as equipped,
-- while the in-round monster stays whatever the server spawned. A snapshot of
-- the original values is kept so turning the toggle off restores them.
local skinSpoofSnapshot = nil
local function applySkinSpoof()
	local inv = LP:FindFirstChild("Inventory")
	local monsters = inv and inv:FindFirstChild("Monsters")
	local vap = monsters and monsters:FindFirstChild("Vapor")
	if not (inv and vap) then
		return
	end

	if STATE.skinSpoof then
		if not skinSpoofSnapshot then
			local snap = { tiers = {}, skin = nil, monsterSkin = nil }
			for _, n in ipairs({ "Vapor-I", "Vapor-II", "Vapor-III", "Vapor-IV" }) do
				local b = vap:FindFirstChild(n)
				if b and b:IsA("BoolValue") then
					snap.tiers[n] = b.Value
				end
			end
			local sk = vap:FindFirstChild("Vapor-Skin")
			if sk and sk:IsA("StringValue") then
				snap.skin = sk.Value
			end
			local ms = inv:FindFirstChild("MonsterSkin")
			if ms and ms:IsA("StringValue") then
				snap.monsterSkin = ms.Value
			end
			skinSpoofSnapshot = snap
		end
		for _, n in ipairs({ "Vapor-I", "Vapor-II", "Vapor-III", "Vapor-IV" }) do
			local b = vap:FindFirstChild(n)
			if b and b:IsA("BoolValue") and b.Value ~= true then
				b.Value = true
			end
		end
		local sk = vap:FindFirstChild("Vapor-Skin")
		if sk and sk:IsA("StringValue") and sk.Value ~= "Vapor-IV" then
			sk.Value = "Vapor-IV"
		end
		local ms = inv:FindFirstChild("MonsterSkin")
		if ms and ms:IsA("StringValue") and ms.Value:match("^Vapor") and ms.Value ~= "Vapor-IV" then
			ms.Value = "Vapor-IV"
		end
	elseif skinSpoofSnapshot then
		local snap = skinSpoofSnapshot
		for n, v in pairs(snap.tiers) do
			local b = vap:FindFirstChild(n)
			if b and b:IsA("BoolValue") then
				pcall(function()
					b.Value = v
				end)
			end
		end
		local sk = vap:FindFirstChild("Vapor-Skin")
		if sk and snap.skin then
			pcall(function()
				sk.Value = snap.skin
			end)
		end
		local ms = inv:FindFirstChild("MonsterSkin")
		if ms and snap.monsterSkin then
			pcall(function()
				ms.Value = snap.monsterSkin
			end)
		end
		skinSpoofSnapshot = nil
	end
end

local function statusLoop()
	while running do
		pcall(applyFullbright)
		pcall(applyNoFog)
		pcall(applyStamina)
		pcall(applySpeed)
		pcall(applyHitbox)
		pcall(voidRescue)
		pcall(applySkinSpoof)
		pcall(function()
			for _, fn in ipairs(colorSyncers) do
				fn()
			end
		end)
		pcall(function()
			statusDot.Text = STATE.enabled and "ON" or "OFF"
			statusDot.TextColor3 = STATE.enabled and THEME.on or THEME.off
			infoMouse.Text = "Mouse: " .. tostring(UserInputService.MouseBehavior):gsub("Enum.MouseBehavior.", "")
		end)
		task.wait(0.4)
	end
end
task.spawn(statusLoop)

-- keybinds
local TAB_KEYS = {
	[Enum.KeyCode.One] = 1,
	[Enum.KeyCode.Two] = 2,
	[Enum.KeyCode.Three] = 3,
	[Enum.KeyCode.Four] = 4,
	[Enum.KeyCode.Five] = 5,
	[Enum.KeyCode.Six] = 6,
	[Enum.KeyCode.Seven] = 7,
}

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed or keybindCapturing then
		return
	end
	if input.UserInputType ~= Enum.UserInputType.Keyboard and input.UserInputType ~= Enum.UserInputType.Gamepad1 then
		return
	end
	local kb = STATE.keybind and Enum.KeyCode[STATE.keybind]
	if kb and input.KeyCode == kb then
		toggleWindow()
		return
	end
	if input.KeyCode == Enum.KeyCode.H then
		setPanic(not panicked)
		return
	end
	local tab = TAB_KEYS[input.KeyCode]
	if tab and gui.Enabled and not panicked then
		selectTab(tab)
	end
end)

-- ==========================================================================
-- session handle
-- ==========================================================================

local handle = {}
handle.gui = gui
handle.overlay = overlay
handle.cameraUtils = cameraUtils
handle.state = STATE
handle.setTab = selectTab
handle.toggleWindow = toggleWindow
handle.collectOneShard = collectOneShard
handle.autoTasks = function(on)
	STATE.autoCollect = on ~= false
	saveConfig()
	return STATE.autoCollect
end
handle.autoCollect = handle.autoTasks
handle.taskGroup = function(name)
	if name ~= nil then
		STATE.taskGroup = (name == "" or name == "All") and "All" or tostring(name)
		taskPickerDirty = true
		saveConfig()
	end
	return STATE.taskGroup
end
handle.taskGroups = function()
	local out = { "All" }
	for _, f in ipairs(objectiveFolders(mapNow())) do
		out[#out + 1] = f.Name
	end
	return out
end
handle.getCounts = function()
	return counts, trackedCount, monsterDist
end
handle.roundInfo = roundInfo
handle.uiPhase = uiPhase
handle.setPanic = setPanic
handle.closeNotice = function()
	local ok, err = pcall(closeNotice)
	return ok, tostring(err)
end
handle.closeNote = closeNote
-- internal engines, exposed for testing / scripting
handle.runShardEsp = stepShardEsp
handle.runHighlights = stepHighlights
handle.runExitEsp = stepExitEsp
handle.roleOf = roleOf
handle.teleportNearest = function()
	return TP and TP.goNearest and TP.goNearest()
end
handle.teleportExit = function()
	return TP and TP.goExit and TP.goExit()
end
handle.tp = TP
handle.mapNow = mapNow
handle.antiAfk = function(on)
	STATE.antiAfk = on ~= false
	saveConfig()
	ensureAntiAfk()
	return STATE.antiAfk
end
handle.noclip = function(on)
	STATE.noclip = on ~= false
	if not STATE.noclip then
		restoreNoclip()
	end
	saveConfig()
	return STATE.noclip
end
handle.noFog = function(on)
	STATE.noFog = on ~= false
	applyNoFog()
	saveConfig()
	return STATE.noFog
end
handle.infiniteStamina = function(on)
	STATE.infiniteStamina = on ~= false
	applyStamina()
	saveConfig()
	return STATE.infiniteStamina
end
handle.speed = function(mult)
	STATE.speedMult = math.floor(math.clamp(tonumber(mult) or 1, 1, 10) * 10 + 0.5) / 10
	applySpeed()
	saveConfig()
	return STATE.speedMult
end
handle.shiftlock = function(on)
	STATE.shiftlock = on ~= false
	saveConfig()
	return STATE.shiftlock
end
handle.freeCamera = freeCamera
handle.taskSafety = function(on)
	STATE.taskSafety = on ~= false
	saveConfig()
	return STATE.taskSafety
end
handle.taskSafetyDist = function(m)
	STATE.taskSafetyDist = math.clamp(tonumber(m) or 40, 20, 80)
	saveConfig()
	return STATE.taskSafetyDist
end
handle.instantPrompt = function(on)
	STATE.instantPrompt = on ~= false
	saveConfig()
	return STATE.instantPrompt
end
handle.voidRescue = function(on)
	if on ~= nil then
		STATE.voidRescue = on ~= false
		saveConfig()
	end
	return STATE.voidRescue
end
handle.hitbox = function(mult)
	STATE.hitboxMult = math.clamp(tonumber(mult) or 1, 1, 10)
	applyHitbox()
	saveConfig()
	return STATE.hitboxMult
end
handle.setFreeMouse = function(on)
	STATE.freeMouse = on ~= false
	if not STATE.freeMouse then
		giveMouseBack()
	end
	saveConfig()
	return STATE.freeMouse
end
handle.releaseMouse = giveMouseBack
handle.destroy = function()
	running = false
	pcall(giveMouseBack)
	if antiAfkConn then
		pcall(function()
			antiAfkConn:Disconnect()
		end)
		antiAfkConn = nil
	end
	pcall(function()
		if fbSaved then
			for k, v in pairs(fbSaved) do
				Lighting[k] = v
			end
		end
	end)
	pcall(restoreNoclip)
	pcall(function()
		STATE.infiniteStamina = false
		applyStamina()
	end)
	pcall(function()
		STATE.speedMult = 1
		applySpeed()
	end)
	pcall(function()
		STATE.shiftlock = false
	end)
	pcall(function()
		STATE.hitboxMult = 1
		applyHitbox()
	end)
	pcall(function()
		STATE.noFog = false
		applyNoFog()
	end)
	pcall(function()
		for _, rec in pairs(tracked) do
			if rec.hl then
				rec.hl:Destroy()
			end
			if rec.bb then
				rec.bb:Destroy()
			end
		end
	end)
	pcall(function()
		for _, f in pairs(fx) do
			f.tracer:Destroy()
			f.arrow:Destroy()
		end
	end)
	pcall(function()
		clearExit()
	end)
	pcall(function()
		espFolder:Destroy()
	end)
	pcall(function()
		shardFolder:Destroy()
	end)
	pcall(function()
		exitFolder:Destroy()
	end)
	pcall(function()
		gui:Destroy()
	end)
	pcall(function()
		overlay:Destroy()
	end)
	pcall(function()
		for _, c in ipairs(connections) do
			c:Disconnect()
		end
	end)
end
handle.cleanup = handle.destroy

genv.PillarChaseHub = handle

print("[PCHub] v2 loaded. Monster=red, Survivor=green, Sentinel=amber.")
print(string.format("[PCHub] %s = window, keys 1-7 = tabs, H = panic hide. Cursor frees while the window is open and is handed straight back on close. %d players seen.", tostring(STATE.keybind), #Players:GetPlayers()))
print("[PCHub] Extras: infinite stamina, speed booster, anti-AFK, fullbright, no fog, noclip, FOV zoom, exit ESP, crosshair, fps/ping, Vapor skin spoof.")
print("[PCHub] Tasks: round-aware. Objective ESP on all maps; 'Auto tasks' is ON by default. Lobby/dead = idle.")
