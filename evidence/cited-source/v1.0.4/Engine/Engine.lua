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
    sequences = {},  -- name -> { button, data }
    currentContext = "none",  -- active content context (T2-1)
}
local Engine = GRIPEMS.Engine

--- Sanitize a sequence name for use as a global frame name.
--- Strips non-alphanumeric characters and replaces spaces with underscores.
--- @param name string Raw sequence name
--- @return string Sanitized name safe for global frame names
function Engine:SanitizeName(name)
    if not name then return "Unknown" end
    local sanitized = name:gsub("%s+", "_"):gsub("[^%w_]", "")
    if sanitized == "" then sanitized = "Unknown" end
    return sanitized
end

--- Substitute ~varname~ references in a macrotext string with evaluated values.
--- Variables are resolved via VariableStore:Evaluate(). Failed evaluations
--- are replaced with empty string and logged.
--- @param text string Raw macrotext with potential ~varname~ references
--- @return string Resolved macrotext with variables substituted
function Engine:SubstituteVariables(text)
    if not text or text == "" then return text end
    local VS = GRIPEMS.VariableStore
    if not VS then return text end

    return text:gsub(D.VAR_PATTERN, function(varName)
        local value, err = VS:Evaluate(varName)
        if value == nil then
            if err and err ~= "Not found" then
                GRIPEMS:Debug(string.format(L["GEMS_VAR_EVAL_ERROR"], varName,
                    tostring(err)))
            end
            return ""
        end
        return tostring(value)
    end)
end

