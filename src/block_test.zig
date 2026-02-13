const std = @import("std");
const phant = @import("phant");
const Allocator = std.mem.Allocator;

// Phant type aliases
const Address = phant.types.Address;
const Block = phant.types.Block;
const BlockHeader = phant.types.BlockHeader;
const Hash32 = phant.types.Hash32;
const Bytes32 = phant.types.Bytes32;
const StateDB = phant.state.StateDB;
const AccountState = phant.state.AccountState;
const Blockchain = phant.blockchain.Blockchain;
const Fork = phant.blockchain.Fork;
const ChainId = phant.config.ChainId;

const log = std.log.scoped(.blocktest);

// ── JSON fixture types ──────────────────────────────────────────────────────

const HexString = []const u8;

pub const Fixture = struct {
    const FixtureType = std.json.ArrayHashMap(FixtureTest);
    tests: std.json.Parsed(FixtureType),

    pub fn fromBytes(allocator: Allocator, bytes: []const u8) !Fixture {
        const tests = try std.json.parseFromSlice(
            FixtureType,
            allocator,
            bytes,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        );
        return .{ .tests = tests };
    }

    pub fn deinit(self: *Fixture) void {
        self.tests.deinit();
        self.tests = undefined;
    }
};

pub const FixtureTest = struct {
    _info: std.json.Value = .null,
    network: []const u8,
    genesisRLP: HexString,
    blocks: []const FixtureBlock,
    lastblockhash: HexString,
    pre: ChainState,
    postState: ?ChainState = null,
    sealEngine: ?[]const u8 = null,
};

pub const FixtureBlock = struct {
    rlp: []const u8,
    blockHeader: ?std.json.Value = null,
    expectException: ?[]const u8 = null,
};

pub const ChainState = std.json.ArrayHashMap(AccountStateHex);

pub const AccountStateHex = struct {
    nonce: HexString,
    balance: HexString,
    code: HexString,
    storage: AccountStorageHex,

    pub fn toAccountState(self: AccountStateHex, allocator: Allocator, addr_hex: []const u8) !AccountState {
        const nonce = try std.fmt.parseInt(u64, self.nonce[2..], 16);
        const balance = try std.fmt.parseInt(u256, self.balance[2..], 16);

        const code = try allocator.alloc(u8, self.code[2..].len / 2);
        _ = try std.fmt.hexToBytes(code, self.code[2..]);

        var addr: Address = undefined;
        _ = try std.fmt.hexToBytes(&addr, addr_hex[2..]);

        var account = try AccountState.init(allocator, addr, nonce, balance, code);

        var it = self.storage.map.iterator();
        while (it.next()) |entry| {
            const key = try std.fmt.parseUnsigned(u256, entry.key_ptr.*[2..], 16);
            const value = try std.fmt.parseUnsigned(u256, entry.value_ptr.*[2..], 16);
            var value_bytes: Bytes32 = undefined;
            std.mem.writeInt(u256, &value_bytes, value, .big);
            try account.storage.putNoClobber(key, value_bytes);
        }

        return account;
    }
};

const AccountStorageHex = std.json.ArrayHashMap(HexString);

// ── Test result types ───────────────────────────────────────────────────────

pub const TestResult = union(enum) {
    pass,
    fail: []const u8,
    skip: []const u8,
};

// ── Supported fork check ────────────────────────────────────────────────────

/// Returns true if the given network name represents a post-merge fork
/// that phant can attempt to execute. Phant enforces difficulty=0, nonce=0,
/// base_fee required, and withdrawals_root required, so only Shanghai+ works.
fn isSupportedFork(network: []const u8) bool {
    const supported = [_][]const u8{
        "Shanghai",
        "Cancun",
        "Prague",
        "Osaka",
        // Transition forks that end up post-merge
        "ParisToShanghaiAtTime15k",
        "ShanghaiToCancunAtTime15k",
        "CancunToPragueAtTime15k",
        "PragueToOsakaAtTime15k",
    };
    for (supported) |s| {
        if (std.mem.eql(u8, network, s)) return true;
    }
    return false;
}

