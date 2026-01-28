const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create raylib module
    const raylib_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Build raylib as a static library
    const raylib = b.addLibrary(.{
        .linkage = .static,
        .name = "raylib",
        .root_module = raylib_module,
    });

    // Add raylib source files
    const raylib_flags: []const []const u8 = &.{
        "-DPLATFORM_DESKTOP",
        "-fno-sanitize=undefined",
        "-std=gnu99",
        "-D_GNU_SOURCE",
    };

    //        "vendor/raylib/src/rmodels.c",
    //        "vendor/raylib/src/raudio.c",

    raylib.addCSourceFiles(.{
        .files = &.{ "vendor/raylib/src/rcore.c", "vendor/raylib/src/rshapes.c", "vendor/raylib/src/rtextures.c", "vendor/raylib/src/rtext.c", "vendor/raylib/src/utils.c", "vendor/raylib/src/rglfw.c" },
        .flags = raylib_flags,
    });

    raylib.addIncludePath(b.path("vendor/raylib/src"));
    raylib.addIncludePath(b.path("vendor/raylib/src/external/glfw/include"));

    // Create executable module
    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const exe = b.addExecutable(.{
        .name = "clawd-widget",
        .root_module = exe_module,
    });

    // Link raylib to the executable
    exe.linkLibrary(raylib);
    exe.root_module.addIncludePath(b.path("vendor/raylib/src"));

    // Link platform-specific libraries to the executable
    const os_tag = target.result.os.tag;
    if (os_tag == .linux) {
        exe.linkSystemLibrary("GL");
        exe.linkSystemLibrary("m");
        exe.linkSystemLibrary("pthread");
        exe.linkSystemLibrary("dl");
        exe.linkSystemLibrary("rt");
        exe.linkSystemLibrary("X11");
    } else if (os_tag == .windows) {
        exe.linkSystemLibrary("winmm");
        exe.linkSystemLibrary("gdi32");
        exe.linkSystemLibrary("opengl32");
    } else if (os_tag == .macos) {
        exe.linkFramework("OpenGL");
        exe.linkFramework("Cocoa");
        exe.linkFramework("IOKit");
        exe.linkFramework("CoreAudio");
        exe.linkFramework("CoreVideo");
    }

    b.installArtifact(exe);

    // Install font asset
    b.installFile("src/DejaVuSans.ttf", "bin/DejaVuSans.ttf");

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the widget");
    run_step.dependOn(&run_cmd.step);
}
