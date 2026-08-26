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
    const sfizz_cmd = b.addSystemCommand(&.{ "sh", "scripts/build-sfizz.sh" });
    const sfizz_step = b.step("sfizz", "Build the native streaming SFZ sampler engine");
    sfizz_step.dependOn(&sfizz_cmd.step);

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

    if (optimize == .Debug) {
        const dev_controller = b.addExecutable(.{
            .name = "score-devctl",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/tools/dev_control.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        dev_controller.root_module.link_libc = true;
        dev_controller.root_module.addIncludePath(b.path("src/platform/apple"));
        dev_controller.root_module.addCSourceFile(.{
            .file = b.path("src/platform/apple/music_devices.c"),
            .flags = &.{"-std=c11"},
        });
        dev_controller.root_module.linkFramework("AudioToolbox", .{});
        dev_controller.root_module.linkFramework("AudioUnit", .{});
        dev_controller.root_module.linkFramework("CoreAudio", .{});
        dev_controller.root_module.linkFramework("CoreFoundation", .{});
        dev_controller.root_module.linkFramework("CoreMIDI", .{});
        b.installArtifact(dev_controller);
    }

    // One score workbench with subcommands replaces a growing collection of
    // narrow, song-specific scripts. Keep exchange-format transformations in
    // Zig so the exact same semantic core is exercised by tooling and app.
    const score_workbench = b.addExecutable(.{
        .name = "score-workbench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/score_workbench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "score", .module = score }},
        }),
    });
    b.installArtifact(score_workbench);
    const score_workbench_run = b.addRunArtifact(score_workbench);
    if (b.args) |args| score_workbench_run.addArgs(args);
    const score_workbench_step = b.step("score-workbench", "Inspect and transform scores with the shared Zig semantic core");
    score_workbench_step.dependOn(&score_workbench_run.step);
    const audio_analyzer_run = b.addRunArtifact(score_workbench);
    audio_analyzer_run.addArg("audio-evidence");
    if (b.args) |args| audio_analyzer_run.addArgs(args);
    const audio_analyzer_step = b.step("audio-analyze", "Analyze a local WAV and optionally compare it with MusicXML/MXL");
    audio_analyzer_step.dependOn(&audio_analyzer_run.step);

    const sampler_module = b.createModule(.{
        .root_source_file = b.path("src/platform/native/sfizz_sampler.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "score", .module = score }},
    });
    const sampler_workbench = b.addExecutable(.{
        .name = "score-sampler-workbench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/sampler_workbench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "score", .module = score },
                .{ .name = "sfizz_sampler", .module = sampler_module },
            },
        }),
    });
    sampler_workbench.step.dependOn(&sfizz_cmd.step);
    b.installArtifact(sampler_workbench);
    const sampler_renderer_run = b.addRunArtifact(sampler_workbench);
    sampler_renderer_run.step.dependOn(&sfizz_cmd.step);
    sampler_renderer_run.addArg("render");
    if (b.args) |args| sampler_renderer_run.addArgs(args);
    const sampler_renderer_step = b.step("sampler-render", "Render an offline SFZ grand-piano verification WAV");
    sampler_renderer_step.dependOn(&sampler_renderer_run.step);
    const sampler_verifier_run = b.addRunArtifact(sampler_workbench);
    sampler_verifier_run.step.dependOn(&sfizz_cmd.step);
    sampler_verifier_run.addArg("verify");
    if (b.args) |args| sampler_verifier_run.addArgs(args);
    const sampler_verifier_step = b.step("sampler-verify", "Run offline grand-piano dynamics, pedal, latency, spectral, overload, and queue gates");
    sampler_verifier_step.dependOn(&sampler_verifier_run.step);

    const native_piano_path = b.option([]const u8, "native-piano", "Reference SFZ for the native release audio gate") orelse
        "local-content/instruments/AccurateSalamanderGrandPianoV6.2beta2/sfz_live/Accurate-SalamanderGrandPiano_flat.Recommended.sfz";
    const native_pack_inspection = b.addRunArtifact(sampler_workbench);
    native_pack_inspection.step.dependOn(&sfizz_cmd.step);
    native_pack_inspection.addArgs(&.{ "inspect-pack", native_piano_path, ".zig-cache/verification/native-release-pack.json" });
    const native_sampler_gate = b.addRunArtifact(sampler_workbench);
    native_sampler_gate.step.dependOn(&native_pack_inspection.step);
    native_sampler_gate.addArgs(&.{ "verify", ".zig-cache/verification/native-release-audio.json", ".zig-cache/verification/native-release-audio.wav", native_piano_path });
    const native_audio_gate_step = b.step("native-audio-gate", "Verify the installed native piano pack, dynamics, pedals, acoustic layers, timing, spectrum, and overload safety");
    native_audio_gate_step.dependOn(&native_sampler_gate.step);

    const portable_piano_path = b.option([]const u8, "portable-piano", "Licensed local SFZ compiled for browser and iOS") orelse native_piano_path;
    const portable_pack_run = b.addRunArtifact(sampler_workbench);
    portable_pack_run.step.dependOn(&sfizz_cmd.step);
    portable_pack_run.addArgs(&.{ "portable-pack", portable_piano_path, ".zig-cache/portable/accurate-salamander-grand.scorebank" });
    const portable_pack_step = b.step("portable-piano", "Compile the licensed local SFZ into the shared browser/iOS sampled-grand bank");
    portable_pack_step.dependOn(&portable_pack_run.step);
    const portable_verify_run = b.addRunArtifact(sampler_workbench);
    portable_verify_run.step.dependOn(&portable_pack_run.step);
    portable_verify_run.addArgs(&.{ "portable-verify", ".zig-cache/portable/accurate-salamander-grand.scorebank", ".zig-cache/verification/portable-grand.wav" });
    const portable_verify_step = b.step("portable-piano-verify", "Verify the shared browser/iOS sampled-grand dynamics, attack, sustain, and safety");
    portable_verify_step.dependOn(&portable_verify_run.step);

    const native = b.addExecutable(.{
        .name = "score",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/platform/native/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "score", .module = score }},
        }),
    });
    native.step.dependOn(&sfizz_cmd.step);
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
    native.root_module.linkFramework("CoreFoundation", .{});
    native.root_module.linkFramework("CoreGraphics", .{});
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
    bundle_cmd.step.dependOn(&sfizz_cmd.step);
    bundle_step.dependOn(&bundle_cmd.step);
    const native_release_step = b.step("macos-release", "Build the signed macOS bundle and pass the installed concert-grand audio gate");
    native_release_step.dependOn(&bundle_cmd.step);
    native_release_step.dependOn(&native_sampler_gate.step);

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
    if (b.args) |args| run_native_cmd.addArgs(args);
    const native_step = b.step("native", "Run the native WebGPU application");
    native_step.dependOn(&run_native_cmd.step);

    const dev_step = b.step("dev", "Run native app and rebuild hot-reloadable systems on change");
    const dev_cmd = b.addSystemCommand(&.{ "sh", "scripts/dev-native.sh" });
    if (b.args) |args| dev_cmd.addArgs(args);
    dev_step.dependOn(&dev_cmd.step);

    const run_cmd = b.addRunArtifact(diagnostic);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the headless engine diagnostic");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{ .root_module = score });
    const run_tests = b.addRunArtifact(tests);
    const workbench_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/score_workbench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "score", .module = score }},
        }),
    });
    const run_workbench_tests = b.addRunArtifact(workbench_tests);
    const test_step = b.step("test", "Run portable engine tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_workbench_tests.step);

    const web_step = b.step("web", "Build the Wasm/WebGPU export with Emscripten");
    const web_cmd = b.addSystemCommand(&.{ "sh", "scripts/build-web.sh" });
    web_cmd.step.dependOn(&portable_pack_run.step);
    web_step.dependOn(&web_cmd.step);

    const web_dev_step = b.step("dev-web", "Serve and statefully hot-reload the Wasm/WebGPU application");
    const web_dev_cmd = b.addSystemCommand(&.{ "sh", "scripts/dev-web.sh" });
    web_dev_cmd.step.dependOn(&portable_pack_run.step);
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
    ios_app_cmd.step.dependOn(&portable_pack_run.step);
    ios_app_cmd.step.dependOn(ios_step);
    ios_app_step.dependOn(&ios_app_cmd.step);

    const ios_device_installer = b.addExecutable(.{
        .name = "score-ios-device-install",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/ios_device_install.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    const ios_device_install_run = b.addRunArtifact(ios_device_installer);
    ios_device_install_run.step.dependOn(&ios_app_cmd.step);
    if (b.args) |args| ios_device_install_run.addArgs(args);
    const ios_device_install_step = b.step("install-ios-device", "Build, provision, install, and launch Score on a connected physical iPad");
    ios_device_install_step.dependOn(&ios_device_install_run.step);

    const ios_simulator_step = b.step("ios-simulator", "Build an ad-hoc signed arm64 iOS Simulator application");
    const ios_simulator_cmd = b.addSystemCommand(&.{ "sh", "scripts/build-ios-app.sh", "simulator" });
    ios_simulator_cmd.step.dependOn(&portable_pack_run.step);
    ios_simulator_step.dependOn(&ios_simulator_cmd.step);

    const ios_dev_step = b.step("dev-ios", "Run the iOS Simulator and hot-reload last-good Metal shader edits");
    const ios_dev_cmd = b.addSystemCommand(&.{ "sh", "scripts/dev-ios.sh" });
    ios_dev_cmd.step.dependOn(&portable_pack_run.step);
    ios_dev_step.dependOn(&ios_dev_cmd.step);
}
