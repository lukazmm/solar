const std = @import("std");
const ArrayList = std.ArrayList;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const DynLib = std.DynLib;
const Allocator = std.mem.Allocator;

const assert = std.debug.assert;
const panic = std.debug.panic;

const vk = @import("vulkan");

// *************************
// Device ******************
// *************************

const DeviceDispatch = vk.DeviceWrapper(.{
    .destroyDevice = true,
});
