const std = @import("std");
const windows = std.os.windows;
const Tunnel = @import("ztunnel");
const winapi = @import("winapi.zig");

const Self = @This();

hPC: winapi.HPCON,
pAttr: []u8,
sInfo: winapi.STARTUPINFOEX,
pInfo: windows.PROCESS_INFORMATION,
hPipeIn: windows.HANDLE,
hPipeOut: windows.HANDLE,
allocator: std.mem.Allocator,
pub fn init(allocator: std.mem.Allocator, shell: []const u8) !Self {
    var conMode: windows.DWORD = 0;

    const hStdIn = winapi.CreateFileA(
        "CONIN$",
        windows.GENERIC_READ | windows.GENERIC_WRITE,
        windows.FILE_SHARE_READ | windows.FILE_SHARE_WRITE,
        null,
        windows.OPEN_EXISTING,
        windows.FILE_ATTRIBUTE_NORMAL,
        null,
    );

    if (hStdIn == windows.INVALID_HANDLE_VALUE) return error.CreateFileA;

    const hStdOut = winapi.CreateFileA(
        "CONOUT$",
        windows.GENERIC_READ | windows.GENERIC_WRITE,
        windows.FILE_SHARE_READ | windows.FILE_SHARE_WRITE,
        null,
        windows.OPEN_EXISTING,
        windows.FILE_ATTRIBUTE_NORMAL,
        null,
    );

    if (hStdOut == windows.INVALID_HANDLE_VALUE) return error.CreateFileA;

    if (windows.kernel32.GetConsoleMode(hStdOut, &conMode) == 0)
        return error.GetConsoleMode1;

    if (windows.kernel32.SetConsoleMode(
        hStdOut,
        conMode | windows.ENABLE_VIRTUAL_TERMINAL_PROCESSING | windows.DISABLE_NEWLINE_AUTO_RETURN,
    ) == 0) return error.SetConsoleMode1;

    if (!winapi.SetStdHandle(windows.STD_INPUT_HANDLE, hStdIn) or !winapi.SetStdHandle(windows.STD_OUTPUT_HANDLE, hStdOut))
        return error.SetStdHandle;

    var hPC: winapi.HPCON = undefined;
    var hPtyIn: windows.HANDLE = windows.INVALID_HANDLE_VALUE;
    var hPtyOut: windows.HANDLE = windows.INVALID_HANDLE_VALUE;

    var hPipeIn: windows.HANDLE = windows.INVALID_HANDLE_VALUE;
    var hPipeOut: windows.HANDLE = windows.INVALID_HANDLE_VALUE;

    try winapi.getOverlappedPipe(&hPtyOut, &hPipeOut);

    if (!winapi.CreatePipe(&hPtyIn, &hPipeIn, null, 1) or hPtyIn == windows.INVALID_HANDLE_VALUE)
        return error.CreatePipe;

    var csbi: windows.CONSOLE_SCREEN_BUFFER_INFO = undefined;
    var conSize: windows.COORD = undefined;

    if (windows.kernel32.GetConsoleScreenBufferInfo(hStdOut, &csbi) == 0)
        return error.GetConsoleScreenBufferInfo;

    conSize.X = 94; //csbi.srWindow.Right - csbi.srWindow.Left + 1;
    conSize.Y = 42; //csbi.srWindow.Bottom - csbi.srWindow.Top + 1;

    if (winapi.CreatePseudoConsole(conSize, hPtyIn, hPtyOut, 0, &hPC) != 0)
        return error.CreatePseudoConsole;

    var sInfo = std.mem.zeroInit(winapi.STARTUPINFOEX, .{
        .StartupInfo = .{
            .cb = @as(windows.DWORD, @truncate(@sizeOf(winapi.STARTUPINFO))),
        },
    });

    var attrListSize: usize = 0;
    _ = winapi.InitializeProcThreadAttributeList(null, 1, 0, &attrListSize);

    const pAttrList = try allocator.alloc(u8, attrListSize);

    sInfo.lpAttributeList = @ptrCast(pAttrList);
    if (!winapi.InitializeProcThreadAttributeList(sInfo.lpAttributeList, 1, 0, &attrListSize))
        return error.InitializeProcThreadAttributeList;

    if (!winapi.UpdateProcThreadAttribute(sInfo.lpAttributeList, 0, 0x00020016, hPC, @sizeOf(winapi.HPCON), null, null))
        return error.UpdateProcThreadAttribute;

    var pInfo: windows.PROCESS_INFORMATION = undefined;

    const zCmd = try allocator.dupeZ(u8, shell);
    defer allocator.free(zCmd);

    if (!winapi.CreateProcessA(
        null,
        zCmd,
        null,
        null,
        false,
        winapi.EXTENDED_STARTUPINFO_PRESENT,
        null,
        null,
        &sInfo,
        &pInfo,
    ))
        return error.CreateProcessA;

    return .{
        .hPC = hPC,
        .sInfo = sInfo,
        .pInfo = pInfo,
        .pAttr = pAttrList,
        .hPipeIn = hPipeIn,
        .hPipeOut = hPipeOut,
        .allocator = allocator,
    };
}

