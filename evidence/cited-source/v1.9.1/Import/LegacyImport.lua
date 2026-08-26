-- GRIP-EMS: Legacy Import Parser
-- Legacy format parser and flat action compiler for importing external sequences

local ADDON_NAME, GRIPEMS = ...
local L = LibStub("AceLocale-3.0"):GetLocale("GRIP-EMS")
local D = GRIPEMS.Defaults
local S = GRIPEMS.Serialization
local VS = GRIPEMS.VariableStore

GRIPEMS.LegacyImport = {}
local LI = GRIPEMS.LegacyImport

-- Legacy MetaData context fields that map 1:1 to GRIP-EMS context keys
local LEGACY_CONTEXT_FIELDS = {
    "Raid",
    "Arena",
    "PVP",
    "Mythic",
    "MythicPlus",
    "Heroic",
    "Dungeon",
    "Timewalking",
    "Party",
    "Scenario",
}

--- Import one or more sequences from an encoded legacy or GRIP1 string.
--- Detects payload format (COLLECTION, simple array, command) and processes
--- each sequence found: compile macro version, build sequenceData, activate.
--- @param encodedString string The full encoded string (with prefix)
--- @return boolean success
--- @return table|string result Import results table on success, error on failure
function LI.Import(encodedString)
    if not encodedString or encodedString == "" then
        return false, "No import string provided"
    end

    -- Check if this is a GRIP1 native format
    local format = S.DetectFormat(encodedString)
    if format == "GRIP1" then
        -- Preview to handle both single-sequence and collection payloads
        local preview = LI.Preview(encodedString)
        if not preview or not preview.ok then
            return false, preview and preview.error or "Failed to preview GRIP1 payload"
        end
        if (preview.totalSequences or 0) == 0 then
            return false, "No sequences found"
        end
        -- Auto-select all sequences and variables for import
        local selections = { sequences = {}, variables = {} }
        for i in ipairs(preview.sequences or {}) do
            selections.sequences[i] = { selected = true, action = "import" }
        end
        for i in ipairs(preview.variables or {}) do
            selections.variables[i] = { selected = true, action = "import" }
        end
        return LI.CommitSelected(preview, selections)
    end

    -- Decode the string
    local ok, decoded = S.Decode(encodedString)
    if not ok then
        return false, decoded
    end

    local results = {
        names = {},
        warnings = {},
        count = 0,
        stepCounts = {},
        varsImported = 0,
        varsSkipped = 0,
        contextOverridesImported = 0,
        versionsDropped = 0,
        pausesConverted = 0,
        pauseSteps = 0,
        embedsSkipped = 0,
        truncatedSteps = 0,
        stepFunctions = {},
    }

    -- Detect payload format and extract sequences
    if type(decoded) == "table" and decoded.type == "COLLECTION" then
        -- COLLECTION format (clipboard exports)
        local payload = decoded.payload
        if not payload or not payload.Sequences then
            return false, "COLLECTION has no Sequences"
        end

        local seqCount = 0
        for _ in pairs(payload.Sequences) do
            seqCount = seqCount + 1
        end

        for seqName, seqValue in pairs(payload.Sequences) do
            if type(seqValue) == "string" then
                -- Double-encoded: decode the inner encoded string
                local innerOk, innerDecoded = S.Decode(seqValue)
                if
                    innerOk
                    and type(innerDecoded) == "table"
                    and type(innerDecoded[1]) == "string"
                    and type(innerDecoded[2]) == "table"
                then
                    local importOk, importErr = LI.ProcessSequence(innerDecoded[1], innerDecoded[2], results)
                    if not importOk then
                        results.warnings[#results.warnings + 1] =
                            string.format("'%s': %s", tostring(innerDecoded[1]), tostring(importErr))
                    end
                else
                    results.warnings[#results.warnings + 1] =
                        string.format("'%s': failed to decode inner sequence", tostring(seqName))
                end
            elseif type(seqValue) == "table" then
                -- Raw table (12.0.1+ style) - process directly
                local importOk, importErr = LI.ProcessSequence(seqName, seqValue, results)
                if not importOk then
                    results.warnings[#results.warnings + 1] =
                        string.format("'%s': %s", tostring(seqName), tostring(importErr))
                end
            end
        end

        -- Import variables from COLLECTION payload
        if payload.Variables and type(payload.Variables) == "table" then
            for varName, varValue in pairs(payload.Variables) do
                if type(varValue) == "string" then
                    -- Double-encoded variable (user selected in source export GUI)
                    local varOk, varDecoded = S.Decode(varValue)
                    if varOk and type(varDecoded) == "table" then
                        if type(varDecoded[1]) == "string" and type(varDecoded[2]) == "table" then
                            local gripVar = LI.MapLegacyVariable(varDecoded[1], varDecoded[2])
                            LI.ImportVariable(varDecoded[1], gripVar, results)
                        else
                            local gripVar = LI.MapLegacyVariable(varName, varDecoded)
                            LI.ImportVariable(varName, gripVar, results)
                        end
                    else
                        results.warnings[#results.warnings + 1] = "Variable '" .. varName .. "': failed to decode"
                    end
                elseif type(varValue) == "table" then
                    -- Raw table: auto-included from source dependency resolver
                    local gripVar = LI.MapLegacyVariable(varName, varValue)
                    LI.ImportVariable(varName, gripVar, results)
                end
            end
        end
    elseif type(decoded) == "table" and decoded.Command then
        -- Command format (addon chat transmission) -- not supported
        return false, "Command format (addon transmission) is not supported"
    elseif type(decoded) == "table" and type(decoded[1]) == "string" and type(decoded[2]) == "table" then
        -- Simple array format: { name, sequence }
        local seqName = decoded[1]
        local sequence = decoded[2]
        local importOk, importErr = LI.ProcessSequence(seqName, sequence, results)
        if not importOk then
            return false, importErr
        end
    else
        return false, L["GEMS_IMPORT_UNKNOWN_FORMAT"]
    end

    if results.count == 0 then
        return false, "No sequences could be imported"
    end

    -- Notify listeners
    if GRIPEMS.Fire then
        GRIPEMS:Fire("SEQUENCE_IMPORTED", results)
    end

    return true, results
end

--- Map legacy MetaData context version fields into GRIP-EMS contextOverrides.
--- Source format stores integer version indices on MetaData (Raid, Arena, PVP, etc.).
--- If a context version equals the default, it means "use default" and is skipped.
--- @param metadata table|nil Imported sequence MetaData table
--- @param numVersions number Total number of imported versions (for bounds check)
--- @return table contextOverrides { ctxKey = versionIndex } (empty if no overrides)
function LI.MapLegacyContextOverrides(metadata, numVersions)
    local overrides = {}
    if not metadata or type(metadata) ~= "table" then
        return overrides
    end
    local defaultIdx = tonumber(metadata.Default) or 1
    for _, field in ipairs(LEGACY_CONTEXT_FIELDS) do
        local idx = tonumber(metadata[field])
        if idx and idx >= 1 and idx <= numVersions and idx ~= defaultIdx then
            overrides[field] = idx
        end
    end
    return overrides
end

--- Process a single imported sequence: pick the default macro version, compile it,
--- build a GRIP-EMS sequenceData table, and activate it.
--- @param seqName string Sequence name
--- @param sequence table Imported sequence object
--- @param results table Import results accumulator
--- @param opts table|nil Optional metadata overrides (author, description, specID, updatedAt, classID, icon)
--- @return boolean success
--- @return string|nil error Error message on failure
function LI.ProcessSequence(seqName, sequence, results, opts)
    if not seqName or not sequence then
        return false, "Missing name or sequence data"
    end

    local macros = sequence.Macros or sequence.MacroVersions or sequence.Versions
    if not macros or #macros == 0 then
        return false, "No macro versions found"
    end

    -- Pick the default macro version index
    local defaultIdx = 1
    if sequence.MetaData and sequence.MetaData.Default then
        defaultIdx = tonumber(sequence.MetaData.Default) or 1
    end
    if defaultIdx < 1 or defaultIdx > #macros then
        defaultIdx = 1
    end

    -- Checksum validation (non-blocking, warn only)
    if sequence.MetaData and sequence.MetaData.Checksum then
        local macroData = sequence.Macros or sequence.MacroVersions or sequence.Versions
        if macroData then
            local computed = S.ComputeTableChecksum(macroData)
            if computed and computed ~= tostring(sequence.MetaData.Checksum) then
                results.warnings[#results.warnings + 1] = seqName
                    .. ": import checksum mismatch (data may have been modified since export)"
            end
        end
    end

    -- Import ALL versions (T2-2a: no longer dropping non-default versions)
    local versions = {}
    local anySteps = false
    for i, macroVersion in ipairs(macros) do
        -- Reset compile stats before each version
        LI._compileStats = { pauses = 0, pauseSteps = 0, embeds = 0, truncated = 0, unresolvedSpells = 0 }

        local compiled = LI.CompileMacroVersion(macroVersion)

        -- Accumulate compile stats into results
        results.pausesConverted = (results.pausesConverted or 0) + LI._compileStats.pauses
        results.pauseSteps = (results.pauseSteps or 0) + LI._compileStats.pauseSteps
        results.embedsSkipped = (results.embedsSkipped or 0) + LI._compileStats.embeds
        results.truncatedSteps = (results.truncatedSteps or 0) + LI._compileStats.truncated

        if (LI._compileStats.unresolvedSpells or 0) > 0 then
            results.warnings[#results.warnings + 1] = seqName
                .. ": "
                .. LI._compileStats.unresolvedSpells
                .. " spell ID(s) could not be resolved to names (/cast with numeric IDs will fail)"
        end

        -- Merge warnings
        if compiled.warnings then
            for _, w in ipairs(compiled.warnings) do
                results.warnings[#results.warnings + 1] = seqName .. ": " .. w
            end
        end

        -- Map step function: check Step first, then StepFunction, default Sequential
        local stepFunc = D.STEP_SEQUENTIAL
        if macroVersion.Step then
            local s = macroVersion.Step
            if s == "Sequential" or s == "Priority" or s == "Random" then
                if s == "Priority" then
                    GRIPEMS:Debug("Priority mapped to Sequential (priority encoded in step order)")
                    results.warnings[#results.warnings + 1] = seqName
                        .. ": Priority step function mapped to Sequential (priority encoded in step order)"
                    stepFunc = D.STEP_SEQUENTIAL
                else
                    stepFunc = s
                end
            elseif s == "ReversePriority" then
                stepFunc = D.STEP_REVERSE_PRIORITY
            end
        elseif macroVersion.StepFunction then
            local s = macroVersion.StepFunction
            if s == "Sequential" or s == "Priority" or s == "Random" then
                if s == "Priority" then
                    GRIPEMS:Debug("Priority mapped to Sequential (priority encoded in step order)")
                    results.warnings[#results.warnings + 1] = seqName
                        .. ": Priority step function mapped to Sequential (priority encoded in step order)"
                    stepFunc = D.STEP_SEQUENTIAL
                else
                    stepFunc = s
                end
            elseif s == "ReversePriority" then
                stepFunc = D.STEP_REVERSE_PRIORITY
            end
        end

        -- Inherit step function from inner Loop if macro version has none
        if stepFunc == D.STEP_SEQUENTIAL and compiled.innerStepFunc then
            stepFunc = compiled.innerStepFunc
        end

        -- Map reset conditions from InbuiltVariables
        local resetOnCombat = false
        local resetOnTarget = false
        local resetOnGear = false
        if macroVersion.InbuiltVariables and type(macroVersion.InbuiltVariables) == "table" then
            if macroVersion.InbuiltVariables.Combat then
                resetOnCombat = true
            end
            if macroVersion.InbuiltVariables.Head then
                resetOnGear = true
            end
        end

        -- Build action tree from legacy Actions array (S14-C)
        local actionTree = LI.MapLegacyActionsToTree(macroVersion.Actions or {})

        versions[i] = {
            stepFunction = stepFunc,
            steps = compiled.steps or {},
            actions = actionTree,
            keyPress = compiled.keyPress or "",
            keyRelease = compiled.keyRelease or "",
            resetOnCombat = resetOnCombat,
            resetOnTarget = resetOnTarget,
            resetOnGear = resetOnGear,
            resetOnSpec = false,
            resetTimer = 0,
        }

        if compiled.steps and #compiled.steps > 0 then
            anySteps = true
        end
    end

    if not anySteps then
        return false, "No steps after compilation"
    end

    -- Interleave is now a first-class property on Action nodes (interval field).
    -- ActionCompiler handles interleaving at compile time, so action trees
    -- no longer need to be cleared for imported sequences.

    -- Track step function per sequence for report (from default version)
    results.stepFunctions = results.stepFunctions or {}
    results.stepFunctions[seqName] = versions[defaultIdx].stepFunction

    -- Build GRIP-EMS sequenceData with versioned format
    local seqData = {
        name = seqName,
        icon = D.QUESTION_MARK_ICON,
        defaultVersion = defaultIdx,
        contextOverrides = LI.MapLegacyContextOverrides(sequence.MetaData, #versions),
        versions = versions,
        author = "",
        version = "1",
        description = "",
        help = sequence.Help or sequence.help or "",
        helplink = sequence.Helplink or sequence.helplink or "",
        classID = select(3, UnitClass("player")) or 0,
        specID = nil,
        createdAt = time(),
        updatedAt = time(),
    }

    -- Store legacy format metadata for future use (informational only)
    seqData.importMeta = {}
    if sequence.MetaData then
        if sequence.MetaData.GSEVersion then
            seqData.importMeta.sourceVersion = tostring(sequence.MetaData.GSEVersion)
        end
        if sequence.MetaData.Checksum then
            seqData.importMeta.sourceChecksum = tostring(sequence.MetaData.Checksum)
        end
        -- Read disabled state from metadata
        if sequence.MetaData.Disabled then
            seqData.disabled = true
        end
    end

    -- Count context overrides for import report
    local ctxCount = 0
    for _ in pairs(seqData.contextOverrides) do
        ctxCount = ctxCount + 1
    end
    results.contextOverridesImported = (results.contextOverridesImported or 0) + ctxCount

    -- Merge optional metadata overrides (from migration or enhanced import)
    if opts then
        if opts.author then
            seqData.author = opts.author
        end
        if opts.description then
            seqData.description = opts.description
        end
        if opts.specID then
            seqData.specID = opts.specID
        end
        if opts.updatedAt then
            seqData.updatedAt = opts.updatedAt
        end
        if opts.classID ~= nil then
            seqData.classID = opts.classID
        end
        if opts.icon then
            seqData.icon = opts.icon
        end
    end

    -- Read metadata from COLLECTION clipboard path (opts is nil on this path)
    local md = sequence.MetaData
    if md then
        if seqData.author == "" and md.Author then
            seqData.author = md.Author
        end
        if not seqData.specID and md.SpecID then
            seqData.specID = md.SpecID
        end
        if seqData.icon == D.QUESTION_MARK_ICON then
            if md.Icon and md.Icon ~= 0 then
                seqData.icon = md.Icon
            elseif sequence.Icon and sequence.Icon ~= 0 then
                seqData.icon = sequence.Icon
            end
        end
    end

    -- Auto-suggest icon if still question mark
    if seqData.icon == D.QUESTION_MARK_ICON then
        local IP = GRIPEMS.LegacyImport
        if IP and IP._SuggestSequenceIcon then
            local iconID = IP._SuggestSequenceIcon(seqData)
            if iconID then
                seqData.icon = iconID
                seqData.autoIcon = true
            end
        end
    end

    -- Activate the sequence through the engine (class-gate during migration)
    if opts and opts.dormant then
        if _G.GRIP_EMS_CHAR then
            GRIP_EMS_CHAR.sequences = GRIP_EMS_CHAR.sequences or {}
            GRIP_EMS_CHAR.sequences[seqName] = seqData
        end
        GRIPEMS.Engine:RegisterSequenceOnly(seqName, seqData)
    else
        GRIPEMS.Engine:ActivateSequence(seqName, seqData)
    end

    results.names[#results.names + 1] = seqName
    results.stepCounts = results.stepCounts or {}
    results.stepCounts[seqName] = #versions[defaultIdx].steps
    results.count = results.count + 1

    return true
end

--- Map a legacy macro version's Actions array to an EMS action tree.
--- Produces structured action nodes that preserve the hierarchical intent
--- of the imported sequence (loops, conditionals, embeds, pauses).
--- Edge Repeat actions are promoted to keyPress/keyRelease and excluded.
--- @param legacyActions table Imported macro version Actions array
--- @return table actions Array of EMS action nodes
function LI.MapLegacyActionsToTree(legacyActions)
    if not legacyActions or #legacyActions == 0 then
        return {}
    end

    -- Detect edge Repeat actions (same logic as CompileMacroVersion)
    local actionsStart = 1
    local actionsEnd = #legacyActions
    if legacyActions[1] and legacyActions[1].Type == "Repeat" then
        actionsStart = 2
    end
    if actionsEnd >= actionsStart and legacyActions[actionsEnd] and legacyActions[actionsEnd].Type == "Repeat" then
        actionsEnd = actionsEnd - 1
    end

    local tree = {}
    for idx = actionsStart, actionsEnd do
        local action = legacyActions[idx]
        if action and action.Type and not action.Disabled then
            local node = LI._MapActionToNode(action)
            if node then
                tree[#tree + 1] = node
            end
        end
    end
    return tree
end

--- Map a single legacy action to an EMS action node (recursive).
--- @param action table Imported action object
--- @return table|nil node EMS action node, or nil to skip
function LI._MapActionToNode(action)
    if not action or not action.Type then
        return nil
    end
    if action.Disabled then
        return nil
    end

    local actionType = action.Type

    if actionType == "Comment" then
        return nil
    end

    if actionType == "Action" then
        local macro
        local subType = action.type
        if subType == "macro" and action.macro then
            macro = LI.ResolveSpellIDsInMacrotext(action.macro)
        elseif subType == "spell" then
            local spell = LI.ResolveSpell(action.Spell or action.macro)
            if not spell or spell == "" then
                return nil
            end
            if action.unit and action.unit ~= "" then
                macro = "/cast [@" .. action.unit .. "] " .. spell
            else
                macro = "/cast " .. spell
            end
        elseif subType == "item" then
            local item = tostring(action.Spell or action.macro or "")
            if item == "" then
                return nil
            end
            if action.unit and action.unit ~= "" then
                macro = "/use [@" .. action.unit .. "] " .. item
            else
                macro = "/use " .. item
            end
        elseif subType == "action" then
            -- Pet ability
            local spellName = action.action
            if not spellName or spellName == "" then
                return nil
            end
            if action.unit and action.unit ~= "" then
                macro = "/cast [@" .. action.unit .. "] " .. spellName
            else
                macro = "/cast " .. spellName
            end
        elseif subType == "toy" then
            -- Toy usage
            local toyName = action.toy
            if not toyName or toyName == "" then
                return nil
            end
            if action.unit and action.unit ~= "" then
                macro = "/use [@" .. action.unit .. "] " .. toyName
            else
                macro = "/use " .. toyName
            end
        else
            if action.macro and action.macro ~= "" then
                macro = action.macro
            else
                return nil
            end
        end
        return { type = D.ACTION_TYPE_ACTION, macro = macro or "" }
    end

    if actionType == "spell" then
        local spell = LI.ResolveSpell(action.Spell)
        if not spell or spell == "" then
            return nil
        end
        local macro
        if action.unit and action.unit ~= "" then
            macro = "/cast [@" .. action.unit .. "] " .. spell
        else
            macro = "/cast " .. spell
        end
        return { type = D.ACTION_TYPE_ACTION, macro = macro }
    end

    if actionType == "item" then
        local item = tostring(action.Spell or "")
        if item == "" then
            return nil
        end
        local macro
        if action.unit and action.unit ~= "" then
            macro = "/use [@" .. action.unit .. "] " .. item
        else
            macro = "/use " .. item
        end
        return { type = D.ACTION_TYPE_ACTION, macro = macro }
    end

    if actionType == "macro" then
        local text = tostring(action.Spell or "")
        if text == "" then
            return nil
        end
        return { type = D.ACTION_TYPE_ACTION, macro = LI.ResolveSpellIDsInMacrotext(text) }
    end

    if actionType == "Repeat" then
        -- Mid-array Repeat: preserve interval as interleave property
        local macro = ""
        if action.macro and action.macro ~= "" then
            macro = LI.ResolveSpellIDsInMacrotext(action.macro)
        elseif action.Spell then
            local spell = LI.ResolveSpell(action.Spell)
            if spell and spell ~= "" then
                macro = "/cast " .. spell
            end
        end
        if macro == "" then
            return nil
        end
        local interval = tonumber(action.Interval) or tonumber(action.Repeat) or 2
        if interval < D.ACTION_INTERLEAVE_MIN then
            interval = D.ACTION_INTERLEAVE_MIN
        end
        if interval > D.ACTION_INTERLEAVE_MAX then
            interval = D.ACTION_INTERLEAVE_MAX
        end
        return { type = D.ACTION_TYPE_ACTION, macro = macro, interval = interval }
    end

    if actionType == "Pause" then
        local numSteps = 1
        if action.Variable and action.Variable ~= "" then
            -- Dynamic pause: keep as action node with /run comment
            return { type = D.ACTION_TYPE_ACTION, macro = "/run -- PAUSE: ~" .. tostring(action.Variable) .. "~" }
        end
        if action.MS then
            local msVal = tostring(action.MS)
            if msVal == "GCD" or msVal == "~~GCD~~" then
                -- GCD-duration pause: default to 2 clicks (~1.5s GCD)
                numSteps = 2
            elseif tonumber(msVal) and tonumber(msVal) > 0 then
                local ms = tonumber(msVal)
                local clickRate = GRIPEMS.Settings
                        and GRIPEMS.Settings.GetEffectiveClickRate
                        and GRIPEMS.Settings:GetEffectiveClickRate()
                    or 250
                numSteps = math.ceil(ms / clickRate)
            end
        elseif action.Clicks and tonumber(action.Clicks) then
            numSteps = tonumber(action.Clicks)
        end
        if numSteps < 1 then
            numSteps = 1
        end
        return { type = D.ACTION_TYPE_PAUSE, clicks = numSteps }
    end

    if actionType == "Loop" then
        local loopCount = tonumber(action.Repeat) or tonumber(action.Count) or 1
        if loopCount < 1 then
            loopCount = 1
        end
        if loopCount > D.ACTION_LOOP_MAX_REPEAT then
            loopCount = D.ACTION_LOOP_MAX_REPEAT
        end

        -- Map step function
        local sfName = D.STEP_SEQUENTIAL
        if action.StepFunction then
            local s = action.StepFunction
            if s == "Priority" then
                sfName = D.STEP_SEQUENTIAL
            elseif s == "Sequential" or s == "Random" then
                sfName = s
            elseif s == "ReversePriority" then
                sfName = D.STEP_REVERSE_PRIORITY
            end
        end

        -- Extract sub-actions
        local subActions = {}
        if action.Actions and type(action.Actions) == "table" then
            for _, sa in ipairs(action.Actions) do
                subActions[#subActions + 1] = sa
            end
        else
            local idx = 1
            while action[idx] or action[tostring(idx)] do
                subActions[#subActions + 1] = action[idx] or action[tostring(idx)]
                idx = idx + 1
            end
        end

        local children = {}
        for _, sa in ipairs(subActions) do
            if not sa.Disabled then
                local child = LI._MapActionToNode(sa)
                if child then
                    children[#children + 1] = child
                end
            end
        end

        return {
            type = D.ACTION_TYPE_LOOP,
            ["repeat"] = loopCount,
            stepFunction = sfName,
            children = children,
        }
    end

    if actionType == "If" then
        local variable = action.Variable or action.Condition or "= true"

        -- True branch
        local trueBranch = {}
        if action[1] then
            local node = LI._MapActionToNode(action[1])
            if node then
                trueBranch[#trueBranch + 1] = node
            end
        elseif action.Actions and action.Actions[1] then
            local node = LI._MapActionToNode(action.Actions[1])
            if node then
                trueBranch[#trueBranch + 1] = node
            end
        elseif action.Spell then
            local spell = LI.ResolveSpell(action.Spell)
            if spell and spell ~= "" then
                trueBranch[#trueBranch + 1] = { type = D.ACTION_TYPE_ACTION, macro = "/cast " .. spell }
            end
        end

        -- False branch
        local falseBranch = {}
        if action[2] then
            local node = LI._MapActionToNode(action[2])
            if node then
                falseBranch[#falseBranch + 1] = node
            end
        elseif action.ElseActions and action.ElseActions[1] then
            local node = LI._MapActionToNode(action.ElseActions[1])
            if node then
                falseBranch[#falseBranch + 1] = node
            end
        end

        return {
            type = D.ACTION_TYPE_IF,
            variable = variable,
            children = { trueBranch, falseBranch },
        }
    end

    if actionType == "Embed" then
        local seqName = action.Sequence or action.Spell or ""
        return { type = D.ACTION_TYPE_EMBED, sequence = tostring(seqName) }
    end

    if actionType == "Variable" then
        local varName = action.Variable or action.Spell or ""
        if varName == "" then
            return nil
        end
        return { type = D.ACTION_TYPE_ACTION, macro = "/run ~" .. varName .. "~" }
    end

    if actionType == "action" then
        -- Pet action
        local name = tostring(action.Spell or action.macro or "")
        if name == "" then
            return nil
        end
        return { type = D.ACTION_TYPE_ACTION, macro = "/cast " .. name }
    end

    if actionType == "toy" then
        local name = tostring(action.Spell or action.macro or "")
        if name == "" then
            return nil
        end
        return { type = D.ACTION_TYPE_ACTION, macro = "/use " .. name }
    end

    -- Unknown type: skip
    return nil
end

--- Compile a single imported macro version into an array of flat macrotext strings.
--- Prepends KeyPress and appends KeyRelease to each compiled action step.
--- @param macroVersion table Imported macro version { KeyPress, KeyRelease, Step, Actions }
--- @return table { steps = { ... }, warnings = { ... } }
function LI.CompileMacroVersion(macroVersion)
    local warnings = {}
    local steps = {}

    if not macroVersion then
        return { steps = steps, warnings = { "Nil macro version" } }
    end

    -- Build KeyPress/KeyRelease blocks
    local keyPress = ""
    if macroVersion.KeyPress and #macroVersion.KeyPress > 0 then
        keyPress = table.concat(macroVersion.KeyPress, "\n")
    end

    local keyRelease = ""
    if macroVersion.KeyRelease and #macroVersion.KeyRelease > 0 then
        keyRelease = table.concat(macroVersion.KeyRelease, "\n")
    end

    -- Compile each action
    local actions = macroVersion.Actions
    if not actions then
        return { steps = steps, warnings = { "No actions in macro version" } }
    end

    -- Detect Repeat actions at edges of Actions array.
    -- Legacy format encodes KeyPress as a Repeat at Actions[1] and KeyRelease
    -- as a Repeat at Actions[#Actions]. Promote their macro content
    -- into keyPress/keyRelease and exclude them from step compilation.
    local actionsStart = 1
    local actionsEnd = #actions
    if actions[1] and actions[1].Type == "Repeat" then
        local repeatMacro = actions[1].macro or ""
        if repeatMacro ~= "" then
            if keyPress ~= "" then
                keyPress = keyPress .. "\n" .. repeatMacro
            else
                keyPress = repeatMacro
            end
        end
        actionsStart = 2
    end
    if actionsEnd >= actionsStart and actions[actionsEnd] and actions[actionsEnd].Type == "Repeat" then
        local repeatMacro = actions[actionsEnd].macro or ""
        if repeatMacro ~= "" then
            if keyRelease ~= "" then
                keyRelease = keyRelease .. "\n" .. repeatMacro
            else
                keyRelease = repeatMacro
            end
        end
        actionsEnd = actionsEnd - 1
    end

    -- Resolve spell IDs in KeyPress/KeyRelease strings
    -- (after edge Repeat promotion so promoted content is also resolved)
    if keyPress ~= "" then
        keyPress = LI.ResolveSpellIDsInMacrotext(keyPress)
    end
    if keyRelease ~= "" then
        keyRelease = LI.ResolveSpellIDsInMacrotext(keyRelease)
    end

    local innerStepFunc = nil
    local intervalActions = {}
    for actionIdx = actionsStart, actionsEnd do
        local action = actions[actionIdx]
        -- Capture StepFunction from inner Loop actions
        if action.Type == "Loop" and action.StepFunction then
            local s = action.StepFunction
            if s == "Sequential" or s == "Priority" or s == "Random" then
                if s == "Priority" then
                    GRIPEMS:Debug("Priority mapped to Sequential (innerStepFunc, priority encoded in step order)")
                    warnings[#warnings + 1] =
                        "Priority step function mapped to Sequential (priority encoded in step order)"
                    innerStepFunc = D.STEP_SEQUENTIAL
                else
                    innerStepFunc = s
                end
            end
        end
        local compiled, actionWarnings = LI.CompileAction(action)
        if actionWarnings then
            for _, w in ipairs(actionWarnings) do
                warnings[#warnings + 1] = w
            end
        end

        for _, stepText in ipairs(compiled) do
            -- Raw step (no KP/KR wrapping -- Engine handles wrapping based
            -- on step function: Sequential/Random wrap per-step, Priority
            -- wraps once at top/bottom)
            if stepText == "" then
                -- Empty step (pause no-op): preserve as-is
                steps[#steps + 1] = ""
            else
                local raw = stepText:match("^%s*(.-)%s*$") or ""
                if raw ~= "" then
                    raw = LI.ResolveSpellIDsInMacrotext(raw)
                    steps[#steps + 1] = raw
                    -- Track actions with interval for interleaving
                    if action.Interval and tonumber(action.Interval) and tonumber(action.Interval) > 0 then
                        intervalActions[#intervalActions + 1] = {
                            text = raw,
                            interval = tonumber(action.Interval),
                        }
                    end
                end
            end
        end
    end

    -- Interval interleaving pass: insert copies at every Nth position
    if #intervalActions > 0 then
        local MAX_INTERLEAVED = 200
        local totalInserted = 0
        for _, ia in ipairs(intervalActions) do
            -- Work backwards to avoid index shifting
            local pos = ia.interval
            while pos <= #steps and totalInserted < MAX_INTERLEAVED do
                table.insert(steps, pos + 1, ia.text)
                totalInserted = totalInserted + 1
                pos = pos + ia.interval + 1
            end
        end
        warnings[#warnings + 1] = string.format(L["GEMS_IMPORT_INTERVAL_PRESERVED"], #intervalActions)
    end

    return {
        steps = steps,
        keyPress = keyPress,
        keyRelease = keyRelease,
        warnings = warnings,
        innerStepFunc = innerStepFunc,
    }
end

--- Compile a single imported action into macrotext string(s).
--- @param action table Imported action { Type, Spell, unit, Condition, Actions, ... }
--- @return table Array of macrotext strings (usually 1; Loop expands to N)
--- @return table|nil Array of warning strings
function LI.CompileAction(action)
    if not action or not action.Type then
        return {}, { "Action with no Type skipped" }
    end

    -- Skip disabled actions silently
    if action.Disabled then
        return {}, nil
    end

    local actionType = action.Type
    local warnings = {}

    if actionType == "Action" then
        -- Modern legacy action format
        local subType = action.type -- lowercase t: "macro", "spell", "item"
        if subType == "macro" and action.macro then
            return { LI.ResolveSpellIDsInMacrotext(action.macro) }
        elseif subType == "spell" then
            local spell = LI.ResolveSpell(action.Spell or action.macro)
            if not spell or spell == "" then
                return {}, { "Action/spell with no spell reference skipped" }
            end
            if action.unit and action.unit ~= "" then
                return { "/cast [@" .. action.unit .. "] " .. spell }
            else
                return { "/cast " .. spell }
            end
        elseif subType == "item" then
            local item = tostring(action.Spell or action.macro or "")
            if item == "" then
                return {}, { "Action/item with no item reference skipped" }
            end
            if action.unit and action.unit ~= "" then
                return { "/use [@" .. action.unit .. "] " .. item }
            else
                return { "/use " .. item }
            end
        elseif subType == "action" then
            -- Pet ability
            local spellName = action.action
            if not spellName or spellName == "" then
                return {}, { "Action/pet with no ability reference skipped" }
            end
            if action.unit and action.unit ~= "" then
                return { "/cast [@" .. action.unit .. "] " .. spellName }
            else
                return { "/cast " .. spellName }
            end
        elseif subType == "toy" then
            -- Toy usage
            local toyName = action.toy
            if not toyName or toyName == "" then
                return {}, { "Action/toy with no toy reference skipped" }
            end
            if action.unit and action.unit ~= "" then
                return { "/use [@" .. action.unit .. "] " .. toyName }
            else
                return { "/use " .. toyName }
            end
        else
            -- Unknown subtype, try macro field as fallback
            if action.macro and action.macro ~= "" then
                return { action.macro }
            end
            return {}, { "Action with unknown subtype: " .. tostring(subType) }
        end
    elseif actionType == "spell" then
        local spell = LI.ResolveSpell(action.Spell)
        if not spell or spell == "" then
            return {}, { "Spell action with no spell name skipped" }
        end
        local text
        if action.unit and action.unit ~= "" then
            text = "/cast [@" .. action.unit .. "] " .. spell
        else
            text = "/cast " .. spell
        end
        return { text }
    elseif actionType == "item" then
        local item = tostring(action.Spell or "")
        if item == "" then
            return {}, { "Item action with no item name skipped" }
        end
        local text
        if action.unit and action.unit ~= "" then
            text = "/use [@" .. action.unit .. "] " .. item
        else
            text = "/use " .. item
        end
        return { text }
    elseif actionType == "macro" then
        local text = tostring(action.Spell or "")
        if text == "" then
            return {}, { "Macro action with empty text skipped" }
        end
        return { LI.ResolveSpellIDsInMacrotext(text) }
    elseif actionType == "Pause" then
        if LI._compileStats then
            LI._compileStats.pauses = LI._compileStats.pauses + 1
        end
        -- Variable sub-path: dynamic pause as comment step (unchanged)
        if action.Variable and action.Variable ~= "" then
            local step = "/run -- PAUSE: ~" .. tostring(action.Variable) .. "~"
            return { step }, { L["GEMS_VAR_IMPORT_PAUSE"] }
        end
        -- Static pause: convert to N empty steps (each consumes one keypress)
        local numSteps = 1
        if action.MS then
            local msVal = tostring(action.MS)
            if msVal == "GCD" or msVal == "~~GCD~~" then
                -- GCD-duration pause: default to 2 clicks (~1.5s GCD)
                numSteps = 2
            elseif tonumber(msVal) and tonumber(msVal) > 0 then
                -- MS mode: convert milliseconds to click count
                local ms = tonumber(msVal)
                local clickRate = GRIPEMS.Settings:GetEffectiveClickRate() or 250
                numSteps = math.ceil(ms / clickRate)
            end
        elseif action.Clicks and tonumber(action.Clicks) then
            -- Clicks mode: explicit step count
            numSteps = tonumber(action.Clicks)
        end
        if numSteps < 1 then
            numSteps = 1
        end
        local emptySteps = {}
        for i = 1, numSteps do
            emptySteps[i] = ""
        end
        if LI._compileStats then
            LI._compileStats.pauseSteps = LI._compileStats.pauseSteps + numSteps
        end
        local msg = string.format(L["GEMS_IMPORT_PAUSE_CONVERTED"], numSteps)
        return emptySteps, { msg }
    elseif actionType == "If" then
        local result, ifWarnings = LI.CompileConditional(action)
        return result, ifWarnings
    elseif actionType == "Repeat" then
        -- Repeat: a per-press macro wrapper (KeyPress/KeyRelease
        -- equivalent). Content is in action.macro, not sub-actions.
        -- CompileMacroVersion promotes edge Repeat actions to
        -- keyPress/keyRelease blocks; mid-array Repeats compile as steps.
        if action.macro and action.macro ~= "" then
            return { LI.ResolveSpellIDsInMacrotext(action.macro) }
        elseif action.Spell then
            local spell = LI.ResolveSpell(action.Spell)
            if spell and spell ~= "" then
                return { "/cast " .. spell }
            end
        end
        return {}, nil
    elseif actionType == "Loop" then
        local loopCount = tonumber(action.Repeat) or tonumber(action.Count) or 1
        if loopCount < 1 then
            loopCount = 1
        end
        if loopCount > 50 then
            warnings[#warnings + 1] = string.format("Loop count capped from %d to 50", loopCount)
            loopCount = 50
        end

        -- Extract sub-actions: numbered keys (int or string) OR Actions array
        local subActions = {}
        if action.Actions and type(action.Actions) == "table" then
            -- Old format: Actions array
            for _, sa in ipairs(action.Actions) do
                subActions[#subActions + 1] = sa
            end
        else
            -- Modern format: numbered keys [1], [2], ... or ["1"], ["2"], ...
            local idx = 1
            while action[idx] or action[tostring(idx)] do
                subActions[#subActions + 1] = action[idx] or action[tostring(idx)]
                idx = idx + 1
            end
        end

        if #subActions == 0 then
            return {}, { "Loop with no sub-actions skipped" }
        end

        local expanded = {}
        for _ = 1, loopCount do
            for _, subAction in ipairs(subActions) do
                if not subAction.Disabled then
                    local compiled, subWarnings = LI.CompileAction(subAction)
                    if subWarnings then
                        for _, w in ipairs(subWarnings) do
                            warnings[#warnings + 1] = w
                        end
                    end
                    for _, step in ipairs(compiled) do
                        expanded[#expanded + 1] = step
                    end
                end
            end
        end
        return expanded, (#warnings > 0) and warnings or nil
    elseif actionType == "Embed" then
        if LI._compileStats then
            LI._compileStats.embeds = LI._compileStats.embeds + 1
        end
        local embedName = tostring(action.Sequence or action.Spell or "?")
        warnings[#warnings + 1] = string.format(L["GEMS_IMPORT_EMBED_SKIPPED"], embedName)
        return {}, warnings
    elseif actionType == "Comment" then
        return {}
    elseif actionType == "Variable" then
        -- Legacy variable action: resolve to substitution syntax
        local varName = action.Variable or action.Spell or ""
        if varName == "" then
            return {}, { "Variable action with no name skipped" }
        end
        if VS and VS.Get and VS:Get(varName) then
            -- Variable exists: emit substitution token (resolved at CompileSteps time)
            return { "/run ~" .. varName .. "~" }
        else
            GRIPEMS:Debug("Variable action skipped: '" .. varName .. "' not found")
            return {}, nil
        end
    elseif actionType == "action" then
        -- Pet action: compile to /cast PetActionName
        local name = tostring(action.Spell or action.macro or "")
        if name == "" then
            GRIPEMS:Debug("Pet action skipped: no name field")
            return {}, nil
        end
        return { "/cast " .. name }
    elseif actionType == "toy" then
        -- Toy action: compile to /use ToyName
        local name = tostring(action.Spell or action.macro or "")
        if name == "" then
            GRIPEMS:Debug("Toy action skipped: no name field")
            return {}, nil
        end
        return { "/use " .. name }
    else
        warnings[#warnings + 1] = string.format(L["GEMS_IMPORT_ACTION_SKIPPED"], tostring(actionType))
        return {}, warnings
    end
end

--- Resolve a spell reference to a string name.
--- If spellRef is a number (spell ID), tries C_Spell.GetSpellName to get
--- the localized name; falls back to tostring if unavailable.
--- @param spellRef string|number Spell name or spell ID
--- @return string Spell name as a string
function LI.ResolveSpell(spellRef)
    if spellRef == nil then
        return ""
    end

    if type(spellRef) == "number" then
        -- Try to resolve spell ID to localized name
        local name = C_Spell.GetSpellName(spellRef)
        if name and name ~= "" then
            return name
        end
        -- Fallback: spell ID as string (broken in modern WoW -- /cast requires names)
        if LI._compileStats then
            LI._compileStats.unresolvedSpells = (LI._compileStats.unresolvedSpells or 0) + 1
        end
        GRIPEMS:Debug("Unresolved spell ID: " .. tostring(spellRef))
        return tostring(spellRef)
    end

    return tostring(spellRef)
end

--- Post-process macrotext to resolve numeric spell IDs in /cast and /castsequence lines.
--- Modern WoW requires spell names, not numeric IDs, in /cast commands.
--- @param text string Raw macrotext (may be multi-line)
--- @return string Processed macrotext with spell IDs resolved in /cast and /castsequence
function LI.ResolveSpellIDsInMacrotext(text)
    if not text or text == "" then
        return text
    end

    --- Consume all leading [condition] blocks from a string.
    --- Returns the concatenated conditions (with trailing space) and the remainder.
    --- @param str string Input after command keyword
    --- @return string conditions All [...] blocks concatenated (empty string if none)
    --- @return string remainder Text after the last condition block
    local function consumeConditions(str)
        local conditions = ""
        local remainder = str
        while true do
            local bracket, rest = remainder:match("^(%b[])%s*(.*)")
            if bracket then
                conditions = conditions .. bracket .. " "
                remainder = rest
            else
                break
            end
        end
        -- Trim trailing space from conditions
        conditions = conditions:match("^(.-)%s*$") or conditions
        return conditions, remainder
    end

    local lines = {}
    for line in text:gmatch("[^\n]+") do
        local lineLower = line:lower()
        if (lineLower:match("^/cast%s") or lineLower:match("^/use%s")) and not lineLower:match("^/castsequence") then
            -- /cast or /use line: resolve numeric spell IDs to names
            -- Pattern: /cast [optional conditions] SpellRef; SpellRef
            -- /use numeric args are inventory slots, NOT spell IDs (BUG-046)
            local cmd, rest = line:match("^(/%a+%s+)(.*)")
            local cmdWord = cmd and strlower(cmd:match("^(/%a+)"))
            if cmd and rest and rest ~= "" then
                -- Consume all leading [condition] blocks
                local conditions, spellPart = consumeConditions(rest)
                if spellPart and spellPart ~= "" then
                    -- Split by semicolons (fallback casts)
                    local resolved = {}
                    for ref in spellPart:gmatch("[^;]+") do
                        ref = ref:match("^%s*(.-)%s*$") -- trim
                        -- Each segment may have its own [condition] blocks
                        local segCond, segSpell = consumeConditions(ref)
                        if cmdWord ~= "/use" then
                            local numericID = tonumber(segSpell)
                            if numericID and tostring(numericID) == segSpell then
                                local name = C_Spell.GetSpellName(numericID)
                                if name and name ~= "" then
                                    segSpell = name
                                end
                            end
                        end
                        if segCond ~= "" then
                            resolved[#resolved + 1] = segCond .. " " .. segSpell
                        else
                            resolved[#resolved + 1] = segSpell
                        end
                    end
                    if conditions ~= "" then
                        line = cmd .. conditions .. " " .. table.concat(resolved, "; ")
                    else
                        line = cmd .. table.concat(resolved, "; ")
                    end
                end
            end
        elseif lineLower:match("^/castsequence") then
            -- Consume all leading [condition] blocks after the command
            local cmdPart, rest = line:match("^(/[cC][aA][sS][tT][sS][eE][qQ][uU][eE][nN][cC][eE]%s+)(.*)")
            if cmdPart then
                local conditions, spellList = consumeConditions(rest)
                local prefix
                if conditions ~= "" then
                    prefix = cmdPart .. conditions .. " "
                else
                    prefix = cmdPart
                end
                if spellList and spellList ~= "" then
                    -- Handle reset= prefix within the spell list
                    -- e.g. "reset=target/combat 217200, 34026"
                    local resetPrefix, remainder = spellList:match("^(reset=%S+%s+)(.*)")
                    if resetPrefix then
                        prefix = prefix .. resetPrefix
                        spellList = remainder
                    end
                    -- Split spell list by comma, resolve each numeric entry
                    local resolved = {}
                    for entry in spellList:gmatch("[^,]+") do
                        entry = entry:match("^%s*(.-)%s*$") -- trim
                        local numericID = tonumber(entry)
                        if numericID then
                            local name = C_Spell.GetSpellName(numericID)
                            if name and name ~= "" then
                                resolved[#resolved + 1] = name
                            else
                                -- Can't resolve, keep as-is (will error but no worse than before)
                                resolved[#resolved + 1] = entry
                            end
                        else
                            -- Already a name or complex expression, keep as-is
                            resolved[#resolved + 1] = entry
                        end
                    end
                    line = prefix .. table.concat(resolved, ", ")
                end
            end
            -- if cmdPart was nil, line stays unchanged (no-op)
        end
        lines[#lines + 1] = line
    end
    return table.concat(lines, "\n")
end

--- Map a legacy variable definition to GRIP-EMS varDef format.
--- @param legacyVarName string Variable name from source
--- @param legacyVarDef table Legacy variable definition table
--- @return table GRIP-EMS varDef table
function LI.MapLegacyVariable(legacyVarName, legacyVarDef)
    local events = ""
    if legacyVarDef.eventNames and type(legacyVarDef.eventNames) == "table" and #legacyVarDef.eventNames > 0 then
        events = table.concat(legacyVarDef.eventNames, ", ")
    end

    local ts = legacyVarDef.LastUpdated or time()

    return {
        name = legacyVarName,
        funct = legacyVarDef.funct or "",
        events = events,
        author = legacyVarDef.Author or "",
        version = "1",
        comments = legacyVarDef.comments or "",
        createdAt = ts,
        updatedAt = ts,
        disabled = false,
    }
end

--- Import a single mapped variable into the VariableStore.
--- Validates name and function body; skips if variable already exists.
--- @param name string Variable name
--- @param varDef table Mapped GRIP-EMS varDef
--- @param results table Import results accumulator
--- @return boolean success
--- @return string|nil error Error message on failure
function LI.ImportVariable(name, varDef, results)
    -- Validate name
    local validName, nameErr = VS:ValidateName(name)
    if not validName then
        results.warnings[#results.warnings + 1] = "Variable '" .. tostring(name) .. "': " .. tostring(nameErr)
        return false, nameErr
    end

    -- Skip if already exists
    if VS:Get(name) then
        results.varsSkipped = results.varsSkipped + 1
        return true
    end

    -- Validate function body (warn but still save)
    local validFunc, funcErr = VS:ValidateFunction(varDef.funct)
    if not validFunc then
        results.warnings[#results.warnings + 1] = "Variable '"
            .. name
            .. "': invalid function body - "
            .. tostring(funcErr)
    end

    VS:Set(name, varDef)
    results.varsImported = results.varsImported + 1
    return true
end

--- Compile an If action into WoW conditional macro syntax.
--- @param action table Imported If action { Condition, Actions, ElseActions }
--- @return table Array of macrotext strings
--- @return table|nil Array of warning strings
function LI.CompileConditional(action)
    if not action then
        return {}, { "Nil conditional action" }
    end

    local condition = action.Condition or ""
    local warnings = {}

    -- Get the primary spell: check Spell directly on action first (CBOR
    -- encodes the spell on the If action itself), then fall back to the
    -- Actions sub-table used by older format variants.
    local primarySpell = nil
    if action.Spell then
        primarySpell = LI.ResolveSpell(action.Spell)
    elseif action.Actions and action.Actions[1] then
        local subAction = action.Actions[1]
        if subAction.Spell then
            primarySpell = LI.ResolveSpell(subAction.Spell)
        elseif subAction.Type == "If" then
            -- Nested If: flatten recursively
            local nested, nWarnings = LI.CompileConditional(subAction)
            if nWarnings then
                for _, w in ipairs(nWarnings) do
                    warnings[#warnings + 1] = w
                end
            end
            return nested, (#warnings > 0) and warnings or nil
        end
    end

    if not primarySpell or primarySpell == "" then
        return {}, { "If action with no Spell or Actions skipped" }
    end

    -- Check for ElseActions
    local elseSpell = nil
    if action.ElseActions and action.ElseActions[1] then
        local elseAction = action.ElseActions[1]
        if elseAction.Spell then
            elseSpell = LI.ResolveSpell(elseAction.Spell)
        end
    end

    local text
    if elseSpell and elseSpell ~= "" then
        -- /cast [condition] spell1; spell2
        text = "/cast [" .. condition .. "] " .. primarySpell .. "; " .. elseSpell
    else
        -- /cast [condition] spell1
        text = "/cast [" .. condition .. "] " .. primarySpell
    end

    return { text }, (#warnings > 0) and warnings or nil
end
