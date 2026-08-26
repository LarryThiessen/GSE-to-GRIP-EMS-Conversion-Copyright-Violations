-- GRIP-EMS: Popup Sequence Editor
-- Standalone lightweight editor windows (max 4, pooled).
-- Each popup has its own state: currentSequence, isDirty, activeVersionIndex,
-- workingSteps, and independent frame tree.

local ADDON_NAME, GRIPEMS = ...
local UI = GRIPEMS.UI
local L = LibStub("AceLocale-3.0"):GetLocale("GRIP-EMS")

local function D()
    return GRIPEMS.Defaults
end

GRIPEMS.PopupEditor = {}
local PE = GRIPEMS.PopupEditor

PE.pool = {}

-- Forward declaration
local InitPopupStepRow

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

--- Deep-copy a steps array (strings only).
--- @param steps table Array of step strings
--- @return table Deep copy
local function DeepCopySteps(steps)
    local copy = {}
    for i, step in ipairs(steps) do
        copy[i] = step
    end
    return copy
end

--- Get or lazily create the per-instance undo stack.
--- @param inst table Popup instance
--- @return table|nil UndoStack instance
local function GetUndoStack(inst)
    if not inst.undoStack then
        local US = GRIPEMS.UndoStack
        if US and US.New then
            inst.undoStack = US:New()
        end
    end
    return inst.undoStack
end

--- Resolve an icon for a sequence (auto-detect or manual).
--- @param seqData table Sequence data
--- @return any Texture path or ID
local function ResolvePopupIcon(seqData)
    if not seqData then
        return "Interface\\Icons\\INV_Misc_QuestionMark"
    end
    -- Manual numeric icon
    if seqData.autoIcon == false and type(seqData.icon) == "number" then
        return seqData.icon
    end
    -- Auto-detect via main editor if available
    local SE = GRIPEMS.SequenceEditor
    if SE and SE.AutoDetectIcon then
        local detected = SE:AutoDetectIcon(seqData)
        if detected then
            return detected
        end
    end
    -- Legacy string icon
    if type(seqData.icon) == "string" and seqData.icon ~= "" then
        return "Interface\\Icons\\" .. seqData.icon
    end
    return "Interface\\Icons\\INV_Misc_QuestionMark"
end

---------------------------------------------------------------------------
-- Open / find / create
---------------------------------------------------------------------------

