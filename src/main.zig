const std = @import("std");
const FileEntry = @import("zip.zig").FileEntry;

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(!gpa.deinit());
    var alloc = gpa.allocator();

    var file = try std.fs.cwd().openFile("out.zip", .{});
    var zipFile = try FileEntry.new(&file, alloc, true);
    defer zipFile.deinit(alloc);

    std.debug.print("{} {s}\n", .{zipFile.header, zipFile.header.fileName});
}
