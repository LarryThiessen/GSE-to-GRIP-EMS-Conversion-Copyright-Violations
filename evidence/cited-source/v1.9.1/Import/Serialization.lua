-- GRIP-EMS: Serialization
-- Encode/decode wrappers around C_EncodingUtil for import/export pipelines

local ADDON_NAME, GRIPEMS = ...
local D = GRIPEMS.Defaults

GRIPEMS.Serialization = {}
local S = GRIPEMS.Serialization

--- Encode a Lua table into a prefixed, compressed, Base64 string.
--- Pipeline: SerializeCBOR -> CompressString -> EncodeBase64 -> prepend prefix
--- @param tab table The Lua table to encode
--- @param prefix string|nil Prefix to prepend (defaults to D.GRIP1_PREFIX)
--- @return boolean success
--- @return string result Encoded string on success, error message on failure
function S.Encode(tab, prefix)
    prefix = prefix or D.GRIP1_PREFIX
    if not tab then
        return false, "Nothing to encode"
    end

    local ok, result = pcall(function()
        local cbor = C_EncodingUtil.SerializeCBOR(tab)
        local compressed = C_EncodingUtil.CompressString(cbor)
        local base64 = C_EncodingUtil.EncodeBase64(compressed)
        return prefix .. base64
    end)

    if ok then
        return true, result
    else
        return false, "Encode failed: " .. tostring(result)
    end
end

--- Detect the format of an encoded string by its prefix.
--- @param data string The encoded string to check
--- @return string|nil "GSE3", "GRIP1", or nil if unknown
function S.DetectFormat(data)
    if not data or type(data) ~= "string" then
        return nil
    end
    if data:sub(1, #D.GSE3_PREFIX) == D.GSE3_PREFIX then
        return "GSE3"
    elseif data:sub(1, #D.GRIP1_PREFIX) == D.GRIP1_PREFIX then
        return "GRIP1"
    end
    if GRIPEMS.DebugWindow then
        local preview = (data or ""):sub(1, 20)
        GRIPEMS.DebugWindow:AddMessage(
            "Import format unknown: len=" .. tostring(#(data or "")) .. " prefix=[" .. preview .. "]"
        )
    end
    return nil
end

--- Decode an encoded string back into a Lua table.
--- Detects format by prefix, then runs: strip prefix -> DecodeBase64 ->
--- DecompressString -> DeserializeCBOR.
--- If legacy decode fails from position 7, retries from position 6 (compat fallback).
--- @param data string The encoded string (with prefix)
--- @return boolean success
--- @return table|string result Decoded table on success, error message on failure
--- @return string|nil formatName "GSE3" or "GRIP1" on success
function S.Decode(data)
    if not data or type(data) ~= "string" or #data == 0 then
        return false, "No data to decode"
    end

    local format = S.DetectFormat(data)
    if not format then
        return false, "Unknown format"
    end

    -- Determine strip position based on format
    local stripPos
    if format == "GSE3" then
        stripPos = #D.GSE3_PREFIX + 1 -- position 7
    elseif format == "GRIP1" then
        stripPos = #D.GRIP1_PREFIX + 1 -- position 8
    end

    local function tryDecode(startPos)
        local base64str = data:sub(startPos)
        if #base64str == 0 then
            return false, "Empty payload after prefix"
        end
        local decoded = C_EncodingUtil.DecodeBase64(base64str)
        local decompressed = C_EncodingUtil.DecompressString(decoded)
        local result = C_EncodingUtil.DeserializeCBOR(decompressed)
        return true, result
    end

    -- Primary decode attempt
    local ok, result = pcall(function()
        local success, decoded = tryDecode(stripPos)
        if success then
            return decoded
        end
        error(decoded)
    end)

    if ok then
        local db = _G.GRIP_EMS_DB
        if db then
            db.importStats = db.importStats or {}
            local fmt = format or "unknown"
            db.importStats[fmt] = (db.importStats[fmt] or 0) + 1
        end
        return true, result, format
    end

    -- Legacy fallback: primary decode strips from position 7 (#GSE3_PREFIX + 1),
    -- but some older exporters produced strings where the Base64 payload
    -- starts one byte earlier (position 6 = #GSE3_PREFIX). This is intentional
    -- compatibility, not a bug. The fallback only runs if primary decode fails.
    if format == "GSE3" then
        local ok2, result2 = pcall(function()
            local success, decoded = tryDecode(#D.GSE3_PREFIX)
            if success then
                return decoded
            end
            error(decoded)
        end)
        if ok2 then
            local db = _G.GRIP_EMS_DB
            if db then
                db.importStats = db.importStats or {}
                db.importStats[format] = (db.importStats[format] or 0) + 1
            end
            return true, result2, format
        end
    end

    local db = _G.GRIP_EMS_DB
    if db then
        db.importStats = db.importStats or {}
        db.importStats["fail"] = (db.importStats["fail"] or 0) + 1
    end
    return false, "Decode failed: " .. tostring(result)
end

--- Compute a numeric checksum of a Lua table via CBOR serialization.
--- Used for import integrity validation (non-blocking).
--- @param tbl table The table to checksum
--- @return string|nil checksum Numeric hash as string, or nil on failure
function S.ComputeTableChecksum(tbl)
    if not tbl then
        return nil
    end
    local ok, cbor = pcall(C_EncodingUtil.SerializeCBOR, tbl)
    if not ok or not cbor then
        return nil
    end
    -- DJB2 hash of CBOR bytes
    local hash = 5381
    for i = 1, #cbor do
        hash = ((hash * 33) + string.byte(cbor, i)) % 4294967296
    end
    return tostring(hash)
end
