# Cited source files — GRIP-EMS v1.0.4 through v2.4.7

Every source file that a `FILE:LINE` citation anywhere in this package resolves into, extracted
**unmodified** from the official release archives, at the **same relative path** the citations use.

```
cited-source/<version>/<original/relative/path.lua>
```

117 files across eight releases. Line numbers match the originals exactly, so a citation such as
`Import/LegacyImport.lua:738-739` (v2.3.16) resolves with:

```bash
sed -n '738,739p' cited-source/v2.3.16/Import/LegacyImport.lua
```

## Why these are here rather than the full packages

`PROVENANCE.md` states the rule this package held itself to: a full installable archive is
justified only while a third party can independently re-download the same file from a
distribution channel and confirm byte-identity. On **2026-08-26** that ceased to be true for
these eight releases — CurseForge, Wago Addons and WoWInterface each now serve only the current
release, v2.4.8. CurseForge purged its pre-v2.4.8 files when it actioned this claim on 2026-08-20.

The addon's developer, who holds an All-Rights-Reserved copyright in it, asked that the eight full
packages be withdrawn and did not object to the cited files being kept. He did not ask for any
analysis, exhibit, correspondence, finding or quotation to be removed, and none has been. The full
2026-08-26 addendum in `PROVENANCE.md` records the request and what was verified before acting.

**v2.4.8 is not in this directory.** It is still published on all three platforms, so it remains
archived in full as `evidence/GRIP-EMS-v2.4.8.zip`, hashed in `SHA256SUMS.txt`, and can be
re-downloaded and compared by anyone.

## Coverage

| Version | Files | Note |
|---|---|---|
| v1.0.4  |  9 | `Import/GSEMigrate.lua` — the pre-rename name of `LegacyMigrate.lua` |
| v1.9.1  | 13 | |
| v2.3.5  | 15 | the byline defect, `UI/SequenceEditor.lua:4906-4913` |
| v2.3.16 | 16 | the byline guard and `Test/test_v0_upgrade_guard.lua`, both new here |
| v2.3.17 | 16 | do-not-share refusal introduced |
| v2.3.18 | 16 | |
| v2.4.6  | 16 | |
| v2.4.7  | 16 | |

**Line numbers drift between releases**, which is why every version is kept separately rather than
one representative copy. `importMeta.sourceChecksum` sits at line 372 in v1.9.1 and line 844 in
v2.4.7. Always read a citation against the version it names.

## Verifying these are genuine

These files are extracts, so they carry no hash of their own in `SHA256SUMS.txt` — the hashes
there are of the complete archives they came from. Anyone holding one of those archives, including
the developer, CurseForge or Wago, can confirm both the archive hash and that these extracts match
it byte for byte:

```bash
sha256sum GRIP-EMS-v2.3.16.zip                     # compare to SHA256SUMS.txt
unzip -p GRIP-EMS-v2.3.16.zip 'GRIP-EMS/Import/LegacyImport.lua' \
  | diff - cited-source/v2.3.16/Import/LegacyImport.lua && echo "identical"
```

If you are reviewing this claim and need a complete package for a version no longer published,
ask the rights holder — all eight are retained unmodified on his own machine.

## Licence

These files are the copyrighted work of Sataana (MrSataana / JesperLive), All Rights Reserved,
reproduced here **solely as the cited evidence** for the copyright claim documented in this
repository, in the quantity necessary to make each citation checkable. They are not offered as a
download of the addon, are not installable, and no licence to them is granted or implied.
