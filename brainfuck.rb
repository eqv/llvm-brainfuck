### Disclaimer
#This is the commented version of my little Brainfuck compiler, The code is
#meant for educational purpose. Please note that this compiler is _NOT_ save.
#It is trivial to generate Brainfuck programs that execute arbitrary code on
#your machine by moving beyond the intended memory and corrupting stack
#information. Again: _DO NOT LET ANYONE EXECUTE CODE WITH THIS ON YOUR
#MACHINE_.
#
#This code is released under WTFPL:
#
#
#        DO WHAT THE FUCK YOU WANT TO PUBLIC LICENSE
#                    Version 2, December 2004
#
# Copyright (C) 2004 Sam Hocevar <sam@hocevar.net>
#
# Everyone is permitted to copy and distribute verbatim or modified
# copies of this license document, and changing it is allowed as long
# as the name is changed.
#
#            DO WHAT THE FUCK YOU WANT TO PUBLIC LICENSE
#   TERMS AND CONDITIONS FOR COPYING, DISTRIBUTION AND MODIFICATION
#
#  0. You just DO WHAT THE FUCK YOU WANT TO.

### Setup
#You will need the ruby-llvm gem for this to run. You will probably have to compile llvm 3.0 with
#
#      $ ./configure --enable-jit --enable-shared --enable-optimized
#      $ make && sudo make install
#
# Then you most likely will have to copy the llvm binary to a place where FFI finds it
# In my case this was
#
#      $ cp /usr/lib/x86_64-linux-gnu/libLLVM-3.0.so.1 "~/.rvm/usr/lib/libLLVM-3.0.so"
#
# You can figure out where FFI looks for libraries by running
#
#      $ strace -o dump "ruby brainfuck.rb"
#      $ cat dump| grep open | grep llvm-3.0.so

### Code
#Just some requires for llvm
require 'llvm/core'
require 'llvm/execution_engine'
require 'llvm/transforms/scalar'


#We will use this class to generate a LLVM module containing a single main function that executes our
#brainfuck program.
class Generator

#This method will add a function with the given `name` to the module given as `mod`. Its body will contain the compiled brainfuck `code`.
  def build(code,name, mod)

#Create a new function with the given `name`, taking no arguments, ad returning a single `LLVM::Int`
    mod.functions.add(name, [], LLVM::Int) do |f|
#LLVM handles code in so call **Basic Blocks**. A basic block is a linear
#sequence of instructions without incoming jumps. E.g. only the first
#instruction in a basic block can be jumped to / called to. However a basic
#block may jump/call to as many other basic blocks as it wants. Every basic
#block has to end in a jump to another block or a return.

#Create a basic block that is used as entry point of the function (remember we
#can only jump/call to the begin of a basic block)
      entry= f.basic_blocks.append("entry")
#We will need a loop that initializes the memory for our program, this loop
#needs a loop header `init_loop` that will check whether we have initialized all memory
#fields to 0 and a body `init_body` that will initializes a single memory cell to 0 per
#iteration then jumps back to the loop header. Finally we need the `body` of our
#function actually containing the brainfuck code.
      init_loop = f.basic_blocks.append("init loop")
      init_body = f.basic_blocks.append("init body")
      body = f.basic_blocks.append("body")

#we will support the `.` instruction which needs output. We declare the
#standard function `putchar` as external function which takes one `LLVM::Int`
#and returns another one
      @putchar = mod.functions.add("putchar", [LLVM::Int], LLVM::Int)
#Now we will start to construct the actual program. We use the `builder`
#object which allows us to add code to any given basic block
      entry.build do |builder|
#We create two stack variables, one containing the brainfuck pointer `@offset`,
#the other containing an array of 1000 `LLVM::Int` cells
        @offset = builder.alloca(LLVM::Int)
        @data = builder.array_alloca(LLVM::Int, LLVM::Int(1000))
#The offset will point to he first element of the array for initialization
        builder.store(LLVM::Int(0), @offset)
