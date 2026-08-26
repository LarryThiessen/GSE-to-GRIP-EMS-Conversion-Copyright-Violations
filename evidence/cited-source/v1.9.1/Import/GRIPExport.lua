-- GRIP-EMS: GRIP Export
-- Native GRIP-EMS export and import for sharing sequences between users

local ADDON_NAME, GRIPEMS = ...
local L = LibStub("AceLocale-3.0"):GetLocale("GRIP-EMS")
local D = GRIPEMS.Defaults
local S = GRIPEMS.Serialization

GRIPEMS.GRIPExport = {}
local GE = GRIPEMS.GRIPExport
local SC = GRIPEMS.SpellCache

--- Prepare versions for export: deep-copy, strip locale fields,
--- translate spell tags to IDs.
--- @param seqData table Sequence data with .versions
--- @return table exportVersions
function GE.PrepareExportVersions(seqData)
    local exportVersions = {}
    if seqData.versions and type(seqData.versions) == "table" then
        for vi, ver in ipairs(seqData.versions) do
            local verCopy = {}
            for k, v in pairs(ver) do
                verCopy[k] = v
            end
            -- Strip storage-only locale fields (Phase 2b: not part of transport format)
            verCopy.taggedSteps = nil
            verCopy.taggedKeyPress = nil
            verCopy.taggedKeyRelease = nil
            verCopy.stepsLocale = nil
            -- Deep-copy actions tree for export (v4: S14-C)
            if ver.actions then
                verCopy.actions = D.DeepCopyActions(ver.actions)
            end
            -- Translate steps
            if ver.steps then
                local translatedSteps = {}
                for si, step in ipairs(ver.steps) do
                    if type(step) == "string" then
                        translatedSteps[si] = SC:TranslateMacrotext(step, "toIDs")
                    else
                        translatedSteps[si] = step
                    end
                end
                verCopy.steps = translatedSteps
            end
            -- Translate keyPress / keyRelease
            if ver.keyPress and type(ver.keyPress) == "string" then
                verCopy.keyPress = SC:TranslateMacrotext(ver.keyPress, "toIDs")
            end
            if ver.keyRelease and type(ver.keyRelease) == "string" then
                verCopy.keyRelease = SC:TranslateMacrotext(ver.keyRelease, "toIDs")
            end
            exportVersions[vi] = verCopy
        end
    end
    return exportVersions
end

--- Export an active sequence as a GRIP1-encoded string.
--- Builds a GRIP-EMS native payload and encodes it with the !GRIP1! prefix.
--- @param sequenceName string Name of the sequence to export
--- @return boolean success
--- @return string result Encoded string on success, error message on failure
function GE.Export(sequenceName)
    if not sequenceName or sequenceName == "" then
        return false, "No sequence name provided"
    end

    local entry = GRIPEMS.Engine.sequences[sequenceName]
    if not entry or not entry.data then
        return false, string.format(L["GEMS_SEND_NO_SEQ"], sequenceName)
    end

    local seqData = entry.data

    -- Prepare export versions (deep-copy + spell tag translation)
    local exportVersions = GE.PrepareExportVersions(seqData)

    -- Build GRIP1 payload (v4: action tree + locale-safe spell ID tags)
    local payload = {
        format = "GRIP-EMS",
        version = D.GRIP_FORMAT_VERSION,
        locale = GetLocale(),
        name = sequenceName,
        sequence = {
            icon = seqData.icon or D.QUESTION_MARK_ICON,
            versions = exportVersions,
            defaultVersion = seqData.defaultVersion or 1,
            author = seqData.author or "",
            description = seqData.description or "",
            help = seqData.help or "",
            helplink = seqData.helplink or "",
            classID = seqData.classID,
            specID = seqData.specID,
            createdAt = seqData.createdAt,
            updatedAt = seqData.updatedAt,
        },
    }

    -- Encode with GRIP1 prefix
    local ok, encoded = S.Encode(payload, D.GRIP1_PREFIX)
    if not ok then
        return false, "Export encoding failed: " .. tostring(encoded)
    end

    return true, encoded
end

