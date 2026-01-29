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

// Application runtime config (CLI overrides)
const AppConfig = struct {
    config_path: ?[]const u8 = null,
    status_dir: []const u8,
    debug: bool = false,
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

// UI state tracking per job
const JobUIState = struct {
    executing: bool = false,
    execute_start_ms: i64 = 0,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Get HOME for defaults
    const home = std.posix.getenv("HOME") orelse {
        std.debug.print("Error: HOME environment variable not set\n", .{});
        return;
    };

    // Build default status dir path
    var default_status_dir_buf: [512]u8 = undefined;
    const default_status_dir = std.fmt.bufPrint(&default_status_dir_buf, "{s}/clawd/cron-status", .{home}) catch {
        std.debug.print("Error: Failed to build default status dir path\n", .{});
        return;
    };

    // Parse CLI arguments
    var app_config = AppConfig{
        .config_path = null,
        .status_dir = default_status_dir,
    };

    var args = std.process.args();
    _ = args.skip(); // Skip program name

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--config") or std.mem.eql(u8, arg, "-c")) {
            if (args.next()) |path| {
                app_config.config_path = path;
            }
        } else if (std.mem.eql(u8, arg, "--status-dir") or std.mem.eql(u8, arg, "-s")) {
            if (args.next()) |path| {
                app_config.status_dir = path;
            }
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp();
            return;
        } else if (std.mem.eql(u8, arg, "--debug") or std.mem.eql(u8, arg, "-d")) {
            app_config.debug = true;
        }
    }

    // Load config
    const config = loadConfig(allocator, app_config.config_path) catch |err| {
        std.debug.print("Error loading config: {}\n", .{err});
        return;
    };
    defer allocator.free(config.gateway.auth.token);

    // Ensure status directory exists
    std.fs.makeDirAbsolute(app_config.status_dir) catch |err| {
        if (err != error.PathAlreadyExists) {
            std.debug.print("Warning: Could not create status dir {s}: {}\n", .{ app_config.status_dir, err });
        }
    };

    // Initialize window
    const window_width = 500;
    const window_height = 600;
    rl.InitWindow(window_width, window_height, "Clawd Widget");
    defer rl.CloseWindow();

    rl.SetWindowState(rl.FLAG_WINDOW_RESIZABLE);

    // Load custom fonts at exact sizes for crisp rendering
    var exe_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_dir = std.fs.selfExeDirPath(&exe_dir_buf) catch ".";
    var font_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const font_path = std.fmt.bufPrintZ(&font_path_buf, "{s}/DejaVuSans.ttf", .{exe_dir}) catch "DejaVuSans.ttf";

    const font_large = rl.LoadFontEx(font_path.ptr, 24, null, 0); // titles
    const font_medium = rl.LoadFontEx(font_path.ptr, 18, null, 0); // job names, markers
    const font_small = rl.LoadFontEx(font_path.ptr, 14, null, 0); // buttons, tooltips, status
    defer rl.UnloadFont(font_large);
    defer rl.UnloadFont(font_medium);
    defer rl.UnloadFont(font_small);

    rl.SetTextureFilter(font_large.texture, rl.TEXTURE_FILTER_BILINEAR);
    rl.SetTextureFilter(font_medium.texture, rl.TEXTURE_FILTER_BILINEAR);
    rl.SetTextureFilter(font_small.texture, rl.TEXTURE_FILTER_BILINEAR);
    rl.SetTargetFPS(60);

    // Fetch initial data
    var jobs: []CronJob = fetchCronJobs(allocator, config, app_config.debug) catch |err| {
        std.debug.print("Failed to fetch jobs: {}\n", .{err});
        return;
    };
    var jobs_ui: []JobUIState = allocator.alloc(JobUIState, jobs.len) catch {
        std.debug.print("Failed to allocate UI state\n", .{});
        return;
    };
    for (jobs_ui) |*ui| {
        ui.* = JobUIState{};
    }

    var last_refresh: i64 = std.time.milliTimestamp();
    const refresh_interval_ms: i64 = 30000; // Refresh every 30 seconds

    // Main loop
    while (!rl.WindowShouldClose()) {
        const now = std.time.milliTimestamp();

        // Auto-refresh
        if (now - last_refresh > refresh_interval_ms) {
            refreshJobs(allocator, config, &jobs, &jobs_ui, app_config.debug);
            last_refresh = now;
        }

        // Manual refresh with R key
        if (rl.IsKeyPressed(rl.KEY_R)) {
            refreshJobs(allocator, config, &jobs, &jobs_ui, app_config.debug);
            last_refresh = now;
        }

        // Reset executing state after timeout (30 seconds)
        for (jobs_ui) |*ui| {
            if (ui.executing and (now - ui.execute_start_ms > 30000)) {
                ui.executing = false;
            }
        }

        // Render
        rl.BeginDrawing();
        defer rl.EndDrawing();

        rl.ClearBackground(rl.Color{ .r = 20, .g = 20, .b = 30, .a = 255 });

        const screen_width = rl.GetScreenWidth();
        const screen_height = rl.GetScreenHeight();

        // Title
        rl.DrawTextEx(font_large, "Clawd Cron Jobs", .{ .x = 20, .y = 20 }, 24, 1, rl.Color{ .r = 255, .g = 255, .b = 255, .a = 255 });

        // Help button (top-right)
        const help_btn = drawButton(
            @as(f32, @floatFromInt(screen_width - 35)),
            20,
            25,
            25,
            "?",
            rl.Color{ .r = 80, .g = 80, .b = 120, .a = 255 },
            font_small,
        );
        const help_hovered = isButtonHovered(help_btn); // Track for deferred tooltip

        // Job count
        var count_buf: [64]u8 = undefined;
        const count_text = std.fmt.bufPrintZ(&count_buf, "{d} jobs", .{jobs.len}) catch "Jobs";
        rl.DrawTextEx(font_medium, count_text.ptr, .{ .x = 20, .y = 50 }, 16, 1, rl.Color{ .r = 150, .g = 150, .b = 150, .a = 255 });

        // Draw jobs
        var y_pos: f32 = 90;
        var hovered_job_id: ?[]const u8 = null; // Track for deferred tooltip
        for (jobs, 0..) |job, i| {
            const ui_state = if (i < jobs_ui.len) &jobs_ui[i] else null;
            const is_executing = if (ui_state) |ui| ui.executing else false;

            // Determine color based on state
            const color = if (is_executing) blk: {
                // Pulsing yellow for executing
                const pulse_val = @as(f32, @floatFromInt(@mod(now, 1000))) / 1000.0;
                const pulse: u8 = @intFromFloat(180.0 + 75.0 * @sin(pulse_val * 6.28));
                break :blk rl.Color{ .r = 255, .g = pulse, .b = 50, .a = 255 };
            } else if (job.enabled)
                rl.Color{ .r = 100, .g = 255, .b = 100, .a = 255 }
            else
                rl.Color{ .r = 120, .g = 120, .b = 120, .a = 180 };

            const text_alpha: u8 = if (job.enabled or is_executing) 255 else 150;

            // Marker (filled/empty circle)
            const marker = if (job.enabled) "●" else "○";
            var marker_buf: [4]u8 = undefined;
            const marker_z = std.fmt.bufPrintZ(&marker_buf, "{s}", .{marker}) catch ".";
            rl.DrawTextEx(font_medium, marker_z.ptr, .{ .x = 30, .y = y_pos }, 18, 1, color);

            // Job name (truncate if too long)
            var name_buf: [128]u8 = undefined;
            const display_name = if (job.name.len > 30) job.name[0..27] else job.name;
            const name_text: [:0]const u8 = if (job.name.len > 30)
                std.fmt.bufPrintZ(&name_buf, "{s}...", .{display_name}) catch "..."
            else
                std.fmt.bufPrintZ(&name_buf, "{s}", .{job.name}) catch "?";

            // Calculate name bounds for hover detection
            const name_width = rl.MeasureTextEx(font_medium, name_text.ptr, 18, 1).x;
            const name_rect = rl.Rectangle{ .x = 60, .y = y_pos, .width = name_width, .height = 20 };
            const name_hovered = rl.CheckCollisionPointRec(rl.GetMousePosition(), name_rect);

            // Track hovered job for deferred tooltip drawing
            if (name_hovered) {
                hovered_job_id = job.id;
            }

            // Draw name with underline hint if hoverable
            const name_color = if (name_hovered)
                rl.Color{ .r = 150, .g = 200, .b = 255, .a = text_alpha }
            else
                rl.Color{ .r = 255, .g = 255, .b = 255, .a = text_alpha };
            rl.DrawTextEx(font_medium, name_text.ptr, .{ .x = 60, .y = y_pos }, 18, 1, name_color);

            // Executing indicator
            if (is_executing) {
                rl.DrawTextEx(font_small, " (running...)", .{ .x = 60 + name_width + 5, .y = y_pos + 2 }, 14, 1, rl.Color{ .r = 255, .g = 200, .b = 50, .a = 255 });
            }

            // Buttons on the right
            const btn_y = y_pos - 2;
            const run_btn_x: f32 = @floatFromInt(screen_width - 125);
            const toggle_btn_x: f32 = @floatFromInt(screen_width - 65);

            // Run Now button (green, or gray if disabled)
            const run_btn_color = if (job.enabled)
                rl.Color{ .r = 50, .g = 150, .b = 50, .a = 255 }
            else
                rl.Color{ .r = 80, .g = 80, .b = 80, .a = 150 };
            const run_btn = drawButton(run_btn_x, btn_y, 50, 22, "Run", run_btn_color, font_small);
            if (job.enabled and isButtonClicked(run_btn)) {
                runJobNow(allocator, job.id, app_config.debug) catch |err| {
                    std.debug.print("Failed to run job: {}\n", .{err});
                };
                if (ui_state) |ui| {
                    ui.executing = true;
                    ui.execute_start_ms = now;
                }
            }

            // Toggle button (red Stop / blue Start)
            const toggle_color = if (job.enabled)
                rl.Color{ .r = 180, .g = 50, .b = 50, .a = 255 }
            else
                rl.Color{ .r = 50, .g = 120, .b = 180, .a = 255 };
            const toggle_label = if (job.enabled) "Disable" else "Enable";
            const toggle_btn = drawButton(toggle_btn_x, btn_y, 55, 22, toggle_label, toggle_color, font_small);
            if (isButtonClicked(toggle_btn)) {
                toggleJobEnabled(allocator, config, job.id, !job.enabled, app_config.debug) catch |err| {
                    std.debug.print("Failed to toggle job: {}\n", .{err});
                };
                // Trigger refresh
                refreshJobs(allocator, config, &jobs, &jobs_ui, app_config.debug);
                last_refresh = now;
            }

            y_pos += 22;

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

                rl.DrawTextEx(font_small, time_text.ptr, .{ .x = 60, .y = y_pos }, 14, 1, rl.Color{ .r = 100, .g = 200, .b = 255, .a = text_alpha });
                y_pos += 20;
            }

            // Last status
            if (job.state.lastStatus) |status| {
                var status_buf: [128]u8 = undefined;
                const display_status = if (status.len > 45) status[0..42] else status;
                const status_text: [:0]const u8 = if (status.len > 45)
                    std.fmt.bufPrintZ(&status_buf, "  {s}...", .{display_status}) catch "  ..."
                else
                    std.fmt.bufPrintZ(&status_buf, "  {s}", .{status}) catch "  ?";

                const status_color = if (std.mem.indexOf(u8, status, "success") != null or std.mem.indexOf(u8, status, "complete") != null)
                    rl.Color{ .r = 100, .g = 255, .b = 100, .a = 200 }
                else if (std.mem.indexOf(u8, status, "error") != null or std.mem.indexOf(u8, status, "fail") != null)
                    rl.Color{ .r = 255, .g = 100, .b = 100, .a = 200 }
                else
                    rl.Color{ .r = 200, .g = 200, .b = 200, .a = 200 };

                rl.DrawTextEx(font_small, status_text.ptr, .{ .x = 60, .y = y_pos }, 13, 1, status_color);
                y_pos += 18;
            }

            y_pos += 10; // Spacing between jobs

            // Stop if we run out of space
            if (y_pos > @as(f32, @floatFromInt(screen_height)) - 50) break;
        }

        // Draw tooltip AFTER all jobs (so it renders on top)
        if (hovered_job_id) |job_id| {
            if (readJobStatusFile(allocator, app_config.status_dir, job_id)) |status_content| {
                defer allocator.free(status_content);

                const mouse_pos = rl.GetMousePosition();
                const tooltip_x = mouse_pos.x + 10;
                const tooltip_y = mouse_pos.y + 20;

                const max_lines: usize = 15;
                const line_height: f32 = 16;
                const max_tooltip_width: f32 = 350;
                const font_size: f32 = 14;

                // Word-wrap the content into display lines
                var wrapped_lines: [32][128]u8 = undefined;
                var wrapped_line_lens: [32]usize = undefined;
                var num_wrapped_lines: usize = 0;

                var content_idx: usize = 0;
                while (content_idx < status_content.len and num_wrapped_lines < max_lines) {
                    // Find end of this source line (or end of content)
                    var line_end = content_idx;
                    while (line_end < status_content.len and status_content[line_end] != '\n') {
                        line_end += 1;
                    }
                    const source_line = status_content[content_idx..line_end];

                    if (source_line.len == 0) {
                        // Empty line
                        wrapped_lines[num_wrapped_lines][0] = 0;
                        wrapped_line_lens[num_wrapped_lines] = 0;
                        num_wrapped_lines += 1;
                    } else {
                        // Word-wrap this line
                        var wrap_start: usize = 0;
                        while (wrap_start < source_line.len and num_wrapped_lines < max_lines) {
                            var wrap_end: usize = wrap_start;
                            var last_space: usize = wrap_start;

                            // Build line word by word
                            while (wrap_end < source_line.len) {
                                // Find next word boundary
                                var word_end = wrap_end;
                                while (word_end < source_line.len and source_line[word_end] != ' ') {
                                    word_end += 1;
                                }

                                // Measure line with this word
                                var measure_buf: [128]u8 = undefined;
                                const test_len = @min(word_end - wrap_start, 127);
                                @memcpy(measure_buf[0..test_len], source_line[wrap_start .. wrap_start + test_len]);
                                measure_buf[test_len] = 0;
                                const width = rl.MeasureTextEx(font_small, &measure_buf, font_size, 1).x;

                                if (width > max_tooltip_width and wrap_end > wrap_start) {
                                    // Line too long, wrap at last space (or force break)
                                    if (last_space > wrap_start) {
                                        wrap_end = last_space;
                                    }
                                    break;
                                }

                                // Accept this word
                                wrap_end = word_end;
                                if (wrap_end < source_line.len and source_line[wrap_end] == ' ') {
                                    last_space = wrap_end;
                                    wrap_end += 1; // skip space
                                }
                            }

                            // Store this wrapped line
                            const line_len = @min(wrap_end - wrap_start, 127);
                            if (line_len > 0) {
                                // Trim trailing space
                                var trimmed_len = line_len;
                                while (trimmed_len > 0 and source_line[wrap_start + trimmed_len - 1] == ' ') {
                                    trimmed_len -= 1;
                                }
                                @memcpy(wrapped_lines[num_wrapped_lines][0..trimmed_len], source_line[wrap_start .. wrap_start + trimmed_len]);
                                wrapped_lines[num_wrapped_lines][trimmed_len] = 0;
                                wrapped_line_lens[num_wrapped_lines] = trimmed_len;
                                num_wrapped_lines += 1;
                            }

                            wrap_start = wrap_end;
                            // Skip leading spaces on new line
                            while (wrap_start < source_line.len and source_line[wrap_start] == ' ') {
                                wrap_start += 1;
                            }
                        }
                    }

                    content_idx = line_end + 1; // skip newline
                }

                // Calculate actual max width from wrapped lines
                var actual_max_width: f32 = 200;
                for (0..num_wrapped_lines) |li| {
                    const w = rl.MeasureTextEx(font_small, &wrapped_lines[li], font_size, 1).x;
                    if (w > actual_max_width) actual_max_width = w;
                }

                const tooltip_width = @min(actual_max_width + 20, max_tooltip_width + 20);
                const tooltip_height = @as(f32, @floatFromInt(num_wrapped_lines)) * line_height + 20;

                const adj_x = if (tooltip_x + tooltip_width > @as(f32, @floatFromInt(screen_width - 10)))
                    @as(f32, @floatFromInt(screen_width)) - tooltip_width - 10
                else
                    tooltip_x;

                rl.DrawRectangleRounded(
                    .{ .x = adj_x, .y = tooltip_y, .width = tooltip_width, .height = tooltip_height },
                    0.1,
                    8,
                    rl.Color{ .r = 30, .g = 30, .b = 45, .a = 250 },
                );
                rl.DrawRectangleRoundedLines(
                    .{ .x = adj_x, .y = tooltip_y, .width = tooltip_width, .height = tooltip_height },
                    0.1,
                    8,
                    1,
                    rl.Color{ .r = 100, .g = 100, .b = 150, .a = 255 },
                );

                // Draw wrapped lines
                var text_y = tooltip_y + 10;
                for (0..num_wrapped_lines) |li| {
                    rl.DrawTextEx(font_small, &wrapped_lines[li], .{ .x = adj_x + 10, .y = text_y }, font_size, 1, rl.Color{ .r = 220, .g = 220, .b = 220, .a = 255 });
                    text_y += line_height;
                }
            } else |_| {
                const mouse_pos = rl.GetMousePosition();
                const tooltip_x = mouse_pos.x + 10;
                const tooltip_y = mouse_pos.y + 20;

                rl.DrawRectangleRounded(
                    .{ .x = tooltip_x, .y = tooltip_y, .width = 300, .height = 58 },
                    0.1,
                    8,
                    rl.Color{ .r = 30, .g = 30, .b = 45, .a = 250 },
                );

                var hint_buf: [256]u8 = undefined;
                const hint1 = std.fmt.bufPrintZ(&hint_buf, "No status file found.", .{}) catch "No status file";
                rl.DrawTextEx(font_small, hint1.ptr, .{ .x = tooltip_x + 10, .y = tooltip_y + 10 }, 14, 1, rl.Color{ .r = 180, .g = 180, .b = 180, .a = 255 });

                var path_hint_buf: [256]u8 = undefined;
                const hint2 = std.fmt.bufPrintZ(&path_hint_buf, "Create: {s}/{s}.md", .{ app_config.status_dir, job_id }) catch "Create status file";
                rl.DrawTextEx(font_small, hint2.ptr, .{ .x = tooltip_x + 10, .y = tooltip_y + 32 }, 13, 1, rl.Color{ .r = 130, .g = 160, .b = 200, .a = 255 });
            }
        }

        // Draw help tooltip AFTER all jobs (so it renders on top)
        if (help_hovered) {
            const tooltip_x: f32 = @floatFromInt(screen_width - 320);
            const tooltip_y: f32 = 50;

            rl.DrawRectangleRounded(
                .{ .x = tooltip_x, .y = tooltip_y, .width = 300, .height = 100 },
                0.1,
                8,
                rl.Color{ .r = 40, .g = 40, .b = 60, .a = 245 },
            );

            rl.DrawTextEx(font_small, "Jobs can write status to:", .{ .x = tooltip_x + 10, .y = tooltip_y + 10 }, 14, 1, rl.Color{ .r = 220, .g = 220, .b = 220, .a = 255 });

            var path_buf: [256]u8 = undefined;
            const tooltip_path = std.fmt.bufPrintZ(&path_buf, "{s}/[job-id].md", .{app_config.status_dir}) catch "[status-dir]/[job-id].md";
            rl.DrawTextEx(font_small, tooltip_path.ptr, .{ .x = tooltip_x + 10, .y = tooltip_y + 30 }, 13, 1, rl.Color{ .r = 150, .g = 200, .b = 255, .a = 255 });

            rl.DrawTextEx(font_small, "Hover job name to see status preview.", .{ .x = tooltip_x + 10, .y = tooltip_y + 54 }, 13, 1, rl.Color{ .r = 180, .g = 180, .b = 180, .a = 255 });
            rl.DrawTextEx(font_small, "Click Run/Stop to control jobs.", .{ .x = tooltip_x + 10, .y = tooltip_y + 74 }, 13, 1, rl.Color{ .r = 180, .g = 180, .b = 180, .a = 255 });
        }

        // Footer with refresh info
        const seconds_since_refresh = @divTrunc(now - last_refresh, 1000);
        var footer_buf: [128]u8 = undefined;
        const footer_text = std.fmt.bufPrintZ(&footer_buf, "Updated {d}s ago | R=refresh | Click buttons to control jobs", .{seconds_since_refresh}) catch "Press R to refresh";
        const footer_y: f32 = @floatFromInt(screen_height - 30);
        rl.DrawTextEx(font_small, footer_text.ptr, .{ .x = 20, .y = footer_y }, 12, 1, rl.Color{ .r = 120, .g = 120, .b = 120, .a = 255 });
    }

    // Cleanup
    freeJobs(allocator, jobs);
    if (jobs_ui.len > 0) allocator.free(jobs_ui);
}

