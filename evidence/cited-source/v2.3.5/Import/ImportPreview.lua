-- GRIP-EMS: ImportPreview
-- Created: 2026-03-20
-- Updated: 2026-06-25
-- Patch: 12.0.7.68256 Midnight (Retail LIVE)

-- GRIP-EMS: Import Preview
-- Pure-data preview engine for import strings: decode and analyze without side effects

local ADDON_NAME, GRIPEMS = ...
local L = LibStub("AceLocale-3.0"):GetLocale("GRIP-EMS", true)
local D = GRIPEMS.Defaults
local S = GRIPEMS.Serialization
local LI = GRIPEMS.LegacyImport
local VS = GRIPEMS.VariableStore
local SC = GRIPEMS.SpellCache

local FREEFORM_PATTERNS = {
    "^/run%s",
    "^/script%s",
    "^/target%s",
    "^/focus$",
    "^/focus%s",
    "^/stopmacro",
    "^/console%s",
    "^/dump%s",
    "^/click%s",
}

local function IsFreeformStep(stepText)
    if type(stepText) ~= "string" then
        return false
    end
    local lower = stepText:lower()
    for _, pat in ipairs(FREEFORM_PATTERNS) do
        if lower:match(pat) then
            return true
        end
    end
    return false
end

--- v2.1.0 Phase B: attach provenance + verification state to a preview entry.
--- Surfaces the fields the import-preview UI panel renders (original author,
--- identity, creation date, modifier-chain count, forkedFrom, signature
--- algorithm + value, provenance source, computed verification state).
--- Legacy-format imports lack provenance; they receive verificationState
--- "unknown" so the UI badge greys-out rather than red-flagging.
--- @param entry table Preview-result sequence entry to enrich (mutated)
--- @param seqObj table Decoded sequence payload (native or legacy)
local function AttachProvenance(entry, seqObj)
    if not entry or type(seqObj) ~= "table" then
        return
    end
    local Identity = GRIPEMS.Identity
    local prov = {
        originalAuthor = seqObj.originalAuthor or "",
        originalAuthorIdentity = seqObj.originalAuthorIdentity or "",
        originalCreatedAt = seqObj.originalCreatedAt or 0,
        chainLength = (seqObj.modifierChain and #seqObj.modifierChain) or 0,
        modifierChain = seqObj.modifierChain or {},
        forkedFrom = seqObj.forkedFrom,
        forkedFromChain = seqObj.forkedFromChain or {},
        signatureAlgorithm = seqObj.signatureAlgorithm or "",
        originalSignature = seqObj.originalSignature or "",
        provenanceSource = seqObj.provenanceSource or "",
        lastModifier = seqObj.lastModifier or "",
        verificationState = "unknown",
    }
    if Identity and Identity.VerifySequence and seqObj.originalAuthor and seqObj.originalAuthor ~= "" then
        prov.verificationState = Identity:VerifySequence(seqObj)
    end
    entry.provenance = prov
end

--- Produce a deterministic string fingerprint of a sequence's content.
--- Handles both GRIP-EMS format (lowercase, .versions) and legacy format (mixed case, .Macros).
--- @param seqObj table Sequence object
--- @return string Fingerprint string for equality comparison
local function ComputeSequenceFingerprint(seqObj)
    if not seqObj or type(seqObj) ~= "table" then
        return ""
    end
    local parts = {}
    local versions = seqObj.versions or seqObj.Macros or seqObj.MacroVersions or seqObj.Versions
    if versions and type(versions) == "table" then
        for _, ver in ipairs(versions) do
            parts[#parts + 1] = ver.stepFunction or ver.StepFunction or ver.Step or ""
            local steps = ver.steps or ver.Actions
            if steps and type(steps) == "table" then
                -- Late-bound fetch: the module-level upvalue may be nil
                -- depending on TOC load order at first-fingerprint time.
                local cache = GRIPEMS.SpellCache
                local stepStrs = {}
                for i = 1, #steps do
                    local s = steps[i]
                    if type(s) == "string" then
                        stepStrs[i] = s
                    elseif cache and cache.StepToString then
                        stepStrs[i] = cache:StepToString(s)
                    else
                        stepStrs[i] = ""
                    end
                end
                parts[#parts + 1] = table.concat(stepStrs, "|")
            end
            parts[#parts + 1] = ver.keyPress or ver.KeyPress or ""
            parts[#parts + 1] = ver.keyRelease or ver.KeyRelease or ""
            parts[#parts + 1] = tostring(ver.resetOnCombat or ver.Combat or false)
            parts[#parts + 1] = tostring(ver.resetOnTarget or ver.Head or false)
            parts[#parts + 1] = tostring(ver.resetTimer or ver.Timer or "")
        end
        parts[#parts + 1] = tostring(#versions)
    end
    parts[#parts + 1] = tostring(seqObj.defaultVersion or seqObj.Default or "")
    return table.concat(parts, "\n")
end

--- Produce a deterministic string fingerprint of a variable definition.
--- @param varDef table Variable definition
--- @return string Fingerprint string for equality comparison
local function ComputeVariableFingerprint(varDef)
    if not varDef or type(varDef) ~= "table" then
        return ""
    end
    local parts = {}
    parts[#parts + 1] = varDef.value or ""
    parts[#parts + 1] = varDef.funct or ""
    parts[#parts + 1] = varDef.events or ""
    parts[#parts + 1] = tostring(varDef.disabled or false)
    return table.concat(parts, "\n")
end

--- Translate spell ID tags to localized names in all versions of a sequence.
--- Mutates the sequence table in place (safe on freshly decoded data).
--- @param seq table Sequence payload with .versions array
local function TranslateSequenceVersions(seq)
    if not seq or not seq.versions or type(seq.versions) ~= "table" then
        return
    end
    for _, ver in ipairs(seq.versions) do
        -- Phase 2b: capture tagged payload before translating to names
        if ver.steps then
            local taggedSteps = {}
            for si, step in ipairs(ver.steps) do
                if type(step) == "string" then
                    -- A legacy/shared import payload can already contain handle-tokens;
                    -- recover them to names before seeding the tagged copy.
                    step = (SC:RecoverHandleTokensInText(step))
                    ver.steps[si] = step
                end
                taggedSteps[si] = step
                if type(step) == "string" then
                    ver.steps[si] = SC:TranslateMacrotext(step, "toNames")
                end
            end
            ver.taggedSteps = taggedSteps
        end
        if ver.keyPress and type(ver.keyPress) == "string" then
            ver.keyPress = (SC:RecoverHandleTokensInText(ver.keyPress))
            ver.taggedKeyPress = ver.keyPress
            ver.keyPress = SC:TranslateMacrotext(ver.keyPress, "toNames")
        end
        if ver.keyRelease and type(ver.keyRelease) == "string" then
            ver.keyRelease = (SC:RecoverHandleTokensInText(ver.keyRelease))
            ver.taggedKeyRelease = ver.keyRelease
            ver.keyRelease = SC:TranslateMacrotext(ver.keyRelease, "toNames")
        end
        ver.stepsLocale = GetLocale()
    end
end

--- Suggest an icon for a sequence by scanning all version steps for spell names.
--- Extracts spells via ParseSpellFromMacrotext, resolves variable references,
--- and returns the first valid icon found.
--- @param seqObj table Sequence object (GRIP-EMS or legacy format)
--- @return number|nil iconID The suggested icon file ID, or nil
local function SuggestSequenceIcon(seqObj)
    if not seqObj or type(seqObj) ~= "table" then
        return nil
    end

    local skipPrefixes = D.SKIP_SPELL_PREFIXES
    if not skipPrefixes then
        return nil
    end

    -- Gather all steps from all versions
    local allSteps = {}
    local versions = seqObj.versions or seqObj.Macros or seqObj.MacroVersions or seqObj.Versions
    if versions and type(versions) == "table" then
        for _, ver in ipairs(versions) do
            local steps = ver.steps or ver.Actions
            if steps and type(steps) == "table" then
                for _, step in ipairs(steps) do
                    if type(step) == "string" and step ~= "" then
                        allSteps[#allSteps + 1] = step
                    end
                end
            end
            -- Also check keyPress for spells
            local kp = ver.keyPress or ver.KeyPress
            if type(kp) == "string" and kp ~= "" then
                allSteps[#allSteps + 1] = kp
            end
        end
    elseif seqObj.steps and type(seqObj.steps) == "table" then
        for _, step in ipairs(seqObj.steps) do
            if type(step) == "string" and step ~= "" then
                allSteps[#allSteps + 1] = step
            end
        end
    end

    -- Scan each step for spell names and look up icons
    for _, stepText in ipairs(allSteps) do
        -- Resolve variable references first
        local resolved = stepText:gsub(D.VAR_PATTERN, function(varName)
            if VS and VS.GetCachedValue then
                local val = VS:GetCachedValue(varName)
                if val and type(val) == "string" then
                    return val
                end
            end
            return ""
        end)

        -- Use SpellCache parser to find the best spell name
        local ok, spellName = pcall(function()
            return SC:ParseSpellFromMacrotext(resolved)
        end)
        if ok and spellName and spellName ~= "" then
            local iconOk, iconID = pcall(function()
                return SC:GetIcon(spellName)
            end)
            if iconOk and iconID then
                return iconID
            end
        end
    end

    return nil
end

-- Expose for cross-module access (LegacyImport.ProcessSequence)
LI._SuggestSequenceIcon = SuggestSequenceIcon

--- Generate a structured preview of an encoded import string.
--- Decodes and analyzes the string WITHOUT any side effects: no ActivateSequence,
--- no VariableStore writes, no callbacks fired.
--- @param encodedString string The full encoded string (with prefix)
--- @return table Preview result table (ok, format, sequences, variables, warnings, counts)
function LI.Preview(encodedString)
    if not encodedString or encodedString == "" then
        return { ok = false, error = "No import string provided" }
    end

    local format = S.DetectFormat(encodedString)

    -- GRIP-EMS native format (EMS1 v2.1.0+, GRIP1 legacy).
    -- Both share the {format="GRIP-EMS", ...} payload shape; route
    -- both through the same internal preview helper.
    if format == "GRIP1" or format == "EMS1" then
        return LI._PreviewGRIP1(encodedString)
    end

    -- Legacy format (or unknown)
    local ok, decoded = LI.DecodeWithProviders(encodedString)
    if not ok then
        return { ok = false, error = decoded }
    end

    -- FRG1 (GRIP Forge export envelope): validate, then unwrap the inner
    -- COLLECTION so the preview walk below analyzes it (export-path design
    -- doc, site 6). The envelope forge block attaches to every preview
    -- entry after the walk so the commit rail stamps the forge-import
    -- family without any CommitSelected change.
    local forgeProvenance = nil
    if format == "FRG1" then
        local forge, verr = LI.ValidateForgeEnvelope(decoded)
        if not forge then
            return { ok = false, error = verr }
        end
        forgeProvenance = forge
        decoded = decoded.payload
    end

    local result = {
        ok = true,
        format = (format == "FRG1") and "FRG1" or "GSE3",
        forge = forgeProvenance,
        sequences = {},
        variables = {},
        macros = {},
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
                if
                    innerOk
                    and type(innerDecoded) == "table"
                    and type(innerDecoded[1]) == "string"
                    and type(innerDecoded[2]) == "table"
                then
                    LI._PreviewAddSequence(result, innerDecoded[1], innerDecoded[2])
                else
                    result.warnings[#result.warnings + 1] =
                        string.format("'%s': failed to decode inner sequence", tostring(seqName))
                end
            elseif type(seqValue) == "table" then
                -- Raw table (12.0.1+ style)
                LI._PreviewAddSequence(result, seqName, seqValue)
            end
        end

        -- Preview variables from COLLECTION payload
        if payload.Variables and type(payload.Variables) == "table" then
            for varName, varValue in pairs(payload.Variables) do
                if type(varValue) == "string" then
                    local varOk, varDecoded = S.Decode(varValue)
                    if varOk and type(varDecoded) == "table" then
                        if type(varDecoded[1]) == "string" and type(varDecoded[2]) == "table" then
                            local gripVar = LI.MapLegacyVariable(varDecoded[1], varDecoded[2])
                            LI._PreviewAddVariable(result, varDecoded[1], gripVar)
                        else
                            local gripVar = LI.MapLegacyVariable(varName, varDecoded)
                            LI._PreviewAddVariable(result, varName, gripVar)
                        end
                    else
                        result.warnings[#result.warnings + 1] = "Variable '" .. varName .. "': failed to decode"
                    end
                elseif type(varValue) == "table" then
                    local gripVar = LI.MapLegacyVariable(varName, varValue)
                    LI._PreviewAddVariable(result, varName, gripVar)
                end
            end
        end

        -- Preview macros from COLLECTION payload (audit Layer 1 picker UI rewire:
        -- closes payload.Macros half-bug from Phase 1 for picker paste users)
        if payload.Macros and type(payload.Macros) == "table" then
            for macName, macValue in pairs(payload.Macros) do
                if type(macValue) == "string" then
                    local mOk, mDecoded = S.Decode(macValue)
                    if mOk and type(mDecoded) == "table" then
                        LI._PreviewAddMacro(result, macName, mDecoded)
                    else
                        result.warnings[#result.warnings + 1] = "Macro '" .. macName .. "': failed to decode"
                    end
                elseif type(macValue) == "table" then
                    LI._PreviewAddMacro(result, macName, macValue)
                end
            end
        end
    elseif type(decoded) == "table" and decoded.Command then
        return { ok = false, error = "Command format (addon transmission) is not supported" }
    elseif type(decoded) == "table" and type(decoded[1]) == "string" and type(decoded[2]) == "table" then
        -- Simple array format: { name, sequence }
        LI._PreviewAddSequence(result, decoded[1], decoded[2])
    else
        return { ok = false, error = L["GEMS_IMPORT_UNKNOWN_FORMAT"] }
    end

    -- Forge attribution (site 6): each FRG1 preview entry carries the
    -- envelope forge block for the UI, threads the commit opts, and
    -- mirrors the post-commit provenance so the preview panel matches
    -- what ProcessSequence will stamp at commit time.
    if forgeProvenance then
        for _, entry in ipairs(result.sequences) do
            entry.forge = forgeProvenance
            entry.opts = entry.opts or {}
            entry.opts.forgeProvenance = forgeProvenance
            if entry.provenance then
                entry.provenance.provenanceSource = "forge-import"
                entry.provenance.originalAuthor = "GRIP Forge"
                entry.provenance.forgeAuthor = forgeProvenance.author or ""
            end
        end
    end

    -- Compute summary counts
    LI._PreviewComputeCounts(result)

    if result.totalSequences == 0 and result.totalVariables == 0 and (result.totalMacros or 0) == 0 then
        result.warnings[#result.warnings + 1] = L["GEMS_IMPORT_PREVIEW_EMPTY"]
    end

    return result
end

--- Preview a GRIP-EMS native import string.
--- Accepts both !EMS1! (v2.1.0+ native) and !GRIP1! (legacy native);
--- both encode the same {format="GRIP-EMS", ...} payload shape via
--- S.Encode and dispatch identically post-decode.
--- @param encodedString string The !EMS1!- or !GRIP1!-prefixed encoded string
--- @return table Preview result table
function LI._PreviewGRIP1(encodedString)
    local ok, decoded, detectedFormat = S.Decode(encodedString)
    if not ok then
        return { ok = false, error = decoded }
    end
    if detectedFormat ~= "GRIP1" and detectedFormat ~= "EMS1" then
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
            ok = true,
            format = "GRIP1",
            sequences = {},
            variables = {},
            warnings = {},
        }
        -- Iterate decoded.sequences (name -> seqPayload)
        for seqName, seqPayload in pairs(decoded.sequences or {}) do
            local ver = seqPayload.versions and seqPayload.versions[seqPayload.defaultVersion or 1]
            local stepCount = ver and ver.steps and #ver.steps or 0
            local versionCount = seqPayload.versions and #seqPayload.versions or 0
            local exists = (Engine and Engine.sequences and Engine.sequences[seqName] ~= nil)
            local status = "new"
            if exists then
                local existingEntry = Engine.sequences[seqName]
                local existingData = existingEntry and existingEntry.data
                local incomingFP = ComputeSequenceFingerprint(seqPayload)
                local existingFP = existingData and ComputeSequenceFingerprint(existingData) or ""
                status = (incomingFP == existingFP) and "identical" or "different"
            end
            local freeformCount = 0
            local freeVer = seqPayload.versions
                and (seqPayload.versions[seqPayload.defaultVersion or 1] or seqPayload.versions[1])
            if freeVer and freeVer.steps then
                for _, stepText in ipairs(freeVer.steps) do
                    if IsFreeformStep(stepText) then
                        freeformCount = freeformCount + 1
                    end
                end
            end

            local seqIcon = seqPayload.icon or D.QUESTION_MARK_ICON
            local suggestedIcon = nil
            if seqIcon == D.QUESTION_MARK_ICON then
                suggestedIcon = SuggestSequenceIcon(seqPayload)
            end

            local colEntry = {
                name = seqName,
                icon = seqIcon,
                suggestedIcon = suggestedIcon,
                versionCount = versionCount,
                stepCount = stepCount,
                status = status,
                selected = true,
                conflictAction = (status == "new") and "import" or "skip",
                seqObj = seqPayload,
                isCollection = true,
                freeformCount = freeformCount,
            }
            AttachProvenance(colEntry, seqPayload)
            colResult.sequences[#colResult.sequences + 1] = colEntry
        end
        -- Iterate decoded.variables (name -> varDef)
        for varName, varDef in pairs(decoded.variables or {}) do
            local existingVar = VS and VS.Get and VS:Get(varName)
            local varStatus = "new"
            if existingVar then
                local incomingFP = ComputeVariableFingerprint(varDef)
                local existingFP = ComputeVariableFingerprint(existingVar)
                varStatus = (incomingFP == existingFP) and "identical" or "different"
            end
            colResult.variables[#colResult.variables + 1] = {
                name = varName,
                status = varStatus,
                selected = true,
                conflictAction = (varStatus == "new") and "import" or "skip",
                varDef = varDef,
            }
        end
        table.sort(colResult.sequences, function(a, b)
            return a.name < b.name
        end)
        table.sort(colResult.variables, function(a, b)
            return a.name < b.name
        end)
        -- Carry export metadata if present
        colResult.exportMeta = decoded.exportMeta or nil
        LI._PreviewComputeCounts(colResult)
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

    -- Freeform detection
    local freeformCount = 0
    local freeVer = (seq.versions and seq.versions[seq.defaultVersion or 1]) or (seq.versions and seq.versions[1])
    if freeVer and freeVer.steps then
        for _, stepText in ipairs(freeVer.steps) do
            if IsFreeformStep(stepText) then
                freeformCount = freeformCount + 1
            end
        end
    end

    -- Status check
    local status = "new"
    local existingStepCount = nil
    if GRIPEMS.Engine and GRIPEMS.Engine.sequences and GRIPEMS.Engine.sequences[seqName] then
        local entry = GRIPEMS.Engine.sequences[seqName]
        if entry.data then
            local ver = GRIPEMS.Engine:GetActiveVersion(entry.data)
            if ver and ver.steps then
                existingStepCount = #ver.steps
            end
        end
        local incomingFP = ComputeSequenceFingerprint(seq)
        local existingFP = entry.data and ComputeSequenceFingerprint(entry.data) or ""
        status = (incomingFP == existingFP) and "identical" or "different"
    end

    local suggestedIcon = nil
    if icon == D.QUESTION_MARK_ICON then
        suggestedIcon = SuggestSequenceIcon(seq)
    end

    local singleEntry = {
        name = seqName,
        seqObj = decoded,
        versionCount = versionCount,
        stepCount = stepCount,
        stepFunction = stepFunction,
        icon = icon,
        suggestedIcon = suggestedIcon,
        status = status,
        existingStepCount = existingStepCount,
        conflictAction = (status == "new") and "import" or "skip",
        freeformCount = freeformCount,
        opts = nil,
    }
    AttachProvenance(singleEntry, seq)
    local result = {
        ok = true,
        format = "GRIP1",
        sequences = { singleEntry },
        variables = {},
        warnings = {},
    }

    -- GRIP1 v5+: extract bundled variables (mirrors COLLECTION branch)
    for varName, varDef in pairs(decoded.variables or {}) do
        local existingVar = VS and VS.Get and VS:Get(varName)
        local varStatus = "new"
        if existingVar then
            local incomingFP = ComputeVariableFingerprint(varDef)
            local existingFP = ComputeVariableFingerprint(existingVar)
            varStatus = (incomingFP == existingFP) and "identical" or "different"
        end
        result.variables[#result.variables + 1] = {
            name = varName,
            status = varStatus,
            selected = true,
            conflictAction = (varStatus == "new") and "import" or "skip",
            varDef = varDef,
        }
    end
    table.sort(result.variables, function(a, b)
        return a.name < b.name
    end)

    LI._PreviewComputeCounts(result)
    return result
end

--- Add an imported sequence to a preview result (no side effects).
--- @param result table The preview result being built
--- @param seqName string Sequence name
--- @param sequence table Imported sequence object
function LI._PreviewAddSequence(result, seqName, sequence)
    if not seqName or not sequence then
        result.warnings[#result.warnings + 1] = "Skipped entry with missing name or data"
        return
    end

    local macros = sequence.Macros or sequence.MacroVersions or sequence.Versions
    if not macros or #macros == 0 then
        result.warnings[#result.warnings + 1] = string.format("'%s': no macro versions found", tostring(seqName))
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
    local spellWarnCount = 0
    local spellInfoCount = 0
    local freeformCount = 0

    if defaultMacro then
        -- Save and restore compile stats to avoid side effects
        local savedStats = LI._compileStats
        LI._compileStats = { pauses = 0, embeds = 0, truncated = 0 }

        local compiled = LI.CompileMacroVersion(defaultMacro)
        stepCount = compiled.steps and #compiled.steps or 0

        -- Spell validation on compiled steps (import -- no Engine state)
        if compiled.steps and GRIPEMS.SpellValidator and GRIPEMS.SpellCache and GRIPEMS.SpellCache.ready then
            local SV = GRIPEMS.SpellValidator
            for _, stepText in ipairs(compiled.steps) do
                if type(stepText) == "string" then
                    local stepResult = SV:ValidateStep(stepText)
                    for _, spell in ipairs(stepResult.spells) do
                        if spell.status == D.SPELL_STATUS_UNKNOWN then
                            spellWarnCount = spellWarnCount + 1
                        elseif spell.status == D.SPELL_STATUS_KNOWN then
                            spellInfoCount = spellInfoCount + 1
                        end
                    end
                end
            end
        end

        -- Freeform detection on compiled steps
        freeformCount = 0
        if compiled.steps then
            for _, stepText in ipairs(compiled.steps) do
                if IsFreeformStep(stepText) then
                    freeformCount = freeformCount + 1
                end
            end
        end

        -- Collect compile warnings
        if compiled.warnings then
            for _, w in ipairs(compiled.warnings) do
                result.warnings[#result.warnings + 1] = seqName .. ": " .. w
            end
        end

        LI._compileStats = savedStats

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
    local sourceVersion = nil
    local sourceChecksum = nil
    if sequence.MetaData then
        opts = {
            author = sequence.MetaData.Author,
            description = sequence.MetaData.Description,
            specID = sequence.MetaData.SpecID,
        }
        -- Extract legacy format version and checksum (informational)
        if sequence.MetaData.GSEVersion then
            sourceVersion = tostring(sequence.MetaData.GSEVersion)
        end
        if sequence.MetaData.Checksum then
            sourceChecksum = tostring(sequence.MetaData.Checksum)
        end
    end

    -- Status: check if name already exists in engine
    local status = "new"
    local existingStepCount = nil
    if GRIPEMS.Engine and GRIPEMS.Engine.sequences and GRIPEMS.Engine.sequences[seqName] then
        local entry = GRIPEMS.Engine.sequences[seqName]
        if entry.data then
            local ver = GRIPEMS.Engine:GetActiveVersion(entry.data)
            if ver and ver.steps then
                existingStepCount = #ver.steps
            end
        end
        local incomingFP = ComputeSequenceFingerprint(sequence)
        local existingFP = entry.data and ComputeSequenceFingerprint(entry.data) or ""
        status = (incomingFP == existingFP) and "identical" or "different"
    end

    local suggestedIcon = nil
    if icon == D.QUESTION_MARK_ICON then
        suggestedIcon = SuggestSequenceIcon(sequence)
    end

    local legacyEntry = {
        name = seqName,
        seqObj = sequence,
        versionCount = #macros,
        stepCount = stepCount,
        stepFunction = stepFunction,
        icon = icon,
        suggestedIcon = suggestedIcon,
        status = status,
        existingStepCount = existingStepCount,
        conflictAction = (status == "new") and "import" or "skip",
        opts = opts,
        sourceVersion = sourceVersion,
        sourceChecksum = sourceChecksum,
        spellWarnCount = spellWarnCount,
        spellInfoCount = spellInfoCount,
        freeformCount = freeformCount,
    }
    AttachProvenance(legacyEntry, sequence)
    result.sequences[#result.sequences + 1] = legacyEntry

    if freeformCount > 0 then
        result.warnings[#result.warnings + 1] = string.format(L["GEMS_IMPORT_FREEFORM_WARN"], seqName, freeformCount)
    end
end

--- Add a variable to a preview result (no side effects).
--- @param result table The preview result being built
--- @param name string Variable name
--- @param varDef table Mapped GRIP-EMS varDef
function LI._PreviewAddVariable(result, name, varDef)
    if not name or not varDef then
        return
    end

    local status = "new"
    local existingVar = VS and VS.Get and VS:Get(name)
    if existingVar then
        local incomingFP = ComputeVariableFingerprint(varDef)
        local existingFP = ComputeVariableFingerprint(existingVar)
        status = (incomingFP == existingFP) and "identical" or "different"
    end

    result.variables[#result.variables + 1] = {
        name = name,
        varDef = varDef,
        status = status,
        conflictAction = (status == "new") and "import" or "skip",
    }
end

--- Add a macro entry to the preview result. Used by the COLLECTION
--- payload.Macros walk so the picker can show macros alongside sequences
--- and variables. Does NOT touch SavedVariables -- pure data preview.
--- @param result table The preview result being built
--- @param name string Macro name (also the dedup key)
--- @param node table Raw macro node table { name, icon, text, manageMacro, ... }
function LI._PreviewAddMacro(result, name, node)
    if not name or not node then
        return
    end
    result.macros = result.macros or {}

    local exists = false
    if _G.GRIP_EMS_DB and GRIP_EMS_DB.macros and GRIP_EMS_DB.macros[name] then
        exists = true
    end
    if not exists and _G.GRIP_EMS_CHAR and GRIP_EMS_CHAR.macros and GRIP_EMS_CHAR.macros[name] then
        exists = true
    end
    if not exists and GetMacroIndexByName then
        local slot = GetMacroIndexByName(name)
        if slot and slot > 0 then
            exists = true
        end
    end

    local body = (type(node.text) == "string" and node.text)
        or (type(node.manageMacro) == "string" and node.manageMacro)
        or ""

    result.macros[#result.macros + 1] = {
        name = name,
        node = node,
        bodyPreview = body,
        exists = exists,
        action = exists and "update" or "create",
        status = exists and "different" or "new",
        conflictAction = "import",
        selected = true,
    }
end

--- Compute summary counts on a preview result table.
--- @param result table The preview result table to update
function LI._PreviewComputeCounts(result)
    local totalSeq = #result.sequences
    local totalVar = #result.variables
    local totalMac = (result.macros and #result.macros) or 0
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
    result.totalMacros = totalMac
    result.newSequences = newSeq
    result.existingSequences = existingSeq -- identical + different
end

--- Scan selected sequences for variable references and auto-select
--- matching variables that are not manually overridden.
--- @param preview table The preview result from LI.Preview()
--- @return table neededVars Set of variable names referenced by selected sequences
function LI.ResolveImportVariableDeps(preview)
    if not preview then
        return {}
    end

    local neededVars = {}
    local varPattern = D.VAR_PATTERN

    for _, entry in ipairs(preview.sequences) do
        if entry.conflictAction ~= "skip" then
            -- Gather steps from all versions
            local seqObj = entry.seqObj
            local versions
            if entry.isCollection then
                versions = seqObj and seqObj.versions
            else
                local inner = seqObj and (seqObj.sequence or seqObj)
                versions = inner and (inner.versions or inner.Macros or inner.MacroVersions or inner.Versions)
            end
            if versions and type(versions) == "table" then
                for _, ver in ipairs(versions) do
                    local steps = ver.steps or ver.Actions
                    if steps and type(steps) == "table" then
                        for _, step in ipairs(steps) do
                            if type(step) == "string" then
                                for varName in step:gmatch(varPattern) do
                                    neededVars[varName] = true
                                end
                            end
                        end
                    end
                    -- Also scan keyPress/keyRelease
                    local kp = ver.keyPress or ver.KeyPress
                    if type(kp) == "string" then
                        for varName in kp:gmatch(varPattern) do
                            neededVars[varName] = true
                        end
                    end
                    local kr = ver.keyRelease or ver.KeyRelease
                    if type(kr) == "string" then
                        for varName in kr:gmatch(varPattern) do
                            neededVars[varName] = true
                        end
                    end
                end
            end
        end
    end

    -- Auto-select matching variables
    for _, varEntry in ipairs(preview.variables) do
        local needed = neededVars[varEntry.name] or false
        if needed then
            if not varEntry.manualDeselect then
                varEntry.autoSelected = true
                if varEntry.conflictAction == "skip" and not varEntry.manualDeselect then
                    varEntry.conflictAction = "import"
                end
            end
        else
            varEntry.autoSelected = false
            if not varEntry.manualSelect then
                varEntry.conflictAction = "skip"
            end
        end
    end

    return neededVars
end

--- Build a GRIP-EMS seqData table from a GRIP1 sequence payload.
--- Shared helper for CommitSelected to eliminate field drift between paths.
--- @param seq table The GRIP1 sequence payload
--- @param name string The sequence name to assign
--- @return table seqData Ready for ActivateSequence
local function BuildSeqDataFromGRIP1(seq, name)
    local seqData = {
        name = name,
        icon = seq.icon or D.QUESTION_MARK_ICON,
        autoIcon = seq.autoIcon,
        versions = seq.versions,
        defaultVersion = seq.defaultVersion or 1,
        contextOverrides = seq.contextOverrides or {},
        author = seq.author or "",
        version = seq.version or "1",
        description = seq.description or "",
        help = seq.help or "",
        helplink = seq.helplink or "",
        changelog = seq.changelog,
        -- v2.3.4: per-sequence talent code. Author-set string wins; the
        -- spec-gated live capture from the exporter is the fallback, but ONLY
        -- for payloads with no provenance: talentString is signed content
        -- (Identity CONTENT_FIELDS) while talentBuild is the unsigned display
        -- key, so writing the capture into a signed sequence rewrites signed
        -- content post-signature and VerifySequence false-flags "tampered".
        -- The trailing nil keeps a gated-off fallback from storing false.
        talentString = (seq.talentString and seq.talentString ~= "" and seq.talentString)
            or ((not seq.originalAuthor or seq.originalAuthor == "") and seq.talentBuild)
            or nil,
        url = seq.url,
        classID = seq.classID or select(3, UnitClass("player")) or 0,
        specID = seq.specID,
        createdAt = seq.createdAt or time(),
        updatedAt = seq.updatedAt or time(),
        disabled = seq.disabled or nil,
    }
    -- Preserve dependency metadata onto the runtime sequence so
    -- the export-side auto-include + import-time warning path
    -- can read it. Mirror of LI.ProcessSequence preservation
    -- block in LegacyImport.lua. The GRIP1 wire format uses
    -- a flat seq.Dependencies field (top-level alongside
    -- author/version/description); we nest it under
    -- seqData.MetaData.Dependencies to match the runtime
    -- reader path at ExportPreview.lua L292 (GE.ResolveMacroDeps).
    if seq.Dependencies and type(seq.Dependencies) == "table" then
        seqData.MetaData = { Dependencies = seq.Dependencies }
    end
    -- v2.1.0 Authorship Integrity: carry provenance through the native
    -- commit path. The native exporter ships these fields; dropping them
    -- here degraded every shared sequence to the no-provenance family at
    -- the next repair pass. Mirrors the ProcessSequence carry arm in
    -- LegacyImport.lua, plus forkedFromChain (present on the wire).
    if seq.originalAuthor and seq.originalAuthor ~= "" then
        seqData.originalAuthor = seq.originalAuthor
        seqData.originalAuthorIdentity = seq.originalAuthorIdentity or ""
        seqData.originalAuthorRealm = seq.originalAuthorRealm or ""
        seqData.originalAuthorBattleTag = nil -- never trust inbound BattleTag (LOCAL ONLY)
        seqData.originalCreatedAt = seq.originalCreatedAt or 0
        seqData.originalSignature = seq.originalSignature or ""
        seqData.originalSignatureV2 = seq.originalSignatureV2 or ""
        seqData.lastModifier = seq.lastModifier or ""
        seqData.lastModifierIdentity = seq.lastModifierIdentity or ""
        seqData.lastModifierRealm = seq.lastModifierRealm or ""
        seqData.lastModifiedAt = seq.lastModifiedAt or 0
        seqData.modifierChain = {}
        if seq.modifierChain then
            for i, entry in ipairs(seq.modifierChain) do
                seqData.modifierChain[i] = entry
            end
        end
        seqData.forkedFrom = seq.forkedFrom
        seqData.forkedFromChain = {}
        if seq.forkedFromChain then
            for i, entry in ipairs(seq.forkedFromChain) do
                seqData.forkedFromChain[i] = entry
            end
        end
        seqData.provenanceSource = seq.provenanceSource or "native"
        seqData.privacyMode = seq.privacyMode or "public"
        seqData.signatureAlgorithm = seq.signatureAlgorithm or "ALG_V0_DJB2"
        if GRIPEMS.Identity then
            GRIPEMS.Identity:AppendModifierEntry(seqData, "imported")
        end
    end
    -- Absent provenance: leave fields nil; the one-shot repair pass in
    -- Core/Core.lua stamps the no-provenance family on next load.
    -- Locale: normalize every version so a native/P2P sequence stores
    -- client-locale cast text regardless of the locale it was authored or
    -- transmitted in. NormalizeVersionLocale re-tags FROM the transport steps
    -- (catalog-backed, cross-locale) then renders to the client locale.
    if SC and SC.NormalizeVersionLocale then
        for _, ver in ipairs(seqData.versions or {}) do
            SC:NormalizeVersionLocale(ver, seqData.classID)
        end
    end
    return seqData
end

--- Commit selected sequences and variables from a preview.
--- Applies user selections: import, skip, or rename each entry.
--- @param preview table The table returned by LI.Preview()
--- @param selections table User selections per index
--- @return boolean success
--- @return table results Standard import results table
function LI.CommitSelected(preview, selections)
    if not preview or not preview.ok then
        return false, "Invalid preview"
    end

    selections = selections or {}
    local seqSelections = selections.sequences or {}
    local varSelections = selections.variables or {}

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

    -- Process sequences
    for i, entry in ipairs(preview.sequences) do
        local sel = seqSelections[i]
        if sel and sel.selected and (sel.action == "import" or sel.action == "rename") then
            local name = entry.name
            if sel.action == "rename" then
                name = LI._GenerateRenameName(name)
            end

            if preview.format == "GRIP1" and entry.isCollection then
                -- GRIP1 COLLECTION entry: seqObj IS the sequence payload
                local seqData = BuildSeqDataFromGRIP1(entry.seqObj, name)
                if seqData.icon == D.QUESTION_MARK_ICON then
                    local iconID = SuggestSequenceIcon(seqData)
                    if iconID then
                        seqData.icon = iconID
                        seqData.autoIcon = true
                    end
                end
                local ver = GRIPEMS.Engine:GetActiveVersion(seqData)
                if ver and ver.steps and #ver.steps > 0 then
                    GRIPEMS.Engine:ActivateSequence(name, seqData)
                    if _G.GRIP_EMS_CHAR then
                        GRIP_EMS_CHAR.sequences = GRIP_EMS_CHAR.sequences or {}
                        GRIP_EMS_CHAR.sequences[name] = seqData
                    end
                    results.names[#results.names + 1] = name
                    results.stepCounts[name] = #ver.steps
                    results.stepFunctions[name] = ver.stepFunction or D.STEP_SEQUENTIAL
                    results.count = results.count + 1
                    if seqData.contextOverrides and next(seqData.contextOverrides) then
                        results.contextOverridesImported = results.contextOverridesImported + 1
                    end
                end
            elseif preview.format == "GRIP1" then
                -- GRIP1 single-sequence: rebuild from decoded payload
                local seq = entry.seqObj.sequence
                local seqData = BuildSeqDataFromGRIP1(seq, name)
                -- Handle single-version migration (no .versions)
                if not seq.versions or type(seq.versions) ~= "table" or not next(seq.versions) then
                    if seq.steps then
                        seqData.versions = nil
                        seqData.steps = seq.steps
                        seqData.stepFunction = seq.stepFunction or D.STEP_SEQUENTIAL
                        seqData.resetOnCombat = seq.resetCombat or false
                        seqData.resetOnTarget = seq.resetTarget or false
                        GRIPEMS.Engine:MigrateSequenceFormat(seqData)
                    end
                end
                if seqData.icon == D.QUESTION_MARK_ICON then
                    local iconID = SuggestSequenceIcon(seqData)
                    if iconID then
                        seqData.icon = iconID
                        seqData.autoIcon = true
                    end
                end

                GRIPEMS.Engine:ActivateSequence(name, seqData)
                results.names[#results.names + 1] = name
                local ver = GRIPEMS.Engine:GetActiveVersion(seqData)
                results.stepCounts[name] = ver and #ver.steps or 0
                results.stepFunctions[name] = ver and ver.stepFunction or D.STEP_SEQUENTIAL
                results.count = results.count + 1
                if seqData.contextOverrides and next(seqData.contextOverrides) then
                    results.contextOverridesImported = results.contextOverridesImported + 1
                end
            elseif preview.format == "RAW" then
                -- Raw macrotext import: compiledVersions has final steps
                local cv = entry.compiledVersions and entry.compiledVersions[1]
                if cv and cv.steps and #cv.steps > 0 then
                    local seqData = {
                        name = name,
                        icon = entry.icon or D.QUESTION_MARK_ICON,
                        defaultVersion = 1,
                        versions = {
                            [1] = {
                                stepFunction = cv.stepFunction or "Sequential",
                                keyPress = cv.keyPress or "",
                                keyRelease = cv.keyRelease or "",
                                resetOnCombat = true,
                                resetOnTarget = false,
                                resetOnGear = false,
                                resetOnSpec = false,
                                resetTimer = 0,
                                steps = cv.steps,
                            },
                        },
                    }
                    if seqData.icon == D.QUESTION_MARK_ICON then
                        local iconID = SuggestSequenceIcon(seqData)
                        if iconID then
                            seqData.icon = iconID
                            seqData.autoIcon = true
                        end
                    end
                    if SC and SC.NormalizeVersionLocale then
                        for _, ver in ipairs(seqData.versions or {}) do
                            SC:NormalizeVersionLocale(ver, seqData.classID)
                        end
                    end
                    GRIPEMS.Engine:ActivateSequence(name, seqData)
                    if _G.GRIP_EMS_CHAR then
                        GRIP_EMS_CHAR.sequences = GRIP_EMS_CHAR.sequences or {}
                        GRIP_EMS_CHAR.sequences[name] = seqData
                    end
                    results.names[#results.names + 1] = name
                    results.stepCounts[name] = #cv.steps
                    results.count = results.count + 1
                end
            else
                -- Legacy format: reuse existing ProcessSequence
                local importOk, importErr = LI.ProcessSequence(name, entry.seqObj, results, entry.opts)
                if not importOk then
                    results.warnings[#results.warnings + 1] =
                        string.format("'%s': %s", tostring(name), tostring(importErr))
                end
            end
        end
    end

    -- Process variables
    for i, entry in ipairs(preview.variables) do
        local sel = varSelections[i]
        if sel and sel.selected and sel.action == "import" then
            LI.ImportVariable(entry.name, entry.varDef, results)
        end
    end

    -- Process macros (audit Layer 1 picker-UI rewire: closes the
    -- payload.Macros half-bug from Phase 1 for picker paste users).
    -- LI.ImportMacro routes through MM:UpdateMacro which EditMacro's an
    -- existing slot or CreateMacro's a new one; the action field is
    -- effectively binary (selected != ignore).
    if preview.macros then
        local macSelections = selections.macros or {}
        for i, entry in ipairs(preview.macros) do
            local sel = macSelections[i]
            if sel and sel.selected and sel.action ~= "ignore" then
                LI.ImportMacro(entry.name, entry.node, results)
            end
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
function LI._GenerateRenameName(name)
    if not name then
        return "Unnamed (2)"
    end

    -- Check for existing " (N)" suffix
    local base, num = name:match("^(.+) %((%d+)%)$")
    if base and num then
        return base .. " (" .. (tonumber(num) + 1) .. ")"
    end

    return name .. " (2)"
end
