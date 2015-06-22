@[NoInline]
fun get_stack_top : Void*
  dummy :: Int32
  pointerof(dummy) as Void*
end

ifdef darwin
  @[Link(ldflags: "crystal_extern_darwin.o")]
else
  @[Link(ldflags: "crystal_extern_linux.o")]
end
lib CrystalExtern
  fun switch_stacks(current : Void**, to : Void*)
end

class Fiber
  STACK_SIZE = 8 * 1024 * 1024

  @@first_fiber = nil
  @@last_fiber = nil
  @@stack_pool = [] of Void*

  protected property :stack_top
  protected property :stack_bottom
  protected property :next_fiber
  protected property :prev_fiber

  def initialize(&@proc)
    @stack = Fiber.allocate_stack
    @stack_top = @stack_bottom = @stack + STACK_SIZE
    # @cr = LibPcl.co_create(->(fiber) { (fiber as Fiber).run }, self as Void*, @stack, STACK_SIZE)

    fiber_main = ->(f : Void*) { (f as Fiber).run }

    stack_ptr = @stack + STACK_SIZE - sizeof(UInt64)
    stack_ptr = Pointer(UInt64).new(stack_ptr.address & ~0x0f_u64)
    @stack_top = (stack_ptr - 7) as Void*

    stack_ptr[0] = fiber_main.pointer.address
    stack_ptr[-1] = self.object_id.to_u64

  # stack = (unsigned long *) (malloc(STACK_SIZE) + STACK_SIZE - sizeof(unsigned long));
  # stack = (void *)((unsigned long)stack & ~0x0fUL);
  # stack[0] = (unsigned long)func;
  # stack[-1] = arg;
  # // stack[-2] = (unsigned long)&stack[-1];

  # fiber.stack = &stack[-7];

    @prev_fiber = nil
    if last_fiber = @@last_fiber
      @prev_fiber = last_fiber
      last_fiber.next_fiber = @@last_fiber = self
    else
      @@first_fiber = @@last_fiber = self
    end
  end

  def initialize
    @proc = ->{}
    @stack = Pointer(Void).null
    @stack_top = get_stack_top
    @stack_bottom = LibGC.stackbottom

    @@first_fiber = @@last_fiber = self
  end

  protected def self.allocate_stack
    @@stack_pool.pop? || LibC.mmap(nil, LibC::SizeT.cast(Fiber::STACK_SIZE),
      LibC::PROT_READ | LibC::PROT_WRITE,
      LibC::MAP_PRIVATE | LibC::MAP_ANON,
      -1, 0)
  end

  def self.stack_pool_collect
    return if @@stack_pool.size == 0
    free_count = @@stack_pool.size > 1 ? @@stack_pool.size / 2 : 1
    free_count.times do
      stack = @@stack_pool.pop
      LibC.munmap(stack, LibC::SizeT.cast(Fiber::STACK_SIZE))
    end
  end

  def run
    @proc.call
    @@stack_pool << @stack

    # Remove the current fiber from the linked list

    if prev_fiber = @prev_fiber
      prev_fiber.next_fiber = @next_fiber
    else
      @@first_fiber = @next_fiber
    end

    if next_fiber = @next_fiber
      next_fiber.prev_fiber = @prev_fiber
    else
      @@last_fiber = @prev_fiber
    end

    @@rescheduler.try &.call
  end

  def self.rescheduler=(rescheduler)
    @@rescheduler = rescheduler
  end

  protected def stack_top_ptr
    pointerof(@stack_top)
  end

  @[NoInline]
  def resume
    current, @@current = @@current, self
    CrystalExtern.switch_stacks(current.stack_top_ptr, @stack_top)

    # Fiber.current.stack_top = get_stack_top

    LibGC.stackbottom = @stack_bottom
    # LibPcl.co_call(@cr)
  end

  protected def push_gc_roots
    # Push the used section of the stack
    LibGC.push_all_eager @stack_top, @stack_bottom
  end

  @@prev_push_other_roots = LibGC.get_push_other_roots

  # This will push all fibers stacks whenever the GC wants to collect some memory
  LibGC.set_push_other_roots -> do
    @@prev_push_other_roots.call

    fiber = @@first_fiber
    while fiber
      fiber.push_gc_roots
      fiber = fiber.next_fiber
    end
  end

  @@root = new

  def self.root
    @@root
  end

  # @[ThreadLocal]
  @@current = root

  def self.current
    @@current
  end


end