fn printHelp() void {
    const help_text =
        \\Clawd Widget - Cron Job Monitor
        \\
        \\Usage: clawd-widget [OPTIONS]
        \\
        \\Options:
        \\  -c, --config <path>      Path to clawdbot config file
        \\                           (default: ~/.clawdbot/clawdbot.json)
        \\  -s, --status-dir <path>  Directory for job status files
        \\                           (default: ~/clawd/cron-status)
        \\  -d, --debug              Print API calls to stderr
        \\  -h, --help               Show this help message
        \\
        \\Controls:
        \\  R          Refresh job list
        \\  Run        Execute job immediately
        \\  Stop/Start Toggle job enabled state
        \\
        \\Status Files:
        \\  Jobs can write status to [status-dir]/[job-id].md
        \\  Widget displays the first line as a preview.
        \\
    ;
    std.debug.print("{s}", .{help_text});
}

fn refreshJobs(allocator: std.mem.Allocator, config: ClawdbotConfig, jobs: *[]CronJob, jobs_ui: *[]JobUIState, debug: bool) void {
    // Preserve executing states
    var preserved_states = std.StringHashMap(JobUIState).init(allocator);
    defer preserved_states.deinit();

    for (jobs.*, jobs_ui.*) |job, ui| {
        if (ui.executing) {
            preserved_states.put(job.id, ui) catch {};
        }
    }

    // Free old data
    freeJobs(allocator, jobs.*);
    if (jobs_ui.len > 0) allocator.free(jobs_ui.*);

    // Fetch new data
    jobs.* = fetchCronJobs(allocator, config, debug) catch |err| blk: {
        std.debug.print("Failed to fetch jobs: {}\n", .{err});
        break :blk allocator.alloc(CronJob, 0) catch &[_]CronJob{};
    };

    // Recreate UI state, preserving executing flags
    jobs_ui.* = allocator.alloc(JobUIState, jobs.len) catch &[_]JobUIState{};
    for (jobs.*, 0..) |job, i| {
        if (i < jobs_ui.len) {
            if (preserved_states.get(job.id)) |state| {
                jobs_ui.*[i] = state;
            } else {
                jobs_ui.*[i] = JobUIState{};
            }
        }
    }
}

