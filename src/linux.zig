const std = @import("std");
const Tunnel = @import("ztunnel");
const builtin = @import("builtin");

const c = @cImport({
    @cInclude("termios.h");
    @cInclude("sys/ioctl.h");
    @cInclude(if (builtin.os.tag == .freebsd) "libutil.h" else "pty.h");
});

const Self = @This();

master: std.posix.fd_t,
allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator, shell: []const u8) !Self {
    // TODO: handle winsize
    var fd: std.posix.fd_t = 0;
    const pid = c.forkpty(&fd, null, null, null);
    if (pid < 0) return error.ForkPTY;
    if (pid == 0) std.process.execv(allocator, &[_][]const u8{shell}) catch {};

    return .{
        .master = fd,
        .allocator = allocator,
    };
}

pub fn resize(self: *Self, cols: c_ushort, rows: c_ushort) void {
    const winsize: c.winsize = std.mem.zeroInit(c.winsize, .{
        .ws_row = rows,
        .ws_col = cols,
    });
    _ = c.ioctl(self.master, c.TIOCSWINSZ, &winsize);
}

pub fn run(self: *Self, tunnel: Tunnel) !void {
    var fds = [_]std.posix.pollfd{
        .{
            .fd = self.master,
            .events = 1,
            .revents = 0,
        },
        .{
            .fd = tunnel.stream.handle,
            .events = 1,
            .revents = 0,
        },
    };

    var buffer: [4096]u8 = undefined;

    while (true) {
        if (try std.posix.poll(&fds, -1) == 0) continue;
        if (fds[0].revents != 0) {
            const size = std.posix.read(fds[0].fd, &buffer) catch |err| switch (err) {
                error.InputOutput => break,
                else => return err,
            };
            if (size == 0) continue;
            try tunnel.writeFrame(buffer[0..size]);
        }
        if (fds[1].revents != 0) {
            const data = try tunnel.readFrame(self.allocator);
            defer self.allocator.free(data);
            if (data.len == 8 and std.mem.startsWith(u8, data, "\x00\xff\x00\xff")) {
                const cols = std.mem.readInt(u16, data[4..][0..2], .big);
                const rows = std.mem.readInt(u16, data[6..][0..2], .big);
                self.resize(cols, rows);
                continue;
            }
            _ = try std.posix.write(fds[0].fd, data);
        }
    }
}
