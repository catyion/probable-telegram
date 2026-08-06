local Platform = require("src.Platform")

local Dumper = {}

local char = string.char
local concat = table.concat
local floor = math.floor
local frexp = math.frexp
local huge = math.huge
local type = type

local LUA_SIGNATURE = "\27Lua"
local LUA_VERSION = 0x51
local LUA_FORMAT = 0

local LUA_TNIL = 0
local LUA_TBOOLEAN = 1
local LUA_TNUMBER = 3
local LUA_TSTRING = 4

local TWO_20 = 1048576
local TWO_31 = 2147483648
local TWO_32 = 4294967296
local TWO_52 = 4503599627370496
local MIN_SUBNORMAL = 4.9406564584124654e-324

local function write(writer, value)
    writer.parts[#writer.parts + 1] = value
end

local function pack_unsigned(value, size, endian)
    if value < 0 or value ~= floor(value) then
        error("binary chunk integer must be a non-negative integer", 0)
    end

    local bytes = {}
    for index = 1, size do
        bytes[index] = char(value % 256)
        value = floor(value / 256)
    end

    if value ~= 0 then
        error("binary chunk integer does not fit its target field", 0)
    end

    if endian == "big" then
        local left = 1
        local right = size
        while left < right do
            bytes[left], bytes[right] = bytes[right], bytes[left]
            left = left + 1
            right = right - 1
        end
    end

    return concat(bytes)
end

local function split_double(value)
    local sign = 0
    if value < 0 or (value == 0 and 1 / value < 0) then
        sign = 1
        value = -value
    end

    local exponent
    local fraction

    if value ~= value then
        exponent = 2047
        fraction = TWO_52 / 2
    elseif value == huge then
        exponent = 2047
        fraction = 0
    elseif value == 0 then
        exponent = 0
        fraction = 0
    else
        local mantissa, binary_exponent = frexp(value)
        exponent = binary_exponent + 1022

        if exponent <= 0 then
            exponent = 0
            fraction = floor(value / MIN_SUBNORMAL + 0.5)
        else
            fraction = floor((mantissa * 2 - 1) * TWO_52 + 0.5)
            if fraction >= TWO_52 then
                fraction = 0
                exponent = exponent + 1
            end
            if exponent >= 2047 then
                exponent = 2047
                fraction = 0
            end
        end
    end

    local low = fraction % TWO_32
    local high_fraction = floor(fraction / TWO_32)
    local high = sign * TWO_31 + exponent * TWO_20 + high_fraction
    return high, low
end

local function pack_number(value, endian)
    local high, low = split_double(value)
    if endian == "little" then
        return pack_unsigned(low, 4, endian) .. pack_unsigned(high, 4, endian)
    end
    return pack_unsigned(high, 4, endian) .. pack_unsigned(low, 4, endian)
end

local function write_byte(writer, value)
    write(writer, char(value))
end

local function write_int(writer, value)
    write(writer, pack_unsigned(value, writer.platform.int_size, writer.platform.endian))
end

local function write_size_t(writer, value)
    write(writer, pack_unsigned(value, writer.platform.size_t_size, writer.platform.endian))
end

local function write_instruction(writer, value)
    write(writer, pack_unsigned(value, writer.platform.instruction_size, writer.platform.endian))
end

local function write_number(writer, value)
    write(writer, pack_number(value, writer.platform.endian))
end

local function write_string(writer, value)
    if value == nil then
        write_size_t(writer, 0)
        return
    end

    write_size_t(writer, #value + 1)
    write(writer, value)
    write_byte(writer, 0)
end

local function dump_code(writer, proto)
    write_int(writer, #proto.code)
    for index = 1, #proto.code do
        write_instruction(writer, proto.code[index])
    end
end

local dump_function

local function dump_constants(writer, proto, parent_source)
    write_int(writer, #proto.constants)
    for index = 1, #proto.constants do
        local value = proto.constants[index]
        local value_type = type(value)

        if value == nil then
            write_byte(writer, LUA_TNIL)
        elseif value_type == "boolean" then
            write_byte(writer, LUA_TBOOLEAN)
            write_byte(writer, value and 1 or 0)
        elseif value_type == "number" then
            write_byte(writer, LUA_TNUMBER)
            write_number(writer, value)
        elseif value_type == "string" then
            write_byte(writer, LUA_TSTRING)
            write_string(writer, value)
        else
            error("unsupported prototype constant type '" .. value_type .. "'", 0)
        end
    end

    write_int(writer, #proto.protos)
    for index = 1, #proto.protos do
        dump_function(writer, proto.protos[index], parent_source)
    end
end

local function dump_debug(writer, proto)
    if writer.strip_debug then
        write_int(writer, 0)
        write_int(writer, 0)
        write_int(writer, 0)
        return
    end

    write_int(writer, #proto.line_info)
    for index = 1, #proto.line_info do
        write_int(writer, proto.line_info[index])
    end

    write_int(writer, #proto.locals)
    for index = 1, #proto.locals do
        local local_info = proto.locals[index]
        write_string(writer, local_info.name)
        write_int(writer, local_info.start_pc)
        write_int(writer, local_info.end_pc)
    end

    write_int(writer, #proto.upvalue_names)
    for index = 1, #proto.upvalue_names do
        write_string(writer, proto.upvalue_names[index])
    end
end

dump_function = function(writer, proto, parent_source)
    local source = proto.source
    if writer.strip_debug or source == parent_source then
        write_string(writer, nil)
    else
        write_string(writer, source)
    end

    write_int(writer, proto.line_defined or 0)
    write_int(writer, proto.last_line_defined or 0)
    write_byte(writer, proto.nups or 0)
    write_byte(writer, proto.num_params or 0)
    write_byte(writer, proto.is_vararg or 0)
    write_byte(writer, proto.max_stack_size or 2)

    dump_code(writer, proto)
    dump_constants(writer, proto, source)
    dump_debug(writer, proto)
end

local function write_header(writer)
    local platform = writer.platform
    write(writer, LUA_SIGNATURE)
    write_byte(writer, LUA_VERSION)
    write_byte(writer, LUA_FORMAT)
    write_byte(writer, platform.endian == "little" and 1 or 0)
    write_byte(writer, platform.int_size)
    write_byte(writer, platform.size_t_size)
    write_byte(writer, platform.instruction_size)
    write_byte(writer, platform.number_size)
    write_byte(writer, platform.integral_numbers and 1 or 0)
end

function Dumper.Dump(proto, platform, strip_debug)
    if type(proto) ~= "table" or type(proto.code) ~= "table" then
        error("prototype must be a generated Lua 5.1 prototype", 2)
    end

    platform = platform or Platform.Default()
    Platform.Validate(platform)

    local writer = {
        parts = {},
        platform = platform,
        strip_debug = strip_debug == true,
    }

    write_header(writer)
    dump_function(writer, proto, nil)
    return concat(writer.parts)
end

return Dumper
