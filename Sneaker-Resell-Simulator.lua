--!nocheck
--!nolint
-- ═══════════════════════════════════════════════════════════════════════════
-- SRS V7 · Single-boot script  (v3: sell-everything + smart walker)
--
-- The body is wrapped in bootScript() only to keep the top-level chunk tidy.
-- It boots exactly once per execution; no session-hop watcher, no re-run.
--
-- WHAT THIS SCRIPT DOES (section map, top to bottom)
--   Compat shims ........ fills in executor functions that are missing
--   SakuraUI loader ..... loads the window library (local file first, then GitHub)
--   Reload hygiene ...... a generation counter (srsAlive) makes every loop and
--                         event from an older execution stop itself
--   Speed tables ........ SPEED_CONFIG (buy/reload delays per speed tier) and
--                         DIG_SPEED_CONFIG (dig timings per tier)
--   Logger / saves ...... Log(), SRS_V4_Saves.json (settings), sidecar autostate
--   SmartWalkTo ......... the navigator: pathfinding + doors + gaps + ledges
--   Sell system ......... sellToNPC (walk to NPC), sell-bar listener (fires the
--                         Stop button inside the Perfect zone), adaptive latency
--                         controller, runSellCycle. Sells EVERY shoe, no rarity
--                         ordering, no "too few to bother" skip.
--   Buy system .......... runBuyCycle (single routine for every buying mode),
--                         shared buy-budget snapshot (Helpers.*Budget*)
--   Full Auto ........... buy -> sell -> re-snapshot budget -> repeat
--   Semi Auto / Risky / Human / PC pages / Macro / Do Everything / Shoe App
--   Auto Dig / Risky Dig  walking or teleporting treasure digger
--   Stability ........... anti-AFK, auto-reconnect, lag + stall watchdogs,
--                         render saver, optional GC sweep
--   Webhook / alerts .... Discord webhook, detections, periodic stats
--   Info tab ............ feature guide + logs
--
-- RULES OF THUMB
--   * Only ONE automation runs at a time; starting one stops the others
--     (cancelOtherAutomation).
--   * Buy Budget: money is snapshotted when a run starts; only purchases spend
--     it, so worker income can never extend a buy phase.
--   * bootScript() is near Luau's 200-local limit. Many helpers now live on the
--     local table __L (e.g. __L.Log). New helpers go on __L, the global Helpers
--     table, or inside do ... end blocks, never new top-level locals.
-- ═══════════════════════════════════════════════════════════════════════════
local function bootScript()
local __L = {} -- holds helpers moved off the 200-local limit
do
local executorName = (identifyexecutor and identifyexecutor()) or "Unknown"

local blockedExecutors = { "solara", "xeno", "yub-x", "yubx" }
local lowerExec = executorName:lower()
for _, blocked in ipairs(blockedExecutors) do
    if lowerExec:find(blocked, 1, true) then
        error("SRS V7: Executor '" .. executorName .. "' is not supported. Please use a supported executor.")
    end
end
end

-- Compat shims: fill in only what the executor lacks (all pcall-safe no-ops)
if not getgenv then
    getgenv = function() return _G end
end
if not fireclickdetector then
    fireclickdetector = function() end
end
if not isfile then isfile = function() return false end end
if not readfile then readfile = function() error("readfile unsupported") end end
if not writefile then writefile = function() end end

if not request then
    if http and http.request then
        request = http.request
    elseif http_request then
        request = http_request
    elseif syn and syn.request then
        request = syn.request
    else
        request = function() end
    end
end

if not game.HttpGet then
    if http and http.get then
        game.HttpGet = function(_, url) return http.get(url) end
    end
end

if not setclipboard then
    if toclipboard then
        setclipboard = toclipboard
    elseif writeclipboard then
        setclipboard = writeclipboard
    else
        setclipboard = function() end
    end
end

if not firetouchinterest then
    firetouchinterest = function() end
end

if not fireproximityprompt then
    fireproximityprompt = function(prompt)
        pcall(function()
            local VIM = game:GetService("VirtualInputManager")
            VIM:SendKeyEvent(true, prompt.KeyboardKeyCode, false, game)
            task.wait(0.1)
            VIM:SendKeyEvent(false, prompt.KeyboardKeyCode, false, game)
        end)
    end
end

if not firesignal then
    firesignal = function(signal, ...)
        local args = {...}
        if getconnections then
            local okc, conns = pcall(getconnections, signal)
            if okc and conns then
                for _, c in ipairs(conns) do pcall(function() c:Fire(table.unpack(args)) end) end
            end
        end
    end
end

-- ── SakuraUI v4.7 loader (local copies first; HTTP is a last resort) ───────
-- The library is loaded from GitHub only (no local files, nothing embedded),
-- so the script always runs the newest SakuraUI. The fetch is retried a few
-- times with a short wait before it gives up.
local Library = (function()
    -- Loads the PLAIN (un-obfuscated) SakuraUI. The obfuscated copy breaks tab
    -- icons, so a source without the SAKURAUI_PLAIN marker is rejected.
    local URL = "https://raw.githubusercontent.com/Sakuras-Hub/Script-Hub/refs/heads/main/SakuraUI.lua"
    local why = {}
    local function trySource(src, where)
        if type(src) ~= "string" or #src < 100 then why[#why+1] = where .. ": empty/too short"; return nil end
        -- Plain = carries the SAKURAUI_PLAIN marker, OR is readable source that
        -- still has the real method names (an obfuscated build hides them in an
        -- encoded string table, so these plain-text names are absent).
        local isPlain = src:find("SAKURAUI_PLAIN", 1, true)
            or (src:find("_CreateTab", 1, true) and src:find("CreateSegmented", 1, true))
            -- your own protected build of the plain library (Luau Shield header).
            -- The obfuscated GitHub copy has no such header, so it stays rejected.
            or src:sub(1, 60):find("Luau Shield protected build", 1, true)
        if not isPlain then why[#why+1] = where .. ": not the plain file (obfuscated or old)"; return nil end
        local chunk, cerr = loadstring(src)
        if not chunk then why[#why+1] = where .. ": compile failed: " .. tostring(cerr); return nil end
        local ok2, lib = pcall(chunk)
        if not ok2 then why[#why+1] = where .. ": run failed: " .. tostring(lib); return nil end
        if type(lib) ~= "table" or not lib.new then why[#why+1] = where .. ": returned no library"; return nil end
        return lib
    end
    -- GitHub only, so the script always runs the newest library. The URL is
    -- cache-busted and the fetch is retried a few times before giving up.
    for attempt = 1, 3 do
        local ok, src = pcall(game.HttpGet, game, URL .. "?t=" .. tostring(os.time()) .. attempt)
        if ok then
            local lib = trySource(src, "github (try " .. attempt .. ")")
            if lib then return lib end
        else
            why[#why+1] = "github (try " .. attempt .. "): request failed: " .. tostring(src)
        end
        if attempt < 3 then task.wait(1.5) end
    end
    getgenv().SRS_LibraryWhy = table.concat(why, " | ")
    return nil
end)()
if not Library then
    error("SakuraUI failed to load -> " .. tostring(getgenv().SRS_LibraryWhy)
        .. "  (the library is loaded from GitHub only; make sure the plain SakuraUI.lua with the SAKURAUI_PLAIN marker is uploaded to the repo)")
end

-- ── Reload hygiene: previous instances die the moment a new one loads. ─────
-- A generation counter in getgenv() is bumped on every load; every loop and
-- connection in this script checks it and becomes inert once it is stale.
-- Shared running flags are reset, and any leftover GUI is destroyed so a
-- reload is a clean slate (no stale toggles, no stacked UIs).
getgenv().SRS_ReloadGen = (getgenv().SRS_ReloadGen or 0) + 1
local SRS_GEN = getgenv().SRS_ReloadGen
local function srsAlive()
    return getgenv().SRS_ReloadGen == SRS_GEN
end
getgenv().FullAutoRunning    = false
getgenv().PCFullAutoRunning  = false
getgenv().ScriptShuttingDown = false

task.spawn(function()
    local pg = game:GetService("Players").LocalPlayer:FindFirstChild("PlayerGui")
    if pg then
        for _, sg in ipairs(pg:GetChildren()) do
            local n = sg.Name
            -- Foreign/legacy screens only: SakuraUI auto-destroys its own
            -- previous instance inside Library:new — never nuke "SakuraUI"
            -- or the freshly-built window would die before it renders.
            if n == "Acrylic" or n == "Arcylic" or n:find("SRS", 1, true) then
                pcall(function() sg:Destroy() end)
            end
        end
    end
end)

-- ── Delta helpers ──────────────────────────────────────────────────────────
local function deltaWait(seconds)
    if seconds <= 0 then task.wait(); return end
    local accumulated = 0
    local last = tick()
    while accumulated < seconds do
        task.wait()
        local now = tick()
        accumulated = accumulated + (now - last)
        last = now
    end
end

-- ── Speed config (delta-based delays) ─────────────────────────────────────
local SPEED_CONFIG = {
    slow   = { buyDelay = 1.50, reloadDelay = 6.0 },
    medium = { buyDelay = 1.00, reloadDelay = 5.0 },
    fast   = { buyDelay = 0.50, reloadDelay = 4.0 },
    -- human_slow = 4.0s +/- 1.2s, human_medium = 3.0s +/- 1.0s, human_fast = 2.0s +/- 0.7s
    human_slow   = { buyDelay = 4.0, reloadDelay = 8.0, jitter = 1.2 },
    human_medium = { buyDelay = 3.0, reloadDelay = 7.0, jitter = 1.0 },
    human_fast   = { buyDelay = 2.0, reloadDelay = 6.0, jitter = 0.7 },
    -- Riskier timings — faster than Full Auto's "fast". Bans were reported on
    -- these speeds (see the Info tab); only reachable via the explicit "Risky"
    -- buy page. Semi Auto's OLD labels advertised these, but the loop always
    -- read SPEED_CONFIG (so it never actually ran them) — now they're real.
    risky_slow   = { buyDelay = 0.25, reloadDelay = 3.5 },
    risky_medium = { buyDelay = 0.15, reloadDelay = 2.0 },
    risky_fast   = { buyDelay = 0.05, reloadDelay = 1.0 },
}

-- Tiny shared-helper table. bootScript() is at Luau's 200-register ceiling
-- (its tail was split into runMainBodyPart1/2/3 for exactly this), so these
-- helpers are a global table (like safeSetToggle) rather than a local
-- declaration that would cost a register it cannot spare.
Helpers = {}
-- Money spent during the current/last dig run. Uses the spend counter (not
-- "balance at start - balance now", which counted any later purchase and was
-- hidden by sell income) and freezes when the dig stops.
Helpers.digSpend = function()
    local base = getgenv().SRS_DigSpentBase
    if base == nil then return 0 end
    local stop = getgenv().SRS_DigSpentEnd
    return math.max(0, (stop or (getgenv().TotalMoneySpent or 0)) - base)
end

-- ── Full Auto cycle timer (buy phase -> sell phase -> back to buy) ─────────
-- Phase changes are reported by the Full Auto / PC Full Auto loops. Durations
-- of the previous buy and sell phases are remembered so the dashboard can
-- estimate "time to sell", "time to buy" and the length of a full loop.
getgenv().SRS_Cycle = { phase = "idle", start = 0, limit = 0, spent = 0, loopStart = 0, loops = 0,
    loopNet0 = 0, profitSum = 0 }
-- Buy health counters (pages refreshed, purchases, rejections, errors, dry streak).
getgenv().SRS_Health = { pages = 0, okPages = 0, bought = 0, rejected = 0, errors = 0, dry = 0 }

function Helpers.sessionNet()
    local g = getgenv()
    return (g.TotalMoneyEarned or 0) + (g.PassiveIncome or 0) - (g.TotalMoneySpent or 0)
end

function Helpers.healthPage(bought, failed)
    local H = getgenv().SRS_Health
    H.pages = H.pages + 1
    H.rejected = H.rejected + (tonumber(failed) or 0)
    if (tonumber(bought) or 0) > 0 then
        H.okPages = H.okPages + 1; H.bought = H.bought + bought; H.dry = 0
    else
        H.dry = H.dry + 1
    end
end

function Helpers.healthError()
    local H = getgenv().SRS_Health
    H.errors = H.errors + 1; H.dry = H.dry + 1
end

function Helpers.resetCycleStats()
    local C = getgenv().SRS_Cycle
    C.loops, C.profitSum, C.lastLoopProfit, C.bestLoopProfit = 0, 0, nil, nil
    C.loopNet0 = Helpers.sessionNet()
    getgenv().SRS_Health = { pages = 0, okPages = 0, bought = 0, rejected = 0, errors = 0, dry = 0 }
end

function Helpers.cyclePhase(name, limit)
    local C = getgenv().SRS_Cycle
    local now, prev = tick(), C.phase
    if prev == name then
        if name == "buy" then C.limit = limit or C.limit; C.spent = 0; C.start = now end
        return
    end
    if prev == "buy" and (C.spent or 0) > 0 then C.lastBuy = now - C.start; C.lastBuyLimit = C.limit end
    if prev == "sell" then C.lastSell = now - C.start; C.lastSellTotal = C.sellTotal end
    if name == "buy" then
        if prev == "sell" and C.loopStart > 0 then
            C.lastLoop = now - C.loopStart
            C.loops = C.loops + 1
            local lp = Helpers.sessionNet() - (C.loopNet0 or 0)
            C.lastLoopProfit = lp
            C.profitSum = (C.profitSum or 0) + lp
            if C.bestLoopProfit == nil or lp > C.bestLoopProfit then C.bestLoopProfit = lp end
        end
        C.loopStart = now
        C.loopNet0 = Helpers.sessionNet()
    end
    C.phase, C.start, C.limit, C.spent = name, now, limit or 0, 0
    C.spentBase = getgenv().TotalMoneySpent or 0
    C.sellTotal, C.sellLeft = nil, nil
end

function Helpers.cycleProgress(spent)
    local C = getgenv().SRS_Cycle
    if C then C.spent = spent or 0 end
end

-- Returns a table: phase, full (does the mode loop buy->sell?), toSell, toBuy,
-- buyTakes, sellTakes, loop (seconds; nil = still measuring).
function Helpers.cycleInfo()
    local C = getgenv().SRS_Cycle
    local now = tick()
    local el = math.max(0, now - (C.start or now))
    local r = { phase = C.phase, full = C.full, loop = nil }
    local buyRem, sellRem
    if C.phase == "buy" then
        if (C.spent or 0) > 0 and el >= 8 and (C.limit or 0) > 0 then
            buyRem = el * math.max(0, C.limit - C.spent) / C.spent
        elseif C.lastBuy then
            -- Each sell phase grows the budget, so scale the last buy time by it.
            local scale = (C.lastBuyLimit and C.lastBuyLimit > 0 and (C.limit or 0) > 0) and (C.limit / C.lastBuyLimit) or 1
            buyRem = math.max(0, C.lastBuy * scale - el)
        end
        r.buyTakes = buyRem and (el + buyRem) or C.lastBuy
        r.sellTakes = C.lastSell
        r.toSell = buyRem
        if buyRem and C.lastSell then r.toBuy = buyRem + C.lastSell end
    elseif C.phase == "sell" then
        local total, left = C.sellTotal, C.sellLeft
        if total and left then
            local done = total - left
            if left <= 0 then sellRem = 0
            elseif done > 0 and el >= 4 then sellRem = el * left / done end
        end
        if sellRem == nil and C.lastSell then
            local scale = (C.lastSellTotal and C.lastSellTotal > 0 and total and total > 0) and (total / C.lastSellTotal) or 1
            sellRem = math.max(0, C.lastSell * scale - el)
        end
        r.sellTakes = sellRem and (el + sellRem) or C.lastSell
        r.buyTakes = C.lastBuy
        r.toSell = 0
        r.toBuy = sellRem
    else
        r.buyTakes, r.sellTakes = C.lastBuy, C.lastSell
    end
    r.loop = C.lastLoop or ((C.lastBuy and C.lastSell) and (C.lastBuy + C.lastSell) or nil)
    return r
end

function Helpers.jittered(v, j)
    if not j or j <= 0 then return v end
    local out = v + (math.random() * 2 - 1) * j
    return math.max(0.5, math.floor(out * 100) / 100)
end

local function getBuyDelay(speed)
    local conf = SPEED_CONFIG[speed] or SPEED_CONFIG.slow
    return Helpers.jittered(conf.buyDelay, conf.jitter)
end
local function getReloadDelay(speed)
    local conf = SPEED_CONFIG[speed] or SPEED_CONFIG.slow
    return Helpers.jittered(conf.reloadDelay, conf.jitter)
end

-- Dig speed tiers mirror the buy page: legit walking speeds + risky teleport
-- speeds. Each tier scales the E-press grab window (the 8s cycle hog), tool
-- settle waits, treasure buy polls, and end-of-cycle waits. Risky tiers are
-- only reachable via the explicit Risky dig toggles.
local DIG_SPEED_CONFIG = {
    slow   = { grab = 9.0, settle = 0.30, tool = 0.30, buyPoll = 3.5, cycle = 0.30 },
    medium = { grab = 8.0, settle = 0.15, tool = 0.15, buyPoll = 2.5, cycle = 0.15 },
    fast   = { grab = 6.0, settle = 0.10, tool = 0.10, buyPoll = 2.0, cycle = 0.10 },
    -- Riskier timings — faster than walking's "fast". Bans were reported on
    -- the buy page's risky tiers; these dig tiers carry the same risk.
    risky_slow   = { grab = 6.0, settle = 0.15, tool = 0.15, buyPoll = 2.0, cycle = 0.15 },
    risky_medium = { grab = 5.0, settle = 0.10, tool = 0.10, buyPoll = 1.5, cycle = 0.10 },
    risky_fast   = { grab = 4.0, settle = 0.06, tool = 0.06, buyPoll = 1.0, cycle = 0.06 },
}

function __L.getDigCfg(speed)
    return DIG_SPEED_CONFIG[speed] or DIG_SPEED_CONFIG.medium
end

-- ── Safe file helpers ──────────────────────────────────────────────────────
local function safeReadFile(path)
    local ok, data = pcall(readfile, path)
    if ok and type(data) == "string" and data ~= "" then return data end
    local ok2, data2 = pcall(readfile, path .. ".bak")
    if ok2 and type(data2) == "string" and data2 ~= "" then 
        pcall(function() if Log then Log("WARN", "Loaded backup for " .. path) end end)
        return data2 
    end
    local ok3, data3 = pcall(readfile, path .. ".old")
    if ok3 and type(data3) == "string" and data3 ~= "" then 
        pcall(function() if Log then Log("WARN", "Loaded old backup for " .. path) end end)
        return data3 
    end
    return nil
end

local function safeWriteFile(path, data)
    pcall(function()
        local tmp = path .. ".tmp"
        pcall(writefile, tmp, data)
        task.wait()
        pcall(writefile, path, data)
        pcall(function() writefile(path .. ".bak", data) end)
        pcall(function() writefile(path .. ".old", data) end)
        pcall(delfile, tmp)
    end)
end

function __L.safeIsFile(path)
    local ok, result = pcall(isfile, path)
    if ok and result then return true end
    local ok2, result2 = pcall(isfile, path .. ".bak")
    if ok2 and result2 then return true end
    local ok3, result3 = pcall(isfile, path .. ".old")
    return ok3 and result3
end

-- ── Logger ──────────────────────────────────────────────────────────────────
local LOG_PATH = "srs_log.txt"
local LOG_MAX_LINES = 500
local LOG_BUFFER_MAX = 500

getgenv().SRS_LogBuffer = getgenv().SRS_LogBuffer or {}
local SRS_LogBuffer = getgenv().SRS_LogBuffer

function __L._pushLogToBuffer(line)
    table.insert(SRS_LogBuffer, line)
    if #SRS_LogBuffer > LOG_BUFFER_MAX then
        table.remove(SRS_LogBuffer, 1)
    end
    if getgenv().SRS_LogUpdateGUI then
        pcall(getgenv().SRS_LogUpdateGUI)
    end
end

function __L._printToConsole(level, line)
    local lvl = string.upper(tostring(level or "INFO"))
    if lvl ~= "ERROR" and lvl ~= "FATAL" and lvl ~= "WARN" and lvl ~= "WARNING"
        and not getgenv().SRS_VerboseConsole then
        return
    end
    if lvl == "ERROR" or lvl == "FATAL" then
        warn("[SRS][" .. lvl .. "] " .. line:gsub("^%[%d%d:%d%d:%d%d%] %[%a+%] ", ""))
    elseif lvl == "WARN" or lvl == "WARNING" then
        warn("[SRS][WARN] " .. line:gsub("^%[%d%d:%d%d:%d%d%] %[%a+%] ", ""))
    else
        print("[SRS][" .. lvl .. "] " .. line:gsub("^%[%d%d:%d%d:%d%d%] %[%a+%] ", ""))
    end
end

local function Log(level, msg)
    local timestamp = os.date("%H:%M:%S")
    local msgStr = tostring(msg)
    local line = string.format("[%s] [%s] %s", timestamp, tostring(level or "INFO"), msgStr)
    __L._printToConsole(level, line)
    __L._pushLogToBuffer(line)
    local logN = (getgenv().SRS_LogCount or 0) + 1
    getgenv().SRS_LogCount = logN
    if appendfile and logN % 400 ~= 0 then
        pcall(appendfile, LOG_PATH, line .. "\n")
        return
    end
    pcall(function()
        local existing = ""
        if __L.safeIsFile(LOG_PATH) then
            existing = safeReadFile(LOG_PATH) or ""
        end
        local full = existing .. "\n" .. line
        -- Trim old lines if too long
        local lines = {}
        for part in (full .. "\n"):gmatch("(.-)\n") do
            table.insert(lines, part)
        end
        if #lines > LOG_MAX_LINES then
            local cut = #lines - math.floor(LOG_MAX_LINES * 0.5)
            local kept = {}
            for i = cut + 1, #lines do
                table.insert(kept, lines[i])
            end
            full = table.concat(kept, "\n")
        end
        safeWriteFile(LOG_PATH, full)
    end)
end

local function LogEvent(name, details)
    Log("EVENT", name .. ": " .. tostring(details))
end

local function safeSpawn(func, ...)
    local args = {...}
    task.spawn(function()
        local ok, err = xpcall(func, function(e)
            return debug.traceback(tostring(e), 2)
        end, table.unpack(args))
        if not ok then
            Log("ERROR", "safeSpawn: " .. tostring(err))
        end
    end)
end

-- ── Persistence ────────────────────────────────────────────────────────────
local SAVE_PATH = "SRS_V4_Saves.json"

function __L.loadSavedSettings()
    if not __L.safeIsFile(SAVE_PATH) then return nil end
    local raw = safeReadFile(SAVE_PATH)
    if not raw or raw == "" then return nil end
    local ok, data = pcall(function()
        return game:GetService("HttpService"):JSONDecode(raw)
    end)
    return ok and data or nil
end

local savedData = __L.loadSavedSettings()

local function saveSettings()
    local existing = {}
    local raw = safeReadFile(SAVE_PATH)
    if raw and raw ~= "" then
        local ok2, decoded = pcall(function()
            return game:GetService("HttpService"):JSONDecode(raw)
        end)
        if ok2 and decoded then existing = decoded end
    end
    existing.WebhookURL = (getgenv().WebhookURL and getgenv().WebhookURL ~= "")
        and getgenv().WebhookURL
        or (savedData and savedData.WebhookURL) or ""
    existing.Blacklist = {
        Common    = Settings and Settings.Buy.Blacklist.Common    or false,
        Uncommon  = Settings and Settings.Buy.Blacklist.Uncommon  or false,
        Epic      = Settings and Settings.Buy.Blacklist.Epic      or false,
        Legendary = Settings and Settings.Buy.Blacklist.Legendary or false,
        Legacy    = Settings and Settings.Buy.Blacklist.Legacy    or false,
        Special   = Settings and Settings.Buy.Blacklist.Special   or false,
        Limited   = Settings and Settings.Buy.Blacklist.Limited   or false,
        Grail     = Settings and Settings.Buy.Blacklist.Grail     or false,
    }
    -- v4: ONLY the blacklist (plus the webhook URL text and quest-claim ids,
    -- which are data, not toggles) survive a re-inject. Everything else always
    -- boots at its default. Old keys are wiped from the file.
    existing.Stability  = nil
    existing.AutoUnlock = nil
    existing.Budget     = nil
    existing.Quests     = nil
    existing.PCSlots    = nil
    local ok, encoded = pcall(function()
        return game:GetService("HttpService"):JSONEncode(existing)
    end)
    if ok then
        safeWriteFile(SAVE_PATH, encoded)
        savedData = existing
    end
end

-- ── Services ───────────────────────────────────────────────────────────────
local Workspace          = game:GetService("Workspace")
local Players            = game:GetService("Players")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local VirtualUser        = game:GetService("VirtualUser")
local PathfindingService = game:GetService("PathfindingService")
local RunService         = game:GetService("RunService")
local HttpService        = game:GetService("HttpService")
local ScriptContext      = game:GetService("ScriptContext")
local NetworkClient      = game:GetService("NetworkClient")


local LocalPlayer = Players.LocalPlayer

-- ═══════════════════════════════════════════════════════════════════════════
-- SmartWalkTo (v3) — the ONE navigator used by every walk in this script
-- (walkToPC, ensureAtStorePC, sellToNPC, walking Auto Dig).
--
-- Signature: SmartWalkTo(targetPosition, keepGoing, opts) -> reached (bool)
--   keepGoing     function -> truthy while the walk may continue (the caller's
--                 "automation still on" flag). The walk stops the moment it
--                 returns false/nil, so toggling an automation off is instant.
--   opts.reach    success distance in studs (default 8)
--   opts.maxTime  total walk budget in seconds (default 30)
--   opts.maxStuck consecutive "no progress" checks before giving up (default 5)
--   opts.depth    internal: recursion guard (a door approach may walk once)
--
-- HOW IT WORKS (in the order it tries things)
--   1. ROUTE      Roblox PathfindingService, tried with a NARROW agent first
--                 (radius 2.5, then 2, then 1.5). The old fixed radius of 3
--                 made a 6-stud-wide agent that cannot fit through a normal
--                 door, so the navmesh said "no path" at every doorway. If the
--                 exact target is off the navmesh (the store PC pivot is), a
--                 ring of +3..+8 stud offsets around it is tried.
--   2. WALLS      Rays use RespectCanCollide, so invisible/non-solid parts are
--                 not mistaken for walls, and other players are ignored.
--   3. DOORS      A blocking part (or its parent models) named door / gate /
--                 entrance / turnstile / shutter is treated as a door. The
--                 walker finds its ProximityPrompt or ClickDetector, walks into
--                 range, triggers it, waits for the way to clear, then re-plans.
--                 Prompts that look like shops/teleports/purchases (buy, sell,
--                 robux, unlock, enter, teleport, ...) are NEVER triggered.
--                 Doors with no handle (touch/auto doors) are simply pushed.
--                 Each door gets at most 3 tries (keypress, hold, keypress).
--   4. GAPS       No door? Probe both sides along the wall for an opening
--                 (doorway) whose ray clears, and slide to it. Slide direction
--                 is held for a minimum time/distance so it never zig-zags.
--   5. LEDGES     A low obstacle (under ~3 studs tall) is hopped, not circled.
--   6. STUCK      No real progress for ~1.2s -> jump, scan 16 studs for a door,
--                 re-plan the route, and finally give up cleanly so the caller's
--                 retry logic runs instead of grinding on a wall forever.
--   7. LIVE       The route is re-planned when Roblox reports a waypoint
--                 blocked (Path.Blocked), e.g. a door that just closed.
--   8. GAIT       WalkSpeed eases up to a sprint with a small wobble so the
--                 movement is not constant-speed. The original speed is always
--                 restored, even if something errors mid-walk.
--
-- Everything the walker needs besides the walk loop itself lives in the
-- global Helpers table (bootScript() is at Luau's 200-local ceiling).
-- ═══════════════════════════════════════════════════════════════════════════

-- Door detection ------------------------------------------------------------
-- Name fragments that make a part/model "a door". Words that merely CONTAIN
-- "door" (outdoor, indoor, doormat, doorbell, doorway, doorstep) are removed
-- before matching so "Outdoor_Wall" is not treated as a door.
Helpers.DOOR_WORDS = { "door", "gate", "entrance", "turnstile", "shutter" }
Helpers.DOOR_NOT_WORDS = { "outdoor", "indoor", "doormat", "doorbell", "doorway", "doorstep" }
-- A prompt whose text contains any of these is never triggered by the walker
-- (it could spend money, teleport you, or open a shop instead of a door).
Helpers.DOOR_BAD_TEXT = {
    "buy", "sell", "shop", "purchase", "robux", "premium", "gamepass", "vip",
    "unlock", "teleport", "rebirth", "trade",
}
-- v4: a prompt right ON a door-named part may legitimately say "Enter"; one found
-- on a parent model (strict mode) must not, because that is how shop/teleport
-- doors are labelled.
Helpers.DOOR_BAD_TEXT_STRICT = { "enter" }

function Helpers.isDoorName(name)
    local n = tostring(name):lower()
    for _, skip in ipairs(Helpers.DOOR_NOT_WORDS) do
        n = n:gsub(skip, "")
    end
    for _, w in ipairs(Helpers.DOOR_WORDS) do
        if n:find(w, 1, true) then return true end
    end
    return false
end

-- The door an instance belongs to: the instance itself or one of its next 3
-- ancestors, whichever is named like a door (and is a Part/Model, not a Folder).
function Helpers.doorFromHit(inst)
    local cur = inst
    for _ = 1, 4 do
        if not cur or cur == workspace or cur == game then return nil end
        if cur:IsA("PVInstance") and Helpers.isDoorName(cur.Name) then return cur end
        cur = cur.Parent
    end
    return nil
end

-- Is this ProximityPrompt safe to fire as a "door opener"?
-- strict = also require that the text actually mentions open/door/gate/close
-- (used for prompts found on a door's parent model rather than on the door).
function Helpers.controlOk(prompt, strict)
    if not prompt.Enabled then return false end
    local txt = (tostring(prompt.ActionText) .. " " .. tostring(prompt.ObjectText)):lower()
    for _, w in ipairs(Helpers.DOOR_BAD_TEXT) do
        if txt:find(w, 1, true) then return false end
    end
    if strict then
        for _, w in ipairs(Helpers.DOOR_BAD_TEXT_STRICT) do
            if txt:find(w, 1, true) then return false end
        end
        return (txt:find("open", 1, true) or txt:find("door", 1, true)
            or txt:find("gate", 1, true) or txt:find("close", 1, true)) ~= nil
    end
    return true
end

-- Find the thing that opens a door: a ProximityPrompt (preferred) or a
-- ClickDetector. Returns control, "prompt" | "click", or nil.
function Helpers.findDoorControl(door)
    local roots = { door }
    local parent = door.Parent
    if parent and parent ~= workspace and parent:IsA("Model") then roots[2] = parent end
    for ri, root in ipairs(roots) do
        local strict = ri > 1
        local click = nil
        local n = 0
        for _, d in ipairs(root:GetDescendants()) do
            n += 1
            if n > 300 then break end
            if d:IsA("ProximityPrompt") and Helpers.controlOk(d, strict) then
                return d, "prompt"
            elseif d:IsA("ClickDetector") and not strict and not click then
                click = d
            end
        end
        if click then return click, "click" end
    end
    return nil
end

function Helpers.controlPos(ctrl)
    local p = ctrl.Parent
    if p and p:IsA("Attachment") then return p.WorldPosition end
    if p and p:IsA("BasePart") then return p.Position end
    local m = p and p:FindFirstAncestorOfClass("Model")
    if m then return m:GetPivot().Position end
    return nil
end

-- Every door within `radius` studs of `pos`, nearest first:
-- { { door = Instance, pos = Vector3, dist = number }, ... }
function Helpers.scanDoors(pos, radius, exclude)
    local list, seen = {}, {}
    local ok, parts = pcall(function()
        local op = OverlapParams.new()
        op.FilterType = Enum.RaycastFilterType.Exclude
        op.FilterDescendantsInstances = exclude or {}
        return workspace:GetPartBoundsInRadius(pos, radius, op)
    end)
    if not ok or not parts then return list end
    for _, part in ipairs(parts) do
        local d = Helpers.doorFromHit(part)
        if d and not seen[d] then
            seen[d] = true
            local okp, dp = pcall(function() return d:GetPivot().Position end)
            if okp and dp then
                list[#list + 1] = { door = d, pos = dp, dist = (dp - pos).Magnitude }
            end
        end
    end
    table.sort(list, function(a, b) return a.dist < b.dist end)
    return list
end

-- Walk into range of the door's control and trigger it.
-- tryNo 1 = fireproximityprompt, 2 = manual hold (for HoldDuration prompts),
-- 3 = fireproximityprompt again. Returns true if a control was triggered.
function Helpers.useDoor(door, hrp, humanoid, keepGoing, tryNo, depth)
    local ctrl, kind = Helpers.findDoorControl(door)
    if not ctrl then return false end
    local cpos = Helpers.controlPos(ctrl)
    if not cpos then return false end
    local reach = 8
    if kind == "prompt" then
        reach = math.max(3, (tonumber(ctrl.MaxActivationDistance) or 10) - 2)
    end
    -- Far away: use the full navigator once (depth guard stops recursion).
    if (hrp.Position - cpos).Magnitude > reach + 6 and (depth or 0) < 1 and Helpers.SmartWalkTo then
        Helpers.SmartWalkTo(cpos, keepGoing, { reach = reach, maxTime = 12, depth = (depth or 0) + 1 })
    end
    local t0 = tick()
    while keepGoing() and tick() - t0 < 4 and (hrp.Position - cpos).Magnitude > reach do
        humanoid:MoveTo(cpos)
        deltaWait(0.1)
    end
    if (hrp.Position - cpos).Magnitude > reach + 2 then return false end
    if kind == "prompt" then
        local hold = tonumber(ctrl.HoldDuration) or 0
        if tryNo == 2 and hold > 0 then
            pcall(function() ctrl:InputHoldBegin() end)
            deltaWait(hold + 0.15)
            pcall(function() ctrl:InputHoldEnd() end)
        else
            pcall(fireproximityprompt, ctrl)
        end
    else
        pcall(fireclickdetector, ctrl)
    end
    LogEvent("Door", "used " .. kind .. " on " .. door:GetFullName() .. " (try " .. tostring(tryNo) .. ")")
    return true
end

-- The walk loop -------------------------------------------------------------
-- ctx collects things the wrapper must clean up (path-blocked connection,
-- the humanoid and its original WalkSpeed).
function Helpers.walkCore(ctx, targetPosition, keepGoing, opts)
    opts = opts or {}
    local reach    = opts.reach    or 8
    local maxTime  = opts.maxTime  or 30
    local maxStuck = opts.maxStuck or 5

    local char     = LocalPlayer.Character
    local hrp      = char and char:FindFirstChild("HumanoidRootPart")
    local humanoid = char and char:FindFirstChildOfClass("Humanoid")
    if not hrp or not humanoid or humanoid.Health <= 0 then return false end
    if (hrp.Position - targetPosition).Magnitude <= reach then return true end
    ctx.humanoid = humanoid

    -- Humanized gait: smoother WalkSpeed envelope (eased ramp to a sprint) plus
    -- a ~1.5Hz wobble so the speed is never constant. Straight-line aim by
    -- default; set getgenv().SRSHumanizedWalk = true for a slight lateral sway.
    local baseSpeed   = humanoid.WalkSpeed
    ctx.baseSpeed     = baseSpeed
    local sprintSpeed = getgenv().SRSWalkSprintSpeed or 26
    local gaitEpoch   = tick()
    local curSpeed    = baseSpeed
    local function gaitMoveTo(targetPos)
        local walkT  = tick() - gaitEpoch
        local ramp   = math.min(1, walkT / 0.3)
        local eased  = 1 - (1 - ramp) * (1 - ramp)
        local target = baseSpeed + (sprintSpeed - baseSpeed) * eased
        local final  = math.max(baseSpeed, math.min(sprintSpeed, target + 0.7 * math.sin(walkT * 9.4)))
        if curSpeed ~= final then
            curSpeed = final
            humanoid.WalkSpeed = final
        end
        if getgenv().SRSHumanizedWalk then
            local posNow = hrp.Position
            local flatGoal = Vector3.new(targetPos.X - posNow.X, 0, targetPos.Z - posNow.Z)
            local distGoal = flatGoal.Magnitude
            if distGoal > 0.5 then
                local fwd = flatGoal / distGoal
                local side = Vector3.new(-fwd.Z, 0, fwd.X)
                targetPos = posNow + fwd * distGoal + side * (0.35 * math.sin(walkT * 3.1) * math.min(1, distGoal / 2.5))
            end
        end
        humanoid:MoveTo(targetPos)
    end

    local startT = tick()

    -- Rays: ignore our character and every other player (a player standing in
    -- a doorway must not look like a wall) and ignore non-collidable parts.
    local rayParams = RaycastParams.new()
    rayParams.FilterType = Enum.RaycastFilterType.Exclude
    local rayExclude = { char }
    for _, p in ipairs(Players:GetPlayers()) do
        local c = p.Character
        if c and c ~= char then rayExclude[#rayExclude + 1] = c end
    end
    rayParams.FilterDescendantsInstances = rayExclude
    rayParams.IgnoreWater = true
    pcall(function() rayParams.RespectCanCollide = true end)

    local function castHit(from, dir, maxDist)
        return workspace:Raycast(from + Vector3.new(0, 2, 0), dir * maxDist, rayParams)
    end

    -- 1) Navmesh route. Narrow agents first so doorways fit; the exact target
    -- can sit off the navmesh, so NoPath is retried against a ring of offsets
    -- and the closest reachable point becomes the leg to walk.
    local waypoints, legIndex = nil, 1
    local blockedFlag = false
    local function tryCompute(dest, radius)
        local ok = pcall(function()
            local p = PathfindingService:CreatePath({
                AgentRadius = radius, AgentHeight = 5,
                AgentCanJump = true, AgentCanClimb = false, WaypointSpacing = 3,
            })
            p:ComputeAsync(hrp.Position, dest)
            if p.Status == Enum.PathStatus.Success then
                local w = p:GetWaypoints()
                if #w > 0 then
                    waypoints = w
                    if ctx.conn then ctx.conn:Disconnect() end
                    -- Roblox tells us when a waypoint ahead becomes blocked
                    -- (a door closing, a moved part): re-plan on the next tick.
                    ctx.conn = p.Blocked:Connect(function(idx)
                        if idx >= legIndex then blockedFlag = true end
                    end)
                end
            end
        end)
        return ok and waypoints ~= nil
    end
    local RING = {
        Vector3.new(3,0,0),  Vector3.new(-3,0,0),  Vector3.new(0,0,3),  Vector3.new(0,0,-3),
        Vector3.new(5,0,0),  Vector3.new(-5,0,0),  Vector3.new(0,0,5),  Vector3.new(0,0,-5),
        Vector3.new(8,0,0),  Vector3.new(-8,0,0),  Vector3.new(0,0,8),  Vector3.new(0,0,-8),
    }
    local function routeTo(dest)
        waypoints, legIndex = nil, 1
        for _, r in ipairs({ 2.5, 2, 1.5 }) do
            if tryCompute(dest, r) then return true end
        end
        for _, off in ipairs(RING) do
            waypoints = nil
            if tryCompute(dest + off, 2) then return true end
        end
        return false
    end

    -- 2) Wall-follow steering: resolve the wall's surface normal from the real
    -- hit and slide ALONG it. Before sliding, scan both sides for a DOORWAY GAP
    -- (nearest offset where the forward ray clears) and slide straight to it.
    -- Returns (slideVector, isGap).
    local function steerAround(pos, dirGoal)
        local ray = castHit(pos, dirGoal, 14)
        local normal = ray and ray.Normal or nil
        local wallRight = normal and Vector3.new(-normal.Z, 0, normal.X) or Vector3.new(-dirGoal.Z, 0, dirGoal.X)
        if wallRight:Dot(dirGoal) < 0 then wallRight = -wallRight end
        local bestOff, bestScore = nil, -1e9
        for _, sign in ipairs({ 1, -1 }) do
            for _, off in ipairs({ 2, 4, 6, 8, 10, 12, 14, 18, 22 }) do
                local slide = wallRight * (off * sign)
                -- drop slides that point clearly away from the goal
                if slide:Dot(dirGoal) < -off * 0.5 then continue end
                local h = castHit(pos + slide, dirGoal, 16)
                local clearDist = h and h.Distance or 16
                if clearDist > 5 then
                    local score = math.min(clearDist, 10) - off * 0.5
                    if score > bestScore then bestScore, bestOff = score, slide end
                end
            end
        end
        if bestOff then return bestOff, true end
        return wallRight, false
    end

    -- 3) Doors. Returns true when the way ahead looks clear afterwards.
    local doorState = {}
    local function tryDoor(door, dirGoal)
        local st = doorState[door]
        if not st then st = { tries = 0, last = 0 }; doorState[door] = st end
        if st.tries >= 3 or tick() - st.last < 2.5 then return false end
        st.tries += 1
        st.last = tick()
        local dir = Vector3.new(dirGoal.X, 0, dirGoal.Z)
        if dir.Magnitude < 0.1 then
            local look = hrp.CFrame.LookVector
            dir = Vector3.new(look.X, 0, look.Z)
        end
        if dir.Magnitude > 0.1 then dir = dir.Unit end
        local used = Helpers.useDoor(door, hrp, humanoid, keepGoing, st.tries, opts.depth or 0)
        if not used then
            -- No handle: touch/auto doors open when you walk into them.
            humanoid:MoveTo(hrp.Position + dir * 6)
            deltaWait(1.0)
        end
        local t0 = tick()
        while keepGoing() and tick() - t0 < 2.0 do
            local h = castHit(hrp.Position, dir, 4)
            if not h or not (h.Instance == door or h.Instance:IsDescendantOf(door)) then return true end
            deltaWait(0.15)
        end
        return false
    end

    routeTo(targetPosition)

    -- No navmesh route at all. A closed door is the usual reason, so look for
    -- one before giving up. The blind straight-line fallback is only allowed
    -- when the direct ray is clear, a door was opened, or a doorway gap exists.
    if not waypoints then
        local delta   = targetPosition - hrp.Position
        local flat    = Vector3.new(delta.X, 0, delta.Z)
        local flatLen = flat.Magnitude
        if flatLen > 1 then
            local fdir  = flat / flatLen
            local probe = castHit(hrp.Position, fdir, flatLen + 1)
            if probe and probe.Distance < flatLen - 1.5 then
                local door = Helpers.doorFromHit(probe.Instance)
                if not door then
                    for _, e in ipairs(Helpers.scanDoors(hrp.Position, 60, rayExclude)) do
                        local tod = Vector3.new(e.pos.X - hrp.Position.X, 0, e.pos.Z - hrp.Position.Z)
                        if tod.Magnitude > 0.5 and (tod / tod.Magnitude):Dot(fdir) > 0.2 then
                            door = e.door
                            break
                        end
                    end
                end
                local opened = door ~= nil and tryDoor(door, fdir)
                if opened then routeTo(targetPosition) end
                if not waypoints and not opened then
                    local _, gap = steerAround(hrp.Position, fdir)
                    if not gap then return false end
                end
            end
        end
    end

    local stuckCount   = 0
    local lastStuckPos = hrp.Position
    local lastStuckT   = tick()

    -- Wall-follow hysteresis: once committed to a slide, keep it for a minimum
    -- distance (6 studs, 8 through a gap) and time (0.9s, 1.5s through a gap)
    -- before re-deciding, so a doorway never causes zig-zagging.
    local slideDir, slideIsGap, slideStartPos, slideStartT = nil, false, nil, nil
    local firstGoal = (waypoints and waypoints[1]) and waypoints[1].Position or targetPosition
    local progLast  = (hrp.Position - firstGoal).Magnitude

    -- Rolling 1s window of real progress: one jitter tick while pressed against
    -- a wall can never clear the stall detector.
    local winSum = 0
    local winT, winD = {}, {}

    while keepGoing() and tick() - startT < maxTime do
        local hrp2 = char and char:FindFirstChild("HumanoidRootPart")
        if not hrp2 or humanoid.Health <= 0 then return false end
        if humanoid.Sit then humanoid.Jump = true end
        local pos = hrp2.Position
        if (pos - targetPosition).Magnitude <= reach then return true end

        if blockedFlag then
            blockedFlag = false
            routeTo(targetPosition)
        end

        local goal = (waypoints and waypoints[legIndex]) and waypoints[legIndex].Position or targetPosition
        if waypoints and (pos - goal).Magnitude < 4 then
            legIndex = legIndex + 1
            goal = waypoints[legIndex] and waypoints[legIndex].Position or targetPosition
            progLast = (pos - goal).Magnitude
        end

        local flat     = Vector3.new(goal.X - pos.X, 0, goal.Z - pos.Z)
        local distGoal = flat.Magnitude
        local dirGoal  = distGoal > 0.01 and flat / distGoal or Vector3.new(0, 0, 0)

        local inCommit = slideDir and slideStartPos
            and (tick() - slideStartT < (slideIsGap and 1.5 or 0.9))
            and ((pos - slideStartPos).Magnitude < (slideIsGap and 8 or 6))

        local progNow = (pos - goal).Magnitude
        local progDelta = progLast - progNow
        progLast = progNow

        local nowW = tick()
        winSum = winSum + progDelta
        winT[#winT + 1] = nowW
        winD[#winD + 1] = progDelta
        while #winT > 0 and nowW - winT[1] > 1.0 do
            table.remove(winT, 1)
            if #winD > 0 then winSum = winSum - table.remove(winD, 1) end
        end

        local wallRay = nil
        if distGoal > 0.5 then wallRay = castHit(pos, dirGoal, 3.5) end
        local wallAhead = wallRay and wallRay.Distance < 2.5

        if not slideDir and winSum > 1.0 then
            gaitMoveTo(goal)                                  -- making progress: just walk
        elseif not slideDir and wallAhead then
            -- Blocked. A door? open it. A low ledge? hop it. Otherwise slide
            -- to the nearest doorway gap / along the wall.
            local door = Helpers.doorFromHit(wallRay.Instance)
            if door and tryDoor(door, dirGoal) then
                routeTo(targetPosition)
                gaitMoveTo(targetPosition)
            else
                local wi = wallRay.Instance
                if not door and wi:IsA("BasePart") and not wi:IsA("Terrain") and wi.Size.Y < 3.2 then
                    humanoid.Jump = true
                end
                slideDir, slideIsGap = steerAround(pos, dirGoal)
                slideStartPos = pos
                slideStartT   = tick()
                gaitMoveTo(pos + slideDir * 5)
            end
        elseif not slideDir then
            gaitMoveTo(goal)                                  -- open ground, keep walking
        elseif inCommit then
            gaitMoveTo(pos + slideDir * 5)
        else
            -- Commit window over: release if the line to the goal is clear,
            -- otherwise re-scan (a long slide can march PAST the doorway).
            local aheadProbe = castHit(pos + slideDir * 3, dirGoal, math.min(distGoal, 14))
            if (aheadProbe and aheadProbe.Distance or 14) > 5 then
                slideDir, slideIsGap = nil, false
                gaitMoveTo(goal)
            else
                slideDir, slideIsGap = steerAround(pos, dirGoal)
                slideStartPos = pos
                slideStartT   = tick()
                gaitMoveTo(pos + slideDir * 5)
            end
        end

        if waypoints and waypoints[legIndex] and waypoints[legIndex].Action == Enum.PathWaypointAction.Jump then
            humanoid.Jump = true
        end

        deltaWait(0.1)

        -- Stuck check every 1.2s: jump -> look for a door -> re-plan -> give up.
        if tick() - lastStuckT >= 1.2 then
            local moved = (hrp2.Position - lastStuckPos).Magnitude
            if moved < 1.2 then
                stuckCount = stuckCount + 1
                humanoid.Jump = true
                for _, e in ipairs(Helpers.scanDoors(hrp2.Position, 16, rayExclude)) do
                    local st = doorState[e.door]
                    -- v4: ignore doors behind us (opening those wasted tries and time)
                    local tod = Vector3.new(e.pos.X - hrp2.Position.X, 0, e.pos.Z - hrp2.Position.Z)
                    local ahead = dirGoal.Magnitude < 0.1 or tod.Magnitude < 6
                        or (tod / tod.Magnitude):Dot(dirGoal) > -0.3
                    if ahead and (not st or st.tries < 3) then
                        if tryDoor(e.door, dirGoal) then
                            routeTo(targetPosition)
                            stuckCount = 0
                        end
                        break
                    end
                end
                if stuckCount > 1 then routeTo(targetPosition) end
                if stuckCount >= maxStuck then
                    -- v4: say what we were stuck on, so a missed door can be added by name
                    local look = dirGoal.Magnitude > 0.1 and dirGoal or hrp2.CFrame.LookVector
                    local bh = castHit(hrp2.Position, look, 5)
                    LogEvent("WalkStuck", string.format("gave up at (%d,%d,%d) blocker=%s",
                        math.floor(hrp2.Position.X), math.floor(hrp2.Position.Y), math.floor(hrp2.Position.Z),
                        bh and bh.Instance:GetFullName() or "none"))
                    return false
                end
            else
                stuckCount = 0
            end
            lastStuckPos = hrp2.Position
            lastStuckT   = tick()
        end
    end

    local hrpFinal = char and char:FindFirstChild("HumanoidRootPart")
    return hrpFinal and (hrpFinal.Position - targetPosition).Magnitude <= reach * 1.5 or false
end

-- Public entry point. The pcall guarantees WalkSpeed is restored and the
-- Path.Blocked connection is dropped no matter how the walk ends.
local SmartWalkTo = function(targetPosition, keepGoing, opts)
    local ctx = {}
    local ok, res = pcall(Helpers.walkCore, ctx, targetPosition, keepGoing, opts)
    if ctx.conn then pcall(function() ctx.conn:Disconnect() end) end
    if ctx.humanoid and ctx.baseSpeed then
        pcall(function() ctx.humanoid.WalkSpeed = ctx.baseSpeed end)
    end
    if not ok then
        Log("ERROR", "SmartWalkTo: " .. tostring(res))
        return false
    end
    return res
end
Helpers.SmartWalkTo = SmartWalkTo
getgenv().SmartWalkTo = SmartWalkTo

-- ── Safe character references ──────────────────────────────────────────────
local Character, Humanoid, HumanoidRootPart

function __L.refreshCharacter()
    local char = LocalPlayer.Character
    if not char then
        local ok, result = pcall(function()
            return LocalPlayer.CharacterAdded:Wait()
        end)
        if ok then char = result else return end
    end
    Character        = char
    Humanoid         = char:FindFirstChildOfClass("Humanoid")
    HumanoidRootPart = char:FindFirstChild("HumanoidRootPart")
end

pcall(__L.refreshCharacter)

local PlayerGui = LocalPlayer.PlayerGui

-- ── Safe SellFrame reference ───────────────────────────────────────────────
local SellFrame
local function getSellFrame()
    local ok, result = pcall(function()
        return PlayerGui.MainScreenGui.SellAnimFrame
    end)
    if ok and result then
        SellFrame = result
        return true
    end
    SellFrame = nil
    return false
end
getSellFrame()

-- ── Sell-bar / shop-page mutual exclusion ──────────────────────────────────
-- The game rejects shop-page refreshes while the sell bar is up, and only
-- auto-closes the bar itself once no more sellable shoes remain. Every sell
-- exit therefore closes the bar explicitly; every buy refresh also force-
-- closes it (idempotent) so a bar left up by manual play or a stopped sweep
-- can never block a buy cycle. Fires the bar's real ExitButton, with a
-- Visible=false fallback to cover slow exit tweens.
local function closeSellBar()
    if not SellFrame then getSellFrame() end
    if not SellFrame then return end
    if SellFrame.Visible then
        local exit = SellFrame:FindFirstChild("ExitButton")
        if exit then
            pcall(function() firesignal(exit.MouseButton1Down) end)
            pcall(function() firesignal(exit.MouseButton1Click) end)
            pcall(function() exit.MouseButton1Down:Fire() end)
            pcall(function() exit.MouseButton1Click:Fire() end)
        end
        pcall(function() SellFrame.Visible = false end)
    end
    -- [FIX] A stop can race an in-flight sellToNPC: the NPC prompt fires after
    -- this close (or after the bar was already hidden) and re-opens the bar
    -- with no listener left to sell or close it. While no sell mode is active,
    -- poll briefly and close it again; bail out if a new sell starts.
    local function sellModeActive()
        local st = getgenv().Settings
        return (st and st.Sell) or getgenv().FullAutoRunning or getgenv().PCFullAutoRunning
    end
    if sellModeActive() then return end
    if getgenv().SRS_ClosingSellBar then return end
    getgenv().SRS_ClosingSellBar = true
    task.spawn(function()
        for _ = 1, 12 do
            task.wait(0.5)
            if not srsAlive() then break end
            if sellModeActive() then break end
            if not SellFrame or not SellFrame.Parent then break end
            if SellFrame.Visible then
                local ex = SellFrame:FindFirstChild("ExitButton")
                if ex then
                    pcall(function() firesignal(ex.MouseButton1Down) end)
                    pcall(function() firesignal(ex.MouseButton1Click) end)
                end
                pcall(function() SellFrame.Visible = false end)
            else
                break
            end
        end
        getgenv().SRS_ClosingSellBar = false
    end)
end

-- ── Safe Sneakers require ──────────────────────────────────────────────────
local Sneakers = {}
do
local ok_sneakers, sneakersResult = pcall(function()
    return require(ReplicatedStorage.SneakerModule).sneakers
end)
if ok_sneakers and sneakersResult then
    Sneakers = sneakersResult
end
end
-- [FIX] the game's own rarity palette (SneakerModule.RarityColors) so the
-- Blacklist tab can show each rarity in its real in-game colour instead of a
-- hand-typed guess ("Legendary | Gold" was wrong — the game paints it orange).
-- Stored on getgenv() rather than a new top-level local: bootScript() is on
-- Luau's 200-register ceiling (I-007/I-008) and a fresh local here re-breaks the
-- load with "Out of local registers ... exceeded limit 200".
do
local ok_rc, rcResult = pcall(function()
    return require(ReplicatedStorage.SneakerModule).RarityColors
end)
if ok_rc and type(rcResult) == "table" then
    getgenv().SRS_RarityColors = rcResult
else
    getgenv().SRS_RarityColors = {}
end
end

-- ── Load saved blacklist values ────────────────────────────────────────────
local savedBL = savedData and savedData.Blacklist or {}

getgenv().Settings = {
    Sell = false,
    Buy  = {
        Enabled   = false,
        Blacklist = {
            Common    = savedBL.Common    or false,
            Uncommon  = savedBL.Uncommon  or false,
            Epic      = savedBL.Epic      or false,
            Legendary = savedBL.Legendary or false,
            Legacy    = savedBL.Legacy    or false,
            Special   = savedBL.Special   or false,
            Limited   = savedBL.Limited   or false,
            Grail     = savedBL.Grail     or false, -- every rarity is blacklistable now
            -- [FIX] the per-shoe blacklist was removed; only rarities are skipped
        },
    },
    AutoUnlock = false, -- [FIX] user request: OFF by default; testing unlocks costs real money
    Budget = {
        -- Run-scoped buy budget: money is snapshotted once when automation
        -- turns on; the buy->sell swap fires when cumulative purchases spend
        -- it. Worker income earned mid-run can never re-arm the budget.
        Enabled = true, -- v4: always ON at boot (never restored from the save file)
    },
    HalloweenTradeIn = {
        -- Auto turn-in at the Halloween skeleton ("Give me these Sneakers")
        -- as soon as all three required shoes are at 5/5. OFF at boot.
        Enabled = false,
    },
    HalloweenBoxes = {
        -- Open Halloween Mystery Boxes (bought with Candy) after each sell
        -- phase of Full Auto / PC Full Auto. OFF at boot like every toggle.
        Enabled = false,
    },
    Quests = {
        -- Auto-claim daily quests when their counters pass the target and
        -- redeem the final bonus once all three are done (default ON).
        AutoRedeem = true, -- v4: always ON at boot
    },
    Buttons = false,
    -- Store upgrades are bought by touch. Touching the button part works from
    -- anywhere (no proximity), which is the default; players who want realism
    -- can enable WalkToStoreButtons to walk over to each button first.
    WalkToStoreButtons = false,
}

getgenv().NotificationsEnabled = true

-- ── Fix: stop page scroll while hovering over an open dropdown ────────────
-- When the cursor is over a child ScrollingFrame (dropdown list), temporarily
-- disable all ancestor ScrollingFrames (the page) so wheel only scrolls the child.
task.spawn(function()
    task.wait(3)
    local coreGui = game:GetService("CoreGui")
    local hooked = setmetatable({}, { __mode = "k" })
    local function hookNestedScroll(sf)
        if not sf:IsA("ScrollingFrame") then return end
        if hooked[sf] then return end
        hooked[sf] = true
        local ancestors = {}
        local p = sf.Parent
        while p and srsAlive() do
            if p:IsA("ScrollingFrame") then table.insert(ancestors, p) end
            p = p.Parent
        end
        if #ancestors == 0 then return end
        sf.MouseEnter:Connect(function()
            for _, a in ipairs(ancestors) do a.ScrollingEnabled = false end
        end)
        sf.MouseLeave:Connect(function()
            for _, a in ipairs(ancestors) do a.ScrollingEnabled = true end
        end)
    end
    local SKIP_GUI = { RobloxGui = true, PlayerList = true, Chat = true, ExperienceChat = true,
        TopBarApp = true, RobloxPromptGui = true, PurchasePrompt = true, ThemeProvider = true,
        InGameMenu = true, BubbleChat = true }
    local function hookGui(sg)
        if not sg:IsA("ScreenGui") or SKIP_GUI[sg.Name] then return end
        sg.DescendantAdded:Connect(function(desc)
            if not srsAlive() then return end
            if desc:IsA("ScrollingFrame") then task.defer(hookNestedScroll, desc) end
        end)
        local n = 0
        for _, desc in ipairs(sg:GetDescendants()) do
            if desc:IsA("ScrollingFrame") then hookNestedScroll(desc) end
            n += 1
            if n % 400 == 0 then task.wait() end
        end
    end
    for _, sg in ipairs(coreGui:GetChildren()) do task.spawn(hookGui, sg) end
    coreGui.ChildAdded:Connect(function(child)
        if not srsAlive() then return end
        task.wait()
        hookGui(child)
    end)
end)

-- Rayfield image names -> SakuraUI icon (keyword or verified asset ID).
local ICON_IDS = {
    Check = "85262178816537",    -- lucide circle-check — verified 420px render
    X     = "error",             -- SakuraUI "error" icon
    Alert = "83898160590116",    -- lucide circle-alert — verified 420px render
    Store = "124870886755485",   -- lucide/gravity shopping-cart — verified 420px render
    Star  = "82714530610376",    -- lucide/gravity solid star — verified 420px render
}

-- Image name -> SakuraUI Type, which tints the stripe + icon per kind.
local NOTIFY_TYPES = {
    Check = "success",
    X     = "error",
    Alert = "warning",
    Store = "info",
    Star  = "success",
}

local Window -- assigned below, after Library:new(...)

local function Notify(opts)
    if getgenv().NotificationsEnabled == false then return end
    -- Cascade guard: cancelOtherAutomation()/shutdownAllAutomation() flip every
    -- sibling toggle off inside FullAutoSwitching=true, and each stop path fires
    -- its own "Stopped." popup. Suppress those so starting one automation doesn't
    -- spam "everything stopped" notifications. Interrupt pops from the loops
    -- (out of money, inventory empty, server not responding) fire before their
    -- own FullAutoSwitching=true line, so they still show.
    if getgenv().FullAutoSwitching then return end
    if not Window then return end
    local o = table.clone(opts or {})
    if o.Image ~= nil then
        o.Icon = ICON_IDS[o.Image]
        o.Type = NOTIFY_TYPES[o.Image] or o.Type
        o.Image = nil
    end
    o.Description = o.Content
    o.Content = nil
    Window:Notify(o)
end

function __L.NotifySuccess(title, content, duration)
    Notify({ Title = title or "Success", Content = content or "", Duration = duration or 3, Image = "Check" })
end
function __L.NotifyError(title, content, duration)
    Notify({ Title = title or "Error", Content = content or "", Duration = duration or 5, Image = "X" })
end
function __L.NotifyWarn(title, content, duration)
    Notify({ Title = title or "Warning", Content = content or "", Duration = duration or 4, Image = "Alert" })
end

-- Direct notifies that bypass the "In-Script Notifications" toggle
-- (matches the old Rayfield:Notify(...) call sites).
local function RawNotify(opts)
    if not Window then return end
    local o = table.clone(opts or {})
    if o.Image ~= nil then
        o.Icon = ICON_IDS[o.Image]
        o.Type = NOTIFY_TYPES[o.Image] or o.Type
        o.Image = nil
    end
    o.Description = o.Content
    o.Content = nil
    Window:Notify(o)
end

Settings = getgenv().Settings

do
local function FireTouchTransmitter(touchParent)
    local Char = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Part")
    if Char then
        firetouchinterest(touchParent, Char, 0)
        firetouchinterest(touchParent, Char, 1)
    end
end

end

function __L.getNearestNPC(exclude)
    -- [FIX] The old body computed `hasPrompt` and then never used it (the
    -- `if not hasPrompt then if v:IsA("Model") and v.PrimaryPart then -- maybe
    -- check end end` block was dead), so the macro would walk to the nearest NPC
    -- even when its Sell prompt was missing or DISABLED. The Enabled flag is
    -- dynamic (NPC_12 was observed with Enabled = false while its neighbours were
    -- true), so this prefers the nearest NPC with an ENABLED prompt and only
    -- falls back to the nearest NPC at all when nobody is currently sellable,
    -- so it can never regress to returning nil where it used to return
    -- something.
    local Nearest, NearestAny = nil, nil
    local StartDist, StartAny = 1000, 1000
    local npcFolder = Workspace:FindFirstChild("NPCFolder")
    if not npcFolder then return nil end
    local hrp = HumanoidRootPart or (LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart"))
    if not hrp then return nil end
    for _, v in ipairs(npcFolder:GetChildren()) do
        if exclude and exclude[v] then continue end
        local pos = nil
        if v:IsA("Model") then
            pcall(function()
                pos = v:GetPivot().Position
            end)
        elseif v:IsA("BasePart") then
            pos = v.Position
        end
        if not pos then continue end
        local hasPrompt = false
        for _, desc in ipairs(v:GetDescendants()) do
            if desc:IsA("ProximityPrompt") and desc.Enabled then
                hasPrompt = true
                break
            end
        end
        local Distance = (hrp.Position - pos).Magnitude
        if hasPrompt and Distance < StartDist then
            StartDist  = Distance
            Nearest    = v
        end
        if Distance < StartAny then
            StartAny   = Distance
            NearestAny = v
        end
    end
    return Nearest or NearestAny
end

function __L.sellToNPC()
    if not Settings.Sell and not getgenv().FullAutoRunning and not getgenv().PCFullAutoRunning then return end
    if SellFrame and SellFrame.Visible then return end
    local now = tick()
    if now - (getgenv().SRS_LastSellToNPCT or 0) < 2.5 then return end
    local hrp = HumanoidRootPart or (LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart"))
    local hum = Humanoid or (LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid"))
    if not hrp or not hum then return end
    -- [FIX] Recover from a voided/falling character instead of letting it fall
    -- forever (or teleporting to NPCs that were flung out with it). The store
    -- island is well within 2,000 studs; y<-200 means we are under the map.
    if (hrp.Position - Vector3.new(-318, 100, 370)).Magnitude > 2000 or hrp.Position.Y < -200 then
        LogEvent("Recover", "sellToNPC: character voided at " .. tostring(hrp.Position) .. " -> respawn")
        pcall(function() hum.Health = 0 end)
        deltaWait(2)
        return
    end
    local maxAttempts = 4
    local unreachable = {} -- v4: NPCs whose walk failed this call; try the next nearest one
    for attempt = 1, maxAttempts do
        local NPC = __L.getNearestNPC(unreachable)
        if not NPC and next(unreachable) ~= nil then
            unreachable = {}
            NPC = __L.getNearestNPC(unreachable)
        end
        if not NPC then deltaWait(1); continue end
        local ok_pivot, pivot = pcall(function() return NPC:GetPivot().Position end)
        if not ok_pivot then deltaWait(1); continue end
        -- [FIX] NPC pivots are at their feet and their floor is at pivot.Y.
        -- The old player-Y target pointed into the upper ledge/wall; subtracting
        -- another 2.5 put the goal underground, so the walker never found a path.
        local targetPos = Vector3.new(pivot.X, pivot.Y, pivot.Z)
        -- Never chase an NPC that has been flung out of the map: teleporting to
        -- it would put the character in the void (and can trip server kicks).
        if (pivot - hrp.Position).Magnitude > 2000 then
            unreachable[NPC] = true
            LogEvent("SellWalk", "ignoring far/void sell NPC " .. tostring(NPC.Name) .. " d=" .. math.floor((pivot - hrp.Position).Magnitude))
            deltaWait(0.2)
            continue
        end
        -- [FIX] Prefer an ENABLED prompt, and when this NPC has no usable prompt
        -- at all, mark it unreachable. Previously a prompt-less nearest NPC was
        -- handed back by getNearestNPC on all four attempts in a row (because
        -- `unreachable` was never set here), so a whole sell pass could burn
        -- without the sell bar ever opening. A disabled prompt is still used as
        -- a last resort so a momentarily-disabled vendor is not skipped.
        local Proximity, fallbackPrompt = nil, nil
        for _, desc in ipairs(NPC:GetDescendants()) do
            if desc:IsA("ProximityPrompt") then
                if desc.Enabled then Proximity = desc; break end
                fallbackPrompt = fallbackPrompt or desc
            end
        end
        if not Proximity and not fallbackPrompt then
            unreachable[NPC] = true
            deltaWait(0.5)
            continue
        end
        Proximity = Proximity or fallbackPrompt
        -- [FIX] I-009: stand INSIDE the prompt's activation radius. The old
        -- clickRange = maxD + 3 walked the character OUTSIDE MaxActivationDistance
        -- (10 for every sell vendor) and only gave up past maxD * 2 (26 studs),
        -- so fireproximityprompt ran in range-limbo (11..26 studs), silently did
        -- nothing, and the sell bar never opened — the character just stood at
        -- the vendor ("stops moving ... does not open the sell gui"). UseDoor
        -- already uses maxD - 2; here walk to maxD - 3 and gate at the true
        -- activation distance, so a walk that ends short is retried on another
        -- vendor instead of firing out of range.
        local okRange, maxD = pcall(function() return Proximity.MaxActivationDistance end)
        local clickRange = math.max(6, tonumber(okRange and maxD) or 10)
        local walkReach  = math.max(3, clickRange - 3)
        local goalFlat = Vector3.new(targetPos.X - hrp.Position.X, 0, targetPos.Z - hrp.Position.Z)
        local walkReached = nil
        if goalFlat.Magnitude > walkReach then
            getgenv().SRS_LastSellToNPCT = now
            local okWalk, res = pcall(function()
                return SmartWalkTo(targetPos, function()
                    return (Settings.Sell or getgenv().FullAutoRunning or getgenv().PCFullAutoRunning)
                        and srsAlive() and not (SellFrame and SellFrame.Visible)
                end, { reach = walkReach, maxTime = 15 })
            end)
            walkReached = okWalk and res or false
        end
        -- Firing a prompt out of its activation range is a silent miss, and the
        -- caller's loop would just walk again — the back-and-forth the walker is
        -- known for. Re-check range after the walk before clicking.
        local distNow = Vector3.new(targetPos.X - hrp.Position.X, 0, targetPos.Z - hrp.Position.Z).Magnitude
        if distNow > clickRange then
            -- [FIX] The route from the store floor to the NPC row stalls the
            -- walker (navmesh gap at the doorway). Nudge to the vendor, then
            -- re-check: the green-bar prompt only fires inside MaxActivationDistance.
            local away = Vector3.new(hrp.Position.X - targetPos.X, 0, hrp.Position.Z - targetPos.Z)
            if away.Magnitude < 0.1 then away = Vector3.new(0, 0, 1) end
            -- Stand well clear of the rig: teleporting on top of an unanchored
            -- NPC knocks it (and sometimes the player) into the void.
            local stand = Vector3.new(targetPos.X + away.Unit.X * 6.5, pivot.Y + 3, targetPos.Z + away.Unit.Z * 6.5)
            hrp.CFrame = CFrame.new(stand.X, stand.Y, stand.Z)
            hrp.AssemblyLinearVelocity = Vector3.zero
            deltaWait(1.5)
            distNow = Vector3.new(targetPos.X - hrp.Position.X, 0, targetPos.Z - hrp.Position.Z).Magnitude
            LogEvent("SellWalk", "nudged to sell NPC " .. tostring(NPC.Name) .. " dist=" .. math.floor(distNow) .. " walk=" .. tostring(walkReached))
        end
        if distNow > clickRange then
            unreachable[NPC] = true
            -- [DIAG] Enough evidence to tell the exits apart next time: walk=false
            -- with hp>0 and a live flag means walkCore bailed before moving (dead
            -- character, or keepGoing() false), not that the NPC is unreachable.
            LogEvent("SellWalk", "could not reach sell NPC " .. tostring(NPC.Name)
                .. " (" .. math.floor(distNow) .. " studs away, need<" .. math.floor(clickRange)
                .. ", hp=" .. tostring(math.floor((hum and hum.Health) or -1))
                .. ", sell=" .. tostring(Settings.Sell)
                .. ", fa=" .. tostring(getgenv().FullAutoRunning)
                .. ", pcfa=" .. tostring(getgenv().PCFullAutoRunning)
                .. ", walk=" .. tostring(walkReached) .. ") - trying another")
            deltaWait(0.5)
            -- try again with fresh NPC
            continue
        end
        getgenv().SRS_LastSellToNPCT = now
        -- [FIX] Legit look: glide the drawn cursor onto the vendor as we press
        -- its prompt (the prompt itself is still fired server-side).
        if Helpers.focusSellNPC then pcall(Helpers.focusSellNPC, NPC) end
        local okFire, fireErr = pcall(fireproximityprompt, Proximity)
        LogEvent("SellWalk", "fired sell prompt " .. tostring(NPC.Name) .. " ok=" .. tostring(okFire) .. " err=" .. tostring(fireErr))
        -- Hold position while the bar opens; only walk again if it never comes up.
        local openedAt = tick()
        local checkInterval = 0.15
        while tick() - openedAt < 5.0 do
            deltaWait(checkInterval)
            if SellFrame and SellFrame.Visible then
                LogEvent("SellWalk", "sell bar opened by " .. tostring(NPC.Name))
                return
            end
        end
    end
    warn("[SELL] No NPC opened the sell bar this pass — trying again next cycle")
end

local function getStore()
    local stores = Workspace:FindFirstChild("Stores")
    if not stores then return nil end
    return stores:FindFirstChild(LocalPlayer.Name .. "Store")
end

local Store = getStore()
safeSpawn(function()
    while not Store and srsAlive() do deltaWait(.5); Store = getStore() end
end)

getgenv().TotalMoneySpent   = 0
getgenv().TotalMoneyEarned  = 0
getgenv().ShoesBought       = 0
getgenv().TreasuresBought   = 0
getgenv().ShoesSold         = 0
getgenv().MoneyAtCycleStart = 0
getgenv().PassiveIncome     = 0
getgenv().ScriptIncomeWindow = 0
getgenv().SRS_PeakMoney     = 0

local lastKnownMoney = 0
local trackingActive = false

local function getMoney()
    local ls = LocalPlayer:FindFirstChild("leaderstats")
    if not ls then return 0 end
    local money = ls:FindFirstChild("Money")
    if not money then return 0 end
    return tonumber(money.Value) or 0
end

function __L.onMoneyChanged(newValue)
    if not trackingActive then lastKnownMoney = newValue; return end
    local diff = newValue - lastKnownMoney
    if diff < 0 then
        getgenv().TotalMoneySpent = getgenv().TotalMoneySpent + math.abs(diff)
    elseif diff > 0 then
        if lastKnownMoney == 0
            and (getgenv().TotalMoneySpent or 0) == 0
            and (getgenv().TotalMoneyEarned or 0) == 0
            and (getgenv().PassiveIncome or 0) == 0
            and tick() > (getgenv().ScriptIncomeWindow or 0) then
            -- 0 -> balance jump with nothing done yet: the game is still loading
            -- the stat, so this is the starting balance, not income.
            getgenv().MoneyAtSessionStart = newValue
        elseif tick() <= (getgenv().ScriptIncomeWindow or 0) then
            getgenv().TotalMoneyEarned = getgenv().TotalMoneyEarned + diff
            getgenv().ScriptIncomeWindow = 0
        else
            getgenv().PassiveIncome = getgenv().PassiveIncome + diff
        end
    end
    lastKnownMoney = newValue
end

function __L.hookMoneyValue()
    getgenv().SRS_MoneyReady = false
    local ls = LocalPlayer:WaitForChild("leaderstats", 10)
    if not ls then getgenv().SRS_MoneyReady = true; return end
    local moneyVal = ls:WaitForChild("Money", 10)
    if not moneyVal then getgenv().SRS_MoneyReady = true; return end
    lastKnownMoney = moneyVal.Value
    -- Connect first so nothing is missed while we wait for the balance to settle.
    moneyVal:GetPropertyChangedSignal("Value"):Connect(function()
        if not srsAlive() then return end
        __L.onMoneyChanged(moneyVal.Value)
    end)
    -- Settle: wait until the balance is non-zero and unchanged for ~0.6s
    -- (or give up after 8s: the balance really is 0).
    local started, lastChange, seen = tick(), tick(), moneyVal.Value
    while srsAlive() and tick() - started < 8 do
        local v = moneyVal.Value
        if v ~= seen then seen = v; lastChange = tick() end
        if v > 0 and tick() - lastChange >= 0.6 then break end
        task.wait(0.1)
    end
    lastKnownMoney = moneyVal.Value
    getgenv().MoneyAtSessionStart = moneyVal.Value
    trackingActive = true
    getgenv().SRS_MoneyReady = true
end

safeSpawn(__L.hookMoneyValue)

-- ── Number formatter ───────────────────────────────────────────────────────
local function fmtNum(n)
    n = math.floor(tonumber(n) or 0)
    local s = tostring(math.abs(n))
    local result = ""
    local len = #s
    for i = 1, len do
        if i > 1 and (len - i + 1) % 3 == 0 then
            result = result .. ","
        end
        result = result .. s:sub(i, i)
    end
    return (n < 0 and "-" or "") .. result
end

local function fmtMoney(n)
    return "$" .. fmtNum(n)
end



-- ── SakuraUI Window ─────────────────────────────────────────────────────
-- Library.new(title, configFolder): config persistence stays disabled —
-- the flag save/load cycle is removed so nothing is written to configs.
Window = Library.new("SRS V7 | by Sakura", "SRS_Hub")
-- Compact default size, scaled to the screen; Resize() also clamps to the viewport.
pcall(function()
    local cam = workspace.CurrentCamera
    local vp = cam and cam.ViewportSize or Vector2.new(1280, 720)
    local w = math.clamp(math.floor(vp.X * 0.5), 520, 640)
    local h = math.clamp(math.floor(vp.Y * 0.6), 340, 460)
    Window:Resize(UDim2.fromOffset(w, h))
end)
-- Force the top-bar Settings button to the gear icon — applies even when a stock
-- fallback build (obfuscated/HTTP) loads instead of the customized local build
pcall(function()
    if Window.topBar then
        local settingsButton = Window.topBar:FindFirstChild("Settings")
        if settingsButton then settingsButton.Image = "rbxassetid://10734950309" end
    end
end)
-- Apply saved "main" UI preset (accent/blossoms/transparency) — no-op if not present
pcall(function()
    Window:_LoadUIPreset("main")
end)
-- SakuraUI's built-in window toggle keybind defaults to RightControl.
Window:SetToggleKey(Enum.KeyCode.K)


-- ── Consolidated state table (avoids local register overflow) ─────────────
local State = {
    -- Movement
    Flying           = false,
    InfJump          = false,
    Noclip           = false,
    FlySpeed         = 50,
    WalkSpeed        = 16,
    noclipConnection = nil,
    -- Full Auto threads
    fullAutoThread   = nil,
    farmThread       = nil,
    riskFarmThread   = nil,
    shoeAppThread    = nil,
    pcAutoBuyThread  = nil,
    pcFullAutoThread = nil,
    -- Full Auto state
    fullAutoRunning      = false,
    fullAutoSpeed        = "slow",
    fullAutoSwitching    = false,
    -- PC Auto Buy state
    pcAutoBuyRunning  = false,
    pcAutoBuySpeed    = "slow",
    pcSwitching       = false,
    -- PC Full Auto state
    pcFullAutoRunning     = false,
    pcFullAutoSpeed       = "slow",
    pcFullAutoSwitching   = false,
    -- Dig state
    farming       = false,
    riskFarming   = false,
    digSpeed      = "medium",
    riskDigSpeed  = "risky_medium",
    selectedLevel = "Level1",
    -- Sell bar
    sellBarConnection = nil,
    sellBarCooldown   = false,
    -- Fire-gate invariant: stop-fire only when CurrentPage == this (last
    -- successfully parked best-stocked shoe). nil = bar hidden / no park yet.
    sellCarouselParkedName = nil,
    sellCarouselRetryScheduled = false,
    -- Shoe App
    shoeAppBuying        = false,
    shoeAppSessionBought = 0,
    shoeAppWatcherRunning = false,
    shoeAppWatcherThread  = nil,
    -- Remote fail tracking
    remoteFailCount = 0,
    -- Periodic stats
    periodicStatsThread    = nil,
    periodicStatsRunning   = false,
    periodicIntervalMinutes = 10,
    alivePingMinutes       = 60,
    -- Heartbeat
    lastHeartbeat    = 0,
    heartbeatAlerted = false,
    -- FPS
    frameCount  = 0,
    lastFPSTime = 0,
    currentFPS  = 0,
}

-- ── Consolidated toggle table ──────────────────────────────────────────────
local Toggles = {
    SlowAutoBuy    = nil,
    MediumAutoBuy  = nil,
    FastAutoBuy    = nil,
    SlowRiskyBuy   = nil,
    MediumRiskyBuy = nil,
    FastRiskyBuy   = nil,
    AutoSell       = nil,
    SlowFullAuto   = nil,
    MediumFullAuto = nil,
    FastFullAuto   = nil,
    RiskySlowFullAuto = nil,
    RiskyMediumFullAuto = nil,
    RiskyFastFullAuto = nil,
    SlowPCAutoBuy    = nil,
    MediumPCAutoBuy  = nil,
    FastPCAutoBuy    = nil,
    SlowPCFullAuto   = nil,
    MediumPCFullAuto = nil,
    FastPCFullAuto   = nil,
    RiskySlowPCAutoBuy    = nil,
    RiskyMediumPCAutoBuy  = nil,
    RiskyFastPCAutoBuy    = nil,
    RiskySlowPCFullAuto   = nil,
    RiskyMediumPCFullAuto = nil,
    RiskyFastPCFullAuto   = nil,
    HumanSlowAutoBuy      = nil,
    HumanMediumAutoBuy    = nil,
    HumanFastAutoBuy      = nil,
    HumanSlowFullAuto     = nil,
    HumanMediumFullAuto   = nil,
    HumanFastFullAuto     = nil,
    HumanSlowPCAutoBuy    = nil,
    HumanMediumPCAutoBuy  = nil,
    HumanFastPCAutoBuy    = nil,
    HumanSlowPCFullAuto   = nil,
    HumanMediumPCFullAuto = nil,
    HumanFastPCFullAuto   = nil,
    AutoUnlock       = nil,
    AutoRedeemQuests = nil,
    SlowWalkDig      = nil,
    MediumWalkDig    = nil,
    FastWalkDig      = nil,
    SlowRiskDig      = nil,
    MediumRiskDig    = nil,
    FastRiskDig      = nil,
}

-- Every automation start turns off every other automation toggle (dig speeds,
-- risky dig, auto buys, risky buys, auto sell, full auto, PC buys, PC full
-- auto). The FullAutoSwitching guard stops the Set(false) cascade from
-- double-tearing-down loops while sibling toggles are switched off.
local AUTOMATION_TOGGLE_KEYS = {
    "SlowWalkDig", "MediumWalkDig", "FastWalkDig",
    "SlowRiskDig", "MediumRiskDig", "FastRiskDig",
    "SlowAutoBuy", "MediumAutoBuy", "FastAutoBuy",
    "SlowRiskyBuy", "MediumRiskyBuy", "FastRiskyBuy",
    "HumanSlowAutoBuy", "HumanMediumAutoBuy", "HumanFastAutoBuy",
    "AutoSell",
    "LimitedShopWatch", "LimitedShopBuy",
    "SlowFullAuto", "MediumFullAuto", "FastFullAuto",
    "RiskySlowFullAuto", "RiskyMediumFullAuto", "RiskyFastFullAuto",
    "HumanSlowFullAuto", "HumanMediumFullAuto", "HumanFastFullAuto",
    "SlowPCAutoBuy", "MediumPCAutoBuy", "FastPCAutoBuy",
    "SlowPCFullAuto", "MediumPCFullAuto", "FastPCFullAuto",
    "RiskyFastFullAuto",
    "RiskySlowPCAutoBuy", "RiskyMediumPCAutoBuy", "RiskyFastPCAutoBuy",
    "RiskySlowPCFullAuto", "RiskyMediumPCFullAuto", "RiskyFastPCFullAuto",
    "HumanSlowPCAutoBuy", "HumanMediumPCAutoBuy", "HumanFastPCAutoBuy",
    "HumanSlowPCFullAuto", "HumanMediumPCFullAuto", "HumanFastPCFullAuto",
    "MacroRun", "AutoUpgradeStore", "DoEverything",
    "ArcadeBasketball", "ArcadeBoxing",
}

local function cancelOtherAutomation(caller)
    -- The Macro lives in a sub-page that is rebuilt on every page switch, so its
    -- toggle handle can be stale: stop it directly, not only through the toggle.
    if Helpers.Macro and Helpers.Macro.Running and caller ~= Toggles.MacroRun then
        pcall(Helpers.Macro.stop, true)
    end
    if caller == nil or caller ~= Toggles.AutoUpgradeStore then
        if Settings.Buttons and Helpers.Upg then Helpers.Upg.stop() end
    end
    local isRiskDigCaller = caller ~= nil and (caller == Toggles.SlowRiskDig
        or caller == Toggles.MediumRiskDig or caller == Toggles.FastRiskDig)
    if State.riskFarming and Helpers.stopRiskDig and not isRiskDigCaller then
        pcall(Helpers.stopRiskDig)
    end
    getgenv().FullAutoSwitching = true
    for i = 1, #AUTOMATION_TOGGLE_KEYS do
        local t = Toggles[AUTOMATION_TOGGLE_KEYS[i]]
        if t and t ~= caller and t.Set then
            pcall(t.Set, t, false)
        end
    end
    getgenv().FullAutoSwitching = false
end

local BLToggles = {}

getgenv().FullAutoSwitching  = false
getgenv().ScriptShuttingDown = false
getgenv().PCFullAutoRunning  = false

local NoclippedParts = {}

function __L.clearNoclippedParts()
    for part in pairs(NoclippedParts) do
        if part and part.Parent then
            pcall(function() part.CanCollide = true end)
        end
    end
    NoclippedParts = {}
end

function __L.applyNoclipToCharacter()
    local char = LocalPlayer.Character
    if not char then return end
    for _, Part in ipairs(char:GetDescendants()) do
        if Part:IsA("BasePart") and Part.CanCollide then
            NoclippedParts[Part] = true
            Part.CanCollide = false
        end
    end
end

function __L.EnableNoclip()
    if State.noclipConnection then State.noclipConnection:Disconnect() end
    __L.applyNoclipToCharacter()
    State.noclipConnection = RunService.Stepped:Connect(function()
        if not srsAlive() then return end
        if State.Noclip and LocalPlayer.Character then
            for _, Part in ipairs(LocalPlayer.Character:GetDescendants()) do
                if Part:IsA("BasePart") and Part.CanCollide then
                    NoclippedParts[Part] = true
                    Part.CanCollide = false
                end
            end
        end
    end)
end

function __L.DisableNoclip()
    if State.noclipConnection then State.noclipConnection:Disconnect(); State.noclipConnection = nil end
    __L.clearNoclippedParts()
end

LocalPlayer.CharacterRemoving:Connect(function() if srsAlive() then __L.clearNoclippedParts() end end)

-- ── Tabs ──────────────────────────────────────────────────────────────────
-- SakuraUI nests tabs inside window sections: Window:CreateSection → :CreateTab.
-- Modes that belong together share ONE tab and live as sub-pages swapped by the
-- dropdown pinned at the top of that tab (page-in-a-page). Modes that carry
-- explicit ban risk keep their own clearly-labeled tab instead of being buried
-- in a dropdown. The SubPages:Nav dropdown restores its last pick from FlagValues
-- so the rebuild never resets the user's selection.
local WindowSections = {
    Buying   = Window:CreateSection("Buying"),
    AutoDig  = Window:CreateSection("Auto Dig"),
    Settings = Window:CreateSection("Settings"),
}

local Tabs = {
    AutoBuy   = WindowSections.Buying:CreateTab("Auto Buy",   "85262178816537"),    -- lucide circle-check — verified 420px render
    PCAuto    = WindowSections.Buying:CreateTab("PC",         "124870886755485"),    -- lucide/gravity shopping-cart — verified 420px render
    ShoeApp   = WindowSections.Buying:CreateTab("Shoe App",   "71885477293226"),     -- lucide/gravity shopping-bag — verified 420px render
    -- [LOGUPG] Limited Shop tab (new). The live drop logs show the game's limited
    -- restock in workspace.LimitedShop.Boxes.BoxN.HoldPart.BuyPrompt; the macro
    -- had no handling for it. Populated at the end of bootScript().
    LimitedShop = WindowSections.Buying:CreateTab("Limited Shop", "83898160590116"),
    -- Arcade: the store's own Boxing/Basketball minigames + the Arcade Prize
    -- shop (Tickets). Self-contained (built after bootScript), so this costs no
    -- registers on the main body.
    Arcade    = WindowSections.Buying:CreateTab("Arcade", "82714530610376"),
    Risky     = WindowSections.Buying:CreateTab("Risky",      "83898160590116"),     -- lucide circle-alert — verified 420px render
    Halloween = WindowSections.Buying:CreateTab("Halloween", "120318414957104"),  -- Halloween event: boxes + skeleton trade-in
    AutoDig   = WindowSections.AutoDig:CreateTab("Auto Dig",  "82714530610376"),     -- lucide/gravity solid star — verified 420px render
    DigDash   = WindowSections.AutoDig:CreateTab("Dig Dashboard", "10734943674"),    -- SakuraUI target/magnify icon
    Dashboard = WindowSections.Settings:CreateTab("Dashboard", "120318414957104"),   -- lucide/gravity star-in-circle — verified 420px render
    Blacklist = WindowSections.Settings:CreateTab("Blacklist", "10723356507"),       -- SakuraUI save/doc icon
    Webhook   = WindowSections.Settings:CreateTab("Webhook",   "10709775704"),       -- SakuraUI check/bell icon
    Stability = WindowSections.Settings:CreateTab("Stability", "93898873302694"),    -- lucide check — verified 420px render
    Quests    = WindowSections.Settings:CreateTab("Quests",    "120318414957104"),   -- lucide/gravity star-in-circle
    Info      = WindowSections.Settings:CreateTab("Info",      "119045069462549"),   -- lucide/gravity solid bag — verified 420px render
}
-- ── Icon guarantee ───────────────────────────────────────────────────────
-- Re-applies every tab icon, resolves Decal IDs to their Image, and swaps in a
-- bundled icon if an ID fails to load, so a tab can never end up blank.
do
    local ICONS = {
        AutoBuy="85262178816537", PCAuto="124870886755485", ShoeApp="71885477293226",
        LimitedShop="83898160590116", Arcade="82714530610376", Risky="83898160590116",
        AutoDig="82714530610376", DigDash="10734943674",
        Dashboard="120318414957104", Blacklist="10723356507", Webhook="10709775704",
        Stability="93898873302694", Quests="120318414957104", Info="119045069462549",
    }
    local FALLBACKS = { "10709775704", "10747384394", "10734950309", "10723356507" }
    local n = 0
    for key, id in pairs(ICONS) do
        n = n + 1
        local tab = Tabs[key]
        local img = tab and tab.icon
        if img then
            local fb = "rbxassetid://" .. FALLBACKS[(n % #FALLBACKS) + 1]
            pcall(function() img.Image = "rbxassetid://" .. id end)
            task.spawn(function()
                local good = false
                pcall(function()
                    game:GetService("ContentProvider"):PreloadAsync({ img })
                    good = img.IsLoaded == true
                end)
                if not good then
                    -- maybe a Decal ID: unwrap to its Texture
                    pcall(function()
                        local objs = game:GetObjects("rbxassetid://" .. id)
                        local d = objs and objs[1]
                        if d and d:IsA("Decal") and d.Texture ~= "" then
                            img.Image = d.Texture
                            game:GetService("ContentProvider"):PreloadAsync({ img })
                            good = img.IsLoaded == true
                        end
                    end)
                end
                if not good then pcall(function() img.Image = fb end) end
            end)
        end
    end
end
local AutoDigTab        = Tabs.AutoDig

-- ── Sub-page manager ─────────────────────────────────────────────────────
local SubPages = { pool = {}, activeTab = {} }

-- In-session value registry: keeps element values across sub-page rebuilds.
-- Gen2 re-registers duplicate flags with a numeric suffix, so a rebuilt
-- element can no longer restore from config — this mirrors V1's Flags table.
local FlagValues = {}

-- v4: "is the automation behind this toggle flag running RIGHT NOW?"
-- Sub-pages are destroyed and rebuilt every time you switch page, so a toggle
-- used to come back OFF even while its automation was still running. Every
-- rebuilt automation toggle now takes its state from this resolver (true /
-- false), or nil for flags that are not automations. Lives on Helpers so
-- bootScript() spends no registers on it.
Helpers.FLAG_SPEEDS = {
    Slow = "slow", Medium = "medium", Fast = "fast",
    RiskySlow = "risky_slow", RiskyMedium = "risky_medium", RiskyFast = "risky_fast",
    HumanSlow = "human_slow", HumanMedium = "human_medium", HumanFast = "human_fast",
}
Helpers.SEMI_BUY_FLAGS = {
    AutoBuySlow = "slow", AutoBuyMedium = "medium", AutoBuyFast = "fast",
    RiskySlowBuy = "risky_slow", RiskyMediumBuy = "risky_medium", RiskyFastBuy = "risky_fast",
    HumanSlowBuy = "human_slow", HumanMediumBuy = "human_medium", HumanFastBuy = "human_fast",
}
function Helpers.flagRunning(flag)
    if type(flag) ~= "string" then return nil end
    local G = getgenv()
    local S = G.Settings or {}
    local doEv = G.SRS_DoEverythingOn and true or false
    local ok, res = pcall(function()
        if flag == "DoEverything" then return (G.PCFullAutoRunning and doEv) and true or false end
        if flag == "MacroRun"     then return (Helpers.Macro and Helpers.Macro.Running) and true or false end
        if flag == "ArcadeBasketball" then return (Helpers.Arcade and Helpers.Arcade.running and Helpers.Arcade.mode == "basketball") and true or false end
        if flag == "ArcadeBoxing"     then return (Helpers.Arcade and Helpers.Arcade.running and Helpers.Arcade.mode == "boxing") and true or false end
        if flag == "AutoButtons"  then return S.Buttons and true or false end
        if flag == "AutoSell" then
            return (S.Sell and not (G.FullAutoRunning or G.PCFullAutoRunning
                or (Helpers.Macro and Helpers.Macro.Running))) and true or false
        end
        local semi = Helpers.SEMI_BUY_FLAGS[flag]
        if semi then
            return (S.Buy and S.Buy.Enabled and G.SRS_LastBuySpeed == semi
                and not (G.FullAutoRunning or G.PCFullAutoRunning or State.pcAutoBuyRunning
                    or (Helpers.Macro and Helpers.Macro.Running))) and true or false
        end
        local pre = flag:match("^(.-)PCFullAuto$")
        if pre ~= nil and Helpers.FLAG_SPEEDS[pre] then
            return (G.PCFullAutoRunning and not doEv and State.pcFullAutoSpeed == Helpers.FLAG_SPEEDS[pre]) and true or false
        end
        pre = flag:match("^(.-)PCAutoBuy$")
        if pre ~= nil and Helpers.FLAG_SPEEDS[pre] then
            return (State.pcAutoBuyRunning and State.pcAutoBuySpeed == Helpers.FLAG_SPEEDS[pre]) and true or false
        end
        pre = flag:match("^(.-)FullAuto$")
        if pre ~= nil and Helpers.FLAG_SPEEDS[pre] then
            return (G.FullAutoRunning and G.FullAutoSpeed == Helpers.FLAG_SPEEDS[pre]) and true or false
        end
        pre = flag:match("^(.-)RiskDig$")
        if pre ~= nil and Helpers.FLAG_SPEEDS["Risky" .. pre] then
            return (State.riskFarming and State.riskDigSpeed == Helpers.FLAG_SPEEDS["Risky" .. pre]) and true or false
        end
        return nil
    end)
    if ok then return res end
    return nil
end

-- Maps Rayfield V1/Gen2 prop names to SakuraUI prop names.
-- SakuraUI: CurrentValue→Default; Range→Min/Max; CurrentOption→Default;
-- PlaceholderText→Placeholder; no Increment/Suffix/MultipleOptions/
-- RemoveTextAfterFocusLost support.
function __L.normalizeProps(method, props)
    if type(props) ~= "table" then return props end
    local p = table.clone(props)
    if method == "CreateToggle" then
        if p.CurrentValue ~= nil then
            p.Default = p.CurrentValue
            p.CurrentValue = nil
        end
    elseif method == "CreateSlider" then
        if p.Range then
            p.Min = p.Range[1]
            p.Max = p.Range[2]
            p.Range = nil
        end
        if p.CurrentValue ~= nil then
            p.Default = p.CurrentValue
            p.CurrentValue = nil
        end
        p.Increment = nil
        p.Suffix = nil
    elseif method == "CreateDropdown" then
        if p.CurrentOption ~= nil then
            p.Default = type(p.CurrentOption) == "table" and p.CurrentOption[1] or p.CurrentOption
            p.CurrentOption = nil
        end
        p.MultipleOptions = nil
    elseif method == "CreateTextBox" then
        if p.PlaceholderText ~= nil then
            p.Placeholder = p.PlaceholderText
            p.PlaceholderText = nil
        end
        p.RemoveTextAfterFocusLost = nil
    end
    local flag = p.flag or p.Flag
    if flag then
        if method == "CreateToggle" then
            -- v4: a rebuilt automation toggle shows what is REALLY running.
            local live = Helpers.flagRunning(flag)
            if live ~= nil then
                p.Default = live
                FlagValues[flag] = live
            elseif FlagValues[flag] ~= nil
                and (tostring(flag):sub(1, 4) == "Det_" or flag == "PeriodicStatsToggle" or flag == "NoclipToggle") then
                -- plain preference toggles built from a constant: keep the user's last pick
                p.Default = FlagValues[flag]
            end
        end
        if FlagValues[flag] ~= nil and p.Default == nil then
            p.Default = FlagValues[flag]
        end
        local cb = p.callback or p.Callback
        if cb then
            p.Callback = function(...)
                local v = (...)
                -- v4: creating a toggle with Default=true may echo its callback.
                -- During/just after a page build, ignore an echo that only repeats
                -- the state the automation is already in (it would restart it).
                if method == "CreateToggle" and SubPages._echoUntil and tick() < SubPages._echoUntil
                   and Helpers.flagRunning(flag) == v then
                    FlagValues[flag] = v
                    return
                end
                FlagValues[flag] = v
                return cb(...)
            end
            p.callback = nil
        end
    end
    return p
end

-- Status-row labels: plain transparent text rows (classic wall-of-text look).
-- SakuraUI's native CreateLabel renders a boxed component (frame + stroke +
-- corner), which comes out looking like Rayfield; the old GUI used raw text
-- rows. Game code calls handle:Set(...), so alias Set → Text.
local function createLabelShim(tab, text)
    -- Preferred: the library's quiet note card (8px corners + faint rail).
    -- Older SakuraUI copies fetched from GitHub have no CreateNote, so the
    -- original plain-text row is kept as a working fallback.
    if tab and type(tab.CreateNote) == "function" then
        local okNote, note = pcall(function()
            return tab:CreateNote({ Text = tostring(text or ""), RichText = true })
        end)
        if okNote and note then
            local handle = note
            if type(handle.Set) ~= "function" then handle.Set = handle.SetText end
            if type(handle.Remove) ~= "function" then handle.Remove = handle.Destroy end
            return handle
        end
        warn("[SRS][UI] CreateNote failed, using the plain label: " .. tostring(note))
    end

    local label = Instance.new("TextLabel")
    label.Name = "Label"
    label.Size = UDim2.new(1, 0, 0, 18)
    label.AutomaticSize = Enum.AutomaticSize.Y
    label.BackgroundTransparency = 1
    label.BorderSizePixel = 0
    label.Text = tostring(text or "")
    label.TextSize = 15
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.TextWrapped = true
    label.RichText = true
    label.TextColor3 = Color3.fromRGB(232, 234, 246)
    label.Parent = tab.content
    local handle = { Instance = label }
    handle.Set = function(_, v)
        pcall(function() label.Text = tostring(v) end)
    end
    handle.Destroy = function()
        pcall(function() if label.Parent then label:Destroy() end end)
    end
    handle.Remove = handle.Destroy
    return handle
end

-- Destroys every element the previous build of a sub-page created, while
-- keeping Arcylic's own layout instances (UIListLayout/UIPadding) alive —
-- destroying them collapses the content into an unlaid-out pile at the top.
function __L.clearTabPage(tabAPI)
    if not tabAPI or not tabAPI.content then return end
    for _, child in ipairs(tabAPI.content:GetChildren()) do
        if child:IsA("UIListLayout") or child:IsA("UIPadding") then continue end
        child:Destroy()
    end
end

-- Nav-state remembered from the last SubPages:Nav call, used as a safety net
-- so a partially-failed rebuild always restores the pill nav instead of
-- leaving the user stranded on a page with no way to switch sub-pages.
local navSafetyNet = {}

-- Internal: (re)paint the pill nav track for a tab. If the top-level build of
-- a sub-page either forgot to call SubPages:Nav or errored silently before it,
-- Show calls this with the saved nav options so the track is repainted from
-- the safety net — the user can never be stuck without navigation.
function __L.ensureNavTrack(tabKey, tabAPI, tAPI, pageCount, elements)
    local saved = navSafetyNet[tabKey]
    if not saved then return end

    -- Only repaint if this rebuild did NOT lay its own track: check for the
    -- SubPageTrack the Nav function creates.
    if tabAPI and tabAPI.content then
        for _, child in ipairs(tabAPI.content:GetChildren()) do
            if child.Name == "SubPageTrack" then
                return -- nav already present
            end
        end
    end

    -- No track survived the rebuild — repaint it from the saved options so
    -- the user keeps navigation even if the page build threw partway.
    local flag      = saved.flag
    local current   = FlagValues[flag]
    if current == nil then current = saved.default or saved.options[1] end
    SubPages:Nav(tAPI, {
        label   = saved.label,
        options = saved.options,
        flag    = flag,
        default = saved.default or saved.options[1],
    })
end

function SubPages:Register(name, tab, buildFn)
    self.pool[name] = { tab = tab, build = buildFn }
end

function SubPages:Show(name, ...)
    local page = self.pool[name]
    if not page then return end

    local tabKey = tostring(page.tab)
    local tabAPI = page.tab
    self._tabKey = tabKey

    -- Drop stale Toggles references from the previous sub-page so old handles
    -- are never used after their instances were destroyed.
    local prev = self.activeTab[tabKey]
    if prev and prev.elements then
        for _, staleEl in ipairs(prev.elements) do
            for tName, tVal in pairs(Toggles) do
                if tVal == staleEl then
                    Toggles[tName] = nil
                    break
                end
            end
        end
    end

    __L.clearTabPage(tabAPI)

    task.wait()

    local elements = {}
    local METHOD_ALIASES = {
        CreateInput = "CreateTextBox",
    }
    local function T(method, ...)
        local el
        method = METHOD_ALIASES[method] or method
        if method == "CreateLabel" then
            el = createLabelShim(tabAPI, select(1, ...))
        elseif method == "CreateParagraph" then
            el = tabAPI:CreateParagraph(select(1, ...))
        elseif method == "CreateSection" then
            local props = select(1, ...)
            el = tabAPI:CreateSection(type(props) == "string" and props or props.name)
        else
            el = tabAPI[method](tabAPI, __L.normalizeProps(method, select(1, ...)))
            if method == "CreateToggle" then
                -- Game code calls Toggles.X:Set(false); SakuraUI toggles expose SetValue.
                el.Set = el.SetValue
            end
        end
        table.insert(elements, el)
        return el
    end

    self._tab = tabAPI
    self._tabKey = tabKey

    -- Build through a protected call. If the page's build throws (a stale
    -- instance handle, a nil option, a SakuraUI method mismatch) we still
    -- (a) surface it to the console instead of dying silently ate one frame
    -- and (b) fall into ensureNavTrack below, which repaints the pill track
    -- from the last Nav() call so the user is never stranded without nav.
    self._echoUntil = tick() + 3
    local ok, err = pcall(page.build, T, elements, ...)
    self._echoUntil = tick() + 0.75
    if not ok then
        local msg = string.format(
            "[SRS][SubPages:%s] build failed: %s",
            tostring(name),
            tostring(err)
        )
        pcall(Log, "ERROR", msg)
    end

    -- Safety net: if this show never called SubPages:Nav (build returned
    -- early or threw before painting pills), repaint the pill track from the
    -- last saved nav state so navigation is always reachable.
    __L.ensureNavTrack(tabKey, tabAPI, T, 0, elements)
    self.activeTab[tabKey] = { elements = elements }
end

PageRefs = {}

-- Page-in-a-page navigation for merged tabs. Renders a modern segmented pill
-- bar pinned at the top of the tab; picking a pill rebuilds the tab through
-- SubPages:Show. SubPages:Show clears the tab content, so every sub-page
-- build must call SubPages:Nav first or the user loses navigation.
function SubPages:Nav(T, opts)
    local tabAPI = self._tab
    if not (tabAPI and tabAPI.content) then return end

    local options = opts.options or {}
    local current = FlagValues[opts.flag]
    if current == nil then current = opts.default or options[1] end
    local accent = (Window and Window._accent) or Color3.fromRGB(255, 95, 175)

    -- Preferred look: the library's own segmented control (boxed track with
    -- centered pills). Falls back to the hand-built pills below if unavailable.
    if tabAPI.CreateSegmented then
        navSafetyNet[self._tabKey or tabKey] = {
            label = opts.label, options = opts.options,
            flag = opts.flag, default = opts.default,
        }
        pcall(function()
            tabAPI:CreateSegmented({
                Options = options,
                Default = current,
                Callback = function(opt)
                    if tostring(opt) == tostring(FlagValues[opts.flag] == nil and current or FlagValues[opts.flag]) then return end
                    FlagValues[opts.flag] = opt
                    if opts.onPick then pcall(opts.onPick, opt) end
                    -- rebuild next frame: Show destroys the very bar that was clicked
                    task.defer(function() SubPages:Show(opt) end)
                end,
            })
        end)
        local made
        for _, child in ipairs(tabAPI.content:GetChildren()) do
            if child.Name:sub(1, 10) == "Segmented_" then made = child end
        end
        if made then
            made.Name = "SubPageTrack"
            if opts.hint then T("CreateLabel", opts.hint) end
            return
        end
    end

    local track = Instance.new("Frame")
    track.Name = "SubPageTrack"
    track.Size = UDim2.new(1, 0, 0, 38)
    track.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    track.BackgroundTransparency = 0.93
    track.BorderSizePixel = 0
    track.ClipsDescendants = true
    track.Parent = tabAPI.content

    local trackCorner = Instance.new("UICorner")
    trackCorner.CornerRadius = UDim.new(0, 10)
    trackCorner.Parent = track

    local trackStroke = Instance.new("UIStroke")
    trackStroke.Color = Color3.fromRGB(255, 255, 255)
    trackStroke.Transparency = 0.88
    trackStroke.Parent = track

    local layout = Instance.new("UIListLayout")
    layout.FillDirection = Enum.FillDirection.Horizontal
    layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
    layout.VerticalAlignment = Enum.VerticalAlignment.Center
    layout.Padding = UDim.new(0, 6)
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Parent = track

    -- Remember this nav state so ensureNavTrack (in SubPages:Show) can
    -- repaint the pill track even if a later sub-page build throws before
    -- it lays its own navigation.
    navSafetyNet[self._tabKey or tabKey] = {
        label   = opts.label,
        options = opts.options,
        flag    = opts.flag,
        default = opts.default,
    }

    for _, opt in ipairs(options) do
        local isActive = tostring(opt) == tostring(current)
        local pill = Instance.new("TextButton")
        pill.Name = "Pill_" .. tostring(opt):gsub("[^%w_]+", "_")
        pill.Size = UDim2.new(0, 0, 0, 26)
        pill.AutomaticSize = Enum.AutomaticSize.X
        pill.BackgroundColor3 = isActive and accent or Color3.fromRGB(255, 255, 255)
        pill.BackgroundTransparency = isActive and 0.08 or 1
        pill.BorderSizePixel = 0
        pill.AutoButtonColor = false
        pill.Text = tostring(opt)
        pill.TextColor3 = Color3.fromRGB(255, 255, 255)
        pill.TextTransparency = isActive and 0 or 0.45
        pill.TextSize = 15
        pill.Font = Enum.Font.GothamMedium
        pill.Parent = track

        local pad = Instance.new("UIPadding")
        pad.PaddingLeft = UDim.new(0, 14)
        pad.PaddingRight = UDim.new(0, 14)
        pad.Parent = pill

        local pillCorner = Instance.new("UICorner")
        pillCorner.CornerRadius = UDim.new(0, 7)
        pillCorner.Parent = pill

        if isActive then
            local pillStroke = Instance.new("UIStroke")
            pillStroke.Color = Color3.fromRGB(255, 255, 255)
            pillStroke.Transparency = 0.5
            pillStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
            pillStroke.Parent = pill
        else
            pill.MouseEnter:Connect(function()
                pill.BackgroundTransparency = 0.88
                pill.TextTransparency = 0.2
            end)
            pill.MouseLeave:Connect(function()
                pill.BackgroundTransparency = 1
                pill.TextTransparency = 0.45
            end)
        end

        pill.Activated:Connect(function()
            if opt == current then return end
            FlagValues[opts.flag] = opt
            if opts.onPick then opts.onPick(opt) end
            SubPages:Show(opt)
        end)
    end

    if opts.hint then T("CreateLabel", opts.hint) end
end

-- Safe stop-path toggle flip: rebuilt sub-pages destroy their element
-- instances, so a stop path must never touch a stale handle raw. Every
-- Toggles.X:Set(false) outside a pcall goes through this.
function safeSetToggle(name, value)
    local t = Toggles and Toggles[name]
    if not t then return end
    local fn = t.Set or t.SetValue
    if fn then pcall(fn, t, value) end
end

RawNotify({
    Title    = "Credits",
    Content  = "Script by Sakura",
    Duration = 6.5,
    Image    = "Heart",
})

local startTime = tick()

local function formatUptime(seconds)
    local days    = math.floor(seconds / 86400)
    local hours   = math.floor((seconds % 86400) / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    local secs    = math.floor(seconds % 60)
    return string.format("%dd %02dh %02dm %02ds", days, hours, minutes, secs)
end

function __L.getGamePing()
    local ok, ping = pcall(function()
        return game:GetService("Stats").Network.ServerStatsItem["Data Ping"]:GetValueString()
    end)
    return ok and ping or "N/A"
end

local alertCooldowns = {}
local function canAlert(key, cooldownSeconds)
    local now = tick()
    if alertCooldowns[key] and now - alertCooldowns[key] < cooldownSeconds then return false end
    alertCooldowns[key] = now
    return true
end

getgenv().DetectionToggles = {
    GameClose         = true,
    NetworkDisconnect = true,
    ScriptError       = true,
    HeartbeatTimeout  = true,
    FPSDrop           = true,
    PingSpike         = true,
    InventoryAnomaly  = true,
    AutoStall         = true,
    AlivePing         = true,
    MoneyStuck        = true,
    LeaderstatWipe    = true,
    GUIMissing        = true,
    RemoteFail        = true,
    ExecutorHealth    = true,
}

getgenv().WebhookURL = (savedData and savedData.WebhookURL) or ""

local WEBHOOK_COLOR = 0xFF00FF

-- ── Unified stats block ───────────────────────────────────────────────────
function __L.buildSessionStats()
    local money  = getMoney()
    local spent  = getgenv().TotalMoneySpent or 0
    local earned = getgenv().TotalMoneyEarned or 0
    local net    = earned + (getgenv().PassiveIncome or 0) - spent
    local netStr = net >= 0
        and ("+$" .. fmtNum(net))
        or  ("-$" .. fmtNum(math.abs(net)))
    local bought = getgenv().ShoesBought or 0
    local sold   = getgenv().ShoesSold   or 0

    return table.concat({
        "",
        "**——— Session Stats ———**",
        "**Player:**         " .. LocalPlayer.Name,
        "**Current Money:**  " .. fmtMoney(money),
        "**Total Spent:**    " .. fmtMoney(spent),
        "**Total Earned:**   " .. fmtMoney(earned),
        "**Passive Income:** " .. fmtMoney(getgenv().PassiveIncome or 0),
        "**Net Profit:**     " .. netStr,
        "**Shoes Bought:**   " .. fmtNum(bought),
        "**Shoes Sold:**     " .. fmtNum(sold),
        "**Ping:**           " .. __L.getGamePing() .. " ms",
        "**Uptime:**         " .. formatUptime(tick() - startTime),
        "",
        "🔗 **[Sakura's Socials](https://sakuras-hub.github.io/Sakuras-Hub/)**",
    }, "\n")
end

-- ── Dig-specific stats block (no Shoes Sold) ──────────────────────────────
function __L.buildDigSessionStats()
    local money     = getMoney()
    local spent     = getgenv().TotalMoneySpent or 0
    local earned    = getgenv().TotalMoneyEarned or 0
    local net       = earned + (getgenv().PassiveIncome or 0) - spent
    local netStr    = net >= 0
        and ("+$" .. fmtNum(net))
        or  ("-$" .. fmtNum(math.abs(net)))
    local treasures = getgenv().TreasuresBought or 0

    return table.concat({
        "",
        "**——— Session Stats ———**",
        "**Player:**            " .. LocalPlayer.Name,
        "**Current Money:**     " .. fmtMoney(money),
        "**Total Spent:**       " .. fmtMoney(spent),
        "**Total Earned:**      " .. fmtMoney(earned),
        "**Passive Income:**    " .. fmtMoney(getgenv().PassiveIncome or 0),
        "**Net Profit:**        " .. netStr,
        "**Treasures Bought:**  " .. fmtNum(treasures),
        "**Ping:**              " .. __L.getGamePing() .. " ms",
        "**Uptime:**            " .. formatUptime(tick() - startTime),
        "",
        "🔗 **[Sakura's Socials](https://sakuras-hub.github.io/Sakuras-Hub/)**",
    }, "\n")
end

local function postWebhook(username, title, description)
    if not getgenv().WebhookURL or getgenv().WebhookURL == "" then return end
    local data = HttpService:JSONEncode({
        username   = username,
        avatar_url = "https://i.imgur.com/NambJ9Q.gif",
        embeds = {{
            title       = tostring(title),
            description = tostring(description) .. __L.buildSessionStats(),
            color       = WEBHOOK_COLOR,
            footer      = { text = "SRS V7 by Sakura's Hub" },
            timestamp   = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        }},
    })
    pcall(function()
        request({ Url = getgenv().WebhookURL, Method = "POST",
            Headers = { ["Content-Type"] = "application/json" }, Body = data })
    end)
end

-- ── Dig-specific webhook poster (uses buildDigSessionStats) ───────────────
function __L.postDigWebhook(username, title, description)
    if not getgenv().WebhookURL or getgenv().WebhookURL == "" then return end
    local data = HttpService:JSONEncode({
        username   = username,
        avatar_url = "https://i.imgur.com/NambJ9Q.gif",
        embeds = {{
            title       = tostring(title),
            description = tostring(description) .. __L.buildDigSessionStats(),
            color       = WEBHOOK_COLOR,
            footer      = { text = "SRS V7 by Sakura's Hub" },
            timestamp   = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        }},
    })
    pcall(function()
        request({ Url = getgenv().WebhookURL, Method = "POST",
            Headers = { ["Content-Type"] = "application/json" }, Body = data })
    end)
end

function __L.sendCrashWebhook(reason, detail)
    postWebhook("SRS Detections | by Sakura's Hub", reason, "**Event:** " .. tostring(detail) .. "\n")
end

local function sendAlert(detectionKey, reason, detail)
    if not getgenv().DetectionToggles then return end
    if not getgenv().DetectionToggles[detectionKey] then return end
    __L.sendCrashWebhook(reason, detail)
end

function __L.sendWebhook(title, extraLines)
    local extra = extraLines and ("\n" .. extraLines .. "\n") or ""
    postWebhook("SRS Full Automation | by Sakura's Hub", title, extra)
end

function __L.sendAlivePing()
    postWebhook("SRS Alive Check | by Sakura's Hub", "Still Alive", "Bot is still running fine.\n")
end

function __L.sendPeriodicStats()
    postWebhook("SRS Stat Update | by Sakura's Hub", "Periodic Stats", "")
end

getgenv().FullAutoRunning = false
local fullAutoThread      = nil
getgenv().FullAutoSpeed   = "slow"

local function sellableInventoryCount()
    local inv = LocalPlayer:FindFirstChild("Inventory")
    if not inv then return 0 end
    local sellable = inv:FindFirstChild("SellableInventory")
    if not sellable then return 0 end
    -- [FIX] Count SHOES, not unique UI stacks. One stack can hold dozens of
    -- pairs, so the old #GetChildren() never reached the 50-pair sell cap.
    local total = 0
    for _, c in ipairs(sellable:GetChildren()) do
        local q = tonumber(c.Value)
        if q and q > 0 then
            total += q
        elseif q == nil then
            total += 1
        end
    end
    return total
end

local function inventoryIsEmpty()
    return sellableInventoryCount() == 0
end

-- Selling 1-2 shoes while cash is healthy is a waste of time (the buy phase
-- gave up for a reason unrelated to money). Loop straight back to buying.
local MIN_CASH_TO_SKIP_TINY_SELL  = 50000

function __L.shouldSkipSell()
    -- Always sell everything: leftover shoes are never skipped.
    return false
end

do
local function getSneakerPrice(sneakerData)
    return sneakerData.BuyPrice or sneakerData.MaxBuyPrice or 0
end

end

-- The module's MaxBuyPrice is NOT the PC's real offer price: module values are
-- $1-2450 while the PC charges up to ~$5.2M per offer (visible in the offer
-- slot's PriceText label). Affordability must be checked against the GUI price.
local offerSlotsFrame = nil
local offerFrameSearchTime = 0
local wsScanTime = 0

function __L.scanForOfferFrame(root, maxDepth)
    local frontier = { root }
    for depth = 1, maxDepth do
        local nextLevel = {}
        for _, inst in ipairs(frontier) do
            for _, child in ipairs(inst:GetChildren()) do
                if string.match(child.Name, "^Offer%d+$") then
                    return inst
                end
                if (child:IsA("GuiBase2d") or child:IsA("GuiBase3d")) and #nextLevel < 800 then
                    nextLevel[#nextLevel + 1] = child
                end
            end
        end
        frontier = nextLevel
    end
    return nil
end

function __L.findOfferSlotsFrame()
    local gui = LocalPlayer:FindFirstChild("PlayerGui")
    if gui then
        local f = __L.scanForOfferFrame(gui, 10)
        if f then return f end
    end
    local now = tick()
    if now - wsScanTime < 120 then return nil end
    wsScanTime = now
    local ws = game:GetService("Workspace")
    local scanned = 0
    for _, inst in ipairs(ws:GetDescendants()) do
        scanned += 1
        if scanned % 2000 == 0 then task.wait() end
        if inst:IsA("SurfaceGui") then
            local f = __L.scanForOfferFrame(inst, 6)
            if f then return f end
        end
    end
    return nil
end

local function getOfferSlotsFrame()
    if offerSlotsFrame and offerSlotsFrame.Parent then return offerSlotsFrame end
    local now = tick()
    if now - offerFrameSearchTime < 3 then return offerSlotsFrame end
    offerFrameSearchTime = now
    offerSlotsFrame = __L.findOfferSlotsFrame()
    return offerSlotsFrame
end

function __L.getOfferRealPrice(i)
    local frame = getOfferSlotsFrame()
    if not frame then return nil end
    local slot = frame:FindFirstChild("Offer" .. i)
    if not slot then return nil end
    -- Authoritative: the slot's SneakerPrice attribute is the real charge and
    -- never goes stale (the PriceText label keeps the previous offer's text).
    local okP, attrPrice = pcall(function() return slot:GetAttribute("SneakerPrice") end)
    if okP and type(attrPrice) == "number" and attrPrice > 0 then return attrPrice end
    for _, child in ipairs(slot:GetChildren()) do
        if (child:IsA("TextLabel") or child:IsA("TextButton"))
            and string.find(string.lower(child.Name), "price") then
            local digits = tostring(child.Text):gsub("%D", "")
            if digits ~= "" then return tonumber(digits) end
        end
    end
    return nil
end

-- Offers are unlocked progressively (PcProgressOffer). Buying a locked offer
-- always gets server-rejected, so skip them instead of wasting attempts.
function __L.getUnlockedOfferCount()
    -- Re-read: the server advances PcProgressOffer asynchronously; caching stale
    -- would make the unlock loop re-attempt the same offer forever.
    local val = LocalPlayer:FindFirstChild("PcProgressOffer")
        or (LocalPlayer:FindFirstChild("leaderstats") and LocalPlayer.leaderstats:FindFirstChild("PcProgressOffer"))
    if not val then return nil end
    return tonumber(val.Value) or 0
end

do
local priceInfoLogged = false
local priceScanLogged = false

local function logPriceScan()
    if priceScanLogged then return end
    priceScanLogged = true
    local entries = 0
    local function scanGui(root, depth)
        for _, inst in ipairs(root:GetChildren()) do
            local lower = string.lower(inst.Name)
            if string.find(lower, "offer") or string.find(lower, "price") or string.find(lower, "unlock") or string.find(lower, "buy") then
                if entries < 40 then
                    entries += 1
                    local txt = ""
                    if (inst:IsA("TextLabel") or inst:IsA("TextButton")) and inst.Text ~= "" then
                        txt = " text=" .. tostring(inst.Text)
                    end
                    LogEvent("PriceScan", inst:GetFullName() .. " <" .. inst.ClassName .. ">" .. txt)
                end
            end
            if (inst:IsA("GuiBase2d") or inst:IsA("GuiBase3d")) and depth < 12 then
                scanGui(inst, depth + 1)
            end
        end
    end
    local gui = LocalPlayer:FindFirstChild("PlayerGui")
    if gui then scanGui(gui, 0) end
    for _, inst in ipairs(game:GetService("Workspace"):GetDescendants()) do
        if inst:IsA("SurfaceGui") then scanGui(inst, 0) end
    end
    LogEvent("PriceScan", "scan complete: " .. entries .. " entries")
end

-- The PC's offer GUI may mount a moment after the script starts, so retry the
-- price read a few times before giving up; if it still never appears, dump
-- every Offer/Price-named GUI found so the real layout can be identified.
local function logPriceInfoOnce()
    if priceInfoLogged then return end
    priceInfoLogged = true
    local attempt = 0
    local function tryReport()
        local frame    = getOfferSlotsFrame()
        local p1, p2   = __L.getOfferRealPrice(1), __L.getOfferRealPrice(2)
        local unlocked = __L.getUnlockedOfferCount()
        if (frame and (p1 or p2)) or attempt >= 4 then
            warn("[PRICE] offers frame: " .. tostring(frame and frame:GetFullName() or "NOT FOUND")
                .. " | offer1/2 prices: " .. tostring(p1) .. ", " .. tostring(p2)
                .. " | unlocked offers: " .. tostring(unlocked))
            LogEvent("PriceInfo", "frame=" .. tostring(frame and frame.Name or "none")
                .. " prices=" .. tostring(p1) .. "," .. tostring(p2)
                .. " unlocked=" .. tostring(unlocked))
            if not frame or (not p1 and not p2) then logPriceScan() end
        else
            attempt += 1
            deltaWait(2)
            tryReport()
        end
    end
    safeSpawn(tryReport)
end



end

-- ── Rarity-priority ordering ────────────────────────────────────────────────
-- Buy order should follow value, not slot order: when money is limited the
-- best sneakers must be attempted first, otherwise budget drains on Commons.
local RARITY_RANK = {
    Common    = 1,
    Uncommon  = 2,
    Epic      = 3,
    Legendary = 4,
    Legacy    = 5,
    Special   = 6,
    Limited   = 7,
    Grail     = 8,
}

function __L.rarityRank(data)
    if not data then return 0 end
    return RARITY_RANK[data.Rarity] or 0
end

-- Bought-by-rarity dashboard counters (session-scoped; zeroed by Reset Session Stats)
getgenv().ShoesRarityBought = getgenv().ShoesRarityBought or {}
getgenv().trackBoughtRarity = function(data)
    local rarity = data and data.Rarity or "Common"
    local st = getgenv().ShoesRarityBought
    if st then st[rarity] = (st[rarity] or 0) + 1 end
end

function __L.sortOffersByRarity(items)
    local list = {}
    if type(items) ~= "table" then return list end
    for i, sneakerName in pairs(items) do
        table.insert(list, { i = i, name = sneakerName })
    end
    table.sort(list, function(a, b)
        local ra = __L.rarityRank(Sneakers[a.name])
        local rb = __L.rarityRank(Sneakers[b.name])
        if ra ~= rb then return ra > rb end
        return a.i < b.i
    end)
    return list
end

-- ── Auto-unlock helpers ─────────────────────────────────────────────────────
-- [FIX] Find the FIRST slot whose unlock frame is showing. That is the offer
-- the game's own UnlockButton handler is currently set up for (its price label
-- is u3[PcProgressOffer.Value]); later slots keep stale labels from earlier
-- progress states. Iterating from 1 keeps us on the correct one.
function __L.nextLockedUnlockButton()
    local slots = getOfferSlotsFrame()
    if not slots then return nil end
    for i = 1, 16 do
        local slot = slots:FindFirstChild("Offer" .. i)
        if slot then
            local uf = slot:FindFirstChild("UnlockFrame")
            if uf and uf.Visible then
                local btn = uf:FindFirstChild("UnlockButton")
                if btn and btn:IsA("TextButton") then
                    local priceLabel = uf:FindFirstChild("UnlockPrice")
                    local price = 0
                    if priceLabel then
                        -- NOTE: inner parens keep gsub's replacement count from
                        -- being passed to tonumber as a base (would return nil).
                        price = tonumber((tostring(priceLabel.Text or ""):gsub("%D", ""))) or 0
                    end
                    return btn, i, price
                end
            end
        end
    end
    return nil
end



function __L.scrollIntoView(btn)
    local frame = btn:FindFirstAncestorOfClass("ScrollingFrame")
    if not frame then return end
    local top = frame.AbsolutePosition.Y
    local bottom = top + frame.AbsoluteSize.Y
    local btnTop = btn.AbsolutePosition.Y
    local btnBottom = btnTop + btn.AbsoluteSize.Y
    if btnTop >= top and btnBottom <= bottom then return end
    local dy = 0
    if btnTop < top then dy = btnTop - top - 4 end
    if btnBottom > bottom then dy = btnBottom - bottom + 4 end
    pcall(function()
        frame.CanvasPosition = Vector2.new(frame.CanvasPosition.X, math.max(0, frame.CanvasPosition.Y + dy))
    end)
    deltaWait(0.3)
end

function __L.clickGuiButton(btn)
    if not btn then return false end
    __L.scrollIntoView(btn)
    local ok = pcall(function()
        -- Some shop controls ignore synthetic mouse events and only respond when
        -- their signals are fired (the sell bar's Stop button proved this), so
        -- fire every click signal the game might listen to, then the mouse event.
        if btn.MouseButton1Down  then pcall(function() firesignal(btn.MouseButton1Down) end) end
        if btn.MouseButton1Up    then pcall(function() firesignal(btn.MouseButton1Up) end) end
        if btn.MouseButton1Click then pcall(function() firesignal(btn.MouseButton1Click) end) end
        if btn.Activated         then pcall(function() firesignal(btn.Activated) end) end
        local pos    = btn.AbsolutePosition
        local size   = btn.AbsoluteSize
        local centre = Vector2.new(pos.X + size.X / 2, pos.Y + size.Y / 2)
        local VIM    = game:GetService("VirtualInputManager")
        VIM:SendMouseButtonEvent(centre.X, centre.Y, 0, true,  game, 1)
        VIM:SendMouseButtonEvent(centre.X, centre.Y, 0, false, game, 1)
    end)
    return ok
end

function __L.findBuyButton(i)
    local slots = getOfferSlotsFrame()
    if not slots then return nil end
    local slot = slots:FindFirstChild("Offer" .. i)
    if not slot then return nil end
    local btn = nil
    for _, desc in ipairs(slot:GetDescendants()) do
        if desc:IsA("TextButton") and tostring(desc.Name):lower():find("buy") then
            btn = desc
            break
        end
    end
    if not btn then
        for _, desc in ipairs(slot:GetDescendants()) do
            if desc:IsA("TextButton") and not tostring(desc.Name):lower():find("unlock") then
                btn = desc
                break
            end
        end
    end
    return btn
end

local function connCount(sig)
    local ok, conns = pcall(function() return getconnections(sig) end)
    if ok and conns then return #conns end
    return -1
end

function __L.slotClickSignals(desc)
    if not (desc:IsA("TextButton") or desc:IsA("ImageButton")) then return "" end
    return "conns(d/u/c/a)=" .. connCount(desc.MouseButton1Down) .. "/" .. connCount(desc.MouseButton1Up) .. "/" .. connCount(desc.MouseButton1Click) .. "/" .. connCount(desc.Activated)
end

local dumpedOffers = {}

function __L.dumpOfferStructure(i)
    -- One-time dump of a slot's full layout: every control, its visibility,
    -- text, and which click signals the game listens to. The shop UI is
    -- obfuscated, so this is the only way to identify the real buy control.
    if dumpedOffers[i] then return end
    dumpedOffers[i] = true
    local slots = getOfferSlotsFrame()
    if not slots then
        LogEvent("ShopDump", "Offer" .. i .. " | frame NOT FOUND")
        return
    end
    local slot = slots:FindFirstChild("Offer" .. i)
    if not slot then return end
    local exist = {}
    for s = 1, 16 do
        if slots:FindFirstChild("Offer" .. s) then table.insert(exist, s) end
    end
    local parts = { "slots=" .. table.concat(exist, ","), slot.ClassName .. " " .. slot.Name }
    for _, desc in ipairs(slot:GetDescendants()) do
        if not (desc:IsA("TextButton") or desc:IsA("ImageButton") or desc:IsA("TextLabel")) then continue end
        local text = tostring(desc.Text or ""):gsub("%s+", " "):sub(1, 40)
        local vis = desc.Visible and "T" or "F"
        local en = (desc:IsA("TextButton") or desc:IsA("ImageButton")) and tostring(desc.Active) or "-"
        table.insert(parts, desc.ClassName .. " " .. desc.Name .. " v=" .. vis .. " e=" .. en .. " " .. __L.slotClickSignals(desc) .. " txt='" .. text .. "'")
    end
    LogEvent("ShopDump", "Offer" .. i .. " | " .. table.concat(parts, " | "))
end

function __L.clickConfirmPopup(i)
    -- Some shop UIs open a confirmation dialog after Buy; find its button
    -- outside the offer slots (a dialog lives above the shop frame) and click it.
    local slots = getOfferSlotsFrame()
    if not slots then return nil end
    local screenGui = slots:FindFirstAncestorOfClass("ScreenGui")
    if not screenGui then return nil end
    local confirmNames = { "confirm", "purchase", "accept", "yes" }
    for _, btn in ipairs(screenGui:GetDescendants()) do
        if not btn:IsA("TextButton") then continue end
        if not btn.Visible then continue end
        if btn.AbsoluteSize.X <= 0 or btn.AbsoluteSize.Y <= 0 then continue end
        if slots:IsAncestorOf(btn) then continue end
        local lower = tostring(btn.Name):lower()
        local hit = false
        for _, kw in ipairs(confirmNames) do
            if lower:find(kw) then hit = true break end
        end
        if not hit then continue end
        __L.clickGuiButton(btn)
        LogEvent("BuyClick", "Offer" .. i .. " confirm dialog clicked on " .. tostring(btn.Name))
        return tostring(btn.Name)
    end
    return nil
end



-- ── Auto-unlock ─────────────────────────────────────────────────────────────
-- [FIX] Fire the PC screen's own UnlockButton instead of invoking
-- BuyNewOfferFunction blindly. That handler (a) gates on money, (b) invokes
-- the same remote, and (c) advances the UI for the NEXT offer via
-- newOfferAppear/lastOfferFunction. The old direct-remote version never ran
-- that UI step, so every slot after the first unlock kept a stale price label
-- and the loop stopped after one unlock. The price is still read from the
-- visible label first, so a broke player never triggers the error path.
function __L.tryAutoUnlock()
    if not Settings.AutoUnlock then return 0 end
    local spent = 0
    pcall(function()
        -- [FIX] The on-screen UnlockPrice label is only current for the slot
        -- the client last set up by itself; it goes stale after a direct
        -- unlock, so gating on it both mislabels the offer and can trigger the
        -- game's "Not Enough Money" branch. The real charge is fixed by the
        -- game's own table (PCLocalScript u3), indexed by PcProgressOffer:
        -- unlocking Offer(progress+1) costs prices[progress].
        local prices = { 500, 3000, 8000, 15000, 35000, 75000, 100000, 160000, 300000, 500000, 850000, 1250000, 2000000, 4500000, 7500000, 15000000 }
        local progress = __L.getUnlockedOfferCount() or 0
        if progress <= 0 or progress >= 16 then return end
        local price = prices[progress] or 0
        if price <= 0 then return end
        local btn = __L.nextLockedUnlockButton()
        if not btn then return end
        if getMoney() < price then return end
        local beforeMoney = getMoney()
        pcall(function() firesignal(btn.MouseButton1Click) end)
        for _ = 1, 20 do
            deltaWait(0.1)
            if (__L.getUnlockedOfferCount() or 0) > progress then break end
        end
        local afterProg = __L.getUnlockedOfferCount() or 0
        spent = math.max(0, beforeMoney - getMoney())
        if afterProg > progress then
            LogEvent("AutoUnlock", "Unlocked Offer" .. (progress + 1) .. " price=" .. price .. " spent=" .. spent .. " progress=" .. afterProg)
            if spent > 0 and Helpers.recordSpend then Helpers.recordSpend(spent) end
        else
            LogEvent("AutoUnlock", "Offer" .. (progress + 1) .. " unlock refused (price=" .. price .. " money=" .. getMoney() .. " progress=" .. afterProg .. ")")
        end
    end)
    return spent
end

local function isBlacklisted(data)
    if not data then return false end
    local bl = Settings.Buy.Blacklist
    -- [FIX] Rarity-only blacklist. The per-shoe blacklist was removed on request
    -- ("in the blacklist tab i just want the rarity not per shoe black list"), so
    -- a bare shoe-name string can no longer match anything here - only the rarity
    -- of a shoe data table can be skipped.
    local r = type(data) == "table" and data.Rarity or nil
    if not r then return false end
    if bl.Common    and r == "Common"    then return true end
    if bl.Uncommon  and r == "Uncommon"  then return true end
    if bl.Epic      and r == "Epic"      then return true end
    if bl.Legendary and r == "Legendary" then return true end
    if bl.Legacy    and r == "Legacy"    then return true end
    if bl.Special   and r == "Special"   then return true end
    if bl.Limited   and r == "Limited"   then return true end
    if bl.Grail     and r == "Grail"     then return true end
    return false
end

function __L.canAffordAnyOffer(items)
    -- Returns: canBuy (bool), reason (string | nil)
    -- When canBuy is false, reason is one of:
    --   "no_items"        - items table is empty / invalid
    --   "all_blacklisted" - every item is blacklisted
    -- No client-side price/unlock gates: the server is the authority (see
    -- buy-cycle comment below) — any non-blacklisted offer is worth firing at.
    if type(items) ~= "table" then return false, "no_items" end
    deltaWait(0.2)
    for _, v in pairs(items) do
        local data = Sneakers[v]
        if not data then continue end
        if isBlacklisted(data) then continue end
        return true, "ok"
    end
    return false, "all_blacklisted"
end

-- InvokeServer returns without throwing even when the server silently refuses
-- the buy (sold out / already bought / cooldown), so a non-throwing call alone
-- proves nothing. Only count a purchase when the money actually decreased.
-- No GUI path here on purpose: the old working script fired this remote and
-- never touched the shop UI (log proof: our GUI fallback clicked a *select*
-- button — "Offer2 selected via BigBuyButton" — not a purchase). Remote-only
-- means the PC shop UI does NOT need to be open for buying to work.
function __L.attemptBuyOffer(i)
    local moneyBefore = getMoney()
    local ok, err = pcall(function()
        return ReplicatedStorage.RemoteEvents.BuySneakerFunction:InvokeServer("Offer" .. i)
    end)
    if not ok then
        return false, "remote_error", err
    end
    -- Give the server time to apply the purchase; money updates with delay.
    -- Third return value = how much money actually left the wallet.
    for _ = 1, 6 do
        deltaWait(0.5)
        local now = getMoney()
        if now < moneyBefore then return true, "bought", moneyBefore - now end
    end
    return false, "rejected"
end

-- One pass over a refreshed page.
--   opts.running = function() -> truthy while the caller's mode is still on
--   opts.slots   = { [i] = bool } slot filter (PC modes)
--   opts.limit   = max money this pass may spend (the snapshot budget left)
-- Returns bought, failed, spent, skippedOverBudget.
-- Spending is recorded straight into the budget snapshot here, so EVERY mode
-- that goes through this function shares the same accounting.
local function runBuyCycle(items, speed, opts)
    opts = opts or {}
    if type(items) ~= "table" then return 0, 0, 0, 0 end
    -- Unlock spending draws from the same wallet snapshot as shoe purchases;
    -- count it so the buy->sell swap fires when the snapshot is truly gone
    -- (not only when the server starts rejecting shoe buys).
    local unlockSpent = __L.tryAutoUnlock() or 0
    local running = opts.running or function() return getgenv().FullAutoRunning end
    local limit   = opts.limit
    local slots   = opts.slots
    local cycleCount, failedCount, realSpent, skippedOver = 0, 0, unlockSpent, 0
    local buyDelay = getBuyDelay(speed or getgenv().FullAutoSpeed or "slow")
    for _, entry in ipairs(__L.sortOffersByRarity(items)) do
        local i = entry.i
        local v = entry.name
        if not srsAlive() or not running() then break end
        if slots and not slots[i] then continue end
        local data = Sneakers[v]
        if not data then continue end
        if isBlacklisted(data) then continue end
        -- Budget gate: the budget is a snapshot of money taken when the run
        -- started. Offers that would overshoot what is LEFT of it are skipped,
        -- and the pass ends the moment it is spent — income can't extend it.
        local left = limit and (limit - realSpent) or math.huge
        if left <= 0 then break end
        local guiPrice = __L.getOfferRealPrice(i)
        if guiPrice and guiPrice > left then
            skippedOver += 1
            continue
        end
        -- Otherwise no client-side price/unlock gates: the server is the
        -- authority and a rejected attempt costs nothing but a call.
        -- Only the Macro moves a cursor and clicks; every other mode buys
        -- straight through the remote (opts.cursor is set by the Macro only).
        if opts.cursor and Helpers.focusOfferButton then pcall(Helpers.focusOfferButton, i) end
        local bought, reason, extra = __L.attemptBuyOffer(i)

        if bought then
            State.remoteFailCount = 0
            getgenv().ShoesBought += 1
            getgenv().trackBoughtRarity(data)
            cycleCount += 1
            local spent = tonumber(extra) or 0
            realSpent += spent
            Helpers.recordSpend(spent)
        else
            failedCount += 1
            if reason == "remote_error" then
                State.remoteFailCount += 1
                LogEvent("BuyCycle", "Offer" .. i .. " failed: " .. tostring(extra))
                if State.remoteFailCount >= 5 then
                    if canAlert("remote_fail", 120) then
                        sendAlert("RemoteFail", "Remote Event Failing",
                            "BuySneakerFunction failed " .. tostring(State.remoteFailCount) .. " times in a row.")
                    end
                end
            else
                LogEvent("BuyCycle", "Offer" .. i .. " rejected silently (money=" .. tostring(getMoney()) .. ", guiPrice=" .. tostring(guiPrice) .. ")")
            end
        end

        deltaWait(buyDelay)
    end
    return cycleCount, failedCount, realSpent, skippedOver
end

-- ── Restock export ────────────────────────────────────────────────────────
-- Bounded buy loop driven from the executor console: buy until inventory
-- holds `targetPairs` shoes. Server is the price/stock authority (same note
-- as runBuyCycle) — a rejected attempt costs nothing but a call. Stops on
-- shutdown or when 3 full passes buy nothing AND money never moved (broke or
-- shelf empty), without guessing prices client-side.
getgenv().SRS_RestockTo = function(targetPairs)
    targetPairs = targetPairs or 60
    getgenv().__RESTOCK_ABORT = false
    local bought, stalledPasses, passes = 0, 0, 0
    local buyDelay = getBuyDelay("slow")
    while srsAlive() and not getgenv().ScriptShuttingDown do
        if sellableInventoryCount() >= targetPairs then break end
        passes = passes + 1
        if passes > 40 then
            warn("[RESTOCK] pass cap (40) hit, pairs=" .. sellableInventoryCount())
            break
        end
        __L.tryAutoUnlock()
        local ok, items = Helpers.refreshShopPage()
        if not ok or type(items) ~= "table" then
            deltaWait(1.5)
        else
            local passBought = 0
            local countAtPassStart = sellableInventoryCount()
            for _, entry in ipairs(__L.sortOffersByRarity(items)) do
                if sellableInventoryCount() >= targetPairs then break end
                local data = Sneakers[entry.name]
                if not data then continue end
                if isBlacklisted(data) then continue end
                local b, reason = __L.attemptBuyOffer(entry.i)
                if b then passBought = passBought + 1 end
                if reason == "remote_error" then
                    pcall(Helpers.refreshShopPage)
                    deltaWait(1.0)
                end
                deltaWait(buyDelay)
            end
            bought = bought + passBought
            -- Dead pass = no shoes landed. Money is NOT a reliable progress
            -- signal here (passive income ticks it up, offer-slot unlocks spend
            -- it down, and BuySneakerFunction can deduct then silently fail to
            -- grant — observed live: 469 "bought" money-drops but only 18 pairs
            -- in inventory). Net sellable-count growth across the pass is the
            -- only truth; a pass that ends with no growth is dead regardless of
            -- how many phantom "purchases" the money signal counted.
            if sellableInventoryCount() <= countAtPassStart then
                stalledPasses = stalledPasses + 1
                if stalledPasses >= 3 then
                    warn("[RESTOCK] stalled (nothing buyable / broke), pairs=" .. sellableInventoryCount())
                    break
                end
            else
                stalledPasses = 0
            end
        end
        deltaWait(getReloadDelay("slow"))
    end
    getgenv().__RESTOCK_ABORT = true
    warn("[RESTOCK] done pairs=" .. sellableInventoryCount() .. " bought=" .. bought .. " money=" .. tostring(getMoney()))
    return bought
end

-- ── Sell bar ──────────────────────────────────────────────────────────────

function __L.fireStopButton()
    if not SellFrame then getSellFrame() end
    if not SellFrame then return end
    local btn = SellFrame.StopButton
    -- Signals only, NO raw VIM click: StopButton has real connections, so the
    -- fired signals trigger it. A physical click at its screen position falls
    -- through to the 3D world whenever the bar is sliding out (Visible still
    -- true during the tween) and ends up clicking players walking by.
    pcall(function() firesignal(btn.MouseButton1Down) end)
    pcall(function() firesignal(btn.MouseButton1Click) end)
    pcall(function() btn.MouseButton1Down:Fire() end)
    pcall(function() btn.MouseButton1Click:Fire() end)
end

-- ── Sell-carousel rarity control ───────────────────────────────────────────
-- The sell bar sells whichever sneaker the SpinningSelectFrame carousel is
-- showing, and the game orders that carousel by inventory order, not value,
-- so without this control the cheapest stacks leave first. CurrentPage is
-- read-only (assignment throws), so navigation is LeftButton/RightButton
-- clicks; steps are computed from page indices to take the shorter arc.
local function getSellCarousel()
    if not SellFrame then getSellFrame() end
    if not SellFrame then return nil, nil, nil, nil end
    local spin   = SellFrame:FindFirstChild("SpinningSelectFrame")
    local sel    = spin and spin:FindFirstChild("SelectedFrame")
    local layout = sel and sel:FindFirstChildOfClass("UIPageLayout")
    return SellFrame, spin, sel, layout
end

function __L.sellCarouselPages()
    local _, _, sel, layout = getSellCarousel()
    if not sel or not layout then return {} end
    local pages = {}
    for idx, c in ipairs(sel:GetChildren()) do
        if c:IsA("ImageButton") then
            local amt = c:FindFirstChild("AmountText")
            local txt = amt and amt:IsA("TextLabel") and amt.Text or ""
            local n   = tonumber(txt:match("^(%d+)"))
            pages[#pages + 1] = {
                name = c.Name, btn = c, remaining = n or 0,
                order = (type(c.LayoutOrder) == "number") and c.LayoutOrder or 0,
                idx = idx,
            }
        end
    end
    table.sort(pages, function(a, b)
        if a.order ~= b.order then return a.order < b.order end
        return a.idx < b.idx
    end)
    return pages
end

local function sellCarouselCurrent()
    local _, _, _, layout = getSellCarousel()
    if not layout then return nil end
    local ok, cur = pcall(function() return layout.CurrentPage end)
    return ok and cur or nil
end

-- Fires every click path the game may have connected, mirroring fireStopButton
-- (signals only, no raw VIM click: one falls through to the 3D world during
-- the slide-out tween and would click players walking by).
function __L.spamCarouselButton(btn)
    pcall(function() firesignal(btn.MouseButton1Down) end)
    pcall(function() firesignal(btn.MouseButton1Click) end)
    pcall(function() firesignal(btn.Activated) end)
end

-- Page ImageButton names occasionally drift from Sneakers keys (renames in the
-- module). Try exact, then a case-insensitive scan, before giving up.
function __L.matchSneakerKey(name)
    if not name then return nil end
    if Sneakers[name] then return name end
    local low = name:lower()
    for k in pairs(Sneakers) do
        if type(k) == "string" and k:lower() == low then return k end
    end
    return nil
end

function __L.navigateSellCarouselTo(targetName)
    -- Click-until-seen: the wheel advances in multi-page chunks per click and
    -- wraps (CircularScrolling), so index-arc math overshoots and oscillates.
    -- Settle-spaced RIGHT clicks + re-read each cycle converge from any
    -- position in at most one full revolution, whatever the chunk size.
    for _ = 1, 70 do
        local _, spin, _, layout = getSellCarousel()
        if not spin or not layout then return false end
        local rb = spin:FindFirstChild("RightButton")
        if not rb then return false end
        local cur = sellCarouselCurrent()
        if cur and cur.Name == targetName then return true end
        local before = cur and cur.Name or nil
        __L.spamCarouselButton(rb)
        task.wait(0.35)
        local after = sellCarouselCurrent()
        if after and after.Name == targetName then return true end
        -- Two identical non-target re-reads = the click never registered
        -- (wheel dead/bar re-building): give up instead of spinning forever.
        if after and before and after.Name == before then
            task.wait(0.35)
            local again = sellCarouselCurrent()
            if again and again.Name == before then return false end
        end
    end
    return false
end

-- The game runs a ~4s intro spin animation on the carousel when the bar
-- opens (probed: wheel advanced 4 pages on its own then parked). Clicking
-- RightButton WHILE that animation is running makes navigation overshoot:
-- the "click-until-seen" loop re-reads a moving target, the parked page
-- changes under it, and the retry path chases the spin forever. Wait for the
-- wheel to go static (two identical page reads) before any navigation so
-- clicks land on a settled wheel; each click then moves exactly one page.
function __L.waitSellWheelSettled(timeout)
    local _, _, _, layout = getSellCarousel()
    if not layout then return false end
    local deadline = tick() + (timeout or 6)
    local prev, seen = nil, 0
    while tick() < deadline do
        if SellFrame and not SellFrame.Visible then return false end
        local cur = sellCarouselCurrent()
        if cur and prev and cur.Name == prev.Name then
            seen = seen + 1
            if seen >= 2 then return true end
        else
            seen = 0
        end
        prev = cur
        task.wait(0.25)
    end
    return false
end

-- Lock the carousel onto the highest-rarity sneaker still holding stock.
-- While navigating, sellBarBusy gates the stop-fire so a sweep can never sell
-- a lower-rarity shoe mid-flip: the line keeps sweeping and the next
-- perfect-zone pass fires once the carousel has landed.
function __L.flipToBestSellShoe()
    if true then State.sellCarouselParkedName = nil; return true end -- rarity-first selling removed: sell whatever page is showing
    if State.sellCarouselBusy then return false end
    State.sellCarouselBusy = true
    local ok, parked = pcall(function()
        -- The carousel may still be building when the bar first opens; give
        -- it a bounded moment before giving up on the flip.
        local pages
        for _ = 1, 20 do
            pages = __L.sellCarouselPages()
            if #pages > 0 then break end
            task.wait(0.05)
        end
        local bestName, bestRank = nil, -1
        for _, p in ipairs(pages) do
            local data = Sneakers[__L.matchSneakerKey(p.name)]
            local rank = __L.rarityRank(data)
            if p.remaining > 0 and rank > bestRank then
                bestRank, bestName = rank, p.name
            end
        end
        if not bestName then return nil end
        -- Navigation clicks land on a STATIC wheel only: if the intro spin
        -- (or the post-sale re-spin) is still running, bail so the retry path
        -- re-checks in 0.8s. Clicking mid-spin is what made the wheel drift.
        if not __L.waitSellWheelSettled(6) then return nil end
        if __L.navigateSellCarouselTo(bestName) then return bestName end
        return nil
    end)
    State.sellCarouselBusy = false
    if ok and parked then
        State.sellCarouselParkedName = parked
    else
        State.sellCarouselParkedName = nil
    end
    return ok and parked ~= nil
end

-- Grade is decided by the line's REAL position when the game samples it after
-- stop (client hit-test on the actual COLORX_* zones, server re-validates).
-- Stretching zones does not work and ISOLATES nothing — prediction does: fire
-- StopButton EARLY by (velocity * grade latency) so the line is inside the
-- Perfect zone at the moment the game reads it.
getgenv().SellGradeLatency = getgenv().SellGradeLatency or 0.02 -- live-tunable
getgenv().SellDebugLog     = getgenv().SellDebugLog or {}
getgenv().SellMeasureLog   = getgenv().SellMeasureLog or {}
getgenv().SellGradeLog     = getgenv().SellGradeLog or {}
local function startSellBarListener()
    if State.sellBarConnection then return end
    local velBuf, velocity = {}, 0
    -- Median of per-frame signed velocities across the window. Resists jitter,
    -- stale AbsolutePosition samples and reversal frames that single short
    -- window deltas blow up on. Returns 0 when direction is inconsistent.
    local function smoothedVel()
        local n = #velBuf
        if n < 3 then return 0 end
        local vals = {}
        for i = 2, n do
            local dt = velBuf[i].t - velBuf[i - 1].t
            if dt > 0.001 and dt < 0.1 then
                local v = (velBuf[i].x - velBuf[i - 1].x) / dt
                if math.abs(v) < 4000 then vals[#vals + 1] = v end
            end
        end
        if #vals == 0 then return 0 end
        table.sort(vals)
        local med = vals[math.floor(#vals / 2) + 1]
        if math.abs(med) < 150 then return 0 end
        return med
    end
    local dbgCentreX, dbgLeadX, dbgPerfL, dbgPerfR, dbgVel, dbgLat = 0, 0, 0, 0, 0, 0
    local traj = {}
    local lastProj, lastProjT = nil, 0 -- previous frame's projected line X (centre-aim trigger)
    State.sellBarConnection = RunService.RenderStepped:Connect(function()
        if not srsAlive() then return end
        if not Settings.Sell and not getgenv().FullAutoRunning and not getgenv().PCFullAutoRunning then return end
        if not SellFrame then getSellFrame(); return end
        if not SellFrame.Visible then
            State.sellBarCooldown = false
            State.sellBarWasVisible = false
            State.sellCarouselParkedName = nil
            lastProj = nil
            return
        end
        if State.sellBarCooldown then lastProj = nil; return end
        -- [FIX] Legit look: park the drawn cursor on the bar's StopButton while
        -- it is on screen, so the stop reads as a real button tap.
        if Helpers.sellBarCursorTick then pcall(Helpers.sellBarCursorTick) end
        local ok, triggered = pcall(function()
            local Line    = SellFrame.BarAndLine.Line
            local Perfect = SellFrame.BarAndLine.ExtraBarFrame.LineColorsFrame["COLORX_Perfect"]
            local centreX = Line.AbsolutePosition.X + Line.AbsoluteSize.X / 2
            local PerfLeft   = Perfect.AbsolutePosition.X
            local PerfRight  = Perfect.AbsolutePosition.X + Perfect.AbsoluteSize.X
            local now = tick()
            velBuf[#velBuf + 1] = { t = now, x = centreX }
            while #velBuf > 4 do table.remove(velBuf, 1) end
            velocity = smoothedVel()
            traj[#traj + 1] = { t = now, x = centreX, pl = PerfLeft, pr = PerfRight }
            if #traj > 90 then table.remove(traj, 1) end
            if math.abs(velocity) < 150 then return false end
            -- Empirical: all recorded misses fired on right-moving (return)
            -- sweeps; zero misses on left-moving (delivery) sweeps. Fire only
            -- on the delivery sweep unless SellRightGate is explicitly forced.
            if getgenv().SellLeftGate == nil then getgenv().SellLeftGate = true end
            if getgenv().SellLeftGate and velocity > 0 then return false end
            local lat = getgenv().SellGradeLatency or 0.016
            local projX = centreX + velocity * lat
            local perfCentre = (PerfLeft + PerfRight) / 2
            dbgCentreX, dbgLeadX, dbgPerfL, dbgPerfR, dbgVel, dbgLat = centreX, projX, PerfLeft, PerfRight, velocity, lat
            local zoneW = PerfRight - PerfLeft
            -- v4 CENTRE-AIM (set getgenv().SellAimCentre = false for the old
            -- "anywhere in the middle 70%" trigger). The old rule fired on the
            -- FIRST frame the projected line entered the zone, i.e. near its
            -- edge, so any latency jitter pushed it out as Good/Miss. Now it
            -- fires on the frame whose projection is NEAREST the zone centre
            -- (this frame is closer than the next would be), and also if the
            -- projection stepped straight across the centre between two frames
            -- (narrow zone / fast bar). That gives the full half-zone of
            -- margin on both sides instead of ~0 on the leading side.
            if getgenv().SellAimCentre == false then
                return projX >= PerfLeft + zoneW * 0.15 and projX < PerfRight - zoneW * 0.15
            end
            local prev, prevT = lastProj, lastProjT
            lastProj, lastProjT = projX, now
            local inZone = projX >= PerfLeft + zoneW * 0.08 and projX <= PerfRight - zoneW * 0.08
            local dtF = now - prevT
            if dtF <= 0.001 or dtF > 0.1 then dtF = 1 / 60 end
            local nextProj = projX + velocity * dtF
            if inZone and math.abs(projX - perfCentre) <= math.abs(nextProj - perfCentre) then
                return true
            end
            if prev and (prev - perfCentre) * (projX - perfCentre) <= 0
               and math.min(math.abs(prev - perfCentre), math.abs(projX - perfCentre)) <= zoneW * 0.45 then
                return true
            end
            return false
        end)
        if ok and triggered then
            State.sellBarCooldown = true
            getgenv().ScriptIncomeWindow = tick() + 1.5
            local log = getgenv().SellDebugLog
            table.insert(log, { t = tick(), centreX = dbgCentreX, leadX = dbgLeadX, perL = dbgPerfL, perR = dbgPerfR, vel = dbgVel, lat = dbgLat })
            if #log > 60 then table.remove(log, 1) end
            __L.fireStopButton()
            if Helpers.sellBarPressFlash then pcall(Helpers.sellBarPressFlash) end
            getgenv().ShoesSold += 1
            task.spawn(function()
                local Line = SellFrame and SellFrame.BarAndLine and SellFrame.BarAndLine.Line
                local P = SellFrame and SellFrame.BarAndLine and SellFrame.BarAndLine.ExtraBarFrame
                    and SellFrame.BarAndLine.ExtraBarFrame.LineColorsFrame
                    and SellFrame.BarAndLine.ExtraBarFrame.LineColorsFrame["COLORX_Perfect"]
                if not Line or not P then return end
                local ms = game:GetService("Players").LocalPlayer
                    and game:GetService("Players").LocalPlayer:FindFirstChild("PlayerGui")
                local ComboLab = ms and ms:FindFirstChild("MainScreenGui") and ms.MainScreenGui:FindFirstChild("SellAnimFrame")
                    and ms.MainScreenGui.SellAnimFrame:FindFirstChild("ComboFrame")
                    and ms.MainScreenGui.SellAnimFrame.ComboFrame:FindFirstChild("ComboAmount")
                local fireX = dbgCentreX
                local fireT = tick()
                local okf, fL, fR = pcall(function()
                    local l = P.AbsolutePosition.X
                    return l, l + P.AbsoluteSize.X
                end)
                local okB, combB = pcall(function() return ComboLab.Text end)
                -- Post-fire trajectory (~320ms window, 20ms frames). The game
                -- grades at an unknown offset after stop — either a fixed
                -- server latency (line still gliding) or a settle model (line
                -- plateaus). The long window shows WHICH, and where the final
                -- rest position sits relative to the zone per grade.
                local traj = {}
                local zoneSnap = { pL = nil, pR = nil }
                for frame = 1, 16 do
                    task.wait(0.02)
                    local okc, lx = pcall(function()
                        return Line.AbsolutePosition.X + Line.AbsoluteSize.X / 2
                    end)
                    local okz, pL, pR
                    if okc and not zoneSnap.pL then
                        okz, pL, pR = pcall(function()
                            local l = P.AbsolutePosition.X
                            return l, l + P.AbsoluteSize.X
                        end)
                        if okz then zoneSnap.pL, zoneSnap.pR = pL, pR end
                    end
                    if okc then
                        traj[#traj + 1] = { d = tick() - fireT, x = lx }
                    end
                end
                local lx, pL, pR = traj[1] and traj[1].x, zoneSnap.pL, zoneSnap.pR
                if lx and pL and pR then
                    local inZone = lx > pL and lx < pR
                    local meas = getgenv().SellMeasureLog
                    table.insert(meas, { t = tick(), fireX = fireX, delay = tick() - fireT, nextX = lx, perL = pL, perR = pR, inZone = inZone })
                    if #meas > 120 then table.remove(meas, 1) end
                end
                task.wait(0.6)
                local okA, combA = pcall(function() return ComboLab.Text end)
                do -- v4: running grade tally for the Dashboard (Perfect = combo up, Good = same, Miss = reset)
                    local cs = getgenv().SellStats
                    if not cs then
                        cs = { perfect = 0, good = 0, miss = 0, combo = 0, best = 0 }
                        getgenv().SellStats = cs
                    end
                    local nb, na = tonumber(okB and combB), tonumber(okA and combA)
                    if na then
                        cs.combo = na
                        if na > cs.best then cs.best = na end
                        if nb then
                            if na > nb then cs.perfect += 1
                            elseif na == nb then cs.good += 1
                            else cs.miss += 1 end
                        end
                    end
                end
                local g = getgenv().SellGradeLog
                table.insert(g, { t = tick(), fireX = fireX, fL = okf and fL or nil, fR = okf and fR or nil,
                    lx = lx or nil, pL = pL or nil, pR = pR or nil,
                    cB = okB and combB or nil, cA = okA and combA or nil,
                    traj = traj })
                if #g > 60 then table.remove(g, 1) end
            end)
            task.delay(0.5, function() State.sellBarCooldown = false end)
        end
    end)
end

local function stopSellBarListener()
    if State.sellBarConnection then State.sellBarConnection:Disconnect(); State.sellBarConnection = nil end
end

-- ── Adaptive grade-latency controller ──────────────────────────────────────
-- The server samples the line at an offset T after StopButton fires, and T
-- DRIFTS over a session (measured ~20ms→55ms in ~15min, ≈+2.3ms/min). A fixed
-- `lat` lead therefore decays: Perfect-rate falls 54%→10%, grades shift to
-- Good, then Miss resets. The trigger projects centreX + v*lat into the
-- Perfect window, so the fix is to make `lat` track T. Perfect-rate alone
-- cannot say which side of the peak we are on (it plateaus for |lat−T| <
-- ~35ms, and velocity jitter blurs the slope), so the controller probes both
-- flanks with a ±12ms dither, corrects toward the better flank, then creeps
-- with the measured drift while healthy.
local ADAPT_P_RATE_OK = 0.70
local ADAPT_P_PROBE = 0.60
local ADAPT_LAT_MIN = 0.012
local ADAPT_PROBE_DITHER = 0.006

function __L.adaptGradeOf(e)
    -- Grade from combo deltas: Perfect = +1, Good = unchanged, Miss = reset.
    if not e or not e.cB or not e.cA then return nil end
    local b, a = tonumber(e.cB), tonumber(e.cA)
    if not b or not a then return nil end
    if a > b then return "P" end
    if a == b then return "G" end
    return "M"
end

function __L.adaptTally(newerThanT, skipFrom, skipTo)
    -- Grade mix over resolved SellGradeLog entries. Pass a timestamp to count
    -- only entries appended after it (probe-flank measurement); nil counts the
    -- whole recent window (rolling 40). A timestamp watermark is required: the
    -- log is capped at 60 and rolls with table.remove(g, 1) on every insert,
    -- which destroys an index-based tail (the newest entry always lands at the
    -- tail index, so a probe flank could only ever count that single entry and
    -- nL/nR stuck at 1, forcing endless probe-invalid keeps at the stale lat).
    -- skipFrom/skipTo excludes a swallowed tick() window (the probe swing),
    -- whose swept-lat sales would otherwise skew the fresh-window P rate.
    local g = getgenv().SellGradeLog
    local n, p, m = 0, 0, 0
    for i = #g, 1, -1 do
        local e = g[i]
        if newerThanT == nil or (e.t and e.t > newerThanT) then
            if skipFrom and skipTo and e.t and e.t >= skipFrom and e.t <= skipTo then continue end
            local gr = __L.adaptGradeOf(e)
            if gr then
                n = n + 1
                if gr == "P" then p = p + 1 elseif gr == "M" then m = m + 1 end
                if n >= 40 then break end
            end
        end
    end
    return n, p / math.max(1, n), m
end

-- Executor-global table survives across ships, so re-shipping the default
-- literal alone never propagates newly added fields to an old object. Seed
-- only keys that are still nil: existing tuning state is preserved while
-- arithmetic fields (missPushes, lastProbe, ...) get a guaranteed value.
getgenv().SellAdapt = getgenv().SellAdapt or {}
local _sellAdapt = getgenv().SellAdapt
for _k, _v in pairs({
    lat = 0.016,      -- current lead, applied to SellGradeLatency
    base = 0.016,     -- lat before a probe swing
    dir = 1,          -- sign of the last-known-good correction
    phase = "hold",   -- hold | probeL | probeR | recover
    phaseStart = 0,
    tailT = 0,        -- SellGradeLog watermark (tick()) at probe-flank start
    excStart = 0,     -- probe-swing tick() window start; rolling tally skips it
    excEnd = 0,       -- probe-swing tick() window end (set at probeR exit)
    pL = 0, pR = 0, pN = 0, -- measured flank Perfect-rates + flankL sample count
    recoverTicks = 0,
    missPushes = 0,   -- consecutive hard-miss pushes, bounded at 3
    lastProbe = 0,
    goodTicks = 0,
    tick = 0,
    lastHarvestT = 0, -- SellGradeLog watermark: last grade whose trajectory was harvested
    harvest = {},     -- ring of Perfect-grade trajectory midpoints (T estimates)
}) do
    if _sellAdapt[_k] == nil then _sellAdapt[_k] = _v end
end

-- Trajectory bracket of a resolved grade: the post-fire frame window during
-- which the line visibly sat inside the Perfect zone. The server samples at
-- some T after Stop fires; a Perfect grade means T landed inside this window,
-- so its midpoint is a direct T estimate. Good/Miss brackets are NOT used for
-- estimation (client visuals and the server sample can disagree off-Perfect).
-- Returns midpoint in seconds, or nil when the grade carries no usable bracket.
function __L.adaptPerfectMidpoint(e)
    if not e or not e.traj or #e.traj < 2 or not e.pL or not e.pR then return nil end
    local entryT, exitT = nil, nil
    for _, f in ipairs(e.traj) do
        if f.x and f.x > e.pL and f.x < e.pR then
            if not entryT then entryT = f.d end
            exitT = f.d
        end
    end
    if entryT and exitT then return (entryT + exitT) / 2 end
    return nil
end

-- lat vs trajectory-midpoint mapping. Measured live: P grades at lat=0.0422
-- showed in-zone midpoints of 0.057-0.058; G grades at lat=0.036 sat in-zone
-- early (0.025-0.050) and had already left when sampled. The StopButton press
-- brakes the bar, so the line lingers in the zone instead of passing through
-- at full velocity — the trigger's linear projection (centreX + v*lat)
-- therefore undershoots the real T by this factor. Empirical, re-checked
-- whenever a Perfect bracket is harvested.
function __L.adaptLatencyTick(now)
    local a = getgenv().SellAdapt
    if not a.initialized then
        a.lat = getgenv().SellGradeLatency or 0.016
        a.base = a.lat
        a.initialized = true
    end
    local n, pRate, mCount = __L.adaptTally(tick() - 90, a.excStart, a.excEnd)
    if n < 15 then return end

    local glog = getgenv().SellGradeLog
    local newestT = glog[#glog] and glog[#glog].t or 0
    if now - newestT > 10 then return end -- no fresh sells: stale grades must not steer latency

    local elapsed = now - a.phaseStart

    if a.phase == "hold" and pRate < ADAPT_P_PROBE and now - a.lastProbe > 60 then
        -- Perfect-rate collapsed. Probe the slope: fire later (lat−6ms) then
        -- earlier (lat+6ms); the better flank shows which edge we are on.
        a.phase, a.phaseStart = "probeL", now
        a.base = a.lat
        a.tailT = tick()
        a.excStart = tick() -- swung-lat sales must not steer the rolling tally
        a.lastGoodLat = nil
        a.pL, a.pR, a.pN = 0, 0, 0
        a.lat = math.max(ADAPT_LAT_MIN, a.base - ADAPT_PROBE_DITHER)
        print(string.format("SELLADAPT probeL base=%.4f P=%.2f n=%d", a.base, pRate, n))
elseif a.phase == "probeL" then
        local nl, flankL = __L.adaptTally(a.tailT)
        -- Flank needs enough fresh fires to be meaningful: advance on >=6
        -- samples landed after `tail`, or force-advance on a 45s hard cap so
        -- a starved probe can't hang forever while sells are paused.
        if nl >= 6 or elapsed > 45 then
            a.pL, a.pN = flankL, nl
            a.phase, a.phaseStart = "probeR", now
            a.tailT = tick()
            a.lat = math.min(0.09, a.base + ADAPT_PROBE_DITHER)
            print(string.format("SELLADAPT probeR flankL=%.2f nL=%d", a.pL, nl))
        end
    elseif a.phase == "probeR" then
        local nr, flankR = __L.adaptTally(a.tailT)
        if nr >= 6 or elapsed > 45 then
            a.pR = flankR
            a.excEnd = tick() -- probe swing over: window closes at this boundary
            if a.pN >= 6 and nr >= 6 then
                if a.pL < 0.10 and flankR < 0.10 then
                    -- Both flanks read ~0 P with valid sample counts: the
                    -- Perfect window is far from this lat and the gradient
                    -- cannot pick a direction (pL == pR == 0 biases dir=+1,
                    -- which creeps straight back into the 0.09 cap). Halve
                    -- base toward the 0.016 default and re-probe from there.
                    a.base = math.max(ADAPT_LAT_MIN, (a.base + 0.016) / 2)
                    a.lat = a.base
                    a.phase, a.phaseStart = "hold", now
                    a.lastProbe = now - 70
                    print(string.format("SELLADAPT zero-flank base=%.4f re-probe", a.base))
                else
                    a.dir = a.pL > a.pR and -1 or 1
                    a.recoverTicks = 0
                    a.missPushes = 0
                    a.phase, a.phaseStart = "recover", now
                    a.lat = math.min(0.09, math.max(ADAPT_LAT_MIN, a.base + a.dir * 0.008))
                    a.lastProbe = now
                    print(string.format("SELLADAPT dir=%d flankL=%.2f flankR=%.2f lat=%.4f", a.dir, a.pL, a.pR, a.lat))
                end
            else
                -- A flank with too few fresh fires reads as ~0 P and corrupts
                -- the decision (sells pause while walking between NPC visits).
                -- Keep lat, and cool down 180s before re-probing (lastProbe
                -- set 120s ahead; the hold gate needs now-lastProbe>60).
                a.lat = a.base
                a.phase, a.phaseStart = "hold", now
                a.lastProbe = now + 120
                print(string.format("SELLADAPT probe-invalid nL=%d nR=%d keep lat=%.4f cd=180", a.pN, nr, a.lat))
end
        end
    elseif a.phase == "recover" and (pRate >= ADAPT_P_RATE_OK or elapsed > 40) then
        a.phase, a.phaseStart = "hold", now
        a.lastProbe = now
    elseif a.phase == "recover" and a.recoverTicks > 8 and pRate < ADAPT_P_PROBE then
        -- Recovery is not winning; abandon it and probe fresh from the live lat.
        a.phase, a.phaseStart = "hold", now
        a.lastProbe = now - 70
    end

    -- Harvest a Perfect-grade trajectory midpoint whenever a fresh grade
    -- resolves. This is a direct T measurement (server sampled while the line
    -- sat inside the Perfect window); the 0.74 map converts it back into
    -- trigger-latency space. Only P brackets enter the ring: off-Perfect
    -- grades are where client visuals and the server sample disagree, so
    -- their brackets would inject noise.
    local gnew = glog[#glog]
    if gnew and gnew.t and gnew.t > a.lastHarvestT then
        a.lastHarvestT = gnew.t
        local mid = __L.adaptPerfectMidpoint(gnew)
        if mid and __L.adaptGradeOf(gnew) == "P" then
            a.harvest[#a.harvest + 1] = mid
            if #a.harvest > 8 then table.remove(a.harvest, 1) end
            a.lastGoodLat = math.min(0.09, math.max(ADAPT_LAT_MIN, a.lat))
        end
    end

    -- Per-phase steering.
    if a.phase == "hold" then
        -- Perfect-bracket median maps straight to a lat target, so hold can
        -- converge within a few 2.5s ticks of the first P grade landing —
        -- the old 0.2ms/8s creep took 100+ sales to recover a drifty T. The
        -- steady-state correction rate (25%/tick) also tracks a drifting T
        -- without waiting for pRate to collapse into a probe.
        local target = nil
        if #a.harvest >= 3 then
            local sorted = {}
            for i = 1, #a.harvest do sorted[i] = a.harvest[i] end
            table.sort(sorted)
            target = sorted[math.floor(#sorted / 2) + 1] * 0.74
        end
        if target and math.abs(a.lat - target) > 0.0003 then
            a.lat = math.min(0.09, math.max(ADAPT_LAT_MIN, a.lat + (target - a.lat) * 0.25))
        elseif pRate >= 0.85 then
            -- Solid plateau: nudge with the drift slowly. The step direction
            -- comes from the last probe (a.dir) so we track the window center
            -- instead of always walking up through its far edge. Observed live:
            -- dir=-1 (window at lat=0.0133, probeL=1.00) but the old creep
            -- walked lat 0.0120→0.0186 against it and P decayed 1.00→0.72 with
            -- nothing correcting in the 0.60–0.85 dead band.
            a.goodTicks = a.goodTicks + 1
            if pRate >= 0.95 then a.lastGoodLat = a.lat end
            if a.goodTicks % 4 == 0 then
                a.lat = math.min(0.09, math.max(ADAPT_LAT_MIN, a.lat + a.dir * 0.0002))
            end
        elseif pRate < 0.85 and pRate >= 0.50 and a.lastGoodLat
               and math.abs(a.lat - a.lastGoodLat) > 0.0005 then
            -- Decay band: not bad enough to trip the <0.60 probe gate, but the
            -- lat is off the window's center. Ease back toward the last
            -- P>=0.95 anchor instead of freezing at a degraded lat; this
            -- corrects a stale a.dir too (creep off, only this runs in-band).
            a.lat = a.lat + (a.lat < a.lastGoodLat and 0.0002 or -0.0002)
        end
    elseif a.phase == "recover" then
        a.recoverTicks = a.recoverTicks + 1
        if pRate < ADAPT_P_RATE_OK then
            a.lat = math.min(0.09, math.max(ADAPT_LAT_MIN, a.lat + a.dir * 0.004))
        end
    end

    -- Hard-miss safety: a reset means the sample left the Good zone; push
    -- hard in the last-known-good direction, but only 3 times. Three pushes
    -- without recovery means the direction itself is stale — force a fresh
    -- probe instead of riding the cap (the 0.0328→0.0900 miss-push cascade).
    if mCount >= 2 and pRate < 0.5 and a.phase == "hold" then
        if a.missPushes >= 3 then
            a.missPushes = 0
            a.base = a.lat
            a.phase, a.phaseStart = "probeL", now
            a.tailT = tick()
            a.excStart = tick()
            a.lastGoodLat = nil
            a.pL, a.pR, a.pN = 0, 0, 0
            a.lat = math.max(ADAPT_LAT_MIN, a.base - ADAPT_PROBE_DITHER)
            print(string.format("SELLADAPT miss-cap -> probeL base=%.4f", a.base))
        else
            a.missPushes = a.missPushes + 1
            a.lat = math.min(0.09, math.max(ADAPT_LAT_MIN, a.lat + a.dir * 0.008))
            print(string.format("SELLADAPT miss-push (%d) lat=%.4f", a.missPushes, a.lat))
        end
    end

    getgenv().SellGradeLatency = a.lat

    a.tick = a.tick + 1
    if a.tick % 12 == 0 then
        print(string.format("SELLADAPT lat=%.4f P=%.2f n=%d phase=%s dir=%d", a.lat, pRate, n, a.phase, a.dir))
    end
end

-- Shared sell-adapt loop. Runs while ANY sell mode is active (UI toggle,
-- executor start, full-auto cycles) so `lat` keeps tracking the server's
-- sampling offset T in every flow. Re-entrant via __SELLADAPT_RUNNING.
local function startSellAdaptLoop()
    if getgenv().__SELLADAPT_RUNNING then return end
    getgenv().__SELLADAPT_RUNNING = true
    task.spawn(function()
        while (Settings.Sell or getgenv().FullAutoRunning or getgenv().PCFullAutoRunning)
              and srsAlive() do
            __L.adaptLatencyTick(tick())
            deltaWait(2.5)
        end
        getgenv().__SELLADAPT_RUNNING = false
    end)
end

-- External sell controller (mirrors the Auto Sell toggle callback so the
-- executor can start/stop semi-auto selling without touching the UI).
getgenv().SRS_StartSell = function()
    Settings.Sell = true
    if Helpers.closeShop then pcall(Helpers.closeShop) end
    startSellBarListener()
    startSellAdaptLoop()
    task.spawn(function()
        local emptyCount = 0
        while Settings.Sell and srsAlive() do
            if inventoryIsEmpty() then
                -- SellableInventory rebuilds transiently during UI refreshes,
                -- so one (or two) empty readings are not authoritative.
                emptyCount = emptyCount + 1
                if emptyCount >= 3 then
                    stopSellBarListener()
                    closeSellBar()
                    Settings.Sell = false
                    warn("[SELL] Inventory confirmed empty over 3 checks — sell phase done")
                    break
                end
                deltaWait(0.5)
            else
                emptyCount = 0
                if not SellFrame or not SellFrame.Visible then
                    pcall(__L.sellToNPC)
                end
                deltaWait(0.1)
            end
        end
    end)
end
getgenv().SRS_StopSell = function()
    Settings.Sell = false
    stopSellBarListener()
    closeSellBar()
    if Helpers.closeShop then pcall(Helpers.closeShop) end
end

do -- Scoped so its locals (4 fns, 3 vals) free registers before the rest of bootScript
-- ── Daily quests ────────────────────────────────────────────────────────────
-- Counters are lifetime totals; claims are day-keyed and idempotent.
-- Quest keys rotate per day, so targets are read live from Quests.Daily.
-- Claims persist to the save file so a script reload or rejoin mid-day
-- cannot double-claim an already-redeemed quest (the day-255 duplicate bug).
getgenv().DailyQuestClaims = getgenv().DailyQuestClaims
    or (savedData and savedData.QuestClaims) or {} -- keyed "day:quest"

local function saveQuestClaims()
    local raw = safeReadFile(SAVE_PATH)
    local current = {}
    if raw and raw ~= "" then
        local ok, decoded = pcall(function()
            return game:GetService("HttpService"):JSONDecode(raw)
        end)
        if ok and decoded then current = decoded end
    end
    current.QuestClaims = getgenv().DailyQuestClaims
    local ok, encoded = pcall(function()
        return game:GetService("HttpService"):JSONEncode(current)
    end)
    if ok then safeWriteFile(SAVE_PATH, encoded) end
end

local okQM, QuestModuleTable = pcall(function()
    return require(ReplicatedStorage:FindFirstChild("QuestModule"))
end)
local QUEST_NEED_FALLBACK = {
    Sell50Npc = 50, Sell100Npc = 100, Buy100PcCommon = 100,
    Sell50FastSell = 50, Sell100FastSell = 100,
    Buy50PcUncommon = 50, Buy20PcEpic = 20, Buy10PcLegendary = 10,
    Dig3Sneakers = 3, Dig5Sneakers = 5, PlayFor10Minutes = 10,
}

local function questNeed(key)
    if okQM and QuestModuleTable and QuestModuleTable.quests
        and QuestModuleTable.quests[key] and QuestModuleTable.quests[key].NeededAmount then
        return QuestModuleTable.quests[key].NeededAmount
    end
    return QUEST_NEED_FALLBACK[key]
end

local function dailyQuestTargets(Daily)
    local targets = {}
    for _, child in ipairs(Daily:GetChildren()) do
        if child:IsA("IntValue") then
            local need = questNeed(child.Name)
            if need then
                targets[#targets + 1] = { Key = child.Name, Need = need }
            end
        end
    end
    return targets
end

-- [X2GATE] only redeem daily-quest prizes while the game's 2X money flag is LIVE.
-- The SAME PlayerInfo we trust for desc.Active — we read its SIBLING member,
-- MultiplierTime (IntValue > 0 = 2X money live). pcall'd, read-only, zero writes.
local function x2Live()
    local okpi, pi = pcall(function() return LocalPlayer:FindFirstChild("PlayerInfo") end)
    if not (okpi and pi) then return false end
    local okmt, mt = pcall(function() return pi:FindFirstChild("MultiplierTime") end)
    if not (okmt and mt) then return false end
    local okv, v = pcall(function() return mt.Value end)
    return okv and (tonumber(v) or 0) > 0
end

local function checkDailyQuests(force)
    if not Settings.Quests or Settings.Quests.AutoRedeem == false then return end
    local Quests = LocalPlayer:FindFirstChild("Quests")
    if not Quests then return end
    local Daily = Quests:FindFirstChild("Daily")
    if not Daily then return end
    local Stamp = Quests:FindFirstChild("DailyTimeStamp")
    local Day   = Stamp and tonumber(Stamp.Value) or 0
    local claims = getgenv().DailyQuestClaims
    local targets = dailyQuestTargets(Daily)
    if #targets == 0 then return end

    local fired = 0
    for _, q in ipairs(targets) do
        local counter = Daily:FindFirstChild(q.Key)
        local stateKey = Day .. ":" .. q.Key
        if counter and counter.Value >= q.Need and not claims[stateKey] and (force or x2Live()) then
            local ok = pcall(function()
                ReplicatedStorage.RemoteEvents.ClaimDailyQuestEvent:FireServer(q.Key)
            end)
            if ok then
                claims[stateKey] = true
                fired = fired + 1
                LogEvent("DailyQuest", "claimed " .. q.Key .. " (" .. counter.Value .. "/" .. q.Need .. ", day " .. Day .. ")")
            end
        end
    end
    if fired > 0 then saveQuestClaims() end

    -- All three past target (and now claimed) on this day → grab the final bonus.
    local finalKey = Day .. ":FINAL"
    if (fired > 0 or force) and not claims[finalKey] and (force or x2Live()) then
        local allDone = true
        for _, q in ipairs(targets) do
            local counter = Daily:FindFirstChild(q.Key)
            if not (counter and counter.Value >= q.Need) then allDone = false end
        end
        if allDone then
            local ok = pcall(function()
                ReplicatedStorage.RemoteEvents.ClaimFinalDailyQuestEvent:FireServer()
            end)
            if ok then
                claims[finalKey] = true
                LogEvent("DailyQuest", "final bonus claimed (day " .. Day .. ")")
                Notify({ Title = "Daily Quests", Content = "All 3 quests claimed — bonus reward redeemed!", Duration = 3, Image = "Star" })
            end
        end
    end
end

Helpers.checkDailyQuests = checkDailyQuests

-- Poll every 60s while alive; exits on reload so a fresh script re-checks.
local function startDailyQuestChecker()
    if getgenv().__DAILYQUEST_RUNNING then return end
    getgenv().__DAILYQUEST_RUNNING = true
    task.spawn(function()
        task.wait(5)
        while srsAlive() do
            checkDailyQuests()
            deltaWait(60)
        end
        getgenv().__DAILYQUEST_RUNNING = false
    end)
end
startDailyQuestChecker()
end

function __L.runSellCycle()
    startSellBarListener()
    startSellAdaptLoop()
    while (getgenv().FullAutoRunning or getgenv().PCFullAutoRunning) and srsAlive() do
        -- Check inventory.  If empty, confirm after a short delay
        -- so a UI refresh (which briefly clears SellableInventory)
        -- doesn't trick us into exiting prematurely.
        if inventoryIsEmpty() then
            deltaWait(1)
            if inventoryIsEmpty() then
                warn("[SELL] Inventory confirmed empty after 1s delay — sell phase done")
                break
            end
            warn("[SELL] Inventory appeared empty but refilled after 1s — continuing sell")
        end
        if not SellFrame or not SellFrame.Visible then
            warn("[SELL] Sell bar not visible — walking to NPC")
            local okSell, sellErr = pcall(__L.sellToNPC)
            if not okSell then warn("[SELL] sellToNPC error: " .. tostring(sellErr)) end
        end
        deltaWait(0.1)
    end
    stopSellBarListener()
    closeSellBar()
    warn("[SELL] Sell phase complete — Money:", getMoney(), "ShoesSold:", getgenv().ShoesSold)
    safeSpawn(function()
        __L.sendWebhook("Sell Cycle Complete")
    end)
end

-- ── Shoe App helpers ────────────────────────────────────────────────────────
local function safeSetLabel(lbl, text)
    if lbl and type(lbl.Set) == "function" then
        pcall(function() lbl:Set(tostring(text)) end)
    end
end

local MIN_SHOE_APP_MONEY = 5000 -- fallback when a drop's price is unknown

-- PhoneScript (decompiled live, :539) keeps a drop card alive for 600s after
-- its release time, and the drop is "First Come First Serve - you have 10
-- minutes to buy or until the stock runs out" (:486). So arm a moment before
-- release and keep hammering the whole real window instead of the old 90s/90s.
local SHOE_ARM_SECONDS = 120
local SHOE_DROP_WINDOW = 600

-- "4h 12m" / "9m 30s" / "45s" for the drop-watcher status line.
function __L.fmtLeft(s)
    s = math.max(0, math.floor(tonumber(s) or 0))
    local h = math.floor(s / 3600)
    local m = math.floor((s % 3600) / 60)
    if h > 0 then return h .. "h " .. m .. "m" end
    if m > 0 then return m .. "m " .. (s % 60) .. "s" end
    return s .. "s"
end

-- Cheap drops (e.g. $1 shoes) must be buyable on a low balance, so the money
-- guard is price-based, not a fixed rich-player threshold.
local function shoeBuyMinMoney(price)
    local p = tonumber(price) or 0
    if p > 0 then return p + 50 end
    return MIN_SHOE_APP_MONEY
end

function __L.getShoeAppData()
    local remoteEvents = ReplicatedStorage:FindFirstChild("RemoteEvents")
    if not remoteEvents then return nil end
    local remote = remoteEvents:FindFirstChild("GetShoesAppData")
    if not remote then return nil end
    local ok, data = pcall(function() return remote:InvokeServer() end)
    if not ok or type(data) ~= "table" then
        LogEvent("ShoeAppData", "Failed to fetch data")
        return nil
    end
    return data
end

function __L.parseShoeEntry(entry)
    if type(entry) ~= "table" then return nil end
    local inner = (type(entry.value) == "table") and entry.value or entry
    if type(inner) ~= "table" then return nil end
    local name  = tostring(entry.key or inner.Sn or inner.Name or "Unknown")
    local price = tonumber(inner.Pc or inner.Price or inner.BuyPrice or 0) or 0
    local rel   = inner.tm or inner.Tm or inner.ReleaseTime or inner.releaseTime
    local t     = tonumber(rel)
    if t and t > 9999999999 then t = math.floor(t / 1000) end
    -- `Sn` is the exact string the BuyShoesApp remote expects (PhoneScript
    -- passes value.Sn). For Shoe App entries key == Sn, but keep both.
    local sn = tostring(inner.Sn or entry.key or name)
    -- [FIX] `Cw` is the live stock label the phone card shows as its
    -- "ColorName" text ("Stock: 3", "Stock: 1", "Stock: 0"). A drop at
    -- "Stock: 0" is sold out and the server always refuses it, so skipping it
    -- here stops the sniper (checkAndBuyShoeApp, the background watcher and the
    -- standalone Shoe App panel all do `if not parsed then continue end`)
    -- hammering a dead drop for the whole 600s keep-alive window. Only skip
    -- when a number is actually parsed, so a missing/renamed field can never
    -- hide a live drop.
    local stock = nil
    if inner.Cw ~= nil then
        local n = tostring(inner.Cw):match("(%d+)")
        if n then stock = tonumber(n) end
    end
    if stock and stock <= 0 then return nil end
    return { name = name, sn = sn, price = price, release = t, stock = stock }
end

-- ── Shoe App UI-driven buy ─────────────────────────────────────────────────
-- The BuyShoesApp remote is DEAD without client-side selection state that
-- only a real UI card click sets (server error at PhoneServerScript:385:
-- "attempt to perform arithmetic (add) on nil and number"). So purchases
-- are driven through the actual phone UI with real VIM clicks — the same
-- mechanism as the external auto-clicker that provably works:
--   phone open → ShoesApp open → click the drop's card (InfoFrame sheet
--   slides up, BuyButton moves on-screen) → click BuyButton → verify.
-- firesignal is NEVER used here: it corrupts the phone's page tween state.
local SHOE_PHONE_OPEN_X = 1400 -- PhoneFrame.X: ~979 open / ~1551 closed

local function findInPhone(phone, name)
    local function walk(o, depth)
        if depth > 12 then return nil end
        for _, v in ipairs(o:GetChildren()) do
            if v.Name == name then return v end
            local r = walk(v, depth + 1)
            if r then return r end
        end
        return nil
    end
    return phone and walk(phone, 0) or nil
end

function __L.getShoePhone()
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    if not pg then return nil, nil end
    local phone = pg:FindFirstChild("PhoneGui")
    local pf    = phone and phone:FindFirstChild("PhoneFrame")
    return phone, pf
end

local function shoeVimClick(obj)
    if not obj or not obj:IsA("GuiObject") then return false end
    local ok = pcall(function()
        local pos   = obj.AbsolutePosition
        local size  = obj.AbsoluteSize
        local cx, cy = pos.X + size.X / 2, pos.Y + size.Y / 2
        local VIM = game:GetService("VirtualInputManager")
        VIM:SendMouseButtonEvent(cx, cy, 0, true,  game, 1)
        VIM:SendMouseButtonEvent(cx, cy, 0, false, game, 1)
    end)
    return ok
end

function __L.shoeOnScreen(obj)
    if not obj or not obj:IsA("GuiObject") then return false end
    local cam = workspace.CurrentCamera
    local vp  = cam and cam.ViewportSize or Vector2.new(1536, 889)
    local p   = obj.AbsolutePosition
    local s   = obj.AbsoluteSize
    return p.X >= 0 and p.Y >= 0 and (p.X + s.X) <= vp.X and (p.Y + s.Y) <= vp.Y
end

function __L.ensureShoePhoneOpen(pf)
    if not pf then return false end
    if pf.AbsolutePosition.X < SHOE_PHONE_OPEN_X then return true end
    local opb = pf:FindFirstChild("OpenPhoneButton")
    if not opb then return false end
    if not shoeVimClick(opb) then return false end
    local deadline = tick() + 3
    while tick() < deadline do
        deltaWait(0.25)
        if pf.AbsolutePosition.X < SHOE_PHONE_OPEN_X then
            deltaWait(0.4) -- let the slide animation finish
            return true
        end
    end
    LogEvent("ShoeAppBuy", "Phone did not open after OPB click")
    return false
end

function __L.ensureShoesAppOpen(phone, ins)
    local shoes = ins and ins:FindFirstChild("ShoesFrame")
    if shoes and shoes.Visible then return shoes end
    local home = findInPhone(phone, "HomeButton")
    if home then shoeVimClick(home) end
    deltaWait(0.5)
    local icon = findInPhone(phone, "ShoesApp")
    if not icon then return nil end
    if not shoeVimClick(icon) then return nil end
    local deadline = tick() + 3
    while tick() < deadline do
        deltaWait(0.25)
        if shoes and shoes.Visible then
            deltaWait(0.3)
            return shoes
        end
    end
    LogEvent("ShoeAppBuy", "ShoesApp did not open after icon click")
    return nil
end

function __L.findShoeAppCards(listFrame)
    local cards = {}
    if not listFrame then return cards end
    local containers = { listFrame }
    local sf = listFrame:FindFirstChildOfClass("ScrollingFrame")
    if sf then table.insert(containers, sf) end
    for _, container in ipairs(containers) do
        for _, child in ipairs(container:GetChildren()) do
            if child:IsA("ScrollingFrame") then continue end
            if not (child:IsA("Frame") or child:IsA("ImageButton") or child:IsA("TextButton")) then continue end
            -- Live card layout (verified 2026-09-06): the card Frame's Name
            -- is a throwaway ("funnyFortnite"); the drop's real name sits in
            -- a TypeName label ("Air Bogdan 6 x Awake NY"). The buy control
            -- is the card's BuyButton, whose text is the countdown until the
            -- drop ("1 Day 15 Hours") then flips to "Purchase". There is no
            -- NameText / ButtonToClick anymore.
            local name = ""
            local tn   = child:FindFirstChild("TypeName")
            if tn and (tn:IsA("TextLabel") or tn:IsA("TextButton")) then
                name = tostring(tn.Text or "")
            end
            local bb  = child:FindFirstChild("BuyButton")
            local btn = (bb and bb:IsA("GuiButton")) and bb or child:FindFirstChild("ButtonToClick")
            table.insert(cards, {
                card = child,
                btn  = (btn and btn:IsA("GuiButton")) and btn or (child:IsA("GuiButton") and child or nil),
                name = name,
            })
        end
    end
    return cards
end

function __L.pickShoeCard(cards, targetName)
    if #cards == 0 then return nil end
    if targetName and targetName ~= "" then
        local target = tostring(targetName):lower()
        for _, c in ipairs(cards) do
            local cardName = tostring(c.name):lower()
            -- Match either containment direction: the rendered TypeName label
            -- truncates the colorway (live dump showed "Air Bogdan 6 x Awake NY"
            -- on the card vs "...Midnight Navy" in the server key), so the card
            -- name can be a prefix of the target instead of the other way round.
            if cardName ~= "" and (cardName:find(target, 1, true) or target:find(cardName, 1, true)) then return c end
        end
    end
    for _, c in ipairs(cards) do
        local b = c.btn or c.card
        if __L.shoeOnScreen(b) then return c end
    end
    return cards[1]
end

function __L.looksLikeTimerText(text)
    local txt = tostring(text or ""):lower()
    if txt:find("left") or txt:find("until") or txt:find(":%d%d") then return true end
    local digits = txt:gsub("%D", "")
    return #digits >= 1 and txt:find("[smh]") ~= nil
end

function __L.findCardTimerButton(card)
    local root = card and (card.btn or card.card)
    if not root then return nil end
    for _, desc in ipairs(root:GetDescendants()) do
        if not (desc:IsA("TextButton") or desc:IsA("ImageButton")) then continue end
        if not desc.Visible then continue end
        if __L.looksLikeTimerText(desc.Text) then return desc end
    end
    return nil
end

-- The buy flow needs one thing the old code skipped: the clickable buy
-- control is the drop card's own BuyButton, the one whose visible text is
-- The buy flow needs one thing the old code skipped: the clickable buy
-- control is the drop card's own BuyButton, the one whose visible text is
-- the countdown ("1 Day 15 Hours") that flips to "Purchase" when the drop
-- goes live. A click inside any other card area (the frame, the image) does
-- nothing. Debug dump disabled to save local registers.
function __L.dumpShoeAppCards(listFrame)
    -- no-op: debug dump disabled
end

-- After a successful purchase the game raises GotEmFrame over the phone
-- center with a Claim button; it swallows card clicks until dismissed.
-- Decompiled ClaimButton handler is a pure cosmetic tween (no server
-- invoke): TweenPosition((0.5, 0, 1.5, 0), In, Quad, 0.1) + wait(0.15),
-- so replicate it directly. A claim click is NOT needed -- the buy already
-- happened on BuyButton, and ClaimButton sits below the 889px viewport
-- (abs Y ~1150) so VIM clicks cannot reach it anyway.
function __L.dismissShoeGotEm(shoes)
    if not shoes then return false end
    local gem = shoes:FindFirstChild("GotEmFrame")
    if not gem or not gem.Visible then return false end
    if gem.AbsolutePosition.Y >= 1500 then return false end
    LogEvent("ShoeAppBuy", "Dismissing GotEmFrame (claim tween)")
    pcall(function()
        gem:TweenPosition(UDim2.new(0.5, 0, 1.5, 0), Enum.EasingDirection.In, Enum.EasingStyle.Quad, 0.1, false)
    end)
    task.wait(0.15)
    -- Tween target (1.5 scale) still overlaps the phone's lower half, which
    -- would swallow the next BuyButton click. The game clears it on its own
    -- 5s refresh; clear it immediately instead.
    gem.Visible = false
    return true
end

local attemptShoeAppBuy
local attemptShoeAppBuyUI

-- ── Shoe App phone helpers (UI fallback in own scope) ───────────────────────
do
    function attemptShoeAppBuyUI(targetName, minMoney)
        local moneyBefore = getMoney()
        if moneyBefore < (minMoney or MIN_SHOE_APP_MONEY) then
            return "broke", 0
        end

        local phone, pf = __L.getShoePhone()
        if not pf then
            LogEvent("ShoeAppBuy", "Phone UI not found")
            return "error", 0
        end

        if not __L.ensureShoePhoneOpen(pf) then return "error", 0 end

        local ins   = pf:FindFirstChild("InsideFrame")
        local shoes = __L.ensureShoesAppOpen(phone, ins)
        if not shoes then return "error", 0 end

        -- Re-read fresh: ShoesFrame tracks the phone's X, so child positions
        -- only settle after the phone/app slide animations finish.
        local listFrame = shoes:FindFirstChild("ListFrame")
        local cards     = __L.findShoeAppCards(listFrame)
        if #cards == 0 then
            -- No drop listed right now — normal when the app is empty. Try one
            -- re-open cycle in case the list just failed to sync, then give up.
            local home = findInPhone(phone, "HomeButton")
            if home then shoeVimClick(home) end
            deltaWait(0.6)
            if not (shoes and shoes.Visible) then
                local icon = findInPhone(phone, "ShoesApp")
                if icon then shoeVimClick(icon) end
                deltaWait(0.8)
            end
            cards = __L.findShoeAppCards(listFrame)
            if #cards == 0 then return "fail", 0 end
        end

        local card = __L.pickShoeCard(cards, targetName)
        if not card then return "fail", 0 end

        __L.dumpShoeAppCards(listFrame)

        -- The card's BuyButton is the countdown control: its visible text is
        -- "1 Day 15 Hours"-style until the drop goes live, then "Purchase";
        -- clicking it invokes the buy remote directly (verified in the live
        -- decompile, PhoneScript:603-616). The InfoFrame details sheet is a
        -- separate, slower path — not needed for purchase. A raised GotEmFrame
        -- from an earlier buy swallows clicks, so dismiss it before the card.
        __L.dismissShoeGotEm(shoes)
        deltaWait(0.3)

        local btn = __L.findCardTimerButton(card) or card.btn or card.card
        if not btn then return "fail", 0 end
        __L.scrollIntoView(btn)
        deltaWait(0.3)
        if not shoeVimClick(btn) then
            LogEvent("ShoeAppBuy", "Card click failed")
            return "error", 0
        end
        deltaWait(0.2)

        local inv       = LocalPlayer:FindFirstChild("Inventory")
        local sellable  = inv and inv:FindFirstChild("SellableInventory")
        local invBefore = sellable and #sellable:GetChildren() or 0

        -- Poll for up to 4 s — accept success if money dropped OR inventory grew
        local pollDeadline = tick() + 4
        local moneyAfter   = getMoney()
        local invAfter     = 0
        while tick() < pollDeadline do
            deltaWait(0.25)
            moneyAfter = getMoney()
            local inv2      = LocalPlayer:FindFirstChild("Inventory")
            local sellable2 = inv2 and inv2:FindFirstChild("SellableInventory")
            invAfter = sellable2 and #sellable2:GetChildren() or 0
            local spent = moneyBefore - moneyAfter
            if spent > 0 or invAfter > invBefore then
                return "success", math.abs(math.max(spent, 0))
            end
        end

        LogEvent("ShoeAppBuy", "No purchase in 4s (money " .. moneyBefore .. "->" .. moneyAfter .. ", inv " .. invBefore .. "->" .. invAfter .. ")")
        return "fail", 0
    end
end

-- ── Shoe App remote-first buy (fast path) ───────────────────────────────────
-- The drop card's BuyButton handler in PhoneScript (decompiled live, :603-644)
-- ultimately runs exactly:
--     RemoteEvents.BuyShoesApp:InvokeServer(Sn)   -- Sn = the server shoe name
-- and it returns `true` on a real purchase, or a status STRING otherwise
-- ("Error" while the drop is not live, "Stock Ran Out", ...). Firing that
-- remote directly is the SAME server call the UI makes, but it skips the whole
-- open-phone + open-Shoes-app + VIM-click + 4s-poll flow that was making drops
-- slip past. A throw (unknown name) or a missing remote falls back to the UI.
local shoeRemoteErrStreak, shoeRemoteRejectStreak = 0, 0
local shoeInvokeBusy = false        -- single-flight: one BuyShoesApp call at a time
local shoeGateWarnAt = 0
-- [FIX] Two pacing locals used to live here (shoeLastCallAt / shoeFastUntil).
-- Nothing in the file ever read them, and each dead local held one of
-- bootScript()'s 200 registers, which is what pushed this whole chunk over
-- Luau's limit so the script would not even compile ("Out of local registers
-- ... exceeded limit 200" at the autostart block). Removed; register reclaim.

function __L.attemptShoeAppBuyRemote(shoeName, minMoney)
    local moneyBefore = getMoney()
    if moneyBefore < (minMoney or MIN_SHOE_APP_MONEY) then return "broke", 0 end
    if type(shoeName) ~= "string" or shoeName == "" then return "error", 0 end

    -- The server only answers BuyShoesApp while CanBuyShoesApp is true; while it
    -- is false the RemoteFunction does not return at all (observed live), which
    -- would freeze the sniper. Mirror the phone UI: wait for the gate, don't call.
    local gate = LocalPlayer:FindFirstChild("CanBuyShoesApp")
    if gate and gate:IsA("BoolValue") and gate.Value == false then
        if tick() - shoeGateWarnAt > 20 then
            shoeGateWarnAt = tick()
            LogEvent("ShoeApp", "CanBuyShoesApp=false - waiting for the buy gate")
        end
        return "fail", 0
    end

    local rEvents = ReplicatedStorage:FindFirstChild("RemoteEvents")
    local buy     = rEvents and rEvents:FindFirstChild("BuyShoesApp")
    if not buy then return "error", 0 end

    -- Bounded, single-flight call. If the gate closes mid-flight the invoke can
    -- block; give up so the drop loop keeps hammering instead of stalling. (The
    -- abandoned call still completes server-side if it can.)
    -- [FIX] The bound was a hard 1.5s, but the Sakura report measured this exact
    -- remote at rtt min=1.047 max=1.941s (placeId 12991635726, 2026-10-18), so a
    -- slow-but-SUCCESSFUL buy could be abandoned and written off as a failure
    -- (money spent, no ShoesBought++, no webhook, and the loop may buy again).
    -- 3s clears the measured max with margin; the drop window is 600s, so the
    -- handful of extra seconds a stalled call can cost is irrelevant.
    local SHOE_INVOKE_TIMEOUT = 3.0
    if shoeInvokeBusy then return "fail", 0 end
    shoeInvokeBusy = true
    local done, ok, res = false, nil, nil
    task.spawn(function()
        ok, res = pcall(function() return buy:InvokeServer(shoeName) end)
        done = true
        shoeInvokeBusy = false
    end)
    local t0 = tick()
    while not done and (tick() - t0) < SHOE_INVOKE_TIMEOUT do deltaWait(0.02) end
    if not done then
        shoeInvokeBusy = false
        LogEvent("ShoeAppBuy", "BuyShoesApp did not answer in " .. SHOE_INVOKE_TIMEOUT .. "s (stalled) - retrying")
        return "fail", 0
    end

    if not ok then
        LogEvent("ShoeAppBuy", "BuyShoesApp threw: " .. tostring(res))
        return "error", 0
    end
    if res == true then
        return "success", math.max(0, moneyBefore - getMoney())
    end
    return "rejected", 0, tostring(res)
end

-- Single entry point every watcher/loop calls, so all modes get the fast path.
function attemptShoeAppBuy(targetName, minMoney)
    local result, spent, reason = __L.attemptShoeAppBuyRemote(targetName, minMoney)
    if result == "success" then
        shoeRemoteErrStreak, shoeRemoteRejectStreak = 0, 0
        return "success", spent
    end
    if result == "broke" then return "broke", 0 end
    if result == "fail" then return "fail", 0 end

    if result == "rejected" then
        -- The server answered (remote works) but refused this attempt. Log the
        -- reason once, and every few refusals ALSO run one UI attempt as
        -- insurance in case a particular drop needs client-side state.
        shoeRemoteRejectStreak += 1
        if shoeRemoteRejectStreak == 1 or (shoeRemoteRejectStreak % 8) == 0 then
            LogEvent("ShoeApp", "BuyShoesApp -> " .. tostring(reason) .. " (" .. tostring(targetName) .. ")")
        end
        if (shoeRemoteRejectStreak % 8) == 0 then
            local uiRes, uiSpent = attemptShoeAppBuyUI(targetName, minMoney)
            if uiRes == "success" then
                shoeRemoteRejectStreak = 0
                return "success", uiSpent
            end
        end
        return "fail", 0
    end

    -- result == "error": the remote threw or is missing — lean on the phone UI.
    shoeRemoteErrStreak += 1
    if shoeRemoteErrStreak >= 3 then
        local uiRes, uiSpent = attemptShoeAppBuyUI(targetName, minMoney)
        if uiRes == "success" then shoeRemoteErrStreak = 0 end
        return uiRes, uiSpent
    end
    return "error", 0
end

-- ── Shoe App Auto Buy (used by Full Auto loop) ─────────────────────────────
function __L.checkAndBuyShoeApp()
    local data = __L.getShoeAppData()
    if not data then
        if canAlert("shoeapp_data_fail", 30) then
            Notify({
                Title    = "Shoe App",
                Content  = "Failed to fetch Shoe App data — remote may be missing.",
                Duration = 4,
                Image    = "X",
            })
        end
        return
    end

    local entries = (data[1] ~= nil) and data or { data }
    local now     = os.time()

    for _, entry in ipairs(entries) do
        if not (getgenv().FullAutoRunning or getgenv().PCFullAutoRunning) then break end

        local parsed = __L.parseShoeEntry(entry)
        if not parsed then continue end

        local secondsLeft = parsed.release and (parsed.release - now) or 0

        if secondsLeft > SHOE_ARM_SECONDS or secondsLeft < -SHOE_DROP_WINDOW then continue end

        if secondsLeft > 0 then
            Notify({
                Title    = "Shoe App - Drop Incoming",
                Content  = parsed.name .. " drops in " .. math.floor(secondsLeft) .. "s - spamming at release!",
                Duration = 5,
                Image    = "Check",
            })
        else
            Notify({
                Title    = "Shoe App - Buying Now",
                Content  = "Hammering " .. parsed.name .. "!",
                Duration = 3,
                Image    = "Check",
            })
        end

        local GRACE_SECONDS = SHOE_DROP_WINDOW
        local deadline      = tick() + math.max(secondsLeft, 0) + GRACE_SECONDS
        local errorCount    = 0
        local MAX_ERRORS    = 15
        local failStreak    = 0
        local totalBought   = 0

        while tick() < deadline
            and (getgenv().FullAutoRunning or getgenv().PCFullAutoRunning) do

            -- Min-money guard: skip if out of cash entirely
            if getMoney() < shoeBuyMinMoney(parsed.price) then
                if failStreak == 0 then
                    LogEvent("ShoeApp", "Out of money, skipping remaining buys")
                end
                failStreak += 1
                if failStreak >= 5 then
                    Notify({
                        Title    = "Shoe App - Out of Money",
                        Content  = "Bank too low for Shoe App, stopping buy attempts.",
                        Duration = 5,
                        Image    = "X",
                    })
                    break
                end
                deltaWait(0.5)
                continue
            end
            failStreak = 0

            local result, spent = attemptShoeAppBuy(parsed.sn or parsed.name, shoeBuyMinMoney(parsed.price))

            if result == "success" then
                totalBought += 1
                errorCount   = 0
                getgenv().ShoesBought = (getgenv().ShoesBought or 0) + 1
                getgenv().trackBoughtRarity(Sneakers[parsed.name])

                Notify({
                    Title    = "Shoe App - Bought",
                    Content  = parsed.name .. " x" .. totalBought .. " purchased for $" .. fmtNum(spent) .. "!",
                    Duration = 5,
                    Image    = "Check",
                })

                safeSpawn(function()
                    postWebhook(
                        "SRS Shoe App | by Sakura's Hub",
                        "Shoe App Purchase",
                        "**Shoe:** "               .. parsed.name   ..
                        "\n**Price Paid:** "        .. fmtMoney(spent) ..
                        "\n**Listed Price:** "      .. fmtMoney(parsed.price) ..
                        "\n**Bought This Drop:** "  .. tostring(totalBought) .. "\n"
                    )
                end)

                deltaWait(0.2)

            elseif result == "error" then
                errorCount += 1

                if errorCount >= MAX_ERRORS then
                    LogEvent("ShoeApp", "Remote errored " .. MAX_ERRORS .. "x on " .. parsed.name)
                    Notify({
                        Title    = "Shoe App - Remote Error",
                        Content  = parsed.name .. " - remote errored " .. MAX_ERRORS .. "x in a row, giving up.",
                        Duration = 6,
                        Image    = "X",
                    })
                    safeSpawn(function()
                        postWebhook(
                            "SRS Shoe App | by Sakura's Hub",
                            "Shoe App Buy Failed",
                            "**Shoe:** "     .. parsed.name ..
                            "\n**Reason:** Remote threw a Lua error " .. MAX_ERRORS .. " consecutive times." ..
                            "\n**Bought Before Failing:** " .. tostring(totalBought) .. "\n"
                        )
                    end)
                    break
                end

                deltaWait(0.2)

            elseif result == "broke" then
                LogEvent("ShoeApp", "Out of money, ending shoe app buys")
                Notify({
                    Title    = "Shoe App - Out of Money",
                    Content  = "Not enough money for Shoe App, stopping.",
                    Duration = 4,
                    Image    = "X",
                })
                break

            else
                -- "fail" — no purchase detected; apply adaptive backoff
                errorCount = 0
                local backoff = math.min(0.05 * math.pow(2, math.min(failStreak, 4)), 1.0)
                deltaWait(backoff)
            end
        end

        if totalBought == 0 then
            LogEvent("ShoeApp", "Window closed for " .. parsed.name .. ", 0 bought")
            Notify({
                Title    = "Shoe App - Window Closed",
                Content  = parsed.name .. " - 90s window ended. Got 0 shoes.",
                Duration = 5,
                Image    = "X",
            })
            safeSpawn(function()
                postWebhook(
                    "SRS Shoe App | by Sakura's Hub",
                    "Shoe App - Window Closed",
                    "**Shoe:** " .. parsed.name ..
                    "\n**Reason:** 90s grace window expired with 0 purchases.\n"
                )
            end)
        else
            Notify({
                Title    = "Shoe App - Drop Done",
                Content  = parsed.name .. " - bought " .. totalBought .. " total this drop!",
                Duration = 5,
                Image    = "X",
            })
        end
    end
end

-- ── Full Auto Loop ─────────────────────────────────────────────────────────
local walkToPC -- assigned after walkTo; used by fullAutoLoop and runAutoBuyLoop
local ensureAtStorePC -- buy-cycle proximity gate; assigned after walkToPC

-- Buy-budget bookkeeping. No machinery lives here, but both full-auto loops
-- call it every outer cycle so the swap check and the end-of-run stop agree
-- on what "budget spent" means to the user.
-- ── Buy-budget snapshot ────────────────────────────────────────────────────
-- ONE shared accounting for every buying mode (Full Auto, PC Full Auto, Semi
-- Auto, PC Semi Auto, Macro, Do Everything):
--   snapshot -> money when the run (or the new cycle) starts
--   spent    -> only what purchases actually cost; income never adds to it
-- When the snapshot is spent the mode swaps to selling; Full-style modes then
-- re-snapshot and buy again, so a buy phase can never run on forever.
function Helpers.budgetOn()
    return (Settings.Budget and Settings.Budget.Enabled) and true or false
end

function Helpers.snapshotBudget(announceTitle)
    getgenv().SRS_BuyBudget = getMoney()
    getgenv().SRS_BuySpent  = 0
    LogEvent("Budget", "snapshot=" .. tostring(getgenv().SRS_BuyBudget))
    if announceTitle and Helpers.budgetOn() then
        Notify({ Title = announceTitle, Content = "New buy budget: " .. fmtMoney(getgenv().SRS_BuyBudget), Duration = 3, Image = "Store" })
    end
end

function Helpers.budgetLeft()
    if not Helpers.budgetOn() then return math.huge end
    if getgenv().SRS_BuyBudget == nil then Helpers.snapshotBudget() end
    return math.max(0, (getgenv().SRS_BuyBudget or 0) - (getgenv().SRS_BuySpent or 0))
end

function Helpers.budgetExhausted()
    return Helpers.budgetOn() and Helpers.budgetLeft() <= 0
end

function Helpers.recordSpend(n)
    n = tonumber(n)
    if n and n > 0 then getgenv().SRS_BuySpent = (getgenv().SRS_BuySpent or 0) + n end
end

-- Cap for one buy phase: what is left of the snapshot, or (budget OFF) the
-- money in the wallet when the phase started.
function Helpers.phaseLimit()
    if Helpers.budgetOn() then return Helpers.budgetLeft() end
    return getMoney()
end

-- ── Shop page refresh pacing ───────────────────────────────────────────────
-- The game's own PC script (PCLocalScript.refreshfunction) waits 1s between
-- page refreshes, and 5s once DailyBoughtSneakers >= 5000. Invoking
-- RefreshPageFunction faster than that makes the server answer nil.
--
-- LIVE 2026-10-23: DailyBoughtSneakers was 8449, the full-auto loop retried a
-- nil refresh every 1s, burned all 8 strikes in ~10s and swapped to the sell
-- phase with $29.1M of a $29.1M buy budget still unspent. These helpers pace
-- every shop refresh exactly like the game's own UI and give failures a real
-- backoff instead of a 1s hammer.
function Helpers.refreshCooldown()
    local d = LocalPlayer:FindFirstChild("DailyBoughtSneakers")
    local n = d and tonumber(d.Value) or 0
    return (n >= 5000) and 5.0 or 1.0
end

-- Sleep only if the previous refresh happened less than one cooldown ago.
function Helpers.waitRefreshGap()
    local waitFor = ((getgenv().SRS_LastShopRefresh or 0) + Helpers.refreshCooldown()) - tick()
    if waitFor > 0 then deltaWait(waitFor) end
end

-- After a nil page: never faster than the game's own cooldown, +0.5s per
-- consecutive strike (capped at +2s).
function Helpers.refreshBackoff(strikes)
    return Helpers.refreshCooldown() + math.min(math.max((strikes or 1) - 1, 0), 4) * 0.5
end

-- RefreshPageFunction with the game's own pacing. Signature matches
-- RefreshPageFunction:InvokeServer() -> ok, items.
function Helpers.refreshShopPage()
    Helpers.waitRefreshGap()
    local ok, items = pcall(function()
        return ReplicatedStorage.RemoteEvents.RefreshPageFunction:InvokeServer()
    end)
    getgenv().SRS_LastShopRefresh = tick()
    return ok, items
end

function __L.fullAutoLoop()
    LogEvent("FullAuto", "Started")
    Notify({ Title = "Full Automation", Content = "Full Automation started!", Duration = 3, Image = "Check" })
    getgenv().ShoesBoughtBeforeCycle = getgenv().ShoesBought
    getgenv().ShoesSoldBeforeCycle   = getgenv().ShoesSold

    -- Walk to the store PC on enable. Buy remotes work from anywhere, so a
    -- failed walk must never block the loop.
    walkToPC(function() return getgenv().FullAutoRunning and srsAlive() end)

    while getgenv().FullAutoRunning and srsAlive() do
        -- [FIX] Void guard: a frozen/flung character used to fall for minutes and
        -- could trip a server kick. Respawn instead of continuing the loop.
        local _chr = LocalPlayer.Character
        local _hrp = _chr and _chr:FindFirstChild("HumanoidRootPart")
        local _hum = _chr and _chr:FindFirstChildOfClass("Humanoid")
        if _hrp and _hum and ((_hrp.Position - Vector3.new(-318, 100, 370)).Magnitude > 2000 or _hrp.Position.Y < -200) then
            LogEvent("Recover", "fullAuto: character voided at " .. tostring(_hrp.Position) .. " -> respawn")
            pcall(function() _hum.Health = 0 end)
            deltaWait(3)
            continue
        end
        local skipBuy = false
        if Helpers.budgetExhausted() then
            if inventoryIsEmpty() then
                Helpers.snapshotBudget("Full Automation")
                if Helpers.budgetExhausted() then
                    if canAlert("fa_zero_budget", 300) then
                        Notify({ Title = "Full Automation", Content = "No money to buy with and nothing to sell — waiting for income.", Duration = 5, Image = "X" })
                    end
                    deltaWait(5)
                    continue
                end
            else
                skipBuy = true
                warn("[FA] Buy budget spent (" .. tostring(getgenv().SRS_BuySpent) .. "/" .. tostring(getgenv().SRS_BuyBudget) .. ") — selling inventory first")
                Notify({ Title = "Full Automation", Content = "Budget spent — selling inventory.", Duration = 3, Image = "Check" })
                LogEvent("FullAuto", "Budget spent -> sell (spent=" .. tostring(getgenv().SRS_BuySpent) .. " budget=" .. tostring(getgenv().SRS_BuyBudget) .. " balance=" .. tostring(getMoney()) .. ")")
            end
        end
        safeSpawn(__L.checkAndBuyShoeApp)

        Notify({ Title = "Full Automation", Content = "Buy phase — checking shop offers...", Duration = 2, Image = "Store" })
        warn("[FA] ── Buy phase start ── Money:", getMoney(), "Inventory:", LocalPlayer:FindFirstChild("Inventory") and #(LocalPlayer.Inventory:FindFirstChild("SellableInventory") and LocalPlayer.Inventory.SellableInventory:GetChildren() or {}) or "?")

        local strikes     = 0
        local MAX_STRIKES = 8
        local failSince   = nil   -- first nil refresh of the current outage
        local buyPhaseMoney = Helpers.phaseLimit()
        local realSpent     = 0
        local shopOpened    = false
        Helpers.cyclePhase("buy", buyPhaseMoney)

        while not skipBuy and getgenv().FullAutoRunning and srsAlive() do
            if strikes >= MAX_STRIKES then
                warn("[FA] Strikes exhausted (" .. strikes .. "/" .. MAX_STRIKES .. ") → sell phase")
                Notify({ Title = "Full Automation", Content = "Retries exhausted — switching to sell phase.", Duration = 3, Image = "Store" })
                LogEvent("FullAuto", "Buy phase → sell: refresh failures x" .. MAX_STRIKES)
                strikes = 0
                break
            end

            ensureAtStorePC(function() return getgenv().FullAutoRunning and srsAlive() end)
            -- [FIX] Close a leftover sell bar BEFORE opening the shop; the game
            -- rejects shop-page refreshes while the bar is up.
            closeSellBar()
            -- Buying is remote-only: the PC screen is never opened here (only the
            -- Macro uses the shop GUI), so the camera is never taken over.
            local ok, items = Helpers.refreshShopPage()

            -- ═══ Server error: paced retry up to MAX_STRIKES ═══
            if not ok or type(items) ~= "table" then
                strikes += 1
                failSince = failSince or tick()
                local failSpan = tick() - failSince
                local budgetLeftNow = math.max(0, buyPhaseMoney - realSpent)
                warn("[FA] Server error — strike " .. strikes .. "/" .. MAX_STRIKES
                    .. " (" .. math.floor(failSpan) .. "s failing, $" .. fmtNum(budgetLeftNow) .. " budget left)")
                Helpers.healthError()
                LogEvent("FullAuto", "refresh FAILED strike " .. strikes .. "/" .. MAX_STRIKES
                    .. " ok=" .. tostring(ok) .. " items=" .. tostring(items)
                    .. " failingFor=" .. math.floor(failSpan) .. "s")
                Notify({ Title = "Full Automation", Content = "Page refresh failed (" .. strikes .. "/" .. MAX_STRIKES .. ") — retrying...", Duration = 2, Image = "X" })
                -- A nil page is usually a server cooldown hiccup, not a dead
                -- shop. Do NOT swap to selling while the buy budget is mostly
                -- unspent: keep retrying with the game's own refresh cooldown
                -- (5s once DailyBoughtSneakers >= 5000) for up to 90s.
                if strikes >= MAX_STRIKES then
                    if buyPhaseMoney > 0 and realSpent < buyPhaseMoney and failSpan < 90 then
                        warn("[FA] Refresh outage " .. math.floor(failSpan) .. "s — $" .. fmtNum(budgetLeftNow) .. " of buy budget left, still retrying")
                        Notify({ Title = "Full Automation", Content = "Shop page not responding — still retrying (" .. math.floor(failSpan) .. "s, " .. fmtMoney(budgetLeftNow) .. " left)", Duration = 3, Image = "X" })
                        strikes = 0   -- failSpan is the real timeout; don't poison the buy-0 counter
                    else
                        warn("[FA] Strikes exhausted after " .. math.floor(failSpan) .. "s → sell phase")
                        Notify({ Title = "Full Automation", Content = "Retries exhausted — switching to sell phase.", Duration = 3, Image = "Store" })
                        LogEvent("FullAuto", "Buy phase → sell: refresh failures x" .. MAX_STRIKES
                            .. " over " .. math.floor(failSpan) .. "s (spent=" .. realSpent .. " limit=" .. buyPhaseMoney .. ")")
                        strikes = 0
                        break
                    end
                end
                deltaWait(Helpers.refreshBackoff(strikes))
                continue
            end
            failSince = nil

            local firstK, firstV = next(items)
            LogEvent("FullAuto", "refresh OK items=" .. tostring(type(items)) .. " first=" .. tostring(firstK) .. ":" .. tostring(firstV))
            __L.dumpOfferStructure(1)
            __L.dumpOfferStructure(2)
            local canBuy, reason = __L.canAffordAnyOffer(items)

            -- ═══ Nothing buyable: just retry (could be blank page or all blacklisted) ═══
            if not canBuy and (reason == "no_items" or reason == "all_blacklisted") then
                warn("[FA] No items to buy (reason: " .. reason .. ") — refreshing...")
                Notify({ Title = "Full Automation", Content = "No buyable items — refreshing page...", Duration = 2, Image = "Store" })
                deltaWait(1)
                continue
            end

            -- ═══ Attempt every eligible offer — the server is the authority ═══
            -- The original script fired the buy remote at every offer and let
            -- the server accept/reject. Client-side price guesses here were
            -- wrong (log: money=66 vs price=69 → "unaffordable" → sold without
            -- ever attempting). Server rejections are counted by strikes below.
            -- Sell when the real buy money is gone: purchases draw buyPhaseMoney
            -- down while employee pay keeps the visible balance up — that passive
            -- income must not mask "can't afford any more".
            if realSpent >= buyPhaseMoney then
                warn("[FA] Buy money spent (" .. realSpent .. "/" .. buyPhaseMoney .. ") — can't afford more")
                Notify({ Title = "Full Automation", Content = "Out of buy money (employee pay excluded) — selling inventory", Duration = 3, Image = "Check" })
                LogEvent("FullAuto", "Buy phase → sell: unaffordable realSpent=" .. realSpent .. " phaseMoney=" .. buyPhaseMoney .. " balance=" .. tostring(getMoney()))
                break
            end
            warn("[FA] Page has items — running buy cycle")
            local bought, failedOffers, spentThisPage, skippedOver = runBuyCycle(items, getgenv().FullAutoSpeed, { limit = buyPhaseMoney - realSpent })
            realSpent += (spentThisPage or 0); Helpers.cycleProgress(realSpent); Helpers.healthPage(bought, failedOffers)

            if bought > 0 then
                warn("[FA] Bought " .. bought .. " shoes — resetting strikes")
                Notify({ Title = "Full Automation", Content = "Bought " .. bought .. " shoe(s) this page!", Duration = 3, Image = "Check" })
            end

            -- ═══ Budget spent (or nothing left that fits it): swap to selling NOW ═══
            if realSpent >= buyPhaseMoney or (bought == 0 and (skippedOver or 0) > 0 and (failedOffers or 0) == 0) then
                warn("[FA] Buy budget used (" .. realSpent .. "/" .. buyPhaseMoney .. ") → sell phase")
                Notify({ Title = "Full Automation", Content = "Budget spent — selling inventory.", Duration = 3, Image = "Check" })
                LogEvent("FullAuto", "Buy phase → sell: budget used realSpent=" .. realSpent .. " phaseLimit=" .. buyPhaseMoney .. " balance=" .. tostring(getMoney()))
                break
            end

            -- ═══ Buy returned 0: back off and retry up to MAX_STRIKES ═══
            if bought == 0 then
                strikes += 1
                local capMode = (failedOffers or 0) > 0
                warn("[FA] Buy returned 0 — strike " .. strikes .. "/" .. MAX_STRIKES .. (capMode and (" (" .. failedOffers .. " server rejections — PC capped or sold out)") or ""))
                -- Server refuses to sell (offers capped/sold out): retrying the
                -- same page is pointless — confirm 3x quickly, then sell instead.
                if capMode and strikes >= 3 then
                    warn("[FA] Shop rejected purchases x" .. strikes .. " → sell phase")
                    Notify({ Title = "Full Automation", Content = "Shop rejected purchases — switching to sell phase.", Duration = 3, Image = "Store" })
                    LogEvent("FullAuto", "Buy phase → sell: shop rejected x" .. strikes .. " (money=" .. tostring(getMoney()) .. ")")
                    break
                end
                if strikes >= MAX_STRIKES then
                    warn("[FA] Buy retries exhausted → sell phase")
                    Notify({ Title = "Full Automation", Content = "Buy attempts exhausted — switching to sell phase.", Duration = 3, Image = "Store" })
                    LogEvent("FullAuto", "Buy phase → sell: 0 purchases across " .. MAX_STRIKES .. " pages (money=" .. tostring(getMoney()) .. ")")
                    break
                end
                if capMode then
                    Notify({ Title = "Full Automation", Content = "Shop not selling (" .. strikes .. "/3) — retrying in " .. math.min(strikes * 5, 15) .. "s...", Duration = 2, Image = "X" })
                    deltaWait(math.min(strikes * 5, 15))
                else
                    Notify({ Title = "Full Automation", Content = "No purchase registered (" .. strikes .. "/" .. MAX_STRIKES .. ") — retrying...", Duration = 2, Image = "X" })
                    deltaWait(math.min(strikes, 5))
                end
                continue
            end

            strikes = 0
            deltaWait(getReloadDelay(getgenv().FullAutoSpeed))
        end

        local cycleBought = getgenv().ShoesBought - (getgenv().ShoesBoughtBeforeCycle or 0)
        safeSpawn(function()
            __L.sendWebhook("Buy Cycle Complete", "**Shoes Bought This Cycle:** " .. fmtNum(cycleBought))
        end)
        getgenv().ShoesBoughtBeforeCycle = getgenv().ShoesBought

        if not getgenv().FullAutoRunning then break end
        if inventoryIsEmpty() then
            warn("[FA] No inventory to sell — skipping sell phase")
            if getMoney() < MIN_CASH_TO_SKIP_TINY_SELL and canAlert("broke_stuck", 600) then
                LogEvent("FullAuto", "STUCK: broke + no inventory (money=" .. tostring(getMoney()) .. ") — nothing to buy or sell; earn money first")
                Notify({ Title = "Full Automation", Content = "Broke & no inventory — nothing to buy or sell. Earn money first.", Duration = 5, Image = "X" })
            end
            deltaWait(2); continue
        end
        if __L.shouldSkipSell() then
            warn("[FA] Only " .. sellableInventoryCount() .. " shoe(s) with $" .. tostring(getMoney()) .. " — skipping pointless sell, looping back to buy")
            Notify({ Title = "Full Automation", Content = "Too few shoes to sell — back to buying.", Duration = 2, Image = "Store" })
            LogEvent("FullAuto", "Sell phase skipped: tiny inventory (money=" .. tostring(getMoney()) .. ")")
            Helpers.snapshotBudget("Full Automation")
            deltaWait(2)
            continue
        end

        Helpers.cyclePhase("sell")
        warn("[FA] ── Sell phase start ── Money:", getMoney(), "ShoesSold so far:", getgenv().ShoesSold)
        Notify({ Title = "Full Automation", Content = "Sell phase — selling inventory...", Duration = 2, Image = "Store" })
        getgenv().ShoesSoldBeforeCycle = getgenv().ShoesSold
        -- Try to complete and redeem quests for 2x money if possible
        safeSpawn(function()
            pcall(function()
                if Helpers.checkDailyQuests then Helpers.checkDailyQuests(true) end
            end)
        end)
        -- [FIX] Leave the PC shop (restores the normal camera and re-enables
        -- the prompt) before walking to the vendor, so the sell phase plays
        -- out on the normal game view.
        Helpers.closeShop()
        __L.runSellCycle()
        Helpers.snapshotBudget("Full Automation")
        -- After selling, try to redeem quests and hop to next session if configured
        safeSpawn(function()
            pcall(function()
                if Helpers.checkDailyQuests then Helpers.checkDailyQuests(true) end
            end)
        end)
        -- Halloween (one toggle on the Halloween tab): open the Candy boxes,
        -- then trade in the moment the shoes read 5/5.
        if Helpers.halloweenCycle and Settings.HalloweenTradeIn and Settings.HalloweenTradeIn.Enabled then
            getgenv().SRS_HalloweenFromSell = true
            Notify({ Title = "Halloween", Content = "Armed - Will run after sell", Duration = 2, Image = "Store" })
            pcall(Helpers.halloweenCycle, function() return getgenv().FullAutoRunning and srsAlive() end)
            getgenv().SRS_HalloweenFromSell = nil
        else
            getgenv().SRS_HalloweenFromSell = nil
        end
        -- Back to the store PC so the next buy phase starts from the shop,
        -- not the sell NPC (reads as a real restock run).
        walkToPC(function() return getgenv().FullAutoRunning and srsAlive() end)
        deltaWait(0.5)
        -- Auto server hop after sell cycle if enabled
        safeSpawn(function()
            local st = getgenv().SRS_Stability
            if st and st.hopAfterSell then
                deltaWait(2)
                if getgenv()._SRS_serverHop then
                    getgenv()._SRS_serverHop(game.PlaceId)
                elseif serverHopToLowest then
                    serverHopToLowest(game.PlaceId)
                end
            end
        end)
    end

    getgenv().FullAutoRunning   = false
    getgenv().SRS_HalloweenFromSell = nil
    getgenv().FullAutoSwitching = true
    safeSetToggle("SlowFullAuto", false)
    safeSetToggle("MediumFullAuto", false)
    safeSetToggle("FastFullAuto", false)
    safeSetToggle("RiskySlowFullAuto", false)
    safeSetToggle("RiskyMediumFullAuto", false)
    safeSetToggle("RiskyFastFullAuto", false)
    getgenv().FullAutoSwitching = false

    Notify({ Title = "Full Automation", Content = "Full Automation stopped.", Duration = 3, Image = "X" })
    LogEvent("FullAuto", "Stopped")
end

-- ── Background Shoe App Watcher (persistent, runs alongside Full Auto) ─────
function __L.shoeAppBackgroundWatcher()
    LogEvent("ShoeAppWatcher", "Started")
    local activeDrops = {}

    while State.shoeAppWatcherRunning and srsAlive() do
        local data = __L.getShoeAppData()

        if data then
            local entries = (data[1] ~= nil) and data or { data }
            local now     = os.time()

            for _, entry in ipairs(entries) do
                if not State.shoeAppWatcherRunning then break end

                local parsed = __L.parseShoeEntry(entry)
                if not parsed or not parsed.release then continue end

                local secondsLeft = parsed.release - now
                local dropKey     = parsed.name .. "_" .. tostring(parsed.release)

                if secondsLeft > SHOE_ARM_SECONDS or secondsLeft < -SHOE_DROP_WINDOW then continue end
                if activeDrops[dropKey] then continue end

                activeDrops[dropKey] = true

                safeSpawn(function()
                    if secondsLeft > 0 then
                        deltaWait(secondsLeft)
                    end

                    if not State.shoeAppWatcherRunning then
                        activeDrops[dropKey] = nil
                        return
                    end

                    local GRACE_SECONDS = SHOE_DROP_WINDOW
                    local deadline      = tick() + GRACE_SECONDS
                    local errorCount    = 0
                    local MAX_ERRORS    = 15
                    local totalBought   = 0

                    while State.shoeAppWatcherRunning and srsAlive() and tick() < deadline do
                        local result, spent = attemptShoeAppBuy(parsed.sn or parsed.name, shoeBuyMinMoney(parsed.price))

                        if result == "success" then
                            totalBought   += 1
                            errorCount     = 0
                            getgenv().ShoesBought = (getgenv().ShoesBought or 0) + 1
                            getgenv().trackBoughtRarity(Sneakers[parsed.name])

                            Notify({
                                Title    = "Shoe App - Bought",
                                Content  = parsed.name .. " x" .. totalBought .. " | $" .. fmtNum(spent),
                                Duration = 4,
                                Image    = "Check",
                            })

                            safeSpawn(function()
                                postWebhook(
                                    "SRS Shoe App | by Sakura's Hub",
                                    "Shoe App Purchase",
                                    "**Shoe:** "              .. parsed.name   ..
                                    "\n**Price Paid:** "       .. fmtMoney(spent) ..
                                    "\n**Listed Price:** "     .. fmtMoney(parsed.price) ..
                                    "\n**Bought This Drop:** " .. tostring(totalBought) .. "\n"
                                )
                            end)

                            deltaWait(0.3)

                        elseif result == "error" then
                            errorCount += 1
                            if errorCount >= MAX_ERRORS then
                                safeSpawn(function()
                                    postWebhook(
                                        "SRS Shoe App | by Sakura's Hub",
                                        "Shoe App Buy Failed",
                                        "**Shoe:** "    .. parsed.name ..
                                        "\n**Reason:** Remote errored " .. MAX_ERRORS .. " times.\n" ..
                                        "\n**Bought Before Failing:** " .. tostring(totalBought) .. "\n"
                                    )
                                end)
                                break
                            end
                            deltaWait(0.2)

                        else
                            errorCount = 0
                            deltaWait(0.05)
                        end
                    end

                    if totalBought > 0 then
                        safeSpawn(function()
                            postWebhook(
                                "SRS Shoe App | by Sakura's Hub",
                                "Drop Complete",
                                "**Shoe:** " .. parsed.name ..
                                "\n**Total Bought:** " .. tostring(totalBought) .. "\n"
                            )
                        end)
                    end

                    task.delay(120, function()
                        activeDrops[dropKey] = nil
                    end)
                end)
            end
        end

        deltaWait(5)
    end
    LogEvent("ShoeAppWatcher", "Stopped")
end

function __L.startShoeAppWatcher()
    if State.shoeAppWatcherRunning then return end
    LogEvent("ShoeAppWatcher", "Starting...")
    State.shoeAppWatcherRunning = true
    State.shoeAppWatcherThread  = task.spawn(__L.shoeAppBackgroundWatcher)
end

function __L.stopShoeAppWatcher()
    State.shoeAppWatcherRunning = false
    if State.shoeAppWatcherThread then
        task.cancel(State.shoeAppWatcherThread)
        State.shoeAppWatcherThread = nil
    end
end

local function startFullAuto(speed, callerToggle)
    getgenv().FullAutoSwitching = true
    cancelOtherAutomation(callerToggle)
    getgenv().FullAutoSwitching = false

    LogEvent("FullAuto", "Starting speed=" .. tostring(speed))
    -- [FIX] Start with the script window visible so the user can stop/change
    -- it; K (built-in toggle) hides/shows it again.
    if Helpers.openUI then pcall(Helpers.openUI) end
    if Helpers.forceCloseShop then pcall(Helpers.forceCloseShop) end
    if fullAutoThread then pcall(task.cancel, fullAutoThread); fullAutoThread = nil end
    Settings.Buy.Enabled = false
    Settings.Sell        = false
    getgenv().FullAutoSpeed   = speed
    getgenv().FullAutoRunning = true
    getgenv().MoneyAtCycleStart = getMoney()
    getgenv().SRS_BuyBudget = getMoney()
    getgenv().SRS_BuySpent  = 0
    __L.startShoeAppWatcher()

    safeSpawn(function()
        __L.sendWebhook("Full Automation Started", "**Speed:** " .. speed)
    end)

    fullAutoThread = task.spawn(__L.fullAutoLoop)
end

local function stopFullAuto()
    getgenv().FullAutoRunning = false
    Helpers.cyclePhase("idle")
    -- [FIX] A mode switch (FullAutoSwitching) used to return here before any
    -- cleanup, leaving a sell bar / PC shop open. Keep the log and webhook
    -- quiet on a switch, but always cancel the worker and close both GUIs.
    local switching = getgenv().FullAutoSwitching
    if not switching then LogEvent("FullAuto", "Stopping...") end
    local selfThread = coroutine.running()
    if fullAutoThread and fullAutoThread ~= selfThread then
        task.cancel(fullAutoThread); fullAutoThread = nil
    end
    stopSellBarListener()
    closeSellBar()
    -- [FIX] Hand the camera back if the PC shop screen was left open.
    if Helpers.forceCloseShop then pcall(Helpers.forceCloseShop) end
    __L.stopShoeAppWatcher()
    if not switching then
        safeSpawn(function()
            __L.sendWebhook("Full Automation Stopped")
        end)
        Notify({ Title = "Full Automation", Content = "Full Automation stopped.", Duration = 3, Image = "X" })
    end
end

-- ── Full Auto sub-page ──────────────────────────────────────────────────────
SubPages:Register("Full Auto", Tabs.AutoBuy, function(T, elements)
    SubPages:Nav(T, { label = "Auto Buy Page", options = { "Full Auto", "Semi Auto", "Human Speeds" }, flag = "NAV_AutoBuy", default = "Full Auto" })
    T("CreateSection", "Full Auto")
    T("CreateLabel", "WHAT IT DOES: walks to your store PC, refreshes the shop and buys every non-blacklisted shoe (best rarity first) until your Buy Budget is spent, then walks to the sell NPC and sells EVERY shoe, takes a fresh budget snapshot and repeats forever.")
    T("CreateLabel", "ALSO: snipes Shoe App drops by firing the game's own BuyShoesApp remote the instant a drop goes live (phone-UI clicks only as a fallback), claims daily quests before and after selling, and opens doors on the way (the walker finds and triggers door prompts).")
    T("CreateLabel", "STOPS WHEN: you turn it off, you teleport/server hop, or you are broke with nothing to sell (it then waits for income instead of spinning).")
    T("CreateSection", "Buy + Sell Cycle + Buy Drop Shoe If Has Less Than 60 Seconds")
    T("CreateLabel", "Slow: 1.5s buy delay | 6s reload delay")

    Toggles.SlowFullAuto = T("CreateToggle", {
        Name = "Slow Full Automation", CurrentValue = false, Flag = "SlowFullAuto",
        Callback = function(state)
            if state then startFullAuto("slow",   Toggles.SlowFullAuto)
            else stopFullAuto() end
        end,
    })

    T("CreateLabel", "Medium: 1.0s buy delay | 5s reload delay")

    Toggles.MediumFullAuto = T("CreateToggle", {
        Name = "Medium Full Automation", CurrentValue = false, Flag = "MediumFullAuto",
        Callback = function(state)
            if state then startFullAuto("medium", Toggles.MediumFullAuto)
            else stopFullAuto() end
        end,
    })

    T("CreateLabel", "Fast: 0.5s buy delay | 4s reload delay")

    Toggles.FastFullAuto = T("CreateToggle", {
        Name = "Fast Full Automation", CurrentValue = false, Flag = "FastFullAuto",
        Callback = function(state)
            if state then startFullAuto("fast",   Toggles.FastFullAuto)
            else stopFullAuto() end
        end,
    })

    T("CreateSection", "Auto-Stop")
    Toggles.AutoStopTarget = T("CreateToggle", {
        Name = "Auto-Stop at Target Balance",
        CurrentValue = getgenv().SRS_AutoStopAtTarget == true,
        Flag = "AutoStopTarget",
        Callback = function(state)
            getgenv().SRS_AutoStopAtTarget = state and true or false
            if state and (tonumber(getgenv().SRS_TargetBalance) or 0) <= 0 then
                Notify({ Title = "Auto-Stop", Content = "Set a target balance below first", Duration = 4, Image = "Alert" })
            end
        end,
    })
    T("CreateInput", {
        Name = "Target Balance ($)",
        PlaceholderText = tostring(math.floor(tonumber(getgenv().SRS_TargetBalance) or 0)),
        RemoveTextAfterFocusLost = false,
        Callback = function(text)
            local num = tonumber((tostring(text):gsub("[^%d%.%-]", "")))
            if num and num >= 0 then
                getgenv().SRS_TargetBalance = math.floor(num)
                Notify({ Title = "Auto-Stop", Content = "Target set to $" .. fmtMoney(getgenv().SRS_TargetBalance), Duration = 2, Image = "Check" })
            end
        end,
    })

    Helpers.buildBudgetToggle(T)
end)

-- ── Semi Automation helpers (module-level, like startFullAuto) ─────────────
function __L.analyzeNoBuyReason(Items)
    if type(Items) ~= "table" or next(Items) == nil then
        return "empty"
    end
    -- No client-side price/unlock gates: any non-blacklisted offer is worth
    -- attempting — the server accepts/rejects (old script fired at every offer).
    for _, sneakerName in pairs(Items) do
        local data = Sneakers[sneakerName]
        if not data then continue end
        if isBlacklisted(data) then continue end
        return "ok"
    end
    return "blacklisted"
end

local function runAutoBuyLoop(speed, toggleRef)
    Settings.Buy.Enabled = true
    getgenv().SRS_BuyLoopId = (getgenv().SRS_BuyLoopId or 0) + 1
    local myBuyId = getgenv().SRS_BuyLoopId
    getgenv().SRS_LastBuySpeed = speed
    -- Semi buying only buys: no budget snapshot, no buy->sell swap, no stop on
    -- a spent budget. It runs until you turn it off (or the shop truly stalls).
    local tag = speed:gsub("^%l", string.upper)
    local boughtAtStart = getgenv().ShoesBought
    local strikes = 0
    local noBuyBroke = 0
    local buyDelay    = getBuyDelay(speed)
    local reloadDelay = getReloadDelay(speed)
    warn("[AUTOBUY/" .. tag .. "] Starting — buyDelay:", buyDelay, "reloadDelay:", reloadDelay)
    if Settings.Buy.Enabled then
        walkToPC(function() return Settings.Buy.Enabled end)
    end
    while true do
        if not srsAlive() or myBuyId ~= getgenv().SRS_BuyLoopId then return end
        if not Settings.Buy.Enabled then
            LogEvent("SemiAutoBuy", "Stopped by toggle speed=" .. tag)
            return
        end
        ensureAtStorePC(function() return Settings.Buy.Enabled end)
        closeSellBar()
        local okItems, Items = Helpers.refreshShopPage()
        if not okItems or type(Items) ~= "table" then
            strikes += 1
            warn("[AUTOBUY/" .. tag .. "] Server error — strike " .. strikes .. "/5")
            if strikes >= 3 then
                Notify({ Title = "Auto Buy (" .. tag .. ")", Content = "Server error " .. strikes .. "/5 — retrying...", Duration = 3, Image = "Alert" })
            end
            if strikes >= 5 then
                local boughtThisRun = getgenv().ShoesBought - boughtAtStart
                warn("[AUTOBUY/" .. tag .. "] Strikes exhausted — stopping (bought:", boughtThisRun, ")")
                LogEvent("SemiAutoBuy", "Stopped strikes speed=" .. tag .. " bought=" .. boughtThisRun)
                Settings.Buy.Enabled = false
                safeSpawn(function()
                    postWebhook("SRS Semi Automation | by Sakura's Hub", "Auto Buy Done",
                        "**Speed:** " .. tag .. "\n**Shoes Bought This Run:** " .. fmtNum(boughtThisRun) .. "\n")
                end)
                Notify({ Title = "Auto Buy", Content = "Server not responding — Auto Buy stopped.", Duration = 4, Image = "X" })
                getgenv().FullAutoSwitching = true
                if toggleRef then pcall(toggleRef.Set, toggleRef, false) end
                getgenv().FullAutoSwitching = false
                return
            end
            deltaWait(Helpers.refreshBackoff(strikes)); continue
        end
        local boughtThisCycle, failedOffers, _, skippedOver = runBuyCycle(Items, speed, {
            running = function() return Settings.Buy.Enabled and myBuyId == getgenv().SRS_BuyLoopId end,
        })
        if not srsAlive() or not Settings.Buy.Enabled or myBuyId ~= getgenv().SRS_BuyLoopId then return end
        if boughtThisCycle == 0 then
            if failedOffers > 0 then
                -- Server rejected every eligible offer (PC capped / sold out):
                -- wait it out, don't count this as "broke".
                warn("[AUTOBUY/" .. tag .. "] All " .. failedOffers .. " buy(s) rejected server-side — PC capped or sold out, waiting 15s")
                deltaWait(15)
            end
            local reason = __L.analyzeNoBuyReason(Items)
            -- Broke = balance actually empty (client money is accurate; it was
            -- the client *price guesses* that were wrong, so they're removed).
            if getMoney() <= 0 then
                noBuyBroke += 1
                warn("[AUTOBUY/" .. tag .. "] Broke cycle " .. noBuyBroke .. "/10")
                if noBuyBroke >= 10 then
                    local boughtThisRun = getgenv().ShoesBought - boughtAtStart
                    local actuallyBroke = getMoney() <= 0
                    warn("[AUTOBUY/" .. tag .. "] No affordable offers — stopping (bought:", boughtThisRun, " money:", getMoney(), ")")
                    LogEvent("SemiAutoBuy", "Stopped broke speed=" .. tag .. " bought=" .. boughtThisRun .. " money=" .. tostring(getMoney()))
                    Settings.Buy.Enabled = false
                    safeSpawn(function()
                        postWebhook("SRS Semi Automation | by Sakura's Hub", "Auto Buy Done",
                            "**Speed:** " .. tag .. "\n**Shoes Bought This Run:** " .. fmtNum(boughtThisRun) .. "\n**Reason:** " .. (actuallyBroke and "Ran out of money" or "No affordable offers for a while") .. "\n")
                    end)
                    Notify({ Title = "Auto Buy", Content = actuallyBroke and ("Out of money! Bought " .. fmtNum(boughtThisRun) .. " shoes.") or ("No affordable offers — stopped. Bought " .. fmtNum(boughtThisRun) .. " shoes."), Duration = 5, Image = "X" })
                    getgenv().FullAutoSwitching = true
                    if toggleRef then pcall(toggleRef.Set, toggleRef, false) end
                    getgenv().FullAutoSwitching = false
                    return
                end
                deltaWait(3)
            else
                noBuyBroke = 0
                if reason == "blacklisted" or reason == "empty" then
                    warn("[AUTOBUY/" .. tag .. "] All blacklisted or empty page — refreshing")
                    Notify({ Title = "Auto Buy (" .. tag .. ")", Content = reason == "blacklisted" and "All items blacklisted — retrying..." or "Empty page — retrying...", Duration = 2, Image = "Alert" })
                end
            end
            deltaWait(1)
        else
            strikes = 0
            noBuyBroke = 0
            warn("[AUTOBUY/" .. tag .. "] Bought " .. boughtThisCycle .. " — resetting counters")
            Notify({ Title = "Auto Buy", Content = "Bought " .. boughtThisCycle .. " shoe(s) this page!", Duration = 3, Image = "Check" })
        end
        deltaWait(reloadDelay)
    end
end

-- ── Semi Automation ───────────────────────────────────────────────────────
-- ═══════════════════════════════════════════════════════════════════════════
-- Auto Upgrade Store (v4 rewrite) — Helpers.Upg
-- Clicks the shelf-upgrade ClickDetectors in YOUR store until every shelf is
-- maxed. Old version bugs fixed:
--   * "maxed" was decided by "money did not drop in 1.5s". Being too poor, or
--     income landing during the window, marked a shelf maxed FOREVER and then
--     server hopped. Now: the shelf's own label/price is read; a shelf you
--     cannot afford is WAITED for; "maxed" needs the label to say MAX, or 4
--     no-effect clicks while the label said you could afford it.
--   * Money is sampled every 0.1s and the LOWEST value counts (income cannot
--     hide a purchase).
--   * Walks to the shelf when far (ClickDetectors have an activation distance).
--   * Single loop (id-guarded), stopped by every other automation and by
--     shutdown, status label, and a "Dump Store Upgrades" button that writes
--     the store layout + shelf labels to Script Logs for debugging.
-- Lives in its own function so bootScript() spends no registers on it.
-- ═══════════════════════════════════════════════════════════════════════════
;(function()
local U = { id = 0, clicks = 0, bought = 0, status = "Idle" }
Helpers.Upg = U
U.GROUPS = { "LeftShelves", "BackShelves", "RightShelves" }
local SUFFIX = { k = 1e3, m = 1e6, b = 1e9, t = 1e12 }

local function parsePrice(text)
    if type(text) ~= "string" then return nil end
    local t = text:gsub("<[^>]->", ""):gsub(",", "")
    -- a suffix only counts when it is a lone K/M/B/T letter ("$100 Tokens" is 100)
    local num, word = t:match("%$%s*(%d[%d%.]*)%s*(%a*)")
    local dollar = num ~= nil
    if not num then num, word = t:match("(%d[%d%.]*)%s*(%a*)") end
    local n = tonumber(num)
    if not n then return nil end
    local mult = (#word == 1) and SUFFIX[word:lower()] or nil
    if not dollar and not mult then return nil end -- bare number with no $ and no suffix: not a price
    return n * (mult or 1)
end
U.parsePrice = parsePrice

local function setStatus(txt)
    U.status = txt
    if PageRefs.upgStatusLabel then
        pcall(function() PageRefs.upgStatusLabel:Set("Status: " .. txt) end)
    end
end

-- price (number|nil), maxed (bool), joined label text
function U.readInfo(part)
    local texts = {}
    local roots = { part }
    local par = part.Parent
    if par and par:IsA("Model") then roots[2] = par end
    local n = 0
    for _, root in ipairs(roots) do
        for _, d in ipairs(root:GetDescendants()) do
            n += 1
            if n > 150 then break end
            if d:IsA("TextLabel") or d:IsA("TextButton") then
                local ok, tx = pcall(function() return d.Text end)
                if ok and type(tx) == "string" and tx ~= "" then texts[#texts + 1] = tx end
            end
        end
    end
    local joined = table.concat(texts, " | ")
    local price = nil
    for _, tx in ipairs(texts) do
        local p = parsePrice(tx)
        if p and p > 0 and (not price or tx:find("$", 1, true)) then price = p end
    end
    for _, k in ipairs({ "Price", "Cost", "UpgradePrice", "UpgradeCost" }) do
        local ok, v = pcall(function() return part:GetAttribute(k) end)
        if ok and type(v) == "number" and v > 0 and not price then price = v end
    end
    local low = joined:lower()
    local hasMax = low:find("%f[%a]max%f[%A]") or low:find("%f[%a]maxed%f[%A]") or low:find("sold out", 1, true)
    return price, (hasMax ~= nil and not price), joined
end

-- Upgrade targets in YOUR store:
--   1) Ground "button" parts (BackWall / LeftShelves / MurakamiRug / BackShelves
--      / Floor2 / Bot3) carry a Cost attribute and a TouchTransmitter — they
--      are bought by TOUCHING them, and the touch fires from anywhere (no
--      proximity needed). Once bought, the part is destroyed, which is also
--      the "maxed" signal.
--   2) Legacy stores use shelf ClickDetectors; those still work as a fallback.
-- Owned-upgrade memory. A part counts as OWNED when the game marks it so
-- (Owned/Bought/Purchased/Unlocked/Maxed attribute, CanTouch off, a label
-- saying owned/purchased/bought/maxed/sold out) or when this script already
-- bought it / saw it ignore touches. Remembered on getgenv() so a re-run in
-- the same Roblox session never retries what it already knows is owned.
getgenv().SRS_UpgOwned = getgenv().SRS_UpgOwned or {}
local OWNED_ATTRS = { "Owned", "Bought", "Purchased", "Unlocked", "IsOwned", "Maxed" }
local OWNED_WORDS = { "owned", "purchased", "bought", "maxed", "sold out", "unlocked" }
local function ownedKey(part)
    return tostring(LocalPlayer.UserId) .. ":" .. part.Name
end
function U.markOwned(part)
    if part then getgenv().SRS_UpgOwned[ownedKey(part)] = true end
end
function U.isOwned(part)
    if not part then return true end
    if getgenv().SRS_UpgOwned[ownedKey(part)] then return true end
    for _, a in ipairs(OWNED_ATTRS) do
        local ok, v = pcall(function() return part:GetAttribute(a) end)
        if ok and v == true then return true end
    end
    local okT, ct = pcall(function() return part.CanTouch end)
    if okT and ct == false then return true end
    -- a label that says "owned" etc. (a price label means it is still for sale)
    local n = 0
    for _, d in ipairs(part:GetDescendants()) do
        n += 1
        if n > 40 then break end
        if d:IsA("TextLabel") or d:IsA("TextButton") then
            local ok, tx = pcall(function() return d.Text end)
            if ok and type(tx) == "string" and tx ~= "" and not tx:find("$", 1, true) then
                local low = tx:lower()
                for _, w in ipairs(OWNED_WORDS) do
                    if low:find(w, 1, true) then return true end
                end
            end
        end
    end
    return false
end

function U.collect(store)
    local list, seen = {}, {}
    local raw = 0
    local function push(part)
        if seen[part] or not part:IsA("BasePart") then return end
        seen[part] = true
        raw += 1
        if U.isOwned(part) then return end -- already own it: never touch it again
        list[#list + 1] = { part = part, cd = part:FindFirstChildOfClass("ClickDetector") }
    end
    -- 1) ground buttons: direct children with a positive Cost attribute
    for _, v in ipairs(store:GetChildren()) do
        if v:IsA("BasePart") then
            local okC, c = pcall(function() return v:GetAttribute("Cost") end)
            if okC and type(c) == "number" and c > 0 then push(v) end
        end
    end
    -- deeper nested buttons (some store layouts bury them)
    if raw == 0 then
        local n = 0
        for _, v in ipairs(store:GetDescendants()) do
            n += 1
            if n % 600 == 0 then task.wait() end
            if v:IsA("BasePart") then
                local okC, c = pcall(function() return v:GetAttribute("Cost") end)
                if okC and type(c) == "number" and c > 0 then push(v) end
            end
        end
    end
    -- 2) legacy shelf ClickDetectors (only when there are no ground buttons)
    if raw == 0 then
        for _, g in ipairs(U.GROUPS) do
            local grp = store:FindFirstChild(g)
            if grp then
                for _, v in ipairs(grp:GetDescendants()) do
                    local cd = v:FindFirstChildOfClass("ClickDetector")
                    if cd then push(v) end
                end
            end
        end
    end
    return list
end

local function getReputation()
    local ls = LocalPlayer:FindFirstChild("leaderstats")
    local v = ls and ls:FindFirstChild("Reputation")
    return v and v.Value or 0
end

-- Touch the button part (works from anywhere — no proximity — which is why
-- the default is REMOTE buying). firetouchinterest(hrp, part, 0) starts the
-- touch; the toggle-off call is a no-op on some executors and unnecessary.
local function tryBuyTarget(part)
    local hrp = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
    if not hrp or not part or not part.Parent then return false end
    pcall(function() firetouchinterest(hrp, part, 0) end)
    return true
end

-- Returns "allmaxed" when every upgrade is bought, "stopped" otherwise.
function U.run(keepGoing)
    local st = {}
    local idle = 0
    while keepGoing() do
        local store = getStore()
        if not store then setStatus("waiting for your store"); deltaWait(2.5); continue end
        local list = U.collect(store)
        if #list == 0 then
            idle += 1
            setStatus("no upgrades left (all bought)")
            if idle >= 8 then return "allmaxed" end
            deltaWait(1.5)
            continue
        end
        idle = 0
        local active, maxedN, waiting, did = 0, 0, 0, false
        for _, e in ipairs(list) do
            if not keepGoing() then return "stopped" end
            local s = st[e.part]
            if not s then s = { fails = 0, cool = 0, failMaxed = false }; st[e.part] = s end
            if s.failMaxed then
                maxedN += 1
            else
                active += 1
                local cost = nil
                local okC, c = pcall(function() return e.part:GetAttribute("Cost") end)
                if okC and type(c) == "number" and c > 0 then cost = c end
                if not cost then
                    local p, _, _ = U.readInfo(e.part)
                    cost = p
                end
                local money = getMoney()
                local rep = getReputation()
                -- Rep-cost buttons (e.g. the rug) are affordable by rep.
                local affordable = cost == nil or money >= cost or rep >= cost
                if not affordable then
                    waiting += 1 -- cannot afford yet: wait for income, never a failure
                elseif tick() >= s.cool then
                    if Settings.WalkToStoreButtons and Helpers.SmartWalkTo then
                        setStatus("walking to " .. e.part.Name)
                        Helpers.SmartWalkTo(e.part.Position, keepGoing, { reach = 6, maxTime = 20 })
                    end
                    if not keepGoing() then return "stopped" end
                    setStatus("upgrading " .. e.part.Name .. (cost and (" (" .. fmtMoney(cost) .. ")") or ""))
                    local beforeMoney, beforeRep = getMoney(), getReputation()
                    local lowestMoney, lowestRep = beforeMoney, beforeRep
                    U.clicks += 1
                    pcall(fireclickdetector, e.cd) -- no-op when there is no ClickDetector
                    tryBuyTarget(e.part)
                    local t0 = tick()
                    while tick() - t0 < 1.5 and keepGoing() do
                        deltaWait(0.1)
                        local m, r = getMoney(), getReputation()
                        if m < lowestMoney then lowestMoney = m end
                        if r < lowestRep then lowestRep = r end
                    end
                    local spentMoney = beforeMoney - lowestMoney
                    local spentRep = beforeRep - lowestRep
                    local gone = not e.part.Parent
                    if gone or spentMoney >= 1 or spentRep >= 1 then
                        s.fails = 0
                        did = true
                        U.bought += 1
                        U.markOwned(e.part)
                        s.failMaxed = true
                        LogEvent("Upgrade", string.format("%s bought (money=%s rep=%s gone=%s)", e.part.Name, tostring(spentMoney), tostring(spentRep), tostring(gone)))
                    else
                        -- No purchase and the part is still there: either it is
                        -- an unaffordable Rep item (wait), or something is wrong.
                        if cost and (money >= cost or rep >= cost) then s.fails += 1 else waiting += 1 end
                        s.cool = tick() + (cost and math.min(20, 3 * s.fails) or 60)
                        if s.fails >= 2 then
                            s.failMaxed = true
                            U.markOwned(e.part)
                            Log("WARN", "[Upgrade] " .. e.part:GetFullName() .. " treated as already owned: " .. s.fails .. " touches did nothing (cost " .. tostring(cost) .. ")")
                        end
                    end
                end
            end
        end
        if active == 0 then return "allmaxed" end
        if waiting > 0 and not did then
            setStatus(string.format("waiting for money (%d unaffordable, %d maxed)", waiting, maxedN))
        elseif not did then
            setStatus(string.format("%d active, %d maxed", active, maxedN))
        end
        deltaWait(did and 0.5 or 2.5)
    end
    return "stopped"
end

function U.start()
    U.id += 1
    local myId = U.id
    Settings.Buttons = true
    setStatus("starting")
    safeSpawn(function()
        local res = U.run(function() return Settings.Buttons and srsAlive() and U.id == myId end)
        if U.id ~= myId or not srsAlive() then return end
        if res == "allmaxed" then
            Settings.Buttons = false
            setStatus("every store upgrade is bought")
            safeSetToggle("AutoUpgradeStore", false)
            Notify({ Title = "Auto Upgrade Store", Content = "All store upgrades bought.", Duration = 5, Image = "Check" })
            LogEvent("Upgrade", "all upgrade buttons bought; clicks=" .. U.clicks .. " upgrades=" .. U.bought)
        else
            setStatus("stopped")
        end
    end)
end

function U.stop()
    U.id += 1
    Settings.Buttons = false
    setStatus("stopped")
end

function U.dump()
    local store = getStore()
    if not store then
        Log("WARN", "[UpgradeDump] store not found (Workspace.Stores." .. LocalPlayer.Name .. "Store)")
        Notify({ Title = "Upgrade Dump", Content = "Store not found.", Duration = 4, Image = "X" })
        return
    end
    Log("INFO", "[UpgradeDump] store=" .. store:GetFullName() .. " money=" .. tostring(getMoney()))
    for _, c in ipairs(store:GetChildren()) do
        Log("INFO", string.format("[UpgradeDump] child %s (%s) kids=%d", c.Name, c.ClassName, #c:GetChildren()))
    end
    local list = U.collect(store)
    local inList = {}
    for i, e in ipairs(list) do
        inList[e.cd] = true
        local price, maxed, txt = U.readInfo(e.part)
        local attrs = {}
        for k, v in pairs(e.part:GetAttributes()) do attrs[#attrs + 1] = tostring(k) .. "=" .. tostring(v) end
        Log("INFO", string.format("[UpgradeDump] shelf %d %s (%s) clickDist=%s price=%s maxed=%s labels=%s attrs=%s",
            i, e.part:GetFullName(), e.part.ClassName, tostring(e.cd.MaxActivationDistance),
            tostring(price), tostring(maxed), txt:sub(1, 160), table.concat(attrs, ",")))
    end
    local other, n = 0, 0
    for _, v in ipairs(store:GetDescendants()) do
        n += 1
        if n % 500 == 0 then task.wait() end
        if v:IsA("ClickDetector") and not inList[v] then
            other += 1
            if other <= 20 then Log("INFO", "[UpgradeDump] other ClickDetector (NOT used): " .. v:GetFullName()) end
        end
    end
    Log("INFO", string.format("[UpgradeDump] done: %d shelves used, %d other ClickDetectors", #list, other))
    Notify({ Title = "Upgrade Dump", Content = #list .. " shelves found. See Info > Script Logs ([UpgradeDump]).", Duration = 5, Image = "Check" })
end
end)()

SubPages:Register("Semi Auto", Tabs.AutoBuy, function(T, elements)
SubPages:Nav(T, { label = "Auto Buy Page", options = { "Full Auto", "Semi Auto", "Human Speeds" }, flag = "NAV_AutoBuy", default = "Full Auto" })
T("CreateSection", "Semi Auto")
T("CreateLabel", "Semi Auto = ONE job at a time. Pick the job you want; it stops by itself when the job is done.")
T("CreateLabel", "Auto Sell: walks to the sell NPC and sells EVERY shoe on the bar (no rarity order, nothing left behind), stops when your sellable inventory is empty.")
T("CreateLabel", "Auto Upgrade Store: clicks each shelf upgrade until every shelf is maxed, then server hops.")
T("CreateLabel", "Auto Buy: refreshes the shop and buys until the Buy Budget is spent or you are broke, then stops. Slow/Medium/Fast only change the delay between buys and refreshes.")
Toggles.AutoSell = T("CreateToggle", {
    Name = "Auto Sell", CurrentValue = false, Flag = "AutoSell",
    Callback = function(state)
        if state then
            cancelOtherAutomation(Toggles.AutoSell)
            safeSpawn(function()
                postWebhook("SRS Semi Automation | by Sakura's Hub", "Auto Sell Started", "")
            end)
    end
    safeSpawn(function()
        Settings.Sell = state
        if state then
            safeSpawn(function()
                local soldAtStart = getgenv().ShoesSold
                if Helpers.closeShop then pcall(Helpers.closeShop) end
                startSellBarListener()
                startSellAdaptLoop()
                while Settings.Sell and srsAlive() do
                    if inventoryIsEmpty() then
                        stopSellBarListener()
                        Settings.Sell = false
                        local soldThisRun = getgenv().ShoesSold - soldAtStart
                        safeSpawn(function()
                            postWebhook("SRS Semi Automation | by Sakura's Hub", "Auto Sell Done",
                                "**Shoes Sold This Run:** " .. fmtNum(soldThisRun) .. "\n")
                        end)
                        Notify({ Title = "Auto Sell", Content = "Inventory empty — Auto Sell stopped.", Duration = 4, Image = "Check" })
                        getgenv().FullAutoSwitching = true
                        safeSetToggle("AutoSell", false)
                        getgenv().FullAutoSwitching = false
                        return
                    end
                    if not SellFrame or not SellFrame.Visible then
                        local okSell, sellErr = pcall(__L.sellToNPC)
                        if not okSell then warn("[SELL] sellToNPC error: " .. tostring(sellErr)) end
                    end
                    deltaWait(0.1)
                end
                stopSellBarListener()
                closeSellBar()
            end)
        else
            stopSellBarListener()
            closeSellBar()
            if Helpers.closeShop then pcall(Helpers.closeShop) end
        end
    end)
end,
})

PageRefs.upgStatusLabel = T("CreateLabel", "Status: " .. tostring(Helpers.Upg.status))
T("CreateLabel", "Store buttons are bought remotely by touch (no walking). Enable the toggle below to walk to each button first.")
Toggles.WalkToStoreButtons = T("CreateToggle", {
    Name = "Walk to store buttons before buying", CurrentValue = false, Flag = "UpgWalkToButtons",
    Callback = function(state)
        Settings.WalkToStoreButtons = state
    end,
})
Toggles.AutoUpgradeStore = T("CreateToggle", {
    Name = "Auto Upgrade Store", CurrentValue = false, Flag = "AutoButtons",
    Callback = function(state)
        Notify({ Title = "Auto Upgrade Store", Content = state and "Started" or "Stopped", Duration = 3, Image = state and "Check" or "X" })
        if state then
            cancelOtherAutomation(Toggles.AutoUpgradeStore)
            Helpers.Upg.start()
        else
            Helpers.Upg.stop()
        end
    end,
})
T("CreateButton", {
    Name = "Forget Owned Upgrades (retry everything)",
    Callback = function()
        getgenv().SRS_UpgOwned = {}
        Notify({ Title = "Auto Upgrade Store", Content = "Owned-upgrade memory cleared.", Duration = 3, Image = "Check" })
    end,
})
T("CreateButton", {
    Name = "Dump Store Upgrades (to Script Logs)",
    Callback = function() safeSpawn(Helpers.Upg.dump) end,
})

T("CreateLabel", "Slow: 1.5s buy delay | 6s reload delay")
Toggles.SlowAutoBuy = T("CreateToggle", {
    Name = "Slow Auto Buy Sneakers", CurrentValue = false, Flag = "AutoBuySlow",
    Callback = function(state)
        if state then
            cancelOtherAutomation(Toggles.SlowAutoBuy)
            safeSpawn(function()
                postWebhook("SRS Semi Automation | by Sakura's Hub", "Auto Buy Started", "**Speed:** Slow\n")
            end)
            LogEvent("SemiAutoBuy", "Started speed=slow")
        end
        safeSpawn(function()
            Settings.Buy.Enabled = state
            if state then runAutoBuyLoop("slow", Toggles.SlowAutoBuy) end
        end)
    end,
})

T("CreateLabel", "Medium: 1.0s buy delay | 5s reload delay")
Toggles.MediumAutoBuy = T("CreateToggle", {
    Name = "Medium Auto Buy Sneakers", CurrentValue = false, Flag = "AutoBuyMedium",
    Callback = function(state)
        if state then
            cancelOtherAutomation(Toggles.MediumAutoBuy)
            safeSpawn(function()
                postWebhook("SRS Semi Automation | by Sakura's Hub", "Auto Buy Started", "**Speed:** Medium\n")
            end)
            LogEvent("SemiAutoBuy", "Started speed=medium")
        end
        safeSpawn(function()
            Settings.Buy.Enabled = state
            if state then runAutoBuyLoop("medium", Toggles.MediumAutoBuy) end
        end)
    end,
})

T("CreateLabel", "Fast: 0.5s buy delay | 4s reload delay")
Toggles.FastAutoBuy = T("CreateToggle", {
    Name = "Fast Auto Buy Sneakers", CurrentValue = false, Flag = "AutoBuyFast",
    Callback = function(state)
        if state then
            cancelOtherAutomation(Toggles.FastAutoBuy)
            safeSpawn(function()
                postWebhook("SRS Semi Automation | by Sakura's Hub", "Auto Buy Started", "**Speed:** Fast\n")
            end)
            LogEvent("SemiAutoBuy", "Started speed=fast")
        end
        safeSpawn(function()
            Settings.Buy.Enabled = state
            if state then runAutoBuyLoop("fast", Toggles.FastAutoBuy) end
        end)
    end,
})
end)

-- ── Risky sub-page: Semi Auto's old (faster) timings, made real & opt-in ──
-- ── Risky hub: EVERY risky-speed automation lives on this one tab ─────────
-- Pages: Risky Buy / Risky Full Auto / Risky PC / Risky Macro / Risky Dig. Nothing risky is
-- built on any other tab, so the safe pages stay clean.
function Helpers.riskyNav(T)
    SubPages:Nav(T, {
        label   = "Risky Page",
        options = { "Risky Buy", "Risky Full Auto", "Risky PC", "Risky Macro", "Risky Dig" },
        flag    = "NAV_RISKY",
        default = "Risky Buy",
    })
end

SubPages:Register("Risky Buy", Tabs.Risky, function(T, elements)
    Helpers.riskyNav(T)
    T("CreateSection", "Risky Buy")
    T("CreateLabel", "Same as Auto Buy but with much shorter delays. Faster = more shoes per minute AND a higher chance of a ban. Use only for short sessions.")
    T("CreateLabel", "Faster than Full Auto — bans reported on these speeds (see Info tab)")
    T("CreateLabel", "Risky Slow: 0.25s buy delay | 3.5s reload delay")

    Toggles.SlowRiskyBuy = T("CreateToggle", {
        Name = "Risky Slow Auto Buy", CurrentValue = false, Flag = "RiskySlowBuy",
        Callback = function(state)
            if state then
                cancelOtherAutomation(Toggles.SlowRiskyBuy)
                safeSpawn(function()
                    postWebhook("SRS Semi Automation | by Sakura's Hub", "Auto Buy Started (RISKY)", "**Speed:** Risky Slow\n")
                end)
                LogEvent("SemiAutoBuy", "Started speed=risky_slow")
            end
            safeSpawn(function()
                Settings.Buy.Enabled = state
                if state then runAutoBuyLoop("risky_slow", Toggles.SlowRiskyBuy) end
            end)
        end,
    })

    T("CreateLabel", "Risky Medium: 0.15s buy delay | 2s reload delay")
    Toggles.MediumRiskyBuy = T("CreateToggle", {
        Name = "Risky Medium Auto Buy", CurrentValue = false, Flag = "RiskyMediumBuy",
        Callback = function(state)
            if state then
                cancelOtherAutomation(Toggles.MediumRiskyBuy)
                safeSpawn(function()
                    postWebhook("SRS Semi Automation | by Sakura's Hub", "Auto Buy Started (RISKY)", "**Speed:** Risky Medium\n")
                end)
                LogEvent("SemiAutoBuy", "Started speed=risky_medium")
            end
            safeSpawn(function()
                Settings.Buy.Enabled = state
                if state then runAutoBuyLoop("risky_medium", Toggles.MediumRiskyBuy) end
            end)
        end,
    })

    T("CreateLabel", "Risky Fast: 0.05s buy delay | 1s reload delay")
    Toggles.FastRiskyBuy = T("CreateToggle", {
        Name = "Risky Fast Auto Buy", CurrentValue = false, Flag = "RiskyFastBuy",
        Callback = function(state)
            if state then
                cancelOtherAutomation(Toggles.FastRiskyBuy)
                safeSpawn(function()
                    postWebhook("SRS Semi Automation | by Sakura's Hub", "Auto Buy Started (RISKY)", "**Speed:** Risky Fast\n")
                end)
                LogEvent("SemiAutoBuy", "Started speed=risky_fast")
            end
            safeSpawn(function()
                Settings.Buy.Enabled = state
                if state then runAutoBuyLoop("risky_fast", Toggles.FastRiskyBuy) end
            end)
        end,
    })
end)

-- ── Risky Full Auto sub-page ─────────────────────────────────────────────
SubPages:Register("Risky Full Auto", Tabs.Risky, function(T, elements)
    Helpers.riskyNav(T)
    T("CreateSection", "Risky Full Auto")
    T("CreateLabel", "Same walk + buy + sell loop as Full Auto, but with the shortest delays. Bans reported on this speed (see Info tab). Short sessions only.")
    T("CreateLabel", "Risky Slow: 0.25s buy delay | 3.5s reload delay")
    Toggles.RiskySlowFullAuto = T("CreateToggle", {
        Name = "Risky Slow Full Automation", CurrentValue = false, Flag = "RiskySlowFullAuto",
        Callback = function(state)
            if state then startFullAuto("risky_slow", Toggles.RiskySlowFullAuto)
            else stopFullAuto() end
        end,
    })

    T("CreateLabel", "Risky Medium: 0.15s buy delay | 2s reload delay")
    Toggles.RiskyMediumFullAuto = T("CreateToggle", {
        Name = "Risky Medium Full Automation", CurrentValue = false, Flag = "RiskyMediumFullAuto",
        Callback = function(state)
            if state then startFullAuto("risky_medium", Toggles.RiskyMediumFullAuto)
            else stopFullAuto() end
        end,
    })

    T("CreateLabel", "Risky Fast: 0.05s buy delay | 1s reload delay")
    Toggles.RiskyFastFullAuto = T("CreateToggle", {
        Name = "Risky Fast Full Automation", CurrentValue = false, Flag = "RiskyFastFullAuto",
        Callback = function(state)
            if state then startFullAuto("risky_fast", Toggles.RiskyFastFullAuto)
            else stopFullAuto() end
        end,
    })
    Helpers.buildBudgetToggle(T)
end)

-- ── Human Speeds sub-page ───────────────────────────────────────────────────
-- Human-like delays with random jitter. These are the safest tiers in the
-- script for long AFK sessions. Buy speeds are the one knob that risks bans,
-- so humans speeds only go SLOWER than "slow" — never faster.
SubPages:Register("Human Speeds", Tabs.AutoBuy, function(T, elements)
    SubPages:Nav(T, { label = "Auto Buy Page", options = { "Full Auto", "Semi Auto", "Human Speeds" }, flag = "NAV_AutoBuy", default = "Full Auto" })
    T("CreateSection", "Human Speeds")
    T("CreateLabel", "Human tiers add random +/- jitter to every delay so the timing never repeats. They are slower than Slow on purpose: use them for long AFK runs.")
    T("CreateLabel", "Auto Buy toggles stop when the budget is spent. Full Automation toggles loop buy -> sell -> buy forever.")
    T("CreateLabel", "Randomized delays that look like a real player — safest tiers in the script")
    T("CreateLabel", "Human Slow: ~4s buy | ~8s reload")

    Toggles.HumanSlowAutoBuy = T("CreateToggle", {
        Name = "Human Slow Auto Buy", CurrentValue = false, Flag = "HumanSlowBuy",
        Callback = function(state)
            if state then
                cancelOtherAutomation(Toggles.HumanSlowAutoBuy)
                safeSpawn(function()
                    postWebhook("SRS Semi Automation | by Sakura's Hub", "Auto Buy Started (HUMAN)", "**Speed:** Human Slow\n")
                end)
                LogEvent("SemiAutoBuy", "Started speed=human_slow")
            end
            safeSpawn(function()
                Settings.Buy.Enabled = state
                if state then runAutoBuyLoop("human_slow", Toggles.HumanSlowAutoBuy) end
            end)
        end,
    })

    T("CreateLabel", "Human Medium: ~3s buy | ~7s reload")

    Toggles.HumanMediumAutoBuy = T("CreateToggle", {
        Name = "Human Medium Auto Buy", CurrentValue = false, Flag = "HumanMediumBuy",
        Callback = function(state)
            if state then
                cancelOtherAutomation(Toggles.HumanMediumAutoBuy)
                safeSpawn(function()
                    postWebhook("SRS Semi Automation | by Sakura's Hub", "Auto Buy Started (HUMAN)", "**Speed:** Human Medium\n")
                end)
                LogEvent("SemiAutoBuy", "Started speed=human_medium")
            end
            safeSpawn(function()
                Settings.Buy.Enabled = state
                if state then runAutoBuyLoop("human_medium", Toggles.HumanMediumAutoBuy) end
            end)
        end,
    })

    T("CreateLabel", "Human Fast: ~2s buy | ~6s reload")

    Toggles.HumanFastAutoBuy = T("CreateToggle", {
        Name = "Human Fast Auto Buy", CurrentValue = false, Flag = "HumanFastBuy",
        Callback = function(state)
            if state then
                cancelOtherAutomation(Toggles.HumanFastAutoBuy)
                safeSpawn(function()
                    postWebhook("SRS Semi Automation | by Sakura's Hub", "Auto Buy Started (HUMAN)", "**Speed:** Human Fast\n")
                end)
                LogEvent("SemiAutoBuy", "Started speed=human_fast")
            end
            safeSpawn(function()
                Settings.Buy.Enabled = state
                if state then runAutoBuyLoop("human_fast", Toggles.HumanFastAutoBuy) end
            end)
        end,
    })

    T("CreateSection", "Full Automation — Human Speeds")
    T("CreateLabel", "Walks to your PC, buys, then sells — human-paced")
    T("CreateLabel", "Human Slow: ~4s buy | ~8s reload")

    Toggles.HumanSlowFullAuto = T("CreateToggle", {
        Name = "Human Slow Full Automation", CurrentValue = false, Flag = "HumanSlowFullAuto",
        Callback = function(state)
            if state then startFullAuto("human_slow", Toggles.HumanSlowFullAuto)
            else stopFullAuto() end
        end,
    })

    T("CreateLabel", "Human Medium: ~3s buy | ~7s reload")

    Toggles.HumanMediumFullAuto = T("CreateToggle", {
        Name = "Human Medium Full Automation", CurrentValue = false, Flag = "HumanMediumFullAuto",
        Callback = function(state)
            if state then startFullAuto("human_medium", Toggles.HumanMediumFullAuto)
            else stopFullAuto() end
        end,
    })

    T("CreateLabel", "Human Fast: ~2s buy | ~6s reload")

    Toggles.HumanFastFullAuto = T("CreateToggle", {
        Name = "Human Fast Full Automation", CurrentValue = false, Flag = "HumanFastFullAuto",
        Callback = function(state)
            if state then startFullAuto("human_fast", Toggles.HumanFastFullAuto)
            else stopFullAuto() end
        end,
    })

    Helpers.buildBudgetToggle(T)
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- ── PC Auto Buy Tab ────────────────────────────────────────────────────────
-- ═══════════════════════════════════════════════════════════════════════════

local pcSelectedSlots = {}
do
local savedPCSlots = {} -- v4: slot picks are not restored (all 16 ON at boot)
-- The shop has 16 offer slots; unset slots default ON so fresh users buy
-- everything, while any saved selection is honored per-slot.
for i = 1, 16 do
    if savedPCSlots[i] ~= nil then pcSelectedSlots[i] = savedPCSlots[i] else pcSelectedSlots[i] = true end
end
end

function __L.savePCSlots()
    local raw = safeReadFile(SAVE_PATH)
    local current = {}
    if raw and raw ~= "" then
        local ok, decoded = pcall(function()
            return game:GetService("HttpService"):JSONDecode(raw)
        end)
        if ok and decoded then current = decoded end
    end
    current.PCSlots = nil -- v4: slot picks are not persisted
    local ok, encoded = pcall(function()
        return game:GetService("HttpService"):JSONEncode(current)
    end)
    if ok then safeWriteFile(SAVE_PATH, encoded) end
end

-- ── PC Semi Auto Buy ───────────────────────────────────────────────────────
function __L.pcSelectedSlotsDesc()
    -- pcSelectedSlots holds booleans; render enabled slot numbers instead of
    -- letting table.concat (string-only) crash on the bools.
    local parts = {}
    for i = 1, #pcSelectedSlots do
        if pcSelectedSlots[i] then parts[#parts + 1] = tostring(i) end
    end
    return #parts > 0 and table.concat(parts, ",") or "none"
end

function __L.runPCAutoBuyLoop()
    LogEvent("PCAutoBuy", "Started slots=" .. __L.pcSelectedSlotsDesc())
    warn("[PCAUTOBUY] Starting — selected slots:", __L.pcSelectedSlotsDesc())
    local boughtAtStart = getgenv().ShoesBought
    local strikes = 0
    local MAX_STRIKES = 5
    local noBuyBroke = 0
    local MAX_BROKE = 5
    -- [FIX] PC Auto Buy never walked to the store PC (every other buy mode
    -- does). Walk there on start, then re-check each round so a respawn or
    -- a push away from the PC brings the character back.
    walkToPC(function() return State.pcAutoBuyRunning and srsAlive() end)
    while State.pcAutoBuyRunning and srsAlive() do
        local buyDelay    = getBuyDelay(State.pcAutoBuySpeed)
        local reloadDelay = getReloadDelay(State.pcAutoBuySpeed)

        ensureAtStorePC(function() return State.pcAutoBuyRunning and srsAlive() end)
        Notify({ Title = "PC Auto Buy", Content = "Refreshing page...", Duration = 2, Image = "Store" })

        closeSellBar()
        local ok, items = Helpers.refreshShopPage()

        if not ok or type(items) ~= "table" then
            strikes += 1
            warn("[PCAUTOBUY] Server error — strike " .. strikes .. "/" .. MAX_STRIKES)
            Notify({ Title = "PC Auto Buy", Content = "Failed to fetch offers (" .. strikes .. "/" .. MAX_STRIKES .. ")", Duration = 2, Image = "X" })
            if strikes >= MAX_STRIKES then
                local boughtThisRun = getgenv().ShoesBought - boughtAtStart
                warn("[PCAUTOBUY] Strikes exhausted — stopping (bought:", boughtThisRun, ")")
                LogEvent("PCAutoBuy", "Stopped strikes=" .. strikes)
                State.pcAutoBuyRunning = false
                safeSpawn(function()
                    postWebhook("SRS PC Auto Buy | by Sakura's Hub", "PC Auto Buy Stopped",
                        "**Reason:** Server not responding\n**Shoes Bought This Run:** " .. fmtNum(boughtThisRun) .. "\n")
                end)
                Notify({ Title = "PC Auto Buy", Content = "Server not responding — stopped. Bought " .. fmtNum(boughtThisRun) .. " shoes.", Duration = 5, Image = "X" })
                return
            end
            deltaWait(Helpers.refreshBackoff(strikes))
            continue
        end

        local boughtThisCycle, failedOffers, _, skippedOver = runBuyCycle(items, State.pcAutoBuySpeed, {
            running = function() return State.pcAutoBuyRunning end,
            slots   = pcSelectedSlots,
        })
        if not State.pcAutoBuyRunning or not srsAlive() then break end
        if boughtThisCycle > 0 then
            Notify({ Title = "PC Auto Buy", Content = "Bought " .. boughtThisCycle .. " shoe(s) this page!", Duration = 2, Image = "Check" })
        end
        if boughtThisCycle > 0 then
            strikes = 0
            noBuyBroke = 0
            warn("[PCAUTOBUY] Bought " .. boughtThisCycle .. " shoes this page — resetting counters")
        else
            local reason = __L.analyzeNoBuyReason(items)
            -- Broke = balance actually empty (see SemiAutoBuy note)
            if getMoney() <= 0 then
                noBuyBroke += 1
                warn("[PCAUTOBUY] Broke cycle " .. noBuyBroke .. "/" .. MAX_BROKE)
                if noBuyBroke >= MAX_BROKE then
                    local boughtThisRun = getgenv().ShoesBought - boughtAtStart
                    warn("[PCAUTOBUY] Out of money — stopping (bought:", boughtThisRun, ")")
                    LogEvent("PCAutoBuy", "Stopped out-of-money bought=" .. boughtThisRun)
                    State.pcAutoBuyRunning = false
                    safeSpawn(function()
                        postWebhook("SRS PC Auto Buy | by Sakura's Hub", "PC Auto Buy Stopped",
                            "**Reason:** Out of money\n**Shoes Bought This Run:** " .. fmtNum(boughtThisRun) .. "\n")
                    end)
                    Notify({ Title = "PC Auto Buy", Content = "Out of money! Bought " .. fmtNum(boughtThisRun) .. " shoes.", Duration = 5, Image = "X" })
                    return
                end
            else
                noBuyBroke = 0
                warn("[PCAUTOBUY] Zero bought (reason: " .. tostring(reason) .. ") — refreshing")
            end
        end

        deltaWait(reloadDelay)
    end
    warn("[PCAUTOBUY] Stopped by toggle")
    LogEvent("PCAutoBuy", "Stopped by toggle")
end

local function startPCAutoBuy(speed, callerToggle)
    LogEvent("PCAutoBuy", "Starting speed=" .. tostring(speed))
    if State.pcAutoBuyThread then pcall(task.cancel, State.pcAutoBuyThread); State.pcAutoBuyThread = nil end
    State.pcSwitching = true
    cancelOtherAutomation(callerToggle)
    State.pcSwitching = false

    State.pcAutoBuySpeed   = speed
    Helpers.snapshotBudget()
    State.pcAutoBuyRunning = true
    Notify({ Title = "PC Auto Buy", Content = "Started! Speed: " .. speed, Duration = 4, Image = "Check" })
    State.pcAutoBuyThread = task.spawn(__L.runPCAutoBuyLoop)
end

local function stopPCAutoBuy()
    State.pcAutoBuyRunning = false
    -- [FIX] Same guard ordering as stopFullAuto: don't log "Stopping..." when
    -- this is just cancelOtherAutomation() switching modes (it flips the other
    -- toggles off with pcSwitching = true).
    if State.pcSwitching then return end
    LogEvent("PCAutoBuy", "Stopping...")
    if State.pcAutoBuyThread then task.cancel(State.pcAutoBuyThread); State.pcAutoBuyThread = nil end
    Notify({ Title = "PC Auto Buy", Content = "Stopped.", Duration = 3, Image = "X" })
end

-- ── PC Full Auto (Buy + Sell Cycle) ───────────────────────────────────────

local function stopPCFullAuto()
    getgenv().PCFullAutoRunning = false
    Helpers.cyclePhase("idle")
    -- [FIX] Always clean up, even during a mode switch: cancel the worker
    -- first so nothing can reopen a GUI, then close the sell bar and shop.
    local switching = State.pcFullAutoSwitching
    local selfThread = coroutine.running()
    if State.pcFullAutoThread and State.pcFullAutoThread ~= selfThread then
        task.cancel(State.pcFullAutoThread); State.pcFullAutoThread = nil
    end
    stopSellBarListener()
    closeSellBar()
    -- [FIX] Hand the camera back if the shop screen is still open.
    if Helpers.closeShop then pcall(Helpers.closeShop) end
    if not switching then
        safeSpawn(function() postWebhook("SRS PC Full Auto | by Sakura's Hub", "PC Full Auto Stopped", "") end)
        Notify({ Title = "PC Full Auto", Content = "PC Full Auto stopped.", Duration = 3, Image = "X" })
        LogEvent("PCFullAuto", "Stopped")
    end
end

function __L.pcFullAutoLoop()
    LogEvent("PCFullAuto", "Started")
    Notify({ Title = "PC Full Auto", Content = "PC Full Auto started!", Duration = 3, Image = "Check" })
    walkToPC(function() return getgenv().PCFullAutoRunning and srsAlive() end)

    while getgenv().PCFullAutoRunning and srsAlive() do
        local skipBuy = false
        if Helpers.budgetExhausted() then
            if inventoryIsEmpty() then
                Helpers.snapshotBudget("PC Full Auto")
                if Helpers.budgetExhausted() then
                    if canAlert("pcfa_zero_budget", 300) then
                        Notify({ Title = "PC Full Auto", Content = "No money to buy with and nothing to sell — waiting for income.", Duration = 5, Image = "X" })
                    end
                    deltaWait(5)
                    continue
                end
            else
                skipBuy = true
                warn("[PCFA] Buy budget spent (" .. tostring(getgenv().SRS_BuySpent) .. "/" .. tostring(getgenv().SRS_BuyBudget) .. ") — selling inventory first")
                Notify({ Title = "PC Full Auto", Content = "Budget spent — selling inventory.", Duration = 3, Image = "Check" })
                LogEvent("PCFullAuto", "Budget spent -> sell (spent=" .. tostring(getgenv().SRS_BuySpent) .. " budget=" .. tostring(getgenv().SRS_BuyBudget) .. " balance=" .. tostring(getMoney()) .. ")")
            end
        end
        local buyDelay    = getBuyDelay(State.pcFullAutoSpeed)
        local reloadDelay = getReloadDelay(State.pcFullAutoSpeed)

        Notify({ Title = "PC Full Auto", Content = "Buy phase — checking PC offers...", Duration = 2, Image = "Store" })
        warn("[PCFA] ── Buy phase start ── Money:", getMoney(), "Selected slots:", #pcSelectedSlots)

        local strikes     = 0
        local MAX_STRIKES = 8
        local buyPhaseMoney = Helpers.phaseLimit()
        local realSpent     = 0
        Helpers.cyclePhase("buy", buyPhaseMoney)

        while not skipBuy and getgenv().PCFullAutoRunning and srsAlive() do
            if strikes >= MAX_STRIKES then
                warn("[PCFA] Strikes exhausted (" .. strikes .. "/" .. MAX_STRIKES .. ") → sell phase")
                Notify({ Title = "PC Full Auto", Content = "Retries exhausted — switching to sell phase.", Duration = 3, Image = "Store" })
                LogEvent("PCFullAuto", "Buy phase → sell: refresh failures x" .. MAX_STRIKES)
                strikes = 0
                break
            end

            ensureAtStorePC(function() return getgenv().PCFullAutoRunning and srsAlive() end)
            -- Close a leftover sell bar first. Buying is remote-only; the PC
            -- screen stays shut (only the Macro uses the shop GUI).
            closeSellBar()
            local ok, items = Helpers.refreshShopPage()

            -- ═══ Server error: paced retry ═══
            if not ok or type(items) ~= "table" then
                strikes += 1
                warn("[PCFA] Server error — strike " .. strikes .. "/" .. MAX_STRIKES); Helpers.healthError()
                Notify({ Title = "PC Full Auto", Content = "Failed to fetch offers (" .. strikes .. "/" .. MAX_STRIKES .. ") — retrying...", Duration = 2, Image = "X" })
                deltaWait(Helpers.refreshBackoff(strikes))
                continue
            end

            -- ═══ Check if any selected slot has a buyable (non-blacklisted) offer ═══
            -- Server decides affordability — attempt every eligible offer (see FullAuto note).
            local anyEligible = false
            for i, sneakerName in pairs(items) do
                if not pcSelectedSlots[i] then continue end
                local data = Sneakers[sneakerName]
                if not data or isBlacklisted(data) then continue end
                anyEligible = true
                break
            end

            -- ═══ Nothing buyable in selected slots: just retry (all blacklisted or unselected) ═══
            if not anyEligible then
                warn("[PCFA] No eligible items in selected slots — refreshing...")
                Notify({ Title = "PC Full Auto", Content = "No eligible items — refreshing page...", Duration = 2, Image = "Store" })
                deltaWait(1)
                continue
            end

            -- ═══ Buy phase ═══
            if realSpent >= buyPhaseMoney then
                warn("[PCFA] Buy money spent (" .. realSpent .. "/" .. buyPhaseMoney .. ") — can't afford more")
                Notify({ Title = "PC Full Auto", Content = "Out of buy money (employee pay excluded) — selling inventory", Duration = 3, Image = "Check" })
                LogEvent("PCFullAuto", "Buy phase → sell: unaffordable realSpent=" .. realSpent .. " phaseMoney=" .. buyPhaseMoney .. " balance=" .. tostring(getMoney()))
                break
            end
            warn("[PCFA] Eligible items found — running buy cycle")
            local boughtThisCycle, failedOffers, spentThisPage, skippedOver = runBuyCycle(items, State.pcFullAutoSpeed, {
                running = function() return getgenv().PCFullAutoRunning end,
                slots   = pcSelectedSlots,
                limit   = buyPhaseMoney - realSpent,
            })
            realSpent += (spentThisPage or 0); Helpers.cycleProgress(realSpent); Helpers.healthPage(boughtThisCycle, failedOffers)
            if boughtThisCycle > 0 then
                Notify({ Title = "PC Full Auto", Content = "Bought " .. boughtThisCycle .. " shoe(s) this page!", Duration = 3, Image = "Check" })
            end
            if realSpent >= buyPhaseMoney or (boughtThisCycle == 0 and (skippedOver or 0) > 0 and (failedOffers or 0) == 0) then
                warn("[PCFA] Buy budget used (" .. realSpent .. "/" .. buyPhaseMoney .. ") → sell phase")
                Notify({ Title = "PC Full Auto", Content = "Budget spent — selling inventory.", Duration = 3, Image = "Check" })
                LogEvent("PCFullAuto", "Buy phase → sell: budget used realSpent=" .. realSpent .. " phaseLimit=" .. buyPhaseMoney .. " balance=" .. tostring(getMoney()))
                break
            end

            if boughtThisCycle > 0 then
                strikes = 0
                warn("[PCFA] Bought " .. boughtThisCycle .. " shoes — resetting strikes")
                Notify({ Title = "PC Full Auto", Content = "Bought " .. boughtThisCycle .. " shoe(s) this page!", Duration = 3, Image = "Check" })
            else
                -- ═══ Buy returned 0: back off and retry ═══
                strikes += 1
                local capMode = failedOffers > 0
                warn("[PCFA] Buy returned 0 — strike " .. strikes .. "/" .. MAX_STRIKES .. (capMode and (" (" .. failedOffers .. " server rejections — PC capped or sold out)") or ""))
                -- Server refuses to sell (offers capped/sold out): retrying the
                -- same page is pointless — confirm 3x quickly, then sell instead.
                if capMode and strikes >= 3 then
                    warn("[PCFA] Shop rejected purchases x" .. strikes .. " → sell phase")
                    Notify({ Title = "PC Full Auto", Content = "Shop rejected purchases — switching to sell phase.", Duration = 3, Image = "Store" })
                    LogEvent("PCFullAuto", "Buy phase → sell: shop rejected x" .. strikes .. " (money=" .. tostring(getMoney()) .. ")")
                    break
                end
                if strikes >= MAX_STRIKES then
                    warn("[PCFA] Buy retries exhausted → sell phase")
                    Notify({ Title = "PC Full Auto", Content = "Buy attempts exhausted — switching to sell phase.", Duration = 3, Image = "Store" })
                    LogEvent("PCFullAuto", "Buy phase → sell: 0 purchases across " .. MAX_STRIKES .. " pages (money=" .. tostring(getMoney()) .. ")")
                    break
                end
                if capMode then
                    Notify({ Title = "PC Full Auto", Content = "Shop not selling (" .. strikes .. "/3) — retrying in " .. math.min(strikes * 5, 15) .. "s...", Duration = 2, Image = "Store" })
                    deltaWait(math.min(strikes * 5, 15))
                else
                    Notify({ Title = "PC Full Auto", Content = "Nothing bought (" .. strikes .. "/" .. MAX_STRIKES .. ") — retrying...", Duration = 2, Image = "Store" })
                    deltaWait(math.min(strikes, 5))
                end
                continue
            end

            deltaWait(reloadDelay)
        end

        if not getgenv().PCFullAutoRunning then break end

        safeSpawn(function()
            postWebhook("SRS PC Full Auto | by Sakura's Hub", "PC Buy Cycle Complete",
                "**Shoes Bought This Cycle:** " .. fmtNum(getgenv().ShoesBought) .. "\n")
        end)

        if inventoryIsEmpty() then
            warn("[PCFA] Inventory empty after buy — skipping sell, looping back to buy")
            Notify({ Title = "PC Full Auto", Content = "Inventory empty — looping back to buy.", Duration = 2, Image = "Store" })
            deltaWait(2)
            continue
        end
        if __L.shouldSkipSell() then
            warn("[PCFA] Only " .. sellableInventoryCount() .. " shoe(s) with $" .. tostring(getMoney()) .. " — skipping pointless sell, looping back to buy")
            Notify({ Title = "PC Full Auto", Content = "Too few shoes to sell — back to buying.", Duration = 2, Image = "Store" })
            LogEvent("PCFullAuto", "Sell phase skipped: tiny inventory (money=" .. tostring(getMoney()) .. ")")
            Helpers.snapshotBudget("PC Full Auto")
            deltaWait(2)
            continue
        end

        Helpers.cyclePhase("sell")
        warn("[PCFA] ── Sell phase start ── Money:", getMoney(), "ShoesSold:", getgenv().ShoesSold)
        Notify({ Title = "PC Full Auto", Content = "Sell phase — selling inventory...", Duration = 2, Image = "Store" })
        safeSpawn(function()
            pcall(function()
                if Helpers.checkDailyQuests then Helpers.checkDailyQuests(true) end
            end)
        end)
        -- [FIX] The buy phase opens the PC screen; close it before walking to
        -- the NPC so the sell bar is on top and the camera is free (D-018).
        if Helpers.closeShop then pcall(Helpers.closeShop) end
        startSellBarListener()
        startSellAdaptLoop()

        while getgenv().PCFullAutoRunning and srsAlive() and not inventoryIsEmpty() do
            if not SellFrame or not SellFrame.Visible then
                warn("[PCFA] Sell bar not visible — walking to NPC")
                local okSell, sellErr = pcall(__L.sellToNPC)
                if not okSell then warn("[PCFA] sellToNPC error: " .. tostring(sellErr)) end
            end
            deltaWait(0.1)
        end

        stopSellBarListener()
        closeSellBar()
        Helpers.snapshotBudget("PC Full Auto")
        warn("[PCFA] Sell phase complete — Money:", getMoney(), "ShoesSold:", getgenv().ShoesSold)
        safeSpawn(function()
            pcall(function()
                if Helpers.checkDailyQuests then Helpers.checkDailyQuests(true) end
            end)
        end)
        safeSpawn(function()
            postWebhook("SRS PC Full Auto | by Sakura's Hub", "PC Sell Cycle Complete",
                "**Shoes Sold:** " .. fmtNum(getgenv().ShoesSold) .. "\n")
        end)
        -- Halloween boxes (toggle): walk to the box and open them with Candy,
        -- then return to the store PC for the next buy phase.
        if Helpers.halloweenCycle and Settings.HalloweenTradeIn and Settings.HalloweenTradeIn.Enabled then
            getgenv().SRS_HalloweenFromSell = true
            Notify({ Title = "Halloween", Content = "Armed - Will run after sell", Duration = 2, Image = "Store" })
            local pcAlive = function() return getgenv().PCFullAutoRunning and srsAlive() end
            -- open boxes, then trade in, then back to the store PC
            pcall(Helpers.halloweenCycle, pcAlive)
            getgenv().SRS_HalloweenFromSell = nil
            if pcAlive() then walkToPC(pcAlive) end
        else
            getgenv().SRS_HalloweenFromSell = nil
        end
        safeSpawn(function()
            local st = getgenv().SRS_Stability
            if st and st.hopAfterSell then
                deltaWait(2)
                if getgenv()._SRS_serverHop then
                    getgenv()._SRS_serverHop(game.PlaceId)
                elseif serverHopToLowest then
                    serverHopToLowest(game.PlaceId)
                end
            end
        end)
        deltaWait(0.5)
    end

    getgenv().PCFullAutoRunning = false
    getgenv().SRS_HalloweenFromSell = nil
    State.pcFullAutoSwitching = true
    safeSetToggle("SlowPCFullAuto", false)
    safeSetToggle("MediumPCFullAuto", false)
    safeSetToggle("FastPCFullAuto", false)
    safeSetToggle("RiskySlowPCFullAuto", false)
    safeSetToggle("RiskyMediumPCFullAuto", false)
    safeSetToggle("RiskyFastPCFullAuto", false)
    State.pcFullAutoSwitching = false

    Notify({ Title = "PC Full Auto", Content = "PC Full Auto stopped.", Duration = 3, Image = "X" })
    LogEvent("PCFullAuto", "Loop ended")
end

local function startPCFullAuto(speed, callerToggle)
    getgenv().SRS_DoEverythingOn = (callerToggle ~= nil and callerToggle == Toggles.DoEverything) and true or false
    if State.pcFullAutoThread then pcall(task.cancel, State.pcFullAutoThread); State.pcFullAutoThread = nil end
    getgenv().PCFullAutoRunning = false
    LogEvent("PCFullAuto", "Starting speed=" .. tostring(speed))
    State.pcFullAutoSwitching = true
    cancelOtherAutomation(callerToggle)
    State.pcFullAutoSwitching = false

    State.pcAutoBuyRunning      = false
    Settings.Buy.Enabled        = false
    Settings.Sell               = false
    getgenv().FullAutoRunning   = false

    State.pcFullAutoSpeed       = speed
    getgenv().PCFullAutoRunning = true
    getgenv().SRS_BuyBudget = getMoney()
    getgenv().SRS_BuySpent  = 0

    safeSpawn(function()
        postWebhook("SRS PC Full Auto | by Sakura's Hub", "PC Full Auto Started", "**Speed:** " .. speed .. "\n")
    end)

    State.pcFullAutoThread = task.spawn(__L.pcFullAutoLoop)
end

-- Boot-resume: SRS_AUTOSTART is armed via queue_on_teleport; we start the
-- cycle directly because the PC Auto tab's toggles don't exist until shown.
if getgenv().SRS_AUTOSTART then
    local raw = tostring(getgenv().SRS_AUTOSTART):lower()
    local mode = raw:find("slow") and "slow" or raw:find("fast") and "fast" or raw:find("medium") and "medium" or nil
    getgenv().SRS_AUTOSTART = nil
    if mode then
        task.spawn(function()
            task.wait(2)
            local ok3, e3 = pcall(function() startPCFullAuto(mode, nil) end)
            if not ok3 then warn("[SRS] autostart PC cycle failed: " .. tostring(e3)) end
        end)
    else
        warn("[SRS] autostart ignored, unknown speed: " .. raw)
    end
end

-- PC sub-pages build in their own function: bootScript() sits at Luau's
-- register ceiling, so these helpers and five registrations must not hold
-- locals in bootScript for its entire run. IIFE so the frame name costs no
-- bootScript register either.
;(function()
-- ── Do Everything (one-stop orchestration) ─────────────────────────────────
-- Single toggle: auto-unlock offers + hourly quests + PC full automation.
-- Everything runs through the server remotes (the PC screen GUI has zero
-- click handlers — see probe notes), so walking happens, then buy, then sell.
local DO_EVERY_SPEEDS = {
    ["Slow"] = "slow", ["Medium"] = "medium", ["Fast"] = "fast",
    ["Human Slow"] = "human_slow", ["Human Medium"] = "human_medium", ["Human Fast"] = "human_fast",
}

local function startDoEverything()
    if getgenv().PCFullAutoRunning then
        Notify({ Title = "Do Everything", Content = "Already running.", Duration = 3, Image = "Alert" })
        return
    end
    local speed = getgenv().SRS_DoEverythingSpeed or "medium"
    if not Settings.Quests then Settings.Quests = {} end
    Settings.Quests.AutoRedeem = true
    if Toggles.AutoRedeemQuests then safeSetToggle("AutoRedeemQuests", true) end
    -- Don't auto-enable AutoUnlock on load - respect saved state
    startPCFullAuto(speed, Toggles.DoEverything)
    LogEvent("DoEverything", "Started speed=" .. speed)
    Notify({ Title = "Do Everything", Content = "Running at " .. speed .. " — buying, then selling when budget is spent.", Duration = 4, Image = "Check" })
end

local function stopDoEverything()
    stopPCFullAuto()
end

-- Shared PC controls: slot selection + auto-unlock appear on every PC page.
local function buildPCSlotsAndUnlocks(T)
    Helpers.buildBudgetToggle(T)
    T("CreateSection", "PC Slot Selection")
    T("CreateLabel", "Select which offer slots to buy from (1-16) — selections are saved")

    for i = 1, 16 do
        T("CreateToggle", {
            Name = "Buy Slot " .. i,
            CurrentValue = pcSelectedSlots[i],
            Flag = "PCSlot" .. i,
            Callback = function(state)
                pcSelectedSlots[i] = state
                __L.savePCSlots()
            end,
        })
    end

    T("CreateSection", "Offer Unlocks")
    T("CreateLabel", "Auto-unlocks the next locked offer slot when you can afford it (real GUI prices)")
    Toggles.AutoUnlock = T("CreateToggle", {
        Name = "Auto Unlock Offers",
        CurrentValue = Settings.AutoUnlock,
        Flag = "AutoUnlock",
        Callback = function(state)
            Settings.AutoUnlock = state
            saveSettings()
        end,
    })
end

-- Buy-budget toggle shared by every page that runs a buy->sell cycle.
function Helpers.buildBudgetToggle(T)
    T("CreateSection", "Buy Budget")
    T("CreateLabel", "Snapshots your money when automation starts — the buy->sell swap fires when that money is spent, so worker income can't extend buying")
    Toggles.BuyBudget = T("CreateToggle", {
        Name = "Buy Budget (Snapshot)",
        CurrentValue = (Settings.Budget and Settings.Budget.Enabled) ~= false,
        Flag = "BuyBudget",
        Callback = function(state)
            if not Settings.Budget then Settings.Budget = {} end
            Settings.Budget.Enabled = state
            saveSettings()
        end,
    })
end

-- ── Semi PC Auto sub-page ─────────────────────────────────────────────────
SubPages:Register("Semi PC Auto", Tabs.PCAuto, function(T, elements)
    SubPages:Nav(T, { label = "PC Page", options = { "Semi PC Auto", "Full PC Auto", "PC Human", "Macro", "Do Everything" }, flag = "NAV_PC", default = "Semi PC Auto" })
    T("CreateSection", "Semi PC Auto")
    T("CreateLabel", "PC pages buy only from the offer slots you tick under 'PC Slot Selection'. Selections are saved between sessions.")
    T("CreateLabel", "Refreshes offers and buys from selected slots — respects Blacklist tab")
    T("CreateLabel", "You only need PC Auto Buy if you want to buy from select slots — Auto Buy already covers all slots")
    T("CreateLabel", "Make sure you have walked up to the PC and opened it at least once first")

    T("CreateLabel", "Slow: 1.5s buy delay | 6s reload delay")
    Toggles.SlowPCAutoBuy = T("CreateToggle", {
        Name = "Slow PC Auto Buy", CurrentValue = false, Flag = "SlowPCAutoBuy",
        Callback = function(state)
            if state then startPCAutoBuy("slow",   Toggles.SlowPCAutoBuy)
            else stopPCAutoBuy() end
        end,
    })

    T("CreateLabel", "Medium: 1.0s buy delay | 5s reload delay")
    Toggles.MediumPCAutoBuy = T("CreateToggle", {
        Name = "Medium PC Auto Buy", CurrentValue = false, Flag = "MediumPCAutoBuy",
        Callback = function(state)
            if state then startPCAutoBuy("medium", Toggles.MediumPCAutoBuy)
            else stopPCAutoBuy() end
        end,
    })

    T("CreateLabel", "Fast: 0.5s buy delay | 4s reload delay")
    Toggles.FastPCAutoBuy = T("CreateToggle", {
        Name = "Fast PC Auto Buy", CurrentValue = false, Flag = "FastPCAutoBuy",
        Callback = function(state)
            if state then startPCAutoBuy("fast",   Toggles.FastPCAutoBuy)
            else stopPCAutoBuy() end
        end,
    })

    buildPCSlotsAndUnlocks(T)
end)

-- ── Full PC Auto sub-page ─────────────────────────────────────────────────
SubPages:Register("Full PC Auto", Tabs.PCAuto, function(T, elements)
    SubPages:Nav(T, { label = "PC Page", options = { "Semi PC Auto", "Full PC Auto", "PC Human", "Macro", "Do Everything" }, flag = "NAV_PC", default = "Semi PC Auto" })
    T("CreateSection", "Full PC Auto")
    T("CreateLabel", "Loop: walk to the PC -> buy from ticked slots until the budget is spent -> walk to the NPC -> sell everything -> new budget -> repeat.")
    T("CreateLabel", "Walks to your PC, buys from selected slots, then sells when out of money — loops until stopped")
    T("CreateLabel", "Respects Blacklist tab | Uses sell bar listener + NPC walk for sell phase")

    T("CreateLabel", "Slow: 1.5s buy delay | 6s reload delay")
    Toggles.SlowPCFullAuto = T("CreateToggle", {
        Name = "Slow PC Full Auto", CurrentValue = false, Flag = "SlowPCFullAuto",
        Callback = function(state)
            if state then startPCFullAuto("slow",   Toggles.SlowPCFullAuto)
            else stopPCFullAuto() end
        end,
    })

    T("CreateLabel", "Medium: 1.0s buy delay | 5s reload delay")
    Toggles.MediumPCFullAuto = T("CreateToggle", {
        Name = "Medium PC Full Auto", CurrentValue = false, Flag = "MediumPCFullAuto",
        Callback = function(state)
            if state then startPCFullAuto("medium", Toggles.MediumPCFullAuto)
            else stopPCFullAuto() end
        end,
    })

    T("CreateLabel", "Fast: 0.5s buy delay | 4s reload delay")
    Toggles.FastPCFullAuto = T("CreateToggle", {
        Name = "Fast PC Full Auto", CurrentValue = false, Flag = "FastPCFullAuto",
        Callback = function(state)
            if state then startPCFullAuto("fast",   Toggles.FastPCFullAuto)
            else stopPCFullAuto() end
        end,
    })

    buildPCSlotsAndUnlocks(T)
end)

-- ── PC Risky sub-page ─────────────────────────────────────────────────────
SubPages:Register("Risky PC", Tabs.Risky, function(T, elements)
    Helpers.riskyNav(T)
    T("CreateSection", "Risky PC")
    T("CreateLabel", "Faster than PC Fast — bans reported on these speeds (see Info tab)")
    T("CreateLabel", "Only for short sessions where you accept the risk")

    T("CreateLabel", "Risky Slow: 0.25s buy delay | 3.5s reload delay")
    Toggles.RiskySlowPCAutoBuy = T("CreateToggle", {
        Name = "Risky Slow PC Auto Buy", CurrentValue = false, Flag = "RiskySlowPCAutoBuy",
        Callback = function(state)
            if state then startPCAutoBuy("risky_slow",   Toggles.RiskySlowPCAutoBuy)
            else stopPCAutoBuy() end
        end,
    })

    T("CreateLabel", "Risky Medium: 0.15s buy delay | 2s reload delay")
    Toggles.RiskyMediumPCAutoBuy = T("CreateToggle", {
        Name = "Risky Medium PC Auto Buy", CurrentValue = false, Flag = "RiskyMediumPCAutoBuy",
        Callback = function(state)
            if state then startPCAutoBuy("risky_medium", Toggles.RiskyMediumPCAutoBuy)
            else stopPCAutoBuy() end
        end,
    })

    T("CreateLabel", "Risky Fast: 0.05s buy delay | 1s reload delay")
    Toggles.RiskyFastPCAutoBuy = T("CreateToggle", {
        Name = "Risky Fast PC Auto Buy", CurrentValue = false, Flag = "RiskyFastPCAutoBuy",
        Callback = function(state)
            if state then startPCAutoBuy("risky_fast",   Toggles.RiskyFastPCAutoBuy)
            else stopPCAutoBuy() end
        end,
    })

    T("CreateSection", "Full PC Automation — Risky Speeds")
    T("CreateLabel", "Walks, buys, sells at risky speeds — bans reported on these tiers")

    T("CreateLabel", "Risky Slow: 0.25s buy delay | 3.5s reload delay")
    Toggles.RiskySlowPCFullAuto = T("CreateToggle", {
        Name = "Risky Slow PC Full Auto", CurrentValue = false, Flag = "RiskySlowPCFullAuto",
        Callback = function(state)
            if state then startPCFullAuto("risky_slow",   Toggles.RiskySlowPCFullAuto)
            else stopPCFullAuto() end
        end,
    })

    T("CreateLabel", "Risky Medium: 0.15s buy delay | 2s reload delay")
    Toggles.RiskyMediumPCFullAuto = T("CreateToggle", {
        Name = "Risky Medium PC Full Auto", CurrentValue = false, Flag = "RiskyMediumPCFullAuto",
        Callback = function(state)
            if state then startPCFullAuto("risky_medium", Toggles.RiskyMediumPCFullAuto)
            else stopPCFullAuto() end
        end,
    })

    T("CreateLabel", "Risky Fast: 0.05s buy delay | 1s reload delay")
    Toggles.RiskyFastPCFullAuto = T("CreateToggle", {
        Name = "Risky Fast PC Full Auto", CurrentValue = false, Flag = "RiskyFastPCFullAuto",
        Callback = function(state)
            if state then startPCFullAuto("risky_fast",   Toggles.RiskyFastPCFullAuto)
            else stopPCFullAuto() end
        end,
    })

    buildPCSlotsAndUnlocks(T)
end)

-- ── PC Human sub-page ─────────────────────────────────────────────────────
SubPages:Register("PC Human", Tabs.PCAuto, function(T, elements)
    SubPages:Nav(T, { label = "PC Page", options = { "Semi PC Auto", "Full PC Auto", "PC Human", "Macro", "Do Everything" }, flag = "NAV_PC", default = "Semi PC Auto" })
    T("CreateSection", "PC Human Speeds")
    T("CreateLabel", "Randomized human-like delays — safest tiers for long AFK sessions")

    T("CreateLabel", "Human Slow: ~4s buy | ~8s reload")
    Toggles.HumanSlowPCAutoBuy = T("CreateToggle", {
        Name = "Human Slow PC Auto Buy", CurrentValue = false, Flag = "HumanSlowPCAutoBuy",
        Callback = function(state)
            if state then startPCAutoBuy("human_slow",   Toggles.HumanSlowPCAutoBuy)
            else stopPCAutoBuy() end
        end,
    })

    T("CreateLabel", "Human Medium: ~3s buy | ~7s reload")
    Toggles.HumanMediumPCAutoBuy = T("CreateToggle", {
        Name = "Human Medium PC Auto Buy", CurrentValue = false, Flag = "HumanMediumPCAutoBuy",
        Callback = function(state)
            if state then startPCAutoBuy("human_medium", Toggles.HumanMediumPCAutoBuy)
            else stopPCAutoBuy() end
        end,
    })

    T("CreateLabel", "Human Fast: ~2s buy | ~6s reload")
    Toggles.HumanFastPCAutoBuy = T("CreateToggle", {
        Name = "Human Fast PC Auto Buy", CurrentValue = false, Flag = "HumanFastPCAutoBuy",
        Callback = function(state)
            if state then startPCAutoBuy("human_fast",   Toggles.HumanFastPCAutoBuy)
            else stopPCAutoBuy() end
        end,
    })

    T("CreateSection", "Full PC Automation — Human Speeds")
    T("CreateLabel", "Walks, buys, sells — human-paced")

    T("CreateLabel", "Human Slow: ~4s buy | ~8s reload")
    Toggles.HumanSlowPCFullAuto = T("CreateToggle", {
        Name = "Human Slow PC Full Auto", CurrentValue = false, Flag = "HumanSlowPCFullAuto",
        Callback = function(state)
            if state then startPCFullAuto("human_slow",   Toggles.HumanSlowPCFullAuto)
            else stopPCFullAuto() end
        end,
    })

    T("CreateLabel", "Human Medium: ~3s buy | ~7s reload")
    Toggles.HumanMediumPCFullAuto = T("CreateToggle", {
        Name = "Human Medium PC Full Auto", CurrentValue = false, Flag = "HumanMediumPCFullAuto",
        Callback = function(state)
            if state then startPCFullAuto("human_medium", Toggles.HumanMediumPCFullAuto)
            else stopPCFullAuto() end
        end,
    })

    T("CreateLabel", "Human Fast: ~2s buy | ~6s reload")
    Toggles.HumanFastPCFullAuto = T("CreateToggle", {
        Name = "Human Fast PC Full Auto", CurrentValue = false, Flag = "HumanFastPCFullAuto",
        Callback = function(state)
            if state then startPCFullAuto("human_fast",   Toggles.HumanFastPCFullAuto)
            else stopPCFullAuto() end
        end,
    })

    buildPCSlotsAndUnlocks(T)
end)

-- ── Do Everything sub-page ──────────────────────────────────────────────────
SubPages:Register("Do Everything", Tabs.PCAuto, function(T, elements)
    SubPages:Nav(T, { label = "PC Page", options = { "Semi PC Auto", "Full PC Auto", "PC Human", "Macro", "Do Everything" }, flag = "NAV_PC", default = "Semi PC Auto" })
    T("CreateSection", "Do Everything")
    T("CreateLabel", "Pick a speed, press Run Everything. It turns on daily-quest redeeming, walks to your PC, buys until the budget is spent, sells every shoe, and repeats. Slot selection and Auto Unlock Offers below still apply.")
    T("CreateLabel", "One toggle: auto-unlock offers + hourly quests + walk to PC + buy until budget spent + sell")
    T("CreateLabel", "Everything runs through server remotes — safest path in the script")

    T("CreateDropdown", {
        Name = "Do Everything Speed",
        Options = { "Slow", "Medium", "Fast", "Human Slow", "Human Medium", "Human Fast" },
        Default = "Medium",
        Flag = "DoEverythingSpeed",
        Callback = function(choice)
            getgenv().SRS_DoEverythingSpeed = DO_EVERY_SPEEDS[choice] or "medium"
        end,
    })

    Toggles.DoEverything = T("CreateToggle", {
        Name = "Run Everything", CurrentValue = false, Flag = "DoEverything",
        Callback = function(state)
            if state then startDoEverything() else stopDoEverything() end
        end,
    })

    buildPCSlotsAndUnlocks(T)
end)
-- ═══════════════════════════════════════════════════════════════════════════
-- ── Macro: mouse-driven PC buyer ────────────────────────────────────────────
-- Walks to the store PC, moves the mouse like a person, clicks the shoe in
-- each selected slot, clicks Refresh, repeats. Honors the Blacklist tab, the
-- PC slot toggles and the Buy Budget snapshot: when the snapshot is spent (or
-- nothing buyable shows up for a while) it swaps to selling, takes a fresh
-- snapshot and goes again — on every speed, regardless of income.
-- Lives entirely inside this scope + Helpers.Macro so bootScript() spends no
-- extra registers on it.
-- ═══════════════════════════════════════════════════════════════════════════
do
local UIS        = game:GetService("UserInputService")
local VIM        = game:GetService("VirtualInputManager")
local GuiService = game:GetService("GuiService")

local M = {
    Running = false, id = 0, thread = nil, selling = false,
    Speed = "medium", Fallback = true, Strict = false, MaxDry = 6,
    mode = "", status = "Idle",
    stats = { passes = 0, bought = 0, spent = 0, swaps = 0, clicks = 0, remote = 0 },
}
Helpers.Macro = M

local function rnd(a, b) return a + math.random() * (b - a) end

local function setStatus(txt)
    M.status = txt
    if PageRefs.macroStatusLabel then
        pcall(function() PageRefs.macroStatusLabel:Set("Status: " .. txt) end)
    end
end

local function report()
    local left = Helpers.budgetOn() and fmtMoney(Helpers.budgetLeft()) or "off"
    if PageRefs.macroStatsLabel then
        pcall(function()
            PageRefs.macroStatsLabel:Set(string.format(
                "Passes: %d | Bought: %d | Spent: %s | Swaps: %d | Budget left: %s | Mode: %s",
                M.stats.passes, M.stats.bought, fmtMoney(M.stats.spent), M.stats.swaps, left,
                M.mode ~= "" and M.mode or "-"))
        end)
    end
end

-- ── GUI helpers ────────────────────────────────────────────────────────────
local function shown(obj)
    local cur = obj
    while cur and cur ~= game do
        if cur:IsA("GuiObject") and not cur.Visible then return false end
        if cur:IsA("ScreenGui") and not cur.Enabled then return false end
        -- [FIX] world-space GUIs (SurfaceGui/BillboardGui) are not ScreenGuis, so
        -- a disabled one used to pass this check. The store PC ships a disabled
        -- SurfaceGui on its physical RefreshButton part, and the macro was
        -- preferring it over the real on-screen Refresh and clicking a control
        -- that can never be seen or fire.
        if cur:IsA("SurfaceGui") or cur:IsA("BillboardGui") then
            if not cur.Enabled then return false end
        end
        cur = cur.Parent
    end
    if obj:IsA("GuiObject") then return obj.AbsoluteSize.X > 0 and obj.AbsoluteSize.Y > 0 end
    return true
end

local function inPlayerGui(obj)
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    return pg ~= nil and obj ~= nil and obj:IsDescendantOf(pg)
end

local BAD_WORDS = { "robux", "r$", "premium", "gamepass", "game pass", "skip", "instant", "vip", "unlock" }
local function badButton(name, txt)
    local s = name .. " " .. txt
    for _, w in ipairs(BAD_WORDS) do
        if s:find(w, 1, true) then return true end
    end
    return false
end

local function btnText(d)
    return d:IsA("TextButton") and tostring(d.Text):lower() or ""
end

-- Shoe name -> Sneakers key, read from the slot's own labels.
local nameIndex
local function norm(str) return (tostring(str):lower():gsub("[^%w]", "")) end
local function buildIndex()
    nameIndex = { map = {}, list = {} }
    for k in pairs(Sneakers) do
        if type(k) == "string" then
            local n = norm(k)
            if n ~= "" then
                nameIndex.map[n] = k
                nameIndex.list[#nameIndex.list + 1] = { n = n, k = k }
            end
        end
    end
    table.sort(nameIndex.list, function(a, b) return #a.n > #b.n end)
end

local function readSlotName(slot)
    if not nameIndex then buildIndex() end
    -- Authoritative live data: the slot's Sneaker attribute. The on-screen
    -- labels go stale the moment the page is refreshed (every locked slot keeps
    -- the previous template name), so the attribute is trusted first.
    local okA, attrName = pcall(function() return slot:GetAttribute("Sneaker") end)
    if okA and type(attrName) == "string" and attrName ~= "" then
        local n = norm(attrName)
        local k = nameIndex.map[n]
        if k then return k end
        if #n >= 6 then
            for _, e in ipairs(nameIndex.list) do
                if #e.n >= 6 and #e.n <= #n and n:find(e.n, 1, true) then return e.k end
            end
        end
        return nil
    end
    local texts = {}
    for _, d in ipairs(slot:GetDescendants()) do
        if d:IsA("TextLabel") or d:IsA("TextButton") then
            local t = norm(d.Text)
            if t ~= "" then texts[#texts + 1] = t end
        end
    end
    for _, t in ipairs(texts) do
        local k = nameIndex.map[t]
        if k then return k end
    end
    for _, t in ipairs(texts) do
        if #t >= 6 then
            for _, e in ipairs(nameIndex.list) do
                if #e.n >= 6 and #e.n <= #t and t:find(e.n, 1, true) then return e.k end
            end
        end
    end
    return nil
end

local function slotLocked(slot)
    -- Authoritative: the server sets Sneaker="" on a locked offer and to the
    -- real name once it is unlocked. The GUI lock overlay is stale after a
    -- refresh (an unlocked offer can still show its "Unlock" frame), so the
    -- attribute decides and the overlay is only a fallback.
    local okA, attrName = pcall(function() return slot:GetAttribute("Sneaker") end)
    if okA and type(attrName) == "string" then
        return attrName == ""
    end
    for _, d in ipairs(slot:GetDescendants()) do
        if d:IsA("GuiObject") then
            local n = d.Name:lower()
            if (n:find("unlock", 1, true) or n == "locked" or n:find("lockframe", 1, true) or n:find("lockicon", 1, true)) and shown(d) then
                return true
            end
        end
    end
    return false
end

-- Clickable controls inside a slot, best candidate first. Unlock / Robux style
-- buttons are never candidates.
local function slotButtons(slot)
    local out = {}
    local function consider(d)
        if not (d:IsA("TextButton") or d:IsA("ImageButton")) then return end
        if not shown(d) then return end
        local n, t = d.Name:lower(), btnText(d)
        if badButton(n, t) then return end
        local pri = 3
        if n:find("bigbuy", 1, true) then pri = 0
        elseif n:find("buy", 1, true) or t:find("buy", 1, true) or t:find("purchase", 1, true) then pri = 1
        elseif n:find("select", 1, true) then pri = 2 end
        out[#out + 1] = { b = d, p = pri, o = #out }
    end
    consider(slot)
    for _, d in ipairs(slot:GetDescendants()) do consider(d) end
    table.sort(out, function(a, b)
        if a.p ~= b.p then return a.p < b.p end
        return a.o < b.o
    end)
    local res = {}
    for _, e in ipairs(out) do res[#res + 1] = e.b end
    return res
end

-- Confirm dialogs only (never anything shop/Robux related). The purchase
-- dialog (MainScreenGui.SelectDisplayPriceFrame.ConfirmButton) is NOT under the
-- shop's SurfaceGui, so when the offers frame has no ScreenGui ancestor the
-- whole PlayerGui is scanned for a currently-visible confirm control.
local function findConfirm(frame)
    if frame then
        local sg = frame:FindFirstAncestorOfClass("ScreenGui")
        if sg then
            for _, d in ipairs(sg:GetDescendants()) do
                if (d:IsA("TextButton") or d:IsA("ImageButton")) and not frame:IsAncestorOf(d) and shown(d) then
                    local n, t = d.Name:lower(), btnText(d)
                    if not badButton(n, t) and (n:find("confirm", 1, true) or n:find("accept", 1, true) or n == "yes"
                        or t:find("confirm", 1, true) or t == "yes") then
                        return d
                    end
                end
            end
        end
    end
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    if pg then
        for _, d in ipairs(pg:GetDescendants()) do
            if (d:IsA("TextButton") or d:IsA("ImageButton")) and shown(d) then
                local n = d.Name:lower()
                if (n == "confirmbutton" or n:find("confirm", 1, true)) and not badButton(n, btnText(d)) then
                    return d
                end
            end
        end
    end
    return nil
end

local REFRESH_KEYS = { "refresh", "reload", "reroll" }

-- The PC's ON-WORLD Refresh button: a SurfaceGui ImageButton parented to the
-- PC.RefreshButton part, with a real MouseButton1Click handler. It is the
-- control a player physically clicks and it stays visible even when the PC's
-- in-screen TopFrame is hidden, so it is always preferred.
local function findWorldRefreshButton()
    local store = getStore()
    local pc = store and store:FindFirstChild("PC")
    local part = pc and pc:FindFirstChild("RefreshButton")
    local sg = part and part:FindFirstChild("SurfaceGui")
    local btn = sg and sg:FindFirstChild("RefreshButton")
    if btn and (btn:IsA("TextButton") or btn:IsA("ImageButton")) and shown(btn) then return btn end
    return nil
end

-- [FIX] The real, working Refresh lives in the store's own PC screen SurfaceGui
-- (PlayerGui.PCScreenGui.ScreenFrame.TopFrame.RefreshButton, Adornee = PCScreen),
-- not on the physical RefreshButton part — that part's SurfaceGui ships disabled
-- with no Adornee, so the old order picked a control that could never be clicked.
-- Search the PlayerGui surface UIs for a visible refresh control.
local function findGuiRefreshButton()
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    if not pg then return nil end
    for _, sg in ipairs(pg:GetChildren()) do
        if (sg:IsA("SurfaceGui") or sg:IsA("BillboardGui")) and sg.Enabled then
            for _, d in ipairs(sg:GetDescendants()) do
                if (d:IsA("TextButton") or d:IsA("ImageButton")) and shown(d) then
                    local n, t = d.Name:lower(), btnText(d)
                    if not badButton(n, t) then
                        for _, k in ipairs(REFRESH_KEYS) do
                            if n:find(k, 1, true) or t:find(k, 1, true) then return d end
                        end
                    end
                end
            end
        end
    end
    return nil
end

local function findRefresh(frame)
    if M.refreshBtn and M.refreshBtn.Parent then return M.refreshBtn end
    M.refreshBtn = nil
    -- 1) a visible refresh control in the PC screen's world surface (the real one)
    local gui = findGuiRefreshButton()
    if gui then M.refreshBtn = gui; return gui end
    -- 2) the physical on-world PC Refresh button, when its SurfaceGui is live
    local world = findWorldRefreshButton()
    if world then M.refreshBtn = world; return world end
    -- 2) a refresh-named button shown somewhere in the shop's own GUI. The
    --    refresh control is a SIBLING of the offers frame (TopFrame), never a
    --    descendant of it, so the whole shop root is scanned once.
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    local root = frame
    while root and root.Parent and root.Parent ~= pg and root.Parent ~= game do
        root = root.Parent
    end
    if root then
        for _, d in ipairs(root:GetDescendants()) do
            if (d:IsA("TextButton") or d:IsA("ImageButton")) and shown(d) then
                local n, t = d.Name:lower(), btnText(d)
                if not badButton(n, t) then
                    for _, k in ipairs(REFRESH_KEYS) do
                        if n:find(k, 1, true) or t:find(k, 1, true) then
                            M.refreshBtn = d
                            return d
                        end
                    end
                end
            end
        end
    end
    return nil
end

-- ── Humanized mouse ────────────────────────────────────────────────────────
local function moveDur()
    local c = SPEED_CONFIG[M.Speed]
    local f = c and math.clamp(c.buyDelay / 1.0, 0.3, 1.5) or 1
    return rnd(0.25, 0.5) * f
end

local function mouseMove(x, y)
    -- [FIX] Live user report: mousemoveabs() DOES move the real Windows cursor
    -- on this executor (the earlier "stub" reading was wrong). Every buy/sell
    -- glide therefore hijacked the user's pointer and they could not click the
    -- script UI while the macro ran. NEVER touch the OS cursor: the drawn dot
    -- is the only pointer the macro moves, and clicks are still delivered by
    -- activateButton (firesignal), so the visible dot and the clicked control
    -- stay the same. Remember where the drawn cursor was so the next glide
    -- starts from there.
    M.cursorX, M.cursorY = x, y
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    if not pg then return end
    local dot = M.cursorDot
    if not (dot and dot.Parent) then
        local gui = M.cursorGui
        if not (gui and gui.Parent) then
            gui = pg:FindFirstChild("SRS_Cursor")
            if gui then gui:Destroy() end
            gui = Instance.new("ScreenGui")
            gui.Name = "SRS_Cursor"
            gui.ResetOnSpawn = false
            gui.IgnoreGuiInset = true
            gui.DisplayOrder = 1000000
            gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
            gui.Parent = pg
            M.cursorGui = gui
        end
        dot = Instance.new("Frame")
        dot.Name = "Dot"
        dot.Size = UDim2.fromOffset(16, 16)
        dot.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
        dot.BackgroundTransparency = 0.1
        dot.BorderSizePixel = 0
        dot.Active = false -- visual only: never eat clicks meant for the UI/game
        dot.ZIndex = 2
        dot.Parent = gui
        local corner = Instance.new("UICorner")
        corner.CornerRadius = UDim.new(1, 0)
        corner.Parent = dot
        local stroke = Instance.new("UIStroke")
        stroke.Color = Color3.fromRGB(0, 0, 0)
        stroke.Thickness = 2
        stroke.Parent = dot
        local point = Instance.new("Frame")
        point.Name = "Point"
        point.Size = UDim2.fromOffset(4, 4)
        point.Position = UDim2.new(0.5, -2, 0.5, -2)
        point.BackgroundColor3 = Color3.fromRGB(255, 60, 60)
        point.BorderSizePixel = 0
        point.ZIndex = 3
        point.Parent = dot
        local pc = Instance.new("UICorner")
        pc.CornerRadius = UDim.new(1, 0)
        pc.Parent = point
        M.cursorDot = dot
    end
    dot.Position = UDim2.fromOffset(x - 8, y - 8)
    dot.Visible = true
end

local function humanMove(tx, ty, dur)
    local sx, sy = M.cursorX, M.cursorY
    if not sx then
        local mp = UIS:GetMouseLocation()
        sx, sy = mp.X, mp.Y
    end
    local dx, dy = tx - sx, ty - sy
    local dist = math.sqrt(dx * dx + dy * dy)
    if dist < 2 then mouseMove(tx, ty); return end
    dur = dur or moveDur()
    M.mouseBusy = true
    local nx, ny = -dy / dist, dx / dist
    local bend = rnd(-0.18, 0.18) * dist
    local cx, cy = sx + dx * 0.5 + nx * bend, sy + dy * 0.5 + ny * bend
    local t0 = tick()
    while srsAlive() do
        local t = (tick() - t0) / dur
        if t >= 1 then break end
        local e = t < 0.5 and (2 * t * t) or (1 - ((-2 * t + 2) ^ 2) / 2)
        local u = 1 - e
        local x = u * u * sx + 2 * u * e * cx + e * e * tx
        local y = u * u * sy + 2 * u * e * cy + e * e * ty
        mouseMove(x + rnd(-0.6, 0.6) * (1 - t), y + rnd(-0.6, 0.6) * (1 - t))
        task.wait()
    end
    mouseMove(tx, ty)
    M.mouseBusy = false
end

-- AbsolutePosition ignores the top-bar inset on ScreenGuis that respect it;
-- the virtual mouse works in full-screen coordinates.
local function targetPoint(obj)
    local p, s = obj.AbsolutePosition, obj.AbsoluteSize
    local ox, oy = 0, 0
    local sg = obj:FindFirstAncestorOfClass("ScreenGui")
    if sg and not sg.IgnoreGuiInset then
        local ok, inset = pcall(function() return GuiService:GetGuiInset() end)
        if ok and inset then ox, oy = inset.X, inset.Y end
    end
    return p.X + s.X * rnd(0.3, 0.7) + ox, p.Y + s.Y * rnd(0.3, 0.7) + oy
end

-- World-space (SurfaceGui/BillboardGui) buttons never receive synthetic
-- VirtualInputManager clicks: their AbsolutePosition is surface-local, so the
-- virtual mouse never lands on them. Firing the button's own click handler is
-- still the button path (the game's own handler runs) — never the server remote.
local function isWorldGuiButton(obj)
    return obj:FindFirstAncestorWhichIsA("SurfaceGui") ~= nil
        or obj:FindFirstAncestorWhichIsA("BillboardGui") ~= nil
end

-- [FIX] I-011: a SurfaceGui button reports AbsolutePosition in surface-canvas
-- pixels (the store PC's screen is a 2.38 x 1.35 stud part, CanvasSize
-- 800x600), so the old world-button path could never put the cursor on the
-- button at all — the user saw the macro buy without the mouse moving
-- ("does not ... move my mouse and click"). Project the button's face point
-- through the camera to a real screen position. This is for show only:
-- activateButton still performs the click, because a synthetic click cannot
-- land on a 3D surface.
local function worldButtonScreenPoint(obj)
    local sg = obj:FindFirstAncestorWhichIsA("SurfaceGui")
    local ad = sg and sg.Adornee
    local cam = workspace.CurrentCamera
    if not (ad and ad:IsA("BasePart") and cam) then return nil end
    local canvas = sg.CanvasSize
    local cw = (canvas and canvas.X > 0) and canvas.X or sg.AbsoluteSize.X
    local ch = (canvas and canvas.Y > 0) and canvas.Y or sg.AbsoluteSize.Y
    if cw <= 0 or ch <= 0 then return nil end
    local ap, asz = obj.AbsolutePosition, obj.AbsoluteSize
    local u = math.clamp((ap.X + asz.X * 0.5) / cw, 0.001, 0.999) - 0.5
    local v = math.clamp((ap.Y + asz.Y * 0.5) / ch, 0.001, 0.999) - 0.5
    local sz = ad.Size
    local f = sg.Face
    local p
    if f == Enum.NormalId.Back then
        p = Vector3.new(-u * sz.X, -v * sz.Y, -sz.Z * 0.5)
    elseif f == Enum.NormalId.Front then
        p = Vector3.new(u * sz.X, -v * sz.Y, sz.Z * 0.5)
    elseif f == Enum.NormalId.Right then
        p = Vector3.new(sz.X * 0.5, -v * sz.Y, -u * sz.Z)
    elseif f == Enum.NormalId.Left then
        p = Vector3.new(-sz.X * 0.5, -v * sz.Y, u * sz.Z)
    elseif f == Enum.NormalId.Top then
        p = Vector3.new(u * sz.X, sz.Y * 0.5, -v * sz.Z)
    else
        p = Vector3.new(u * sz.X, -sz.Y * 0.5, v * sz.Z)
    end
    local ok, sp = pcall(function()
        return cam:WorldToScreenPoint(ad.CFrame:PointToWorldSpace(p))
    end)
    if ok and sp then return sp.X, sp.Y, sp.Z end
    return nil
end

-- ── Visual focus hooks ─────────────────────────────────────────────────────
-- Stored on the global Helpers table (never new bootScript locals — I-008).
-- The mouse driver on this executor cannot move the OS cursor, so the drawn
-- dot is the visible stand-in (see mouseMove). These hooks glide it onto
-- whatever the macro is about to interact with, so Full Auto looks like a
-- player using the mouse: buy phase → the offer's own button, sell phase →
-- the bar's StopButton, NPC sells → the vendor's prompt.

Helpers.focusOfferButton = function(i)
    local frame = getOfferSlotsFrame()
    local slot = frame and frame:FindFirstChild("Offer" .. i)
    if not slot then return end
    local btn = slotButtons(slot)[1]
    if not btn then return end
    if isWorldGuiButton(btn) then
        local wx, wy, wz = worldButtonScreenPoint(btn)
        if wx and wz and wz > 0 then humanMove(wx, wy, 0.16) end
    else
        local x, y = targetPoint(btn)
        humanMove(x, y, 0.16)
    end
end

Helpers.focusSellNPC = function(npc)
    local cam = workspace.CurrentCamera
    local head = npc and npc:FindFirstChild("Head")
    if not (cam and head) then return end
    local ok, sp = pcall(function() return cam:WorldToScreenPoint(head.Position) end)
    if ok and sp and sp.Z > 0 then humanMove(sp.X, sp.Y, 0.2) end
end

-- Called every frame while the sell bar is up: park the drawn cursor on the
-- StopButton — the control a real player taps to grade the sale.
Helpers.sellBarCursorTick = function()
    if not (SellFrame and SellFrame.Visible) then return end
    local btn = SellFrame.StopButton
    if not btn then return end
    -- Pick the resting spot ONCE per button (targetPoint is random, so calling
    -- it every frame made the dot hop around the button = jitter). Store it as a
    -- fraction of the button so it still tracks if the button moves/resizes.
    local fr = Helpers.sellBarCursorFrac
    if not fr or fr.btn ~= btn then
        fr = { btn = btn, u = rnd(0.4, 0.6), v = rnd(0.4, 0.6) }
        Helpers.sellBarCursorFrac = fr
    end
    local p, s = btn.AbsolutePosition, btn.AbsoluteSize
    local ox, oy = 0, 0
    local sg = btn:FindFirstAncestorOfClass("ScreenGui")
    if sg and not sg.IgnoreGuiInset then
        local okI, inset = pcall(function() return GuiService:GetGuiInset() end)
        if okI and inset then ox, oy = inset.X, inset.Y end
    end
    local x, y = p.X + s.X * fr.u + ox, p.Y + s.Y * fr.v + oy
    -- Skip sub-pixel updates so the dot sits perfectly still once parked.
    local cx, cy = M.cursorX, M.cursorY
    if cx and math.abs(cx - x) < 0.5 and math.abs(cy - y) < 0.5 then return end
    mouseMove(x, y)
end

-- Cursor press flash on the stop tap (visual only, no raw input events).
Helpers.sellBarPressFlash = function()
    local dot = M.cursorDot
    if not (dot and dot.Parent) then return end
    local px, py = dot.Position.X.Offset, dot.Position.Y.Offset
    dot.Size = UDim2.fromOffset(12, 12)
    dot.Position = UDim2.fromOffset(px + 2, py + 2)
    task.delay(0.1, function()
        if dot.Parent then
            dot.Size = UDim2.fromOffset(16, 16)
            dot.Position = UDim2.fromOffset(px, py)
        end
    end)
end

-- ── PC shop screen: genuinely open it during buy phases ────────────────────
-- The game marks the shop open only while PCScreenGui.AlwaysOnTop is true;
-- that is set by the PC's own ProximityPrompt handler, which also moves the
-- camera onto the shop screen. Full Auto used to buy entirely through the
-- remotes with the screen shut, so the user never saw the shop. Open it after
-- arriving at the PC, and exit it again before walking to the sell NPC.
Helpers.shopScreenIsOpen = function()
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    local gui = pg and pg:FindFirstChild("PCScreenGui")
    return gui ~= nil and gui.AlwaysOnTop == true
end

Helpers.openShop = function()
    if Helpers.shopScreenIsOpen() then return true end
    local store = getStore()
    local pc = store and store:FindFirstChild("PC")
    local scr = pc and pc:FindFirstChild("PCScreen")
    local prompt = scr and scr:FindFirstChild("ProximityPrompt")
    if not prompt then return false end
    -- We are standing inside the prompt's range (ensureAtStorePC). Firing the
    -- prompt runs the game's own open handler; a signal fire is the fallback.
    pcall(function() fireproximityprompt(prompt) end)
    for _ = 1, 12 do
        deltaWait(0.1)
        if Helpers.shopScreenIsOpen() then
            LogEvent("Shop", "PC screen opened")
            return true
        end
    end
    pcall(function() firesignal(prompt.Triggered) end)
    for _ = 1, 12 do
        deltaWait(0.1)
        if Helpers.shopScreenIsOpen() then
            LogEvent("Shop", "PC screen opened (signal fallback)")
            return true
        end
    end
    LogEvent("Shop", "PC screen did not open")
    return false
end

-- Hands the camera and mouse back to the player. Used whenever the PC shop
-- screen is closed or fails to close, so the camera can never stay locked.
Helpers.restoreCamera = function()
    local cam = workspace.CurrentCamera
    local chr = LocalPlayer.Character
    local hum = chr and chr:FindFirstChildOfClass("Humanoid")
    pcall(function()
        if cam then
            cam.CameraType = Enum.CameraType.Custom
            if hum then cam.CameraSubject = hum end
        end
    end)
    pcall(function() UIS.MouseBehavior = Enum.MouseBehavior.Default end)
end

Helpers.closeShop = function()
    if not Helpers.shopScreenIsOpen() then return true end
    local store = getStore()
    local pc = store and store:FindFirstChild("PC")
    local exitPart = pc and pc:FindFirstChild("ExitPart")
    local sg = exitPart and exitPart:FindFirstChild("SurfaceGui")
    local btn = sg and sg:FindFirstChild("ExitButton")
    if not btn then
        Helpers.restoreCamera()
        return false
    end
    pcall(function() firesignal(btn.MouseButton1Click) end)
    for _ = 1, 6 do
        deltaWait(0.1)
        if not Helpers.shopScreenIsOpen() then
            LogEvent("Shop", "PC screen closed")
            return true
        end
    end
    LogEvent("Shop", "PC screen did not close")
    -- Last resort so the player is never stuck: free the camera and drop the
    -- shop's always-on-top flag, then re-check.
    Helpers.restoreCamera()
    pcall(function()
        local pg = LocalPlayer:FindFirstChild("PlayerGui")
        local gui = pg and pg:FindFirstChild("PCScreenGui")
        if gui then gui.AlwaysOnTop = false end
    end)
    return not Helpers.shopScreenIsOpen()
end

-- Safe to call any time (start/stop of an automation): closes a leftover PC
-- shop screen and always gives the camera back.
Helpers.forceCloseShop = function()
    if Helpers.shopScreenIsOpen() then Helpers.closeShop() end
    Helpers.restoreCamera()
end

-- [FIX] Bring the script window back when automation starts. The library
-- hides Container and leaves only a tiny ReopenDot when the user closes it
-- (and K is the built-in toggle); automation used to start with the window
-- hidden, so there was no visible way to stop it. Uses the library's own
-- Toggle() so the reopen dot state stays in sync.
Helpers.openUI = function()
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    local sak = pg and pg:FindFirstChild("SakuraUI")
    local cont = sak and sak:FindFirstChild("Container")
    if cont and cont.Visible then return true end
    if Window and Window.Toggle then
        pcall(function() Window:Toggle() end)
    end
    return (cont ~= nil and cont.Visible) == true
end

-- Idle liveliness: while an automation runs and nothing else is using the
-- cursor, drift it a few pixels so it never looks frozen on screen.
safeSpawn(function()
    while srsAlive() do
        deltaWait(rnd(2.5, 5.5))
        local active = M.Running or M.selling
        if active and not M.mouseBusy and M.cursorX and not (SellFrame and SellFrame.Visible) then
            humanMove(M.cursorX + rnd(-60, 60), M.cursorY + rnd(-45, 45), rnd(0.35, 0.7))
        end
    end
end)

local function activateButton(obj)
    if not (obj:IsA("TextButton") or obj:IsA("ImageButton")) then return false end
    for _, name in ipairs({ "MouseButton1Click", "Activated", "MouseButton1Down" }) do
        local sig = obj[name]
        if sig then
            local ok, conns = pcall(getconnections, sig)
            if not ok or conns == nil or #conns > 0 then
                if pcall(firesignal, sig) then return true end
            end
        end
    end
    return false
end

local function clickObject(obj)
    if not obj or not obj.Parent or not obj:IsA("GuiObject") then return false end
    __L.scrollIntoView(obj)
    if isWorldGuiButton(obj) then
        -- [FIX] I-011: unreachable by a raw VIM click, so travel the real
        -- cursor onto the projected button first (visible), then run the
        -- button's own handler to guarantee the click.
        local wx, wy, wz = worldButtonScreenPoint(obj)
        if wx and wz and wz > 0 then
            humanMove(wx, wy)
            task.wait(rnd(0.04, 0.12))
            local x2, y2, _ = worldButtonScreenPoint(obj)
            if x2 and math.abs(x2 - wx) + math.abs(y2 - wy) > 6 then humanMove(x2, y2, 0.1) end
        end
        local ok = activateButton(obj)
        M.stats.clicks += 1
        return ok
    end
    if not __L.shoeOnScreen(obj) then return false end
    local x, y = targetPoint(obj)
    humanMove(x, y)
    task.wait(rnd(0.05, 0.14))
    local x2, y2 = targetPoint(obj)
    if math.abs(x2 - x) + math.abs(y2 - y) > 8 then
        humanMove(x2, y2, 0.12)
        x, y = x2, y2
    end
    -- Move the real cursor for show, then run the button's own handler. A raw
    -- VIM click silently no-ops on several of this game's controls, so the
    -- handler is fired to guarantee the click registers exactly once.
    local ok = activateButton(obj)
    if not ok then
        pcall(function() VIM:SendMouseButtonEvent(x, y, 0, true, game, 1) end)
        task.wait(rnd(0.04, 0.11))
        pcall(function() VIM:SendMouseButtonEvent(x, y, 0, false, game, 1) end)
    end
    M.stats.clicks += 1
    return true
end

-- ── Opening the PC UI ──────────────────────────────────────────────────────
local function ensureShop(alive)
    local frame = getOfferSlotsFrame()
    if frame and not inPlayerGui(frame) then return nil, "the PC screen is a world-space SurfaceGui (not clickable)" end
    if frame and shown(frame) then return frame end
    local store = getStore()
    local pc = store and store:FindFirstChild("PC")
    if pc then
        -- Fire all reachable PC triggers so the world screen actually opens.
        for _, d in ipairs(pc:GetDescendants()) do
            if d:IsA("ProximityPrompt") then pcall(fireproximityprompt, d)
            elseif d:IsA("ClickDetector") then pcall(fireclickdetector, d) end
        end
        -- [FIX] proactively walk to the PC so the screen is actually visible/usable
        local hrp = getHRP()
        local okp, pivot = pcall(function() return pc:GetPivot() end)
        if hrp and okp and pivot then
            local r = 8
            for _, d in ipairs(pc:GetDescendants()) do
                if d:IsA("ProximityPrompt") then r = math.max(4, (tonumber(d.MaxActivationDistance) or 10) - 2); break end
            end
            if (hrp.Position - pivot.Position).Magnitude > r + 6 then
                pcall(function() walkToPC(function() return alive() end) end)
            end
        end
        if not alive() then return nil end
        task.wait(0.2)
        frame = getOfferSlotsFrame()
        if frame and inPlayerGui(frame) and shown(frame) then return frame end
    end
    return nil, "the PC UI did not open"
end

-- ── Buying ─────────────────────────────────────────────────────────────────
local function inventoryCount() return sellableInventoryCount() end

-- True once money dropped or the inventory grew; returns (ok, moneySpent).
local function waitPurchase(before, invBefore, timeout)
    local deadline = tick() + timeout
    while tick() < deadline do
        local now = getMoney()
        if now < before then return true, before - now end
        if inventoryCount() > invBefore then return true, 0 end
        task.wait(0.1)
    end
    return false, 0
end

local function clickBuy(e, frame, alive)
    __L.dumpOfferStructure(e.i)
    local before, invBefore = getMoney(), inventoryCount()
    local cands = slotButtons(e.slot)
    for n = 1, math.min(#cands, 3) do
        if not alive() then return false end
        if clickObject(cands[n]) then
            task.wait(rnd(0.25, 0.45))
            local confirm = findConfirm(frame)
            if confirm then
                clickObject(confirm)
                task.wait(rnd(0.15, 0.3))
            end
            local ok, spent = waitPurchase(before, invBefore, 1.6)
            if ok then return true, spent, false end
        end
    end
    if M.Fallback and alive() then
        local bought, _, spent = __L.attemptBuyOffer(e.i)
        if bought then
            M.stats.remote += 1
            return true, tonumber(spent) or 0, true
        end
    end
    return false, 0, false
end

local warnedNames = false
local function blacklistActive()
    local b = Settings.Buy.Blacklist
    return b.Common or b.Uncommon or b.Epic or b.Legendary or b.Legacy or b.Special or b.Limited or b.Grail
end

local function guiPass(alive, frame)
    local list, lockedN, total, unreadable = {}, 0, 0, 0
    for i = 1, 16 do
        local slot = frame:FindFirstChild("Offer" .. i)
        if slot then
            total += 1
            local locked = slotLocked(slot)
            if locked then lockedN += 1 end
            local name = readSlotName(slot)
            if not name then unreadable += 1 end
            list[#list + 1] = { i = i, slot = slot, locked = locked, name = name }
        end
    end
    -- If every slot looks "locked" the lock detection is wrong, not the shop.
    local ignoreLock = total > 0 and lockedN == total
    if unreadable > 0 and unreadable == total and blacklistActive() and not warnedNames then
        warnedNames = true
        Notify({ Title = "Macro", Content = "Couldn't read shoe names from the PC UI, so the Blacklist can't be applied. Turn on 'Strict Blacklist' to skip unreadable slots.", Duration = 7, Image = "Alert" })
        LogEvent("Macro", "shoe names unreadable (" .. unreadable .. "/" .. total .. " slots)")
    end
    local plan = {}
    for _, e in ipairs(list) do
        if pcSelectedSlots[e.i] and (ignoreLock or not e.locked) then
            local data = e.name and Sneakers[e.name] or nil
            local skip = false
            if data then skip = isBlacklisted(data) elseif M.Strict then skip = true end
            if not skip then
                e.data = data
                e.rank = __L.rarityRank(data)
                plan[#plan + 1] = e
            end
        end
    end
    table.sort(plan, function(a, b)
        if a.rank ~= b.rank then return a.rank > b.rank end
        return a.i < b.i
    end)
    local bought, skippedOver, failed = 0, 0, 0
    for _, e in ipairs(plan) do
        if not alive() then break end
        local left = Helpers.budgetLeft()
        if left <= 0 then break end
        local price = __L.getOfferRealPrice(e.i)
        if price and price > left then
            skippedOver += 1
            continue
        end
        if not e.slot.Parent then continue end
        setStatus("Clicking slot " .. e.i)
        local ok, spent = clickBuy(e, frame, alive)
        if ok then
            bought += 1
            local s = tonumber(spent) or 0
            if s <= 0 and price then s = price end
            getgenv().ShoesBought += 1
            if e.data then getgenv().trackBoughtRarity(e.data) end
            Helpers.recordSpend(s)
            M.stats.bought += 1
            M.stats.spent += s
            Notify({ Title = "Macro", Content = "Bought slot " .. e.i .. (e.name and (": " .. e.name) or ""), Duration = 2, Image = "Check" })
        else
            failed += 1
        end
        deltaWait(getBuyDelay(M.Speed))
    end
    return bought, skippedOver, failed
end

-- One buy+refresh pass. Mouse mode when the PC UI and its Refresh button are
-- found; otherwise (and only if Remote Fallback is on) a remote-driven pass.
local function onePass(alive)
    ensureAtStorePC(alive)
    __L.tryAutoUnlock()
    -- The Macro is the one mode that really uses the shop screen: open it so the
    -- camera sits on the PC and every move/click of the cursor is visible.
    if Helpers.openShop and not Helpers.shopScreenIsOpen() then pcall(Helpers.openShop) end
    local frame, why = ensureShop(alive)
    local btn = frame and findRefresh(frame)
    if frame and btn then
        if M.mode ~= "mouse" then
            M.mode = "mouse"
            LogEvent("Macro", "mouse mode (frame=" .. frame:GetFullName() .. ")")
        end
        setStatus("Buying with the mouse")
        local bought, skipped = guiPass(alive, frame)
        if not alive() then return bought, skipped end
        setStatus("Clicking Refresh")
        local b2 = findRefresh(frame) or btn
        clickObject(b2)
        task.wait(rnd(0.35, 0.7))
        return bought, skipped
    end
    if frame and not btn then why = "no Refresh button found" end
    if not M.Fallback then
        setStatus("Waiting: " .. tostring(why or "PC UI not found") .. " (Remote Fallback is off)")
        task.wait(2)
        return 0, 0
    end
    if M.mode ~= "remote" then
        M.mode = "remote"
        LogEvent("Macro", "remote mode: " .. tostring(why))
        Notify({ Title = "Macro", Content = "Remote mode — " .. tostring(why or "PC UI not found") .. ". Buying through the server instead of the mouse.", Duration = 6, Image = "Alert" })
    end
    setStatus("Buying (remote mode)")
    closeSellBar()
    local ok, items = Helpers.refreshShopPage()
    if not ok or type(items) ~= "table" then
        task.wait(1.5)
        return 0, 0
    end
    local bought, _, spent, skipped = runBuyCycle(items, M.Speed, {
        cursor  = true,
        running = alive,
        slots   = pcSelectedSlots,
        limit   = Helpers.budgetOn() and Helpers.budgetLeft() or nil,
    })
    M.stats.bought += bought
    M.stats.spent += spent or 0
    return bought, skipped
end

-- Budget spent / nothing buyable: sell, fresh snapshot, carry on.
-- Returns false when the macro should end (broke with nothing to sell).
local function swapPhase(alive, reason)
    LogEvent("Macro", "swap phase: " .. reason)
    -- Leave the PC screen (camera back to normal) before walking off to sell.
    if Helpers.forceCloseShop then pcall(Helpers.forceCloseShop) end
    Notify({ Title = "Macro", Content = "Swapping to selling (" .. reason .. ")", Duration = 3, Image = "Store" })
    if inventoryIsEmpty() then
        if getMoney() <= 0 then
            Notify({ Title = "Macro", Content = "Out of money and nothing to sell — macro stopped.", Duration = 6, Image = "X" })
            setStatus("Out of money")
            return false
        end
        Helpers.snapshotBudget("Macro")
        return true
    end
    if __L.shouldSkipSell() then
        Helpers.snapshotBudget("Macro")
        return true
    end
    setStatus("Selling inventory")
    safeSpawn(function() pcall(function() Helpers.checkDailyQuests(true) end) end)
    M.selling = true
    getgenv().SRS_StartSell()
    deltaWait(1)
    local t0 = tick()
    while alive() and Settings.Sell and tick() - t0 < 900 do deltaWait(0.5) end
    getgenv().SRS_StopSell()
    M.selling = false
    if not alive() then return false end
    M.stats.swaps += 1
    safeSpawn(function() pcall(function() Helpers.checkDailyQuests(true) end) end)
    walkToPC(alive)
    Helpers.snapshotBudget("Macro")
    safeSpawn(function()
        postWebhook("SRS | by Sakura's Hub", "Macro Sell Cycle Complete", "**Shoes Sold:** " .. fmtNum(getgenv().ShoesSold) .. "\n")
    end)
    local st = getgenv().SRS_Stability
    if st and st.hopAfterSell and getgenv()._SRS_serverHop then
        deltaWait(2)
        getgenv()._SRS_serverHop(game.PlaceId)
    end
    return true
end

local function mainLoop(myId)
    local function alive() return M.Running and M.id == myId and srsAlive() end
    setStatus("Walking to the PC")
    walkToPC(alive)
    local dry = 0
    while alive() do
        local reason
        if Helpers.budgetExhausted() then
            reason = "buy budget spent"
        elseif dry >= M.MaxDry then
            reason = dry .. " passes without a purchase"
        end
        if reason then
            if not swapPhase(alive, reason) then break end
            dry = 0
            if not alive() then break end
        end
        local bought = onePass(alive)
        M.stats.passes += 1
        if (bought or 0) > 0 then dry = 0 else dry += 1 end
        report()
        if not alive() then break end
        setStatus("Waiting for the shop")
        deltaWait(getReloadDelay(M.Speed))
    end
end

function M.start(callerToggle)
    if M.Running then return end
    cancelOtherAutomation(callerToggle)
    Settings.Buy.Enabled        = false
    Settings.Sell               = false
    State.pcAutoBuyRunning      = false
    getgenv().FullAutoRunning   = false
    getgenv().PCFullAutoRunning = false
    M.id += 1
    local myId = M.id
    M.Running = true
    M.mode = ""
    M.refreshBtn = nil
    warnedNames = false
    M.stats = { passes = 0, bought = 0, spent = 0, swaps = 0, clicks = 0, remote = 0 }
    Helpers.snapshotBudget()
    setStatus("Starting")
    LogEvent("Macro", "Started speed=" .. tostring(M.Speed) .. " budget=" .. tostring(getgenv().SRS_BuyBudget))
    Notify({ Title = "Macro", Content = "Started (" .. tostring(M.Speed) .. ") — budget " .. fmtMoney(getgenv().SRS_BuyBudget or 0), Duration = 4, Image = "Check" })
    safeSpawn(function()
        postWebhook("SRS | by Sakura's Hub", "Macro Started", "**Speed:** " .. tostring(M.Speed) .. "\n**Budget:** " .. fmtMoney(getgenv().SRS_BuyBudget or 0) .. "\n")
    end)
    M.thread = task.spawn(function()
        local ok, err = pcall(mainLoop, myId)
        if not ok then Log("ERROR", "Macro crashed: " .. tostring(err)) end
        if M.id == myId and M.Running then
            -- [DIAG] Re-executing the script bumps getgenv().SRS_ReloadGen, which
            -- makes srsAlive() false; mainLoop then exits on its first `while`
            -- check and the macro self-stops with "passes=0". From the log alone
            -- that looked like a random crash (I-003). Name the real cause.
            local reason = (not srsAlive()) and "script reload" or nil
            M.stop(nil, reason)
        end
    end)
end

function M.stop(silent, reason)
    if not M.Running then return end
    M.Running = false
    M.id += 1
    if M.selling then
        M.selling = false
        pcall(function() getgenv().SRS_StopSell() end)
    end
    safeSetToggle("MacroRun", false)
    setStatus("Stopped")
    LogEvent("Macro", "Stopped passes=" .. M.stats.passes .. " bought=" .. M.stats.bought .. (reason and (" (" .. reason .. ")") or ""))
    if not silent then
        Notify({ Title = "Macro", Content = "Stopped. Bought " .. M.stats.bought .. " shoe(s).", Duration = 3, Image = "X" })
        local b, sp = M.stats.bought, M.stats.spent
        safeSpawn(function()
            postWebhook("SRS | by Sakura's Hub", "Macro Stopped", "**Shoes Bought:** " .. fmtNum(b) .. "\n**Spent:** " .. fmtMoney(sp) .. "\n")
        end)
    end
    local th = M.thread
    M.thread = nil
    if th and th ~= coroutine.running() then pcall(task.cancel, th) end
    -- Never leave the PC screen open / the camera locked after the macro ends.
    safeSpawn(function() if Helpers.forceCloseShop then pcall(Helpers.forceCloseShop) end end)
end

-- One pass for testing from the UI.
function M.once()
    if M.Running then
        Notify({ Title = "Macro", Content = "Macro is already running.", Duration = 3, Image = "Alert" })
        return
    end
    M.id += 1
    local myId = M.id
    M.Running = true
    Helpers.snapshotBudget()
    local function alive() return M.Running and M.id == myId and srsAlive() end
    local ok, err = pcall(function()
        walkToPC(alive)
        local bought = onePass(alive)
        Notify({ Title = "Macro", Content = "Test pass done — bought " .. tostring(bought or 0) .. ".", Duration = 4, Image = "Check" })
    end)
    if not ok then Log("ERROR", "Macro test failed: " .. tostring(err)) end
    if M.id == myId then M.Running = false end
    setStatus("Idle")
    report()
end

local MACRO_SPEEDS = {
    ["Slow"] = "slow", ["Medium"] = "medium", ["Fast"] = "fast",
    ["Human Slow"] = "human_slow", ["Human Medium"] = "human_medium", ["Human Fast"] = "human_fast",
    ["Risky Slow"] = "risky_slow", ["Risky Medium"] = "risky_medium", ["Risky Fast"] = "risky_fast",
}
local MACRO_SPEED_NAMES = {
    "Slow", "Medium", "Fast", "Human Slow", "Human Medium", "Human Fast",
}

SubPages:Register("Macro", Tabs.PCAuto, function(T, elements)
    SubPages:Nav(T, { label = "PC Page", options = { "Semi PC Auto", "Full PC Auto", "PC Human", "Macro", "Do Everything" }, flag = "NAV_PC", default = "Semi PC Auto" })
    T("CreateSection", "Macro")
    T("CreateLabel", "If the Macro says 'Remote mode', the PC screen could not be clicked (or its Refresh button was not found). It still works, it just buys through the server instead of the mouse.")
    T("CreateLabel", "Test 1 Pass runs a single buy+refresh pass so you can check clicks land before leaving it running.")
    T("CreateLabel", "Walks to your PC, moves the mouse like a person, clicks the shoe in each selected slot, clicks Refresh and repeats.")
    T("CreateLabel", "Respects the Blacklist tab and the PC slot toggles below. Make sure the PC is in view and not blocked by other UI.")
    T("CreateLabel", "Buy Budget snapshot decides when it swaps to selling (any speed, income can't extend it); then it re-snapshots and goes again.")
    PageRefs.macroStatusLabel = T("CreateLabel", "Status: " .. M.status)
    PageRefs.macroStatsLabel  = T("CreateLabel", "Passes: 0 | Bought: 0 | Spent: $0 | Swaps: 0")
    report()

    -- Risky paces live on the Risky tab ("Risky Macro"); fall back to Medium here.
    if not M.Running and tostring(M.Speed):find("^risky") then M.Speed = "medium" end
    local curName = "Medium"
    for _, nm in ipairs(MACRO_SPEED_NAMES) do
        if MACRO_SPEEDS[nm] == M.Speed then curName = nm end
    end
    T("CreateDropdown", {
        Name = "Macro Speed (click + refresh pace)",
        Options = MACRO_SPEED_NAMES,
        Default = curName,
        Flag = "MacroSpeed",
        Callback = function(choice)
            local text = choice[1] or choice
            M.Speed = MACRO_SPEEDS[text] or "medium"
        end,
    })

    Toggles.MacroRun = T("CreateToggle", {
        Name = "Run Macro", CurrentValue = M.Running, Flag = "MacroRun",
        Callback = function(state)
            if state then M.start(Toggles.MacroRun) else M.stop() end
        end,
    })

    T("CreateToggle", {
        Name = "Remote Fallback (if a click doesn't register / UI not found)",
        CurrentValue = M.Fallback, Flag = "MacroFallback",
        Callback = function(state) M.Fallback = state end,
    })
    T("CreateToggle", {
        Name = "Strict Blacklist (skip slots whose shoe can't be read)",
        CurrentValue = M.Strict, Flag = "MacroStrict",
        Callback = function(state) M.Strict = state end,
    })
    T("CreateSlider", {
        Name = "Passes with no purchase before selling",
        Min = 3, Max = 20, Default = M.MaxDry, Precision = 0, Flag = "MacroMaxDry",
        Callback = function(v) M.MaxDry = math.floor(tonumber(v) or 6) end,
    })
    T("CreateButton", {
        Name = "Test 1 Pass",
        Callback = function() safeSpawn(M.once) end,
    })

    buildPCSlotsAndUnlocks(T)
end)

-- ── Risky Macro (lives on the Risky tab) ───────────────────────────────────
-- The same Macro as PC > Macro, locked to the three risky paces. The Macro is
-- the only mode that moves the cursor onto the PC screen and clicks.
SubPages:Register("Risky Macro", Tabs.Risky, function(T, elements)
    Helpers.riskyNav(T)
    T("CreateSection", "Risky Macro")
    T("CreateLabel", "Walks to your PC, opens the shop, moves the mouse onto each shoe, clicks it, clicks Refresh and repeats at risky speed. Bans reported on these speeds (see Info tab).")
    T("CreateLabel", "Respects the Blacklist tab and the PC slot toggles below. Make sure the PC is in view and not blocked by other UI.")
    PageRefs.macroStatusLabel = T("CreateLabel", "Status: " .. M.status)
    PageRefs.macroStatsLabel  = T("CreateLabel", "Passes: 0 | Bought: 0 | Spent: $0 | Swaps: 0")
    report()

    local RISKY_MAP = { ["Risky Slow"] = "risky_slow", ["Risky Medium"] = "risky_medium", ["Risky Fast"] = "risky_fast" }
    local RISKY_NAMES = { "Risky Slow", "Risky Medium", "Risky Fast" }
    local cur = "Risky Medium"
    for _, nm in ipairs(RISKY_NAMES) do
        if RISKY_MAP[nm] == M.Speed then cur = nm end
    end
    if not M.Running and not tostring(M.Speed):find("^risky") then M.Speed = RISKY_MAP[cur] end
    T("CreateDropdown", {
        Name = "Risky Macro Speed (click + refresh pace)",
        Options = RISKY_NAMES,
        Default = cur,
        Flag = "RiskyMacroSpeed",
        Callback = function(choice)
            local text = choice[1] or choice
            M.Speed = RISKY_MAP[text] or "risky_medium"
        end,
    })

    Toggles.MacroRun = T("CreateToggle", {
        Name = "Run Risky Macro", CurrentValue = M.Running, Flag = "MacroRun",
        Callback = function(state)
            if state then M.start(Toggles.MacroRun) else M.stop() end
        end,
    })
    T("CreateButton", {
        Name = "Test 1 Pass",
        Callback = function() safeSpawn(M.once) end,
    })

    buildPCSlotsAndUnlocks(T)
end)
end

end)()

-- ── Quests sub-page ──────────────────────────────────────────────────────────
SubPages:Register("Quests", Tabs.Quests, function(T, elements)
    T("CreateSection", "Daily Quests")
    T("CreateLabel", "Daily quests are claimed only while the game's 2X money boost is live (or when Full Auto forces a claim around a sell). Claims are saved so a reload never double-claims.")
    T("CreateLabel", "Auto-claims each daily quest when its counter passes the target")
    T("CreateLabel", "Redeems the final bonus once all three quests are done")
    T("CreateLabel", "Checks every 60 seconds | Claims survive script reloads and rejoins")

    Toggles.AutoRedeemQuests = T("CreateToggle", {
        Name = "Auto Redeem Daily Quests",
        CurrentValue = (Settings.Quests and Settings.Quests.AutoRedeem) ~= false,
        Flag = "AutoRedeemQuests",
        Callback = function(state)
            if not Settings.Quests then Settings.Quests = {} end
            Settings.Quests.AutoRedeem = state
            saveSettings()
        end,
    })
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- ── Blacklist sub-page ──────────────────────────────────────────────────────
-- ═══════════════════════════════════════════════════════════════════════════
-- Halloween tab: boxes + skeleton trade-in, one toggle, a few test buttons.
SubPages:Register("Halloween", Tabs.Halloween, function(T, elements)
    T("CreateSection", "Auto Halloween")
    T("CreateLabel", "ONE toggle does it all: opens every Candy box you can afford, then walks to the skeleton ('Give me these Sneakers') and trades in the moment all three shoes read 5/5 - repeating while you still have 5/5.")
    T("CreateLabel", "Runs after each Full Auto / PC Full Auto / Do Everything sell phase, and by itself (every ~6s) whenever no other automation is running. Off at boot.")
    Toggles.HalloweenAuto = T("CreateToggle", {
        Name = "Auto Halloween (boxes + trade-in)",
        CurrentValue = (Settings.HalloweenTradeIn and Settings.HalloweenTradeIn.Enabled) == true,
        Flag = "HalloweenAuto",
        Callback = function(state)
            if not Settings.HalloweenBoxes then Settings.HalloweenBoxes = {} end
            if not Settings.HalloweenTradeIn then Settings.HalloweenTradeIn = {} end
            Settings.HalloweenBoxes.Enabled = state
            Settings.HalloweenTradeIn.Enabled = state
            if state then
                getgenv().SRS_HalloweenFromSell = nil
                Notify({ Title = "Halloween", Content = "Enabled - Will run after next Full/PC Full Auto sell phase", Duration = 4, Image = "Store" })
            else
                getgenv().SRS_HalloweenFromSell = nil
                Notify({ Title = "Halloween", Content = "Disabled", Duration = 2, Image = "X" })
            end
        end,
    })

    PageRefs.halloweenArmedLabel = T("CreateLabel", "Status: Idle")

    T("CreateSection", "What you still need")
    PageRefs.halloweenStatusLabel = T("CreateLabel", "Reading the skeleton board and your inventory...")
    T("CreateLabel", "Updates by itself every 2s. 'Need' lists exactly how many more of each Halloween shoe the skeleton wants (5 of each). Candy is what the Mystery Box costs per open.")
    T("CreateLabel", "SAFETY: the trade only runs when all three stacks are really 5/5 AND the skeleton board reads 5/5. The game's server consumes partial stacks without paying if the confirm remote is fired early, so this script never does that.")

    T("CreateSection", "Test / Manual")
    -- Runs fn on its own thread, one manual job at a time, and tells you the result.
    local function manual(title, fn)
        if Helpers.halloweenTesting or Helpers.halloweenRunning or Helpers.tradeInBusy then
            Notify({ Title = title, Content = "Already running - wait for it to finish.", Duration = 3, Image = "X" })
            return
        end
        Helpers.halloweenTesting = true
        safeSpawn(function()
            local ok, err = pcall(fn)
            Helpers.halloweenTesting = false
            if not ok then
                Notify({ Title = title, Content = "Failed: " .. tostring(err), Duration = 5, Image = "X" })
                LogEvent("Halloween", title .. " error: " .. tostring(err))
            end
        end)
    end
    local function alive() return srsAlive() end

    T("CreateButton", {
        Name = "Run Full Halloween Cycle Now",
        Callback = function()
            manual("Halloween", function()
                local o, t = Helpers.halloweenCycle(alive, true)
                Notify({ Title = "Halloween", Content = "Opened " .. o .. " box(es), traded in " .. t .. "x.", Duration = 5, Image = (o + t > 0) and "Check" or "X" })
            end)
        end,
    })
    T("CreateButton", {
        Name = "Open Boxes Now",
        Callback = function()
            manual("Halloween Boxes", function()
                local n = Helpers.openHalloweenBoxes(alive, true) or 0
                if n == 0 then
                    Notify({ Title = "Halloween Boxes", Content = "Nothing opened. Event box missing, not enough Candy (" .. Helpers.candy() .. "), or it could not be reached.", Duration = 5, Image = "X" })
                end
            end)
        end,
    })
    T("CreateButton", {
        Name = "Trade In Now",
        Callback = function()
            manual("Halloween Trade-In", function()
                if not Helpers.tradeInReady() then
                    Notify({ Title = "Halloween Trade-In", Content = "Not ready yet: " .. Helpers.tradeInStatusText(), Duration = 7, Image = "X" })
                    return
                end
                local n = Helpers.halloweenTradeIn(alive, true) or 0
                if n == 0 then
                    Notify({ Title = "Halloween Trade-In", Content = "Nothing traded (skeleton missing, unreachable, or the server refused). See the log.", Duration = 5, Image = "X" })
                end
            end)
        end,
    })
    T("CreateButton", {
        Name = "Check Status (Candy + shoes)",
        Callback = function()
            local txt = Helpers.tradeInStatusText()
            Notify({ Title = "Halloween", Content = txt, Duration = 7, Image = "Store" })
        end,
    })
end)

SubPages:Register("Blacklist", Tabs.Blacklist, function(T, elements)

T("CreateSection", "Blacklist")
T("CreateLabel", "Ticked rarities are SKIPPED by every buying mode (Auto Buy, Full Auto, PC pages, Macro). Unticked rarities are bought. Selling is never filtered: every shoe is sold. Only rarities can be skipped - there is no per-shoe blacklist. Choices save across re-injects.")

local function rarityToggle(key, label)
    BLToggles[key] = T("CreateToggle", {
        Name = label,
        CurrentValue = Settings.Buy.Blacklist[key],
        Flag = key .. "Blacklist",
        Callback = function(state)
            Settings.Buy.Blacklist[key] = state
            saveSettings()
        end,
    })
end

-- [FIX] Paint each rarity toggle's label with the game's own RarityColors entry
-- so the tab reads like the in-game rarity colours (the user asked why Limited
-- and Grail had no colour while Common did). The toggle is a Frame named
-- "Toggle_<Name>" with a TextLabel child "<Name>.Name"; we recolour that label
-- after the builder returns. Colour lookup is pcall-guarded: an unknown or
-- non-Color3 entry just leaves the default label colour alone.
local function rarityToggleColored(key, label)
    rarityToggle(key, label)
    local col = (getgenv().SRS_RarityColors or {})[key]
    if typeof ~= nil and typeof(col) == "Color3" then
        local tabAPI = Tabs.Blacklist
        local content = tabAPI and tabAPI.content
        -- elements are appended in creation order; the rarity toggle for `key`
        -- is the last Toggle_ frame that matches this label.
        local target = content and content:FindFirstChild("Toggle_" .. label)
        if target then
            for _, d in ipairs(target:GetDescendants()) do
                if d:IsA("TextLabel") then d.TextColor3 = col end
            end
        end
    end
end

rarityToggleColored("Common",    "Common | Grey")
rarityToggleColored("Uncommon",  "Uncommon | Green")
rarityToggleColored("Epic",      "Epic | Purple")
rarityToggleColored("Legendary", "Legendary | Orange")
rarityToggleColored("Legacy",    "Legacy | Green")
rarityToggleColored("Special",   "Special | Blue")
rarityToggleColored("Limited",   "Limited | Red")
rarityToggleColored("Grail",     "Grail | Cyan")
end)

-- ── Auto Dig tab ───────────────────────────────────────────────────────────
-- The whole post-top-level body used to live in one runMainBody() wrapper to
-- stay under Luau's 200-register-per-function limit on legacy executors. It
-- outgrew that too, so it is split into three sequential functions at clean
-- seams (dig ends 5458, stability ends 6020); behavior is unchanged.
function __L.runMainBodyPart1()
AutoDigTab:CreateSection("Auto Dig")
AutoDigTab:CreateSection("Beach Shoes")
createLabelShim(AutoDigTab, "WHAT IT DOES: buys a treasure of the chosen level, walks to it, equips your shovel, digs, presses E until the shoe lands in your inventory, then buys the next treasure. Only treasures near where you started (300 studs) and not owned by other players are dug. Walking tiers use the smart walker (doors, gaps, ledges); Risky tiers teleport instead and carry ban risk. Gold Grocs finds ping your webhook.")

local function getCharacter()  return LocalPlayer.Character end
local function getHRP()
    local char = getCharacter()
    return char and char:FindFirstChild("HumanoidRootPart")
end
local function getHumanoid()
    local char = getCharacter()
    return char and char:FindFirstChildWhichIsA("Humanoid")
end

local function equipShovel()
    local char = getCharacter()
    if not char then return false end
    if char:FindFirstChild("Shovel") then return true end
    local backpack = LocalPlayer:FindFirstChild("Backpack")
    local shovel = backpack and backpack:FindFirstChild("Shovel")
    if shovel then
        local hum = char:FindFirstChildOfClass("Humanoid")
        if hum then hum:EquipTool(shovel); deltaWait(0.3); return true end
    end
    return false
end

local function useShovel()
    local char = getCharacter()
    if not char then return end
    local tool = char:FindFirstChild("Shovel")
    if tool then pcall(function() tool:Activate() end) end
end

local function pressE()
    pcall(function()
        local VIM = game:GetService("VirtualInputManager")
        VIM:SendKeyEvent(true,  Enum.KeyCode.E, false, game)
        deltaWait(0.05)
        VIM:SendKeyEvent(false, Enum.KeyCode.E, false, game)
    end)
end

local function spamE(duration, farmingFlag)
    farmingFlag = farmingFlag or function() return State.farming end
    local deadline = tick() + duration
    while tick() < deadline and farmingFlag() do
        pressE(); deltaWait(0.1)
    end
end

-- Grab the dug shoe by pressing E until the item actually lands in inventory.
-- The old fixed 3s blind mash missed the grab prompt on slower digs, because
-- the treasure despawns and the prompt registers after the dig animation.
-- Waiting for the despawn first skips the useless pre-dig mash: the server
-- owns the dig timing, and presses before the prompt exists burn the window.
local function grabDugShoes(duration, farmingFlag, invSnapBefore, despawnPart)
    local deadline = tick() + duration
    if despawnPart then
        while tick() < deadline and farmingFlag() do
            if not despawnPart.Parent then break end
            deltaWait(0.1)
        end
        if not farmingFlag() then return {} end
    end
    while tick() < deadline and farmingFlag() do
        pressE()
        deltaWait(0.12)
        local found = {}
        local inv = LocalPlayer:FindFirstChild("Inventory")
        local unsellF = inv and inv:FindFirstChild("UnsellableInventory")
        local sellF   = inv and inv:FindFirstChild("SellableInventory")
        if unsellF then
            for _, item in ipairs(unsellF:GetChildren()) do
                local beforeVal = invSnapBefore and invSnapBefore[item.Name]
                if beforeVal == nil or item.Value > beforeVal then table.insert(found, item) end
            end
        end
        if sellF then
            for _, item in ipairs(sellF:GetChildren()) do
                local beforeVal = invSnapBefore and invSnapBefore[item.Name]
                if beforeVal == nil or item.Value > beforeVal then table.insert(found, item) end
            end
        end
        if #found > 0 then
            for _, item in ipairs(found) do
                if invSnapBefore then invSnapBefore[item.Name] = item.Value end
            end
            return found
        end
    end
    return {}
end

-- Ensure a shovel is equipped; when full-auto is on, buy the selected shovel
-- if none is in the backpack (cold start after a fresh buy).
local function ensureShovel(fullAuto)
    if equipShovel() then return true end
    if not fullAuto then return false end
    pcall(function()
        game:GetService("ReplicatedStorage")
            :WaitForChild("RemoteEvents")
            :WaitForChild("BuyShovelEvent")
            :FireServer(getgenv().FullAutoShovelKey or "Shovel")
    end)
    deltaWait(0.6)
    return equipShovel()
end

local function buyNewShovel()
    pcall(function()
        game:GetService("ReplicatedStorage")
            :WaitForChild("RemoteEvents")
            :WaitForChild("BuyTreasure")
            :FireServer(State.selectedLevel)
    end)
end

local function getBestDigPart(treasure)
    if treasure:IsA("BasePart") then return treasure end
    if treasure:IsA("Model") and treasure.PrimaryPart then return treasure.PrimaryPart end
    local exactNames = { "HitBox", "Root", "Base", "Mound", "Treasure" }
    for _, name in ipairs(exactNames) do
        local part = treasure:FindFirstChild(name)
        if part and part:IsA("BasePart") then return part end
    end
    local biggest, biggestVol = nil, 0
    for _, part in ipairs(treasure:GetDescendants()) do
        if part:IsA("BasePart") then
            local vol = part.Size.X * part.Size.Y * part.Size.Z
            if vol > biggestVol then biggestVol = vol; biggest = part end
        end
    end
    return biggest
end

getgenv().DigAnchor = nil
local ANCHOR_RADIUS  = 300

local function isNotOtherPlayers(treasure)
    local myName = LocalPlayer.Name:lower()
    local tName  = treasure.Name:lower()

    -- Check other players' names FIRST — catches "ZoeyCrystal5942"-style treasure names
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer then
            if tName:find(player.Name:lower(), 1, true) then return false end
        end
    end

    -- Attribute checks
    local attr = treasure:GetAttribute("Owner")
    if attr and type(attr) == "string" then return attr:lower() == myName end
    local attrId = treasure:GetAttribute("OwnerId") or treasure:GetAttribute("OwnerUserId")
    if attrId then return tostring(attrId) == tostring(LocalPlayer.UserId) end
    for _, child in ipairs(treasure:GetChildren()) do
        local n = child.Name:lower()
        if n == "owner" or n == "ownerid" or n == "owneruserid" then
            if child:IsA("StringValue") then return child.Value:lower() == myName end
            if child:IsA("ObjectValue") then return child.Value == LocalPlayer end
            if child:IsA("IntValue")    then return child.Value == LocalPlayer.UserId end
        end
    end

    -- If our name is in the treasure name, it's ours
    if tName:find(myName, 1, true) then return true end

    return true
end

local function getSortedTreasures(treasureFolder)
    local hrp = getHRP()
    if not hrp then return {} end
    local anchor = getgenv().DigAnchor or hrp.Position
    local result = {}
    for _, treasure in ipairs(treasureFolder:GetChildren()) do
        if not treasure.Parent then continue end
        if not isNotOtherPlayers(treasure) then continue end
        local part = getBestDigPart(treasure)
        if not part then continue end
        local anchorDist = (anchor - part.Position).Magnitude
        if anchorDist > ANCHOR_RADIUS then continue end
        local dist = (hrp.Position - part.Position).Magnitude
        table.insert(result, { treasure = treasure, part = part, dist = dist })
    end
    table.sort(result, function(a, b) return a.dist < b.dist end)
    return result
end

local WALK_REACH_DIST = 8

local function walkTo(targetPosition, farmingFlag)
    return SmartWalkTo(targetPosition, farmingFlag, { reach = WALK_REACH_DIST, maxTime = 35 })
end

-- Best spot to stand in front of the store PC screen. The old walk stopped
-- "within reach" of the screen from ANY direction, so the character often ended
-- up beside or behind the desk (or on the far side of a wall) facing away.
-- Candidates are in front of and behind the screen along its look axis; a
-- candidate is valid only if there is floor under it and nothing solid between
-- it and the screen. Of the valid ones the nearest to the player wins.
function Helpers.pcStand(pc)
    local ok, result = pcall(function()
        local screen = pc:FindFirstChild("PCScreen") or pc
        local pv = screen:GetPivot()
        local hrp = getHRP()
        local char = LocalPlayer.Character
        local params = RaycastParams.new()
        params.FilterType = Enum.RaycastFilterType.Exclude
        params.FilterDescendantsInstances = { pc, char }
        local look = Vector3.new(pv.LookVector.X, 0, pv.LookVector.Z)
        if look.Magnitude < 0.1 then return nil end
        look = look.Unit
        local best, bestDist
        for _, sign in ipairs({ 1, -1 }) do
            for _, dist in ipairs({ 4, 3, 5 }) do
                local base = pv.Position + look * (sign * dist)
                local down = workspace:Raycast(base + Vector3.new(0, 4, 0), Vector3.new(0, -14, 0), params)
                if down then
                    local standPos = Vector3.new(base.X, down.Position.Y + 3, base.Z)
                    local eye = standPos + Vector3.new(0, 0.5, 0)
                    local toScreen = pv.Position - eye
                    local blocked = workspace:Raycast(eye, toScreen - toScreen.Unit * 0.5, params)
                    if not blocked then
                        local d = hrp and (hrp.Position - standPos).Magnitude or 0
                        if not bestDist or d < bestDist then best, bestDist = standPos, d end
                        break
                    end
                end
            end
        end
        return best
    end)
    return ok and result or nil
end

-- Turn the character to face the screen (stops the "facing away" miss).
function Helpers.facePC(pc)
    pcall(function()
        local hrp = getHRP()
        local screen = pc:FindFirstChild("PCScreen") or pc
        if not hrp then return end
        local p = screen:GetPivot().Position
        if (hrp.Position - p).Magnitude > 20 then return end
        hrp.CFrame = CFrame.lookAt(hrp.Position, Vector3.new(p.X, hrp.Position.Y, p.Z))
    end)
end

-- Cosmetic: walk to this player's store PC so the loop reads as restocking.
-- The buy remotes don't need the PC open; the caller's "keep going" flag stops
-- the walk if its automation toggle flips off mid-transit.
walkToPC = function(farmingFlag)
    if type(farmingFlag) ~= "function" then return false end
    local store = getStore()
    if not store then return false end
    local pc = store:FindFirstChild("PC")
    if not pc then return false end
    -- [FIX] Stand in front of the PC SCREEN, not the PC pivot, and close enough
    -- (maxD - 3) that the screen is actually in view: the screen must project in
    -- front of the camera before the cursor can be moved onto its buttons. The
    -- old reach-8 walk to the pivot often left the player ~8 studs out and facing
    -- away, so the projected button was behind the camera (Z < 0) and the mouse
    -- pass silently did nothing.
    local target = pc:FindFirstChild("PCScreen") or pc
    local ok, pivot = pcall(function() return target:GetPivot() end)
    if not ok or not pivot then return false end
    local reach = WALK_REACH_DIST
    for _, d in ipairs(pc:GetDescendants()) do
        if d:IsA("ProximityPrompt") then
            reach = math.max(3, (tonumber(d.MaxActivationDistance) or 10) - 3)
            break
        end
    end
    local stand = Helpers.pcStand(pc)
    if stand then
        SmartWalkTo(stand, farmingFlag, { reach = 3, maxTime = 35 })
        -- Close but not there (walker stalled)? Fall back to the old "near the screen" target.
        local hrp = getHRP()
        if hrp and (hrp.Position - stand).Magnitude > 8 then
            SmartWalkTo(pivot.Position, farmingFlag, { reach = reach, maxTime = 20 })
        end
    else
        SmartWalkTo(pivot.Position, farmingFlag, { reach = reach, maxTime = 35 })
    end
    Helpers.facePC(pc)
    return true
end

-- Buy-phase proximity gate. Buying reads as restocking when the character
-- stands at their store PC; the buy loops call this before each refresh round
-- and walk back first when far. walkToPC is bounded by walkTo's own maxTime,
-- so an unreachable PC backs off for 60s and the buy proceeds remotely
-- instead of stalling the loop.
local PC_BUY_RADIUS = 20
ensureAtStorePC = function(keepGoing)
    if type(keepGoing) ~= "function" then return true end
    if State.pcGateRetryAt and tick() < State.pcGateRetryAt then return true end
    local store = getStore()
    if not store then return true end
    local pc = store:FindFirstChild("PC")
    if not pc then return true end
    -- [FIX] I-010: the PC shop screen only opens when the PC's own
    -- ProximityPrompt fires, and a prompt only fires within
    -- MaxActivationDistance (~10 studs on the store PC). The old gate called
    -- anything within 20 studs "at the PC", so the character parked 10..20
    -- studs out, the prompt could never trigger, the screen stayed shut and
    -- the mouse pass was skipped (dark remote buy). Same convention as
    -- Helpers.useDoor: stand inside MaxActivationDistance - 2.
    local pcRadius = PC_BUY_RADIUS
    for _, d in ipairs(pc:GetDescendants()) do
        if d:IsA("ProximityPrompt") then
            pcRadius = math.max(4, (tonumber(d.MaxActivationDistance) or 10) - 2)
            break
        end
    end
    local hrp = getHRP()
    if not hrp then return true end
    local ok, pivot = pcall(function() return pc:GetPivot() end)
    if not ok or not pivot then return true end
    if (hrp.Position - pivot.Position).Magnitude <= pcRadius then return true end
    walkToPC(keepGoing)
    local rt = getHRP()
    if rt then
        local ok2, pivot2 = pcall(function() return pc:GetPivot() end)
        if ok2 and pivot2 and (rt.Position - pivot2.Position).Magnitude > pcRadius then
            -- [FIX] The navmesh around the store/arcade stalls the walker 10-25
            -- studs out, so every page paid a 35s walk + 60s backoff. Nudge the
            -- last few studs (same client-side fallback as the cashier sell) so
            -- the PC screen is in range and pages refresh at shop speed.
            local dir = Vector3.new(rt.Position.X - pivot2.Position.X, 0, rt.Position.Z - pivot2.Position.Z)
            if dir.Magnitude < 0.1 then dir = Vector3.new(0, 0, 1) end
            local target = pivot2.Position + dir.Unit * 4
            local sp = Helpers.pcStand(pc)
            if sp then
                rt.CFrame = CFrame.new(sp)
            else
                rt.CFrame = CFrame.new(target.X, rt.Position.Y + 1, target.Z)
            end
            Helpers.facePC(pc)
            task.wait(0.35)
            local rt2 = getHRP()
            if rt2 and (rt2.Position - pivot2.Position).Magnitude > pcRadius then
                State.pcGateRetryAt = tick() + 60
            end
        end
    end
    return true
end

-- ── Halloween Mystery Boxes ───────────────────────────────────────────────
-- Boxes live under Workspace.HalloweenEvent (known: SkeletonAirForceMysteryBox,
-- MainPart.ProximityPrompt "Buy For 100 Candy", hold 0.5s, ~8 studs). Triggering
-- a prompt spends Candy (Players.<me>.PlayerInfo.Candy), the server grants a shoe
-- and plays the opening animation; the prompt is disabled for ~5s and comes back
-- when the box is ready again. So "open" = walk to the box and trigger that
-- prompt while there is Candy for another one. Every Candy box found under
-- HalloweenEvent is handled, so newly added boxes work without a script update.
function Helpers.halloweenPromptCost(prompt)
    return tonumber((tostring(prompt.ActionText):gsub(",", "")):match("(%d+)%s*Candy")) or 100
end

function Helpers.halloweenPromptPos(prompt)
    local par = prompt.Parent
    if par and par:IsA("BasePart") then return par.Position end
    if par and par:IsA("Attachment") then return par.WorldPosition end
    if par and par:IsA("Model") then return par:GetPivot().Position end
    return nil
end

-- Returns a list of { prompt, pos, cost } for every Candy box, known box first.
function Helpers.halloweenBoxes()
    local list = {}
    local ev = Workspace:FindFirstChild("HalloweenEvent")
    if not ev then return list end
    local seen = {}
    local function add(prompt)
        if not prompt or seen[prompt] then return end
        local pos = Helpers.halloweenPromptPos(prompt)
        if not pos then return end
        seen[prompt] = true
        list[#list + 1] = { prompt = prompt, pos = pos, cost = Helpers.halloweenPromptCost(prompt) }
    end
    local known = ev:FindFirstChild("SkeletonAirForceMysteryBox")
    local kmp = known and known:FindFirstChild("MainPart")
    if kmp then add(kmp:FindFirstChildOfClass("ProximityPrompt")) end
    for _, d in ipairs(ev:GetDescendants()) do
        if d:IsA("ProximityPrompt") then
            local grand = d.Parent and d.Parent.Parent
            local candyText = tostring(d.ActionText):find("Candy", 1, true)
            local boxModel = grand and tostring(grand.Name):find("MysteryBox", 1, true)
            if candyText or boxModel then add(d) end
        end
    end
    return list
end

-- Kept for older callers: the first box only.
function Helpers.halloweenBox()
    local b = Helpers.halloweenBoxes()[1]
    if not b then return nil end
    return b.prompt, b.pos
end

function Helpers.candy()
    local info = LocalPlayer:FindFirstChild("PlayerInfo")
    local c = info and info:FindFirstChild("Candy")
    return c and tonumber(c.Value) or 0
end

-- Returns how many boxes were opened. keepGoing() stops it mid-way.
function Helpers.openHalloweenBoxes(keepGoing, force)
    local cfg = Settings.HalloweenBoxes
    if not (cfg and (cfg.Enabled or force)) then return 0 end
    if type(keepGoing) ~= "function" then keepGoing = function() return true end end
    local function alive() return keepGoing() and (cfg.Enabled or force) and srsAlive() end

    local boxes = Helpers.halloweenBoxes()
    if #boxes == 0 then return 0 end   -- event over / not loaded: nothing to do

    local cheapest = math.huge
    for _, b in ipairs(boxes) do cheapest = math.min(cheapest, b.cost) end
    if Helpers.candy() < cheapest then
        LogEvent("Halloween", "Skipped: candy=" .. tostring(Helpers.candy()) .. " cost=" .. cheapest)
        return 0
    end

    local total = 0

    local function openFrom(box)
        local prompt, pos, cost = box.prompt, box.pos, box.cost
        if not prompt.Parent then return 0 end
        if Helpers.candy() < cost then return 0 end

        local reach = math.max(3, (tonumber(prompt.MaxActivationDistance) or 8) - 3)
        local function inRange()
            local hrp = getHRP()
            return hrp and (hrp.Position - pos).Magnitude <= reach + 1.5
        end
        local function goToBox()
            if inRange() then return true end
            SmartWalkTo(pos, keepGoing, { reach = reach, maxTime = 45 })
            if inRange() then return true end
            -- Walker stalled close by: nudge the last few studs (same client-side
            -- fallback as the PC / cashier). A far-away stall is left alone.
            local hrp = getHRP()
            if hrp and (hrp.Position - pos).Magnitude <= 60 then
                local dir = Vector3.new(hrp.Position.X - pos.X, 0, hrp.Position.Z - pos.Z)
                if dir.Magnitude < 0.1 then dir = Vector3.new(0, 0, 1) end
                local t = pos + dir.Unit * 3
                hrp.CFrame = CFrame.new(t.X, pos.Y + 3, t.Z)
                deltaWait(0.35)
            end
            return inRange()
        end

        Notify({ Title = "Halloween Boxes", Content = "Walking to " .. tostring(prompt.Parent and prompt.Parent.Parent and prompt.Parent.Parent.Name or "the Halloween box") .. " (" .. Helpers.candy() .. " Candy)...", Duration = 3, Image = "Store" })
        if not goToBox() then
            Notify({ Title = "Halloween Boxes", Content = "Couldn't reach the box — skipping it.", Duration = 4, Image = "X" })
            LogEvent("Halloween", "Walk failed: " .. tostring(prompt:GetFullName()))
            return 0
        end

        local opened, fails = 0, 0
        while alive() and total + opened < 200 do
            local before = Helpers.candy()
            if before < cost then break end
            -- The prompt is disabled while the last opening animation plays.
            local t0 = tick()
            while alive() and not prompt.Enabled and tick() - t0 < 12 do deltaWait(0.2) end
            if not alive() then break end
            if not prompt.Enabled then
                LogEvent("Halloween", "Prompt stayed disabled — stopping this box")
                break
            end
            if not goToBox() then break end

            -- Trigger: hold for prompts with a hold time, then verify by Candy.
            local hold = tonumber(prompt.HoldDuration) or 0
            if hold > 0 and fails < 2 then
                pcall(function() prompt:InputHoldBegin() end)
                deltaWait(hold + 0.25)
                pcall(function() prompt:InputHoldEnd() end)
            else
                pcall(fireproximityprompt, prompt)
            end
            local t1 = tick()
            while alive() and Helpers.candy() >= before and tick() - t1 < 2.5 do deltaWait(0.1) end

            if Helpers.candy() < before then
                opened = opened + 1
                fails = 0
                deltaWait(0.6) -- let the box start its animation (disables the prompt)
            else
                fails = fails + 1
                if fails >= 4 then
                    LogEvent("Halloween", "Gave up after " .. fails .. " failed triggers")
                    break
                end
                deltaWait(0.4)
            end
        end
        return opened
    end

    for _, box in ipairs(boxes) do
        if not alive() then break end
        total = total + openFrom(box)
    end

    if total > 0 then
        Notify({ Title = "Halloween Boxes", Content = "Opened " .. total .. " box(es). Candy left: " .. Helpers.candy(), Duration = 4, Image = "Check" })
    end
    LogEvent("Halloween", "Opened " .. total .. " candyLeft=" .. tostring(Helpers.candy()))
    return total
end

-- Halloween Trade-In (skeleton: "Give me these Sneakers")
-- Workspace.HalloweenEvent.PromptPart.ProximityPrompt ("Trade In", hold 0)
-- opens PlayerGui.MainScreenGui.HalloweenFrame; its ConfirmButton makes the
-- game fire ReplicatedStorage.RemoteEvents.HalloweenConfirmTradeIn() (no args).
-- The server takes 5 of each required shoe out of
-- Players.<me>.Inventory.UnsellableInventory and grants a reward shoe.
--
-- LIVE-VERIFIED 2026-10-23 (place 12991635726, HalloweenSneakerCounterScript):
--   * The client checks all three stacks >= 5 BEFORE showing the frame.
--   * The Confirm handler fires the remote with NO check of its own, and the
--     server does not re-check either: firing it with short stacks consumes
--     min(have, 5) of EACH shoe and pays NOTHING (confirmed live).
--   * Therefore the frame being visible is the only safe gate; this script
--     never presses Confirm (or fires the remote) while the frame is closed.
--   * The board counters clamp at 1 and refresh every 3s, so READY requires
--     BOTH the ground-truth inventory (all >= 5) and the board at 5/5.
-- READY = every requirement shows n/5 (read from the skeleton board / frame
-- text when it can be found, otherwise from the inventory counts).
Helpers.TRADE_IN_SHOES = {
    "Mike Dunk Low Halloween Skull",
    "Air Bogdan 5 Halloween",
    "Mike Air Force 1 Halloween Skull",
}
Helpers.TRADE_IN_NEED = 5

-- Inventory view: ready, sum of counts, per-shoe counts.
function Helpers.tradeInInventory()
    local inv = LocalPlayer:FindFirstChild("Inventory")
    local un = inv and inv:FindFirstChild("UnsellableInventory")
    local counts, sum, ready = {}, 0, true
    for _, name in ipairs(Helpers.TRADE_IN_SHOES) do
        local v = un and un:FindFirstChild(name)
        local n = v and tonumber(v.Value) or 0
        counts[name] = n
        sum = sum + n
        if n < Helpers.TRADE_IN_NEED then ready = false end
    end
    return ready, sum, counts
end

-- Board view: reads every "n/m" label on the skeleton board and in the trade
-- frame. Returns (found, allComplete, signature).
function Helpers.tradeInBoard()
    local total, complete, sig = 0, 0, {}
    local function scan(root)
        if not root then return end
        for _, d in ipairs(root:GetDescendants()) do
            if d:IsA("TextLabel") or d:IsA("TextButton") then
                local a, b = tostring(d.Text):match("^%s*(%d+)%s*/%s*(%d+)%s*$")
                if a and b then
                    total = total + 1
                    sig[#sig + 1] = a .. "/" .. b
                    if tonumber(a) >= tonumber(b) then complete = complete + 1 end
                end
            end
        end
    end
    scan(Workspace:FindFirstChild("HalloweenEvent"))
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    local msg = pg and pg:FindFirstChild("MainScreenGui")
    scan(msg and msg:FindFirstChild("HalloweenFrame"))
    return total >= 3, total > 0 and complete == total, table.concat(sig, ",")
end

function Helpers.tradeInReady()
    local invReady = Helpers.tradeInInventory()
    local found, boardReady = Helpers.tradeInBoard()
    -- BOTH must agree when the board is readable. The board refreshes every 3s
    -- (HalloweenSneakerCounterScript) so it can lag behind a trade, while the
    -- game's own gate is the inventory count. A live test on 2026-10-23 showed
    -- the server will consume PARTIAL stacks (min(have,5) of each shoe, no
    -- reward) if the confirm remote is fired while short - so never trust a
    -- single source here.
    if found then return (invReady and boardReady) and true or false end
    return invReady and true or false
end

function Helpers.tradeInSnapshot()
    local _, sum, counts = Helpers.tradeInInventory()
    local _, _, sig = Helpers.tradeInBoard()
    return tostring(sum) .. "|" .. sig
end

-- Short names so the dashboard row does not wrap on a 1920px screen.
Helpers.TRADE_IN_SHORT = {
    ["Mike Dunk Low Halloween Skull"]  = "Dunk Low Skull",
    ["Air Bogdan 5 Halloween"]         = "Bogdan 5 Halloween",
    ["Mike Air Force 1 Halloween Skull"] = "AF1 Skull",
}

-- Per-shoe view for the dashboard: { name, short, have, need, ok }.
-- `counts` is optional so a caller that already read the inventory can pass it
-- in and the whole row is built from one consistent snapshot.
function Helpers.tradeInNeeds(counts)
    local _, _, have = Helpers.tradeInInventory()
    counts = counts or have
    local need = Helpers.TRADE_IN_NEED
    local out = {}
    for _, name in ipairs(Helpers.TRADE_IN_SHOES) do
        local n = counts[name] or 0
        out[#out + 1] = {
            name  = name,
            short = Helpers.TRADE_IN_SHORT[name] or name,
            have  = n,
            need  = need,
            ok    = n >= need,
        }
    end
    return out
end

-- One-line live readout for the Halloween tab and the log:
--   "Dunk Low Skull 3/5 · Bogdan 5 Halloween 5/5 · AF1 Skull 5/5
--    Need: 2 more Dunk Low Skull  |  Candy: 16  |  waiting (board not 5/5)"
-- Returns (text, ready).
function Helpers.tradeInStatusText()
    local invReady, _, counts = Helpers.tradeInInventory()
    local found, boardReady, sig = Helpers.tradeInBoard()
    local parts, missing = {}, {}
    for _, e in ipairs(Helpers.tradeInNeeds(counts)) do
        parts[#parts + 1] = string.format("%s %d/%d", e.short, e.have, e.need)
        if not e.ok then
            missing[#missing + 1] = string.format("%d more %s", e.need - e.have, e.short)
        end
    end
    local ready = invReady and (not found or boardReady)
    local state
    if found then
        state = (ready and "READY (5/5 all three)") or ("waiting (board " .. tostring(sig) .. ")")
    else
        state = ready and "READY (inventory 5/5)" or "waiting (inventory)"
    end
    local txt = table.concat(parts, " · ")
    if #missing > 0 then txt = txt .. "  |  Need: " .. table.concat(missing, ", ") end
    txt = txt .. "  |  Candy: " .. tostring(Helpers.candy()) .. "  |  " .. state
    return txt, ready and true or false
end

-- True while another automation owns the character (the idle watcher below
-- never walks the player away from one of those; Full Auto calls the trade-in
-- itself after each sell phase instead).
function Helpers.tradeInBusyElsewhere()
    local G = getgenv()
    return (G.FullAutoRunning or G.PCFullAutoRunning or State.pcAutoBuyRunning
        or State.farming or State.riskFarming
        or (Settings.Buy and Settings.Buy.Enabled) or Settings.Sell
        or (Helpers.Macro and Helpers.Macro.Running)
        or (Helpers.Arcade and Helpers.Arcade.running)
        or Helpers.halloweenTesting) and true or false
end

-- Returns how many trade-ins were completed. keepGoing() stops it mid-way.
function Helpers.halloweenTradeIn(keepGoing, force)
    local cfg = Settings.HalloweenTradeIn
    if not (cfg and (cfg.Enabled or force)) then return 0 end
    if type(keepGoing) ~= "function" then keepGoing = function() return true end end
    local function alive() return keepGoing() and (cfg.Enabled or force) and srsAlive() end
    if Helpers.tradeInBusy then return 0 end

    local ev = Workspace:FindFirstChild("HalloweenEvent")
    local part = ev and ev:FindFirstChild("PromptPart")
    local prompt = part and part:FindFirstChildOfClass("ProximityPrompt")
    if not prompt then return 0 end                 -- event over / not loaded
    if not Helpers.tradeInReady() then
        -- Say WHY it is idle (once every 30s) instead of silently returning 0:
        -- this is what tells the user which shoes are still short.
        local now = tick()
        if not Helpers.tradeInWaitAt or now - Helpers.tradeInWaitAt > 30 then
            Helpers.tradeInWaitAt = now
            local okT, txt = pcall(Helpers.tradeInStatusText)
            LogEvent("Halloween", "TradeIn waiting - " .. tostring(okT and txt or "unknown"))
        end
        return 0                                        -- not 5/5 yet
    end

    local pos = Helpers.halloweenPromptPos(prompt)
    if not pos then return 0 end

    Helpers.tradeInBusy = true
    local done = 0
    local ok, err = pcall(function()
        local reach = math.max(3, (tonumber(prompt.MaxActivationDistance) or 8) - 3)
        local function inRange()
            local hrp = getHRP()
            return hrp and (hrp.Position - pos).Magnitude <= reach + 1.5
        end
        local function goTo()
            if inRange() then return true end
            SmartWalkTo(pos, keepGoing, { reach = reach, maxTime = 45 })
            if inRange() then return true end
            local hrp = getHRP()
            if hrp and (hrp.Position - pos).Magnitude <= 60 then
                local dir = Vector3.new(hrp.Position.X - pos.X, 0, hrp.Position.Z - pos.Z)
                if dir.Magnitude < 0.1 then dir = Vector3.new(0, 0, 1) end
                local t = pos + dir.Unit * 3
                hrp.CFrame = CFrame.new(t.X, pos.Y + 3, t.Z)
                deltaWait(0.35)
            end
            return inRange()
        end
        local function changedWithin(before, secs)
            local t0 = tick()
            while alive() and tick() - t0 < secs do
                if Helpers.tradeInSnapshot() ~= before then return true end
                deltaWait(0.1)
            end
            return Helpers.tradeInSnapshot() ~= before
        end

        Notify({ Title = "Halloween Trade-In", Content = "All shoes at 5/5 - walking to the skeleton...", Duration = 3, Image = "Store" })
        if not goTo() then
            Notify({ Title = "Halloween Trade-In", Content = "Couldn't reach the skeleton.", Duration = 4, Image = "X" })
            LogEvent("Halloween", "TradeIn walk failed")
            return
        end

        local fails = 0
        while alive() and done < 100 do
            if not Helpers.tradeInReady() then break end
            if not goTo() then break end
            local before = Helpers.tradeInSnapshot()

            -- 1) open the trade frame through the real prompt
            if prompt.Enabled then
                local hold = tonumber(prompt.HoldDuration) or 0
                if hold > 0 then
                    pcall(function() prompt:InputHoldBegin() end)
                    deltaWait(hold + 0.25)
                    pcall(function() prompt:InputHoldEnd() end)
                else
                    pcall(fireproximityprompt, prompt)
                end
            end
            local pg = LocalPlayer:FindFirstChild("PlayerGui")
            local msg = pg and pg:FindFirstChild("MainScreenGui")
            local frame = msg and msg:FindFirstChild("HalloweenFrame")
            local t0 = tick()
            while alive() and frame and not frame.Visible and tick() - t0 < 3 do deltaWait(0.1) end

            -- 2) press Confirm ONLY while the frame is actually open.
            --
            -- The game's own LocalScript (HalloweenSneakerCounterScript) checks
            -- all three UnsellableInventory stacks for >= 5 BEFORE it shows the
            -- frame. Its ConfirmButton handler then fires
            -- HalloweenConfirmTradeIn with no check of its own, and the server
            -- trusts it: a live test proved that firing that remote with short
            -- stacks eats min(have, 5) of EACH required shoe and pays nothing.
            -- So the frame being visible IS the gate - never click Confirm and
            -- never fire the remote while it is closed.
            local success = false
            if frame and frame.Visible then
                local btn = frame:FindFirstChild("ConfirmButton", true)
                if btn then
                    pcall(function() firesignal(btn.MouseButton1Click) end)
                    success = changedWithin(before, 2.0)
                    if not success and alive() then
                        pcall(function() firesignal(btn.Activated) end)
                        success = changedWithin(before, 1.5)
                    end
                end
            end
            if not success and alive() then
                local invReady = Helpers.tradeInInventory()
                LogEvent("Halloween", "TradeIn gate: frameVisible=" .. tostring(frame and frame.Visible)
                    .. " inv5x5=" .. tostring(invReady) .. " (direct remote never fired)")
            end

            if success then
                done = done + 1
                fails = 0
                deltaWait(0.8) -- let the reward + frame close settle
            else
                fails = fails + 1
                LogEvent("Halloween", "TradeIn no change (try " .. fails .. ") snap=" .. before)
                if fails >= 2 then break end
                deltaWait(0.6)
            end
        end
    end)
    Helpers.tradeInBusy = false
    if not ok then LogEvent("Halloween", "TradeIn error: " .. tostring(err)) end

    if done > 0 then
        Notify({ Title = "Halloween Trade-In", Content = "Traded in " .. done .. "x.", Duration = 4, Image = "Check" })
    end
    LogEvent("Halloween", "TradeIn done=" .. done)
    return done
end

-- Can at least one Candy box be opened right now?
function Helpers.halloweenCanOpen()
    local boxes = Helpers.halloweenBoxes()
    if #boxes == 0 then return false end
    local cheapest = math.huge
    for _, b in ipairs(boxes) do cheapest = math.min(cheapest, b.cost) end
    return Helpers.candy() >= cheapest
end

-- THE Halloween routine: open every Candy box you can afford, wait for the
-- shoes to land in the inventory, then trade in while the skeleton board reads
-- 5/5. Returns (boxesOpened, tradeIns). Used by Full Auto, PC Full Auto /
-- Do Everything, the idle watcher and the Halloween tab buttons.
function Helpers.halloweenCycle(keepGoing, force)
    local cfgT = Settings.HalloweenTradeIn
    if not force and not (cfgT and cfgT.Enabled) then return 0, 0 end
    if Helpers.halloweenRunning then return 0, 0 end
    Helpers.halloweenRunning = true
    local opened, traded = 0, 0
    local ok, err = pcall(function()
        local okA, a = pcall(Helpers.openHalloweenBoxes, keepGoing, force)
        if okA then opened = tonumber(a) or 0 end
        if opened > 0 then
            -- the last box just paid out: give the inventory / board a moment
            local t0 = tick()
            while srsAlive() and not Helpers.tradeInReady() and tick() - t0 < 3 do deltaWait(0.25) end
        end
        local okB, b = pcall(Helpers.halloweenTradeIn, keepGoing, force)
        if okB then traded = tonumber(b) or 0 end
    end)
    Helpers.halloweenRunning = false
    if not ok then LogEvent("Halloween", "Cycle error: " .. tostring(err)) end
    return opened, traded
end

-- Idle watcher: ONLY runs right after a Full Auto / PC Full Auto sell phase
-- if Auto Halloween is enabled. Turning off manual stuff won't trigger it.
task.spawn(function()
    while srsAlive() do
        task.wait(6)
        local cfg = Settings.HalloweenTradeIn
        if cfg and cfg.Enabled and getgenv().SRS_HalloweenFromSell and not Helpers.halloweenRunning and not Helpers.tradeInBusy
            and not Helpers.tradeInBusyElsewhere() then
            local armed = getgenv().SRS_HalloweenFromSell
            getgenv().SRS_HalloweenFromSell = nil
            pcall(function()
                if armed and (Helpers.tradeInReady() or Helpers.halloweenCanOpen()) then
                    Helpers.halloweenCycle(function()
                        return srsAlive() and not Helpers.tradeInBusyElsewhere()
                    end)
                end
            end)
        end
    end
end)

-- Halloween tab status updater
task.spawn(function()
    while srsAlive() do
        task.wait(1)
        local lbl = PageRefs and PageRefs.halloweenArmedLabel
        if not lbl then
            -- try to find if it exists
        end
        if lbl then
            local cfgT = Settings.HalloweenTradeIn
            if Helpers.halloweenRunning or Helpers.tradeInBusy then
                pcall(function() lbl:Set("Status: Running...") end)
            elseif getgenv().SRS_HalloweenFromSell then
                pcall(function() lbl:Set("Status: Armed - Will run after current sell phase") end)
            elseif cfgT and cfgT.Enabled then
                pcall(function() lbl:Set("Status: Enabled - Waiting for next Full/PC Full Auto sell") end)
            else
                pcall(function() lbl:Set("Status: Disabled") end)
            end
        end
        task.wait(0)
    end
end)

-- Live requirements row on the Halloween tab. Runs even while the tab is not
-- visible (the label handle is just overwritten when the page is rebuilt).
task.spawn(function()
    while srsAlive() do
        task.wait(2)
        local lbl = PageRefs and PageRefs.halloweenStatusLabel
        if lbl then
            local okT, txt = pcall(Helpers.tradeInStatusText)
            if okT and txt then
                pcall(function() lbl:Set(txt) end)
            end
        end
    end
end)

-- ── Auto Dig session state ────────────────────────────────────────────────
local digSessionStart    = nil
local digMoneyAtStart    = nil
local digShoesFound      = 0

-- Dig rarity dashboard counters (per-rare category, survives script reload)
getgenv().DigStats = getgenv().DigStats or {
    Common = 0, Uncommon = 0, Epic = 0, Legendary = 0, Limited = 0, Grail = 0,
}
local function trackDugShoe(shoeName)
    local data = Sneakers[shoeName]
    local rarity = data and data.Rarity or "Common"
    local st = getgenv().DigStats
    if st[rarity] then st[rarity] = st[rarity] + 1 else st[rarity] = 1 end
end

-- ── Dig webhook — uses postDigWebhook (no Shoes Sold) ─────────────────────
local function sendDigWebhook(shoeName, treasureLevel, isRisky)
    if not getgenv().WebhookURL or getgenv().WebhookURL == "" then return end
    local now        = tick()
    local elapsed    = digSessionStart and (now - digSessionStart) or 0
    local moneyNow   = getMoney()
    local moneySpent = Helpers.digSpend()
    local mode       = isRisky and "Teleporting (Risky)" or "Walking"
    __L.postDigWebhook(
        "SRS Auto Dig | by Sakura's Hub",
        "Shoe Dug Up! ",
        "**Shoe Found:** "      .. tostring(shoeName)    ..
        "\n**Treasure Tier:** "  .. tostring(treasureLevel) ..
        "\n**Dig Mode:** "       .. mode                  ..
        "\n**Session Time:** "   .. formatUptime(elapsed) ..
        "\n**Money Spent Digging:** " .. fmtMoney(moneySpent) ..
        "\n**Money Remaining:** " .. fmtMoney(moneyNow)   ..
        "\n**Shoes Dug This Session:** " .. tostring(digShoesFound) .. "\n"
    )
end

-- ══════════════════════════════════════════════════════════════════════════
-- ── UPDATED farmLoop — instance snapshot + Gold Grocs @everyone alert ────
-- ══════════════════════════════════════════════════════════════════════════
local function farmLoop()
    LogEvent("AutoDig", "Started")
    local digCfg         = __L.getDigCfg(State.digSpeed)
    local STUCK_SAME_SPOT_DIST = 2.0
    local lastDigPos           = nil
    local sameSpotCount        = 0
    local skipSet              = {}
    local lastShovelWebhookTick = 0

    local function isFarming() return State.farming end

    while State.farming and srsAlive() do
        digCfg = __L.getDigCfg(State.digSpeed)
        local treasureFolder = workspace:FindFirstChild("TreasureFolder")
        if not treasureFolder then
            deltaWait(2)
            Notify({ Title = "Auto Dig", Content = "TreasureFolder not found — wrong game?", Duration = 3, Image = "X" })
            continue
        end
        local sorted = getSortedTreasures(treasureFolder)
        if #sorted == 0 then
            skipSet = {}
            -- Buy a fresh treasure so walking mode keeps digging instead of
            -- polling an empty folder forever; the server rejects the buy
            -- silently when broke and the poll just resumes next cycle.
            buyNewShovel()
            getgenv().TreasuresBought = (getgenv().TreasuresBought or 0) + 1
            local waitStart = tick()
            while tick() - waitStart < digCfg.buyPoll do
                deltaWait(0.2)
                if #getSortedTreasures(treasureFolder) > 0 then break end
            end
            deltaWait(digCfg.cycle)
            continue
        end

        skipSet = {}

        for _, entry in ipairs(sorted) do
            if not State.farming then break end
            if not entry.treasure.Parent then continue end
            if skipSet[entry.treasure] then continue end

            -- Snapshot BOTH folders right before this dig (track name->value so increments are detected)
            local invSnapBefore = {}
            local inv = LocalPlayer:FindFirstChild("Inventory")
            local _snapUnsell = inv and inv:FindFirstChild("UnsellableInventory")
            local _snapSell   = inv and inv:FindFirstChild("SellableInventory")
            if _snapUnsell then for _, si in ipairs(_snapUnsell:GetChildren()) do invSnapBefore[si.Name] = si.Value end end
            if _snapSell   then for _, si in ipairs(_snapSell:GetChildren())   do invSnapBefore[si.Name] = si.Value end end

            local targetPos = entry.part.Position + Vector3.new(0, 3, 0)

            local hrpNow = getHRP()
            if hrpNow and lastDigPos then
                if (hrpNow.Position - lastDigPos).Magnitude < STUCK_SAME_SPOT_DIST then
                    sameSpotCount += 1
                    if sameSpotCount >= 3 then
                        skipSet[entry.treasure] = true
                        sameSpotCount = 0
                        local hum = getHumanoid()
                        if hum then hum.Jump = true end
                        deltaWait(0.5)
                        continue
                    end
                else
                    sameSpotCount = 0
                end
            end

            local reached = walkTo(targetPos, isFarming)
            if not State.farming or not entry.treasure.Parent then break end

            if not reached then
                skipSet[entry.treasure] = true
                deltaWait(0.3)
                continue
            end

            lastDigPos = getHRP() and getHRP().Position or lastDigPos
            deltaWait(digCfg.settle)
            ensureShovel(true); deltaWait(digCfg.tool)
            useShovel(); deltaWait(digCfg.tool)

            -- Grab dug shoes: press E until the item actually lands in inventory
            local newShoes = grabDugShoes(digCfg.grab, isFarming, invSnapBefore, entry.treasure)

            -- Buy a new treasure only when the old one has been dug up
            if not entry.treasure.Parent then
                buyNewShovel()
                getgenv().TreasuresBought = (getgenv().TreasuresBought or 0) + 1
                local waitStart = tick()
                while tick() - waitStart < digCfg.buyPoll do
                    deltaWait(0.2)
                    if #getSortedTreasures(treasureFolder) > 0 then break end
                end
                if tick() - lastShovelWebhookTick > 15 then
                    lastShovelWebhookTick = tick()
                    safeSpawn(function()
                        __L.postDigWebhook(
                            "SRS Auto Dig | by Sakura's Hub",
                            "Bought New Treasure ",
                            "**Treasure Tier:** " .. State.selectedLevel .. "\n"
                        )
                    end)
                end
            end

            deltaWait(digCfg.cycle)

            -- Fire webhooks for every new shoe
            for _, item in ipairs(newShoes) do
                digShoesFound += 1
                local shoeName = item.Name or "Unknown Shoe"
                trackDugShoe(shoeName)

                Notify({
                    Title    = "Auto Dig - Shoe Found!",
                    Content  = "Found: " .. shoeName,
                    Duration = 5,
                    Image    = "Check",
                })

                local isGoldGrocs = shoeName == "Gold Grocs"

                safeSpawn(function()
                    sendDigWebhook(shoeName, State.selectedLevel, false)

                    if isGoldGrocs and getgenv().WebhookURL and getgenv().WebhookURL ~= "" then
                        local pingData = HttpService:JSONEncode({
                            content    = "@everyone  **GOLD GROCS FOUND** ",
                            username   = "SRS Auto Dig | by Sakura's Hub",
                            avatar_url = "https://i.imgur.com/NambJ9Q.gif",
                        })
                        pcall(function()
                            request({
                                Url     = getgenv().WebhookURL,
                                Method  = "POST",
                                Headers = { ["Content-Type"] = "application/json" },
                                Body    = pingData,
                            })
                        end)

                        local now2       = tick()
                        local elapsed    = digSessionStart and (now2 - digSessionStart) or 0
                        local moneyNow   = getMoney()
                        local moneySpent = Helpers.digSpend()

                        local embedData = HttpService:JSONEncode({
                            username   = "SRS Auto Dig | by Sakura's Hub",
                            avatar_url = "https://i.imgur.com/NambJ9Q.gif",
                            content    = "@everyone",
                            embeds = {{
                                title = " GOLD GROCS DUG UP — GRAIL FIND!",
                                description = table.concat({
                                    "",
                                    "**Shoe Found:** Gold Grocs",
                                    "**Rarity:** Grail ",
                                    "**Treasure Tier:** " .. State.selectedLevel,
                                    "**Dig Mode:** Walking",
                                    "**Session Time:** " .. formatUptime(elapsed),
                                    "**Money Spent Digging:** " .. fmtMoney(moneySpent),
                                    "**Money Remaining:** " .. fmtMoney(moneyNow),
                                    "**Shoes Dug This Session:** " .. tostring(digShoesFound),
                                    "",
                                    " **[Sakura's Socials](https://sakuras-hub.github.io/Sakuras-Hub/)**",
                                }, "\n") .. __L.buildDigSessionStats(),
                                color  = 0xFFD700,
                                footer = { text = "SRS V7 by Sakura's Hub" },
                                timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
                            }},
                        })
                        pcall(function()
                            request({
                                Url     = getgenv().WebhookURL,
                                Method  = "POST",
                                Headers = { ["Content-Type"] = "application/json" },
                                Body    = embedData,
                            })
                        end)
                    end
                end)
            end
        end
        deltaWait(digCfg.cycle)
    end
end

local TREASURE_LEVEL_MAP = {
    ["Level 1"]       = "Level1",
    ["Level 2"]       = "Level2",
    ["Level 3"]       = "Level3",
    ["Level 4"]       = "Level4",
    ["BLOX Treasure"] = "BLOXTreasure",
}

local TREASURE_INFO = {
    Level1      = { price = "$10.0K",  reward = "6x Common/Uncommon", color = "Default" },
    Level2      = { price = "$100.0K", reward = "5x Rare",            color = "Default" },
    Level3      = { price = "$1.0M",   reward = "5x Epic",            color = "Default" },
    Level4      = { price = "$10.0M",  reward = "4x Legendary",       color = "Default" },
    BLOXTreasure = { price = "$25.0M", reward = "5x BLOX Collab",     color = "Default" },
}

local SHOVEL_MAP = {
    ["Basic Shovel"]   = "Shovel",
    ["Garden Shovel"]  = "Garden Shovel",
    ["Kids Shovel"]    = "Kids Shovel",
    ["Diamond Shovel"] = "Diamond Shovel",
    ["Gold Shovel"]    = "Gold Shovel",
}

local SHOVEL_INFO = {
    ["Shovel"]         = { price = "Equipped", luck = "+0%",   desc = "Starter shovel" },
    ["Garden Shovel"]  = { price = "$100.0K",  luck = "+10%",  desc = "Garden Shovel" },
    ["Kids Shovel"]    = { price = "$1.0M",    luck = "+25%",  desc = "Kids Shovel" },
    ["Diamond Shovel"] = { price = "$10.0M",   luck = "+50%",  desc = "Diamond Shovel" },
    ["Gold Shovel"]    = { price = "$100.0M",  luck = "+100%", desc = "Gold Shovel" },
}

local selectedLevelLabel
AutoDigTab:CreateDropdown({
    Name = "Treasure Level",
    Options = {"Level 1", "Level 2", "Level 3", "Level 4", "BLOX Treasure"},
    Default = "Level 1",
    Flag = "ShovelLevel",
    Callback = function(option)
        local text = option[1] or option
        State.selectedLevel = TREASURE_LEVEL_MAP[text] or text:gsub(" ", "")
        local info = TREASURE_INFO[State.selectedLevel]
        if info and selectedLevelLabel then
            selectedLevelLabel:Set("Selected: " .. State.selectedLevel ..
                "\nPrice: " .. info.price ..
                "\nExpected: " .. info.reward)
        end
        Notify({ Title = "Treasure Level", Content = "Selected: " .. State.selectedLevel, Duration = 2, Image = "Check" })
    end,
})
selectedLevelLabel = createLabelShim(AutoDigTab, "Selected: Level1\nPrice: $10.0K\nExpected: 6x Common/Uncommon")

AutoDigTab:CreateButton({
    Name = "Buy Treasure",
    Callback = function()
        buyNewShovel()
        Notify({ Title = "Buy Treasure", Content = "Bought " .. State.selectedLevel, Duration = 2, Image = "Check" })
    end,
})

AutoDigTab:CreateSection("Shovel")

local selectedShovelLabel
local SHOVEL_OPTIONS = {"Basic Shovel", "Garden Shovel", "Kids Shovel", "Diamond Shovel", "Gold Shovel"}
local selectedShovelKey = "Shovel"
AutoDigTab:CreateDropdown({
    Name = "Shovel",
    Options = SHOVEL_OPTIONS,
    Default = "Basic Shovel",
    Flag = "DigShovel",
    Callback = function(option)
        local text = option[1] or option
        selectedShovelKey = SHOVEL_MAP[text] or text
        getgenv().FullAutoShovelKey = selectedShovelKey
        local info = SHOVEL_INFO[selectedShovelKey]
        if info and selectedShovelLabel then
            selectedShovelLabel:Set(selectedShovelKey .. "\nPrice: " .. info.price .. " | Luck: " .. info.luck)
        end
    end,
})
selectedShovelLabel = createLabelShim(AutoDigTab, "Shovel\nPrice: Equipped | Luck: +0%")

AutoDigTab:CreateButton({
    Name = "Buy Shovel",
    Callback = function()
        if selectedShovelKey == "Shovel" then
            Notify({ Title = "Buy Shovel", Content = "Already equipped!", Duration = 2, Image = "X" })
            return
        end
        pcall(function()
            game:GetService("ReplicatedStorage")
                :WaitForChild("RemoteEvents")
                :WaitForChild("BuyShovelEvent")
                :FireServer(selectedShovelKey)
        end)
        Notify({ Title = "Buy Shovel", Content = "Bought " .. selectedShovelKey, Duration = 2, Image = "Check" })
    end,
})

AutoDigTab:CreateSection("Auto Dig")

local riskFarmLoop

local function startWalkDig(speed)
    State.digSpeed = speed
    if State.farming then return end
    local hrp = getHRP()
    getgenv().DigAnchor = hrp and hrp.Position or nil
    digSessionStart  = tick()
    digMoneyAtStart  = getMoney()
    getgenv().SRS_DigSpentBase = getgenv().TotalMoneySpent or 0
    getgenv().SRS_DigSpentEnd  = nil
    digShoesFound    = 0
    State.farming    = true
    State.farmThread = task.spawn(farmLoop)
    Notify({ Title = "Auto Dig", Content = "Started (" .. speed .. ") with " .. State.selectedLevel, Duration = 2, Image = "Check" })
    safeSpawn(function()
        postWebhook("SRS Auto Dig | by Sakura's Hub", "Auto Dig Started",
            "**Mode:** Walking (" .. speed .. ")\n**Treasure Tier:** " .. State.selectedLevel ..
            "\n**Starting Money:** " .. fmtMoney(getMoney()) .. "\n")
    end)
end

local function stopWalkDig()
    if not State.farming then return end
    State.farming = false
    getgenv().DigAnchor = nil
    if State.farmThread then task.cancel(State.farmThread); State.farmThread = nil end
    local humanoid = getHumanoid()
    local hrp = getHRP()
    if humanoid and hrp then humanoid:MoveTo(hrp.Position) end
    local elapsed   = digSessionStart and math.floor(tick() - digSessionStart) or 0
    getgenv().SRS_DigSpentEnd = getgenv().TotalMoneySpent or 0
    local moneySpent = Helpers.digSpend()
    LogEvent("AutoDig", "Stopped dug=" .. tostring(digShoesFound) .. " elapsed=" .. elapsed)
    if elapsed > 0 then getgenv().DigTotalTime = (getgenv().DigTotalTime or 0) + elapsed end
    safeSpawn(function()
        postWebhook("SRS Auto Dig | by Sakura's Hub", "Auto Dig Stopped",
            "**Mode:** Walking\n**Session Time:** " .. formatUptime(elapsed) ..
            "\n**Money Spent Digging:** " .. fmtMoney(moneySpent) ..
            "\n**Money Remaining:** " .. fmtMoney(getMoney()) ..
            "\n**Total Shoes Dug:** " .. tostring(digShoesFound) .. "\n")
    end)
    Notify({ Title = "Auto Dig", Content = "Stopped.", Duration = 2, Image = "X" })
end

local function startRiskDig(speed)
    State.riskDigSpeed = speed
    if State.riskFarming then return end
    local hrp = getHRP()
    getgenv().DigAnchor = hrp and hrp.Position or nil
    digSessionStart      = tick()
    digMoneyAtStart      = getMoney()
    getgenv().SRS_DigSpentBase = getgenv().TotalMoneySpent or 0
    getgenv().SRS_DigSpentEnd  = nil
    digShoesFound        = 0
    State.riskFarming    = true
    State.riskFarmThread = task.spawn(riskFarmLoop)
    Notify({ Title = "Risky Auto Dig", Content = "Started (" .. speed .. ") with " .. State.selectedLevel, Duration = 2, Image = "Check" })
    safeSpawn(function()
        postWebhook("SRS Auto Dig | by Sakura's Hub", "Auto Dig Started",
            "**Mode:** Teleporting (Risky: " .. speed .. ")\n**Treasure Tier:** " .. State.selectedLevel ..
            "\n**Starting Money:** " .. fmtMoney(getMoney()) .. "\n")
    end)
end

local function stopRiskDig()
    if not State.riskFarming then return end
    State.riskFarming = false
    getgenv().DigAnchor = nil
    if State.riskFarmThread then task.cancel(State.riskFarmThread); State.riskFarmThread = nil end
    local elapsed    = digSessionStart and math.floor(tick() - digSessionStart) or 0
    getgenv().SRS_DigSpentEnd = getgenv().TotalMoneySpent or 0
    local moneySpent = Helpers.digSpend()
    LogEvent("RiskyAutoDig", "Stopped dug=" .. tostring(digShoesFound) .. " elapsed=" .. elapsed)
    if elapsed > 0 then getgenv().DigTotalTime = (getgenv().DigTotalTime or 0) + elapsed end
    safeSpawn(function()
        postWebhook("SRS Auto Dig | by Sakura's Hub", "Auto Dig Stopped",
            "**Mode:** Teleporting (Risky)\n**Session Time:** " .. formatUptime(elapsed) ..
            "\n**Money Spent Digging:** " .. fmtMoney(moneySpent) ..
            "\n**Money Remaining:** " .. fmtMoney(getMoney()) ..
            "\n**Total Shoes Dug:** " .. tostring(digShoesFound) .. "\n")
    end)
    Notify({ Title = "Risky Auto Dig", Content = "Stopped.", Duration = 2, Image = "X" })
end

local function makeDigSpeedToggle(which, speed, name, flag, risk, tab)
    tab = tab or AutoDigTab
    local toggle = tab:CreateToggle({
        Name = name, Default = false, Flag = flag,
        Callback = function(state)
            if state then
                cancelOtherAutomation(Toggles[which])
                if State.farming    and State.digSpeed    ~= speed then stopWalkDig()  end
                if State.riskFarming and State.riskDigSpeed ~= speed then stopRiskDig() end
                if risk then startRiskDig(speed) else startWalkDig(speed) end
            elseif risk then
                if State.riskDigSpeed == speed then stopRiskDig() end
            else
                if State.digSpeed == speed then stopWalkDig() end
            end
        end,
    })
    -- Dig toggles bypass the SubPages T() shim that aliases Set → SetValue, so
    -- mirror that here: game code (cancelOtherAutomation) calls Toggles.X:Set(false).
    if toggle.Set == nil and toggle.SetValue then toggle.Set = toggle.SetValue end
    Toggles[which] = toggle
end

AutoDigTab:CreateLabel("Slow: 9s dig window | 0.3s tool delay | 3.5s treasure wait | 0.3s between cycles")
makeDigSpeedToggle("SlowWalkDig", "slow", "Walking Auto Dig (Slow)", "SlowWalkDig", false)
AutoDigTab:CreateLabel("Medium: 8s dig window | 0.15s tool delay | 2.5s treasure wait | 0.15s between cycles")
makeDigSpeedToggle("MediumWalkDig", "medium", "Walking Auto Dig (Medium)", "MediumWalkDig", false)
AutoDigTab:CreateLabel("Fast: 6s dig window | 0.1s tool delay | 2s treasure wait | 0.1s between cycles")
makeDigSpeedToggle("FastWalkDig", "fast", "Walking Auto Dig (Fast)", "FastWalkDig", false)

-- ── Dig Dashboard page (own tab in the Auto Dig section) ──────────────────
SubPages:Register("Dig Dashboard", Tabs.DigDash, function(T, elements)
    -- Same grid dashboard as the main one (tiles + section cards). Older library
    -- copies without CreateDashboard fall back to the plain labels below.
    if type(Tabs.DigDash.CreateDashboard) == "function" then
        local okD, made = pcall(function()
            return Tabs.DigDash:CreateDashboard({ Title = "DIG DASHBOARD" })
        end)
        if okD and type(made) == "table" and type(made.Update) == "function" and made.Instance then
            PageRefs.digDash = made
            return
        end
        warn("[SRS][DigDashboard] CreateDashboard failed, using labels: " .. tostring(made))
    end
    T("CreateSection", "Dig Dashboard")

    PageRefs.digStatusLabel = T("CreateLabel", "Status: Idle")
    PageRefs.digRunningLabel = T("CreateLabel", "Mode: Idle")
    PageRefs.digTierLabel    = T("CreateLabel", "Tier: Level1")

    T("CreateSection", "This Session")
    PageRefs.digSessTimeLabel = T("CreateLabel", "Session Time: 0d 00h 00m 00s")
    PageRefs.digShoesLabel    = T("CreateLabel", "Shoes Dug: 0")
    PageRefs.digSpentLabel    = T("CreateLabel", "Money Spent: $0")
    PageRefs.digMoneyLabel    = T("CreateLabel", "Current Money: $0")

    T("CreateSection", "All Time")
    PageRefs.digTotalTimeLabel  = T("CreateLabel", "Total Dig Time: 0d 00h 00m 00s")
    PageRefs.digTotalShoesLabel = T("CreateLabel", "Total Shoes Dug: 0")
    PageRefs.digBoughtLabel     = T("CreateLabel", "Treasures Bought: 0")

    T("CreateSection", "Rarity Breakdown")
    PageRefs.digRarityLabel = T("CreateLabel",
        "Common: 0 | Uncommon: 0\nEpic: 0 | Legendary: 0\nLimited: 0 | Grail: 0")
end)

safeSpawn(function()
    while srsAlive() and not getgenv().ScriptShuttingDown do
        deltaWait(1)
        local running = State.farming or State.riskFarming
        local mode = "Idle"
        if State.riskFarming then mode = "Teleporting (Risky: " .. State.riskDigSpeed .. ")"
        elseif State.farming then mode = "Walking (" .. State.digSpeed .. ")"
        end
        local sessTime = running and digSessionStart and math.max(0, tick() - digSessionStart) or 0
        local spent    = Helpers.digSpend()
        local st       = getgenv().DigStats or {}
        local totalShoes = (st.Common or 0) + (st.Uncommon or 0) + (st.Epic or 0)
            + (st.Legendary or 0) + (st.Limited or 0) + (st.Grail or 0)

        if PageRefs.digDash then
            pcall(function()
                local dash = PageRefs.digDash
                if not dash.Instance or not dash.Instance.Parent then return end
                local function dur(sec)
                    return formatUptime(math.max(0, sec or 0))
                end
                local money = getMoney()
                dash:Update({
                    Title = "DIG DASHBOARD",
                    Badge = { Text = running and "RUNNING" or "IDLE", Color = running and "ok" or "idle" },
                    Active = running and mode or "",
                    Tiles = {
                        { Label = "Session", Value = dur(sessTime), Sub = running and "this dig session" or "not digging", Color = "idle" },
                        { Label = "Shoes Dug", Value = fmtNum(digShoesFound), Sub = "all-time " .. fmtNum(totalShoes), Color = "accent" },
                        { Label = "Dig Spend", Value = fmtMoney(spent), Sub = (digShoesFound or 0) > 0 and ("avg " .. fmtMoney(spent / digShoesFound) .. " per shoe") or "no shoes yet", Color = "bad" },
                        { Label = "Money", Value = fmtMoney(money), Sub = "current balance", Color = "ok" },
                    },
                    Sections = {
                        { Title = "STATUS", Rows = {
                            { Label = "Status", Value = running and "Running" or "Idle" },
                            { Label = "Mode", Value = mode },
                            { Label = "Tier", Value = tostring(State.selectedLevel or "Level1") },
                        } },
                        { Title = "ALL TIME", Rows = {
                            { Label = "Dig time", Value = dur(getgenv().DigTotalTime or 0) },
                            { Label = "Shoes dug", Value = fmtNum(totalShoes) },
                            { Label = "Treasures", Value = fmtNum(getgenv().TreasuresBought or 0) .. " bought" },
                        } },
                        { Title = "RARITY BREAKDOWN", Rows = {
                            { Label = "Common", Value = fmtNum(st.Common or 0) },
                            { Label = "Uncommon", Value = fmtNum(st.Uncommon or 0) },
                            { Label = "Epic", Value = fmtNum(st.Epic or 0) },
                            { Label = "Legendary", Value = fmtNum(st.Legendary or 0) },
                            { Label = "Limited", Value = fmtNum(st.Limited or 0) },
                            { Label = "Grail", Value = fmtNum(st.Grail or 0) },
                        } },
                    },
                })
            end)
        end
        if PageRefs.digStatusLabel then pcall(function() PageRefs.digStatusLabel:Set("Status: " .. (running and "Running" or "Idle")) end) end
        if PageRefs.digRunningLabel then pcall(function() PageRefs.digRunningLabel:Set("Mode: " .. mode) end) end
        if PageRefs.digTierLabel then pcall(function() PageRefs.digTierLabel:Set("Tier: " .. tostring(State.selectedLevel or "Level1")) end) end
        if PageRefs.digSessTimeLabel then pcall(function() PageRefs.digSessTimeLabel:Set("Session Time: " .. formatUptime(sessTime)) end) end
        if PageRefs.digShoesLabel then pcall(function() PageRefs.digShoesLabel:Set("Shoes Dug: " .. fmtNum(digShoesFound)) end) end
        if PageRefs.digSpentLabel then pcall(function() PageRefs.digSpentLabel:Set("Money Spent: " .. fmtMoney(spent)) end) end
        if PageRefs.digMoneyLabel then pcall(function() PageRefs.digMoneyLabel:Set("Current Money: " .. fmtMoney(getMoney())) end) end
        if PageRefs.digTotalTimeLabel then pcall(function() PageRefs.digTotalTimeLabel:Set("Total Dig Time: " .. formatUptime(getgenv().DigTotalTime or 0)) end) end
        if PageRefs.digTotalShoesLabel then pcall(function() PageRefs.digTotalShoesLabel:Set("Total Shoes Dug: " .. fmtNum(totalShoes)) end) end
        if PageRefs.digBoughtLabel then pcall(function() PageRefs.digBoughtLabel:Set("Treasures Bought: " .. fmtNum(getgenv().TreasuresBought or 0)) end) end
        if PageRefs.digRarityLabel then pcall(function() PageRefs.digRarityLabel:Set(string.format(
            "Common: %d | Uncommon: %d\nEpic: %d | Legendary: %d\nLimited: %d | Grail: %d",
            st.Common or 0, st.Uncommon or 0, st.Epic or 0, st.Legendary or 0, st.Limited or 0, st.Grail or 0)) end) end
    end
end)

local function getRiskHRP()
    local char = LocalPlayer.Character
    return char and char:FindFirstChild("HumanoidRootPart")
end

local function riskEquipShovel()
    local char = LocalPlayer.Character
    if not char then return false end
    if char:FindFirstChild("Shovel") then return true end
    local backpack = LocalPlayer:FindFirstChild("Backpack")
    local shovel = backpack and backpack:FindFirstChild("Shovel")
    if shovel then
        local hum = char:FindFirstChildOfClass("Humanoid")
        if hum then hum:EquipTool(shovel); deltaWait(0.3); return true end
    end
    return false
end

local function riskUseShovel()
    local char = LocalPlayer.Character
    if not char then return end
    local tool = char:FindFirstChild("Shovel")
    if tool then pcall(function() tool:Activate() end) end
end

local function teleportTo(part)
    local hrp = getRiskHRP()
    if hrp and part then hrp.CFrame = part.CFrame + Vector3.new(0, 3, 0) end
end

local function riskPressE()
    pcall(function()
        local VIM = game:GetService("VirtualInputManager")
        VIM:SendKeyEvent(true,  Enum.KeyCode.E, false, game)
        deltaWait(0.05)
        VIM:SendKeyEvent(false, Enum.KeyCode.E, false, game)
    end)
end

local function riskSpamE(duration)
    local deadline = tick() + duration
    while tick() < deadline and State.riskFarming do
        riskPressE(); deltaWait(0.1)
    end
end

local function riskBuyNewShovel()
    pcall(function()
        game:GetService("ReplicatedStorage")
            :WaitForChild("RemoteEvents")
            :WaitForChild("BuyTreasure")
            :FireServer(State.selectedLevel)
    end)
end

function riskFarmLoop()
    LogEvent("RiskyAutoDig", "Started")
    local riskCfg = __L.getDigCfg(State.riskDigSpeed)
    while State.riskFarming and srsAlive() do
        riskCfg = __L.getDigCfg(State.riskDigSpeed)
        local treasureFolder = workspace:FindFirstChild("TreasureFolder")
        if not treasureFolder then
            deltaWait(2)
            Notify({ Title = "Risky Auto Dig", Content = "TreasureFolder not found — wrong game?", Duration = 3, Image = "X" })
            continue
        end
        local sorted = getSortedTreasures(treasureFolder)
        if #sorted == 0 then
            riskBuyNewShovel()
            getgenv().TreasuresBought = (getgenv().TreasuresBought or 0) + 1
            local emptyWaitStart = tick()
            while tick() - emptyWaitStart < riskCfg.buyPoll do
                deltaWait(0.2)
                if #getSortedTreasures(treasureFolder) > 0 then break end
            end
            deltaWait(riskCfg.cycle)
            continue
        end
        for _, entry in ipairs(sorted) do
            if not State.riskFarming then break end
            if not entry.treasure.Parent then continue end
            teleportTo(entry.part); deltaWait(riskCfg.settle)
            if not State.riskFarming or not entry.treasure.Parent then break end
            riskEquipShovel(); deltaWait(riskCfg.tool)
            riskUseShovel();   deltaWait(riskCfg.tool)

            -- Snapshot BOTH folders before digging (track name->value so increments are detected)
            local invBefore_risk = {}
            local riskInv = LocalPlayer:FindFirstChild("Inventory")
            local _riskUnsell = riskInv and riskInv:FindFirstChild("UnsellableInventory")
            local _riskSell   = riskInv and riskInv:FindFirstChild("SellableInventory")
            if _riskUnsell then for _, item in ipairs(_riskUnsell:GetChildren()) do invBefore_risk[item.Name] = item.Value end end
            if _riskSell   then for _, item in ipairs(_riskSell:GetChildren())   do invBefore_risk[item.Name] = item.Value end end

            -- Grab dug shoes: press E until the item actually lands in inventory
            local riskNewShoes = grabDugShoes(riskCfg.grab, function() return State.riskFarming end, invBefore_risk, entry.treasure)
            -- Buy a new treasure only when the old one has been dug up
            if not entry.treasure.Parent then
                riskBuyNewShovel()
                getgenv().TreasuresBought = (getgenv().TreasuresBought or 0) + 1
                local riskWaitStart = tick()
                while tick() - riskWaitStart < riskCfg.buyPoll do
                    deltaWait(0.2)
                    if #getSortedTreasures(treasureFolder) > 0 then break end
                end
            end
            deltaWait(riskCfg.cycle)

            for _, item in ipairs(riskNewShoes) do
                invBefore_risk[item.Name] = item.Value
                digShoesFound += 1
                local shoeName = item.Name or "Unknown Shoe"
                trackDugShoe(shoeName)
                Notify({ Title = "Auto Dig - Shoe Found!", Content = "Found: " .. shoeName, Duration = 5, Image = "Check" })
                safeSpawn(function()
                    sendDigWebhook(shoeName, State.selectedLevel, true)
                end)
            end
        end
        deltaWait(riskCfg.cycle)
    end
end

-- Risky Auto Dig lives on the Risky tab (page "Risky Dig"). Its toggles are
-- rebuilt on every page switch like the other risky pages, so the stop path is
-- exposed on Helpers and cancelOtherAutomation() stops a running risky dig
-- directly instead of relying on a (possibly destroyed) toggle handle.
Helpers.stopRiskDig = stopRiskDig
SubPages:Register("Risky Dig", Tabs.Risky, function(T, elements)
    Helpers.riskyNav(T)
    T("CreateSection", "Risky Auto Dig")
    T("CreateLabel", "Teleports to treasures instead of walking. Faster than walking, bans reported on these speeds (see Info tab).")
    for _, def in ipairs({
        { "SlowRiskDig",   "risky_slow",   "Slow"   },
        { "MediumRiskDig", "risky_medium", "Medium" },
        { "FastRiskDig",   "risky_fast",   "Fast"   },
    }) do
        local which, speed, label = def[1], def[2], def[3]
        T("CreateLabel", ({
            risky_slow   = "Risky Slow: 6s dig window | 0.15s tool delay | 2s treasure wait | 0.15s between cycles",
            risky_medium = "Risky Medium: 5s dig window | 0.1s tool delay | 1.5s treasure wait | 0.1s between cycles",
            risky_fast   = "Risky Fast: 4s dig window | 0.06s tool delay | 1s treasure wait | 0.06s between cycles",
        })[speed])
        Toggles[which] = T("CreateToggle", {
            Name = "Teleporting Auto Dig (Risky " .. label .. ")", CurrentValue = false, Flag = which,
            Callback = function(state)
                if state then
                    cancelOtherAutomation(Toggles[which])
                    if State.farming then stopWalkDig() end
                    if State.riskFarming and State.riskDigSpeed ~= speed then stopRiskDig() end
                    startRiskDig(speed)
                elseif State.riskDigSpeed == speed then
                    stopRiskDig()
                end
            end,
        })
    end
end)

end -- runMainBodyPart1

function __L.runMainBodyPart2()

AutoDigTab:CreateToggle({
    Name = "Noclip (If You Keep Getting Stuck On Stuff)", Default = false, Flag = "NoclipToggle",
    Callback = function(Value)
        State.Noclip = Value
        if State.Noclip then __L.EnableNoclip() else __L.DisableNoclip() end
    end,
})

createLabelShim(AutoDigTab, "If You Have Any Issues Like Walking To The Wrong Place Etc Go To Misc And Serverhop If Still Not Working Restart The Game And Your Roblox Executors")

-- ── Anti-idle (gated by Stability tab's Anti-AFK toggle) ────────────────
LocalPlayer.Idled:Connect(function()
    if not srsAlive() then return end
    local st = getgenv().SRS_Stability or {}
    if st.antiAFK == false then return end
    pcall(function()
        VirtualUser:Button2Down(Vector2.new(0,0), Workspace.CurrentCamera.CFrame)
        task.wait()
        VirtualUser:Button2Up(Vector2.new(0,0), Workspace.CurrentCamera.CFrame)
    end)
end)

safeSpawn(function()
    while srsAlive() and not getgenv().ScriptShuttingDown do
        deltaWait(75)
        if getgenv().ScriptShuttingDown then break end
        local st = getgenv().SRS_Stability or {}
        if st.antiAFK == false then continue end
        pcall(function()
            VirtualUser:Button2Down(Vector2.new(0,0), Workspace.CurrentCamera.CFrame)
            task.wait()
            VirtualUser:Button2Up(Vector2.new(0,0), Workspace.CurrentCamera.CFrame)
        end)
    end
end)

-- ── Stats tab ──────────────────────────────────────────────────────────────

local lastFPSTime = tick()

RunService.RenderStepped:Connect(function()
    if not srsAlive() then return end
    State.frameCount += 1
end)

safeSpawn(function()
    while true do
        if not srsAlive() then return end
        deltaWait(1)
        local now   = tick()
        local delta = now - lastFPSTime
        State.currentFPS  = delta > 0 and math.floor(State.frameCount / delta) or 0
        State.frameCount  = 0
        lastFPSTime = now
    end
end)

safeSpawn(function()
    local StatsService = game:GetService("Stats")
    while srsAlive() do
        if PageRefs.uptimeLabel then pcall(function() PageRefs.uptimeLabel:Set("Uptime: " .. formatUptime(tick() - startTime)) end) end
        if PageRefs.fpsLabel then pcall(function() PageRefs.fpsLabel:Set("FPS: " .. tostring(State.currentFPS)) end) end
        local ok, ping = pcall(function()
            return StatsService.Network.ServerStatsItem["Data Ping"]:GetValueString()
        end)
        if PageRefs.pingLabel then pcall(function() PageRefs.pingLabel:Set("Ping: " .. (ok and ping or "N/A")) end) end
        deltaWait(1)
    end
end)

-- ══════════════════════════════════════════════════════════════════════════
-- ── Dashboard: ONE big live card (same design as Shoe Sniper v7) ──────────
-- The page is rebuilt on every visit, so the card publishes a refresh
-- function in PageRefs and ONE background loop (below) calls it each second.
-- ══════════════════════════════════════════════════════════════════════════
SubPages:Register("Dashboard", Tabs.Dashboard, function(T, elements)
    -- colours / text helpers -------------------------------------------------
    -- Matches SakuraUI's own palette (pink accent, TextDark labels).
    local C_DIM, C_OK, C_BAD, C_WARN = "#9e94c0", "#6edc8c", "#ff6b6b", "#ffd166"
    local function col(hex, s) return '<font color="' .. hex .. '">' .. tostring(s) .. '</font>' end
    local function esc(s) return (tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")) end
    -- The data lines below did not change: head() opens a new section card and
    -- row() becomes a label/value pair. add() assembles the dashboard model.
    local function head(t) return { __head = true, text = tostring(t) } end
    local function row(label, value) return { __row = true, label = tostring(label), value = tostring(value) } end
    local function strip(s)
        return (tostring(s):gsub("<[^>]+>", ""):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&amp;", "&"))
    end
    local function clean(t)
        local out = tostring(t or ""):gsub("[─━═]+", " "):gsub("%s+", " ")
        return (out:gsub("^%s+", ""):gsub("%s+$", ""))
    end
    local function rowText(label, value)
        local text = strip(value)
        if label == nil or label == "" then return "             " .. text end
        return string.format("%-13s", label) .. text
    end
    local function onoff(b) return b and col(C_OK, "ON") or col(C_DIM, "OFF") end
    local function signed(n)
        if n >= 0 then return col(C_OK, "+$" .. fmtNum(n)) end
        return col(C_BAD, "-$" .. fmtNum(math.abs(n)))
    end
    local function dur(sec)
        if not sec then return "never" end
        sec = math.max(0, math.floor(sec))
        if sec < 60 then return sec .. "s" end
        if sec < 3600 then return math.floor(sec / 60) .. "m " .. (sec % 60) .. "s" end
        if sec < 86400 then return math.floor(sec / 3600) .. "h " .. math.floor((sec % 3600) / 60) .. "m" end
        return math.floor(sec / 86400) .. "d " .. math.floor((sec % 86400) / 3600) .. "h"
    end

    -- Cycle watcher: Full Auto / PC Full Auto report their own phases. Every
    -- other mode (Auto Buy, PC Auto Buy, Auto Sell, Macro, Run Everything) is
    -- detected here so the Buy / Sell timer works with all of them.
    safeSpawn(function()
        while srsAlive() and not getgenv().ScriptShuttingDown do
            pcall(function()
                local C = getgenv().SRS_Cycle
                local hooked = getgenv().FullAutoRunning or getgenv().PCFullAutoRunning
                local M = Helpers.Macro
                if hooked then
                    C.full = true
                elseif M and M.Running then
                    C.full = true
                    Helpers.cyclePhase(M.selling and "sell" or "buy", (Helpers.budgetOn() and Helpers.budgetLeft()) or getMoney())
                elseif State.pcAutoBuyRunning or (Settings.Buy and Settings.Buy.Enabled) then
                    C.full = false
                    local lim = (Helpers.budgetOn() and Helpers.budgetLeft()) or getMoney()
                    Helpers.cyclePhase("buy", lim)
                elseif Settings.Sell then
                    C.full = false
                    Helpers.cyclePhase("sell")
                else
                    C.full = false
                    Helpers.cyclePhase("idle")
                end
                if C.phase == "buy" and not hooked then
                    C.spent = math.max(0, (getgenv().TotalMoneySpent or 0) - (C.spentBase or 0))
                elseif C.phase == "sell" then
                    local n = sellableInventoryCount()
                    if not C.sellTotal then C.sellTotal = n end
                    C.sellLeft = n
                end
            end)
            deltaWait(1)
        end
    end)

    local function buildModel()
        local up      = tick() - startTime
        local hours   = math.max(up / 3600, 1 / 3600)
        local money   = getMoney()
        local spent   = getgenv().TotalMoneySpent or 0
        local earned  = getgenv().TotalMoneyEarned or 0
        local net     = earned + (getgenv().PassiveIncome or 0) - spent
        local bought  = getgenv().ShoesBought or 0
        local sold    = getgenv().ShoesSold or 0
        local peak    = math.max(getgenv().SRS_PeakMoney or 0, money)
        getgenv().SRS_PeakMoney = peak
        local model = {
            Title = "SRS DASHBOARD",
            Badge = { Text = "IDLE", Color = "idle" },
            Active = "",
            Tiles = {},
            Sections = {},
            __title = false,
        }
        local pre = {}
        local function add(item)
            if type(item) == "table" and item.__head then
                model.Sections[#model.Sections + 1] = { Title = item.text, Rows = {} }
            elseif type(item) == "table" and item.__row then
                local section = model.Sections[#model.Sections]
                if section then
                    section.Rows[#section.Rows + 1] = { Label = item.label, Value = item.value }
                else
                    pre[#pre + 1] = item
                end
            elseif type(item) == "string" and model.__title ~= true then
                local plain = strip(item)
                if plain ~= "" then
                    model.__title = true
                    model.Title = clean(plain:gsub("%s*●.*$", ""))
                end
            end
        end

        -- active modes -----------------------------------------------------
        local modes = {}
        if getgenv().FullAutoRunning or State.fullAutoRunning then modes[#modes + 1] = "Full Auto (" .. tostring(getgenv().FullAutoSpeed or State.fullAutoSpeed) .. ")" end
        if State.pcAutoBuyRunning then modes[#modes + 1] = "PC Auto Buy (" .. tostring(State.pcAutoBuySpeed) .. ")" end
        if getgenv().PCFullAutoRunning or State.pcFullAutoRunning then modes[#modes + 1] = "PC Full Auto (" .. tostring(State.pcFullAutoSpeed) .. ")" end
        if State.shoeAppBuying then modes[#modes + 1] = "Shoe App" end
        if State.farming then modes[#modes + 1] = "Dig (" .. tostring(State.digSpeed) .. ")" end
        if State.riskFarming then modes[#modes + 1] = "Risky Dig (" .. tostring(State.riskDigSpeed) .. ")" end
        if Helpers.Macro and Helpers.Macro.Running then modes[#modes + 1] = "Macro" end
        local badgeText, badgeTone
        if #modes > 0 then badgeText, badgeTone = "RUNNING", "ok" else badgeText, badgeTone = "IDLE", "idle" end
        local badge = col(#modes > 0 and C_OK or C_DIM, "● " .. badgeText)
        add("<b>SRS  DASHBOARD</b>   " .. badge)
        add(row("Active", #modes > 0 and col(C_OK, esc(table.concat(modes, ", "))) or col(C_DIM, "nothing running")))
        add("")

        -- system -----------------------------------------------------------
        add(head("SYSTEM"))
        add(row("Uptime", formatUptime(up)))
        add(row("FPS / Ping", tostring(State.currentFPS or 0) .. " fps   /   " .. __L.getGamePing()))
        local plrs = game:GetService("Players")
        add(row("Server", #plrs:GetPlayers() .. "/" .. plrs.MaxPlayers .. " players   age " .. dur(workspace.DistributedGameTime)))
        add("")

        -- wallet -----------------------------------------------------------
        add(head("WALLET"))
        add(row("Money", fmtMoney(money) .. col(C_DIM, "   (peak " .. fmtMoney(peak) .. ")")))
        add(row("Spent", fmtMoney(spent)))
        add(row("Earned", fmtMoney(earned) .. col(C_DIM, "   from selling")))
        add(row("Passive", fmtMoney(getgenv().PassiveIncome or 0)))
        add(row("Net profit", signed(net) .. (up >= 60 and col(C_DIM, "   " .. (net >= 0 and "+" or "-") .. "$" .. fmtNum(math.abs(net / hours)) .. "/hr") or "")))
        do
            local goal = getgenv().SRS_MoneyGoal or 0
            if goal > 0 then
                local pct = math.min(100, math.floor(money / goal * 100))
                local eta
                if money >= goal then eta = col(C_OK, "reached")
                elseif up >= 120 and net > 0 then eta = "~" .. dur((goal - money) / (net / hours) * 3600)
                else eta = col(C_DIM, "measuring...") end
                add(row("Goal", fmtMoney(goal) .. col(C_DIM, "   " .. pct .. "%")))
                add(row("Goal ETA", eta))
            end
        end
        do
            local t = tonumber(getgenv().SRS_TargetBalance) or 0
            if getgenv().SRS_AutoStopAtTarget and t > 0 then
                local tp = math.min(100, math.floor(money / t * 100))
                local ts = money >= t and col(C_OK, "REACHED") or (money >= t * 0.8 and col(C_WARN, "NEAR") or col(C_DIM, "grinding"))
                add(row("Auto-Stop Target", fmtMoney(t) .. col(C_DIM, "   " .. tp .. "%   ") .. ts))
            end
        end
        add("")

        -- shoes ------------------------------------------------------------
        add(head("SHOES"))
        add(row("Bought", fmtNum(bought) .. (bought > 0 and col(C_DIM, "   avg spend " .. fmtMoney(spent / bought) .. "   " .. fmtNum(bought / hours) .. "/hr") or "")))
        add(row("Sold", fmtNum(sold) .. (sold > 0 and col(C_DIM, "   " .. fmtNum(sold / hours) .. "/hr") or "")))
        add(row("Rates", col(C_DIM, "$/hr " .. (net >= 0 and "+" or "-") .. "$" .. fmtNum(math.abs(net / hours)) .. "   |   Shoes/hr " .. fmtNum(bought / hours))))
        local rb = getgenv().ShoesRarityBought or {}
        add(row("By rarity", "Common " .. (rb.Common or 0) .. "  Uncommon " .. (rb.Uncommon or 0) .. "  Epic " .. (rb.Epic or 0)))
        add(row("", "Legendary " .. (rb.Legendary or 0) .. "  Limited " .. (rb.Limited or 0) .. "  Grail " .. (rb.Grail or 0)))
        add("")

        -- buy budget -------------------------------------------------------
        add(head("BUY BUDGET"))
        local bOn = Helpers.budgetOn()
        local snap = getgenv().SRS_BuyBudget
        if not bOn then
            add(row("Budget", col(C_DIM, "OFF (spends whatever is in your wallet)")))
        else
            local state
            if snap == nil then state = col(C_DIM, "waiting for a buy run")
            elseif Helpers.budgetExhausted() then state = col(C_WARN, "SPENT - selling / waiting for new snapshot")
            else state = col(C_OK, "ACTIVE") end
            add(row("Budget", state))
            add(row("Snapshot", snap and fmtMoney(snap) or "--"))
            add(row("Spent / Left", fmtMoney(getgenv().SRS_BuySpent or 0) .. " / " .. (snap and fmtMoney(Helpers.budgetLeft()) or "--")))
        end
        add("")

        -- halloween ---------------------------------------------------------
        add(head("HALLOWEEN"))
        do
            local candyAmt = 0
            if Helpers.candy then
                local okc, c = pcall(Helpers.candy)
                if okc and type(c) == "number" then candyAmt = c end
            end
            add(row("Candy", fmtNum(candyAmt)))
            local ready = false
            if Helpers.tradeInReady then
                local o, r = pcall(Helpers.tradeInReady)
                if o then ready = r and true or false end
            end
            add(row("Trade-In Ready", ready and col(C_OK, "YES") or col(C_DIM, "NO")))
            local cfgT = Settings.HalloweenTradeIn
            local hm = (cfgT and cfgT.Enabled) and true or false
            add(row("Auto Halloween", hm and col(C_OK, "ENABLED (after sell)") or col(C_DIM, "DISABLED")))
            if getgenv().SRS_HalloweenFromSell then
                add(row("Status", col(C_WARN, "ARMED - after sell")))
            elseif Helpers.halloweenRunning or Helpers.tradeInBusy then
                add(row("Status", col(C_OK, "RUNNING...")))
            end
        end
        add("")

        -- sell combo -------------------------------------------------------
        add(head("SELL COMBO"))
        local cs = getgenv().SellStats or { perfect = 0, good = 0, miss = 0, combo = 0, best = 0 }
        local tot = (cs.perfect or 0) + (cs.good or 0) + (cs.miss or 0)
        local rate = tot > 0 and string.format("%d%%", math.floor(cs.perfect / tot * 100 + 0.5)) or "--"
        add(row("Combo", (cs.combo or 0) .. col(C_DIM, "   best " .. (cs.best or 0))))
        add(row("Grades", "Perfect " .. (cs.perfect or 0) .. "  Good " .. (cs.good or 0) .. "  Miss " .. (cs.miss or 0)))
        add(row("Perfect rate", rate))
        add("")

        -- full auto cycle timer ----------------------------------------------
        add(head("BUY / SELL TIMER"))
        do
            local ci = Helpers.cycleInfo()
            local function est(v)
                if v == nil then return col(C_DIM, "measuring...") end
                if v <= 0 then return col(C_OK, "now") end
                return "~" .. dur(v)
            end
            local idle = ci.phase == "idle"
            local phaseText = col(C_DIM, "not running")
            if ci.phase == "buy" then phaseText = col(C_OK, "Buying")
            elseif ci.phase == "sell" then phaseText = col(C_OK, "Selling") end
            add(row("Phase", phaseText))
            if ci.full or idle then
                add(row("Sell phase in", idle and col(C_DIM, "--") or (ci.phase == "sell" and col(C_OK, "selling now") or est(ci.toSell))))
                add(row("Buy phase in", idle and col(C_DIM, "--") or (ci.phase == "buy" and col(C_OK, "buying now") or est(ci.toBuy))))
                add(row("Full loop", ci.loop and ("~" .. dur(ci.loop)) or col(C_DIM, "measuring... (first loop)")))
            elseif ci.phase == "buy" then
                add(row("Sell phase in", col(C_DIM, "this mode only buys")))
            else
                add(row("Buy phase in", col(C_DIM, "this mode only sells")))
            end
            local C = getgenv().SRS_Cycle
            add(row("Loops done", fmtNum(C and C.loops or 0)))
            if C and C.lastLoopProfit then
                local avg = C.loops > 0 and (C.profitSum / C.loops) or 0
                add(row("Last loop", signed(C.lastLoopProfit) .. col(C_DIM, "   avg ") .. signed(avg) .. col(C_DIM, "   best ") .. signed(C.bestLoopProfit or 0)))
            else
                add(row("Last loop", col(C_DIM, "after the first full loop")))
            end
            -- current speed timings
            local sk
            local Mc = Helpers.Macro
            if getgenv().FullAutoRunning then sk = getgenv().FullAutoSpeed
            elseif getgenv().PCFullAutoRunning then sk = State.pcFullAutoSpeed
            elseif State.pcAutoBuyRunning then sk = State.pcAutoBuySpeed
            elseif Mc and Mc.Running then sk = Mc.Speed
            elseif Settings.Buy and Settings.Buy.Enabled then sk = getgenv().SRS_LastBuySpeed end
            local sc = sk and SPEED_CONFIG[sk]
            if sc then
                add(row("Speed", esc(tostring(sk)) .. col(C_DIM, "   " .. sc.buyDelay .. "s buy | " .. sc.reloadDelay .. "s reload")))
            else
                add(row("Speed", col(C_DIM, "--")))
            end
        end
        add("")

        -- buy health ---------------------------------------------------------
        add(head("BUY HEALTH"))
        do
            local H = getgenv().SRS_Health or {}
            local pages = H.pages or 0
            local rate = pages > 0 and math.floor((H.okPages or 0) / pages * 100) or nil
            add(row("Pages", fmtNum(pages) .. col(C_DIM, "   bought on " .. fmtNum(H.okPages or 0) .. (rate and ("  (" .. rate .. "%)") or ""))))
            add(row("Rejected", fmtNum(H.rejected or 0) .. col(C_DIM, "   server errors " .. fmtNum(H.errors or 0))))
            add(row("Dry streak", (H.dry or 0) >= 3 and col(C_WARN, tostring(H.dry) .. " pages in a row") or tostring(H.dry or 0)))
        end
        add("")

        -- warnings (only shown when something needs attention) ---------------
        do
            local W = {}
            local H = getgenv().SRS_Health or {}
            local C = getgenv().SRS_Cycle
            local faOn = getgenv().FullAutoRunning or getgenv().PCFullAutoRunning
            if faOn and money < 1 and inventoryIsEmpty() then
                W[#W + 1] = "Broke with nothing to sell - waiting for income"
            end
            if (H.dry or 0) >= 3 then
                W[#W + 1] = "Shop not buying: " .. H.dry .. " pages in a row with no purchase"
            end
            if C and C.phase ~= "idle" then
                local el = tick() - (C.start or tick())
                local ref = (C.phase == "buy" and C.lastBuy) or (C.phase == "sell" and C.lastSell) or nil
                local limit = math.max(900, ref and ref * 3 or 0)
                if el > limit then
                    W[#W + 1] = (C.phase == "buy" and "Buy" or "Sell") .. " phase running long (" .. dur(el) .. ")"
                end
            end
            if #W > 0 then
                add(head("WARNINGS"))
                for _, w in ipairs(W) do add(row("!", col(C_WARN, esc(w)))) end
                add("")
            end
        end

        -- auto dig ---------------------------------------------------------
        add(head("AUTO DIG"))
        local digRunning = State.farming or State.riskFarming
        local digMode = "Idle"
        if State.riskFarming then digMode = "Teleporting (" .. tostring(State.riskDigSpeed) .. ")"
        elseif State.farming then digMode = "Walking (" .. tostring(State.digSpeed) .. ")" end
        local dst = getgenv().DigStats or {}
        local totalDug = (dst.Common or 0) + (dst.Uncommon or 0) + (dst.Epic or 0) + (dst.Legendary or 0) + (dst.Limited or 0) + (dst.Grail or 0)
        add(row("Status", (digRunning and col(C_OK, "Running") or col(C_DIM, "Idle")) .. "   " .. esc(digMode) .. "   tier " .. tostring(State.selectedLevel or "Level1")))
        add(row("This session", (digRunning and digSessionStart) and dur(tick() - digSessionStart) or "--"))
        add(row("Shoes dug", fmtNum(digShoesFound) .. col(C_DIM, "   all-time " .. fmtNum(totalDug))))
        add(row("Dig spend", fmtMoney(Helpers.digSpend())))
        add(row("Treasures", fmtNum(getgenv().TreasuresBought or 0) .. " bought   total dig time " .. dur(getgenv().DigTotalTime or 0)))
        add(row("Dug rarity", "Common " .. (dst.Common or 0) .. "  Uncommon " .. (dst.Uncommon or 0) .. "  Epic " .. (dst.Epic or 0)))
        add(row("", "Legendary " .. (dst.Legendary or 0) .. "  Limited " .. (dst.Limited or 0) .. "  Grail " .. (dst.Grail or 0)))
        add("")

        -- macro / upgrades -------------------------------------------------
        add(head("PC AUTO & UPGRADES"))
        local Mc = Helpers.Macro
        add(row("PC Auto", Mc and ((Mc.Running and col(C_OK, "running") or col(C_DIM, "idle")) .. "   " .. esc(tostring(Mc.status or ""))) or col(C_DIM, "not loaded")))
        local Up = Helpers.Upg
        add(row("Upgrades", Up and (esc(tostring(Up.status or "Idle")) .. col(C_DIM, "   clicks " .. fmtNum(Up.clicks or 0) .. "   bought " .. fmtNum(Up.bought or 0))) or col(C_DIM, "not loaded")))
        add("")

        -- stability / misc -------------------------------------------------
        add(head("STABILITY & MISC"))
        local st = getgenv().SRS_Stability or {}
        add(row("Protection", "anti-AFK " .. onoff(st.antiAFK) .. "   reconnect " .. onoff(st.autoReconnect) .. "   lag-watch " .. onoff(st.lagWatch)))
        add(row("Stall hop", st.stallWatch and (col(C_OK, "ON") .. col(C_DIM, "   after " .. tostring(st.stallMinutes or 10) .. " min idle")) or col(C_DIM, "OFF")))
        add(row("FPS cap", (st.fpsCap and st.fpsCap > 0) and tostring(st.fpsCap) or "unlimited"))
        add(row("Webhook", (getgenv().WebhookURL or "") ~= "" and col(C_OK, "set") or col(C_DIM, "not set")))
        add(row("Codes", esc(getgenv().SRS_CodesMsg or "idle")))

        -- Headline tiles. The matching rows above are removed from the section
        -- cards further down, so the text data itself stays exactly the same.
        model.Tiles = {
            { Label = "Uptime", Value = formatUptime(up), Sub = "this session", Color = "idle" },
            { Label = "Money", Value = fmtMoney(money), Sub = "peak " .. fmtMoney(peak), Color = "accent" },
            {
                Label = "Net Profit",
                Value = signed(net),
                Sub = up >= 60 and ((net >= 0 and "+" or "-") .. "$" .. fmtNum(math.abs(net / hours)) .. " per hour") or "since session start",
                Color = net >= 0 and "ok" or "bad",
            },
            {
                Label = "Bought / Sold",
                Value = fmtNum(bought) .. " / " .. fmtNum(sold),
                Sub = bought > 0 and ("avg spend " .. fmtMoney(spent / bought) .. " per shoe") or "no purchases yet",
                Color = "idle",
            },
        }
        local promoted = { Uptime = true, Money = true, ["Net profit"] = true, Bought = true, Sold = true }
        for _, section in ipairs(model.Sections) do
            local kept = {}
            for _, r in ipairs(section.Rows) do
                if not promoted[r.Label] then kept[#kept + 1] = r end
            end
            section.Rows = kept
        end
        for _, r in ipairs(pre) do
            if r.label == "Active" then model.Active = r.value end
        end
        model.Badge = { Text = badgeText, Color = badgeTone }
        model.__title = false
        return model
    end

    local function modelToText(m)
        local lines = {}
        local badge = (m.Badge and m.Badge.Text) or "IDLE"
        lines[#lines + 1] = tostring(m.Title or "SRS DASHBOARD") .. "   " .. tostring(badge)
        if m.Active and tostring(m.Active) ~= "" then
            lines[#lines + 1] = rowText("Active", m.Active)
        end
        lines[#lines + 1] = ""
        local tiles = m.Tiles or {}
        for _, t in ipairs(tiles) do
            local sub = (t.Sub and t.Sub ~= "") and ("   (" .. strip(t.Sub) .. ")") or ""
            lines[#lines + 1] = string.format("%-13s%s%s", t.Label, strip(t.Value), sub)
        end
        if #tiles > 0 then lines[#lines + 1] = "" end
        for _, section in ipairs(m.Sections or {}) do
            lines[#lines + 1] = "[" .. clean(section.Title) .. "]"
            for _, r in ipairs(section.Rows or {}) do
                lines[#lines + 1] = rowText(r.Label, r.Value)
            end
            lines[#lines + 1] = ""
        end
        return table.concat(lines, "\n")
    end

    -- Dashboard surface: prefer the library's CreateDashboard grid. Old
    -- GitHub copies have no such method, so the original text card is built
    -- as a fallback (never a silent blank page).
    local dash
    local body
    if type(Tabs.Dashboard.CreateDashboard) == "function" then
        local okDash, made = pcall(function()
            return Tabs.Dashboard:CreateDashboard({ Title = "SRS DASHBOARD" })
        end)
        if okDash and type(made) == "table" and type(made.Update) == "function" and made.Instance then
            dash = made
        else
            warn("[SRS][Dashboard] CreateDashboard failed, using the text card: " .. tostring(made))
        end
    end
    if not dash then
        local card = Instance.new("Frame")
        card.Name = "DashboardCard"
        card.BackgroundColor3 = Color3.fromRGB(23, 19, 38)
        card.BackgroundTransparency = 0.25
        card.BorderSizePixel = 0
        card.Size = UDim2.new(1, 0, 0, 0)
        card.AutomaticSize = Enum.AutomaticSize.Y
        do
            local uc = Instance.new("UICorner"); uc.CornerRadius = UDim.new(0, 8); uc.Parent = card
            local us = Instance.new("UIStroke"); us.Color = Color3.fromRGB(255, 95, 175); us.Transparency = 0.55; us.Thickness = 1; us.Parent = card
            local pad = Instance.new("UIPadding")
            pad.PaddingTop = UDim.new(0, 14); pad.PaddingBottom = UDim.new(0, 14)
            pad.PaddingLeft = UDim.new(0, 16); pad.PaddingRight = UDim.new(0, 16)
            pad.Parent = card
        end
        body = Instance.new("TextLabel")
        body.Name = "Body"
        body.BackgroundTransparency = 1
        body.Size = UDim2.new(1, 0, 0, 0)
        body.AutomaticSize = Enum.AutomaticSize.Y
        body.Font = Enum.Font.RobotoMono
        body.TextSize = 13
        body.RichText = true
        body.TextWrapped = true
        body.TextXAlignment = Enum.TextXAlignment.Left
        body.TextYAlignment = Enum.TextYAlignment.Top
        body.TextColor3 = Color3.fromRGB(232, 234, 246)
        body.Text = "loading..."
        body.Parent = card
        card.Parent = Tabs.Dashboard.content
    end

    local function refresh()
        if dash then
            if not dash.Instance or not dash.Instance.Parent then return end
        elseif body and not body.Parent then
            return
        end
        local okM, model = pcall(buildModel)
        if not okM then
            local msg = "Dashboard error: " .. tostring(model)
            if dash then
                dash:Update({
                    Title = "SRS DASHBOARD",
                    Badge = { Text = "ERROR", Color = "bad" },
                    Active = msg,
                    Tiles = {},
                    Sections = {},
                })
            elseif body then
                body.Text = msg
            end
            return
        end
        if dash then
            dash:Update(model)
        else
            body.Text = modelToText(model)
        end
    end
    refresh()
    PageRefs.dashRefresh = refresh
    PageRefs.dashBuildText = function()
        local okM, model = pcall(buildModel)
        return okM and modelToText(model) or ""
    end

    -- controls ---------------------------------------------------------------
    T("CreateSection", "Controls")

    T("CreateToggle", {
        Name = "In-Script Notifications",
        CurrentValue = true,
        Callback = function(state)
            getgenv().NotificationsEnabled = state
        end,
    })

    T("CreateButton", {
        Name = "Stop All Automation",
        Callback = function()
            pcall(cancelOtherAutomation, nil)
            Notify({ Title = "Stopped", Content = "Every automation was turned off.", Duration = 3, Image = "Check" })
        end,
    })

    T("CreateInput", {
        Name = "Money Goal (0 = off)",
        PlaceholderText = "e.g. 10000000",
        RemoveTextAfterFocusLost = false,
        Callback = function(text)
            local v = tonumber((tostring(text):gsub("[%s,$]", "")))
            getgenv().SRS_MoneyGoal = (v and v > 0) and v or 0
            if PageRefs.dashRefresh then pcall(PageRefs.dashRefresh) end
        end,
    })

    T("CreateButton", {
        Name = "Take New Buy-Budget Snapshot",
        Callback = function()
            Helpers.snapshotBudget("Dashboard")
        end,
    })

    T("CreateButton", {
        Name = "Reset Session Stats",
        Callback = function()
            getgenv().TotalMoneySpent     = 0
            getgenv().TotalMoneyEarned    = 0
            getgenv().ShoesBought         = 0
            getgenv().ShoesSold           = 0
            local rbr = getgenv().ShoesRarityBought
            if rbr then
                for k in pairs(rbr) do rbr[k] = 0 end
            end
            getgenv().PassiveIncome       = 0
            getgenv().ScriptIncomeWindow  = 0
            -- keep the dig-spend counter in step with the zeroed spend total
            if getgenv().SRS_DigSpentBase ~= nil then getgenv().SRS_DigSpentBase = 0 end
            if getgenv().SRS_DigSpentEnd  ~= nil then getgenv().SRS_DigSpentEnd  = 0 end
            getgenv().SellStats           = { perfect = 0, good = 0, miss = 0, combo = 0, best = 0 }
            Helpers.resetCycleStats()
            getgenv().MoneyAtSessionStart = getMoney()
            getgenv().SRS_PeakMoney       = getMoney()
            refresh()
            Notify({ Title = "Stats", Content = "Session stats have been reset.", Duration = 3, Image = "Check" })
        end,
    })

    T("CreateButton", {
        Name = "Copy Dashboard Snapshot",
        Callback = function()
            local okM, model = pcall(buildModel)
            if not okM then
                Notify({ Title = "Copy", Content = "Could not build the snapshot.", Duration = 3, Image = "X" })
                return
            end
            local plain = modelToText(model)
            pcall(function() setclipboard(plain) end)
            Notify({ Title = "Copied", Content = "Dashboard text copied to your clipboard.", Duration = 3, Image = "Check" })
        end,
    })

    T("CreateSection", "Tools")

    -- Server is case-sensitive and only accepts lowercase; secretsneaker is the
    -- hidden code (verified live Aug 2026).
    local CODES = { "bbence_27", "misumaki", "likes10k", "homie", "secretsneaker" }

    T("CreateButton", {
        Name = "Redeem All Codes",
        Callback = function()
            if getgenv().__SRS_CODES_RUNNING then
                RawNotify({ Title = "Codes", Content = "Already redeeming — wait for it to finish.", Duration = 3, Image = "Alert" })
                return
            end
            getgenv().__SRS_CODES_RUNNING = true
            local function status(txt) getgenv().SRS_CodesMsg = txt end
            safeSpawn(function()
                local okRun, errRun = pcall(function()
                    local rs = game:GetService("ReplicatedStorage")
                    local remotes = rs:FindFirstChild("RemoteEvents")
                    local redeem = remotes and remotes:FindFirstChild("RedeemCode")
                    if not redeem then
                        status("RedeemCode remote not found")
                        RawNotify({ Title = "Codes", Content = "RedeemCode remote not found — game updated?", Duration = 4, Image = "X" })
                        return
                    end
                    local okCount, invalidCount, usedCount, failCount = 0, 0, 0, 0
                    for idx, code in ipairs(CODES) do
                        if not srsAlive() then return end
                        status(string.format("redeeming %s (%d/%d)...", code, idx, #CODES))
                        Log("INFO", "[CODES] redeeming " .. code .. " (" .. idx .. "/" .. #CODES .. ")")
                        local done, worked, resp = false, false, nil
                        task.spawn(function()
                            worked = pcall(function() resp = redeem:InvokeServer(code) end)
                            done = true
                        end)
                        for _ = 1, 40 do
                            if done then break end
                            task.wait(0.25)
                        end
                        -- Server answers with a plain string: "invalid" (wrong code or
                        -- rate-limited), "alreadyRedeemed", or a success message.
                        local label, img
                        if not done then
                            failCount = failCount + 1
                            label, img = "no response (timed out)", "X"
                        elseif worked then
                            local r = tostring(resp or ""):lower()
                            if r:find("invalid") then
                                invalidCount = invalidCount + 1
                                label, img = "invalid", "X"
                            elseif r:find("already") or r:find("used") then
                                usedCount = usedCount + 1
                                label, img = "already redeemed", "Alert"
                            else
                                okCount = okCount + 1
                                label, img = "redeemed!", "Check"
                            end
                        else
                            failCount = failCount + 1
                            label, img = "rejected by server", "X"
                        end
                        warn("[CODES] " .. code .. " => " .. tostring(worked and resp or "REJECTED/TIMEOUT"))
                        status(string.format("%s - %s (%d/%d)", code, label, idx, #CODES))
                        RawNotify({ Title = "Code " .. code, Content = label, Duration = 3, Image = img })
                        -- 3s pacing: back-to-back codes trip the server's rate limit.
                        if idx < #CODES then task.wait(3) end
                    end
                    local summary = string.format("Redeemed %d, invalid %d, already used %d, failed %d.", okCount, invalidCount, usedCount, failCount)
                    status("done - " .. summary)
                    RawNotify({ Title = "Codes finished", Content = summary, Duration = 5, Image = "Check" })
                end)
                getgenv().__SRS_CODES_RUNNING = false
                if not okRun then
                    Log("ERROR", "[CODES] " .. tostring(errRun))
                    status("error - see Info > Script Logs")
                end
            end)
        end,
    })

    T("CreateButton", {
        Name = "Server Hop",
        Callback = function()
            loadstring(game:HttpGet("https://raw.githubusercontent.com/FaddedMarket/roblox-scripts/refs/heads/main/random%20scripts/serverhop.lua"))()
        end,
    })

    T("CreateButton", {
        Name = "Join Same Server",
        Callback = function()
            loadstring(game:HttpGet("https://raw.githubusercontent.com/FaddedMarket/roblox-scripts/refs/heads/main/random%20scripts/joinsameserver.lua"))()
        end,
    })

    T("CreateSection", "To Help More Turn Your Brightness All The Way Down")
    T("CreateButton", {
        Name = "Black Screen (To Help With Screen Burn When Afk)",
        Callback = function()
            local screenGui = Instance.new("ScreenGui")
            screenGui.Name = "BlackScreen"
            screenGui.ResetOnSpawn = false
            screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
            screenGui.DisplayOrder = 2147483647
            screenGui.IgnoreGuiInset = true
            screenGui.Parent = LocalPlayer:WaitForChild("PlayerGui")

            local frame = Instance.new("Frame")
            frame.Size = UDim2.new(1, 0, 1, 0)
            frame.Position = UDim2.new(0, 0, 0, 0)
            frame.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
            frame.BorderSizePixel = 0
            frame.ZIndex = 1
            frame.Parent = screenGui

            local closeButton = Instance.new("TextButton")
            closeButton.Size = UDim2.new(0, 28, 0, 28)
            closeButton.Position = UDim2.new(1, -36, 0, 8)
            closeButton.BackgroundColor3 = Color3.fromRGB(60, 60, 60)
            closeButton.BorderSizePixel = 0
            closeButton.Text = "X"
            closeButton.TextColor3 = Color3.fromRGB(255, 255, 255)
            closeButton.TextSize = 14
            closeButton.Font = Enum.Font.GothamBold
            closeButton.ZIndex = 2
            closeButton.Parent = frame

            local corner = Instance.new("UICorner")
            corner.CornerRadius = UDim.new(0, 6)
            corner.Parent = closeButton

            closeButton.MouseButton1Click:Connect(function()
                screenGui:Destroy()
            end)

            Notify({ Title = "Black Screen", Content = "Click the X in the top right to close.", Duration = 4, Image = "Check" })
        end,
    })
end)

-- One background loop refreshes whichever Dashboard card is currently built.
safeSpawn(function()
    while srsAlive() and not getgenv().ScriptShuttingDown do
        deltaWait(1)
        local f = PageRefs.dashRefresh
        if f then pcall(f) end
    end
end)

-- ── Stability sub-page (ported from "bad ass anti afk.lua") ───────────────
local stDefaults = {
    antiAFK              = true,
    autoReconnect        = true,
    lagWatch             = true,
    heartbeatThreshold   = 0.6,
    glitchCountThreshold = 3,
    autoAction           = "None", -- "None" | "Respawn" | "Rejoin"
    rejoinDelay          = 2,
    serverHop            = true,
    hopAfterSell         = false, -- hop servers after every sell cycle (OFF by default)
    fpsCap               = 60,   -- 15 | 30 | 60 | 90 | 120 | 0 (0 = unlimited)
    renderSaver          = true, -- throttle graphics when fully idle
    stallWatch           = true, -- no buys AND no sells for stallMinutes -> auto server hop
    stallMinutes         = 10,
    gcSweep              = false, -- incremental GC step every gcSeconds (full collect removed: it froze the client)
    gcSeconds            = 60,
}
getgenv().SRS_Stability = {} -- v4: always rebuilt from defaults (nothing restored from save or a previous run)
local stLive = getgenv().SRS_Stability
for k, v in pairs(stDefaults) do
    if stLive[k] == nil then stLive[k] = v end
end

-- Apply the persisted FPS cap (0 in the file means unlimited)
local fpstable = stLive.fpsCap
if fpstable and fpstable > 0 then
    pcall(function() setfpscap(fpstable) end)
elseif fpstable == 0 then
    pcall(function() setfpscap(0) end)
end

local function stabilityHttpGet(url)
    local ok, res = pcall(function() return request({ Url = url, Method = "GET" }) end)
    if ok and res and res.Body then return true, res.Body end
    if syn and syn.request then
        local ok2, res2 = pcall(function() return syn.request({ Url = url, Method = "GET" }) end)
        if ok2 and res2 and res2.Body then return true, res2.Body end
    end
    return false, nil
end

-- Hop to the least-filled public server; plain rejoin when serverHop is off
-- or the API call fails. Paginated: up to 5 pages of 100 servers each.
local function serverHopToLowest(placeId)
    local st = getgenv().SRS_Stability or {}
    local TS = game:GetService("TeleportService")
    if not st.serverHop then
        pcall(function() TS:Teleport(placeId, LocalPlayer) end)
        return
    end
    local cursor = ""
    for _ = 1, 5 do
        local url = ("https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Asc&limit=100%s")
            :format(placeId, #cursor > 0 and ("&cursor=" .. HttpService:UrlEncode(cursor)) or "")
        local ok, body = stabilityHttpGet(url)
        if not ok then
            pcall(function() TS:Teleport(placeId, LocalPlayer) end)
            return
        end
        local data
        pcall(function() data = HttpService:JSONDecode(body) end)
        if data and data.data then
            for _, srv in ipairs(data.data) do
                if srv.id and srv.id ~= game.JobId and srv.playing < srv.maxPlayers then
                    pcall(function() TS:TeleportToPlaceInstance(placeId, srv.id, LocalPlayer) end)
                    return
                end
            end
            cursor = data.nextPageCursor or ""
            if cursor == "" then break end
        else
            break
        end
    end
    pcall(function() TS:Teleport(placeId, LocalPlayer) end)
end

getgenv()._SRS_serverHop = serverHopToLowest

-- Auto-reconnect: the disconnect prompt appears in CoreGui's prompt overlay;
-- on ErrorPrompt rejoin the same place+job, plain teleport as fallback.
local stabilityReconnectConn
local function attachStabilityReconnect()
    if stabilityReconnectConn then stabilityReconnectConn:Disconnect(); stabilityReconnectConn = nil end
    pcall(function()
        local promptGui = game:GetService("CoreGui"):FindFirstChild("RobloxPromptGui") or game:GetService("CoreGui"):WaitForChild("RobloxPromptGui", 5)
        if not promptGui then return end
        local overlay = promptGui:FindFirstChild("promptOverlay") or promptGui:WaitForChild("promptOverlay", 5)
        if not overlay then return end
        stabilityReconnectConn = overlay.ChildAdded:Connect(function(obj)
            local st = getgenv().SRS_Stability
            if not st or not st.autoReconnect then return end
            if obj.Name == "ErrorPrompt" then
                warn("[STAB] disconnect detected -> auto rejoin")
                local placeId, jobId = game.PlaceId, game.JobId
                task.delay(0.2, function()
                    pcall(function() game:GetService("TeleportService"):TeleportToPlaceInstance(placeId, jobId, LocalPlayer) end)
                    task.delay(1.0, function()
                        pcall(function() game:GetService("TeleportService"):Teleport(placeId, LocalPlayer) end)
                    end)
                end)
            end
        end)
    end)
end
attachStabilityReconnect()

-- Lag watchdog: a heartbeat that takes longer than the threshold is a
-- glitch; after the glitch cap, run the configured auto-action.
task.spawn(function()
    local glitchCount = 0
    while srsAlive() and not getgenv().ScriptShuttingDown do
        local st = getgenv().SRS_Stability
        local t1 = tick()
        task.wait(1.0)
        local d = (tick() - t1) - 1.0 -- overshoot only (the wait itself is 1s)
        if st and st.lagWatch then
            if d > (st.heartbeatThreshold or 0.6) then
                glitchCount += 1
            else
                glitchCount = math.max(0, glitchCount - 1)
            end
            if glitchCount >= (st.glitchCountThreshold or 3) then
                if st.autoAction == "Respawn" then
                    task.delay(st.rejoinDelay or 2, function() pcall(function() LocalPlayer:LoadCharacter() end) end)
                elseif st.autoAction == "Rejoin" then
                    task.delay(st.rejoinDelay or 2, function() serverHopToLowest(game.PlaceId) end)
                end
                glitchCount = 0
            end
        end
        if PageRefs.stabilityStatusLabel then
            pcall(function()
                PageRefs.stabilityStatusLabel:Set(("AntiAFK:%s AutoRejoin:%s LagWatch:%s Glitch:%d")
                    :format((st and st.antiAFK ~= false) and "ON" or "OFF",
                        (st and st.autoReconnect ~= false) and "ON" or "OFF",
                        (st and st.lagWatch ~= false) and "ON" or "OFF", glitchCount))
            end)
        end
    end
end)

-- Stall watchdog: if buy/sell counters freeze for stallMinutes while
-- automation is supposed to be running, server-hop to shake the session.
task.spawn(function()
    local lastBought = getgenv().ShoesBought or 0
    local lastSold   = getgenv().ShoesSold   or 0
    local lastMove   = tick()
    while srsAlive() and not getgenv().ScriptShuttingDown do
        local st = getgenv().SRS_Stability
        if st and st.stallWatch ~= false then
            local anyRunning = getgenv().FullAutoRunning or getgenv().PCFullAutoRunning
                or Settings.Sell or Settings.Buy.Enabled
            local b = getgenv().ShoesBought or 0
            local s = getgenv().ShoesSold or 0
            if anyRunning then
                if b ~= lastBought or s ~= lastSold then
                    lastBought, lastSold, lastMove = b, s, tick()
                elseif (tick() - lastMove) >= (st.stallMinutes or 10) * 60 then
                    Notify({ Title = "Stall Watchdog", Content = "No progress in " .. (st.stallMinutes or 10) .. " min — server hopping.", Duration = 5, Image = "Alert" })
                    serverHopToLowest(game.PlaceId)
                    lastMove = tick()
                end
            else
                lastBought, lastSold, lastMove = b, s, tick()
            end
        end
        task.wait(30)
    end
end)

-- Memory sweep: run collectgarbage on an interval to hold memory down.
task.spawn(function()
    while srsAlive() and not getgenv().ScriptShuttingDown do
        local st = getgenv().SRS_Stability
        task.wait(st and st.gcSweep ~= false and (st.gcSeconds or 30) or 60)
        if st and st.gcSweep ~= false then
            pcall(function() collectgarbage("step", 200) end)
        end
    end
end)

-- Render saver: when nothing is running, drop to a low FPS cap to relieve
-- the GPU; restore the user's cap the moment automation takes over.
task.spawn(function()
    while srsAlive() and not getgenv().ScriptShuttingDown do
        local st = getgenv().SRS_Stability
        if st and st.renderSaver ~= false and setfpscap then
            local anyRunning = getgenv().FullAutoRunning or getgenv().PCFullAutoRunning
                or Settings.Sell or Settings.Buy.Enabled or State.farming or State.riskFarming
                or State.pcAutoBuyRunning or State.shoeAppBuying
            local userCap = st.fpsCap and st.fpsCap > 0 and st.fpsCap or 60
            local wantCap = anyRunning and userCap or math.min(userCap, 30)
            if getgenv().SRS_LastFpsCap ~= wantCap then
                getgenv().SRS_LastFpsCap = wantCap
                pcall(setfpscap, wantCap)
            end
        end
        task.wait(5)
    end
end)

SubPages:Register("Stability", Tabs.Stability, function(T, elements)
    T("CreateSection", "Stability")
    T("CreateLabel", "Anti-AFK: sends a tiny click every 2 minutes so Roblox never idles you out. Auto-Reconnect: rejoins the same server if the disconnect prompt appears.")
    T("CreateLabel", "Lag Watchdog: counts frames that take longer than the threshold; after 3 in a row it runs the Lag Auto-Action (None / Respawn / Rejoin).")
    T("CreateLabel", "Stall Watchdog: if nothing is bought or sold for the chosen minutes while an automation is on, it server hops to unstick the session.")
    T("CreateLabel", "Server Hop After Sell: hops to a fresh server after every sell cycle. Hop To Low-Pop: choose the emptiest public server instead of a plain rejoin.")
    T("CreateLabel", "Re-injecting the script always starts with every toggle OFF. Render Saver: drops FPS while idle to cool the GPU.")
    local st = getgenv().SRS_Stability or {}

    PageRefs.stabilityStatusLabel = T("CreateLabel", "AntiAFK:ON AutoRejoin:ON LagWatch:ON Glitch:0")

    T("CreateToggle", {
        Name = "Anti-AFK (Idle Protection)",
        Default = st.antiAFK ~= false,
        Flag = "StabAntiAFK",
        Callback = function(Value)
            getgenv().SRS_Stability.antiAFK = Value
            saveSettings()
        end,
    })
    T("CreateToggle", {
        Name = "Auto-Reconnect",
        Default = st.autoReconnect ~= false,
        Flag = "StabAutoReconnect",
        Callback = function(Value)
            getgenv().SRS_Stability.autoReconnect = Value
            saveSettings()
        end,
    })
    T("CreateToggle", {
        Name = "Lag Watchdog",
        Default = st.lagWatch ~= false,
        Flag = "StabLagWatch",
        Callback = function(Value)
            getgenv().SRS_Stability.lagWatch = Value
            saveSettings()
        end,
    })
    T("CreateDropdown", {
        Name = "Lag Auto-Action",
        Options = { "None", "Respawn", "Rejoin" },
        Default = st.autoAction or "None",
        Flag = "StabAutoAction",
        Callback = function(option)
            local text = option[1] or option
            getgenv().SRS_Stability.autoAction = text
            saveSettings()
        end,
    })
    T("CreateInput", {
        Name = "Lag Threshold (seconds)",
        PlaceholderText = "0.6",
        RemoveTextAfterFocusLost = false,
        Callback = function(text)
            local v = tonumber(text)
            if v and v > 0 then getgenv().SRS_Stability.heartbeatThreshold = v; saveSettings() end
        end,
    })
    T("CreateInput", {
        Name = "Rejoin Delay (seconds)",
        PlaceholderText = "2",
        RemoveTextAfterFocusLost = false,
        Callback = function(text)
            local v = tonumber(text)
            if v and v >= 0 then getgenv().SRS_Stability.rejoinDelay = v; saveSettings() end
        end,
    })
    T("CreateButton", {
        Name = "Respawn Now",
        Callback = function()
            local d = getgenv().SRS_Stability.rejoinDelay or 2
            task.delay(d, function() pcall(function() LocalPlayer:LoadCharacter() end) end)
        end,
    })
    T("CreateButton", {
        Name = "Server Hop Now",
        Callback = function()
            serverHopToLowest(game.PlaceId)
        end,
    })
    T("CreateToggle", {
        Name = "Hop To Low-Pop Server (off = plain rejoin)",
        Default = st.serverHop ~= false,
        Flag = "StabServerHop",
        Callback = function(Value)
            getgenv().SRS_Stability.serverHop = Value
            saveSettings()
        end,
    })
    T("CreateToggle", {
        Name = "Server Hop After Every Sell Cycle",
        Default = st.hopAfterSell == true,
        Flag = "StabHopAfterSell",
        Callback = function(Value)
            getgenv().SRS_Stability.hopAfterSell = Value
            saveSettings()
        end,
    })
    T("CreateDropdown", {
        Name = "FPS Cap",
        Options = { "60", "30", "15", "90", "120", "0 (unlimited)" },
        Default = (st.fpsCap == 0) and "0 (unlimited)" or tostring(st.fpsCap or 60),
        Flag = "StabFpsCap",
        Callback = function(option)
            local text = option[1] or option
            local v = tonumber(text:match("%d+"))
            getgenv().SRS_Stability.fpsCap = v or 60
            saveSettings()
            pcall(function() setfpscap(v or 60) end)
        end,
    })
    T("CreateToggle", {
        Name = "Render Saver (idle GPU relief)",
        Default = st.renderSaver ~= false,
        Flag = "StabRenderSaver",
        Callback = function(Value)
            getgenv().SRS_Stability.renderSaver = Value
            saveSettings()
        end,
    })
    T("CreateToggle", {
        Name = "Stall Watchdog (hop if idle)",
        Default = st.stallWatch ~= false,
        Flag = "StabStallWatch",
        Callback = function(Value)
            getgenv().SRS_Stability.stallWatch = Value
            saveSettings()
        end,
    })
    T("CreateInput", {
        Name = "Stall Minutes (no buys/sells)",
        PlaceholderText = "10",
        RemoveTextAfterFocusLost = false,
        Callback = function(text)
            local v = tonumber(text)
            if v and v > 0 then getgenv().SRS_Stability.stallMinutes = v; saveSettings() end
        end,
    })
    T("CreateToggle", {
        Name = "Memory Sweep (GC)",
        Default = st.gcSweep ~= false,
        Flag = "StabGcSweep",
        Callback = function(Value)
            getgenv().SRS_Stability.gcSweep = Value
            saveSettings()
        end,
    })
end)

end -- runMainBodyPart2

function __L.runMainBodyPart3()

-- ── Webhook helpers ───────────────────────────────────────────────────────
local function getWebhookDisplayText()
    local url = getgenv().WebhookURL
    if not url or url == "" then return "Loaded Webhook: None" end
    if #url > 40 then return "Loaded Webhook: " .. url:sub(1, 40) .. "..." end
    return "Loaded Webhook: " .. url
end

-- ── Webhook Alerts sub-page ──────────────────────────────────────────────
SubPages:Register("Webhook", Tabs.Webhook, function(T, elements)
    T("CreateSection", "Webhook")
    T("CreateLabel", "Paste a Discord webhook URL to get cycle summaries, shoe purchases, dig finds and crash/health alerts. Use Test Webhook after saving. Each alert type can be switched off below.")

    PageRefs.webhookStatusLabel = T("CreateLabel", getWebhookDisplayText())

    T("CreateInput", {
        Name                     = "Webhook URL",
        PlaceholderText          = "Paste your Discord webhook URL here",
        RemoveTextAfterFocusLost = false,
        Callback = function(text)
            if text and text ~= "" then
                getgenv().WebhookURL = text
                saveSettings()
                if PageRefs.webhookStatusLabel then pcall(function() PageRefs.webhookStatusLabel:Set(getWebhookDisplayText()) end) end
                RawNotify({ Title = "Webhook Set", Content = "Discord webhook URL saved!", Duration = 3, Image = "Check" })
            end
        end,
    })

    T("CreateButton", {
        Name = "Save Webhook URL",
        Callback = function()
            if not getgenv().WebhookURL or getgenv().WebhookURL == "" then
                RawNotify({ Title = "Webhook", Content = "No webhook URL entered yet!", Duration = 4, Image = "X" })
                return
            end
            saveSettings()
            if PageRefs.webhookStatusLabel then pcall(function() PageRefs.webhookStatusLabel:Set(getWebhookDisplayText()) end) end
            RawNotify({ Title = "Webhook Saved", Content = "Webhook URL has been saved!", Duration = 3, Image = "Check" })
        end,
    })

    T("CreateButton", {
        Name = "Test Webhook",
        Callback = function()
            if not getgenv().WebhookURL or getgenv().WebhookURL == "" then
                RawNotify({ Title = "Webhook", Content = "No webhook URL set!", Duration = 4, Image = "X" })
                return
            end
            safeSpawn(function()
                __L.sendCrashWebhook("Test Webhook", "Webhook is working! All enabled detections will send here.")
            end)
            RawNotify({ Title = "Webhook", Content = "Test message sent!", Duration = 3, Image = "Check" })
        end,
    })

    T("CreateSection", "Master Control")

    T("CreateButton", {
        Name = "Enable All Detections",
        Callback = function()
            for k in pairs(getgenv().DetectionToggles) do getgenv().DetectionToggles[k] = true end
            RawNotify({ Title = "Detections", Content = "All detections enabled.", Duration = 3, Image = "Check" })
        end,
    })

    T("CreateButton", {
        Name = "Disable All Detections",
        Callback = function()
            for k in pairs(getgenv().DetectionToggles) do getgenv().DetectionToggles[k] = false end
            RawNotify({ Title = "Detections", Content = "All detections disabled.", Duration = 3, Image = "X" })
        end,
    })

    T("CreateSection", "Critical Alerts")
    T("CreateToggle", { Name = "Game Close / Kicked",          CurrentValue = true, Flag = "Det_GameClose",        Callback = function(s) getgenv().DetectionToggles.GameClose = s end })
    T("CreateToggle", { Name = "Network Disconnect",           CurrentValue = true, Flag = "Det_NetworkDisconnect", Callback = function(s) getgenv().DetectionToggles.NetworkDisconnect = s end })
    T("CreateToggle", { Name = "Heartbeat Timeout",            CurrentValue = true, Flag = "Det_HeartbeatTimeout",  Callback = function(s) getgenv().DetectionToggles.HeartbeatTimeout = s end })
    T("CreateToggle", { Name = "Remote Event Failing",         CurrentValue = true, Flag = "Det_RemoteFail",        Callback = function(s) getgenv().DetectionToggles.RemoteFail = s end })
    T("CreateToggle", { Name = "Leaderstats Wiped",            CurrentValue = true, Flag = "Det_LeaderstatWipe",    Callback = function(s) getgenv().DetectionToggles.LeaderstatWipe = s end })
    T("CreateToggle", { Name = "Inventory Anomaly",            CurrentValue = true, Flag = "Det_InventoryAnomaly",  Callback = function(s) getgenv().DetectionToggles.InventoryAnomaly = s end })
    T("CreateToggle", { Name = "GUI Missing",                  CurrentValue = true, Flag = "Det_GUIMissing",        Callback = function(s) getgenv().DetectionToggles.GUIMissing = s end })

    T("CreateSection", "Performance Alerts")
    T("CreateToggle", { Name = "Critical FPS Drop (below 10)", CurrentValue = true, Flag = "Det_FPSDrop",   Callback = function(s) getgenv().DetectionToggles.FPSDrop = s end })
    T("CreateToggle", { Name = "Ping Spike (above 2000ms)",    CurrentValue = true, Flag = "Det_PingSpike", Callback = function(s) getgenv().DetectionToggles.PingSpike = s end })

    T("CreateSection", "Bot Health Alerts")
    T("CreateToggle", { Name = "Automation Stalled",           CurrentValue = true, Flag = "Det_AutoStall",      Callback = function(s) getgenv().DetectionToggles.AutoStall = s end })
    T("CreateToggle", { Name = "Money Not Changing",           CurrentValue = true, Flag = "Det_MoneyStuck",     Callback = function(s) getgenv().DetectionToggles.MoneyStuck = s end })
    T("CreateToggle", { Name = "Executor Functions Missing",   CurrentValue = true, Flag = "Det_ExecutorHealth", Callback = function(s) getgenv().DetectionToggles.ExecutorHealth = s end })
    T("CreateToggle", { Name = "Script Error",                 CurrentValue = true, Flag = "Det_ScriptError",   Callback = function(s) getgenv().DetectionToggles.ScriptError = s end })

    T("CreateSection", "Alive Ping")
    T("CreateToggle", { Name = "Alive Ping (periodic check-in)", CurrentValue = true, Flag = "Det_AlivePing", Callback = function(s) getgenv().DetectionToggles.AlivePing = s end })

    T("CreateSection", "Alive Ping Settings")
    T("CreateSlider", {
        Name = "Alive Ping Interval (minutes)", Range = {5, 120}, Increment = 5,
        Suffix = "min", CurrentValue = 60, Flag = "AlivePingInterval",
        Callback = function(value)
            State.alivePingMinutes = value
        end,
    })

    T("CreateSection", "Periodic Stats Webhook")

    T("CreateSlider", {
        Name = "Stats Interval (minutes)", Range = {1, 60}, Increment = 1,
        Suffix = "min", CurrentValue = 10, Flag = "PeriodicStatsInterval",
        Callback = function(value) State.periodicIntervalMinutes = value end,
    })

    T("CreateToggle", {
        Name = "Periodic Stats Webhook", CurrentValue = false, Flag = "PeriodicStatsToggle",
        Callback = function(state)
            State.periodicStatsRunning = state
            if state then
                if not getgenv().WebhookURL or getgenv().WebhookURL == "" then
                    RawNotify({ Title = "Periodic Stats", Content = "No webhook URL set!", Duration = 4, Image = "X" })
                    State.periodicStatsRunning = false; return
                end
                RawNotify({ Title = "Periodic Stats", Content = "Sending stats every " .. tostring(State.periodicIntervalMinutes) .. " minute(s).", Duration = 3, Image = "Check" })
                State.periodicStatsThread = task.spawn(function()
                    while State.periodicStatsRunning and srsAlive() do
                        deltaWait(State.periodicIntervalMinutes * 60)
                        if not State.periodicStatsRunning then break end
                        safeSpawn(__L.sendPeriodicStats)
                    end
                end)
            else
                if State.periodicStatsThread then task.cancel(State.periodicStatsThread); State.periodicStatsThread = nil end
                RawNotify({ Title = "Periodic Stats", Content = "Periodic stats stopped.", Duration = 3, Image = "X" })
            end
        end,
    })
end)

-- ── Shoe App sub-page ───────────────────────────────────────────────────────
SubPages:Register("Shoe App", Tabs.ShoeApp, function(T, elements)
    T("CreateSection", "Shoe App")
    T("CreateLabel", "Snipes limited phone drops. At release time it fires the game's own BuyShoesApp remote directly (the exact call the Buy button makes) for zero-latency buying, and only falls back to opening the phone + Shoes app + real mouse clicks if the remote is unavailable.")
    T("CreateLabel", "Zero-delay spam buying. Buys as many as possible before the window closes.")
    T("CreateLabel", "FAIL SYSTEM: 15 remote errors in a row = give up + webhook. Plain fails = keep going.")

    local shoeAppStatusLabel = T("CreateLabel", "Status: Idle")
    local shoeAppBoughtLabel = T("CreateLabel", "Bought this session: 0")

T("CreateToggle", {
    Name         = "Auto Buy Shoe App",
    CurrentValue = false,
    Flag         = "ShoeAppAutoBuy",
    Callback = function(state)
        State.shoeAppBuying = state

        if state then
            Notify({
                Title    = "Shoe App",
                Content  = "Standalone buyer started! Watching for drops...",
                Duration = 4,
                Image    = "Check",
            })
            safeSetLabel(shoeAppStatusLabel, "Status: Running - watching for drops...")

            State.shoeAppThread = task.spawn(function()
                while State.shoeAppBuying and srsAlive() do
                    local data = __L.getShoeAppData()

                    if not data then
                        safeSetLabel(shoeAppStatusLabel, "Status: Failed to fetch data - retrying in 5s...")
                        deltaWait(5)
                        continue
                    end

                    local entries   = (data[1] ~= nil) and data or { data }
                    local now       = os.time()
                    local anyActive = false
                    local nextName, nextLeft = nil, nil

                    for _, entry in ipairs(entries) do
                        if not State.shoeAppBuying then break end

                        local parsed = __L.parseShoeEntry(entry)
                        if not parsed then continue end

                        local secondsLeft = parsed.release and (parsed.release - now) or 0
                        -- Track the soonest upcoming drop so the panel always
                        -- shows exactly what is being armed, even hours ahead.
                        if parsed.release then
                            local rel = parsed.release - now
                            if rel > 0 and (nextLeft == nil or rel < nextLeft) then
                                nextName, nextLeft = parsed.name, rel
                            end
                        end
                        -- Live-verified: the server returns past drops too (the Air
                        -- Bogdan 4 Tour Yellow entry from 4 days ago), but their
                        -- cards are gone from the UI. Negative beyond the keep-alive
                        -- window means sold-out/expired — skip just like the Full
                        -- Auto loop does, or the loop hammers a dead drop forever.
                        if secondsLeft > SHOE_ARM_SECONDS or secondsLeft < -SHOE_DROP_WINDOW then continue end

                        anyActive = true

                        if secondsLeft > 0 then
                            safeSetLabel(shoeAppStatusLabel,
                                "Status: " .. parsed.name .. " in " .. math.floor(secondsLeft) .. "s...")
                            Notify({
                                Title    = "Shoe App - Drop Incoming",
                                Content  = parsed.name .. " drops in " .. math.floor(secondsLeft) .. "s!",
                                Duration = 5,
                                Image    = "Check",
                            })
                        else
                            safeSetLabel(shoeAppStatusLabel, "Status: Hammering " .. parsed.name .. "...")
                            Notify({
                                Title    = "Shoe App - Buying Now",
                                Content  = "Hammering " .. parsed.name .. " - zero delay!",
                                Duration = 3,
                                Image    = "Check",
                            })
                        end

                        local GRACE_SECONDS = SHOE_DROP_WINDOW
                        local deadline      = tick() + math.max(secondsLeft, 0) + GRACE_SECONDS
                        local errorCount    = 0
                        local MAX_ERRORS    = 15
                        local totalBought   = 0

                        while State.shoeAppBuying and srsAlive() and tick() < deadline do
                            local result, spent = attemptShoeAppBuy(parsed.sn or parsed.name, shoeBuyMinMoney(parsed.price))

                            if result == "success" then
                                totalBought                  += 1
                                errorCount                    = 0
                                State.shoeAppSessionBought   += 1
                                getgenv().ShoesBought = (getgenv().ShoesBought or 0) + 1

                                safeSetLabel(shoeAppStatusLabel,
                                    "Status: Bought " .. parsed.name .. " x" .. totalBought .. "!")
                                safeSetLabel(shoeAppBoughtLabel,
                                    "Bought this session: " .. tostring(State.shoeAppSessionBought))

                                Notify({
                                    Title    = "Shoe App - Bought",
                                    Content  = parsed.name .. " x" .. totalBought .. " - $" .. fmtNum(spent) .. " paid!",
                                    Duration = 5,
                                    Image    = "Check",
                                })

                                safeSpawn(function()
                                    postWebhook(
                                        "SRS Shoe App | by Sakura's Hub",
                                        "Shoe App Purchase",
                                        "**Shoe:** "               .. parsed.name ..
                                        "\n**Price Paid:** "        .. fmtMoney(spent) ..
                                        "\n**Listed Price:** "      .. fmtMoney(parsed.price) ..
                                        "\n**Bought This Drop:** "  .. tostring(totalBought) .. "\n"
                                    )
                                end)

                                deltaWait(0.3)

                            elseif result == "error" then
                                errorCount += 1
                                safeSetLabel(shoeAppStatusLabel,
                                    "Status: Remote error x" .. errorCount .. "/" .. MAX_ERRORS)

                                if errorCount >= MAX_ERRORS then
                                    Notify({
                                        Title    = "Shoe App - Remote Down",
                                        Content  = parsed.name .. " errored " .. MAX_ERRORS .. "x in a row - skipping.",
                                        Duration = 6,
                                        Image    = "X",
                                    })
                                    safeSpawn(function()
                                        postWebhook(
                                            "SRS Shoe App | by Sakura's Hub",
                                            "Shoe App Buy Failed",
                                            "**Shoe:** "    .. parsed.name ..
                                            "\n**Reason:** Remote errored " .. MAX_ERRORS .. " consecutive times." ..
                                            "\n**Bought Before Failing:** " .. tostring(totalBought) .. "\n"
                                        )
                                    end)
                                    break
                                end

                                deltaWait(0.2)

                            else
                                errorCount = 0
                                safeSetLabel(shoeAppStatusLabel,
                                    "Status: Spamming " .. parsed.name .. "...")
                                deltaWait(0.05)
                            end
                        end

                        if totalBought == 0 then
                            Notify({
                                Title    = "Shoe App - Window Closed",
                                Content  = parsed.name .. " - 90s up. Got 0 shoes.",
                                Duration = 5,
                                Image    = "X",
                            })
                            safeSetLabel(shoeAppStatusLabel, "Status: Window closed - 0 bought.")
                        else
                            Notify({
                                Title    = "Shoe App - Drop Done",
                                Content  = parsed.name .. " - got " .. totalBought .. " total this drop!",
                                Duration = 5,
                                Image    = "Check",
                            })
                            safeSetLabel(shoeAppStatusLabel,
                                "Status: Done - " .. totalBought .. " bought. Watching for next...")
                        end
                    end

                    if not anyActive then
                        if nextName then
                            safeSetLabel(shoeAppStatusLabel, "Status: Watching - next: " .. nextName .. " in " .. __L.fmtLeft(nextLeft))
                        else
                            safeSetLabel(shoeAppStatusLabel, "Status: Watching - no drops listed.")
                        end
                    end

                    deltaWait(5)
                end

                safeSetLabel(shoeAppStatusLabel, "Status: Stopped")
                Notify({
                    Title    = "Shoe App",
                    Content  = "Auto buyer stopped.",
                    Duration = 3,
                    Image    = "X",
                })
            end)

        else
            if State.shoeAppThread then
                task.cancel(State.shoeAppThread)
                State.shoeAppThread = nil
            end
            safeSetLabel(shoeAppStatusLabel, "Status: Stopped")
            Notify({
                Title    = "Shoe App",
                Content  = "Auto buyer stopped.",
                Duration = 3,
                Image    = "X",
            })
        end
    end,
})

T("CreateButton", {
    Name = "Reset Session Count",
    Callback = function()
        State.shoeAppSessionBought = 0
        safeSetLabel(shoeAppBoughtLabel, "Bought this session: 0")
        Notify({
            Title    = "Shoe App",
            Content  = "Session count reset to 0.",
            Duration = 3,
            Image    = "Check",
        })
    end,
})

T("CreateSection", "Shoe App Info")

local shoeSlotLabels  = {}
local shoeStatusLabel = T("CreateLabel", "Status: Press Pull Info")

T("CreateButton", {
    Name = "Pull Info",
    Callback = function()
        safeSpawn(function()
            local ok, data = pcall(function()
                return game:GetService("ReplicatedStorage").RemoteEvents.GetShoesAppData:InvokeServer()
            end)

            if not ok or data == nil then
                pcall(function() shoeStatusLabel:Set("Status: Failed to fetch data") end)
                Notify({ Title = "Shoe App", Content = "Failed to pull data!", Duration = 4, Image = "X" })
                return
            end

            for _, lbl in ipairs(shoeSlotLabels) do
                pcall(function() lbl:Destroy() end)
            end
            shoeSlotLabels = {}

            local function formatRelease(tm)
                local t = tonumber(tm)
                if not t then return "Unknown" end
                if t > 9999999999 then t = math.floor(t / 1000) end
                local now  = os.time()
                local left = t - now
                if left <= 0 then return "Available Now!" end
                local days  = math.floor(left / 86400)
                local hours = math.floor((left % 86400) / 3600)
                local mins  = math.floor((left % 3600) / 60)
                if days > 0 then
                    return string.format("%dd %dh %dm", days, hours, mins)
                elseif hours > 0 then
                    return string.format("%dh %dm", hours, mins)
                else
                    return string.format("%d mins", mins)
                end
            end

            if type(data) == "table" then
                local entries = data[1] and data or { data }
                local shown   = 0
                for i, entry in ipairs(entries) do
                    if i > 5 then break end
                    if type(entry) == "table" then
                        local inner   = (type(entry.value) == "table") and entry.value or entry
                        local name    = entry.key or inner.Sn or inner.Name or "Unknown"
                        local price   = inner.Pc  or inner.Price or inner.BuyPrice or 0
                        local release = inner.tm  or inner.Tm  or inner.ReleaseTime or inner.releaseTime

                        local t = tonumber(release)
                        if t then
                            if t > 9999999999 then t = math.floor(t / 1000) end
                            if t - os.time() <= 0 then continue end
                        end

                        local relStr = formatRelease(release)
                        local ok2, lbl = pcall(function()
                            return T("CreateLabel", string.format(
                                "Slot %d | %s | $%s | In: %s",
                                shown + 1, tostring(name), fmtNum(tonumber(price) or 0), relStr
                            ))
                        end)
                        if ok2 and lbl then
                            table.insert(shoeSlotLabels, lbl)
                            shown += 1
                        end
                    end
                end
                if shown == 0 then
                    pcall(function() shoeStatusLabel:Set("Status: No entries found in data") end)
                else
                    pcall(function() shoeStatusLabel:Set("Status: Showing " .. shown .. " shoe(s)") end)
                end
            else
                pcall(function() shoeStatusLabel:Set("Status: Unexpected data type") end)
            end

            RawNotify({ Title = "Shoe App", Content = "Data pulled successfully!", Duration = 4, Image = "Check" })
        end)
    end,
})

end)

-- ── Info & Socials ───────────────────────────────────────────────────────
SubPages:Register("Info", Tabs.Info, function(T, elements)
    T("CreateSection", "Info & Socials")
    T("CreateLabel", "This script was made by qbtbq on Discord.")
    T("CreateLabel", "If you have any issues, join the Discord and open a ticket. Tell us the problem you are having and which executor you use, and we will help as fast as we can.")
    T("CreateLabel", "This script is 100% free and keyless. It is made purely out of passion and love for scripting, so I hope you enjoy it.")
    T("CreateParagraph", { Title = "Why we slowed down the speeds",   Content = "We slowed down the buy and full-auto speeds to cut the detection rate and let the shop reloads settle, so you land more grails and get longer runtimes instead of tripping risk checks. The slow speeds are the safe daily default now. The medium, fast and risky presets are there if you want to push it, but the faster you go the higher the ban chance gets." })
    T("CreateParagraph", { Title = "How walking works", Content = "Every walk (to your PC, to the sell NPC, to a treasure) uses one navigator. It plans a route with Roblox pathfinding using a narrow agent so doorways fit, steers around walls using rays that ignore non-solid parts and other players, hops low ledges, and re-plans if a waypoint becomes blocked. If it gets stuck it jumps, re-plans, and finally gives up so the automation can retry instead of grinding on a wall." })
    T("CreateParagraph", { Title = "How doors are handled", Content = "A blocking part or model named door, gate, entrance, turnstile or shutter counts as a door. The walker looks for its ProximityPrompt or ClickDetector, walks into range, triggers it, waits for the path to clear and re-plans. Prompts that mention buy, sell, shop, robux, unlock, enter or teleport are never triggered. Doors with no handle are pushed open by walking into them. Each door gets 3 tries. No door? It looks for a doorway gap along the wall and slides to it." })
    T("CreateParagraph", { Title = "How selling works", Content = "The sell bar has a moving line; the script fires the Stop button when the line is projected to be inside the Perfect zone, using an adaptive latency value that keeps tracking the server's timing. It sells whatever shoe the carousel shows: there is no rarity order and no 'too few shoes to bother' skip. A sell phase ends only when your sellable inventory is confirmed empty, then the sell bar is closed." })
    T("CreateParagraph", { Title = "How buying and the Buy Budget work", Content = "Every buying mode uses one routine. When a run starts, your current money is saved as the budget. Only purchases reduce it, so worker income, quest rewards and sales can never extend a buy phase. Offers priced above what is left are skipped, best rarity is bought first, and blacklisted rarities are never bought. When the budget is spent, Full modes sell and take a new snapshot; Semi modes stop." })
    T("CreateParagraph", { Title = "Safety notes", Content = "Only one automation runs at a time. Slow and Human tiers are the safe ones; Risky tiers and teleport dig have reported bans. The script loads its UI library and the Server Hop / Join Same Server helpers from GitHub, so only run it if you trust those sources. Everything is logged to Script Logs below: copy them when asking for help." })
    T("CreateSection", "This Is All My Socials")
    T("CreateButton", {
        Name = "Link Tree",
        Callback = function()
            setclipboard("https://linktr.ee/Fadded_market")
            RawNotify({ Title = "Copied!", Content = "Link Tree has been copied to clipboard.", Duration = 3 })
        end,
    })

    T("CreateLabel", "If the Discord link ever stops working, all my links are on the Linktree.")

    T("CreateButton", {
        Name = "Discord",
        Callback = function()
            setclipboard("https://discord.gg/WXXm8zmGNA")
            RawNotify({ Title = "Copied!", Content = "Discord link has been copied to clipboard.", Duration = 3 })
        end,
    })

    T("CreateSection", "Script Logs")

    local SRS_LogParagraph
    local function refreshLogUI()
        if not SRS_LogParagraph then return end
        local buf = getgenv().SRS_LogBuffer or {}
        local txt = table.concat(buf, "\n")
        pcall(function()
            if SRS_LogParagraph.SetText then
                SRS_LogParagraph:SetText(txt)
            elseif SRS_LogParagraph.Set then
                SRS_LogParagraph:Set(txt)
            else
                SRS_LogParagraph.Text = txt
            end
        end)
    end
    getgenv().SRS_LogUpdateGUI = refreshLogUI

    SRS_LogParagraph = T("CreateParagraph", {
        Title = "Console Output",
        Content = table.concat(getgenv().SRS_LogBuffer or {}, "\n"),
    })

    T("CreateButton", {
        Name = "Clear Logs",
        Callback = function()
            getgenv().SRS_LogBuffer = {}
            SRS_LogBuffer = getgenv().SRS_LogBuffer
            refreshLogUI()
            Log("INFO", "Logs cleared")
            RawNotify({ Title = "Logs", Content = "Console logs cleared.", Duration = 2 })
        end,
    })

    T("CreateButton", {
        Name = "Copy Logs",
        Callback = function()
            local txt = table.concat(getgenv().SRS_LogBuffer or {}, "\n")
            if setclipboard then
                setclipboard(txt)
                RawNotify({ Title = "Logs", Content = "Logs copied to clipboard.", Duration = 2 })
            end
        end,
    })

    refreshLogUI()
end)

-- Every dropdown page is now its own sidebar tab — build them all up front.
SubPages:Show("Full Auto")
SubPages:Show("Semi PC Auto")
SubPages:Show("Shoe App")
SubPages:Show("Risky Buy")
SubPages:Show("Dashboard")
SubPages:Show("Blacklist")
SubPages:Show("Webhook")
SubPages:Show("Stability")
SubPages:Show("Quests")
SubPages:Show("Halloween")
SubPages:Show("Dig Dashboard")
SubPages:Show("Info")

-- ── Character respawn ──────────────────────────────────────────────────────
LocalPlayer.CharacterAdded:Connect(function(NewCharacter)
    if not srsAlive() then return end
    Character        = NewCharacter
    Humanoid         = NewCharacter:WaitForChild("Humanoid")
    HumanoidRootPart = NewCharacter:WaitForChild("HumanoidRootPart")
    State.Flying  = false
    State.InfJump = false
    State.Noclip  = false
    if State.noclipConnection then State.noclipConnection:Disconnect(); State.noclipConnection = nil end
    task.delay(2, function() getSellFrame() end)
end)

-- ── Crash / health detections ──────────────────────────────────────────────
LocalPlayer.AncestryChanged:Connect(function()
    if not srsAlive() then return end
    sendAlert("GameClose", "Game Closed / Kicked", "The game closed. Could be a kick, server shutdown, or network drop.")
end)

pcall(function()
    NetworkClient.ConnectionFailed:Connect(function(peer, code, reason)
        if not srsAlive() then return end
        sendAlert("NetworkDisconnect", "Connection Failed",
            "Peer: " .. tostring(peer) .. " | Code: " .. tostring(code) .. " | Reason: " .. tostring(reason))
    end)
end)

ScriptContext.Error:Connect(function(message, trace, script)
    if not srsAlive() then return end
    local scriptName = script and script:GetFullName() or "Unknown"
    local fullErr = string.format("Script Error | %s\nError: %s\nTrace: %s", scriptName, tostring(message), tostring(trace))
    Log("ERROR", fullErr)
    if not canAlert("script_error", 10) then return end
    if message and message:find("cannot resume non%-suspended coroutine") then return end
    if trace and trace:find("PCLocalScript") then return end
    sendAlert("ScriptError", "Script Error",
        "**Error:** " .. tostring(message) ..
        "\n**Script:** " .. scriptName ..
        "\n**Trace:** " .. tostring(trace):sub(1, 300))
end)

State.lastHeartbeat    = tick()
State.heartbeatAlerted = false
RunService.Heartbeat:Connect(function()
    if not srsAlive() then return end
    State.lastHeartbeat    = tick()
    State.heartbeatAlerted = false
end)

safeSpawn(function()
    while true do
        if not srsAlive() then return end
        deltaWait(5)
        local gap = tick() - State.lastHeartbeat
        if gap > 10 and not State.heartbeatAlerted then
            State.heartbeatAlerted = true
            sendAlert("HeartbeatTimeout", "Heartbeat Timeout",
                "No Heartbeat for " .. math.floor(gap) .. " seconds. Game may be frozen or crashed.")
        end
    end
end)

safeSpawn(function()
    while srsAlive() and not getgenv().ScriptShuttingDown do
        deltaWait(30)
        if getgenv().ScriptShuttingDown then break end
        if State.currentFPS < 10 and State.currentFPS > 0 then
            if canAlert("fps_drop", 120) then
                sendAlert("FPSDrop", "Critical FPS Drop", "FPS is at " .. tostring(State.currentFPS) .. " — game may be about to crash.")
            end
        end
    end
end)

safeSpawn(function()
    while srsAlive() and not getgenv().ScriptShuttingDown do
        deltaWait(30)
        if getgenv().ScriptShuttingDown then break end
        local ok, pingVal = pcall(function()
            return game:GetService("Stats").Network.ServerStatsItem["Data Ping"]:GetValue()
        end)
        if ok and type(pingVal) == "number" and pingVal > 2000 then
            if canAlert("ping_spike", 120) then
                sendAlert("PingSpike", "Ping Spike", "Ping is at " .. tostring(math.floor(pingVal)) .. " ms — high risk of disconnect.")
            end
        end
    end
end)

local lastKnownInventorySize = 0
safeSpawn(function()
    while srsAlive() and not getgenv().ScriptShuttingDown do
        deltaWait(10)
        if getgenv().ScriptShuttingDown then break end
        local inv         = LocalPlayer:FindFirstChild("Inventory")
        local sellable    = inv and inv:FindFirstChild("SellableInventory")
        local currentSize = sellable and #sellable:GetChildren() or 0
        if lastKnownInventorySize > 3 and currentSize == 0
            and not Settings.Sell and not getgenv().FullAutoRunning and not getgenv().PCFullAutoRunning then
            if canAlert("inventory_wipe", 60) then
                sendAlert("InventoryAnomaly", "Inventory Anomaly",
                    "Had " .. tostring(lastKnownInventorySize) .. " shoes — now 0. Possible data loss.")
            end
        end
        lastKnownInventorySize = currentSize
    end
end)

safeSpawn(function()
    local lastBoughtCount = 0
    local lastBoughtTick  = tick()
    while srsAlive() and not getgenv().ScriptShuttingDown do
        deltaWait(60)
        if getgenv().ScriptShuttingDown then break end
        local anyRunning = getgenv().FullAutoRunning or getgenv().PCFullAutoRunning
        if anyRunning then
            if getgenv().ShoesBought == lastBoughtCount then
                local stalledFor = math.floor((tick() - lastBoughtTick) / 60)
                if stalledFor >= 5 then
                    if canAlert("auto_stall", 300) then
                        sendAlert("AutoStall", "Automation Stalled",
                            "Full Auto running " .. tostring(stalledFor) .. " min with no shoes bought. May be stuck.")
                    end
                end
            else
                lastBoughtCount = getgenv().ShoesBought
                lastBoughtTick  = tick()
            end
        else
            lastBoughtCount = getgenv().ShoesBought
            lastBoughtTick  = tick()
        end
    end
end)

safeSpawn(function()
    while srsAlive() and not getgenv().ScriptShuttingDown do
        deltaWait(State.alivePingMinutes * 60)
        if getgenv().ScriptShuttingDown then break end
        if getgenv().DetectionToggles and getgenv().DetectionToggles.AlivePing then
            __L.sendAlivePing()
        end
    end
end)

safeSpawn(function()
    local lastMoneyCheck = getMoney()
    local lastMoneyTick  = tick()
    while srsAlive() and not getgenv().ScriptShuttingDown do
        deltaWait(60)
        if getgenv().ScriptShuttingDown then break end
        local anyRunning = getgenv().FullAutoRunning or getgenv().PCFullAutoRunning
        if not anyRunning and not Settings.Sell then
            lastMoneyCheck = getMoney(); lastMoneyTick = tick(); continue
        end
        if Settings.Sell then
            lastMoneyCheck = getMoney(); lastMoneyTick = tick(); continue
        end
        local currentMoney = getMoney()
        if currentMoney ~= lastMoneyCheck then
            lastMoneyCheck = currentMoney; lastMoneyTick = tick()
        else
            local stuckMin = math.floor((tick() - lastMoneyTick) / 60)
            if stuckMin >= 15 then
                if canAlert("money_stuck", 600) then
                    sendAlert("MoneyStuck", "Money Not Changing",
                        "Money stuck at " .. fmtMoney(currentMoney) .. " for " .. tostring(stuckMin) .. " min.")
                end
            end
        end
    end
end)

safeSpawn(function()
    local lastLeaderstatsCheck = {}
    local ls = LocalPlayer:WaitForChild("leaderstats", 10)
    if not ls then return end
    for _, stat in ipairs(ls:GetChildren()) do
        if stat:IsA("IntValue") or stat:IsA("NumberValue") then
            lastLeaderstatsCheck[stat.Name] = stat.Value
        end
    end
    while srsAlive() and not getgenv().ScriptShuttingDown do
        deltaWait(15)
        if getgenv().ScriptShuttingDown then break end
        for _, stat in ipairs(ls:GetChildren()) do
            if stat:IsA("IntValue") or stat:IsA("NumberValue") then
                local prev = lastLeaderstatsCheck[stat.Name] or 0
                if prev > 100 and stat.Value == 0 then
                    if canAlert("stat_wipe_" .. stat.Name, 120) then
                        sendAlert("LeaderstatWipe", "Stat Wiped: " .. stat.Name,
                            stat.Name .. " dropped from " .. tostring(prev) .. " to 0.")
                    end
                end
                lastLeaderstatsCheck[stat.Name] = stat.Value
            end
        end
    end
end)

safeSpawn(function()
    while srsAlive() and not getgenv().ScriptShuttingDown do
        deltaWait(30)
        if getgenv().ScriptShuttingDown then break end
        local gui = LocalPlayer.PlayerGui:FindFirstChild("MainScreenGui")
        if not gui then
            if canAlert("gui_missing", 120) then
                sendAlert("GUIMissing", "GUI Missing",
                    "MainScreenGui not found in PlayerGui. Sell automation is broken until respawn.")
            end
        end
    end
end)

safeSpawn(function()
    while true do
        if not srsAlive() then return end
        deltaWait(120)
        local missing = {}
        if not request             then table.insert(missing, "request") end
        if not firetouchinterest   then table.insert(missing, "firetouchinterest") end
        if not fireproximityprompt then table.insert(missing, "fireproximityprompt") end
        if not setclipboard        then table.insert(missing, "setclipboard") end
        if not getgenv             then table.insert(missing, "getgenv") end
        if #missing > 0 then
            if canAlert("executor_health", 300) then
                sendAlert("ExecutorHealth", "Executor Functions Missing",
                    "These globals are no longer available: " .. table.concat(missing, ", "))
            end
        end
    end
end)

-- ── Teleport / place change safety shutdown ───────────────────────────────
local function shutdownAllAutomation()
    LogEvent("Shutdown", "Shutting down all automation")
    if Helpers.Macro then pcall(Helpers.Macro.stop, true) end
    getgenv().FullAutoRunning   = false
    getgenv().PCFullAutoRunning = false
    Settings.Sell               = false
    Settings.Buy.Enabled        = false
    State.shoeAppBuying         = false
    State.farming               = false
    State.riskFarming           = false
    State.pcAutoBuyRunning      = false
    -- Reset every UI toggle so toggles don't appear stuck "on" after teleport
    getgenv().FullAutoSwitching = true
    safeSetToggle("SlowFullAuto", false)
    safeSetToggle("MediumFullAuto", false)
    safeSetToggle("FastFullAuto", false)
    safeSetToggle("RiskySlowFullAuto", false)
    safeSetToggle("RiskyMediumFullAuto", false)
    safeSetToggle("RiskyFastFullAuto", false)
    safeSetToggle("AutoSell", false)
    safeSetToggle("SlowAutoBuy", false)
    safeSetToggle("MediumAutoBuy", false)
    safeSetToggle("FastAutoBuy", false)
    safeSetToggle("SlowRiskyBuy", false)
    safeSetToggle("MediumRiskyBuy", false)
    safeSetToggle("FastRiskyBuy", false)
    safeSetToggle("SlowPCAutoBuy", false)
    safeSetToggle("MediumPCAutoBuy", false)
    safeSetToggle("FastPCAutoBuy", false)
    safeSetToggle("SlowPCFullAuto", false)
    safeSetToggle("MediumPCFullAuto", false)
    safeSetToggle("FastPCFullAuto", false)
    safeSetToggle("AutoUpgradeStore", false)
    if Helpers.Upg then Helpers.Upg.stop() end
    for _, k in ipairs(AUTOMATION_TOGGLE_KEYS) do safeSetToggle(k, false) end
    getgenv().FullAutoSwitching = false
    stopSellBarListener()
    __L.stopShoeAppWatcher()
    if fullAutoThread               then task.cancel(fullAutoThread);               fullAutoThread        = nil end
    if State.farmThread             then task.cancel(State.farmThread);             State.farmThread      = nil end
    if State.riskFarmThread         then task.cancel(State.riskFarmThread);         State.riskFarmThread  = nil end
    if State.shoeAppThread          then task.cancel(State.shoeAppThread);          State.shoeAppThread   = nil end
    if State.pcAutoBuyThread        then task.cancel(State.pcAutoBuyThread);        State.pcAutoBuyThread = nil end
    if State.pcFullAutoThread       then task.cancel(State.pcFullAutoThread);       State.pcFullAutoThread = nil end
    if State.noclipConnection       then State.noclipConnection:Disconnect();       State.noclipConnection = nil end
    -- [FIX] Teleport / place-change shutdown must not leave a game GUI open.
    if Helpers.closeShop then pcall(Helpers.closeShop) end
    closeSellBar()
end

-- ── Automation-state sidecar (fresh boot auto-restore) ─────────────────────
-- Mirrors which automation was live (mode:speed) into a tiny sidecar file.
-- On a fresh boot (battery death / manual re-execute) the restore block at
-- the end of runMainBody re-flips the matching toggle. Written only on
-- CHANGE so the file gets no disk churn while the farm idles.
local AUTOSTATE_PATH = "SRS_V4_AutoState.json"

local function serializeAutoState()
    if Helpers.Macro and Helpers.Macro.Running then
        return "macro:" .. tostring(Helpers.Macro.Speed)
    end
    if getgenv().FullAutoRunning then
        return "fullAuto:" .. tostring(getgenv().FullAutoSpeed)
    end
    if getgenv().PCFullAutoRunning then
        return "pcFullAuto:" .. tostring(State.pcFullAutoSpeed)
    end
    if State.pcAutoBuyRunning then
        return "pcAutoBuy:" .. tostring(State.pcAutoBuySpeed)
    end
    if State.riskFarming then
        return "riskDig:" .. tostring(State.riskDigSpeed)
    end
    if State.farming then
        return "walkDig:" .. tostring(State.digSpeed)
    end
    local S = getgenv().Settings or {}
    if S.Sell then
        return "sell"
    end
    if S.Buy and S.Buy.Enabled then
        return "buy:" .. tostring(getgenv().SRS_LastBuySpeed)
    end
    if S.Buttons then return "storeUpgrade" end
    return "none"
end

local function persistAutoState()
    local key = serializeAutoState()
    if key == getgenv().SRS_AutoStateKey then return end
    getgenv().SRS_AutoStateKey = key
    local ok, encoded = pcall(function()
        return game:GetService("HttpService"):JSONEncode({ state = key })
    end)
    if ok then safeWriteFile(AUTOSTATE_PATH, encoded) end
end

game:GetService("TeleportService").LocalPlayerArrivedFromTeleport:Connect(function() if srsAlive() then shutdownAllAutomation() end end)

game:GetService("Players").LocalPlayer.OnTeleport:Connect(function(teleportState)
    if not srsAlive() then return end
    if teleportState == Enum.TeleportState.RequestedFromServer
    or teleportState == Enum.TeleportState.Started then
        shutdownAllAutomation()
    end
end)

-- ── Notify saved webhook was loaded ───────────────────────────────────────
if getgenv().WebhookURL and getgenv().WebhookURL ~= "" then
    Log("INFO", "Settings loaded - webhook & blacklist restored from save.")
    RawNotify({ Title = "Settings Loaded", Content = "Webhook & blacklist restored from save!", Duration = 4, Image = "Check" })
end

Log("INFO", "SRS V7 Loaded - all detections active. Set webhook in Webhook Alerts tab.")
RawNotify({
    Title    = "SRS V7 Loaded",
    Content  = "All detections active. Set your webhook in the Webhook Alerts tab.",
    Duration = 5,
    Image    = "Shield",
})

-- ── Boot always starts with everything OFF ────────────────────────────────
-- The old "restore automation after boot" feature (and its sidecar saving) was
-- removed: re-injecting the script never re-enables a previous toggle. Any
-- sidecar left by an older version is overwritten so it can never be read.
safeWriteFile(AUTOSTATE_PATH, '{"state":"none"}')
-- v4: the save file now keeps ONLY the blacklist (+ webhook URL text and quest-claim ids).
-- Wipe the leftover per-setting keys from older saves right away.
pcall(saveSettings)
getgenv().SRS_AutoStateKey = "none"

end -- runMainBodyPart3

__L.runMainBodyPart1()
__L.runMainBodyPart2()
__L.runMainBodyPart3()

-- ═══════════════════════════════════════════════════════════════════════════
-- [LOGUPG] Limited Shop Drop Sniper  —  added from the live drop logs.
--
-- What the logs proved the game actually does:
--   * workspace.LimitedShop is a Model holding a "Boxes" folder.
--   * Each box  Box<N> -> HoldPart -> BuyPrompt  is a ProximityPrompt with
--       ObjectText  = the shoe name            (e.g. "Mike SB Dunk Low London")
--       ActionText  = "Purchase For 2.0M"      (the price, K/M/B suffix)
--       HoldDuration = 3                       (hold the key to buy)
--       MaxActivationDistance ~= 7-8
--   * ReplicatedStorage.SneakerModule also exposes .LimitedShopSneaker (the
--     list of limited shoes) alongside the .sneakers table we already require.
--
-- The macro had NO LimitedShop handling at all. This module watches every box,
-- posts a Discord alert the moment a box (re)stocks, and - if you arm it - walks
-- to the box and holds its buy prompt for you. Self-contained, so bootScript()
-- spends no registers on it. Turn it off (or any other automation on) to stop it.
-- ═══════════════════════════════════════════════════════════════════════════
Helpers.LimitedShop = (function()
    local L = {
        running = false, autoBuy = false, thread = nil, interval = 1.0,
        status = "Idle", seen = {}, lastAlert = {}, bought = 0, dropped = 0,
    }
    Helpers.LimitedShop = L
    L.setLabel = function() end

    local SUFFIX = { k = 1e3, m = 1e6, b = 1e9, t = 1e12 }
    local function parsePrice(text)
        if type(text) ~= "string" then return 0 end
        local t = text:gsub("<[^>]->", ""):gsub(",", "")
        local num, suf = t:match("(%d[%d%.]*)%s*([KkMmBbTt]?)")
        local n = tonumber(num)
        if not n then return 0 end
        return math.floor(n * (SUFFIX[(suf or ""):lower()] or 1))
    end

    -- Reuse the macro's own blacklist filter (rarity only now) so the sniper
    -- never buys something the normal buy loop would skip.
    local function shoeBlacklisted(name)
        local data = Sneakers and Sneakers[name]
        if type(data) == "table" and isBlacklisted then return isBlacklisted(data) end
        if isBlacklisted then return isBlacklisted(name) end
        return false
    end

    -- Walk workspace.LimitedShop.Boxes and return every box that currently shows
    -- an enabled buy prompt (i.e. has stock).
    function L.scan()
        local root = Workspace:FindFirstChild("LimitedShop")
        if not root then return nil, "LimitedShop missing" end
        local boxes = root:FindFirstChild("Boxes") or root
        local out = {}
        for _, box in ipairs(boxes:GetChildren()) do
            local prompt = box:FindFirstChildWhichIsA("ProximityPrompt", true)
            if prompt and prompt.Enabled then
                local shoe = tostring(prompt.ObjectText or "")
                if shoe ~= "" then
                    local pos
                    local pp = prompt.Parent
                    if pp and pp:IsA("BasePart") then
                        pos = pp.Position
                    else
                        pcall(function() pos = box:GetPivot().Position end)
                    end
                    table.insert(out, {
                        boxName   = box.Name,
                        shoe      = shoe,
                        priceText = tostring(prompt.ActionText or ""),
                        price     = parsePrice(prompt.ActionText),
                        prompt    = prompt,
                        pos       = pos,
                        hold      = tonumber(prompt.HoldDuration) or 0,
                    })
                end
            end
        end
        return out
    end

    local function rawNotify(title, content)
        pcall(Notify, { Title = title, Content = content, Duration = 6, Image = "Check" })
    end

    local function rawWebhook(title, lines)
        safeSpawn(function()
            postWebhook("SRS Limited Shop | by Sakura's Hub", title, lines)
        end)
    end

    -- Walk into range then hold the prompt. Verification = money dropped
    -- (the prompt is literally "Purchase For <price>").
    local function attemptBuy(item, keepGoing)
        local prompt = item.prompt
        if not prompt or not prompt.Parent then return false, "prompt gone" end
        if not prompt.Enabled then return false, "prompt disabled" end
        if shoeBlacklisted(item.shoe) then return false, "blacklisted" end
        local price = item.price or 0
        if getMoney() < price then return false, "not enough money" end
        if Helpers.budgetOn() and price > 0 and Helpers.budgetLeft() < price then
            return false, "over budget"
        end
        local char = LocalPlayer.Character
        local hrp = char and char:FindFirstChild("HumanoidRootPart")
        local humanoid = char and char:FindFirstChildOfClass("Humanoid")
        if not hrp or not humanoid then return false, "no character" end
        local reach = math.max(4, (tonumber(prompt.MaxActivationDistance) or 8) - 2)
        if item.pos and (hrp.Position - item.pos).Magnitude > reach and Helpers.SmartWalkTo then
            Helpers.SmartWalkTo(item.pos, keepGoing, { reach = reach, maxTime = 12 })
        end
        local t0 = tick()
        while keepGoing() and item.pos and (hrp.Position - item.pos).Magnitude > reach and tick() - t0 < 3 do
            humanoid:MoveTo(item.pos)
            deltaWait(0.1)
        end
        local before = getMoney()
        if item.hold > 0 then
            pcall(function() prompt:InputHoldBegin() end)
            local h0 = tick()
            while keepGoing() and tick() - h0 < item.hold + 0.3 do deltaWait(0.05) end
            pcall(function() prompt:InputHoldEnd() end)
        else
            pcall(fireproximityprompt, prompt)
        end
        deltaWait(0.45)
        local after = getMoney()
        if after < before then
            local spent = before - after
            if spent > 0 and Helpers.recordSpend then Helpers.recordSpend(spent) end
            getgenv().ShoesBought = (getgenv().ShoesBought or 0) + 1
            return true, "bought", spent
        end
        return false, "no effect"
    end

    local function loop()
        local firstPass = true
        while L.running and srsAlive() do
            local items, err = L.scan()
            if not items then
                L.status = "Waiting (" .. tostring(err) .. ")"
                L.setLabel("Status: " .. L.status)
            else
                -- Which boxes are here now, and which are new since the last poll?
                local present, fresh = {}, {}
                for _, it in ipairs(items) do
                    local key = it.boxName .. "|" .. it.shoe
                    present[key] = true
                    if firstPass then
                        -- On arming auto-buy, also treat the stock already up.
                        if L.autoBuy then table.insert(fresh, it) end
                    elseif not L.seen[key] then
                        table.insert(fresh, it)
                    end
                    L.seen[key] = true
                end
                for k in pairs(L.seen) do if not present[k] then L.seen[k] = nil end end

                for _, it in ipairs(fresh) do
                    local key = it.boxName .. "|" .. it.shoe
                    local now = tick()
                    if firstPass or (now - (L.lastAlert[key] or 0) >= 20) then
                        L.lastAlert[key] = now
                        L.dropped = L.dropped + 1
                        local ptext = (it.priceText ~= "" and it.priceText) or ("$" .. fmtNum(it.price))
                        L.status = "DROP: " .. it.shoe .. " (" .. ptext .. ")"
                        L.setLabel("Status: " .. L.status)
                        LogEvent("LimitedShop", "drop " .. it.shoe .. " " .. ptext .. " box=" .. it.boxName)
                        rawNotify("Limited Shop Drop", it.shoe .. " - " .. ptext)
                        rawWebhook("Limited Drop Detected",
                            "**Shoe:** " .. it.shoe ..
                            "\n**Price:** " .. ptext ..
                            "\n**Box:** " .. it.boxName ..
                            "\n**Auto-Buy:** " .. tostring(L.autoBuy) .. "\n")
                        if L.autoBuy then
                            local ok, why, spent = attemptBuy(it, function() return L.running and srsAlive() end)
                            if ok then
                                L.bought = L.bought + 1
                                L.status = "Bought " .. it.shoe .. " ($" .. fmtNum(spent) .. ")"
                                L.setLabel("Status: " .. L.status)
                                LogEvent("LimitedShop", "bought " .. it.shoe .. " $" .. tostring(spent))
                                rawWebhook("Limited Drop Bought",
                                    "**Shoe:** " .. it.shoe .. "\n**Paid:** $" .. fmtNum(spent) .. "\n")
                            else
                                LogEvent("LimitedShop", "buy failed " .. it.shoe .. ": " .. tostring(why))
                            end
                        end
                    end
                end

                if #fresh == 0 then
                    L.status = "Watching (" .. #items .. " in stock)"
                    L.setLabel("Status: " .. L.status)
                end
                firstPass = false
            end
            local waited = 0
            while L.running and waited < (L.interval or 1.0) do
                deltaWait(0.1)
                waited = waited + 0.1
            end
        end
        L.setLabel("Status: Stopped")
    end

    function L.start(autoBuy)
        L.autoBuy = autoBuy and true or false
        if L.running then return end
        L.running = true
        L.seen = {}
        L.status = autoBuy and "Auto-buy starting..." or "Watch starting..."
        LogEvent("LimitedShop", "started autoBuy=" .. tostring(L.autoBuy))
        L.thread = task.spawn(loop)
    end

    function L.stop()
        if not L.running and not L.thread then return end
        L.running = false
        if L.thread then pcall(task.cancel, L.thread) end
        L.thread = nil
        L.status = "Stopped"
        L.setLabel("Status: Stopped")
        LogEvent("LimitedShop", "stopped")
    end

    -- Dump the live box layout + the LimitedShopSneaker list to the Script Logs,
    -- so the layout can be re-checked after a game update.
    function L.dump()
        local items, err = L.scan()
        LogEvent("LimitedShop", "dump begin (" .. tostring(err or (#items .. " box(es)")) .. ")")
        for _, it in ipairs(items or {}) do
            LogEvent("LimitedShop", "dump box=" .. it.boxName .. " shoe=" .. it.shoe ..
                " price=" .. tostring(it.priceText) .. " hold=" .. tostring(it.hold))
        end
        local mod = ReplicatedStorage:FindFirstChild("SneakerModule")
        if mod then
            local ok, list = pcall(function() return require(mod).LimitedShopSneaker end)
            if ok and type(list) == "table" then
                for i, name in ipairs(list) do
                    LogEvent("LimitedShop", "shoelist[" .. i .. "]=" .. tostring(name))
                end
            end
        end
        LogEvent("LimitedShop", "dump end")
        return items
    end

    -- ── UI (own tab, registered in the Tabs table near the top) ───────────
    local tab = Tabs.LimitedShop
    if tab then
        tab:CreateSection("Limited Shop Drop Sniper")
        createLabelShim(tab,
            "Watches workspace.LimitedShop boxes (the fast-selling limited restock). " ..
            "Alerts you on Discord the moment new stock appears, and can walk to the box " ..
            "and hold the buy prompt for you. Buying needs you near the shop.")
        -- [FIX] Use the shared label shim, not SakuraUI's native CreateLabel: the
        -- native component renders its own boxed "Label" chrome (the raw word
        -- "Label" showed up on this page), while the shim is a plain text row and
        -- still exposes :Set(...) for the live status text.
        local statusLabel = createLabelShim(tab, "Status: Idle")
        L.setLabel = function(s)
            if statusLabel then
                pcall(function() statusLabel:Set(tostring(s)) end)
            end
        end

        local watchToggle, buyToggle
        watchToggle = tab:CreateToggle({
            Name = "Watch Limited Shop (alert on new stock)",
            CurrentValue = false, Flag = "LsWatch",
            Callback = function(state)
                if state then
                    cancelOtherAutomation(watchToggle)
                    L.start(false)
                else
                    L.stop()
                end
            end,
        })
        if watchToggle.Set == nil and watchToggle.SetValue then watchToggle.Set = watchToggle.SetValue end
        Toggles.LimitedShopWatch = watchToggle

        buyToggle = tab:CreateToggle({
            Name = "Auto-Buy Limited Drops (risky - spends money)",
            CurrentValue = false, Flag = "LsBuy",
            Callback = function(state)
                if state then
                    cancelOtherAutomation(buyToggle)
                    L.start(true)
                else
                    L.stop()
                end
            end,
        })
        if buyToggle.Set == nil and buyToggle.SetValue then buyToggle.Set = buyToggle.SetValue end
        Toggles.LimitedShopBuy = buyToggle

        tab:CreateButton({
            Name = "Scan Limited Shop Now (to Script Logs)",
            Callback = function() safeSpawn(function() L.dump() end) end,
        })
        createLabelShim(tab, "Tip: keep this tab open while you wait at the store so you see the status line.")
    end

    return L
end)()

-- ═══════════════════════════════════════════════════════════════════════════
-- Arcade AFK farmer  —  built from the live tree + the user's notes.
--
-- What the game actually has (verified live on the store):
--   * <store>.BoxingMachine.OpenPart.ProximityPrompt       act="Play"  obj="Boxing Machine"
--   * <store>.BasketballMachine.OpenPart.ProximityPrompt   act="Play"  obj="Basketball Machine"
--   * both prompts open a UI frame under PlayerGui.MainScreenGui:
--       BasketballMinigame.ShootButton   (label "Shoot")        $10K per shot, +100 Tickets
--       PunchingBagMiniGame.ShootButton  (label "Start Punching") $10K, punch for tickets
--     Both ShootButtons have REAL MouseButton1Click handlers, so the miner fires
--     the button's own signal (never the server remote).
--   * <store>.PrizeCounter.OpenShopPart.ProximityPrompt    act="Open" obj="Arcade Prizes"
--     opens PlayerGui.MainScreenGui.ArcadePrizeFrame — 6 shoe prizes, each with a
--     BuyButton, paid with PlayerInfo.Tickets.
--
-- The macro had NO arcade handling. This module plays a chosen minigame on a
-- loop (walk to the machine -> fire the Play prompt -> press the action button
-- -> repeat) so you can AFK tickets, and can optionally open the Prize shop.
-- Self-contained, so bootScript() spends no registers on it.
-- ═══════════════════════════════════════════════════════════════════════════
Helpers.Arcade = (function()
    local A = {
        running = false, mode = nil, thread = nil,
        status = "Idle", plays = 0, tickets0 = 0, setLabel = function() end,
    }
    Helpers.Arcade = A
    -- Programmatic handle (also lets the user start/stop the farm without the UI).
    getgenv().SRS_Arcade = A

    local function log(msg) pcall(LogEvent, "Arcade", msg) end
    local function notify(t, c, d) pcall(Notify, { Title = t, Content = c, Duration = d or 3, Image = "Check" }) end

    local function playerGui() return LocalPlayer:FindFirstChild("PlayerGui") end
    local function mainGui()
        local pg = playerGui()
        return pg and pg:FindFirstChild("MainScreenGui")
    end
    local function myStore()
        local stores = workspace:FindFirstChild("Stores")
        return stores and stores:FindFirstChild(LocalPlayer.Name .. "Store")
    end
    local function tickets()
        local pi = LocalPlayer:FindFirstChild("PlayerInfo")
        local t = pi and pi:FindFirstChild("Tickets")
        return (t and tonumber(t.Value)) or 0
    end
    local function money()
        local ls = LocalPlayer:FindFirstChild("leaderstats")
        local m = ls and ls:FindFirstChild("Money")
        return (m and tonumber(m.Value)) or 0
    end

    -- Machine model -> the UI frame its Play prompt opens.
    local MACHINES = {
        basketball = { part = "BasketballMachine", frame = "BasketballMinigame", label = "Basketball" },
        boxing     = { part = "BoxingMachine",     frame = "PunchingBagMiniGame", label = "Boxing" },
    }

    -- Walk to the machine's Play prompt and fire it. Returns the opened frame or nil.
    local function openMachine(alive, key)
        local def = MACHINES[key]
        local store = myStore()
        if not (store and def) then return nil, "store/machine missing" end
        local machine = store:FindFirstChild(def.part)
        if not machine then return nil, def.part .. " missing" end
        -- If the minigame is already open, do NOT fire the Play prompt again:
        -- the prompt toggles the frame, so re-firing it would close the game.
        local gNow = mainGui()
        local openNow = gNow and gNow:FindFirstChild(def.frame)
        if openNow and openNow.Visible then return openNow end
        local openPart = machine:FindFirstChild("OpenPart")
        local prompt = nil
        for _, d in ipairs(machine:GetDescendants()) do
            if d:IsA("ProximityPrompt") then prompt = d; break end
        end
        -- Stand inside the prompt's activation radius before firing it.
        local hrp = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
        local okp, pivot = pcall(function() return machine:GetPivot() end)
        local maxD = prompt and (tonumber(prompt.MaxActivationDistance) or 10) or 10
        local reach = math.max(3, maxD - 3)
        if hrp and okp and pivot and (hrp.Position - pivot.Position).Magnitude > reach then
            if SmartWalkTo then pcall(SmartWalkTo, pivot.Position, alive, { reach = reach, maxTime = 30 }) end
        end
        if prompt and alive() then pcall(fireproximityprompt, prompt) end
        task.wait(0.4)
        local g = mainGui()
        local frame = g and g:FindFirstChild(def.frame)
        return frame
    end

    -- ── One Boxing round (confirmed live) ─────────────────────────────────
    -- First click on ShootButton pays $10K and starts the round; every further
    -- click counts one punch. At ~100 punches the game pays +100 Tickets about
    -- 3-4s later (verified live: 100 clicks -> "+100 Tickets", tickets 386->486).
    -- Click until the hidden ClickedAmountText reads 100, then wait for the
    -- payout, so extra clicks can never spill into another paid round.
    local function boxingRound(alive)
        local frame = openMachine(alive, "boxing")
        if not frame then return nil, nil, "no frame" end
        local t0, m0 = tickets(), money()
        local punches, payout = 0, 0
        local deadline = tick() + 15
        local started = false
        while A.running and alive() and tick() < deadline do
            local g = mainGui()
            local f = g and g:FindFirstChild("PunchingBagMiniGame")
            if not (f and f.Visible) then break end
            local btn = f:FindFirstChild("ShootButton")
            if not btn then break end
            pcall(firesignal, btn.MouseButton1Click)
            punches += 1
            started = true
            local nowT = tickets()
            if nowT > t0 then payout = nowT - t0; break end
            local ct = f:FindFirstChild("ClickedAmountText")
            local n = ct and tonumber(ct.Text)
            if n and n >= 100 then
                -- round complete: stop clicking and wait for the payout
                local payUntil = tick() + 15
                while A.running and alive() and tick() < payUntil do
                    task.wait(0.25)
                    nowT = tickets()
                    if nowT > t0 then payout = nowT - t0; break end
                end
                break
            end
            if punches >= 115 then break end
            task.wait(0.025)
        end
        if started and payout == 0 then
            local payUntil = tick() + 12
            while A.running and alive() and tick() < payUntil do
                task.wait(0.25)
                local nowT = tickets()
                if nowT > t0 then payout = nowT - t0; break end
            end
        end
        return punches, payout, nil, t0, m0
    end

    -- ── Basketball aim ────────────────────────────────────────────────────
    -- Decompiled BasketballLocalScript: clicking Shoot fires BuyBasketballEvent;
    -- the SERVER then InvokeClient()s back (one round trip, measured 0.18-0.32s)
    -- and only then are the arrow tweens cancelled, freezing the launch angle.
    -- The ball gets Impulse(LookVector*1.5 + UpVector*3.8); ideal ball direction
    -- is -159.5 deg toward TouchToWin (size .75x.005x.75, so it can tunnel).
    -- We therefore aim AHEAD: predict the frozen angle = current + omega*delay.
    local ARM_TARGET = -155.0
    local ARM_DELAY  = 0.22
    local function ballAngle()
        local store = myStore()
        local m = store and store:FindFirstChild("BasketballMachine")
        local atm = m and m:FindFirstChild("ArrowTurnModel")
        local pp = atm and atm.PrimaryPart
        if not pp then return nil end
        local lv = pp.CFrame.LookVector
        return math.deg(math.atan2(lv.X, lv.Z))
    end
    local function normAng(d)
        while d > 180 do d -= 360 end
        while d <= -180 do d += 360 end
        return d
    end
    local function basketballRound(alive)
        local frame = openMachine(alive, "basketball")
        if not frame then return nil, nil, "no frame" end
        local t0, m0 = tickets(), money()
        local btn = frame:FindFirstChild("ShootButton")
        if not btn then return nil, nil, "no ShootButton", t0, m0 end
        local readyUntil = tick() + 12
        while A.running and alive() and tick() < readyUntil and not btn.Visible do task.wait(0.1) end
        if not btn.Visible then return nil, nil, "button not ready", t0, m0 end
        local prev, prevT = ballAngle(), tick()
        local aimUntil = tick() + 4
        local clicked = false
        while A.running and alive() and tick() < aimUntil do
            task.wait()
            local a, now = ballAngle(), tick()
            if a and prev then
                local dt = now - prevT
                if dt > 0.001 then
                    local omega = normAng(a - prev) / dt
                    local pred = normAng(a + omega * ARM_DELAY)
                    if math.abs(normAng(pred - ARM_TARGET)) <= 2.0 then
                        pcall(firesignal, btn.MouseButton1Click)
                        clicked = true
                        break
                    end
                end
            end
            prev, prevT = a, now
        end
        if not clicked then return nil, nil, "aim timeout", t0, m0 end
        local clickT = tick()
        local payout = 0
        local untilT = clickT + 10
        while A.running and alive() and tick() < untilT do
            task.wait(0.15)
            local nowT = tickets()
            if nowT > t0 then payout = nowT - t0; break end
            -- OnClientInvoke un-hides the button ~3s after the click. If no
            -- tickets arrived by then it was a miss (thin target tunnelled), so
            -- don't waste the full 10s before the next shot.
            if btn.Visible and tick() - clickT > 3.2 then
                task.wait(0.4)
                nowT = tickets()
                if nowT > t0 then payout = nowT - t0 end
                break
            end
        end
        return 1, payout, nil, t0, m0
    end

    local function loop(alive)
        local key = A.mode
        local def = MACHINES[key]
        A.tickets0 = tickets()
        A.rounds = 0
        A.gained = 0
        A.status = "Farming " .. (def and def.label or "?") .. " tickets..."
        A.setLabel(A.status)
        log("started mode=" .. tostring(key) .. " tickets=" .. tostring(A.tickets0) .. " money=" .. tostring(money()))
        local fails = 0
        while A.running and alive() do
            if money() < 20000 then
                A.status = "Stopped: not enough money ($20K floor)"
                A.setLabel(A.status)
                log("stopped low money=" .. tostring(money()))
                notify("Arcade", "Arcade stopped — less than $20K left.", 5)
                break
            end
            local punches, payout, err, t0, m0
            if key == "boxing" then
                punches, payout, err, t0, m0 = boxingRound(alive)
            else
                punches, payout, err = basketballRound(alive)
            end
            if not punches then
                fails += 1
                A.status = "Waiting for " .. (def and def.label or "?") .. " (" .. tostring(err or "no frame") .. ")"
                A.setLabel(A.status)
                if fails >= 15 then break end
                task.wait(1.0)
                continue
            end
            fails = 0
            A.plays += punches
            A.rounds += 1
            A.gained += (payout or 0)
            local total = tickets()
            A.status = string.format("%s round %d | +%d tickets | total %d",
                def and def.label or "?", A.rounds, payout or 0, total)
            A.setLabel(A.status)
            log(string.format("round mode=%s punches=%d gained=%d total=%d money=%d",
                tostring(key), punches, payout or 0, total, money()))
            task.wait(0.35)
        end
        A.running = false
        A.status = "Stopped"
        A.setLabel("Status: Stopped")
        log("stopped rounds=" .. tostring(A.rounds) .. " gained=" .. tostring(A.gained) .. " tickets=" .. tostring(tickets()))
    end

    -- Open the Arcade Prize shop so the user can spend tickets (read-only here:
    -- the script just opens it; buying prizes stays manual until asked otherwise).
    local function openPrizeShop(alive)
        local store = myStore()
        local counter = store and store:FindFirstChild("PrizeCounter")
        local prompt = nil
        if counter then
            for _, d in ipairs(counter:GetDescendants()) do
                if d:IsA("ProximityPrompt") then prompt = d; break end
            end
        end
        local hrp = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
        local okp, pivot = pcall(function() return counter and counter:GetPivot() end)
        if hrp and okp and pivot then
            local reach = math.max(3, (prompt and tonumber(prompt.MaxActivationDistance) or 13) - 3)
            if (hrp.Position - pivot.Position).Magnitude > reach and SmartWalkTo then
                pcall(SmartWalkTo, pivot.Position, alive, { reach = reach, maxTime = 30 })
            end
        end
        if prompt and alive() then pcall(fireproximityprompt, prompt) end
        task.wait(0.4)
        local g = mainGui()
        local frame = g and g:FindFirstChild("ArcadePrizeFrame")
        return frame, tickets()
    end

    function A.start(mode, callerToggle)
        if A.running then A.stop() end
        A.mode = mode
        A.plays = 0
        safeSpawn(function()
            pcall(cancelOtherAutomation, callerToggle)
            A.running = true
            safeSpawn(function()
                local ok, err = pcall(loop, function() return A.running and srsAlive() end)
                if not ok then log("crashed: " .. tostring(err)) end
            end)
        end)
        notify("Arcade", "Farming " .. tostring(mode) .. " tickets started.", 3)
    end

    function A.stop()
        if not A.running then return end
        A.running = false
        A.status = "Stopped"
        notify("Arcade", "Arcade farming stopped.", 3)
    end

    -- ── UI ────────────────────────────────────────────────────────────────
    local tab = Tabs.Arcade
    if tab then
        tab:CreateSection("Arcade — AFK Ticket Farming")
        createLabelShim(tab,
            "Plays the store's own arcade minigames on a loop so you can AFK tickets. " ..
            "Walks to the machine, presses Play, then plays the real round. " ..
            "Boxing is the reliable max: 100 punches = +100 Tickets (~11s per round). " ..
            "Basketball auto-aims the swinging arrow, but its paper-thin target can miss. " ..
            "Each round costs $10K; farming stops below $20K.")
        local statusLabel = createLabelShim(tab, "Status: Idle")
        A.setLabel = function(s)
            pcall(function() statusLabel:Set(tostring(s)) end)
        end

        local bbToggle, boxToggle
        bbToggle = tab:CreateToggle({
            Name = "Farm Basketball (auto-aim shot) — $10K per shot",
            CurrentValue = false, Flag = "ArcadeBasketball",
            Callback = function(state)
                if state then A.start("basketball", bbToggle) else A.stop() end
            end,
        })
        if bbToggle.Set == nil and bbToggle.SetValue then bbToggle.Set = bbToggle.SetValue end
        Toggles.ArcadeBasketball = bbToggle

        boxToggle = tab:CreateToggle({
            Name = "Farm Boxing (guaranteed +100) — $10K per round",
            CurrentValue = false, Flag = "ArcadeBoxing",
            Callback = function(state)
                if state then A.start("boxing", boxToggle) else A.stop() end
            end,
        })
        if boxToggle.Set == nil and boxToggle.SetValue then boxToggle.Set = boxToggle.SetValue end
        Toggles.ArcadeBoxing = boxToggle

        tab:CreateButton({
            Name = "Open Arcade Prize Shop",
            Callback = function()
                safeSpawn(function()
                    local frame, tks = openPrizeShop(function() return srsAlive() end)
                    A.setLabel("Prize shop " .. (frame and "open" or "not found") .. " | tickets " .. tostring(tks))
                    notify("Arcade", frame and "Prize shop opened." or "Prize shop did not open.", 3)
                end)
            end,
        })
        tab:CreateButton({
            Name = "Report Tickets (to Script Logs)",
            Callback = function()
                log("tickets now=" .. tostring(tickets()) .. " plays=" .. tostring(A.plays))
                A.setLabel("Tickets: " .. tostring(tickets()))
            end,
        })
        createLabelShim(tab, "AFK tip: leave a farm toggle on and keep this tab open to watch the status line.")
    end

    return A
end)()

-- Programmatic handles (AFK control + live verification).
getgenv().SRS_StartFullAuto = startFullAuto
getgenv().SRS_StopFullAuto  = stopFullAuto
getgenv().SRS_SaveSettings  = saveSettings
getgenv().SRS_Helpers       = Helpers

end -- bootScript()

bootScript()
