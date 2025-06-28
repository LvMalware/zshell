const std = @import("std");
const windows = std.os.windows;
const Tunnel = @import("ztunnel");

const Self = @This();

const HPCON = windows.HANDLE;

const EXTENDED_STARTUPINFO_PRESENT = 0x00080000;

const STARTUPINFO = extern struct {
    cb: windows.DWORD,
    lpReserved: ?windows.LPSTR,
    lpDesktop: ?windows.LPSTR,
    lpTitle: ?windows.LPSTR,
    dwX: windows.DWORD,
    dwY: windows.DWORD,
    dwXSize: windows.DWORD,
    dwYSize: windows.DWORD,
    dwXCountChars: windows.DWORD,
    dwYCountChars: windows.DWORD,
    dwFillAttribute: windows.DWORD,
    dwFlags: windows.DWORD,
    wShowWindow: windows.WORD,
    cbReserved2: windows.WORD,
    lpReserved2: ?*anyopaque,
    hStdInput: ?windows.HANDLE,
    hStdOutput: ?windows.HANDLE,
    hStdError: ?windows.HANDLE,
};

const STARTUPINFOEX = extern struct {
    StartupInfo: STARTUPINFO,
    lpAttributeList: ?*anyopaque,
};

extern "kernel32" fn CreatePseudoConsole(
    size: windows.COORD,
    hInput: windows.HANDLE,
    hOutput: windows.HANDLE,
    dwFlags: windows.DWORD,
    phPC: *HPCON,
) callconv(.C) windows.HRESULT;

extern "kernel32" fn ResizePseudoConsole(
    hPC: HPCON,
    size: windows.COORD,
) callconv(.C) windows.HRESULT;

extern "kernel32" fn ClosePseudoConsole(
    hPC: HPCON,
) callconv(.C) void;

extern "kernel32" fn CreatePipe(
    hReadPipe: *windows.HANDLE,
    hWritePipe: *windows.HANDLE,
    lpPipeAttributes: ?*anyopaque,
    nSize: windows.DWORD,
) callconv(.C) bool;

extern "kernel32" fn InitializeProcThreadAttributeList(
    lpAttributeList: ?*anyopaque,
    dwAttributeCount: windows.DWORD,
    dwFlags: windows.DWORD,
    lpSize: *usize,
) callconv(.C) bool;

extern "kernel32" fn UpdateProcThreadAttribute(
    lpAttributeList: ?*anyopaque,
    dwFlags: windows.DWORD,
    Attribute: windows.DWORD,
    lpValue: *anyopaque,
    cbSize: usize,
    lpPreviousValue: ?*anyopaque,
    lpReturnSize: ?*usize,
) callconv(.C) bool;

extern "kernel32" fn CreateProcessA(
    lpApplicationName: ?[*:0]const u8,
    lpCommandLine: [*:0]const u8,
    lpProcessAttributes: ?*anyopaque,
    lpThreadAttributes: ?*anyopaque,
    bInheritHandles: bool,
    dwCreationFlags: windows.DWORD,
    lpEnvironment: ?*anyopaque,
    lpCurrentDirectory: ?[*:0]const u8,
    lpStartupInfo: *STARTUPINFOEX,
    lpProcessInformation: *windows.PROCESS_INFORMATION,
) callconv(.C) bool;

extern "kernel32" fn SetStdHandle(
    hId: windows.DWORD,
    hHandle: windows.HANDLE,
) callconv(.C) bool;

extern "kernel32" fn CreateFileA(
    lpFileName: [*:0]const u8,
    dwDesiredAccess: windows.DWORD,
    dwShareMode: windows.DWORD,
    lpSecurityAttributes: ?*anyopaque,
    dwCreationDisposition: windows.DWORD,
    dwFlagsAndAttributes: windows.DWORD,
    hTemplateFile: ?windows.HANDLE,
) callconv(.C) windows.HANDLE;

extern "kernel32" fn PeekNamedPipe(
    hNamedPipe: windows.HANDLE,
    lpBuffer: ?*u8,
    nBufferSize: windows.DWORD,
    lpBytesRead: ?*windows.DWORD,
    lpTotalBytesAvail: ?*windows.DWORD,
    lpBytesLeftThisMessage: ?*windows.WORD,
) callconv(.C) bool;

