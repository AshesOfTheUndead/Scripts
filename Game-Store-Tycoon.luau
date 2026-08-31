local WindUI = loadstring(game:HttpGet("https://github.com/Footagesus/WindUI/releases/latest/download/main.lua"))()

local Players     = game:GetService("Players")
local RS          = game:GetService("ReplicatedStorage")
local WS          = game:GetService("Workspace")
local RunService  = game:GetService("RunService")
local UIS         = game:GetService("UserInputService")
local VU          = game:GetService("VirtualUser")
local TS          = game:GetService("TeleportService")

local LP          = Players.LocalPlayer
local Events      = WS:WaitForChild("Events")
local takegame    = RS:WaitForChild("Events"):WaitForChild("takegame")

pcall(function() WindUI:SetParent(game:GetService("CoreGui")) end)
pcall(function() WindUI:SetNotificationLower(true) end)

-- ================= MONEYCODE REPLICA =================

local band, bxor, lshift, rshift = bit32.band, bit32.bxor, bit32.lshift, bit32.rshift
local function mix(p1, p2, p3)
    local v1 = math.floor(tonumber(p1) or 0)
    local v2 = band(v1, 4294967295)
    local v3 = math.floor(tonumber(p2) or 0)
    v1 = band(v3, 4294967295)
    v3 = bxor(bxor(v2, p3), v1)
    v3 = band(bxor(v3, (lshift(v3, 13))), 4294967295)
    v3 = bxor(v3, (rshift(v3, 17)))
    return (band(bxor(v3, (lshift(v3, 5))), 4294967295))
end
local function moneyCode(p2)
    local v2 = math.floor(tonumber(p2) or 0)
    local v3 = math.abs(v2)
    local v1 = (100001 >= v3) and 1517243948 or 2668804013
    return string.format("%08x", (mix(LP.UserId, v2, v1)))
end

-- ================= STATE =================

local S = {
    autoRestock = false, restockDelay = 2,
    autoRegister = false,
    autoDelivery = false,
    autoRobber = false,
    autoMoney = false, moneyAmount = 10000, moneyDelay = 5,
    antiAfk = true,
}

local registerPrompts = nil
local promptScanAt = 0

-- ================= HELPERS =================

