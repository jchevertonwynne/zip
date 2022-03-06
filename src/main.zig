const std = @import("std");
const ZipFile = @import("zip.zig").ZipFile;
const crc32 = @import("crc32.zig").crc32;
const inflate = @import("inflate.zig");

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(!gpa.deinit());
    var alloc = gpa.allocator();

    var file = try std.fs.cwd().openFile("out.zip", .{});
    var zipFile = try ZipFile.new(&file, alloc);
    defer zipFile.deinit(alloc);

    // std.debug.print("{s}\n", .{zipFile.endOfCentralDirectoryRecord});
    // for (zipFile.centralDirectoryFileHeaders) |c| {
    //     std.debug.print("name = \"{s}\"\ncomment = \"{s}\"\n{s}\n\n", .{ c.fileName, c.fileComment, c });
    // }

    try zipFile.loadFiles(&file, alloc);

    for (zipFile.fileEntries.?) |f| {
        std.debug.print("file name = {s}\ncompressed size = {}\n", .{ f.header.fileName, f.contents.len });

        var decompressed = try f.decompressed(alloc);
        switch (decompressed) {
            .Decompressed => |*d| {
                std.debug.print("{s}\n", .{d.*});
                alloc.free(d.*);
            },
            else => {}
        }

        std.debug.print("\n", .{});
    }

    // try file.seekFromEnd(-22);
    // var buf: [22]u8 = undefined;
    // var read = try file.read(&buf);
    // std.debug.print("{} {d}\n", .{read, buf});
}