--- Import a GRIP1-encoded string back into a sequence.
--- Validates the payload format and version, then builds sequenceData.
--- @param encodedString string The !GRIP1!-prefixed encoded string
--- @return boolean success
--- @return string nameOrError Sequence name on success, error message on failure
--- @return table|nil seqData The sequenceData table (only on success)
function GE.ImportNative(encodedString)
    local ok, decoded, format = S.Decode(encodedString)
    if not ok then
        return false, decoded
    end

    if format ~= "GRIP1" then
        return false, "Not a GRIP-EMS export string"
    end

    -- Validate payload structure
    if type(decoded) ~= "table" then
        return false, "Invalid payload (not a table)"
    end
    if decoded.format ~= "GRIP-EMS" then
        return false, "Invalid payload format: " .. tostring(decoded.format)
    end
    if not decoded.version or decoded.version > D.GRIP_FORMAT_VERSION then
        return false, "Unsupported format version: " .. tostring(decoded.version)
    end
    if not decoded.name or decoded.name == "" then
        return false, "Payload has no sequence name"
    end
    if not decoded.sequence then
        return false, "Payload has no sequence data"
    end

    -- Locale mismatch warning (CE-2)
    if decoded.locale and decoded.locale ~= GetLocale() then
        if GRIPEMS.DebugWindow then
            GRIPEMS.DebugWindow:Add(
                "Import from locale: "
                    .. decoded.locale
                    .. " (current: "
                    .. GetLocale()
                    .. ") -- check spell translations"
            )
        end
    end

    -- v3+: translate spell ID tags back to localized names
    if decoded.version >= 3 and decoded.sequence then
        local seq = decoded.sequence
        if seq.versions and type(seq.versions) == "table" then
            for _, ver in ipairs(seq.versions) do
                -- Phase 2b: capture tagged payload before translating to names
                if ver.steps then
                    local taggedSteps = {}
                    for si, step in ipairs(ver.steps) do
                        taggedSteps[si] = step
                        if type(step) == "string" then
                            ver.steps[si] = SC:TranslateMacrotext(step, "toNames")
                        end
                    end
                    ver.taggedSteps = taggedSteps
                end
                if ver.keyPress and type(ver.keyPress) == "string" then
                    ver.taggedKeyPress = ver.keyPress
                    ver.keyPress = SC:TranslateMacrotext(ver.keyPress, "toNames")
                end
                if ver.keyRelease and type(ver.keyRelease) == "string" then
                    ver.taggedKeyRelease = ver.keyRelease
                    ver.keyRelease = SC:TranslateMacrotext(ver.keyRelease, "toNames")
                end
                ver.stepsLocale = GetLocale()
            end
        end
    end

    local seq = decoded.sequence

    -- Build sequenceData from payload
    local seqData = {
        name = decoded.name,
        icon = seq.icon or D.QUESTION_MARK_ICON,
        autoIcon = seq.autoIcon,
        author = seq.author or "",
        version = "1",
        description = seq.description or "",
        help = seq.help or "",
        helplink = seq.helplink or "",
        classID = seq.classID or select(3, UnitClass("player")) or 0,
        specID = seq.specID,
        createdAt = seq.createdAt or time(),
        updatedAt = seq.updatedAt or time(),
    }

    if seq.versions and type(seq.versions) == "table" and next(seq.versions) then
        -- Format v2: versioned payload
        seqData.versions = seq.versions
        seqData.defaultVersion = seq.defaultVersion or 1
    elseif seq.steps then
        -- Format v1: flat payload -- migrate to versioned
        seqData.steps = seq.steps
        seqData.stepFunction = seq.stepFunction or D.STEP_SEQUENTIAL
        seqData.resetOnCombat = seq.resetCombat or false
        seqData.resetOnTarget = seq.resetTarget or false
        GRIPEMS.Engine:MigrateSequenceFormat(seqData)
    else
        return false, "Payload has no sequence steps or versions"
    end

    local ver = GRIPEMS.Engine:GetActiveVersion(seqData)
    if not ver or not ver.steps or #ver.steps == 0 then
        return false, "Imported sequence has no steps"
    end

    return true, decoded.name, seqData
end

---------------------------------------------------------------------------
-- GE.ExportAsText(seqNames, varNames)
-- Build a human-readable plain-text summary of selected sequences.
---------------------------------------------------------------------------

--- Resolve a sequence icon field to a readable name.
--- @param icon number|string|nil Icon value from seqData
--- @return string Readable icon label
local function ResolveIconName(icon)
    if not icon then
        return "(none)"
    end
    if type(icon) == "number" then
        local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(icon)
        if info and info.name then
            return info.name
        end
        return tostring(icon)
    end
    return tostring(icon)
