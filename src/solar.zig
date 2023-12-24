const device = @import("device.zig");
const func_buffer = @import("func_buffer.zig");
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
    _ = func_buffer;
    _ = instance;
    _ = queue;
}
