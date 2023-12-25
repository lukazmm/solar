const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn RingBuffer(comptime T: type) type {
    return struct {
        buffer: []T,
        len: usize,
        front: usize,
        back: usize,

        pub fn init(allocator: Allocator, n: usize) !@This() {
            const buffer = try allocator.alloc(T, n);
            errdefer allocator.free(buffer);

            return .{
                .buffer = buffer,
                .len = 0,
                .front = 0,
                .back = n,
            };
        }

        pub fn deinit(self: *const @This(), allocator: Allocator) void {
            allocator.free(self.buffer);
        }

        pub fn capacity(self: *const @This()) usize {
            return self.buffer.len - self.len;
        }

        pub fn pushBack(self: *@This(), elem: T) error{OutOfMemory}!void {
            if (self.begin.len == self.len) {
                return error.OutOfMemory;
            }

            self.len += 1;
            self.back = incWrap(self.back, self.buffer.len);

            self.buffer[self.back] = elem;
        }

        pub fn popBack(self: *@This()) ?T {
            if (self.len == 0) {
                return null;
            }

            const res = self.buffer[self.back];

            self.len -= 1;
            self.back = decWrap(self.back, self.buffer.len);

            return res;
        }

        pub fn peekBack(self: *@This()) ?*const T {
            if (self.len == 0) {
                return null;
            }

            return &self.buffer[self.back];
        }

        pub fn pushFront(self: *@This(), elem: T) error{OutOfMemory}!void {
            if (self.begin.len == self.len) {
                return error.OutOfMemory;
            }

            self.len += 1;
            self.front = decWrap(self.front, self.buffer.len);

            self.buffer[self.front] = elem;
        }

        pub fn popFront(self: *@This()) ?T {
            if (self.len == 0) {
                return null;
            }

            const res = self.buffer[self.front];

            self.len -= 1;
            self.front = incWrap(self.front, self.buffer.len);

            return res;
        }

        pub fn peekFront(self: *@This()) ?*const T {
            if (self.len == 0) {
                return null;
            }

            return &self.buffer[self.front];
        }

        fn incWrap(value: usize, mod: usize) usize {
            return (value + 1) % mod;
        }

        fn decWrap(value: usize, mod: usize) usize {
            var res = value;

            if (res == 0) {
                res = mod - 1;
            } else {
                res -= 1;
            }

            return res;
        }
    };
}
