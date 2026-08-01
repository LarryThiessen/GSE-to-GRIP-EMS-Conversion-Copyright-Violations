import { decodeGSEExport } from "./gseDecoder";
import { encodeEMSExport, GRIP_PREFIX, GRIP_FORMAT_VERSION } from "./emsEncoder";
import { stepsFromActions } from "./emsDecoder";
import type { ConvertResult, DecodeResult } from "./types";
import { formatMacroForGripExport } from "./spellCatalog";
import { mergeKeyPress, extractKeyPressFromVersion } from "./keyPressExtract";

type LooseRecord = Record<string, any>;

const DEFAULT_ICON = 134400;
const STEP_FUNCTIONS = new Set(["Sequential", "Priority", "Random", "ReversePriority"]);
const INTERLEAVE_MIN = 2;
const INTERLEAVE_MAX = 50;
const LOOP_REPEAT_MAX = 50;

function convertGSEExportToGRIP(input: unknown): ConvertResult {
  const decoded = decodeGSEExport(input);
  return convertDecodedGSEToGRIP(decoded);
}

function convertDecodedGSEToGRIP(decoded: DecodeResult): ConvertResult {
  const warnings: string[] = [];
  const sequences = decoded.sequences || [];
  const meta = decoded.meta || {};

  if (!sequences.length) {
    throw new Error("The GSE export did not contain any sequences to convert.");
  }

  const isCollection = sequences.length > 1 || meta.type === "COLLECTION";
  const payload = isCollection
    ? buildCollectionPayload(sequences, meta, warnings)
    : buildSinglePayload(sequences[0], meta, warnings);

  return {
    export: encodeEMSExport(payload, GRIP_PREFIX),
    format: "GRIP-EMS",
    version: GRIP_FORMAT_VERSION,
    type: isCollection ? "COLLECTION" : "SEQUENCE",
    sequenceCount: sequences.length,
    sequenceNames: sequences.map(sequence => sequence.name).filter((name): name is string => Boolean(name)),
    warnings
  };
}

function buildSinglePayload(sequence: LooseRecord, meta: LooseRecord, warnings: string[]): LooseRecord {
  return {
    format: "GRIP-EMS",
    version: GRIP_FORMAT_VERSION,
    locale: "enUS",
    name: sequence.name,
    sequence: buildSequencePayload(sequence, meta, warnings)
  };
}

function buildCollectionPayload(sequences: LooseRecord[], meta: LooseRecord, warnings: string[]): LooseRecord {
  const exportMeta = meta.exportMeta || {};
  const payload: LooseRecord = {
    format: "GRIP-EMS",
    version: GRIP_FORMAT_VERSION,
    type: "COLLECTION",
    locale: "enUS",
    sequences: {}
  };

  if (exportMeta.collectionName || exportMeta.author || exportMeta.description || exportMeta.helplink || exportMeta.helpUrl) {
    const collectionMeta: LooseRecord = {
      collectionName: exportMeta.collectionName || "",
      author: exportMeta.author || "",
      description: exportMeta.description || "",
      helplink: exportMeta.helplink || ""
    };

    // Source metadata is carried through only when the source actually had a value.
    if (exportMeta.helpUrl) {
      collectionMeta.helpUrl = exportMeta.helpUrl;
    }
    if (exportMeta.platformId) {
      collectionMeta.platformId = exportMeta.platformId;
    }
    if (exportMeta.checksum) {
      collectionMeta.checksum = exportMeta.checksum;
    }
    if (exportMeta.gseVersion) {
      collectionMeta.gseVersion = exportMeta.gseVersion;
    }

    payload.exportMeta = collectionMeta;
  }

  for (const sequence of sequences) {
    payload.sequences[sequence.name] = buildSequencePayload(sequence, meta, warnings, sequence.name);
  }

  return payload;
}