fn freeJobs(allocator: std.mem.Allocator, jobs: []CronJob) void {
    for (jobs) |job| {
        allocator.free(job.name);
        allocator.free(job.id);
        if (job.state.lastStatus) |status| allocator.free(status);
    }
    if (jobs.len > 0) allocator.free(jobs);
}

fn isButtonClicked(rect: rl.Rectangle) bool {
    if (rl.IsMouseButtonPressed(rl.MOUSE_BUTTON_LEFT)) {
        const mouse_pos = rl.GetMousePosition();
        return rl.CheckCollisionPointRec(mouse_pos, rect);
    }
    return false;
}

fn isButtonHovered(rect: rl.Rectangle) bool {
    const mouse_pos = rl.GetMousePosition();
    return rl.CheckCollisionPointRec(mouse_pos, rect);
}

fn drawButton(x: f32, y: f32, width: f32, height: f32, label: []const u8, base_color: rl.Color, font: rl.Font) rl.Rectangle {
    const rect = rl.Rectangle{ .x = x, .y = y, .width = width, .height = height };

    // Hover effect - lighten color
    const is_hovered = isButtonHovered(rect);
    const color = if (is_hovered)
        rl.Color{
            .r = @min(@as(u16, base_color.r) + 40, 255),
            .g = @min(@as(u16, base_color.g) + 40, 255),
            .b = @min(@as(u16, base_color.b) + 40, 255),
            .a = base_color.a,
        }
    else
        base_color;

    rl.DrawRectangleRounded(rect, 0.3, 8, color);

    // Center text in button
    var label_buf: [32]u8 = undefined;
    const label_z = std.fmt.bufPrintZ(&label_buf, "{s}", .{label}) catch "?";
    const text_width = rl.MeasureTextEx(font, label_z.ptr, 13, 1).x;
    const text_x = x + (width - text_width) / 2;
    const text_y = y + (height - 13) / 2;
    rl.DrawTextEx(font, label_z.ptr, .{ .x = text_x, .y = text_y }, 13, 1, rl.Color{ .r = 255, .g = 255, .b = 255, .a = 255 });

    return rect;
}

