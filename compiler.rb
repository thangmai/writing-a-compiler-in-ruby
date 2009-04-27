#!/bin/env ruby

require 'emitter'
require 'parser'
require 'scope'
require 'function'
require 'extensions'
require 'ast'

require 'set'

# This gets compiled before each programm.
# It defines the array function, that allocates the appropriate amount of
# bytes for a given array-size.
DO_BEFORE= [
  [:defun, :array, [:size],[:malloc,[:mul,:size,4]]],
]

# This is used for code, that needs to be compiled at the end of a programm.
# For now, it's empty.
DO_AFTER= []

class Compiler
  attr_reader :global_functions

  # list of all predefined keywords with a corresponding compile-method
  # call & callm are ignored, since their compile-methods require
  # a special calling convention
  @@keywords = Set[
                :do, :class, :defun, :if, :lambda,
                :assign, :while, :index, :let, :case
               ]


  def initialize
    @e = Emitter.new
    @global_functions = {}
    @string_constants = {}
    @global_constants = Set.new
    @classes = {}
    @vtableoffsets = VTableOffsets.new
  end


  # Outputs nice compiler error messages, similar to
  # the parser (ParserBase#error).
  def error(error_message, current_scope = nil, current_exp = nil)
    if current_exp.respond_to?(:position) && current_exp.position && current_exp.position.lineno
      pos = current_exp.position
      location = " @ #{pos.inspect}"
    elsif @lastpos
      location = " near (after) #{@lastpos}"
    else
      location = ""
    end
    raise "Compiler error: #{error_message}#{location}\n
           current scope: #{current_scope.inspect}\n
           current expression: #{current_exp.inspect}\n"
  end


  # Prints out a warning to the console.
  # Similar to error, but doesn't throw an exception, only prints out a message
  # and any given additional arguments during compilation process to the console.
  def warning(warning_message, *args)
    STDERR.puts("#{warning_message} - #{args.join(',')}")
  end


  # Allocate an integer value to a symbol. We'll "cheat" for now and just
  # use the "host" system. The symbol table needs to eventually get
  # reflected in the compiled program -- you need to be able to retrieve the
  # name etc.. We also need to either create a "real" object for each of them
  # *or* use a typetag like MRI (in other words: we can't just treat it as an
  # arbitrary integer like this code does.
  def intern(sym)
    sym.to_sym.to_i
  end

  # Returns an argument with its type identifier.
  #
  # If an Array is given, we have a subexpression, which needs to be compiled first.
  # If a Fixnum is given, it's an int ->   [:int, a]
  # If it's a Symbol, its a variable identifier and needs to be looked up within the given scope.
  # Otherwise, we assume it's a string constant and treat it like one.
  def get_arg(scope, a)
    return compile_exp(scope, a) if a.is_a?(Array)
    return [:int, a] if (a.is_a?(Fixnum))
    if (a.is_a?(Symbol))
      name = a.to_s
      return [:int,intern(name.rest)] if name[0] == ?:
      return scope.get_arg(a)
    end

    lab = @string_constants[a]
    if !lab
      lab = @e.get_local
      @string_constants[a] = lab
    end
    return [:strconst,lab]
  end


  # Outputs all constants used within the code generated so far.
  # Outputs them as string and global constants, respectively.
  def output_constants
    @e.rodata { @string_constants.each { |c,l| @e.string(l, c) } }
    @e.bss    { @global_constants.each { |c|   @e.bsslong(c) }}
  end


  # Similar to output_constants, but for functions.
  # Compiles all functions, defined so far and outputs the appropriate assembly code.
  def output_functions
    @global_functions.each do |name,func|

      # create a function scope for each defined function and compile it appropriately.
      # also pass it the current global scope for further lookup of variables used
      # within the functions body that aren't defined there (global variables and those,
      # that are defined in the outer scope of the function's)
      @e.func(name, func.rest?) { compile_eval_arg(FuncScope.new(func,@global_scope),func.body) }

    end
  end


  # Compiles a function definition.
  # Takes the current scope, in which the function is defined,
  # the name of the function, its arguments as well as the body-expression that holds
  # the actual code for the function's body.
  def compile_defun(scope, name, args, body)
    if scope.is_a?(ClassScope) # Ugly. Create a default "register_function" or something. Have it return the global name

      # since we have a class scope,
      # we also pass the class scope to the function, since it's actually a method.
      f = Function.new([:self]+args, body, scope) # "self" is "faked" as an argument to class methods.

      @e.comment("method #{name}")

      # Need to clean up the name to be able to use it in the assembler.
      # Strictly speaking we don't *need* to use a sensible name at all,
      # but it makes me a lot happier when debugging the asm.
      cleaned = name.to_s.gsub("?","__Q") # FIXME: Needs to do more.
      cleaned = cleaned.to_s.gsub("[]","__NDX")
      cleaned = cleaned.to_s.gsub("!","__X")
      fname = "__method_#{scope.name}_#{cleaned}"
      scope.set_vtable_entry(name, fname, f)
      @e.load_address(fname)
      @e.with_register do |reg|
        @e.movl(scope.name.to_s, reg)
        v = scope.vtable[name]
        @e.addl(v.offset*Emitter::PTR_SIZE, reg) if v.offset > 0
        @e.save_to_indirect(@e.result_value,reg)
      end
      name = fname
    else
      # function isn't within a class (which would mean, it's a method)
      # so it must be global
      f = Function.new(args, body)
    end

    # add function to the global list of functions defined so far
    @global_functions[name] = f

    # a function is referenced by its name (in assembly this is a label).
    # wherever we encounter that name, we really need the adress of the label.
    # so we mark the function with an adress type.
    return [:addr, name]
  end


  # Compiles an if expression.
  # Takes the current (outer) scope and two expressions representing
  # the if and else arm.
  # If no else arm is given, it defaults to nil.
  def compile_if(scope, cond, if_arm, else_arm = nil)
    compile_eval_arg(scope, cond)
    l_else_arm = @e.get_local
    l_end_if_arm = @e.get_local
    @e.jmp_on_false(l_else_arm)
    compile_eval_arg(scope, if_arm)
    @e.jmp(l_end_if_arm) if else_arm
    @e.local(l_else_arm)
    compile_eval_arg(scope, else_arm) if else_arm
    @e.local(l_end_if_arm) if else_arm
    return [:subexpr]
  end

  def compile_case(scope, *args)
    error(":case not implemented yet", scope, [:case]+args)
    # FIXME:
    # Implement like this: compile_eval_arg
    # save the register, and loop over the "when"'s. 
    # Compile each of the "when"'s as "if"'s where the value
    # is loaded from the stack and compared with the value
    # (or values) in the when clause
  end


  # Compiles an anonymous function ('lambda-expression').
  # Simply calls compile_defun, only, that the name gets generated
  # by the emitter via Emitter#get_local.
  def compile_lambda(scope, args, body)
    compile_defun(scope, @e.get_local, args,body)
  end


  # Compiles and evaluates a given argument within a given scope.
  def compile_eval_arg(scope, arg)
    if arg.respond_to?(:position) && arg.position != nil
      pos = arg.position.inspect
      @e.comment(arg.position.inspect) if pos != @lastpos
      @lastpos = pos
    end
    args = get_arg(scope,arg)
    atype = args[0]
    aparam = args[1]
    if atype == :ivar
      ret = compile_eval_arg(scope, :self)
      @e.load_instance_var(ret, aparam)
      return @e.result_value
    end
    return @e.load(atype,aparam)
  end


  # Compiles an assignment statement.
  def compile_assign(scope, left, right)
    # transform "foo.bar = baz" into "foo.bar=(baz) - FIXME: Is this better handled in treeoutput.rb?
    # Also need to handle :call equivalently.
    if left.is_a?(Array) && left[0] == :callm && left.size == 3 # no arguments
      return compile_callm(scope, left[1], (left[2].to_s + "=").to_sym, right)
    end

    source = compile_eval_arg(scope, right)
    atype = nil
    aparam = nil
    @e.save_register(source) do
      atype, aparam = get_arg(scope, left)
    end

    if atype == :ivar
      ret = compile_eval_arg(scope,:self)
      @e.save_to_instance_var(source, ret, aparam)
      return [:subexpr]
    end

    if !(@e.save(atype,source,aparam))
      err_msg = "Expected an argument on left hand side of assignment - got #{atype.to_s}, (left: #{left.inspect}, right: #{right.inspect})"
      error(err_msg, scope, [:assign, left, right]) # pass current expression as well
    end
    return [:subexpr]
  end


  # Compiles a function call.
  # Takes the current scope, the function to call as well as the arguments
  # to call the function with.
  def compile_call(scope, func, args)
    args = [args] if !args.is_a?(Array)
    @e.with_stack(args.length, true) do
      args.each_with_index do |a,i|
        param = compile_eval_arg(scope, a)
        @e.save_to_stack(param, i)
      end
      @e.call(compile_eval_arg(scope, func))
    end
    return [:subexpr]
  end


  # Compiles a method call to an object.
  # Similar to compile_call but with an additional object parameter
  # representing the object to call the method on.
  # The object gets passed to the method, which is just another function,
  # as the first parameter.
  def compile_callm(scope, ob, method, args)
    @e.comment("callm #{ob.to_s}.#{method.inspect}")

    args ||= []
    args = [args] if !args.is_a?(Array) # FIXME: It's probably better to make the parser consistently pass an array

    off = @vtableoffsets.get_offset(method)
    if !off
      # Argh. Ok, then. Lets do send
      off = @vtableoffsets.get_offset(:__send__)
      args = [intern(method)] + args
      warning("WARNING: No vtable offset for '#{method}' -- you're likely to get a method_missing")
      #error(err_msg, scope, [:callm, ob, method, args])
    end

    @e.with_stack(args.length+1, true) do
      ret = compile_eval_arg(scope, ob)
      @e.save_register(ret) do
        @e.save_to_stack(ret, 0)
        args.each_with_index do |a,i|
          param = compile_eval_arg(scope, a)
          @e.save_to_stack(param, i+1)
        end
      end
      @e.with_register do |reg|
        @e.load_indirect(ret, reg)

        @e.movl("#{off*Emitter::PTR_SIZE}(%#{reg.to_s})", @e.result_value)
        @e.call(@e.result_value)
      end
    end
    @e.comment("callm #{ob.to_s}.#{method.to_s} END")
    return [:subexpr]
  end


  # Compiles a do-end block expression.
  def compile_do(scope, *exp)
    exp.each { |e| source=compile_eval_arg(scope, e); @e.save_result(source); }
    return [:subexpr]
  end


  # Compiles a array indexing-expression.
  # Takes the current scope, the array as well as the index number to access.
  def compile_index(scope, arr, index)
    source = compile_eval_arg(scope, arr)
    reg = nil #This is needed to retain |reg|
    @e.with_register do |reg|
      @e.movl(source,reg)
      source = compile_eval_arg(scope, index)
      @e.save_result(source)
      @e.sall(2, @e.result_value)
      @e.addl(@e.result_value,reg)
    end
    return [:indirect, reg]
  end


  # Compiles a while loop.
  # Takes the current scope, a condition expression as well as the body of the function.
  def compile_while(scope, cond, body)
    @e.loop do |br|
      var = compile_eval_arg(scope, cond)
      @e.jmp_on_false(br)
      compile_exp(scope, body)
    end
    return [:subexpr]
  end


  # Compiles a let expression.
  # Takes the current scope, a list of variablenames as well as a list of arguments.
  def compile_let(scope, varlist, *args)
    vars = {}
    varlist.each_with_index {|v,i| vars[v]=i}
    ls = LocalVarScope.new(vars, scope)
    if vars.size
      @e.with_local(vars.size) { compile_do(ls, *args) }
    else
      compile_do(ls, *args)
    end
    return [:subexpr]
  end


  # Compiles a class definition.
  # Takes the current scope, the name of the class as well as a list of expressions
  # that belong to the class.
  def compile_class(scope, name, *exps)
    @e.comment("=== class #{name} ===")

    cscope = ClassScope.new(scope, name, @vtableoffsets)

    # FIXME: (If this class has a superclass, copy the vtable from the superclass as a starting point)
    # FIXME: Fill in all unused vtable slots with __method_missing
    # FIXME: Need to generate "thunks" for __method_missing that knows the name of the slot they are in, and
    #        then jump into __method_missing.
    exps.each do |l2|
      l2.each do |e|
        if e.is_a?(Array) && e[0] == :defun
          cscope.add_vtable_entry(e[1]) # add method into vtable of class-scope to associate with class
        end
      end
    end
    @classes[name] = cscope
    @global_scope.globals << name
    compile_exp(scope, [:assign, name.to_sym, [:call, :__new_class_object, [cscope.klass_size]]])
    compile_exp(cscope, [:assign, :@instance_size, cscope.instance_size])
    @global_constants << name
    exps.each do |e|
      addr = compile_do(cscope, *e)
    end
    @e.comment("=== end class #{name} ===")
    return [:global, name]
  end


  # General method for compiling expressions.
  # Calls the specialized compile methods depending of the
  # expression to be compiled (e.g. compile_if, compile_call, compile_let etc.).
  def compile_exp(scope, exp)
    return [:subexpr] if !exp || exp.size == 0

    # check if exp is within predefined keywords list
    if(@@keywords.include?(exp[0]))
      return self.send("compile_#{exp[0].to_s}", scope, *exp.rest)
    else
      return compile_call(scope, exp[1], exp[2]) if (exp[0] == :call)
      return compile_callm(scope, exp[1], exp[2], exp[3]) if (exp[0] == :callm)
      return compile_call(scope, exp[0], exp.rest) if (exp.is_a? Array)
    end

    warning("Somewhere calling #compile_exp when they should be calling #compile_eval_arg? #{exp.inspect}")
    res = compile_eval_arg(scope, exp[0])
    @e.save_result(res)
    return [:subexpr]
  end


  # Compiles the main function, where the compiled programm starts execution.
  def compile_main(exp)
    @e.main do
      # We should allow arguments to main
      # so argc and argv get defined, but
      # that is for later.
      @main = Function.new([],[])
      @global_scope = GlobalScope.new
      compile_eval_arg(FuncScope.new(@main, @global_scope), exp)
    end

    # after the main function, we ouput all functions and constants
    # used and defined so far.
    output_functions
    output_constants
  end


  # We need to ensure we find the maximum
  # size of the vtables *before* we compile
  # any of the classes
  #
  # Consider whether to check :call/:callm nodes as well, though they
  # will likely hit method_missing
  def alloc_vtable_offsets(exp)
    exp.depth_first(:defun) do |defun|
      @vtableoffsets.alloc_offset(defun[1])
      :skip
    end

    classes = 0
    exp.depth_first(:class) {|c| classes += 1; :skip }
    warning("INFO: Max vtable offset when compiling is #{@vtableoffsets.max} in #{classes} classes, for a total vtable overhead of #{@vtableoffsets.max * classes * 4} bytes")
  end


  # Starts the actual compile process.
  def compile(exp)
    alloc_vtable_offsets(exp)
    compile_main(exp)
  end
end

dump = ARGV.include?("--parsetree")
norequire = ARGV.include?("--norequire") # Don't process require's statically - compile them instead

# Option to not rewrite the parse tree (breaks compilation, but useful for debugging of the parser)
OpPrec::TreeOutput.dont_rewrite if ARGV.include?("--dont-rewrite")


# check remaining arguments, if a filename is given.
# if not, read from STDIN.
input_source = STDIN
ARGV.each do |arg|
  if File.exists?(arg)
    input_source = File.open(arg, "r")
    STDERR.puts "reading from file: #{arg}"
    break
  end
end

s = Scanner.new(input_source)
prog = nil

begin
  parser = Parser.new(s, {:norequire => norequire})
  prog = parser.parse
rescue Exception => e
  STDERR.puts "#{e.message}"
  # FIXME: The position ought to come from the parser, as should the rest, since it could come
  # from a 'require'd file, in which case the fragment below means nothing.
  STDERR.puts "Failed at line #{s.lineno} / col #{s.col}  before:\n"
  buf = ""
  while s.peek && buf.size < 100
    buf += s.get
  end
  STDERR.puts buf
end

if prog && dump
  PP.pp prog
  exit
end

Compiler.new.compile(prog) if prog
