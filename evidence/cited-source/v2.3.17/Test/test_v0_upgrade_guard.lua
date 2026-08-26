-- GRIP-EMS: Headless test for the lazy V0 signature-upgrade guard
--
-- Created:    2026-07-30
-- Updated:    2026-07-30
-- Patch: 12.0.7.68275 Midnight (Retail LIVE)
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
-- Cases:
--   V1  unsigned inbound payload: no identityHash bound, no signature minted,
--       algorithm left at ALG_V0_DJB2, byline untouched
--   V2  genuinely legacy V0 (non-empty originalSignature): still upgrades to
--       ALG_V1_SHA256 (no-regression control, green before and after the fix)
--   V3  the two shapes DIVERGE on all three signature fields. Before the fix
--       both upgraded identically, so this case is the one that goes red.

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
