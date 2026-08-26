-- GRIP-EMS: Headless test for the lazy V0 signature-upgrade guard
--
-- Created:    2026-07-30
-- Updated:    2026-08-17
-- Patch: 12.1.0.69299 Midnight (Retail LIVE)
--
-- CI-enforced proof of the SECURITY-RELEVANT half of the lazy signature
-- upgrade guard in UI/PopupEditor.lua's SaveSequence.
--
-- The bug: an inbound payload that carries originalAuthor but no
-- originalSignature lands on the ALG_V0_DJB2 default. The upgrade branch used
-- to test the algorithm ONLY, so on the first local save it wrote the LOCAL
-- user's identityHash into originalAuthorIdentity, minted an originalSignature
-- with the local key, and let EnsureOwnedV2Signature stamp V2 on top. A
-- foreign byline then read as verified under the importer's identity. The
-- branch now also requires a non-empty originalSignature before it migrates,
-- so an unsigned import is deliberately left unsigned.
--
-- The same four cases live in Hub/Tools/lua_headless as
-- test_popup_save_field_carry.lua cases 5 and 6, but that harness is SET B and
-- CI runs alltest --sets ac, so nothing there can redden a build. This file is
-- the CI-reachable gate: SET A is glob-discovered from EMS/Test/test_*.lua and
-- lives in the same repo as the guard it pins.
--
-- Drives the REAL shipped UI/PopupEditor.lua through the WoW addon vararg
-- contract (loadfile + setfenv into a stub-backed sandbox), so the assertions
-- read the payload SaveSequence actually hands to Engine:UpdateSequenceData.
--
-- Run from the EMS root:  lua Test/test_v0_upgrade_guard.lua
-- Exit code 0 = all passed, 1 = at least one failure.
--
-- SCOPE IS WIDER THAN THE FILENAME. The harness captures the exact payload a
-- real PE:SaveSequence hands to Engine:UpdateSequenceData, which is the one
-- place every popup save-path invariant becomes visible, so cases that have
-- nothing to do with signatures live here too. The file now pins the
-- signature-upgrade guard (V1-V3), per-version schema parity across both editor
-- saves (V4-V5), and the popup save-path invariants on steps and their sidecars
-- (V6-V11). Read the filename as "where the popup save payload is asserted",
-- not as the full subject list.
--
-- Cases:
--   V1  unsigned inbound payload: no identityHash bound, no signature minted,
--       algorithm left at ALG_V0_DJB2, byline untouched
--   V2  genuinely legacy V0 (non-empty originalSignature): still upgrades to
--       ALG_V1_SHA256 (no-regression control, green before and after the fix)
--   V3  the two shapes DIVERGE on all three signature fields. Before the fix
--       both upgraded identically, so this case is the one that goes red.
--   V4  every D.NewVersion key survives the POPUP editor save
--   V5  every D.NewVersion key survives the STRUCTURED editor save
--   V6  a popup save of a TREE-MODE version does not persist the flat working
--       copy: steps and stepFunction come from stored data, because
--       Engine:UpdateSequenceData recompiles both from the tree inside the same
--       call and would discard the edit that the save was meant to keep
--   V7  the control that forbids satisfying V6 by never writing working steps
--       at all: a FLAT version still persists every edited step and the working
--       stepFunction
--   V8  compiledLabels ALWAYS carry through a popup save, as a fresh sparse
--       copy rather than an alias, and a baked import (importBakedSteps set,
--       tree present) is the shape that proves it: both recompile paths skip a
--       baked version, so the carry is the only thing preserving its labels.
--       The treeless case is deliberately left unpinned -- see the comment on
--       the carry in UI/PopupEditor.lua.
--   V9  a popup save cancels a quick re-sign armed by the structured editor on
--       the same sequence, so the full save's signature is not followed by a
--       duplicate modifier-chain entry
--  V10  switching version clears the popup undo stack, so an undo closure
--       holding the OUTGOING version's step indices cannot rewrite the
--       INCOMING version's working copy at those positions
--  V11  switching version clears the undo stack even when the switch returns
--       early at the entry guard, which pins the clear ABOVE those guards
--       rather than merely present. V10 alone passes with the block on either
--       side of the guards; this case fails unless it sits above them.
--
-- V4 and V5 are a different guard bolted onto the same harness, because the
-- harness already captures the exact payload a real save hands to
-- Engine:UpdateSequenceData, which is where a dropped field becomes visible.
-- Both editors rebuild every version from a hand-enumerated field list, so any
-- per-version field missing from that list is deleted by the Save the editor
-- itself offers. See the block above those cases for the three times it has
-- happened.

