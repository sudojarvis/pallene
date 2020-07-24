-- Copyright (c) 2020, The Pallene Developers
-- Pallene is licensed under the MIT license.
-- Please refer to the LICENSE and AUTHORS files for details
-- SPDX-License-Identifier: MIT

local util = require "pallene.util"

--
-- This file implements a Pallene to Lua translator.
--
-- The Pallene compiler is divided into two logical ends:
-- * The frontend which parses Pallene source code to generate AST and performs semantic analysis.
-- * The backend which generates C source code.
--
-- Both these ends are decoupled, this provides us with the flexibility to integrate another backend
-- that generates Lua. The users can run the compiler with `--emit-lua` trigger the translator to
-- generate plain Lua instead of C.
--
-- The generation of Lua is performed by a different backend (implemented here). It accepts input
-- string and the AST generated by the parser. The generator then walks over the AST to replacing
-- type annotations with white space. Interestingly spaces, newlines, comments and pretty much
-- everything else other than type annotations are retained in the translated code. Thus, the
-- formatting in the original input is preserved, which means the error messages always point to
-- the same location in both Pallene and Lua code.
--

local translator = {}

local Translator = util.Class()

function Translator:init(input)
    self.input = input -- string
    self.last_index = 1 -- integer
    self.partials = {} -- list of strings
    self.exports = {} -- list of strings
    return self
end

function Translator:add_previous(stop_index)
    assert(self.last_index <= stop_index + 1)
    local partial = self.input:sub(self.last_index, stop_index)
    table.insert(self.partials, partial)
    self.last_index = stop_index + 1
end

function Translator:add_whitespace(start_index, stop_index)
    assert(self.last_index <= start_index)
    assert(start_index <= stop_index+1)
    self:add_previous(start_index - 1)

    local region = self.input:sub(start_index, stop_index)
    local partial = region:gsub("%S", " ")
    table.insert(self.partials, partial)

    self.last_index = stop_index + 1
end

function Translator:add_local(start_index)
    self:add_previous(start_index - 1)
    -- The export keyword is six characters long, whereas the local keyword is five characters
    -- long. Therefore, we pad the keyword with a space. We could add the space to the left, too.
    -- But it seems more "natural" on the right.
    table.insert(self.partials, "local ")

    self.last_index = self.last_index + 6
end

function Translator:add_exports()
    if #self.exports > 0 then
        table.insert(self.partials, "\nreturn {\n")
        for _, export in ipairs(self.exports) do
            local pair = string.format("    %s = %s,\n", export, export)
            table.insert(self.partials, pair)
        end
        table.insert(self.partials, "}\n")
    end
end

function Translator:translate_decl(decl)
    if decl.type then
        -- Remove the colon but retain any adjacent comment to the right.
        self:add_whitespace(decl.col_loc.pos, decl.col_loc.pos)
        -- Remove the type annotation but exclude the next token.
        self:add_whitespace(decl.type.loc.pos, decl.end_loc.pos - 1)
    end
end

function Translator:translate_stat(stat)
    if stat._tag == "ast.Stat.Decl" then
        for _, decl in ipairs(stat.decls) do
            self:translate_decl(decl)
        end
    elseif stat._tag == "ast.Stat.For" then
        self:translate_decl(stat.decl)
    elseif stat._tag == "ast.Stat.Block" then
        for _, s in ipairs(stat.stats) do
            self:translate_stat(s)
        end
    end
end

function Translator:translate_toplevel(node)
    if node._tag == "ast.Toplevel.Var" then
        -- Add the variables to the export sequence if they are declared with the `export`
        -- modifier.
        if not node.is_local then
            self:add_local(node.loc.pos)
            for _, decl in ipairs(node.decls) do
                table.insert(self.exports, decl.name)
            end
        end

        for _, decl in ipairs(node.decls) do
            self:translate_decl(decl)
        end
    elseif node._tag == "ast.Toplevel.Func" then
        if not node.is_local then
            self:add_local(node.loc.pos)
            table.insert(self.exports, node.decl.name)
        end

        -- Remove type annotations from function parameters.
        for _, arg_decl in ipairs(node.value.arg_decls) do
            self:translate_decl(arg_decl)
        end

        -- Remove type annotations from the return type, which is optional. However, `rt_col_loc`
        -- and `rt_end_loc` are always set. Therefore, it is safe to replace without any checks.
        self:add_whitespace(node.rt_col_loc.pos, node.rt_end_loc.pos - 1)

        self:translate_stat(node.value.body)
    elseif node._tag == "ast.Toplevel.Typealias" then
        -- Remove the type alias but exclude the next token.
        self:add_whitespace(node.loc.pos, node.end_loc.pos - 1)
    elseif node._tag == "ast.Toplevel.Record" then
        -- Remove the record but exclude the next token.
        self:add_whitespace(node.loc.pos, node.end_loc.pos - 1)
    end
end

function translator.translate(input, prog_ast)
    local instance = Translator.new(input)

    for _, node in ipairs(prog_ast) do
        instance:translate_toplevel(node)
    end
    -- Whatever characters that were not included in the partials should be added.
    instance:add_previous(#input)
    instance:add_exports()

    return table.concat(instance.partials)
end

return translator