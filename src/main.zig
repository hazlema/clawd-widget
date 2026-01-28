const std = @import("std");
const http = std.http;
const json = std.json;

const rl = @cImport({
    @cInclude("raylib.h");
});

// Clawdbot config structure
const ClawdbotConfig = struct {
    gateway: struct {
        port: u16,
        auth: struct {
            token: []const u8,
        },
    },
};

// Cron job response structures
const CronJob = struct {
    id: []const u8,
    name: []const u8,
    enabled: bool,
    state: struct {
        nextRunAtMs: ?i64 = null,
        lastRunAtMs: ?i64 = null,
        lastStatus: ?[]const u8 = null,
    },
};

const CronListResponse = struct {
    ok: bool,
    result: struct {
        details: struct {
            jobs: []CronJob,
        },
    },
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Load config
    const config = try loadConfig(allocator);
    defer allocator.free(config.gateway.auth.token);

    // Initialize window
    const window_width = 500;
    const window_height = 600;
    rl.InitWindow(window_width, window_height, "🕵️  Clawd Widget");
    defer rl.CloseWindow();

    rl.SetWindowState(rl.FLAG_WINDOW_RESIZABLE);

    // Load custom font from executable directory
    var exe_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_dir = std.fs.selfExeDirPath(&exe_dir_buf) catch ".";
    var font_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const font_path = std.fmt.bufPrintZ(&font_path_buf, "{s}/DejaVuSans.ttf", .{exe_dir}) catch "DejaVuSans.ttf";
    const font = rl.LoadFontEx(font_path.ptr, 48, null, 0);
    defer rl.UnloadFont(font);

    rl.SetTargetFPS(60);

    // Fetch initial data
    var jobs = try fetchCronJobs(allocator, config);
    var last_refresh: i64 = std.time.milliTimestamp();
    const refresh_interval_ms: i64 = 30000; // Refresh every 30 seconds

    // Main loop
    while (!rl.WindowShouldClose()) {
        // Auto-refresh
        const now = std.time.milliTimestamp();
        if (now - last_refresh > refresh_interval_ms) {
            // Clean up old jobs
            for (jobs) |job| {
                allocator.free(job.name);
                allocator.free(job.id);
                if (job.state.lastStatus) |status| allocator.free(status);
            }
            allocator.free(jobs);

            // Fetch new data
            jobs = fetchCronJobs(allocator, config) catch |err| blk: {
                std.debug.print("Failed to fetch jobs: {}\n", .{err});
                break :blk try allocator.alloc(CronJob, 0);
            };
            last_refresh = now;
        }

        // Manual refresh with R key
        if (rl.IsKeyPressed(rl.KEY_R)) {
            for (jobs) |job| {
                allocator.free(job.name);
                allocator.free(job.id);
                if (job.state.lastStatus) |status| allocator.free(status);
            }
            allocator.free(jobs);

            jobs = fetchCronJobs(allocator, config) catch |err| blk: {
                std.debug.print("Failed to fetch jobs: {}\n", .{err});
                break :blk try allocator.alloc(CronJob, 0);
            };
            last_refresh = now;
        }

        // Render
        rl.BeginDrawing();
        defer rl.EndDrawing();

        rl.ClearBackground(rl.Color{ .r = 20, .g = 20, .b = 30, .a = 255 });

        // Title
        rl.DrawTextEx(font, "Clawd Cron Jobs", .{ .x = 20, .y = 20 }, 24, 1, rl.Color{ .r = 255, .g = 255, .b = 255, .a = 255 });

        // Job count
        var count_buf: [64]u8 = undefined;
        const count_text = std.fmt.bufPrintZ(&count_buf, "{d} jobs", .{jobs.len}) catch "Jobs";
        rl.DrawTextEx(font, count_text.ptr, .{ .x = 20, .y = 50 }, 16, 1, rl.Color{ .r = 150, .g = 150, .b = 150, .a = 255 });

        // Draw jobs
        var y_pos: f32 = 90;
        for (jobs) |job| {
            // Job name with enabled indicator
            const color = if (job.enabled)
                rl.Color{ .r = 100, .g = 255, .b = 100, .a = 255 }
            else
                rl.Color{ .r = 255, .g = 100, .b = 100, .a = 255 };

            const marker = if (job.enabled) "●" else "○";
            var marker_buf: [4]u8 = undefined;
            const marker_z = std.fmt.bufPrintZ(&marker_buf, "{s}", .{marker}) catch "•";
            rl.DrawTextEx(font, marker_z.ptr, .{ .x = 30, .y = y_pos }, 18, 1, color);

            // Job name (truncate if too long)
            var name_buf: [128]u8 = undefined;
            const name_text: [:0]const u8 = if (job.name.len > 40)
                std.fmt.bufPrintZ(&name_buf, "{s}...", .{job.name[0..37]}) catch "..."
            else
                std.fmt.bufPrintZ(&name_buf, "{s}", .{job.name}) catch "?";
            rl.DrawTextEx(font, name_text.ptr, .{ .x = 60, .y = y_pos }, 18, 1, rl.Color{ .r = 255, .g = 255, .b = 255, .a = 255 });

            y_pos += 20;

            // Next run time
            if (job.state.nextRunAtMs) |next| {
                const mins = @divTrunc(next - now, 60000);
                var time_buf: [64]u8 = undefined;
                const time_text = if (mins < 0)
                    std.fmt.bufPrintZ(&time_buf, "  Running now", .{}) catch "  ..."
                else if (mins == 0)
                    std.fmt.bufPrintZ(&time_buf, "  < 1 min", .{}) catch "  ..."
                else
                    std.fmt.bufPrintZ(&time_buf, "  in {d} min", .{mins}) catch "  ...";

                rl.DrawTextEx(font, time_text.ptr, .{ .x = 60, .y = y_pos }, 14, 1, rl.Color{ .r = 100, .g = 200, .b = 255, .a = 255 });
                y_pos += 22;
            }

            // Last status
            if (job.state.lastStatus) |status| {
                var status_buf: [128]u8 = undefined;
                const status_text: [:0]const u8 = if (status.len > 50)
                    std.fmt.bufPrintZ(&status_buf, "  {s}...", .{status[0..47]}) catch "  ..."
                else
                    std.fmt.bufPrintZ(&status_buf, "  {s}", .{status}) catch "  ?";

                const status_color = if (std.mem.indexOf(u8, status, "success") != null or std.mem.indexOf(u8, status, "complete") != null)
                    rl.Color{ .r = 100, .g = 255, .b = 100, .a = 200 }
                else if (std.mem.indexOf(u8, status, "error") != null or std.mem.indexOf(u8, status, "fail") != null)
                    rl.Color{ .r = 255, .g = 100, .b = 100, .a = 200 }
                else
                    rl.Color{ .r = 200, .g = 200, .b = 200, .a = 200 };

                rl.DrawTextEx(font, status_text.ptr, .{ .x = 60, .y = y_pos }, 13, 1, status_color);
                y_pos += 22;
            }

            y_pos += 12; // Spacing between jobs

            // Stop if we run out of space
            if (y_pos > @as(f32, window_height) - 60) break;
        }

        // Footer with refresh info
        const seconds_since_refresh = @divTrunc(now - last_refresh, 1000);
        var footer_buf: [128]u8 = undefined;
        const footer_text = std.fmt.bufPrintZ(&footer_buf, "Updated {d}s ago | Press R to refresh", .{seconds_since_refresh}) catch "Press R to refresh";
        const footer_y: f32 = @floatFromInt(rl.GetScreenHeight() - 30);
        rl.DrawTextEx(font, footer_text.ptr, .{ .x = 20, .y = footer_y }, 13, 1, rl.Color{ .r = 120, .g = 120, .b = 120, .a = 255 });
    }

    // Cleanup
    for (jobs) |job| {
        allocator.free(job.name);
        allocator.free(job.id);
        if (job.state.lastStatus) |status| allocator.free(status);
    }
    allocator.free(jobs);
}

