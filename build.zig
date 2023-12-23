const std = @import("std");
const vkgen = @import("vendor/vulkan-zig/generator/index.zig");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    // Add vulkan binding generation step
    const path = std.os.getenv("VULKAN_SDK");
    const gen = vkgen.VkGenerateStep.createFromSdk(b, path.?);

    // Get solar module
    const module = b.addModule("solar", .{
        .source_file = .{ .path = "src/solar.zig" },
        .dependencies = &.{.{
            .name = "vulkan",
            .module = gen.getModule(),
        }},
    });

    // ***********************
    // Build Static Library **
    // ***********************

    const lib = b.addStaticLibrary(.{
        .name = "solar",
        .root_source_file = .{ .path = "src/solar.zig" },
        .target = target,
        .optimize = optimize,
    });

    // Mainly for dlopen (may be able to remove at some point)
    lib.linkLibC();

    // Modules
    lib.addModule("vulkan", gen.getModule());

    // This declares intent for the library to be installed into the standard
    // location when the user invokes the "install" step (the default step when
    // running `zig build`).
    b.installArtifact(lib);

    // **************************
    // Tests ********************
    // **************************

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const tests = b.addTest(.{
        .root_source_file = .{ .path = "src/solar.zig" },
        .target = target,
        .optimize = optimize,
    });

    tests.addModule("vulkan", gen.getModule());

    const run_tests = b.addRunArtifact(tests);

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build test`
    // This will evaluate the `test` step rather than the default, which is "install".
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_tests.step);

    // **************************
    // Example ******************
    // **************************

    const example = b.addExecutable(.{
        .name = "example",
        .root_source_file = .{ .path = "examples/example.zig" },
        .target = target,
        .optimize = optimize,
    });
    // Enable libC
    example.linkLibC();
    // Dependent modules
    example.addModule("solar", module);
    // Install artifact
    b.installArtifact(example);

    // Add run command
    const run_example_cmd = b.addRunArtifact(example);
    run_example_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_example_cmd.addArgs(args);
    }

    const run_step = b.step("run-example", "Run the solar vk example");
    run_step.dependOn(&run_example_cmd.step);
}
