-- GRIP-EMS: MacroConditionalBaker
-- Created: 2026-05-28
-- Updated: 2026-06-21
-- Patch: 12.0.7.68256 Midnight (Retail LIVE)
--
-- Compile-time variable baker (IC-VAR-04 / v2.1.8 Win 4). Inspects a user
-- variable's .funct source as a narrow Lua subset, validates it against a
-- fixed set of approved shapes, and rewrites ~varname~ references in step
-- macrotext to native [conditional] X; Y form -- so the cast decision runs
-- in WoW's secure conditional dispatcher instead of through runtime variable
-- resolution. Variables that do not reduce to an approved shape fall through
-- to runtime substitution unchanged. See Research/IC-VAR-04_Design.md for the
-- spec this file implements against.

local ADDON_NAME, GRIPEMS = ...
local MCB = {}
GRIPEMS.MacroConditionalBaker = MCB
local D = GRIPEMS.Defaults

-- ===========================================================================
-- Helper registry -- SINGLE source of truth for helper -> conditional mapping
-- ===========================================================================
--
-- The parser, validator, and translator all consume this one table. Adding a
-- new helper means one row here, one function in Engine/Conditions.lua, and
-- one test fixture in Test/macro_conditional_baker_spec.lua. paramType is one
-- of "none" / "modkey" / "integer" / "unit" / "spell". integer rows carry a
-- paramRange {min,max}; modkey rows carry a paramAllowlist set.

MCB._HELPERS = {
    ["InCombat"] = {
        conditional = "combat",
        paramType = "none",
    },
    ["HasMod"] = {
        conditional = "mod",
        paramType = "modkey",
        paramAllowlist = {
            shift = true,
            ctrl = true,
            alt = true,
            lshift = true,
            rshift = true,
            lctrl = true,
            rctrl = true,
            lalt = true,
            ralt = true,
        },
    },
    ["InStance"] = {
        conditional = "stance",
        paramType = "integer",
        paramRange = { min = 1, max = 3 },
    },
    ["InForm"] = {
        conditional = "form",
        paramType = "integer",
        paramRange = { min = 0, max = 7 },
    },
    ["InSpec"] = {
        conditional = "spec",
        paramType = "integer",
        paramRange = { min = 1, max = 4 },
    },
    ["InBonusBar"] = {
        conditional = "bonusbar",
        paramType = "integer",
        paramRange = { min = 0, max = 5 },
    },
    ["IsStealthed"] = {
        conditional = "stealth",
        paramType = "none",
    },
    ["IsDead"] = {
        conditional = "dead",
        paramType = "unit",
    },
    ["IsHelp"] = {
        conditional = "help",
        paramType = "unit",
    },
    ["IsHarm"] = {
        conditional = "harm",
        paramType = "unit",
    },
    ["UnitExists"] = {
        conditional = "exists",
        paramType = "unit",
    },
    ["InParty"] = {
        conditional = "party",
        paramType = "none",
    },
    ["InRaid"] = {
        conditional = "raid",
        paramType = "none",
    },
    ["InGroup"] = {
        conditional = "group",
        paramType = "none",
    },
    ["IsChanneling"] = {
        conditional = "channeling",
        paramType = "none",
    },
    ["KnowsSpell"] = {
        conditional = "known",
        paramType = "spell",
    },
    ["IsMounted"] = {
        conditional = "mounted",
        paramType = "none",
    },
    ["IsIndoors"] = {
        conditional = "indoors",
        paramType = "none",
    },
    ["IsOutdoors"] = {
        conditional = "outdoors",
        paramType = "none",
    },
    ["IsSwimming"] = {
        conditional = "swimming",
        paramType = "none",
    },
    ["UnitHasVehicleUI"] = {
        conditional = "unithasvehicleui",
        paramType = "unit",
    },
    ["InPossessBar"] = {
        conditional = "possessbar",
        paramType = "none",
    },
    ["InOverrideBar"] = {
        conditional = "overridebar",
        paramType = "none",
    },
}

-- ===========================================================================
-- Unit token allowlist
-- ===========================================================================
--
-- Recognized WoW unit tokens that may appear as the optional string argument
-- to IsDead / IsHelp / IsHarm / UnitExists / UnitHasVehicleUI. Anything
-- outside this set rejects the bake. Built programmatically to avoid 90+
-- literal rows.

local UNIT_TOKENS = {
    player = true,
    target = true,
    focus = true,
    mouseover = true,
    pet = true,
    vehicle = true,
    none = true,
    targettarget = true,
    focustarget = true,
    pettarget = true,
}
for i = 1, 4 do
    UNIT_TOKENS["party" .. i] = true
    UNIT_TOKENS["partypet" .. i] = true
end
for i = 1, 40 do
    UNIT_TOKENS["raid" .. i] = true
    UNIT_TOKENS["raidpet" .. i] = true
end
for i = 1, 5 do
    UNIT_TOKENS["boss" .. i] = true
    UNIT_TOKENS["arena" .. i] = true
    UNIT_TOKENS["arenapet" .. i] = true
end

