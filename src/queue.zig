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

const Deque = @import("utils/deque.zig").Deque;

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
        pending: ArrayListUnmanaged(T),
        inflight: Deque(Flight),

        const Flight = struct {
            handle: T,
            value: usize,
        };

        fn submit(self: *@This(), fence: usize) error{OutOfMemory}!void {
            while (self.pending.popOrNull()) |handle| {
                try self.inflight.pushBack(.{
                    .handle = handle,
                    .value = fence,
                });
            }
        }

        fn reset(self: @This(), fence: usize) error{OutOfMemory}!void {
            while (self.inflight.front()) |front| {
                if (front.value > fence) {
                    break;
                }

                try self.free.append(self.allocator, self.inflight.popFront().?);
            }
        }
    };
}
