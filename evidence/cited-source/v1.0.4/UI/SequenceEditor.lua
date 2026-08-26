-- GRIP-EMS: Sequence Editor
-- Right panel: editor header, tab bar, and content area for sequence editing

local ADDON_NAME, GRIPEMS = ...
local UI = GRIPEMS.UI
local L = LibStub("AceLocale-3.0"):GetLocale("GRIP-EMS")

-- Upvalue accessor for Defaults
local function D() return GRIPEMS.Defaults end

GRIPEMS.SequenceEditor = {}
local SE = GRIPEMS.SequenceEditor

-- Runtime state
SE.currentSequence = nil
SE.activeTab = "Steps"
SE.isDirty = false
SE.activeVersionIndex = 1

--- Return the version being edited (may differ from the engine default).
--- @param seqData table Sequence data with versions array
--- @return table|nil The version table for the current editor index
function SE:GetEditingVersion(seqData)
    if not seqData or not seqData.versions then return nil end
    local idx = SE.activeVersionIndex or 1
    return seqData.versions[idx] or seqData.versions[1]
end

---------------------------------------------------------------------------
-- Initialization (called from UI:InitPanels)
---------------------------------------------------------------------------

--- Build the editor UI inside the right panel.
--- @param parentPanel Frame The MainFrame.rightPanel
function SE:Init(parentPanel)
    if not parentPanel then return end
    local C = UI.Colors

    -- Remove the placeholder text
    local mainFrame = GRIPEMS_MainFrame
    if mainFrame and mainFrame.rightPlaceholder then
        mainFrame.rightPlaceholder:Hide()
        mainFrame.rightPlaceholder:SetText("")
    end

    SE.container = parentPanel

    -- "Select a sequence" placeholder (shown when nothing selected)
    local selectHint = parentPanel:CreateFontString(nil, "OVERLAY")
    UI:SetFont(selectHint, 12)
    selectHint:SetPoint("CENTER", parentPanel, "CENTER", 0, 0)
    selectHint:SetText(L["GEMS_UI_SELECT_SEQUENCE"])
    selectHint:SetTextColor(C.textMuted:GetRGBA())
    SE.selectHint = selectHint

    -----------------------------------------------------------------------
    -- Editor header
    -----------------------------------------------------------------------
    local header = CreateFrame("Frame", nil, parentPanel, "BackdropTemplate")
    header:SetHeight(D().EDITOR_HEADER_HEIGHT)
    header:SetPoint("TOPLEFT", parentPanel, "TOPLEFT", 0, 0)
    header:SetPoint("TOPRIGHT", parentPanel, "TOPRIGHT", 0, 0)
    header:SetBackdrop(UI.Backdrops.panelNoBorder)
    header:SetBackdropColor(C.bgMain:GetRGBA())
    header:Hide()
    SE.header = header

    -- Icon display (32x32)
    local iconTex = header:CreateTexture(nil, "ARTWORK")
    iconTex:SetSize(32, 32)
    iconTex:SetPoint("TOPLEFT", header, "TOPLEFT", 8, -8)
    SE.iconTex = iconTex

    -- Icon tooltip frame (invisible overlay for tooltip)
    local iconOverlay = CreateFrame("Frame", nil, header)
    iconOverlay:SetAllPoints(iconTex)
    iconOverlay:EnableMouse(true)
    iconOverlay:SetScript("OnEnter", function(self)
        UI:ShowTooltip(self, L["GEMS_UI_SEQ_ICON"], L["GEMS_UI_ICON_HINT"])
    end)
    iconOverlay:SetScript("OnLeave", function()
        UI:HideTooltip()
    end)
    iconOverlay:SetScript("OnMouseUp", function()
        SE:OpenIconPicker()
    end)

    -- Name EditBox (replaces FontString from 3A)
    local nameEditBox = CreateFrame("EditBox", nil, header, "BackdropTemplate")
    nameEditBox:SetHeight(D().NAME_EDITBOX_HEIGHT)
    nameEditBox:SetPoint("LEFT", iconTex, "RIGHT", 8, 0)
    nameEditBox:SetPoint("RIGHT", header, "RIGHT", -280, 0)
    nameEditBox:SetAutoFocus(false)
    nameEditBox:SetBackdrop(UI.Backdrops.panel)
    nameEditBox:SetBackdropColor(C.bgInput:GetRGBA())
    nameEditBox:SetBackdropBorderColor(C.border:GetRGBA())
    nameEditBox:SetTextInsets(6, 6, 2, 2)

    local fontPath = GameFontNormal:GetFont()
    nameEditBox:SetFont(fontPath, 14, "OUTLINE")
    nameEditBox:SetTextColor(C.textPrimary:GetRGBA())

    nameEditBox:SetScript("OnEnterPressed", function(self)
        SE:HandleNameChange(self:GetText())
        self:ClearFocus()
    end)
    nameEditBox:SetScript("OnEscapePressed", function(self)
        -- Revert to current name
        self:SetText(SE.currentSequence or "")
        self:ClearFocus()
    end)
    nameEditBox:SetScript("OnEditFocusGained", function(self)
        self:SetBackdropBorderColor(C.borderFocus:GetRGBA())
    end)
    nameEditBox:SetScript("OnEditFocusLost", function(self)
        self:SetBackdropBorderColor(C.border:GetRGBA())
    end)
    SE.nameEditBox = nameEditBox

    -- Name tooltip overlay
    local nameTooltipFrame = CreateFrame("Frame", nil, header)
    nameTooltipFrame:SetPoint("TOPLEFT", nameEditBox, "TOPLEFT", 0, 0)
    nameTooltipFrame:SetPoint("BOTTOMRIGHT", nameEditBox, "BOTTOMRIGHT", 0, 0)
    nameTooltipFrame:EnableMouse(false)
    nameTooltipFrame:SetScript("OnEnter", function(self)
        UI:ShowTooltip(self, L["GEMS_UI_NAME_TOOLTIP"], L["GEMS_UI_NAME_EDIT_HINT"])
    end)
    nameTooltipFrame:SetScript("OnLeave", function()
        UI:HideTooltip()
    end)

    -- Save button (visible only when dirty)
    local saveBtn = UI:CreateButton(header, L["GEMS_UI_SAVE"], 60, 24)
    saveBtn:SetPoint("LEFT", nameEditBox, "RIGHT", 4, 0)
    saveBtn:SetBackdropColor(C.bgSave:GetRGBA())
    saveBtn:SetScript("OnClick", function()
        if InCombatLockdown() then return end
        SE:SaveSequence()
        SE:UpdateSaveButtons()
    end)
    saveBtn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(C.bgSaveHover:GetRGBA())
        self:SetBackdropBorderColor(C.borderFocus:GetRGBA())
        UI:ShowTooltip(self, L["GEMS_UI_SAVE"], L["GEMS_UI_SAVE_BTN_DESC"])
    end)
    saveBtn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(C.bgSave:GetRGBA())
        self:SetBackdropBorderColor(C.border:GetRGBA())
        UI:HideTooltip()
    end)
    saveBtn:Hide()
    SE.saveBtn = saveBtn

    -- Discard button (visible only when dirty)
    local discardBtn = UI:CreateButton(header, L["GEMS_UI_DISCARD"], 60, 24)
    discardBtn:SetPoint("LEFT", saveBtn, "RIGHT", 2, 0)
    discardBtn:SetScript("OnClick", function()
        if not SE.currentSequence then return end
        SE:LoadSequence(SE.currentSequence)
        SE:UpdateSaveButtons()
    end)
    discardBtn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(C.bgRowHover:GetRGBA())
        self:SetBackdropBorderColor(C.borderFocus:GetRGBA())
        UI:ShowTooltip(self, L["GEMS_UI_DISCARD"], L["GEMS_UI_DISCARD_BTN_DESC"])
    end)
    discardBtn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(C.bgButton:GetRGBA())
        self:SetBackdropBorderColor(C.border:GetRGBA())
        UI:HideTooltip()
    end)
    discardBtn:Hide()
    SE.discardBtn = discardBtn

    -- Export button (after Discard)
    local exportBtn = UI:CreateButton(header, L["GEMS_UI_EXPORT_BTN_EDITOR"], 70, 24)
    exportBtn:SetPoint("LEFT", discardBtn, "RIGHT", 4, 0)
    exportBtn:SetScript("OnClick", function()
        if not SE.currentSequence then return end
        local GE = GRIPEMS.GRIPExport
        if not GE then return end
        local ok, result = GE.Export(SE.currentSequence)
        if ok then
            local EF = GRIPEMS.ExportFrame
            if EF then
                EF:Show(SE.currentSequence, result)
            else
                GRIPEMS:Print(string.format(L["GEMS_EXPORT_RESULT"], result))
            end
        else
            GRIPEMS:Print(string.format(L["GEMS_EXPORT_FAILED"], tostring(result)))
        end
    end)
    exportBtn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(C.bgRowHover:GetRGBA())
        self:SetBackdropBorderColor(C.borderFocus:GetRGBA())
        UI:ShowTooltip(self, L["GEMS_UI_EXPORT_BTN_EDITOR"],
            L["GEMS_UI_EXPORT_BTN_EDITOR_DESC"])
    end)
    exportBtn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(C.bgButton:GetRGBA())
        self:SetBackdropBorderColor(C.border:GetRGBA())
        UI:HideTooltip()
    end)
    SE.exportBtn = exportBtn

    -- Send button (after Export)
    local sendBtn = UI:CreateButton(header, L["GEMS_UI_SEND_BTN"], 70, 24)
    sendBtn:SetPoint("LEFT", exportBtn, "RIGHT", 2, 0)
    sendBtn:SetScript("OnClick", function()
        if not SE.currentSequence then return end
        if GRIPEMS.Transmission then
            GRIPEMS.Transmission:ShowSendDialog(SE.currentSequence)
        end
    end)
    sendBtn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(C.bgRowHover:GetRGBA())
        self:SetBackdropBorderColor(C.borderFocus:GetRGBA())
        UI:ShowTooltip(self, L["GEMS_UI_SEND_BTN"], L["GEMS_UI_SEND_BTN_DESC"])
    end)
    sendBtn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(C.bgButton:GetRGBA())
        self:SetBackdropBorderColor(C.border:GetRGBA())
        UI:HideTooltip()
    end)
    SE.sendBtn = sendBtn

    -- Step function row (below icon/name)
    local sfRow = CreateFrame("Frame", nil, header)
    sfRow:SetHeight(26)
    sfRow:SetPoint("TOPLEFT", iconTex, "BOTTOMLEFT", 0, -6)
    sfRow:SetPoint("TOPRIGHT", header, "TOPRIGHT", -8, 0)

    -- Step Function label
    local sfLabel = sfRow:CreateFontString(nil, "OVERLAY")
    UI:SetFont(sfLabel, 10)
    sfLabel:SetPoint("LEFT", sfRow, "LEFT", 0, 0)
    sfLabel:SetText(L["GEMS_UI_STEP_FUNCTION"])
    sfLabel:SetTextColor(C.textSecondary:GetRGBA())

    -- Step function toggle buttons
    local sfTypes = { "Sequential", "Random", "Priority", "ReversePriority" }
    local sfLabels = {
        Sequential = L["GEMS_UI_SF_SEQUENTIAL"],
        Random = L["GEMS_UI_SF_RANDOM"],
        Priority = L["GEMS_UI_SF_PRIORITY"],
        ReversePriority = L["GEMS_UI_SF_REVERSEPRIORITY"],
    }
    SE.sfButtons = {}
    local prevBtn
    for _, sfName in ipairs(sfTypes) do
        local btn = UI:CreateButton(sfRow, sfLabels[sfName] or sfName, 68, 22)
        if prevBtn then
            btn:SetPoint("LEFT", prevBtn, "RIGHT", 2, 0)
        else
            btn:SetPoint("LEFT", sfLabel, "RIGHT", 8, 0)
        end
        btn._sfName = sfName

        btn:SetScript("OnClick", function(self)
            SE:SetStepFunction(self._sfName)
        end)
        btn:SetScript("OnEnter", function(self)
            local key = "GEMS_STEPFUNC_" .. self._sfName:upper() .. "_DESC"
            local label = sfLabels[self._sfName] or self._sfName
            UI:ShowTooltip(self, label, L[key] or "")
            self:SetBackdropColor(C.bgRowHover:GetRGBA())
            self:SetBackdropBorderColor(C.borderFocus:GetRGBA())
        end)
        btn:SetScript("OnLeave", function(self)
            SE:UpdateStepFunctionButtons()
            UI:HideTooltip()
        end)

        SE.sfButtons[sfName] = btn
        prevBtn = btn
    end

    -- Reset checkboxes row
    local resetRow = CreateFrame("Frame", nil, header)
    resetRow:SetHeight(22)
    resetRow:SetPoint("TOPLEFT", sfRow, "BOTTOMLEFT", 0, -4)
    resetRow:SetPoint("TOPRIGHT", sfRow, "BOTTOMRIGHT", 0, -4)

    -- Reset on combat checkbox
    local cbCombat = CreateFrame("CheckButton", nil, resetRow, "UICheckButtonTemplate")
    cbCombat:SetSize(22, 22)
    cbCombat:SetPoint("LEFT", resetRow, "LEFT", 0, 0)
    cbCombat:SetScript("OnClick", function(self)
        SE:OnResetToggled("combat", self:GetChecked())
    end)
    cbCombat:SetScript("OnEnter", function(self)
        UI:ShowTooltip(self, L["GEMS_UI_RESET_COMBAT"], L["GEMS_UI_RESET_COMBAT_DESC"])
    end)
    cbCombat:SetScript("OnLeave", function() UI:HideTooltip() end)
    SE.cbCombat = cbCombat

    local combatLabel = resetRow:CreateFontString(nil, "OVERLAY")
    UI:SetFont(combatLabel, 10)
    combatLabel:SetPoint("LEFT", cbCombat, "RIGHT", 2, 0)
    combatLabel:SetText(L["GEMS_UI_RESET_COMBAT"])
    combatLabel:SetTextColor(C.textSecondary:GetRGBA())

    -- Reset on target checkbox
    local cbTarget = CreateFrame("CheckButton", nil, resetRow, "UICheckButtonTemplate")
    cbTarget:SetSize(22, 22)
    cbTarget:SetPoint("LEFT", combatLabel, "RIGHT", 12, 0)
    cbTarget:SetScript("OnClick", function(self)
        SE:OnResetToggled("target", self:GetChecked())
    end)
    cbTarget:SetScript("OnEnter", function(self)
        UI:ShowTooltip(self, L["GEMS_UI_RESET_TARGET"], L["GEMS_UI_RESET_TARGET_DESC"])
    end)
    cbTarget:SetScript("OnLeave", function() UI:HideTooltip() end)
    SE.cbTarget = cbTarget

    local targetLabel = resetRow:CreateFontString(nil, "OVERLAY")
    UI:SetFont(targetLabel, 10)
    targetLabel:SetPoint("LEFT", cbTarget, "RIGHT", 2, 0)
    targetLabel:SetText(L["GEMS_UI_RESET_TARGET"])
    targetLabel:SetTextColor(C.textSecondary:GetRGBA())

    -----------------------------------------------------------------------
    -- Version bar (between header and tab bar)
    -----------------------------------------------------------------------
    local versionBar = CreateFrame("Frame", nil, parentPanel, "BackdropTemplate")
    versionBar:SetHeight(26)
    versionBar:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, 0)
    versionBar:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, 0)
    versionBar:SetBackdrop(UI.Backdrops.panelNoBorder)
    versionBar:SetBackdropColor(C.bgDeep:GetRGBA())
    versionBar:Hide()
    SE.versionBar = versionBar

    -- Version dropdown button (shows "Version X of Y")
    local versionBtn = UI:CreateButton(versionBar, "Version 1 of 1", 140, 22)
    versionBtn:SetPoint("LEFT", versionBar, "LEFT", 8, 0)
    versionBtn:SetScript("OnClick", function(self)
        if not SE.currentSequence then return end
        local vbEntry = GRIPEMS.Engine and GRIPEMS.Engine.sequences
            and GRIPEMS.Engine.sequences[SE.currentSequence]
        if not vbEntry or not vbEntry.data or not vbEntry.data.versions then return end

        MenuUtil.CreateContextMenu(self, function(_, rootDescription)
            for i = 1, #vbEntry.data.versions do
                local lbl = "Version " .. i
                if i == (vbEntry.data.defaultVersion or 1) then
                    lbl = lbl .. " (Default)"
                end
                rootDescription:CreateButton(lbl, function()
                    SE:SwitchVersion(i)
                end)
            end
        end)
    end)
    versionBtn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(C.bgRowHover:GetRGBA())
        self:SetBackdropBorderColor(C.borderFocus:GetRGBA())
        UI:ShowTooltip(self, "Version", "Select which version to edit")
    end)
    versionBtn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(C.bgButton:GetRGBA())
        self:SetBackdropBorderColor(C.border:GetRGBA())
        UI:HideTooltip()
    end)
    SE.versionBtn = versionBtn

    -- Add Version button
    local addVerBtn = UI:CreateButton(versionBar, "+", 24, 22)
    addVerBtn:SetPoint("LEFT", versionBtn, "RIGHT", 4, 0)
    addVerBtn:SetScript("OnClick", function()
        if not SE.currentSequence then return end
        if SE.isDirty then SE:PromptSave() return end
        local avEntry = GRIPEMS.Engine and GRIPEMS.Engine.sequences
            and GRIPEMS.Engine.sequences[SE.currentSequence]
        if not avEntry or not avEntry.data then return end

        local tmpl = D().NewVersion
        local newVer = {
            stepFunction = tmpl.stepFunction,
            steps = {},
            resetOnCombat = tmpl.resetOnCombat,
            resetOnTarget = tmpl.resetOnTarget,
            resetOnGear = tmpl.resetOnGear,
            resetOnSpec = tmpl.resetOnSpec,
            resetTimer = tmpl.resetTimer,
        }
        table.insert(avEntry.data.versions, newVer)
        GRIPEMS.Engine:UpdateSequenceData(SE.currentSequence, avEntry.data)
        SE.activeVersionIndex = #avEntry.data.versions
        SE:LoadVersionIntoEditor()
    end)
    addVerBtn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(C.bgRowHover:GetRGBA())
        self:SetBackdropBorderColor(C.borderFocus:GetRGBA())
        UI:ShowTooltip(self, "Add Version", "Create a new empty version")
    end)
    addVerBtn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(C.bgButton:GetRGBA())
        self:SetBackdropBorderColor(C.border:GetRGBA())
        UI:HideTooltip()
    end)
    SE.addVerBtn = addVerBtn

    -- Duplicate Version button
    local dupVerBtn = UI:CreateButton(versionBar, "Dup", 32, 22)
    dupVerBtn:SetPoint("LEFT", addVerBtn, "RIGHT", 2, 0)
    dupVerBtn:SetScript("OnClick", function()
        if not SE.currentSequence then return end
        if SE.isDirty then SE:PromptSave() return end
        local dvEntry = GRIPEMS.Engine and GRIPEMS.Engine.sequences
            and GRIPEMS.Engine.sequences[SE.currentSequence]
        if not dvEntry or not dvEntry.data then return end

        local srcVer = SE:GetEditingVersion(dvEntry.data)
        if not srcVer then return end

        local dupVer = {
            stepFunction = srcVer.stepFunction,
            steps = {},
            resetOnCombat = srcVer.resetOnCombat,
            resetOnTarget = srcVer.resetOnTarget,
            resetOnGear = srcVer.resetOnGear,
            resetOnSpec = srcVer.resetOnSpec,
            resetTimer = srcVer.resetTimer,
        }
        for j, step in ipairs(srcVer.steps) do
            dupVer.steps[j] = step
        end
        table.insert(dvEntry.data.versions, dupVer)
        GRIPEMS.Engine:UpdateSequenceData(SE.currentSequence, dvEntry.data)
        SE.activeVersionIndex = #dvEntry.data.versions
        SE:LoadVersionIntoEditor()
    end)
    dupVerBtn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(C.bgRowHover:GetRGBA())
        self:SetBackdropBorderColor(C.borderFocus:GetRGBA())
        UI:ShowTooltip(self, "Duplicate Version", "Copy current version to a new version")
    end)
    dupVerBtn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(C.bgButton:GetRGBA())
        self:SetBackdropBorderColor(C.border:GetRGBA())
        UI:HideTooltip()
    end)
    SE.dupVerBtn = dupVerBtn

    -- Delete Version button
    local delVerBtn = UI:CreateButton(versionBar, "Del", 32, 22)
    delVerBtn:SetPoint("LEFT", dupVerBtn, "RIGHT", 2, 0)
    delVerBtn:SetScript("OnClick", function()
        if not SE.currentSequence then return end
        if SE.isDirty then SE:PromptSave() return end
        local dlEntry = GRIPEMS.Engine and GRIPEMS.Engine.sequences
            and GRIPEMS.Engine.sequences[SE.currentSequence]
        if not dlEntry or not dlEntry.data or not dlEntry.data.versions then return end
        if #dlEntry.data.versions <= 1 then return end

        local deletedIdx = SE.activeVersionIndex
        table.remove(dlEntry.data.versions, deletedIdx)
        -- Adjust defaultVersion if needed
        local defVer = dlEntry.data.defaultVersion or 1
        if defVer == deletedIdx then
            dlEntry.data.defaultVersion = 1
        elseif defVer > deletedIdx then
            dlEntry.data.defaultVersion = defVer - 1
        end
        if dlEntry.data.defaultVersion > #dlEntry.data.versions then
            dlEntry.data.defaultVersion = #dlEntry.data.versions
        end
        -- Clean up contextOverrides: remove stale refs, decrement higher indices
        if dlEntry.data.contextOverrides then
            for ctxKey, ovIdx in pairs(dlEntry.data.contextOverrides) do
                if ovIdx == deletedIdx then
                    dlEntry.data.contextOverrides[ctxKey] = nil
                elseif ovIdx > deletedIdx then
                    dlEntry.data.contextOverrides[ctxKey] = ovIdx - 1
                end
            end
        end
        GRIPEMS.Engine:UpdateSequenceData(SE.currentSequence, dlEntry.data)
        SE.activeVersionIndex = 1
        SE:LoadVersionIntoEditor()
    end)
    delVerBtn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(C.bgRowHover:GetRGBA())
        self:SetBackdropBorderColor(C.borderFocus:GetRGBA())
        UI:ShowTooltip(self, "Delete Version", "Remove current version")
    end)
    delVerBtn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(C.bgButton:GetRGBA())
        self:SetBackdropBorderColor(C.border:GetRGBA())
        UI:HideTooltip()
    end)
    SE.delVerBtn = delVerBtn

    -- Set Default button
    local defVerBtn = UI:CreateButton(versionBar, "*", 24, 22)
    defVerBtn:SetPoint("LEFT", delVerBtn, "RIGHT", 2, 0)
    defVerBtn:SetScript("OnClick", function()
        if not SE.currentSequence then return end
        if SE.isDirty then SE:PromptSave() return end
        local sdEntry = GRIPEMS.Engine and GRIPEMS.Engine.sequences
            and GRIPEMS.Engine.sequences[SE.currentSequence]
        if not sdEntry or not sdEntry.data then return end

        sdEntry.data.defaultVersion = SE.activeVersionIndex
        GRIPEMS.Engine:UpdateSequenceData(SE.currentSequence, sdEntry.data)
        SE:RefreshVersionBar()
    end)
    defVerBtn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(C.bgRowHover:GetRGBA())
        self:SetBackdropBorderColor(C.borderFocus:GetRGBA())
        UI:ShowTooltip(self, "Set Default", "Make current version the default for execution")
    end)
    defVerBtn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(C.bgButton:GetRGBA())
        self:SetBackdropBorderColor(C.border:GetRGBA())
        UI:HideTooltip()
    end)
    SE.defVerBtn = defVerBtn

    -----------------------------------------------------------------------
    -- Priority Preview (between header and tab bar)
    -----------------------------------------------------------------------
    local previewFrame = CreateFrame("Frame", nil, parentPanel, "BackdropTemplate")
    previewFrame:SetHeight(D().PRIORITY_PREVIEW_HEIGHT)
    previewFrame:SetPoint("TOPLEFT", versionBar, "BOTTOMLEFT", 0, 0)
    previewFrame:SetPoint("RIGHT", parentPanel, "RIGHT", 0, 0)
    previewFrame:SetBackdrop(UI.Backdrops.panel)
    previewFrame:SetBackdropColor(C.bgInput:GetRGBA())
    previewFrame:SetBackdropBorderColor(C.border:GetRGBA())
    previewFrame:Hide()
    SE.previewFrame = previewFrame

    -- Plain ScrollFrame for clipping preview content (no scrollbar)
    local previewScroll = CreateFrame("ScrollFrame", nil, previewFrame)
    previewScroll:SetPoint("TOPLEFT", previewFrame, "TOPLEFT", 4, -2)
    previewScroll:SetPoint("BOTTOMRIGHT", previewFrame, "BOTTOMRIGHT", -4, 14)
    SE.previewScroll = previewScroll

    -- Mousewheel scrolling on the preview ScrollFrame
    previewScroll:EnableMouseWheel(true)
    previewScroll:SetScript("OnMouseWheel", function(self, delta)
        local current = self:GetVerticalScroll()
        local maxScroll = self:GetVerticalScrollRange()
        local step = 14 * 3
        local newScroll = current - (delta * step)
        newScroll = math.max(0, math.min(newScroll, maxScroll))
        self:SetVerticalScroll(newScroll)
        -- Hide fade/hint when scrolled to bottom
        local atBottom = newScroll >= (maxScroll - 1)
        if SE.previewFade then
            if atBottom then SE.previewFade:Hide()
            else SE.previewFade:Show() end
        end
        if SE.previewOverflowHint then
            if atBottom then SE.previewOverflowHint:Hide()
            else SE.previewOverflowHint:Show() end
        end
    end)

    -- Bottom fade gradient (transparent to bgInput)
    local fadeTex = previewFrame:CreateTexture(nil, "OVERLAY")
    fadeTex:SetHeight(20)
    fadeTex:SetPoint("BOTTOMLEFT", previewFrame, "BOTTOMLEFT", 1, 14)
    fadeTex:SetPoint("BOTTOMRIGHT", previewFrame, "BOTTOMRIGHT", -1, 14)
    fadeTex:SetTexture("Interface\\Buttons\\WHITE8x8")
    local bg = C.bgInput
    fadeTex:SetGradient("VERTICAL",
        CreateColor(bg.r, bg.g, bg.b, 0),
        CreateColor(bg.r, bg.g, bg.b, 1))
    fadeTex:Hide()
    SE.previewFade = fadeTex

    -- Overflow down-arrow indicator
    local overflowHint = previewFrame:CreateFontString(nil, "OVERLAY")
    UI:SetFont(overflowHint, 9)
    overflowHint:SetPoint("BOTTOMLEFT", previewFrame, "BOTTOMLEFT", 4, 2)
    overflowHint:SetText("v more")
    overflowHint:SetTextColor(C.textMuted:GetRGBA())
    overflowHint:Hide()
    SE.previewOverflowHint = overflowHint

    -- Preview EditBox (read-only, for copy support)
    local previewEditBox = CreateFrame("EditBox", nil, previewScroll)
    previewEditBox:SetWidth(previewScroll:GetWidth() or 200)
    previewEditBox:SetMultiLine(true)
    previewEditBox:SetAutoFocus(false)
    previewEditBox:EnableMouse(true)
    previewEditBox:SetFont(fontPath, 9, "")
    previewEditBox:SetTextColor(C.textSecondary:GetRGBA())
    previewEditBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    previewEditBox:EnableKeyboard(false)
    previewScroll:SetScrollChild(previewEditBox)
    SE.previewEditBox = previewEditBox

    -- Preview char count
    local previewCharCount = previewFrame:CreateFontString(nil, "OVERLAY")
    UI:SetFont(previewCharCount, 9)
    previewCharCount:SetPoint("BOTTOMRIGHT", previewFrame, "BOTTOMRIGHT", -4, 2)
    previewCharCount:SetText("")
    previewCharCount:SetTextColor(C.textSuccess:GetRGBA())
    SE.previewCharCount = previewCharCount

    -----------------------------------------------------------------------
    -- Tab bar
    -----------------------------------------------------------------------
    local tabBar = CreateFrame("Frame", nil, parentPanel, "BackdropTemplate")
    tabBar:SetHeight(D().TAB_HEIGHT)
    tabBar:SetPoint("TOPLEFT", versionBar, "BOTTOMLEFT", 0, 0)
    tabBar:SetPoint("TOPRIGHT", versionBar, "BOTTOMRIGHT", 0, 0)
    tabBar:SetBackdrop(UI.Backdrops.panelNoBorder)
    tabBar:SetBackdropColor(C.bgDeep:GetRGBA())
    tabBar:Hide()
    SE.tabBar = tabBar

    -- Tab buttons
    local tabDefs = {
        { name = "Steps",     label = L["GEMS_UI_TAB_STEPS"],     active = true  },
        { name = "Keybind",   label = L["GEMS_UI_TAB_KEYBIND"],   active = true  },
        { name = "Macros",    label = L["GEMS_UI_TAB_MACROS"],    active = true  },
        { name = "Context",  label = L["GEMS_UI_TAB_CONTEXT"],  active = true  },
        { name = "Variables", label = L["GEMS_UI_TAB_VARIABLES"], active = true  },
        { name = "Raw",       label = L["GEMS_UI_TAB_RAW"],       active = true  },
    }
    SE.tabButtons = {}
    local prevTab
    for _, def in ipairs(tabDefs) do
        local tab = CreateFrame("Button", nil, tabBar, "BackdropTemplate")
        tab:SetSize(62, D().TAB_HEIGHT)
        tab:SetBackdrop(UI.Backdrops.panelNoBorder)

        local tabLabel = tab:CreateFontString(nil, "OVERLAY")
        UI:SetFont(tabLabel, 11)
        tabLabel:SetPoint("CENTER")
        tabLabel:SetText(def.label)
        tab.label = tabLabel
        tab._tabName = def.name
        tab._isActive = def.active

        if prevTab then
            tab:SetPoint("LEFT", prevTab, "RIGHT", 0, 0)
        else
            tab:SetPoint("LEFT", tabBar, "LEFT", 4, 0)
        end

        if def.active then
            tab:SetScript("OnClick", function(self)
                SE:SwitchTab(self._tabName)
            end)
            tab:SetScript("OnEnter", function(self)
                UI:ShowTooltip(self, def.label)
            end)
            tab:SetScript("OnLeave", function() UI:HideTooltip() end)
        else
            -- Disabled tabs: grayed out with tooltip
            tabLabel:SetTextColor(C.textMuted:GetRGBA())
            tab:SetScript("OnEnter", function(self)
                UI:ShowTooltip(self, def.label, L["GEMS_UI_TAB_COMING_SOON"])
            end)
            tab:SetScript("OnLeave", function() UI:HideTooltip() end)
        end

        SE.tabButtons[def.name] = tab
        prevTab = tab
    end

    -----------------------------------------------------------------------
    -- Content area (hosts tab content)
    -----------------------------------------------------------------------
    local contentArea = CreateFrame("Frame", nil, parentPanel)
    contentArea:SetPoint("TOPLEFT", tabBar, "BOTTOMLEFT", 0, 0)
    contentArea:SetPoint("BOTTOMRIGHT", parentPanel, "BOTTOMRIGHT", 0, 0)
    contentArea:Hide()
    SE.contentArea = contentArea

    -- Initialize StepListView inside content area
    if GRIPEMS.StepListView then
        GRIPEMS.StepListView:Init(contentArea)
    end

    -- Initialize KeybindTab inside content area
    if GRIPEMS.KeybindTab then
        GRIPEMS.KeybindTab:Init(contentArea)
    end

    -- Initialize MacrosTab inside content area
    if GRIPEMS.MacrosTab then
        GRIPEMS.MacrosTab:Init(contentArea)
    end

    -- Initialize ContextTab inside content area
    if GRIPEMS.ContextTab then
        GRIPEMS.ContextTab:Init(contentArea)
    end

    -- Initialize VariablesTab inside content area
    if GRIPEMS.VariablesTab then
        GRIPEMS.VariablesTab:Init(contentArea)
    end

    -- Initialize RawTab inside content area
    if GRIPEMS.RawTab then
        GRIPEMS.RawTab:Init(contentArea)
    end

    -- Register callbacks
    if GRIPEMS.RegisterCallback then
        GRIPEMS.RegisterCallback(SE, "SEQUENCE_UPDATED", "OnSequenceUpdated")
        GRIPEMS.RegisterCallback(SE, "KEYBIND_CHANGED", "OnKeybindChangedEditor")
    end

    -- Update tab visuals
    SE:UpdateTabButtons()