-- ===========================================================================
-- Tokenizer
-- ===========================================================================

local KEYWORDS = {
    ["local"] = true,
    ["return"] = true,
    ["if"] = true,
    ["then"] = true,
    ["elseif"] = true,
    ["else"] = true,
    ["end"] = true,
    ["function"] = true,
    ["and"] = true,
    ["or"] = true,
    ["not"] = true,
    ["true"] = true,
    ["false"] = true,
    ["nil"] = true,
}

local OPERATORS = {
    ["="] = true,
    ["("] = true,
    [")"] = true,
    [","] = true,
    ["."] = true,
    [";"] = true,
}

local function isAlpha(c)
    return (c >= "A" and c <= "Z") or (c >= "a" and c <= "z") or c == "_"
end

local function isDigit(c)
    return c >= "0" and c <= "9"
end

local function isAlnum(c)
    return isAlpha(c) or isDigit(c)
end

--- Scan a Lua-subset source string into a flat token list.
--- Strips line comments (-- to EOL), block comments (--[[ ... ]]), and
--- whitespace. Returns the token array on success, or nil + errMsg on an
--- unterminated string, unterminated block comment, or unrecognized char.
--- @param src string Source to tokenize
--- @return table|nil tokens
--- @return string|nil errMsg
function MCB._Tokenize(src)
    if type(src) ~= "string" then
        return nil, "tokenizer: non-string source"
    end
    local tokens = {}
    local pos = 1
    local len = #src
    local line = 1
    local col = 1
    while pos <= len do
        local c = src:sub(pos, pos)
        if c == " " or c == "\t" or c == "\r" then
            pos = pos + 1
            col = col + 1
        elseif c == "\n" then
            pos = pos + 1
            line = line + 1
            col = 1
        elseif c == "-" and src:sub(pos + 1, pos + 1) == "-" then
            if src:sub(pos + 2, pos + 3) == "[[" then
                local close = src:find("]]", pos + 4, true)
                if not close then
                    return nil, "tokenizer: unterminated block comment at line " .. line
                end
                local consumed = src:sub(pos, close + 1)
                line = line + select(2, consumed:gsub("\n", ""))
                pos = close + 2
                col = 1
            else
                while pos <= len and src:sub(pos, pos) ~= "\n" do
                    pos = pos + 1
                end
            end
        elseif c == '"' or c == "'" then
            local quote = c
            local startCol = col
            pos = pos + 1
            col = col + 1
            local sb = {}
            local closed = false
            while pos <= len do
                local ch = src:sub(pos, pos)
                if ch == quote then
                    closed = true
                    break
                elseif ch == "\\" then
                    local nxt = src:sub(pos + 1, pos + 1)
                    if nxt == "" then
                        return nil, "tokenizer: unterminated string at line " .. line
                    end
                    if nxt == "n" then
                        sb[#sb + 1] = "\n"
                    elseif nxt == "t" then
                        sb[#sb + 1] = "\t"
                    elseif nxt == "r" then
                        sb[#sb + 1] = "\r"
                    elseif nxt == "\\" then
                        sb[#sb + 1] = "\\"
                    elseif nxt == '"' then
                        sb[#sb + 1] = '"'
                    elseif nxt == "'" then
                        sb[#sb + 1] = "'"
                    else
                        sb[#sb + 1] = nxt
                    end
                    pos = pos + 2
                    col = col + 2
                elseif ch == "\n" then
                    return nil, "tokenizer: unterminated string at line " .. line
                else
                    sb[#sb + 1] = ch
                    pos = pos + 1
                    col = col + 1
                end
            end
            if not closed then
                return nil, "tokenizer: unterminated string at line " .. line
            end
            pos = pos + 1
            col = col + 1
            tokens[#tokens + 1] = { type = "STR", value = table.concat(sb), line = line, col = startCol }
        elseif isDigit(c) then
            local start = pos
            local startCol = col
            while pos <= len and (isDigit(src:sub(pos, pos)) or src:sub(pos, pos) == ".") do
                pos = pos + 1
                col = col + 1
            end
            local raw = src:sub(start, pos - 1)
            local n = tonumber(raw)
            if not n then
                return nil, "tokenizer: malformed number '" .. raw .. "' at line " .. line
            end
            tokens[#tokens + 1] = { type = "NUM", value = n, line = line, col = startCol }
        elseif isAlpha(c) then
            local start = pos
            local startCol = col
            while pos <= len and isAlnum(src:sub(pos, pos)) do
                pos = pos + 1
                col = col + 1
            end
            local name = src:sub(start, pos - 1)
            if KEYWORDS[name] then
                tokens[#tokens + 1] = { type = "KW", value = name, line = line, col = startCol }
            else
                tokens[#tokens + 1] = { type = "NAME", value = name, line = line, col = startCol }
            end
        elseif OPERATORS[c] then
            tokens[#tokens + 1] = { type = "OP", value = c, line = line, col = col }
            pos = pos + 1
            col = col + 1
        else
            return nil, "tokenizer: unexpected character '" .. c .. "' at line " .. line
        end
    end
    tokens[#tokens + 1] = { type = "EOF", value = "", line = line, col = col }
    return tokens
end

-- ===========================================================================
-- Recursive-descent parser
-- ===========================================================================

local function peek(state, n)
    return state.tokens[state.pos + (n or 0)]
end

local function consume(state)
    local tok = state.tokens[state.pos]
    state.pos = state.pos + 1
    return tok
end

local function matches(state, ttype, tvalue)
    local tok = peek(state)
    if not tok or tok.type ~= ttype then
        return false
    end
    if tvalue and tok.value ~= tvalue then
        return false
    end
    return true
end

local function parseError(state, msg)
    if state.err then
        return
    end
    local tok = peek(state)
    state.err = "parser: " .. msg .. " at line " .. (tok and tok.line or "?")
end

local function expect(state, ttype, tvalue)
    local tok = peek(state)
    if not tok or tok.type ~= ttype or (tvalue and tok.value ~= tvalue) then
        local want = ttype .. (tvalue and (" '" .. tvalue .. "'") or "")
        parseError(state, "expected " .. want .. ", got '" .. (tok and tostring(tok.value) or "EOF") .. "'")
        return nil
    end
    state.pos = state.pos + 1
    return tok
end

-- Forward declarations (mutually recursive productions).
local parseChunk, parseLocalStat, parseReturnStat, parseIfStat
local parseReturnExpr, parseIfChain, parseAndChain, parseUnary, parsePrimary
local parseHelperCall, parseArgList, parseLiteral

parseChunk = function(state)
    local node = { tag = "chunk", stats = {}, finalReturn = nil }
    while true do
        if state.err then
            return nil
        end
        local tok = peek(state)
        if tok.type == "EOF" then
            break
        end
        if tok.type == "KW" and tok.value == "local" then
            local stat = parseLocalStat(state)
            if not stat then
                return nil
            end
            node.stats[#node.stats + 1] = stat
        elseif tok.type == "KW" and tok.value == "return" then
            local stat = parseReturnStat(state)
            if not stat then
                return nil
            end
            node.finalReturn = stat
            if matches(state, "OP", ";") then
                consume(state)
            end
            break
        elseif tok.type == "KW" and tok.value == "if" then
            local stat = parseIfStat(state)
            if not stat then
                return nil
            end
            node.finalReturn = stat
            if matches(state, "OP", ";") then
                consume(state)
            end
            break
        elseif tok.type == "OP" and tok.value == ";" then
            consume(state)
        else
            parseError(state, "unexpected token '" .. tostring(tok.value) .. "'")
            return nil
        end
    end
    if peek(state).type ~= "EOF" then
        parseError(state, "trailing content after return")
        return nil
    end
    if not node.finalReturn then
        parseError(state, "chunk has no return statement")
        return nil
    end
    return node
end

parseLocalStat = function(state)
    expect(state, "KW", "local")
    local nameTok = expect(state, "NAME")
    if not nameTok then
        return nil
    end
    expect(state, "OP", "=")
    local value = parseReturnExpr(state)
    if not value then
        return nil
    end
    if matches(state, "OP", ";") then
        consume(state)
    end
    return { tag = "local", name = nameTok.value, value = value }
end

parseReturnStat = function(state)
    expect(state, "KW", "return")
    local value = parseReturnExpr(state)
    if not value then
        return nil
    end
    return { tag = "return", value = value }
end

parseIfStat = function(state)
    expect(state, "KW", "if")
    local cond = parseReturnExpr(state)
    if not cond then
        return nil
    end
    expect(state, "KW", "then")
    expect(state, "KW", "return")
    local thenVal = parseReturnExpr(state)
    if not thenVal then
        return nil
    end
    local branches = { { cond = cond, value = thenVal } }
    while matches(state, "KW", "elseif") do
        consume(state)
        local elifCond = parseReturnExpr(state)
        if not elifCond then
            return nil
        end
        expect(state, "KW", "then")
        expect(state, "KW", "return")
        local elifVal = parseReturnExpr(state)
        if not elifVal then
            return nil
        end
        branches[#branches + 1] = { cond = elifCond, value = elifVal }
    end
    local elseVal = nil
    if matches(state, "KW", "else") then
        consume(state)
        expect(state, "KW", "return")
        elseVal = parseReturnExpr(state)
        if not elseVal then
            return nil
        end
    end
    expect(state, "KW", "end")
    if state.err then
        return nil
    end
    -- Desugar if-elseif-else into the same OR-chain AST a Shape T2 ternary
    -- produces: cond1 and val1 or cond2 and val2 or ... or elseVal. A compound
    -- `if a and b then` condition flattens into the branch's AND-operands so
    -- the validator sees one and-chain of helpers ending in the value.
    local orOperands = {}
    for _, br in ipairs(branches) do
        local andOps = {}
        if br.cond.tag == "and" then
            for _, o in ipairs(br.cond.operands) do
                andOps[#andOps + 1] = o
            end
        else
            andOps[#andOps + 1] = br.cond
        end
        andOps[#andOps + 1] = br.value
        orOperands[#orOperands + 1] = { tag = "and", operands = andOps }
    end
    if elseVal then
        orOperands[#orOperands + 1] = elseVal
    end
    local orNode
    if #orOperands == 1 then
        orNode = orOperands[1]
    else
        orNode = { tag = "or", operands = orOperands }
    end
    return { tag = "return", value = orNode }
end

parseReturnExpr = function(state)
    return parseIfChain(state)
end

parseIfChain = function(state)
    local first = parseAndChain(state)
    if not first then
        return nil
    end
    if not matches(state, "KW", "or") then
        return first
    end
    local operands = { first }
    while matches(state, "KW", "or") do
        consume(state)
        local nextNode = parseAndChain(state)
        if not nextNode then
            return nil
        end
        operands[#operands + 1] = nextNode
    end
    return { tag = "or", operands = operands }
end

parseAndChain = function(state)
    local first = parseUnary(state)
    if not first then
        return nil
    end
    if not matches(state, "KW", "and") then
        return first
    end
    local operands = { first }
    while matches(state, "KW", "and") do
        consume(state)
        local nextNode = parseUnary(state)
        if not nextNode then
            return nil
        end
        operands[#operands + 1] = nextNode
    end
    return { tag = "and", operands = operands }
end

parseUnary = function(state)
    if matches(state, "KW", "not") then
        consume(state)
        local inner = parseUnary(state)
        if not inner then
            return nil
        end
        return { tag = "not", operand = inner }
    end
    return parsePrimary(state)
end

parsePrimary = function(state)
    local tok = peek(state)
    if not tok then
        parseError(state, "unexpected end of input")
        return nil
    end
    if tok.type == "OP" and tok.value == "(" then
        consume(state)
        local inner = parseIfChain(state)
        if not inner then
            return nil
        end
        expect(state, "OP", ")")
        return inner
    end
    if tok.type == "STR" then
        consume(state)
        return { tag = "literal", litType = "string", value = tok.value }
    end
    if tok.type == "NUM" then
        consume(state)
        return { tag = "literal", litType = "number", value = tok.value }
    end
    if tok.type == "KW" then
        if tok.value == "true" then
            consume(state)
            return { tag = "literal", litType = "bool", value = true }
        end
        if tok.value == "false" then
            consume(state)
            return { tag = "literal", litType = "bool", value = false }
        end
        if tok.value == "nil" then
            consume(state)
            return { tag = "literal", litType = "nil" }
        end
        parseError(state, "unexpected keyword '" .. tok.value .. "' in expression")
        return nil
    end
    if tok.type == "NAME" then
        if tok.value == "GRIPEMS" then
            return parseHelperCall(state)
        end
        consume(state)
        return { tag = "nameref", name = tok.value }
    end
    parseError(state, "unexpected token '" .. tostring(tok.value) .. "' in expression")
    return nil
end

parseHelperCall = function(state)
    expect(state, "NAME", "GRIPEMS")
    expect(state, "OP", ".")
    local nameTok = expect(state, "NAME")
    if not nameTok then
        return nil
    end
    expect(state, "OP", "(")
    if state.err then
        return nil
    end
    local args = {}
    if not (matches(state, "OP", ")")) then
        args = parseArgList(state)
        if not args then
            return nil
        end
    end
    expect(state, "OP", ")")
    if state.err then
        return nil
    end
    return { tag = "helper", name = nameTok.value, args = args }
end

parseArgList = function(state)
    local args = {}
    local first = parseLiteral(state)
    if not first then
        return nil
    end
    args[#args + 1] = first
    while matches(state, "OP", ",") do
        consume(state)
        local nextLit = parseLiteral(state)
        if not nextLit then
            return nil
        end
        args[#args + 1] = nextLit
    end
    return args
end

parseLiteral = function(state)
    local tok = peek(state)
    if not tok then
        parseError(state, "unexpected end of input")
        return nil
    end
    if tok.type == "STR" then
        consume(state)
        return { tag = "literal", litType = "string", value = tok.value }
    end
    if tok.type == "NUM" then
        consume(state)
        return { tag = "literal", litType = "number", value = tok.value }
    end
    if tok.type == "KW" then
        if tok.value == "true" then
            consume(state)
            return { tag = "literal", litType = "bool", value = true }
        end
        if tok.value == "false" then
            consume(state)
            return { tag = "literal", litType = "bool", value = false }
        end
        if tok.value == "nil" then
            consume(state)
            return { tag = "literal", litType = "nil" }
        end
    end
    parseError(state, "expected literal argument, got '" .. tostring(tok.value) .. "'")
    return nil
end

--- Parse a variable .funct source into a chunk AST.
--- Pre-pass strips an optional `function() ... end` wrapper and injects an
--- implicit `return` when the body is a bare expression. Returns the AST root
--- on success, or nil + errMsg on the first parse error.
--- @param src string Variable source
--- @return table|nil ast
--- @return string|nil errMsg
function MCB._Parse(src)
    if type(src) ~= "string" then
        return nil, "parser: non-string source"
    end
    local trimmed = src:gsub("^%s+", ""):gsub("%s+$", "")
    local inner = trimmed:match("^function%s*%(%s*%)%s*(.*)$")
    if inner then
        trimmed = inner:gsub("%s*end%s*$", "")
    end
    local firstWord = trimmed:match("^([%a_][%w_]*)")
    if not firstWord or (firstWord ~= "return" and firstWord ~= "local" and firstWord ~= "if") then
        trimmed = "return " .. trimmed
    end
    local tokens, tokErr = MCB._Tokenize(trimmed)
    if not tokens then
        return nil, tokErr
    end
    local state = { tokens = tokens, pos = 1, err = nil }
    local ast = parseChunk(state)
    if state.err then
        return nil, state.err
    end
    if not ast then
        return nil, "parser: empty AST"
    end
    return ast
end

-- ===========================================================================
-- AST shape validator
-- ===========================================================================

local function literalHasNestedVar(litNode)
    if litNode.litType ~= "string" or type(litNode.value) ~= "string" then
        return false
    end
    return litNode.value:find(D.VAR_PATTERN) ~= nil
end

-- Resolve a helper-call AST node against the registry. Returns a conditional
-- descriptor { conditional, args, target } on success, or nil + errMsg. Every
-- argument must be a literal of the registered paramType and within range /
-- allowlist. The descriptor's `negated` flag is set by the caller.
local function validateHelperCall(helperNode)
    if helperNode.tag ~= "helper" then
        return nil, "not a helper-call"
    end
    local meta = MCB._HELPERS[helperNode.name]
    if not meta then
        return nil, "unknown helper '" .. tostring(helperNode.name) .. "'"
    end
    local args = helperNode.args or {}
    if meta.paramType == "none" then
        if #args > 0 then
            return nil, "helper '" .. helperNode.name .. "' takes no arguments"
        end
        return { conditional = meta.conditional, args = {} }
    end
    if meta.paramType == "modkey" then
        if #args ~= 1 then
            return nil, "helper '" .. helperNode.name .. "' requires one modkey argument"
        end
        local a = args[1]
        if a.litType ~= "string" then
            return nil, "modkey argument must be a string literal"
        end
        if not meta.paramAllowlist[a.value] then
            return nil, "unknown modkey '" .. tostring(a.value) .. "'"
        end
        return { conditional = meta.conditional, args = { a.value } }
    end
    if meta.paramType == "integer" then
        if #args ~= 1 then
            return nil, "helper '" .. helperNode.name .. "' requires one integer argument"
        end
        local a = args[1]
        if a.litType ~= "number" then
            return nil, "integer argument must be a number literal"
        end
        if a.value ~= math.floor(a.value) then
            return nil, "integer argument must be a whole number"
        end
        if a.value < meta.paramRange.min or a.value > meta.paramRange.max then
            return nil, "integer argument out of range"
        end
        return { conditional = meta.conditional, args = { string.format("%d", a.value) } }
    end
    if meta.paramType == "unit" then
        if #args == 0 then
            return { conditional = meta.conditional, args = {} }
        end
        if #args ~= 1 then
            return nil, "helper '" .. helperNode.name .. "' takes at most one unit argument"
        end
        local a = args[1]
        if a.litType ~= "string" then
            return nil, "unit argument must be a string literal"
        end
        if not UNIT_TOKENS[a.value] then
            return nil, "unknown unit token '" .. tostring(a.value) .. "'"
        end
        return { conditional = meta.conditional, args = {}, target = "@" .. a.value }
    end
    if meta.paramType == "spell" then
        if #args ~= 1 then
            return nil, "helper '" .. helperNode.name .. "' requires one spell argument"
        end
        local a = args[1]
        if a.litType == "number" then
            local nameStr
            if C_Spell and C_Spell.GetSpellName then
                local ok, n = pcall(C_Spell.GetSpellName, a.value)
                if ok then
                    nameStr = n
                end
            end
            if (not nameStr or nameStr == "") and GRIPEMS.SpellCache and GRIPEMS.SpellCache.byID then
                local entry = GRIPEMS.SpellCache.byID[a.value]
                nameStr = entry and entry.name or nil
            end
            if not nameStr or nameStr == "" then
                return nil, "unknown spellID '" .. tostring(a.value) .. "'"
            end
            return { conditional = meta.conditional, args = { nameStr } }
        end
        if a.litType == "string" then
            if a.value == "" then
                return nil, "spell name must be non-empty"
            end
            return { conditional = meta.conditional, args = { a.value } }
        end
        return nil, "spell argument must be a string or number literal"
    end
    return nil, "unhandled paramType '" .. tostring(meta.paramType) .. "'"
end

-- Build a single conditional descriptor from a helper-call or `not helper-call`
-- operand. Returns the descriptor (with negated flag) or nil + errMsg.
local function operandToConditional(opNode)
    if opNode.tag == "not" then
        if opNode.operand.tag ~= "helper" then
            return nil, "negation on a non-helper operand"
        end
        local m, e = validateHelperCall(opNode.operand)
        if not m then
            return nil, e
        end
        m.negated = true
        return m
    end
    if opNode.tag == "helper" then
        local m, e = validateHelperCall(opNode)
        if not m then
            return nil, e
        end
        m.negated = false
        return m
    end
    return nil, "unsupported operand in AND-branch"
end

-- DeMorgan-expand a `not (...)` operand whose inner node is a helper, an
-- and-chain, or an or-chain. Returns a list of condition groups
-- ({ conditionals = {desc, ...} }) or nil + errMsg. Caps at 8 groups.
local function deMorganExpand(notNode)
    local inner = notNode.operand
    if inner.tag == "helper" then
        local m, e = validateHelperCall(inner)
        if not m then
            return nil, e
        end
        m.negated = true
        return { { conditionals = { m } } }
    end
    if inner.tag == "and" then
        -- not(a and b and ...) -> not(a) or not(b) or ...  (separate groups)
        local out = {}
        for _, sub in ipairs(inner.operands) do
            if sub.tag ~= "helper" then
                return nil, "DeMorgan element must be a helper-call"
            end
            local m, e = validateHelperCall(sub)
            if not m then
                return nil, e
            end
            m.negated = true
            out[#out + 1] = { conditionals = { m } }
            if #out > 8 then
                return nil, "DeMorgan combinatorial cap exceeded"
            end
        end
        return out
    end
    if inner.tag == "or" then
        -- not(a or b or ...) -> not(a) and not(b) and ...  (single group)
        local group = { conditionals = {} }
        for _, sub in ipairs(inner.operands) do
            if sub.tag ~= "helper" then
                return nil, "DeMorgan element must be a helper-call"
            end
            local m, e = validateHelperCall(sub)
            if not m then
                return nil, e
            end
            m.negated = true
            group.conditionals[#group.conditionals + 1] = m
        end
        return { group }
    end
    return nil, "DeMorgan target not supported"
end

-- Validate one OR-chain branch. Most branches yield exactly one clause
-- ({ conditionals = {...}, value = "X" }); a DeMorgan-expanded operand yields
-- several clauses that share the branch value. Returns a clause list or
-- nil + errMsg.
local function validateBranch(node)
    if node.tag == "literal" then
        if literalHasNestedVar(node) then
            return nil, "literal value contains nested ~varname~"
        end
        if node.litType ~= "string" then
            return nil, "default value must be a string literal"
        end
        return { { conditionals = {}, value = node.value } }
    end

    if node.tag ~= "and" then
        return nil, "branch is neither an and-chain nor a literal value"
    end

    local ops = node.operands
    if #ops < 2 then
        return nil, "and-branch needs a condition and a value"
    end
    local valueNode = ops[#ops]
    if valueNode.tag ~= "literal" then
        return nil, "and-branch must terminate with a literal value"
    end
    if literalHasNestedVar(valueNode) then
        return nil, "literal value contains nested ~varname~"
    end
    if valueNode.litType ~= "string" then
        return nil, "branch value must be a string literal"
    end

    -- Accumulate clauses; a DeMorgan operand multiplies the running set.
    local clauses = { { conditionals = {} } }
    for i = 1, #ops - 1 do
        local op = ops[i]
        if op.tag == "not" and op.operand.tag ~= "helper" then
            local expansion, expErr = deMorganExpand(op)
            if not expansion then
                return nil, expErr
            end
            local merged = {}
            for _, existing in ipairs(clauses) do
                for _, grp in ipairs(expansion) do
                    local combined = { conditionals = {} }
                    for _, c in ipairs(existing.conditionals) do
                        combined.conditionals[#combined.conditionals + 1] = c
                    end
                    for _, c in ipairs(grp.conditionals) do
                        combined.conditionals[#combined.conditionals + 1] = c
                    end
                    merged[#merged + 1] = combined
                    if #merged > 8 then
                        return nil, "DeMorgan combinatorial cap exceeded"
                    end
                end
            end
            clauses = merged
        else
            local desc, err = operandToConditional(op)
            if not desc then
                return nil, err
            end
            for _, existing in ipairs(clauses) do
                existing.conditionals[#existing.conditionals + 1] = desc
            end
        end
    end

    local result = {}
    for _, cl in ipairs(clauses) do
        result[#result + 1] = { conditionals = cl.conditionals, value = valueNode.value }
    end
    return result
end

-- Validate the top-level return expression (an OR-chain, single AND-branch,
-- or bare literal). Enforces the 3-branch OR-chain depth cap and the 8-clause
-- post-DeMorgan cap. Returns { branches = {...} } or nil + errMsg.
local function validateReturnExpr(node)
    local originalBranches
    if node.tag == "or" then
        originalBranches = node.operands
    else
        originalBranches = { node }
    end
    if #originalBranches > 3 then
        return nil, "OR-chain depth cap exceeded (" .. #originalBranches .. " > 3)"
    end
    local allClauses = {}
    for _, br in ipairs(originalBranches) do
        local clauses, err = validateBranch(br)
        if not clauses then
            return nil, err
        end
        for _, c in ipairs(clauses) do
            allClauses[#allClauses + 1] = c
            if #allClauses > 8 then
                return nil, "clause cap exceeded after DeMorgan expansion"
            end
        end
    end
    local hasConditional = false
    for _, c in ipairs(allClauses) do
        if c.conditionals and #c.conditionals > 0 then
            hasConditional = true
            break
        end
    end
    if not hasConditional then
        return nil, "body is unconditional; defer to runtime substitution"
    end
    return { branches = allClauses }
end

--- Validate a chunk AST against the approved shapes.
--- Handles the L1 local-then-return form by inlining a single
--- `local r = <expr>; return r` once, then validating the inlined expression.
--- Returns the translation context { branches = {...} } or nil + errMsg.
--- @param astRoot table Chunk AST from MCB._Parse
--- @return table|nil ctx
--- @return string|nil errMsg
function MCB._Validate(astRoot)
    if not astRoot or astRoot.tag ~= "chunk" then
        return nil, "validator: non-chunk root"
    end
    local ret = astRoot.finalReturn
    if not ret or ret.tag ~= "return" then
        return nil, "validator: chunk has no return value"
    end
    if #astRoot.stats > 0 then
        -- Shape L1: every preceding statement must be a local; the return must
        -- be a bare reference to one of them. Inline once, then validate.
        local localMap = {}
        for _, stat in ipairs(astRoot.stats) do
            if stat.tag ~= "local" then
                return nil, "L1 shape: non-local statement present"
            end
            localMap[stat.name] = stat.value
        end
        if ret.value.tag ~= "nameref" then
            return nil, "L1 shape: return must be a bare local reference"
        end
        local inlined = localMap[ret.value.name]
        if not inlined then
            return nil, "L1 shape: return references an undeclared local"
        end
        return validateReturnExpr(inlined)
    end
    return validateReturnExpr(ret.value)
end

-- ===========================================================================
-- Translator
-- ===========================================================================

local function emitConditional(c)
    local prefix = c.negated and "no" or ""
    local body = prefix .. c.conditional
    if c.args and #c.args > 0 then
        body = body .. ":" .. table.concat(c.args, "/")
    end
    return body
end

local function emitClause(clause)
    if not clause.conditionals or #clause.conditionals == 0 then
        return clause.value
    end
    local parts = {}
    for _, c in ipairs(clause.conditionals) do
        parts[#parts + 1] = emitConditional(c)
        if c.target then
            parts[#parts + 1] = c.target
        end
    end
    return "[" .. table.concat(parts, ",") .. "] " .. clause.value
end

--- Translate a validated context into a macrotext fragment.
--- Emits one clause per branch and joins them with "; ", then canonicalizes
--- through MacroSyntax.Parse + Serialize. If MacroSyntax records any parse
--- error on the emission, the bake aborts (defense in depth -- a malformed
--- emission falls through to runtime substitution). Returns the fragment or
--- nil + errMsg.
--- @param ctx table Context from MCB._Validate
--- @return string|nil fragment
--- @return string|nil errMsg
function MCB._Translate(ctx)
    if not ctx or not ctx.branches then
        return nil, "translator: empty context"
    end
    local parts = {}
    for _, br in ipairs(ctx.branches) do
        parts[#parts + 1] = emitClause(br)
    end
    local fragment = table.concat(parts, "; ")
    local MS = GRIPEMS.MacroSyntax
    if MS and MS.Parse and MS.Serialize then
        local ast = MS.Parse(fragment)
        if ast.parse_errors and #ast.parse_errors > 0 then
            return nil, "translator: MacroSyntax rejected emission"
        end
        fragment = MS.Serialize(ast)
    end
    return fragment
end

-- ===========================================================================
-- Bake cache -- keyed by varName, fingerprinted by (updatedAt + locale)
-- ===========================================================================

MCB._bakeCache = {}
MCB._bakeLocale = nil

-- Return the cached fragment for varDef iff the fingerprint still matches.
function MCB._Lookup(varDef)
    if not varDef or not varDef.name then
        return nil
    end
    local slot = MCB._bakeCache[varDef.name]
    if not slot then
        return nil
    end
    if slot.updatedAt ~= (varDef.updatedAt or 0) then
        return nil
    end
    local loc = GetLocale and GetLocale() or ""
    if slot.locale ~= loc then
        return nil
    end
    return slot.fragment
end

-- Store a baked fragment for varName under the current fingerprint.
function MCB._Store(varName, varDef, fragment)
    if not varName then
        return
    end
    MCB._bakeCache[varName] = {
        fragment = fragment,
        updatedAt = (varDef and varDef.updatedAt) or 0,
        locale = GetLocale and GetLocale() or "",
    }
end

-- Drop one variable's cache slot (VARIABLE_UPDATED / CREATED / DELETED).
function MCB._Invalidate(varName)
    if not varName then
        return
    end
    MCB._bakeCache[varName] = nil
end

-- Drop the whole cache (locale change).
function MCB._InvalidateAll()
    MCB._bakeCache = {}
end

-- ===========================================================================
-- Public API
-- ===========================================================================

--- Run the full parse + validate + translate pipeline on a varDef.
--- Diagnostic entry point: does NOT touch the cache. Returns the baked
--- macrotext fragment, or nil when the variable does not reduce to an
--- approved shape (the safe, silent rejection path).
--- @param varDef table Variable definition (uses .funct, .disabled)
--- @return string|nil fragment
function MCB:Bake(varDef)
    if type(varDef) ~= "table" then
        return nil
    end
    if varDef.disabled then
        return nil
    end
    if type(varDef.funct) ~= "string" or varDef.funct == "" then
        return nil
    end
    local ast, parseErr = MCB._Parse(varDef.funct)
    if not ast then
        if GRIPEMS.Debug then
            GRIPEMS:Debug("MCB:Bake parse reject: " .. tostring(parseErr))
        end
        return nil
    end
    local ctx, valErr = MCB._Validate(ast)
    if not ctx then
        if GRIPEMS.Debug then
            GRIPEMS:Debug("MCB:Bake validate reject: " .. tostring(valErr))
        end
        return nil
    end
    local fragment, transErr = MCB._Translate(ctx)
    if not fragment then
        if GRIPEMS.Debug then
            GRIPEMS:Debug("MCB:Bake translate reject: " .. tostring(transErr))
        end
        return nil
    end
    return fragment
end

--- Diagnostic boolean: does this variable reduce to a bakeable shape?
--- @param varDef table Variable definition
--- @return boolean
function MCB:CanBake(varDef)
    return MCB:Bake(varDef) ~= nil
end

--- Compile-time bake pass over a step's macrotext. Scans for D.VAR_PATTERN
--- tokens, looks up each variable, and substitutes the baked fragment when
--- one is available (cache hit, else a fresh parse/validate/translate that is
--- then cached). Rejected variables are left as ~varname~ for runtime
--- SubstituteVariables to handle. Idempotent: a fully baked string contains
--- no ~varname~ tokens, so a second call returns it unchanged.
--- @param stepText string Raw macrotext
--- @return string Rewritten (or unchanged) macrotext
function MCB:RewriteStepText(stepText)
    if type(stepText) ~= "string" or stepText == "" then
        return stepText
    end
    if not MCB._initialized and GRIPEMS.RegisterCallback then
        MCB:Initialize()
    end
    if not D or not D.VAR_PATTERN then
        return stepText
    end
    local VS = GRIPEMS.VariableStore
    if not VS or not VS.Get then
        return stepText
    end
    local rewritten = stepText:gsub(D.VAR_PATTERN, function(varName)
        local varDef = VS:Get(varName)
        if not varDef then
            return nil
        end
        if varDef.disabled or type(varDef.funct) ~= "string" or varDef.funct == "" then
            return nil
        end
        local cached = MCB._Lookup(varDef)
        if cached then
            return cached
        end
        local fragment = self:Bake(varDef)
        if not fragment then
            return nil
        end
        MCB._Store(varName, varDef, fragment)
        return fragment
    end)
    return rewritten
end

--- Register cache-invalidation handlers on the VariableStore event surface.
--- Idempotent -- guarded by MCB._initialized so repeated calls are no-ops.
--- VARIABLE_UPDATED / VARIABLE_CREATED / VARIABLE_DELETED each clear the
--- affected cache slot; the locale gate (PLAYER_LOGIN, registered in the
--- bootstrap below) clears the whole cache when GetLocale() changes.
function MCB:Initialize()
    if MCB._initialized then
        return
    end
    MCB._initialized = true
    if GRIPEMS.RegisterCallback then
        GRIPEMS.RegisterCallback(MCB, "VARIABLE_UPDATED", function(_, _, varName)
            MCB._Invalidate(varName)
        end)
        GRIPEMS.RegisterCallback(MCB, "VARIABLE_CREATED", function(_, _, varName)
            MCB._Invalidate(varName)
        end)
        GRIPEMS.RegisterCallback(MCB, "VARIABLE_DELETED", function(_, _, varName)
            MCB._Invalidate(varName)
        end)
    end
    MCB._bakeLocale = GetLocale and GetLocale() or ""
end

-- Bootstrap: defer subscriber registration to PLAYER_LOGIN, when
-- GRIPEMS.RegisterCallback (wired at ADDON_LOADED) is guaranteed available,
-- and run the locale gate. Keeps the module self-contained -- no Core.lua
-- wiring needed. RewriteStepText also lazy-initializes on first use, so the
-- bake path is covered even before PLAYER_LOGIN fires.
local bootstrapFrame = CreateFrame and CreateFrame("Frame") or nil
if bootstrapFrame then
    bootstrapFrame:RegisterEvent("PLAYER_LOGIN")
    bootstrapFrame:SetScript("OnEvent", function()
        local loc = GetLocale and GetLocale() or ""
        if MCB._bakeLocale and MCB._bakeLocale ~= loc then
            MCB._InvalidateAll()
        end
        MCB:Initialize()
        MCB._bakeLocale = loc
    end)
end
