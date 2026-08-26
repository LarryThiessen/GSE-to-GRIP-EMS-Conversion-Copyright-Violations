-- GRIP-EMS: Import Preview
-- Pure-data preview engine for import strings: decode and analyze without side effects

local ADDON_NAME, GRIPEMS = ...
local L = LibStub("AceLocale-3.0"):GetLocale("GRIP-EMS")
local D = GRIPEMS.Defaults
local S = GRIPEMS.Serialization
local GI = GRIPEMS.GSEImport
local VS = GRIPEMS.VariableStore
local SC = GRIPEMS.SpellCache

--- Translate spell ID tags to localized names in all versions of a sequence.
--- Mutates the sequence table in place (safe on freshly decoded data).
--- @param seq table Sequence payload with .versions array
local function TranslateSequenceVersions(seq)
    if not seq or not seq.versions or type(seq.versions) ~= "table" then
        return
    end
    for _, ver in ipairs(seq.versions) do
        if ver.steps then
            for si, step in ipairs(ver.steps) do
                if type(step) == "string" then
                    ver.steps[si] = SC:TranslateMacrotext(step, "toNames")
                end
            end
        end
        if ver.keyPress and type(ver.keyPress) == "string" then
            ver.keyPress = SC:TranslateMacrotext(ver.keyPress, "toNames")
        end
        if ver.keyRelease and type(ver.keyRelease) == "string" then
            ver.keyRelease = SC:TranslateMacrotext(ver.keyRelease, "toNames")
        end
    end
end

