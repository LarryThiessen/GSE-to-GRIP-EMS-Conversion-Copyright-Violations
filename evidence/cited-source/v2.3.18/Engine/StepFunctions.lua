-- GRIP-EMS: StepFunctions
-- Created: 2026-03-18
-- Updated: 2026-06-24
-- Patch: 12.0.7.68275 Midnight (Retail LIVE)

-- GRIP-EMS: Step Functions
-- Registry of step advancement strategies and WrapScript click body builders

local ADDON_NAME, GRIPEMS = ...
local L = LibStub("AceLocale-3.0"):GetLocale("GRIP-EMS", true)
local D = GRIPEMS.Defaults

-- StepFunctions module: defines how the sequencer picks the next step on each
-- button press. Each step function provides a BuildClickBody() method that
-- returns a single string of Lua code for the WrapScript OnClick body. This runs
-- in the restricted environment during combat and has access to the `steps`
-- table (array of newtable() attribute tables) and `numSteps` variable set
-- via :Execute() on the button.
--
-- Each step's attribute table contains key-value pairs like:
--   steps[1]["type"] = "macro"
--   steps[1]["macrotext"] = "/say Step 1"
-- The click body iterates the current step's attributes with pairs() and
-- calls self:SetAttribute(k, v) for each one, clearing conflicting attributes
-- (macrotext vs macro, clearing unit) to avoid stale state.
GRIPEMS.StepFunctions = {}
local SF = GRIPEMS.StepFunctions

-- Plugin step-function registry (Plugin API Phase 2c). id -> normalized
-- entry. Declared here so SF:Get / SF:GetNames (below) can resolve a
-- registered id; the registrar + expander run at end of file.
local registered = {}

-- Sequential: cycles 1, 2, 3, ..., N, 1, 2, ... (round-robin)
SF.Sequential = {
    name = D.STEP_SEQUENTIAL,
    description = L["GEMS_STEPFUNC_SEQUENTIAL_DESC"],
    BuildClickBody = function()
        local body = [=[
            local btn = button
            if self:GetAttribute("freezeArmed") == "1" then
                local fm = self:GetAttribute("freezeMod")
                if (fm == "shift" and IsShiftKeyDown())
                   or (fm == "ctrl" and IsControlKeyDown())
                   or (fm == "alt" and IsAltKeyDown()) then
                    self:SetAttribute("macro", nil)
                    self:SetAttribute("unit", nil)
                    self:SetAttribute("macrotext", "")
                    self:CallMethod("PostClick")
                    return
                end
            end
            local drv = self:GetFrameRef("emsdriver")
            local skyriding = false
            if drv then
                local drvstate = drv:GetAttribute("emsstate")
                skyriding = (drvstate == "skyride") or (drv:GetAttribute("skyrideforce") == "1")
            end
            if skyriding then
                local verdict = SecureCmdOptionParse("[@target,harm,nodead] seq; pass")
                if verdict ~= "seq" then
                    self:SetAttribute("macro", nil)
                    self:SetAttribute("unit", nil)
                    self:SetAttribute("macrotext", self:GetAttribute("skyridepass") or "")
                    return
                end
            end
            local modReset = false
            if btn == "LeftButton" and self:GetAttribute("resetMod_LeftButton") then modReset = true end
            if btn == "RightButton" and self:GetAttribute("resetMod_RightButton") then modReset = true end
            if btn == "MiddleButton" and self:GetAttribute("resetMod_MiddleButton") then modReset = true end
            if btn == "Button4" and self:GetAttribute("resetMod_Button4") then modReset = true end
            if btn == "Button5" and self:GetAttribute("resetMod_Button5") then modReset = true end
            if IsLeftAltKeyDown() and self:GetAttribute("resetMod_LeftAlt") then modReset = true end
            if IsRightAltKeyDown() and self:GetAttribute("resetMod_RightAlt") then modReset = true end
            if IsAltKeyDown() and self:GetAttribute("resetMod_Alt") then modReset = true end
            if IsLeftControlKeyDown() and self:GetAttribute("resetMod_LeftControl") then modReset = true end
            if IsRightControlKeyDown() and self:GetAttribute("resetMod_RightControl") then modReset = true end
            if IsControlKeyDown() and self:GetAttribute("resetMod_Control") then modReset = true end
            if IsLeftShiftKeyDown() and self:GetAttribute("resetMod_LeftShift") then modReset = true end
            if IsRightShiftKeyDown() and self:GetAttribute("resetMod_RightShift") then modReset = true end
            if IsShiftKeyDown() and self:GetAttribute("resetMod_Shift") then modReset = true end
            if (IsAltKeyDown() or IsControlKeyDown() or IsShiftKeyDown()) and self:GetAttribute("resetMod_AnyMod") then modReset = true end
            if modReset then
                self:SetAttribute('_shouldReset', '1')
            end
            local step = self:GetAttribute('step') or 1
            step = tonumber(step)
            local shouldReset = self:GetAttribute('_shouldReset')
            if shouldReset == "1" then
                step = 1
                self:SetAttribute('_shouldReset', '0')
            end
            local numS = math.max(numSteps or 1, 1)
            local stepData = steps and steps[step]
            if stepData then
                for k, v in pairs(stepData) do
                    if k == "macrotext" then
                        self:SetAttribute("macro", nil)
                        self:SetAttribute("unit", nil)
                    elseif k == "macro" then
                        self:SetAttribute("macrotext", nil)
                        self:SetAttribute("unit", nil)
                    end
                    self:SetAttribute(k, v)
                end
            end
            if skyriding then
                local mt = self:GetAttribute("macrotext")
                if mt and mt ~= "" then
                    local prefix = "/dismount\n"
                    if drv:GetAttribute("autounshift") == "1" then
                        prefix = prefix .. "/cancelform\n"
                    end
                    if #mt + #prefix <= 255 then
                        self:SetAttribute("macrotext", prefix .. mt)
                    end
                end
            end
            step = step % numS + 1
            self:SetAttribute('step', step)
            self:CallMethod('UpdateIcon')
            self:CallMethod('PostClick')
        ]=]
        return body
    end,
}

