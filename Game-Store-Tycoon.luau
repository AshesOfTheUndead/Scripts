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
    autoStaff = false,
    autoMoney = false, moneyAmount = 10000, moneyDelay = 5,
    antiAfk = true,
    fpsBoost = false,

    regTaken = 0, trucksUnloaded = 0, robbersCaught = 0, standsRestocked = 0,
    hiredStaff = 0, itemsBought = 0, sessionEarn = 0,
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

-- ================= FREE WORKFORCE =================
-- newemp with Cost=0: verified live - Cost:0 Job:2 employee, no wage.

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
            Cost = 0,                                  -- FREE FOREVER
            Color = template.Appearance.Color.Value,   -- BodyColors inst
            Hair = template.Appearance.Hair.Value,     -- Accessory inst
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

-- ================= BUY EVERYTHING =================

local function buyEverything()
    local t = myTycoon()
    if not t then return { bought = 0 } end
    local info = t:FindFirstChild("Info")
    local purchase = ctrlRemote(t, "PurchaseModel")
    if not (info and purchase) then return { bought = 0 } end

    local bought = 0
    for _, cat in ipairs({ "Models", "AdModels", "RegisterModels", "BuildingModels" }) do
        local folder = info:FindFirstChild(cat)
        if folder then
            for _, v in ipairs(folder:GetChildren()) do
                if not alive() then break end
                if v:IsA("BoolValue") and v.Value == false then
                    pcall(function() purchase:InvokeServer(v, nil) end)
                    task.wait(0.2)
                    if v.Value == true then bought += 1 end
                end
            end
        end
    end
    local up = ctrlRemote(t, "Upgrade")
    if up then safe(function() up:FireServer() end) end
    S.itemsBought += bought
    return { bought = bought }
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
    Author = "v8.0 divine",
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
    Desc = "Register + restock + delivery + robbers + staff keeper + anti-AFK. Store runs itself, you explore freely.",
    Icon = "rocket",
    Value = false, Flag = "master_god",
    Callback = function(v)
        S.autoRegister = v
        S.autoRestock = v
        S.autoDelivery = v
        S.autoRobber = v
        S.autoStaff = v
        S.antiAfk = v
        notify("God Mode", v and "Engaged" or "Disabled", "rocket")
    end,
})

local MB = sect(TabMain, "Automation")
local statsPara = MB:Paragraph({ Title = "Live Stats", Desc = "warming up..." })

MB:Toggle({ Title = "Instant Register", Desc = "Serves queues the moment they change, at the server's pace",
    Value = false, Flag = "auto_register", Callback = function(v) S.autoRegister = v end })
MB:Toggle({ Title = "Auto Restock", Value = false, Flag = "auto_restock",
    Callback = function(v) S.autoRestock = v end })
MB:Slider({ Title = "Restock Delay (s)", Value = { Min = 1, Max = 10, Default = 2 },
    Flag = "restock_delay", Callback = function(v) S.restockDelay = v end })
MB:Toggle({ Title = "Auto Delivery", Value = false, Flag = "auto_delivery",
    Callback = function(v) S.autoDelivery = v end })
MB:Toggle({ Title = "Auto Catch Robbers", Value = false, Flag = "auto_robber",
    Callback = function(v) S.autoRobber = v end })

-- ------ TAB: STAFF ------

local TabStaff = Window:Tab({ Title = "Staff", Icon = "users", IconColor = Color3.fromHex("#a78bfa") })
local SA = sect(TabStaff, "Free Unlimited Employees")

SA:Paragraph({ Title = "Verified", Desc = "Wages are the Cost YOU send in the hire call - v8 sends 0. Server has no count cap. Free army." })

SA:Button({
    Title = "Hire 20 of EVERY Job - FREE",
    Desc = "80 employees at $0/min: 20 register + 20 restocker + 20 delivery + 20 security",
    Icon = "crown",
    Callback = function()
        task.spawn(function()
            notify("Hiring", "80 FREE employees incoming...", "users")
            local total = 0
            for job = 2, 5 do
                total += hireFreeMany(job, 20)
            end
            notify("Hiring", "Hired " .. total .. "/80 - all $0/min", "users")
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
        notify("Hiring", hireCountRef .. " x " .. (JOB_NAMES[hireJob] or "?") .. " ($0/min)", "user-plus")
        local n = hireFreeMany(hireJob, hireCountRef)
        notify("Hiring", "Hired " .. n .. " at $0/min", "user-plus")
    end)
end })

