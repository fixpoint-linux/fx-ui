const std = @import("std");

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) void {
    // Standard target options allow the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    // Optimization options: like standardOptimizeOption but defaulting to
    // ReleaseFast — the interpreted VM is unusably slow in Debug (~10-25x),
    // and `zig build` must produce a playable TUI out of the box.
    // `-Doptimize=Debug|ReleaseSafe|...` and `--release[=fast|safe|small]`
    // still select an explicit mode.
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or binary size",
    ) orelse switch (b.release_mode) {
        .off, .any, .fast => std.builtin.OptimizeMode.ReleaseFast,
        .safe => .ReleaseSafe,
        .small => .ReleaseSmall,
    };
    // It's also possible to define more custom flags to toggle optional features
    // of this build script using `b.option()`. All defined flags (including
    // target and optimize options) will be listed when running `zig build --help`
    // in this directory.

    // ---- zinc-vm package dependency (VM extraction P2) ----
    // The collector and the ZINC VM are owned by the ../zinc-vm package (the
    // single shared executor); fx-ui no longer compiles its own src/gc* +
    // src/vm* copies.  The package exports both modules by name ("gc", "vm"),
    // so every consumer keeps its `@import("gc")` / `@import("vm")` calls
    // UNCHANGED.  This top-level instance carries the command-line optimize;
    // the per-mode gate below builds its own dependency instances.
    const zinc = b.dependency("zinc_vm", .{ .target = target, .optimize = optimize });
    const gc_mod = zinc.module("gc");
    const vm_mod = zinc.module("vm");

    // This creates a module, which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Zig modules are the preferred way of making Zig code available to consumers.
    // addModule defines a module that we intend to make available for importing
    // to our consumers. We must give it a name because a Zig package can expose
    // multiple modules and consumers will need to be able to specify which
    // module they want to access.
    const mod = b.addModule("fx_ui", .{
        // The root source file is the "entry point" of this module. Users of
        // this module will only be able to access public declarations contained
        // in this file, which means that if you have declarations that you
        // intend to expose to consumers that were defined in other files part
        // of this module, you will have to make sure to re-export them from
        // the root file.
        .root_source_file = b.path("src/root.zig"),
        // Later on we'll use this module as the root module of a test executable
        // which requires us to specify a target.
        .target = target,
    });

    // Here we define an executable. An executable needs to have a root module
    // which needs to expose a `main` function. While we could add a main function
    // to the module defined above, it's sometimes preferable to split business
    // logic and the CLI into two separate modules.
    //
    // If your goal is to create a Zig library for others to use, consider if
    // it might benefit from also exposing a CLI tool. A parser library for a
    // data serialization format could also bundle a CLI syntax checker, for example.
    //
    // If instead your goal is to create an executable, consider if users might
    // be interested in also being able to embed the core functionality of your
    // program in their own executable in order to avoid the overhead involved in
    // subprocessing your CLI tool.
    //
    // If neither case applies to you, feel free to delete the declaration you
    // don't need and to put everything under a single module.
    const exe = b.addExecutable(.{
        .name = "fx_ui",
        .root_module = b.createModule(.{
            // b.createModule defines a new module just like b.addModule but,
            // unlike b.addModule, it does not expose the module to consumers of
            // this package, which is why in this case we don't have to give it a name.
            .root_source_file = b.path("src/main.zig"),
            // Target and optimization levels must be explicitly wired in when
            // defining an executable or library (in the root module), and you
            // can also hardcode a specific target for an executable or library
            // definition if desireable (e.g. firmware for embedded devices).
            .target = target,
            .optimize = optimize,
            // List of modules available for import in source files part of the
            // root module.
            .imports = &.{
                // Here "fx_ui" is the name you will use in your source code to
                // import this module (e.g. `@import("fx_ui")`). The name is
                // repeated because you are allowed to rename your imports, which
                // can be extremely useful in case of collisions (which can happen
                // importing modules from different packages).
                .{ .name = "fx_ui", .module = mod },
                .{ .name = "gc", .module = gc_mod },
            },
        }),
    });

    // This declares intent for the executable to be installed into the
    // install prefix when running `zig build` (i.e. when executing the default
    // step). By default the install prefix is `zig-out/` but can be overridden
    // by passing `--prefix` or `-p`.
    b.installArtifact(exe);

    // ---- consumer-side M9 effect loop (src/effectloop.zig) ----
    // The HOST-SIDE effect-manager event loop is fx-ui-ONLY — it is NOT part
    // of the zinc-vm package — so it lives here as a local module over the
    // package's vm (state/values/interp/prims/execplan/hostcall).
    const effectloop_mod = b.createModule(.{
        .root_source_file = b.path("src/effectloop.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "gc", .module = gc_mod },
            .{ .name = "vm", .module = vm_mod },
        },
    });

    // ---- `elmvm`: the M0 gate harness (tools/elmvm.zig) ----
    // A CLI wrapper that loads a csexp bundle and runs one function, proving
    // the ZINC VM parser/interp end-to-end before any Elm codegen exists.
    const elmvm_mod = b.createModule(.{
        .root_source_file = b.path("tools/elmvm.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "gc", .module = gc_mod },
            .{ .name = "vm", .module = vm_mod },
            .{ .name = "effectloop", .module = effectloop_mod },
        },
    });
    const elmvm = b.addExecutable(.{
        .name = "elmvm",
        .root_module = elmvm_mod,
    });
    const elmvm_install = b.addInstallArtifact(elmvm, .{});
    const elmvm_step = b.step("elmvm", "Build the elmvm gate harness");
    elmvm_step.dependOn(&elmvm_install.step);

    // ---- `vmbench`: the VM throughput benchmark harness (tools/vmbench.zig) ----
    const vmbench_mod = b.createModule(.{
        .root_source_file = b.path("tools/vmbench.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "gc", .module = gc_mod },
            .{ .name = "vm", .module = vm_mod },
        },
    });
    const vmbench = b.addExecutable(.{
        .name = "vmbench",
        .root_module = vmbench_mod,
    });
    const vmbench_install = b.addInstallArtifact(vmbench, .{});
    const vmbench_step = b.step("vmbench", "Build the vmbench throughput harness");
    vmbench_step.dependOn(&vmbench_install.step);

    // ---- `ptytest`: the PTY expect-runner for terminal fixtures (M1 tea) ----
    // A libc-linked exe with NO vm imports — pure POSIX (open ptmx/fork/ioctl/
    // poll).  Drives elmvm inside a pseudo-terminal and asserts on the output.
    const ptytest_mod = b.createModule(.{
        .root_source_file = b.path("tools/ptytest.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const ptytest = b.addExecutable(.{
        .name = "ptytest",
        .root_module = ptytest_mod,
    });
    const ptytest_install = b.addInstallArtifact(ptytest, .{});
    const ptytest_step = b.step("ptytest", "Build the ptytest terminal harness");
    ptytest_step.dependOn(&ptytest_install.step);

    // ---- `aotrt`: the handwritten AOT runtime (tools/aot/runtime.zig) ----
    // Shared by every generated module and the aotbench driver.  Imports gc +
    // vm; the generated Zig calls back into it for tail dispatch, env builds,
    // and the code-array -> native-fn registry.
    const aotrt_mod = b.createModule(.{
        .root_source_file = b.path("tools/aot/runtime.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "gc", .module = gc_mod },
            .{ .name = "vm", .module = vm_mod },
        },
    });

    // ---- `aotdump`: the AOT emitter (links gc+vm, real parseBundle) ----
    // Also imports aotrt: the dumper checks the emitted unit count against
    // runtime.zig's REG_MAX (the registry arrays the generated aotInit fills).
    const aotdump_mod = b.createModule(.{
        .root_source_file = b.path("tools/aot/dump.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "gc", .module = gc_mod },
            .{ .name = "vm", .module = vm_mod },
            .{ .name = "runtime.zig", .module = aotrt_mod },
        },
    });
    const aotdump = b.addExecutable(.{
        .name = "aotdump",
        .root_module = aotdump_mod,
    });
    const aotdump_install = b.addInstallArtifact(aotdump, .{});
    const aotdump_step = b.step("aotdump", "Build the AOT emitter (aotdump)");
    aotdump_step.dependOn(&aotdump_install.step);

    // ---- `aot`: the AOT-to-Zig spike (fib / countdown / biglist / todos) ----
    // Each spike exe compiles the fixture with node run.js -> aotdump -> a
    // generated Zig module, then links it against aotrt + gc + vm.  SEPARATE
    // from gate/test: the interpreter stays the source of truth.
    const aot_step = b.step("aot", "Build the AOT spike exes (fib/countdown/biglist/todos)");
    aot_step.dependOn(&aotdump_install.step);
    inline for (.{
        .{ .name = "aotbench-fib", .fixture = "tests/elm-fixtures/fib.elm", .entry = "Fib.fib" },
        .{ .name = "aotbench-countdown", .fixture = "tests/elm-fixtures/countdown.elm", .entry = "Countdown.countdown" },
        .{ .name = "aotbench-biglist", .fixture = "tests/elm-fixtures/biglist.elm", .entry = "BigList.main" },
    }) |sp| {
        aot_step.dependOn(addAotSpike(b, target, optimize, gc_mod, vm_mod, aotrt_mod, aotdump, sp.name, sp.fixture, sp.entry));
    }
    // Phase 4 headline: the full todos TUI end-to-end (Tea v2 + ListBox +
    // TextInput + Help + Lipgloss + TaskReadFile/WriteFile).  Compiles the SAME
    // source set as the gate's pty_app todos row (TodoApp.elm + the todos.elm
    // re-export fixture) so the bundle and entry (Todos.main) are identical to
    // what elmvm drives under the pty.
    aot_step.dependOn(addAotTodosSpike(b, target, optimize, gc_mod, vm_mod, aotrt_mod, effectloop_mod, aotdump));

    // This creates a top level step. Top level steps have a name and can be
    // invoked by name when running `zig build` (e.g. `zig build run`).
    // This will evaluate the `run` step rather than the default step.
    // For a top level step to actually do something, it must depend on other
    // steps (e.g. a Run step, as we will see in a moment).
    const run_step = b.step("run", "Run the app");

    // This creates a RunArtifact step in the build graph. A RunArtifact step
    // invokes an executable compiled by Zig. Steps will only be executed by the
    // runner if invoked directly by the user (in the case of top level steps)
    // or if another step depends on it, so it's up to you to define when and
    // how this Run step will be executed. In our case we want to run it when
    // the user runs `zig build run`, so we create a dependency link.
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    // By making the run step depend on the default step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Creates an executable that will run `test` blocks from the provided module.
    // Here `mod` needs to define a target, which is why earlier we made sure to
    // set the releative field.
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    // A run step that will run the test executable.
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // Creates an executable that will run `test` blocks from the executable's
    // root module. Note that test executables only test one module at a time,
    // hence why we have to create two separate ones.
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    // A run step that will run the second test executable.
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // ---- Shen GC test step + permanent multi-mode gate (units A-C) ----
    // The gc/vm TEST SUITES are owned by the zinc-vm package (fx-ui's local
    // copies were removed in extraction P2); these steps drive the package's
    // test files through a consumer-side per-mode dependency instance.
    const gc_test_step = b.step("gc-test", "Run Shen GC tests (honours -Doptimize)");
    gc_test_step.dependOn(addGcTestSet(b, target, optimize));
    test_step.dependOn(gc_test_step);

    // ---- Shen VM test step (plan M0): same shape as gc-test. ----
    const vm_test_step = b.step("vm-test", "Run Shen VM tests (honours -Doptimize)");
    vm_test_step.dependOn(addVmTestSet(b, target, optimize));
    test_step.dependOn(vm_test_step);

    // ---- `gate`: the permanent ReleaseSafe build gate (unit C) ----
    // Runs the full Shen GC + VM suites in Debug + ReleaseSafe + ReleaseFast in
    // one command.  ReleaseSafe keeps std.debug.assert live, so every
    // safety-enforcement added in the GC units B/E is proven under the gate,
    // not just in Debug.
    const gate_step = b.step("gate", "Run Shen GC + VM tests in Debug + ReleaseSafe + ReleaseFast");
    gate_step.dependOn(addGcTestSet(b, target, .Debug));
    gate_step.dependOn(addGcTestSet(b, target, .ReleaseSafe));
    gate_step.dependOn(addGcTestSet(b, target, .ReleaseFast));
    gate_step.dependOn(addVmTestSet(b, target, .Debug));
    gate_step.dependOn(addVmTestSet(b, target, .ReleaseSafe));
    gate_step.dependOn(addVmTestSet(b, target, .ReleaseFast));

    // Just like flags, top level steps are also listed in the `--help` menu.
    //
    // The Zig build system is entirely implemented in userland, which means
    // that it cannot hook into private compiler APIs. All compilation work
    // orchestrated by the build system will result in other Zig compiler
    // subcommands being invoked with the right flags defined. You can observe
    // these invocations when one fails (or you pass a flag to increase
    // verbosity) to validate assumptions and diagnose problems.
    //
    // Lastly, the Zig build system is relatively simple and self-contained,
    // and reading its source code will allow you to master it.
}

