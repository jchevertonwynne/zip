const std = @import("std");
const zip = @import("zip.zig");
const zigargs = @import("zigargs");

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(!gpa.deinit());
    var alloc = gpa.allocator();

    var parsedArgs = try zigargs.parseForCurrentProcess(Args, alloc, .print);
    defer parsedArgs.deinit();

    var args = parsedArgs.options;
    try args.validate();

    switch (parsedArgs.options.mode) {
        .unzip => try zip.unzip(args.file, args.outputdir, args.usec, alloc),
        .zip => try zip.zip(args.file, args.inputdir, alloc),
    }
}

const Args = struct {
    file: []const u8 = &[_]u8{},
    outputdir: []const u8 = ".",
    inputdir: []const u8 = ".",
    mode: enum { zip, unzip } = .unzip,
    usec: bool = false,

    pub const shorthands = .{
        .f = "file",
        .o = "outputdir",
        .i = "inputdir",
        .m = "mode",
        .c = "usec",
    };

    fn validate(this: @This()) !void {
        if (this.file.len == 0) {
            return error.ArgsZipFileNameNotProvided;
        }
        if (this.mode == .unzip and this.outputdir.len == 0) {
            return error.ArgsZipFileOutputDirNotProvided;
        }
        if (this.mode == .zip and this.outputdir.len == 0) {
            return error.ArgsZipFileInputDirNotProvided;
        }
    }
};