end

---------------------------------------------------------------------------
-- Tab management
---------------------------------------------------------------------------

--- Switch the active tab.
--- @param tabName string Tab identifier ("Steps", "Keybind", "Macros")
function SE:SwitchTab(tabName)
    if tabName ~= "Steps" and tabName ~= "Keybind" and tabName ~= "Macros"
            and tabName ~= "Context" and tabName ~= "Variables"
            and tabName ~= "Raw" then return end
    SE.activeTab = tabName
    SE:UpdateTabButtons()
    SE:UpdateTabContent()

    -- Persist last tab choice
    if _G.GRIP_EMS_CHAR and GRIP_EMS_CHAR.ui then
        GRIP_EMS_CHAR.ui.lastTab = tabName
    end
end

--- Update tab button styling (active vs inactive).
function SE:UpdateTabButtons()
    local C = UI.Colors
    for name, tab in pairs(SE.tabButtons) do
        if not tab._isActive then
            -- Disabled tab stays muted
            tab:SetBackdropColor(0, 0, 0, 0)
            tab.label:SetTextColor(C.textMuted:GetRGBA())
        elseif name == SE.activeTab then
            tab:SetBackdropColor(C.accent:GetRGBA())
            tab.label:SetTextColor(C.textPrimary:GetRGBA())
        else
            tab:SetBackdropColor(0, 0, 0, 0)
            tab.label:SetTextColor(C.textSecondary:GetRGBA())
        end
    end