/// Build one AOT spike executable: node run.js compiles the fixture to a csexp
/// bundle, aotdump emits a generated Zig module from it, and the exe (aotbench
/// driver, tools/aot/main.zig) links that module against aotrt + gc + vm.
/// Returns the install step for the spike exe.
fn addAotSpike(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    gc_mod: *std.Build.Module,
    vm_mod: *std.Build.Module,
    aotrt_mod: *std.Build.Module,
    aotdump: *std.Build.Step.Compile,
    name: []const u8,
    fixture: []const u8,
    entry: []const u8,
) *std.Build.Step {
    // 1. Elm fixture -> csexp bundle (node run.js, the gate's own compiler).
    const node_cmd = b.addSystemCommand(&.{"node"});
    node_cmd.addArg("elm-compiler/run.js");
    node_cmd.addFileArg(b.path(fixture));
    const bundle_lp = node_cmd.addOutputFileArg(b.fmt("{s}.csexp", .{name}));

    // 2. csexp bundle -> generated Zig (aotdump, the REAL parser).
    const dump_cmd = b.addRunArtifact(aotdump);
    dump_cmd.addFileArg(bundle_lp);
    dump_cmd.addArg(entry);
    dump_cmd.addArg("-o");
    const gen_lp = dump_cmd.addOutputFileArg("gen.zig");

    // 3. The generated module (imports gc/vm/runtime.zig).
    const aot_gen_mod = b.createModule(.{
        .root_source_file = gen_lp,
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "gc", .module = gc_mod },
            .{ .name = "vm", .module = vm_mod },
            .{ .name = "runtime.zig", .module = aotrt_mod },
        },
    });

    // 4. The aotbench driver exe (tools/aot/main.zig).
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("tools/aot/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "gc", .module = gc_mod },
            .{ .name = "vm", .module = vm_mod },
            .{ .name = "runtime.zig", .module = aotrt_mod },
            .{ .name = "aot_gen", .module = aot_gen_mod },
        },
    });
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = exe_mod,
    });
    const install = b.addInstallArtifact(exe, .{});
    return &install.step;
}

