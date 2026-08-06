local Syntax = require("lua51c.Syntax")

local Lexer = {}

local byte = string.byte
local char = string.char
local find = string.find
local sub = string.sub
local concat = table.concat

local ESCAPES = {
    ["a"] = "\a",
    ["b"] = "\b",
    ["f"] = "\f",
    ["n"] = "\n",
    ["r"] = "\r",
    ["t"] = "\t",
    ["v"] = "\v",
    ["\\"] = "\\",
    ["\""] = "\"",
    ["'"] = "'",
}

local SINGLE = {
    [43] = "+",
    [45] = "-",
    [42] = "*",
    [47] = "/",
    [37] = "%",
    [94] = "^",
    [35] = "#",
    [60] = "<",
    [62] = ">",
    [61] = "=",
    [40] = "(",
    [41] = ")",
    [123] = "{",
    [125] = "}",
    [91] = "[",
    [93] = "]",
    [59] = ";",
    [58] = ":",
    [44] = ",",
    [46] = ".",
}

local function is_digit(value)
    return value and value >= 48 and value <= 57
end

local function is_alpha_numeric(value)
    return value and (
        (value >= 48 and value <= 57)
        or (value >= 65 and value <= 90)
        or (value >= 97 and value <= 122)
        or value == 95
    )
end

local function fail(state, line, column, message)
    error(string.format("%s:%d:%d: %s", state.source_name, line, column, message), 0)
end

local function consume_newline(state)
    local first = byte(state.source, state.position)
    state.position = state.position + 1

    local second = byte(state.source, state.position)
    if (first == 10 and second == 13) or (first == 13 and second == 10) then
        state.position = state.position + 1
    end

    state.line = state.line + 1
    state.line_start = state.position
end

local function make_token(state, kind, value, lexeme, start_position, start_line, start_column)
    return {
        kind = kind,
        value = value,
        lexeme = lexeme,
        line = start_line,
        column = start_column,
        offset = start_position,
        end_line = state.line,
        end_column = state.position - state.line_start + 1,
        end_offset = state.position,
    }
end

local function long_separator(source, position, bracket)
    if byte(source, position) ~= bracket then
        return nil
    end

    local cursor = position + 1
    while byte(source, cursor) == 61 do
        cursor = cursor + 1
    end

    if byte(source, cursor) == bracket then
        return cursor - position - 1
    end

    return nil
end