fn loadConfig(allocator: std.mem.Allocator) !ClawdbotConfig {
    // Try to read ~/.clawdbot/clawdbot.json
    const home = std.posix.getenv("HOME") orelse return error.NoHomeDir;

    var path_buf: [1024]u8 = undefined;
    const config_path = try std.fmt.bufPrint(&path_buf, "{s}/.clawdbot/clawdbot.json", .{home});

    const file = try std.fs.openFileAbsolute(config_path, .{});
    defer file.close();

    var read_buf: [8192]u8 = undefined;
    var file_reader = file.reader(&read_buf);
    const content = try file_reader.interface.allocRemaining(allocator, std.Io.Limit.limited(1024 * 1024));
    defer allocator.free(content);

    const parsed = try json.parseFromSlice(ClawdbotConfig, allocator, content, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    // Clone the token string so it survives
    const token = try allocator.dupe(u8, parsed.value.gateway.auth.token);

    return .{
        .gateway = .{
            .port = parsed.value.gateway.port,
            .auth = .{
                .token = token,
            },
        },
    };
}

fn fetchCronJobs(allocator: std.mem.Allocator, config: ClawdbotConfig) ![]CronJob {
    var client = http.Client{ .allocator = allocator };
    defer client.deinit();

    // Build URL
    var url_buf: [256]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://localhost:{d}/tools/invoke", .{config.gateway.port});

    // Build request body
    const body = "{\"tool\": \"cron\", \"action\": \"list\"}";

    // Build auth header
    var auth_buf: [512]u8 = undefined;
    const auth_header = try std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{config.gateway.auth.token});

    // Response buffer with allocating writer
    var alloc_writer = std.Io.Writer.Allocating.init(allocator);
    defer alloc_writer.deinit();

    // Make request
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = body,
        .response_writer = &alloc_writer.writer,
        .extra_headers = &.{
            .{ .name = "Authorization", .value = auth_header },
            .{ .name = "Content-Type", .value = "application/json" },
        },
    });

    if (result.status != .ok) {
        return error.HttpError;
    }

    const response_body = alloc_writer.written();

    // Parse JSON
    const parsed = try json.parseFromSlice(CronListResponse, allocator, response_body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    // Clone jobs array
    const jobs = try allocator.alloc(CronJob, parsed.value.result.details.jobs.len);
    for (parsed.value.result.details.jobs, 0..) |job, i| {
        jobs[i] = .{
            .id = try allocator.dupe(u8, job.id),
            .name = try allocator.dupe(u8, job.name),
            .enabled = job.enabled,
            .state = .{
                .nextRunAtMs = job.state.nextRunAtMs,
                .lastRunAtMs = job.state.lastRunAtMs,
                .lastStatus = if (job.state.lastStatus) |s| try allocator.dupe(u8, s) else null,
            },
        };
    }

    return jobs;
}
