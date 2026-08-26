-- GRIP-EMS: Engine
-- Created: 2026-03-18
-- Updated: 2026-08-17
-- Patch: 12.1.0.69299 Midnight (Retail LIVE)

-- GRIP-EMS: Sequencer Engine
-- Core sequencer: SecureActionButton creation, step loading, activation, resets

local ADDON_NAME, GRIPEMS = ...
local L = LibStub("AceLocale-3.0"):GetLocale("GRIP-EMS", true)
local D = GRIPEMS.Defaults
local SF = GRIPEMS.StepFunctions
local MM = GRIPEMS.MacroManager
local KM = GRIPEMS.KeybindManager

-- Engine module: the heart of GRIP-EMS. Creates one SecureActionButton per
-- active sequence, loads step data into the restricted environment via
-- :Execute(), and wires up WrapScript OnClick body for step advancement.
-- Buttons start with type="macro" so the WrapScript only needs to swap
-- macrotext content (WoW silently blocks type attribute changes in the
-- restricted environment). An empty macrotext with type="macro" is a safe
-- no-op for sequences with no steps loaded yet.
-- Macro stubs (/click GRIPEMS_Name) trigger these buttons.
-- All button creation and attribute changes from insecure code go through
-- OOCQueue to respect combat lockdown restrictions.
GRIPEMS.Engine = {
    sequences = {}, -- name -> { button, data }
    currentContext = "none", -- active content context (T2-1)
    currentLoadoutID = nil, -- number? active configID (observation-only; Section 6.0)
    currentLoadoutName = nil, -- string? display name cache (observation-only; Section 6.0)
    currentLoadoutSpec = nil, -- number? specID (observation-only; Section 6.0)
    corruptSequences = {}, -- corrupt entries found during restore
    _buttonPressTimes = {}, -- rolling window for tempo overlay press rate
    BUTTON_PRESS_WINDOW = 10, -- seconds of press history to keep
}
local Engine = GRIPEMS.Engine

--- Resolve variables, fit keyPress/keyRelease per step, and expand via the
--- given expand function. Used by THREE arms of the compile branch in both
--- ActivateSequence and RecompileSequence: Priority, ReversePriority, and
--- every plugin-registered expander via SF:IsExpander. Only the fourth arm
--- reaches Engine:CompileSteps. Naming two of the three is what let the
--- empowerRelease gap be written up as smaller than it was.
--- @param engine table Engine instance (for SubstituteVariables)
--- @param steps table Array of step strings
--- @param kp string keyPress text (may be empty)
--- @param kr string keyRelease text (may be empty)
--- @param expandFunc function Called with resolved array, returns compiled steps
--- @return table Compiled steps from expandFunc
local function ResolveFitAndExpand(engine, steps, kp, kr, expandFunc)
    kp = (type(kp) == "string") and kp or ""
    kr = (type(kr) == "string") and kr or ""
    -- NO SHAPE TEST HERE, AND IT IS NAMED RATHER THAN LEFT SILENT. The ipairs on
    -- the next-but-one line raises on a number, a boolean AND a string, and this
    -- helper is where nine of the twelve activation and recompile compile
    -- branches route. It is invisible to every census pattern for the same
    -- reason the CompileSteps head was: no length operator, no field name, no
    -- receiver on any line above the loop.
    --
    -- A guard is NOT shipped here in 15u because it could not be reddened.
    -- Measured at fccd100: the only caller a suite reaches is
    -- RecompileSequence's base path, and Engine:2840 turns a scalar away before
    -- this helper is called; every other caller sits in ActivateSequence or a
    -- variant block, and unconditional-error probes in all three were silent
    -- across SET A, SET B and SET C. Ship target 15v, after a SET B fixture
    -- stubs enough of CreateFrame to walk ActivateSequence.
    -- Priority, ReversePriority and every plugin expander route through here and
    -- never touch CompileSteps, so without this they would publish no
    -- empowerRelease at all and the release would be dead on those step
    -- functions. Keyed by final text because the expanders copy strings out of
    -- resolved; duplicated entries share one text and therefore one release.
    -- Testable, contrary to what the phase 2-polish handoff claimed. This helper is
    -- file-local but RecompileSequence's base path reaches it, and the D-block in
    -- Test/test_stepadv_numsteps_domain.lua already drives that path with a Priority
    -- sequence. The stamping is asserted end to end by the S-block in the same file.
    local releaseByText = {}
    local resolved = {}
    for i, step in ipairs(steps) do
        local SC = GRIPEMS.SpellCache
        local stepText = (SC and SC.StepToString) and SC:StepToString(step) or tostring(step)
        -- IC-VAR-04: compile-time bake pass (variables matching approved
        -- macro-conditional shapes get rewritten to native [cond] X; Y
        -- macrotext BEFORE runtime variable substitution; rejected
        -- variables fall through to SubstituteVariables unchanged)
        local MCB = GRIPEMS.MacroConditionalBaker
        local prebakedText = (MCB and MCB:RewriteStepText(stepText)) or stepText
        resolved[i] = engine:SubstituteVariables(prebakedText)
        -- Phase 1-polish-4: strip out-of-range {spell:N} tokens that
        -- crash btn:Execute in the 12.0 restricted env. Pre-v2.1.5
        -- imports may have persisted bad IDs; we clean them at
        -- runtime so the restricted-env failure does not fire.
        if SC and SC.ScrubInvalidSpellTags then
            resolved[i] = SC:ScrubInvalidSpellTags(resolved[i])
        end
        local ownRelease = engine:EmpowerReleaseFor(resolved[i])
        local combined = resolved[i]
        if kp ~= "" then
            combined = kp .. "\n" .. combined
        end
        if kr ~= "" then
            combined = combined .. "\n" .. kr
        end
        if #combined <= D.MAX_SAB_MACROTEXT_LENGTH then
            resolved[i] = combined
        end
        releaseByText[resolved[i]] = ownRelease
    end
    return engine:StampEmpowerReleases(expandFunc(resolved), releaseByText)
end

--- Sanitize a sequence name for use as a global frame name.
--- Strips non-alphanumeric characters and replaces spaces with underscores.
--- @param name string Raw sequence name
--- @return string Sanitized name safe for global frame names
function Engine:SanitizeName(name)
    if not name then
        return "Unknown"
    end
    local sanitized = name:gsub("%s+", "_"):gsub("[^%w_]", "")
    if sanitized == "" then
        sanitized = "Unknown"
    end
    return sanitized
end

--- Substitute ~varname~ references in a macrotext string with evaluated values.
--- Variables are resolved via VariableStore:Evaluate(). Failed evaluations
--- are replaced with empty string and logged.
--- @param text string Raw macrotext with potential ~varname~ references
--- @return string Resolved macrotext with variables substituted
function Engine:SubstituteVariables(text)
    if type(text) ~= "string" then
        return text
    end
    if text == "" then
        return text
    end
    local VS = GRIPEMS.VariableStore
    if not VS then
        return text
    end

    return text:gsub(D.VAR_PATTERN, function(varName)
        local value, err = VS:Evaluate(varName)
        if value == nil then
            -- Fallback: check gear-aware variables
            local GV = GRIPEMS.GearVariables
            if GV then
                local gearValue = GV:Get(varName)
                if gearValue then
                    return tostring(gearValue)
                end
            end
            -- Fallback: plugin-registered variable providers (Plugin API Tier 4).
            -- The resolver pcall-isolates each provider and returns only a plain
            -- scalar (string/number/boolean); a table/function/userdata or secret
            -- return is rejected, so nothing taint-sensitive reaches macrotext.
            if GRIPEMS.ResolvePluginVariable then
                local pluginValue = GRIPEMS:ResolvePluginVariable(varName)
                if pluginValue ~= nil then
                    return tostring(pluginValue)
                end
            end
            if err and err ~= "Not found" then
                GRIPEMS:Debug(L["GEMS_VAR_EVAL_ERROR"], varName, tostring(err))
            end
            return ""
        end
        return tostring(value)
    end)
end

--- Resolve the empower release macrotext for one step's own resolved text.
--- Public because TWO compile paths need it and neither can see the other's
--- locals: Engine:CompileSteps for Sequential and Random, and the file-local
--- ResolveFitAndExpand for Priority, ReversePriority and every plugin
--- expander. Public also makes the lookup directly testable in isolation,
--- which is the cheap way to cover nil, empty, non-string and the tooltip
--- filter. CORRECTION to what this comment said at c99e392: it claimed no
--- suite reaches ResolveFitAndExpand. A suite DOES, through
--- RecompileSequence's base path, and the S-block in
--- Test/test_stepadv_numsteps_domain.lua now asserts the stamping there.
--- Detection is SC:IsEmpowerSpell only, which reads the set the spellbook
--- walk built from C_Spell.IsPressHoldReleaseSpell.
--- @param text string|nil A single step's resolved macrotext
--- @return string The release macrotext, or "" when the step casts no empower
function Engine:EmpowerReleaseFor(text)
    if type(text) ~= "string" or text == "" then
        return ""
    end
    local SC = GRIPEMS.SpellCache
    local SVv = GRIPEMS.SpellValidator
    if not (SC and SC.IsEmpowerSpell and SVv and SVv.ExtractAllSpells) then
        return ""
    end
    for _, ex in ipairs(SVv:ExtractAllSpells(text)) do
        if ex.command ~= "showtooltip" then
            local numeric = tonumber(ex.name)
            local id = numeric or (SC.GetSpellID and SC:GetSpellID(ex.name))
            if id and SC:IsEmpowerSpell(id) then
                -- A macro cannot cast by numeric id, so a numeric token has
                -- to resolve to a name or the release is skipped entirely.
                local castName = ex.name
                if numeric then
                    castName = SC.RecoverSpellName and SC:RecoverSpellName(numeric) or nil
                end
                if castName and castName ~= "" then
                    return "/cast [nochanneling] " .. castName
                end
            end
        end
    end
    return ""
end

--- Stamp empowerRelease onto expander output. The expanders copy strings
--- OUT of the resolved array, so every output macrotext is a key in the map
--- the caller built from that same array. A plugin expander that invents a
--- string is not in the map and gets "", which is the correct fail-safe:
--- an unknown text must never arm a release.
--- @param out table|nil Array of attribute tables from an expander
--- @param releaseByText table|nil Map of resolved text -> release macrotext
--- @return table|nil The same array, stamped in place
function Engine:StampEmpowerReleases(out, releaseByText)
    if type(out) ~= "table" then
        return out
    end
    for i = 1, #out do
        local entry = out[i]
        if type(entry) == "table" then
            local key = entry.macrotext
            local rel = nil
            if type(releaseByText) == "table" and type(key) == "string" then
                rel = releaseByText[key]
            end
            entry.empowerRelease = rel or ""
        end
    end
    return out
end

--- Compile raw string steps into attribute table format.
--- Performs variable substitution (~varname~) before compiling.
--- When keyPress/keyRelease are provided, each step's macrotext is combined
--- with keyPress/keyRelease IF the total fits within 255 chars. Steps that
--- exceed the limit get only the resolved step text (keyPress fires only via
--- action bar macro stub clicks for those steps).
--- @param steps table Array of macro text strings
--- @param keyPress string|nil KeyPress block to prepend per step
--- @param keyRelease string|nil KeyRelease block to append per step
--- @return table Array of attribute tables (e.g. {type="macro", macrotext="..."})
function Engine:CompileSteps(steps, keyPress, keyRelease)
    -- SHAPE TEST, NOT A TRUTHINESS TEST, and this site is the reason the
    -- .steps residue list in Test/test_malformed_entry_guards.lua:6089 said
    -- eight when it should have said more. The old head was
    -- "if not steps then", which contains no "#", no field name and no
    -- length operator, so BARE_NOTLEN, BARE_LEN, BARE_PAREN and every
    -- field-keyed shape in the census are all structurally blind to it. It
    -- was never triaged because nothing could see it, not because anyone
    -- decided it was safe.
    --
    -- MEASURED at 914109d, one pcall per shape against the real Engine.lua:
    --   CompileSteps(5)      Engine/Engine.lua:162: attempt to get length of
    --                        local 'steps' (a number value)
    --   CompileSteps(true)   Engine/Engine.lua:162: ... (a boolean value)
    --   CompileSteps("abc")  Engine/Engine.lua:163: bad argument #1 to
    --                        'ipairs' (table expected, got string)
    --   CompileSteps(table)  ok
    --   CompileSteps(nil)    ok, absorbed by the old gate
    --
    -- THREE shapes raise, not two, and the string is the one that explains
    -- the fix. "#" on a string is legal and returns its byte length, so a
    -- string walks past any length test and dies at the ipairs one line
    -- later. Tightening the truthiness test would not have caught it; only
    -- a type test does.
    if type(steps) ~= "table" then
        return {}
    end
    local kp = (type(keyPress) == "string") and keyPress or ""
    local kr = (type(keyRelease) == "string") and keyRelease or ""
    local compiled = {}
    local fitted = 0
    local total = #steps
    for i, stepText in ipairs(steps) do
        local SC = GRIPEMS.SpellCache
        local stepStr = (SC and SC.StepToString) and SC:StepToString(stepText) or tostring(stepText)
        -- IC-VAR-04: compile-time bake pass (see ResolveFitAndExpand)
        local MCB = GRIPEMS.MacroConditionalBaker
        local prebakedStr = (MCB and MCB:RewriteStepText(stepStr)) or stepStr
        local resolved = self:SubstituteVariables(prebakedStr)
        -- Phase 1-polish-4: strip out-of-range {spell:N} tokens that
        -- crash btn:Execute in the 12.0 restricted env. Pre-v2.1.5
        -- imports may have persisted bad IDs; we clean them at
        -- runtime so the restricted-env failure does not fire.
        if SC and SC.ScrubInvalidSpellTags then
            resolved = SC:ScrubInvalidSpellTags(resolved)
        end
        local combined
        if kp ~= "" and kr ~= "" then
            combined = kp .. "\n" .. resolved .. "\n" .. kr
        elseif kp ~= "" then
            combined = kp .. "\n" .. resolved
        elseif kr ~= "" then
            combined = resolved .. "\n" .. kr
        else
            combined = resolved
        end
        if #combined <= D.MAX_SAB_MACROTEXT_LENGTH then
            compiled[i] = { type = D.ATTR_TYPE_MACRO, macrotext = combined }
            if kp ~= "" or kr ~= "" then
                fitted = fitted + 1
            end
        else
            compiled[i] = { type = D.ATTR_TYPE_MACRO, macrotext = resolved }
        end
        -- Per-step empower release text, computed from the step's OWN resolved text
        -- rather than from combined: a keyPress carrying an empowered spell must not
        -- win over the spell the step itself casts. Published on EVERY step, empty
        -- when the step casts no empowered spell, so the click body's pairs() walk
        -- always overwrites it.
        compiled[i].empowerRelease = self:EmpowerReleaseFor(resolved)
        -- Display-domain counterpart to empowerRelease: the step's OWN resolved text,
        -- never the combined text above. Same reason -- a keyPress line must not win
        -- over the spell the step itself casts -- applied to what the player SEES.
        -- Published on EVERY step, on both the fitted and the overflow branch, so a
        -- consumer never has to ask which branch produced this entry.
        compiled[i].stepOwnText = resolved
    end
    if (kp ~= "" or kr ~= "") and fitted < total then
        GRIPEMS:Print(L["GEMS_WARN_KP_STEP_OVERFLOW"]:format(fitted, total, total - fitted))
    end
    return compiled
end

--- Pure test: do ALL steps bake keyPress/keyRelease into their per-step
--- macrotext within the 255-char cap? When true, the macro stub does NOT
--- need to embed keyPress/keyRelease -- the per-step button already carries
--- them on both keybind and /click. Mirrors the per-step bake in
--- CompileSteps; keep the transform in sync with that loop.
--- @param steps table Array of step strings
--- @param kp string keyPress block (may be empty)
--- @param kr string keyRelease block (may be empty)
--- @return boolean true if the stub can safely omit keyPress/keyRelease
function Engine:AllStepsBakeKpKr(steps, kp, kr)
    kp = (type(kp) == "string") and kp or ""
    kr = (type(kr) == "string") and kr or ""
    if kp == "" and kr == "" then
        return true
    end
    if type(steps) ~= "table" or #steps == 0 then
        return false
    end
    local SC = GRIPEMS.SpellCache
    local MCB = GRIPEMS.MacroConditionalBaker
    for _, step in ipairs(steps) do
        local stepStr = (SC and SC.StepToString) and SC:StepToString(step) or tostring(step)
        local prebaked = (MCB and MCB:RewriteStepText(stepStr)) or stepStr
        local resolved = self:SubstituteVariables(prebaked)
        if SC and SC.ScrubInvalidSpellTags then
            resolved = SC:ScrubInvalidSpellTags(resolved)
        end
        local combined = resolved
        if kp ~= "" then
            combined = kp .. "\n" .. combined
        end
        if kr ~= "" then
            combined = combined .. "\n" .. kr
        end
        if #combined > D.MAX_SAB_MACROTEXT_LENGTH then
            return false
        end
    end
    return true
end

