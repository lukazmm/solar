const std = @import("std");
const span = std.mem.span;
const panic = std.debug.panic;

const solar = @import("solar");
const Loader = solar.Loader;
const Instance = solar.Instance;

pub fn main() !void {
    // Setup Allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();

        if (deinit_status == .leak) {
            std.debug.print("Runtime data leak detected\n", .{});
        }
    }

    const allocator = gpa.allocator();

    // Skip on line
    std.debug.print("\n", .{});

    // ***************************
    // Loader

    var loader = Loader.open(null) catch |err| {
        panic("Unable to find Vulkan Loader .{}\n", .{err});
    };
    defer loader.close();

    std.debug.print("Found Vulkan Loader\n", .{});

    // **************************
    // Instance

    var instance = try Instance.create(&loader, allocator, .{});
    defer instance.destroy(&loader);

    std.debug.print("Created Vulkan Instance\n", .{});
    std.debug.print("Num Adapters: {}\n", .{instance.numAdapters()});

    for (0..instance.numAdapters()) |i| {
        const info = instance.adapterInfo(i);

        std.debug.print("\n{}\n", .{info});
    }
}
