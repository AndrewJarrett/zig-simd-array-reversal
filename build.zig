const std = @import("std");
const alg = @import("src/main.zig").alg;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });

    const timerOption = b.option(bool, "timer", "Use internal zig timer instead of a profiling/benchmarking tool") orelse false;

    inline for (@typeInfo(alg).Enum.fields) |a| {
        const exe = b.addExecutable(.{
            .name = a.name,
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        });

        const options = b.addOptions();
        options.addOption([]const u8, "algorithm", a.name);
        options.addOption(bool, "timer", timerOption);
        exe.root_module.addOptions("config", options);

        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());

        const run_step = b.step("run-" ++ a.name, "Run the app");
        run_step.dependOn(&run_cmd.step);

        const wf = b.addWriteFiles();
        wf.addCopyFileToSource(exe.getEmittedAsm(), "zig-out/" ++ a.name ++ ".asm");
        wf.step.dependOn(&exe.step);
        b.getInstallStep().dependOn(&wf.step);
    }

    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
