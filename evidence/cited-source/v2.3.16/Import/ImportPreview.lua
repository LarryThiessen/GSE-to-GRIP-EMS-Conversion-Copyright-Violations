-- GRIP-EMS: ImportPreview
-- Created: 2026-03-20
-- Updated: 2026-07-30
-- Patch: 12.0.7.68453 Midnight (Retail LIVE)

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
        -- type(), not truthiness: these are payload fields, and the length
        -- operator raises on a number or boolean. Handing a non-table straight
        -- through to the UI would also give the picker a chain it cannot walk.
        chainLength = (type(seqObj.modifierChain) == "table" and #seqObj.modifierChain) or 0,
        modifierChain = type(seqObj.modifierChain) == "table" and seqObj.modifierChain or {},
        forkedFrom = seqObj.forkedFrom,
        forkedFromChain = type(seqObj.forkedFromChain) == "table" and seqObj.forkedFromChain or {},
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
        -- Phase 2b: capture tagged payload before translating to names.
        -- type(), not truthiness: ver.steps is a payload field and ipairs on a
        -- number or boolean raises "bad argument #1 to 'ipairs'".
        if type(ver.steps) == "table" then
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

--- Attach a Forge envelope's attribution to every preview sequence entry.
--- Each entry carries the forge block for the UI, threads the commit opts so
--- the commit rail runs LI.ApplyForgeProvenance, and mirrors the post-commit
--- provenance so the preview panel matches what ProcessSequence will stamp.
--- Shared by both FRG1 payload kinds so legacy and native previews attribute
--- identically (export-path design doc, site 6).
--- @param sequences table|nil Array of preview sequence entries
--- @param forge table The validated envelope forge attribution block
local function ApplyForgePreviewAttribution(sequences, forge)
    for _, entry in ipairs(sequences or {}) do
        entry.forge = forge
        entry.opts = entry.opts or {}
        entry.opts.forgeProvenance = forge
        if entry.provenance then
            entry.provenance.provenanceSource = "forge-import"
            entry.provenance.originalAuthor = "GRIP Forge"
            entry.provenance.forgeAuthor = forge.author or ""
        end
    end
end

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

    -- FRG1 (GRIP Forge export envelope): validate, then route on the payload
    -- kind the validator reports (export-path design doc, site 6).
    --   native -- a GRIP-EMS COLLECTION payload: previewed by the native
    --             helper and returned directly, because the legacy walk below
    --             would misreport it as a legacy export.
    --   legacy -- a legacy-shaped COLLECTION payload: unwrapped here so the
    --             preview walk below analyzes it, exactly as before.
    -- Either way the envelope forge block attaches to every preview entry so
    -- the commit rail stamps the forge-import family.
    local forgeProvenance = nil
    if format == "FRG1" then
        local forge, verr, payloadKind = LI.ValidateForgeEnvelope(decoded)
        if not forge then
            return { ok = false, error = verr }
        end
        if payloadKind == "native" then
            local nativeResult = LI._PreviewNativePayload(decoded.payload)
            if not nativeResult.ok then
                return nativeResult
            end
            nativeResult.format = "FRG1"
            nativeResult.payloadKind = "native"
            nativeResult.forge = forge
            ApplyForgePreviewAttribution(nativeResult.sequences, forge)
            return nativeResult
        end
        forgeProvenance = forge
        decoded = decoded.payload
    end

    local result = {
        ok = true,
        format = (format == "FRG1") and "FRG1" or "GSE3",
        payloadKind = (format == "FRG1") and "legacy" or nil,
        forge = forgeProvenance,
        sequences = {},
        variables = {},
        macros = {},
        warnings = {},
    }

    -- COLLECTION format
    if type(decoded) == "table" and decoded.type == "COLLECTION" then
        local payload = decoded.payload
        -- type(), not truthiness: the walk below calls pairs() on this field,
        -- and pairs raises on a number, a boolean AND a string. Measured
        -- pre-guard: "bad argument #1 to 'pairs' (table expected, got number)".
        if type(payload) ~= "table" or type(payload.Sequences) ~= "table" then
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
                        result.warnings[#result.warnings + 1] = "Variable '"
                            .. tostring(varName)
                            .. "': failed to decode"
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
                        result.warnings[#result.warnings + 1] = "Macro '" .. tostring(macName) .. "': failed to decode"
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

    -- Forge attribution (site 6): the legacy-payload FRG1 route attributes
    -- through the same helper the native route uses.
    if forgeProvenance then
        ApplyForgePreviewAttribution(result.sequences, forgeProvenance)
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
--- S.Encode and dispatch identically post-decode. This is the string entry
--- point only: decode plus the format check, then delegate to
--- LI._PreviewNativePayload. The FRG1 v2 route calls that helper directly
--- with the native payload lifted out of the Forge envelope.
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
    return LI._PreviewNativePayload(decoded)
end

--- Preview an already-decoded GRIP-EMS native payload.
--- Takes the decoded {format="GRIP-EMS", ...} table -- from an !EMS1!/!GRIP1!
--- string via LI._PreviewGRIP1, or from the payload slot of an FRG1 Forge
--- envelope -- and returns the preview result. The caller owns the decode
--- step and any envelope validation.
--- @param decoded table|any The decoded native payload table
--- @return table Preview result table
function LI._PreviewNativePayload(decoded)
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
        -- A pasted payload can key decoded.sequences with any type, and a
        -- non-text name reaches the name-sort below and errors out. Filter the
        -- keys rather than wrapping the 44-line body: same outcome, reviewable
        -- diff. The variables walk just below uses if/else because its body is
        -- short enough that the reindent is free. Do not "unify" the two.
        local safeSequences = {}
        for seqName, seqPayload in pairs(decoded.sequences or {}) do
            if type(seqName) == "string" then
                safeSequences[seqName] = seqPayload
            else
                colResult.warnings[#colResult.warnings + 1] = "Skipped a sequence with a non-text name"
            end
        end
        -- Iterate the filtered sequences (name -> seqPayload)
        for seqName, seqPayload in pairs(safeSequences) do
            -- type(), not truthiness: versions and steps are payload fields, so
            -- a number or boolean reaches an index or a length operator and
            -- raises. A STRING does not raise -- # returns its length -- but it
            -- yields a nonsense count, so it is excluded here too.
            local payloadVersions = type(seqPayload.versions) == "table" and seqPayload.versions or nil
            local ver = payloadVersions and payloadVersions[seqPayload.defaultVersion or 1]
            local stepCount = (ver and type(ver.steps) == "table" and #ver.steps) or 0
            local versionCount = (type(payloadVersions) == "table" and #payloadVersions) or 0
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
            local freeVer = payloadVersions and (payloadVersions[seqPayload.defaultVersion or 1] or payloadVersions[1])
            if freeVer and type(freeVer.steps) == "table" then
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
            -- A pasted payload can carry any key type. A non-text name can never
            -- be valid (ValidateName refuses it at commit time), and letting one
            -- reach colResult.variables makes the sort comparator below compare a
            -- number against a string and error out.
            if type(varName) ~= "string" then
                colResult.warnings[#colResult.warnings + 1] = "Skipped a variable with a non-text name"
            else
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

    if type(decoded.name) ~= "string" or decoded.name == "" then
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

    local malformedSteps = false
    if seq.versions and type(seq.versions) == "table" and next(seq.versions) then
        versionCount = #seq.versions
        local defaultIdx = seq.defaultVersion or 1
        local defaultVer = seq.versions[defaultIdx] or seq.versions[1]
        if defaultVer then
            stepCount = (type(defaultVer.steps) == "table" and #defaultVer.steps) or 0
            stepFunction = defaultVer.stepFunction or D.STEP_SEQUENTIAL
        end
    elseif type(seq.steps) == "table" then
        -- type(), not truthiness: a number or boolean steps field reached the
        -- length operator below and raised "attempt to get length of field
        -- 'steps'". A string did not raise but produced a nonsense count.
        versionCount = 1
        stepCount = #seq.steps
        stepFunction = seq.stepFunction or D.STEP_SEQUENTIAL
    elseif seq.steps ~= nil then
        -- Present but not a table. stepCount stays 0, which is the correct
        -- count -- but a well-formed-looking zero hides the fact that the
        -- payload was malformed, so the preview says so instead.
        malformedSteps = true
    end

    -- Freeform detection
    local freeformCount = 0
    local freeVersions = type(seq.versions) == "table" and seq.versions or nil
    local freeVer = (freeVersions and freeVersions[seq.defaultVersion or 1]) or (freeVersions and freeVersions[1])
    if freeVer and type(freeVer.steps) == "table" then
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
    if malformedSteps then
        result.warnings[#result.warnings + 1] =
            string.format(L["GEMS_IMPORT_PREVIEW_STEPS_MALFORMED"], tostring(seqName))
    end

    -- GRIP1 v5+: extract bundled variables (mirrors COLLECTION branch)
    for varName, varDef in pairs(decoded.variables or {}) do
        -- A pasted payload can carry any key type. A non-text name can never
        -- be valid (ValidateName refuses it at commit time), and letting one
        -- reach result.variables makes the sort comparator below compare a
        -- number against a string and error out.
        if type(varName) ~= "string" then
            result.warnings[#result.warnings + 1] = "Skipped a variable with a non-text name"
        else
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
    -- A pasted payload can key its tables with any type. A non-text name is
    -- unrenderable in the picker (ImportFrame.lua:544 SetText) and can never
    -- pass ValidateName at commit time, so drop it here with a warning.
    if type(seqName) ~= "string" then
        result.warnings[#result.warnings + 1] = "Skipped a sequence with a non-text name"
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
        -- Shape-tested, not truthiness-tested: a scalar compiled.steps passes
        -- a truthiness gate and raises at the ipairs immediately below.
        --
        -- 15p CORRECTION: THIS GATE IS INERT ON THE REAL CALL PATH, and the
        -- 15o report was wrong to name this site the cheapest next behavioural
        -- proof -- it is the one that CANNOT be behaviourally proven. compiled
        -- is the return of LI.CompileMacroVersion. That function declares
        -- "local steps = {}" once, mutates it only through
        -- "steps[#steps + 1] = ...", never reassigns it, and returns it from
        -- all three of its exits. compiled.steps is therefore a table BY
        -- CONSTRUCTION -- never nil, never a scalar -- so the type() test can
        -- never evaluate false through the real path, and a fixture whose
        -- compiled.steps is a scalar can only be built by stubbing
        -- LI.CompileMacroVersion into returning a shape it cannot return.
        -- That is not a behavioural proof of anything. THE GUARD STAYS: it is
        -- correct defence in depth against a future rewrite of that function
        -- and it costs nothing. Only the claim about it was wrong.
        --
        -- AND THE TWO BARE READS BRACKETING IT ARE BARE FOR THE SAME REASON
        -- AND ARE NOT HOLES:
        --   above   stepCount = compiled.steps and #compiled.steps or 0
        --   below   if compiled.steps then / ipairs(compiled.steps)
        -- A later pass must NOT "fix" either one, and must not read them out
        -- of the .steps census D bucket as defects.
        if
            type(compiled.steps) == "table"
            and GRIPEMS.SpellValidator
            and GRIPEMS.SpellCache
            and GRIPEMS.SpellCache.ready
        then
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
    -- Asymmetric with the guard above on purpose: nothing to add is silent,
    -- but dropping USER data warns, because the user is about to approve a
    -- list that no longer contains it.
    if type(name) ~= "string" then
        result.warnings[#result.warnings + 1] = "Skipped a variable with a non-text name"
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
    if type(name) ~= "string" then
        result.warnings[#result.warnings + 1] = "Skipped a macro with a non-text name"
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
        -- type(), not truthiness: byte-identical code to the GRIPExport twin,
        -- on the same two fields. ipairs raises on a string as well as on a
        -- number or boolean, so no shape is tolerated here.
        if type(seq.modifierChain) == "table" then
            for i, entry in ipairs(seq.modifierChain) do
                seqData.modifierChain[i] = entry
            end
        end
        seqData.forkedFrom = seq.forkedFrom
        seqData.forkedFromChain = {}
        if type(seq.forkedFromChain) == "table" then
            for i, entry in ipairs(seq.forkedFromChain) do
                seqData.forkedFromChain[i] = entry
            end
        end
        -- An absent provenanceSource on the wire is not local authorship, so
        -- the old "native" default was wrong twice over: an inbound payload is
        -- by definition foreign, and "native" is not in the VerifySequence
        -- whitelist, which made any third-party payload read as damaged.
        -- "no-provenance" IS whitelisted and is exactly what the Core.lua
        -- repair pass already stamps for this case.
        seqData.provenanceSource = seq.provenanceSource or "no-provenance"
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
        for _, ver in ipairs(type(seqData.versions) == "table" and seqData.versions or {}) do
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

    -- Native GRIP-EMS preview rail. A GRIP1/EMS1 string previews as
    -- format "GRIP1"; a Forge envelope carrying a GRIP-EMS native payload
    -- previews as format "FRG1" with payloadKind "native". Both produce the
    -- same entry shape (seqObj IS the native payload), so both commit
    -- through the native branches below. The forge attribution rides along
    -- on entry.opts.forgeProvenance, which those branches apply directly --
    -- the legacy rail gets it via LI.ProcessSequence instead.
    local isForgeNative = preview.format == "FRG1" and preview.payloadKind == "native"
    local isNativePreview = preview.format == "GRIP1" or isForgeNative

    -- Process sequences
    for i, entry in ipairs(preview.sequences) do
        local sel = seqSelections[i]
        if sel and sel.selected and (sel.action == "import" or sel.action == "rename") then
            local name = entry.name
            if sel.action == "rename" then
                name = LI._GenerateRenameName(name)
            end

            if isNativePreview and entry.isCollection then
                -- Native COLLECTION entry: seqObj IS the sequence payload
                local seqData = BuildSeqDataFromGRIP1(entry.seqObj, name)
                if seqData.icon == D.QUESTION_MARK_ICON then
                    local iconID = SuggestSequenceIcon(seqData)
                    if iconID then
                        seqData.icon = iconID
                        seqData.autoIcon = true
                    end
                end
                if entry.opts and entry.opts.forgeProvenance then
                    LI.ApplyForgeProvenance(seqData, entry.opts.forgeProvenance)
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
            elseif isNativePreview then
                -- Native single-sequence: rebuild from decoded payload
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
                if entry.opts and entry.opts.forgeProvenance then
                    LI.ApplyForgeProvenance(seqData, entry.opts.forgeProvenance)
                end

                GRIPEMS.Engine:ActivateSequence(name, seqData)
                results.names[#results.names + 1] = name
                local ver = GRIPEMS.Engine:GetActiveVersion(seqData)
                -- type(), not truthiness, and it guards ver.steps as well as
                -- ver -- unlike its neighbours at :1245 and :1297, this line
                -- guarded only ver. Measured: a version present with steps
                -- ABSENT raises "attempt to get length of field 'steps' (a nil
                -- value)", which is a live defect independent of shape
                -- corruption; a string steps field does not raise at all and
                -- fabricates a count from its character length (4 for "text").
                results.stepCounts[name] = (ver and type(ver.steps) == "table" and #ver.steps) or 0
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
                        for _, ver in ipairs(type(seqData.versions) == "table" and seqData.versions or {}) do
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
                -- Legacy format: reuse existing ProcessSequence. pcall
                -- contains corrupt or hostile payloads whose action entries
                -- raise on field access; the failure becomes a per-sequence
                -- import warning instead of aborting the whole import.
                -- Snapshot the stat counters first: a mid-compile failure
                -- leaves partial increments behind (over-counted import
                -- stats), so a failed sequence rolls back to the pre-call
                -- totals and contributes exactly one warning line.
                local statKeys = {
                    "count",
                    "contextOverridesImported",
                    "versionsDropped",
                    "pausesConverted",
                    "pauseSteps",
                    "embedsSkipped",
                    "truncatedSteps",
                }
                local statSnap = {}
                for _, k in ipairs(statKeys) do
                    statSnap[k] = results[k]
                end
                local namesBefore = #results.names
                local warningsBefore = #results.warnings
                local pcallOk, importOk, importErr = pcall(LI.ProcessSequence, name, entry.seqObj, results, entry.opts)
                if not pcallOk then
                    for _, k in ipairs(statKeys) do
                        results[k] = statSnap[k]
                    end
                    for j = #results.names, namesBefore + 1, -1 do
                        local rolledName = results.names[j]
                        results.stepCounts[rolledName] = nil
                        results.stepFunctions[rolledName] = nil
                        results.names[j] = nil
                    end
                    for j = #results.warnings, warningsBefore + 1, -1 do
                        results.warnings[j] = nil
                    end
                    importOk, importErr = false, tostring(importOk)
                end
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
