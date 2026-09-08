//! Damage tracker for the GUI renderer — a faithful pure-Zig port of the
//! rencache damage algorithm from photon (reference:
//! ~/projects/github/photon/src/rencache.c:12-283, whole algorithm; the
//! SDL-specific renderer.c command replay is intentionally NOT ported).
//!
//! Port deltas vs photon (everything else is line-for-line):
//! - DAMAGE UNIT: photon grids 96px screen blocks over a fixed 80x50 board
//!   (rencache.c:9-11); here the unit is ONE TERMINAL CELL and the board is
//!   caller-sized cols x rows, resizable via resize().
//! - HASH WIDTH: photon cells are 32-bit fnv-1a (rencache.c:39-47); here they
//!   are 64-bit fnv-1a so the caller's u64 content hashes keep their entropy
//!   (identical combine mechanics).
//! - COMMAND BUFFER: photon records draw commands (rencache.c:14-101) and
//!   replays them into each dirty rect (rencache.c:232-276); this port is
//!   handed per-cell content hashes directly (touch), so no command buffer
//!   exists and nothing is replayed.
//! - PIXEL EXPANSION of dirty rects (rencache.c:222-230) dropped: cells are
//!   already this port's unit, so there is no cell->pixel scaling step.
//!
//! Pure Zig: no SDL, no vm/gc imports; the allocator is chosen by the caller.

const std = @import("std");

/// A rectangle in terminal cells (the damage unit), half-open:
/// covers cells [x, x+w) x [y, y+h).
pub const CellRect = struct { x: u16, y: u16, w: u16, h: u16 };

/// 64-bit fnv-1a (photon rencache.c:39-47 is the 32-bit variant; same
/// combine mechanics, wider state).
const HASH_INITIAL: u64 = 14695981039346656037;
const FNV_PRIME: u64 = 1099511628211;

/// C: rencache.c:42-47 `hash()` — fnv-1a combine `data` into `h`. The
/// multiply wraps (photon relies on C unsigned wraparound), hence `*%`.
fn hashCombine(h: *u64, data: []const u8) void {
    for (data) |b| {
        h.* = (h.* ^ b) *% FNV_PRIME;
    }
}

