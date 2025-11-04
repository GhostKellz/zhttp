const std = @import("std");
const Io = std.Io;
const net = Io.net;
const crypto = std.crypto;
const compat = @import("zhttp").compat;

// Use the same TLS setup as the HTTP client
const TlsConnection = struct {
    client: std.crypto.tls.Client,
    tls_read_buffer: []u8,
    tls_write_buffer: []u8,
    stream_read_buffer: []u8,
    stream_write_buffer: []u8,
    allocator: std.mem.Allocator,
    
    fn deinit(self: *TlsConnection) void {
        self.allocator.free(self.tls_read_buffer);
        self.allocator.free(self.tls_write_buffer);
        self.allocator.free(self.stream_read_buffer);
        self.allocator.free(self.stream_write_buffer);
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    std.log.info("Connecting to httpbin.org:443...", .{});
    
    // Connect to HTTPS server
    const stream = try compat.tcpConnectToHost(allocator, "httpbin.org", 443);
    defer compat.closeStream(stream);
    
    std.log.info("TCP connection established", .{});
    
    // Set up TLS exactly like HTTP client
    const tls_conn = try allocator.create(TlsConnection);
    defer allocator.destroy(tls_conn);
    
    const min_buf_len = crypto.tls.max_ciphertext_record_len;
    
    const tls_read_buffer = try allocator.alloc(u8, min_buf_len);
    const tls_write_buffer = try allocator.alloc(u8, min_buf_len);
    const stream_read_buffer = try allocator.alloc(u8, min_buf_len);
    const stream_write_buffer = try allocator.alloc(u8, min_buf_len);
    
    var stream_reader = compat.BufferedReader.init(stream, stream_read_buffer);
    var stream_writer = compat.BufferedWriter.init(stream, stream_write_buffer);

    // Generate entropy for TLS
    var entropy: [176]u8 = undefined;
    crypto.random.bytes(&entropy);

    const tls_options = crypto.tls.Client.Options{
        .host = .no_verification,
        .ca = .no_verification,
        .write_buffer = tls_write_buffer,
        .read_buffer = tls_read_buffer,
        .entropy = &entropy,
        .realtime_now_seconds = compat.realtimeNowSeconds(),
    };
    
    std.log.info("Initializing TLS handshake...", .{});
    
    const tls_client = crypto.tls.Client.init(stream_reader.reader(), stream_writer.writer(), tls_options) catch |err| {
        std.log.err("TLS init failed: {}", .{err});
        return;
    };
    
    tls_conn.* = TlsConnection{
        .client = tls_client,
        .tls_read_buffer = tls_read_buffer,
        .tls_write_buffer = tls_write_buffer,
        .stream_read_buffer = stream_read_buffer,
        .stream_write_buffer = stream_write_buffer,
        .allocator = allocator,
    };
    
    std.log.info("TLS handshake completed successfully!", .{});
    
    // Build HTTP request exactly like HTTP client
    var request_buffer = std.ArrayList(u8){};
    defer request_buffer.deinit(allocator);
    
    const request_line_str = try std.fmt.allocPrint(allocator, "{s} {s} HTTP/1.1\r\n", .{ "GET", "/get" });
    defer allocator.free(request_line_str);
    try request_buffer.appendSlice(allocator, request_line_str);
    
    const host_header = try std.fmt.allocPrint(allocator, "Host: {s}\r\n", .{"httpbin.org"});
    defer allocator.free(host_header);
    try request_buffer.appendSlice(allocator, host_header);
    
    const connection_header = "Connection: close\r\n";
    try request_buffer.appendSlice(allocator, connection_header);
    
    try request_buffer.appendSlice(allocator, "\r\n");
    
    std.log.info("Sending HTTP request:\n{s}", .{request_buffer.items});
    
    // Write request and flush exactly like HTTP client
    try tls_conn.client.writer.writeAll(request_buffer.items);
    try tls_conn.client.writer.flush();
    try stream_writer.interface.flush();
    
    std.log.info("Request sent and flushed, reading response...", .{});
    
    // Add delay like in working minimal test
    std.Thread.sleep(100 * std.time.ns_per_ms);
    
    // Read response
    var response_buffer: [1024]u8 = undefined;
    const bytes_read = try tls_conn.client.reader.readSliceShort(response_buffer[0..]);
    
    std.log.info("Read {} bytes:", .{bytes_read});
    if (bytes_read > 0) {
        std.debug.print("{s}\n", .{response_buffer[0..bytes_read]});
    }
    
    tls_conn.deinit();
}