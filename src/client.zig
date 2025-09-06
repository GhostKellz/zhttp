const std = @import("std");
const net = std.net;
const crypto = std.crypto;
const Method = @import("method.zig").Method;
const Request = @import("request.zig").Request;
const RequestBuilder = @import("request.zig").RequestBuilder;
const Response = @import("response.zig").Response;
const Header = @import("header.zig");
const Body = @import("body.zig").Body;
const BodyReader = @import("body.zig").BodyReader;
const Http1 = @import("http1.zig").Http1;
const Error = @import("error.zig").Error;

/// HTTP client configuration
pub const ClientOptions = struct {
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
    user_agent: []const u8 = "zhttp/0.1.0",
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

/// HTTP client with connection pooling
pub const Client = struct {
    allocator: std.mem.Allocator,
    options: ClientOptions,
    pool: ConnectionPool,
    
    pub fn init(allocator: std.mem.Allocator, options: ClientOptions) Client {
        return Client{
            .allocator = allocator,
            .options = options,
            .pool = ConnectionPool.init(allocator, options.pool),
        };
    }
    
    pub fn deinit(self: *Client) void {
        self.pool.deinit();
    }
    
    /// Send HTTP request with redirect support
    pub fn send(self: *Client, request: Request) !Response {
        return self.sendWithRedirects(request, 0);
    }
    
    fn sendWithRedirects(self: *Client, request: Request, redirect_count: u8) !Response {
        if (redirect_count >= self.options.max_redirects) {
            return Error.TooManyRedirects;
        }
        
        const url_components = try request.parseUrl(self.allocator);
        
        // Get or create connection
        const conn = try self.pool.getConnection(url_components.scheme, url_components.host, url_components.port);
        defer self.pool.releaseConnection(conn);
        
        // Send request and receive response
        var response = try self.sendOnConnection(conn, request, url_components);
        
        // Handle redirects
        if (response.isRedirect()) {
            if (response.location()) |location_url| {
                defer response.deinit();
                
                // Check for redirect loops by comparing with original URL
                if (std.mem.eql(u8, request.url, location_url)) {
                    return Error.RedirectLoopDetected;
                }
                
                // Create new request for redirect
                var redirect_request = Request.init(self.allocator, request.method, location_url);
                defer redirect_request.deinit();
                
                // For POST/PUT requests, change method to GET on redirect (except 307/308)
                const should_preserve_method = response.status == 307 or response.status == 308;
                if (!should_preserve_method and (request.method == .POST or request.method == .PUT or request.method == .PATCH)) {
                    redirect_request.method = .GET;
                    // Clear body for method change
                    redirect_request.body = Body.empty();
                } else {
                    // Copy body for 307/308 redirects
                    redirect_request.body = request.body;
                }
                
                // Copy relevant headers (except host-specific ones)
                for (request.headers.headers.items) |header| {
                    // Skip host and authorization headers on redirect for security
                    if (!std.mem.eql(u8, header.name, "host") and 
                        !std.mem.eql(u8, header.name, "Host") and
                        !std.mem.eql(u8, header.name, "authorization") and
                        !std.mem.eql(u8, header.name, "Authorization")) {
                        try redirect_request.addHeader(header.name, header.value);
                    }
                }
                
                return self.sendWithRedirects(redirect_request, redirect_count + 1);
            }
        }
        
        return response;
    }
    
    /// Send request on specific connection
    fn sendOnConnection(self: *Client, conn: *Connection, request: Request, url_components: @import("request.zig").UrlComponents) !Response {
        // Ensure connection is established
        if (!conn.isConnected()) {
            try conn.connect(self.allocator, url_components.scheme, url_components.host, url_components.port, self.options);
        }
        
        // Write request directly to connection
        try writeRequestToConnection(conn, request, url_components);
        
        
        // Read response
        return self.readResponse(conn);
    }
    
    /// Read HTTP response from connection
    fn readResponse(self: *Client, conn: *Connection) !Response {
        // Read status line directly from stream
        var line_buffer: [1024]u8 = undefined;
        std.log.info("Reading status line from connection...", .{});
        const status_line_str = try readLineFromConnection(conn, &line_buffer);
        std.log.info("Got status line: {s}", .{status_line_str});
        const status_line = try Http1.parseStatusLine(status_line_str);
        
        // Create response
        var response = Response.init(self.allocator, status_line.status, status_line.reason, status_line.version);
        
        // Read headers
        while (true) {
            const line = try readLineFromConnection(conn, &line_buffer);
            if (line.len == 0) break; // Empty line ends headers
            
            const header = try Http1.parseHeaderLine(line);
            try response.addHeader(header.name, header.value);
        }
        
        // Read the entire body into memory since the stream will be closed
        const body = try self.readResponseBodyFromConnection(conn, response.headers);
        response.setBody(body);
        
        return response;
    }
    
    /// Read response body from connection into memory
    fn readResponseBodyFromConnection(self: *Client, conn: *Connection, headers: Header.HeaderMap) !Body {
        if (Http1.isChunkedEncoding(headers)) {
            // Read chunked body
            return self.readChunkedBodyFromConnection(conn);
        } else if (Http1.getContentLength(headers)) |content_length| {
            // Read body with known length
            return self.readFixedLengthBodyFromConnection(conn, content_length);
        } else {
            // Read until connection close
            return self.readUntilCloseFromConnection(conn);
        }
    }
    
    /// Read body with known content length
    fn readFixedLengthBodyFromConnection(self: *Client, conn: *Connection, content_length: u64) !Body {
        const body_data = try self.allocator.alloc(u8, content_length);
        errdefer self.allocator.free(body_data);
        
        var total_read: usize = 0;
        while (total_read < content_length) {
            const bytes_read = try conn.read(body_data[total_read..]);
            if (bytes_read == 0) break; // Connection closed
            total_read += bytes_read;
        }
        
        if (total_read != content_length) {
            self.allocator.free(body_data);
            return error.IncompleteBody;
        }
        
        return Body.fromString(body_data);
    }
    
    /// Read body until connection closes
    fn readUntilCloseFromConnection(self: *Client, conn: *Connection) !Body {
        var body_data = std.ArrayList(u8){};
        defer body_data.deinit(self.allocator);
        
        var buffer: [4096]u8 = undefined;
        while (true) {
            const bytes_read = try conn.read(&buffer);
            if (bytes_read == 0) break; // Connection closed
            try body_data.appendSlice(self.allocator, buffer[0..bytes_read]);
        }
        
        const owned_data = try body_data.toOwnedSlice(self.allocator);
        return Body.fromString(owned_data);
    }
    
    /// Read chunked body (simplified implementation)
    fn readChunkedBodyFromConnection(self: *Client, conn: *Connection) !Body {
        // For now, just read until close - proper chunked implementation would be more complex
        return self.readUntilCloseFromConnection(conn);
    }
    
    /// Create body reader based on response headers
    fn createBodyFromHeaders(self: *Client, reader: anytype, headers: Header.HeaderMap) !Body {
        _ = self;
        
        if (Http1.isChunkedEncoding(headers)) {
            // TODO: Implement chunked body reader
            var mutable_reader = reader;
            return Body{ .reader = mutable_reader.interface() };
        } else if (Http1.getContentLength(headers)) |content_length| {
            // TODO: Implement limited reader with content length
            _ = content_length;
            var mutable_reader = reader;
            return Body{ .reader = mutable_reader.interface() };
        } else {
            // Read until connection close
            var mutable_reader = reader;
            return Body{ .reader = mutable_reader.interface() };
        }
    }
};

/// Connection pool for reusing HTTP connections
const ConnectionPool = struct {
    allocator: std.mem.Allocator,
    options: ClientOptions.PoolOptions,
    connections: std.HashMap(ConnectionKey, std.ArrayList(*Connection), ConnectionKeyContext, std.hash_map.default_max_load_percentage),
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
    
    fn init(allocator: std.mem.Allocator, options: ClientOptions.PoolOptions) ConnectionPool {
        return ConnectionPool{
            .allocator = allocator,
            .options = options,
            .connections = std.HashMap(ConnectionKey, std.ArrayList(*Connection), ConnectionKeyContext, std.hash_map.default_max_load_percentage).init(allocator),
            .mutex = std.Thread.Mutex{},
        };
    }
    
    fn deinit(self: *ConnectionPool) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        var iterator = self.connections.iterator();
        while (iterator.next()) |entry| {
            for (entry.value_ptr.items) |conn| {
                conn.close();
                self.allocator.destroy(conn);
            }
            entry.value_ptr.deinit(self.allocator);
        }
        self.connections.deinit();
    }
    
    fn getConnection(self: *ConnectionPool, scheme: []const u8, host: []const u8, port: u16) !*Connection {
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
        
        // Create new connection
        const conn = try self.allocator.create(Connection);
        conn.* = Connection.init();
        return conn;
    }
    
    fn releaseConnection(self: *ConnectionPool, conn: *Connection) void {
        // TODO: Implement connection reuse logic
        // For now, just close the connection
        conn.close();
        self.allocator.destroy(conn);
    }
};

