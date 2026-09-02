local WindUI = loadstring(game:HttpGet("https://github.com/Footagesus/WindUI/releases/latest/download/main.lua"))()

local Players     = game:GetService("Players")
local RS          = game:GetService("ReplicatedStorage")
local WS          = game:GetService("Workspace")
local VU          = game:GetService("VirtualUser")
local TS          = game:GetService("TeleportService")

local LP          = Players.LocalPlayer

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
    -- telemetry
    regTaken = 0, trucksUnloaded = 0, robbersCaught = 0, standsRestocked = 0,
}

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

-- empty game stands: Games children with Transparency == 1
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

-- register map: game pairs Line.N with RegisterModels.N (verified:
-- queue Folder gets a child, employee calls RemoteTrigger:InvokeServer)
local function registerMap(t)
    local out = {}
    local rm = t:FindFirstChild("RegisterModels")
    local line = t:FindFirstChild("Line")
    if rm and line then
        for _, l in ipairs(line:GetChildren()) do
            local n = l.Name:match("^(%d+)$")
            if n then
                local reg = rm:FindFirstChild(n)
                local rt = reg and reg:FindFirstChild("RemoteTrigger")
                if rt and rt:IsA("RemoteFunction") then
                    table.insert(out, { lineFolder = l, trigger = rt, n = n })
                end
            end
        end
    end
    return out
end

-- ================= UI =================

local Window = WindUI:CreateWindow({
    Title = "Game Store Tycoon Hub",
    Icon = "store",
    Author = "v3.0 final",
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

MB:Toggle({ Title = "Auto Register", Desc = "Takes ALL queued customer orders the instant they line up - the game's own register flow", Value = false, Flag = "auto_register",
    Callback = function(v) S.autoRegister = v end })

MB:Toggle({ Title = "Auto Restock", Desc = "Refill empty game stands", Value = false, Flag = "auto_restock",
    Callback = function(v) S.autoRestock = v end })
MB:Slider({ Title = "Restock Check Delay (s)", Value = { Min = 1, Max = 10, Default = 2 },
    Flag = "restock_delay", Callback = function(v) S.restockDelay = v end })

MB:Toggle({ Title = "Auto Delivery", Desc = "Unloads truck boxes + collects the cash drop", Value = false, Flag = "auto_delivery",
    Callback = function(v) S.autoDelivery = v end })

MB:Toggle({ Title = "Auto Catch Robbers", Desc = "Arrests any robber that spawns in your store", Value = false, Flag = "auto_robber",
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
    Desc = "Safe path to big numbers - mimics sale volume. A single billions-size call gets caught and reverts your save; the drip does not.",
    Value = false, Flag = "auto_money",
    Callback = function(v) S.autoMoney = v end,
})
MD:Slider({ Title = "Amount per tick", Value = { Min = 1000, Max = 100000, Default = 10000 },
    Flag = "money_amount", Callback = function(v) S.moneyAmount = v end })
MD:Slider({ Title = "Delay (s)", Value = { Min = 2, Max = 60, Default = 5 },
    Flag = "money_delay", Callback = function(v) S.moneyDelay = v end })
MD:Paragraph({ Title = "Rate", Desc = "10K / 5s = $120K per hour. 100K / 5s = $1.2M/hr. If money ever snaps backwards, the save reverted - lower the amount." })

-- ------ TAB: MISC ------

local TabMisc = Window:Tab({ Title = "Misc", Icon = "ellipsis", IconColor = Color3.fromHex("#94a3b8") })
local MS = sect(TabMisc, "Utility")

MS:Toggle({ Title = "Anti-AFK", Desc = "Silent, keeps you connected forever", Value = true, Flag = "ut_afk",
    Callback = function(v) S.antiAfk = v end })
MS:Button({ Title = "Rejoin Server", Icon = "refresh-cw", Callback = function() TS:Teleport(game.PlaceId, LP) end })

TabMisc:Paragraph({ Title = "Info", Desc = "K - toggle menu\nSettings save between sessions." })

-- ================= CORE LOOPS =================

task.spawn(function()
    local restockAcc = 0
    while alive() do
        local t = myTycoon()
        if t then

            -- REGISTER: instant - take every queued order
            if S.autoRegister then
                safe(function()
                    local taken = 0
                    for _, r in ipairs(registerMap(t)) do
                        local folder = r.lineFolder:FindFirstChild("Folder")
                        if folder and #folder:GetChildren() > 0 then
                            r.trigger:InvokeServer()
                            taken += 1
                        end
                    end
                    if taken > 0 then S.regTaken += taken end
                    -- collect pending sale popup if the UI missed it
                    if t.Info.Sale.Value ~= 0 then
                        local sale = t.Info.Sale.Value
                        t.Control.Money:FireServer(sale, moneyCode(sale))
                    end
                end)
            end

            -- DELIVERY: unload boxes + collect cash drop
            if S.autoDelivery then
                safe(function()
                    local function unloadTruck(truck)
                        if not (truck and truck.Parent and truck.PrimaryPart) then return end
                        local boxes = truck:FindFirstChild("boxes")
                        if not boxes then return end
                        local remote = truck.PrimaryPart:FindFirstChild("Remote")
                        if remote and boxes.Value > 0 then
                            remote:Fire()
                            S.trucksUnloaded += 1
                        end
                        local pp = truck.PrimaryPart:FindFirstChildOfClass("ProximityPrompt")
                        if pp and pp.Enabled and boxes.Value <= 0 then
                            fireproximityprompt(pp)
                        end
                    end
                    for _, v in ipairs(WS.Vehicles:GetChildren()) do
                        if v:FindFirstChild("boxes") then
                            unloadTruck(v)
                        end
                    end
                    local lot = t.Info.Lot.Value
                    if lot then
                        local tp = lot:FindFirstChild("truckpath")
                        local spots = tp and tp:FindFirstChild("spots")
                        if spots then
                            for _, spot in ipairs(spots:GetChildren()) do
                                local occ = spot:FindFirstChild("occupied")
                                local truck = occ and occ.Value
                                if truck and truck.Parent then
                                    unloadTruck(truck)
                                end
                            end
                        end
                    end
                end)
            end

            -- ROBBER: arrest via the game's own CaptureFn
            if S.autoRobber then
                safe(function()
                    for _, v in ipairs(t:GetChildren()) do
                        if v:IsA("Folder") and v:FindFirstChild("CaptureFn")
                            and v:FindFirstChild("Captured") and not v.Captured.Value then
                            pcall(function() v.CaptureFn:Invoke() end)
                            S.robbersCaught += 1
                        end
                    end
                end)
            end

            -- RESTOCK: on its own cadence (costs money per stand)
            restockAcc += 1
            if S.autoRestock and restockAcc >= math.max(S.restockDelay, 1) then
                restockAcc = 0
                safe(function()
                    local empties = emptyGames(t)
                    if #empties > 0 then
                        for _, g in ipairs(empties) do
                            t.Control.Restock:FireServer(g)
                        end
                        t.Control.Update:FireServer()
                        S.standsRestocked += #empties
                    end
                end)
            end
        end

        -- fast tick while register automation runs so queues never wait
        task.wait(S.autoRegister and 0.4 or 1)
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
                    string.format("Orders taken: %d  |  Trucks: %d  |  Robbers: %d  |  Restocks: %d",
                        S.regTaken, S.trucksUnloaded, S.robbersCaught, S.standsRestocked),
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

notify("Game Store Tycoon Hub", "v3.0 final loaded - press K", "store")
print("[GST Hub v3.0] Loaded")
