local Resolver = {}

local function fail(state, node, message)
    error(string.format("%s:%d:%d: %s", state.source_name, node.line, node.column, message), 0)
end

local function new_function(parent, node, is_vararg)
    return {
        parent = parent,
        node = node,
        is_vararg = is_vararg,
        symbols = {},
        parameters = {},
        upvalues = {},
        upvalue_map = {},
    }
end

local function push_scope(state)
    local scope = {
        parent = state.scope,
        bindings = {},
    }
    state.scope = scope
    return scope
end

local function pop_scope(state)
    state.scope = state.scope.parent
end

local function declare(state, identifier, is_parameter)
    state.next_symbol = state.next_symbol + 1

    local symbol = {
        id = state.next_symbol,
        name = identifier.name,
        owner = state.current_function,
        declaration = identifier,
        captured = false,
        is_parameter = is_parameter or false,
    }

    identifier.symbol = symbol
    state.scope.bindings[identifier.name] = symbol

    local symbols = state.current_function.symbols
    symbols[#symbols + 1] = symbol

    if is_parameter then
        local parameters = state.current_function.parameters
        parameters[#parameters + 1] = symbol
    end

    return symbol
end

local function find_symbol(state, name)
    local scope = state.scope
    while scope do
        local symbol = scope.bindings[name]
        if symbol then
            return symbol
        end
        scope = scope.parent
    end
    return nil
end

local function capture(function_scope, symbol)
    local existing = function_scope.upvalue_map[symbol.id]
    if existing ~= nil then
        return existing
    end

    local parent = function_scope.parent
    if not parent then
        return nil
    end

    local descriptor
    if symbol.owner == parent then
        symbol.captured = true
        descriptor = {
            kind = "local",
            symbol = symbol,
            name = symbol.name,
        }
    else
        local parent_index = capture(parent, symbol)
        if parent_index == nil then
            return nil
        end

        descriptor = {
            kind = "upvalue",
            parent_index = parent_index,
            symbol = symbol,
            name = symbol.name,
        }
    end

    local index = #function_scope.upvalues
    descriptor.index = index
    function_scope.upvalues[#function_scope.upvalues + 1] = descriptor
    function_scope.upvalue_map[symbol.id] = index
    return index
end

local function resolve_identifier(state, node)
    local symbol = find_symbol(state, node.name)

    if not symbol then
        node.binding = {
            kind = "global",
            name = node.name,
        }
    elseif symbol.owner == state.current_function then
        node.binding = {
            kind = "local",
            symbol = symbol,
        }
    else
        local index = capture(state.current_function, symbol)
        if index == nil then
            fail(state, node, "unable to capture local '" .. node.name .. "'")
        end

        node.binding = {
            kind = "upvalue",
            index = index,
            symbol = symbol,
        }
    end
end

local resolve_expression
local resolve_statement

local function resolve_expression_list(state, expressions)
    for index = 1, #expressions do
        resolve_expression(state, expressions[index])
    end
end

local function resolve_function(state, node)
    local parent_function = state.current_function
    local parent_loop_depth = state.loop_depth
    local function_scope = new_function(parent_function, node, node.is_vararg)

    node.function_scope = function_scope
    state.current_function = function_scope
    state.loop_depth = 0

    push_scope(state)
    for index = 1, #node.parameters do
        declare(state, node.parameters[index], true)
    end

    for index = 1, #node.body.statements do
        resolve_statement(state, node.body.statements[index])
    end

    pop_scope(state)
    state.current_function = parent_function
    state.loop_depth = parent_loop_depth
end

resolve_expression = function(state, node)
    local kind = node.kind

    if kind == "Identifier" then
        resolve_identifier(state, node)
    elseif kind == "ParenthesizedExpression" then
        resolve_expression(state, node.expression)
    elseif kind == "IndexExpression" then
        resolve_expression(state, node.object)
        resolve_expression(state, node.key)
    elseif kind == "MemberExpression" then
        resolve_expression(state, node.object)
    elseif kind == "CallExpression" then
        resolve_expression(state, node.callee)
        resolve_expression_list(state, node.arguments)
    elseif kind == "MethodCallExpression" then
        resolve_expression(state, node.object)
        resolve_expression_list(state, node.arguments)
    elseif kind == "UnaryExpression" then
        resolve_expression(state, node.argument)
    elseif kind == "BinaryExpression" then
        resolve_expression(state, node.left)
        resolve_expression(state, node.right)
    elseif kind == "TableExpression" then
        for index = 1, #node.fields do
            local field = node.fields[index]
            if field.kind == "ComputedField" then
                resolve_expression(state, field.key)
            end
            resolve_expression(state, field.value)
        end
    elseif kind == "FunctionExpression" then
        resolve_function(state, node)
    elseif kind == "VarargExpression" then
        if not state.current_function.is_vararg then
            fail(state, node, "cannot use '...' outside a vararg function")
        end
    elseif kind == "NilLiteral"
        or kind == "BooleanLiteral"
        or kind == "NumberLiteral"
        or kind == "StringLiteral"
    then
        return
    else
        fail(state, node, "unsupported expression node '" .. tostring(kind) .. "'")
    end
end

local function resolve_scoped_block(state, block)
    push_scope(state)
    for index = 1, #block.statements do
        resolve_statement(state, block.statements[index])
    end
    pop_scope(state)
end

resolve_statement = function(state, node)
    local kind = node.kind

    if kind == "LocalStatement" then
        resolve_expression_list(state, node.values)
        node.symbols = {}
        for index = 1, #node.names do
            node.symbols[index] = declare(state, node.names[index], false)
        end
    elseif kind == "LocalFunctionStatement" then
        node.symbol = declare(state, node.name, false)
        resolve_function(state, node.value)
    elseif kind == "AssignmentStatement" then
        for index = 1, #node.targets do
            resolve_expression(state, node.targets[index])
        end
        resolve_expression_list(state, node.values)
    elseif kind == "FunctionStatement" then
        resolve_expression(state, node.target)
        resolve_function(state, node.value)
    elseif kind == "CallStatement" then
        resolve_expression(state, node.expression)
    elseif kind == "DoStatement" then
        resolve_scoped_block(state, node.body)
    elseif kind == "WhileStatement" then
        resolve_expression(state, node.condition)
        state.loop_depth = state.loop_depth + 1
        resolve_scoped_block(state, node.body)
        state.loop_depth = state.loop_depth - 1
    elseif kind == "RepeatStatement" then
        state.loop_depth = state.loop_depth + 1
        push_scope(state)
        for index = 1, #node.body.statements do
            resolve_statement(state, node.body.statements[index])
        end
        resolve_expression(state, node.condition)
        pop_scope(state)
        state.loop_depth = state.loop_depth - 1
    elseif kind == "IfStatement" then
        for index = 1, #node.clauses do
            local clause = node.clauses[index]
            resolve_expression(state, clause.condition)
            resolve_scoped_block(state, clause.body)
        end
        if node.else_body then
            resolve_scoped_block(state, node.else_body)
        end
    elseif kind == "NumericForStatement" then
        resolve_expression(state, node.initial)
        resolve_expression(state, node.limit)
        if node.step then
            resolve_expression(state, node.step)
        end

        state.loop_depth = state.loop_depth + 1
        push_scope(state)
        node.symbol = declare(state, node.variable, false)
        for index = 1, #node.body.statements do
            resolve_statement(state, node.body.statements[index])
        end
        pop_scope(state)
        state.loop_depth = state.loop_depth - 1
    elseif kind == "GenericForStatement" then
        resolve_expression_list(state, node.values)

        state.loop_depth = state.loop_depth + 1
        push_scope(state)
        node.symbols = {}
        for index = 1, #node.variables do
            node.symbols[index] = declare(state, node.variables[index], false)
        end
        for index = 1, #node.body.statements do
            resolve_statement(state, node.body.statements[index])
        end
        pop_scope(state)
        state.loop_depth = state.loop_depth - 1
    elseif kind == "ReturnStatement" then
        resolve_expression_list(state, node.values)
    elseif kind == "BreakStatement" then
        if state.loop_depth == 0 then
            fail(state, node, "break outside loop")
        end
    else
        fail(state, node, "unsupported statement node '" .. tostring(kind) .. "'")
    end
end

function Resolver.Resolve(chunk, source_name)
    if type(chunk) ~= "table" or chunk.kind ~= "Chunk" then
        error("chunk must be a parsed Chunk node", 2)
    end

    local main_function = new_function(nil, chunk, true)
    local state = {
        source_name = source_name or chunk.source or "=(source)",
        current_function = main_function,
        scope = nil,
        loop_depth = 0,
        next_symbol = 0,
    }

    chunk.function_scope = main_function
    push_scope(state)

    for index = 1, #chunk.body.statements do
        resolve_statement(state, chunk.body.statements[index])
    end

    pop_scope(state)
    return chunk
end

return Resolver