/// Determine which Fork implementation to use for a given network name.
fn createFork(allocator: Allocator, network: []const u8, statedb: *StateDB) !*Fork {
    // Prague and later use the EIP-2935 block hash storage
    if (std.mem.eql(u8, network, "Prague") or
        std.mem.eql(u8, network, "Osaka") or
        std.mem.eql(u8, network, "CancunToPragueAtTime15k") or
        std.mem.eql(u8, network, "PragueToOsakaAtTime15k"))
    {
        return try Fork.prague.enablePrague(statedb, null, allocator);
    }
    // Everything else uses the frontier (basic) fork
    return try Fork.frontier.newFrontierFork(allocator);
}

// ── Core test runner ────────────────────────────────────────────────────────

/// Run a single block test fixture. Translates go-ethereum's
/// block_test_util.go Run function.
///
/// Returns a TestResult indicating pass, fail (with reason), or skip.
/// Never panics — all errors are caught and reported.
pub fn runTest(
    test_name: []const u8,
    fixture: *const FixtureTest,
    base_allocator: Allocator,
    result_buf: []u8,
) TestResult {
    return runTestInner(test_name, fixture, base_allocator, result_buf) catch |err| {
        const msg = std.fmt.bufPrint(result_buf, "internal error: {s}", .{@errorName(err)}) catch "unknown error";
        return .{ .fail = msg };
    };
}

