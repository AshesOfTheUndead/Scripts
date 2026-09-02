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
    autoRegister = false,
    autoRestock = false, restockDelay = 2,
    autoDelivery = false,
    autoRobber = false,
    autoStaff = false, staffTarget = 30,
    autoFirePaid = false,
    autoMoney = false, moneyAmount = 10000, moneyDelay = 5,
    autoSave = true, saveDelay = 120,
    antiAfk = true,
    fpsBoost = false,
    espTycoons = false, espRange = 400,

    regTaken = 0, trucksUnloaded = 0, robbersCaught = 0, standsRestocked = 0,
    hiredStaff = 0, itemsBought = 0, sessionEarn = 0, savesFired = 0,
    paidFired = 0, peakMoney = 0,
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

local function addMoney(amount)
    local t = myTycoon()
    if not t then return false end
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

-- lot anchor: Lot.Value IS the Part (v9 searched children - the bug)
local function lotAnchor(t)
    local info = t:FindFirstChild("Info")
    local lot = info and info:FindFirstChild("Lot")
    local v = lot and lot.Value
    if v and v:IsA("BasePart") then
        return v
    end
    return nil
end

-- ================= FREE WORKFORCE =================

local JOB_NAMES = { [2] = "Register", [3] = "Restocker", [4] = "Delivery", [5] = "Security" }

local function hireFree(job)
    local t = myTycoon()
    if not t then return false end
    local template = RS:FindFirstChild("Employee")
    local newemp = WS:FindFirstChild("Events") and WS.Events:FindFirstChild("newemp")
    if not (template and newemp) then return false end
    local ok = pcall(function()
        newemp:InvokeServer(t, template, {
            Job = job,
            Nam = template.Nam.Value,
            Cost = 0,
            Color = template.Appearance.Color.Value,
            Hair = template.Appearance.Hair.Value,
        })
    end)
    if ok then S.hiredStaff += 1 end
    return ok
end

local function hireFreeMany(job, count)
    local hired = 0
    for _ = 1, count do
        if not alive() then break end
        if hireFree(job) then hired += 1 end
        task.wait(0.25)
    end
    return hired
end

-- fire one employee (paid leech removal)
local function fireEmployee(t, empFolder)
    local fireemp = WS:FindFirstChild("Events") and WS.Events:FindFirstChild("fireemp")
    if not fireemp then return false end
    local ok = pcall(function()
        fireemp:FireServer(t, empFolder)
    end)
    if ok then S.paidFired += 1 end
    return ok
end

-- fire every PAID employee (Cost > 0)
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

-- ================= ROBBERS (full game sequence) =================
-- UncoverFn reveals + cuffs + sirens (Job=98), CaptureFn pays the
-- bounty AND fades + destroys the body ~7s later. The full sequence
-- leaves NOTHING frozen - v9's CaptureFn-only calls did.

local function captureRobber(folder)
    local ok1 = pcall(function() folder.UncoverFn:Invoke() end)
    task.wait(0.5)
    local ok2 = pcall(function() folder.CaptureFn:Invoke() end)
    if ok1 or ok2 then S.robbersCaught += 1 end
    return ok1 and ok2
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
    local up = ctrlRemote(t, "Upgrade")
    if up then safe(function() up:FireServer() end) end
    S.itemsBought += bought
    return { bought = bought }
end

-- ================= ESP =================

local tycoonLabels = {}
local function clearTycoonEsp()
    for _, l in pairs(tycoonLabels) do
        if l and l.Parent then l.Parent:Destroy() end
    end
    tycoonLabels = {}
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
    Author = "v10.0 apex",
    Folder = "GameStoreTycoonHub",
    Size = UDim2.fromOffset(640, 580),
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
    Desc = "Everything + auto-save + auto-fire paid staff + anti-AFK. The store runs itself forever.",
    Icon = "rocket",
    Value = false, Flag = "master_god",
    Callback = function(v)
        S.autoRegister = v
        S.autoRestock = v
        S.autoDelivery = v
        S.autoRobber = v
        S.autoStaff = v
        S.autoFirePaid = v
        S.autoSave = v
        S.antiAfk = v
        notify("God Mode", v and "Engaged - apex mode" or "Disabled", "rocket")
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
MB:Toggle({ Title = "Auto Catch Robbers", Desc = "Full capture sequence - reveals, cuffs, bounty, fade-out. No frozen bodies.",
    Value = false, Flag = "auto_robber", Callback = function(v) S.autoRobber = v end })

-- ------ TAB: STAFF ------

local TabStaff = Window:Tab({ Title = "Staff", Icon = "users", IconColor = Color3.fromHex("#a78bfa") })
local SA = sect(TabStaff, "Free Unlimited Employees")

SA:Paragraph({ Title = "Verified", Desc = "Wages are the Cost YOU send - v10 sends 0. No server cap. Free forever." })

SA:Button({
    Title = "Hire 20 of EVERY Job - FREE",
    Desc = "80 employees at $0/min",
    Icon = "crown",
    Callback = function()
        task.spawn(function()
            notify("Hiring", "80 FREE employees incoming...", "users")
            local total = 0
            for job = 2, 5 do
                total += hireFreeMany(job, 20)
            end
            forceSave()
            notify("Hiring", "Hired " .. total .. "/80 - saved", "users")
        end)
    end,
})

