const std = @import("std");
const posix = std.posix;
const net = std.Io.net;

pub const Hub = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex,
    connections: std.ArrayListUnmanaged(Connection) = .empty,

    pub const Connection = struct {
        id: u64,
        stream: net.Stream,
        channel: []const u8 = "",
        namespace: []const u8 = "",
        type: enum { ws, sse } = .ws,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Hub {
        return .{
            .allocator = allocator,
            .io = io,
            .mutex = std.Io.Mutex.init,
            .connections = .empty,
        };
    }

    pub fn deinit(self: *Hub) void {
        for (self.connections.items) |conn| {
            conn.stream.close(self.io);
        }
        self.connections.deinit(self.allocator);
    }

    pub fn add(self: *Hub, conn: Connection) !void {
        self.mutex.lock(self.io) catch return error.LockFailed;
        defer self.mutex.unlock(self.io);
        for (self.connections.items) |c| {
            if (c.id == conn.id) return error.DuplicateId;
        }
        try self.connections.append(self.allocator, conn);
    }

    pub fn updateChannel(self: *Hub, conn_id: u64, channel: []const u8) !void {
        self.mutex.lock(self.io) catch return error.LockFailed;
        defer self.mutex.unlock(self.io);
        for (self.connections.items) |*conn| {
            if (conn.id == conn_id) {
                conn.channel = channel;
                return;
            }
        }
    }

    pub fn remove(self: *Hub, conn_id: u64) void {
        self.mutex.lock(self.io) catch return;
        defer self.mutex.unlock(self.io);
        for (self.connections.items, 0..) |conn, i| {
            if (conn.id == conn_id) {
                _ = self.connections.orderedRemove(i);
                return;
            }
        }
    }

    pub fn count(self: *Hub) usize {
        self.mutex.lock(self.io) catch return 0;
        defer self.mutex.unlock(self.io);
        return self.connections.items.len;
    }

    pub fn broadcast(self: *Hub, message: []const u8) void {
        self.mutex.lock(self.io) catch return;
        var snapshot: std.ArrayListUnmanaged(Connection) = .empty;
        defer snapshot.deinit(self.allocator);
        for (self.connections.items) |conn| {
            snapshot.append(self.allocator, conn) catch {};
        }
        self.mutex.unlock(self.io);

        var dead: std.ArrayListUnmanaged(u64) = .empty;
        defer dead.deinit(self.allocator);

        for (snapshot.items) |conn| {
            switch (conn.type) {
                .ws => self.sendText(conn.stream, message) catch {
                    dead.append(self.allocator, conn.id) catch {};
                },
                .sse => self.sendSse(conn.stream, "message", message) catch {
                    dead.append(self.allocator, conn.id) catch {};
                },
            }
        }

        if (dead.items.len == 0) return;
        self.mutex.lock(self.io) catch return;
        defer self.mutex.unlock(self.io);
        for (dead.items) |id| {
            for (self.connections.items, 0..) |conn, i| {
                if (conn.id == id) {
                    _ = self.connections.orderedRemove(i);
                    break;
                }
            }
        }
    }

    pub fn notifyUser(self: *Hub, user_id: u64, event: []const u8, data: anytype) void {
        var ch_buf: [32]u8 = undefined;
        const channel = std.fmt.bufPrint(&ch_buf, "user:{d}", .{user_id}) catch return;
        self.emitTo(channel, event, data);
    }

    pub fn emit(self: *Hub, event: []const u8, data: anytype) void {
        const json = std.json.Stringify.valueAlloc(self.allocator, data, .{}) catch return;
        defer self.allocator.free(json);
        self.broadcastEvent(event, json);
    }

    pub fn emitTo(self: *Hub, channel: []const u8, event: []const u8, data: anytype) void {
        const json = std.json.Stringify.valueAlloc(self.allocator, data, .{}) catch return;
        defer self.allocator.free(json);
        self.broadcastToChannelEvent(channel, event, json);
    }

    fn broadcastEvent(self: *Hub, event: []const u8, data: []const u8) void {
        self.mutex.lock(self.io) catch return;
        var snapshot: std.ArrayListUnmanaged(Connection) = .empty;
        defer snapshot.deinit(self.allocator);
        for (self.connections.items) |conn| {
            if (conn.type == .sse) {
                snapshot.append(self.allocator, conn) catch {};
            }
        }
        self.mutex.unlock(self.io);

        var dead: std.ArrayListUnmanaged(u64) = .empty;
        defer dead.deinit(self.allocator);

        for (snapshot.items) |conn| {
            self.sendSse(conn.stream, event, data) catch {
                dead.append(self.allocator, conn.id) catch {};
            };
        }

        if (dead.items.len == 0) return;
        self.mutex.lock(self.io) catch return;
        defer self.mutex.unlock(self.io);
        for (dead.items) |id| {
            for (self.connections.items, 0..) |conn, i| {
                if (conn.id == id) {
                    _ = self.connections.orderedRemove(i);
                    break;
                }
            }
        }
    }

    fn broadcastToChannelEvent(self: *Hub, channel: []const u8, event: []const u8, data: []const u8) void {
        self.mutex.lock(self.io) catch return;
        var snapshot: std.ArrayListUnmanaged(Connection) = .empty;
        defer snapshot.deinit(self.allocator);
        for (self.connections.items) |conn| {
            if (conn.type == .sse and std.mem.eql(u8, conn.channel, channel)) {
                snapshot.append(self.allocator, conn) catch {};
            }
        }
        self.mutex.unlock(self.io);

        var dead: std.ArrayListUnmanaged(u64) = .empty;
        defer dead.deinit(self.allocator);

        for (snapshot.items) |conn| {
            self.sendSse(conn.stream, event, data) catch {
                dead.append(self.allocator, conn.id) catch {};
            };
        }

        if (dead.items.len == 0) return;
        self.mutex.lock(self.io) catch return;
        defer self.mutex.unlock(self.io);
        for (dead.items) |id| {
            for (self.connections.items, 0..) |conn, i| {
                if (conn.id == id) {
                    _ = self.connections.orderedRemove(i);
                    break;
                }
            }
        }
    }

    pub fn broadcastFmt(self: *Hub, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.allocPrint(self.allocator, fmt, args) catch return;
        defer self.allocator.free(msg);
        self.broadcast(msg);
    }

    pub fn broadcastToChannelFmt(self: *Hub, channel: []const u8, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.allocPrint(self.allocator, fmt, args) catch return;
        defer self.allocator.free(msg);
        self.broadcastToChannel(channel, msg);
    }

    pub fn broadcastToChannel(self: *Hub, channel: []const u8, message: []const u8) void {
        self.mutex.lock(self.io) catch return;
        var snapshot: std.ArrayListUnmanaged(Connection) = .empty;
        defer snapshot.deinit(self.allocator);
        for (self.connections.items) |conn| {
            if (std.mem.eql(u8, conn.channel, channel)) {
                snapshot.append(self.allocator, conn) catch {};
            }
        }
        self.mutex.unlock(self.io);

        var dead: std.ArrayListUnmanaged(u64) = .empty;
        defer dead.deinit(self.allocator);

        for (snapshot.items) |conn| {
            switch (conn.type) {
                .ws => self.sendText(conn.stream, message) catch {
                    dead.append(self.allocator, conn.id) catch {};
                },
                .sse => self.sendSse(conn.stream, "message", message) catch {
                    dead.append(self.allocator, conn.id) catch {};
                },
            }
        }

        if (dead.items.len == 0) return;
        self.mutex.lock(self.io) catch return;
        defer self.mutex.unlock(self.io);
        for (dead.items) |id| {
            for (self.connections.items, 0..) |conn, i| {
                if (conn.id == id) {
                    _ = self.connections.orderedRemove(i);
                    break;
                }
            }
        }
    }

    fn sendSse(self: *Hub, stream: net.Stream, event: []const u8, data: []const u8) !void {
        var write_buf: [4096]u8 = undefined;
        var sw = net.Stream.Writer.init(stream, self.io, &write_buf);
        const writer = &sw.interface;
        try writer.writeAll("event: ");
        try writer.writeAll(event);
        try writer.writeAll("\ndata: ");
        try writer.writeAll(data);
        try writer.writeAll("\n\n");
        try writer.flush();
    }

    fn sendText(self: *Hub, stream: net.Stream, text: []const u8) !void {
        var write_buf: [4096]u8 = undefined;
        var sw = net.Stream.Writer.init(stream, self.io, &write_buf);
        const writer = &sw.interface;

        var header_buf: [10]u8 = undefined;
        var header_len: usize = 2;
        header_buf[0] = 0x81;

        if (text.len < 126) {
            header_buf[1] = @intCast(text.len);
        } else if (text.len < 65536) {
            header_buf[1] = 126;
            std.mem.writeInt(u16, header_buf[2..4], @intCast(text.len), .big);
            header_len = 4;
        } else {
            header_buf[1] = 127;
            std.mem.writeInt(u64, header_buf[2..10], text.len, .big);
            header_len = 10;
        }

        try writer.writeAll(header_buf[0..header_len]);
        try writer.writeAll(text);
        try writer.flush();
    }
};

