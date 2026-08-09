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
        "14_dsl_select_projections",
        "15_raw_dsl_interoperability",
        "16_dsl_predicates_pagination",
        "17_persistence_reopen_verification",
        "18_schema_lifecycle_verification",
        "19_prepared_parameter_verification",
        "20_scalar_functions_typed_dsl",
        "21_indexed_queries",
        "22_views_and_typed_reads",
        "23_triggers_raw_and_dsl",
        "24_cte_raw_and_typed_reads",
        "25_subqueries_raw_and_typed_dsl",
        "26_foreign_key_actions",
        "27_composite_unique_keys",
        "28_foreign_key_update_actions",
        "29_multiple_ctes",
        "30_composite_table_constraints",
        "31_composite_foreign_keys",
        "32_recursive_ctes",
        "33_explain_query_plan",
        "34_virtual_generate_series",
        "35_wal_journal_mode",
        "36_grouped_aggregates",
        "37_insert_select_copy",
        "38_insert_or_ignore",
        "39_upsert_do_nothing",
        "40_upsert_do_update",
        "41_insert_or_replace",
        "42_update_from_join",
        "43_not_in_subqueries",
        "44_exists_subqueries",
        "45_literal_in_lists",
        "46_raw_alter_table",
        "47_column_defaults",
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

        // Individual run step (e.g. run-01_open_and_exec)
        const run_step_name = b.fmt("run-{s}", .{name});
        const run = b.addRunArtifact(exe);
        run.step.dependOn(b.getInstallStep());
        const run_step = b.step(run_step_name, b.fmt("Run {s} example", .{name}));
        run_step.dependOn(&run.step);

        // Aggregate run step
        run_all_examples.dependOn(&run.step);
    }
}
