if game.PlaceId ~= 10963175 then return end

local WindUI = loadstring(game:HttpGet("https://github.com/Footagesus/WindUI/releases/latest/download/main.lua"))()

local Players     = game:GetService("Players")
local RS          = game:GetService("ReplicatedStorage")
local WS          = game:GetService("Workspace")
local VU          = game:GetService("VirtualUser")
local TS          = game:GetService("TeleportService")
local Lighting    = game:GetService("Lighting")

local LP          = Players.LocalPlayer

pcall(function() WindUI:SetParent(game:GetService("CoreGui")) end)
pcall(function() WindUI:SetNotificationLower(true) end)

-- ================= CONSTANTS =================

local CAP = 1e9                -- hard cap: above this, money resets to 0
local SAFE_CEILING = 950e6     -- drip stops here
local TEAM_PLAN = { { job = 2, count = 7 }, { job = 4, count = 3 } }
local JOB_NAMES = { [2] = "Register", [3] = "Restocker", [4] = "Delivery", [5] = "Security" }

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
    -- automation
    autoRegister = false,
    autoRestock = false, restockDelay = 2,
    autoDelivery = false,
    autoRobber = false,
    autoTeam = false,
    autoFirePaid = false,
    autoMoney = false, moneyAmount = 10000, moneyDelay = 5,
    autoSave = true, saveDelay = 120,
    autoRejoin = true,
    antiAfk = true,

    -- hiring
    hireWage = 0,

    -- visuals
    fpsBoost = false,
    espTycoons = false, espRange = 500,

    -- telemetry
    regTaken = 0, trucksUnloaded = 0, robbersCaught = 0, standsRestocked = 0,
    hiredStaff = 0, itemsBought = 0, paidFired = 0, savesFired = 0,
    sessionEarn = 0, peakMoney = 0, lastM = nil,
    capNotified = false,
    earnLog = {},
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

local function connect(sig, fn)
    if typeof(STATE) == "table" and STATE.connect then return STATE.connect(sig, fn) end
    return sig:Connect(fn)
end

local function alive()
    if typeof(STATE) ~= "table" or STATE.alive == nil then return true end
    return STATE.alive()
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

local function ctrlRemote(t, name)
    local c = t:FindFirstChild("Control")
    local r = c and c:FindFirstChild(name)
    if r and (r:IsA("RemoteEvent") or r:IsA("RemoteFunction")) then
        return r
    end
    return nil
end

local function moneyNow()
    local t = myTycoon()
    local info = t and t:FindFirstChild("Info")
    local m = info and info:FindFirstChild("Money")
    return m and m.Value or 0
end

local function lotAnchor(t)
    local info = t:FindFirstChild("Info")
    local lot = info and info:FindFirstChild("Lot")
    local v = lot and lot.Value
    if v and v:IsA("BasePart") then
        return v
    end
    return nil
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

-- ================= CAP-GUARDED MONEY =================

local function addMoney(amount)
    local t = myTycoon()
    if not t then return false end
    if amount > 0 then
        local current = moneyNow()
        if current >= SAFE_CEILING then
            if not S.capNotified then
                S.capNotified = true
                notify("Cap Guard", "At $" .. comma(current) .. " - drip paused below the $1B cap", "shield")
            end
            return false
        end
        if current + amount > CAP - 50e6 then
            amount = math.max(1000, CAP - 50e6 - current)
        end
    end
    local m = ctrlRemote(t, "Money")
    if m then
        safe(function() m:FireServer(amount, moneyCode(amount)) end)
    end
    return true
end

local function forceSave()
    local t = myTycoon()
    if not t then return false end
    local s = ctrlRemote(t, "Save")
    if s then
        safe(function() s:FireServer() end)
        S.savesFired += 1
        return true
    end
    return false
end

-- ================= TEAM SYSTEM =================

local function teamCounts(t)
    local counts = { 0, 0, 0, 0, 0, 0 }
    local emps = t:FindFirstChild("Employees")
    if emps then
        for _, e in ipairs(emps:GetChildren()) do
            local j = e:FindFirstChild("Job")
            if j and j.Value >= 1 and j.Value <= 5 then
                counts[j.Value] += 1
            end
        end
    end
    return counts