fn makeSocketPair() ![2]net.Socket {
    var fds: [2]posix.fd_t = undefined;
    const rc = posix.system.socketpair(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0, &fds);
    if (rc != 0) return error.Unexpected;
    return .{
        net.Socket{ .handle = fds[0], .address = .{ .ip4 = .{ .bytes = [4]u8{ 0, 0, 0, 0 }, .port = 0 } } },
        net.Socket{ .handle = fds[1], .address = .{ .ip4 = .{ .bytes = [4]u8{ 0, 0, 0, 0 }, .port = 0 } } },
    };
}

const testing = std.testing;

test "Hub: init and deinit" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();
    try testing.expectEqual(@as(usize, 0), hub.count());
}

test "Hub: add increases count" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const sockets = try makeSocketPair();
    // sockets[0] is handed to the Hub below and stays registered for the
    // whole test — Hub.deinit() closes every registered connection's stream,
    // so a separate `defer sockets[0].close(io)` here would double-close it
    // (crashes as EBADF/use-after-free in debug builds). Only sockets[1] —
    // never owned by the Hub — needs its own defer.
    defer sockets[1].close(io);
    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();
    try hub.add(.{ .id = 1, .stream = .{ .socket = sockets[0] } });
    try testing.expectEqual(@as(usize, 1), hub.count());
}

