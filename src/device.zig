const std = @import("std");
const ArrayList = std.ArrayList;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const DynLib = std.DynLib;
const Allocator = std.mem.Allocator;

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

const DeviceDispatch = vk.DeviceWrapper(.{
    .destroyDevice = true,
});

/// Feature flags for device creation.
pub const DeviceFlags = packed struct {};

pub const DeviceConfig = struct {
    flags: DeviceFlags,
    adapter: Adapter,
};

pub const DeviceCreateError = error{
    OutOfMemory,
    OutOfDeviceMemory,
    NoSuitableAdapter,
    NoDirectQueue,
    Unknown,
};

pub const Device = struct {
    pub fn create(allocator: Allocator, instance: *const Instance, adapter: ?*const Adapter, config: DeviceConfig) DeviceCreateError!Device {
        _ = config;

        // ****************************
        // Find best physical device

        var physical_device: vk.PhysicalDevice = undefined;

        if (adapter) |a| {
            physical_device = a.handle;
        } else {
            const adapters: []Adapter = allocator.alloc(Adapter, instance.numAdapters());
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
        instance.vki.getPhysicalDeviceQueueFamilyProperties2(physical_device, &queue_family_count, null);

        const queue_families: []vk.QueueFamilyProperties2 = allocator.alloc(vk.QueueFamilyProperties2, @as(usize, queue_family_count));
        defer allocator.free(queue_families);

        instance.vki.getPhysicalDeviceQueueFamilyProperties2(physical_device, &queue_family_count, queue_families.ptr);

        var direct_family: ?u32 = null;
        var async_compute_family: ?u32 = null;
        var async_transfer_family: ?u32 = null;

        for (0..queue_family_count) |idx| {
            const props = queue_families[idx].queue_family_properties;

            if (props.queue_flags.transfer_bit and !props.queue_flags.compute_bit and !props.queue_flags.graphics_bit) {
                async_transfer_family = idx;
            } else if (props.queue_flags.compute_bit and !props.queue_flags.graphics_bit) {
                async_compute_family = idx;
            } else if (props.query_flags.graphics_bit) {
                direct_family = idx;
            }
        }

        if (direct_family == null) {
            return DeviceCreateError.NoDirectQueue;
        }

        queue_create_infos.append(
            allocator,
            vk.DeviceQueueCreateInfo{
                .queue_count = 1,
                .p_queue_priorities = &[_]f64{1.0},
                .queue_family_index = direct_family.?,
            },
        );

        if (async_compute_family) |family_index| {
            queue_create_infos.append(
                allocator,
                vk.DeviceQueueCreateInfo{
                    .queue_count = 1,
                    .p_queue_priorities = &[_]f64{1.0},
                    .queue_family_index = family_index,
                },
            );
        }

        if (async_transfer_family) |family_index| {
            queue_create_infos.append(
                allocator,
                vk.DeviceQueueCreateInfo{
                    .queue_count = 1,
                    .p_queue_priorities = &[_]f64{1.0},
                    .queue_family_index = family_index,
                },
            );
        }

        // ********************************
        // Create Device

        // TODO device layers for compatibility

        const create_info: vk.DeviceCreateInfo = .{
            .queue_create_info_count = @as(u32, @intCast(queue_create_infos.items.len)),
            .p_queue_create_infos = queue_create_infos.items.ptr,
            .enabled_extension_count = 0,
            .pp_enabled_extension_names = null,
            .enabled_layer_count = 0,
            .pp_enabled_layer_names = null,
        };
        _ = create_info;

        // const handle = instance.vki.createDevice(physical_device, &create_info, null);

    }

    pub fn destroy(self: *Device) void {
        self.* = undefined;
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
