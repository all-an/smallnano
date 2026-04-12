/// Fuzz harness for wire-message decoding.
///
/// Feed arbitrary bytes on stdin. The first 8 bytes are treated as a message
/// header; if they parse, the harness attempts the matching body decode using
/// whatever bytes remain.
const std = @import("std");
const message = @import("network/message.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const input = try std.fs.File.stdin().readToEndAlloc(allocator, 1 << 20);
    defer allocator.free(input);

    if (input.len < message.HEADER_SIZE) return;

    const header_buf = input[0..message.HEADER_SIZE][0..message.HEADER_SIZE];
    const header = message.MessageHeader.decode(header_buf) catch return;
    const body = input[message.HEADER_SIZE..];

    switch (header.msg_type) {
        .handshake => {
            if (body.len >= message.HANDSHAKE_BODY_SIZE) {
                _ = message.HandshakeBody.decode(body[0..message.HANDSHAKE_BODY_SIZE]);
            }
        },
        .handshake_ack => {
            if (body.len >= message.HANDSHAKE_ACK_BODY_SIZE) {
                _ = message.HandshakeAckBody.decode(body[0..message.HANDSHAKE_ACK_BODY_SIZE]);
            }
        },
        .keepalive => {},
        .publish => {
            if (body.len >= message.PUBLISH_BODY_SIZE) {
                _ = message.PublishBody.decode(body[0..message.PUBLISH_BODY_SIZE]);
            }
        },
        .vote_by => {
            _ = message.VoteByBody.decode(body) catch {};
        },
        .pull_req => {
            if (body.len >= message.PULL_REQ_BODY_SIZE) {
                _ = message.PullReqBody.decode(body[0..message.PULL_REQ_BODY_SIZE]);
            }
        },
        .pull_ack => {
            _ = message.PullAckBody.decode(body) catch {};
        },
        .telemetry => {
            if (body.len >= message.TELEMETRY_BODY_SIZE) {
                _ = message.TelemetryBody.decode(body[0..message.TELEMETRY_BODY_SIZE]);
            }
        },
    }
}
