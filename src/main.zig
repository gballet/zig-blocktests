const std = @import("std");
const phant = @import("phant");
const block_test = @import("block_test.zig");

const Allocator = std.mem.Allocator;
const IoWriter = std.Io.Writer;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: blocktests <path-to-fixtures-dir-or-file>\n", .{});
        std.process.exit(1);
    }

    const path = args[1];
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    // Statistics
    var passed: u64 = 0;
    var failed: u64 = 0;
    var skipped: u64 = 0;

    // Try opening as directory first; if that fails, treat as file
    if (std.fs.cwd().openDir(path, .{ .iterate = true })) |*dir| {
        var d = dir.*;
        defer d.close();
        try runDirectory(allocator, path, &d, stdout, &passed, &failed, &skipped);
    } else |_| {
        // Not a directory, try as file
        try runFile(allocator, path, stdout, &passed, &failed, &skipped);
    }

    try printSummary(stdout, passed, failed, skipped);
    try stdout.flush();
    if (failed > 0) std.process.exit(1);
}

fn runDirectory(
    allocator: Allocator,
    dir_path: []const u8,
    dir: *std.fs.Dir,
    stdout: *IoWriter,
    passed: *u64,
    failed: *u64,
    skipped: *u64,
) !void {
    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".json")) continue;

        // Build full path
        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.path });
        defer allocator.free(full_path);

        runFile(allocator, full_path, stdout, passed, failed, skipped) catch |err| {
            stdout.print("[ERR ] {s}: {s}\n", .{ entry.path, @errorName(err) }) catch {};
        };
    }
}

fn runFile(
    allocator: Allocator,
    file_path: []const u8,
    stdout: *IoWriter,
    passed: *u64,
    failed: *u64,
    skipped: *u64,
) !void {
    // Read file content
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1 << 30);
    defer allocator.free(content);

    // Parse fixture
    var fixture = block_test.Fixture.fromBytes(allocator, content) catch |err| {
        try stdout.print("[ERR ] {s}: JSON parse error: {s}\n", .{ file_path, @errorName(err) });
        return;
    };
    defer fixture.deinit();

    // Run each test in the fixture
    var it = fixture.tests.value.map.iterator();
    while (it.next()) |entry| {
        const test_name = entry.key_ptr.*;
        const fixture_test = entry.value_ptr;

        // Per-test result buffer for error messages
        var result_buf: [4096]u8 = undefined;

        const result = block_test.runTest(test_name, fixture_test, allocator, &result_buf);

        switch (result) {
            .pass => {
                passed.* += 1;
                try stdout.print("[PASS] {s}\n", .{test_name});
            },
            .fail => |reason| {
                failed.* += 1;
                try stdout.print("[FAIL] {s}: {s}\n", .{ test_name, reason });
            },
            .skip => |reason| {
                skipped.* += 1;
                try stdout.print("[SKIP] {s}: {s}\n", .{ test_name, reason });
            },
        }
    }
}

fn printSummary(stdout: *IoWriter, passed: u64, failed: u64, skipped: u64) !void {
    try stdout.print("---\nResults: {d} passed, {d} failed, {d} skipped\n", .{ passed, failed, skipped });
}
