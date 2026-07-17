const std = @import("std");
const fs_utils = @import("fs_utils.zig");

pub fn run(io: std.Io) !void {
    const root_dir = try fs_utils.findProjectRoot(io);

    std.debug.print("Updating spider dependency...\n", .{});

    var child = try std.process.spawn(io, .{
        .argv = &.{ "zig", "fetch", "--save", "git+https://github.com/llllOllOOll/spider" },
        .cwd = .{ .dir = root_dir },
    });
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) {
            std.debug.print("error: zig fetch failed with exit code {d}\n", .{code});
            return error.ZigFetchFailed;
        },
        else => {
            std.debug.print("error: zig fetch terminated abnormally\n", .{});
            return error.ZigFetchFailed;
        },
    }

    std.debug.print("Done! spider dependency updated.\n", .{});
}
