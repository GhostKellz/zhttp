const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const Io = std.Io;
const net = Io.net;
const crypto = std.crypto;
const compat = @import("compat.zig");
const Method = @import("method.zig").Method;
const Request = @import("request.zig").Request;
const RequestBuilder = @import("request.zig").RequestBuilder;
const Response = @import("response.zig").Response;
const Header = @import("header.zig");
const Body = @import("body.zig").Body;
const BodyReader = @import("body.zig").BodyReader;
const Http1 = @import("http1.zig").Http1;
const ChunkedReaderGen = @import("http1.zig").ChunkedReader;
const Error = @import("error.zig").Error;

// Import homebrew async runtime
const AsyncRuntime = @import("async_runtime.zig");
const EventLoop = AsyncRuntime.EventLoop;
const AsyncIO = AsyncRuntime.AsyncIO;

/// Async HTTP client configuration
pub const AsyncClientOptions = struct {
    /// Connection timeout in milliseconds
    connect_timeout: u64 = 10000,
    /// Read timeout in milliseconds
    read_timeout: u64 = 30000,
    /// Write timeout in milliseconds
    write_timeout: u64 = 30000,
    /// Maximum redirects to follow
    max_redirects: u8 = 10,
    /// Maximum retry attempts
    max_retries: u8 = 3,
    /// User agent string
    user_agent: []const u8 = "zhttp-async/0.1.1",
    /// Enable automatic decompression
    auto_decompress: bool = true,
    /// Maximum response body size
    max_body_size: usize = 10 * 1024 * 1024, // 10MB
    /// Connection pool settings
    pool: PoolOptions = PoolOptions{},
    /// TLS settings
    tls: TlsOptions = TlsOptions{},
    
    pub const PoolOptions = struct {
        /// Maximum connections per host
        max_per_host: u32 = 10,
        /// Maximum total connections
        max_total: u32 = 100,
        /// Idle timeout in milliseconds
        idle_timeout: u64 = 90000,
    };
    
    pub const TlsOptions = struct {
        /// Enable certificate verification
        verify_certificates: bool = true,
        /// Custom CA certificates
        ca_bundle: ?[]const u8 = null,
        /// Certificate pinning (SPKI SHA-256 hashes)
        pinned_certificates: ?[]const []const u8 = null,
        /// Minimum TLS version
        min_version: TlsVersion = .tls_1_2,
        /// ALPN protocols
        alpn_protocols: []const []const u8 = &.{ "h2", "http/1.1" },
        
        pub const TlsVersion = enum {
            tls_1_0,
            tls_1_1,
            tls_1_2,
            tls_1_3,
        };
    };
};