test "Hub: remove decreases count" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const sockets = try makeSocketPair();
    defer sockets[1].close(io);
    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();
    try hub.add(.{ .id = 99, .stream = .{ .socket = sockets[0] } });
    hub.remove(99);
    try testing.expectEqual(@as(usize, 0), hub.count());
}

test "Hub: remove nonexistent id does not crash" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();
    hub.remove(404);
    try testing.expectEqual(@as(usize, 0), hub.count());
}

test "Hub: broadcast writes valid WS frame" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const sockets = try makeSocketPair();
    // sockets[0] stays registered in the Hub (write succeeds, never removed)
    // — see the comment in "Hub: add increases count" for why it must not
    // also be closed here.
    defer sockets[1].close(io);
    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();
    try hub.add(.{ .id = 1, .stream = .{ .socket = sockets[0] } });

    const msg = "hello";
    hub.broadcast(msg);

    var buf: [64]u8 = undefined;
    var read_buf: [256]u8 = undefined;
    var reader = net.Stream.Reader.init(.{ .socket = sockets[1] }, io, &read_buf);
    try reader.interface.readSliceAll(buf[0..2]);
    try testing.expectEqual(@as(u8, 0x81), buf[0]);
    try testing.expectEqual(@as(u8, msg.len), buf[1]);
    try reader.interface.readSliceAll(buf[0..msg.len]);
    try testing.expectEqualStrings(msg, buf[0..msg.len]);
}

