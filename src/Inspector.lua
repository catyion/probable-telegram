local Inspector = {}

local concat = table.concat
local format = string.format
local sort = table.sort

local function is_identifier(value)
    return type(value) == "string" and value:match("^[%a_][%w_]*$") ~= nil
end

local function append_value(output, value, depth, seen)
    local value_type = type(value)

    if value_type == "string" then
        output[#output + 1] = format("%q", value)
    elseif value_type ~= "table" then
        output[#output + 1] = tostring(value)
    elseif seen[value] then
        output[#output + 1] = "<cycle>"
    else
        seen[value] = true
        output[#output + 1] = "{"

        local keys = {}
        for key in pairs(value) do
            keys[#keys + 1] = key
        end

        sort(keys, function(left, right)
            local left_type = type(left)
            local right_type = type(right)
            if left_type == right_type then
                return tostring(left) < tostring(right)
            end
            return left_type < right_type
        end)

        if #keys > 0 then
            output[#output + 1] = "\n"
        end

        for _, key in ipairs(keys) do
            output[#output + 1] = string.rep("    ", depth + 1)
            if is_identifier(key) then
                output[#output + 1] = key
            else
                output[#output + 1] = "["
                append_value(output, key, depth + 1, seen)
                output[#output + 1] = "]"
            end
            output[#output + 1] = " = "
            append_value(output, value[key], depth + 1, seen)
            output[#output + 1] = ",\n"
        end

        if #keys > 0 then
            output[#output + 1] = string.rep("    ", depth)
        end
        output[#output + 1] = "}"
        seen[value] = nil
    end
end

function Inspector.Format(value)
    local output = {}
    append_value(output, value, 0, {})
    return concat(output)
end

return Inspector
