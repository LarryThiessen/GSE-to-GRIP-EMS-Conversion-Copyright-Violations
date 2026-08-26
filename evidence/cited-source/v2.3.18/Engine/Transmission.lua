-- GRIP-EMS: Transmission
-- Created: 2026-03-20
-- Updated: 2026-08-01
-- Patch: 12.0.7.68256 Midnight (Retail LIVE)

-- GRIP-EMS: Transmission
-- Player-to-player sequence sharing via AceComm-3.0 (T2-9)
--
-- v2.1.0 Phase D privacy-mode boundary audit:
--   The 10 Ser.Encode(payload, D().GRIP1_PREFIX) call sites in this file
--   carry one of two payload shapes -- neither needs a direct
--   BuildExportPayload wrap because privacy scrubbing happens upstream:
--
--   1) An already-encoded export string (CMD_TRANSMIT in T:SendSequence
--      and T:SendCollection). The encoded string is produced by
--      GE.Export / GE.ExportCollection, both of which call
--      Identity:BuildExportPayload INTERNALLY before encoding. Privacy
--      mode is applied at the source; this layer just wraps the string
--      in a transmission envelope.
--   2) Non-sequence control payloads (CMD_REQUEST, CMD_VERSION,
--      CMD_META_REQUEST, CMD_META, CMD_SPELLCACHE, CMD_LIST_REQUEST,
--      CMD_LIST_RESPONSE). These do not carry originalAuthor /
--      identityHash fields, so they have nothing to scrub.
--
--   The Phase B prefix decision (Transmission stays on D.GRIP1_PREFIX)
--   is unrelated to privacy: privacy controls payload CONTENTS, not
--   the format prefix. Both invariants hold.
--
-- v2.3.17 do-not-share boundary audit. The identity audit above asks only
-- whether a payload carries AUTHOR IDENTITY. That is a narrower question than
-- whether it carries AUTHORED CONTENT, and grouping seven commands together as
-- "control payloads" hid the difference: two of them ship the author's help
-- text. Every payload table in this file, by its LITERAL KEYS, not by what its
-- function name suggests:
--
--   T:SendSequence        Command, Data                     Data is a GE.Export
--                                                           string; that call
--                                                           refuses a marked
--                                                           sequence. GATED.
--   T:SendCollection      Command, Data                     as above. GATED.
--   T:SendRequest         Command, SeqName                  names a REMOTE
--                                                           sequence we want;
--                                                           discloses nothing
--                                                           of ours. Open.
--   T:SendVersionCheck    Command, Version                  addon version. Open.
--   T:SendMetaRequest     Command, SeqName                  names a REMOTE
--                                                           sequence. Open.
--   T:SendSequenceMeta    Command, SeqName, UpdatedAt,      Help is authored
--                         Help                              prose. GATED.
--   T:SendSpellCache      Command, Cache                    Cache is built from
--                                                           the spell catalog,
--                                                           never from sequence
--                                                           data. Open.
--   T:SendListRequest     Command                           one key. Open.
--   T:SendListResponse    Command, Sequences; each row:     help and author are
--                         name, help, icon, class, specID,  authored prose.
--                         author, updatedAt, stepCount      ROW FILTERED.
--   CMD_VERSION reply     Command, Version                  addon version. Open.
--
-- The two inbound stores (pendingIncoming, T.remoteLists) hold what someone
-- else sent us and are outside this boundary.
--
-- ADDING A KEY TO ANY PAYLOAD ABOVE REOPENS THIS QUESTION. The test that
-- matters is not "is this a control command" but "does this key carry text a
-- human wrote" -- help, description, notes, comments, author prose, or step
-- macrotext.

local ADDON_NAME, GRIPEMS = ...
local L = LibStub("AceLocale-3.0"):GetLocale("GRIP-EMS", true)

local T = {}
GRIPEMS.Transmission = T

-- Pending incoming sequences (ring buffer, max D.COMM_MAX_PENDING)
local pendingIncoming = {}

--- Return the count of pending incoming sequences (for diagnostics).
--- @return number count
function T:GetPendingCount()
    return #pendingIncoming
end

-- Known GRIP-EMS users (sender -> { version, lastSeen })
local knownUsers = {}

-- Version check echo-loop prevention (sender -> last response time)
local versionResponded = {}

-- Pending send dialog sequence name (set before GRIPEMS.Popup:Show)
local pendingSendSeqName = nil

-- Spell cache broadcast throttle (epoch seconds of last broadcast)
local lastSpellCacheBroadcast = 0

-- Remote sequence lists (sender -> { sequences, timestamp })
T.remoteLists = {}

-- Upvalue accessor for Defaults (loaded before Engine/)
local function D()
    return GRIPEMS.Defaults
end

-- Prune knownUsers entries older than 5 minutes (300s)
local function PruneKnownUsers()
    local now = time()
    for sender, info in pairs(knownUsers) do
        if now - info.lastSeen > 300 then
            knownUsers[sender] = nil
        end
    end
    for sender, ts in pairs(versionResponded) do
        if now - ts > 300 then
            versionResponded[sender] = nil
        end
    end