local function safe(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then warn("[GST Hub] " .. tostring(err)) end
    return ok
end

local function notify(title, content, icon)
    safe(function() WindUI:Notify({ Title = title, Content = content, Duration = 3, Icon = icon or "info" }) end)
end

local function myTycoon()
    for _, t in ipairs(WS.Tycoons:GetChildren()) do
        local info = t:FindFirstChild("Info")
        if info and info:FindFirstChild("Owner") and info.Owner.Value == LP.Name then
            return t
        end
    end
    return nil
end

local function addMoney(amount)
    local t = myTycoon()
    if not t then return false end
    safe(function()
        t.Control.Money:FireServer(amount, moneyCode(amount))
    end)
    return true
end

local function connect(sig, fn)
    if typeof(STATE) == "table" and STATE.connect then return STATE.connect(sig, fn) end
    return sig:Connect(fn)
end

local function alive()
    if typeof(STATE) ~= "table" or STATE.alive == nil then return true end
    return STATE.alive()
end

local function emptyGames(t)
    local out = {}
    local models = t:FindFirstChild("Models")
    if models then
        for _, m in ipairs(models:GetChildren()) do
            if m:IsA("Model") and m:FindFirstChild("Games") then
                for _, g in ipairs(m.Games:GetChildren()) do
                    if g:IsA("BasePart") and g.Transparency == 1 then
                        table.insert(out, g)
                    end
                end
            end
        end
    end
    return out
end

local function refreshRegisterPrompts(t)
    local found = {}
    for _, v in ipairs(t:GetDescendants()) do
        if v:IsA("ProximityPrompt") and v.ActionText == "Checkout" then
            table.insert(found, v)
        end
    end
    registerPrompts = found
    promptScanAt = os.clock()
end

local function customerNear(pos, radius)
    for _, c in ipairs(WS.Customers:GetChildren()) do
        -- customers can be Folders wrapping models, or models directly
        local containers = (c:IsA("Folder") and c:GetChildren()) or { c }
        for _, m in ipairs(containers) do
            local hr = m:IsA("Model") and (m:FindFirstChild("HumanoidRootPart") or m.PrimaryPart)
            if hr and (hr.Position - pos).Magnitude <= (radius or 14) then
                return true
            end
        end
    end
    return false
end

-- ================= UI =================

local Window = WindUI:CreateWindow({
    Title = "Game Store Tycoon Hub",
    Icon = "store",
    Author = "v2.0 final",
    Folder = "GameStoreTycoonHub",
    Size = UDim2.fromOffset(600, 520),
    Theme = "Dark",
    Transparent = true,
    ToggleKey = Enum.KeyCode.K,
    AutoScale = true,
    SideBarWidth = 190,
    HideSearchBar = true,
    NewElements = true,
    Background = WindUI:Gradient({
        ["0"] = { Color = Color3.fromHex("#0b1020"), Transparency = 0.02 },
        ["100"] = { Color = Color3.fromHex("#131a36"), Transparency = 0.06 },
    }, { Rotation = 90 }),
    User = { Enabled = true, Anonymous = true },
})

local function sect(tab, title)
    local ok, s = pcall(function() return tab:Section({ Title = title, Opened = true }) end)
    return (ok and s) and s or tab
end

-- ------ TAB: MAIN ------

local TabMain = Window:Tab({ Title = "Main", Icon = "zap", IconColor = Color3.fromHex("#ffd23f") })
local MA = sect(TabMain, "One-Click")

MA:Toggle({
    Title = "FULL AUTO",
    Desc = "Restock + register + delivery + robbers + anti-AFK. Works while you sleep.",
    Icon = "rocket",
    Value = false, Flag = "master_auto",
    Callback = function(v)
        S.autoRestock = v
        S.autoRegister = v
        S.autoDelivery = v
        S.autoRobber = v
        S.antiAfk = v
        notify("Full Auto", v and "Engaged - go AFK" or "Disabled", "rocket")
    end,
})

local MB = sect(TabMain, "Automation")
local statsPara = MB:Paragraph({ Title = "Live Stats", Desc = "warming up..." })

MB:Toggle({ Title = "Auto Restock", Desc = "Refill empty game stands", Value = false, Flag = "auto_restock",
    Callback = function(v) S.autoRestock = v end })
MB:Slider({ Title = "Restock Check Delay (s)", Value = { Min = 1, Max = 10, Default = 2 },
    Flag = "restock_delay", Callback = function(v) S.restockDelay = v end })

MB:Toggle({ Title = "Auto Register", Desc = "Takes customer orders at Checkout prompts + collects sales", Value = false, Flag = "auto_register",
    Callback = function(v) S.autoRegister = v end })

MB:Toggle({ Title = "Auto Delivery", Desc = "Collects any truck that arrives at your lot", Value = false, Flag = "auto_delivery",
    Callback = function(v) S.autoDelivery = v end })

MB:Toggle({ Title = "Auto Catch Robbers", Desc = "Restores robbed stands + untag + restock, like Security capture", Value = false, Flag = "auto_robber",
    Callback = function(v) S.autoRobber = v end })

-- ------ TAB: MONEY ------

local TabMoney = Window:Tab({ Title = "Money", Icon = "banknote", IconColor = Color3.fromHex("#4ade80") })
local MC = sect(TabMoney, "Instant Cash")

MC:Button({ Title = "+$10,000", Icon = "banknote", Callback = function()
    if addMoney(10000) then notify("Money", "+$10,000", "banknote") end
end })
MC:Button({ Title = "+$50,000", Icon = "banknote", Callback = function()
    if addMoney(50000) then notify("Money", "+$50,000", "banknote") end
end })
MC:Button({ Title = "+$100,000", Icon = "banknote", Callback = function()
    if addMoney(100000) then notify("Money", "+$100,000", "banknote") end
end })

local MD = sect(TabMoney, "Auto Money Drip")

MD:Toggle({
    Title = "Auto Money Drip",
    Desc = "Safe path to big numbers: mimics sale volume. A single billions-size call gets caught by anticheat and reverts your save - the drip does not.",
    Value = false, Flag = "auto_money",
    Callback = function(v) S.autoMoney = v end,
})
MD:Slider({ Title = "Amount per tick", Value = { Min = 1000, Max = 100000, Default = 10000 },
    Flag = "money_amount", Callback = function(v) S.moneyAmount = v end })
MD:Slider({ Title = "Delay (s)", Value = { Min = 2, Max = 60, Default = 5 },
    Flag = "money_delay", Callback = function(v) S.moneyDelay = v end })
MD:Paragraph({ Title = "Rate", Desc = "10K / 5s = $120K per hour per 10K tick. 100K / 5s = $1.2M/hr. Watch Live Stats - if money ever snaps backwards, the save reverted: lower the amount." })

-- ------ TAB: MISC ------

local TabMisc = Window:Tab({ Title = "Misc", Icon = "ellipsis", IconColor = Color3.fromHex("#94a3b8") })
local MS = sect(TabMisc, "Utility")

MS:Toggle({ Title = "Anti-AFK", Desc = "Silent, keeps you connected forever", Value = true, Flag = "ut_afk",
    Callback = function(v) S.antiAfk = v end })
MS:Button({ Title = "Rejoin Server", Icon = "refresh-cw", Callback = function() TS:Teleport(game.PlaceId, LP) end })

TabMisc:Paragraph({ Title = "Info", Desc = "K - toggle menu\nSettings save between sessions.\nStand near your registers/lot when possible - some prompts check distance." })

-- ================= CORE LOOPS =================

-- automation loop
task.spawn(function()
    local robberTick = 0
    while alive() do
        local t = myTycoon()
        if t then

            -- RESTOCK (verified)
            if S.autoRestock then
                safe(function()
                    local empties = emptyGames(t)
                    if #empties > 0 then
                        for _, g in ipairs(empties) do
                            t.Control.Restock:FireServer(g)
                        end
                        t.Control.Update:FireServer()
                    end
                end)
            end

            -- REGISTER: fire Checkout prompts when a customer waits nearby
            if S.autoRegister then
                safe(function()
                    if not registerPrompts or (os.clock() - promptScanAt) > 15 then
                        refreshRegisterPrompts(t)
                    end
                    for _, p in ipairs(registerPrompts) do
                        if p.Parent and p.Enabled then
                            local anchorPart = p.Parent
                            if customerNear(anchorPart.Position, 14) then
                                fireproximityprompt(p)
                            end
                        end
                    end
                    -- collect pending sale popup (verified money call)
                    if t.Info.Sale.Value ~= 0 then
                        local sale = t.Info.Sale.Value
                        t.Control.Money:FireServer(sale, moneyCode(sale))
                    end
                end)
            end

            -- DELIVERY: trucks are dynamic - scan Vehicles + lot spots
            if S.autoDelivery then
                safe(function()
                    for _, v in ipairs(WS.Vehicles:GetChildren()) do
                        local b = v:FindFirstChild("boxes")
                        if b and b.Value > 0 and v.PrimaryPart then
                            local pp = v.PrimaryPart:FindFirstChildOfClass("ProximityPrompt")
                            if pp and pp.Enabled then
                                fireproximityprompt(pp)
                            end
                        end
                    end
                    local lot = t.Info.Lot.Value
                    if lot then
                        local tp = lot:FindFirstChild("truckpath")
                        if tp then
                            local spots = tp:FindFirstChild("spots")
                            if spots then
                                for _, spot in ipairs(spots:GetChildren()) do
                                    for _, child in ipairs(spot:GetChildren()) do
                                        if child:IsA("Model") then
                                            local b = child:FindFirstChild("boxes")
                                            if b and b.Value > 0 and child.PrimaryPart then
                                                local pp = child.PrimaryPart:FindFirstChildOfClass("ProximityPrompt")
                                                if pp and pp.Enabled then
                                                    fireproximityprompt(pp)
                                                end
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end
                end)
            end

            -- ROBBER: untag + restock robbed stands (game's own recovery)
            robberTick += 1
            if S.autoRobber and robberTick >= 2 then
                robberTick = 0
                safe(function()
                    local tagged = {}
                    for _, d in ipairs(t:GetDescendants()) do
                        if d.Name == "RobberTag" and d.Parent then
                            local decal = d.Parent
                            local part = decal.Parent
                            if part and part:IsA("BasePart") then
                                table.insert(tagged, { part = part, tag = d })
                            end
                        end
                    end
                    for _, e in ipairs(tagged) do
                        takegame:FireServer(e.part, "restock")
                        takegame:FireServer(e.part, "untag")
                        e.tag:Destroy()
                    end
                end)
            end
        end

        task.wait(1)
    end
end)

-- money drip (sole owner of auto-money)
task.spawn(function()
    while alive() do
        if S.autoMoney then
            safe(function() addMoney(S.moneyAmount) end)
        end
        task.wait(math.max(S.moneyDelay, 2))
    end
end)

-- stats
task.spawn(function()
    while alive() do
        local t = myTycoon()
        if t and statsPara then
            safe(function()
                statsPara:SetTitle("Live Stats")
                statsPara:SetDesc(table.concat({
                    string.format("Money: $%s", t.Info.Money.Value),
                    string.format("Games: %d/%d  |  Rating: %.2f",
                        t.Info.Games.Value, t.Info.MaxGames.Value, t.Info.Rating.Value),
                    string.format("Customers: %d max  |  InLine: %d  |  Ads: %d",
                        t.Info.MaxCustomers.Value, t.Info.InLine.Value, t.Info.Ads.Value),
                }, "\n"))
            end)
        end
        task.wait(1)
    end
end)

-- anti-AFK
connect(LP.Idled, function()
    if S.antiAfk then
        VU:CaptureController()
        VU:ClickButton2(Vector2.new())
    end
end)

if typeof(STATE) == "table" and STATE.onCleanup then
    STATE.onCleanup(function() end)
end

notify("Game Store Tycoon Hub", "v2.0 final loaded - press K", "store")
print("[GST Hub v2.0] Loaded")