fn loadConfig(allocator: std.mem.Allocator, custom_path: ?[]const u8) !ClawdbotConfig {
    var path_buf: [1024]u8 = undefined;
    const config_path = if (custom_path) |p|
        p
    else blk: {
        const home = std.posix.getenv("HOME") orelse return error.NoHomeDir;
        break :blk try std.fmt.bufPrint(&path_buf, "{s}/.clawdbot/clawdbot.json", .{home});
    };

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

fn runJobNow(allocator: std.mem.Allocator, job_id: []const u8, debug: bool) !void {
    // Use CLI for force mode since HTTP tool endpoint doesn't support it
    if (debug) {
        std.debug.print("[DEBUG] Running: clawdbot cron run {s} --force\n", .{job_id});
    }

    var child = std.process.Child.init(
        &.{ "clawdbot", "cron", "run", job_id, "--force", "--timeout", "60000" },
        allocator,
    );
    child.spawn() catch |err| {
        if (debug) {
            std.debug.print("[DEBUG] Failed to spawn clawdbot: {}\n", .{err});
        }
        return err;
    };

    // Don't wait for completion - job runs async
    if (debug) {
        std.debug.print("[DEBUG] Job triggered (running in background)\n", .{});
    }
}

fn toggleJobEnabled(allocator: std.mem.Allocator, config: ClawdbotConfig, job_id: []const u8, enabled: bool, debug: bool) !void {
    var client = http.Client{ .allocator = allocator };
    defer client.deinit();

    // Build URL
    var url_buf: [256]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://localhost:{d}/tools/invoke", .{config.gateway.port});

    // Build request body - args wrapper required for gateway
    var body_buf: [512]u8 = undefined;
    const enabled_str = if (enabled) "true" else "false";
    const body = try std.fmt.bufPrint(&body_buf, "{{\"tool\": \"cron\", \"action\": \"update\", \"args\": {{\"jobId\": \"{s}\", \"patch\": {{\"enabled\": {s}}}}}}}", .{ job_id, enabled_str });

    if (debug) {
        std.debug.print("[DEBUG] POST {s}\n", .{url});
        std.debug.print("[DEBUG] Body: {s}\n", .{body});
    }

    // Build auth header
    var auth_buf: [512]u8 = undefined;
    const auth_header = try std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{config.gateway.auth.token});

    // Response buffer
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

    if (debug) {
        std.debug.print("[DEBUG] Response status: {}\n", .{result.status});
    }

    if (result.status != .ok) {
        return error.HttpError;
    }
}

