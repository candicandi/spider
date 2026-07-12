const std = @import("std");
const pacman = @import("pacman");
const Ctx = @import("spider").Ctx;

const Sha256 = std.crypto.hash.sha2.Sha256;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

const UPPER_HEX = "0123456789ABCDEF";

// ─── Config ──────────────────────────────────────────────────────

pub const R2Config = struct {
    account_id: []const u8,
    access_key: []const u8,
    secret_key: []const u8,
    bucket: []const u8,
    pub_url: []const u8 = "",
    region: []const u8 = "auto",
};

// ─── R2 Client ────────────────────────────────────────────────────

pub const R2 = struct {
    config: R2Config,
    /// Persistent — created once in init()/initFromEnv(), reused (with its
    /// connection pool) across every put/get/delete/head/copyObject call
    /// instead of dialing a fresh TCP+TLS connection every time.
    client: pacman.Client,

    pub fn init(io: std.Io, config: R2Config) !R2 {
        const base_url = try std.fmt.allocPrint(
            std.heap.smp_allocator,
            "https://{s}.r2.cloudflarestorage.com",
            .{config.account_id},
        );
        const client = try pacman.Client.init(io, std.heap.smp_allocator, .{ .base_url = base_url });
        return .{ .config = config, .client = client };
    }

    pub fn initFromEnv(io: std.Io) !R2 {
        const env = @import("spider").env;
        return init(io, .{
            .account_id = env.getOr("R2_ACCOUNT_ID", ""),
            .access_key = env.getOr("R2_ACCESS_KEY", ""),
            .secret_key = env.getOr("R2_SECRET_KEY", ""),
            .bucket = env.getOr("R2_BUCKET", ""),
            .pub_url = env.getOr("R2_PUBLIC_URL", ""),
        });
    }

    pub fn deinit(self: *R2) void {
        self.client.deinit();
    }

    // ─── Operations ──────────────────────────────────────────────

    pub fn put(self: *R2, c: *Ctx, key: []const u8, body: []const u8, content_type: []const u8) !void {
        const host = try self.endpointHost(c.arena);
        const path = try self.requestPath(c.arena, key);
        const payload_hash = try sha256Hex(c.arena, body);
        const signed = try self.signRequest(c.arena, "PUT", key, payload_hash, &.{});

        const uri = std.Uri{
            .scheme = "https",
            .host = .{ .raw = host },
            .path = .{ .percent_encoded = path },
        };

        var res = try pacman.request(c._io, c.arena, "", .{
            .method = .PUT,
            .uri = uri,
            .body = .{ .raw = body },
            .headers = &.{
                .{ .name = "Authorization", .value = signed.authorization },
                .{ .name = "X-Amz-Date", .value = signed.x_amz_date },
                .{ .name = "X-Amz-Content-Sha256", .value = signed.x_amz_content_sha256 },
                .{ .name = "Content-Type", .value = content_type },
                .{ .name = "Connection", .value = "close" },
            },
        }, &self.client.http_client);
        defer res.deinit();

        if (res.status != .ok and res.status != .no_content) {
            const res_body = res.text();
            std.log.err("r2 put failed status={d} url={s} body={s}", .{ @intFromEnum(res.status), path, res_body });
            return error.R2PutFailed;
        }
    }

    /// Copia um objeto server-side (R2 -> R2), sem baixar o body pro cliente.
    /// x-amz-copy-source segue o formato "/{bucket}/{key-url-encoded}" — igual
    /// ao que requestPath() ja produz, reusado aqui pra montar o valor do header
    /// (confirmado na doc do CopyObject da AWS S3, que R2 implementa).
    /// CopyObject nao tem corpo de requisicao, entao o payload_hash e o de
    /// string vazia (mesmo padrao ja usado em get/delete/head).
    pub fn copyObject(self: *R2, c: *Ctx, source_key: []const u8, dest_key: []const u8) !void {
        const host = try self.endpointHost(c.arena);
        const dest_path = try self.requestPath(c.arena, dest_key);
        const copy_source = try self.requestPath(c.arena, source_key);
        const payload_hash = try sha256Hex(c.arena, "");
        const signed = try self.signRequest(c.arena, "PUT", dest_key, payload_hash, &.{
            .{ "x-amz-copy-source", copy_source },
        });

        const uri = std.Uri{
            .scheme = "https",
            .host = .{ .raw = host },
            .path = .{ .percent_encoded = dest_path },
        };

        // No "Connection: close" here (unlike put/delete): CopyObject returns
        // 200 with a real XML body (ETag/LastModified), not a bodyless
        // response — the transfer_encoding=none+content_length=null read-hang
        // risk that close guards against doesn't apply, so this call can
        // safely reuse the persistent connection pool.
        var res = try pacman.request(c._io, c.arena, "", .{
            .method = .PUT,
            .uri = uri,
            .body = .{ .raw = "" },
            .headers = &.{
                .{ .name = "Authorization", .value = signed.authorization },
                .{ .name = "X-Amz-Date", .value = signed.x_amz_date },
                .{ .name = "X-Amz-Content-Sha256", .value = signed.x_amz_content_sha256 },
                .{ .name = "x-amz-copy-source", .value = copy_source },
            },
        }, &self.client.http_client);
        defer res.deinit();

        if (res.status != .ok) {
            const res_body = res.text();
            std.log.err("r2 copyObject failed status={d} dest={s} source={s} body={s}", .{ @intFromEnum(res.status), dest_path, copy_source, res_body });
            return error.R2CopyFailed;
        }
    }

    pub fn get(self: *R2, c: *Ctx, key: []const u8) ![]u8 {
        const host = try self.endpointHost(c.arena);
        const path = try self.requestPath(c.arena, key);
        const payload_hash = try sha256Hex(c.arena, "");
        const signed = try self.signRequest(c.arena, "GET", key, payload_hash, &.{});

        const uri = std.Uri{
            .scheme = "https",
            .host = .{ .raw = host },
            .path = .{ .percent_encoded = path },
        };

        var res = try pacman.request(c._io, c.arena, "", .{
            .method = .GET,
            .uri = uri,
            .headers = &.{
                .{ .name = "Authorization", .value = signed.authorization },
                .{ .name = "X-Amz-Date", .value = signed.x_amz_date },
                .{ .name = "X-Amz-Content-Sha256", .value = signed.x_amz_content_sha256 },
            },
        }, &self.client.http_client);
        defer res.deinit();

        if (res.status == .not_found) return error.NotFound;
        if (res.status != .ok) {
            std.log.err("r2 get: status={d} path={s}", .{ @intFromEnum(res.status), path });
            return error.R2GetFailed;
        }
        return c.arena.dupe(u8, res.text());
    }

    pub fn delete(self: *R2, c: *Ctx, key: []const u8) !void {
        const host = try self.endpointHost(c.arena);
        const path = try self.requestPath(c.arena, key);
        const payload_hash = try sha256Hex(c.arena, "");
        const signed = try self.signRequest(c.arena, "DELETE", key, payload_hash, &.{});

        const uri = std.Uri{
            .scheme = "https",
            .host = .{ .raw = host },
            .path = .{ .percent_encoded = path },
        };

        var res = try pacman.request(c._io, c.arena, "", .{
            .method = .DELETE,
            .uri = uri,
            .headers = &.{
                .{ .name = "Authorization", .value = signed.authorization },
                .{ .name = "X-Amz-Date", .value = signed.x_amz_date },
                .{ .name = "X-Amz-Content-Sha256", .value = signed.x_amz_content_sha256 },
                .{ .name = "Connection", .value = "close" },
            },
        }, &self.client.http_client);
        defer res.deinit();

        if (res.status == .not_found) return error.NotFound;
        if (res.status != .ok and res.status != .no_content) return error.R2DeleteFailed;
    }

    pub fn head(self: *R2, c: *Ctx, key: []const u8) !bool {
        const host = try self.endpointHost(c.arena);
        const path = try self.requestPath(c.arena, key);
        const payload_hash = try sha256Hex(c.arena, "");
        const signed = try self.signRequest(c.arena, "HEAD", key, payload_hash, &.{});

        const uri = std.Uri{
            .scheme = "https",
            .host = .{ .raw = host },
            .path = .{ .percent_encoded = path },
        };

        var res = try pacman.request(c._io, c.arena, "", .{
            .method = .HEAD,
            .uri = uri,
            .headers = &.{
                .{ .name = "Authorization", .value = signed.authorization },
                .{ .name = "X-Amz-Date", .value = signed.x_amz_date },
                .{ .name = "X-Amz-Content-Sha256", .value = signed.x_amz_content_sha256 },
            },
        }, &self.client.http_client);
        defer res.deinit();

        if (res.status == .not_found) return false;
        if (res.status == .ok) return true;
        return error.R2HeadFailed;
    }

    // ─── Presigned URLs ──────────────────────────────────────────

    pub fn presignedPut(self: *const R2, allocator: std.mem.Allocator, key: []const u8, content_type: []const u8, expires_sec: u32) ![]const u8 {
        const dt = currentDateTime();
        const date_str = dt.date[0..];
        const datetime_str = dt.datetime[0..];

        const host = try self.endpointHost(allocator);
        const path = try self.requestPath(allocator, key);

        const credential = try std.fmt.allocPrint(allocator, "{s}/{s}/{s}/s3/aws4_request", .{
            self.config.access_key, date_str, self.config.region,
        });

        var cred_encoded = std.ArrayList(u8).empty;
        defer cred_encoded.deinit(allocator);
        for (credential) |c| {
            if (c == '/') {
                try cred_encoded.appendSlice(allocator, "%2F");
            } else {
                try cred_encoded.append(allocator, c);
            }
        }

        var ct_encoded = std.ArrayList(u8).empty;
        defer ct_encoded.deinit(allocator);
        for (content_type) |c| {
            switch (c) {
                'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => try ct_encoded.append(allocator, c),
                '/' => try ct_encoded.appendSlice(allocator, "%2F"),
                else => {
                    try ct_encoded.append(allocator, '%');
                    var hex_buf: [2]u8 = undefined;
                    _ = std.fmt.bufPrint(&hex_buf, "{X:0>2}", .{c}) catch unreachable;
                    try ct_encoded.appendSlice(allocator, &hex_buf);
                },
            }
        }

        const expires_str = try std.fmt.allocPrint(allocator, "{d}", .{expires_sec});

        const query = try std.fmt.allocPrint(
            allocator,
            "X-Amz-Algorithm=AWS4-HMAC-SHA256" ++
                "&X-Amz-Content-Sha256=UNSIGNED-PAYLOAD" ++
                "&X-Amz-Credential={s}" ++
                "&X-Amz-Date={s}" ++
                "&X-Amz-Expires={s}" ++
                "&X-Amz-SignedHeaders=content-type%3Bhost" ++
                "&content-type={s}",
            .{ cred_encoded.items, datetime_str, expires_str, ct_encoded.items },
        );

        const canonical_headers = try std.fmt.allocPrint(allocator, "content-type:{s}\nhost:{s}\n", .{
            content_type, host,
        });

        const canonical_request = try std.fmt.allocPrint(
            allocator,
            "PUT\n{s}\n{s}\n{s}\ncontent-type;host\nUNSIGNED-PAYLOAD",
            .{ path, query, canonical_headers },
        );

        const canonical_hash = try sha256Hex(allocator, canonical_request);
        const string_to_sign = try std.fmt.allocPrint(
            allocator,
            "AWS4-HMAC-SHA256\n{s}\n{s}/{s}/s3/aws4_request\n{s}",
            .{ datetime_str, date_str, self.config.region, canonical_hash },
        );

        const signing_key = try signingKey(self.config.secret_key, date_str, self.config.region, "s3");
        var sig_bytes: [HmacSha256.mac_length]u8 = undefined;
        HmacSha256.create(&sig_bytes, string_to_sign, &signing_key);
        const sig_hex = try hexLower(allocator, &sig_bytes);

        return std.fmt.allocPrint(allocator, "https://{s}{s}?{s}&X-Amz-Signature={s}", .{
            host, path, query, sig_hex,
        });
    }

    pub fn presignedGet(self: *const R2, allocator: std.mem.Allocator, key: []const u8, expires_sec: u32) ![]const u8 {
        const dt = currentDateTime();
        const date_str = dt.date[0..];
        const datetime_str = dt.datetime[0..];

        const host = try self.endpointHost(allocator);
        const path = try self.requestPath(allocator, key);

        const credential = try std.fmt.allocPrint(allocator, "{s}/{s}/{s}/s3/aws4_request", .{
            self.config.access_key, date_str, self.config.region,
        });

        var cred_encoded = std.ArrayList(u8).empty;
        defer cred_encoded.deinit(allocator);
        for (credential) |c| {
            if (c == '/') {
                try cred_encoded.appendSlice(allocator, "%2F");
            } else {
                try cred_encoded.append(allocator, c);
            }
        }

        const expires_str = try std.fmt.allocPrint(allocator, "{d}", .{expires_sec});

        const query = try std.fmt.allocPrint(
            allocator,
            "X-Amz-Algorithm=AWS4-HMAC-SHA256" ++
                "&X-Amz-Content-Sha256=UNSIGNED-PAYLOAD" ++
                "&X-Amz-Credential={s}" ++
                "&X-Amz-Date={s}" ++
                "&X-Amz-Expires={s}" ++
                "&X-Amz-SignedHeaders=host",
            .{ cred_encoded.items, datetime_str, expires_str },
        );

        const canonical_headers = try std.fmt.allocPrint(allocator, "host:{s}\n", .{host});

        const canonical_request = try std.fmt.allocPrint(
            allocator,
            "GET\n{s}\n{s}\n{s}\nhost\nUNSIGNED-PAYLOAD",
            .{ path, query, canonical_headers },
        );

        const canonical_hash = try sha256Hex(allocator, canonical_request);
        const string_to_sign = try std.fmt.allocPrint(
            allocator,
            "AWS4-HMAC-SHA256\n{s}\n{s}/{s}/s3/aws4_request\n{s}",
            .{ datetime_str, date_str, self.config.region, canonical_hash },
        );

        const signing_key = try signingKey(self.config.secret_key, date_str, self.config.region, "s3");
        var sig_bytes: [HmacSha256.mac_length]u8 = undefined;
        HmacSha256.create(&sig_bytes, string_to_sign, &signing_key);
        const sig_hex = try hexLower(allocator, &sig_bytes);

        return std.fmt.allocPrint(allocator, "https://{s}{s}?{s}&X-Amz-Signature={s}", .{
            host, path, query, sig_hex,
        });
    }

    // ─── Utilities ───────────────────────────────────────────────

    pub fn publicUrl(self: *const R2, allocator: std.mem.Allocator, key: []const u8) ![]const u8 {
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ self.config.pub_url, key });
    }

    pub fn objectKey(self: *const R2, allocator: std.mem.Allocator, tenant_id: []const u8, category: []const u8, filename: []const u8) ![]const u8 {
        _ = self;
        return std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ tenant_id, category, filename });
    }

    // ─── Internal ────────────────────────────────────────────────

    fn requestUrl(self: *const R2, allocator: std.mem.Allocator, key: []const u8) ![]const u8 {
        const host = try self.endpointHost(allocator);
        const path = try self.requestPath(allocator, key);
        return std.fmt.allocPrint(allocator, "https://{s}{s}", .{ host, path });
    }

    fn endpointHost(self: *const R2, allocator: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(allocator, "{s}.r2.cloudflarestorage.com", .{self.config.account_id});
    }

    fn requestPath(self: *const R2, allocator: std.mem.Allocator, key: []const u8) ![]const u8 {
        var encoded = std.ArrayList(u8).empty;
        errdefer encoded.deinit(allocator);
        try encoded.append(allocator, '/');
        try encoded.appendSlice(allocator, self.config.bucket);
        try encoded.append(allocator, '/');
        for (key) |c| {
            switch (c) {
                '/', 'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => try encoded.append(allocator, c),
                else => {
                    try encoded.appendSlice(allocator, "%");
                    try encoded.append(allocator, UPPER_HEX[c >> 4]);
                    try encoded.append(allocator, UPPER_HEX[c & 0xf]);
                },
            }
        }
        return encoded.toOwnedSlice(allocator);
    }

    fn signRequest(
        self: *const R2,
        allocator: std.mem.Allocator,
        method: []const u8,
        key: []const u8,
        payload_hash: []const u8,
        extra_headers: []const [2][]const u8,
    ) !SignedRequest {
        const dt = currentDateTime();
        const date_str = dt.date[0..];
        const datetime_str = dt.datetime[0..];

        const host = try self.endpointHost(allocator);
        const path = try self.requestPath(allocator, key);

        // SigV4 exige CanonicalHeaders/SignedHeaders em ordem alfabetica por
        // nome — monta todos os headers (fixos + extras) e ordena antes de
        // construir as strings, em vez de assumir uma ordem fixa.
        var all_headers = std.ArrayList([2][]const u8).empty;
        defer all_headers.deinit(allocator);
        try all_headers.append(allocator, .{ "host", host });
        try all_headers.append(allocator, .{ "x-amz-content-sha256", payload_hash });
        try all_headers.append(allocator, .{ "x-amz-date", datetime_str });
        for (extra_headers) |h| try all_headers.append(allocator, h);

        std.mem.sort([2][]const u8, all_headers.items, {}, struct {
            fn lessThan(_: void, a: [2][]const u8, b: [2][]const u8) bool {
                return std.mem.lessThan(u8, a[0], b[0]);
            }
        }.lessThan);

        var canonical_headers = std.ArrayList(u8).empty;
        defer canonical_headers.deinit(allocator);
        var signed_headers = std.ArrayList(u8).empty;
        defer signed_headers.deinit(allocator);

        for (all_headers.items, 0..) |h, i| {
            try canonical_headers.appendSlice(allocator, h[0]);
            try canonical_headers.append(allocator, ':');
            try canonical_headers.appendSlice(allocator, h[1]);
            try canonical_headers.append(allocator, '\n');
            if (i > 0) try signed_headers.append(allocator, ';');
            try signed_headers.appendSlice(allocator, h[0]);
        }

        const canonical_request = try std.fmt.allocPrint(allocator, "{s}\n{s}\n\n{s}\n{s}\n{s}", .{
            method, path, canonical_headers.items, signed_headers.items, payload_hash,
        });

        const canonical_hash = try sha256Hex(allocator, canonical_request);
        const string_to_sign = try std.fmt.allocPrint(
            allocator,
            "AWS4-HMAC-SHA256\n{s}\n{s}/{s}/s3/aws4_request\n{s}",
            .{ datetime_str, date_str, self.config.region, canonical_hash },
        );

        const key_signing = try signingKey(self.config.secret_key, date_str, self.config.region, "s3");
        var sig_bytes: [HmacSha256.mac_length]u8 = undefined;
        HmacSha256.create(&sig_bytes, string_to_sign, &key_signing);
        const sig_hex = try hexLower(allocator, &sig_bytes);

        const authorization = try std.fmt.allocPrint(
            allocator,
            "AWS4-HMAC-SHA256 Credential={s}/{s}/{s}/s3/aws4_request, SignedHeaders={s}, Signature={s}",
            .{ self.config.access_key, date_str, self.config.region, signed_headers.items, sig_hex },
        );

        return .{
            .authorization = authorization,
            .x_amz_date = try allocator.dupe(u8, datetime_str),
            .x_amz_content_sha256 = try allocator.dupe(u8, payload_hash),
        };
    }
};