end

--- Show/hide tab content based on active tab.
function SE:UpdateTabContent()
    local SLV = GRIPEMS.StepListView
    local KBT = GRIPEMS.KeybindTab
    local MTab = GRIPEMS.MacrosTab
    local CTab = GRIPEMS.ContextTab
    local VTab = GRIPEMS.VariablesTab
    local RTab = GRIPEMS.RawTab

    -- Helper: hide all StepListView elements
    local function hideStepListView()
        if SLV and SLV.scrollBox then SLV.scrollBox:Hide() end
        if SLV and SLV.scrollBar then SLV.scrollBar:Hide() end
        if SLV and SLV.actionBar then SLV.actionBar:Hide() end
        if SLV and SLV.editArea then SLV.editArea:Hide() end
        if SLV and SLV.selectLabel then SLV.selectLabel:Hide() end
        if SLV and SLV.emptyLabel then SLV.emptyLabel:Hide() end
        if SLV and SLV.hintLabel then SLV.hintLabel:Hide() end
    end

    if SE.activeTab == "Steps" then
        -- Show StepListView elements
        if SLV and SLV.scrollBox then SLV.scrollBox:Show() end
        if SLV and SLV.scrollBar then SLV.scrollBar:Show() end
        if SLV and SLV.actionBar then SLV.actionBar:Show() end
        if SLV then SLV:UpdateEditArea() end
        -- Hide other tabs
        if KBT then KBT:Hide() end
        if MTab then MTab:Hide() end
        if CTab then CTab:Hide() end
        if VTab then VTab:Hide() end
        if RTab then RTab:Hide() end
    elseif SE.activeTab == "Keybind" then
        hideStepListView()
        if KBT then KBT:Show() end
        if MTab then MTab:Hide() end
        if CTab then CTab:Hide() end
        if VTab then VTab:Hide() end
        if RTab then RTab:Hide() end
    elseif SE.activeTab == "Macros" then
        hideStepListView()
        if KBT then KBT:Hide() end
        if MTab then MTab:Show() end
        if CTab then CTab:Hide() end
        if VTab then VTab:Hide() end
        if RTab then RTab:Hide() end
    elseif SE.activeTab == "Context" then
        hideStepListView()
        if KBT then KBT:Hide() end
        if MTab then MTab:Hide() end
        if CTab then CTab:Show() end
        if VTab then VTab:Hide() end
        if RTab then RTab:Hide() end
    elseif SE.activeTab == "Variables" then
        hideStepListView()
        if KBT then KBT:Hide() end
        if MTab then MTab:Hide() end
        if CTab then CTab:Hide() end
        if VTab then VTab:Show() end
        if RTab then RTab:Hide() end
    elseif SE.activeTab == "Raw" then
        hideStepListView()
        if KBT then KBT:Hide() end
        if MTab then MTab:Hide() end
        if CTab then CTab:Hide() end
        if VTab then VTab:Hide() end
        if RTab then RTab:Show() end
    end
