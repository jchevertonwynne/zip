const std = @import("std");
const zlib = @import("zlib.zig");

pub fn inflate(deflated: []const u8, uncompressedSize: usize, useC: bool, alloc: std.mem.Allocator) ![]u8 {
    if (useC) {
        return inC(deflated, uncompressedSize, alloc);
    } else {
        return inZig(deflated, uncompressedSize, alloc);
    }
}

fn inC(deflated: []const u8, uncompressedSize: usize, alloc: std.mem.Allocator) ![]u8 {
    var result = try alloc.alloc(u8, uncompressedSize);
    errdefer alloc.free(result);

    var inflationStatus = zlib.puff(result.ptr, &@truncate(c_ulong, result.len), deflated.ptr, &@truncate(c_ulong, deflated.len));

    if (inflationStatus != 0) {
        return error.ZlibInflationError;
    }

    return result;
}

fn inZig(deflated: []const u8, uncompressedSize: usize, alloc: std.mem.Allocator) ![]u8 {
    var result = std.ArrayList(u8).init(alloc);
    defer result.deinit();
    try result.ensureTotalCapacity(uncompressedSize);

    var bitGetter = BitGetter.new(deflated);

    while (true) {
        var header = try Header.new(try bitGetter.array(3));

        switch (header.block) {
            .Stored => try inflateStoredBlock(&bitGetter, &result),
            .Static => try inflateStaticHuffman(&bitGetter, &result),
            .Dynamic => try inflateDynamicHuffman(&bitGetter, &result),
        }

        if (header.final) {
            break;
        }
    }

    return result.toOwnedSlice();
}

fn inflateStoredBlock(bitGetter: *BitGetter, result: *std.ArrayList(u8)) !void {
    try bitGetter.skipToByteBoundary();
    var len = arrayToInt(try bitGetter.array(16), .MSB);
    var nLen = arrayToInt(try bitGetter.array(16), .MSB);
    if (len != ~nLen) {
        return error.ZipFileLenMismatch;
    }
    while (len > 0) {
        len -= 1;
        result.appendAssumeCapacity(try bitGetter.byte());
    }
}

fn inflateStaticHuffman(bitGetter: *BitGetter, result: *std.ArrayList(u8)) !void {
    const huffmanTables = comptime blk: {
        @setEvalBranchQuota(100000);
        var lengths: [288]u64 = undefined;
        var symbol: usize = 0;
        while (symbol < 144) : (symbol += 1)
            lengths[symbol] = 8;
        while (symbol < 256) : (symbol += 1)
            lengths[symbol] = 9;
        while (symbol < 280) : (symbol += 1)
            lengths[symbol] = 7;
        while (symbol < 288) : (symbol += 1)
            lengths[symbol] = 8;

        var lenCount: [16]u16 = undefined;
        var lenSymbol: [288]u16 = undefined;
        var lenTable = DynamicHuffman.new(&lenCount, &lenSymbol, &lengths);

        symbol = 0;
        while (symbol < 30) : (symbol += 1)
            lengths[symbol] = 5;

        var distCount: [16]u16 = undefined;
        var distSymbol: [30]u16 = undefined;
        var distTable = DynamicHuffman.new(&distCount, &distSymbol, lengths[0..30]);

        var tables: struct {
            lenTable: DynamicHuffman = lenTable,
            distTable: DynamicHuffman = distTable,
        } = .{};
        break :blk tables;
    };
    try codes(bitGetter, huffmanTables.lenTable, huffmanTables.distTable, result);
}