const SignedRequest = struct {
    authorization: []const u8,
    x_amz_date: []const u8,
    x_amz_content_sha256: []const u8,
};

// ─── AWS Signature V4 Helpers ─────────────────────────────────────

fn sha256Hex(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(data, &digest, .{});
    return hexLower(allocator, &digest);
}

fn hexLower(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const hex_chars = "0123456789abcdef";
    var result = try allocator.alloc(u8, bytes.len * 2);
    for (bytes, 0..) |b, i| {
        result[i * 2] = hex_chars[b >> 4];
        result[i * 2 + 1] = hex_chars[b & 0xf];
    }
    return result;
}

fn hmacSha256(key: []const u8, data: []const u8) [HmacSha256.mac_length]u8 {
    var out: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&out, data, key);
    return out;
}

fn signingKey(secret: []const u8, date: []const u8, region: []const u8, service: []const u8) ![HmacSha256.mac_length]u8 {
    var key_buf: [256]u8 = undefined;
    const aws4_key = try std.fmt.bufPrint(&key_buf, "AWS4{s}", .{secret});
    const k_date = hmacSha256(aws4_key, date);
    const k_region = hmacSha256(&k_date, region);
    const k_service = hmacSha256(&k_region, service);
    const k_signing = hmacSha256(&k_service, "aws4_request");
    return k_signing;
}

