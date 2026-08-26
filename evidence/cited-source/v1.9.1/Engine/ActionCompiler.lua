-- GRIP-EMS: Action Compiler
-- Flattens action tree nodes into a flat steps array for the runtime engine.
-- The action tree is the editor-facing data model; the engine runs flat steps.
-- Compilation happens at save/activate time.

local ADDON_NAME, GRIPEMS = ...
local D = GRIPEMS.Defaults

GRIPEMS.ActionCompiler = {}
local AC = GRIPEMS.ActionCompiler

--- Compile an actions array (tree) into a flat steps array (strings).
--- @param actions table Array of action nodes
--- @param engine table Engine reference (for embed lookups)
--- @return table steps Flat array of macro text strings
function AC.CompileActions(actions, engine)
    if not actions or #actions == 0 then
        return {}
    end
    local steps = {}
    local interleaves = {}
    for _, node in ipairs(actions) do
        if node.type == D.ACTION_TYPE_ACTION and node.interval and node.interval >= D.ACTION_INTERLEAVE_MIN then
            interleaves[#interleaves + 1] = {
                macro = node.macro or "",
                interval = node.interval,
            }
        else
            local nodeSteps = AC._compileNode(node, engine, 1)
            for _, step in ipairs(nodeSteps) do
                steps[#steps + 1] = step
            end
        end
    end
    if #interleaves > 0 then
        AC._applyInterleaving(steps, interleaves)
    end
    return steps
end

--- Insert interleave copies into a flat step array at regular intervals.
--- @param steps table Flat array of macro text strings (modified in place)
--- @param interleaves table Array of { macro, interval }
function AC._applyInterleaving(steps, interleaves)
    local MAX_INSERTED = 200
    local totalInserted = 0
    for _, il in ipairs(interleaves) do
        if il.macro ~= "" then
            local interval = il.interval
            if interval < D.ACTION_INTERLEAVE_MIN then
                interval = D.ACTION_INTERLEAVE_MIN
            end
            local pos = interval
            while pos <= #steps and totalInserted < MAX_INSERTED do
                table.insert(steps, pos + 1, il.macro)
                totalInserted = totalInserted + 1
                pos = pos + interval + 1
            end
        end
    end
end

--- Compile a single action node into flat step strings.
--- @param node table Action node
--- @param engine table Engine reference
--- @param depth number Current nesting depth
--- @return table steps Flat array of macro text strings
function AC._compileNode(node, engine, depth)
    if not node or not node.type then
        return {}
    end
    if depth > D.ACTION_MAX_DEPTH then
        GRIPEMS:Debug("ActionCompiler: max nesting depth exceeded at depth " .. tostring(depth))
        return {}
    end

    local nodeType = node.type

    -- Action: single macro string
    if nodeType == D.ACTION_TYPE_ACTION then
        return { node.macro or "" }
    end

    -- Pause: emit N empty strings (no-op keypresses)
    if nodeType == D.ACTION_TYPE_PAUSE then
        local clicks = node.clicks or 1
        if clicks < 1 then
            clicks = 1
        end
        local steps = {}
        for i = 1, clicks do
            steps[i] = ""
        end
        return steps
    end

    -- Embed: inline steps from another sequence
    if nodeType == D.ACTION_TYPE_EMBED then
        local seqName = node.sequence or ""
        if seqName == "" then
            GRIPEMS:Debug("ActionCompiler: embed node has empty sequence name")
            return {}
        end
        if engine and engine.sequences and engine.sequences[seqName] then
            local entry = engine.sequences[seqName]
            local ver = engine:GetActiveVersion(entry.data)
            if ver and ver.steps then
                local copy = {}
                for i, step in ipairs(ver.steps) do
                    copy[i] = step
                end
                return copy
            end
        end
        GRIPEMS:Debug("ActionCompiler: embedded sequence not found: " .. seqName)
        return {}
    end

    -- Loop: compile children then repeat/expand
    if nodeType == D.ACTION_TYPE_LOOP then
        local childSteps = {}
        local interleaves = {}
        local children = node.children or {}
        for _, child in ipairs(children) do
            if child.type == D.ACTION_TYPE_ACTION and child.interval and child.interval >= D.ACTION_INTERLEAVE_MIN then
                interleaves[#interleaves + 1] = {
                    macro = child.macro or "",
                    interval = child.interval,
                }
            else
                local cs = AC._compileNode(child, engine, depth + 1)
                for _, step in ipairs(cs) do
                    childSteps[#childSteps + 1] = step
                end
            end
        end
        if #childSteps == 0 and #interleaves == 0 then
            return {}
        end

        local repeatCount = node["repeat"] or D.ACTION_LOOP_DEFAULT_REPEAT
        if repeatCount < 1 then
            repeatCount = 1
        end
        if repeatCount > D.ACTION_LOOP_MAX_REPEAT then
            repeatCount = D.ACTION_LOOP_MAX_REPEAT
        end

        local sfName = node.stepFunction or D.STEP_SEQUENTIAL
        local steps = {}

        if sfName == D.STEP_PRIORITY then
            -- Priority expansion on step strings
            local n = #childSteps
            for i = 1, n do
                for j = 1, i do
                    steps[#steps + 1] = childSteps[j]
                end
            end
        elseif sfName == D.STEP_REVERSE_PRIORITY then
            -- Reverse priority expansion on step strings
            local n = #childSteps
            for i = n, 1, -1 do
                for j = i, n do
                    steps[#steps + 1] = childSteps[j]
                end
            end
        else
            -- Sequential (and Random -- randomness is runtime)
            for r = 1, repeatCount do
                for _, step in ipairs(childSteps) do
                    steps[#steps + 1] = step
                end
            end
        end

        if #interleaves > 0 then
            AC._applyInterleaving(steps, interleaves)
        end

        return steps
    end

    -- If: compile branches and merge where possible
    if nodeType == D.ACTION_TYPE_IF then
        local condition = node.variable or "= true"
        local trueBranch = node.children and node.children[1] or {}
        local falseBranch = node.children and node.children[2] or {}

        -- Simple case: each branch has exactly 1 action child
        local simpleTrue = (#trueBranch == 1 and trueBranch[1].type == D.ACTION_TYPE_ACTION)
        local simpleFalse = (#falseBranch == 1 and falseBranch[1].type == D.ACTION_TYPE_ACTION)
        local simpleFalseEmpty = (#falseBranch == 0)

        if simpleTrue and (simpleFalse or simpleFalseEmpty) then
            local trueSpell = trueBranch[1].macro or ""
            if simpleFalseEmpty then
                -- Single branch: /cast [condition] spell
                return { "/cast [" .. condition .. "] " .. trueSpell }
            else
                local falseSpell = falseBranch[1].macro or ""
                -- Both branches: /cast [condition] spell1; spell2
                return { "/cast [" .. condition .. "] " .. trueSpell .. "; " .. falseSpell }
            end
        end

        -- Complex case: compile true branch only (false branch discarded)
        GRIPEMS:Debug("ActionCompiler: complex If block -- false branch discarded at compile time")
        local steps = {}
        for _, child in ipairs(trueBranch) do
            local cs = AC._compileNode(child, engine, depth + 1)
            for _, step in ipairs(cs) do
                steps[#steps + 1] = step
            end
        end
        return steps
    end

    -- Unknown type: skip
    GRIPEMS:Debug("ActionCompiler: unknown action type: " .. tostring(nodeType))
    return {}
end

--- Migrate a flat steps array to an actions array.
--- Each step becomes a simple action node with the step as macro text.
--- @param steps table Flat array of macro text strings
--- @return table actions Array of action nodes
function AC.MigrateStepsToActions(steps)
    if not steps then
        return {}
    end
    local actions = {}
    for i, step in ipairs(steps) do
        actions[i] = {
            type = D.ACTION_TYPE_ACTION,
            macro = step,
        }
    end
    return actions
end

--- Validate an actions array recursively.
--- @param actions table Array of action nodes
--- @param depth number|nil Current depth (default 1)
--- @return boolean isValid
--- @return table errors Array of error strings
function AC.ValidateActions(actions, depth)
    depth = depth or 1
    local errors = {}

    if not actions or type(actions) ~= "table" then
        return true, errors
    end

    if depth > D.ACTION_MAX_DEPTH then
        errors[#errors + 1] = "Max nesting depth (" .. tostring(D.ACTION_MAX_DEPTH) .. ") exceeded"
        return false, errors
    end

    for i, node in ipairs(actions) do
        if type(node) ~= "table" or not node.type then
            errors[#errors + 1] = "Node " .. tostring(i) .. ": missing or invalid type"
        elseif node.type == D.ACTION_TYPE_ACTION then
            if not node.macro or node.macro == "" then
                errors[#errors + 1] = "Node " .. tostring(i) .. ": action has empty macro"
            end
            if node.interval then
                if
                    type(node.interval) ~= "number"
                    or node.interval < D.ACTION_INTERLEAVE_MIN
                    or node.interval > D.ACTION_INTERLEAVE_MAX
                then
                    errors[#errors + 1] = "Node "
                        .. tostring(i)
                        .. ": interval out of range ("
                        .. tostring(D.ACTION_INTERLEAVE_MIN)
                        .. "-"
                        .. tostring(D.ACTION_INTERLEAVE_MAX)
                        .. ")"
                end
            end
        elseif node.type == D.ACTION_TYPE_LOOP then
            local rep = node["repeat"] or 0
            if rep < 1 or rep > D.ACTION_LOOP_MAX_REPEAT then
                errors[#errors + 1] = "Node "
                    .. tostring(i)
                    .. ": loop repeat out of range (1-"
                    .. tostring(D.ACTION_LOOP_MAX_REPEAT)
                    .. ")"
            end
            local _, childErrors = AC.ValidateActions(node.children or {}, depth + 1)
            for _, e in ipairs(childErrors) do
                errors[#errors + 1] = e
            end
        elseif node.type == D.ACTION_TYPE_IF then
            if not node.variable or node.variable == "" then
                errors[#errors + 1] = "Node " .. tostring(i) .. ": if has empty variable"
            end
            if node.children then
                local _, trueErrors = AC.ValidateActions(node.children[1] or {}, depth + 1)
                for _, e in ipairs(trueErrors) do
                    errors[#errors + 1] = e
                end
                local _, falseErrors = AC.ValidateActions(node.children[2] or {}, depth + 1)
                for _, e in ipairs(falseErrors) do
                    errors[#errors + 1] = e
                end
            end
        elseif node.type == D.ACTION_TYPE_EMBED then
            if not node.sequence or node.sequence == "" then
                errors[#errors + 1] = "Node " .. tostring(i) .. ": embed has empty sequence name"
            end
        elseif node.type ~= D.ACTION_TYPE_PAUSE then
            errors[#errors + 1] = "Node " .. tostring(i) .. ": unknown type " .. tostring(node.type)
        end
    end

    return #errors == 0, errors
end
