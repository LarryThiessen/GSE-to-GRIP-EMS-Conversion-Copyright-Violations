-- GRIP-EMS: GRIP Export
-- Native GRIP-EMS export and import for sharing sequences between users

local ADDON_NAME, GRIPEMS = ...
local L = LibStub("AceLocale-3.0"):GetLocale("GRIP-EMS")
local D = GRIPEMS.Defaults
local S = GRIPEMS.Serialization

GRIPEMS.GRIPExport = {}
local GE = GRIPEMS.GRIPExport
local SC = GRIPEMS.SpellCache

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
        return false, string.format(L["No sequence named '%s' found."], sequenceName)
    end

    local seqData = entry.data

    -- Deep-copy versions and translate spell names to ID tags for export.
    -- Never mutate live Engine data.
    local exportVersions = {}
    if seqData.versions and type(seqData.versions) == "table" then
        for vi, ver in ipairs(seqData.versions) do
            local verCopy = {}
            for k, v in pairs(ver) do
                verCopy[k] = v
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

    -- Build GRIP1 payload (v3: locale-safe with spell ID tags)
    local payload = {
        format = "GRIP-EMS",
        version = D.GRIP_FORMAT_VERSION,
        locale = GetLocale(),
        name = sequenceName,
        sequence = {
            icon = seqData.icon or D.QUESTION_MARK_ICON,
            versions = exportVersions,
            defaultVersion = seqData.defaultVersion or 1,
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

    -- v3+: translate spell ID tags back to localized names
    if decoded.version >= 3 and decoded.sequence then
        local seq = decoded.sequence
        if seq.versions and type(seq.versions) == "table" then
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
    end

    local seq = decoded.sequence

    -- Build sequenceData from payload
    local seqData = {
        name = decoded.name,
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
