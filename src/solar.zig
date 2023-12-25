const device = @import("device.zig");
const instance = @import("instance.zig");
const queue = @import("queue.zig");

// ***************************
// Instance

pub const Loader = instance.Loader;

pub const Instance = instance.Instance;
pub const InstanceConfig = instance.InstanceConfig;
pub const InstanceFlags = instance.InstanceFlags;
pub const InstanceCreateError = instance.InstanceCreateError;

pub const Adapter = instance.Adapter;
pub const AdapterKind = instance.AdapterKind;

// ***************************
// Device

pub const Device = device.Device;
pub const DeviceConfig = device.DeviceConfig;
pub const DeviceFlags = device.DeviceFlags;

// ****************************
// Queue

pub const QueueConfig = queue.QueueConfig;
pub const QueueKind = queue.QueueKind;

test {
    _ = device;
    _ = instance;
    _ = queue;
    _ = @import("utils/deque.zig");
    _ = @import("utils/func_buffer.zig");
    _ = @import("utils/ring_buffer.zig");
}
