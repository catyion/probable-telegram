local Ast = require("src.Ast")
local Opcode = require("src.Opcode")

local Generator = {}

local Op = Opcode.Op
local floor = math.floor

local ARITHMETIC = {
    ["+"] = Op.ADD,
    ["-"] = Op.SUB,
    ["*"] = Op.MUL,
    ["/"] = Op.DIV,
    ["%"] = Op.MOD,
    ["^"] = Op.POW,
}

local UNARY = {
    ["-"] = Op.UNM,
    ["not"] = Op.NOT,
    ["#"] = Op.LEN,
}

local function fail(state, node, message)
    error(string.format("%s:%d:%d: %s", state.proto.source, node.line or 0, node.column or 0, message), 0)
end

local function pc(state)
    return #state.proto.code
end

local function check_field(state, node, value, maximum, name)
    if value < 0 or value > maximum then
        fail(state, node, name .. " exceeds Lua 5.1 bytecode limits")
    end
end

local function emit(state, instruction, line)
    local code = state.proto.code
    code[#code + 1] = instruction
    state.proto.line_info[#state.proto.line_info + 1] = line or 0
    return #code - 1
end

local function emit_abc(state, op, a, b, c, line, node)
    check_field(state, node or { line = line }, a, Opcode.MAXARG_A, "register A")
    check_field(state, node or { line = line }, b, Opcode.MAXARG_B, "operand B")
    check_field(state, node or { line = line }, c, Opcode.MAXARG_C, "operand C")
    return emit(state, Opcode.EncodeABC(op, a, b, c), line)
end

local function emit_abx(state, op, a, bx, line, node)
    check_field(state, node or { line = line }, a, Opcode.MAXARG_A, "register A")
    check_field(state, node or { line = line }, bx, Opcode.MAXARG_Bx, "operand Bx")
    return emit(state, Opcode.EncodeABx(op, a, bx), line)
end

local function emit_asbx(state, op, a, sbx, line, node)
    check_field(state, node or { line = line }, a, Opcode.MAXARG_A, "register A")
    if sbx < -Opcode.MAXARG_sBx or sbx > Opcode.MAXARG_sBx then
        fail(state, node or { line = line }, "control structure exceeds Lua 5.1 jump range")
    end
    return emit(state, Opcode.EncodeAsBx(op, a, sbx), line)
end

local function emit_jump(state, line)
    return emit_asbx(state, Op.JMP, 0, 0, line)
end

local function patch_jump(state, jump_pc, target_pc)
    local decoded = Opcode.Decode(state.proto.code[jump_pc + 1])
    local offset = target_pc - jump_pc - 1
    if offset < -Opcode.MAXARG_sBx or offset > Opcode.MAXARG_sBx then
        error("control structure exceeds Lua 5.1 jump range", 0)
    end
    state.proto.code[jump_pc + 1] = Opcode.EncodeAsBx(decoded.op, decoded.a, offset)
end

local function update_max_register(state)
    if state.free_register > state.max_register then
        state.max_register = state.free_register
    end
    if state.max_register > Opcode.MAXSTACK then
        error(string.format("%s: function requires more than %d registers", state.proto.source, Opcode.MAXSTACK), 0)
    end
end

local function ensure_registers(state, count)
    if count > state.free_register then
        state.free_register = count
        update_max_register(state)
    end
end

local function reserve(state, count)
    local base = state.free_register
    state.free_register = state.free_register + count
    update_max_register(state)
    return base
end

local function set_free(state, value)
    if value < state.local_top then
        value = state.local_top
    end
    state.free_register = value
end

local function add_constant(state, value)
    local value_type = type(value)
    local map = state.constant_maps[value_type]
    local index = map[value]

    if index ~= nil then
        return index
    end

    index = #state.proto.constants
    if index > Opcode.MAXARG_Bx then
        error(state.proto.source .. ": too many constants in function", 0)
    end

    state.proto.constants[index + 1] = value
    map[value] = index
    return index
end

local function push_scope(state)
    local scope = {
        base = state.local_top,
        symbols = {},
    }
    state.scopes[#state.scopes + 1] = scope
    return scope
end

local function scope_close_register(state, scope)
    local minimum
    for index = 1, #scope.symbols do
        local symbol = scope.symbols[index]
        if symbol.captured then
            local register = state.symbol_registers[symbol.id]
            if register and (not minimum or register < minimum) then
                minimum = register
            end
        end
    end
    return minimum
end

local function emit_scope_close(state, scope, line)
    local register = scope_close_register(state, scope)
    if register then
        emit_abc(state, Op.CLOSE, register, 0, 0, line or 0)
    end
end

local function declare_symbol(state, symbol, start_pc)
    if state.local_top >= Opcode.MAXVARS then
        fail(state, symbol.declaration, "too many local variables in function")
    end

    local register = state.local_top
    state.local_top = state.local_top + 1
    ensure_registers(state, state.local_top)
    state.symbol_registers[symbol.id] = register

    local scope = state.scopes[#state.scopes]
    scope.symbols[#scope.symbols + 1] = symbol

    local debug = {
        name = symbol.name,
        start_pc = start_pc or pc(state),
        end_pc = 0,
    }
    state.proto.locals[#state.proto.locals + 1] = debug
    state.symbol_debug[symbol.id] = debug

    return register
end

local function reserve_hidden_locals(state, count, node)
    if state.local_top + count > Opcode.MAXVARS then
        fail(state, node, "too many local variables in function")
    end

    local base = state.local_top
    state.local_top = state.local_top + count
    ensure_registers(state, state.local_top)
    return base
end

local function pop_scope(state, should_close, line)
    local scope = state.scopes[#state.scopes]
    if should_close ~= false then
        emit_scope_close(state, scope, line)
    end

    local end_pc = pc(state)
    for index = 1, #scope.symbols do
        local symbol = scope.symbols[index]
        local debug = state.symbol_debug[symbol.id]
        if debug then
            debug.end_pc = end_pc
        end
        state.symbol_registers[symbol.id] = nil
        state.symbol_debug[symbol.id] = nil
    end

    state.scopes[#state.scopes] = nil
    state.local_top = scope.base
    set_free(state, state.local_top)
    return scope
end

local function set_symbol_start(state, symbol, start_pc)
    local debug = state.symbol_debug[symbol.id]
    if debug then
        debug.start_pc = start_pc
    end
end

local function register_for_symbol(state, symbol, node)
    local register = state.symbol_registers[symbol.id]
    if register == nil then
        fail(state, node, "local '" .. symbol.name .. "' is not active")
    end
    return register
end

local compile_expression
local compile_statement
local generate_function

local function emit_load_nil(state, first, count, line, node)
    if count <= 0 then
        return
    end
    local last = first + count - 1
    emit_abc(state, Op.LOADNIL, first, last, 0, line, node)
end

local function compile_identifier(state, node, target)
    local binding = node.binding

    if binding.kind == "local" then
        local source = register_for_symbol(state, binding.symbol, node)
        if source ~= target then
            emit_abc(state, Op.MOVE, target, source, 0, node.line, node)
        end
    elseif binding.kind == "upvalue" then
        emit_abc(state, Op.GETUPVAL, target, binding.index, 0, node.line, node)
    else
        local index = add_constant(state, binding.name)
        emit_abx(state, Op.GETGLOBAL, target, index, node.line, node)
    end
end

local function literal_constant(node)
    if node.kind == "NumberLiteral" or node.kind == "StringLiteral" or node.kind == "BooleanLiteral" then
        return true, node.value
    end
    return false, nil
end

local function compile_operand(state, node, freeze)
    local is_constant, value = literal_constant(node)
    if is_constant then
        local index = add_constant(state, value)
        if index <= Opcode.MAXINDEXRK then
            return Opcode.RK(index)
        end
    end

    if not freeze and node.kind == "Identifier" and node.binding.kind == "local" then
        return register_for_symbol(state, node.binding.symbol, node)
    end

    local target = reserve(state, 1)
    compile_expression(state, node, target, 1)
    return target
end

local function compile_comparison(state, node, target)
    local mark = state.free_register
    local operator = node.operator
    local op
    local accepted = 1
    local reverse = false

    if operator == "==" then
        op = Op.EQ
    elseif operator == "~=" then
        op = Op.EQ
        accepted = 0
    elseif operator == "<" then
        op = Op.LT
    elseif operator == ">" then
        op = Op.LT
        reverse = true
    elseif operator == "<=" then
        op = Op.LE
    elseif operator == ">=" then
        op = Op.LE
        reverse = true
    end

    local left = compile_operand(state, node.left, true)
    local right = compile_operand(state, node.right, false)
    if reverse then
        left, right = right, left
    end

    emit_abc(state, op, accepted, left, right, node.line, node)
    local jump_true = emit_jump(state, node.line)
    emit_abc(state, Op.LOADBOOL, target, 0, 1, node.line, node)
    local true_pc = pc(state)
    emit_abc(state, Op.LOADBOOL, target, 1, 0, node.line, node)
    patch_jump(state, jump_true, true_pc)
    set_free(state, mark)
end

local function compile_logical(state, node, target)
    compile_expression(state, node.left, target, 1)

    local condition = node.operator == "and" and 0 or 1
    emit_abc(state, Op.TEST, target, 0, condition, node.line, node)
    local jump_end = emit_jump(state, node.line)
    compile_expression(state, node.right, target, 1)
    patch_jump(state, jump_end, pc(state))
end

local function collect_concat(node, expressions)
    if node.kind == "BinaryExpression" and node.operator == ".." then
        collect_concat(node.left, expressions)
        collect_concat(node.right, expressions)
    else
        expressions[#expressions + 1] = node
    end
end

local function compile_binary(state, node, target)
    local operator = node.operator

    if operator == "and" or operator == "or" then
        compile_logical(state, node, target)
        return
    end

    if operator == "==" or operator == "~=" or operator == "<" or operator == ">"
        or operator == "<=" or operator == ">="
    then
        compile_comparison(state, node, target)
        return
    end

    if operator == ".." then
        local mark = state.free_register
        local expressions = {}
        collect_concat(node, expressions)
        local base = reserve(state, #expressions)

        for index = 1, #expressions do
            compile_expression(state, expressions[index], base + index - 1, 1)
        end

        emit_abc(state, Op.CONCAT, target, base, base + #expressions - 1, node.line, node)
        set_free(state, mark)
        return
    end

    local mark = state.free_register
    local left = compile_operand(state, node.left, true)
    local right = compile_operand(state, node.right, false)
    emit_abc(state, ARITHMETIC[operator], target, left, right, node.line, node)
    set_free(state, mark)
end

local function compile_index(state, node, target)
    local mark = state.free_register
    local object = reserve(state, 1)
    compile_expression(state, node.object, object, 1)

    local key
    if node.kind == "MemberExpression" then
        local index = add_constant(state, node.name)
        if index <= Opcode.MAXINDEXRK then
            key = Opcode.RK(index)
        else
            key = reserve(state, 1)
            emit_abx(state, Op.LOADK, key, index, node.line, node)
        end
    else
        key = compile_operand(state, node.key, false)
    end

    emit_abc(state, Op.GETTABLE, target, object, key, node.line, node)
    set_free(state, mark)
end

local function compile_call(state, node, target, wanted, call_opcode)
    call_opcode = call_opcode or Op.CALL
    local outer_mark = state.free_register
    local use_target = target >= state.local_top
    local call_base

    if use_target then
        call_base = target
        ensure_registers(state, call_base + 1)
    else
        if wanted < 0 then
            fail(state, node, "open call result cannot target an active local")
        end
        call_base = reserve(state, 1)
    end

    local argument_count = 0
    local argument_base

    if node.kind == "MethodCallExpression" then
        ensure_registers(state, call_base + 2)
        compile_expression(state, node.object, call_base + 1, 1)

        local key_index = add_constant(state, node.method)
        local key
        if key_index <= Opcode.MAXINDEXRK then
            key = Opcode.RK(key_index)
        else
            key = reserve(state, 1)
            emit_abx(state, Op.LOADK, key, key_index, node.line, node)
        end

        emit_abc(state, Op.SELF, call_base, call_base + 1, key, node.line, node)
        argument_count = 1
        argument_base = call_base + 2
    else
        compile_expression(state, node.callee, call_base, 1)
        argument_base = call_base + 1
    end

    local arguments = node.arguments
    local open_arguments = false

    for index = 1, #arguments do
        local argument_target = argument_base + index - 1
        ensure_registers(state, argument_target + 1)

        if index == #arguments and Ast.IsMultiResult(arguments[index]) then
            compile_expression(state, arguments[index], argument_target, -1)
            open_arguments = true
        else
            compile_expression(state, arguments[index], argument_target, 1)
            argument_count = argument_count + 1
        end
    end

    if wanted > 0 then
        ensure_registers(state, call_base + wanted)
    end

    local b = open_arguments and 0 or (argument_count + 1)
    local c = call_opcode == Op.TAILCALL and 0 or (wanted < 0 and 0 or (wanted + 1))
    emit_abc(state, call_opcode, call_base, b, c, node.line, node)

    if not use_target and wanted > 0 then
        for index = 0, wanted - 1 do
            emit_abc(state, Op.MOVE, target + index, call_base + index, 0, node.line, node)
        end
    end

    set_free(state, outer_mark)
end

local function emit_setlist(state, table_register, count, block, line, node)
    if block <= Opcode.MAXARG_C then
        emit_abc(state, Op.SETLIST, table_register, count, block, line, node)
    else
        emit_abc(state, Op.SETLIST, table_register, count, 0, line, node)
        emit(state, block, line)
    end
end

local function compile_table(state, node, target)
    local outer_mark = state.free_register
    local use_target = target >= state.local_top
    local table_register

    if use_target then
        table_register = target
        ensure_registers(state, table_register + 1)
    else
        table_register = reserve(state, 1)
    end

    local array_count = 0
    local record_count = 0
    for index = 1, #node.fields do
        if node.fields[index].kind == "ArrayField" then
            array_count = array_count + 1
        else
            record_count = record_count + 1
        end
    end

    emit_abc(
        state,
        Op.NEWTABLE,
        table_register,
        Opcode.IntToFloatingByte(array_count),
        Opcode.IntToFloatingByte(record_count),
        node.line,
        node
    )

    local pending = 0
    local total_array = 0

    for index = 1, #node.fields do
        local field = node.fields[index]

        if field.kind == "ArrayField" then
            total_array = total_array + 1
            local value_register = table_register + pending + 1
            ensure_registers(state, value_register + 1)

            local is_last = index == #node.fields
            if is_last and Ast.IsMultiResult(field.value) then
                compile_expression(state, field.value, value_register, -1)
                local block = floor((total_array - 1) / Opcode.LFIELDS_PER_FLUSH) + 1
                emit_setlist(state, table_register, 0, block, field.line, field)
                pending = 0
            else
                compile_expression(state, field.value, value_register, 1)
                pending = pending + 1

                if pending == Opcode.LFIELDS_PER_FLUSH then
                    local block = floor((total_array - 1) / Opcode.LFIELDS_PER_FLUSH) + 1
                    emit_setlist(state, table_register, pending, block, field.line, field)
                    pending = 0
                end
            end
        else
            local mark = state.free_register
            local key

            if field.kind == "RecordField" then
                local index_value = add_constant(state, field.key)
                if index_value <= Opcode.MAXINDEXRK then
                    key = Opcode.RK(index_value)
                else
                    key = reserve(state, 1)
                    emit_abx(state, Op.LOADK, key, index_value, field.line, field)
                end
            else
                key = compile_operand(state, field.key, true)
            end

            local value = compile_operand(state, field.value, false)
            emit_abc(state, Op.SETTABLE, table_register, key, value, field.line, field)
            set_free(state, mark)
        end
    end

    if pending > 0 then
        local block = floor((total_array - 1) / Opcode.LFIELDS_PER_FLUSH) + 1
        emit_setlist(state, table_register, pending, block, node.end_line, node)
    end

    if not use_target then
        emit_abc(state, Op.MOVE, target, table_register, 0, node.line, node)
    end

    set_free(state, outer_mark)
end

local function compile_function_expression(state, node, target)
    local child = generate_function(node, node.function_scope, state)
    local index = #state.proto.protos
    state.proto.protos[index + 1] = child

    emit_abx(state, Op.CLOSURE, target, index, node.line, node)

    for upvalue_index = 1, #node.function_scope.upvalues do
        local descriptor = node.function_scope.upvalues[upvalue_index]
        if descriptor.kind == "local" then
            local register = register_for_symbol(state, descriptor.symbol, node)
            emit_abc(state, Op.MOVE, 0, register, 0, node.line, node)
        else
            emit_abc(state, Op.GETUPVAL, 0, descriptor.parent_index, 0, node.line, node)
        end
    end
end

compile_expression = function(state, node, target, wanted)
    wanted = wanted or 1
    if wanted > 0 then
        ensure_registers(state, target + wanted)
    else
        ensure_registers(state, target + 1)
    end

    local kind = node.kind

    if kind == "NilLiteral" then
        emit_load_nil(state, target, 1, node.line, node)
    elseif kind == "BooleanLiteral" then
        emit_abc(state, Op.LOADBOOL, target, node.value and 1 or 0, 0, node.line, node)
    elseif kind == "NumberLiteral" or kind == "StringLiteral" then
        emit_abx(state, Op.LOADK, target, add_constant(state, node.value), node.line, node)
    elseif kind == "Identifier" then
        compile_identifier(state, node, target)
    elseif kind == "ParenthesizedExpression" then
        compile_expression(state, node.expression, target, 1)
    elseif kind == "IndexExpression" or kind == "MemberExpression" then
        compile_index(state, node, target)
    elseif kind == "UnaryExpression" then
        local mark = state.free_register
        local source = reserve(state, 1)
        compile_expression(state, node.argument, source, 1)
        emit_abc(state, UNARY[node.operator], target, source, 0, node.line, node)
        set_free(state, mark)
    elseif kind == "BinaryExpression" then
        compile_binary(state, node, target)
    elseif kind == "CallExpression" or kind == "MethodCallExpression" then
        compile_call(state, node, target, wanted)
    elseif kind == "FunctionExpression" then
        compile_function_expression(state, node, target)
    elseif kind == "TableExpression" then
        compile_table(state, node, target)
    elseif kind == "VarargExpression" then
        local b = wanted < 0 and 0 or (wanted + 1)
        emit_abc(state, Op.VARARG, target, b, 0, node.line, node)
    else
        fail(state, node, "unsupported expression node '" .. tostring(kind) .. "'")
    end
end

local function compile_expression_list(state, expressions, wanted)
    local base = state.free_register
    local count = #expressions
    local slots = count
    if wanted > slots then
        slots = wanted
    end
    if slots > 0 then
        reserve(state, slots)
    end

    if count == 0 then
        emit_load_nil(state, base, wanted, 0)
        return base
    end

    for index = 1, count - 1 do
        compile_expression(state, expressions[index], base + index - 1, 1)
    end

    local last = expressions[count]
    local remaining = wanted - count + 1

    if remaining > 0 then
        if Ast.IsMultiResult(last) then
            compile_expression(state, last, base + count - 1, remaining)
        else
            compile_expression(state, last, base + count - 1, 1)
            emit_load_nil(state, base + count, remaining - 1, last.line, last)
        end
    elseif Ast.IsMultiResult(last) then
        compile_expression(state, last, base + count - 1, 0)
    else
        compile_expression(state, last, base + count - 1, 1)
    end

    return base
end

local function compile_open_expression_list(state, expressions)
    local base = state.free_register
    local count = #expressions
    if count == 0 then
        return base, 0, false
    end

    reserve(state, count)
    for index = 1, count - 1 do
        compile_expression(state, expressions[index], base + index - 1, 1)
    end

    local last = expressions[count]
    local open = Ast.IsMultiResult(last)
    compile_expression(state, last, base + count - 1, open and -1 or 1)
    return base, count, open
end

local function prepare_target(state, node)
    if node.kind == "Identifier" then
        local binding = node.binding
        if binding.kind == "local" then
            return {
                kind = "local",
                register = register_for_symbol(state, binding.symbol, node),
                node = node,
            }
        elseif binding.kind == "upvalue" then
            return {
                kind = "upvalue",
                index = binding.index,
                node = node,
            }
        else
            return {
                kind = "global",
                index = add_constant(state, binding.name),
                node = node,
            }
        end
    end

    local object = reserve(state, 1)
    compile_expression(state, node.object, object, 1)

    local key
    if node.kind == "MemberExpression" then
        local index = add_constant(state, node.name)
        if index <= Opcode.MAXINDEXRK then
            key = Opcode.RK(index)
        else
            key = reserve(state, 1)
            emit_abx(state, Op.LOADK, key, index, node.line, node)
        end
    else
        key = compile_operand(state, node.key, true)
    end

    return {
        kind = "index",
        object = object,
        key = key,
        node = node,
    }
end

local function write_target(state, target, value_register)
    local node = target.node
    if target.kind == "local" then
        if target.register ~= value_register then
            emit_abc(state, Op.MOVE, target.register, value_register, 0, node.line, node)
        end
    elseif target.kind == "upvalue" then
        emit_abc(state, Op.SETUPVAL, value_register, target.index, 0, node.line, node)
    elseif target.kind == "global" then
        emit_abx(state, Op.SETGLOBAL, value_register, target.index, node.line, node)
    else
        emit_abc(state, Op.SETTABLE, target.object, target.key, value_register, node.line, node)
    end
end

local function compile_assignment(state, node)
    local mark = state.free_register
    local targets = {}

    for index = 1, #node.targets do
        targets[index] = prepare_target(state, node.targets[index])
    end

    local values = compile_expression_list(state, node.values, #targets)
    for index = 1, #targets do
        write_target(state, targets[index], values + index - 1)
    end

    set_free(state, mark)
end

local function compile_local(state, node)
    local start_pc = pc(state)
    local values

    if state.local_top + #node.symbols > Opcode.MAXVARS then
        fail(state, node.names[#node.names], "too many local variables in function")
    end

    if #node.values > 0 then
        values = compile_expression_list(state, node.values, #node.symbols)
    end

    local first_register
    for index = 1, #node.symbols do
        local register = declare_symbol(state, node.symbols[index], start_pc)
        first_register = first_register or register
    end

    if #node.values == 0 then
        emit_load_nil(state, first_register, #node.symbols, node.line, node)
    elseif first_register ~= values then
        for index = 0, #node.symbols - 1 do
            emit_abc(state, Op.MOVE, first_register + index, values + index, 0, node.line, node)
        end
    end

    local active_pc = pc(state)
    for index = 1, #node.symbols do
        set_symbol_start(state, node.symbols[index], active_pc)
    end
    set_free(state, state.local_top)
end

local function compile_local_function(state, node)
    local register = declare_symbol(state, node.symbol, pc(state))
    compile_function_expression(state, node.value, register)
    set_symbol_start(state, node.symbol, pc(state))
    set_free(state, state.local_top)
end

local function compile_function_statement(state, node)
    local mark = state.free_register
    local target = prepare_target(state, node.target)
    local value = reserve(state, 1)
    compile_function_expression(state, node.value, value)
    write_target(state, target, value)
    set_free(state, mark)
end

local function compile_scoped_block(state, block)
    push_scope(state)
    for index = 1, #block.statements do
        compile_statement(state, block.statements[index])
        set_free(state, state.local_top)
    end
    pop_scope(state, true, block.end_line)
end

local function emit_test_jump_false(state, register, line, node)
    emit_abc(state, Op.TEST, register, 0, 0, line, node)
    return emit_jump(state, line)
end

local function compile_if(state, node)
    local end_jumps = {}

    for index = 1, #node.clauses do
        local clause = node.clauses[index]
        local mark = state.free_register
        local condition = reserve(state, 1)
        compile_expression(state, clause.condition, condition, 1)
        local false_jump = emit_test_jump_false(state, condition, clause.condition.line, clause.condition)
        set_free(state, mark)

        compile_scoped_block(state, clause.body)

        if index < #node.clauses or node.else_body then
            end_jumps[#end_jumps + 1] = emit_jump(state, clause.body.end_line)
        end
        patch_jump(state, false_jump, pc(state))
    end

    if node.else_body then
        compile_scoped_block(state, node.else_body)
    end

    local finish = pc(state)
    for index = 1, #end_jumps do
        patch_jump(state, end_jumps[index], finish)
    end
end

local function push_loop(state)
    local loop = {
        breaks = {},
        scope_depth = #state.scopes,
    }
    state.loops[#state.loops + 1] = loop
    return loop
end

local function pop_loop(state)
    local loop = state.loops[#state.loops]
    state.loops[#state.loops] = nil
    return loop
end

local function emit_break_close(state, loop, line)
    local minimum
    for scope_index = loop.scope_depth, #state.scopes do
        local register = scope_close_register(state, state.scopes[scope_index])
        if register and (not minimum or register < minimum) then
            minimum = register
        end
    end

    if minimum then
        emit_abc(state, Op.CLOSE, minimum, 0, 0, line)
    end
end

local function patch_breaks(state, loop, target)
    for index = 1, #loop.breaks do
        patch_jump(state, loop.breaks[index], target)
    end
end

local function compile_while(state, node)
    local start_pc = pc(state)
    local mark = state.free_register
    local condition = reserve(state, 1)
    compile_expression(state, node.condition, condition, 1)
    local exit_jump = emit_test_jump_false(state, condition, node.condition.line, node.condition)
    set_free(state, mark)

    push_scope(state)
    local loop = push_loop(state)
    for index = 1, #node.body.statements do
        compile_statement(state, node.body.statements[index])
        set_free(state, state.local_top)
    end
    pop_scope(state, true, node.body.end_line)

    local back = emit_jump(state, node.end_line)
    patch_jump(state, back, start_pc)

    local finish = pc(state)
    patch_jump(state, exit_jump, finish)
    pop_loop(state)
    patch_breaks(state, loop, finish)
end

local function compile_repeat(state, node)
    local start_pc = pc(state)
    local scope = push_scope(state)
    local loop = push_loop(state)

    for index = 1, #node.body.statements do
        compile_statement(state, node.body.statements[index])
        set_free(state, state.local_top)
    end

    local mark = state.free_register
    local condition = reserve(state, 1)
    compile_expression(state, node.condition, condition, 1)
    local false_jump = emit_test_jump_false(state, condition, node.condition.line, node.condition)
    set_free(state, mark)

    emit_scope_close(state, scope, node.end_line)
    local exit_jump = emit_jump(state, node.end_line)

    local false_pc = pc(state)
    patch_jump(state, false_jump, false_pc)
    emit_scope_close(state, scope, node.end_line)
    local back = emit_jump(state, node.end_line)
    patch_jump(state, back, start_pc)

    local finish = pc(state)
    patch_jump(state, exit_jump, finish)
    pop_loop(state)
    patch_breaks(state, loop, finish)
    pop_scope(state, false, node.end_line)
end

local function compile_numeric_for(state, node)
    local scope = push_scope(state)
    local base = reserve_hidden_locals(state, 3, node)
    local variable_register = declare_symbol(state, node.symbol, pc(state))

    compile_expression(state, node.initial, base, 1)
    compile_expression(state, node.limit, base + 1, 1)
    if node.step then
        compile_expression(state, node.step, base + 2, 1)
    else
        emit_abx(state, Op.LOADK, base + 2, add_constant(state, 1), node.line, node)
    end
    set_free(state, state.local_top)

    local prepare = emit_asbx(state, Op.FORPREP, base, 0, node.line, node)
    local body_start = pc(state)
    set_symbol_start(state, node.symbol, body_start)

    local loop = push_loop(state)
    for index = 1, #node.body.statements do
        compile_statement(state, node.body.statements[index])
        set_free(state, state.local_top)
    end

    emit_scope_close(state, scope, node.end_line)
    local for_loop = emit_asbx(state, Op.FORLOOP, base, 0, node.end_line, node)
    patch_jump(state, prepare, for_loop)
    patch_jump(state, for_loop, body_start)

    local finish = pc(state)
    pop_loop(state)
    patch_breaks(state, loop, finish)
    pop_scope(state, false, node.end_line)

    if variable_register ~= base + 3 then
        error("internal numeric for register allocation error", 0)
    end
end

local function compile_generic_for(state, node)
    local scope = push_scope(state)
    local values = compile_expression_list(state, node.values, 3)
    local base = reserve_hidden_locals(state, 3, node)

    for index = 1, #node.symbols do
        declare_symbol(state, node.symbols[index], pc(state))
    end

    if base ~= values then
        for index = 0, 2 do
            emit_abc(state, Op.MOVE, base + index, values + index, 0, node.line, node)
        end
    end
    set_free(state, state.local_top)

    local initial_jump = emit_jump(state, node.line)
    local body_start = pc(state)
    for index = 1, #node.symbols do
        set_symbol_start(state, node.symbols[index], body_start)
    end

    local loop = push_loop(state)
    for index = 1, #node.body.statements do
        compile_statement(state, node.body.statements[index])
        set_free(state, state.local_top)
    end

    emit_scope_close(state, scope, node.end_line)
    local iterator_pc = pc(state)
    emit_abc(state, Op.TFORLOOP, base, 0, #node.symbols, node.end_line, node)
    local back = emit_jump(state, node.end_line)
    patch_jump(state, back, body_start)
    patch_jump(state, initial_jump, iterator_pc)

    local finish = pc(state)
    pop_loop(state)
    patch_breaks(state, loop, finish)
    pop_scope(state, false, node.end_line)
end

local function compile_return(state, node)
    if #node.values == 0 then
        emit_abc(state, Op.RETURN, 0, 1, 0, node.line, node)
        return
    end

    local mark = state.free_register
    local value = node.values[1]

    if #node.values == 1 and Ast.IsCall(value) then
        local base = state.free_register
        compile_call(state, value, base, -1, Op.TAILCALL)
        emit_abc(state, Op.RETURN, base, 0, 0, node.line, node)
    else
        local base, count, open = compile_open_expression_list(state, node.values)
        emit_abc(state, Op.RETURN, base, open and 0 or (count + 1), 0, node.line, node)
    end

    set_free(state, mark)
end

compile_statement = function(state, node)
    local kind = node.kind

    if kind == "LocalStatement" then
        compile_local(state, node)
    elseif kind == "LocalFunctionStatement" then
        compile_local_function(state, node)
    elseif kind == "AssignmentStatement" then
        compile_assignment(state, node)
    elseif kind == "FunctionStatement" then
        compile_function_statement(state, node)
    elseif kind == "CallStatement" then
        local mark = state.free_register
        compile_call(state, node.expression, state.free_register, 0)
        set_free(state, mark)
    elseif kind == "DoStatement" then
        compile_scoped_block(state, node.body)
    elseif kind == "WhileStatement" then
        compile_while(state, node)
    elseif kind == "RepeatStatement" then
        compile_repeat(state, node)
    elseif kind == "IfStatement" then
        compile_if(state, node)
    elseif kind == "NumericForStatement" then
        compile_numeric_for(state, node)
    elseif kind == "GenericForStatement" then
        compile_generic_for(state, node)
    elseif kind == "ReturnStatement" then
        compile_return(state, node)
    elseif kind == "BreakStatement" then
        local loop = state.loops[#state.loops]
        if not loop then
            fail(state, node, "break outside loop")
        end
        emit_break_close(state, loop, node.line)
        loop.breaks[#loop.breaks + 1] = emit_jump(state, node.line)
    else
        fail(state, node, "unsupported statement node '" .. tostring(kind) .. "'")
    end
end

local function create_state(node, function_scope, parent_state)
    local source = parent_state and parent_state.proto.source or node.source
    local is_main = node.kind == "Chunk"

    if #function_scope.upvalues > Opcode.MAXUPVALUES then
        error(string.format("%s:%d:%d: too many upvalues in function", source, node.line or 0, node.column or 0), 0)
    end

    local proto = {
        source = source,
        line_defined = is_main and 0 or node.line,
        last_line_defined = is_main and 0 or node.end_line,
        nups = #function_scope.upvalues,
        num_params = #function_scope.parameters,
        is_vararg = function_scope.is_vararg and 2 or 0,
        max_stack_size = 2,
        code = {},
        constants = {},
        protos = {},
        line_info = {},
        locals = {},
        upvalue_names = {},
    }

    for index = 1, #function_scope.upvalues do
        proto.upvalue_names[index] = function_scope.upvalues[index].name
    end

    return {
        proto = proto,
        constant_maps = {
            string = {},
            number = {},
            boolean = {},
        },
        symbol_registers = {},
        symbol_debug = {},
        scopes = {},
        loops = {},
        local_top = 0,
        free_register = 0,
        max_register = 0,
    }
end

generate_function = function(node, function_scope, parent_state)
    local state = create_state(node, function_scope, parent_state)
    push_scope(state)

    for index = 1, #function_scope.parameters do
        declare_symbol(state, function_scope.parameters[index], 0)
    end

    local body = node.body
    for index = 1, #body.statements do
        compile_statement(state, body.statements[index])
        set_free(state, state.local_top)
    end

    local last_statement = body.statements[#body.statements]
    if not last_statement or last_statement.kind ~= "ReturnStatement" then
        emit_abc(state, Op.RETURN, 0, 1, 0, node.end_line or 0, node)
    end

    pop_scope(state, false, node.end_line)
    state.proto.max_stack_size = math.max(2, state.max_register)
    return state.proto
end

function Generator.Generate(chunk)
    if type(chunk) ~= "table" or chunk.kind ~= "Chunk" then
        error("chunk must be a resolved Chunk node", 2)
    end
    if not chunk.function_scope then
        error("chunk must be resolved before code generation", 2)
    end

    return generate_function(chunk, chunk.function_scope, nil)
end

return Generator