end

---------------------------------------------------------------------------
-- Name change handling
---------------------------------------------------------------------------

--- Handle renaming the sequence via the name EditBox.
--- @param newName string The new name entered by the user
function SE:HandleNameChange(newName)
    if not newName then return end
    newName = newName:match("^%s*(.-)%s*$") or ""  -- trim whitespace
    if newName == "" then
        GRIPEMS:Print(L["GEMS_UI_NAME_EMPTY"])
        if SE.nameEditBox then
            SE.nameEditBox:SetText(SE.currentSequence or "")
        end
        return
    end
    if newName == SE.currentSequence then return end

    local engine = GRIPEMS.Engine
    if not engine or not engine.sequences then return end
    if engine.sequences[newName] then
        GRIPEMS:Print(string.format(L["GEMS_UI_NAME_EXISTS"], newName))
        if SE.nameEditBox then
            SE.nameEditBox:SetText(SE.currentSequence or "")
        end
        return
    end

    local oldName = SE.currentSequence
    local oldEntry = engine.sequences[oldName]
    if not oldEntry or not oldEntry.data then return end
    local oldData = oldEntry.data
    local KM = GRIPEMS.KeybindManager
    local oldKey = KM and KM:GetKeybind(oldName)

    -- Deep-copy the data with new name (version-aware)
    local newData = {
        name = newName,
        icon = oldData.icon,
        autoIcon = oldData.autoIcon,
        defaultVersion = oldData.defaultVersion or 1,
        contextOverrides = {},
        versions = {},
        author = oldData.author or "",
        version = oldData.version or "1",
        description = oldData.description or "",
        classID = oldData.classID or 0,
        specID = oldData.specID,
        createdAt = oldData.createdAt or time(),
        updatedAt = time(),
    }
    -- Deep copy contextOverrides
    if oldData.contextOverrides then
        for k, v in pairs(oldData.contextOverrides) do
            newData.contextOverrides[k] = v
        end
    end
    -- Deep copy all versions
    if oldData.versions then
        for i, ver in ipairs(oldData.versions) do
            newData.versions[i] = {
                stepFunction = ver.stepFunction,
                steps = {},
                resetOnCombat = ver.resetOnCombat,
                resetOnTarget = ver.resetOnTarget,
                resetOnGear = ver.resetOnGear,
                resetOnSpec = ver.resetOnSpec,
                resetTimer = ver.resetTimer,
            }
            for j, step in ipairs(ver.steps) do
                newData.versions[i].steps[j] = step
            end
        end
    end

    -- Deactivate old, activate new
    GRIPEMS.Engine:DeactivateSequence(oldName)
    GRIPEMS.Engine:ActivateSequence(newName, newData)

    -- Re-apply keybind to new name
    if oldKey and KM then
        C_Timer.After(0.15, function()
            KM:SetKeybind(newName, oldKey)
        end)
    end

    -- Update editor state
    SE.currentSequence = newName

    -- Refresh SequenceList
    local SL = GRIPEMS.SequenceList
    if SL then
        UI.selectedSequence = newName
        SL:RefreshDataProvider()
    end