#br creates a `branch` or jump instruction. After setting up the stack space we
#will jump into the initialization loop
        builder.br init_loop
      end

#This is the header of the init loop, it checks if `@offset` points to the last
#element in the array. If it does the loop will be aborted and the real code
#begins, otherwise another iteration is performed.
      init_loop.build do |builder|
#create a integer equality operation, comparing the content of the `@offset` variable with the constant 1000
        cmp = builder.icmp(:eq, builder.load(@offset), LLVM::Int(1000))
#create a conditional jump that jumps to the main `body` if `@offset == 1000`
#holds and to the init loop body `init_body` otherwise
        builder.cond( cmp , body, init_body)
      end

      #This is the body of the init loop
      init_body.build do |builder|
        #Store the constant 0 in `@data[@offset]`
        addr = builder.gep(@data, [builder.load(@offset)])
        builder.store(LLVM::Int(0), addr) #init cell to 0
        #Move the pointer to the right by one cell (e.g. increment `@offset` by one)
        right(builder) #move ptr to right
        #Jump back to the loop header to check whether we are done
        builder.br init_loop #initialize next field
      end

      #Finally we arrive at the main body of the brainfuck code
      body.build do |builder|
        #Initialize `@offset` to point to the center of the memory
        builder.store(LLVM::Int(500), @offset)
        #Parse the string given as brainfuck code into our intermediate representation
        code_arry = parse(code)
        puts code_arry.inspect
        #We then call the function `code_gen` that will transform the brainfuck code
        #into LLVM instructions appended to the basic block currently pointed to by
        #`builder`. It may be necessary to generate new basic blocks (e.G. if loops
        #are used inside of the brainfuck program, thus we need to pass the function `f` as well.
        builder = code_gen(code_arry,f, builder)
        #Now all the brainfuck code has been generated an builder points to the last
        #basic block created. Simply add a return statement that returns the content of
        #the current memory cell
        builder.ret(deref(builder))
     end
    end
  end

  #This function parses a brainfuck string and returns an intermediate representation.
