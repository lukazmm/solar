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

    /// Enumerates the instance api version provided by the current loader.
    fn instanceVersion(self: *const Loader) u32 {
        return self.vkb.enumerateInstanceVersion() catch {
            panic("Unable to enumerate vulkan instance version\n", .{});
        };
    }

    /// Retrieves supported instance layers
    fn supportedLayers(self: *const Loader, allocator: Allocator) ![]vk.LayerProperties {
        var supported_layer_count: u32 = undefined;

        _ = self.vkb.enumerateInstanceLayerProperties(&supported_layer_count, null) catch |err| {
            return switch (err) {
                error.OutOfHostMemory => error.OutOfMemory,
                else => error.Unknown,
            };
        };

        const supported_layers = try allocator.alloc(vk.LayerProperties, @as(usize, supported_layer_count));
        errdefer allocator.free(supported_layers);

        _ = self.vkb.enumerateInstanceLayerProperties(&supported_layer_count, supported_layers.ptr) catch |err| {
            return switch (err) {
                error.OutOfHostMemory => error.OutOfMemory,
                else => error.Unknown,
            };
        };

        return supported_layers;
    }

    /// Retrieves supported instance extensions.
    fn supportedExtensions(self: *const Loader, allocator: Allocator, layer_name: ?[*:0]const u8) ![]vk.ExtensionProperties {
        var supported_ext_count: u32 = undefined;

        _ = self.vkb.enumerateInstanceExtensionProperties(layer_name, &supported_ext_count, null) catch |err| {
            return switch (err) {
                error.OutOfHostMemory => error.OutOfMemory,
                else => error.Unknown,
            };
        };

        const supported_exts = try allocator.alloc(vk.ExtensionProperties, @as(usize, supported_ext_count));
        errdefer allocator.free(supported_exts);

        _ = self.vkb.enumerateInstanceExtensionProperties(layer_name, &supported_ext_count, supported_exts.ptr) catch |err| {
            return switch (err) {
                error.OutOfHostMemory => error.OutOfMemory,
                else => error.Unknown,
            };
        };

        return supported_exts;
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
    .getPhysicalDeviceQueueFamilyProperties = true,
    .createDevice = true,
    .getDeviceProcAddr = true,
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

    // Config
    layers: ArrayListUnmanaged([*:0]const u8),
    extensions: ArrayListUnmanaged([*:0]const u8),

    /// Creates a new instance from the given configuration. The loader must outlive this instance.
    pub fn create(allocator: Allocator, loader: *const Loader, config: InstanceConfig) InstanceCreateError!Instance {
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

        const supported_layers = try loader.supportedLayers(allocator);
        defer allocator.free(supported_layers);

        const supported_extensions = try loader.supportedExtensions(allocator, null);
        defer allocator.free(supported_extensions);

        // Enabled
        var enabled_extensions: ArrayListUnmanaged([*:0]const u8) = .{};
        errdefer enabled_extensions.deinit(allocator);

        var enabled_layers: ArrayListUnmanaged([*:0]const u8) = .{};
        errdefer enabled_layers.deinit(allocator);

        if (config.flags.validation and supportsLayer(supported_layers, "VK_LAYER_KHRONOS_validation")) {
            try enabled_layers.append(allocator, "VK_LAYER_KHRONOS_validation");
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

        const candidates = try allocPhysicalDevices(allocator, vki, handle);
        defer allocator.free(candidates);

        var adapters: ArrayListUnmanaged(vk.PhysicalDevice) = .{};
        errdefer adapters.deinit(allocator);

        for (candidates) |candidate| {
            if (isPhysicalDeviceSuitable(vki, candidate)) {
                try adapters.append(allocator, candidate);
            }
        }

        const adapters_owned = try adapters.toOwnedSlice(allocator);

        // ********************************

        return .{
            .gpa = allocator,
            .vki = vki,
            .handle = handle,
            .adapters = adapters_owned,
            .extensions = enabled_extensions,
            .layers = enabled_layers,
        };
    }

    /// Destroys and frees an instance. The loader used to create the instance must still be alive.
    pub fn destroy(self: *Instance) void {
        self.layers.deinit(self.gpa);
        self.extensions.deinit(self.gpa);

        self.gpa.free(self.adapters);

        self.vki.destroyInstance(self.handle, null);

        self.* = undefined;
    }

    /// Returns the number of valid adapters that can be enumerated by this instance.
    pub fn numAdapters(self: *const Instance) usize {
        return self.adapters.len;
    }

    /// Retrieves the adapter handle and properties corresponding to the given index.
    pub fn enumerateAdapters(self: *const Instance, idx: usize) Adapter {
        // Assert index in bounds
        assert(idx < self.numAdapters());
        // Retrieve adapter handle
        const handle = self.adapters[idx];
        // Get Properties
        var properties: vk.PhysicalDeviceProperties2 = .{ .properties = undefined };
        self.vki.getPhysicalDeviceProperties2(handle, &properties);

        // Get Vk 1.0 properties
        const props10 = properties.properties;
        const name = props10.device_name;
        const kind: AdapterKind = switch (props10.device_type) {
            .discrete_gpu => .discrete,
            .integrated_gpu => .integrated,
            .virtual_gpu => .virtual,
            .cpu => .software,
            else => .unknown,
        };

        return .{
            .handle = self.adapters[idx],
            .m_name = name,
            .m_kind = kind,
        };
    }

    /// Helper function to enumerate physical devices
    fn allocPhysicalDevices(allocator: Allocator, vki: InstanceDispatch, instance: vk.Instance) ![]vk.PhysicalDevice {
        var physical_device_count: u32 = undefined;

        _ = vki.enumeratePhysicalDevices(instance, &physical_device_count, null) catch {
            return error.Unknown;
        };

        const physical_devices = try allocator.alloc(vk.PhysicalDevice, @as(usize, physical_device_count));
        errdefer allocator.free(physical_devices);

        _ = vki.enumeratePhysicalDevices(instance, &physical_device_count, physical_devices.ptr) catch {
            return error.Unknown;
        };

        return physical_devices;
    }

    /// Helper function to determine if the physical device supports the minimum API version.
    fn isPhysicalDeviceSuitable(vki: InstanceDispatch, handle: vk.PhysicalDevice) bool {
        var props: vk.PhysicalDeviceProperties2 = .{ .properties = undefined };
        vki.getPhysicalDeviceProperties2(handle, &props);

        const props10 = props.properties;

        return props10.api_version >= vk.API_VERSION_1_3;
    }

    /// Helper function for determining if an extension is supported by this instance.
    fn supportsExtension(extensions: []vk.ExtensionProperties, ext: [*:0]const u8) bool {
        for (extensions) |extension| {
            const name: [*:0]const u8 = @ptrCast(&extension.name);

            if (eql(u8, span(name), span(ext))) {
                return true;
            }
        }

        return false;
    }

    /// Helper function to determin if a layer is supported by this instance.
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

/// Used for storing adapter names inline.
pub const MaxAdapterNameSize = vk.MAX_PHYSICAL_DEVICE_NAME_SIZE;

/// Enumeration of the various kinds of adapters.
pub const AdapterKind = enum {
    /// An adapter which is integrated into the cpu chip (often sharing ram and other resources).
    integrated,
    /// An adapter connected by PCIe bus.
    discrete,
    /// An adapter in a virtual enviornment.
    virtual,
    /// A software renderer.
    software,
    /// An unknown adapter kind.
    unknown,
};

/// Represents a physical display adapter enumerated by the instance.
pub const Adapter = struct {
    /// Handle to underlying vkPhysicalDevice
    handle: vk.PhysicalDevice,
    /// An inline storage buffer for the name of the adapter
    m_name: [MaxAdapterNameSize]u8,
    m_kind: AdapterKind,

    pub fn name(self: *const Adapter) [:0]const u8 {
        const m_name: [*:0]const u8 = @ptrCast(&self.m_name);
        return span(m_name);
    }

    pub fn kind(self: Adapter) AdapterKind {
        return self.m_kind;
    }

    pub fn format(self: *const @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) std.os.WriteError!void {
        try writer.print("Display Adapter: {s}\n", .{self.name()});

        switch (self.kind()) {
            .integrated => try writer.print("  Integrated GPU", .{}),
            .discrete => try writer.print("  Discrete GPU", .{}),
            .virtual => try writer.print("  Virtual GPU", .{}),
            .software => try writer.print("  Software GPU", .{}),
            .unknown => try writer.print("  Unknown GPU Type", .{}),
        }
    }
};
