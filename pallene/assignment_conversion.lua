-- Copyright (c) 2021, The Pallene Developers
-- Pallene is licensed under the MIT license.
-- Please refer to the LICENSE and AUTHORS files for details
-- SPDX-License-Identifier: MIT

local util     = require "pallene.util"
local typedecl = require "pallene.typedecl"
local types    = require "pallene.types"
local ast      = require "pallene.ast"

local converter = {}

--
--  ASSIGNMENT CONVERSION
-- ======================
-- This Compiler pass handles mutable captured variables inside nested closures by
-- transforming AST Nodes that reference or re-assign to them. All captured variables
-- are 'boxed' inside records. For example, consider this code:
-- ```
-- function m.foo()
--     local x: integer = 10
--     local set_x: (integer) -> () = function (y)
--          x = y
--     end
--     local get_x: () -> integer = function () return x end
-- end
--```
-- The AST representation of the above snippet, will be converted in this pass to
-- something like the following:
-- ```
-- record $T
--     value: integer
-- end
--
-- function m.foo()
--     local x: $T = { value = 10 }
--     local set_x: (integer) -> () = function (y)
--          x.value = y
--     end
--     local get_x: () -> integer = function () return x.value end
-- end
-- ```

local Converter = util.Class()

function converter.convert(prog_ast)
    return Converter.new():visit_prog(prog_ast)
end


local function FuncInfo()
    return {
        mutated_decls  = {}, -- list of ast.Decl
        captured_decls = {} -- { ast.Decl }
    }
end

function Converter:init()
    self.func_stack = {} -- list of FuncInfo
    table.insert(self.func_stack, FuncInfo())

    self.ref_of_decl        = {} -- { ast.Decl => list of ast.Var.Name }
    self.func_depth_of_decl = {} -- { ast.Decl => integer }
    self.init_exp_of_decl   = {} -- { ast.Decl => ast.Exp }
    self.box_records        = {} -- list of ast.Toplevel.Record

    -- used to assign unique names to subsequently generated record types
    self.typ_counter = 0
end

-- generates a unique type name each time
function Converter:type_name(var_name)
    self.typ_counter = self.typ_counter + 1
    return "$T_"..var_name.."_"..self.typ_counter
end

function Converter:add_box_type(loc, typ)
    local dummy_node = ast.Toplevel.Record(loc, types.tostring(typ), {})
    dummy_node._type = typ
    table.insert(self.box_records, dummy_node)
end

function Converter:register_decl(decl)
    if not self.ref_of_decl[decl] then
        self.ref_of_decl[decl]        = {}
        self.func_depth_of_decl[decl] = #self.func_stack
    end 
end

function Converter:visit_prog(prog_ast)
    assert(prog_ast._tag == "ast.Program.Program")
    for _, tl_node in ipairs(prog_ast.tls) do
        if tl_node._tag == "ast.Toplevel.Stats" then
            for _, stat in ipairs(tl_node.stats) do
                self:visit_stat(stat)
            end
        else
            -- skip record declarations and type aliases
            assert(typedecl.match_tag(tl_node._tag, "ast.Toplevel"))
        end
    end

    -- add the upvalue box record types to the AST
    for _, node in ipairs(self.box_records) do
        table.insert(prog_ast.tls, node)
    end

    return prog_ast
end

function Converter:visit_stats(stats)
    for _, stat in ipairs(stats) do
        self:visit_stat(stat)
    end
end

