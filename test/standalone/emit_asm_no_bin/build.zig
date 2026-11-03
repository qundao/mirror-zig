const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize: std.builtin.Optimize = .debug;

    const obj = b.addObject(.{
        .name = "main",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .optimize = optimize,
            .target = b.graph.host,
        }),
    });
    _ = obj.getEmittedAsm();

    const test_step = b.step("test", "Test it");
    test_step.dependOn(&obj.step);
    b.setDefaultStep(test_step);

    test_step.dependOn(&obj.step);
}
