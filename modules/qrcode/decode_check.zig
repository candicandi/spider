//! Helper executable for `zig build test-decode`. Generates one of a
//! few hardcoded QR codes (selected by a numeric argv[1]) and writes it
//! to stdout as a plain-ASCII PBM (P1) image, with the ISO 6.3.8 quiet
//! zone (minimum 4 modules) this project's encoder does not draw
//! itself — matrix.zig only produces the encoding region.
//!
//! build.zig pipes this into `zbarimg --raw` and compares its output
//! against the original text, closing the loop this project's test
//! strategy called for from the start: proving the generated symbol is
//! actually scannable by a real, independent decoder — not just
//! internally consistent or byte-identical to a reference encoder.

const std = @import("std");
const qrcode = @import("qrcode");

const Case = struct { text: []const u8, version: u8, ecc: qrcode.Ecc };

/// Deliberately varied: alphanumeric mode at version 1 (the fixture
/// already cross-validated against qrcode.c throughout this project),
/// numeric mode at a different version, and byte mode at yet another
/// version/ECC level — so this one test exercises all three in-scope
/// modes, not just the one already covered everywhere else.
const cases = [_]Case{
    .{ .text = "HELLO WORLD", .version = 1, .ecc = .medium },
    .{ .text = "12345678901234567890", .version = 3, .ecc = .low },
    .{ .text = "Testing byte-mode QR generation with lowercase.", .version = 5, .ecc = .quartile },
};

const quiet_zone = 4;
/// zbarimg's scanner needs several pixels per module to reliably find
/// edges — confirmed empirically: a 1-pixel-per-module render of a
/// known-good symbol failed to decode ("scanned 0 barcode symbols"),
/// while the exact same module data at 4 pixels per module decoded
/// correctly. Every prior successful zbarimg test earlier in this
/// project used qrencode's PNG output, which defaults to 3px/module —
/// never actually 1:1, so this wasn't caught until this exact test ran.
const scale = 4;

pub fn main(init: std.process.Init) !void {
    var arg_it = std.process.Args.Iterator.init(init.minimal.args);
    _ = arg_it.next(); // executable name
    const index_str = arg_it.next() orelse return error.MissingCaseIndex;
    const index = try std.fmt.parseInt(usize, index_str, 10);
    const case = cases[index];

    var qr = try qrcode.QR.encode(init.gpa, case.text, case.version, case.ecc);
    defer qr.deinit();

    const width: u16 = qr.size + quiet_zone * 2;
    const pixel_width: u32 = @as(u32, width) * scale;

    var buf: [8192]u8 = undefined;
    var file_writer = std.Io.File.stdout().writer(init.io, &buf);
    const out = &file_writer.interface;

    try out.print("P1\n{d} {d}\n", .{ pixel_width, pixel_width });

    var y: u16 = 0;
    while (y < width) : (y += 1) {
        const in_symbol_y = y >= quiet_zone and y < quiet_zone + qr.size;

        // 1024 comfortably covers even version 40 (size 177 -> 185
        // with quiet zone -> 740 pixels at this scale).
        var row: [1024]u8 = undefined;
        var x: u16 = 0;
        while (x < width) : (x += 1) {
            const in_symbol = in_symbol_y and x >= quiet_zone and x < quiet_zone + qr.size;
            const dark = in_symbol and qr.getModule(x - quiet_zone, y - quiet_zone);
            const ch: u8 = if (dark) '1' else '0';
            @memset(row[x * scale ..][0..scale], ch);
        }
        var s: u16 = 0;
        while (s < scale) : (s += 1) {
            try out.writeAll(row[0..pixel_width]);
            try out.writeByte('\n');
        }
    }
    try out.flush();
}
