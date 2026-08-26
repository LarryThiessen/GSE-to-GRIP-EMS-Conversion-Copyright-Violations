-- GRIP-EMS: Sequence Editor
-- Created: 2025 (pre-stamping)
-- Updated: 2026-08-17
-- Patch: 12.1.0.69299 Midnight (Retail LIVE)
--
-- Right panel: editor header, tab bar, and content area for sequence editing.
-- Phase 2 #7: the editBoxFocused flag has been relocated to GRIPEMS.Focus so
-- cross-module handlers (MainFrame OnKeyDown, modal OnKeyDown) share a single
-- source of truth. A legacy SE.editBoxFocused metatable forwards reads from
-- callers that have not yet migrated.

local ADDON_NAME, GRIPEMS = ...
local UI = GRIPEMS.UI
local L = LibStub("AceLocale-3.0"):GetLocale("GRIP-EMS", true)

-- Upvalue accessor for Defaults
local function D()
    return GRIPEMS.Defaults
end

GRIPEMS.SequenceEditor = {}
local SE = GRIPEMS.SequenceEditor

-- Phase 2 #7 back-compat: SE.editBoxFocused now lives on GRIPEMS.Focus.
-- Reads of SE.editBoxFocused fall through to the Focus manager; writes go
-- through Focus:SetEditBoxFocused and never touch the SE table directly.
setmetatable(SE, {
    __index = function(_, k)
        if k == "editBoxFocused" then
            if GRIPEMS.Focus and GRIPEMS.Focus.IsEditBoxFocused then
                return GRIPEMS.Focus:IsEditBoxFocused()
            end
            return false
        end
        return nil
    end,
})

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
    -- type(), not truthiness. A bare-truthiness head check passes a SCALAR
    -- .versions straight through to the index below, and "attempt to index
    -- field 'versions' (a number value)" raises on 5 and on true. This line
    -- became reachable with a scalar only after SE:SwitchVersion was given its
    -- own type() guard: before that, SwitchVersion raised at the length
    -- operator and never got here. With the guard, maxVer falls back to 1,
    -- idx = 1 clears the range check, and LoadVersionIntoEditor calls this
    -- function -- so the raise was RELOCATED here, not removed.
    if not seqData or type(seqData.versions) ~= "table" then
        return nil
    end
    local idx = SE.activeVersionIndex or 1
    return seqData.versions[idx] or seqData.versions[1]
end

---------------------------------------------------------------------------
-- Dependency scanner (S08b)
---------------------------------------------------------------------------