/// Async HTTP client with homebrew async runtime
pub const AsyncClient = if (!build_options.enable_async) struct {
    // Provide a stub implementation when async is disabled
    pub fn init(allocator: std.mem.Allocator, options: AsyncClientOptions) @This() {
        _ = allocator;
        _ = options;
        return @This(){};
    }
    
    pub fn deinit(self: *@This()) void {
        _ = self;
    }
    
    pub fn send(self: *@This(), event_loop: *EventLoop, request: Request) !Response {
        _ = self;
        _ = event_loop;
        _ = request;
        return Error.AsyncNotEnabled;
    }
} else struct {
    allocator: std.mem.Allocator,
    options: AsyncClientOptions,
    pool: AsyncConnectionPool,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, options: AsyncClientOptions) Self {
        return Self{
            .allocator = allocator,
            .options = options,
            .pool = AsyncConnectionPool.init(allocator, options.pool),
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.pool.deinit();
    }
    
    /// Send HTTP request asynchronously using homebrew runtime
    pub fn send(self: *Self, event_loop: *EventLoop, request: Request) !Response {
        return self.sendWithRetries(event_loop, request, 0);
    }

    /// Send with retry logic
    fn sendWithRetries(self: *Self, event_loop: *EventLoop, request: Request, retry_count: u8) !Response {
        if (retry_count >= self.options.max_retries) {
            return Error.DeadlineExceeded;
        }

        const result = self.sendWithRedirects(event_loop, request, 0);

        if (result) |response| {
            return response;
        } else |err| switch (err) {
            // Retry on certain errors
            Error.ConnectTimeout,
            Error.ReadTimeout,
            Error.WriteTimeout,
            Error.ConnectionRefused,
            Error.ConnectionReset,
            Error.NetworkUnreachable,
            Error.SystemResources => {
                // Exponential backoff using async timer
                if (retry_count > 0) {
                    const delay_ms = std.math.pow(u64, 2, retry_count) * 1000; // 2^retry * 1s
                    // Schedule timer for backoff delay
                    _ = try event_loop.scheduleTimer(delay_ms, struct {
                        fn callback(timer: *AsyncRuntime.Timer) void {
                            _ = timer;
                        }
                    }.callback);
                }
                return self.sendWithRetries(event_loop, request, retry_count + 1);
            },
            else => return err,
        }
    }

    fn sendWithRedirects(self: *Self, event_loop: *EventLoop, request: Request, redirect_count: u8) !Response {
        if (redirect_count >= self.options.max_redirects) {
            return Error.TooManyRedirects;
        }
        
        const url_components = try request.parseUrl(self.allocator);
        
        // Get or create async connection
        const conn = try self.pool.getConnection(url_components.scheme, url_components.host, url_components.port);
        defer self.pool.releaseConnection(conn);

        // Send request and receive response asynchronously
        var response = try self.sendOnConnection(event_loop, conn, request, url_components);
        
        // Handle redirects
        if (response.isRedirect()) {
            if (response.location()) |location_url| {
                defer response.deinit();
                
                // Check for redirect loops
                if (std.mem.eql(u8, request.url, location_url)) {
                    return Error.RedirectLoopDetected;
                }
                
                // Create new request for redirect
                var redirect_request = Request.init(self.allocator, request.method, location_url);
                defer redirect_request.deinit();
                
                // Handle method changes on redirect
                const should_preserve_method = response.status == 307 or response.status == 308;
                if (!should_preserve_method and (request.method == .POST or request.method == .PUT or request.method == .PATCH)) {
                    redirect_request.method = .GET;
                    redirect_request.body = Body.empty();
                } else {
                    redirect_request.body = request.body;
                }
                
                // Copy headers (except host-specific ones)
                for (request.headers.items()) |header| {
                    if (!std.mem.eql(u8, header.name, "host") and 
                        !std.mem.eql(u8, header.name, "Host") and
                        !std.mem.eql(u8, header.name, "authorization") and
                        !std.mem.eql(u8, header.name, "Authorization")) {
                        try redirect_request.addHeader(header.name, header.value);
                    }
                }
                
                return self.sendWithRedirects(event_loop, redirect_request, redirect_count + 1);
            }
        }
        
        return response;
    }
    
    /// Send request on async connection
    fn sendOnConnection(self: *Self, event_loop: *EventLoop, conn: *AsyncConnection, request: Request, url_components: @import("request.zig").UrlComponents) !Response {
        // Ensure connection is established
        if (!conn.isConnected()) {
            try conn.connect(self.allocator, url_components.scheme, url_components.host, url_components.port, self.options);
        }

        // Write request asynchronously
        try self.writeRequestToConnection(event_loop, conn, request, url_components);

        // Read response asynchronously
        return self.readResponse(event_loop, conn);
    }

    /// Write HTTP request to async connection
    fn writeRequestToConnection(self: *Self, event_loop: *EventLoop, conn: *AsyncConnection, request: Request, url_components: @import("request.zig").UrlComponents) !void {
        
        var request_buffer: std.ArrayList(u8) = .{};
        defer request_buffer.deinit(self.allocator);
        
        // Build request line
        const request_line = try url_components.buildRequestLine(self.allocator);
        defer self.allocator.free(request_line);
        
        const request_line_str = try std.fmt.allocPrint(self.allocator, "{s} {s} HTTP/1.1\r\n", .{ request.method.toString(), request_line });
        defer self.allocator.free(request_line_str);
        try request_buffer.appendSlice(self.allocator, request_line_str);
        
        // Ensure Host header is set
        if (!request.headers.has(Header.common.HOST)) {
            const host_header = if (url_components.port == 80 or url_components.port == 443)
                try std.fmt.allocPrint(self.allocator, "Host: {s}\r\n", .{url_components.host})
            else
                try std.fmt.allocPrint(self.allocator, "Host: {s}:{d}\r\n", .{ url_components.host, url_components.port });
            defer self.allocator.free(host_header);
            try request_buffer.appendSlice(self.allocator, host_header);
        }
        
        // Add Connection: close header
        const connection_header = "Connection: close\r\n";
        try request_buffer.appendSlice(self.allocator, connection_header);
        
        // Write headers
        for (request.headers.items()) |header| {
            const header_line = try std.fmt.allocPrint(self.allocator, "{s}: {s}\r\n", .{ header.name, header.value });
            defer self.allocator.free(header_line);
            try request_buffer.appendSlice(self.allocator, header_line);
        }
        
        // Set Content-Length if we have a body with known length
        if (!request.body.isEmpty() and !request.headers.has(Header.common.CONTENT_LENGTH)) {
            if (request.body.contentLength()) |length| {
                const content_length_header = try std.fmt.allocPrint(self.allocator, "Content-Length: {d}\r\n", .{length});
                defer self.allocator.free(content_length_header);
                try request_buffer.appendSlice(self.allocator, content_length_header);
            }
        }
        
        // End headers
        try request_buffer.appendSlice(self.allocator, "\r\n");
        
        // Write headers asynchronously
        try conn.writeAll(event_loop, request_buffer.items);

        // Write body if present
        if (!request.body.isEmpty()) {
            var body_reader = BodyReader.init(self.allocator, request.body);
            defer body_reader.deinit();

            var body_buffer: [8192]u8 = undefined;
            while (true) {
                const bytes_read = try body_reader.read(&body_buffer);
                if (bytes_read == 0) break;

                try conn.writeAll(event_loop, body_buffer[0..bytes_read]);
            }
        }

        // Flush the connection
        try conn.flush(event_loop);
    }

    /// Read HTTP response asynchronously
    fn readResponse(self: *Self, event_loop: *EventLoop, conn: *AsyncConnection) !Response {
        // Read entire response for simplicity (could be optimized for streaming)
        var response_buffer: [8192]u8 = undefined;
        const bytes_read = try conn.readAll(event_loop, &response_buffer);
        if (bytes_read == 0) return error.EndOfStream;
        
        const response_data = response_buffer[0..bytes_read];
        
        // Parse the response data
        return self.parseHttpResponseFromData(response_data);
    }
    
    /// Parse HTTP response from raw data
    fn parseHttpResponseFromData(self: *Self, data: []const u8) !Response {
        var line_iter = std.mem.splitSequence(u8, data, "\r\n");
        
        // Parse status line
        const status_line_str = line_iter.next() orelse return error.InvalidResponse;
        const status_line = try Http1.parseStatusLine(status_line_str);
        
        // Create response with owned reason string
        const owned_reason = try self.allocator.dupe(u8, status_line.reason);
        var response = Response.init(self.allocator, status_line.status, owned_reason, status_line.version);
        response.setOwnedReason(owned_reason);
        
        // Parse headers
        while (line_iter.next()) |line| {
            if (line.len == 0) break;
            
            const header = try Http1.parseHeaderLine(line);
            const owned_name = try self.allocator.dupe(u8, header.name);
            const owned_value = try self.allocator.dupe(u8, header.value);
            try response.headers.appendOwned(owned_name, owned_value);
        }
        
        // Find body start
        const headers_end = std.mem.indexOf(u8, data, "\r\n\r\n") orelse return error.InvalidResponse;
        const body_start = headers_end + 4;
        
        if (body_start < data.len) {
            const body_data = data[body_start..];
            const owned_body_data = try self.allocator.dupe(u8, body_data);
            response.setBody(Body.fromOwnedString(owned_body_data));
        }
        
        return response;
    }
};

