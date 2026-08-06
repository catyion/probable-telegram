local Ast = require("src.Ast")
local Syntax = require("src.Syntax")

local Parser = {}

local function current(state, offset)
    return state.tokens[state.index + (offset or 0)]
end

local function fail(state, token, message)
    token = token or current(state)
    error(string.format("%s:%d:%d: %s near %q", state.source_name, token.line, token.column, message, token.lexeme), 0)
end

local function advance(state)
    local token = current(state)
    state.index = state.index + 1
    return token
end

local function match(state, kind)
    if current(state).kind == kind then
        return advance(state)
    end
    return nil
end

local function expect(state, kind, message)
    local token = current(state)
    if token.kind ~= kind then
        fail(state, token, message or (kind .. " expected"))
    end
    return advance(state)
end

local parse_expression
local parse_block

local function identifier(token)
    return Ast.New("Identifier", token, token, {
        name = token.value,
    })
end

local function parse_expression_list(state)
    local expressions = { parse_expression(state, 1) }
    while match(state, ",") do
        expressions[#expressions + 1] = parse_expression(state, 1)
    end
    return expressions
end

local function parse_table(state)
    local start = expect(state, "{")
    local fields = {}

    while current(state).kind ~= "}" do
        local field_start = current(state)
        local field

        if match(state, "[") then
            local key = parse_expression(state, 1)
            expect(state, "]")
            expect(state, "=")
            local value = parse_expression(state, 1)
            field = Ast.New("ComputedField", field_start, value, {
                key = key,
                value = value,
            })
        elseif current(state).kind == "name" and current(state, 1).kind == "=" then
            local key_token = advance(state)
            advance(state)
            local value = parse_expression(state, 1)
            field = Ast.New("RecordField", field_start, value, {
                key = key_token.value,
                value = value,
            })
        else
            local value = parse_expression(state, 1)
            field = Ast.New("ArrayField", field_start, value, {
                value = value,
            })
        end

        fields[#fields + 1] = field

        if not match(state, ",") and not match(state, ";") then
            break
        end

        if current(state).kind == "}" then
            break
        end
    end

    local finish = expect(state, "}")
    return Ast.New("TableExpression", start, finish, {
        fields = fields,
    })
end

local function parse_function_body(state, start, inject_self)
    expect(state, "(")

    local parameters = {}
    local is_vararg = false

    if inject_self then
        parameters[#parameters + 1] = Ast.New("Identifier", start, start, {
            name = "self",
            implicit = true,
        })
    end

    if current(state).kind ~= ")" then
        if match(state, "...") then
            is_vararg = true
        else
            repeat
                local name = expect(state, "name", "parameter name expected")
                parameters[#parameters + 1] = identifier(name)

                if current(state).kind == "," and current(state, 1).kind == "..." then
                    advance(state)
                    advance(state)
                    is_vararg = true
                    break
                end
            until not match(state, ",")
        end
    end

    expect(state, ")")
    local body = parse_block(state, { ["end"] = true })
    local finish = expect(state, "end")

    return Ast.New("FunctionExpression", start, finish, {
        parameters = parameters,
        is_vararg = is_vararg,
        body = body,
    })
end

local function parse_arguments(state, expression)
    local token = current(state)
    local arguments
    local finish

    if token.kind == "(" then
        if token.line > expression.end_line then
            fail(state, token, "ambiguous syntax; function call parentheses must begin on the same line")
        end

        advance(state)
        arguments = {}
        if current(state).kind ~= ")" then
            arguments = parse_expression_list(state)
        end
        finish = expect(state, ")")
    elseif token.kind == "{" then
        local argument = parse_table(state)
        arguments = { argument }
        finish = argument
    elseif token.kind == "string" then
        local string_token = advance(state)
        local argument = Ast.New("StringLiteral", string_token, string_token, {
            value = string_token.value,
            raw = string_token.lexeme,
        })
        arguments = { argument }
        finish = string_token
    else
        fail(state, token, "function arguments expected")
    end

    return arguments, finish
end

local function parse_prefix_expression(state)
    local token = current(state)
    local expression

    if token.kind == "name" then
        advance(state)
        expression = identifier(token)
    elseif token.kind == "(" then
        local start = advance(state)
        local inner = parse_expression(state, 1)
        local finish = expect(state, ")")
        expression = Ast.New("ParenthesizedExpression", start, finish, {
            expression = inner,
        })
    else
        fail(state, token, "unexpected symbol")
    end

    while true do
        token = current(state)

        if token.kind == "." then
            advance(state)
            local name = expect(state, "name", "field name expected")
            expression = Ast.New("MemberExpression", expression, name, {
                object = expression,
                name = name.value,
            })
        elseif token.kind == "[" then
            advance(state)
            local key = parse_expression(state, 1)
            local finish = expect(state, "]")
            expression = Ast.New("IndexExpression", expression, finish, {
                object = expression,
                key = key,
            })
        elseif token.kind == ":" then
            advance(state)
            local name = expect(state, "name", "method name expected")
            local arguments, finish = parse_arguments(state, expression)
            expression = Ast.New("MethodCallExpression", expression, finish, {
                object = expression,
                method = name.value,
                arguments = arguments,
            })
        elseif token.kind == "(" or token.kind == "{" or token.kind == "string" then
            local arguments, finish = parse_arguments(state, expression)
            expression = Ast.New("CallExpression", expression, finish, {
                callee = expression,
                arguments = arguments,
            })
        else
            break
        end
    end

    return expression
end

local function parse_atom(state)
    local token = current(state)

    if token.kind == "nil" then
        advance(state)
        return Ast.New("NilLiteral", token, token)
    elseif token.kind == "true" or token.kind == "false" then
        advance(state)
        return Ast.New("BooleanLiteral", token, token, {
            value = token.kind == "true",
        })
    elseif token.kind == "number" then
        advance(state)
        return Ast.New("NumberLiteral", token, token, {
            value = token.value,
            raw = token.lexeme,
        })
    elseif token.kind == "string" then
        advance(state)
        return Ast.New("StringLiteral", token, token, {
            value = token.value,
            raw = token.lexeme,
        })
    elseif token.kind == "..." then
        advance(state)
        return Ast.New("VarargExpression", token, token)
    elseif token.kind == "function" then
        local start = advance(state)
        return parse_function_body(state, start, false)
    elseif token.kind == "{" then
        return parse_table(state)
    end

    return parse_prefix_expression(state)
end

parse_expression = function(state, minimum_power)
    local token = current(state)
    local left

    if Syntax.Unary[token.kind] then
        local operator = advance(state)
        local argument = parse_expression(state, Syntax.UnaryBindingPower)
        left = Ast.New("UnaryExpression", operator, argument, {
            operator = operator.kind,
            argument = argument,
        })
    else
        left = parse_atom(state)
    end

    while true do
        local operator = current(state)
        local power = Syntax.Binary[operator.kind]
        if not power or power[1] < minimum_power then
            break
        end

        advance(state)
        local right = parse_expression(state, power[2])
        left = Ast.New("BinaryExpression", left, right, {
            operator = operator.kind,
            left = left,
            right = right,
        })
    end

    return left
end

local function parse_return(state)
    local start = advance(state)
    local values = {}
    local kind = current(state).kind

    if kind ~= ";" and not Syntax.BlockEnd[kind] then
        values = parse_expression_list(state)
    end

    local finish = values[#values] or start
    return Ast.New("ReturnStatement", start, finish, {
        values = values,
    })
end

local function parse_local(state)
    local start = advance(state)

    local function_token = match(state, "function")
    if function_token then
        local name_token = expect(state, "name", "local function name expected")
        local name = identifier(name_token)
        local value = parse_function_body(state, function_token, false)
        return Ast.New("LocalFunctionStatement", start, value, {
            name = name,
            value = value,
        })
    end

    local names = {}
    repeat
        names[#names + 1] = identifier(expect(state, "name", "local name expected"))
    until not match(state, ",")

    local values = {}
    if match(state, "=") then
        values = parse_expression_list(state)
    end

    return Ast.New("LocalStatement", start, values[#values] or names[#names], {
        names = names,
        values = values,
    })
end

local function parse_function_statement(state)
    local start = advance(state)
    local name_token = expect(state, "name", "function name expected")
    local target = identifier(name_token)
    local inject_self = false

    while match(state, ".") do
        local field = expect(state, "name", "field name expected")
        target = Ast.New("MemberExpression", target, field, {
            object = target,
            name = field.value,
        })
    end

    if match(state, ":") then
        local field = expect(state, "name", "method name expected")
        target = Ast.New("MemberExpression", target, field, {
            object = target,
            name = field.value,
        })
        inject_self = true
    end

    local value = parse_function_body(state, start, inject_self)
    return Ast.New("FunctionStatement", start, value, {
        target = target,
        value = value,
    })
end

local function parse_do(state)
    local start = advance(state)
    local body = parse_block(state, { ["end"] = true })
    local finish = expect(state, "end")
    return Ast.New("DoStatement", start, finish, {
        body = body,
    })
end

local function parse_while(state)
    local start = advance(state)
    local condition = parse_expression(state, 1)
    expect(state, "do")
    local body = parse_block(state, { ["end"] = true })
    local finish = expect(state, "end")
    return Ast.New("WhileStatement", start, finish, {
        condition = condition,
        body = body,
    })
end

local function parse_repeat(state)
    local start = advance(state)
    local body = parse_block(state, { ["until"] = true })
    expect(state, "until")
    local condition = parse_expression(state, 1)
    return Ast.New("RepeatStatement", start, condition, {
        body = body,
        condition = condition,
    })
end

local function parse_if(state)
    local start = advance(state)
    local clauses = {}

    local condition = parse_expression(state, 1)
    expect(state, "then")
    local body = parse_block(state, { ["elseif"] = true, ["else"] = true, ["end"] = true })
    clauses[#clauses + 1] = {
        condition = condition,
        body = body,
    }

    while match(state, "elseif") do
        condition = parse_expression(state, 1)
        expect(state, "then")
        body = parse_block(state, { ["elseif"] = true, ["else"] = true, ["end"] = true })
        clauses[#clauses + 1] = {
            condition = condition,
            body = body,
        }
    end

    local else_body
    if match(state, "else") then
        else_body = parse_block(state, { ["end"] = true })
    end

    local finish = expect(state, "end")
    return Ast.New("IfStatement", start, finish, {
        clauses = clauses,
        else_body = else_body,
    })
end

local function parse_for(state)
    local start = advance(state)
    local first_name = identifier(expect(state, "name", "for variable expected"))

    if match(state, "=") then
        local initial = parse_expression(state, 1)
        expect(state, ",")
        local limit = parse_expression(state, 1)
        local step
        if match(state, ",") then
            step = parse_expression(state, 1)
        end
        expect(state, "do")
        local body = parse_block(state, { ["end"] = true })
        local finish = expect(state, "end")
        return Ast.New("NumericForStatement", start, finish, {
            variable = first_name,
            initial = initial,
            limit = limit,
            step = step,
            body = body,
        })
    end

    local names = { first_name }
    while match(state, ",") do
        names[#names + 1] = identifier(expect(state, "name", "for variable expected"))
    end

    expect(state, "in")
    local values = parse_expression_list(state)
    expect(state, "do")
    local body = parse_block(state, { ["end"] = true })
    local finish = expect(state, "end")

    return Ast.New("GenericForStatement", start, finish, {
        variables = names,
        values = values,
        body = body,
    })
end

local function parse_assignment_or_call(state)
    local first = parse_prefix_expression(state)

    if Ast.IsCall(first) and current(state).kind ~= "," and current(state).kind ~= "=" then
        return Ast.New("CallStatement", first, first, {
            expression = first,
        })
    end

    if not Ast.IsVariable(first) then
        fail(state, current(state), "assignment target expected")
    end

    local targets = { first }
    while match(state, ",") do
        local target = parse_prefix_expression(state)
        if not Ast.IsVariable(target) then
            fail(state, current(state), "assignment target expected")
        end
        targets[#targets + 1] = target
    end

    expect(state, "=", "'=' expected")
    local values = parse_expression_list(state)

    return Ast.New("AssignmentStatement", first, values[#values], {
        targets = targets,
        values = values,
    })
end

local function parse_statement(state)
    local kind = current(state).kind

    if kind == ";" then
        advance(state)
        return nil
    elseif kind == "local" then
        return parse_local(state)
    elseif kind == "function" then
        return parse_function_statement(state)
    elseif kind == "do" then
        return parse_do(state)
    elseif kind == "while" then
        return parse_while(state)
    elseif kind == "repeat" then
        return parse_repeat(state)
    elseif kind == "if" then
        return parse_if(state)
    elseif kind == "for" then
        return parse_for(state)
    elseif kind == "return" then
        return parse_return(state)
    elseif kind == "break" then
        local token = advance(state)
        return Ast.New("BreakStatement", token, token)
    end

    return parse_assignment_or_call(state)
end

parse_block = function(state, stop)
    local start = current(state)
    local statements = {}
    local terminal = false

    while not stop[current(state).kind] do
        if current(state).kind == "eof" then
            fail(state, current(state), "unexpected end of file")
        end

        if terminal then
            fail(state, current(state), "statement not allowed after return or break")
        end

        local statement = parse_statement(state)
        if statement then
            statements[#statements + 1] = statement
            terminal = statement.kind == "ReturnStatement" or statement.kind == "BreakStatement"
        end

        match(state, ";")
    end

    local finish = statements[#statements] or start
    return Ast.New("Block", start, finish, {
        statements = statements,
    })
end

function Parser.Parse(tokens, source_name)
    if type(tokens) ~= "table" then
        error("tokens must be a token array", 2)
    end

    local state = {
        tokens = tokens,
        index = 1,
        source_name = source_name or "=(source)",
    }

    local first = current(state)
    local body = parse_block(state, { ["eof"] = true })
    local finish = expect(state, "eof")

    return Ast.New("Chunk", first, finish, {
        body = body,
        source = state.source_name,
        is_vararg = true,
    })
end

return Parser
