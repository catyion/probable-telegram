local Disassembler = require("src.Disassembler")
local Dumper = require("src.Dumper")
local Format = require("src.Format")
local Generator = require("src.Generator")
local Inspector = require("src.Inspector")
local Lexer = require("src.Lexer")
local Opcode = require("src.Opcode")
local Parser = require("src.Parser")
local Platform = require("src.Platform")
local Resolver = require("src.Resolver")

local Compiler = {
    VERSION = "1.0.0",
    Format = Format,
    Disassembler = Disassembler,
    Dumper = Dumper,
    Generator = Generator,
    Inspector = Inspector,
    Lexer = Lexer,
    Opcode = Opcode,
    Parser = Parser,
    Platform = Platform,
    Resolver = Resolver,
}

local function normalize_options(options)
    if options == nil then
        return {}
    end
    if type(options) == "string" then
        return { source_name = options }
    end
    if type(options) ~= "table" then
        error("compiler options must be a table or source-name string", 3)
    end
    return options
end

local function source_name(options)
    return options.source_name or "=(source)"
end

local function resolve_platform(value)
    if value == nil then
        return Platform.Default()
    end
    if type(value) == "string" then
        return Platform.FromName(value)
    end
    Platform.Validate(value)
    return value
end

function Compiler.Tokenize(source, options)
    options = normalize_options(options)
    return Lexer.Tokenize(source, source_name(options))
end

function Compiler.Parse(source_or_tokens, options)
    options = normalize_options(options)
    local tokens

    if type(source_or_tokens) == "string" then
        tokens = Lexer.Tokenize(source_or_tokens, source_name(options))
    elseif type(source_or_tokens) == "table" then
        tokens = source_or_tokens
    else
        error("source must be a string or token array", 2)
    end

    return Parser.Parse(tokens, source_name(options))
end

function Compiler.Resolve(source_or_ast, options)
    options = normalize_options(options)
    local ast

    if type(source_or_ast) == "string" then
        ast = Compiler.Parse(source_or_ast, options)
    elseif type(source_or_ast) == "table" and source_or_ast.kind == "Chunk" then
        ast = source_or_ast
    else
        error("source must be a string or Chunk node", 2)
    end

    if not ast.function_scope then
        Resolver.Resolve(ast, source_name(options))
    end
    return ast
end

function Compiler.Prototype(source_or_ast, options)
    options = normalize_options(options)

    if type(source_or_ast) == "table" and source_or_ast.code then
        return source_or_ast
    end

    local ast = Compiler.Resolve(source_or_ast, options)
    return Generator.Generate(ast)
end

function Compiler.Compile(source_or_proto, options)
    options = normalize_options(options)
    local proto = Compiler.Prototype(source_or_proto, options)
    local platform = resolve_platform(options.platform)
    return Dumper.Dump(proto, platform, options.strip_debug)
end

function Compiler.Disassemble(source_or_proto, options)
    options = normalize_options(options)
    local proto = Compiler.Prototype(source_or_proto, options)
    return Disassembler.Format(proto)
end

function Compiler.Inspect(value, options)
    return Inspector.Format(value, options)
end

function Compiler.Output(source, output_format, options)
    options = normalize_options(options)
    output_format = output_format or Format.BYTECODE

    if output_format == Format.TOKENS then
        return Compiler.Tokenize(source, options)
    elseif output_format == Format.AST then
        return Compiler.Parse(source, options)
    elseif output_format == Format.RESOLVED then
        return Compiler.Resolve(source, options)
    elseif output_format == Format.PROTOTYPE then
        return Compiler.Prototype(source, options)
    elseif output_format == Format.BYTECODE then
        return Compiler.Compile(source, options)
    elseif output_format == Format.DISASSEMBLY then
        return Compiler.Disassemble(source, options)
    end

    error("unknown compiler output format '" .. tostring(output_format) .. "'", 2)
end

return Compiler
