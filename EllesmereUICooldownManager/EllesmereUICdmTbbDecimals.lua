if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
--------------------------------------------------------------------------------
--  EllesmereUICdmTbbDecimals.lua
--  12.1-only engine-driven decimal duration text for Tracking Bars.
--
--  The main TBB tick mirrors Blizzard's duration FontString verbatim because
--  the remaining time is a secret value in combat -- Lua cannot format it.
--  This module renders tenths anyway via a hidden aura container: each
--  opted-in bar gets a slot whose SetDurationText formatter is evaluated
--  ENGINE-side against the (possibly secret) remaining duration, so the text
--  is identical in and out of combat.
--
--  ENGINE RULE: a FontString registered with SetDurationText must inherit the
--  button's forbidden aspects, i.e. be a DESCENDANT of the aura button --
--  binding the bar's own timer FS hard-errors inside AddAuraSlot ("must
--  inherit all forbidden parent aspects from owner"). So the engine writes
--  into a hidden FS created ON the slot button, and the tick copies that
--  string onto the bar's real timer FS -- the exact passthrough mechanics it
--  already uses for Blizzard's FontString, just reading a decimal source.
--
--  Contract with the tick (EllesmereUICdmBuffBars.lua):
--    * bar._tbbEngineText = the bound slot button, bar._tbbEngineFS = the
--      hidden engine-written FS (both set/cleared ONLY here). While set, the
--      tick mirrors engineFS -> bar._timerText, gated on the slot button's
--      shown state (shown exactly while the aura exists) so stale text can
--      never display; any pcall failure falls back to the whole-second
--      Blizzard passthrough, still accurate.
--    * ns.TBBDecimals_Sync() runs at the end of every BuildTrackedBuffBars.
--
--  Cost model: nothing exists until a bar enables Decimals (no container, no
--  events, no tick work -- the tick's only overhead is one nil field read).
--  Enabled, the engine writes the text C-side and the tick DROPS its per-tick
--  GetText/SetText passthrough for that bar. Containers are (re)built only
--  when the set of opted-in bars or their spells changes (signature check),
--  never per tick. Container creation is combat-illegal, so a mid-combat
--  change unbinds everything first (the tick falls back to the whole-second
--  mirror, still accurate) and the rebuild runs at regen.
--------------------------------------------------------------------------------

local _, ns = ...

local AK -- EllesmereUI.AuraKit, resolved at first sync

-- Per-bar decimal threshold (Duration Text cog slider, 1-120, default 5):
-- tenths render below it. Integer-keyed cache (one engine formatter per
-- distinct threshold; bounded by the slider range, so no eviction needed).
-- Floor 1, never 0: a 0 threshold would collide with the tenths breakpoint
-- at threshold = 0 in GetDecimalFormatter's table.
local function ClampThr(v)
    v = tonumber(v) or 5
    if v < 1 then v = 1 elseif v > 120 then v = 120 end
    return math.floor(v + 0.5)
end

local formatterByThr = {}
local function GetDecimalFormatter(thr)
    thr = ClampThr(thr)
    local cached = formatterByThr[thr]
    if cached ~= nil then
        if cached then return cached end
        return nil -- false sentinel: this threshold's table was rejected
    end
    if not (C_StringUtil and C_StringUtil.CreateNumericRuleFormatter
        and Enum.NumericRuleFormatRounding) then
        formatterByThr[thr] = false
        return nil
    end
    local Nearest = Enum.NumericRuleFormatRounding.Nearest
    local Up      = Enum.NumericRuleFormatRounding.Up
    local f = C_StringUtil.CreateNumericRuleFormatter()
    -- Shape of the field-proven threshold-text formatter: tenths Nearest below the
    -- threshold, whole seconds Up to the minute, then m:ss/h/d with boundaries offset
    -- just above the unit edge so UP-rounded input never flashes "60". step/rounding
    -- live at the BREAKPOINT level; components carry only the divisor. Off-shape tables
    -- get silently rejected or default-rounded by the validator -- do not restyle.
    local points = {
        { threshold = 0, format = "%.1f", rounding = Nearest, step = 0.1 },
    }
    if thr <= 59 then
        points[#points + 1] = { threshold = thr, format = "%d", rounding = Up, step = 1 }
        points[#points + 1] = { threshold = 59.0001, format = "%d:%02d", rounding = Up, step = 1,
            components = { { div = 60 }, { mod = 60 } } }
    else
        -- Threshold past the minute boundary: tenths run right up to it,
        -- then hand off straight to m:ss (no whole-second band).
        points[#points + 1] = { threshold = thr + 0.0001, format = "%d:%02d", rounding = Up, step = 1,
            components = { { div = 60 }, { mod = 60 } } }
    end
    points[#points + 1] = { threshold = 3599.0001, format = "%dh", rounding = Up, step = 1,
        components = { { div = 3600 } } }
    points[#points + 1] = { threshold = 86399.0001, format = "%dd", rounding = Up, step = 1,
        components = { { div = 86400 } } }
    local ok = pcall(f.SetBreakpoints, f, points)
    if not ok then
        formatterByThr[thr] = false
        return nil
    end
    formatterByThr[thr] = f
    return f
end

-- Variant expansion for one stored spell id: the live aura can come up under
-- the talent override (or base) form of the id the config captured.
local function AddVariants(include, sid)
    if type(sid) ~= "number" or sid <= 0 then return end
    include[sid] = true
    if C_Spell then
        if C_Spell.GetOverrideSpell then
            local o = C_Spell.GetOverrideSpell(sid)
            if type(o) == "number" and o > 0 then include[o] = true end
        end
        if C_Spell.GetBaseSpell then
            local b = C_Spell.GetBaseSpell(sid)
            if type(b) == "number" and b > 0 then include[b] = true end
        end
    end
end

-- Secret-guarded AddVariants for ids read off live frames/cooldownInfo (an
-- active frame's ids can be SECRET; a secret table key would blow up the
-- filter). issecretvalue FIRST, arithmetic after.
local function AddCleanID(include, id)
    if issecretvalue and issecretvalue(id) then return end
    if type(id) ~= "number" or id <= 0 then return end
    AddVariants(include, id)
end

-- Reconcile a config's include set against Blizzard's cooldown info -- the SAME source
-- of truth the tick's frame matching trusts (MatchesSID). The aura that actually
-- appears often carries an id that exists ONLY in linkedSpellIDs (variant chains:
-- rituals, Eclipse-style pairs), never in the stored config ids, and without it the
-- slot filter can never match. Sync-time only (rebuilds), never per tick.
local function AddCooldownInfoIDs(include, cfg)
    local frame = ns.FindTBBChild and ns.FindTBBChild(cfg)
    if not frame then return end
    -- The frame's canonical id resolves GetSpellID/GetAuraSpellID (the actual
    -- aura variant) with its own secret handling.
    if ns.GetCanonicalSpellIDForFrame then
        AddCleanID(include, ns.GetCanonicalSpellIDForFrame(frame))
    end
    local cdID = frame.cooldownID
    local gci = C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo
    local info = cdID and gci and gci(cdID)
    if not info then return end
    AddCleanID(include, info.spellID)
    AddCleanID(include, info.overrideSpellID)
    AddCleanID(include, info.overrideTooltipSpellID)
    if info.linkedSpellIDs then
        for k = 1, #info.linkedSpellIDs do
            AddCleanID(include, info.linkedSpellIDs[k])
        end
    end
end

local host           -- shown 1px anchor for the container (alpha 0, mouse-off)
local container      -- live AuraContainer, or nil
local signature      -- signature string of the live container's slot set
local boundIndex = {}   -- bar index -> slot button (rebuilt per container)
local boundThr = {}     -- bar index -> threshold its binding was registered with
local directIndex = {}  -- bar index -> matched Blizzard CooldownViewer aura button
local directFS = {}     -- bar index -> engine-written FS parented to that button
local directThr = {}
local pendingRegen      -- true while a combat-deferred rebuild is queued
local regenFrame

local function UnmarkAll()
    for idx in pairs(boundIndex) do
        local bar = ns.GetTBBFrame and ns.GetTBBFrame(idx)
        if bar then
            bar._tbbEngineText = nil
            bar._tbbEngineFS = nil
            -- The mirror gates the timer FS alpha from the secret aura
            -- presence; an unbound bar must never keep a stuck alpha-0 FS.
            if bar._tbbAlphaGated then
                if bar._timerText then bar._timerText:SetAlpha(1) end
                bar._tbbAlphaGated = nil
            end
        end
    end
    wipe(boundIndex)
    wipe(boundThr)
    wipe(directIndex)
    wipe(directFS)
    wipe(directThr)
end

local function ReleaseCurrent()
    UnmarkAll()
    if container then
        AK.ReleaseContainer(container) -- hides it: the engine stops driving
        container = nil
        signature = nil
    end
end

-- Desired slot set: one entry per enabled, aura-driven bar with Decimals on.
-- Self-timed presets (lust/potions/Time Spiral) are excluded -- they already
-- render tenths from their own clean, never-secret countdown.
--
-- Two passes. Pass 1 collects each bar's SAVED identity (stored ids + override/base
-- variants) and claims those ids for that bar. Pass 2 adds the cooldownInfo enrichment,
-- but an id claimed by a DIFFERENT decimal bar's saved config never leaks in: spell
-- families share one cooldownInfo (ritual + art chains list each other in
-- linkedSpellIDs), and family-wide filters on two bars made the engine bind the live
-- aura to whichever slot it liked -- the losing bar showed no decimals at all.
local function CollectDesired()
    local tbb = ns.GetTrackedBuffBars and ns.GetTrackedBuffBars()
    local bars = tbb and tbb.bars
    if not bars then return nil, "" end

    local work, claimed
    for i, cfg in ipairs(bars) do
        if cfg.enabled ~= false and cfg.timerDecimals and not cfg.popularKey
           and cfg.trackType ~= "cooldown" then
            local include = {}
            AddVariants(include, cfg.spellID)
            AddVariants(include, cfg.baseSpellID)
            if cfg.spellIDs then
                for k = 1, #cfg.spellIDs do AddVariants(include, cfg.spellIDs[k]) end
            end
            if next(include) then
                work = work or {}
                claimed = claimed or {}
                work[#work + 1] = { index = i, cfg = cfg, include = include }
                for id in pairs(include) do
                    if claimed[id] == nil then claimed[id] = i end
                end
            end
        end
    end
    if not work then return nil, "" end

    local desired, sigParts = {}, {}
    local extra = {}
    for n = 1, #work do
        local w = work[n]
        wipe(extra)
        AddCooldownInfoIDs(extra, w.cfg)
        for id in pairs(extra) do
            local owner = claimed[id]
            if owner == nil or owner == w.index then
                w.include[id] = true
            end
        end
        local ids = {}
        for id in pairs(w.include) do ids[#ids + 1] = id end
        table.sort(ids)
        -- thr intentionally stays OUT of the signature: a slider move
        -- re-registers the live binding in place (no container swap).
        desired[#desired + 1] = { index = w.index, include = w.include, ids = ids,
            thr = ClampThr(w.cfg.timerDecimalThreshold) }
        sigParts[#sigParts + 1] = w.index .. "=" .. table.concat(ids, ",")
    end
    return desired, table.concat(sigParts, ";")
end

local function BuildContainer(desired)
    if not host then
        -- Keep the proxy renderable so the engine continues processing its aura
        -- slots and duration text. The bound FontStrings are descendants of this
        -- host, so setting the host to alpha zero can suppress their updates.
        -- Keep the proxy on-screen; off-screen AuraContainers can be culled
        -- before their engine-managed aura and duration bindings are advanced.
        host = CreateFrame("Frame", nil, UIParent)
        -- Match the suite's proven engine-text proxies: a meaningful renderable
        -- rectangle is required even though its presentation is transparent.
        host:SetSize(80, 20)
        host:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
        host:SetFrameStrata("BACKGROUND")
        host:EnableMouse(false)
    end

    AK.styles.tbbDecimalText = AK.styles.tbbDecimalText
        or { width = 1, height = 1, noRegions = true }

    local slots = {}
    for n = 1, #desired do
        local want = desired[n]
        slots[n] = {
            key = "tbb" .. want.index,
            filter = { "HELPFUL" },
            candidateFilters = { includeSpellIDs = want.include },
            style = "tbbDecimalText",
            extraInit = function(button)
                -- Match the suite's working engine-proxy pattern: give the slot a
                -- renderable, two-point anchored rect before duration registration.
                button:SetAllPoints(host)
                if button.SetMouseClickEnabled then button:SetMouseClickEnabled(false) end
                if button.SetMouseMotionEnabled then button:SetMouseMotionEnabled(false) end
                local fmt = GetDecimalFormatter(want.thr)
                if not fmt then return end -- rejected: tick keeps its mirror
                local bar = ns.GetTBBFrame and ns.GetTBBFrame(want.index)
                if not (bar and bar._timerText) then return end -- unbound: tick keeps its mirror
                -- The bound FS MUST be a descendant of the aura button (aspect
                -- inheritance) -- so the engine writes into this hidden one and
                -- the tick copies its string to the bar's real timer FS. Same
                -- carrier arrangement as the standard AuraKit regions; fonted
                -- BEFORE registration (style-before-register contract). It is
                -- never presented on-screen (the proxy is off-screen); only its string is read.
                local carrier = CreateFrame("Frame", nil, button)
                carrier:SetAllPoints(button)
                local fs = carrier:CreateFontString(nil, "OVERLAY")
                fs:SetFont((ns.GetCDMFont and ns.GetCDMFont())
                    or "Interface\\AddOns\\EllesmereUI\\media\\fonts\\Expressway.TTF", 12, "")
                fs:SetPoint("CENTER", button, "CENTER", 0, 0)
                fs:SetAlpha(0.001)
                -- Use the plain textFormatter option. The optional custom binding can
                -- be rejected by some clients; SetDurationTextSafe then succeeds with
                -- a bare options table, silently producing Blizzard's whole numbers.
                -- Only advertise this as a decimal source when the full formatter lands.
                local _, full = AK.SetDurationTextSafe(button, fs, AK.BuildDurationTextOpts(fmt))
                if full then
                    boundIndex[want.index] = button
                    boundThr[want.index] = want.thr
                    bar._tbbEngineText = button
                    bar._tbbEngineFS = fs
                end
            end,
        }
    end

    -- point is REQUIRED: the engine parses auras from a run-when-visible
    -- OnUpdate, and an unanchored container has no renderable rect -- it
    -- builds, binds slots, and then never processes a single aura (silent:
    -- the hidden FS stays empty and the tick falls back to whole seconds).
    container = AK.CreateContainer(host, "player", {
        point = { "BOTTOMLEFT", host, "BOTTOMLEFT", 0, 0 },
        slots = slots,
    })
    container:SetFrameLevel(host:GetFrameLevel() + 1)
end

-- Prefer the already-matched Blizzard CooldownViewer aura button as the
-- duration owner. It is the exact aura driving the Tracking Bar and already
-- carries the protected duration, so no duplicate aura filter is required.
local function BindDirect(want)
    local bar = ns.GetTBBFrame and ns.GetTBBFrame(want.index)
    local tbb = ns.GetTrackedBuffBars and ns.GetTrackedBuffBars()
    local cfg = tbb and tbb.bars and tbb.bars[want.index]
    local button = cfg and ns.FindTBBChild and ns.FindTBBChild(cfg)
    if not (bar and bar._timerText and button and button.SetDurationText) then return false end

    if directIndex[want.index] == button and directFS[want.index]
       and directThr[want.index] == want.thr then
        bar._tbbEngineText = button
        bar._tbbEngineFS = directFS[want.index]
        return true
    end
    if InCombatLockdown() then return false end

    local fmt = GetDecimalFormatter(want.thr)
    if not fmt then return false end
    local fs
    local okCreate = pcall(function()
        local carrier = CreateFrame("Frame", nil, button)
        carrier:SetAllPoints(button)
        carrier:SetFrameLevel(button:GetFrameLevel() + 5)
        fs = carrier:CreateFontString(nil, "OVERLAY")
        fs:SetFont((ns.GetCDMFont and ns.GetCDMFont())
            or "Interface\\AddOns\\EllesmereUI\\media\\fonts\\Expressway.TTF", 12, "")
        fs:SetPoint("CENTER", button, "CENTER", 0, 0)
        fs:SetAlpha(0.001)
    end)
    if not okCreate or not fs then return false end

    local _, full = AK.SetDurationTextSafe(button, fs, AK.BuildDurationTextOpts(fmt))
    if not full then return false end
    directIndex[want.index] = button
    directFS[want.index] = fs
    directThr[want.index] = want.thr
    bar._tbbEngineText = button
    bar._tbbEngineFS = fs
    return true
end

function ns.TBBDecimals_Sync()
    AK = AK or (EllesmereUI and EllesmereUI.AuraKit)
    if not AK then return end

    local desired, sig = CollectDesired()

    if not desired then
        if container then ReleaseCurrent() end
        return
    end

    if container and sig == signature then
        -- Same slot set: re-stamp the tick contract flags (BuildTrackedBuffBars
        -- runs often between swaps and nothing else ever sets these), and
        -- re-register any binding whose threshold slider moved -- a fresh
        -- SetDurationText on the live button swaps the formatter in place
        -- (established re-registration pattern; no container swap needed).
        for n = 1, #desired do
            local want = desired[n]
            local button = boundIndex[want.index]
            local bar = ns.GetTBBFrame and ns.GetTBBFrame(want.index)
            BindDirect(want)
            if button and bar then
                if directIndex[want.index] == nil then bar._tbbEngineText = button end
                if directIndex[want.index] == nil and bar._tbbEngineFS
                   and boundThr[want.index] ~= want.thr then
                    local fmt = GetDecimalFormatter(want.thr)
                    if fmt then
                        -- Stamp only on success: SetDurationTextSafe never throws
                        -- anymore, and a denied re-registration under restriction must
                        -- stay unstamped so a later Sync retries it.
                        local _, full = AK.SetDurationTextSafe(button, bar._tbbEngineFS,
                            AK.BuildDurationTextOpts(fmt))
                        if full then boundThr[want.index] = want.thr end
                    end
                end
            end
        end
        return
    end

    -- Slot set changed. The old bindings would keep writing the OLD spell's
    -- time onto re-purposed bar indexes, so tear down FIRST (bars fall back
    -- to the accurate whole-second passthrough for the gap), then build.
    -- Container creation is combat-illegal: defer the build, not the teardown.
    ReleaseCurrent()

    if InCombatLockdown() then
        pendingRegen = true
        if not regenFrame then
            regenFrame = ns.TakeShell()
            regenFrame:SetScript("OnEvent", function(self)
                self:UnregisterEvent("PLAYER_REGEN_ENABLED")
                if pendingRegen then
                    pendingRegen = nil
                    ns.TBBDecimals_Sync()
                end
            end)
        end
        regenFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
        return
    end
    pendingRegen = nil

    BuildContainer(desired)
    signature = container and sig or nil
    for n = 1, #desired do BindDirect(desired[n]) end
end

-- Temporary runtime diagnostics for the Tracking Bar decimal pipeline.
-- Usage: /asdebug while the tracked buff is active.
local function DebugPlain(v)
    if v == nil then return "nil" end
    if issecretvalue and issecretvalue(v) then return "<secret>" end
    return tostring(v)
end

function ns.TBBDecimals_Debug()
    local out = DEFAULT_CHAT_FRAME
    local function say(msg) out:AddMessage("|cff0cd29fTBB decimals:|r " .. msg) end
    local desired, sig = CollectDesired()
    say("AK=" .. DebugPlain(AK ~= nil)
        .. " container=" .. DebugPlain(container ~= nil)
        .. " signature=" .. DebugPlain(signature)
        .. " desiredSignature=" .. DebugPlain(sig))
    if not desired then
        say("No enabled aura Tracking Bars currently have Decimals enabled.")
        return
    end
    for n = 1, #desired do
        local want = desired[n]
        local tbb = ns.GetTrackedBuffBars and ns.GetTrackedBuffBars()
        local cfg = tbb and tbb.bars and tbb.bars[want.index]
        local bar = ns.GetTBBFrame and ns.GetTBBFrame(want.index)
        local blizz = cfg and ns.FindTBBChild and ns.FindTBBChild(cfg)
        local engFS = bar and bar._tbbEngineFS
        local engBtn = bar and bar._tbbEngineText
        local okText, engText = false, nil
        if engFS then okText, engText = pcall(engFS.GetText, engFS) end
        local okShown, btnShown = false, nil
        if engBtn then okShown, btnShown = pcall(engBtn.IsShown, engBtn) end

        -- IsShown() is secret for engine aura slots, so render its value through
        -- the engine-safe alpha setter instead of branching on or printing it.
        if engBtn and engBtn.IsShown and UIParent then
            local indicator = ns._tbbDecimalDebugIndicator
            if not indicator then
                indicator = CreateFrame("Frame", nil, UIParent)
                indicator:SetSize(260, 30)
                indicator:SetPoint("TOP", UIParent, "TOP", 0, -120)
                indicator:SetFrameStrata("TOOLTIP")
                local label = indicator:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
                label:SetPoint("RIGHT", indicator, "CENTER", -4, 0)
                label:SetText("AS decimal slot:")
                local active = indicator:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
                active:SetPoint("LEFT", indicator, "CENTER", 4, 0)
                active:SetText("|cff00ff00ACTIVE|r")
                local inactive = indicator:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
                inactive:SetPoint("LEFT", indicator, "CENTER", 4, 0)
                inactive:SetText("|cffff4040INACTIVE|r")
                indicator.active = active
                indicator.inactive = inactive
                ns._tbbDecimalDebugIndicator = indicator
            end
            indicator:Show()
            if indicator.active.SetAlphaFromBoolean then
                local state = engBtn:IsShown()
                indicator.active:SetAlphaFromBoolean(state, 1, 0)
                indicator.inactive:SetAlphaFromBoolean(state, 0, 1)
            end
            C_Timer.After(10, function() indicator:Hide() end)
        end
        local idCount = 0
        for _ in pairs(want.include) do idCount = idCount + 1 end
        say("bar " .. want.index
            .. " name=" .. DebugPlain(cfg and cfg.name)
            .. " spellID=" .. DebugPlain(cfg and cfg.spellID)
            .. " threshold=" .. DebugPlain(want.thr)
            .. " formatter=" .. DebugPlain(GetDecimalFormatter(want.thr) ~= nil)
            .. " ids=" .. idCount)
        say("  BlizzardFrame=" .. DebugPlain(blizz ~= nil)
            .. " cooldownID=" .. DebugPlain(blizz and blizz.cooldownID)
            .. " SetDurationText=" .. DebugPlain(blizz and blizz.SetDurationText ~= nil)
            .. " direct=" .. DebugPlain(directIndex[want.index] == blizz)
            .. " boundButton=" .. DebugPlain(engBtn ~= nil)
            .. " shownOK=" .. DebugPlain(okShown)
            .. " shown=" .. DebugPlain(btnShown)
            .. " engineFS=" .. DebugPlain(engFS ~= nil)
            .. " GetTextOK=" .. DebugPlain(okText)
            .. " engineText=" .. DebugPlain(engText))
    end
end

SLASH_EUITBBDECDEBUG1 = "/asdebug"
SlashCmdList.EUITBBDECDEBUG = function() ns.TBBDecimals_Debug() end