--- Build the execution-order list of resolved macrotext strings for a steps array under
--- a step function. Side-effect-free: no writes to Engine or sequence state. Returns the
--- execOrder array plus an isRandom flag (Random order is nondeterministic; callers list
--- each step once). Extracted from SimulateSteps so the icon preview and the public step
--- accessor share one expansion path.
--- @param steps table Array of step text/tables
--- @param stepFunction string Step-function name
--- @return table execOrder Resolved macrotext strings in execution order
--- @return boolean isRandom True when stepFunction is Random
function Engine:BuildExecutionOrder(steps, stepFunction)
    local execOrder = {}
    -- Measured at 914109d: a number and a boolean raise on this line's own
    -- "#steps"; a string passes it, because "#" on a string is legal, and
    -- raises at the ipairs on :263 instead. One type test closes all three.
    -- The three production callers (Engine:474, Engine:2226, Engine:2256) all
    -- hand over ver.steps or a local bound straight off it and none dereferences
    -- it first, so the callee owns the first read on every path and one guard
    -- here covers them all. A fourth in-file caller, Engine:375, is
    -- Engine:SimulateSteps handing on its own argument; it carries the identical
    -- guard one frame up, so a scalar cannot reach here through it.
    --
    -- The :254 and :263 above are frozen quotes from the pre-fix run and stay
    -- pinned to 914109d. The caller numbers are CURRENT-TREE pointers, READ at
    -- their own line's text: :375 and :474 moved +22, :2226 and :2256 moved +46.
    --
    -- 15u CORRECTION, recorded rather than silently fixed. 15t wrote 445, 2171,
    -- 2201 and 346 here and stated they had been re-read after the shift. They
    -- had not. They were the pre-15t numbers plus +34 and +47, where the real
    -- shifts were +41 and +56, and at fccd100 each of the four landed on an
    -- unrelated line -- 445 on an "@param" doc line, 2171 on "if cached then",
    -- 2201 on a bare "end", and 346 inside the SimulateSteps comment 15t itself
    -- had just written. A pointer is checked by reading the line it points at.
    -- Nothing else counts, and adding an offset is not reading.
    if type(steps) ~= "table" or #steps == 0 then
        return execOrder, false
    end

    local SC = GRIPEMS.SpellCache
    local sf = stepFunction or "Sequential"

    -- Resolve variables in all steps first
    local resolvedSteps = {}
    for i, stepText in ipairs(steps) do
        local stepStr = (SC and SC.StepToString) and SC:StepToString(stepText) or tostring(stepText)
        resolvedSteps[i] = self:SubstituteVariables(stepStr)
    end

    -- Build the execution order based on step function
    if sf == "Priority" then
        local expanded = SF:ExpandPriority(resolvedSteps)
        for _, entry in ipairs(expanded) do
            execOrder[#execOrder + 1] = entry.macrotext or ""
        end
    elseif sf == "ReversePriority" then
        local expanded = SF:ExpandReversePriority(resolvedSteps)
        for _, entry in ipairs(expanded) do
            execOrder[#execOrder + 1] = entry.macrotext or ""
        end
    elseif SF:IsExpander(sf) then
        local expanded = SF:RunExpander(sf, resolvedSteps)
        for _, entry in ipairs(expanded) do
            execOrder[#execOrder + 1] = entry.macrotext or ""
        end
    elseif sf == "Random" then
        -- Random: order is nondeterministic. Hand back the resolved steps in authored
        -- order with the isRandom flag so callers list each step exactly once.
        return resolvedSteps, true
    else
        -- Sequential: just use resolvedSteps directly
        execOrder = resolvedSteps
    end

    return execOrder, false
end

--- Simulate N keypresses over an explicit steps list and return the step order
--- with spell info. Used by the icon strip preview UI. Side-effect-free (no writes
--- to Engine state). Callers pass the steps + stepFunction directly so the preview
--- can simulate a compiled tree without mutating the stored version.
--- @param steps table Array of step text/tables in execution order
--- @param stepFunction string Step-function name (Sequential, Priority, ...)
--- @param count number Number of keypresses to simulate (default 20)
--- @return table Array of { stepIndex, macrotext, spellName, iconID, spellStatus, isRandom }
function Engine:SimulateSteps(steps, stepFunction, count)
    count = count or 20
    local result = {}
    -- Same three shapes, same split: :307 for a number and a boolean, :263
    -- via BuildExecutionOrder for a string. Measured at 914109d. The single
    -- production caller is UI/SequenceEditor.lua:6443, which passes
    -- ver.steps without reading a field off it first.
    if type(steps) ~= "table" or #steps == 0 then
        return result
    end

    local SC = GRIPEMS.SpellCache
    local execOrder, isRandom = self:BuildExecutionOrder(steps, stepFunction)

    if isRandom then
        -- Random: cannot predict order. Return each unique step once
        -- with a flag indicating random selection
        for i, resolved in ipairs(execOrder) do
            local spellName = SC and SC.ParseSpellFromMacrotext and SC:ParseSpellFromMacrotext(resolved) or nil
            local iconID = spellName and SC and SC.GetIcon and SC:GetIcon(spellName) or nil
            -- Check spell validity if SpellValidator available
            local spellStatus = nil
            local SV = GRIPEMS.SpellValidator
            if SV and SV.ValidateSpell and spellName then
                local valResult = SV:ValidateSpell(spellName, "cast")
                spellStatus = valResult.status
                if not iconID then
                    iconID = valResult.icon
                end
            end
            result[#result + 1] = {
                stepIndex = i,
                macrotext = resolved,
                spellName = spellName,
                iconID = iconID,
                spellStatus = spellStatus,
                isRandom = true,
            }
        end
        return result
    end

    -- Generate count simulated keypresses (round-robin over execOrder)
    local totalSteps = #execOrder
    if totalSteps == 0 then
        return result
    end
    for press = 1, count do
        local idx = ((press - 1) % totalSteps) + 1
        local macrotext = execOrder[idx]
        local spellName = SC and SC.ParseSpellFromMacrotext and SC:ParseSpellFromMacrotext(macrotext) or nil
        local iconID = spellName and SC and SC.GetIcon and SC:GetIcon(spellName) or nil
        local spellStatus = nil
        local SV = GRIPEMS.SpellValidator
        if SV and SV.ValidateSpell and spellName then
            local valResult = SV:ValidateSpell(spellName, "cast")
            spellStatus = valResult.status
            if not iconID then
                iconID = valResult.icon
            end
        end
        result[#result + 1] = {
            stepIndex = idx,
            macrotext = macrotext,
            spellName = spellName,
            iconID = iconID,
            spellStatus = spellStatus,
            isRandom = false,
        }
    end
    return result
end

-- Resolve a flat macrotext array into the public per-step snapshot shape
-- ({ index, spellID, spellName, icon }). Shared by GetActiveVersionStepList
-- (EXECUTION domain) and GetAuthoredStepList (AUTHORED domain) so the two
-- accessors can never drift in shape. nil-safe on SpellCache (headless).
local function ResolveStepSnapshots(macroArray, classID)
    local SC = GRIPEMS.SpellCache
    local out = {}
    for i = 1, #macroArray do
        local macrotext = macroArray[i]
        local spellName, spellID, icon
        if SC and SC.ParseSpellFromMacrotext then
            spellName = SC:ParseSpellFromMacrotext(macrotext)
        end
        if spellName and SC then
            if SC.GetSpellID then
                spellID = SC:GetSpellID(spellName, classID)
            end
            if SC.GetIcon then
                icon = SC:GetIcon(spellName)
            end
        end
        out[i] = { index = i, spellID = spellID, spellName = spellName, icon = icon }
    end
    return out
end

--- Per-step spell data for a sequence's ACTIVE version, in execution order. Side-effect
--- free. Returns a fresh array of { index, spellID, spellName, icon }; a step that casts
--- no resolvable spell still gets an entry (nil spell fields) so the index stays aligned
--- with the secure button. nil-safe on SpellCache (headless / pre-build). All values are
--- public scalars.
--- @param seqData table Sequence data (versioned format)
--- @return table Array of per-step { index, spellID, spellName, icon }
function Engine:GetActiveVersionStepList(seqData)
    local ver = self:GetActiveVersion(seqData)
    if not ver or type(ver.steps) ~= "table" then
        return {}
    end
    local execOrder = self:BuildExecutionOrder(ver.steps, ver.stepFunction)
    local classID = seqData and seqData.classID or nil
    return ResolveStepSnapshots(execOrder, classID)
end

--- Read-only per-step spell data for a sequence's ACTIVE version in AUTHORED base
--- order: interleave copies suppressed and the version repeatCount not applied.
--- Loops are unrolled and IF branches flattened, so this is the authored BASE
--- ORDER, not the action tree. Same per-index shape as GetActiveVersionStepList.
--- @param seqData table Sequence data (versioned format)
--- @return table Array of per-step { index, spellID, spellName, icon }
function Engine:GetAuthoredStepList(seqData)
    local ver = self:GetActiveVersion(seqData)
    if not ver then
        return {}
    end
    local AC = GRIPEMS.ActionCompiler
    local authoredArray
    if
        type(ver.actions) == "table"
        and #ver.actions > 0
        and not ver.importBakedSteps
        and AC
        and AC.CompileAuthoredActions
    then
        -- Live action tree present: recompile the AUTHORED base order (interleave
        -- copies suppressed, version repeatCount not applied). Never returns the
        -- interleave-injected ver.steps in this path.
        authoredArray = AC.CompileAuthoredActions(ver.actions, self)
    else
        -- Legacy version with no action tree, an import whose steps were baked, or
        -- a headless harness with no ActionCompiler: ver.steps IS the authored array.
        authoredArray = ver.steps
    end
    if type(authoredArray) ~= "table" then
        return {}
    end
    local classID = seqData and seqData.classID or nil
    return ResolveStepSnapshots(authoredArray, classID)
end

--- Build the Execute() string that creates the steps table in the restricted
--- environment. Each step is a newtable() with string-keyed attribute pairs.
--- Uses long bracket strings [=======[...]=======] for values to safely embed
--- any macro text without escaping issues.
--- @param compiledSteps table Array of attribute tables ({type=X, macrotext=Y})
--- @return string Lua code string for btn:Execute()
function Engine:BuildExecuteString(compiledSteps)
    -- Measured at 914109d: :459 for a number and a boolean, :463 for a
    -- string, which passes the length test and dies at the ipairs.
    --
    -- WHAT THE CALLERS DO AND DO NOT PROVE. The four in-file call sites are
    -- Engine:1513, :1777, :2873 and :2930, plus Engine/TempoAdvisor.lua:288 --
    -- CURRENT-TREE pointers READ at each line's own text. All four sit below
    -- 15u's :1278 band edge, a 15t-TREE number, so all four moved +46. :459 and :463 stay at 914109d.
    --
    -- 15t said all five "pass a local that came out of CompileSteps". They do
    -- not. Three of the four in-file sites are fed by a FOUR-ARM branch whose
    -- first THREE arms call ResolveFitAndExpand:
    --     :1497 :1501 :1505 ResolveFitAndExpand   :1509 CompileSteps
    --     :2858 :2862 :2866 ResolveFitAndExpand   :2870 CompileSteps
    --     :2916 :2920 :2924 ResolveFitAndExpand   :2928 CompileSteps
    -- Nine of the twelve assignments come from ResolveFitAndExpand, and what
    -- lands in compiledSteps on those branches is whatever the expander returns.
    -- CompileSteps' return contract says nothing about them.
    --
    -- SO WHAT IS ACTUALLY TRUE, measured at fccd100 with unconditional-error
    -- probes rather than read off the source:
    --   RecompileSequence's base path IS reached by SET A and IS safe, because
    --   Engine:2840 turns a scalar ver.steps away before stepsToLoad is bound.
    --   Driving the real RecompileSequence with ver.steps = 5, true and "abc"
    --   returns cleanly on all three.
    --   ActivateSequence is NOT ENTERED past :1315 by ANY suite -- a bare print
    --   at :1324 was silent across SET A 18/18, SET B 46 files and SET C -- so
    --   its call at :1513 is covered by no test and every claim about it is a
    --   source read.
    -- Recording the difference matters: a later caller that stops routing
    -- through CompileSteps inherits this guard, and a reader who assumes "no
    -- caller can" means "no test can" would delete it.
    if type(compiledSteps) ~= "table" or #compiledSteps == 0 then
        return "steps = newtable()\nnumSteps = 0\n"
    end
    local parts = { "steps = newtable()\n" }
    for i, stepData in ipairs(compiledSteps) do
        parts[#parts + 1] = "steps[" .. i .. "] = newtable()\n"
        if type(stepData) == "table" then
            for k, v in pairs(stepData) do
                parts[#parts + 1] = "steps["
                    .. i
                    .. ']["'
                    .. tostring(k)
                    .. '"] = [=======['
                    .. tostring(v)
                    .. "]=======]\n"
            end
        end
    end
    parts[#parts + 1] = "numSteps = " .. #compiledSteps .. "\n"
    return table.concat(parts)
end

--- Restricted-env brace guard (ARENA-RELOAD-ISSUE). Blizzard's
--- RestrictedExecution rejects ANY literal { or } in a secure body (even
--- inside long-bracket literals) with "Direct table creation is not
--- permitted". The brace almost always comes from a {spell:N} token that
--- could not resolve to a name. Root cause is token resolution, NOT a
--- SpellCache-settling timing race: on 12.0 a packed hero-talent override
--- handle from C_SpellBook.FindSpellOverrideByID is in-range but has no
--- name, so the tag is PERMANENTLY unresolvable (SC:IsResolvableSpellID
--- now keeps the spell name instead of emitting such a tag). This guard
--- is retained as defense-in-depth: a braced body must never reach the
--- secure env. When a brace is present, skip the :Execute, record a
--- trace, and schedule a capped reload via the existing RecompileSequence.
---
--- State is keyed per sequence name AND per physical button slot ("base",
--- "v2", ...). A clean sibling button clears only its OWN slot, so it can no
--- longer wipe a braced sibling's attempts counter -- the mixed braced/clean
--- bug where the cap was unreachable and the reload looped every ~3s forever.
--- Scheduling stays per-sequence: one RecompileSequence rebuilds every button,
--- so multiple braced buttons in a single pass schedule a single reload, not
--- one timer each. Each braced slot caps independently at
--- BRACE_RELOAD_MAX_ATTEMPTS, after which it stays deferred (keybind left
--- unloaded -- safe) and records exactly one "brace-permanent" trace. Capped
--- sequences self-heal on the next SPELL_CACHE_REFRESHED via
--- RetryCappedBraceReloads.
--- @param name string Sequence name
--- @param btn table The secure button (unused except for symmetry/logging)
--- @param execStr string The execStr about to be loaded
--- @param compiledSteps table|nil Compiled steps array
--- @param label string Call-site label (human-facing, recorded in the trace)
--- @param slot string Path-independent button slot ("base" / "v"..N). Keys the
---        attempts counter so base/recompile and variant/recompile-variant for
---        the SAME physical button share one counter.
--- @return boolean true if a brace was found and the load was deferred
function Engine:DeferIfBraced(name, btn, execStr, compiledSteps, label, slot)
    if type(execStr) ~= "string" then
        return false
    end
    local slotKey = slot or "base"
    local bracePos = execStr:find("[{}]")
    if not bracePos then
        -- Clean button: clear ONLY this slot's counter, never a braced
        -- sibling's. Prune the sequence entry once it is fully clean and idle.
        local st = self._braceReload and self._braceReload[name]
        if st and st.slots then
            st.slots[slotKey] = nil
            if not st.scheduled and not next(st.slots) then
                self._braceReload[name] = nil
            end
        end
        return false
    end
    if GRIPEMS.Trace then
        GRIPEMS.Trace:RecordExecuteFailure(name, execStr, bracePos, compiledSteps, label, "brace")
    end
    self._braceReload = self._braceReload or {}
    local st = self._braceReload[name]
    if not st then
        st = { scheduled = false, slots = {} }
        self._braceReload[name] = st
    end
    local ss = st.slots[slotKey]
    if not ss then
        ss = { attempts = 0, permanent = false }
        st.slots[slotKey] = ss
    end
    if ss.attempts >= (D.BRACE_RELOAD_MAX_ATTEMPTS or 3) then
        -- This slot has exhausted its reloads: stay deferred (keybind unloaded
        -- is the safe state) and record brace-permanent exactly once.
        if not ss.permanent then
            ss.permanent = true
            if GRIPEMS.Trace then
                GRIPEMS.Trace:RecordExecuteFailure(name, execStr, bracePos, compiledSteps, label, "brace-permanent")
            end
        end
        return true
    end
    ss.attempts = ss.attempts + 1
    -- One reload timer per pass: the first braced slot schedules; later braced
    -- slots in the same RecompileSequence pass piggyback on it.
    if not st.scheduled then
        st.scheduled = true
        local delay = (D.SPELL_CACHE_VALIDATION_RETRY_DELAY or 2.5) + (D.BRACE_RELOAD_MARGIN or 0.5)
        C_Timer.After(delay, function()
            st.scheduled = false
            if self.sequences[name] then
                self:RecompileSequence(name)
            end
        end)
    end
    return true
end

--- Self-heal braced sequences once SpellCache settles. A previously
--- unresolvable {spell:N} token may now resolve, so re-queue EVERY sequence
--- with a pending braced slot -- capped OR mid-retry -- and fire one
--- RecompileSequence each to reload the steps. Broadened 2026-06-23
--- (Daxomault context-switch bug, Discord 1518712692708348005): the old
--- capped-only selection skipped an entry still mid-retry on the same refresh
--- that resolved its spell, which then capped with no later refresh to catch
--- it. Names are collected before mutating so the pairs walk is not modified
--- in place. Name kept (callers + the SPELL_CACHE_REFRESHED handler use it).
--- @return number Count of sequences re-queued for recompile
function Engine:RetryCappedBraceReloads()
    local br = self._braceReload
    if not br then
        return 0
    end
    -- Broadened 2026-06-23 (Daxomault context-switch bug, Discord thread
    -- 1518712692708348005): retry EVERY sequence with a pending braced slot,
    -- not only those that exhausted their own retry timers. A spell-cache
    -- refresh is exactly when a previously unresolvable {spell:N} token may
    -- now resolve; the old capped-only gate skipped a brace entry that was
    -- still mid-retry on the same refresh that resolved its spell, then it
    -- capped with no later refresh to catch it -- the live context-switch
    -- "wrong version until /reload" signature.
    local toRetry
    for name, st in pairs(br) do
        if st and st.slots and next(st.slots) then
            toRetry = toRetry or {}
            toRetry[#toRetry + 1] = name
        end
    end
    if not toRetry then
        return 0
    end
    for _, name in ipairs(toRetry) do
        br[name] = nil
        if self.sequences[name] then
            self:RecompileSequence(name)
        end
    end
    return #toRetry
end

--- Return the active version table for a sequence.
--- Single indirection point for all version access. Context-aware (T2-1):
--- checks contextOverrides + fallback chain before defaultVersion.
--- @param seqData table Sequence data (versioned format)
--- @return table|nil The active version table, or nil if none
function Engine:GetActiveVersion(seqData)
    -- type(), not truthiness. Corrupt data (bad import, hand-edited
    -- SavedVariables) can leave a scalar in seqData.versions, and this function
    -- INDEXES that field at four sites below -- the pin read, the direct context
    -- read, the fallback-chain read, and the default resolution. A bare
    -- "not seqData.versions" head check let all four run against a non-table:
    -- measured, a number or boolean raised "attempt to index field 'versions'"
    -- at the default resolution. A string is the tolerant shape -- it indexes to
    -- nil through the string metatable -- so a length check is not an adequate
    -- model here either.
    --
    -- This is the single indirection point for version access, so the blast
    -- radius was every caller: GE.BuildExportList (Import/ExportPreview.lua:43)
    -- resolves the active version for EVERY stored sequence, which meant one
    -- corrupt entry failed the whole export dialog before its own row was
    -- reached. The type() guards in that function could not help -- the raise
    -- happened upstream of them, in here.
    --
    -- Matches the sibling guard already present at Engine:GetActiveVersionIndex
    -- below. nil is the same answer this function already gives for an absent
    -- versions field, so no caller sees a new shape.
    if not seqData or type(seqData.versions) ~= "table" then
        return nil
    end

    -- Pin precedence (LIVE-VERSION-QUICK-SWAP): a user-set pin wins over context
    -- overrides and defaultVersion until cleared. An out-of-range pin falls
    -- through to the resolution below (never clamped here), so a stale pin can
    -- never strand a sequence.
    local pin = tonumber(seqData.pinnedVersion) or seqData.pinnedVersion
    if pin and seqData.versions[pin] then
        return seqData.versions[pin]
    end

    -- Context resolution (T2-1)
    local overrides = seqData.contextOverrides
    if overrides and Engine.currentContext ~= D.CONTEXT_NONE then
        local ctx = Engine.currentContext
        -- Direct match
        local idx = tonumber(overrides[ctx]) or overrides[ctx]
        if idx and seqData.versions[idx] then
            return seqData.versions[idx]
        end
        -- Fallback chain
        local fallbacks = D.CONTEXT_FALLBACKS[ctx]
        if fallbacks then
            for _, fbKey in ipairs(fallbacks) do
                idx = tonumber(overrides[fbKey]) or overrides[fbKey]
                if idx and seqData.versions[idx] then
                    return seqData.versions[idx]
                end
            end
        end
    end

    -- Default fallback
    local idx = tonumber(seqData.defaultVersion) or seqData.defaultVersion or 1
    return seqData.versions[idx] or seqData.versions[1]
end

--- Return the active version index for a sequence under the current context.
--- Kept separate from GetActiveVersion so runtime reload code can compare the
--- version actually loaded into the secure button against the version that the
--- current context resolves to.
--- @param seqData table Sequence data (versioned format)
--- @param resolvedVer table|nil Optional version table already returned by GetActiveVersion
--- @return number|nil Active version index, or nil when unresolved
function Engine:GetActiveVersionIndex(seqData, resolvedVer)
    if not seqData or type(seqData.versions) ~= "table" then
        return nil
    end
    resolvedVer = resolvedVer or self:GetActiveVersion(seqData)
    if not resolvedVer then
        return nil
    end
    for vi, v in ipairs(seqData.versions) do
        if v == resolvedVer then
            return vi
        end
    end
    return nil
end

--- Apply the active version's out-of-combat runtime attributes to existing
--- secure buttons without replacing the button object. This is important for
--- context switches: keybind/action routing can still point at the existing
--- SecureActionButton until the binding matrix is rebuilt, so the safest first
--- step is to refresh that button in place.
--- @param entry table Engine.sequences entry
--- @param ver table Active version table
function Engine:_ApplyVersionRuntimeAttributes(entry, ver)
    if not entry or not ver then
        return
    end
    local resetTimer = ver.resetTimer or 0
    local seqResetMods = ver.resetModifiers
    local globalMods = GRIPEMS.Settings:GetResetModifiers()
    local resetMods
    if seqResetMods then
        resetMods = {}
        for mod, default in pairs(globalMods) do
            if seqResetMods[mod] ~= nil then
                resetMods[mod] = seqResetMods[mod]
            else
                resetMods[mod] = default
            end
        end
    else
        resetMods = globalMods
    end

    local htf = GRIPEMS.Settings:GetHoldToFreeze()

    local function apply(btn, variantModifier)
        if not btn then
            return
        end
        btn:SetAttribute("step", 1)
        btn:SetAttribute("resetTimer", resetTimer)
        btn:SetAttribute("_shouldReset", "0")
        for mod, enabled in pairs(resetMods) do
            btn:SetAttribute("resetMod_" .. mod, enabled and "1" or nil)
        end
        -- Per-version channel hold. Applied inside this closure so the base button
        -- and every variant button pick it up from the one resolved version.
        -- empowerRelease is a PER-STEP attribute written only by a step commit, so
        -- it is cleared alongside every releaseAtMax publish; see the invariant note
        -- at the UpdateSequenceData site, which is the one the stale-release defect
        -- ran through.
        btn:SetAttribute("holdOnChannel", ver.holdOnChannel and "1" or nil)
        btn:SetAttribute("releaseAtMax", ver.releaseAtMax and "1" or nil)
        btn:SetAttribute("empowerRelease", nil)
        local arm = htf.enabled
        if variantModifier and variantModifier == htf.modifier then
            arm = false
        end
        btn:SetAttribute("freezeArmed", arm and "1" or nil)
        btn:SetAttribute("freezeMod", htf.modifier)
    end

    apply(entry.button, nil)
    if entry.variantButtons then
        for _, vb in pairs(entry.variantButtons) do
            apply(vb, vb.variantModifier)
        end
    end
end

--- Migrate a flat-format seqData to the versioned format.
--- If seqData already has a non-empty versions table, returns it unchanged.
--- Otherwise wraps top-level fields into versions[1] and removes the flat fields.
--- @param seqData table Sequence data (flat or versioned)
--- @return table The migrated seqData (same reference, mutated in-place)
function Engine:MigrateSequenceFormat(seqData)
    if not seqData then
        return seqData
    end
    -- Already versioned: has non-empty versions table
    if seqData.versions and type(seqData.versions) == "table" and next(seqData.versions) then
        return seqData
    end

    -- Wrap flat fields into versions[1]
    local ver = {
        steps = seqData.steps or {},
        stepFunction = seqData.stepFunction or "Sequential",
        resetOnCombat = seqData.resetOnCombat or false,
        resetOnTarget = seqData.resetOnTarget or false,
        resetOnGear = seqData.resetOnGear or false,
        resetOnSpec = seqData.resetOnSpec or false,
        resetTimer = seqData.resetTimer or 0,
    }
    seqData.defaultVersion = 1
    seqData.versions = { ver }

    -- Remove old flat fields
    seqData.steps = nil
    seqData.stepFunction = nil
    seqData.resetOnCombat = nil
    seqData.resetOnTarget = nil
    seqData.resetOnGear = nil
    seqData.resetOnSpec = nil
    seqData.resetTimer = nil

    -- Ensure contextOverrides exists (T2-1)
    seqData.contextOverrides = seqData.contextOverrides or {}

    return seqData
end

--- Detect the current content context from instance and group state.
--- Uses GetInstanceInfo + difficultyID disambiguation for party/raid/scenario.
--- @return string Context key from D.CONTEXT_KEYS, or D.CONTEXT_NONE
function Engine:DetectContext()
    local _, instanceType, difficultyID = GetInstanceInfo()

    if instanceType == "party" or instanceType == "raid" then
        local ctx = D.DIFFICULTY_CONTEXT[difficultyID]
        if ctx then
            -- M+ tier sub-detection
            if ctx == "MythicPlus" then
                local keyLevel = C_ChallengeMode
                    and C_ChallengeMode.GetActiveKeystoneInfo
                    and C_ChallengeMode.GetActiveKeystoneInfo()
                if keyLevel and keyLevel > 0 then
                    local S = GRIPEMS.Settings
                    local mid = S and S:Get("mythicPlusTierMid") or D.MYTHICPLUS_TIER_MID_DEFAULT
                    local high = S and S:Get("mythicPlusTierHigh") or D.MYTHICPLUS_TIER_HIGH_DEFAULT
                    if keyLevel >= high then
                        return "MythicPlusHigh"
                    elseif keyLevel >= mid then
                        return "MythicPlusMid"
                    else
                        return "MythicPlusLow"
                    end
                end
                return "MythicPlus"
            end
            return ctx
        end
        if instanceType == "party" then
            return "Dungeon"
        end
        return "Raid"
    end

    if instanceType == "scenario" then
        if difficultyID == 208 then
            -- Delve tier sub-detection
            local tier = Engine:GetDelveTierFromCVar()
            if tier then
                local S = GRIPEMS.Settings
                local highThresh = S and S:Get("delvesTierHigh") or D.DELVES_TIER_HIGH_DEFAULT
                if tier >= highThresh then
                    return "DelvesHigh"
                else
                    return "DelvesLow"
                end
            end
            return "Delves"
        end
        return "Scenario"
    end

    -- PvP sub-detection (rated split)
    if instanceType == "arena" then
        if C_PvP and C_PvP.IsSoloShuffle and C_PvP.IsSoloShuffle() then
            return "SoloShuffle"
        end
        if C_PvP and C_PvP.IsRatedArena and C_PvP.IsRatedArena() then
            return "RatedArena"
        end
        -- Per-map detection for non-rated arenas (v1.2.0 S22-F)
        local instanceMapID = select(8, GetInstanceInfo())
        if instanceMapID and D.ARENA_MAP_CONTEXT[instanceMapID] then
            return D.ARENA_MAP_CONTEXT[instanceMapID]
        end
        return "Arena"
    end
    if instanceType == "pvp" then
        if C_PvP and C_PvP.IsSoloRBG and C_PvP.IsSoloRBG() then
            return "BattlegroundBlitz"
        end
        if C_PvP and C_PvP.IsRatedBattleground and C_PvP.IsRatedBattleground() then
            return "RatedBG"
        end
        -- Per-map detection for non-rated battlegrounds (v1.2.0 S22-F)
        local instanceMapID = select(8, GetInstanceInfo())
        if instanceMapID and D.BG_MAP_CONTEXT[instanceMapID] then
            return D.BG_MAP_CONTEXT[instanceMapID]
        end
        return "PVP"
    end

    if instanceType == "none" then
        if IsInGroup() then
            return "Party"
        end
        return "Solo"
    end

    return D.CONTEXT_NONE
end

--- Decode the Delve tier from the lastSelectedTieredEntranceTier CVar.
--- Returns the tier number (1-11) or nil if unavailable/unparseable.
--- @return number|nil tier
function Engine:GetDelveTierFromCVar()
    local b64 = GetCVar("lastSelectedTieredEntranceTier")
    if not b64 or b64 == "" then
        return nil
    end
    local ok1 = C_EncodingUtil and C_EncodingUtil.DecodeBase64
    if not ok1 then
        return nil
    end
    local raw = C_EncodingUtil.DecodeBase64(b64)
    if not raw then
        return nil
    end
    local ok2 = C_EncodingUtil and C_EncodingUtil.DeserializeCBOR
    if not ok2 then
        return nil
    end
    local tbl = C_EncodingUtil.DeserializeCBOR(raw)
    if not tbl or type(tbl) ~= "table" then
        return nil
    end
    -- CVar stores single-entry map {pdeID = tierNumber}
    for _, tier in pairs(tbl) do
        if type(tier) == "number" and tier > 0 then
            return tier
        end
    end
    return nil
end

--- Check for context changes and reload affected sequences.
--- Called on zone change, group roster update, and login.
function Engine:UpdateContext(forceReload)
    local newContext = self:DetectContext()
    if newContext == self.currentContext then
        if forceReload then
            self:ReloadContextSequences(true)
        end
        return
    end

    local oldContext = self.currentContext
    self.currentContext = newContext
    GRIPEMS:Debug(L["GEMS_CONTEXT_CHANGED"], D.CONTEXT_LABELS[newContext] or newContext)
    if GRIPEMS.Fire then
        GRIPEMS:Fire("CONTEXT_CHANGED", newContext, oldContext)
    end
    self:ReloadContextSequences(true)
end

--- Schedule a context refresh after instance/zone state has settled.
--- PLAYER_ENTERING_WORLD and ZONE_CHANGED_NEW_AREA can fire before
--- GetInstanceInfo()/C_ChallengeMode report their final values, especially
--- when zoning into queued dungeons or Mythic+. Run an immediate refresh plus
--- delayed probes so context-specific versions are rebuilt once the client
--- reports the real instance context.
--- @param reason string|nil Diagnostic reason
function Engine:ScheduleContextUpdate(reason)
    -- Instance transitions are not atomic. On Retail, PLAYER_ENTERING_WORLD and
    -- ZONE_CHANGED_NEW_AREA can fire while GetInstanceInfo()/difficulty data still
    -- reports the previous world state. A /reload inside the dungeon works because
    -- by then the client state has settled. Use a generation-based watcher so every
    -- new transition restarts the probe window instead of being ignored by a stale
    -- pending flag.
    self._contextRefreshGeneration = (self._contextRefreshGeneration or 0) + 1
    local generation = self._contextRefreshGeneration

    local function probe(forceReload)
        if Engine._contextRefreshGeneration ~= generation then
            return
        end
        Engine:UpdateContext(forceReload)
    end

    probe(false)

    if not C_Timer or not C_Timer.After then
        return
    end

    local delays = { 0.25, 0.75, 1.50, 2.50, 4.00, 6.00 }
    for _, delay in ipairs(delays) do
        C_Timer.After(delay, function()
            -- Force a reload on later probes even if the context string did not
            -- change. This repairs buttons that were built against a transitional
            -- or stale version index and matches the behavior users get after
            -- /reload, without requiring them to reload manually.
            probe(delay >= 1.50)
        end)
    end
end

--- Detect the active loadout configID and broadcast LOADOUT_CHANGED on transition.
--- Observation-only; never drives a switch. Per Section 6.0.1 of the v3.2 design.
--- Wired to PLAYER_ENTERING_WORLD, PLAYER_SPECIALIZATION_CHANGED,
--- ACTIVE_COMBAT_CONFIG_CHANGED, TRAIT_CONFIG_UPDATED (filtered), and
--- PLAYER_TALENT_UPDATE per Section 6.0.2 event wiring.
function Engine:UpdateLoadout()
    local newID = C_ClassTalents and C_ClassTalents.GetActiveConfigID and C_ClassTalents.GetActiveConfigID() or nil

    -- Debounce edit-mode autosaves and idempotent re-entry from belt-and-braces events.
    if newID == self.currentLoadoutID then
        return
    end

    local oldID = self.currentLoadoutID
    local oldName = self.currentLoadoutName

    local newName = nil
    if newID and C_Traits and C_Traits.GetConfigInfo then
        local info = C_Traits.GetConfigInfo(newID)
        newName = info and info.name or nil
    end

    local newSpec = nil
    local specIdx = GetSpecialization and GetSpecialization() or nil
    if specIdx then
        newSpec = GetSpecializationInfo and GetSpecializationInfo(specIdx) or nil
    end

    self.currentLoadoutID = newID
    self.currentLoadoutName = newName
    self.currentLoadoutSpec = newSpec

    if GRIP_EMS_CHAR then
        GRIP_EMS_CHAR.activeLoadoutID = newID
    end

    if GRIPEMS.Fire then
        GRIPEMS:Fire("LOADOUT_CHANGED", newID, newName, oldID, oldName)
    end

    -- ReloadContextSequences is referenced in Section 6.0.1; guard with type check
    -- in case load order shifts in future phases.
    if type(self.ReloadContextSequences) == "function" then
        self:ReloadContextSequences()
    end
end

--- Reload sequences whose resolved version changed due to a context switch.
--- Refreshes existing secure buttons in place first so any live keybind/action
--- routing that still points at the old button object immediately runs the new
--- context version. A full /reload works because it rebuilds everything; this
--- does the same critical rebinding work at runtime without requiring reload.
function Engine:ReloadContextSequences(forceReload)
    local pending = {}

    -- First pass: collect candidates without mutating Engine.sequences during
    -- pairs(). The previous deactivate+activate path could rebuild while this
    -- table was being iterated, which made the context switch path fragile.
    for name, entry in pairs(self.sequences) do
        local seqData = entry and entry.data
        if seqData and seqData.contextOverrides and next(seqData.contextOverrides) then
            local btn = entry.button
            if btn then
                local newVer = self:GetActiveVersion(seqData)
                local newIdx = self:GetActiveVersionIndex(seqData, newVer)
                local oldIdx = btn.activeVersionIdx
                if newIdx and (forceReload or newIdx ~= oldIdx) then
                    pending[#pending + 1] = {
                        name = name,
                        oldIdx = oldIdx,
                        newIdx = newIdx,
                    }
                end
            end
        end
    end

    for _, item in ipairs(pending) do
        GRIPEMS.OOCQueue:Add(function()
            Engine:ReloadSequenceLive(item.name)
        end, D.OOC_OP_RELOAD, item.name)
    end

    if #pending > 0 then
        GRIPEMS:Debug(L["GEMS_CONTEXT_RELOAD"], #pending)
    end
end

--- Reload a single sequence's live version in place (or via full recreate for
--- variant sets). Extracted from ReloadContextSequences so the context-switch
--- path and the version-pin path share the exact same secure reload work.
--- Recomputes the live version/index, then either recreates the variant set or
--- refreshes the existing secure button in place. MUST run out of combat --
--- callers queue it through OOCQueue:Add with D.OOC_OP_RELOAD.
--- @param name string Sequence name
function Engine:ReloadSequenceLive(name)
    local entry = Engine.sequences[name]
    if not entry or not entry.data or not entry.button then
        return
    end

    local seqData = entry.data
    local liveVer = Engine:GetActiveVersion(seqData)
    local liveIdx = Engine:GetActiveVersionIndex(seqData, liveVer)
    if not liveVer or not liveIdx then
        return
    end

    -- Variant-set safety (added on adoption): the in-place refresh below
    -- recompiles existing variant buttons by index but does NOT add or
    -- remove them when a version's variant set changes. Route any sequence
    -- that has (or had) variant buttons through the proven full recreate
    -- path, which rebuilds the variant set from the new version. The
    -- in-place path then runs only for plain single-button sequences.
    local hasVariants = (liveVer.variantOverrides and #liveVer.variantOverrides > 0)
        or (entry.variantButtons and next(entry.variantButtons) ~= nil)
    if hasVariants then
        Engine:DeactivateSequence(name, true)
        Engine:ActivateSequence(name, seqData)
        return
    end

    -- Critical runtime fix: do not rely on replacing the button object
    -- to switch versions. Existing keybind matrices and action-bar
    -- routes may still reference the old SecureActionButton until the
    -- next binding refresh. Updating that same object in place makes the
    -- dungeon version fire immediately, matching what a later /reload
    -- would have produced.
    entry.button.activeVersionIdx = liveIdx
    entry.button.seqData = seqData
    Engine:_ApplyVersionRuntimeAttributes(entry, liveVer)
    Engine:RecompileSequence(name)

    -- Rebuild the binding matrix after the in-place refresh so direct
    -- keybinds pick up the current button/frame refs. Schedule first
    -- (debounced) and also run a near-future retry because instance
    -- transitions can overlap action-bar and driver state changes.
    if KM and KM.ScheduleLoadKeybinds then
        KM:ScheduleLoadKeybinds()
        if C_Timer and C_Timer.After then
            C_Timer.After(0.20, function()
                if KM and KM.LoadKeybinds then
                    KM:LoadKeybinds()
                end
            end)
        end
    end

    if GRIPEMS.BarIntegration and GRIPEMS.BarIntegration.ScanAllButtons then
        GRIPEMS.BarIntegration:ScanAllButtons()
    end
end

--- Pin a sequence's live version to a specific index until cleared.
--- The pin wins over contextOverrides and defaultVersion in GetActiveVersion.
--- Writing seqData.pinnedVersion is plain insecure data (allowed in combat);
--- only the secure reload defers through OOCQueue, so a swap pressed in combat
--- applies the instant combat drops. Does NOT call any secure API directly.
--- @param name string Sequence name
--- @param idx number Version index to pin (1-based)
--- @return boolean true if the pin was set, false on invalid name/index
function Engine:SetVersionPin(name, idx)
    local entry = self.sequences[name]
    if not entry or not entry.data or type(entry.data.versions) ~= "table" then
        return false
    end
    idx = tonumber(idx)
    if not idx or idx < 1 or idx > #entry.data.versions then
        return false
    end
    entry.data.pinnedVersion = idx
    -- Mirror to the per-character SavedVariables table so the pin persists
    -- across /reload (same pattern as the disabled-flag mirror).
    if _G.GRIP_EMS_CHAR and GRIP_EMS_CHAR.sequences and GRIP_EMS_CHAR.sequences[name] then
        GRIP_EMS_CHAR.sequences[name].pinnedVersion = idx
    end
    GRIPEMS.OOCQueue:Add(function()
        Engine:ReloadSequenceLive(name)
    end, D.OOC_OP_RELOAD, name)
    if GRIPEMS.Fire then
        GRIPEMS:Fire("SEQUENCE_UPDATED", name, entry.data)
    end
    return true
end

--- Clear a sequence's version pin, reverting to context/default resolution.
--- @param name string Sequence name
--- @return boolean true if a matching sequence was found and cleared
function Engine:ClearVersionPin(name)
    local entry = self.sequences[name]
    if not entry or not entry.data then
        return false
    end
    entry.data.pinnedVersion = nil
    if _G.GRIP_EMS_CHAR and GRIP_EMS_CHAR.sequences and GRIP_EMS_CHAR.sequences[name] then
        GRIP_EMS_CHAR.sequences[name].pinnedVersion = nil
    end
    GRIPEMS.OOCQueue:Add(function()
        Engine:ReloadSequenceLive(name)
    end, D.OOC_OP_RELOAD, name)
    if GRIPEMS.Fire then
        GRIPEMS:Fire("SEQUENCE_UPDATED", name, entry.data)
    end
    return true
end

-- SetInitialAttributes removed: OnClick preBody sets attributes on first
-- click. The button starts with type="macro" (empty macrotext = safe no-op).
-- WoW's restricted env silently blocks type attribute changes, so the button
-- must start as type="macro" and the WrapScript body only swaps macrotext content.

--- Create and configure a SecureActionButton for a sequence.
--- The button inherits both SecureActionButtonTemplate (for action execution)
--- and SecureHandlerBaseTemplate (for :Execute() and :WrapScript()).
--- Initial type is "macro"; the click body swaps macrotext per-step.
--- Must be called out of combat (goes through OOCQueue).
--- @param name string Sequence name
--- @param sequenceData table Sequence definition (steps, stepFunction, etc.)
function Engine:ActivateSequence(name, sequenceData)
    if not name or not sequenceData then
        return
    end
    -- Disabled sequences: register without creating button/keybind
    if sequenceData.disabled then
        self:RegisterSequenceOnly(name, sequenceData)
        if _G.GRIP_EMS_CHAR then
            GRIP_EMS_CHAR.sequences = GRIP_EMS_CHAR.sequences or {}
            GRIP_EMS_CHAR.sequences[name] = sequenceData
        end
        return
    end
    local ver = self:GetActiveVersion(sequenceData)
    -- UNGUARDED, AND THE TWIN OF A SITE THAT IS GUARDED. "or" substitutes for
    -- nil and false only, so a scalar ver.steps passes through and the "#steps"
    -- three lines down raises on a number and a boolean; a string clears it and
    -- reaches SF:ValidateSteps. Engine:2840 is the same read in
    -- RecompileSequence and it IS shape-tested. Only one of the twins was ever
    -- fixed. Not guarded in 15u because ActivateSequence is not entered past the
    -- line above by any suite -- measured at fccd100, a bare print here was
    -- silent across SET A, SET B and SET C. Ship target 15v.
    local steps = ver and ver.steps or {}

    -- Validate steps for diagnostics (warn-only, do not block activation)
    if #steps > 0 then
        local valid, errors = SF:ValidateSteps(steps)
        if not valid then
            for _, err in ipairs(errors) do
                GRIPEMS:Debug(err)
            end
        end
    end

    -- Deactivate existing sequence with the same name first
    if self.sequences[name] then
        self:DeactivateSequence(name, true)
    end

    local function doActivate()
        local sanitized = self:SanitizeName(name)
        local globalName = D.BUTTON_PREFIX .. sanitized

        -- Clean up any existing global button with this name.
        -- In WoW Retail, CreateFrame with an existing global name returns the
        -- OLD frame (hidden, parentless from DeactivateSequence) without resetting
        -- its state. Clearing _G forces CreateFrame to build a genuinely new button,
        -- matching the fresh-button behavior seen after relog. (BUG-029 Issue A)
        local existing = _G[globalName]
        if existing then
            existing:SetAttribute("type", nil)
            existing:UnregisterAllEvents()
            existing:Hide()
            existing:SetParent(nil)
            _G[globalName] = nil
        end

        -- Create the button with dual-template inheritance, nil parent
        local btn = CreateFrame("Button", globalName, nil, "SecureActionButtonTemplate,SecureHandlerBaseTemplate")
        btn:Show()
        btn:SetAttribute("type", D.ATTR_TYPE_MACRO)
        btn:SetAttribute("step", 1)
        local activeVer = Engine:GetActiveVersion(sequenceData)
        local resetTimer = activeVer and activeVer.resetTimer or 0
        if resetTimer > 0 then
            btn:SetAttribute("resetTimer", resetTimer)
        end
        btn:SetAttribute("_shouldReset", "0")
        -- Set macro reset modifier attributes for restricted env checks
        local seqResetMods = activeVer and activeVer.resetModifiers
        local resetMods
        if seqResetMods then
            resetMods = {}
            local globalMods = GRIPEMS.Settings:GetResetModifiers()
            for mod, default in pairs(globalMods) do
                if seqResetMods[mod] ~= nil then
                    resetMods[mod] = seqResetMods[mod]
                else
                    resetMods[mod] = default
                end
            end
        else
            resetMods = GRIPEMS.Settings:GetResetModifiers()
        end
        for mod, enabled in pairs(resetMods) do
            btn:SetAttribute("resetMod_" .. mod, enabled and "1" or nil)
        end
        -- Channel hold is per-version, so it rides the same out-of-combat plain
        -- custom-attribute mechanism as resetMod_* above and needs no global rearm.
        btn:SetAttribute("holdOnChannel", activeVer and activeVer.holdOnChannel and "1" or nil)
        btn:SetAttribute("releaseAtMax", activeVer and activeVer.releaseAtMax and "1" or nil)
        btn:SetAttribute("empowerRelease", nil)
        -- Arm hold-to-freeze (out of combat, plain custom attributes -- same
        -- mechanism as resetMod_* above). Base buttons always arm when enabled.
        local htf = GRIPEMS.Settings:GetHoldToFreeze()
        btn:SetAttribute("freezeArmed", htf.enabled and "1" or nil)
        btn:SetAttribute("freezeMod", htf.modifier)
        btn:RegisterForClicks("AnyDown")

        if GRIPEMS.KeybindManager and GRIPEMS.KeybindManager.AttachDriverRef then
            GRIPEMS.KeybindManager:AttachDriverRef(btn)
        end

        -- Store sequence metadata on the button for CallMethod access
        btn.seqName = name
        btn.seqData = sequenceData

        -- Store resolved version index for context-switch comparison (T2-1 hotfix)
        local resolvedVer = Engine:GetActiveVersion(sequenceData)
        btn.activeVersionIdx = nil
        if resolvedVer and type(sequenceData.versions) == "table" then
            for vi, v in ipairs(sequenceData.versions) do
                if v == resolvedVer then
                    btn.activeVersionIdx = vi
                    break
                end
            end
        end

        -- Insecure method called from restricted env via CallMethod('UpdateIcon')
        btn.UpdateIcon = function(self)
            GRIPEMS.Engine:UpdateButtonIcon(self)
        end

        -- Insecure method called from restricted env via CallMethod('PostClick')
        -- Handles reset-timer logic using GetTime() (unavailable in restricted env).
        -- Also stores effective click rate as metadata for /gems status display.
        btn.PostClick = function(self)
            local now = GetTime()
            -- Reset timer check
            local resetTimer = self:GetAttribute("resetTimer") or 0 -- luacheck: no redefined
            if resetTimer > 0 then
                local lastPress = self._lastPress or 0
                if lastPress > 0 and (now - lastPress) > resetTimer then
                    if not GRIPEMS.OOCQueue.IsRestricted() then
                        self:SetAttribute("_shouldReset", "1")
                    end
                end
                self._lastPress = now
            end
            -- Store effective click rate as metadata (informational)
            self._effectiveClickRate = GRIPEMS.Settings:GetEffectiveClickRate()
            -- Store last clicked sequence for ExecutionTracer association
            self._lastClickedSequence = self.seqName
            self._lastClickTime = now
            local EngineRef = GRIPEMS.Engine
            if EngineRef then
                EngineRef._lastClickedSequence = self.seqName
                EngineRef._lastClickTime = now
                -- Rolling button press window for tempo overlay
                local bpt = EngineRef._buttonPressTimes
                bpt[#bpt + 1] = now
                while #bpt > 0 and (now - bpt[1]) > EngineRef.BUTTON_PRESS_WINDOW do
                    table.remove(bpt, 1)
                end
            end
            -- Accessibility: speak step on advance (Phase 1C label-first; v2.3.7 Phase 4
            -- expanded-domain). "step" indexes the EXPANDED execution array, so both the
            -- label and the "of Y" denominator come from the expanded-domain helpers
            -- (btn._execLabels / _numExecSteps), never from authored ver.steps. No cached
            -- label -> generic "Step X of Y".
            if GRIPEMS.Speech and GRIPEMS.Speech.Announce then
                local eng = GRIPEMS.Engine
                local newStep = tonumber(self:GetAttribute("step")) or 1
                local label = eng:GetExecStepLabel(self, newStep)
                if label and label ~= "" then
                    GRIPEMS.Speech:Announce(label)
                else
                    local speechVer = eng:GetActiveVersion(self.seqData)
                    local numSteps = eng:GetExecStepCount(self, speechVer)
                    GRIPEMS.Speech:Announce(string.format(L["ACCESS_SPEECH_STEP_FORMAT"], newStep, numSteps))
                end
            end
        end

        -- Only compile/Execute/WrapScript if we have steps to load.
        -- Empty sequences get a button (type="macro" + empty macrotext = safe
        -- no-op) but no WrapScript wiring. Steps are added via UpdateSequenceData.
        local curVer = Engine:GetActiveVersion(sequenceData)
        -- Action tree compilation: flatten actions to steps + labels before runtime use.
        -- ARCH-MIGRATE Phase 1: import-baked versions keep their baked steps (flag set at legacy import).
        if curVer and curVer.actions and #curVer.actions > 0 and not curVer.importBakedSteps then
            curVer.steps, curVer.compiledLabels = GRIPEMS.ActionCompiler.CompileActions(curVer.actions, self, curVer)
        end
        local stepsToLoad = curVer and curVer.steps or {}
        local stepFuncName = curVer and curVer.stepFunction or D.STEP_SEQUENTIAL
        local kp = curVer and curVer.keyPress or ""
        local kr = curVer and curVer.keyRelease or ""
        -- Hoisted so the variant-button creation block below can reuse the
        -- step function + click body without recomputing them. (IC-VAR-02 Phase 1)
        local stepFunc
        local clickBody
        if #stepsToLoad > 0 then
            -- Determine which steps to load based on step function
            stepFunc = SF:Get(stepFuncName) or SF.Sequential

            -- Compile steps: Priority/ReversePriority pre-expand into flat
            -- arrays of single-step entries; Sequential/Random wrap individually.
            local compiledSteps
            if stepFuncName == D.STEP_PRIORITY then
                compiledSteps = ResolveFitAndExpand(self, stepsToLoad, kp, kr, function(r)
                    return SF:ExpandPriority(r)
                end)
            elseif stepFuncName == D.STEP_REVERSE_PRIORITY then
                compiledSteps = ResolveFitAndExpand(self, stepsToLoad, kp, kr, function(r)
                    return SF:ExpandReversePriority(r)
                end)
            elseif SF:IsExpander(stepFuncName) then
                compiledSteps = ResolveFitAndExpand(self, stepsToLoad, kp, kr, function(r)
                    return SF:RunExpander(stepFuncName, r)
                end)
            else
                compiledSteps = self:CompileSteps(stepsToLoad, kp, kr)
            end

            -- Load step data into the restricted environment via :Execute()
            local execStr = self:BuildExecuteString(compiledSteps)
            local ok, err = true, nil
            if not self:DeferIfBraced(name, btn, execStr, compiledSteps, "base", "base") then
                ok, err = pcall(btn.Execute, btn, execStr)
                if ok then
                    -- The secure body cycles step over the EXPANDED array (BuildExecuteString
                    -- emits numSteps = #compiledSteps). Cache that length so
                    -- SEQUENCE_STEP_ADVANCED reports a denominator in the same domain as the
                    -- step index it ships. Written ONLY after the Execute that loaded these
                    -- steps succeeded: a braced-body defer or a failed Execute leaves the OLD
                    -- steps live in the restricted env, and the cache must keep describing
                    -- those, not the ones we failed to load.
                    btn._numExecSteps = #compiledSteps
                    btn._execSteps = compiledSteps
                    -- Expanded-domain labels aligned with _execSteps, for the accessibility
                    -- speak-step handler (btn._execLabels[step]).
                    btn._execLabels = self:BuildExecLabels(
                        curVer and (curVer.compiledLabels or curVer.stepLabels),
                        stepFuncName,
                        #stepsToLoad
                    )
                end
            end
            if not ok then
                GRIPEMS:Debug("Execute failed: " .. tostring(err))
                -- v2.1.5 diagnostic: capture execStr context for Errors 4+5 investigation.
                -- BugSack pre-existing: "Direct table creation is not permitted" inside
                -- the restricted env. Need to see what execStr actually contains when this
                -- fires. Logs to DebugWindow which has a 500-msg ring buffer.
                if GRIPEMS.DebugWindow and GRIPEMS.DebugWindow.AddMessage then
                    local execLen = type(execStr) == "string" and #execStr or 0
                    local execHead = type(execStr) == "string" and execStr:sub(1, 500) or "<not string>"
                    local stepCount = compiledSteps and #compiledSteps or 0
                    GRIPEMS.DebugWindow:AddMessage(
                        string.format(
                            "Execute failed for sequence '%s' (execStr length=%d, compiledSteps=%d)",
                            tostring(name),
                            execLen,
                            stepCount
                        )
                    )
                    GRIPEMS.DebugWindow:AddMessage("execStr head: " .. execHead)
                end
                self:_NotifySequenceRefreshFailure(name, err)
            end

            -- Wire up WrapScript OnClick body for step advancement.
            -- Method form: header:WrapScript(frame, script, body)
            -- where header=btn (env owner) and frame=btn (script target).
            -- Body runs in restricted env: sets step attributes, advances,
            -- then calls PostClick for time-based throttle/reset.
            clickBody = stepFunc.BuildClickBody()
            btn:WrapScript(btn, "OnClick", clickBody)
            -- Stamp the wrapped body so UpdateSequenceData can detect a
            -- step-function-class change coming from in-place mutators
            -- (see the bodyStale check there).
            btn._emsClickBody = clickBody
        end

        -- Variant button creation (IC-VAR-02 Phase 1, Smart Keybind Groups -- Win 2).
        -- Variant 1 is the base button above. variantOverrides[] holds entries for
        -- variants 2..4, each producing its own SecureActionButton bound to the
        -- sequence's base key + a modifier prefix (SHIFT-/CTRL-/ALT-). The base
        -- key + base button keep their unprefixed binding. Skips entirely when
        -- no overrides exist (single-variant case is byte-identical to today).
        local variantButtons
        if curVer and curVer.variantOverrides and #curVer.variantOverrides > 0 and clickBody then
            local overrides = curVer.variantOverrides
            local validOverrides = true
            if #overrides > D.MAX_VARIANT_OVERRIDES then
                GRIPEMS:Debug(
                    string.format(
                        "Variant overrides for '%s' exceed max (%d > %d); skipping variant buttons",
                        tostring(name),
                        #overrides,
                        D.MAX_VARIANT_OVERRIDES
                    )
                )
                validOverrides = false
            end
            if validOverrides then
                local seenMods = {}
                for ovIdx, override in ipairs(overrides) do
                    if type(override) ~= "table" then
                        GRIPEMS:Debug(
                            string.format(
                                "Variant override %d for '%s' is not a table; aborting variant buttons",
                                ovIdx,
                                tostring(name)
                            )
                        )
                        validOverrides = false
                        break
                    end
                    local mod = override.modifier
                    if not (mod and D.VARIANT_MODIFIER_SET[mod]) or mod == "plain" then
                        GRIPEMS:Debug(
                            string.format(
                                "Variant override %d for '%s' has invalid modifier '%s'; aborting variant buttons",
                                ovIdx,
                                tostring(name),
                                tostring(mod)
                            )
                        )
                        validOverrides = false
                        break
                    end
                    if seenMods[mod] then
                        GRIPEMS:Debug(
                            string.format(
                                "Variant override %d for '%s' duplicates modifier '%s'; aborting variant buttons",
                                ovIdx,
                                tostring(name),
                                mod
                            )
                        )
                        validOverrides = false
                        break
                    end
                    seenMods[mod] = true
                end
            end

            if validOverrides then
                variantButtons = {}
                for ovIdx, override in ipairs(overrides) do
                    local effectiveSteps = override.steps
                    if not effectiveSteps or #effectiveSteps == 0 then
                        GRIPEMS:Debug(
                            string.format(
                                "[variant %d/%s] '%s' has empty steps; skipping variant button creation",
                                ovIdx + 1,
                                tostring(override.modifier),
                                tostring(name)
                            )
                        )
                    else
                        local variantName = globalName .. D.VARIANT_BUTTON_SUFFIX .. (ovIdx + 1)
                        -- Clean up any existing global button with this name (same BUG-029 Issue A pattern).
                        local existingVB = _G[variantName]
                        if existingVB then
                            existingVB:SetAttribute("type", nil)
                            existingVB:UnregisterAllEvents()
                            existingVB:Hide()
                            existingVB:SetParent(nil)
                            _G[variantName] = nil
                        end

                        local variantBtn = CreateFrame(
                            "Button",
                            variantName,
                            nil,
                            "SecureActionButtonTemplate,SecureHandlerBaseTemplate"
                        )
                        variantBtn:Show()
                        variantBtn:SetAttribute("type", D.ATTR_TYPE_MACRO)
                        variantBtn:SetAttribute("step", 1)
                        if resetTimer > 0 then
                            variantBtn:SetAttribute("resetTimer", resetTimer)
                        end
                        variantBtn:SetAttribute("_shouldReset", "0")
                        for mod, enabled in pairs(resetMods) do
                            variantBtn:SetAttribute("resetMod_" .. mod, enabled and "1" or nil)
                        end
                        -- Same per-version channel hold the base button got above, from
                        -- the same resolved version, so a variant press behaves identically.
                        variantBtn:SetAttribute("holdOnChannel", activeVer and activeVer.holdOnChannel and "1" or nil)
                        variantBtn:SetAttribute("releaseAtMax", activeVer and activeVer.releaseAtMax and "1" or nil)
                        variantBtn:SetAttribute("empowerRelease", nil)
                        -- Arm hold-to-freeze on the variant button, BUT skip when this
                        -- variant's own modifier equals the freeze modifier (Q3 collision):
                        -- holding that modifier routes the press to this variant button via
                        -- its override binding, so the variant takes precedence over freeze.
                        local htfV = GRIPEMS.Settings:GetHoldToFreeze()
                        local armV = htfV.enabled and (override.modifier ~= htfV.modifier)
                        variantBtn:SetAttribute("freezeArmed", armV and "1" or nil)
                        variantBtn:SetAttribute("freezeMod", htfV.modifier)
                        variantBtn:RegisterForClicks("AnyDown")

                        variantBtn.seqName = name
                        variantBtn.seqData = sequenceData
                        variantBtn.variantIndex = ovIdx + 1
                        variantBtn.variantModifier = override.modifier

                        -- Same insecure UpdateIcon closure as the base button.
                        variantBtn.UpdateIcon = function(self)
                            GRIPEMS.Engine:UpdateButtonIcon(self)
                        end

                        -- Same PostClick body as the base button (reset timer, speech, click rate).
                        variantBtn.PostClick = function(self)
                            local now = GetTime()
                            local rt = self:GetAttribute("resetTimer") or 0
                            if rt > 0 then
                                local lastPress = self._lastPress or 0
                                if lastPress > 0 and (now - lastPress) > rt then
                                    if not GRIPEMS.OOCQueue.IsRestricted() then
                                        self:SetAttribute("_shouldReset", "1")
                                    end
                                end
                                self._lastPress = now
                            end
                            self._effectiveClickRate = GRIPEMS.Settings:GetEffectiveClickRate()
                            self._lastClickedSequence = self.seqName
                            self._lastClickTime = now
                            local EngineRef = GRIPEMS.Engine
                            if EngineRef then
                                EngineRef._lastClickedSequence = self.seqName
                                EngineRef._lastClickTime = now
                                local bpt = EngineRef._buttonPressTimes
                                bpt[#bpt + 1] = now
                                while #bpt > 0 and (now - bpt[1]) > EngineRef.BUTTON_PRESS_WINDOW do
                                    table.remove(bpt, 1)
                                end
                            end
                            if GRIPEMS.Speech and GRIPEMS.Speech.Announce then
                                -- Expanded-domain (v2.3.7 Phase 4); mirrors the base button.
                                local eng = GRIPEMS.Engine
                                local newStep = tonumber(self:GetAttribute("step")) or 1
                                local label = eng:GetExecStepLabel(self, newStep)
                                if label and label ~= "" then
                                    GRIPEMS.Speech:Announce(label)
                                else
                                    local speechVer = eng:GetActiveVersion(self.seqData)
                                    local numSteps = eng:GetExecStepCount(self, speechVer)
                                    GRIPEMS.Speech:Announce(
                                        string.format(L["ACCESS_SPEECH_STEP_FORMAT"], newStep, numSteps)
                                    )
                                end
                            end
                        end

                        local effectiveKp = override.keyPress or kp
                        local effectiveKr = override.keyRelease or kr
                        local vCompiledSteps
                        if stepFuncName == D.STEP_PRIORITY then
                            vCompiledSteps = ResolveFitAndExpand(
                                self,
                                effectiveSteps,
                                effectiveKp,
                                effectiveKr,
                                function(r)
                                    return SF:ExpandPriority(r)
                                end
                            )
                        elseif stepFuncName == D.STEP_REVERSE_PRIORITY then
                            vCompiledSteps = ResolveFitAndExpand(
                                self,
                                effectiveSteps,
                                effectiveKp,
                                effectiveKr,
                                function(r)
                                    return SF:ExpandReversePriority(r)
                                end
                            )
                        elseif SF:IsExpander(stepFuncName) then
                            vCompiledSteps = ResolveFitAndExpand(
                                self,
                                effectiveSteps,
                                effectiveKp,
                                effectiveKr,
                                function(r)
                                    return SF:RunExpander(stepFuncName, r)
                                end
                            )
                        else
                            vCompiledSteps = self:CompileSteps(effectiveSteps, effectiveKp, effectiveKr)
                        end

                        local vExecStr = self:BuildExecuteString(vCompiledSteps)
                        local vOk, vErr = true, nil
                        if
                            not self:DeferIfBraced(
                                name,
                                variantBtn,
                                vExecStr,
                                vCompiledSteps,
                                "variant " .. (ovIdx + 1),
                                "v" .. (ovIdx + 1)
                            )
                        then
                            vOk, vErr = pcall(variantBtn.Execute, variantBtn, vExecStr)
                            if vOk then
                                variantBtn._numExecSteps = #vCompiledSteps
                                variantBtn._execSteps = vCompiledSteps
                                -- Variant overrides carry steps but no per-step labels, so the
                                -- speak-step handler falls to the generic "Step X of Y".
                                variantBtn._execLabels = nil
                            end
                        end
                        if not vOk then
                            GRIPEMS:Debug(
                                string.format(
                                    "[variant %d/%s] Execute failed: %s",
                                    ovIdx + 1,
                                    tostring(override.modifier),
                                    tostring(vErr)
                                )
                            )
                            if GRIPEMS.DebugWindow and GRIPEMS.DebugWindow.AddMessage then
                                local execLen = type(vExecStr) == "string" and #vExecStr or 0
                                local execHead = type(vExecStr) == "string" and vExecStr:sub(1, 500) or "<not string>"
                                local stepCount = vCompiledSteps and #vCompiledSteps or 0
                                GRIPEMS.DebugWindow:AddMessage(
                                    string.format(
                                        "[variant %d/%s] Execute failed for sequence '%s' (execStr length=%d, compiledSteps=%d)",
                                        ovIdx + 1,
                                        tostring(override.modifier),
                                        tostring(name),
                                        execLen,
                                        stepCount
                                    )
                                )
                                GRIPEMS.DebugWindow:AddMessage(
                                    string.format(
                                        "[variant %d/%s] execStr head: %s",
                                        ovIdx + 1,
                                        tostring(override.modifier),
                                        execHead
                                    )
                                )
                            end
                            self:_NotifySequenceRefreshFailure(name, vErr)
                        end

                        if GRIPEMS.KeybindManager and GRIPEMS.KeybindManager.AttachDriverRef then
                            GRIPEMS.KeybindManager:AttachDriverRef(variantBtn)
                        end
                        variantBtn:WrapScript(variantBtn, "OnClick", clickBody)
                        variantButtons[ovIdx] = variantBtn
                    end
                end
            end
        end

        -- Compile the recommend function (IC-VAR-02 Phase 2). The active
        -- version's recommendSource (with seqData.recommendSource fallback)
        -- is compiled at the same time variantButtons are built so the
        -- runtime evaluator can pcall a cached function instead of
        -- re-loadstringing on every VARIABLE_UPDATED. Defensive: skip if
        -- RecommendationEvaluator is not loaded (dev configurations may
        -- omit the module without breaking sequence activation).
        if GRIPEMS.RecommendationEvaluator and curVer then
            GRIPEMS.RecommendationEvaluator:CompileForVersion(name, btn.activeVersionIdx, sequenceData, curVer)
            if curVer._recommendFunc then
                GRIPEMS.RecommendationEvaluator:_ScheduleReeval(name)
            end
        end

        -- Register the sequence
        self.sequences[name] = {
            button = btn,
            data = sequenceData,
            variantButtons = variantButtons,
        }

        -- Persist to SavedVariables (survives /reload)
        if _G.GRIP_EMS_CHAR then
            GRIP_EMS_CHAR.sequences = GRIP_EMS_CHAR.sequences or {}
            GRIP_EMS_CHAR.sequences[name] = sequenceData
        end

        local activeSteps = curVer and curVer.steps or {}
        GRIPEMS:Debug(L["GEMS_SEQ_ACTIVATED"], name, #activeSteps)

        -- Create the macro stub so the player can drag it to the action bar
        MM:CreateStub(name, kp, kr, activeSteps)

        -- Apply keybinding if one exists for this sequence
        -- Skip during initial load: LoadKeybinds() runs after
        -- RestoreSavedSequences and applies all binds in one pass.
        if KM and self._initialLoadComplete then
            KM:BindIfConfigured(name)
        end

        -- Notify listeners
        if GRIPEMS.Fire then
            GRIPEMS:Fire("SEQUENCE_CREATED", name, sequenceData)
        end

        -- Faster, Slower: notify TempoAdvisor of sequence activation
        if GRIPEMS.TempoAdvisor then
            GRIPEMS.TempoAdvisor:OnSequenceActivated(name, sequenceData)
        end
    end

    GRIPEMS.OOCQueue:Add(doActivate, D.OOC_OP_ACTIVATE, name)
end

--- Re-arm hold-to-freeze attributes on every active base + variant button.
--- Called by Settings:SetHoldToFreeze when the freeze setting changes so live
--- sequences pick up the new enabled/modifier without a /reload. OOC-gated:
--- freezeArmed/freezeMod must only be written out of combat (the secure snippet
--- reads them), so an in-combat call defers via OOCQueue. Variant buttons whose
--- own modifier equals the freeze modifier are NOT armed (Q3 collision rule), so
--- the variant keeps precedence on that modifier for its sequence.
function Engine:RearmFreezeAll()
    if InCombatLockdown() then
        GRIPEMS.OOCQueue:Add(function()
            Engine:RearmFreezeAll()
        end, D.OOC_OP_GENERIC)
        return
    end
    local htf = GRIPEMS.Settings:GetHoldToFreeze()
    for _, entry in pairs(self.sequences) do
        if entry.button then
            entry.button:SetAttribute("freezeArmed", htf.enabled and "1" or nil)
            entry.button:SetAttribute("freezeMod", htf.modifier)
        end
        if entry.variantButtons then
            for _, vb in pairs(entry.variantButtons) do
                local armV = htf.enabled and (vb.variantModifier ~= htf.modifier)
                vb:SetAttribute("freezeArmed", armV and "1" or nil)
                vb:SetAttribute("freezeMod", htf.modifier)
            end
        end
    end
end

--- Register a sequence without creating a SecureActionButton (dormant).
--- The sequence appears in the UI list but cannot fire until activated.
--- @param name string Sequence name
--- @param seqData table Sequence data
function Engine:RegisterSequenceOnly(name, seqData)
    if not name or not seqData then
        return
    end
    -- Skip if already registered (active or dormant)
    if self.sequences[name] then
        return
    end
    self.sequences[name] = {
        button = nil, -- dormant: no SecureActionButton
        data = seqData,
    }
    -- Fire callback so SequenceList sees it
    if GRIPEMS.Fire then
        GRIPEMS:Fire("SEQUENCE_CREATED", name, seqData)
    end
end

--- Promote a dormant (registered but button=nil) sequence to fully active.
--- @param name string Sequence name
function Engine:ActivateDormantSequence(name)
    local entry = self.sequences[name]
    if not entry or entry.button then
        return
    end -- not dormant or already active
    local data = entry.data
    -- Unregister + activate as ONE queued unit. The old shape removed the
    -- registration synchronously and queued only the activation; under
    -- combat lockdown that made the row vanish from the sequence list until
    -- the queue drained. Out of combat OOCQueue:Add executes the closure
    -- inline, so the common path is unchanged. The unregister stays INSIDE
    -- the closure so ActivateSequence does not route through
    -- DeactivateSequence (which deletes the macro stub and drops the
    -- SavedVariables entry).
    GRIPEMS.OOCQueue:Add(function()
        Engine.sequences[name] = nil
        Engine:ActivateSequence(name, data)
    end, D.OOC_OP_ACTIVATE, name)
end

--- Check whether a sequence is registered but dormant (no button).
--- @param name string Sequence name
--- @return boolean
function Engine:IsSequenceDormant(name)
    local entry = self.sequences[name]
    return entry ~= nil and entry.button == nil
end

--- Return the count of dormant (button=nil) sequences.
--- @return number
function Engine:GetDormantCount()
    local count = 0
    for _, entry in pairs(self.sequences) do
        if entry.button == nil then
            count = count + 1
        end
    end
    return count
end

--- Deactivate a sequence: hide and unregister its button, delete macro stub.
--- @param name string Sequence name
--- @param keepStub boolean|nil When true, the macro stub is preserved
---        (not deleted). Rebuild flows that immediately re-activate the
---        SAME sequence pass true: deleting + recreating the stub
---        allocates a new macro index, which orphans the action-bar slot
---        the player dragged the stub onto. Keeping it lets CreateStub
---        refresh the body in place (EditMacro) so the macro index -- and
---        the action-bar placement -- survive the rebuild.
function Engine:DeactivateSequence(name, keepStub)
    if not name or not self.sequences[name] then
        return
    end

    local function doDeactivate()
        -- Clear live override binding (keeps saved data for re-activation)
        if KM then
            KM:UnbindSequence(name)
        end

        local entry = self.sequences[name]
        if entry and entry.button then
            entry.button:SetAttribute("type", nil)
            entry.button:Hide()
            entry.button:SetParent(nil)
        end
        -- Tear down variant buttons (IC-VAR-02 Phase 1). Each variant button
        -- also clears its global slot so re-activation rebuilds it cleanly
        -- (same BUG-029 Issue A pattern as the base button). pairs (not
        -- ipairs) because skipped overrides leave sparse holes in the array.
        if entry and entry.variantButtons then
            for _, vb in pairs(entry.variantButtons) do
                if vb and vb.SetAttribute then
                    vb:SetAttribute("type", nil)
                    vb:UnregisterAllEvents()
                    vb:Hide()
                    vb:SetParent(nil)
                    local vbName = vb.GetName and vb:GetName()
                    if vbName then
                        _G[vbName] = nil
                    end
                end
            end
        end
        -- Clear cached recommend function so re-activation rebuilds fresh
        -- (IC-VAR-02 Phase 2). The version table survives in SavedVariables
        -- but the compiled closure is session-local.
        if entry and entry.data and type(entry.data.versions) == "table" then
            for _, v in ipairs(entry.data.versions) do
                if type(v) == "table" then
                    v._recommendFunc = nil
                end
            end
        end
        self.sequences[name] = nil

        -- Remove from SavedVariables
        if _G.GRIP_EMS_CHAR and GRIP_EMS_CHAR.sequences then
            GRIP_EMS_CHAR.sequences[name] = nil
        end

        if not keepStub then
            MM:DeleteStub(name)
        end
        GRIPEMS:Debug(L["GEMS_SEQ_DEACTIVATED"], name)

        -- Notify listeners
        if GRIPEMS.Fire then
            GRIPEMS:Fire("SEQUENCE_DELETED", name)
        end
    end

    GRIPEMS.OOCQueue:Add(doDeactivate, D.OOC_OP_DEACTIVATE, name)
end

--- Toggle the disabled state of a sequence.
--- Disabled sequences remain in the list but have no button or keybind.
--- @param name string Sequence name
function Engine:ToggleSequenceDisabled(name)
    local entry = self.sequences[name]
    if not entry or not entry.data then
        return
    end

    if entry.data.disabled then
        -- Re-enable: unregister + activate as one queued unit (same shape as
        -- ActivateDormantSequence -- keeps the row visible when re-enabled
        -- during combat lockdown). Out of combat the closure runs inline.
        entry.data.disabled = nil
        local data = entry.data
        GRIPEMS.OOCQueue:Add(function()
            Engine.sequences[name] = nil
            Engine:ActivateSequence(name, data)
        end, D.OOC_OP_ACTIVATE, name)
    else
        -- Disable: tear down button but keep registered as dormant
        entry.data.disabled = true
        local data = entry.data
        local function doDisable()
            if KM then
                KM:UnbindSequence(name)
            end
            if entry.button then
                entry.button:SetAttribute("type", nil)
                entry.button:Hide()
                entry.button:SetParent(nil)
            end
            entry.button = nil
            -- Tear down variant buttons too (IC-VAR-02 Phase 1). pairs (not
            -- ipairs) because skipped overrides leave sparse holes.
            if entry.variantButtons then
                for _, vb in pairs(entry.variantButtons) do
                    if vb and vb.SetAttribute then
                        vb:SetAttribute("type", nil)
                        vb:UnregisterAllEvents()
                        vb:Hide()
                        vb:SetParent(nil)
                        local vbName = vb.GetName and vb:GetName()
                        if vbName then
                            _G[vbName] = nil
                        end
                    end
                end
                entry.variantButtons = nil
            end
            -- Clear cached recommend function so re-enable rebuilds fresh
            -- (IC-VAR-02 Phase 2).
            if entry.data and type(entry.data.versions) == "table" then
                for _, v in ipairs(entry.data.versions) do
                    if type(v) == "table" then
                        v._recommendFunc = nil
                    end
                end
            end
            MM:DeleteStub(name)
            if GRIPEMS.Fire then
                GRIPEMS:Fire("SEQUENCE_UPDATED", name, data)
            end
        end
        GRIPEMS.OOCQueue:Add(doDisable, D.OOC_OP_DEACTIVATE, name)
    end

    -- Persist disabled state to SavedVariables
    if _G.GRIP_EMS_CHAR and GRIP_EMS_CHAR.sequences and GRIP_EMS_CHAR.sequences[name] then
        GRIP_EMS_CHAR.sequences[name].disabled = entry.data.disabled
    end
end

--- Reset a sequence's step counter to 1. OOC-only from insecure code.
--- @param name string Sequence name
function Engine:ResetStep(name)
    if not name or not self.sequences[name] then
        return
    end
    local btn = self.sequences[name].button
    if not btn then
        return
    end

    local function doReset()
        btn:SetAttribute("step", 1)
        GRIPEMS:Debug(L["GEMS_STEP_RESET"], name)
        Engine:UpdateButtonIcon(btn, true)
    end

    GRIPEMS.OOCQueue:Add(doReset, D.OOC_OP_RESET, name)
end

--- Get the current step index for a sequence.
--- @param name string Sequence name
--- @return number|nil Current step (1-based), or nil if sequence not found
function Engine:GetCurrentStep(name)
    if not name or not self.sequences[name] then
        return nil
    end
    local btn = self.sequences[name].button
    if not btn then
        return nil
    end
    return tonumber(btn:GetAttribute("step")) or 1
end

--- Manually advance a sequence's step (for /gems test debugging).
--- Wraps around to step 1 after the last step. OOC-only.
--- @param name string Sequence name
function Engine:AdvanceStep(name)
    if not name or not self.sequences[name] then
        return
    end
    local entry = self.sequences[name]
    local btn = entry.button
    if not btn then
        return
    end

    local function doAdvance()
        local step = tonumber(btn:GetAttribute("step")) or 1
        local ver = Engine:GetActiveVersion(entry.data)
        -- "step" indexes the EXPANDED array, so wrap over the expanded count (matches the
        -- secure body's step % numS + 1), not #ver.steps.
        local numSteps = Engine:GetExecStepCount(btn, ver)
        if numSteps == 0 then
            return
        end
        step = step % numSteps + 1
        btn:SetAttribute("step", step)
        GRIPEMS:Debug(L["GEMS_STEP_ADVANCED"], name, step, numSteps)
    end

    GRIPEMS.OOCQueue:Add(doAdvance, D.OOC_OP_GENERIC, name)
end

--- The number of steps the secure body actually cycles through for this button. When
--- the button carries the compile-time cache (_numExecSteps), that EXPANDED count wins
--- -- it describes the steps actually live in the restricted env, so the hot fire path
--- is untouched. With no cache (a DORMANT sequence, or a button whose Execute has not
--- yet succeeded), the no-cache path expands ver.steps through BuildExecutionOrder
--- rather than returning the raw #ver.steps, so the value ALWAYS sits in the EXECUTION
--- domain and NEVER in the compiled one. This keeps it equal to
--- #GetActiveVersionStepList (API:GetSequenceSteps) for the same sequence. Single
--- source of truth -- every consumer of the step denominator calls this rather than
--- reading #ver.steps.
--- @param btn frame The SecureActionButton
--- @param ver table|nil The active version table
--- @return number Step count in the EXECUTION domain the button's "step" attribute lives in
function Engine:GetExecStepCount(btn, ver)
    local cached = btn and btn._numExecSteps
    if cached then
        return cached
    end
    -- No cache: a DORMANT sequence (RegisterSequenceOnly leaves button = nil)
    -- or a button whose first Execute was deferred/failed. #ver.steps would be
    -- the COMPILED count, but GetActiveVersionStepList (API:GetSequenceSteps)
    -- always expands, so returning it puts stepCount and #GetSequenceSteps in
    -- different domains for the same sequence. Expand here too.
    if ver and type(ver.steps) == "table" and #ver.steps > 0 then
        return #self:BuildExecutionOrder(ver.steps, ver.stepFunction)
    end
    return 0
end

--- The macrotext the secure body actually fires at a given step index. The button's
--- "step" attribute indexes the EXPANDED execution array, NEVER ver.steps: for
--- Priority, authored [A,B,C,D] expands to [A,A,B,A,B,C,A,B,C,D], so ver.steps[step]
--- is wrong for nine of ten positions. BOTH branches now live in the EXECUTION domain:
--- the cached branch reads the compiled array (btn._execSteps); the no-cache branch
--- expands ver.steps through BuildExecutionOrder rather than reading ver.steps raw, so
--- the cached and uncached answers AGREE for the same button/step/version. Expanding
--- also substitutes variables, which the raw authored text does not.
--- @param btn frame The SecureActionButton
--- @param step number The button's current "step" attribute (an expanded index)
--- @param ver table|nil The active version table (expanded through BuildExecutionOrder)
--- @return string|nil Macrotext for that step, or nil
function Engine:GetExecStepText(btn, step, ver)
    local exec = btn and btn._execSteps
    if exec and exec[step] and exec[step].macrotext then
        return exec[step].macrotext
    end
    -- No cache: "step" is an EXPANDED index, so it must index the EXPANDED array.
    -- Indexing the authored ver.steps with it is a domain error -- for
    -- ReversePriority even step 1 differs (order[1] is the LAST authored step,
    -- steps[1] the first), and for Priority step 3 the cached branch returns the
    -- second authored step while ver.steps[3] returns the third. BuildExecutionOrder
    -- also substitutes variables, which the raw ver.steps does not.
    local steps = ver and ver.steps
    if steps and #steps > 0 then
        local order = self:BuildExecutionOrder(steps, ver.stepFunction)
        if order and #order > 0 then
            return order[step] or order[1]
        end
    end
    return nil
end

--- The text a DISPLAY consumer (icon, tracker row, bar overlay) should parse a spell
--- out of for a given step index. NOTHING about casting reads this accessor: the
--- macrotext that actually fires is unchanged and still comes from GetExecStepText.
---
--- Why a companion instead of a fix inside GetExecStepText: CompileSteps prepends the
--- keyPress block to every step whenever the two fit the 255-char cap, and stores that
--- COMBINED string as the step's macrotext. That combined string is correct for firing
--- and wrong for display -- SC:ParseSpellFromMacrotext returns the last unconditional
--- or [combat] cast it finds, else the FIRST conditional cast, so when no line anywhere
--- is unconditional and none carries [combat], the answer is keypress line one for
--- every step (measured: a Brewmaster keyPress opening with [mod:shift] Leg Sweep and
--- steps all carrying [nochanneling] showed Leg Sweep on every tracker row). This
--- reads compiled[step].stepOwnText, the step's own resolved text, which is the same
--- input empowerRelease is computed from one loop below the bake.
---
--- The fallback is CORRECT, not merely tolerable, in both shapes that reach it:
---   * An execution array compiled before stepOwnText existed (a button cached across
---     an upgrade, or a hand-built array in a test) simply falls through to the old
---     answer -- the pre-fix behaviour, never a raise.
---   * The no-cache branch of GetExecStepText returns order[step] out of
---     BuildExecutionOrder, which never carries keyPress in the first place, so it is
---     already in the display domain and needs no companion.
--- @param btn frame The SecureActionButton
--- @param step number The button's current "step" attribute (an expanded index)
--- @param ver table|nil The active version table (used only by the fallback)
--- @return string|nil Text to parse a display spell from, or nil
function Engine:GetExecStepDisplayText(btn, step, ver)
    local exec = btn and btn._execSteps
    local entry = exec and exec[step]
    local ownText = entry and entry.stepOwnText
    if type(ownText) == "string" and ownText ~= "" then
        return ownText
    end
    return self:GetExecStepText(btn, step, ver)
end

--- Build the EXPANDED-domain per-step labels array, aligned index-for-index with the
--- compiled execution array cached on btn._execSteps, from the AUTHORED labels. Priority
--- and ReversePriority run the labels through the SAME triangle the macrotext takes (via
--- SF:ExpandPriority / SF:ExpandReversePriority), so the label at an expanded index names
--- the authored step that position actually fires. Sequential/Random are identity (pass a
--- nil/Sequential stepFunction to force identity -- e.g. hold mode, which never expands).
--- A plugin expander reorders by macrotext CONTENT, so its label mapping cannot be
--- recovered from labels -> nil (the accessor then falls back to the generic "Step X of Y").
--- Returns nil when there are no usable labels, so nothing is cached needlessly.
--- @param authoredLabels table|nil Labels aligned with the authored steps (compiledLabels/stepLabels)
--- @param stepFunction string|nil The version's step function (nil -> Sequential / identity)
--- @param n number The authored step count (#ver.steps)
--- @return table|nil Expanded labels array, or nil when none apply
function Engine:BuildExecLabels(authoredLabels, stepFunction, n)
    if type(authoredLabels) ~= "table" or type(n) ~= "number" or n <= 0 then
        return nil
    end
    local labels = {}
    local any = false
    for i = 1, n do
        local lbl = authoredLabels[i]
        if type(lbl) ~= "string" or lbl == "" then
            lbl = ""
        else
            any = true
        end
        labels[i] = lbl
    end
    if not any then
        return nil
    end
    local sf = stepFunction or D.STEP_SEQUENTIAL
    local entries
    if sf == D.STEP_PRIORITY then
        entries = SF:ExpandPriority(labels)
    elseif sf == D.STEP_REVERSE_PRIORITY then
        entries = SF:ExpandReversePriority(labels)
    elseif SF:IsExpander(sf) then
        return nil
    else
        return labels
    end
    local out = {}
    for i = 1, #entries do
        out[i] = entries[i].macrotext
    end
    return out
end

--- The human-readable label for the step the secure body actually fires at a given
--- expanded step index. Reads btn._execLabels, the EXPANDED-domain labels array cached at
--- compile time index-for-index with btn._execSteps. Unlike GetExecStepText there is NO
--- authored-array fallback on purpose: ver.compiledLabels / stepLabels are AUTHORED-domain,
--- so indexing them by an expanded step is the exact defect this closes. A button with no
--- cache (or a variant / plugin expander with no recoverable labels) returns nil, and the
--- caller speaks the generic "Step X of Y" instead of a wrong label.
--- @param btn frame The SecureActionButton
--- @param step number The button's current "step" attribute (an expanded index)
--- @return string|nil The step label, or nil when none is cached
function Engine:GetExecStepLabel(btn, step)
    local execLabels = btn and btn._execLabels
    if type(execLabels) ~= "table" then
        return nil
    end
    local label = execLabels[step]
    if label == nil or label == "" then
        return nil
    end
    return label
end

--- Update the macro stub icon based on the button's current step.
--- Called from the restricted environment via CallMethod('UpdateIcon').
--- This is an insecure method that queues an OOC icon update.
--- SC:ParseSpellFromMacrotext and SC:GetIcon are pure Lua lookups --
--- they work fine from insecure code. MM:UpdateIcon uses OOCQueue.
--- @param btn frame The SecureActionButton
--- @param silent boolean|nil When true, suppress the stepComplete cue.
---   Reset paths pass true: the step changed, but nothing was cast.
function Engine:UpdateButtonIcon(btn, silent)
    if not btn or not btn.seqName then
        return
    end
    local seqData = btn.seqData
    if not seqData then
        return
    end

    -- Icon update: OOC only (MM:UpdateIcon uses SetAttribute)
    if not GRIPEMS.OOCQueue.IsRestricted() then
        if seqData.autoIcon == false and type(seqData.icon) == "number" then
            MM:UpdateIcon(btn.seqName, seqData.icon)
        else
            local step = tonumber(btn:GetAttribute("step")) or 1
            local ver = self:GetActiveVersion(seqData)
            -- The "step" attribute indexes the EXPANDED execution array, never ver.steps.
            local stepText = self:GetExecStepDisplayText(btn, step, ver)
            if stepText then
                local SC = GRIPEMS.SpellCache
                if SC then
                    local spellName = SC:ParseSpellFromMacrotext(stepText)
                    if spellName then
                        local iconID = SC:GetIcon(spellName)
                        if iconID then
                            MM:UpdateIcon(btn.seqName, iconID)
                        end
                    end
                end
            end
        end
    end

    -- Step-advanced callback: ALWAYS fire (pure Lua, safe in combat)
    if GRIPEMS.Fire then
        local step = tonumber(btn:GetAttribute("step")) or 1
        local ver = self:GetActiveVersion(seqData)
        local numSteps = self:GetExecStepCount(btn, ver)
        GRIPEMS:Fire("SEQUENCE_STEP_ADVANCED", btn.seqName, step, numSteps)
        if GRIPEMS.Sound and not silent then
            GRIPEMS.Sound:Play("stepComplete")
        end
    end
end

--- Return a summary table of all active sequences for status display.
--- @return table Array of { name, stepCount, currentStep, stepFunction }
function Engine:GetSequenceList()
    local list = {}
    for name, entry in pairs(self.sequences) do
        local btn = entry.button
        local currentStep = 1
        if btn then
            currentStep = tonumber(btn:GetAttribute("step")) or 1
        end
        local ver = self:GetActiveVersion(entry.data)
        table.insert(list, {
            name = name,
            -- Expanded count so it agrees with currentStep (an expanded index), not "7/4".
            stepCount = self:GetExecStepCount(btn, ver),
            currentStep = currentStep,
            stepFunction = ver and ver.stepFunction or D.STEP_SEQUENTIAL,
        })
    end
    table.sort(list, function(a, b)
        return a.name < b.name
    end)
    return list
end

--- Return the count of active sequences.
--- @return number
function Engine:GetActiveCount()
    local count = 0
    for _ in pairs(self.sequences) do
        count = count + 1
    end
    return count
end

function Engine:GetButtonPressRate()
    local now = GetTime()
    local bpt = self._buttonPressTimes
    -- Prune stale entries
    while #bpt > 0 and (now - bpt[1]) > self.BUTTON_PRESS_WINDOW do
        table.remove(bpt, 1)
    end
    if #bpt < 2 then
        return 0
    end
    local span = bpt[#bpt] - bpt[1]
    if span <= 0 then
        return 0
    end
    return (#bpt - 1) / span
end

-- Settle window (seconds) before the second keybind push after a world load.
-- Mirrors KEYBIND_LOSS_SETTLE_SECONDS in Engine/KeybindManager.lua.
local KEYBIND_LOAD_SETTLE_SECONDS = 1.5

--- Entering-world restore. Runs the once-per-login bootstrap behind its gate,
--- then re-applies sequence keybinds unconditionally on every world load.
--- Called from the PLAYER_ENTERING_WORLD branch of the engine event handler.
function Engine:_RunEnteringWorldRestore()
    -- Bootstrap-class operations. ScanExisting + RestoreSavedSequences are
    -- one-time setup: PLAYER_ENTERING_WORLD fires on every instance
    -- transition, and re-running the OOCQueue Deactivate+Activate dance per
    -- sequence on each entry caused intermittent sequence loss
    -- (Oomph 2026-05-15). disable+enable still forces a fresh bootstrap
    -- because the addon's Lua state resets.
    if not Engine._initialLoadComplete then
        MM:ScanExisting()
        Engine:RestoreSavedSequences()
        Engine._initialLoadComplete = true
    end

    -- LoadKeybinds is NOT bootstrap-class and must run on EVERY world load.
    -- It is idempotent: it rebuilds the matrix and pushes it to the secure
    -- driver, touching no activation state. A loading screen drops the live
    -- override bindings, and on a zone change the driver's emsvehicle state
    -- does not change, so _onattributechanged never re-fires and nothing
    -- else re-pushes. Gating this with the two above is what left a saved
    -- key showing in /gems while the press did nothing
    -- (Discord 1537091347683745882).
    Engine:_ReapplyKeybindsAfterLoad()
end

--- Re-apply sequence keybinds after a world load. Inline when unrestricted,
--- queued otherwise; an in-combat /reload drains on PLAYER_REGEN_ENABLED,
--- restriction lift, or the periodic ticker. Follows up with one debounced
--- settle pass after the loading screen ends.
function Engine:_ReapplyKeybindsAfterLoad()
    if not KM then
        return
    end
    if not GRIPEMS.OOCQueue.IsRestricted() then
        KM:LoadKeybinds()
    else
        GRIPEMS.OOCQueue:Add(function()
            if KM and KM.LoadKeybinds then
                KM:LoadKeybinds()
            end
        end, D.OOC_OP_GENERIC, "__enteringworld_loadkeybinds__")
    end

    -- Second pass after the loading screen ends. A binding applied while
    -- the screen is still up can be discarded when the world finishes
    -- loading, and the sequence buttons may not yet exist in _G at the
    -- moment of the first push. One settle re-push covers both. It routes
    -- through ScheduleLoadKeybinds, which is debounced, so a burst of
    -- PLAYER_ENTERING_WORLD events collapses to one rebuild.
    if C_Timer and C_Timer.After then
        C_Timer.After(KEYBIND_LOAD_SETTLE_SECONDS, function()
            if KM and KM.ScheduleLoadKeybinds then
                KM:ScheduleLoadKeybinds()
            end
        end)
    end
end

--- Restore all sequences from SavedVariables after login/reload.
--- Called from PLAYER_ENTERING_WORLD before keybind loading.
function Engine:RestoreSavedSequences()
    if not _G.GRIP_EMS_CHAR or not GRIP_EMS_CHAR.sequences then
        return
    end
    -- Claim anything another character staged for us BEFORE the pairs loop
    -- below, so a freshly claimed sequence is validated, migrated and activated
    -- in the same pass. Claiming afterwards would need a second /reload.
    if GRIPEMS.CharIndex then
        GRIPEMS.CharIndex:ClaimInbox()
    end
    self.corruptSequences = {}
    local playerClassID = select(3, UnitClass("player")) or 0
    local dormantCount = 0
    local count = 0
    local restrictedDeferred = 0
    for name, seqData in pairs(GRIP_EMS_CHAR.sequences) do
        if type(name) ~= "string" or name == "" then
            -- Corrupt key (likely from interrupted delete/rename).
            -- Drop immediately -- popup-based corrupt flow keys on entry.name,
            -- which would be unusable for non-string keys.
            GRIP_EMS_CHAR.sequences[name] = nil
            GRIPEMS:Debug("Dropped corrupt sequence key: type=" .. type(name) .. " value='" .. tostring(name) .. "'")
        elseif type(seqData) == "table" then
            -- Validate structure before activation
            local valid = true
            local errorMsg = nil
            if type(seqData.versions) ~= "table" or #seqData.versions == 0 then
                valid = false
                errorMsg = "Missing or empty versions table"
            else
                local hasSteps = false
                for _, ver in ipairs(seqData.versions) do
                    if type(ver) == "table" and type(ver.steps) == "table" then
                        hasSteps = true
                        break
                    end
                end
                if not hasSteps then
                    valid = false
                    errorMsg = "No version contains a steps table"
                end

                -- Variant overrides validation (IC-VAR-02 Phase 1). Walks every
                -- version and rejects sequences with malformed variantOverrides.
                if valid then
                    for vIdx, ver in ipairs(seqData.versions) do
                        if type(ver) == "table" and ver.variantOverrides ~= nil then
                            if type(ver.variantOverrides) ~= "table" then
                                valid = false
                                errorMsg = "Variant overrides malformed: version "
                                    .. vIdx
                                    .. " variantOverrides is not a table"
                                break
                            end
                            if #ver.variantOverrides > D.MAX_VARIANT_OVERRIDES then
                                valid = false
                                errorMsg = "Variant overrides malformed: version "
                                    .. vIdx
                                    .. " has "
                                    .. #ver.variantOverrides
                                    .. " overrides (max "
                                    .. D.MAX_VARIANT_OVERRIDES
                                    .. ")"
                                break
                            end
                            local seenMods = {}
                            for ovIdx, override in ipairs(ver.variantOverrides) do
                                if type(override) ~= "table" then
                                    valid = false
                                    errorMsg = "Variant overrides malformed: version "
                                        .. vIdx
                                        .. " override "
                                        .. ovIdx
                                        .. " is not a table"
                                    break
                                end
                                local mod = override.modifier
                                if not (mod and D.VARIANT_MODIFIER_SET[mod]) or mod == "plain" then
                                    valid = false
                                    errorMsg = "Variant overrides malformed: version "
                                        .. vIdx
                                        .. " override "
                                        .. ovIdx
                                        .. " has invalid modifier '"
                                        .. tostring(mod)
                                        .. "'"
                                    break
                                end
                                if seenMods[mod] then
                                    valid = false
                                    errorMsg = "Variant overrides malformed: version "
                                        .. vIdx
                                        .. " has duplicate modifier '"
                                        .. mod
                                        .. "'"
                                    break
                                end
                                seenMods[mod] = true
                                if type(override.steps) ~= "table" then
                                    -- Non-table steps would crash CompileSteps; normalize to empty
                                    -- array so the variant survives the validator. ActivateSequence
                                    -- detects the empty-steps case at runtime and skips that
                                    -- variant's button creation (Engine/Engine.lua L920-930).
                                    GRIPEMS:Debug(
                                        string.format(
                                            "Variant override %d for sequence (modifier '%s') had non-table steps; normalized to empty array",
                                            ovIdx,
                                            tostring(mod)
                                        )
                                    )
                                    override.steps = {}
                                end
                                if #override.steps == 0 then
                                    -- Empty-steps overrides are tolerated (the /gems variants add
                                    -- MOD slash command creates this shape on purpose). The
                                    -- variant button is NOT created at activation -- the user is
                                    -- expected to populate the steps via Phase 2 UI or direct
                                    -- SavedVariable edit. Do NOT mark the sequence corrupt; do
                                    -- NOT break out of the outer validation loop.
                                    GRIPEMS:Debug(
                                        string.format(
                                            "Variant override %d for sequence (modifier '%s') has empty steps; variant button will be skipped at activation",
                                            ovIdx,
                                            tostring(mod)
                                        )
                                    )
                                end
                            end
                            if not valid then
                                break
                            end
                        end
                    end
                end

                -- Recommend source validation (IC-VAR-02 Phase 2). Both the
                -- sequence-level seqData.recommendSource fallback and the
                -- per-version ver.recommendSource are purely additive: a bad
                -- shape clears the offending field but never sets valid =
                -- false. The compiled function is not restored from
                -- SavedVariables anyway -- RecommendationEvaluator recompiles
                -- via loadstring at activation -- so a stale shape only
                -- surfaces at first eval and falls silently to nil (base
                -- variant armed). Reject non-string with a debug warning +
                -- nil the field so subsequent compile attempts skip it.
                if valid then
                    if seqData.recommendSource ~= nil and type(seqData.recommendSource) ~= "string" then
                        GRIPEMS:Debug(
                            string.format(
                                "Sequence '%s' has non-string recommendSource (type %s); dropping field.",
                                tostring(name),
                                type(seqData.recommendSource)
                            )
                        )
                        seqData.recommendSource = nil
                    end
                    if type(seqData.versions) == "table" then
                        for vIdx, ver in ipairs(seqData.versions) do
                            if
                                type(ver) == "table"
                                and ver.recommendSource ~= nil
                                and type(ver.recommendSource) ~= "string"
                            then
                                GRIPEMS:Debug(
                                    string.format(
                                        "Sequence '%s' version %d has non-string recommendSource (type %s); dropping field.",
                                        tostring(name),
                                        vIdx,
                                        type(ver.recommendSource)
                                    )
                                )
                                ver.recommendSource = nil
                            end
                        end
                    end
                end
            end

            if valid then
                -- Migrate and activate inside pcall for safety
                local ok, err = pcall(function()
                    seqData = self:MigrateSequenceFormat(seqData)
                    GRIP_EMS_CHAR.sequences[name] = seqData
                    local ver = self:GetActiveVersion(seqData)
                    if ver then
                        local seqClass = seqData.classID or 0
                        if seqClass == playerClassID or seqClass == 0 then
                            if GRIPEMS.OOCQueue and GRIPEMS.OOCQueue:IsRestricted() then
                                -- R1 deeper fix, corrected 2026-06-07: this branch now only
                                -- triggers for a /reload during combat lockdown. WoW gates
                                -- protected button setup on InCombatLockdown() alone; the
                                -- AddOnRestriction states (arena PvPMatch, Mythic+
                                -- ChallengeMode, raid Encounter) are secret-value contexts
                                -- and do not block protected setup out of combat. Register
                                -- the data now (no protected work) and queue activation; the
                                -- OOCQueue drains on PLAYER_REGEN_ENABLED / restriction lift /
                                -- the periodic ticker. Guarantees recovery without another
                                -- /reload and avoids the inline path that R1 Fix A guards.
                                self:RegisterSequenceOnly(name, seqData)
                                GRIPEMS.OOCQueue:Add(function()
                                    Engine:ActivateDormantSequence(name)
                                end, D.OOC_OP_ACTIVATE, name)
                                restrictedDeferred = restrictedDeferred + 1
                            else
                                self:ActivateSequence(name, seqData)
                                count = count + 1
                            end
                        else
                            self:RegisterSequenceOnly(name, seqData)
                            dormantCount = dormantCount + 1
                        end
                    end
                end)
                if not ok then
                    -- BUG-ARENA-RELOAD-WIPE (R1): activation can fail at restore for a
                    -- TRANSIENT reason -- a protected/secure op blocked under an
                    -- AddOnRestriction (arena PvPMatch, M+ ChallengeMode, raid Encounter)
                    -- when IsRestricted() under-reports the state, or a secret-value
                    -- error in a restricted context. This is NOT data corruption: the
                    -- sequence data is already persisted in GRIP_EMS_CHAR.sequences
                    -- (assigned above, before activation). Routing it to the
                    -- delete-capable corrupt queue offers the user a Delete that
                    -- permanently drops valid data on the next save. Keep it in
                    -- SavedVariables and log it; the next unrestricted reload
                    -- re-activates it. Structural corruption is still caught by the
                    -- valid==false branch below.
                    GRIPEMS:Debug(
                        "RestoreSavedSequences: activation failed for '"
                            .. tostring(name)
                            .. "' (kept in SavedVariables, not quarantined): "
                            .. tostring(err)
                    )
                end
            else
                table.insert(self.corruptSequences, {
                    name = name,
                    data = seqData,
                    error = errorMsg,
                })
            end
        end
    end
    if count > 0 then
        GRIPEMS:Print(string.format(L["GEMS_RESTORED"], count))
    end
    if dormantCount > 0 then
        GRIPEMS:Debug(L["GEMS_DORMANT_LOADED"], dormantCount)
    end
    if restrictedDeferred > 0 then
        GRIPEMS:Print(string.format(L["GEMS_RESTRICTED_PAUSED"], restrictedDeferred))
    end
    -- Schedule corrupt handler after login completes (UI must be ready)
    if #self.corruptSequences > 0 then
        if C_Timer and C_Timer.After then
            C_Timer.After(2, function()
                Engine:ProcessNextCorrupt()
            end)
        end
    end
    -- Publish LAST so the account-scoped metadata index reflects post-migration
    -- state and includes anything just claimed from the outbox.
    if GRIPEMS.CharIndex then
        GRIPEMS.CharIndex:Publish()
    end
end

--- Update sequence data in-place. If stepFunction changed -- detected by
--- old/new comparison for new-table saves, or by the wrapped-body check for
--- in-place mutators -- deactivate+reactivate so the WrapScript re-wraps.
--- @param name string Sequence name
--- @param seqData table Updated sequence data
function Engine:UpdateSequenceData(name, seqData)
    if not name or not seqData then
        return
    end
    local entry = self.sequences[name]
    if not entry then
        return
    end

    if not entry.button then
        -- Dormant sequence: activate it first (user is editing)
        self:ActivateDormantSequence(name)
        entry = self.sequences[name]
        if not entry or not entry.button then
            return
        end
    end

    seqData.updatedAt = time()

    -- Locale: re-tag to canonical IDs and re-render to the client locale on every
    -- save (covers edit-save and new-from-scratch authored in any locale).
    local SC = GRIPEMS.SpellCache
    if SC and SC.ready then
        for _, version in ipairs(type(seqData.versions) == "table" and seqData.versions or {}) do
            SC:NormalizeVersionLocale(version, seqData.classID)
        end
    end

    -- Check if step count changed (requires WrapScript rebuild for new Execute data)
    local oldVer = self:GetActiveVersion(entry.data)
    local newVer = self:GetActiveVersion(seqData)
    local oldStepCount = oldVer and #oldVer.steps or 0
    local newStepCount = newVer and #newVer.steps or 0
    local stepsChanged = oldStepCount ~= newStepCount

    -- Check if stepFunction changed (requires engine rebuild)
    local oldStepFunc = oldVer and oldVer.stepFunction
    local newStepFunc = newVer and newVer.stepFunction

    -- In-place mutators (quick persists, version bar, set-default) pass
    -- entry.data itself, so oldStepFunc == newStepFunc by identity and a
    -- step-function change is invisible to the comparison above. The
    -- WrapScript OnClick advance body is per body CLASS (Random vs the
    -- shared Sequential round-robin that Priority/ReversePriority and
    -- plugin expanders cycle) and only a full rebuild re-wraps it, so also
    -- compare the body the button was wrapped with against the body the
    -- active version needs now.
    local bodyStale = false
    local wrappedBody = entry.button and entry.button._emsClickBody
    if wrappedBody and newVer then
        local needed = SF:Get(newStepFunc or D.STEP_SEQUENTIAL) or SF.Sequential
        bodyStale = needed.BuildClickBody() ~= wrappedBody
    end

    if oldStepFunc ~= newStepFunc or stepsChanged or bodyStale then
        -- Full rebuild required
        self:DeactivateSequence(name, true)
        self:ActivateSequence(name, seqData)
    else
        -- In-place update (no engine rebuild needed)
        entry.data = seqData
        -- Publish the per-version runtime attributes. This block used to be gated on
        -- "btn and not IsRestricted()" with NO fallback, so in combat the whole publish
        -- was skipped and never retried while the RecompileSequence call below still
        -- queued and landed, leaving the button carrying stale attributes until
        -- something else happened to republish. It now runs through the same OOCQueue
        -- gate the SETTING_CHANGED site at the bottom of this file already uses.
        --
        -- EVERY INPUT IS RE-RESOLVED AT DRAIN TIME AND NOTHING IS CAPTURED. A queued op
        -- can drain after a recompile, after a deactivation, or after a later edit, so a
        -- captured button or version table would reintroduce the stale-state bug one
        -- layer up. Re-resolving also makes the op self-correcting: two edits during one
        -- combat drain as two publishes of the same FINAL state rather than replaying an
        -- older one.
        local function doPublish()
            local curEntry = self.sequences[name]
            local curBtn = curEntry and curEntry.button
            if not curBtn then
                return
            end
            local curVer = self:GetActiveVersion(curEntry.data)
            if not curVer then
                return
            end
            curBtn:SetAttribute("resetTimer", curVer.resetTimer or 0)
            -- Refresh per-sequence reset modifier attributes
            local seqResetMods = curVer.resetModifiers
            local globalMods = GRIPEMS.Settings:GetResetModifiers()
            local resetMods
            if seqResetMods then
                resetMods = {}
                for mod, default in pairs(globalMods) do
                    if seqResetMods[mod] ~= nil then
                        resetMods[mod] = seqResetMods[mod]
                    else
                        resetMods[mod] = default
                    end
                end
            else
                resetMods = globalMods
            end
            for mod, enabled in pairs(resetMods) do
                curBtn:SetAttribute("resetMod_" .. mod, enabled and "1" or nil)
            end
            -- Per-version channel hold, refreshed alongside the reset modifiers on
            -- the version-switch path so a switch cannot leave a stale attribute.
            --
            -- Cleared wherever releaseAtMax is published. empowerRelease is written to
            -- the button ONLY by a step commit, so publishing releaseAtMax always clears
            -- it and only a step commit sets it. This clear remains DEFENCE IN DEPTH --
            -- the load-bearing one is at the head of doRecompile, which covers the seven
            -- RecompileSequence call sites that do not publish first -- but with the
            -- queue fallback above it now actually lands in combat instead of being
            -- dropped.
            curBtn:SetAttribute("holdOnChannel", curVer.holdOnChannel and "1" or nil)
            curBtn:SetAttribute("releaseAtMax", curVer.releaseAtMax and "1" or nil)
            curBtn:SetAttribute("empowerRelease", nil)
        end
        if GRIPEMS.OOCQueue.IsRestricted() then
            GRIPEMS.OOCQueue:Add(doPublish, D.OOC_OP_SETTING, name)
        else
            doPublish()
        end
        if _G.GRIP_EMS_CHAR and GRIP_EMS_CHAR.sequences then
            GRIP_EMS_CHAR.sequences[name] = seqData
        end
        -- Recompile step data into the restricted environment so edited step
        -- text takes effect immediately, without requiring a relog. (BUG-029 Issue B)
        self:RecompileSequence(name)
    end

    if GRIPEMS.Fire then
        GRIPEMS:Fire("SEQUENCE_UPDATED", name, seqData)
    end
end

--- Notify the user that a sequence rebuild failed. Called from both
--- ActivateSequence and RecompileSequence on btn:Execute failure.
--- Strategy 1 user diagnostic: chat warning + session-scope log.
--- @param name string Sequence name
--- @param err any Error captured from pcall
function Engine:_NotifySequenceRefreshFailure(name, err)
    if type(name) ~= "string" or name == "" then
        return
    end
    local errText = tostring(err or "")
    GRIPEMS:Print(string.format(L["GEMS_SEQUENCE_REFRESH_FAILED"], name))
    self._refreshFailures = self._refreshFailures or {}
    self._refreshFailures[name] = {
        time = time(),
        err = errText,
    }
end

--- Recompile a sequence's steps after a variable value changed.
--- Re-runs CompileSteps + BuildExecuteString + btn:Execute() to reload
--- step data with updated variable values. Must go through OOCQueue if in combat.
--- @param name string Sequence name
function Engine:RecompileSequence(name)
    if not name then
        return
    end
    local entry = self.sequences[name]
    if not entry or not entry.data or not entry.button then
        return
    end

    local seqData = entry.data
    local ver = self:GetActiveVersion(seqData)
    if not ver then
        return
    end
    -- Action tree compilation: flatten actions to steps + labels before runtime use.
    -- ARCH-MIGRATE Phase 1: import-baked versions keep their baked steps (flag set at legacy import).
    if ver.actions and #ver.actions > 0 and not ver.importBakedSteps then
        ver.steps, ver.compiledLabels = GRIPEMS.ActionCompiler.CompileActions(ver.actions, self, ver)
    end
    if type(ver.steps) ~= "table" or #ver.steps == 0 then
        return
    end

    GRIPEMS:Debug(L["GEMS_VAR_RECOMPILE"], name)

    local function doRecompile()
        local btn = entry.button
        if not btn then
            return
        end

        -- THE INVARIANT LIVES HERE, not only at the publish sites. A recompile is the
        -- event that re-evaluates the four-arm step-function branch and swaps the steps
        -- table, so it is the moment the PRODUCER of empowerRelease can change: the
        -- Priority, ReversePriority and plugin-expander arms publish it through
        -- StampEmpowerReleases while the CompileSteps arm publishes it per step, and a
        -- switch between them must not leave the outgoing arm's text armed. Clearing at
        -- the releaseAtMax publish sites is not sufficient on its own, because
        -- Engine:UpdateSequenceData skips its whole publish block in combat with no
        -- OOCQueue fallback while THIS function queues and therefore still lands. Eight
        -- call sites reach RecompileSequence and only one of them publishes first.
        -- Fail direction is deliberate: clearing too often costs at most one missed
        -- release, which falls back to the auto-cast at max and self-heals on the next
        -- step commit, while not clearing casts the wrong spell until a reload.
        btn:SetAttribute("empowerRelease", nil)

        local stepsToLoad = ver.steps
        local kp = ver.keyPress or ""
        local kr = ver.keyRelease or ""
        -- Priority/ReversePriority: pre-expand into flat single-step arrays
        local compiledSteps
        if ver.stepFunction == D.STEP_PRIORITY then
            compiledSteps = ResolveFitAndExpand(self, stepsToLoad, kp, kr, function(r)
                return SF:ExpandPriority(r)
            end)
        elseif ver.stepFunction == D.STEP_REVERSE_PRIORITY then
            compiledSteps = ResolveFitAndExpand(self, stepsToLoad, kp, kr, function(r)
                return SF:ExpandReversePriority(r)
            end)
        elseif SF:IsExpander(ver.stepFunction) then
            compiledSteps = ResolveFitAndExpand(self, stepsToLoad, kp, kr, function(r)
                return SF:RunExpander(ver.stepFunction, r)
            end)
        else
            compiledSteps = self:CompileSteps(stepsToLoad, kp, kr)
        end

        local execStr = self:BuildExecuteString(compiledSteps)
        local ok, err = true, nil
        if not self:DeferIfBraced(name, btn, execStr, compiledSteps, "recompile", "base") then
            ok, err = pcall(btn.Execute, btn, execStr)
            if ok then
                btn._numExecSteps = #compiledSteps
                btn._execSteps = compiledSteps
                btn._execLabels =
                    self:BuildExecLabels(ver and (ver.compiledLabels or ver.stepLabels), ver.stepFunction, #stepsToLoad)
            end
        end
        if not ok then
            GRIPEMS:Debug("Execute failed: " .. tostring(err))
            -- Strategy 2 auto-recovery: in-place btn:Execute failed.
            -- Fall back to Branch A full rebuild (Deactivate + Activate),
            -- which creates a fresh frame and avoids per-button state
            -- that may have caused the in-place failure. ActivateSequence
            -- surfaces its own warning if its btn:Execute also fails.
            -- ActivateSequence rebuilds variant buttons too, so we do not
            -- need to recompile them separately here. (IC-VAR-02 Phase 1)
            GRIPEMS:Debug("RecompileSequence: auto-rebuild for " .. name)
            Engine:DeactivateSequence(name, true)
            Engine:ActivateSequence(name, entry.data)
            return
        end

        -- Update macro stub body with current keyPress/keyRelease
        MM:UpdateStubBody(name, kp, kr, stepsToLoad)

        -- Recompile variant buttons (IC-VAR-02 Phase 1). Walks every override
        -- and refreshes its variant button's Execute payload so the OOCQueue
        -- RECOMPILE op (driven by IC-VAR-03's Smart Auto-Reload) refreshes
        -- every variant, not just the base.
        local overrides = ver.variantOverrides or {}
        for ovIdx, override in ipairs(overrides) do
            local vb = entry.variantButtons and entry.variantButtons[ovIdx]
            if vb then
                -- Same invariant as the base button above. doRecompile refreshes every variant
                -- button's Execute payload, and the variant publish site is reached only from
                -- ActivateSequence, never from a recompile.
                vb:SetAttribute("empowerRelease", nil)
                local effKp = override.keyPress or kp
                local effKr = override.keyRelease or kr
                local effSteps = override.steps
                if effSteps and #effSteps > 0 then
                    local effCompiled
                    if ver.stepFunction == D.STEP_PRIORITY then
                        effCompiled = ResolveFitAndExpand(self, effSteps, effKp, effKr, function(r)
                            return SF:ExpandPriority(r)
                        end)
                    elseif ver.stepFunction == D.STEP_REVERSE_PRIORITY then
                        effCompiled = ResolveFitAndExpand(self, effSteps, effKp, effKr, function(r)
                            return SF:ExpandReversePriority(r)
                        end)
                    elseif SF:IsExpander(ver.stepFunction) then
                        effCompiled = ResolveFitAndExpand(self, effSteps, effKp, effKr, function(r)
                            return SF:RunExpander(ver.stepFunction, r)
                        end)
                    else
                        effCompiled = self:CompileSteps(effSteps, effKp, effKr)
                    end
                    local effExec = self:BuildExecuteString(effCompiled)
                    local vOk, vErr = true, nil
                    if
                        not self:DeferIfBraced(
                            name,
                            vb,
                            effExec,
                            effCompiled,
                            "recompile-variant " .. (ovIdx + 1),
                            "v" .. (ovIdx + 1)
                        )
                    then
                        vOk, vErr = pcall(vb.Execute, vb, effExec)
                        if vOk then
                            vb._numExecSteps = #effCompiled
                            vb._execSteps = effCompiled
                            -- Variant overrides carry no per-step labels (see ActivateSequence).
                            vb._execLabels = nil
                        end
                    end
                    if not vOk then
                        GRIPEMS:Debug(
                            "Variant recompile failed for " .. name .. " v" .. (ovIdx + 1) .. ": " .. tostring(vErr)
                        )
                    end
                end
            end
        end
    end

    GRIPEMS.OOCQueue:Add(doRecompile, D.OOC_OP_RECOMPILE, name)
end

--- Would this button's compiled array stamp a release it is not currently
--- carrying? Reads the CACHED compiled array rather than recompiling, so the
--- scan is cheap enough to run on every button on a spell-cache refresh.
---
--- ONE KNOWN FALSE POSITIVE, NAMED RATHER THAN LEFT SILENT. entry.macrotext is
--- the COMBINED text (keyPress .. step .. keyRelease) whenever the combination
--- fit the 255-char cap, while the stamp is computed from the step's OWN
--- resolved text -- deliberately, so a keyPress casting an empowered spell
--- cannot win over the spell the step itself casts. A sequence whose keyPress
--- casts an empower while no step does therefore reads as stale here. The cost
--- is exactly one wasted recompile, because the recompile re-stamps "" (the
--- correct value) and the caller's latch stops the scan repeating. Reading the
--- step's own text back out of the combined string would mean re-deriving the
--- fit, which is the thing that produced this class of bug in the first place.
--- @param engine table Engine instance (for EmpowerReleaseFor)
--- @param btn table|nil A secure button carrying a compiled _execSteps array
--- @return boolean true when at least one entry is missing a release it earns
local function ButtonNeedsEmpowerHeal(engine, btn)
    local exec = btn and btn._execSteps
    if type(exec) ~= "table" then
        return false
    end
    for i = 1, #exec do
        local e = exec[i]
        if type(e) == "table" and (e.empowerRelease == nil or e.empowerRelease == "") then
            if engine:EmpowerReleaseFor(e.macrotext) ~= "" then
                return true
            end
        end
    end
    return false
end

--- Same test across a sequence's whole button set. A variant override carries
--- its own steps and its own compiled array, so a variant can be stale while
--- the base is clean; one RecompileSequence refreshes base and variants alike,
--- so either answering yes is enough to schedule the single recompile.
--- @param engine table Engine instance
--- @param entry table|nil A self.sequences entry
--- @return boolean
local function SequenceNeedsEmpowerHeal(engine, entry)
    if type(entry) ~= "table" then
        return false
    end
    if ButtonNeedsEmpowerHeal(engine, entry.button) then
        return true
    end
    local variants = entry.variantButtons
    if type(variants) == "table" then
        for _, vb in pairs(variants) do
            if ButtonNeedsEmpowerHeal(engine, vb) then
                return true
            end
        end
    end
    return false
end

--- Heal sequences that compiled BEFORE the empower data existed.
--- EMPOWER-RELEASE-INERT-UNTIL-RECOMPILE: empowerRelease is baked into the
--- compiled step table at compile time, and at login and at every reload the
--- compile runs before SC:Scan has walked the spellbook, so every step stamps
--- "" and nothing re-stamps it. The hold still works and the empower still
--- completes on its own, so the failure is silent -- the user simply never gets
--- the release they enabled, for the whole session, unless they happen to edit
--- the sequence and trigger a recompile by hand.
---
--- WHY RE-STAMP-ON-READY AND NOT RESOLVE-AT-PRESS-TIME. Resolving lazily would
--- remove the ordering dependency instead of racing it, and it is not
--- available: the press path is the WrapScript OnClick body, which runs in the
--- RESTRICTED environment. All three readers sit inside a snippet and reach the
--- value only through self:GetAttribute -- Engine/StepFunctions.lua:58
--- (Sequential), :164 (Random) and Engine/TempoAdvisor.lua:233 (the native
--- button's preBody). The lookup needs SpellValidator:ExtractAllSpells and
--- three SpellCache methods, none of which exist in that environment, and the
--- macrotext has to be set inside the snippet before the click resolves, so
--- deferring it to an insecure CallMethod would land after the press it was
--- meant to serve. The choice is not a cost comparison; the second direction
--- has no implementation.
---
--- WHY A WHOLE RECOMPILE RATHER THAN AN IN-PLACE RE-STAMP. Re-stamping from
--- entry.macrotext would read the COMBINED text and silently let a keyPress
--- decide the release, inverting the rule the per-step computation exists to
--- enforce. RecompileSequence re-runs the real four-arm compile branch, so both
--- producers of the field (StampEmpowerReleases for the Priority,
--- ReversePriority and plugin-expander arms, and the per-step assignment in
--- CompileSteps for Sequential and Random) publish through their own path, and
--- variant buttons are refreshed in the same pass. No new semantics ship here.
---
--- LATCHED, so this is a one-shot per empower-availability transition rather
--- than a recompile of every sequence on every refresh. The latch clears
--- whenever no empower spell is known, which is also what makes a later spec
--- change INTO an empower spec heal again. A spec change BETWEEN two empower
--- specs does not re-heal; that is deliberate and costs nothing, because the
--- spellbook rescan changes the resolved names, which HealOverrideSteps
--- already recompiles on (on a display change, as of v2.4.4), and an unchanged
--- name keeps an unchanged stamp.
---
--- Detection is Engine:EmpowerReleaseFor, which reads SC:IsEmpowerSpell, which
--- reads the set the spellbook walk built from C_Spell.IsPressHoldReleaseSpell.
--- No class check, no spec check and no spell-ID literal is added here.
--- @return number Count of sequences re-queued for recompile
function Engine:HealEmpowerReleases()
    local SC = GRIPEMS.SpellCache
    if not (SC and SC.ready and SC.HasEmpowerSpells and SC:HasEmpowerSpells()) then
        -- No empower spell is known, so "" is the CORRECT stamp on every step
        -- and there is nothing to heal. Clearing the latch on this branch is
        -- what lets a later transition into an empower spec heal.
        self._empowerHealed = nil
        return 0
    end
    if self._empowerHealed then
        return 0
    end
    self._empowerHealed = true

    -- Names are collected BEFORE any recompile, for the reason
    -- RetryCappedBraceReloads collects them: RecompileSequence's Execute-failure
    -- branch auto-recovers via DeactivateSequence + ActivateSequence, and
    -- DeactivateSequence removes the entry, so recompiling inside the pairs walk
    -- would mutate the table being walked.
    local stale = {}
    for name, entry in pairs(self.sequences) do
        if type(name) == "string" and SequenceNeedsEmpowerHeal(self, entry) then
            stale[#stale + 1] = name
        end
    end
    for _, name in ipairs(stale) do
        self:RecompileSequence(name)
    end
    if #stale > 0 then
        GRIPEMS:Debug("Empower release heal: re-queued %d sequence(s) after the spell cache settled", #stale)
    end
    return #stale
end

--- Heal sequence steps after a WoW client locale change.
--- Checks each version's stepsLocale against GetLocale(). If mismatched
--- and taggedSteps exist, translates tagged spell IDs back to the current
--- locale's spell names. Recompiles any healed sequences.
--- Called on SPELL_CACHE_REFRESHED, from the handler Engine:RegisterCallbacks
--- installs. NOT registered at file load -- that is what this comment used to
--- claim, and that belief is what produced
--- ENGINE-TOPLEVEL-CALLBACKS-NEVER-REGISTERED: GRIPEMS.RegisterCallback does
--- not exist until Core's ADDON_LOADED handler builds it, so nothing at file
--- scope can register anything.
function Engine:HealLocaleSteps()
    local SC = GRIPEMS.SpellCache
    if not SC or not SC.ready then
        return
    end
    if not _G.GRIP_EMS_CHAR or not GRIP_EMS_CHAR.sequences then
        return
    end

    local currentLocale = GetLocale()
    local healed = 0

    for name, seqData in pairs(GRIP_EMS_CHAR.sequences) do
        if type(seqData) == "table" then
            local dirty = false
            for _, version in ipairs(type(seqData.versions) == "table" and seqData.versions or {}) do
                if version.stepsLocale and version.stepsLocale ~= currentLocale and version.taggedSteps then
                    -- Preserve original author text before healing
                    if not version.stepsOriginal then
                        local orig = {}
                        for si, s in ipairs(version.steps) do
                            orig[si] = s
                        end
                        version.stepsOriginal = orig
                    end
                    -- Heal steps from tagged spell ID data
                    for i, taggedStep in ipairs(version.taggedSteps) do
                        version.steps[i] = SC:TranslateMacrotext(taggedStep, "toNames")
                    end
                    -- Heal keyPress
                    if version.taggedKeyPress and version.taggedKeyPress ~= "" then
                        version.keyPress = SC:TranslateMacrotext(version.taggedKeyPress, "toNames")
                    end
                    -- Heal keyRelease
                    if version.taggedKeyRelease and version.taggedKeyRelease ~= "" then
                        version.keyRelease = SC:TranslateMacrotext(version.taggedKeyRelease, "toNames")
                    end
                    -- Re-tag with new locale names so taggedSteps stays current
                    version.taggedSteps = SC:TagSteps(version.steps, { classID = seqData.classID })
                    if version.keyPress and version.keyPress ~= "" then
                        version.taggedKeyPress =
                            SC:TranslateMacrotext(version.keyPress, "toIDs", { classID = seqData.classID })
                    end
                    if version.keyRelease and version.keyRelease ~= "" then
                        version.taggedKeyRelease =
                            SC:TranslateMacrotext(version.keyRelease, "toIDs", { classID = seqData.classID })
                    end
                    -- Locale: re-localize the action tree too, so the
                    -- RecompileSequence below (which rebuilds steps from
                    -- ver.actions) emits client-locale cast text.
                    if SC.NormalizeActionsLocale then
                        SC:NormalizeActionsLocale(version.actions, { classID = seqData.classID })
                    end
                    version.stepsLocale = currentLocale
                    dirty = true
                end
            end
            if dirty then
                self:RecompileSequence(name)
                healed = healed + 1
            end
        end
    end

    if healed > 0 then
        GRIPEMS:Print(string.format("Locale change detected: healed %d sequence(s) from %s.", healed, currentLocale))
        -- HealOverrideSteps now runs unconditionally from the SPELL_CACHE_REFRESHED
        -- callback (see L2005), so the previous in-line chain here is redundant.
    end
end

--- Compare two override-display entries for equality.
--- nil is a legal value on both sides: it means "no override differs from the
--- persisted text for this version", which is the common answer and must
--- compare equal to itself so an idle heal does not recompile the world.
--- The steps map is sparse (only differing indices are recorded), so it is
--- walked in BOTH directions -- a one-way walk reports equal when one side
--- carries an index the other does not.
--- @param prev table|nil The entry recorded by the previous walk
--- @param entry table|nil The entry produced by this walk
--- @return boolean true when the two describe the same display state
function Engine:_OverrideDisplayEqual(prev, entry)
    if prev == nil and entry == nil then
        return true
    end
    if prev == nil or entry == nil then
        return false
    end
    if prev.keyPress ~= entry.keyPress or prev.keyRelease ~= entry.keyRelease then
        return false
    end
    for i, v in pairs(prev.steps or {}) do
        if (entry.steps or {})[i] ~= v then
            return false
        end
    end
    for i, v in pairs(entry.steps or {}) do
        if (prev.steps or {})[i] ~= v then
            return false
        end
    end
    return true
end

--- Resolve the ACTIVE spell-override name for every stored step, for DISPLAY.
--- Walks every sequence with taggedSteps; for each version, re-translates the
--- tagged spell IDs with opts.useOverrides = true so whatever override is live
--- right now -- talent, hero talent, form, channel or proc -- lands in the
--- resolved string. The result is filed in Engine._overrideDisplay and read
--- back through Engine:GetOverrideDisplay. NOTHING here writes SavedVariables:
--- version.steps, version.keyPress and version.keyRelease are left untouched,
--- and so are version.taggedSteps and version.stepsLocale.
---
--- STALE-OVERRIDE-STEP-TEXT, why the write is gone. FindSpellOverrideByID
--- answers for whatever override is live at call time and cannot separate a
--- durable talent override from a transient one driven by a form, a channel or
--- a proc. Through v2.4.3 that answer was written into the three persisted
--- fields, so a heal taken while a proc was up stored a name the player cannot
--- cast once the proc drops, and the dead text survived in SavedVariables.
--- Blood DK San'layn stored "Vampiric Strike" over "Heart Strike"; Guardian
--- Druid stored "Ravage" over "Maul".
---
--- The durable answer is the BASE name, and WoW resolves /cast <base name>
--- through whatever override is live -- which is why Data/SpellCache.lua L1666
--- already says the spell's own ID is correct for export. Measured on a live
--- Guardian Druid 2026-08-17 (Research/Override_Name_Castability_Probe):
--- Maul 6807 is castable, known and in the spellbook, and GetOverrideSpell(
--- 6807, 0, true, X) returned 6807 for every ignore value, while Ravage 441583
--- resolves to an ID but not to a castable name. So persisted text carries the
--- base name and override resolution happens at draw time, where being wrong
--- costs a wrong label instead of a dead macro.
---
--- The combat gate stays. It is no longer load-bearing for correctness --
--- nothing is persisted now -- but an override read mid-fight produces a label
--- that is stale the moment the form drops, and the walk is not free.
--- PLAYER_REGEN_ENABLED re-schedules this via Engine:ScheduleOverrideHeal.
---
--- A version's entry is recorded ONLY where the resolved string DIFFERS from
--- the persisted text. Equal means there is nothing for the draw path to
--- prefer, so an absent entry is the answer and the fallback costs one nil
--- check. Dirty tracking follows that recorded entry rather than a stored-field
--- diff: nil -> present, present -> nil and present -> different each recompile
--- (the button re-reads the version so its icon follows the flip), while
--- nil -> nil and an unchanged entry do not.
---
--- Called on PLAYER_SPECIALIZATION_CHANGED, TRAIT_CONFIG_UPDATED, and -- via
--- the debounced Engine:ScheduleOverrideHeal -- PLAYER_REGEN_ENABLED,
--- UPDATE_OVERRIDE_ACTIONBAR and UPDATE_SHAPESHIFT_FORM.
function Engine:HealOverrideSteps()
    local SC = GRIPEMS.SpellCache
    if not SC or not SC.ready then
        return
    end
    if InCombatLockdown() then
        return
    end
    if not _G.GRIP_EMS_CHAR or not GRIP_EMS_CHAR.sequences then
        return
    end

    local opts = { useOverrides = true }
    local previous = type(self._overrideDisplay) == "table" and self._overrideDisplay or {}
    local display = {}
    local healed = 0

    for name, seqData in pairs(GRIP_EMS_CHAR.sequences) do
        if type(seqData) == "table" then
            local dirty = false
            local prevVersions = type(previous[name]) == "table" and previous[name] or {}
            for versionIndex, version in ipairs(type(seqData.versions) == "table" and seqData.versions or {}) do
                if version.taggedSteps then
                    -- sourceSteps records the persisted text the resolved name
                    -- stands in for. The draw path prefers the resolved name
                    -- only while the row still shows that exact text, so a step
                    -- the player has since edited renders what they typed
                    -- instead of a label left over from the last heal.
                    local entry = nil
                    local storedSteps = type(version.steps) == "table" and version.steps or {}
                    for i, taggedStep in ipairs(version.taggedSteps) do
                        local resolved = SC:TranslateMacrotext(taggedStep, "toNames", opts)
                        if resolved ~= storedSteps[i] then
                            entry = entry or { steps = {}, sourceSteps = {} }
                            entry.steps[i] = resolved
                            entry.sourceSteps[i] = storedSteps[i]
                        end
                    end
                    if version.taggedKeyPress and version.taggedKeyPress ~= "" then
                        local resolved = SC:TranslateMacrotext(version.taggedKeyPress, "toNames", opts)
                        if resolved ~= version.keyPress then
                            entry = entry or { steps = {}, sourceSteps = {} }
                            entry.keyPress = resolved
                            entry.sourceKeyPress = version.keyPress
                        end
                    end
                    if version.taggedKeyRelease and version.taggedKeyRelease ~= "" then
                        local resolved = SC:TranslateMacrotext(version.taggedKeyRelease, "toNames", opts)
                        if resolved ~= version.keyRelease then
                            entry = entry or { steps = {}, sourceSteps = {} }
                            entry.keyRelease = resolved
                            entry.sourceKeyRelease = version.keyRelease
                        end
                    end
                    if entry then
                        display[name] = display[name] or {}
                        display[name][versionIndex] = entry
                    end
                    if not self:_OverrideDisplayEqual(prevVersions[versionIndex], entry) then
                        dirty = true
                    end
                end
            end
            if dirty then
                self:RecompileSequence(name)
                healed = healed + 1
            end
        end
    end

    self._overrideDisplay = display

    if healed > 0 then
        GRIPEMS:Debug("HealOverrideSteps: override display changed for " .. healed .. " sequence(s).")
    end
end

--- Read the override-display entry recorded by Engine:HealOverrideSteps.
--- The draw path calls this per row, so every level is guarded and a missing
--- sequence, a missing version or a walk that has never run returns nil rather
--- than raising. nil means "render the persisted text", which is always a
--- correct answer -- the display layer is an improvement on the stored name,
--- never a prerequisite for showing one.
--- @param sequenceName string Name of the sequence being drawn
--- @param versionIndex number 1-based index into seqData.versions
--- @return table|nil entry { steps = { [i] = name }, sourceSteps = { [i] = text },
---   keyPress, sourceKeyPress, keyRelease, sourceKeyRelease }; nil when no
---   override differs from the persisted text for that version.
function Engine:GetOverrideDisplay(sequenceName, versionIndex)
    if type(sequenceName) ~= "string" or sequenceName == "" then
        return nil
    end
    local byName = self._overrideDisplay
    if type(byName) ~= "table" then
        return nil
    end
    local byVersion = byName[sequenceName]
    if type(byVersion) ~= "table" then
        return nil
    end
    local index = tonumber(versionIndex)
    if not index then
        return nil
    end
    local entry = byVersion[index]
    if type(entry) ~= "table" then
        return nil
    end
    return entry
end

--- One hop from a poisoned TAG back to the base spell's name.
---
--- Called only on a row the plain re-derive could not repair, which means the
--- tag itself resolves to the stored name and the TAG is what is wrong. Every
--- {spell:N} in the tagged text is put through SC:GetBaseSpellID once. A
--- DIFFERENT id is a real base link and is substituted; the SAME id means
--- neither the API nor D.BASE_SPELL_TABLE has anything, and that token is left
--- as it was. When no token moved this returns nil and the caller leaves the row
--- untouched.
---
--- Scope, deliberately narrow: one lookup per token, no override resolution, no
--- chain walking, no second hop. The tagged text itself is NOT rewritten -- only
--- the name derived from it. The display walk already normalises through
--- FindBaseSpellByID before applying overrides (Data/SpellCache.lua), so a tag
--- left in the override's own id still draws correctly, and rewriting stored
--- references is a wider change than repairing stored text.
---
--- GUARDS, and which of them are still load-bearing after delegation.
--- SC:GetBaseSpellID owns the API existence check and the bounds guard, so the
--- inline copies of both are gone rather than duplicated. What remains:
---   * the SC.GetBaseSpellID type check, because SC arrives as a parameter and a
---     harness or a partial load can hand over a table without it, and calling a
---     nil field raises.
---   * the pcall, and NOT out of habit. SC:GetBaseSpellID calls SC:IsValidSpellID
---     UNCONDITIONALLY and has no pcall of its own, so an SC missing that method
---     now raises INSIDE the delegate. Measured 12.1.0.69299:
---     FindBaseSpellByID(2147483648) and (4294967296) both throw "outside of
---     expected range", while (0) and (-1) return nil, and SC:IsValidSpellID
---     rejects <= 0 and > 2147483647 -- so its bounds exactly cover the throw
---     range and the pcall is dead weight on the happy path. It is kept for the
---     missing-IsValidSpellID branch, which this function cannot see from here.
--- This runs inside a login-time migration: a raise here is a broken login, not
--- a wrong label.
--- @param taggedText string The stored tagged macrotext for this row
--- @param SC table The SpellCache module, already verified by the caller
--- @return string|nil name The re-derived base name, or nil when nothing recovered
function Engine:_RecoverPoisonedTagName(taggedText, SC)
    if type(taggedText) ~= "string" or taggedText == "" then
        return nil
    end
    if type(SC.GetBaseSpellID) ~= "function" then
        return nil
    end
    local moved = false
    local rebuilt = taggedText:gsub("{spell:(%d+)}", function(digits)
        local id = tonumber(digits)
        if not id then
            return nil
        end
        -- DELEGATED as of v2.4.4 Phase 4. This used to call
        -- C_SpellBook.FindBaseSpellByID inline, duplicating SC:GetBaseSpellID's
        -- API call, bounds guard and existence check -- and, more to the point,
        -- bypassing D.BASE_SPELL_TABLE, so the recovery could never benefit from
        -- a populated table. It now asks the one function that owns that answer.
        -- The "different id means a real base link" test below still reads
        -- correctly, because SC:GetBaseSpellID returns its input unchanged when
        -- neither the API nor the table has anything.
        local ok, baseID = pcall(SC.GetBaseSpellID, SC, id)
        if not ok or type(baseID) ~= "number" or baseID == id then
            return nil
        end
        moved = true
        return "{spell:" .. baseID .. "}"
    end)
    if not moved then
        return nil
    end
    -- NO opts on the re-derive, exactly as the first pass: the base id must
    -- resolve as itself, with no override logic reintroduced.
    local name = SC:TranslateMacrotext(rebuilt, "toNames")
    if type(name) ~= "string" or name == "" then
        return nil
    end
    return name
end

-- One-time repair for step text already poisoned by the pre-v2.4.4 writer.
--
-- TWO SHAPES OF DAMAGE, AND ONLY ONE OF THEM IS ALWAYS RECOVERABLE.
--
-- Shape one, a poisoned NAME whose TAG is still the base id. Re-deriving the
-- name from that tag with NO opts runs no override logic and lands back on the
-- base name, so this always recovers. That is the first pass below.
--
-- Shape two, a poisoned TAG: the stored reference is the override's own id
-- rather than the base spell's. Whether that recovers is NOT a property of the
-- override's kind, and the earlier version of this comment was wrong to say so.
-- It claimed the base lookup fails because "the replacement chain does not
-- exist for a proc override". Measured on a live Guardian Druid (Sataanoir,
-- 12.1.0.69299), with C_SpellBook.FindBaseSpellByID:
--
--     441583  Ravage  ->  441583   no recovery
--     400254  Raze    ->    6807   RECOVERS to Maul
--       6807  Maul    ->    6807   identity, the unpoisoned control
--
-- Ravage and Raze are BOTH talent overrides of Maul, and NEITHER was talented
-- at measurement time. So the discriminator is not proc versus talent, and it
-- is not whether the override is currently live. It is whether that spell's own
-- data carries a base link at all. Raze does; Ravage does not.
--
-- The second pass below therefore makes ONE hop: on a row the first pass could
-- not repair, resolve the tag to its id and ask FindBaseSpellByID once. A
-- DIFFERENT id is a real base link and the name is re-derived from it. The SAME
-- id means the API has nothing to offer, and the row is left exactly as it was.
-- This is deliberately not a general override resolver: it is one lookup on a
-- tag already known to be poisoned.
--
-- CONCLUSION UNCHANGED, only narrowed. The Ravage class has no route back
-- through any API on this build, so the offline override-to-base map is still
-- needed and is tracked as EMS-OVERRIDE-BASE-MAP-OFFLINE. Until it exists this
-- function leaves those rows alone rather than emitting a name it cannot
-- justify, which is the defect this whole release exists to remove.
--
-- Note for anyone extending this: C_SpellBook.GetBaseSpell does NOT exist on
-- this build. A previous draft of this comment cited it. FindBaseSpellByID is
-- the function that is actually there, and it is existence-checked below
-- because an error inside a migration is a broken login, not a wrong label.
--
-- Gated per character on GRIP_EMS_CHAR.overrideNameRepairV1, the same shape
-- RunHandleTokenRecovery and RunBareNameMacroHeal use in Data/SpellCache.lua.
-- Dispatched from SC:RegisterMigrations alongside them.
--- @return number repaired Count of versions whose persisted text changed
function Engine:RepairPersistedOverrideNames()
    local SC = GRIPEMS.SpellCache
    if not SC or not SC.ready or type(SC.TranslateMacrotext) ~= "function" then
        return 0
    end
    if not _G.GRIP_EMS_CHAR or GRIP_EMS_CHAR.overrideNameRepairV1 then
        return 0
    end
    if type(GRIP_EMS_CHAR.sequences) ~= "table" then
        GRIP_EMS_CHAR.overrideNameRepairV1 = true
        return 0
    end

    local repaired = 0
    for name, seqData in pairs(GRIP_EMS_CHAR.sequences) do
        if type(seqData) == "table" then
            local seqChanged = false
            for _, version in ipairs(type(seqData.versions) == "table" and seqData.versions or {}) do
                local changed = false
                if type(version.taggedSteps) == "table" and type(version.steps) == "table" then
                    for i, taggedStep in ipairs(version.taggedSteps) do
                        -- NO opts: the base name is exactly what the tag says
                        -- when no override logic runs.
                        local base = SC:TranslateMacrotext(taggedStep, "toNames")
                        if type(base) == "string" and base ~= "" and base ~= version.steps[i] then
                            version.steps[i] = base
                            changed = true
                        else
                            -- The tag resolves to the name already stored, so
                            -- the NAME is not what is wrong here: the TAG is.
                            -- One hop back through the base link, which recovers
                            -- the Raze class and returns nil for the Ravage one.
                            local recovered = self:_RecoverPoisonedTagName(taggedStep, SC)
                            if recovered and recovered ~= version.steps[i] then
                                version.steps[i] = recovered
                                changed = true
                            end
                        end
                    end
                end
                if type(version.taggedKeyPress) == "string" and version.taggedKeyPress ~= "" then
                    local base = SC:TranslateMacrotext(version.taggedKeyPress, "toNames")
                    if type(base) == "string" and base ~= version.keyPress then
                        version.keyPress = base
                        changed = true
                    else
                        local recovered = self:_RecoverPoisonedTagName(version.taggedKeyPress, SC)
                        if recovered and recovered ~= version.keyPress then
                            version.keyPress = recovered
                            changed = true
                        end
                    end
                end
                if type(version.taggedKeyRelease) == "string" and version.taggedKeyRelease ~= "" then
                    local base = SC:TranslateMacrotext(version.taggedKeyRelease, "toNames")
                    if type(base) == "string" and base ~= version.keyRelease then
                        version.keyRelease = base
                        changed = true
                    else
                        local recovered = self:_RecoverPoisonedTagName(version.taggedKeyRelease, SC)
                        if recovered and recovered ~= version.keyRelease then
                            version.keyRelease = recovered
                            changed = true
                        end
                    end
                end
                if changed then
                    repaired = repaired + 1
                    seqChanged = true
                end
            end
            -- The button was compiled from the poisoned text, so the repair has
            -- to reach it or the dead macro stays live until something else
            -- recompiles. Guarded: this runs from a migration, and a sequence
            -- that is not registered has no button to rebuild.
            if
                seqChanged
                and type(self.RecompileSequence) == "function"
                and self.sequences
                and self.sequences[name]
            then
                self:RecompileSequence(name)
            end
        end
    end

    GRIP_EMS_CHAR.overrideNameRepairV1 = true
    if repaired > 0 then
        GRIPEMS:Debug("RepairPersistedOverrideNames: restored base names on " .. repaired .. " version(s).")
    end
    return repaired
end

--- Debounced entry point for Engine:HealOverrideSteps.
--- A form change or an action-bar swap can fire several events in one
--- frame, and each one would otherwise walk every stored sequence. The
--- timer collapses the burst into one heal. The callback re-checks
--- combat because the burst can start out of combat and land inside it;
--- when that happens PLAYER_REGEN_ENABLED schedules the next attempt.
function Engine:ScheduleOverrideHeal()
    if self._overrideHealTimer then
        self._overrideHealTimer:Cancel()
        self._overrideHealTimer = nil
    end
    if not C_Timer or not C_Timer.NewTimer then
        self:HealOverrideSteps()
        return
    end
    self._overrideHealTimer = C_Timer.NewTimer(D.OVERRIDE_HEAL_DEBOUNCE, function()
        Engine._overrideHealTimer = nil
        Engine:HealOverrideSteps()
    end)
end

--- Create a copy of an existing sequence under a new name.
--- @param sourceName string Name of the sequence to copy
--- @param newName string Name for the duplicate
--- @return boolean success
--- @return string|nil error Error message on failure
function Engine:DuplicateSequence(sourceName, newName)
    if not sourceName or not newName then
        return false, "Missing source or target name"
    end
    if newName == "" then
        return false, "New name cannot be empty"
    end
    if self.sequences[newName] then
        return false, string.format("Sequence '%s' already exists", newName)
    end

    local sourceEntry = self.sequences[sourceName]
    if not sourceEntry or not sourceEntry.data then
        return false, string.format("Source sequence '%s' not found", sourceName)
    end

    local src = sourceEntry.data

    -- Deep-copy the seqData (manually copy each field + all versions)
    local newData = {
        name = newName,
        icon = src.icon or D.QUESTION_MARK_ICON,
        autoIcon = src.autoIcon,
        defaultVersion = src.defaultVersion or 1,
        contextOverrides = {},
        versions = {},
        author = src.author or "",
        version = src.version or "1",
        description = src.description or "",
        -- v2.3.4: the talent code and source URL are part of the content the
        -- sequence was authored for -- a duplicate keeps them. StampForked
        -- signs the fork AFTER this literal, so the copy stays self-consistent.
        -- Phase 3: help/helplink/changelog ride along for the same reason
        -- (none are signature-canon fields; silent loss on fork otherwise).
        talentString = src.talentString,
        url = src.url,
        help = src.help or "",
        helplink = src.helplink or "",
        changelog = src.changelog,
        privacyMode = (GRIP_EMS_DB and GRIP_EMS_DB.config and GRIP_EMS_DB.config.privacyDefault)
            or (GRIPEMS.Defaults and GRIPEMS.Defaults.PRIVACY_MODE_DEFAULT)
            or "public",
        classID = src.classID or 0,
        specID = src.specID,
        createdAt = time(),
        updatedAt = time(),
    }

    -- v2.2.0 L87 FOLLOWUP-1: fork preserves MetaData so a forked sequence
    -- inherits the source's author-tagged macro deps. SaveSequence on the
    -- fork can then read MacrosTab.checkedMacros (hydrated by LoadSequence
    -- from the carried-forward MetaData.Dependencies.Macros) and round-trip
    -- the tag set. Without this, every fork loses tags silently.
    if src.MetaData then
        newData.MetaData = {}
        for k, v in pairs(src.MetaData) do
            if k ~= "Dependencies" then
                newData.MetaData[k] = v
            end
        end
        if src.MetaData.Dependencies then
            newData.MetaData.Dependencies = {}
            for dk, dv in pairs(src.MetaData.Dependencies) do
                if type(dv) == "table" then
                    local arrCopy = {}
                    for i, item in ipairs(dv) do
                        arrCopy[i] = item
                    end
                    newData.MetaData.Dependencies[dk] = arrCopy
                else
                    newData.MetaData.Dependencies[dk] = dv
                end
            end
        end
    end

    -- v2.3.4 Phase 3: per-sequence sound cue overrides follow the copy
    -- (fresh table -- never alias the source's map).
    if src.soundCues then
        newData.soundCues = {}
        for cueKey, cueVal in pairs(src.soundCues) do
            newData.soundCues[cueKey] = cueVal
        end
    end

    -- Deep copy all versions
    if type(src.versions) == "table" then
        for i, ver in ipairs(src.versions) do
            newData.versions[i] = D.CopyVersion(ver)
        end
    end
    -- Deep copy contextOverrides
    if src.contextOverrides then
        for k, v in pairs(src.contextOverrides) do
            newData.contextOverrides[k] = v
        end
    end

    -- v2.1.0 Phase C: every duplicate becomes a fork. The Identity module
    -- records the source's lineage in newData.forkedFrom and re-stamps the
    -- current user as the new Original Author with a fresh signature. This
    -- closes the v2.0.x forgery vector where a duplicate could carry the
    -- source author's identity + signature into a sequence the duplicating
    -- user controls.
    if GRIPEMS and GRIPEMS.Identity then
        GRIPEMS.Identity:StampForked(newData, src)
    end

    self:ActivateSequence(newName, newData)
    return true
end

---------------------------------------------------------------------------
-- Corrupt Sequence Recovery (StaticPopup chain)
---------------------------------------------------------------------------

-- Counters for summary message after all corrupt sequences are processed
local corruptDeleted = 0
local corruptSkipped = 0
local corruptExported = 0

--- Recursive table-to-string serializer for Export Raw.
--- Defensive: wraps top-level call in pcall. Handles string, number,
--- boolean, and nested table values. Non-serializable types show as
--- a placeholder string.
--- @param tbl table The table to serialize
--- @return string Readable Lua table dump
local function TableToString(tbl)
    local ok, result = pcall(function()
        local function serialize(val, indent)
            local pad = string.rep("  ", indent)
            local t = type(val)
            if t == "string" then
                return string.format("%q", val)
            elseif t == "number" or t == "boolean" then
                return tostring(val)
            elseif t == "table" then
                local parts = {}
                parts[#parts + 1] = "{"
                local innerPad = string.rep("  ", indent + 1)
                -- Array part
                local arrayLen = #val
                for i = 1, arrayLen do
                    parts[#parts + 1] = innerPad .. "[" .. i .. "] = " .. serialize(val[i], indent + 1) .. ","
                end
                -- Hash part
                for k, v in pairs(val) do
                    local skip = false
                    if type(k) == "number" and k >= 1 and k <= arrayLen and k == math.floor(k) then
                        skip = true
                    end
                    if not skip then
                        local keyStr
                        if type(k) == "string" then
                            keyStr = '["' .. k .. '"]'
                        else
                            keyStr = "[" .. tostring(k) .. "]"
                        end
                        parts[#parts + 1] = innerPad .. keyStr .. " = " .. serialize(v, indent + 1) .. ","
                    end
                end
                parts[#parts + 1] = pad .. "}"
                return table.concat(parts, "\n")
            else
                return '"<' .. t .. '>"'
            end
        end
        return serialize(tbl, 0)
    end)
    if ok then
        return result
    else
        return "-- Serialization failed: " .. tostring(result)
    end
end

--- Process the next corrupt sequence in the queue.
--- Shows a StaticPopup for user action or prints summary when done.
function Engine:ProcessNextCorrupt()
    if #self.corruptSequences == 0 then
        -- All processed, print summary
        if (corruptDeleted + corruptSkipped + corruptExported) > 0 then
            GRIPEMS:Print(string.format(L["GEMS_CORRUPT_SUMMARY"], corruptDeleted, corruptSkipped, corruptExported))
        end
        corruptDeleted = 0
        corruptSkipped = 0
        corruptExported = 0
        return
    end

    local entry = self.corruptSequences[1]
    local popupText = string.format(L["GEMS_CORRUPT_TEXT"], entry.name, entry.error)
    GRIPEMS.Popup:Show("GRIPEMS_CORRUPT_SEQUENCE", popupText)
end

GRIPEMS.Popup:Define("GRIPEMS_CORRUPT_SEQUENCE", {
    text = "%s",
    button1 = L["GEMS_CORRUPT_DELETE"],
    button2 = L["GEMS_CORRUPT_SKIP"],
    button3 = L["GEMS_CORRUPT_EXPORT"],
    OnAccept = function()
        -- Delete: remove from SavedVariables permanently
        local entry = table.remove(Engine.corruptSequences, 1)
        if entry and _G.GRIP_EMS_CHAR and GRIP_EMS_CHAR.sequences then
            GRIP_EMS_CHAR.sequences[entry.name] = nil
        end
        corruptDeleted = corruptDeleted + 1
        Engine:ProcessNextCorrupt()
    end,
    OnCancel = function()
        -- Skip: leave in SavedVariables, user can fix later
        table.remove(Engine.corruptSequences, 1)
        corruptSkipped = corruptSkipped + 1
        Engine:ProcessNextCorrupt()
    end,
    OnAlt = function()
        -- Export Raw: serialize table and show in ExportFrame
        local entry = table.remove(Engine.corruptSequences, 1)
        if entry then
            local rawString = TableToString(entry.data)
            local EF = GRIPEMS.ExportFrame
            if EF and EF.Show then
                EF:Show(nil, rawString)
            end
        end
        corruptExported = corruptExported + 1
        Engine:ProcessNextCorrupt()
    end,
    timeout = 0,
    hideOnEscape = false,
})

-- Event handling for reset conditions (named for /reload reuse)
local engineFrame = _G["GRIPEMS_EngineEvent"] or CreateFrame("Frame", "GRIPEMS_EngineEvent")
engineFrame:UnregisterAllEvents()
engineFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
engineFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
engineFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
engineFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
engineFrame:RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED")
engineFrame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
engineFrame:RegisterEvent("ZONE_CHANGED")
engineFrame:RegisterEvent("ZONE_CHANGED_INDOORS")
engineFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
engineFrame:RegisterEvent("PLAYER_DIFFICULTY_CHANGED")
engineFrame:RegisterEvent("INSTANCE_GROUP_SIZE_CHANGED")
engineFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
engineFrame:RegisterEvent("CHALLENGE_MODE_START")
engineFrame:RegisterEvent("CHALLENGE_MODE_COMPLETED")
engineFrame:RegisterEvent("PET_BATTLE_OPENING_DONE")
engineFrame:RegisterEvent("PET_BATTLE_CLOSE")
engineFrame:RegisterEvent("UPDATE_BONUS_ACTIONBAR")
engineFrame:RegisterEvent("UPDATE_VEHICLE_ACTIONBAR")
engineFrame:RegisterEvent("UPDATE_OVERRIDE_ACTIONBAR")
engineFrame:RegisterEvent("UPDATE_SHAPESHIFT_FORM")
engineFrame:RegisterEvent("UPDATE_BINDINGS")
-- Loadout observation events (Phase 1.5a, Section 6.0.2). PLAYER_ENTERING_WORLD and
-- PLAYER_SPECIALIZATION_CHANGED are already registered above; their handlers below
-- are extended to call Engine:UpdateLoadout() in addition to existing behavior.
engineFrame:RegisterEvent("ACTIVE_COMBAT_CONFIG_CHANGED")
engineFrame:RegisterEvent("TRAIT_CONFIG_UPDATED")
engineFrame:RegisterEvent("TRAIT_CONFIG_CREATED")
engineFrame:RegisterEvent("TRAIT_CONFIG_DELETED")
engineFrame:RegisterEvent("CONFIG_COMMIT_FAILED")
engineFrame:RegisterEvent("PLAYER_TALENT_UPDATE")
engineFrame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")

engineFrame:SetScript("OnEvent", function(_, event, ...)
    if event == "PLAYER_REGEN_ENABLED" then
        -- Reset step on sequences with resetOnCombat=true
        for name, entry in pairs(Engine.sequences) do
            local ver = Engine:GetActiveVersion(entry.data)
            if ver and ver.resetOnCombat then
                local btn = entry.button
                if btn then
                    btn:SetAttribute("step", 1)
                    GRIPEMS:Debug(L["GEMS_COMBAT_RESET"], name)
                    Engine:UpdateButtonIcon(btn, true)
                end
            end
        end
        -- STALE-OVERRIDE-STEP-TEXT: the heal is skipped during combat, so
        -- leaving combat is the moment the durable override answer is
        -- readable again. This is the backstop that fixes the reported case
        -- even when no bar-swap event fires.
        Engine:ScheduleOverrideHeal()
    elseif event == "PLAYER_TARGET_CHANGED" then
        -- v2.2.0 POLISH-1: dedupe PLAYER_TARGET_CHANGED. WoW 12.0
        -- Midnight soft-targeting cycles the internal target hint as
        -- nearby entities move / aggro / despawn, firing this event
        -- continuously (every 2-3s) even when UnitGUID("target") is
        -- unchanged or nil. Skip the reset when the actual target
        -- identity has not changed -- covers nil->nil pulses (AFK
        -- with no target) AND same-GUID re-targets (rare but possible
        -- if a macro re-selects the same unit). Cache update sits
        -- ABOVE the OOC gate so the cache stays accurate across
        -- combat boundaries; otherwise the first OOC event after
        -- combat could compare against a stale GUID and spuriously
        -- fire on the next real target change.
        local currentTargetGUID = UnitGUID("target")
        -- On 12.0.5 a combat target's GUID is a secret value; comparing it
        -- while execution is tainted by the addon throws ("attempt to
        -- compare ... a secret string value"). Guard the dedup compare -- if
        -- the value is not safely comparable, fall through (skip the dedup)
        -- instead of erroring. The reset loop below is OOC-gated, so skipping
        -- the dedup under taint changes nothing observable beyond not
        -- crashing.
        local sameTarget = false
        local compareOK = pcall(function()
            sameTarget = (currentTargetGUID == Engine._lastTargetGUID)
        end)
        if compareOK and sameTarget then
            return
        end
        Engine._lastTargetGUID = currentTargetGUID
        -- Reset step on target change, OOC only (Phase 1 limitation)
        if GRIPEMS.OOCQueue.IsRestricted() then
            return
        end
        for name, entry in pairs(Engine.sequences) do
            local ver = Engine:GetActiveVersion(entry.data)
            if ver and ver.resetOnTarget then
                local btn = entry.button
                if btn then
                    btn:SetAttribute("step", 1)
                    GRIPEMS:Debug(L["GEMS_TARGET_RESET"], name)
                    Engine:UpdateButtonIcon(btn, true)
                end
            end
        end
    elseif event == "PLAYER_EQUIPMENT_CHANGED" then
        local slot = ...
        -- Reset step on gear change, OOC only
        if GRIPEMS.OOCQueue.IsRestricted() then
            return
        end
        for name, entry in pairs(Engine.sequences) do
            local ver = Engine:GetActiveVersion(entry.data)
            if ver and ver.resetOnGear then
                local btn = entry.button
                if btn then
                    local wasStep = tonumber(btn:GetAttribute("step")) or 1
                    btn:SetAttribute("step", 1)
                    GRIPEMS:Debug(L["GEMS_GEAR_RESET"], name, wasStep, slot)
                    Engine:UpdateButtonIcon(btn, true)
                end
            end
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        -- Detect context before restoring sequences (so GetActiveVersion picks
        -- the correct version on first activation). UpdateContext + UpdateLoadout
        -- run on EVERY PLAYER_ENTERING_WORLD because instance context and
        -- loadout state are legitimately per-instance.
        Engine:ScheduleContextUpdate("PLAYER_ENTERING_WORLD")
        -- Bootstrap loadout observation (Section 6.0.2 once-per-login)
        Engine:UpdateLoadout()
        -- Bootstrap once, then re-apply keybinds on EVERY world load.
        Engine:_RunEnteringWorldRestore()

        -- Track which classes have been fully activated
        GRIPEMS.loadedClasses = GRIPEMS.loadedClasses or {}
        GRIPEMS.loadedClasses[select(3, UnitClass("player")) or 0] = true

        -- Initialize bar integration after sequences are restored
        if C_Timer and C_Timer.After then
            C_Timer.After(1, function()
                if GRIPEMS.BarIntegration then
                    GRIPEMS.BarIntegration:Init()
                end
            end)
        end

        -- Register for variable changes to recompile affected sequences.
        --
        -- SIGNATURE IS (event, name), NOT (self, event, name). A FUNCTION REF is
        -- dispatched with no self prepended -- Dispatch(events[eventname],
        -- eventname, ...) at Libs/CallbackHandler-1.0:54, and the registration
        -- comment at :76-77, where a string method "leads to self[method](self,
        -- ...)" and a function ref "leads to functionref(...)". Only the string
        -- form gets self, and this site registers a function.
        --
        -- This carried function(_, _, varName) against producers that fire
        -- (name, value) -- Data/VariableStore.lua:238, :346, :935 -- so varName
        -- bound the VALUE, VS:GetReferences(value) returned an empty list, and a
        -- variable edit never recompiled the sequences that referenced it. The
        -- "if not varName" guard below hid it: a nil-ish value simply returned.
        if GRIPEMS.RegisterCallback then
            GRIPEMS.RegisterCallback(Engine, "VARIABLE_UPDATED", function(_, varName)
                if not varName then
                    return
                end
                local VS = GRIPEMS.VariableStore
                if not VS then
                    return
                end
                local refs = VS:GetReferences(varName)
                for _, seqName in ipairs(refs) do
                    if Engine.sequences[seqName] then
                        Engine:RecompileSequence(seqName)
                    end
                end
            end)
        end
    elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
        -- Only react to player's own spec change, not group members
        local unit = ...
        if unit == "player" then
            -- Reset step on spec change for sequences with resetOnSpec
            for name, entry in pairs(Engine.sequences) do
                local ver = Engine:GetActiveVersion(entry.data)
                if ver and ver.resetOnSpec then
                    local btn = entry.button
                    if btn then
                        local wasStep = tonumber(btn:GetAttribute("step")) or 1
                        btn:SetAttribute("step", 1)
                        GRIPEMS:Debug(L["GEMS_SPEC_RESET"], name, wasStep)
                        Engine:UpdateButtonIcon(btn, true)
                    end
                end
            end
            -- Reload keybinds for new spec (debounced with ACTIVE_TALENT_GROUP_CHANGED)
            if KM then
                KM:ScheduleLoadKeybinds()
            end
            -- Re-observe loadout after spec change (Section 6.0.2)
            Engine:UpdateLoadout()
            -- L500 Strategy A Phase 3: re-translate taggedSteps for talent overrides
            -- that may differ in the new spec. No-op for sequences without
            -- taggedSteps (pre-Phase-1 imports keep current behavior).
            Engine:HealOverrideSteps()
        end
    elseif event == "ACTIVE_TALENT_GROUP_CHANGED" then
        -- Backup event for spec changes (debounced with PLAYER_SPECIALIZATION_CHANGED)
        if KM then
            KM:ScheduleLoadKeybinds()
        end
    elseif event == "ACTIVE_COMBAT_CONFIG_CHANGED" then
        -- Canonical success signal for build switching (Section 6.0.2 primary trigger).
        local configID = ...
        Engine:UpdateLoadout()
        if GRIPEMS.LoadoutManager and type(GRIPEMS.LoadoutManager._OnActiveCombatConfigChanged) == "function" then
            GRIPEMS.LoadoutManager:_OnActiveCombatConfigChanged(configID)
        end
    elseif event == "TRAIT_CONFIG_UPDATED" then
        -- Secondary signal; filter to changes affecting the active or last-observed loadout.
        local configID = ...
        local activeID = C_ClassTalents and C_ClassTalents.GetActiveConfigID and C_ClassTalents.GetActiveConfigID()
            or nil
        if configID == activeID or configID == Engine.currentLoadoutID then
            Engine:UpdateLoadout()
            -- L500 Strategy A Phase 3: re-translate taggedSteps when the
            -- active loadout's trait config changes (talent point spent / removed).
            Engine:HealOverrideSteps()
        end
    elseif event == "PLAYER_TALENT_UPDATE" then
        -- Defense-in-depth; no payload, always re-read the active configID.
        Engine:UpdateLoadout()
    elseif event == "TRAIT_CONFIG_CREATED" then
        -- Routes to the LM ImportLoadout one-shot listener (Section 6.4 / Phase 1.5b).
        local configInfo = ...
        if GRIPEMS.LoadoutManager and type(GRIPEMS.LoadoutManager._OnTraitConfigCreated) == "function" then
            GRIPEMS.LoadoutManager:_OnTraitConfigCreated(configInfo)
        end
    elseif event == "TRAIT_CONFIG_DELETED" then
        -- Purge (ctx, deletedID) build assignment entries (Section 6.4 / Phase 1.5b).
        local configID = ...
        if GRIPEMS.LoadoutManager and type(GRIPEMS.LoadoutManager._OnTraitConfigDeleted) == "function" then
            GRIPEMS.LoadoutManager:_OnTraitConfigDeleted(configID)
        end
    elseif event == "CONFIG_COMMIT_FAILED" then
        -- Routes to LM failure handler (Section 6.3 / Phase 1.5b).
        local configID = ...
        if GRIPEMS.LoadoutManager and type(GRIPEMS.LoadoutManager._OnConfigCommitFailed) == "function" then
            GRIPEMS.LoadoutManager:_OnConfigCommitFailed(configID)
        end
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        -- Spell 384255 "Changing Talents" cast completion (Section 6.3 primary success signal per Phase 1.5b-polish-1 empirical AVAV).
        local unitTarget, _, spellID = ...
        if unitTarget == "player" and spellID == 384255 then
            if GRIPEMS.LoadoutManager and type(GRIPEMS.LoadoutManager._OnCommitCastSucceeded) == "function" then
                GRIPEMS.LoadoutManager:_OnCommitCastSucceeded(spellID)
            end
        end
    elseif event == "ZONE_CHANGED" then
        Engine:ScheduleContextUpdate("ZONE_CHANGED")
    elseif event == "ZONE_CHANGED_INDOORS" then
        Engine:ScheduleContextUpdate("ZONE_CHANGED_INDOORS")
    elseif event == "ZONE_CHANGED_NEW_AREA" then
        Engine:ScheduleContextUpdate("ZONE_CHANGED_NEW_AREA")
    elseif event == "PLAYER_DIFFICULTY_CHANGED" then
        Engine:ScheduleContextUpdate("PLAYER_DIFFICULTY_CHANGED")
    elseif event == "INSTANCE_GROUP_SIZE_CHANGED" then
        Engine:ScheduleContextUpdate("INSTANCE_GROUP_SIZE_CHANGED")
    elseif event == "GROUP_ROSTER_UPDATE" then
        Engine:ScheduleContextUpdate("GROUP_ROSTER_UPDATE")
    elseif event == "CHALLENGE_MODE_START" then
        Engine:ScheduleContextUpdate("CHALLENGE_MODE_START")
    elseif event == "CHALLENGE_MODE_COMPLETED" then
        Engine:ScheduleContextUpdate("CHALLENGE_MODE_COMPLETED")
    elseif event == "PET_BATTLE_OPENING_DONE" then
        if GRIPEMS.PetBattleButtons then
            GRIPEMS.PetBattleButtons:Activate()
        end
    elseif event == "PET_BATTLE_CLOSE" then
        if GRIPEMS.PetBattleButtons then
            GRIPEMS.PetBattleButtons:Deactivate()
        end
    elseif
        event == "UPDATE_BONUS_ACTIONBAR"
        or event == "UPDATE_VEHICLE_ACTIONBAR"
        or event == "UPDATE_OVERRIDE_ACTIONBAR"
        or event == "UPDATE_SHAPESHIFT_FORM"
    then
        -- Ignore bar-swap events during initial load (buttons may not exist yet)
        if not Engine._initialLoadComplete then
            return
        end
        -- Both secure drivers own their own suspend/restore on bar swap,
        -- event-lessly via their <=0.2s OnUpdate: GRIPEMS_VehicleDriver for the
        -- sequence keybind, GRIPEMS_VehicleKeybindOwner for the vehicle-slot
        -- keybinds. Nothing to toggle from Lua here.
        -- A bar swap can change which skyriding ability each bound key drives,
        -- so refresh the per-button pass-through text (no-op off the skyride bar).
        if GRIPEMS.KeybindManager and GRIPEMS.KeybindManager.RefreshSkyridePassAttrs then
            GRIPEMS.KeybindManager:RefreshSkyridePassAttrs()
        end
        -- STALE-OVERRIDE-STEP-TEXT: these are the events that fire when a
        -- transient spell override appears or reverts. The heal is what puts
        -- the base spell name back into the step text, and before this it had
        -- no trigger of its own.
        Engine:ScheduleOverrideHeal()
    elseif event == "UPDATE_BINDINGS" then
        if GRIPEMS.KeybindManager then
            GRIPEMS.KeybindManager:ScheduleLoadKeybinds()
        end
    end
end)

--- Register Engine's message-bus callbacks.
---
--- MUST be called from Core's ADDON_LOADED handler, AFTER
--- LibStub("CallbackHandler-1.0"):New(GRIPEMS) creates GRIPEMS.RegisterCallback
--- at Core/Core.lua:3304. Engine CANNOT self-register at file-load scope: every
--- addon file has already executed by the time ADDON_LOADED fires, so
--- GRIPEMS.RegisterCallback is nil at file scope and a column-0
--- "if GRIPEMS.RegisterCallback then" block there tests nil and registers
--- NOTHING. Core.lua:3310 states exactly this about SpellCache. Two blocks at
--- the bottom of THIS file did it anyway and were dead on every client from the
--- day each landed. Moving them lower in the file would not have helped:
--- ADDON_LOADED is an event, not a load phase.
---
--- MEASURED IN-CLIENT 2026-08-13 on Kontje at fa38627, and each step
--- discriminates rather than merely observing:
---   1. Hook HealLocaleSteps and HealEmpowerReleases, Fire
---      SPELL_CACHE_REFRESHED -- neither hook fires.
---   2. Register the SAME event by hand at that moment and fire again -- the
---      new handler DOES fire. So the dispatcher works and the registration is
---      what never happened; this was never a broken Fire.
---   3. HealEmpowerReleases called directly returns 1 and heals, so the
---      handler's contents were sound all along.
---   4. The SETTING_CHANGED block, by side effect rather than inference: hook
---      Settings.GetResetModifiers, fire the event with the macroResetModifiers
---      key, hook count stays 0.
---
--- Dead as a result, for every user: HealLocaleSteps, HealOverrideSteps,
--- VariableStore:HealLocaleVariables, RetryCappedBraceReloads,
--- HealEmpowerReleases, and the whole macroResetModifiers republish (which also
--- republishes holdOnChannel and releaseAtMax and clears empowerRelease).
---
--- Latched. ADDON_LOADED can fire more than once, and CallbackHandler keys one
--- slot per (event, registrant) so a re-register would silently replace rather
--- than duplicate -- but the latch states the intent instead of leaning on that.
--- @return boolean true when this call performed the registration
function Engine:RegisterCallbacks()
    if not GRIPEMS.RegisterCallback or self._callbacksRegistered then
        return false
    end
    self._callbacksRegistered = true

    -- Phase 2c: heal locale-mismatched sequences after every spell cache refresh.
    -- HealOverrideSteps runs unconditionally so /reload re-derives the hero-talent
    -- override DISPLAY even when no locale change occurred. As of v2.4.4 it
    -- writes no SavedVariables at all, and it records an entry only where the
    -- resolved name differs from the persisted text, so the unconditional call
    -- costs one translate walk and nothing else when no override is active.
    GRIPEMS.RegisterCallback(Engine, "SPELL_CACHE_REFRESHED", function()
        Engine:HealLocaleSteps()
        Engine:HealOverrideSteps()
        local VS = GRIPEMS.VariableStore
        if VS and VS.HealLocaleVariables then
            VS:HealLocaleVariables()
        end
        -- ARENA-RELOAD-ISSUE: a braced sequence (capped OR mid-retry) may now
        -- resolve, so re-queue every pending braced entry once the cache settles.
        Engine:RetryCappedBraceReloads()
        -- EMPOWER-RELEASE-INERT-UNTIL-RECOMPILE: this refresh is the moment the
        -- empower set first exists, and every sequence compiled before it baked
        -- an empty release. Runs LAST on purpose: the heals above may already
        -- have recompiled a sequence for their own reasons, and the staleness
        -- scan then finds nothing to do for it rather than queueing a second
        -- recompile of the same name.
        Engine:HealEmpowerReleases()
    end)

    -- Update macro reset modifier attributes on all active buttons when setting
    -- changes. OOC-gated: SetAttribute is protected and cannot run during combat.
    -- SIGNATURE IS (event, key), NOT (self, event, key). Registering with a
    -- FUNCTION REF rather than a method-name string means CallbackHandler
    -- dispatches it as fn(eventname, ...) with no self prepended -- see
    -- Libs/CallbackHandler-1.0:54, Dispatch(events[eventname], eventname, ...),
    -- and the registration comment at :75, "self with function ref, leads to
    -- functionref(...)". Every producer fires Fire("SETTING_CHANGED", key,
    -- value) (Data/Settings.lua:229, :257, :299), so the handler receives
    -- (event, key, value).
    --
    -- This arm carried function(_, _, key) and therefore compared the setting's
    -- VALUE against "macroResetModifiers" and never matched. It was invisible
    -- because the block was also never registered, so the wrong comparison
    -- never got the chance to run: fixing only the registration would have
    -- shipped a block that registers and still does nothing. The palette
    -- handler at Core/Core.lua:3528 already uses the correct function(_, key).
    GRIPEMS.RegisterCallback(Engine, "SETTING_CHANGED", function(_, key)
        if key ~= "macroResetModifiers" then
            return
        end
        local function doUpdate()
            local globalMods = GRIPEMS.Settings:GetResetModifiers()
            for _, entry in pairs(Engine.sequences) do
                local btn = entry.button
                if btn then
                    local activeVer = Engine:GetActiveVersion(entry.data)
                    local seqResetMods = activeVer and activeVer.resetModifiers
                    local resetMods
                    if seqResetMods then
                        resetMods = {}
                        for mod, default in pairs(globalMods) do
                            if seqResetMods[mod] ~= nil then
                                resetMods[mod] = seqResetMods[mod]
                            else
                                resetMods[mod] = default
                            end
                        end
                    else
                        resetMods = globalMods
                    end
                    for mod, enabled in pairs(resetMods) do
                        btn:SetAttribute("resetMod_" .. mod, enabled and "1" or nil)
                    end
                    -- Republished from the same resolved version this loop already
                    -- read, so a live button can never keep a stale channel-hold flag.
                    btn:SetAttribute("holdOnChannel", activeVer and activeVer.holdOnChannel and "1" or nil)
                    btn:SetAttribute("releaseAtMax", activeVer and activeVer.releaseAtMax and "1" or nil)
                    btn:SetAttribute("empowerRelease", nil)
                end
            end
        end
        if GRIPEMS.OOCQueue.IsRestricted() then
            GRIPEMS.OOCQueue:Add(doUpdate, D.OOC_OP_SETTING, "macroResetModifiers")
        else
            doUpdate()
        end
    end)

    return true
end
