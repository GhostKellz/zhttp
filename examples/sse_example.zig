const std = @import("std");
const zhttp = @import("zhttp");

/// Example demonstrating Server-Sent Events (SSE)
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("Server-Sent Events Example\n", .{});
    std.debug.print("=========================\n\n", .{});

    // 1. Create an event
    var event = zhttp.SSE.Event.init("Hello from SSE!");
    event.event_type = "message";
    event.id = "1";
    event.retry = 5000;

    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    try event.format(buffer.writer().any());

    std.debug.print("Event formatted as SSE:\n{s}\n", .{buffer.items});

    // 2. Use event builder
    var builder = zhttp.SSE.EventBuilder.init();
    const built_event = builder
        .setType("update")
        .setData("Stock price: $123.45")
        .setId("42")
        .setRetry(3000)
        .build();

    buffer.clearRetainingCapacity();
    try built_event.format(buffer.writer().any());

    std.debug.print("Built event:\n{s}\n", .{buffer.items});

    // 3. Parse SSE stream
    std.debug.print("Parsing SSE stream:\n", .{});

    var client = zhttp.SSE.Client.init(allocator);
    defer client.deinit();

    const sse_data =
        "event: stock-update\n" ++
        "id: 100\n" ++
        "data: AAPL: $175.50\n" ++
        "\n" ++
        "event: stock-update\n" ++
        "id: 101\n" ++
        "data: GOOGL: $142.30\n" ++
        "\n" ++
        "event: alert\n" ++
        "id: 102\n" ++
        "data: Market closing soon!\n" ++
        "\n";

    var events = try client.processChunk(sse_data);
    defer events.deinit();

    std.debug.print("Received {} events:\n", .{events.items.len});
    for (events.items, 0..) |evt, i| {
        std.debug.print("\nEvent #{}:\n", .{i + 1});
        std.debug.print("  Type: {s}\n", .{evt.event_type.?});
        std.debug.print("  ID: {s}\n", .{evt.id.?});
        std.debug.print("  Data: {s}\n", .{evt.data});
    }

    std.debug.print("\nLast Event ID: {s}\n", .{client.getLastEventId().?});

    // 4. Multi-line data
    std.debug.print("\nMulti-line data example:\n", .{});

    var multiline_builder = zhttp.SSE.EventBuilder.init();
    const multiline_event = multiline_builder
        .setType("code")
        .setData("function hello() {\n  console.log('Hello, World!');\n}")
        .build();

    buffer.clearRetainingCapacity();
    try multiline_event.format(buffer.writer().any());

    std.debug.print("{s}\n", .{buffer.items});
}