end

---------------------------------------------------------------------------
-- Step function toggle
---------------------------------------------------------------------------

--- Update step function button styling.
function SE:UpdateStepFunctionButtons()
    local C = UI.Colors
    local engine = GRIPEMS.Engine
    local current = SE.currentSequence and engine and engine.sequences
        and engine.sequences[SE.currentSequence]
    local ver = current and current.data and SE:GetEditingVersion(current.data)
    local currentSF = ver and ver.stepFunction or ""

    for sfName, btn in pairs(SE.sfButtons) do
        if sfName == currentSF then
            btn:SetBackdropColor(C.accent:GetRGBA())
            btn:SetBackdropBorderColor(C.accent:GetRGBA())
            btn.label:SetTextColor(C.textPrimary:GetRGBA())
        else
            btn:SetBackdropColor(C.bgButton:GetRGBA())
            btn:SetBackdropBorderColor(C.border:GetRGBA())
            btn.label:SetTextColor(C.textSecondary:GetRGBA())
        end
    end
end

--- Handle step function button click.
--- @param sfName string The new step function name
function SE:SetStepFunction(sfName)
    if not SE.currentSequence then return end
    local engine = GRIPEMS.Engine
    if not engine or not engine.sequences then return end
    local entry = engine.sequences[SE.currentSequence]
    if not entry or not entry.data then return end

    local ver = SE:GetEditingVersion(entry.data)
    if not ver then return end
    if ver.stepFunction == sfName then return end

    ver.stepFunction = sfName
    SE.isDirty = true
    SE:UpdateSaveButtons()
    GRIPEMS.Engine:UpdateSequenceData(SE.currentSequence, entry.data)
    SE:UpdateStepFunctionButtons()
    SE:UpdatePriorityPreview()
end

---------------------------------------------------------------------------
-- Reset checkbox handling
---------------------------------------------------------------------------

--- Handle reset checkbox toggle.
--- @param resetType string "combat" or "target"
--- @param checked boolean New checked state
function SE:OnResetToggled(resetType, checked)
    if not SE.currentSequence then return end
    local engine = GRIPEMS.Engine
    if not engine or not engine.sequences then return end
    local entry = engine.sequences[SE.currentSequence]
    if not entry or not entry.data then return end

    local ver = SE:GetEditingVersion(entry.data)
    if not ver then return end
    if resetType == "combat" then
        ver.resetOnCombat = checked and true or false
    elseif resetType == "target" then
        ver.resetOnTarget = checked and true or false
    end
    SE.isDirty = true
    SE:UpdateSaveButtons()
    GRIPEMS.Engine:UpdateSequenceData(SE.currentSequence, entry.data)
end

---------------------------------------------------------------------------
-- Dirty state / save logic
---------------------------------------------------------------------------

--- Update Save/Discard button visibility based on dirty state.
function SE:UpdateSaveButtons()
    if not SE.saveBtn or not SE.discardBtn then return end
    if SE.isDirty then
        SE.saveBtn:Show()
        SE.discardBtn:Show()
        -- Disable Save during combat (engine methods may queue OOC ops)
        if InCombatLockdown() then
            SE.saveBtn:Disable()
        else
            SE.saveBtn:Enable()
        end
        -- Re-anchor nameEditBox wider to make room for Save/Discard
        SE.nameEditBox:ClearAllPoints()
        SE.nameEditBox:SetPoint("LEFT", SE.iconTex, "RIGHT", 8, 0)
        SE.nameEditBox:SetPoint("RIGHT", SE.header, "RIGHT", -280, 0)
        -- Export anchors after Discard
        SE.exportBtn:ClearAllPoints()
        SE.exportBtn:SetPoint("LEFT", SE.discardBtn, "RIGHT", 4, 0)
    else
        SE.saveBtn:Hide()
        SE.discardBtn:Hide()
        -- Expand nameEditBox into the space freed by hidden buttons
        SE.nameEditBox:ClearAllPoints()
        SE.nameEditBox:SetPoint("LEFT", SE.iconTex, "RIGHT", 8, 0)
        SE.nameEditBox:SetPoint("RIGHT", SE.header, "RIGHT", -155, 0)
        -- Export anchors directly after nameEditBox
        SE.exportBtn:ClearAllPoints()
        SE.exportBtn:SetPoint("LEFT", SE.nameEditBox, "RIGHT", 4, 0)
    end

    -- Sync StepListView save button + unsaved hint
    local SLV = GRIPEMS.StepListView
    if SLV and SLV.saveBtn then
        SLV.saveBtn:SetShown(SE.isDirty)
    end
    if SLV and SLV.unsavedHint then
        SLV.unsavedHint:SetShown(SE.isDirty)
    end