-- Random: picks a random step each press
SF.Random = {
    name = D.STEP_RANDOM,
    description = L["GEMS_STEPFUNC_RANDOM_DESC"],
    BuildClickBody = function()
        local body = [=[
            local btn = button
            if self:GetAttribute("freezeArmed") == "1" then
                local fm = self:GetAttribute("freezeMod")
                if (fm == "shift" and IsShiftKeyDown())
                   or (fm == "ctrl" and IsControlKeyDown())
                   or (fm == "alt" and IsAltKeyDown()) then
                    self:SetAttribute("macro", nil)
                    self:SetAttribute("unit", nil)
                    self:SetAttribute("macrotext", "")
                    self:CallMethod("PostClick")
                    return
                end
            end
            local drv = self:GetFrameRef("emsdriver")
            local skyriding = false
            if drv then
                local drvstate = drv:GetAttribute("emsstate")
                skyriding = (drvstate == "skyride") or (drv:GetAttribute("skyrideforce") == "1")
            end
            if skyriding then
                local verdict = SecureCmdOptionParse("[@target,harm,nodead] seq; pass")
                if verdict ~= "seq" then
                    self:SetAttribute("macro", nil)
                    self:SetAttribute("unit", nil)
                    self:SetAttribute("macrotext", self:GetAttribute("skyridepass") or "")
                    return
                end
            end
            local modReset = false
            if btn == "LeftButton" and self:GetAttribute("resetMod_LeftButton") then modReset = true end
            if btn == "RightButton" and self:GetAttribute("resetMod_RightButton") then modReset = true end
            if btn == "MiddleButton" and self:GetAttribute("resetMod_MiddleButton") then modReset = true end
            if btn == "Button4" and self:GetAttribute("resetMod_Button4") then modReset = true end
            if btn == "Button5" and self:GetAttribute("resetMod_Button5") then modReset = true end
            if IsLeftAltKeyDown() and self:GetAttribute("resetMod_LeftAlt") then modReset = true end
            if IsRightAltKeyDown() and self:GetAttribute("resetMod_RightAlt") then modReset = true end
            if IsAltKeyDown() and self:GetAttribute("resetMod_Alt") then modReset = true end
            if IsLeftControlKeyDown() and self:GetAttribute("resetMod_LeftControl") then modReset = true end
            if IsRightControlKeyDown() and self:GetAttribute("resetMod_RightControl") then modReset = true end
            if IsControlKeyDown() and self:GetAttribute("resetMod_Control") then modReset = true end
            if IsLeftShiftKeyDown() and self:GetAttribute("resetMod_LeftShift") then modReset = true end
            if IsRightShiftKeyDown() and self:GetAttribute("resetMod_RightShift") then modReset = true end
            if IsShiftKeyDown() and self:GetAttribute("resetMod_Shift") then modReset = true end
            if (IsAltKeyDown() or IsControlKeyDown() or IsShiftKeyDown()) and self:GetAttribute("resetMod_AnyMod") then modReset = true end
            if modReset then
                self:SetAttribute('_shouldReset', '1')
            end
            local shouldReset = self:GetAttribute('_shouldReset')
            local numS = math.max(numSteps or 1, 1)
            local step
            if shouldReset == "1" then
                step = 1
                self:SetAttribute('_shouldReset', '0')
            else
                step = random(1, numS)
            end
            self:SetAttribute('step', step)
            local stepData = steps and steps[step]
            if stepData then
                for k, v in pairs(stepData) do
                    if k == "macrotext" then
                        self:SetAttribute("macro", nil)
                        self:SetAttribute("unit", nil)
                    elseif k == "macro" then
                        self:SetAttribute("macrotext", nil)
                        self:SetAttribute("unit", nil)
                    end
                    self:SetAttribute(k, v)
                end
            end
            if skyriding then
                local mt = self:GetAttribute("macrotext")
                if mt and mt ~= "" then
                    local prefix = "/dismount\n"
                    if drv:GetAttribute("autounshift") == "1" then
                        prefix = prefix .. "/cancelform\n"
                    end
                    if #mt + #prefix <= 255 then
                        self:SetAttribute("macrotext", prefix .. mt)
                    end
                end
            end
            self:CallMethod('UpdateIcon')
            self:CallMethod('PostClick')
        ]=]
        return body
    end,
}

