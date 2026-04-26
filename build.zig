const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const package_name = "quircz";
    const root_source_path = "src/root.zig";
    const public_header_path = "include/quircz.h";

    const module = b.addModule(package_name, .{
        .root_source_file = b.path(root_source_path),
        .target = target,
        .optimize = optimize,
    });

    const library = b.addLibrary(.{
        .name = package_name,
        .root_module = module,
    });

    b.installArtifact(library);

    const install_header = b.addInstallHeaderFile(
        b.path(public_header_path),
        "quircz.h",
    );
    b.getInstallStep().dependOn(&install_header.step);

    const tests = b.addTest(.{
        .root_module = module,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run package tests");
    test_step.dependOn(&run_tests.step);
}