pub fn deinit(self: *Self) void {
    winapi.ClosePseudoConsole(self.hPC);
    windows.CloseHandle(self.hPipeIn);
    windows.CloseHandle(self.hPipeOut);

    _ = windows.kernel32.TerminateProcess(self.pInfo.hProcess, 0);
    windows.CloseHandle(self.pInfo.hThread);
    windows.CloseHandle(self.pInfo.hProcess);
    self.allocator.free(self.pAttr);
}

pub fn isAlive(self: Self) bool {
    var exitCode: windows.DWORD = 259;
    _ = windows.kernel32.GetExitCodeProcess(self.pInfo.hProcess, &exitCode);
    return exitCode == 259;
}

pub fn resize(self: *Self, cols: u16, rows: u16) void {
    _ = winapi.ResizePseudoConsole(self.hPC, .{
        .X = @bitCast(cols),
        .Y = @bitCast(rows),
    });
}

// even though this function does nothing, we still need it because SleepEx won't know if the I/O operation was
// completed unless a completion routine is called... (yes, windows is sh*t like that)
fn overlap_callback(
    dwErrorCode: std.os.windows.DWORD,
    dwNumberOfBytesTransfered: std.os.windows.DWORD,
    lpOverlapped: ?*std.os.windows.OVERLAPPED,
) callconv(.C) void {
    _ = .{ lpOverlapped, dwErrorCode, dwNumberOfBytesTransfered };
}

pub fn run(self: *Self, tunnel: Tunnel) !void {
    var fds = [_]std.os.windows.ws2_32.pollfd{.{
        .fd = tunnel.stream.handle,
        .events = winapi.POLLRDNORM | winapi.POLLWRNORM,
        .revents = 0,
    }};

    defer self.deinit();

    var buffer: [4096]u8 = undefined;
    var overlap: windows.OVERLAPPED = std.mem.zeroes(windows.OVERLAPPED);

    if (!winapi.ReadFileEx(self.hPipeOut, &buffer, buffer.len, &overlap, overlap_callback)) {
        return error.ReadFileEx;
    }

    while (self.isAlive()) {
        if (std.os.windows.ws2_32.WSAPoll(&fds, fds.len, -1) == 0) continue;
        if (winapi.SleepEx(10, true) == winapi.WAIT_IO_COMPLETION) {
            try tunnel.writeFrame(buffer[0..overlap.InternalHigh]);
            overlap = std.mem.zeroes(windows.OVERLAPPED);
            if (!winapi.ReadFileEx(self.hPipeOut, &buffer, buffer.len, &overlap, overlap_callback)) {
                return error.ReadFileEx;
            }
        }

        if (fds[0].revents & winapi.POLLRDNORM == 0) continue;
        const data = try tunnel.readFrame(self.allocator);
        defer self.allocator.free(data);

        if (data.len == 8 and std.mem.startsWith(u8, data, "\x00\xff\x00\xff")) {
            const cols = std.mem.readInt(u16, data[4..][0..2], .big);
            const rows = std.mem.readInt(u16, data[6..][0..2], .big);
            self.resize(cols, rows);
            continue;
        }

        if (data.len == 0) continue;

        if (std.mem.indexOf(u8, data, "\r\n") == null and std.mem.indexOf(u8, data, "\n") != null) {
            const unix2dos = try std.mem.replaceOwned(u8, self.allocator, data, "\n", "\r\n");
            defer self.allocator.free(unix2dos);
            _ = try windows.WriteFile(self.hPipeIn, unix2dos, null);
        } else {
            _ = try windows.WriteFile(self.hPipeIn, data, null);
        }
    }
}
