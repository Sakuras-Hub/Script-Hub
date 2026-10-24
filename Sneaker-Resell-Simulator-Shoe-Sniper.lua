-- ════════════════════════════════════════════════════════════════
--  SHOE SNIPER  |  Sakura Edition
--  v5 by Sakura's Hub (converted from Rayfield to SakuraUI)
--  v6: faster boot, StockY engine, central buy gates, diagnostics
--
--  Saved configs are unchanged: every ShoeBuyer_*.json / .txt file keeps
--  its name and format, so existing configs keep working.
-- ════════════════════════════════════════════════════════════════
--
--  WHAT'S IN THIS FILE (top to bottom)
--
--   CORE
--     1. BOOT ............... remotes, reload guard, GATES, StockY engine, UI library
--     2. DISK HELPERS ....... read/write settings, blacklist, per-shoe caps, webhook
--     3. SETTINGS ........... saved options and their defaults
--     4. RUNTIME STATE ...... mode flags, connection lists, caches
--     5. UTILITIES .......... number formatting, money, buffered logging
--
--   GAME LOGIC
--     6. TABLE SLOT CACHE ... every market display slot, kept up to date
--     7. SNEAKER MODULE ..... sellable / unsellable data
--     8. INVENTORY + WEBHOOK  sold tracking, Discord messages
--     9. STOCKY CHECKS ...... price caps and filters
--    10. BUYING ............. buyGate -> fireAndConfirm -> trySneaker
--    11. WALK-TO-BUY ........ pathfinding helpers
--    12. SCAN MODES ......... Snipe, Low Price ($1), and the walking variants
--    13. SELLING ............ table helpers, auto-sell loop, flash list
--
--   USER INTERFACE (one section per tab)
--    14. Sniper | Market | Sell & Table | Blacklist | Per-Shoe Caps
--        Settings | Configs | Stats
--
--   END
--    15. STARTUP ............ final wiring, welcome messages
--    16. DIAGNOSTICS ........ status file, SRS_API, remote spy, kill switch
--
--  QUICK REFERENCE
--
--   Tuning gates live (no reload needed):
--       getgenv().SRS_GATES.MaxSessionSpend = 5000
--
--   Gate keys:
--       RequireMoney, MoneyReserve, MoneyStatName   keep buys affordable
--       MinFireInterval, SlotFailCooldown           pacing and per-slot cooldown
--       BreakerFails, BreakerPause                  stop after repeated silent failures
--       MaxSessionSpend                             hard spending cap (0 = off)
--       StockYDiskTTL, StockYAutoRefresh,
--       StockYHardMaxAge, StockYSanityRatio         StockY cache behavior
--
--   Files written while running:
--       srs_status.json    machine-readable state (every 2s)
--       ShoeBuyer_console.log        recent log lines
--       ShoeBuyer_stockycache.json   StockY prices (instant start on re-join)
--
--   Remote control:  getgenv().SRS_API  and  getgenv().SRS_KILL = true
--
-- ════════════════════════════════════════════════════════════════

-- ════════════════════════════════════════════════════════════════
--  BOOT  (v6)
--  Order matters:  remotes -> StockY fetch starts -> UI library -> UI.
--  The StockY request is already in flight while the UI is still loading,
--  and a disk cache makes the first seconds instant on re-joins.
--  (Luau allows only 200 top-level locals per script, so boot helpers live
--   in do-blocks / the Hooks table instead of new top-level locals.)
-- ════════════════════════════════════════════════════════════════

local __L = {} -- holds helpers moved off the 200-local limit
if not game:IsLoaded() then game.Loaded:Wait() end

-- Late-bound hooks: the real log()/notify() are defined further down.
local Hooks = {
    log    = function(tag, msg) print("[SRS][" .. tostring(tag) .. "] " .. tostring(msg)) end,
    notify = function() end,
}
Hooks.fatal = function(msg)
    pcall(function() writefile("srs_err.txt", "SRS BOOT: " .. msg) end)
    error("[SRS] " .. msg, 0)
end
Hooks.waitFor = function(parent, name, timeout)
    if not parent then return nil end
    return parent:FindFirstChild(name) or parent:WaitForChild(name, timeout)
end

local mark
do
    local T0, Marks = os.clock(), {}
    getgenv().SRS_BOOT_MARKS = Marks
    mark = function(name)
        Marks[name] = os.clock() - T0
        Hooks.log("BOOT", string.format("%s @ %.2fs", name, Marks[name]))
    end
end
mark("start")

-- ── Services ──────────────────────────────────────────────────
local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local Players            = game:GetService("Players")
local HttpService        = game:GetService("HttpService")
local RunService         = game:GetService("RunService")
local PathfindingService = game:GetService("PathfindingService")
local LocalPlayer        = Players.LocalPlayer
while not LocalPlayer do task.wait(); LocalPlayer = Players.LocalPlayer end

-- ── Reload hygiene ────────────────────────────────────────────
-- Every load bumps the generation counter. All loops and buy/sell entry
-- points check srsAlive() and go inert once a newer instance has loaded.
getgenv().SRS_ReloadGen = (getgenv().SRS_ReloadGen or 0) + 1
local SRS_GEN = getgenv().SRS_ReloadGen
local function srsAlive()
    return getgenv().SRS_ReloadGen == SRS_GEN
end
getgenv().SRS_KILL = nil
getgenv().SRS_LEAVING = nil
-- canAct: alive AND not leaving AND not killed. Gate for every buy/sell action.
function __L.canAct()
    return srsAlive() and not getgenv().SRS_LEAVING and not getgenv().SRS_KILL
end

-- ── Session tracking (persists across re-runs via getgenv) ────
local sessionStart = tick()
getgenv().TotalMoneySpent     = getgenv().TotalMoneySpent     or 0
getgenv().ShoesBought         = getgenv().ShoesBought         or 0
getgenv().ShoesSold           = getgenv().ShoesSold           or 0
getgenv().MoneyAtSessionStart = getgenv().MoneyAtSessionStart or 0
getgenv().TotalMoneyEarned    = getgenv().TotalMoneyEarned    or 0

-- ── GATES (live-tunable: getgenv().SRS_GATES.<Key> = value, or SRS_API.setGate) ──
local GATES = getgenv().SRS_GATES or {}
getgenv().SRS_GATES = GATES
do
    local function d(k, v) if GATES[k] == nil then GATES[k] = v end end
    d("RequireMoney",      true)   -- refuse a buy the balance can't cover
    d("MoneyReserve",      0)      -- always keep this much cash
    d("MoneyStatName",     "")     -- leaderstats name of your cash (blank = auto: Cash/Money/Bucks/Coins/Balance)
    d("MinFireInterval",   0.03)   -- min seconds between two buy FireServer calls
    d("SlotFailCooldown",  2.5)    -- ignore a slot this long after an unverified buy
    d("BreakerFails",      5)      -- N unverified buys in a row (slot unchanged) opens the breaker
    d("BreakerPause",      15)     -- seconds buying is paused when the breaker opens
    d("MaxSessionSpend",   0)      -- 0 = off. Hard cap on total spend this session
    d("StockYDiskTTL",     1800)   -- disk cache usable for this many seconds after it was saved
    d("StockYAutoRefresh", 300)    -- re-fetch StockY every N seconds
    d("StockYHardMaxAge",  7200)   -- StockY-gated buys stop if the cache is older than this
    d("StockYSanityRatio", 0.25)   -- reject a refresh smaller than this fraction of the current cache
end

-- ── Remote events (bounded waits, clear errors) ───────────────
local RemoteEvents, BuyDisplaySneakerEvent, GetStockYPrices, ChangeDisplaySneaker, RemoveDisplaySneaker
do
    RemoteEvents = Hooks.waitFor(ReplicatedStorage, "RemoteEvents", 30)
    if not RemoteEvents then Hooks.fatal("ReplicatedStorage.RemoteEvents not found after 30s (wrong game or still loading)") end
    BuyDisplaySneakerEvent = Hooks.waitFor(RemoteEvents, "BuyDisplaySneakerEvent", 15)
    if not BuyDisplaySneakerEvent then Hooks.fatal("BuyDisplaySneakerEvent not found after 15s") end
    GetStockYPrices      = Hooks.waitFor(RemoteEvents, "GetStockYPrices",      8)
    ChangeDisplaySneaker = Hooks.waitFor(RemoteEvents, "ChangeDisplaySneaker", 5)
    RemoveDisplaySneaker = Hooks.waitFor(RemoteEvents, "RemoveDisplaySneaker", 5)
    mark("remotes_ready")
    Hooks.log("BOOT", "remotes: Buy=" .. BuyDisplaySneakerEvent.ClassName
        .. " StockY=" .. (GetStockYPrices and GetStockYPrices.ClassName or "MISSING")
        .. " Change=" .. (ChangeDisplaySneaker and ChangeDisplaySneaker.ClassName or "MISSING")
        .. " Remove=" .. (RemoveDisplaySneaker and RemoveDisplaySneaker.ClassName or "MISSING"))
end


-- ════════════════════════════════════════════════════════════════
--  STOCKY ENGINE  (non-blocking, timeout-safe, disk-cached, self-healing)
--    * one request in flight at a time (never stacks InvokeServer calls)
--    * a late reply is still accepted (the invoke thread applies it itself)
--    * failures retry with backoff; a bad/tiny reply never replaces a good cache
--    * auto-refreshes; no manual "press Refresh first" step any more
-- ════════════════════════════════════════════════════════════════

local StockYCache = {}                       -- shoeName -> number (always replaced whole, never half-filled)
local StockY = {
    ready = false, count = 0, version = 0, source = "none",
    updatedAt = nil, inflight = false, inflightSince = nil,
    attempts = 0, failStreak = 0, fetchMs = nil,
    lastErr = nil, lastShape = nil, forceRefresh = false,
}
getgenv().SRS_STOCKY = StockY

