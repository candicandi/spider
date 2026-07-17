const std = @import("std");
const new = @import("new.zig");
const generate = @import("generate.zig");
const install = @import("install.zig");
const generate_vapid = @import("generate_vapid.zig");
const migrate = @import("migrate.zig");
const update = @import("update.zig");
const self_update = @import("self_update.zig");

const version = "0.6.9";

const usage =
    \\Spider CLI — spiderme.org
    \\
    \\Usage:
    \\  spider new <app_name> [--daisyui] [--skip-downloads] [--api] [--no-db]
    \\                                 Create a new Spider project
    \\    --daisyui                    Include DaisyUI preset
    \\    --skip-downloads             Skip binary downloads (tailwindcss, alpine, htmx, icons)
    \\    --api                        API-only project (no HTML views)
    \\    --no-db                      Skip database setup
    \\    --pg                         Use PostgreSQL instead of default SQLite
    \\  spider generate <subcommand>   Generate code (aliases: g)
    \\  spider g <subcommand>          Alias for generate
    \\    feature <name> [--api]        Generate a new feature (--api for REST API)
    \\    auth [--provider=keycloak|google] [--api]  Generate auth feature (--api for bearer-only)
    \\  spider generate-vapid           Generate VAPID keys for Web Push
    \\  spider install                 Download frontend assets (tailwindcss, alpine, htmx, icons)
    \\  spider migrate                 Run pending database migrations
    \\  spider update                  Update the spider dependency in this project
    \\  spider self-update             Update the spider CLI itself
    \\  spider version                 Show CLI version
    \\  spider help                    Show this help
    \\
;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.next(); // skip program name

    const command = args.next() orelse {
        std.debug.print("{s}", .{usage});
        return;
    };

    if (std.mem.eql(u8, command, "new")) {
        var use_daisyui = false;
        var skip_downloads = false;
        var api_only = false;
        var no_db = false;
        var use_pg = false;
        var app_name_opt: ?[]const u8 = null;
        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "--daisyui")) {
                use_daisyui = true;
            } else if (std.mem.eql(u8, arg, "--skip-downloads")) {
                skip_downloads = true;
            } else if (std.mem.eql(u8, arg, "--api")) {
                api_only = true;
            } else if (std.mem.eql(u8, arg, "--no-db")) {
                no_db = true;
            } else if (std.mem.eql(u8, arg, "--pg")) {
                use_pg = true;
            } else {
                app_name_opt = arg;
            }
        }
        const app_name = app_name_opt orelse {
            std.debug.print("error: missing app name\nUsage: spider new <app_name>\n", .{});
            return error.MissingAppName;
        };
        try new.run(io, allocator, app_name, use_daisyui, skip_downloads, api_only, no_db, use_pg);
    } else if (std.mem.eql(u8, command, "generate")) {
        const subcommand = args.next() orelse {
            std.debug.print("Usage: spider generate <subcommand>\n", .{});
            return;
        };
        try generate.run(io, allocator, subcommand, &args);
    } else if (std.mem.eql(u8, command, "g")) {
        const subcommand = args.next() orelse {
            std.debug.print("Usage: spider g <subcommand>\n", .{});
            std.debug.print("Available subcommands:\n", .{});
            std.debug.print("  feature <name> [--api]    Generate a new feature (--api for REST API)\n", .{});
            std.debug.print("  auth [--provider=keycloak|google] [--api]  Generate auth feature (--api for bearer-only)\n", .{});
            return;
        };
        try generate.run(io, allocator, subcommand, &args);
    } else if (std.mem.eql(u8, command, "migrate")) {
        try migrate.run(io, allocator);
    } else if (std.mem.eql(u8, command, "update")) {
        try update.run(io);
    } else if (std.mem.eql(u8, command, "self-update")) {
        try self_update.run(io);
    } else if (std.mem.eql(u8, command, "install")) {
        try install.run(io, allocator, std.Io.Dir.cwd());
    } else if (std.mem.eql(u8, command, "generate-vapid")) {
        const subject = args.next();
        try generate_vapid.run(io, allocator, subject);
    } else if (std.mem.eql(u8, command, "version")) {
        std.debug.print("spider v{s}\n", .{version});
    } else if (std.mem.eql(u8, command, "help")) {
        std.debug.print("{s}", .{usage});
    } else {
        std.debug.print("error: unknown command '{s}'\n{s}", .{ command, usage });
    }
}
