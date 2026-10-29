const std = @import("std");
const Io = std.Io;

const usage =
    \\Usage: ./word_select [options]
    \\
    \\Options:
    \\  --input-file INPUT_JSON_FILE
    \\  --output-file OUTPUT_TXT_FILE
    \\  --lang LANG
    \\
;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);

    var opt_input_file_path: ?[]const u8 = null;
    var opt_output_file_path: ?[]const u8 = null;
    var opt_lang: ?[]const u8 = null;

    {
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, "-h", arg) or std.mem.eql(u8, "--help", arg)) {
                try Io.File.stdout().writeStreamingAll(io, usage);
                return std.process.cleanExit(io);
            } else if (std.mem.eql(u8, "--input-file", arg)) {
                i += 1;
                if (i > args.len) fatal("expected arg after '{s}'", .{arg});
                if (opt_input_file_path != null) fatal("duplicated {s} argument", .{arg});
                opt_input_file_path = args[i];
            } else if (std.mem.eql(u8, "--output-file", arg)) {
                i += 1;
                if (i > args.len) fatal("expected arg after '{s}'", .{arg});
                if (opt_output_file_path != null) fatal("duplicated {s} argument", .{arg});
                opt_output_file_path = args[i];
            } else if (std.mem.eql(u8, "--lang", arg)) {
                i += 1;
                if (i > args.len) fatal("expected arg after '{s}'", .{arg});
                if (opt_lang != null) fatal("duplicated {s} argument", .{arg});
                opt_lang = args[i];
            } else {
                fatal("unrecognized arg: '{s}'", .{arg});
            }
        }
    }

    const input_file_path = opt_input_file_path orelse fatal("missing --input-file", .{});
    const output_file_path = opt_output_file_path orelse fatal("missing --output-file", .{});
    const lang = opt_lang orelse fatal("missing --lang", .{});

    var input_file = Io.Dir.cwd().openFile(io, input_file_path, .{}) catch |err| {
        fatal("unable to open '{s}': {s}", .{ input_file_path, @errorName(err) });
    };
    defer input_file.close(io);
    var input_file_buffer: [1000]u8 = undefined;
    var input_file_reader = input_file.reader(io, &input_file_buffer);

    var output_file = Io.Dir.cwd().createFile(io, output_file_path, .{}) catch |err| {
        fatal("unable to open '{s}': {s}", .{ output_file_path, @errorName(err) });
    };
    defer output_file.close(io);

    var json_reader: std.json.Reader = .init(arena, &input_file_reader.interface);
    var words = try std.json.ArrayHashMap([]const u8).jsonParse(arena, &json_reader, .{
        .allocate = .alloc_if_needed,
        .max_value_len = 1000,
    });

    const w = words.map.get(lang) orelse fatal("Lang not found in JSON file", .{});

    try output_file.writeStreamingAll(io, w);
    return std.process.cleanExit(io);
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print(format, args);
    std.process.exit(1);
}

// syntax
