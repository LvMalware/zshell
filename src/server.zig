const std = @import("std");
const X25519 = std.crypto.dh.X25519;
const Tunnel = @import("ztunnel");

const Self = @This();

server: std.net.Server,
keypair: Tunnel.KeyPair,
allowed: std.ArrayList([]u8),
allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator, host: []const u8, port: u16, keypair: Tunnel.KeyPair) !Self {
    const addr = try std.net.Address.parseIp(host, port);
    return .{
        .server = try addr.listen(.{ .reuse_address = true }),
        .keypair = keypair,
        .allowed = std.ArrayList([]u8).init(allocator),
        .allocator = allocator,
    };
}

pub fn loadPeers(self: *Self, path: []const u8) !void {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const data = try file.readToEndAlloc(self.allocator, std.math.maxInt(usize));
    defer self.allocator.free(data);
    var lines = std.mem.splitScalar(u8, data, '\n');
    var plain: [X25519.public_length]u8 = undefined;
    while (lines.next()) |base64| {
        if (base64.len < 10) continue;
        try std.base64.standard.Decoder.decode(&plain, base64);
        try self.allowed.append(try self.allocator.dupe(u8, &plain));
    }
}

pub fn accept(self: *Self) !Tunnel {
    const connection = try self.server.accept();
    var client = Tunnel.init(self.allocator, connection.stream, self.keypair);
    errdefer client.deinit();
    for (self.allowed.items) |public| {
        try client.addAllowed(public[0..X25519.public_length].*);
    }
    try client.keyExchange(.server);
    return client;
}

pub fn deinit(self: *Self) void {
    self.server.deinit();
    for (self.allowed.items) |public| {
        self.allocator.free(public);
    }
    self.allowed.deinit();
}