--- Scan the current sequence steps for variable and sequence references.
--- Returns a table with variables, sequences, embeddedBy, and macros arrays.
--- macros are read from MetaData.Dependencies.Macros (author-tagged), not
--- derived from step scanning. variables/sequences are step-derived.
--- @param seqData table Sequence data with versions
--- @return table { variables={...}, sequences={...}, embeddedBy={...}, macros={...} }
function SE:ScanDependencies(seqData)
    local result = {
        variables = {},
        sequences = {},
        embeddedBy = {},
        macros = {},
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
            for varName in step:gmatch(D().VAR_PATTERN) do
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
                    if type(otherData.versions) == "table" then
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

    -- v2.2.0 L87 EMS-MACRO-DEPS-NATIVE-SEQUENCE-TAGGING: surface author-
    -- tagged macros from MetaData.Dependencies.Macros (read-only; tags are
    -- maintained by MacrosTab, not derived from step scanning).
    if seqData.MetaData and seqData.MetaData.Dependencies and type(seqData.MetaData.Dependencies.Macros) == "table" then
        for _, macName in ipairs(seqData.MetaData.Dependencies.Macros) do
            result.macros[#result.macros + 1] = { name = macName }
        end
        table.sort(result.macros, function(a, b)
            return a.name < b.name
        end)
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
    if GRIPEMS.UI and GRIPEMS.UI.RegisterPanelFrame then
        GRIPEMS.UI:RegisterPanelFrame(SE.container, "panel", "panel.sequenceEditor")
    end

    -- Phase C: wrap the visible editor CONTENT in a transparent mountable root.
    -- Keyboard / Focus / ConsolePort / resize wiring stays on the real panel
    -- (parentPanel / SE.container); only the content frames build into SE.root,
    -- which SetAllPoints the panel so classic renders identically. A modern
    -- layout provider mounts SE.root into its own host.
    SE.root = CreateFrame("Frame", nil, parentPanel)
    SE.root:SetAllPoints(parentPanel)
    if GRIPEMS.RegisterMountablePanel then
        GRIPEMS:RegisterMountablePanel("editor", SE.root)
    end

    -- Phase 2 #7/#8: register SequenceEditor as a named Focus region so the
    -- focus-ring renderer can anchor overlays here.
    if GRIPEMS.Focus and GRIPEMS.Focus.RegisterRegion then
        GRIPEMS.Focus:RegisterRegion("SequenceEditor", parentPanel)
    end

    -- Register with ConsolePort cursor navigation (nil-safe)
    if ConsolePort and ConsolePort.AddInterfaceCursorFrame then
        ConsolePort:AddInterfaceCursorFrame(parentPanel)
    end

    -- "Select a sequence" placeholder (shown when nothing selected)
    local selectHint = SE.root:CreateFontString(nil, "OVERLAY")
    UI:SetFont(selectHint, 12)
    selectHint:SetPoint("CENTER", SE.root, "CENTER", 0, 0)
    selectHint:SetText(L["GEMS_UI_SELECT_SEQUENCE"])
    selectHint:SetTextColor(C.textMuted:GetRGBA())
    SE.selectHint = selectHint

    -----------------------------------------------------------------------
    -- Phase F T2: deferred-engagement ScrollFrame wrap of rightPanel content.
    -- Wraps header + sections + spellBanner + versionBar + previewFrame + tabBar + contentArea
    -- so the chrome scrolls if user-expanded sections + previewFrame exceed rightPanel.height.
    -- Scrollbar is HIDDEN when scrollChild fits viewport (deferred engagement -- opposite of Phase E always-visible).
    -----------------------------------------------------------------------
    local rightPanelScroll = CreateFrame("ScrollFrame", nil, SE.root)
    rightPanelScroll:SetPoint("TOPLEFT", SE.root, "TOPLEFT", 0, 0)
    rightPanelScroll:SetPoint("BOTTOMRIGHT", SE.root, "BOTTOMRIGHT", -14, 0) -- 14 px right margin for scrollbar
    SE.rightPanelScroll = rightPanelScroll

    local scrollChild = CreateFrame("Frame", nil, rightPanelScroll)
    scrollChild:SetSize(parentPanel:GetWidth() or 480, parentPanel:GetHeight() or 460)
    rightPanelScroll:SetScrollChild(scrollChild)
    SE.rightPanelScrollChild = scrollChild

    -- Width sync: scrollChild width follows rightPanelScroll width
    rightPanelScroll:SetScript("OnSizeChanged", function(self, w, _h)
        if w and w > 0 then
            scrollChild:SetWidth(w)
        end
    end)

    -- Mousewheel scroll
    rightPanelScroll:EnableMouseWheel(true)
    rightPanelScroll:SetScript("OnMouseWheel", function(self, delta)
        local current = self:GetVerticalScroll() or 0
        local maxScroll = self:GetVerticalScrollRange() or 0
        local step = 30
        local newScroll = current - (delta * step)
        newScroll = math.max(0, math.min(newScroll, maxScroll))
        self:SetVerticalScroll(newScroll)
    end)

    -- MinimalScrollBar widget. Deferred-engagement: hidden when scroll range == 0.
    local rightPanelScrollBar = CreateFrame("EventFrame", nil, SE.root, "MinimalScrollBar")
    rightPanelScrollBar:SetPoint("TOPLEFT", rightPanelScroll, "TOPRIGHT", 2, 0)
    rightPanelScrollBar:SetPoint("BOTTOMLEFT", rightPanelScroll, "BOTTOMRIGHT", 2, 20) -- Phase F.2: clear MainFrame resizeGrip (16x16 at BOTTOMRIGHT - 2, +2 = ~18 px corner footprint + 2 px safety)
    SE.rightPanelScrollBar = rightPanelScrollBar

    rightPanelScrollBar:RegisterCallback("OnScroll", function(_self, scrollPercentage)
        local maxScroll = rightPanelScroll:GetVerticalScrollRange() or 0
        rightPanelScroll:SetVerticalScroll(scrollPercentage * maxScroll)
    end, rightPanelScrollBar)
    rightPanelScroll:SetScript("OnVerticalScroll", function(self, offset)
        local maxScroll = self:GetVerticalScrollRange() or 0
        if maxScroll > 0 then
            rightPanelScrollBar:SetScrollPercentage(offset / maxScroll)
        end
    end)
    rightPanelScroll:SetScript("OnScrollRangeChanged", function(self, _xRange, yRange)
        -- Deferred engagement: hide scrollbar when no scroll needed
        if yRange and yRange > 0 then
            rightPanelScrollBar:Show()
            local visibleExtent = self:GetHeight() or 0
            local fullExtent = yRange + visibleExtent
            if visibleExtent > 0 and fullExtent > 0 then
                rightPanelScrollBar:SetVisibleExtentPercentage(visibleExtent / fullExtent)
            end
        else
            rightPanelScrollBar:Hide()
        end
    end)
    rightPanelScrollBar:Hide() -- start hidden; OnScrollRangeChanged shows when needed

    -- Phase F: subsequent CreateFrame calls use scrollChild as parent instead of parentPanel
    local seParent = scrollChild

    -----------------------------------------------------------------------
    -- Editor header
    -----------------------------------------------------------------------
    local header = CreateFrame("Frame", nil, seParent, "BackdropTemplate")
    header:SetHeight(D().EDITOR_HEADER_HEIGHT)
    header:SetPoint("TOPLEFT", seParent, "TOPLEFT", 0, 0)
    header:SetPoint("TOPRIGHT", seParent, "TOPRIGHT", 0, 0)
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
    -- Phase F T3 (Bug 2): a min-width on the EditBox would prevent text compression under
    -- the button chain at narrow MainFrame widths, but Frame:SetMinResize is not exposed on
    -- plain EditBox in the modern API. The actual fix lives in SE:_HandleRightPanelResize:
    -- below RIGHTPANEL_BUTTON_HIDE_WIDTH_THRESHOLD the Disable + Export buttons hide,
    -- which gives nameEditBox enough horizontal room without compression.
    local nameEditBox = CreateFrame("EditBox", nil, header, "BackdropTemplate")
    nameEditBox:SetHeight(D().NAME_EDITBOX_HEIGHT)
    nameEditBox:SetPoint("LEFT", iconTex, "RIGHT", 8, 0)
    nameEditBox:SetAutoFocus(false)
    UI:ApplyBackdrop(nameEditBox, UI.Backdrops.panel, C.bgInput, C.border)
    nameEditBox:SetTextInsets(6, 6, 2, 2)

    local fontPath = GRIPEMS.UI:GetFontPath()
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

    -- Disabled-state badge (shown when entry.data.disabled is truthy)
    local disabledBadge = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    disabledBadge:SetText(L["GEMS_UI_DISABLED_BADGE"])
    disabledBadge:SetTextColor(C.textMuted:GetRGBA())
    disabledBadge:Hide()
    SE.disabledBadge = disabledBadge

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

    -- Disable/Enable toggle button (sits between Discard and Export in chain)
    local disableBtn = UI:CreateButton(header, L["GEMS_UI_DISABLE"], 70, 24)
    disableBtn:SetScript("OnClick", function()
        if not SE.currentSequence then
            return
        end
        GRIPEMS.Engine:ToggleSequenceDisabled(SE.currentSequence)
        SE:UpdateDisabledState()
    end)
    disableBtn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(C.bgRowHover:GetRGBA())
        self:SetBackdropBorderColor(C.borderFocus:GetRGBA())
        local entry = GRIPEMS.Engine and GRIPEMS.Engine.sequences and GRIPEMS.Engine.sequences[SE.currentSequence]
        local isDisabled = entry and entry.data and entry.data.disabled
        local title = isDisabled and L["GEMS_UI_ENABLE"] or L["GEMS_UI_DISABLE"]
        local desc = isDisabled and L["GEMS_UI_ENABLE_BTN_DESC"] or L["GEMS_UI_DISABLE_BTN_DESC"]
        UI:ShowTooltip(self, title, desc)
    end)
    disableBtn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(C.bgButton:GetRGBA())
        self:SetBackdropBorderColor(C.border:GetRGBA())
        UI:HideTooltip()
    end)
    SE.disableBtn = disableBtn

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

    -- Fork button (visible only on foreign-author sequences). v2.1.0 Phase C.
    -- Calls SequenceList:ShowForkDialog so both surfaces (toolbar + context menu)
    -- share the same rename + Engine:DuplicateSequence path.
    local forkBtn = UI:CreateButton(header, L["GEMS_FORK_BUTTON"], 60, 24)
    forkBtn:SetScript("OnClick", function()
        if not SE.currentSequence then
            return
        end
        if GRIPEMS.SequenceList and GRIPEMS.SequenceList.ShowForkDialog then
            GRIPEMS.SequenceList:ShowForkDialog(SE.currentSequence)
        end
    end)
    forkBtn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(C.bgRowHover:GetRGBA())
        self:SetBackdropBorderColor(C.borderFocus:GetRGBA())
        UI:ShowTooltip(self, L["GEMS_FORK_BUTTON"], L["GEMS_FORK_TOOLTIP"])
    end)
    forkBtn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(C.bgButton:GetRGBA())
        self:SetBackdropBorderColor(C.border:GetRGBA())
        UI:HideTooltip()
    end)
    forkBtn:Hide()
    SE.forkBtn = forkBtn

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
    -- sendBtn -> recordBtn -> exportBtn -> disableBtn -> discardBtn -> saveBtn
    recordBtn:SetPoint("RIGHT", sendBtn, "LEFT", -2, 0)
    exportBtn:SetPoint("RIGHT", recordBtn, "LEFT", -2, 0)
    disableBtn:SetPoint("RIGHT", exportBtn, "LEFT", -4, 0)
    discardBtn:SetPoint("RIGHT", disableBtn, "LEFT", -2, 0)
    saveBtn:SetPoint("RIGHT", discardBtn, "LEFT", -2, 0)
    SE.disabledBadge:SetPoint("RIGHT", disableBtn, "LEFT", -8, 0)
    -- nameEditBox RIGHT: the leftmost VISIBLE element of the right-hand
    -- cluster. Anchoring past a live button makes the EditBox underlap it
    -- and swallow its clicks (the EditBox wins the hit test).
    SE:_UpdateNameEditBoxRightAnchor()

    -- Step function row (below icon/name)
    local sfRow = CreateFrame("Frame", nil, header)
    sfRow:SetHeight(26)
    sfRow:SetPoint("TOPLEFT", iconTex, "BOTTOMLEFT", 0, -6 - UI:GetRowGap())
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
    resetRow:SetPoint("TOPLEFT", sfRow, "BOTTOMLEFT", 0, -4 - UI:GetRowGap())
    resetRow:SetPoint("TOPRIGHT", sfRow, "BOTTOMRIGHT", 0, -4)

    -- Reset on combat checkbox
    local cbCombat = CreateFrame("CheckButton", nil, resetRow, "UICheckButtonTemplate")
    cbCombat:SetSize(22, 22)
    UI:RegisterLargeTarget(cbCombat)
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
    UI:RegisterLargeTarget(cbTarget)
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
    resetRow2:SetPoint("TOPLEFT", resetRow, "BOTTOMLEFT", 0, -2 - UI:GetRowGap())
    resetRow2:SetPoint("TOPRIGHT", resetRow, "BOTTOMRIGHT", 0, -2)

    -- Gear checkbox
    local cbGear = CreateFrame("CheckButton", nil, resetRow2, "UICheckButtonTemplate")
    cbGear:SetSize(22, 22)
    UI:RegisterLargeTarget(cbGear)
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
    UI:RegisterLargeTarget(cbSpec)
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

    -- Repeat-N EditBox (ENH-TOP-LEVEL-SEQUENCE-REPEAT-N)
    local repeatLabel = resetRow2:CreateFontString(nil, "OVERLAY")
    UI:SetFont(repeatLabel, 10)
    repeatLabel:SetPoint("LEFT", timerBox, "RIGHT", 16, 0)
    repeatLabel:SetText(L["GEMS_UI_REPEAT_COUNT"])
    repeatLabel:SetTextColor(C.textSecondary:GetRGBA())

    local repeatBox = CreateFrame("EditBox", nil, resetRow2, "InputBoxTemplate")
    repeatBox:SetSize(40, 20)
    repeatBox:SetPoint("LEFT", repeatLabel, "RIGHT", 4, 0)
    repeatBox:SetAutoFocus(false)
    repeatBox:SetNumeric(true)
    repeatBox:SetMaxLetters(3)
    repeatBox:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
        local val = tonumber(self:GetText()) or 1
        if val < 1 then
            val = 1
        end
        if val > GRIPEMS.Defaults.ACTION_LOOP_MAX_REPEAT then
            val = GRIPEMS.Defaults.ACTION_LOOP_MAX_REPEAT
        end
        self:SetText(tostring(val))
        SE:OnRepeatCountChanged(val)
    end)
    repeatBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)
    repeatBox:SetScript("OnEnter", function(self)
        UI:ShowTooltip(self, L["GEMS_UI_REPEAT_COUNT"], L["GEMS_UI_REPEAT_COUNT_DESC"])
    end)
    repeatBox:SetScript("OnLeave", function()
        UI:HideTooltip()
    end)
    SE.repeatBox = repeatBox
    if GRIPEMS.Focus and GRIPEMS.Focus.HookEditBox then
        GRIPEMS.Focus:HookEditBox(repeatBox)
    end

    -- Channel-hold row. Its own row because resetRow2 is 22px and already carries
    -- five controls, so a dropdown does not fit beside them.
    local resetRow3 = CreateFrame("Frame", nil, header)
    resetRow3:SetHeight(22)
    resetRow3:SetPoint("TOPLEFT", resetRow2, "BOTTOMLEFT", 0, -2 - UI:GetRowGap())
    resetRow3:SetPoint("TOPRIGHT", resetRow2, "BOTTOMRIGHT", 0, -2)

    -- Hold-while-channeling control (per-version). The SETTING is not class-gated:
    -- it means "do not advance while channeling" and works for any channel from any
    -- source. Only the CONTROL is scoped, by SE:RefreshChannelHoldControl below.
    local channelHoldLabel = resetRow3:CreateFontString(nil, "OVERLAY")
    UI:SetFont(channelHoldLabel, 10)
    channelHoldLabel:SetPoint("LEFT", resetRow3, "LEFT", 0, 0)
    channelHoldLabel:SetText(L["GEMS_UI_HOLD_ON_CHANNEL"])
    channelHoldLabel:SetTextColor(C.textSecondary:GetRGBA())
    SE.channelHoldLabel = channelHoldLabel

    local CHANNEL_HOLD_ORDER = { "off", "hold", "release" }
    local CHANNEL_HOLD_LABELS = {
        off = L["GEMS_UI_CHANNEL_HOLD_OFF"],
        hold = L["GEMS_UI_CHANNEL_HOLD_HOLD"],
        release = L["GEMS_UI_CHANNEL_HOLD_RELEASE"],
    }
    -- SE:RefreshChannelHoldControl lives outside this closure and needs the same
    -- label map to set the dropdown text, so publish it rather than duplicating it.
    SE.channelHoldModeLabels = CHANNEL_HOLD_LABELS

    local channelHoldDD = CreateFrame("Frame", "GRIPEMS_SE_ChannelHoldDD", resetRow3, "UIDropDownMenuTemplate")
    -- Negative x offset absorbs the dropdown template's own left inset, so the
    -- visible gap to the label matches the other controls on these rows.
    channelHoldDD:SetPoint("LEFT", channelHoldLabel, "RIGHT", -8, -2)
    UIDropDownMenu_SetWidth(channelHoldDD, 150)
    channelHoldDD._value = "off"

    UIDropDownMenu_Initialize(channelHoldDD, function(_, level)
        local current = channelHoldDD._value or "off"
        for _, mode in ipairs(CHANNEL_HOLD_ORDER) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = CHANNEL_HOLD_LABELS[mode] or mode
            info.value = mode
            info.checked = (current == mode)
            info.func = function()
                channelHoldDD._value = mode
                UIDropDownMenu_SetText(channelHoldDD, CHANNEL_HOLD_LABELS[mode] or mode)
                CloseDropDownMenus()
                SE:OnChannelHoldModeChanged(mode)
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)

    UIDropDownMenu_SetText(channelHoldDD, CHANNEL_HOLD_LABELS.off)
    channelHoldDD:EnableMouse(true)
    channelHoldDD:SetScript("OnEnter", function(self)
        UI:ShowTooltip(self, L["GEMS_UI_HOLD_ON_CHANNEL"], L["GEMS_UI_HOLD_ON_CHANNEL_DESC"])
    end)
    channelHoldDD:SetScript("OnLeave", function()
        UI:HideTooltip()
    end)
    UI:RegisterLargeTarget(channelHoldDD)
    SE.channelHoldDropdown = channelHoldDD

    -- KeyPress / KeyRelease row
    local kpRow = CreateFrame("Frame", nil, header)
    kpRow:SetHeight(90)
    kpRow:SetPoint("TOPLEFT", resetRow3, "BOTTOMLEFT", 0, -4 - UI:GetRowGap())
    kpRow:SetPoint("TOPRIGHT", resetRow3, "BOTTOMRIGHT", 0, -4)

    -- KeyPress label
    local kpLabel = kpRow:CreateFontString(nil, "OVERLAY")
    UI:SetFont(kpLabel, 10)
    kpLabel:SetPoint("TOPLEFT", kpRow, "TOPLEFT", 0, 0)
    kpLabel:SetText(L["GEMS_UI_KEYPRESS"])
    kpLabel:SetTextColor(C.textSecondary:GetRGBA())

    -- KeyPress EditBox
    local kpScroll = CreateFrame("ScrollFrame", nil, kpRow)
    kpScroll:SetPoint("TOPLEFT", kpLabel, "BOTTOMLEFT", 0, -2 - UI:GetRowGap())
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
    kpStatus:SetPoint("TOPLEFT", kpScroll, "BOTTOMLEFT", 0, -1 - UI:GetRowGap())
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
    krScroll:SetPoint("TOPLEFT", krLabel, "BOTTOMLEFT", 0, -2 - UI:GetRowGap())
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
    local stubSection = CreateFrame("Frame", nil, seParent)
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

    -- Phase F T1: callable setter so OnSizeChanged hook can force-collapse programmatically.
    -- Declared inside SE:Init so it can capture the upvalues stubSection / stubContent /
    -- stubArrow / STUB_TOGGLE_HEIGHT / STUB_CONTENT_HEIGHT.
    function SE:SetStubExpanded(bool)
        SE.stubExpanded = bool and true or false
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
        if SE._RecomputeRightPanelScrollChild then
            SE:_RecomputeRightPanelScrollChild()
        end
    end
    stubToggle:SetScript("OnClick", function()
        SE:SetStubExpanded(not SE.stubExpanded)
    end)

    -----------------------------------------------------------------------
    -- Metadata section (collapsible, between stub preview and spell banner)
    -----------------------------------------------------------------------
    local META_TOGGLE_HEIGHT = 18
    local META_ROW_HEIGHT = 22
    -- META_ROWS counts every visible metadata row: 1 author + 1 description (with
    -- META_DESC_EXTRA for multi-line) + 4 metadata edit rows + 4 read-only rows +
    -- 1 last-modified read-only row (v2.1.0 Authorship Integrity) +
    -- 1 cue header + 4 cue override dropdowns + 1 hold-mode toggle = 17. The two
    -- single-row slots that the description displaces are absorbed by
    -- META_DESC_EXTRA so the count is intentionally 15 here. See Phase 4 item 22
    -- Phase 2 for the cue-override block.
    -- v2.1.0 Phase D: bumped from 15 to 16 to accommodate the privacy-mode
    -- dropdown row (metaPrivacyDropdown), inserted between metaLastModifiedBox
    -- and the per-sequence sound cue header.
    -- v2.3.4: bumped again for the Talent Loadout row (metaTalentBox, slot 16),
    -- plus one extra so the dependencies separator (placed at META_ROWS * row
    -- height) clears the talent row's bottom edge (descShift 84 + 22 * 17 = 458
    -- > 22 * 18 + 40 + 6 = 442, so 18 still collided; 19 puts it at 464).
    -- MUST equal the META_ROWS local in SE:RecalcMetaHeight (synced Phase 3).
    local META_ROWS = 19
    local META_PAD = 4
    -- META_DESC_EXTRA defined later after MakeMetaEditRow calls
    local META_FULL = META_TOGGLE_HEIGHT + META_PAD + (META_ROW_HEIGHT * META_ROWS) + 40

    local metaSection = CreateFrame("Frame", nil, seParent)
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
    -- Phase F T1: callable setter so OnSizeChanged hook can force-collapse programmatically.
    -- Declared inside SE:Init so it can capture the upvalues metaSection / metaArrow /
    -- META_TOGGLE_HEIGHT / META_FULL.
    function SE:SetMetadataExpanded(bool)
        SE.metadataExpanded = bool and true or false
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
        if SE._RecomputeRightPanelScrollChild then
            SE:_RecomputeRightPanelScrollChild()
        end
    end
    metaToggle:SetScript("OnClick", function()
        SE:SetMetadataExpanded(not SE.metadataExpanded)
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
        lbl:SetWidth(110)
        lbl:SetJustifyH("LEFT")
        lbl:SetText(L[labelKey])
        lbl:SetTextColor(C.textSecondary:GetRGBA())
        local box = CreateFrame("EditBox", nil, metaContent, "BackdropTemplate")
        box:SetHeight(20)
        box:SetPoint("TOPLEFT", lbl, "TOPRIGHT", 8, -1)
        box:SetPoint("TOPRIGHT", metaContent, "TOPRIGHT", -8, -1)
        -- box width derived from anchors (lbl.RIGHT + 8 to metaContent.RIGHT - 8)
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
        if GRIPEMS.Focus and GRIPEMS.Focus.HookEditBox then
            GRIPEMS.Focus:HookEditBox(box)
        end
        return box
    end

    -- Helper: create a read-only metadata row (label + font string)
    local function MakeMetaReadRow(yOff, labelKey)
        local lbl = metaContent:CreateFontString(nil, "OVERLAY")
        UI:SetFont(lbl, 10)
        lbl:SetPoint("TOPLEFT", metaContent, "TOPLEFT", 8, yOff)
        lbl:SetWidth(110)
        lbl:SetJustifyH("LEFT")
        lbl:SetText(L[labelKey])
        lbl:SetTextColor(C.textSecondary:GetRGBA())
        local val = metaContent:CreateFontString(nil, "OVERLAY")
        UI:SetFont(val, 10)
        val:SetPoint("TOPLEFT", lbl, "TOPRIGHT", 8, 0)
        val:SetPoint("TOPRIGHT", metaContent, "TOPRIGHT", -8, 0)
        val:SetJustifyH("LEFT")
        val:SetTextColor(C.textPrimary:GetRGBA())
        return val
    end

    SE.metaAuthorBox = MakeMetaEditRow(0, "GEMS_EDITOR_METADATA_AUTHOR")
    -- v2.1.0 Authorship Integrity: Original Author is locked after first save.
    -- Field stays visible but rejects user input. Tooltip + lock icon signal the lock.
    SE.metaAuthorBox:Disable()
    SE.metaAuthorBox:SetTextColor(C.textMuted:GetRGBA())
    SE.metaAuthorBox:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(L["GEMS_AUTHOR_LOCKED_TOOLTIP"], 1, 1, 1, 1, true)
        -- D3: provenance-source sentence for imported sequences
        -- (set by LoadSequence, cleared by the editor Clear path).
        if SE._authorSourceDetail then
            GameTooltip:AddLine(SE._authorSourceDetail, 0.8, 0.8, 0.8, true)
        end
        GameTooltip:Show()
    end)
    SE.metaAuthorBox:SetScript("OnLeave", GameTooltip_Hide)
    SE.metaAuthorLockIcon = metaContent:CreateTexture(nil, "OVERLAY")
    SE.metaAuthorLockIcon:SetTexture("Interface\\Buttons\\LockButton-Locked-Up")
    SE.metaAuthorLockIcon:SetSize(12, 12)
    SE.metaAuthorLockIcon:SetPoint("RIGHT", SE.metaAuthorBox, "RIGHT", -4, 0)

    -- v2.1.6: Author dropdown for brand-new sequences. The dropdown sits in
    -- the same metadata slot as metaAuthorBox; LoadSequence + Clear swap
    -- visibility so the EditBox renders post-lock state and the dropdown
    -- handles the picker for sequences whose originalAuthor is still empty.
    -- Options come from Identity:GetAuthorOptions (pseudonym + BattleNet
    -- roster); the default selection comes from
    -- Identity:GetDefaultAuthorChoice(privacyMode), which keys off the
    -- per-sequence privacy mode (Pseudonymous -> pseudonym; otherwise the
    -- current character). Identity hashes are still derived from the
    -- active BattleTag inside StampOriginal, so the cryptographic
    -- signature is locked to the BNet account regardless of which display
    -- name the user picks here.
    local function FormatAuthorPickerLabel(opt)
        if opt.kind == "pseudonym" then
            return string.format(L["GEMS_AUTHOR_PICKER_PSEUDONYM"], opt.value)
        elseif opt.kind == "current" then
            return string.format(L["GEMS_AUTHOR_PICKER_CURRENT"], opt.value)
        end
        return string.format(L["GEMS_AUTHOR_PICKER_ALT"], opt.value, opt.realm or "?")
    end

    local authorDD = CreateFrame("Frame", "GRIPEMS_SE_MetaAuthorDD", metaContent, "UIDropDownMenuTemplate")
    authorDD:SetPoint("TOPLEFT", metaContent, "TOPLEFT", 100, 4)
    UIDropDownMenu_SetWidth(authorDD, 180)
    authorDD._value = ""
    authorDD._options = {}
    UIDropDownMenu_Initialize(authorDD, function(_, level)
        for _, opt in ipairs(authorDD._options or {}) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = FormatAuthorPickerLabel(opt)
            info.value = opt.value
            info.checked = (authorDD._value == opt.value)
            info.func = function()
                authorDD._value = opt.value
                UIDropDownMenu_SetText(authorDD, FormatAuthorPickerLabel(opt))
                CloseDropDownMenus()
                if SE.OnMetadataChanged then
                    SE:OnMetadataChanged()
                end
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    authorDD:Hide()
    SE.metaAuthorDropdown = authorDD

    -- Populates the author dropdown and toggles visibility based on whether
    -- the sequence's originalAuthor is locked. seqData may be nil (Clear
    -- path); when nil the dropdown hides and the EditBox shows (empty).
    -- The default selection picks the pseudonym when privacyMode is
    -- "pseudonymous" and one is configured, otherwise the current character.
    function SE:RefreshAuthorPicker(seqData)
        local Identity = GRIPEMS.Identity
        local locked = seqData and seqData.originalAuthor and seqData.originalAuthor ~= ""
        if not seqData or locked or not Identity then
            if SE.metaAuthorDropdown then
                SE.metaAuthorDropdown:Hide()
            end
            if SE.metaAuthorBox then
                SE.metaAuthorBox:Show()
            end
            if SE.metaAuthorLockIcon then
                SE.metaAuthorLockIcon:Show()
            end
            return
        end
        local options = Identity:GetAuthorOptions()
        local privacyMode = seqData.privacyMode or "public"
        local defaultChoice = Identity:GetDefaultAuthorChoice(privacyMode)
        SE.metaAuthorDropdown._options = options
        SE.metaAuthorDropdown._value = defaultChoice or ""
        local defaultLabel = defaultChoice or ""
        for _, opt in ipairs(options) do
            if opt.value == defaultChoice then
                defaultLabel = FormatAuthorPickerLabel(opt)
                break
            end
        end
        UIDropDownMenu_SetText(SE.metaAuthorDropdown, defaultLabel)
        if SE.metaAuthorBox then
            SE.metaAuthorBox:Hide()
        end
        if SE.metaAuthorLockIcon then
            SE.metaAuthorLockIcon:Hide()
        end
        SE.metaAuthorDropdown:Show()
    end

    -- v2.1.0 Phase C polish: read-only "Forked from" row showing the immediate
    -- parent (single-hop) or the full ancestry chain (multi-hop). Hidden by
    -- default; LoadSequence shows it when seqData.forkedFrom or
    -- seqData.forkedFromChain is populated.
    SE.metaForkedFromBox = MakeMetaEditRow(-META_ROW_HEIGHT, "GEMS_AUTHOR_FORKED_FROM_LABEL")
    SE.metaForkedFromBox:Disable()
    SE.metaForkedFromBox:SetTextColor(C.textMuted:GetRGBA())
    SE.metaForkedFromBox:Hide()
    SE.metaDescBox = MakeMetaEditRow(-(META_ROW_HEIGHT * 2), "GEMS_EDITOR_METADATA_DESCRIPTION")
    -- Convert description to multi-line (60px tall instead of 20)
    local META_DESC_EXTRA = 40
    SE.metaDescBox:SetMultiLine(true)
    SE.metaDescBox:SetHeight(60)
    SE.metaDescBox:SetMaxLetters(D().EXPORT_META_DESC_MAX)
    -- Shift remaining rows down to account for the taller description box
    -- plus the new metaForkedFromBox slot above it.
    local descShift = (META_ROW_HEIGHT * 2) + META_DESC_EXTRA
    SE.metaHelpBox = MakeMetaEditRow(-(descShift + META_ROW_HEIGHT), "GEMS_EDITOR_METADATA_HELP")
    SE.metaHelpLinkBox = MakeMetaEditRow(-(descShift + META_ROW_HEIGHT * 2), "GEMS_EDITOR_METADATA_HELPLINK")
    SE.metaClassText = MakeMetaReadRow(-(descShift + META_ROW_HEIGHT * 3), "GEMS_EDITOR_METADATA_CLASS")
    SE.metaSpecText = MakeMetaReadRow(-(descShift + META_ROW_HEIGHT * 4), "GEMS_EDITOR_METADATA_SPEC")
    SE.metaCreatedText = MakeMetaReadRow(-(descShift + META_ROW_HEIGHT * 5), "GEMS_EDITOR_METADATA_CREATED")
    SE.metaUpdatedText = MakeMetaReadRow(-(descShift + META_ROW_HEIGHT * 6), "GEMS_EDITOR_METADATA_UPDATED")
    -- v2.1.0 Authorship Integrity: read-only "Last modified by" row.
    -- Auto-updates on every save via Identity:StampLastModified.
    SE.metaLastModifiedBox = MakeMetaEditRow(-(descShift + META_ROW_HEIGHT * 7), "GEMS_AUTHOR_LAST_MODIFIED_LABEL")
    SE.metaLastModifiedBox:Disable()
    SE.metaLastModifiedBox:SetTextColor(C.textMuted:GetRGBA())

    -- v2.1.0 Phase D: per-sequence privacy-mode dropdown. Always visible
    -- (every sequence has a privacyMode -- default "public"). Selection
    -- writes to dd._value; SaveSequence persists it as seqData.privacyMode.
    -- LoadSequence populates the dropdown from the active seqData.
    local PRIVACY_MODE_LABELS = {
        public = L["GEMS_PRIVACY_MODE_PUBLIC"],
        pseudonymous = L["GEMS_PRIVACY_MODE_PSEUDONYMOUS"],
        private = L["GEMS_PRIVACY_MODE_PRIVATE"],
    }
    local PRIVACY_MODE_ORDER = { "public", "pseudonymous", "private" }
    local function MakeMetaPrivacyDropdown(yOff, labelKey, frameName)
        local lbl = metaContent:CreateFontString(nil, "OVERLAY")
        UI:SetFont(lbl, 10)
        lbl:SetPoint("TOPLEFT", metaContent, "TOPLEFT", 8, yOff)
        lbl:SetText(L[labelKey])
        lbl:SetTextColor(C.textSecondary:GetRGBA())

        local dd = CreateFrame("Frame", frameName, metaContent, "UIDropDownMenuTemplate")
        dd:SetPoint("TOPLEFT", metaContent, "TOPLEFT", 84, yOff + 4)
        UIDropDownMenu_SetWidth(dd, 180)
        dd._value = "public"

        UIDropDownMenu_Initialize(dd, function(self, level)
            local current = dd._value or "public"
            for _, mode in ipairs(PRIVACY_MODE_ORDER) do
                local info = UIDropDownMenu_CreateInfo()
                info.text = PRIVACY_MODE_LABELS[mode] or mode
                info.value = mode
                info.checked = (current == mode)
                info.func = function()
                    dd._value = mode
                    UIDropDownMenu_SetText(dd, PRIVACY_MODE_LABELS[mode] or mode)
                    CloseDropDownMenus()
                    if SE.OnMetadataChanged then
                        SE:OnMetadataChanged()
                    end
                end
                UIDropDownMenu_AddButton(info, level)
            end
        end)

        UIDropDownMenu_SetText(dd, PRIVACY_MODE_LABELS.public)
        return dd
    end

    SE.metaPrivacyDropdown = MakeMetaPrivacyDropdown(
        -(descShift + META_ROW_HEIGHT * 8),
        "GEMS_PRIVACY_MODE_LABEL",
        "GRIPEMS_SE_MetaPrivacyDD"
    )

    -- Phase 4 item 22 Phase 2: per-sequence sound cue overrides. One header row
    -- plus four LSM dropdowns. An empty selection (the "(global default)" entry
    -- at the top of each list) means the cue resolves through the global
    -- accessibility.soundCue<X> setting at S:Play time. A non-empty entry wins.
    -- Selection is persisted to engine.sequences[name].data.soundCues[cueKey].
    local cueHeaderLabel = metaContent:CreateFontString(nil, "OVERLAY")
    UI:SetFont(cueHeaderLabel, 10)
    -- v2.1.0 Phase D: shifted from row 8 to row 9 to accommodate the new
    -- privacy-mode dropdown inserted at row 8.
    cueHeaderLabel:SetPoint("TOPLEFT", metaContent, "TOPLEFT", 8, -(descShift + META_ROW_HEIGHT * 9))
    cueHeaderLabel:SetText(L["GEMS_EDITOR_SEQ_SOUND_HEADER"])
    cueHeaderLabel:SetTextColor(C.textSecondary:GetRGBA())
    SE.metaCueHeader = cueHeaderLabel

    -- Helper: build a labelled UIDropDownMenu populated with LSM "sound" entries
    -- plus a synthetic "(global default)" entry at the top. Selection is stored
    -- on dd._value (string; empty == global). Each dropdown gets a unique global
    -- frame name because UIDropDownMenuTemplate requires one.
    local function MakeMetaCueDropdown(yOff, labelKey, cueKey, frameName)
        local lbl = metaContent:CreateFontString(nil, "OVERLAY")
        UI:SetFont(lbl, 10)
        lbl:SetPoint("TOPLEFT", metaContent, "TOPLEFT", 8, yOff)
        lbl:SetText(L[labelKey])
        lbl:SetTextColor(C.textSecondary:GetRGBA())

        local dd = CreateFrame("Frame", frameName, metaContent, "UIDropDownMenuTemplate")
        dd:SetPoint("TOPLEFT", metaContent, "TOPLEFT", 84, yOff + 4)
        UIDropDownMenu_SetWidth(dd, 180)
        dd._cueKey = cueKey
        dd._value = ""

        UIDropDownMenu_Initialize(dd, function(self, level)
            local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)
            local current = dd._value or ""
            local info

            info = UIDropDownMenu_CreateInfo()
            info.text = L["GEMS_EDITOR_SEQ_SOUND_NONE"]
            info.value = ""
            info.checked = (current == "")
            info.func = function()
                dd._value = ""
                UIDropDownMenu_SetText(dd, L["GEMS_EDITOR_SEQ_SOUND_NONE"])
                CloseDropDownMenus()
                if SE.OnMetadataChanged then
                    SE:OnMetadataChanged()
                end
            end
            UIDropDownMenu_AddButton(info, level)

            if LSM then
                local sounds = LSM:HashTable("sound")
                local names = {}
                for k in pairs(sounds) do
                    names[#names + 1] = k
                end
                table.sort(names)
                for _, name in ipairs(names) do
                    info = UIDropDownMenu_CreateInfo()
                    info.text = name
                    info.value = name
                    info.checked = (current == name)
                    info.func = function()
                        dd._value = name
                        UIDropDownMenu_SetText(dd, name)
                        CloseDropDownMenus()
                        if SE.OnMetadataChanged then
                            SE:OnMetadataChanged()
                        end
                    end
                    UIDropDownMenu_AddButton(info, level)
                end
            end
        end)

        UIDropDownMenu_SetText(dd, L["GEMS_EDITOR_SEQ_SOUND_NONE"])
        return dd
    end

    -- v2.1.0 Phase D: cue dropdowns shifted +1 row each (rows 10-13) to make
    -- room for the privacy-mode dropdown at row 8. The holdCheck row also
    -- moves from 13 to 14.
    SE.metaCueErrorDD = MakeMetaCueDropdown(
        -(descShift + META_ROW_HEIGHT * 10),
        "GEMS_EDITOR_SEQ_SOUND_ERROR",
        "error",
        "GRIPEMS_SE_MetaCueErrorDD"
    )
    SE.metaCueSuccessDD = MakeMetaCueDropdown(
        -(descShift + META_ROW_HEIGHT * 11),
        "GEMS_EDITOR_SEQ_SOUND_SUCCESS",
        "success",
        "GRIPEMS_SE_MetaCueSuccessDD"
    )
    SE.metaCueInfoDD = MakeMetaCueDropdown(
        -(descShift + META_ROW_HEIGHT * 12),
        "GEMS_EDITOR_SEQ_SOUND_INFO",
        "info",
        "GRIPEMS_SE_MetaCueInfoDD"
    )
    SE.metaCueStepDD = MakeMetaCueDropdown(
        -(descShift + META_ROW_HEIGHT * 13),
        "GEMS_EDITOR_SEQ_SOUND_STEP",
        "stepComplete",
        "GRIPEMS_SE_MetaCueStepDD"
    )

    -- Hold Mode per-sequence toggle (below metadata rows + cue dropdowns, above dependencies)
    local holdCheckY = -(descShift + META_ROW_HEIGHT * 14)
    local holdCheck = CreateFrame("CheckButton", nil, metaContent, "UICheckButtonTemplate")
    holdCheck:SetPoint("TOPLEFT", metaContent, "TOPLEFT", 0, holdCheckY)
    holdCheck:SetSize(24, 24)
    UI:RegisterLargeTarget(holdCheck)
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
    holdCheck:SetScript("OnLeave", GameTooltip_Hide)
    SE.holdModeCheck = holdCheck

    -- Changelog: per-sequence change notes, exported to sharing sites
    -- (lazygrip.net). Single-line; appended below the hold-mode row so no
    -- existing metadata row offset changes.
    SE.metaChangelogBox = MakeMetaEditRow(-(descShift + META_ROW_HEIGHT * 15), "GEMS_EDITOR_METADATA_CHANGELOG")
    SE.metaChangelogBox:SetMaxLetters(D().EXPORT_META_CHANGELOG_MAX)

    -- Talent Loadout: per-sequence talent import string (author-set or
    -- carried from import). Reuses the export dialog's locale key.
    SE.metaTalentBox = MakeMetaEditRow(-(descShift + META_ROW_HEIGHT * 16), "GEMS_EXPORT_META_TALENT")
    SE.metaTalentBox:SetMaxLetters(D().EXPORT_META_TALENT_MAX)

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
    depFrame:SetPoint("TOPLEFT", depHeaderLabel, "BOTTOMLEFT", 0, -4 - UI:GetRowGap())
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
    local CR_BLOCK_HEIGHT = CR_SECTION_PAD
        + 1
        + CR_SECTION_PAD
        + CR_ROW_HEIGHT * CR_ROWS
        + CR_BTN_HEIGHT
        + CR_SECTION_PAD

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
    crRecLabel:SetPoint("TOPLEFT", crHeaderLabel, "BOTTOMLEFT", 0, -4 - UI:GetRowGap())
    crRecLabel:SetTextColor(C.textSecondary:GetRGBA())
    crRecLabel:SetText(L["FS_RECOMMENDED"]:gsub("%%d.*", ""))
    local crRecValue = metaContent:CreateFontString(nil, "OVERLAY")
    UI:SetFont(crRecValue, 10)
    crRecValue:SetPoint("LEFT", crRecLabel, "LEFT", 80, 0)
    crRecValue:SetTextColor(C.textPrimary:GetRGBA())

    -- Complexity row
    local crComplexLabel = metaContent:CreateFontString(nil, "OVERLAY")
    UI:SetFont(crComplexLabel, 10)
    crComplexLabel:SetPoint("TOPLEFT", crRecLabel, "BOTTOMLEFT", 0, -2 - UI:GetRowGap())
    crComplexLabel:SetTextColor(C.textSecondary:GetRGBA())
    crComplexLabel:SetText(L["FS_COMPLEXITY"]:gsub("%%s", ""))
    local crComplexValue = metaContent:CreateFontString(nil, "OVERLAY")
    UI:SetFont(crComplexValue, 10)
    crComplexValue:SetPoint("LEFT", crComplexLabel, "LEFT", 80, 0)
    crComplexValue:SetTextColor(C.textPrimary:GetRGBA())

    -- Confidence row
    local crConfLabel = metaContent:CreateFontString(nil, "OVERLAY")
    UI:SetFont(crConfLabel, 10)
    crConfLabel:SetPoint("TOPLEFT", crComplexLabel, "BOTTOMLEFT", 0, -2 - UI:GetRowGap())
    crConfLabel:SetTextColor(C.textSecondary:GetRGBA())
    crConfLabel:SetText("Confidence:")
    local crConfValue = metaContent:CreateFontString(nil, "OVERLAY")
    UI:SetFont(crConfValue, 10)
    crConfValue:SetPoint("LEFT", crConfLabel, "LEFT", 80, 0)
    crConfValue:SetTextColor(C.textPrimary:GetRGBA())

    -- Manual Override button
    local crOverrideBtn = CreateFrame("Button", nil, metaContent, "UIPanelButtonTemplate")
    crOverrideBtn:SetSize(120, CR_BTN_HEIGHT)
    crOverrideBtn:SetPoint("TOPLEFT", crConfLabel, "BOTTOMLEFT", 0, -4 - UI:GetRowGap())
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
    SE.crElements = {
        crSeparator,
        crHeaderLabel,
        crRecLabel,
        crRecValue,
        crComplexLabel,
        crComplexValue,
        crConfLabel,
        crConfValue,
        crOverrideBtn,
    }

    -----------------------------------------------------------------------
    -- Reset Modifier Overrides (collapsible, between metadata and spell banner)
    -----------------------------------------------------------------------
    local RMOD_TOGGLE_HEIGHT = 18
    local RMOD_ENABLE_HEIGHT = 22
    local RMOD_ROW_HEIGHT = 22
    local RMOD_ROWS = 5
    local RMOD_CONTENT_HEIGHT = RMOD_ENABLE_HEIGHT + RMOD_ROW_HEIGHT * RMOD_ROWS + 4

    local resetModSection = CreateFrame("Frame", nil, seParent)
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
    rmodContent:SetPoint("TOPLEFT", rmodToggle, "BOTTOMLEFT", 0, -2 - UI:GetRowGap())
    rmodContent:SetPoint("TOPRIGHT", rmodToggle, "BOTTOMRIGHT", 0, -2)
    rmodContent:SetHeight(RMOD_CONTENT_HEIGHT)
    rmodContent:Hide()
    SE.resetModContent = rmodContent

    -- Phase F T1: callable setter so OnSizeChanged hook can force-collapse programmatically.
    -- Declared inside SE:Init so it can capture the upvalues resetModSection / rmodContent /
    -- rmodArrow / RMOD_TOGGLE_HEIGHT / RMOD_CONTENT_HEIGHT.
    function SE:SetResetModExpanded(bool)
        SE.resetModExpanded = bool and true or false
        if SE.resetModExpanded then
            rmodContent:Show()
            resetModSection:SetHeight(RMOD_TOGGLE_HEIGHT + 2 + RMOD_CONTENT_HEIGHT)
            rmodArrow:SetText("v")
        else
            rmodContent:Hide()
            resetModSection:SetHeight(RMOD_TOGGLE_HEIGHT)
            rmodArrow:SetText(">")
        end
        if SE._RecomputeRightPanelScrollChild then
            SE:_RecomputeRightPanelScrollChild()
        end
    end
    rmodToggle:SetScript("OnClick", function()
        SE:SetResetModExpanded(not SE.resetModExpanded)
    end)

    -- Enable checkbox
    local rmodEnableCB = CreateFrame("CheckButton", nil, rmodContent, "UICheckButtonTemplate")
    rmodEnableCB:SetSize(22, 22)
    UI:RegisterLargeTarget(rmodEnableCB)
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
        rowFrame:SetPoint("TOPLEFT", prevRow, "BOTTOMLEFT", 0, -1 - UI:GetRowGap())
        rowFrame:SetPoint("RIGHT", rmodContent, "RIGHT", -4, 0)

        local prevCB
        for _, mod in ipairs(group.mods) do
            local cb = CreateFrame("CheckButton", nil, rowFrame, "UICheckButtonTemplate")
            cb:SetSize(18, 18)
            UI:RegisterLargeTarget(cb)
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
    local spellBanner = CreateFrame("Frame", nil, seParent, "BackdropTemplate")
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
    local versionBar = CreateFrame("Frame", nil, seParent, "BackdropTemplate")
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
        -- type(), not truthiness: the "#vbEntry.data.versions" loops below raise
        -- "attempt to get length of field 'versions'" on a scalar.
        if not vbEntry or not vbEntry.data or type(vbEntry.data.versions) ~= "table" then
            return
        end

        MenuUtil.CreateContextMenu(self, function(_, rootDescription)
            for i = 1, #vbEntry.data.versions do
                local lbl = string.format(L["GEMS_VERSION_LABEL"], i)
                if i == (vbEntry.data.defaultVersion or 1) then
                    lbl = lbl .. L["GEMS_VERSION_DEFAULT_SUFFIX"]
                end
                if i == GRIPEMS.Engine:GetActiveVersionIndex(vbEntry.data) then
                    lbl = lbl .. L["GEMS_VERSION_LIVE_MARKER"]
                end
                rootDescription:CreateButton(lbl, function()
                    SE:SwitchVersion(i)
                end)
            end
            -- Pin / unpin actions (LIVE-VERSION-QUICK-SWAP): the entries above
            -- switch the EDIT version; these pin the LIVE (running) version over
            -- context until cleared. SetVersionPin/ClearVersionPin queue the
            -- secure reload through OOCQueue, so this is safe in combat.
            rootDescription:CreateDivider()
            for i = 1, #vbEntry.data.versions do
                rootDescription:CreateButton(string.format("%s V%d", L["GEMS_VERSION_PIN_ACTION"], i), function()
                    GRIPEMS.Engine:SetVersionPin(SE.currentSequence, i)
                end)
            end
            if vbEntry.data.pinnedVersion then
                rootDescription:CreateButton(L["GEMS_VERSION_UNPIN_ACTION"], function()
                    GRIPEMS.Engine:ClearVersionPin(SE.currentSequence)
                end)
            end
        end)
    end)
    versionBtn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(C.bgRowHover:GetRGBA())
        self:SetBackdropBorderColor(C.borderFocus:GetRGBA())
        UI:ShowTooltip(
            self,
            L["GEMS_VERSION_TOOLTIP_TITLE"],
            L["GEMS_VERSION_TOOLTIP_DESC"],
            L["GEMS_VERSION_TOOLTIP_LIVE_HINT"]
        )
    end)
    versionBtn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(C.bgButton:GetRGBA())
        self:SetBackdropBorderColor(C.border:GetRGBA())
        UI:HideTooltip()
    end)
    SE.versionBtn = versionBtn

    -- Read-only LIVE indicator. Shows which version the keybind actually fires
    -- (Engine:GetActiveVersionIndex), which can differ from the EDIT version
    -- shown on the dropdown button. Populated by SE:RefreshVersionBar; this is
    -- display-only and never touches the engine or secure path.
    local versionLiveBadge = versionBar:CreateFontString(nil, "OVERLAY")
    UI:SetFont(versionLiveBadge, 11)
    versionLiveBadge:SetPoint("RIGHT", versionBar, "RIGHT", -8, 0)
    versionLiveBadge:SetTextColor(C.textSecondary:GetRGBA())
    versionLiveBadge:Hide()
    SE.versionLiveBadge = versionLiveBadge

    -- Clickable overlay over the live badge (LIVE-VERSION-QUICK-SWAP). The badge
    -- is a FontString (no clicks), so a transparent Button covers its extent and
    -- opens a pin/unpin menu. Shown/hidden alongside the badge in
    -- SE:RefreshVersionBar. SetVersionPin/ClearVersionPin queue the secure reload
    -- through OOCQueue, so clicking is safe in combat -- no secure API here.
    local versionLiveBtn = CreateFrame("Button", nil, versionBar)
    versionLiveBtn:SetAllPoints(versionLiveBadge)
    versionLiveBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    versionLiveBtn:Hide()
    versionLiveBtn:SetScript("OnClick", function(self)
        if not SE.currentSequence then
            return
        end
        local lbEntry = GRIPEMS.Engine and GRIPEMS.Engine.sequences and GRIPEMS.Engine.sequences[SE.currentSequence]
        -- type(), not truthiness: the "#seqData.versions" loop below raises
        -- "attempt to get length of field 'versions'" on a scalar.
        if not lbEntry or not lbEntry.data or type(lbEntry.data.versions) ~= "table" then
            return
        end
        local seqData = lbEntry.data
        MenuUtil.CreateContextMenu(self, function(_, rootDescription)
            rootDescription:CreateTitle(L["GEMS_VERSION_TOOLTIP_TITLE"])
            for i = 1, #seqData.versions do
                rootDescription:CreateButton(string.format("%s V%d", L["GEMS_VERSION_PIN_ACTION"], i), function()
                    GRIPEMS.Engine:SetVersionPin(SE.currentSequence, i)
                end)
            end
            if seqData.pinnedVersion then
                rootDescription:CreateButton(L["GEMS_VERSION_UNPIN_ACTION"], function()
                    GRIPEMS.Engine:ClearVersionPin(SE.currentSequence)
                end)
            end
        end)
    end)
    versionLiveBtn:SetScript("OnEnter", function(self)
        UI:ShowTooltip(
            self,
            L["GEMS_VERSION_TOOLTIP_TITLE"],
            L["GEMS_VERSION_TOOLTIP_DESC"],
            L["GEMS_VERSION_TOOLTIP_LIVE_HINT"]
        )
    end)
    versionLiveBtn:SetScript("OnLeave", function()
        UI:HideTooltip()
    end)
    SE.versionLiveBtn = versionLiveBtn

    -- Density-aware gap for the 4-mini-button cluster (Phase 4-polish #3).
    -- At density=large each 24x22 button gets a 44x44 hit rect (padX = 10
    -- each side); 2 px logical gap leaves 18 px hit-rect overlap. Bumping
    -- to 22 px in large mode eliminates the overlap entirely.
    -- /reload required for already-drawn versionBar when density toggles --
    -- documented behavior matching the existing UI:ApplyTitleBarSpacing precedent.
    local verBtnGap = UI:IsLargeTargets() and 22 or 2

    -- Add Version button
    local addVerBtn = UI:CreateButton(versionBar, "+", 24, 22)
    UI:RegisterLargeTarget(addVerBtn)
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
            repeatCount = tmpl.repeatCount,
            keyPress = tmpl.keyPress or "",
            keyRelease = tmpl.keyRelease or "",
        }
        -- type(), not truthiness: table.insert raises "wrong number of arguments"
        -- on a scalar 'versions', and the "#avEntry.data.versions" read below
        -- raises "attempt to get length of field 'versions'".
        if type(avEntry.data.versions) ~= "table" then
            return
        end
        table.insert(avEntry.data.versions, newVer)
        SE._updatingFromEditor = true
        GRIPEMS.Engine:UpdateSequenceData(SE.currentSequence, avEntry.data)
        SE._updatingFromEditor = false
        -- versions is signature-canon content and nothing forces a later
        -- full save here -- queue the owned re-sign like the quick persists.
        SE:_QueueQuickResign(SE.currentSequence)
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
    UI:RegisterLargeTarget(dupVerBtn)
    dupVerBtn:SetPoint("LEFT", addVerBtn, "RIGHT", verBtnGap, 0)
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

        local dupVer = D().CopyVersion(srcVer)
        -- type(), not truthiness: table.insert raises "wrong number of arguments"
        -- on a scalar 'versions', and the "#dvEntry.data.versions" read below
        -- raises "attempt to get length of field 'versions'".
        if type(dvEntry.data.versions) ~= "table" then
            return
        end
        table.insert(dvEntry.data.versions, dupVer)
        SE._updatingFromEditor = true
        GRIPEMS.Engine:UpdateSequenceData(SE.currentSequence, dvEntry.data)
        SE._updatingFromEditor = false
        SE:_QueueQuickResign(SE.currentSequence)
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
    UI:RegisterLargeTarget(delVerBtn)
    delVerBtn:SetPoint("LEFT", dupVerBtn, "RIGHT", verBtnGap, 0)
    delVerBtn:SetScript("OnClick", function()
        if not SE.currentSequence then
            return
        end
        if SE.isDirty then
            SE:PromptSave()
            return
        end
        local dlEntry = GRIPEMS.Engine and GRIPEMS.Engine.sequences and GRIPEMS.Engine.sequences[SE.currentSequence]
        -- type(), not truthiness: the "#dlEntry.data.versions" read below raises
        -- "attempt to get length of field 'versions'" on a scalar.
        if not dlEntry or not dlEntry.data or type(dlEntry.data.versions) ~= "table" then
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
        -- Adjust pinnedVersion the same way (LIVE-VERSION-QUICK-SWAP): clear it
        -- if the pinned version was deleted, decrement it if it sat above the
        -- deleted index. Persisted by the UpdateSequenceData call below, exactly
        -- like defaultVersion / contextOverrides above.
        local pinVer = dlEntry.data.pinnedVersion
        if pinVer == deletedIdx then
            dlEntry.data.pinnedVersion = nil
        elseif pinVer and pinVer > deletedIdx then
            dlEntry.data.pinnedVersion = pinVer - 1
        end
        SE._updatingFromEditor = true
        GRIPEMS.Engine:UpdateSequenceData(SE.currentSequence, dlEntry.data)
        SE._updatingFromEditor = false
        SE:_QueueQuickResign(SE.currentSequence)
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
    UI:RegisterLargeTarget(defVerBtn)
    defVerBtn:SetPoint("LEFT", delVerBtn, "RIGHT", verBtnGap, 0)
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
        -- Set Default flips which version is engine-live for context-free
        -- sequences: refresh the Variants tab liveness label when the tab
        -- is open (RefreshFromSelection self-guards on visibility).
        if GRIPEMS.VariantsTab and GRIPEMS.VariantsTab.RefreshFromSelection then
            GRIPEMS.VariantsTab:RefreshFromSelection()
        end
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
    local previewFrame = CreateFrame("Frame", nil, seParent, "BackdropTemplate")
    previewFrame:SetHeight(D().PREVIEW_FRAME_HEIGHT)
    previewFrame:SetPoint("TOPLEFT", versionBar, "BOTTOMLEFT", 0, 0)
    previewFrame:SetPoint("RIGHT", seParent, "RIGHT", 0, 0)
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
    previewScroll:SetScript("OnSizeChanged", function(self)
        local w = self:GetWidth()
        if w > 0 then
            previewEditBox:SetWidth(w)
        end
    end)
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
    scrollTrack:SetPoint("BOTTOMLEFT", previewIconScroll, "BOTTOMLEFT", 0, -2 - UI:GetRowGap())
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
            if GRIPEMS.ExportFrame then
                GRIPEMS.ExportFrame:Show(L["GEMS_PREVIEW_COPY_HEADER"], clean, L["GEMS_PREVIEW_COPY_HINT"], {
                    rawHeader = true,
                    title = L["GEMS_PREVIEW_COPY_TITLE"],
                })
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
    local tabBar = CreateFrame("Frame", nil, seParent, "BackdropTemplate")
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
        { name = "Variants", label = L["GEMS_UI_TAB_VARIANTS"], active = true },
        { name = "Raw", label = L["GEMS_UI_TAB_RAW"], active = true },
    }
    SE.tabButtons = {}
    -- Stored on SE so SE:RebuildTabBar() can re-run the creation loop in-place
    -- when the user toggles showVariantsTab.
    SE._tabDefs = tabDefs
    local prevTab
    for _, def in ipairs(tabDefs) do
        -- Variants tab gating (IC-VAR-02 Phase 2). Skip entire button
        -- creation when setting is OFF so layout naturally collapses.
        -- Condition is positive (show-when-allowed) to satisfy luacheck
        -- empty-if-branch.
        local showVariants = GRIPEMS.Settings and GRIPEMS.Settings:Get("showVariantsTab")
        if def.name ~= "Variants" or showVariants then
            local tab = CreateFrame("Button", nil, tabBar, "BackdropTemplate")
            tab:SetSize(62, D().TAB_HEIGHT)
            UI:RegisterLargeTarget(tab)
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
        end -- close Variants-gate if (Edit 10 in IC-VAR-02 Phase 2)
    end

    -- Help (?) button: opens a context-aware popover for the active tab.
    local helpBtn = UI:CreateButton(tabBar, L["ACCESS_HELP_BUTTON_LABEL"] or "?", 22, D().TAB_HEIGHT)
    UI:RegisterLargeTarget(helpBtn)
    helpBtn:SetPoint("RIGHT", tabBar, "RIGHT", -4, 0)
    helpBtn:SetScript("OnClick", function()
        if GRIPEMS.Help then
            GRIPEMS.Help:Toggle(SE.activeTab, helpBtn)
        end
    end)
    helpBtn:SetScript("OnEnter", function(self)
        UI:ShowTooltip(self, L["ACCESS_HELP_BUTTON_TOOLTIP"] or "Help")
    end)
    helpBtn:SetScript("OnLeave", function()
        UI:HideTooltip()
    end)
    SE.helpBtn = helpBtn

    -----------------------------------------------------------------------
    -- Content area (hosts tab content)
    -----------------------------------------------------------------------
    -- Phase F T2: contentArea is now inside scrollChild. Width follows tabBar
    -- (TOPRIGHT anchor); height set explicitly via SE:_RecomputeRightPanelScrollChild
    -- (clamp 170 px min). Old BOTTOMRIGHT-to-parentPanel anchor removed because
    -- scrollChild's height is dynamic, not anchor-derived.
    local contentArea = CreateFrame("Frame", nil, seParent)
    contentArea:SetPoint("TOPLEFT", tabBar, "BOTTOMLEFT", 0, 0)
    contentArea:SetPoint("TOPRIGHT", tabBar, "BOTTOMRIGHT", 0, 0)
    contentArea:SetHeight(170)
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

    -- Initialize VariantsTab inside content area (IC-VAR-02 Phase 2). Always
    -- builds the frame regardless of showVariantsTab so toggling the setting
    -- back on does not require recreating UI surface. The tab button is the
    -- only gated piece (see for-loop wrapper above).
    if GRIPEMS.VariantsTab then
        GRIPEMS.VariantsTab:Init(contentArea)
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
        -- IC-VAR-02 Phase 2: live-toggle showVariantsTab without /reload
        GRIPEMS.RegisterCallback(SE, "SETTING_CHANGED", "OnSettingChanged")
        -- Keep the version-bar Live badge correct when the player zones (context
        -- change) with the editor open. Display-only refresh, no engine change.
        GRIPEMS.RegisterCallback(SE, "CONTEXT_CHANGED", "OnContextChangedEditor")
    end

    -----------------------------------------------------------------------
    -- Keyboard navigation (Item 1)
    -----------------------------------------------------------------------
    -- Phase 2 #7: editBoxFocused relocated to GRIPEMS.Focus. The back-compat
    -- metatable at the top of this file serves legacy SE.editBoxFocused
    -- reads. Writes below go through Focus:SetEditBoxFocused.

    -- Phase 2 #7: editBoxFocused wiring lives on GRIPEMS.Focus.
    -- HookEditBoxFocus is a thin alias for Focus:HookEditBox so the
    -- per-editbox calls below stay legible at the original sites.
    local function HookEditBoxFocus(editBox)
        if GRIPEMS.Focus and GRIPEMS.Focus.HookEditBox then
            GRIPEMS.Focus:HookEditBox(editBox)
        end
    end

    HookEditBoxFocus(SE.nameEditBox)
    HookEditBoxFocus(SE.keyPressEditBox)
    HookEditBoxFocus(SE.keyReleaseEditBox)
    HookEditBoxFocus(SE.timerBox)
    HookEditBoxFocus(SE.metaAuthorBox)
    HookEditBoxFocus(SE.metaDescBox)
    HookEditBoxFocus(SE.metaHelpBox)
    HookEditBoxFocus(SE.metaHelpLinkBox)
    HookEditBoxFocus(SE.metaChangelogBox)
    HookEditBoxFocus(SE.metaTalentBox)

    -- Ordered tab names for arrow cycling (must match tabDefs order)
    local tabOrder = { "Steps", "Keybind", "Macros", "Context", "Variables", "Variants", "Raw" }

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
            if SE.metaChangelogBox and SE.metaChangelogBox:IsVisible() then
                fields[#fields + 1] = SE.metaChangelogBox
            end
            if SE.metaTalentBox and SE.metaTalentBox:IsVisible() then
                fields[#fields + 1] = SE.metaTalentBox
            end
        end
        return fields
    end

    parentPanel:EnableKeyboard(true)
    parentPanel:SetScript("OnKeyDown", function(self, key)
        -- Combat taint guard: SetPropagateKeyboardInput below is protected.
        -- Calling it from addon code during combat taints parentPanel and
        -- cascades ADDON_ACTION_BLOCKED to child frames. Skip all editor
        -- keyboard shortcuts during combat; prior propagation state (typically
        -- true from the fallthrough at the handler end) persists, so keys
        -- flow to the game normally.
        if InCombatLockdown() then
            return
        end
        -- Suspenders layer: independent of the Focus flag, query WoW
        -- directly for any focused EditBox. If found, propagate the key
        -- and let the EditBox handle it.
        if GetCurrentKeyBoardFocus and GetCurrentKeyBoardFocus() then
            pcall(self.SetPropagateKeyboardInput, self, true)
            return
        end
        -- Only handle keys when no EditBox has focus and editor is visible.
        -- (editBoxFocused flag now owned by GRIPEMS.Focus per Phase 2 #7.)
        if GRIPEMS.Focus and GRIPEMS.Focus:IsEditBoxFocused() then
            pcall(self.SetPropagateKeyboardInput, self, true)
            return
        end
        if not SE.currentSequence then
            pcall(self.SetPropagateKeyboardInput, self, true)
            return
        end

        -- Phase 2 #7: SPACE opens the per-step detail pane; DELETE
        -- removes the current step. Both scoped to the Steps tab. ENTER is
        -- reserved to reach the game (chat), so it is no longer handled here.
        -- The detail pane anchors on workingActions nodeIndex (hierarchical
        -- actions), with a fallback through _editingContext for outline rows
        -- that stored nodeIndex at click time.
        if key == "SPACE" and SE.activeTab == "Steps" then
            local SLV = GRIPEMS.StepListView
            if SLV then
                local nodeIdx = nil
                if SLV._editingContext and SLV._editingContext.nodeIndex then
                    nodeIdx = SLV._editingContext.nodeIndex
                elseif SLV.hasActions and SLV.workingActions and SLV.selectedIndex then
                    nodeIdx = SLV.selectedIndex
                end
                if nodeIdx and SLV.OpenDetailPane and SLV.workingActions and SLV.workingActions[nodeIdx] then
                    SLV:OpenDetailPane(nodeIdx)
                    pcall(self.SetPropagateKeyboardInput, self, false)
                    return
                end
            end
        end

        if key == "DELETE" and SE.activeTab == "Steps" then
            local SLV = GRIPEMS.StepListView
            if SLV then
                -- Actions mode: resolve the selected node from the editing
                -- context (or the open detail pane) and remove it directly,
                -- mirroring the action-bar Delete button. DeleteStep below
                -- only knows the flat-mode workingSteps array, so without
                -- this branch keyboard-Delete is a no-op for any node in
                -- the action tree (macro-ref, Loop, If, ...).
                if SLV.hasActions and SLV.workingActions then
                    local ni = (SLV._editingContext and SLV._editingContext.nodeIndex)
                        or (SLV._detailOpen and SLV._detailNodeIndex)
                    if ni and SLV.workingActions[ni] then
                        table.remove(SLV.workingActions, ni)
                        if SLV._detailOpen and SLV._detailNodeIndex then
                            if SLV._detailNodeIndex == ni then
                                SLV:CloseDetailPane()
                            elseif SLV._detailNodeIndex > ni then
                                SLV._detailNodeIndex = SLV._detailNodeIndex - 1
                            end
                        end
                        SLV._editingContext = nil
                        SLV.selectedIndex = nil
                        if SLV._markDirty then
                            SLV:_markDirty()
                        end
                        SLV:RefreshAll()
                        pcall(self.SetPropagateKeyboardInput, self, false)
                        return
                    end
                end
                if SLV.DeleteStep then
                    SLV:DeleteStep()
                    pcall(self.SetPropagateKeyboardInput, self, false)
                    return
                end
            end
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

        -- Phase 4 item 8: numbered-key tab jump. 1..6 (or Alt+1..Alt+6) while
        -- the SequenceEditor is focused jumps directly to the matching tab.
        -- Shift+digit and Ctrl+digit fall through so action-bar page
        -- modifiers are unaffected. Combat guard already handled above.
        -- Phase 4 item 29 A11Y-SE-OVERLAY-GATE: when a modal context
        -- (SpellPicker, PopupEditor, RepairFrame, ImportFrame, ExportFrame,
        -- ComparisonFrame, Tutorial, simplified-mode flow) is on top of
        -- the focus stack, digit keys must not switch SE tabs. Only the
        -- base "MainFrame" and "KeybindTab" contexts allow the tab jump
        -- (KeybindTab is the keybind tab's own focus context from a56cb80, a
        -- base context, not a modal).
        if
            (key == "1" or key == "2" or key == "3" or key == "4" or key == "5" or key == "6")
            and not IsShiftKeyDown()
            and not IsControlKeyDown()
        then
            local Focus = GRIPEMS.Focus
            local top = Focus and Focus.TopContext and Focus:TopContext()
            if top and top.name and top.name ~= "MainFrame" and top.name ~= "KeybindTab" then
                pcall(self.SetPropagateKeyboardInput, self, true)
                return
            end
            local idx = tonumber(key)
            local targetName = idx and tabOrder[idx]
            if targetName then
                local tabBtn = SE.tabButtons[targetName]
                if tabBtn and tabBtn._isActive then
                    SE:SwitchTab(targetName)
                    pcall(self.SetPropagateKeyboardInput, self, false)
                    return
                end
            end
            pcall(self.SetPropagateKeyboardInput, self, true)
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
                    -- Collapse an active flat multi-selection to a single selection
                    -- on the navigated row so the primary index and the highlighted
                    -- set never desync. Outline mode never reports multi (IsMultiSelect
                    -- is gated on not hasActions), so it is unaffected.
                    if SLV.IsMultiSelect and SLV:IsMultiSelect() then
                        SLV.selectedSet = nil
                        SLV.selectionAnchor = newIdx
                    end
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

    -- PLAYER_REGEN_ENABLED reset: ensure keyboard propagation is true after combat.
    -- The combat-taint guard at the top of OnKeyDown skips all SetPropagateKeyboardInput
    -- calls during combat. If the last pre-combat keystroke left propagation = false,
    -- that state persists through the entire combat and blocks action-bar keybinds
    -- pressed while the editor holds focus. Resetting at REGEN_ENABLED clears the
    -- stuck-false edge case; lockdown has fully released at this point so the call
    -- is safe.
    if not parentPanel._gems_regenReset then
        parentPanel:RegisterEvent("PLAYER_REGEN_ENABLED")
        parentPanel:HookScript("OnEvent", function(self, event)
            if event == "PLAYER_REGEN_ENABLED" then
                pcall(self.SetPropagateKeyboardInput, self, true)
            end
        end)
        parentPanel._gems_regenReset = true
    end

    -- OnShow reset: if the editor opens post-combat with stale propagation=false
    -- (e.g. combat started before PLAYER_REGEN_ENABLED could land the REGEN reset,
    -- or the panel was hidden at that moment), clear the stuck-false state on show.
    if not parentPanel._gems_onShowReset then
        parentPanel:HookScript("OnShow", function(self)
            -- Combat-taint guard: SetPropagateKeyboardInput is protected
            -- during lockdown. If the editor opens mid-combat the call
            -- fires ADDON_ACTION_BLOCKED (pcall suppresses the lua error
            -- but not the protected-function event). The
            -- PLAYER_REGEN_ENABLED handler above restores propagation
            -- when combat ends, so skipping the call here is safe.
            if InCombatLockdown() then
                return
            end
            pcall(self.SetPropagateKeyboardInput, self, true)
        end)
        parentPanel._gems_onShowReset = true
    end

    -- Update tab visuals
    SE:UpdateTabButtons()

    -- Apply-on-build: if Simplified Mode was enabled before the editor was
    -- ever built, the freshly created tabs are unfiltered. RelayoutSimplified
    -- is idempotent and restores-to-normal when the mode is off, so one call
    -- at the end of the build covers both states.
    SE:RelayoutSimplified()

    -----------------------------------------------------------------------
    -- Phase F T2: dynamic scrollChild height. Sums all visible chrome heights + contentArea.
    -- contentArea gets a min-height clamp (170 px = editArea floor 100 + actionBar 30 + gaps + scrollBox).
    -- When sum exceeds rightPanelScroll height, scrollbar engages.
    -----------------------------------------------------------------------
    function SE:_RecomputeRightPanelScrollChild()
        if not SE.rightPanelScrollChild or not SE.rightPanelScroll then
            return
        end
        local sumH = 0
        if SE.header and SE.header:IsShown() then
            sumH = sumH + (SE.header:GetHeight() or 0)
        end
        if SE.stubSection and SE.stubSection:IsShown() then
            sumH = sumH + (SE.stubSection:GetHeight() or 0)
        end
        if SE.metadataSection and SE.metadataSection:IsShown() then
            sumH = sumH + (SE.metadataSection:GetHeight() or 0)
        end
        if SE.resetModSection and SE.resetModSection:IsShown() then
            sumH = sumH + (SE.resetModSection:GetHeight() or 0)
        end
        if SE.spellWarnBanner and SE.spellWarnBanner:IsShown() then
            sumH = sumH + (SE.spellWarnBanner:GetHeight() or 0)
        end
        if SE.versionBar and SE.versionBar:IsShown() then
            sumH = sumH + (SE.versionBar:GetHeight() or 0)
        end
        if SE.previewFrame and SE.previewFrame:IsShown() then
            sumH = sumH + (SE.previewFrame:GetHeight() or 0)
        end
        if SE.tabBar and SE.tabBar:IsShown() then
            sumH = sumH + (SE.tabBar:GetHeight() or 0)
        end
        -- contentArea: clamp to minimum 170 px
        local contentH = math.max(170, (SE.rightPanelScroll:GetHeight() or 0) - sumH)
        if SE.contentArea then
            SE.contentArea:SetHeight(contentH)
        end
        sumH = sumH + contentH
        SE.rightPanelScrollChild:SetHeight(math.max(sumH, SE.rightPanelScroll:GetHeight() or 0))
    end

    -----------------------------------------------------------------------
    -- Phase F T1: auto-collapse 3 expand-collapse sections when rightPanel.height drops below threshold.
    -- One-way (does NOT auto-expand on size-up; preserves user intent).
    -- Also fires the T3 button-hide logic (Bug 2) when rightPanel.width drops below its threshold.
    -----------------------------------------------------------------------
    function SE:_HandleRightPanelResize()
        if not SE.rightPanel then
            return
        end
        local d = D()
        local h = SE.rightPanel:GetHeight() or 0
        local w = SE.rightPanel:GetWidth() or 0

        -- T1: auto-collapse below height threshold
        if h > 0 and h < d.RIGHTPANEL_AUTOCOLLAPSE_HEIGHT_THRESHOLD then
            if SE.stubExpanded and SE.SetStubExpanded then
                SE:SetStubExpanded(false)
            end
            if SE.metadataExpanded and SE.SetMetadataExpanded then
                SE:SetMetadataExpanded(false)
            end
            if SE.resetModExpanded and SE.SetResetModExpanded then
                SE:SetResetModExpanded(false)
            end
        end

        -- T3: hide non-essential header buttons below width threshold
        if w > 0 then
            local hideBtns = w < d.RIGHTPANEL_BUTTON_HIDE_WIDTH_THRESHOLD
            if SE.disableBtn then
                if hideBtns then
                    SE.disableBtn:Hide()
                else
                    SE.disableBtn:Show()
                end
            end
            if SE.exportBtn then
                if hideBtns then
                    SE.exportBtn:Hide()
                else
                    SE.exportBtn:Show()
                end
            end
            -- Visibility changed: the EditBox's right anchor must follow.
            SE:_UpdateNameEditBoxRightAnchor()
        end

        if SE._RecomputeRightPanelScrollChild then
            SE:_RecomputeRightPanelScrollChild()
        end
    end

    -- Phase F T1+T3: react to MainFrame resizes. Mirrors the StepListView L233 HookScript pattern.
    SE.rightPanel = parentPanel
    parentPanel:HookScript("OnSizeChanged", function()
        SE:_HandleRightPanelResize()
    end)
    SE:_HandleRightPanelResize() -- initial pass before OnSizeChanged fires
end

--- Apply a UI scale multiplier to the editor container.
--- Mirrors TrackerHUD:Rebuild SetScale pattern.
function SE:SetScale(scale)
    if not SE.container then
        return
    end
    SE.container:SetScale(scale or 1.0)
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
        and tabName ~= "Variants"
        and tabName ~= "Raw"
    then
        return
    end
    -- Simplified Mode (Phase S2): only Steps and Keybind are reachable.
    -- Refuse navigation to the other four even if called programmatically.
    local acc = GRIPEMS.Settings
        and GRIPEMS.Settings.db
        and GRIPEMS.Settings.db.profile
        and GRIPEMS.Settings.db.profile.accessibility
    if acc and acc.simplifiedMode and tabName ~= "Steps" and tabName ~= "Keybind" then
        return
    end
    SE.activeTab = tabName
    -- Plugin API v2 (Phase D): announce the accepted tab switch to plugins. Inside
    -- both guards above, so only a valid, simplified-mode-allowed switch fires. The
    -- file-scope init assignment (SE.activeTab = "Steps") is NOT a switch and does
    -- not fire. Nil-guarded like the other in-core fires; payload is the tab name.
    if GRIPEMS.Fire then
        GRIPEMS:Fire("GEMS_EDITOR_TAB_CHANGED", tabName)
    end
    SE:UpdateTabButtons()
    SE:UpdateTabContent()

    -- Persist last tab choice
    if _G.GRIP_EMS_CHAR and GRIP_EMS_CHAR.ui then
        GRIP_EMS_CHAR.ui.lastTab = tabName
    end
end

--- Handle showVariantsTab toggle without /reload (IC-VAR-02 Phase 2).
--- Other SETTING_CHANGED keys are ignored here so the listener is a no-op
--- for unrelated settings.
function SE:OnSettingChanged(_, key)
    if key ~= "showVariantsTab" then
        return
    end
    SE:RebuildTabBar()
end

--- Rebuild the tab bar in-place when showVariantsTab flips. Destroys the
--- existing tab buttons (releasing them via SetParent(nil) so the layout
--- chain anchored on prevTab does not leak references) and re-runs the
--- same per-def loop the Init pass used. The content frame for VariantsTab
--- is already created and parented to contentArea, so this is a pure
--- tab-bar refresh -- no UI recreation needed.
---
--- If the active tab is "Variants" when the setting flips OFF, fall back
--- to "Steps" via SE:SwitchTab("Steps") so the editor never lands on a
--- now-invisible tab.
function SE:RebuildTabBar()
    if not SE.tabBar or not SE._tabDefs then
        return
    end
    local D_ = D()
    local C = UI.Colors
    -- Tear down existing buttons
    for _, tab in pairs(SE.tabButtons) do
        if tab.SetScript then
            tab:SetScript("OnClick", nil)
            tab:SetScript("OnEnter", nil)
            tab:SetScript("OnLeave", nil)
        end
        if tab.Hide then
            tab:Hide()
        end
        if tab.SetParent then
            tab:SetParent(nil)
        end
    end
    SE.tabButtons = {}

    -- Rebuild with the same gating logic as the Init for-loop above.
    local showVariants = GRIPEMS.Settings and GRIPEMS.Settings:Get("showVariantsTab")
    local prevTab
    for _, def in ipairs(SE._tabDefs) do
        if def.name ~= "Variants" or showVariants then
            local tab = CreateFrame("Button", nil, SE.tabBar, "BackdropTemplate")
            tab:SetSize(62, D_.TAB_HEIGHT)
            UI:RegisterLargeTarget(tab)
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
                tab:SetPoint("LEFT", SE.tabBar, "LEFT", 4, 0)
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
                tabLabel:SetTextColor(C.textMuted:GetRGBA())
            end
            SE.tabButtons[def.name] = tab
            prevTab = tab
        end
    end

    -- If user was on Variants when setting flipped OFF, redirect to Steps.
    if SE.activeTab == "Variants" and not showVariants then
        SE:SwitchTab("Steps")
    else
        SE:UpdateTabButtons()
    end

    -- Re-apply the Simplified filter after a tab-bar rebuild: the rebuild
    -- recreates buttons with _isActive from the raw defs, which wipes the
    -- Simplified tab whitelist. Idempotent; restores-to-normal when off.
    SE:RelayoutSimplified()
end

--- Update tab button styling (active vs inactive).
function SE:UpdateTabButtons()
    -- Pre-build guard: /gems test simplified can run before the editor is
    -- ever built, so tabButtons may not exist yet. pairs(nil) crashes; the
    -- post-build apply (RelayoutSimplified at the end of the build) re-runs
    -- this once tabButtons exists.
    if not SE.tabButtons then
        return
    end
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
    local VxTab = GRIPEMS.VariantsTab
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
        if SLV and SLV.emptyIcon then
            SLV.emptyIcon:Hide()
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
            -- Rebuild list content + empty-state visibility on tab return.
            -- RefreshAll is tab-aware and asserts visibility only when the
            -- Steps tab is active (which it is, in this branch).
            if SLV.RefreshAll then
                SLV:RefreshAll()
            end
            if SLV.scrollBox then
                SLV.scrollBox:Show()
            end
            if SLV.scrollBar then
                SLV.scrollBar:Show()
            end
            if SLV._detailOpen and SLV._detailContainer then
                SLV._detailContainer:Show()
            end
            -- Simplified Mode replaces the standard action bar with the
            -- 3-button column; RelayoutSimplified hides it, but a tab return
            -- lands here and blindly re-showed it (found during the Phase
            -- 6-polish AVAV, 2026-07-10). Hide while simplified so a tab
            -- return also corrects a stray-shown bar; the simplified-off
            -- restore path reaches this branch with the flag already false,
            -- so normal restore is unchanged.
            if SLV.actionBar then
                local acc = GRIPEMS.Settings
                    and GRIPEMS.Settings.db
                    and GRIPEMS.Settings.db.profile
                    and GRIPEMS.Settings.db.profile.accessibility
                if acc and acc.simplifiedMode then
                    SLV.actionBar:Hide()
                else
                    SLV.actionBar:Show()
                end
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
        if VxTab then
            VxTab:Hide()
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
        if VxTab then
            VxTab:Hide()
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
        if VxTab then
            VxTab:Hide()
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
        if VxTab then
            VxTab:Hide()
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
        if VxTab then
            VxTab:Hide()
        end
        if RTab then
            RTab:Hide()
        end
    elseif SE.activeTab == "Variants" then
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
        if VxTab then
            VxTab:Show()
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
        if VxTab then
            VxTab:Hide()
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

    -- Settle any pending quick-edit re-sign under the old name BEFORE the
    -- rename copies the data: the rename carries the signature verbatim
    -- (valid only for signed content), and the orphaned timer would no-op
    -- once the old key is gone.
    if SE._quickResignGen[oldName] then
        SE:_CancelQuickResign(oldName)
        SE:_FlushQuickResign(oldName)
    end

    -- Plugin-owned sequences are lifecycle-managed by their plugin
    -- (ownership journal is keyed by name); a user rename would orphan
    -- the journal and break DisablePlugin teardown.
    if oldData.ownerPlugin then
        GRIPEMS:Print(string.format(L["GEMS_UI_RENAME_PLUGIN_OWNED"], oldName, tostring(oldData.ownerPlugin)))
        if SE.nameEditBox then
            SE.nameEditBox:SetText(oldName)
        end
        return
    end

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
        changelog = oldData.changelog or "",
        talentString = oldData.talentString,
        url = oldData.url,
        importMeta = oldData.importMeta,
        disabled = oldData.disabled,
        classID = oldData.classID or 0,
        specID = oldData.specID,
        -- IC-VAR-02: sequence-level recommend fallback, previously dropped
        -- on rename (silent loss of Variants-tab authoring).
        recommendSource = oldData.recommendSource,
        createdAt = oldData.createdAt or time(),
        updatedAt = time(),
    }
    -- Deep copy contextOverrides
    if oldData.contextOverrides then
        for k, v in pairs(oldData.contextOverrides) do
            newData.contextOverrides[k] = v
        end
    end
    -- Deep copy all versions via the same generic all-keys copy the
    -- list rename and DuplicateSequence use. It carries the locale
    -- sidecars (taggedSteps / taggedKeyPress / taggedKeyRelease /
    -- stepsLocale) the old explicit field list dropped -- ALG_V2 canon
    -- prefers the tagged sidecar, so dropping it could false-tamper an
    -- imported signed sequence on a pure rename. The IC-VAR-02 and
    -- ARCH-MIGRATE carries now ride the generic copy.
    if type(oldData.versions) == "table" then
        for i, ver in ipairs(oldData.versions) do
            newData.versions[i] = GRIPEMS.Defaults.CopyVersion(ver)
        end
    end

    -- v2.3.4 Phase 4: rename must not strip identity -- carry provenance,
    -- privacyMode, MetaData dep tags, and soundCues (name is not a signature
    -- canon field, so carried signatures stay valid).
    GRIPEMS.Defaults.CarrySequenceIdentity(newData, oldData)

    -- Deactivate old, activate new
    GRIPEMS.Engine:DeactivateSequence(oldName)
    GRIPEMS.Engine:ActivateSequence(newName, newData)

    -- Re-key the per-spec hold-mode preference to the new name
    if GRIPEMS.TempoAdvisor and GRIPEMS.TempoAdvisor.RenameHoldMode then
        GRIPEMS.TempoAdvisor:RenameHoldMode(oldName, newName)
    end

    -- Re-apply keybind to new name
    if oldKey and KM then
        if C_Timer and C_Timer.After then
            C_Timer.After(0.15, function()
                KM:SetKeybind(newName, oldKey)
            end)
        end
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
    -- Guard: an external theme-repaint caller (e.g. a Plugin-API consumer that
    -- recolors the editor) can invoke this before the Steps-tab header is built,
    -- so SE.sfButtons may not exist yet. Nothing to recolor until it does.
    if not SE.sfButtons then
        return
    end
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

---------------------------------------------------------------------------
-- Quick-persist re-sign
---------------------------------------------------------------------------

-- Quick persists below write V2-canon content (step function, combat/target
-- reset, reset timer, keyPress/keyRelease) straight into the stored sequence
-- via UpdateSequenceData without the full save's re-sign, so closing the
-- editor without saving left the owner's own sequence verifying "tampered".
-- A short debounce turns a burst of toggles or keystrokes into ONE owned
-- re-sign + ONE chain entry. The flush runs AFTER the persist's normalize
-- pass, so the locale sidecars are already in sync with the new content
-- when the canon reads them (no strip needed on this path). Non-canon
-- quick persists (repeatCount, resetModifiers, gear/spec resets) do not
-- queue: they cannot diverge the signature.
local QUICK_RESIGN_DELAY = 1.0
SE._quickResignGen = {}
-- Monotonic across ALL sequences and never reset: a slot that is nil'd by a
-- cancel or flush and then re-armed gets a fresh serial, so a stale timer
-- from before the cancel can never match the new arming.
SE._quickResignSerial = 0

--- Queue (or re-arm) the debounced re-sign for a sequence.
--- @param seqName string Sequence whose canon content was quick-persisted
function SE:_QueueQuickResign(seqName)
    if not seqName then
        return
    end
    SE._quickResignSerial = SE._quickResignSerial + 1
    local gen = SE._quickResignSerial
    SE._quickResignGen[seqName] = gen
    if C_Timer and C_Timer.After then
        C_Timer.After(QUICK_RESIGN_DELAY, function()
            if SE._quickResignGen[seqName] ~= gen then
                return
            end
            SE._quickResignGen[seqName] = nil
            SE:_FlushQuickResign(seqName)
        end)
    else
        SE._quickResignGen[seqName] = nil
        SE:_FlushQuickResign(seqName)
    end
end

--- Drop a pending re-sign (the full save just signed everything itself).
--- @param seqName string Sequence name
function SE:_CancelQuickResign(seqName)
    if seqName then
        SE._quickResignGen[seqName] = nil
    end
end

-- Settle every pending re-sign before the SavedVariables write: the data
-- mutation persists at logout either way (entry.data aliases the SV row),
-- and would land unsigned unless flushed here. Fires on /reload too.
local quickResignFlusher = CreateFrame("Frame")
quickResignFlusher:RegisterEvent("PLAYER_LOGOUT")
quickResignFlusher:SetScript("OnEvent", function()
    local pending = {}
    for name in pairs(SE._quickResignGen) do
        pending[#pending + 1] = name
    end
    for _, name in ipairs(pending) do
        SE._quickResignGen[name] = nil
        SE:_FlushQuickResign(name)
    end
end)

--- Re-sign a quick-persisted sequence: owned V2 refresh + one chain entry,
--- then persist the signature fields. Skips unstamped sequences (nothing
--- signed, nothing to diverge -- the eventual full save stamps them).
--- @param seqName string Sequence name (re-resolved; no-op if gone)
function SE:_FlushQuickResign(seqName)
    local engine = GRIPEMS.Engine
    local Identity = GRIPEMS.Identity
    local entry = engine and engine.sequences and engine.sequences[seqName]
    local data = entry and entry.data
    if not (Identity and Identity.AppendModifierEntry and data) then
        return
    end
    if not data.originalAuthor or data.originalAuthor == "" then
        return
    end
    if Identity.EnsureOwnedV2Signature then
        Identity:EnsureOwnedV2Signature(data)
    end
    Identity:AppendModifierEntry(data, "edited")
    SE._updatingFromEditor = true
    engine:UpdateSequenceData(seqName, data)
    SE._updatingFromEditor = false
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
    SE:_QueueQuickResign(SE.currentSequence)
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
    local signedContent = false
    if resetType == "combat" then
        ver.resetOnCombat = checked and true or false
        signedContent = true
    elseif resetType == "target" then
        ver.resetOnTarget = checked and true or false
        signedContent = true
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
    if signedContent then
        SE:_QueueQuickResign(SE.currentSequence)
    end
end

--- Handle the per-version channel-hold mode dropdown.
--- @param mode string One of "off", "hold", "release"
function SE:OnChannelHoldModeChanged(mode)
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
    ver.holdOnChannel = (mode == "hold" or mode == "release") and true or false
    ver.releaseAtMax = (mode == "release") and true or false
    SE.isDirty = true
    SE:UpdateSaveButtons()
    SE._updatingFromEditor = true
    GRIPEMS.Engine:UpdateSequenceData(SE.currentSequence, entry.data)
    SE._updatingFromEditor = false
end

--- Refresh the channel-hold mode dropdown from a version.
--- Visible when this character knows at least one press-hold-release spell, OR
--- when the flag is ALREADY set on this version. The second clause is not
--- optional: a sequence imported from a character that had the control would
--- otherwise carry a set flag that the importing character can neither see nor
--- clear, which is a hidden setting and a support ticket. "Already set" spans
--- BOTH flags so releaseAtMax alone cannot hide the control either.
--- @param ver table|nil The version being edited
function SE:RefreshChannelHoldControl(ver)
    local dd = SE.channelHoldDropdown
    if not dd then
        return
    end
    local isSet = (ver and (ver.holdOnChannel or ver.releaseAtMax)) and true or false
    local SC = GRIPEMS.SpellCache
    local hasEmpower = (SC and SC.HasEmpowerSpells and SC:HasEmpowerSpells()) and true or false
    -- The pair {holdOnChannel = false, releaseAtMax = true} is not producible by
    -- this dropdown and is inert at runtime, because every click body tests
    -- holdOnChannel first. Read it as "off" rather than repairing it.
    local mode = "off"
    if ver and ver.holdOnChannel then
        mode = (ver.releaseAtMax and "release") or "hold"
    end
    dd._value = mode
    local labels = SE.channelHoldModeLabels or {}
    UIDropDownMenu_SetText(dd, labels[mode] or mode)
    if hasEmpower or isSet then
        dd:Show()
        if SE.channelHoldLabel then
            SE.channelHoldLabel:Show()
        end
    else
        dd:Hide()
        if SE.channelHoldLabel then
            SE.channelHoldLabel:Hide()
        end
    end
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
    if ver.resetTimer == (value or 0) then
        return
    end
    ver.resetTimer = value or 0
    SE.isDirty = true
    SE:UpdateSaveButtons()
    SE._updatingFromEditor = true
    GRIPEMS.Engine:UpdateSequenceData(SE.currentSequence, entry.data)
    SE._updatingFromEditor = false
    SE:_QueueQuickResign(SE.currentSequence)
end

--- Handle the per-version Repeat-N EditBox change.
--- @param value number New repeat count (clamped 1..MAX in the caller)
function SE:OnRepeatCountChanged(value)
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
    ver.repeatCount = value or 1
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
    SE:_QueueQuickResign(SE.currentSequence)
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
    SE:_QueueQuickResign(SE.currentSequence)
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
    local body = MM:BuildStubBody(buttonName, ver.keyPress, ver.keyRelease, ver.steps)
    SE.stubContentBox:SetText(body or "")
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

    -- Macros section (v2.2.0 L87: author-tagged via MacrosTab)
    yOff = yOff - 2 -- small gap
    MakeRow(L["GEMS_DEPS_MACROS"], C.textSecondary, 0)
    if #deps.macros == 0 then
        MakeRow(L["GEMS_DEPS_NONE"], C.textMuted, dc.indent)
    else
        for _, m in ipairs(deps.macros) do
            -- Color by current macro presence: green if found in WoW, error if missing
            local slot = GetMacroIndexByName and GetMacroIndexByName(m.name) or 0
            local color = (slot and slot > 0) and C.textSuccess or C.textError
            MakeRow(m.name, color, dc.indent)
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
    -- META_ROWS bumped from 9 -> 14 in Phase 4 item 22 Phase 2 to make room
    -- for the per-sequence sound cue header + four LSM override dropdowns
    -- inserted between Updated and Hold Mode. Bumped again for the v2.3.4
    -- Talent Loadout row.
    -- v2.3.4 Phase 3: synced to SE:Init's META_ROWS (19). Both constants
    -- model the SAME fixed-rows region above the dependencies separator;
    -- the historical drift (17 vs 15, then 19 vs 16) made this recompute
    -- under-count the section by 44-66px whenever dependencies rendered,
    -- letting content anchored below the section ride up over the dep rows
    -- and Click Rate block. MUST equal the META_ROWS local in SE:Init.
    local META_ROWS = 19
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
    GRIPEMS.Popup:Define("GRIPEMS_RECORDING_CONFIRM", {
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
        hideOnEscape = true,
    })
    GRIPEMS.Popup:Show("GRIPEMS_RECORDING_CONFIRM")
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
        if C_Timer and C_Timer.After then
            C_Timer.After(0.1, function()
                local SL = GRIPEMS.SequenceList
                if SL then
                    SL:SelectSequence(name)
                end
                SE.isDirty = true
                SE:UpdateSaveButtons()
            end)
        end

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

--- Anchor the name EditBox's RIGHT edge to the leftmost VISIBLE element of the
--- header's right-hand button cluster.
---
--- The EditBox is created before the header buttons and wins the mouse hit test
--- wherever they overlap, so an over-wide RIGHT anchor silently swallows every
--- button it covers rather than merely drawing over it. Anchoring to exportBtn
--- while the editor was clean put the EditBox's edge on disableBtn's exact right
--- edge, which made Disable unclickable: it reported the EditBox's own rename
--- tooltip and never fired. Save and Discard hide when clean, but disableBtn does
--- not, so it cannot be skipped over.
---
--- Order matters: saveBtn is the leftmost button when the editor is dirty, then
--- the disabled badge, then disableBtn; exportBtn is the fallback for the narrow
--- layout where the width threshold has hidden both (that hide exists to give the
--- EditBox room, so it must not be clawed back here).
function SE:_UpdateNameEditBoxRightAnchor()
    if not SE.nameEditBox or not SE.iconTex then
        return
    end
    local anchor
    if SE.saveBtn and SE.saveBtn:IsShown() then
        anchor = SE.saveBtn
    elseif SE.disabledBadge and SE.disabledBadge:IsShown() then
        anchor = SE.disabledBadge
    elseif SE.disableBtn and SE.disableBtn:IsShown() then
        anchor = SE.disableBtn
    else
        anchor = SE.exportBtn
    end
    if not anchor then
        return
    end
    SE.nameEditBox:ClearAllPoints()
    SE.nameEditBox:SetPoint("LEFT", SE.iconTex, "RIGHT", 8, 0)
    SE.nameEditBox:SetPoint("RIGHT", anchor, "LEFT", -4, 0)
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
        SE:_UpdateNameEditBoxRightAnchor()
    else
        SE.saveBtn:Hide()
        SE.discardBtn:Hide()
        SE:_UpdateNameEditBoxRightAnchor()
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

--- Refresh the disabled-state badge and toggle button label.
--- Called on sequence load and after toggle, not on every text edit.
function SE:UpdateDisabledState()
    local entry = GRIPEMS.Engine and GRIPEMS.Engine.sequences and GRIPEMS.Engine.sequences[SE.currentSequence]
    local isDisabled = entry and entry.data and entry.data.disabled and true or false
    if SE.disabledBadge then
        if isDisabled then
            SE.disabledBadge:Show()
        else
            SE.disabledBadge:Hide()
        end
    end
    -- The badge shows/hides in the cluster; re-anchor the EditBox.
    SE:_UpdateNameEditBoxRightAnchor()
    if SE.disableBtn and SE.disableBtn.label then
        SE.disableBtn.label:SetText(isDisabled and L["GEMS_UI_ENABLE"] or L["GEMS_UI_DISABLE"])
    end
end

--- Update Fork button visibility + chain anchoring. v2.1.0 Phase C.
--- Fork button is shown only on foreign-author sequences (sequences whose
--- originalAuthorIdentity differs from the current player's identity hash).
--- When shown, it inserts itself into the toolbar chain between recordBtn
--- and sendBtn (right-to-left). When hidden, recordBtn re-anchors directly
--- to sendBtn so there is no visual gap.
function SE:UpdateForkButton()
    local Identity = GRIPEMS.Identity
    local entry = GRIPEMS.Engine and GRIPEMS.Engine.sequences and GRIPEMS.Engine.sequences[SE.currentSequence]
    local seqData = entry and entry.data
    local isForeign = false
    if Identity and seqData then
        local me = Identity:GetCurrent()
        local seqId = seqData.originalAuthorIdentity
        if seqId and seqId ~= "" and me and me.identityHash and seqId ~= me.identityHash then
            isForeign = true
        end
    end
    if SE.forkBtn then
        SE.forkBtn:SetShown(isForeign)
    end
    if SE.recordBtn and SE.sendBtn then
        SE.recordBtn:ClearAllPoints()
        if isForeign and SE.forkBtn then
            SE.forkBtn:ClearAllPoints()
            SE.forkBtn:SetPoint("RIGHT", SE.sendBtn, "LEFT", -2, 0)
            SE.recordBtn:SetPoint("RIGHT", SE.forkBtn, "LEFT", -2, 0)
        else
            SE.recordBtn:SetPoint("RIGHT", SE.sendBtn, "LEFT", -2, 0)
        end
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
        SE._lastStaleCount = 0
        SE.spellWarnBanner:SetHeight(0)
        SE.spellWarnBanner:EnableMouse(false)
        SE.spellWarnBanner:Hide()
        if SE.versionBar and SE.header then
            SE.versionBar:ClearAllPoints()
            SE.versionBar:SetPoint("TOPLEFT", SE.header, "BOTTOMLEFT", 0, 0)
            SE.versionBar:SetPoint("TOPRIGHT", SE.header, "BOTTOMRIGHT", 0, 0)
        end
        if SE._RecomputeRightPanelScrollChild then
            SE:_RecomputeRightPanelScrollChild()
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
        if SE._RecomputeRightPanelScrollChild then
            SE:_RecomputeRightPanelScrollChild()
        end
        return
    end
    local valResult = SV:ValidateSequence(seqEntry.data)
    local newStale = valResult.staleCount or 0
    local prevStale = SE._lastStaleCount or 0
    if prevStale == 0 and newStale > 0 and GRIPEMS.Speech and GRIPEMS.Speech.Announce then
        local msg = string.format(L["GEMS_SPELL_WARN_BANNER"], newStale)
        GRIPEMS.Speech:Announce(msg)
    end
    SE._lastStaleCount = newStale
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
            local contextual = {}
            for _, stepResult in ipairs(valResult.steps) do
                for _, spell in ipairs(stepResult.spells) do
                    if spell.status == D().SPELL_STATUS_UNKNOWN then
                        lines[#lines + 1] = string.format(L["GEMS_SPELL_TOOLTIP_UNKNOWN"], spell.name)
                    elseif spell.status == D().SPELL_STATUS_KNOWN then
                        lines[#lines + 1] = string.format(L["GEMS_SPELL_TOOLTIP_KNOWN"], spell.name)
                    elseif spell.status == D().SPELL_STATUS_CONTEXTUAL then
                        contextual[#contextual + 1] = string.format(L["GEMS_SPELL_TOOLTIP_CONTEXTUAL"], spell.name)
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
            if #contextual > 0 then
                local ctxR, ctxG, ctxB = GRIPEMS.UI.Colors.textContextual:GetRGBA()
                GameTooltip:AddLine(table.concat(contextual, "\n"), ctxR, ctxG, ctxB, true)
            end
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
    if SE._RecomputeRightPanelScrollChild then
        SE:_RecomputeRightPanelScrollChild()
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

    -- Retrieve working step labels (flat mode per-step labels, sparse)
    local workingStepLabels = SLV:GetWorkingStepLabels()

    -- Deep copy all versions, updating steps in the active version
    local newData = {
        name = oldData.name,
        icon = oldData.icon,
        autoIcon = oldData.autoIcon,
        defaultVersion = oldData.defaultVersion or 1,
        -- LIVE-VERSION-QUICK-SWAP: carry the per-character pin across save so a
        -- structured-editor save does not silently drop an active pin (nil stays
        -- nil; an out-of-range pin is tolerated by the resolver fall-through).
        pinnedVersion = oldData.pinnedVersion,
        contextOverrides = {},
        versions = {},
        -- v2.1.6: prefer the visible widget. When the author dropdown is
        -- showing (brand-new sequence) read its _value; when the EditBox is
        -- showing (locked sequence) read its text. Either way the chain
        -- falls back to oldData.author for migrated sequences with no live
        -- widget state. :IsShown() (not :GetText()) is the gate because an
        -- empty EditBox text "" is truthy in Lua and would otherwise short-
        -- circuit the dropdown branch.
        author = (
            SE.metaAuthorBox
            and SE.metaAuthorBox:IsShown()
            and (SE._authorBoxCleanText or SE.metaAuthorBox:GetText())
        )
            or ((SE.metaAuthorDropdown and SE.metaAuthorDropdown:IsShown()) and SE.metaAuthorDropdown._value)
            or oldData.author
            or "",
        version = oldData.version or "1",
        description = SE.metaDescBox and SE.metaDescBox:GetText() or oldData.description or "",
        help = SE.metaHelpBox and SE.metaHelpBox:GetText() or oldData.help or "",
        helplink = SE.metaHelpLinkBox and SE.metaHelpLinkBox:GetText() or oldData.helplink or "",
        changelog = SE.metaChangelogBox and SE.metaChangelogBox:GetText() or oldData.changelog or "",
        classID = oldData.classID or 0,
        specID = oldData.specID,
        -- IC-VAR-02: sequence-level recommend fallback, previously dropped
        -- on every editor save (silent loss of Variants-tab authoring).
        recommendSource = oldData.recommendSource,
        createdAt = oldData.createdAt or time(),
        updatedAt = time(),
    }

    -- v2.2.0 L87 EMS-MACRO-DEPS-NATIVE-SEQUENCE-TAGGING: preserve MetaData
    -- fields across save. SaveSequence rebuilds newData from scratch and
    -- previously dropped MetaData entirely; this lost Dependencies on the
    -- first author save of any imported sequence. Carry forward all
    -- non-Dependencies MetaData keys (Checksum, GSEVersion, Disabled etc.)
    -- byte-equal, then merge author-tagged Macros into Dependencies while
    -- preserving any pre-existing Dependencies.Sequences / Variables.
    if oldData.MetaData then
        newData.MetaData = {}
        for k, v in pairs(oldData.MetaData) do
            if k ~= "Dependencies" then
                newData.MetaData[k] = v
            end
        end
        if oldData.MetaData.Dependencies then
            newData.MetaData.Dependencies = {}
            for dk, dv in pairs(oldData.MetaData.Dependencies) do
                newData.MetaData.Dependencies[dk] = dv
            end
        end
    end

    -- Author-tagged macro deps from MacrosTab. Omit Dependencies.Macros
    -- when empty so SavedVariables stay clean for the no-tags case.
    local MTab = GRIPEMS.MacrosTab
    if MTab and MTab.GetMacroDeps then
        local tagged = MTab:GetMacroDeps()
        if tagged and #tagged > 0 then
            newData.MetaData = newData.MetaData or {}
            newData.MetaData.Dependencies = newData.MetaData.Dependencies or {}
            newData.MetaData.Dependencies.Macros = tagged
        elseif newData.MetaData and newData.MetaData.Dependencies then
            newData.MetaData.Dependencies.Macros = nil
            -- Collapse empty Dependencies table for clean SV
            if not next(newData.MetaData.Dependencies) then
                newData.MetaData.Dependencies = nil
            end
            if newData.MetaData and not next(newData.MetaData) then
                newData.MetaData = nil
            end
        end
    end

    -- Phase 4 item 22 Phase 2: optional per-sequence sound cue overrides.
    -- Persist seqData.soundCues only when at least one dropdown carries a
    -- non-empty LSM key. Empty / "(global default)" selections are dropped
    -- from the table, and a fully-cleared override set is persisted as nil
    -- (field omitted) so existing data is not bloated with empty tables.
    local cueDropdowns = {
        error = SE.metaCueErrorDD,
        success = SE.metaCueSuccessDD,
        info = SE.metaCueInfoDD,
        stepComplete = SE.metaCueStepDD,
    }
    local cueOverrides
    for cueKey, dd in pairs(cueDropdowns) do
        local val = dd and dd._value or ""
        if val ~= "" then
            cueOverrides = cueOverrides or {}
            cueOverrides[cueKey] = val
        end
    end
    if cueOverrides then
        newData.soundCues = cueOverrides
    end
    if oldData.contextOverrides then
        for k, v in pairs(oldData.contextOverrides) do
            newData.contextOverrides[k] = v
        end
    end
    if type(oldData.versions) == "table" then
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
                repeatCount = ver.repeatCount,
                importBakedSteps = ver.importBakedSteps,
                keyPress = ver.keyPress or "",
                keyRelease = ver.keyRelease or "",
                recommendSource = ver.recommendSource,
                -- Third instance of one failure class in this literal, after
                -- recommendSource and variantOverrides. This rebuild enumerates fields
                -- by hand, so any per-version field absent here is DELETED by the Save
                -- the editor itself offers. Both were unreachable through the UI from
                -- the day they shipped: the dropdown kept displaying the chosen mode
                -- while the version came back nil/nil. D.NewVersion is the canonical
                -- schema and the parity test in Test/test_v0_upgrade_guard.lua now
                -- asserts every one of its keys survives this rebuild.
                holdOnChannel = ver.holdOnChannel,
                releaseAtMax = ver.releaseAtMax,
            }
            if ver.resetModifiers then
                newData.versions[i].resetModifiers = {}
                for mod, val in pairs(ver.resetModifiers) do
                    newData.versions[i].resetModifiers[mod] = val
                end
            end
            -- IC-VAR-02: carry variant overrides through the rebuild. They
            -- were previously dropped on every editor save and rename -- a
            -- silent loss of overrides authored via the Variants tab or the
            -- variants slash command (per-version recommendSource rides in
            -- the field list above for the same reason).
            if ver.variantOverrides then
                newData.versions[i].variantOverrides = {}
                for j, ov in ipairs(ver.variantOverrides) do
                    local ovCopy = {
                        name = ov.name,
                        modifier = ov.modifier,
                        steps = {},
                        keyPress = ov.keyPress,
                        keyRelease = ov.keyRelease,
                        icon = ov.icon,
                    }
                    for k, step in ipairs(ov.steps or {}) do
                        ovCopy.steps[k] = step
                    end
                    newData.versions[i].variantOverrides[j] = ovCopy
                end
            end
            if i == activeIdx then
                -- Active version: save actions tree if present
                if workingActions then
                    newData.versions[i].actions = DD.DeepCopyActions(workingActions)
                    -- Strip the locale sidecar off the saved tree: the working
                    -- copy carries macroTagged from the last normalize pass, an
                    -- in-place macro edit does not refresh it, and the V2 sign
                    -- below prefers the tag -- it would cover the stale
                    -- pre-edit macro, and the post-save re-tag would badge the
                    -- owner's own sequence "tampered". NormalizeActionsLocale
                    -- regenerates the tags from the new macros inside
                    -- UpdateSequenceData right after this save. Non-active
                    -- versions keep their in-sync tags (nothing edited them).
                    local SCache = GRIPEMS.SpellCache
                    if SCache and SCache._WalkActions then
                        SCache:_WalkActions(newData.versions[i].actions, function(node)
                            node.macroTagged = nil
                        end)
                    end
                    -- Compile flat steps + sparse labels from actions for runtime
                    -- (Phase 1C-bis-outline: compiledLabels sourced from node.label)
                    local AC = GRIPEMS.ActionCompiler
                    local compiledSteps, compiledLabels = AC.CompileActions(workingActions, engine, newData.versions[i])
                    newData.versions[i].steps = compiledSteps
                    newData.versions[i].compiledLabels = compiledLabels
                    if AC.CompilesEmptyDueToInterleave and AC.CompilesEmptyDueToInterleave(workingActions) then
                        GRIPEMS:Print(L["GEMS_INTERLEAVE_NOBASE_WARN"])
                    end
                    -- ARCH-MIGRATE Phase 1: explicit tree save = user accepts
                    -- native compile semantics; baked-steps protection ends for
                    -- this version. UpdateSequenceData re-tags locale sidecars
                    -- from the new steps right after this save path runs.
                    newData.versions[i].importBakedSteps = nil
                else
                    -- Flat mode: working steps only
                    for j, step in ipairs(steps) do
                        newData.versions[i].steps[j] = step
                    end
                end
                -- Preserve per-step labels (flat mode labels follow their step)
                if workingStepLabels then
                    newData.versions[i].stepLabels = {}
                    for j = 1, #steps do
                        newData.versions[i].stepLabels[j] = workingStepLabels[j]
                    end
                end
            else
                -- Non-active versions: straight copy including actions
                for j, step in ipairs(ver.steps) do
                    newData.versions[i].steps[j] = step
                end
                if ver.stepLabels then
                    newData.versions[i].stepLabels = {}
                    for j = 1, #ver.steps do
                        newData.versions[i].stepLabels[j] = ver.stepLabels[j]
                    end
                end
                if ver.actions then
                    newData.versions[i].actions = DD.DeepCopyActions(ver.actions)
                    -- ARCH-MIGRATE Phase 1: import-baked versions keep their
                    -- baked steps; only an explicit editor save of THAT version
                    -- (active branch above) accepts native semantics.
                    if not ver.importBakedSteps then
                        -- Recompile steps + labels for this version (Phase 1C-bis-outline)
                        local AC = GRIPEMS.ActionCompiler
                        local compiledSteps, compiledLabels =
                            AC.CompileActions(ver.actions, engine, newData.versions[i])
                        newData.versions[i].steps = compiledSteps
                        newData.versions[i].compiledLabels = compiledLabels
                    end
                end
            end
        end
    end

    -- v2.3.4: talent string comes from the metadata EditBox (author-editable);
    -- an emptied box clears the field (normalized to nil for clean SV). url,
    -- importMeta, and disabled have no editor widget -- carry them so the
    -- save rebuild stops silently discarding them.
    local talentText = SE.metaTalentBox and SE.metaTalentBox:GetText() or oldData.talentString or ""
    newData.talentString = talentText ~= "" and talentText or nil
    newData.url = oldData.url
    newData.importMeta = oldData.importMeta
    newData.disabled = oldData.disabled
    -- v2.1.0 Authorship Integrity: carry forward provenance fields from oldData,
    -- then stamp identity. StampOriginal fires when originalAuthor is empty
    -- (first save of a brand-new sequence); AppendModifierEntry fires on every
    -- subsequent save. Both update lastModifier* fields.
    newData.originalAuthor = oldData.originalAuthor or ""
    newData.originalAuthorIdentity = oldData.originalAuthorIdentity or ""
    newData.originalAuthorRealm = oldData.originalAuthorRealm or ""
    newData.originalAuthorBattleTag = oldData.originalAuthorBattleTag
    newData.originalCreatedAt = oldData.originalCreatedAt or 0
    newData.originalSignature = oldData.originalSignature or ""
    newData.originalSignatureV2 = oldData.originalSignatureV2 or ""
    newData.lastModifier = oldData.lastModifier or ""
    newData.lastModifierIdentity = oldData.lastModifierIdentity or ""
    newData.lastModifierRealm = oldData.lastModifierRealm or ""
    newData.lastModifiedAt = oldData.lastModifiedAt or 0
    newData.modifierChain = {}
    if oldData.modifierChain then
        for i, chainEntry in ipairs(oldData.modifierChain) do
            newData.modifierChain[i] = chainEntry
        end
    end
    newData.forkedFrom = oldData.forkedFrom
    newData.forkedFromChain = oldData.forkedFromChain
    newData.provenanceSource = oldData.provenanceSource or "native"
    -- v2.1.0 Phase D: privacy mode comes from the metadata dropdown when
    -- present (so a user-selected mode wins on this save), falling back to
    -- the previously-saved per-sequence value, then to "public" for legacy
    -- sequences with no privacyMode field.
    local pmDD = SE.metaPrivacyDropdown
    newData.privacyMode = (pmDD and pmDD._value) or oldData.privacyMode or "public"
    newData.signatureAlgorithm = oldData.signatureAlgorithm or "ALG_V0_DJB2"
    local Identity = GRIPEMS.Identity
    if Identity then
        if newData.originalAuthor == "" then
            -- v2.1.6: pass the author dropdown's value so the chosen
            -- displayName (pseudonym / current char / known alt) is what
            -- gets stamped + signed as originalAuthor. Identity hash still
            -- derives from me.identityHash inside StampOriginal, so the
            -- cryptographic signature stays locked to the BNet account
            -- regardless of which name the user picks.
            local chosen = SE.metaAuthorDropdown and SE.metaAuthorDropdown._value
            Identity:StampOriginal(newData, chosen)
            -- StampOriginal sets ALG_V1_SHA256 + signatures
        else
            -- Legacy ALG_V0_DJB2 -> upgrade lazily on this save. The upgrade
            -- requires an existing V0 signature to migrate: it stamps the
            -- LOCAL user's identityHash into originalAuthorIdentity, so
            -- firing it on an unsigned import would bind a foreign byline to
            -- this account and let EnsureOwnedV2Signature stamp V2 on top.
            -- An unsigned import is deliberately left unsigned rather than
            -- being signed under the local identity.
            local v0Sig = newData.originalSignature
            if newData.signatureAlgorithm == "ALG_V0_DJB2" and v0Sig and v0Sig ~= "" then
                local me = Identity:GetCurrent()
                newData.originalAuthorIdentity = me.identityHash
                newData.signatureAlgorithm = "ALG_V1_SHA256"
                newData.originalSignature = Identity:SignSequence(newData)
            end
            Identity:EnsureOwnedV2Signature(newData)
            Identity:AppendModifierEntry(newData, "edited")
            -- AppendModifierEntry stamps currentSignature.
        end
    end

    SE._updatingFromEditor = true
    engine:UpdateSequenceData(SE.currentSequence, newData)
    SE._updatingFromEditor = false
    -- The full save just re-signed everything; a still-pending quick-edit
    -- re-sign would only append a duplicate chain entry.
    SE:_CancelQuickResign(SE.currentSequence)

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
    SLV:LoadSteps(newVer and newVer.steps or {}, newVer and newVer.actions or nil, newVer and newVer.stepLabels or nil)
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

    GRIPEMS.Popup:Define("GRIPEMS_SAVE_PROMPT", {
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
        hideOnEscape = true,
    })
    GRIPEMS.Popup:Show("GRIPEMS_SAVE_PROMPT")
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
    if not ver or type(ver.steps) ~= "table" or #ver.steps == 0 then
        return nil
    end

    local SC = GRIPEMS.SpellCache
    if not SC then
        return nil
    end

    local text
    if ver.stepFunction == "Priority" or ver.stepFunction == "ReversePriority" then
        local lines = {}
        for i = 1, #ver.steps do
            local s = SC:StepToString(ver.steps[i])
            if s ~= "" then
                lines[#lines + 1] = s
            end
        end
        text = table.concat(lines, "\n")
    else
        text = SC:StepToString(ver.steps[1])
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

    -- Auto-activate dormant sequences when user opens them for editing.
    -- Latched: out of combat the promotion runs inline and fires
    -- SEQUENCE_CREATED mid-load, before SE.currentSequence is assigned; the
    -- SequenceList deferred-activation repair would re-enter LoadSequence
    -- for a redundant second populate. The latch makes the repair skip
    -- exactly that window. In combat the promotion is queued past the latch
    -- and the post-combat fire stays repairable, which is the intended flow.
    if GRIPEMS.Engine:IsSequenceDormant(name) then
        SE._activatingDormant = true
        local promoted, promoteErr = pcall(GRIPEMS.Engine.ActivateDormantSequence, GRIPEMS.Engine, name)
        SE._activatingDormant = false
        if not promoted then
            -- Re-raise after the latch reset: same failure surface as before
            -- the latch existed, but the latch can no longer stick.
            error(promoteErr, 0)
        end
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
        -- v2.1.0 Authorship Integrity: prefer originalAuthor; fall back to author
        -- (migrated sequences may have empty originalAuthor when author is "Unknown");
        -- show provenance-unknown placeholder if both are empty.
        local origAuthor = seqData.originalAuthor or ""
        local fallbackAuthor = seqData.author or ""
        local authorText
        if origAuthor ~= "" then
            authorText = origAuthor
        elseif fallbackAuthor ~= "" then
            authorText = fallbackAuthor
        else
            authorText = L["GEMS_PROVENANCE_UNKNOWN"]
        end
        -- E2-polish: SaveSequence reads this box back into the author
        -- field. Keep the undecorated value so the D3 source tag below
        -- never leaks into saved data.
        SE._authorBoxCleanText = authorText
        -- D3: provenance-source label on imported sequences. The disabled
        -- author box appends a short source tag; the OnEnter handler adds
        -- the full sentence from the detail field set here.
        SE._authorSourceDetail = nil
        local provSrc = seqData.provenanceSource
        if provSrc == "forge-import" then
            authorText = string.format("%s (%s)", authorText, L["GEMS_PROVENANCE_FORGE_IMPORT"])
            local forgeMeta = seqData.importMeta and seqData.importMeta.forge
            local attribution = (forgeMeta and forgeMeta.author) or origAuthor
            SE._authorSourceDetail = string.format(L["GEMS_PROVENANCE_FORGE_IMPORT_TOOLTIP"], attribution)
        elseif provSrc == "gse-legacy" then
            authorText = string.format("%s (%s)", authorText, L["GEMS_PROVENANCE_LEGACY_IMPORT"])
            SE._authorSourceDetail = string.format(L["GEMS_PROVENANCE_LEGACY_IMPORT_TOOLTIP"], origAuthor)
        end
        SE.metaAuthorBox:SetText(authorText)
    end
    -- v2.1.6: swap to the author dropdown when originalAuthor is empty
    -- (brand-new sequence); keep the locked EditBox visible otherwise.
    if SE.RefreshAuthorPicker then
        SE:RefreshAuthorPicker(seqData)
    end
    -- v2.1.0 Phase C polish: render fork lineage. Multi-hop chain is
    -- shown as "P1 <- P2 <- ... <- root" (truncated at 4 with "(+N more)").
    -- Single-parent fork (legacy / pre-polish) renders the original-author
    -- on its own. Non-forks hide the row entirely.
    if SE.metaForkedFromBox then
        local chain = seqData.forkedFromChain
        local ff = seqData.forkedFrom
        if chain and #chain > 0 then
            local parts = {}
            for i = 1, math.min(#chain, 4) do
                local ancestor = chain[i]
                parts[#parts + 1] = (ancestor and ancestor.originalAuthor) or "?"
            end
            if #chain > 4 then
                parts[#parts + 1] = string.format(L["GEMS_AUTHOR_FORKED_FROM_CHAIN_TRUNCATE"], #chain - 4)
            end
            SE.metaForkedFromBox:SetText(table.concat(parts, " <- "))
            SE.metaForkedFromBox:Show()
        elseif ff and ff.originalAuthor and ff.originalAuthor ~= "" then
            local label = ff.originalAuthor
            if ff.originalCreatedAt and ff.originalCreatedAt > 0 then
                label = string.format(
                    L["GEMS_AUTHOR_FORKED_FROM_VALUE"],
                    ff.originalAuthor,
                    date("%Y-%m-%d", ff.originalCreatedAt)
                )
            end
            SE.metaForkedFromBox:SetText(label)
            SE.metaForkedFromBox:Show()
        else
            SE.metaForkedFromBox:SetText("")
            SE.metaForkedFromBox:Hide()
        end
    end
    if SE.metaLastModifiedBox then
        local lm = seqData.lastModifier or ""
        local lmAt = seqData.lastModifiedAt or 0
        if lm == "" and lmAt == 0 then
            SE.metaLastModifiedBox:SetText("")
        else
            SE.metaLastModifiedBox:SetText(
                string.format(L["GEMS_AUTHOR_LAST_MODIFIED_VALUE"], lm, date("%Y-%m-%d", lmAt))
            )
        end
    end
    -- v2.1.0 Phase D: populate the privacy-mode dropdown from the
    -- per-sequence override, falling back to "public" for legacy sequences
    -- without a privacyMode field.
    if SE.metaPrivacyDropdown then
        local mode = seqData.privacyMode or "public"
        SE.metaPrivacyDropdown._value = mode
        local labelMap = {
            public = L["GEMS_PRIVACY_MODE_PUBLIC"],
            pseudonymous = L["GEMS_PRIVACY_MODE_PSEUDONYMOUS"],
            private = L["GEMS_PRIVACY_MODE_PRIVATE"],
        }
        UIDropDownMenu_SetText(SE.metaPrivacyDropdown, labelMap[mode] or mode)
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
    if SE.metaChangelogBox then
        SE.metaChangelogBox:SetText(seqData.changelog or "")
    end
    if SE.metaTalentBox then
        SE.metaTalentBox:SetText(seqData.talentString or "")
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

    -- Phase 4 item 22 Phase 2: populate per-sequence sound cue dropdowns.
    -- Missing seqData.soundCues collapses every dropdown to "(global default)";
    -- present entries take precedence and are reflected by setting the dropdown
    -- visible text to the LSM key.
    do
        local cueDDList = {
            { dd = SE.metaCueErrorDD, key = "error" },
            { dd = SE.metaCueSuccessDD, key = "success" },
            { dd = SE.metaCueInfoDD, key = "info" },
            { dd = SE.metaCueStepDD, key = "stepComplete" },
        }
        local seqCues = seqData.soundCues
        for _, cueDD in ipairs(cueDDList) do
            if cueDD.dd then
                local val = (seqCues and seqCues[cueDD.key]) or ""
                cueDD.dd._value = val
                if val == "" then
                    UIDropDownMenu_SetText(cueDD.dd, L["GEMS_EDITOR_SEQ_SOUND_NONE"])
                else
                    UIDropDownMenu_SetText(cueDD.dd, val)
                end
            end
        end
    end

    -- Populate click rate info from TempoAdvisor
    if SE.crElements then
        local TA = GRIPEMS.TempoAdvisor
        local rec = TA and TA:GetRecommendation(name)
        if rec then
            local cps = rec.recommendedMs and rec.recommendedMs > 0 and math.floor(1000 / rec.recommendedMs) or 0
            SE.crRecValue:SetText(string.format("%d ms (%d/sec)", rec.recommendedMs or 0, cps))
            SE.crComplexValue:SetText(rec.complexity or "?")
            local eff = GRIPEMS.TempoAdvisor and GRIPEMS.TempoAdvisor:GetEffectiveConfidence(rec)
            SE.crConfValue:SetText(eff or "?")
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
    SE:RefreshChannelHoldControl(ver)
    if SE.timerBox then
        SE.timerBox:SetText(tostring(ver and ver.resetTimer or 0))
    end
    if SE.repeatBox then
        SE.repeatBox:SetText(tostring(ver and ver.repeatCount or 1))
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
        GRIPEMS.StepListView:LoadSteps(
            ver and ver.steps or {},
            ver and ver.actions or nil,
            ver and ver.stepLabels or nil
        )
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

    -- Load data into VariantsTab
    if GRIPEMS.VariantsTab then
        GRIPEMS.VariantsTab:LoadSequence(name)
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

    -- Refresh disabled-state badge + toggle button label
    SE:UpdateDisabledState()

    -- v2.1.0 Phase C: Fork button visibility (foreign-author sequences only)
    SE:UpdateForkButton()

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
    SE:RefreshChannelHoldControl(ver)
    if SE.timerBox then
        SE.timerBox:SetText(tostring(ver and ver.resetTimer or 0))
    end
    if SE.repeatBox then
        SE.repeatBox:SetText(tostring(ver and ver.repeatCount or 1))
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
        GRIPEMS.StepListView:LoadSteps(
            ver and ver.steps or {},
            ver and ver.actions or nil,
            ver and ver.stepLabels or nil
        )
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
    -- type(), not truthiness: a scalar .versions raises "attempt to get length
    -- of field 'versions'" on the length operator, and a string fabricates a
    -- bound from its character length -- which would let an out-of-range switch
    -- through the range check below. 1 is the absent-field answer already.
    local maxVer = (type(seqData.versions) == "table" and #seqData.versions) or 1
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
        SE._authorSourceDetail = nil
        SE._authorBoxCleanText = nil
        SE.metaAuthorBox:SetText("")
    end
    -- v2.1.6: reset the author dropdown alongside the EditBox. The metadata
    -- section is hidden on clear, so visibility doesn't matter here -- but
    -- the next LoadSequence call gets a clean slate.
    if SE.metaAuthorDropdown then
        SE.metaAuthorDropdown._value = ""
        SE.metaAuthorDropdown._options = {}
        UIDropDownMenu_SetText(SE.metaAuthorDropdown, "")
        SE.metaAuthorDropdown:Hide()
    end
    if SE.metaForkedFromBox then
        SE.metaForkedFromBox:SetText("")
        SE.metaForkedFromBox:Hide()
    end
    if SE.metaLastModifiedBox then
        SE.metaLastModifiedBox:SetText("")
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
    if SE.metaChangelogBox then
        SE.metaChangelogBox:SetText("")
    end
    if SE.metaTalentBox then
        SE.metaTalentBox:SetText("")
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

    -- Phase 4 item 22 Phase 2: reset per-sequence sound cue dropdowns to
    -- "(global default)" when the editor has no sequence selected so the
    -- next loaded sequence starts with a clean slate.
    do
        local cueDDList = { SE.metaCueErrorDD, SE.metaCueSuccessDD, SE.metaCueInfoDD, SE.metaCueStepDD }
        for _, dd in ipairs(cueDDList) do
            if dd then
                dd._value = ""
                UIDropDownMenu_SetText(dd, L["GEMS_EDITOR_SEQ_SOUND_NONE"])
            end
        end
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
    SE:RefreshChannelHoldControl(nil)
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

    if GRIPEMS.VariantsTab then
        GRIPEMS.VariantsTab:Clear()
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
        SE:UpdateDisabledState()
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

-- Refresh the version-bar Live badge when the context changes (e.g. zoning)
-- while the editor is open. Display-only; reads Engine:GetActiveVersionIndex
-- via SE:RefreshVersionBar and never touches the engine or secure path.
function SE:OnContextChangedEditor(event, newContext, oldContext)
    if not SE.container or not SE.container:IsVisible() then
        return
    end
    SE:RefreshVersionBar()
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
        UI:RegisterLargeTarget(closeBtn)
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
        autoBtn:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6 - UI:GetRowGap())
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

            -- icon is signature-canon content and entry.data aliases the SV
            -- row -- queue the debounced re-sign like the quick persists,
            -- but only when the canon actually changes (autoIcon is not
            -- signed; nil icon canonicalizes to the question mark).
            local iconChanged = entry.data.icon ~= nil
            entry.data.autoIcon = true
            entry.data.icon = nil
            SE.isDirty = true
            SE:UpdateSaveButtons()
            if iconChanged then
                SE:_QueueQuickResign(SE.currentSequence)
            end

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
        scrollFrame:SetPoint("TOPLEFT", autoBtn, "BOTTOMLEFT", 0, -6 - UI:GetRowGap())
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

                local iconChanged = entry.data.icon ~= self._iconID
                entry.data.icon = self._iconID
                entry.data.autoIcon = false
                SE.isDirty = true
                SE:UpdateSaveButtons()
                if iconChanged then
                    SE:_QueueQuickResign(SE.currentSequence)
                end

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

-- Build a preview-only version table whose steps / compiledLabels reflect the
-- LIVE working tree (so the strip matches what the runtime will fire), falling
-- back to ver for every other field via __index. Never writes back to ver, so
-- the engine's stored ver.steps is untouched. The importBakedSteps + actions
-- guard mirrors Engine:ActivateSequence.
function SE:_PreviewVersion(ver)
    local SLV = GRIPEMS.StepListView
    local steps, labels = ver.steps, ver.compiledLabels
    if SLV then
        if not ver.importBakedSteps and SLV.workingActions and #SLV.workingActions > 0 then
            local AC = GRIPEMS.ActionCompiler
            if AC and AC.CompileActions then
                steps, labels = AC.CompileActions(SLV.workingActions, GRIPEMS.Engine, ver)
            end
        elseif SLV.GetWorkingSteps then
            local ws = SLV:GetWorkingSteps()
            if ws and #ws > 0 then
                steps, labels = ws, nil
            end
        end
    end
    return setmetatable({ steps = steps or {}, compiledLabels = labels }, { __index = ver })
end

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
    local previewVer = ver and SE:_PreviewVersion(ver) or nil

    -- Show for ALL step functions with steps
    if not previewVer or type(previewVer.steps) ~= "table" or #previewVer.steps == 0 then
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
        if SE._RecomputeRightPanelScrollChild then
            SE:_RecomputeRightPanelScrollChild()
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
        SE:UpdatePreviewIcons(previewVer)
    elseif mode == D().PREVIEW_MODE_COMPILED then
        SE:UpdatePreviewCompiled(previewVer)
    else
        SE:UpdatePreviewText(previewVer)
    end
    if SE._RecomputeRightPanelScrollChild then
        SE:_RecomputeRightPanelScrollChild()
    end
end

--- Icon strip preview mode. Shows spell icons for simulated keypresses.
function SE:UpdatePreviewIcons(ver)
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
    local simulated = GRIPEMS.Engine:SimulateSteps(ver.steps, ver.stepFunction, defaults.PREVIEW_MAX_STEPS)
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
        elseif status == defaults.SPELL_STATUS_CONTEXTUAL then
            btn.tintOverlay:SetVertexColor(0, 0.7, 1)
            btn.tintOverlay:SetAlpha(0.18)
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
        local SC = GRIPEMS.SpellCache
        local stepStr = (SC and SC.StepToString) and SC:StepToString(stepText) or tostring(stepText)
        resolvedSteps[i] = GRIPEMS.Engine:SubstituteVariables(stepStr)
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
    if C_Timer and C_Timer.After then
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
    if C_Timer and C_Timer.After then
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
    -- type(), not truthiness -- same failure as SwitchToVersion above, on the
    -- same field reached through entry.data instead of a seqData local: a
    -- scalar raises on the length operator, a string fabricates a total that
    -- would then be formatted into the version-bar label.
    local total = (type(entry.data.versions) == "table" and #entry.data.versions) or 1
    local isDefault = SE.activeVersionIndex == (entry.data.defaultVersion or 1)

    -- Update dropdown button text
    if SE.versionBtn and SE.versionBtn.label then
        local txt = string.format(L["GEMS_VERSION_OF"], SE.activeVersionIndex, total)
        if isDefault then
            txt = txt .. L["GEMS_VERSION_DEFAULT_MARKER"]
        end
        SE.versionBtn.label:SetText(txt)
    end

    -- Read-only LIVE badge: which version the keybind actually fires right now,
    -- resolved through the existing accessor (no second resolver). When a pin is
    -- set it shows the pinned-state text plus an "applies after combat" note
    -- while the secure reload is still deferred (OOCQueue:IsRestricted()).
    if SE.versionLiveBadge then
        local E = GRIPEMS.Engine
        local liveIdx = E and E.GetActiveVersionIndex and E:GetActiveVersionIndex(entry.data)
        if liveIdx then
            local txt
            -- Only label "(pinned)" when the pin actually resolves (in range),
            -- mirroring the resolver's own fall-through: an out-of-range pin is
            -- ignored by GetActiveVersion, so the badge must not claim it.
            local pin = tonumber(entry.data.pinnedVersion) or entry.data.pinnedVersion
            if pin and entry.data.versions[pin] then
                txt = string.format(L["GEMS_VERSION_PINNED_BADGE"], liveIdx)
                if GRIPEMS.OOCQueue and GRIPEMS.OOCQueue:IsRestricted() then
                    txt = txt .. L["GEMS_VERSION_PIN_COMBAT_NOTE"]
                end
            else
                txt = string.format(L["GEMS_VERSION_LIVE_BADGE"], liveIdx)
            end
            SE.versionLiveBadge:SetText(txt)
            SE.versionLiveBadge:Show()
            if SE.versionLiveBtn then
                SE.versionLiveBtn:Show()
            end
        else
            SE.versionLiveBadge:Hide()
            if SE.versionLiveBtn then
                SE.versionLiveBtn:Hide()
            end
        end
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

---------------------------------------------------------------------------
-- Simplified Mode (Phase S2)
---------------------------------------------------------------------------

-- Tabs that remain reachable when simplifiedMode=true. Driven by the tab
-- _isActive flag so the existing Tab/LEFT/RIGHT/numbered-jump cycle code
-- transparently skips the hidden tabs without duplicated cycle logic.
local _SIMPLIFIED_TABS = { Steps = true, Keybind = true }

-- Module-level overlay names that Simplified Mode force-hides. Looked up
-- dynamically on each pass; missing modules are skipped silently.
local _SIMPLIFIED_OVERLAY_KEYS = {
    "FloatingMenu",
    "SpellPicker",
    "PopupEditor",
    "RepairFrame",
    "ComparisonFrame",
}

-- Forward declaration so _ensureSimplifiedBar's PLAYER_REGEN_ENABLED
-- closure can call _wireRunToSequence (defined below). The real body is
-- assigned later via `function _wireRunToSequence() ... end`.
local _wireRunToSequence

-- Lazily build the three-button Simplified Mode action column
-- (Run / Unlock / Close). Anchored TOPRIGHT inside the editor container.
-- Run is a SecureActionButtonTemplate that forwards clicks to the active
-- sequence's registered SAB (engine.sequences[name].button) via click-
-- attribute chaining, so the hardware-event requirement is preserved.
local function _ensureSimplifiedBar()
    if SE.simplifiedActionBar then
        return SE.simplifiedActionBar
    end
    -- SAFETY GATE (Plugin API Phase 1b, design risk #1): parent the Simplified
    -- bar -- and its SecureActionButtonTemplate Run button -- to the
    -- GRIPEMS_MainFrame root, never to SE.container / SE.rightPanel. Those can
    -- be a layout host in a modern layout, and no secure button may descend
    -- from a reparentable host. The root is never a host and no provider
    -- reparents it, so the hardware-event Run path stays valid in every layout.
    local parent = _G.GRIPEMS_MainFrame
    if not parent then
        return nil
    end
    local C = UI.Colors
    local bar = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    bar:SetSize(60, 60 * 3 + 16)
    -- Offset below the title bar so the bar does not overlap the title-bar
    -- buttons now that it anchors to the frame root instead of the rightPanel.
    bar:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -8, -(D().TITLE_BAR_HEIGHT + 8))
    bar:SetFrameStrata("HIGH")
    -- GRIPEMS_MainFrame is itself strata HIGH (UI/MainFrame.lua), so HIGH
    -- here is a same-strata no-op and the bar -- a direct child at parent
    -- level + 1 -- drew UNDER the right panel's deeper subtree (scroll
    -- frames, scrollbars). Only the few px right of the panel edge
    -- rendered; report + screenshot BeastBlood1885, grip-ems chat
    -- 2026-07-10, EMS 2.3.5. Raise the frame LEVEL well above the sibling
    -- panel subtrees; the three child buttons ride along.
    bar:SetFrameLevel(parent:GetFrameLevel() + 100)
    UI:ApplyBackdrop(bar, UI.Backdrops.panel, C.bgPanel, C.border)
    bar:Hide()

    local function makeBtn(template, tooltip, order)
        local btn = CreateFrame("Button", nil, bar, template)
        btn:SetSize(60, 60)
        btn:SetPoint("TOP", bar, "TOP", 0, -(order - 1) * (60 + 4) - 4)
        UI:ApplyBackdrop(btn, UI.Backdrops.panel, C.bgButton, C.border)
        UI:RegisterLargeTarget(btn)
        local lbl = btn:CreateFontString(nil, "OVERLAY")
        UI:SetFont(lbl, 11)
        lbl:SetPoint("CENTER")
        btn.label = lbl
        btn:SetScript("OnEnter", function(self)
            self:SetBackdropColor(C.bgRowHover:GetRGBA())
            self:SetBackdropBorderColor(C.borderFocus:GetRGBA())
            UI:ShowTooltip(self, tooltip)
        end)
        btn:SetScript("OnLeave", function(self)
            self:SetBackdropColor(C.bgButton:GetRGBA())
            self:SetBackdropBorderColor(C.border:GetRGBA())
            UI:HideTooltip()
        end)
        return btn
    end

    local runBtn = makeBtn("SecureActionButtonTemplate,BackdropTemplate", L["ACCESS_SIMPLIFIED_RUN_BUTTON"], 1)
    runBtn:RegisterForClicks("AnyUp", "AnyDown")
    runBtn.label:SetText(L["ACCESS_SIMPLIFIED_RUN_BUTTON"])
    runBtn:SetScript("PostClick", function(self)
        if self:GetAttribute("type") ~= "click" then
            return
        end
        if GRIPEMS.Speech and GRIPEMS.Speech.Announce and SE.currentSequence then
            GRIPEMS.Speech:Announce(string.format(L["ACCESS_ANNOUNCE_SIMPLIFIED_RUN"], SE.currentSequence))
        end
    end)
    bar.runBtn = runBtn

    local unlockBtn = makeBtn("BackdropTemplate", L["ACCESS_SIMPLIFIED_UNLOCK_BUTTON"], 2)
    unlockBtn.label:SetText(L["ACCESS_SIMPLIFIED_UNLOCK_BUTTON"])
    unlockBtn:SetScript("OnClick", function()
        SE._simplifiedUnlocked = not SE._simplifiedUnlocked
        SE:RelayoutSimplified()
        if GRIPEMS.Speech and GRIPEMS.Speech.Announce then
            GRIPEMS.Speech:Announce(
                SE._simplifiedUnlocked and L["ACCESS_ANNOUNCE_SIMPLIFIED_UNLOCKED"]
                    or L["ACCESS_ANNOUNCE_SIMPLIFIED_LOCKED"]
            )
        end
        local KBT = GRIPEMS.KeybindTab
        if KBT and KBT.RefreshDisplay then
            pcall(KBT.RefreshDisplay, KBT)
        end
    end)
    bar.unlockBtn = unlockBtn

    local closeBtn = makeBtn("BackdropTemplate", L["ACCESS_HELP_CLOSE"], 3)
    closeBtn.label:SetText(L["ACCESS_HELP_CLOSE"])
    closeBtn:SetScript("OnClick", function()
        local mf = _G.GRIPEMS_MainFrame
        if mf then
            if GRIPEMS.Speech and GRIPEMS.Speech.Announce then
                GRIPEMS.Speech:Announce(L["ACCESS_ANNOUNCE_SIMPLIFIED_CLOSED"])
            end
            mf:Hide()
        end
    end)
    bar.closeBtn = closeBtn

    SE.simplifiedActionBar = bar

    -- Combat-safe Run wire-up: _wireRunToSequence is a no-op while in
    -- combat, so re-fire it right after PLAYER_REGEN_ENABLED so the Run
    -- button becomes active as soon as combat ends.
    if not bar._regenFrame then
        bar._regenFrame = CreateFrame("Frame")
        bar._regenFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
        bar._regenFrame:SetScript("OnEvent", function()
            local a = GRIPEMS.Settings
                and GRIPEMS.Settings.db
                and GRIPEMS.Settings.db.profile
                and GRIPEMS.Settings.db.profile.accessibility
            if a and a.simplifiedMode then
                _wireRunToSequence()
            end
        end)
    end

    return bar
end

-- Point the Run button's SecureActionButton click-chain at the active
-- sequence's engine SAB, so hardware clicks on Run fire that sequence.
-- Assigned into the forward-declared local so _ensureSimplifiedBar's
-- PLAYER_REGEN_ENABLED closure can call it.
function _wireRunToSequence()
    local bar = SE.simplifiedActionBar
    if not bar or not bar.runBtn then
        return
    end
    if InCombatLockdown() then
        return
    end
    local Engine = GRIPEMS.Engine
    local name = SE.currentSequence
    local entry = Engine and Engine.sequences and name and Engine.sequences[name]
    if entry and entry.button then
        bar.runBtn:SetAttribute("type", "click")
        bar.runBtn:SetAttribute("clickbutton", entry.button)
    else
        bar.runBtn:SetAttribute("type", nil)
        bar.runBtn:SetAttribute("clickbutton", nil)
    end
end

local function _hideOverlays()
    for _, key in ipairs(_SIMPLIFIED_OVERLAY_KEYS) do
        local overlay = GRIPEMS[key]
        if overlay then
            if type(overlay.Hide) == "function" then
                pcall(overlay.Hide, overlay)
            elseif overlay.frame and overlay.frame.Hide then
                pcall(overlay.frame.Hide, overlay.frame)
            end
        end
    end
end

--- Lazily create and show the muted one-line explanation that sits where the
--- central editor was while Simplified Mode is locked. Anchored to the
--- (hidden) editScrollFrame rect; parented to the editor's parent so tab
--- switching hides it together with the rest of the Steps content.
function SE:_ShowSimplifiedLockedHint(SLV)
    if not SE._simplifiedLockedHint then
        local anchor = SLV and SLV.editScrollFrame
        local host = anchor and anchor.GetParent and anchor:GetParent()
        if not host then
            return
        end
        local fs = host:CreateFontString(nil, "OVERLAY")
        UI:SetFont(fs, 10)
        fs:SetPoint("TOPLEFT", anchor, "TOPLEFT", 4, -4)
        fs:SetPoint("RIGHT", anchor, "RIGHT", -4, 0)
        fs:SetJustifyH("LEFT")
        fs:SetWordWrap(true)
        fs:SetText(L["GEMS_UI_SIMPLIFIED_LOCKED_HINT"])
        fs:SetTextColor(UI.Colors.textMuted:GetRGBA())
        SE._simplifiedLockedHint = fs
    end
    SE._simplifiedLockedHint:Show()
end

--- Hide the locked-edit hint if it has been created.
function SE:_HideSimplifiedLockedHint()
    if SE._simplifiedLockedHint then
        SE._simplifiedLockedHint:Hide()
    end
end

--- Apply or undo the Simplified Mode layout collapse.
--- Called by /gems simplified, by the Settings panel toggle, at PLAYER_LOGIN
--- when simplifiedMode=true, and on profile change. Idempotent: safe to call
--- repeatedly. Combat-safe: secure-attribute writes are skipped while
--- InCombatLockdown() is true; a follow-up call after PLAYER_REGEN_ENABLED
--- completes the wire-up.
function SE:RelayoutSimplified()
    local acc = GRIPEMS.Settings
        and GRIPEMS.Settings.db
        and GRIPEMS.Settings.db.profile
        and GRIPEMS.Settings.db.profile.accessibility
    local on = acc and acc.simplifiedMode == true or false

    -- Tab filter: drive the existing cycle logic via _isActive.
    if SE.tabButtons then
        for name, tab in pairs(SE.tabButtons) do
            if on then
                tab._isActive = _SIMPLIFIED_TABS[name] == true
            else
                tab._isActive = true
            end
        end
    end

    if on then
        -- If a restricted tab is currently active, rebound to Steps.
        if SE.activeTab and not _SIMPLIFIED_TABS[SE.activeTab] then
            SE:SwitchTab("Steps")
        else
            SE:UpdateTabButtons()
        end

        -- Read-only per-step rows (hide per-row edit / drag / context-menu).
        local SLV = GRIPEMS.StepListView
        if SLV and SLV.SetAllRowsReadOnly then
            pcall(SLV.SetAllRowsReadOnly, SLV, true)
        end

        -- Overlay hides (FloatingMenu, SpellPicker, PopupEditor, RepairFrame,
        -- ComparisonFrame).
        _hideOverlays()

        -- Title bar: single 56x56 Close button (hide minimize / settings).
        local MF = GRIPEMS.UI and GRIPEMS.UI.ApplySimplifiedTitleBar
        if MF then
            pcall(GRIPEMS.UI.ApplySimplifiedTitleBar, GRIPEMS.UI, true)
        end

        -- Show the 3-button action column (Run / Unlock / Close).
        local bar = _ensureSimplifiedBar()
        if bar then
            bar:Show()
            _wireRunToSequence()
        end

        -- Hide the standard StepListView action bar (9+ buttons).
        if SLV and SLV.actionBar and SE.activeTab == "Steps" then
            SLV.actionBar:Hide()
        end

        -- Hide the central editor (ScrollFrame container + scrollbar) unless the session has unlocked editing.
        -- Phase E shipped a ScrollFrame wrap around editBox; flipping editBox alone leaves the bordered
        -- container + always-visible scrollbar floating. Toggle both editScrollFrame and editScrollBar.
        -- While hidden, show the locked-edit hint in the editor's place so the
        -- blank region explains itself; clear it when the session is unlocked.
        if SLV and not SE._simplifiedUnlocked then
            if SLV.editScrollFrame and SLV.editScrollFrame.Hide then
                SLV.editScrollFrame:Hide()
            end
            if SLV.editScrollBar and SLV.editScrollBar.Hide then
                SLV.editScrollBar:Hide()
            end
            SE:_ShowSimplifiedLockedHint(SLV)
        elseif SLV then
            SE:_HideSimplifiedLockedHint()
            -- Unlock while staying in Simplified Mode: re-run the edit-area
            -- refresh so the editor reopens for the current selection without
            -- waiting for the next row click.
            if SLV.UpdateEditArea then
                pcall(SLV.UpdateEditArea, SLV)
            end
        end
    else
        -- Restore: all tabs active again.
        SE:UpdateTabButtons()

        local SLV = GRIPEMS.StepListView
        if SLV and SLV.SetAllRowsReadOnly then
            pcall(SLV.SetAllRowsReadOnly, SLV, false)
        end

        -- Restore the central editor (ScrollFrame container + scrollbar) on leave.
        if SLV then
            if SLV.editScrollFrame and SLV.editScrollFrame.Show then
                SLV.editScrollFrame:Show()
            end
            if SLV.editScrollBar and SLV.editScrollBar.Show then
                SLV.editScrollBar:Show()
            end
        end
        SE:_HideSimplifiedLockedHint()

        if GRIPEMS.UI and GRIPEMS.UI.ApplySimplifiedTitleBar then
            pcall(GRIPEMS.UI.ApplySimplifiedTitleBar, GRIPEMS.UI, false)
        end

        if SE.simplifiedActionBar then
            SE.simplifiedActionBar:Hide()
            if not InCombatLockdown() and SE.simplifiedActionBar.runBtn then
                SE.simplifiedActionBar.runBtn:SetAttribute("type", nil)
                SE.simplifiedActionBar.runBtn:SetAttribute("clickbutton", nil)
            end
        end

        SE._simplifiedUnlocked = false
        SE:UpdateTabContent()
    end
end