/// Async connection pool
const AsyncConnectionPool = struct {
    allocator: std.mem.Allocator,
    options: AsyncClientOptions.PoolOptions,
    connections: std.HashMap(ConnectionKey, std.ArrayListUnmanaged(*AsyncConnection), ConnectionKeyContext, std.hash_map.default_max_load_percentage),
    mutex: std.Thread.Mutex,
    
    const ConnectionKey = struct {
        scheme: []const u8,
        host: []const u8,
        port: u16,
    };
    
    const ConnectionKeyContext = struct {
        pub fn hash(self: @This(), key: ConnectionKey) u64 {
            _ = self;
            var hasher = std.hash.Wyhash.init(0);
            hasher.update(key.scheme);
            hasher.update(":");
            hasher.update(key.host);
            hasher.update(":");
            hasher.update(std.mem.asBytes(&key.port));
            return hasher.final();
        }
        
        pub fn eql(self: @This(), a: ConnectionKey, b: ConnectionKey) bool {
            _ = self;
            return std.mem.eql(u8, a.scheme, b.scheme) and
                   std.mem.eql(u8, a.host, b.host) and
                   a.port == b.port;
        }
    };
    
    fn init(allocator: std.mem.Allocator, options: AsyncClientOptions.PoolOptions) AsyncConnectionPool {
        return AsyncConnectionPool{
            .allocator = allocator,
            .options = options,
            .connections = std.HashMap(ConnectionKey, std.ArrayListUnmanaged(*AsyncConnection), ConnectionKeyContext, std.hash_map.default_max_load_percentage).init(allocator),
            .mutex = std.Thread.Mutex{},
        };
    }
    
    fn deinit(self: *AsyncConnectionPool) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        var iterator = self.connections.iterator();
        while (iterator.next()) |entry| {
            for (entry.value_ptr.items) |conn| {
                conn.deinit();
                self.allocator.destroy(conn);
            }
            entry.value_ptr.deinit(self.allocator);
        }
        self.connections.deinit();
    }
    
    fn getConnection(self: *AsyncConnectionPool, scheme: []const u8, host: []const u8, port: u16) !*AsyncConnection {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        const key = ConnectionKey{ .scheme = scheme, .host = host, .port = port };
        
        if (self.connections.getPtr(key)) |conn_list| {
            if (conn_list.items.len > 0) {
                if (conn_list.pop()) |conn| {
                    return conn;
                }
            }
        }
        
        // Create new async connection
        const conn = try self.allocator.create(AsyncConnection);
        conn.* = try AsyncConnection.init(self.allocator);
        
        // Store owned copies of the connection key strings
        const owned_scheme = try self.allocator.dupe(u8, scheme);
        const owned_host = try self.allocator.dupe(u8, host);
        conn.pool_key = ConnectionKey{
            .scheme = owned_scheme,
            .host = owned_host,
            .port = port,
        };
        
        return conn;
    }
    
    fn releaseConnection(self: *AsyncConnectionPool, conn: *AsyncConnection) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (!conn.isConnected() or conn.pool_key == null) {
            conn.deinit();
            self.allocator.destroy(conn);
            return;
        }
        
        conn.last_used = compat.milliTimestamp();
        
        const key = conn.pool_key.?;
        
        const result = self.connections.getOrPut(key) catch {
            conn.deinit();
            self.allocator.destroy(conn);
            return;
        };
        
        if (!result.found_existing) {
            result.value_ptr.* = std.ArrayListUnmanaged(*AsyncConnection){};
        }
        
        if (result.value_ptr.items.len >= self.options.max_per_host) {
            if (result.value_ptr.items.len > 0) {
                const oldest = result.value_ptr.orderedRemove(0);
                oldest.deinit();
                self.allocator.destroy(oldest);
            }
        }
        
        result.value_ptr.append(self.allocator, conn) catch {
            conn.deinit();
            self.allocator.destroy(conn);
        };
    }
};

