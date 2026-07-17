const std = @import("std");
const fs_utils = @import("fs_utils.zig");

fn removeLine(allocator: std.mem.Allocator, content: []const u8, marker: []const u8) ![]u8 {
    const pos = std.mem.indexOf(u8, content, marker) orelse return try allocator.dupe(u8, content);
    const line_start = if (std.mem.lastIndexOfLinear(u8, content[0..pos], "\n")) |nl| nl + 1 else 0;
    const line_end = if (std.mem.indexOf(u8, content[pos..], "\n")) |nl| pos + nl + 1 else content.len;
    return try std.mem.concat(allocator, u8, &.{
        content[0..line_start],
        content[line_end..],
    });
}

fn uncommentLine(allocator: std.mem.Allocator, content: []const u8, marker: []const u8) ![]u8 {
    const replacement = marker["// ".len..];
    const pos = std.mem.indexOf(u8, content, marker) orelse return try allocator.dupe(u8, content);
    return try std.mem.concat(allocator, u8, &.{
        content[0..pos],
        replacement,
        content[pos + marker.len ..],
    });
}

pub fn updateMainZig(
    io: std.Io,
    allocator: std.mem.Allocator,
    root_dir: std.Io.Dir,
    provider: []const u8,
    provider_config: []const u8,
    api: bool,
) !void {
    const main_path = "src/main.zig";

    const existing = root_dir.readFileAlloc(io, main_path, allocator, .limited(64 * 1024)) catch {
        std.debug.print("warning: src/main.zig not found, skipping auth update\n", .{});
        return;
    };
    defer allocator.free(existing);

    var result = try allocator.dupe(u8, existing);
    defer allocator.free(result);

    // 1. Remove "_ = allocator;" line
    {
        const r = try removeLine(allocator, result, "_ = allocator;");
        allocator.free(result);
        result = r;
    }

    // 2. Remove "_ = io;" line
    {
        const r = try removeLine(allocator, result, "_ = io;");
        allocator.free(result);
        result = r;
    }

    // 3. Uncomment "// const db = spider.pg;"
    {
        const r = try uncommentLine(allocator, result, "// const db = spider.pg;");
        allocator.free(result);
        result = r;
    }

    // 4. Uncomment DB init/deinit lines
    {
        const r = try uncommentLine(allocator, result, "// try db.init(allocator, io, .{});");
        allocator.free(result);
        result = r;
    }
    {
        const r = try uncommentLine(allocator, result, "// defer db.deinit();");
        allocator.free(result);
        result = r;
    }

    // 5. Add "const auth = features.auth;" after "const home = features.home;"
    if (!api) {
        const import_marker = "const home = features.home;\n";
        if (std.mem.indexOf(u8, result, import_marker)) |pos| {
            const auth_import = "const auth = features.auth;\n";
            const insert_pos = pos + import_marker.len;
            const r = try std.mem.concat(allocator, u8, &.{
                result[0..insert_pos],
                auth_import,
                result[insert_pos..],
            });
            allocator.free(result);
            result = r;
        }
    }

    // 6. Add provider init block before "var server = spider.app(.{});"
    const server_marker = "var server = spider.app(.{});";
    const Provider = try std.fmt.allocPrint(allocator, "{c}{s}", .{ std.ascii.toUpper(provider[0]), provider[1..] });
    defer allocator.free(Provider);

    const provider_block = try std.fmt.allocPrint(
        allocator,
        "    var {s}_auth = try spider.{s}.{s}.init(allocator, io, .{{\n{s}\n    }});\n" ++
            "    defer {s}_auth.deinit();\n\n",
        .{ provider, provider, Provider, provider_config, provider },
    );
    defer allocator.free(provider_block);

    if (std.mem.indexOf(u8, result, server_marker)) |pos| {
        const line_start = if (std.mem.lastIndexOfLinear(u8, result[0..pos], "\n")) |nl| nl + 1 else 0;
        const r = try std.mem.concat(allocator, u8, &.{
            result[0..line_start],
            provider_block,
            result[line_start..],
        });
        allocator.free(result);
        result = r;
    }

    // 7. Add middleware + auth routes before first route or .onError(
    //    Try .get("/", home.index, .{}) first (non-API), fall back to .onError( (API)
    const home_route_marker = ".get(\"/\", home.controller.index, .{})";
    const onerror_marker = ".onError(";
    const routes_marker = if (std.mem.indexOf(u8, result, home_route_marker)) |_| home_route_marker else onerror_marker;
    const auth_routes = if (api)
        try std.fmt.allocPrint(
            allocator,
            "        .use({s}_auth.middleware())\n",
            .{provider},
        )
    else
        try std.fmt.allocPrint(
            allocator,
            "        .use({s}_auth.middleware())\n" ++
                "        .get(\"/auth/login\", {s}_auth.loginHandler(), .{{}})\n" ++
                "        .get(\"/auth/callback\", {s}_auth.callbackHandler(), .{{}})\n" ++
                "        .get(\"/auth/session\", auth.controller.session, .{{}})\n" ++
                "        .get(\"/auth/logout\", auth.controller.logout, .{{}})\n",
            .{ provider, provider, provider },
        );
    defer allocator.free(auth_routes);

    if (std.mem.indexOf(u8, result, routes_marker)) |pos| {
        const line_start = if (std.mem.lastIndexOfLinear(u8, result[0..pos], "\n")) |nl| nl + 1 else 0;
        const r = try std.mem.concat(allocator, u8, &.{
            result[0..line_start],
            auth_routes,
            result[line_start..],
        });
        allocator.free(result);
        result = r;
    }

    try fs_utils.writeFile(io, root_dir, main_path, result);
}
