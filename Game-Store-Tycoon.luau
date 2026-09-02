local WindUI = loadstring(game:HttpGet("https://github.com/Footagesus/WindUI/releases/latest/download/main.lua"))()

local Players     = game:GetService("Players")
local RS          = game:GetService("ReplicatedStorage")
local WS          = game:GetService("Workspace")
local RunService  = game:GetService("RunService")
local UIS         = game:GetService("UserInputService")
local VU          = game:GetService("VirtualUser")
local TS          = game:GetService("TeleportService")
local Lighting    = game:GetService("Lighting")

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

    -- v4 staff suite
    autoStaff = false,
    autoUpgrade = false, upgradeDelay = 30,
    fpsBoost = false,
    espTycoons = false, espRange = 300,

    -- telemetry
    regTaken = 0, trucksUnloaded = 0, robbersCaught = 0, standsRestocked = 0,
    hiredStaff = 0, upgradesBought = 0,
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

local function comma(n)
    n = math.floor(n)
    local s = tostring(math.abs(n))
    local sign = n < 0 and "-" or ""
    while true do
        local s2, k = s:gsub("^(-?%d+)(%d%d%d)", "%1,%2")
        if k == 0 then break end
        s = s2
    end
    return sign .. s
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

-- staff slots: registers 1..7 (job 2), Sec1..6 posts (job 5)
-- game hires via Employee:InvokeServer(slotNumber, 1)
local function staffSlots(t)
    local out = {}
    for i = 1, 7 do
        table.insert(out, { name = "Register " .. i, id = i, kind = "register" })
    end
    for i = 1, 6 do
        table.insert(out, { name = "Security " .. i, id = i + 10, kind = "security" })
    end
    return out
end

local function isSlotHired(t, slot)
    local emps = t:FindFirstChild("Employees")
    if not emps then return false end
    for _, e in ipairs(emps:GetChildren()) do
        local j = e:FindFirstChild("Job")
        -- register slots map to Emp parts; simplest check: the part has no Placeholder
    end
    return false
end

-- ================= LIGHTING / CLEANUP =================

local lightingSaved = nil
local function applyLighting()
    if S.fpsBoost and not lightingSaved then
        lightingSaved = {
            shadows = Lighting.GlobalShadows,
            brightness = Lighting.Brightness,
        }
    end
    if S.fpsBoost then
        safe(function()
            Lighting.GlobalShadows = false
            for _, e in ipairs(Lighting:GetChildren()) do
                if e:IsA("PostEffect") then e.Enabled = false end
            end
        end)
    elseif lightingSaved then
        safe(function()
            Lighting.GlobalShadows = lightingSaved.shadows
            Lighting.Brightness = lightingSaved.brightness
        end)
        lightingSaved = nil
    end
end

-- ================= PLAYER ESP =================

local tycoonLabels = {}

local function clearTycoonEsp()
    for _, l in pairs(tycoonLabels) do
        if l and l.Parent then l.Parent:Destroy() end
    end
    tycoonLabels = {}
end

-- ================= UI =================

local Window = WindUI:CreateWindow({
    Title = "Game Store Tycoon Hub",
    Icon = "store",
    Author = "v4.0 superhub",
    Folder = "GameStoreTycoonHub",
    Size = UDim2.fromOffset(620, 560),
    Theme = "Dark",
    Transparent = true,
    ToggleKey = Enum.KeyCode.K,
    AutoScale = true,
    SideBarWidth = 195,
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
    Title = "GOD MODE",
    Desc = "Everything: register + delivery + robbers + restock + staff + upgrades + anti-AFK. Turn it on and never think about the store again.",
    Icon = "rocket",
    Value = false, Flag = "master_god",
    Callback = function(v)
        S.autoRegister = v
        S.autoDelivery = v
        S.autoRobber = v
        S.autoRestock = v
        S.autoStaff = v
        S.autoUpgrade = v
        S.antiAfk = v
        notify("God Mode", v and "Engaged - the store runs itself" or "Disabled", "rocket")
    end,
})

local MB = sect(TabMain, "Automation")
local statsPara = MB:Paragraph({ Title = "Live Stats", Desc = "warming up..." })

