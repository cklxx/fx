const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const proto_mod = b.addModule("proto", .{
        .root_source_file = b.path("src/proto.zig"),
        .target = target,
        .optimize = optimize,
    });

    const server_mod = b.addModule("server", .{
        .root_source_file = b.path("src/server.zig"),
        .target = target,
        .optimize = optimize,
    });
    server_mod.addImport("proto", proto_mod);

    const client_mod = b.addModule("client", .{
        .root_source_file = b.path("src/client.zig"),
        .target = target,
        .optimize = optimize,
    });
    client_mod.addImport("proto", proto_mod);

    const server_exe = b.addExecutable(.{
        .name = "asock-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "proto", .module = proto_mod },
                .{ .name = "server", .module = server_mod },
            },
        }),
    });
    b.installArtifact(server_exe);

    const demo_exe = b.addExecutable(.{
        .name = "asock-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/demo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "proto", .module = proto_mod },
                .{ .name = "client", .module = client_mod },
            },
        }),
    });
    b.installArtifact(demo_exe);

    const testkit_exe = b.addExecutable(.{
        .name = "asock-testkit",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/testkit.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "proto", .module = proto_mod },
                .{ .name = "client", .module = client_mod },
            },
        }),
    });
    b.installArtifact(testkit_exe);

    const cli_exe = b.addExecutable(.{
        .name = "asock-cli",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "proto", .module = proto_mod },
                .{ .name = "client", .module = client_mod },
            },
        }),
    });
    b.installArtifact(cli_exe);

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/proto.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    const server_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/server.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "proto", .module = proto_mod },
            },
        }),
    });
    const run_server_tests = b.addRunArtifact(server_tests);
    test_step.dependOn(&run_server_tests.step);
}
