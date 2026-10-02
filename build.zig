const std = @import("std");

pub fn build(b: *std.Build) void {
    // The pure-Zig kernels need the host's SIMD instruction set to approach
    // the performance of native inference runtimes. Cross-compilers can opt
    // out with `-Dnative-cpu=false`.
    const native_cpu = b.option(bool, "native-cpu", "use the host CPU feature set") orelse true;
    var default_target: std.Target.Query = .{};
    if (native_cpu) default_target.cpu_model = .native;
    const target = b.standardTargetOptions(.{ .default_target = default_target });
    // Model inference is dominated by scalar dequantization/matmul loops;
    // Debug mode is unusably slow for the interactive application. Keep tests
    // explicitly overridable, while making the normal executable fast by
    // default (`-Doptimize=Debug` remains available for debugging).
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "optimization mode") orelse .ReleaseSafe;

    const android_keystore = b.addOptions();
    android_keystore.addOption([]const u8, "key_alias", b.option([]const u8, "android-key-alias", "Android Keystore alias") orelse "naza-zig-unlock");
    android_keystore.addOption([]const u8, "rsa_modulus_hex", b.option([]const u8, "android-rsa-modulus-hex", "Pinned Android Keystore RSA modulus in hex") orelse "");
    android_keystore.addOption([]const u8, "rsa_exponent_hex", b.option([]const u8, "android-rsa-exponent-hex", "Pinned Android Keystore RSA exponent in hex") orelse "010001");
    android_keystore.addOption([]const u8, "termux_keystore_path", b.option([]const u8, "termux-keystore-path", "Absolute termux-keystore executable path") orelse "/data/data/com.termux/files/usr/bin/termux-keystore");

    const root = b.createModule(.{
        .root_source_file = b.path("src/naza_all.zig"),
        .target = target,
        .optimize = optimize,
    });
    root.addOptions("android_keystore_options", android_keystore);

    const exe = b.addExecutable(.{
        .name = "naza-zig",
        .root_module = root,
    });
    // The GUI is still rendered entirely in Zig. X11 is only the Debian OS
    // surface/input boundary; no GTK/Qt/SDL/webview widget stack is linked.
    if (target.result.os.tag == .linux and target.result.abi != .android) {
        exe.linkLibC();
        exe.linkSystemLibrary("X11");
    }
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the NAZA pure-Zig monolith");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.stdio = .inherit;
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    const test_root = b.createModule(.{
        .root_source_file = b.path("src/naza_all.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_root.addOptions("android_keystore_options", android_keystore);
    const tests = b.addTest(.{ .root_module = test_root });
    // gui.zig is imported by the monolith tests, so the desktop test artifact
    // needs the same narrow platform boundary as the executable. The UI
    // implementation itself remains software-rendered Zig.
    if (target.result.os.tag == .linux and target.result.abi != .android) {
        tests.linkLibC();
        tests.linkSystemLibrary("X11");
    }
    const run_tests = b.addRunArtifact(tests);

    const aes_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/crypto/aes_gcm.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_aes_tests = b.addRunArtifact(aes_tests);

    const model_task_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/model_task.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    if (target.result.os.tag == .linux) model_task_tests.linkLibC();
    const run_model_task_tests = b.addRunArtifact(model_task_tests);

    const inference_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/inference_task.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    if (target.result.os.tag == .linux) inference_tests.linkLibC();
    const run_inference_tests = b.addRunArtifact(inference_tests);

    const aes_test_step = b.step("aes-test", "Run AES-256-GCM/PBKDF2 compatibility tests");
    aes_test_step.dependOn(&run_aes_tests.step);

    const test_step = b.step("test", "Run monolith and AES-GCM tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_aes_tests.step);
    test_step.dependOn(&run_model_task_tests.step);
    test_step.dependOn(&run_inference_tests.step);
}