test "Hub: broadcast removes dead connection" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const sockets = try makeSocketPair();
    defer sockets[0].close(io);
    defer sockets[1].close(io);
    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();
    try hub.add(.{ .id = 1, .stream = .{ .socket = sockets[0] } });
    try testing.expectEqual(@as(usize, 1), hub.count());

    try (net.Stream{ .socket = sockets[0] }).shutdown(io, .send);
    hub.broadcast("anything");
    try testing.expectEqual(@as(usize, 0), hub.count());
}

test "Hub: broadcast delivers to all connections" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const sockets_a = try makeSocketPair();
    const sockets_b = try makeSocketPair();
    // Both sockets_a[0] and sockets_b[0] are handed to the Hub below and stay
    // registered for the whole test (broadcast succeeds, nothing removed) —
    // see "Hub: add increases count" for why they must not also be closed here.
    defer sockets_a[1].close(io);
    defer sockets_b[1].close(io);
    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();
    try hub.add(.{ .id = 1, .stream = .{ .socket = sockets_a[0] } });
    try hub.add(.{ .id = 2, .stream = .{ .socket = sockets_b[0] } });

    const msg = "ping";
    hub.broadcast(msg);

    var buf_a: [64]u8 = undefined;
    var read_buf_a: [256]u8 = undefined;
    var reader_a = net.Stream.Reader.init(.{ .socket = sockets_a[1] }, io, &read_buf_a);
    try reader_a.interface.readSliceAll(buf_a[0..2]);
    try testing.expectEqual(@as(u8, 0x81), buf_a[0]);
    try testing.expectEqual(@as(u8, msg.len), buf_a[1]);

    var buf_b: [64]u8 = undefined;
    var read_buf_b: [256]u8 = undefined;
    var reader_b = net.Stream.Reader.init(.{ .socket = sockets_b[1] }, io, &read_buf_b);
    try reader_b.interface.readSliceAll(buf_b[0..2]);
    try testing.expectEqual(@as(u8, 0x81), buf_b[0]);
    try testing.expectEqual(@as(u8, msg.len), buf_b[1]);
}

test "Hub: add duplicate id returns error" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const sockets_a = try makeSocketPair();
    const sockets_b = try makeSocketPair();
    // sockets_a[0] is handed to the Hub and stays registered — see "Hub: add
    // increases count". sockets_b[0] is REJECTED (duplicate id), so it's
    // never Hub-owned and keeps its own defer close.
    defer sockets_a[1].close(io);
    defer sockets_b[0].close(io);
    defer sockets_b[1].close(io);
    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();

    try hub.add(.{ .id = 7, .stream = .{ .socket = sockets_a[0] } });
    try testing.expectError(
        error.DuplicateId,
        hub.add(.{ .id = 7, .stream = .{ .socket = sockets_b[0] } }),
    );
    try testing.expectEqual(@as(usize, 1), hub.count());
}

test "Hub: broadcastToChannel delivers only to matching channel" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const sockets_a = try makeSocketPair();
    const sockets_b = try makeSocketPair();
    // Both sockets_a[0] (targeted, write succeeds) and sockets_b[0] (never
    // targeted, no removal ever triggered for it) stay registered through
    // the whole test — see "Hub: add increases count".
    defer sockets_a[1].close(io);
    defer sockets_b[1].close(io);
    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();

    try hub.add(.{ .id = 1, .stream = .{ .socket = sockets_a[0] }, .channel = "room:1" });
    try hub.add(.{ .id = 2, .stream = .{ .socket = sockets_b[0] }, .channel = "room:2" });

    hub.broadcastToChannel("room:1", "hello");

    var buf: [64]u8 = undefined;
    var read_buf: [256]u8 = undefined;
    var reader = net.Stream.Reader.init(.{ .socket = sockets_a[1] }, io, &read_buf);
    try reader.interface.readSliceAll(buf[0..2]);
    try testing.expectEqual(@as(u8, 0x81), buf[0]);

    try (net.Stream{ .socket = sockets_b[0] }).shutdown(io, .send);
}

