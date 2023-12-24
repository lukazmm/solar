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

pub const QueueKind = enum {
    direct,
    async_compute,
    async_transfer,
};

pub const QueueConfig = struct {
    kind: QueueKind,
};

pub const Queue = struct {
    timeline: vk.Semaphore,
};