# For example the string:
#   `"++[>++<-] calculate 2*2 ."`
# becomes the intermediate representation:
#   `["+","+", [ ">", "+","+","<","-" ] "."]`
  def parse(data)
    #Remove all non-brainfuck instruction characters (they are considered to be comments in brainfuck)
    data = data.gsub(/[^\[\]\-+,.<>]/,"")
    #match the outermost pair of `[]` (e.g. the outermost loop) as well as all
    #simple instructions (e.g. `.<>+-`) before and after the loop
    md = data.match(/\A(?<beg>[^\[]+)\[(?<in>.*)\](?<out>[^\[]+)\Z/)
    #If there happens to be a loop we will split all the simple instructions into an array, holding one string per instruction and another Array that contains the loop body
    if md
      return md[:beg].split("") + [parse(md[:in])] + md[:out].split("")
    end
    #If there is no loop the simply splitting suffices
    return data.split("")
  end

  #After we parsed our string into `code` we will now append all the necessary
  #instructions to the basic block of `builder`
  def code_gen(code,f, builder)
    #iterate over every element of the representation
    code.each do |instr|
      case instr
        #If it is an `Array` (e.g. a loop) then call `loop_gen`. This function
        #introduces new basic blocks, thus we have to update our builder
        when Array then builder = loop_gen(instr,f, builder)
        #If it is a simple instruction just call the corresponding generator
        #function. All these functions only append code to the same block so no updates
        #to builder are necessary
        when ">" then right(builder)
        when "<" then left(builder)
        when "+" then inc(builder)
        when "-" then dec(builder)
        when "." then put(builder)
      end
    end
    #Finally return builder so that the callee knows where to continue with code generation
    return builder
  end

  #This function will append a brainfuck loop containing `code` to the block that `builder` holds.
  def loop_gen(code,f, builder)
      #To do so it needs three new basic blocks: `loop_head` (tests whether the loop
      #condition still holds) `loop_body` (holds all the code from the loop body) and
      #`loop_next` (a new block that is used to generate all the code _after_ the
      #loop)
      loop_head = f.basic_blocks.append("loop head")
      loop_body = f.basic_blocks.append("loop body")
      loop_next = f.basic_blocks.append("loop next")

      #add a jump to the `loop_head` to the current basic block
      #Thus the current basic block of `builder` becomes irrelevant
      builder.br(loop_head)
      #Make the `loop_head` the new current basic block of the builder
      builder.position_at_end(loop_head)
      #Add the loop condition `@data[@offset] != 0` to the `loop_head`
      cond = builder.icmp(:eq, deref(builder) , LLVM::Int(0))
      #exit the loop by jumping to `loop_next` if the condition doesn't hold,
      #continue with the loop otherwise
      builder.cond( cond , loop_next, loop_body)

      #Generate the basic block `loop_body`
      loop_body.build do |loop_builder|
        #Recursively generate code for the body of this loop
        #A call to `code_gen` potentially adds more basic blocks, so we need to
        #update our `builder` to point to the new basic block
        loop_builder = code_gen(code, f, loop_builder)
        #After executing the loop body jump back to the head to check for the loop condition
        loop_builder.br(loop_head)
      end
      #return a builder that works on `loop_next` so that the callee can continue building stuff _after_ the loop
      builder.position_at_end(loop_next)
      return builder
  end

  #This function adds a call to putchar(@data[@offset]) to the current basic block
  def put(builder) builder.call(@putchar, deref(builder)) end

  #This function returns a node that contains the value `@data[@offset]`
  def offs(b) return b.gep(@data,[b.load(@offset)]) end

  #This function returns a node that contains the value of `@data[@offset]`
  def deref(b) return b.load(offs(b)) end

  #This function takes a node of type integer and stores its value at `@data[@offset]`
  def store(b,val) return b.store(val,offs(b)) end

  #These functions will add code that increments/decrements the value of `@data[@offset]`
  def inc(builder) store(builder, builder.add( deref(builder), LLVM::Int(1))) end
  def dec(builder) store(builder, builder.sub( deref(builder), LLVM::Int(1))) end

  #These functions will add code that increments/decrements `@offset` (e.g. move the brainfuck pointer to the left/right)
  def right(builder)
    builder.store(builder.add(builder.load(@offset),LLVM::Int(1)), @offset)
  end

  def left(builder)
    builder.store(builder.sub(builder.load(@offset),LLVM::Int(1)), @offset)
  end

end


#We are targeting x86 code
LLVM.init_x86


#Create a new Module (All LLVM functions need to be inside of a module
mod = LLVM::Module.new("brainfuck")
#Create a new Code Generator
gen = Generator.new

halloworld = <<EOF
++++++++++ [ >+++++++>++++++++++>+++>+<<<<- ]
>++.>+.+++++++..+++.>++.<<+++++++++++++++.
>.+++.------.--------.>+.>.+++.
EOF

#Use the code generator to build the main function from the `halloworld` brainfuck code
fn = gen.build(halloworld,"main",mod)

#Verify the byte code
mod.verify

#Make a JIT VM
puts "making jit"
jit = LLVM::JITCompiler.new(mod)

#Add some optimizations - for example "++++++++++" will compile to a single addition of 10 instead of 10 increments
pmgr = LLVM::PassManager.new(jit)
#Tries to convert variables created on the stack with `alloca` into registers
pmgr.mem2reg!
#Combines long sequences of simple instructions into single ones think of all
#those "++++++"
pmgr.instcombine!
#Reorders expressions for later passes
pmgr.reassociate!
#Combines operations on constants into their result
pmgr.constprop!
#Eliminates dead code
pmgr.adce!
#Eliminates dead store instructions
pmgr.dse!
#Apply optimization
pmgr.run(mod)

#Run the Code inside of the JIT VM
jit.run_function(mod.functions["main"]).to_i

#Generate a native binary
puts "compiling to native"
mod.write_bitcode(File.open("test.bc","w"))
system("llc test.bc")
system("gcc test.s -o test.out")
