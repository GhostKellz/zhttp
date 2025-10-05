const std = @import("std");
const zhttp = @import("zhttp");

/// Example demonstrating WebSocket protocol
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("WebSocket Example\n", .{});
    std.debug.print("================\n\n", .{});

    // 1. Generate WebSocket key for upgrade
    const key = try zhttp.WebSocket.Upgrade.generateKey(allocator);
    defer allocator.free(key);
    std.debug.print("Generated WebSocket Key: {s}\n", .{key});

    // 2. Generate accept key (server-side)
    const accept_key = try zhttp.WebSocket.Upgrade.generateAcceptKey(allocator, key);
    defer allocator.free(accept_key);
    std.debug.print("Accept Key: {s}\n\n", .{accept_key});

    // 3. Create upgrade headers
    var headers = try zhttp.WebSocket.Upgrade.createUpgradeHeaders(
        allocator,
        "example.com",
        "/ws",
        key,
    );
    defer headers.deinit();

    std.debug.print("Upgrade Request Headers:\n", .{});
    for (headers.items) |header| {
        std.debug.print("  {s}: {s}\n", .{ header.name, header.value });
    }
    std.debug.print("\n", .{});

    // 4. Create and encode text frame
    var text_frame = try zhttp.WebSocket.Frame.text(allocator, "Hello, WebSocket!", true);
    defer text_frame.deinit(allocator);

    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    try text_frame.write(buffer.writer().any());

    std.debug.print("Text Frame ({} bytes):\n", .{buffer.items.len});
    std.debug.print("  FIN: {}\n", .{text_frame.header.fin});
    std.debug.print("  Opcode: {}\n", .{text_frame.header.opcode});
    std.debug.print("  Masked: {}\n", .{text_frame.header.masked});
    std.debug.print("  Payload: {s}\n\n", .{text_frame.payload});

    // 5. Create binary frame
    const binary_data = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05 };
    var binary_frame = try zhttp.WebSocket.Frame.binary(allocator, &binary_data, false);
    defer binary_frame.deinit(allocator);

    std.debug.print("Binary Frame:\n", .{});
    std.debug.print("  Opcode: {}\n", .{binary_frame.header.opcode});
    std.debug.print("  Payload Length: {}\n", .{binary_frame.payload.len});
    std.debug.print("  Data: ", .{});
    for (binary_frame.payload) |byte| {
        std.debug.print("{x:0>2} ", .{byte});
    }
    std.debug.print("\n\n", .{});

    // 6. Create ping frame
    var ping_frame = try zhttp.WebSocket.Frame.ping(allocator, "ping", true);
    defer ping_frame.deinit(allocator);

    std.debug.print("Ping Frame:\n", .{});
    std.debug.print("  Opcode: {}\n", .{ping_frame.header.opcode});
    std.debug.print("  Payload: {s}\n\n", .{ping_frame.payload});

    // 7. Create close frame
    var close_frame = try zhttp.WebSocket.Frame.close(
        allocator,
        .normal,
        "Goodbye!",
        false,
    );
    defer close_frame.deinit(allocator);

    std.debug.print("Close Frame:\n", .{});
    std.debug.print("  Opcode: {}\n", .{close_frame.header.opcode});
    std.debug.print("  Code: {}\n", .{zhttp.WebSocket.CloseCode.normal});
    std.debug.print("  Reason: Goodbye!\n", .{});
}