pub const Tracker = struct {
    alloc: std.mem.Allocator,
    cols: u16,
    rows: u16,
    /// C: rencache.c:25-28 cells_buf1/cells_buf2 — the double-buffered hash
    /// grid (`cells` = current frame, `cells_prev` = previous frame). u64
    /// cells here vs photon's 32-bit `unsigned`.
    cells: []u64,
    cells_prev: []u64,
    /// C: rencache.c:29 rect_buf — merged dirty rects. Sized to ceil(n/2)
    /// where n = cols*rows: non-mergeable dirty cells form an independent set
    /// of the king graph (merge triggers when |dx| <= 1 and |dy| <= 1), whose
    /// maximum is ceil(cols/2)*ceil(rows/2) <= ceil(n/2), so pushRect's
    /// append (rencache.c:190) cannot overflow.
    rect_buf: []CellRect,

    pub fn init(alloc: std.mem.Allocator, cols: u16, rows: u16) !*Tracker {
        const n = @as(usize, cols) * rows;
        const cells = try alloc.alloc(u64, n);
        errdefer alloc.free(cells);
        const cells_prev = try alloc.alloc(u64, n);
        errdefer alloc.free(cells_prev);
        const rect_buf = try alloc.alloc(CellRect, (n + 1) / 2);
        errdefer alloc.free(rect_buf);
        const self = try alloc.create(Tracker);
        errdefer alloc.destroy(self);
        self.* = .{
            .alloc = alloc,
            .cols = cols,
            .rows = rows,
            .cells = cells,
            .cells_prev = cells_prev,
            .rect_buf = rect_buf,
        };
        @memset(self.cells, HASH_INITIAL);
        // C: rencache.c:153-162 — photon's first frame is a full repaint
        // because begin_frame sees the screen-rect change and memsets
        // cells_prev to 0xff. Establish the same state directly: an all-ones
        // prev differs from every HASH_INITIAL cur cell.
        @memset(self.cells_prev, std.math.maxInt(u64));
        return self;
    }

    pub fn deinit(self: *Tracker) void {
        self.alloc.free(self.rect_buf);
        self.alloc.free(self.cells_prev);
        self.alloc.free(self.cells);
        self.alloc.destroy(self);
    }

    /// Grow/shrink the cell grid. Photon does this check inside begin_frame
    /// (rencache.c:153-162); the port takes cols/rows explicitly. After a
    /// size change the next endFrame is a FULL repaint: prev is all-ones, so
    /// every cell differs (rencache.c:160).
    /// Panics on OOM (the frozen signature cannot propagate an error).
    pub fn resize(self: *Tracker, cols: u16, rows: u16) void {
        if (cols == self.cols and rows == self.rows) return; // C: rencache.c:157
        const n = @as(usize, cols) * rows;
        if (n != self.cells.len) {
            self.cells = self.alloc.realloc(self.cells, n) catch
                @panic("rencache: OOM resizing damage grid");
            self.cells_prev = self.alloc.realloc(self.cells_prev, n) catch
                @panic("rencache: OOM resizing damage grid");
            self.rect_buf = self.alloc.realloc(self.rect_buf, (n + 1) / 2) catch
                @panic("rencache: OOM resizing damage grid");
        }
        self.cols = cols;
        self.rows = rows;
        @memset(self.cells, HASH_INITIAL);
        @memset(self.cells_prev, std.math.maxInt(u64)); // C: rencache.c:160
    }

    /// C: rencache.c:153-162 — photon detects resizes here; the port moves
    /// that reset into resize(), so this is a lifecycle no-op kept for
    /// frame-shape parity (beginFrame -> touch* -> endFrame).
    pub fn beginFrame(self: *Tracker) void {
        _ = self;
    }

    /// Hash `content_hash` into every screen cell overlapped by `rect`
    /// (rect clamped to the grid, empty rects ignored).
    /// C: rencache.c:165-177 update_overlapping_cells — photon derives a
    /// command hash h first (:202-204) and fnv-1a combines its bytes into
    /// each overlapped cell (:174); the port combines the caller's content
    /// hash the same way. The cell range is half-open here because the rect
    /// is already in cell units (photon's pixel rects yield inclusive ranges
    /// after the /CELL_SIZE division, :166-169).
    pub fn touch(self: *Tracker, rect: CellRect, content_hash: u64) void {
        if (rect.w == 0 or rect.h == 0) return; // C: rencache.c:201
        var h: u64 = HASH_INITIAL;
        hashCombine(&h, std.mem.asBytes(&content_hash));
        // Clamp to the board: the analogue of photon intersecting every
        // command with the screen/clip rect (rencache.c:117, :200).
        const x1: u32 = @min(@as(u32, rect.x), self.cols);
        const y1: u32 = @min(@as(u32, rect.y), self.rows);
        const x2: u32 = @min(@as(u32, rect.x) + rect.w, self.cols);
        const y2: u32 = @min(@as(u32, rect.y) + rect.h, self.rows);
        var y = y1;
        while (y < y2) : (y += 1) {
            var x = x1;
            while (x < x2) : (x += 1) {
                const idx = self.cellIdx(@intCast(x), @intCast(y));
                hashCombine(&self.cells[idx], std.mem.asBytes(&h)); // C: :174
            }
        }
    }

    /// Diff cur vs prev cell hashes, merge the dirty cells into rects, report
    /// them, then swap the double buffers and leave `cells` reset for the next
    /// frame. `out_dirty` is the caller-owned unmanaged list (cleared here).
    /// Panics on OOM growing `out_dirty` (frozen void signature).
    /// C: rencache.c:194-283 (minus the SDL command replay :232-276 and the
    /// pixel expansion :222-230).
    pub fn endFrame(self: *Tracker, out_dirty: *std.ArrayList(CellRect)) void {
        // Push rects for all cells changed since last frame, reset cells
        // (C: rencache.c:207-220 — the reset buffer becomes `cells` again
        // after the :278-281 swap).
        var rect_count: usize = 0;
        var y: u16 = 0;
        while (y < self.rows) : (y += 1) {
            var x: u16 = 0;
            while (x < self.cols) : (x += 1) {
                const idx = self.cellIdx(x, y);
                if (self.cells[idx] != self.cells_prev[idx]) {
                    self.pushRect(.{ .x = x, .y = y, .w = 1, .h = 1 }, &rect_count); // C: :216
                }
                self.cells_prev[idx] = HASH_INITIAL; // C: :218
            }
        }

        // C: rencache.c:222-230 pixel expansion dropped (cells are the unit);
        // :232-276 command replay/present dropped (SDL renderer's job).
        out_dirty.clearRetainingCapacity();
        out_dirty.appendSlice(self.alloc, self.rect_buf[0..rect_count]) catch
            @panic("rencache: OOM reporting dirty rects");

        // Swap cell buffer (C: rencache.c:278-281); the incoming `cells` is
        // already fully reset to HASH_INITIAL by the :218 writes above, which
        // is what photon's :282 command-buffer reset achieves for its buffer.
        const tmp = self.cells;
        self.cells = self.cells_prev;
        self.cells_prev = tmp;
    }

    /// Debug aid: ASCII map of the current dirty diff ('#' dirty, '.' clean).
    /// Read-only (no reset, no swap). Contract: renderer/rencache.zig
    /// (optional debugVisual). Writer errors are swallowed.
    pub fn debugVisual(self: *Tracker, writer: anytype) void {
        var y: u16 = 0;
        while (y < self.rows) : (y += 1) {
            var x: u16 = 0;
            while (x < self.cols) : (x += 1) {
                const idx = self.cellIdx(x, y);
                const dirty = self.cells[idx] != self.cells_prev[idx];
                writer.writeAll(if (dirty) "#" else ".") catch {};
            }
            writer.writeAll("\n") catch {};
        }
    }

    /// C: rencache.c:50-52 cell_idx.
    fn cellIdx(self: *const Tracker, x: u16, y: u16) usize {
        return @as(usize, x) + @as(usize, y) * self.cols;
    }

    /// Merge `r` into the first overlapping buffered rect (scanning backwards),
    /// else append. C: rencache.c:180-192 push_rect. Single backwards pass, no
    /// re-merge cascade — faithful to photon (a merged rect may still overlap
    /// earlier rects; a superset damage rect is harmless).
    fn pushRect(self: *Tracker, r: CellRect, count: *usize) void {
        var i = count.*;
        while (i > 0) {
            i -= 1;
            const rp = &self.rect_buf[i];
            if (rectsOverlap(rp.*, r)) { // C: :184
                rp.* = mergeRects(rp.*, r); // C: :185
                return;
            }
        }
        self.rect_buf[count.*] = r; // C: :190
        count.* += 1;
    }

    /// C: rencache.c:55-58 rects_overlap — note `>=`: edge-ADJACENT rects
    /// overlap, which is what merges neighboring dirty cells. u32 math so
    /// x+w cannot overflow u16 in safe builds.
    fn rectsOverlap(a: CellRect, b: CellRect) bool {
        return @as(u32, b.x) + b.w >= a.x and b.x <= @as(u32, a.x) + a.w and
            @as(u32, b.y) + b.h >= a.y and b.y <= @as(u32, a.y) + a.h;
    }

    /// C: rencache.c:70-76 merge_rects (u32 intermediates, no overflow).
    fn mergeRects(a: CellRect, b: CellRect) CellRect {
        const x1: u32 = @min(a.x, b.x);
        const y1: u32 = @min(a.y, b.y);
        const x2: u32 = @max(@as(u32, a.x) + a.w, @as(u32, b.x) + b.w);
        const y2: u32 = @max(@as(u32, a.y) + a.h, @as(u32, b.y) + b.h);
        return .{
            .x = @intCast(x1),
            .y = @intCast(y1),
            .w = @intCast(x2 - x1),
            .h = @intCast(y2 - y1),
        };
    }
};
