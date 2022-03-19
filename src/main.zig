const std = @import("std");
const ZipFile = @import("zip.zig").ZipFile;
const crc32 = @import("crc32.zig").crc32;
const zigargs = @import("zigargs");

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(!gpa.deinit());
    var alloc = gpa.allocator();

    var parsedArgs = try zigargs.parseForCurrentProcess(Args, alloc, .print);
    defer parsedArgs.deinit();

    try parsedArgs.options.valid();

    switch (parsedArgs.options.mode) {
        .unzip => try unzipZipFile(parsedArgs.options, alloc),
        .zip => {
            std.debug.print("zip is currently unimplemented\n", .{});
            return error.ZipFileZipUnimplemented;
        },
    }
}

const Args = struct {
    file: []const u8 = &[_]u8{},
    outputdir: []const u8 = ".",
    mode: enum { zip, unzip } = .unzip,
    usec: bool = false,

    pub const shorthands = .{
        .f = "file",
        .o = "outputdir",
        .m = "mode",
        .c = "usec",
    };

    fn valid(this: @This()) !void {
        if (this.file.len == 0) {
            return error.ArgsZipFileNameNotProvided;
        }
    }
};

fn unzipZipFile(args: Args, alloc: std.mem.Allocator) !void {
    var sourceFile = try std.fs.cwd().openFile(args.file, .{});
    defer sourceFile.close();

    var outDir = try std.fs.cwd().openDir(args.outputdir, .{ .access_sub_paths = false });
    defer outDir.close();

    var zipFile = try ZipFile.new(&sourceFile, alloc);
    defer zipFile.deinit(alloc);

    try zipFile.decompress(outDir, args.usec, alloc);
}
