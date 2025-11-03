const std = @import("std");
const net = std.net;

/// Timeout and error recovery utilities for HTTP client

/// Timeout configuration
pub const TimeoutConfig = struct {
    connect_timeout_ms: ?u64 = 10000, // 10 seconds
    read_timeout_ms: ?u64 = 30000, // 30 seconds
    write_timeout_ms: ?u64 = 30000, // 30 seconds
    total_timeout_ms: ?u64 = 60000, // 60 seconds total
};

/// Timeout error
pub const TimeoutError = error{
    ConnectTimeout,
    ReadTimeout,
    WriteTimeout,
    TotalTimeout,
};

/// Timeout manager
pub const TimeoutManager = struct {
    config: TimeoutConfig,
    start_time: i64,

    pub fn init(config: TimeoutConfig) TimeoutManager {
        return .{
            .config = config,
            .start_time = std.time.milliTimestamp(),
        };
    }

    /// Check if total timeout has been exceeded
    pub fn checkTotalTimeout(self: *const TimeoutManager) !void {
        if (self.config.total_timeout_ms) |timeout| {
            const elapsed = @as(u64, @intCast(std.time.milliTimestamp() - self.start_time));
            if (elapsed > timeout) {
                return TimeoutError.TotalTimeout;
            }
        }
    }

    /// Get remaining time for operation
    pub fn getRemainingTime(self: *const TimeoutManager, timeout_ms: ?u64) ?u64 {
        const timeout = timeout_ms orelse return null;

        const elapsed = @as(u64, @intCast(std.time.milliTimestamp() - self.start_time));
        if (elapsed >= timeout) {
            return 0;
        }

        return timeout - elapsed;
    }

    /// Check if we should timeout for connect operation
    pub fn checkConnectTimeout(self: *const TimeoutManager) !void {
        if (self.config.connect_timeout_ms) |timeout| {
            const elapsed = @as(u64, @intCast(std.time.milliTimestamp() - self.start_time));
            if (elapsed > timeout) {
                return TimeoutError.ConnectTimeout;
            }
        }
    }
};

/// Retry configuration
pub const RetryConfig = struct {
    max_retries: usize = 3,
    initial_backoff_ms: u64 = 100,
    max_backoff_ms: u64 = 10000,
    backoff_multiplier: f64 = 2.0,
    retry_on_timeout: bool = true,
    retry_on_connection_error: bool = true,
    retry_on_5xx: bool = true,
};

/// Retry strategy
pub const RetryStrategy = struct {
    config: RetryConfig,
    attempt: usize = 0,

    pub fn init(config: RetryConfig) RetryStrategy {
        return .{ .config = config };
    }

    /// Should retry based on error
    pub fn shouldRetry(self: *const RetryStrategy, err: anyerror) bool {
        if (self.attempt >= self.config.max_retries) {
            return false;
        }

        // Check if error is retryable
        return switch (err) {
            TimeoutError.ConnectTimeout,
            TimeoutError.ReadTimeout,
            TimeoutError.WriteTimeout,
            => self.config.retry_on_timeout,

            error.ConnectionRefused,
            error.NetworkUnreachable,
            error.HostUnreachable,
            => self.config.retry_on_connection_error,

            else => false,
        };
    }

    /// Get backoff duration for current attempt
    pub fn getBackoff(self: *const RetryStrategy) u64 {
        const backoff_duration = @as(f64, @floatFromInt(self.config.initial_backoff_ms)) *
            std.math.pow(f64, self.config.backoff_multiplier, @as(f64, @floatFromInt(self.attempt)));

        return @min(@as(u64, @intFromFloat(backoff_duration)), self.config.max_backoff_ms);
    }

    /// Sleep for backoff duration
    pub fn backoff(self: *RetryStrategy) void {
        const duration = self.getBackoff();
        std.time.sleep(duration * std.time.ns_per_ms);
        self.attempt += 1;
    }

    /// Reset retry counter
    pub fn reset(self: *RetryStrategy) void {
        self.attempt = 0;
    }
};

/// Timed reader wrapper
pub const TimedReader = struct {
    reader: *std.Io.Reader,
    timeout_ms: ?u64,
    start_time: i64,

    pub fn init(reader: *std.Io.Reader, timeout_ms: ?u64) TimedReader {
        return .{
            .reader = reader,
            .timeout_ms = timeout_ms,
            .start_time = std.time.milliTimestamp(),
        };
    }

    pub fn read(self: *TimedReader, buffer: []u8) !usize {
        if (self.timeout_ms) |timeout| {
            const elapsed = @as(u64, @intCast(std.time.milliTimestamp() - self.start_time));
            if (elapsed > timeout) {
                return TimeoutError.ReadTimeout;
            }
        }

        return try self.reader.readSliceShort(buffer);
    }

    pub fn readAll(self: *TimedReader, buffer: []u8) !usize {
        var index: usize = 0;
        while (index < buffer.len) {
            const amt = try self.read(buffer[index..]);
            if (amt == 0) break;
            index += amt;
        }
        return index;
    }

    pub fn readByte(self: *TimedReader) !u8 {
        if (self.timeout_ms) |timeout| {
            const elapsed = @as(u64, @intCast(std.time.milliTimestamp() - self.start_time));
            if (elapsed > timeout) {
                return TimeoutError.ReadTimeout;
            }
        }

        return try self.reader.takeByte();
    }
};

/// Timed writer wrapper
pub const TimedWriter = struct {
    writer: *std.Io.Writer,
    timeout_ms: ?u64,
    start_time: i64,

    pub fn init(writer: *std.Io.Writer, timeout_ms: ?u64) TimedWriter {
        return .{
            .writer = writer,
            .timeout_ms = timeout_ms,
            .start_time = std.time.milliTimestamp(),
        };
    }

    pub fn write(self: *TimedWriter, bytes: []const u8) !usize {
        if (self.timeout_ms) |timeout| {
            const elapsed = @as(u64, @intCast(std.time.milliTimestamp() - self.start_time));
            if (elapsed > timeout) {
                return TimeoutError.WriteTimeout;
            }
        }

        var data: [1][]const u8 = .{bytes};
        return try self.writer.writeVec(&data);
    }

    pub fn writeAll(self: *TimedWriter, bytes: []const u8) !void {
        if (self.timeout_ms) |timeout| {
            const elapsed = @as(u64, @intCast(std.time.milliTimestamp() - self.start_time));
            if (elapsed > timeout) {
                return TimeoutError.WriteTimeout;
            }
        }

        try self.writer.writeAll(bytes);
    }
};

test "timeout manager basic" {
    const config = TimeoutConfig{
        .total_timeout_ms = 1000,
    };

    const manager = TimeoutManager.init(config);
    try manager.checkTotalTimeout();
}

test "retry strategy backoff" {
    const config = RetryConfig{
        .max_retries = 3,
        .initial_backoff_ms = 100,
        .backoff_multiplier = 2.0,
    };

    var strategy = RetryStrategy.init(config);

    try std.testing.expectEqual(@as(u64, 100), strategy.getBackoff());
    strategy.attempt = 1;
    try std.testing.expectEqual(@as(u64, 200), strategy.getBackoff());
    strategy.attempt = 2;
    try std.testing.expectEqual(@as(u64, 400), strategy.getBackoff());
}

test "retry strategy should retry" {
    const config = RetryConfig{
        .max_retries = 3,
        .retry_on_timeout = true,
    };

    const strategy = RetryStrategy.init(config);

    try std.testing.expect(strategy.shouldRetry(TimeoutError.ConnectTimeout));
    try std.testing.expect(strategy.shouldRetry(error.ConnectionRefused));
}
