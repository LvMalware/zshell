const std = @import("std");
const builtin = @import("builtin");

const flags = @import("flags");
const Shell = @import("shell.zig");
const Tunnel = @import("ztunnel");
const Server = @import("server.zig");
const Console = @import("console.zig");

fn setNonBlock(sock: std.net.Stream) void {
    if (builtin.os.tag == .windows) {
        var mode: u32 = 1;
        _ = std.os.windows.ws2_32.ioctlsocket(sock.handle, std.os.windows.ws2_32.FIONBIO, &mode);
        var nodelay: u8 = 1;
        _ = std.os.windows.ws2_32.setsockopt(
            sock.handle,
            std.os.windows.ws2_32.IPPROTO.TCP,
            std.os.windows.ws2_32.TCP.NODELAY,
            @ptrCast(&nodelay),
            @sizeOf(u8),
        );
    } else {
        const mode = std.posix.fcntl(sock.handle, std.c.F.GETFL, 0) catch unreachable;
        if (mode == -1) return;
        _ = std.posix.fcntl(sock.handle, std.c.F.SETFL, mode | 0x40000009) catch unreachable;
    }
}

fn serverThread(allocator: std.mem.Allocator, client: *Tunnel, command: ?[]const u8) void {
    defer client.deinit();
    var shell = Shell.init(allocator, command) catch return;
    shell.run(client.*) catch {};
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const parsed = try flags.parse(
        .{
            .{ "help", bool, false, "Show this help message and exit" },
            .{ "port", u16, 1337, "Port to listen/connect (default: 1337)" },
            .{ "host", ?[]const u8, null, "Host to listen/connect" },
            .{ "save", ?[]const u8, null, "File to save private key" },
            .{ "shell", ?[]const u8, null, "Shell/command to be served to the client" },
            .{ "print", bool, false, "Print public ECC keys to stdout" },
            .{ "server", bool, false, "Act as a server" },
            .{ "public", ?[]const u8, null, "File containning public keys (one per line) to authenticate client (in server mode)" },
            .{ "private", ?[]const u8, null, "File containning private key to use" },
            .{ "reverse", bool, false, "Server will receive a shell / Client will send a shell" },
        },
        allocator,
    );
    defer parsed.deinit();

    const stdout = std.io.getStdOut().writer();

    if (parsed.flags.help) {
        try stdout.print("Usage: {s} [options]\nOptions: \n", .{parsed.prog});
        try parsed.writeHelp(stdout);
        return;
    }

    const keypair = if (parsed.flags.private) |filename| priv: {
        const file = try std.fs.cwd().openFile(filename, .{});
        defer file.close();
        const data = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
        defer allocator.free(data);

        const private = try Tunnel.PrivateKey.fromBytes(data);
        const public = Tunnel.PublicKey{
            .ecc = try std.crypto.dh.X25519.recoverPublicKey(private.ecc),
            .kyber = .{
                .pk = private.kyber.pk,
                .hpk = private.kyber.hpk,
            },
        };

        break :priv Tunnel.KeyPair{ .public = public, .private = private };
    } else Tunnel.KeyPair.generate();

    if (parsed.flags.print) {
        const base64 = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(keypair.public.ecc.len));
        _ = std.base64.standard.Encoder.encode(base64[0..], &keypair.public.ecc);
        try stdout.print("ECC Public Key: {s}\n", .{base64});
        defer allocator.free(base64);
    }

    if (parsed.flags.save) |filename| {
        const file = try std.fs.cwd().createFile(filename, .{});
        defer file.close();
        try file.writeAll(&keypair.private.toBytes());
    }

    if (parsed.flags.server) {
        var server = try Server.init(allocator, parsed.flags.host orelse "0.0.0.0", parsed.flags.port, keypair);
        defer server.deinit();
        if (parsed.flags.public) |path| {
            try server.loadPeers(path);
        }
        while (true) {
            var client = server.accept() catch continue;
            setNonBlock(client.stream);
            if (parsed.flags.reverse) {
                defer client.deinit();
                try Console.init(allocator, &client).run();
                break;
            } else {
                var thread = std.Thread.spawn(.{}, serverThread, .{ allocator, &client, parsed.flags.shell }) catch {
                    client.deinit();
                    continue;
                };
                thread.detach();
            }
        }
    } else {
        if (parsed.flags.host == null) {
            try stdout.print("Missing host to connect\n", .{});
            return;
        }
        const stream = try std.net.tcpConnectToHost(allocator, parsed.flags.host.?, parsed.flags.port);
        var tunnel = Tunnel.init(allocator, stream, keypair);
        try tunnel.keyExchange(.client);

        setNonBlock(stream);

        if (parsed.flags.reverse) {
            var shell = try Shell.init(allocator, parsed.flags.shell);
            try shell.run(tunnel);
        } else {
            try Console.init(allocator, &tunnel).run();
        }
    }
}