/// Individual HTTP connection
/// TLS wrapper that manages buffers and client together
const TlsConnection = struct {
    client: std.crypto.tls.Client,
    tls_read_buffer: []u8,
    tls_write_buffer: []u8,
    stream_read_buffer: []u8,
    stream_write_buffer: []u8,
    stream_writer: net.Stream.Writer,  // Store the stream writer used during init
    ca_bundle: ?crypto.Certificate.Bundle, // CA bundle for certificate verification
    allocator: std.mem.Allocator,
    
    fn deinit(self: *TlsConnection) void {
        self.allocator.free(self.tls_read_buffer);
        self.allocator.free(self.tls_write_buffer);
        self.allocator.free(self.stream_read_buffer);
        self.allocator.free(self.stream_write_buffer);
        if (self.ca_bundle) |*bundle| {
            bundle.deinit(self.allocator);
        }
    }
};

const Connection = struct {
    stream: ?net.Stream,
    tls: ?*TlsConnection,
    connected: bool,
    last_used: i64,
    is_tls: bool,
    
    fn init() Connection {
        return Connection{
            .stream = null,
            .tls = null,
            .connected = false,
            .last_used = std.time.milliTimestamp(),
            .is_tls = false,
        };
    }
    
    fn isConnected(self: Connection) bool {
        return self.connected and self.stream != null;
    }
    
    fn connect(self: *Connection, allocator: std.mem.Allocator, scheme: []const u8, host: []const u8, port: u16, options: ClientOptions) !void {
        if (self.isConnected()) return;
        
        // Connect to server with hostname resolution
        const stream = try net.tcpConnectToHost(allocator, host, port);
        
        if (std.mem.eql(u8, scheme, "https")) {
            // Initialize TLS client properly
            try self.initTlsConnection(allocator, stream, host, options.tls);
        } else {
            self.stream = stream;
            self.is_tls = false;
        }
        self.connected = true;
        self.last_used = std.time.milliTimestamp();
    }
    
    fn close(self: *Connection) void {
        if (self.tls) |tls_conn| {
            tls_conn.deinit();
            tls_conn.allocator.destroy(tls_conn);
            self.tls = null;
        }
        
        if (self.stream) |stream| {
            stream.close();
            self.stream = null;
        }
        
        self.connected = false;
        self.is_tls = false;
    }
    
    fn initTlsConnection(self: *Connection, allocator: std.mem.Allocator, stream: net.Stream, host: []const u8, tls_options: ClientOptions.TlsOptions) !void {
        // Store the stream
        self.stream = stream;
        
        // Allocate TLS connection structure
        const tls_conn = try allocator.create(TlsConnection);
        errdefer allocator.destroy(tls_conn);
        
        // Allocate separate buffers for TLS client and stream I/O
        const min_buf_len = std.crypto.tls.max_ciphertext_record_len;
        
        // TLS client buffers
        const tls_read_buffer = try allocator.alloc(u8, min_buf_len);
        errdefer allocator.free(tls_read_buffer);
        
        const tls_write_buffer = try allocator.alloc(u8, min_buf_len);
        errdefer allocator.free(tls_write_buffer);
        
        // Stream buffers (separate from TLS buffers)
        const stream_read_buffer = try allocator.alloc(u8, min_buf_len);
        errdefer allocator.free(stream_read_buffer);
        
        const stream_write_buffer = try allocator.alloc(u8, min_buf_len);  
        errdefer allocator.free(stream_write_buffer);
        
        // Create stream readers and writers using the stream buffers
        var stream_reader = stream.reader(stream_read_buffer);
        var stream_writer = stream.writer(stream_write_buffer);
        
        // Load CA bundle if certificate verification is enabled
        var ca_bundle_opt: ?crypto.Certificate.Bundle = null;
        if (tls_options.verify_certificates) {
            var ca_bundle = crypto.Certificate.Bundle{};
            try ca_bundle.rescan(allocator);
            ca_bundle_opt = ca_bundle;
        }
        errdefer if (ca_bundle_opt) |*bundle| bundle.deinit(allocator);
        
        // Initialize TLS client with proper options
        const tls_client_options = if (tls_options.verify_certificates) 
            crypto.tls.Client.Options{
                .host = .{ .explicit = host },
                .ca = .{ .bundle = ca_bundle_opt.? },
                .write_buffer = tls_write_buffer,
                .read_buffer = tls_read_buffer,
            }
        else 
            crypto.tls.Client.Options{
                .host = .no_verification,
                .ca = .no_verification,
                .write_buffer = tls_write_buffer,
                .read_buffer = tls_read_buffer,
            };
        
        // Initialize TLS client - handshake is performed automatically during init
        std.log.info("Initializing TLS handshake...", .{});
        const tls_client = try std.crypto.tls.Client.init(stream_reader.interface(), &stream_writer.interface, tls_client_options);
        std.log.info("TLS handshake completed successfully!", .{});
        
        // Set up the TLS connection structure
        tls_conn.* = TlsConnection{
            .client = tls_client,
            .tls_read_buffer = tls_read_buffer,
            .tls_write_buffer = tls_write_buffer,
            .stream_read_buffer = stream_read_buffer,
            .stream_write_buffer = stream_write_buffer,
            .stream_writer = stream_writer,  // Store the writer used during TLS init
            .ca_bundle = ca_bundle_opt,  // Store CA bundle for cleanup
            .allocator = allocator,
        };
        
        self.tls = tls_conn;
        self.is_tls = true;
    }
    
    fn read(self: *Connection, buffer: []u8) !usize {
        if (self.is_tls) {
            if (self.tls) |tls_conn| {
                std.log.info("Reading from TLS client...", .{});
                const bytes_read = tls_conn.client.reader.readSliceShort(buffer) catch |err| {
                    std.log.err("TLS read error: {}", .{err});
                    return err;
                };
                std.log.info("TLS read returned {} bytes", .{bytes_read});
                return bytes_read;
            }
        }
        return try self.stream.?.read(buffer);
    }
    
    fn writeAll(self: *Connection, bytes: []const u8) !void {
        if (self.is_tls) {
            if (self.tls) |tls_conn| {
                return try tls_conn.client.writer.writeAll(bytes);
            }
        }
        return try self.stream.?.writeAll(bytes);
    }
    
    fn flush(self: *Connection) !void {
        if (self.is_tls) {
            if (self.tls) |tls_conn| {
                try tls_conn.client.writer.flush();
                // Use the exact same stream writer that was used during TLS initialization
                try tls_conn.stream_writer.interface.flush();
            }
        }
    }
    
};

