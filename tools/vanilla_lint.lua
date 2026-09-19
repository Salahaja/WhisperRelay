--[[
    vanilla_lint.lua - checks addon source against what WoW 1.12 actually runs.

    Usage (from the repo root):
        lua tools/vanilla_lint.lua GrayfathersFrameroids.lua [more files...]

    Why this exists on top of `luac -p`: the interpreter available on a modern
    machine is Lua 5.4, but vanilla 1.12 runs Lua 5.0. Every syntax feature
    added since (the # length operator, % modulo, goto, integer division,
    bitwise operators) parses PERFECTLY under 5.4 and then blows up in-game
    with a script error. A clean `luac -p` is therefore not evidence the file
    will load in 1.12 - it only rules out plain typos. This catches the gap.

    It also flags standard-library and WoW API calls that don't exist in
    1.12 but do exist later (string.match, hooksecurefunc, SetShown, ...),
    which are runtime errors rather than parse errors and so would otherwise
    only surface when the exact code path runs in-game.

    Deliberately a text scanner, not a parser: it needs to flag things a 5.4
    parser accepts without complaint, so the parser can't be the thing doing
    the checking. Strings and comments are blanked out first (preserving line
    and column numbers) so a % inside a Lua pattern or a # inside a comment
    isn't mistaken for an operator.
--]]

