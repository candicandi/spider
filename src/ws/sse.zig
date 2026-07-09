const std = @import("std");
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
        var ch_buf: [32]u8 = undefined;
        const channel = try std.fmt.bufPrint(&ch_buf, "user:{d}", .{user_id});
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
