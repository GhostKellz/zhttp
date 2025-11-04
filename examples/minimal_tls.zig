const std = @import("std");
const Io = std.Io;
const net = Io.net;
const crypto = std.crypto;
const compat = @import("zhttp").compat;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    std.log.info("Connecting to httpbin.org:443...", .{});
    
    // Connect to HTTPS server
    const stream = try compat.tcpConnectToHost(allocator, "httpbin.org", 443);
    defer compat.closeStream(stream);
    
    std.log.info("TCP connection established", .{});
    
    // Set up TLS
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
    
    var tls_client = crypto.tls.Client.init(stream_reader.reader(), stream_writer.writer(), tls_options) catch |err| {
        std.log.err("TLS init failed: {}", .{err});
        return;
    };
    
    std.log.info("TLS handshake completed successfully!", .{});
    
    // Send simple HTTP request
    const request = "GET /get HTTP/1.1\r\nHost: httpbin.org\r\nConnection: close\r\n\r\n";
    
    std.log.info("Sending HTTP request...", .{});
    try tls_client.writer.writeAll(request);
    try tls_client.writer.flush();
    
    // Also flush underlying stream
    try stream_writer.interface.flush();
    
    std.log.info("Request sent and flushed (both TLS and stream), reading response...", .{});
    
    // Small delay to let server process
    std.Thread.sleep(100 * std.time.ns_per_ms);
    
    // Read some response
    var response_buffer: [1024]u8 = undefined;
    const bytes_read = try tls_client.reader.readSliceShort(response_buffer[0..]);
    
    std.log.info("Read {} bytes:", .{bytes_read});
    std.debug.print("{s}\n", .{response_buffer[0..bytes_read]});
}