---------------------------------------------------------------------------
-- WhatsNew.lua -- Login popup showing release highlights
-- Fires once per new version; users can permanently dismiss via checkbox.
---------------------------------------------------------------------------
-- Created:    2025 (pre-stamping; exact date unknown)
-- Updated:    2026-08-02
-- Patch: 12.0.7.68275 Midnight (Retail LIVE)

local ADDON_NAME, GRIPEMS = ...
GRIPEMS.WhatsNew = {}
local WN = GRIPEMS.WhatsNew
local L = LibStub("AceLocale-3.0"):GetLocale("GRIP-EMS", true)

---------------------------------------------------------------------------
-- Content table (update each release)
---------------------------------------------------------------------------
WN.currentNotes = {
    version = "2.3.17",
    title = "v2.3.17 -- Variables Get a Sandbox",
    sections = {
        {
            heading = "Changed",
            items = {
                "A variable's function body used to execute with the whole game environment in reach, so it could read and write any other addon's data and any saved setting on your account. It now runs against a fixed list: the condition helpers from the Insert Helper button, the standard Lua functions, and the read-only game queries for spells, auras, items and unit state.",
                "The list covers reads only. A variable can ask what your cooldown is, whether you know a spell, how many of an item you carry, whether you are mounted, stealthed, in combat or in a group. It cannot cast, send a chat message, run a macro, change a setting or schedule anything for later.",
                "Some existing variables may stop returning a value. If one does, it used something outside that list. Turn on debug output and the variable name and the exact thing it reached are named once each.",
            },
        },
        {
            heading = "Fixed",
            items = {
                "A sequence marked do-not-share is no longer shared. The mark travels with the sequence and is honoured: it will not export to a string, will not go out over player-to-player sharing, and will not be sent if somebody asks for it directly. The export window says which sequence was refused and why.",
                "The mark is read when a sequence arrives, from either metadata layout, and the import preview shows it before you commit. A marked sequence is left out of the sequence list other players browse rather than listed with the author's help text stripped.",
            },
        },
    },
}

---------------------------------------------------------------------------
-- Should-show logic
---------------------------------------------------------------------------
function WN:ShouldShow()
    local db = GRIP_EMS_DB and GRIP_EMS_DB.whatsNew
    if not db then
        return true
    end -- first install
    if db.neverShow then
        return false
    end
    if GRIPEMS.version == "dev" then
        return false
    end
    return db.lastSeenVersion ~= GRIPEMS.version
end

---------------------------------------------------------------------------
-- Dismiss logic (close button + frame OnHide)
---------------------------------------------------------------------------
function WN:Dismiss()
    GRIP_EMS_DB.whatsNew = GRIP_EMS_DB.whatsNew or {}
    GRIP_EMS_DB.whatsNew.lastSeenVersion = GRIPEMS.version
    if WN.neverShowChecked then
        GRIP_EMS_DB.whatsNew.neverShow = true
    end
end

---------------------------------------------------------------------------
-- Frame construction
---------------------------------------------------------------------------
function WN:CreateFrame()
    local C = GRIPEMS.UI and GRIPEMS.UI.Colors

    local frame = CreateFrame("Frame", "GRIPEMS_WhatsNewFrame", UIParent, "BackdropTemplate")
    frame:SetSize(480, 380)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("DIALOG")
    frame:SetFrameLevel(200)

    -- Backdrop (match addon dark theme)
    if C then
        GRIPEMS.UI:ApplyBackdrop(frame, GRIPEMS.UI.Backdrops.panel, C.bgDeep, C.border)
    else
        frame:SetBackdrop({
            bgFile = "Interface/Tooltips/UI-Tooltip-Background",
            edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
            edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 },
        })
        frame:SetBackdropColor(0.08, 0.08, 0.16, 0.95)
        frame:SetBackdropBorderColor(0.3, 0.3, 0.5, 0.8)
    end
    if GRIPEMS.UI and GRIPEMS.UI.RegisterPanelFrame then
        GRIPEMS.UI:RegisterPanelFrame(frame, "overlay", "overlay.splash")
    end

    -- ESC-closeable
    if not tContains(UISpecialFrames, "GRIPEMS_WhatsNewFrame") then
        tinsert(UISpecialFrames, "GRIPEMS_WhatsNewFrame")
    end

    -- Title
    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -14)
    title:SetTextColor(1, 0.96, 0.26)
    title:SetText(WN.currentNotes.title)

    -- Close button
    local closeBtn = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -2, -2)
    closeBtn:SetScript("OnClick", function()
        frame:Hide()
    end)

    -- Checkbox (bottom-left) -- "Don't show again"
    local checkColor = C and C.textSecondary or CreateColor(0.533, 0.533, 0.667, 1)
    local check = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
    check:SetPoint("BOTTOMLEFT", 16, 12)
    check:SetScript("OnClick", function(self)
        WN.neverShowChecked = self:GetChecked()
    end)
    check:SetScript("OnEnter", function(self)
        GRIPEMS.UI:ShowTooltip(self, L["GEMS_UI_WHATSNEW_DISMISS"], L["GEMS_WHATSNEW_DISMISS_DESC"])
    end)
    check:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    local checkLabel = check:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    checkLabel:SetPoint("LEFT", check, "RIGHT", 4, 0)
    checkLabel:SetTextColor(checkColor:GetRGBA())
    checkLabel:SetText(L["GEMS_UI_WHATSNEW_DISMISS"])

    -- Scrollable content area
    local scrollFrame = CreateFrame("ScrollFrame", nil, frame)
    scrollFrame:SetPoint("TOPLEFT", 16, -40)
    scrollFrame:SetPoint("BOTTOMRIGHT", -16, 42)

    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetWidth(scrollFrame:GetWidth() or 448)
    scrollFrame:SetScrollChild(content)

    -- Build content from sections
    local yOff = 0
    for _, section in ipairs(WN.currentNotes.sections) do
        -- Heading
        local heading = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        heading:SetPoint("TOPLEFT", 0, -yOff)
        heading:SetTextColor(0, 0.8, 0.4)
        heading:SetText(section.heading)
        yOff = yOff + 18

        -- Items
        for _, item in ipairs(section.items) do
            local line = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            line:SetPoint("TOPLEFT", 0, -yOff)
            line:SetWidth(440)
            line:SetJustifyH("LEFT")
            line:SetText("  - " .. item)
            yOff = yOff + line:GetStringHeight() + 2
        end

        yOff = yOff + 10 -- gap between sections
    end

    content:SetHeight(yOff)

    -- Mouse wheel scrolling
    scrollFrame:EnableMouseWheel(true)
    scrollFrame:SetScript("OnMouseWheel", function(self, delta)
        local cur = self:GetVerticalScroll()
        local maxScroll = self:GetVerticalScrollRange()
        self:SetVerticalScroll(math.max(0, math.min(maxScroll, cur - delta * 30)))
    end)

    -- Dismiss on hide
    frame:SetScript("OnHide", function()
        WN:Dismiss()
    end)

    WN.frame = frame
end

---------------------------------------------------------------------------
-- Show entry point
---------------------------------------------------------------------------
function WN:Show()
    if not WN:ShouldShow() then
        return
    end
    if not WN.frame then
        WN:CreateFrame()
    end
    WN.neverShowChecked = false
    WN.frame:Show()
end

---------------------------------------------------------------------------
-- Init (called from Core.lua)
---------------------------------------------------------------------------
function WN:Init()
    if C_Timer and C_Timer.After then
        C_Timer.After(2, function()
            WN:Show()
        end)
    end
end