function buildSequencePayload(sequence: LooseRecord, meta: LooseRecord, warnings: string[], sequenceName: string = sequence.name): LooseRecord {
  const exportMeta = meta.exportMeta || {};
  const sequenceMeta = (sequence.metaData || {}) as LooseRecord;
  const versions = (sequence.versions || []).map((version: LooseRecord, index: number) =>
    buildVersionPayload(version, warnings, `${sequenceName} · ${version.name || `Version ${index + 1}`}`)
  ).filter(Boolean);

  if (!versions.length) {
    throw new Error(`Sequence "${sequenceName}" has no convertible macro blocks.`);
  }

  const helpUrl = String(sequenceMeta.HelpURL || sequenceMeta.helpUrl || exportMeta.helpUrl || "").trim();
  const platformId = String(sequenceMeta.PlatformID || sequenceMeta.platformId || exportMeta.platformId || "").trim();
  const checksum = String(sequenceMeta.Checksum || sequenceMeta.checksum || exportMeta.checksum || "").trim();
  const gseVersion = sequenceMeta.GSEVersion || sequenceMeta.gseVersion || exportMeta.gseVersion || null;

  const payload: LooseRecord = {
    icon: DEFAULT_ICON,
    author: sequenceMeta.Author || sequenceMeta.author || exportMeta.author || "",
    description: sequence.description || exportMeta.description || "",
    help: String(sequence.help || "").trim(),
    helplink: String(sequenceMeta.Helplink || sequenceMeta.helplink || exportMeta.helplink || "").trim(),
    // This converter only ever runs on a GSE source, so the origin is always accurate here.
    provenanceSource: "gse-legacy",
    classID: sequence.classId || meta.classId || 0,
    specID: sequence.specId || meta.specId || null,
    defaultVersion: sequence.defaultVersion || 1,
    versions
  };

  // Source metadata is carried through only when the source actually had a value.
  if (helpUrl) {
    payload.helpUrl = helpUrl;
  }
  if (platformId) {
    payload.platformId = platformId;
  }
  if (checksum) {
    payload.checksum = checksum;
  }
  if (gseVersion) {
    payload.gseVersion = gseVersion;
  }

  return payload;
}

function buildVersionPayload(version: LooseRecord, warnings: string[], label: string): LooseRecord | null {
  const extracted = extractKeyPressFromVersion((version as LooseRecord).blocks || []) as {
    blocks: LooseRecord[];
    keyPress?: string;
  };
  const versionForMapping = {
    ...version,
    blocks: extracted.blocks,
    keyPress: mergeKeyPress(version.keyPress || "", extracted.keyPress)
  };
  const { actions, keyPress, keyRelease } = mapBlocksToActions(
    versionForMapping.blocks,
    warnings,
    label,
    versionForMapping
  );

  if (!actions.length) {
    warnings.push(`${label}: no actions were produced after conversion.`);
    return null;
  }

  const steps = buildExportSteps(actions);
  if (!steps.length) {
    warnings.push(`${label}: no flat steps were produced; import may fail until GRIP recompiles from actions.`);
  }

  return {
    stepFunction: mapVersionStepFunction(version.stepFunction, actions),
    actions,
    steps,
    keyPress: keyPress || "",
    keyRelease: keyRelease || "",
    resetOnCombat: false,
    resetOnTarget: false,
    resetOnGear: false,
    resetOnSpec: false,
    resetTimer: 0
  };
}

function mapBlocksToActions(blocks: LooseRecord[], warnings: string[], label: string, version: LooseRecord = {}) {
  let start = 0;
  let end = blocks.length - 1;
  let keyPress = formatMacroForGripExport(version.keyPress || "");
  let keyRelease = formatMacroForGripExport(version.keyRelease || "");

  if (blocks[0]?.kind === "Repeat" && blocks[0].text) {
    keyPress = mergeKeyPress(keyPress, formatMacroForGripExport(blocks[0].text));
    start = 1;
  }

  if (end >= start && blocks[end]?.kind === "Repeat" && blocks[end].text) {
    keyRelease = mergeKeyPress(keyRelease, formatMacroForGripExport(blocks[end].text));
    end -= 1;
  }

  const actions: LooseRecord[] = [];
  for (let index = start; index <= end; index += 1) {
    const node = mapBlockToAction(blocks[index], warnings, label);
    if (node) {
      actions.push(node);
    }
  }

  return { actions, keyPress, keyRelease };
}

