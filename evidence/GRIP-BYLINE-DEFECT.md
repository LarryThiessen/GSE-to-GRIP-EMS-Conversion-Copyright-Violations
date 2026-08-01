# GRIP wrote the importing user's identity onto other people's sequences

**Established 2026-08-01.** Every step below is verifiable from files retained in this repository or from GRIP's own public release notes. Nothing here depends on private information.

---

## The short version

Until **v2.3.16** (released 2026-07-30), saving an imported sequence in GRIP-EMS wrote the **importing user's cryptographic identity** into the sequence's original-author record and signed it as theirs. GRIP disclosed this in its own changelog. The code confirms it.

The visible author name was not changed. What changed was the ownership record underneath — so a sequence could display one creator's name while being cryptographically signed to whoever imported it.

---

## 1. GRIP's own disclosure

CurseForge project 1489414, file ID `8537834`, **v2.3.16**, uploaded 2026-07-30. From the published changelog, under *Fixed*:

> **"Saving an imported sequence no longer puts your name on it.** A sequence in the older signature format upgraded itself the first time you saved, and that upgrade wrote your identity into the original-author field. When the import arrived with no signature at all there was nothing to upgrade, but the upgrade ran regardless: **it bound your byline to someone else's sequence and then signed it as yours.** An unsigned import stays unsigned now. Both the main editor and the popup editor were affected."

Two further entries in the same release:

> "An imported sequence that arrived without a provenance field used to show the amber 'Damaged' badge… It reads **'Provenance unknown'** now, which is what it is."

> *Internal:* "A test fixture credited the wrong author. Corrected, and the packager ignores the file that carries the attribution note."

---

## 2. The defect, in the shipped code

**v2.3.5**, `UI/SequenceEditor.lua:4906-4913`:

```lua
else
    -- Legacy ALG_V0_DJB2 -> upgrade lazily on this save.
    if newData.signatureAlgorithm == "ALG_V0_DJB2" then
        local me = Identity:GetCurrent()
        newData.originalAuthorIdentity = me.identityHash
        newData.signatureAlgorithm = "ALG_V1_SHA256"
        newData.originalSignature = Identity:SignSequence(newData)
    end
    Identity:EnsureOwnedV2Signature(newData)
    Identity:AppendModifierEntry(newData, "edited")
end
```

The only condition is the algorithm tag. `newData.signatureAlgorithm` defaults to `"ALG_V0_DJB2"` earlier in the same function (line 4893), so a sequence that arrived with **no signature at all** still satisfied it. The branch then wrote the local user's `identityHash` into `originalAuthorIdentity` and re-signed.

`UI/PopupEditor.lua` carried the same path, matching the changelog's "both the main editor and the popup editor were affected."

---

## 3. Why it reached that branch on imported content

`Import/LegacyImport.lua:870-879`, the GSE-legacy import path:

```lua
seqData.originalAuthor         = seqData.author or "Unknown (GSE legacy)"
seqData.originalAuthorIdentity = ""
seqData.originalSignature      = ""
seqData.provenanceSource       = "gse-legacy"
seqData.signatureAlgorithm     = "ALG_V0_DJB2"
```

`originalAuthor` is populated from whatever name the source file carried, so the **first** branch (which fires only when `originalAuthor == ""`) was skipped. Execution fell to the `else` branch above. The Forge import path at `:100-109` sets the same combination.

---

## 4. What the fix actually changed

**v2.3.16**, same location, one added condition — and a comment describing the problem in their own words:

```lua
else
    -- Legacy ALG_V0_DJB2 -> upgrade lazily on this save. The upgrade
    -- requires an existing V0 signature to migrate: it stamps the
    -- LOCAL user's identityHash into originalAuthorIdentity, so
    -- firing it on an unsigned import would bind a foreign byline to
    -- this account and let EnsureOwnedV2Signature stamp V2 on top.
    -- An unsigned import is deliberately left unsigned rather than
    -- being signed under the local identity.
    local v0Sig = newData.originalSignature
    if newData.signatureAlgorithm == "ALG_V0_DJB2" and v0Sig and v0Sig ~= "" then
```

**Corroborating checks:**

- `Engine/Identity.lua` is **byte-identical** between v2.3.5 and v2.3.16 — 862 lines, same line numbers. The defect was never in the signing function, only in the call-site gate. That matches how the changelog describes it.
- `Test/test_v0_upgrade_guard.lua` is **new in v2.3.16**, matching the release note's "one proving the signature upgrade refuses an unsigned import."
- `EnsureOwnedV2Signature` (`Identity.lua:483-494`) has its own ownership gate: it re-signs only when `seq.originalAuthorIdentity == me.identityHash`. The old bug worked *because* the V0 upgrade wrote that value in first, making the check pass a line later. Blocking the upgrade breaks the whole chain — which is why one condition was sufficient.

---

## 5. How stripped content reached this path

The LazyGrip Workshop converter removes the GSE.Tools ownership fields. Comparing the two files retained at `lazygrip-webtool/`:

| Field | `02_thirdparty_BEFORE_gse.json` | `03_thirdparty_AFTER_grip.json` |
|---|---|---|
| `PlatformID` | present | **absent** |
| `Checksum` | present | **absent** |
| `HelpURL` | present | **absent** |
| any signature field | present | **none** |

So: the converter strips the ownership identifiers server-side → GRIP's importer records the result as unsigned → saving it stamped the importer as cryptographic owner.

---

## 6. What this establishes, stated precisely

**Established.** In GRIP releases up to and including v2.3.5, saving an imported sequence that arrived unsigned wrote the importing user's `identityHash` into `originalAuthorIdentity` and signed the sequence under that identity. This is disclosed by the developer and confirmed in the shipped code.

**Established.** The visible `originalAuthor` string was **not** overwritten by this path — it carried through from the source file. The change was to the identity and signature fields. A sequence could therefore display the original creator's name while being cryptographically owned by the importer. Anyone testing this and seeing the name unchanged should not conclude the claim is wrong.

**Established.** It is fixed as of v2.3.16 (2026-07-30), by requiring a pre-existing signature before the upgrade runs.

**NOT established, and not claimed here:**

- That this was deliberate. It is presented as a bug, it was self-disclosed, and nothing in the code distinguishes a defect from a design choice.
- That it was ever applied to this rights holder's sequences specifically. The mechanism is general; no instance involving SLG-Sequences is evidenced in this document.
- That the fix is retroactive. It prevents new occurrences; it does not alter records already written.

**Unaffected by the fix:** the LazyGrip converter still removes `PlatformID`, `Checksum` and `HelpURL` server-side. That conduct is separate from the addon, is not addressed by an addon patch, and is documented in `../grip-lazygrip-webtool-exhibit.md`.

---

## Reproduce

```
# the defect and the fix, side by side
unzip -p GRIP-EMS-v2.3.5.zip  '*UI/SequenceEditor.lua' | sed -n '4906,4913p'
unzip -p GRIP-EMS-v2.3.16.zip '*UI/SequenceEditor.lua' | sed -n '5118,5132p'

# the import defaults that put content on that path
unzip -p GRIP-EMS-v2.3.5.zip '*Import/LegacyImport.lua' | sed -n '870,879p'

# the guard test that is new in 2.3.16
unzip -l GRIP-EMS-v2.3.16.zip | grep test_v0_upgrade_guard
unzip -l GRIP-EMS-v2.3.5.zip  | grep test_v0_upgrade_guard   # absent
```

Archives and hashes: `SHA256SUMS.txt` and `PROVENANCE.md` in this directory.
Changelog source: CurseForge project 1489414, file `8537834`.
