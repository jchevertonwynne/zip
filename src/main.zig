const std = @import("std");
const ZipFile = @import("zip.zig").ZipFile;
const crc32 = @import("crc32.zig").crc32;
const inflate = @import("inflate.zig");

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(!gpa.deinit());
    var alloc = gpa.allocator();

    var args = std.process.args();
    _ = args.skip();
    var zipFileNameOpt = try args.next(alloc);

    if (zipFileNameOpt == null) {
        std.debug.print("please provide a zip file\n", .{});
        std.os.exit(1);
    }
    var zipFileName = zipFileNameOpt.?;
    defer alloc.free(zipFileName);

    std.debug.print("reading from file {s}\n", .{zipFileName});

    var file = try std.fs.cwd().openFile(zipFileName, .{});
    var zipFile = try ZipFile.new(&file, alloc);
    defer zipFile.deinit(alloc);

    try zipFile.loadFiles(&file, alloc);

    for (zipFile.fileEntries.?) |f| {
        std.debug.print("file name = {s}\ncompressed size = {}\n", .{ f.header.fileName, f.contents.len });

        var decompressed = try f.decompressed(alloc);
        switch (decompressed) {
            .Decompressed => |*d| {
                std.debug.print("{s}\n", .{d.*});
                std.debug.print("{} == {} ? {}\n", .{f.header.crc32, crc32(d.*), f.header.crc32 == crc32(d.*)});
                alloc.free(d.*);
            },
            else => {},
        }

        std.debug.print("\n", .{});
    }
}
