const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main module
    const module = b.addModule("sqlite", .{
        .root_source_file = b.path("src/sqlite.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Static library
    const library = b.addLibrary(.{
        .name = "sqlite",
        .root_module = module,
        .linkage = .static,
    });
    b.installArtifact(library);

    // Documentation
    const install_docs = b.addInstallDirectory(.{
        .source_dir = library.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    const docs_step = b.step(
        "docs",
        "Generate sqlite.zig API documentation",
    );
    docs_step.dependOn(&install_docs.step);

    // Tests
    const tests = b.addTest(.{
        .root_module = module,
    });

    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step(
        "test",
        "Run the sqlite.zig test suite",
    );
    test_step.dependOn(&run_tests.step);

    // Examples
    const build_examples = b.step(
        "examples",
        "Build all sqlite.zig examples",
    );

    const run_all_examples = b.step(
        "run-all-examples",
        "Build and run every sqlite.zig example",
    );

    const examples = [_][]const u8{
        "01_open_and_exec",
        "02_prepared_statement",
        "03_transactions",
        "04_dsl_query_builder",
        "05_migrations",
        "06_error_handling",
        "07_python_interop",
        "08_repair_legacy_example",
        "09_dsl_crud",
        "10_dsl_advanced",
        "11_keys_and_joins",
        "12_complex_queries",
        "13_edge_cases",
    };

    inline for (examples) |name| {
        const exe = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    b.fmt("examples/{s}.zig", .{name}),
                ),
                .target = target,
                .optimize = optimize,
            }),
        });

        exe.root_module.addImport("sqlite", module);

        b.installArtifact(exe);

        // Build example
        build_examples.dependOn(&exe.step);

        // Run example
        const run = b.addRunArtifact(exe);
        run.step.dependOn(b.getInstallStep());
        run_all_examples.dependOn(&run.step);
    }
}
