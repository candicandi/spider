const std = @import("std");
const posix = std.posix;
const net = std.Io.net;
const Hub = @import("hub.zig").Hub;
const Ctx = @import("../core/context.zig").Ctx;
const Response = @import("../core/context.zig").Response;
const Handler = @import("../routing/router.zig").Handler;

pub const Sse = struct {
    _stream: net.Stream,
    _hub: *Hub,
    _conn_id: u64,
    channel: []const u8 = "",
    params: std.StringHashMapUnmanaged([]const u8) = .{},
    arena: std.mem.Allocator,
    io: std.Io,

    pub fn send(self: *Sse, event: []const u8, data: anytype) !void {
        const json = try std.json.Stringify.valueAlloc(self.arena, data, .{});
        defer self.arena.free(json);

        var write_buf: [4096]u8 = undefined;
        var sw = net.Stream.Writer.init(self._stream, self.io, &write_buf);
        const writer = &sw.interface;
        try writer.writeAll("event: ");
        try writer.writeAll(event);
        try writer.writeAll("\ndata: ");
        try writer.writeAll(json);
        try writer.writeAll("\n\n");
        try writer.flush();
    }

    pub fn join(self: *Sse, channel: []const u8) !void {
        self.channel = channel;
        try self._hub.updateChannel(self._conn_id, channel);
    }

    pub fn joinUser(self: *Sse, user_id: u64) !void {
        // Must outlive this call — join() stores the slice on self.channel
        // and in the Hub's connection list for the connection's whole
        // lifetime. A stack buffer here would leave both as dangling slices
        // the moment this function returns (caught by a hanging test: the
        // Hub compares garbage bytes against a freshly-built channel name
        // and never finds a match, so nothing is ever delivered).
        const channel = try std.fmt.allocPrint(self.arena, "user:{d}", .{user_id});
        try self.join(channel);
    }

    pub fn param(self: *Sse, key: []const u8) ?[]const u8 {
        return self.params.get(key);
    }

    pub fn wait(self: *Sse) void {
        var buf: [1]u8 = undefined;
        var read_buf: [256]u8 = undefined;
        var reader = net.Stream.Reader.init(self._stream, self.io, &read_buf);
        _ = reader.interface.readSliceAll(&buf) catch {};
    }
};

// Shared by Server.sse() and Group.sse() — kept here (not in core/app.zig)
// so routing/group.zig can use it without importing app.zig, which would
// create a circular import (app.zig already imports group.zig for
// mount()'s parameter type).
pub fn buildHandler(comptime handler: fn (*Sse) anyerror!void) Handler {
    const W = struct {
        pub fn call(ctx: *Ctx) anyerror!Response {
            const hub = ctx._sse_hub orelse return ctx.text("", .{});

            var write_buf: [512]u8 = undefined;
            var sw = net.Stream.Writer.init(ctx._stream, ctx._io, &write_buf);
            const writer = &sw.interface;
            try writer.writeAll(
                "HTTP/1.1 200 OK\r\n" ++
                    "Content-Type: text/event-stream\r\n" ++
                    "Cache-Control: no-cache\r\n" ++
                    "Connection: keep-alive\r\n" ++
                    "Access-Control-Allow-Origin: *\r\n" ++
                    "\r\n",
            );
            try writer.flush();

            var rand_buf: [8]u8 = undefined;
            std.Io.random(ctx._io, &rand_buf);
            const conn_id = std.mem.readInt(u64, &rand_buf, .little);

            try hub.add(.{
                .id = conn_id,
                .stream = ctx._stream,
                .type = .sse,
            });
            defer hub.remove(conn_id);

            var sse = Sse{
                ._stream = ctx._stream,
                ._hub = hub,
                ._conn_id = conn_id,
                .params = ctx.params,
                .arena = ctx.arena,
                .io = ctx._io,
            };

            handler(&sse) catch {};
            return Response{ .raw = true };
        }
    };
    return W.call;
}

// =============================================================================
// Tests
// =============================================================================
// Sse itself had zero coverage before this — Hub (hub.zig) already had a
// decent suite for join/broadcast/emit/remove at the connection-list level,
// but nothing exercised the Sse wrapper methods (send/join/joinUser/param)
// directly. These construct a Sse by hand (not through buildHandler, which
// needs a full Ctx/HTTP handshake) over a real socketpair, mirroring the
// pattern hub.zig's own tests already use.

const testing = std.testing;

fn makeSocketPair() ![2]net.Socket {
    var fds: [2]posix.fd_t = undefined;
    const rc = posix.system.socketpair(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0, &fds);
    if (rc != 0) return error.Unexpected;
    return .{
        net.Socket{ .handle = fds[0], .address = .{ .ip4 = .{ .bytes = [4]u8{ 0, 0, 0, 0 }, .port = 0 } } },
        net.Socket{ .handle = fds[1], .address = .{ .ip4 = .{ .bytes = [4]u8{ 0, 0, 0, 0 }, .port = 0 } } },
    };
}

// ── Baseline: current behavior (send/join/joinUser/param) ──────────────────

test "Sse: send writes 'event: X\\ndata: Y\\n\\n' wire format" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const sockets = try makeSocketPair();
    defer sockets[0].close(io);
    defer sockets[1].close(io);

    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var sse = Sse{
        ._stream = .{ .socket = sockets[0] },
        ._hub = &hub,
        ._conn_id = 1,
        .arena = arena.allocator(),
        .io = io,
    };

    try sse.send("greeting", .{ .msg = "hi" });

    const expected = "event: greeting\ndata: {\"msg\":\"hi\"}\n\n";
    var buf: [expected.len]u8 = undefined;
    var read_buf: [256]u8 = undefined;
    var reader = net.Stream.Reader.init(.{ .socket = sockets[1] }, io, &read_buf);
    try reader.interface.readSliceAll(&buf);
    try testing.expectEqualStrings(expected, &buf);
}

