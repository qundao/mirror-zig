const builtin = @import("builtin");

const std = @import("std");
const Io = std.Io;
const fatal = std.process.fatal;
const mem = std.mem;
const Allocator = std.mem.Allocator;
const doctest = @import("doctest.zig");

const usage =
    \\Usage: term2html -- <argv> 
    \\
    \\   Executes argv in a child process, capturing stderr while enabling
    \\   terminal colors, and then printing to stdout the terminal colors
    \\   converted to HTML.
    \\
    \\Options:
    \\   -h, --help             Print this help and exit
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const environ_map = init.environ_map;
    const args = try init.minimal.args.toSlice(arena);
    const cwd_path = try std.process.currentPathAlloc(io, arena);

    _ = environ_map.swapRemove("NOCOLOR");
    try environ_map.put("CLICOLOR_FORCE", "1");

    var arg_i: usize = 1;
    const argv = while (true) : (arg_i += 1) {
        const arg = args[arg_i];
        if (mem.eql(u8, arg, "-h") or mem.eql(u8, arg, "--help")) {
            try Io.File.stdout().writeStreamingAll(io, usage);
            std.process.exit(0);
        } else if (mem.eql(u8, arg, "--")) {
            break args[arg_i + 1 ..];
        } else {
            fatal("unrecognized option: {q}", .{arg});
        }
    } else fatal("missing -- arg", .{});

    const result = try doctest.run(arena, io, environ_map, cwd_path, argv);
    const escaped_stdout = try doctest.escapeHtml(arena, result.stdout);
    const escaped_stderr = try doctest.escapeHtml(arena, result.stderr);

    const colored_stderr = try doctest.termColor(arena, escaped_stderr);
    const colored_stdout = try doctest.termColor(arena, escaped_stdout);

    var shell_buffer: Io.Writer.Allocating = .init(arena);
    defer shell_buffer.deinit();
    const shell_out = &shell_buffer.writer;

    try shell_out.writeAll("$");
    for (argv) |arg| try shell_out.print(" {s}", .{arg});
    try shell_out.print("\n{s}{s}", .{ colored_stdout, colored_stderr });
    if (!result.term.eql(.success)) try shell_out.print("(process {f})", .{result.term});
    try shell_out.writeAll("\n");

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    try doctest.printShell(&stdout_writer.interface, shell_buffer.written(), false);
    try stdout_writer.interface.writeByte('\n');
    try stdout_writer.flush();

    try Io.File.stderr().writeStreamingAll(io, result.stdout);
    try Io.File.stderr().writeStreamingAll(io, result.stderr);
}
