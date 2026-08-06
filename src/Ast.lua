local Ast = {}

local function copy_fields(target, fields)
    if fields then
        for key, value in pairs(fields) do
            target[key] = value
        end
    end
end

function Ast.New(kind, first, last, fields)
    last = last or first

    local node = {
        kind = kind,
        line = first.line,
        column = first.column,
        offset = first.offset,
        end_line = last.end_line,
        end_column = last.end_column,
        end_offset = last.end_offset,
    }

    copy_fields(node, fields)
    return node
end

function Ast.IsCall(node)
    return node.kind == "CallExpression" or node.kind == "MethodCallExpression"
end

function Ast.IsVariable(node)
    return node.kind == "Identifier" or node.kind == "IndexExpression" or node.kind == "MemberExpression"
end

function Ast.IsMultiResult(node)
    return node.kind == "CallExpression" or node.kind == "MethodCallExpression" or node.kind == "VarargExpression"
end

return Ast