-- Priority: pre-expanded round-robin. Steps are expanded into N*(N+1)/2
-- entries where higher-priority steps appear more frequently. Uses the same
-- Sequential click body (round-robin cycling) over the expanded array.
SF.Priority = {
    name = D.STEP_PRIORITY,
    description = L["GEMS_STEPFUNC_PRIORITY_DESC"],
    BuildClickBody = SF.Sequential.BuildClickBody,
}

-- ReversePriority: inverted pre-expansion. Lower-priority (later) steps
-- appear more frequently. Same Sequential click body over the expanded array.
SF.ReversePriority = {
    name = D.STEP_REVERSE_PRIORITY,
    description = L["GEMS_STEPFUNC_REVERSEPRIORITY_DESC"],
    BuildClickBody = SF.Sequential.BuildClickBody,
}

--- Expand steps for Priority mode (weighted pre-expansion).
--- N original steps become N*(N+1)/2 flat entries. Step 1 appears N times,
--- step 2 appears N-1 times, ..., step N appears 1 time. Each expanded
--- entry contains the step text as macrotext (no keyPress wrapping).
--- The expanded array is cycled using the Sequential click body.
--- @param stepTexts table Array of variable-resolved macro text strings
--- @return table Array of attribute tables (one per expanded step)
function SF:ExpandPriority(stepTexts)
    if not stepTexts or #stepTexts == 0 then
        return { { type = D.ATTR_TYPE_MACRO, macrotext = "" } }
    end
    local expanded = {}
    for i = 1, #stepTexts do
        for j = 1, i do
            expanded[#expanded + 1] = {
                type = D.ATTR_TYPE_MACRO,
                macrotext = stepTexts[j],
            }
        end
    end
    return expanded
end

--- Expand steps for ReversePriority mode (inverted pre-expansion).
--- N original steps become N*(N+1)/2 flat entries. Step N appears N times,
--- step N-1 appears N-1 times, ..., step 1 appears 1 time.
--- @param stepTexts table Array of variable-resolved macro text strings
--- @return table Array of attribute tables (one per expanded step)
function SF:ExpandReversePriority(stepTexts)
    if not stepTexts or #stepTexts == 0 then
        return { { type = D.ATTR_TYPE_MACRO, macrotext = "" } }
    end
    local n = #stepTexts
    local expanded = {}
    for i = n, 1, -1 do
        for j = i, n do
            expanded[#expanded + 1] = {
                type = D.ATTR_TYPE_MACRO,
                macrotext = stepTexts[j],
            }
        end
    end
    return expanded
