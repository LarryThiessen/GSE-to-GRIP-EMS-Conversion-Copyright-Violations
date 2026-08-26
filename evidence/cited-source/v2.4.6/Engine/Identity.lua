-- GRIP-EMS: Authorship Identity Module (Phase A foundation)
-- Created: 2026-05-09
-- Updated: 2026-08-17
-- Patch: 12.1.0.69299 Midnight (Retail LIVE)
--
-- Phase A: identity resolution + djb2 placeholder hash.
-- Phase B: replaces _placeholderHash with LibHash-1.0 sha256 keyed by
-- the same identity-resolution path.

local ADDON_NAME, GRIPEMS = ...

local I = {}
GRIPEMS.Identity = I

local PREFIX_BATTLETAG = "battletag:"
local PREFIX_NAMEREALM = "namerealm:"

-- djb2 hash, 32-bit, returned as 8-char lowercase hex.
-- Phase A placeholder; retained in Phase B as the fallback path for
-- installs missing LibHash-1.0 (and for verifying legacy ALG_V0_DJB2
-- sequences stamped before the SHA-256 upgrade).
local function _placeholderHash(s)
    local hash = 5381
    for i = 1, #s do
        hash = (hash * 33 + s:byte(i)) % 0x100000000
    end
    return string.format("%08x", hash)
end

local _LH = nil
local function _GetLibHash()
    if not _LH then
        _LH = LibStub and LibStub("LibHash-1.0", true)
    end
    return _LH
end

-- SHA-256 hash of input. Returns 64-char lowercase hex.
-- Falls back to djb2 placeholder if LibHash unavailable.
local function _hash(s)
    local lh = _GetLibHash()
    if lh and lh.sha256 then
        return lh.sha256(s)
    end
    -- Fallback path; should only fire in misconfigured installs.
    return _placeholderHash(s)
end

function I:HashBattleTag(battleTag)
    return _hash(PREFIX_BATTLETAG .. (battleTag or ""))
end

function I:HashNameRealm(name, realm)
    return _hash(PREFIX_NAMEREALM .. (name or "") .. "@" .. (realm or ""))
end

-- Returns identity tuple for the local player.
-- {displayName, identityHash, battleTag, realm, source}
-- source = "battletag" (BNet present) or "name-realm" (offline fallback)
function I:GetCurrent()
    local _, battleTag = BNGetInfo()
    local realm = GetRealmName() or ""
    local unitName = UnitName("player") or ""

    if battleTag and battleTag ~= "" then
        return {
            displayName = unitName,
            identityHash = I:HashBattleTag(battleTag),
            battleTag = battleTag,
            realm = realm,
            source = "battletag",
        }
    end
    return {
        displayName = unitName,
        identityHash = I:HashNameRealm(unitName, realm),
        battleTag = nil,
        realm = realm,
        source = "name-realm",
    }
end