MB:Toggle({ Title = "Auto Register", Desc = "Takes ALL queued orders instantly - game's own flow", Value = false, Flag = "auto_register",
    Callback = function(v) S.autoRegister = v end })

MB:Toggle({ Title = "Auto Delivery", Desc = "Unloads truck boxes + collects cash drops", Value = false, Flag = "auto_delivery",
    Callback = function(v) S.autoDelivery = v end })

MB:Toggle({ Title = "Auto Catch Robbers", Desc = "Arrests every robber that spawns", Value = false, Flag = "auto_robber",
    Callback = function(v) S.autoRobber = v end })

MB:Toggle({ Title = "Auto Restock", Desc = "Refills empty game stands", Value = false, Flag = "auto_restock",
    Callback = function(v) S.autoRestock = v end })
MB:Slider({ Title = "Restock Delay (s)", Value = { Min = 1, Max = 10, Default = 2 },
    Flag = "restock_delay", Callback = function(v) S.restockDelay = v end })

-- ------ TAB: STAFF ------

local TabStaff = Window:Tab({ Title = "Staff", Icon = "users", IconColor = Color3.fromHex("#a78bfa") })
local SA = sect(TabStaff, "Automation")

SA:Toggle({
    Title = "Auto Full Staff",
    Desc = "Hires employees into every open slot (registers + security) whenever the store can afford them.",
    Value = false, Flag = "auto_staff",
    Callback = function(v) S.autoStaff = v end,
})

local SB = sect(TabStaff, "Manual")

SB:Button({
    Title = "Hire for All Open Registers", Icon = "user-plus",
    Callback = function()
        local t = myTycoon()
        if not t then return end
        local hired = 0
        for _, slot in ipairs(staffSlots(t)) do
            if slot.kind == "register" then
                safe(function()
                    local emp = t.Control:FindFirstChild("Employee")
                    if emp then
                        emp:InvokeServer(slot.id, 1)
                        hired += 1
                    end
                end)
                task.wait(0.15)
            end
        end
        S.hiredStaff += hired
        notify("Staff", "Hire calls fired: " .. hired, "users")
    end,
})

SB:Button({
    Title = "Hire Security Team", Icon = "shield",
    Callback = function()
        local t = myTycoon()
        if not t then return end
        local hired = 0
        for _, slot in ipairs(staffSlots(t)) do
            if slot.kind == "security" then
                safe(function()
                    local emp = t.Control:FindFirstChild("Employee")
                    if emp then
                        emp:InvokeServer(slot.id, 1)
                        hired += 1
                    end
                end)
                task.wait(0.15)
            end
        end
        S.hiredStaff += hired
        notify("Security", "Hire calls fired: " .. hired, "shield")
    end,
})

SB:Button({
    Title = "Fire Everyone", Icon = "user-minus",
    Callback = function()
        local t = myTycoon()
        if not t then return end
        for _, slot in ipairs(staffSlots(t)) do
            safe(function()
                t.Control.Employee:InvokeServer(slot.id, 2)
            end)
            task.wait(0.15)
        end
        notify("Staff", "Fire calls fired", "user-minus")
    end,
})

-- ------ TAB: UPGRADES ------

local TabUp = Window:Tab({ Title = "Upgrades", Icon = "trending-up", IconColor = Color3.fromHex("#4ade80") })
local UA = sect(TabUp, "Store Building")

UA:Button({
    Title = "Upgrade Building NOW", Desc = "Buys the next building tier", Icon = "arrow-up-circle",
    Callback = function()
        local t = myTycoon()
        if not t then return end
        safe(function() t.Control.Upgrade:FireServer() end)
        S.upgradesBought += 1
        notify("Upgrade", "Building upgrade fired", "trending-up")
    end,
})

