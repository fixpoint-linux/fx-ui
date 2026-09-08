//! Default-build GUI backend (photon-gui P2 item 13): the no-SDL stand-in
//! selected by build.zig when -Dgui is OFF.  Same pub API as gui_sdl.zig;
//! every call is a fail-soft no-op, so the effectloop GUI leaves behave
//! exactly like their P1 stubs (guiOpen completes unit, guiPoll completes
//! unit — Tea.guiProgram's GUI branch treats that as GIgnore and the program
//! drains to exit) and neither `zig build test` nor the elm gate needs SDL.

const std = @import("std");
const gui = @import("gui_model");

pub fn open(alloc: std.mem.Allocator, title: []const u8, cols: u16, rows: u16) bool {
    _ = alloc;
    _ = title;
    _ = cols;
    _ = rows;
    return false;
}

pub fn opened() bool {
    return false;
}

pub fn eventFd() i32 {
    return -1;
}

pub fn present(frame: []const []const gui.Span) void {
    _ = frame;
}

pub fn cellDims() struct { w: i32, h: i32 } {
    return .{ .w = 0, .h = 0 };
}

pub fn gridSize() struct { cols: u16, rows: u16 } {
    return .{ .cols = 0, .rows = 0 };
}

pub fn invalidate() void {}

pub fn close() void {}
