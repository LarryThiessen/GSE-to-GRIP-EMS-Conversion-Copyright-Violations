---------------------------------------------------------------------------
-- WhatsNew.lua -- Login popup showing release highlights
-- Fires once per new version; users can permanently dismiss via checkbox.
---------------------------------------------------------------------------
-- Created:    2025 (pre-stamping; exact date unknown)
-- Updated:    2026-08-04
-- Patch: 12.0.7.68974 Midnight (Retail LIVE)

local ADDON_NAME, GRIPEMS = ...
GRIPEMS.WhatsNew = {}
local WN = GRIPEMS.WhatsNew
local L = LibStub("AceLocale-3.0"):GetLocale("GRIP-EMS", true)

---------------------------------------------------------------------------
-- Content table (update each release)
---------------------------------------------------------------------------
WN.currentNotes = {
    version = "2.3.18",
    title = "v2.3.18 -- Sequences From Your Other Characters",
    sections = {
        {
            heading = "Added",
            items = {
                "The sequence list can show what your other characters have saved. Tick the Other characters box above the list and every sequence from another character appears alongside your own, sorted and filtered together. Those rows are read-only, greyed, and carry the owner's name.",
                "Sequences are still stored per character and nothing about that changed, so a character appears only once it has logged in with this release.",
                "To move a sequence, right-click it and pick Copy to character. The copy is handed over the next time that character logs in, and a name collision renames the incoming sequence instead of overwriting what is already there.",
                "The CVar Health dashboard grows to 284 settings across 14 sections, with new rows for sound and audio channels, Loss of Control alerts, and a batch of interface toggles.",
            },
        },
        {
            heading = "Fixed",
            items = {
                "The step counter, the tracker icon and the action bar overlay repaint when a sequence resets. Leaving combat, switching target, swapping gear and changing spec all reset the sequence to step 1, and all three kept showing the step from before the reset while the engine sat correctly at step 1.",
                "The Copy button under the rotation preview opens the export window now. It used to fill an edit box positioned off screen, so nothing happened that you could see.",
                "A rename typed into the Source (Raw Data) tab is ignored on purpose, and the warning that says so no longer disappears after two seconds.",
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
