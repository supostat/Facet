const std = @import("std");

// Single declared build entry for Facet Phase 1.
//
// No Zig sources compile yet (the engine core arrives at a later phase). This
// build orchestrates the Swift toolchain directly via swiftc: it produces the
// windowed app binary and a separate headless snapshot/metric test binary,
// wiring `zig build`, `zig build run`, `zig build run-debug`, and
// `zig build test`. swiftc -o output goes through addOutputFileArg so the
// compiled artifacts are content-addressed and cached by the build graph.

const swift_target = "arm64-apple-macosx26.0";

const app_sources = [_][]const u8{
    "src/platform/Renderer.swift",
    "src/platform/FrameLoop.swift",
    "src/platform/Window.swift",
    "src/platform/AppMain.swift",
};

// The test target compiles Renderer.swift ONLY — it must not pull in the
// windowing/event-loop types, which cannot run headlessly.
const test_sources = [_][]const u8{
    "src/platform/Renderer.swift",
    "tests/snapshots/clear_frame_test.swift",
};

const linked_frameworks = [_][]const u8{ "Metal", "QuartzCore", "AppKit" };

pub fn build(b: *std.Build) void {
    const app_binary = compileSwift(b, "facet", &app_sources, .release);
    b.getInstallStep().dependOn(&b.addInstallBinFile(app_binary, "facet").step);

    addRunStep(b, "run", "Build and run the windowed app (Metal validation OFF)", app_binary, false);

    const debug_app_binary = compileSwift(b, "facet-debug", &app_sources, .debug);
    addRunStep(b, "run-debug", "Build and run the app with Metal API Validation ON", debug_app_binary, true);

    const test_binary = compileSwift(b, "clear-frame-test", &test_sources, .debug);
    const test_run = runBinary(b, test_binary, true);
    test_run.expectExitCode(0);
    b.step("test", "Run the headless snapshot/metric test (Metal validation ON)").dependOn(&test_run.step);
}

const Optimization = enum { debug, release };

fn compileSwift(
    b: *std.Build,
    binary_basename: []const u8,
    sources: []const []const u8,
    optimization: Optimization,
) std.Build.LazyPath {
    const compile = b.addSystemCommand(&.{ "swiftc", "-target", swift_target });
    switch (optimization) {
        .release => compile.addArg("-O"),
        .debug => compile.addArg("-Onone"),
    }
    for (sources) |source| compile.addFileArg(b.path(source));
    for (linked_frameworks) |framework| compile.addArgs(&.{ "-framework", framework });
    compile.addArg("-o");
    return compile.addOutputFileArg(binary_basename);
}

fn runBinary(b: *std.Build, binary: std.Build.LazyPath, metal_validation: bool) *std.Build.Step.Run {
    const run = std.Build.Step.Run.create(b, "run swift binary");
    run.addFileArg(binary);
    if (metal_validation) {
        run.setEnvironmentVariable("METAL_DEVICE_WRAPPER_TYPE", "1");
        run.setEnvironmentVariable("MTL_DEBUG_LAYER", "1");
    }
    return run;
}

fn addRunStep(
    b: *std.Build,
    step_name: []const u8,
    description: []const u8,
    binary: std.Build.LazyPath,
    metal_validation: bool,
) void {
    const run = runBinary(b, binary, metal_validation);
    if (b.args) |args| run.addArgs(args);
    b.step(step_name, description).dependOn(&run.step);
}
