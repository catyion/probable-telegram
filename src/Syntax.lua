local Syntax = {}

Syntax.Keywords = {
    ["and"] = true,
    ["break"] = true,
    ["do"] = true,
    ["else"] = true,
    ["elseif"] = true,
    ["end"] = true,
    ["false"] = true,
    ["for"] = true,
    ["function"] = true,
    ["if"] = true,
    ["in"] = true,
    ["local"] = true,
    ["nil"] = true,
    ["not"] = true,
    ["or"] = true,
    ["repeat"] = true,
    ["return"] = true,
    ["then"] = true,
    ["true"] = true,
    ["until"] = true,
    ["while"] = true,
}

Syntax.BlockEnd = {
    ["else"] = true,
    ["elseif"] = true,
    ["end"] = true,
    ["until"] = true,
    ["eof"] = true,
}

Syntax.Binary = {
    ["or"] = { 1, 2 },
    ["and"] = { 2, 3 },
    ["<"] = { 3, 4 },
    ["<="] = { 3, 4 },
    [">"] = { 3, 4 },
    [">="] = { 3, 4 },
    ["~="] = { 3, 4 },
    ["=="] = { 3, 4 },
    [".."] = { 4, 4 },
    ["+"] = { 5, 6 },
    ["-"] = { 5, 6 },
    ["*"] = { 6, 7 },
    ["/"] = { 6, 7 },
    ["%"] = { 6, 7 },
    ["^"] = { 8, 8 },
}

Syntax.Unary = {
    ["-"] = true,
    ["not"] = true,
    ["#"] = true,
}

Syntax.UnaryBindingPower = 7

return Syntax
