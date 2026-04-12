const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Vendored SQLite (compiled once, linked into binary and tests) ─────────
    const sqlite_mod = b.createModule(.{
        .target = target,
        .optimize = .ReleaseFast, // always compile SQLite optimised
    });
    sqlite_mod.addCSourceFile(.{
        .file = b.path("src/vendor/sqlite3.c"),
        .flags = &.{
            "-DSQLITE_THREADSAFE=0", // single-threaded; we serialize access ourselves
            "-DSQLITE_OMIT_LOAD_EXTENSION", // no dynamic extensions needed
            "-DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1", // NORMAL sync in WAL mode
            "-DSQLITE_DEFAULT_CACHE_SIZE=-16384", // 16 MB page cache
            "-std=c99",
        },
    });
    sqlite_mod.link_libc = true;

    const sqlite = b.addLibrary(.{
        .name = "sqlite3",
        .root_module = sqlite_mod,
    });

    // ── Helper: wire SQLite into a compile step ───────────────────────────────
    const sqlite_include = b.path("src/vendor");

    // ── Root module (shared between binary and tests) ─────────────────────────
    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ── Executable ────────────────────────────────────────────────────────────
    const exe = b.addExecutable(.{
        .name = "smallnano",
        .root_module = root_mod,
    });
    exe.linkLibrary(sqlite);
    exe.addIncludePath(sqlite_include);
    exe.linkLibC();
    b.installArtifact(exe);

    // ── Run step ──────────────────────────────────────────────────────────────
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the smallnano node");
    run_step.dependOn(&run_cmd.step);

    // ── Formatting check ─────────────────────────────────────────────────────
    const fmt_check_cmd = b.addSystemCommand(&.{
        "zig",
        "fmt",
        "--check",
        "src/",
        "build.zig",
    });
    const fmt_check_step = b.step("fmt-check", "Check source formatting");
    fmt_check_step.dependOn(&fmt_check_cmd.step);

    // ── Tests ─────────────────────────────────────────────────────────────────
    // Single test binary rooted at main.zig. All modules are imported
    // transitively, so relative cross-directory imports resolve correctly.
    const test_step = b.step("test", "Run all unit tests");

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const unit_tests = b.addTest(.{ .root_module = test_mod });
    unit_tests.linkLibrary(sqlite);
    unit_tests.addIncludePath(sqlite_include);
    unit_tests.linkLibC();
    const run_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_tests.step);

    // ── Fuzz harnesses ───────────────────────────────────────────────────────
    const fuzz_block_mod = b.createModule(.{
        .root_source_file = b.path("src/fuzz_block_deserialize.zig"),
        .target = target,
        .optimize = optimize,
    });
    const fuzz_block = b.addExecutable(.{
        .name = "fuzz-block-deserialize",
        .root_module = fuzz_block_mod,
    });
    fuzz_block.linkLibrary(sqlite);
    fuzz_block.addIncludePath(sqlite_include);
    fuzz_block.linkLibC();
    const fuzz_block_run = b.addRunArtifact(fuzz_block);
    if (b.args) |args| fuzz_block_run.addArgs(args);
    const fuzz_block_step = b.step("fuzz-block", "Run the block deserialisation fuzz harness");
    fuzz_block_step.dependOn(&fuzz_block_run.step);

    const fuzz_message_mod = b.createModule(.{
        .root_source_file = b.path("src/fuzz_message_decode.zig"),
        .target = target,
        .optimize = optimize,
    });
    const fuzz_message = b.addExecutable(.{
        .name = "fuzz-message-decode",
        .root_module = fuzz_message_mod,
    });
    fuzz_message.linkLibrary(sqlite);
    fuzz_message.addIncludePath(sqlite_include);
    fuzz_message.linkLibC();
    const fuzz_message_run = b.addRunArtifact(fuzz_message);
    if (b.args) |args| fuzz_message_run.addArgs(args);
    const fuzz_message_step = b.step("fuzz-message", "Run the wire-message decode fuzz harness");
    fuzz_message_step.dependOn(&fuzz_message_run.step);

    // ── Benchmark harness ────────────────────────────────────────────────────
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/bench_ledger_process.zig"),
        .target = target,
        .optimize = optimize,
    });
    const bench_exe = b.addExecutable(.{
        .name = "bench-ledger-process",
        .root_module = bench_mod,
    });
    bench_exe.linkLibrary(sqlite);
    bench_exe.addIncludePath(sqlite_include);
    bench_exe.linkLibC();
    const bench_run = b.addRunArtifact(bench_exe);
    if (b.args) |args| bench_run.addArgs(args);
    const bench_step = b.step("bench-ledger", "Run the ledger processing benchmark");
    bench_step.dependOn(&bench_run.step);

    const check_step = b.step("check", "Check formatting and run all unit tests");
    check_step.dependOn(&fmt_check_cmd.step);
    check_step.dependOn(&run_tests.step);
}
