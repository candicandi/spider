const std = @import("std");
const Router = @import("router.zig").Router;
const Handler = @import("router.zig").Handler;
const MiddlewareFn = @import("../core/context.zig").MiddlewareFn;
const sse_mod = @import("../ws/sse.zig");
const Sse = sse_mod.Sse;

const PathMiddlewareEntry = struct {
    path: []const u8,
    middleware: MiddlewareFn,
};

// Mirrors app.zig's private RouteMiddlewareEntry exactly (path + method + middlewares).
// Duplicated locally rather than imported: app.zig already imports Group for mount()'s
// parameter type, so importing app.zig back from here would create a circular @import.
const RouteMiddlewareEntry = struct {
    path: []const u8,
    method: std.http.Method,
    middlewares: []const MiddlewareFn,
};

fn hasRbac(comptime config: anytype) bool {
    return (@hasField(@TypeOf(config), "roles") and config.roles.len > 0) or
        (@hasField(@TypeOf(config), "org_roles") and config.org_roles.len > 0);
}

pub const Group = struct {
    router: *Router,
    prefix: []const u8,
    path_middlewares: [32]PathMiddlewareEntry = undefined,
    path_middleware_count: usize = 0,
    route_middlewares: std.ArrayList(RouteMiddlewareEntry) = .empty,
    has_sse: bool = false,

    pub fn init(prefix: []const u8) Group {
        const r = std.heap.page_allocator.create(Router) catch @panic("OOM");
        r.* = Router.init(std.heap.page_allocator) catch @panic("OOM");
        return .{
            .router = r,
            .prefix = prefix,
            .path_middleware_count = 0,
            .route_middlewares = .empty,
        };
    }

    pub fn get(self: *Group, path: []const u8, handler: Handler, comptime config: anytype) *Group {
        const full = self.join(path) catch unreachable;
        self.router.add(.GET, full, handler) catch unreachable;
        self.registerRoute(.GET, path, full, config);
        return self;
    }

    pub fn post(self: *Group, path: []const u8, handler: Handler, comptime config: anytype) *Group {
        const full = self.join(path) catch unreachable;
        self.router.add(.POST, full, handler) catch unreachable;
        self.registerRoute(.POST, path, full, config);
        return self;
    }

    pub fn put(self: *Group, path: []const u8, handler: Handler, comptime config: anytype) *Group {
        const full = self.join(path) catch unreachable;
        self.router.add(.PUT, full, handler) catch unreachable;
        self.registerRoute(.PUT, path, full, config);
        return self;
    }

    pub fn delete(self: *Group, path: []const u8, handler: Handler, comptime config: anytype) *Group {
        const full = self.join(path) catch unreachable;
        self.router.add(.DELETE, full, handler) catch unreachable;
        self.registerRoute(.DELETE, path, full, config);
        return self;
    }

    // No RBAC config param — Server.sse() doesn't take one either, so this
    // isn't a new inconsistency. buildHandler lives in ws/sse.zig (not
    // app.zig) specifically so this can call it without a circular import.
    pub fn sse(self: *Group, path: []const u8, comptime handler: fn (*Sse) anyerror!void) *Group {
        const full = self.join(path) catch unreachable;
        self.router.add(.GET, full, sse_mod.buildHandler(handler)) catch unreachable;
        self.freeJoined(path, full);
        self.has_sse = true;
        return self;
    }

    pub fn useAt(self: *Group, path_suffix: []const u8, m: MiddlewareFn) *Group {
        const full = self.join(path_suffix) catch return self;
        if (self.path_middleware_count >= self.path_middlewares.len) {
            std.debug.panic(
                "Group.useAt: path middleware capacity exceeded (max {d}) registering \"{s}\" on group prefix \"{s}\"",
                .{ self.path_middlewares.len, full, self.prefix },
            );
        }
        self.path_middlewares[self.path_middleware_count] = .{ .path = full, .middleware = m };
        self.path_middleware_count += 1;
        return self;
    }

    // full is only freed when no RBAC config keeps it alive as a route_middlewares key
    // (see freeJoined below); when RBAC is present, full's lifetime must match Server's
    // route_middlewares entries, i.e. it lives for the process, same as useAt() paths.
    fn registerRoute(self: *Group, method: std.http.Method, path: []const u8, full: []const u8, comptime config: anytype) void {
        if (!comptime hasRbac(config)) {
            self.freeJoined(path, full);
            return;
        }
        // Mirrors Server.get/.post/.put/.delete's RBAC-wrapping exactly (app.zig):
        // one independent route_middlewares append per role kind, same allocator,
        // same catch-unreachable/catch-{} split.
        if (comptime (@hasField(@TypeOf(config), "roles") and config.roles.len > 0)) {
            const rbac_mw = @import("../modules/rbac.zig").requireRoles(config.roles);
            const mw_slice = std.heap.page_allocator.alloc(MiddlewareFn, 1) catch unreachable;
            mw_slice[0] = rbac_mw;
            self.route_middlewares.append(std.heap.page_allocator, .{
                .path = full,
                .method = method,
                .middlewares = mw_slice,
            }) catch {};
        }
        if (comptime (@hasField(@TypeOf(config), "org_roles") and config.org_roles.len > 0)) {
            const rbac_mw = @import("../modules/rbac.zig").requireOrgRoles(config.org_roles);
            const mw_slice = std.heap.page_allocator.alloc(MiddlewareFn, 1) catch unreachable;
            mw_slice[0] = rbac_mw;
            self.route_middlewares.append(std.heap.page_allocator, .{
                .path = full,
                .method = method,
                .middlewares = mw_slice,
            }) catch {};
        }
    }

    // join() only allocates when it returns a freshly built "prefix + path" buffer;
    // its two early-return paths hand back a caller-owned slice (path or self.prefix)
    // that must never be freed.
    fn freeJoined(self: Group, path: []const u8, full: []const u8) void {
        if (full.ptr == path.ptr) return;
        if (full.ptr == self.prefix.ptr) return;
        self.router.allocator.free(full);
    }

    fn join(self: Group, path: []const u8) ![]const u8 {
        if (self.prefix.len == 0) return path;
        if (path.len == 0) return self.prefix;
        const prefix_has_slash = self.prefix[self.prefix.len - 1] == '/';
        const path_has_slash = path[0] == '/';
        if (prefix_has_slash and path_has_slash) {
            return std.fmt.allocPrint(self.router.allocator, "{s}{s}", .{ self.prefix, path[1..] });
        }
        if (!prefix_has_slash and !path_has_slash) {
            return std.fmt.allocPrint(self.router.allocator, "{s}/{s}", .{ self.prefix, path });
        }
        return std.fmt.allocPrint(self.router.allocator, "{s}{s}", .{ self.prefix, path });
    }
};
