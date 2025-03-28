const std = @import("std");
const windows = std.os.windows;

pub const HPCON = windows.HANDLE;

const EXTENDED_STARTUPINFO_PRESENT = 0x00080000;

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

pub fn start() !HPCON {
    var conMode: windows.DWORD = undefined;
    const hConsole = try windows.GetStdHandle(windows.STD_OUTPUT_HANDLE);
    if (windows.kernel32.GetConsoleMode(hConsole, &conMode) == 0)
        return error.GetConsoleMode;

    if (windows.kernel32.SetConsoleMode(hConsole, conMode | windows.ENABLE_VIRTUAL_TERMINAL_PROCESSING) == 0)
        return error.SetConsoleMode;

    var hPC: HPCON = undefined;
    var hPtyIn: windows.HANDLE = windows.INVALID_HANDLE_VALUE;
    var hPtyOut: windows.HANDLE = windows.INVALID_HANDLE_VALUE;
    var hPipeIn: windows.HANDLE = windows.INVALID_HANDLE_VALUE;
    var hPipeOut: windows.HANDLE = windows.INVALID_HANDLE_VALUE;

    if (!CreatePipe(&hPtyIn, &hPipeOut, null, 0) or !CreatePipe(&hPipeIn, &hPtyOut, null, 0))
        return error.CreatePipe;

    if (hPtyOut == windows.INVALID_HANDLE_VALUE or hPtyIn == windows.INVALID_HANDLE_VALUE)
        return error.CreatePipe;

    var csbi: windows.CONSOLE_SCREEN_BUFFER_INFO = undefined;
    var conSize: windows.COORD = undefined;

    if (windows.kernel32.GetConsoleScreenBufferInfo(hConsole, &csbi) == 0)
        return error.GetConsoleScreenBufferInfo;

    conSize.X = csbi.srWindow.Right - csbi.srWindow.Left + 1;
    conSize.Y = csbi.srWindow.Bottom - csbi.srWindow.Top + 1;

    if (CreatePseudoConsole(conSize, hPtyIn, hPtyOut, 0, &hPC) != 0)
        return error.CreatePseudoConsole;

    var sInfo = std.mem.zeroInit(STARTUPINFOEX, .{
        .StartupInfo = .{
            .cb = @as(windows.DWORD, @truncate(@sizeOf(STARTUPINFO))),
        },
    });

    var attrListSize: usize = 0;
    _ = InitializeProcThreadAttributeList(null, 1, 0, &attrListSize);
    std.debug.print("attrListSize: {d}\n", .{attrListSize});

    const pAttrList = try std.heap.page_allocator.alloc(u8, attrListSize);
    defer std.heap.page_allocator.free(pAttrList);

    sInfo.lpAttributeList = @ptrCast(pAttrList);
    std.debug.print("sInfo: {}\n", .{sInfo});
    if (!InitializeProcThreadAttributeList(sInfo.lpAttributeList, 1, 0, &attrListSize))
        return error.InitializeProcThreadAttributeList;

    if (!UpdateProcThreadAttribute(sInfo.lpAttributeList, 0, 0x00020016, hPC, @sizeOf(HPCON), null, null))
        return error.UpdateProcThreadAttribute;

    var pInfo: windows.PROCESS_INFORMATION = undefined;
    std.debug.print("Creating process...\n", .{});

    if (!CreateProcessA(null, "C:\\Windows\\System32\\cmd.exe".ptr, null, null, false, EXTENDED_STARTUPINFO_PRESENT, null, null, &sInfo, &pInfo))
        return error.CreateProcessA;

    try windows.WaitForSingleObject(pInfo.hThread, std.math.maxInt(windows.DWORD));

    return hPC;
}