end

--- Save the current working steps back to the engine.
function SE:SaveSequence()
    if not SE.currentSequence then return end

    local SLV = GRIPEMS.StepListView
    if not SLV then return end

    local engine = GRIPEMS.Engine
    if not engine or not engine.sequences then return end
    local entry = engine.sequences[SE.currentSequence]
    if not entry or not entry.data then return end

    -- Build updated seqData from current engine data + working steps (version-aware)
    local oldData = entry.data
    local steps = SLV:GetWorkingSteps()

    -- Deep copy all versions, updating steps in the active version
    local newData = {
        name = oldData.name,
        icon = oldData.icon,
        autoIcon = oldData.autoIcon,
        defaultVersion = oldData.defaultVersion or 1,
        contextOverrides = {},
        versions = {},
        author = oldData.author or "",
        version = oldData.version or "1",
        description = oldData.description or "",
        classID = oldData.classID or 0,
        specID = oldData.specID,
        createdAt = oldData.createdAt or time(),
        updatedAt = time(),
    }
    if oldData.contextOverrides then
        for k, v in pairs(oldData.contextOverrides) do
            newData.contextOverrides[k] = v
        end
    end
    if oldData.versions then
        local activeIdx = SE.activeVersionIndex or oldData.defaultVersion or 1
        for i, ver in ipairs(oldData.versions) do
            newData.versions[i] = {
                stepFunction = ver.stepFunction,
                steps = {},
                resetOnCombat = ver.resetOnCombat,
                resetOnTarget = ver.resetOnTarget,
                resetOnGear = ver.resetOnGear,
                resetOnSpec = ver.resetOnSpec,
                resetTimer = ver.resetTimer,
            }
            if i == activeIdx then
                -- Active version gets the working steps
                for j, step in ipairs(steps) do
                    newData.versions[i].steps[j] = step
                end
            else
                -- Non-active versions get a straight copy
                for j, step in ipairs(ver.steps) do
                    newData.versions[i].steps[j] = step
                end
            end
        end
    end

    engine:UpdateSequenceData(SE.currentSequence, newData)

    local SL = GRIPEMS.SequenceList
    if SL then SL:RefreshDataProvider() end

    SE.isDirty = false
    SE:UpdateSaveButtons()

    -- Reload working copy baseline
    local newVer = SE:GetEditingVersion(newData)
    SLV:LoadSteps(newVer and newVer.steps or {})
end

--- Show the Save/Discard/Cancel prompt for unsaved changes.
function SE:PromptSave()
    local SL = GRIPEMS.SequenceList

    StaticPopupDialogs["GRIPEMS_SAVE_PROMPT"] = {
        text = string.format(L["GEMS_UI_SAVE_PROMPT"], SE.currentSequence or ""),
        button1 = L["GEMS_UI_SAVE"],
        button2 = L["GEMS_UI_DISCARD"],
        button3 = CANCEL,
        -- button1 = OnAccept = Save
        OnAccept = function()
            SE:SaveSequence()
            if SL and SL.pendingSelect then
                SL:DoSelectSequence(SL.pendingSelect)
                SL.pendingSelect = nil
            end
        end,
        -- button2 = OnCancel = Discard
        OnCancel = function()
            SE.isDirty = false
            if SL and SL.pendingSelect then
                SL:DoSelectSequence(SL.pendingSelect)
                SL.pendingSelect = nil
            end
        end,
        -- button3 = OnAlt = Cancel/abort
        OnAlt = function()
            if SL then SL.pendingSelect = nil end
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
    }
    StaticPopup_Show("GRIPEMS_SAVE_PROMPT")
end

---------------------------------------------------------------------------
-- Auto-Detect Icon
---------------------------------------------------------------------------

--- Detect the best icon for a sequence from its step content.
--- For Priority mode, concatenates all steps. Otherwise uses step 1.
--- @param seqData table Sequence data with steps and stepFunction
--- @return number|nil iconID The detected icon fileID, or nil
function SE:AutoDetectIcon(seqData)
    local ver = SE:GetEditingVersion(seqData)
    if not ver or not ver.steps or #ver.steps == 0 then
        return nil
    end

    local SC = GRIPEMS.SpellCache
    if not SC then return nil end

    local text
    if ver.stepFunction == "Priority" or ver.stepFunction == "ReversePriority" then
        text = table.concat(ver.steps, "\n")
    else
        text = ver.steps[1]
    end

    local spellName = SC:ParseSpellFromMacrotext(text)
    if not spellName then return nil end

    return SC:GetIcon(spellName)
end

---------------------------------------------------------------------------
-- Sequence loading
---------------------------------------------------------------------------

--- Load a sequence into the editor.
--- @param name string|nil Sequence name (nil clears editor)
function SE:LoadSequence(name)
    SE.isDirty = false
    SE:UpdateSaveButtons()

    if not name then
        SE:Clear()
        return
    end

    local entry = GRIPEMS.Engine and GRIPEMS.Engine.sequences
        and GRIPEMS.Engine.sequences[name]
    if not entry or not entry.data then
        SE:Clear()
        return
    end

    SE.currentSequence = name
    local seqData = entry.data

    -- Set version index to the sequence default
    SE.activeVersionIndex = seqData.defaultVersion or 1

    -- Show editor, hide placeholder
    if SE.selectHint then SE.selectHint:Hide() end
    if SE.header then SE.header:Show() end
    if SE.versionBar then SE.versionBar:Show() end
    if SE.tabBar then SE.tabBar:Show() end
    if SE.contentArea then SE.contentArea:Show() end

    -- Populate header: resolve icon with priority chain
    -- Manual numeric icon > auto-detect > legacy string > question mark
    local resolvedIcon
    if seqData.autoIcon == false and type(seqData.icon) == "number" then
        -- User manually picked an icon (numeric fileID)
        resolvedIcon = seqData.icon
    else
        -- Auto-detect from step content
        resolvedIcon = SE:AutoDetectIcon(seqData)
    end

    if resolvedIcon then
        if SE.iconTex then SE.iconTex:SetTexture(resolvedIcon) end
    elseif type(seqData.icon) == "string" and seqData.icon ~= "" then
        -- Legacy string icon name
        if SE.iconTex then SE.iconTex:SetTexture("Interface\\Icons\\" .. seqData.icon) end
    else
        -- Fallback: question mark
        if SE.iconTex then SE.iconTex:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark") end
    end
    SE.resolvedIcon = resolvedIcon

    if SE.nameEditBox then SE.nameEditBox:SetText(name) end

    -- Export button state
    if SE.exportBtn then SE.exportBtn:Enable() end

    -- Step function buttons
    SE:UpdateStepFunctionButtons()

    -- Reset checkboxes (from active version)
    local ver = SE:GetEditingVersion(seqData)
    if SE.cbCombat then SE.cbCombat:SetChecked(ver and ver.resetOnCombat or false) end
    if SE.cbTarget then SE.cbTarget:SetChecked(ver and ver.resetOnTarget or false) end

    -- Load steps into StepListView (from active version)
    if GRIPEMS.StepListView then
        GRIPEMS.StepListView:LoadSteps(ver and ver.steps or {})
    end

    -- Load data into KeybindTab
    if GRIPEMS.KeybindTab then
        GRIPEMS.KeybindTab:LoadSequence(name)
    end

    -- Load data into MacrosTab
    if GRIPEMS.MacrosTab then
        GRIPEMS.MacrosTab:LoadSequence(name)
    end

    -- Load data into VariablesTab (no-op, account-wide)
    if GRIPEMS.VariablesTab then
        GRIPEMS.VariablesTab:LoadSequence(name)
    end

    -- Load data into RawTab
    if GRIPEMS.RawTab then
        GRIPEMS.RawTab:LoadSequence(name)
    end

    -- Update version bar
    SE:RefreshVersionBar()

    -- Update priority preview
    SE:UpdatePriorityPreview()

    -- Make sure correct tab content is showing
    SE:UpdateTabContent()
end

