const std = @import("std");

const flecs_flags = &.{
    "-std=c99",
    "-DFLECS_CUSTOM_BUILD",
    "-DFLECS_SYSTEM",
    "-DFLECS_PIPELINE",
    "-DFLECS_TIMER",
};

fn addFlecs(b: *std.Build, module: *std.Build.Module) void {
    module.link_libc = true;
    module.addIncludePath(b.path("vendor/flecs/distr"));
    module.addCSourceFile(.{
        .file = b.path("vendor/flecs/distr/flecs.c"),
        .flags = flecs_flags,
    });
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const score = b.addModule("score", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    addFlecs(b, score);

    const diagnostic = b.addExecutable(.{
        .name = "score-diagnostic",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "score", .module = score }},
        }),
    });
    b.installArtifact(diagnostic);

    const audio_analyzer = b.addExecutable(.{
        .name = "score-audio-analyze",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/analyze_audio.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "score", .module = score }},
        }),
    });
    b.installArtifact(audio_analyzer);
    const audio_analyzer_run = b.addRunArtifact(audio_analyzer);
    if (b.args) |args| audio_analyzer_run.addArgs(args);
    const audio_analyzer_step = b.step("audio-analyze", "Analyze a local WAV and optionally compare it with MusicXML/MXL");
    audio_analyzer_step.dependOn(&audio_analyzer_run.step);

    const native = b.addExecutable(.{
        .name = "score",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/platform/native/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "score", .module = score }},
        }),
    });
    const build_options = b.addOptions();
    build_options.addOption(bool, "hot_reload", optimize == .Debug);
    native.root_module.addOptions("build_options", build_options);
    native.root_module.addAnonymousImport("score_ui.wgsl", .{
        .root_source_file = b.path("src/render/shaders/ui.wgsl"),
    });
    native.root_module.addIncludePath(b.path("src/platform/apple"));
    native.root_module.addCSourceFile(.{
        .file = b.path("src/platform/apple/open_panel.m"),
        .flags = &.{ "-fobjc-arc", "-fmodules" },
    });
    native.root_module.addCSourceFile(.{
        .file = b.path("src/platform/apple/music_devices.c"),
        .flags = &.{"-std=c11"},
    });
    native.root_module.linkFramework("AppKit", .{});
    native.root_module.linkFramework("AudioToolbox", .{});
    native.root_module.linkFramework("AudioUnit", .{});
    native.root_module.linkFramework("CoreAudio", .{});
    native.root_module.linkFramework("CoreMIDI", .{});
    const zglfw = b.dependency("zglfw", .{ .target = target, .optimize = optimize });
    native.root_module.addImport("zglfw", zglfw.module("root"));
    native.root_module.linkLibrary(zglfw.artifact("glfw"));
    const zgpu = b.dependency("zgpu", .{ .target = target, .optimize = optimize });
    native.root_module.addImport("zgpu", zgpu.module("root"));
    @import("zgpu").addLibraryPathsTo(native);
    native.root_module.linkLibrary(zgpu.artifact("zdawn"));
    b.installArtifact(native);

    const bundle_step = b.step("macos-bundle", "Build an ad-hoc signed native macOS app bundle");
    const bundle_cmd = b.addSystemCommand(&.{ "sh", "scripts/bundle-macos.sh" });
    bundle_cmd.step.dependOn(b.getInstallStep());
    bundle_step.dependOn(&bundle_cmd.step);

    const systems_plugin = b.addLibrary(.{
        .name = "score-systems",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/plugin_root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const systems_step = b.step("systems", "Build the hot-reloadable development systems module");
    const install_systems = b.addInstallArtifact(systems_plugin, .{});
    systems_step.dependOn(&install_systems.step);
    if (optimize == .Debug) b.getInstallStep().dependOn(&install_systems.step);

    const run_native_cmd = b.addRunArtifact(native);
    run_native_cmd.step.dependOn(b.getInstallStep());
    const native_step = b.step("native", "Run the native WebGPU application");
    native_step.dependOn(&run_native_cmd.step);

    const dev_step = b.step("dev", "Run native app and rebuild hot-reloadable systems on change");
    const dev_cmd = b.addSystemCommand(&.{ "sh", "scripts/dev-native.sh" });
    dev_step.dependOn(&dev_cmd.step);

    const run_cmd = b.addRunArtifact(diagnostic);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the headless engine diagnostic");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{ .root_module = score });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run portable engine tests");
    test_step.dependOn(&run_tests.step);

    const web_step = b.step("web", "Build the Wasm/WebGPU export with Emscripten");
    const web_cmd = b.addSystemCommand(&.{ "sh", "scripts/build-web.sh" });
    web_step.dependOn(&web_cmd.step);

    const web_dev_step = b.step("dev-web", "Serve and statefully hot-reload the Wasm/WebGPU application");
    const web_dev_cmd = b.addSystemCommand(&.{ "sh", "scripts/dev-web.sh" });
    web_dev_step.dependOn(&web_dev_cmd.step);

    const ios_step = b.step("ios-core", "Build the portable iOS arm64 static core for an Xcode Metal host");
    if (b.option(bool, "ios-internal", "Internal iOS SDK-configured build") orelse false) {
        var ios_query: std.Target.Query = .{ .cpu_arch = .aarch64, .os_tag = .ios };
        if (b.option(bool, "ios-simulator", "Build for the arm64 iOS simulator") orelse false) ios_query.abi = .simulator;
        const ios_target = b.resolveTargetQuery(ios_query);
        const ios_score = b.addModule("score-ios", .{
            .root_source_file = b.path("src/root.zig"),
            .target = ios_target,
            .optimize = optimize,
        });
        if (b.sysroot) |sdk| ios_score.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/include" }) });
        addFlecs(b, ios_score);
        const ios_core = b.addLibrary(.{
            .name = "score-ios-core",
            .linkage = .static,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform/apple/ios_core.zig"),
                .target = ios_target,
                .optimize = optimize,
                .imports = &.{.{ .name = "score", .module = ios_score }},
            }),
        });
        const ios_install = b.addInstallArtifact(ios_core, .{});
        ios_step.dependOn(&ios_install.step);
        const ios_header = b.addInstallFile(b.path("src/platform/apple/score_ios.h"), "include/score_ios.h");
        ios_step.dependOn(&ios_header.step);
    } else {
        const ios_cmd = b.addSystemCommand(&.{ "sh", "scripts/build-ios-core.sh" });
        ios_step.dependOn(&ios_cmd.step);
    }

    const ios_app_step = b.step("ios-app", "Build the unsigned UIKit/Metal iOS application bundle");
    const ios_app_cmd = b.addSystemCommand(&.{ "sh", "scripts/build-ios-app.sh" });
    ios_app_cmd.step.dependOn(ios_step);
    ios_app_step.dependOn(&ios_app_cmd.step);

    const ios_simulator_step = b.step("ios-simulator", "Build an ad-hoc signed arm64 iOS Simulator application");
    const ios_simulator_cmd = b.addSystemCommand(&.{ "sh", "scripts/build-ios-app.sh", "simulator" });
    ios_simulator_step.dependOn(&ios_simulator_cmd.step);
}
