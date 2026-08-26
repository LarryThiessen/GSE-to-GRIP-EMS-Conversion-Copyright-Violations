-- GRIP-EMS: ExportPreview
-- Created: 2026-03-20
-- Updated: 2026-07-02
-- Patch: 12.0.7.68256 Midnight (Retail LIVE)

-- GRIP-EMS: Export Preview
-- Build structured export data, resolve variable dependencies, detect embedded
-- sequence references, and encode multi-sequence GRIP1 collection payloads.

local ADDON_NAME, GRIPEMS = ...
local D = GRIPEMS.Defaults
local L = LibStub("AceLocale-3.0"):GetLocale("GRIP-EMS", true)
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
        macros = {},
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

    -- Scan all WoW macros (account + per-character)
    local maxMacros = (MAX_ACCOUNT_MACROS or 120) + (MAX_CHARACTER_MACROS or 18)
    for macid = 1, maxMacros do
        local mname, micon, mbody = GetMacroInfo(macid)
        if mname and mname ~= "" then
            local scope = "a"
            if macid > (MAX_ACCOUNT_MACROS or 120) then
                scope = "p"
            end
            result.macros[#result.macros + 1] = {
                name = mname,
                icon = micon or D.QUESTION_MARK_ICON,
                body = mbody or "",
                scope = scope,
                autoSelected = false,
                manualSelect = false,
                manualDeselect = false,
                selected = false,
            }
        end
    end

    table.sort(result.macros, function(a, b)
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
-- GE.ResolveMacroDeps(selectedSeqNames)
-- Given selected sequence names, return set of macro names referenced by
-- their MetaData.Dependencies.Macros lists. Mirrors ResolveVariableDeps.
---------------------------------------------------------------------------

--- Resolve macro dependencies for a set of selected sequences.
--- @param selectedSeqNames table Array or set of sequence names
--- @return table Set of macro names (name -> true)
function GE.ResolveMacroDeps(selectedSeqNames)
    if not selectedSeqNames then
        return {}
    end

    local nameSet = {}
    if #selectedSeqNames > 0 then
        for _, name in ipairs(selectedSeqNames) do
            nameSet[name] = true
        end
    else
        nameSet = selectedSeqNames
    end

    local macSet = {}
    for seqName in pairs(nameSet) do
        local entry = Engine.sequences[seqName]
        if entry and entry.data then
            local meta = entry.data.MetaData
            local deps = meta and meta.Dependencies
            if deps and type(deps.Macros) == "table" then
                for _, macName in ipairs(deps.Macros) do
                    macSet[macName] = true
                end
            end
        end
    end

    return macSet
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

--- Build the GRIP-EMS COLLECTION payload for a selection. Shared by the
--- native encoder (GE.ExportCollection) and plugin export providers
--- (GE.SerializeWithProvider) so both serialize the identical canonical
--- structure. Pure data; no encode step.
--- @param seqNames table Array of sequence names
--- @param varNames table|nil Array of variable names
--- @param macNames table|nil Array of macro names
--- @param exportMeta table|nil Optional metadata
--- @return table payload COLLECTION payload table
function GE.BuildCollectionPayload(seqNames, varNames, macNames, exportMeta)
    local payload = {
        format = "GRIP-EMS",
        version = D.GRIP_FORMAT_VERSION,
        addonVersion = GRIPEMS.version,
        type = "COLLECTION",
        locale = GetLocale(),
        exportedAt = time(),
        schemaRev = D.EMS_EXPORT_SCHEMA_REV,
        sequences = {},
        variables = {},
        Macros = {},
    }
    -- v2.3.3 Phase 1: build-context parity with the single-sequence envelope.
    if GetBuildInfo then
        local wowPatch, wowBuild, _, wowInterface = GetBuildInfo()
        payload.wowPatch = wowPatch
        payload.wowBuild = wowBuild
        payload.wowInterface = wowInterface
    end

    -- v2.3.3 Phase 1: envelope privacy is the strictest mode across the
    -- config default and every selected sequence's privacyMode
    -- (private > pseudonymous > public), so one private sequence in the
    -- selection hides the exporter identity for the whole collection.
    local MODE_RANK = { public = 1, pseudonymous = 2, private = 3 }
    local strictestMode = (GRIP_EMS_DB and GRIP_EMS_DB.config and GRIP_EMS_DB.config.privacyDefault)
        or D.PRIVACY_MODE_DEFAULT
        or "public"
    if not MODE_RANK[strictestMode] then
        strictestMode = "public"
    end
    -- Distinct class/spec coverage for exportMeta.
    local classIDSet, specIDSet = {}, {}

    for _, seqName in ipairs(seqNames) do
        local entry = Engine.sequences[seqName]
        if entry and entry.data then
            local seqData = entry.data

            -- v2.1.0 Phase D: scrub the local user's identity per the
            -- per-sequence privacyMode (defaults to seq.privacyMode then to
            -- config.privacyDefault then to "public"). Foreign-author
            -- entries (forkedFromChain ancestors, other modifiers) stay
            -- visible -- only the local user's identity is rewritten.
            -- BuildExportPayload deep-copies, so the scrub never mutates
            -- the local sequence in GRIPEMS.Engine.sequences.
            local Identity = GRIPEMS.Identity
            if Identity and Identity.BuildExportPayload then
                seqData = Identity:BuildExportPayload(seqData, seqData.privacyMode)
            end

            -- Prepare export versions (deep-copy + spell tag translation)
            local exportVersions = GE.PrepareExportVersions(seqData)
            local bc = GE.ResolveExportContext(seqData)

            local seqMode = seqData.privacyMode
            if seqMode and MODE_RANK[seqMode] and MODE_RANK[seqMode] > MODE_RANK[strictestMode] then
                strictestMode = seqMode
            end
            if seqData.classID then
                classIDSet[seqData.classID] = true
            end
            if seqData.specID then
                specIDSet[seqData.specID] = true
            end

            payload.sequences[seqName] = {
                icon = seqData.icon or D.QUESTION_MARK_ICON,
                versions = exportVersions,
                defaultVersion = seqData.defaultVersion or 1,
                contextOverrides = seqData.contextOverrides,
                -- v2.1.0 Phase D: emit provenance fields onto the wire so
                -- receivers can render Verified / Modified / Forked badges
                -- and the modifier-chain / forkedFromChain ancestry. Every
                -- field is already privacy-scrubbed by BuildExportPayload.
                originalAuthor = seqData.originalAuthor,
                originalAuthorIdentity = seqData.originalAuthorIdentity,
                originalAuthorRealm = seqData.originalAuthorRealm,
                originalCreatedAt = seqData.originalCreatedAt,
                originalSignature = seqData.originalSignature,
                originalSignatureV2 = seqData.originalSignatureV2,
                signatureAlgorithm = seqData.signatureAlgorithm,
                lastModifier = seqData.lastModifier,
                lastModifierIdentity = seqData.lastModifierIdentity,
                lastModifierRealm = seqData.lastModifierRealm,
                lastModifiedAt = seqData.lastModifiedAt,
                modifierChain = seqData.modifierChain,
                forkedFrom = seqData.forkedFrom,
                forkedFromChain = seqData.forkedFromChain,
                provenanceSource = seqData.provenanceSource,
                privacyMode = seqData.privacyMode,
                -- v2.3.3 Phase 1: full single-path metadata parity so
                -- collection receivers (and site parsers) can auto-fill
                -- class / spec / description per sequence. Reads the
                -- privacy-scrubbed seqData plus the shared context
                -- resolver, matching GE.Export field for field.
                author = seqData.author or "",
                description = seqData.description or "",
                help = seqData.help or "",
                helplink = seqData.helplink or "",
                changelog = seqData.changelog,
                classID = seqData.classID,
                specID = seqData.specID,
                createdAt = seqData.createdAt or time(),
                updatedAt = seqData.updatedAt,
                playerLevel = bc.playerLevel,
                classFile = bc.classFile,
                className = bc.className,
                specName = bc.specName,
                role = bc.role,
                heroSpecID = bc.heroSpecID,
                heroSpecName = bc.heroSpecName,
                talentString = bc.talentString,
                talentBuild = bc.talentBuild,
                url = bc.url,
                contentTypes = bc.contentTypes,
                versionCount = bc.versionCount,
                insights = GE.BuildInsights(seqName, seqData, exportVersions),
                -- v2.2.0 Phase L4-polish2 emitted the stored MetaData deps
                -- here; v2.3.3 Phase 1 merges that Macros list with the
                -- embedded-sequence and variable scans. Receivers that
                -- predate this field (older EMS clients) safely ignore
                -- the extra key during deserialization.
                Dependencies = GE.BuildDependenciesField(seqData, exportVersions),
            }
        end
    end

    -- v2.3.3 Phase 1: privacy-aware exporter identity + region under the
    -- strictest selected mode. Omitted entirely when that mode is private;
    -- region ships only when it is public.
    local exportedBy = GE.BuildExportedBy(strictestMode)
    if exportedBy then
        payload.exportedBy = exportedBy
    end
    if strictestMode == D.PRIVACY_MODE_PUBLIC and GetCurrentRegionName then
        payload.region = GetCurrentRegionName()
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
                -- v2.3.3 Phase 1: locale-risk flag (guarded pcall read so
                -- harnesses without the risk index skip it).
                if VS.GetLocaleRisk then
                    local riskOk, risk = pcall(VS.GetLocaleRisk, VS, varName)
                    if riskOk and risk then
                        cleaned.localeRisk = true
                    end
                end
                payload.variables[varName] = cleaned
            end
        end
    end

    if macNames and #macNames > 0 then
        local maxMacros = (MAX_ACCOUNT_MACROS or 120) + (MAX_CHARACTER_MACROS or 18)
        local nameToInfo = {}
        for macid = 1, maxMacros do
            local mname, micon, mbody = GetMacroInfo(macid)
            if mname and mname ~= "" then
                local scope = "a"
                if macid > (MAX_ACCOUNT_MACROS or 120) then
                    scope = "p"
                end
                nameToInfo[mname] = { icon = micon, body = mbody or "", scope = scope }
            end
        end
        for _, macName in ipairs(macNames) do
            local info = nameToInfo[macName]
            if info then
                payload.Macros[macName] = {
                    name = macName,
                    icon = info.icon or D.QUESTION_MARK_ICON,
                    text = info.body,
                    category = info.scope,
                }
            end
        end
    end

    -- Embed export metadata if provided
    -- v2.1.0: author is always included (the includeAuthor toggle was removed
    -- when EMS dropped GSE-export compat under the !EMS1! native format).
    if exportMeta then
        local classIDs, specIDs = {}, {}
        for id in pairs(classIDSet) do
            classIDs[#classIDs + 1] = id
        end
        for id in pairs(specIDSet) do
            specIDs[#specIDs + 1] = id
        end
        table.sort(classIDs)
        table.sort(specIDs)
        payload.exportMeta = {
            collectionName = exportMeta.collectionName,
            author = exportMeta.author,
            description = exportMeta.includeDescription and exportMeta.description or nil,
            talentString = exportMeta.includeTalent and exportMeta.talentString or nil,
            url = exportMeta.includeUrl and exportMeta.url or nil,
            -- v2.3.3 Phase 1: selection coverage summary for parsers.
            counts = {
                sequences = #seqNames,
                variables = varNames and #varNames or 0,
                macros = macNames and #macNames or 0,
            },
            classIDs = classIDs,
            specIDs = specIDs,
            createdAt = payload.exportedAt,
        }
    end

    return payload
end

--- Export multiple sequences and variables as a GRIP1 collection string.
--- Falls back to single-format GE.Export() if only 1 sequence, 0 variables, 0 macros.
--- @param seqNames table Array of sequence names to export
--- @param varNames table Array of variable names to export
--- @param macNames table Array of macro names to export
--- @param exportMeta table|nil Optional metadata (collectionName, author, etc.)
--- @return boolean ok
--- @return string result Encoded string on success, error message on failure
function GE.ExportCollection(seqNames, varNames, macNames, exportMeta)
    if not seqNames or #seqNames == 0 then
        return false, "No sequences selected for export"
    end

    if #seqNames == 1 and (not varNames or #varNames == 0) and (not macNames or #macNames == 0) then
        return GE.Export(seqNames[1])
    end

    local payload = GE.BuildCollectionPayload(seqNames, varNames, macNames, exportMeta)

    local ok, encoded = S.Encode(payload, D.EMS1_PREFIX)
    if not ok then
        return false, "Export encoding failed: " .. tostring(encoded)
    end

    return true, encoded
end

--- Serialize the current export selection through a registered plugin
--- export provider. Symmetric inverse of LI.DecodeWithProviders on the
--- import side: EMS owns the pipeline and builds the canonical COLLECTION
--- payload; the provider only transforms that payload into its own wire
--- string. The provider gets ONE Serialize call carrying the WHOLE
--- selection (the COLLECTION payload), never a per-sequence loop.
--- Serialize runs in pcall; a throwing or non-string provider fails
--- cleanly without breaking the export UI.
--- @param providerId string id of a provider in GRIPEMS._exportProviders
--- @param seqNames table Array of sequence names to export
--- @param varNames table|nil Array of variable names
--- @param macNames table|nil Array of macro names
--- @param exportMeta table|nil Optional metadata
--- @return boolean ok
--- @return string result Serialized string on success, error message on failure
--- @return string|nil id The provider id on success
function GE.SerializeWithProvider(providerId, seqNames, varNames, macNames, exportMeta)
    local providers = GRIPEMS._exportProviders
    if type(providers) ~= "table" or #providers == 0 then
        return false, "No export providers registered"
    end
    if not seqNames or #seqNames == 0 then
        return false, "No sequences selected for export"
    end
    local provider
    for i = 1, #providers do
        if providers[i].id == providerId then
            provider = providers[i]
            break
        end
    end
    if not provider then
        return false, "Unknown export provider: " .. tostring(providerId)
    end
    local payload = GE.BuildCollectionPayload(seqNames, varNames, macNames, exportMeta)
    local ok, result = pcall(provider.Serialize, provider, payload)
    if not ok then
        return false, "Export provider error: " .. tostring(result)
    end
    if type(result) ~= "string" then
        return false, "Export provider returned a non-string value"
    end
    return true, result, provider.id
end