end

local function hireWaged(job, wage)
    local t = myTycoon()
    if not t then return false end
    local template = RS:FindFirstChild("Employee")
    local newemp = WS:FindFirstChild("Events") and WS.Events:FindFirstChild("newemp")
    if not (template and newemp) then return false end
    local ok = pcall(function()
        newemp:InvokeServer(t, template, {
            Job = job,
            Nam = template.Nam.Value,
            Cost = wage,
            Color = template.Appearance.Color.Value,
            Hair = template.Appearance.Hair.Value,
        })
    end)
    if ok then S.hiredStaff += 1 end
    return ok
end

local function hireManyWaged(job, count, wage)
    local hired = 0
    for _ = 1, count do
        if not alive() then break end
        if hireWaged(job, wage) then hired += 1 end
        task.wait(0.25)
    end
    return hired
end

local function buildTeam()
    local t = myTycoon()
    if not t then return 0 end
    local counts = teamCounts(t)
    local hired = 0
    for _, entry in ipairs(TEAM_PLAN) do
        local deficit = entry.count - counts[entry.job]
        for _ = 1, math.max(deficit, 0) do
            if hireWaged(entry.job, S.hireWage) then hired += 1 end
            task.wait(0.3)
        end
    end
    return hired
end

local function fireEmployee(t, empFolder)
    local fireemp = WS:FindFirstChild("Events") and WS.Events:FindFirstChild("fireemp")
    if not fireemp then return false end
    local ok = pcall(function()
        fireemp:FireServer(t, empFolder)
    end)
    if ok then S.paidFired += 1 end
    return ok
end

local function fireAllPaid()
    local t = myTycoon()
    if not t then return 0 end
    local emps = t:FindFirstChild("Employees")
    if not emps then return 0 end
    local fired = 0
    for _, e in ipairs(emps:GetChildren()) do
        local c = e:FindFirstChild("Cost")
        if c and c.Value > 0 then
            if fireEmployee(t, e) then fired += 1 end
            task.wait(0.2)
        end
    end
    return fired
end

local function fireEveryone()
    local t = myTycoon()
    if not t then return 0 end
    local emps = t:FindFirstChild("Employees")
    if not emps then return 0 end
    local fired = 0
    for _, e in ipairs(emps:GetChildren()) do
        if fireEmployee(t, e) then fired += 1 end
        task.wait(0.2)
    end
    return fired
end

-- ================= REGISTER =================

local lastQueueN = {}

local function claimSpot(t, n)
    local emp = t:FindFirstChild("Emp" .. n)
    if not emp or emp:FindFirstChild("Placeholder") then
        return nil
    end
    local ov = Instance.new("ObjectValue")
    ov.Name = "Placeholder"
    ov.Value = LP
    ov.Parent = emp
    return ov
end

local function queueSize(t, n)
    local lf = t:FindFirstChild("Line")
    lf = lf and lf:FindFirstChild(tostring(n))
    local folder = lf and lf:FindFirstChild("Folder")
    return folder and #folder:GetChildren() or 0
end

local function serveRegister(n)
    local t = myTycoon()
    if not t then return end
    local reg = t:FindFirstChild("RegisterModels")
    reg = reg and reg:FindFirstChild(tostring(n))
    local trigger = reg and reg:FindFirstChild("RemoteTrigger")
    if not trigger then return end
    if queueSize(t, n) == 0 then return end
    local holder = claimSpot(t, n)
    safe(function() trigger:InvokeServer() end)
    S.regTaken += 1
    if holder then holder:Destroy() end
end

-- ================= ROBBERS =================

local function captureRobber(folder)
    local ok1 = pcall(function() folder.UncoverFn:Invoke() end)
    task.wait(0.5)
    local ok2 = pcall(function() folder.CaptureFn:Invoke() end)
    if ok1 or ok2 then S.robbersCaught += 1 end
end

-- ================= MAX TIER =================

