const std = @import("std");

/// Comprehensive test runner for zhttp
/// Runs all test suites and reports results

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n", .{});
    std.debug.print("╔═══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  zhttp Comprehensive Test Suite                          ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});

    var total_passed: usize = 0;
    var total_failed: usize = 0;

    // Parse command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var run_unit = true;
    var run_fuzz = false;
    var run_stress = false;
    var run_security = false;
    var run_bench = false;
    var verbose = false;

    if (args.len > 1) {
        run_unit = false; // If specific suites requested, don't run all by default

        for (args[1..]) |arg| {
            if (std.mem.eql(u8, arg, "--unit")) run_unit = true;
            if (std.mem.eql(u8, arg, "--fuzz")) run_fuzz = true;
            if (std.mem.eql(u8, arg, "--stress")) run_stress = true;
            if (std.mem.eql(u8, arg, "--security")) run_security = true;
            if (std.mem.eql(u8, arg, "--bench")) run_bench = true;
            if (std.mem.eql(u8, arg, "--all")) {
                run_unit = true;
                run_fuzz = true;
                run_stress = true;
                run_security = true;
            }
            if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
                verbose = true;
            }
            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                printHelp();
                return;
            }
        }
    }

    if (run_unit) {
        std.debug.print("📋 Running Unit Tests (Memory Leak Detection)\n", .{});
        std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});
        const result = try runTestSuite("zig", &[_][]const u8{ "test", "tests/unit/memory_leak_tests.zig" }, verbose);
        total_passed += result.passed;
        total_failed += result.failed;
    }

    if (run_fuzz) {
        std.debug.print("\n🎲 Running Fuzz Tests\n", .{});
        std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});
        const result = try runTestSuite("zig", &[_][]const u8{ "test", "tests/fuzz/fuzz_parsers.zig" }, verbose);
        total_passed += result.passed;
        total_failed += result.failed;
    }

    if (run_stress) {
        std.debug.print("\n💪 Running Stress Tests\n", .{});
        std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});
        const result = try runTestSuite("zig", &[_][]const u8{ "test", "tests/stress/stress_tests.zig" }, verbose);
        total_passed += result.passed;
        total_failed += result.failed;
    }

    if (run_security) {
        std.debug.print("\n🔒 Running Security Tests\n", .{});
        std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});
        const result = try runTestSuite("zig", &[_][]const u8{ "test", "tests/security/security_tests.zig" }, verbose);
        total_passed += result.passed;
        total_failed += result.failed;
    }

    if (run_bench) {
        std.debug.print("\n⚡ Running Benchmarks\n", .{});
        std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});
        _ = try runCommand("zig", &[_][]const u8{ "build", "bench" }, verbose);
    }

    // Summary
    std.debug.print("\n", .{});
    std.debug.print("╔═══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  Test Summary                                             ║\n", .{});
    std.debug.print("╠═══════════════════════════════════════════════════════════╣\n", .{});
    std.debug.print("║  ✅ Passed:  {d:4}                                          ║\n", .{total_passed});
    std.debug.print("║  ❌ Failed:  {d:4}                                          ║\n", .{total_failed});
    std.debug.print("╚═══════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});

    if (total_failed > 0) {
        std.debug.print("❌ Some tests failed!\n", .{});
        std.process.exit(1);
    } else {
        std.debug.print("✅ All tests passed!\n", .{});
        std.debug.print("\n🚀 zhttp is production ready!\n\n", .{});
    }
}

const TestResult = struct {
    passed: usize,
    failed: usize,
};

fn runTestSuite(cmd: []const u8, args: []const []const u8, verbose: bool) !TestResult {
    const result = try runCommand(cmd, args, verbose);

    // Parse output for test results
    // Zig test output format: "All X tests passed."
    var passed: usize = 0;
    var failed: usize = 0;

    if (std.mem.indexOf(u8, result.stdout, "All") != null and
        std.mem.indexOf(u8, result.stdout, "tests passed") != null)
    {
        // Extract number
        var iter = std.mem.tokenizeAny(u8, result.stdout, " \n");
        while (iter.next()) |token| {
            if (std.mem.eql(u8, token, "All")) {
                if (iter.next()) |num_str| {
                    passed = std.fmt.parseInt(usize, num_str, 10) catch 0;
                    break;
                }
            }
        }
    }

    if (result.term.Exited != 0) {
        failed = 1; // Some tests failed
    }

    return .{ .passed = passed, .failed = failed };
}

const CommandResult = struct {
    stdout: []u8,
    stderr: []u8,
    term: std.process.Child.Term,
};

fn runCommand(cmd: []const u8, args: []const []const u8, verbose: bool) !CommandResult {
    var child = std.process.Child.init(args, std.heap.page_allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    const stdout = try child.stdout.?.readToEndAlloc(std.heap.page_allocator, 10 * 1024 * 1024);
    const stderr = try child.stderr.?.readToEndAlloc(std.heap.page_allocator, 10 * 1024 * 1024);

    const term = try child.wait();

    if (verbose) {
        std.debug.print("{s}\n", .{stdout});
        if (stderr.len > 0) {
            std.debug.print("STDERR:\n{s}\n", .{stderr});
        }
    } else {
        // Just print summary
        if (term.Exited == 0) {
            std.debug.print("✅ Test suite passed\n", .{});
        } else {
            std.debug.print("❌ Test suite failed (exit code {})\n", .{term.Exited});
            std.debug.print("{s}\n", .{stderr});
        }
    }

    return .{
        .stdout = stdout,
        .stderr = stderr,
        .term = term,
    };
}

fn printHelp() void {
    std.debug.print(
        \\Usage: zig build test-all [options]
        \\
        \\Options:
        \\  --unit       Run unit tests (memory leak detection)
        \\  --fuzz       Run fuzz tests
        \\  --stress     Run stress tests
        \\  --security   Run security tests
        \\  --bench      Run benchmarks
        \\  --all        Run all test suites
        \\  -v, --verbose   Verbose output
        \\  -h, --help      Show this help
        \\
        \\Examples:
        \\  zig build test-all --unit
        \\  zig build test-all --all
        \\  zig build test-all --fuzz --security -v
        \\
    , .{});
}
