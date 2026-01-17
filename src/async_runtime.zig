const std = @import("std");
const builtin = @import("builtin");
const net = std.net;
const os = std.os;
const linux = os.linux;
const posix = std.posix;
const compat = @import("compat.zig");

/// Create an epoll instance (posix.epoll_create1 was removed in Zig 0.16)
fn epollCreate1(flags: u32) !i32 {
    const rc = linux.epoll_create1(flags);
    return switch (linux.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        .NOMEM => error.SystemResources,
        .INVAL => error.InvalidArgument,
        else => error.Unexpected,
    };
}

/// Homebrew async runtime for zhttp
/// Provides minimal event loop, task scheduling, and timer support
/// Eliminates external dependencies like zsync
/// Task state for async operations
pub const TaskState = enum {
    pending,
    running,
    completed,
    failed,
};

/// Future representing an async computation
pub fn Future(comptime T: type) type {
    return struct {
        state: TaskState,
        result: ?T,
        err: ?anyerror,

        const Self = @This();

        pub fn init() Self {
            return .{
                .state = .pending,
                .result = null,
                .err = null,
            };
        }

        pub fn complete(self: *Self, value: T) void {
            self.result = value;
            self.state = .completed;
        }

        pub fn fail(self: *Self, err: anyerror) void {
            self.err = err;
            self.state = .failed;
        }

        pub fn get(self: *Self) !T {
            return switch (self.state) {
                .completed => self.result.?,
                .failed => self.err.?,
                .pending, .running => error.TaskNotComplete,
            };
        }
    };
}

/// Task handle for managing async operations
pub const Task = struct {
    id: u64,
    state: TaskState,
    callback: *const fn (*Task) anyerror!void,

    pub fn init(id: u64, callback: *const fn (*Task) anyerror!void) Task {
        return .{
            .id = id,
            .state = .pending,
            .callback = callback,
        };
    }

    pub fn run(self: *Task) !void {
        self.state = .running;
        self.callback(self) catch |err| {
            self.state = .failed;
            return err;
        };
        self.state = .completed;
    }
};

/// I/O event types
pub const EventType = enum {
    read,
    write,
    err,
    timeout,
};

/// I/O event
pub const Event = struct {
    fd: std.posix.fd_t,
    event_type: EventType,
    data: ?*anyopaque = null,
};

/// Timer for timeout handling
pub const Timer = struct {
    id: u64,
    deadline_ms: u64,
    callback: *const fn (*Timer) void,
    cancelled: bool = false,

    pub fn init(id: u64, timeout_ms: u64, callback: *const fn (*Timer) void) Timer {
        const now: u64 = @intCast(compat.milliTimestamp());
        return .{
            .id = id,
            .deadline_ms = now + timeout_ms,
            .callback = callback,
        };
    }

    pub fn cancel(self: *Timer) void {
        self.cancelled = true;
    }

    pub fn isExpired(self: *const Timer) bool {
        if (self.cancelled) return false;
        const now: u64 = @intCast(compat.milliTimestamp());
        return now >= self.deadline_ms;
    }
};

