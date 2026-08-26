-- GRIP-EMS: Export Preview
-- Build structured export data, resolve variable dependencies, detect embedded
-- sequence references, and encode multi-sequence GRIP1 collection payloads.

local ADDON_NAME, GRIPEMS = ...
local D = GRIPEMS.Defaults
local L = LibStub("AceLocale-3.0"):GetLocale("GRIP-EMS")
local S = GRIPEMS.Serialization

local GE = GRIPEMS.GRIPExport
local Engine = GRIPEMS.Engine
local VS = GRIPEMS.VariableStore

---------------------------------------------------------------------------
-- GE.BuildExportList()
-- Scan Engine.sequences and VS:GetAll() to build structured export data.
---------------------------------------------------------------------------

--- Build a structured list of all exportable sequences and variables.
--- @return table { sequences = {...}, variables = {...} }
function GE.BuildExportList()
    local result = {
        sequences = {},
        variables = {},
    }

    -- Scan all active sequences
    for seqName, entry in pairs(Engine.sequences) do
        if entry and entry.data then
            local seqData = entry.data

            -- Count versions and steps from active version
            local versionCount = 0
            if seqData.versions and type(seqData.versions) == "table" then
                versionCount = #seqData.versions
            end
            local ver = Engine:GetActiveVersion(seqData)
            local stepCount = ver and ver.steps and #ver.steps or 0
            local stepFunction = ver and ver.stepFunction or D.STEP_SEQUENTIAL

            -- Scan all version steps for variable dependencies
            local varDeps = {}
            local varDepsSet = {}
            if seqData.versions and type(seqData.versions) == "table" then
                for _, v in ipairs(seqData.versions) do
                    if v and v.steps then
                        for _, step in ipairs(v.steps) do
                            if type(step) == "string" then
                                for varName in step:gmatch(D.VAR_PATTERN) do
                                    if not varDepsSet[varName] then
                                        varDepsSet[varName] = true
                                        varDeps[#varDeps + 1] = varName
                                    end
                                end
                            end
                        end
                    end
                end
            end
            -- Fallback: legacy flat steps
            if seqData.steps then
                for _, step in ipairs(seqData.steps) do
                    if type(step) == "string" then
                        for varName in step:gmatch(D.VAR_PATTERN) do
                            if not varDepsSet[varName] then
                                varDepsSet[varName] = true
                                varDeps[#varDeps + 1] = varName
                            end
                        end
                    end
                end
            end

            -- Scan all version steps for embedded sequence references
            local embeddedDeps = {}
            local embeddedSet = {}
            local clickPattern = "/click GRIPEMS_(%S+)"
            if seqData.versions and type(seqData.versions) == "table" then
                for _, v in ipairs(seqData.versions) do
                    if v and v.steps then
                        for _, step in ipairs(v.steps) do
                            if type(step) == "string" then
                                for refName in step:gmatch(clickPattern) do
                                    if not embeddedSet[refName] then
                                        embeddedSet[refName] = true
                                        embeddedDeps[#embeddedDeps + 1] = refName
                                    end
                                end
                            end
                        end
                    end
                end
            end
            -- Fallback: legacy flat steps
            if seqData.steps then
                for _, step in ipairs(seqData.steps) do
                    if type(step) == "string" then
                        for refName in step:gmatch(clickPattern) do
                            if not embeddedSet[refName] then
                                embeddedSet[refName] = true
                                embeddedDeps[#embeddedDeps + 1] = refName
                            end
                        end
                    end
                end
            end

            result.sequences[#result.sequences + 1] = {
                name = seqName,
                icon = seqData.icon or D.QUESTION_MARK_ICON,
                versionCount = versionCount,
                stepCount = stepCount,
                stepFunction = stepFunction,
                varDeps = varDeps,
                embeddedDeps = embeddedDeps,
                selected = false,
            }
        end
    end

    -- Sort sequences alphabetically
    table.sort(result.sequences, function(a, b)
        return a.name < b.name
    end)

    -- Scan all variables
    local allVars = VS:GetAll()
    for varName, _ in pairs(allVars) do
        result.variables[#result.variables + 1] = {
            name = varName,
            value = VS:GetCachedValue(varName),
            referencedBy = VS:GetReferences(varName),
            autoSelected = false,
            selected = false,
        }
    end

    -- Sort variables alphabetically
    table.sort(result.variables, function(a, b)
        return a.name < b.name
    end)

    return result
end

---------------------------------------------------------------------------
-- GE.ResolveVariableDeps(selectedSeqNames)
-- Given selected sequence names, return set of variable names they reference.
---------------------------------------------------------------------------

--- Resolve variable dependencies for a set of selected sequences.
--- @param selectedSeqNames table Array or set of sequence names
--- @return table Set of variable names (name -> true)
function GE.ResolveVariableDeps(selectedSeqNames)
    if not selectedSeqNames then
        return {}
    end

    -- Build a lookup set
    local nameSet = {}
    if #selectedSeqNames > 0 then
        -- Array form
        for _, name in ipairs(selectedSeqNames) do
            nameSet[name] = true
        end
    else
        -- Already a set
        nameSet = selectedSeqNames
    end

    local varSet = {}
    for seqName in pairs(nameSet) do
        local entry = Engine.sequences[seqName]
        if entry and entry.data then
            local seqData = entry.data
            -- Scan versioned steps
            if seqData.versions and type(seqData.versions) == "table" then
                for _, ver in ipairs(seqData.versions) do
                    if ver and ver.steps then
                        for _, step in ipairs(ver.steps) do
                            if type(step) == "string" then
                                for varName in step:gmatch(D.VAR_PATTERN) do
                                    varSet[varName] = true
                                end
                            end
                        end
                    end
                end
            end
            -- Fallback: legacy flat steps
            if seqData.steps then
                for _, step in ipairs(seqData.steps) do
                    if type(step) == "string" then
                        for varName in step:gmatch(D.VAR_PATTERN) do
                            varSet[varName] = true
                        end
                    end
                end
            end
        end
    end

    -- Transitive: scan variable function bodies for ~var~ references
    local MAX_DEPTH = 8
    local checked = {}
    local function scanVarDeps(varName, depth)
        if checked[varName] or depth > MAX_DEPTH then
            return
        end
        checked[varName] = true
        local varDef = VS and VS:Get(varName) or nil
        if varDef and varDef.funct and type(varDef.funct) == "string" then
            for depName in varDef.funct:gmatch(D.VAR_PATTERN) do
                if not varSet[depName] then
                    varSet[depName] = true
                    scanVarDeps(depName, depth + 1)
                end
            end
        end
    end
    -- Snapshot keys to avoid mutation during iteration
    local initialVars = {}
    for varName in pairs(varSet) do
        initialVars[#initialVars + 1] = varName
    end
    for _, varName in ipairs(initialVars) do
        scanVarDeps(varName, 1)
    end

    return varSet
end

---------------------------------------------------------------------------
-- GE.DetectMissingEmbeddedDeps(selectedSeqNames)
-- Find embedded deps that reference sequences NOT in the selected set.
---------------------------------------------------------------------------

--- Detect embedded sequence references that are not selected for export.
--- @param selectedSeqNames table Array or set of sequence names
--- @return table Array of warning strings
function GE.DetectMissingEmbeddedDeps(selectedSeqNames)
    if not selectedSeqNames then
        return {}
    end

    -- Build a lookup set
    local nameSet = {}
    if #selectedSeqNames > 0 then
        for _, name in ipairs(selectedSeqNames) do
            nameSet[name] = true
        end
    else
        nameSet = selectedSeqNames
    end

    local warnings = {}
    local clickPattern = "/click GRIPEMS_(%S+)"

    for seqName in pairs(nameSet) do
        local entry = Engine.sequences[seqName]
        if entry and entry.data then
            local seqData = entry.data
            local checked = {}
            -- Scan versioned steps
            if seqData.versions and type(seqData.versions) == "table" then
                for _, ver in ipairs(seqData.versions) do
                    if ver and ver.steps then
                        for _, step in ipairs(ver.steps) do
                            if type(step) == "string" then
                                for refName in step:gmatch(clickPattern) do
                                    if not nameSet[refName] and not checked[refName] then
                                        checked[refName] = true
                                        warnings[#warnings + 1] =
                                            string.format(L["GEMS_EXPORT_PICK_EMBEDDED_WARN"], seqName, refName)
                                    end
                                end
                            end
                        end
                    end
                end
            end
            -- Fallback: legacy flat steps
            if seqData.steps then
                for _, step in ipairs(seqData.steps) do
                    if type(step) == "string" then
                        for refName in step:gmatch(clickPattern) do
                            if not nameSet[refName] and not checked[refName] then
                                checked[refName] = true
                                warnings[#warnings + 1] =
                                    string.format(L["GEMS_EXPORT_PICK_EMBEDDED_WARN"], seqName, refName)
                            end
                        end
                    end
                end
            end
        end
    end

    return warnings
end

---------------------------------------------------------------------------
-- GE.ExportCollection(seqNames, varNames)
-- Build and encode a GRIP1 collection payload.
---------------------------------------------------------------------------

--- Export multiple sequences and variables as a GRIP1 collection string.
--- Falls back to single-format GE.Export() if only 1 sequence and 0 variables.
--- @param seqNames table Array of sequence names to export
--- @param varNames table Array of variable names to export
--- @param exportMeta table|nil Optional metadata (collectionName, author, etc.)
--- @return boolean ok
--- @return string result Encoded string on success, error message on failure
function GE.ExportCollection(seqNames, varNames, exportMeta)
    if not seqNames or #seqNames == 0 then
        return false, "No sequences selected for export"
    end

    -- Single sequence, no variables: use existing single-format for backward compat
    if #seqNames == 1 and (not varNames or #varNames == 0) then
        return GE.Export(seqNames[1])
    end

    local payload = {
        format = "GRIP-EMS",
        version = D.GRIP_FORMAT_VERSION,
        type = "COLLECTION",
        locale = GetLocale(),
        sequences = {},
        variables = {},
    }

    for _, seqName in ipairs(seqNames) do
        local entry = Engine.sequences[seqName]
        if entry and entry.data then
            local seqData = entry.data

            -- Prepare export versions (deep-copy + spell tag translation)
            local exportVersions = GE.PrepareExportVersions(seqData)

            payload.sequences[seqName] = {
                icon = seqData.icon or D.QUESTION_MARK_ICON,
                versions = exportVersions,
                defaultVersion = seqData.defaultVersion or 1,
                contextOverrides = seqData.contextOverrides,
            }
        end
    end

    if varNames then
        for _, varName in ipairs(varNames) do
            local varDef = VS:Get(varName)
            if varDef then
                -- Deep-copy relevant fields, exclude name (redundant)
                local cleaned = {}
                if varDef.funct then
                    cleaned.funct = varDef.funct
                end
                if varDef.events then
                    cleaned.events = varDef.events
                end
                cleaned.comments = varDef.comments or varDef.description or nil
                if varDef.disabled then
                    cleaned.disabled = varDef.disabled
                end
                if varDef.author then
                    cleaned.author = varDef.author
                end
                if varDef.version then
                    cleaned.version = varDef.version
                end
                payload.variables[varName] = cleaned
            end
        end
    end

    -- Embed export metadata if provided
    if exportMeta then
        payload.exportMeta = {
            collectionName = exportMeta.collectionName,
            author = exportMeta.includeAuthor and exportMeta.author or nil,
            description = exportMeta.includeDescription and exportMeta.description or nil,
            talentString = exportMeta.includeTalent and exportMeta.talentString or nil,
            url = exportMeta.includeUrl and exportMeta.url or nil,
        }
    end

    local ok, encoded = S.Encode(payload, D.GRIP1_PREFIX)
    if not ok then
        return false, "Export encoding failed: " .. tostring(encoded)
    end

    return true, encoded
end