do
    local FILE_STOCKY = "ShoeBuyer_stockycache.json"

    local function describeShape(v)
        local t = typeof(v)
        if t ~= "table" then return t .. ":" .. tostring(v):sub(1, 80) end
        local parts, n, total = {}, 0, 0
        for k, x in pairs(v) do
            total += 1
            if n < 3 then
                n += 1
                local xt = typeof(x)
                parts[n] = typeof(k) .. ":" .. tostring(k):sub(1, 30) .. "=" .. xt
                    .. (xt == "table" and "{...}" or (":" .. tostring(x):sub(1, 20)))
            end
        end
        return "table(" .. total .. " keys) e.g. " .. table.concat(parts, " | ")
    end

    -- Accepts { [name]=number } | { [name]={Price=..} } | { {Name=..,Price=..}, ... }
    local PRICE_FIELDS = { "Price", "price", "Value", "value", "StockY", "stockY", "Average", "avg" }
    local NAME_FIELDS  = { "Name", "name", "Shoe", "shoe", "Sneaker", "sneaker" }

    local function toPrice(val, depth)
        if type(val) == "number" then return val end
        if type(val) == "string" then return tonumber((val:gsub("[,$%s]", ""))) end
        if type(val) == "table" and (depth or 0) < 1 then
            for _, f in ipairs(PRICE_FIELDS) do
                local p = toPrice(val[f], 1)       -- handles "1,200" / "$1200" inside a field too
                if p then return p end
            end
        end
        return nil
    end

    local function parseStockY(tbl)
        local out, n = {}, 0
        for k, v in pairs(tbl) do
            local name, price
            if type(k) == "string" then
                name, price = k, toPrice(v)
            elseif type(v) == "table" then
                for _, f in ipairs(NAME_FIELDS) do
                    if type(v[f]) == "string" then name = v[f]; break end
                end
                price = toPrice(v)
            end
            if name and price and price > 0 then out[name] = price; n += 1 end
        end
        return out, n
    end

    local function applyStockY(raw, source, ts)
        if type(raw) ~= "table" then return false, "reply was " .. typeof(raw) end
        local data, n = parseStockY(raw)
        if n == 0 then
            for _, w in ipairs({ "Prices", "prices", "Data", "data", "StockY", "stockY" }) do
                if type(raw[w]) == "table" then data, n = parseStockY(raw[w]); if n > 0 then break end end
            end
        end
        if n == 0 then return false, "no usable prices in reply" end
        if StockY.count >= 20 and n < StockY.count * GATES.StockYSanityRatio then
            return false, "suspiciously small reply (" .. n .. " vs " .. StockY.count .. " cached) - kept old cache"
        end
        StockYCache = data                                -- atomic swap
        StockY.count, StockY.source = n, source
        StockY.updatedAt = ts or os.time()
        StockY.ready, StockY.forceRefresh = true, false
        StockY.version += 1
        return true
    end

    local function saveDisk()
        pcall(function()
            writefile(FILE_STOCKY, HttpService:JSONEncode({ t = StockY.updatedAt, prices = StockYCache }))
        end)
    end

    local function loadDisk()
        local ok, raw = pcall(function()
            if isfile and isfile(FILE_STOCKY) then return readfile(FILE_STOCKY) end
            return nil
        end)
        if not ok or type(raw) ~= "string" or raw == "" then return false end
        local ok2, tbl = pcall(HttpService.JSONDecode, HttpService, raw)
        if not ok2 or type(tbl) ~= "table" or type(tbl.prices) ~= "table" then return false end
        local age = os.time() - (tonumber(tbl.t) or 0)
        if age > GATES.StockYDiskTTL then
            Hooks.log("STOCKY", "disk cache is " .. age .. "s old (> TTL) - ignoring")
            return false
        end
        return (applyStockY(tbl.prices, "disk", tonumber(tbl.t)))
    end

    -- Fire ONE request. Never blocks the caller. Returns false if one is already pending.
    local function fetch()
        if not GetStockYPrices then StockY.lastErr = "remote missing"; return false end
        if StockY.inflight then return false end
        StockY.inflight, StockY.inflightSince = true, os.clock()
        StockY.attempts += 1
        local startedAt = os.clock()
        task.spawn(function()
            local ok, res = pcall(function() return GetStockYPrices:InvokeServer() end)
            StockY.inflight = false
            if not srsAlive() then return end
            StockY.fetchMs = (os.clock() - startedAt) * 1000
            if ok then
                local applied, why = applyStockY(res, "live")
                if applied then
                    StockY.lastErr, StockY.failStreak = nil, 0
                    saveDisk()
                    mark("stocky_live_ok")
                    Hooks.log("STOCKY", string.format("live: %d prices in %.0fms", StockY.count, StockY.fetchMs))
                else
                    StockY.lastErr, StockY.lastShape = why, describeShape(res)
                    StockY.failStreak += 1
                    Hooks.log("STOCKY", "bad reply: " .. tostring(why) .. " | " .. StockY.lastShape)
                end
            else
                StockY.lastErr = tostring(res)
                StockY.failStreak += 1
                Hooks.log("STOCKY", "invoke error: " .. StockY.lastErr)
            end
        end)
        return true
    end

    StockY.usable = function()
        if not StockY.ready then return false, "StockY not loaded yet" end
        local age = os.time() - (StockY.updatedAt or 0)
        if age > GATES.StockYHardMaxAge then return false, "StockY cache is " .. age .. "s old and refresh keeps failing" end
        return true
    end

    local function labelText()
        if StockY.ready then
            local age = os.time() - (StockY.updatedAt or os.time())
            return string.format("StockY prices: %d shoes loaded  (%s, updated %ds ago)%s", StockY.count,
                StockY.source == "disk" and "saved copy" or "live", age,
                StockY.inflight and "  - refreshing..." or "")
        end
        if StockY.inflight then
            return string.format("StockY prices: loading... %ds  (buys that use StockY wait for this)", math.floor(os.clock() - (StockY.inflightSince or os.clock())))
        end
        return "StockY prices: not loaded yet" .. (StockY.lastErr and ("  -  retrying (" .. tostring(StockY.lastErr):sub(1, 50) .. ")") or "")
    end

    -- Instant start from disk (if fresh enough), then the live fetch begins right away.
    if loadDisk() then mark("stocky_disk_loaded") end

    task.spawn(function()
        local BACKOFF = { 2, 4, 8, 15, 30 }
        while srsAlive() do
            if not GetStockYPrices and RemoteEvents then
                GetStockYPrices = RemoteEvents:FindFirstChild("GetStockYPrices")
            end
            local age  = StockY.updatedAt and (os.time() - StockY.updatedAt) or math.huge
            local want = (not StockY.ready) or StockY.forceRefresh or age >= GATES.StockYAutoRefresh
            if want and GetStockYPrices and not StockY.inflight then
                fetch()
                local t0 = tick()
                while StockY.inflight and srsAlive() and tick() - t0 < 60 do task.wait(0.1) end
                if StockY.lastErr and srsAlive() then
                    local d  = BACKOFF[math.min(math.max(StockY.failStreak, 1), #BACKOFF)]
                    local t1 = tick()
                    while srsAlive() and tick() - t1 < d and not StockY.forceRefresh do task.wait(0.25) end
                end
            end
            task.wait(0.25)
        end
    end)

    -- Keep the UI label fresh (label may not exist yet; that's fine)
    task.spawn(function()
        while srsAlive() do
            local lbl = getgenv().SnpStockYLabel
            if lbl then pcall(function() lbl:Set(labelText()) end) end
            task.wait(2)
        end
    end)
end


-- ── World / Inventory references (bounded) ────────────────────
local Tables, Inventory, SellableInventory, UnsellableInventory
do
    Tables    = workspace:FindFirstChild("Tables") or workspace:WaitForChild("Tables", 10)
    Inventory = LocalPlayer:WaitForChild("Inventory", 30)
    if not Inventory then Hooks.fatal("LocalPlayer.Inventory not found after 30s") end
    SellableInventory   = Inventory:WaitForChild("SellableInventory", 15)
    UnsellableInventory = Inventory:WaitForChild("UnsellableInventory", 15)
    if not SellableInventory or not UnsellableInventory then Hooks.fatal("Sellable/Unsellable inventory folders missing") end
    mark("world_ready")
end


-- ── UI Library (SakuraUI, WATERMARK-GATED) ───────────────────
-- The library is only used if its source carries YOUR watermark:
--   * the SAKURAUI_PLAIN marker, or
--   * the "Luau Shield protected build" header (your protected build).
-- Anything else (obfuscated copy, old copy, someone else's copy) is
-- rejected. Loaded from GitHub only (no local files, nothing embedded).
local Library
do
    local URL = "https://raw.githubusercontent.com/Sakuras-Hub/Script-Hub/refs/heads/main/SakuraUI.lua"
    local why = {}
    local function trySource(src, where)
        if type(src) ~= "string" or #src < 100 then why[#why+1] = where .. ": empty/too short"; return nil end
        local watermarked = src:find("SAKURAUI_PLAIN", 1, true)
            or src:sub(1, 60):find("Luau Shield protected build", 1, true)
        if not watermarked then why[#why+1] = where .. ": no watermark (not your build) - rejected"; return nil end
        local chunk, cerr = loadstring(src)
        if not chunk then why[#why+1] = where .. ": compile failed: " .. tostring(cerr); return nil end
        local okR, lib = pcall(chunk)
        if not okR then why[#why+1] = where .. ": run failed: " .. tostring(lib); return nil end
        if type(lib) ~= "table" or not lib.new then why[#why+1] = where .. ": returned no library"; return nil end
        return lib
    end
    -- GitHub only, so the script always runs the newest library. The URL is
    -- cache-busted and the fetch is retried a few times before giving up.
    for attempt = 1, 3 do
        if Library then break end
        local okGet, body = pcall(function() return game:HttpGet(URL .. "?t=" .. tostring(os.time()) .. attempt) end)
        if okGet then Library = trySource(body, "github (try " .. attempt .. ")")
        else why[#why+1] = "github (try " .. attempt .. "): request failed: " .. tostring(body) end
        if not Library and attempt < 3 then task.wait(1.5) end
    end
    if not Library then
        local msg = "SakuraUI failed to load -> " .. table.concat(why, " | ")
            .. "  (the library is loaded from GitHub only; make sure the plain SakuraUI.lua with the SAKURAUI_PLAIN marker is uploaded to the repo)"
        pcall(function() writefile("srs_err.txt", "SAKURA LOADER: " .. msg) end)
        error(msg)
    end
    mark("ui_lib_loaded")
end


-- ── Save file names (same as v5 — your saved configs still work) ──
local FILES = {
    WEBHOOK   = "ShoeBuyer_webhook.txt",
    SETTINGS  = "ShoeBuyer_settings.json",
    BLACKLIST = "ShoeBuyer_blacklist.json",
    MAX_BUY   = "ShoeBuyer_maxbuyprice.json",
    CONFIGS   = "ShoeBuyer_configs.json",
}


-- ════════════════════════════════════════════════════════════════
--  DISK HELPERS  (read / write persistent data)
-- ════════════════════════════════════════════════════════════════

function __L.diskRead(filename)
    local ok, data = pcall(readfile, filename)
    if ok and type(data) == "string" and data ~= "" then return data end
    -- try backup
    local ok2, data2 = pcall(readfile, filename .. ".bak")
    if ok2 and type(data2) == "string" and data2 ~= "" then 
        pcall(function() print("[SRS][SAVE] Loaded backup for " .. filename) end)
        return data2 
    end
    return nil
end

function __L.diskWrite(filename, content)
    -- atomic-ish write via temp file
    pcall(function()
        local tmp = filename .. ".tmp"
        pcall(writefile, tmp, content)
        pcall(writefile, filename, content)
        pcall(function() writefile(filename .. ".bak", content) end)
        pcall(delfile, tmp)
    end)
end

function __L.jsonRead(filename)
    local raw = __L.diskRead(filename)
    if not raw then return nil end
    local ok, tbl = pcall(HttpService.JSONDecode, HttpService, raw)
    if not ok or type(tbl) ~= "table" then
        pcall(function() print("[SRS][SAVE] Failed to decode " .. filename .. ": " .. tostring(tbl)) end)
        return nil
    end
    return tbl
end

function __L.jsonWrite(filename, tbl)
    pcall(function() 
        local encoded = HttpService:JSONEncode(tbl)
        local tmp = filename .. ".tmp"
        writefile(tmp, encoded)
        writefile(filename, encoded)
        pcall(function() writefile(filename .. ".bak", encoded) end)
        pcall(delfile, tmp)
    end)
end

-- ── Webhook ────────────────────────────────────────────────────
function __L.saveWebhook(url)  __L.diskWrite(FILES.WEBHOOK, url) end
function __L.loadWebhook()     return __L.diskRead(FILES.WEBHOOK) or "" end

-- ── Settings ───────────────────────────────────────────────────
function __L.saveSettingsToDisk(s)
    __L.jsonWrite(FILES.SETTINGS, {
        PriceFilter            = s.PriceFilter,
        MaxPrice               = tonumber(s.MaxPrice)               or 100000,
        TargetShoe             = s.TargetShoe,
        Delay                  = tonumber(s.Delay)                  or 0.05,
        UseStockYCheck         = s.UseStockYCheck,
        StockYMargin           = tonumber(s.StockYMargin)           or 1.0,
        UnsellableOnly         = s.UnsellableOnly,
        SellStockYOffsetPct    = tonumber(s.SellStockYOffsetPct)    or 0,
        UseFixedSellPrice      = s.UseFixedSellPrice,
        FixedSellPrice         = tonumber(s.FixedSellPrice)         or 1000,
        AutoSellUnsellableOnly = s.AutoSellUnsellableOnly,
        SnipeCycleWait         = tonumber(s.SnipeCycleWait)         or 0.5,
        OneDollarCycleWait     = tonumber(s.OneDollarCycleWait)     or 0.5,
        AutoSellRefillWait     = tonumber(s.AutoSellRefillWait)     or 3.0,
        AutoSellSlotWait       = tonumber(s.AutoSellSlotWait)       or 0.1,
        FlashListHoldTime      = tonumber(s.FlashListHoldTime)      or 0.5,
        FlashListDelistTime    = tonumber(s.FlashListDelistTime)    or 0.1,
        BuyConfirmPollWait     = tonumber(s.BuyConfirmPollWait)     or 0.08,
        UseOverpayLimit        = s.UseOverpayLimit,
        OverpayLimit           = tonumber(s.OverpayLimit)           or 0,
        BlockNoStockYData      = s.BlockNoStockYData,
        UseMaxPriceFallback    = s.UseMaxPriceFallback,
        MaxPriceFallback       = tonumber(s.MaxPriceFallback)       or 50000,
    })
end

function __L.loadSettingsFromDisk()
    return __L.jsonRead(FILES.SETTINGS) or {}
end

-- ── Blacklist ──────────────────────────────────────────────────
local Blacklist         = {}
local BlacklistMinPrice = 0

function __L.saveBlacklist()
    local arr = {}
    for name in pairs(Blacklist) do table.insert(arr, name) end
    __L.jsonWrite(FILES.BLACKLIST, arr)
end

function __L.loadBlacklist()
    local arr = __L.jsonRead(FILES.BLACKLIST)
    if type(arr) == "table" then
        for _, name in ipairs(arr) do Blacklist[name] = true end
    end
end

__L.loadBlacklist()

function __L.isBlacklisted(shoeName)
    return Blacklist[shoeName] == true
end

-- ── Per-shoe max buy prices ────────────────────────────────────
local MaxBuyPerShoe = {}

function __L.saveMaxBuyPrices()
    __L.jsonWrite(FILES.MAX_BUY, MaxBuyPerShoe)
end

function __L.loadMaxBuyPrices()
    local tbl = __L.jsonRead(FILES.MAX_BUY)
    if type(tbl) == "table" then
        for k, v in pairs(tbl) do
            local n = tonumber(v)
            if type(k) == "string" and n and n > 0 then
                MaxBuyPerShoe[k] = n
            end
        end
    end
end

__L.loadMaxBuyPrices()

function __L.hasMaxBuyPrice(shoe)  return MaxBuyPerShoe[shoe] ~= nil end
function __L.getMaxBuyPrice(shoe)  return MaxBuyPerShoe[shoe] end


-- ════════════════════════════════════════════════════════════════
--  SETTINGS  (loaded from disk, with defaults)
-- ════════════════════════════════════════════════════════════════

local saved = __L.loadSettingsFromDisk()

-- Helper: read a saved boolean with a default
function __L.savedBool(key, default)
    if saved[key] ~= nil then return saved[key] end
    return default
end

local Settings = {
    PriceFilter            = __L.savedBool("PriceFilter",            true),           -- buy only at or under MaxPrice
    MaxPrice               = tonumber(saved.MaxPrice)               or 100000,    -- global price ceiling ($)
    TargetShoe             = saved.TargetShoe                       or "",        -- only shoes whose name contains this (blank = any)
    Delay                  = tonumber(saved.Delay)                  or 0.05,      -- seconds to pause after each buy attempt
    SnipeMode              = false,                                               -- runtime flag, not saved
    OneDollarMode          = false,                                               -- runtime flag, not saved
    WebhookURL             = __L.loadWebhook(),                                       -- Discord webhook (stored in ShoeBuyer_webhook.txt)
    UseStockYCheck         = __L.savedBool("UseStockYCheck",         true),           -- compare listing price against StockY
    StockYMargin           = tonumber(saved.StockYMargin)           or 1.0,       -- max price = StockY x this (1.0 = at StockY)
    UnsellableOnly         = __L.savedBool("UnsellableOnly",         false),          -- only buy unsellable shoes
    AutoSell               = false,                                               -- runtime flag, not saved
    AutoSellUnsellableOnly = __L.savedBool("AutoSellUnsellableOnly", false),          -- auto-sell lists unsellable shoes only
    SellStockYOffsetPct    = tonumber(saved.SellStockYOffsetPct)    or 0,         -- list at StockY plus/minus this percent
    UseFixedSellPrice      = __L.savedBool("UseFixedSellPrice",      false),          -- list everything at FixedSellPrice
    FixedSellPrice         = tonumber(saved.FixedSellPrice)         or 1000,      -- price used when UseFixedSellPrice is on
    SnipeCycleWait         = tonumber(saved.SnipeCycleWait)         or 0.5,       -- seconds between full Snipe sweeps
    OneDollarCycleWait     = tonumber(saved.OneDollarCycleWait)     or 0.5,       -- seconds between full Low Price sweeps
    AutoSellRefillWait     = tonumber(saved.AutoSellRefillWait)     or 3.0,       -- seconds between table refill checks
    AutoSellSlotWait       = tonumber(saved.AutoSellSlotWait)       or 0.1,       -- seconds to wait for a listing to appear
    FlashListHoldTime      = tonumber(saved.FlashListHoldTime)      or 0.5,       -- seconds a flash listing stays up
    FlashListDelistTime    = tonumber(saved.FlashListDelistTime)    or 0.1,       -- seconds between flash listings
    BuyConfirmPollWait     = tonumber(saved.BuyConfirmPollWait)     or 0.08,      -- buy confirm window = this x 10 (minimum 1.5s)
    UseOverpayLimit        = __L.savedBool("UseOverpayLimit",        false),          -- skip listings too far above StockY
    OverpayLimit           = tonumber(saved.OverpayLimit)           or 0,         -- max $ allowed above StockY
    BlockNoStockYData      = __L.savedBool("BlockNoStockYData",      false),          -- skip shoes that have no StockY price
    UseMaxPriceFallback    = __L.savedBool("UseMaxPriceFallback",    true),           -- cap shoes that have no StockY price
    MaxPriceFallback       = tonumber(saved.MaxPriceFallback)       or 50000,     -- that cap ($)
}

-- Numeric keys that need tonumber() before saving
local NUMERIC_KEYS = {
    "StockYMargin","MaxPrice","Delay","FixedSellPrice","SellStockYOffsetPct",
    "SnipeCycleWait","OneDollarCycleWait","AutoSellRefillWait","AutoSellSlotWait",
    "FlashListHoldTime","FlashListDelistTime","BuyConfirmPollWait","OverpayLimit","MaxPriceFallback",
}
local numericKeySet = {}
for _, k in ipairs(NUMERIC_KEYS) do numericKeySet[k] = true end

local function saveSetting(key, value)
    if numericKeySet[key] then value = tonumber(value) or value end
    Settings[key] = value
    __L.saveSettingsToDisk(Settings)
end


-- ════════════════════════════════════════════════════════════════
--  RUNTIME STATE
-- ════════════════════════════════════════════════════════════════

local BuyStats = { Found = 0, Bought = 0, Skipped = 0 }

-- Mode running flags
local SnipeLoopRunning        = false
local OneDollarRunning        = false
local WalkBuySnipeRunning     = false
local WalkBuyOneDollarRunning = false
local SellAllRunning          = false
local SellUnsellRunning       = false
local FlashListRunning        = false
local listAutoRefresh         = false

-- Connection tables (cleared when a mode stops)
local SnipeConnections      = {}
local OneDollarConns        = {}
local WalkBuySnipeConns     = {}
local WalkBuyOneDollarConns = {}
local SellAllConns          = {}
local SellUnsellConns       = {}

-- UI references set later
local SnipeToggleRef
local OneDollarToggleRef
local WalkSnipeToggleRef
local WalkOneDollarToggleRef

-- Wake events for walk modes (so they react instantly when a shoe appears)
local WakeSnipeEvent  = nil
local WakeDollarEvent = nil

-- Sell-tab state
local pendingSellPrice    = 1000
local sellLabelRefs       = {}
local lastSellRefreshTime = nil
local lastListRefreshTime = nil

-- Flash list state
local FlashListCounter    = 0
local FlashListNextDollar = math.random(5, 15)
local flashListedSlot     = nil

-- Low-price mode max price
local OneDollarMaxPrice = 1

-- Log ring-buffer
local MAX_LOG   = 30
local logBuffer = {}
local logHead   = 1

-- StockY price cache + engine live in the BOOT block at the top of the file

-- Last price a shoe was listed at (used for sold webhook)
local lastListedPrice = {}

-- Cached display slots from all tables
local cachedSlots = {}


-- ════════════════════════════════════════════════════════════════
--  UTILITY FUNCTIONS
-- ════════════════════════════════════════════════════════════════

-- Format a number with commas: 1234567 → "1,234,567"
local function commaNum(n)
    n = math.floor(tonumber(n) or 0)
    local s      = tostring(math.abs(n))
    local result = ""
    local len    = #s
    for i = 1, len do
        if i > 1 and (len - i + 1) % 3 == 0 then result = result .. "," end
        result = result .. s:sub(i, i)
    end
    return (n < 0 and "-" or "") .. result
end

local function fmtMoney(n)   return "$" .. commaNum(n) end
function __L.timeSince(t)
    if not t then return "never" end
    return math.floor(tick() - t) .. "s ago"
end

function __L.formatUptime(seconds)
    return string.format("%dd %02dh %02dm %02ds",
        math.floor(seconds / 86400),
        math.floor((seconds % 86400) / 3600),
        math.floor((seconds % 3600) / 60),
        math.floor(seconds % 60))
end

-- Returns the balance, or nil while leaderstats / the cash stat has not loaded
-- yet. getMoney() below is just this with nil turned into 0.
function __L.getMoneyOrNil()
    local ls = LocalPlayer:FindFirstChild("leaderstats")
    if not ls then return nil end
    local custom = GATES.MoneyStatName
    if type(custom) == "string" and custom ~= "" then
        local cv = ls:FindFirstChild(custom)
        local cn = cv and tonumber(cv.Value)
        if cn then return cn end
    end
    for _, name in ipairs({ "Cash", "Money", "Bucks", "Coins", "Balance" }) do
        local v = ls:FindFirstChild(name)
        local n = v and tonumber(v.Value)
        if n then return n end
    end
    for _, v in ipairs(ls:GetChildren()) do
        if v:IsA("NumberValue") or v:IsA("IntValue") then
            local n = tonumber(v.Value)
            if n then return n end
        end
    end
    return nil
end

function __L.getMoney()
    local ls = LocalPlayer:FindFirstChild("leaderstats")
    if not ls then return 0 end
    do
        local n = __L.getMoneyOrNil()
        if n then return n end
    end
    -- Try common currency value names first
    for _, name in ipairs({ "Cash", "Money", "Bucks", "Coins", "Balance" }) do
        local v = ls:FindFirstChild(name)
        if v then return tonumber(v.Value) or 0 end
    end
    -- Fall back to the first NumberValue / IntValue found
    for _, v in ipairs(ls:GetChildren()) do
        if v:IsA("NumberValue") or v:IsA("IntValue") then
            return tonumber(v.Value) or 0
        end
    end
    return 0
end

-- Session baseline. Net profit = balance now - balance at the start.
-- The game creates the money stat at 0 and fills in your real balance a moment
-- later, so a baseline read too early would be 0 and "profit" would equal the
-- whole balance. A jump from 0 to a real balance while nothing has been bought,
-- sold or spent is treated as the balance loading, not as profit.
function __L.ensureMoneyBaseline()
    local g = getgenv()
    local m = __L.getMoneyOrNil()
    if not m then return g.MoneyBaselineSet == true end
    local now = tick()
    if not g.MoneyBaselineSet then
        g.MoneyAtSessionStart = m
        g.MoneyBaselineSet = true
        g.MoneyLocked = false
        g.MoneySeen, g.MoneyChangedAt, g.MoneyStartedAt = m, now, now
        return true
    end
    if g.MoneyLocked then return true end
    local untouched = (g.ShoesBought or 0) == 0 and (g.ShoesSold or 0) == 0
        and (g.TotalMoneySpent or 0) == 0
    if m ~= g.MoneySeen then g.MoneySeen = m; g.MoneyChangedAt = now end
    if untouched then
        -- Still loading: the baseline follows the balance, so profit stays +$0.
        g.MoneyAtSessionStart = m
        -- Lock once the balance is non-zero and has been steady for 1s
        -- (or after 8s, when the balance really is 0).
        if (m > 0 and now - g.MoneyChangedAt >= 1) or now - g.MoneyStartedAt >= 8 then
            g.MoneyLocked = true
        end
    else
        g.MoneyLocked = true
    end
    return true
end

-- Like getMoney() but also says whether the balance came from a *named* currency stat.
-- Gates only enforce on a trusted read, so a wrong guess can never block every buy.
function __L.getMoneyChecked()
    local ls = LocalPlayer:FindFirstChild("leaderstats")
    if not ls then return 0, false end
    local custom = GATES.MoneyStatName
    if type(custom) == "string" and custom ~= "" then
        local v = ls:FindFirstChild(custom)
        if v then local n = tonumber(v.Value); if n then return n, true end end
    end
    for _, name in ipairs({ "Cash", "Money", "Bucks", "Coins", "Balance" }) do
        local v = ls:FindFirstChild(name)
        if v then local n = tonumber(v.Value); if n then return n, true end end
    end
    for _, v in ipairs(ls:GetChildren()) do
        if v:IsA("NumberValue") or v:IsA("IntValue") then return tonumber(v.Value) or 0, false end
    end
    return 0, false
end

-- ── Logging (mirrors to disk, throttled, so we can verify from outside) ──
local log
do
    local pendingLog, flushQueued, fileLines = {}, false, 0
    local function flush()
        flushQueued = false
        if #pendingLog == 0 then return end
        local chunk = table.concat(pendingLog, "\n") .. "\n"
        pendingLog = {}
        if getgenv().SRS_LEAVING then return end
        pcall(function()
            if appendfile then
                appendfile("ShoeBuyer_console.log", chunk)
                fileLines += select(2, chunk:gsub("\n", "\n"))
                if fileLines > 1500 then            -- trim: keep the last 400 lines (rare)
                    fileLines = 0
                    local all, out = readfile("ShoeBuyer_console.log"), {}
                    for l in all:gmatch("[^\r\n]+") do table.insert(out, l) end
                    local keep = {}
                    for i = math.max(1, #out - 400), #out do table.insert(keep, out[i]) end
                    writefile("ShoeBuyer_console.log", table.concat(keep, "\n") .. "\n")
                end
            else
                local cur = (isfile and isfile("ShoeBuyer_console.log")) and readfile("ShoeBuyer_console.log") or ""
                local out = {}
                for l in (cur .. "\n" .. chunk):gmatch("[^\r\n]+") do
                    if #out > 400 then table.remove(out, 1) end
                    table.insert(out, l)
                end
                writefile("ShoeBuyer_console.log", table.concat(out, "\n"))
            end
        end)
    end

    -- v6: lines are buffered and flushed at most every 2s (was: read+rewrite the whole file twice a second)
    log = function(tag, msg)
        local line = "[" .. os.date("%H:%M:%S") .. "][" .. tostring(tag) .. "] " .. tostring(msg)
        print(line)
        logBuffer[logHead] = line
        logHead = (logHead % MAX_LOG) + 1
        table.insert(pendingLog, line)
        if #pendingLog > 200 then table.remove(pendingLog, 1) end
        if not flushQueued then
            flushQueued = true
            task.delay(2, flush)
        end
    end
end


-- ════════════════════════════════════════════════════════════════
--  UI WINDOW + SUB-PAGES (SakuraUI)
-- ════════════════════════════════════════════════════════════════

local Window = Library.new("Shoe Sniper v7 | by Sakura", "SRS_SAKURA")
-- Compact default size scaled to the screen; Resize() also clamps to the viewport.
pcall(function()
    local cam = workspace.CurrentCamera
    local vp = cam and cam.ViewportSize or Vector2.new(1280, 720)
    Window:Resize(UDim2.fromOffset(
        math.clamp(math.floor(vp.X * 0.5), 520, 640),
        math.clamp(math.floor(vp.Y * 0.6), 340, 460)))
end)
pcall(function() Window:_LoadUIPreset("main") end)
pcall(function()
    if Window.topBar then
        local s = Window.topBar:FindFirstChild("Settings")
        if s then s.Image = "rbxassetid://10734950309" end
    end
end)
pcall(function() Window:SetToggleKey(Enum.KeyCode.K) end)
getgenv()._SRSWindow = Window
getgenv()._SRSLib    = Library

-- Organised into groups — everything lives in its own sub-page (tab)
local SectionSniper  = Window:CreateSection("Sniper")
local SectionSell    = Window:CreateSection("Selling")
local SectionFilters = Window:CreateSection("Filters & Caps")
local SectionSystem  = Window:CreateSection("System")

local ScannerTab   = SectionSniper:CreateTab("Sniper", "100604009889706")
local ListTab      = SectionSniper:CreateTab("Market", "10734950309")
local SellTab      = SectionSell:CreateTab("Sell & Table", "10709775704")
local BlacklistTab = SectionFilters:CreateTab("Blacklist", "10747384394")
local MaxBuyTab    = SectionFilters:CreateTab("Per-Shoe Caps", "10734943674")
local SettingsTab  = SectionSystem:CreateTab("Settings", "10723356507")
local ConfigTab    = SectionSystem:CreateTab("Configs", "10723356507")
local StatsTab     = SectionSystem:CreateTab("Dashboard", "120318414957104")

-- Icon guarantee: unwrap Decal IDs, and swap in a bundled icon if an ID
-- fails to load, so no tab is ever left blank.
do
    local FALLBACKS = { "10709775704", "10747384394", "10734950309", "10723356507" }
    local list = {
        { ScannerTab, "100604009889706" }, { ListTab, "10734950309" }, { SellTab, "10709775704" },
        { BlacklistTab, "10747384394" }, { MaxBuyTab, "10734943674" }, { SettingsTab, "10723356507" },
        { ConfigTab, "10723356507" }, { StatsTab, "120318414957104" },
    }
    for i, pair in ipairs(list) do
        local img, id = pair[1] and pair[1].icon, pair[2]
        if img then
            task.spawn(function()
                local good = false
                pcall(function()
                    game:GetService("ContentProvider"):PreloadAsync({ img })
                    good = img.IsLoaded == true
                end)
                if not good then
                    pcall(function()
                        local o = game:GetObjects("rbxassetid://" .. id)[1]
                        if o and o:IsA("Decal") and o.Texture ~= "" then
                            img.Image = o.Texture
                            game:GetService("ContentProvider"):PreloadAsync({ img })
                            good = img.IsLoaded == true
                        end
                    end)
                end
                if not good then pcall(function() img.Image = "rbxassetid://" .. FALLBACKS[(i % #FALLBACKS) + 1] end) end
            end)
        end
    end
end

-- ── Notify (nil-safe wrapper) ───────────────────────────────────
local NOTIFY_ICONS = { Check = "check", X = "error", Alert = "error", Warn = "error" }
local function notify(title, desc, dur, icon)
    if getgenv().NotificationsEnabled == false then return end
    pcall(function()
        local notif = { Title = tostring(title), Description = tostring(desc), Duration = dur or 4 }
        if icon then
            local ico = NOTIFY_ICONS[icon]
            if ico then notif.Icon = ico end
        end
        Window:Notify(notif)
    end)
end

-- Quick notify helper
function __L.notifySuccess(t, d) notify(t, d, 3, "Check") end
function __L.notifyError(t, d) notify(t, d, 5, "X") end
function __L.notifyWarn(t, d) notify(t, d, 4, "Alert") end

Hooks.log, Hooks.notify = log, notify   -- BOOT engine now logs through the real log()

local function setStatus(txt)
    local lbl = getgenv().SnpStatusLabel
    if lbl then pcall(function() lbl:Set("Status: " .. tostring(txt)) end) end
end

local updateStats
do
    local queued = false
    updateStats = function()      -- v6: coalesced to <=4 UI writes/sec (was one per scanned slot)
        if queued then return end
        queued = true
        task.delay(0.25, function()
            queued = false
            local lbl = getgenv().SnpStatsLabel
            if lbl then
                pcall(function()
                    lbl:Set("Listings checked: " .. BuyStats.Found .. "   |   Bought: " .. BuyStats.Bought .. "   |   Skipped: " .. BuyStats.Skipped)
                end)
            end
        end)
    end
end


-- ════════════════════════════════════════════════════════════════
--  DYNAMIC UI HELPERS
--  (custom full-width rows/buttons that can be cleared on rebuild)
-- ════════════════════════════════════════════════════════════════

local okFont, GUIFONT = pcall(function() return Font.new("rbxasset://fonts/families/GothamSSm.json") end)
if not okFont then GUIFONT = Enum.Font.Gotham end

local ROWC = {
    BG     = Color3.fromRGB(23, 19, 38),
    BORDER = Color3.fromRGB(62, 52, 95),
    TEXT   = Color3.fromRGB(232, 234, 246),
    DIM    = Color3.fromRGB(158, 148, 192),
    ACCENT = Color3.fromRGB(255, 95, 175),
    GREEN  = Color3.fromRGB(110, 220, 140),
    RED    = Color3.fromRGB(255, 107, 107),
    WARN   = Color3.fromRGB(255, 209, 102),
}

-- The same 3px accent rail the SakuraUI elements use. Kept on ROWC so it
-- adds no extra top-level local to the main chunk.
ROWC.rail = function(fr, color, visible)
    local rail = Instance.new("Frame")
    rail.Name = "Rail"
    rail.BackgroundColor3 = color or ROWC.ACCENT
    rail.BackgroundTransparency = 0.35
    rail.BorderSizePixel = 0
    rail.AnchorPoint = Vector2.new(0, 0.5)
    rail.Position = UDim2.new(0, 0, 0.5, 0)
    rail.Size = UDim2.new(0, 3, 0.56, 0)
    rail.Visible = visible ~= false
    rail.ZIndex = (fr.ZIndex or 1) + 1
    local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 2); c.Parent = rail
    rail.Parent = fr
    return rail
end

local tabDyn = {}

function __L.dynTrack(tab, inst)
    local list = tabDyn[tab] or {}
    table.insert(list, inst)
    tabDyn[tab] = list
    return inst
end

function __L.dynClear(tab)
    local list = tabDyn[tab] or {}
    tabDyn[tab] = {}
    for _, inst in ipairs(list) do pcall(function() inst:Destroy() end) end
end

-- Full-width text row (label). Returns a handle with :Set(txt)
local function mkRow(tab, text, opts)
    opts = opts or {}
    local isHeader = opts.header == true
    local fr = Instance.new("Frame")
    fr.Name = "DynRow_" .. tostring(opts.name or tick())
    fr.BackgroundColor3 = ROWC.BG
    fr.BackgroundTransparency = opts.transparency or (isHeader and 0.35 or 0.45)
    fr.BorderSizePixel = 0
    fr.Size = UDim2.new(1, 0, 0, 0)
    fr.AutomaticSize = Enum.AutomaticSize.Y
    local uc = Instance.new("UICorner"); uc.CornerRadius = UDim.new(0, 8); uc.Parent = fr
    local lbl = Instance.new("TextLabel")
    if isHeader then
        local okH, hfont = pcall(Font.new, typeof(GUIFONT) == "Font" and GUIFONT.Family or GUIFONT, Enum.FontWeight.Bold, Enum.FontStyle.Normal)
        lbl.FontFace = okH and hfont or GUIFONT
    else
        lbl.FontFace = GUIFONT
    end
    lbl.Text = tostring(text or "")
    lbl.TextColor3 = opts.color or ROWC.TEXT
    lbl.TextSize = isHeader and 16 or 14
    lbl.TextWrapped = true
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.BackgroundTransparency = 1
    lbl.Size = UDim2.new(1, -24, 0, 0)
    lbl.Position = UDim2.new(0, 12, 0, isHeader and 12 or 10)
    lbl.AutomaticSize = Enum.AutomaticSize.Y
    lbl.Parent = fr
    local pad = Instance.new("Frame")
    pad.BackgroundTransparency = 1
    pad.Size = UDim2.new(1, 0, 0, isHeader and 12 or 10)
    pad.Parent = fr
    ROWC.rail(fr, opts.railColor or (isHeader and ROWC.ACCENT or ROWC.DIM), true)
    fr.Parent = tab.content
    if not opts.static then __L.dynTrack(tab, fr) end
    return {
        Set = function(_, txt) lbl.Text = tostring(txt) end,
        GetText = function() return lbl.Text end,
        SetColor = function(_, c) lbl.TextColor3 = c end,
    }
end

-- Full-width action button (custom). Returns a handle with :Set(txt)
function __L.mkBtn(tab, text, cb, opts)
    opts = opts or {}
    local fr = Instance.new("Frame")
    fr.Name = "DynBtn_" .. tostring(opts.name or tick())
    fr.BackgroundColor3 = ROWC.BG
    fr.BackgroundTransparency = 0.35
    fr.BorderSizePixel = 0
    fr.Size = UDim2.new(1, 0, 0, 0)
    fr.AutomaticSize = Enum.AutomaticSize.Y
    local uc = Instance.new("UICorner"); uc.CornerRadius = UDim.new(0, 8); uc.Parent = fr
    local lbl = Instance.new("TextLabel")
    lbl.FontFace = GUIFONT
    lbl.Text = tostring(text or "")
    lbl.TextColor3 = ROWC.TEXT
    lbl.TextSize = 14
    lbl.TextWrapped = true
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.BackgroundTransparency = 1
    lbl.Size = UDim2.new(1, -24, 0, 0)
    lbl.Position = UDim2.new(0, 12, 0, 11)
    lbl.AutomaticSize = Enum.AutomaticSize.Y
    lbl.Parent = fr
    local pad = Instance.new("Frame")
    pad.BackgroundTransparency = 1
    pad.Size = UDim2.new(1, 0, 0, 11)
    pad.Parent = fr
    local btn = Instance.new("TextButton")
    btn.Text = ""
    btn.BackgroundTransparency = 1
    btn.Size = UDim2.new(1, 0, 1, 0)
    btn.Parent = fr
    btn.MouseButton1Click:Connect(function()
        fr.BackgroundTransparency = 0.12
        task.delay(0.12, function() pcall(function() fr.BackgroundTransparency = 0.35 end) end)
        pcall(cb)
    end)
    btn.MouseEnter:Connect(function() fr.BackgroundTransparency = 0.22 end)
    btn.MouseLeave:Connect(function() fr.BackgroundTransparency = 0.35 end)
    ROWC.rail(fr, opts.railColor or ROWC.ACCENT, true)
    fr.Parent = tab.content
    if not opts.static then __L.dynTrack(tab, fr) end
    return {
        Set = function(_, txt) lbl.Text = tostring(txt) end,
        SetText = function(_, txt) lbl.Text = tostring(txt) end,
    }
end

-- One horizontal row: wrapped text on the left + a compact action button on the
-- right. Returns a handle with :Set(leftText) and :SetBtn(btnText).
function __L.mkRowBtn(tab, leftText, btnText, cb, opts)
    opts = opts or {}
    local fr = Instance.new("Frame")
    fr.Name = "DynRowBtn_" .. tostring(opts.name or tick())
    fr.BackgroundColor3 = ROWC.BG
    fr.BackgroundTransparency = opts.transparency or 0.4
    fr.BorderSizePixel = 0
    fr.Size = UDim2.new(1, 0, 0, 0)
    fr.AutomaticSize = Enum.AutomaticSize.Y
    local uc = Instance.new("UICorner"); uc.CornerRadius = UDim.new(0, 8); uc.Parent = fr
    ROWC.rail(fr, opts.railColor or ROWC.ACCENT, true)
    -- The text lives in a body frame so the rail is outside the UIListLayout.
    local body = Instance.new("Frame")
    body.Name = "Body"
    body.BackgroundTransparency = 1
    body.Size = UDim2.new(1, 0, 0, 0)
    body.AutomaticSize = Enum.AutomaticSize.Y
    body.Parent = fr
    local ul = Instance.new("UIListLayout")
    ul.FillDirection = Enum.FillDirection.Vertical
    ul.SortOrder = Enum.SortOrder.LayoutOrder
    ul.Padding = UDim.new(0, 4)
    ul.Parent = body
    local topPad = Instance.new("Frame")
    topPad.BackgroundTransparency = 1
    topPad.Size = UDim2.new(1, 0, 0, 8)
    topPad.LayoutOrder = 0
    topPad.Parent = body
    local lbl = Instance.new("TextLabel")
    lbl.LayoutOrder = 1
    lbl.FontFace = GUIFONT
    lbl.Text = tostring(leftText or "")
    lbl.TextColor3 = ROWC.TEXT
    lbl.TextSize = 14
    lbl.TextWrapped = true
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.BackgroundTransparency = 1
    lbl.Size = UDim2.new(1, -124, 0, 0)
    lbl.AutomaticSize = Enum.AutomaticSize.Y
    lbl.Parent = body
    local sub = nil
    if opts.sub and opts.sub ~= "" then
        sub = Instance.new("TextLabel")
        sub.LayoutOrder = 2
        sub.FontFace = GUIFONT
        sub.Text = tostring(opts.sub)
        sub.TextColor3 = opts.subColor or ROWC.DIM
        sub.TextSize = 12
        sub.TextWrapped = true
        sub.TextXAlignment = Enum.TextXAlignment.Left
        sub.BackgroundTransparency = 1
        sub.Size = UDim2.new(1, -124, 0, 0)
        sub.AutomaticSize = Enum.AutomaticSize.Y
        sub.Parent = body
    end
    local btn = Instance.new("TextButton")
    local okH, hfont = pcall(Font.new, typeof(GUIFONT) == "Font" and GUIFONT.Family or GUIFONT, Enum.FontWeight.Bold, Enum.FontStyle.Normal)
    btn.FontFace = okH and hfont or GUIFONT
    btn.Text = tostring(btnText or "")
    btn.TextColor3 = Color3.new(1, 1, 1)
    btn.TextSize = 14
    btn.BackgroundColor3 = ROWC.ACCENT
    btn.BackgroundTransparency = 0.25
    btn.BorderSizePixel = 0
    btn.Size = UDim2.new(0, 104, 0, 32)
    btn.AnchorPoint = Vector2.new(1, 0.5)
    btn.Position = UDim2.new(1, -12, 0.5, 0)
    local buc = Instance.new("UICorner"); buc.CornerRadius = UDim.new(0, 8); buc.Parent = btn
    btn.Parent = fr
    btn.MouseButton1Click:Connect(function()
        btn.BackgroundTransparency = 0.05
        task.delay(0.12, function() pcall(function() btn.BackgroundTransparency = 0.25 end) end)
        pcall(cb)
    end)
    btn.MouseEnter:Connect(function() btn.BackgroundTransparency = 0.1 end)
    btn.MouseLeave:Connect(function() btn.BackgroundTransparency = 0.25 end)
    local pad = Instance.new("Frame")
    pad.BackgroundTransparency = 1
    pad.Size = UDim2.new(1, 0, 0, 10)
    pad.LayoutOrder = 99
    pad.Parent = body
    fr.Parent = tab.content
    if not opts.static then __L.dynTrack(tab, fr) end
    return {
        Set = function(_, txt) lbl.Text = tostring(txt) end,
        SetBtn = function(_, txt) btn.Text = tostring(txt) end,
        SetSub = sub and function(_, txt) sub.Text = tostring(txt) end or nil,
    }
end

-- One row containing N small equal-width buttons laid out horizontally.
-- buttons = array of { text=, cb= }. Returns the row frame.
function __L.mkBtnGroup(tab, buttons, opts)
    opts = opts or {}
    local fr = Instance.new("Frame")
    fr.Name = "DynBtnGroup_" .. tostring(opts.name or tick())
    fr.BackgroundColor3 = ROWC.BG
    fr.BackgroundTransparency = opts.transparency or 0.45
    fr.BorderSizePixel = 0
    fr.Size = UDim2.new(1, 0, 0, 0)
    fr.AutomaticSize = Enum.AutomaticSize.Y
    local uc = Instance.new("UICorner"); uc.CornerRadius = UDim.new(0, 8); uc.Parent = fr
    local topPad = Instance.new("Frame")
    topPad.BackgroundTransparency = 1
    topPad.Size = UDim2.new(1, 0, 0, 8)
    topPad.Parent = fr
    local inner = Instance.new("Frame")
    inner.BackgroundTransparency = 1
    inner.Size = UDim2.new(1, 0, 0, 0)
    inner.AutomaticSize = Enum.AutomaticSize.Y
    inner.Parent = fr
    local layout = Instance.new("UIListLayout")
    layout.FillDirection = Enum.FillDirection.Horizontal
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Padding = UDim.new(0, 8)
    layout.Parent = inner
    for i, b in ipairs(buttons) do
        local btn = Instance.new("TextButton")
        btn.LayoutOrder = i
        btn.FontFace = GUIFONT
        btn.Text = tostring(b.text or "")
        btn.TextColor3 = ROWC.TEXT
        btn.TextSize = 13
        btn.BackgroundColor3 = ROWC.BG
        btn.BackgroundTransparency = 0.35
        btn.BorderSizePixel = 0
        btn.Size = UDim2.new(1 / #buttons, -4, 0, 30)
        local buc = Instance.new("UICorner"); buc.CornerRadius = UDim.new(0, 8); buc.Parent = btn
        btn.Parent = inner
        btn.MouseButton1Click:Connect(function()
            btn.BackgroundTransparency = 0.12
            task.delay(0.12, function() pcall(function() btn.BackgroundTransparency = 0.35 end) end)
            pcall(b.cb)
        end)
        btn.MouseEnter:Connect(function() btn.BackgroundTransparency = 0.2 end)
        btn.MouseLeave:Connect(function() btn.BackgroundTransparency = 0.35 end)
    end
    local botPad = Instance.new("Frame")
    botPad.BackgroundTransparency = 1
    botPad.Size = UDim2.new(1, 0, 0, 8)
    botPad.Parent = fr
    ROWC.rail(fr, opts.railColor or ROWC.ACCENT, true)
    fr.Parent = tab.content
    if not opts.static then __L.dynTrack(tab, fr) end
    return fr
end

-- ── Readability pass for the text above the buttons ─────────────────────
-- Paragraph cards get shorter lines, bigger and brighter text and more line
-- spacing. Buttons, toggles and the dashboard tab are not touched. Lives on
-- ROWC so the main chunk spends no extra locals (it is near the 200 limit).
ROWC.readable = function(text)
    text = tostring(text or "")
    if #text < 70 or text:find("<", 1, true) then return text end
    local out = {}
    for chunk in (text .. "\n"):gmatch("(.-)\n") do
        if #chunk > 70 then
            local cur = 1
            while true do
                local a, b = chunk:find("[%.!%?] +%u", cur)
                if not a then break end
                table.insert(out, chunk:sub(cur, a))
                cur = b
            end
            table.insert(out, chunk:sub(cur))
        else
            table.insert(out, chunk)
        end
    end
    for i, ln in ipairs(out) do
        ln = ln:gsub("^%s+", "")
        local lead, rest = ln:match("^(%u[%u%s/]+:)%s*(.*)$")
        if lead and #lead >= 4 then ln = "<b>" .. lead .. "</b> " .. rest end
        out[i] = ln
    end
    return table.concat(out, "\n\n")
end
ROWC.polishText = function(root)
    pcall(function()
        local objs = root:GetDescendants()
        table.insert(objs, root)
        for _, o in ipairs(objs) do
            if o:IsA("TextLabel") then
                o.RichText = true
                o.TextWrapped = true
                o.TextSize = math.max(o.TextSize + 1, 16)
                pcall(function() o.LineHeight = 1.15 end)
                local _h, sat, v = o.TextColor3:ToHSV()
                if sat < 0.35 and v < 0.95 then o.TextColor3 = Color3.fromRGB(236, 238, 248) end
                o.TextTransparency = 0
            end
        end
    end)
end
ROWC.polishTabs = function(list)
    for _, tb in ipairs(list) do
        local orig = tb.CreateParagraph
        if type(orig) == "function" then
            tb.CreateParagraph = function(self, props, ...)
                if type(props) == "table" and type(props.Content) == "string" then
                    props = table.clone(props)
                    props.Content = ROWC.readable(props.Content)
                end
                local before = {}
                local content = self.content
                if content then
                    for _, c in ipairs(content:GetChildren()) do before[c] = true end
                end
                local res = orig(self, props, ...)
                if content then
                    for _, c in ipairs(content:GetChildren()) do
                        if not before[c] and not c:IsA("UIListLayout") and not c:IsA("UIPadding") then
                            ROWC.polishText(c)
                        end
                    end
                end
                return res
            end
        end
    end
end
ROWC.polishTabs({ ScannerTab, ListTab, SellTab, BlacklistTab, MaxBuyTab, SettingsTab, ConfigTab })

-- Section header from the library (pip + uppercase label + fading rule) so
-- dynamically built sections match the static ones. Tracked for dynClear.
function __L.mkSection(tab, title, opts)
    opts = opts or {}
    local header = tab:CreateSection(tostring(title or ""))
    local label = header:IsA("TextLabel") and header or header:FindFirstChild("SectionLabel")
    if not opts.static then __L.dynTrack(tab, header) end
    return {
        Set = function(_, txt)
            if not label then return end
            label.Text = string.upper((tostring(txt or ""):gsub("[─━═]+", " "):gsub("%s+", " ")))
        end,
    }
end


-- ════════════════════════════════════════════════════════════════
--  STATUS CARD  (replaces the five plain text rows at the top of the
--  Sniper tab). Handles keep the same :Set("Label: value") API, so
--  nothing else in the script had to change.
-- ════════════════════════════════════════════════════════════════
ROWC.statusCard = function(tab)
    local function bold()
        local ok, f = pcall(Font.new, "rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Bold, Enum.FontStyle.Normal)
        return ok and f or GUIFONT
    end
    local function new(class, props, parent)
        local o = Instance.new(class)
        for k, v in pairs(props) do o[k] = v end
        o.Parent = parent
        return o
    end
    local function round(o, r) new("UICorner", { CornerRadius = UDim.new(0, r) }, o) end
    local function label(parent, text, size, color, boldText, props)
        local p = { BackgroundTransparency = 1, Text = text, TextSize = size, TextColor3 = color,
                    TextXAlignment = Enum.TextXAlignment.Left, RichText = false }
        p.FontFace = boldText and bold() or GUIFONT
        for k, v in pairs(props or {}) do p[k] = v end
        return new("TextLabel", p, parent)
    end
    local TONE = { ok = ROWC.GREEN, warn = ROWC.WARN, bad = ROWC.RED, idle = ROWC.DIM }

    local card = new("Frame", {
        Name = "StatusCard", BackgroundColor3 = ROWC.BG, BackgroundTransparency = 0.1,
        BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
    })
    round(card, 8)
    new("UIStroke", { Color = ROWC.BORDER, Transparency = 0.35, Thickness = 1 }, card)
    new("UIPadding", { PaddingTop = UDim.new(0, 9), PaddingBottom = UDim.new(0, 9),
                       PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12) }, card)
    new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 6) }, card)

    -- header: current activity on the left, state pill on the right
    local head = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 20), LayoutOrder = 1 }, card)
    local doing = label(head, "Idle  (nothing is running yet)", 13, ROWC.TEXT, true, {
        Size = UDim2.new(1, -86, 1, 0), TextTruncate = Enum.TextTruncate.AtEnd })
    local pill = label(head, "● IDLE", 10, ROWC.DIM, true, {
        AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, 0, 0.5, 0),
        Size = UDim2.new(0, 0, 0, 18), AutomaticSize = Enum.AutomaticSize.X,
        BackgroundTransparency = 0.82, BackgroundColor3 = ROWC.DIM, TextXAlignment = Enum.TextXAlignment.Center,
    })
    round(pill, 9)
    new("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }, pill)

    -- three counters, number and caption on one line each
    local tiles = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 30), LayoutOrder = 2 }, card)
    new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, SortOrder = Enum.SortOrder.LayoutOrder,
                          Padding = UDim.new(0, 6) }, tiles)
    local tileNum, tileCap = {}, {}
    local defaults = { "CHECKED", "BOUGHT", "SKIPPED" }
    for i = 1, 3 do
        local t = new("Frame", { BackgroundColor3 = ROWC.BORDER, BackgroundTransparency = 0.6, BorderSizePixel = 0,
                                 Size = UDim2.new(1 / 3, -4, 1, 0), LayoutOrder = i }, tiles)
        round(t, 6)
        tileNum[i] = label(t, "0", 15, i == 2 and ROWC.GREEN or ROWC.TEXT, true, {
            Position = UDim2.new(0, 10, 0, 0), Size = UDim2.new(0.45, -10, 1, 0), TextTruncate = Enum.TextTruncate.AtEnd })
        tileCap[i] = label(t, defaults[i], 9, ROWC.DIM, true, {
            Position = UDim2.new(0.45, 0, 0, 0), Size = UDim2.new(0.55, -8, 1, 0),
            TextXAlignment = Enum.TextXAlignment.Right, TextTruncate = Enum.TextTruncate.AtEnd })
    end

    -- compact label / value rows
    local function infoRow(name, order)
        local r = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0),
                                 AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = order }, card)
        label(r, name, 12, ROWC.DIM, false, { Size = UDim2.new(0.3, 0, 0, 16) })
        return label(r, "...", 12, ROWC.TEXT, true, {
            Position = UDim2.new(0.3, 0, 0, 0), Size = UDim2.new(0.7, 0, 0, 0),
            AutomaticSize = Enum.AutomaticSize.Y, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top })
    end
    local syVal  = infoRow("StockY prices", 3)
    local shVal  = infoRow("Shoe data", 4)
    local whyVal = infoRow("Skipped because", 5)

    local function after(txt)  -- "Label: value"  ->  value
        local v = tostring(txt):match("^[^:]-:%s*(.*)$")
        return v or tostring(txt)
    end
    local function tone(v)
        local l = v:lower()
        if l:find("fail") or l:find("error") or l:find("not loaded") then return ROWC.RED end
        if l:find("loading") or l:find("retry") then return ROWC.WARN end
        if l:find("loaded") or l:find("ready") then return ROWC.GREEN end
        return ROWC.TEXT
    end

    local H = { Frame = card }
    H.Status = { Set = function(_, txt)
        local v = after(txt)
        local l = v:lower()
        local state = "ok"
        if l:find("error") or l:find("fail") then state = "bad"
        elseif l:find("paus") or l:find("wait") then state = "warn"
        elseif l:find("idle") or l:find("nothing") or l:find("stopped") then state = "idle" end
        local c = TONE[state]
        doing.Text = v
        doing.TextColor3 = state == "idle" and ROWC.TEXT or c
        pill.Text = "● " .. (state == "idle" and "IDLE" or state == "warn" and "PAUSED" or state == "bad" and "ERROR" or "RUNNING")
        pill.TextColor3 = c
        pill.BackgroundColor3 = c
    end }
    H.Stats = { Set = function(_, txt)
        local i = 0
        for seg in tostring(txt):gmatch("[^|]+") do
            i = i + 1
            if i > 3 then break end
            local name, n = seg:match("^%s*(.-)%s*:%s*(.-)%s*$")
            if name and tileNum[i] then
                tileNum[i].Text = n
                tileCap[i].Text = (name:gsub("^[Ll]istings ", "")):upper()
            end
        end
    end }
    H.StockY = { Set = function(_, txt) local v = after(txt); syVal.Text = v; syVal.TextColor3 = tone(v) end }
    H.Shoe   = { Set = function(_, txt) local v = after(txt); shVal.Text = v; shVal.TextColor3 = tone(v) end }
    H.Why    = { Set = function(_, txt)
        local v = after(txt):gsub("%s*|%s*", "   ·   ")
        whyVal.Text = v
        whyVal.TextColor3 = v:lower():find("nothing yet") and ROWC.DIM or ROWC.TEXT
    end }
    card.Parent = tab.content
    return H
