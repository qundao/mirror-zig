const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize: std.builtin.Optimize = .debug;
    const target = b.graph.host;

    const obj = b.addObject(.{
        .name = "base64",
        .root_module = b.createModule(.{
            .root_source_file = b.path("base64.zig"),
            .optimize = optimize,
            .target = target,
            .link_libc = true,
        }),
    });

    const exe = b.addExecutable(.{
        .name = "test",
        .root_module = b.createModule(.{
            .root_source_file = null,
            .optimize = optimize,
            .target = target,
            .link_libc = true,
        }),
    });
    exe.root_module.addCSourceFile(.{
        .file = b.path("test.c"),
        .flags = &[_][]const u8{"-std=c99"},
    });
    exe.root_module.addObject(obj);

    const test_step = b.step("test", "Test it");
    test_step.dependOn(&exe.step);
    b.setDefaultStep(test_step);

    const run_cmd = b.addRunArtifact(exe);
    test_step.dependOn(&run_cmd.step);
}