/// Async connection using homebrew async runtime
const AsyncConnection = struct {
    stream: ?net.Stream,
    is_tls: bool,
    tls_client: ?std.crypto.tls.Client,
    connected: bool,
    last_used: i64,
    allocator: std.mem.Allocator,
    pool_key: ?AsyncConnectionPool.ConnectionKey,
    
    fn init(allocator: std.mem.Allocator) !AsyncConnection {
        return AsyncConnection{
            .stream = null,
            .is_tls = false,
            .tls_client = null,
            .connected = false,
            .last_used = compat.milliTimestamp(),
            .allocator = allocator,
            .pool_key = null,
        };
    }
    
    fn isConnected(self: AsyncConnection) bool {
        return self.connected and self.stream != null;
    }
    
    fn deinit(self: *AsyncConnection) void {
        if (self.pool_key) |key| {
            self.allocator.free(key.scheme);
            self.allocator.free(key.host);
        }
        
        if (self.stream) |stream| {
            compat.closeStream(stream);
        }
    }
    
    fn connect(self: *AsyncConnection, allocator: std.mem.Allocator, scheme: []const u8, host: []const u8, port: u16, options: AsyncClientOptions) !void {
        if (self.isConnected()) return;
        
        // For now, use basic connection (could be enhanced with async DNS resolution)
        self.stream = try compat.tcpConnectToHost(allocator, host, port);
        
        if (std.mem.eql(u8, scheme, "https")) {
            try self.initTls(host, options.tls);
        }
        
        self.connected = true;
        self.last_used = compat.milliTimestamp();
    }
    
    fn initTls(self: *AsyncConnection, host: []const u8, tls_options: AsyncClientOptions.TlsOptions) !void {
        _ = host;
        _ = tls_options;
        // TODO: Implement async TLS using homebrew runtime
        // For now, this is a placeholder
        self.is_tls = true;
    }

    /// Write data asynchronously
    fn writeAll(self: *AsyncConnection, event_loop: *EventLoop, data: []const u8) !void {
        // For now use synchronous write - can be improved with event loop integration
        _ = event_loop;
        if (self.stream) |stream| {
            try compat.writeAll(stream, data);
        } else {
            return error.NotConnected;
        }
    }

    /// Read data asynchronously
    fn readAll(self: *AsyncConnection, event_loop: *EventLoop, buffer: []u8) !usize {
        // For now use synchronous read - can be improved with event loop integration
        _ = event_loop;
        if (self.stream) |stream| {
            return try std.posix.read(stream.socket.handle, buffer);
        } else {
            return error.NotConnected;
        }
    }

    /// Flush connection asynchronously
    fn flush(self: *AsyncConnection, event_loop: *EventLoop) !void {
        // For now use synchronous flush - can be improved with event loop integration
        _ = self;
        _ = event_loop;
        // No-op for TCP streams
    }
};

