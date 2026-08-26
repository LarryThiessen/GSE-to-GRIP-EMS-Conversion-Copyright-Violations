-- GRIP-EMS: Sequencer Engine
-- Core sequencer: SecureActionButton creation, step loading, activation, resets

local ADDON_NAME, GRIPEMS = ...
local L = LibStub("AceLocale-3.0"):GetLocale("GRIP-EMS")
local D = GRIPEMS.Defaults
local SF = GRIPEMS.StepFunctions
local MM = GRIPEMS.MacroManager
local KM = GRIPEMS.KeybindManager

-- Engine module: the heart of GRIP-EMS. Creates one SecureActionButton per
-- active sequence, loads step data into the restricted environment via
-- :Execute(), and wires up WrapScript OnClick body for step advancement.
-- Buttons start with type="macro" so the WrapScript only needs to swap
-- macrotext content (WoW silently blocks type attribute changes in the
-- restricted environment). An empty macrotext with type="macro" is a safe
-- no-op for sequences with no steps loaded yet.
-- Macro stubs (/click GRIPEMS_Name) trigger these buttons.
-- All button creation and attribute changes from insecure code go through
-- OOCQueue to respect combat lockdown restrictions.
GRIPEMS.Engine = {
    sequences = {}, -- name -> { button, data }
    currentContext = "none", -- active content context (T2-1)
    corruptSequences = {}, -- corrupt entries found during restore
    _buttonPressTimes = {}, -- rolling window for tempo overlay press rate
    BUTTON_PRESS_WINDOW = 10, -- seconds of press history to keep
}
local Engine = GRIPEMS.Engine

--- Resolve variables, fit keyPress/keyRelease per step, and expand via the
--- given expand function. Used by Priority and ReversePriority paths in both
--- ActivateSequence and RecompileSequence.
--- @param engine table Engine instance (for SubstituteVariables)
--- @param steps table Array of step strings
--- @param kp string keyPress text (may be empty)
--- @param kr string keyRelease text (may be empty)
--- @param expandFunc function Called with resolved array, returns compiled steps
--- @return table Compiled steps from expandFunc
local function ResolveFitAndExpand(engine, steps, kp, kr, expandFunc)
    local resolved = {}
    for i, step in ipairs(steps) do
        resolved[i] = engine:SubstituteVariables(tostring(step))
        local combined = resolved[i]
        if kp ~= "" then
            combined = kp .. "\n" .. combined
        end
        if kr ~= "" then
            combined = combined .. "\n" .. kr
        end
        if #combined <= D.MAX_SAB_MACROTEXT_LENGTH then
            resolved[i] = combined
        end
    end
    return expandFunc(resolved)
end

--- Sanitize a sequence name for use as a global frame name.
--- Strips non-alphanumeric characters and replaces spaces with underscores.
--- @param name string Raw sequence name
--- @return string Sanitized name safe for global frame names
function Engine:SanitizeName(name)
    if not name then
        return "Unknown"
    end
    local sanitized = name:gsub("%s+", "_"):gsub("[^%w_]", "")
    if sanitized == "" then
        sanitized = "Unknown"
    end
    return sanitized
end

--- Substitute ~varname~ references in a macrotext string with evaluated values.
--- Variables are resolved via VariableStore:Evaluate(). Failed evaluations
--- are replaced with empty string and logged.
--- @param text string Raw macrotext with potential ~varname~ references
--- @return string Resolved macrotext with variables substituted
function Engine:SubstituteVariables(text)
    if not text or text == "" then
        return text
    end
    local VS = GRIPEMS.VariableStore
    if not VS then
        return text
    end

    return text:gsub(D.VAR_PATTERN, function(varName)
        local value, err = VS:Evaluate(varName)
        if value == nil then
            -- Fallback: check gear-aware variables
            local GV = GRIPEMS.GearVariables
            if GV then
                local gearValue = GV:Get(varName)
                if gearValue then
                    return tostring(gearValue)
                end
            end
            if err and err ~= "Not found" then
                GRIPEMS:Debug(string.format(L["GEMS_VAR_EVAL_ERROR"], varName, tostring(err)))
            end
            return ""
        end
        return tostring(value)
    end)
end

--- Compile raw string steps into attribute table format.
--- Performs variable substitution (~varname~) before compiling.
--- When keyPress/keyRelease are provided, each step's macrotext is combined
--- with keyPress/keyRelease IF the total fits within 255 chars. Steps that
--- exceed the limit get only the resolved step text (keyPress fires only via
--- action bar macro stub clicks for those steps).
--- @param steps table Array of macro text strings
--- @param keyPress string|nil KeyPress block to prepend per step
--- @param keyRelease string|nil KeyRelease block to append per step
--- @return table Array of attribute tables (e.g. {type="macro", macrotext="..."})
function Engine:CompileSteps(steps, keyPress, keyRelease)
    if not steps then
        return {}
    end
    local kp = keyPress or ""
    local kr = keyRelease or ""
    local compiled = {}
    local fitted = 0
    local total = #steps
    for i, stepText in ipairs(steps) do
        local resolved = self:SubstituteVariables(tostring(stepText))
        local combined
        if kp ~= "" and kr ~= "" then
            combined = kp .. "\n" .. resolved .. "\n" .. kr
        elseif kp ~= "" then
            combined = kp .. "\n" .. resolved
        elseif kr ~= "" then
            combined = resolved .. "\n" .. kr
        else
            combined = resolved
        end
        if #combined <= D.MAX_SAB_MACROTEXT_LENGTH then
            compiled[i] = { type = D.ATTR_TYPE_MACRO, macrotext = combined }
            if kp ~= "" or kr ~= "" then
                fitted = fitted + 1
            end
        else
            compiled[i] = { type = D.ATTR_TYPE_MACRO, macrotext = resolved }
        end
    end
    if (kp ~= "" or kr ~= "") and fitted < total then
        GRIPEMS:Print(L["GEMS_WARN_KP_STEP_OVERFLOW"]:format(fitted, total, total - fitted))
    end
    return compiled
end

