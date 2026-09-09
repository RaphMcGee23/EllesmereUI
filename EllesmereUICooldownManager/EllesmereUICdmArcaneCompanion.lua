if EUI_CLIENT_BLOCKED then return end

--------------------------------------------------------------------------------
-- Engine-owned Arcane companion labels for Tracking Bars.
--
-- This is the same pattern used by EUI_ResourceBars_ArcaneSoul: a visible
-- FontString is a descendant of an engine aura-slot button and is registered
-- through SetDurationText with a NumericRuleFormatter and a RemainingDuration
-- ColorCurve. The aura engine owns both visibility and colour. No protected
-- duration or protected colour ever crosses back into addon Lua.
--------------------------------------------------------------------------------

local _, ns = ...
local EUI = _G.EllesmereUI

local SURGE_CAST_ID = 365350
local SURGE_AURA_ID = 365362
local SOUL_AURA_ID = 451038
local ARCANE_BLAST_ID = 30451
local GCD_SPELL_ID = 61304
local STYLE_KEY = "ecme:tbb-arcane-companion"

local S = {
    surge = { include = { [SURGE_CAST_ID] = true, [SURGE_AURA_ID] = true } },
    soul = { include = { [SOUL_AURA_ID] = true } },
}
local built, queued, dirty

local function CfgHasID(cfg, id)
    if not cfg then return false end
    if cfg.spellID == id or cfg.baseSpellID == id then return true end
    if cfg.spellIDs then
        for i = 1, #cfg.spellIDs do
            if cfg.spellIDs[i] == id then return true end
        end
    end
    return false
end

local function ArcaneBlastSeconds()
    if UnitCastingInfo then
        local _, _, _, startMS, endMS, _, _, _, spellID = UnitCastingInfo("player")
        if type(spellID) == "number" and not (issecretvalue and issecretvalue(spellID))
           and spellID == ARCANE_BLAST_ID
           and type(startMS) == "number" and type(endMS) == "number"
           and not (issecretvalue and (issecretvalue(startMS) or issecretvalue(endMS))) then
            return math.floor((endMS - startMS) / 10 + 0.5) / 100
        end
    end
    local info = C_Spell and C_Spell.GetSpellInfo
        and C_Spell.GetSpellInfo(ARCANE_BLAST_ID)
    local ms = info and info.castTime
    if type(ms) ~= "number" or (issecretvalue and issecretvalue(ms)) or ms <= 0 then
        return S.surge.threshold or 1.5
    end
    return math.floor(ms / 10 + 0.5) / 100
end

local function GCDSeconds()
    local cd = C_Spell and C_Spell.GetSpellCooldown
        and C_Spell.GetSpellCooldown(GCD_SPELL_ID)
    local d = cd and cd.duration
    if type(d) == "number" and not (issecretvalue and issecretvalue(d))
       and d >= 0.7 and d <= 1.6 then
        d = math.floor(d * 100 + 0.5) / 100
        S.soul.gcd = d
        return d
    end
    local haste = UnitSpellHaste and UnitSpellHaste("player")
    if type(haste) ~= "number" or (issecretvalue and issecretvalue(haste)) then
        return S.soul.gcd or 1.5
    end
    d = 1.5 / (1 + haste / 100)
    if d < 0.75 then d = 0.75 elseif d > 1.6 then d = 1.6 end
    d = math.floor(d * 100 + 0.5) / 100
    S.soul.gcd = d
    return d
end

local function UpdateThresholdCurve(st, threshold, mode)
    if not (C_CurveUtil and C_CurveUtil.CreateColorCurve
            and Enum and Enum.LuaCurveType) then return false end
    if not st.curve then
        st.curve = C_CurveUtil.CreateColorCurve()
        st.curve:SetType(Enum.LuaCurveType.Step)
    end
    local curveStamp = string.format("%s|%.2f", mode or "timing", threshold)
    if st.curveStamp ~= curveStamp then
        st.curve:ClearPoints()
        if mode == "soul-check" then
            -- The last-GCD Prismatic Bolt recommendation is intentional, not
            -- an error state. Amber distinguishes it from the green Barrage
            -- recommendation without suggesting that the player has failed.
            st.curve:AddPoint(0, CreateColor(1.00, 0.72, 0.12, 1))
            st.curve:AddPoint(threshold + 0.0001, CreateColor(0.20, 1.00, 0.20, 1))
        else
            -- Arcane Surge retains its original cast-fits timing indication.
            st.curve:AddPoint(0, CreateColor(1.00, 0.18, 0.18, 1))
            st.curve:AddPoint(threshold + 0.0001, CreateColor(0.20, 1.00, 0.20, 1))
        end
        st.curveStamp = curveStamp
    end
    return true