/// Build the AOT'd todos TUI exe (aotbench-todos, Phase 4).  Same shape as
/// addAotSpike but compiles TWO sources (the gate's exact pty_app todos set:
/// examples/todos/TodoApp.elm + tests/elm-fixtures/todos.elm, which re-exports
/// TodoApp.main as Todos.main) and links the elmvm-shaped todos driver
/// (tools/aot/todos.zig) against gc + vm + aotrt + effectloop instead of the
/// pure-bench aotbench driver.  The driver runs the baked entry, installs the
/// applyHost hook, and drives the host effect loop under a pty (drop-in for
/// elmvm in the pty gate).
fn addAotTodosSpike(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    gc_mod: *std.Build.Module,
    vm_mod: *std.Build.Module,
    aotrt_mod: *std.Build.Module,
    effectloop_mod: *std.Build.Module,
    aotdump: *std.Build.Step.Compile,
) *std.Build.Step {
    const name = "aotbench-todos";

    // 1. Elm sources -> csexp bundle (node run.js, the gate's own compiler).
    const node_cmd = b.addSystemCommand(&.{"node"});
    node_cmd.addArg("elm-compiler/run.js");
    node_cmd.addFileArg(b.path("examples/todos/TodoApp.elm"));
    node_cmd.addFileArg(b.path("tests/elm-fixtures/todos.elm"));
    const bundle_lp = node_cmd.addOutputFileArg(b.fmt("{s}.csexp", .{name}));

    // 2. csexp bundle -> generated Zig (aotdump, the REAL parser).
    const dump_cmd = b.addRunArtifact(aotdump);
    dump_cmd.addFileArg(bundle_lp);
    dump_cmd.addArg("Todos.main");
    dump_cmd.addArg("-o");
    const gen_lp = dump_cmd.addOutputFileArg("gen.zig");

    // 3. The generated module (imports gc/vm/runtime.zig).
    const aot_gen_mod = b.createModule(.{
        .root_source_file = gen_lp,
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "gc", .module = gc_mod },
            .{ .name = "vm", .module = vm_mod },
            .{ .name = "runtime.zig", .module = aotrt_mod },
        },
    });

    // 4. The elmvm-shaped todos driver exe (tools/aot/todos.zig).
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("tools/aot/todos.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "gc", .module = gc_mod },
            .{ .name = "vm", .module = vm_mod },
            .{ .name = "runtime.zig", .module = aotrt_mod },
            .{ .name = "aot_gen", .module = aot_gen_mod },
            .{ .name = "effectloop", .module = effectloop_mod },
        },
    });
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = exe_mod,
    });
    const install = b.addInstallArtifact(exe, .{});
    return &install.step;
}

