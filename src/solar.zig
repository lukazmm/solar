const device = @import("device.zig");
const instance = @import("instance.zig");

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

test {
    _ = device;
    _ = instance;
}