end

-- Native Sakura textbox that is also tracked for clearing
function __L.dynTextBox(tab, opts)
    local name  = tostring(opts.Name or "TextBox")
    local box   = tab:CreateTextBox(opts)
    local found = nil
    for _, c in ipairs(tab.content:GetChildren()) do
        if c:IsA("Frame") and c.Name == "TextBox_" .. name then found = c end
    end
    if found then __L.dynTrack(tab, found) end
    return box
end

-- Native Sakura toggle that is also tracked for clearing
function __L.dynToggle(tab, opts)
    local name  = tostring(opts.Name or "Toggle")
    local tgl   = tab:CreateToggle(opts)
    local found = nil
    for _, c in ipairs(tab.content:GetChildren()) do
        if c:IsA("Frame") and c.Name == "Toggle_" .. name then found = c end
    end
    if found then __L.dynTrack(tab, found) end
    return tgl
end

-- ════════════════════════════════════════════════════════════════
--  TABLE SLOT CACHE
-- ════════════════════════════════════════════════════════════════

local rebuildSlotCache, wireTableEvents
do
    local set = {}
    local function addSlot(slot)
        if slot and not set[slot] then
            set[slot] = true
            table.insert(cachedSlots, slot)
        end
    end

    rebuildSlotCache = function()
        if not Tables then return end
        cachedSlots, set = {}, {}
        for _, tableModel in ipairs(Tables:GetChildren()) do
            if tableModel.Name == "Table" then
                for i = 1, 6 do addSlot(tableModel:FindFirstChild("DisplaySneaker" .. i)) end
            end
        end
    end

    -- Keep cache up to date when tables are added / removed
    wireTableEvents = function()
        if not Tables then return end
        Tables.ChildAdded:Connect(function(tableModel)
            task.wait(0.3)
            if tableModel.Name == "Table" then
                for i = 1, 6 do addSlot(tableModel:FindFirstChild("DisplaySneaker" .. i)) end
            end
        end)
        Tables.ChildRemoved:Connect(function()
            task.spawn(rebuildSlotCache)
        end)
    end
end
wireTableEvents()


-- ════════════════════════════════════════════════════════════════
--  SNEAKER MODULE  (provides sellable / unsellable / rarity data)
-- ════════════════════════════════════════════════════════════════

local SneakerModule       = nil
local SneakerModuleLoaded = false

function __L.getSneakerData(shoeName)
    if not SneakerModuleLoaded or not SneakerModule then return nil end
    if type(SneakerModule.sneakers) ~= "table" then return nil end
    return SneakerModule.sneakers[shoeName]
end

function __L.isUnsellable(shoeName)
    -- Check the module first (most reliable)
    local data = __L.getSneakerData(shoeName)
    if data ~= nil then
        return type(data) == "table" and table.find(data, "Unsellable") ~= nil
    end
    -- Fall back to checking if the player owns it in the unsellable folder
    for _, item in ipairs(UnsellableInventory:GetChildren()) do
        if item.Name == shoeName then return true end
    end
    return false
end

function __L.loadSneakerModule()
    local ok, result = pcall(function()
        return require(ReplicatedStorage:WaitForChild("SneakerModule"))
    end)
    if ok and type(result) == "table" and type(result.sneakers) == "table" then
        SneakerModule       = result
        SneakerModuleLoaded = true
        local total, unsellCount = 0, 0
        for _, data in pairs(SneakerModule.sneakers) do
            total += 1
            if type(data) == "table" and table.find(data, "Unsellable") then unsellCount += 1 end
        end
        log("MODULE", "Loaded: " .. total .. " shoes, " .. unsellCount .. " unsellable")
        local _sml = getgenv().SnpSneakerModLabel
        if _sml then pcall(function() _sml:Set("Shoe data: loaded  (" .. total .. " shoes, " .. unsellCount .. " are unsellable)") end) end
    else
        log("MODULE", "Failed: " .. tostring(result))
        local _sml = getgenv().SnpSneakerModLabel
        if _sml then pcall(function() _sml:Set("Shoe data: FAILED to load  -  press Reload Shoe Data at the bottom of this tab") end) end
    end
end

function __L.buildUnsellableCache()
    if SneakerModuleLoaded and SneakerModule and type(SneakerModule.sneakers) == "table" then
        local count = 0
        for _, data in pairs(SneakerModule.sneakers) do
            if type(data) == "table" and table.find(data, "Unsellable") then count += 1 end
        end
        notify("Unsellable Cache", count .. " unsellable shoes identified.", 4)
    else
        notify("Unsellable Cache", "SneakerModule not loaded!", 6)
    end
end


-- ════════════════════════════════════════════════════════════════
--  INVENTORY HELPERS
-- ════════════════════════════════════════════════════════════════

function __L.isSellable(shoeName)
    for _, item in ipairs(SellableInventory:GetChildren()) do
        if item.Name == shoeName then return true end
    end
    return false
end

function __L.ownsUnsellable(shoeName)
    for _, item in ipairs(UnsellableInventory:GetChildren()) do
        if item.Name == shoeName then return true end
    end
    return false
end

-- Sold-shoe tracking
local trackedSellable = {}

function __L.initSoldTracking()
    for _, item in ipairs(SellableInventory:GetChildren()) do
        trackedSellable[item] = true
    end
    SellableInventory.ChildRemoved:Connect(function(item)
        if trackedSellable[item] then
            trackedSellable[item] = nil
            getgenv().ShoesSold += 1
            log("SOLD", item.Name .. " | total: " .. getgenv().ShoesSold)
        end
    end)
    SellableInventory.ChildAdded:Connect(function(item)
        trackedSellable[item] = true
    end)
end


-- ════════════════════════════════════════════════════════════════
--  WEBHOOK (Dashboard Style)
-- ════════════════════════════════════════════════════════════════

local SAKURAS_SOCIALS_URL = "https://sakuras-hub.github.io/Sakuras-Hub/"

local WEBHOOK_COLOR   = 0xFF5FAF
local WEBHOOK_AVATAR  = "https://i.imgur.com/NambJ9Q.gif"
local WEBHOOK_FOOTER  = { text = "SRS V7 by Sakura's Hub" }

function __L.buildSessionStats()
    local money  = __L.getMoney()
    local start  = getgenv().MoneyAtSessionStart or money
    if __L.ensureMoneyBaseline then __L.ensureMoneyBaseline() end
    start = getgenv().MoneyAtSessionStart or start
    local net    = money - start
    local netStr = net >= 0 and ("+$" .. commaNum(net)) or ("-$" .. commaNum(math.abs(net)))
    return table.concat({
        "",
        "**——— Session Stats ———**",
        "**Current Money:**  " .. fmtMoney(money),
        "**Total Spent:**    " .. fmtMoney(getgenv().TotalMoneySpent or 0),
        "**Net Profit:**     " .. netStr,
        "**Shoes Bought:**   " .. tostring(getgenv().ShoesBought or 0),
        "**Shoes Sold:**     " .. tostring(getgenv().ShoesSold   or 0),
        "**Uptime:**         " .. __L.formatUptime(tick() - sessionStart),
        "",
        "🔗 **[Sakura's Socials](" .. SAKURAS_SOCIALS_URL .. ")**",
    }, "\n")
end

function __L.getHttpRequest()
    if type(syn) == "table"  and type(syn.request) == "function" then return syn.request end
    if type(http) == "table" and type(http.request) == "function" then return http.request end
    if type(request) == "function" then return request end
    if type(HttpService.RequestAsync) == "function" then
        return function(opts) return HttpService:RequestAsync(opts) end
    end
    return nil
end

function __L.sendWebhookRaw(payload)
    if Settings.WebhookURL == "" then return end
    if getgenv().SRS_LEAVING then return end
    local fn = __L.getHttpRequest()
    if not fn then warn("[Webhook] No HTTP request function."); return end
    pcall(function()
        fn({
            Url     = Settings.WebhookURL,
            Method  = "POST",
            Headers = { ["Content-Type"] = "application/json" },
            Body    = HttpService:JSONEncode(payload),
        })
    end)
end

function __L.postWebhookDashboard(username, title, description)
    if Settings.WebhookURL == "" then return end
    if getgenv().SRS_LEAVING then return end
    local desc = tostring(description or "")
    if desc ~= "" and desc:sub(-1) ~= "\n" then desc = desc .. "\n" end
    desc = desc .. __L.buildSessionStats()
    local data = {
        username   = tostring(username or "SRS | by Sakura's Hub"),
        avatar_url = WEBHOOK_AVATAR,
        embeds = {{
            title       = tostring(title or ""),
            description = desc,
            color       = WEBHOOK_COLOR,
            footer      = WEBHOOK_FOOTER,
            timestamp   = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        }},
    }
    __L.sendWebhookRaw(data)
end

function __L.sendWebhook(shoeName, price, confirmed, titlePrefix, sellerName)
    if Settings.WebhookURL == "" then return end
    local title = (titlePrefix or (confirmed and "BOUGHT" or "COULD NOT VERIFY")) .. " - " .. tostring(shoeName)
    local desc  = "**Shoe:** " .. tostring(shoeName)
        .. "\n**Price:** " .. fmtMoney(price)
        .. "\n**Bought From:** " .. tostring(sellerName or "Unknown")
        .. "\n**Balance After:** " .. fmtMoney(__L.getMoney()) .. "\n"
    __L.postWebhookDashboard("SRS Full Automation | by Sakura's Hub", title, desc)
end

function __L.sendSoldWebhook(shoeName, listPrice)
    if Settings.WebhookURL == "" then return end
    local desc = "**Shoe:** " .. tostring(shoeName)
        .. "\n**Sold For:** " .. fmtMoney(listPrice or 0)
        .. "\n**Balance After:** " .. fmtMoney(__L.getMoney()) .. "\n"
    __L.postWebhookDashboard("SRS | by Sakura's Hub", "SOLD - " .. tostring(shoeName), desc)
end

function __L.sendKickWebhook(reason)
    if Settings.WebhookURL == "" then return end
    local desc = "**Event:** " .. tostring(reason or "Game closed / Kicked") .. "\n"
    __L.postWebhookDashboard("SRS Detections | by Sakura's Hub", "Game Closed / Kicked", desc)
end

-- Also fire a sold webhook whenever an item leaves the sellable inventory
SellableInventory.ChildRemoved:Connect(function(item)
    local price = lastListedPrice[item.Name] or 0
    task.spawn(function()
        task.wait(0.5)
        __L.sendSoldWebhook(item.Name, price)
    end)
end)


-- ════════════════════════════════════════════════════════════════
--  STOCKY PRICE CHECKS + SKIP COUNTERS  (the engine itself lives in BOOT)
-- ════════════════════════════════════════════════════════════════