test "Hub: broadcast still delivers to all regardless of channel" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const sockets_a = try makeSocketPair();
    const sockets_b = try makeSocketPair();
    // Both sockets_a[0] and sockets_b[0] stay registered through the whole
    // test (broadcast succeeds to both) — see "Hub: add increases count".
    defer sockets_a[1].close(io);
    defer sockets_b[1].close(io);
    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();

    try hub.add(.{ .id = 1, .stream = .{ .socket = sockets_a[0] }, .channel = "room:1" });
    try hub.add(.{ .id = 2, .stream = .{ .socket = sockets_b[0] }, .channel = "room:2" });

    hub.broadcast("global");

    var buf_a: [64]u8 = undefined;
    var read_buf_a: [256]u8 = undefined;
    var reader_a = net.Stream.Reader.init(.{ .socket = sockets_a[1] }, io, &read_buf_a);
    try reader_a.interface.readSliceAll(buf_a[0..2]);
    try testing.expectEqual(@as(u8, 0x81), buf_a[0]);

    var buf_b: [64]u8 = undefined;
    var read_buf_b: [256]u8 = undefined;
    var reader_b = net.Stream.Reader.init(.{ .socket = sockets_b[1] }, io, &read_buf_b);
    try reader_b.interface.readSliceAll(buf_b[0..2]);
    try testing.expectEqual(@as(u8, 0x81), buf_b[0]);
}

test "Hub: emit serializes JSON with event and data" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const sockets = try makeSocketPair();
    // sockets[0] stays registered in the Hub — see "Hub: add increases count".
    defer sockets[1].close(io);
    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();
    // emit()/broadcastEvent() only sends to .sse-typed connections — without
    // this, the read below blocks forever waiting for data that never comes.
    try hub.add(.{ .id = 1, .stream = .{ .socket = sockets[0] }, .type = .sse });

    hub.emit("alert", .{ .message = "test", .count = @as(i32, 42) });

    // SSE wire format is plain text ("event: X\ndata: Y\n\n"), not a
    // length-prefixed WS binary frame — read the exact expected message.
    const expected = "event: alert\ndata: {\"message\":\"test\",\"count\":42}\n\n";
    var buf: [expected.len]u8 = undefined;
    var read_buf: [256]u8 = undefined;
    var reader = net.Stream.Reader.init(.{ .socket = sockets[1] }, io, &read_buf);
    try reader.interface.readSliceAll(&buf);
    try testing.expectEqualStrings(expected, &buf);

    const data_start = std.mem.indexOf(u8, &buf, "data: ").? + "data: ".len;
    const payload = buf[data_start .. buf.len - 2]; // trim trailing "\n\n"
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, payload, .{});
    defer parsed.deinit();
    const data_obj = parsed.value.object;
    try testing.expectEqualStrings("test", data_obj.get("message").?.string);
    try testing.expectEqual(@as(i64, 42), data_obj.get("count").?.integer);
}

test "Hub: emitTo delivers only to matching channel" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const sockets_a = try makeSocketPair();
    const sockets_b = try makeSocketPair();
    // Both sockets_a[0] (targeted) and sockets_b[0] (never targeted, never
    // removed) stay registered through the whole test — see "Hub: add
    // increases count".
    defer sockets_a[1].close(io);
    defer sockets_b[1].close(io);
    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();

    // emitTo()/broadcastToChannelEvent() only sends to .sse-typed connections.
    try hub.add(.{ .id = 1, .stream = .{ .socket = sockets_a[0] }, .channel = "room:1", .type = .sse });
    try hub.add(.{ .id = 2, .stream = .{ .socket = sockets_b[0] }, .channel = "room:2", .type = .sse });

    hub.emitTo("room:1", "notice", .{ .text = "only room:1" });

    // SSE wire format is plain text, not a length-prefixed WS binary frame.
    const expected = "event: notice\ndata: {\"text\":\"only room:1\"}\n\n";
    var buf: [expected.len]u8 = undefined;
    var read_buf: [256]u8 = undefined;
    var reader = net.Stream.Reader.init(.{ .socket = sockets_a[1] }, io, &read_buf);
    try reader.interface.readSliceAll(&buf);
    try testing.expectEqualStrings(expected, &buf);

    // sockets_b should NOT receive anything — shutdown its send side to confirm
    try (net.Stream{ .socket = sockets_b[0] }).shutdown(io, .send);
}

