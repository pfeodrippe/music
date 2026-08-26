const std = @import("std");

const bundle_id = "app.score.practice.ios";
const app_path = "build/ios/Score.app";
const work_path = ".zig-cache/ios-device-install";

const Options = struct {
    device: ?[]const u8 = null,
    profile: ?[]const u8 = null,
    identity: ?[]const u8 = null,
    launch: bool = true,
};

pub fn main(init: std.process.Init) !void {
    if (@import("builtin").os.tag != .macos) return error.MacOSRequired;

    var options: Options = .{};
    var arguments = std.process.Args.Iterator.init(init.minimal.args);
    _ = arguments.next();
    while (arguments.next()) |argument| {
        if (std.mem.eql(u8, argument, "--device")) {
            options.device = arguments.next() orelse return usage(error.MissingArgument);
        } else if (std.mem.eql(u8, argument, "--profile")) {
            options.profile = arguments.next() orelse return usage(error.MissingArgument);
        } else if (std.mem.eql(u8, argument, "--identity")) {
            options.identity = arguments.next() orelse return usage(error.MissingArgument);
        } else if (std.mem.eql(u8, argument, "--no-launch")) {
            options.launch = false;
        } else if (std.mem.eql(u8, argument, "--help") or std.mem.eql(u8, argument, "-h")) {
            usage(null) catch {};
            return;
        } else {
            std.debug.print("unknown option: {s}\n", .{argument});
            return usage(error.UnknownOption);
        }
    }

    try std.Io.Dir.cwd().createDirPath(init.io, work_path);

    const device = if (options.device) |configured|
        try init.gpa.dupe(u8, configured)
    else if (init.environ_map.get("SCORE_IOS_DEVICE")) |configured|
        try init.gpa.dupe(u8, configured)
    else
        try detectDevice(init);
    defer init.gpa.free(device);

    const identity = if (options.identity) |configured|
        try init.gpa.dupe(u8, configured)
    else if (init.environ_map.get("SCORE_IOS_SIGN_IDENTITY")) |configured|
        try init.gpa.dupe(u8, configured)
    else
        try detectIdentity(init);
    defer init.gpa.free(identity);

    const profile = if (options.profile) |configured|
        try init.gpa.dupe(u8, configured)
    else if (init.environ_map.get("SCORE_IOS_PROFILE")) |configured|
        try init.gpa.dupe(u8, configured)
    else
        try detectProfile(init);
    defer init.gpa.free(profile);

    std.debug.print("iPad device: {s}\n", .{device});
    std.debug.print("signing identity: {s}\n", .{identity});
    std.debug.print("provisioning profile: {s}\n", .{profile});

    try runChecked(init, &.{ "/bin/cp", profile, app_path ++ "/embedded.mobileprovision" });
    try runChecked(init, &.{ "/usr/bin/security", "cms", "-D", "-i", profile, "-o", work_path ++ "/profile.plist" });
    try runChecked(init, &.{ "/usr/bin/plutil", "-extract", "Entitlements", "xml1", "-o", work_path ++ "/entitlements.plist", work_path ++ "/profile.plist" });
    try runChecked(init, &.{ "/usr/bin/codesign", "--force", "--sign", identity, "--entitlements", work_path ++ "/entitlements.plist", "--timestamp=none", app_path });
    try runChecked(init, &.{ "/usr/bin/codesign", "--verify", "--deep", "--strict", app_path });
    try runChecked(init, &.{ "/usr/bin/xcrun", "devicectl", "device", "install", "app", "--device", device, app_path });
    if (options.launch) try runChecked(init, &.{ "/usr/bin/xcrun", "devicectl", "device", "process", "launch", "--device", device, "--terminate-existing", bundle_id });

    std.debug.print("Score installed{s}.\n", .{if (options.launch) " and launched" else ""});
}

fn usage(err: ?anyerror) anyerror!void {
    std.debug.print(
        \\usage: zig build install-ios-device -- [--device ID] [--profile FILE] [--identity HASH] [--no-launch]
        \\
        \\Defaults auto-detect the first connected physical iPad, the first Apple Development identity,
        \\and the provisioning profile for app.score.practice.ios. SCORE_IOS_DEVICE,
        \\SCORE_IOS_PROFILE, and SCORE_IOS_SIGN_IDENTITY override those defaults.
        \\
    , .{});
    if (err) |value| return value;
}

