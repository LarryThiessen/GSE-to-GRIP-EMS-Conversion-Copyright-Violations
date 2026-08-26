-- GRIP-EMS: LegacyImport
-- Created: 2026-04-03
-- Updated: 2026-07-02
-- Patch: 12.0.7.68256 Midnight (Retail LIVE)

-- GRIP-EMS: Legacy Import Parser
-- Legacy format parser and flat action compiler for importing external sequences

local ADDON_NAME, GRIPEMS = ...
local L = LibStub("AceLocale-3.0"):GetLocale("GRIP-EMS", true)
local D = GRIPEMS.Defaults
local S = GRIPEMS.Serialization
local VS = GRIPEMS.VariableStore

GRIPEMS.LegacyImport = {}
local LI = GRIPEMS.LegacyImport

-- Legacy MetaData context fields that map 1:1 to GRIP-EMS context keys.
-- "Normal" is a newer alias used by some authors; treated as a context like
-- the others, but ALSO consulted as a fallback for MetaData.Default when
-- the legacy MetaData omits Default explicitly. Keep it first so the
-- alias-as-default routing in MapLegacyContextOverrides and ProcessSequence
-- finds it without scanning past the canonical keys.
local LEGACY_CONTEXT_FIELDS = {
    "Normal",
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

--- Parse a Forge envelope timestamp (YYYYMMDDHHMMSS string) into epoch seconds.
--- Returns 0 for anything else: non-string input, wrong length/shape, or a
--- time() failure on out-of-range field values.
--- @param s string|nil Timestamp string from the envelope's forge.exportedAt
--- @return number Epoch seconds, or 0 when the input cannot be parsed
local function _ParseForgeTimestamp(s)
    if type(s) ~= "string" then
        return 0
    end
    local year, month, day, hour, min, sec = s:match("^(%d%d%d%d)(%d%d)(%d%d)(%d%d)(%d%d)(%d%d)$")
    if not year then
        return 0
    end
    local ok, epoch = pcall(time, {
        year = tonumber(year),
        month = tonumber(month),
        day = tonumber(day),
        hour = tonumber(hour),
        min = tonumber(min),
        sec = tonumber(sec),
    })
    if ok and type(epoch) == "number" then
        return epoch
    end
    return 0
end
LI._ParseForgeTimestamp = _ParseForgeTimestamp

--- Validate a decoded GRIP Forge export envelope (FRG1).
--- The envelope wraps a COLLECTION payload with a forge attribution block:
--- { type = "FORGE_EXPORT", formatVersion = N, forge = { author, ... },
---   payload = { type = "COLLECTION", ... } }.
--- @param decoded table|any The decoded FRG1 payload
--- @return table|nil forge The envelope's forge attribution block on success
--- @return string|nil error Error message on failure
function LI.ValidateForgeEnvelope(decoded)
    if type(decoded) ~= "table" or decoded.type ~= "FORGE_EXPORT" then
        return nil, "Forge export: payload is not a FORGE_EXPORT envelope"
    end
    local formatVersion = tonumber(decoded.formatVersion) or 0
    if formatVersion > D.FRG1_FORMAT_VERSION then
        return nil,
            "Forge export format v"
                .. tostring(decoded.formatVersion)
                .. " is newer than this GRIP-EMS supports. Update GRIP-EMS."
    end
    if type(decoded.forge) ~= "table" or type(decoded.forge.author) ~= "string" or decoded.forge.author == "" then
        return nil, "Forge export: missing required attribution (forge.author)"
    end
    if type(decoded.payload) ~= "table" or decoded.payload.type ~= "COLLECTION" then
        return nil, "Forge export: payload is not a COLLECTION"
    end
    return decoded.forge, nil
end

--- Stamp the forge-import provenance family onto seqData. Forge envelopes
--- carry a fixed "GRIP Forge" byline; the envelope's forge block (author,
--- exportedAt, and any forward-compatible keys) is preserved verbatim under
--- seqData.importMeta.forge so future UI consumers can read the attribution.
--- @param seqData table The sequenceData under construction in ProcessSequence
--- @param forge table The validated envelope forge attribution block
function LI.ApplyForgeProvenance(seqData, forge)
    seqData.originalAuthor = "GRIP Forge"
    seqData.originalAuthorIdentity = ""
    seqData.originalAuthorRealm = ""
    seqData.originalAuthorBattleTag = nil -- never trust inbound BattleTag (LOCAL ONLY)
    seqData.originalCreatedAt = LI._ParseForgeTimestamp(forge.exportedAt)
    seqData.originalSignature = ""
    seqData.modifierChain = {}
    seqData.provenanceSource = "forge-import"
    seqData.privacyMode = "public"
    seqData.signatureAlgorithm = "ALG_V0_DJB2"
    -- Shallow-copy every forge key; unknown keys are preserved untouched
    -- (forward compatibility per the export-path design doc, section 4.2).
    seqData.importMeta = seqData.importMeta or {}
    seqData.importMeta.forge = {}
    for k, v in pairs(forge) do
        seqData.importMeta.forge[k] = v
    end
    if GRIPEMS.Identity then
        GRIPEMS.Identity:AppendModifierEntry(seqData, "imported-from-forge")
    end
