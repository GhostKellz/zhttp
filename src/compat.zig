// Compatibility helpers for Zig 0.16 API changes
const std = @import("std");
const Io = std.Io;
const net = Io.net;
const posix = std.posix;

/// Get current time in milliseconds since epoch (replacement for std.time.milliTimestamp)
pub fn milliTimestamp() i64 {
    const ts = posix.clock_gettime(posix.CLOCK.REALTIME) catch return 0;
    return @as(i64, ts.sec) * 1000 + @divFloor(ts.nsec, 1_000_000);
}

/// Get current timestamp in Io.Timestamp format
pub fn now() Io.Timestamp {
    const ts = posix.clock_gettime(posix.CLOCK.REALTIME) catch return .{ .nanoseconds = 0 };
    return .{ .nanoseconds = @as(i96, @intCast(ts.sec * 1_000_000_000 + ts.nsec)) };
}

/// Get current time in seconds (for TLS)
pub fn realtimeNowSeconds() i64 {
    const ts = posix.clock_gettime(posix.CLOCK.REALTIME) catch return 0;
    return ts.sec;
}

/// Close a stream (simpler than the Io-based close in Zig 0.16)
pub fn closeStream(stream: net.Stream) void {
    posix.close(stream.socket.handle);
}

/// Write all bytes to a stream (replacement for stream.writeAll)
pub fn writeAll(stream: net.Stream, bytes: []const u8) !void {
    var index: usize = 0;
    while (index < bytes.len) {
        const written = try posix.write(stream.socket.handle, bytes[index..]);
        if (written == 0) return error.ConnectionClosed;
        index += written;
    }
}

/// Buffered reader for blocking I/O (replacement for Stream.Reader)
pub const BufferedReader = struct {
    stream: net.Stream,
    io_reader: Io.Reader,

    pub fn init(stream: net.Stream, buffer: []u8) BufferedReader {
        return .{
            .stream = stream,
            .io_reader = .{
                .vtable = &vtable,
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
        };
    }

    pub fn reader(self: *BufferedReader) *Io.Reader {
        return &self.io_reader;
    }

    const vtable = Io.Reader.VTable{
        .stream = streamFn,
        .discard = discardFn,
    };

    fn streamFn(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) anyerror!usize {
        const self: *BufferedReader = @fieldParentPtr("io_reader", r);
        _ = w;

        // Read directly from socket
        const max_read = limit.minInt(r.buffer.len);
        if (max_read == 0) return 0;

        const n = posix.read(self.stream.socket.handle, r.buffer[0..max_read]) catch |err| {
            return err;
        };
        r.end = n;
        r.seek = 0;
        return n;
    }

    fn discardFn(r: *Io.Reader, limit: Io.Limit) anyerror!usize {
        const self: *BufferedReader = @fieldParentPtr("io_reader", r);
        var total: usize = 0;
        var remaining = limit.toInt() orelse std.math.maxInt(usize);

        var discard_buf: [4096]u8 = undefined;
        while (remaining > 0) {
            const to_read = @min(remaining, discard_buf.len);
            const n = posix.read(self.stream.socket.handle, discard_buf[0..to_read]) catch |err| {
                return if (total > 0) total else err;
            };
            if (n == 0) break;
            total += n;
            remaining -= n;
        }
        return total;
    }
};

/// Buffered writer for blocking I/O (replacement for Stream.Writer)
pub const BufferedWriter = struct {
    stream: net.Stream,
    io_writer: Io.Writer,

    pub fn init(stream: net.Stream, buffer: []u8) BufferedWriter {
        return .{
            .stream = stream,
            .io_writer = .{
                .vtable = &vtable,
                .buffer = buffer,
                .seek = 0,
            },
        };
    }

    pub fn writer(self: *BufferedWriter) *Io.Writer {
        return &self.io_writer;
    }

    const vtable = Io.Writer.VTable{
        .stream = streamFn,
        .flush = flushFn,
    };

    fn streamFn(w: *Io.Writer, r: *Io.Reader, limit: Io.Limit) anyerror!usize {
        const self: *BufferedWriter = @fieldParentPtr("io_writer", w);
        _ = r;

        // Write buffered data first if any
        if (w.seek > 0) {
            var written: usize = 0;
            while (written < w.seek) {
                const n = posix.write(self.stream.socket.handle, w.buffer[written..w.seek]) catch |err| {
                    w.seek -= written;
                    return if (written > 0) written else err;
                };
                if (n == 0) return error.ConnectionClosed;
                written += n;
            }
            w.seek = 0;
        }

        // Write directly from the limit if it fits
        const max_write = limit.minInt(w.buffer.len);
        if (max_write == 0) return 0;

        const n = posix.write(self.stream.socket.handle, w.buffer[0..max_write]) catch |err| {
            return err;
        };
        return n;
    }

    fn flushFn(w: *Io.Writer) anyerror!void {
        const self: *BufferedWriter = @fieldParentPtr("io_writer", w);

        if (w.seek == 0) return;

        var written: usize = 0;
        while (written < w.seek) {
            const n = posix.write(self.stream.socket.handle, w.buffer[written..w.seek]) catch |err| {
                w.seek -= written;
                return err;
            };
            if (n == 0) return error.ConnectionClosed;
            written += n;
        }
        w.seek = 0;
    }
};

/// Connect to a TCP host by name (replacement for std.net.tcpConnectToHost)
/// This is a blocking synchronous DNS resolution and connection.
pub fn tcpConnectToHost(allocator: std.mem.Allocator, host: []const u8, port: u16) !net.Stream {
    // Use getaddrinfo to resolve hostname
    var hints: std.c.addrinfo = undefined;
    @memset(std.mem.asBytes(&hints), 0);
    hints.flags = @bitCast(std.c.AI{ .ADDRCONFIG = true });
    hints.family = std.c.AF.UNSPEC; // Allow IPv4 or IPv6
    hints.socktype = std.c.SOCK.STREAM;
    hints.protocol = std.c.IPPROTO.TCP;

    // Convert port to string for getaddrinfo
    var port_buf: [6]u8 = undefined;
    const port_str = std.fmt.bufPrint(&port_buf, "{d}", .{port}) catch unreachable;

    // Need null-terminated strings for getaddrinfo
    const host_z = try allocator.dupeZ(u8, host);
    defer allocator.free(host_z);

    const port_z = try allocator.dupeZ(u8, port_str);
    defer allocator.free(port_z);

    var res: ?*std.c.addrinfo = null;
    const rc = std.c.getaddrinfo(host_z.ptr, port_z.ptr, &hints, &res);
    if (@intFromEnum(rc) != 0) {
        return error.UnknownHostName;
    }
    const res_nn = res orelse return error.UnknownHostName;
    defer std.c.freeaddrinfo(res_nn);

    // Try each address until one succeeds
    var addr = res;
    while (addr) |ai| : (addr = ai.next) {
        // Create socket
        const sock = posix.socket(
            @intCast(ai.family),
            @intCast(ai.socktype),
            @intCast(ai.protocol),
        ) catch continue;
        errdefer posix.close(sock);

        // Try to connect
        posix.connect(
            sock,
            ai.addr.?,
            ai.addrlen,
        ) catch {
            posix.close(sock);
            continue;
        };

        // Success! Create a Stream wrapper
        // We need to construct a fake address since we can't easily extract it
        // For most HTTP client purposes, this doesn't matter
        return net.Stream{
            .socket = .{
                .handle = sock,
                .address = .{ .ip4 = .{
                    .bytes = .{ 0, 0, 0, 0 },
                    .port = port,
                } },
            },
        };
    }

    return error.ConnectionRefused;
}
