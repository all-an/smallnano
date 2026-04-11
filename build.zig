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
            "-DSQLITE_THREADSAFE=0",        // single-threaded; we serialize access ourselves
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
}
