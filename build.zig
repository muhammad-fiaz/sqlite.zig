const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.addModule("sqlite_zig", .{
        .root_source_file = b.path("src/sqlite.zig"),
        .target = target,
        .optimize = optimize,
    });

    const library = b.addLibrary(.{
        .name = "sqlite_zig",
        .root_module = module,
        .linkage = .static,
    });
    b.installArtifact(library);

    const tests = b.addTest(.{ .root_module = module });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run the sqlite.zig test suite");
    test_step.dependOn(&run_tests.step);

    const examples_step = b.step("examples", "Build all sqlite.zig examples");
    const examples = [_][]const u8{
        "01_open_and_exec",
        "02_prepared_statement",
        "03_transactions",
        "04_dsl_query_builder",
        "05_migrations",
        "06_error_handling",
        "07_python_interop",
        "08_repair_legacy_example",
    };
    for (examples) |name| {
        const executable = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("examples/{s}.zig", .{name})),
                .target = target,
                .optimize = optimize,
            }),
        });
        executable.root_module.addImport("sqlite_zig", module);
        b.installArtifact(executable);
        examples_step.dependOn(&executable.step);
    }
}
