const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.addModule("sqlite", .{
        .root_source_file = b.path("src/sqlite.zig"),
        .target = target,
        .optimize = optimize,
    });

    const library = b.addLibrary(.{
        .name = "sqlite",
        .root_module = module,
        .linkage = .static,
    });
    b.installArtifact(library);

    const installDocs = b.addInstallDirectory(.{
        .source_dir = library.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    const docsStep = b.step(
        "docs",
        "Generate sqlite.zig API documentation",
    );
    docsStep.dependOn(&installDocs.step);

    const tests = b.addTest(.{
        .root_module = module,
    });

    const runTests = b.addRunArtifact(tests);

    const testStep = b.step(
        "test",
        "Run the sqlite.zig test suite",
    );
    testStep.dependOn(&runTests.step);

    // Compile-only verification: builds the library and the test binary
    // without installing the 70 example executables and without executing
    // anything. Cross-check CI jobs use this so one target costs two
    // compilations instead of 140+; use `test` or the default install step
    // when examples or execution are needed.
    const checkStep = b.step(
        "check",
        "Compile the library and test suite without running",
    );
    checkStep.dependOn(&library.step);
    checkStep.dependOn(&tests.step);

    const buildExamples = b.step(
        "examples",
        "Build all sqlite.zig examples",
    );

    const runAllExamples = b.step(
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
        "07_file_format",
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
        "48_raw_dsl",
        "49_sqlite_coverage_layers",
        "50_schema_validation_interop",
        "51_dsl_ctes",
        "52_column_mapping",
        "53_expression_operators",
        "54_derived_tables",
        "55_returning",
        "56_upsert_dsl",
        "57_before_triggers",
        "58_case_dsl",
        "59_using_natural_joins",
        "60_multi_column_using",
        "61_compound_dsl",
        "62_pragma_checks",
        "63_derived_dsl",
        "64_window_dsl",
        "65_generated_columns",
        "66_strict_tables",
        "67_without_rowid",
        "68_partial_expression_indexes",
        "69_multi_key_order_by",
        "70_collision_free_dsl",
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

        buildExamples.dependOn(&exe.step);

        const runStepName = b.fmt("run-{s}", .{name});
        const run = b.addRunArtifact(exe);
        run.step.dependOn(b.getInstallStep());
        const runStep = b.step(runStepName, b.fmt("Run {s} example", .{name}));
        runStep.dependOn(&run.step);

        runAllExamples.dependOn(&run.step);
    }
}