-- All buy-side runtime state in ONE table (Luau caps a script at 200 top-level locals).
local BuyState = {
    inflight = 0,            -- prices fired but not yet resolved (so concurrent buys can't overspend)
    lastFireAt = 0, breakerUntil = 0, streak = 0, lastBuyAt = nil,
    skips = {},              -- reason -> count (visible in the status file / SRS_API)
    cool  = setmetatable({}, { __mode = "k" }),   -- slot -> tick() until which it is ignored
}
getgenv().SRS_SKIPS = BuyState.skips
local function skip(reason) BuyState.skips[reason] = (BuyState.skips[reason] or 0) + 1 end

local logThrottled
do
    local lastLogAt = {}
    logThrottled = function(key, interval, tag, msg)
        local now = tick()
        if (lastLogAt[key] or 0) + interval > now then return end
        lastLogAt[key] = now
        log(tag, msg)
    end
end

-- Manual "force refresh" (button). Non-blocking engine does the work; this just reports.
function __L.refreshStockY()
    if not GetStockYPrices then
        log("STOCKY", "Remote not found")
        notify("StockY Error", "Remote not found!", 6, "X")
        return
    end
    local v0 = StockY.version
    StockY.forceRefresh = true
    notify("StockY", "Refreshing...", 3)
    local t0 = tick()
    while srsAlive() and tick() - t0 < 60 do
        if StockY.version ~= v0 then
            notify("StockY", StockY.count .. " prices cached (" .. string.format("%.1fs", (StockY.fetchMs or 0) / 1000) .. ").", 5)
            return
        end
        task.wait(0.1)
    end
    notify("StockY Error", tostring(StockY.lastErr or "server hasn't replied yet - still retrying in background"), 6, "X")
end

-- Returns true if it is OK to buy this shoe at this price (checks StockY, overpay, fallback)
function __L.stockYOk(shoeName, price)
    -- GATE: StockY-based checks need data. Hold (don't guess) until it has loaded.
    if Settings.UseStockYCheck then
        local usable, why = StockY.usable()
        if not usable then
            logThrottled("stocky_gate", 5, "STOCKY", "GATE " .. why .. " - buys held until prices are available")
            skip("stocky_not_ready"); BuyStats.Skipped += 1; updateStats()
            return false
        end
    end

    local stockYPrice = StockYCache[shoeName]
    local hasData     = type(stockYPrice) == "number" and stockYPrice > 0

    -- No StockY data for this shoe
    if not hasData then
        if Settings.UseMaxPriceFallback then
            local fallback = tonumber(Settings.MaxPriceFallback) or 50000
            if price > fallback then
                logThrottled("fb:" .. shoeName, 10, "FALLBACK", "SKIP " .. shoeName .. " price " .. fmtMoney(price) .. " > fallback " .. fmtMoney(fallback))
                skip("fallback_cap"); BuyStats.Skipped += 1; updateStats()
                return false
            end
            return true
        end
        if Settings.UseStockYCheck and Settings.BlockNoStockYData then
            logThrottled("nd:" .. shoeName, 10, "STOCKY", "SKIP " .. shoeName .. " no StockY data")
            skip("no_stocky_data"); BuyStats.Skipped += 1; updateStats()
            return false
        end
        return true
    end

    -- Overpay limiter: skip if listing price is too far above StockY
    if Settings.UseOverpayLimit then
        local maxOverpay = tonumber(Settings.OverpayLimit) or 0
        local overpay    = price - stockYPrice
        if overpay > maxOverpay then
            logThrottled("op:" .. shoeName, 10, "OVERPAY", "SKIP " .. shoeName .. " overpay " .. fmtMoney(overpay) .. " > limit " .. fmtMoney(maxOverpay))
            skip("overpay"); BuyStats.Skipped += 1; updateStats()
            return false
        end
    end

    -- StockY margin: skip if price is more than (StockY * margin)
    if Settings.UseStockYCheck then
        local margin = tonumber(Settings.StockYMargin) or 1.0
        local cap    = stockYPrice * margin
        if price > cap then
            logThrottled("sy:" .. shoeName, 10, "STOCKY", "SKIP " .. shoeName .. " " .. fmtMoney(price) .. " > cap " .. fmtMoney(math.floor(cap)))
            skip("stocky_cap"); BuyStats.Skipped += 1; updateStats()
            return false
        end
    end

    return true
end


-- ════════════════════════════════════════════════════════════════
--  BUYING LOGIC  (v6: every auto-buy passes through buyGate)
-- ════════════════════════════════════════════════════════════════

local buyDebounce = setmetatable({}, { __mode = "k" })  -- slot -> tick() of lock

-- Slot lock: one buy per slot at a time. Auto-expires so a stuck buy can't wedge a slot forever.
function __L.acquireSlotLock(slot)
    if typeof(slot) ~= "Instance" or not slot.Parent then return false end
    local t = buyDebounce[slot]
    if t and tick() - t < 6 then return false end
    buyDebounce[slot] = tick()
    return true
end

function __L.releaseSlotLock(slot)
    buyDebounce[slot] = nil
end

-- Prune expired slot cooldowns periodically
task.spawn(function()
    while srsAlive() do
        task.wait(45)
        if not srsAlive() then break end
        local now = tick()
        for slot, t in pairs(BuyState.cool) do
            if typeof(slot) == "Instance" and slot.Parent then
                if type(t) == "number" and now > t + 90 then
                    BuyState.cool[slot] = nil
                end
            else
                BuyState.cool[slot] = nil
            end
        end
        -- prune buyDebounce
        for slot, t in pairs(buyDebounce) do
            if typeof(slot) == "Instance" and slot.Parent then
                if type(t) == "number" and now - t > 15 then
                    buyDebounce[slot] = nil
                end
            else
                buyDebounce[slot] = nil
            end
        end
    end
end)

-- THE gate. Returns true, or false + reason. `manual` = clicked in the Market tab.
function __L.buyGate(slot, shoeName, price, manual)
    if not __L.canAct() then return false, "inactive" end
    if not slot or not slot.Parent then return false, "slot_gone" end

    local sv = slot:FindFirstChild("SneakerValue")
    local pv = slot:FindFirstChild("Price")
    local db = slot:FindFirstChild("SellDebounce")
    if not sv or tostring(sv.Value) ~= shoeName then return false, "listing_changed" end
    if db and db.Value == true then return false, "already_sold" end
    local live = tonumber(pv and pv.Value)
    if not live or live < 1 then return false, "bad_price" end
    if live ~= price then return false, "price_changed" end
    if not BuyDisplaySneakerEvent or not BuyDisplaySneakerEvent.Parent then return false, "remote_missing" end

    if not manual then
        local now = tick()
        if now < BuyState.breakerUntil then return false, "breaker_open" end
        if (BuyState.cool[slot] or 0) > now then return false, "slot_cooldown" end
        local cap = tonumber(GATES.MaxSessionSpend) or 0
        if cap > 0 and (getgenv().TotalMoneySpent or 0) + BuyState.inflight + price > cap then
            return false, "spend_cap"
        end
    end

    if GATES.RequireMoney then
        local money, known = __L.getMoneyChecked()
        if known and money - BuyState.inflight - (tonumber(GATES.MoneyReserve) or 0) < price then
            return false, "insufficient_funds"
        end
    end
    return true
end

-- Gate -> fire -> confirm. Auto modes confirm in the background so the scan loop never stalls.
-- Releases the slot lock when finished (callers must NOT release it themselves).
function __L.fireAndConfirm(slot, shoeName, price, fromListTab)
    local inflightAdded = false
    local released = false
    local function safeRelease()
        if released then return end
        released = true
        pcall(__L.releaseSlotLock, slot)
    end
    local function safeDecrInflight()
        if inflightAdded then
            inflightAdded = false
            BuyState.inflight = math.max(0, BuyState.inflight - price)
        end
    end
    local ok, why = __L.buyGate(slot, shoeName, price, fromListTab)
    if not ok then
        skip(why)
        logThrottled("gate:" .. why .. ":" .. shoeName, 5, "GATE", why .. " - " .. shoeName .. " " .. fmtMoney(price))
        safeRelease()
        if fromListTab then notify("List Buy", "Blocked: " .. why, 4, "X") end
        return false
    end

    -- Tiny spacing between consecutive fires (ticket system, so parallel callers queue instead of dropping)
    if not fromListTab then
        local now = tick()
        local at  = math.max(now, BuyState.lastFireAt + (tonumber(GATES.MinFireInterval) or 0))
        BuyState.lastFireAt = at
        if at > now then task.wait(at - now) end
        local db = slot:FindFirstChild("SellDebounce")
        if not slot.Parent or (db and db.Value == true) then
            skip("sold_during_ticket"); safeRelease(); return false
        end
    end

    local sellerName = "Unknown"
    pcall(function()
        local ov = slot.Parent and slot.Parent:FindFirstChild("OwnerValue")
        if ov and ov.Value then sellerName = tostring(ov.Value.Name) end
    end)

    log("FIRE", slot.Name .. " | " .. shoeName .. " | " .. fmtMoney(price) .. " | " .. sellerName)

    -- Listen BEFORE firing so a fast replication can't be missed
    local confirmed   = false
    local conns       = {}
    local moneyBefore = __L.getMoney()
    local function watch(folder)
        table.insert(conns, folder.ChildAdded:Connect(function(item)
            if item.Name == shoeName then confirmed = true end
        end))
    end
    watch(SellableInventory); watch(UnsellableInventory)

    BuyState.inflight += price
    inflightAdded = true
    local fired, err = pcall(function() BuyDisplaySneakerEvent:FireServer(slot, shoeName, price) end)
    if not fired then
        for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
        safeDecrInflight()
        safeRelease()
        log("ERR", tostring(err))
        return false
    end

    local function resolve()
        local okRes, errRes = pcall(function()
            local deadline = tick() + math.max(1.5, (tonumber(Settings.BuyConfirmPollWait) or 0.08) * 10)
            while not confirmed and tick() < deadline and srsAlive() do task.wait(0.02) end
            for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
            safeDecrInflight()

            if confirmed then
                local delta = moneyBefore - __L.getMoney()
                local cost
                if delta > 0 and math.abs(delta - price) <= price * 0.05 then
                    cost = delta
                else
                    cost = price
                end
                log("OK", "BOUGHT: " .. shoeName .. " | " .. fmtMoney(cost) .. " | " .. fmtMoney(__L.getMoney()))
                BuyStats.Bought           += 1
                getgenv().ShoesBought     += 1
                getgenv().TotalMoneySpent += cost
                BuyState.streak = 0
                BuyState.lastBuyAt = os.time()
            else
                -- Did someone else win the race, or did our buy silently fail?
                local sv   = slot:FindFirstChild("SneakerValue")
                local db   = slot:FindFirstChild("SellDebounce")
                local gone = (not slot.Parent) or (not sv) or tostring(sv.Value) ~= shoeName or (db ~= nil and db.Value == true)
                if gone then
                    skip("lost_race")
                    log("LOST", "sold out before us - " .. shoeName)
                else
                    BuyState.streak += 1
                    BuyState.cool[slot] = tick() + (tonumber(GATES.SlotFailCooldown) or 2.5)
                    log("WARN", "COULD NOT VERIFY - " .. shoeName .. " (streak " .. BuyState.streak .. ")")
                    if BuyState.streak >= (tonumber(GATES.BreakerFails) or 5) then
                        BuyState.breakerUntil     = tick() + (tonumber(GATES.BreakerPause) or 15)
                        BuyState.streak = 0
                        skip("breaker_tripped")
                        log("BREAKER", "too many unverified buys in a row - pausing buys " .. GATES.BreakerPause .. "s")
                        notify("Buy breaker", "Several buys didn't verify. Pausing " .. GATES.BreakerPause .. "s.", 6, "X")
                    end
                end
            end

            updateStats()
            safeRelease()

            if confirmed or fromListTab then
                task.spawn(function()
                    __L.sendWebhook(shoeName, price, confirmed, fromListTab and "LIST TAB BUY" or "BOUGHT", sellerName)
                end)
            end
        end)
        if not okRes then
            for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
            safeDecrInflight()
            safeRelease()
            log("ERR", "resolve: " .. tostring(errRes))
        end
    end

    if fromListTab then resolve() else task.spawn(resolve) end   -- list tab wants the result before refreshing
    return true
end

-- Safety watchdog
task.spawn(function()
    while srsAlive() do
        task.wait(30)
        if not srsAlive() then break end
        -- if inflight stuck too long
        if BuyState.inflight > 0 then
            -- will be decremented by resolve or pcall cleanup
        end
        -- ensure breaker doesn't get stuck weirdly
        if BuyState.breakerUntil and BuyState.breakerUntil < tick() - 300 then
            BuyState.breakerUntil = 0
            BuyState.streak = 0
        end
    end
end)

-- Check all filters for a slot and buy if it passes. Returns true if a buy was fired.
function __L.trySneaker(slot)
    if not __L.canAct() then return false end
    if typeof(slot) ~= "Instance" or not slot.Parent then return false end
    if (BuyState.cool[slot] or 0) > tick() then return false end
    local sneakerVal = slot:FindFirstChild("SneakerValue")
    local priceVal   = slot:FindFirstChild("Price")
    local debounce   = slot:FindFirstChild("SellDebounce")

    if not sneakerVal or sneakerVal.Value == "" then return false end
    if debounce and debounce.Value == true then return false end

    local shoeName = tostring(sneakerVal.Value)
    local price    = tonumber(priceVal and priceVal.Value) or 0
    if price < 1 then skip("bad_price"); BuyStats.Found += 1; BuyStats.Skipped += 1; updateStats(); return false end   -- unreplicated / missing price must never pass caps

    BuyStats.Found += 1; updateStats()

    if __L.isBlacklisted(shoeName) then skip("blacklist"); BuyStats.Skipped += 1; updateStats(); return false end
    if Settings.UnsellableOnly and not __L.isUnsellable(shoeName) then skip("not_unsellable"); BuyStats.Skipped += 1; updateStats(); return false end

    if type(Settings.TargetShoe) == "string" and Settings.TargetShoe ~= "" then
        if not shoeName:lower():find(Settings.TargetShoe:lower(), 1, true) then
            skip("target_mismatch"); BuyStats.Skipped += 1; updateStats(); return false
        end
    end

    if Settings.PriceFilter and price > (tonumber(Settings.MaxPrice) or 100000) then
        skip("max_price"); BuyStats.Skipped += 1; updateStats(); return false
    end

    if __L.hasMaxBuyPrice(shoeName) and price > __L.getMaxBuyPrice(shoeName) then
        logThrottled("pc:" .. shoeName, 10, "PERSH", "SKIP " .. shoeName .. " price " .. fmtMoney(price) .. " > cap " .. fmtMoney(__L.getMaxBuyPrice(shoeName)))
        skip("per_shoe_cap"); BuyStats.Skipped += 1; updateStats(); return false
    end

    if not __L.stockYOk(shoeName, price) then return false end
    if not __L.acquireSlotLock(slot) then return false end

    log("FIND", shoeName .. " | " .. fmtMoney(price))
    return __L.fireAndConfirm(slot, shoeName, price, false)
end

-- Low-price mode: only buy if price is at or below OneDollarMaxPrice
function __L.tryOneDollar(slot)
    if not __L.canAct() then return false end
    if (BuyState.cool[slot] or 0) > tick() then return false end
    local sneakerVal = slot:FindFirstChild("SneakerValue")
    local priceVal   = slot:FindFirstChild("Price")
    local debounce   = slot:FindFirstChild("SellDebounce")

    if not sneakerVal or sneakerVal.Value == "" then return false end
    if debounce and debounce.Value == true then return false end

    local price    = tonumber(priceVal and priceVal.Value) or 0
    local shoeName = tostring(sneakerVal.Value)

    if price < 1 then skip("bad_price"); return false end   -- price 0 = not replicated yet, NOT a free shoe
    if price > OneDollarMaxPrice then return false end
    if __L.isBlacklisted(shoeName) then return false end
    if not __L.acquireSlotLock(slot) then return false end

    BuyStats.Found += 1; updateStats()
    setStatus("$1 Mode - buying: " .. shoeName .. " (" .. fmtMoney(price) .. ")")
    local fired = __L.fireAndConfirm(slot, shoeName, price, false)
    setStatus("$1 Mode (<=" .. fmtMoney(OneDollarMaxPrice) .. ") [LIVE]")
    return fired
end


-- ════════════════════════════════════════════════════════════════
--  WALK-TO-BUY  (pathfinding helpers)
-- ════════════════════════════════════════════════════════════════

local SPRINT_SPEED = 32
local NORMAL_SPEED = 16

function __L.setWalkSpeed(on)
    pcall(function()
        local char = LocalPlayer.Character
        if not char then return end
        local hum = char:FindFirstChildOfClass("Humanoid")
        if hum then hum.WalkSpeed = on and SPRINT_SPEED or NORMAL_SPEED end
    end)
end

function __L.walkToPosition(targetPos, runningFn)
    local char = LocalPlayer.Character
    if not char then return end
    local hum      = char:FindFirstChildOfClass("Humanoid")
    local rootPart = char:FindFirstChild("HumanoidRootPart")
    if not hum or not rootPart then return end

    -- Already close enough — no need to walk
    if (rootPart.Position - targetPos).Magnitude < 20 then return end

    __L.setWalkSpeed(true)
    local path = PathfindingService:CreatePath({ AgentRadius = 2, AgentHeight = 5, AgentCanJump = true })
    local ok   = pcall(function() path:ComputeAsync(rootPart.Position, targetPos) end)

    if ok and path.Status == Enum.PathStatus.Success then
        for _, wp in ipairs(path:GetWaypoints()) do
            if runningFn and not runningFn() then __L.setWalkSpeed(false); return end
            if wp.Action == Enum.PathWaypointAction.Jump then hum.Jump = true end
            hum:MoveTo(wp.Position)
            hum.MoveToFinished:Wait(3)
        end
    else
        hum:MoveTo(targetPos)
        hum.MoveToFinished:Wait(4)
    end
    __L.setWalkSpeed(false)
end

function __L.walkToSlot(slot, runningFn)
    local model = slot.Parent
    if not model then return end
    local part = model:FindFirstChildWhichIsA("BasePart", true)
    if part then
        __L.walkToPosition(part.Position, runningFn)
        task.wait(0.1)
    end
end


-- ════════════════════════════════════════════════════════════════
--  SCAN MODES  (Snipe, Low Price / $1, and the Walk-to-Buy variants)
-- ════════════════════════════════════════════════════════════════

-- One-shot: scan every table right now
function __L.scanAllTables()
    if not Tables then setStatus("Tables not loaded yet"); return end
    BuyStats = { Found = 0, Bought = 0, Skipped = 0 }; updateStats()
    setStatus("Scanning [LIVE]")
    local tableCount = 0
    for _, tableModel in ipairs(Tables:GetChildren()) do
        if tableModel.Name == "Table" then
            tableCount += 1
            task.spawn(function()
                for i = 1, 6 do
                    local slot = tableModel:FindFirstChild("DisplaySneaker" .. i)
                    if slot and __L.trySneaker(slot) and Settings.Delay > 0 then task.wait(Settings.Delay) end
                end
            end)
        end
    end
    task.wait(1.5)   -- v6: buys confirm in the background; no per-table wait
    setStatus("Done - bought:" .. BuyStats.Bought)
end

-- ── Snipe Mode ────────────────────────────────────────────────
function __L.stopSnipe()
    SnipeLoopRunning = false
    for _, c in ipairs(SnipeConnections) do c:Disconnect() end
    SnipeConnections = {}
    setStatus("Idle")
end

function __L.startSnipe()
    if not Tables then notify("Shoe Sniper", "Market tables not loaded yet - retry in a moment.", 4); return end
    if SnipeLoopRunning then return end
    SnipeLoopRunning = true
    SnipeConnections = {}

    local function hookSlot(slot)
        local sv = slot:FindFirstChild("SneakerValue")
        local pv = slot:FindFirstChild("Price")
        if sv then
            table.insert(SnipeConnections, sv.Changed:Connect(function(v)
                if v ~= "" and SnipeLoopRunning then
                    task.defer(__L.trySneaker, slot)
                end
            end))
        end
        -- v6: also react instantly to PRICE DROPS on an already-listed shoe (poll was the only catch before)
        if pv then
            table.insert(SnipeConnections, pv.Changed:Connect(function()
                if SnipeLoopRunning then task.defer(__L.trySneaker, slot) end
            end))
        end
    end

    for _, slot in ipairs(cachedSlots) do hookSlot(slot) end

    -- Hook new tables as they appear
    table.insert(SnipeConnections, Tables.ChildAdded:Connect(function(tm)
        if not SnipeLoopRunning then return end
        task.wait(0.3)
        if tm.Name == "Table" then
            for i = 1, 6 do
                local s = tm:FindFirstChild("DisplaySneaker" .. i)
                if s then hookSlot(s) end
            end
        end
    end))

    -- Poll loop (catches shoes that were already listed before hooks fired)
    task.spawn(function()
        while SnipeLoopRunning do
            if not srsAlive() then break end
            local n = 0
            for _, slot in ipairs(cachedSlots) do
                if not SnipeLoopRunning then break end
                -- v6: only pace after an actual buy attempt (was: Delay after EVERY slot = seconds per cycle)
                if __L.trySneaker(slot) and Settings.Delay > 0 then task.wait(Settings.Delay) end
                n += 1; if n % 50 == 0 then task.wait() end
            end
            task.wait(Settings.SnipeCycleWait)
        end
    end)

    if Settings.UseStockYCheck and not StockY.ready then
        setStatus("Sniping [waiting for StockY...]")
        notify("Shoe Sniper", "StockY prices still loading - buys start automatically once ready.", 5)
        task.spawn(function()
            while SnipeLoopRunning and srsAlive() and not StockY.ready do task.wait(0.25) end
            if SnipeLoopRunning and srsAlive() then
                setStatus("Sniping [LIVE]")
                notify("Shoe Sniper", "StockY ready - sniping live.", 3, "Check")
            end
        end)
    else
        setStatus("Sniping [LIVE]")
    end
end

-- ── Low-Price Mode ($1 Mode) ───────────────────────────────────
function __L.stopOneDollar()
    OneDollarRunning = false
    for _, c in ipairs(OneDollarConns) do c:Disconnect() end
    OneDollarConns = {}
    setStatus("Idle")
end

function __L.startOneDollar()
    if not Tables then notify("Shoe Sniper", "Market tables not loaded yet - retry in a moment.", 4); return end
    if OneDollarRunning then return end
    OneDollarRunning = true
    OneDollarConns   = {}

    local function hookSlot(slot)
        local sv = slot:FindFirstChild("SneakerValue")
        local pv = slot:FindFirstChild("Price")
        if sv then
            table.insert(OneDollarConns, sv.Changed:Connect(function(v)
                if v ~= "" and OneDollarRunning then
                    task.spawn(function() __L.tryOneDollar(slot) end)
                end
            end))
        end
        if pv then
            table.insert(OneDollarConns, pv.Changed:Connect(function(v)
                if OneDollarRunning and tonumber(v) and tonumber(v) <= OneDollarMaxPrice then
                    task.spawn(function() __L.tryOneDollar(slot) end)
                end
            end))
        end
    end

    for _, slot in ipairs(cachedSlots) do hookSlot(slot) end

    table.insert(OneDollarConns, Tables.ChildAdded:Connect(function(tm)
        if not OneDollarRunning then return end
        task.wait(0.3)
        if tm.Name == "Table" then
            for i = 1, 6 do
                local s = tm:FindFirstChild("DisplaySneaker" .. i)
                if s then hookSlot(s) end
            end
        end
    end))

    task.spawn(function()
        local scanned = 0
        while OneDollarRunning do
            if not srsAlive() then break end
            for _, slot in ipairs(cachedSlots) do
                if not OneDollarRunning then break end
                local pv = slot:FindFirstChild("Price")
                if pv and tonumber(pv.Value) and tonumber(pv.Value) <= OneDollarMaxPrice then
                    scanned += 1
                    __L.tryOneDollar(slot)
                    local _sl = getgenv().SnpStatsLabel
                    if _sl then pcall(function()
                        _sl:Set("Listings checked: " .. BuyStats.Found .. "   |   Bought: " .. BuyStats.Bought .. "   |   Cheap listings seen: " .. scanned)
                    end) end
                end
            end
            task.wait(Settings.OneDollarCycleWait)
        end
    end)

    setStatus("$1 Mode (<=" .. fmtMoney(OneDollarMaxPrice) .. ") [LIVE]")
end

-- ── Walk-to-Buy Snipe ─────────────────────────────────────────
function __L.stopWalkBuySnipe()
    WalkBuySnipeRunning = false
    for _, c in ipairs(WalkBuySnipeConns) do c:Disconnect() end
    WalkBuySnipeConns = {}
    if WakeSnipeEvent then pcall(function() WakeSnipeEvent:Destroy() end); WakeSnipeEvent = nil end
    __L.setWalkSpeed(false); setStatus("Idle")
end

function __L.startWalkBuySnipe()
    if not Tables then notify("Shoe Sniper", "Market tables not loaded yet - retry in a moment.", 4); return end
    if WalkBuySnipeRunning then return end
    WalkBuySnipeRunning = true
    WalkBuySnipeConns   = {}
    local function isRunning() return WalkBuySnipeRunning end

    -- Find the cheapest eligible slot currently on the map
    local function scanBest()
        local bestSlot, bestPrice = nil, math.huge
        for _, slot in ipairs(cachedSlots) do
            local sv = slot:FindFirstChild("SneakerValue")
            local pv = slot:FindFirstChild("Price")
            local db = slot:FindFirstChild("SellDebounce")
            if not (sv and sv.Value ~= "" and not (db and db.Value)) then continue end
            local shoeName = tostring(sv.Value)
            local price    = tonumber(pv and pv.Value) or 0
            if __L.isBlacklisted(shoeName) then continue end
            if Settings.UnsellableOnly and not __L.isUnsellable(shoeName) then continue end
            if type(Settings.TargetShoe) == "string" and Settings.TargetShoe ~= ""
                and not shoeName:lower():find(Settings.TargetShoe:lower(), 1, true) then continue end
            if Settings.PriceFilter and price > (tonumber(Settings.MaxPrice) or 100000) then continue end
            if __L.hasMaxBuyPrice(shoeName) and price > __L.getMaxBuyPrice(shoeName) then continue end
            if Settings.UseStockYCheck or Settings.UseMaxPriceFallback or Settings.UseOverpayLimit or Settings.BlockNoStockYData then
                if not __L.stockYOk(shoeName, price) then BuyStats.Skipped = math.max(0, BuyStats.Skipped - 1); continue end
            end
            if price < bestPrice then bestPrice = price; bestSlot = slot end
        end
        return bestSlot
    end

    -- Make sure the shoe and price haven't changed while we were walking
    local function stillValid(slot, expectedName, expectedPrice)
        local sv = slot:FindFirstChild("SneakerValue")
        local pv = slot:FindFirstChild("Price")
        local db = slot:FindFirstChild("SellDebounce")
        if not sv or sv.Value ~= expectedName then return false end
        if db and db.Value then return false end
        return math.abs((tonumber(pv and pv.Value) or 0) - expectedPrice) <= 1
    end

    WakeSnipeEvent = Instance.new("BindableEvent")
    local wakeEvent = WakeSnipeEvent

    local function hookSlot(slot)
        local sv = slot:FindFirstChild("SneakerValue")
        if sv then
            table.insert(WalkBuySnipeConns, sv.Changed:Connect(function(v)
                if v ~= "" and WalkBuySnipeRunning then pcall(function() wakeEvent:Fire() end) end
            end))
        end
    end

    for _, slot in ipairs(cachedSlots) do hookSlot(slot) end
    table.insert(WalkBuySnipeConns, Tables.ChildAdded:Connect(function(tm)
        if not WalkBuySnipeRunning then return end
        task.wait(0.3)
        if tm.Name == "Table" then
            for i = 1, 6 do
                local s = tm:FindFirstChild("DisplaySneaker" .. i)
                if s then hookSlot(s) end
            end
        end
    end))

    task.spawn(function()
        while WalkBuySnipeRunning do
            if not srsAlive() then break end
            local slot = scanBest()
            if slot then
                local sv     = slot:FindFirstChild("SneakerValue")
                local pv     = slot:FindFirstChild("Price")
                local sName  = sv and tostring(sv.Value) or ""
                local sPrice = tonumber(pv and pv.Value) or 0
                setStatus("Walk-Snipe → " .. sName .. " (" .. fmtMoney(sPrice) .. ")")
                __L.walkToSlot(slot, isRunning)
                if WalkBuySnipeRunning then
                    if stillValid(slot, sName, sPrice) then
                        __L.trySneaker(slot)
                    else
                        log("WALK", "Slot changed — skipping " .. sName)
                        setStatus("Walk-Snipe [re-scanning...]")
                    end
                end
                task.wait(math.max(Settings.Delay, 0.05))
            else
                setStatus("Walk-Snipe [nothing to buy]")
                -- Sleep until a shoe appears (or timeout)
                local woke = false
                local wc   = wakeEvent.Event:Connect(function() woke = true end)
                local dl   = tick() + Settings.SnipeCycleWait
                while not woke and tick() < dl and WalkBuySnipeRunning and srsAlive() do task.wait(0.05) end
                wc:Disconnect()
            end
        end
        __L.setWalkSpeed(false)
    end)

    setStatus("Walk-to-Buy Snipe [LIVE]")
end

-- ── Walk-to-Buy Low-Price Mode ────────────────────────────────
function __L.stopWalkBuyOneDollar()
    WalkBuyOneDollarRunning = false
    for _, c in ipairs(WalkBuyOneDollarConns) do c:Disconnect() end
    WalkBuyOneDollarConns = {}
    if WakeDollarEvent then pcall(function() WakeDollarEvent:Destroy() end); WakeDollarEvent = nil end
    __L.setWalkSpeed(false); setStatus("Idle")
end

function __L.startWalkBuyOneDollar()
    if not Tables then notify("Shoe Sniper", "Market tables not loaded yet - retry in a moment.", 4); return end
    if WalkBuyOneDollarRunning then return end
    WalkBuyOneDollarRunning = true
    WalkBuyOneDollarConns   = {}
    local function isRunning() return WalkBuyOneDollarRunning end

    local function scanBest()
        local bestSlot, bestPrice = nil, math.huge
        for _, slot in ipairs(cachedSlots) do
            local sv = slot:FindFirstChild("SneakerValue")
            local pv = slot:FindFirstChild("Price")
            local db = slot:FindFirstChild("SellDebounce")
            if not (sv and sv.Value ~= "" and not (db and db.Value)) then continue end
            local price = tonumber(pv and pv.Value) or math.huge
            if price <= OneDollarMaxPrice and not __L.isBlacklisted(tostring(sv.Value)) then
                if price < bestPrice then bestPrice = price; bestSlot = slot end
            end
        end
        return bestSlot
    end

    local function stillValid(slot, expectedName, expectedPrice)
        local sv = slot:FindFirstChild("SneakerValue")
        local pv = slot:FindFirstChild("Price")
        local db = slot:FindFirstChild("SellDebounce")
        if not sv or sv.Value ~= expectedName then return false end
        if db and db.Value then return false end
        return math.abs((tonumber(pv and pv.Value) or 0) - expectedPrice) <= 1
    end

    WakeDollarEvent = Instance.new("BindableEvent")
    local wakeEvent = WakeDollarEvent

    local function hookSlot(slot)
        local sv = slot:FindFirstChild("SneakerValue")
        local pv = slot:FindFirstChild("Price")
        local function tryWake()
            if not WalkBuyOneDollarRunning then return end
            if (tonumber(pv and pv.Value) or math.huge) <= OneDollarMaxPrice then
                pcall(function() wakeEvent:Fire() end)
            end
        end
        if sv then table.insert(WalkBuyOneDollarConns, sv.Changed:Connect(function(v) if v ~= "" then tryWake() end end)) end
        if pv then table.insert(WalkBuyOneDollarConns, pv.Changed:Connect(tryWake)) end
    end

    for _, slot in ipairs(cachedSlots) do hookSlot(slot) end
    table.insert(WalkBuyOneDollarConns, Tables.ChildAdded:Connect(function(tm)
        if not WalkBuyOneDollarRunning then return end
        task.wait(0.3)
        if tm.Name == "Table" then
            for i = 1, 6 do
                local s = tm:FindFirstChild("DisplaySneaker" .. i)
                if s then hookSlot(s) end
            end
        end
    end))

    task.spawn(function()
        local scanned = 0
        while WalkBuyOneDollarRunning do
            if not srsAlive() then break end
            local slot = scanBest()
            if slot then
                local sv     = slot:FindFirstChild("SneakerValue")
                local pv     = slot:FindFirstChild("Price")
                local sName  = sv and tostring(sv.Value) or ""
                local sPrice = tonumber(pv and pv.Value) or 0
                setStatus("Walk-$1 → " .. sName .. " (" .. fmtMoney(sPrice) .. ")")
                __L.walkToSlot(slot, isRunning)
                if WalkBuyOneDollarRunning then
                    if stillValid(slot, sName, sPrice) then
                        scanned += 1
                        __L.tryOneDollar(slot)
                        local _sl = getgenv().SnpStatsLabel
                        if _sl then pcall(function()
                            _sl:Set("Listings checked: " .. BuyStats.Found .. "   |   Bought: " .. BuyStats.Bought .. "   |   Cheap listings seen: " .. scanned)
                        end) end
                    else
                        log("WALK", "Slot changed — skipping " .. sName)
                        setStatus("Walk-$1 [re-scanning...]")
                    end
                end
                task.wait(math.max(Settings.Delay, 0.05))
            else
                setStatus("Walk-$1 (<=" .. fmtMoney(OneDollarMaxPrice) .. ") [nothing to buy]")
                local woke = false
                local wc   = wakeEvent.Event:Connect(function() woke = true end)
                local dl   = tick() + Settings.OneDollarCycleWait
                while not woke and tick() < dl and WalkBuyOneDollarRunning and srsAlive() do task.wait(0.05) end
                wc:Disconnect()
            end
        end
        __L.setWalkSpeed(false)
    end)

    setStatus("Walk-to-Buy $1 (<=" .. fmtMoney(OneDollarMaxPrice) .. ") [LIVE]")
end

-- Stop everything at once (used on character removal / teleport)
function __L.stopAllModes()
    __L.stopSnipe()
    __L.stopOneDollar()
    __L.stopWalkBuySnipe()
    __L.stopWalkBuyOneDollar()
    -- Stop auto-sell modes
    SellAllRunning    = false; for _, c in ipairs(SellAllConns)    do c:Disconnect() end; SellAllConns    = {}
    SellUnsellRunning = false; for _, c in ipairs(SellUnsellConns) do c:Disconnect() end; SellUnsellConns = {}
    -- Stop flash list
    FlashListRunning = false
    if flashListedSlot then
        pcall(function()
            if RemoveDisplaySneaker then RemoveDisplaySneaker:FireServer(flashListedSlot)
            elseif ChangeDisplaySneaker then ChangeDisplaySneaker:FireServer("", flashListedSlot.Name, 0) end
        end)
        flashListedSlot = nil
    end
    listAutoRefresh = false
end

LocalPlayer.CharacterRemoving:Connect(__L.stopAllModes)
game:GetService("Players").LocalPlayer.OnTeleport:Connect(function(state)
    getgenv().SRS_LEAVING = true
    if state == Enum.TeleportState.RequestedFromServer or state == Enum.TeleportState.Started then
        __L.stopAllModes()
    end
    task.spawn(function() __L.sendKickWebhook("Player teleported / kicked") end)
end)
LocalPlayer.AncestryChanged:Connect(function()
    getgenv().SRS_LEAVING = true
    task.spawn(function() __L.sendKickWebhook("Game Closed / Player Kicked") end)
end)


-- ════════════════════════════════════════════════════════════════
--  SELL / TABLE HELPERS
-- ════════════════════════════════════════════════════════════════

function __L.getMyTable()
    if not Tables then return nil end
    for _, tm in ipairs(Tables:GetChildren()) do
        if tm.Name == "Table" then
            local ov = tm:FindFirstChild("OwnerValue")
            if ov and ov.Value == LocalPlayer then return tm end
        end
    end
    return nil
end

function __L.hasTableSkin()
    local ti = LocalPlayer:FindFirstChild("TableInventory")
    if not ti then return false end
    if #ti:GetChildren() > 0 then return true end
    for _ in pairs(ti:GetAttributes()) do return true end
    return false
end

function __L.maxTableSlots() return __L.hasTableSkin() and 6 or 3 end

function __L.getFirstEmptySlot(myTable)
    if not myTable then return nil end
    for i = 1, __L.maxTableSlots() do
        local slot = myTable:FindFirstChild("DisplaySneaker" .. i)
        if slot then
            local sv = slot:FindFirstChild("SneakerValue")
            if sv and sv.Value == "" then return slot end
        end
    end
    return nil
end

function __L.calcSellPrice(shoeName)
    if Settings.UseFixedSellPrice then
        return math.max(1, Settings.FixedSellPrice)
    end
    local sp = StockYCache[shoeName]
    if sp and sp > 0 then
        return math.max(1, math.floor(sp * (1 + Settings.SellStockYOffsetPct / 100)))
    end
    return pendingSellPrice
end

function __L.listShoeOnTable(shoeName)
    if not ChangeDisplaySneaker then log("ERR", "ChangeDisplaySneaker nil"); return false, 0 end
    local myTable   = __L.getMyTable(); if not myTable then return false, 0 end
    local slot      = __L.getFirstEmptySlot(myTable); if not slot then log("SELL", "All slots full"); return false, 0 end
    local listPrice = __L.calcSellPrice(shoeName)
    local ok, err   = pcall(function() ChangeDisplaySneaker:FireServer(shoeName, slot.Name, listPrice) end)
    if ok then
        lastListedPrice[shoeName] = listPrice
        return true, listPrice
    end
    log("ERR", "List failed: " .. tostring(err)); return false, 0
end

function __L.removeShoeFromSlot(slot)
    if not slot then return end
    if RemoveDisplaySneaker then
        pcall(function() RemoveDisplaySneaker:FireServer(slot) end)
    elseif ChangeDisplaySneaker then
        pcall(function() ChangeDisplaySneaker:FireServer("", slot.Name, 0) end)
    else
        log("ERR", "removeShoeFromSlot: no remote")
    end
end

-- Update all sell-tab price labels after settings change
function __L.updateSellPriceLabels()
    for shoeName, ref in pairs(sellLabelRefs) do
        local badge     = ref.sellable and "[SELLABLE]" or "[UNSELLABLE]"
        local sp        = StockYCache[shoeName]
        local listPrice = __L.calcSellPrice(shoeName)
        local stockStr
        if Settings.UseFixedSellPrice then
            stockStr = "Fixed: " .. fmtMoney(Settings.FixedSellPrice) .. (sp and (" | StockY: " .. fmtMoney(sp)) or "")
        else
            local pctStr = Settings.SellStockYOffsetPct >= 0
                and ("+" .. Settings.SellStockYOffsetPct .. "%")
                or  (Settings.SellStockYOffsetPct .. "%")
            stockStr = sp
                and ("StockY: " .. fmtMoney(sp) .. " (" .. pctStr .. ") -> " .. fmtMoney(listPrice))
                or  ("StockY: N/A -> Fallback: " .. fmtMoney(pendingSellPrice))
        end
        pcall(function() ref.label:Set(shoeName .. "  |  " .. badge .. "  |  " .. stockStr) end)
    end
end


-- ════════════════════════════════════════════════════════════════
--  AUTO-SELL LOOP
-- ════════════════════════════════════════════════════════════════

-- Shared auto-sell core: continuously fills your table slots from inventory
function __L.runPersistentSellLoop(label, ownedFn, runningFn, connsTable)
    local slotLimit = __L.hasTableSkin() and 6 or 3
    notify(label .. " Started", "Continuous | " .. slotLimit .. " slots", 5)

    local function getAlreadyListed()
        local listed = {}
        local mt     = __L.getMyTable(); if not mt then return listed end
        for i = 1, __L.maxTableSlots() do
            local slot = mt:FindFirstChild("DisplaySneaker" .. i)
            if slot then
                local sv = slot:FindFirstChild("SneakerValue")
                if sv and sv.Value ~= "" then listed[sv.Value] = true end
            end
        end
        return listed
    end

    local function pickNextShoe()
        local listed = getAlreadyListed()
        -- Prefer unsellable (they earn more attention)
        for _, item in ipairs(UnsellableInventory:GetChildren()) do
            if ownedFn(item.Name) and not listed[item.Name] then return item.Name end
        end
        for _, item in ipairs(SellableInventory:GetChildren()) do
            if ownedFn(item.Name) and not listed[item.Name] then return item.Name end
        end
        return nil
    end

    local function fillSlots()
        if not runningFn() then return end
        if not srsAlive() then return end
        local mt = __L.getMyTable(); if not mt then return end
        local failures = 0
        while runningFn() do
            if not srsAlive() then return end
            local slot = __L.getFirstEmptySlot(mt); if not slot then break end
            local shoe = pickNextShoe();         if not shoe then break end
            local ok, price = __L.listShoeOnTable(shoe)
            if ok then
                failures = 0
                notify(label, shoe .. " -> " .. fmtMoney(price), 3, "Check")
                local confirmed = false
                for _ = 1, 20 do
                    task.wait(Settings.AutoSellSlotWait)
                    if __L.getFirstEmptySlot(mt) ~= slot then confirmed = true; break end
                end
                if not confirmed then failures += 1; task.wait(1); if failures >= 3 then break end end
            else
                failures += 1; task.wait(1); if failures >= 3 then break end
            end
        end
    end

    -- Hook each slot so we refill immediately when a shoe sells
    local function hookTableSlots(mt)
        if not mt then return end
        for i = 1, slotLimit do
            local slot = mt:FindFirstChild("DisplaySneaker" .. i)
            if slot then
                local sv = slot:FindFirstChild("SneakerValue")
                if sv then
                    local conn = sv.Changed:Connect(function(v)
                        if v == "" and runningFn() then task.wait(0.5); fillSlots() end
                    end)
                    table.insert(connsTable, conn)
                end
            end
        end
    end

    local mt = __L.getMyTable()
    if mt then hookTableSlots(mt) end
    fillSlots()
    task.spawn(function()
        while runningFn() do
            if not srsAlive() then break end
            task.wait(Settings.AutoSellRefillWait)
            if runningFn() then fillSlots() end
        end
    end)
end

function __L.startSellAll()
    if SellAllRunning then return end
    SellAllRunning = true
    task.spawn(function()
        __L.runPersistentSellLoop(
            "SELL-ALL",
            function(n) return __L.isSellable(n) or __L.ownsUnsellable(n) end,
            function() return SellAllRunning end,
            SellAllConns)
    end)
end

function __L.startSellUnsell()
    if SellUnsellRunning then return end
    SellUnsellRunning = true
    task.spawn(function()
        __L.runPersistentSellLoop(
            "SELL-UNSELL",
            function(n) return __L.ownsUnsellable(n) end,
            function() return SellUnsellRunning end,
            SellUnsellConns)
    end)
end


-- ════════════════════════════════════════════════════════════════
--  FLASH LIST MODE
-- ════════════════════════════════════════════════════════════════

function __L.startFlashList()
    if FlashListRunning then return end
    if not ChangeDisplaySneaker then
        notify("Flash List", "Remote not available!", 5); return
    end
    FlashListRunning    = true
    FlashListCounter    = 0
    FlashListNextDollar = math.random(5, 15)

    task.spawn(function()
        while FlashListRunning do
            if not srsAlive() then break end
            local mt = __L.getMyTable()
            if not mt then task.wait(1); continue end

            local slot = mt:FindFirstChild("DisplaySneaker1")
            if not slot then task.wait(1); continue end

            -- Remove whatever is currently in slot 1
            local sv = slot:FindFirstChild("SneakerValue")
            if sv and sv.Value ~= "" then __L.removeShoeFromSlot(slot); task.wait(0.2) end

            -- Pick a random shoe from inventory
            local shoes = {}
            for _, item in ipairs(SellableInventory:GetChildren())   do table.insert(shoes, item.Name) end
            for _, item in ipairs(UnsellableInventory:GetChildren())  do table.insert(shoes, item.Name) end
            if #shoes == 0 then task.wait(1); continue end

            local shoeName = shoes[math.random(1, #shoes)]
            FlashListCounter += 1

            -- Every FlashListNextDollar listings, list at $1
            local listPrice
            if FlashListCounter >= FlashListNextDollar then
                listPrice           = 1
                FlashListCounter    = 0
                FlashListNextDollar = math.random(5, 15)
                notify("Flash List - $1 Hit!", shoeName .. " @ $1" .. "\nNext in " .. FlashListNextDollar, 3, "Check")
            else
                listPrice = math.random(2, 999999)
            end

            local ok = pcall(function() ChangeDisplaySneaker:FireServer(shoeName, "DisplaySneaker1", listPrice) end)
            if ok then flashListedSlot = slot end

            task.wait(Settings.FlashListHoldTime)

            if FlashListRunning then
                __L.removeShoeFromSlot(slot)
                flashListedSlot = nil
                task.wait(Settings.FlashListDelistTime)
            end
        end
    end)
end

-- ════════════════════════════════════════════════════════════════
--  SNIPER TAB  UI  (sub-page: Sniper)
-- ════════════════════════════════════════════════════════════════

-- Status labels (top of tab, created here to control ordering)
do
    local sc = ROWC.statusCard(ScannerTab)
    getgenv().SnpStatusLabel     = sc.Status
    getgenv().SnpStatsLabel      = sc.Stats
    getgenv().SnpStockYLabel     = sc.StockY
    getgenv().SnpSneakerModLabel = sc.Shoe
    getgenv().SnpWhyLabel        = sc.Why
end

ScannerTab:CreateSection("START HERE (read this first)")
ScannerTab:CreateParagraph({
    Title = "3 steps. That's it.",
    Content = "1)  Look at the lines above. When they say 'StockY prices: ... loaded' and 'Shoe data: loaded', you are ready. This happens by itself in a few seconds.\n\n2)  Flip ONE switch below. Snipe Mode is the right choice for almost everyone.\n\n3)  Leave it on. It buys by itself. The 'Status' line shows what it is doing. Flip the same switch off to stop.",
})
ScannerTab:CreateParagraph({
    Title = "Good to know",
    Content = "-  Only one buying mode runs at a time. Turning one on turns the others off.\n-  It only buys shoes that pass your rules (Settings, Blacklist and Per-Shoe Caps tabs).\n-  It will not spend more cash than you have, and it pauses by itself if purchases keep failing.\n-  Press K on your keyboard to hide or show this window.\n-  Your settings save automatically.",
})

ScannerTab:CreateSection("One-Time Scan")
ScannerTab:CreateParagraph({
    Title = "Scan Once",
    Content = "Checks every table one single time and buys whatever passes your rules, then stops. Use this to test your settings without leaving a mode running.",
})
ScannerTab:CreateButton({
    Name     = "Scan Once now",
    Callback = function() task.spawn(__L.scanAllTables) end,
})

ScannerTab:CreateSection("Snipe Mode (recommended)")
ScannerTab:CreateParagraph({
    Title = "Snipe Mode",
    Content = "Watches every table and buys the instant a good shoe is listed or its price drops. Your character does not move. This is the fastest mode and the one to use unless it does not work for you.",
})
SnipeToggleRef = ScannerTab:CreateToggle({
    Name     = "Snipe Mode   (ON = running, OFF = stopped)",
    Default  = false,
    Callback = function(v)
        Settings.SnipeMode = v
        if v then
            if OneDollarRunning        then __L.stopOneDollar();        pcall(function() OneDollarToggleRef:SetValue(false)    end) end
            if WalkBuySnipeRunning     then __L.stopWalkBuySnipe();     pcall(function() WalkSnipeToggleRef:SetValue(false)    end) end
            if WalkBuyOneDollarRunning then __L.stopWalkBuyOneDollar(); pcall(function() WalkOneDollarToggleRef:SetValue(false) end) end
            BuyStats = { Found=0, Bought=0, Skipped=0 }; updateStats()
            task.spawn(__L.startSnipe)
        else
            __L.stopSnipe()
        end
    end,
})

ScannerTab:CreateSection("Walk-to-Buy Snipe (backup option)")
ScannerTab:CreateParagraph({
    Title = "Walk-to-Buy Snipe",
    Content = "Same as Snipe Mode, but your character walks to the table before buying. It is slower. Only use it if the game will not let you buy from far away.",
})
WalkSnipeToggleRef = ScannerTab:CreateToggle({
    Name     = "Walk-to-Buy Snipe   (ON = running, OFF = stopped)",
    Default  = false,
    Callback = function(v)
        if v then
            if SnipeLoopRunning        then __L.stopSnipe();            pcall(function() SnipeToggleRef:SetValue(false)         end) end
            if OneDollarRunning        then __L.stopOneDollar();        pcall(function() OneDollarToggleRef:SetValue(false)     end) end
            if WalkBuyOneDollarRunning then __L.stopWalkBuyOneDollar(); pcall(function() WalkOneDollarToggleRef:SetValue(false) end) end
            BuyStats = { Found=0, Bought=0, Skipped=0 }; updateStats()
            task.spawn(__L.startWalkBuySnipe)
        else
            __L.stopWalkBuySnipe()
        end
    end,
})

ScannerTab:CreateSection("Low Price Mode ($1 deals)")
ScannerTab:CreateParagraph({
    Title = "Low Price Mode",
    Content = "Ignores StockY and buys ANY shoe listed at or below the price you type below (the default is $1). Good for grabbing free or extremely cheap shoes. Shoes on your Blacklist are still skipped.",
})
ScannerTab:CreateTextBox({
    Name        = "Highest price to pay in Low Price Mode ($)",
    Placeholder = "Type a number like 500  (blank = $1)",
    NumbersOnly = true,
    Callback    = function(v)
        local num = tonumber(v)
        if num and num >= 1 then OneDollarMaxPrice = math.floor(num)
        elseif v == "" then OneDollarMaxPrice = 1 end
    end,
})
OneDollarToggleRef = ScannerTab:CreateToggle({
    Name     = "Low Price Mode   (ON = running, OFF = stopped)",
    Default  = false,
    Callback = function(v)
        Settings.OneDollarMode = v
        if v then
            if SnipeLoopRunning        then __L.stopSnipe();            pcall(function() SnipeToggleRef:SetValue(false)         end) end
            if WalkBuySnipeRunning     then __L.stopWalkBuySnipe();     pcall(function() WalkSnipeToggleRef:SetValue(false)     end) end
            if WalkBuyOneDollarRunning then __L.stopWalkBuyOneDollar(); pcall(function() WalkOneDollarToggleRef:SetValue(false) end) end
            BuyStats = { Found=0, Bought=0, Skipped=0 }; updateStats()
            task.spawn(__L.startOneDollar)
        else
            __L.stopOneDollar()
        end
    end,
})

ScannerTab:CreateSection("Walk-to-Buy Low Price (backup option)")
ScannerTab:CreateParagraph({
    Title = "Walk-to-Buy Low Price",
    Content = "Same as Low Price Mode, but your character walks to the table first. It uses the same price you typed above.",
})
WalkOneDollarToggleRef = ScannerTab:CreateToggle({
    Name     = "Walk-to-Buy Low Price   (ON = running, OFF = stopped)",
    Default  = false,
    Callback = function(v)
        if v then
            if SnipeLoopRunning    then __L.stopSnipe();        pcall(function() SnipeToggleRef:SetValue(false)     end) end
            if OneDollarRunning    then __L.stopOneDollar();    pcall(function() OneDollarToggleRef:SetValue(false) end) end
            if WalkBuySnipeRunning then __L.stopWalkBuySnipe(); pcall(function() WalkSnipeToggleRef:SetValue(false) end) end
            BuyStats = { Found=0, Bought=0, Skipped=0 }; updateStats()
            task.spawn(__L.startWalkBuyOneDollar)
        else
            __L.stopWalkBuyOneDollar()
        end
    end,
})

ScannerTab:CreateSection("Not buying anything? Check this list")
ScannerTab:CreateParagraph({
    Title = "The usual reasons",
    Content = "-  StockY prices are still loading. Wait for the StockY line at the top, or turn off 'Use StockY Price Check' in Settings.\n-  The shoe costs more than your Global Max Price, your StockY Margin, or that shoe's Per-Shoe Cap.\n-  The shoe is on your Blacklist.\n-  'Buy Unsellable Shoes Only' or 'Only buy this shoe' is turned on in Settings.\n-  You do not have enough cash.\n-  Another player bought it first. This is normal, everyone is racing.\n-  The safety pause kicked in: after 5 purchases in a row fail to go through, buying pauses for 15 seconds.\n\nThe line at the top called 'Why shoes were skipped' shows live counts of exactly what is blocking purchases.",
})

ScannerTab:CreateSection("Fix-It Buttons (only if something looks wrong)")
ScannerTab:CreateParagraph({
    Title = "You normally never need these",
    Content = "StockY prices, shoe data and tables all load by themselves when you join. Press these only if a line at the top of this tab is still stuck on 'loading' or 'not loaded' after a minute.",
})
ScannerTab:CreateButton({
    Name     = "Reload StockY Prices",
    Callback = function() task.spawn(__L.refreshStockY) end,
})
ScannerTab:CreateButton({
    Name     = "Reload Shoe Data  (rarity and unsellable info)",
    Callback = function()
        task.spawn(function()
            SneakerModule = nil; SneakerModuleLoaded = false
            __L.loadSneakerModule(); __L.buildUnsellableCache()
        end)
    end,
})
ScannerTab:CreateButton({
    Name     = "Re-scan Tables  (use if new tables are not being noticed)",
    Callback = function()
        task.spawn(function()
            rebuildSlotCache()
            notify("Table Cache", #cachedSlots .. " display slots found.", 4)
        end)
    end,
})


-- ════════════════════════════════════════════════════════════════
--  MARKET TAB  UI  (sub-page: Market)
-- ════════════════════════════════════════════════════════════════

do
    local ListStatusLabel = nil
    local ListGeneration  = 0

    local function buildList()
        if not Tables then return end
        __L.dynClear(ListTab)
        ListGeneration   += 1
        local myGen       = ListGeneration
        lastListRefreshTime = tick()

        -- Gather all shoes currently on tables
        local shoes = {}
        for _, tableModel in ipairs(Tables:GetChildren()) do
            if tableModel.Name == "Table" then
                local ownerVal  = tableModel:FindFirstChild("OwnerValue")
                local ownerName = (ownerVal and ownerVal.Value and ownerVal.Value.Name) or "Unknown"
                for i = 1, 6 do
                    local slot = tableModel:FindFirstChild("DisplaySneaker" .. i)
                    if slot then
                        local sv = slot:FindFirstChild("SneakerValue")
                        local pv = slot:FindFirstChild("Price")
                        local db = slot:FindFirstChild("SellDebounce")
                        if sv and sv.Value ~= "" and not (db and db.Value == true) then
                            table.insert(shoes, {
                                slot     = slot,
                                shoeName = tostring(sv.Value),
                                price    = tonumber(pv and pv.Value) or 0,
                                owner    = ownerName,
                            })
                        end
                    end
                end
            end
        end

        if myGen ~= ListGeneration then return end
        pcall(function() ListStatusLabel:Set("Shoes: " .. #shoes .. " | Refreshed: " .. __L.timeSince(lastListRefreshTime)) end)
        __L.mkSection(ListTab, "Shoes For Sale, cheapest first  (updated " .. os.date("%H:%M:%S") .. ")")

        if #shoes == 0 then
            mkRow(ListTab, "No shoes are for sale right now.")
            return
        end

        table.sort(shoes, function(a, b) return a.price < b.price end)

        for idx, entry in ipairs(shoes) do
            if myGen ~= ListGeneration then return end
            local shoeName = entry.shoeName
            local price    = entry.price
            local owner    = entry.owner
            local slot     = entry.slot

            -- Show StockY comparison
            local sp      = StockYCache[shoeName]
            local diffStr = "StockY: N/A"
            if sp and sp > 0 then
                local diff    = price - sp
                local pct     = math.floor((diff / sp) * 100)
                local sign    = diff >= 0 and "+" or ""
                local arrow   = diff > 0 and "▲" or (diff < 0 and "▼" or "=")
                diffStr = "StockY: " .. fmtMoney(sp) .. "  " .. arrow .. " " .. sign .. pct .. "% (" .. sign .. fmtMoney(diff) .. ")"
            end

            __L.mkRowBtn(ListTab, shoeName .. "  |  " .. fmtMoney(price) .. "  |  " .. owner, "BUY  " .. fmtMoney(price), function()
                local sv = slot:FindFirstChild("SneakerValue")
                local pv = slot:FindFirstChild("Price")
                local db = slot:FindFirstChild("SellDebounce")
                if not sv or sv.Value == "" then
                    notify("List Buy", "Slot is now empty!", 3, "X"); return
                end
                if db and db.Value == true then
                    notify("List Buy", "Already sold!", 3, "X"); return
                end
                task.spawn(function()
                    __L.fireAndConfirm(slot, sv.Value, tonumber(pv and pv.Value) or 0, true)
                    pcall(function() ListStatusLabel:Set("Bought! Refreshing...") end)
                    task.wait(2); buildList()
                end)
            end, { sub = diffStr })

            if idx % 8 == 0 then task.wait() end
            if myGen ~= ListGeneration then return end
        end
    end

    ListTab:CreateSection("Live Market (every shoe for sale right now)")
    ListTab:CreateParagraph({
        Title = "How to use this page",
        Content = "Press Refresh List to see every shoe for sale, cheapest first. Next to each one you can see how its price compares to StockY (a down arrow means cheaper than market, an up arrow means more expensive).\n\nPress BUY to buy that shoe yourself. A manual buy ignores your filters and only checks that you can afford it.",
    })
    ListStatusLabel = mkRow(ListTab, "Nothing loaded yet. Press Refresh List below.", { static = true })
    ListTab:CreateButton({
        Name     = "Refresh List now",
        Callback = function()
            task.spawn(function()
                pcall(function() ListStatusLabel:Set("Refreshing...") end)
                buildList()
            end)
        end,
    })
    ListTab:CreateToggle({
        Name     = "Auto-refresh the list every 5 seconds",
        Default  = false,
        Callback = function(v)
            listAutoRefresh = v
            if v then
                task.spawn(function()
                    while listAutoRefresh and srsAlive() do buildList(); task.wait(5) end
                end)
            end
        end,
    })
end


-- ════════════════════════════════════════════════════════════════
--  SELL TAB  UI  (sub-page: Sell & Table)
-- ════════════════════════════════════════════════════════════════

do
    local SellStatusLabel = nil
    local SellGeneration  = 0

    local function buildSellList()
        __L.dynClear(SellTab)
        SellGeneration   += 1
        local myGen       = SellGeneration
        lastSellRefreshTime = tick()

        local allShoes = {}
        for _, item in ipairs(SellableInventory:GetChildren())   do table.insert(allShoes, { name = item.Name, sellable = true  }) end
        for _, item in ipairs(UnsellableInventory:GetChildren()) do table.insert(allShoes, { name = item.Name, sellable = false }) end

        local total = #allShoes
        pcall(function() SellStatusLabel:Set("Inventory: " .. total .. " | Refreshed: " .. __L.timeSince(lastSellRefreshTime)) end)
        __L.mkSection(SellTab, "Your Shoes (" .. total .. ")  -  updated " .. os.date("%H:%M:%S"))

        if total == 0 then
            mkRow(SellTab, "You do not own any shoes yet.")
            return
        end

        table.sort(allShoes, function(a, b) return a.name < b.name end)

        for idx, shoe in ipairs(allShoes) do
            if myGen ~= SellGeneration then return end
            local shoeName = shoe.name
            local sellable = shoe.sellable
            local badge    = sellable and "[SELLABLE]" or "[UNSELLABLE]"
            local sp        = StockYCache[shoeName]
            local listPrice = __L.calcSellPrice(shoeName)
            local stockStr

            if Settings.UseFixedSellPrice then
                stockStr = "Fixed: " .. fmtMoney(Settings.FixedSellPrice) .. (sp and (" | StockY: " .. fmtMoney(sp)) or "")
            else
                local pctStr = Settings.SellStockYOffsetPct >= 0
                    and ("+" .. Settings.SellStockYOffsetPct .. "%")
                    or  (Settings.SellStockYOffsetPct .. "%")
                stockStr = sp
                    and ("StockY: " .. fmtMoney(sp) .. " (" .. pctStr .. ") -> " .. fmtMoney(listPrice))
                    or  ("StockY: N/A -> Fallback: " .. fmtMoney(pendingSellPrice))
            end

            local lbl = mkRow(SellTab, shoeName .. "  |  " .. badge .. "  |  " .. stockStr)
            sellLabelRefs[shoeName] = { label = lbl, sellable = sellable }

            __L.mkBtn(SellTab, "Put on my table: " .. shoeName .. "  (" .. fmtMoney(listPrice) .. ")  [" .. (sellable and "SELLABLE" or "UNSELLABLE") .. "]", function()
                local stillOwned = sellable and __L.isSellable(shoeName) or __L.ownsUnsellable(shoeName)
                if not stillOwned then
                    notify("Sell Error", shoeName .. " not in inventory.", 4, "X"); return
                end
                local ok, price = __L.listShoeOnTable(shoeName)
                if ok then
                    notify("Listed!", shoeName .. " -> " .. fmtMoney(price), 4, "Check")
                    task.wait(0.8); buildSellList()
                else
                    notify("Sell Error", "Failed to list " .. shoeName, 4, "X")
                end
            end)

            if idx % 8 == 0 then task.wait() end
            if myGen ~= SellGeneration then return end
        end
    end

    SellTab:CreateSection("How Your Shoes Get Priced")
    SellTab:CreateParagraph({
        Title = "The price formula",
        Content = "When a shoe is listed (by a button below or by Auto-Sell), its price is the StockY price, moved up or down by the percent you choose here. If StockY has no price for that shoe, the Backup price is used instead.\n\nWant one price for everything? Use Fixed Price further down. It overrides all of this.",
    })
    SellStatusLabel = mkRow(SellTab, "Nothing loaded yet. Press Refresh Inventory at the bottom of this page.", { static = true })

    SellTab:CreateTextBox({
        Name        = "Backup price ($)  -  used when StockY has no price for a shoe",
        Placeholder = "e.g. 5000",
        NumbersOnly = true,
        Callback    = function(v)
            local num = tonumber(v)
            if num and num > 0 then pendingSellPrice = math.floor(num); __L.updateSellPriceLabels() end
        end,
    })

    local sliderDebounce = nil
    SellTab:CreateSlider({
        Name     = "Price vs StockY (%):  0 = market,  10 = 10% above,  -10 = 10% below",
        Min      = -50,
        Max      = 100,
        Default  = math.floor(tonumber(Settings.SellStockYOffsetPct) or 0),
        Callback = function(v)
            saveSetting("SellStockYOffsetPct", v)
            if sliderDebounce then task.cancel(sliderDebounce) end
            sliderDebounce = task.delay(0.3, function() sliderDebounce = nil; __L.updateSellPriceLabels() end)
        end,
    })

    SellTab:CreateSection("Fixed Price (one price for everything)")
    SellTab:CreateParagraph({
        Title = "Fixed price",
        Content = "Turn this on to list every shoe at the exact same price, ignoring StockY completely.",
    })
    SellTab:CreateToggle({
        Name     = "Use ONE fixed price for every shoe",
        Default  = Settings.UseFixedSellPrice,
        Callback = function(v) saveSetting("UseFixedSellPrice", v); __L.updateSellPriceLabels() end,
    })
    SellTab:CreateTextBox({
        Name        = "Fixed price ($)",
        Placeholder = "e.g. 5000",
        NumbersOnly = true,
        Callback    = function(v)
            local num = tonumber(v)
            if num and num > 0 then saveSetting("FixedSellPrice", math.floor(num)); __L.updateSellPriceLabels() end
        end,
    })

    SellTab:CreateSection("Auto-Sell (keeps your table full)")
    SellTab:CreateParagraph({
        Title = "Auto-Sell",
        Content = "Whenever a slot on your table is empty, Auto-Sell puts the next shoe from your inventory on it, at the price set above. It keeps going until you turn it off.\n\nYour table has 3 slots (6 if you own a table skin).",
    })
    SellTab:CreateToggle({
        Name     = "Auto-Sell: every shoe   (ON = running)",
        Default  = false,
        Callback = function(v)
            if v then
                SellAllRunning = false; for _, c in ipairs(SellAllConns) do c:Disconnect() end; SellAllConns = {}
                SellUnsellRunning = false; for _, c in ipairs(SellUnsellConns) do c:Disconnect() end; SellUnsellConns = {}
                __L.startSellAll()
            else
                SellAllRunning = false; for _, c in ipairs(SellAllConns) do c:Disconnect() end; SellAllConns = {}
            end
        end,
    })
    SellTab:CreateToggle({
        Name     = "Auto-Sell: unsellable shoes only   (ON = running)",
        Default  = false,
        Callback = function(v)
            if v then
                SellAllRunning = false; for _, c in ipairs(SellAllConns) do c:Disconnect() end; SellAllConns = {}
                SellUnsellRunning = false; for _, c in ipairs(SellUnsellConns) do c:Disconnect() end; SellUnsellConns = {}
                __L.startSellUnsell()
            else
                SellUnsellRunning = false; for _, c in ipairs(SellUnsellConns) do c:Disconnect() end; SellUnsellConns = {}
            end
        end,
    })

    SellTab:CreateSection("Flash Listing (advanced, read the warning)")
    SellTab:CreateParagraph({
        Title = "Flash Listing",
        Content = "Over and over, this lists a random shoe from your inventory in slot 1 at a random price, then takes it off again a moment later. Every 5 to 15 listings, the price is $1.\n\nWARNING: while a shoe is listed at $1, another player or sniper can buy it at that price and you lose the shoe. Only use this if you understand and accept that.",
    })
    SellTab:CreateToggle({
        Name     = "Flash Listing   (ON = running, see warning above)",
        Default  = false,
        Callback = function(v)
            if v then
                SellAllRunning    = false; for _, c in ipairs(SellAllConns)    do c:Disconnect() end; SellAllConns    = {}
                SellUnsellRunning = false; for _, c in ipairs(SellUnsellConns) do c:Disconnect() end; SellUnsellConns = {}
                __L.startFlashList()
            else
                FlashListRunning = false
                if flashListedSlot then __L.removeShoeFromSlot(flashListedSlot); flashListedSlot = nil end
            end
        end,
    })

    SellTab:CreateSection("Refresh")
    SellTab:CreateButton({
        Name     = "Refresh Inventory",
        Callback = function()
            task.spawn(function()
                pcall(function() SellStatusLabel:Set("Loading inventory...") end)
                buildSellList()
            end)
        end,
    })
end


-- ════════════════════════════════════════════════════════════════
--  BLACKLIST TAB  UI  (sub-page: Blacklist)
-- ════════════════════════════════════════════════════════════════

do
    local BlacklistStatusLabel  = nil
    local BlacklistSearchFilter = ""
    local BlacklistGeneration   = 0

    local function buildBlacklistTab()
        __L.dynClear(BlacklistTab)
        BlacklistGeneration += 1
        local myGen          = BlacklistGeneration

        local allShoes = {}
        if SneakerModuleLoaded and SneakerModule and type(SneakerModule.sneakers) == "table" then
            for shoeName, data in pairs(SneakerModule.sneakers) do
                local unsell = type(data) == "table" and table.find(data, "Unsellable") ~= nil
                if BlacklistSearchFilter == "" or shoeName:lower():find(BlacklistSearchFilter:lower(), 1, true) then
                    table.insert(allShoes, { name = shoeName, unsellable = unsell, knownType = true })
                end
            end
        else
            -- Module not loaded — show only what's already in the blacklist
            for shoeName in pairs(Blacklist) do
                if BlacklistSearchFilter == "" or shoeName:lower():find(BlacklistSearchFilter:lower(), 1, true) then
                    table.insert(allShoes, { name = shoeName, unsellable = false, knownType = false })
                end
            end
        end

        table.sort(allShoes, function(a, b) return a.name < b.name end)

        local blCount     = 0
        for _ in pairs(Blacklist) do blCount += 1 end
        local moduleNote  = SneakerModuleLoaded and "" or "  WARNING: Module not loaded"
        pcall(function()
            BlacklistStatusLabel:Set("Total: " .. #allShoes .. " | Blacklisted: " .. blCount
                .. (BlacklistSearchFilter ~= "" and (" | Filter: \"" .. BlacklistSearchFilter .. "\"") or "")
                .. moduleNote)
        end)

        if myGen ~= BlacklistGeneration then return end

        __L.mkSection(BlacklistTab,
            SneakerModuleLoaded
                and ("All Shoes (" .. #allShoes .. ")" .. (BlacklistSearchFilter ~= "" and " — filtered" or "") .. " — " .. os.date("%H:%M:%S"))
                or  ("Saved Blacklist (" .. #allShoes .. " entries)"))

        if #allShoes == 0 then
            mkRow(BlacklistTab, SneakerModuleLoaded and "No shoes match filter." or "Blacklist is empty.")
            return
        end

        for idx, shoe in ipairs(allShoes) do
            if myGen ~= BlacklistGeneration then return end
            local shoeName = shoe.name
            local typeTag  = shoe.knownType and (shoe.unsellable and "  [UNSELLABLE]" or "  [SELLABLE]") or ""
            local blTag    = __L.isBlacklisted(shoeName) and "  BLACKLISTED" or ""

            __L.dynToggle(BlacklistTab, {
                Name     = shoeName .. typeTag .. blTag,
                Default  = __L.isBlacklisted(shoeName),
                Callback = function(v)
                    if v then Blacklist[shoeName] = true else Blacklist[shoeName] = nil end
                    __L.saveBlacklist()
                    local cnt = 0; for _ in pairs(Blacklist) do cnt += 1 end
                    pcall(function() BlacklistStatusLabel:Set("Total: " .. #allShoes .. " | Blacklisted: " .. cnt .. moduleNote) end)
                    notify(
                        v and "Blacklisted" or "Un-Blacklisted",
                        shoeName .. (v and " will be skipped." or " will be bought."),
                        3)
                end,
            })

            if idx % 15 == 0 then task.wait() end
            if myGen ~= BlacklistGeneration then return end
        end
    end

    BlacklistTab:CreateSection("What Is the Blacklist?")
    BlacklistStatusLabel = mkRow(BlacklistTab, "Loading saved blacklist...", { static = true })
    BlacklistTab:CreateParagraph({
        Title = "Shoes you never want to buy",
        Content = "A shoe on the blacklist is NEVER bought by any mode (Snipe, Scan Once, Low Price, and the Walk-to-Buy modes).\n\nFlip the switch next to a shoe in the list below to blacklist it, or use the bulk buttons for whole groups. Changes save automatically.",
    })
    BlacklistTab:CreateButton({
        Name     = "Load / Refresh Shoe List  (press this if the list is empty)",
        Callback = function()
            task.spawn(function()
                if not SneakerModuleLoaded then __L.loadSneakerModule(); task.wait(1) end
                buildBlacklistTab()
            end)
        end,
    })

    BlacklistTab:CreateSection("Find a Shoe")
    BlacklistTab:CreateTextBox({
        Name        = "Search by shoe name",
        Placeholder = "e.g. Air Jordan  (then press Apply Filter)",
        Callback    = function(v) BlacklistSearchFilter = tostring(v or ""):lower() end,
    })
    BlacklistTab:CreateButton({ Name = "Apply Filter",           Callback = function() task.spawn(buildBlacklistTab) end })
    BlacklistTab:CreateButton({ Name = "Clear Filter  (show every shoe again)", Callback = function() BlacklistSearchFilter = ""; task.spawn(buildBlacklistTab) end })

    BlacklistTab:CreateSection("Blacklist Many Shoes at Once")
    BlacklistTab:CreateButton({
        Name     = "Blacklist every UNSELLABLE shoe",
        Callback = function()
            if not SneakerModuleLoaded or not SneakerModule or type(SneakerModule.sneakers) ~= "table" then
                notify("Blacklist", "Load SneakerModule first.", 4); return
            end
            local count = 0
            for n, d in pairs(SneakerModule.sneakers) do
                if type(d) == "table" and table.find(d, "Unsellable") then Blacklist[n] = true; count += 1 end
            end
            __L.saveBlacklist()
            notify("Blacklist", count .. " unsellable blacklisted.", 5)
            task.spawn(buildBlacklistTab)
        end,
    })
    BlacklistTab:CreateButton({
        Name     = "Blacklist every SELLABLE shoe",
        Callback = function()
            if not SneakerModuleLoaded or not SneakerModule or type(SneakerModule.sneakers) ~= "table" then
                notify("Blacklist", "Load SneakerModule first.", 4); return
            end
            local count = 0
            for n, d in pairs(SneakerModule.sneakers) do
                if type(d) == "table" and not table.find(d, "Unsellable") then Blacklist[n] = true; count += 1 end
            end
            __L.saveBlacklist()
            notify("Blacklist", count .. " sellable blacklisted.", 5)
            task.spawn(buildBlacklistTab)
        end,
    })
    BlacklistTab:CreateButton({
        Name     = "Clear the blacklist  (removes every shoe from it)",
        Callback = function()
            local count = 0; for _ in pairs(Blacklist) do count += 1 end
            Blacklist = {}; __L.saveBlacklist()
            notify("Blacklist Cleared", count .. " entries removed.", 4)
            task.spawn(buildBlacklistTab)
        end,
    })

    BlacklistTab:CreateSection("By Rarity")
    BlacklistTab:CreateParagraph({
        Title = "One tap for a whole rarity",
        Content = "Pick a rarity below to blacklist (or un-blacklist) every shoe of that rarity.\nRarities: Common, Uncommon, Epic, Legendary, Limited, Grail, Special, Legacy.",
    })

    local function blacklistByRarity(rarityTag, add)
        if not SneakerModuleLoaded or not SneakerModule or type(SneakerModule.sneakers) ~= "table" then
            notify("Rarity Blacklist", "Load SneakerModule first!", 5); return
        end
        local count = 0
        for shoeName, data in pairs(SneakerModule.sneakers) do
            if type(data) == "table" and data["Rarity"] == rarityTag then
                if add then Blacklist[shoeName] = true else Blacklist[shoeName] = nil end
                count += 1
            end
        end
        __L.saveBlacklist()
        local action = add and "blacklisted" or "un-blacklisted"
        notify(rarityTag .. " " .. action, count .. " " .. rarityTag .. " shoes " .. action .. ".", 4)
        task.spawn(buildBlacklistTab)
    end

    for _, rarity in ipairs({ "Common","Uncommon","Epic","Legendary","Limited","Grail","Special","Legacy" }) do
        local tag = rarity
        BlacklistTab:CreateButton({ Name = "Blacklist All "    .. tag, Callback = function() blacklistByRarity(tag, true)  end })
        BlacklistTab:CreateButton({ Name = "Un-Blacklist All " .. tag, Callback = function() blacklistByRarity(tag, false) end })
    end

    BlacklistTab:CreateSection("By Value (skip cheap shoes)")
    BlacklistTab:CreateParagraph({
        Title = "Only chase valuable shoes",
        Content = "Blacklists every shoe whose StockY price is BELOW the number you type. Needs StockY prices to be loaded (see the top of the Sniper tab).",
    })
    BlacklistTab:CreateTextBox({
        Name        = "Minimum StockY price to keep ($)",
        Placeholder = "e.g. 5000",
        NumbersOnly = true,
        Callback    = function(v)
            local num = tonumber(v); if num ~= nil and num >= 0 then BlacklistMinPrice = math.floor(num) end
        end,
    })
    BlacklistTab:CreateButton({
        Name     = "Blacklist every shoe worth LESS than that",
        Callback = function()
            if BlacklistMinPrice <= 0 then notify("Price Blacklist", "Set a price above 0 first!", 4); return end
            if not SneakerModuleLoaded or not SneakerModule or type(SneakerModule.sneakers) ~= "table" then
                notify("Price Blacklist", "Load SneakerModule first!", 5); return
            end
            local count, noData = 0, 0
            for shoeName in pairs(SneakerModule.sneakers) do
                local sp = StockYCache[shoeName]
                if sp and type(sp) == "number" and sp > 0 then
                    if sp < BlacklistMinPrice then Blacklist[shoeName] = true; count += 1 end
                else noData += 1 end
            end
            __L.saveBlacklist()
            notify("Price Blacklist", count .. " blacklisted. (" .. noData .. " no StockY data skipped)", 6)
            task.spawn(buildBlacklistTab)
        end,
    })
    BlacklistTab:CreateButton({
        Name     = "Remove every shoe worth LESS than that from the blacklist",
        Callback = function()
            if BlacklistMinPrice <= 0 then notify("Price Blacklist", "Set a price above 0 first!", 4); return end
            if not SneakerModuleLoaded or not SneakerModule or type(SneakerModule.sneakers) ~= "table" then
                notify("Price Blacklist", "Load SneakerModule first!", 4); return
            end
            local count = 0
            for shoeName in pairs(SneakerModule.sneakers) do
                local sp = StockYCache[shoeName]
                if sp and type(sp) == "number" and sp > 0 and sp < BlacklistMinPrice then
                    Blacklist[shoeName] = nil; count += 1
                end
            end
            __L.saveBlacklist()
            notify("Price Blacklist", count .. " removed from blacklist.", 5)
            task.spawn(buildBlacklistTab)
        end,
    })

    BlacklistTab:CreateSection("Share")
    BlacklistTab:CreateButton({
        Name     = "Copy my blacklist  (paste it anywhere to share)",
        Callback = function()
            local names = {}
            for n in pairs(Blacklist) do table.insert(names, n) end
            table.sort(names)
            pcall(function() setclipboard(table.concat(names, "\n")) end)
            notify("Clipboard", #names .. " shoe(s) copied!", 4)
        end,
    })
end


-- ════════════════════════════════════════════════════════════════
--  PER-SHOE CAPS TAB  UI  (sub-page: Per-Shoe Caps)
--  ★ Now shows StockY price right next to the shoe name ★
-- ════════════════════════════════════════════════════════════════

do
    local MaxBuyStatusLabel    = nil
    local MaxBuyGeneration     = 0
    local MaxBuyShoeListFilter = ""
    local MaxBuyShowCapsOnly   = false

    local function buildMaxBuyList()
        __L.dynClear(MaxBuyTab)
        MaxBuyGeneration += 1
        local myGen       = MaxBuyGeneration
        local filter      = MaxBuyShoeListFilter:lower()

        -- Build list of shoes to show
        local allShoes = {}
        if SneakerModuleLoaded and SneakerModule and type(SneakerModule.sneakers) == "table" then
            for shoeName in pairs(SneakerModule.sneakers) do
                local matchFilter = filter == "" or shoeName:lower():find(filter, 1, true)
                local matchCaps   = not MaxBuyShowCapsOnly or MaxBuyPerShoe[shoeName] ~= nil
                if matchFilter and matchCaps then table.insert(allShoes, shoeName) end
            end
        else
            -- Module not loaded — show only capped shoes
            for name in pairs(MaxBuyPerShoe) do
                if filter == "" or name:lower():find(filter, 1, true) then table.insert(allShoes, name) end
            end
        end
        table.sort(allShoes)

        local capCount = 0
        for _ in pairs(MaxBuyPerShoe) do capCount += 1 end
        local showing  = MaxBuyShowCapsOnly and "Capped shoes only" or "All shoes"
        pcall(function() MaxBuyStatusLabel:Set(showing .. " — " .. #allShoes .. " shown, " .. capCount .. " capped") end)

        -- Empty-state messages
        if #allShoes == 0 then
            local msg
            if not SneakerModuleLoaded then
                msg = "Shoe data has not loaded yet. Go to the Sniper tab, press Reload Shoe Data, then come back here."
            elseif MaxBuyShowCapsOnly then
                msg = "You have no caps set yet. Turn off 'Show Capped Only' to see all shoes."
            else
                msg = "No shoes match your search."
            end
            mkRow(MaxBuyTab, msg)
            return
        end

        local hint = MaxBuyShowCapsOnly
            and ("Capped Shoes (" .. #allShoes .. ") — type a new price to update, leave blank to remove")
            or  ("All Shoes ("    .. #allShoes .. ") — type a price next to any shoe to set a cap")
        __L.mkSection(MaxBuyTab, hint)

        for idx, shoeName in ipairs(allShoes) do
            if myGen ~= MaxBuyGeneration then return end
            local sn  = shoeName
            local cap = MaxBuyPerShoe[sn]
            local sp  = StockYCache[sn]

            -- ── Row: shoe name + cap + StockY price ─────────────────
            -- StockY price is shown prominently so you can see market
            -- value at a glance before deciding what cap to set.
            local infoLine = sn
            if sp and sp > 0 then
                infoLine = infoLine .. "  |  StockY: " .. fmtMoney(sp)
            else
                infoLine = infoLine .. "  |  StockY: N/A"
            end
            if cap then
                infoLine = infoLine .. "  |  Cap: " .. fmtMoney(cap)
            end
            mkRow(MaxBuyTab, infoLine)

            -- ── Input: set the cap price ────────────────────────────
            local placeholder = cap
                and ("Cap: " .. fmtMoney(cap) .. " — clear to remove")
                or  "Type price (e.g. 50000) then press Enter"
            __L.dynTextBox(MaxBuyTab, {
                Name        = "Cap_" .. sn,
                Placeholder = placeholder,
                NumbersOnly = true,
                Callback    = function(v)
                    v = tostring(v or ""):match("^%s*(.-)%s*$")
                    local n = tonumber(v)
                    if n and n > 0 then
                        MaxBuyPerShoe[sn] = math.floor(n)
                        __L.saveMaxBuyPrices()
                        local cnt = 0; for _ in pairs(MaxBuyPerShoe) do cnt += 1 end
                        notify("Cap Set", sn .. " — max buy: " .. fmtMoney(math.floor(n)), 3)
                        pcall(function()
                            MaxBuyStatusLabel:Set(showing .. " — " .. #allShoes .. " shown, " .. cnt .. " capped")
                        end)
                    elseif v == "" and MaxBuyPerShoe[sn] then
                        MaxBuyPerShoe[sn] = nil
                        __L.saveMaxBuyPrices()
                        local cnt = 0; for _ in pairs(MaxBuyPerShoe) do cnt += 1 end
                        notify("Cap Removed", sn .. " now uses the global max price.", 4)
                        pcall(function()
                            MaxBuyStatusLabel:Set(showing .. " — " .. #allShoes .. " shown, " .. cnt .. " capped")
                        end)
                        if MaxBuyShowCapsOnly then task.spawn(buildMaxBuyList) end
                    end
                end,
            })

            if idx % 12 == 0 then task.wait() end
            if myGen ~= MaxBuyGeneration then return end
        end
    end

    -- ── Static UI ──────────────────────────────────────────────
    MaxBuyTab:CreateSection("What Is a Per-Shoe Cap?")
    MaxBuyTab:CreateParagraph({
        Title = "A price limit for ONE shoe",
        Content = "A cap is the most you will ever pay for one specific shoe. Shoes without a cap just follow the Global Max Price from the Settings tab.\n\nA cap can only make buying stricter: every limit is checked, and the lowest one wins.",
    })

    MaxBuyTab:CreateSection("How to Set a Cap")
    MaxBuyTab:CreateParagraph({ Title = "Step 1", Content = "Make sure the shoe list at the bottom of this page has loaded. If it is empty, press Reload Shoe List." })
    MaxBuyTab:CreateParagraph({ Title = "Step 2", Content = "Find your shoe. Use Search below to narrow the list." })
    MaxBuyTab:CreateParagraph({ Title = "Step 3", Content = "Type the most you want to pay in the box under the shoe name, then press Enter." })
    MaxBuyTab:CreateParagraph({ Title = "Step 4", Content = "To remove a cap, empty the box and press Enter." })

    MaxBuyTab:CreateSection("What to Show")
    MaxBuyTab:CreateToggle({
        Name     = "Only show shoes that already have a cap",
        Default  = false,
        Callback = function(v) MaxBuyShowCapsOnly = v; task.spawn(buildMaxBuyList) end,
    })
    MaxBuyTab:CreateButton({
        Name     = "Reload Shoe List",
        Callback = function()
            task.spawn(function()
                if not SneakerModuleLoaded then
                    notify("Loading...", "Loading shoe list, please wait.", 4)
                    __L.loadSneakerModule(); task.wait(1)
                end
                buildMaxBuyList()
            end)
        end,
    })

    MaxBuyTab:CreateSection("Search")
    MaxBuyTab:CreateTextBox({
        Name        = "Search by shoe name",
        Placeholder = "e.g. Air Bogdan  (then press Apply Search)",
        Callback    = function(v) MaxBuyShoeListFilter = tostring(v or ""):lower() end,
    })
    MaxBuyTab:CreateButton({ Name = "Apply Search",           Callback = function() task.spawn(buildMaxBuyList) end })
    MaxBuyTab:CreateButton({ Name = "Clear Search  (show every shoe again)", Callback = function() MaxBuyShoeListFilter = ""; task.spawn(buildMaxBuyList) end })

    MaxBuyTab:CreateSection("Set Caps for Every Shoe at Once")
    MaxBuyTab:CreateParagraph({
        Title = "Caps based on StockY",
        Content = "Sets a cap on every shoe that has a StockY price, as a percent of that price. Needs StockY prices to be loaded.",
    })
    local pendingBulkPct = 100
    MaxBuyTab:CreateSlider({
        Name     = "Cap = this % of StockY price   (100 = exactly the StockY price)",
        Min      = 10,
        Max      = 150,
        Default  = 100,
        Callback = function(v) pendingBulkPct = v end,
    })
    MaxBuyTab:CreateButton({
        Name     = "Apply that % as a cap to every shoe",
        Callback = function()
            local count, noData = 0, 0
            for shoeName, sp in pairs(StockYCache) do
                if type(sp) == "number" and sp > 0 then
                    MaxBuyPerShoe[shoeName] = math.max(1, math.floor(sp * pendingBulkPct / 100))
                    count += 1
                else noData += 1 end
            end
            __L.saveMaxBuyPrices()
            notify("Bulk Caps Applied", count .. " shoes capped at " .. pendingBulkPct .. "% of StockY. " .. noData .. " had no StockY data.", 7)
            task.spawn(buildMaxBuyList)
        end,
    })
    MaxBuyTab:CreateButton({
        Name     = "Remove ALL caps  (back to the Global Max Price)",
        Callback = function()
            local count = 0; for _ in pairs(MaxBuyPerShoe) do count += 1 end
            MaxBuyPerShoe = {}; __L.saveMaxBuyPrices()
            notify("All Caps Removed", count .. " caps cleared.", 5)
            task.spawn(buildMaxBuyList)
        end,
    })
    MaxBuyTab:CreateButton({
        Name     = "Copy all my caps  (paste anywhere to share)",
        Callback = function()
            local lines, names = {}, {}
            for name in pairs(MaxBuyPerShoe) do table.insert(names, name) end
            table.sort(names)
            for _, name in ipairs(names) do table.insert(lines, name .. " = " .. fmtMoney(MaxBuyPerShoe[name])) end
            pcall(function() setclipboard(table.concat(lines, "\n")) end)
            notify("Copied!", #lines .. " cap(s) copied.", 4)
        end,
    })

    MaxBuyTab:CreateSection("Shoe List")
    MaxBuyStatusLabel = mkRow(MaxBuyTab, "Loading shoe list...", { static = true })

    task.defer(function()
        task.wait(0.3)
        buildMaxBuyList()
    end)
end


-- ════════════════════════════════════════════════════════════════
--  SETTINGS TAB  UI  (sub-page: Settings)
-- ════════════════════════════════════════════════════════════════

do
    local function truncateURL(url)
        if url == "" then return "None set" end
        return #url <= 40 and url or (url:sub(1, 37) .. "...")
    end

    SettingsTab:CreateSection("Discord Alerts (optional, skip if you do not use Discord)")
    SettingsTab:CreateParagraph({
        Title = "Get a Discord message for every sale",
        Content = "Paste a Discord webhook link and the script posts a message whenever you buy a shoe, sell a shoe, or get disconnected.\n\nTo make one in Discord: Server Settings, Integrations, Webhooks, New Webhook, Copy Webhook URL.",
    })
    local WebhookLoadedLabel = mkRow(SettingsTab, "Saved webhook: " .. truncateURL(Settings.WebhookURL), { static = true })
    local pendingWebhookURL  = ""
    SettingsTab:CreateTextBox({
        Name        = "Paste your webhook link here",
        Placeholder = "https://discord.com/api/webhooks/...",
        Callback    = function(v) pendingWebhookURL = tostring(v or "") end,
    })
    SettingsTab:CreateButton({
        Name     = "Save Webhook",
        Callback = function()
            if pendingWebhookURL == "" then notify("Webhook", "No URL entered.", 3); return end
            Settings.WebhookURL = pendingWebhookURL; __L.saveWebhook(Settings.WebhookURL)
            pcall(function() WebhookLoadedLabel:Set("Saved webhook: " .. truncateURL(Settings.WebhookURL)) end)
            notify("Webhook Saved", "Your webhook has been saved.", 3)
        end,
    })
    SettingsTab:CreateButton({
        Name     = "Send a Test Message  (check that it works)",
        Callback = function()
            if Settings.WebhookURL == "" then notify("Webhook", "No webhook URL set!", 3); return end
            __L.sendWebhook("TEST SHOE - Air Bogdan 4", 12345, true, "TEST", "TestSeller123")
            notify("Test Sent", "Check your Discord!", 3)
        end,
    })
    SettingsTab:CreateButton({
        Name     = "Send a Test Disconnect Alert",
        Callback = function()
            if Settings.WebhookURL == "" then notify("Webhook", "No webhook URL set!", 3); return end
            __L.sendKickWebhook("Manual test")
            notify("Test Sent", "Check your Discord!", 3)
        end,
    })
    SettingsTab:CreateButton({
        Name     = "Remove Saved Webhook",
        Callback = function()
            Settings.WebhookURL = ""; pendingWebhookURL = ""; __L.saveWebhook("")
            pcall(function() WebhookLoadedLabel:Set("Current Webhook: None set") end)
            notify("Webhook Removed", "Webhook cleared.", 3)
        end,
    })

    SettingsTab:CreateSection("What the Sniper Is Allowed to Buy")
    SettingsTab:CreateParagraph({
        Title = "Your buying rules",
        Content = "A shoe has to pass EVERY rule below before it gets bought. Rules you turn off are simply ignored.",
    })
    SettingsTab:CreateToggle({ Name = "Use a Global Max Price  (set it below)", Default = Settings.PriceFilter, Callback = function(v) saveSetting("PriceFilter", v) end })
    SettingsTab:CreateTextBox({ Name = "Global Max Price ($)  -  never pay more than this for any shoe", Default = tostring(Settings.MaxPrice), Placeholder = "e.g. 100000", NumbersOnly = true, Callback = function(v) saveSetting("MaxPrice", tonumber(v) or 100000) end })
    SettingsTab:CreateToggle({ Name = "Use StockY Price Check  (recommended)", Default = Settings.UseStockYCheck, Callback = function(v) saveSetting("UseStockYCheck", v) end })
    SettingsTab:CreateParagraph({ Title = "StockY Check", Content = "StockY is the shoe's market price. When this is on, a listing priced above the StockY Margin (set in the next section) is skipped. Buying waits until StockY prices have loaded." })
    SettingsTab:CreateToggle({ Name = "Only buy UNSELLABLE shoes  (skip every sellable shoe)", Default = Settings.UnsellableOnly, Callback = function(v) saveSetting("UnsellableOnly", v) end })
    SettingsTab:CreateTextBox({ Name = "Only buy this shoe  (leave blank to buy any shoe)", Default = tostring(Settings.TargetShoe), Placeholder = "e.g. Air Bogdan 4  (part of the name is enough)", Callback = function(v) saveSetting("TargetShoe", tostring(v or "")) end })

    SettingsTab:CreateSection("How Far Above Market Price Is OK?")
    SettingsTab:CreateParagraph({
        Title = "StockY Margin",
        Content = "How far above the StockY price the sniper may pay.\n100 = only at or below StockY.\n120 = up to 20% above.\n150 = up to 50% above.\n\nOnly applies while 'Use StockY Price Check' is on.",
    })
    SettingsTab:CreateSlider({
        Name     = "StockY Margin (% of the StockY price)",
        Min      = 50,
        Max      = 200,
        Default  = math.floor(((tonumber(Settings.StockYMargin) or 1.0) * 100) + 0.5),
        Callback = function(v) saveSetting("StockYMargin", v / 100) end,
    })

    SettingsTab:CreateSection("Shoes StockY Has No Price For")
    SettingsTab:CreateParagraph({
        Title = "What to do with unknown shoes",
        Content = "Some shoes are missing from StockY, so there is nothing to compare their price to. Pick how to treat them:\n\nOption 1 buys them only if they cost less than the cap you set.\nOption 2 skips all of them. It only works while Option 1 is OFF.",
    })
    SettingsTab:CreateToggle({
        Name     = "Option 1 (recommended): buy unknown shoes up to the cap below",
        Default  = Settings.UseMaxPriceFallback,
        Callback = function(v)
            saveSetting("UseMaxPriceFallback", v)
            if v and Settings.BlockNoStockYData then saveSetting("BlockNoStockYData", false) end
            notify("Fallback Cap", v and ("ON — unknown shoes capped at " .. fmtMoney(Settings.MaxPriceFallback)) or "OFF", 3)
        end,
    })
    SettingsTab:CreateTextBox({ Name = "Cap for unknown shoes ($)", Default = tostring(Settings.MaxPriceFallback), Placeholder = "e.g. 50000", NumbersOnly = true, Callback = function(v) local num = tonumber(v); if num and num > 0 then saveSetting("MaxPriceFallback", math.floor(num)) end end })
    SettingsTab:CreateToggle({
        Name     = "Option 2 (strictest): skip unknown shoes  (needs Option 1 OFF)",
        Default  = Settings.BlockNoStockYData,
        Callback = function(v)
            saveSetting("BlockNoStockYData", v)
            if v and Settings.UseMaxPriceFallback then saveSetting("UseMaxPriceFallback", false) end
            notify("Block Unknown Shoes", v and "ON — shoes with no StockY data will be skipped" or "OFF", 3)
        end,
    })

    SettingsTab:CreateSection("Overpay Limit (a second price check)")
    SettingsTab:CreateParagraph({
        Title = "Limit in dollars above market",
        Content = "Skips a shoe if its price is more than this many dollars above its StockY price.\nExample: set it to 500 and anything more than $500 over market is skipped.",
    })
    SettingsTab:CreateToggle({ Name = "Use the Overpay Limit  (turn on to use the number below)", Default = Settings.UseOverpayLimit, Callback = function(v) saveSetting("UseOverpayLimit", v) end })
    SettingsTab:CreateTextBox({ Name = "Most I will pay above StockY ($)  -  0 means at or below StockY only", Default = tostring(Settings.OverpayLimit), Placeholder = "e.g. 500", NumbersOnly = true, Callback = function(v) local num = tonumber(v); if num ~= nil and num >= 0 then saveSetting("OverpayLimit", math.floor(num)) end end })

    SettingsTab:CreateSection("Safety Limits (protects your cash)")
    SettingsTab:CreateParagraph({
        Title = "Stops the bot from overspending",
        Content = "These protect your money. They apply to every buying mode.\n\nNote: unlike the rest of this page, these reset to their defaults each time you rejoin the game.",
    })
    SettingsTab:CreateToggle({
        Name     = "Never buy a shoe I cannot afford  (recommended)",
        Default  = GATES.RequireMoney ~= false,
        Callback = function(v) GATES.RequireMoney = v and true or false end,
    })
    SettingsTab:CreateTextBox({
        Name        = "Always keep this much cash in reserve ($)",
        Default     = tostring(GATES.MoneyReserve or 0),
        Placeholder = "0  (no reserve)",
        NumbersOnly = true,
        Callback    = function(v) GATES.MoneyReserve = math.max(0, tonumber(v) or 0) end,
    })
    SettingsTab:CreateTextBox({
        Name        = "Stop buying after spending this much this session ($)",
        Default     = tostring(GATES.MaxSessionSpend or 0),
        Placeholder = "0  (no limit)",
        NumbersOnly = true,
        Callback    = function(v) GATES.MaxSessionSpend = math.max(0, tonumber(v) or 0) end,
    })
    SettingsTab:CreateParagraph({
        Title = "Automatic safety pause",
        Content = "If 5 purchases in a row fail to go through even though the shoe was still there, buying pauses for 15 seconds so the script does not keep firing at a broken target. Losing a shoe to another player does not count.",
    })

    SettingsTab:CreateSection("Speed and Timing (advanced, leave alone)")
    SettingsTab:CreateParagraph({
        Title = "The defaults are already good",
        Content = "Smaller numbers make the script faster but use more of your computer. If you are not sure, do not touch these.\n\nAll values are in milliseconds (1000 ms = 1 second). Use Reset to Defaults at the bottom if you get lost.",
    })
    SettingsTab:CreateSlider({ Name = "Pause after each buy attempt (ms)",                          Min = 0,    Max = 500,   Default = math.floor(((tonumber(Settings.Delay) or 0) * 1000) + 0.5),              Callback = function(v) saveSetting("Delay", v / 1000) end })
    SettingsTab:CreateSlider({ Name = "Snipe Mode: rest between full sweeps (ms)",               Min = 0,    Max = 2000,  Default = math.floor(((tonumber(Settings.SnipeCycleWait) or 0) * 1000) + 0.5),       Callback = function(v) saveSetting("SnipeCycleWait", v / 1000) end })
    SettingsTab:CreateSlider({ Name = "Low Price Mode: rest between full sweeps (ms)",           Min = 0,    Max = 2000,  Default = math.floor(((tonumber(Settings.OneDollarCycleWait) or 0) * 1000) + 0.5),   Callback = function(v) saveSetting("OneDollarCycleWait", v / 1000) end })
    SettingsTab:CreateSlider({ Name = "How long to wait for a purchase to confirm (higher = waits longer)",                           Min = 10,   Max = 500,   Default = math.floor(((tonumber(Settings.BuyConfirmPollWait) or 0) * 1000) + 0.5),   Callback = function(v) saveSetting("BuyConfirmPollWait", v / 1000) end })
    SettingsTab:CreateSlider({ Name = "Auto-Sell: how often to check for empty slots (ms)",                 Min = 500,  Max = 10000, Default = math.floor(((tonumber(Settings.AutoSellRefillWait) or 0) * 1000) + 0.5),   Callback = function(v) saveSetting("AutoSellRefillWait", v / 1000) end })
    SettingsTab:CreateSlider({ Name = "Auto-Sell: pause between listing each shoe (ms)",               Min = 50,   Max = 1000,  Default = math.floor(((tonumber(Settings.AutoSellSlotWait) or 0) * 1000) + 0.5),     Callback = function(v) saveSetting("AutoSellSlotWait", v / 1000) end })
    SettingsTab:CreateSlider({ Name = "Flash Listing: how long each shoe stays up (ms)",                Min = 100,  Max = 5000,  Default = math.floor(((tonumber(Settings.FlashListHoldTime) or 0) * 1000) + 0.5),    Callback = function(v) saveSetting("FlashListHoldTime", v / 1000) end })
    SettingsTab:CreateSlider({ Name = "Flash Listing: pause before the next one (ms)",                       Min = 50,   Max = 2000,  Default = math.floor(((tonumber(Settings.FlashListDelistTime) or 0) * 1000) + 0.5),   Callback = function(v) saveSetting("FlashListDelistTime", v / 1000) end })

    SettingsTab:CreateSection("Reset to Defaults")
    SettingsTab:CreateButton({
        Name     = "Reset every setting on this page to its default",
        Callback = function()
            pcall(function() writefile("ShoeBuyer_settings.json", "{}") end)
            Settings.PriceFilter        = true;  Settings.MaxPrice         = 100000; Settings.TargetShoe = ""; Settings.Delay = 0.05
            Settings.UseStockYCheck     = false; Settings.StockYMargin     = 1.0;   Settings.UnsellableOnly = false; OneDollarMaxPrice = 1
            Settings.SnipeCycleWait     = 0.5;  Settings.OneDollarCycleWait = 0.5; Settings.AutoSellRefillWait = 3.0; Settings.AutoSellSlotWait = 0.1
            Settings.FlashListHoldTime  = 0.5;  Settings.FlashListDelistTime = 0.1; Settings.BuyConfirmPollWait = 0.08
            Settings.UseOverpayLimit    = false; Settings.OverpayLimit    = 0;     Settings.BlockNoStockYData = false
            Settings.UseMaxPriceFallback = true; Settings.MaxPriceFallback = 50000
            __L.saveSettingsToDisk(Settings)
            notify("Settings Reset", "All settings are back to defaults. Restart the script to fully apply.", 7)
        end,
    })
end


-- ════════════════════════════════════════════════════════════════
--  CONFIGS TAB  UI  (sub-page: Configs)
-- ════════════════════════════════════════════════════════════════

do
    local CONFIG_PREFIX   = "SRS_CFG:"
    local CONFIG_VERSION  = 2

    -- Keys that are saved as part of a shareable config
    local SHAREABLE_KEYS = {
        "PriceFilter","MaxPrice","TargetShoe","Delay","UseStockYCheck","StockYMargin",
        "UnsellableOnly","SellStockYOffsetPct","UseFixedSellPrice","FixedSellPrice",
        "AutoSellUnsellableOnly","SnipeCycleWait","OneDollarCycleWait","AutoSellRefillWait",
        "AutoSellSlotWait","FlashListHoldTime","FlashListDelistTime","BuyConfirmPollWait",
        "UseOverpayLimit","OverpayLimit","BlockNoStockYData","UseMaxPriceFallback","MaxPriceFallback",
    }

    local function buildPayload(name)
        local payload = { _v = CONFIG_VERSION, _name = name or "Unnamed" }
        for _, key in ipairs(SHAREABLE_KEYS) do payload[key] = Settings[key] end
        local blArr = {}
        for n in pairs(Blacklist) do table.insert(blArr, n) end
        table.sort(blArr)
        payload._blacklist         = blArr
        payload._pendingSellPrice  = pendingSellPrice
        payload._oneDollarMaxPrice = OneDollarMaxPrice
        payload._maxBuyPerShoe     = MaxBuyPerShoe
        return payload
    end

    local function encodeConfig(name)
        return CONFIG_PREFIX .. HttpService:JSONEncode(buildPayload(name))
    end

    local function decodeConfig(str)
        str = tostring(str or ""):match("^%s*(.-)%s*$")
        if str:sub(1, #CONFIG_PREFIX) ~= CONFIG_PREFIX then return nil, "Missing SRS_CFG: prefix" end
        local ok, tbl = pcall(function() return HttpService:JSONDecode(str:sub(#CONFIG_PREFIX + 1)) end)
        if not ok or type(tbl) ~= "table" then return nil, "Invalid config data" end
        return tbl, nil
    end

    local function applyConfig(tbl)
        for _, key in ipairs(SHAREABLE_KEYS) do
            if tbl[key] ~= nil then Settings[key] = tbl[key] end
        end
        -- Backwards compatibility with older config keys
        if tbl.MaxBuyPrice ~= nil and Settings.MaxPrice == 100000 then Settings.MaxPrice = tonumber(tbl.MaxBuyPrice) or 100000 end
        if tbl.SellOffset  ~= nil and Settings.SellStockYOffsetPct == 0 then Settings.SellStockYOffsetPct = tonumber(tbl.SellOffset) or 0 end
        __L.saveSettingsToDisk(Settings)
        if type(tbl._blacklist) == "table" then
            for _, name in ipairs(tbl._blacklist) do Blacklist[name] = true end
            __L.saveBlacklist()
        end
        if type(tbl._pendingSellPrice)  == "number" and tbl._pendingSellPrice  > 0 then pendingSellPrice    = math.floor(tbl._pendingSellPrice) end
        if type(tbl._oneDollarMaxPrice) == "number" and tbl._oneDollarMaxPrice >= 1 then OneDollarMaxPrice  = math.floor(tbl._oneDollarMaxPrice) end
        if type(tbl._maxBuyPerShoe) == "table" then
            for name, cap in pairs(tbl._maxBuyPerShoe) do
                local n = tonumber(cap)
                if type(name) == "string" and n and n > 0 then MaxBuyPerShoe[name] = n end
            end
            __L.saveMaxBuyPrices()
        end
    end

    -- Saved configs (stored to disk)
    local savedConfigs = {}
    local function loadSavedConfigs()
        savedConfigs = __L.jsonRead(FILES.CONFIGS) or {}
    end
    local function writeSavedConfigs()
        __L.jsonWrite(FILES.CONFIGS, savedConfigs)
    end
    loadSavedConfigs()

    local ConfigStatusLabel  = nil
    local ConfigGeneration   = 0

    local function buildConfigSavedList()
        __L.dynClear(ConfigTab)
        ConfigGeneration += 1
        local myGen       = ConfigGeneration
        local names       = {}
        for name in pairs(savedConfigs) do table.insert(names, name) end
        table.sort(names)
        pcall(function() ConfigStatusLabel:Set(#names .. " saved config(s)") end)

        if #names == 0 then
            mkRow(ConfigTab, "You have not saved any configs yet. Type a name above and press Save Config.")
            return
        end

        __L.mkSection(ConfigTab, "Your Saved Configs (" .. #names .. ")")

        for _, name in ipairs(names) do
            if myGen ~= ConfigGeneration then return end
            local cfg      = savedConfigs[name]
            local capName  = name
            local blCount  = type(cfg._blacklist) == "table" and #cfg._blacklist or 0
            local capCount = 0
            if type(cfg._maxBuyPerShoe) == "table" then for _ in pairs(cfg._maxBuyPerShoe) do capCount += 1 end end
            local summary  = string.format(
                "Max Buy: $%s  |  StockY Check: %s  |  Blacklist: %d shoes  |  Caps: %d",
                commaNum(cfg.MaxPrice or 0), cfg.UseStockYCheck and "ON" or "OFF", blCount, capCount)

            mkRow(ConfigTab, capName, { color = ROWC.ACCENT, header = true })
            mkRow(ConfigTab, summary)
            __L.mkBtnGroup(ConfigTab, {
                { text = "Load", cb = function()
                    local live = savedConfigs[capName]
                    if not live then notify("Error", "Config not found.", 3); return end
                    applyConfig(live); notify("Config Loaded", capName .. " applied!", 5)
                end },
                { text = "Update", cb = function()
                    local updated = {}
                    local live    = savedConfigs[capName] or {}
                    for k, v in pairs(live) do updated[k] = v end
                    for _, key in ipairs(SHAREABLE_KEYS) do updated[key] = Settings[key] end
                    if type(updated._maxBuyPerShoe) ~= "table" then updated._maxBuyPerShoe = {} end
                    for k, v in pairs(MaxBuyPerShoe) do updated._maxBuyPerShoe[k] = v end
                    local blArr = {}; for n in pairs(Blacklist) do table.insert(blArr, n) end
                    updated._blacklist = blArr; updated._v = CONFIG_VERSION; updated._name = capName
                    savedConfigs[capName] = updated; writeSavedConfigs()
                    notify("Config Updated", capName .. " saved with current settings.", 5)
                    task.spawn(buildConfigSavedList)
                end },
                { text = "Share Code", cb = function()
                    local live = savedConfigs[capName]
                    if live then pcall(function() setclipboard(CONFIG_PREFIX .. HttpService:JSONEncode(live)) end) end
                    notify("Share Code Copied!", "Paste this to share " .. capName, 5)
                end },
                { text = "Delete", cb = function()
                    savedConfigs[capName] = nil; writeSavedConfigs()
                    notify("Deleted", capName .. " has been removed.", 3)
                    task.spawn(buildConfigSavedList)
                end },
            })
        end
    end

    ConfigTab:CreateSection("What Is a Config?")
    ConfigTab:CreateParagraph({
        Title = "A saved setup you can switch to in one tap",
        Content = "A config remembers your Settings tab choices, your blacklist and your per-shoe caps. Save one for each way you play (for example 'Unsellable Hunter' or 'Cheap Flips'), then load it later instead of changing everything by hand.",
    })

    ConfigTab:CreateSection("Save Your Current Setup")
    ConfigTab:CreateParagraph({
        Title = "Save / load",
        Content = "Type a name, then press Save Config. It shows up in the list at the bottom of this page, where you can load or delete it.",
    })
    local pendingConfigName = ""
    ConfigTab:CreateTextBox({ Name = "Name for this config", Placeholder = "e.g. Unsellable Hunter", Callback = function(v) pendingConfigName = tostring(v or ""):match("^%s*(.-)%s*$") end })
    ConfigTab:CreateButton({ Name = "Save Config", Callback = function()
        local name = pendingConfigName
        if name == "" then notify("Config", "Type a name first!", 3); return end
        savedConfigs[name] = buildPayload(name); writeSavedConfigs()
        notify("Saved!", name .. " saved.", 5)
        task.spawn(buildConfigSavedList)
    end })

    ConfigTab:CreateSection("Use a Config Someone Shared With You")
    ConfigTab:CreateParagraph({
        Title = "Paste their share code",
        Content = "A share code is one long line of text that starts with SRS_CFG: . Paste it below, then choose whether to use it now or just save it for later.",
    })
    local pendingImportStr = ""
    ConfigTab:CreateTextBox({ Name = "Paste the share code here", Placeholder = "SRS_CFG:{...}", Callback = function(v) pendingImportStr = tostring(v or ""):match("^%s*(.-)%s*$") end })
    ConfigTab:CreateButton({ Name = "Use it now  (replaces my current setup)", Callback = function()
        if pendingImportStr == "" then notify("Import", "Paste a share code first!", 3); return end
        local tbl, err = decodeConfig(pendingImportStr)
        if not tbl then notify("Import Failed", tostring(err), 6); return end
        applyConfig(tbl)
        local blImported = type(tbl._blacklist) == "table" and #tbl._blacklist or 0
        notify("Imported!", (tbl._name or "Config") .. " applied! Added " .. blImported .. " blacklist entries.", 6)
        pendingImportStr = ""
    end })
    ConfigTab:CreateButton({ Name = "Save it for later  (does not change my current setup)", Callback = function()
        if pendingImportStr == "" then notify("Import", "Paste a share code first!", 3); return end
        local tbl, err = decodeConfig(pendingImportStr)
        if not tbl then notify("Import Failed", tostring(err), 6); return end
        local importName = tostring(tbl._name or "Imported_" .. os.time())
        savedConfigs[importName] = tbl; writeSavedConfigs()
        notify("Saved!", importName .. " saved. Load it from the list below.", 5)
        pendingImportStr = ""; task.spawn(buildConfigSavedList)
    end })

    ConfigTab:CreateSection("Share Your Setup With Others")
    ConfigTab:CreateButton({ Name = "Copy my current setup as a share code", Callback = function()
        pcall(function() setclipboard(encodeConfig("QuickExport_" .. os.date("%H%M%S"))) end)
        notify("Copied!", "Share code copied to clipboard.", 5)
    end })

    ConfigTab:CreateSection("Your Saved Configs")
    ConfigStatusLabel = mkRow(ConfigTab, "Loading...", { static = true })
    ConfigTab:CreateButton({ Name = "Refresh the list", Callback = function() task.spawn(buildConfigSavedList) end })

    task.defer(function()
        task.wait(0.3)
        buildConfigSavedList()
    end)
end


-- ════════════════════════════════════════════════════════════════
--  DASHBOARD TAB  UI  (sub-page: Dashboard)
--  One big live card + control buttons. Wrapped in a function so its
--  variables never count toward the main chunk's 200-local limit.
-- ════════════════════════════════════════════════════════════════

;(function()
    if getgenv().NotificationsEnabled == nil then getgenv().NotificationsEnabled = true end

    -- ── colours / text helpers ────────────────────────────────
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
        if n >= 0 then return col(C_OK, "+$" .. commaNum(n)) end
        return col(C_BAD, "-$" .. commaNum(math.abs(n)))
    end
    local function dur(sec)
        if not sec then return "never" end
        sec = math.max(0, math.floor(sec))
        if sec < 60 then return sec .. "s" end
        if sec < 3600 then return math.floor(sec / 60) .. "m " .. (sec % 60) .. "s" end
        if sec < 86400 then return math.floor(sec / 3600) .. "h " .. math.floor((sec % 3600) / 60) .. "m" end
        return math.floor(sec / 86400) .. "d " .. math.floor((sec % 86400) / 3600) .. "h"
    end
    local function count(t) local n = 0; for _ in pairs(t) do n += 1 end; return n end

    local SKIP_NAMES = {
        blacklist = "on blacklist", max_price = "over Max Price", per_shoe_cap = "over shoe cap",
        stocky_cap = "over StockY margin", overpay = "too far above StockY", fallback_cap = "unknown shoe over cap",
        no_stocky_data = "no StockY price", stocky_not_ready = "StockY not ready",
        not_unsellable = "sellable shoe", target_mismatch = "not target shoe",
        insufficient_funds = "can't afford", spend_cap = "spend limit hit", lost_race = "lost the race",
        breaker_open = "safety pause", slot_cooldown = "slot cooling down", price_changed = "price changed",
        listing_changed = "listing changed", already_sold = "already sold", bad_price = "price not ready",
    }

    -- ── live numbers ──────────────────────────────────────────
    local currentFPS, frameCount, lastFPS = 0, 0, tick()
    local fpsConn = RunService.RenderStepped:Connect(function() frameCount += 1 end)
    local peakMoney = 0
    local codesMsg = "idle"
    local StatsService = game:GetService("Stats")

    task.spawn(function()
        while srsAlive() do
            local now = tick()
            if now - lastFPS > 0 then currentFPS = math.floor(frameCount / (now - lastFPS)) end
            frameCount = 0; lastFPS = now
            task.wait(1)
        end
        pcall(function() fpsConn:Disconnect() end)
    end)

    -- ── build the card text ───────────────────────────────────
    local function buildModel()
        local up      = tick() - sessionStart
        local hours   = math.max(up / 3600, 1 / 3600)
        local money   = __L.getMoney()
        local spent   = getgenv().TotalMoneySpent or 0
        local start   = __L.ensureMoneyBaseline() and getgenv().MoneyAtSessionStart or money
        local net     = money - start
        local earned  = math.max(0, net + spent)
        getgenv().TotalMoneyEarned = earned
        if money > peakMoney then peakMoney = money end
        local bought  = getgenv().ShoesBought or 0
        local sold    = getgenv().ShoesSold or 0
        local breaker = tick() < BuyState.breakerUntil
        local model = {
            Title = "SHOE SNIPER v7 DASHBOARD",
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

        -- active modes
        local modes = {}
        if SnipeLoopRunning        then modes[#modes + 1] = "Snipe" end
        if OneDollarRunning        then modes[#modes + 1] = "Low Price" end
        if WalkBuySnipeRunning     then modes[#modes + 1] = "Walk Snipe" end
        if WalkBuyOneDollarRunning then modes[#modes + 1] = "Walk Low Price" end
        if SellAllRunning          then modes[#modes + 1] = "Auto-Sell All" end
        if SellUnsellRunning       then modes[#modes + 1] = "Auto-Sell Unsellable" end
        if FlashListRunning        then modes[#modes + 1] = "Flash List" end
        local badgeText, badgeTone
        if breaker then badgeText, badgeTone = "PAUSED", "warn"
        elseif #modes > 0 then badgeText, badgeTone = "RUNNING", "ok"
        else badgeText, badgeTone = "IDLE", "idle" end
        local badge = col(breaker and C_WARN or (#modes > 0 and C_OK or C_DIM), "● " .. badgeText)

        add("<b>SHOE SNIPER v7  DASHBOARD</b>   " .. badge)
        add(row("Active", #modes > 0 and col(C_OK, table.concat(modes, ", ")) or col(C_DIM, "nothing running")))
        add("")

        -- system
        add(head("SYSTEM"))
        local okP, ping = pcall(function() return StatsService.Network.ServerStatsItem["Data Ping"]:GetValueString() end)
        add(row("Uptime", __L.formatUptime(up)))
        add(row("FPS / Ping", currentFPS .. " fps   /   " .. (okP and ping or "N/A")))
        add(row("Server", #Players:GetPlayers() .. "/" .. Players.MaxPlayers .. " players   age " .. dur(workspace.DistributedGameTime)))
        add("")

        -- wallet
        add(head("WALLET"))
        add(row("Money", fmtMoney(money) .. col(C_DIM, "   (peak " .. fmtMoney(peakMoney) .. ")")))
        add(row("Spent", fmtMoney(spent)))
        add(row("Earned", fmtMoney(earned) .. col(C_DIM, "  (estimate)")))
        add(row("Net profit", signed(net) .. (up >= 60 and col(C_DIM, "   " .. (net >= 0 and "+" or "-") .. "$" .. commaNum(math.abs(net / hours)) .. "/hr") or "")))
        local cap = tonumber(GATES.MaxSessionSpend) or 0
        if cap > 0 then
            add(row("Spend limit", fmtMoney(spent + BuyState.inflight) .. " / " .. fmtMoney(cap)))
        else
            add(row("Spend limit", col(C_DIM, "off")))
        end
        add("")

        -- shoes
        add(head("SHOES"))
        add(row("Bought", commaNum(bought) .. (bought > 0 and col(C_DIM, "   avg " .. fmtMoney(spent / bought) .. "   " .. commaNum(bought / hours) .. "/hr") or "")))
        add(row("Sold", commaNum(sold)))
        local okS, stock = pcall(function() return #SellableInventory:GetChildren() + #UnsellableInventory:GetChildren() end)
        add(row("In stock", okS and (commaNum(stock) .. " shoes" .. col(C_DIM, "   unsold, so cash profit is lower until they sell")) or col(C_DIM, "--")))
        add(row("Last buy", BuyState.lastBuyAt and (dur(os.time() - BuyState.lastBuyAt) .. " ago") or "none yet"))
        add("")

        -- sniper
        add(head("SNIPER"))
        local found = BuyStats.Found or 0
        local hit = found > 0 and string.format("%.1f%%", (BuyStats.Bought or 0) / found * 100) or "--"
        add(row("Checked", commaNum(found) .. "   bought " .. (BuyStats.Bought or 0) .. "   skipped " .. commaNum(BuyStats.Skipped or 0)))
        add(row("Hit rate", hit))
        add(row("Safety", breaker and col(C_WARN, "paused") or col(C_OK, "OK") .. col(C_DIM, "   unverified streak " .. BuyState.streak)))
        local skipList = {}
        for k, v in pairs(BuyState.skips) do if type(v) == "number" and v > 0 then skipList[#skipList + 1] = { k, v } end end
        table.sort(skipList, function(a, b) return a[2] > b[2] end)
        if #skipList == 0 then
            add(row("Top skips", col(C_DIM, "nothing skipped yet")))
        else
            for i = 1, math.min(3, #skipList) do
                add(row(i == 1 and "Top skips" or "", esc(SKIP_NAMES[skipList[i][1]] or skipList[i][1]) .. col(C_DIM, "  x" .. commaNum(skipList[i][2]))))
            end
        end
        add("")

        -- data
        add(head("DATA"))
        local sy
        if StockY.ready then
            local age = StockY.updatedAt and (os.time() - StockY.updatedAt) or nil
            sy = col(C_OK, "ready") .. "   " .. commaNum(StockY.count) .. " prices   age " .. dur(age)
        elseif StockY.inflight then sy = col(C_WARN, "loading...")
        else sy = col(C_BAD, "not ready") end
        add(row("StockY", sy))
        if (StockY.failStreak or 0) > 0 then
            add(row("StockY errors", col(C_WARN, StockY.failStreak .. " in a row") .. (StockY.lastErr and col(C_DIM, "  " .. esc(tostring(StockY.lastErr):sub(1, 40))) or "")))
        end
        add(row("Market", (Tables and col(C_OK, "found") or col(C_BAD, "not found")) .. "   " .. #cachedSlots .. " slots"))
        add(row("Shoe data", SneakerModuleLoaded and col(C_OK, "loaded") or col(C_WARN, "loading...")))
        add("")

        -- filters
        add(head("FILTERS"))
        add(row("Max price", Settings.PriceFilter and fmtMoney(Settings.MaxPrice) or col(C_DIM, "off")))
        add(row("StockY check", Settings.UseStockYCheck and (col(C_OK, "ON") .. "   margin x" .. tostring(Settings.StockYMargin)) or col(C_DIM, "OFF")))
        add(row("Overpay limit", Settings.UseOverpayLimit and (col(C_OK, "ON") .. "   " .. fmtMoney(Settings.OverpayLimit)) or col(C_DIM, "OFF")))
        add(row("No-price", Settings.BlockNoStockYData and "blocked" or (Settings.UseMaxPriceFallback and ("capped at " .. fmtMoney(Settings.MaxPriceFallback)) or "any price")))
        add(row("Blacklist", commaNum(count(Blacklist)) .. " shoes" .. (BlacklistMinPrice > 0 and col(C_DIM, "   min " .. fmtMoney(BlacklistMinPrice)) or "")))
        add(row("Shoe caps", commaNum(count(MaxBuyPerShoe)) .. " set"))
        add(row("Unsellable", onoff(Settings.UnsellableOnly) .. "   target: " .. ((Settings.TargetShoe or "") ~= "" and esc(Settings.TargetShoe) or col(C_DIM, "any"))))
        add("")

        -- selling
        add(head("SELLING"))
        add(row("Auto-sell", (SellAllRunning or SellUnsellRunning) and col(C_OK, "ON") or col(C_DIM, "OFF")))
        add(row("Flash list", onoff(FlashListRunning)))
        add(row("List price", Settings.UseFixedSellPrice and ("fixed " .. fmtMoney(Settings.FixedSellPrice)) or string.format("StockY %+g%%", tonumber(Settings.SellStockYOffsetPct) or 0)))
        add("")

        -- misc
        add(head("MISC"))
        add(row("Webhook", (Settings.WebhookURL or "") ~= "" and col(C_OK, "set") or col(C_DIM, "not set")))
        add(row("Codes", esc(codesMsg)))

        -- Headline tiles. The matching rows above are removed from the section
        -- cards below, so the text data itself stays exactly the same.
        model.Tiles = {
            { Label = "Uptime", Value = __L.formatUptime(up), Sub = "this session", Color = "idle" },
            { Label = "Money", Value = fmtMoney(money), Sub = "peak " .. fmtMoney(peakMoney), Color = "accent" },
            {
                Label = "Net Profit",
                Value = signed(net),
                Sub = "start " .. fmtMoney(start) .. (up >= 60 and ("  ·  " .. (net >= 0 and "+" or "-") .. "$" .. commaNum(math.abs(net / hours)) .. "/hr") or ""),
                Color = net >= 0 and "ok" or "bad",
            },
            {
                Label = "Bought / Sold",
                Value = commaNum(bought) .. " / " .. commaNum(sold),
                Sub = bought > 0 and ("avg " .. fmtMoney(spent / bought) .. " each") or "no purchases yet",
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
        lines[#lines + 1] = tostring(m.Title or "SHOE SNIPER v7 DASHBOARD") .. "   " .. tostring(badge)
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

    -- Prefer the library dashboard grid; old GitHub libraries do not have it,
    -- so build the original monospace text card as a working fallback.
    local dash
    local body
    if type(StatsTab.CreateDashboard) == "function" then
        local okDash, made = pcall(function()
            return StatsTab:CreateDashboard({ Title = "SHOE SNIPER v7 DASHBOARD" })
        end)
        if okDash and type(made) == "table" and type(made.Update) == "function" and made.Instance then
            dash = made
        else
            warn("[Sniper][Dashboard] CreateDashboard failed, using the text card: " .. tostring(made))
        end
    end
    if not dash then
        local card = Instance.new("Frame")
        card.Name = "DashboardCard"
        card.BackgroundColor3 = ROWC.BG
        card.BackgroundTransparency = 0.25
        card.BorderSizePixel = 0
        card.Size = UDim2.new(1, 0, 0, 0)
        card.AutomaticSize = Enum.AutomaticSize.Y
        do
            local uc = Instance.new("UICorner"); uc.CornerRadius = UDim.new(0, 8); uc.Parent = card
            local us = Instance.new("UIStroke"); us.Color = ROWC.ACCENT; us.Transparency = 0.55; us.Thickness = 1; us.Parent = card
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
        body.TextColor3 = ROWC.TEXT
        body.Text = "loading..."
        body.Parent = card
        card.Parent = StatsTab.content
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
                    Title = "SHOE SNIPER v7 DASHBOARD",
                    Badge = { Text = "ERROR", Color = "bad" },
                    Active = msg,
                    Tiles = {},
                    Sections = {},
                })
            else
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
    task.spawn(function()
        while srsAlive() do
            task.wait(1)
            refresh()
        end
    end)
    -- Refresh right away when the balance changes (debounced) instead of
    -- waiting up to a second for the next poll.
    task.spawn(function()
        local ls = LocalPlayer:WaitForChild("leaderstats", 15)
        if not ls then return end
        local pending = false
        local function onChange()
            if pending or not srsAlive() then return end
            pending = true
            task.delay(0.15, function()
                pending = false
                if srsAlive() then pcall(__L.ensureMoneyBaseline); refresh() end
            end)
        end
        for _, v in ipairs(ls:GetChildren()) do
            if v:IsA("ValueBase") then v:GetPropertyChangedSignal("Value"):Connect(onChange) end
        end
        ls.ChildAdded:Connect(function(v)
            if v:IsA("ValueBase") then v:GetPropertyChangedSignal("Value"):Connect(onChange) end
            onChange()
        end)
    end)

    -- ── controls ──────────────────────────────────────────────
    StatsTab:CreateSection("Controls")
    StatsTab:CreateToggle({
        Name         = "In-Script Notifications",
        Default      = true,
        CurrentValue = true,
        Callback     = function(state) getgenv().NotificationsEnabled = state end,
    })
    StatsTab:CreateButton({ Name = "Stop All Modes", Callback = function()
        __L.stopAllModes()
        notify("Stopped", "Every sniper and sell mode was stopped.", 3, "Check")
    end })
    StatsTab:CreateButton({ Name = "Reset Session Stats", Callback = function()
        getgenv().TotalMoneySpent = 0; getgenv().TotalMoneyEarned = 0
        getgenv().ShoesBought = 0; getgenv().ShoesSold = 0
        getgenv().MoneyBaselineSet = false; __L.ensureMoneyBaseline(); getgenv().MoneyLocked = true
        BuyStats.Found = 0; BuyStats.Bought = 0; BuyStats.Skipped = 0
        peakMoney = __L.getMoney()
        table.clear(BuyState.skips)
        updateStats(); refresh()
        notify("Stats", "Session stats have been reset.", 3, "Check")
    end })
    StatsTab:CreateButton({ Name = "Copy Dashboard Snapshot", Callback = function()
        local okM, model = pcall(buildModel)
        if not okM then notify("Copy", "Could not build the snapshot.", 3, "X"); return end
        local plain = modelToText(model)
        pcall(function() setclipboard(plain) end)
        notify("Copied", "Dashboard text copied to your clipboard.", 3, "Check")
    end })

    StatsTab:CreateSection("Tools")
    -- Server is case-sensitive and only accepts lowercase.
    local CODES = { "bbence_27", "misumaki", "likes10k", "homie", "secretsneaker" }
    StatsTab:CreateButton({ Name = "Redeem All Codes", Callback = function()
        if getgenv().__SRS_CODES_RUNNING then
            notify("Codes", "Already redeeming - wait for it to finish.", 3, "X")
            return
        end
        getgenv().__SRS_CODES_RUNNING = true
        task.spawn(function()
            local okRun, errRun = pcall(function()
                local redeem = RemoteEvents and RemoteEvents:FindFirstChild("RedeemCode")
                if not redeem then
                    codesMsg = "RedeemCode remote not found"
                    notify("Codes", "RedeemCode remote not found - game updated?", 4, "X")
                    return
                end
                local okCount, invalidCount, usedCount, failCount = 0, 0, 0, 0
                for idx, code in ipairs(CODES) do
                    if not srsAlive() then return end
                    codesMsg = string.format("redeeming %s (%d/%d)...", code, idx, #CODES)
                    local done, worked, resp = false, false, nil
                    task.spawn(function()
                        worked = pcall(function() resp = redeem:InvokeServer(code) end)
                        done = true
                    end)
                    for _ = 1, 40 do
                        if done then break end
                        task.wait(0.25)
                    end
                    -- Server answers with a plain string: "invalid", "alreadyRedeemed",
                    -- or a success message. Only the latter counts as redeemed.
                    local label
                    if not done then
                        failCount = failCount + 1; label = "no response"
                    elseif worked then
                        local r = tostring(resp or ""):lower()
                        if r:find("invalid") then invalidCount = invalidCount + 1; label = "invalid"
                        elseif r:find("already") or r:find("used") then usedCount = usedCount + 1; label = "already redeemed"
                        else okCount = okCount + 1; label = "redeemed!" end
                    else
                        failCount = failCount + 1; label = "rejected"
                    end
                    codesMsg = string.format("%s - %s (%d/%d)", code, label, idx, #CODES)
                    -- 3s pacing: back-to-back codes trip the server rate limit.
                    if idx < #CODES then task.wait(3) end
                end
                local summary = string.format("redeemed %d, invalid %d, used %d, failed %d", okCount, invalidCount, usedCount, failCount)
                codesMsg = "done - " .. summary
                notify("Codes finished", summary, 5, "Check")
            end)
            getgenv().__SRS_CODES_RUNNING = false
            if not okRun then
                log("ERROR", "[CODES] " .. tostring(errRun))
                codesMsg = "error - see log"
            end
        end)
    end })
    StatsTab:CreateButton({ Name = "Server Hop", Callback = function()
        __L.stopAllModes()
        notify("Server Hop", "Stopping all modes... hopping in 1.5s", 3)
        task.wait(1.5)
        pcall(function()
            loadstring(game:HttpGet("https://raw.githubusercontent.com/FaddedMarket/roblox-scripts/refs/heads/main/random%20scripts/serverhop.lua"))()
        end)
    end })
    StatsTab:CreateButton({ Name = "Join Same Server", Callback = function()
        pcall(function()
            loadstring(game:HttpGet("https://raw.githubusercontent.com/FaddedMarket/roblox-scripts/refs/heads/main/random%20scripts/joinsameserver.lua"))()
        end)
    end })
    StatsTab:CreateButton({ Name = "Black Screen (helps with screen burn when AFK)", Callback = function()
        local screenGui = Instance.new("ScreenGui")
        screenGui.Name = "BlackScreen"
        screenGui.ResetOnSpawn = false
        screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
        screenGui.DisplayOrder = 2147483647
        screenGui.IgnoreGuiInset = true
        screenGui.Parent = LocalPlayer:WaitForChild("PlayerGui")

        local frame = Instance.new("Frame")
        frame.Size = UDim2.new(1, 0, 1, 0)
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
        corner.CornerRadius = UDim.new(0, 8)
        corner.Parent = closeButton

        closeButton.MouseButton1Click:Connect(function() screenGui:Destroy() end)
        notify("Black Screen", "Click the X in the top right to close.", 4, "Check")
    end })
    StatsTab:CreateButton({ Name = "Copy the creator's social links", Callback = function()
        pcall(function() setclipboard(SAKURAS_SOCIALS_URL) end)
        notify("Sakura's Socials", "Link copied!\n" .. SAKURAS_SOCIALS_URL, 6)
    end })
end)()


-- ════════════════════════════════════════════════════════════════
--  STARTUP
-- ════════════════════════════════════════════════════════════════

-- Fresh session: counters, baseline and net profit all start together (they
-- used to survive a reload in getgenv while the baseline reset, which skewed
-- "Earned").
getgenv().TotalMoneySpent  = 0
getgenv().TotalMoneyEarned = 0
getgenv().ShoesBought      = 0
getgenv().ShoesSold        = 0
getgenv().MoneyBaselineSet = false
getgenv().MoneyAtSessionStart = 0
__L.ensureMoneyBaseline()
-- Fast settle: poll quickly until the starting balance has loaded and locked.
task.spawn(function()
    local t0 = tick()
    while srsAlive() and getgenv().MoneyLocked ~= true and tick() - t0 < 30 do
        pcall(__L.ensureMoneyBaseline)
        task.wait(0.2)
    end
end)
if Tables then rebuildSlotCache() end
task.spawn(function() __L.loadSneakerModule(); __L.buildUnsellableCache() end)

if not Tables then
    task.spawn(function()
        while not Tables do
            task.wait(2)
            local t = workspace:FindFirstChild("Tables")
            if t then
                Tables = t
                wireTableEvents()
                rebuildSlotCache()
                notify("Shoe Sniper", "Market tables found - sniper online.", 4)
                pcall(function()
                    writefile("srs_beat.txt", "srs|tables-now|t=" .. os.clock() .. "|slots=" .. #cachedSlots)
                end)
            end
        end
    end)
end
task.spawn(__L.initSoldTracking)   -- StockY engine already running since BOOT

-- Live "why was a shoe skipped?" line on the Sniper tab (plain-English view of BuyState.skips)
do
    local WHY = {
        blacklist = "on your blacklist",            max_price = "above your Global Max Price",
        per_shoe_cap = "above that shoe's cap",     stocky_cap = "above your StockY Margin",
        overpay = "too far above StockY",           fallback_cap = "unknown shoe over the cap",
        no_stocky_data = "no StockY price",         stocky_not_ready = "waiting for StockY",
        not_unsellable = "sellable (Unsellable Only is on)", target_mismatch = "not your target shoe",
        insufficient_funds = "could not afford",    spend_cap = "session spend limit reached",
        lost_race = "someone else bought it first", breaker_open = "safety pause active",
        slot_cooldown = "cooling down after a failed buy",
        price_changed = "changed before we could buy", listing_changed = "changed before we could buy",
        already_sold = "already sold",              bad_price = "price not ready yet",
    }
    task.spawn(function()
        while srsAlive() do
            local lbl = getgenv().SnpWhyLabel
            if lbl then
                local list = {}
                for reason, n in pairs(BuyState.skips) do
                    table.insert(list, { n = n, text = WHY[reason] or reason })
                end
                table.sort(list, function(a, b) return a.n > b.n end)
                local parts = {}
                for i = 1, math.min(3, #list) do parts[i] = list[i].n .. "x " .. list[i].text end
                pcall(function()
                    lbl:Set("Why shoes were skipped: " .. (#parts > 0 and table.concat(parts, "   |   ") or "nothing yet"))
                end)
            end
            task.wait(2)
        end
    end)
end
mark("ui_built")

local blCount = 0; for _ in pairs(Blacklist) do blCount += 1 end
print("=== SHOE SNIPER LOADED | " .. #cachedSlots .. " slots | " .. blCount .. " blacklisted ===")
if Settings.UseOverpayLimit     then print("[OVERPAY LIMITER] ON — max overpay: " .. fmtMoney(Settings.OverpayLimit)) end
if Settings.UseMaxPriceFallback then print("[FALLBACK CAP] ON — unknown shoes capped at: " .. fmtMoney(Settings.MaxPriceFallback)) end
if Settings.BlockNoStockYData   then print("[BLOCK UNKNOWN] ON — shoes with no StockY data will be skipped") end

notify("Shoe Sniper is ready", "Open the Sniper tab and flip ONE buying switch. Press K to hide or show this window.", 7)
notify("Credits", "Script by Sakura's Hub | Sakura UI edition", 6.5)

-- ════════════════════════════════════════════════════════════════
--  DIAGNOSTICS / LIVE-TEST API  (for MCP + external tooling)
--    srs_status.json   machine-readable state, refreshed every 2s
--    srs_remotes.log   remote-call log (only while the spy is ON)
--    getgenv().SRS_API           status / refreshStockY / setGate / dumpSlots / spy / start-stop
-- ════════════════════════════════════════════════════════════════

do
local FILE_STATUS  = "srs_status.json"
local FILE_REMOTES = "srs_remotes.log"

local function currentStatus()
    local age = StockY.updatedAt and (os.time() - StockY.updatedAt) or nil
    local money, moneyKnown = __L.getMoneyChecked()
    return {
        gen      = SRS_GEN,
        uptime   = math.floor(tick() - sessionStart),
        marks    = getgenv().SRS_BOOT_MARKS,
        modes    = {
            snipe = SnipeLoopRunning, oneDollar = OneDollarRunning,
            walkSnipe = WalkBuySnipeRunning, walkOneDollar = WalkBuyOneDollarRunning,
            sellAll = SellAllRunning, sellUnsell = SellUnsellRunning, flashList = FlashListRunning,
        },
        stocky   = {
            ready = StockY.ready, count = StockY.count, source = StockY.source, ageSec = age,
            inflight = StockY.inflight, attempts = StockY.attempts, failStreak = StockY.failStreak,
            fetchMs = StockY.fetchMs, lastErr = StockY.lastErr, lastShape = StockY.lastShape,
            version = StockY.version,
        },
        buy      = {
            found = BuyStats.Found, bought = BuyStats.Bought, skipped = BuyStats.Skipped,
            inflightSpend = BuyState.inflight, breakerOpen = tick() < BuyState.breakerUntil,
            unverifiedStreak = BuyState.streak, lastBuyAt = BuyState.lastBuyAt,
            sessionBought = getgenv().ShoesBought, sessionSpent = getgenv().TotalMoneySpent,
        },
        skips    = BuyState.skips,
        slots    = #cachedSlots,
        money    = money,
        moneyKnown = moneyKnown,
        tablesLoaded  = Tables ~= nil,
        sneakerModule = SneakerModuleLoaded,
        remotes  = {
            buy = BuyDisplaySneakerEvent ~= nil, stocky = GetStockYPrices ~= nil,
            change = ChangeDisplaySneaker ~= nil, remove = RemoveDisplaySneaker ~= nil,
        },
        gates    = GATES,
        spyOn    = getgenv().SRS_SPY_ON == true,
    }
end

local function dumpSlots()
    local out = {}
    for _, slot in ipairs(cachedSlots) do
        local sv = slot:FindFirstChild("SneakerValue")
        local pv = slot:FindFirstChild("Price")
        local db = slot:FindFirstChild("SellDebounce")
        if sv and sv.Value ~= "" then
            local name = tostring(sv.Value)
            table.insert(out, {
                slot = slot:GetFullName(), shoe = name,
                price = tonumber(pv and pv.Value) or 0,
                sold = (db ~= nil and db.Value == true),
                stocky = StockYCache[name],
                blacklisted = __L.isBlacklisted(name),
            })
        end
    end
    return out
end

-- ── Opt-in remote spy (observes our own client's calls to the 4 market remotes) ──
-- Passive: records args then passes the call through untouched. Installed once per session.
local function installRemoteSpy()
    if getgenv().SRS_SPY_INSTALLED then return true end
    if not (hookmetamethod and getnamecallmethod) then
        return false, "executor lacks hookmetamethod/getnamecallmethod"
    end
    local watch = {}
    for _, r in ipairs({ BuyDisplaySneakerEvent, GetStockYPrices, ChangeDisplaySneaker, RemoveDisplaySneaker }) do
        if r then watch[r] = true end
    end
    local buf = {}
    getgenv().SRS_SPY_BUF = buf

    local function fmt(v, depth)
        local t = typeof(v)
        if t == "Instance" then return "<" .. v.ClassName .. " " .. v:GetFullName() .. ">" end
        if t == "table" then
            if depth >= 2 then return "{...}" end
            local parts, n = {}, 0
            for k, x in pairs(v) do
                n += 1
                if n > 12 then table.insert(parts, "..."); break end
                table.insert(parts, tostring(k) .. "=" .. fmt(x, depth + 1))
            end
            return "{" .. table.concat(parts, ", ") .. "}"
        end
        return t .. ":" .. tostring(v)
    end

    local wrapC = newcclosure or function(f) return f end
    local old
    old = hookmetamethod(game, "__namecall", wrapC(function(self, ...)
        local method = getnamecallmethod()
        if getgenv().SRS_SPY_ON and watch[self] and (method == "FireServer" or method == "InvokeServer") then
            local args = table.pack(...)
            local name, stamp = self.Name, os.clock()
            task.defer(function()            -- never delay or alter the real call
                pcall(function()
                    local parts = {}
                    for i = 1, args.n do parts[i] = fmt(args[i], 0) end
                    local line = string.format("[%.3f] %s:%s(%s)", stamp, name, method, table.concat(parts, ", "))
                    table.insert(buf, line)
                    if #buf > 300 then table.remove(buf, 1) end
                    if appendfile then appendfile(FILE_REMOTES, line .. "\n") end
                end)
            end)
        end
        return old(self, ...)
    end))
    getgenv().SRS_SPY_INSTALLED = true
    return true
end

getgenv().SRS_API = {
    status        = currentStatus,
    dumpSlots     = dumpSlots,
    refreshStockY = function() StockY.forceRefresh = true end,
    setGate       = function(k, v)
        if GATES[k] == nil then return false end
        GATES[k] = v
        return true
    end,
    stopAll       = function() __L.stopAllModes() end,
    startSnipe    = function() task.spawn(__L.startSnipe) end,
    startOneDollar = function() task.spawn(__L.startOneDollar) end,
    scanOnce      = function() task.spawn(__L.scanAllTables) end,
    spy           = function(on)
        if on then
            local ok, why = installRemoteSpy()
            if not ok then return false, why end
        end
        getgenv().SRS_SPY_ON = on and true or false
        return true
    end,
}

-- Heartbeat + startup proof (for external verification) + kill switch.
-- Polls every 2s so SRS_KILL takes effect promptly (was: once a minute).
pcall(function()
    writefile("srs_beat.txt", "srs|loaded|t=" .. os.clock() .. "|slots=" .. #cachedSlots .. "|bl=" .. blCount)
end)

task.spawn(function()
    local lastBeat = 0
    local lastStatusJson = nil
    local lastHealthLog = 0
    while true do
        task.wait(2)
        if not srsAlive() then return end
        if getgenv().SRS_LEAVING then return end
        if getgenv().SRS_KILL then
            __L.stopAllModes()
            pcall(function()
                local gui = getgenv()._SRS_GUI
                if gui then gui:Destroy() end
                getgenv()._SRS_GUI = nil
                getgenv()._SRS_ACTIVE = nil
                writefile("srs_beat.txt", "srs|killed|t=" .. os.clock())
            end)
            return
        end
        pcall(function() 
            local st = currentStatus()
            local json = HttpService:JSONEncode(st)
            if getgenv().SRS_SPY_ON or lastStatusJson ~= json or (tick() % 10) < 0.1 then
                writefile(FILE_STATUS, json)
                lastStatusJson = json
            end
        end)
        if os.clock() - lastBeat >= 60 then
            lastBeat = os.clock()
            pcall(function()
                writefile("srs_beat.txt",
                    "srs|beat|t=" .. os.clock() .. "|slots=" .. #cachedSlots
                    .. "|bought=" .. tostring(getgenv().ShoesBought or 0)
                    .. "|sold=" .. tostring(getgenv().ShoesSold or 0)
                    .. "|money=" .. commaNum(__L.getMoney()))
            end)
        end
        -- health check
        if tick() - lastHealthLog > 300 then
            lastHealthLog = tick()
            if BuyState.breakerUntil and tick() < BuyState.breakerUntil then
                log("HEALTH", "Buy breaker active for " .. math.floor(BuyState.breakerUntil - tick()) .. "s")
            end
            if StockY.ready and StockY.updatedAt and (os.time() - StockY.updatedAt) > 3600 then
                log("HEALTH", "StockY data is old (" .. math.floor((os.time() - StockY.updatedAt)/60) .. "m ago)")
            end
        end
    end
end)
end

-- Register the GUI handle so a future "kill" can remove it cleanly
task.defer(function()
    pcall(function()
        local gui = ScannerTab.content:FindFirstAncestorOfClass("ScreenGui")
        if gui then getgenv()._SRS_GUI = gui end
    end)
end)

-- Anti-AFK: prevent the game from kicking for inactivity
local VirtualUser = game:GetService("VirtualUser")
LocalPlayer.Idled:Connect(function()
    pcall(function()
        VirtualUser:Button2Down(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
        task.wait()
        VirtualUser:Button2Up(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
    end)
end)
task.spawn(function()
    while true do
        if not srsAlive() then break end
        task.wait(120)
        pcall(function()
            VirtualUser:Button2Down(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
            task.wait()
            VirtualUser:Button2Up(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
        end)
    end
end)
