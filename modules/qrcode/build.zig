const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("spider_qrcode", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        // Pure Zig — no C dependency, no link_libc.
        // (spider is not imported: this module has no dependency on
        // Ctx/Response today; it only produces a module matrix.)
    });

    // Unit tests for the algorithm modules — runs standalone during
    // development, before this package is wired into Spider's own
    // build.zig via -Dqrcode=true.
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run qrcode module unit tests");
    test_step.dependOn(&run_mod_tests.step);

    // test-decode — generates a few QR codes and decodes them with the
    // real `zbarimg` scanner, proving they're actually readable and not
    // just internally/oracle consistent. Separate from the default
    // `test` step (same pattern as Spider's own test-pg/test-sqlite)
    // since it shells out to an external tool that may not be
    // installed everywhere.
    const decode_check_exe = b.addExecutable(.{
        .name = "decode_check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("decode_check.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "qrcode", .module = mod }},
        }),
    });

    const test_decode_step = b.step("test-decode", "Decode generated QR codes with zbarimg (requires zbarimg installed)");
    const decode_cases = [_][]const u8{
        "HELLO WORLD",
        "12345678901234567890",
        "Testing byte-mode QR generation with lowercase.",
    };
    for (decode_cases, 0..) |text, i| {
        const gen_run = b.addRunArtifact(decode_check_exe);
        gen_run.addArg(b.fmt("{d}", .{i}));
        const pbm = gen_run.captureStdOut(.{ .basename = "out.pbm" });

        const zbar_run = b.addSystemCommand(&.{ "zbarimg", "--raw" });
        zbar_run.addFileArg(pbm);
        zbar_run.expectStdOutEqual(b.fmt("{s}\n", .{text}));
        zbar_run.expectExitCode(0);

        test_decode_step.dependOn(&zbar_run.step);
    }
}
