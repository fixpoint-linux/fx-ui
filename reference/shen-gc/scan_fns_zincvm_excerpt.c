
#include "zincvm.h"

/* ---- GC scanning functions (called by gc.c scavenger) ----
 *
 * gc_scan_value and gc_evacuate are mode-agnostic: they serve both full
 * collect (evacuate to next_space) and nursery scavenge (nursery→old-gen),
 * dispatched by gc_move via in_scavenge.  gc_scan_value evacuates all
 * GC-managed pointers within a Value; gc_evacuate updates a single pointer
 * slot via gc_move. */

/* gc_move is implemented in gc.c */
void *gc_move(void *p);

/* gc_evacuate: update a single pointer slot to point to the evacuated copy */
void gc_evacuate(void **slot) {
    *slot = gc_move(*slot);
}

/* gc_scan_value: evacuate all GC-managed pointers within a Value */
void gc_scan_value(Value *v) {
    switch (v->tag) {
    case VAL_CONS:
        gc_evacuate((void **)&v->cons.car);
        gc_evacuate((void **)&v->cons.cdr);
        break;
    case VAL_LAMBDA:
        gc_evacuate((void **)&v->lambda.code);
        gc_evacuate((void **)&v->lambda.env);
        break;
    case VAL_VECTOR:
        gc_evacuate((void **)&v->vector.data);
        break;
    case VAL_STRING:
        gc_evacuate((void **)&v->str.data);
        break;
    case VAL_ERROR:
        gc_evacuate((void **)&v->error.message);
        break;
    /* These types contain no GC-managed pointers:
     *   VAL_NUMBER, VAL_SYMBOL (sym.name is strdup'd C-heap),
     *   VAL_BOOLEAN, VAL_NIL, VAL_MARK,
     *   VAL_PRIM (prim.name is a literal string),
     *   VAL_STREAM (stream.file is FILE* / intptr_t)
     */
    default:
        break;
    }
}

/* True iff v references any GC object in the nursery.  Must mirror