-- Goes over all the ast.Decls inside the function that have been captured by some nested
-- function, transforms the decl node itself and all the references made to it.
function Converter:exit_lambda()
    local func_info = self.func_stack[#self.func_stack]
    for _, decl in ipairs(func_info.mutated_decls) do
        if func_info.captured_decls[decl] then
            assert(not decl._exported_as)

            -- 1. Create a record type `$T` to hold this captured var.
            -- 2. Transform the ast.Decl node from `local x = value` to `local x: $T =  { value = value }`
            -- 3. Go over all the references ever made to this variable and transform them from `ast.Var.Name`
            --    to ast.Var.Dot
            local typ = types.T.Record(self:type_name(decl.name), { "value" } , { value = decl._type } )
            self:add_box_type(decl.loc, typ)
            decl._type = typ

            local init_exp = self.init_exp_of_decl[decl]

            if init_exp then
                local value_exp = util.copy_table(init_exp)
                util.empty_table(init_exp)

                init_exp._tag   = "ast.Exp.InitList"
                init_exp._type  = typ
                init_exp.fields = {}
                init_exp.fields[1] = { name = "value", exp = value_exp }
            else
                error("upvalues that are not initialized upon declaration cannot be captured.")
            end

            for _, ref in ipairs(self.ref_of_decl[decl]) do
                assert(ref._tag == "ast.Var.Name")
                local var = util.copy_table(ref)
                ref._tag = "ast.Var.Dot"
                ref.exp  =  ast.Exp.Var(ref.loc, var)
                ref.name = "value"

                ref.exp._type = typ
            end
        end
    end

    assert(#self.func_stack > 1)
    table.remove(self.func_stack)
end

function Converter:visit_lambda(lambda)
    local func_info = FuncInfo()
    table.insert(self.func_stack, func_info)

    for _, arg in ipairs(lambda.arg_decls) do
        self:register_decl(arg)
    end

    self:visit_stats(lambda.body.stats)
    self:exit_lambda()
end

function Converter:visit_func(func)
    assert(func._tag == "ast.FuncStat.FuncStat")
    local lambda = func.value
    assert(lambda and lambda._tag == "ast.Exp.Lambda")
    self:visit_lambda(lambda)
end

function Converter:visit_stat(stat)
    local tag = stat._tag
    if tag == "ast.Stat.Functions" then
        for _, func in ipairs(stat.funcs) do
            self:visit_func(func)
        end
    
    elseif tag == "ast.Stat.Return" then
        for _, exp in ipairs(stat.exps) do
            self:visit_exp(exp)
        end
    
    elseif tag == "ast.Stat.Decl" then
        for _, decl in ipairs(stat.decls) do
            self:register_decl(decl)
        end

        for i, exp in ipairs(stat.exps) do
            self:visit_exp(exp)
            -- do not register extra values on RHS
            if i <= #stat.decls then
                self.init_exp_of_decl[stat.decls[i]] = exp
            end
        end

    elseif tag == "ast.Stat.Block" then
        self:visit_stats(stat.stats)

    elseif tag == "ast.Stat.While" or tag == "ast.Stat.Repeat" then
        self:visit_stats(stat.block.stats)
        self:visit_exp(stat.condition)

    elseif tag == "ast.Stat.If" then
        self:visit_exp(stat.condition)
        self:visit_stats(stat.then_.stats)
        if stat.else_ then
            self:visit_stat(stat.else_)
        end
    
    elseif tag == "ast.Stat.ForNum" then
        self:visit_exp(stat.start)
        self:visit_exp(stat.limit)
        self:visit_exp(stat.step)

        self:register_decl(stat.decl)
        self:visit_stats(stat.block.stats)

    elseif tag == "ast.Stat.ForIn" then
        for _, decl in ipairs(stat.decls) do
            self:register_decl(decl)
        end

        for _, exp in ipairs(stat.exps) do
            self:visit_exp(exp)
        end
        
        self:visit_stats(stat.block.stats)

    elseif tag == "ast.Stat.Assign" then
        for _, var in ipairs(stat.vars) do
            self:visit_var(var)
            
            if var._tag == "ast.Var.Name" and not var._exported_as then
                if var._def._tag == "checker.Def.Variable" then
                    local decl = assert(var._def.decl)
                    local depth = self.func_depth_of_decl[decl]
                    local func_info = self.func_stack[depth]
                    table.insert(func_info.mutated_decls, decl) 
                end
            end
        end

        for _, exp in ipairs(stat.exps) do
            self:visit_exp(exp)
        end

    elseif tag == "ast.Stat.Decl" then
        for _, decl in ipairs(stat.decls) do
            self:register_decl(decl)
        end

        for _, exp in ipairs(stat.exps) do
            self:visit_exp(exp)
        end

    elseif tag == "ast.Stat.Call" then
        self:visit_exp(stat.call_exp)

    elseif  tag == "ast.Stat.Break" then
        -- empty
    else
        typedecl.tag_error(tag)
    end
end


function Converter:visit_var(var)
    local vtag = var._tag

    if vtag == "ast.Var.Name" and not var._exported_as then
        if var._def._tag == "checker.Def.Variable" then
            local decl = assert(var._def.decl)
            assert(self.ref_of_decl[decl], decl.name)
            local depth = self.func_depth_of_decl[decl]
            -- depth == 1 when the decl is that of a global
            if depth < #self.func_stack and depth > 1 then
                local func_info = self.func_stack[depth]
                func_info.captured_decls[decl] = true
            end
            table.insert(self.ref_of_decl[decl], var)
        end

    elseif vtag == "ast.Var.Dot" then
        self:visit_exp(var.exp)
    
    elseif vtag == "ast.Var.Bracket" then
        self:visit_exp(var.t)
        self:visit_exp(var.k)
    
    end
end

-- If necessary, transforms `exp` or one of it's subexpression nodes in case they 
-- reference a mutable upvalue.
-- Recursively visits all sub-expressions and applies an `ast.Var.Name => ast.Var.Dot`
-- transformation wherever necessary.
function Converter:visit_exp(exp)
    local tag = exp._tag

    if tag == "ast.Exp.InitList" then
        for _, field in ipairs(exp.fields) do
            self:visit_exp(field.exp)
        end

    elseif tag == "ast.Exp.Lambda" then
        self:visit_lambda(exp)

    elseif tag == "ast.Exp.CallFunc" or tag == "ast.Exp.CallMethod" then
        self:visit_exp(exp.exp)
        for _, arg in ipairs(exp.args) do
            self:visit_exp(arg)
        end

    elseif tag == "ast.Exp.Var" then
        self:visit_var(exp.var)

    elseif tag == "ast.Exp.Unop" 
        or tag == "ast.Exp.Cast" 
        or tag == "ast.Exp.ToFloat" 
        or tag == "ast.Exp.Paren" then
        self:visit_exp(exp.exp)

    elseif tag == "ast.Exp.Binop" then
        self:visit_exp(exp.lhs)
        self:visit_exp(exp.rhs)

    elseif not typedecl.match_tag(tag, "ast.Exp") then
        typedecl.tag_error(tag)
    end
end

return converter