end

-- Chat event types for message filter registration (Item 3)
local CHAT_FILTER_EVENTS = {
    "CHAT_MSG_SAY",
    "CHAT_MSG_YELL",
    "CHAT_MSG_WHISPER",
    "CHAT_MSG_WHISPER_INFORM",
    "CHAT_MSG_PARTY",
    "CHAT_MSG_PARTY_LEADER",
    "CHAT_MSG_RAID",
    "CHAT_MSG_RAID_LEADER",
    "CHAT_MSG_RAID_WARNING",
    "CHAT_MSG_GUILD",
    "CHAT_MSG_OFFICER",
    "CHAT_MSG_INSTANCE_CHAT",
    "CHAT_MSG_INSTANCE_CHAT_LEADER",
    "CHAT_MSG_CHANNEL",
    "CHAT_MSG_BN_WHISPER",
}

--- Chat message filter: replaces [GRIP-EMS: Player - Seq] with clickable links.
--- @param self table Filter self reference (unused)
--- @param event string Chat event name (unused)
--- @param msg string Chat message text
--- @param author string Message author
--- @return boolean|nil false If message was modified, nil otherwise
local function ChatLinkFilter(self, event, msg, author, ...)
    if not msg or msg == "" then
        return
    end

    local newMsg = msg:gsub("%[GRIP%-EMS: (.-)%s+%-%s+(.-)%]", function(playerName, seqName)
        return T:CreateChatLink(seqName, playerName)
    end)

    if newMsg ~= msg then
        return false, newMsg, author, ...
    end
end

---------------------------------------------------------------------------
-- T:Initialize()
-- Called from Core.lua after all modules loaded (PLAYER_LOGIN).
---------------------------------------------------------------------------

--- Initialize the transmission system: embed AceComm, register prefix,
--- install SetItemRef hook, and register group event.
function T:Initialize()
    -- Embed AceComm-3.0 into the GRIPEMS table (not an AceAddon)
    LibStub("AceComm-3.0"):Embed(GRIPEMS)

    -- Define the handler BEFORE registering (CallbackHandler validates at reg time)
    function GRIPEMS:OnCommReceived(prefix, message, channel, sender)
        T:HandleReceive(prefix, message, channel, sender)
    end

    -- Register comm prefix (requires OnCommReceived to exist on the embedded object)
    GRIPEMS:RegisterComm(D().COMM_PREFIX)

    -- Install SetItemRef hook for clickable chat links
    hooksecurefunc("SetItemRef", function(link)
        local player, seq = link:match("^GRIPEMS:([^:]+):(.+)$")
        if player and seq then
            if Ambiguate(player, "none") == UnitName("player") then
                -- Own sequence: open local editor
                local MF = GRIPEMS.MainFrame
                if MF and MF.Show then
                    MF:Show()
                    local SL = GRIPEMS.SequenceList
                    if SL and SL.SelectSequence then
                        SL:SelectSequence(seq)
                    end
                end
            else
                -- Remote sequence: request from sender
                T:SendRequest(seq, player)
            end
        end
    end)

    -- Register GROUP_ROSTER_UPDATE for version check on group join
    -- Named for /reload reuse -- prevents orphan C++ frame objects
    local versionFrame = _G["GRIPEMS_TransmitEvent"] or CreateFrame("Frame", "GRIPEMS_TransmitEvent")
    versionFrame:UnregisterAllEvents()
    versionFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
    local throttled = false
    versionFrame:SetScript("OnEvent", function()
        if throttled then
            return
        end
        throttled = true
        if C_Timer and C_Timer.After then
            C_Timer.After(5, function()
                throttled = false
                T:SendVersionCheck()
            end)
        end
    end)

    -- Register SPELL_CACHE_REFRESHED to broadcast cache to group
    GRIPEMS.RegisterCallback(GRIPEMS, "SPELL_CACHE_REFRESHED", function()
        T:SendSpellCache()
    end)

    -- Register chat link filters (Midnight compatibility: skip if gameMode >= 12)
    local gameMode = 0
    if GetGameMode then
        local gmOk, gmResult = pcall(GetGameMode)
        if gmOk and type(gmResult) == "number" then
            gameMode = gmResult
        end
    end
    if gameMode < 12 then
        for _, event in ipairs(CHAT_FILTER_EVENTS) do
            ChatFrame_AddMessageEventFilter(event, ChatLinkFilter)
        end
    end

    -- Register send dialog once (text is set dynamically in ShowSendDialog)
    GRIPEMS.Popup:Define("GRIPEMS_SEND_SEQUENCE", {
        text = "",
        button1 = L["GEMS_SEND_DIALOG_ACCEPT"],
        button2 = CANCEL,
        hasEditBox = true,
        editBoxWidth = 200,
        OnAccept = function(self)
            local target = self.EditBox:GetText():trim()
            if target == "" then
                return
            end
            T:SendSequence(pendingSendSeqName, target)
        end,
        OnShow = function(self)
            self.EditBox:SetText("")
            self.EditBox:SetFocus()
        end,
        timeout = 0,
        hideOnEscape = true,
    })

    -- Pre-send repair warning dialog (text set dynamically before each show)
    GRIPEMS.Popup:Define("GRIPEMS_SEND_REPAIR_WARN", {
        text = "",
        button1 = "",
        button2 = CANCEL,
        OnAccept = function() end,
        timeout = 0,
        hideOnEscape = true,
    })

    GRIPEMS:Debug("Transmission initialized (prefix: " .. D().COMM_PREFIX .. ")")
