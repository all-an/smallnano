/// RPC server — minimal single-threaded HTTP/1.1 wrapper around JSON handlers.
///
/// The server intentionally keeps the transport tiny:
///   - one blocking accept loop
///   - one request per connection
///   - POST only
///   - `Content-Length` required
///   - a bounded in-memory request buffer
const std = @import("std");

pub fn RpcServer(comptime HandlerType: type) type {
    return struct {
        const Self = @This();

        pub const HttpError = error{
            InvalidHttpRequest,
            MethodNotAllowed,
            ContentLengthRequired,
            InvalidContentLength,
            RequestBodyTruncated,
            RequestTooLarge,
            ConnectionClosed,
        };

        allocator: std.mem.Allocator,
        handlers: *HandlerType,
        listen_address: []const u8,
        listen_port: u16,
        max_request_size: usize,
        stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        thread: ?std.Thread = null,

        pub fn init(
            allocator: std.mem.Allocator,
            handlers: *HandlerType,
            listen_address: []const u8,
            listen_port: u16,
            max_request_size: usize,
        ) Self {
            return .{
                .allocator = allocator,
                .handlers = handlers,
                .listen_address = listen_address,
                .listen_port = listen_port,
                .max_request_size = max_request_size,
            };
        }

        pub fn start(self: *Self) !void {
            if (self.thread != null) return;
            self.stop.store(false, .release);
            self.thread = try std.Thread.spawn(.{}, accept_loop_thread, .{self});
        }

        pub fn request_stop(self: *Self) void {
            self.stop.store(true, .release);
        }

        pub fn stop_and_join(self: *Self) void {
            self.request_stop();
            if (self.thread) |thread| {
                thread.join();
                self.thread = null;
            }
        }

        /// Accept and serve HTTP requests until `request_stop()` is called.
        pub fn accept_loop(self: *Self) void {
            const addr = std.net.Address.parseIp(self.listen_address, self.listen_port) catch |err| {
                std.log.err("rpc: failed to parse listen address: {}", .{err});
                return;
            };
            var server = addr.listen(.{
                .reuse_address = true,
                .force_nonblocking = true,
            }) catch |err| {
                std.log.err("rpc: failed to listen on port {d}: {}", .{ self.listen_port, err });
                return;
            };
            defer server.deinit();

            std.log.info("rpc: listening on {s}:{d}", .{ self.listen_address, self.listen_port });

            while (!self.stop.load(.acquire)) {
                const conn = server.accept() catch |err| switch (err) {
                    error.WouldBlock => {
                        std.Thread.sleep(20 * std.time.ns_per_ms);
                        continue;
                    },
                    else => continue,
                };
                self.handle_connection(conn) catch |err| {
                    std.log.warn("rpc: request failed: {}", .{err});
                };
            }
        }

        fn handle_connection(self: *Self, conn: std.net.Server.Connection) !void {
            defer conn.stream.close();

            const request = try self.read_request(conn.stream);
            defer self.allocator.free(request);

            const response = self.handle_http_request(self.allocator, request) catch |err| switch (err) {
                error.MethodNotAllowed => try http_response(self.allocator, 405, "Method Not Allowed", "{\"error\":\"MethodNotAllowed\"}"),
                error.ContentLengthRequired => try http_response(self.allocator, 411, "Length Required", "{\"error\":\"ContentLengthRequired\"}"),
                error.InvalidContentLength,
                error.InvalidHttpRequest,
                error.RequestBodyTruncated,
                => try http_response(self.allocator, 400, "Bad Request", "{\"error\":\"InvalidHttpRequest\"}"),
                else => return err,
            };
            defer self.allocator.free(response);

            try write_all(conn.stream, response);
        }

        /// Parse one raw HTTP/1.1 request and return a full owned HTTP response.
        pub fn handle_http_request(self: *Self, allocator: std.mem.Allocator, request: []const u8) ![]u8 {
            const body = try parse_http_request(request);
            const json_response = try self.handlers.handle(allocator, body);
            defer allocator.free(json_response);
            return http_response(allocator, 200, "OK", json_response);
        }

        fn read_request(self: *Self, stream: std.net.Stream) ![]u8 {
            var buffer = try self.allocator.alloc(u8, self.max_request_size);
            errdefer self.allocator.free(buffer);

            var used: usize = 0;
            var content_length: ?usize = null;
            var body_end: ?usize = null;

            while (used < buffer.len) {
                const read_len = try stream.read(buffer[used..]);
                if (read_len == 0) return HttpError.ConnectionClosed;
                used += read_len;

                if (content_length == null) {
                    if (std.mem.indexOf(u8, buffer[0..used], "\r\n\r\n")) |headers_end| {
                        content_length = try parse_content_length(buffer[0 .. headers_end + 2]);
                        body_end = headers_end + 4 + content_length.?;
                    }
                }

                if (body_end) |end| {
                    if (used >= end) return self.allocator.dupe(u8, buffer[0..end]);
                }
            }

            return HttpError.RequestTooLarge;
        }

        fn accept_loop_thread(self: *Self) void {
            self.accept_loop();
        }
    };
}