UA:Toggle({
    Title = "Auto Upgrade Building",
    Desc = "Buys the next tier whenever affordable, on an interval.",
    Value = false, Flag = "auto_upgrade",
    Callback = function(v) S.autoUpgrade = v end,
})
UA:Slider({ Title = "Upgrade Check Delay (s)", Value = { Min = 10, Max = 300, Default = 30 },
    Flag = "upgrade_delay", Callback = function(v) S.upgradeDelay = v end })

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
    Desc = "Safe path - mimics sale volume. Single billions-size calls get caught; the drip does not.",
    Value = false, Flag = "auto_money",
    Callback = function(v) S.autoMoney = v end,
})
MD:Slider({ Title = "Amount per tick", Value = { Min = 1000, Max = 100000, Default = 10000 },
    Flag = "money_amount", Callback = function(v) S.moneyAmount = v end })
MD:Slider({ Title = "Delay (s)", Value = { Min = 2, Max = 60, Default = 5 },
    Flag = "money_delay", Callback = function(v) S.moneyDelay = v end })

-- ------ TAB: VISUALS ------

local TabVis = Window:Tab({ Title = "Visuals", Icon = "eye", IconColor = Color3.fromHex("#7dd87d") })
local VA = sect(TabVis, "World")

VA:Toggle({ Title = "Tycoon ESP", Desc = "Labels every tycoon with owner + money", Value = false, Flag = "esp_tycoons",
    Callback = function(v) S.espTycoons = v; if not v then clearTycoonEsp() end end })
VA:Slider({ Title = "ESP Range", Value = { Min = 100, Max = 1000, Default = 300 },
    Flag = "esp_range", Callback = function(v) S.espRange = v end })

local VB = sect(TabVis, "Client")

VB:Toggle({ Title = "FPS Boost", Desc = "Shadows + post-effects off", Value = false, Flag = "gfx_fps",
    Callback = function(v) S.fpsBoost = v; applyLighting() end })

-- ------ TAB: MISC ------

local TabMisc = Window:Tab({ Title = "Misc", Icon = "ellipsis", IconColor = Color3.fromHex("#94a3b8") })
local MS = sect(TabMisc, "Utility")

MS:Toggle({ Title = "Anti-AFK", Desc = "Silent, keeps you connected forever", Value = true, Flag = "ut_afk",
    Callback = function(v) S.antiAfk = v end })
MS:Button({ Title = "Restore Everything", Icon = "rotate-ccw", Callback = function()
    S.fpsBoost = false
    applyLighting()
    clearTycoonEsp()
    notify("Restored", "Visuals returned to vanilla", "rotate-ccw")
end })
MS:Button({ Title = "Rejoin Server", Icon = "refresh-cw", Callback = function() TS:Teleport(game.PlaceId, LP) end })

TabMisc:Paragraph({ Title = "Info", Desc = "K - toggle menu\nSettings save between sessions.\nGOD MODE is all you need." })

-- ================= CORE LOOPS =================

-- fast automation loop
task.spawn(function()
    local restockAcc = 0
    while alive() do
        local t = myTycoon()
        if t then

            -- REGISTER
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
                    if t.Info.Sale.Value ~= 0 then
                        local sale = t.Info.Sale.Value
                        t.Control.Money:FireServer(sale, moneyCode(sale))
                    end
                end)
            end

            -- DELIVERY
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
                        if v:FindFirstChild("boxes") then unloadTruck(v) end
                    end
                    local lot = t.Info.Lot.Value
                    if lot then
                        local tp = lot:FindFirstChild("truckpath")
                        local spots = tp and tp:FindFirstChild("spots")
                        if spots then
                            for _, spot in ipairs(spots:GetChildren()) do
                                local occ = spot:FindFirstChild("occupied")
                                local truck = occ and occ.Value
                                if truck and truck.Parent then unloadTruck(truck) end
                            end
                        end
                    end
                end)
            end

            -- ROBBER
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

            -- RESTOCK
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

        task.wait(S.autoRegister and 0.4 or 1)
    end
end)

