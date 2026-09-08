//! Headless unit tests for the terminal-cell damage tracker
//! (src/renderer/rencache.zig), per the frozen contract:
//! (a) adjacent/overlapping dirty cells merge into ONE rect
//! (b) disjoint dirty cells stay separate rects
//! (c) resize resets prev (full repaint next frame)
//! (d) unchanged frame yields ZERO dirty
//! (e) a hash change in one region dirties only that region
//!
//! Photon reference: ~/projects/github/photon/src/rencache.c:12-283.

const std = @import("std");
const rencache = @import("rencache.zig");

const CellRect = rencache.CellRect;
const Tracker = rencache.Tracker;
const testing = std.testing;

fn expectRectsEqual(actual: []const CellRect, expected: []const CellRect) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (actual, expected) |a, e| {
        try testing.expectEqual(e, a);
    }
}

// (a) adjacent dirty cells merge into ONE rect.
// Also proves the first endFrame is a full repaint (photon's resize-reset
// state at init, rencache.c:153-162).
test "adjacent dirty cells merge into one rect" {
    const t = try Tracker.init(testing.allocator, 20, 10);
    defer t.deinit();
    var dirty: std.ArrayList(CellRect) = .empty;
    defer dirty.deinit(testing.allocator);

    // First frame: prev is all-ones -> every cell dirty -> the whole 20x10
    // grid merges into a single rect (row-major merge, rencache.c:180-192).
    t.endFrame(&dirty);
    try expectRectsEqual(dirty.items, &.{.{ .x = 0, .y = 0, .w = 20, .h = 10 }});

    // Steady frame: two horizontally adjacent + one vertically adjacent cell.
    t.beginFrame();
    t.touch(.{ .x = 2, .y = 3, .w = 1, .h = 1 }, 0xA);
    t.touch(.{ .x = 3, .y = 3, .w = 1, .h = 1 }, 0xB);
    t.touch(.{ .x = 2, .y = 4, .w = 1, .h = 1 }, 0xC);
    t.endFrame(&dirty);
    try expectRectsEqual(dirty.items, &.{.{ .x = 2, .y = 3, .w = 2, .h = 2 }});
}

// (b) disjoint dirty cells stay separate rects.
test "disjoint dirty cells stay separate rects" {
    const t = try Tracker.init(testing.allocator, 20, 10);
    defer t.deinit();
    var dirty: std.ArrayList(CellRect) = .empty;
    defer dirty.deinit(testing.allocator);
    t.endFrame(&dirty); // baseline full repaint

    t.beginFrame();
    t.touch(.{ .x = 1, .y = 1, .w = 1, .h = 1 }, 0x11);
    t.touch(.{ .x = 10, .y = 5, .w = 2, .h = 2 }, 0x22);
    t.endFrame(&dirty);
    // Scan is row-major (rencache.c:211-212), so (1,1) is pushed first.
    try expectRectsEqual(dirty.items, &.{
        .{ .x = 1, .y = 1, .w = 1, .h = 1 },
        .{ .x = 10, .y = 5, .w = 2, .h = 2 },
    });
}

// (c) resize resets prev -> full repaint on the next frame.
test "resize forces a full repaint next frame" {
    const t = try Tracker.init(testing.allocator, 20, 10);
    defer t.deinit();
    var dirty: std.ArrayList(CellRect) = .empty;
    defer dirty.deinit(testing.allocator);
    t.endFrame(&dirty); // baseline full repaint

    // Grow: untouched grid still repaints fully (photon rencache.c:160).
    t.resize(30, 8);
    t.endFrame(&dirty);
    try expectRectsEqual(dirty.items, &.{.{ .x = 0, .y = 0, .w = 30, .h = 8 }});

    // Shrink likewise.
    t.resize(10, 5);
    t.endFrame(&dirty);
    try expectRectsEqual(dirty.items, &.{.{ .x = 0, .y = 0, .w = 10, .h = 5 }});

    // Same-size resize is a no-op guard (photon :157): nothing dirty after.
    t.resize(10, 5);
    t.endFrame(&dirty);
    try testing.expectEqual(@as(usize, 0), dirty.items.len);
}