-- Stable canonical serialization for hashing. Sorts table keys + emits
-- typed scalar form. NOT for export (that is AceSerializer); this is
-- hash-input only.
local function _canonValue(v)
    local t = type(v)
    if t == "nil" then
        return "n:"
    end
    if t == "boolean" then
        return "b:" .. tostring(v)
    end
    if t == "number" then
        return "n:" .. tostring(v)
    end
    if t == "string" then
        local s = v:gsub("\\", "\\\\"):gsub('"', '\\"')
        return 's:"' .. s .. '"'
    end
    if t == "table" then
        local keys = {}
        for k in pairs(v) do
            keys[#keys + 1] = tostring(k)
        end
        table.sort(keys)
        local parts = {}
        for _, k in ipairs(keys) do
            parts[#parts + 1] = k .. "=" .. _canonValue(v[k])
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return "?:"
end

-- ALG_V2 canonical serializer. Identical to _canonValue EXCEPT the table branch
-- looks values up by the ORIGINAL key, not the stringified key, so numeric /
-- array keys (versions, step arrays, action trees) are actually walked. The V1
-- string-key lookup silently dropped every array value to nil -- which is why the
-- V1 signature never covered macro content.
local function _canonValueV2(v)
    local t = type(v)
    if t == "nil" then
        return "n:"
    end
    if t == "boolean" then
        return "b:" .. tostring(v)
    end
    if t == "number" then
        return "n:" .. tostring(v)
    end
    if t == "string" then
        local s = v:gsub("\\", "\\\\"):gsub('"', '\\"')
        return 's:"' .. s .. '"'
    end
    if t == "table" then
        local keys = {}
        local km = {}
        for k in pairs(v) do
            local ks = tostring(k)
            keys[#keys + 1] = ks
            km[ks] = k
        end
        table.sort(keys)
        local parts = {}
        for _, ks in ipairs(keys) do
            parts[#parts + 1] = ks .. "=" .. _canonValueV2(v[km[ks]])
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return "?:"
end

-- Walk only content fields (NOT provenance) for hash input. Provenance
-- fields participate in the signature payload via I:SignSequence, not
-- via canon.
local CONTENT_FIELDS = {
    "versions",
    "contextOverrides",
    "holdMode",
    "keybindOverrides",
    "description",
    "specID",
    "classID",
    "icon",
    "url",
    "talentString",
}

function I:CanonicalSerialize(seq)
    local parts = {}
    for _, key in ipairs(CONTENT_FIELDS) do
        parts[#parts + 1] = key .. "=" .. _canonValue(seq[key])
    end
    return table.concat(parts, "|")
end

function I:SignSequence(seq)
    local canon = I:CanonicalSerialize(seq)
    local payload = canon
        .. "||"
        .. (seq.originalAuthor or "")
        .. "||"
        .. (seq.originalAuthorIdentity or "")
        .. "||"
        .. tostring(seq.originalCreatedAt or 0)
    return _hash(payload)
end

-- ALG_V2: locale-independent normalization of a sequence's executable content.
-- Mirrors GRIPExport.PrepareExportVersions' reuse-tagged-else-toIDs transform so
-- the SIGNED form equals the TRANSPORTED form (a headless parity test guards drift).
-- Hashing the spell-ID form keeps the signature stable across client locales.
local function _normalizeVersionsToIDs(seq)
    local out = {}
    if type(seq.versions) ~= "table" then
        return out
    end
    local SC = GRIPEMS.SpellCache
    local D = GRIPEMS.Defaults
    local classID = seq.classID
    for vi, ver in ipairs(seq.versions) do
        local v = {
            stepFunction = ver.stepFunction,
            resetOnCombat = ver.resetOnCombat,
            resetOnTarget = ver.resetOnTarget,
            resetTimer = ver.resetTimer,
            stepLabels = ver.stepLabels,
        }
        if type(ver.steps) == "table" then
            local s = {}
            for si, step in ipairs(ver.steps) do
                if type(step) == "string" then
                    s[si] = (ver.taggedSteps and ver.taggedSteps[si])
                        or (SC and SC.TranslateMacrotext and SC:TranslateMacrotext(step, "toIDs", { classID = classID }))
                        or step
                else
                    s[si] = step
                end
            end
            v.steps = s
        end
        if type(ver.keyPress) == "string" then
            v.keyPress = ver.taggedKeyPress
                or (SC and SC.TranslateMacrotext and SC:TranslateMacrotext(ver.keyPress, "toIDs", { classID = classID }))
                or ver.keyPress
        end
        if type(ver.keyRelease) == "string" then
            v.keyRelease = ver.taggedKeyRelease
                or (SC and SC.TranslateMacrotext and SC:TranslateMacrotext(
                    ver.keyRelease,
                    "toIDs",
                    { classID = classID }
                ))
                or ver.keyRelease
        end
        if ver.actions then
            local a = (D and D.DeepCopyActions and D.DeepCopyActions(ver.actions)) or ver.actions
            if SC and SC.TagActionsToIDs then
                SC:TagActionsToIDs(a, { classID = classID })
            end
            v.actions = a
        end
        out[vi] = v
    end
    return out
end

-- ALG_V2 content projection: normalized executable content (versions in spell-ID
-- form) plus the scalar content fields V1 covered. With the _canonValueV2 numeric-
-- key fix, the versions array is now actually hashed.
function I:_CanonicalContentV2(seq)
    -- Normalize the nil-able content fields EXACTLY as GE.Export does (icon ->
    -- QUESTION_MARK_ICON, description -> "", contextOverrides -> {}) so the SIGNED
    -- form equals the TRANSPORTED form. Without this, a sequence with a nil icon /
    -- description / contextOverrides at sign-time false-flags "tampered" after an
    -- export/import round-trip (the wire defaults differ from the raw nil).
    --
    -- holdMode / keybindOverrides are intentionally EXCLUDED here (V1's
    -- CONTENT_FIELDS still lists them, but cannot change without invalidating
    -- legacy V1 signatures). Neither is portable content: hold mode is a
    -- per-character / per-spec preference stored in GRIP_EMS_CHAR.tempoHoldMode
    -- keyed by sequence NAME (never written to the sequence object), and
    -- keybindOverrides is unused. Neither is transported, so signing them would
    -- false-flag "tampered" on any sequence that set one. V2 covers only the
    -- content that actually travels on the wire.
    local D = GRIPEMS.Defaults
    return {
        versions = _normalizeVersionsToIDs(seq),
        contextOverrides = seq.contextOverrides or {},
        description = seq.description or "",
        specID = seq.specID,
        classID = seq.classID,
        icon = seq.icon or (D and D.QUESTION_MARK_ICON),
        url = seq.url,
        talentString = seq.talentString,
    }
end

function I:SignSequenceV2(seq)
    local canon = _canonValueV2(I:_CanonicalContentV2(seq))
    local payload = canon
        .. "||"
        .. (seq.originalAuthor or "")
        .. "||"
        .. (seq.originalAuthorIdentity or "")
        .. "||"
        .. tostring(seq.originalCreatedAt or 0)
    return _hash(payload)
end

-- Returns one of: "verified", "modified", "tampered", "unknown",
-- "damaged", "forked". Dispatches on seq.signatureAlgorithm.
function I:VerifySequence(seq)
    if not seq.originalAuthor or seq.originalAuthor == "" then
        return "unknown"
    end
    if not seq.originalSignature or seq.originalSignature == "" then
        if
            seq.provenanceSource == "no-provenance"
            or seq.provenanceSource == "gse-legacy"
            or seq.provenanceSource == "offline-fallback"
            or seq.provenanceSource == "forge-import"
        then
            return "unknown"
        end
        return "damaged"
    end
    -- Phase C: signature compare BEFORE forkedFrom branch so a forked
    -- sequence with tampered content surfaces as "tampered" (not masked
    -- under the "forked" badge). The receiver must see content tampering
    -- regardless of whether the sequence was forked.
    -- Unknown future scheme: a signatureAlgorithm this client cannot reproduce
    -- degrades to "unknown" (grey), never "tampered" (red).
    local algo = seq.signatureAlgorithm
    if algo and algo ~= "" and algo ~= "ALG_V0_DJB2" and algo ~= "ALG_V1_SHA256" and algo ~= "ALG_V2_SHA256" then
        return "unknown"
    end
    -- Dual-sign dispatch: prefer the V2 content signature when present (covers the
    -- full locale-normalized macro content); fall back to the legacy V1 signature.
    local expected, stored
    if seq.originalSignatureV2 and seq.originalSignatureV2 ~= "" then
        expected = I:SignSequenceV2(seq)
        stored = seq.originalSignatureV2
    else
        expected = I:SignSequence(seq)
        stored = seq.originalSignature
    end
    if expected ~= stored then
        return "tampered"
    end
    if seq.forkedFrom then
        return "forked"
    end
    if seq.modifierChain and #seq.modifierChain > 1 then
        return "modified"
    end
    return "verified"
end

-- Stamp original-author trio onto a brand-new sequence (first save only).
-- Returns true if stamped, false if seq already had originalAuthor set.
--
-- v2.1.6: callers may pass an explicit chosenDisplayName from the author
-- dropdown -- the pseudonym, the current character's name, or any other
-- character on this BattleNet account. The identity hash and provenance
-- source still derive from the active BattleTag, so the cryptographic
-- signature remains tied to the BNet account regardless of which display
-- name the user picks. A nil / empty chosenDisplayName falls back to the
-- current character name, preserving the pre-v2.1.6 default for callers
-- like StampForked that have no picker UI.
function I:StampOriginal(seq, chosenDisplayName)
    if seq.originalAuthor and seq.originalAuthor ~= "" then
        return false
    end
    local me = I:GetCurrent()
    -- v2.1.6 Phase 1.5: validate the chosen name. If the caller passed
    -- something not in GetAuthorOptions (or nothing at all), fall back
    -- to the privacy-mode default. This closes the data-layer hole the
    -- picker dropdown left open AND extends pseudonym-on-new to the
    -- fork path (StampForked passes nil chosenDisplayName).
    local displayName = chosenDisplayName
    if displayName and displayName ~= "" then
        if not I:IsValidAuthorChoice(displayName) then
            displayName = nil
        end
    else
        displayName = nil
    end
    if not displayName then
        local default = I:GetDefaultAuthorChoice(seq.privacyMode)
        if default and default ~= "" then
            displayName = default
        end
    end
    if not displayName or displayName == "" then
        displayName = me.displayName
    end
    -- Look up the realm for the chosen name. Pseudonym entries return
    -- nil (no realm) -- fall back to me.realm so originalAuthorRealm
    -- is always populated. Alt characters from a different realm get
    -- THEIR realm stamped, not the editing character's.
    local chosenRealm = I:GetAuthorChoiceRealm(displayName)
    if not chosenRealm or chosenRealm == "" then
        chosenRealm = me.realm
    end
    seq.originalAuthor = displayName
    seq.originalAuthorIdentity = me.identityHash
    seq.originalAuthorRealm = chosenRealm
    seq.originalAuthorBattleTag = me.battleTag
    seq.originalCreatedAt = time()
    seq.provenanceSource = me.source == "battletag" and "native" or "offline-fallback"
    seq.modifierChain = seq.modifierChain or {}
    table.insert(seq.modifierChain, {
        name = displayName,
        identity = me.identityHash,
        realm = chosenRealm,
        at = time(),
        kind = "created",
    })
    I:StampLastModified(seq, me, displayName)
    seq.signatureAlgorithm = "ALG_V2_SHA256"
    seq.originalSignature = I:SignSequence(seq)
    seq.originalSignatureV2 = I:SignSequenceV2(seq)
    seq.currentSignature = seq.originalSignature
    seq.currentSignatureV2 = seq.originalSignatureV2
    return true
end

-- Stamp a forked sequence: record the source's lineage into forkedFrom,
-- reset the new fork's original* fields, then call StampOriginal so the
-- current user becomes the new Original Author with a fresh signature.
-- The first modifierChain entry is rewritten as kind="forked-from" so the
-- chain begins at the fork point. Idempotent guard: refuses to re-stamp
-- a sequence that already has forkedFrom set (would lose source lineage).
-- Returns true on first stamp, false if the sequence was already forked.
function I:StampForked(newSeq, sourceSeq)
    if newSeq.forkedFrom then
        return false
    end
    newSeq.forkedFrom = {
        originalAuthor = sourceSeq.originalAuthor or "",
        originalAuthorIdentity = sourceSeq.originalAuthorIdentity or "",
        originalAuthorRealm = sourceSeq.originalAuthorRealm or "",
        originalCreatedAt = sourceSeq.originalCreatedAt or 0,
        originalSignature = sourceSeq.originalSignature or "",
        forkedAt = time(),
    }
    -- Phase C polish: build the multi-hop fork chain. Each fork prepends the
    -- source's identity to the chain. forkedFromChain is the FULL ancestry
    -- from immediate parent (entry [1]) outward to the root (entry [N]).
    -- Receivers can render the lineage as "P1 <- P2 <- ... <- root" by
    -- walking this list. forkedFrom stays the immediate parent for back-
    -- compat / convenience access.
    newSeq.forkedFromChain = { newSeq.forkedFrom }
    if sourceSeq.forkedFromChain and #sourceSeq.forkedFromChain > 0 then
        for i = 1, #sourceSeq.forkedFromChain do
            table.insert(newSeq.forkedFromChain, sourceSeq.forkedFromChain[i])
        end
    elseif sourceSeq.forkedFrom then
        -- Source is a pre-polish v2.1.0 fork without forkedFromChain.
        -- Inherit the legacy single-parent pointer as the second chain entry
        -- so the chain is at least 2 deep (immediate + grand-parent).
        table.insert(newSeq.forkedFromChain, sourceSeq.forkedFrom)
    end
    newSeq.originalAuthor = ""
    newSeq.originalAuthorIdentity = ""
    newSeq.originalAuthorRealm = ""
    newSeq.originalAuthorBattleTag = nil
    newSeq.originalCreatedAt = 0
    newSeq.originalSignature = ""
    newSeq.originalSignatureV2 = ""
    newSeq.currentSignature = ""
    newSeq.currentSignatureV2 = ""
    newSeq.modifierChain = {}
    newSeq.signatureAlgorithm = "ALG_V2_SHA256"
    I:StampOriginal(newSeq)
    if newSeq.modifierChain[1] then
        newSeq.modifierChain[1].kind = "forked-from"
    end
    return true
end

-- Stamp last-modifier fields. Called on every save (including first).
-- v2.1.6: accepts an optional chosenDisplayName so StampOriginal can forward
-- the picker's selection on first save; this keeps the "Created by X" and
-- "Last modified by X" rows aligned on a brand-new sequence. Subsequent
-- saves leave chosenDisplayName nil so lastModifier reverts to the actual
-- editing character (which is the honest signal post-creation).
function I:StampLastModified(seq, me, chosenDisplayName)
    me = me or I:GetCurrent()
    seq.lastModifier = chosenDisplayName or me.displayName
    seq.lastModifierIdentity = me.identityHash
    seq.lastModifierRealm = me.realm
    seq.lastModifiedAt = time()
end

-- ALG_V2 owned re-stamp: when the local user is the sequence's ORIGINAL author,
-- (re)sign the V2 content signature over the CURRENT content and mark
-- ALG_V2_SHA256. A non-owner cannot re-stamp (identity differs), so third-party
-- content changes still surface as "tampered". Also lazily upgrades a legacy
-- V1-only owned sequence to V2 on its next save. Returns true if it stamped.
function I:EnsureOwnedV2Signature(seq)
    if not seq or not seq.originalAuthor or seq.originalAuthor == "" then
        return false
    end
    local me = I:GetCurrent()
    if not me or not me.identityHash or seq.originalAuthorIdentity ~= me.identityHash then
        return false
    end
    seq.signatureAlgorithm = "ALG_V2_SHA256"
    seq.originalSignatureV2 = I:SignSequenceV2(seq)
    return true
end

-- Append a modifier-chain entry on every non-first save.
function I:AppendModifierEntry(seq, kind)
    local me = I:GetCurrent()
    seq.modifierChain = seq.modifierChain or {}
    table.insert(seq.modifierChain, {
        name = me.displayName,
        identity = me.identityHash,
        realm = me.realm,
        at = time(),
        kind = kind or "edited",
    })
    I:StampLastModified(seq, me)
    seq.currentSignature = I:SignSequence(seq)
    seq.currentSignatureV2 = I:SignSequenceV2(seq)
end

-- Phase D: deep-copy a Lua value. Sequence-level depth is enough -- the
-- provenance objects we touch are tables-of-tables-of-scalars. Used by
-- BuildExportPayload so the local sequence in GRIPEMS.Engine.sequences is
-- never mutated by the export-side scrub.
function I:_DeepCopy(v)
    if type(v) ~= "table" then
        return v
    end
    local t = {}
    for k, val in pairs(v) do
        t[k] = I:_DeepCopy(val)
    end
    return t
end

-- Phase D: walk modifierChain + forkedFromChain + lastModifier* +
-- originalAuthor* + forkedFrom fields and replace entries whose identity
-- matches matchHash with (newName, newHash). Foreign authors are left
-- untouched -- only the local user's entries get scrubbed.
function I:_ScrubIdentity(payload, matchHash, newName, newHash)
    if not payload then
        return
    end
    if payload.originalAuthorIdentity == matchHash then
        payload.originalAuthor = newName
        payload.originalAuthorIdentity = newHash
    end
    if payload.lastModifierIdentity == matchHash then
        payload.lastModifier = newName
        payload.lastModifierIdentity = newHash
    end
    if payload.modifierChain then
        for _, entry in ipairs(payload.modifierChain) do
            if entry.identity == matchHash then
                entry.name = newName
                entry.identity = newHash
            end
        end
    end
    if payload.forkedFromChain then
        for _, ancestor in ipairs(payload.forkedFromChain) do
            if ancestor.originalAuthorIdentity == matchHash then
                ancestor.originalAuthor = newName
                ancestor.originalAuthorIdentity = newHash
            end
        end
    end
    if payload.forkedFrom and payload.forkedFrom.originalAuthorIdentity == matchHash then
        payload.forkedFrom.originalAuthor = newName
        payload.forkedFrom.originalAuthorIdentity = newHash
    end
    -- The BattleTag is stored locally for offline-fallback hashing only and
    -- must never leave the boundary, regardless of mode.
    payload.originalAuthorBattleTag = nil
end

-- Phase D / v2.2.0: 64-char lowercase hex salt for private-mode identity
-- replacement. SHA-256 (_hash) over per-call entropy (time + GetTime +
-- fresh table address) so two private exports from the same user
-- produce different, unlinkable salts. The hash itself is cryptographically
-- strong; the security guarantee depends on the entropy inputs not being
-- guessable. Private mode trades author-side unlinkability for forgery-
-- resistance; the originalSignature still verifies independently.
function I:_GenerateAnonymousSalt()
    -- v2.2.0 L87-FU3: math.randomseed is nil-callable in WoW 12.0 Midnight
    -- (single-site removal; no replacement API in the Blizzard sandbox).
    -- Build the salt from three entropy sources, hashed for diffusion:
    --   1) time()         -- second-resolution wall clock
    --   2) GetTime()      -- millisecond-resolution session uptime
    --   3) tostring({})   -- fresh table address per call
    -- Even two calls within the same second produce different salts
    -- (GetTime advances and the table address is fresh). _hash diffuses
    -- the bits so the output is unpredictable across sessions, matching
    -- the unlinkability guarantee the original randomseed-based version
    -- was trying to provide.
    local entropy = string.format("%d:%s:%s", time() or 0, tostring(GetTime and GetTime()), tostring({}))
    return _hash(entropy)
end

-- Phase D: returns a deep-copied sequence with the local user's identity
-- entries scrubbed per privacyMode. Foreign authors (originalAuthor of an
-- ancestor in forkedFromChain, modifierChain entries from OTHER users)
-- stay visible -- the scrub matches on identityHash and only rewrites the
-- LOCAL user's entries.
--
-- mode: "public" / "pseudonymous" / "private" / nil
--   nil reads seq.privacyMode then config.privacyDefault then "public" as
--   the final fallback (matching D.PRIVACY_MODE_DEFAULT).
function I:BuildExportPayload(seq, mode)
    if not seq then
        return seq
    end
    mode = mode or seq.privacyMode
    if not mode then
        local cfg = GRIP_EMS_DB and GRIP_EMS_DB.config
        mode = (cfg and cfg.privacyDefault) or (GRIPEMS.Defaults and GRIPEMS.Defaults.PRIVACY_MODE_DEFAULT) or "public"
    end
    -- Deep copy so we never mutate the local sequence
    local payload = I:_DeepCopy(seq)
    if mode == "public" then
        return payload
    end
    local me = I:GetCurrent()
    if not me or not me.identityHash or me.identityHash == "" then
        return payload
    end
    if mode == "pseudonymous" then
        local pseudonym = (GRIP_EMS_DB and GRIP_EMS_DB.config and GRIP_EMS_DB.config.pseudonym)
            or (GRIPEMS.Defaults and GRIPEMS.Defaults.PRIVACY_PSEUDONYM_DEFAULT)
            or "Anonymous"
        -- Pseudonymous keeps the SAME identityHash so receivers can see
        -- "same author" linkage across multiple pseudonymous exports.
        I:_ScrubIdentity(payload, me.identityHash, pseudonym, me.identityHash)
        return payload
    end
    if mode == "private" then
        -- Private uses a per-export random salt so two private exports are
        -- NOT linkable. Foreign authors (Gaupanda in your forkedFromChain)
        -- remain unchanged.
        local salt = I:_GenerateAnonymousSalt()
        I:_ScrubIdentity(payload, me.identityHash, "Anonymous", salt)
        return payload
    end
    return payload
end

-- Phase D: returns a displayName that's safe to show in UI when the user
-- has multiple sequences from authors with the same name but different
-- identityHashes. Walks all sequences in the local library; if more than
-- one author uses the same displayName but a different identityHash, this
-- returns "<name>#<8-hex>" instead of the bare name. Best-effort -- a
-- collision in someone else's library is invisible here, but the per-user
-- collision is the common case (e.g. multiple "Anonymous" pseudonymous
-- exports landing in the same library).
function I:ResolveDisplayName(displayName, identityHash)
    if not displayName or displayName == "" then
        return "?"
    end
    if not identityHash or identityHash == "" then
        return displayName
    end
    local engine = GRIPEMS.Engine
    if not engine or not engine.sequences then
        return displayName
    end
    local seen = {}
    for _, entry in pairs(engine.sequences) do
        local d = entry and entry.data
        if d and d.originalAuthor and d.originalAuthorIdentity and d.originalAuthorIdentity ~= "" then
            local n = d.originalAuthor
            if seen[n] and seen[n] ~= d.originalAuthorIdentity then
                if n == displayName then
                    return string.format("%s#%s", displayName, identityHash:sub(1, 8))
                end
            else
                seen[n] = d.originalAuthorIdentity
            end
        end
    end
    return displayName
end

-- v2.1.6 author picker support. The SequenceEditor exposes a dropdown of
-- valid attribution names (pseudonym + characters on this BattleNet
-- account) so the user can stamp a brand-new sequence as their pseudonym
-- without waiting for the export-time scrub to rewrite it. The dropdown
-- occupies the EXACT slot the disabled Author EditBox used to fill; the
-- EditBox now only renders post-lock state. Identity hashes are still
-- derived from the active BattleTag (or the name-realm fallback), so the
-- cryptographic signature is unchanged regardless of which displayName
-- the user picks from the dropdown.

local function _GetConfig()
    if not GRIP_EMS_DB then
        return nil
    end
    GRIP_EMS_DB.config = GRIP_EMS_DB.config or {}
    return GRIP_EMS_DB.config
end

-- Returns the SavedVariables-backed character roster, creating an empty
-- list on first access. Each entry is { name, realm, lastSeen }.
function I:_GetRosterTable()
    local cfg = _GetConfig()
    if not cfg then
        return {}
    end
    cfg.characterRoster = cfg.characterRoster or {}
    return cfg.characterRoster
end

-- Record the current character into the account-scoped roster. Dedupes by
-- (name, realm); refreshes lastSeen on an existing entry rather than
-- inserting a duplicate. Called once at PLAYER_LOGIN.
function I:RegisterCurrentCharacter()
    local me = I:GetCurrent()
    if not me or not me.displayName or me.displayName == "" then
        return
    end
    local roster = I:_GetRosterTable()
    local now = time()
    for _, entry in ipairs(roster) do
        if entry.name == me.displayName and entry.realm == me.realm then
            entry.lastSeen = now
            return
        end
    end
    table.insert(roster, { name = me.displayName, realm = me.realm, lastSeen = now })
end

-- Returns the roster as a NEW list sorted by lastSeen descending (most
-- recently logged-in character first). The caller can mutate the copy
-- without disturbing SavedVariables.
function I:GetAccountRoster()
    local roster = I:_GetRosterTable()
    local copy = {}
    for i = 1, #roster do
        copy[i] = roster[i]
    end
    table.sort(copy, function(a, b)
        return (a.lastSeen or 0) > (b.lastSeen or 0)
    end)
    return copy
end

-- Returns the ordered author-dropdown options for the local user:
--   { pseudonym (if configured and non-empty),
--     current character,
--     other known characters from the roster }
-- Each entry is { value, kind, realm } where kind is "pseudonym" /
-- "current" / "alt". "realm" is set for current + alt entries so the
-- caller can disambiguate same-name characters across realms. Dedupes
-- by value: pseudonym wins, then current, then alts. The SequenceEditor
-- formats these into user-facing labels via locale strings so this
-- module stays free of UI / locale concerns.
function I:GetAuthorOptions()
    local options = {}
    local seen = {}
    local me = I:GetCurrent()
    local cfg = _GetConfig()
    local pseudonym = cfg and cfg.pseudonym
    if pseudonym and pseudonym ~= "" then
        options[#options + 1] = { value = pseudonym, kind = "pseudonym" }
        seen[pseudonym] = true
    end
    if me and me.displayName and me.displayName ~= "" and not seen[me.displayName] then
        options[#options + 1] = {
            value = me.displayName,
            kind = "current",
            realm = me.realm,
        }
        seen[me.displayName] = true
    end
    local roster = I:GetAccountRoster()
    for _, entry in ipairs(roster) do
        local n = entry and entry.name
        if n and n ~= "" and not seen[n] then
            options[#options + 1] = {
                value = n,
                kind = "alt",
                realm = entry.realm,
            }
            seen[n] = true
        end
    end
    return options
end

-- Default selection for the author dropdown when a brand-new sequence is
-- being authored. Returns the configured pseudonym when privacyMode is
-- "pseudonymous" AND the pseudonym is set; otherwise the current character
-- name. This is what makes the Discord-reported MFDOOM scenario work:
-- pseudonym "MFDOOM" + privacy default "pseudonymous" stamps "MFDOOM" at
-- creation instead of waiting for the export-time rewrite.
function I:GetDefaultAuthorChoice(privacyMode)
    local cfg = _GetConfig()
    -- v2.1.6 Phase 1.6: when privacyMode is nil/empty (the fork
    -- integration path via DuplicateSequence -> StampForked ->
    -- StampOriginal never sets it), fall back to the account-level
    -- config.privacyDefault. This closes the gap where forks ignored
    -- the user's pseudonymous default. Defaults.lua uses the same
    -- fallback chain for new sequences (config.privacyDefault ->
    -- D.PRIVACY_MODE_DEFAULT), so behaviour is now consistent
    -- across New and Fork.
    if not privacyMode or privacyMode == "" then
        privacyMode = (cfg and cfg.privacyDefault) or "public"
    end
    if privacyMode == "pseudonymous" then
        local pseudonym = cfg and cfg.pseudonym
        if pseudonym and pseudonym ~= "" then
            return pseudonym
        end
    end
    local me = I:GetCurrent()
    return (me and me.displayName) or ""
end

-- v2.1.6 Phase 1.5: returns true when displayName is one of the
-- legitimate author labels for the local user (configured pseudonym,
-- current character, or any character on the BattleNet roster). Used
-- by StampOriginal to reject chosenDisplayName values that did not
-- come from GetAuthorOptions. The cryptographic signature already
-- catches post-stamp tampering, but this gate also prevents pre-stamp
-- impersonation from any caller that bypasses the dropdown (e.g. a
-- future Code path, a /run command, or a buggy widget state).
function I:IsValidAuthorChoice(displayName)
    if not displayName or displayName == "" then
        return false
    end
    local opts = I:GetAuthorOptions()
    for _, opt in ipairs(opts) do
        if opt.value == displayName then
            return true
        end
    end
    return false
end

-- Returns the realm field of the matching author option, or nil if no
-- match. Pseudonym entries have no realm; current/alt entries carry
-- their character's realm. Caller uses this to stamp originalAuthorRealm
-- accurately when an alt from a different realm is picked.
function I:GetAuthorChoiceRealm(displayName)
    if not displayName or displayName == "" then
        return nil
    end
    local opts = I:GetAuthorOptions()
    for _, opt in ipairs(opts) do
        if opt.value == displayName then
            return opt.realm
        end
    end
    return nil
end

-- PLAYER_LOGIN registers the local character into the roster on every
-- login, which is how the dropdown picks up alts the user has logged into
-- since installing v2.1.6. Pre-existing characters with sequences but no
-- roster entry appear after their next login -- there's no retroactive
-- scan because Blizzard does not expose a "list every WoW character on
-- this BattleNet account" API; addons can only see the currently
-- logged-in toon.
do
    local f = CreateFrame("Frame")
    f:RegisterEvent("PLAYER_LOGIN")
    f:SetScript("OnEvent", function(_, event)
        if event == "PLAYER_LOGIN" then
            I:RegisterCurrentCharacter()
        end
    end)
end
