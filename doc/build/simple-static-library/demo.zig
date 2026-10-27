const std = @import("std");
const Io = std.Io;

extern fn fizzbuzz(n: usize) ?[*:0]const u8;

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var buf: [1024]u8 = undefined;
    const file_writer = Io.File.stdout().writer(io, &buf);
    const w = &file_writer.interface;
    for (0..100) |n| {
        if (fizzbuzz(n)) |s| {
            try w.print("{s}\n", .{s});
        } else {
            try w.print("{d}\n", .{n});
        }
    }
    try w.flush();
}

// syntax
