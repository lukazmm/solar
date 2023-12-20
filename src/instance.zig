const builtin = @import("builtin");
const std = @import("std");

const vk = @import("vulkan");

const BaseDispatch = vk.BaseWrapper(.{
    .createInstance = true,
    .getInstanceProcAddr = true,
    .enumerateInstanceExtensionProperties = true,
    .enumerateInstanceLayerProperties = true,
    .enumerateInstanceVersion = true,
});

const InstanceDispatch = vk.InstanceWrapper(.{});

pub const Instance = struct {
    // Dispatch
    vkb: BaseDispatch,
    vki: InstanceDispatch,

    // Inner types
    instance: vk.Instance,

    pub const InstanceCreateError = error{
        load_error,
    };

    pub fn create() !void {
        // TODO work on multiple platforms

        const RTLD = std.c.RTLD;

        const module = std.c.dlopen("libvulkan.so", RTLD.LOCAL | RTLD.LAZY) orelse return .load_error;
        const addr = std.c.dlsym(module, "vkGetInstanceProcAddr");
        const vkb = try BaseDispatch.load(addr);
        _ = vkb;
    }
};