local function upgradeToMax()
    local tiers = 0
    local t = myTycoon()
    if not t then return 0 end
    local up = ctrlRemote(t, "Upgrade")
    if not up then return 0 end
    for _ = 1, 30 do
        if not alive() then break end
        local ft = myTycoon()
        if not ft then break end
        local before = ft.Info:FindFirstChild("TycoonBuilding")
        before = before and before.Value or 0
        up:FireServer()
        task.wait(6)
        local ft2 = myTycoon()
        if not ft2 then break end
        local now = ft2.Info:FindFirstChild("TycoonBuilding")
        now = now and now.Value or 0
        if now > before then
            tiers += now - before
        else
            break
        end
    end
    forceSave()
    return tiers
end

-- ================= BUY EVERYTHING =================

local CAT_MAP = {
    { info = "Models", world = "Models" },
    { info = "AdModels", world = "AdModels" },
    { info = "RegisterModels", world = "RegisterModels" },
    { info = "BuildingModels", world = "Buildings" },
}

local function buyEverything()
    local t = myTycoon()
    if not t then return { bought = 0 } end
    local info = t:FindFirstChild("Info")
    local purchase = ctrlRemote(t, "PurchaseModel")
    if not (info and purchase) then return { bought = 0 } end

    local bought = 0
    for _, entry in ipairs(CAT_MAP) do
        local folder = info:FindFirstChild(entry.info)
        local world = t:FindFirstChild(entry.world)
        if folder and world then
            for _, v in ipairs(folder:GetChildren()) do
                if not alive() then break end
                if v:IsA("BoolValue") and v.Value == false then
                    local preview = world:FindFirstChild(v.Name)
                    if preview then
                        pcall(function() purchase:InvokeServer(v, preview) end)
                        task.wait(0.1)
                        if v.Value == true then bought += 1 end
                    end
                end
            end
        end
    end
    S.itemsBought += bought
    return { bought = bought }
end

-- ================= DETAILED ESP =================

local tycoonLabels = {}
local function clearTycoonEsp()
    for _, l in pairs(tycoonLabels) do
        if l and l.Parent then l.Parent:Destroy() end
    end
    tycoonLabels = {}
end

