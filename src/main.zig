const std = @import("std");
const gc = @import("gc");
const types = gc.types;

/// Mirror of C: zincvm.c val_cons — allocates a heap `car` cell and a heap
/// `cdr` cell (both GC_TYPE_VALUE) and returns a cons Value whose car/cdr
/// point at them.  Roots car, cdr, and car_cell across the two allocs so the
/// build is safe even if a natural preemptive/reactive scavenge fires mid-way.
fn valCons(g: *gc.Gc, car: types.Value, cdr: types.Value) types.Value {
    var car_copy = car;
    var cdr_copy = cdr;
    g.rootPushValue(&car_copy);
    g.rootPushValue(&cdr_copy);
    const car_cell = g.alloc(types.Value);
    var car_root: ?*types.Value = car_cell;
    g.rootPushPtr(@ptrCast(&car_root));
    const cdr_cell = g.alloc(types.Value);
    car_root.?.* = car;
    cdr_cell.* = cdr;
    g.rootPop(); // car_root
    g.rootPop(); // cdr
    g.rootPop(); // car
    return .{ .tag = .cons, .payload = .{ .cons = .{ .car = car_root, .cdr = cdr_cell } } };
}

/// Walk a ROOT_VALUE-rooted cons list, printing each node's car.
fn printList(root: *const types.Value) usize {
    var count: usize = 0;
    var cur = root.*;
    while (cur.tag == types.ValTag.cons) {
        const car = cur.payload.cons.car orelse break;
        count += 1;
        std.debug.print("    node {d}: {d}\n", .{ count, car.payload.number });
        const cdr = cur.payload.cons.cdr orelse break;
        cur = cdr.*;
    }
    return count;
}

pub fn main() !void {
    // Reasonable reserve: the C minimum heap (16 MB, MIN_HEAP_PAGES) with an
    // explicit 64 MB VAS reservation so grow_heap has headroom without the
    // 4 GB C-default overcommit.  verbose prints the [GC ...] banners.
    var g = try gc.Gc.init(.{
        .heap_bytes = 16 * 1024 * 1024,
        .reserve_bytes = 64 * 1024 * 1024,
        .verbose = true,
    });
    defer g.deinit();

    // Build a small cons graph — the list (1 2 3) — whose head is held ONLY
    // by a ROOT_VALUE precise root.  The build stays below the nursery
    // low-water, so nothing moves until we force a collection below.
    var root: types.Value = .{ .tag = .nil, .payload = .{ .number = 0 } };
    g.rootPushValue(&root);
    var i: i64 = 3;
    while (i >= 1) : (i -= 1) {
        const num: types.Value = .{ .tag = .number, .payload = .{ .number = i } };
        root = valCons(&g, num, root);
    }
    std.debug.print("Shen GC demo: built (1 2 3), rooting head via ROOT_VALUE.\n", .{});

    // Force a nursery scavenge, then a full collect (semi-space swap).  The
    // tree must survive both — the precise root is its only survival path.
    g.collectNursery(.@"test");
    g.collect(.@"test");

    std.debug.print("After scavenge + full collect:\n", .{});
    const s = g.stats();
    std.debug.print("  nursery scavenges={d} preemptive={d} reactive={d} full collects={d}\n", .{
        s.nursery_scavenge_count,
        s.preemptive_scavenge_count,
        s.reactive_scavenge_count,
        s.full_collect_count,
    });
    std.debug.print("  allocated pages={d} nursery_is_empty={} nursery_no_other_space={}\n", .{
        s.allocated_pages,
        s.nursery_is_empty,
        s.nursery_no_other_space,
    });
    std.debug.print("  alloc classes: raw={d} value={d} value_array={d} instr_array={d} callframe_array={d}\n", .{
        s.alloc_class_count[0],
        s.alloc_class_count[1],
        s.alloc_class_count[2],
        s.alloc_class_count[3],
        s.alloc_class_count[4],
    });

    // The list survived collection: walk it to prove the ROOT_VALUE root kept
    // the whole graph reachable across the scavenge and the full collect.
    const count = printList(&root);
    std.debug.print("  list intact after collection: {d} nodes.\n", .{count});
    if (count != 3) {
        std.debug.panic("Shen GC demo: list corrupted after collection (got {d} nodes)\n", .{count});
    }

    g.rootPopTo(0);
}
