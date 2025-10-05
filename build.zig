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
    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});
    
    // Feature flags for HTTP engines and components
    const engine_h1 = b.option(bool, "engine_h1", "Enable HTTP/1.1 engine (default: true)") orelse true;
    const engine_h2 = b.option(bool, "engine_h2", "Enable HTTP/2 engine (default: false)") orelse false;
    const engine_h3 = b.option(bool, "engine_h3", "Enable HTTP/3 engine (default: false)") orelse false;
    const enable_async = b.option(bool, "async", "Enable async runtime via zsync (default: true)") orelse true;
    const with_brotli = b.option(bool, "with_brotli", "Enable Brotli compression support (default: false)") orelse false;
    const with_zlib = b.option(bool, "with_zlib", "Enable zlib/gzip compression support (default: true)") orelse true;
    const quic_backend = b.option([]const u8, "quic_backend", "QUIC backend: msquic|quiche|none (default: none)") orelse "none";

    // This creates a module, which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Zig modules are the preferred way of making Zig code available to consumers.
    // addModule defines a module that we intend to make available for importing
    // to our consumers. We must give it a name because a Zig package can expose
    // multiple modules and consumers will need to be able to specify which
    // module they want to access.
    const mod = b.addModule("zhttp", .{
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
    
    // Add build options to the module
    const build_options = b.addOptions();
    build_options.addOption(bool, "engine_h1", engine_h1);
    build_options.addOption(bool, "engine_h2", engine_h2);
    build_options.addOption(bool, "engine_h3", engine_h3);
    build_options.addOption(bool, "enable_async", enable_async);
    build_options.addOption(bool, "with_brotli", with_brotli);
    build_options.addOption(bool, "with_zlib", with_zlib);
    build_options.addOption([]const u8, "quic_backend", quic_backend);
    
    // Create a single build_options module
    const build_options_module = build_options.createModule();
    mod.addImport("build_options", build_options_module);
    
    // Async runtime is now built-in (homebrew)
    // No external dependencies needed for async support

    // Add zquic dependency if HTTP/3 is enabled
    if (engine_h3 and !std.mem.eql(u8, quic_backend, "none")) {
        const zquic_dep = b.dependency("zquic", .{
            .target = target,
            .optimize = optimize,
            .enable_http3 = true,
            .enable_async_zsync = enable_async,
        });
        mod.addImport("zquic", zquic_dep.module("zquic"));
    }

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
        .name = "zhttp",
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
                .{ .name = "zhttp", .module = mod },
                .{ .name = "build_options", .module = build_options_module },
            },
        }),
    });

    // This declares intent for the executable to be installed into the
    // install prefix when running `zig build` (i.e. when executing the default
    // step). By default the install prefix is `zig-out/` but can be overridden
    // by passing `--prefix` or `-p`.
    b.installArtifact(exe);

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

    // Advanced test suites for production readiness
    // Memory leak detection tests
    const memory_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/memory_leak_tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zhttp", .module = mod },
                .{ .name = "build_options", .module = build_options_module },
            },
        }),
    });
    const run_memory_tests = b.addRunArtifact(memory_tests);
    const memory_test_step = b.step("test-memory", "Run memory leak detection tests");
    memory_test_step.dependOn(&run_memory_tests.step);

    // Fuzz tests
    const fuzz_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fuzz/fuzz_parsers.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zhttp", .module = mod },
                .{ .name = "build_options", .module = build_options_module },
            },
        }),
    });
    const run_fuzz_tests = b.addRunArtifact(fuzz_tests);
    const fuzz_test_step = b.step("test-fuzz", "Run fuzz tests");
    fuzz_test_step.dependOn(&run_fuzz_tests.step);

    // Stress tests
    const stress_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/stress/stress_tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zhttp", .module = mod },
                .{ .name = "build_options", .module = build_options_module },
            },
        }),
    });
    const run_stress_tests = b.addRunArtifact(stress_tests);
    const stress_test_step = b.step("test-stress", "Run stress tests");
    stress_test_step.dependOn(&run_stress_tests.step);

    // Security tests
    const security_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/security/security_tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zhttp", .module = mod },
                .{ .name = "build_options", .module = build_options_module },
            },
        }),
    });
    const run_security_tests = b.addRunArtifact(security_tests);
    const security_test_step = b.step("test-security", "Run security hardening tests");
    security_test_step.dependOn(&run_security_tests.step);

    // Comprehensive test suite
    const test_all_step = b.step("test-all", "Run all test suites (unit + fuzz + stress + security)");
    test_all_step.dependOn(test_step);
    test_all_step.dependOn(&run_memory_tests.step);
    test_all_step.dependOn(&run_fuzz_tests.step);
    test_all_step.dependOn(&run_stress_tests.step);
    test_all_step.dependOn(&run_security_tests.step);

    // Benchmark executable
    const bench_exe = b.addExecutable(.{
        .name = "benchmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/benchmark.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zhttp", .module = mod },
                .{ .name = "build_options", .module = build_options_module },
            },
        }),
    });
    // Don't install benchmark by default - only when bench step is run
    const install_bench = b.addInstallArtifact(bench_exe, .{});

    const run_bench = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Run performance benchmarks");
    bench_step.dependOn(&install_bench.step);
    bench_step.dependOn(&run_bench.step);

    // Example executables
    const examples = [_]struct { name: []const u8, path: []const u8, desc: []const u8 }{
        .{ .name = "get", .path = "examples/get.zig", .desc = "Simple GET request example" },
        .{ .name = "post_json", .path = "examples/post_json.zig", .desc = "POST request with JSON body" },
        .{ .name = "download", .path = "examples/download.zig", .desc = "File download example" },
        .{ .name = "test_https", .path = "examples/test_https.zig", .desc = "HTTPS request with TLS example" },
        .{ .name = "test_https_no_verify", .path = "examples/test_https_no_verify.zig", .desc = "HTTPS request without certificate verification" },
        .{ .name = "debug_https", .path = "examples/debug_https.zig", .desc = "Debug HTTPS connection issues" },
        .{ .name = "minimal_tls", .path = "examples/minimal_tls.zig", .desc = "Minimal TLS test" },
        .{ .name = "debug_tls_like_client", .path = "examples/debug_tls_like_client.zig", .desc = "TLS test with HTTP client structure" },
        .{ .name = "exact_copy_test", .path = "examples/exact_copy_test.zig", .desc = "Exact copy of working TLS example with HTTP client pattern" },
        .{ .name = "test_https_with_verification", .path = "examples/test_https_with_verification.zig", .desc = "HTTPS test with certificate verification enabled" },
        .{ .name = "debug_tls_connection_only", .path = "examples/debug_tls_connection_only.zig", .desc = "Test HTTP client TLS setup in isolation" },
        .{ .name = "async_get", .path = "examples/async_get.zig", .desc = "Async GET request using zsync runtime" },
        .{ .name = "http1_server", .path = "examples/http1_server.zig", .desc = "HTTP/1.1 server example" },
        .{ .name = "http2_server", .path = "examples/http2_server.zig", .desc = "HTTP/2 server example" },
        .{ .name = "http3_server", .path = "examples/http3_server.zig", .desc = "HTTP/3 over QUIC server example" },
    };

    for (examples) |example| {
        const example_exe = b.addExecutable(.{
            .name = example.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(example.path),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                .{ .name = "zhttp", .module = mod },
                .{ .name = "build_options", .module = build_options_module },
            },
            }),
        });

        b.installArtifact(example_exe);

        // Create run step for each example
        const run_example = b.addRunArtifact(example_exe);
        if (b.args) |args| {
            run_example.addArgs(args);
        }
        const run_example_step = b.step(b.fmt("run-{s}", .{example.name}), example.desc);
        run_example_step.dependOn(&run_example.step);
    }

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