function mapBlockToAction(block: LooseRecord | null | undefined, warnings: string[], label: string): LooseRecord | null {
  if (!block) {
    return null;
  }

  switch (block.kind) {
    case "Action":
      return block.text ? { type: "action", macro: formatMacroForGripExport(block.text) } : null;

    case "Repeat":
      if (!block.text) {
        return null;
      }
      return {
        type: "action",
        macro: formatMacroForGripExport(block.text),
        interval: clampInterval(block.interval)
      };

    case "Loop": {
      const children = (block.children || [])
        .map((child: LooseRecord) => mapBlockToAction(child, warnings, label))
        .filter(Boolean);

      if (!children.length) {
        warnings.push(`${label}: skipped empty loop.`);
        return null;
      }

      return {
        type: "loop",
        stepFunction: mapLoopStepFunction(block.stepFunction),
        repeat: clampLoopRepeat(block.repeat),
        children
      };
    }

    case "Pause":
      return mapPauseBlock(block);

    case "If": {
      const children = (block.children || [])
        .map((child: LooseRecord) => mapBlockToAction(child, warnings, label))
        .filter(Boolean);

      if (!children.length) {
        warnings.push(`${label}: skipped empty If block.`);
        return null;
      }

      return {
        type: "if",
        variable: block.variable || "= true",
        children: [children, []]
      };
    }

    case "Embed":
      warnings.push(`${label}: GSE embed blocks are not supported in GRIP; skipped.`);
      return null;

    default:
      warnings.push(`${label}: skipped unsupported block type "${block.kind}".`);
      return null;
  }
}

function mapPauseBlock(block: LooseRecord): LooseRecord {
  const ms = block.ms;
  if (ms === "GCD" || ms === "~~GCD~~") {
    return { type: "pause", clicks: 2 };
  }

  if (block.clicks && block.clicks > 0) {
    return { type: "pause", clicks: block.clicks };
  }

  if (ms !== undefined && ms !== null && ms !== "") {
    const parsed = Number(ms);
    if (Number.isFinite(parsed) && parsed > 0) {
      return { type: "pause", clicks: Math.max(1, Math.ceil(parsed / 250)) };
    }
  }

  return { type: "pause", clicks: 1 };
}

function mapVersionStepFunction(stepFunction: unknown, actions: LooseRecord[]): string {
  const normalized = normalizeStepFunction(stepFunction);
  if (normalized) {
    return normalized;
  }

  const loop = actions.find(action => action.type === "loop");
  return mapLoopStepFunction(loop?.stepFunction);
}

function mapLoopStepFunction(stepFunction: unknown): string {
  const normalized = normalizeStepFunction(stepFunction);
  return normalized || "Sequential";
}

function normalizeStepFunction(stepFunction: unknown): string {
  const value = String(stepFunction || "").trim();
  if (!value) {
    return "";
  }

  const match = [...STEP_FUNCTIONS].find(name => name.toLowerCase() === value.toLowerCase());
  return match || value;
}

function clampInterval(value: unknown): number {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) {
    return INTERLEAVE_MIN;
  }
  return Math.min(INTERLEAVE_MAX, Math.max(INTERLEAVE_MIN, Math.floor(parsed)));
}

function clampLoopRepeat(value: unknown): number {
  const parsed = Number(value);
  if (!Number.isFinite(parsed) || parsed < 1) {
    return 1;
  }
  return Math.min(LOOP_REPEAT_MAX, Math.floor(parsed));
}

function buildExportSteps(actions: LooseRecord[]): string[] {
  return stepsFromActions(actions)
    .map(step => formatStepForExport(step))
    .filter(Boolean);
}

function formatStepForExport(step: LooseRecord): string {
  const pre = (step.preMarkers || []).join("");
  const post = (step.postMarkers || []).join("");
  const text = String(step.text || "").trim();
  const combined = `${pre}${text}${post}`.trim();
  return combined || text;
}

export {
  convertGSEExportToGRIP,
  convertDecodedGSEToGRIP,
  mapBlockToAction,
  buildExportSteps
};
