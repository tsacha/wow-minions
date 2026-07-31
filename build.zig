const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Détection de l'OS hôte pour désactiver minion/launcher sous macOS
    const host_is_macos = b.graph.host.result.os.tag == .macos;

    const wine_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86,
        .os_tag = .windows,
        .abi = .gnu,
    });

    const Expansion = enum { classic, tbc, wotlk };
    const exp_str = b.option([]const u8, "expansion", "Game version (classic, tbc, wotlk)") orelse "wotlk";
    const expansion = std.meta.stringToEnum(Expansion, exp_str) orelse .wotlk;
    const gui = b.option(bool, "gui", "Build mastermind with the raylib GUI") orelse true;
    const pathfinding = b.option(bool, "pathfinding", "Enable Detour pathfinding for GUI navigate_to (mmaps, waypoints)") orelse false;
    const max_bots = b.option(usize, "max-bots", "Maximum concurrent minion connections (default 25)") orelse 25;

    const build_options = b.addOptions();
    build_options.addOption(Expansion, "expansion", expansion);
    build_options.addOption(bool, "gui", gui);
    build_options.addOption(bool, "pathfinding", pathfinding);
    build_options.addOption(usize, "max_bots", max_bots);
    const opts_mod = build_options.createModule();

    const protocol_wine = b.createModule(.{ .root_source_file = b.path("src/protocol/protocol.zig"), .target = wine_target, .optimize = optimize });
    const protocol_host = b.createModule(.{ .root_source_file = b.path("src/protocol/protocol.zig"), .target = target, .optimize = optimize });
    const minion_spell_packets_host = b.createModule(.{ .root_source_file = b.path("src/minion/spell_packets.zig"), .target = target, .optimize = optimize });

    const gen_wire_manifest = b.addExecutable(.{
        .name = "gen-wire-manifest",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gen_wire_manifest/main.zig"),
            .target = target,
            .optimize = .Debug,
            .imports = &.{
                .{ .name = "protocol", .module = protocol_host },
            },
        }),
    });
    const run_gen_wire = b.addRunArtifact(gen_wire_manifest);
    run_gen_wire.addArg("src/protocol/generated/wire_layout.json");
    const gen_protocol_step = b.step("gen-protocol", "Regenerate src/protocol/generated/wire_layout.json from protocol.zig");
    gen_protocol_step.dependOn(&run_gen_wire.step);

    const types_mod = b.createModule(.{
        .root_source_file = b.path("src/mastermind/types.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protocol", .module = protocol_host },
            .{ .name = "build_options", .module = opts_mod },
        },
    });

    const gui_command_mod = b.createModule(.{
        .root_source_file = b.path("src/mastermind/gui/command.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "types", .module = types_mod },
        },
    });

    const registry_mod = b.createModule(.{
        .root_source_file = b.path("src/mastermind/net/registry.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protocol", .module = protocol_host },
            .{ .name = "types", .module = types_mod },
        },
    });

    const nav_shared_mod = b.createModule(.{
        .root_source_file = b.path("src/mastermind/nav/shared.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "build_options", .module = opts_mod },
            .{ .name = "types", .module = types_mod },
            .{ .name = "gui_command", .module = gui_command_mod },
        },
    });

    const nav_mod = b.createModule(.{
        .root_source_file = if (pathfinding)
            b.path("src/mastermind/nav/detour.zig")
        else
            b.path("src/mastermind/nav/stub.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "nav_shared", .module = nav_shared_mod },
            .{ .name = "protocol", .module = protocol_host },
            .{ .name = "types", .module = types_mod },
            .{ .name = "registry", .module = registry_mod },
        },
    });

    const can_run_wine_tests = b.graph.host.result.os.tag == wine_target.result.os.tag and
        b.graph.host.result.cpu.arch == wine_target.result.cpu.arch and
        b.graph.host.result.abi == wine_target.result.abi;

    // Variables optionnelles pour les composants Windows
    var opt_minion: ?*std.Build.Step.Compile = null;
    var opt_launcher: ?*std.Build.Step.Compile = null;
    var opt_minion_tests: ?*std.Build.Step.Compile = null;
    var opt_launcher_tests: ?*std.Build.Step.Compile = null;

    if (!host_is_macos) {
        // --- Minion ---
        const win32_minion_c = b.addTranslateC(.{
            .root_source_file = b.path("src/minion/win32.h"),
            .target = wine_target,
            .optimize = optimize,
        });

        const minion = b.addLibrary(.{
            .name = "minion",
            .linkage = .dynamic,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/minion/main.zig"),
                .target = wine_target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "win32", .module = win32_minion_c.createModule() },
                    .{ .name = "protocol", .module = protocol_wine },
                    .{ .name = "build_options", .module = opts_mod },
                },
            }),
        });
        minion.root_module.linkSystemLibrary("ws2_32", .{});
        b.installArtifact(minion);
        opt_minion = minion;

        // --- Launcher ---
        const win32_launcher_c = b.addTranslateC(.{
            .root_source_file = b.path("src/launcher/win32.h"),
            .target = wine_target,
            .optimize = optimize,
        });

        const launcher = b.addExecutable(.{
            .name = "launcher",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/launcher/main.zig"),
                .target = wine_target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "win32", .module = win32_launcher_c.createModule() },
                    .{ .name = "minion.dll", .module = b.createModule(.{ .root_source_file = minion.getEmittedBin() }) },
                    .{ .name = "protocol", .module = protocol_wine },
                },
                .link_libc = true,
            }),
        });
        launcher.step.dependOn(&minion.step);
        b.installArtifact(launcher);
        opt_launcher = launcher;

        // Tests Minion/Launcher
        opt_minion_tests = b.addTest(.{ .root_module = minion.root_module });
        opt_launcher_tests = b.addTest(.{ .root_module = launcher.root_module });

        addRunStep(b, launcher, "run-launcher", "Run the launcher");
    }

    // --- Mastermind ---
    // Workaround: On force LLVM si on est sur macOS, ou sur Linux en Debug
    const force_llvm = target.result.os.tag == .macos or (target.result.os.tag == .linux and optimize == .Debug);

    const detour_cflags = &.{ "-std=c++17", "-DDT_POLYREF64=1" };

    const mastermind = b.addExecutable(.{
        .name = "mastermind",
        .use_llvm = force_llvm,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/mastermind/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "protocol", .module = protocol_host },
                .{ .name = "build_options", .module = opts_mod },
                .{ .name = "nav", .module = nav_mod },
                .{ .name = "types", .module = types_mod },
                .{ .name = "registry", .module = registry_mod },
                .{ .name = "gui_command", .module = gui_command_mod },
                .{ .name = "minion_spell_packets", .module = minion_spell_packets_host },
            },
            .link_libc = true,
            .link_libcpp = true,
        }),
    });

    if (pathfinding) {
        const recast_dep = b.dependency("recastnavigation", .{
            .target = target,
            .optimize = optimize,
        });

        nav_mod.addIncludePath(b.path("src/mastermind/nav"));
        nav_mod.addIncludePath(recast_dep.path("Detour/Include"));
        mastermind.root_module.addIncludePath(b.path("src/mastermind/nav"));
        mastermind.root_module.addIncludePath(recast_dep.path("Detour/Include"));
        mastermind.root_module.addCSourceFiles(.{
            .root = recast_dep.path("."),
            .files = &.{
                "Detour/Source/DetourAlloc.cpp",
                "Detour/Source/DetourAssert.cpp",
                "Detour/Source/DetourCommon.cpp",
                "Detour/Source/DetourNavMesh.cpp",
                "Detour/Source/DetourNavMeshBuilder.cpp",
                "Detour/Source/DetourNavMeshQuery.cpp",
                "Detour/Source/DetourNode.cpp",
            },
            .flags = detour_cflags,
        });
        mastermind.root_module.addCSourceFile(.{
            .file = b.path("src/mastermind/nav/detour_bridge.cpp"),
            .flags = detour_cflags,
        });
    }

    if (gui) {
        const raylib_dep = b.dependency("raylib", .{
            .target = target,
            .optimize = .ReleaseFast,
            .platform = .sdl3,
            .linkage = .dynamic,
        });

        mastermind.root_module.addImport("ray", raylib_dep.module("raylib"));

        const raylib_lib = raylib_dep.artifact("raylib");

        // macOS: SDL3 from Homebrew
        if (target.result.os.tag == .macos) {
            const sdl3_include = std.Build.LazyPath{ .cwd_relative = "/opt/homebrew/opt/sdl3/include" };
            const sdl3_lib = std.Build.LazyPath{ .cwd_relative = "/opt/homebrew/opt/sdl3/lib" };
            raylib_lib.root_module.addIncludePath(sdl3_include);
            raylib_lib.root_module.addLibraryPath(sdl3_lib);
        }

        raylib_lib.root_module.linkSystemLibrary("SDL3", .{});
    }
    b.installArtifact(mastermind);

    // Tests & Steps Mastermind
    const mastermind_tests = b.addTest(.{ .root_module = mastermind.root_module });
    mastermind_tests.use_llvm = mastermind.use_llvm;

    addRunStep(b, mastermind, "run-mastermind", "Run the mastermind");

    // --- Global Steps ---
    const check = b.step("check", "Check compile");
    check.dependOn(&mastermind.step);
    if (opt_minion) |minion| check.dependOn(&minion.step);
    if (opt_launcher) |launcher| check.dependOn(&launcher.step);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(mastermind_tests).step);

    if (can_run_wine_tests) {
        if (opt_minion_tests) |t| test_step.dependOn(&b.addRunArtifact(t).step);
        if (opt_launcher_tests) |t| test_step.dependOn(&b.addRunArtifact(t).step);
    }

    const test_windows_step = b.step("test-windows", "Run Windows-targeted tests");
    if (opt_minion_tests) |t| test_windows_step.dependOn(&b.addRunArtifact(t).step);
    if (opt_launcher_tests) |t| test_windows_step.dependOn(&b.addRunArtifact(t).step);
}

fn addRunStep(b: *std.Build, artifact: *std.Build.Step.Compile, name: []const u8, desc: []const u8) void {
    const step = b.step(name, desc);
    const run_cmd = b.addRunArtifact(artifact);
    step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
}
