// MIT License
//
// Copyright (c) 2022 Yusuke Tanaka
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

const std = @import("std");
const mem = std.mem;
const math = std.math;
const Allocator = mem.Allocator;
const assert = std.debug.assert;

// TODO make unmanaged

/// Double-ended queue ported from Rust's standard library, which is provided under MIT License.
/// It can be found at https://github.com/rust-lang/rust/blob/master/LICENSE-MIT
pub fn DequeUnmanaged(comptime T: type) type {
    return struct {
        /// tail and head are pointers into the buffer. Tail always points
        /// to the first element that could be read, Head always points
        /// to where data should be written.
        /// If tail == head the buffer is empty. The length of the ringbuffer
        /// is defined as the distance between the two.
        tail: usize,
        head: usize,
        /// Users should **NOT** use this field directly.
        /// In order to access an item with an index, use `get` method.
        /// If you want to iterate over the items, call `iterator` method to get an iterator.
        buffer: []T,

        const Self = @This();
        const INITIAL_CAPACITY = 7; // 2^3 - 1
        const MINIMUM_CAPACITY = 1; // 2 - 1

        /// Creates an empty deque.
        /// Deinitialize with `deinit`.
        pub fn init(allocator: Allocator) Allocator.Error!Self {
            return initCapacity(allocator, INITIAL_CAPACITY);
        }

        /// Creates an empty deque with space for at least `capacity` elements.
        ///
        /// Note that there is no guarantee that the created Deque has the specified capacity.
        /// If it is too large, this method gives up meeting the capacity requirement.
        /// In that case, it will instead create a Deque with the default capacity anyway.
        ///
        /// Deinitialize with `deinit`.
        pub fn initCapacity(allocator: Allocator, cap: usize) Allocator.Error!Self {
            const effective_cap =
                math.ceilPowerOfTwo(usize, @max(cap +| 1, MINIMUM_CAPACITY + 1)) catch
                math.ceilPowerOfTwoAssert(usize, INITIAL_CAPACITY + 1);

            const buffer = try allocator.alloc(T, effective_cap);
            errdefer allocator.free(buffer);

            return Self{
                .tail = 0,
                .head = 0,
                .buffer = buffer,
            };
        }

        /// Release all allocated memory.
        pub fn deinit(self: *Self, allocator: Allocator) void {
            allocator.free(self.buffer);
        }

        /// Returns the length of the already-allocated buffer.
        pub fn capacity(self: Self) usize {
            return self.buffer.len;
        }

        /// Returns the number of elements in the deque.
        pub fn len(self: Self) usize {
            return count(self.tail, self.head, self.capacity());
        }

        /// Gets the pointer to the element with the given index, if any.
        /// Otherwise it returns `null`.
        pub fn get(self: Self, index: usize) ?*T {
            if (index >= self.len()) return null;

            const idx = self.wrapAdd(self.tail, index);
            return &self.buffer[idx];
        }

        /// Gets the pointer to the first element, if any.
        pub fn front(self: Self) ?*T {
            return self.get(0);
        }

        /// Gets the pointer to the last element, if any.
        pub fn back(self: Self) ?*T {
            const last_idx = math.sub(usize, self.len(), 1) catch return null;
            return self.get(last_idx);
        }

        /// Adds the given element to the back of the deque.
        pub fn pushBack(self: *Self, allocator: Allocator, item: T) Allocator.Error!void {
            if (self.isFull()) {
                try self.grow(allocator);
            }

            const head = self.head;
            self.head = self.wrapAdd(self.head, 1);
            self.buffer[head] = item;
        }

        /// Adds the given element to the front of the deque.
        pub fn pushFront(self: *Self, allocator: Allocator, item: T) Allocator.Error!void {
            if (self.isFull()) {
                try self.grow(allocator);
            }

            self.tail = self.wrapSub(self.tail, 1);
            const tail = self.tail;
            self.buffer[tail] = item;
        }

        /// Pops and returns the last element of the deque.
        pub fn popBack(self: *Self) ?T {
            if (self.len() == 0) return null;

            self.head = self.wrapSub(self.head, 1);
            const head = self.head;
            const item = self.buffer[head];
            self.buffer[head] = undefined;
            return item;
        }

        /// Pops and returns the first element of the deque.
        pub fn popFront(self: *Self) ?T {
            if (self.len() == 0) return null;

            const tail = self.tail;
            self.tail = self.wrapAdd(self.tail, 1);
            const item = self.buffer[tail];
            self.buffer[tail] = undefined;
            return item;
        }

        /// Adds all the elements in the given slice to the back of the deque.
        pub fn appendSlice(self: *Self, allocator: Allocator, items: []const T) Allocator.Error!void {
            for (items) |item| {
                try self.pushBack(allocator, item);
            }
        }

        /// Adds all the elements in the given slice to the front of the deque.
        pub fn prependSlice(self: *Self, allocator: Allocator, items: []const T) Allocator.Error!void {
            if (items.len == 0) return;

            var i: usize = items.len - 1;

            while (true) : (i -= 1) {
                const item = items[i];
                try self.pushFront(allocator, item);
                if (i == 0) break;
            }
        }

        /// Returns an iterator over the deque.
        /// Modifying the deque may invalidate this iterator.
        pub fn iterator(self: Self) Iterator {
            return .{
                .head = self.head,
                .tail = self.tail,
                .ring = self.buffer,
            };
        }

        pub const Iterator = struct {
            head: usize,
            tail: usize,
            ring: []T,

            pub fn next(it: *Iterator) ?*T {
                if (it.head == it.tail) return null;

                const tail = it.tail;
                it.tail = wrapIndex(it.tail +% 1, it.ring.len);
                return &it.ring[tail];
            }

            pub fn nextBack(it: *Iterator) ?*T {
                if (it.head == it.tail) return null;

                it.head = wrapIndex(it.head -% 1, it.ring.len);
                return &it.ring[it.head];
            }
        };

        /// Returns `true` if the buffer is at full capacity.
        fn isFull(self: Self) bool {
            return self.capacity() - self.len() == 1;
        }

        fn grow(self: *Self, allocator: Allocator) Allocator.Error!void {
            assert(self.isFull());
            const old_cap = self.capacity();

            // Reserve additional space to accomodate more items
            self.buffer = try allocator.realloc(self.buffer, old_cap * 2);

            // Update `tail` and `head` pointers accordingly
            self.handleCapacityIncrease(old_cap);

            assert(self.capacity() >= old_cap * 2);
            assert(!self.isFull());
        }

        /// Updates `tail` and `head` values to handle the fact that we just reallocated the internal buffer.
        fn handleCapacityIncrease(self: *Self, old_capacity: usize) void {
            const new_capacity = self.capacity();

            // Move the shortest contiguous section of the ring buffer.
            // There are three cases to consider:
            //
            // (A) No need to update
            //          T             H
            // before: [o o o o o o o . ]
            //
            // after : [o o o o o o o . . . . . . . . . ]
            //          T             H
            //
            //
            // (B) [..H] needs to be moved
            //              H T
            // before: [o o . o o o o o ]
            //          ---
            //           |_______________.
            //                           |
            //                           v
            //                          ---
            // after : [. . . o o o o o o o . . . . . . ]
            //                T             H
            //
            //
            // (C) [T..old_capacity] needs to be moved
            //                    H T
            // before: [o o o o o . o o ]
            //                      ---
            //                       |_______________.
            //                                       |
            //                                       v
            //                                      ---
            // after : [o o o o o . . . . . . . . . o o ]
            //                    H                 T

            if (self.tail <= self.head) {
                // (A), Nop
            } else if (self.head < old_capacity - self.tail) {
                // (B)
                self.copyNonOverlapping(old_capacity, 0, self.head);
                self.head += old_capacity;
                assert(self.head > self.tail);
            } else {
                // (C)
                const new_tail = new_capacity - (old_capacity - self.tail);
                self.copyNonOverlapping(new_tail, self.tail, old_capacity - self.tail);
                self.tail = new_tail;
                assert(self.head < self.tail);
            }
            assert(self.head < self.capacity());
            assert(self.tail < self.capacity());
        }

        fn copyNonOverlapping(self: *Self, dest: usize, src: usize, length: usize) void {
            assert(dest + length <= self.capacity());
            assert(src + length <= self.capacity());
            @memcpy(self.buffer[dest .. dest + length], self.buffer[src .. src + length]);
        }

        fn wrapAdd(self: Self, idx: usize, addend: usize) usize {
            return wrapIndex(idx +% addend, self.capacity());
        }

        fn wrapSub(self: Self, idx: usize, subtrahend: usize) usize {
            return wrapIndex(idx -% subtrahend, self.capacity());
        }
    };
}