// reference: https://github.com/madler/zlib/blob/master/contrib/puff/puff.c#L665
fn inflateDynamicHuffman(bitGetter: *BitGetter, result: *std.ArrayList(u8)) !void {
    var hlit = @as(u16, arrayToInt(try bitGetter.array(5), .LSB)) + 257;
    var hdist = @as(u16, arrayToInt(try bitGetter.array(5), .LSB)) + 1;
    var hclen = @as(u16, arrayToInt(try bitGetter.array(4), .LSB)) + 4;

    const indexOrdering = [19]u8{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };
    var lengths: [286 + 30]u64 = undefined;
    var index: usize = 0;
    while (index < hclen) : (index += 1) {
        lengths[indexOrdering[index]] = arrayToInt(try bitGetter.array(3), .LSB);
    }
    while (index < 19) : (index += 1) {
        lengths[indexOrdering[index]] = 0;
    }

    var lenCounts: [16]u16 = undefined; // maxbits + 1
    var lenSymbols: [286]u16 = undefined; // maxlcodes
    var dynamicHuffman1 = DynamicHuffman.new(&lenCounts, &lenSymbols, lengths[0..19]);

    index = 0;
    while (index < hlit + hdist) {
        var symbol = try decode(bitGetter, dynamicHuffman1);
        if (symbol < 16) {
            lengths[index] = symbol;
            index += 1;
        } else {
            var len: usize = 0;
            if (symbol == 16) {
                len = lengths[index - 1];
                symbol = 3 + @as(u16, arrayToInt(try bitGetter.array(2), .LSB));
            } else if (symbol == 17) {
                symbol = 3 + @as(u16, arrayToInt(try bitGetter.array(3), .LSB));
            } else {
                symbol = 11 + @as(u16, arrayToInt(try bitGetter.array(7), .LSB));
            }
            while (symbol > 0) {
                symbol -= 1;
                lengths[index] = len;
                index += 1;
            }
        }
    }

    var lenHuffman = DynamicHuffman.new(&lenCounts, &lenSymbols, lengths[0..hlit]);

    var distCounts: [16]u16 = undefined; // maxbits + 1
    var distSymbols: [30]u16 = undefined; // maxlcodes
    var distHuffman = DynamicHuffman.new(&distCounts, &distSymbols, lengths[hlit .. hlit + hdist]);

    return try codes(bitGetter, lenHuffman, distHuffman, result);
}

fn codes(bitGetter: *BitGetter, lenHuffman: DynamicHuffman, distHuffman: DynamicHuffman, result: *std.ArrayList(u8)) !void {
    const lengths: [29]u64 = .{
        3,  4,  5,  6,   7,   8,   9,   10,  11,  13,
        15, 17, 19, 23,  27,  31,  35,  43,  51,  59,
        67, 83, 99, 115, 131, 163, 195, 227, 258,
    };
    const lengthExtras: [29]u64 = .{
        0, 0, 0, 0, 0, 0, 0, 0, 1, 1,
        1, 1, 2, 2, 2, 2, 3, 3, 3, 3,
        4, 4, 4, 4, 5, 5, 5, 5, 0,
    };
    const distances: [30]u64 = .{
        1,    2,    3,    4,    5,    7,    9,    13,    17,    25,
        33,   49,   65,   97,   129,  193,  257,  385,   513,   769,
        1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
    };
    const distanceExtras: [30]u64 = .{
        0, 0, 0,  0,  1,  1,  2,  2,  3,  3,
        4, 4, 5,  5,  6,  6,  7,  7,  8,  8,
        9, 9, 10, 10, 11, 11, 12, 12, 13, 13,
    };

    while (true) {
        var symbol = try decode(bitGetter, lenHuffman);
        if (symbol == 256) {
            break;
        } else if (symbol < 256) {
            try result.append(@truncate(u8, symbol));
        } else {
            symbol -= 257;

            var len: usize = lengths[symbol];
            var add: usize = 0;
            var lenExtra = lengthExtras[symbol];
            var ind: u6 = 0;
            while (lenExtra > 0) : (ind += 1) {
                lenExtra -= 1;
                add += @as(usize, try bitGetter.next()) << ind;
            }
            len += add;

            symbol = try decode(bitGetter, distHuffman);
            var dist: usize = distances[symbol];
            var extra = distanceExtras[symbol];
            add = 0;
            ind = 0;
            while (extra > 0) : (ind += 1) {
                extra -= 1;
                add += @as(usize, try bitGetter.next()) << ind;
            }
            dist += add;

            var curr = result.items.len - dist;
            var end = curr + len;
            while (curr < end) : (curr += 1) {
                result.appendAssumeCapacity(result.items[curr]);
            }
        }
    }
}

