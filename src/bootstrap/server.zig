/// Bootstrap server — serves account frontiers and block windows to peers.
///
/// The bootstrap server is a thin read-only view over the local store. It does
/// not open sockets itself; the networking layer will call these helpers after
/// decoding `PullReq` messages or when preparing a frontier scan response.
///
/// Pruned nodes are first-class citizens:
///   - frontier scans include each account's `pruned_height`
///   - `serve_pull_req()` refuses requests at or below the pruning watermark
///   - replies are bounded to `PULL_ACK_MAX_BLOCKS` sequential blocks
const std = @import("std");
const block_mod = @import("../types/block.zig");
const message = @import("../network/message.zig");
const store_mod = @import("../store/store.zig");

const StateBlock = block_mod.StateBlock;
const AccountInfo = store_mod.AccountInfo;

pub const FrontierInfo = struct {
    account: [32]u8,
    frontier: [32]u8,
    height: u64,
    pruned_height: u64,
};

pub const PullError = error{
    AccountNotFound,
    StartHeightPruned,
    NoBlocksAvailable,
    MissingBlock,
};

pub fn BootstrapServer(comptime StoreType: type) type {
    return struct {
        const Self = @This();

        store: *StoreType,

        pub fn init(store: *StoreType) Self {
            return .{ .store = store };
        }

        /// Append every known account frontier to `out`.
        pub fn get_frontiers(
            self: *Self,
            allocator: std.mem.Allocator,
            out: *std.ArrayList(FrontierInfo),
        ) !void {
            const Ctx = struct {
                allocator: std.mem.Allocator,
                out: *std.ArrayList(FrontierInfo),
                store: *StoreType,
                err: ?anyerror = null,

                fn on_account(ctx: *@This(), account: [32]u8, info: AccountInfo) void {
                    if (ctx.err != null) return;
                    ctx.out.append(ctx.allocator, .{
                        .account = account,
                        .frontier = info.frontier,
                        .height = info.height,
                        .pruned_height = ctx.store.get_pruned_height(&account),
                    }) catch |err| {
                        ctx.err = err;
                    };
                }
            };

            var ctx = Ctx{
                .allocator = allocator,
                .out = out,
                .store = self.store,
            };
            try self.store.for_each_account(&ctx, Ctx.on_account);
            if (ctx.err) |err| return err;
        }

        /// Serve one `PullReq` by returning up to 8 sequential blocks.
        pub fn serve_pull_req(self: *Self, req: message.PullReqBody) PullError!message.PullAckBody {
            const info = self.store.get_account(&req.account) orelse return PullError.AccountNotFound;
            const pruned_height = self.store.get_pruned_height(&req.account);

            if (req.start_height == 0 or req.start_height > info.height) {
                return PullError.NoBlocksAvailable;
            }
            if (req.start_height <= pruned_height) {
                return PullError.StartHeightPruned;
            }

            var body = message.PullAckBody{
                .blocks = undefined,
                .count = 0,
            };

            var height = req.start_height;
            while (height <= info.height and body.count < message.PULL_ACK_MAX_BLOCKS) : (height += 1) {
                const row = self.store.get_block_by_height(&req.account, height) orelse
                    return PullError.MissingBlock;
                body.blocks[body.count] = StateBlock.from_bytes(&row.block_bytes);
                body.count += 1;
            }

            if (body.count == 0) return PullError.NoBlocksAvailable;
            return body;
        }
    };
}

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;
const NullStore = @import("../store/null_store.zig").NullStore;

fn test_block(
    account: [32]u8,
    previous: [32]u8,
    representative: [32]u8,
    balance: u128,
    link: [32]u8,
) StateBlock {
    return .{
        .account = account,
        .previous = previous,
        .representative = representative,
        .balance = balance,
        .link = link,
        .work = 0,
        .signature = [_]u8{0} ** 64,
    };
}

test "bootstrap_server: get_frontiers includes pruning watermark" {
    var store = NullStore.init(testing.allocator);
    defer store.deinit();

    const account = [_]u8{0x01} ** 32;
    const frontier = [_]u8{0xA1} ** 32;
    try store.put_account(&account, .{
        .frontier = frontier,
        .balance = 10,
        .representative = [_]u8{0x02} ** 32,
        .height = 3,
        .modified = 0,
    });
    try store.put_pruned_height(&account, 2);

    var server = BootstrapServer(NullStore).init(&store);
    var frontiers = std.ArrayList(FrontierInfo){};
    defer frontiers.deinit(testing.allocator);

    try server.get_frontiers(testing.allocator, &frontiers);
    try testing.expectEqual(@as(usize, 1), frontiers.items.len);
    try testing.expectEqual(account, frontiers.items[0].account);
    try testing.expectEqual(frontier, frontiers.items[0].frontier);
    try testing.expectEqual(@as(u64, 2), frontiers.items[0].pruned_height);
}

test "bootstrap_server: serve_pull_req returns sequential blocks up to protocol window" {
    var store = NullStore.init(testing.allocator);
    defer store.deinit();

    const account = [_]u8{0x11} ** 32;
    try store.put_account(&account, .{
        .frontier = [_]u8{0xFF} ** 32,
        .balance = 99,
        .representative = [_]u8{0x22} ** 32,
        .height = 10,
        .modified = 0,
    });

    var previous = block_mod.ZERO_HASH;
    for (1..11) |height| {
        const blk = test_block(account, previous, [_]u8{0x22} ** 32, height, [_]u8{@intCast(height)} ** 32);
        const hash = blk.hash();
        try store.put_block(&hash, .{
            .account = account,
            .block_bytes = blk.to_bytes(),
            .height = @intCast(height),
        });
        previous = hash;
    }

    var server = BootstrapServer(NullStore).init(&store);
    const body = try server.serve_pull_req(.{
        .account = account,
        .start_height = 2,
    });

    try testing.expectEqual(message.PULL_ACK_MAX_BLOCKS, body.count);
    try testing.expectEqual(@as(u128, 2), body.blocks[0].balance);
    try testing.expectEqual(@as(u128, 9), body.blocks[7].balance);
}

test "bootstrap_server: serve_pull_req rejects requests below pruning watermark" {
    var store = NullStore.init(testing.allocator);
    defer store.deinit();

    const account = [_]u8{0x21} ** 32;
    try store.put_account(&account, .{
        .frontier = [_]u8{0xAA} ** 32,
        .balance = 1,
        .representative = [_]u8{0xBB} ** 32,
        .height = 5,
        .modified = 0,
    });
    try store.put_pruned_height(&account, 3);

    var server = BootstrapServer(NullStore).init(&store);
    try testing.expectError(PullError.StartHeightPruned, server.serve_pull_req(.{
        .account = account,
        .start_height = 3,
    }));
}
