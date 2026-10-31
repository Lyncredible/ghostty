const Ghostty = @This();

const std = @import("std");
const Config = @import("Config.zig");
const SharedDeps = @import("SharedDeps.zig");

/// The primary Ghostty executable.
exe: *std.Build.Step.Compile,

/// The install step for the executable.
install_step: *std.Build.Step.InstallArtifact,

/// On Windows, the install step for the `ghostty.com` console launcher.
launcher_install_step: ?*std.Build.Step.InstallArtifact = null,

pub fn init(b: *std.Build, cfg: *const Config, deps: *const SharedDeps) !Ghostty {
    const exe: *std.Build.Step.Compile = b.addExecutable(.{
        .name = "ghostty",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = cfg.target,
            .optimize = cfg.optimize,
            .strip = cfg.strip,
            .omit_frame_pointer = cfg.omitFramePointer(),
            // Windows needs unwind tables for structured exception
            // handling (MinGW's startup code registers a handler), so
            // we keep them there even when stripping.
            .unwind_tables = if (cfg.strip and cfg.target.result.os.tag != .windows)
                .none
            else
                .sync,
        }),
        // Crashes on x86_64 self-hosted on 0.15.1
        .use_llvm = true,
    });
    const install_step = b.addInstallArtifact(exe, .{});

    // Set PIE if requested
    if (cfg.pie) exe.pie = true;

    // Add the shared dependencies. When building only lib-vt we skip
    // heavy deps so cross-compilation doesn't pull in GTK, etc. An
    // explicit -Demit-exe builds the app alongside lib-vt, so it needs them.
    if (!cfg.emit_lib_vt or cfg.emit_exe) _ = try deps.add(exe);

    // Check for possible issues
    try checkNixShell(exe, cfg);

    // Add patchelf step if that option is specified.
    _ = cfg.addPatchElf(exe, &install_step.step);

    // OS-specific
    switch (cfg.target.result.os.tag) {
        .windows => {
            exe.subsystem = .windows;
            exe.root_module.addWin32ResourceFile(.{
                .file = b.path("dist/windows/ghostty.rc"),
            });
        },

        else => {},
    }

    // On Windows, a console program installed as ghostty.com, which
    // shells run for `ghostty` before ghostty.exe. See its source.
    const launcher_install: ?*std.Build.Step.InstallArtifact = if (cfg.target.result.os.tag == .windows) launcher: {
        const launcher = b.addExecutable(.{
            .name = "ghostty-launcher",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main_windows_launcher.zig"),
                .target = cfg.target,
                .optimize = cfg.optimize,
                .strip = cfg.strip,
            }),
        });
        launcher.subsystem = .console;
        launcher.root_module.addWin32ResourceFile(.{
            .file = b.path("dist/windows/ghostty.rc"),
        });
        break :launcher b.addInstallArtifact(launcher, .{
            .dest_sub_path = "ghostty.com",
            .pdb_dir = .disabled,
        });
    } else null;

    return .{
        .exe = exe,
        .install_step = install_step,
        .launcher_install_step = launcher_install,
    };
}

/// Add the ghostty exe to the install target.
pub fn install(self: *const Ghostty) void {
    const b = self.install_step.step.owner;
    b.getInstallStep().dependOn(&self.install_step.step);
    if (self.launcher_install_step) |step| b.getInstallStep().dependOn(&step.step);
}

/// If we're in NixOS but not in the shell environment then we issue
/// a warning because the rpath may not be setup properly. This doesn't modify
/// our build in any way but addresses a common build-from-source issue
/// for a subset of users.
fn checkNixShell(exe: *std.Build.Step.Compile, cfg: *const Config) !void {
    // Non-Linux doesn't have rpath issues.
    if (cfg.target.result.os.tag != .linux) return;

    // When cross-compiling, we don't need to worry about matching our
    // Nix shell rpath since the resulting binary will be run on a
    // separate system.
    if (!cfg.target.query.isNativeCpu()) return;
    if (!cfg.target.query.isNativeOs()) return;

    // Verify we're in NixOS
    std.Io.Dir.accessAbsolute(exe.step.owner.graph.io, "/etc/NIXOS", .{}) catch return;

    // If we're in a nix shell, not a problem
    if (cfg.env.get("IN_NIX_SHELL") != null) return;

    std.log.warn(
        "\x1b[" ++ color_map.get("yellow").? ++
            "\x1b[" ++ color_map.get("d").? ++
            \\Detected building on and for NixOS outside of the Nix shell environment.
            \\
            \\The resulting ghostty binary will likely fail on launch because it is
            \\unable to dynamically load the windowing libs (X11, Wayland, etc.).
            \\We highly recommend running only within the Nix build environment
            \\and the resulting binary will be portable across your system.
            \\
            \\To run in the Nix build environment, use the following command.
            \\Append any additional options like (`-Doptimize` flags). The resulting
            \\binary will be in zig-out as usual.
            \\
            \\  nix develop -c zig build
            \\
        ++
            "\x1b[0m",
        .{},
    );
}

/// ANSI escape codes for colored log output
const color_map = std.StaticStringMap([]const u8).initComptime(.{
    &.{ "black", "30m" },
    &.{ "blue", "34m" },
    &.{ "b", "1m" },
    &.{ "d", "2m" },
    &.{ "cyan", "36m" },
    &.{ "green", "32m" },
    &.{ "magenta", "35m" },
    &.{ "red", "31m" },
    &.{ "white", "37m" },
    &.{ "yellow", "33m" },
});