--- Simulate N keypresses of a sequence and return the step order with spell info.
--- Used by the icon strip preview UI. Side-effect-free (no writes to Engine state).
--- @param seqData table Sequence data (with versions, stepFunction)
--- @param count number Number of keypresses to simulate (default 20)
--- @return table Array of { stepIndex, macrotext, spellName, iconID, spellStatus, isRandom }
function Engine:SimulateSteps(seqData, count)
    count = count or 20
    local result = {}
    local ver = self:GetActiveVersion(seqData)
    if not ver or not ver.steps or #ver.steps == 0 then
        return result
    end

    local SC = GRIPEMS.SpellCache
    local sf = ver.stepFunction or "Sequential"

    -- Resolve variables in all steps first
    local resolvedSteps = {}
    for i, stepText in ipairs(ver.steps) do
        resolvedSteps[i] = self:SubstituteVariables(tostring(stepText))
    end

    -- Build the execution order based on step function
    local execOrder -- array of resolved macrotext strings in execution order
    if sf == "Priority" then
        local expanded = SF:ExpandPriority(resolvedSteps)
        execOrder = {}
        for _, entry in ipairs(expanded) do
            execOrder[#execOrder + 1] = entry.macrotext or ""
        end
    elseif sf == "ReversePriority" then
        local expanded = SF:ExpandReversePriority(resolvedSteps)
        execOrder = {}
        for _, entry in ipairs(expanded) do
            execOrder[#execOrder + 1] = entry.macrotext or ""
        end
    elseif sf == "Random" then
        -- Random: cannot predict order. Return each unique step once
        -- with a flag indicating random selection
        for i, resolved in ipairs(resolvedSteps) do
            local spellName = SC and SC.ParseSpellFromMacrotext and SC:ParseSpellFromMacrotext(resolved) or nil
            local iconID = spellName and SC and SC.GetIcon and SC:GetIcon(spellName) or nil
            -- Check spell validity if SpellValidator available
            local spellStatus = nil
            local SV = GRIPEMS.SpellValidator
            if SV and SV.ValidateSpell and spellName then
                local valResult = SV:ValidateSpell(spellName, "cast")
                spellStatus = valResult.status
                if not iconID then
                    iconID = valResult.icon
                end
            end
            result[#result + 1] = {
                stepIndex = i,
                macrotext = resolved,
                spellName = spellName,
                iconID = iconID,
                spellStatus = spellStatus,
                isRandom = true,
            }
        end
        return result
    else
        -- Sequential: just use resolvedSteps directly
        execOrder = resolvedSteps
    end

    -- Generate count simulated keypresses (round-robin over execOrder)
    local totalSteps = #execOrder
    if totalSteps == 0 then
        return result
    end
    for press = 1, count do
        local idx = ((press - 1) % totalSteps) + 1
        local macrotext = execOrder[idx]
        local spellName = SC and SC.ParseSpellFromMacrotext and SC:ParseSpellFromMacrotext(macrotext) or nil
        local iconID = spellName and SC and SC.GetIcon and SC:GetIcon(spellName) or nil
        local spellStatus = nil
        local SV = GRIPEMS.SpellValidator
        if SV and SV.ValidateSpell and spellName then
            local valResult = SV:ValidateSpell(spellName, "cast")
            spellStatus = valResult.status
            if not iconID then
                iconID = valResult.icon
            end
        end
        result[#result + 1] = {
            stepIndex = idx,
            macrotext = macrotext,
            spellName = spellName,
            iconID = iconID,
            spellStatus = spellStatus,
            isRandom = false,
        }
    end
    return result
end

--- Build the Execute() string that creates the steps table in the restricted
--- environment. Each step is a newtable() with string-keyed attribute pairs.
--- Uses long bracket strings [=======[...]=======] for values to safely embed
--- any macro text without escaping issues.
--- @param compiledSteps table Array of attribute tables ({type=X, macrotext=Y})
--- @return string Lua code string for btn:Execute()
function Engine:BuildExecuteString(compiledSteps)
    if not compiledSteps or #compiledSteps == 0 then
        return "steps = newtable()\nnumSteps = 0\n"
    end
    local parts = { "steps = newtable()\n" }
    for i, stepData in ipairs(compiledSteps) do
        parts[#parts + 1] = "steps[" .. i .. "] = newtable()\n"
        if type(stepData) == "table" then
            for k, v in pairs(stepData) do
                parts[#parts + 1] = "steps["
                    .. i
                    .. ']["'
                    .. tostring(k)
                    .. '"] = [=======['
                    .. tostring(v)
                    .. "]=======]\n"
            end
        end
    end
    parts[#parts + 1] = "numSteps = " .. #compiledSteps .. "\n"
    return table.concat(parts)
end

--- Return the active version table for a sequence.
--- Single indirection point for all version access. Context-aware (T2-1):
--- checks contextOverrides + fallback chain before defaultVersion.
--- @param seqData table Sequence data (versioned format)
--- @return table|nil The active version table, or nil if none
function Engine:GetActiveVersion(seqData)
    if not seqData or not seqData.versions then
        return nil
    end

    -- Context resolution (T2-1)
    local overrides = seqData.contextOverrides
    if overrides and Engine.currentContext ~= D.CONTEXT_NONE then
        local ctx = Engine.currentContext
        -- Direct match
        local idx = overrides[ctx]
        if idx and seqData.versions[idx] then
            return seqData.versions[idx]
        end
        -- Fallback chain
        local fallbacks = D.CONTEXT_FALLBACKS[ctx]
        if fallbacks then
            for _, fbKey in ipairs(fallbacks) do
                idx = overrides[fbKey]
                if idx and seqData.versions[idx] then
                    return seqData.versions[idx]
                end
            end
        end
    end

    -- Default fallback
    local idx = seqData.defaultVersion or 1
    return seqData.versions[idx] or seqData.versions[1]
end

--- Migrate a flat-format seqData to the versioned format.
--- If seqData already has a non-empty versions table, returns it unchanged.
--- Otherwise wraps top-level fields into versions[1] and removes the flat fields.
--- @param seqData table Sequence data (flat or versioned)
--- @return table The migrated seqData (same reference, mutated in-place)
function Engine:MigrateSequenceFormat(seqData)
    if not seqData then
        return seqData
    end
    -- Already versioned: has non-empty versions table
    if seqData.versions and type(seqData.versions) == "table" and next(seqData.versions) then
        return seqData
    end

    -- Wrap flat fields into versions[1]
    local ver = {
        steps = seqData.steps or {},
        stepFunction = seqData.stepFunction or "Sequential",
        resetOnCombat = seqData.resetOnCombat or false,
        resetOnTarget = seqData.resetOnTarget or false,
        resetOnGear = seqData.resetOnGear or false,
        resetOnSpec = seqData.resetOnSpec or false,
        resetTimer = seqData.resetTimer or 0,
    }
    seqData.defaultVersion = 1
    seqData.versions = { ver }

    -- Remove old flat fields
    seqData.steps = nil
    seqData.stepFunction = nil
    seqData.resetOnCombat = nil
    seqData.resetOnTarget = nil
    seqData.resetOnGear = nil
    seqData.resetOnSpec = nil
    seqData.resetTimer = nil

    -- Ensure contextOverrides exists (T2-1)
    seqData.contextOverrides = seqData.contextOverrides or {}

    return seqData
end

--- Detect the current content context from instance and group state.
--- Uses GetInstanceInfo + difficultyID disambiguation for party/raid/scenario.
--- @return string Context key from D.CONTEXT_KEYS, or D.CONTEXT_NONE
function Engine:DetectContext()
    local _, instanceType, difficultyID = GetInstanceInfo()

    if instanceType == "party" or instanceType == "raid" then
        local ctx = D.DIFFICULTY_CONTEXT[difficultyID]
        if ctx then
            -- M+ tier sub-detection
            if ctx == "MythicPlus" then
                local keyLevel = C_ChallengeMode
                    and C_ChallengeMode.GetActiveKeystoneInfo
                    and C_ChallengeMode.GetActiveKeystoneInfo()
                if keyLevel and keyLevel > 0 then
                    local S = GRIPEMS.Settings
                    local mid = S and S:Get("mythicPlusTierMid") or D.MYTHICPLUS_TIER_MID_DEFAULT
                    local high = S and S:Get("mythicPlusTierHigh") or D.MYTHICPLUS_TIER_HIGH_DEFAULT
                    if keyLevel >= high then
                        return "MythicPlusHigh"
                    elseif keyLevel >= mid then
                        return "MythicPlusMid"
                    else
                        return "MythicPlusLow"
                    end
                end
                return "MythicPlus"
            end
            return ctx
        end
        if instanceType == "party" then
            return "Dungeon"
        end
        return "Raid"
    end

    if instanceType == "scenario" then
        if difficultyID == 208 then
            -- Delve tier sub-detection
            local tier = Engine:GetDelveTierFromCVar()
            if tier then
                local S = GRIPEMS.Settings
                local highThresh = S and S:Get("delvesTierHigh") or D.DELVES_TIER_HIGH_DEFAULT
                if tier >= highThresh then
                    return "DelvesHigh"
                else
                    return "DelvesLow"
                end
            end
            return "Delves"
        end
        return "Scenario"
    end

    -- PvP sub-detection (rated split)
    if instanceType == "arena" then
        if C_PvP and C_PvP.IsSoloShuffle and C_PvP.IsSoloShuffle() then
            return "SoloShuffle"
        end
        if C_PvP and C_PvP.IsRatedArena and C_PvP.IsRatedArena() then
            return "RatedArena"
        end
        -- Per-map detection for non-rated arenas (v1.2.0 S22-F)
        local instanceMapID = select(8, GetInstanceInfo())
        if instanceMapID and D.ARENA_MAP_CONTEXT[instanceMapID] then
            return D.ARENA_MAP_CONTEXT[instanceMapID]
        end
        return "Arena"
    end
    if instanceType == "pvp" then
        if C_PvP and C_PvP.IsSoloRBG and C_PvP.IsSoloRBG() then
            return "BattlegroundBlitz"
        end
        if C_PvP and C_PvP.IsRatedBattleground and C_PvP.IsRatedBattleground() then
            return "RatedBG"
        end
        -- Per-map detection for non-rated battlegrounds (v1.2.0 S22-F)
        local instanceMapID = select(8, GetInstanceInfo())
        if instanceMapID and D.BG_MAP_CONTEXT[instanceMapID] then
            return D.BG_MAP_CONTEXT[instanceMapID]
        end
        return "PVP"
    end

    if instanceType == "none" then
        if IsInGroup() then
            return "Party"
        end
        return "Solo"
    end

    return D.CONTEXT_NONE
end

--- Decode the Delve tier from the lastSelectedTieredEntranceTier CVar.
--- Returns the tier number (1-11) or nil if unavailable/unparseable.
--- @return number|nil tier
function Engine:GetDelveTierFromCVar()
    local b64 = GetCVar("lastSelectedTieredEntranceTier")
    if not b64 or b64 == "" then
        return nil
    end
    local ok1 = C_EncodingUtil and C_EncodingUtil.DecodeBase64
    if not ok1 then
        return nil
    end
    local raw = C_EncodingUtil.DecodeBase64(b64)
    if not raw then
        return nil
    end
    local ok2 = C_EncodingUtil and C_EncodingUtil.DeserializeCBOR
    if not ok2 then
        return nil
    end
    local tbl = C_EncodingUtil.DeserializeCBOR(raw)
    if not tbl or type(tbl) ~= "table" then
        return nil
    end
    -- CVar stores single-entry map {pdeID = tierNumber}
    for _, tier in pairs(tbl) do
        if type(tier) == "number" and tier > 0 then
            return tier
        end
    end
    return nil
end

--- Check for context changes and reload affected sequences.
--- Called on zone change, group roster update, and login.
function Engine:UpdateContext()
    local newContext = self:DetectContext()
    if newContext == self.currentContext then
        return
    end

    local oldContext = self.currentContext
    self.currentContext = newContext
    GRIPEMS:Debug(string.format(L["GEMS_CONTEXT_CHANGED"], D.CONTEXT_LABELS[newContext] or newContext))
    if GRIPEMS.Fire then
        GRIPEMS:Fire("CONTEXT_CHANGED", newContext, oldContext)
    end
    self:ReloadContextSequences()
end

--- Reload sequences whose resolved version changed due to a context switch.
--- Deactivates and reactivates affected sequences via OOCQueue.
function Engine:ReloadContextSequences()
    local reloaded = 0
    for name, entry in pairs(self.sequences) do
        local seqData = entry.data
        if seqData and seqData.contextOverrides and next(seqData.contextOverrides) then
            -- Compare resolved version INDEX against what button currently runs
            -- (T2-1 hotfix: table refs are identical, so compare indices instead)
            local btn = entry.button
            if btn then
                local newVer = self:GetActiveVersion(seqData)
                local newIdx = nil
                if newVer and seqData.versions then
                    for vi, v in ipairs(seqData.versions) do
                        if v == newVer then
                            newIdx = vi
                            break
                        end
                    end
                end
                local oldIdx = btn.activeVersionIdx
                if newIdx and oldIdx and newIdx ~= oldIdx then
                    local function doReload()
                        Engine:DeactivateSequence(name)
                        Engine:ActivateSequence(name, seqData)
                    end
                    GRIPEMS.OOCQueue:Add(doReload, D.OOC_OP_RELOAD, name)
                    reloaded = reloaded + 1
                end
            end
        end
    end
    if reloaded > 0 then
        GRIPEMS:Debug(string.format(L["GEMS_CONTEXT_RELOAD"], reloaded))
    end
end

-- SetInitialAttributes removed: OnClick preBody sets attributes on first
-- click. The button starts with type="macro" (empty macrotext = safe no-op).
-- WoW's restricted env silently blocks type attribute changes, so the button
-- must start as type="macro" and the WrapScript body only swaps macrotext content.

--- Create and configure a SecureActionButton for a sequence.
--- The button inherits both SecureActionButtonTemplate (for action execution)
--- and SecureHandlerBaseTemplate (for :Execute() and :WrapScript()).
--- Initial type is "macro"; the click body swaps macrotext per-step.
--- Must be called out of combat (goes through OOCQueue).
--- @param name string Sequence name
--- @param sequenceData table Sequence definition (steps, stepFunction, etc.)
function Engine:ActivateSequence(name, sequenceData)
    if not name or not sequenceData then
        return
    end
    -- Disabled sequences: register without creating button/keybind
    if sequenceData.disabled then
        self:RegisterSequenceOnly(name, sequenceData)
        if _G.GRIP_EMS_CHAR then
            GRIP_EMS_CHAR.sequences = GRIP_EMS_CHAR.sequences or {}
            GRIP_EMS_CHAR.sequences[name] = sequenceData
        end
        return
    end
    local ver = self:GetActiveVersion(sequenceData)
    local steps = ver and ver.steps or {}

    -- Validate steps for diagnostics (warn-only, do not block activation)
    if #steps > 0 then
        local valid, errors = SF:ValidateSteps(steps)
        if not valid then
            for _, err in ipairs(errors) do
                GRIPEMS:Debug(err)
            end
        end
    end

    -- Deactivate existing sequence with the same name first
    if self.sequences[name] then
        self:DeactivateSequence(name)
    end

    local function doActivate()
        local sanitized = self:SanitizeName(name)
        local globalName = D.BUTTON_PREFIX .. sanitized

        -- Clean up any existing global button with this name.
        -- In WoW Retail, CreateFrame with an existing global name returns the
        -- OLD frame (hidden, parentless from DeactivateSequence) without resetting
        -- its state. Clearing _G forces CreateFrame to build a genuinely new button,
        -- matching the fresh-button behavior seen after relog. (BUG-029 Issue A)
        local existing = _G[globalName]
        if existing then
            existing:SetAttribute("type", nil)
            existing:UnregisterAllEvents()
            existing:Hide()
            existing:SetParent(nil)
            _G[globalName] = nil
        end

        -- Create the button with dual-template inheritance, nil parent
        local btn = CreateFrame("Button", globalName, nil, "SecureActionButtonTemplate,SecureHandlerBaseTemplate")
        btn:Show()
        btn:SetAttribute("type", D.ATTR_TYPE_MACRO)
        btn:SetAttribute("step", 1)
        local activeVer = Engine:GetActiveVersion(sequenceData)
        local resetTimer = activeVer and activeVer.resetTimer or 0
        if resetTimer > 0 then
            btn:SetAttribute("resetTimer", resetTimer)
        end
        btn:SetAttribute("_shouldReset", "0")
        -- Set macro reset modifier attributes for restricted env checks
        local seqResetMods = activeVer and activeVer.resetModifiers
        local resetMods
        if seqResetMods then
            resetMods = {}
            local globalMods = GRIPEMS.Settings:GetResetModifiers()
            for mod, default in pairs(globalMods) do
                if seqResetMods[mod] ~= nil then
                    resetMods[mod] = seqResetMods[mod]
                else
                    resetMods[mod] = default
                end
            end
        else
            resetMods = GRIPEMS.Settings:GetResetModifiers()
        end
        for mod, enabled in pairs(resetMods) do
            btn:SetAttribute("resetMod_" .. mod, enabled and "1" or nil)
        end
        btn:RegisterForClicks("AnyDown")

        -- Store sequence metadata on the button for CallMethod access
        btn.seqName = name
        btn.seqData = sequenceData

        -- Store resolved version index for context-switch comparison (T2-1 hotfix)
        local resolvedVer = Engine:GetActiveVersion(sequenceData)
        btn.activeVersionIdx = nil
        if resolvedVer and sequenceData.versions then
            for vi, v in ipairs(sequenceData.versions) do
                if v == resolvedVer then
                    btn.activeVersionIdx = vi
                    break
                end
            end
        end

        -- Insecure method called from restricted env via CallMethod('UpdateIcon')
        btn.UpdateIcon = function(self)
            GRIPEMS.Engine:UpdateButtonIcon(self)
        end

        -- Insecure method called from restricted env via CallMethod('PostClick')
        -- Handles reset-timer logic using GetTime() (unavailable in restricted env).
        -- Also stores effective click rate as metadata for /gems status display.
        btn.PostClick = function(self)
            local now = GetTime()
            -- Reset timer check
            local resetTimer = self:GetAttribute("resetTimer") or 0 -- luacheck: no redefined
            if resetTimer > 0 then
                local lastPress = self._lastPress or 0
                if lastPress > 0 and (now - lastPress) > resetTimer then
                    if not GRIPEMS.OOCQueue.IsRestricted() then
                        self:SetAttribute("_shouldReset", "1")
                    end
                end
                self._lastPress = now
            end
            -- Store effective click rate as metadata (informational)
            self._effectiveClickRate = GRIPEMS.Settings:GetEffectiveClickRate()
            -- Store last clicked sequence for ExecutionTracer association
            self._lastClickedSequence = self.seqName
            self._lastClickTime = now
            local EngineRef = GRIPEMS.Engine
            if EngineRef then
                EngineRef._lastClickedSequence = self.seqName
                EngineRef._lastClickTime = now
                -- Rolling button press window for tempo overlay
                local bpt = EngineRef._buttonPressTimes
                bpt[#bpt + 1] = now
                while #bpt > 0 and (now - bpt[1]) > EngineRef.BUTTON_PRESS_WINDOW do
                    table.remove(bpt, 1)
                end
            end
        end

        -- Only compile/Execute/WrapScript if we have steps to load.
        -- Empty sequences get a button (type="macro" + empty macrotext = safe
        -- no-op) but no WrapScript wiring. Steps are added via UpdateSequenceData.
        local curVer = Engine:GetActiveVersion(sequenceData)
        -- Action tree compilation: flatten actions to steps before runtime use
        if curVer and curVer.actions and #curVer.actions > 0 then
            curVer.steps = GRIPEMS.ActionCompiler.CompileActions(curVer.actions, self)
        end
        local stepsToLoad = curVer and curVer.steps or {}
        local stepFuncName = curVer and curVer.stepFunction or D.STEP_SEQUENTIAL
        local kp = curVer and curVer.keyPress or ""
        local kr = curVer and curVer.keyRelease or ""
        if #stepsToLoad > 0 then
            -- Determine which steps to load based on step function
            local stepFunc = SF:Get(stepFuncName) or SF.Sequential

            -- Compile steps: Priority/ReversePriority pre-expand into flat
            -- arrays of single-step entries; Sequential/Random wrap individually.
            local compiledSteps
            if stepFuncName == D.STEP_PRIORITY then
                compiledSteps = ResolveFitAndExpand(self, stepsToLoad, kp, kr, function(r)
                    return SF:ExpandPriority(r)
                end)
            elseif stepFuncName == D.STEP_REVERSE_PRIORITY then
                compiledSteps = ResolveFitAndExpand(self, stepsToLoad, kp, kr, function(r)
                    return SF:ExpandReversePriority(r)
                end)
            else
                compiledSteps = self:CompileSteps(stepsToLoad, kp, kr)
            end

            -- Load step data into the restricted environment via :Execute()
            local execStr = self:BuildExecuteString(compiledSteps)
            local ok, err = pcall(btn.Execute, btn, execStr)
            if not ok then
                GRIPEMS:Debug("Execute failed: " .. tostring(err))
            end

            -- Wire up WrapScript OnClick body for step advancement.
            -- Method form: header:WrapScript(frame, script, body)
            -- where header=btn (env owner) and frame=btn (script target).
            -- Body runs in restricted env: sets step attributes, advances,
            -- then calls PostClick for time-based throttle/reset.
            local clickBody = stepFunc.BuildClickBody()
            btn:WrapScript(btn, "OnClick", clickBody)
        end

        -- Register the sequence
        self.sequences[name] = {
            button = btn,
            data = sequenceData,
        }

        -- Persist to SavedVariables (survives /reload)
        if _G.GRIP_EMS_CHAR then
            GRIP_EMS_CHAR.sequences = GRIP_EMS_CHAR.sequences or {}
            GRIP_EMS_CHAR.sequences[name] = sequenceData
        end

        local activeSteps = curVer and curVer.steps or {}
        GRIPEMS:Debug(string.format(L["GEMS_SEQ_ACTIVATED"], name, #activeSteps))

        -- Create the macro stub so the player can drag it to the action bar
        MM:CreateStub(name, kp, kr)

        -- Apply keybinding if one exists for this sequence
        -- Skip during initial load: LoadKeybinds() runs after
        -- RestoreSavedSequences and applies all binds in one pass.
        if KM and self._initialLoadComplete then
            KM:BindIfConfigured(name)
        end

        -- Notify listeners
        if GRIPEMS.Fire then
            GRIPEMS:Fire("SEQUENCE_CREATED", name, sequenceData)
        end

        -- Faster, Slower: notify TempoAdvisor of sequence activation
        if GRIPEMS.TempoAdvisor then
            GRIPEMS.TempoAdvisor:OnSequenceActivated(name, sequenceData)
        end
    end

    GRIPEMS.OOCQueue:Add(doActivate, D.OOC_OP_ACTIVATE, name)
end

--- Register a sequence without creating a SecureActionButton (dormant).
--- The sequence appears in the UI list but cannot fire until activated.
--- @param name string Sequence name
--- @param seqData table Sequence data
function Engine:RegisterSequenceOnly(name, seqData)
    if not name or not seqData then
        return
    end
    -- Skip if already registered (active or dormant)
    if self.sequences[name] then
        return
    end
    self.sequences[name] = {
        button = nil, -- dormant: no SecureActionButton
        data = seqData,
    }
    -- Fire callback so SequenceList sees it
    if GRIPEMS.Fire then
        GRIPEMS:Fire("SEQUENCE_CREATED", name, seqData)
    end
end

--- Promote a dormant (registered but button=nil) sequence to fully active.
--- @param name string Sequence name
function Engine:ActivateDormantSequence(name)
    local entry = self.sequences[name]
    if not entry or entry.button then
        return
    end -- not dormant or already active
    -- Remove the dormant registration so ActivateSequence can re-register
    self.sequences[name] = nil
    -- Full activation (creates button, stub, keybind, fires callback)
    self:ActivateSequence(name, entry.data)
end

--- Check whether a sequence is registered but dormant (no button).
--- @param name string Sequence name
--- @return boolean
function Engine:IsSequenceDormant(name)
    local entry = self.sequences[name]
    return entry ~= nil and entry.button == nil
end

--- Return the count of dormant (button=nil) sequences.
--- @return number
function Engine:GetDormantCount()
    local count = 0
    for _, entry in pairs(self.sequences) do
        if entry.button == nil then
            count = count + 1
        end
    end
    return count
end

--- Deactivate a sequence: hide and unregister its button, delete macro stub.
--- @param name string Sequence name
function Engine:DeactivateSequence(name)
    if not name or not self.sequences[name] then
        return
    end

    local function doDeactivate()
        -- Clear live override binding (keeps saved data for re-activation)
        if KM then
            KM:UnbindSequence(name)
        end

        local entry = self.sequences[name]
        if entry and entry.button then
            entry.button:SetAttribute("type", nil)
            entry.button:Hide()
            entry.button:SetParent(nil)
        end
        self.sequences[name] = nil

        -- Remove from SavedVariables
        if _G.GRIP_EMS_CHAR and GRIP_EMS_CHAR.sequences then
            GRIP_EMS_CHAR.sequences[name] = nil
        end

        MM:DeleteStub(name)
        GRIPEMS:Debug(string.format(L["GEMS_SEQ_DEACTIVATED"], name))

        -- Notify listeners
        if GRIPEMS.Fire then
            GRIPEMS:Fire("SEQUENCE_DELETED", name)
        end
    end

    GRIPEMS.OOCQueue:Add(doDeactivate, D.OOC_OP_DEACTIVATE, name)
end

--- Toggle the disabled state of a sequence.
--- Disabled sequences remain in the list but have no button or keybind.
--- @param name string Sequence name
function Engine:ToggleSequenceDisabled(name)
    local entry = self.sequences[name]
    if not entry or not entry.data then
        return
    end

    if entry.data.disabled then
        -- Re-enable: remove dormant registration, activate fully
        entry.data.disabled = nil
        self.sequences[name] = nil
        self:ActivateSequence(name, entry.data)
    else
        -- Disable: tear down button but keep registered as dormant
        entry.data.disabled = true
        local data = entry.data
        local function doDisable()
            if KM then
                KM:UnbindSequence(name)
            end
            if entry.button then
                entry.button:SetAttribute("type", nil)
                entry.button:Hide()
                entry.button:SetParent(nil)
            end
            entry.button = nil
            MM:DeleteStub(name)
            if GRIPEMS.Fire then
                GRIPEMS:Fire("SEQUENCE_UPDATED", name, data)
            end
        end
        GRIPEMS.OOCQueue:Add(doDisable, D.OOC_OP_DEACTIVATE, name)
    end

    -- Persist disabled state to SavedVariables
    if _G.GRIP_EMS_CHAR and GRIP_EMS_CHAR.sequences and GRIP_EMS_CHAR.sequences[name] then
        GRIP_EMS_CHAR.sequences[name].disabled = entry.data.disabled
    end
end

--- Reset a sequence's step counter to 1. OOC-only from insecure code.
--- @param name string Sequence name
function Engine:ResetStep(name)
    if not name or not self.sequences[name] then
        return
    end
    local btn = self.sequences[name].button
    if not btn then
        return
    end

    local function doReset()
        btn:SetAttribute("step", 1)
        GRIPEMS:Debug(string.format(L["GEMS_STEP_RESET"], name))
    end

    GRIPEMS.OOCQueue:Add(doReset, D.OOC_OP_RESET, name)
end

--- Get the current step index for a sequence.
--- @param name string Sequence name
--- @return number|nil Current step (1-based), or nil if sequence not found
function Engine:GetCurrentStep(name)
    if not name or not self.sequences[name] then
        return nil
    end
    local btn = self.sequences[name].button
    if not btn then
        return nil
    end
    return tonumber(btn:GetAttribute("step")) or 1
end

--- Manually advance a sequence's step (for /gems test debugging).
--- Wraps around to step 1 after the last step. OOC-only.
--- @param name string Sequence name
function Engine:AdvanceStep(name)
    if not name or not self.sequences[name] then
        return
    end
    local entry = self.sequences[name]
    local btn = entry.button
    if not btn then
        return
    end

    local function doAdvance()
        local step = tonumber(btn:GetAttribute("step")) or 1
        local ver = Engine:GetActiveVersion(entry.data)
        local numSteps = ver and #ver.steps or 0
        if numSteps == 0 then
            return
        end
        step = step % numSteps + 1
        btn:SetAttribute("step", step)
        GRIPEMS:Debug(string.format(L["GEMS_STEP_ADVANCED"], name, step, numSteps))
    end

    GRIPEMS.OOCQueue:Add(doAdvance, D.OOC_OP_GENERIC, name)
end

--- Update the macro stub icon based on the button's current step.
--- Called from the restricted environment via CallMethod('UpdateIcon').
--- This is an insecure method that queues an OOC icon update.
--- SC:ParseSpellFromMacrotext and SC:GetIcon are pure Lua lookups --
--- they work fine from insecure code. MM:UpdateIcon uses OOCQueue.
--- @param btn frame The SecureActionButton
function Engine:UpdateButtonIcon(btn)
    if not btn or not btn.seqName then
        return
    end
    local seqData = btn.seqData
    if not seqData then
        return
    end

    -- Icon update: OOC only (MM:UpdateIcon uses SetAttribute)
    if not GRIPEMS.OOCQueue.IsRestricted() then
        if seqData.autoIcon == false and type(seqData.icon) == "number" then
            MM:UpdateIcon(btn.seqName, seqData.icon)
        else
            local step = tonumber(btn:GetAttribute("step")) or 1
            local ver = self:GetActiveVersion(seqData)
            local steps = ver and ver.steps
            if steps and #steps > 0 then
                local stepText = steps[step] or steps[1]
                if stepText then
                    local SC = GRIPEMS.SpellCache
                    if SC then
                        local spellName = SC:ParseSpellFromMacrotext(stepText)
                        if spellName then
                            local iconID = SC:GetIcon(spellName)
                            if iconID then
                                MM:UpdateIcon(btn.seqName, iconID)
                            end
                        end
                    end
                end
            end
        end
    end

    -- Step-advanced callback: ALWAYS fire (pure Lua, safe in combat)
    if GRIPEMS.Fire then
        local step = tonumber(btn:GetAttribute("step")) or 1
        local ver = self:GetActiveVersion(seqData)
        local numSteps = ver and #ver.steps or 0
        GRIPEMS:Fire("SEQUENCE_STEP_ADVANCED", btn.seqName, step, numSteps)
    end
end

--- Return a summary table of all active sequences for status display.
--- @return table Array of { name, stepCount, currentStep, stepFunction }
function Engine:GetSequenceList()
    local list = {}
    for name, entry in pairs(self.sequences) do
        local btn = entry.button
        local currentStep = 1
        if btn then
            currentStep = tonumber(btn:GetAttribute("step")) or 1
        end
        local ver = self:GetActiveVersion(entry.data)
        table.insert(list, {
            name = name,
            stepCount = ver and #ver.steps or 0,
            currentStep = currentStep,
            stepFunction = ver and ver.stepFunction or D.STEP_SEQUENTIAL,
        })
    end
    table.sort(list, function(a, b)
        return a.name < b.name
    end)
    return list
end

--- Return the count of active sequences.
--- @return number
function Engine:GetActiveCount()
    local count = 0
    for _ in pairs(self.sequences) do
        count = count + 1
    end
    return count
end

function Engine:GetButtonPressRate()
    local now = GetTime()
    local bpt = self._buttonPressTimes
    -- Prune stale entries
    while #bpt > 0 and (now - bpt[1]) > self.BUTTON_PRESS_WINDOW do
        table.remove(bpt, 1)
    end
    if #bpt < 2 then
        return 0
    end
    local span = bpt[#bpt] - bpt[1]
    if span <= 0 then
        return 0
    end
    return (#bpt - 1) / span
end

--- Restore all sequences from SavedVariables after login/reload.
--- Called from PLAYER_ENTERING_WORLD before keybind loading.
function Engine:RestoreSavedSequences()
    if not _G.GRIP_EMS_CHAR or not GRIP_EMS_CHAR.sequences then
        return
    end
    self.corruptSequences = {}
    local playerClassID = select(3, UnitClass("player")) or 0
    local dormantCount = 0
    local count = 0
    for name, seqData in pairs(GRIP_EMS_CHAR.sequences) do
        if type(seqData) == "table" then
            -- Validate structure before activation
            local valid = true
            local errorMsg = nil
            if type(seqData.versions) ~= "table" or #seqData.versions == 0 then
                valid = false
                errorMsg = "Missing or empty versions table"
            else
                local hasSteps = false
                for _, ver in ipairs(seqData.versions) do
                    if type(ver) == "table" and type(ver.steps) == "table" then
                        hasSteps = true
                        break
                    end
                end
                if not hasSteps then
                    valid = false
                    errorMsg = "No version contains a steps table"
                end
            end

            if valid then
                -- Migrate and activate inside pcall for safety
                local ok, err = pcall(function()
                    seqData = self:MigrateSequenceFormat(seqData)
                    GRIP_EMS_CHAR.sequences[name] = seqData
                    local ver = self:GetActiveVersion(seqData)
                    if ver then
                        local seqClass = seqData.classID or 0
                        if seqClass == playerClassID or seqClass == 0 then
                            self:ActivateSequence(name, seqData)
                            count = count + 1
                        else
                            self:RegisterSequenceOnly(name, seqData)
                            dormantCount = dormantCount + 1
                        end
                    end
                end)
                if not ok then
                    table.insert(self.corruptSequences, {
                        name = name,
                        data = seqData,
                        error = tostring(err),
                    })
                end
            else
                table.insert(self.corruptSequences, {
                    name = name,
                    data = seqData,
                    error = errorMsg,
                })
            end
        end
    end
    if count > 0 then
        GRIPEMS:Print(string.format(L["GEMS_RESTORED"], count))
    end
    if dormantCount > 0 then
        GRIPEMS:Debug(string.format(L["GEMS_DORMANT_LOADED"], dormantCount))
    end
    -- Schedule corrupt handler after login completes (UI must be ready)
    if #self.corruptSequences > 0 then
        C_Timer.After(2, function()
            Engine:ProcessNextCorrupt()
        end)
    end
end

--- Update sequence data in-place. If stepFunction changed, deactivate+reactivate.
--- @param name string Sequence name
--- @param seqData table Updated sequence data
function Engine:UpdateSequenceData(name, seqData)
    if not name or not seqData then
        return
    end
    local entry = self.sequences[name]
    if not entry then
        return
    end

    if not entry.button then
        -- Dormant sequence: activate it first (user is editing)
        self:ActivateDormantSequence(name)
        entry = self.sequences[name]
        if not entry or not entry.button then
            return
        end
    end

    seqData.updatedAt = time()

    -- Tag all versions with spell IDs for locale protection (Phase 2a)
    local SC = GRIPEMS.SpellCache
    if SC and SC.ready then
        for _, version in ipairs(seqData.versions or {}) do
            version.taggedSteps = SC:TagSteps(version.steps or {})
            version.taggedKeyPress = SC:TranslateMacrotext(version.keyPress or "", "toIDs")
            version.taggedKeyRelease = SC:TranslateMacrotext(version.keyRelease or "", "toIDs")
            version.stepsLocale = GetLocale()
        end
    end

    -- Check if step count changed (requires WrapScript rebuild for new Execute data)
    local oldVer = self:GetActiveVersion(entry.data)
    local newVer = self:GetActiveVersion(seqData)
    local oldStepCount = oldVer and #oldVer.steps or 0
    local newStepCount = newVer and #newVer.steps or 0
    local stepsChanged = oldStepCount ~= newStepCount

    -- Check if stepFunction changed (requires engine rebuild)
    local oldStepFunc = oldVer and oldVer.stepFunction
    local newStepFunc = newVer and newVer.stepFunction

    if oldStepFunc ~= newStepFunc or stepsChanged then
        -- Full rebuild required
        self:DeactivateSequence(name)
        self:ActivateSequence(name, seqData)
    else
        -- In-place update (no engine rebuild needed)
        entry.data = seqData
        local btn = entry.button
        if btn and not GRIPEMS.OOCQueue.IsRestricted() then
            local resetTimer = newVer and newVer.resetTimer or 0
            btn:SetAttribute("resetTimer", resetTimer)
            -- Refresh per-sequence reset modifier attributes
            local seqResetMods = newVer and newVer.resetModifiers
            local globalMods = GRIPEMS.Settings:GetResetModifiers()
            local resetMods
            if seqResetMods then
                resetMods = {}
                for mod, default in pairs(globalMods) do
                    if seqResetMods[mod] ~= nil then
                        resetMods[mod] = seqResetMods[mod]
                    else
                        resetMods[mod] = default
                    end
                end
            else
                resetMods = globalMods
            end
            for mod, enabled in pairs(resetMods) do
                btn:SetAttribute("resetMod_" .. mod, enabled and "1" or nil)
            end
        end
        if _G.GRIP_EMS_CHAR and GRIP_EMS_CHAR.sequences then
            GRIP_EMS_CHAR.sequences[name] = seqData
        end
        -- Recompile step data into the restricted environment so edited step
        -- text takes effect immediately, without requiring a relog. (BUG-029 Issue B)
        self:RecompileSequence(name)
    end

    if GRIPEMS.Fire then
        GRIPEMS:Fire("SEQUENCE_UPDATED", name, seqData)
    end
end

--- Recompile a sequence's steps after a variable value changed.
--- Re-runs CompileSteps + BuildExecuteString + btn:Execute() to reload
--- step data with updated variable values. Must go through OOCQueue if in combat.
--- @param name string Sequence name
function Engine:RecompileSequence(name)
    if not name then
        return
    end
    local entry = self.sequences[name]
    if not entry or not entry.data or not entry.button then
        return
    end

    local seqData = entry.data
    local ver = self:GetActiveVersion(seqData)
    if not ver then
        return
    end
    -- Action tree compilation: flatten actions to steps before runtime use
    if ver.actions and #ver.actions > 0 then
        ver.steps = GRIPEMS.ActionCompiler.CompileActions(ver.actions, self)
    end
    if not ver.steps or #ver.steps == 0 then
        return
    end

    GRIPEMS:Debug(string.format(L["GEMS_VAR_RECOMPILE"], name))

    local function doRecompile()
        local btn = entry.button
        if not btn then
            return
        end

        local stepsToLoad = ver.steps
        local kp = ver.keyPress or ""
        local kr = ver.keyRelease or ""
        -- Priority/ReversePriority: pre-expand into flat single-step arrays
        local compiledSteps
        if ver.stepFunction == D.STEP_PRIORITY then
            compiledSteps = ResolveFitAndExpand(self, stepsToLoad, kp, kr, function(r)
                return SF:ExpandPriority(r)
            end)
        elseif ver.stepFunction == D.STEP_REVERSE_PRIORITY then
            compiledSteps = ResolveFitAndExpand(self, stepsToLoad, kp, kr, function(r)
                return SF:ExpandReversePriority(r)
            end)
        else
            compiledSteps = self:CompileSteps(stepsToLoad, kp, kr)
        end

        local execStr = self:BuildExecuteString(compiledSteps)
        local ok, err = pcall(btn.Execute, btn, execStr)
        if not ok then
            GRIPEMS:Debug("Execute failed: " .. tostring(err))
        end

        -- Update macro stub body with current keyPress/keyRelease
        MM:UpdateStubBody(name, kp, kr)
    end

    GRIPEMS.OOCQueue:Add(doRecompile, D.OOC_OP_RECOMPILE, name)
end

--- Heal sequence steps after a WoW client locale change.
--- Checks each version's stepsLocale against GetLocale(). If mismatched
--- and taggedSteps exist, translates tagged spell IDs back to the current
--- locale's spell names. Recompiles any healed sequences.
--- Called on SPELL_CACHE_REFRESHED (registered at file load).
function Engine:HealLocaleSteps()
    local SC = GRIPEMS.SpellCache
    if not SC or not SC.ready then
        return
    end
    if not _G.GRIP_EMS_CHAR or not GRIP_EMS_CHAR.sequences then
        return
    end

    local currentLocale = GetLocale()
    local healed = 0

    for name, seqData in pairs(GRIP_EMS_CHAR.sequences) do
        if type(seqData) == "table" then
            local dirty = false
            for _, version in ipairs(seqData.versions or {}) do
                if version.stepsLocale and version.stepsLocale ~= currentLocale and version.taggedSteps then
                    -- Preserve original author text before healing
                    if not version.stepsOriginal then
                        local orig = {}
                        for si, s in ipairs(version.steps) do
                            orig[si] = s
                        end
                        version.stepsOriginal = orig
                    end
                    -- Heal steps from tagged spell ID data
                    for i, taggedStep in ipairs(version.taggedSteps) do
                        version.steps[i] = SC:TranslateMacrotext(taggedStep, "toNames")
                    end
                    -- Heal keyPress
                    if version.taggedKeyPress and version.taggedKeyPress ~= "" then
                        version.keyPress = SC:TranslateMacrotext(version.taggedKeyPress, "toNames")
                    end
                    -- Heal keyRelease
                    if version.taggedKeyRelease and version.taggedKeyRelease ~= "" then
                        version.keyRelease = SC:TranslateMacrotext(version.taggedKeyRelease, "toNames")
                    end
                    -- Re-tag with new locale names so taggedSteps stays current
                    version.taggedSteps = SC:TagSteps(version.steps)
                    if version.keyPress and version.keyPress ~= "" then
                        version.taggedKeyPress = SC:TranslateMacrotext(version.keyPress, "toIDs")
                    end
                    if version.keyRelease and version.keyRelease ~= "" then
                        version.taggedKeyRelease = SC:TranslateMacrotext(version.keyRelease, "toIDs")
                    end
                    version.stepsLocale = currentLocale
                    dirty = true
                end
            end
            if dirty then
                self:RecompileSequence(name)
                healed = healed + 1
            end
        end
    end

    if healed > 0 then
        GRIPEMS:Print(string.format("Locale change detected: healed %d sequence(s) from %s.", healed, currentLocale))
    end
end

--- Create a copy of an existing sequence under a new name.
--- @param sourceName string Name of the sequence to copy
--- @param newName string Name for the duplicate
--- @return boolean success
--- @return string|nil error Error message on failure
function Engine:DuplicateSequence(sourceName, newName)
    if not sourceName or not newName then
        return false, "Missing source or target name"
    end
    if newName == "" then
        return false, "New name cannot be empty"
    end
    if self.sequences[newName] then
        return false, string.format("Sequence '%s' already exists", newName)
    end

    local sourceEntry = self.sequences[sourceName]
    if not sourceEntry or not sourceEntry.data then
        return false, string.format("Source sequence '%s' not found", sourceName)
    end

    local src = sourceEntry.data

    -- Deep-copy the seqData (manually copy each field + all versions)
    local newData = {
        name = newName,
        icon = src.icon or D.QUESTION_MARK_ICON,
        autoIcon = src.autoIcon,
        defaultVersion = src.defaultVersion or 1,
        contextOverrides = {},
        versions = {},
        author = src.author or "",
        version = src.version or "1",
        description = src.description or "",
        classID = src.classID or 0,
        specID = src.specID,
        createdAt = time(),
        updatedAt = time(),
    }
    -- Deep copy all versions
    if src.versions then
        for i, ver in ipairs(src.versions) do
            newData.versions[i] = D.CopyVersion(ver)
        end
    end
    -- Deep copy contextOverrides
    if src.contextOverrides then
        for k, v in pairs(src.contextOverrides) do
            newData.contextOverrides[k] = v
        end
    end

    self:ActivateSequence(newName, newData)
    return true
end

---------------------------------------------------------------------------
-- Corrupt Sequence Recovery (StaticPopup chain)
---------------------------------------------------------------------------

-- Counters for summary message after all corrupt sequences are processed
local corruptDeleted = 0
local corruptSkipped = 0
local corruptExported = 0

--- Recursive table-to-string serializer for Export Raw.
--- Defensive: wraps top-level call in pcall. Handles string, number,
--- boolean, and nested table values. Non-serializable types show as
--- a placeholder string.
--- @param tbl table The table to serialize
--- @return string Readable Lua table dump
local function TableToString(tbl)
    local ok, result = pcall(function()
        local function serialize(val, indent)
            local pad = string.rep("  ", indent)
            local t = type(val)
            if t == "string" then
                return string.format("%q", val)
            elseif t == "number" or t == "boolean" then
                return tostring(val)
            elseif t == "table" then
                local parts = {}
                parts[#parts + 1] = "{"
                local innerPad = string.rep("  ", indent + 1)
                -- Array part
                local arrayLen = #val
                for i = 1, arrayLen do
                    parts[#parts + 1] = innerPad .. "[" .. i .. "] = " .. serialize(val[i], indent + 1) .. ","
                end
                -- Hash part
                for k, v in pairs(val) do
                    local skip = false
                    if type(k) == "number" and k >= 1 and k <= arrayLen and k == math.floor(k) then
                        skip = true
                    end
                    if not skip then
                        local keyStr
                        if type(k) == "string" then
                            keyStr = '["' .. k .. '"]'
                        else
                            keyStr = "[" .. tostring(k) .. "]"
                        end
                        parts[#parts + 1] = innerPad .. keyStr .. " = " .. serialize(v, indent + 1) .. ","
                    end
                end
                parts[#parts + 1] = pad .. "}"
                return table.concat(parts, "\n")
            else
                return '"<' .. t .. '>"'
            end
        end
        return serialize(tbl, 0)
    end)
    if ok then
        return result
    else
        return "-- Serialization failed: " .. tostring(result)
    end
end

--- Process the next corrupt sequence in the queue.
--- Shows a StaticPopup for user action or prints summary when done.
function Engine:ProcessNextCorrupt()
    if #self.corruptSequences == 0 then
        -- All processed, print summary
        if (corruptDeleted + corruptSkipped + corruptExported) > 0 then
            GRIPEMS:Print(string.format(L["GEMS_CORRUPT_SUMMARY"], corruptDeleted, corruptSkipped, corruptExported))
        end
        corruptDeleted = 0
        corruptSkipped = 0
        corruptExported = 0
        return
    end

    local entry = self.corruptSequences[1]
    local popupText = string.format(L["GEMS_CORRUPT_TEXT"], entry.name, entry.error)
    StaticPopup_Show("GRIPEMS_CORRUPT_SEQUENCE", popupText)
end

StaticPopupDialogs["GRIPEMS_CORRUPT_SEQUENCE"] = {
    text = "%s",
    button1 = L["GEMS_CORRUPT_DELETE"],
    button2 = L["GEMS_CORRUPT_SKIP"],
    button3 = L["GEMS_CORRUPT_EXPORT"],
    OnAccept = function()
        -- Delete: remove from SavedVariables permanently
        local entry = table.remove(Engine.corruptSequences, 1)
        if entry and _G.GRIP_EMS_CHAR and GRIP_EMS_CHAR.sequences then
            GRIP_EMS_CHAR.sequences[entry.name] = nil
        end
        corruptDeleted = corruptDeleted + 1
        Engine:ProcessNextCorrupt()
    end,
    OnCancel = function()
        -- Skip: leave in SavedVariables, user can fix later
        table.remove(Engine.corruptSequences, 1)
        corruptSkipped = corruptSkipped + 1
        Engine:ProcessNextCorrupt()
    end,
    OnAlt = function()
        -- Export Raw: serialize table and show in ExportFrame
        local entry = table.remove(Engine.corruptSequences, 1)
        if entry then
            local rawString = TableToString(entry.data)
            local EF = GRIPEMS.ExportFrame
            if EF and EF.Show then
                EF:Show(nil, rawString)
            end
        end
        corruptExported = corruptExported + 1
        Engine:ProcessNextCorrupt()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = false,
    preferredIndex = 3,
}

-- Event handling for reset conditions (named for /reload reuse)
local engineFrame = _G["GRIPEMS_EngineEvent"] or CreateFrame("Frame", "GRIPEMS_EngineEvent")
engineFrame:UnregisterAllEvents()
engineFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
engineFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
engineFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
engineFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
engineFrame:RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED")
engineFrame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
engineFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
engineFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
engineFrame:RegisterEvent("CHALLENGE_MODE_START")
engineFrame:RegisterEvent("CHALLENGE_MODE_COMPLETED")
engineFrame:RegisterEvent("UNIT_ENTERED_VEHICLE")
engineFrame:RegisterEvent("UNIT_EXITED_VEHICLE")
engineFrame:RegisterEvent("PET_BATTLE_OPENING_START")
engineFrame:RegisterEvent("PET_BATTLE_OPENING_DONE")
engineFrame:RegisterEvent("PET_BATTLE_CLOSE")
engineFrame:RegisterEvent("UPDATE_BONUS_ACTIONBAR")
engineFrame:RegisterEvent("UPDATE_VEHICLE_ACTIONBAR")

engineFrame:SetScript("OnEvent", function(_, event, ...)
    if event == "PLAYER_REGEN_ENABLED" then
        -- Reset step on sequences with resetOnCombat=true
        for name, entry in pairs(Engine.sequences) do
            local ver = Engine:GetActiveVersion(entry.data)
            if ver and ver.resetOnCombat then
                local btn = entry.button
                if btn then
                    btn:SetAttribute("step", 1)
                    GRIPEMS:Debug(string.format(L["GEMS_COMBAT_RESET"], name))
                end
            end
        end
    elseif event == "PLAYER_TARGET_CHANGED" then
        -- Reset step on target change, OOC only (Phase 1 limitation)
        if GRIPEMS.OOCQueue.IsRestricted() then
            return
        end
        for name, entry in pairs(Engine.sequences) do
            local ver = Engine:GetActiveVersion(entry.data)
            if ver and ver.resetOnTarget then
                local btn = entry.button
                if btn then
                    btn:SetAttribute("step", 1)
                    GRIPEMS:Debug(string.format(L["GEMS_TARGET_RESET"], name))
                end
            end
        end
    elseif event == "PLAYER_EQUIPMENT_CHANGED" then
        local slot = ...
        -- Reset step on gear change, OOC only
        if GRIPEMS.OOCQueue.IsRestricted() then
            return
        end
        for name, entry in pairs(Engine.sequences) do
            local ver = Engine:GetActiveVersion(entry.data)
            if ver and ver.resetOnGear then
                local btn = entry.button
                if btn then
                    local wasStep = tonumber(btn:GetAttribute("step")) or 1
                    btn:SetAttribute("step", 1)
                    GRIPEMS:Debug(string.format(L["GEMS_GEAR_RESET"], name, wasStep, slot))
                end
            end
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        -- Detect context before restoring sequences (so GetActiveVersion picks
        -- the correct version on first activation)
        Engine:UpdateContext()
        -- Scan for existing GRIP-EMS macro stubs on login
        MM:ScanExisting()
        Engine:RestoreSavedSequences()
        -- All buttons created synchronously (OOCQueue runs immediately OOC).
        -- Apply all keybinds in one pass (BindIfConfigured is skipped during
        -- init via _initialLoadComplete guard, so this is the sole bind point).
        if KM and not GRIPEMS.OOCQueue.IsRestricted() then
            KM:LoadKeybinds()
        end
        Engine._initialLoadComplete = true

        -- Track which classes have been fully activated
        GRIPEMS.loadedClasses = GRIPEMS.loadedClasses or {}
        GRIPEMS.loadedClasses[select(3, UnitClass("player")) or 0] = true

        -- Initialize bar integration after sequences are restored
        C_Timer.After(1, function()
            if GRIPEMS.BarIntegration then
                GRIPEMS.BarIntegration:Init()
            end
        end)

        -- Register for variable changes to recompile affected sequences
        if GRIPEMS.RegisterCallback then
            GRIPEMS.RegisterCallback(Engine, "VARIABLE_UPDATED", function(_, _, varName)
                if not varName then
                    return
                end
                local VS = GRIPEMS.VariableStore
                if not VS then
                    return
                end
                local refs = VS:GetReferences(varName)
                for _, seqName in ipairs(refs) do
                    if Engine.sequences[seqName] then
                        Engine:RecompileSequence(seqName)
                    end
                end
            end)
        end
    elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
        -- Only react to player's own spec change, not group members
        local unit = ...
        if unit == "player" then
            -- Reset step on spec change for sequences with resetOnSpec
            for name, entry in pairs(Engine.sequences) do
                local ver = Engine:GetActiveVersion(entry.data)
                if ver and ver.resetOnSpec then
                    local btn = entry.button
                    if btn then
                        local wasStep = tonumber(btn:GetAttribute("step")) or 1
                        btn:SetAttribute("step", 1)
                        GRIPEMS:Debug(string.format(L["GEMS_SPEC_RESET"], name, wasStep))
                    end
                end
            end
            -- Reload keybinds for new spec (debounced with ACTIVE_TALENT_GROUP_CHANGED)
            if KM then
                KM:ScheduleLoadKeybinds()
            end
        end
    elseif event == "ACTIVE_TALENT_GROUP_CHANGED" then
        -- Backup event for spec changes (debounced with PLAYER_SPECIALIZATION_CHANGED)
        if KM then
            KM:ScheduleLoadKeybinds()
        end
    elseif event == "ZONE_CHANGED_NEW_AREA" then
        Engine:UpdateContext()
    elseif event == "GROUP_ROSTER_UPDATE" then
        Engine:UpdateContext()
    elseif event == "CHALLENGE_MODE_START" then
        Engine:UpdateContext()
    elseif event == "CHALLENGE_MODE_COMPLETED" then
        Engine:UpdateContext()
    elseif event == "UNIT_ENTERED_VEHICLE" then
        local unit = ...
        if unit == "player" and KM then
            KM:SuspendKeybinds("vehicle")
            if GRIPEMS.VehicleKeybinds then
                GRIPEMS.VehicleKeybinds:Activate()
            end
        end
    elseif event == "UNIT_EXITED_VEHICLE" then
        local unit = ...
        if unit == "player" and KM then
            if GRIPEMS.VehicleKeybinds then
                GRIPEMS.VehicleKeybinds:Deactivate()
            end
            KM:RestoreKeybinds("vehicle")
        end
    elseif event == "PET_BATTLE_OPENING_START" then
        if KM then
            KM:SuspendKeybinds("pet battle")
        end
    elseif event == "PET_BATTLE_OPENING_DONE" then
        if GRIPEMS.PetBattleButtons then
            GRIPEMS.PetBattleButtons:Activate()
        end
    elseif event == "PET_BATTLE_CLOSE" then
        if GRIPEMS.PetBattleButtons then
            GRIPEMS.PetBattleButtons:Deactivate()
        end
        if KM then
            KM:RestoreKeybinds("pet battle")
        end
    elseif event == "UPDATE_BONUS_ACTIONBAR" or event == "UPDATE_VEHICLE_ACTIONBAR" then
        -- Ignore bar-swap events during initial load (buttons may not exist yet)
        if not Engine._initialLoadComplete then
            return
        end
        -- Catches bar swaps that don't fire UNIT_ENTERED_VEHICLE
        -- (e.g., possess bar, override bar, some quest vehicles)
        if KM then
            if
                HasVehicleActionBar()
                or HasOverrideActionBar()
                or UnitHasVehicleUI("player")
                or C_PetBattles.IsInBattle()
            then
                KM:SuspendKeybinds("bar swap")
                if GRIPEMS.VehicleKeybinds then
                    GRIPEMS.VehicleKeybinds:Activate()
                end
            else
                if GRIPEMS.VehicleKeybinds then
                    GRIPEMS.VehicleKeybinds:Deactivate()
                end
                KM:RestoreKeybinds("bar swap")
            end
        end
    end
end)

-- Phase 2c: heal locale-mismatched sequences after every spell cache refresh
if GRIPEMS.RegisterCallback then
    GRIPEMS.RegisterCallback(Engine, "SPELL_CACHE_REFRESHED", function()
        Engine:HealLocaleSteps()
        local VS = GRIPEMS.VariableStore
        if VS and VS.HealLocaleVariables then
            VS:HealLocaleVariables()
        end
    end)
end

-- Update macro reset modifier attributes on all active buttons when setting changes.
-- OOC-gated: SetAttribute is protected and cannot run during combat.
if GRIPEMS.RegisterCallback then
    GRIPEMS.RegisterCallback(Engine, "SETTING_CHANGED", function(_, _, key)
        if key ~= "macroResetModifiers" then
            return
        end
        local function doUpdate()
            local globalMods = GRIPEMS.Settings:GetResetModifiers()
            for _, entry in pairs(Engine.sequences) do
                local btn = entry.button
                if btn then
                    local activeVer = Engine:GetActiveVersion(entry.data)
                    local seqResetMods = activeVer and activeVer.resetModifiers
                    local resetMods
                    if seqResetMods then
                        resetMods = {}
                        for mod, default in pairs(globalMods) do
                            if seqResetMods[mod] ~= nil then
                                resetMods[mod] = seqResetMods[mod]
                            else
                                resetMods[mod] = default
                            end
                        end
                    else
                        resetMods = globalMods
                    end
                    for mod, enabled in pairs(resetMods) do
                        btn:SetAttribute("resetMod_" .. mod, enabled and "1" or nil)
                    end
                end
            end
        end
        if GRIPEMS.OOCQueue.IsRestricted() then
            GRIPEMS.OOCQueue:Add(doUpdate, D.OOC_OP_SETTING)
        else
            doUpdate()
        end
    end)
end
