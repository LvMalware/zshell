const std = @import("std");
const Tunnel = @import("ztunnel");

const Self = @This();

server: std.net.Server,
keypair: Tunnel.KeyPair,
allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator, host: []const u8, port: u16, keypair: Tunnel.KeyPair) !Self {
    const addr = try std.net.Address.parseIp(host, port);
    return .{
        .server = try addr.listen(.{ .reuse_address = true }),
        .keypair = keypair,
        .allocator = allocator,
    };
}

pub fn accept(self: *Self) !Tunnel {
    const connection = try self.server.accept();
    var client = Tunnel.init(self.allocator, connection.stream, self.keypair);
    errdefer client.deinit();
    try client.keyExchange(.server);
    return client;
}

pub fn deinit(self: *Self) void {
    self.server.deinit();
}