end

---------------------------------------------------------------------------
-- Channel auto-detection helper
---------------------------------------------------------------------------

--- Detect the best channel for sending a comm message.
--- Cross-realm: AceComm handles Name-Server format natively for WHISPER.
--- PARTY/RAID channels broadcast to all group members including cross-realm;
--- sender strings include realm automatically.
--- @param target string|nil Target player name (required for WHISPER)
--- @return string channel The channel to use
--- @return string|nil target The target player (nil for group channels)
local function DetectChannel(target)
    if target and target ~= "" then
        return "WHISPER", target
    end
    if IsInRaid() then
        if not IsInRaid(LE_PARTY_CATEGORY_HOME) and IsInRaid(LE_PARTY_CATEGORY_INSTANCE) then
            return "INSTANCE_CHAT", nil
        end
        return "RAID", nil
    end
    if IsInGroup() then
        if not IsInGroup(LE_PARTY_CATEGORY_HOME) and IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then
            return "INSTANCE_CHAT", nil
        end
        return "PARTY", nil
    end
    -- Fallback: whisper requires a target
    return "WHISPER", target
end

---------------------------------------------------------------------------
-- Send functions
---------------------------------------------------------------------------

--- Send a single sequence to a target player.
--- @param seqName string Sequence name to send
--- @param target string Target player name
--- @param channel string|nil Channel override (auto-detected if nil)
function T:SendSequence(seqName, target, channel, skipRepairCheck)
    local S = GRIPEMS.Settings
    if S and not S:Get("p2pEnabled") then
        GRIPEMS:Print(L["GEMS_SEND_DISABLED"])
        return
    end

    if not seqName or seqName == "" then
        return
    end
    if not GRIPEMS.Engine.sequences[seqName] then
        GRIPEMS:Print(string.format(L["GEMS_SEND_NO_SEQ"], seqName))
        return
    end

    -- Do-not-share refusal, ahead of the repair check so a marked sequence never
    -- reaches the repair popup whose OnAccept re-enters this function. GE.Export
    -- below refuses the same sequence on its own; this gate exists so the user
    -- gets the reason instead of a generic send failure, and so no repair dialog
    -- is raised for a send that can never happen.
    local GEgate = GRIPEMS.GRIPExport
    local seqEntryGate = GRIPEMS.Engine.sequences[seqName]
    if GEgate and GEgate.IsNoRedistribute and GEgate.IsNoRedistribute(seqEntryGate and seqEntryGate.data) then
        GRIPEMS:Print(string.format(L["GEMS_EXPORT_NO_REDISTRIBUTE"], seqName))
        return
    end

    -- Pre-send repair check
    if not skipRepairCheck then
        local RA = GRIPEMS.RepairAnalyzer
        if RA then
            local seqEntry = GRIPEMS.Engine.sequences[seqName]
            if seqEntry and seqEntry.data then
                local issues = RA:Analyze(seqEntry.data, seqName)
                local iCount = 0
                for _, issue in ipairs(issues) do
                    if issue.severity == "critical" or issue.severity == "error" then
                        iCount = iCount + 1
                    end
                end
                if iCount > 0 then
                    local dialog = GRIPEMS.Popup:GetDef("GRIPEMS_SEND_REPAIR_WARN")
                    dialog.text = string.format(L["GEMS_REPAIR_SEND_WARN"], iCount)
                    dialog.button1 = L["GEMS_REPAIR_SEND_ACCEPT"]
                    dialog.OnAccept = function()
                        T:SendSequence(seqName, target, channel, true)
                    end
                    GRIPEMS.Popup:Show("GRIPEMS_SEND_REPAIR_WARN")
                    return
                end
            end
        end
    end

    local GE = GRIPEMS.GRIPExport
    local ok, exportString = GE.Export(seqName)
    if not ok then
        GRIPEMS:Print(string.format(L["GEMS_SEND_FAILED"], tostring(exportString)))
        return
    end

    -- Build command payload
    local payload = {
        Command = D().CMD_TRANSMIT,
        Data = exportString,
    }

    local Ser = GRIPEMS.Serialization
    local encOk, encoded = Ser.Encode(payload, D().GRIP1_PREFIX)
    if not encOk then
        GRIPEMS:Print(string.format(L["GEMS_SEND_FAILED"], tostring(encoded)))
        return
    end

    if not channel then
        channel, target = DetectChannel(target)
    end

    GRIPEMS:SendCommMessage(D().COMM_PREFIX, encoded, channel, target, "NORMAL")
    GRIPEMS:Print(string.format(L["GEMS_SEND_SUCCESS"], seqName, target or channel))
    T:PrintChatLink(seqName, UnitName("player"))
    if GRIPEMS.wagoAnalytics then
        GRIPEMS.wagoAnalytics:IncrementCounter("p2p_send")
    end
