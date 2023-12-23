const builtin = @import("builtin");
const std = @import("std");
const ArrayList = std.ArrayList;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const DynLib = std.DynLib;
const Allocator = std.mem.Allocator;

const assert = std.debug.assert;
const panic = std.debug.panic;
const eql = std.mem.eql;
const span = std.mem.span;

const vk = @import("vulkan");

// ***************************
// Loader ********************
// ***************************

const BaseDispatch = vk.BaseWrapper(.{
    .createInstance = true,
    .getInstanceProcAddr = true,
    .enumerateInstanceExtensionProperties = true,
    .enumerateInstanceLayerProperties = true,
    .enumerateInstanceVersion = true,
});

/// Possible errors which could occur when attempting to find and load the Vulkan Loader.
pub const LoadError = error{
    MissingVulkanLoader,
    InvalidVulkanLoader,
    UnsupportedTarget,
};

// This provides an interface to register and bootstrap into the vulkan loader dynamically by loading
// `vkGetInstanceProcAddr` using dlsym (or equivalent).
pub const Loader = struct {
    vkb: BaseDispatch,
    lib: DynLib,

    /// Loads the `vkGetInstanceProcAddr` function by searching the given path (or if null a default set of paths
    /// depending on the target) for the appropriate dynamic library and loading the function pointer by name.
    /// This function then uses that function pointer to setup the dispatch table.
    pub fn open(path: ?[:0]const u8) LoadError!Loader {
        if (comptime DynLib == void) {
            return .UnsupportedTarget;
        }

        var lib: DynLib = loadDynLib(path) catch return LoadError.MissingVulkanLoader;
        errdefer lib.close();

        const vkGetProcAddress: vk.PfnGetInstanceProcAddr = lib.lookup(vk.PfnGetInstanceProcAddr, "vkGetInstanceProcAddr") orelse return LoadError.InvalidVulkanLoader;
        const vkb = BaseDispatch.loadNoFail(vkGetProcAddress);

        return .{
            .vkb = vkb,
            .lib = lib,
        };
    }

    /// Unloads the dynamic library and cleans up the dispatch table.
    pub fn close(loader: *Loader) void {
        loader.lib.close();
    }

    /// Retrieves the `vkGetInstanceProcAddr` function from this loader, which can be used to interacte
    /// with external loaders/alternate bindings.
    pub fn vkGetInstanceProcAddr(self: *const Loader) vk.PfnGetInstanceProcAddr {
        return self.vkb.dispatch.vkGetInstanceProcAddr;
    }

    // /// Enumerates the instance api version provided by the current loader.
    // pub fn instanceVersion(self: *const LoaderDynamic) u32 {
    //     return self.vkb.enumerateInstanceVersion() catch {
    //         panic("Unable to enumerate vulkan instance version\n", .{});
    //     };
    // }

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
                } else {
                    return err;
                }
            };

            return lib;
        }

        const lib = DynLib.open("libvulkan.so.1") catch |err| {
            if (err == error.FileNotFound) {
                return DynLib.open("libvulkan.so");
            } else {
                return err;
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
    .enumeratePhysicalDevices = true,
    .getPhysicalDeviceFeatures2 = true,
    .getPhysicalDeviceProperties2 = true,
});

/// Feature flags for instance creation.
pub const InstanceFlags = packed struct {
    /// If set to true, validation layers will be enabled (if available).
    validation: bool = (builtin.mode == .Debug),
};

/// Configuration details used to create an instance.
pub const InstanceConfig = struct {
    /// Flags defining instance to be created.
    flags: InstanceFlags = .{},
    /// Optional name of the application.
    app_name: ?[*:0]const u8 = null,
};

/// Potential errors during the creation of an instance.
pub const InstanceCreateError = error{
    OutOfMemory,
    FeatureNotSupported,
    IncompatibleDriver,
    Unknown,
};

