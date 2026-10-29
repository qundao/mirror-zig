const std = @import("std");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);

    if (args.len != 2) fatal("wrong number of arguments", .{});

    const output_file_path = args[1];

    var output_file = Io.Dir.cwd().createFile(io, output_file_path, .{}) catch |err| {
        fatal("failed to open {q}: {t}", .{ output_file_path, err });
    };
    defer output_file.close(io);

    try output_file.writeStreamingAll(io,
        \\pub const Person = struct {
        \\   age: usize = 18,
        \\   name: []const u8 = "foo"
        \\};
    );
    return std.process.cleanExit(io);
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print(format, args);
    std.process.exit(1);
}

// syntax
