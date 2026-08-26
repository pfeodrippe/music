const std = @import("std");

const c = @cImport({
    @cInclude("music_devices.h");
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
    @cInclude("sys/time.h");
    @cInclude("stdlib.h");
    @cInclude("unistd.h");
});

fn runBitwigBootstrap() !void {
    const service = c.score_midi_create_named("Score Bridge Bootstrap") orelse return error.BootstrapSourceCreateFailed;
    defer c.score_midi_destroy(service);

    std.debug.print("Score Bridge Bootstrap is active; keep this process running while Bitwig uses the OSC bridge.\n", .{});
    while (true) _ = c.sleep(1);
}

pub fn main(init: std.process.Init) !void {
    var command_buffer: [4096]u8 = undefined;
    var command_len: usize = 0;
    var arguments = std.process.Args.Iterator.init(init.minimal.args);
    _ = arguments.next();
    if (arguments.next()) |first| {
        if (std.mem.eql(u8, first, "bitwig-bootstrap")) {
            if (arguments.next() != null) return error.UnexpectedBootstrapArgument;
            return runBitwigBootstrap();
        }
        if (first.len > command_buffer.len) return error.CommandTooLong;
        @memcpy(command_buffer[0..first.len], first);
        command_len = first.len;
    }
    while (arguments.next()) |argument| {
        if (command_len != 0) {
            command_buffer[command_len] = ' ';
            command_len += 1;
        }
        if (command_len + argument.len > command_buffer.len) return error.CommandTooLong;
        @memcpy(command_buffer[command_len .. command_len + argument.len], argument);
        command_len += argument.len;
    }
    if (command_len == 0) {
        @memcpy(command_buffer[0..5], "state");
        command_len = 5;
    }

    var path_buffer: [104:0]u8 = [_:0]u8{0} ** 104;
    const configured = c.getenv("SCORE_DEV_SOCKET");
    const path = if (configured != null and configured[0] != 0)
        std.mem.span(configured)
    else
        std.fmt.bufPrint(path_buffer[0 .. path_buffer.len - 1], "/tmp/score-dev-{d}.sock", .{c.getuid()}) catch return error.SocketPathTooLong;
    if (path.len >= path_buffer.len) return error.SocketPathTooLong;
    if (configured != null and configured[0] != 0) @memcpy(path_buffer[0..path.len], path);
    path_buffer[path.len] = 0;

    const socket = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
    if (socket < 0) return error.SocketCreateFailed;
    defer _ = c.close(socket);
    var address: c.struct_sockaddr_un = std.mem.zeroes(c.struct_sockaddr_un);
    const address_len: c.socklen_t = @intCast(@offsetOf(c.struct_sockaddr_un, "sun_path") + path.len + 1);
    address.sun_len = @intCast(address_len);
    address.sun_family = c.AF_UNIX;
    const destination: [*]u8 = @ptrCast(&address.sun_path);
    @memcpy(destination[0 .. path.len + 1], path_buffer[0 .. path.len + 1]);
    if (c.connect(socket, @ptrCast(&address), address_len) != 0) {
        std.debug.print("score-devctl: no Debug app at {s}\n", .{path});
        return error.ControlSocketUnavailable;
    }

    var timeout = c.struct_timeval{ .tv_sec = 3, .tv_usec = 0 };
    _ = c.setsockopt(socket, c.SOL_SOCKET, c.SO_RCVTIMEO, &timeout, @sizeOf(c.struct_timeval));
    if (c.send(socket, &command_buffer, command_len, 0) != command_len) return error.SendFailed;
    var response: [4096]u8 = undefined;
    const received = c.recv(socket, &response, response.len, 0);
    if (received <= 0) return error.ResponseTimeout;
    std.debug.print("{s}\n", .{response[0..@intCast(received)]});
}