local ADDON_NAME = "GRIP-EMS"

-- ---------------------------------------------------------------------------
-- Minimal assertion + runner harness (mirrors test_legacy_import_parity.lua).
-- ---------------------------------------------------------------------------

local tests = {}

local function test(name, fn)
    tests[#tests + 1] = { name = name, fn = fn }
end

local function assertEqual(expected, actual, label)
    if expected ~= actual then
        error((label or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
    end
end

local function assertNotEqual(unwanted, actual, label)
    if unwanted == actual then
        error((label or "value") .. ": expected anything but " .. tostring(unwanted), 2)
    end
end

local function assertTrue(cond, label)
    if not cond then
        error((label or "condition") .. " failed", 2)
    end
end

-- ---------------------------------------------------------------------------
-- Sandbox: a self-referential no-op stub backs every unknown global, so the
-- shipped UI module loads without a real WoW client. Real stdlib falls
-- through to _G.
-- ---------------------------------------------------------------------------

local stub = {}
setmetatable(stub, {
    __index = function()
        return stub
    end,
    __call = function()
        return stub
    end,
})

local env = setmetatable({}, {
    __index = function(_, k)
        local v = rawget(_G, k)
        if v ~= nil then
            return v
        end
        return stub
    end,
})
env._G = env

-- Locale keys echo back so any format string in the save path resolves.
local LOCALE = setmetatable({}, {
    __index = function(_, k)
        return k
    end,
})

env.LibStub = function()
    return {
        GetLocale = function()
            return LOCALE
        end,
    }
end
-- SaveSequence stamps updatedAt (and createdAt when absent) from time().
env.time = os.time

local function DeepCopy(v)
    if type(v) ~= "table" then
        return v
    end
    local copy = {}
    for k, val in pairs(v) do
        copy[k] = DeepCopy(val)
    end
    return copy
end

local GRIPEMS = {
    UI = {},
    Debug = function() end,
    Print = function() end,
    Defaults = {
        DeepCopyActions = DeepCopy,
        STEP_SEQUENTIAL = "Sequential",
        STEP_RANDOM = "Random",
        STEP_PRIORITY = "Priority",
        STEP_REVERSE_PRIORITY = "ReversePriority",
    },
}

-- ---------------------------------------------------------------------------
-- Load the REAL UI/PopupEditor.lua into the sandbox.
-- ---------------------------------------------------------------------------

local function loadModule(candidates)
    for _, path in ipairs(candidates) do
        -- loadfile is dev-harness file I/O, intentionally outside the addon WoW std.
        -- selene: allow(undefined_variable)
        local chunk = loadfile(path)
        if chunk then
            setfenv(chunk, env)
            chunk(ADDON_NAME, GRIPEMS)
            return true
        end
    end
    return false
end

assertTrue(
    loadModule({
        "UI/PopupEditor.lua",
        "../UI/PopupEditor.lua",
        "GRIP/EMS/UI/PopupEditor.lua",
    }),
    "could not locate UI/PopupEditor.lua (run from the EMS root)"
)

local PE = GRIPEMS.PopupEditor
assertTrue(PE ~= nil, "GRIPEMS.PopupEditor attached")
assertTrue(type(PE.SaveSequence) == "function", "PE.SaveSequence defined")

-- The logic under test ends at engine:UpdateSequenceData. Everything after it
-- is widget refresh, so stub those methods out and the run never touches frames.
local function noop() end
PE.UpdateSaveButtons = noop
PE.RefreshStepList = noop

-- ---------------------------------------------------------------------------
-- Fixture + Identity stub (stub shape copied from the SET B sibling
-- test_popup_save_field_carry.lua so the two harnesses agree on the contract).
-- ---------------------------------------------------------------------------

local function FixtureData(name)
    return {
        name = name,
        icon = 134400,
        autoIcon = false,
        defaultVersion = 1,
        author = "Origi",
        version = "4",
        classID = 11,
        specID = 105,
        createdAt = 1000,
        contextOverrides = { party = 2 },
        privacyMode = "pseudonymous",
        originalAuthor = "Origi",
        originalAuthorIdentity = "HASH_ORIG",
        originalAuthorRealm = "RealmA",
        originalCreatedAt = 111,
        originalSignature = "OSIG",
        lastModifier = "Modder",
        lastModifierIdentity = "HASH_MOD",
        lastModifierRealm = "RealmB",
        lastModifiedAt = 222,
        modifierChain = {
            { name = "Origi", identity = "HASH_ORIG", realm = "RealmA", at = 111, kind = "created" },
        },
        provenanceSource = "native",
        signatureAlgorithm = "ALG_V1_SHA256",
        currentSignature = "CSIG",
        versions = {
            {
                stepFunction = "Sequential",
                steps = { "/cast A", "/cast B" },
                resetOnCombat = true,
                resetTimer = 5,
                keyPress = "/startattack",
                keyRelease = "/stopattack",
                actions = { { type = "spell", value = "A" }, { type = "spell", value = "B" } },
            },
        },
    }
end

-- Popup instance as LoadSequence would leave it: a flat working copy of the
-- active version with one step edited in, actions tree stored unchanged.
local function MakeInst(name, oldData)
    return {
        currentSequence = name,
        activeVersionIndex = 1,
        isDirty = true,
        workingStepFunction = "Sequential",
        workingSteps = { "/cast A", "/cast NEW", "/cast B" },
        workingActions = DeepCopy(oldData.versions[1].actions),
    }
end

local stampLog = {}

local function MakeIdentityStub()
    return {
        StampOriginal = function(_, seq, chosen)
            table.insert(stampLog, { call = "stamp", chosen = chosen })
            seq.originalAuthor = "StampedAuthor"
            seq.signatureAlgorithm = "ALG_V1_SHA256"
            seq.currentSignature = "STAMPED"
        end,
        AppendModifierEntry = function(_, seq, kind)
            table.insert(stampLog, { call = "append", kind = kind })
            seq.modifierChain = seq.modifierChain or {}
            table.insert(seq.modifierChain, { name = "Editor", kind = kind })
            seq.currentSignature = "RESIGNED"
        end,
        GetCurrent = function()
            return { identityHash = "ME_HASH" }
        end,
        SignSequence = function()
            return "NEWSIG"
        end,
        -- The stub's owner (HASH_FOREIGN) never matches the current identity
        -- (ME_HASH), so the V2 helper returns false and logs nothing, which
        -- keeps the single-call stampLog assertions valid.
        EnsureOwnedV2Signature = function()
            return false
        end,
    }
end

local function RunSave(name, oldData)
    local captured
    GRIPEMS.Engine = {
        sequences = { [name] = { data = oldData } },
        UpdateSequenceData = function(_, seqName, seqData)
            assertEqual(name, seqName, "UpdateSequenceData sequence name")
            captured = seqData
        end,
    }
    PE:SaveSequence(MakeInst(name, oldData))
    assertTrue(captured ~= nil, "SaveSequence reached UpdateSequenceData for " .. name)
    return captured
end

-- Inbound payload with a foreign byline on the ALG_V0_DJB2 default. The only
-- difference between the two shapes below is originalSignature, which is
-- exactly the field the guard reads.
local function RunV0Import(name, sig)
    stampLog = {}
    GRIPEMS.Identity = MakeIdentityStub()
    local d = FixtureData(name)
    d.originalAuthor = "ForeignAuthor"
    d.originalAuthorIdentity = "HASH_FOREIGN"
    d.originalSignature = sig
    d.signatureAlgorithm = "ALG_V0_DJB2"
    d.provenanceSource = "no-provenance"
    local saved = RunSave(name, d)
    return saved, stampLog
end

local unsignedSaved, unsignedLog = RunV0Import("UnsignedImport", "")
local v0Saved, v0Log = RunV0Import("LegacyV0Signed", "V0SIG")

-- ---------------------------------------------------------------------------
-- Cases.
-- ---------------------------------------------------------------------------

test("V1: unsigned inbound payload keeps its foreign byline unsigned", function()
    assertEqual("", unsignedSaved.originalSignature, "no originalSignature minted (was NEWSIG before the guard)")
    assertEqual("HASH_FOREIGN", unsignedSaved.originalAuthorIdentity, "inbound identity preserved verbatim")
    assertNotEqual("ME_HASH", unsignedSaved.originalAuthorIdentity, "local identityHash NOT bound to a foreign byline")
    assertEqual("ALG_V0_DJB2", unsignedSaved.signatureAlgorithm, "algorithm left as is, nothing to migrate")
    assertEqual("ForeignAuthor", unsignedSaved.originalAuthor, "byline itself untouched")
    assertEqual("", unsignedSaved.originalSignatureV2 or "", "no V2 signature stamped on top")
    -- The local edit is still recorded: the guard suppresses the ORIGINAL
    -- signature only, never the edit marker.
    assertEqual(1, #unsignedLog, "exactly one identity call")
    assertEqual("append", unsignedLog[1].call, "the call is AppendModifierEntry")
    assertEqual("edited", unsignedLog[1].kind, "chain entry kind is edited")
    assertEqual("RESIGNED", unsignedSaved.currentSignature, "currentSignature (the edit marker) still stamped")
end)

test("V2: genuinely legacy V0 with a signature still upgrades (control)", function()
    assertEqual("ALG_V1_SHA256", v0Saved.signatureAlgorithm, "algorithm upgraded")
    assertEqual("ME_HASH", v0Saved.originalAuthorIdentity, "identity hash refreshed on upgrade")
    assertEqual("NEWSIG", v0Saved.originalSignature, "original signature recomputed on upgrade")
    assertEqual(1, #v0Log, "exactly one identity call")
    assertEqual("append", v0Log[1].call, "AppendModifierEntry still fired after the upgrade")
end)

test("V3: the signed and unsigned V0 shapes diverge, they are not both upgraded", function()
    assertNotEqual(
        unsignedSaved.signatureAlgorithm,
        v0Saved.signatureAlgorithm,
        "signatureAlgorithm must differ between the two shapes"
    )
    assertNotEqual(
        unsignedSaved.originalAuthorIdentity,
        v0Saved.originalAuthorIdentity,
        "originalAuthorIdentity must differ between the two shapes"
    )
    assertNotEqual(
        unsignedSaved.originalSignature,
        v0Saved.originalSignature,
        "originalSignature must differ between the two shapes"
    )
end)

-- ---------------------------------------------------------------------------
-- V4/V5: D.NewVersion schema parity across BOTH editor save rebuilds.
--
-- WHY THIS EXISTS. Both editor save paths rebuild every version from a
-- hand-enumerated field list, so a per-version field that is not named in that
-- list is DELETED by the Save the editor itself offers. That has now happened
-- three times in the same literal: recommendSource, variantOverrides, and
-- holdOnChannel/releaseAtMax. The third one made Evoker Mode unreachable through
-- the UI from the day it shipped -- the dropdown kept displaying the chosen mode
-- while the saved version came back nil. Each was fixed by appending one more
-- field. These two cases are what stops the fourth: iterate D.NewVersion, the
-- canonical per-version schema, and assert every key survives a real save.
--
-- ONE-DIRECTIONAL ON PURPOSE. The rebuilds also carry repeatCount,
-- importBakedSteps and recommendSource, none of which are in D.NewVersion, and
-- that is correct. The assertion is SCHEMA IS A SUBSET OF CARRIED, never equality.
--
-- resetModifiers is in the schema as an explicit nil, so pairs() cannot see it
-- and the loop cannot cover it. Both rebuilds carry it through a dedicated
-- "if ver.resetModifiers" branch rather than through the literal, so it gets its
-- own probe and its own assertion below.
--
-- The probe version sits at index 2 while the active index is 1, so it goes
-- through the PURE rebuild. Version 1 takes steps and stepFunction from the
-- editor's working copy, which would make "what went in came out" meaningless
-- for those two keys.
-- ---------------------------------------------------------------------------

-- Load a shipped module into its OWN sandbox so nothing above is disturbed.
local function LoadIsolated(paths, holder)
    local ienv = setmetatable({}, {
        __index = function(_, k)
            local v = rawget(_G, k)
            if v ~= nil then
                return v
            end
            return stub
        end,
    })
    ienv._G = ienv
    ienv.LibStub = env.LibStub
    ienv.time = os.time
    for _, path in ipairs(paths) do
        -- loadfile is dev-harness file I/O, intentionally outside the addon WoW std.
        -- selene: allow(undefined_variable)
        local chunk = loadfile(path)
        if chunk then
            setfenv(chunk, ienv)
            chunk(ADDON_NAME, holder)
            return true
        end
    end
    return false
end

local defaultsHolder = {}
assertTrue(
    LoadIsolated({ "Data/Defaults.lua", "../Data/Defaults.lua", "GRIP/EMS/Data/Defaults.lua" }, defaultsHolder),
    "could not locate Data/Defaults.lua (run from the EMS root)"
)
local SCHEMA = defaultsHolder.Defaults and defaultsHolder.Defaults.NewVersion
assertTrue(type(SCHEMA) == "table", "D.NewVersion loaded as a table")

-- A value that DIFFERS from the schema default for every key, so a rebuild that
-- silently substitutes the default cannot pass by accident.
local function ProbeValue(key, defaultValue)
    local t = type(defaultValue)
    if t == "boolean" then
        return not defaultValue
    elseif t == "number" then
        return defaultValue + 7
    elseif t == "string" then
        -- stepFunction has to stay a REAL step function; every other string just
        -- has to be distinguishable from its default.
        if key == "stepFunction" then
            return "Random"
        end
        return defaultValue .. "SCHEMA_PROBE"
    elseif t == "table" then
        return { "/cast SchemaProbeOne", "/cast SchemaProbeTwo" }
    end
    return "SCHEMA_PROBE_" .. tostring(key)
end

local function MakeProbeVersion()
    local v = {}
    for key, def in pairs(SCHEMA) do
        v[key] = ProbeValue(key, def)
    end
    v.resetModifiers = { Shift = true, Alt = false }
    return v
end

local function ValuesAgree(expected, actual)
    if type(expected) ~= "table" then
        return expected == actual
    end
    if type(actual) ~= "table" then
        return false
    end
    for k, ev in pairs(expected) do
        if actual[k] ~= ev then
            return false
        end
    end
    for k in pairs(actual) do
        if expected[k] == nil then
            return false
        end
    end
    return true
end

local function AssertSchemaSurvived(saved, label)
    local probe = MakeProbeVersion()
    local got = saved and saved.versions and saved.versions[2]
    assertTrue(type(got) == "table", label .. ": the probe version came back as a table")
    local checked = 0
    for key in pairs(SCHEMA) do
        assertTrue(
            ValuesAgree(probe[key], got[key]),
            label .. ": schema key '" .. key .. "' survived the save (got " .. tostring(got[key]) .. ")"
        )
        checked = checked + 1
    end
    -- Non-vacuity: D.NewVersion carries 11 non-nil keys today. If the loop ever
    -- runs over nothing, this case must fail rather than pass silently.
    assertTrue(checked >= 10, label .. ": the loop covered the whole schema, saw " .. checked .. " keys")
    assertTrue(ValuesAgree(probe.resetModifiers, got.resetModifiers), label .. ": resetModifiers survived")
end

local popupProbeSaved
do
    local d = FixtureData("SchemaParityPopup")
    d.versions[2] = MakeProbeVersion()
    -- MakeIdentityStub appends to the shared stampLog upvalue. Reset it here or
    -- these runs land in the table V2 counts, which reads as a V2 regression.
    stampLog = {}
    GRIPEMS.Identity = MakeIdentityStub()
    popupProbeSaved = RunSave("SchemaParityPopup", d)
end

test("V4: every D.NewVersion key survives the POPUP editor save (real PE:SaveSequence)", function()
    AssertSchemaSurvived(popupProbeSaved, "V4 popup")
end)

-- The SequenceEditor half runs the REAL SE:SaveSequence too. It was NOT
-- disproportionate to stub: SaveSequence needs GRIPEMS.StepListView and a
-- registered engine entry, and every widget read on the way through is
-- "SE.widget and ..." guarded, so with SE:Init never called each one falls back
-- to oldData. The module is loaded into its own sandbox so the popup harness
-- above is untouched.
local seHolder = setmetatable({}, {
    __index = function()
        return stub
    end,
})
local seLoaded = LoadIsolated({
    "UI/SequenceEditor.lua",
    "../UI/SequenceEditor.lua",
    "GRIP/EMS/UI/SequenceEditor.lua",
}, seHolder)
assertTrue(seLoaded, "could not locate UI/SequenceEditor.lua (run from the EMS root)")

local SE = rawget(seHolder, "SequenceEditor")
assertTrue(type(SE) == "table", "GRIPEMS.SequenceEditor attached")
assertTrue(type(SE.SaveSequence) == "function", "SE.SaveSequence defined")

local seProbeSaved
do
    local d = FixtureData("SchemaParitySE")
    d.versions[2] = MakeProbeVersion()
    local workingSteps = { "/cast A", "/cast NEW", "/cast B" }
    -- Only the three working-copy readers matter to the rebuild. Everything else
    -- SaveSequence calls on StepListView is post-save widget refresh, so a no-op
    -- fallback keeps the harness from growing a method list that drifts.
    rawset(
        seHolder,
        "StepListView",
        setmetatable({
            GetWorkingSteps = function()
                return workingSteps
            end,
            GetWorkingActions = function()
                return nil
            end,
            GetWorkingStepLabels = function()
                return nil
            end,
        }, {
            __index = function()
                return noop
            end,
        })
    )
    stampLog = {}
    rawset(seHolder, "Identity", MakeIdentityStub())
    rawset(seHolder, "Engine", {
        sequences = { SchemaParitySE = { data = d } },
        UpdateSequenceData = function(_, _, seqData)
            seProbeSaved = seqData
        end,
    })
    SE.currentSequence = "SchemaParitySE"
    SE.activeVersionIndex = 1
    SE.UpdateSaveButtons = noop
    SE.RefreshStepList = noop
    SE:SaveSequence()
end

test("V5: every D.NewVersion key survives the STRUCTURED editor save (real SE:SaveSequence)", function()
    assertTrue(seProbeSaved ~= nil, "V5: SE:SaveSequence reached UpdateSequenceData")
    AssertSchemaSurvived(seProbeSaved, "V5 structured")
end)

-- ---------------------------------------------------------------------------
-- V6-V9: POPUP save-path invariants on steps and their sidecars.
-- ---------------------------------------------------------------------------

local function RunSaveWith(name, oldData, inst)
    local captured
    GRIPEMS.Engine = {
        sequences = { [name] = { data = oldData } },
        UpdateSequenceData = function(_, seqName, seqData)
            assertEqual(name, seqName, "UpdateSequenceData sequence name")
            captured = seqData
        end,
    }
    inst.currentSequence = name
    PE:SaveSequence(inst)
    assertTrue(captured ~= nil, "SaveSequence reached UpdateSequenceData for " .. name)
    return captured
end

local SENTINEL = "/cast SENTINEL_MUST_NOT_PERSIST"

local treeOld, treeOrigSteps, treeSaved
do
    treeOld = FixtureData("PopupTreeMode")
    treeOld.versions[1].compiledLabels = { "Lbl1", "Lbl2" }
    treeOrigSteps = DeepCopy(treeOld.versions[1].steps)
    stampLog = {}
    GRIPEMS.Identity = MakeIdentityStub()
    GRIPEMS.SequenceEditor = nil
    treeSaved = RunSaveWith("PopupTreeMode", treeOld, {
        activeVersionIndex = 1,
        isDirty = true,
        workingStepFunction = "Random",
        workingSteps = { "/cast A", SENTINEL, "/cast B" },
        workingActions = DeepCopy(treeOld.versions[1].actions),
    })
end

local flatSaved
do
    local d = FixtureData("PopupFlatMode")
    d.versions[1].actions = nil
    d.versions[1].compiledLabels = { "Lbl1", "Lbl2" }
    stampLog = {}
    GRIPEMS.Identity = MakeIdentityStub()
    flatSaved = RunSaveWith("PopupFlatMode", d, {
        activeVersionIndex = 1,
        isDirty = true,
        workingStepFunction = "Random",
        workingSteps = { "/cast A", SENTINEL, "/cast B" },
        workingActions = nil,
    })
end

local cancelledFor
do
    local d = FixtureData("PopupQuickResign")
    d.versions[1].actions = nil
    stampLog = {}
    GRIPEMS.Identity = MakeIdentityStub()
    GRIPEMS.SequenceEditor = {
        _CancelQuickResign = function(_, n)
            cancelledFor = n
        end,
    }
    RunSaveWith("PopupQuickResign", d, {
        activeVersionIndex = 1,
        isDirty = true,
        workingStepFunction = "Sequential",
        workingSteps = { "/cast A" },
        workingActions = nil,
    })
    GRIPEMS.SequenceEditor = nil
end

test("V6: popup save of a TREE-MODE version does not persist flat step edits", function()
    assertTrue(
        type(treeOld.versions[1].actions) == "table" and #treeOld.versions[1].actions > 0,
        "V6 precondition: the fixture version carries an actions tree"
    )
    assertTrue(not treeOld.versions[1].importBakedSteps, "V6 precondition: the tree is live, not baked")
    local v = treeSaved.versions[1]
    for i = 1, #v.steps do
        assertNotEqual(SENTINEL, v.steps[i], "V6: the working-copy sentinel did not reach step " .. i)
    end
    assertEqual(#treeOrigSteps, #v.steps, "V6: step count came from the stored version, not the working copy")
    for i = 1, #treeOrigSteps do
        assertEqual(treeOrigSteps[i], v.steps[i], "V6: step " .. i .. " came from the stored version")
    end
    assertEqual("Sequential", v.stepFunction, "V6: stepFunction came from the stored version")
end)

test("V7: popup save of a FLAT version still persists the flat step edits (control)", function()
    local v = flatSaved.versions[1]
    assertTrue(v.actions == nil, "V7 precondition: no actions tree on this version")
    assertEqual(3, #v.steps, "V7: all three working steps persisted")
    assertEqual(SENTINEL, v.steps[2], "V7: the edited step reached the saved payload")
    assertEqual("Random", v.stepFunction, "V7: workingStepFunction still wins on a flat version")
end)

local bakedSaved, bakedSrcLabels
do
    local d = FixtureData("PopupBakedImport")
    d.versions[1].importBakedSteps = true
    d.versions[1].compiledLabels = { [2] = "Loop head" }
    bakedSrcLabels = d.versions[1].compiledLabels
    stampLog = {}
    GRIPEMS.Identity = MakeIdentityStub()
    bakedSaved = RunSaveWith("PopupBakedImport", d, {
        activeVersionIndex = 1,
        isDirty = true,
        workingStepFunction = "Sequential",
        workingSteps = { "/cast A", "/cast B" },
        workingActions = DeepCopy(d.versions[1].actions),
    })
end

test("V8: compiledLabels always carry as a FRESH table, baked imports included", function()
    -- Live tree: the downstream recompile would regenerate these anyway, so the
    -- carry is cheap insurance rather than the only copy.
    assertTrue(treeSaved.versions[1].compiledLabels ~= nil, "V8(a): a live tree keeps its compiledLabels")
    -- Baked import: Engine:RecompileSequence and Engine:ActivateSequence both skip
    -- the recompile when importBakedSteps is set, so THIS carry is the only thing
    -- preserving the labels. Engine:BuildExecLabels reads (compiledLabels or
    -- stepLabels), so dropping them silently demotes the version to its stepLabels.
    local baked = bakedSaved.versions[1]
    assertTrue(baked.importBakedSteps == true, "V8 precondition: the probe version is baked")
    assertTrue(type(baked.actions) == "table" and #baked.actions > 0, "V8 precondition: it carries a tree too")
    assertEqual("Loop head", baked.compiledLabels and baked.compiledLabels[2], "V8(b): baked labels carried")
    assertTrue(baked.compiledLabels ~= bakedSrcLabels, "V8(c): the carried table is FRESH, not an alias")
end)

test("V9: a popup save cancels a pending quick re-sign for that sequence", function()
    assertEqual("PopupQuickResign", cancelledFor, "V9: PE:SaveSequence cancelled the pending resign")
end)

local switchClearedUndo = false
do
    local d = FixtureData("PopupSwitchVersion")
    d.versions[2] = { stepFunction = "Sequential", steps = { "/cast V2" } }
    local inst = {
        currentSequence = "PopupSwitchVersion",
        activeVersionIndex = 1,
        isDirty = true,
        workingSteps = { "/cast A" },
        undoStack = {
            Clear = function()
                switchClearedUndo = true
            end,
        },
    }
    GRIPEMS.Engine = { sequences = { PopupSwitchVersion = { data = d } } }
    PE.UpdateSfButtons = noop
    PE.RefreshVersionBar = noop
    PE:SwitchVersion(inst, 2)
    assertEqual(2, inst.activeVersionIndex, "V10 precondition: the switch actually happened")
    assertEqual("/cast V2", inst.workingSteps[1], "V10 precondition: the working copy was replaced")
end

test("V10: switching version clears the popup undo stack", function()
    assertTrue(switchClearedUndo, "V10: PE:SwitchVersion cleared inst.undoStack")
end)

-- V10 supplies a healthy engine, entry and version, so every guard inside
-- PE:SwitchVersion passes and the clear runs no matter which side of those
-- guards the block sits on. Moving the block below them keeps V10 green while
-- restoring the defect on every early-return path. This case forces the entry
-- guard to fire AFTER inst.activeVersionIndex has already been reassigned, the
-- half-switched state in which a stale closure holding the OUTGOING version's
-- step index is exactly what must not survive.
local earlyReturnClearedUndo = false
local earlyReturnIndex, earlyReturnFirstStep
do
    local prevEngine = GRIPEMS.Engine
    local inst = {
        currentSequence = "PopupSwitchEarlyReturn",
        activeVersionIndex = 1,
        isDirty = true,
        workingSteps = { "/cast OUTGOING" },
        undoStack = {
            Clear = function()
                earlyReturnClearedUndo = true
            end,
        },
    }
    -- Empty sequences table: engine.sequences[inst.currentSequence] is nil, so
    -- the call returns at the "not entry or not entry.data" guard.
    GRIPEMS.Engine = { sequences = {} }
    PE:SwitchVersion(inst, 2)
    earlyReturnIndex = inst.activeVersionIndex
    earlyReturnFirstStep = inst.workingSteps[1]
    GRIPEMS.Engine = prevEngine
end

test("V11: switching version clears the undo stack even when the switch returns early", function()
    assertEqual(2, earlyReturnIndex, "V11 precondition: the index was reassigned before the guard")
    assertEqual(
        "/cast OUTGOING",
        earlyReturnFirstStep,
        "V11 precondition: the call returned early, working copy untouched"
    )
    assertTrue(earlyReturnClearedUndo, "V11: PE:SwitchVersion cleared inst.undoStack before the early-return guards")
end)

-- ---------------------------------------------------------------------------
-- Run.
-- ---------------------------------------------------------------------------

local passed = 0
local failed = 0
for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then
        passed = passed + 1
        print("PASS  " .. t.name)
    else
        failed = failed + 1
        print("FAIL  " .. t.name .. " " .. tostring(err))
    end
end
print(string.format("RESULT %d passed, %d failed", passed, failed))
os.exit(failed > 0 and 1 or 0)
