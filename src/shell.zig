const std = @import("std");
const builtin = @import("builtin");
const linux = @import("linux.zig");
const windows = @import("windows.zig");

const default_shell = switch (builtin.os.tag) {
    .linux => "/bin/bash",
    .windows => "powershell.exe",
    else => "/bin/sh",
};

const Shell = switch (builtin.os.tag) {
    .windows => windows,
    else => linux,
};

pub fn init(allocator: std.mem.Allocator, shell: ?[]const u8) !Shell {
    return try Shell.init(allocator, shell orelse default_shell);
}
