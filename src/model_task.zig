const std = @import("std");

// The GUI owns a bounded child process, never a thread blocked on DNS/TLS.
// Only the same executable and fixed model command are run, without a shell.
pub const ModelTask = struct {
    child: ?std.process.Child = null,
    models: ?std.fs.Dir = null,
    stage: ?std.fs.Dir = null,
    stage_name: [48]u8 = undefined,
    stage_name_len: usize = 0,
    timer: ?std.time.Timer = null,
    downloading: bool = false,
    status: [1024]u8 = undefined,
    status_len: usize = 0,
    line: [512]u8 = undefined,
    line_len: usize = 0,

    pub fn busy(self: *const ModelTask) bool {
        return self.child != null;
    }
    pub fn text(self: *const ModelTask) []const u8 {
        return self.status[0..self.status_len];
    }
    fn set(self: *ModelTask, message: []const u8) void {
        self.status_len = @min(message.len, self.status.len);
        @memcpy(self.status[0..self.status_len], message[0..self.status_len]);
    }

    pub fn start(self: *ModelTask, allocator: std.mem.Allocator, filename: []const u8, download: bool) !void {
        if (self.busy()) return error.ModelTaskBusy;
        const cwd = std.fs.cwd();
        var parent = try cwd.openDir(".", .{});
        defer parent.close();
        const parent_stat = try std.posix.fstat(parent.fd);
        if (parent_stat.uid != std.posix.getuid() or parent_stat.mode & 0o022 != 0) return error.InsecureWorkingDirectory;
        std.posix.mkdirat(cwd.fd, "models", 0o700) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        const models = try cwd.openDir("models", .{ .no_follow = true });
        self.models = models;
        errdefer self.cleanup();
        const stat = try std.posix.fstat(models.fd);
        // Refuse writable shared directories rather than silently changing them.
        if (stat.uid != std.posix.getuid() or stat.mode & 0o022 != 0) return error.InsecureModelDirectory;
        self.downloading = download;
        self.timer = try std.time.Timer.start();
        self.line_len = 0;
        if (download) {
            // linkat publication enforces no-clobber even against a race;
            // this early check avoids downloading when a model is present.
            if (std.posix.fstatat(models.fd, filename, std.posix.AT.SYMLINK_NOFOLLOW)) |_| {
                return error.ModelDestinationExists;
            } else |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            }
            const name = try std.fmt.bufPrint(&self.stage_name, ".naza-download-{x}", .{std.crypto.random.int(u128)});
            try std.posix.mkdirat(models.fd, name, 0o700);
            self.stage_name_len = name.len;
            self.stage = try models.openDir(name, .{ .no_follow = true });
        }
        const executable = try std.fs.selfExePathAlloc(allocator);
        defer allocator.free(executable);
        const argv = [_][]const u8{ executable, if (download) "download" else "verify", filename };
        var child = std.process.Child.init(&argv, allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Pipe;
        child.cwd_dir = if (self.stage) |dir| dir else models;
        try child.spawn();
        self.child = child;
        errdefer self.cancel();
        try self.child.?.waitForSpawn();
        self.set(if (download) "Connecting over HTTPS. Download stays private until SHA-256 verification completes." else "Verifying local model against the compiled SHA-256...");
    }

    fn cleanup(self: *ModelTask) void {
        if (self.stage) |*dir| dir.close();
        self.stage = null;
        if (self.models) |*dir| {
            if (self.stage_name_len != 0) dir.deleteTree(self.stage_name[0..self.stage_name_len]) catch {};
            dir.close();
        }
        self.models = null;
        self.stage_name_len = 0;
    }

    pub fn cancel(self: *ModelTask) void {
        if (self.child) |*child| {
            // SIGKILL bounds shutdown even during a stuck resolver/connect/TLS.
            std.posix.kill(child.id, std.posix.SIG.KILL) catch {};
            // waitForSpawn can cache a SpawnError after fork. Clear it so
            // wait() still reaps that child and closes its inherited pipes.
            child.term = null;
            _ = child.wait() catch {};
        }
        self.child = null;
        self.cleanup();
        self.set("Cancelled. Private staging removed. Any previously installed model was preserved.");
    }

    pub fn deinit(self: *ModelTask) void {
        if (self.busy()) self.cancel() else self.cleanup();
    }

    pub fn poll(self: *ModelTask, filename: []const u8) !void {
        const child = if (self.child) |*c| c else return;
        // Total deadline also covers continuously progressing or stalled DNS.
        if (self.timer.?.read() > 15 * 60 * std.time.ns_per_s) {
            self.cancel();
            self.set("Timed out after 15 minutes. Private staging removed; existing model preserved.");
            return;
        }
        if (child.stderr) |pipe| {
            var fds = [_]std.posix.pollfd{.{ .fd = pipe.handle, .events = std.posix.POLL.IN, .revents = 0 }};
            // One small read per frame bounds work and output buffering.
            if (try std.posix.poll(&fds, 0) != 0) {
                var bytes: [512]u8 = undefined;
                const n = try pipe.read(&bytes);
                for (bytes[0..n]) |byte| {
                    if (byte == '\r' or byte == '\n') {
                        if (self.line_len != 0) self.set(self.line[0..self.line_len]);
                        self.line_len = 0;
                    } else if (byte >= 32 and byte <= 126 and self.line_len < self.line.len) {
                        self.line[self.line_len] = byte;
                        self.line_len += 1;
                    }
                }
            }
        }
        const result = std.posix.waitpid(child.id, std.posix.W.NOHANG);
        if (result.pid == 0) return;
        child.term = if (std.posix.W.IFEXITED(result.status))
            .{ .Exited = std.posix.W.EXITSTATUS(result.status) }
        else
            .{ .Signal = std.posix.W.TERMSIG(result.status) };
        const term = try child.wait();
        self.child = null;
        defer self.cleanup();
        switch (term) {
            .Exited => |code| if (code != 0) {
                self.set(if (self.downloading) "Download failed. Check network, available space and model pin. An existing destination is never overwritten." else "Verification failed. Model missing, too large, not a regular file, or SHA-256 mismatch. Do not load it.");
                return;
            },
            else => {
                self.set("Model operation failed. Existing model preserved.");
                return;
            },
        }
        if (self.downloading) {
            // Both directory descriptors remain bound to the validated dirs.
            // Publication fails atomically if any destination already exists.
            std.posix.linkat(self.stage.?.fd, filename, self.models.?.fd, filename, 0) catch |err| {
                self.set("Installation refused: destination already exists or publication failed. Existing model preserved.");
                return err;
            };
        }
        self.set(if (self.downloading) "Installed and SHA-256 verified: models/llama3-small-Q3_K_M.gguf" else "Verified: local model matches the compiled SHA-256.");
    }
};