SA:Toggle({ Title = "Auto Staff Keeper", Desc = "Re-hires free staff if the count drops", Value = false, Flag = "auto_staff",
    Callback = function(v) S.autoStaff = v end })

-- ------ TAB: UPGRADES ------

local TabUp = Window:Tab({ Title = "Upgrades", Icon = "trending-up", IconColor = Color3.fromHex("#4ade80") })
local UA = sect(TabUp, "Store")

UA:Button({
    Title = "AUTO UPGRADE ALL",
    Desc = "Buys every unowned model, ad, register and building - verified per purchase.",
    Icon = "crown",
    Callback = function()
        task.spawn(function()
            notify("Upgrade All", "Buying everything...", "crown")
            local total = 0
            for _ = 1, 10 do
                if not alive() then break end
                local r = buyEverything()
                if not r or r.bought == 0 then break end
                total += r.bought
                task.wait(1)
            end
            notify("Upgrade All", "Bought " .. total .. " items", "crown")
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

local MD = sect(TabMoney, "Auto Money Drip")

MD:Toggle({ Title = "Auto Money Drip", Value = false, Flag = "auto_money",
    Callback = function(v) S.autoMoney = v end })
MD:Slider({ Title = "Amount per tick", Value = { Min = 1000, Max = 1000000, Default = 10000, Step = 1000 },
    Flag = "money_amount", Callback = function(v) S.moneyAmount = v end })
MD:Slider({ Title = "Delay (s)", Value = { Min = 0.01, Max = 60, Default = 5, Step = 0.01 },
    Flag = "money_delay", Callback = function(v) S.moneyDelay = v end })
MD:Paragraph({ Title = "Caution", Desc = "1M @ 0.01s = $60M/s. Anticheat reverts saves on huge single calls; if money snaps backwards, slow the drip." })

-- ------ TAB: MISC ------

local TabMisc = Window:Tab({ Title = "Misc", Icon = "ellipsis", IconColor = Color3.fromHex("#94a3b8") })
local MS = sect(TabMisc, "Utility")

MS:Toggle({ Title = "Anti-AFK", Value = true, Flag = "ut_afk",
    Callback = function(v) S.antiAfk = v end })
MS:Toggle({ Title = "FPS Boost", Value = false, Flag = "gfx_fps",
    Callback = function(v) S.fpsBoost = v; applyLighting() end })
MS:Button({ Title = "Rejoin Server", Icon = "refresh-cw", Callback = function() TS:Teleport(game.PlaceId, LP) end })

TabMisc:Paragraph({ Title = "Info", Desc = "K - toggle menu\nSettings save between sessions." })

-- ================= CORE LOOPS =================

-- register watchers
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

-- delivery + robber + restock
task.spawn(function()
    local restockAcc = 0
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
                            pcall(function() v.CaptureFn:Invoke() end)
                            S.robbersCaught += 1
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
        end
        task.wait(0.75)
    end
end)

-- staff keeper (free re-hires)
task.spawn(function()
    local acc = 0
    while alive() do
        acc += 1
        if S.autoStaff and acc >= 60 then
            acc = 0
            local t = myTycoon()
            local emps = t and t:FindFirstChild("Employees")
            if t and emps and #emps:GetChildren() < 10 then
                hireFree(2)
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
        task.wait(math.max(S.moneyDelay, 0.01))
    end
end)

-- stats
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
                    if lastM == nil then lastM = moneyV.Value end
                    if moneyV.Value > lastM then
                        S.sessionEarn += moneyV.Value - lastM
                    end
                    lastM = moneyV.Value
                    safe(function()
                        statsPara:SetTitle("Live Stats")
                        statsPara:SetDesc(table.concat({
                            string.format("Money: $%s  (+$%s session)",
                                comma(moneyV.Value), comma(S.sessionEarn)),
                            string.format("Employees: %d  |  Games: %d/%d  |  Bldg: %d",
                                emps and #emps:GetChildren() or 0,
                                info.Games.Value, info.MaxGames.Value, info.Building.Value),
                            string.format("Orders: %d  Trucks: %d  Robbers: %d  Restocks: %d",
                                S.regTaken, S.trucksUnloaded, S.robbersCaught, S.standsRestocked),
                            string.format("Hired: %d  |  Bought: %d",
                                S.hiredStaff, S.itemsBought),
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
    STATE.onCleanup(function() end)
end

notify("Game Store Tycoon Hub", "v8.0 divine loaded - press K", "store")
print("[GST Hub v8.0] Loaded")
