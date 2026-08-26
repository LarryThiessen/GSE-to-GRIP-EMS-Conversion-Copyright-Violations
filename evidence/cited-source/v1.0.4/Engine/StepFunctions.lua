-- GRIP-EMS: Step Functions
-- Registry of step advancement strategies and WrapScript click body builders

local ADDON_NAME, GRIPEMS = ...
local L = LibStub("AceLocale-3.0"):GetLocale("GRIP-EMS")
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

-- Sequential: cycles 1, 2, 3, ..., N, 1, 2, ... (round-robin)
SF.Sequential = {
    name = D.STEP_SEQUENTIAL,
    description = L["GEMS_STEPFUNC_SEQUENTIAL_DESC"],
    BuildClickBody = function()
        local body = [=[
            local step = self:GetAttribute('step') or 1
            step = tonumber(step)
            local shouldReset = self:GetAttribute('_shouldReset')
            if shouldReset == "1" then
                step = 1
                self:SetAttribute('_shouldReset', '0')
            end
            local numS = numSteps or 1
            local stepData = steps[step]
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
            local shouldReset = self:GetAttribute('_shouldReset')
            local numS = numSteps or 1
            local step
            if shouldReset == "1" then
                step = 1
                self:SetAttribute('_shouldReset', '0')
            else
                step = random(1, numS)
            end
            self:SetAttribute('step', step)
            local stepData = steps[step]
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
    description = L["GEMS_STEPFUNC_REVERSE_PRIORITY_DESC"],
    BuildClickBody = SF.Sequential.BuildClickBody,
}

--- Expand steps for Priority mode (weighted pre-expansion).
--- N original steps become N*(N+1)/2 flat entries. Step 1 appears N times,
--- step 2 appears N-1 times, ..., step N appears 1 time. Each expanded entry
--- contains a single /cast line wrapped with optional KeyPress/KeyRelease.
--- The expanded array is cycled using the Sequential click body (round-robin).
--- @param stepTexts table Array of variable-resolved macro text strings
--- @param keyPress string|nil KeyPress block (prepended to each expanded step)
--- @param keyRelease string|nil KeyRelease block (appended to each expanded step)
--- @return table Array of attribute tables (one per expanded step)
function SF:ExpandPriority(stepTexts, keyPress, keyRelease)
    if not stepTexts or #stepTexts == 0 then
        return { { type = D.ATTR_TYPE_MACRO, macrotext = "" } }
    end
    local expanded = {}
    for i = 1, #stepTexts do
        for j = 1, i do
            local parts = {}
            if keyPress and keyPress ~= "" then
                parts[#parts + 1] = keyPress
            end
            parts[#parts + 1] = stepTexts[j]
            if keyRelease and keyRelease ~= "" then
                parts[#parts + 1] = keyRelease
            end
            expanded[#expanded + 1] = {
                type = D.ATTR_TYPE_MACRO,
                macrotext = table.concat(parts, "\n"),
            }
        end
    end
    return expanded
end

--- Expand steps for ReversePriority mode (inverted pre-expansion).
--- N original steps become N*(N+1)/2 flat entries. Step N appears N times,
--- step N-1 appears N-1 times, ..., step 1 appears 1 time.
--- Pattern: [N], [N-1, N], [N-2, N-1, N], ...
--- @param stepTexts table Array of variable-resolved macro text strings
--- @param keyPress string|nil KeyPress block (prepended to each expanded step)
--- @param keyRelease string|nil KeyRelease block (appended to each expanded step)
--- @return table Array of attribute tables (one per expanded step)
function SF:ExpandReversePriority(stepTexts, keyPress, keyRelease)
    if not stepTexts or #stepTexts == 0 then
        return { { type = D.ATTR_TYPE_MACRO, macrotext = "" } }
    end
    local n = #stepTexts
    local expanded = {}
    for i = n, 1, -1 do
        for j = i, n do
            local parts = {}
            if keyPress and keyPress ~= "" then
                parts[#parts + 1] = keyPress
            end
            parts[#parts + 1] = stepTexts[j]
            if keyRelease and keyRelease ~= "" then
                parts[#parts + 1] = keyRelease
            end
            expanded[#expanded + 1] = {
                type = D.ATTR_TYPE_MACRO,
                macrotext = table.concat(parts, "\n"),
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
    if not stepTexts then return true, {} end
    local errors = {}
    for i, step in ipairs(stepTexts) do
        if not step then
            table.insert(errors, string.format(L["GEMS_STEP_NIL"], i))
        elseif type(step) == "string" then
            -- Raw string format (user input)
            if #step > D.MAX_MACROTEXT_LENGTH then
                table.insert(errors, string.format(L["GEMS_STEP_TOO_LONG"], i,
                    #step, D.MAX_MACROTEXT_LENGTH))
            end
        elseif type(step) == "table" then
            -- Compiled attribute table format
            local mt = step.macrotext
            if mt and #mt > D.MAX_MACROTEXT_LENGTH then
                table.insert(errors, string.format(L["GEMS_STEP_TOO_LONG"], i,
                    #mt, D.MAX_MACROTEXT_LENGTH))
            end
        end
    end
    return #errors == 0, errors
end

--- Look up a step function definition by name.
--- @param name string Step function name (Sequential, Random, Priority)
--- @return table|nil Step function definition table, or nil if not found
function SF:Get(name)
    if not name then return nil end
    return SF[name] or nil
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
    table.sort(names)
    return names
end