fn count(tail: usize, head: usize, size: usize) usize {
    assert(math.isPowerOfTwo(size));
    return (head -% tail) & (size - 1);
}

fn wrapIndex(index: usize, size: usize) usize {
    assert(math.isPowerOfTwo(size));
    return index & (size - 1);
}

// test "Deque works" {
//     const testing = std.testing;

//     var deque = try DequeUnmanaged(usize).init(testing.allocator);
//     defer deque.deinit();

//     // empty deque
//     try testing.expectEqual(@as(usize, 0), deque.len());
//     try testing.expect(deque.get(0) == null);
//     try testing.expect(deque.front() == null);
//     try testing.expect(deque.back() == null);
//     try testing.expect(deque.popBack() == null);
//     try testing.expect(deque.popFront() == null);

//     // pushBack
//     try deque.pushBack(101);
//     try testing.expectEqual(@as(usize, 1), deque.len());
//     try testing.expectEqual(@as(usize, 101), deque.get(0).?.*);
//     try testing.expectEqual(@as(usize, 101), deque.front().?.*);
//     try testing.expectEqual(@as(usize, 101), deque.back().?.*);

//     // pushFront
//     try deque.pushFront(100);
//     try testing.expectEqual(@as(usize, 2), deque.len());
//     try testing.expectEqual(@as(usize, 100), deque.get(0).?.*);
//     try testing.expectEqual(@as(usize, 100), deque.front().?.*);
//     try testing.expectEqual(@as(usize, 101), deque.get(1).?.*);
//     try testing.expectEqual(@as(usize, 101), deque.back().?.*);