end

--- Decode an encoded string, falling back to registered plugin import providers when no
--- built-in format matches. Built-in formats win (S.Decode first); a recognized-but-failed
--- format keeps its own error and is NOT offered to providers. Only a literal
--- "Unknown format" result is passed to GRIPEMS._importProviders, in registration order:
--- a provider with Detect is asked first; one without Detect has Parse attempted directly.
--- The first provider whose Parse returns a table wins; that table must be the same shape
--- S.Decode yields (COLLECTION or simple payload) so it flows through ProcessSequence and
--- the secret-value guards unchanged. Detect/Parse run in pcall.
--- @param encodedString string
--- @return boolean success
--- @return table|string result Decoded table on success, error message on failure
--- @return string|nil source built-in format name, or the matching provider id
function LI.DecodeWithProviders(encodedString)
    local ok, decoded, fmt = S.Decode(encodedString)
    if ok then
        return true, decoded, fmt
    end
    if decoded ~= "Unknown format" then
        return false, decoded, fmt
    end
    local providers = GRIPEMS._importProviders
    if type(providers) == "table" then
        for i = 1, #providers do
            local p = providers[i]
            local matched = true
            if p.Detect then
                local detOk, det = pcall(p.Detect, p, encodedString)
                matched = (detOk and det) and true or false
            end
            if matched then
                local parseOk, parsed = pcall(p.Parse, p, encodedString)
                if parseOk and type(parsed) == "table" then
                    return true, parsed, p.id
                end
            end
        end
    end
    return false, "Unknown format"