--- Clear the editor to its default empty state.
function SE:Clear()
    SE.currentSequence = nil
    SE.isDirty = false
    SE.activeVersionIndex = 1

    if SE.selectHint then SE.selectHint:Show() end
    if SE.header then SE.header:Hide() end
    if SE.versionBar then SE.versionBar:Hide() end
    if SE.tabBar then SE.tabBar:Hide() end
    if SE.contentArea then SE.contentArea:Hide() end

    if SE.iconTex then
        SE.iconTex:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
    end
    if SE.nameEditBox then SE.nameEditBox:SetText("") end
    if SE.cbCombat then SE.cbCombat:SetChecked(false) end
    if SE.cbTarget then SE.cbTarget:SetChecked(false) end
    if SE.exportBtn then SE.exportBtn:Disable() end

    if GRIPEMS.StepListView then
        GRIPEMS.StepListView:Clear()
    end

    if GRIPEMS.KeybindTab then
        GRIPEMS.KeybindTab:Clear()
    end

    if GRIPEMS.MacrosTab then
        GRIPEMS.MacrosTab:Clear()
    end

    if GRIPEMS.VariablesTab then
        GRIPEMS.VariablesTab:Clear()
    end

    if GRIPEMS.RawTab then
        GRIPEMS.RawTab:Clear()
    end

    if GRIPEMS.ContextTab then
        GRIPEMS.ContextTab:Clear()
    end

    -- Hide priority preview
    if SE.previewFrame then SE.previewFrame:Hide() end
end

---------------------------------------------------------------------------
-- Callback handler
---------------------------------------------------------------------------

--- Refresh editor if the currently viewed sequence was updated externally.
function SE:OnSequenceUpdated(event, name, seqData)
    if name and name == SE.currentSequence then
        SE:LoadSequence(name)
    end
end

--- Refresh KeybindTab if the active tab is Keybind.
function SE:OnKeybindChangedEditor(event, seqName, key)
    if SE.activeTab == "Keybind" and GRIPEMS.KeybindTab then
        GRIPEMS.KeybindTab:RefreshDisplay()
    end
end

---------------------------------------------------------------------------
-- Priority Live Preview
---------------------------------------------------------------------------

---------------------------------------------------------------------------
-- Icon Picker Popup
---------------------------------------------------------------------------

--- Open (or show) the spell icon picker popup.
function SE:OpenIconPicker()
    if not SE.currentSequence then return end
    local C = UI.Colors
    local defaults = D()

    -- Create the picker frame on first call, reuse after
    if not SE.iconPicker then
        local picker = CreateFrame("Frame", "GRIPEMS_IconPicker", UIParent, "BackdropTemplate")
        picker:SetSize(defaults.ICON_PICKER_WIDTH, defaults.ICON_PICKER_HEIGHT)
        picker:SetFrameStrata("DIALOG")
        picker:SetBackdrop(UI.Backdrops.panel)
        picker:SetBackdropColor(C.bgMain:GetRGBA())
        picker:SetBackdropBorderColor(C.border:GetRGBA())
        picker:EnableMouse(true)
        picker:SetMovable(true)
        picker:RegisterForDrag("LeftButton")
        picker:SetScript("OnDragStart", function(self) self:StartMoving() end)
        picker:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
        picker:SetClampedToScreen(true)

        -- ESC to close
        tinsert(UISpecialFrames, "GRIPEMS_IconPicker")

        -- Title
        local title = picker:CreateFontString(nil, "OVERLAY")
        UI:SetFont(title, 12)
        title:SetPoint("TOPLEFT", picker, "TOPLEFT", 10, -10)
        title:SetText(L["GEMS_UI_ICON_PICKER_TITLE"])
        title:SetTextColor(C.textPrimary:GetRGBA())

        -- Close button (themed dark-UI X)
        local closeBtn = CreateFrame("Button", nil, picker, "BackdropTemplate")
        closeBtn:SetSize(24, 24)
        closeBtn:SetPoint("TOPRIGHT", picker, "TOPRIGHT", -4, -4)
        closeBtn:SetBackdrop(UI.Backdrops.panel)
        closeBtn:SetBackdropColor(C.bgButton:GetRGBA())
        closeBtn:SetBackdropBorderColor(C.border:GetRGBA())
        local pickerCloseLbl = closeBtn:CreateFontString(nil, "OVERLAY")
        UI:SetFont(pickerCloseLbl, 14)
        pickerCloseLbl:SetPoint("CENTER", 0, 1)
        pickerCloseLbl:SetText("X")
        pickerCloseLbl:SetTextColor(C.textSecondary:GetRGBA())
        closeBtn:SetScript("OnClick", function() picker:Hide() end)
        closeBtn:SetScript("OnEnter", function(self)
            self:SetBackdropColor(C.accent:GetRGBA())
            self:SetBackdropBorderColor(C.borderFocus:GetRGBA())
            pickerCloseLbl:SetTextColor(C.textPrimary:GetRGBA())
        end)
        closeBtn:SetScript("OnLeave", function(self)
            self:SetBackdropColor(C.bgButton:GetRGBA())
            self:SetBackdropBorderColor(C.border:GetRGBA())
            pickerCloseLbl:SetTextColor(C.textSecondary:GetRGBA())
        end)

        -- Auto-Detect button
        local autoBtn = UI:CreateButton(picker, L["GEMS_UI_AUTO_DETECT"], 100, 22)
        autoBtn:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
        autoBtn:SetScript("OnClick", function()
            if not SE.currentSequence then return end
            local engine = GRIPEMS.Engine
            if not engine or not engine.sequences then return end
            local entry = engine.sequences[SE.currentSequence]
            if not entry or not entry.data then return end

            entry.data.autoIcon = true
            entry.data.icon = nil
            SE.isDirty = true
            SE:UpdateSaveButtons()

            -- Refresh the editor icon
            local autoIcon = SE:AutoDetectIcon(entry.data)
            if autoIcon then
                if SE.iconTex then SE.iconTex:SetTexture(autoIcon) end
                SE.resolvedIcon = autoIcon
            else
                if SE.iconTex then
                    SE.iconTex:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
                end
                SE.resolvedIcon = nil
            end

            local SL = GRIPEMS.SequenceList
            if SL then SL:RefreshDataProvider() end

            picker:Hide()
        end)
        autoBtn:SetScript("OnEnter", function(self)
            self:SetBackdropColor(C.bgRowHover:GetRGBA())
            self:SetBackdropBorderColor(C.borderFocus:GetRGBA())
            UI:ShowTooltip(self, L["GEMS_UI_AUTO_DETECT"], L["GEMS_UI_AUTO_DETECT_DESC"])
        end)
        autoBtn:SetScript("OnLeave", function(self)
            self:SetBackdropColor(C.bgButton:GetRGBA())
            self:SetBackdropBorderColor(C.border:GetRGBA())
            UI:HideTooltip()
        end)

        -- ScrollFrame for icon grid
        local scrollFrame = CreateFrame("ScrollFrame", nil, picker, "UIPanelScrollFrameTemplate")
        scrollFrame:SetPoint("TOPLEFT", autoBtn, "BOTTOMLEFT", 0, -6)
        scrollFrame:SetPoint("BOTTOMRIGHT", picker, "BOTTOMRIGHT", -26, 8)

        local scrollChild = CreateFrame("Frame", nil, scrollFrame)
        scrollChild:SetWidth(scrollFrame:GetWidth())
        scrollFrame:SetScrollChild(scrollChild)

        picker.scrollFrame = scrollFrame
        picker.scrollChild = scrollChild
        picker.iconButtons = {}
        SE.iconPicker = picker
    end

    -- (Re)build the icon grid from SpellCache
    SE:BuildIconGrid()

    -- Position below the icon texture in the editor header
    local picker = SE.iconPicker
    picker:ClearAllPoints()
    if SE.iconTex then
        picker:SetPoint("TOPLEFT", SE.iconTex, "BOTTOMLEFT", -8, -4)
    else
        picker:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end

    picker:Show()
end

