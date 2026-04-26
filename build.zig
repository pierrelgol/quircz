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
        .root_source_file = b.path("demo/z_demo.zig"),
        .target = target,
        .optimize = optimize,
    });
    demo_mod.addImport("quircz", mod);

    const demo_exe = b.addExecutable(.{
        .name = "demo",
        .root_module = demo_mod,
    });

    const run_demo = b.addRunArtifact(demo_exe);

    run_demo.addFileArg(b.path("demo/zen.zip"));
    if (b.args) |a| run_demo.addArgs(a);

    const demo_step = b.step("demo", "Run demo against demo/zen.zip");
    demo_step.dependOn(&run_demo.step);

    const c_demo_mod = b.createModule(.{
        .root_source_file = null,
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    c_demo_mod.addCSourceFile(.{
        .file = b.path("demo/c_demo.c"),
        .flags = &.{ "-Wall", "-Werro", "-Wextra" },
        .language = .c,
    });

    const c_demo_exe = b.addExecutable(.{
        .name = "demo-c",
        .root_module = c_demo_mod,
    });
    c_demo_exe.root_module.addIncludePath(b.path("include"));
    c_demo_exe.root_module.linkLibrary(lib);
    c_demo_exe.root_module.linkSystemLibrary("z", .{});

    const run_c_demo = b.addRunArtifact(c_demo_exe);
    run_c_demo.addFileArg(b.path("demo/zen.zip"));
    if (b.args) |a| run_c_demo.addArgs(a);

    const c_demo_step = b.step("c-demo", "Run C demo against demo/zen.zip");
    c_demo_step.dependOn(&run_c_demo.step);

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