end

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

    -- Check if this is a GRIP-EMS native format (EMS1 v2.1.0+, GRIP1 legacy).
    -- Both encode the same {format="GRIP-EMS", version=N, name, sequence, ...}
    -- payload shape via S.Encode; only the prefix differs. Route both through
    -- the preview/commit path so v2.1.0+ exports import cleanly.
    local format = S.DetectFormat(encodedString)
    if format == "GRIP1" or format == "EMS1" then
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
    local ok, decoded = LI.DecodeWithProviders(encodedString)
    if not ok then
        return false, decoded
    end

    -- FRG1 (GRIP Forge export envelope): validate, then unwrap the inner
    -- COLLECTION so the existing branch below compiles it. The envelope's
    -- forge attribution block rides through collectionOpts as forgeProvenance
    -- and ProcessSequence stamps the forge-import provenance family.
    local forgeProvenance = nil
    if format == "FRG1" then
        local forge, verr = LI.ValidateForgeEnvelope(decoded)
        if not forge then
            return false, verr
        end
        forgeProvenance = forge
        decoded = decoded.payload
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
        macrosImported = 0,
        macrosSkipped = 0,
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

        -- Thread the COLLECTION payload through opts so the dependency
        -- check inside ProcessSequence can see the sibling Macros /
        -- Sequences tables. Only the COLLECTION path supplies a payload;
        -- the simple-array and migrate paths leave opts.payload nil and
        -- the dependency check falls back to local stores.
        local collectionOpts = { payload = payload, forgeProvenance = forgeProvenance }
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
                    local importOk, importErr =
                        LI.ProcessSequence(innerDecoded[1], innerDecoded[2], results, collectionOpts)
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
                local importOk, importErr = LI.ProcessSequence(seqName, seqValue, results, collectionOpts)
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

        -- Import macros from COLLECTION payload (audit Layer 1: closes
        -- the MOONSPAM gap). Each entry is either a raw macro node table
        -- or a double-encoded string; both shapes route through
        -- LI.ImportMacro which enqueues an OOC importmacro action.
        if payload.Macros and type(payload.Macros) == "table" then
            for macName, macValue in pairs(payload.Macros) do
                if type(macValue) == "string" then
                    local mOk, mDecoded = S.Decode(macValue)
                    if mOk and type(mDecoded) == "table" then
                        LI.ImportMacro(macName, mDecoded, results)
                    else
                        results.warnings[#results.warnings + 1] = "Macro '" .. macName .. "': failed to decode"
                    end
                elseif type(macValue) == "table" then
                    LI.ImportMacro(macName, macValue, results)
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
    -- Default takes precedence; Normal is an alias used by newer formats.
    -- If Default is omitted but Normal is set, Normal becomes the active
    -- version index and any per-context entry equal to that index is
    -- treated as "use default" (skipped) for parity with Default routing.
    local defaultIdx = tonumber(metadata.Default) or tonumber(metadata.Normal) or 1
    for _, field in ipairs(LEGACY_CONTEXT_FIELDS) do
        local idx = tonumber(metadata[field])
        if idx and idx >= 1 and idx <= numVersions and idx ~= defaultIdx then
            overrides[field] = idx
        end
    end
    return overrides
end

--- True when a macro field is a bare macro NAME. A leading /, #, or = means the
--- value is macrotext; anything else references a /macro by name and the body
--- must be inlined so the step does not type the name into chat.
function LI._IsBareMacroName(s)
    if type(s) ~= "string" or s == "" then
        return false
    end
    local first = s:sub(1, 1)
    return first ~= "/" and first ~= "#" and first ~= "="
end

--- Build a name -> body map from a COLLECTION payload's Macros table so a
--- bare-name macro step can be inlined with the bundled body. Macro nodes carry
--- the body in text (preferred) or manageMacro. Returns {} when no payload or no
--- Macros table is present.
function LI._BuildMacroBodyMap(payload)
    local map = {}
    if type(payload) == "table" and type(payload.Macros) == "table" then
        for name, node in pairs(payload.Macros) do
            if type(node) == "table" then
                local body = node.text or node.manageMacro
                if type(body) == "string" and body ~= "" then
                    map[name] = body
                end
            end
        end
    end
    return map
end

--- Resolve a bare macro name to its body. Import-time priority: the in-flight
--- COLLECTION payload (LI._importMacroBodies), then a stored EMS macro, then a
--- live /macro of the same name. Returns nil when nothing has the body, so the
--- caller keeps the bare name and the existing dependency warning fires.
function LI._ResolveMacroBody(name)
    if type(name) ~= "string" or name == "" then
        return nil
    end
    if LI._importMacroBodies and LI._importMacroBodies[name] then
        return LI._importMacroBodies[name]
    end
    local MM = GRIPEMS.MacroManager
    if MM then
        if MM.GetStored then
            local stored = MM:GetStored(name)
            if stored and (stored.text or stored.manageMacro) then
                return stored.text or stored.manageMacro
            end
        end
        if MM.SnapshotByName then
            local snap = MM:SnapshotByName(name)
            if snap and snap.text and snap.text ~= "" then
                return snap.text
            end
        end
    end
    return nil
end

--- Heal one macrotext field (a flat step, keyPress, or keyRelease) that may be a
--- bare macro NAME left by a pre-fix import. Returns the resolved body in display
--- form when the value is a bare name that resolves to a stored / live macro,
--- otherwise the value unchanged. The boolean reports whether a heal happened.
--- @param s any A step / keyPress / keyRelease value
--- @return any healed The macro body when healed, else s unchanged
--- @return boolean changed True when a bare name was resolved and replaced
function LI._HealBareMacroField(s)
    if LI._IsBareMacroName(s) then
        local body = LI._ResolveMacroBody(s)
        if body and body ~= "" then
            return LI.ResolveSpellIDsInMacrotext(body), true
        end
    end
    return s, false
end

--- Heal one action-tree node in place: a bare-name macro action becomes a macro-
--- ref node carrying the inlined body, matching what the fixed import produces.
--- Leaf only -- containers (loop / if) are walked by the caller via SC:_WalkActions.
--- macroTagged is cleared so the caller's NormalizeVersionLocale pass regenerates
--- it from the healed macro.
--- @param node table An action-tree node
--- @return boolean changed True when the node was converted
function LI._HealBareMacroNode(node)
    if type(node) ~= "table" or node.type ~= D.ACTION_TYPE_ACTION then
        return false
    end
    if not LI._IsBareMacroName(node.macro) then
        return false
    end
    local body = LI._ResolveMacroBody(node.macro)
    if not body or body == "" then
        return false
    end
    node.subtype = D.ACTION_SUBTYPE_MACROREF
    node.macroName = node.macro
    node.macro = LI.ResolveSpellIDsInMacrotext(body)
    node.macroTagged = nil
    return true
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

    -- Pick the default macro version index. MetaData.Default is the
    -- canonical key; MetaData.Normal is a newer alias used when Default
    -- is omitted. If both are set, Default takes precedence.
    local defaultIdx = 1
    if sequence.MetaData then
        if sequence.MetaData.Default then
            defaultIdx = tonumber(sequence.MetaData.Default) or 1
        elseif sequence.MetaData.Normal then
            defaultIdx = tonumber(sequence.MetaData.Normal) or 1
        end
    end
    if defaultIdx < 1 or defaultIdx > #macros then
        defaultIdx = 1
    end

    -- Build the bundled macro-body map for this import so bare-name macro steps
    -- inline the body instead of typing the macro name into chat. Every
    -- ProcessSequence call rebuilds it; the migrate and simple-array paths pass
    -- no payload and get an empty map, falling back to stored / live macros
    -- inside LI._ResolveMacroBody.
    LI._importMacroBodies = LI._BuildMacroBodyMap(opts and opts.payload)

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

    -- E2 fix + ARCH-MIGRATE Phase 2: imported versions carry baked flat
    -- steps whose transforms the activation-time recompile does not
    -- reproduce (interval interleaving in-line base step + unclamped
    -- eligibility, embed/variable/conditional semantic differences, and
    -- the taggedSteps locale sidecars that key off the baked array).
    -- importBakedSteps marks these versions; the three activation-class
    -- CompileActions sites skip recompilation for them, so baked steps
    -- stay authoritative until an explicit editor save of that version
    -- clears the flag. The action tree survives import as of Phase 2:
    -- the editor's native block UI reads it directly, and the locale
    -- normalization loop below covers node macros alongside the flat
    -- steps (the NormalizeVersionLocale tree walk tags node.macroTagged
    -- and renders node.macro to the client locale).
    for _, ver in ipairs(versions) do
        ver.importBakedSteps = true
    end

    -- L500 Strategy A Phase 1: tag every version with spell IDs for talent /
    -- locale protection. Mirrors the edit-path retag loop in
    -- Engine:UpdateSequenceData (Engine/Engine.lua) and the Phase-2a
    -- one-time migration in Data/SpellCache.lua. Without this, legacy
    -- imports land in SavedVariables with
    -- name-baked macrotext only, and a respec or talent change leaves the
    -- stored macrotext stale until re-import. See
    -- Research/L500_Override_Resolution_Design_2026-05-16.md "Strategy A".
    local SC = GRIPEMS.SpellCache
    if SC and SC.ready then
        -- Q2 Phase 4: author class for collision resolution. Mirrors how seqData.classID is
        -- derived below (opts.classID override, else player class). On a cross-class library
        -- import (LegacyMigrate sets opts.classID) this tags to the AUTHOR's class.
        local authorClassID = (opts and opts.classID) or select(3, UnitClass("player")) or 0
        for _, ver in ipairs(versions) do
            SC:NormalizeVersionLocale(ver, authorClassID)
        end
    else
        -- SpellCache not ready at import time (rare: import fires during the
        -- pre-cache-ready window after PLAYER_LOGIN). Set the existing pending
        -- migration flag so the RunPendingTagMigration pass in
        -- Data/SpellCache.lua picks these versions up when the cache is
        -- ready. Same recovery path the global Phase-2a migration uses.
        if _G.GRIP_EMS_DB then
            GRIP_EMS_DB.pendingTagMigration = true
        end
    end

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
        -- Preserve dependency metadata onto the runtime sequence so
        -- post-import lookups (ResolveMacroDeps + future deps surfaces)
        -- can read it. Selective copy under MetaData.Dependencies to
        -- match the source-format field name expected by readers at
        -- ExportPreview.lua L292-298.
        if sequence.MetaData.Dependencies and type(sequence.MetaData.Dependencies) == "table" then
            seqData.MetaData = seqData.MetaData or {}
            seqData.MetaData.Dependencies = sequence.MetaData.Dependencies
        end
    end

    -- v2.3.3 Phase 1: enriched exporters emit the merged deps as a TOP-LEVEL
    -- Dependencies field on the wire sequence; this path previously read
    -- MetaData.Dependencies only, dropping the top-level field entirely.
    -- MetaData.Dependencies wins when both are present.
    if type(sequence.Dependencies) == "table" and not (seqData.MetaData and seqData.MetaData.Dependencies) then
        seqData.MetaData = seqData.MetaData or {}
        seqData.MetaData.Dependencies = sequence.Dependencies
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
            seqData.updatedAt = GRIPEMS.NormalizeUpdatedAt(opts.updatedAt) or seqData.updatedAt
        end
        if opts.classID ~= nil then
            seqData.classID = opts.classID
        end
        if opts.icon then
            seqData.icon = opts.icon
        end
    end

    -- v2.3.3 Phase 1: carry enriched native COLLECTION per-sequence metadata.
    -- Slotted between the opts overrides above (which win) and the legacy
    -- md.* fallbacks below (which still fill any remaining gaps): a top-level
    -- wire field never clobbers a value opts already set, and md.* only
    -- fills what is still empty afterwards.
    if (not seqData.author or seqData.author == "") and sequence.author and sequence.author ~= "" then
        seqData.author = sequence.author
    end
    if
        (not seqData.description or seqData.description == "")
        and sequence.description
        and sequence.description ~= ""
    then
        seqData.description = sequence.description
    end
    if (not seqData.help or seqData.help == "") and sequence.help and sequence.help ~= "" then
        seqData.help = sequence.help
    end
    if (not seqData.helplink or seqData.helplink == "") and sequence.helplink and sequence.helplink ~= "" then
        seqData.helplink = sequence.helplink
    end
    if seqData.changelog == nil and sequence.changelog ~= nil then
        seqData.changelog = sequence.changelog
    end
    if not seqData.specID and sequence.specID then
        seqData.specID = sequence.specID
    end
    if sequence.classID and (not opts or opts.classID == nil) then
        seqData.classID = sequence.classID
    end
    if sequence.createdAt then
        seqData.createdAt = sequence.createdAt
    end
    if sequence.updatedAt and (not opts or not opts.updatedAt) then
        seqData.updatedAt = GRIPEMS.NormalizeUpdatedAt(sequence.updatedAt) or seqData.updatedAt
    end
    if seqData.talentString == nil and sequence.talentString ~= nil then
        seqData.talentString = sequence.talentString
    end
    if seqData.url == nil and sequence.url ~= nil then
        seqData.url = sequence.url
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
        -- HelpTxt is the newer descriptive blurb (<=120 chars); Help is the
        -- older alias still produced by some exporters. Prefer HelpTxt when
        -- both are present so newer content wins.
        if not seqData.description or seqData.description == "" then
            if md.HelpTxt and md.HelpTxt ~= "" then
                seqData.description = md.HelpTxt
            elseif md.Help and md.Help ~= "" then
                seqData.description = md.Help
            end
        end
        if (not seqData.helplink or seqData.helplink == "") and md.Helplink and md.Helplink ~= "" then
            seqData.helplink = md.Helplink
        end
        if md.LastUpdated then
            seqData.updatedAt = GRIPEMS.NormalizeUpdatedAt(md.LastUpdated) or seqData.updatedAt
        end
    end

    -- v2.1.0 Authorship Integrity: carry forward provenance from !EMS1! payloads
    -- that embed the v2.1.0 schema directly. Legacy payloads (GSE3) lack these
    -- fields, so we stamp the gse-legacy state and a chain entry instead.
    -- Forge envelopes (FRG1) stamp the forge-import family via
    -- LI.ApplyForgeProvenance with a fixed GRIP Forge byline.
    if opts and opts.forgeProvenance then
        LI.ApplyForgeProvenance(seqData, opts.forgeProvenance)
    elseif sequence.originalAuthor and sequence.originalAuthor ~= "" then
        seqData.originalAuthor = sequence.originalAuthor
        seqData.originalAuthorIdentity = sequence.originalAuthorIdentity or ""
        seqData.originalAuthorRealm = sequence.originalAuthorRealm or ""
        seqData.originalAuthorBattleTag = nil -- never trust inbound BattleTag (LOCAL ONLY)
        seqData.originalCreatedAt = sequence.originalCreatedAt or 0
        seqData.originalSignature = sequence.originalSignature or ""
        seqData.originalSignatureV2 = sequence.originalSignatureV2 or ""
        seqData.lastModifier = sequence.lastModifier or ""
        seqData.lastModifierIdentity = sequence.lastModifierIdentity or ""
        seqData.lastModifierRealm = sequence.lastModifierRealm or ""
        seqData.lastModifiedAt = sequence.lastModifiedAt or 0
        seqData.modifierChain = {}
        if sequence.modifierChain then
            for i, entry in ipairs(sequence.modifierChain) do
                seqData.modifierChain[i] = entry
            end
        end
        seqData.forkedFrom = sequence.forkedFrom
        seqData.forkedFromChain = {}
        if type(sequence.forkedFromChain) == "table" then
            for i, entry in ipairs(sequence.forkedFromChain) do
                seqData.forkedFromChain[i] = entry
            end
        end
        seqData.provenanceSource = sequence.provenanceSource or "native"
        seqData.privacyMode = sequence.privacyMode or "public"
        seqData.signatureAlgorithm = sequence.signatureAlgorithm or "ALG_V0_DJB2"
        if GRIPEMS.Identity then
            GRIPEMS.Identity:AppendModifierEntry(seqData, "imported")
        end
    else
        seqData.originalAuthor = seqData.author or "Unknown (GSE legacy)"
        seqData.originalAuthorIdentity = ""
        seqData.originalAuthorRealm = ""
        seqData.originalAuthorBattleTag = nil
        seqData.originalCreatedAt = 0
        seqData.originalSignature = ""
        seqData.modifierChain = {}
        seqData.provenanceSource = "gse-legacy"
        seqData.privacyMode = "public"
        seqData.signatureAlgorithm = "ALG_V0_DJB2"
        -- Stamp the importer (current player) as a chain entry.
        if GRIPEMS.Identity then
            GRIPEMS.Identity:AppendModifierEntry(seqData, "imported-from-gse")
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

    -- Dependency-presence check (audit 5.6): warn when MetaData.Dependencies
    -- references a macro or sub-sequence that is neither bundled in the
    -- payload nor already present locally. Keeps the user from discovering
    -- "MOONSPAM typed into chat" mid-fight by surfacing the gap at import
    -- time. The payload is threaded through opts.payload so the COLLECTION
    -- clipboard path (which has sibling Macros / Sequences tables) and the
    -- migrate path (no payload, locals only) reuse the same logic. Reads the
    -- carried merged deps on seqData so both the legacy MetaData shape and
    -- the enriched top-level Dependencies field get missing-dep warnings.
    local carriedDeps = seqData.MetaData and seqData.MetaData.Dependencies
    if carriedDeps then
        local deps = carriedDeps
        local payload = opts and opts.payload
        if type(deps.Macros) == "table" then
            for _, depName in ipairs(deps.Macros) do
                local inPayload = payload and payload.Macros and payload.Macros[depName] ~= nil
                local inStored = GRIPEMS.MacroManager
                    and GRIPEMS.MacroManager.GetStored
                    and GRIPEMS.MacroManager:GetStored(depName) ~= nil
                local liveSlot = GetMacroIndexByName and GetMacroIndexByName(depName)
                local inWoW = liveSlot and liveSlot > 0
                if not inPayload and not inStored and not inWoW then
                    local fmt = L["GEMS_IMPORT_MACRO_DEP_MISSING"]
                        or "%s: references macro '%s' which is not in the import payload and not in your saved macros."
                            .. " The step will type '%s' into chat at runtime."
                    results.warnings[#results.warnings + 1] = string.format(fmt, seqName, depName, depName)
                end
            end
        end
        if type(deps.Sequences) == "table" then
            for _, depName in ipairs(deps.Sequences) do
                local inPayload = payload and payload.Sequences and payload.Sequences[depName] ~= nil
                local inStored = _G.GRIP_EMS_CHAR
                    and GRIP_EMS_CHAR.sequences
                    and GRIP_EMS_CHAR.sequences[depName] ~= nil
                if not inPayload and not inStored then
                    local fmt = L["GEMS_IMPORT_SEQUENCE_DEP_MISSING"]
                        or "%s: embeds sequence '%s' which is not in the import payload and not in your saved sequences."
                    results.warnings[#results.warnings + 1] = string.format(fmt, seqName, depName)
                end
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
        if action and action.Type then
            local node = LI._MapActionToNode(action)
            if node then
                tree[#tree + 1] = node
            end
        end
    end
    return tree
end

--- Map a single legacy action to an EMS action node, preserving its disabled
--- state. A disabled action becomes a normal node tagged node.disabled = true so
--- the editor shows it greyed at its original position (re-enableable); the flat
--- compiler and the activation-time recompile both skip disabled nodes, so it
--- never fires. The wrapper tags disabled for EVERY caller (top level plus nested
--- loop / if children), so the inner mapper does not special-case it.
--- @param action table Imported action object
--- @return table|nil node EMS action node (node.disabled set when Disabled), or nil
function LI._MapActionToNode(action)
    local node = LI._MapActionToNodeInner(action)
    if node and action and action.Disabled then
        node.disabled = true
    end
    return node
end

--- Inner mapper: build the node for an action's type. Disabled tagging is applied
--- by the LI._MapActionToNode wrapper above.
--- @param action table Imported action object
--- @return table|nil node EMS action node, or nil to skip
function LI._MapActionToNodeInner(action)
    if not action or not action.Type then
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
            -- Bare macro NAME: produce a macro-ref node with the inlined body so
            -- the editor renders it as a Macro step and the runtime runs the body.
            if LI._IsBareMacroName(action.macro) then
                local body = LI._ResolveMacroBody(action.macro)
                if body and body ~= "" then
                    return {
                        type = D.ACTION_TYPE_ACTION,
                        subtype = D.ACTION_SUBTYPE_MACROREF,
                        macroName = action.macro,
                        macro = LI.ResolveSpellIDsInMacrotext(body),
                    }
                end
            end
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
            local child = LI._MapActionToNode(sa)
            if child then
                children[#children + 1] = child
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

    -- Detect interval-less Repeat actions at the edges of the Actions array.
    -- A Repeat with a positive interval is a WEAVE, not a KeyPress/KeyRelease
    -- marker -- KeyPress/KeyRelease arrive as their own fields (read above).
    -- Only an interval-less edge Repeat is promoted; a weave placed first or
    -- last stays in the action list and is woven by the interval pass below,
    -- instead of firing on every key press.
    local function isEdgeKeyMarker(a)
        if not a or a.Type ~= "Repeat" then
            return false
        end
        local iv = tonumber(a.Interval) or tonumber(a.Repeat)
        return not (iv and iv > 0)
    end
    local actionsStart = 1
    local actionsEnd = #actions
    if isEdgeKeyMarker(actions[1]) then
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
    if actionsEnd >= actionsStart and isEdgeKeyMarker(actions[actionsEnd]) then
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
                    -- Only Type=="Repeat" actions weave. A Type=="Action" block
                    -- may carry a stale Interval that the source engine ignores;
                    -- it is a normal step here. Woven actions are NOT placed at
                    -- their natural position -- they are spaced through the base
                    -- steps by the shared pass below.
                    if action.Type == "Repeat" then
                        local iv = tonumber(action.Interval) or tonumber(action.Repeat) or D.ACTION_INTERLEAVE_DEFAULT
                        intervalActions[#intervalActions + 1] = {
                            macro = raw,
                            interval = iv,
                        }
                    else
                        steps[#steps + 1] = raw
                    end
                end
            end
        end
    end

    -- Weave Repeat actions through the base steps using the SAME helper
    -- the editor's ActionCompiler uses, so baked import steps are
    -- byte-identical to an editor recompile of the same tree. The throwaway
    -- labels table is required by the helper signature; the import does not
    -- use flat-step labels (they come from the action tree).
    if #intervalActions > 0 then
        if GRIPEMS.ActionCompiler and GRIPEMS.ActionCompiler.ApplyInterleaving then
            GRIPEMS.ActionCompiler.ApplyInterleaving(steps, {}, intervalActions)
        else
            GRIPEMS:Debug("CompileMacroVersion: ActionCompiler.ApplyInterleaving unavailable; weave skipped")
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
            -- Bare macro NAME (no /, #, =): inline the referenced macro body so
            -- the step runs the macro instead of typing its name into chat.
            if LI._IsBareMacroName(action.macro) then
                local body = LI._ResolveMacroBody(action.macro)
                if body and body ~= "" then
                    return { LI.ResolveSpellIDsInMacrotext(body) }
                end
            end
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
                local clickRate = GRIPEMS.Settings
                        and GRIPEMS.Settings.GetEffectiveClickRate
                        and GRIPEMS.Settings:GetEffectiveClickRate()
                    or 250
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
        -- Repeat: content is in action.macro, not sub-actions. A Repeat with
        -- a positive interval is a weave and compiles as a step (woven by the
        -- interval pass). Only an interval-less Repeat at the first/last slot
        -- is promoted by CompileMacroVersion to a keyPress/keyRelease block.
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

--- Resolve a spell ID to its currently-active override variant.
--- Wraps C_SpellBook.FindSpellOverrideByID and C_Spell.GetSpellName so a
--- base spell ID used in a legacy export (e.g. 56641 Steady Shot) resolves
--- to the variant active for the player's current talents (e.g. 217200
--- Barbed Shot when the BM override is talented). Returns nil when neither
--- the override nor the base ID maps to a valid spell name; callers fall
--- through to their own unresolved-ID accounting.
--- Mirrors Data/SpellCache.lua SafeOverrideID pattern (L91-99).
--- @param spellID number Numeric spell ID from the source payload
--- @return string|nil name Override-resolved localized spell name, nil if unresolvable
function LI._ResolveOverriddenName(spellID)
    if type(spellID) ~= "number" then
        return nil
    end
    local resolved = spellID
    if C_SpellBook and C_SpellBook.FindSpellOverrideByID then
        resolved = C_SpellBook.FindSpellOverrideByID(spellID) or spellID
    end
    local name = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(resolved)
    if name and name ~= "" then
        return name
    end
    return nil
end

--- Resolve a spell reference to a string name.
--- If spellRef is a number (spell ID), delegates to LI._ResolveOverriddenName
--- so the talent-active override variant is returned; falls back to tostring
--- when the helper cannot resolve a name.
--- @param spellRef string|number Spell name or spell ID
--- @return string Spell name as a string
function LI.ResolveSpell(spellRef)
    if spellRef == nil then
        return ""
    end

    if type(spellRef) == "number" then
        -- BUG-pershizzle: route through override-aware resolver so legacy
        -- base spell IDs (e.g. 56641 Steady Shot) map to the currently
        -- active variant (e.g. 217200 Barbed Shot under BM talents).
        local name = LI._ResolveOverriddenName(spellRef)
        if name then
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
                                -- BUG-pershizzle: route through override-aware resolver
                                -- so /cast 56641 maps to "Barbed Shot" under BM talents.
                                local name = LI._ResolveOverriddenName(numericID)
                                if name then
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
                            -- BUG-pershizzle: route through override-aware resolver
                            -- so /castsequence 56641, ... maps to "Barbed Shot, ...".
                            local name = LI._ResolveOverriddenName(numericID)
                            if name then
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
    local result = table.concat(lines, "\n")
    -- Convert legacy double-tilde variable syntax ~~var~~ to EMS single-tilde ~var~ (allows underscores)
    result = result:gsub("~~([%w_]+)~~", "~%1~")
    return result
end

--- Enqueue a macro node for OOC import. Resolves scope from the node's
--- category field ("p" = per-character, anything else = account), forwards
--- the node through GRIPEMS.OOCQueue:Enqueue (which routes to
--- MacroManager:ImportMacro on the next OOC tick), and bumps the macros
--- counters on the import results table for the post-import summary.
---
--- The scope parameter is an explicit override; when set it wins over
--- node.category. Layer 3 migration uses this to force "a"/"p" based on
--- which GSEMacros bucket the node was found under.
---
--- @param name string Macro name (used as both display name and dedup key)
--- @param node table The macro node table { name, icon, text, manageMacro, category, ... }
--- @param results table Import results accumulator (gets macrosImported / macrosSkipped bumps)
--- @param scope string|nil Optional "a" or "p" scope override
--- @return boolean|nil True if enqueued, nil on validation failure
function LI.ImportMacro(name, node, results, scope)
    if not name or name == "" or type(node) ~= "table" then
        results.macrosSkipped = (results.macrosSkipped or 0) + 1
        return nil
    end
    node.name = node.name or name
    node.category = scope or node.category or "a"
    if GRIPEMS.OOCQueue and GRIPEMS.OOCQueue.Enqueue then
        GRIPEMS.OOCQueue:Enqueue({ action = "importmacro", node = node })
    end
    results.macrosImported = (results.macrosImported or 0) + 1
    return true
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
