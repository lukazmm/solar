# Solar

`Solar` is a low-level cross platform gpu framework built over Vulkan 1.3 using `Snektron`'s vulkan bindings for `zig`. I am currently focused on making this project suitable for GPGPU work, but will hopefully be able to later add some utilities for handling surfaces and swapchains.

# Design Goals

This project seeks to simplify some of the (in my opinion) strange aspects of the Vulkan API, removing some of the annoying constructs and boilerplate. In a sense this is my _ideal_ graphics + compute API, merging the best aspects of Vulkan, D3D12, and Metal, while providing some utilty features (such as less tedious memory management using the `Vulkan Memory Allocator` library).

Note, currently all third party libraries are copied inline into the `vendor/` directory. This will change once `zig`'s package management situation becomes a bit more stable (for instance, after the release of `0.12` or `0.13`).