/// Represents a vulkan instance, dispatch table, and interface to the physical display adapters.
/// Used for the creation of devices and surfaces, as well as for querying information about adapters.
pub const Instance = struct {
    // Allocator.
    gpa: Allocator,
    // Dispatch table.
    vki: InstanceDispatch,
    // Handles
    handle: vk.Instance,
    adapters: []vk.PhysicalDevice,

    /// Creates an instance.
    pub fn create(loader: *const Loader, allocator: Allocator, config: InstanceConfig) InstanceCreateError!Instance {
        // App Info
        const app_info: vk.ApplicationInfo = .{
            .p_application_name = config.app_name,
            .application_version = vk.API_VERSION_1_0,
            .p_engine_name = "Solar Framework",
            .engine_version = vk.API_VERSION_1_0,
            .api_version = vk.API_VERSION_1_3,
        };

        // ********************************
        // Extensions + Layers

        var supported_layers: []vk.LayerProperties = &.{};
        defer allocator.free(supported_layers);

        var supported_extensions: []vk.ExtensionProperties = &.{};
        defer allocator.free(supported_extensions);

        {
            // Layers
            var supported_layer_count: u32 = undefined;

            _ = loader.vkb.enumerateInstanceLayerProperties(&supported_layer_count, null) catch |err| {
                return switch (err) {
                    error.OutOfHostMemory => error.OutOfMemory,
                    else => error.Unknown,
                };
            };

            supported_layers = try allocator.alloc(vk.LayerProperties, @as(usize, supported_layer_count));

            _ = loader.vkb.enumerateInstanceLayerProperties(&supported_layer_count, supported_layers.ptr) catch |err| {
                return switch (err) {
                    error.OutOfHostMemory => error.OutOfMemory,
                    else => error.Unknown,
                };
            };

            // Extensions
            var supported_extension_count: u32 = undefined;

            _ = loader.vkb.enumerateInstanceExtensionProperties(null, &supported_extension_count, null) catch |err| {
                return switch (err) {
                    error.OutOfHostMemory => error.OutOfMemory,
                    else => error.Unknown,
                };
            };

            supported_extensions = try allocator.alloc(vk.ExtensionProperties, @as(usize, supported_extension_count));

            _ = loader.vkb.enumerateInstanceExtensionProperties(null, &supported_extension_count, supported_extensions.ptr) catch |err| {
                return switch (err) {
                    error.OutOfHostMemory => error.OutOfMemory,
                    else => error.Unknown,
                };
            };
        }

        var enabled_extensions = ArrayList([*:0]const u8).init(allocator);
        defer enabled_extensions.deinit();

        var enabled_layers = ArrayList([*:0]const u8).init(allocator);
        defer enabled_layers.deinit();

        if (config.flags.validation and supportsLayer(supported_layers, "VK_LAYER_KHRONOS_validation")) {
            try enabled_layers.append("VK_LAYER_KHRONOS_validation");
        }

        // ******************************
        // Create Instance

        const enabled_extension_count: u32 = @intCast(enabled_extensions.items.len);
        const pp_enabled_extensions: [*]const [*:0]const u8 = enabled_extensions.items.ptr;
        const enabled_layer_count: u32 = @intCast(enabled_layers.items.len);
        const pp_enabled_layers: [*]const [*:0]const u8 = enabled_layers.items.ptr;

        const create_info: vk.InstanceCreateInfo = .{
            .p_application_info = &app_info,
            .enabled_layer_count = enabled_layer_count,
            .pp_enabled_layer_names = pp_enabled_layers,
            .enabled_extension_count = enabled_extension_count,
            .pp_enabled_extension_names = pp_enabled_extensions,
        };

        const handle: vk.Instance = loader.vkb.createInstance(&create_info, null) catch |err| {
            return switch (err) {
                error.OutOfHostMemory => error.OutOfMemory,
                error.LayerNotPresent, error.ExtensionNotPresent => error.FeatureNotSupported,
                error.IncompatibleDriver => error.IncompatibleDriver,
                error.OutOfDeviceMemory, error.InitializationFailed, error.Unknown => error.Unknown,
            };
        };

        const vki: InstanceDispatch = InstanceDispatch.loadNoFail(handle, loader.vkb.dispatch.vkGetInstanceProcAddr);
        errdefer vki.destroyInstance(handle, null);

        // ********************************
        // Adapters

        // TODO portability enumeration

        const candidate_count = blk: {
            var res: u32 = undefined;
            _ = vki.enumeratePhysicalDevices(handle, &res, null) catch {
                return error.Unknown;
            };
            break :blk @as(usize, res);
        };

        const candidates = try allocator.alloc(vk.PhysicalDevice, candidate_count);
        defer allocator.free(candidates);

        {
            var count: u32 = @intCast(candidate_count);
            _ = vki.enumeratePhysicalDevices(handle, &count, candidates.ptr) catch {
                return error.Unknown;
            };
        }

        const AdapterScore = struct { score: usize, adapter: vk.PhysicalDevice };

        var adapter_map = try allocator.alloc(AdapterScore, candidate_count);
        defer allocator.free(adapter_map);

        for (0..candidate_count) |i| {
            adapter_map[i].adapter = candidates[i];
            adapter_map[i].score = scoreAdapter(vki, candidates[i]);
        }

        // Sort according to score

        const Ranker = struct {
            pub fn betterAdapter(_: void, lhs: AdapterScore, rhs: AdapterScore) bool {
                return lhs.score > rhs.score;
            }
        };

        std.sort.heap(AdapterScore, adapter_map, void{}, Ranker.betterAdapter);

        // Build slice of candidates which passed ranking

        var adapter_count: usize = candidate_count;

        while (adapter_count > 0) {
            if (adapter_map[adapter_count - 1].score > 0) {
                break;
            }

            adapter_count -= 1;
        }

        const adapters = try allocator.alloc(vk.PhysicalDevice, adapter_count);
        errdefer allocator.free(adapters);

        for (0..adapter_count) |i| {
            adapters[i] = adapter_map[i].adapter;
        }

        // ********************************

        return .{
            .gpa = allocator,
            .vki = vki,
            .handle = handle,
            .adapters = adapters,
        };
    }

    /// Destroys and frees an instance created using this loader.
    pub fn destroy(self: *Instance, _: *const Loader) void {
        self.gpa.free(self.adapters);
        self.vki.destroyInstance(self.handle, null);
        self.* = undefined;
    }

    pub fn numAdapters(self: *const Instance) usize {
        return self.adapters.len;
    }

    pub fn adapterInfo(self: *const Instance, idx: usize) AdapterInfo {
        assert(idx < self.numAdapters());

        // Adapter corresponding to the given index
        const adapter = self.adapters[idx];

        // var features: vk.PhysicalDeviceFeatures2 = .{};
        // self.vki.getPhysicalDeviceFeatures2(adapter, &features);

        var properties: vk.PhysicalDeviceProperties2 = .{ .properties = undefined };
        self.vki.getPhysicalDeviceProperties2(adapter, &properties);

        // const feats10 = features.features;
        // _ = feats10;
        const props10 = properties.properties;

        var info: AdapterInfo = undefined;
        info.name = props10.device_name;
        info.kind = switch (props10.device_type) {
            .discrete_gpu => .discrete,
            .integrated_gpu => .integrated,
            .virtual_gpu => .virtual,
            .cpu => .software,
            else => .other,
        };

        return info;
    }

    fn scoreAdapter(vki: InstanceDispatch, adapter: vk.PhysicalDevice) usize {
        var props: vk.PhysicalDeviceProperties2 = .{ .properties = undefined };
        vki.getPhysicalDeviceProperties2(adapter, &props);

        const props10 = props.properties;

        var score: usize = 1;

        // Discrete GPUs have a large performance advantage
        if (props10.device_type == .discrete_gpu) {
            score += 1000;
        }

        // Integrated gpus are still better than software rendering
        if (props10.device_type == .integrated_gpu) {
            score += 100;
        }

        // Vulkan 1.3 must be supported
        if (props10.api_version < vk.API_VERSION_1_3) {
            score = 0;
        }

        return score;
    }

    fn supportsExtension(extensions: []vk.ExtensionProperties, ext: [*:0]const u8) bool {
        for (extensions) |extension| {
            const name: [*:0]const u8 = @ptrCast(&extension.name);

            if (eql(u8, span(name), span(ext))) {
                return true;
            }
        }

        return false;
    }

    fn supportsLayer(layers: []vk.LayerProperties, lay: [*:0]const u8) bool {
        for (layers) |layer| {
            const name: [*:0]const u8 = @ptrCast(&layer.layer_name);

            if (eql(u8, span(name), span(lay))) {
                return true;
            }
        }

        return false;
    }
};

// ****************************************
// Adapter Info ***************************
// ****************************************

pub const AdapterKind = enum {
    integrated,
    discrete,
    virtual,
    software,
    other,
};

pub const MaxAdapterNameSize = vk.MAX_PHYSICAL_DEVICE_NAME_SIZE;

pub const AdapterInfo = struct {
    name: [MaxAdapterNameSize]u8,
    kind: AdapterKind,

    pub fn format(value: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) std.os.WriteError!void {
        const name: [*:0]const u8 = @ptrCast(&value.name);
        try writer.print("Display Adapter: {s}\n", .{span(name)});

        switch (value.kind) {
            .integrated => try writer.print("  Integrated GPU", .{}),
            .discrete => try writer.print("  Discrete GPU", .{}),
            .virtual => try writer.print("  Virtual GPU", .{}),
            .software => try writer.print("  Software GPU", .{}),
            .other => try writer.print("  Unknown GPU Type", .{}),
        }
    }
};