/// Event loop implementation - platform specific
pub const EventLoop = struct {
    allocator: std.mem.Allocator,
    epoll_fd: if (builtin.os.tag == .linux) std.posix.fd_t else void,
    kqueue_fd: if (builtin.os.tag == .macos or builtin.os.tag == .freebsd) std.posix.fd_t else void,
    running: bool,
    tasks: std.ArrayList(Task),
    timers: std.ArrayList(Timer),
    next_task_id: u64,
    next_timer_id: u64,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        var loop = Self{
            .allocator = allocator,
            .epoll_fd = if (builtin.os.tag == .linux) undefined else {},
            .kqueue_fd = if (builtin.os.tag == .macos or builtin.os.tag == .freebsd) undefined else {},
            .running = false,
            .tasks = .{},
            .timers = .{},
            .next_task_id = 0,
            .next_timer_id = 0,
        };

        // Initialize platform-specific event mechanism
        if (builtin.os.tag == .linux) {
            loop.epoll_fd = try epollCreate1(linux.EPOLL.CLOEXEC);
        } else if (builtin.os.tag == .macos or builtin.os.tag == .freebsd) {
            loop.kqueue_fd = std.posix.system.kqueue();
        }

        return loop;
    }

    pub fn deinit(self: *Self) void {
        if (builtin.os.tag == .linux) {
            std.posix.close(self.epoll_fd);
        } else if (builtin.os.tag == .macos or builtin.os.tag == .freebsd) {
            std.posix.close(self.kqueue_fd);
        }
        self.tasks.deinit(self.allocator);
        self.timers.deinit(self.allocator);
    }

    /// Add a file descriptor to monitor for events
    pub fn addFd(self: *Self, fd: std.posix.fd_t, event_type: EventType) !void {
        if (builtin.os.tag == .linux) {
            var event = linux.epoll_event{
                .events = switch (event_type) {
                    .read => linux.EPOLL.IN,
                    .write => linux.EPOLL.OUT,
                    .err => linux.EPOLL.ERR,
                    .timeout => 0,
                },
                .data = .{ .fd = fd },
            };
            try std.posix.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_ADD, fd, &event);
        } else if (builtin.os.tag == .macos or builtin.os.tag == .freebsd) {
            const filter: i16 = switch (event_type) {
                .read => std.posix.system.EVFILT_READ,
                .write => std.posix.system.EVFILT_WRITE,
                else => return error.UnsupportedEventType,
            };
            var kev = std.mem.zeroes(std.posix.system.Kevent);
            kev.ident = @intCast(fd);
            kev.filter = filter;
            kev.flags = std.posix.system.EV_ADD | std.posix.system.EV_ENABLE;
            var timeout = std.mem.zeroes(std.posix.system.timespec);
            _ = try std.posix.system.kevent(self.kqueue_fd, &[_]std.posix.system.Kevent{kev}, &[_]std.posix.system.Kevent{}, &timeout);
        }
    }

    /// Remove a file descriptor from monitoring
    pub fn removeFd(self: *Self, fd: std.posix.fd_t) !void {
        if (builtin.os.tag == .linux) {
            try std.posix.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_DEL, fd, null);
        } else if (builtin.os.tag == .macos or builtin.os.tag == .freebsd) {
            var kev = std.mem.zeroes(std.posix.system.Kevent);
            kev.ident = @intCast(fd);
            kev.flags = std.posix.system.EV_DELETE;
            var timeout = std.mem.zeroes(std.posix.system.timespec);
            _ = try std.posix.system.kevent(self.kqueue_fd, &[_]std.posix.system.Kevent{kev}, &[_]std.posix.system.Kevent{}, &timeout);
        }
    }

    /// Schedule a task for execution
    pub fn scheduleTask(self: *Self, callback: *const fn (*Task) anyerror!void) !u64 {
        const task_id = self.next_task_id;
        self.next_task_id += 1;

        const task = Task.init(task_id, callback);
        try self.tasks.append(self.allocator, task);

        return task_id;
    }

    /// Schedule a timer
    pub fn scheduleTimer(self: *Self, timeout_ms: u64, callback: *const fn (*Timer) void) !u64 {
        const timer_id = self.next_timer_id;
        self.next_timer_id += 1;

        const timer = Timer.init(timer_id, timeout_ms, callback);
        try self.timers.append(self.allocator, timer);

        return timer_id;
    }

    /// Process expired timers
    fn processTimers(self: *Self) void {
        var i: usize = 0;
        while (i < self.timers.items.len) {
            const timer = &self.timers.items[i];
            if (timer.isExpired()) {
                timer.callback(timer);
                _ = self.timers.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    /// Process pending tasks
    fn processTasks(self: *Self) !void {
        var i: usize = 0;
        while (i < self.tasks.items.len) {
            var task = &self.tasks.items[i];
            if (task.state == .pending) {
                task.run() catch |err| {
                    std.debug.print("Task {d} failed: {}\n", .{ task.id, err });
                };
            }
            if (task.state == .completed or task.state == .failed) {
                _ = self.tasks.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    /// Run the event loop
    pub fn run(self: *Self) !void {
        self.running = true;

        while (self.running) {
            // Process timers
            self.processTimers();

            // Process tasks
            try self.processTasks();

            // Wait for I/O events with timeout
            if (builtin.os.tag == .linux) {
                var events: [32]linux.epoll_event = undefined;
                const timeout_ms: i32 = if (self.timers.items.len > 0) 10 else 1000;
                const n = std.posix.epoll_wait(self.epoll_fd, &events, timeout_ms);

                for (events[0..n]) |event| {
                    // Handle I/O event
                    _ = event;
                    // TODO: Dispatch to appropriate handler
                }
            } else if (builtin.os.tag == .macos or builtin.os.tag == .freebsd) {
                var events: [32]std.posix.system.Kevent = undefined;
                var timeout = std.posix.system.timespec{
                    .tv_sec = 0,
                    .tv_nsec = if (self.timers.items.len > 0) 10_000_000 else 1_000_000_000,
                };
                const n = try std.posix.system.kevent(self.kqueue_fd, &[_]std.posix.system.Kevent{}, &events, &timeout);

                for (events[0..n]) |event| {
                    // Handle I/O event
                    _ = event;
                    // TODO: Dispatch to appropriate handler
                }
            }

            // Exit if no work to do
            if (self.tasks.items.len == 0 and self.timers.items.len == 0) {
                break;
            }
        }
    }

    /// Stop the event loop
    pub fn stop(self: *Self) void {
        self.running = false;
    }
};

/// Async I/O operations
pub const AsyncIO = struct {
    loop: *EventLoop,

    const Self = @This();

    pub fn init(loop: *EventLoop) Self {
        return .{ .loop = loop };
    }

    /// Async read with timeout
    pub fn read(self: Self, fd: os.fd_t, buffer: []u8, timeout_ms: u64) !usize {
        _ = self;
        _ = fd;
        _ = buffer;
        _ = timeout_ms;
        // TODO: Implement non-blocking read with event loop integration
        return error.NotImplemented;
    }

    /// Async write with timeout
    pub fn write(self: Self, fd: os.fd_t, buffer: []const u8, timeout_ms: u64) !usize {
        _ = self;
        _ = fd;
        _ = buffer;
        _ = timeout_ms;
        // TODO: Implement non-blocking write with event loop integration
        return error.NotImplemented;
    }

    /// Async connect with timeout
    pub fn connect(self: Self, address: net.Address, timeout_ms: u64) !net.Stream {
        _ = self;
        _ = address;
        _ = timeout_ms;
        // TODO: Implement non-blocking connect with event loop integration
        return error.NotImplemented;
    }
};

test "EventLoop init/deinit" {
    const allocator = std.testing.allocator;
    var loop = try EventLoop.init(allocator);
    defer loop.deinit();
}

test "Future completion" {
    var future = Future(i32).init();
    try std.testing.expect(future.state == .pending);

    future.complete(42);
    try std.testing.expect(future.state == .completed);

    const result = try future.get();
    try std.testing.expectEqual(@as(i32, 42), result);
}

test "Timer expiration" {
    var timer = Timer.init(0, 100, struct {
        fn callback(t: *Timer) void {
            _ = t;
        }
    }.callback);

    // Timer should not be expired immediately
    try std.testing.expect(!timer.isExpired());

    // Sleep and check expiration
    std.time.sleep(150 * std.time.ns_per_ms);
    try std.testing.expect(timer.isExpired());
}
