const std = @import("std");
const context_mod = @import("context.zig");
const Ctx = context_mod.Ctx;
const RequestKind = Ctx.RequestKind;

fn makeCtx(alc: std.mem.Allocator, headers: []const [2][]const u8) !Ctx {
    var ctx = Ctx{
        .request = undefined,
        .arena = alc,
        .params = .{},
    };
    for (headers) |h| {
        try ctx._headers.put(alc, h[0], h[1]);
    }
    return ctx;
}

test "requestKind: HX-Request-Type=partial -> .fragment (htmx 4.0)" {
    const alc = std.testing.allocator;
    var ctx = try makeCtx(alc, &.{.{ "HX-Request-Type", "partial" }});
    defer ctx._headers.deinit(alc);

    try std.testing.expectEqual(RequestKind.fragment, ctx.requestKind());
}

test "requestKind: HX-Request-Type=full -> .full (htmx 4.0)" {
    const alc = std.testing.allocator;
    var ctx = try makeCtx(alc, &.{.{ "HX-Request-Type", "full" }});
    defer ctx._headers.deinit(alc);

    try std.testing.expectEqual(RequestKind.full, ctx.requestKind());
}

test "requestKind: no HX-Request-Type, HX-Boosted present -> .boosted (htmx 2.x)" {
    const alc = std.testing.allocator;
    var ctx = try makeCtx(alc, &.{.{ "HX-Boosted", "true" }});
    defer ctx._headers.deinit(alc);

    try std.testing.expectEqual(RequestKind.boosted, ctx.requestKind());
}

test "requestKind: no HX-Request-Type, HX-Request present -> .fragment (htmx 2.x)" {
    const alc = std.testing.allocator;
    var ctx = try makeCtx(alc, &.{.{ "HX-Request", "true" }});
    defer ctx._headers.deinit(alc);

    try std.testing.expectEqual(RequestKind.fragment, ctx.requestKind());
}

test "requestKind: no htmx headers at all -> .full (plain navigation)" {
    const alc = std.testing.allocator;
    var ctx = try makeCtx(alc, &.{});
    defer ctx._headers.deinit(alc);

    try std.testing.expectEqual(RequestKind.full, ctx.requestKind());
}

test "requestKind: HX-Request-Type wins over HX-Boosted/HX-Request when present" {
    const alc = std.testing.allocator;
    var ctx = try makeCtx(alc, &.{
        .{ "HX-Request-Type", "partial" },
        .{ "HX-Boosted", "true" },
        .{ "HX-Request", "true" },
    });
    defer ctx._headers.deinit(alc);

    try std.testing.expectEqual(RequestKind.fragment, ctx.requestKind());
}

test "isHtmx()/isBoosted() unaffected by the requestKind() addition (no regression)" {
    const alc = std.testing.allocator;
    var ctx = try makeCtx(alc, &.{ .{ "HX-Request", "true" }, .{ "HX-Boosted", "true" } });
    defer ctx._headers.deinit(alc);

    try std.testing.expect(ctx.isHtmx());
    try std.testing.expect(ctx.isBoosted());
}

test "isHtmx()/isBoosted() false when headers absent (no regression)" {
    const alc = std.testing.allocator;
    var ctx = try makeCtx(alc, &.{});
    defer ctx._headers.deinit(alc);

    try std.testing.expect(!ctx.isHtmx());
    try std.testing.expect(!ctx.isBoosted());
}