-- Replaces every string literal and comment with spaces, keeping the file's
-- exact length so positions still map back to real line/column numbers.
local function blankStringsAndComments(src)
    local out = {}
    local i, n = 1, #src

    local function emit(text) out[#out + 1] = text end
    local function blanked(text) return (string.gsub(text, "[^\n]", " ")) end

    while i <= n do
        local c = string.sub(src, i, i)
        local two = string.sub(src, i, i + 1)

        if two == "--" then
            -- Long comment --[[ ]] / --[==[ ]==] , else to end of line.
            local _, closeStart, eq = string.find(src, "^%-%-%[(=*)%[", i)
            if closeStart then
                local pattern = "%]" .. eq .. "%]"
                local s, e = string.find(src, pattern, closeStart + 1)
                e = e or n
                emit(blanked(string.sub(src, i, e)))
                i = e + 1
            else
                local e = string.find(src, "\n", i) or (n + 1)
                emit(blanked(string.sub(src, i, e - 1)))
                i = e
            end
        elseif c == '"' or c == "'" then
            local j = i + 1
            while j <= n do
                local cj = string.sub(src, j, j)
                if cj == "\\" then
                    j = j + 2
                elseif cj == c or cj == "\n" then
                    break
                else
                    j = j + 1
                end
            end
            emit(blanked(string.sub(src, i, math.min(j, n))))
            i = j + 1
        else
            local _, bracketEnd, eq = string.find(src, "^%[(=*)%[", i)
            if bracketEnd then
                local s, e = string.find(src, "%]" .. eq .. "%]", bracketEnd + 1)
                e = e or n
                emit(blanked(string.sub(src, i, e)))
                i = e + 1
            else
                emit(c)
                i = i + 1
            end
        end
    end

    return table.concat(out)
end

-- Each rule gets the code with strings/comments blanked. `pattern` is matched
-- repeatedly; `skip` (optional) gets the match plus the character following it
-- and returns true to ignore that hit.
local RULES = {
    {
        pattern = "#",
        msg = "the # length operator is Lua 5.1+ - vanilla 1.12 needs table.getn(t) (and string.len(s))",
        skip = function(code, pos)
            -- A #! shebang on line 1 is not an operator.
            return pos == 1 and string.sub(code, 1, 2) == "#!"
        end,
    },
    {
        pattern = "%%",
        msg = "the % modulo operator is Lua 5.1+ - vanilla 1.12 needs math.mod(a, b)",
    },
    {
        pattern = "//",
        msg = "// integer division is Lua 5.3+ - not available in vanilla 1.12",
    },
    {
        pattern = "::[%a_][%w_]*::",
        msg = "goto labels are Lua 5.4 - not available in vanilla 1.12",
    },
    {
        pattern = "[%s(]goto[%s]",
        msg = "goto is Lua 5.4 - not available in vanilla 1.12",
    },
    {
        pattern = "<<",
        msg = "bitwise shifts are Lua 5.3+ - not available in vanilla 1.12",
    },
    {
        pattern = ">>",
        msg = "bitwise shifts are Lua 5.3+ - not available in vanilla 1.12",
    },
    {
        pattern = "~",
        msg = "bitwise not is Lua 5.3+ - not available in vanilla 1.12",
        skip = function(code, pos)
            -- ~= is the (perfectly fine) not-equal operator.
            return string.sub(code, pos + 1, pos + 1) == "="
        end,
    },
    -- Standard library that only exists in later Lua versions.
    { pattern = "string%.match",   msg = "string.match is Lua 5.1+ - use string.find with captures" },
    { pattern = "string%.gmatch",  msg = "string.gmatch is Lua 5.1+ - use string.gfind" },
    { pattern = ":match%(",        msg = "s:match() is Lua 5.1+ - use string.find with captures" },
    { pattern = ":gmatch%(",       msg = "s:gmatch() is Lua 5.1+ - use string.gfind" },
    { pattern = "math%.fmod",      msg = "math.fmod is Lua 5.1+ - use math.mod" },
    { pattern = "table%.unpack",   msg = "table.unpack is Lua 5.2+ - use unpack" },
    { pattern = "table%.maxn",     msg = "table.maxn is Lua 5.1+ - not available in vanilla 1.12" },
    { pattern = "select%(",        msg = "select() is Lua 5.1+ - in 5.0 varargs arrive as the `arg` table" },
    { pattern = "os%.exit",        msg = "os.exit is not exposed to WoW addons" },
    -- WoW API that postdates 1.12.
    { pattern = "hooksecurefunc",     msg = "hooksecurefunc() does not exist in 1.12 - save the old function and call it yourself" },
    { pattern = ":SetShown%(",        msg = "SetShown() does not exist in 1.12 - use :Show()/:Hide()" },
    { pattern = "InCombatLockdown",   msg = "InCombatLockdown() does not exist in 1.12" },
    { pattern = "GetNumGroupMembers", msg = "GetNumGroupMembers() does not exist in 1.12 - use GetNumPartyMembers/GetNumRaidMembers" },
    { pattern = "IsInRaid%(",         msg = "IsInRaid() does not exist in 1.12 - use GetNumRaidMembers() > 0" },
    { pattern = "IsInGroup%(",        msg = "IsInGroup() does not exist in 1.12 - use GetNumPartyMembers() > 0" },
    -- %f[%w] is a frontier pattern: it anchors the match to a word boundary
    -- so GetUnitGUID (SuperWoW, and present on this client) is not mistaken
    -- for the stock UnitGUID that genuinely is missing in 1.12.
    { pattern = "%f[%w]UnitGUID",     msg = "UnitGUID() does not exist in 1.12 - identify units by name" },
    { pattern = "C_[%a]+%.",          msg = "the C_ namespace does not exist in 1.12" },
    { pattern = "string%.split",      msg = "string.split() does not exist in 1.12 - use string.gfind" },
}

-- Rules that must see string literals, so they run on the ORIGINAL source
-- rather than the blanked copy the rules above use.
local RAW_RULES = {
    {
        -- 1.12 SendAddonMessage accepts PARTY, RAID, GUILD and BATTLEGROUND
        -- only. "WHISPER" is not rejected politely: the client throws
        -- "Unknown addon chat type" and can take the process down with it
        -- (ERROR #132). Addon-to-addon whispers have to be done as an
        -- addressed broadcast on a channel that is allowed.
        pattern = "SendAddonMessage%s*%([^)]-[\"\047]WHISPER[\"\047]",
        msg = "SendAddonMessage cannot use WHISPER in 1.12 - it errors and can crash the client; address a PARTY/RAID/GUILD broadcast instead",
    },
}

local function lineColumnAt(src, pos)
    local line, lineStart = 1, 1
    local i = 1
    while true do
        local nl = string.find(src, "\n", i, true)
        if not nl or nl >= pos then break end
        line = line + 1
        lineStart = nl + 1
        i = nl + 1
    end
    return line, pos - lineStart + 1
end

--[[ Closures that capture a generic-for CONTROL variable.

     In 5.0 the control variables of `for k, v in ...` belong to the loop, not
     to one turn of it, and the iterator's terminating nil is assigned to them
     on the way out. So a closure that captures v and runs LATER -- an OnClick,
     a getter handed to a widget -- reads nil, and the symptom is "attempt to
     index a nil value" pointing at a line that reads perfectly.

     Nothing else catches this. It runs correctly under 5.4, where each turn of
     the loop gets its own copy, so the desktop harness gives the answer we
     want no matter what the client does. It cost a day in the announce dialog.

     The fix is to not capture it: stash what the closure needs on the widget
     (as report.lua does with b.tabKey), or take it as a function parameter,
     which is per-call in every version of Lua.

     Only flags references INSIDE the closure body -- `table.sort(v.list,
     function(a, b) ... end)` reads v before the closure exists, and runs it
     before the loop moves on, so it is fine. ]]

local BLOCK_OPEN = { ["function"] = true, ["do"] = true, ["then"] = true,
                     ["repeat"] = true }
local BLOCK_CLOSE = { ["end"] = true, ["until"] = true }

-- The position just past the `end` that closes the block opened at `from`.
local function blockEnd(code, from)
    local depth, init = 1, from
    while depth > 0 do
        local s, e, word = string.find(code, "([%a_][%w_]*)", init)
        if not s then return #code end
        -- `elseif ... then` re-opens what it just closed; net zero.
        if word == "elseif" then depth = depth - 1 end
        if BLOCK_OPEN[word] then depth = depth + 1
        elseif BLOCK_CLOSE[word] then depth = depth - 1 end
        init = e + 1
    end
    return init
end

--[[ Closures these hand straight to something that calls them before it
     returns are safe: the loop has not moved on yet. Everything else is
     stored and called later, which is the whole problem. ]]
local CALLED_IMMEDIATELY = {
    pcall = true, xpcall = true, sort = true, foreach = true, foreachi = true,
}

-- The name of the call whose argument list `pos` sits in, if any.
local function enclosingCall(code, pos)
    local depth, i = 0, pos - 1
    while i > 0 do
        local c = string.sub(code, i, i)
        if c == ")" then depth = depth + 1
        elseif c == "(" then
            if depth == 0 then
                local name = string.match(string.sub(code, 1, i - 1), "([%a_][%w_]*)%s*$")
                return name
            end
            depth = depth - 1
        end
        i = i - 1
    end
    return nil
end

local function loopVarCaptures(code)
    local hits, seen, init = {}, {}, 1
    while true do
        local s, e, names = string.find(code, "%f[%w_]for%s+([%w_][%w_,%s]-)%s+in%s", init)
        if not s then break end
        init = e

        local vars = {}
        for v in string.gmatch(names, "[%a_][%w_]*") do
            if v ~= "_" then vars[v] = true end
        end

        local doStart = string.find(code, "%f[%w_]do%f[^%w_]", e)
        if doStart then
            local loopEnd = blockEnd(code, doStart + 2)
            -- Every closure opened inside this loop body.
            local fpos = doStart
            while true do
                local fs, fe = string.find(code, "%f[%w_]function%s*%(", fpos)
                if not fs or fs >= loopEnd then break end
                fpos = fe

                local caller = enclosingCall(code, fs)
                if not (caller and CALLED_IMMEDIATELY[caller]) then
                    local closeEnd = blockEnd(code, fe)
                    local body = string.sub(code, fe, math.min(closeEnd, loopEnd))
                    for v in pairs(vars) do
                        local bi = 1
                        while true do
                            local bs, be = string.find(body, "%f[%w_]" .. v .. "%f[^%w_]", bi)
                            if not bs then break end
                            -- `R.state.tab` is a field that happens to share
                            -- the name, not the loop variable.
                            local prev = bs > 1 and string.sub(body, bs - 1, bs - 1) or ""
                            if prev ~= "." and prev ~= ":" then
                                local pos = fe + bs - 1
                                -- Nested closures see the same reference once.
                                if not seen[pos] then
                                    seen[pos] = true
                                    hits[#hits + 1] = { pos = pos, var = v }
                                end
                            end
                            bi = be + 1
                        end
                    end
                end
            end
        end
    end
    return hits
end

local function lintFile(path)
    local fh = io.open(path, "r")
    if not fh then
        print(path .. ": cannot open")
        return 1
    end
    local src = fh:read("*a")
    fh:close()

    local findings = 0

    -- Parse first: a syntax error makes every other finding noise.
    local chunk, err = loadstring and loadstring(src, path) or load(src, path)
    if not chunk then
        print(path .. ": SYNTAX ERROR: " .. tostring(err))
        return 1
    end

    local code = blankStringsAndComments(src)

    for _, rule in ipairs(RULES) do
        local init = 1
        while true do
            local s, e = string.find(code, rule.pattern, init)
            if not s then break end
            if not (rule.skip and rule.skip(code, s)) then
                local line, col = lineColumnAt(src, s)
                print(path .. ":" .. line .. ":" .. col .. ": " .. rule.msg)
                findings = findings + 1
            end
            init = e + 1
        end
    end

    for _, rule in ipairs(RAW_RULES) do
        local init = 1
        while true do
            local st, en = string.find(src, rule.pattern, init)
            if not st then break end
            local line, col = lineColumnAt(src, st)
            print(path .. ":" .. line .. ":" .. col .. ": " .. rule.msg)
            findings = findings + 1
            init = en + 1
        end
    end

    for _, hit in ipairs(loopVarCaptures(code)) do
        local line, col = lineColumnAt(src, hit.pos)
        print(path .. ":" .. line .. ":" .. col ..
            ": closure captures the for-in variable '" .. hit.var ..
            "' - in 5.0 that is one slot for the whole loop, and it holds nil " ..
            "once the loop ends; pass it as an argument or stash it on the frame")
        findings = findings + 1
    end

    return findings
end

--[[ The loop-capture scanner checks itself before it checks anything else.

     It is pattern matching over blanked source, not a parser, so it is exactly
     the kind of check that can quietly stop matching after an unrelated tweak
     and report "clean" forever. These two samples are the bug and the shape
     most likely to be mistaken for it. ]]
do
    local bad = "for k, v in pairs(t) do b:SetScript('x', function() f(v.key) end) end"
    local good = "for k, v in pairs(t) do table.sort(v.list, function(a, b) return a < b end) end"
    if #loopVarCaptures(blankStringsAndComments(bad)) == 0 then
        print("vanilla_lint: INTERNAL - the for-in capture check no longer detects its own example")
        os.exit(1)
    end
    if #loopVarCaptures(blankStringsAndComments(good)) > 0 then
        print("vanilla_lint: INTERNAL - the for-in capture check flags a closure that runs inside the loop")
        os.exit(1)
    end
end

local files = {}
for i = 1, 100 do
    if not arg[i] then break end
    files[#files + 1] = arg[i]
end

if #files == 0 then
    print("usage: lua tools/vanilla_lint.lua <file.lua> [more...]")
    os.exit(2)
end

local total = 0
for _, path in ipairs(files) do
    total = total + lintFile(path)
end

if total == 0 then
    print("vanilla 1.12 lint: clean (" .. #files .. " file(s))")
    os.exit(0)
else
    print("vanilla 1.12 lint: " .. total .. " problem(s)")
    os.exit(1)
end
