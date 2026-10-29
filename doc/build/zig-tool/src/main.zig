const std = @import("std");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    const self_exe_dir_path = try std.process.executableDirPathAlloc(io, arena);
    var self_exe_dir = try Io.Dir.cwd().openDir(io, self_exe_dir_path, .{});
    defer self_exe_dir.close(io);

    const word = try self_exe_dir.readFileAlloc(io, "word.txt", arena, .limited(1000));

    var stdout_buffer: [1000]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print("Hello {s}\n", .{word});
    try stdout.flush();
}

// syntax