fn readJobStatusFile(allocator: std.mem.Allocator, status_dir: []const u8, job_id: []const u8) ![]const u8 {
    var path_buf: [1024]u8 = undefined;
    const status_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}.md", .{ status_dir, job_id });

    const file = std.fs.openFileAbsolute(status_path, .{}) catch |err| {
        return err;
    };
    defer file.close();

    // Read first 512 bytes (preview)
    var read_buf: [512]u8 = undefined;
    const bytes_read = try file.read(&read_buf);
    if (bytes_read == 0) return error.EmptyFile;

    return try allocator.dupe(u8, read_buf[0..bytes_read]);
}

fn fetchCronJobs(allocator: std.mem.Allocator, config: ClawdbotConfig, debug: bool) ![]CronJob {
    var client = http.Client{ .allocator = allocator };
    defer client.deinit();

    // Build URL
    var url_buf: [256]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://localhost:{d}/tools/invoke", .{config.gateway.port});

    // Build request body - include disabled jobs so user can re-enable them
    const body = "{\"tool\": \"cron\", \"action\": \"list\", \"args\": {\"includeDisabled\": true}}";

    if (debug) {
        std.debug.print("[DEBUG] POST {s}\n", .{url});
        std.debug.print("[DEBUG] Body: {s}\n", .{body});
    }

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

    if (debug) {
        std.debug.print("[DEBUG] Response status: {}\n", .{result.status});
    }

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