/// SAFETY-ENFORCEMENT (unit C): build one self-contained Shen GC test set
/// compiled at `opt` and return its run step.  Because each mode needs its own
/// gc module (std.debug.assert inside the collector is gated by that module's
/// optimize), every call resolves its OWN zinc-vm dependency instance at that
/// optimize mode — the package's exported "gc" module therefore carries `opt`,
/// exactly like the pre-extraction per-mode b.createModule instances — then
/// wires gc_test (from the package) + addTest + run + the T9 expected-panic
/// exe (also from the package).
fn addGcTestSet(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    opt: std.builtin.OptimizeMode,
) *std.Build.Step {
    const zinc = b.dependency("zinc_vm", .{ .target = target, .optimize = opt });
    const gc_mod = zinc.module("gc");

    const gc_test_mod = b.createModule(.{
        .root_source_file = zinc.path("tests/gc_test.zig"),
        .target = target,
        .optimize = opt,
        .imports = &.{ .{ .name = "gc", .module = gc_mod } },
    });
    const gc_tests = b.addTest(.{ .root_module = gc_test_mod });
    const run_gc_tests = b.addRunArtifact(gc_tests);

    // ---- T9: expected-panic executable (plan DECISION 7) ----
    // Zig 0.16 has no in-process panic assertion, so the ROOT_PTR
    // interior-pointer defense (gc.c:1527-1539) is proven by a tiny exe that
    // overrides its root panic handler, matches the defense message, and
    // exits 42; the Run step expects exactly that.  Panic exit paths through
    // abort() are signal-based (nondeterministic for expect_term), hence the
    // handler-normalized exit code.
    const t9_mod = b.createModule(.{
        .root_source_file = zinc.path("tests/root_ptr_panic.zig"),
        .target = target,
        .optimize = opt,
        .imports = &.{ .{ .name = "gc", .module = gc_mod } },
    });
    const t9_exe = b.addExecutable(.{
        .name = "gc_root_ptr_panic",
        .root_module = t9_mod,
    });
    const run_t9 = b.addRunArtifact(t9_exe);
    run_t9.expectExitCode(42);

    // The T9 exe runs as part of this mode's gc-test set (before the tests).
    run_gc_tests.step.dependOn(&run_t9.step);

    return &run_gc_tests.step;
}

/// Build one self-contained Shen VM test set compiled at `opt` and return its
/// run step (plan M0, mirroring addGcTestSet).  Each mode gets its OWN zinc-vm
/// dependency instance (so the package's "gc"/"vm" modules carry that mode's
/// optimize, with no module-name clashes across the gate's three instances);
/// the vm_test module (from the package) imports both.
fn addVmTestSet(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    opt: std.builtin.OptimizeMode,
) *std.Build.Step {
    const zinc = b.dependency("zinc_vm", .{ .target = target, .optimize = opt });
    const gc_mod = zinc.module("gc");
    const vm_mod = zinc.module("vm");

    const vm_test_mod = b.createModule(.{
        .root_source_file = zinc.path("tests/vm_test.zig"),
        .target = target,
        .optimize = opt,
        .link_libc = true,
        .imports = &.{
            .{ .name = "gc", .module = gc_mod },
            .{ .name = "vm", .module = vm_mod },
        },
    });
    const vm_tests = b.addTest(.{ .root_module = vm_test_mod });
    const run_vm_tests = b.addRunArtifact(vm_tests);

    return &run_vm_tests.step;
}