--- Open a sequence in a popup editor.
--- If the sequence is already open, bring that popup to front.
--- @param seqName string Sequence name to edit
function PE:Open(seqName)
    if not seqName or seqName == "" then
        return
    end

    -- Check if already open in a popup
    for _, inst in ipairs(PE.pool) do
        if inst.inUse and inst.currentSequence == seqName then
            inst.frame:Show()
            inst.frame:Raise()
            return
        end
    end

    -- Find first available pooled instance
    local inst
    for _, candidate in ipairs(PE.pool) do
        if not candidate.inUse then
            inst = candidate
            break
        end
    end

    -- Create new instance if pool has room
    if not inst then
        if #PE.pool >= D().MAX_POPUP_EDITORS then
            GRIPEMS:Print(string.format(L["GEMS_UI_POPUP_MAX_REACHED"], D().MAX_POPUP_EDITORS))
            return
        end
        inst = PE:CreateInstance(#PE.pool + 1)
        PE.pool[#PE.pool + 1] = inst
    end

    PE:LoadSequence(inst, seqName)
    inst.frame:Show()
    inst.frame:Raise()
    inst.frame:SetFrameLevel(100 + inst.index * 10)
end

---------------------------------------------------------------------------
-- Instance creation
---------------------------------------------------------------------------

--- Build the frame tree for one popup editor instance.
--- @param index number Pool index (1-based)
--- @return table Instance table
function PE:CreateInstance(index)
    local C = UI.Colors
    local defaults = D()
    local frameName = "GRIPEMS_PopupEditor" .. index

    local inst = {
        index = index,
        inUse = false,
        currentSequence = nil,
        isDirty = false,
        activeVersionIndex = 1,
        workingSteps = {},
        workingActions = nil, -- v1.2.0 S14-B: stored but not edited in popup
        _updatingFromSelf = false,
        undoStack = nil, -- created lazily via GetUndoStack
        _suppressUndo = false,
    }

    -- Cascade offset: each subsequent popup shifts right and down
    local offsetX = (index - 1) * 30
    local offsetY = (index - 1) * -30

    -----------------------------------------------------------------------
    -- Main frame
    -----------------------------------------------------------------------
    local frame = CreateFrame("Frame", frameName, UIParent, "BackdropTemplate")
    frame:SetSize(defaults.POPUP_EDITOR_WIDTH, defaults.POPUP_EDITOR_HEIGHT)
    frame:SetPoint("CENTER", UIParent, "CENTER", offsetX, offsetY)
    frame:SetFrameStrata("DIALOG")
    UI:ApplyBackdrop(frame, UI.Backdrops.panel, C.bgMain, C.border)
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:SetResizable(true)
    frame:SetResizeBounds(defaults.POPUP_EDITOR_MIN_WIDTH, defaults.POPUP_EDITOR_MIN_HEIGHT)
    frame:Hide()
    inst.frame = frame

    -- ESC to close
    if not tContains(UISpecialFrames, frameName) then
        tinsert(UISpecialFrames, frameName)
    end

    -- Raise on click (any mouse interaction)
    frame:SetScript("OnMouseDown", function(self)
        self:Raise()
    end)

    -----------------------------------------------------------------------
    -- Title bar (32px)
    -----------------------------------------------------------------------
    local titleBar = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    titleBar:SetHeight(32)
    titleBar:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    titleBar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
    UI:ApplyBackdrop(titleBar, UI.Backdrops.panelNoBorder, C.bgDeep)
    inst.titleBar = titleBar

    -- Dragging via title bar
    titleBar:EnableMouse(true)
    titleBar:RegisterForDrag("LeftButton")
    titleBar:SetScript("OnDragStart", function()
        frame:StartMoving()
    end)
    titleBar:SetScript("OnDragStop", function()
        frame:StopMovingOrSizing()
    end)

    -- Title text
    local titleText = titleBar:CreateFontString(nil, "OVERLAY")
    UI:SetFont(titleText, 12, "OUTLINE")
    titleText:SetPoint("LEFT", titleBar, "LEFT", 8, 0)
    titleText:SetText(L["GEMS_UI_POPUP_TITLE"])
    titleText:SetTextColor(C.gripGreen:GetRGBA())
    inst.titleText = titleText

    -- Close button
    local closeBtn = CreateFrame("Button", nil, titleBar, "BackdropTemplate")
    closeBtn:SetSize(22, 22)
    closeBtn:SetPoint("TOPRIGHT", titleBar, "TOPRIGHT", -4, -5)
    UI:ApplyBackdrop(closeBtn, UI.Backdrops.panel, C.bgButton, C.border)
    local closeLbl = closeBtn:CreateFontString(nil, "OVERLAY")
    UI:SetFont(closeLbl, 12)
    closeLbl:SetPoint("CENTER", 0, 1)
    closeLbl:SetText("X")
    closeLbl:SetTextColor(C.textSecondary:GetRGBA())
    closeBtn:SetScript("OnClick", function()
        PE:CloseInstance(inst)
    end)
    closeBtn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(C.accent:GetRGBA())
        self:SetBackdropBorderColor(C.borderFocus:GetRGBA())
        closeLbl:SetTextColor(C.textPrimary:GetRGBA())
    end)
    closeBtn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(C.bgButton:GetRGBA())
        self:SetBackdropBorderColor(C.border:GetRGBA())
        closeLbl:SetTextColor(C.textSecondary:GetRGBA())
    end)

    -- Override frame OnHide to handle ESC close with dirty check
    frame:SetScript("OnHide", function()
        -- If hiding via ESC (UISpecialFrames), treat as close
        if inst.inUse and inst.isDirty then
            -- Re-show and prompt
            frame:Show()
            PE:PromptDirtyClose(inst)
        end
    end)

    -----------------------------------------------------------------------
    -- Resize grip
    -----------------------------------------------------------------------
    local resizeGrip = CreateFrame("Button", nil, frame)
    resizeGrip:SetSize(16, 16)
    resizeGrip:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -2, 2)
    resizeGrip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    resizeGrip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    resizeGrip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    resizeGrip:SetScript("OnMouseDown", function()
        frame:StartSizing("BOTTOMRIGHT")
    end)
    resizeGrip:SetScript("OnMouseUp", function()
        frame:StopMovingOrSizing()
    end)

    -----------------------------------------------------------------------
    -- Keyboard navigation
    -----------------------------------------------------------------------
    frame:EnableKeyboard(true)
    frame:SetScript("OnKeyDown", function(self, key)
        -- Skip when an EditBox has focus
        local focus = GetCurrentKeyBoardFocus()
        if focus then
            self:SetPropagateKeyboardInput(true)
            return
        end

        -- Ctrl+Z: Undo
        if key == "Z" and IsControlKeyDown() and not IsShiftKeyDown() then
            local us = GetUndoStack(inst)
            if us and us:CanUndo() then
                us:Undo(inst)
            end
            self:SetPropagateKeyboardInput(false)
            return
        end

        -- Ctrl+Y / Ctrl+Shift+Z: Redo
        if (key == "Y" and IsControlKeyDown()) or (key == "Z" and IsControlKeyDown() and IsShiftKeyDown()) then
            local us = GetUndoStack(inst)
            if us and us:CanRedo() then
                us:Redo(inst)
            end
            self:SetPropagateKeyboardInput(false)
            return
        end

        -- Alt+Up/Down: Move step
        if (key == "UP" or key == "DOWN") and IsAltKeyDown() then
            if inst.selectedStepIndex then
                local dir = key == "UP" and -1 or 1
                PE:MoveStep(inst, dir)
            end
            self:SetPropagateKeyboardInput(false)
            return
        end

        -- Up/Down: Step navigation
        if key == "UP" or key == "DOWN" then
            local count = #inst.workingSteps
            if count > 0 then
                local cur = inst.selectedStepIndex or 0
                local newIdx
                if key == "UP" then
                    newIdx = cur > 1 and (cur - 1) or count
                else
                    newIdx = cur < count and (cur + 1) or 1
                end
                inst.selectedStepIndex = newIdx
                PE:RefreshStepList(inst)
            end
            self:SetPropagateKeyboardInput(false)
            return
        end

        -- All other keys: propagate
        self:SetPropagateKeyboardInput(true)
    end)

    -----------------------------------------------------------------------
    -- Header area (icon + name + save/discard)
    -----------------------------------------------------------------------
    local headerArea = CreateFrame("Frame", nil, frame)
    headerArea:SetHeight(42)
    headerArea:SetPoint("TOPLEFT", titleBar, "BOTTOMLEFT", 0, 0)
    headerArea:SetPoint("TOPRIGHT", titleBar, "BOTTOMRIGHT", 0, 0)
    inst.headerArea = headerArea

    -- Icon (32x32)
    local iconTex = headerArea:CreateTexture(nil, "ARTWORK")
    iconTex:SetSize(32, 32)
    iconTex:SetPoint("TOPLEFT", headerArea, "TOPLEFT", 8, -5)
    inst.iconTex = iconTex

    -- Name label (read-only FontString)
    local nameLabel = headerArea:CreateFontString(nil, "OVERLAY")
    UI:SetFont(nameLabel, 14, "OUTLINE")
    nameLabel:SetPoint("LEFT", iconTex, "RIGHT", 8, 0)
    nameLabel:SetTextColor(C.textPrimary:GetRGBA())
    nameLabel:SetText("")
    inst.nameLabel = nameLabel

    -- Save button (visible when dirty)
    local saveBtn = UI:CreateButton(headerArea, L["GEMS_UI_SAVE"], 60, 22)
    saveBtn:SetPoint("TOPRIGHT", headerArea, "TOPRIGHT", -8, -10)
    saveBtn:SetBackdropColor(C.bgSave:GetRGBA())
    saveBtn:SetScript("OnClick", function()
        if GRIPEMS.OOCQueue.IsRestricted() then
            return
        end
        PE:SaveSequence(inst)
    end)
    saveBtn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(C.bgSaveHover:GetRGBA())
        self:SetBackdropBorderColor(C.borderFocus:GetRGBA())
        if GRIPEMS.OOCQueue.IsRestricted() then
            UI:ShowTooltip(self, L["GEMS_UI_SAVE"], L["GEMS_UI_SAVE_COMBAT"])
        else
            UI:ShowTooltip(self, L["GEMS_UI_SAVE"], L["GEMS_UI_SAVE_BTN_DESC"])
        end
    end)
    saveBtn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(C.bgSave:GetRGBA())
        self:SetBackdropBorderColor(C.border:GetRGBA())
        UI:HideTooltip()
    end)
    saveBtn:Hide()
    inst.saveBtn = saveBtn

    -- Discard button (visible when dirty)
    local discardBtn = UI:CreateButton(headerArea, L["GEMS_UI_DISCARD"], 60, 22)
    discardBtn:SetPoint("RIGHT", saveBtn, "LEFT", -2, 0)
    discardBtn:SetScript("OnClick", function()
        if inst.currentSequence then
            PE:LoadSequence(inst, inst.currentSequence)
        end
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
    inst.discardBtn = discardBtn

    -----------------------------------------------------------------------
    -- Step function toggle row
    -----------------------------------------------------------------------
    local sfRow = CreateFrame("Frame", nil, frame)
    sfRow:SetHeight(26)
    sfRow:SetPoint("TOPLEFT", headerArea, "BOTTOMLEFT", 8, -2)
    sfRow:SetPoint("TOPRIGHT", headerArea, "BOTTOMRIGHT", -8, -2)
    inst.sfRow = sfRow

    local sfLabel = sfRow:CreateFontString(nil, "OVERLAY")
    UI:SetFont(sfLabel, 10)
    sfLabel:SetPoint("LEFT", sfRow, "LEFT", 0, 0)
    sfLabel:SetText(L["GEMS_UI_STEP_FUNCTION"])
    sfLabel:SetTextColor(C.textSecondary:GetRGBA())

    local sfTypes = { "Sequential", "Random", "Priority", "ReversePriority" }
    local sfLabelsMap = {
        Sequential = L["GEMS_UI_SF_SEQUENTIAL"],
        Random = L["GEMS_UI_SF_RANDOM"],
        Priority = L["GEMS_UI_SF_PRIORITY"],
        ReversePriority = L["GEMS_UI_SF_REVERSEPRIORITY"],
    }
    inst.sfButtons = {}
    local prevSfBtn
    for _, sfName in ipairs(sfTypes) do
        local btn = UI:CreateButton(sfRow, sfLabelsMap[sfName] or sfName, 68, 22)
        if prevSfBtn then
            btn:SetPoint("LEFT", prevSfBtn, "RIGHT", 2, 0)
        else
            btn:SetPoint("LEFT", sfLabel, "RIGHT", 8, 0)
        end
        btn._sfName = sfName
        btn:SetScript("OnClick", function(self)
            PE:SetStepFunction(inst, self._sfName)
        end)
        btn:SetScript("OnEnter", function(self)
            local key = "GEMS_STEPFUNC_" .. self._sfName:upper() .. "_DESC"
            UI:ShowTooltip(self, sfLabelsMap[self._sfName] or self._sfName, L[key] or "")
            self:SetBackdropColor(C.bgRowHover:GetRGBA())
            self:SetBackdropBorderColor(C.borderFocus:GetRGBA())
        end)
        btn:SetScript("OnLeave", function()
            PE:UpdateSfButtons(inst)
            UI:HideTooltip()
        end)
        inst.sfButtons[sfName] = btn
        prevSfBtn = btn
    end

    -----------------------------------------------------------------------
    -- Version bar
    -----------------------------------------------------------------------
    local versionBar = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    versionBar:SetHeight(24)
    versionBar:SetPoint("TOPLEFT", sfRow, "BOTTOMLEFT", -8, -2)
    versionBar:SetPoint("TOPRIGHT", sfRow, "BOTTOMRIGHT", 8, -2)
    UI:ApplyBackdrop(versionBar, UI.Backdrops.panelNoBorder, C.bgDeep)
    inst.versionBar = versionBar

    local versionBtn = UI:CreateButton(versionBar, string.format(L["GEMS_VERSION_OF"], 1, 1), 120, 20)
    versionBtn:SetPoint("LEFT", versionBar, "LEFT", 8, 0)
    versionBtn:SetScript("OnClick", function(self)
        if not inst.currentSequence then
            return
        end
        local engine = GRIPEMS.Engine
        if not engine or not engine.sequences then
            return
        end
        local entry = engine.sequences[inst.currentSequence]
        if not entry or not entry.data or not entry.data.versions then
            return
        end
        MenuUtil.CreateContextMenu(self, function(_, rootDescription)
            for i = 1, #entry.data.versions do
                local lbl = string.format(L["GEMS_VERSION_LABEL"], i)
                if i == (entry.data.defaultVersion or 1) then
                    lbl = lbl .. L["GEMS_VERSION_DEFAULT_SUFFIX"]
                end
                rootDescription:CreateButton(lbl, function()
                    PE:SwitchVersion(inst, i)
                end)
            end
        end)
    end)
    versionBtn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(C.bgRowHover:GetRGBA())
        self:SetBackdropBorderColor(C.borderFocus:GetRGBA())
        UI:ShowTooltip(self, L["GEMS_VERSION_TOOLTIP_TITLE"], L["GEMS_VERSION_TOOLTIP_DESC"])
    end)
    versionBtn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(C.bgButton:GetRGBA())
        self:SetBackdropBorderColor(C.border:GetRGBA())
        UI:HideTooltip()
    end)
    inst.versionBtn = versionBtn

    -----------------------------------------------------------------------
    -- Tab bar (Steps only for v1)
    -----------------------------------------------------------------------
    local tabBar = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    tabBar:SetHeight(24)
    tabBar:SetPoint("TOPLEFT", versionBar, "BOTTOMLEFT", 0, 0)
    tabBar:SetPoint("TOPRIGHT", versionBar, "BOTTOMRIGHT", 0, 0)
    UI:ApplyBackdrop(tabBar, UI.Backdrops.panelNoBorder, C.bgDeep)
    inst.tabBar = tabBar

    local stepsTab = CreateFrame("Button", nil, tabBar, "BackdropTemplate")
    stepsTab:SetSize(60, 24)
    stepsTab:SetPoint("LEFT", tabBar, "LEFT", 4, 0)
    stepsTab:SetBackdrop(UI.Backdrops.panelNoBorder)
    stepsTab:SetBackdropColor(C.accent:GetRGBA())
    local stepsTabLbl = stepsTab:CreateFontString(nil, "OVERLAY")
    UI:SetFont(stepsTabLbl, 11)
    stepsTabLbl:SetPoint("CENTER")
    stepsTabLbl:SetText(L["GEMS_UI_TAB_STEPS"])
    stepsTabLbl:SetTextColor(C.textPrimary:GetRGBA())

    -----------------------------------------------------------------------
    -- Content area: scrollable step list with inline EditBoxes
    -----------------------------------------------------------------------
    local contentArea = CreateFrame("Frame", nil, frame)
    contentArea:SetPoint("TOPLEFT", tabBar, "BOTTOMLEFT", 0, 0)
    contentArea:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -1, 36)
    inst.contentArea = contentArea

    -- ScrollBox for steps
    local stepScrollBox = CreateFrame("Frame", nil, contentArea, "WowScrollBoxList")
    stepScrollBox:SetPoint("TOPLEFT", contentArea, "TOPLEFT", 4, -4)
    stepScrollBox:SetPoint("BOTTOMRIGHT", contentArea, "BOTTOMRIGHT", -18, 4)
    inst.stepScrollBox = stepScrollBox

    local stepScrollBar = CreateFrame("EventFrame", nil, contentArea, "MinimalScrollBar")
    stepScrollBar:SetPoint("TOPLEFT", stepScrollBox, "TOPRIGHT", 2, 0)
    stepScrollBar:SetPoint("BOTTOMLEFT", stepScrollBox, "BOTTOMRIGHT", 2, 0)

    local stepScrollView = CreateScrollBoxListLinearView()
    stepScrollView:SetElementExtent(D().STEP_ROW_HEIGHT)
    stepScrollView:SetElementInitializer("Frame", function(rowFrame, data)
        InitPopupStepRow(rowFrame, data, inst)
    end)
    ScrollUtil.InitScrollBoxListWithScrollBar(stepScrollBox, stepScrollBar, stepScrollView)
    stepScrollBox:SetDataProvider(CreateDataProvider())

    -----------------------------------------------------------------------
    -- Bottom action buttons
    -----------------------------------------------------------------------
    local actionBar = CreateFrame("Frame", nil, frame)
    actionBar:SetHeight(30)
    actionBar:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 1, 1)
    actionBar:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -1, 1)
    inst.actionBar = actionBar

    local addBtn = UI:CreateButton(actionBar, L["GEMS_UI_ADD_STEP"], 60, 24)
    addBtn:SetPoint("LEFT", actionBar, "LEFT", 8, 0)
    addBtn:SetScript("OnClick", function()
        PE:AddStep(inst)
    end)
    inst.addStepBtn = addBtn

    local delBtn = UI:CreateButton(actionBar, L["GEMS_UI_DEL_STEP"], 40, 24)
    delBtn:SetPoint("LEFT", addBtn, "RIGHT", 4, 0)
    delBtn:SetScript("OnClick", function()
        PE:DeleteStep(inst)
    end)
    inst.delStepBtn = delBtn

    local upBtn = UI:CreateButton(actionBar, L["GEMS_UI_MOVE_UP"], 40, 24)
    upBtn:SetPoint("LEFT", delBtn, "RIGHT", 4, 0)
    upBtn:SetScript("OnClick", function()
        PE:MoveStep(inst, -1)
    end)
    inst.moveUpBtn = upBtn

    local downBtn = UI:CreateButton(actionBar, L["GEMS_UI_MOVE_DOWN"], 50, 24)
    downBtn:SetPoint("LEFT", upBtn, "RIGHT", 4, 0)
    downBtn:SetScript("OnClick", function()
        PE:MoveStep(inst, 1)
    end)
    inst.moveDownBtn = downBtn

    -----------------------------------------------------------------------
    -- Register SEQUENCE_UPDATED callback for this instance
    -----------------------------------------------------------------------
    if GRIPEMS.RegisterCallback then
        inst._callbackKey = "PopupEditor_" .. index
        inst._sequenceUpdatedCB = function(_, seqName)
            if inst._updatingFromSelf then
                return
            end
            if inst.inUse and inst.currentSequence == seqName then
                if not inst.isDirty then
                    PE:LoadSequence(inst, seqName)
                end
            end
        end
        -- Do NOT register here -- registered in LoadSequence when opened
    end

    return inst
