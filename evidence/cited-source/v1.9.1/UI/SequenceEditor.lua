-- GRIP-EMS: Sequence Editor
-- Right panel: editor header, tab bar, and content area for sequence editing

local ADDON_NAME, GRIPEMS = ...
local UI = GRIPEMS.UI
local L = LibStub("AceLocale-3.0"):GetLocale("GRIP-EMS")

-- Upvalue accessor for Defaults
local function D()
    return GRIPEMS.Defaults
end

GRIPEMS.SequenceEditor = {}
local SE = GRIPEMS.SequenceEditor

-- Runtime state
SE.currentSequence = nil
SE.activeTab = "Steps"
SE.isDirty = false
SE.activeVersionIndex = 1
SE.pendingVersionSwitch = nil

--- Return the version being edited (may differ from the engine default).
--- @param seqData table Sequence data with versions array
--- @return table|nil The version table for the current editor index
function SE:GetEditingVersion(seqData)
    if not seqData or not seqData.versions then
        return nil
    end
    local idx = SE.activeVersionIndex or 1
    return seqData.versions[idx] or seqData.versions[1]
end

---------------------------------------------------------------------------
-- Dependency scanner (S08b)
---------------------------------------------------------------------------

--- Scan the current sequence steps for variable and sequence references.
--- Returns a table with variables, sequences, and embeddedBy arrays.
--- @param seqData table Sequence data with versions
--- @return table { variables={...}, sequences={...}, embeddedBy={...} }
function SE:ScanDependencies(seqData)
    local result = {
        variables = {},
        sequences = {},
        embeddedBy = {},
    }
    if not seqData then
        return result
    end

    local ver = SE:GetEditingVersion(seqData)
    if not ver or not ver.steps then
        return result
    end

    -- Deduplicate sets
    local varSeen = {}
    local seqSeen = {}

    for _, step in ipairs(ver.steps) do
        if type(step) == "string" then
            -- Variable references: ~varname~
            for varName in step:gmatch("~([%w_]+)~") do
                if not varSeen[varName] then
                    varSeen[varName] = true
                    local status = "missing"
                    local VS = GRIPEMS.VariableStore
                    if VS then
                        local allVars = VS:GetAll()
                        if allVars and allVars[varName] then
                            status = "found"
                        end
                    end
                    result.variables[#result.variables + 1] = { name = varName, status = status }
                end
            end
            -- Sequence references: /click GRIPEMS_SeqName
            for btnName in step:gmatch("/click%s+GRIPEMS_(%S+)") do
                -- Strip trailing whitespace or punctuation
                btnName = btnName:gsub("[%s%p]+$", "")
                if not seqSeen[btnName] then
                    seqSeen[btnName] = true
                    local status = "missing"
                    local engine = GRIPEMS.Engine
                    if engine and engine.sequences and engine.sequences[btnName] then
                        status = "found"
                    end
                    result.sequences[#result.sequences + 1] = { name = btnName, status = status }
                end
            end
        end
    end

    -- Reverse scan: which other sequences embed this one
    local currentName = seqData.name
    if currentName and currentName ~= "" then
        local engine = GRIPEMS.Engine
        if engine and engine.sequences then
            local clickPattern = "/click%s+GRIPEMS_" .. currentName:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
            for otherName, otherEntry in pairs(engine.sequences) do
                if otherName ~= currentName and otherEntry and otherEntry.data then
                    local otherData = otherEntry.data
                    if otherData.versions then
                        local found = false
                        local otherVer = engine:GetActiveVersion(otherData)
                        if otherVer and otherVer.steps then
                            for _, step in ipairs(otherVer.steps) do
                                if type(step) == "string" and step:find(clickPattern) then
                                    found = true
                                    break
                                end
                            end
                        end
                        if found then
                            result.embeddedBy[#result.embeddedBy + 1] = otherName
                        end
                    end
                end
            end
            table.sort(result.embeddedBy)
        end
    end

    return result
end

---------------------------------------------------------------------------
-- Initialization (called from UI:InitPanels)
---------------------------------------------------------------------------

--- Build the editor UI inside the right panel.
--- @param parentPanel Frame The MainFrame.rightPanel
function SE:Init(parentPanel)
    if not parentPanel then
        return
    end
    local C = UI.Colors

    -- Remove the placeholder text
    local mainFrame = GRIPEMS_MainFrame
    if mainFrame and mainFrame.rightPlaceholder then
        mainFrame.rightPlaceholder:Hide()
        mainFrame.rightPlaceholder:SetText("")
    end

    SE.container = parentPanel

    -- Register with ConsolePort cursor navigation (nil-safe)
    if ConsolePort and ConsolePort.AddInterfaceCursorFrame then
        ConsolePort:AddInterfaceCursorFrame(parentPanel)
    end

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
    UI:ApplyBackdrop(header, UI.Backdrops.panelNoBorder, C.bgMain)
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
    nameEditBox:SetAutoFocus(false)
    UI:ApplyBackdrop(nameEditBox, UI.Backdrops.panel, C.bgInput, C.border)
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
    nameEditBox:SetScript("OnEnter", function(eb)
        UI:ShowTooltip(eb, L["GEMS_UI_NAME_TOOLTIP"], L["GEMS_UI_NAME_EDIT_HINT"])
    end)
    nameEditBox:SetScript("OnLeave", function()
        UI:HideTooltip()
    end)
    SE.nameEditBox = nameEditBox

    -- Save button (visible only when dirty)
    local saveBtn = UI:CreateButton(header, L["GEMS_UI_SAVE"], 60, 24)
    saveBtn:SetBackdropColor(C.bgSave:GetRGBA())
    saveBtn:SetScript("OnClick", function()
        if GRIPEMS.OOCQueue.IsRestricted() then
            return
        end
        SE:SaveSequence()
        SE:UpdateSaveButtons()
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
    SE.saveBtn = saveBtn

    -- Discard button (visible only when dirty)
    local discardBtn = UI:CreateButton(header, L["GEMS_UI_DISCARD"], 60, 24)
    discardBtn:SetScript("OnClick", function()
        if not SE.currentSequence then
            return
        end
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
    exportBtn:SetScript("OnClick", function()
        if not SE.currentSequence then
            return
        end
        local GE = GRIPEMS.GRIPExport
        if not GE then
            return
        end
        local deps = GE.ResolveVariableDeps({ SE.currentSequence })
        if next(deps) then
            local EF = GRIPEMS.ExportFrame
            if EF then
                EF:Show(SE.currentSequence)
            end
        else
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
        end
    end)
    exportBtn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(C.bgRowHover:GetRGBA())
        self:SetBackdropBorderColor(C.borderFocus:GetRGBA())
        UI:ShowTooltip(self, L["GEMS_UI_EXPORT_BTN_EDITOR"], L["GEMS_UI_EXPORT_BTN_EDITOR_DESC"])
    end)
    exportBtn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(C.bgButton:GetRGBA())
        self:SetBackdropBorderColor(C.border:GetRGBA())
        UI:HideTooltip()
    end)
    SE.exportBtn = exportBtn

    -- Send button (after Export)
    local sendBtn = UI:CreateButton(header, L["GEMS_UI_SEND_BTN"], 70, 24)
    sendBtn:SetPoint("TOPRIGHT", header, "TOPRIGHT", -8, -12)
    sendBtn:SetScript("OnClick", function()
        if not SE.currentSequence then
            return
        end
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

    -- Record button (toggle recording via MacroRecorder)
    local recordBtn = UI:CreateButton(header, L["GEMS_UI_RECORD"], 70, 24)
    recordBtn:SetScript("OnClick", function()
        local MR = GRIPEMS.MacroRecorder
        if not MR then
            return
        end
        MR:Toggle()
        SE:UpdateRecordButton()
        if not MR.isRecording then
            -- Recording just stopped
            local count = MR:GetCount()
            if count > 0 then
                GRIPEMS:Print(string.format(L["GEMS_RECORDER_STOPPED"], count))
                SE:ShowRecordingConfirm(count)
            else
                GRIPEMS:Print(L["GEMS_RECORDER_EMPTY"])
            end
        end
    end)
    recordBtn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(C.bgRowHover:GetRGBA())
        self:SetBackdropBorderColor(C.borderFocus:GetRGBA())
    end)
    recordBtn:SetScript("OnLeave", function(self)
        SE:UpdateRecordButton()
        UI:HideTooltip()
    end)
    recordBtn:Hide()
    SE.recordBtn = recordBtn

    -- Wire up live count update callback
    local MR = GRIPEMS.MacroRecorder
    if MR then
        MR.onCountUpdate = function(count)
            if SE.recordBtn and SE.recordBtn:IsShown() then
                SE.recordBtn.label:SetText(string.format(L["GEMS_UI_RECORDING_COUNT"], count))
            end
        end
    end

    -- Right-to-left button chain from header TOPRIGHT
    -- sendBtn -> recordBtn -> exportBtn -> discardBtn -> saveBtn
    recordBtn:SetPoint("RIGHT", sendBtn, "LEFT", -2, 0)
    exportBtn:SetPoint("RIGHT", recordBtn, "LEFT", -2, 0)
    discardBtn:SetPoint("RIGHT", exportBtn, "LEFT", -4, 0)
    saveBtn:SetPoint("RIGHT", discardBtn, "LEFT", -2, 0)
    -- nameEditBox RIGHT: exportBtn when clean (save/discard start hidden)
    nameEditBox:SetPoint("RIGHT", exportBtn, "LEFT", -4, 0)

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
    cbCombat:SetScript("OnLeave", function()
        UI:HideTooltip()
    end)
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
    cbTarget:SetScript("OnLeave", function()
        UI:HideTooltip()
    end)
    SE.cbTarget = cbTarget

    local targetLabel = resetRow:CreateFontString(nil, "OVERLAY")
    UI:SetFont(targetLabel, 10)
    targetLabel:SetPoint("LEFT", cbTarget, "RIGHT", 2, 0)
    targetLabel:SetText(L["GEMS_UI_RESET_TARGET"])
    targetLabel:SetTextColor(C.textSecondary:GetRGBA())

    -- Reset conditions row 2 (gear, spec, timer)
    local resetRow2 = CreateFrame("Frame", nil, header)
    resetRow2:SetHeight(22)
    resetRow2:SetPoint("TOPLEFT", resetRow, "BOTTOMLEFT", 0, -2)
    resetRow2:SetPoint("TOPRIGHT", resetRow, "BOTTOMRIGHT", 0, -2)

    -- Gear checkbox
    local cbGear = CreateFrame("CheckButton", nil, resetRow2, "UICheckButtonTemplate")
    cbGear:SetSize(22, 22)
    cbGear:SetPoint("LEFT", resetRow2, "LEFT", 0, 0)
    cbGear:SetScript("OnClick", function(self)
        SE:OnResetToggled("gear", self:GetChecked())
    end)
    cbGear:SetScript("OnEnter", function(self)
        UI:ShowTooltip(self, L["GEMS_UI_RESET_GEAR"], L["GEMS_UI_RESET_GEAR_DESC"])
    end)
    cbGear:SetScript("OnLeave", function()
        UI:HideTooltip()
    end)
    SE.cbGear = cbGear

    local gearLabel = resetRow2:CreateFontString(nil, "OVERLAY")
    UI:SetFont(gearLabel, 10)
    gearLabel:SetPoint("LEFT", cbGear, "RIGHT", 2, 0)
    gearLabel:SetText(L["GEMS_UI_RESET_GEAR"])
    gearLabel:SetTextColor(C.textSecondary:GetRGBA())

    -- Spec checkbox
    local cbSpec = CreateFrame("CheckButton", nil, resetRow2, "UICheckButtonTemplate")
    cbSpec:SetSize(22, 22)
    cbSpec:SetPoint("LEFT", gearLabel, "RIGHT", 12, 0)
    cbSpec:SetScript("OnClick", function(self)
        SE:OnResetToggled("spec", self:GetChecked())
    end)
    cbSpec:SetScript("OnEnter", function(self)
        UI:ShowTooltip(self, L["GEMS_UI_RESET_SPEC"], L["GEMS_UI_RESET_SPEC_DESC"])
    end)
    cbSpec:SetScript("OnLeave", function()
        UI:HideTooltip()
    end)
    SE.cbSpec = cbSpec

    local specLabel = resetRow2:CreateFontString(nil, "OVERLAY")
    UI:SetFont(specLabel, 10)
    specLabel:SetPoint("LEFT", cbSpec, "RIGHT", 2, 0)
    specLabel:SetText(L["GEMS_UI_RESET_SPEC"])
    specLabel:SetTextColor(C.textSecondary:GetRGBA())

    -- Timer EditBox
    local timerLabel = resetRow2:CreateFontString(nil, "OVERLAY")
    UI:SetFont(timerLabel, 10)
    timerLabel:SetPoint("LEFT", specLabel, "RIGHT", 16, 0)
    timerLabel:SetText(L["GEMS_UI_RESET_TIMER"])
    timerLabel:SetTextColor(C.textSecondary:GetRGBA())

    local timerBox = CreateFrame("EditBox", nil, resetRow2, "InputBoxTemplate")
    timerBox:SetSize(40, 20)
    timerBox:SetPoint("LEFT", timerLabel, "RIGHT", 4, 0)
    timerBox:SetAutoFocus(false)
    timerBox:SetNumeric(true)
    timerBox:SetMaxLetters(4)
    timerBox:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
        local val = tonumber(self:GetText()) or 0
        if val < 0 then
            val = 0
        end
        self:SetText(tostring(val))
        SE:OnResetTimerChanged(val)
    end)
    timerBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)
    timerBox:SetScript("OnEnter", function(self)
        UI:ShowTooltip(self, L["GEMS_UI_RESET_TIMER"], L["GEMS_UI_RESET_TIMER_DESC"])
    end)
    timerBox:SetScript("OnLeave", function()
        UI:HideTooltip()
    end)
    SE.timerBox = timerBox

    -- KeyPress / KeyRelease row
    local kpRow = CreateFrame("Frame", nil, header)
    kpRow:SetHeight(90)
    kpRow:SetPoint("TOPLEFT", resetRow2, "BOTTOMLEFT", 0, -4)
    kpRow:SetPoint("TOPRIGHT", resetRow2, "BOTTOMRIGHT", 0, -4)

    -- KeyPress label
    local kpLabel = kpRow:CreateFontString(nil, "OVERLAY")
    UI:SetFont(kpLabel, 10)
    kpLabel:SetPoint("TOPLEFT", kpRow, "TOPLEFT", 0, 0)
    kpLabel:SetText(L["GEMS_UI_KEYPRESS"])
    kpLabel:SetTextColor(C.textSecondary:GetRGBA())

    -- KeyPress EditBox
    local kpScroll = CreateFrame("ScrollFrame", nil, kpRow)
    kpScroll:SetPoint("TOPLEFT", kpLabel, "BOTTOMLEFT", 0, -2)
    kpScroll:SetPoint("BOTTOMLEFT", kpRow, "BOTTOMLEFT", 0, 14)
    kpScroll:SetPoint("RIGHT", kpRow, "TOP", -4, 0)

    local kpEdit = CreateFrame("EditBox", nil, kpScroll, "BackdropTemplate")
    kpEdit:SetMultiLine(true)
    kpEdit:SetAutoFocus(false)
    UI:ApplyBackdrop(kpEdit, UI.Backdrops.panel, C.bgInput, C.border)
    kpEdit:SetTextInsets(6, 6, 4, 4)
    kpEdit:SetHeight(60)
    local kpFont = GameFontNormal:GetFont()
    kpEdit:SetFont(kpFont, 11, "")
    kpEdit:SetTextColor(C.textPrimary:GetRGBA())
    kpEdit:SetScript("OnTextChanged", function(self, userInput)
        if not userInput then
            return
        end
        SE:OnKeyPressChanged(self:GetText() or "")
        -- Auto-grow EditBox height for scrolling
        local text = self:GetText() or ""
        local numLines = 1
        if #text > 0 then
            numLines = select(2, text:gsub("\n", "\n")) + 1
        end
        local _, lineH = self:GetFont()
        lineH = lineH or 11
        local contentH = math.max(60, numLines * (lineH + 2) + 8)
        self:SetHeight(contentH)
    end)
    kpEdit:SetScript("OnEnter", function(self)
        UI:ShowTooltip(self, L["GEMS_UI_KEYPRESS"], L["GEMS_UI_KEYPRESS_DESC"])
    end)
    kpEdit:SetScript("OnLeave", function()
        UI:HideTooltip()
    end)
    kpScroll:SetScrollChild(kpEdit)
    kpScroll:SetScript("OnSizeChanged", function(self)
        local w = self:GetWidth()
        if w > 0 then
            kpEdit:SetWidth(w)
        end
    end)
    kpScroll:EnableMouseWheel(true)
    kpScroll:SetScript("OnMouseWheel", function(self, delta)
        local current = self:GetVerticalScroll()
        local maxScroll = self:GetVerticalScrollRange()
        local step = 20
        local newScroll = current - (delta * step)
        newScroll = math.max(0, math.min(newScroll, maxScroll))
        self:SetVerticalScroll(newScroll)
    end)
    SE.keyPressEditBox = kpEdit

    -- KeyPress status label (below keyPress EditBox)
    local kpStatus = kpRow:CreateFontString(nil, "OVERLAY")
    UI:SetFont(kpStatus, 9)
    kpStatus:SetPoint("TOPLEFT", kpScroll, "BOTTOMLEFT", 0, -1)
    kpStatus:SetTextColor(C.textSecondary:GetRGBA())
    SE.kpStatusLabel = kpStatus

    -- KeyRelease label
    local krLabel = kpRow:CreateFontString(nil, "OVERLAY")
    UI:SetFont(krLabel, 10)
    krLabel:SetPoint("TOPLEFT", kpRow, "TOP", 4, 0)
    krLabel:SetText(L["GEMS_UI_KEYRELEASE"])
    krLabel:SetTextColor(C.textSecondary:GetRGBA())

    -- KeyRelease EditBox
    local krScroll = CreateFrame("ScrollFrame", nil, kpRow)
    krScroll:SetPoint("TOPLEFT", krLabel, "BOTTOMLEFT", 0, -2)
    krScroll:SetPoint("BOTTOMLEFT", kpRow, "BOTTOM", 4, 14)
    krScroll:SetPoint("RIGHT", kpRow, "RIGHT", 0, 0)

    local krEdit = CreateFrame("EditBox", nil, krScroll, "BackdropTemplate")
    krEdit:SetMultiLine(true)
    krEdit:SetAutoFocus(false)
    UI:ApplyBackdrop(krEdit, UI.Backdrops.panel, C.bgInput, C.border)
    krEdit:SetTextInsets(6, 6, 4, 4)
    krEdit:SetHeight(60)
    local krFont = GameFontNormal:GetFont()
    krEdit:SetFont(krFont, 11, "")
    krEdit:SetTextColor(C.textPrimary:GetRGBA())
    krEdit:SetScript("OnTextChanged", function(self, userInput)
        if not userInput then
            return
        end
        SE:OnKeyReleaseChanged(self:GetText() or "")
        -- Auto-grow EditBox height for scrolling
        local text = self:GetText() or ""
        local numLines = 1
        if #text > 0 then
            numLines = select(2, text:gsub("\n", "\n")) + 1
        end
        local _, lineH = self:GetFont()
        lineH = lineH or 11
        local contentH = math.max(60, numLines * (lineH + 2) + 8)
        self:SetHeight(contentH)
    end)
    krEdit:SetScript("OnEnter", function(self)
        UI:ShowTooltip(self, L["GEMS_UI_KEYRELEASE"], L["GEMS_UI_KEYRELEASE_DESC"])
    end)
    krEdit:SetScript("OnLeave", function()
        UI:HideTooltip()
    end)
    krScroll:SetScrollChild(krEdit)
    krScroll:SetScript("OnSizeChanged", function(self)
        local w = self:GetWidth()
        if w > 0 then
            krEdit:SetWidth(w)
        end
    end)
    krScroll:EnableMouseWheel(true)
    krScroll:SetScript("OnMouseWheel", function(self, delta)
        local current = self:GetVerticalScroll()
        local maxScroll = self:GetVerticalScrollRange()
        local step = 20
        local newScroll = current - (delta * step)
        newScroll = math.max(0, math.min(newScroll, maxScroll))
        self:SetVerticalScroll(newScroll)
    end)
    SE.keyReleaseEditBox = krEdit

    -----------------------------------------------------------------------
    -- Macro Stub Preview (collapsible, between header and metadata)
    -----------------------------------------------------------------------
    local STUB_TOGGLE_HEIGHT = 18
    local STUB_CONTENT_HEIGHT = 60
    local stubSection = CreateFrame("Frame", nil, parentPanel)
    stubSection:SetHeight(STUB_TOGGLE_HEIGHT)
    stubSection:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, 0)
    stubSection:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, 0)
    stubSection:Hide()
    SE.stubSection = stubSection
    SE.stubExpanded = false

    local stubToggle = CreateFrame("Button", nil, stubSection)
    stubToggle:SetHeight(STUB_TOGGLE_HEIGHT)
    stubToggle:SetPoint("TOPLEFT", stubSection, "TOPLEFT", 0, 0)
    stubToggle:SetPoint("TOPRIGHT", stubSection, "TOPRIGHT", 0, 0)

    local stubArrow = stubToggle:CreateFontString(nil, "OVERLAY")
    UI:SetFont(stubArrow, 10)
    stubArrow:SetPoint("LEFT", stubToggle, "LEFT", 8, 0)
    stubArrow:SetText(">")
    stubArrow:SetTextColor(C.textSecondary:GetRGBA())
    SE.stubArrow = stubArrow

    local stubToggleLabel = stubToggle:CreateFontString(nil, "OVERLAY")
    UI:SetFont(stubToggleLabel, 10)
    stubToggleLabel:SetPoint("LEFT", stubArrow, "RIGHT", 4, 0)
    stubToggleLabel:SetText(L["GEMS_UI_STUB_PREVIEW"])
    stubToggleLabel:SetTextColor(C.textSecondary:GetRGBA())

    stubToggle:SetScript("OnEnter", function()
        stubToggleLabel:SetTextColor(C.textPrimary:GetRGBA())
        stubArrow:SetTextColor(C.textPrimary:GetRGBA())
    end)
    stubToggle:SetScript("OnLeave", function()
        stubToggleLabel:SetTextColor(C.textSecondary:GetRGBA())
        stubArrow:SetTextColor(C.textSecondary:GetRGBA())
    end)

    -- Stub content (disabled EditBox for copy support)
    local stubContent = CreateFrame("EditBox", nil, stubSection, "BackdropTemplate")
    stubContent:SetPoint("TOPLEFT", stubToggle, "BOTTOMLEFT", 8, -2)
    stubContent:SetPoint("RIGHT", stubSection, "RIGHT", -8, 0)
    stubContent:SetHeight(STUB_CONTENT_HEIGHT)
    stubContent:SetMultiLine(true)
    stubContent:SetAutoFocus(false)
    stubContent:EnableMouse(true)
    stubContent:EnableKeyboard(false)
    UI:ApplyBackdrop(stubContent, UI.Backdrops.panel, C.bgInput, C.border)
    stubContent:SetTextInsets(6, 6, 4, 4)
    stubContent:SetFont(fontPath, 10, "")
    stubContent:SetTextColor(C.textPrimary:GetRGBA())
    stubContent:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)
    stubContent:SetScript("OnMouseDown", function(self)
        self:EnableKeyboard(true)
        self:SetFocus()
        self:HighlightText()
    end)
    stubContent:SetScript("OnEditFocusLost", function(self)
        self:EnableKeyboard(false)
    end)
    stubContent:Hide()
    SE.stubContentBox = stubContent

    stubToggle:SetScript("OnClick", function()
        SE.stubExpanded = not SE.stubExpanded
        if SE.stubExpanded then
            stubSection:SetHeight(STUB_TOGGLE_HEIGHT + 2 + STUB_CONTENT_HEIGHT)
            stubContent:Show()
            stubArrow:SetText("v")
            SE:RefreshStubPreview()
        else
            stubSection:SetHeight(STUB_TOGGLE_HEIGHT)
            stubContent:Hide()
            stubArrow:SetText(">")
        end
    end)

    -----------------------------------------------------------------------
    -- Metadata section (collapsible, between stub preview and spell banner)
    -----------------------------------------------------------------------
    local META_TOGGLE_HEIGHT = 18
    local META_ROW_HEIGHT = 22
    local META_ROWS = 9
    local META_PAD = 4
    -- META_DESC_EXTRA defined later after MakeMetaEditRow calls
    local META_FULL = META_TOGGLE_HEIGHT + META_PAD + (META_ROW_HEIGHT * META_ROWS) + 40

    local metaSection = CreateFrame("Frame", nil, parentPanel)
    metaSection:SetHeight(META_TOGGLE_HEIGHT)
    metaSection:SetPoint("TOPLEFT", stubSection, "BOTTOMLEFT", 0, 0)
    metaSection:SetPoint("TOPRIGHT", stubSection, "BOTTOMRIGHT", 0, 0)
    metaSection:Hide()
    SE.metadataSection = metaSection
    SE.metadataExpanded = false

    -- Toggle bar
    local metaToggle = CreateFrame("Button", nil, metaSection)
    metaToggle:SetHeight(META_TOGGLE_HEIGHT)
    metaToggle:SetPoint("TOPLEFT", metaSection, "TOPLEFT", 0, 0)
    metaToggle:SetPoint("TOPRIGHT", metaSection, "TOPRIGHT", 0, 0)

    local metaArrow = metaToggle:CreateFontString(nil, "OVERLAY")
    UI:SetFont(metaArrow, 10)
    metaArrow:SetPoint("LEFT", metaToggle, "LEFT", 8, 0)
    metaArrow:SetText(">")
    metaArrow:SetTextColor(C.textSecondary:GetRGBA())
    SE.metaArrow = metaArrow

    local metaToggleLabel = metaToggle:CreateFontString(nil, "OVERLAY")
    UI:SetFont(metaToggleLabel, 10)
    metaToggleLabel:SetPoint("LEFT", metaArrow, "RIGHT", 4, 0)
    metaToggleLabel:SetText(L["GEMS_EDITOR_METADATA"])
    metaToggleLabel:SetTextColor(C.textSecondary:GetRGBA())

    metaToggle:SetScript("OnEnter", function()
        metaToggleLabel:SetTextColor(C.textPrimary:GetRGBA())
        metaArrow:SetTextColor(C.textPrimary:GetRGBA())
    end)
    metaToggle:SetScript("OnLeave", function()
        metaToggleLabel:SetTextColor(C.textSecondary:GetRGBA())
        metaArrow:SetTextColor(C.textSecondary:GetRGBA())
    end)
    metaToggle:SetScript("OnClick", function()
        SE.metadataExpanded = not SE.metadataExpanded
        if SE.metadataExpanded then
            local h = SE._metaFullHeight or META_FULL
            metaSection:SetHeight(h)
            SE.metadataContent:Show()
            metaArrow:SetText("v")
        else
            metaSection:SetHeight(META_TOGGLE_HEIGHT)
            SE.metadataContent:Hide()
            metaArrow:SetText(">")
        end
    end)

    -- Content area (hidden when collapsed)
    local metaContent = CreateFrame("Frame", nil, metaSection)
    metaContent:SetPoint("TOPLEFT", metaToggle, "BOTTOMLEFT", 0, -META_PAD)
    metaContent:SetPoint("TOPRIGHT", metaToggle, "BOTTOMRIGHT", 0, -META_PAD)
    metaContent:SetHeight(META_ROW_HEIGHT * META_ROWS + 40)
    metaContent:Hide()
    SE.metadataContent = metaContent

    -- Helper: create an editable metadata row (label + edit box)
    local metaFont = GameFontNormal:GetFont()
    local function MakeMetaEditRow(yOff, labelKey)
        local lbl = metaContent:CreateFontString(nil, "OVERLAY")
        UI:SetFont(lbl, 10)
        lbl:SetPoint("TOPLEFT", metaContent, "TOPLEFT", 8, yOff)
        lbl:SetText(L[labelKey])
        lbl:SetTextColor(C.textSecondary:GetRGBA())
        local box = CreateFrame("EditBox", nil, metaContent, "BackdropTemplate")
        box:SetHeight(20)
        box:SetPoint("TOPLEFT", metaContent, "TOPLEFT", 100, yOff - 1)
        box:SetWidth(200)
        box:SetAutoFocus(false)
        UI:ApplyBackdrop(box, UI.Backdrops.panel, C.bgInput, C.border)
        box:SetTextInsets(6, 6, 2, 2)
        box:SetFont(metaFont, 11, "")
        box:SetTextColor(C.textPrimary:GetRGBA())
        box:SetScript("OnEnterPressed", function(self)
            self:ClearFocus()
        end)
        box:SetScript("OnEscapePressed", function(self)
            self:ClearFocus()
        end)
        box:SetScript("OnTextChanged", function(self, userInput)
            if not userInput then
                return
            end
            SE:OnMetadataChanged()
        end)
        box:SetScript("OnEditFocusGained", function(self)
            self:SetBackdropBorderColor(C.borderFocus:GetRGBA())
        end)
        box:SetScript("OnEditFocusLost", function(self)
            self:SetBackdropBorderColor(C.border:GetRGBA())
        end)
        return box
    end

    -- Helper: create a read-only metadata row (label + font string)
    local function MakeMetaReadRow(yOff, labelKey)
        local lbl = metaContent:CreateFontString(nil, "OVERLAY")
        UI:SetFont(lbl, 10)
        lbl:SetPoint("TOPLEFT", metaContent, "TOPLEFT", 8, yOff)
        lbl:SetText(L[labelKey])
        lbl:SetTextColor(C.textSecondary:GetRGBA())
        local val = metaContent:CreateFontString(nil, "OVERLAY")
        UI:SetFont(val, 10)
        val:SetPoint("TOPLEFT", metaContent, "TOPLEFT", 100, yOff)
        val:SetTextColor(C.textPrimary:GetRGBA())
        return val
    end

    SE.metaAuthorBox = MakeMetaEditRow(0, "GEMS_EDITOR_METADATA_AUTHOR")
    SE.metaDescBox = MakeMetaEditRow(-META_ROW_HEIGHT, "GEMS_EDITOR_METADATA_DESCRIPTION")
    -- Convert description to multi-line (60px tall instead of 20)
    local META_DESC_EXTRA = 40
    SE.metaDescBox:SetMultiLine(true)
    SE.metaDescBox:SetHeight(60)
    SE.metaDescBox:SetMaxLetters(D().EXPORT_META_DESC_MAX)
    -- Shift remaining rows down to account for the taller description box
    local descShift = META_ROW_HEIGHT + META_DESC_EXTRA
    SE.metaHelpBox = MakeMetaEditRow(-(descShift + META_ROW_HEIGHT), "GEMS_EDITOR_METADATA_HELP")
    SE.metaHelpLinkBox = MakeMetaEditRow(-(descShift + META_ROW_HEIGHT * 2), "GEMS_EDITOR_METADATA_HELPLINK")
    SE.metaClassText = MakeMetaReadRow(-(descShift + META_ROW_HEIGHT * 3), "GEMS_EDITOR_METADATA_CLASS")
    SE.metaSpecText = MakeMetaReadRow(-(descShift + META_ROW_HEIGHT * 4), "GEMS_EDITOR_METADATA_SPEC")
    SE.metaCreatedText = MakeMetaReadRow(-(descShift + META_ROW_HEIGHT * 5), "GEMS_EDITOR_METADATA_CREATED")
    SE.metaUpdatedText = MakeMetaReadRow(-(descShift + META_ROW_HEIGHT * 6), "GEMS_EDITOR_METADATA_UPDATED")

    -- Hold Mode per-sequence toggle (below metadata rows, above dependencies)
    local holdCheckY = -(descShift + META_ROW_HEIGHT * 7)
    local holdCheck = CreateFrame("CheckButton", nil, metaContent, "UICheckButtonTemplate")
    holdCheck:SetPoint("TOPLEFT", metaContent, "TOPLEFT", 0, holdCheckY)
    holdCheck:SetSize(24, 24)
    local holdLabel = holdCheck:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    holdLabel:SetPoint("LEFT", holdCheck, "RIGHT", 4, 0)
    holdLabel:SetText(L["FS_HOLD_SEQ_TOGGLE"])
    holdCheck:SetScript("OnClick", function(self)
        local checked = self:GetChecked()
        local seqName = SE.currentSequence
        if seqName then
            local holdTA = GRIPEMS.TempoAdvisor
            if holdTA then
                holdTA:SetHoldMode(seqName, checked)
            end
        end
    end)
    holdCheck:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(L["FS_HOLD_SEQ_TOGGLE_DESC"], 1, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    holdCheck:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    SE.holdModeCheck = holdCheck

    -- Dependencies subsection (below 9 metadata rows)
    local DEP_SECTION_PAD = 6
    local DEP_HEADER_HEIGHT = 16
    local DEP_ROW_HEIGHT = 14
    local DEP_INDENT = 16

    local depSeparator = metaContent:CreateTexture(nil, "ARTWORK")
    depSeparator:SetHeight(1)
    depSeparator:SetPoint(
        "TOPLEFT",
        metaContent,
        "TOPLEFT",
        4,
        -(META_ROW_HEIGHT * META_ROWS + META_DESC_EXTRA) - DEP_SECTION_PAD
    )
    depSeparator:SetPoint(
        "TOPRIGHT",
        metaContent,
        "TOPRIGHT",
        -4,
        -(META_ROW_HEIGHT * META_ROWS + META_DESC_EXTRA) - DEP_SECTION_PAD
    )
    depSeparator:SetColorTexture(C.border:GetRGBA())

    local depHeaderLabel = metaContent:CreateFontString(nil, "OVERLAY")
    UI:SetFont(depHeaderLabel, 10)
    depHeaderLabel:SetPoint("TOPLEFT", depSeparator, "BOTTOMLEFT", 4, -DEP_SECTION_PAD)
    depHeaderLabel:SetText(L["GEMS_DEPS_HEADER"])
    depHeaderLabel:SetTextColor(C.textSecondary:GetRGBA())

    -- Container frame for dynamically created dependency rows
    local depFrame = CreateFrame("Frame", nil, metaContent)
    depFrame:SetPoint("TOPLEFT", depHeaderLabel, "BOTTOMLEFT", 0, -4)
    depFrame:SetPoint("RIGHT", metaContent, "RIGHT", -8, 0)
    depFrame:SetHeight(10) -- will be recalculated dynamically
    SE.depFrame = depFrame
    SE.depRows = {}
    SE.depSeparator = depSeparator
    SE.depHeaderLabel = depHeaderLabel
    SE.depConstants = {
        sectionPad = DEP_SECTION_PAD,
        headerHeight = DEP_HEADER_HEIGHT,
        rowHeight = DEP_ROW_HEIGHT,
        indent = DEP_INDENT,
        baseOffset = META_ROW_HEIGHT * META_ROWS
            + META_DESC_EXTRA
            + DEP_SECTION_PAD
            + 1
            + DEP_SECTION_PAD
            + DEP_HEADER_HEIGHT
            + 4,
    }

    -----------------------------------------------------------------------
    -- Click Rate Info (read-only TA recommendation display + override button)
    -----------------------------------------------------------------------
    local CR_SECTION_PAD = 6
    local CR_ROW_HEIGHT = 14
    local CR_ROWS = 3
    local CR_BTN_HEIGHT = 20
    local CR_BLOCK_HEIGHT = CR_SECTION_PAD + 1 + CR_SECTION_PAD + CR_ROW_HEIGHT * CR_ROWS + CR_BTN_HEIGHT + CR_SECTION_PAD

    local crSeparator = metaContent:CreateTexture(nil, "ARTWORK")
    crSeparator:SetHeight(1)
    crSeparator:SetPoint("TOPLEFT", depFrame, "BOTTOMLEFT", 0, -CR_SECTION_PAD)
    crSeparator:SetPoint("RIGHT", metaContent, "RIGHT", -4, 0)
    crSeparator:SetColorTexture(C.border:GetRGBA())

    local crHeaderLabel = metaContent:CreateFontString(nil, "OVERLAY")
    UI:SetFont(crHeaderLabel, 10)
    crHeaderLabel:SetPoint("TOPLEFT", crSeparator, "BOTTOMLEFT", 4, -CR_SECTION_PAD)
    crHeaderLabel:SetText(L["GEMS_SETTINGS_CLICK_RATE"])
    crHeaderLabel:SetTextColor(C.textSecondary:GetRGBA())

    -- Recommended ms row
    local crRecLabel = metaContent:CreateFontString(nil, "OVERLAY")
    UI:SetFont(crRecLabel, 10)
    crRecLabel:SetPoint("TOPLEFT", crHeaderLabel, "BOTTOMLEFT", 0, -4)
    crRecLabel:SetTextColor(C.textSecondary:GetRGBA())
    crRecLabel:SetText(L["FS_RECOMMENDED"]:gsub("%%d.*", ""))
    local crRecValue = metaContent:CreateFontString(nil, "OVERLAY")
    UI:SetFont(crRecValue, 10)
    crRecValue:SetPoint("LEFT", crRecLabel, "LEFT", 80, 0)
    crRecValue:SetTextColor(C.textPrimary:GetRGBA())

    -- Complexity row
    local crComplexLabel = metaContent:CreateFontString(nil, "OVERLAY")
    UI:SetFont(crComplexLabel, 10)
    crComplexLabel:SetPoint("TOPLEFT", crRecLabel, "BOTTOMLEFT", 0, -2)
    crComplexLabel:SetTextColor(C.textSecondary:GetRGBA())
    crComplexLabel:SetText(L["FS_COMPLEXITY"]:gsub("%%s", ""))
    local crComplexValue = metaContent:CreateFontString(nil, "OVERLAY")
    UI:SetFont(crComplexValue, 10)
    crComplexValue:SetPoint("LEFT", crComplexLabel, "LEFT", 80, 0)
    crComplexValue:SetTextColor(C.textPrimary:GetRGBA())

    -- Confidence row
    local crConfLabel = metaContent:CreateFontString(nil, "OVERLAY")
    UI:SetFont(crConfLabel, 10)
    crConfLabel:SetPoint("TOPLEFT", crComplexLabel, "BOTTOMLEFT", 0, -2)
    crConfLabel:SetTextColor(C.textSecondary:GetRGBA())
    crConfLabel:SetText("Confidence:")
    local crConfValue = metaContent:CreateFontString(nil, "OVERLAY")
    UI:SetFont(crConfValue, 10)
    crConfValue:SetPoint("LEFT", crConfLabel, "LEFT", 80, 0)
    crConfValue:SetTextColor(C.textPrimary:GetRGBA())

    -- Manual Override button
    local crOverrideBtn = CreateFrame("Button", nil, metaContent, "UIPanelButtonTemplate")
    crOverrideBtn:SetSize(120, CR_BTN_HEIGHT)
    crOverrideBtn:SetPoint("TOPLEFT", crConfLabel, "BOTTOMLEFT", 0, -4)
    crOverrideBtn:SetText(L["FS_MANUAL_OVERRIDE"])
    crOverrideBtn:SetScript("OnClick", function()
        local seqName = SE.currentSequence
        if not seqName then
            return
        end
        local TA = GRIPEMS.TempoAdvisor
        if not TA then
            return
        end
        local specID = TA:GetCurrentSpecID()
        if not _G.GRIP_EMS_CHAR then
            _G.GRIP_EMS_CHAR = {}
        end
        GRIP_EMS_CHAR.tempoManualOverride = GRIP_EMS_CHAR.tempoManualOverride or {}
        GRIP_EMS_CHAR.tempoManualOverride[specID] = GRIP_EMS_CHAR.tempoManualOverride[specID] or {}
        local overrides = GRIP_EMS_CHAR.tempoManualOverride[specID]
        if overrides[seqName] then
            -- Clear override
            overrides[seqName] = nil
            GRIPEMS:Print(string.format(L["FS_OVERRIDE_CLEARED"], seqName))
            crOverrideBtn:SetText(L["FS_MANUAL_OVERRIDE"])
        else
            -- Set override to current effective click rate
            local currentMs = GRIPEMS.Settings:GetEffectiveClickRate()
            overrides[seqName] = currentMs
            GRIPEMS:Print(string.format(L["FS_OVERRIDE_SET"], currentMs, seqName))
            crOverrideBtn:SetText(L["FS_CLEAR_OVERRIDE"])
        end
    end)

    -- Store references
    SE.crSeparator = crSeparator
    SE.crHeaderLabel = crHeaderLabel
    SE.crRecValue = crRecValue
    SE.crComplexValue = crComplexValue
    SE.crConfValue = crConfValue
    SE.crOverrideBtn = crOverrideBtn
    SE.crBlockHeight = CR_BLOCK_HEIGHT

    -- Hide by default (shown only when a sequence is loaded)
    crSeparator:Hide()
    crHeaderLabel:Hide()
    crRecLabel:Hide()
    crRecValue:Hide()
    crComplexLabel:Hide()
    crComplexValue:Hide()
    crConfLabel:Hide()
    crConfValue:Hide()
    crOverrideBtn:Hide()
    SE.crElements = { crSeparator, crHeaderLabel, crRecLabel, crRecValue, crComplexLabel, crComplexValue, crConfLabel, crConfValue, crOverrideBtn }

    -----------------------------------------------------------------------
    -- Reset Modifier Overrides (collapsible, between metadata and spell banner)
    -----------------------------------------------------------------------
    local RMOD_TOGGLE_HEIGHT = 18
    local RMOD_ENABLE_HEIGHT = 22
    local RMOD_ROW_HEIGHT = 22
    local RMOD_ROWS = 5
    local RMOD_CONTENT_HEIGHT = RMOD_ENABLE_HEIGHT + RMOD_ROW_HEIGHT * RMOD_ROWS + 4

    local resetModSection = CreateFrame("Frame", nil, parentPanel)
    resetModSection:SetHeight(RMOD_TOGGLE_HEIGHT)
    resetModSection:SetPoint("TOPLEFT", metaSection, "BOTTOMLEFT", 0, 0)
    resetModSection:SetPoint("TOPRIGHT", metaSection, "BOTTOMRIGHT", 0, 0)
    resetModSection:Hide()
    SE.resetModSection = resetModSection
    SE.resetModExpanded = false

    -- Toggle bar
    local rmodToggle = CreateFrame("Button", nil, resetModSection)
    rmodToggle:SetHeight(RMOD_TOGGLE_HEIGHT)
    rmodToggle:SetPoint("TOPLEFT", resetModSection, "TOPLEFT", 0, 0)
    rmodToggle:SetPoint("TOPRIGHT", resetModSection, "TOPRIGHT", 0, 0)

    local rmodArrow = rmodToggle:CreateFontString(nil, "OVERLAY")
    UI:SetFont(rmodArrow, 10)
    rmodArrow:SetPoint("LEFT", rmodToggle, "LEFT", 8, 0)
    rmodArrow:SetText(">")
    rmodArrow:SetTextColor(C.textSecondary:GetRGBA())

    local rmodToggleLabel = rmodToggle:CreateFontString(nil, "OVERLAY")
    UI:SetFont(rmodToggleLabel, 10)
    rmodToggleLabel:SetPoint("LEFT", rmodArrow, "RIGHT", 4, 0)
    rmodToggleLabel:SetText(L["GEMS_UI_RESET_MODS_HEADER"])
    rmodToggleLabel:SetTextColor(C.textSecondary:GetRGBA())

    rmodToggle:SetScript("OnEnter", function()
        rmodToggleLabel:SetTextColor(C.textPrimary:GetRGBA())
        rmodArrow:SetTextColor(C.textPrimary:GetRGBA())
    end)
    rmodToggle:SetScript("OnLeave", function()
        rmodToggleLabel:SetTextColor(C.textSecondary:GetRGBA())
        rmodArrow:SetTextColor(C.textSecondary:GetRGBA())
    end)

    -- Content area (hidden when collapsed)
    local rmodContent = CreateFrame("Frame", nil, resetModSection)
    rmodContent:SetPoint("TOPLEFT", rmodToggle, "BOTTOMLEFT", 0, -2)
    rmodContent:SetPoint("TOPRIGHT", rmodToggle, "BOTTOMRIGHT", 0, -2)
    rmodContent:SetHeight(RMOD_CONTENT_HEIGHT)
    rmodContent:Hide()
    SE.resetModContent = rmodContent

    rmodToggle:SetScript("OnClick", function()
        if SE.resetModExpanded then
            SE.resetModExpanded = false
            rmodContent:Hide()
            resetModSection:SetHeight(RMOD_TOGGLE_HEIGHT)
            rmodArrow:SetText(">")
        else
            SE.resetModExpanded = true
            rmodContent:Show()
            resetModSection:SetHeight(RMOD_TOGGLE_HEIGHT + 2 + RMOD_CONTENT_HEIGHT)
            rmodArrow:SetText("v")
        end
    end)

    -- Enable checkbox
    local rmodEnableCB = CreateFrame("CheckButton", nil, rmodContent, "UICheckButtonTemplate")
    rmodEnableCB:SetSize(22, 22)
    rmodEnableCB:SetPoint("TOPLEFT", rmodContent, "TOPLEFT", 8, 0)
    SE.resetModEnableCB = rmodEnableCB

    local rmodEnableLabel = rmodContent:CreateFontString(nil, "OVERLAY")
    UI:SetFont(rmodEnableLabel, 10)
    rmodEnableLabel:SetPoint("LEFT", rmodEnableCB, "RIGHT", 2, 0)
    rmodEnableLabel:SetText(L["GEMS_UI_RESET_MODS_ENABLE"])
    rmodEnableLabel:SetTextColor(C.textSecondary:GetRGBA())

    local rmodGlobalHint = rmodContent:CreateFontString(nil, "OVERLAY")
    UI:SetFont(rmodGlobalHint, 9)
    rmodGlobalHint:SetPoint("LEFT", rmodEnableLabel, "RIGHT", 8, 0)
    rmodGlobalHint:SetText(L["GEMS_UI_RESET_MODS_GLOBAL"])
    rmodGlobalHint:SetTextColor(C.textMuted:GetRGBA())
    SE.resetModGlobalHint = rmodGlobalHint

    -- Modifier checkbox grid (5 rows)
    local modGroups = {
        { mods = { "LeftButton", "RightButton", "MiddleButton", "Button4", "Button5" } },
        { mods = { "LeftAlt", "RightAlt", "Alt" } },
        { mods = { "LeftControl", "RightControl", "Control" } },
        { mods = { "LeftShift", "RightShift", "Shift" } },
        { mods = { "AnyMod" } },
    }
    SE.resetModCheckboxes = {}
    local prevRow = rmodEnableCB
    for _, group in ipairs(modGroups) do
        local rowFrame = CreateFrame("Frame", nil, rmodContent)
        rowFrame:SetHeight(RMOD_ROW_HEIGHT)
        rowFrame:SetPoint("TOPLEFT", prevRow, "BOTTOMLEFT", 0, -1)
        rowFrame:SetPoint("RIGHT", rmodContent, "RIGHT", -4, 0)

        local prevCB
        for _, mod in ipairs(group.mods) do
            local cb = CreateFrame("CheckButton", nil, rowFrame, "UICheckButtonTemplate")
            cb:SetSize(18, 18)
            if prevCB then
                cb:SetPoint("LEFT", prevCB._label, "RIGHT", 6, 0)
            else
                cb:SetPoint("LEFT", rowFrame, "LEFT", 0, 0)
            end
            cb._modName = mod
            cb:SetScript("OnClick", function(self)
                SE:OnResetModChanged(self._modName, self:GetChecked())
            end)

            local label = rowFrame:CreateFontString(nil, "OVERLAY")
            UI:SetFont(label, 9)
            label:SetPoint("LEFT", cb, "RIGHT", 1, 0)
            label:SetText(L["GEMS_RESET_MOD_" .. strupper(mod)])
            label:SetTextColor(C.textSecondary:GetRGBA())
            cb._label = label

            SE.resetModCheckboxes[mod] = cb
            prevCB = cb
        end
        prevRow = rowFrame
    end

    -- Enable toggle wiring
    rmodEnableCB:SetScript("OnClick", function(self)
        local checked = self:GetChecked()
        SE:OnResetModEnableToggled(checked)
    end)

    -----------------------------------------------------------------------
    -- Spell warning banner (between header and version bar)
    -----------------------------------------------------------------------
    local spellBanner = CreateFrame("Frame", nil, parentPanel, "BackdropTemplate")
    spellBanner:SetHeight(0)
    spellBanner:SetPoint("TOPLEFT", resetModSection, "BOTTOMLEFT", 0, 0)
    spellBanner:SetPoint("TOPRIGHT", resetModSection, "BOTTOMRIGHT", 0, 0)
    UI:ApplyBackdrop(spellBanner, UI.Backdrops.panelNoBorder, C.bgInput)
    spellBanner:EnableMouse(false)
    spellBanner:Hide()
    SE.spellWarnBanner = spellBanner

    local warnIcon = spellBanner:CreateTexture(nil, "ARTWORK")
    warnIcon:SetSize(16, 16)
    warnIcon:SetPoint("LEFT", spellBanner, "LEFT", 6, 0)
    warnIcon:SetTexture("Interface\\DialogFrame\\UI-Dialog-Icon-AlertNew")

    local warnText = spellBanner:CreateFontString(nil, "OVERLAY")
    UI:SetFont(warnText, 11)
    warnText:SetPoint("LEFT", warnIcon, "RIGHT", 4, 0)
    warnText:SetTextColor(C.textWarning:GetRGBA())
    SE.spellWarnText = warnText

    -----------------------------------------------------------------------
    -- Version bar (between header and tab bar)
    -----------------------------------------------------------------------
    local versionBar = CreateFrame("Frame", nil, parentPanel, "BackdropTemplate")
    versionBar:SetHeight(26)
    versionBar:SetPoint("TOPLEFT", resetModSection, "BOTTOMLEFT", 0, 0)
    versionBar:SetPoint("TOPRIGHT", resetModSection, "BOTTOMRIGHT", 0, 0)
    UI:ApplyBackdrop(versionBar, UI.Backdrops.panelNoBorder, C.bgDeep)
    versionBar:Hide()
    SE.versionBar = versionBar

    -- Version dropdown button (shows "Version X of Y")
    local versionBtn = UI:CreateButton(versionBar, string.format(L["GEMS_VERSION_OF"], 1, 1), 140, 22)
    versionBtn:SetPoint("LEFT", versionBar, "LEFT", 8, 0)
    versionBtn:SetScript("OnClick", function(self)
        if not SE.currentSequence then
            return
        end
        local vbEntry = GRIPEMS.Engine and GRIPEMS.Engine.sequences and GRIPEMS.Engine.sequences[SE.currentSequence]
        if not vbEntry or not vbEntry.data or not vbEntry.data.versions then
            return
        end

        MenuUtil.CreateContextMenu(self, function(_, rootDescription)
            for i = 1, #vbEntry.data.versions do
                local lbl = string.format(L["GEMS_VERSION_LABEL"], i)
                if i == (vbEntry.data.defaultVersion or 1) then
                    lbl = lbl .. L["GEMS_VERSION_DEFAULT_SUFFIX"]
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
        UI:ShowTooltip(self, L["GEMS_VERSION_TOOLTIP_TITLE"], L["GEMS_VERSION_TOOLTIP_DESC"])
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
        if not SE.currentSequence then
            return
        end
        if SE.isDirty then
            SE:PromptSave()
            return
        end
        local avEntry = GRIPEMS.Engine and GRIPEMS.Engine.sequences and GRIPEMS.Engine.sequences[SE.currentSequence]
        if not avEntry or not avEntry.data then
            return
        end

        local tmpl = D().NewVersion
        local newVer = {
            stepFunction = tmpl.stepFunction,
            steps = {},
            resetOnCombat = tmpl.resetOnCombat,
            resetOnTarget = tmpl.resetOnTarget,
            resetOnGear = tmpl.resetOnGear,
            resetOnSpec = tmpl.resetOnSpec,
            resetTimer = tmpl.resetTimer,
            keyPress = tmpl.keyPress or "",
            keyRelease = tmpl.keyRelease or "",
        }
        table.insert(avEntry.data.versions, newVer)
        SE._updatingFromEditor = true
        GRIPEMS.Engine:UpdateSequenceData(SE.currentSequence, avEntry.data)
        SE._updatingFromEditor = false
        SE.activeVersionIndex = #avEntry.data.versions
        SE:LoadVersionIntoEditor()
    end)
    addVerBtn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(C.bgRowHover:GetRGBA())
        self:SetBackdropBorderColor(C.borderFocus:GetRGBA())
        UI:ShowTooltip(self, L["GEMS_VERSION_ADD_TITLE"], L["GEMS_VERSION_ADD_DESC"])
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
        if not SE.currentSequence then
            return
        end
        if SE.isDirty then
            SE:PromptSave()
            return
        end
        local dvEntry = GRIPEMS.Engine and GRIPEMS.Engine.sequences and GRIPEMS.Engine.sequences[SE.currentSequence]
        if not dvEntry or not dvEntry.data then
            return
        end

        local srcVer = SE:GetEditingVersion(dvEntry.data)
        if not srcVer then
            return
        end

        local dupVer = {
            stepFunction = srcVer.stepFunction,
            steps = {},
            resetOnCombat = srcVer.resetOnCombat,
            resetOnTarget = srcVer.resetOnTarget,
            resetOnGear = srcVer.resetOnGear,
            resetOnSpec = srcVer.resetOnSpec,
            resetTimer = srcVer.resetTimer,
            keyPress = srcVer.keyPress or "",
            keyRelease = srcVer.keyRelease or "",
        }
        -- Deep-copy the flat resetModifiers table so duplicate doesn't alias source
        if srcVer.resetModifiers then
            dupVer.resetModifiers = {}
            for mod, val in pairs(srcVer.resetModifiers) do
                dupVer.resetModifiers[mod] = val
            end
        end
        for j, step in ipairs(srcVer.steps) do
            dupVer.steps[j] = step
        end
        table.insert(dvEntry.data.versions, dupVer)
        SE._updatingFromEditor = true
        GRIPEMS.Engine:UpdateSequenceData(SE.currentSequence, dvEntry.data)
        SE._updatingFromEditor = false
        SE.activeVersionIndex = #dvEntry.data.versions
        SE:LoadVersionIntoEditor()
    end)
    dupVerBtn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(C.bgRowHover:GetRGBA())
        self:SetBackdropBorderColor(C.borderFocus:GetRGBA())
        UI:ShowTooltip(self, L["GEMS_VERSION_DUP_TITLE"], L["GEMS_VERSION_DUP_DESC"])
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
        if not SE.currentSequence then
            return
        end
        if SE.isDirty then
            SE:PromptSave()
            return
        end
        local dlEntry = GRIPEMS.Engine and GRIPEMS.Engine.sequences and GRIPEMS.Engine.sequences[SE.currentSequence]
        if not dlEntry or not dlEntry.data or not dlEntry.data.versions then
            return
        end
        if #dlEntry.data.versions <= 1 then
            return
        end

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
        SE._updatingFromEditor = true
        GRIPEMS.Engine:UpdateSequenceData(SE.currentSequence, dlEntry.data)
        SE._updatingFromEditor = false
        SE.activeVersionIndex = 1
        SE:LoadVersionIntoEditor()
    end)
    delVerBtn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(C.bgRowHover:GetRGBA())
        self:SetBackdropBorderColor(C.borderFocus:GetRGBA())
        UI:ShowTooltip(self, L["GEMS_VERSION_DEL_TITLE"], L["GEMS_VERSION_DEL_DESC"])
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
        if not SE.currentSequence then
            return
        end
        if SE.isDirty then
            SE:PromptSave()
            return
        end
        local sdEntry = GRIPEMS.Engine and GRIPEMS.Engine.sequences and GRIPEMS.Engine.sequences[SE.currentSequence]
        if not sdEntry or not sdEntry.data then
            return
        end

        sdEntry.data.defaultVersion = SE.activeVersionIndex
        SE._updatingFromEditor = true
        GRIPEMS.Engine:UpdateSequenceData(SE.currentSequence, sdEntry.data)
        SE._updatingFromEditor = false
        SE:RefreshVersionBar()
    end)
    defVerBtn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(C.bgRowHover:GetRGBA())
        self:SetBackdropBorderColor(C.borderFocus:GetRGBA())
        UI:ShowTooltip(self, L["GEMS_VERSION_DEFAULT_TITLE"], L["GEMS_VERSION_DEFAULT_DESC"])
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
    previewFrame:SetHeight(D().PREVIEW_FRAME_HEIGHT)
    previewFrame:SetPoint("TOPLEFT", versionBar, "BOTTOMLEFT", 0, 0)
    previewFrame:SetPoint("RIGHT", parentPanel, "RIGHT", 0, 0)
    UI:ApplyBackdrop(previewFrame, UI.Backdrops.panel, C.bgInput, C.border)
    previewFrame:Hide()
    SE.previewFrame = previewFrame

    -- Plain ScrollFrame for clipping preview content (no scrollbar)
    local previewScroll = CreateFrame("ScrollFrame", nil, previewFrame)
    previewScroll:SetPoint("TOPLEFT", previewFrame, "TOPLEFT", 4, -2)
    previewScroll:SetPoint("BOTTOMRIGHT", previewFrame, "BOTTOMRIGHT", -58, 14)
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
            if atBottom then
                SE.previewFade:Hide()
            else
                SE.previewFade:Show()
            end
        end
        if SE.previewOverflowHint then
            if atBottom then
                SE.previewOverflowHint:Hide()
            else
                SE.previewOverflowHint:Show()
            end
        end
    end)

    -- Bottom fade gradient (transparent to bgInput)
    local fadeTex = previewFrame:CreateTexture(nil, "OVERLAY")
    fadeTex:SetHeight(20)
    fadeTex:SetPoint("BOTTOMLEFT", previewFrame, "BOTTOMLEFT", 1, 14)
    fadeTex:SetPoint("BOTTOMRIGHT", previewFrame, "BOTTOMRIGHT", -1, 14)
    fadeTex:SetTexture("Interface\\Buttons\\WHITE8x8")
    local bg = C.bgInput
    fadeTex:SetGradient("VERTICAL", CreateColor(bg.r, bg.g, bg.b, 0), CreateColor(bg.r, bg.g, bg.b, 1))
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
    previewEditBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)
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

    -- Icon strip container (horizontal ScrollFrame for icon mode)
    local previewIconScroll = CreateFrame("ScrollFrame", nil, previewFrame)
    previewIconScroll:SetPoint("TOPLEFT", previewFrame, "TOPLEFT", 4, -4)
    previewIconScroll:SetPoint("BOTTOMRIGHT", previewFrame, "BOTTOMRIGHT", -58, 14)
    previewIconScroll:EnableMouseWheel(true)

    local function UpdateIconScrollFades(scroll)
        local maxScroll = scroll:GetHorizontalScrollRange()
        local current = scroll:GetHorizontalScroll()
        local canScrollRight = maxScroll > 0 and current < (maxScroll - 1)
        local canScrollLeft = current > 1
        if SE.iconFadeRight then
            if canScrollRight then
                SE.iconFadeRight:Show()
            else
                SE.iconFadeRight:Hide()
            end
        end
        if SE.iconFadeLeft then
            if canScrollLeft then
                SE.iconFadeLeft:Show()
            else
                SE.iconFadeLeft:Hide()
            end
        end
        if SE.iconChevronRight then
            if canScrollRight then
                SE.iconChevronRight:Show()
                SE.iconChevronRightBtn:Show()
            else
                SE.iconChevronRight:Hide()
                SE.iconChevronRightBtn:Hide()
            end
        end
        if SE.iconChevronLeft then
            if canScrollLeft then
                SE.iconChevronLeft:Show()
                SE.iconChevronLeftBtn:Show()
            else
                SE.iconChevronLeft:Hide()
                SE.iconChevronLeftBtn:Hide()
            end
        end
        if SE.iconScrollTrack and SE.iconScrollThumb then
            if maxScroll > 0 then
                SE.iconScrollTrack:Show()
                SE.iconScrollThumb:Show()
                local trackWidth = SE.iconScrollTrack:GetWidth()
                local scrollFrameWidth = scroll:GetWidth()
                local visibleRatio = scrollFrameWidth / (scrollFrameWidth + maxScroll)
                local thumbWidth = math.max(trackWidth * visibleRatio, 20)
                SE.iconScrollThumb:SetWidth(thumbWidth)
                local thumbMax = trackWidth - thumbWidth
                local thumbPos = (maxScroll > 0) and (current / maxScroll * thumbMax) or 0
                SE.iconScrollThumb:ClearAllPoints()
                SE.iconScrollThumb:SetPoint("LEFT", SE.iconScrollTrack, "LEFT", thumbPos, 0)
            else
                SE.iconScrollTrack:Hide()
                SE.iconScrollThumb:Hide()
            end
        end
    end

    previewIconScroll:SetScript("OnMouseWheel", function(self, delta)
        local current = self:GetHorizontalScroll()
        local maxScroll = self:GetHorizontalScrollRange()
        local step = 40
        local newScroll = current - (delta * step)
        newScroll = math.max(0, math.min(newScroll, maxScroll))
        self:SetHorizontalScroll(newScroll)
        UpdateIconScrollFades(self)
    end)
    previewIconScroll:SetScript("OnScrollRangeChanged", function(self)
        UpdateIconScrollFades(self)
    end)
    previewIconScroll:Hide()
    SE.previewIconScroll = previewIconScroll

    local previewIconContainer = CreateFrame("Frame", nil, previewIconScroll)
    previewIconContainer:SetHeight(D().PREVIEW_ICON_SIZE)
    previewIconContainer:SetWidth(1)
    previewIconScroll:SetScrollChild(previewIconContainer)
    SE.previewIconContainer = previewIconContainer

    -- Icon pool (reusable icon button frames, created on demand)
    SE.previewIcons = {}

    -- Horizontal fade overlays for icon scroll affordance
    local panelBg = C.bgPanel
    local iconFadeRight = previewFrame:CreateTexture(nil, "OVERLAY", nil, 7)
    iconFadeRight:SetWidth(40)
    iconFadeRight:SetPoint("TOPRIGHT", previewIconScroll, "TOPRIGHT", 0, 0)
    iconFadeRight:SetPoint("BOTTOMRIGHT", previewIconScroll, "BOTTOMRIGHT", 0, 0)
    iconFadeRight:SetTexture("Interface\\Buttons\\WHITE8x8")
    iconFadeRight:SetGradient(
        "HORIZONTAL",
        CreateColor(bg.r, bg.g, bg.b, 0),
        CreateColor(panelBg.r, panelBg.g, panelBg.b, 1)
    )
    iconFadeRight:Hide()
    SE.iconFadeRight = iconFadeRight

    local iconFadeLeft = previewFrame:CreateTexture(nil, "OVERLAY", nil, 7)
    iconFadeLeft:SetWidth(40)
    iconFadeLeft:SetPoint("TOPLEFT", previewIconScroll, "TOPLEFT", 0, 0)
    iconFadeLeft:SetPoint("BOTTOMLEFT", previewIconScroll, "BOTTOMLEFT", 0, 0)
    iconFadeLeft:SetTexture("Interface\\Buttons\\WHITE8x8")
    iconFadeLeft:SetGradient(
        "HORIZONTAL",
        CreateColor(panelBg.r, panelBg.g, panelBg.b, 1),
        CreateColor(bg.r, bg.g, bg.b, 0)
    )
    iconFadeLeft:Hide()
    SE.iconFadeLeft = iconFadeLeft

    -- Chevron arrow indicators for icon scroll
    local iconChevronLeft = previewFrame:CreateFontString(nil, "OVERLAY")
    UI:SetFont(iconChevronLeft, 12)
    iconChevronLeft:SetText("<<")
    iconChevronLeft:SetTextColor(C.textSecondary:GetRGBA())
    iconChevronLeft:SetAlpha(0.7)
    iconChevronLeft:SetPoint("LEFT", previewIconScroll, "LEFT", -1, 0)
    iconChevronLeft:Hide()
    SE.iconChevronLeft = iconChevronLeft

    local iconChevronRight = previewFrame:CreateFontString(nil, "OVERLAY")
    UI:SetFont(iconChevronRight, 12)
    iconChevronRight:SetText(">>")
    iconChevronRight:SetTextColor(C.textSecondary:GetRGBA())
    iconChevronRight:SetAlpha(0.7)
    iconChevronRight:SetPoint("RIGHT", previewIconScroll, "RIGHT", 1, 0)
    iconChevronRight:Hide()
    SE.iconChevronRight = iconChevronRight

    local iconChevronLeftBtn = CreateFrame("Button", nil, previewFrame)
    iconChevronLeftBtn:SetSize(16, 36)
    iconChevronLeftBtn:SetPoint("LEFT", previewIconScroll, "LEFT", -1, 0)
    iconChevronLeftBtn:SetScript("OnClick", function()
        local cur = previewIconScroll:GetHorizontalScroll()
        local step = D().PREVIEW_ICON_SIZE + D().PREVIEW_ICON_SPACING
        local newScroll = math.max(0, cur - step)
        previewIconScroll:SetHorizontalScroll(newScroll)
        UpdateIconScrollFades(previewIconScroll)
    end)
    iconChevronLeftBtn:Hide()
    SE.iconChevronLeftBtn = iconChevronLeftBtn

    local iconChevronRightBtn = CreateFrame("Button", nil, previewFrame)
    iconChevronRightBtn:SetSize(16, 36)
    iconChevronRightBtn:SetPoint("RIGHT", previewIconScroll, "RIGHT", 1, 0)
    iconChevronRightBtn:SetScript("OnClick", function()
        local cur = previewIconScroll:GetHorizontalScroll()
        local maxS = previewIconScroll:GetHorizontalScrollRange()
        local step = D().PREVIEW_ICON_SIZE + D().PREVIEW_ICON_SPACING
        local newScroll = math.min(maxS, cur + step)
        previewIconScroll:SetHorizontalScroll(newScroll)
        UpdateIconScrollFades(previewIconScroll)
    end)
    iconChevronRightBtn:Hide()
    SE.iconChevronRightBtn = iconChevronRightBtn

    -- Scroll position track bar below icon strip
    local scrollTrack = CreateFrame("Frame", nil, previewFrame)
    scrollTrack:SetHeight(2)
    scrollTrack:SetPoint("BOTTOMLEFT", previewIconScroll, "BOTTOMLEFT", 0, -2)
    scrollTrack:SetPoint("BOTTOMRIGHT", previewIconScroll, "BOTTOMRIGHT", 0, -2)
    local trackBg = scrollTrack:CreateTexture(nil, "BACKGROUND")
    trackBg:SetAllPoints()
    trackBg:SetColorTexture(C.bgButton:GetRGBA())
    trackBg:SetAlpha(0.5)
    local scrollThumb = scrollTrack:CreateTexture(nil, "ARTWORK")
    scrollThumb:SetHeight(2)
    scrollThumb:SetColorTexture(C.accent:GetRGBA())
    scrollThumb:SetAlpha(0.6)
    scrollTrack:Hide()
    SE.iconScrollTrack = scrollTrack
    SE.iconScrollThumb = scrollThumb

    -- Preview mode toggle button (top-right of previewFrame)
    local toggleBtn = UI:CreateButton(previewFrame, L["GEMS_PREVIEW_ICONS"], 50, 18)
    toggleBtn:SetPoint("TOPRIGHT", previewFrame, "TOPRIGHT", -4, -3)
    toggleBtn:SetScript("OnClick", function()
        local S = GRIPEMS.Settings
        local current = S:Get("previewMode") or "icons"
        local next
        if current == "icons" then
            next = "text"
        elseif current == "text" then
            next = "compiled"
        else
            next = "icons"
        end
        S:Set("previewMode", next)
        local labels =
            { icons = L["GEMS_PREVIEW_ICONS"], text = L["GEMS_PREVIEW_TEXT"], compiled = L["GEMS_PREVIEW_COMPILED"] }
        toggleBtn.label:SetText(labels[next] or L["GEMS_PREVIEW_ICONS"])
        SE:UpdatePreview()
    end)
    toggleBtn:SetScript("OnEnter", function(self)
        UI:ShowTooltip(self, L["GEMS_PREVIEW_TOGGLE_TIP"])
    end)
    toggleBtn:SetScript("OnLeave", function()
        UI:HideTooltip()
    end)
    toggleBtn:SetFrameLevel(previewFrame:GetFrameLevel() + 10)
    SE.previewToggleBtn = toggleBtn

    -- Copy preview text button (left of toggle, text mode only)
    local copyBtn = UI:CreateButton(previewFrame, L["GEMS_PREVIEW_COPY"], 50, 18)
    copyBtn:SetPoint("RIGHT", toggleBtn, "LEFT", -4, 0)
    copyBtn:SetScript("OnClick", function()
        local text = SE.previewEditBox and SE.previewEditBox:GetText()
        if text and text ~= "" then
            local clean = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
            if not SE:CopyToClipboard(clean) then
                if GRIPEMS.ExportFrame then
                    GRIPEMS.ExportFrame:Show("Rotation Preview", clean)
                end
            end
        end
    end)
    copyBtn:SetScript("OnEnter", function(self)
        UI:ShowTooltip(self, L["GEMS_PREVIEW_COPY_TIP"])
    end)
    copyBtn:SetScript("OnLeave", function()
        UI:HideTooltip()
    end)
    copyBtn:SetFrameLevel(previewFrame:GetFrameLevel() + 10)
    copyBtn:Hide()
    SE.previewCopyBtn = copyBtn

    -- Hidden clipboard EditBox (off-screen to avoid taint from secure contexts)
    local clipboardBox = CreateFrame("EditBox", nil, UIParent)
    clipboardBox:SetSize(1, 1)
    clipboardBox:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -100, 100)
    clipboardBox:SetAutoFocus(false)
    clipboardBox:SetMultiLine(true)
    clipboardBox:SetMaxLetters(0)
    clipboardBox:Hide()
    SE.clipboardBox = clipboardBox

    clipboardBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
        self:Hide()
    end)
    clipboardBox:SetScript("OnEditFocusLost", function(self)
        self:Hide()
    end)

    -- Random hint label (shown when step function is Random)
    local randomHint = previewFrame:CreateFontString(nil, "OVERLAY")
    UI:SetFont(randomHint, 9)
    randomHint:SetPoint("BOTTOMLEFT", previewFrame, "BOTTOMLEFT", 4, 2)
    randomHint:SetText(L["GEMS_PREVIEW_RANDOM_HINT"])
    randomHint:SetTextColor(C.textMuted:GetRGBA())
    randomHint:Hide()
    SE.previewRandomHint = randomHint

    -----------------------------------------------------------------------
    -- Tab bar
    -----------------------------------------------------------------------
    local tabBar = CreateFrame("Frame", nil, parentPanel, "BackdropTemplate")
    tabBar:SetHeight(D().TAB_HEIGHT)
    tabBar:SetPoint("TOPLEFT", versionBar, "BOTTOMLEFT", 0, 0)
    tabBar:SetPoint("TOPRIGHT", versionBar, "BOTTOMRIGHT", 0, 0)
    UI:ApplyBackdrop(tabBar, UI.Backdrops.panelNoBorder, C.bgDeep)
    tabBar:Hide()
    SE.tabBar = tabBar

    -- Tab buttons
    local tabDefs = {
        { name = "Steps", label = L["GEMS_UI_TAB_STEPS"], active = true },
        { name = "Keybind", label = L["GEMS_UI_TAB_KEYBIND"], active = true },
        { name = "Macros", label = L["GEMS_UI_TAB_MACROS"], active = true },
        { name = "Context", label = L["GEMS_UI_TAB_CONTEXT"], active = true },
        { name = "Variables", label = L["GEMS_UI_TAB_VARIABLES"], active = true },
        { name = "Raw", label = L["GEMS_UI_TAB_RAW"], active = true },
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
            tab:SetScript("OnLeave", function()
                UI:HideTooltip()
            end)
        else
            -- Disabled tabs: grayed out with tooltip
            tabLabel:SetTextColor(C.textMuted:GetRGBA())
            tab:SetScript("OnEnter", function(self)
                UI:ShowTooltip(self, def.label, L["GEMS_UI_TAB_COMING_SOON"])
            end)
            tab:SetScript("OnLeave", function()
                UI:HideTooltip()
            end)
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
        GRIPEMS.RegisterCallback(SE, "SPELL_VALIDATION_UPDATED", "OnSpellValidationUpdated")
    end

    -----------------------------------------------------------------------
    -- Keyboard navigation (Item 1)
    -----------------------------------------------------------------------
    SE.editBoxFocused = false

    -- Helper: wrap existing focus scripts to track editbox focus state
    local function HookEditBoxFocus(editBox)
        if not editBox then
            return
        end
        local oldGain = editBox:GetScript("OnEditFocusGained")
        editBox:SetScript("OnEditFocusGained", function(self, ...)
            SE.editBoxFocused = true
            if oldGain then
                oldGain(self, ...)
            end
        end)
        local oldLost = editBox:GetScript("OnEditFocusLost")
        editBox:SetScript("OnEditFocusLost", function(self, ...)
            SE.editBoxFocused = false
            if oldLost then
                oldLost(self, ...)
            end
        end)
    end

    HookEditBoxFocus(SE.nameEditBox)
    HookEditBoxFocus(SE.keyPressEditBox)
    HookEditBoxFocus(SE.keyReleaseEditBox)
    HookEditBoxFocus(SE.timerBox)
    HookEditBoxFocus(SE.metaAuthorBox)
    HookEditBoxFocus(SE.metaDescBox)
    HookEditBoxFocus(SE.metaHelpBox)
    HookEditBoxFocus(SE.metaHelpLinkBox)

    -- Ordered tab names for arrow cycling (must match tabDefs order)
    local tabOrder = { "Steps", "Keybind", "Macros", "Context", "Variables", "Raw" }

    -- Ordered focusable fields for Tab cycling
    local function GetFocusableFields()
        local fields = {}
        if SE.nameEditBox and SE.nameEditBox:IsVisible() then
            fields[#fields + 1] = SE.nameEditBox
        end
        if SE.keyPressEditBox and SE.keyPressEditBox:IsVisible() then
            fields[#fields + 1] = SE.keyPressEditBox
        end
        if SE.keyReleaseEditBox and SE.keyReleaseEditBox:IsVisible() then
            fields[#fields + 1] = SE.keyReleaseEditBox
        end
        if SE.metadataExpanded then
            if SE.metaAuthorBox and SE.metaAuthorBox:IsVisible() then
                fields[#fields + 1] = SE.metaAuthorBox
            end
            if SE.metaDescBox and SE.metaDescBox:IsVisible() then
                fields[#fields + 1] = SE.metaDescBox
            end
            if SE.metaHelpBox and SE.metaHelpBox:IsVisible() then
                fields[#fields + 1] = SE.metaHelpBox
            end
            if SE.metaHelpLinkBox and SE.metaHelpLinkBox:IsVisible() then
                fields[#fields + 1] = SE.metaHelpLinkBox
            end
        end
        return fields
    end

    parentPanel:EnableKeyboard(true)
    parentPanel:SetScript("OnKeyDown", function(self, key)
        -- Only handle keys when no EditBox has focus and editor is visible
        if SE.editBoxFocused then
            pcall(self.SetPropagateKeyboardInput, self, true)
            return
        end
        if not SE.currentSequence then
            pcall(self.SetPropagateKeyboardInput, self, true)
            return
        end

        if key == "Z" and IsControlKeyDown() and not IsShiftKeyDown() then
            local US = GRIPEMS.UndoStack
            if US and US:CanUndo() then
                US:Undo()
            end
            pcall(self.SetPropagateKeyboardInput, self, false)
            return
        end

        if (key == "Y" and IsControlKeyDown()) or (key == "Z" and IsControlKeyDown() and IsShiftKeyDown()) then
            local US = GRIPEMS.UndoStack
            if US and US:CanRedo() then
                US:Redo()
            end
            pcall(self.SetPropagateKeyboardInput, self, false)
            return
        end

        if key == "LEFT" or key == "RIGHT" then
            -- Cycle through active tabs
            local currentIdx = 0
            for i, name in ipairs(tabOrder) do
                if name == SE.activeTab then
                    currentIdx = i
                    break
                end
            end
            if currentIdx == 0 then
                pcall(self.SetPropagateKeyboardInput, self, true)
                return
            end
            local dir = (key == "RIGHT") and 1 or -1
            local count = #tabOrder
            local nextIdx = currentIdx
            for _ = 1, count do
                nextIdx = ((nextIdx - 1 + dir) % count) + 1
                local tabBtn = SE.tabButtons[tabOrder[nextIdx]]
                if tabBtn and tabBtn._isActive then
                    SE:SwitchTab(tabOrder[nextIdx])
                    break
                end
            end
            pcall(self.SetPropagateKeyboardInput, self, false)
            return
        end

        if (key == "UP" or key == "DOWN") and IsAltKeyDown() then
            if SE.activeTab == "Steps" then
                local SLV = GRIPEMS.StepListView
                if SLV and SLV.selectedIndex then
                    if key == "UP" then
                        SLV:MoveStepUp()
                    else
                        SLV:MoveStepDown()
                    end
                    pcall(self.SetPropagateKeyboardInput, self, false)
                    return
                end
            end
            pcall(self.SetPropagateKeyboardInput, self, true)
            return
        end

        if key == "UP" or key == "DOWN" then
            -- Step navigation when Steps tab is active
            if SE.activeTab == "Steps" then
                local SLV = GRIPEMS.StepListView
                if SLV and SLV.workingSteps and #SLV.workingSteps > 0 then
                    local cur = SLV.selectedIndex or 0
                    local newIdx
                    if key == "UP" then
                        newIdx = cur > 1 and (cur - 1) or #SLV.workingSteps
                    else
                        newIdx = cur < #SLV.workingSteps and (cur + 1) or 1
                    end
                    SLV.selectedIndex = newIdx
                    SLV._lastLineCount = 0
                    SLV:RefreshAll()
                    pcall(self.SetPropagateKeyboardInput, self, false)
                    return
                end
            end
            pcall(self.SetPropagateKeyboardInput, self, true)
            return
        end

        if key == "TAB" then
            local fields = GetFocusableFields()
            if #fields > 0 then
                local shift = IsShiftKeyDown()
                local focused = nil
                for i, f in ipairs(fields) do
                    if f:HasFocus() then
                        focused = i
                        break
                    end
                end
                local nextField
                if not focused then
                    nextField = shift and fields[#fields] or fields[1]
                elseif shift then
                    nextField = fields[focused > 1 and (focused - 1) or #fields]
                else
                    nextField = fields[focused < #fields and (focused + 1) or 1]
                end
                if nextField then
                    nextField:SetFocus()
                end
                pcall(self.SetPropagateKeyboardInput, self, false)
                return
            end
        end

        -- All other keys: propagate to game
        pcall(self.SetPropagateKeyboardInput, self, true)
    end)

    -- Update tab visuals
    SE:UpdateTabButtons()
end

---------------------------------------------------------------------------
-- Tab management
---------------------------------------------------------------------------

--- Switch the active tab.
--- @param tabName string Tab identifier ("Steps", "Keybind", "Macros")
function SE:SwitchTab(tabName)
    if
        tabName ~= "Steps"
        and tabName ~= "Keybind"
        and tabName ~= "Macros"
        and tabName ~= "Context"
        and tabName ~= "Variables"
        and tabName ~= "Raw"
    then
        return
    end
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
        if SLV and SLV.scrollBox then
            SLV.scrollBox:Hide()
        end
        if SLV and SLV.scrollBar then
            SLV.scrollBar:Hide()
        end
        if SLV and SLV.actionBar then
            SLV.actionBar:Hide()
        end
        if SLV and SLV.editArea then
            SLV.editArea:Hide()
        end
        if SLV and SLV.selectLabel then
            SLV.selectLabel:Hide()
        end
        if SLV and SLV.emptyLabel then
            SLV.emptyLabel:Hide()
        end
        if SLV and SLV.hintLabel then
            SLV.hintLabel:Hide()
        end
        -- Close detail pane to avoid stale state
        if SLV and SLV._detailContainer then
            SLV._detailContainer:Hide()
        end
        if SLV and SLV.CloseDetailPane then
            SLV._detailOpen = false
            SLV._detailNavStack = nil
            SLV._detailNode = nil
            SLV._detailNodeIndex = nil
            SLV._detailSelectedChild = nil
            SLV._editingContext = nil
        end
    end

    if SE.activeTab == "Steps" then
        -- Show StepListView elements (Outline + Detail pane aware)
        if SLV then
            if SLV.scrollBox then
                SLV.scrollBox:Show()
            end
            if SLV.scrollBar then
                SLV.scrollBar:Show()
            end
            if SLV._detailOpen and SLV._detailContainer then
                SLV._detailContainer:Show()
            end
            if SLV.actionBar then
                SLV.actionBar:Show()
            end
            SLV:UpdateEditArea()
        end
        -- Hide other tabs
        if KBT then
            KBT:Hide()
        end
        if MTab then
            MTab:Hide()
        end
        if CTab then
            CTab:Hide()
        end
        if VTab then
            VTab:Hide()
        end
        if RTab then
            RTab:Hide()
        end
    elseif SE.activeTab == "Keybind" then
        hideStepListView()
        if KBT then
            KBT:Show()
        end
        if MTab then
            MTab:Hide()
        end
        if CTab then
            CTab:Hide()
        end
        if VTab then
            VTab:Hide()
        end
        if RTab then
            RTab:Hide()
        end
    elseif SE.activeTab == "Macros" then
        hideStepListView()
        if KBT then
            KBT:Hide()
        end
        if MTab then
            MTab:Show()
        end
        if CTab then
            CTab:Hide()
        end
        if VTab then
            VTab:Hide()
        end
        if RTab then
            RTab:Hide()
        end
    elseif SE.activeTab == "Context" then
        hideStepListView()
        if KBT then
            KBT:Hide()
        end
        if MTab then
            MTab:Hide()
        end
        if CTab then
            CTab:Show()
        end
        if VTab then
            VTab:Hide()
        end
        if RTab then
            RTab:Hide()
        end
    elseif SE.activeTab == "Variables" then
        hideStepListView()
        if KBT then
            KBT:Hide()
        end
        if MTab then
            MTab:Hide()
        end
        if CTab then
            CTab:Hide()
        end
        if VTab then
            VTab:Show()
        end
        if RTab then
            RTab:Hide()
        end
    elseif SE.activeTab == "Raw" then
        hideStepListView()
        if KBT then
            KBT:Hide()
        end
        if MTab then
            MTab:Hide()
        end
        if CTab then
            CTab:Hide()
        end
        if VTab then
            VTab:Hide()
        end
        if RTab then
            RTab:Show()
        end
    end
end

---------------------------------------------------------------------------
-- Name change handling
---------------------------------------------------------------------------

--- Handle renaming the sequence via the name EditBox.
--- @param newName string The new name entered by the user
function SE:HandleNameChange(newName)
    if not newName then
        return
    end
    newName = newName:match("^%s*(.-)%s*$") or "" -- trim whitespace
    if newName == "" then
        GRIPEMS:Print(L["GEMS_UI_NAME_EMPTY"])
        if SE.nameEditBox then
            SE.nameEditBox:SetText(SE.currentSequence or "")
        end
        return
    end
    if newName == SE.currentSequence then
        return
    end

    local engine = GRIPEMS.Engine
    if not engine or not engine.sequences then
        return
    end
    if engine.sequences[newName] then
        GRIPEMS:Print(string.format(L["GEMS_UI_NAME_EXISTS"], newName))
        if SE.nameEditBox then
            SE.nameEditBox:SetText(SE.currentSequence or "")
        end
        return
    end

    local oldName = SE.currentSequence
    local oldEntry = engine.sequences[oldName]
    if not oldEntry or not oldEntry.data then
        return
    end
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
        help = oldData.help or "",
        helplink = oldData.helplink or "",
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
                keyPress = ver.keyPress or "",
                keyRelease = ver.keyRelease or "",
            }
            if ver.resetModifiers then
                newData.versions[i].resetModifiers = {}
                for mod, val in pairs(ver.resetModifiers) do
                    newData.versions[i].resetModifiers[mod] = val
                end
            end
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
    local current = SE.currentSequence and engine and engine.sequences and engine.sequences[SE.currentSequence]
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
    if not SE.currentSequence then
        return
    end
    local engine = GRIPEMS.Engine
    if not engine or not engine.sequences then
        return
    end
    local entry = engine.sequences[SE.currentSequence]
    if not entry or not entry.data then
        return
    end

    local ver = SE:GetEditingVersion(entry.data)
    if not ver then
        return
    end
    if ver.stepFunction == sfName then
        return
    end

    ver.stepFunction = sfName
    SE.isDirty = true
    SE:UpdateSaveButtons()
    SE._updatingFromEditor = true
    GRIPEMS.Engine:UpdateSequenceData(SE.currentSequence, entry.data)
    SE._updatingFromEditor = false
    SE:UpdateStepFunctionButtons()
    SE:UpdatePreview()
end

---------------------------------------------------------------------------
-- Reset checkbox handling
---------------------------------------------------------------------------

--- Handle reset checkbox toggle.
--- @param resetType string "combat" or "target"
--- @param checked boolean New checked state
function SE:OnResetToggled(resetType, checked)
    if not SE.currentSequence then
        return
    end
    local engine = GRIPEMS.Engine
    if not engine or not engine.sequences then
        return
    end
    local entry = engine.sequences[SE.currentSequence]
    if not entry or not entry.data then
        return
    end

    local ver = SE:GetEditingVersion(entry.data)
    if not ver then
        return
    end
    if resetType == "combat" then
        ver.resetOnCombat = checked and true or false
    elseif resetType == "target" then
        ver.resetOnTarget = checked and true or false
    elseif resetType == "gear" then
        ver.resetOnGear = checked and true or false
    elseif resetType == "spec" then
        ver.resetOnSpec = checked and true or false
    end
    SE.isDirty = true
    SE:UpdateSaveButtons()
    SE._updatingFromEditor = true
    GRIPEMS.Engine:UpdateSequenceData(SE.currentSequence, entry.data)
    SE._updatingFromEditor = false
end

function SE:OnResetTimerChanged(value)
    if not SE.currentSequence then
        return
    end
    local engine = GRIPEMS.Engine
    if not engine or not engine.sequences then
        return
    end
    local entry = engine.sequences[SE.currentSequence]
    if not entry or not entry.data then
        return
    end
    local ver = SE:GetEditingVersion(entry.data)
    if not ver then
        return
    end
    ver.resetTimer = value or 0
    SE.isDirty = true
    SE:UpdateSaveButtons()
    SE._updatingFromEditor = true
    GRIPEMS.Engine:UpdateSequenceData(SE.currentSequence, entry.data)
    SE._updatingFromEditor = false
end

--- Handle the per-sequence reset modifier enable toggle.
--- @param checked boolean Whether per-sequence overrides are enabled
function SE:OnResetModEnableToggled(checked)
    if not SE.currentSequence then
        return
    end
    local engine = GRIPEMS.Engine
    if not engine or not engine.sequences then
        return
    end
    local entry = engine.sequences[SE.currentSequence]
    if not entry or not entry.data then
        return
    end
    local ver = SE:GetEditingVersion(entry.data)
    if not ver then
        return
    end
    if checked then
        -- Initialize from global settings
        ver.resetModifiers = {}
        local globalMods = GRIPEMS.Settings:GetResetModifiers()
        for mod, enabled in pairs(globalMods) do
            ver.resetModifiers[mod] = enabled
        end
    else
        ver.resetModifiers = nil
    end
    SE.isDirty = true
    SE:UpdateSaveButtons()
    SE._updatingFromEditor = true
    GRIPEMS.Engine:UpdateSequenceData(SE.currentSequence, entry.data)
    SE._updatingFromEditor = false
    SE:RefreshResetModCheckboxes(ver)
end

--- Handle individual reset modifier checkbox toggle.
--- @param modName string Modifier key name
--- @param checked boolean New checked state
function SE:OnResetModChanged(modName, checked)
    if not SE.currentSequence then
        return
    end
    local engine = GRIPEMS.Engine
    if not engine or not engine.sequences then
        return
    end
    local entry = engine.sequences[SE.currentSequence]
    if not entry or not entry.data then
        return
    end
    local ver = SE:GetEditingVersion(entry.data)
    if not ver or not ver.resetModifiers then
        return
    end
    ver.resetModifiers[modName] = checked and true or false
    SE.isDirty = true
    SE:UpdateSaveButtons()
    SE._updatingFromEditor = true
    GRIPEMS.Engine:UpdateSequenceData(SE.currentSequence, entry.data)
    SE._updatingFromEditor = false
end

--- Refresh the reset modifier checkbox UI to match version data.
--- @param ver table|nil The version being edited
function SE:RefreshResetModCheckboxes(ver)
    local hasOverride = ver and ver.resetModifiers ~= nil
    if SE.resetModEnableCB then
        SE.resetModEnableCB:SetChecked(hasOverride)
    end
    if SE.resetModGlobalHint then
        if hasOverride then
            SE.resetModGlobalHint:Hide()
        else
            SE.resetModGlobalHint:Show()
        end
    end
    -- Populate individual checkboxes
    local globalMods = GRIPEMS.Settings:GetResetModifiers()
    for mod, cb in pairs(SE.resetModCheckboxes or {}) do
        if hasOverride then
            cb:SetChecked(ver.resetModifiers[mod] and true or false)
            cb:Enable()
            if cb._label then
                cb._label:SetTextColor(GRIPEMS.UI.Colors.textSecondary:GetRGBA())
            end
        else
            cb:SetChecked(globalMods[mod] and true or false)
            cb:Disable()
            if cb._label then
                cb._label:SetTextColor(GRIPEMS.UI.Colors.textMuted:GetRGBA())
            end
        end
    end
end

--- Update the keyPress status label showing how many steps the keyPress fits.
function SE:UpdateKeyPressStatus()
    if not SE.kpStatusLabel then
        return
    end
    if not SE.currentSequence then
        SE.kpStatusLabel:SetText("")
        return
    end
    local engine = GRIPEMS.Engine
    if not engine or not engine.sequences then
        SE.kpStatusLabel:SetText("")
        return
    end
    local entry = engine.sequences[SE.currentSequence]
    if not entry or not entry.data then
        SE.kpStatusLabel:SetText("")
        return
    end
    local ver = SE:GetEditingVersion(entry.data)
    if not ver then
        SE.kpStatusLabel:SetText("")
        return
    end
    local kp = ver.keyPress or ""
    local kr = ver.keyRelease or ""
    if kp == "" and kr == "" then
        SE.kpStatusLabel:SetText("")
        return
    end
    local C = UI.Colors
    local kpLen = #kp > 0 and (#kp + 1) or 0
    local krLen = #kr > 0 and (#kr + 1) or 0
    local steps = ver.steps or {}
    local fits = 0
    for _, step in ipairs(steps) do
        local resolved = tostring(step)
        if GRIPEMS.Engine and GRIPEMS.Engine.SubstituteVariables then
            resolved = GRIPEMS.Engine:SubstituteVariables(resolved)
        end
        if (#resolved + kpLen + krLen) <= 255 then
            fits = fits + 1
        end
    end
    local total = #steps
    if fits == total then
        SE.kpStatusLabel:SetText(L["GEMS_KP_STATUS_ALL_FIT"]:format(fits))
        SE.kpStatusLabel:SetTextColor(C.textSuccess:GetRGBA())
    elseif fits > 0 then
        SE.kpStatusLabel:SetText(L["GEMS_KP_STATUS_PARTIAL"]:format(fits, total))
        SE.kpStatusLabel:SetTextColor(C.textWarning:GetRGBA())
    else
        SE.kpStatusLabel:SetText(L["GEMS_KP_STATUS_NONE"]:format(total))
        SE.kpStatusLabel:SetTextColor(C.textError:GetRGBA())
    end
end

--- Handle KeyPress text changes from the EditBox.
--- @param text string The new keyPress text
function SE:OnKeyPressChanged(text)
    if not SE.currentSequence then
        return
    end
    local engine = GRIPEMS.Engine
    if not engine or not engine.sequences then
        return
    end
    local entry = engine.sequences[SE.currentSequence]
    if not entry or not entry.data then
        return
    end
    local ver = SE:GetEditingVersion(entry.data)
    if not ver then
        return
    end
    ver.keyPress = text
    SE.isDirty = true
    SE:UpdateSaveButtons()
    -- Update SLV keyPress length and refresh step display
    local SLV = GRIPEMS.StepListView
    if SLV then
        SLV.keyPressLen = #text
        SLV:RefreshAll()
    end
    SE:UpdateKeyPressStatus()
    SE._updatingFromEditor = true
    GRIPEMS.Engine:UpdateSequenceData(SE.currentSequence, entry.data)
    SE._updatingFromEditor = false
end

--- Handle KeyRelease text changes from the EditBox.
--- @param text string The new keyRelease text
function SE:OnKeyReleaseChanged(text)
    if not SE.currentSequence then
        return
    end
    local engine = GRIPEMS.Engine
    if not engine or not engine.sequences then
        return
    end
    local entry = engine.sequences[SE.currentSequence]
    if not entry or not entry.data then
        return
    end
    local ver = SE:GetEditingVersion(entry.data)
    if not ver then
        return
    end
    ver.keyRelease = text
    SE.isDirty = true
    SE:UpdateSaveButtons()
    -- Update SLV keyRelease length and refresh step display
    local SLV = GRIPEMS.StepListView
    if SLV then
        SLV.keyReleaseLen = #text
        SLV:RefreshAll()
    end
    SE:UpdateKeyPressStatus()
    SE._updatingFromEditor = true
    GRIPEMS.Engine:UpdateSequenceData(SE.currentSequence, entry.data)
    SE._updatingFromEditor = false
end

--- Handle metadata field edits (mark dirty).
function SE:OnMetadataChanged()
    if not SE.currentSequence then
        return
    end
    SE.isDirty = true
    SE:UpdateSaveButtons()
end

---------------------------------------------------------------------------
-- Dependency display refresh (S08b)
---------------------------------------------------------------------------

--- Refresh the macro stub body preview from the current version data.
function SE:RefreshStubPreview()
    if not SE.stubContentBox then
        return
    end
    if not SE.stubExpanded then
        return
    end
    if not SE.currentSequence then
        SE.stubContentBox:SetText("")
        return
    end
    local engine = GRIPEMS.Engine
    if not engine or not engine.sequences then
        SE.stubContentBox:SetText("")
        return
    end
    local entry = engine.sequences[SE.currentSequence]
    if not entry or not entry.data then
        SE.stubContentBox:SetText("")
        return
    end
    local ver = SE:GetEditingVersion(entry.data)
    if not ver then
        SE.stubContentBox:SetText("")
        return
    end
    local MM = GRIPEMS.MacroManager
    if not MM or not MM.BuildStubBody then
        SE.stubContentBox:SetText("")
        return
    end
    local buttonName = D().BUTTON_PREFIX .. SE.currentSequence
    local body = MM:BuildStubBody(buttonName, ver.keyPress, ver.keyRelease)
    SE.stubContentBox:SetText(body or "")
end

--- Copy text to clipboard via hidden EditBox (Ctrl+C flow).
--- Auto-hides after 5 seconds if not dismissed earlier.
--- @param text string Text to copy
--- @return boolean success
function SE:CopyToClipboard(text)
    if not self.clipboardBox then
        return false
    end
    self.clipboardBox:SetText(text or "")
    self.clipboardBox:Show()
    self.clipboardBox:SetFocus()
    self.clipboardBox:HighlightText()
    C_Timer.After(5, function()
        if SE.clipboardBox and SE.clipboardBox:IsShown() then
            SE.clipboardBox:ClearFocus()
            SE.clipboardBox:Hide()
        end
    end)
    return true
end

---------------------------------------------------------------------------

--- Clear and rebuild dependency rows in the metadata panel.
--- Called from LoadSequence and SaveSequence.
function SE:RefreshDependencies()
    -- Clean up old rows
    if SE.depRows then
        for _, fs in ipairs(SE.depRows) do
            fs:Hide()
            fs:SetParent(nil)
        end
    end
    SE.depRows = {}

    if not SE.depFrame or not SE.depConstants then
        return
    end

    local depFrame = SE.depFrame
    local dc = SE.depConstants
    local C = UI.Colors

    -- Guard: no sequence loaded
    if not SE.currentSequence then
        depFrame:SetHeight(dc.rowHeight)
        SE:RecalcMetaHeight()
        return
    end

    local engine = GRIPEMS.Engine
    if not engine or not engine.sequences then
        depFrame:SetHeight(dc.rowHeight)
        SE:RecalcMetaHeight()
        return
    end
    local entry = engine.sequences[SE.currentSequence]
    if not entry or not entry.data then
        depFrame:SetHeight(dc.rowHeight)
        SE:RecalcMetaHeight()
        return
    end

    local deps = SE:ScanDependencies(entry.data)
    local yOff = 0

    -- Helper: create a FontString row
    local function MakeRow(text, color, indent)
        local fs = depFrame:CreateFontString(nil, "OVERLAY")
        UI:SetFont(fs, 10)
        fs:SetPoint("TOPLEFT", depFrame, "TOPLEFT", indent or 0, yOff)
        fs:SetText(text)
        fs:SetTextColor(color:GetRGBA())
        SE.depRows[#SE.depRows + 1] = fs
        yOff = yOff - dc.rowHeight
    end

    -- Variables section
    MakeRow(L["GEMS_DEPS_VARIABLES"], C.textSecondary, 0)
    if #deps.variables == 0 then
        MakeRow(L["GEMS_DEPS_NONE"], C.textMuted, dc.indent)
    else
        for _, v in ipairs(deps.variables) do
            local color = v.status == "found" and C.textSuccess or C.textError
            MakeRow("~" .. v.name .. "~", color, dc.indent)
        end
    end

    -- Sequences section
    yOff = yOff - 2 -- small gap
    MakeRow(L["GEMS_DEPS_SEQUENCES"], C.textSecondary, 0)
    if #deps.sequences == 0 then
        MakeRow(L["GEMS_DEPS_NONE"], C.textMuted, dc.indent)
    else
        for _, s in ipairs(deps.sequences) do
            local color = s.status == "found" and C.textSuccess or C.textError
            MakeRow(s.name, color, dc.indent)
        end
    end

    -- Embedded By section
    yOff = yOff - 2 -- small gap
    MakeRow(L["GEMS_DEPS_EMBEDDED_BY"], C.textSecondary, 0)
    if #deps.embeddedBy == 0 then
        MakeRow(L["GEMS_DEPS_NOT_EMBEDDED"], C.textMuted, dc.indent)
    else
        local names = table.concat(deps.embeddedBy, ", ")
        MakeRow(names, C.textSecondary, dc.indent)
    end

    -- Set depFrame height and recalc metadata section
    depFrame:SetHeight(math.abs(yOff))
    SE:RecalcMetaHeight()
end

--- Recalculate metadata section height to include dependencies.
function SE:RecalcMetaHeight()
    if not SE.metadataSection or not SE.metadataContent or not SE.depFrame then
        return
    end
    local META_TOGGLE_HEIGHT = 18
    local META_PAD = 4
    local META_ROW_HEIGHT = 22
    local META_ROWS = 9
    local META_DESC_EXTRA = 40
    local dc = SE.depConstants
    if not dc then
        return
    end
    local depHeight = SE.depFrame:GetHeight() or 0
    local crHeight = 0
    if SE.crElements and SE.crElements[1] and SE.crElements[1]:IsShown() then
        crHeight = SE.crBlockHeight or 0
    end
    local contentRows = META_ROW_HEIGHT * META_ROWS + META_DESC_EXTRA
    local fullHeight = META_TOGGLE_HEIGHT
        + META_PAD
        + contentRows
        + dc.sectionPad
        + 1
        + dc.sectionPad
        + dc.headerHeight
        + 4
        + depHeight
        + crHeight
        + dc.sectionPad
    SE.metadataContent:SetHeight(
        contentRows + dc.sectionPad + 1 + dc.sectionPad + dc.headerHeight + 4 + depHeight + crHeight + dc.sectionPad
    )
    if SE.metadataExpanded then
        SE.metadataSection:SetHeight(fullHeight)
    end
    -- Store for toggle
    SE._metaFullHeight = fullHeight
end

---------------------------------------------------------------------------
-- Dirty state / save logic
---------------------------------------------------------------------------

--- Update Record button appearance based on MacroRecorder state.
function SE:UpdateRecordButton()
    if not SE.recordBtn then
        return
    end
    local MR = GRIPEMS.MacroRecorder
    if not MR then
        return
    end
    local UI = GRIPEMS.UI -- luacheck: no redefined
    local C = UI.Colors
    if MR.isRecording then
        SE.recordBtn.label:SetText(L["GEMS_UI_RECORDING"])
        SE.recordBtn:SetBackdropColor(0.6, 0.1, 0.1, 0.8)
    else
        SE.recordBtn.label:SetText(L["GEMS_UI_RECORD"])
        SE.recordBtn:SetBackdropColor(C.bgButton:GetRGBA())
        SE.recordBtn:SetBackdropBorderColor(C.border:GetRGBA())
    end
end

--- Show confirmation dialog after recording stops.
--- @param count number Number of recorded spells
function SE:ShowRecordingConfirm(count)
    StaticPopupDialogs["GRIPEMS_RECORDING_CONFIRM"] = {
        text = string.format(L["GEMS_RECORDER_CREATE_CONFIRM"], count),
        button1 = L["GEMS_RECORDER_CREATE_YES"],
        button2 = L["GEMS_RECORDER_CREATE_NO"],
        OnAccept = function()
            SE:CreateFromRecording()
        end,
        OnCancel = function()
            local MR = GRIPEMS.MacroRecorder
            if MR then
                MR:Clear()
            end
            SE:UpdateRecordButton()
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
    }
    StaticPopup_Show("GRIPEMS_RECORDING_CONFIRM")
end

--- Create a new sequence from recorded spells.
function SE:CreateFromRecording()
    local MR = GRIPEMS.MacroRecorder
    if not MR or MR:GetCount() == 0 then
        return
    end

    local function doCreate()
        local name = "Recorded " .. date("%H:%M:%S")
        -- Ensure unique name
        local Engine = GRIPEMS.Engine
        if Engine and Engine.sequences then
            local baseName = name
            local suffix = 2
            while Engine.sequences[name] do
                name = baseName .. " " .. suffix
                suffix = suffix + 1
            end
        end

        local D = GRIPEMS.Defaults -- luacheck: no redefined
        local steps = MR:BuildSteps()
        local seqData = D.NewSequenceFromTemplate(name)
        seqData.versions[1].steps = steps

        if Engine then
            Engine:ActivateSequence(name, seqData)
        end

        -- Load into editor and mark dirty so user can review
        C_Timer.After(0.1, function()
            local SL = GRIPEMS.SequenceList
            if SL then
                SL:SelectSequence(name)
            end
            SE.isDirty = true
            SE:UpdateSaveButtons()
        end)

        MR:Clear()
        SE:UpdateRecordButton()
    end

    -- Respect restriction state: queue via OOCQueue if restricted
    if GRIPEMS.OOCQueue.IsRestricted() then
        local OOC = GRIPEMS.OOCQueue
        if OOC then
            OOC:Add(doCreate, "recorder_create")
        end
    else
        doCreate()
    end
end

--- Update Save/Discard button visibility based on dirty state.
function SE:UpdateSaveButtons()
    if not SE.saveBtn or not SE.discardBtn then
        return
    end
    if SE.isDirty then
        SE.saveBtn:Show()
        SE.discardBtn:Show()
        -- Disable Save during combat/restriction (engine methods may queue OOC ops)
        if GRIPEMS.OOCQueue.IsRestricted() then
            SE.saveBtn:Disable()
        else
            SE.saveBtn:Enable()
        end
        -- Shrink nameEditBox: RIGHT edge stops at saveBtn
        SE.nameEditBox:ClearAllPoints()
        SE.nameEditBox:SetPoint("LEFT", SE.iconTex, "RIGHT", 8, 0)
        SE.nameEditBox:SetPoint("RIGHT", SE.saveBtn, "LEFT", -4, 0)
    else
        SE.saveBtn:Hide()
        SE.discardBtn:Hide()
        -- Expand nameEditBox: RIGHT edge stops at exportBtn
        SE.nameEditBox:ClearAllPoints()
        SE.nameEditBox:SetPoint("LEFT", SE.iconTex, "RIGHT", 8, 0)
        SE.nameEditBox:SetPoint("RIGHT", SE.exportBtn, "LEFT", -4, 0)
    end

    -- Record button: visible when a sequence is loaded, hidden when none
    if SE.recordBtn then
        SE.recordBtn:SetShown(SE.currentSequence ~= nil)
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

--- Update the spell warning banner for the current sequence.
function SE:UpdateSpellWarning()
    local SV = GRIPEMS.SpellValidator
    local SC = GRIPEMS.SpellCache
    if not SE.spellWarnBanner then
        return
    end
    if not SE.currentSequence then
        SE.spellWarnBanner:SetHeight(0)
        SE.spellWarnBanner:EnableMouse(false)
        SE.spellWarnBanner:Hide()
        if SE.versionBar and SE.header then
            SE.versionBar:ClearAllPoints()
            SE.versionBar:SetPoint("TOPLEFT", SE.header, "BOTTOMLEFT", 0, 0)
            SE.versionBar:SetPoint("TOPRIGHT", SE.header, "BOTTOMRIGHT", 0, 0)
        end
        return
    end
    local seqEntry = GRIPEMS.Engine and GRIPEMS.Engine.sequences and GRIPEMS.Engine.sequences[SE.currentSequence]
    if not seqEntry or not seqEntry.data or not SC or not SC.ready or not SV then
        SE.spellWarnBanner:SetHeight(0)
        SE.spellWarnBanner:EnableMouse(false)
        SE.spellWarnBanner:Hide()
        if SE.versionBar and SE.header then
            SE.versionBar:ClearAllPoints()
            SE.versionBar:SetPoint("TOPLEFT", SE.header, "BOTTOMLEFT", 0, 0)
            SE.versionBar:SetPoint("TOPRIGHT", SE.header, "BOTTOMRIGHT", 0, 0)
        end
        return
    end
    local valResult = SV:ValidateSequence(seqEntry.data)
    if valResult.staleCount > 0 then
        SE.spellWarnText:SetText(string.format(L["GEMS_SPELL_WARN_BANNER"], valResult.staleCount))
        SE.spellWarnBanner:Show()
        SE.spellWarnBanner:SetHeight(24)
        if SE.versionBar then
            SE.versionBar:ClearAllPoints()
            SE.versionBar:SetPoint("TOPLEFT", SE.spellWarnBanner, "BOTTOMLEFT", 0, 0)
            SE.versionBar:SetPoint("TOPRIGHT", SE.spellWarnBanner, "BOTTOMRIGHT", 0, 0)
        end
        SE.spellWarnBanner:EnableMouse(true)
        SE.spellWarnBanner:SetScript("OnEnter", function(self)
            local lines = {}
            for _, stepResult in ipairs(valResult.steps) do
                for _, spell in ipairs(stepResult.spells) do
                    if spell.status == D().SPELL_STATUS_UNKNOWN then
                        lines[#lines + 1] = string.format(L["GEMS_SPELL_TOOLTIP_UNKNOWN"], spell.name)
                    elseif spell.status == D().SPELL_STATUS_KNOWN then
                        lines[#lines + 1] = string.format(L["GEMS_SPELL_TOOLTIP_KNOWN"], spell.name)
                    end
                end
            end
            -- Truncate regular entries
            if #lines > 10 then
                local extra = #lines - 10
                lines = { unpack(lines, 1, 10) }
                lines[#lines + 1] = string.format("... and %d more", extra)
            end
            -- Tooltip cosmetic spells (dimmed, always visible after truncation)
            if valResult.tooltipStaleCount and valResult.tooltipStaleCount > 0 then
                for _, stepResult in ipairs(valResult.steps) do
                    for _, spell in ipairs(stepResult.tooltipSpells or {}) do
                        if spell.status == D().SPELL_STATUS_TOOLTIP_STALE then
                            lines[#lines + 1] = string.format(L["GEMS_SPELL_TOOLTIP_COSMETIC"], spell.name)
                        end
                    end
                end
            end
            GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
            GameTooltip:SetText(string.format(L["GEMS_SPELL_WARN_BANNER"], valResult.staleCount), 1, 1, 1)
            GameTooltip:AddLine(table.concat(lines, "\n"), 0.8, 0.8, 0.8, true)
            GameTooltip:Show()
        end)
        SE.spellWarnBanner:SetScript("OnLeave", function()
            UI:HideTooltip()
        end)
    else
        SE.spellWarnBanner:SetHeight(0)
        SE.spellWarnBanner:EnableMouse(false)
        SE.spellWarnBanner:Hide()
        if SE.versionBar and SE.resetModSection then
            SE.versionBar:ClearAllPoints()
            SE.versionBar:SetPoint("TOPLEFT", SE.resetModSection, "BOTTOMLEFT", 0, 0)
            SE.versionBar:SetPoint("TOPRIGHT", SE.resetModSection, "BOTTOMRIGHT", 0, 0)
        end
    end
end

--- Save the current working steps back to the engine.
function SE:SaveSequence()
    if not SE.currentSequence then
        return
    end

    local SLV = GRIPEMS.StepListView
    if not SLV then
        return
    end

    local engine = GRIPEMS.Engine
    if not engine or not engine.sequences then
        return
    end
    local entry = engine.sequences[SE.currentSequence]
    if not entry or not entry.data then
        return
    end

    -- Build updated seqData from current engine data + working steps (version-aware)
    local oldData = entry.data
    local steps = SLV:GetWorkingSteps()

    -- Retrieve working actions if in tree mode
    local workingActions = SLV:GetWorkingActions()

    -- Deep copy all versions, updating steps in the active version
    local newData = {
        name = oldData.name,
        icon = oldData.icon,
        autoIcon = oldData.autoIcon,
        defaultVersion = oldData.defaultVersion or 1,
        contextOverrides = {},
        versions = {},
        author = SE.metaAuthorBox and SE.metaAuthorBox:GetText() or oldData.author or "",
        version = oldData.version or "1",
        description = SE.metaDescBox and SE.metaDescBox:GetText() or oldData.description or "",
        help = SE.metaHelpBox and SE.metaHelpBox:GetText() or oldData.help or "",
        helplink = SE.metaHelpLinkBox and SE.metaHelpLinkBox:GetText() or oldData.helplink or "",
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
        local DD = GRIPEMS.Defaults
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
            if ver.resetModifiers then
                newData.versions[i].resetModifiers = {}
                for mod, val in pairs(ver.resetModifiers) do
                    newData.versions[i].resetModifiers[mod] = val
                end
            end
            if i == activeIdx then
                -- Active version: save actions tree if present
                if workingActions then
                    newData.versions[i].actions = DD.DeepCopyActions(workingActions)
                    -- Compile flat steps from actions for runtime
                    for j, step in ipairs(steps) do
                        newData.versions[i].steps[j] = step
                    end
                else
                    -- Flat mode: working steps only
                    for j, step in ipairs(steps) do
                        newData.versions[i].steps[j] = step
                    end
                end
            else
                -- Non-active versions: straight copy including actions
                for j, step in ipairs(ver.steps) do
                    newData.versions[i].steps[j] = step
                end
                if ver.actions then
                    newData.versions[i].actions = DD.DeepCopyActions(ver.actions)
                end
            end
        end
    end

    SE._updatingFromEditor = true
    engine:UpdateSequenceData(SE.currentSequence, newData)
    SE._updatingFromEditor = false

    local SL = GRIPEMS.SequenceList
    if SL then
        SL:RefreshDataProvider()
    end

    SE.isDirty = false
    SE:UpdateSaveButtons()

    local US = GRIPEMS.UndoStack
    if US then
        US:Clear()
    end

    -- Refresh metadata updated timestamp
    if SE.metaUpdatedText then
        SE.metaUpdatedText:SetText(date("%Y-%m-%d", time()))
    end

    -- Reload working copy baseline (pass actions for tree mode)
    local newVer = SE:GetEditingVersion(newData)
    SLV:LoadSteps(newVer and newVer.steps or {}, newVer and newVer.actions or nil)
    SE:UpdateKeyPressStatus()

    -- Re-validate spells after save
    SE:UpdateSpellWarning()

    SE:RefreshVersionBar()
    SE:UpdatePreview()

    -- Refresh dependency display after save
    SE:RefreshDependencies()
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
            if SE.pendingVersionSwitch then
                local ver = SE.pendingVersionSwitch
                SE.pendingVersionSwitch = nil
                SE:SwitchVersion(ver)
            end
        end,
        -- button2 = OnCancel = Discard
        OnCancel = function()
            SE.isDirty = false
            local US = GRIPEMS.UndoStack
            if US then
                US:Clear()
            end
            if SL and SL.pendingSelect then
                SL:DoSelectSequence(SL.pendingSelect)
                SL.pendingSelect = nil
            end
            if SE.pendingVersionSwitch then
                local ver = SE.pendingVersionSwitch
                SE.pendingVersionSwitch = nil
                SE:SwitchVersion(ver)
            end
        end,
        -- button3 = OnAlt = Cancel/abort
        OnAlt = function()
            if SL then
                SL.pendingSelect = nil
            end
            SE.pendingVersionSwitch = nil
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
    if not SC then
        return nil
    end

    local text
    if ver.stepFunction == "Priority" or ver.stepFunction == "ReversePriority" then
        text = table.concat(ver.steps, "\n")
    else
        text = ver.steps[1]
    end

    local spellName = SC:ParseSpellFromMacrotext(text)
    if not spellName then
        return nil
    end

    return SC:GetIcon(spellName)
end

---------------------------------------------------------------------------
-- Sequence loading
---------------------------------------------------------------------------

--- Load a sequence into the editor.
--- @param name string|nil Sequence name (nil clears editor)
function SE:LoadSequence(name)
    SE.isDirty = false
    SE.pendingVersionSwitch = nil
    SE:UpdateSaveButtons()

    local US = GRIPEMS.UndoStack
    if US then
        US:Clear()
    end

    if not name then
        SE:Clear()
        return
    end

    -- Auto-activate dormant sequences when user opens them for editing
    if GRIPEMS.Engine:IsSequenceDormant(name) then
        GRIPEMS.Engine:ActivateDormantSequence(name)
    end

    local entry = GRIPEMS.Engine and GRIPEMS.Engine.sequences and GRIPEMS.Engine.sequences[name]
    if not entry or not entry.data then
        SE:Clear()
        return
    end

    SE.currentSequence = name
    local seqData = entry.data

    -- Set version index to the sequence default
    SE.activeVersionIndex = seqData.defaultVersion or 1

    -- Show editor, hide placeholder
    if SE.selectHint then
        SE.selectHint:Hide()
    end
    if SE.header then
        SE.header:Show()
    end
    if SE.metadataSection then
        SE.metadataSection:Show()
    end
    if SE.versionBar then
        SE.versionBar:Show()
    end
    if SE.tabBar then
        SE.tabBar:Show()
    end
    if SE.contentArea then
        SE.contentArea:Show()
    end

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
        if SE.iconTex then
            SE.iconTex:SetTexture(resolvedIcon)
        end
    elseif type(seqData.icon) == "string" and seqData.icon ~= "" then
        -- Legacy string icon name
        if SE.iconTex then
            SE.iconTex:SetTexture("Interface\\Icons\\" .. seqData.icon)
        end
    else
        -- Fallback: question mark
        if SE.iconTex then
            SE.iconTex:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
        end
    end
    SE.resolvedIcon = resolvedIcon

    if SE.nameEditBox then
        SE.nameEditBox:SetText(name)
    end

    -- Populate metadata fields
    if SE.metaAuthorBox then
        SE.metaAuthorBox:SetText(seqData.author or "")
    end
    if SE.metaDescBox then
        SE.metaDescBox:SetText(seqData.description or "")
    end
    if SE.metaHelpBox then
        SE.metaHelpBox:SetText(seqData.help or "")
    end
    if SE.metaHelpLinkBox then
        SE.metaHelpLinkBox:SetText(seqData.helplink or "")
    end
    if SE.holdModeCheck then
        local holdTA = GRIPEMS.TempoAdvisor
        local isHold = holdTA and holdTA:IsHoldMode(name) or false
        SE.holdModeCheck:SetChecked(isHold)
        -- Only show when holdModeEnabled is on
        local holdS = GRIPEMS.Settings
        if holdS and holdS:Get("holdModeEnabled") then
            SE.holdModeCheck:Show()
        else
            SE.holdModeCheck:Hide()
        end
    end
    if SE.metaClassText then
        local className = seqData.classID and seqData.classID > 0 and GetClassInfo(seqData.classID) or ""
        SE.metaClassText:SetText(className)
    end
    if SE.metaSpecText then
        local specName = ""
        -- selene: allow(undefined_variable)
        if seqData.specID and GetSpecializationInfoByID then -- luacheck: ignore 113
            local _, sName = GetSpecializationInfoByID(seqData.specID) -- selene: allow(undefined_variable)
            specName = sName or ""
        end
        SE.metaSpecText:SetText(specName)
    end
    if SE.metaCreatedText then
        SE.metaCreatedText:SetText(seqData.createdAt and date("%Y-%m-%d", seqData.createdAt) or "")
    end
    if SE.metaUpdatedText then
        SE.metaUpdatedText:SetText(seqData.updatedAt and date("%Y-%m-%d", seqData.updatedAt) or "")
    end
    -- Populate click rate info from TempoAdvisor
    if SE.crElements then
        local TA = GRIPEMS.TempoAdvisor
        local rec = TA and TA:GetRecommendation(name)
        if rec then
            local cps = rec.recommendedMs and rec.recommendedMs > 0 and math.floor(1000 / rec.recommendedMs) or 0
            SE.crRecValue:SetText(string.format("%d ms (%d/sec)", rec.recommendedMs or 0, cps))
            SE.crComplexValue:SetText(rec.complexity or "?")
            SE.crConfValue:SetText(rec.confidence or "?")
            -- Update override button text
            local specID = TA:GetCurrentSpecID()
            local hasOverride = false
            if _G.GRIP_EMS_CHAR and GRIP_EMS_CHAR.tempoManualOverride then
                local specOverrides = GRIP_EMS_CHAR.tempoManualOverride[specID]
                if specOverrides and specOverrides[name] then
                    hasOverride = true
                end
            end
            SE.crOverrideBtn:SetText(hasOverride and L["FS_CLEAR_OVERRIDE"] or L["FS_MANUAL_OVERRIDE"])
            for _, el in ipairs(SE.crElements) do
                el:Show()
            end
        else
            for _, el in ipairs(SE.crElements) do
                el:Hide()
            end
        end
    end

    -- Show metadata section
    if SE.metadataSection then
        SE.metadataSection:Show()
    end

    -- Export button state
    if SE.exportBtn then
        SE.exportBtn:Enable()
    end

    -- Step function buttons
    SE:UpdateStepFunctionButtons()

    -- Reset checkboxes (from active version)
    local ver = SE:GetEditingVersion(seqData)
    if SE.cbCombat then
        SE.cbCombat:SetChecked(ver and ver.resetOnCombat or false)
    end
    if SE.cbTarget then
        SE.cbTarget:SetChecked(ver and ver.resetOnTarget or false)
    end
    if SE.cbGear then
        SE.cbGear:SetChecked(ver and ver.resetOnGear or false)
    end
    if SE.cbSpec then
        SE.cbSpec:SetChecked(ver and ver.resetOnSpec or false)
    end
    if SE.timerBox then
        SE.timerBox:SetText(tostring(ver and ver.resetTimer or 0))
    end
    -- Reset modifier overrides
    SE:RefreshResetModCheckboxes(ver)
    if SE.resetModSection then
        SE.resetModSection:Show()
    end
    if SE.keyPressEditBox then
        SE.keyPressEditBox:SetText(ver and ver.keyPress or "")
    end
    if SE.keyReleaseEditBox then
        SE.keyReleaseEditBox:SetText(ver and ver.keyRelease or "")
    end

    -- Set keyPress/keyRelease lengths on SLV before loading steps
    if GRIPEMS.StepListView then
        GRIPEMS.StepListView.keyPressLen = ver and #(ver.keyPress or "") or 0
        GRIPEMS.StepListView.keyReleaseLen = ver and #(ver.keyRelease or "") or 0
        GRIPEMS.StepListView:LoadSteps(ver and ver.steps or {}, ver and ver.actions or nil)
    end
    SE:UpdateKeyPressStatus()

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

    -- Update spell warning banner
    SE:UpdateSpellWarning()

    -- Update priority preview
    SE:UpdatePreview()

    -- Refresh dependency display
    SE:RefreshDependencies()

    -- Refresh stub preview
    SE:RefreshStubPreview()

    -- Show stub section
    if SE.stubSection then
        SE.stubSection:Show()
    end

    -- Make sure correct tab content is showing
    SE:UpdateTabContent()
end

--- Refresh all editor controls from the currently selected version
--- without changing which sequence is loaded.
function SE:LoadVersionIntoEditor()
    if not SE.currentSequence then
        return
    end
    local engine = GRIPEMS.Engine
    if not engine or not engine.sequences then
        return
    end
    local entry = engine.sequences[SE.currentSequence]
    if not entry or not entry.data then
        return
    end

    local seqData = entry.data
    local ver = SE:GetEditingVersion(seqData)

    SE:UpdateStepFunctionButtons()

    if SE.cbCombat then
        SE.cbCombat:SetChecked(ver and ver.resetOnCombat or false)
    end
    if SE.cbTarget then
        SE.cbTarget:SetChecked(ver and ver.resetOnTarget or false)
    end
    if SE.cbGear then
        SE.cbGear:SetChecked(ver and ver.resetOnGear or false)
    end
    if SE.cbSpec then
        SE.cbSpec:SetChecked(ver and ver.resetOnSpec or false)
    end
    if SE.timerBox then
        SE.timerBox:SetText(tostring(ver and ver.resetTimer or 0))
    end
    SE:RefreshResetModCheckboxes(ver)

    if SE.keyPressEditBox then
        SE.keyPressEditBox:SetText(ver and ver.keyPress or "")
    end
    if SE.keyReleaseEditBox then
        SE.keyReleaseEditBox:SetText(ver and ver.keyRelease or "")
    end

    if GRIPEMS.StepListView then
        GRIPEMS.StepListView.keyPressLen = ver and #(ver.keyPress or "") or 0
        GRIPEMS.StepListView.keyReleaseLen = ver and #(ver.keyRelease or "") or 0
        GRIPEMS.StepListView:LoadSteps(ver and ver.steps or {}, ver and ver.actions or nil)
    end
    SE:UpdateKeyPressStatus()

    SE:RefreshVersionBar()
    SE:UpdatePreview()
    SE:RefreshStubPreview()
    SE:UpdateTabContent()

    SE.isDirty = false
    SE:UpdateSaveButtons()
end

--- Switch to a different version index, then refresh editor controls.
function SE:SwitchVersion(idx)
    if not SE.currentSequence then
        return
    end
    local engine = GRIPEMS.Engine
    if not engine or not engine.sequences then
        return
    end
    local entry = engine.sequences[SE.currentSequence]
    if not entry or not entry.data then
        return
    end

    local seqData = entry.data
    local maxVer = seqData.versions and #seqData.versions or 1
    if idx < 1 or idx > maxVer then
        return
    end
    if idx == SE.activeVersionIndex then
        return
    end

    if SE.isDirty then
        SE.pendingVersionSwitch = idx
        SE:PromptSave()
        return
    end

    SE.activeVersionIndex = idx
    SE:LoadVersionIntoEditor()
end

--- Clear the editor to its default empty state.
function SE:Clear()
    SE.currentSequence = nil
    SE.isDirty = false
    SE.pendingVersionSwitch = nil
    SE.activeVersionIndex = 1

    if SE.selectHint then
        SE.selectHint:Show()
    end
    if SE.header then
        SE.header:Hide()
    end
    -- Hide and reset stub section to collapsed
    if SE.stubSection then
        SE.stubSection:Hide()
        SE.stubExpanded = false
        SE.stubSection:SetHeight(18)
        if SE.stubContentBox then
            SE.stubContentBox:Hide()
            SE.stubContentBox:SetText("")
        end
        if SE.stubArrow then
            SE.stubArrow:SetText(">")
        end
    end
    -- Hide and reset metadata section to collapsed
    if SE.metadataSection then
        SE.metadataSection:Hide()
        SE.metadataExpanded = false
        SE.metadataSection:SetHeight(18)
        if SE.metadataContent then
            SE.metadataContent:Hide()
        end
        if SE.metaArrow then
            SE.metaArrow:SetText(">")
        end
    end
    -- Hide and reset reset-modifier section to collapsed
    if SE.resetModSection then
        SE.resetModSection:Hide()
        SE.resetModExpanded = false
        SE.resetModSection:SetHeight(18)
        if SE.resetModContent then
            SE.resetModContent:Hide()
        end
    end
    if SE.holdModeCheck then
        SE.holdModeCheck:SetChecked(false)
        SE.holdModeCheck:Hide()
    end
    if SE.metaAuthorBox then
        SE.metaAuthorBox:SetText("")
    end
    if SE.metaDescBox then
        SE.metaDescBox:SetText("")
    end
    if SE.metaHelpBox then
        SE.metaHelpBox:SetText("")
    end
    if SE.metaHelpLinkBox then
        SE.metaHelpLinkBox:SetText("")
    end
    if SE.metaClassText then
        SE.metaClassText:SetText("")
    end
    if SE.metaSpecText then
        SE.metaSpecText:SetText("")
    end
    if SE.metaCreatedText then
        SE.metaCreatedText:SetText("")
    end
    if SE.metaUpdatedText then
        SE.metaUpdatedText:SetText("")
    end
    -- Hide click rate info block
    if SE.crElements then
        for _, el in ipairs(SE.crElements) do
            el:Hide()
        end
    end
    -- Clear dependency rows
    if SE.depRows then
        for _, fs in ipairs(SE.depRows) do
            fs:Hide()
            fs:SetParent(nil)
        end
        SE.depRows = {}
    end
    if SE.versionBar then
        SE.versionBar:Hide()
    end
    if SE.tabBar then
        SE.tabBar:Hide()
    end
    if SE.contentArea then
        SE.contentArea:Hide()
    end

    if SE.iconTex then
        SE.iconTex:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
    end
    if SE.nameEditBox then
        SE.nameEditBox:SetText("")
    end
    if SE.cbCombat then
        SE.cbCombat:SetChecked(false)
    end
    if SE.cbTarget then
        SE.cbTarget:SetChecked(false)
    end
    if SE.cbGear then
        SE.cbGear:SetChecked(false)
    end
    if SE.cbSpec then
        SE.cbSpec:SetChecked(false)
    end
    if SE.timerBox then
        SE.timerBox:SetText("0")
    end
    if SE.keyPressEditBox then
        SE.keyPressEditBox:SetText("")
    end
    if SE.keyReleaseEditBox then
        SE.keyReleaseEditBox:SetText("")
    end
    if SE.exportBtn then
        SE.exportBtn:Disable()
    end

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
    if SE.previewFrame then
        SE.previewFrame:Hide()
    end
end

---------------------------------------------------------------------------
-- Callback handler
---------------------------------------------------------------------------

--- Refresh editor if the currently viewed sequence was updated externally.
function SE:OnSequenceUpdated(event, name, seqData)
    if SE._updatingFromEditor then
        return
    end
    if not SE.container or not SE.container:IsVisible() then
        return
    end
    if name and name == SE.currentSequence then
        SE:LoadSequence(name)
    end
end

--- Refresh KeybindTab if the active tab is Keybind.
function SE:OnKeybindChangedEditor(event, seqName, key)
    if not SE.container or not SE.container:IsVisible() then
        return
    end
    if SE.activeTab == "Keybind" and GRIPEMS.KeybindTab then
        GRIPEMS.KeybindTab:RefreshDisplay()
    end
end

--- Refresh spell warnings and preview when spell validation results change.
function SE:OnSpellValidationUpdated()
    if not SE.container or not SE.container:IsVisible() then
        return
    end
    if SE.currentSequence then
        SE:UpdateSpellWarning()
        SE:UpdatePreview()
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
    if not SE.currentSequence then
        return
    end
    local C = UI.Colors
    local defaults = D()

    -- Create the picker frame on first call, reuse after
    if not SE.iconPicker then
        local picker = CreateFrame("Frame", "GRIPEMS_IconPicker", UIParent, "BackdropTemplate")
        picker:SetSize(defaults.ICON_PICKER_WIDTH, defaults.ICON_PICKER_HEIGHT)
        picker:SetFrameStrata("DIALOG")
        UI:ApplyBackdrop(picker, UI.Backdrops.panel, C.bgMain, C.border)
        picker:EnableMouse(true)
        picker:SetMovable(true)
        picker:RegisterForDrag("LeftButton")
        picker:SetScript("OnDragStart", function(self)
            self:StartMoving()
        end)
        picker:SetScript("OnDragStop", function(self)
            self:StopMovingOrSizing()
        end)
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
        UI:ApplyBackdrop(closeBtn, UI.Backdrops.panel, C.bgButton, C.border)
        local pickerCloseLbl = closeBtn:CreateFontString(nil, "OVERLAY")
        UI:SetFont(pickerCloseLbl, 14)
        pickerCloseLbl:SetPoint("CENTER", 0, 1)
        pickerCloseLbl:SetText("X")
        pickerCloseLbl:SetTextColor(C.textSecondary:GetRGBA())
        closeBtn:SetScript("OnClick", function()
            picker:Hide()
        end)
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
            if not SE.currentSequence then
                return
            end
            local engine = GRIPEMS.Engine
            if not engine or not engine.sequences then
                return
            end
            local entry = engine.sequences[SE.currentSequence]
            if not entry or not entry.data then
                return
            end

            entry.data.autoIcon = true
            entry.data.icon = nil
            SE.isDirty = true
            SE:UpdateSaveButtons()

            -- Refresh the editor icon
            local autoIcon = SE:AutoDetectIcon(entry.data)
            if autoIcon then
                if SE.iconTex then
                    SE.iconTex:SetTexture(autoIcon)
                end
                SE.resolvedIcon = autoIcon
            else
                if SE.iconTex then
                    SE.iconTex:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
                end
                SE.resolvedIcon = nil
            end

            local SL = GRIPEMS.SequenceList
            if SL then
                SL:RefreshDataProvider()
            end

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
        local scrollFrame, scrollChild = UI:CreateScrollPanel(picker, 300)
        scrollFrame:SetPoint("TOPLEFT", autoBtn, "BOTTOMLEFT", 0, -6)
        scrollFrame:SetPoint("BOTTOMRIGHT", picker, "BOTTOMRIGHT", -26, 8)
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
    if not picker then
        return
    end

    local SC = GRIPEMS.SpellCache
    if not SC then
        return
    end

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
    if childHeight < 1 then
        childHeight = 1
    end
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
                if not SE.currentSequence then
                    return
                end
                local engine = GRIPEMS.Engine
                if not engine or not engine.sequences then
                    return
                end
                local entry = engine.sequences[SE.currentSequence]
                if not entry or not entry.data then
                    return
                end

                entry.data.icon = self._iconID
                entry.data.autoIcon = false
                SE.isDirty = true
                SE:UpdateSaveButtons()

                if SE.iconTex then
                    SE.iconTex:SetTexture(self._iconID)
                end
                SE.resolvedIcon = self._iconID

                local SL = GRIPEMS.SequenceList
                if SL then
                    SL:RefreshDataProvider()
                end

                picker:Hide()
            end)

            picker.iconButtons[i] = btn
        end

        -- Position in grid
        local row = math.floor((i - 1) / cols)
        local col = (i - 1) % cols
        btn:ClearAllPoints()
        btn:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", col * (size + gap), -(row * (size + gap)))

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
function SE:UpdatePreview()
    if not SE.previewFrame then
        return
    end

    local engine = GRIPEMS.Engine
    local entry = SE.currentSequence and engine and engine.sequences and engine.sequences[SE.currentSequence]
    local seqData = entry and entry.data
    local ver = seqData and SE:GetEditingVersion(seqData)

    -- Show for ALL step functions with steps
    if not ver or not ver.steps or #ver.steps == 0 then
        SE.previewFrame:Hide()
        -- Hide icon strip elements
        if SE.previewIconScroll then
            SE.previewIconScroll:Hide()
        end
        if SE.previewRandomHint then
            SE.previewRandomHint:Hide()
        end
        -- Hide text elements
        if SE.previewFade then
            SE.previewFade:Hide()
        end
        if SE.previewOverflowHint then
            SE.previewOverflowHint:Hide()
        end
        if SE.previewCopyBtn then
            SE.previewCopyBtn:Hide()
        end
        if SE.previewScroll then
            SE.previewScroll:SetVerticalScroll(0)
        end
        -- Restore tab bar anchor
        if SE.tabBar and SE.versionBar then
            SE.tabBar:ClearAllPoints()
            SE.tabBar:SetPoint("TOPLEFT", SE.versionBar, "BOTTOMLEFT", 0, 0)
            SE.tabBar:SetPoint("TOPRIGHT", SE.versionBar, "BOTTOMRIGHT", 0, 0)
        end
        return
    end

    -- Show preview frame
    SE.previewFrame:Show()

    -- Shift tab bar below preview
    if SE.tabBar then
        SE.tabBar:ClearAllPoints()
        SE.tabBar:SetPoint("TOPLEFT", SE.previewFrame, "BOTTOMLEFT", 0, 0)
        SE.tabBar:SetPoint("TOPRIGHT", SE.previewFrame, "BOTTOMRIGHT", 0, 0)
    end

    -- Determine mode
    local S = GRIPEMS.Settings
    local mode = S and S:Get("previewMode") or D().PREVIEW_MODE_ICONS

    -- Update toggle button label
    if SE.previewToggleBtn and SE.previewToggleBtn.label then
        local modeLabels = {
            [D().PREVIEW_MODE_ICONS] = L["GEMS_PREVIEW_ICONS"],
            [D().PREVIEW_MODE_TEXT] = L["GEMS_PREVIEW_TEXT"],
            [D().PREVIEW_MODE_COMPILED] = L["GEMS_PREVIEW_COMPILED"],
        }
        SE.previewToggleBtn.label:SetText(modeLabels[mode] or L["GEMS_PREVIEW_ICONS"])
    end

    if mode == D().PREVIEW_MODE_ICONS then
        SE:UpdatePreviewIcons(ver, seqData)
    elseif mode == D().PREVIEW_MODE_COMPILED then
        SE:UpdatePreviewCompiled(ver)
    else
        SE:UpdatePreviewText(ver)
    end
end

--- Icon strip preview mode. Shows spell icons for simulated keypresses.
function SE:UpdatePreviewIcons(ver, seqData)
    local C = UI.Colors
    local defaults = D()

    -- Hide text mode elements
    if SE.previewScroll then
        SE.previewScroll:Hide()
    end
    if SE.previewFade then
        SE.previewFade:Hide()
    end
    if SE.previewOverflowHint then
        SE.previewOverflowHint:Hide()
    end
    if SE.previewCharCount then
        SE.previewCharCount:Hide()
    end
    if SE.previewCopyBtn then
        SE.previewCopyBtn:Hide()
    end

    -- Show icon mode elements
    if SE.previewIconScroll then
        SE.previewIconScroll:Show()
    end

    -- Simulate steps
    local simulated = GRIPEMS.Engine:SimulateSteps(seqData, defaults.PREVIEW_MAX_STEPS)
    if #simulated == 0 then
        SE:HideAllPreviewIcons()
        return
    end

    -- Random hint
    if SE.previewRandomHint then
        if simulated[1] and simulated[1].isRandom then
            SE.previewRandomHint:Show()
        else
            SE.previewRandomHint:Hide()
        end
    end

    -- Create/reuse icon buttons
    SE.previewIcons = SE.previewIcons or {}
    local iconSize = defaults.PREVIEW_ICON_SIZE
    local spacing = defaults.PREVIEW_ICON_SPACING

    for i, stepData in ipairs(simulated) do
        local btn = SE.previewIcons[i]
        if not btn then
            btn = CreateFrame("Button", nil, SE.previewIconContainer)
            btn:SetSize(iconSize, iconSize)

            -- Icon texture
            btn.icon = btn:CreateTexture(nil, "ARTWORK")
            btn.icon:SetAllPoints()

            -- Step number overlay (bottom-right corner)
            btn.stepNum = btn:CreateFontString(nil, "OVERLAY")
            UI:SetFont(btn.stepNum, 9)
            btn.stepNum:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -1, 1)
            btn.stepNum:SetJustifyH("RIGHT")

            -- Highlight on hover
            btn.highlight = btn:CreateTexture(nil, "HIGHLIGHT")
            btn.highlight:SetAllPoints()
            btn.highlight:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
            btn.highlight:SetBlendMode("ADD")
            btn.highlight:SetAlpha(0.3)

            -- Validity tint overlay
            btn.tintOverlay = btn:CreateTexture(nil, "OVERLAY")
            btn.tintOverlay:SetAllPoints()
            btn.tintOverlay:SetTexture("Interface\\Buttons\\WHITE8x8")
            btn.tintOverlay:SetBlendMode("ADD")
            btn.tintOverlay:SetAlpha(0)

            SE.previewIcons[i] = btn
        end

        -- Position: horizontal row
        btn:ClearAllPoints()
        if i == 1 then
            btn:SetPoint("LEFT", SE.previewIconContainer, "LEFT", 0, 0)
        else
            btn:SetPoint("LEFT", SE.previewIcons[i - 1], "RIGHT", spacing, 0)
        end

        -- Set icon texture
        local iconID = stepData.iconID
        if iconID then
            btn.icon:SetTexture(iconID)
        else
            btn.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
        end

        -- Step number
        btn.stepNum:SetText(tostring(stepData.stepIndex))
        btn.stepNum:SetTextColor(C.textSecondary:GetRGBA())

        -- Spell status tint
        local status = stepData.spellStatus
        if status == defaults.SPELL_STATUS_UNKNOWN then
            btn.tintOverlay:SetVertexColor(1, 0, 0)
            btn.tintOverlay:SetAlpha(0.25)
        elseif status == defaults.SPELL_STATUS_KNOWN then
            btn.tintOverlay:SetVertexColor(1, 0.6, 0)
            btn.tintOverlay:SetAlpha(0.2)
        else
            btn.tintOverlay:SetAlpha(0)
        end

        -- Random indicator
        if stepData.isRandom then
            btn.stepNum:SetText("?")
            btn.stepNum:SetTextColor(C.textMuted:GetRGBA())
        end

        -- Tooltip
        btn:SetScript("OnEnter", function(self)
            local title = string.format(L["GEMS_PREVIEW_STEP_TOOLTIP"], stepData.stepIndex, stepData.spellName or "")
            local body = stepData.macrotext or ""
            if stepData.spellStatus then
                body = body .. "\n\n" .. string.format(L["GEMS_PREVIEW_SPELL_TOOLTIP"], stepData.spellName or "unknown")
            end
            UI:ShowTooltip(self, title, body)
        end)
        btn:SetScript("OnLeave", function()
            UI:HideTooltip()
        end)

        btn:Show()
    end

    -- Hide excess icons from previous render
    for i = #simulated + 1, #SE.previewIcons do
        SE.previewIcons[i]:Hide()
    end

    -- Update icon container width for scrolling
    local totalWidth = #simulated * (iconSize + spacing) - spacing
    if SE.previewIconContainer then
        SE.previewIconContainer:SetWidth(math.max(totalWidth, 1))
    end
end

--- Text list preview mode. Shows numbered macrotext lines for all step functions.
function SE:UpdatePreviewText(ver)
    local C = UI.Colors
    local defaults = D()

    -- Hide icon mode elements
    if SE.previewIconScroll then
        SE.previewIconScroll:Hide()
    end
    if SE.previewRandomHint then
        SE.previewRandomHint:Hide()
    end
    if SE.iconFadeRight then
        SE.iconFadeRight:Hide()
    end
    if SE.iconFadeLeft then
        SE.iconFadeLeft:Hide()
    end
    if SE.iconChevronLeft then
        SE.iconChevronLeft:Hide()
    end
    if SE.iconChevronRight then
        SE.iconChevronRight:Hide()
    end
    if SE.iconChevronLeftBtn then
        SE.iconChevronLeftBtn:Hide()
    end
    if SE.iconChevronRightBtn then
        SE.iconChevronRightBtn:Hide()
    end
    if SE.iconScrollTrack then
        SE.iconScrollTrack:Hide()
    end

    -- Show text mode elements
    if SE.previewScroll then
        SE.previewScroll:ClearAllPoints()
        SE.previewScroll:SetPoint("TOPLEFT", SE.previewFrame, "TOPLEFT", 4, -2)
        SE.previewScroll:SetPoint("BOTTOMRIGHT", SE.previewFrame, "BOTTOMRIGHT", -112, 14)
        SE.previewScroll:Show()
    end
    if SE.previewCharCount then
        SE.previewCharCount:Show()
    end
    if SE.previewCopyBtn then
        SE.previewCopyBtn:Show()
    end

    local SF = GRIPEMS.StepFunctions
    local sf = ver.stepFunction or "Sequential"

    -- Build execution order as macrotext strings
    local resolvedSteps = {}
    for i, stepText in ipairs(ver.steps) do
        resolvedSteps[i] = GRIPEMS.Engine:SubstituteVariables(tostring(stepText))
    end

    local displaySteps
    if sf == "Priority" then
        local expanded = SF:ExpandPriority(resolvedSteps)
        displaySteps = {}
        for _, e in ipairs(expanded) do
            displaySteps[#displaySteps + 1] = e.macrotext or ""
        end
    elseif sf == "ReversePriority" then
        local expanded = SF:ExpandReversePriority(resolvedSteps)
        displaySteps = {}
        for _, e in ipairs(expanded) do
            displaySteps[#displaySteps + 1] = e.macrotext or ""
        end
    else
        -- Sequential or Random: show steps as-is
        displaySteps = resolvedSteps
    end

    -- Build preview text
    local previewLines = {}
    local maxLen = 0
    for i, mt in ipairs(displaySteps) do
        previewLines[#previewLines + 1] = string.format("[%d] %s", i, mt)
        if #mt > maxLen then
            maxLen = #mt
        end
    end
    local compiled = table.concat(previewLines, "\n")

    if SE.previewEditBox then
        SE.previewEditBox:SetText(compiled)
    end

    -- Update scroll child width
    if SE.previewScroll then
        local w = SE.previewScroll:GetWidth()
        if w and w > 0 and SE.previewEditBox then
            SE.previewEditBox:SetWidth(w)
        end
    end

    -- Check overflow
    C_Timer.After(0, function()
        if not SE.previewScroll then
            return
        end
        local maxScroll = SE.previewScroll:GetVerticalScrollRange()
        local hasOverflow = maxScroll and maxScroll > 1
        if SE.previewFade then
            SE.previewFade:SetShown(hasOverflow)
        end
        if SE.previewOverflowHint then
            SE.previewOverflowHint:SetShown(hasOverflow)
        end
    end)

    -- Char count display
    if SE.previewCharCount then
        local displayLimit = defaults.MAX_MACROTEXT_LENGTH
        SE.previewCharCount:SetText(
            string.format("%d steps | longest: %d/%d chars", #displaySteps, maxLen, displayLimit)
        )
        if maxLen >= displayLimit then
            SE.previewCharCount:SetTextColor(C.textError:GetRGBA())
        elseif maxLen > defaults.CHAR_COUNT_WARNING then
            SE.previewCharCount:SetTextColor(C.textWarning:GetRGBA())
        else
            SE.previewCharCount:SetTextColor(C.textSuccess:GetRGBA())
        end
    end
end

--- Compiled preview mode. Shows actual macrotext WoW executes per step.
function SE:UpdatePreviewCompiled(ver)
    local C = UI.Colors
    local defaults = D()

    -- Hide icon mode elements
    if SE.previewIconScroll then
        SE.previewIconScroll:Hide()
    end
    if SE.previewRandomHint then
        SE.previewRandomHint:Hide()
    end
    if SE.iconFadeRight then
        SE.iconFadeRight:Hide()
    end
    if SE.iconFadeLeft then
        SE.iconFadeLeft:Hide()
    end
    if SE.iconChevronLeft then
        SE.iconChevronLeft:Hide()
    end
    if SE.iconChevronRight then
        SE.iconChevronRight:Hide()
    end
    if SE.iconChevronLeftBtn then
        SE.iconChevronLeftBtn:Hide()
    end
    if SE.iconChevronRightBtn then
        SE.iconChevronRightBtn:Hide()
    end
    if SE.iconScrollTrack then
        SE.iconScrollTrack:Hide()
    end

    -- Show text mode elements
    if SE.previewScroll then
        SE.previewScroll:ClearAllPoints()
        SE.previewScroll:SetPoint("TOPLEFT", SE.previewFrame, "TOPLEFT", 4, -2)
        SE.previewScroll:SetPoint("BOTTOMRIGHT", SE.previewFrame, "BOTTOMRIGHT", -112, 14)
        SE.previewScroll:Show()
    end
    if SE.previewCharCount then
        SE.previewCharCount:Show()
    end
    if SE.previewCopyBtn then
        SE.previewCopyBtn:Show()
    end

    -- Compile steps with kp/kr fitting
    local kp = ver.keyPress or ""
    local kr = ver.keyRelease or ""
    local compiledSteps = GRIPEMS.Engine:CompileSteps(ver.steps, kp, kr)

    -- Color helper: convert UI.Colors object to WoW escape code
    local function colorToHex(c)
        return string.format("|cff%02x%02x%02x", c.r * 255, c.g * 255, c.b * 255)
    end

    -- Build per-step preview lines with char count
    local previewLines = {}
    local maxLen = 0
    local fitted = 0
    local total = #compiledSteps
    for i, entry in ipairs(compiledSteps) do
        local mt = entry.macrotext or ""
        local len = #mt
        if len > maxLen then
            maxLen = len
        end
        -- Color the char count bracket
        local countColor
        if len >= defaults.CHAR_COUNT_DANGER then
            countColor = colorToHex(C.textError)
        elseif len >= defaults.CHAR_COUNT_WARNING then
            countColor = colorToHex(C.textWarning)
        else
            countColor = colorToHex(C.textSuccess)
        end
        previewLines[#previewLines + 1] =
            string.format("[%d] %s  %s(%d/%d)|r", i, mt, countColor, len, defaults.MAX_SAB_MACROTEXT_LENGTH)
        -- Track kp fitting (step includes kp when macrotext starts with it)
        if kp ~= "" and mt:sub(1, #kp) == kp then
            fitted = fitted + 1
        end
    end

    -- Append kp fit summary below the step list
    if kp ~= "" then
        previewLines[#previewLines + 1] = ""
        local fitColor
        if fitted >= total then
            fitColor = colorToHex(C.textSuccess)
        elseif fitted > 0 then
            fitColor = colorToHex(C.textWarning)
        else
            fitColor = colorToHex(C.textError)
        end
        previewLines[#previewLines + 1] = fitColor .. L["GEMS_PREVIEW_KP_FIT"]:format(fitted, total) .. "|r"
        if fitted < total then
            previewLines[#previewLines + 1] = fitColor .. L["GEMS_PREVIEW_KP_DROPPED"] .. "|r"
        end
    end

    local text = table.concat(previewLines, "\n")
    if SE.previewEditBox then
        SE.previewEditBox:SetText(text)
    end

    -- Update previewCharCount label with max step length
    if SE.previewCharCount then
        SE.previewCharCount:SetText(string.format("max %d/%d", maxLen, defaults.MAX_SAB_MACROTEXT_LENGTH))
        if maxLen >= defaults.CHAR_COUNT_DANGER then
            SE.previewCharCount:SetTextColor(C.textError:GetRGBA())
        elseif maxLen >= defaults.CHAR_COUNT_WARNING then
            SE.previewCharCount:SetTextColor(C.textWarning:GetRGBA())
        else
            SE.previewCharCount:SetTextColor(C.textSuccess:GetRGBA())
        end
    end

    -- Update scroll child width
    if SE.previewScroll then
        local w = SE.previewScroll:GetWidth()
        if w and w > 0 and SE.previewEditBox then
            SE.previewEditBox:SetWidth(w)
        end
    end

    -- Check overflow (same pattern as UpdatePreviewText)
    C_Timer.After(0, function()
        if not SE.previewScroll then
            return
        end
        local maxScroll = SE.previewScroll:GetVerticalScrollRange()
        local hasOverflow = maxScroll and maxScroll > 1
        if SE.previewFade then
            SE.previewFade:SetShown(hasOverflow)
        end
        if SE.previewOverflowHint then
            SE.previewOverflowHint:SetShown(hasOverflow)
        end
    end)
end

--- Hide all preview icon buttons (cleanup helper).
function SE:HideAllPreviewIcons()
    if SE.previewIcons then
        for _, btn in ipairs(SE.previewIcons) do
            btn:Hide()
        end
    end
end

--- Update the version bar dropdown text and button states.
function SE:RefreshVersionBar()
    if not SE.versionBar then
        return
    end
    local entry = GRIPEMS.Engine and GRIPEMS.Engine.sequences and GRIPEMS.Engine.sequences[SE.currentSequence]
    if not entry or not entry.data then
        return
    end
    local total = entry.data.versions and #entry.data.versions or 1
    local isDefault = SE.activeVersionIndex == (entry.data.defaultVersion or 1)

    -- Update dropdown button text
    if SE.versionBtn and SE.versionBtn.label then
        local txt = string.format(L["GEMS_VERSION_OF"], SE.activeVersionIndex, total)
        if isDefault then
            txt = txt .. L["GEMS_VERSION_DEFAULT_MARKER"]
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