/// Convenience async functions using homebrew runtime
pub fn getAsync(allocator: std.mem.Allocator, event_loop: *EventLoop, url: []const u8) !Response {
    if (!build_options.enable_async) return Error.AsyncNotEnabled;

    var client = AsyncClient.init(allocator, AsyncClientOptions{});
    defer client.deinit();

    var request = Request.init(allocator, .GET, url);
    defer request.deinit();

    return client.send(event_loop, request);
}

/// Convenience async POST function
pub fn postAsync(allocator: std.mem.Allocator, event_loop: *EventLoop, url: []const u8, body: Body) !Response {
    if (!build_options.enable_async) return Error.AsyncNotEnabled;

    var client = AsyncClient.init(allocator, AsyncClientOptions{});
    defer client.deinit();

    var request = Request.init(allocator, .POST, url);
    defer request.deinit();
    request.setBody(body);

    return client.send(event_loop, request);
}

test "async client stub" {
    if (build_options.enable_async) {
        // Test async functionality when enabled
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();

        var client = AsyncClient.init(allocator, AsyncClientOptions{});
        defer client.deinit();

        // This would require an EventLoop instance to test properly
        // try std.testing.expect(@TypeOf(client) == AsyncClient);
    } else {
        // Test stub functionality
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();

        var client = AsyncClient.init(allocator, AsyncClientOptions{});
        defer client.deinit();

        try std.testing.expect(@TypeOf(client) == AsyncClient);
    }
}