--- Build (or rebuild) the icon grid inside the picker from SpellCache data.
function SE:BuildIconGrid()
    local picker = SE.iconPicker
    if not picker then return end

    local SC = GRIPEMS.SpellCache
    if not SC then return end

    local defaults = D()
    local cols = defaults.ICON_GRID_COLS
    local size = defaults.ICON_GRID_SIZE
    local gap = defaults.ICON_GRID_GAP
    local scrollChild = picker.scrollChild

    -- Hide existing buttons
    for _, btn in ipairs(picker.iconButtons) do
        btn:Hide()
    end

    -- Deduplicate icons by iconID (multiple spells can share an icon)
    local seen = {}
    local icons = {}
    for _, entry in ipairs(SC.spells) do
        if entry.iconID and not seen[entry.iconID] then
            seen[entry.iconID] = true
            icons[#icons + 1] = { iconID = entry.iconID, name = entry.name }
        end
    end

    -- Calculate grid dimensions
    local rows = math.ceil(#icons / cols)
    local childWidth = cols * (size + gap) - gap
    local childHeight = rows * (size + gap) - gap
    if childHeight < 1 then childHeight = 1 end
    scrollChild:SetSize(childWidth, childHeight)

    -- Create/reuse icon buttons
    for i, iconData in ipairs(icons) do
        local btn = picker.iconButtons[i]
        if not btn then
            btn = CreateFrame("Button", nil, scrollChild)
            btn:SetSize(size, size)

            local tex = btn:CreateTexture(nil, "ARTWORK")
            tex:SetAllPoints()
            btn.tex = tex

            local highlight = btn:CreateTexture(nil, "HIGHLIGHT")
            highlight:SetAllPoints()
            highlight:SetColorTexture(1, 1, 1, 0.2)

            btn:SetScript("OnEnter", function(self)
                UI:ShowTooltip(self, self._spellName or "")
            end)
            btn:SetScript("OnLeave", function()
                UI:HideTooltip()
            end)
            btn:SetScript("OnClick", function(self)
                if not SE.currentSequence then return end
                local engine = GRIPEMS.Engine
                if not engine or not engine.sequences then return end
                local entry = engine.sequences[SE.currentSequence]
                if not entry or not entry.data then return end

                entry.data.icon = self._iconID
                entry.data.autoIcon = false
                SE.isDirty = true
                SE:UpdateSaveButtons()

                if SE.iconTex then SE.iconTex:SetTexture(self._iconID) end
                SE.resolvedIcon = self._iconID

                local SL = GRIPEMS.SequenceList
                if SL then SL:RefreshDataProvider() end

                picker:Hide()
            end)

            picker.iconButtons[i] = btn
        end

        -- Position in grid
        local row = math.floor((i - 1) / cols)
        local col = (i - 1) % cols
        btn:ClearAllPoints()
        btn:SetPoint("TOPLEFT", scrollChild, "TOPLEFT",
            col * (size + gap), -(row * (size + gap)))

        btn.tex:SetTexture(iconData.iconID)
        btn._iconID = iconData.iconID
        btn._spellName = iconData.name
        btn:Show()
    end
end

---------------------------------------------------------------------------
-- Priority Live Preview
---------------------------------------------------------------------------

--- Update the priority preview display. Shows compiled macrotext when
--- stepFunction is Priority and steps exist. Hides otherwise.
function SE:UpdatePriorityPreview()
    if not SE.previewFrame then return end
    local C = UI.Colors

    local engine = GRIPEMS.Engine
    local entry = SE.currentSequence and engine and engine.sequences
        and engine.sequences[SE.currentSequence]
    local seqData = entry and entry.data
    local ver = seqData and SE:GetEditingVersion(seqData)

    -- Only show for Priority/ReversePriority mode with steps
    local sf = ver and ver.stepFunction
    if not ver or (sf ~= "Priority" and sf ~= "ReversePriority")
            or not ver.steps or #ver.steps == 0 then
        SE.previewFrame:Hide()
        if SE.previewFade then SE.previewFade:Hide() end
        if SE.previewOverflowHint then SE.previewOverflowHint:Hide() end
        if SE.previewScroll then SE.previewScroll:SetVerticalScroll(0) end
        -- Restore tab bar anchor to version bar bottom
        if SE.tabBar and SE.versionBar then
            SE.tabBar:ClearAllPoints()
            SE.tabBar:SetPoint("TOPLEFT", SE.versionBar, "BOTTOMLEFT", 0, 0)
            SE.tabBar:SetPoint("TOPRIGHT", SE.versionBar, "BOTTOMRIGHT", 0, 0)
        end
        return
    end

    -- Show preview
    SE.previewFrame:Show()

    -- Shift tab bar down to anchor below preview frame
    if SE.tabBar then
        SE.tabBar:ClearAllPoints()
        SE.tabBar:SetPoint("TOPLEFT", SE.previewFrame, "BOTTOMLEFT", 0, 0)
        SE.tabBar:SetPoint("TOPRIGHT", SE.previewFrame, "BOTTOMRIGHT", 0, 0)
    end

    -- Build expanded preview: show pre-expansion pattern
    local SF = GRIPEMS.StepFunctions
    local kp = ver.keyPress or ""
    local kr = ver.keyRelease or ""
    local expandedSteps
    if sf == "ReversePriority" then
        expandedSteps = SF:ExpandReversePriority(ver.steps, kp, kr)
    else
        expandedSteps = SF:ExpandPriority(ver.steps, kp, kr)
    end

    -- Build preview text showing each expanded step numbered
    local previewLines = {}
    local maxLen = 0
    for i, entry in ipairs(expandedSteps) do
        local mt = entry.macrotext or ""
        previewLines[#previewLines + 1] = string.format("[%d] %s", i, mt)
        if #mt > maxLen then maxLen = #mt end
    end
    local compiled = table.concat(previewLines, "\n")
    local charCount = maxLen
    local expandedCount = #expandedSteps

    if SE.previewEditBox then
        SE.previewEditBox:SetText(compiled)
    end

    -- Update scroll child width to match scroll frame
    if SE.previewScroll then
        local w = SE.previewScroll:GetWidth()
        if w and w > 0 then
            SE.previewEditBox:SetWidth(w)
        end
    end

    -- Check if content overflows the scroll frame
    C_Timer.After(0, function()
        if not SE.previewScroll then return end
        local maxScroll = SE.previewScroll:GetVerticalScrollRange()
        local hasOverflow = maxScroll and maxScroll > 1
        if SE.previewFade then
            if hasOverflow then SE.previewFade:Show()
            else SE.previewFade:Hide() end
        end
        if SE.previewOverflowHint then
            if hasOverflow then SE.previewOverflowHint:Show()
            else SE.previewOverflowHint:Hide() end
        end
    end)

    -- Update char count: show longest single expanded step vs 255 limit
    -- Each expanded step is a single /cast line, so 255 macro limit applies
    if SE.previewCharCount then
        local defaults = D()
        local displayLimit = defaults.MAX_MACROTEXT_LENGTH

        SE.previewCharCount:SetText(string.format(
            "%d steps expanded | longest: %d/%d chars",
            expandedCount, charCount, displayLimit))

        if charCount >= displayLimit then
            SE.previewCharCount:SetTextColor(C.textError:GetRGBA())
        elseif charCount > defaults.CHAR_COUNT_WARNING then
            SE.previewCharCount:SetTextColor(C.textWarning:GetRGBA())
        else
            SE.previewCharCount:SetTextColor(C.textSuccess:GetRGBA())
        end
    end
end

---------------------------------------------------------------------------
-- Version management helpers
---------------------------------------------------------------------------

--- Switch the editor to a different version index.
--- @param newIndex number The 1-based version index to switch to
function SE:SwitchVersion(newIndex)
    if newIndex == SE.activeVersionIndex then return end
    if SE.isDirty then
        SE:PromptSave()
        return
    end
    SE.activeVersionIndex = newIndex
    SE:LoadVersionIntoEditor()
end

--- Reload the editor UI from the currently selected version.
function SE:LoadVersionIntoEditor()
    local entry = GRIPEMS.Engine and GRIPEMS.Engine.sequences
        and GRIPEMS.Engine.sequences[SE.currentSequence]
    if not entry or not entry.data then return end
    local ver = SE:GetEditingVersion(entry.data)
    if GRIPEMS.StepListView then
        GRIPEMS.StepListView:LoadSteps(ver and ver.steps or {})
    end
    SE:UpdateStepFunctionButtons()
    if SE.cbCombat then SE.cbCombat:SetChecked(ver and ver.resetOnCombat or false) end
    if SE.cbTarget then SE.cbTarget:SetChecked(ver and ver.resetOnTarget or false) end
    SE:UpdatePriorityPreview()
    SE:RefreshVersionBar()
    if GRIPEMS.ContextTab then GRIPEMS.ContextTab:Refresh() end
end

--- Update the version bar dropdown text and button states.
function SE:RefreshVersionBar()
    if not SE.versionBar then return end
    local entry = GRIPEMS.Engine and GRIPEMS.Engine.sequences
        and GRIPEMS.Engine.sequences[SE.currentSequence]
    if not entry or not entry.data then return end
    local total = entry.data.versions and #entry.data.versions or 1
    local isDefault = SE.activeVersionIndex == (entry.data.defaultVersion or 1)

    -- Update dropdown button text
    if SE.versionBtn and SE.versionBtn.label then
        local txt = "Version " .. SE.activeVersionIndex .. " of " .. total
        if isDefault then
            txt = txt .. " (*)"
        end
        SE.versionBtn.label:SetText(txt)
    end

    -- Enable/disable delete button (disabled when only 1 version)
    if SE.delVerBtn then
        if total <= 1 then
            SE.delVerBtn:Disable()
            if SE.delVerBtn.label then
                SE.delVerBtn.label:SetTextColor(UI.Colors.textMuted:GetRGBA())
            end
        else
            SE.delVerBtn:Enable()
            if SE.delVerBtn.label then
                SE.delVerBtn.label:SetTextColor(UI.Colors.textSecondary:GetRGBA())
            end
        end
    end
end

