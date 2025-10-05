const std = @import("std");
const zhttp = @import("zhttp");

/// Example demonstrating HTTP/3 QPACK and framing
/// Note: This is a demonstration of the HTTP/3 protocol components.
/// For a full HTTP/3 client/server, you need to integrate with zquic.
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("HTTP/3 Protocol Example\n", .{});
    std.debug.print("======================\n\n", .{});

    // 1. QPACK Header Compression
    std.debug.print("1. QPACK Header Compression\n", .{});
    std.debug.print("---------------------------\n", .{});

    var encoder = zhttp.Http3.QPACK.Encoder.init(allocator, 4096);
    defer encoder.deinit();

    const headers = [_]struct { name: []const u8, value: []const u8 }{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "example.com" },
        .{ .name = ":path", .value = "/api/data" },
        .{ .name = "user-agent", .value = "zhttp/0.1" },
        .{ .name = "accept", .value = "application/json" },
    };

    var encoded_headers = std.ArrayList(u8).init(allocator);
    defer encoded_headers.deinit();

    try encoder.encodeHeaders(encoded_headers.writer().any(), &headers);

    std.debug.print("Original headers: {} fields\n", .{headers.len});
    std.debug.print("Encoded size: {} bytes\n", .{encoded_headers.items.len});
    std.debug.print("Compression ratio: {d:.1}%\n\n", .{
        @as(f64, @floatFromInt(encoded_headers.items.len)) /
            @as(f64, @floatFromInt(estimateHeaderSize(&headers))) * 100.0,
    });

    // Decode headers
    var decoder = zhttp.Http3.QPACK.Decoder.init(allocator, 4096);
    defer decoder.deinit();

    var decoded_headers = try decoder.decodeHeaderBlock(encoded_headers.items);
    defer {
        for (decoded_headers.items) |h| {
            allocator.free(h.name);
            allocator.free(h.value);
        }
        decoded_headers.deinit();
    }

    std.debug.print("Decoded headers:\n", .{});
    for (decoded_headers.items) |h| {
        std.debug.print("  {s}: {s}\n", .{ h.name, h.value });
    }
    std.debug.print("\n", .{});

    // 2. Variable-Length Integer Encoding
    std.debug.print("2. Variable-Length Integer (VarInt)\n", .{});
    std.debug.print("-----------------------------------\n", .{});

    const test_values = [_]u64{ 0, 63, 64, 16383, 16384, 1073741823, 1073741824 };

    for (test_values) |value| {
        var varint_buf = std.ArrayList(u8).init(allocator);
        defer varint_buf.deinit();

        try zhttp.Http3.Frame.VarInt.encode(varint_buf.writer().any(), value);

        std.debug.print("  Value: {d:10} -> {d} byte(s): ", .{ value, varint_buf.items.len });
        for (varint_buf.items) |byte| {
            std.debug.print("{x:0>2} ", .{byte});
        }

        // Decode and verify
        var fbs = std.io.fixedBufferStream(varint_buf.items);
        const decoded = try zhttp.Http3.Frame.VarInt.decode(fbs.reader().any());
        std.debug.print(" -> {d}\n", .{decoded});
    }
    std.debug.print("\n", .{});

    // 3. HTTP/3 Frames
    std.debug.print("3. HTTP/3 Frames\n", .{});
    std.debug.print("----------------\n", .{});

    // DATA frame
    const data = "Hello, HTTP/3!";
    const data_frame = zhttp.Http3.Frame.DataFrame.init(data);

    var frame_buffer = std.ArrayList(u8).init(allocator);
    defer frame_buffer.deinit();

    try data_frame.encode(frame_buffer.writer().any());

    std.debug.print("DATA frame:\n", .{});
    std.debug.print("  Payload: {s}\n", .{data});
    std.debug.print("  Encoded size: {} bytes\n\n", .{frame_buffer.items.len});

    // HEADERS frame
    frame_buffer.clearRetainingCapacity();
    const headers_frame = zhttp.Http3.Frame.HeadersFrame.init(encoded_headers.items);
    try headers_frame.encode(frame_buffer.writer().any());

    std.debug.print("HEADERS frame:\n", .{});
    std.debug.print("  Header block size: {} bytes\n", .{encoded_headers.items.len});
    std.debug.print("  Encoded size: {} bytes\n\n", .{frame_buffer.items.len});

    // SETTINGS frame
    const settings = [_]zhttp.Http3.Frame.SettingsFrame.Setting{
        .{ .parameter = .qpack_max_table_capacity, .value = 4096 },
        .{ .parameter = .max_field_section_size, .value = 16384 },
        .{ .parameter = .qpack_blocked_streams, .value = 100 },
    };

    frame_buffer.clearRetainingCapacity();
    var settings_frame = zhttp.Http3.Frame.SettingsFrame.init(&settings);
    try settings_frame.encode(frame_buffer.writer().any());

    std.debug.print("SETTINGS frame:\n", .{});
    std.debug.print("  Settings count: {}\n", .{settings.len});
    std.debug.print("  Encoded size: {} bytes\n\n", .{frame_buffer.items.len});

    // 4. 0-RTT Session Management
    std.debug.print("4. 0-RTT Session Management\n", .{});
    std.debug.print("---------------------------\n", .{});

    var zero_rtt = zhttp.Http3.ZeroRTT.ZeroRTTManager.init(allocator, .{
        .enabled = true,
        .max_early_data_size = 16384,
    });
    defer zero_rtt.deinit();

    // Store session ticket
    try zero_rtt.storeTicket("example.com", "session_ticket_data", 16384);

    // Create 0-RTT request
    var request = zhttp.Http3.ZeroRTT.ZeroRTTRequest.init(allocator, "GET", "/api/data");
    defer request.deinit();

    try request.addHeader("accept", "application/json");

    std.debug.print("0-RTT Request:\n", .{});
    std.debug.print("  Method: {s}\n", .{request.method});
    std.debug.print("  Path: {s}\n", .{request.path});
    std.debug.print("  Safe for 0-RTT: {}\n", .{request.isSafeFor0RTT()});
    std.debug.print("  Can use 0-RTT: {}\n", .{zero_rtt.canUse0RTT(&request, "example.com")});
    std.debug.print("  Estimated size: {} bytes\n", .{request.estimateSize()});
}

fn estimateHeaderSize(headers: []const struct { name: []const u8, value: []const u8 }) usize {
    var size: usize = 0;
    for (headers) |h| {
        size += h.name.len + h.value.len + 4; // Name + value + ": " + "\r\n"
    }
    return size;
}