local SB = sect(TabStaff, "Manual Hire (free)")

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
SB:Button({ Title = "Hire Selected - FREE", Icon = "user-plus", Callback = function()
    task.spawn(function()
        local n = hireFreeMany(hireJob, hireCountRef)
        forceSave()
        notify("Hiring", "Hired " .. n .. " at $0/min - saved", "user-plus")
    end)
end })

local SC = sect(TabStaff, "Army Keeper + Leech Cleanup")

SC:Toggle({ Title = "Auto Staff Keeper", Desc = "Re-hires free staff to hold the target", Value = false, Flag = "auto_staff",
    Callback = function(v) S.autoStaff = v end })
SC:Slider({ Title = "Staff Target Count", Value = { Min = 5, Max = 200, Default = 30 },
    Flag = "staff_target", Callback = function(v) S.staffTarget = v end })
SC:Toggle({ Title = "Auto Fire PAID Staff", Desc = "Removes any employee charging wages (Cost > 0)",
    Value = false, Flag = "auto_fire_paid",
    Callback = function(v)
        S.autoFirePaid = v
        if v then
            task.spawn(function()
                local n = fireAllPaid()
                if n > 0 then notify("Cleanup", "Fired " .. n .. " paid leeches", "user-minus") end
            end)
        end
    end })
SC:Button({ Title = "Fire ALL Paid Staff NOW", Desc = "One click - kills every wage on the books",
    Icon = "user-minus", Callback = function()
        task.spawn(function()
            local n = fireAllPaid()
            forceSave()
            notify("Cleanup", "Fired " .. n .. " paid employees - saved", "user-minus")
        end)
    end })

-- ------ TAB: UPGRADES ------

local TabUp = Window:Tab({ Title = "Upgrades", Icon = "trending-up", IconColor = Color3.fromHex("#4ade80") })
local UA = sect(TabUp, "Store")

UA:Button({
    Title = "AUTO UPGRADE ALL",
    Desc = "Buys every unowned model, ad, register and building - verified signature",
    Icon = "crown",
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
            notify("Upgrade All", "Bought " .. total .. " - store maxed & saved", "crown")
        end)
    end,
})
UA:Button({ Title = "Upgrade Building Tier", Icon = "arrow-up-circle", Callback = function()
    local t = myTycoon()
    if t then
        local u = ctrlRemote(t, "Upgrade")
        if u then safe(function() u:FireServer() end) end
    end
end })
UA:Button({ Title = "Force Save NOW", Desc = "Banks all progress", Icon = "save", Callback = function()
    if forceSave() then notify("Save", "Progress banked", "save") end
end })

-- ------ TAB: MONEY ------

local TabMoney = Window:Tab({ Title = "Money", Icon = "banknote", IconColor = Color3.fromHex("#4ade80") })
local MC = sect(TabMoney, "Instant Cash")

MC:Button({ Title = "+$10,000", Icon = "banknote", Callback = function()
    if addMoney(10000) then notify("Money", "+$10,000", "banknote") end
end })
MC:Button({ Title = "+$100,000", Icon = "banknote", Callback = function()
    if addMoney(100000) then notify("Money", "+$100,000", "banknote") end
end })
MC:Button({ Title = "+$1,000,000", Icon = "banknote", Callback = function()
    if addMoney(1000000) then notify("Money", "+$1,000,000", "banknote") end
end })
MC:Button({ Title = "+$1M and Save", Icon = "save", Callback = function()
    if addMoney(1000000) then
        task.wait(0.5)
        forceSave()
        notify("Money", "+$1M banked", "save")
    end
end })

local MD = sect(TabMoney, "Auto Money Drip")

MD:Toggle({ Title = "Auto Money Drip", Value = false, Flag = "auto_money",
    Callback = function(v) S.autoMoney = v end })
MD:Slider({ Title = "Amount per tick", Value = { Min = 1000, Max = 1000000, Default = 10000, Step = 1000 },
    Flag = "money_amount", Callback = function(v) S.moneyAmount = v end })
MD:Slider({ Title = "Delay (s)", Value = { Min = 0.01, Max = 60, Default = 5, Step = 0.01 },
    Flag = "money_delay", Callback = function(v) S.moneyDelay = v end })

local ME = sect(TabMoney, "Auto Save Guard")

ME:Toggle({ Title = "Auto Save", Desc = "Banks progress periodically - reverts only cost the tail",
    Value = true, Flag = "auto_save",
    Callback = function(v) S.autoSave = v end })
ME:Slider({ Title = "Save Interval (s)", Value = { Min = 30, Max = 600, Default = 120 },
    Flag = "save_delay", Callback = function(v) S.saveDelay = v end })

-- ------ TAB: VISUALS ------

local TabVis = Window:Tab({ Title = "Visuals", Icon = "eye", IconColor = Color3.fromHex("#7dd87d") })
local VA = sect(TabVis, "World")