test "GUI cancellation kills blocked child and removes only private staging" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.makeDir("models");
    var models = try temp.dir.openDir("models", .{});
    try models.makeDir(".naza-test-stage");
    var existing = try models.createFile("installed.gguf", .{});
    try existing.writeAll("preserve");
    existing.close();
    var stage = try models.openDir(".naza-test-stage", .{});
    var part = try stage.createFile("partial", .{});
    try part.writeAll("partial transfer");
    part.close();
    const args = [_][]const u8{ "/bin/sleep", "30" };
    var child = std.process.Child.init(&args, std.testing.allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    try child.waitForSpawn();
    var task = ModelTask{ .child = child, .models = models, .stage = stage };
    const name = ".naza-test-stage";
    @memcpy(task.stage_name[0..name.len], name);
    task.stage_name_len = name.len;
    task.cancel();
    try std.testing.expect(!task.busy());
    try std.testing.expectError(error.FileNotFound, temp.dir.statFile("models/.naza-test-stage"));
    try std.testing.expectEqual(@as(u64, 8), (try temp.dir.statFile("models/installed.gguf")).size);
}

test "failed child exec is reaped and its pipes are closed" {
    const args = [_][]const u8{"/naza-test-no-such-executable"};
    var child = std.process.Child.init(&args, std.testing.allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const pid = child.id;
    const fd = child.stderr.?.handle;
    try std.testing.expectError(error.FileNotFound, child.waitForSpawn());
    var task = ModelTask{ .child = child };
    task.cancel();
    try std.testing.expectError(error.ProcessNotFound, std.posix.kill(pid, 0));
    var path: [64]u8 = undefined;
    const pipe_path = try std.fmt.bufPrint(&path, "/proc/self/fd/{d}", .{fd});
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().statFile(pipe_path));
}