const DateTimeStrs = struct {
    date: [8]u8,
    datetime: [16]u8,
};

fn currentDateTime() DateTimeStrs {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.REALTIME, &ts);
    const secs: u64 = @intCast(ts.sec);

    var days = secs / 86400;
    const time_of_day = secs % 86400;

    const hour = time_of_day / 3600;
    const minute = (time_of_day % 3600) / 60;
    const second = time_of_day % 60;

    var year: u64 = 1970;
    while (true) {
        const leap = (year % 4 == 0 and (year % 100 != 0 or year % 400 == 0));
        const days_in_year: u64 = if (leap) 366 else 365;
        if (days < days_in_year) break;
        days -= days_in_year;
        year += 1;
    }
    const leap = (year % 4 == 0 and (year % 100 != 0 or year % 400 == 0));
    const days_in_month = [_]u8{ 31, if (leap) @as(u8, 29) else @as(u8, 28), 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    var month: u64 = 1;
    var d = days;
    for (days_in_month) |dim| {
        if (d < dim) break;
        d -= dim;
        month += 1;
    }
    const day = d + 1;

    var result: DateTimeStrs = undefined;
    _ = std.fmt.bufPrint(&result.date, "{d:0>4}{d:0>2}{d:0>2}", .{ year, month, day }) catch unreachable;
    _ = std.fmt.bufPrint(&result.datetime, "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z", .{ year, month, day, hour, minute, second }) catch unreachable;
    return result;
}

