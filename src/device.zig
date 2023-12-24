const std = @import("std");
const ArrayList = std.ArrayList;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const Allocator = std.mem.Allocator;
const Mutex = std.Thread.Mutex;

const assert = std.debug.assert;
const panic = std.debug.panic;

const vk = @import("vulkan");

// Other modules
const instance_ = @import("instance.zig");
const Instance = instance_.Instance;
const Adapter = instance_.Adapter;

// *************************
// Device ******************
// *************************

// pub const QueueKind = enum {
//     direct,
//     async_compute,
//     async_transfer,
// };

const DeviceDispatch = vk.DeviceWrapper(.{
    .destroyDevice = true,
    .deviceWaitIdle = true,
    .getDeviceQueue = true,
    .queueSubmit2 = true,
});

/// Feature flags for device creation.
pub const DeviceFlags = packed struct {};

pub const DeviceConfig = struct {
    flags: DeviceFlags = .{},
};

pub const DeviceCreateError = error{
    OutOfMemory,
    OutOfDeviceMemory,
    NoSuitableAdapter,
    NoDirectQueue,
    FeatureNotSupported,
    Lost,
    Unknown,
};

pub const Device = struct {
    // Dispatch
    vkd: DeviceDispatch,
    // Handle
    handle: vk.Device,
    // Queues
    direct: vk.Queue,
    direct_family: u32,
    direct_mutex: usize,

    async_compute: vk.Queue,
    async_compute_family: u32,
    async_compute_mutex: usize,

    async_transfer: vk.Queue,
    async_transfer_family: u32,
    async_transfer_mutex: usize,

    // Mutexes
    mutexes: [3]Mutex,

    pub fn create(allocator: Allocator, instance: *const Instance, adapter: ?*const Adapter, config: DeviceConfig) DeviceCreateError!Device {
        _ = config;

        // ****************************
        // Find best physical device

        var physical_device: vk.PhysicalDevice = undefined;

        if (adapter) |a| {
            physical_device = a.handle;
        } else {
            const adapters: []Adapter = try allocator.alloc(Adapter, instance.numAdapters());
            defer allocator.free(adapters);

            for (0..instance.numAdapters()) |i| {
                adapters[i] = instance.enumerateAdapters(i);
            }

            const Scorer = struct {
                pub fn betterAdapter(_: void, lhs: Adapter, rhs: Adapter) bool {
                    return scoreAdapter(&lhs) > scoreAdapter(&rhs);
                }
            };

            std.sort.heap(Adapter, adapters, void{}, Scorer.betterAdapter);

            if (adapters.len > 0 and isAdapterSuitable(&adapters[0])) {
                physical_device = adapters[0].handle;
            } else {
                return DeviceCreateError.NoSuitableAdapter;
            }
        }

        // ********************************
        // Queues

        var queue_create_infos: ArrayListUnmanaged(vk.DeviceQueueCreateInfo) = .{};
        defer queue_create_infos.deinit(allocator);

        // Get queue families
        var queue_family_count: u32 = undefined;
        instance.vki.getPhysicalDeviceQueueFamilyProperties(physical_device, &queue_family_count, null);

        const queue_families = try allocator.alloc(vk.QueueFamilyProperties, @as(usize, queue_family_count));
        defer allocator.free(queue_families);

        instance.vki.getPhysicalDeviceQueueFamilyProperties(physical_device, &queue_family_count, queue_families.ptr);

        var direct_family: ?u32 = null;
        var async_compute_family: ?u32 = null;
        var async_transfer_family: ?u32 = null;

        for (0..queue_family_count) |idx| {
            const family_index = @as(u32, @intCast(idx));
            const props = queue_families[idx];

            if (props.queue_flags.transfer_bit and !props.queue_flags.compute_bit and !props.queue_flags.graphics_bit) {
                async_transfer_family = family_index;
            } else if (props.queue_flags.compute_bit and !props.queue_flags.graphics_bit) {
                async_compute_family = family_index;
            } else if (props.queue_flags.graphics_bit) {
                direct_family = family_index;
            }
        }

        if (direct_family == null) {
            return DeviceCreateError.NoDirectQueue;
        }

        try queue_create_infos.append(
            allocator,
            vk.DeviceQueueCreateInfo{
                .queue_count = 1,
                .p_queue_priorities = &[_]f32{1.0},
                .queue_family_index = direct_family.?,
            },
        );

        if (async_compute_family) |family_index| {
            try queue_create_infos.append(
                allocator,
                vk.DeviceQueueCreateInfo{
                    .queue_count = 1,
                    .p_queue_priorities = &[_]f32{1.0},
                    .queue_family_index = family_index,
                },
            );
        }

        if (async_transfer_family) |family_index| {
            try queue_create_infos.append(
                allocator,
                vk.DeviceQueueCreateInfo{
                    .queue_count = 1,
                    .p_queue_priorities = &[_]f32{1.0},
                    .queue_family_index = family_index,
                },
            );
        }

        // ********************************
        // Create Device

        const create_info: vk.DeviceCreateInfo = .{
            .queue_create_info_count = @as(u32, @intCast(queue_create_infos.items.len)),
            .p_queue_create_infos = queue_create_infos.items.ptr,
            // Currently we enable no extensions.
            .enabled_extension_count = 0,
            .pp_enabled_extension_names = null,
            // Device layers enabled for compatibility with old drivers (pre device layer deprecation).
            .enabled_layer_count = @as(u32, @intCast(instance.layers.items.len)),
            .pp_enabled_layer_names = instance.layers.items.ptr,
        };

        const handle = instance.vki.createDevice(physical_device, &create_info, null) catch |err| {
            return switch (err) {
                error.OutOfHostMemory => error.OutOfMemory,
                error.OutOfDeviceMemory => error.OutOfDeviceMemory,
                error.DeviceLost => error.Lost,
                error.ExtensionNotPresent, error.FeatureNotPresent => error.FeatureNotSupported,
                else => error.Unknown,
            };
        };

        const vkd = DeviceDispatch.loadNoFail(handle, instance.vki.dispatch.vkGetDeviceProcAddr);
        errdefer vkd.destroyDevice(handle, null);

        // **********************
        // Retrieve Queues

        const direct_index: u32 = direct_family.?;
        const direct_mutex: usize = 0;

        var async_compute_index: u32 = undefined;
        var async_compute_mutex: usize = undefined;

        if (async_compute_family) |index| {
            async_compute_index = index;
            async_compute_mutex = 1;
        } else {
            async_compute_index = direct_index;
            async_compute_mutex = direct_mutex;
        }

        var async_transfer_index: u32 = undefined;
        var async_transfer_mutex: usize = undefined;

        if (async_transfer_family) |index| {
            async_transfer_index = index;
            async_transfer_mutex = 2;
        } else {
            async_transfer_index = direct_index;
            async_transfer_mutex = direct_mutex;
        }

        const direct = vkd.getDeviceQueue(handle, direct_index, 0);
        const async_compute = vkd.getDeviceQueue(handle, async_compute_index, 0);
        const async_transfer = vkd.getDeviceQueue(handle, async_transfer_index, 0);

        // *******************************

        return .{
            .vkd = vkd,
            .handle = handle,

            .direct = direct,
            .direct_family = direct_index,
            .direct_mutex = direct_mutex,

            .async_compute = async_compute,
            .async_compute_family = async_compute_index,
            .async_compute_mutex = async_compute_mutex,

            .async_transfer = async_transfer,
            .async_transfer_family = async_transfer_index,
            .async_transfer_mutex = async_transfer_mutex,

            .mutexes = [3]Mutex{ .{}, .{}, .{} },
        };
    }

    pub fn destroy(self: *Device) void {
        // Wait Idle (if possible)
        self.vkd.deviceWaitIdle(self.handle) catch {};
        // Destroy device
        self.vkd.destroyDevice(self.handle, null);
        // Invalidate handle
        self.* = undefined;
    }

    pub fn vkDirectSubmit(self: *const Device, submit_info: vk.SubmitInfo2) !void {
        self.mutexes[self.direct_mutex].lock();
        try self.vkd.queueSubmit2(self.direct, 1, &submit_info, .null_handle);
        self.mutexes[self.direct_mutex].unlock();
    }

    pub fn vkAsyncComputeSubmit(self: *const Device, submit_info: vk.SubmitInfo2) !void {
        self.mutexes[self.async_compute_mutex].lock();
        try self.vkd.queueSubmit2(self.async_compute, 1, &submit_info, .null_handle);
        self.mutexes[self.async_compute_mutex].unlock();
    }

    pub fn vkAsyncTransferSubmit(self: *const Device, submit_info: vk.SubmitInfo2) !void {
        self.mutexes[self.async_transfer_mutex].lock();
        try self.vkd.queueSubmit2(self.async_transfer, 1, &submit_info, .null_handle);
        self.mutexes[self.async_transfer_mutex].unlock();
    }

    fn scoreAdapter(adapter: *const Adapter) usize {
        var score: usize = 0;

        // Discrete GPUs have a large performance advantage
        if (adapter.kind() == .discrete) {
            score += 1000;
        }

        // Integrated gpus are still better than software rendering
        if (adapter.kind() == .integrated) {
            score += 100;
        }

        return score;
    }

    fn isAdapterSuitable(_: *const Adapter) bool {
        return true;
    }
};
