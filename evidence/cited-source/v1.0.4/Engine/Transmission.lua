-- GRIP-EMS: Transmission
-- Player-to-player sequence sharing via AceComm-3.0 (T2-9)

local ADDON_NAME, GRIPEMS = ...
local L = LibStub("AceLocale-3.0"):GetLocale("GRIP-EMS")

local T = {}
GRIPEMS.Transmission = T

-- Pending incoming sequences (ring buffer, max D.COMM_MAX_PENDING)
local pendingIncoming = {}

-- Known GRIP-EMS users (sender -> { version, lastSeen })
local knownUsers = {}

-- Version check echo-loop prevention (sender -> last response time)
local versionResponded = {}

-- Upvalue accessor for Defaults (loaded before Engine/)
local function D() return GRIPEMS.Defaults end

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
            T:SendRequest(seq, player)
        end
    end)

    -- Register GROUP_ROSTER_UPDATE for version check on group join
    local versionFrame = CreateFrame("Frame")
    versionFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
    local throttled = false
    versionFrame:SetScript("OnEvent", function()
        if throttled then return end
        throttled = true
        C_Timer.After(5, function()
            throttled = false
            T:SendVersionCheck()
        end)
    end)

    GRIPEMS:Debug("Transmission initialized (prefix: " .. D().COMM_PREFIX .. ")")
end

---------------------------------------------------------------------------
-- Channel auto-detection helper
---------------------------------------------------------------------------

