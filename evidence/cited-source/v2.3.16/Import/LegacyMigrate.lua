-- GRIP-EMS: LegacyMigrate
-- Created: 2026-04-03
-- Updated: 2026-07-26
-- Patch: 12.0.7.68256 Midnight (Retail LIVE)

-- GRIP-EMS: In-Game Migration
-- Detects source sequencer state and bulk-migrates sequences

local ADDON_NAME, GRIPEMS = ...
local L = LibStub("AceLocale-3.0"):GetLocale("GRIP-EMS", true)
local LI = GRIPEMS.LegacyImport
local S = GRIPEMS.Serialization
local KM = GRIPEMS.KeybindManager

GRIPEMS.LegacyMigrate = {}
local LM = GRIPEMS.LegacyMigrate

---------------------------------------------------------------------------
-- Detection API
---------------------------------------------------------------------------

--- Check if the source sequencer addon is loaded and running.
--- @return boolean
function LM.IsSourceActive()
    return C_AddOns.IsAddOnLoaded("GSE")
end

--- Check if the source sequencer addon is installed (may be disabled).
--- @return boolean
function LM.IsSourceInstalled()
    local name = C_AddOns.GetAddOnInfo("GSE")
    return name ~= nil
end

--- Get the current source sequencer status.
--- @return string "active", "disabled", or "none"
function LM.GetSourceStatus()
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
function LM.GetSourceSequenceCount()
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
--- @param currentClassOnly boolean If true, migrate only the player's class plus
---        class-neutral (classID 0) sequences; skip sequences stamped to other classes
--- @return boolean success
--- @return table|string results Results table on success, error string on failure
function LM.MigrateAll(overwrite, currentClassOnly)
    -- Guard: combat/restriction lockdown
    if GRIPEMS.OOCQueue.IsRestricted() then
        return false, L["GEMS_MIGRATE_COMBAT"]
    end

    -- Guard: source sequencer must be active
    if not LM.IsSourceActive() then
        return false, L["GEMS_MIGRATE_SOURCE_DISABLED"]
    end

    -- Source access: newer source builds keep the runtime table private
    -- (file-local addon table, no global). Bind the runtime library when
    -- the global exists; otherwise migrate straight from SavedVariables,
    -- which the source keeps in sync on every storage write.
    local lib = _G.GSE and _G.GSE.Library or nil
    if not lib and not _G.GSESequences then
        return false, L["GEMS_MIGRATE_EMPTY"]
    end

    -- Force-decompress all classes (runtime library path only)
    if lib and _G.GSE.EnsureClassLoaded then
        for classID = 0, 13 do
            pcall(_G.GSE.EnsureClassLoaded, classID)
        end
    end

    local results = {
        names = {},
        warnings = {},
        count = 0,
        skipped = 0,
        encryptedSkipped = 0,
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
    local playerClassID = select(3, UnitClass("player")) or 0
    local seqStore = _G.GRIP_EMS_CHAR and GRIP_EMS_CHAR.sequences or {}

    -- Snapshot names that existed BEFORE this migration run.
    -- Collisions against pre-existing names = skip (already migrated).
    -- Collisions within this batch (cross-class) = suffix with class name.
    local preExisting = {}
    for existingName in pairs(seqStore) do
        preExisting[existingName] = true
    end

    -- Walk source library [classID][seqName] (skipped when runtime table is private)
    for classID = 0, 13 do
        if lib and lib[classID] and not (currentClassOnly and classID ~= 0 and classID ~= playerClassID) then
            for seqName, seqObj in pairs(lib[classID]) do
                if type(seqObj) == "table" then
                    -- Disabled state is read in ProcessSequence (no longer skipped)
                    do
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
                                local suffixed = tostring(seqName) .. " (" .. className .. ")"
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
                                dormant = (classID ~= 0 and classID ~= playerClassID),
                            }

                            local ok, err = LI.ProcessSequence(targetName, seqObj, results, opts)
                            if not ok then
                                results.warnings[#results.warnings + 1] = seqName .. ": " .. tostring(err)
                            elseif opts.dormant then
                                results.dormantCount = (results.dormantCount or 0) + 1
                            end
                        end
                    end
                end
            end
        end
    end

    -- Fallback: if source library walk found nothing, read SavedVariables directly
    if results.count == 0 and results.skipped == 0 and _G.GSESequences then
        GRIPEMS:Debug("Source library empty or private, falling back to SavedVariables direct decode")
        for classID = 0, 13 do
            if GSESequences[classID] and not (currentClassOnly and classID ~= 0 and classID ~= playerClassID) then
                for seqName, rawData in pairs(GSESequences[classID]) do
                    local seqObj = nil
                    if type(rawData) == "string" then
                        local decOk, decoded, decFmt = S.Decode(rawData)
                        if decOk and type(decoded) == "table" then
                            -- Source SavedVariable stores {name, seqObj} arrays
                            if type(decoded[1]) == "string" and type(decoded[2]) == "table" then
                                seqObj = decoded[2]
                            else
                                seqObj = decoded
                            end
                        else
                            if decFmt == "GSE3_ENCRYPTED" then
                                results.encryptedSkipped = results.encryptedSkipped + 1
                            end
                            GRIPEMS:Debug("  Decode failed for " .. tostring(seqName))
                        end
                        GRIPEMS:Debug("  Decoded " .. tostring(seqName) .. " (type: " .. type(seqObj) .. ")")
                    elseif type(rawData) == "table" then
                        seqObj = rawData
                    end
                    if seqObj and type(seqObj) == "table" then
                        -- Disabled state is read in ProcessSequence (no longer skipped)
                        do
                            local targetName = seqName
                            if seqStore[targetName] and not overwrite then
                                if preExisting[targetName] then
                                    results.skipped = results.skipped + 1
                                    targetName = nil
                                else
                                    local className = GetClassInfo(classID) or ("Class" .. classID)
                                    local suffixed = tostring(seqName) .. " (" .. className .. ")"
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
                                    author = seqObj.MetaData and seqObj.MetaData.Author,
                                    description = seqObj.MetaData and seqObj.MetaData.Help,
                                    specID = seqObj.MetaData and seqObj.MetaData.SpecID,
                                    updatedAt = seqObj.MetaData and seqObj.MetaData.LastUpdated,
                                    icon = seqObj.Icon,
                                    classID = classID,
                                    dormant = (classID ~= 0 and classID ~= playerClassID),
                                }
                                local ok, err = LI.ProcessSequence(targetName, seqObj, results, opts)
                                if not ok then
                                    results.warnings[#results.warnings + 1] = seqName .. ": " .. tostring(err)
                                elseif opts.dormant then
                                    results.dormantCount = (results.dormantCount or 0) + 1
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
                local varOk, varDecoded, varFmt = S.Decode(varData)
                if varOk and type(varDecoded) == "table" then
                    local gripVar = LI.MapLegacyVariable(varName, varDecoded)
                    LI.ImportVariable(varName, gripVar, results)
                elseif varFmt == "GSE3_ENCRYPTED" then
                    results.encryptedSkipped = results.encryptedSkipped + 1
                end
            elseif type(varData) == "table" then
                local gripVar = LI.MapLegacyVariable(varName, varData)
                LI.ImportVariable(varName, gripVar, results)
            end
        end
    end

    -- Auxiliary-macro migration (audit Layer 3): walk _G.GSEMacros so that
    -- bare-name macro references inside migrated sequences resolve at fire
    -- time instead of typing the macro name into chat. The two-level layout
    -- mirrors the source storage:
    --   GSEMacros[<name>]                     = account-level node
    --   GSEMacros["Char-Realm"][<name>]       = per-character bucket
    -- Account-level entries are detected by the presence of node.text or
    -- node.manageMacro on the top-level table; the per-character bucket is
    -- a sub-table keyed by "Char-Realm" matching the active player.
    if _G.GSEMacros and type(GSEMacros) == "table" then
        for macName, macData in pairs(GSEMacros) do
            if type(macData) == "table" then
                if macData.GSEProtected then
                    -- Encrypted protected/subscriber-only macro; EMS cannot read it.
                    results.encryptedSkipped = results.encryptedSkipped + 1
                elseif macData.text or macData.manageMacro then
                    LI.ImportMacro(macName, macData, results, "a")
                else
                    local char, realm = UnitFullName("player")
                    if char and realm and macName == (char .. "-" .. realm) then
                        for innerName, innerNode in pairs(macData) do
                            if type(innerNode) == "table" then
                                if innerNode.GSEProtected then
                                    results.encryptedSkipped = results.encryptedSkipped + 1
                                else
                                    LI.ImportMacro(innerName, innerNode, results, "p")
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    if results.count == 0 and results.skipped == 0 and results.encryptedSkipped == 0 then
        return false, L["GEMS_MIGRATE_EMPTY"]
    end

    -- Keybind migration (override bindings only)
    local kbResults = LM.MigrateKeybinds(overwrite)
    results.keybindsMigrated = kbResults.migrated
    results.keybindsSkipped = kbResults.skipped
    results.keybindConflicts = kbResults.conflicts
    results.aoWarning = kbResults.aoWarning

    -- Notify listeners
    if results.count > 0 and GRIPEMS.Fire then
        GRIPEMS:Fire("SEQUENCE_IMPORTED", results)
    end

    return true, results
end

---------------------------------------------------------------------------
-- Keybind migration (override bindings from source SavedVariables)
---------------------------------------------------------------------------

--- Migrate override keybinds from source sequencer SavedVariables.
--- Reads GSE_C["KeyBindings"][specIndex][key] = seqName and calls
--- KM:SetKeybind for each entry whose sequence exists in EMS.
--- Action bar overrides (GSE_C["ActionBarBinds"]) are counted but not
--- migrated because EMS uses SetOverrideBindingClick, not bar overrides.
--- @param overwrite boolean If true, overwrite existing keybinds
--- @return table Results with migrated, skipped, conflicts, aoWarning
function LM.MigrateKeybinds(overwrite)
    local kbResults = { migrated = 0, skipped = 0, conflicts = 0, aoWarning = nil }

    -- Guard: source character config must exist with keybind data
    local sourceConfig = _G.GSE_C
    if not sourceConfig or type(sourceConfig) ~= "table" then
        return kbResults
    end

    local sourceBinds = sourceConfig["KeyBindings"]
    if not sourceBinds or type(sourceBinds) ~= "table" then
        return kbResults
    end

    local seqStore = GRIPEMS.Engine and GRIPEMS.Engine.sequences or {}

    -- Ensure GRIP_EMS_CHAR keybind tables exist
    if not _G.GRIP_EMS_CHAR then
        return kbResults
    end
    GRIP_EMS_CHAR.keybinds = GRIP_EMS_CHAR.keybinds or {}

    for specIndex, specTable in pairs(sourceBinds) do
        if type(specTable) == "table" and type(specIndex) == "number" then
            GRIP_EMS_CHAR.keybinds[specIndex] = GRIP_EMS_CHAR.keybinds[specIndex] or {}
            local destBinds = GRIP_EMS_CHAR.keybinds[specIndex]

            for key, seqName in pairs(specTable) do
                -- Skip LoadOuts sub-table (per-talent-loadout binds, not supported)
                if key ~= "LoadOuts" and type(key) == "string" and type(seqName) == "string" then
                    if not seqStore[seqName] then
                        -- Sequence not found in EMS
                        kbResults.skipped = kbResults.skipped + 1
                    elseif destBinds[key] and not overwrite then
                        -- Key already bound in this spec
                        kbResults.conflicts = kbResults.conflicts + 1
                    else
                        destBinds[key] = seqName
                        kbResults.migrated = kbResults.migrated + 1
                    end
                end
            end
        end
    end

    -- Count action bar overrides (not migrated)
    local aoBinds = sourceConfig and sourceConfig["ActionBarBinds"]
    if aoBinds and type(aoBinds) == "table" then
        local specs = aoBinds["Specialisations"] or aoBinds["Specializations"]
        if specs and type(specs) == "table" then
            local aoCount = 0
            for _, specTable in pairs(specs) do
                if type(specTable) == "table" then
                    for _ in pairs(specTable) do
                        aoCount = aoCount + 1
                    end
                end
            end
            if aoCount > 0 then
                kbResults.aoWarning = string.format(L["GEMS_MIGRATE_AO_WARNING"], aoCount)
            end
        end
    end

    -- Reload live bindings if any were migrated
    if kbResults.migrated > 0 then
        KM:LoadKeybinds()
    end

    return kbResults
end