test "Sse: join updates the connection's channel on the Hub" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const sockets = try makeSocketPair();
    // sockets[0] is handed to the Hub below and stays registered for the
    // whole test — Hub.deinit() closes it, so closing it again here would
    // double-close (crashes as EBADF in debug builds).
    defer sockets[1].close(io);

    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();
    try hub.add(.{ .id = 1, .stream = .{ .socket = sockets[0] }, .type = .sse });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var sse = Sse{
        ._stream = .{ .socket = sockets[0] },
        ._hub = &hub,
        ._conn_id = 1,
        .arena = arena.allocator(),
        .io = io,
    };

    try sse.join("room:42");
    try testing.expectEqualStrings("room:42", sse.channel);

    // Confirms the Hub-side channel really updated, not just the local field —
    // emitTo("room:42", ...) must actually reach this connection now.
    hub.emitTo("room:42", "notice", .{ .text = "hi" });

    var buf: [256]u8 = undefined;
    var read_buf: [256]u8 = undefined;
    var reader = net.Stream.Reader.init(.{ .socket = sockets[1] }, io, &read_buf);
    try reader.interface.readSliceAll(buf[0..7]); // "event: "
    try testing.expectEqualStrings("event: ", buf[0..7]);
}

test "Sse: join to a different channel does not receive emitTo on the old one" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const sockets = try makeSocketPair();
    // sockets[0] stays Hub-registered — see the send-format test above.
    defer sockets[1].close(io);

    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();
    try hub.add(.{ .id = 1, .stream = .{ .socket = sockets[0] }, .channel = "room:old", .type = .sse });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var sse = Sse{
        ._stream = .{ .socket = sockets[0] },
        ._hub = &hub,
        ._conn_id = 1,
        .channel = "room:old",
        .arena = arena.allocator(),
        .io = io,
    };

    try sse.join("room:new");

    // Nothing should arrive on the old channel anymore.
    hub.emitTo("room:old", "should-not-arrive", .{});
    try (net.Stream{ .socket = sockets[0] }).shutdown(io, .send);
}

test "Sse: joinUser joins the 'user:{id}' channel" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const sockets = try makeSocketPair();
    // sockets[0] is handed to the Hub below and stays registered for the
    // whole test — Hub.deinit() closes it, so closing it again here would
    // double-close (crashes as EBADF in debug builds).
    defer sockets[1].close(io);

    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();
    try hub.add(.{ .id = 1, .stream = .{ .socket = sockets[0] }, .type = .sse });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var sse = Sse{
        ._stream = .{ .socket = sockets[0] },
        ._hub = &hub,
        ._conn_id = 1,
        .arena = arena.allocator(),
        .io = io,
    };

    try sse.joinUser(99);
    try testing.expectEqualStrings("user:99", sse.channel);

    hub.notifyUser(99, "private", .{});

    var buf: [7]u8 = undefined;
    var read_buf: [256]u8 = undefined;
    var reader = net.Stream.Reader.init(.{ .socket = sockets[1] }, io, &read_buf);
    try reader.interface.readSliceAll(&buf);
    try testing.expectEqualStrings("event: ", &buf);
}

test "Sse: param returns the value for a known key and null for an unknown one" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();

    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();

    var params: std.StringHashMapUnmanaged([]const u8) = .{};
    try params.put(arena.allocator(), "_auth_sub", "abc-123");

    var sse = Sse{
        ._stream = undefined,
        ._hub = &hub,
        ._conn_id = 1,
        .params = params,
        .arena = arena.allocator(),
        .io = io,
    };

    try testing.expectEqualStrings("abc-123", sse.param("_auth_sub").?);
    try testing.expectEqual(@as(?[]const u8, null), sse.param("condo_id"));
}

// ── TDD spec: NOT-YET-IMPLEMENTED "id:" field ───────────────────────────────
// One planned feature (per-event `id:` line + Last-Event-ID replay support)
// is partially expressible today: the *sending* half (an incrementing id:
// line on every event) only needs the existing public API — no new fields
// needed to write the assertion, unlike heartbeat/retry/header access/replay
// itself, which all need new API surface that doesn't exist yet (see
// SSE_HUB_TEST_NOTES.md for those). This test is expected to FAIL against
// the current implementation — sendSse() never writes an id: line — and
// should start passing once that lands.

test "Sse (SPEC, currently failing): emitTo includes an incrementing id: line" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const sockets = try makeSocketPair();
    // sockets[0] stays Hub-registered — see the send-format test above.
    defer sockets[1].close(io);

    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();
    try hub.add(.{ .id = 1, .stream = .{ .socket = sockets[0] }, .channel = "room:1", .type = .sse });

    hub.emitTo("room:1", "notice", .{ .text = "first" });
    hub.emitTo("room:1", "notice", .{ .text = "second" });

    var buf: [256]u8 = undefined;
    var read_buf: [256]u8 = undefined;
    var reader = net.Stream.Reader.init(.{ .socket = sockets[1] }, io, &read_buf);

    // Expected future wire format per event: "id: 1\nevent: notice\ndata: ...\n\n"
    const expected_first = "id: 1\nevent: notice\ndata: {\"text\":\"first\"}\n\n";
    try reader.interface.readSliceAll(buf[0..expected_first.len]);
    try testing.expectEqualStrings(expected_first, buf[0..expected_first.len]);

    const expected_second = "id: 2\nevent: notice\ndata: {\"text\":\"second\"}\n\n";
    try reader.interface.readSliceAll(buf[0..expected_second.len]);
    try testing.expectEqualStrings(expected_second, buf[0..expected_second.len]);
}