hPC: HPCON,
pAttr: []u8,
sInfo: STARTUPINFOEX,
pInfo: windows.PROCESS_INFORMATION,
hPipeIn: windows.HANDLE,
hPipeOut: windows.HANDLE,
allocator: std.mem.Allocator,
pub fn init(allocator: std.mem.Allocator, shell: ?[]const u8) !Self {
    var conMode: windows.DWORD = 0;

    const hStdIn = CreateFileA(
        "CONIN$",
        windows.GENERIC_READ | windows.GENERIC_WRITE,
        windows.FILE_SHARE_READ | windows.FILE_SHARE_WRITE,
        null,
        windows.OPEN_EXISTING,
        windows.FILE_ATTRIBUTE_NORMAL,
        null,
    );

    if (hStdIn == windows.INVALID_HANDLE_VALUE) return error.CreateFileA;

    const hStdOut = CreateFileA(
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

    if (!SetStdHandle(windows.STD_INPUT_HANDLE, hStdIn) or !SetStdHandle(windows.STD_OUTPUT_HANDLE, hStdOut))
        return error.SetStdHandle;

    var hPC: HPCON = undefined;
    var hPtyIn: windows.HANDLE = windows.INVALID_HANDLE_VALUE;
    var hPtyOut: windows.HANDLE = windows.INVALID_HANDLE_VALUE;

    var hPipeIn: windows.HANDLE = windows.INVALID_HANDLE_VALUE;
    var hPipeOut: windows.HANDLE = windows.INVALID_HANDLE_VALUE;

    if (!CreatePipe(&hPtyIn, &hPipeIn, null, 1) or hPtyIn == windows.INVALID_HANDLE_VALUE)
        return error.CreatePipe;

    if (!CreatePipe(&hPipeOut, &hPtyOut, null, 1) or hPtyOut == windows.INVALID_HANDLE_VALUE)
        return error.CreatePipe;

    var csbi: windows.CONSOLE_SCREEN_BUFFER_INFO = undefined;
    var conSize: windows.COORD = undefined;

    if (windows.kernel32.GetConsoleScreenBufferInfo(hStdOut, &csbi) == 0)
        return error.GetConsoleScreenBufferInfo;

    conSize.X = 94; //csbi.srWindow.Right - csbi.srWindow.Left + 1;
    conSize.Y = 42; //csbi.srWindow.Bottom - csbi.srWindow.Top + 1;

    if (CreatePseudoConsole(conSize, hPtyIn, hPtyOut, 0, &hPC) != 0)
        return error.CreatePseudoConsole;

    var sInfo = std.mem.zeroInit(STARTUPINFOEX, .{
        .StartupInfo = .{
            .cb = @as(windows.DWORD, @truncate(@sizeOf(STARTUPINFO))),
        },
    });

    var attrListSize: usize = 0;
    _ = InitializeProcThreadAttributeList(null, 1, 0, &attrListSize);

    const pAttrList = try allocator.alloc(u8, attrListSize);

    sInfo.lpAttributeList = @ptrCast(pAttrList);
    if (!InitializeProcThreadAttributeList(sInfo.lpAttributeList, 1, 0, &attrListSize))
        return error.InitializeProcThreadAttributeList;

    if (!UpdateProcThreadAttribute(sInfo.lpAttributeList, 0, 0x00020016, hPC, @sizeOf(HPCON), null, null))
        return error.UpdateProcThreadAttribute;

    var pInfo: windows.PROCESS_INFORMATION = undefined;

    const zCmd = try allocator.dupeZ(u8, shell orelse "powershell.exe");
    defer allocator.free(zCmd);

    if (!CreateProcessA(null, zCmd, null, null, false, EXTENDED_STARTUPINFO_PRESENT, null, null, &sInfo, &pInfo))
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
    ClosePseudoConsole(self.hPC);
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

fn pipeToTunnel(hPipe: windows.HANDLE, tunnel: Tunnel) void {
    var buffer: [1024]u8 = undefined;
    var size: windows.DWORD = 0;
    while (PeekNamedPipe(hPipe, null, 0, null, &size, null) and size > 0) {
        if (windows.kernel32.ReadFile(hPipe, buffer[0..], buffer.len, &size, null) != 0 and size > 0) {
            tunnel.writeFrame(buffer[0..size]) catch return;
        }
    }
}

const POLLRDNORM = 0x0100;
const POLLWRNORM = 0x0010;

pub fn run(self: *Self, tunnel: Tunnel) !void {
    var fds = [_]std.os.windows.ws2_32.pollfd{.{
        .fd = tunnel.stream.handle,
        .events = POLLRDNORM | POLLWRNORM,
        .revents = 0,
    }};

    while (self.isAlive()) {
        // TODO: This will spin the CPU when there is no data read from the socket or the terminal. Find a better way
        // to poll on both ends
        if (std.os.windows.ws2_32.WSAPoll(&fds, fds.len, -1) == 0) continue;
        if (fds[0].revents & POLLWRNORM != 0) pipeToTunnel(self.hPipeOut, tunnel);
        if (fds[0].revents & POLLRDNORM == 0) continue;
        const data = try tunnel.readFrame(self.allocator);
        defer self.allocator.free(data);

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