/// Write HTTP request to connection
fn writeRequestToConnection(conn: *Connection, request: Request, url_components: @import("request.zig").UrlComponents) !void {
    var request_buffer = std.ArrayList(u8){};
    defer request_buffer.deinit(std.heap.page_allocator);
    
    // Build request line
    const request_line = try url_components.buildRequestLine(std.heap.page_allocator);
    defer std.heap.page_allocator.free(request_line);
    
    const request_line_str = try std.fmt.allocPrint(std.heap.page_allocator, "{s} {s} HTTP/1.1\r\n", .{ request.method.toString(), request_line });
    defer std.heap.page_allocator.free(request_line_str);
    try request_buffer.appendSlice(std.heap.page_allocator, request_line_str);
    
    // Ensure Host header is set
    if (!request.headers.has(Header.common.HOST)) {
        const host_header = if (url_components.port == 80 or url_components.port == 443)
            try std.fmt.allocPrint(std.heap.page_allocator, "Host: {s}\r\n", .{url_components.host})
        else
            try std.fmt.allocPrint(std.heap.page_allocator, "Host: {s}:{d}\r\n", .{ url_components.host, url_components.port });
        defer std.heap.page_allocator.free(host_header);
        try request_buffer.appendSlice(std.heap.page_allocator, host_header);
    }
    
    // Add Connection: close header for HTTP/1.1
    const connection_header = "Connection: close\r\n";
    try request_buffer.appendSlice(std.heap.page_allocator, connection_header);
    
    // Write headers
    for (request.headers.items()) |header| {
        const header_line = try std.fmt.allocPrint(std.heap.page_allocator, "{s}: {s}\r\n", .{ header.name, header.value });
        defer std.heap.page_allocator.free(header_line);
        try request_buffer.appendSlice(std.heap.page_allocator, header_line);
    }
    
    // Set Content-Length if we have a body with known length
    if (!request.body.isEmpty() and !request.headers.has(Header.common.CONTENT_LENGTH)) {
        if (request.body.contentLength()) |length| {
            const content_length_header = try std.fmt.allocPrint(std.heap.page_allocator, "Content-Length: {d}\r\n", .{length});
            defer std.heap.page_allocator.free(content_length_header);
            try request_buffer.appendSlice(std.heap.page_allocator, content_length_header);
        }
    }
    
    // End headers
    try request_buffer.appendSlice(std.heap.page_allocator, "\r\n");
    
    // Write the complete headers in one call
    std.log.info("Sending HTTP request:\n{s}", .{request_buffer.items});
    try conn.writeAll(request_buffer.items);
    
    // Write body if present - do this separately as it might be large
    if (!request.body.isEmpty()) {
        var body_reader = BodyReader.init(std.heap.page_allocator, request.body);
        defer body_reader.deinit();
        
        var body_buffer: [8192]u8 = undefined;
        while (true) {
            const bytes_read = try body_reader.read(&body_buffer);
            if (bytes_read == 0) break;
            try conn.writeAll(body_buffer[0..bytes_read]);
        }
    }
    
    // For TLS connections, ensure both levels of flushing after complete request
    if (conn.is_tls) {
        if (conn.tls) |tls_conn| {
            try tls_conn.client.writer.flush();
            try tls_conn.stream_writer.interface.flush();  // Use the same writer as during TLS init
            
            // Add delay like in working example to allow server to process request
            std.Thread.sleep(100 * std.time.ns_per_ms);
        }
    }
}