--- Generate a structured preview of an encoded import string.
--- Decodes and analyzes the string WITHOUT any side effects: no ActivateSequence,
--- no VariableStore writes, no callbacks fired.
--- @param encodedString string The full encoded string (with prefix)
--- @return table Preview result table (ok, format, sequences, variables, warnings, counts)
function GI.Preview(encodedString)
    if not encodedString or encodedString == "" then
        return { ok = false, error = "No import string provided" }
    end

    local format = S.DetectFormat(encodedString)

    -- GRIP1 native format
    if format == "GRIP1" then
        return GI._PreviewGRIP1(encodedString)
    end

    -- Legacy format (or unknown)
    local ok, decoded = S.Decode(encodedString)
    if not ok then
        return { ok = false, error = decoded }
    end

    local result = {
        ok = true,
        format = "GSE3",
        sequences = {},
        variables = {},
        warnings = {},
    }

    -- COLLECTION format
    if type(decoded) == "table" and decoded.type == "COLLECTION" then
        local payload = decoded.payload
        if not payload or not payload.Sequences then
            return { ok = false, error = "COLLECTION has no Sequences" }
        end

        for seqName, seqValue in pairs(payload.Sequences) do
            if type(seqValue) == "string" then
                -- Double-encoded inner sequence
                local innerOk, innerDecoded = S.Decode(seqValue)
                if innerOk and type(innerDecoded) == "table"
                    and type(innerDecoded[1]) == "string"
                    and type(innerDecoded[2]) == "table" then
                    GI._PreviewAddSequence(result, innerDecoded[1], innerDecoded[2])
                else
                    result.warnings[#result.warnings + 1] =
                        string.format("'%s': failed to decode inner sequence", tostring(seqName))
                end
            elseif type(seqValue) == "table" then
                -- Raw table (12.0.1+ style)
                GI._PreviewAddSequence(result, seqName, seqValue)
            end
        end

        -- Preview variables from COLLECTION payload
        if payload.Variables and type(payload.Variables) == "table" then
            for varName, varValue in pairs(payload.Variables) do
                if type(varValue) == "string" then
                    local varOk, varDecoded = S.Decode(varValue)
                    if varOk and type(varDecoded) == "table" then
                        if type(varDecoded[1]) == "string"
                            and type(varDecoded[2]) == "table" then
                            local gripVar = GI.MapGSEVariable(varDecoded[1], varDecoded[2])
                            GI._PreviewAddVariable(result, varDecoded[1], gripVar)
                        else
                            local gripVar = GI.MapGSEVariable(varName, varDecoded)
                            GI._PreviewAddVariable(result, varName, gripVar)
                        end
                    else
                        result.warnings[#result.warnings + 1] =
                            "Variable '" .. varName .. "': failed to decode"
                    end
                elseif type(varValue) == "table" then
                    local gripVar = GI.MapGSEVariable(varName, varValue)
                    GI._PreviewAddVariable(result, varName, gripVar)
                end
            end
        end

    elseif type(decoded) == "table" and decoded.Command then
        return { ok = false, error = "Command format (addon transmission) is not supported" }

    elseif type(decoded) == "table"
        and type(decoded[1]) == "string"
        and type(decoded[2]) == "table" then
        -- Simple array format: { name, sequence }
        GI._PreviewAddSequence(result, decoded[1], decoded[2])

    else
        return { ok = false, error = L["Unknown import format"] }
    end

    -- Compute summary counts
    GI._PreviewComputeCounts(result)

    if result.totalSequences == 0 and result.totalVariables == 0 then
        result.warnings[#result.warnings + 1] = L["GEMS_IMPORT_PREVIEW_EMPTY"]
    end

    return result
end

--- Preview a GRIP1 native import string.
--- @param encodedString string The !GRIP1!-prefixed encoded string
--- @return table Preview result table
function GI._PreviewGRIP1(encodedString)
    local ok, decoded, detectedFormat = S.Decode(encodedString)
    if not ok then
        return { ok = false, error = decoded }
    end
    if detectedFormat ~= "GRIP1" then
        return { ok = false, error = "Not a GRIP-EMS export string" }
    end

    -- Validate payload structure
    if type(decoded) ~= "table" or decoded.format ~= "GRIP-EMS" then
        return { ok = false, error = "Invalid GRIP1 payload" }
    end
    if not decoded.version or decoded.version > D.GRIP_FORMAT_VERSION then
        return { ok = false, error = "Unsupported format version: " .. tostring(decoded.version) }
    end

    -- v3+: translate spell ID tags to localized names for preview display
    if decoded.version >= 3 then
        if decoded.type == "COLLECTION" then
            for _, seqPayload in pairs(decoded.sequences or {}) do
                TranslateSequenceVersions(seqPayload)
            end
        elseif decoded.sequence then
            TranslateSequenceVersions(decoded.sequence)
        end
    end

    -- COLLECTION format (T2-12: multi-sequence + variable export)
    if decoded.type == "COLLECTION" then
        local Engine = GRIPEMS.Engine
        local colResult = {
            ok = true, format = "GRIP1", sequences = {}, variables = {},
            warnings = {},
        }
        -- Iterate decoded.sequences (name -> seqPayload)
        for seqName, seqPayload in pairs(decoded.sequences or {}) do
            local ver = seqPayload.versions
                and seqPayload.versions[seqPayload.defaultVersion or 1]
            local stepCount = ver and ver.steps and #ver.steps or 0
            local versionCount = seqPayload.versions
                and #seqPayload.versions or 0
            local exists = (Engine and Engine.sequences
                and Engine.sequences[seqName] ~= nil)
            colResult.sequences[#colResult.sequences + 1] = {
                name = seqName,
                icon = seqPayload.icon or D.QUESTION_MARK_ICON,
                versionCount = versionCount,
                stepCount = stepCount,
                status = exists and "exists" or "new",
                selected = true,
                conflictAction = exists and "skip" or "import",
                seqObj = seqPayload,
                isCollection = true,
            }
        end
        -- Iterate decoded.variables (name -> varDef)
        for varName, varDef in pairs(decoded.variables or {}) do
            local existingVar = VS and VS.Get and VS:Get(varName)
            colResult.variables[#colResult.variables + 1] = {
                name = varName,
                status = existingVar and "exists" or "new",
                selected = true,
                conflictAction = existingVar and "skip" or "import",
                varDef = varDef,
            }
        end
        table.sort(colResult.sequences,
            function(a, b) return a.name < b.name end)
        table.sort(colResult.variables,
            function(a, b) return a.name < b.name end)
        GI._PreviewComputeCounts(colResult)
        return colResult
    end

    if not decoded.name or decoded.name == "" then
        return { ok = false, error = "Payload has no sequence name" }
    end
    if not decoded.sequence then
        return { ok = false, error = "Payload has no sequence data" }
    end

    local seq = decoded.sequence
    local seqName = decoded.name

    -- Determine version/step counts from payload
    local versionCount = 0
    local stepCount = 0
    local stepFunction = D.STEP_SEQUENTIAL
    local icon = seq.icon or D.QUESTION_MARK_ICON

    if seq.versions and type(seq.versions) == "table" and next(seq.versions) then
        versionCount = #seq.versions
        local defaultIdx = seq.defaultVersion or 1
        local defaultVer = seq.versions[defaultIdx] or seq.versions[1]
        if defaultVer then
            stepCount = defaultVer.steps and #defaultVer.steps or 0
            stepFunction = defaultVer.stepFunction or D.STEP_SEQUENTIAL
        end
    elseif seq.steps then
        versionCount = 1
        stepCount = #seq.steps
        stepFunction = seq.stepFunction or D.STEP_SEQUENTIAL
    end

    -- Status check
    local status = "new"
    local existingStepCount = nil
    if GRIPEMS.Engine and GRIPEMS.Engine.sequences
        and GRIPEMS.Engine.sequences[seqName] then
        status = "exists"
        local entry = GRIPEMS.Engine.sequences[seqName]
        if entry.data then
            local ver = GRIPEMS.Engine:GetActiveVersion(entry.data)
            if ver and ver.steps then
                existingStepCount = #ver.steps
            end
        end
    end

    local result = {
        ok = true,
        format = "GRIP1",
        sequences = {
            {
                name = seqName,
                seqObj = decoded,
                versionCount = versionCount,
                stepCount = stepCount,
                stepFunction = stepFunction,
                icon = icon,
                status = status,
                existingStepCount = existingStepCount,
                conflictAction = (status == "exists") and "skip" or "import",
                opts = nil,
            },
        },
        variables = {},
        warnings = {},
    }

    GI._PreviewComputeCounts(result)
    return result
end

--- Add an imported sequence to a preview result (no side effects).
--- @param result table The preview result being built
--- @param seqName string Sequence name
--- @param sequence table Imported sequence object
function GI._PreviewAddSequence(result, seqName, sequence)
    if not seqName or not sequence then
        result.warnings[#result.warnings + 1] = "Skipped entry with missing name or data"
        return
    end

    local macros = sequence.Macros or sequence.MacroVersions or sequence.Versions
    if not macros or #macros == 0 then
        result.warnings[#result.warnings + 1] =
            string.format("'%s': no macro versions found", tostring(seqName))
        return
    end

    -- Pick default version index
    local defaultIdx = 1
    if sequence.MetaData and sequence.MetaData.Default then
        defaultIdx = tonumber(sequence.MetaData.Default) or 1
    end
    if defaultIdx < 1 or defaultIdx > #macros then
        defaultIdx = 1
    end

    -- Compile default version to count steps (read-only, no side effects)
    local defaultMacro = macros[defaultIdx]
    local stepCount = 0
    local stepFunction = D.STEP_SEQUENTIAL

    if defaultMacro then
        -- Save and restore compile stats to avoid side effects
        local savedStats = GI._compileStats
        GI._compileStats = { pauses = 0, embeds = 0, truncated = 0 }

        local compiled = GI.CompileMacroVersion(defaultMacro)
        stepCount = compiled.steps and #compiled.steps or 0

        -- Collect compile warnings
        if compiled.warnings then
            for _, w in ipairs(compiled.warnings) do
                result.warnings[#result.warnings + 1] = seqName .. ": " .. w
            end
        end

        GI._compileStats = savedStats

        -- Read step function
        if defaultMacro.Step then
            local s = defaultMacro.Step
            if s == "Sequential" or s == "Priority" or s == "Random" then
                if s == "Priority" then
                    stepFunction = D.STEP_SEQUENTIAL
                else
                    stepFunction = s
                end
            end
        elseif defaultMacro.StepFunction then
            local s = defaultMacro.StepFunction
            if s == "Sequential" or s == "Priority" or s == "Random" then
                if s == "Priority" then
                    stepFunction = D.STEP_SEQUENTIAL
                else
                    stepFunction = s
                end
            end
        end
    end

    -- Extract icon from metadata
    local icon = D.QUESTION_MARK_ICON
    if sequence.MetaData and sequence.MetaData.Icon then
        icon = sequence.MetaData.Icon
    end

    -- Extract opts from metadata
    local opts = nil
    if sequence.MetaData then
        opts = {
            author = sequence.MetaData.Author,
            description = sequence.MetaData.Description,
            specID = sequence.MetaData.SpecID,
        }
    end

    -- Status: check if name already exists in engine
    local status = "new"
    local existingStepCount = nil
    if GRIPEMS.Engine and GRIPEMS.Engine.sequences
        and GRIPEMS.Engine.sequences[seqName] then
        status = "exists"
        local entry = GRIPEMS.Engine.sequences[seqName]
        if entry.data then
            local ver = GRIPEMS.Engine:GetActiveVersion(entry.data)
            if ver and ver.steps then
                existingStepCount = #ver.steps
            end
        end
    end

    result.sequences[#result.sequences + 1] = {
        name = seqName,
        seqObj = sequence,
        versionCount = #macros,
        stepCount = stepCount,
        stepFunction = stepFunction,
        icon = icon,
        status = status,
        existingStepCount = existingStepCount,
        conflictAction = (status == "exists") and "skip" or "import",
        opts = opts,
    }
end

--- Add a variable to a preview result (no side effects).
--- @param result table The preview result being built
--- @param name string Variable name
--- @param varDef table Mapped GRIP-EMS varDef
function GI._PreviewAddVariable(result, name, varDef)
    if not name or not varDef then return end

    local status = "new"
    if VS and VS.Get and VS:Get(name) then
        status = "exists"
    end

    result.variables[#result.variables + 1] = {
        name = name,
        varDef = varDef,
        status = status,
        conflictAction = (status == "exists") and "skip" or "import",
    }
end

--- Compute summary counts on a preview result table.
--- @param result table The preview result table to update
function GI._PreviewComputeCounts(result)
    local totalSeq = #result.sequences
    local totalVar = #result.variables
    local newSeq = 0
    local existingSeq = 0

    for _, entry in ipairs(result.sequences) do
        if entry.status == "new" then
            newSeq = newSeq + 1
        else
            existingSeq = existingSeq + 1
        end
    end

    result.totalSequences = totalSeq
    result.totalVariables = totalVar
    result.newSequences = newSeq
    result.existingSequences = existingSeq
end

--- Commit selected sequences and variables from a preview.
--- Applies user selections: import, skip, or rename each entry.
--- @param preview table The table returned by GI.Preview()
--- @param selections table User selections per index
--- @return boolean success
--- @return table results Standard import results table
function GI.CommitSelected(preview, selections)
    if not preview or not preview.ok then
        return false, "Invalid preview"
    end

    selections = selections or {}
    local seqSelections = selections.sequences or {}
    local varSelections = selections.variables or {}

    local results = {
        names = {}, warnings = {}, count = 0, stepCounts = {},
        varsImported = 0, varsSkipped = 0, contextOverridesImported = 0,
        versionsDropped = 0, pausesSkipped = 0, embedsSkipped = 0,
        truncatedSteps = 0, stepFunctions = {},
    }

    -- Process sequences
    for i, entry in ipairs(preview.sequences) do
        local sel = seqSelections[i]
        if sel and sel.selected
            and (sel.action == "import" or sel.action == "rename") then
            local name = entry.name
            if sel.action == "rename" then
                name = GI._GenerateRenameName(name)
            end

            if preview.format == "GRIP1" and entry.isCollection then
                -- GRIP1 COLLECTION entry: seqObj IS the sequence payload
                local seq = entry.seqObj
                local seqData = {
                    name = name,
                    icon = seq.icon or D.QUESTION_MARK_ICON,
                    versions = seq.versions,
                    defaultVersion = seq.defaultVersion or 1,
                    contextOverrides = seq.contextOverrides or {},
                    author = "",
                    version = "1",
                    description = "",
                    classID = select(3, UnitClass("player")) or 0,
                    createdAt = time(),
                    updatedAt = time(),
                }
                local ver = GRIPEMS.Engine:GetActiveVersion(seqData)
                if ver and ver.steps and #ver.steps > 0 then
                    GRIPEMS.Engine:ActivateSequence(name, seqData)
                    if _G.GRIP_EMS_CHAR then
                        GRIP_EMS_CHAR.sequences = GRIP_EMS_CHAR.sequences or {}
                        GRIP_EMS_CHAR.sequences[name] = seqData
                    end
                    results.names[#results.names + 1] = name
                    results.stepCounts[name] = #ver.steps
                    results.stepFunctions[name] = ver.stepFunction
                        or D.STEP_SEQUENTIAL
                    results.count = results.count + 1
                end
            elseif preview.format == "GRIP1" then
                -- DRIFT RISK: This block rebuilds seqData manually instead of calling
                -- GRIPExport.ImportNative. If ImportNative gains new fields, update
                -- this block to match. See Backlog T3 "Import Polish" for refactor.
                -- GRIP1: rebuild seqData from stored decoded payload
                local seq = entry.seqObj.sequence
                local seqData = {
                    name = name,
                    icon = seq.icon or D.QUESTION_MARK_ICON,
                    autoIcon = seq.autoIcon,
                    author = "",
                    version = "1",
                    description = "",
                    classID = select(3, UnitClass("player")) or 0,
                    specID = nil,
                    createdAt = time(),
                    updatedAt = time(),
                }
                if seq.versions and type(seq.versions) == "table"
                    and next(seq.versions) then
                    seqData.versions = seq.versions
                    seqData.defaultVersion = seq.defaultVersion or 1
                elseif seq.steps then
                    seqData.steps = seq.steps
                    seqData.stepFunction = seq.stepFunction or D.STEP_SEQUENTIAL
                    seqData.resetOnCombat = seq.resetCombat or false
                    seqData.resetOnTarget = seq.resetTarget or false
                    GRIPEMS.Engine:MigrateSequenceFormat(seqData)
                end
                seqData.contextOverrides = seqData.contextOverrides or {}

                GRIPEMS.Engine:ActivateSequence(name, seqData)
                results.names[#results.names + 1] = name
                local ver = GRIPEMS.Engine:GetActiveVersion(seqData)
                results.stepCounts[name] = ver and #ver.steps or 0
                results.stepFunctions[name] = ver and ver.stepFunction
                    or D.STEP_SEQUENTIAL
                results.count = results.count + 1
            else
                -- Legacy format: reuse existing ProcessSequence
                local importOk, importErr = GI.ProcessSequence(
                    name, entry.seqObj, results, entry.opts)
                if not importOk then
                    results.warnings[#results.warnings + 1] =
                        string.format("'%s': %s", tostring(name),
                            tostring(importErr))
                end
            end
        end
    end

    -- Process variables
    for i, entry in ipairs(preview.variables) do
        local sel = varSelections[i]
        if sel and sel.selected and sel.action == "import" then
            GI.ImportVariable(entry.name, entry.varDef, results)
        end
    end

    -- Fire callback
    if results.count > 0 and GRIPEMS.Fire then
        GRIPEMS:Fire("SEQUENCE_IMPORTED", results)
    end

    return true, results
end

--- Generate a rename-safe name by appending " (2)" or incrementing existing suffix.
--- @param name string Original sequence name
--- @return string New name with rename suffix
function GI._GenerateRenameName(name)
    if not name then return "Unnamed (2)" end

    -- Check for existing " (N)" suffix
    local base, num = name:match("^(.+) %((%d+)%)$")
    if base and num then
        return base .. " (" .. (tonumber(num) + 1) .. ")"
    end

    return name .. " (2)"
end
