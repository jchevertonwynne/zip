const std = @import("std");

pub fn inflate(deflated: []const u8, alloc: std.mem.Allocator) ![]u8 {
    var result = std.ArrayList(u8).init(alloc);
    defer result.deinit();

    var bitGetter = BitGetter(34000).new(deflated);

    while (true) {
        var headerArr = bitGetter.array(3);
        var header = try Header.new(headerArr);

        std.debug.print("{d}\n{}\n", .{headerArr, header});

        switch (header.block) {
            .Stored => {
                bitGetter.skipToByteBoundary();
                var len = bitGetter.array(16);
                var nLen = bitGetter.array(16);
                std.debug.print("{d} {d}\n", .{ len, nLen });
            },
            .Static => {
                var huffman = bitGetter.array(7);
                var i: u9 = arrayToInt(7, huffman, .MSB);
                if (i <= 0b0010111) {
                    var val = i + 256;
                    std.debug.print("{}\n", .{val});
                    continue;
                }
                i = (i << 1) + bitGetter.next();
                if (i <= 0b10111111) {
                    var val = i - 0b10111111;
                    std.debug.print("{}\n", .{val});
                    continue;
                }
                if (i <= 0b11000111) {
                    var val = i - 0b11000000 + 280;
                    std.debug.print("{}\n", .{val});
                    continue;
                } else {
                    var val = i - 0b110010000 + 144;
                    std.debug.print("{}\n", .{val});
                    continue;
                }
                std.debug.print("{d} == {}\n", .{huffman, i});
            },
            else => {},
        }

        if (header.final)
            break;
    }

    return result.toOwnedSlice();
}

const Header = struct {
    final: bool,
    block: Block,

    fn new(source: [3]u1) !Header {
        return Header{ .final = source[0] == 1, .block = try Block.from(source[1..].*) };
    }
};

const Block = enum {
    Stored,
    Static,
    Dynamic,

    fn from(source: [2]u1) !Block {
        var block: u2 = (@as(u2, source[1]) << 1) + source[0];
        return switch (block) {
            0b00 => .Stored,
            0b01 => .Static,
            0b10 => .Dynamic,
            0b11 => return error.InvalidBlockType,
        };
    }
};

fn BitGetter(comptime bufSize: usize) type {
    return struct {
        source: []const u8,
        index: usize,
        bit: usize,
        ringBuffer: RingBuffer(u1, bufSize),

        fn new(source: []const u8) @This() {
            return .{
                .source = source,
                .index = 0,
                .bit = 0,
                .ringBuffer = RingBuffer(u1, bufSize).new()
            };
        }

        fn atEnd(this: @This()) bool {
            return this.index == this.source.len;
        }

        fn skipToByteBoundary(this: *@This()) void {
            while (this.bit != 0)
                _ = this.next();
        }

        fn next(this: *@This()) u1 {
            var bit = @boolToInt((this.source[this.index] & (@as(u8, 1) << @truncate(u3, this.bit))) != 0);
            this.bit += 1;
            if (this.bit == 8) {
                this.bit = 0;
                this.index += 1;
            }
            this.ringBuffer.append(bit);
            return bit;
        }

        fn array(this: *@This(), comptime size: usize) [size]u1 {
            var result: [size]u1 = undefined;
            for (result) |*r|
                r.* = this.next();
            return result;
        }
    };
}

fn RingBuffer(comptime T: type, comptime bufSize: usize) type {
    return struct {
        buffer: [bufSize]T,
        len: usize,
        start: usize,

        fn new() @This() {
            return .{
                .buffer = undefined,
                .len = 0,
                .start = 0,
            };
        }

        fn append(this: *@This(), val: T) void {
            this.buffer[(this.start + this.len) % bufSize] = val;
            if (this.len == bufSize) {
                this.start += 1;
            } else {
                this.len += 1;
            }
        }

        fn getFromStart(this: @This(), index: usize) T {
            return this.buffer[(this.start + index) % bufSize];
        }

        fn getFromEnd(this: @This(), index: usize) T {
            var lastIndex = (this.start + this.len - 1) % bufSize;
            var wanted = ((bufSize + lastIndex) - index) % bufSize;
            return this.buffer[wanted];
        }
    };
}

fn arrayToInt(comptime size: u16, arr: [size]u1, comptime ordering: Ordering) std.meta.Int(.unsigned, size) {
    var result: std.meta.Int(.unsigned, size) = 0;
    if (ordering == .MSB) {
        for (arr) |a| {
            result <<= 1;
            result += a;
        }
    } else {
        var i: usize = arr.len;
        while (i > 0) {
            i -= 1;
            result <<= 1;
            result += arr[i];
        }
    }

    return result;
}

const Ordering = enum {
    MSB,
    LSB
};