/// Read a line directly from connection (ending with CRLF or LF)
// Connection-level buffer for reading data
const ConnectionBuffer = struct {
    data: [4096]u8,
    start: usize,
    end: usize,
    
    fn init() ConnectionBuffer {
        return ConnectionBuffer{
            .data = undefined,
            .start = 0,
            .end = 0,
        };
    }
    
    fn isEmpty(self: *const ConnectionBuffer) bool {
        return self.start >= self.end;
    }
    
    fn remainingBytes(self: *const ConnectionBuffer) []const u8 {
        return self.data[self.start..self.end];
    }
    
    fn consume(self: *ConnectionBuffer, count: usize) void {
        self.start = @min(self.start + count, self.end);
    }
    
    fn reset(self: *ConnectionBuffer) void {
        self.start = 0;
        self.end = 0;
    }
};

fn readLineFromConnection(conn: *Connection, buffer: []u8) ![]const u8 {
    // For TLS connections, try the EXACT same approach as the working test
    if (conn.is_tls) {
        // Read ALL data at once like working example
        const bytes_read = try conn.read(buffer);
        if (bytes_read == 0) return error.EndOfStream;
        
        std.log.info("Read {} bytes total from TLS", .{bytes_read});
        std.log.info("Data: {s}", .{buffer[0..@min(200, bytes_read)]});
        
        // Find first line ending
        for (buffer[0..bytes_read], 0..) |byte, i| {
            if (byte == '\n') {
                var line_len = i;
                if (line_len > 0 and buffer[line_len - 1] == '\r') {
                    line_len -= 1;
                }
                return buffer[0..line_len];
            }
        }
        
        // No line ending found, return all data
        return buffer[0..bytes_read];
    }
    
    // For regular connections, read byte by byte
    var pos: usize = 0;
    while (pos < buffer.len - 1) {
        var byte_buffer: [1]u8 = undefined;
        const bytes_read = try conn.read(&byte_buffer);
        if (bytes_read == 0) return error.EndOfStream;
        
        const byte = byte_buffer[0];
        if (byte == '\n') {
            // Remove trailing \r if present
            if (pos > 0 and buffer[pos - 1] == '\r') {
                return buffer[0 .. pos - 1];
            }
            return buffer[0..pos];
        }
        buffer[pos] = byte;
        pos += 1;
    }
    return error.HeadersTooLarge;
}