VA:Toggle({ Title = "Tycoon ESP", Desc = "Owner + money over every store (fixed: labels adorn the Lot Part directly)",
    Value = false, Flag = "esp_tycoons",
    Callback = function(v) S.espTycoons = v; if not v then clearTycoonEsp() end end })
VA:Slider({ Title = "ESP Range", Value = { Min = 100, Max = 1000, Default = 400 },
    Flag = "esp_range", Callback = function(v) S.espRange = v end })

local VB = sect(TabVis, "Client")

VB:Toggle({ Title = "FPS Boost", Desc = "Shadows + post-effects off (recommended with 90+ staff)",
    Value = false, Flag = "gfx_fps",
    Callback = function(v) S.fpsBoost = v; applyLighting() end })

-- ------ TAB: MISC ------

local TabMisc = Window:Tab({ Title = "Misc", Icon = "ellipsis", IconColor = Color3.fromHex("#94a3b8") })
local MS = sect(TabMisc, "Utility")

MS:Toggle({ Title = "Anti-AFK", Value = true, Flag = "ut_afk",
    Callback = function(v) S.antiAfk = v end })
MS:Button({ Title = "Teleport to My Store", Icon = "map-pin", Callback = function()
    local t = myTycoon()
    if t then
        local anchor = lotAnchor(t)
        local hrp = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
        if anchor and hrp then
            hrp.CFrame = CFrame.new(anchor.Position + Vector3.new(0, 10, 0))
            notify("Teleport", "At your store", "map-pin")
        end
    end
end })
MS:Button({ Title = "Rejoin Server", Icon = "refresh-cw", Callback = function() TS:Teleport(game.PlaceId, LP) end })

TabMisc:Paragraph({ Title = "Info", Desc = "K - toggle menu\nAll settings persist.\nGOD MODE = the whole empire in one switch." })

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

-- delivery + robber + restock + paid-staff cleanup
task.spawn(function()
    local restockAcc = 0
    local paidCheck = 0
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

            -- paid-staff sweep every ~60s
            paidCheck += 1
            if S.autoFirePaid and paidCheck >= 80 then
                paidCheck = 0
                fireAllPaid()
            end
        end
        task.wait(0.75)
    end
end)

-- staff keeper
task.spawn(function()
    local acc = 0
    while alive() do
        acc += 1
        if S.autoStaff and acc >= 20 then
            acc = 0
            local t = myTycoon()
            local emps = t and t:FindFirstChild("Employees")
            local count = emps and #emps:GetChildren() or 0
            if t and count < S.staffTarget then
                local deficit = math.min(S.staffTarget - count, 10)
                for _ = 1, deficit do
                    hireFree(2)
                    task.wait(0.25)
                end
            end
        end
        task.wait(1)
    end
end)

-- money drip + auto-save
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

-- ESP loop (fixed anchor)
task.spawn(function()
    while alive() do
        if S.espTycoons then
            safe(function()
                local myPos = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
                    and LP.Character.HumanoidRootPart.Position
                if myPos then
                    for _, ty in ipairs(WS.Tycoons:GetChildren()) do
                        local info = ty:FindFirstChild("Info")
                        local anchor = info and lotAnchor(ty)
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

-- stats (with free/paid breakdown)
task.spawn(function()
    local lastM = nil
    while alive() do
        local t = myTycoon()
        if t and statsPara then
            local info = t:FindFirstChild("Info")
            if info then
                local moneyV = info:FindFirstChild("Money")
                local emps = t:FindFirstChild("Employees")
                if moneyV then
                    local freeCount, paidCount = 0, 0
                    if emps then
                        for _, e in ipairs(emps:GetChildren()) do
                            local c = e:FindFirstChild("Cost")
                            if c and c.Value > 0 then
                                paidCount += 1
                            else
                                freeCount += 1
                            end
                        end
                    end
                    if lastM == nil then lastM = moneyV.Value end
                    if moneyV.Value > lastM then
                        S.sessionEarn += moneyV.Value - lastM
                    end
                    if moneyV.Value > S.peakMoney then S.peakMoney = moneyV.Value end
                    lastM = moneyV.Value
                    safe(function()
                        statsPara:SetTitle("Live Stats")
                        statsPara:SetDesc(table.concat({
                            string.format("Money: $%s  (+$%s session, peak $%s)",
                                comma(moneyV.Value), comma(S.sessionEarn), comma(S.peakMoney)),
                            string.format("Staff: %d free / %d PAID  |  Games: %d/%d  |  Bldg: %d",
                                freeCount, paidCount, info.Games.Value, info.MaxGames.Value, info.Building.Value),
                            string.format("Orders: %d  Trucks: %d  Robbers: %d  Restocks: %d",
                                S.regTaken, S.trucksUnloaded, S.robbersCaught, S.standsRestocked),
                            string.format("Hired: %d  Fired paid: %d  Bought: %d  Saves: %d",
                                S.hiredStaff, S.paidFired, S.itemsBought, S.savesFired),
                        }, "\n"))
                    end)
                end
            end
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

notify("Game Store Tycoon Hub", "v10.0 apex loaded - press K", "store")
print("[GST Hub v10.0] Loaded")
