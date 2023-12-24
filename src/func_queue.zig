const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

const CallbackPtr = *const fn ([]u8) void;

fn CallbackWrapper(comptime Context: type, comptime m_func: fn (Context) void) type {
    return struct {
        fn func(src: []u8) void {
            // Stack storage for context
            var stack: Context = undefined;
            // This avoids problems with aligning context.
            const dest: [*]u8 = @ptrCast(&stack);
            @memcpy(dest, src);

            m_func(dest);
        }
    };
}

pub const FuncQueue = struct {
    gpa: Allocator,
    queue: ArrayListUnmanaged(CallbackPtr),
    sizes: ArrayListUnmanaged(usize),
    buffer: ArrayListUnmanaged(u8),

    pub fn init(allocator: Allocator) !FuncQueue {
        return .{
            .gpa = allocator,
            .queue = .{},
            .sizes = .{},
            .buffer = .{},
        };
    }

    pub fn deinit(self: *FuncQueue) void {
        self.queue.deinit(self.gpa);
        self.sizes.deinit(self.gpa);
        self.buffer.deinit(self.gpa);
    }

    pub fn len(self: *const FuncQueue) usize {
        return self.queue.items.len;
    }

    pub fn enqueue(self: *FuncQueue, context: anytype, comptime func: fn (@TypeOf(context)) void) !void {
        const Context = @TypeOf(context);
        const Wrapper = CallbackWrapper(Context, func);

        const size = @sizeOf(Context);

        try self.queue.append(self.gpa, &Wrapper.func);
        try self.sizes.append(self.gpa, size);

        const cursor = self.buffer.items.len;

        try self.buffer.resize(self.gpa, cursor + size);

        const dest: []u8 = self.buffer.items[cursor .. cursor + size];
        const src: [*]u8 = @ptrCast(&context);

        @memcpy(dest, src);
    }

    pub fn flush(self: *FuncQueue) void {
        var cursor: usize = 0;

        for (self.queue.items, self.sizes.items) |func, size| {
            func(self.buffer.items[cursor .. cursor + size]);
            cursor += size;
        }

        self.queue.clearRetainingCapacity();
        self.sizes.clearRetainingCapacity();
        self.buffer.clearRetainingCapacity();
    }
};
