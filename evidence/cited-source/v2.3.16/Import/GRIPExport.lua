-- GRIP-EMS: GRIPExport
-- Created: 2026-03-18
-- Updated: 2026-07-30
-- Patch: 12.0.7.68453 Midnight (Retail LIVE)

-- GRIP-EMS: GRIP Export
-- Native GRIP-EMS export and import for sharing sequences between users

local ADDON_NAME, GRIPEMS = ...
local L = LibStub("AceLocale-3.0"):GetLocale("GRIP-EMS", true)
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
            -- Deep-copy actions tree for export (v4: S14-C).
            -- Truthiness stays here on purpose. Measured against a number, a
            -- boolean and a string ver.actions: D.DeepCopyActions accepts all
            -- three and returns an empty table, so nothing raises and the second
            -- reader below (SC:TagActionsToIDs) is handed a table either way.
            -- ABSENT still leaves verCopy.actions nil. A type() guard here would
            -- change no observable and pin no failure.
            if ver.actions then
                verCopy.actions = D.DeepCopyActions(ver.actions)
                -- Locale: tag the action tree's macros to spell-ID tokens so the
                -- transport is locale-independent (mirrors the toIDs step tagging
                -- below). The importer re-renders to its own client locale.
                if SC.TagActionsToIDs then
                    SC:TagActionsToIDs(verCopy.actions, { classID = seqData.classID })
                end
            end
            -- Translate steps. Reuse the stored canonical ID-tagged form
            -- (ver.taggedSteps, kept in sync by SC:NormalizeVersionLocale) when
            -- present so the transport is independent of the exporter's client
            -- locale; fall back to a fresh toIDs resolution only when absent.
            -- type(), not truthiness: the walk below is an ipairs, which raises
            -- on a number, a boolean AND a string. A string clears a length
            -- operator elsewhere in this family but never clears an ipairs, so
            -- the harsher operator needs the stricter guard. ABSENT is unchanged
            -- and deliberately so -- verCopy.steps must stay nil for an absent
            -- steps, which is what GE.BuildInsights relies on downstream.
            if type(ver.steps) == "table" then
                local translatedSteps = {}
                for si, step in ipairs(ver.steps) do
                    if type(step) == "string" then
                        local tagged = ver.taggedSteps and ver.taggedSteps[si]
                        translatedSteps[si] = tagged
                            or SC:TranslateMacrotext(step, "toIDs", { classID = seqData.classID })
                    else
                        translatedSteps[si] = step
                    end
                end
                verCopy.steps = translatedSteps
            else
                -- Not dead code, and the guard above is not sufficient on its
                -- own: the pairs() copy at the top of this loop already put
                -- ver.steps into verCopy VERBATIM, so without this a scalar
                -- clears the ipairs here and then reaches the downstream
                -- readers that legitimately use truthiness -- :276 / :279 / :329
                -- in BuildInsights, :442 in BuildDependenciesField, and :670 in
                -- GE.Export's variable bundle. Dropping it here is
                -- what makes "nil-or-table by construction" true for all of
                -- them. ABSENT is unchanged: it was nil and stays nil.
                --
                -- AN ACTIONS-ONLY VERSION IS A SUPPORTED SHAPE, NOT A DEFECT.
                -- A version that carries actions and OMITS steps is a
                -- legitimate payload, measured across two passes and
                -- re-confirmed. Three shipped sites already render it:
                -- L["GEMS_EXPORTTEXT_STEPS_NONE"] (the literal "    (none)")
                -- is what the text emitter prints, GE.PrepareExportVersions
                -- omits the key entirely, and GE.BuildExportList yields
                -- stepCount = 0. A later pass must NOT "repair" the absent key
                -- into an empty table: {} and an absent key are different on
                -- the wire and the importer distinguishes them.
                verCopy.steps = nil
            end
            -- Preserve per-step labels aligned to translated steps (flat mode, Phase 1C-bis)
            -- The type() test is on stepLabels because truthiness is not a
            -- shape test: a stored stepLabels of 7 is truthy, enters this
            -- block, and raises at the index two lines down.
            if type(ver.stepLabels) == "table" and verCopy.steps then
                local labelsCopy = {}
                for j = 1, #verCopy.steps do
                    labelsCopy[j] = ver.stepLabels[j]
                end
                verCopy.stepLabels = labelsCopy
            else
                verCopy.stepLabels = nil
            end
            -- Runtime-only compiled label array never ships (Phase 1C-bis-outline)
            verCopy.compiledLabels = nil
            -- Translate keyPress / keyRelease. Reuse the stored canonical
            -- ID-tagged form when present (locale-independent); fall back to a
            -- fresh toIDs resolution only when absent.
            if ver.keyPress and type(ver.keyPress) == "string" then
                verCopy.keyPress = ver.taggedKeyPress
                    or SC:TranslateMacrotext(ver.keyPress, "toIDs", { classID = seqData.classID })
            end
            if ver.keyRelease and type(ver.keyRelease) == "string" then
                verCopy.keyRelease = ver.taggedKeyRelease
                    or SC:TranslateMacrotext(ver.keyRelease, "toIDs", { classID = seqData.classID })
            end
            exportVersions[vi] = verCopy
        end
    end
    return exportVersions
