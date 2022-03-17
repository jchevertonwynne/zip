const std = @import("std");
const ZipFile = @import("zip.zig").ZipFile;
const crc32 = @import("crc32.zig").crc32;
const zigargs = @import("zigargs");

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(!gpa.deinit());
    var alloc = gpa.allocator();

    var args = try zigargs.parseForCurrentProcess(Args, alloc, .print);
    defer args.deinit();

    if (!args.options.valid()) {
        std.debug.print("invalid file provided\n", .{});
        std.os.exit(1);
    }

    std.debug.print("reading from file {s}\n", .{args.options.file});

    var file = try std.fs.cwd().openFile(args.options.file, .{});
    var zipFile = try ZipFile.new(&file, alloc);
    defer zipFile.deinit(alloc);

    try zipFile.loadFiles(&file, alloc);

    switch (args.options.mode) {
        .unzip => {
            for (zipFile.fileEntries.?) |f| {
                std.debug.print("file name = {s}\n", .{f.header.fileName});

                var decompressed = try f.decompressed(args.options.usec, alloc);
                switch (decompressed) {
                    .Decompressed => |d| {
                        var expectedCrc32 = f.header.crc32;
                        var computedCrc32 = crc32(d);
                        std.debug.assert(expectedCrc32 == computedCrc32);
                        alloc.free(d);
                    },
                    else => {},
                }
            }
        },
        .zip => unreachable,
    }
}

const Args = struct {
    file: []const u8 = &[_]u8{},
    mode: enum { zip, unzip } = .unzip,
    usec: bool = false,

    pub const shorthands = .{
        .f = "file",
        .m = "mode",
        .c = "usec",
    };

    fn valid(this: @This()) bool {
        return this.file.len > 0;
    }
};