fn detectDevice(init: std.process.Init) ![]u8 {
    const result = try runCapture(init, &.{ "/usr/bin/xcrun", "devicectl", "list", "devices" });
    defer freeResult(init.gpa, result);
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        // Current CoreDevice reports a paired iPad as `available (paired)`
        // even when its developer tunnel is connected. Older Xcode releases
        // printed `connected`, so accept both spellings.
        if (std.mem.indexOf(u8, line, "connected") == null and
            std.mem.indexOf(u8, line, "available (paired)") == null) continue;
        var tokens = std.mem.tokenizeAny(u8, line, " \t");
        while (tokens.next()) |token| {
            if (looksLikeUuid(token)) return init.gpa.dupe(u8, token);
        }
    }
    return error.NoConnectedIOSDevice;
}

fn detectIdentity(init: std.process.Init) ![]u8 {
    const result = try runCapture(init, &.{ "/usr/bin/security", "find-identity", "-v", "-p", "codesigning" });
    defer freeResult(init.gpa, result);
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "Apple Development:") == null) continue;
        var tokens = std.mem.tokenizeAny(u8, line, " \t)");
        while (tokens.next()) |token| {
            if (token.len == 40 and allHex(token)) return init.gpa.dupe(u8, token);
        }
    }
    return error.NoAppleDevelopmentIdentity;
}

fn detectProfile(init: std.process.Init) ![]u8 {
    const home = init.environ_map.get("HOME") orelse return error.HomeNotConfigured;
    const directory = try std.fmt.allocPrint(init.gpa, "{s}/Library/Developer/Xcode/UserData/Provisioning Profiles", .{home});
    defer init.gpa.free(directory);
    const found = try runCapture(init, &.{ "/usr/bin/find", directory, "-type", "f", "-name", "*.mobileprovision" });
    defer freeResult(init.gpa, found);
    var lines = std.mem.splitScalar(u8, found.stdout, '\n');
    while (lines.next()) |path| {
        if (path.len == 0) continue;
        const decoded = runCapture(init, &.{ "/usr/bin/security", "cms", "-D", "-i", path }) catch continue;
        defer freeResult(init.gpa, decoded);
        if (std.mem.indexOf(u8, decoded.stdout, bundle_id) != null) return init.gpa.dupe(u8, path);
    }
    return error.NoMatchingProvisioningProfile;
}

fn runCapture(init: std.process.Init, argv: []const []const u8) !std.process.RunResult {
    const result = try std.process.run(init.gpa, init.io, .{
        .argv = argv,
        .stdout_limit = .limited(16 * 1024 * 1024),
        .stderr_limit = .limited(16 * 1024 * 1024),
    });
    if (!termSucceeded(result.term)) {
        if (result.stdout.len != 0) std.debug.print("{s}", .{result.stdout});
        if (result.stderr.len != 0) std.debug.print("{s}", .{result.stderr});
        freeResult(init.gpa, result);
        return error.CommandFailed;
    }
    return result;
}

fn runChecked(init: std.process.Init, argv: []const []const u8) !void {
    const result = try runCapture(init, argv);
    defer freeResult(init.gpa, result);
    if (result.stdout.len != 0) std.debug.print("{s}", .{result.stdout});
    if (result.stderr.len != 0) std.debug.print("{s}", .{result.stderr});
}

fn freeResult(allocator: std.mem.Allocator, result: std.process.RunResult) void {
    allocator.free(result.stdout);
    allocator.free(result.stderr);
}

fn termSucceeded(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |status| status == 0,
        else => false,
    };
}

fn looksLikeUuid(value: []const u8) bool {
    if (value.len != 36 or value[8] != '-' or value[13] != '-' or value[18] != '-' or value[23] != '-') return false;
    for (value, 0..) |byte, index| {
        if (index == 8 or index == 13 or index == 18 or index == 23) continue;
        if (!std.ascii.isHex(byte)) return false;
    }
    return true;
}

fn allHex(value: []const u8) bool {
    for (value) |byte| if (!std.ascii.isHex(byte)) return false;
    return true;
}
