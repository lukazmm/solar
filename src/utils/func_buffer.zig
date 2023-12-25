const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

/// A buffer of storage for type erased lambdas.
pub const FuncBuffer = struct {
    buffer: []u8,
    cursor: usize,

    /// Metadata stored before the data storage of each function.
    pub const Meta = struct {
        func: Ptr,
        size: usize,
    };

    /// Number of bytes `Meta` fills.
    const meta_size = @sizeOf(Meta);

    /// A type erased function pointer acting on a byte buffer which stores data.
    pub const Ptr = *const fn ([]u8) void;

    /// Initializes a new function buffer of the specified size.
    pub fn init(allocator: Allocator, size: usize) !FuncBuffer {
        // Allocate a buffer of the given size.
        const buffer = try allocator.alloc(u8, size);
        errdefer allocator.free(buffer);

        return .{
            .buffer = buffer,
            .cursor = 0,
        };
    }

    /// Frees a function buffer.
    pub fn deinit(self: *const FuncBuffer, allocator: Allocator) void {
        allocator.free(self.buffer);
    }

    /// Allocates a new function in the buffer, returning a slice of bytes of the given size
    /// which may be filled with enviornment data for the function. If there is insufficient capacity
    /// in the buffer, this returns `error.OutOfMemory`. Each allocation fills `meta_size + size` bytes
    /// of the buffer (where `meta_size` is usually 16 bytes).
    pub fn alloc(self: *FuncBuffer, size: usize, func: Ptr) error{OutOfMemory}![]u8 {
        // Check the buffer for sufficient space
        if (self.cursor + meta_size + size > self.buffer.len) {
            return error.OutOfMemory;
        }

        // Stack space metadata for this allocation
        const meta: Meta = .{
            .func = func,
            .size = size,
        };
        // Get a pointer to the stack meta
        const meta_bytes: []u8 = self.buffer[self.cursor .. self.cursor + meta_size];
        const meta_ptr: [*]const u8 = @ptrCast(&meta);
        @memcpy(meta_bytes, meta_ptr);
        self.cursor += meta_size;
        // Retrieve the pointer to bytes
        const bytes = self.buffer[self.cursor .. self.cursor + size];
        self.cursor += size;
        // Increment cursor and return
        return bytes;
    }

    /// Resets the function buffer. This erases all existing function pointers and data,
    /// allows new functions to be added to the buffer.
    pub fn reset(self: *FuncBuffer) []u8 {
        self.cursor = 0;
    }

    /// Executes all function in the function buffer.
    pub fn execute(self: *FuncBuffer) void {
        // Stack space for meta data.
        var meta: Meta = undefined;
        const meta_ptr: [*]u8 = @ptrCast(&meta);
        const meta_slice: []u8 = meta_ptr[0..meta_size];
        // Cursor moving through the function queue.
        var cursor: usize = 0;

        while (cursor < self.cursor) {
            // Get meta
            const meta_bytes: [*]const u8 = @ptrCast(&self.buffer[cursor]);
            @memcpy(meta_slice, meta_bytes);
            cursor += meta_size;
            // Run function
            meta.func(self.buffer[cursor .. cursor + meta.size]);
            cursor += meta.size;
        }
    }

    /// Enqueues a function into the function buffer, to be later ran by `execute()`. Sufficient space is allocated to store
    /// context in the bytes following the function pointer.
    pub fn enqueue(self: *FuncBuffer, context: anytype, comptime func: fn (@TypeOf(context)) void) error{OutOfMemory}!void {
        const Context: type = @TypeOf(context);
        // Allocates sufficient space to store `context`.
        const bytes = try self.alloc(@sizeOf(Context), &Wrapper(Context, func).erased);
        // Avoid zig compiler weirdness around taking addresses to arguments
        const ctx = context;
        const ptr: [*]const u8 = @ptrCast(&ctx);
        // Copy context to the given bytes
        @memcpy(bytes, ptr);
    }

    /// A wrapper to perform type erasure on a function + context.
    fn Wrapper(comptime Context: type, comptime m_func: fn (Context) void) type {
        return struct {
            fn erased(src: []u8) void {
                // Stack storage for context
                var stack: Context = undefined;
                // This avoids problems with aligning context data.
                const dest: [*]u8 = @ptrCast(&stack);
                @memcpy(dest, src);
                // Call original function
                m_func(dest);
            }
        };
    }
};
