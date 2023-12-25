const std = @import("std");
const ArrayList = std.ArrayList;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const Allocator = std.mem.Allocator;

const assert = std.debug.assert;
const panic = std.debug.panic;

const vk = @import("vulkan");

// Other modules
const device_ = @import("device.zig");
const Device = device_.Device;

const DequeUnmanaged = @import("utils/deque.zig").DequeUnmanaged;

pub const QueueKind = enum {
    direct,
    async_compute,
    async_transfer,
};

pub const QueueConfig = struct {
    kind: QueueKind,
};

pub const ShaderQueue = struct {
    timeline: vk.Semaphore,
};

/// A helper struct for reusing handles once they are no longer in use by a given submit.
fn QueuePool(comptime T: type) type {
    return struct {
        allocator: Allocator,
        free: ArrayListUnmanaged(T),
        recording: ArrayListUnmanaged(T),
        pending: DequeUnmanaged(Flight),

        const Flight = struct {
            handle: T,
            value: usize,
        };

        /// Initializes a queue pool.
        fn init(allocator: Allocator) error{OutOfMemory}!@This() {
            const pending = try DequeUnmanaged(Flight).init(allocator);
            errdefer pending.deinit(allocator);

            return .{
                .allocator = allocator,
                .free = .{},
                .recording = .{},
                .pending = pending,
            };
        }

        /// Deinitializes a queue pool.
        fn deinit(self: *@This()) void {
            self.free.deinit(self.allocator);
            self.recording.deinit(self.allocator);
            self.pending.deinit(self.allocator);
        }

        /// Checks if any currently pending handles have completed, and if so, moves them to
        /// the free state. This returns the handle in the case that some additional routine must be called.
        fn reset(self: *@This(), fence: usize) error{OutOfMemory}!?T {
            if (self.pending.front()) |front| {
                if (front.value <= fence) {
                    const handle = self.pending.popFront().?.handle;
                    try self.free.append(self.allocator, handle);
                    return handle;
                }
            }
        }

        /// Checks whether the pool needs growth before additional memory can be requested.
        fn shouldGrow(self: *@This()) bool {
            return self.free.items.len == 0;
        }

        /// Grows the queue pool by pushing the given handle onto the free stack
        fn grow(self: *@This(), handle: T) error{OutOfMemory}!void {
            try self.free.append(self.allocator, handle);
        }

        /// Requests a new handle for recording.
        fn request(self: *@This()) error{OutOfMemory}!T {
            if (self.recording.items.len == 0 and self.free.items.len == 0) {
                return error.OutOfMemory;
            } else if (self.recording.items.len == 0) {
                try self.recording.append(self.allocator, self.free.pop());
            }

            return self.recording.getLast();
        }

        /// Transfers all currently recording handles into the pending state.
        fn submit(self: *@This(), fence: usize) error{OutOfMemory}!void {
            while (self.recording.popOrNull()) |handle| {
                try self.pending.pushBack(self.allocator, .{
                    .handle = handle,
                    .value = fence,
                });
            }
        }

        /// Transfers all pending handles into the free state.
        fn waitIdle(self: *@This()) error{OutOfMemory}!void {
            while (self.pending.popFront()) |front| {
                try self.free.append(self.allocator, front.handle);
            }
        }

        /// Cancels the current recording, transfering the most recent recording handle to the free state.
        fn cancel(self: *@This()) error{OutOfMemory}!?T {
            const handle = self.recording.popOrNull() orelse return null;
            try self.free.append(self.allocator, handle);
            return handle;
        }
    };
}