end

---------------------------------------------------------------------------
-- Step row initializer (ScrollBox element, per-instance)
---------------------------------------------------------------------------

InitPopupStepRow = function(row, data, inst)
    local C = UI.Colors

    if not row._initialized then
        local ROW_HEIGHT = D().STEP_ROW_HEIGHT
        row:SetHeight(ROW_HEIGHT)

        local numLabel = row:CreateFontString(nil, "OVERLAY")
        UI:SetFont(numLabel, 10)
        numLabel:SetPoint("LEFT", row, "LEFT", 4, 0)
        numLabel:SetWidth(28)
        numLabel:SetTextColor(C.textSecondary:GetRGBA())
        row.numLabel = numLabel

        local editBox = CreateFrame("EditBox", nil, row, "BackdropTemplate")
        editBox:SetPoint("LEFT", numLabel, "RIGHT", 4, 0)
        editBox:SetPoint("RIGHT", row, "RIGHT", -62, 0)
        editBox:SetHeight(ROW_HEIGHT - 2)
        editBox:SetAutoFocus(false)
        editBox:SetMultiLine(false)
        editBox:SetMaxBytes(255)
        UI:ApplyBackdrop(editBox, UI.Backdrops.panel, C.bgInput, C.border)
        editBox:SetTextInsets(4, 4, 2, 2)
        local fontPath = GameFontNormal:GetFont()
        editBox:SetFont(fontPath, 11, "")
        editBox:SetTextColor(C.textPrimary:GetRGBA())
        row.editBox = editBox

        local spPickerBtn = CreateFrame("Button", nil, row)
        spPickerBtn:SetSize(16, 16)
        spPickerBtn:SetPoint("LEFT", editBox, "RIGHT", 2, 0)
        spPickerBtn:SetNormalTexture("Interface\\Icons\\INV_Misc_Book_09")
        row.spellPickerBtn = spPickerBtn

        local charCount = row:CreateFontString(nil, "OVERLAY")
        UI:SetFont(charCount, 9)
        charCount:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        charCount:SetTextColor(C.textSuccess:GetRGBA())
        row.charCount = charCount

        -- Syntax highlighting hook
        local SH = GRIPEMS.SyntaxHighlight
        if SH then
            SH:HookEditBox(editBox, "macro")
        end

        -- OnTextChanged (reads dynamic _stepIndex/_inst)
        editBox:SetScript("OnTextChanged", function(self, userInput)
            if not userInput then
                return
            end
            local idx = self._stepIndex
            local instRef = self._inst
            if not instRef or not idx then
                return
            end
            local text = self:GetText() or ""
            instRef.workingSteps[idx] = text
            instRef.isDirty = true
            PE:UpdateSaveButtons(instRef)
            if row.charCount then
                row.charCount:SetText(tostring(#text))
                if #text >= D().CHAR_COUNT_DANGER then
                    row.charCount:SetTextColor(C.textError:GetRGBA())
                elseif #text >= D().CHAR_COUNT_WARNING then
                    row.charCount:SetTextColor(C.textWarning:GetRGBA())
                else
                    row.charCount:SetTextColor(C.textSuccess:GetRGBA())
                end
            end
        end)

        editBox:SetScript("OnEscapePressed", function(self)
            self:ClearFocus()
        end)

        editBox:SetScript("OnEditFocusGained", function(self)
            self:SetBackdropBorderColor(C.borderFocus:GetRGBA())
            local instRef = self._inst
            if instRef then
                instRef.selectedStepIndex = self._stepIndex
                instRef._undoTextSnapshot = instRef.workingSteps[self._stepIndex]
                instRef._undoTextSnapshotIdx = self._stepIndex
            end
        end)

        editBox:SetScript("OnEditFocusLost", function(self)
            self:SetBackdropBorderColor(C.border:GetRGBA())
            local instRef = self._inst
            if instRef and instRef._undoTextSnapshot ~= nil and not instRef._suppressUndo then
                local oldText = instRef._undoTextSnapshot
                local snapIdx = instRef._undoTextSnapshotIdx
                local newText = instRef.workingSteps and instRef.workingSteps[snapIdx]
                if newText and oldText ~= newText then
                    local us = GetUndoStack(instRef)
                    if us then
                        us:Push(function()
                            instRef.workingSteps[snapIdx] = oldText
                            instRef.selectedStepIndex = snapIdx
                            instRef.isDirty = true
                            PE:UpdateSaveButtons(instRef)
                            PE:RefreshStepList(instRef)
                        end, function()
                            instRef.workingSteps[snapIdx] = newText
                            instRef.selectedStepIndex = snapIdx
                            instRef.isDirty = true
                            PE:UpdateSaveButtons(instRef)
                            PE:RefreshStepList(instRef)
                        end, "Edit step text")
                    end
                end
                instRef._undoTextSnapshot = nil
                instRef._undoTextSnapshotIdx = nil
            end
        end)

        -- Tab autocomplete
        editBox:SetScript("OnTabPressed", function(self)
            local SLV = GRIPEMS.StepListView
            if not SLV then
                self:ClearFocus()
                return
            end
            local SC = GRIPEMS.SpellCache
            if not SC or not SC.ready then
                self:ClearFocus()
                return
            end
            local text = self:GetText() or ""
            local cursorPos = self:GetCursorPosition()
            if cursorPos == 0 or text == "" then
                self:ClearFocus()
                return
            end
            local wordStart = cursorPos
            while wordStart > 1 and text:sub(wordStart - 1, wordStart - 1):match("[%w_/#]") do
                wordStart = wordStart - 1
            end
            local word = text:sub(wordStart, cursorPos)
            if word == "" then
                self:ClearFocus()
                return
            end

            local charBefore = (wordStart > 1) and text:sub(wordStart - 1, wordStart - 1) or ""
            local isVarComplete = (charBefore == "~")
            if not isVarComplete and word:sub(1, 1) == "~" then
                isVarComplete = true
                word = word:sub(2)
            end

            if isVarComplete then
                local VS = GRIPEMS.VariableStore
                if not VS then
                    self:ClearFocus()
                    return
                end
                local store = VS:GetAll()
                local varMatches = {}
                local prefix = word:lower()
                for varName in pairs(store) do
                    if prefix == "" or varName:lower():sub(1, #prefix) == prefix then
                        varMatches[#varMatches + 1] = { name = varName }
                    end
                end
                table.sort(varMatches, function(a, b)
                    return a.name < b.name
                end)
                if #varMatches > D().AUTOCOMPLETE_MAX_RESULTS then
                    local trimmed = {}
                    for i = 1, D().AUTOCOMPLETE_MAX_RESULTS do
                        trimmed[i] = varMatches[i]
                    end
                    varMatches = trimmed
                end
                if #varMatches == 0 then
                    self:ClearFocus()
                    return
                end
                local tildeStart = charBefore == "~" and (wordStart - 1) or wordStart
                SLV:ShowVarAutocompleteMenu(self, varMatches, tildeStart, cursorPos)
                return
            end

            local firstChar = word:sub(1, 1)
            local isCommand = (firstChar == "/" or firstChar == "#")
            local minChars = isCommand and D().AUTOCOMPLETE_MIN_CHARS or D().AUTOCOMPLETE_MIN_SPELL_CHARS
            if #word < minChars then
                self:ClearFocus()
                return
            end

            local matches
            if isCommand then
                matches = SC:MacroCommandSearch(word, D().AUTOCOMPLETE_MAX_RESULTS)
            else
                matches = SC:PrefixSearch(word, D().AUTOCOMPLETE_MAX_RESULTS)
            end
            if #matches == 0 then
                if #word >= D().AUTOCOMPLETE_MIN_SEQ_CHARS then
                    local seqMatches = SLV:SearchSequenceNames(word)
                    if #seqMatches > 0 then
                        SLV:ShowSeqAutocompleteMenu(self, seqMatches, wordStart, cursorPos)
                        return
                    end
                end
                self:ClearFocus()
                return
            end
            SLV:ShowAutocompleteMenu(self, matches, wordStart, cursorPos)
        end)

        row._initialized = true
    end

    -- Update dynamic references (critical: avoids stale closures)
    row._inst = inst
    row._stepIndex = data.index
    row.editBox._inst = inst
    row.editBox._stepIndex = data.index

    -- Number label
    row.numLabel:SetText(string.format(L["GEMS_UI_STEP_NUM"], data.index))

    -- Set text without triggering OnTextChanged
    local editBox = row.editBox
    local prevScript = editBox:GetScript("OnTextChanged")
    editBox:SetScript("OnTextChanged", nil)
    editBox:SetText(data.text or "")
    editBox:SetScript("OnTextChanged", prevScript)

    -- Char count
    local len = #(data.text or "")
    row.charCount:SetText(tostring(len))
    if len >= D().CHAR_COUNT_DANGER then
        row.charCount:SetTextColor(C.textError:GetRGBA())
    elseif len >= D().CHAR_COUNT_WARNING then
        row.charCount:SetTextColor(C.textWarning:GetRGBA())
    else
        row.charCount:SetTextColor(C.textSuccess:GetRGBA())
    end

    -- Spell picker button
    row.spellPickerBtn:SetScript("OnClick", function(self)
        local SPicker = GRIPEMS.SpellPicker
        if SPicker then
            SPicker:Toggle(editBox, self)
        end
    end)
end

---------------------------------------------------------------------------
-- Step list rendering
---------------------------------------------------------------------------

--- Refresh the step list display for a popup instance.
--- @param inst table Popup instance
function PE:RefreshStepList(inst)
    if not inst.stepScrollBox then
        return
    end
    local dp = CreateDataProvider()
    for i, stepText in ipairs(inst.workingSteps) do
        dp:Insert({ index = i, text = stepText })
    end
    inst.stepScrollBox:SetDataProvider(dp)
end

---------------------------------------------------------------------------
-- Load / Save / Close
---------------------------------------------------------------------------

--- Load a sequence into a popup instance.
--- @param inst table Popup instance
--- @param seqName string Sequence name
function PE:LoadSequence(inst, seqName)
    local engine = GRIPEMS.Engine
    if not engine or not engine.sequences then
        return
    end
    local entry = engine.sequences[seqName]
    if not entry or not entry.data then
        return
    end

    inst.inUse = true
    inst.currentSequence = seqName
    inst.isDirty = false
    inst.activeVersionIndex = entry.data.defaultVersion or 1
    inst.selectedStepIndex = nil

    -- Register SEQUENCE_UPDATED callback for this active instance
    if GRIPEMS.RegisterCallback and inst._sequenceUpdatedCB then
        GRIPEMS.RegisterCallback(inst, "SEQUENCE_UPDATED", inst._sequenceUpdatedCB, inst._callbackKey)
    end

    if inst.undoStack then
        inst.undoStack:Clear()
    end

    local seqData = entry.data
    local ver = seqData.versions and seqData.versions[inst.activeVersionIndex]
    if not ver then
        ver = seqData.versions and seqData.versions[1]
        inst.activeVersionIndex = 1
    end

    -- Deep-copy steps
    inst.workingSteps = DeepCopySteps(ver and ver.steps or {})

    -- Store actions tree if present (flat-only editing in popup for v1.2.0)
    -- Backlog: S14-C tree-mode editing in popup editor
    local DD = GRIPEMS.Defaults
    if ver and ver.actions and #ver.actions > 0 then
        inst.workingActions = DD.DeepCopyActions(ver.actions)
    else
        inst.workingActions = nil
    end

    -- Store step function from version for tracking changes
    inst.workingStepFunction = ver and ver.stepFunction or "Sequential"

    -- Update title
    if inst.titleText then
        inst.titleText:SetText(L["GEMS_UI_POPUP_TITLE"] .. " - " .. seqName)
    end

    -- Update icon
    if inst.iconTex then
        inst.iconTex:SetTexture(ResolvePopupIcon(seqData))
    end

    -- Update name
    if inst.nameLabel then
        inst.nameLabel:SetText(seqName)
    end

    -- Update step function buttons
    PE:UpdateSfButtons(inst)

    -- Update version bar
    PE:RefreshVersionBar(inst)

    -- Refresh step list
    PE:RefreshStepList(inst)

    -- Update save buttons
    PE:UpdateSaveButtons(inst)
end

--- Save the working copy back to the Engine.
--- @param inst table Popup instance
function PE:SaveSequence(inst)
    if not inst.currentSequence then
        return
    end

    local engine = GRIPEMS.Engine
    if not engine or not engine.sequences then
        return
    end
    local entry = engine.sequences[inst.currentSequence]
    if not entry or not entry.data then
        return
    end

    local oldData = entry.data
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
        help = oldData.help or "",
        helplink = oldData.helplink or "",
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
        local activeIdx = inst.activeVersionIndex
        for i, ver in ipairs(oldData.versions) do
            newData.versions[i] = {
                stepFunction = ver.stepFunction,
                steps = {},
                resetOnCombat = ver.resetOnCombat,
                resetOnTarget = ver.resetOnTarget,
                resetOnGear = ver.resetOnGear,
                resetOnSpec = ver.resetOnSpec,
                resetTimer = ver.resetTimer,
                keyPress = ver.keyPress or "",
                keyRelease = ver.keyRelease or "",
            }
            if i == activeIdx then
                -- Active version: use working steps and step function
                newData.versions[i].stepFunction = inst.workingStepFunction or ver.stepFunction
                for j, step in ipairs(inst.workingSteps) do
                    newData.versions[i].steps[j] = step
                end
                -- Preserve actions tree if present (v1.2.0 S14-B)
                if inst.workingActions then
                    local DD = GRIPEMS.Defaults
                    newData.versions[i].actions = DD.DeepCopyActions(inst.workingActions)
                end
            else
                for j, step in ipairs(ver.steps) do
                    newData.versions[i].steps[j] = step
                end
                -- Copy actions from non-active versions
                if ver.actions then
                    local DD = GRIPEMS.Defaults
                    newData.versions[i].actions = DD.DeepCopyActions(ver.actions)
                end
            end
        end
    end

    inst._updatingFromSelf = true
    engine:UpdateSequenceData(inst.currentSequence, newData)
    inst._updatingFromSelf = false

    -- Refresh SequenceList
    local SL = GRIPEMS.SequenceList
    if SL then
        SL:RefreshDataProvider()
    end

    inst.isDirty = false
    if inst.undoStack then
        inst.undoStack:Clear()
    end
    PE:UpdateSaveButtons(inst)

    -- Reload working baseline from saved data
    local savedEntry = engine.sequences[inst.currentSequence]
    if savedEntry and savedEntry.data then
        local savedVer = savedEntry.data.versions and savedEntry.data.versions[inst.activeVersionIndex]
        if savedVer then
            inst.workingSteps = DeepCopySteps(savedVer.steps or {})
            inst.workingStepFunction = savedVer.stepFunction or "Sequential"
        end
    end
    PE:RefreshStepList(inst)
end

--- Close a popup instance (with dirty check).
--- @param inst table Popup instance
function PE:CloseInstance(inst)
    if inst.isDirty then
        PE:PromptDirtyClose(inst)
        return
    end
    PE:HideAndRelease(inst)
end

--- Immediately hide and release a popup instance back to the pool.
--- @param inst table Popup instance
function PE:HideAndRelease(inst)
    inst.frame:SetScript("OnHide", nil)
    inst.frame:Hide()
    -- Unregister SEQUENCE_UPDATED callback while released
    if GRIPEMS.UnregisterCallback then
        GRIPEMS.UnregisterCallback(inst, "SEQUENCE_UPDATED")
    end
    inst.inUse = false
    inst.currentSequence = nil
    inst.isDirty = false
    if inst.undoStack then
        inst.undoStack:Clear()
    end
    inst.workingSteps = {}
    inst.selectedStepIndex = nil
    -- Re-attach the OnHide handler
    inst.frame:SetScript("OnHide", function()
        if inst.inUse and inst.isDirty then
            inst.frame:Show()
            PE:PromptDirtyClose(inst)
        end
    end)
end

--- Show a StaticPopup asking Save/Discard/Cancel for dirty close.
--- @param inst table Popup instance
function PE:PromptDirtyClose(inst)
    local dialogName = "GRIPEMS_POPUP_DIRTY_CLOSE_" .. inst.index
    if not StaticPopupDialogs[dialogName] then
        StaticPopupDialogs[dialogName] = {
            text = L["GEMS_UI_POPUP_CLOSE_DIRTY"],
            button1 = L["GEMS_UI_SAVE"],
            button2 = L["GEMS_UI_DISCARD"],
            button3 = CANCEL,
            OnAccept = function()
                if not GRIPEMS.OOCQueue.IsRestricted() then
                    PE:SaveSequence(inst)
                end
                PE:HideAndRelease(inst)
            end,
            OnCancel = function()
                -- Discard (button2 triggers OnCancel in 3-button dialogs)
                PE:HideAndRelease(inst)
            end,
            OnAlt = function()
                -- Cancel: do nothing, keep popup open
            end,
            timeout = 0,
            whileDead = true,
            hideOnEscape = true,
            preferredIndex = 3,
        }
    end
    StaticPopup_Show(dialogName)
end

---------------------------------------------------------------------------
-- UI state helpers
---------------------------------------------------------------------------

--- Update save/discard button visibility for a popup instance.
--- @param inst table Popup instance
function PE:UpdateSaveButtons(inst)
    if inst.isDirty then
        if inst.saveBtn then
            inst.saveBtn:Show()
        end
        if inst.discardBtn then
            inst.discardBtn:Show()
        end
    else
        if inst.saveBtn then
            inst.saveBtn:Hide()
        end
        if inst.discardBtn then
            inst.discardBtn:Hide()
        end
    end
end

--- Update step function toggle button highlights.
--- @param inst table Popup instance
function PE:UpdateSfButtons(inst)
    local C = UI.Colors
    local activeSf = inst.workingStepFunction or "Sequential"
    for sfName, btn in pairs(inst.sfButtons) do
        if sfName == activeSf then
            btn:SetBackdropColor(C.accent:GetRGBA())
            btn.label:SetTextColor(C.textPrimary:GetRGBA())
        else
            btn:SetBackdropColor(C.bgButton:GetRGBA())
            btn.label:SetTextColor(C.textSecondary:GetRGBA())
        end
    end
end

--- Set the step function for a popup instance.
--- @param inst table Popup instance
--- @param sfName string Step function name
function PE:SetStepFunction(inst, sfName)
    if inst.workingStepFunction == sfName then
        return
    end
    inst.workingStepFunction = sfName
    inst.isDirty = true
    PE:UpdateSfButtons(inst)
    PE:UpdateSaveButtons(inst)
end

--- Refresh the version bar label for a popup instance.
--- @param inst table Popup instance
function PE:RefreshVersionBar(inst)
    if not inst.currentSequence then
        return
    end
    local engine = GRIPEMS.Engine
    if not engine or not engine.sequences then
        return
    end
    local entry = engine.sequences[inst.currentSequence]
    if not entry or not entry.data or not entry.data.versions then
        return
    end
    local total = #entry.data.versions
    local idx = inst.activeVersionIndex or 1
    if inst.versionBtn then
        inst.versionBtn.label:SetText(string.format(L["GEMS_VERSION_OF"], idx, total))
    end
end

--- Switch version in a popup instance.
--- @param inst table Popup instance
--- @param idx number Version index
function PE:SwitchVersion(inst, idx)
    if not inst.currentSequence then
        return
    end
    if idx == inst.activeVersionIndex then
        return
    end
    -- If dirty, discard changes when switching versions
    inst.activeVersionIndex = idx
    inst.isDirty = false

    local engine = GRIPEMS.Engine
    if not engine or not engine.sequences then
        return
    end
    local entry = engine.sequences[inst.currentSequence]
    if not entry or not entry.data then
        return
    end
    local ver = entry.data.versions and entry.data.versions[idx]
    if not ver then
        return
    end
    inst.workingSteps = DeepCopySteps(ver.steps or {})
    inst.workingStepFunction = ver.stepFunction or "Sequential"

    PE:UpdateSfButtons(inst)
    PE:RefreshVersionBar(inst)
    PE:RefreshStepList(inst)
    PE:UpdateSaveButtons(inst)
end

---------------------------------------------------------------------------
-- Step editing operations
---------------------------------------------------------------------------

--- Add a new empty step to the popup instance.
--- @param inst table Popup instance
function PE:AddStep(inst)
    local insertIdx = inst.selectedStepIndex or (#inst.workingSteps + 1)
    local actualIdx
    if insertIdx > #inst.workingSteps then
        inst.workingSteps[#inst.workingSteps + 1] = ""
        actualIdx = #inst.workingSteps
    else
        table.insert(inst.workingSteps, insertIdx + 1, "")
        actualIdx = insertIdx + 1
    end
    inst.isDirty = true

    if not inst._suppressUndo then
        local us = GetUndoStack(inst)
        if us then
            local addedIdx = actualIdx
            us:Push(function()
                table.remove(inst.workingSteps, addedIdx)
                inst.isDirty = true
                inst.selectedStepIndex = nil
                PE:UpdateSaveButtons(inst)
                PE:RefreshStepList(inst)
            end, function()
                table.insert(inst.workingSteps, addedIdx, "")
                inst.isDirty = true
                inst.selectedStepIndex = addedIdx
                PE:UpdateSaveButtons(inst)
                PE:RefreshStepList(inst)
            end, "Add step")
        end
    end

    PE:UpdateSaveButtons(inst)
    PE:RefreshStepList(inst)
end

--- Delete the selected step from the popup instance.
--- @param inst table Popup instance
function PE:DeleteStep(inst)
    local idx = inst.selectedStepIndex
    if not idx or idx < 1 or idx > #inst.workingSteps then
        return
    end
    local removedText = inst.workingSteps[idx]
    table.remove(inst.workingSteps, idx)
    inst.isDirty = true
    inst.selectedStepIndex = nil

    if not inst._suppressUndo then
        local us = GetUndoStack(inst)
        if us then
            local delIdx = idx
            local delText = removedText
            us:Push(function()
                table.insert(inst.workingSteps, delIdx, delText)
                inst.isDirty = true
                inst.selectedStepIndex = delIdx
                PE:UpdateSaveButtons(inst)
                PE:RefreshStepList(inst)
            end, function()
                table.remove(inst.workingSteps, delIdx)
                inst.isDirty = true
                inst.selectedStepIndex = nil
                PE:UpdateSaveButtons(inst)
                PE:RefreshStepList(inst)
            end, "Delete step")
        end
    end

    PE:UpdateSaveButtons(inst)
    PE:RefreshStepList(inst)
end

--- Move a step up or down in the popup instance.
--- @param inst table Popup instance
--- @param direction number -1 for up, 1 for down
function PE:MoveStep(inst, direction)
    local idx = inst.selectedStepIndex
    if not idx then
        return
    end
    local newIdx = idx + direction
    if newIdx < 1 or newIdx > #inst.workingSteps then
        return
    end
    inst.workingSteps[idx], inst.workingSteps[newIdx] = inst.workingSteps[newIdx], inst.workingSteps[idx]
    inst.selectedStepIndex = newIdx
    inst.isDirty = true

    if not inst._suppressUndo then
        local us = GetUndoStack(inst)
        if us then
            local fi = idx
            local ti = newIdx
            us:Push(function()
                inst.workingSteps[fi], inst.workingSteps[ti] = inst.workingSteps[ti], inst.workingSteps[fi]
                inst.selectedStepIndex = fi
                inst.isDirty = true
                PE:UpdateSaveButtons(inst)
                PE:RefreshStepList(inst)
            end, function()
                inst.workingSteps[fi], inst.workingSteps[ti] = inst.workingSteps[ti], inst.workingSteps[fi]
                inst.selectedStepIndex = ti
                inst.isDirty = true
                PE:UpdateSaveButtons(inst)
                PE:RefreshStepList(inst)
            end, "Move step")
        end
    end

    PE:UpdateSaveButtons(inst)
    PE:RefreshStepList(inst)
end
