const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("quircz", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "quircz",
        .root_module = mod,
    });
    b.installArtifact(lib);
    b.getInstallStep().dependOn(&b.addInstallHeaderFile(b.path("include/quircz.h"), "quircz.h").step);

    const demo_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });

    const demo_lib = b.addLibrary(.{
        .name = "quircz_bench",
        .root_module = demo_mod,
    });

    const build_demo = b.addSystemCommand(&.{
        "/bin/sh",
        "demo/build_benchmark.sh",
        "zig-out/bin/quircz-benchmark",
    });
    build_demo.addFileArg(demo_lib.getEmittedBin());
    build_demo.setCwd(b.path("."));
    build_demo.step.dependOn(&demo_lib.step);
    build_demo.step.dependOn(&b.addInstallHeaderFile(b.path("include/quircz.h"), "quircz.h").step);

    const run_demo = b.addSystemCommand(&.{
        "./zig-out/bin/quircz-benchmark",
        "demo/qr_dataset",
    });
    run_demo.setCwd(b.path("."));
    run_demo.step.dependOn(&build_demo.step);

    const demo_step = b.step("demo", "Build the C benchmark executable");
    demo_step.dependOn(&build_demo.step);

    const demo_run_step = b.step("demo-run", "Run the C benchmark against demo/qr_dataset");
    demo_run_step.dependOn(&run_demo.step);

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const lib_tests = b.addTest(.{
        .root_module = lib.root_module,
    });

    const run_exe_tests = b.addRunArtifact(lib_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