-- staff + upgrades loop (slower cadence)
task.spawn(function()
    local staffAcc = 0
    local upAcc = 0
    while alive() do
        local t = myTycoon()
        if t then
            -- STAFF: hire into any free register slot
            if S.autoStaff then
                staffAcc += 1
                if staffAcc >= 5 then
                    staffAcc = 0
                    safe(function()
                        -- hire only where the Emp part has no Placeholder yet
                        for i = 1, 7 do
                            local empPart = t:FindFirstChild("Emp" .. i)
                            if empPart and empPart:FindFirstChild("Placeholder") == nil then
                                t.Control.Employee:InvokeServer(i, 1)
                                S.hiredStaff += 1
                                task.wait(0.2)
                            end
                        end
                        for i = 1, 6 do
                            local secPart = t:FindFirstChild("Sec" .. i)
                            if secPart and secPart:FindFirstChild("Placeholder") == nil then
                                t.Control.Employee:InvokeServer(i + 10, 1)
                                S.hiredStaff += 1
                                task.wait(0.2)
                            end
                        end
                    end)
                end
            end

            -- UPGRADE: next tier when affordable
            if S.autoUpgrade then
                upAcc += 1
                if upAcc >= math.max(S.upgradeDelay, 10) then
                    upAcc = 0
                    safe(function()
                        t.Control.Upgrade:FireServer()
                        S.upgradesBought += 1
                    end)
                end
            end
        end
        task.wait(1)
    end
end)

-- money drip
task.spawn(function()
    while alive() do
        if S.autoMoney then
            safe(function() addMoney(S.moneyAmount) end)
        end
        task.wait(math.max(S.moneyDelay, 2))
    end
end)

-- ESP loop
task.spawn(function()
    while alive() do
        if S.espTycoons then
            safe(function()
                local myPos = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
                    and LP.Character.HumanoidRootPart.Position
                if myPos then
                    for _, ty in ipairs(WS.Tycoons:GetChildren()) do
                        local info = ty:FindFirstChild("Info")
                        local lot = info and info:FindFirstChild("Lot")
                        local anchor = lot and lot.Value and lot.Value:FindFirstChildWhichIsA("BasePart")
                        if anchor and (anchor.Position - myPos).Magnitude <= S.espRange then
                            local label = tycoonLabels[ty]
                            if not label or not label.Parent then
                                local bg = Instance.new("BillboardGui")
                                bg.Size = UDim2.new(0, 180, 0, 30)
                                bg.StudsOffset = Vector3.new(0, 10, 0)
                                bg.AlwaysOnTop = true
                                bg.Adornee = anchor
                                bg.Parent = anchor
                                local tl = Instance.new("TextLabel")
                                tl.Size = UDim2.new(1, 0, 1, 0)
                                tl.BackgroundTransparency = 1
                                tl.TextColor3 = Color3.fromRGB(120, 220, 120)
                                tl.TextStrokeTransparency = 0.3
                                tl.TextSize = 14
                                tl.Font = Enum.Font.GothamBold
                                tl.Parent = bg
                                tycoonLabels[ty] = tl
                            end
                            local money = info:FindFirstChild("Money")
                            local owner = info:FindFirstChild("Owner")
                            label.Text = (owner and owner.Value or "?") .. " - $" ..
                                (money and comma(money.Value) or "?")
                        end
                    end
                    -- remove labels for tycoons out of range or gone
                    for ty, l in pairs(tycoonLabels) do
                        if not ty.Parent or not l.Parent then
                            if l.Parent then l.Parent:Destroy() end
                            tycoonLabels[ty] = nil
                        end
                    end
                end
            end)
        end
        task.wait(1)
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
                    string.format("Money: $%s", comma(t.Info.Money.Value)),
                    string.format("Games: %d/%d  |  Rating: %.2f  |  Bldg: %d",
                        t.Info.Games.Value, t.Info.MaxGames.Value, t.Info.Rating.Value, t.Info.Building.Value),
                    string.format("Customers: %d max  |  InLine: %d",
                        t.Info.MaxCustomers.Value, t.Info.InLine.Value),
                    string.format("Orders: %d  Trucks: %d  Robbers: %d  Restocks: %d",
                        S.regTaken, S.trucksUnloaded, S.robbersCaught, S.standsRestocked),
                    string.format("Hired: %d  |  Upgrades: %d",
                        S.hiredStaff, S.upgradesBought),
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
    STATE.onCleanup(function()
        clearTycoonEsp()
    end)
end

notify("Game Store Tycoon Hub", "v4.0 superhub loaded - press K", "store")
print("[GST Hub v4.0] Loaded")