fn parse_http_request(request: []const u8) ![]const u8 {
    const headers_end = std.mem.indexOf(u8, request, "\r\n\r\n") orelse return error.InvalidHttpRequest;
    const header_block = request[0..headers_end];

    const request_line_end = std.mem.indexOf(u8, header_block, "\r\n") orelse return error.InvalidHttpRequest;
    const request_line = header_block[0..request_line_end];

    if (!std.mem.startsWith(u8, request_line, "POST ")) return error.MethodNotAllowed;
    if (std.mem.indexOf(u8, request_line, " HTTP/1.1") == null and std.mem.indexOf(u8, request_line, " HTTP/1.0") == null) {
        return error.InvalidHttpRequest;
    }

    const content_length = try parse_content_length(header_block);
    const body_start = headers_end + 4;
    const body_end = body_start + content_length;
    if (body_end > request.len) return error.RequestBodyTruncated;
    return request[body_start..body_end];
}

fn parse_content_length(header_block: []const u8) !usize {
    var lines = std.mem.splitSequence(u8, header_block, "\r\n");
    _ = lines.next();

    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(name, "content-length")) continue;

        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        return std.fmt.parseInt(usize, value, 10) catch error.InvalidContentLength;
    }

    return error.ContentLengthRequired;
}

fn http_response(allocator: std.mem.Allocator, status_code: u16, reason: []const u8, body: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "HTTP/1.1 {d} {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ status_code, reason, body.len, body },
    );
}

fn write_all(stream: std.net.Stream, data: []const u8) !void {
    var written: usize = 0;
    while (written < data.len) {
        const n = try stream.write(data[written..]);
        if (n == 0) return error.ConnectionClosed;
        written += n;
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

const FakeHandlers = struct {
    last_body: ?[]u8 = null,

    pub fn handle(self: *FakeHandlers, allocator: std.mem.Allocator, body: []const u8) ![]u8 {
        self.last_body = try allocator.dupe(u8, body);
        return allocator.dupe(u8, "{\"ok\":true}");
    }
};

test "rpc server: wraps a POST body in an HTTP 200 response" {
    var handlers = FakeHandlers{};
    var server = RpcServer(FakeHandlers).init(testing.allocator, &handlers, "127.0.0.1", 7177, 4096);

    const request =
        "POST / HTTP/1.1\r\n" ++
        "Host: localhost\r\n" ++
        "Content-Length: 17\r\n\r\n" ++
        "{\"action\":\"ping\"}";

    const response = try server.handle_http_request(testing.allocator, request);
    defer testing.allocator.free(response);
    defer if (handlers.last_body) |body| testing.allocator.free(body);

    try testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.indexOf(u8, response, "\r\n\r\n{\"ok\":true}") != null);
    try testing.expectEqualStrings("{\"action\":\"ping\"}", handlers.last_body.?);
}

test "rpc server: rejects non-POST requests" {
    const request =
        "GET / HTTP/1.1\r\n" ++
        "Host: localhost\r\n" ++
        "Content-Length: 0\r\n\r\n";

    try testing.expectError(error.MethodNotAllowed, parse_http_request(request));
}

test "rpc server: requires content-length" {
    const request =
        "POST / HTTP/1.1\r\n" ++
        "Host: localhost\r\n\r\n" ++
        "{}";

    try testing.expectError(error.ContentLengthRequired, parse_http_request(request));
}

test "rpc server: detects truncated bodies" {
    const request =
        "POST / HTTP/1.1\r\n" ++
        "Host: localhost\r\n" ++
        "Content-Length: 10\r\n\r\n" ++
        "{}";

    try testing.expectError(error.RequestBodyTruncated, parse_http_request(request));
}
