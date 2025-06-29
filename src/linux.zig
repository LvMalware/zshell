const std = @import("std");
const Tunnel = @import("ztunnel");
const builtin = @import("builtin");

const Self = @This();

process: std.process.Child,
allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator, shell: []const u8) !Self {
    var process = std.process.Child.init(&[_][]const u8{shell}, allocator);

    process.stdin_behavior = .Pipe;
    process.stdout_behavior = .Pipe;
    process.stderr_behavior = .Pipe;

    try process.spawn();
    return .{
        .process = process,
        .allocator = allocator,
    };
}

pub fn run(self: *Self, tunnel: Tunnel) !void {
    try self.process.stdin.?.writeAll("script -q /dev/null && exit\n");
    var fds = [_]std.posix.pollfd{
        .{
            .fd = self.process.stdout.?.handle,
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

        for (fds, 0..) |fd, i| {
            if (fd.revents == 0) continue;
            switch (i) {
                0 => {
                    if (fd.revents == 16) return;
                    const size = try self.process.stdout.?.read(&buffer);
                    if (size == 0) continue;
                    try tunnel.writeFrame(buffer[0..size]);
                },
                1 => {
                    const data = try tunnel.readFrame(self.allocator);
                    defer self.allocator.free(data);
                    try self.process.stdin.?.writeAll(data);
                },
                else => unreachable,
            }
            fds[i].revents = 0;
        }
    }
}
