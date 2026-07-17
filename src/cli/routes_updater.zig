const std = @import("std");
const fs_utils = @import("fs_utils.zig");

pub fn updateMainZig(
    io: std.Io,
    allocator: std.mem.Allocator,
    root_dir: std.Io.Dir,
    feature: []const u8,
    plural: []const u8,
    api: bool,
) !void {
    const main_path = "src/main.zig";

    // Read existing main.zig content
    const existing = root_dir.readFileAlloc(io, main_path, allocator, .limited(64 * 1024)) catch {
        std.debug.print("warning: src/main.zig not found, skipping routes update\n", .{});
        return;
    };
    defer allocator.free(existing);

    // 1. Add feature import (whole module, calls go through .controller.) after "const home = features.home;"
    const import_line = try std.fmt.allocPrint(
        allocator,
        "const {s} = features.{s};\n",
        .{ feature, feature },
    );
    defer allocator.free(import_line);

    // Look for import marker — try home first (non-API), then features import (API)
    const home_marker = "const home = features.home;\n";
    const features_marker = "const features = @import(\"features\");\n";
    const home_pos = std.mem.indexOf(u8, existing, home_marker);
    const features_pos = std.mem.indexOf(u8, existing, features_marker);
    const after_imports = home_pos orelse features_pos orelse {
        std.debug.print("warning: could not find import marker in main.zig\n", .{});
        return;
    };

    const marker = if (home_pos != null) home_marker else features_marker;
    const insert_pos = after_imports + marker.len;
    const with_import = try std.mem.concat(allocator, u8, &.{
        existing[0..insert_pos],
        import_line,
        existing[insert_pos..],
    });
    defer allocator.free(with_import);

    // 2. Add CRUD routes before .onError(
    // SSR mode: GET index, new, edit + POST create, update, delete
    // API mode: GET index, show + POST create + PATCH update + DELETE delete
    const routes = if (api)
        try std.fmt.allocPrint(
            allocator,
            "        .get(\"/{s}\", {s}.controller.index, .{{}})\n" ++
                "        .get(\"/{s}/:id\", {s}.controller.show, .{{}})\n" ++
                "        .post(\"/{s}\", {s}.controller.create, .{{}})\n" ++
                "        .patch(\"/{s}/:id\", {s}.controller.update, .{{}})\n" ++
                "        .delete(\"/{s}/:id\", {s}.controller.delete, .{{}})\n",
            .{
                plural, feature,
                plural, feature,
                plural, feature,
                plural, feature,
                plural, feature,
            },
        )
    else
        try std.fmt.allocPrint(
            allocator,
            "        .get(\"/{s}\", {s}.controller.index, .{{}})\n" ++
                "        .get(\"/{s}/new\", {s}.controller.newForm, .{{}})\n" ++
                "        .get(\"/{s}/:id/edit\", {s}.controller.edit, .{{}})\n" ++
                "        .post(\"/{s}/create\", {s}.controller.create, .{{}})\n" ++
                "        .post(\"/{s}/:id/update\", {s}.controller.update, .{{}})\n" ++
                "        .post(\"/{s}/:id/delete\", {s}.controller.delete, .{{}})\n",
            .{
                plural, feature,
                plural, feature,
                plural, feature,
                plural, feature,
                plural, feature,
                plural, feature,
            },
        );
    defer allocator.free(routes);

    // Find .onError( marker to insert routes just before it
    const onerror_marker = "        .onError(";
    const onerror_pos = std.mem.indexOf(u8, with_import, onerror_marker) orelse {
        std.debug.print("warning: could not find .onError( in main.zig\n", .{});
        return;
    };

    // Build final content with routes inserted before .onError(
    const final_content = try std.mem.concat(allocator, u8, &.{
        with_import[0..onerror_pos],
        routes,
        with_import[onerror_pos..],
    });
    defer allocator.free(final_content);

    try fs_utils.writeFile(io, root_dir, main_path, final_content);
}
