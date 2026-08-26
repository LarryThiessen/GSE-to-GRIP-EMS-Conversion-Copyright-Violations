-- GRIP-EMS: ActionCompiler
-- Created: 2026-04-03
-- Updated: 2026-07-14
-- Patch: 12.0.7.68453 Midnight (Retail LIVE)

-- GRIP-EMS: Action Compiler
-- Flattens action tree nodes into a flat steps array for the runtime engine.
-- The action tree is the editor-facing data model; the engine runs flat steps.
-- Compilation happens at save/activate time.

local ADDON_NAME, GRIPEMS = ...
local D = GRIPEMS.Defaults
local L = LibStub("AceLocale-3.0"):GetLocale("GRIP-EMS", true)

GRIPEMS.ActionCompiler = {}
local AC = GRIPEMS.ActionCompiler

AC._depthWarnedAt = 0

-- Total interleave copies allowed across ALL interleaves in one compile
-- scope. Shared by _applyInterleaving (which enforces it) and
-- InterleaveOverflows (which warns when it bites).
AC.MAX_INTERLEAVE_INSERTED = 200

--- Compile an actions array (tree) into a flat steps array (strings).
--- Also returns a parallel labels array (Phase 1C-bis-outline): labels[i]
--- is the optional per-action label announced by TTS at step i, sparse
--- (nil where no label applies). Interleaved copies carry nil labels.
--- @param actions table Array of action nodes
--- @param engine table Engine reference (for embed lookups)
--- @param version table|nil Version table; if version.repeatCount >= 2 the
---                          entire actions array is wrapped in a synthetic
---                          outer Loop node before compilation.
--- @return table steps Flat array of macro text strings
--- @return table labels Sparse parallel labels array
local function compileTree(actions, engine, version, ignoreInterleave)
    if type(actions) ~= "table" or #actions == 0 then
        return {}, {}
    end
    -- ENH-TOP-LEVEL-SEQUENCE-REPEAT-N: if the version requests N >= 2
    -- repetitions, wrap the entire actions array in a synthetic outer
    -- Loop node. The existing Loop branch will expand the children inline
    -- repeatCount times (Sequential expansion path). Capped at
    -- D.ACTION_LOOP_MAX_REPEAT to match the per-loop limit. nil / 0 / 1 =
    -- no wrap (current infinite-cycle behavior preserved).
    local repeatCount = version and tonumber(version.repeatCount)
    if repeatCount and repeatCount >= 2 then
        if repeatCount > D.ACTION_LOOP_MAX_REPEAT then
            repeatCount = D.ACTION_LOOP_MAX_REPEAT
        end
        actions = {
            {
                type = D.ACTION_TYPE_LOOP,
                ["repeat"] = repeatCount,
                children = actions,
                stepFunction = D.STEP_SEQUENTIAL,
            },
        }
    end
    local steps = {}
    local labels = {}
    local interleaves = {}
    for _, node in ipairs(actions) do
        -- A disabled node is skipped entirely: it contributes no execution
        -- step (covers ACTION/IF/EMBED/PAUSE/LOOP and their subtrees). Absent
        -- disabled key == enabled, so existing sequences are unaffected. A
        -- malformed non-table entry (corrupt import / SavedVariables edit) is
        -- skipped the same way; validation reports it, compile never errors.
        if type(node) == "table" and not node.disabled then
            local nodeInterval = tonumber(node.interval)
            if
                node.type == D.ACTION_TYPE_ACTION
                and nodeInterval
                and nodeInterval >= D.ACTION_INTERLEAVE_MIN
                and not ignoreInterleave
            then
                interleaves[#interleaves + 1] = {
                    macro = type(node.macro) == "string" and node.macro or "",
                    interval = nodeInterval,
                }
            else
                local nodeSteps, nodeLabels = AC._compileNode(node, engine, 1, ignoreInterleave)
                for i, step in ipairs(nodeSteps) do
                    steps[#steps + 1] = step
                    labels[#steps] = nodeLabels[i]
                end
            end
        end
    end
    if #interleaves > 0 then
        AC._applyInterleaving(steps, labels, interleaves)
    end
    return steps, labels
end

--- Public entry. Compile an actions tree to flat steps + sparse labels.
--- If the normal compile yields zero steps but the tree has enabled interleave
--- actions (every action is an interleave, so there is no base step for them to
--- attach to), recompile treating interleaves as base steps so the sequence
--- runs instead of silently doing nothing.
function AC.CompileActions(actions, engine, version)
    local steps, labels = compileTree(actions, engine, version, false)
    if #steps == 0 and AC._hasEnabledInterleave(actions) then
        steps, labels = compileTree(actions, engine, version, true)
        GRIPEMS:Debug("ActionCompiler: interleave-only tree had no base steps; compiled interleaves as base steps")
    end
    return steps, labels
end

--- Compile the AUTHORED base order: the same tree walk as CompileActions, but
--- with interleave copies suppressed (ignoreInterleave = true) and the version
--- level repeatCount wrap skipped (version = nil). Loops are still unrolled and
--- IF branches still flattened -- this is the authored BASE ORDER, not the tree.
--- Backs API:GetAuthoredSteps. Never mutates the actions tree.
--- @param actions table Authored action tree
--- @param engine table|nil Engine reference (for embed lookups)
--- @return table steps Flat array of macro text strings, interleave-free
--- @return table labels Sparse parallel labels array
function AC.CompileAuthoredActions(actions, engine)
    return compileTree(actions, engine, nil, true)
end

--- True if any enabled ACTION node anywhere in the tree is an interleave.
function AC._hasEnabledInterleave(actions)
    if type(actions) ~= "table" then
        return false
    end
    for _, node in ipairs(actions) do
        if type(node) == "table" and not node.disabled then
            local nodeInterval = tonumber(node.interval)
            if node.type == D.ACTION_TYPE_ACTION and nodeInterval and nodeInterval >= D.ACTION_INTERLEAVE_MIN then
                return true
            end
            local kids = node.children
            if type(kids) == "table" then
                if node.type == D.ACTION_TYPE_IF then
                    if AC._hasEnabledInterleave(kids[1] or {}) or AC._hasEnabledInterleave(kids[2] or {}) then
                        return true
                    end
                elseif AC._hasEnabledInterleave(kids) then
                    return true
                end
            end
        end
    end
    return false
end

--- True when the tree has enabled interleave actions AND the normal (no
--- fallback) compile produces zero steps. Shared by ValidateActions, the editor
--- save/export warnings, and the Repair auto-fix.
function AC.CompilesEmptyDueToInterleave(actions)
    if not AC._hasEnabledInterleave(actions) then
        return false
    end
    local steps = compileTree(actions, nil, nil, false)
    return #steps == 0
end

--- Insert interleave copies into a flat step array at regular intervals.
--- Keeps labels aligned: inserted copies carry nil labels (Phase 1C-bis-outline).
--- @param steps table Flat array of macro text strings (modified in place)
--- @param labels table Parallel labels array (modified in place)
--- @param interleaves table Array of { macro, interval }
function AC._applyInterleaving(steps, labels, interleaves)
    local MAX_INSERTED = AC.MAX_INTERLEAVE_INSERTED
    local originalCount = #steps

    -- Snapshot the base steps + labels BEFORE inserting anything. Every
    -- interleave computes its insert positions against these ORIGINAL
    -- indices, so stacking N interleaves keeps each one's spacing
    -- independent. The previous in-place loop mutated steps while iterating,
    -- so each later interleave counted copies an earlier one had already
    -- inserted: the effective interval drifted (an "every 4" interleave
    -- collapsed toward "every 2") and the array bloated until the keybind
    -- stopped firing.
    local baseSteps, baseLabels = {}, {}
    for i = 1, originalCount do
        baseSteps[i] = steps[i]
        baseLabels[i] = labels[i]
    end

    -- Bucket each interleave's copies by the ORIGINAL index they follow.
    -- insertAfter[k] is the ordered list of macros emitted after base step k.
    -- MAX_INSERTED caps the total copies across all interleaves.
    local insertAfter = {}
    local totalInserted = 0
    for _, il in ipairs(interleaves) do
        if il.macro ~= "" then
            local interval = il.interval
            if interval < D.ACTION_INTERLEAVE_MIN then
                interval = D.ACTION_INTERLEAVE_MIN
            end
            -- Clamp an interval that overruns this compile scope. With
            -- interval > originalCount the while loop below never executes: the
            -- interleave contributes zero copies and the action vanishes from
            -- the compiled macro with no warning (pleggster, 2026-07-12 --
            -- interval 8 against a 6-step Feral loop, Convoke never fired).
            -- Clamping makes it fire once per cycle instead of never;
            -- ValidateActions warns and names the Repeat count that would let
            -- the authored interval land unclamped.
            -- originalCount > 0 is REQUIRED: clamping to 0 makes k = 0 and the
            -- loop below never terminates. Zero base steps stays zero copies and
            -- is handled by CompilesEmptyDueToInterleave plus the fallback
            -- recompile.
            if originalCount > 0 and interval > originalCount then
                interval = originalCount
            end
            local k = interval
            while k <= originalCount and totalInserted < MAX_INSERTED do
                local bucket = insertAfter[k]
                if not bucket then
                    bucket = {}
                    insertAfter[k] = bucket
                end
                bucket[#bucket + 1] = il.macro
                totalInserted = totalInserted + 1
                k = k + interval
            end
        end
    end

    if totalInserted == 0 then
        return
    end

    -- Rebuild the flat arrays: walk base steps in order, emit each one then
    -- any interleave copies bucketed after it. Inserted copies carry nil
    -- labels; original steps are never dropped.
    local outSteps, outLabels = {}, {}
    local outN = 0
    for k = 1, originalCount do
        outN = outN + 1
        outSteps[outN] = baseSteps[k]
        outLabels[outN] = baseLabels[k]
        local bucket = insertAfter[k]
        if bucket then
            for _, macro in ipairs(bucket) do
                outN = outN + 1
                outSteps[outN] = macro
                outLabels[outN] = nil
            end
        end
    end

    -- Copy the rebuilt arrays back into the caller's tables (in place).
    for i = 1, outN do
        steps[i] = outSteps[i]
        labels[i] = outLabels[i]
    end
end

-- Public alias. Import/LegacyImport.CompileMacroVersion weaves imported
-- Repeat actions through this exact helper, so baked import steps are
-- byte-identical to an editor recompile (no divergence when an imported
-- sequence is later edited and saved).
AC.ApplyInterleaving = AC._applyInterleaving

--- True when any node in this subtree is an Embed whose target cannot be
--- resolved against the engine. An unresolved Embed compiles to zero steps
--- here but to its real step count in the live compile, so any base-step
--- count taken across it is a guess. Callers refuse to warn on a guess.
--- IF branches are ARRAYS of nodes rather than nodes, so an entry with no
--- .type field is recursed into as a branch list.
local function hasUnresolvableEmbed(nodes, engine)
    if type(nodes) ~= "table" then
        return false
    end
    for _, n in ipairs(nodes) do
        if type(n) == "table" then
            if n.type == nil then
                if hasUnresolvableEmbed(n, engine) then
                    return true
                end
            elseif not n.disabled then
                if n.type == D.ACTION_TYPE_EMBED then
                    local nm = type(n.sequence) == "string" and n.sequence or ""
                    if not (engine and engine.sequences and engine.sequences[nm]) then
                        return true
                    end
                end
                if hasUnresolvableEmbed(n.children, engine) then
                    return true
                end
            end
        end
    end
    return false
end

--- True when the compiler will collect this node as an interleave rather
--- than compile it into base steps. Mirrors the collection condition in
--- compileTree and in the LOOP branch of _compileNode. The macro is NOT
--- part of the test: an interval-bearing ACTION with an empty macro is
--- still collected as an interleave (and then skipped when copies are
--- emitted), so it contributes no base step either way.
local function isInterleaveNode(n)
    if type(n) ~= "table" or n.disabled then
        return false
    end
    if n.type ~= D.ACTION_TYPE_ACTION then
        return false
    end
    local iv = tonumber(n.interval)
    return iv ~= nil and iv >= D.ACTION_INTERLEAVE_MIN
end

--- Shallow copy of a LOOP node with its interleave children removed, so
--- compiling it yields exactly the base-step array _applyInterleaving
--- would receive for that loop. repeatOverride, when given, replaces the
--- node's repeat -- used to measure ONE iteration.
local function loopBaseCopy(loopNode, repeatOverride)
    local copy = {}
    for k, v in pairs(loopNode) do
        copy[k] = v
    end
    if repeatOverride ~= nil then
        copy["repeat"] = repeatOverride
    end
    local kids = {}
    for _, ch in ipairs(loopNode.children or {}) do
        if not isInterleaveNode(ch) then
            kids[#kids + 1] = ch
        end
    end
    copy.children = kids
    return copy
end

--- Report every interleave in a scope that the compiler will silently
--- alter -- either because its interval overruns the scope's base-step
--- count (clamped), or because the shared copy budget is spent before its
--- copies are emitted (truncated). Feeds the ValidateActions warnings.
--- @param actions table The scope's DIRECT child list
--- @param loopNode table|nil The LOOP node owning this scope, or nil for
---        the root scope. The count is obtained by COMPILING, never by
---        arithmetic -- see the triangle expansions in the LOOP branch.
--- @param engine table|nil Engine reference; defaults to GRIPEMS.Engine
--- @param depth number Nesting depth of this scope in the action tree;
---        the live compiler caps output past D.ACTION_MAX_DEPTH, so the
---        count must be taken at the SAME depth. Defaults to 1 (root).
--- @return table overflows Array of { index, interval, baseCount, perIteration, suggestedRepeat }
--- @return table capped Array of { index, want, got }
function AC.InterleaveOverflows(actions, loopNode, engine, depth)
    local overflows, capped = {}, {}
    if type(actions) ~= "table" then
        return overflows, capped
    end

    -- The live compile resolves Embeds through the engine. Use the same
    -- engine here or the base-step count silently disagrees with the
    -- compiler and every warning derived from it is false.
    if engine == nil then
        engine = GRIPEMS.Engine
    end
    depth = tonumber(depth) or 1
    if depth < 1 then
        depth = 1
    end
    if hasUnresolvableEmbed(actions, engine) then
        -- Base count is unknowable. The clamp still does the right thing
        -- against the real compiled array; we simply do not warn.
        return overflows, capped
    end

    -- Collect the interleave candidates. isInterleaveNode mirrors the
    -- compiler's collection condition; an empty macro emits no copies
    -- (_applyInterleaving skips it), so it can neither clamp nor truncate
    -- and is not a candidate here -- ValidateActions already errors on it.
    local pending = {}
    for i, node in ipairs(actions) do
        if isInterleaveNode(node) and type(node.macro) == "string" and node.macro ~= "" then
            pending[#pending + 1] = { index = i, interval = tonumber(node.interval) }
        end
    end

    -- Obtain the base-step count the interval is measured against by
    -- COMPILING, never by arithmetic. Priority and ReversePriority expand a
    -- loop TRIANGULARLY, so the real count is not repeat * #children; only
    -- the real compile (with the real repeat clamp) knows it. Every compile
    -- is guarded -- a count we could not obtain never produces a warning.
    local baseCount, perIteration
    if loopNode == nil then
        -- Root scope: no repeat. Sum the compiled step count of every
        -- non-interleave direct child. perIteration == baseCount.
        baseCount = 0
        for _, node in ipairs(actions) do
            if type(node) == "table" and not node.disabled and not isInterleaveNode(node) then
                local ok, nodeSteps = pcall(AC._compileNode, node, engine, depth, false)
                if not ok or type(nodeSteps) ~= "table" then
                    return overflows, capped
                end
                baseCount = baseCount + #nodeSteps
            end
        end
        perIteration = baseCount
    else
        -- Loop scope: compile the loop with its interleave children stripped
        -- for the full count, and again with repeat forced to 1 for a single
        -- iteration. The real expansion (triangle or linear) and the real
        -- repeat clamp both apply, so neither count can drift.
        local okBase, baseSteps = pcall(AC._compileNode, loopBaseCopy(loopNode, nil), engine, depth, false)
        if not okBase or type(baseSteps) ~= "table" then
            return overflows, capped
        end
        local okIter, iterSteps = pcall(AC._compileNode, loopBaseCopy(loopNode, 1), engine, depth, false)
        if not okIter or type(iterSteps) ~= "table" then
            return overflows, capped
        end
        baseCount = #baseSteps
        perIteration = #iterSteps
    end

    if baseCount <= 0 or perIteration <= 0 then
        -- No base steps at all: CompilesEmptyDueToInterleave already reports
        -- that case as an error, and perIteration is a divisor below.
        return overflows, capped
    end

    -- Walk the interleaves in the SAME order _applyInterleaving does and
    -- spend the SAME shared budget, so the truncation reported here is the
    -- truncation the compiler actually performs.
    local budget = AC.MAX_INTERLEAVE_INSERTED
    for _, p in ipairs(pending) do
        local effective = p.interval
        if effective > baseCount then
            effective = baseCount
            overflows[#overflows + 1] = {
                index = p.index,
                interval = p.interval,
                baseCount = baseCount,
                perIteration = perIteration,
                suggestedRepeat = math.ceil(p.interval / perIteration),
            }
        end
        local want = math.floor(baseCount / effective)
        local got = want
        if got > budget then
            got = budget
        end
        budget = budget - got
        if got < want then
            capped[#capped + 1] = { index = p.index, want = want, got = got }
        end
    end
    return overflows, capped
end

--- Compile a single action node into flat step strings + sparse labels.
--- Label propagation (Phase 1C-bis-outline):
---   ACTION -> labels[1] = node.label
---   PAUSE  -> labels[1] = node.label (first emitted step only)
---   EMBED  -> labels[1] = node.label (first emitted step only)
---   LOOP   -> labels at each iteration entry = node.label (Sequential/Random);
---            labels[1] = node.label for Priority/ReversePriority expansions
---   IF     -> single-line/two-line paths: labels[1] = node.label;
---            per-step path: child labels preserved at offsets, labels[1]
---            overridden by node.label when set (matches LOOP behavior).
---            See IF_Node_Complete_Spec.md section 7 for the full path
---            decision matrix (paths a-f).
--- @param node table Action node
--- @param engine table Engine reference
--- @param depth number Current nesting depth
--- @return table steps Flat array of macro text strings
--- @return table labels Sparse parallel labels array
function AC._compileNode(node, engine, depth, ignoreInterleave)
    if type(node) ~= "table" or not node.type then
        return {}, {}
    end
    -- A disabled node compiles to nothing wherever it sits -- Loop children,
    -- IF branch children, nested subtrees. The top-level skip in compileTree
    -- covers only depth-1 nodes; this guard covers every recursive path.
    if node.disabled then
        return {}, {}
    end
    if depth > D.ACTION_MAX_DEPTH then
        GRIPEMS:Debug("ActionCompiler: max nesting depth exceeded at depth " .. tostring(depth))
        local now = GetTime() or 0
        if now - (AC._depthWarnedAt or 0) > 60 then
            AC._depthWarnedAt = now
            if L and L["GEMS_COMPILE_DEPTH_EXCEEDED"] and GRIPEMS.Print then
                GRIPEMS:Print(string.format(L["GEMS_COMPILE_DEPTH_EXCEEDED"], D.ACTION_MAX_DEPTH))
            end
        end
        return {}, {}
    end

    local nodeType = node.type

    -- Action: single macro string
    if nodeType == D.ACTION_TYPE_ACTION then
        local labels = {}
        labels[1] = node.label
        return { type(node.macro) == "string" and node.macro or "" }, labels
    end

    -- Pause: emit N empty strings (no-op keypresses)
    if nodeType == D.ACTION_TYPE_PAUSE then
        local clicks = tonumber(node.clicks) or 1
        if clicks < 1 then
            clicks = 1
        end
        local steps = {}
        local labels = {}
        for i = 1, clicks do
            steps[i] = ""
        end
        labels[1] = node.label
        return steps, labels
    end

    -- Embed: inline steps from another sequence
    if nodeType == D.ACTION_TYPE_EMBED then
        local seqName = type(node.sequence) == "string" and node.sequence or ""
        if seqName == "" then
            GRIPEMS:Debug("ActionCompiler: embed node has empty sequence name")
            return {}, {}
        end
        if engine and engine.sequences and engine.sequences[seqName] then
            local entry = engine.sequences[seqName]
            local ver = engine:GetActiveVersion(entry.data)
            if ver and ver.steps then
                local copy = {}
                local labels = {}
                for i, step in ipairs(ver.steps) do
                    copy[i] = step
                end
                labels[1] = node.label
                return copy, labels
            end
        end
        GRIPEMS:Debug("ActionCompiler: embedded sequence not found: " .. seqName)
        return {}, {}
    end

    -- Loop: compile children then repeat/expand
    if nodeType == D.ACTION_TYPE_LOOP then
        local childSteps = {}
        local childLabels = {}
        local interleaves = {}
        local children = type(node.children) == "table" and node.children or {}
        for _, child in ipairs(children) do
            local childInterval = type(child) == "table" and tonumber(child.interval) or nil
            if
                type(child) == "table"
                and not child.disabled
                and child.type == D.ACTION_TYPE_ACTION
                and childInterval
                and childInterval >= D.ACTION_INTERLEAVE_MIN
                and not ignoreInterleave
            then
                interleaves[#interleaves + 1] = {
                    macro = type(child.macro) == "string" and child.macro or "",
                    interval = childInterval,
                }
            else
                local cs, cl = AC._compileNode(child, engine, depth + 1, ignoreInterleave)
                for i, step in ipairs(cs) do
                    childSteps[#childSteps + 1] = step
                    childLabels[#childSteps] = cl[i]
                end
            end
        end
        if #childSteps == 0 and #interleaves == 0 then
            return {}, {}
        end

        local repeatCount = tonumber(node["repeat"]) or D.ACTION_LOOP_DEFAULT_REPEAT
        if repeatCount < 1 then
            repeatCount = 1
        end
        if repeatCount > D.ACTION_LOOP_MAX_REPEAT then
            repeatCount = D.ACTION_LOOP_MAX_REPEAT
        end

        local sfName = node.stepFunction or D.STEP_SEQUENTIAL
        local steps = {}
        local labels = {}

        if sfName == D.STEP_PRIORITY then
            -- Priority expansion on step strings, repeated repeatCount times.
            -- Without the repeat wrap a Priority loop silently ignored its
            -- Repeat count and always produced a single iteration.
            local n = #childSteps
            for _ = 1, repeatCount do
                for i = 1, n do
                    for j = 1, i do
                        steps[#steps + 1] = childSteps[j]
                        labels[#steps] = childLabels[j]
                    end
                end
            end
        elseif sfName == D.STEP_REVERSE_PRIORITY then
            -- Reverse priority expansion on step strings, repeated repeatCount
            -- times (same Repeat-count fix as the Priority branch above).
            local n = #childSteps
            for _ = 1, repeatCount do
                for i = n, 1, -1 do
                    for j = i, n do
                        steps[#steps + 1] = childSteps[j]
                        labels[#steps] = childLabels[j]
                    end
                end
            end
        else
            -- Sequential (and Random -- randomness is runtime)
            for _ = 1, repeatCount do
                for i, step in ipairs(childSteps) do
                    steps[#steps + 1] = step
                    labels[#steps] = childLabels[i]
                end
            end
        end

        -- Apply loop label at each iteration entry (Sequential/Random),
        -- or once at the start of the expansion (Priority/ReversePriority).
        if node.label and #steps > 0 then
            if sfName == D.STEP_PRIORITY or sfName == D.STEP_REVERSE_PRIORITY then
                labels[1] = node.label
            else
                local iterationSize = #childSteps
                if iterationSize > 0 then
                    for r = 1, repeatCount do
                        local firstIdx = (r - 1) * iterationSize + 1
                        if firstIdx <= #steps then
                            labels[firstIdx] = node.label
                        end
                    end
                end
            end
        end

        if #interleaves > 0 then
            AC._applyInterleaving(steps, labels, interleaves)
        end

        return steps, labels
    end

    -- If: compile branches per IF_Node_Complete_Spec.md section 7 path matrix.
    -- All parsing/serialization/negation/injection routes through MacroSyntax.
    if nodeType == D.ACTION_TYPE_IF then
        local MS = GRIPEMS.MacroSyntax
        local condText = type(node.variable) == "string" and node.variable or ""
        condText = condText:gsub("^%s+", ""):gsub("%s+$", "")

        if condText == "" then
            GRIPEMS:Debug("ActionCompiler: IF empty cond -- skipping")
            return {}, {}
        end

        local condInput = MS.ParseCondBoxInput(condText)
        if #condInput.errors > 0 then
            GRIPEMS:Debug("ActionCompiler: IF cond parse error: " .. tostring(condInput.errors[1]))
            return {}, {}
        end

        local ifKids = type(node.children) == "table" and node.children or {}
        local trueBranch = type(ifKids[1]) == "table" and ifKids[1] or {}
        local falseBranch = type(ifKids[2]) == "table" and ifKids[2] or {}

        local function compileBranch(branch)
            local bSteps, bLabels = {}, {}
            for _, child in ipairs(branch) do
                local cs, cl = AC._compileNode(child, engine, depth + 1, ignoreInterleave)
                for i, step in ipairs(cs) do
                    bSteps[#bSteps + 1] = step
                    bLabels[#bSteps] = cl[i]
                end
            end
            return bSteps, bLabels
        end

        local tSteps, tLabels = compileBranch(trueBranch)
        local fSteps, fLabels = compileBranch(falseBranch)
        local N, M = #tSteps, #fSteps

        -- Per-line injection helper (spec section 8). Returns the rewritten
        -- line. Pass-through cases: empty string, comment line, or command
        -- not in the conditional-accepting catalog (spec section 6).
        local function injectLine(line, mode)
            if not line or line == "" then
                return line
            end
            if line:sub(1, 1) == "#" then
                return line
            end
            local cmd = line:match("^(/%S+)")
            if not cmd then
                -- Bare text payload: wrap as /cast.
                local injected = MS.InjectIntoOptions(line, condText, mode)
                return "/cast " .. injected
            end
            if not MS.IsCommandConditional(cmd) then
                GRIPEMS:Debug("ActionCompiler: IF non-conditional command passthrough: " .. cmd)
                return line
            end
            local rem = line:sub(#cmd + 2)
            local injected = MS.InjectIntoOptions(rem, condText, mode)
            if injected == "" then
                return cmd
            end
            return cmd .. " " .. injected
        end

        -- Path (a): both branches empty -- skip with debug.
        if N == 0 and M == 0 then
            GRIPEMS:Debug("ActionCompiler: IF both branches empty -- skipping")
            return {}, {}
        end

        local labels = {}

        -- Path (b): N=1, M=0 -- single-line with [C] injection on T.
        if N == 1 and M == 0 then
            local out = injectLine(tSteps[1], "and")
            labels[1] = node.label
            return { out }, labels
        end

        -- Path (c): N=0, M=1 -- single-line with [neg(C)] injection on F.
        if N == 0 and M == 1 then
            local out = injectLine(fSteps[1], "negated_and")
            labels[1] = node.label
            return { out }, labels
        end

        -- N=1, M=1 -- decide between path (d) single-line fall-through and
        -- path (e) two-line split.
        if N == 1 and M == 1 then
            local tLine, fLine = tSteps[1], fSteps[1]
            local tCmd = tLine:match("^(/%S+)")
            local fCmd = fLine:match("^(/%S+)")
            local effTCmd = tCmd or "/cast"
            local effFCmd = fCmd or "/cast"
            local tCondAccept = MS.IsCommandConditional(effTCmd)
            local fCondAccept = MS.IsCommandConditional(effFCmd)

            -- Path (d): same effective command, both conditional-accepting.
            if effTCmd == effFCmd and tCondAccept and fCondAccept then
                local tRem = tCmd and tLine:sub(#tCmd + 2) or tLine
                local fRem = fCmd and fLine:sub(#fCmd + 2) or fLine
                local injectedT = MS.InjectIntoOptions(tRem, condText, "and")
                -- When T's remainder has explicit brackets (targeting or
                -- nested condition), inject [neg(C)] into F too for clarity.
                -- When T is bare, semicolon fall-through naturally encodes
                -- the false branch -- byte-identical to the historical
                -- [nopet] Hunter form.
                local fOut
                if tRem:find("[", 1, true) then
                    fOut = MS.InjectIntoOptions(fRem, condText, "negated_and")
                else
                    fOut = fRem
                end
                local single
                if injectedT == "" then
                    single = effTCmd
                else
                    single = effTCmd .. " " .. injectedT
                end
                if fOut == "" then
                    -- Degenerate: F line collapses; just emit T form.
                    labels[1] = node.label
                    return { single }, labels
                end
                labels[1] = node.label
                return { single .. "; " .. fOut }, labels
            end

            -- Path (e): two-line split.
            local outT = injectLine(tLine, "and")
            local outF = injectLine(fLine, "negated_and")
            labels[1] = node.label
            labels[2] = fLabels[1]
            return { outT, outF }, labels
        end

        -- Path (f): per-step injection (default for any complex case).
        local steps = {}
        for i, line in ipairs(tSteps) do
            steps[#steps + 1] = injectLine(line, "and")
            labels[#steps] = tLabels[i]
        end
        for i, line in ipairs(fSteps) do
            steps[#steps + 1] = injectLine(line, "negated_and")
            labels[#steps] = fLabels[i]
        end
        if node.label and #steps > 0 then
            labels[1] = node.label
        end
        return steps, labels
    end

    -- Unknown type: skip
    GRIPEMS:Debug("ActionCompiler: unknown action type: " .. tostring(nodeType))
    return {}, {}
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
--- @return table warnings Array of warning strings (200-char approach, etc.)
function AC.ValidateActions(actions, depth)
    depth = depth or 1
    local errors = {}
    local warnings = {}

    if not actions or type(actions) ~= "table" then
        return true, errors, warnings
    end

    if depth > D.ACTION_MAX_DEPTH then
        errors[#errors + 1] = "Max nesting depth (" .. tostring(D.ACTION_MAX_DEPTH) .. ") exceeded"
        return false, errors, warnings
    end

    for i, node in ipairs(actions) do
        if type(node) ~= "table" or not node.type then
            errors[#errors + 1] = "Node " .. tostring(i) .. ": missing or invalid type"
        elseif node.type == D.ACTION_TYPE_ACTION then
            if node.macro ~= nil and type(node.macro) ~= "string" then
                errors[#errors + 1] = "Node " .. tostring(i) .. ": action macro has invalid type"
            elseif not node.macro or node.macro == "" then
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
            local repRaw = node["repeat"]
            local repTypeOk = repRaw == nil or type(repRaw) == "number"
            if not repTypeOk then
                errors[#errors + 1] = "Node " .. tostring(i) .. ": loop repeat has invalid type"
            end
            if node.children ~= nil and type(node.children) ~= "table" then
                errors[#errors + 1] = "Node " .. tostring(i) .. ": children field has invalid type"
            end
            local rep = repRaw or 0
            if not repTypeOk then
                -- Neutral in-range value: the invalid-type error above already
                -- reports this node; skip the redundant range error.
                rep = 1
            end
            if rep < 1 or rep > D.ACTION_LOOP_MAX_REPEAT then
                errors[#errors + 1] = "Node "
                    .. tostring(i)
                    .. ": loop repeat out of range (1-"
                    .. tostring(D.ACTION_LOOP_MAX_REPEAT)
                    .. ")"
            end
            local _, childErrors, childWarnings = AC.ValidateActions(node.children or {}, depth + 1)
            for _, e in ipairs(childErrors) do
                errors[#errors + 1] = e
            end
            for _, w in ipairs(childWarnings or {}) do
                warnings[#warnings + 1] = w
            end

            local loopOverflows, loopCapped = AC.InterleaveOverflows(node.children or {}, node, nil, depth)
            for _, f in ipairs(loopOverflows) do
                local fmt = L and L["GEMS_INTERLEAVE_OVERFLOW_LOOP_FMT"]
                if fmt then
                    warnings[#warnings + 1] = string.format(
                        fmt,
                        tostring(f.index),
                        tostring(f.interval),
                        tostring(f.baseCount),
                        tostring(f.baseCount),
                        tostring(f.suggestedRepeat),
                        tostring(f.interval)
                    )
                end
            end
            for _, c in ipairs(loopCapped) do
                local fmt = L and L["GEMS_INTERLEAVE_BUDGET_FMT"]
                if fmt then
                    warnings[#warnings + 1] = string.format(
                        fmt,
                        tostring(c.index),
                        tostring(AC.MAX_INTERLEAVE_INSERTED),
                        tostring(c.got),
                        tostring(c.want)
                    )
                end
            end
        elseif node.type == D.ACTION_TYPE_IF then
            local MS = GRIPEMS.MacroSyntax
            local varTypeOk = node.variable == nil or type(node.variable) == "string"
            if not varTypeOk then
                errors[#errors + 1] = "Node " .. tostring(i) .. ": if variable has invalid type"
            end
            if node.children ~= nil and type(node.children) ~= "table" then
                errors[#errors + 1] = "Node " .. tostring(i) .. ": children field has invalid type"
            end
            local condText = type(node.variable) == "string" and node.variable or ""
            local trimmed = condText:gsub("^%s+", ""):gsub("%s+$", "")
            if trimmed == "" then
                if varTypeOk then
                    errors[#errors + 1] = "Node " .. tostring(i) .. ": if has empty variable"
                end
            elseif MS then
                local condInput = MS.ParseCondBoxInput(trimmed)
                for _, msg in ipairs(condInput.errors) do
                    errors[#errors + 1] = "Node " .. tostring(i) .. ": " .. msg
                end
                if MS.ValidateAst then
                    for _, msg in ipairs(MS.ValidateAst(condInput.ast)) do
                        errors[#errors + 1] = "Node " .. tostring(i) .. ": " .. msg
                    end
                end
            end
            -- Spec section 11 rule 6: both branches empty is an error. Count
            -- enabled children only -- the compiler skips disabled nodes, so a
            -- branch holding nothing but disabled children compiles to zero
            -- steps and must trip the same error as a bare one.
            local vKids = type(node.children) == "table" and node.children or {}
            if vKids[1] ~= nil and type(vKids[1]) ~= "table" then
                errors[#errors + 1] = "Node " .. tostring(i) .. ": IF true branch has invalid type"
            end
            if vKids[2] ~= nil and type(vKids[2]) ~= "table" then
                errors[#errors + 1] = "Node " .. tostring(i) .. ": IF false branch has invalid type"
            end
            local tCount = 0
            for _, child in ipairs(type(vKids[1]) == "table" and vKids[1] or {}) do
                if type(child) ~= "table" or not child.disabled then
                    tCount = tCount + 1
                end
            end
            local fCount = 0
            for _, child in ipairs(type(vKids[2]) == "table" and vKids[2] or {}) do
                if type(child) ~= "table" or not child.disabled then
                    fCount = fCount + 1
                end
            end
            if tCount == 0 and fCount == 0 then
                errors[#errors + 1] = "Node " .. tostring(i) .. ": IF with no actions in either branch"
            end
            -- Spec section 11 rule 5: compiled-step length check.
            -- > 255 emits a hard error. 200 < len <= 255 emits a warning so
            -- the UI can surface a yellow indicator before the user crosses
            -- the hard cap. Two-tier signaling matches the live preview's
            -- char-count visual states.
            if MS and AC.CompileActions and trimmed ~= "" and (tCount > 0 or fCount > 0) then
                local compiledSteps = AC.CompileActions({ node }, nil)
                local ML = GRIPEMS.MacroLint
                for _, step in ipairs(compiledSteps) do
                    local len = MS.PreviewLength(step)
                    if len > 255 then
                        errors[#errors + 1] = "Node "
                            .. tostring(i)
                            .. ": compiled step exceeds 255 chars (length="
                            .. tostring(len)
                            .. ")"
                    elseif len > 200 then
                        warnings[#warnings + 1] = "Node "
                            .. tostring(i)
                            .. ": compiled step approaching 255 chars (length="
                            .. tostring(len)
                            .. ")"
                    end
                    -- Combat-blocked command check (spec section 11.6, Phase H2).
                    -- Warn-only; never blocks save. User may intentionally
                    -- gate with [nocombat] and ship anyway.
                    if ML then
                        local lintSev, lintFindings = ML.LintMacro(step)
                        if lintSev == "warn" and lintFindings and lintFindings[1] then
                            local fmt = L and L["GEMS_IF_LINT_COMBAT_BLOCKED_VALIDATE_FMT"]
                            if fmt then
                                warnings[#warnings + 1] = string.format(fmt, tostring(i), lintFindings[1].cmd)
                            end
                        end
                    end
                end
            end
            if type(node.children) == "table" then
                local _, trueErrors, trueWarnings = AC.ValidateActions(node.children[1] or {}, depth + 1)
                for _, e in ipairs(trueErrors) do
                    errors[#errors + 1] = e
                end
                for _, w in ipairs(trueWarnings or {}) do
                    warnings[#warnings + 1] = w
                end
                local _, falseErrors, falseWarnings = AC.ValidateActions(node.children[2] or {}, depth + 1)
                for _, e in ipairs(falseErrors) do
                    errors[#errors + 1] = e
                end
                for _, w in ipairs(falseWarnings or {}) do
                    warnings[#warnings + 1] = w
                end
            end
        elseif node.type == D.ACTION_TYPE_EMBED then
            if node.sequence ~= nil and type(node.sequence) ~= "string" then
                errors[#errors + 1] = "Node " .. tostring(i) .. ": embed sequence has invalid type"
            elseif not node.sequence or node.sequence == "" then
                errors[#errors + 1] = "Node " .. tostring(i) .. ": embed has empty sequence name"
            end
        elseif node.type == D.ACTION_TYPE_PAUSE then
            if node.clicks ~= nil and type(node.clicks) ~= "number" then
                errors[#errors + 1] = "Node " .. tostring(i) .. ": pause clicks has invalid type"
            end
        else
            errors[#errors + 1] = "Node " .. tostring(i) .. ": unknown type " .. tostring(node.type)
        end
    end

    if depth == 1 then
        local rootOverflows, rootCapped = AC.InterleaveOverflows(actions, nil)
        for _, f in ipairs(rootOverflows) do
            local fmt = L and L["GEMS_INTERLEAVE_OVERFLOW_ROOT_FMT"]
            if fmt then
                warnings[#warnings + 1] = string.format(
                    fmt,
                    tostring(f.index),
                    tostring(f.interval),
                    tostring(f.baseCount),
                    tostring(f.baseCount)
                )
            end
        end
        for _, c in ipairs(rootCapped) do
            local fmt = L and L["GEMS_INTERLEAVE_BUDGET_FMT"]
            if fmt then
                warnings[#warnings + 1] = string.format(
                    fmt,
                    tostring(c.index),
                    tostring(AC.MAX_INTERLEAVE_INSERTED),
                    tostring(c.got),
                    tostring(c.want)
                )
            end
        end
    end

    if depth == 1 and AC.CompilesEmptyDueToInterleave(actions) then
        errors[#errors + 1] =
            "Sequence has interleave actions but no base step; it compiles to zero steps. Turn off interleave on at least one action."
    end

    return #errors == 0, errors, warnings
end