local function espTextFor(ty)
    local info = ty:FindFirstChild("Info")
    if not info then return nil, false end
    local owner = info:FindFirstChild("Owner")
    local money = info:FindFirstChild("Money")
    local tier = info:FindFirstChild("TycoonBuilding")
    local games = info:FindFirstChild("Games")
    local maxGames = info:FindFirstChild("MaxGames")
    local rating = info:FindFirstChild("Rating")
    local open = info:FindFirstChild("Open")
    local emps = ty:FindFirstChild("Employees")

    local isMine = owner and owner.Value == LP.Name
    local lines = {}
    lines[1] = (owner and owner.Value or "?") .. (isMine and "  [YOU]" or "")
    lines[2] = "$" .. comma(money and money.Value or 0)
    lines[3] = "Tier " .. (tier and tier.Value or "?")
        .. "  |  Games " .. (games and games.Value or "?") .. "/" .. (maxGames and maxGames.Value or "?")
    lines[4] = "Rating " .. string.format("%.2f", (rating and rating.Value or 0))
        .. "  |  Staff " .. (emps and #emps:GetChildren() or 0)
        .. "  |  " .. ((open and open.Value) and "OPEN" or "CLOSED")
    return table.concat(lines, "\n"), isMine
end

-- ================= LIGHTING =================

local lightingSaved = nil
local function applyLighting()
    if S.fpsBoost and not lightingSaved then
        lightingSaved = { shadows = Lighting.GlobalShadows, brightness = Lighting.Brightness }
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

-- ================= UI =================

local Window = WindUI:CreateWindow({
    Title = "Game Store Tycoon Hub",
    Icon = "store",
    Author = "v12.0 omega",
    Folder = "GameStoreTycoonHub",
    Size = UDim2.fromOffset(650, 590),
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
    Desc = "Everything: 7+3 free team, all automations, cap-guarded money engine, save guard, auto-rejoin, anti-AFK. Survives rejoins.",
    Icon = "rocket",
    Value = false, Flag = "master_god",
    Callback = function(v)
        S.autoRegister = v
        S.autoRestock = v
        S.autoDelivery = v
        S.autoRobber = v
        S.autoTeam = v
        S.autoFirePaid = v
        S.autoSave = v
        S.autoRejoin = v
        S.antiAfk = v
        if v then
            task.spawn(function()
                local hired = buildTeam()
                if hired > 0 then notify("Team", "+" .. hired .. " free staff", "users") end
            end)
        end
        notify("God Mode", v and "Engaged - the empire runs itself" or "Disabled", "rocket")
    end,
})

local MB = sect(TabMain, "Automation")
local statsPara = MB:Paragraph({ Title = "Live Stats", Desc = "warming up..." })

MB:Toggle({ Title = "Instant Register", Desc = "Serves queues the moment they change",
    Value = false, Flag = "auto_register", Callback = function(v) S.autoRegister = v end })
MB:Toggle({ Title = "Auto Restock", Value = false, Flag = "auto_restock",
    Callback = function(v) S.autoRestock = v end })
MB:Slider({ Title = "Restock Delay (s)", Value = { Min = 1, Max = 10, Default = 2 },
    Flag = "restock_delay", Callback = function(v) S.restockDelay = v end })
MB:Toggle({ Title = "Auto Delivery", Value = false, Flag = "auto_delivery",
    Callback = function(v) S.autoDelivery = v end })
MB:Toggle({ Title = "Auto Catch Robbers", Desc = "Full capture sequence - no frozen bodies",
    Value = false, Flag = "auto_robber", Callback = function(v) S.autoRobber = v end })

-- ------ TAB: TEAM ------

local TabStaff = Window:Tab({ Title = "Team", Icon = "users", IconColor = Color3.fromHex("#a78bfa") })
local SA = sect(TabStaff, "Wage Control")

SA:Slider({
    Title = "Employee Wage ($/min)",
    Desc = "0 = free forever. Negative = REVERSE WAGES (experimental - they may pay you). Positive = you pay them.",
    Value = { Min = -10000, Max = 10000, Default = 0, Step = 250 },
    Flag = "hire_wage",
    Callback = function(v) S.hireWage = v end,
})

SA:Button({
    Title = "Build Team NOW (7 Reg + 3 Del)",
    Desc = "Hires exactly what's missing at your wage setting",
    Icon = "users",
    Callback = function()
        task.spawn(function()
            local hired = buildTeam()
            forceSave()
            notify("Team", "Team built (+" .. hired .. ") at " .. comma(S.hireWage) .. "$/min - saved", "users")
        end)
    end,
})

SA:Toggle({ Title = "Auto Team Keeper", Desc = "Maintains the 7+3 team around the clock",
    Value = false, Flag = "auto_team",
    Callback = function(v)
        S.autoTeam = v
        if v then task.spawn(function() buildTeam() end) end
    end })

SA:Button({
    Title = "NEGATIVE WAGE TEAM (experimental)",
    Desc = "Rebuilds everyone at -1000 $/min - employees may pay YOU. Unproven; fire them if money acts odd.",
    Icon = "flask-conical",
    Callback = function()
        task.spawn(function()
            fireEveryone()
            task.wait(1)
            local h1 = hireManyWaged(2, 7, -1000)
            local h2 = hireManyWaged(4, 3, -1000)
            forceSave()
            notify("Experiment", "Negative team: " .. (h1 + h2) .. " hired at -1000$/min", "flask-conical")
        end)
    end,
})

local SB = sect(TabStaff, "Manual Hire")

local hireJob = 2
SB:Dropdown({
    Title = "Job Type",
    Values = { "Register", "Restocker", "Delivery", "Security" },
    Value = "Register",
    Callback = function(sel)
        hireJob = ({ Register = 2, Restocker = 3, Delivery = 4, Security = 5 })[sel] or 2
    end,
})
local hireCountRef = 1
SB:Slider({ Title = "Count", Value = { Min = 1, Max = 100, Default = 1 },
    Callback = function(v) hireCountRef = v end })
SB:Button({ Title = "Hire Selected", Icon = "user-plus", Callback = function()
    task.spawn(function()
        local n = hireManyWaged(hireJob, hireCountRef, S.hireWage)
        forceSave()
        notify("Hiring", "Hired " .. n .. " at " .. comma(S.hireWage) .. "$/min", "user-plus")
    end)
end })

local SC = sect(TabStaff, "Cleanup")

SC:Button({ Title = "Fire ALL Paid Staff NOW", Desc = "Every wage-leech - gone",
    Icon = "user-minus", Callback = function()
        task.spawn(function()
            local n = fireAllPaid()
            forceSave()
            notify("Cleanup", "Fired " .. n .. " paid - saved", "user-minus")
        end)
    end })
SC:Button({ Title = "Fire EVERYONE (reset team)", Icon = "trash-2", Callback = function()
    task.spawn(function()
        local n = fireEveryone()
        notify("Team", "Fired " .. n, "trash-2")
    end)
end })
SC:Toggle({ Title = "Auto Fire Paid Staff", Value = false, Flag = "auto_fire_paid",
    Callback = function(v)
        S.autoFirePaid = v
        if v then
            task.spawn(function()
                local n = fireAllPaid()
                if n > 0 then notify("Cleanup", "Fired " .. n, "user-minus") end
            end)
        end
    end })

-- ------ TAB: UPGRADES ------

local TabUp = Window:Tab({ Title = "Upgrades", Icon = "trending-up", IconColor = Color3.fromHex("#4ade80") })
local UA = sect(TabUp, "Store")

UA:Button({
    Title = "MAX BUILDING TIER",
    Desc = "One touch to the top tier - instant if already max",
    Icon = "crown",
    Callback = function()
        task.spawn(function()
            notify("Max Tier", "Upgrading...", "crown")
            local tiers = upgradeToMax()
            local t = myTycoon()
            local tier = t and t.Info:FindFirstChild("TycoonBuilding")
            tier = tier and tier.Value or "?"
            if tiers > 0 then
                notify("Max Tier", "Reached tier " .. tier, "crown")
            else
                notify("Max Tier", "Already maxed - tier " .. tier, "crown")
            end
        end)
    end,
})

UA:Button({
    Title = "AUTO UPGRADE ALL",
    Desc = "Buys every unowned model, ad, register and building",
    Icon = "shopping-cart",
    Callback = function()
        task.spawn(function()
            notify("Upgrade All", "Buying everything...", "crown")
            local total = 0
            for _ = 1, 15 do
                if not alive() then break end
                local r = buyEverything()
                if not r or r.bought == 0 then break end
                total += r.bought
                task.wait(0.5)
            end
            forceSave()
            notify("Upgrade All", "Bought " .. total .. " items - saved", "crown")
        end)
    end,
})

UA:Button({ Title = "Force Save NOW", Icon = "save", Callback = function()
    if forceSave() then notify("Save", "Progress banked", "save") end
end })

-- ------ TAB: MONEY ------

local TabMoney = Window:Tab({ Title = "Money", Icon = "banknote", IconColor = Color3.fromHex("#4ade80") })
local MC = sect(TabMoney, "Instant Cash (cap-guarded)")

MC:Button({ Title = "+$10,000", Icon = "banknote", Callback = function()
    if addMoney(10000) then notify("Money", "+$10,000", "banknote") end
end })
MC:Button({ Title = "+$100,000", Icon = "banknote", Callback = function()
    if addMoney(100000) then notify("Money", "+$100,000", "banknote") end
end })
MC:Button({ Title = "+$1,000,000", Icon = "banknote", Callback = function()
    if addMoney(1000000) then notify("Money", "+$1,000,000", "banknote") end
end })
MC:Button({ Title = "+$10,000,000", Icon = "banknote", Callback = function()
    if addMoney(10000000) then notify("Money", "+$10,000,000", "banknote") end
end })

MC:Button({
    Title = "MONEY CANNON",
    Desc = "Rapid burst of 20 payments at your drip amount - every shot cap-checked",
    Icon = "zap",
    Callback = function()
        task.spawn(function()
            notify("Cannon", "Firing...", "zap")
            local fired = 0
            for _ = 1, 20 do
                if not alive() then break end
                if addMoney(S.moneyAmount) then
                    fired += 1
                else
                    break
                end
                task.wait(0.1)
            end
            forceSave()
            notify("Cannon", fired .. " shots landed - saved", "zap")
        end)
    end,
})

local MD = sect(TabMoney, "Auto Money Drip")

MD:Toggle({ Title = "Auto Money Drip", Desc = "Cap-guarded: pauses at $950M, never lets you hit the $1B reset",
    Value = false, Flag = "auto_money",
    Callback = function(v)
        S.autoMoney = v
        S.capNotified = false
    end })
MD:Slider({ Title = "Amount per tick", Value = { Min = 1000, Max = 10000000, Default = 10000, Step = 1000 },
    Flag = "money_amount", Callback = function(v) S.moneyAmount = v end })
MD:Slider({ Title = "Delay (s)", Value = { Min = 0.01, Max = 60, Default = 5, Step = 0.01 },
    Flag = "money_delay", Callback = function(v) S.moneyDelay = v end })

local ME = sect(TabMoney, "Guards")

ME:Toggle({ Title = "Auto Save", Desc = "Banks progress - a reset only costs the tail",
    Value = true, Flag = "auto_save",
    Callback = function(v) S.autoSave = v end })
ME:Slider({ Title = "Save Interval (s)", Value = { Min = 30, Max = 600, Default = 120 },
    Flag = "save_delay", Callback = function(v) S.saveDelay = v end })

-- ------ TAB: VISUALS ------

local TabVis = Window:Tab({ Title = "Visuals", Icon = "eye", IconColor = Color3.fromHex("#7dd87d") })
local VA = sect(TabVis, "World")

VA:Toggle({ Title = "Detailed Tycoon ESP", Desc = "Owner, money, tier, games, rating, staff, open/closed - yours in green",
    Value = false, Flag = "esp_tycoons",
    Callback = function(v) S.espTycoons = v; if not v then clearTycoonEsp() end end })
VA:Slider({ Title = "ESP Range", Value = { Min = 100, Max = 1500, Default = 500 },
    Flag = "esp_range", Callback = function(v) S.espRange = v end })

local VB = sect(TabVis, "Client")

VB:Toggle({ Title = "FPS Boost", Desc = "Shadows + post-effects off",
    Value = false, Flag = "gfx_fps",
    Callback = function(v) S.fpsBoost = v; applyLighting() end })

-- ------ TAB: OVERNIGHT ------

local TabNight = Window:Tab({ Title = "Overnight", Icon = "moon", IconColor = Color3.fromHex("#a78bfa") })
local NA = sect(TabNight, "Unattended Operation")

NA:Paragraph({ Title = "How it works", Desc = "GOD MODE saves its state. If this file is in Real's AutoExec folder, the hub reloads itself on every join - so after an auto-rejoin, the empire resumes automatically." })

NA:Toggle({ Title = "Auto Rejoin on Data Loss", Desc = "If the server dies or you get dropped, rejoin automatically",
    Value = true, Flag = "auto_rejoin",
    Callback = function(v) S.autoRejoin = v end })

NA:Toggle({ Title = "Anti-AFK", Desc = "Silent - keeps the connection alive forever",
    Value = true, Flag = "ut_afk",
    Callback = function(v) S.antiAfk = v end })

NA:Button({ Title = "Rejoin Server NOW", Icon = "refresh-cw", Callback = function()
    TS:Teleport(game.PlaceId, LP)
end })

-- ------ TAB: MISC ------

local TabMisc = Window:Tab({ Title = "Misc", Icon = "ellipsis", IconColor = Color3.fromHex("#94a3b8") })
local MS = sect(TabMisc, "Utility")

MS:Button({ Title = "Teleport to My Store", Icon = "map-pin", Callback = function()
    local t = myTycoon()
    if t then
        local anchor = lotAnchor(t)
        local hrp = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
        if anchor and hrp then
            hrp.CFrame = CFrame.new(anchor.Position + Vector3.new(0, 10, 0))
        end
    end
end })

TabMisc:Paragraph({ Title = "Info", Desc = "K - toggle menu\nAll settings persist between sessions and rejoins.\nGOD MODE = the entire empire in one switch." })

-- ================= CORE LOOPS =================

-- register watcher
task.spawn(function()
    while alive() do
        if S.autoRegister then
            local t = myTycoon()
            if t then
                for n = 1, 7 do
                    local size = queueSize(t, n)
                    local last = lastQueueN[n] or 0
                    if size > 0 and size ~= last then
                        serveRegister(n)
                        task.wait(0.5)
                        serveRegister(n)
                    end
                    lastQueueN[n] = size
                end
            end
        end
        task.wait(1)
    end
end)

-- delivery + robber + restock + team + paid sweep
task.spawn(function()
    local restockAcc = 0
    local teamAcc = 0
    local paidAcc = 0
    while alive() do
        local t = myTycoon()
        if t then
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
                    local lot = t.Info and t.Info:FindFirstChild("Lot")
                    lot = lot and lot.Value
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

            if S.autoRobber then
                safe(function()
                    for _, v in ipairs(t:GetChildren()) do
                        if v:IsA("Folder") and v:FindFirstChild("CaptureFn")
                            and v:FindFirstChild("Captured") and not v.Captured.Value then
                            task.spawn(captureRobber, v)
                        end
                    end
                end)
            end

            restockAcc += 1
            if S.autoRestock and restockAcc >= math.max(S.restockDelay, 1) then
                restockAcc = 0
                local ft = myTycoon()
                local restockR = ft and ctrlRemote(ft, "Restock")
                local updateR = ft and ctrlRemote(ft, "Update")
                if ft and restockR and updateR then
                    local empties = emptyGames(ft)
                    if #empties > 0 then
                        for _, g in ipairs(empties) do
                            safe(function() restockR:FireServer(g) end)
                        end
                        safe(function() updateR:FireServer() end)
                        S.standsRestocked += #empties
                    end
                end
            end

            teamAcc += 1
            if S.autoTeam and teamAcc >= 30 then
                teamAcc = 0
                local counts = teamCounts(t)
                if (counts[2] < 7) or (counts[4] < 3) then
                    task.spawn(buildTeam)
                end
            end

            paidAcc += 1
            if S.autoFirePaid and paidAcc >= 80 then
                paidAcc = 0
                fireAllPaid()
            end
        end
        task.wait(0.75)
    end
end)

-- money drip + auto-save (cap-guarded)
task.spawn(function()
    local saveAcc = 0
    while alive() do
        if S.autoMoney then
            safe(function() addMoney(S.moneyAmount) end)
        end
        saveAcc += 1
        if S.autoSave and saveAcc >= math.max(S.saveDelay, 30) then
            saveAcc = 0
            forceSave()
        end
        task.wait(math.max(S.moneyDelay, 0.01))
    end
end)

-- detailed ESP
task.spawn(function()
    while alive() do
        if S.espTycoons then
            safe(function()
                local myPos = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
                    and LP.Character.HumanoidRootPart.Position
                if myPos then
                    for _, ty in ipairs(WS.Tycoons:GetChildren()) do
                        local anchor = lotAnchor(ty)
                        if anchor and (anchor.Position - myPos).Magnitude <= S.espRange then
                            local label = tycoonLabels[ty]
                            if not label or not label.Parent then
                                local bg = Instance.new("BillboardGui")
                                bg.Size = UDim2.new(0, 230, 0, 80)
                                bg.StudsOffset = Vector3.new(0, 14, 0)
                                bg.AlwaysOnTop = true
                                bg.Adornee = anchor
                                bg.Parent = anchor
                                local tl = Instance.new("TextLabel")
                                tl.Size = UDim2.new(1, 0, 1, 0)
                                tl.BackgroundTransparency = 1
                                tl.TextStrokeTransparency = 0.3
                                tl.TextSize = 13
                                tl.Font = Enum.Font.GothamBold
                                tl.TextWrapped = true
                                tl.Parent = bg
                                tycoonLabels[ty] = tl
                            end
                            local text, isMine = espTextFor(ty)
                            if text then
                                label.Text = text
                                label.TextColor3 = isMine
                                    and Color3.fromRGB(120, 220, 120)
                                    or Color3.fromRGB(235, 235, 235)
                            end
                        end
                    end
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

-- stats + earnings rate + cap-reset watchdog (per-second)
task.spawn(function()
    while alive() do
        local t = myTycoon()
        if t then
            local info = t:FindFirstChild("Info")
            local moneyV = info and info:FindFirstChild("Money")
            if moneyV then
                local m = moneyV.Value
                if S.lastM == nil then S.lastM = m end
                local d = m - S.lastM
                if d > 0 then
                    S.sessionEarn += d
                    S.earnLog[#S.earnLog + 1] = { t = os.clock(), d = d }
                end
                if m > S.peakMoney then S.peakMoney = m end

                -- cap-reset detector: money collapsed to near-zero from a high peak
                if S.peakMoney > 100e6 and m < 1000 then
                    S.autoMoney = false
                    notify("CAP RESET DETECTED", "Money hit the $1B cap and reset. Drip disabled - re-enable below the line.", "shield-off")
                    S.peakMoney = m
                end
                -- reset the notified flag once safely under ceiling
                if S.capNotified and m < SAFE_CEILING - 100e6 then
                    S.capNotified = false
                end
                S.lastM = m

                -- rolling 60s rate
                local now = os.clock()
                while #S.earnLog > 0 and now - S.earnLog[1].t > 60 do table.remove(S.earnLog, 1) end
                local rate = 0
                for _, e in ipairs(S.earnLog) do rate += e.d end

                local counts = teamCounts(t)
                local paid = 0
                local emps = t:FindFirstChild("Employees")
                if emps then
                    for _, e in ipairs(emps:GetChildren()) do
                        local c = e:FindFirstChild("Cost")
                        if c and c.Value > 0 then paid += 1 end
                    end
                end
                if statsPara then
                    safe(function()
                        statsPara:SetTitle("Live Stats")
                        statsPara:SetDesc(table.concat({
                            string.format("Money: $%s / $950M cap  (+$%s session)",
                                comma(m), comma(S.sessionEarn)),
                            string.format("Rate: $%s/min  |  Peak: $%s",
                                comma(rate), comma(S.peakMoney)),
                            string.format("Reg %d/7  Del %d/3  Paid %d  |  Tier %s  Games %d/%d",
                                counts[2], counts[4], paid,
                                tostring(info:FindFirstChild("TycoonBuilding") and info.TycoonBuilding.Value or "?"),
                                info.Games.Value, info.MaxGames.Value),
                            string.format("Orders %d  Trucks %d  Robbers %d  Restocks %d",
                                S.regTaken, S.trucksUnloaded, S.robbersCaught, S.standsRestocked),
                            string.format("Hired %d  Fired %d  Bought %d  Saves %d",
                                S.hiredStaff, S.paidFired, S.itemsBought, S.savesFired),
                        }, "\n"))
                    end)
                end
            end
        end
        task.wait(1)
    end
end)

-- OVERNIGHT WATCHDOG: data-loss rejoin (30s tick)
task.spawn(function()
    local lossStreak = 0
    while alive() do
        local t = myTycoon()
        if t then
            lossStreak = 0
        else
            lossStreak += 1
            if S.autoRejoin and lossStreak >= 3 then
                notify("Overnight", "Data loss - rejoining server...", "refresh-cw")
                task.wait(2)
                TS:Teleport(game.PlaceId, LP)
                lossStreak = 0
            end
        end
        task.wait(30)
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

notify("Game Store Tycoon Hub", "v12.0 omega loaded - press K", "store")
print("[GST Hub v12.0] Loaded")
