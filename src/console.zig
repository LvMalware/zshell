const std = @import("std");
const Tunnel = @import("ztunnel");
const winapi = @import("winapi.zig");
const builtin = @import("builtin");

const c = @cImport({
    @cInclude("termios.h");
    @cInclude("sys/ioctl.h");
});

const SIGWINCH = 28;
var last_rows: i16 = 0;
var last_cols: i16 = 0;

const SignalHandler = ?*const fn (c_int) callconv(.C) void;
extern fn signal(sig: c_int, handler: SignalHandler) SignalHandler;

const Self = @This();

var conn: *Tunnel = undefined;

pub fn toogleTermRaw(handle: std.posix.fd_t) !void {
    if (builtin.os.tag == .windows) {
        var mode: std.os.windows.DWORD = 0;
        if (!winapi.GetConsoleMode(handle, &mode)) return error.GetConsoleMode;
        mode ^= 0x0004 | 0x0002 | 0x0001;
        if (!winapi.SetConsoleMode(handle, mode)) return error.SetConsoleMode;
    } else {
        var term = try std.posix.tcgetattr(handle);
        term.lflag.ECHO = !term.lflag.ECHO;
        term.lflag.ISIG = !term.lflag.ISIG;
        term.lflag.ICANON = !term.lflag.ICANON;
        try std.posix.tcsetattr(handle, .FLUSH, term);
    }
}

fn sigwinch(sig: c_int) callconv(.C) void {
    if (sig != SIGWINCH) return;
    var winsize: c.winsize = undefined;
    _ = std.c.ioctl(std.io.getStdIn().handle, c.TIOCGWINSZ, &winsize);
    var data: [8]u8 = undefined;
    std.mem.copyForwards(u8, &data, "\x00\xff\x00\xff");
    std.mem.writeInt(u16, data[4..][0..2], @truncate(winsize.ws_col), .big);
    std.mem.writeInt(u16, data[6..][0..2], @truncate(winsize.ws_row), .big);
    conn.writeFrame(&data) catch {};
}

allocator: std.mem.Allocator,
pub fn init(allocator: std.mem.Allocator, tun: *Tunnel) Self {
    conn = tun;
    return .{
        .allocator = allocator,
    };
}

pub fn run(self: Self) !void {
    const stdin = std.io.getStdIn();

    try toogleTermRaw(stdin.handle);
    defer toogleTermRaw(stdin.handle) catch {};

    if (builtin.os.tag == .windows) {
        try self.runWindows();
    } else {
        try self.runPosix();
    }
}

fn runPosix(self: Self) !void {
    const stdin = std.io.getStdIn();
    const stdout = std.io.getStdOut();
    var buffer: [4096]u8 = undefined;

    _ = signal(SIGWINCH, sigwinch);
    sigwinch(SIGWINCH);

    var fds = [_]std.posix.pollfd{
        .{
            .fd = stdin.handle,
            .events = 1,
            .revents = 0,
        },
        .{
            .fd = conn.stream.handle,
            .events = 1,
            .revents = 0,
        },
    };
    while (true) {
        if (std.posix.poll(&fds, -1) catch break == 0) continue;
        for (fds, 0..) |fd, i| {
            if (fd.revents == 0) continue;
            if (fd.revents == 16) return;
            switch (i) {
                0 => {
                    const size = try stdin.read(&buffer);
                    if (size == 0) continue;
                    try conn.writeFrame(buffer[0..size]);
                },
                1 => {
                    const data = conn.readFrame(self.allocator) catch return;
                    defer self.allocator.free(data);
                    try stdout.writeAll(data);
                },
                else => unreachable,
            }
        }
    }
}

// even though this function does nothing, we still need it because SleepEx won't know if the I/O operation was
// completed unless a completion routine is called... (yes, windows is sh*t like that)
fn overlap_callback(
    dwErrorCode: std.os.windows.DWORD,
    dwNumberOfBytesTransfered: std.os.windows.DWORD,
    lpOverlapped: ?*std.os.windows.OVERLAPPED,
) callconv(.C) void {
    _ = .{ lpOverlapped, dwErrorCode, dwNumberOfBytesTransfered };
    var csbi: std.os.windows.CONSOLE_SCREEN_BUFFER_INFO = undefined;

    const stdout = std.io.getStdOut().handle;
    if (std.os.windows.kernel32.GetConsoleScreenBufferInfo(stdout, &csbi) == 0) return;
    const rows = csbi.srWindow.Bottom - csbi.srWindow.Top + 1;
    const columns = csbi.srWindow.Right - csbi.srWindow.Left + 1;
    if (columns != last_cols or rows != last_rows) {
        last_cols = columns;
        last_rows = rows;
        var data: [8]u8 = undefined;
        std.mem.copyForwards(u8, &data, "\x00\xff\x00\xff");
        std.mem.writeInt(u16, data[4..][0..2], @bitCast(last_cols), .big);
        std.mem.writeInt(u16, data[6..][0..2], @bitCast(last_rows), .big);
        conn.writeFrame(&data) catch {};
    }
}

fn runWindows(self: Self) !void {
    var fds = [_]std.os.windows.ws2_32.pollfd{.{
        .fd = conn.stream.handle,
        .events = winapi.POLLRDNORM | winapi.POLLWRNORM,
        .revents = 0,
    }};

    var buffer: [4096]u8 = undefined;

    const hStdIn = winapi.CreateFileA(
        "CONIN$",
        std.os.windows.GENERIC_READ,
        std.os.windows.FILE_SHARE_WRITE,
        null,
        std.os.windows.OPEN_EXISTING,
        std.os.windows.FILE_FLAG_OVERLAPPED,
        null,
    );

    if (hStdIn == std.os.windows.INVALID_HANDLE_VALUE) return error.CreateFile;
    defer std.os.windows.CloseHandle(hStdIn);

    const stdout = std.io.getStdOut();

    var overlap: std.os.windows.OVERLAPPED = std.mem.zeroes(std.os.windows.OVERLAPPED);

    if (!winapi.ReadFileEx(hStdIn, &buffer, buffer.len, &overlap, overlap_callback)) return error.ReadFileEx;

    while (true) {
        if (std.os.windows.ws2_32.WSAPoll(&fds, fds.len, -1) == 0) continue;
        if (winapi.SleepEx(10, true) == winapi.WAIT_IO_COMPLETION) {
            try conn.writeFrame(buffer[0..overlap.InternalHigh]);
            overlap = std.mem.zeroes(std.os.windows.OVERLAPPED);
            if (!winapi.ReadFileEx(hStdIn, &buffer, buffer.len, &overlap, overlap_callback)) return error.ReadFileEx;
        }
        if (fds[0].revents & winapi.POLLRDNORM == 0) continue;
        const data = try conn.readFrame(self.allocator);
        defer self.allocator.free(data);
        try stdout.writeAll(data);
    }
}
