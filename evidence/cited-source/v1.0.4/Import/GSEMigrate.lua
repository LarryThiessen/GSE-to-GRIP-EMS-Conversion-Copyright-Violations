-- GRIP-EMS: In-Game Migration
-- Detects source sequencer state and bulk-migrates sequences

local ADDON_NAME, GRIPEMS = ...
local L = LibStub("AceLocale-3.0"):GetLocale("GRIP-EMS")
local GI = GRIPEMS.GSEImport
local S = GRIPEMS.Serialization

GRIPEMS.GSEMigrate = {}
local GM = GRIPEMS.GSEMigrate

---------------------------------------------------------------------------
-- Detection API
---------------------------------------------------------------------------

--- Check if the source sequencer addon is loaded and running.
--- @return boolean
function GM.IsGSEActive()
    return C_AddOns.IsAddOnLoaded("GSE")
end

--- Check if the source sequencer addon is installed (may be disabled).
--- @return boolean
function GM.IsGSEInstalled()
    local name = C_AddOns.GetAddOnInfo("GSE")
    return name ~= nil
end

--- Get the current source sequencer status.
--- @return string "active", "disabled", or "none"
function GM.GetGSEStatus()
    if C_AddOns.IsAddOnLoaded("GSE") then
        return "active"
    end
    local name = C_AddOns.GetAddOnInfo("GSE")
    if name ~= nil then
        return "disabled"
    end
    return "none"
end

---------------------------------------------------------------------------
-- Quick count (no decompression)
---------------------------------------------------------------------------

--- Count sequences in the source compressed storage without decompressing.
--- Uses the source SavedVariable global for a quick count.
--- @return number Total sequence count across all classes
function GM.GetGSESequenceCount()
    if not _G.GSESequences then
        return 0
    end
    local count = 0
    for classID = 0, 13 do
        if GSESequences[classID] then
            for _ in pairs(GSESequences[classID]) do
                count = count + 1
            end
        end
    end
    return count
end

---------------------------------------------------------------------------
-- Bulk migration
---------------------------------------------------------------------------

