const std = @import("std");
const ZipFile = @import("zip.zig").ZipFile;

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(!gpa.deinit());
    var alloc = gpa.allocator();

    var file = try std.fs.cwd().openFile("out.zip", .{});
    var zipFile = try ZipFile.new(&file, alloc);
    defer zipFile.deinit(alloc);

    std.debug.print("{s}\n", .{zipFile.endOfCentralDirectoryRecord});
    std.debug.print("{s}\n", .{zipFile.centralDirectoryFileHeader});

    // try file.seekFromEnd(-22);
    // var buf: [22]u8 = undefined;
    // var read = try file.read(&buf);
    // std.debug.print("{} {d}\n", .{read, buf});
}