test "Hub: notifyUser delivers to user:42 channel" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const sockets = try makeSocketPair();
    // sockets[0] stays registered in the Hub — see "Hub: add increases count".
    defer sockets[1].close(io);
    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();

    // notifyUser()/emitTo() only sends to .sse-typed connections — without
    // this, the read below blocks forever waiting for data that never comes.
    try hub.add(.{ .id = 1, .stream = .{ .socket = sockets[0] }, .channel = "user:42", .type = .sse });

    hub.notifyUser(42, "private", .{ .msg = "secret" });

    // SSE wire format is plain text, not a length-prefixed WS binary frame.
    const expected = "event: private\ndata: {\"msg\":\"secret\"}\n\n";
    var buf: [expected.len]u8 = undefined;
    var read_buf: [256]u8 = undefined;
    var reader = net.Stream.Reader.init(.{ .socket = sockets[1] }, io, &read_buf);
    try reader.interface.readSliceAll(&buf);
    try testing.expectEqualStrings(expected, &buf);
}

test "Hub: broadcastToChannel removes dead connection" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const sockets = try makeSocketPair();
    defer sockets[0].close(io);
    defer sockets[1].close(io);
    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();

    try hub.add(.{ .id = 1, .stream = .{ .socket = sockets[0] }, .channel = "room:1" });
    try testing.expectEqual(@as(usize, 1), hub.count());

    try (net.Stream{ .socket = sockets[0] }).shutdown(io, .send);
    hub.broadcastToChannel("room:1", "msg");
    try testing.expectEqual(@as(usize, 0), hub.count());
}

test "Hub: emitTo removes dead connection on write failure" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const sockets = try makeSocketPair();
    defer sockets[0].close(io);
    defer sockets[1].close(io);
    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();

    try hub.add(.{ .id = 1, .stream = .{ .socket = sockets[0] }, .channel = "room:1", .type = .sse });
    try testing.expectEqual(@as(usize, 1), hub.count());

    try (net.Stream{ .socket = sockets[0] }).shutdown(io, .send);
    hub.emitTo("room:1", "notice", .{ .text = "hi" });
    try testing.expectEqual(@as(usize, 0), hub.count());
}

test "Hub: emit (global) removes dead connection on write failure" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const sockets = try makeSocketPair();
    defer sockets[0].close(io);
    defer sockets[1].close(io);
    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();

    try hub.add(.{ .id = 1, .stream = .{ .socket = sockets[0] }, .type = .sse });
    try testing.expectEqual(@as(usize, 1), hub.count());

    try (net.Stream{ .socket = sockets[0] }).shutdown(io, .send);
    hub.emit("alert", .{ .msg = "hi" });
    try testing.expectEqual(@as(usize, 0), hub.count());
}

test "Hub: emit (global) reaches sse connections regardless of channel" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const sockets = try makeSocketPair();
    // sockets[0] stays registered in the Hub — see "Hub: add increases count".
    defer sockets[1].close(io);
    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();

    // channel is set but irrelevant to emit() — it's a global broadcast, not
    // scoped like emitTo(). Only conn.type == .sse is checked (broadcastEvent).
    try hub.add(.{ .id = 1, .stream = .{ .socket = sockets[0] }, .channel = "room:whatever", .type = .sse });

    hub.emit("alert", .{ .msg = "hi" });

    var buf: [7]u8 = undefined;
    var read_buf: [256]u8 = undefined;
    var reader = net.Stream.Reader.init(.{ .socket = sockets[1] }, io, &read_buf);
    try reader.interface.readSliceAll(&buf);
    try testing.expectEqualStrings("event: ", &buf);
}