--- Migrate all sequences from the source library into GRIP-EMS.
--- Decompresses all classes, walks the library, calls ProcessSequence.
--- @param overwrite boolean If true, overwrite existing sequences with same name
--- @return boolean success
--- @return table|string results Results table on success, error string on failure
function GM.MigrateAll(overwrite)
    -- Guard: combat lockdown
    if InCombatLockdown() then
        return false, L["GEMS_MIGRATE_COMBAT"]
    end

    -- Guard: source sequencer must be active
    if not GM.IsGSEActive() then
        return false, L["GEMS_MIGRATE_GSE_DISABLED"]
    end

    -- Guard: source library must exist
    if not _G.GSE or not GSE.Library then
        return false, "GSE.Library not available"
    end

    -- Force-decompress all classes
    if GSE.EnsureClassLoaded then
        for classID = 0, 13 do
            pcall(GSE.EnsureClassLoaded, classID)
        end
    end

    local results = { names = {}, warnings = {}, count = 0, skipped = 0, stepCounts = {},
        varsImported = 0, varsSkipped = 0, contextOverridesImported = 0,
        versionsDropped = 0, pausesSkipped = 0, embedsSkipped = 0,
        truncatedSteps = 0, stepFunctions = {} }
    local seqStore = _G.GRIP_EMS_CHAR and GRIP_EMS_CHAR.sequences or {}

    -- Snapshot names that existed BEFORE this migration run.
    -- Collisions against pre-existing names = skip (already migrated).
    -- Collisions within this batch (cross-class) = suffix with class name.
    local preExisting = {}
    for existingName in pairs(seqStore) do
        preExisting[existingName] = true
    end

    -- Walk source library [classID][seqName]
    for classID = 0, 13 do
        if GSE.Library[classID] then
            for seqName, seqObj in pairs(GSE.Library[classID]) do
                if type(seqObj) == "table" then
                    -- Skip disabled sequences
                    if not (seqObj.MetaData and seqObj.MetaData.Disabled) then
                        -- Determine target name (handle duplicates)
                        local targetName = seqName
                        if seqStore[targetName] and not overwrite then
                            if preExisting[targetName] then
                                -- Name existed before this run (previous migration), skip
                                results.skipped = results.skipped + 1
                                targetName = nil
                            else
                                -- Cross-class collision within this batch, try suffix
                                local className = GetClassInfo(classID) or ("Class" .. classID)
                                local suffixed = seqName .. " (" .. className .. ")"
                                if seqStore[suffixed] and not overwrite then
                                    results.skipped = results.skipped + 1
                                    results.warnings[#results.warnings + 1] =
                                        string.format(L["GEMS_MIGRATE_SKIPPED"], seqName)
                                    targetName = nil
                                else
                                    targetName = suffixed
                                end
                            end
                        end

                        if targetName then
                            -- Build opts for enhanced ProcessSequence
                            local opts = {
                                author = seqObj.MetaData and seqObj.MetaData.Author,
                                description = seqObj.MetaData and seqObj.MetaData.Help,
                                specID = seqObj.MetaData and seqObj.MetaData.SpecID,
                                updatedAt = seqObj.MetaData and seqObj.MetaData.LastUpdated,
                                icon = seqObj.Icon,
                                classID = classID,
                            }

                            local ok, err = GI.ProcessSequence(targetName, seqObj, results, opts)
                            if not ok then
                                results.warnings[#results.warnings + 1] =
                                    seqName .. ": " .. tostring(err)
                            end
                        end
                    end
                end
            end
        end
    end

    -- Fallback: if source library walk found nothing, read SavedVariables directly
    if results.count == 0 and results.skipped == 0 and _G.GSESequences then
        GRIPEMS:Debug("Source library empty, falling back to SavedVariables direct decode")
        for classID = 0, 13 do
            if GSESequences[classID] then
                for seqName, rawData in pairs(GSESequences[classID]) do
                    local seqObj = nil
                    if type(rawData) == "string" then
                        local decOk, decoded = S.Decode(rawData)
                        if decOk and type(decoded) == "table" then
                            -- Source SavedVariable stores {name, seqObj} arrays
                            if type(decoded[1]) == "string"
                                    and type(decoded[2]) == "table" then
                                seqObj = decoded[2]
                            else
                                seqObj = decoded
                            end
                        else
                            GRIPEMS:Debug("  Decode failed for " .. seqName)
                        end
                        GRIPEMS:Debug("  Decoded " .. seqName .. " (type: "
                            .. type(seqObj) .. ")")
                    elseif type(rawData) == "table" then
                        seqObj = rawData
                    end
                    if seqObj and type(seqObj) == "table" then
                        -- Skip disabled sequences
                        if not (seqObj.MetaData and seqObj.MetaData.Disabled) then
                            local targetName = seqName
                            if seqStore[targetName] and not overwrite then
                                if preExisting[targetName] then
                                    results.skipped = results.skipped + 1
                                    targetName = nil
                                else
                                    local className = GetClassInfo(classID)
                                        or ("Class" .. classID)
                                    local suffixed = seqName
                                        .. " (" .. className .. ")"
                                    if seqStore[suffixed] and not overwrite then
                                        results.skipped = results.skipped + 1
                                        targetName = nil
                                    else
                                        targetName = suffixed
                                    end
                                end
                            end
                            if targetName then
                                local opts = {
                                    author = seqObj.MetaData
                                        and seqObj.MetaData.Author,
                                    description = seqObj.MetaData
                                        and seqObj.MetaData.Help,
                                    specID = seqObj.MetaData
                                        and seqObj.MetaData.SpecID,
                                    updatedAt = seqObj.MetaData
                                        and seqObj.MetaData.LastUpdated,
                                    icon = seqObj.Icon,
                                    classID = classID,
                                }
                                local ok, err = GI.ProcessSequence(
                                    targetName, seqObj, results, opts)
                                if not ok then
                                    results.warnings[#results.warnings + 1] =
                                        seqName .. ": " .. tostring(err)
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- Variable migration
    if _G.GSEVariables and type(GSEVariables) == "table" then
        for varName, varData in pairs(GSEVariables) do
            if type(varData) == "string" then
                local varOk, varDecoded = S.Decode(varData)
                if varOk and type(varDecoded) == "table" then
                    local gripVar = GI.MapGSEVariable(varName, varDecoded)
                    GI.ImportVariable(varName, gripVar, results)
                end
            elseif type(varData) == "table" then
                local gripVar = GI.MapGSEVariable(varName, varData)
                GI.ImportVariable(varName, gripVar, results)
            end
        end
    end

    if results.count == 0 and results.skipped == 0 then
        return false, L["GEMS_MIGRATE_EMPTY"]
    end

    -- Notify listeners
    if results.count > 0 and GRIPEMS.Fire then
        GRIPEMS:Fire("SEQUENCE_IMPORTED", results)
    end

    return true, results
end
