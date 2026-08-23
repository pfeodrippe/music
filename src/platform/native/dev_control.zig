const std = @import("std");

const c = @cImport({
    @cInclude("sys/socket.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/un.h");
    @cInclude("sys/time.h");
    @cInclude("fcntl.h");
    @cInclude("stdlib.h");
    @cInclude("unistd.h");
});

pub const max_command_bytes = 4096;
pub const max_response_bytes = 4096;

pub const Client = struct {
    fd: c_int,
    command_len: usize,

    pub fn respond(self: Client, value: []const u8) void {
        _ = c.send(self.fd, value.ptr, value.len, 0);
        _ = c.close(self.fd);
    }
};

/// A loopback-only Unix-domain control server used by Debug builds. It is
/// polled at the native frame boundary, so commands cannot race Flecs systems,
/// hot-module replacement, GPU packet creation, or score import.
pub const Server = struct {
    fd: c_int,
    path: [104:0]u8,
    path_len: usize,

    pub fn init() !Server {
        const configured = c.getenv("SCORE_DEV_SOCKET");
        if (configured != null and configured[0] != 0) return initAt(std.mem.span(configured));
        var path_buffer: [104]u8 = undefined;
        const value = std.fmt.bufPrint(&path_buffer, "/tmp/score-dev-{d}.sock", .{c.getuid()}) catch return error.SocketPathTooLong;
        return initAt(value);
    }

    fn initAt(value: []const u8) !Server {
        var self = Server{ .fd = -1, .path = [_:0]u8{0} ** 104, .path_len = 0 };
        if (value.len >= self.path.len) return error.SocketPathTooLong;
        @memcpy(self.path[0..value.len], value);
        self.path[value.len] = 0;
        self.path_len = value.len;

        self.fd = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
        if (self.fd < 0) return error.SocketCreateFailed;
        errdefer _ = c.close(self.fd);

        var address: c.struct_sockaddr_un = std.mem.zeroes(c.struct_sockaddr_un);
        const address_len: c.socklen_t = @intCast(@offsetOf(c.struct_sockaddr_un, "sun_path") + self.path_len + 1);
        address.sun_len = @intCast(address_len);
        address.sun_family = c.AF_UNIX;
        const destination: [*]u8 = @ptrCast(&address.sun_path);
        @memcpy(destination[0 .. self.path_len + 1], self.path[0 .. self.path_len + 1]);
        if (c.bind(self.fd, @ptrCast(&address), address_len) != 0) {
            const probe = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
            if (probe >= 0) {
                const live = c.connect(probe, @ptrCast(&address), address_len) == 0;
                _ = c.close(probe);
                if (live) return error.SocketInUse;
            }
            _ = c.unlink(self.path[0..self.path_len :0].ptr);
            if (c.bind(self.fd, @ptrCast(&address), address_len) != 0) return error.SocketBindFailed;
        }
        if (c.chmod(self.path[0..self.path_len :0].ptr, 0o600) != 0) return error.SocketPermissionsFailed;
        if (c.listen(self.fd, 8) != 0) return error.SocketListenFailed;
        if (c.fcntl(self.fd, c.F_SETFL, c.O_NONBLOCK) < 0) return error.SocketNonBlockingFailed;
        return self;
    }

    pub fn deinit(self: *Server) void {
        if (self.fd >= 0) _ = c.close(self.fd);
        if (self.path_len != 0) _ = c.unlink(self.path[0..self.path_len :0].ptr);
        self.fd = -1;
        self.path_len = 0;
    }

    pub fn poll(self: *Server, command: *[max_command_bytes]u8) ?Client {
        const client = c.accept(self.fd, null, null);
        if (client < 0) return null;
        var timeout = c.struct_timeval{ .tv_sec = 0, .tv_usec = 20_000 };
        _ = c.setsockopt(client, c.SOL_SOCKET, c.SO_RCVTIMEO, &timeout, @sizeOf(c.struct_timeval));
        const received = c.recv(client, command, command.len, 0);
        if (received <= 0) {
            _ = c.close(client);
            return null;
        }
        return .{ .fd = client, .command_len = @intCast(received) };
    }

    pub fn pathSlice(self: *const Server) []const u8 {
        return self.path[0..self.path_len];
    }
};

test "a second dev server cannot steal a live control socket" {
    var path_buffer: [104:0]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buffer, "/tmp/score-dev-test-{d}.sock", .{c.getpid()});
    _ = c.unlink(path.ptr);
    var first = try Server.initAt(path);
    defer first.deinit();
    try std.testing.expectError(error.SocketInUse, Server.initAt(path));
}
