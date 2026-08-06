local Opcode = require("lua51c.Opcode")

local Disassembler = {}

local Op = Opcode.Op
local concat = table.concat
local format = string.format
local type = type

local function constant_text(value)
    if type(value) == "string" then
        return format("%q", value)
    end
    return tostring(value)
end

local function constant(proto, index)
    local value = proto.constants[index + 1]
    return format("K%d(%s)", index, constant_text(value))
end

local function rk(proto, operand)
    if Opcode.IsConstant(operand) then
        return constant(proto, Opcode.ConstantIndex(operand))
    end
    return "R" .. operand
end

local function operands(proto, decoded, current_pc)
    local op = decoded.op
    local a = decoded.a
    local b = decoded.b
    local c = decoded.c

    if op == Op.MOVE then
        return format("R%d R%d", a, b)
    elseif op == Op.LOADK then
        return format("R%d %s", a, constant(proto, decoded.bx))
    elseif op == Op.LOADBOOL then
        return format("R%d %s %d", a, b ~= 0 and "true" or "false", c)
    elseif op == Op.LOADNIL then
        return format("R%d R%d", a, b)
    elseif op == Op.GETUPVAL then
        return format("R%d U%d", a, b)
    elseif op == Op.GETGLOBAL then
        return format("R%d %s", a, constant(proto, decoded.bx))
    elseif op == Op.GETTABLE then
        return format("R%d R%d %s", a, b, rk(proto, c))
    elseif op == Op.SETGLOBAL then
        return format("R%d %s", a, constant(proto, decoded.bx))
    elseif op == Op.SETUPVAL then
        return format("R%d U%d", a, b)
    elseif op == Op.SETTABLE then
        return format("R%d %s %s", a, rk(proto, b), rk(proto, c))
    elseif op == Op.NEWTABLE then
        return format("R%d %d %d", a, Opcode.FloatingByteToInt(b), Opcode.FloatingByteToInt(c))
    elseif op == Op.SELF then
        return format("R%d R%d %s", a, b, rk(proto, c))
    elseif op >= Op.ADD and op <= Op.POW then
        return format("R%d %s %s", a, rk(proto, b), rk(proto, c))
    elseif op >= Op.UNM and op <= Op.LEN then
        return format("R%d R%d", a, b)
    elseif op == Op.CONCAT then
        return format("R%d R%d R%d", a, b, c)
    elseif op == Op.JMP then
        return format("%+d -> %d", decoded.sbx, current_pc + 1 + decoded.sbx)
    elseif op >= Op.EQ and op <= Op.LE then
        return format("%d %s %s", a, rk(proto, b), rk(proto, c))
    elseif op == Op.TEST then
        return format("R%d %d", a, c)
    elseif op == Op.TESTSET then
        return format("R%d R%d %d", a, b, c)
    elseif op == Op.CALL or op == Op.TAILCALL then
        return format("R%d %d %d", a, b, c)
    elseif op == Op.RETURN then
        return format("R%d %d", a, b)
    elseif op == Op.FORLOOP or op == Op.FORPREP then
        return format("R%d %+d -> %d", a, decoded.sbx, current_pc + 1 + decoded.sbx)
    elseif op == Op.TFORLOOP then
        return format("R%d %d", a, c)
    elseif op == Op.SETLIST then
        return format("R%d %d %d", a, b, c)
    elseif op == Op.CLOSE then
        return "R" .. a
    elseif op == Op.CLOSURE then
        return format("R%d P%d", a, decoded.bx)
    elseif op == Op.VARARG then
        return format("R%d %d", a, b)
    end

    return format("%d %d %d", a, b, c)
end

function Disassembler.Decode(proto)
    if type(proto) ~= "table" or type(proto.code) ~= "table" then
        error("prototype must be a generated Lua 5.1 prototype", 2)
    end

    local instructions = {}
    local index = 1

    while index <= #proto.code do
        local current_pc = index - 1
        local word = proto.code[index]
        local decoded = Opcode.Decode(word)
        local instruction = {
            pc = current_pc,
            line = proto.line_info[index] or 0,
            word = word,
            op = decoded.op,
            name = Opcode.Name[decoded.op + 1] or "UNKNOWN",
            a = decoded.a,
            b = decoded.b,
            c = decoded.c,
            bx = decoded.bx,
            sbx = decoded.sbx,
            operands = operands(proto, decoded, current_pc),
        }
        instructions[#instructions + 1] = instruction

        if decoded.op == Op.SETLIST and decoded.c == 0 and index < #proto.code then
            index = index + 1
            instructions[#instructions + 1] = {
                pc = index - 1,
                line = proto.line_info[index] or 0,
                word = proto.code[index],
                op = nil,
                name = "EXTRAARG",
                operands = tostring(proto.code[index]),
            }
        end

        index = index + 1
    end

    return instructions
end

local function append_proto(lines, proto, depth, index)
    local indent = string.rep("  ", depth)
    local label = depth == 0 and "main" or "function P" .. index

    lines[#lines + 1] = format(
        "%s%s <%s:%d,%d> (%d instructions, %d constants, %d functions)",
        indent,
        label,
        proto.source or "=?",
        proto.line_defined or 0,
        proto.last_line_defined or 0,
        #proto.code,
        #proto.constants,
        #proto.protos
    )
    lines[#lines + 1] = format(
        "%s  params=%d vararg=%d stack=%d upvalues=%d",
        indent,
        proto.num_params or 0,
        proto.is_vararg or 0,
        proto.max_stack_size or 0,
        proto.nups or 0
    )

    local instructions = Disassembler.Decode(proto)
    for instruction_index = 1, #instructions do
        local instruction = instructions[instruction_index]
        lines[#lines + 1] = format(
            "%s  %04d  [%d]  %-10s %s",
            indent,
            instruction.pc,
            instruction.line,
            instruction.name,
            instruction.operands
        )
    end

    for child_index = 1, #proto.protos do
        lines[#lines + 1] = ""
        append_proto(lines, proto.protos[child_index], depth + 1, child_index - 1)
    end
end

function Disassembler.Format(proto)
    local lines = {}
    append_proto(lines, proto, 0, 0)
    return concat(lines, "\n")
end

return Disassembler
