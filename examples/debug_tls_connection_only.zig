const std = @import("std");
const net = std.net;
const crypto = std.crypto;

// Test just the TLS connection setup that the HTTP client uses
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){}; 
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    std.log.info("Testing HTTP client TLS connection setup in isolation...", .{});
    
    // Connect to HTTPS server
    const stream = try net.tcpConnectToHost(allocator, "httpbin.org", 443);
    defer stream.close();
    
    std.log.info("TCP connection established", .{});
    
    // Set up TLS EXACTLY like HTTP client does
    const min_buf_len = crypto.tls.max_ciphertext_record_len;
    
    const tls_read_buffer = try allocator.alloc(u8, min_buf_len);
    defer allocator.free(tls_read_buffer);
    const tls_write_buffer = try allocator.alloc(u8, min_buf_len);
    defer allocator.free(tls_write_buffer);
    const stream_read_buffer = try allocator.alloc(u8, min_buf_len);
    defer allocator.free(stream_read_buffer);
    const stream_write_buffer = try allocator.alloc(u8, min_buf_len);
    defer allocator.free(stream_write_buffer);
    
    var stream_reader = stream.reader(stream_read_buffer);
    var stream_writer = stream.writer(stream_write_buffer);
    
    // Use no verification like working examples
    const tls_client_options = crypto.tls.Client.Options{
        .host = .no_verification,
        .ca = .no_verification,
        .write_buffer = tls_write_buffer,
        .read_buffer = tls_read_buffer,
    };
    
    std.log.info("Initializing TLS handshake...", .{});
    
    var tls_client = crypto.tls.Client.init(stream_reader.interface(), &stream_writer.interface, tls_client_options) catch |err| {
        std.log.err("TLS init failed: {}", .{err});
        return;
    };
    
    std.log.info("TLS handshake completed successfully!", .{});
    
    // Send HTTP request
    const request = "GET /get HTTP/1.1\r\nHost: httpbin.org\r\nConnection: close\r\n\r\n";
    
    std.log.info("Sending HTTP request...", .{});
    try tls_client.writer.writeAll(request);
    try tls_client.writer.flush();
    
    // Also flush underlying stream
    try stream_writer.interface.flush();
    
    std.log.info("Request sent and flushed, reading response...", .{});
    
    // Add delay like in working example
    std.Thread.sleep(100 * std.time.ns_per_ms);
    
    // Read response
    var response_buffer: [1024]u8 = undefined;
    const bytes_read = try tls_client.reader.readSliceShort(response_buffer[0..]);
    
    std.log.info("Read {} bytes:", .{bytes_read});
    if (bytes_read > 0) {
        std.debug.print("{s}\n", .{response_buffer[0..bytes_read]});
    }
}