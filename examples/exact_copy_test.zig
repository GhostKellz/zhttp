const std = @import("std");
const Io = std.Io;
const net = Io.net;
const crypto = std.crypto;
const compat = @import("zhttp").compat;

// This is an EXACT copy of the working debug_tls_like_client.zig
// but we'll gradually modify it to match the HTTP client pattern

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
    defer allocator.free(tls_read_buffer);
    const tls_write_buffer = try allocator.alloc(u8, min_buf_len);
    defer allocator.free(tls_write_buffer);
    const stream_read_buffer = try allocator.alloc(u8, min_buf_len);
    defer allocator.free(stream_read_buffer);
    const stream_write_buffer = try allocator.alloc(u8, min_buf_len);
    defer allocator.free(stream_write_buffer);
    
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
    
    // Now replicate EXACT HTTP client request sending pattern
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
    
    // Send like HTTP client - writeAll, then flush both TLS and stream
    try tls_conn.client.writer.writeAll(request_buffer.items);
    try tls_conn.client.writer.flush();
    try stream_writer.interface.flush();
    
    std.log.info("Request sent and flushed, reading response...", .{});
    
    // Add delay like in working minimal test
    std.Thread.sleep(100 * std.time.ns_per_ms);
    
    // Now try to read using TLS client readSliceShort like HTTP client does
    std.log.info("Reading from TLS client...", .{});
    
    var response_buffer: [1024]u8 = undefined;
    const bytes_read = tls_conn.client.reader.readSliceShort(response_buffer[0..]) catch |err| {
        std.log.err("TLS read error: {}", .{err});
        return;
    };
    
    std.log.info("Read {} bytes:", .{bytes_read});
    if (bytes_read > 0) {
        std.debug.print("{s}\n", .{response_buffer[0..bytes_read]});
    }
    
    tls_conn.deinit();
}