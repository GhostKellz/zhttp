// Compatibility helpers for Zig 0.16 API changes
const std = @import("std");
const Io = std.Io;
const net = Io.net;
const posix = std.posix;
const linux = std.os.linux;

/// Create a socket (posix.socket was removed in Zig 0.16)
pub const SocketError = error{
    AccessDenied,
    AddressFamilyUnsupported,
    ProtocolFamilyNotAvailable,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    SystemResources,
    ProtocolNotSupported,
    SocketTypeNotSupported,
    Unexpected,
};

pub fn socket(domain: u32, socket_type: u32, protocol: u32) SocketError!posix.socket_t {
    const rc = linux.socket(domain, socket_type, protocol);
    return switch (linux.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .ACCES => error.AccessDenied,
        .AFNOSUPPORT => error.AddressFamilyUnsupported,
        .INVAL => error.ProtocolFamilyNotAvailable,
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        .NOBUFS => error.SystemResources,
        .NOMEM => error.SystemResources,
        .PROTONOSUPPORT => error.ProtocolNotSupported,
        else => error.Unexpected,
    };
}

/// Write to a file descriptor (posix.write was removed in Zig 0.16)
pub const WriteError = error{
    AccessDenied,
    BrokenPipe,
    SystemResources,
    Unexpected,
    WouldBlock,
    InvalidArgument,
};

pub fn write(fd: posix.fd_t, buf: []const u8) WriteError!usize {
    const rc = linux.write(fd, buf.ptr, buf.len);
    return switch (linux.errno(rc)) {
        .SUCCESS => rc,
        .ACCES => error.AccessDenied,
        .PIPE => error.BrokenPipe,
        .NOSPC, .DQUOT, .FBIG => error.SystemResources,
        .AGAIN => error.WouldBlock,
        .INVAL => error.InvalidArgument,
        .IO, .FAULT, .NXIO, .SPIPE => error.Unexpected,
        else => error.Unexpected,
    };
}

/// Sleep for a given number of nanoseconds (posix.nanosleep was removed in Zig 0.16)
pub fn nanosleep(seconds: i64, nanoseconds: i64) void {
    const ts = linux.timespec{
        .sec = seconds,
        .nsec = nanoseconds,
    };
    _ = linux.nanosleep(&ts, null);
}

/// Create a file for writing (std.fs.cwd().createFile was removed in Zig 0.16)
pub const CreateFileError = error{
    AccessDenied,
    FileNotFound,
    SystemResources,
    PathTooLong,
    Unexpected,
};

pub const FileHandle = struct {
    fd: posix.fd_t,

    pub fn close(self: FileHandle) void {
        posix.close(self.fd);
    }

    pub fn writeAll(self: FileHandle, data: []const u8) !void {
        var index: usize = 0;
        while (index < data.len) {
            const written = try write(self.fd, data[index..]);
            if (written == 0) return error.Unexpected;
            index += written;
        }
    }
};

pub fn createFile(path: []const u8) CreateFileError!FileHandle {
    var path_buf: [posix.PATH_MAX]u8 = undefined;
    if (path.len >= path_buf.len) return error.PathTooLong;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;

    const flags: linux.O = .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .TRUNC = true,
    };
    const rc = linux.openat(linux.AT.FDCWD, path_buf[0..path.len :0], flags, 0o644);
    return switch (linux.errno(rc)) {
        .SUCCESS => .{ .fd = @intCast(rc) },
        .ACCES, .PERM => error.AccessDenied,
        .NOENT => error.FileNotFound,
        .NOMEM, .NFILE, .MFILE => error.SystemResources,
        .NAMETOOLONG => error.PathTooLong,
        else => error.Unexpected,
    };
}

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
        const written = try write(stream.socket.handle, bytes[index..]);
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

    fn streamFn(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.Error!usize {
        const self: *BufferedReader = @fieldParentPtr("io_reader", r);
        _ = w;

        // Read directly from socket
        const max_read = limit.minInt(r.buffer.len);
        if (max_read == 0) return 0;

        const n = posix.read(self.stream.socket.handle, r.buffer[0..max_read]) catch {
            return error.ReadFailed;
        };
        r.end = n;
        r.seek = 0;
        return n;
    }

    fn discardFn(r: *Io.Reader, limit: Io.Limit) Io.Reader.Error!usize {
        const self: *BufferedReader = @fieldParentPtr("io_reader", r);
        var total: usize = 0;
        var remaining = limit.toInt() orelse std.math.maxInt(usize);

        var discard_buf: [4096]u8 = undefined;
        while (remaining > 0) {
            const to_read = @min(remaining, discard_buf.len);
            const n = posix.read(self.stream.socket.handle, discard_buf[0..to_read]) catch {
                return if (total > 0) total else error.ReadFailed;
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
                .end = 0,
            },
        };
    }

    pub fn writer(self: *BufferedWriter) *Io.Writer {
        return &self.io_writer;
    }

    const vtable = Io.Writer.VTable{
        .drain = drainFn,
        .flush = flushFn,
    };

    fn drainFn(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const self: *BufferedWriter = @fieldParentPtr("io_writer", w);

        // First flush any buffered data
        if (w.end > 0) {
            var written: usize = 0;
            while (written < w.end) {
                const n = write(self.stream.socket.handle, w.buffer[written..w.end]) catch {
                    return error.WriteFailed;
                };
                if (n == 0) return error.WriteFailed;
                written += n;
            }
            w.end = 0;
        }

        // Then write the provided data
        var total: usize = 0;
        for (data) |slice| {
            var written: usize = 0;
            while (written < slice.len) {
                const n = write(self.stream.socket.handle, slice[written..]) catch {
                    return error.WriteFailed;
                };
                if (n == 0) return error.WriteFailed;
                written += n;
                total += n;
            }
        }

        // Handle splat if needed
        if (splat > 0 and data.len > 0) {
            const last_slice = data[data.len - 1];
            var i: usize = 0;
            while (i < splat) : (i += 1) {
                var written: usize = 0;
                while (written < last_slice.len) {
                    const n = write(self.stream.socket.handle, last_slice[written..]) catch {
                        return error.WriteFailed;
                    };
                    if (n == 0) return error.WriteFailed;
                    written += n;
                }
            }
        }

        return total;
    }

    fn flushFn(w: *Io.Writer) Io.Writer.Error!void {
        const self: *BufferedWriter = @fieldParentPtr("io_writer", w);

        if (w.end == 0) return;

        var written: usize = 0;
        while (written < w.end) {
            const n = write(self.stream.socket.handle, w.buffer[written..w.end]) catch {
                return error.WriteFailed;
            };
            if (n == 0) return error.WriteFailed;
            written += n;
        }
        w.end = 0;
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
        const sock = socket(
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