end

local function UpdateLabelFormatter(st, stamp, points)
    if not (C_StringUtil and C_StringUtil.CreateNumericRuleFormatter) then
        return false
    end
    if not st.formatter then
        st.formatter = C_StringUtil.CreateNumericRuleFormatter()
    end
    if st.formatterStamp ~= stamp then
        if not pcall(st.formatter.SetBreakpoints, st.formatter, points) then
            return false
        end
        st.formatterStamp = stamp
    end
    return true
end

local function PhaseRules(name)
    if name == "surge" then
        local threshold = ArcaneBlastSeconds()
        local label = string.format("AB: %.2fs", threshold)
        return threshold, label, { { threshold = 0, format = label } }, "timing"
    end
    -- Surface the final-window decision during the PREVIOUS action's GCD.
    -- Two haste-adjusted GCDs remaining gives the player one full GCD of
    -- notice instead of changing the prompt midway through the next input.
    local threshold = GCDSeconds() * 2
    -- Install both messages before combat. Blizzard's duration engine selects
    -- between them using Arcane Soul's protected remaining duration, so addon
    -- Lua never needs to replace the string when Prismatic Bolt procs.
    local stamp = string.format("soul-static|%.2f", threshold)
    return threshold, stamp, {
        { threshold = 0, format = "Next: Check Prismatic Bolt" },
        { threshold = threshold + 0.0001, format = "Arcane Barrage" },
    }, "soul-check"
end

local function BindPhase(name, st)
    local AK = EUI and EUI.AuraKit
    if not (AK and st.button and st.text) then return false end
    local threshold, stamp, points, curveMode = PhaseRules(name)
    -- Formatter and curve objects remain the SAME objects for the lifetime of
    -- the binding. Mutating them in place is combat-safe and is the established
    -- live-update pattern used by duration text elsewhere in the UI suite.
    if not UpdateLabelFormatter(st, stamp, points)
       or not UpdateThresholdCurve(st, threshold, curveMode) then return false end
    if st.bound then
        st.threshold, st.stamp = threshold, stamp
        return true
    end
    if InCombatLockdown and InCombatLockdown() then
        dirty = true
        return false
    end
    local ok, full = AK.SetDurationTextSafe(st.button, st.text,
        AK.BuildDurationTextOpts(st.formatter, st.curve, 0.10))
    if ok and full then
        st.threshold, st.stamp, st.bound = threshold, stamp, true
        return true
    end
    st.bound = nil
    dirty = true
    return false
end

local function BuildPhase(name, st)
    local AK = EUI.AuraKit
    local host = CreateFrame("Frame", nil, UIParent)
    host:SetSize(180, 64)
    host:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    host:SetFrameStrata("MEDIUM")
    host:EnableMouse(false)
    host:Show()
    st.host = host

    local container = AK.CreateContainerShell(host, {
        point = { "CENTER", host, "CENTER", 0, 0 },
    })
    AK.AddSlotToContainer(container, {
        key = name,
        filter = { "HELPFUL" },
        candidateFilters = { includeSpellIDs = st.include },
        style = STYLE_KEY,
        extraInit = function(button)
            button:SetAllPoints(host)
            if button.SetMouseClickEnabled then button:SetMouseClickEnabled(false) end
            if button.SetMouseMotionEnabled then button:SetMouseMotionEnabled(false) end
            st.button = button

            local textLayer = CreateFrame("Frame", nil, button)
            textLayer:SetAllPoints(button)
            textLayer:SetFrameLevel(button:GetFrameLevel() + 5)
            local fs = textLayer:CreateFontString(nil, "OVERLAY")
            fs:SetFont((ns.GetCDMFont and ns.GetCDMFont()) or STANDARD_TEXT_FONT, 11, "")
            fs:SetPoint("LEFT", host, "LEFT", 0, 0)
            fs:SetJustifyH("LEFT")
            st.text = fs
            BindPhase(name, st)
        end,
    })
    AK.FinishContainer(container, "player")
    container:SetFrameLevel(host:GetFrameLevel() + 1)
    st.container = container