end

-- Resolve build-context + class/spec/talent metadata for export. Every WoW
-- global is existence-guarded so the headless harness (no WoW env) returns a
-- mostly-empty table instead of erroring. Live talent/hero capture is gated on
-- the player's current spec matching the sequence's specID, so exporting a
-- sequence off-spec never attaches a wrong talent build. An author-set
-- seqData.talentString / seqData.url always wins over live capture.
function GE.ResolveExportContext(seqData)
    local bc = {}
    if GetBuildInfo then
        local v, b, _, iface = GetBuildInfo()
        bc.wowPatch = v
        bc.wowBuild = b
        bc.wowInterface = iface
    end
    if UnitLevel then
        bc.playerLevel = UnitLevel("player")
    end
    if seqData.classID and GetClassInfo then
        local cName, cFile = GetClassInfo(seqData.classID)
        bc.className = cName
        bc.classFile = cFile
    end
    if seqData.specID and GetSpecializationInfoByID then
        local _, sName, _, _, sRole, sClassFile, sClassName = GetSpecializationInfoByID(seqData.specID)
        bc.specName = sName
        bc.role = sRole
        bc.classFile = bc.classFile or sClassFile
        bc.className = bc.className or sClassName
    end
    if type(seqData.contextOverrides) == "table" then
        local keys = {}
        for k in pairs(seqData.contextOverrides) do
            keys[#keys + 1] = k
        end
        table.sort(keys)
        if #keys > 0 then
            bc.contentTypes = keys
        end
    end
    if type(seqData.versions) == "table" then
        bc.versionCount = #seqData.versions
    end
    if seqData.talentString and seqData.talentString ~= "" then
        bc.talentString = seqData.talentString
    end
    if seqData.url and seqData.url ~= "" then
        bc.url = seqData.url
    end
    local curSpecID
    if C_SpecializationInfo and C_SpecializationInfo.GetSpecialization then
        local idx = C_SpecializationInfo.GetSpecialization()
        if idx and GetSpecializationInfo then
            curSpecID = GetSpecializationInfo(idx)
        end
    end
    if
        curSpecID
        and seqData.specID
        and curSpecID == seqData.specID
        and C_ClassTalents
        and C_ClassTalents.GetActiveConfigID
    then
        local cfg = C_ClassTalents.GetActiveConfigID()
        if cfg then
            if C_Traits and C_Traits.GenerateImportString then
                local ok, s = pcall(C_Traits.GenerateImportString, cfg)
                if ok and type(s) == "string" and s ~= "" then
                    bc.talentBuild = s
                end
            end
            if C_ClassTalents.GetActiveHeroTalentSpec then
                local hid = C_ClassTalents.GetActiveHeroTalentSpec()
                if hid then
                    bc.heroSpecID = hid
                    if C_Traits and C_Traits.GetSubTreeInfo then
                        local ok, info = pcall(C_Traits.GetSubTreeInfo, cfg, hid)
                        if ok and type(info) == "table" and info.name then
                            bc.heroSpecName = info.name
                        end
                    end
                end
            end
        end
    end
    return bc
end

--- Resolve the privacy-aware exporter identity block for export envelopes.
--- Mode resolution when nil/empty mirrors Identity:BuildExportPayload:
--- config.privacyDefault, then D.PRIVACY_MODE_DEFAULT, then "public".
--- Nil-guards GRIPEMS.Identity and GRIP_EMS_DB so the headless harness
--- (no WoW env) gets nil back instead of an error.
--- @param mode string|nil Privacy mode ("public" / "pseudonymous" / "private")
--- @return table|nil exportedBy { name, realm?, identity, mode }; nil when private or headless
function GE.BuildExportedBy(mode)
    if not mode or mode == "" then
        mode = (GRIP_EMS_DB and GRIP_EMS_DB.config and GRIP_EMS_DB.config.privacyDefault)
            or D.PRIVACY_MODE_DEFAULT
            or "public"
    end
    if mode == D.PRIVACY_MODE_PRIVATE then
        return nil
    end
    local Identity = GRIPEMS.Identity
    if not Identity or not Identity.GetCurrent then
        return nil
    end
    local me = Identity:GetCurrent()
    if not me or not me.identityHash then
        return nil
    end
    if mode == D.PRIVACY_MODE_PSEUDONYMOUS then
        local pseudonym = (GRIP_EMS_DB and GRIP_EMS_DB.config and GRIP_EMS_DB.config.pseudonym)
            or D.PRIVACY_PSEUDONYM_DEFAULT
            or "Anonymous"
        return { name = pseudonym, identity = me.identityHash, mode = D.PRIVACY_MODE_PSEUDONYMOUS }
    end
    return {
        name = me.displayName,
        realm = me.realm,
        identity = me.identityHash,
        mode = D.PRIVACY_MODE_PUBLIC,
    }
end

--- Compute export-time sequence insights from the ID-tagged export copies.
--- Scans the transport form (exportVersions), never the stored seqData, so
--- spell references come from the locale-independent {spell:N} tags. tempo
--- and health are live-client extras (spec-gated advisor + analyzer) that
--- nil-guard away headless. Receivers recompute this block locally; it is
--- never persisted on import.
--- @param sequenceName string Sequence name (advisor lookup key)
--- @param seqData table Privacy-scrubbed sequence data
--- @param exportVersions table ID-tagged versions from PrepareExportVersions
--- @return table insights
function GE.BuildInsights(sequenceName, seqData, exportVersions)
    local insights = {}
    local defVer = exportVersions[seqData.defaultVersion or 1]
    -- Truthiness is sufficient HERE and the type() guard used elsewhere in this
    -- family would pin nothing. exportVersions comes only from
    -- GE.PrepareExportVersions, whose steps branch is a type() guard (:61): a
    -- table steps is replaced by a freshly built translated table at :72, and
    -- anything else -- absent OR scalar -- is nilled at :94. So
    -- exportVersions[n].steps is nil-or-table BY CONSTRUCTION and the length
    -- operator below cannot see a scalar. The same argument covers every other
    -- truthiness read of exportVersions[n].steps: :329 in this function's spell
    -- scan, :442 in BuildDependenciesField, and :670 in GE.Export's variable
    -- bundle. All of them depend on the :94 branch, not just on the :61 guard
    -- -- :442 is where a scalar surfaced when :94 was missing. Measured, not
    -- assumed: do not re-flag these lines in a later sweep, and do not delete
    -- :94 as dead.
    insights.stepCount = (defVer and defVer.steps and #defVer.steps) or 0
    local stepCounts = {}
    for vi, ver in ipairs(exportVersions) do
        stepCounts[vi] = (ver.steps and #ver.steps) or 0
    end
    insights.stepCounts = stepCounts

    local spellCounts = {}
    local modSet = {}
    local function addModTokens(tokens)
        for token in tokens:gmatch("[^,]+") do
            token = token:match("^%s*(.-)%s*$")
            if token and token ~= "" then
                modSet[token:lower()] = true
            end
        end
    end
    local function scanText(text)
        if type(text) ~= "string" then
            return
        end
        for id in text:gmatch("{spell:(%d+)}") do
            local n = tonumber(id)
            spellCounts[n] = (spellCounts[n] or 0) + 1
        end
        for tokens in text:gmatch("%f[%a]mod:([%a,]+)") do
            addModTokens(tokens)
        end
        for tokens in text:gmatch("%f[%a]modifier:([%a,]+)") do
            addModTokens(tokens)
        end
    end
    local function scanActions(nodes)
        if type(nodes) ~= "table" then
            return
        end
        for _, node in ipairs(nodes) do
            if type(node) == "table" then
                scanText(node.macro)
                if type(node.children) == "table" then
                    if node.type == D.ACTION_TYPE_IF then
                        -- IF children hold two branch node arrays (true / false)
                        scanActions(node.children[1])
                        scanActions(node.children[2])
                    else
                        scanActions(node.children)
                    end
                end
            end
        end
    end
    for _, ver in ipairs(exportVersions) do
        if ver.steps then
            for _, step in ipairs(ver.steps) do
                if type(step) == "string" then
                    scanText(step)
                end
            end
        end
        scanText(ver.keyPress)
        scanText(ver.keyRelease)
        scanActions(ver.actions)
    end

    local spellsUsed = {}
    for id, count in pairs(spellCounts) do
        spellsUsed[#spellsUsed + 1] = { id = id, count = count }
    end
    table.sort(spellsUsed, function(a, b)
        return a.id < b.id
    end)
    insights.spellsUsed = spellsUsed

    local modifiersUsed = {}
    for token in pairs(modSet) do
        modifiersUsed[#modifiersUsed + 1] = token
    end
    table.sort(modifiersUsed)
    insights.modifiersUsed = modifiersUsed

    -- Tempo recommendation: only when the player's current spec matches the
    -- sequence's specID (mirrors the talentBuild gate in ResolveExportContext)
    -- so off-spec exports never attach a wrong-spec tempo.
    local curSpecID
    if C_SpecializationInfo and C_SpecializationInfo.GetSpecialization then
        local idx = C_SpecializationInfo.GetSpecialization()
        if idx and GetSpecializationInfo then
            curSpecID = GetSpecializationInfo(idx)
        end
    end
    local TA = GRIPEMS.TempoAdvisor
    if curSpecID and seqData.specID and curSpecID == seqData.specID and TA and TA.GetRecommendation then
        local recOk, rec = pcall(TA.GetRecommendation, TA, sequenceName)
        if recOk and type(rec) == "table" then
            local tempo = {
                recommendedMs = rec.recommendedMs,
                theoreticalMs = rec.theoreticalMs,
                blendedMs = rec.blendedMs,
                complexity = rec.complexity,
                offGCDCount = rec.offGCDCount,
                unknownCount = rec.unknownCount,
            }
            if TA.GetEffectiveConfidence then
                local confOk, confidence = pcall(TA.GetEffectiveConfidence, TA, rec)
                if confOk and confidence ~= nil then
                    tempo.confidence = confidence
                end
            end
            insights.tempo = tempo
        end
    end

    -- Health counts from the repair analyzer at export time.
    local RA = GRIPEMS.RepairAnalyzer
    if RA and RA.Analyze then
        local issuesOk, issues = pcall(RA.Analyze, RA, seqData, sequenceName)
        if issuesOk and type(issues) == "table" then
            local health = { critical = 0, error = 0, warning = 0 }
            for _, issue in ipairs(issues) do
                if type(issue) == "table" then
                    if issue.severity == "critical" then
                        health.critical = health.critical + 1
                    elseif issue.severity == "error" then
                        health.error = health.error + 1
                    else
                        health.warning = health.warning + 1
                    end
                end
            end
            insights.health = health
        end
    end

    return insights
end

--- Build the merged wire Dependencies field for one sequence. Preserves the
--- stored MetaData Macros list (source-format key casing) and adds scans of
--- the ID-tagged export copies: embedded /click GRIPEMS_* references and
--- ~variable~ tokens. Returns nil when all three lists are empty so plain
--- sequences keep the key off the wire.
--- @param seqData table Privacy-scrubbed sequence data
--- @param exportVersions table ID-tagged versions from PrepareExportVersions
--- @return table|nil Dependencies { Macros?, Sequences?, Variables? }
function GE.BuildDependenciesField(seqData, exportVersions)
    local macros
    local storedDeps = seqData.MetaData and seqData.MetaData.Dependencies
    if storedDeps and type(storedDeps.Macros) == "table" then
        macros = {}
        for i, macName in ipairs(storedDeps.Macros) do
            macros[i] = macName
        end
    end

    local seqSet, seqList = {}, {}
    local varSet, varList = {}, {}
    local function scanVars(text)
        for varName in text:gmatch(D.VAR_PATTERN) do
            if not varSet[varName] then
                varSet[varName] = true
                varList[#varList + 1] = varName
            end
        end
    end
    for _, ver in ipairs(exportVersions) do
        if ver.steps then
            for _, step in ipairs(ver.steps) do
                if type(step) == "string" then
                    for refName in step:gmatch("/click GRIPEMS_(%S+)") do
                        if not seqSet[refName] then
                            seqSet[refName] = true
                            seqList[#seqList + 1] = refName
                        end
                    end
                    scanVars(step)
                end
            end
        end
        if type(ver.keyPress) == "string" then
            scanVars(ver.keyPress)
        end
        if type(ver.keyRelease) == "string" then
            scanVars(ver.keyRelease)
        end
    end
    table.sort(varList)

    if (not macros or #macros == 0) and #seqList == 0 and #varList == 0 then
        return nil
    end
    local deps = {}
    if macros and #macros > 0 then
        deps.Macros = macros
    end
    if #seqList > 0 then
        deps.Sequences = seqList
    end
    if #varList > 0 then
        deps.Variables = varList
    end
    return deps
end

--- Build a wire variable-bundle entry from a stored definition. Shared by
--- the step / keyPress / keyRelease scans in GE.Export. localeRisk is a
--- guarded pcall read so harnesses without the locale-risk index skip it.
--- @param varName string Variable name (locale-risk lookup key)
--- @param varDef table Stored variable definition
--- @return table Wire entry
local function BuildVarBundleEntry(varName, varDef)
    local entry = {
        funct = varDef.funct,
        events = varDef.events or "",
        author = varDef.author or "",
        comments = varDef.comments or varDef.description,
        version = varDef.version,
    }
    if varDef.disabled then
        entry.disabled = true
    end
    local VS = GRIPEMS.VariableStore
    if VS and VS.GetLocaleRisk then
        local riskOk, risk = pcall(VS.GetLocaleRisk, VS, varName)
        if riskOk and risk then
            entry.localeRisk = true
        end
    end
    return entry
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

    local ilAC = GRIPEMS.ActionCompiler
    local ilVer = type(seqData.versions) == "table" and seqData.versions[seqData.defaultVersion or 1] or nil
    if
        ilAC
        and ilAC.CompilesEmptyDueToInterleave
        and ilVer
        and ilVer.actions
        and ilAC.CompilesEmptyDueToInterleave(ilVer.actions)
    then
        GRIPEMS:Print(L["GEMS_INTERLEAVE_NOBASE_WARN"])
    end

    -- v2.1.0 Phase D: scrub the local user's identity per the per-sequence
    -- privacyMode (defaults to seq.privacyMode then to config.privacyDefault
    -- then to "public"). Foreign-author entries (forkedFromChain ancestors,
    -- other modifiers) stay visible -- only the local user's identity is
    -- rewritten. BuildExportPayload deep-copies, so the scrub never mutates
    -- the local sequence in GRIPEMS.Engine.sequences.
    local Identity = GRIPEMS.Identity
    if Identity and Identity.BuildExportPayload then
        seqData = Identity:BuildExportPayload(seqData, seqData.privacyMode)
    end

    -- Prepare export versions (deep-copy + spell tag translation)
    local exportVersions = GE.PrepareExportVersions(seqData)
    local bc = GE.ResolveExportContext(seqData)

    -- Build GRIP1 payload (v4: action tree + locale-safe spell ID tags)
    local payload = {
        format = "GRIP-EMS",
        version = D.GRIP_FORMAT_VERSION,
        addonVersion = GRIPEMS.version,
        wowPatch = bc.wowPatch,
        wowBuild = bc.wowBuild,
        wowInterface = bc.wowInterface,
        locale = GetLocale(),
        exportedAt = time(),
        schemaRev = D.EMS_EXPORT_SCHEMA_REV,
        name = sequenceName,
        sequence = {
            icon = seqData.icon or D.QUESTION_MARK_ICON,
            versions = exportVersions,
            defaultVersion = seqData.defaultVersion or 1,
            contextOverrides = seqData.contextOverrides or {},
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
            -- v2.1.0 Phase D: provenance + privacy-aware identity fields.
            -- Already scrubbed via BuildExportPayload above; receivers
            -- read these to render verification badges and ancestry.
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
            -- v2.3.3 Phase 1: merged dependency field (stored Macros list +
            -- embedded-sequence + variable scans) and export-time insights.
            -- Receivers recompute insights locally and never persist them.
            Dependencies = GE.BuildDependenciesField(seqData, exportVersions),
            insights = GE.BuildInsights(sequenceName, seqData, exportVersions),
        },
    }

    -- v2.3.3 Phase 1: privacy-aware exporter identity + region. exportedBy is
    -- omitted entirely in private mode; region ships only in public mode.
    local effectiveMode = seqData.privacyMode
    if not effectiveMode or effectiveMode == "" then
        effectiveMode = (GRIP_EMS_DB and GRIP_EMS_DB.config and GRIP_EMS_DB.config.privacyDefault)
            or D.PRIVACY_MODE_DEFAULT
            or "public"
    end
    local exportedBy = GE.BuildExportedBy(effectiveMode)
    if exportedBy then
        payload.exportedBy = exportedBy
    end
    if effectiveMode == D.PRIVACY_MODE_PUBLIC and GetCurrentRegionName then
        payload.region = GetCurrentRegionName()
    end

    -- v2.3.3 Phase 1: bundle macro-dependency bodies (same shape as the
    -- collection Macros bundle) so P2P single-sequence sends stop losing
    -- referenced macros. Skips silently headless (no GetMacroInfo).
    local seqDeps = payload.sequence.Dependencies
    if seqDeps and type(seqDeps.Macros) == "table" and #seqDeps.Macros > 0 and GetMacroInfo then
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
        local bundle
        for _, macName in ipairs(seqDeps.Macros) do
            local info = nameToInfo[macName]
            if info then
                bundle = bundle or {}
                bundle[macName] = {
                    name = macName,
                    icon = info.icon or D.QUESTION_MARK_ICON,
                    text = info.body,
                    category = info.scope,
                }
            end
        end
        if bundle then
            payload.Macros = bundle
        end
    end

    -- GRIP1 v5: Bundle variable definitions used by this sequence
    local vars = {}
    for _, ver in ipairs(exportVersions) do
        if ver.steps then
            for _, step in ipairs(ver.steps) do
                if type(step) == "string" then
                    for vn in step:gmatch(D.VAR_PATTERN) do
                        if not vars[vn] then
                            local varDef = GRIPEMS.VariableStore:Get(vn)
                            if varDef then
                                vars[vn] = BuildVarBundleEntry(vn, varDef)
                            end
                        end
                    end
                end
            end
        end
        if ver.keyPress and type(ver.keyPress) == "string" then
            for vn in ver.keyPress:gmatch(D.VAR_PATTERN) do
                if not vars[vn] then
                    local varDef = GRIPEMS.VariableStore:Get(vn)
                    if varDef then
                        vars[vn] = BuildVarBundleEntry(vn, varDef)
                    end
                end
            end
        end
        if ver.keyRelease and type(ver.keyRelease) == "string" then
            for vn in ver.keyRelease:gmatch(D.VAR_PATTERN) do
                if not vars[vn] then
                    local varDef = GRIPEMS.VariableStore:Get(vn)
                    if varDef then
                        vars[vn] = BuildVarBundleEntry(vn, varDef)
                    end
                end
            end
        end
    end
    if next(vars) then
        payload.variables = vars
    end

    if seqData.contextOverrides and next(seqData.contextOverrides) then
        payload.contextOverrides = seqData.contextOverrides
    end

    -- v2.1.0: emit native !EMS1! format. Receivers accept !EMS1! + legacy !GRIP1!.
    local ok, encoded = S.Encode(payload, D.EMS1_PREFIX)
    if not ok then
        return false, "Export encoding failed: " .. tostring(encoded)
    end

    return true, encoded
end

--- Import a native EMS-encoded string back into a sequence.
--- Accepts !EMS1! (v2.1.0+ native) and !GRIP1! (pre-v2.1.0 native, back-compat).
--- Validates the payload format and version, then builds sequenceData.
--- @param encodedString string The !EMS1!- or !GRIP1!-prefixed encoded string
--- @return boolean success
--- @return string nameOrError Sequence name on success, error message on failure
--- @return table|nil seqData The sequenceData table (only on success)
function GE.ImportNative(encodedString)
    local ok, decoded, format = S.Decode(encodedString)
    if not ok then
        return false, decoded
    end

    if format ~= "EMS1" and format ~= "GRIP1" then
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
    if type(decoded.locale) == "string" and decoded.locale ~= GetLocale() then
        if GRIPEMS.DebugWindow then
            GRIPEMS.DebugWindow:AddMessage(
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
                -- Locale: re-tag (catalog-backed, cross-locale) then render to the
                -- client locale. Robust even if the transport carried English
                -- literals from a pre-fix sender, where the old raw capture would
                -- have stored English as the "tagged" form.
                SC:NormalizeVersionLocale(ver, seq.classID)
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
        changelog = seq.changelog,
        -- v2.3.4: author-set talent string wins; the live-capture fallback is
        -- gated on provenance ABSENCE because talentString is signed content
        -- and talentBuild is the unsigned display key (see the ImportPreview
        -- builder for the full rationale). Trailing nil: never store false.
        talentString = (seq.talentString and seq.talentString ~= "" and seq.talentString)
            or ((not seq.originalAuthor or seq.originalAuthor == "") and seq.talentBuild)
            or nil,
        url = seq.url,
        classID = seq.classID or select(3, UnitClass("player")) or 0,
        specID = seq.specID,
        createdAt = seq.createdAt or time(),
        updatedAt = seq.updatedAt or time(),
    }

    -- The native exporter ships these fields; dropping them here degraded
    -- every shared sequence to the no-provenance family at the next repair
    -- pass. Mirrors the ProcessSequence carry arm in LegacyImport.lua, plus
    -- forkedFromChain (present on the wire).
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
        -- type(), not truthiness: ipairs raises on a number, a boolean AND a
        -- string. Unlike the length operator, which returns a length for a
        -- string, there is no tolerant shape here.
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

    seqData.contextOverrides = decoded.contextOverrides or {}

    -- v2.3.3 Phase 1: carry the merged wire Dependencies field so round-trips
    -- keep macro / sequence / variable dep info readable by ResolveMacroDeps.
    -- insights / exportedBy / exportedAt / region / schemaRev are NEVER
    -- persisted -- receivers recompute those locally.
    if type(seq.Dependencies) == "table" then
        seqData.MetaData = seqData.MetaData or {}
        seqData.MetaData.Dependencies = seq.Dependencies
    end

    -- GRIP1 v5: Import bundled variable definitions
    local importedVars = {}
    if decoded.variables and type(decoded.variables) == "table" then
        for varName, varDef in pairs(decoded.variables) do
            -- Validate before importing
            local nameOk, nameErr = GRIPEMS.VariableStore:ValidateName(varName)
            if not nameOk then
                GRIPEMS:Debug("Import: skipping variable " .. tostring(varName) .. " -- " .. tostring(nameErr))
            elseif varDef.funct and type(varDef.funct) == "string" then
                local funcOk, funcErr = GRIPEMS.VariableStore:ValidateFunction(varDef.funct)
                if not funcOk then
                    GRIPEMS:Debug(
                        "Import: skipping variable "
                            .. tostring(varName)
                            .. " -- invalid function: "
                            .. tostring(funcErr)
                    )
                else
                    -- Build clean varDef (only import safe fields)
                    local cleanDef = {
                        name = varName,
                        funct = varDef.funct,
                        events = varDef.events or "",
                        disabled = false,
                        eventsEnabled = true,
                        author = varDef.author or "",
                    }
                    -- Check for existing variable with same name
                    local existing = GRIPEMS.VariableStore:Get(varName)
                    if existing then
                        -- Only overwrite if user confirms (skip silently for now)
                        GRIPEMS:Debug("Import: variable " .. varName .. " already exists, skipping")
                    else
                        GRIPEMS.VariableStore:Set(varName, cleanDef)
                        importedVars[#importedVars + 1] = varName
                    end
                end
            end
        end
    end

    seqData.importedVariables = importedVars

    local ver = GRIPEMS.Engine:GetActiveVersion(seqData)
    if not ver or type(ver.steps) ~= "table" or #ver.steps == 0 then
        return false, "Imported sequence has no steps"
    end

    return true, decoded.name, seqData
end

---------------------------------------------------------------------------
-- GE.ExportAsText(seqNames, varNames, macNames)
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
        local info
        if C_Spell and C_Spell.GetSpellInfo then
            local ok, result = pcall(C_Spell.GetSpellInfo, icon)
            if ok then
                info = result
            end
        end
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

--- Recursively emit the action tree with [label] prefixes (Phase 1C-bis-outline).
--- Mirrors the flat-mode [label] prefix format for round-trip parity.
--- @param actions table Array of action nodes
--- @param lines table Output line accumulator
--- @param indent string Leading whitespace for the current depth
local function emitActionTree(actions, lines, indent)
    -- Corrupt sequence data can leave non-table entries in an actions array
    -- or a non-table children field; both are skipped so export-as-text of a
    -- corrupt sequence still emits every well-formed node.
    if type(actions) ~= "table" then
        return
    end
    for idx, node in ipairs(actions) do
        if type(node) == "table" then
            local pfx = ""
            -- A table label passes both halves of the guard above and fails the
            -- concatenation. node.label is written by the editor, not by any
            -- import path, so this is defence against a hand-edited
            -- SavedVariables file rather than against a pasted payload.
            if node.label and node.label ~= "" then
                pfx = "[" .. tostring(node.label) .. "] "
            end
            local t = node.type
            if t == D.ACTION_TYPE_ACTION then
                lines[#lines + 1] = indent .. idx .. ") " .. pfx .. (node.macro or "")
            elseif t == D.ACTION_TYPE_LOOP then
                local r = node["repeat"] or D.ACTION_LOOP_DEFAULT_REPEAT
                local sfName = node.stepFunction or D.STEP_SEQUENTIAL
                lines[#lines + 1] = indent .. idx .. ") " .. pfx .. "Loop x" .. r .. " (" .. sfName .. ")"
                if node.children then
                    emitActionTree(node.children, lines, indent .. "  ")
                end
            elseif t == D.ACTION_TYPE_IF then
                lines[#lines + 1] = indent .. idx .. ") " .. pfx .. "If " .. tostring(node.variable or "")
                if type(node.children) == "table" then
                    if type(node.children[1]) == "table" then
                        lines[#lines + 1] = indent .. "  True:"
                        emitActionTree(node.children[1], lines, indent .. "    ")
                    end
                    if type(node.children[2]) == "table" and #node.children[2] > 0 then
                        lines[#lines + 1] = indent .. "  False:"
                        emitActionTree(node.children[2], lines, indent .. "    ")
                    end
                end
            elseif t == D.ACTION_TYPE_EMBED then
                lines[#lines + 1] = indent .. idx .. ") " .. pfx .. "Embed: " .. (node.sequence or "")
            elseif t == D.ACTION_TYPE_PAUSE then
                local pinfo
                if node.ms then
                    pinfo = node.ms .. "ms"
                elseif node.gcd then
                    pinfo = node.gcd .. " GCD"
                else
                    pinfo = (node.clicks or 1) .. " clicks"
                end
                lines[#lines + 1] = indent .. idx .. ") " .. pfx .. "Pause: " .. pinfo
            end
        end
    end
end

--- Format a single version block as indented text lines.
--- @param ver table Version data
--- @param vIdx number Version index (1-based)
--- @param vCount number Total version count
--- @param lines table Output line accumulator
local function FormatVersionBlock(ver, vIdx, vCount, lines)
    -- POLISH-EXPORTASTEXT-LOCALE (Backlog L97): locale-key migration. Single-
    -- version sequences flag the lone version as (Default); multi-version
    -- sequences number them. Both paths route through string.format so the
    -- index interpolates into the localized template.
    if vCount == 1 then
        lines[#lines + 1] = string.format(L["GEMS_EXPORTTEXT_VERSION_HEADING_DEFAULT"], vIdx)
    else
        lines[#lines + 1] = string.format(L["GEMS_EXPORTTEXT_VERSION_HEADING"], vIdx)
    end

    -- Step function
    local sf = ver.stepFunction or D.STEP_SEQUENTIAL
    lines[#lines + 1] = L["GEMS_EXPORTTEXT_STEPFUNCTION_LABEL"] .. sf

    -- Reset conditions
    local resetStr = D.BuildResetString(ver)
    if resetStr ~= "" then
        lines[#lines + 1] = L["GEMS_EXPORTTEXT_RESET_LABEL"] .. resetStr
    end

    -- Steps
    lines[#lines + 1] = L["GEMS_EXPORTTEXT_STEPS_HEADING"]
    -- type(), not truthiness: a stored seqData can carry an imported shape.
    -- Measured -- steps = 42 or true raises here at the length operator, and
    -- steps = "text" clears it and raises one line down at ipairs instead.
    if type(ver.steps) == "table" and #ver.steps > 0 then
        for idx, step in ipairs(ver.steps) do
            if type(step) == "string" then
                local slabel = ver.stepLabels and ver.stepLabels[idx]
                if slabel and slabel ~= "" then
                    lines[#lines + 1] = "    " .. idx .. ") [" .. slabel .. "] " .. step
                else
                    lines[#lines + 1] = "    " .. idx .. ") " .. step
                end
            end
        end
    else
        lines[#lines + 1] = L["GEMS_EXPORTTEXT_STEPS_NONE"]
    end

    -- Action tree (Phase 1C-bis-outline): emit with per-node [label] prefixes
    -- Same family and same stored-shape reach as the steps read above.
    if type(ver.actions) == "table" and #ver.actions > 0 then
        lines[#lines + 1] = L["GEMS_EXPORTTEXT_ACTIONS_HEADING"]
        emitActionTree(ver.actions, lines, "    ")
    end

    -- KeyPress (inline, skip if empty). ExecText, not a bare read: this
    -- same file already type-checks ver.keyPress at :683 before gmatch,
    -- so the field is known to arrive non-string. A table here raised
    -- "attempt to concatenate field 'keyPress'".
    local keyPressText = D.ExecText(ver.keyPress)
    if keyPressText ~= "" then
        lines[#lines + 1] = L["GEMS_EXPORTTEXT_KEYPRESS_LABEL"] .. keyPressText
    end

    -- KeyRelease (inline, skip if empty)
    local keyReleaseText = D.ExecText(ver.keyRelease)
    if keyReleaseText ~= "" then
        lines[#lines + 1] = L["GEMS_EXPORTTEXT_KEYRELEASE_LABEL"] .. keyReleaseText
    end
end

--- Export selected sequences and variables as a human-readable text block.
--- Walks all versions per sequence. Suitable for forum/Discord sharing.
--- @param seqNames table Array of sequence names
--- @param varNames table Array of variable names
--- @param macNames table|nil Array of macro names (optional)
--- @return string Plain-text summary
function GE.ExportAsText(seqNames, varNames, macNames)
    local Engine = GRIPEMS.Engine
    local VS = GRIPEMS.VariableStore
    local lines = {}

    for si, seqName in ipairs(seqNames) do
        local entry = Engine.sequences[seqName]
        if entry and entry.data then
            local seqData = entry.data
            -- type(), not truthiness. Measured: a stored versions = 42 raises
            -- here with "attempt to get length of local 'versions'".
            local versions = type(seqData.versions) == "table" and seqData.versions or nil
            local vCount = (type(versions) == "table" and #versions) or 0

            -- Header metadata
            lines[#lines + 1] = L["GEMS_EXPORTTEXT_SEQUENCE_LABEL"] .. seqName
            lines[#lines + 1] = L["GEMS_EXPORTTEXT_AUTHOR_LABEL"]
                .. D.DisplayText(seqData.author, L["GEMS_EXPORTTEXT_AUTHOR_UNKNOWN"])
            -- type(), not truthiness: a table clears both halves and then
            -- raises inside string.format below -- on Lua 5.1 "%s" does not
            -- coerce a table, it errors.
            if type(seqData.originalAuthor) == "string" and seqData.originalAuthor ~= "" then
                lines[#lines + 1] = string.format(L["GEMS_EXPORTTEXT_CREATEDBY"], seqData.originalAuthor)
            end
            if seqData.classID then
                local className
                if GetClassInfo then
                    className = GetClassInfo(seqData.classID)
                end
                lines[#lines + 1] = L["GEMS_EXPORTTEXT_CLASS_LABEL"] .. (className or tostring(seqData.classID))
            end
            lines[#lines + 1] = L["GEMS_EXPORTTEXT_SPEC_LABEL"] .. ResolveSpecName(seqData.specID)
            if seqData.description and seqData.description ~= "" then
                lines[#lines + 1] = L["GEMS_EXPORTTEXT_DESC_LABEL"] .. seqData.description
            end
            if seqData.talentString and seqData.talentString ~= "" then
                lines[#lines + 1] = L["GEMS_EXPORTTEXT_TALENT_LABEL"] .. seqData.talentString
            end
            local linkTarget
            if seqData.url and seqData.url ~= "" then
                linkTarget = seqData.url
            elseif seqData.helplink and seqData.helplink ~= "" then
                linkTarget = seqData.helplink
            end
            if linkTarget then
                lines[#lines + 1] = L["GEMS_EXPORTTEXT_URL_LABEL"] .. linkTarget
            end

            -- Top-level step function (from first version as representative)
            local topSF = D.STEP_SEQUENTIAL
            if versions and versions[1] then
                topSF = versions[1].stepFunction or D.STEP_SEQUENTIAL
            end
            lines[#lines + 1] = L["GEMS_EXPORTTEXT_STEPFUNCTION_LABEL"] .. topSF

            -- Icon
            lines[#lines + 1] = L["GEMS_EXPORTTEXT_ICON_LABEL"] .. ResolveIconName(seqData.icon)
            lines[#lines + 1] = L["GEMS_EXPORTTEXT_VERSIONS_LABEL"] .. vCount
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
        lines[#lines + 1] = L["GEMS_EXPORTTEXT_VARIABLES_HEADING"]
        for _, varName in ipairs(varNames) do
            local varDef = VS:Get(varName)
            if varDef then
                local body = varDef.funct or ""
                if #body > 80 then
                    body = body:sub(1, 80) .. "..."
                end
                local eventStr = ""
                if varDef.events and varDef.events ~= "" then
                    eventStr = string.format(L["GEMS_EXPORTTEXT_VARIABLE_EVENT_SUFFIX"], varDef.events)
                end
                lines[#lines + 1] = "  - " .. varName .. ": " .. body .. eventStr
            end
        end
    end

    -- Macros section
    if macNames and #macNames > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = L["GEMS_EXPORTTEXT_MACROS_HEADING"]
        local accountCap = MAX_ACCOUNT_MACROS or 120
        for _, macName in ipairs(macNames) do
            local slot = GetMacroIndexByName(macName)
            if slot and slot > 0 then
                local _, _, mbody = GetMacroInfo(slot)
                local bodyPreview = mbody or ""
                if #bodyPreview > 80 then
                    bodyPreview = bodyPreview:sub(1, 80) .. "..."
                end
                local scopeLabel = (slot > accountCap) and L["GEMS_EXPORT_PICK_MACRO_SCOPE_CHARACTER"]
                    or L["GEMS_EXPORT_PICK_MACRO_SCOPE_ACCOUNT"]
                lines[#lines + 1] = "  - " .. macName .. " [" .. scopeLabel .. "]: " .. bodyPreview
            end
        end
    end

    -- Footer: addon version + WoW patch provenance. Empty-string fallbacks
    -- keep the headless harness (no WoW env, no version stamp) green.
    local patchStr = ""
    if GetBuildInfo then
        patchStr = GetBuildInfo() or ""
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = string.format(L["GEMS_EXPORTTEXT_FOOTER"], GRIPEMS.version or "", patchStr)

    return table.concat(lines, "\n")
end