end

--- Resolve a spec ID to a human-readable spec name.
--- @param specID number|nil Spec ID from seqData
--- @return string Spec name or "(any)"
local function ResolveSpecName(specID)
    if not specID then
        return "(any)"
    end
    if GetSpecializationInfoByID then -- luacheck: ignore 113
        local _, sName = GetSpecializationInfoByID(specID) -- selene: allow(undefined_variable)
        if sName then
            return sName
        end
    end
    return tostring(specID)
end

--- Format a single version block as indented text lines.
--- @param ver table Version data
--- @param vIdx number Version index (1-based)
--- @param vCount number Total version count
--- @param lines table Output line accumulator
local function FormatVersionBlock(ver, vIdx, vCount, lines)
    local label = "Version " .. vIdx
    if vCount == 1 then
        label = label .. " (Default)"
    end
    lines[#lines + 1] = label .. ":"

    -- Step function
    local sf = ver.stepFunction or D.STEP_SEQUENTIAL
    lines[#lines + 1] = "  Step Function: " .. sf

    -- Reset conditions
    local resetStr = D.BuildResetString(ver)
    if resetStr ~= "" then
        lines[#lines + 1] = "  Reset: " .. resetStr
    end

    -- Steps
    lines[#lines + 1] = "  Steps:"
    if ver.steps and #ver.steps > 0 then
        for idx, step in ipairs(ver.steps) do
            if type(step) == "string" then
                lines[#lines + 1] = "    " .. idx .. ") " .. step
            end
        end
    else
        lines[#lines + 1] = "    (none)"
    end

    -- KeyPress (inline, skip if empty)
    if ver.keyPress and ver.keyPress ~= "" then
        lines[#lines + 1] = "  KeyPress: " .. ver.keyPress
    end

    -- KeyRelease (inline, skip if empty)
    if ver.keyRelease and ver.keyRelease ~= "" then
        lines[#lines + 1] = "  KeyRelease: " .. ver.keyRelease
    end
end

--- Export selected sequences and variables as a human-readable text block.
--- Walks all versions per sequence. Suitable for forum/Discord sharing.
--- @param seqNames table Array of sequence names
--- @param varNames table Array of variable names
--- @return string Plain-text summary
function GE.ExportAsText(seqNames, varNames)
    local Engine = GRIPEMS.Engine
    local VS = GRIPEMS.VariableStore
    local lines = {}

    for si, seqName in ipairs(seqNames) do
        local entry = Engine.sequences[seqName]
        if entry and entry.data then
            local seqData = entry.data
            local versions = seqData.versions
            local vCount = versions and #versions or 0

            -- Header metadata
            lines[#lines + 1] = "Sequence: " .. seqName
            lines[#lines + 1] = "Author: " .. (seqData.author or "(unknown)")
            lines[#lines + 1] = "Spec: " .. ResolveSpecName(seqData.specID)

            -- Top-level step function (from first version as representative)
            local topSF = D.STEP_SEQUENTIAL
            if versions and versions[1] then
                topSF = versions[1].stepFunction or D.STEP_SEQUENTIAL
            end
            lines[#lines + 1] = "Step Function: " .. topSF

            -- Icon
            lines[#lines + 1] = "Icon: " .. ResolveIconName(seqData.icon)
            lines[#lines + 1] = "Versions: " .. vCount
            lines[#lines + 1] = ""

            -- Each version
            if versions then
                for vi, ver in ipairs(versions) do
                    FormatVersionBlock(ver, vi, vCount, lines)
                    if vi < vCount then
                        lines[#lines + 1] = ""
                    end
                end
            end

            -- Divider between sequences
            if si < #seqNames then
                lines[#lines + 1] = ""
                lines[#lines + 1] = "---"
                lines[#lines + 1] = ""
            end
        end
    end

    -- Variables section
    if varNames and #varNames > 0 and VS then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "Variables:"
        for _, varName in ipairs(varNames) do
            local varDef = VS:Get(varName)
            if varDef then
                local body = varDef.funct or ""
                if #body > 80 then
                    body = body:sub(1, 80) .. "..."
                end
                local eventStr = ""
                if varDef.events and varDef.events ~= "" then
                    eventStr = " (Event: " .. varDef.events .. ")"
                end
                lines[#lines + 1] = "  - " .. varName .. ": " .. body .. eventStr
            end
        end
    end

    return table.concat(lines, "\n")
end
