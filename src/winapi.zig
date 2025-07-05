const std = @import("std");
const windows = std.os.windows;

pub const HPCON = windows.HANDLE;
pub const POLLRDNORM = 0x0100;
pub const POLLWRNORM = 0x0010;
pub const WAIT_IO_COMPLETION = 192;
pub const EXTENDED_STARTUPINFO_PRESENT = 0x00080000;

pub const STARTUPINFO = extern struct {
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

pub const STARTUPINFOEX = extern struct {
    StartupInfo: STARTUPINFO,
    lpAttributeList: ?*anyopaque,
};

pub extern "kernel32" fn CreatePseudoConsole(
    size: windows.COORD,
    hInput: windows.HANDLE,
    hOutput: windows.HANDLE,
    dwFlags: windows.DWORD,
    phPC: *HPCON,
) callconv(.C) windows.HRESULT;

pub extern "kernel32" fn ResizePseudoConsole(
    hPC: HPCON,
    size: windows.COORD,
) callconv(.C) windows.HRESULT;

pub extern "kernel32" fn ClosePseudoConsole(
    hPC: HPCON,
) callconv(.C) void;

pub extern "kernel32" fn CreatePipe(
    hReadPipe: *windows.HANDLE,
    hWritePipe: *windows.HANDLE,
    lpPipeAttributes: ?*anyopaque,
    nSize: windows.DWORD,
) callconv(.C) bool;

pub extern "kernel32" fn InitializeProcThreadAttributeList(
    lpAttributeList: ?*anyopaque,
    dwAttributeCount: windows.DWORD,
    dwFlags: windows.DWORD,
    lpSize: *usize,
) callconv(.C) bool;

pub extern "kernel32" fn UpdateProcThreadAttribute(
    lpAttributeList: ?*anyopaque,
    dwFlags: windows.DWORD,
    Attribute: windows.DWORD,
    lpValue: *anyopaque,
    cbSize: usize,
    lpPreviousValue: ?*anyopaque,
    lpReturnSize: ?*usize,
) callconv(.C) bool;

pub extern "kernel32" fn CreateProcessA(
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

pub extern "kernel32" fn SetStdHandle(
    hId: windows.DWORD,
    hHandle: windows.HANDLE,
) callconv(.C) bool;

pub extern "kernel32" fn CreateFileA(
    lpFileName: [*]const u8,
    dwDesiredAccess: windows.DWORD,
    dwShareMode: windows.DWORD,
    lpSecurityAttributes: ?*anyopaque,
    dwCreationDisposition: windows.DWORD,
    dwFlagsAndAttributes: windows.DWORD,
    hTemplateFile: ?windows.HANDLE,
) callconv(.C) windows.HANDLE;

pub extern "kernel32" fn PeekNamedPipe(
    hNamedPipe: windows.HANDLE,
    lpBuffer: ?*u8,
    nBufferSize: windows.DWORD,
    lpBytesRead: ?*windows.DWORD,
    lpTotalBytesAvail: ?*windows.DWORD,
    lpBytesLeftThisMessage: ?*windows.WORD,
) callconv(.C) bool;

pub extern "kernel32" fn SetConsoleMode(
    hConsoleHandle: std.os.windows.HANDLE,
    dwMode: std.os.windows.DWORD,
) callconv(.winapi) bool;

pub extern "kernel32" fn GetConsoleMode(
    hConsoleHandle: std.os.windows.HANDLE,
    lpMode: *std.os.windows.DWORD,
) callconv(.winapi) bool;

pub const overlap_complete_routine = ?*const fn (
    dwErrorCode: std.os.windows.DWORD,
    dwNumberOfBytesTransfered: std.os.windows.DWORD,
    lpOverlapped: ?*std.os.windows.OVERLAPPED,
) callconv(.C) void;

pub extern "kernel32" fn ReadFileEx(
    hFile: std.os.windows.HANDLE,
    lpBuffer: [*]u8,
    nNumberOfBytesToRead: std.os.windows.DWORD,
    lpOverlapped: ?*std.os.windows.OVERLAPPED,
    lpCompletionRoutine: overlap_complete_routine,
) callconv(.winapi) bool;

pub extern "kernel32" fn SleepEx(ms: std.os.windows.DWORD, ba: bool) callconv(.winapi) std.os.windows.DWORD;

pub extern "kernel32" fn GetOverlappedResult(
    hFile: windows.HANDLE,
    lpOverlapped: *windows.OVERLAPPED,
    lpNumberOfBytesTransferred: *windows.DWORD,
    bWait: bool,
) callconv(.winapi) bool;

pub extern "kernel32" fn CreateNamedPipeA(
    lpName: [*]const u8,
    dwOpenMode: windows.DWORD,
    dwPipeMode: windows.DWORD,
    nMaxInstances: windows.DWORD,
    nOutBufferSize: windows.DWORD,
    nInBufferSize: windows.DWORD,
    nDefaultTimeOut: windows.DWORD,
    lpSecurityAttributes: ?*anyopaque,
) callconv(.winapi) windows.HANDLE;

const pipe_prefix = "\\\\.\\pipe\\";
pub fn getPipeName(name: []u8) !void {
    if (name.len <= pipe_prefix.len) return error.BufferTooSmall;
    std.mem.copyForwards(u8, name, pipe_prefix);
    for (pipe_prefix.len..name.len) |i| {
        name[i] = std.base64.url_safe_alphabet_chars[std.crypto.random.intRangeAtMost(usize, 0, std.base64.url_safe_alphabet_chars.len)];
    }
    name[name.len - 1] = 0;
}

pub fn getOverlappedPipe(hWr: *windows.HANDLE, hRd: *windows.HANDLE) !void {
    var pipe_name: [32]u8 = undefined;
    try getPipeName(&pipe_name);

    hWr.* = CreateNamedPipeA(
        &pipe_name,
        windows.PIPE_ACCESS_DUPLEX | windows.FILE_FLAG_OVERLAPPED,
        0x0, // PIPE_TYPE_BYTE
        2,
        4096,
        4096,
        0,
        null,
    );

    if (hWr.* == windows.INVALID_HANDLE_VALUE) return error.CreateFileWrite;

    hRd.* = CreateFileA(
        &pipe_name,
        windows.GENERIC_READ,
        windows.FILE_SHARE_WRITE | windows.FILE_SHARE_READ,
        null,
        windows.OPEN_EXISTING,
        windows.FILE_FLAG_OVERLAPPED,
        null,
    );

    if (hRd.* == windows.INVALID_HANDLE_VALUE) return error.CreateFileRead;
}