// ─── Tests ────────────────────────────────────────────────────────

test "sha256Hex empty string" {
    const allocator = std.testing.allocator;
    const hash = try sha256Hex(allocator, "");
    defer allocator.free(hash);
    try std.testing.expectEqualStrings("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", hash);
}

test "sha256Hex known value" {
    const allocator = std.testing.allocator;
    const hash = try sha256Hex(allocator, "hello");
    defer allocator.free(hash);
    try std.testing.expectEqualStrings("2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824", hash);
}

test "R2 signRequest produces valid authorization header" {
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var r2 = try R2.init(io, .{
        .account_id = "testaccount",
        .access_key = "AKIAIOSFODNN7EXAMPLE",
        .secret_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        .bucket = "my-bucket",
    });
    defer r2.deinit();

    const payload_hash = try sha256Hex(allocator, "hello world");
    defer allocator.free(payload_hash);

    const signed = try r2.signRequest(allocator, "PUT", "test/file.txt", payload_hash, &.{});

    try std.testing.expect(signed.authorization.len > 0);
    try std.testing.expect(std.mem.startsWith(u8, signed.authorization, "AWS4-HMAC-SHA256 Credential="));
    try std.testing.expect(std.mem.indexOf(u8, signed.authorization, "Signature=") != null);
}

test "R2 publicUrl" {
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var r2 = try R2.init(io, .{
        .account_id = "test",
        .access_key = "key",
        .secret_key = "secret",
        .bucket = "bucket",
        .pub_url = "https://pub-xyz.r2.dev",
    });
    defer r2.deinit();
    const url = try r2.publicUrl(allocator, "folder/file.txt");
    defer allocator.free(url);
    try std.testing.expectEqualStrings("https://pub-xyz.r2.dev/folder/file.txt", url);
}

test "R2 objectKey" {
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var r2 = try R2.init(io, .{
        .account_id = "test",
        .access_key = "key",
        .secret_key = "secret",
        .bucket = "bucket",
    });
    defer r2.deinit();
    const key = try r2.objectKey(allocator, "tenant-123", "boletos", "jan.pdf");
    defer allocator.free(key);
    try std.testing.expectEqualStrings("tenant-123/boletos/jan.pdf", key);
}
