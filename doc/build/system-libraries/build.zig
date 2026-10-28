const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const exe = b.addExecutable(.{
        .name = "zip",
        .root_module = b.createModule(.{
            .root_source_file = b.path("zip.zig"),
            .target = b.graph.host,
            .link_libc = true,
        }),
    });

    if (b.systemIntegrationOption("zlib", .{})) {
        exe.root_module.linkSystemLibrary("z", .{});
    } else {
        const zlib_dep = b.dependency("zlib", .{
            .optimize = optimize,
            .target = target,
        });
        exe.root_module.linkLibrary(zlib_dep.artifact("z"));
    }

    b.installArtifact(exe);
}

// build=succeed
// additional_option=-fsys=zlib
// additional_option=--help
