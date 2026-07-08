const std = @import("std");
const Ctx = @import("../core/context.zig").Ctx;
const NextFn = @import("../core/context.zig").NextFn;
const Response = @import("../core/context.zig").Response;

const reset = "\x1b[0m";
const green = "\x1b[32m";
const blue = "\x1b[34m";
const yellow = "\x1b[33m";
const red = "\x1b[31m";

fn statusColor(status: u16) []const u8 {
    if (status >= 100 and status < 200) return blue;
    if (status >= 200 and status < 300) return green;
    if (status >= 300 and status < 400) return blue;
    if (status >= 400 and status < 500) return yellow;
    if (status >= 500) return red;
    return reset;
}

fn formatMs(ns: u64, buf: []u8) []const u8 {
    const ms = @as(f64, @floatFromInt(ns)) / 1_000_000.0;
    return std.fmt.bufPrint(buf, "{d:.1}ms", .{ms}) catch "?ms";
}

pub fn middleware(c: *Ctx, next: NextFn) anyerror!Response {
    const method = @tagName(c.request.head.method);
    const path = c.getPath();

    const start = std.Io.Clock.now(.real, c._io);
    const resp = next(c) catch |err| {
        const end = std.Io.Clock.now(.real, c._io);
        const ns_diff = end.nanoseconds - start.nanoseconds;
        const ns: u64 = if (ns_diff < 0) 0 else @intCast(ns_diff);
        var lat_buf: [32]u8 = undefined;
        const lat = formatMs(ns, &lat_buf);
        // The final HTTP status isn't known here: it's decided by .onError()'s
        // handler (or the default 500 fallback) *after* runChain() returns
        // control to app.zig's dispatch loop, which is outside this
        // middleware's visibility. Report the error itself instead of
        // guessing a status code that may not match what dispatch picks.
        std.debug.print("{s}[ERR]{s} {s: <6} {s}  {s}  (error: {s})\n", .{ red, reset, method, path, lat, @errorName(err) });
        return err;
    };

    const end = std.Io.Clock.now(.real, c._io);
    const status_int: u16 = @intFromEnum(resp.status);
    const sc = statusColor(status_int);

    const ns_diff = end.nanoseconds - start.nanoseconds;
    const ns: u64 = if (ns_diff < 0) 0 else @intCast(ns_diff);

    if (resp.raw) {
        std.debug.print("{s}[{d}]{s} {s: <6} {s}  open\n", .{ sc, status_int, reset, method, path });
    } else {
        var lat_buf: [32]u8 = undefined;
        const lat = formatMs(ns, &lat_buf);
        std.debug.print("{s}[{d}]{s} {s: <6} {s}  {s}\n", .{ sc, status_int, reset, method, path, lat });
    }

    return resp;
}