local function consume_long(state, separator, collect_value, start_line, start_column)
    local source = state.source
    local closing_position = state.position + separator + 1
    state.position = closing_position + 1

    local current = byte(source, state.position)
    if current == 10 or current == 13 then
        consume_newline(state)
    end

    local pieces = collect_value and {} or nil
    local piece_start = state.position

    while state.position <= state.length do
        current = byte(source, state.position)

        if current == 93 and long_separator(source, state.position, 93) == separator then
            if collect_value then
                pieces[#pieces + 1] = sub(source, piece_start, state.position - 1)
            end

            state.position = state.position + separator + 2
            return collect_value and concat(pieces) or nil
        end

        if current == 10 or current == 13 then
            if collect_value then
                pieces[#pieces + 1] = sub(source, piece_start, state.position - 1)
                pieces[#pieces + 1] = "\n"
            end

            consume_newline(state)
            piece_start = state.position
        else
            state.position = state.position + 1
        end
    end

    fail(state, start_line, start_column, "unfinished long string or comment")
end

local function read_short_string(state, quote, start_line, start_column)
    local source = state.source
    local pieces = {}
    state.position = state.position + 1
    local piece_start = state.position

    while state.position <= state.length do
        local current = byte(source, state.position)

        if current == quote then
            pieces[#pieces + 1] = sub(source, piece_start, state.position - 1)
            state.position = state.position + 1
            return concat(pieces)
        end

        if current == 10 or current == 13 then
            fail(state, start_line, start_column, "unfinished string")
        end

        if current == 92 then
            pieces[#pieces + 1] = sub(source, piece_start, state.position - 1)
            state.position = state.position + 1

            local escaped = byte(source, state.position)
            if not escaped then
                fail(state, start_line, start_column, "unfinished string")
            end

            if escaped == 10 or escaped == 13 then
                pieces[#pieces + 1] = "\n"
                consume_newline(state)
            elseif is_digit(escaped) then
                local value = 0
                local count = 0

                while count < 3 and is_digit(byte(source, state.position)) do
                    value = value * 10 + byte(source, state.position) - 48
                    state.position = state.position + 1
                    count = count + 1
                end

                if value > 255 then
                    fail(state, state.line, state.position - state.line_start + 1, "escape sequence too large")
                end

                pieces[#pieces + 1] = char(value)
            else
                local character = char(escaped)
                pieces[#pieces + 1] = ESCAPES[character] or character
                state.position = state.position + 1
            end

            piece_start = state.position
        else
            state.position = state.position + 1
        end
    end

    fail(state, start_line, start_column, "unfinished string")
end

local function parse_hex_number(text)
    local digits = text:match("^0[xX]([%da-fA-F]+)$")
    if not digits then
        return nil
    end

    local value = 0
    for index = 1, #digits do
        local digit = byte(digits, index)
        if digit >= 48 and digit <= 57 then
            digit = digit - 48
        elseif digit >= 65 and digit <= 70 then
            digit = digit - 55
        else
            digit = digit - 87
        end
        value = value * 16 + digit
    end

    return value
end

local function parse_decimal_number(text)
    local base = text
    local exponent = text:match("[eE].*$")

    if exponent then
        if not exponent:match("^[eE][+-]?%d+$") then
            return nil
        end
        base = text:sub(1, #text - #exponent)
    end

    if not base:match("^%d+%.?%d*$") and not base:match("^%.%d+$") then
        return nil
    end

    return tonumber(text)
end

local function read_number(state)
    local source = state.source
    local cursor = state.position
    local previous

    while cursor <= state.length do
        local current = byte(source, cursor)
        if is_alpha_numeric(current) or current == 46 then
            previous = current
            cursor = cursor + 1
        elseif (current == 43 or current == 45) and (previous == 69 or previous == 101) then
            previous = current
            cursor = cursor + 1
        else
            break
        end
    end

    local lexeme = sub(source, state.position, cursor - 1)
    local value

    if lexeme:match("^0[xX]") then
        value = parse_hex_number(lexeme)
    else
        value = parse_decimal_number(lexeme)
    end

    if value == nil then
        fail(state, state.line, state.position - state.line_start + 1, "malformed number")
    end

    state.position = cursor
    return value, lexeme
end

local function skip_trivia(state)
    local source = state.source

    while state.position <= state.length do
        local current = byte(source, state.position)

        if current == 32 or current == 9 or current == 11 or current == 12 then
            local next_position = find(source, "[^ \t\v\f]", state.position)
            state.position = next_position or (state.length + 1)
        elseif current == 10 or current == 13 then
            consume_newline(state)
        elseif current == 45 and byte(source, state.position + 1) == 45 then
            state.position = state.position + 2

            local separator = long_separator(source, state.position, 91)
            if separator then
                consume_long(
                    state,
                    separator,
                    false,
                    state.line,
                    state.position - state.line_start + 1
                )
            else
                local newline = find(source, "[\r\n]", state.position)
                state.position = newline or (state.length + 1)
            end
        else
            return
        end
    end
end

local function next_token(state)
    skip_trivia(state)

    local start_position = state.position
    local start_line = state.line
    local start_column = start_position - state.line_start + 1

    if start_position > state.length then
        return make_token(state, "eof", nil, "", start_position, start_line, start_column)
    end

    local source = state.source
    local current = byte(source, start_position)

    if (current >= 65 and current <= 90) or (current >= 97 and current <= 122) or current == 95 then
        local _, finish = find(source, "^[%a_][%w_]*", start_position)
        local lexeme = sub(source, start_position, finish)
        state.position = finish + 1
        local kind = Syntax.Keywords[lexeme] and lexeme or "name"
        return make_token(state, kind, lexeme, lexeme, start_position, start_line, start_column)
    end

    if is_digit(current) or (current == 46 and is_digit(byte(source, start_position + 1))) then
        local value, lexeme = read_number(state)
        return make_token(state, "number", value, lexeme, start_position, start_line, start_column)
    end

    if current == 34 or current == 39 then
        local value = read_short_string(state, current, start_line, start_column)
        local lexeme = sub(source, start_position, state.position - 1)
        return make_token(state, "string", value, lexeme, start_position, start_line, start_column)
    end

    if current == 91 then
        local separator = long_separator(source, start_position, 91)
        if separator then
            local value = consume_long(state, separator, true, start_line, start_column)
            local lexeme = sub(source, start_position, state.position - 1)
            return make_token(state, "string", value, lexeme, start_position, start_line, start_column)
        end
    end

    local next_byte = byte(source, start_position + 1)
    local third_byte = byte(source, start_position + 2)
    local kind

    if current == 46 and next_byte == 46 and third_byte == 46 then
        kind = "..."
        state.position = state.position + 3
    elseif current == 46 and next_byte == 46 then
        kind = ".."
        state.position = state.position + 2
    elseif current == 61 and next_byte == 61 then
        kind = "=="
        state.position = state.position + 2
    elseif current == 126 and next_byte == 61 then
        kind = "~="
        state.position = state.position + 2
    elseif current == 60 and next_byte == 61 then
        kind = "<="
        state.position = state.position + 2
    elseif current == 62 and next_byte == 61 then
        kind = ">="
        state.position = state.position + 2
    else
        kind = SINGLE[current]
        if not kind then
            fail(state, start_line, start_column, string.format("unexpected symbol near %q", char(current)))
        end
        state.position = state.position + 1
    end

    local lexeme = sub(source, start_position, state.position - 1)
    return make_token(state, kind, kind, lexeme, start_position, start_line, start_column)
end

function Lexer.Tokenize(source, source_name)
    if type(source) ~= "string" then
        error("source must be a string", 2)
    end

    local state = {
        source = source,
        source_name = source_name or "=(source)",
        length = #source,
        position = 1,
        line = 1,
        line_start = 1,
    }

    local tokens = {}
    repeat
        tokens[#tokens + 1] = next_token(state)
    until tokens[#tokens].kind == "eof"

    return tokens
end

return Lexer
