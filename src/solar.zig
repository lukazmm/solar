const device = @import("device.zig");
const instance = @import("instance.zig");

pub const Loader = instance.Loader;

pub const Instance = instance.Instance;
pub const InstanceConfig = instance.InstanceConfig;
pub const InstanceFlags = instance.InstanceFlags;
pub const InstanceCreateError = instance.InstanceCreateError;

pub const AdapterKind = instance.AdapterKind;
pub const AdapterInfo = instance.AdapterInfo;

test {
    _ = device;
    _ = instance;
}