// Static buffer shared across TLS reads in the same connection  
var tls_connection_buffer: ConnectionBuffer = ConnectionBuffer.init();

fn readLineFromTlsConnection(conn: *Connection, line_buffer: []u8) ![]const u8 {
    // If buffer is empty, fill it like the working example - BUT NO DELAY HERE
    // The delay should have already happened after flushing
    if (tls_connection_buffer.isEmpty()) {
        const bytes_read = try conn.read(tls_connection_buffer.data[0..]);
        if (bytes_read == 0) return error.EndOfStream;
        
        tls_connection_buffer.start = 0;
        tls_connection_buffer.end = bytes_read;
        
        std.log.info("Read {} bytes into TLS buffer", .{bytes_read});
    }
    
    // Parse one line from the buffered data
    const remaining = tls_connection_buffer.remainingBytes();
    var line_end: ?usize = null;
    
    for (remaining, 0..) |byte, i| {
        if (byte == '\n') {
            line_end = i;
            break;
        }
    }
    
    if (line_end) |end| {
        var line_len = end;
        // Remove \r if present
        if (line_len > 0 and remaining[line_len - 1] == '\r') {
            line_len -= 1;
        }
        
        if (line_len > line_buffer.len) return error.HeadersTooLarge;
        @memcpy(line_buffer[0..line_len], remaining[0..line_len]);
        
        // Consume the line including the \n
        tls_connection_buffer.consume(end + 1);
        
        return line_buffer[0..line_len];
    }
    
    // No complete line found, need more data  
    // If we have partial data, try reading more
    if (remaining.len > 0 and remaining.len < tls_connection_buffer.data.len / 2) {
        // Move existing data to start and try to read more
        @memmove(tls_connection_buffer.data[0..remaining.len], remaining);
        const additional_bytes = try conn.read(tls_connection_buffer.data[remaining.len..]);
        
        tls_connection_buffer.start = 0;
        tls_connection_buffer.end = remaining.len + additional_bytes;
        
        if (additional_bytes == 0 and remaining.len > 0) {
            // No more data available, return what we have (might be last line without \n)
            if (remaining.len > line_buffer.len) return error.HeadersTooLarge;
            @memcpy(line_buffer[0..remaining.len], tls_connection_buffer.data[0..remaining.len]);
            tls_connection_buffer.consume(remaining.len);
            return line_buffer[0..remaining.len];
        }
        
        // Try parsing again with more data
        return readLineFromTlsConnection(conn, line_buffer);
    }
    
    return error.EndOfStream;
}

