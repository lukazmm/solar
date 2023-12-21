const builtin = @import("builtin");
const std = @import("std");
const DynLib = std.DynLib;

const vk = @import("vulkan");

pub const BaseDispatch = vk.BaseWrapper(.{
    .createInstance = true,
    .getInstanceProcAddr = true,
    .enumerateInstanceExtensionProperties = true,
    .enumerateInstanceLayerProperties = true,
    .enumerateInstanceVersion = true,
});

// This provides an interface to register and bootstrap into the vulkan loader dynamically by loading
// `vkGetInstanceProcAddr` using dlsym (or equivalent).
pub const LoaderDynamic = struct {
    vkb: BaseDispatch,
    lib: DynLib,

    pub const Error = error{
        MissingVulkanLoader,
        UnsupportedTarget,
    };

    /// Loads the `vkGetInstanceProcAddr` function by searching the given path (or if null a default set of paths
    /// depending on the target) for the appropriate dynamic library and loading the function pointer by name.
    /// This function then uses that function pointer to setup the dispatch table.
    pub fn open(path: ?[:0]const u8) Error!LoaderDynamic {
        if (comptime DynLib == void) {
            return .UnsupportedTarget;
        }

        const lib: DynLib = loadDynLib(path) catch return .MissingVulkanLoader;
        errdefer lib.close();

        const vkGetProcAddress: vk.PfnGetInstanceProcAddr = lib.lookup(vk.PfnGetInstanceProcAddr, "vkGetInstanceProcAddr") orelse return .CommandLoadFailure;
        const vkb = BaseDispatch.loadNoFail(vkGetProcAddress);

        return .{
            .vkb = vkb,
            .lib = lib,
        };
    }

    /// Unloads the dynamic library and cleans up the dispatch table.
    pub fn close(loader: *LoaderDynamic) void {
        loader.lib.close();
    }

    /// Retrieves the `vkGetInstanceProcAddr` function from this loader, which can be used to interacte
    /// with external loaders/alternate bindings.
    pub fn vkGetInstanceProcAddr(self: *const LoaderDynamic) vk.PfnGetInstanceProcAddr {
        return self.vkb.dispatch.vkGetInstanceProcAddr;
    }

    /// Enumerates the instance api version provided by the current loader.
    pub fn instanceVersion(self: *const LoaderDynamic) !u32 {
        return self.vkb.enumerateInstanceVersion();
    }

    /// Finds the number of known extensions for a given layer. See `vkEnumerateInstanceExtensionProperties`.
    pub fn instanceExtensionCount(self: *const LoaderDynamic, layer_name: ?[*:0]const u8) !u32 {
        var result: u32 = undefined;
        try self.vkb.enumerateInstanceExtensionProperties(layer_name, &result, null);
        return result;
    }

    /// Overrides the extensions slice with information about each supported instance extension.
    pub fn instanceEnumerateExtensions(self: *const LoaderDynamic, layer_name: ?[*:0]const u8, extensions: []vk.ExtensionProperties) !void {
        try self.vkb.enumerateInstanceExtensionProperties(layer_name, extensions.len, extensions.ptr);
    }

    /// Finds the number of known layers. See `vkEnumerateInstanceLayerProperties`.
    pub fn instanceLayerCount(self: *const LoaderDynamic) !u32 {
        var result: u32 = undefined;
        try self.vkb.enumerateInstanceLayerProperties(&result, null);
        return result;
    }

    /// Overrides the layers slice with information about each supported instance layer.
    pub fn instanceEnumerateLayers(self: *const LoaderDynamic, layers: []vk.LayerProperties) !void {
        try self.vkb.enumerateInstanceLayerProperties(layers.len, layers.ptr);
    }

    /// Creates an instance.
    pub fn createInstance(self: *const LoaderDynamic, info: InstanceCreateInfo) !Instance {
        const create_info: vk.InstanceCreateInfo = .{
            .enabled_extension_count = info.extensions.len,
            .pp_enabled_extension_names = info.extensions.ptr,
            .enabled_layer_count = info.layers.len,
            .pp_enabled_layer_names = info.layers.ptr,
        };

        const handle: vk.Instance = try self.vkb.createInstance(&create_info, null);

        const vki: InstanceDispatch = try InstanceDispatch.load(handle, self.vkb.dispatch.vkGetInstanceProcAddr);
        errdefer vki.destroyInstance(handle, null);

        return .{
            .vki = vki,
            .handle = handle,
        };
    }

    /// Destroys and frees an instance created using this loader.
    pub fn destroyInstance(_: *const LoaderDynamic, instance: *Instance) void {
        instance.vki.destroyInstance(instance.handle, null);
    }

    /// A helper function for loading the appropriate dynamic library.
    fn loadDynLib(path: ?[]const u8) !DynLib {
        if (path) |p| {
            return DynLib.open(p);
        }

        if (builtin.os.tag == .windows) {
            return DynLib.open("vulkan-1.dll");
        }

        if (builtin.os.tag.isDarwin()) {
            const lib = DynLib.open("libvulkan.1.dylib") catch |err| {
                if (err == .FileNotFound) {
                    return DynLib.open("libMoltenVK.dylib");
                }
            };

            return lib;
        }

        const lib = DynLib.open("libvulkan.so.1") catch |err| {
            if (err == .FileNotFound) {
                return DynLib.open("libvulkan.so");
            }
        };

        return lib;
    }
};

// *********************************
// Instance ************************
// *********************************

const InstanceDispatch = vk.InstanceWrapper(.{
    .destroyInstance = true,
});

pub const InstanceCreateInfo = struct {
    name: [*:0]const u8,
    layers: []const [*:0]const u8 = .{},
    extensions: []const [*:0]const u8 = .{},
};

pub const Instance = struct {
    // Dispatch
    vki: InstanceDispatch,
    // Handles
    handle: vk.Instance,
};
