const std = @import("std");
const context_mod = @import("context.zig");
const Ctx = context_mod.Ctx;
const Response = context_mod.Response;
const app_mod = @import("app.zig");
const Server = app_mod.Server;
const extractors = @import("extractors.zig");
const Path = extractors.Path;
const Form = extractors.Form;

const NoDeco = struct {};

// Drives a registered route the same way a real request would: resolves the
// route through the (public) router, builds a Ctx the way workerLoop does
// (including `_decorations`, matching app.zig's `@sizeOf(T) == 0` check),
// and invokes the resulting Handler — exercising the real Server.get/post
// dispatch decision (Handler passthrough / buildAutoWrapper / buildWrapper),
// not a reimplementation of it.
fn dispatch(
    comptime T: type,
    s: *Server(T),
    method: std.http.Method,
    path: []const u8,
    alc: std.mem.Allocator,
    body: ?[]const u8,
) !Response {
    const match = (try s.router.match(method, path, alc)).?;
    var ctx = Ctx{
        .request = undefined,
        .arena = alc,
        .params = match.params,
        .body = body,
        ._decorations = if (@sizeOf(T) == 0) null else @as(*const anyopaque, @ptrCast(&s.decorations)),
    };
    return match.handler(&ctx);
}

const UpdateForm = struct { name: []const u8 };

fn getById(id: Path(i64, "id"), c: *Ctx) !Response {
    return c.text(try std.fmt.allocPrint(c.arena, "{d}", .{id.value}), .{});
}

fn formOnly(form: Form(UpdateForm), c: *Ctx) !Response {
    return c.text(form.value.name, .{});
}

fn comboCtxFirst(c: *Ctx, id: Path(i64, "id"), form: Form(UpdateForm)) !Response {
    return c.text(try std.fmt.allocPrint(c.arena, "{d}:{s}", .{ id.value, form.value.name }), .{});
}

fn comboCtxLast(id: Path(i64, "id"), form: Form(UpdateForm), c: *Ctx) !Response {
    return c.text(try std.fmt.allocPrint(c.arena, "{d}:{s}", .{ id.value, form.value.name }), .{});
}

fn oldStyle(c: *Ctx) !Response {
    return c.text("old", .{});
}

const Deco = struct { greeting: []const u8 };

fn decoHandler(c: *Ctx, greeting: []const u8) !Response {
    return c.text(greeting, .{});
}

test "Path extractor: success" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alc = arena.allocator();

    var s = Server(NoDeco).init();
    defer s.deinit();
    _ = s.get("/items/:id", getById, .{});

    const resp = try dispatch(NoDeco, &s, .GET, "/items/42", alc, null);
    try std.testing.expectEqual(std.http.Status.ok, resp.status);
    try std.testing.expectEqualStrings("42", resp.body.?);
}

test "Path extractor: invalid int -> 400" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alc = arena.allocator();

    var s = Server(NoDeco).init();
    defer s.deinit();
    _ = s.get("/items/:id", getById, .{});

    const resp = try dispatch(NoDeco, &s, .GET, "/items/abc", alc, null);
    try std.testing.expectEqual(std.http.Status.bad_request, resp.status);
}

test "Path extractor: missing param -> 400" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alc = arena.allocator();

    var s = Server(NoDeco).init();
    defer s.deinit();
    // Route deliberately has no `:id` segment, so ctx.params won't have it —
    // exercises the extractor's own "missing" branch.
    _ = s.get("/items", getById, .{});

    const resp = try dispatch(NoDeco, &s, .GET, "/items", alc, null);
    try std.testing.expectEqual(std.http.Status.bad_request, resp.status);
}

test "Form extractor: success" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alc = arena.allocator();

    var s = Server(NoDeco).init();
    defer s.deinit();
    _ = s.post("/form", formOnly, .{});

    const resp = try dispatch(NoDeco, &s, .POST, "/form", alc, "name=hello");
    try std.testing.expectEqual(std.http.Status.ok, resp.status);
    try std.testing.expectEqualStrings("hello", resp.body.?);
}

test "Form extractor: parse failure -> 400" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alc = arena.allocator();

    var s = Server(NoDeco).init();
    defer s.deinit();
    _ = s.post("/form", formOnly, .{});

    // No body at all -> Ctx.parseForm returns error.BodyEmpty.
    const resp = try dispatch(NoDeco, &s, .POST, "/form", alc, null);
    try std.testing.expectEqual(std.http.Status.bad_request, resp.status);
}

test "combo: Path + Form + *Ctx, *Ctx first — order does not matter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alc = arena.allocator();

    var s = Server(NoDeco).init();
    defer s.deinit();
    _ = s.post("/items/:id", comboCtxFirst, .{});

    const resp = try dispatch(NoDeco, &s, .POST, "/items/7", alc, "name=zig");
    try std.testing.expectEqual(std.http.Status.ok, resp.status);
    try std.testing.expectEqualStrings("7:zig", resp.body.?);
}

test "combo: Path + Form + *Ctx, *Ctx last — order does not matter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alc = arena.allocator();

    var s = Server(NoDeco).init();
    defer s.deinit();
    _ = s.post("/items/:id", comboCtxLast, .{});

    const resp = try dispatch(NoDeco, &s, .POST, "/items/7", alc, "name=zig");
    try std.testing.expectEqual(std.http.Status.ok, resp.status);
    try std.testing.expectEqualStrings("7:zig", resp.body.?);
}

test "old-style fn(*Ctx) handler is unaffected by the extractor dispatch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alc = arena.allocator();

    var s = Server(NoDeco).init();
    defer s.deinit();
    _ = s.get("/old", oldStyle, .{});

    const resp = try dispatch(NoDeco, &s, .GET, "/old", alc, null);
    try std.testing.expectEqual(std.http.Status.ok, resp.status);
    try std.testing.expectEqualStrings("old", resp.body.?);
}

test "loose-type decoration handler (buildWrapper) is unaffected by the extractor dispatch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alc = arena.allocator();

    var s = Server(Deco).init();
    defer s.deinit();
    s.decorations = .{ .greeting = "hi-deco" };
    _ = s.get("/deco", decoHandler, .{});

    const resp = try dispatch(Deco, &s, .GET, "/deco", alc, null);
    try std.testing.expectEqual(std.http.Status.ok, resp.status);
    try std.testing.expectEqualStrings("hi-deco", resp.body.?);
}
