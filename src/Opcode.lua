local Opcode = {}

local floor = math.floor

Opcode.Op = {
    MOVE = 0,
    LOADK = 1,
    LOADBOOL = 2,
    LOADNIL = 3,
    GETUPVAL = 4,
    GETGLOBAL = 5,
    GETTABLE = 6,
    SETGLOBAL = 7,
    SETUPVAL = 8,
    SETTABLE = 9,
    NEWTABLE = 10,
    SELF = 11,
    ADD = 12,
    SUB = 13,
    MUL = 14,
    DIV = 15,
    MOD = 16,
    POW = 17,
    UNM = 18,
    NOT = 19,
    LEN = 20,
    CONCAT = 21,
    JMP = 22,
    EQ = 23,
    LT = 24,
    LE = 25,
    TEST = 26,
    TESTSET = 27,
    CALL = 28,
    TAILCALL = 29,
    RETURN = 30,
    FORLOOP = 31,
    FORPREP = 32,
    TFORLOOP = 33,
    SETLIST = 34,
    CLOSE = 35,
    CLOSURE = 36,
    VARARG = 37,
}

Opcode.Name = {
    [1] = "MOVE",
    [2] = "LOADK",
    [3] = "LOADBOOL",
    [4] = "LOADNIL",
    [5] = "GETUPVAL",
    [6] = "GETGLOBAL",
    [7] = "GETTABLE",
    [8] = "SETGLOBAL",
    [9] = "SETUPVAL",
    [10] = "SETTABLE",
    [11] = "NEWTABLE",
    [12] = "SELF",
    [13] = "ADD",
    [14] = "SUB",
    [15] = "MUL",
    [16] = "DIV",
    [17] = "MOD",
    [18] = "POW",
    [19] = "UNM",
    [20] = "NOT",
    [21] = "LEN",
    [22] = "CONCAT",
    [23] = "JMP",
    [24] = "EQ",
    [25] = "LT",
    [26] = "LE",
    [27] = "TEST",
    [28] = "TESTSET",
    [29] = "CALL",
    [30] = "TAILCALL",
    [31] = "RETURN",
    [32] = "FORLOOP",
    [33] = "FORPREP",
    [34] = "TFORLOOP",
    [35] = "SETLIST",
    [36] = "CLOSE",
    [37] = "CLOSURE",
    [38] = "VARARG",
}

Opcode.Mode = {
    [Opcode.Op.MOVE] = "ABC",
    [Opcode.Op.LOADK] = "ABx",
    [Opcode.Op.LOADBOOL] = "ABC",
    [Opcode.Op.LOADNIL] = "ABC",
    [Opcode.Op.GETUPVAL] = "ABC",
    [Opcode.Op.GETGLOBAL] = "ABx",
    [Opcode.Op.GETTABLE] = "ABC",
    [Opcode.Op.SETGLOBAL] = "ABx",
    [Opcode.Op.SETUPVAL] = "ABC",
    [Opcode.Op.SETTABLE] = "ABC",
    [Opcode.Op.NEWTABLE] = "ABC",
    [Opcode.Op.SELF] = "ABC",
    [Opcode.Op.ADD] = "ABC",
    [Opcode.Op.SUB] = "ABC",
    [Opcode.Op.MUL] = "ABC",
    [Opcode.Op.DIV] = "ABC",
    [Opcode.Op.MOD] = "ABC",
    [Opcode.Op.POW] = "ABC",
    [Opcode.Op.UNM] = "ABC",
    [Opcode.Op.NOT] = "ABC",
    [Opcode.Op.LEN] = "ABC",
    [Opcode.Op.CONCAT] = "ABC",
    [Opcode.Op.JMP] = "AsBx",
    [Opcode.Op.EQ] = "ABC",
    [Opcode.Op.LT] = "ABC",
    [Opcode.Op.LE] = "ABC",
    [Opcode.Op.TEST] = "ABC",
    [Opcode.Op.TESTSET] = "ABC",
    [Opcode.Op.CALL] = "ABC",
    [Opcode.Op.TAILCALL] = "ABC",
    [Opcode.Op.RETURN] = "ABC",
    [Opcode.Op.FORLOOP] = "AsBx",
    [Opcode.Op.FORPREP] = "AsBx",
    [Opcode.Op.TFORLOOP] = "ABC",
    [Opcode.Op.SETLIST] = "ABC",
    [Opcode.Op.CLOSE] = "ABC",
    [Opcode.Op.CLOSURE] = "ABx",
    [Opcode.Op.VARARG] = "ABC",
}

Opcode.MAXARG_A = 255
Opcode.MAXARG_B = 511
Opcode.MAXARG_C = 511
Opcode.MAXARG_Bx = 262143
Opcode.MAXARG_sBx = 131071
Opcode.BITRK = 256
Opcode.MAXINDEXRK = 255
Opcode.LFIELDS_PER_FLUSH = 50
Opcode.MAXSTACK = 250
Opcode.MAXVARS = 200
Opcode.MAXUPVALUES = 60

function Opcode.EncodeABC(op, a, b, c)
    return op + a * 64 + c * 16384 + b * 8388608
end

function Opcode.EncodeABx(op, a, bx)
    return op + a * 64 + bx * 16384
end

function Opcode.EncodeAsBx(op, a, sbx)
    return Opcode.EncodeABx(op, a, sbx + Opcode.MAXARG_sBx)
end

function Opcode.Decode(instruction)
    local op = instruction % 64
    local a = floor(instruction / 64) % 256
    local c = floor(instruction / 16384) % 512
    local b = floor(instruction / 8388608) % 512
    local bx = floor(instruction / 16384) % 262144

    return {
        op = op,
        a = a,
        b = b,
        c = c,
        bx = bx,
        sbx = bx - Opcode.MAXARG_sBx,
    }
end

function Opcode.RK(index)
    return Opcode.BITRK + index
end

function Opcode.IsConstant(operand)
    return operand >= Opcode.BITRK
end

function Opcode.ConstantIndex(operand)
    return operand - Opcode.BITRK
end

function Opcode.IntToFloatingByte(value)
    if value < 8 then
        return value
    end

    local exponent = 0
    while value >= 16 do
        value = floor((value + 1) / 2)
        exponent = exponent + 1
    end

    return (exponent + 1) * 8 + value - 8
end

function Opcode.FloatingByteToInt(value)
    if value < 8 then
        return value
    end

    return (value % 8 + 8) * 2 ^ (floor(value / 8) - 1)
end

return Opcode
