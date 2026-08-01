import crypto from "node:crypto";

type LooseRecord = Record<string, any>;

const SECRET = process.env.LAZYGRIP_AUTHOR_LOCK_SECRET as string;
if (!SECRET) {
  throw new Error(
    "LAZYGRIP_AUTHOR_LOCK_SECRET is not set. Refusing to sign or verify author-lock tokens with a hardcoded default secret."
  );
}

function readLockPayload(exportMeta: LooseRecord = {}, sequenceName = "") {
  const lockedAuthor = String(exportMeta.lockedAuthor || "").trim();
  if (!lockedAuthor) {
    return null;
  }

  return {
    lockedAuthor,
    originalAuthor: String(exportMeta.originalAuthor || lockedAuthor).trim() || lockedAuthor,
    originalAuthorRealm: String(exportMeta.originalAuthorRealm || "").trim(),
    exporterName: String(exportMeta.exporterName || "").trim(),
    exporterRealm: String(exportMeta.exporterRealm || "").trim(),
    sequenceName: String(sequenceName || "").trim()
  };
}

function createAuthorLockToken(exportMeta: LooseRecord = {}, sequenceName = ""): string | null {
  const payload = readLockPayload(exportMeta, sequenceName);
  if (!payload) {
    return null;
  }

  const body = JSON.stringify(payload);
  const signature = crypto.createHmac("sha256", SECRET).update(body).digest("base64url");
  return `${Buffer.from(body, "utf8").toString("base64url")}.${signature}`;
}

function verifyAuthorLockToken(token: unknown): LooseRecord | null {
  if (!token || typeof token !== "string") {
    return null;
  }

  const separator = token.lastIndexOf(".");
  if (separator <= 0) {
    return null;
  }

  const bodyB64 = token.slice(0, separator);
  const signature = token.slice(separator + 1);

  try {
    const body = Buffer.from(bodyB64, "base64url").toString("utf8");
    const expected = crypto.createHmac("sha256", SECRET).update(body).digest("base64url");
    if (signature !== expected) {
      return null;
    }

    const payload = JSON.parse(body);
    if (!payload?.lockedAuthor) {
      return null;
    }

    return payload;
  } catch {
    return null;
  }
}

function applyLockedAuthorFields(exportMeta: LooseRecord, payload: LooseRecord) {
  exportMeta.authorLocked = true;
  exportMeta.lockedAuthor = payload.lockedAuthor;
  exportMeta.originalAuthor = payload.originalAuthor || payload.lockedAuthor;
  exportMeta.originalAuthorRealm = payload.originalAuthorRealm || "";
  exportMeta.author = payload.lockedAuthor;

  if (payload.exporterName) {
    exportMeta.exporterName = payload.exporterName;
  }
  if (payload.exporterRealm) {
    exportMeta.exporterRealm = payload.exporterRealm;
  }
}

function clearAuthorLock(exportMeta: LooseRecord) {
  exportMeta.authorLocked = false;
  delete exportMeta.lockedAuthor;
  delete exportMeta.authorLockTokens;
  delete exportMeta.authorLockToken;
  delete exportMeta.originalAuthor;
  delete exportMeta.originalAuthorRealm;
  delete exportMeta.author;
  delete exportMeta.exporterName;
  delete exportMeta.exporterRealm;
}

function enforceAuthorLock(model: LooseRecord) {
  if (!model || typeof model !== "object") {
    return model;
  }

  model.exportMeta = { ...(model.exportMeta || {}) };
  const exportMeta = model.exportMeta;
  const tokens =
    exportMeta.authorLockTokens && typeof exportMeta.authorLockTokens === "object"
      ? exportMeta.authorLockTokens
      : {};
  const sequences = Array.isArray(model.sequences) ? model.sequences : [];

  if (!sequences.length) {
    clearAuthorLock(exportMeta);
    return model;
  }

  let anyVerified = false;
  for (const sequence of sequences) {
    const sequenceName = String(sequence?.name || "").trim();
    const token = tokens[sequenceName];
    const verified = verifyAuthorLockToken(token);
    if (verified && String(verified.sequenceName || "").trim() === sequenceName) {
      anyVerified = true;
      break;
    }
  }

  if (!anyVerified) {
    clearAuthorLock(exportMeta);
    return model;
  }

  for (const sequence of sequences) {
    const sequenceName = String(sequence?.name || "").trim();
    const token = tokens[sequenceName];
    const verified = verifyAuthorLockToken(token);
    if (verified && String(verified.sequenceName || "").trim() === sequenceName) {
      applyLockedAuthorFields(exportMeta, verified);
      break;
    }
  }

  return model;
}

function attachAuthorLockToken(model: LooseRecord) {
  if (!model?.exportMeta?.authorLocked || !Array.isArray(model.sequences)) {
    return model;
  }

  const tokens: Record<string, string> = {};
  for (const sequence of model.sequences) {
    const sequenceName = String(sequence?.name || "").trim();
    if (!sequenceName) {
      continue;
    }
    const token = createAuthorLockToken(model.exportMeta, sequenceName);
    if (token) {
      tokens[sequenceName] = token;
    }
  }

  if (Object.keys(tokens).length) {
    model.exportMeta.authorLockTokens = tokens;
    delete model.exportMeta.authorLockToken;
  }

  return model;
}

export {
  createAuthorLockToken,
  verifyAuthorLockToken,
  enforceAuthorLock,
  attachAuthorLockToken
};