fn decode(bitGetter: *BitGetter, huffman: DynamicHuffman) !u16 {
    var code: u64 = 0;
    var first: u64 = 0;
    var index: u64 = 0;

    var len: usize = 1;
    while (len <= 15) : (len += 1) {
        code += try bitGetter.next();
        var count = huffman.counts[len];
        if (code < first + count) {
            return huffman.symbols[index + (code - first)];
        }
        index += count;
        first += count;
        first <<= 1;
        code <<= 1;
    }

    return error.DecodeOverMaxBits;
}

const DynamicHuffman = struct {
    counts: []u16,
    symbols: []u16,

    fn new(counts: []u16, symbols: []u16, lengths: []u64) DynamicHuffman {
        var result = DynamicHuffman{ .counts = counts, .symbols = symbols };

        for (result.counts) |*c| {
            c.* = 0;
        }
        for (lengths) |l| {
            result.counts[l] += 1;
        }

        var offsets: [16]u64 = undefined;
        offsets[1] = 0;
        var len: usize = 1;
        while (len < 15) : (len += 1) {
            offsets[len + 1] = offsets[len] + result.counts[len];
        }

        for (lengths) |length, i| {
            if (length != 0) {
                result.symbols[offsets[length]] = @truncate(u16, i);
                offsets[length] += 1;
            }
        }

        return result;
    }
};

const Header = struct {
    final: bool,
    block: Block,

    fn new(source: [3]u1) !Header {
        return Header{
            .final = source[0] == 1,
            .block = try Block.from(source[1..].*),
        };
    }
};

const Block = enum {
    Stored,
    Static,
    Dynamic,

    fn from(source: [2]u1) !Block {
        var block: u2 = arrayToInt(source, .LSB);
        return switch (block) {
            0b00 => .Stored,
            0b01 => .Static,
            0b10 => .Dynamic,
            0b11 => return error.InvalidBlockType,
        };
    }
};

const BitGetter = struct {
    source: []const u8,
    index: usize,
    bit: usize,

    fn new(source: []const u8) @This() {
        return .{
            .source = source,
            .index = 0,
            .bit = 0,
        };
    }

    fn atEnd(this: @This()) bool {
        return this.index == this.source.len;
    }

    fn skipToByteBoundary(this: *@This()) !void {
        while (this.bit != 0) {
            _ = try this.next();
        }
    }

    fn byte(this: *@This()) !u8 {
        if (this.atEnd()) {
            return error.BitGetterReachedEnd;
        }
        if (this.bit != 0) {
            return error.BitGetterByteNotAtBoundary;
        }
        var result = this.source[this.index];
        this.index += 1;
        return result;
    }

    fn next(this: *@This()) !u1 {
        if (this.atEnd()) {
            return error.BitGetterReachedEnd;
        }
        var bit = @boolToInt((this.source[this.index] & (@as(u8, 1) << @truncate(u3, this.bit))) != 0);
        this.bit += 1;
        if (this.bit == 8) {
            this.bit = 0;
            this.index += 1;
        }
        return bit;
    }

    fn array(this: *@This(), comptime size: usize) ![size]u1 {
        var result: [size]u1 = undefined;
        for (result) |*r| {
            r.* = try this.next();
        }
        return result;
    }
};

fn arrayToInt(arr: anytype, comptime ordering: Ordering) std.meta.Int(.unsigned, @typeInfo(@TypeOf(arr)).Array.len) {
    if (@typeInfo(@TypeOf(arr)).Array.child != u1) {
        @compileError("only arrays of u1 are supported");
    }
    var result: std.meta.Int(.unsigned, @typeInfo(@TypeOf(arr)).Array.len) = 0;
    switch (ordering) {
        .MSB => {
            for (arr) |a| {
                result <<= 1;
                result += a;
            }
        },
        .LSB => {
            var i: usize = arr.len;
            while (i > 0) {
                i -= 1;
                result <<= 1;
                result += arr[i];
            }
        },
    }

    return result;
}

const Ordering = enum {
    MSB,
    LSB,
};
