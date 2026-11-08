const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "foo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    if (b.dependencyStep(&unit_tests.step, "mime", .{
        .target = target,
        .optimize = optimize,
    })) |mime_dep| {
        // The dependency is available, so we can complete more of the
        // configuration.
        unit_tests.root_module.addImport("mime", mime_dep.module("mime"));
    }

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}

// build=succeed
// additional_option=test
// additional_option=--summary
// additional_option=all
