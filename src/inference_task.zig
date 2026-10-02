const std = @import("std");

/// GUI inference runs in a bounded child. Prompts travel through stdin rather
/// than process arguments, shell commands, or temporary files.
pub const InferenceTask = struct {
    child: ?std.process.Child = null,
    timer: ?std.time.Timer = null,
    output: [2048]u8 = [_]u8{0} ** 2048,
    output_len: usize = 0,
    errors: [512]u8 = [_]u8{0} ** 512,
    errors_len: usize = 0,
    failed: bool = false,
    scanner: bool = false,

    pub fn busy(self: *const InferenceTask) bool {
        return self.child != null;
    }
    pub fn text(self: *const InferenceTask) []const u8 {
        return self.output[0..self.output_len];
    }
    fn set(self: *InferenceTask, message: []const u8) void {
        self.output_len = @min(message.len, self.output.len);
        @memcpy(self.output[0..self.output_len], message[0..self.output_len]);
    }
    pub fn start(self: *InferenceTask, allocator: std.mem.Allocator, mode: []const u8, prompt: []const u8) !void {
        try self.validateInput(mode, prompt);
        const executable = try std.fs.selfExePathAlloc(allocator);
        defer allocator.free(executable);
        try self.startExecutable(allocator, executable, mode, prompt);
    }
    fn validateInput(self: *const InferenceTask, mode: []const u8, prompt: []const u8) !void {
        if (self.busy()) return error.InferenceBusy;
        if (!std.mem.eql(u8, mode, "chat") and !std.mem.eql(u8, mode, "road") and !std.mem.eql(u8, mode, "food")) return error.InvalidMode;
        if (prompt.len == 0 or prompt.len > 8192) return error.InvalidPrompt;
    }
    fn startExecutable(self: *InferenceTask, allocator: std.mem.Allocator, executable: []const u8, mode: []const u8, prompt: []const u8) !void {
        try self.validateInput(mode, prompt);
        self.scanner = !std.mem.eql(u8, mode, "chat");
        const argv = [_][]const u8{ executable, "infer", mode, if (std.mem.eql(u8, mode, "chat")) "128" else "16" };
        var child = std.process.Child.init(&argv, allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        try child.spawn();
        self.child = child;
        errdefer self.cancel();
        try self.child.?.waitForSpawn();
        self.timer = try std.time.Timer.start();
        self.output_len = 0;
        self.errors_len = 0;
        self.failed = false;
        try self.child.?.stdin.?.writeAll(prompt);
        self.child.?.stdin.?.close();
        self.child.?.stdin = null;
    }
    pub fn cancel(self: *InferenceTask) void {
        if (self.child) |*child| {
            std.posix.kill(child.id, std.posix.SIG.KILL) catch {};
            child.term = null;
            _ = child.wait() catch {};
        }
        self.child = null;
        self.failed = true;
        self.set("Model inference cancelled. No risk classification was produced.");
    }
    pub fn deinit(self: *InferenceTask) void {
        if (self.busy()) self.cancel();
        std.crypto.secureZero(u8, &self.output);
        std.crypto.secureZero(u8, &self.errors);
    }
    pub fn poll(self: *InferenceTask) !bool {
        const child = if (self.child) |*c| c else return false;
        if (self.timer.?.read() > 5 * 60 * std.time.ns_per_s) {
            self.cancel();
            self.set("Model inference timed out after 5 minutes. No risk classification was produced.");
            return true;
        }
        var fds = [_]std.posix.pollfd{
            .{ .fd = child.stdout.?.handle, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = child.stderr.?.handle, .events = std.posix.POLL.IN, .revents = 0 },
        };
        _ = try std.posix.poll(&fds, 0);
        for (&fds, 0..) |*fd, i| {
            if (fd.revents == 0) continue;
            var buffer: [256]u8 = undefined;
            const n = try std.posix.read(fd.fd, &buffer);
            if (i == 0) {
                if (n > self.output.len - self.output_len) {
                    self.cancel();
                    self.set("Model output exceeded the GUI limit.");
                    return true;
                }
                @memcpy(self.output[self.output_len..][0..n], buffer[0..n]);
                self.output_len += n;
            } else {
                const keep = @min(n, self.errors.len - self.errors_len);
                @memcpy(self.errors[self.errors_len..][0..keep], buffer[0..keep]);
                self.errors_len += keep;
            }
        }
        // Drain stdout completely before reaping; a successful child can exit
        // with a full reply still buffered in its pipe.
        if (fds[0].revents & std.posix.POLL.HUP == 0 or fds[0].revents & std.posix.POLL.IN != 0) return false;
        const result = std.posix.waitpid(child.id, std.posix.W.NOHANG);
        if (result.pid == 0) return false;
        const success = std.posix.W.IFEXITED(result.status) and std.posix.W.EXITSTATUS(result.status) == 0;
        child.term = if (std.posix.W.IFEXITED(result.status)) .{ .Exited = std.posix.W.EXITSTATUS(result.status) } else .{ .Signal = std.posix.W.TERMSIG(result.status) };
        _ = try child.wait();
        self.child = null;
        self.failed = !success or (!self.scanner and std.mem.trim(u8, self.text(), " \t\r\n").len == 0);
        if (self.failed) {
            var message: [1024]u8 = undefined;
            const detail = std.mem.trim(u8, self.errors[0..self.errors_len], " \t\r\n");
            self.set(std.fmt.bufPrint(&message, "Model inference failed: {s}. Verify the pinned model in Models. No risk classification was produced.", .{if (detail.len == 0) "empty reply" else detail}) catch "Model inference failed.");
        }
        if (!self.failed and self.scanner) self.set(scannerRiskLabel(self.text()));
        return true;
    }
};

// Preserve the original scanner contract: first standalone risk word,
// case insensitive; Medium if the completed reply has no coherent label.
pub fn scannerRiskLabel(reply: []const u8) []const u8 {
    for (0..reply.len) |i| {
        for ([_][]const u8{ "Low", "Medium", "High" }) |label| {
            if (label.len > reply.len - i) continue;
            const end = i + label.len;
            if (std.ascii.eqlIgnoreCase(reply[i..end], label) and
                (i == 0 or !std.ascii.isAlphanumeric(reply[i - 1])) and
                (end == reply.len or !std.ascii.isAlphanumeric(reply[end]))) return label;
        }
    }
    return "Medium";
}

pub fn validRiskLabel(label: []const u8) bool {
    return std.mem.eql(u8, label, "Low") or std.mem.eql(u8, label, "Medium") or std.mem.eql(u8, label, "High");
}

fn testChild(argv: []const []const u8) !InferenceTask {
    var child = std.process.Child.init(argv, std.testing.allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    return .{ .child = child, .timer = try std.time.Timer.start() };
}

fn finishTest(task: *InferenceTask) !void {
    var timer = try std.time.Timer.start();
    while (!(try task.poll())) {
        if (timer.read() > 5 * std.time.ns_per_s) return error.TestTimeout;
        std.Thread.sleep(std.time.ns_per_ms);
    }
}

test "inference drains buffered reply before reaping child" {
    var task = try testChild(&.{ "/bin/sh", "-c", "printf '%0600d' 1" });
    defer task.deinit();
    try finishTest(&task);
    try std.testing.expect(!task.busy());
    try std.testing.expect(!task.failed);
    try std.testing.expectEqual(@as(usize, 600), task.output_len);
    try std.testing.expectEqual(@as(u8, '1'), task.text()[599]);
}

test "inference errors remain visible and incoherent scanner replies become Medium" {
    var task = try testChild(&.{ "/bin/sh", "-c", "printf 'missing model' >&2; exit 1" });
    defer task.deinit();
    try finishTest(&task);
    try std.testing.expect(task.failed);
    try std.testing.expect(std.mem.indexOf(u8, task.text(), "missing model") != null);
    var invalid = try testChild(&.{ "/bin/echo", "garbled reply" });
    defer invalid.deinit();
    invalid.scanner = true;
    try finishTest(&invalid);
    try std.testing.expect(!invalid.failed);
    try std.testing.expectEqualStrings("Medium", invalid.text());
    try std.testing.expect(!validRiskLabel("garbled reply"));
    try std.testing.expect(validRiskLabel("High"));
}

test "inference cancel reaps child and returns control" {
    var task = try testChild(&.{ "/bin/sleep", "30" });
    defer task.deinit();
    task.cancel();
    try std.testing.expect(!task.busy());
    try std.testing.expect(task.failed);
}

test "live GUI worker runs real chat and food inference when explicitly enabled" {
    const executable = std.process.getEnvVarOwned(std.testing.allocator, "NAZA_LLM_TEST_BINARY") catch return error.SkipZigTest;
    defer std.testing.allocator.free(executable);
    for ([_][]const u8{ "chat", "food" }) |mode| {
        var task = InferenceTask{};
        defer task.deinit();
        try task.startExecutable(std.testing.allocator, executable, mode, if (std.mem.eql(u8, mode, "food")) "Raw chicken left in sunlight for two days, smells rotten." else "Hello! What is two plus two?");
        var timer = try std.time.Timer.start();
        while (!(try task.poll())) {
            if (timer.read() > 120 * std.time.ns_per_s) return error.LiveInferenceTimeout;
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
        try std.testing.expect(!task.busy());
        try std.testing.expect(task.output_len > 0);
        if (task.scanner) {
            try std.testing.expect(!task.failed);
            try std.testing.expect(validRiskLabel(task.text()));
        } else {
            if (task.failed) std.debug.print("Live chat failure: {s}\n", .{task.text()});
            try std.testing.expect(!task.failed);
        }
    }
}

test "inference rejects oversized output and invalid input" {
    var task = try testChild(&.{ "/bin/sh", "-c", "printf '%03000d' 1" });
    defer task.deinit();
    try finishTest(&task);
    try std.testing.expect(task.failed);
    try std.testing.expectEqualStrings("Model output exceeded the GUI limit.", task.text());
    var idle = InferenceTask{};
    defer idle.deinit();
    try std.testing.expectError(error.InvalidPrompt, idle.start(std.testing.allocator, "chat", ""));
    try std.testing.expectError(error.InvalidMode, idle.start(std.testing.allocator, "untrusted", "hello"));
}

test "scanner labels preserve first-word parsing and empty-reply fallback" {
    try std.testing.expectEqualStrings("High", scannerRiskLabel("Risk: HIGH. Later: low."));
    try std.testing.expectEqualStrings("Low", scannerRiskLabel("Low confidence, verify independently."));
    try std.testing.expectEqualStrings("Medium", scannerRiskLabel("mediumish highness"));
    try std.testing.expectEqualStrings("Medium", scannerRiskLabel(""));
    var empty = try testChild(&.{"/bin/true"});
    defer empty.deinit();
    empty.scanner = true;
    try finishTest(&empty);
    try std.testing.expect(!empty.failed);
    try std.testing.expectEqualStrings("Medium", empty.text());
}