--- Detect the best channel for sending a comm message.
--- @param target string|nil Target player name (required for WHISPER)
--- @return string channel The channel to use
--- @return string|nil target The target player (nil for group channels)
local function DetectChannel(target)
    if target and target ~= "" then
        return "WHISPER", target
    end
    if IsInRaid() then
        if not IsInRaid(LE_PARTY_CATEGORY_HOME)
            and IsInRaid(LE_PARTY_CATEGORY_INSTANCE) then
            return "INSTANCE_CHAT", nil
        end
        return "RAID", nil
    end
    if IsInGroup() then
        if not IsInGroup(LE_PARTY_CATEGORY_HOME)
            and IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then
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
function T:SendSequence(seqName, target, channel)
    local S = GRIPEMS.Settings
    if S and not S:Get("p2pEnabled") then
        GRIPEMS:Print(L["GEMS_SEND_DISABLED"])
        return
    end

    if not seqName or seqName == "" then return end
    if not GRIPEMS.Engine.sequences[seqName] then
        GRIPEMS:Print(string.format(L["GEMS_SEND_NO_SEQ"], seqName))
        return
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
    local ok, exportString = GE.ExportCollection(seqNames, varNames)
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
    GRIPEMS:Print(string.format(L["GEMS_SEND_SUCCESS"],
        #seqNames .. " sequence(s)", target or channel))
end

--- Send a request for a named sequence from another player.
--- @param seqName string Sequence name to request
--- @param targetPlayer string Player to request from
function T:SendRequest(seqName, targetPlayer)
    if not seqName or not targetPlayer then return end

    local payload = {
        Command = D().CMD_REQUEST,
        SeqName = seqName,
    }

    local Ser = GRIPEMS.Serialization
    local ok, encoded = Ser.Encode(payload, D().GRIP1_PREFIX)
    if not ok then return end

    GRIPEMS:SendCommMessage(D().COMM_PREFIX, encoded, "WHISPER", targetPlayer, "NORMAL")
    GRIPEMS:Print(string.format(L["GEMS_REQUEST_SENT"], seqName, targetPlayer))
end

--- Send a version check to the current group.
function T:SendVersionCheck()
    if not IsInGroup() and not IsInRaid() then return end

    local payload = {
        Command = D().CMD_VERSION,
        Version = GRIPEMS.version,
    }

    local Ser = GRIPEMS.Serialization
    local ok, encoded = Ser.Encode(payload, D().GRIP1_PREFIX)
    if not ok then return end

    local channel = DetectChannel(nil)
    GRIPEMS:SendCommMessage(D().COMM_PREFIX, encoded, channel, nil, "NORMAL")
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
    -- Ignore messages from self
    if sender == UnitName("player") then return end

    -- Ambiguate for cross-realm comparison
    local mySender = Ambiguate(sender, "none")
    local myName = UnitName("player")
    if mySender == myName then return end

    local S = GRIPEMS.Settings
    if S and not S:Get("p2pEnabled") then return end

    local Ser = GRIPEMS.Serialization
    local ok, decoded, _ = Ser.Decode(message)
    if not ok or type(decoded) ~= "table" then return end

    local cmd = decoded.Command

    -----------------------------------------------------------------------
    -- CMD_TRANSMIT: received sequence(s) from another player
    -----------------------------------------------------------------------
    if cmd == D().CMD_TRANSMIT then
        local data = decoded.Data
        if not data then return end

        -- Store in pending ring buffer
        if #pendingIncoming >= D().COMM_MAX_PENDING then
            table.remove(pendingIncoming, 1)
        end
        pendingIncoming[#pendingIncoming + 1] = {
            data = data,
            sender = sender,
            timestamp = time(),
        }

        -- Check auto-accept from friends
        if S and S:Get("p2pAutoAcceptFriends") then
            local isFriend = false
            local ambSender = Ambiguate(sender, "none")
            for i = 1, C_FriendList.GetNumFriends() do
                local info = C_FriendList.GetFriendInfoByIndex(i)
                if info and Ambiguate(info.name, "none") == ambSender then
                    isFriend = true
                    break
                end
            end
            if isFriend then
                local GI = GRIPEMS.GSEImport
                local preview = GI.Preview(data)
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
                    local commitOk, results = GI.CommitSelected(preview, selections)
                    if commitOk and results.names and #results.names > 0 then
                        for _, name in ipairs(results.names) do
                            GRIPEMS:Print(string.format(
                                L["GEMS_RECEIVE_AUTO"], name, sender))
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
        if not seqName then return end

        if GRIPEMS.Engine.sequences[seqName] then
            T:SendSequence(seqName, sender, "WHISPER")
            GRIPEMS:Print(string.format(L["GEMS_REQUEST_FULFILLED"], seqName, sender))
        end
        -- Silently ignore if we don't have it

    -----------------------------------------------------------------------
    -- CMD_VERSION: version check from another GRIP-EMS user
    -----------------------------------------------------------------------
    elseif cmd == D().CMD_VERSION then
        local version = decoded.Version
        if version then
            knownUsers[sender] = { version = version, lastSeen = time() }
            GRIPEMS:Debug(string.format(L["GEMS_VERSION_ANNOUNCE"], sender, version))
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
                GRIPEMS:SendCommMessage(D().COMM_PREFIX, encoded,
                    "WHISPER", sender, "NORMAL")
            end
        end
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
    return "|HGRIPEMS:" .. playerName .. ":" .. seqName .. "|h"
        .. "|cff00cc66[GRIP-EMS: " .. playerName .. " - " .. seqName .. "]|r|h"
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
    end
end

---------------------------------------------------------------------------
-- Send dialog (StaticPopup)
---------------------------------------------------------------------------

--- Show a dialog to enter a target player name for sending a sequence.
--- @param seqName string Sequence name to send
function T:ShowSendDialog(seqName)
    if not seqName then return end

    StaticPopupDialogs["GRIPEMS_SEND_SEQUENCE"] = {
        text = string.format(L["GEMS_SEND_DIALOG_TEXT"], seqName),
        button1 = L["GEMS_SEND_DIALOG_ACCEPT"],
        button2 = CANCEL,
        hasEditBox = true,
        editBoxWidth = 200,
        OnAccept = function(self)
            local target = self.EditBox:GetText():trim()
            if target == "" then return end
            T:SendSequence(seqName, target)
        end,
        OnShow = function(self)
            self.EditBox:SetText("")
            self.EditBox:SetFocus()
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
    }
    StaticPopup_Show("GRIPEMS_SEND_SEQUENCE")
end

---------------------------------------------------------------------------
-- Known users accessor
---------------------------------------------------------------------------

--- Get the table of known GRIP-EMS users.
--- @return table knownUsers sender -> { version, lastSeen }
function T:GetKnownUsers()
    return knownUsers
end
