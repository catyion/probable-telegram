local Platform = {}

local function copy(profile)
    return {
        name = profile.name,
        endian = profile.endian,
        int_size = profile.int_size,
        size_t_size = profile.size_t_size,
        instruction_size = profile.instruction_size,
        number_size = profile.number_size,
        integral_numbers = profile.integral_numbers,
    }
end

local function validate_size(value, name)
    if value ~= 4 and value ~= 8 then
        error(name .. " must be 4 or 8 bytes", 3)
    end
end

function Platform.Validate(profile)
    if type(profile) ~= "table" then
        error("platform must be a table", 2)
    end
    if profile.endian ~= "little" and profile.endian ~= "big" then
        error("platform endian must be 'little' or 'big'", 2)
    end
    if profile.int_size ~= 4 then
        error("only 4-byte Lua integers are supported", 2)
    end
    validate_size(profile.size_t_size, "platform size_t_size")
    if profile.instruction_size ~= 4 then
        error("only 4-byte Lua instructions are supported", 2)
    end
    if profile.number_size ~= 8 or profile.integral_numbers then
        error("only non-integral 8-byte IEEE 754 Lua numbers are supported", 2)
    end
    return profile
end

function Platform.New(options)
    if type(options) ~= "table" then
        error("platform options must be a table", 2)
    end

    local profile = {
        name = options.name or "custom",
        endian = options.endian,
        int_size = options.int_size or 4,
        size_t_size = options.size_t_size,
        instruction_size = options.instruction_size or 4,
        number_size = options.number_size or 8,
        integral_numbers = options.integral_numbers == true,
    }

    Platform.Validate(profile)
    return profile
end

function Platform.Little32()
    return Platform.New({
        name = "little32",
        endian = "little",
        size_t_size = 4,
    })
end

function Platform.Little64()
    return Platform.New({
        name = "little64",
        endian = "little",
        size_t_size = 8,
    })
end

function Platform.Big32()
    return Platform.New({
        name = "big32",
        endian = "big",
        size_t_size = 4,
    })
end

function Platform.Big64()
    return Platform.New({
        name = "big64",
        endian = "big",
        size_t_size = 8,
    })
end

function Platform.Native()
    local chunk = string.dump(function()
    end)

    if string.sub(chunk, 1, 4) ~= "\27Lua" or string.byte(chunk, 5) ~= 0x51 then
        error("native platform detection requires a standard Lua 5.1 runtime", 2)
    end
    if string.byte(chunk, 6) ~= 0 then
        error("unsupported native Lua 5.1 binary chunk format", 2)
    end

    return Platform.New({
        name = "native",
        endian = string.byte(chunk, 7) == 1 and "little" or "big",
        int_size = string.byte(chunk, 8),
        size_t_size = string.byte(chunk, 9),
        instruction_size = string.byte(chunk, 10),
        number_size = string.byte(chunk, 11),
        integral_numbers = string.byte(chunk, 12) ~= 0,
    })
end

function Platform.Default()
    local ok, profile = pcall(Platform.Native)
    if ok then
        return profile
    end
    return Platform.Little64()
end

function Platform.FromName(name)
    if name == nil or name == "default" then
        return Platform.Default()
    elseif name == "native" then
        return Platform.Native()
    elseif name == "little32" then
        return Platform.Little32()
    elseif name == "little64" then
        return Platform.Little64()
    elseif name == "big32" then
        return Platform.Big32()
    elseif name == "big64" then
        return Platform.Big64()
    end

    error(string.format("unknown Lua 5.1 platform profile %q", tostring(name)), 2)
end

function Platform.Copy(profile)
    Platform.Validate(profile)
    return copy(profile)
end

return Platform
