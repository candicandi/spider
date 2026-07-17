const std = @import("std");

pub fn run(io: std.Io) !void {
    std.debug.print("Updating spider CLI...\n", .{});

    var child = try std.process.spawn(io, .{
        .argv = &.{ "sh", "-c", "curl -fsSL https://spiderme.org/install.sh | bash" },
    });
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) {
            std.debug.print("error: install script failed with exit code {d}\n", .{code});
            return error.SelfUpdateFailed;
        },
        else => {
            std.debug.print("error: install script terminated abnormally\n", .{});
            return error.SelfUpdateFailed;
        },
    }
}