fn runTestInner(
    _: []const u8,
    fixture: *const FixtureTest,
    base_allocator: Allocator,
    result_buf: []u8,
) !TestResult {
    // Step 1: Check fork support
    if (!isSupportedFork(fixture.network)) {
        const msg = try std.fmt.bufPrint(result_buf, "unsupported fork \"{s}\"", .{fixture.network});
        return .{ .skip = msg };
    }

    // Step 2: Set up arena for this test
    var arena = std.heap.ArenaAllocator.init(base_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Step 3: Parse pre-state accounts and create statedb
    const accounts_state = blk: {
        var accounts = try allocator.alloc(AccountState, fixture.pre.map.count());
        var it = fixture.pre.map.iterator();
        var i: usize = 0;
        while (it.next()) |entry| {
            accounts[i] = try entry.value_ptr.toAccountState(allocator, entry.key_ptr.*);
            i += 1;
        }
        break :blk accounts;
    };
    var statedb = try StateDB.init(allocator, accounts_state);

    // Step 4: Decode genesis block from RLP
    const genesis_rlp_hex = fixture.genesisRLP;
    var genesis_bytes = try allocator.alloc(u8, genesis_rlp_hex.len / 2);
    genesis_bytes = try std.fmt.hexToBytes(genesis_bytes, genesis_rlp_hex[2..]);
    const genesis_block = Block.decode(allocator, genesis_bytes) catch |err| {
        const msg = try std.fmt.bufPrint(result_buf, "genesis decode failed: {s}", .{@errorName(err)});
        return .{ .fail = msg };
    };

    // Step 5: Create fork and blockchain
    const fork = try createFork(allocator, fixture.network, &statedb);
    var chain = Blockchain.init(allocator, ChainId.Mainnet, &statedb, genesis_block.header, fork) catch |err| {
        const msg = try std.fmt.bufPrint(result_buf, "chain init failed: {s}", .{@errorName(err)});
        return .{ .fail = msg };
    };

    // Step 6: Execute blocks
    for (fixture.blocks, 0..) |encoded_block, bi| {
        // Decode block from hex RLP
        var block_bytes = allocator.alloc(u8, encoded_block.rlp.len / 2) catch |err| {
            const msg = try std.fmt.bufPrint(result_buf, "block {d} alloc failed: {s}", .{ bi, @errorName(err) });
            return .{ .fail = msg };
        };
        block_bytes = std.fmt.hexToBytes(block_bytes, encoded_block.rlp[2..]) catch {
            // Block hex decoding failed
            if (encoded_block.blockHeader == null) {
                // Expected invalid block — continue
                continue;
            }
            const msg = try std.fmt.bufPrint(result_buf, "block {d}: hex decode failed but block expected valid", .{bi});
            return .{ .fail = msg };
        };

        const block = Block.decode(allocator, block_bytes) catch {
            // RLP decode failed
            if (encoded_block.blockHeader == null) {
                // Expected invalid block — continue
                continue;
            }
            const msg = try std.fmt.bufPrint(result_buf, "block {d}: RLP decode failed but block expected valid", .{bi});
            return .{ .fail = msg };
        };

        // Execute block
        if (chain.runBlock(block)) |_| {
            // Block executed successfully
            if (encoded_block.blockHeader == null) {
                const msg = try std.fmt.bufPrint(result_buf, "block {d}: execution succeeded but block expected invalid", .{bi});
                return .{ .fail = msg };
            }
        } else |_| {
            // Block execution failed
            if (encoded_block.blockHeader != null and encoded_block.expectException == null) {
                const msg = try std.fmt.bufPrint(result_buf, "block {d}: execution failed but block expected valid", .{bi});
                return .{ .fail = msg };
            }
            // Expected failure or expected exception — continue
        }
    }

    // Step 7: Validate last block hash
    if (fixture.lastblockhash.len >= 2) {
        var expected_hash: Hash32 = undefined;
        _ = std.fmt.hexToBytes(&expected_hash, fixture.lastblockhash[2..]) catch {
            const msg = try std.fmt.bufPrint(result_buf, "invalid lastblockhash hex", .{});
            return .{ .fail = msg };
        };

        const computed_hash = phant.common.encodeToRLPAndHash(BlockHeader, allocator, chain.prev_block, null) catch |err| {
            const msg = try std.fmt.bufPrint(result_buf, "hash computation failed: {s}", .{@errorName(err)});
            return .{ .fail = msg };
        };

        if (!std.mem.eql(u8, &expected_hash, &computed_hash)) {
            const msg = try std.fmt.bufPrint(
                result_buf,
                "last block hash mismatch: want {x}, got {x}",
                .{ &expected_hash, &computed_hash },
            );
            return .{ .fail = msg };
        }
    }

    // Step 8: Validate post-state
    const post_state = fixture.postState orelse return .pass;
    var post_it = post_state.map.iterator();
    while (post_it.next()) |entry| {
        var exp_account = entry.value_ptr.toAccountState(allocator, entry.key_ptr.*) catch |err| {
            const msg = try std.fmt.bufPrint(result_buf, "post-state parse error: {s}", .{@errorName(err)});
            return .{ .fail = msg };
        };
        _ = &exp_account;

        const got = statedb.getAccount(exp_account.addr);

        if (got.nonce != exp_account.nonce) {
            const msg = try std.fmt.bufPrint(
                result_buf,
                "post-state nonce mismatch for {x}: want {d}, got {d}",
                .{ &exp_account.addr, exp_account.nonce, got.nonce },
            );
            return .{ .fail = msg };
        }

        if (got.balance != exp_account.balance) {
            const msg = try std.fmt.bufPrint(
                result_buf,
                "post-state balance mismatch for {x}: want {d}, got {d}",
                .{ &exp_account.addr, exp_account.balance, got.balance },
            );
            return .{ .fail = msg };
        }

        // Validate storage
        const got_storage = statedb.getAllStorage(exp_account.addr);
        if (got_storage == null) {
            if (exp_account.storage.count() > 0) {
                const msg = try std.fmt.bufPrint(
                    result_buf,
                    "post-state account {x} storage missing but expected {d} slots",
                    .{ &exp_account.addr, exp_account.storage.count() },
                );
                return .{ .fail = msg };
            }
            continue;
        }

        var exp_storage_it = exp_account.storage.iterator();
        while (exp_storage_it.next()) |storage_entry| {
            const key = storage_entry.key_ptr.*;
            const expected_value = storage_entry.value_ptr.*;

            const got_value = statedb.getStorage(exp_account.addr, key);
            if (!std.mem.eql(u8, &got_value, &expected_value)) {
                const msg = try std.fmt.bufPrint(
                    result_buf,
                    "post-state storage mismatch for {x} slot {d}",
                    .{ &exp_account.addr, key },
                );
                return .{ .fail = msg };
            }
        }
    }

    return .pass;
}