// (d) unchanged frame yields zero dirty.
test "unchanged frame yields zero dirty" {
    const t = try Tracker.init(testing.allocator, 20, 10);
    defer t.deinit();
    var dirty: std.ArrayList(CellRect) = .empty;
    defer dirty.deinit(testing.allocator);
    t.endFrame(&dirty); // baseline

    t.beginFrame();
    t.touch(.{ .x = 0, .y = 0, .w = 20, .h = 10 }, 0xFEED);
    t.touch(.{ .x = 5, .y = 2, .w = 4, .h = 3 }, 0xBEEF);
    t.endFrame(&dirty);
    try testing.expect(dirty.items.len > 0);

    // Same content again: hashes match, nothing is reported.
    t.beginFrame();
    t.touch(.{ .x = 0, .y = 0, .w = 20, .h = 10 }, 0xFEED);
    t.touch(.{ .x = 5, .y = 2, .w = 4, .h = 3 }, 0xBEEF);
    t.endFrame(&dirty);
    try testing.expectEqual(@as(usize, 0), dirty.items.len);
}

// (e) a hash change in one region dirties only that region.
test "hash change in one region dirties only that region" {
    const t = try Tracker.init(testing.allocator, 40, 20);
    defer t.deinit();
    var dirty: std.ArrayList(CellRect) = .empty;
    defer dirty.deinit(testing.allocator);

    // Baseline frame already carries the background hash, so the background
    // is genuinely unchanged in the frames below.
    t.beginFrame();
    t.touch(.{ .x = 0, .y = 0, .w = 40, .h = 20 }, 0xAAAA);
    t.endFrame(&dirty); // full repaint (first frame)

    // Same background + a changed region: ONLY that region is dirty.
    t.beginFrame();
    t.touch(.{ .x = 0, .y = 0, .w = 40, .h = 20 }, 0xAAAA);
    t.touch(.{ .x = 30, .y = 10, .w = 5, .h = 4 }, 0xBBBB);
    t.endFrame(&dirty);
    try expectRectsEqual(dirty.items, &.{.{ .x = 30, .y = 10, .w = 5, .h = 4 }});

    // Moving the change elsewhere dirties both the new region and the old
    // one (its content is gone), not the untouched background.
    t.beginFrame();
    t.touch(.{ .x = 0, .y = 0, .w = 40, .h = 20 }, 0xAAAA);
    t.touch(.{ .x = 2, .y = 2, .w = 3, .h = 3 }, 0xCCCC);
    t.endFrame(&dirty);
    try expectRectsEqual(dirty.items, &.{
        .{ .x = 2, .y = 2, .w = 3, .h = 3 },
        .{ .x = 30, .y = 10, .w = 5, .h = 4 },
    });
}

// Out-of-bounds / empty touches are clamped or ignored (photon's screen-rect
// intersect, rencache.c:117/:200): they must not corrupt the grid or report
// phantom damage.
test "out-of-bounds and empty touches are safe" {
    const t = try Tracker.init(testing.allocator, 10, 6);
    defer t.deinit();
    var dirty: std.ArrayList(CellRect) = .empty;
    defer dirty.deinit(testing.allocator);
    t.endFrame(&dirty); // baseline

    t.beginFrame();
    t.touch(.{ .x = 0, .y = 0, .w = 0, .h = 5 }, 0x1); // empty w
    t.touch(.{ .x = 0, .y = 0, .w = 5, .h = 0 }, 0x2); // empty h
    t.touch(.{ .x = 50, .y = 50, .w = 4, .h = 4 }, 0x3); // fully outside
    t.touch(.{ .x = 8, .y = 4, .w = 100, .h = 100 }, 0x4); // partially outside
    t.endFrame(&dirty);
    try expectRectsEqual(dirty.items, &.{.{ .x = 8, .y = 4, .w = 2, .h = 2 }});
}

// debugVisual renders one row of '#' per dirty cell pair-diff without
// mutating tracker state (no reset, no swap).
test "debugVisual shows dirty cells and does not mutate" {
    const t = try Tracker.init(testing.allocator, 4, 2);
    defer t.deinit();
    var dirty: std.ArrayList(CellRect) = .empty;
    defer dirty.deinit(testing.allocator);
    t.endFrame(&dirty);

    t.touch(.{ .x = 1, .y = 0, .w = 1, .h = 1 }, 0x5);
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    t.debugVisual(&w);
    try testing.expectEqualStrings(".#..\n....\n", w.buffered());
}