end

--- Send multiple sequences (collection) to a target player.
--- @param seqNames table Array of sequence names
--- @param varNames table Array of variable names
--- @param target string Target player name
--- @param channel string|nil Channel override
function T:SendCollection(seqNames, varNames, target, channel)
    local S = GRIPEMS.Settings
    if S and not S:Get("p2pEnabled") then
        GRIPEMS:Print(L["GEMS_SEND_DISABLED"])
        return
    end

    local GE = GRIPEMS.GRIPExport
    -- Do-not-share refusal for the collection send. GE.ExportCollection refuses
    -- the same selection, but only after ResolveMacroDeps has already walked it;
    -- refusing up front keeps a marked sequence out of that walk entirely.
    if GE and GE.FindNoRedistribute then
        local blockedName = GE.FindNoRedistribute(seqNames)
        if blockedName then
            GRIPEMS:Print(string.format(L["GEMS_EXPORT_NO_REDISTRIBUTE"], blockedName))
            return
        end
    end
    -- v2.3.3 Phase 1: auto-include macro-dependency bodies so P2P collection
    -- sends carry the same Macros bundle as clipboard collection exports.
    local macNames
    if GE.ResolveMacroDeps then
        local macSet = GE.ResolveMacroDeps(seqNames)
        if type(macSet) == "table" and next(macSet) then
            macNames = {}
            for macName in pairs(macSet) do
                macNames[#macNames + 1] = macName
            end
            table.sort(macNames)
        end
    end
    local ok, exportString = GE.ExportCollection(seqNames, varNames, macNames)
    if not ok then
        GRIPEMS:Print(string.format(L["GEMS_SEND_FAILED"], tostring(exportString)))
        return
    end

    local payload = {
        Command = D().CMD_TRANSMIT,
        Data = exportString,
    }

    local Ser = GRIPEMS.Serialization
    local encOk, encoded = Ser.Encode(payload, D().GRIP1_PREFIX)
    if not encOk then
        GRIPEMS:Print(string.format(L["GEMS_SEND_FAILED"], tostring(encoded)))
        return
    end

    if not channel then
        channel, target = DetectChannel(target)
    end

    GRIPEMS:SendCommMessage(D().COMM_PREFIX, encoded, channel, target, "BULK")
    GRIPEMS:Print(string.format(L["GEMS_SEND_SUCCESS"], #seqNames .. " sequence(s)", target or channel))
end

--- Send a request for a named sequence from another player.
--- @param seqName string Sequence name to request
--- @param targetPlayer string Player to request from
function T:SendRequest(seqName, targetPlayer)
    if not seqName or not targetPlayer then
        return
    end

    local payload = {
        Command = D().CMD_REQUEST,
        SeqName = seqName,
    }

    local Ser = GRIPEMS.Serialization
    local ok, encoded = Ser.Encode(payload, D().GRIP1_PREFIX)
    if not ok then
        return
    end

    GRIPEMS:SendCommMessage(D().COMM_PREFIX, encoded, "WHISPER", targetPlayer, "NORMAL")
    GRIPEMS:Print(string.format(L["GEMS_REQUEST_SENT"], seqName, targetPlayer))
end

--- Send a version check to the current group.
function T:SendVersionCheck()
    if not IsInGroup() and not IsInRaid() then
        return
    end

    local payload = {
        Command = D().CMD_VERSION,
        Version = GRIPEMS.version,
    }

    local Ser = GRIPEMS.Serialization
    local ok, encoded = Ser.Encode(payload, D().GRIP1_PREFIX)
    if not ok then
        return
    end

    local channel = DetectChannel(nil)
    GRIPEMS:SendCommMessage(D().COMM_PREFIX, encoded, channel, nil, "NORMAL")
end

--- Send a metadata request for a named sequence to a specific player.
--- @param seqName string Sequence name to query
--- @param target string Target player name (WHISPER)
function T:SendMetaRequest(seqName, target)
    if not seqName or not target then
        return
    end

    local payload = {
        Command = D().CMD_META_REQUEST,
        SeqName = seqName,
    }

    local Ser = GRIPEMS.Serialization
    local ok, encoded = Ser.Encode(payload, D().GRIP1_PREFIX)
    if not ok then
        return
    end

    GRIPEMS:SendCommMessage(D().COMM_PREFIX, encoded, "WHISPER", target, "NORMAL")
    GRIPEMS:Debug(L["GEMS_META_SENT"], seqName)
end

--- Send lightweight sequence metadata (name, updatedAt, help) to a channel.
--- @param seqName string Sequence name to send metadata for
--- @param channel string|nil Channel override (auto-detected if nil)
--- @param target string|nil Target player (required for WHISPER)
function T:SendSequenceMeta(seqName, channel, target)
    if not seqName then
        return
    end

    local entry = GRIPEMS.Engine.sequences[seqName]
    if not entry then
        return
    end
    local seqData = entry.data or entry

    -- Do-not-share refusal. The payload below carries Help, which is free prose
    -- written by the sequence author -- the most protectable field on the wire,
    -- not the "metadata only, no content" this path was previously assumed to
    -- be. SILENT return with no chat line, matching the CMD_REQUEST pull path:
    -- a meta request is remote-initiated, so a printed refusal would disclose
    -- the very possession fact the refusal exists to withhold.
    local GEmeta = GRIPEMS.GRIPExport
    if GEmeta and GEmeta.IsNoRedistribute and GEmeta.IsNoRedistribute(seqData) then
        return
    end

    local payload = {
        Command = D().CMD_META,
        SeqName = seqName,
        UpdatedAt = GRIPEMS.NormalizeUpdatedAt(seqData.updatedAt) or 0,
        Help = seqData.help or "",
    }

    local Ser = GRIPEMS.Serialization
    local ok, encoded = Ser.Encode(payload, D().GRIP1_PREFIX)
    if not ok then
        return
    end

    if not channel then
        channel, target = DetectChannel(target)
    end

    GRIPEMS:SendCommMessage(D().COMM_PREFIX, encoded, channel, target, "NORMAL")
end

--- Broadcast the local spell cache to the current group/raid.
--- Throttled to once per 60 seconds. Requires group membership.
function T:SendSpellCache()
    if not IsInGroup() and not IsInRaid() then
        return
    end
    if time() - lastSpellCacheBroadcast < 60 then
        return
    end

    local SC = GRIPEMS.SpellCache
    if not SC then
        return
    end
    local sourceCache = SC.byName
    if not sourceCache then
        return
    end

    -- Build lightweight name -> spellID map, capped at SPELLCACHE_BROADCAST_CAP_DEFAULT
    -- to keep AceComm BULK message size bounded. Iteration order over
    -- pairs() is implementation-defined; the cap is best-effort, not curated.
    local cachePayload = {}
    local cap = D().SPELLCACHE_BROADCAST_CAP_DEFAULT or 100
    local count = 0
    for _, entry in pairs(sourceCache) do
        if entry.name and entry.spellID then
            cachePayload[entry.name] = entry.spellID
            count = count + 1
            if count >= cap then
                break
            end
        end
    end

    local payload = {
        Command = D().CMD_SPELLCACHE,
        Cache = cachePayload,
    }

    local Ser = GRIPEMS.Serialization
    local ok, encoded = Ser.Encode(payload, D().GRIP1_PREFIX)
    if not ok then
        return
    end

    local channel = DetectChannel(nil)
    GRIPEMS:SendCommMessage(D().COMM_PREFIX, encoded, channel, nil, "BULK")
    lastSpellCacheBroadcast = time()
    GRIPEMS:Debug(L["GEMS_SPELLCACHE_SENT"])
end

--- Send a list request to a specific player.
--- @param target string Target player name (WHISPER)
function T:SendListRequest(target)
    if not target or target == "" then
        return
    end

    local payload = {
        Command = D().CMD_LIST_REQUEST,
    }

    local Ser = GRIPEMS.Serialization
    local ok, encoded = Ser.Encode(payload, D().GRIP1_PREFIX)
    if not ok then
        return
    end

    GRIPEMS:SendCommMessage(D().COMM_PREFIX, encoded, "WHISPER", target, "NORMAL")
    GRIPEMS:Debug("List request sent to " .. target)
end

--- Send a lightweight sequence list response to a requesting player.
--- @param target string Target player name (WHISPER)
function T:SendListResponse(target)
    if not target or target == "" then
        return
    end

    local sequences = GRIPEMS.Engine.sequences
    if not sequences then
        return
    end

    local list = {}
    local count = 0
    local _, playerClass = UnitClass("player")
    local GEList = GRIPEMS.GRIPExport
    for name, entry in pairs(sequences) do
        if count >= 50 then
            break
        end
        local seqData = entry.data or entry
        -- Do-not-share filter. Each row below carries help and author, both
        -- authored prose, so a marked sequence cannot appear in the list at all.
        --
        -- OMITTED ENTIRELY rather than listed with help blanked. A blanked row
        -- still confirms possession, and the CMD_REQUEST pull is refused anyway,
        -- so a listed row could only ever hand the requester a dead end. Nothing
        -- about the sequence is worth disclosing once sharing is refused.
        --
        -- Skipped BEFORE the count increment: a marked sequence must not consume
        -- one of the 50 slots, or a user with many marked sequences would see a
        -- short list of unmarked ones for no visible reason.
        local skip = GEList and GEList.IsNoRedistribute and GEList.IsNoRedistribute(seqData)
        if not skip then
            local activeVer = GRIPEMS.Engine:GetActiveVersion(seqData)
            list[#list + 1] = {
                name = name,
                help = seqData.help or "",
                icon = seqData.icon or 134400,
                class = playerClass,
                -- v2.3.3 Phase 1: browse metadata so the remote list UI can
                -- show spec / author / freshness without a full transfer.
                specID = seqData.specID,
                author = seqData.originalAuthor or seqData.author or "",
                updatedAt = GRIPEMS.NormalizeUpdatedAt(seqData.updatedAt) or 0,
                stepCount = (activeVer and activeVer.steps and #activeVer.steps) or 0,
            }
            count = count + 1
        end
    end

    local payload = {
        Command = D().CMD_LIST_RESPONSE,
        Sequences = list,
    }

    local Ser = GRIPEMS.Serialization
    local ok, encoded = Ser.Encode(payload, D().GRIP1_PREFIX)
    if not ok then
        return
    end

    GRIPEMS:SendCommMessage(D().COMM_PREFIX, encoded, "WHISPER", target, "BULK")
    GRIPEMS:Debug("List response sent to " .. target .. " (" .. #list .. " sequences)")
end

--- Get stored remote list for a sender.
--- @param sender string Player name
--- @return table|nil Remote list data or nil
function T:GetRemoteList(sender)
    return T.remoteLists[sender] or nil
end

---------------------------------------------------------------------------
-- Receive dispatcher
---------------------------------------------------------------------------

--- Main receive handler. Called from GRIPEMS:OnCommReceived.
--- @param prefix string Comm prefix
--- @param message string Raw encoded message
--- @param channel string Channel the message arrived on
--- @param sender string Sender name
function T:HandleReceive(prefix, message, channel, sender)
    -- Prune stale knownUsers entries (piggybacks on message traffic)
    PruneKnownUsers()

    -- Ignore messages from self
    if sender == UnitName("player") then
        return
    end

    -- Normalize sender to Name-Server format for block list lookup
    if sender and not sender:find("-") then
        local realm = GetNormalizedRealmName()
        if realm and realm ~= "" then
            sender = sender .. "-" .. realm
        end
    end

    -- Block list check: silently drop messages from blocked players
    local db = _G.GRIP_EMS_DB
    if db and db.blockedPlayers and db.blockedPlayers[sender] then
        return
    end

    -- Ambiguate for cross-realm comparison
    local mySender = Ambiguate(sender, "none")
    local myName = UnitName("player")
    if mySender == myName then
        return
    end

    local S = GRIPEMS.Settings
    if S and not S:Get("p2pEnabled") then
        return
    end

    local Ser = GRIPEMS.Serialization
    local ok, decoded, _ = Ser.Decode(message)
    if not ok or type(decoded) ~= "table" then
        return
    end

    local cmd = decoded.Command

    -----------------------------------------------------------------------
    -- CMD_TRANSMIT: received sequence(s) from another player
    -----------------------------------------------------------------------
    if cmd == D().CMD_TRANSMIT then
        local data = decoded.Data
        if not data then
            return
        end

        -- Store in pending ring buffer
        if #pendingIncoming >= D().COMM_MAX_PENDING then
            table.remove(pendingIncoming, 1)
        end
        pendingIncoming[#pendingIncoming + 1] = {
            data = data,
            sender = sender,
            timestamp = time(),
        }

        -- Check auto-accept from friends (pcall-wrapped for API safety)
        if S and S:Get("p2pAutoAcceptFriends") then
            local checkOk, checkResult = pcall(function()
                local ambSender = Ambiguate(sender, "none")
                for i = 1, C_FriendList.GetNumFriends() do
                    local info = C_FriendList.GetFriendInfoByIndex(i)
                    if info and Ambiguate(info.name, "none") == ambSender then
                        return true
                    end
                end
                return false
            end)
            local isFriend = checkOk and checkResult or false
            if isFriend then
                local LI = GRIPEMS.LegacyImport
                local preview = LI.Preview(data)
                if preview and preview.ok then
                    -- Auto-commit all as import
                    local selections = { sequences = {}, variables = {} }
                    for i, entry in ipairs(preview.sequences) do
                        selections.sequences[i] = {
                            selected = true,
                            action = entry.conflictAction or "import",
                        }
                    end
                    for i in ipairs(preview.variables) do
                        selections.variables[i] = {
                            selected = true,
                            action = "import",
                        }
                    end
                    local commitOk, results = LI.CommitSelected(preview, selections)
                    if commitOk and results.names and #results.names > 0 then
                        for _, name in ipairs(results.names) do
                            GRIPEMS:Print(string.format(L["GEMS_RECEIVE_AUTO"], name, sender))
                        end
                    end
                end
                return
            end
        end

        -- Announce and open import
        if S and S:Get("p2pAnnounceReceive") then
            GRIPEMS:Print(string.format(L["GEMS_RECEIVE_ANNOUNCE"], sender))
        end

        T:PrintChatLink("received", sender)

        -- Open ImportFrame with transmission data
        local IF = GRIPEMS.ImportFrame
        if IF and IF.ShowFromTransmission then
            IF:ShowFromTransmission(data, sender)
        end

    -----------------------------------------------------------------------
    -- CMD_REQUEST: another player is requesting a sequence from us
    -----------------------------------------------------------------------
    elseif cmd == D().CMD_REQUEST then
        local seqName = decoded.SeqName
        if not seqName then
            return
        end

        -- Do-not-share refusal on the PULL path. A send-only gate leaves this
        -- open: nothing here is user-initiated, so without this branch a remote
        -- CMD_REQUEST would fulfil itself from a marked sequence. Treated
        -- exactly like not having the sequence -- no reply, no chat line -- so
        -- the requester learns nothing about what is stored locally.
        local reqEntry = GRIPEMS.Engine.sequences[seqName]
        local GEreq = GRIPEMS.GRIPExport
        local reqBlocked = GEreq and GEreq.IsNoRedistribute and GEreq.IsNoRedistribute(reqEntry and reqEntry.data)
        if reqEntry and not reqBlocked then
            T:SendSequence(seqName, sender, "WHISPER")
            GRIPEMS:Print(string.format(L["GEMS_REQUEST_FULFILLED"], seqName, sender))
        end
        -- Silently ignore if we don't have it, or if its author marked it do-not-share

        -----------------------------------------------------------------------
        -- CMD_VERSION: version check from another GRIP-EMS user
        -----------------------------------------------------------------------
    elseif cmd == D().CMD_VERSION then
        local version = decoded.Version
        if version then
            -- sender already includes realm for cross-realm (e.g. "Name-Server")
            knownUsers[sender] = { version = version, lastSeen = time() }
            GRIPEMS:Debug(L["GEMS_VERSION_ANNOUNCE"], sender, version)
        end

        -- Respond with our version (throttled: once per sender per 60s)
        local lastResponded = versionResponded[sender]
        if not lastResponded or (time() - lastResponded) > 60 then
            versionResponded[sender] = time()

            local respPayload = {
                Command = D().CMD_VERSION,
                Version = GRIPEMS.version,
            }
            local encOk, encoded = Ser.Encode(respPayload, D().GRIP1_PREFIX)
            if encOk then
                GRIPEMS:SendCommMessage(D().COMM_PREFIX, encoded, "WHISPER", sender, "NORMAL")
            end
        end

    -----------------------------------------------------------------------
    -- CMD_META_REQUEST: another player wants our sequence metadata
    -----------------------------------------------------------------------
    elseif cmd == D().CMD_META_REQUEST then
        local seqName = decoded.SeqName
        if not seqName then
            return
        end
        if GRIPEMS.Engine.sequences[seqName] then
            T:SendSequenceMeta(seqName, "WHISPER", sender)
        end

    -----------------------------------------------------------------------
    -- CMD_META: received sequence metadata from another player
    -----------------------------------------------------------------------
    elseif cmd == D().CMD_META then
        local seqName = decoded.SeqName
        local remoteUpdatedAt = GRIPEMS.NormalizeUpdatedAt(decoded.UpdatedAt) or 0
        if not seqName then
            return
        end

        local localEntry = GRIPEMS.Engine.sequences[seqName]
        local localData = localEntry and (localEntry.data or localEntry) or nil
        local localUpdatedAt = GRIPEMS.NormalizeUpdatedAt(localData and localData.updatedAt) or 0

        if not localEntry or localUpdatedAt < remoteUpdatedAt then
            GRIPEMS:Debug(L["GEMS_META_NEWER"], seqName, sender)
            T:SendRequest(seqName, sender)
        else
            GRIPEMS:Debug(L["GEMS_META_CURRENT"], seqName, sender)
        end

    -----------------------------------------------------------------------
    -- CMD_SPELLCACHE: received spell cache entries from another player
    -----------------------------------------------------------------------
    elseif cmd == D().CMD_SPELLCACHE then
        local remoteCache = decoded.Cache
        if type(remoteCache) ~= "table" then
            return
        end

        local SC = GRIPEMS.SpellCache
        if SC and SC.MergeRemoteCache then
            local merged = SC:MergeRemoteCache(remoteCache)
            if merged > 0 then
                GRIPEMS:Debug(L["GEMS_SPELLCACHE_MERGED"], merged, sender)
            end
        end

    -----------------------------------------------------------------------
    -- CMD_LIST_REQUEST: another player wants our sequence list
    -----------------------------------------------------------------------
    elseif cmd == D().CMD_LIST_REQUEST then
        if S and not S:Get("p2pEnabled") then
            return
        end
        T:SendListResponse(sender)
        GRIPEMS:Debug("List request received from " .. sender)

    -----------------------------------------------------------------------
    -- CMD_LIST_RESPONSE: received sequence list from another player
    -----------------------------------------------------------------------
    elseif cmd == D().CMD_LIST_RESPONSE then
        local seqs = decoded.Sequences
        if type(seqs) ~= "table" then
            return
        end
        T.remoteLists[sender] = {
            sequences = seqs,
            timestamp = time(),
        }
        GRIPEMS:Fire("REMOTE_LIST_RECEIVED", sender)
        GRIPEMS:Debug("Received sequence list from " .. sender .. " (" .. #seqs .. " sequences)")
    end
end

---------------------------------------------------------------------------
-- Chat link system
---------------------------------------------------------------------------

--- Create a clickable chat link for a sequence.
--- @param seqName string Sequence name
--- @param playerName string Player who owns/sent the sequence
--- @return string link The formatted chat link
function T:CreateChatLink(seqName, playerName)
    return "|HGRIPEMS:"
        .. playerName
        .. ":"
        .. seqName
        .. "|h"
        .. "|cff00cc66[GRIP-EMS: "
        .. playerName
        .. " - "
        .. seqName
        .. "]|r|h"
end

--- Print a clickable chat link to the default chat frame.
--- @param seqName string Sequence name
--- @param senderName string Player name
function T:PrintChatLink(seqName, senderName)
    local link = T:CreateChatLink(seqName, senderName)
    DEFAULT_CHAT_FRAME:AddMessage(link)
end

---------------------------------------------------------------------------
-- Pending management
---------------------------------------------------------------------------

--- Accept a pending incoming sequence.
--- @param index number|nil Index into pendingIncoming (defaults to most recent)
function T:AcceptPending(index)
    if #pendingIncoming == 0 then
        GRIPEMS:Print(L["GEMS_ACCEPT_USAGE"])
        return
    end

    index = index or #pendingIncoming
    local pending = pendingIncoming[index]
    if not pending then
        GRIPEMS:Print(L["GEMS_ACCEPT_USAGE"])
        return
    end

    table.remove(pendingIncoming, index)

    local IF = GRIPEMS.ImportFrame
    if IF and IF.ShowFromTransmission then
        IF:ShowFromTransmission(pending.data, pending.sender)
        if GRIPEMS.wagoAnalytics then
            GRIPEMS.wagoAnalytics:IncrementCounter("p2p_receive")
        end
    end
end

---------------------------------------------------------------------------
-- Send dialog (StaticPopup)
---------------------------------------------------------------------------

--- Show a dialog to enter a target player name for sending a sequence.
--- @param seqName string Sequence name to send
function T:ShowSendDialog(seqName)
    if not seqName then
        return
    end
    pendingSendSeqName = seqName
    local text = string.format(L["GEMS_SEND_DIALOG_TEXT"], seqName)
    local names = T:GetKnownUserNames()
    if #names > 0 then
        text = text .. "\n\n" .. L["GEMS_SEND_DIALOG_KNOWN"] .. "\n" .. table.concat(names, ", ")
    end
    GRIPEMS.Popup:GetDef("GRIPEMS_SEND_SEQUENCE").text = text
    GRIPEMS.Popup:Show("GRIPEMS_SEND_SEQUENCE")
end

---------------------------------------------------------------------------
-- Known users accessor
---------------------------------------------------------------------------

--- Get the table of known GRIP-EMS users.
--- @return table knownUsers sender -> { version, lastSeen }
function T:GetKnownUsers()
    return knownUsers
end

--- Get a sorted array of known player names (pruned of stale entries).
--- @return table names Sorted array of player name strings
function T:GetKnownUserNames()
    PruneKnownUsers()
    local names = {}
    for sender in pairs(knownUsers) do
        names[#names + 1] = sender
    end
    table.sort(names)
    return names
end

---------------------------------------------------------------------------
-- Block list management (T2-9)
---------------------------------------------------------------------------

--- Block a player from P2P transmission.
--- Normalizes name to Name-Server format. Stores in GRIP_EMS_DB.blockedPlayers.
--- @param name string Player name (with or without server)
function T:BlockPlayer(name)
    if not name or name == "" then
        return
    end
    -- Ensure Name-Server format: if no dash, append player's realm
    if not name:find("-") then
        local realm = GetNormalizedRealmName()
        if realm and realm ~= "" then
            name = name .. "-" .. realm
        end
    end
    local db = _G.GRIP_EMS_DB
    if not db then
        return
    end
    db.blockedPlayers = db.blockedPlayers or {}
    db.blockedPlayers[name] = true
    GRIPEMS:Print(string.format(L["GEMS_BLOCK_ADDED"], Ambiguate(name, "none")))
end

--- Unblock a player from P2P transmission.
--- @param name string Player name (with or without server)
function T:UnblockPlayer(name)
    if not name or name == "" then
        return
    end
    -- Ensure Name-Server format
    if not name:find("-") then
        local realm = GetNormalizedRealmName()
        if realm and realm ~= "" then
            name = name .. "-" .. realm
        end
    end
    local db = _G.GRIP_EMS_DB
    if not db or not db.blockedPlayers or not db.blockedPlayers[name] then
        GRIPEMS:Print(string.format(L["GEMS_BLOCK_NOT_FOUND"], Ambiguate(name, "none")))
        return
    end
    db.blockedPlayers[name] = nil
    GRIPEMS:Print(string.format(L["GEMS_BLOCK_REMOVED"], Ambiguate(name, "none")))
end

--- Check if a player is blocked.
--- @param name string Player name (full Name-Server)
--- @return boolean blocked
function T:IsBlocked(name)
    local db = _G.GRIP_EMS_DB
    if not db or not db.blockedPlayers then
        return false
    end
    return db.blockedPlayers[name] == true
end

--- Get a sorted array of all blocked player names.
--- @return table names Sorted array of blocked player name strings
function T:GetBlockedList()
    local db = _G.GRIP_EMS_DB
    if not db or not db.blockedPlayers then
        return {}
    end
    local names = {}
    for name in pairs(db.blockedPlayers) do
        names[#names + 1] = name
    end
    table.sort(names)
    return names
end