//     // more items
//     {
//         var i: usize = 99;
//         while (true) : (i -= 1) {
//             try deque.pushFront(i);
//             if (i == 0) break;
//         }
//     }
//     {
//         var i: usize = 102;
//         while (i < 200) : (i += 1) {
//             try deque.pushBack(i);
//         }
//     }

//     try testing.expectEqual(@as(usize, 200), deque.len());
//     {
//         var i: usize = 0;
//         while (i < deque.len()) : (i += 1) {
//             try testing.expectEqual(i, deque.get(i).?.*);
//         }
//     }
//     {
//         var i: usize = 0;
//         var it = deque.iterator();
//         while (it.next()) |val| : (i += 1) {
//             try testing.expectEqual(i, val.*);
//         }
//         try testing.expectEqual(@as(usize, 200), i);
//     }
// }

// test "initCapacity with too large capacity" {
//     const testing = std.testing;

//     var deque = try Deque(i32).initCapacity(testing.allocator, math.maxInt(usize));
//     defer deque.deinit();

//     // The specified capacity `math.maxInt(usize)` was too large.
//     // Internally this is just ignored, and the default capacity is used instead.
//     try testing.expectEqual(@as(usize, 8), deque.buffer.len);
// }

// test "appendSlice and prependSlice" {
//     const testing = std.testing;

//     var deque = try Deque(usize).init(testing.allocator);
//     defer deque.deinit();

//     try deque.prependSlice(&[_]usize{ 1, 2, 3, 4, 5, 6 });
//     try deque.appendSlice(&[_]usize{ 7, 8, 9 });
//     try deque.prependSlice(&[_]usize{0});
//     try deque.appendSlice(&[_]usize{ 10, 11, 12, 13, 14 });

//     {
//         var i: usize = 0;
//         while (i <= 14) : (i += 1) {
//             try testing.expectEqual(i, deque.get(i).?.*);
//         }
//     }
// }

// test "nextBack" {
//     const testing = std.testing;

//     var deque = try Deque(usize).init(testing.allocator);
//     defer deque.deinit();

//     try deque.appendSlice(&[_]usize{ 5, 4, 3, 2, 1, 0 });

//     {
//         var i: usize = 0;
//         var it = deque.iterator();
//         while (it.nextBack()) |val| : (i += 1) {
//             try testing.expectEqual(i, val.*);
//         }
//     }
// }