end

--- Validate that all steps are within the 255-char macrotext limit.
--- Accepts both raw string format (user/data input) and compiled attribute
--- table format (output from CompileSteps/ExpandPriority).
--- @param stepTexts table Array of macro text strings or attribute tables
--- @return boolean True if all steps are valid
--- @return table Array of error message strings (empty if valid)
function SF:ValidateSteps(stepTexts)
    if not stepTexts then
        return true, {}
    end
    local errors = {}
    for i, step in ipairs(stepTexts) do
        if not step then
            table.insert(errors, string.format(L["GEMS_STEP_NIL"], i))
        elseif type(step) == "string" then
            -- Raw string format (user input)
            if #step > D.MAX_MACROTEXT_LENGTH then
                table.insert(errors, string.format(L["GEMS_STEP_TOO_LONG"], i, #step, D.MAX_MACROTEXT_LENGTH))
            end
        elseif type(step) == "table" then
            -- Compiled attribute table format
            local mt = step.macrotext
            if mt and #mt > D.MAX_MACROTEXT_LENGTH then
                table.insert(errors, string.format(L["GEMS_STEP_TOO_LONG"], i, #mt, D.MAX_MACROTEXT_LENGTH))
            end
        end
    end
    return #errors == 0, errors
end

--- Look up a step function definition by name.
--- @param name string Step function name (Sequential, Random, Priority)
--- @return table|nil Step function definition table, or nil if not found
function SF:Get(name)
    if not name then
        return nil
    end
    return SF[name] or registered[name] or nil
end

--- Return a list of all registered step function names.
--- @return table Array of step function name strings
function SF:GetNames()
    local names = {}
    for key, val in pairs(SF) do
        if type(val) == "table" and val.name and val.BuildClickBody then
            table.insert(names, val.name)
        end
    end
    for _, entry in pairs(registered) do
        table.insert(names, entry.name)
    end
    table.sort(names)
    return names
end

-- ===========================================================================
-- Plugin step-function registry (Plugin API Phase 2c)
-- ===========================================================================
--
-- A registered step function is a PURE step-ordering strategy, the same
-- shape the built-in Priority / ReversePriority modes use: a pre-expansion
-- of the resolved step list that the EMS-owned Sequential secure body then
-- cycles. The plugin supplies only Expand(self, resolvedStepTexts) -> array
-- of macrotext strings (a reordering / weighting of its input). EMS owns the
-- secure WrapScript click body (always SF.Sequential.BuildClickBody) and
-- builds every attribute table itself, so a plugin can never run code in the
-- secure restricted environment and can never inject an attribute beyond
-- type = macro + macrotext.

-- Built-in registry keys a plugin id may never shadow.
local BUILTIN_KEYS = {
    [D.STEP_SEQUENTIAL] = true,
    [D.STEP_RANDOM] = true,
    [D.STEP_PRIORITY] = true,
    [D.STEP_REVERSE_PRIORITY] = true,
}

-- Validate a step-function spec against the Tier 4 contract. Required: id
-- (a non-empty string equal to spec.id, not a built-in key), name (a
-- string), Expand (a function). Optional OnRegister must be a function.
local function ValidateStepFunctionSpec(id, spec)
    if type(id) ~= "string" or id == "" then
        return false, "RegisterStepFunction: id must be a non-empty string"
    end
    if BUILTIN_KEYS[id] then
        return false, "RegisterStepFunction: id '" .. id .. "' collides with a built-in step function"
    end
    if type(spec) ~= "table" then
        return false, "RegisterStepFunction: spec must be a table"
    end
    if type(spec.id) ~= "string" or spec.id ~= id then
        return false, "RegisterStepFunction: spec.id must be a string equal to the registry id"
    end
    if type(spec.name) ~= "string" then
        return false, "RegisterStepFunction: spec.name must be a string"
    end
    if type(spec.Expand) ~= "function" then
        return false, "RegisterStepFunction: spec.Expand must be a function"
    end
    if spec.OnRegister ~= nil and type(spec.OnRegister) ~= "function" then
        return false, "RegisterStepFunction: OnRegister must be a function when present"
    end
    return true
end

--- Register a plugin step function (a pure step-ordering strategy). Rejects
--- a malformed spec, a built-in collision, or a duplicate id (never
--- overwrites). The stored entry reuses SF.Sequential.BuildClickBody so the
--- secure body stays EMS-owned. Runs the optional OnRegister in pcall.
--- @param id string Registry id; must equal spec.id and not collide with a built-in
--- @param spec table { id, name, Expand(self, resolvedStepTexts)->{string,...}, OnRegister? }
--- @return boolean ok
--- @return string|nil reason
function SF:RegisterStepFunction(id, spec)
    local ok, reason = ValidateStepFunctionSpec(id, spec)
    if not ok then
        return false, reason
    end
    if registered[id] then
        return false, "RegisterStepFunction: id '" .. id .. "' is already registered"
    end
    registered[id] = {
        name = spec.name,
        Expand = spec.Expand,
        BuildClickBody = SF.Sequential.BuildClickBody,
        __plugin = true,
    }
    if spec.OnRegister then
        pcall(spec.OnRegister, spec)
    end
    return true
end

--- Remove a registered plugin step function by id. Clears the SAME local
--- `registered` table RegisterStepFunction writes to, so a later registration
--- of the id is treated as fresh. The four built-in step functions are not
--- stored in this table, so they can never be removed here. Used by the
--- per-plugin teardown journal (Core/PluginAPI.lua) on plugin disable.
--- @param id string A registered step-function id
--- @return boolean removed True when an entry existed and was cleared, false otherwise
function SF:UnregisterStepFunction(id)
    if registered[id] then
        registered[id] = nil
        return true
    end
    return false
end

--- True iff name is a registered plugin step function (carries an Expand).
--- @param name string|nil
--- @return boolean
function SF:IsExpander(name)
    local entry = name and registered[name]
    return entry ~= nil and entry.Expand ~= nil
end

--- Run a registered step function's Expand on resolved macrotext strings and
--- return an array of { type = macro, macrotext } tables (the shape
--- ExpandPriority returns). The plugin Expand runs in pcall; a thrown error,
--- a non-table return, any non-string element, a 12.0 secret-tagged element,
--- an empty result, or an overlong step (via SF:ValidateSteps) makes the
--- WHOLE expansion fall back to plain sequential order, so the secure compile
--- path never receives a bad or taint-sensitive array. EMS builds every
--- attribute table; the plugin only chooses the macrotext order.
--- @param name string A registered step-function id
--- @param stepTexts table Array of resolved macrotext strings
--- @return table Array of attribute tables
function SF:RunExpander(name, stepTexts)
    local entry = name and registered[name]
    local function fallback(reason)
        if reason then
            GRIPEMS:Debug(
                "StepFunction '" .. tostring(name) .. "' expander rejected: " .. reason .. " (using sequential order)"
            )
        end
        local out = {}
        for i = 1, #(stepTexts or {}) do
            out[#out + 1] = { type = D.ATTR_TYPE_MACRO, macrotext = stepTexts[i] }
        end
        if #out == 0 then
            out[1] = { type = D.ATTR_TYPE_MACRO, macrotext = "" }
        end
        return out
    end
    if not entry or not entry.Expand then
        return fallback()
    end
    local ok, produced = pcall(entry.Expand, entry, stepTexts)
    if not ok then
        return fallback("Expand threw an error")
    end
    if type(produced) ~= "table" then
        return fallback("Expand did not return a table")
    end
    local result = {}
    for i = 1, #produced do
        local s = produced[i]
        if type(s) ~= "string" then
            return fallback("Expand returned a non-string entry")
        end
        if issecretvalue and issecretvalue(s) then
            return fallback("Expand returned a secret-tagged value")
        end
        result[#result + 1] = { type = D.ATTR_TYPE_MACRO, macrotext = s }
    end
    if #result == 0 then
        return fallback("Expand returned an empty array")
    end
    local valid = SF:ValidateSteps(result)
    if not valid then
        return fallback("Expand produced an overlong step (>255)")
    end
    return result
end

-- Engine-internal channel: shares the registry with the core + test harness,
-- the same pattern as GRIPEMS._conditions / GRIPEMS._variableProviders.
GRIPEMS._stepFunctions = registered