--- Compile raw string steps into attribute table format.
--- Performs variable substitution (~varname~) before compiling.
--- Wraps each step with KeyPress/KeyRelease for Sequential/Random modes.
--- @param steps table Array of macro text strings
--- @param keyPress string|nil KeyPress block to prepend to each step
--- @param keyRelease string|nil KeyRelease block to append to each step
--- @return table Array of attribute tables (e.g. {type="macro", macrotext="..."})
function Engine:CompileSteps(steps, keyPress, keyRelease)
    if not steps then return {} end
    local compiled = {}
    for i, stepText in ipairs(steps) do
        local resolved = self:SubstituteVariables(tostring(stepText))
        -- Wrap with KeyPress/KeyRelease
        local parts = {}
        if keyPress and keyPress ~= "" then
            parts[#parts + 1] = keyPress
        end
        parts[#parts + 1] = resolved
        if keyRelease and keyRelease ~= "" then
            parts[#parts + 1] = keyRelease
        end
        local wrapped = table.concat(parts, "\n")
        compiled[i] = {
            type = D.ATTR_TYPE_MACRO,
            macrotext = wrapped,
        }
    end
    return compiled
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
                parts[#parts + 1] = "steps[" .. i .. "][\"" .. tostring(k)
                    .. "\"] = [=======[" .. tostring(v) .. "]=======]\n"
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
    if not seqData or not seqData.versions then return nil end

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
    if not seqData then return seqData end
    -- Already versioned: has non-empty versions table
    if seqData.versions and type(seqData.versions) == "table"
        and next(seqData.versions) then
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
        if ctx then return ctx end
        if instanceType == "party" then return "Dungeon" end
        return "Raid"
    end

    if instanceType == "scenario" then
        if difficultyID == 208 then return "Delves" end
        return "Scenario"
    end

    if D.INSTANCE_TYPE_CONTEXT[instanceType] then
        return D.INSTANCE_TYPE_CONTEXT[instanceType]
    end

    if instanceType == "none" then
        if IsInGroup() then return "Party" end
        return "Solo"
    end

    return D.CONTEXT_NONE
end

--- Check for context changes and reload affected sequences.
--- Called on zone change, group roster update, and login.
function Engine:UpdateContext()
    local newContext = self:DetectContext()
    if newContext == self.currentContext then return end

    local oldContext = self.currentContext
    self.currentContext = newContext
    GRIPEMS:Debug(string.format(L["GEMS_CONTEXT_CHANGED"],
        D.CONTEXT_LABELS[newContext] or newContext))
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
        if seqData and seqData.contextOverrides
                and next(seqData.contextOverrides) then
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
                    GRIPEMS.OOCQueue:Add(doReload)
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
    if not name or not sequenceData then return end
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
        local btn = CreateFrame("Button", globalName, nil,
            "SecureActionButtonTemplate,SecureHandlerBaseTemplate")
        btn:Show()
        btn:SetAttribute("type", D.ATTR_TYPE_MACRO)
        btn:SetAttribute("step", 1)
        local activeVer = Engine:GetActiveVersion(sequenceData)
        local resetTimer = activeVer and activeVer.resetTimer or 0
        if resetTimer > 0 then
            btn:SetAttribute("resetTimer", resetTimer)
        end
        btn:SetAttribute('_shouldReset', '0')
        btn:RegisterForClicks("AnyUp", "AnyDown")

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
        btn.PostClick = function(self)
            local now = GetTime()
            -- Reset timer check
            local resetTimer = self:GetAttribute('resetTimer') or 0
            if resetTimer > 0 then
                local lastPress = self._lastPress or 0
                if lastPress > 0 and (now - lastPress) > resetTimer then
                    if not InCombatLockdown() then
                        self:SetAttribute('_shouldReset', '1')
                    end
                end
                self._lastPress = now
            end
        end

        -- Only compile/Execute/WrapScript if we have steps to load.
        -- Empty sequences get a button (type="macro" + empty macrotext = safe
        -- no-op) but no WrapScript wiring. Steps are added via UpdateSequenceData.
        local curVer = Engine:GetActiveVersion(sequenceData)
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
                local resolved = {}
                for i, step in ipairs(stepsToLoad) do
                    resolved[i] = self:SubstituteVariables(tostring(step))
                end
                compiledSteps = SF:ExpandPriority(resolved, kp, kr)
            elseif stepFuncName == D.STEP_REVERSE_PRIORITY then
                local resolved = {}
                for i, step in ipairs(stepsToLoad) do
                    resolved[i] = self:SubstituteVariables(tostring(step))
                end
                compiledSteps = SF:ExpandReversePriority(resolved, kp, kr)
            else
                compiledSteps = self:CompileSteps(stepsToLoad, kp, kr)
            end

            -- Load step data into the restricted environment via :Execute()
            local execStr = self:BuildExecuteString(compiledSteps)
            btn:Execute(execStr)

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
        GRIPEMS:Debug(string.format(L["GEMS_SEQ_ACTIVATED"], name,
            #activeSteps))

        -- Create the macro stub so the player can drag it to the action bar
        MM:CreateStub(name)

        -- Apply keybinding if one exists for this sequence
        if KM then
            KM:BindIfConfigured(name)
        end

        -- Notify listeners
        if GRIPEMS.Fire then
            GRIPEMS:Fire("SEQUENCE_CREATED", name, sequenceData)
        end

        -- Safety-net: refresh SequenceList directly (matches delete path pattern)
        -- CallbackHandler registrations may silently fail; this ensures the list
        -- always reflects the current engine state after activation.
        local SL = GRIPEMS.SequenceList
        if SL and SL.RefreshDataProvider then
            SL:RefreshDataProvider()
        end
    end

    GRIPEMS.OOCQueue:Add(doActivate)
end

--- Deactivate a sequence: hide and unregister its button, delete macro stub.
--- @param name string Sequence name
function Engine:DeactivateSequence(name)
    if not name or not self.sequences[name] then return end

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

    GRIPEMS.OOCQueue:Add(doDeactivate)
end

--- Reset a sequence's step counter to 1. OOC-only from insecure code.
--- @param name string Sequence name
function Engine:ResetStep(name)
    if not name or not self.sequences[name] then return end
    local btn = self.sequences[name].button
    if not btn then return end

    local function doReset()
        btn:SetAttribute("step", 1)
        GRIPEMS:Debug(string.format(L["GEMS_STEP_RESET"], name))
    end

    GRIPEMS.OOCQueue:Add(doReset)
end

--- Get the current step index for a sequence.
--- @param name string Sequence name
--- @return number|nil Current step (1-based), or nil if sequence not found
function Engine:GetCurrentStep(name)
    if not name or not self.sequences[name] then return nil end
    local btn = self.sequences[name].button
    if not btn then return nil end
    return tonumber(btn:GetAttribute("step")) or 1
end

--- Manually advance a sequence's step (for /gems test debugging).
--- Wraps around to step 1 after the last step. OOC-only.
--- @param name string Sequence name
function Engine:AdvanceStep(name)
    if not name or not self.sequences[name] then return end
    local entry = self.sequences[name]
    local btn = entry.button
    if not btn then return end

    local function doAdvance()
        local step = tonumber(btn:GetAttribute("step")) or 1
        local ver = Engine:GetActiveVersion(entry.data)
        local numSteps = ver and #ver.steps or 0
        if numSteps == 0 then return end
        step = step % numSteps + 1
        btn:SetAttribute("step", step)
        GRIPEMS:Debug(string.format(L["GEMS_STEP_ADVANCED"], name, step, numSteps))
    end

    GRIPEMS.OOCQueue:Add(doAdvance)
end

--- Update the macro stub icon based on the button's current step.
--- Called from the restricted environment via CallMethod('UpdateIcon').
--- This is an insecure method that queues an OOC icon update.
--- SC:ParseSpellFromMacrotext and SC:GetIcon are pure Lua lookups --
--- they work fine from insecure code. MM:UpdateIcon uses OOCQueue.
--- @param btn frame The SecureActionButton
function Engine:UpdateButtonIcon(btn)
    if not btn or not btn.seqName then return end
    local seqData = btn.seqData
    if not seqData then return end
    if InCombatLockdown() then return end

    -- If user manually set an icon, use that
    if seqData.autoIcon == false and type(seqData.icon) == "number" then
        MM:UpdateIcon(btn.seqName, seqData.icon)
        return
    end

    -- Auto-detect from current step's macrotext
    local step = tonumber(btn:GetAttribute("step")) or 1
    local ver = self:GetActiveVersion(seqData)
    local steps = ver and ver.steps
    if not steps or #steps == 0 then return end

    local stepText = steps[step] or steps[1]
    if not stepText then return end

    local SC = GRIPEMS.SpellCache
    if not SC then return end

    local spellName = SC:ParseSpellFromMacrotext(stepText)
    if not spellName then return end

    local iconID = SC:GetIcon(spellName)
    if not iconID then return end

    MM:UpdateIcon(btn.seqName, iconID)
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
    table.sort(list, function(a, b) return a.name < b.name end)
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

--- Restore all sequences from SavedVariables after login/reload.
--- Called from PLAYER_ENTERING_WORLD before keybind loading.
function Engine:RestoreSavedSequences()
    if not _G.GRIP_EMS_CHAR or not GRIP_EMS_CHAR.sequences then return end
    local count = 0
    for name, seqData in pairs(GRIP_EMS_CHAR.sequences) do
        if type(seqData) == "table" then
            -- Migrate flat format to versioned format (T2-2a)
            seqData = self:MigrateSequenceFormat(seqData)
            GRIP_EMS_CHAR.sequences[name] = seqData
            local ver = self:GetActiveVersion(seqData)
            if ver then
                self:ActivateSequence(name, seqData)
                count = count + 1
            end
        end
    end
    if count > 0 then
        GRIPEMS:Print(string.format(L["GEMS_RESTORED"], count))
    end
end

--- Update sequence data in-place. If stepFunction changed, deactivate+reactivate.
--- @param name string Sequence name
--- @param seqData table Updated sequence data
function Engine:UpdateSequenceData(name, seqData)
    if not name or not seqData then return end
    local entry = self.sequences[name]
    if not entry then return end

    seqData.updatedAt = time()

    -- Check if step count crossed the 0 boundary (requires WrapScript rebuild)
    local oldVer = self:GetActiveVersion(entry.data)
    local newVer = self:GetActiveVersion(seqData)
    local oldStepCount = oldVer and #oldVer.steps or 0
    local newStepCount = newVer and #newVer.steps or 0
    local stepsChanged = (oldStepCount == 0 and newStepCount > 0)
        or (oldStepCount > 0 and newStepCount == 0)

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
        if btn and not InCombatLockdown() then
            local resetTimer = newVer and newVer.resetTimer or 0
            btn:SetAttribute("resetTimer", resetTimer)
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
    if not name then return end
    local entry = self.sequences[name]
    if not entry or not entry.data or not entry.button then return end

    local seqData = entry.data
    local ver = self:GetActiveVersion(seqData)
    if not ver or not ver.steps or #ver.steps == 0 then return end

    GRIPEMS:Debug(string.format(L["GEMS_VAR_RECOMPILE"], name))

    local function doRecompile()
        local btn = entry.button
        if not btn then return end

        local stepsToLoad = ver.steps
        local kp = ver.keyPress or ""
        local kr = ver.keyRelease or ""
        -- Priority/ReversePriority: pre-expand into flat single-step arrays
        if ver.stepFunction == D.STEP_PRIORITY then
            local resolved = {}
            for i, step in ipairs(stepsToLoad) do
                resolved[i] = self:SubstituteVariables(tostring(step))
            end
            local compiledSteps = SF:ExpandPriority(resolved, kp, kr)
            local execStr = self:BuildExecuteString(compiledSteps)
            btn:Execute(execStr)
        elseif ver.stepFunction == D.STEP_REVERSE_PRIORITY then
            local resolved = {}
            for i, step in ipairs(stepsToLoad) do
                resolved[i] = self:SubstituteVariables(tostring(step))
            end
            local compiledSteps = SF:ExpandReversePriority(resolved, kp, kr)
            local execStr = self:BuildExecuteString(compiledSteps)
            btn:Execute(execStr)
        else
            local compiledSteps = self:CompileSteps(stepsToLoad, kp, kr)
            local execStr = self:BuildExecuteString(compiledSteps)
            btn:Execute(execStr)
        end
    end

    GRIPEMS.OOCQueue:Add(doRecompile)
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
            newData.versions[i] = {
                stepFunction = ver.stepFunction,
                steps = {},
                keyPress = ver.keyPress or "",
                keyRelease = ver.keyRelease or "",
                resetOnCombat = ver.resetOnCombat,
                resetOnTarget = ver.resetOnTarget,
                resetOnGear = ver.resetOnGear,
                resetOnSpec = ver.resetOnSpec,
                resetTimer = ver.resetTimer,
            }
            for j, step in ipairs(ver.steps) do
                newData.versions[i].steps[j] = step
            end
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

-- Event handling for reset conditions
local engineFrame = CreateFrame("Frame")
engineFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
engineFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
engineFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
engineFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
engineFrame:RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED")
engineFrame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
engineFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
engineFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
engineFrame:RegisterEvent("UNIT_ENTERED_VEHICLE")
engineFrame:RegisterEvent("UNIT_EXITED_VEHICLE")
engineFrame:RegisterEvent("PET_BATTLE_OPENING_START")
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
        if InCombatLockdown() then return end
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
        -- Reset step on gear change, OOC only
        if InCombatLockdown() then return end
        for name, entry in pairs(Engine.sequences) do
            local ver = Engine:GetActiveVersion(entry.data)
            if ver and ver.resetOnGear then
                local btn = entry.button
                if btn then
                    btn:SetAttribute("step", 1)
                    GRIPEMS:Debug(string.format(L["GEMS_GEAR_RESET"], name))
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
        -- Apply keybinds as safety net (BindIfConfigured already ran per-sequence,
        -- but LoadKeybinds catches any that were missed).
        if KM and not InCombatLockdown() then
            KM:LoadKeybinds()
        end
        Engine._initialLoadComplete = true

        -- Register for variable changes to recompile affected sequences
        if GRIPEMS.RegisterCallback then
            GRIPEMS.RegisterCallback(Engine, "VARIABLE_UPDATED",
                function(_, _, varName)
                    if not varName then return end
                    local VS = GRIPEMS.VariableStore
                    if not VS then return end
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
                        btn:SetAttribute("step", 1)
                        GRIPEMS:Debug(string.format(L["GEMS_SPEC_RESET"], name))
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

    elseif event == "UNIT_ENTERED_VEHICLE" then
        local unit = ...
        if unit == "player" and KM then
            KM:SuspendKeybinds("vehicle")
        end

    elseif event == "UNIT_EXITED_VEHICLE" then
        local unit = ...
        if unit == "player" and KM then
            KM:RestoreKeybinds("vehicle")
        end

    elseif event == "PET_BATTLE_OPENING_START" then
        if KM then
            KM:SuspendKeybinds("pet battle")
        end

    elseif event == "PET_BATTLE_CLOSE" then
        if KM then
            KM:RestoreKeybinds("pet battle")
        end

    elseif event == "UPDATE_BONUS_ACTIONBAR"
        or event == "UPDATE_VEHICLE_ACTIONBAR" then
        -- Ignore bar-swap events during initial load (buttons may not exist yet)
        if not Engine._initialLoadComplete then return end
        -- Catches bar swaps that don't fire UNIT_ENTERED_VEHICLE
        -- (e.g., possess bar, override bar, some quest vehicles)
        if KM then
            if HasVehicleActionBar() or HasOverrideActionBar()
                or UnitHasVehicleUI("player")
                or C_PetBattles.IsInBattle() then
                KM:SuspendKeybinds("bar swap")
            else
                KM:RestoreKeybinds("bar swap")
            end
        end
    end
end)