/// Convenience function to make a GET request
pub fn get(allocator: std.mem.Allocator, url: []const u8) !Response {
    var client = Client.init(allocator, ClientOptions{});
    defer client.deinit();
    
    var request = Request.init(allocator, .GET, url);
    defer request.deinit();
    
    return client.send(request);
}

/// Convenience function to make a POST request
pub fn post(allocator: std.mem.Allocator, url: []const u8, body: Body) !Response {
    var client = Client.init(allocator, ClientOptions{});
    defer client.deinit();
    
    var request = Request.init(allocator, .POST, url);
    defer request.deinit();
    request.setBody(body);
    
    return client.send(request);
}

/// Convenience function to download a file
pub fn download(allocator: std.mem.Allocator, url: []const u8, file_path: []const u8) !void {
    var response = try get(allocator, url);
    defer response.deinit();
    
    if (!response.isSuccess()) {
        return error.RequestFailed;
    }
    
    const file = try std.fs.cwd().createFile(file_path, .{});
    defer file.close();
    
    var buffer: [8192]u8 = undefined;
    while (true) {
        const bytes_read = try response.body_reader.read(&buffer);
        if (bytes_read == 0) break;
        try file.writeAll(buffer[0..bytes_read]);
    }
}

test "client options" {
    const options = ClientOptions{
        .connect_timeout = 5000,
        .user_agent = "test-client",
    };
    
    try std.testing.expect(options.connect_timeout == 5000);
    try std.testing.expectEqualStrings("test-client", options.user_agent);
}

test "connection pool" {
    var pool = ConnectionPool.init(std.testing.allocator, ClientOptions.PoolOptions{});
    defer pool.deinit();
    
    const conn = try pool.getConnection("http", "example.com", 80);
    try std.testing.expect(@TypeOf(conn) == *Connection);
    
    pool.releaseConnection(conn);
}

test "url parsing in request" {
    var request = Request.init(std.testing.allocator, .GET, "http://example.com:8080/path?query=value");
    defer request.deinit();
    
    const url_components = try request.parseUrl(std.testing.allocator);
    
    try std.testing.expectEqualStrings("http", url_components.scheme);
    try std.testing.expectEqualStrings("example.com", url_components.host);
    try std.testing.expect(url_components.port == 8080);
    try std.testing.expectEqualStrings("/path", url_components.path);
}