end

local function Build()
    if built then return end
    local AK = EUI and EUI.AuraKit
    if not AK then return end
    AK.styles[STYLE_KEY] = AK.styles[STYLE_KEY]
        or { noRegions = true, width = 1, height = 1 }
    BuildPhase("surge", S.surge)
    BuildPhase("soul", S.soul)
    built = true
end

local function AttachPhase(st, index)
    st.index = index
    if not st.host then return end
    local bar = index and ns.GetTBBFrame and ns.GetTBBFrame(index)
    if not bar then
        st.host:Hide()
        return
    end
    st.host:ClearAllPoints()
    st.host:SetPoint("LEFT", bar, "RIGHT", 8, 0)
    st.host:SetFrameStrata(bar:GetFrameStrata())
    st.host:SetFrameLevel(bar:GetFrameLevel() + 9)
    st.host:Show()
    if st.text and bar._timerText then
        local font, size, flags = bar._timerText:GetFont()
        if font and size then pcall(st.text.SetFont, st.text, font, size, flags or "") end
    end
end

local function RefreshBindings()
    if not built then return end
    BindPhase("surge", S.surge)
    BindPhase("soul", S.soul)
end

local function EnsureBuilt()
    if built or queued then return end
    local AK = EUI and EUI.AuraKit
    if not (AK and AK.QueueBuildJob) then return end
    queued = true
    AK.QueueBuildJob(function()
        queued = nil
        local ok = pcall(Build)
        if not ok then return end
        AttachPhase(S.surge, S.surge.index)
        AttachPhase(S.soul, S.soul.index)
        RefreshBindings()
    end, "ecme:tbb-arcane-companion")
end

function ns.TBBArcaneCompanion_Sync()
    local tbb = ns.GetTrackedBuffBars and ns.GetTrackedBuffBars()
    local bars = tbb and tbb.bars
    local surgeIndex, soulIndex
    for i, cfg in ipairs(bars or {}) do
        if cfg.enabled ~= false then
            if not surgeIndex and (CfgHasID(cfg, SURGE_CAST_ID)
               or CfgHasID(cfg, SURGE_AURA_ID)) then surgeIndex = i end
            if not soulIndex and CfgHasID(cfg, SOUL_AURA_ID) then soulIndex = i end
        end
    end
    S.surge.index, S.soul.index = surgeIndex, soulIndex
    if surgeIndex or soulIndex then EnsureBuilt() end
    if built then
        AttachPhase(S.surge, surgeIndex)
        AttachPhase(S.soul, soulIndex)
        RefreshBindings()
    end
end

function ns.TBBArcaneCompanion_IsReady(phase)
    local st = S[phase]
    return st and st.index and st.bound and st.text and true or false
end

-- Called by the existing 5 Hz companion refresh. No extra ticker: unchanged
-- values return after two string/number comparisons, while a haste change
-- mutates the already-bound formatter and curve objects in place.
function ns.TBBArcaneCompanion_Refresh()
    if built then RefreshBindings() end
end

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterUnitEvent("UNIT_SPELL_HASTE", "player")
events:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_ENTERING_WORLD" then
        ns.TBBArcaneCompanion_Sync()
        return
    end
    if event == "PLAYER_REGEN_ENABLED" then dirty = nil end
    if built then RefreshBindings() end
end)

if EUI and EUI.AuraKit and EUI.AuraKit.OnRestrictionLift then
    EUI.AuraKit.OnRestrictionLift(function()
        if dirty then
            dirty = nil
            RefreshBindings()
        end
    end)
end
