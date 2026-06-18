const std = @import("std");

// Build entry for Facet. No Zig sources compile yet (the engine core arrives at
// a later phase); this build orchestrates the Swift toolchain via swiftc and the
// Metal toolchain via `xcrun metal`/`xcrun metallib` directly. It produces the
// windowed app binary, a bench binary, and two headless test binaries, wiring
// `zig build`, `zig build run`, `zig build run-debug`, `zig build bench`, and
// `zig build test`. All compiler `-o` outputs go through addOutputFileArg so the
// artifacts are content-addressed and cached by the build graph.

const swift_target = "arm64-apple-macosx26.0";

// Metal compile flags are deliberately a SEPARATE set from swift_target: the two
// toolchains must not share a flag. `xcrun metal` crashes on a `-target`
// triple (verified exit 133) and rejects the space form `-std metal3.2`, so the
// language standard and deployment minimum are emitted as single tokens.
const metal_std = "-std=metal3.2";
const metal_min = "-mmacosx-version-min=26.0";

const app_sources = [_][]const u8{
    "src/platform/Instance.swift",
    "src/platform/MetallibLocator.swift",
    "src/platform/Renderer.swift",
    "src/platform/FrameLoop.swift",
    "src/platform/Window.swift",
    "src/platform/AppMain.swift",
};

// The retained Phase-1 clear-frame regression test: empty instance list ->
// zero draws -> byte-exact clear. Pulls in only the headless-safe types.
const clear_test_sources = [_][]const u8{
    "src/platform/Instance.swift",
    "src/platform/MetallibLocator.swift",
    "src/platform/Renderer.swift",
    "tests/snapshots/clear_frame_test.swift",
};

// The golden-PNG snapshot/metric test for the SDF path.
const sdf_test_sources = [_][]const u8{
    "src/platform/Instance.swift",
    "src/platform/MetallibLocator.swift",
    "src/platform/Renderer.swift",
    "tests/snapshots/PngImage.swift",
    "tests/snapshots/RendererSnapshotTests.swift",
};

// The Phase 3 golden + analytic spot-assert test for the shadow/border path.
const phase3_test_sources = [_][]const u8{
    "src/platform/Instance.swift",
    "src/platform/MetallibLocator.swift",
    "src/platform/Renderer.swift",
    "tests/snapshots/PngImage.swift",
    "tests/snapshots/Phase3ShadowBorderTests.swift",
};

// The bench harness: a live editable-window eye-check plus the headless
// --write-reference golden generator. Reuses the production windowing types.
const bench_sources = [_][]const u8{
    "src/platform/Instance.swift",
    "src/platform/MetallibLocator.swift",
    "src/platform/Renderer.swift",
    "src/platform/FrameLoop.swift",
    "src/platform/Window.swift",
    "tests/snapshots/PngImage.swift",
    // Not named main.swift: swiftc treats a literal main.swift as top-level
    // code, which conflicts with the @main attribute on RendererBench.
    "harness/renderer-bench/RendererBench.swift",
};

const linked_frameworks = [_][]const u8{ "Metal", "QuartzCore", "AppKit", "ImageIO", "CoreGraphics" };

pub fn build(b: *std.Build) void {
    const metallib = compileMetallib(b);

    const app_binary = compileSwift(b, "facet", &app_sources, .release);
    b.getInstallStep().dependOn(&b.addInstallBinFile(app_binary, "facet").step);
    b.getInstallStep().dependOn(&b.addInstallBinFile(metallib, "sdf.metallib").step);

    addRunStep(b, "run", "Build and run the windowed app (Metal validation OFF)", app_binary, metallib, false);

    const debug_app_binary = compileSwift(b, "facet-debug", &app_sources, .debug);
    addRunStep(b, "run-debug", "Build and run the app with Metal API Validation ON", debug_app_binary, metallib, true);

    const bench_binary = compileSwift(b, "facet-bench", &bench_sources, .release);
    addRunStep(b, "bench", "Live eye-check window, or --write-reference to regenerate goldens", bench_binary, metallib, false);

    const clear_test_binary = compileSwift(b, "clear-frame-test", &clear_test_sources, .debug);
    const clear_test_run = runBinary(b, clear_test_binary, metallib, true);
    clear_test_run.expectExitCode(0);

    const sdf_test_binary = compileSwift(b, "renderer-snapshot-test", &sdf_test_sources, .debug);
    const sdf_test_run = runBinary(b, sdf_test_binary, metallib, true);
    sdf_test_run.expectExitCode(0);

    const phase3_test_binary = compileSwift(b, "phase3-shadow-border-test", &phase3_test_sources, .debug);
    const phase3_test_run = runBinary(b, phase3_test_binary, metallib, true);
    phase3_test_run.expectExitCode(0);

    const test_step = b.step("test", "Run the headless clear-frame and SDF snapshot tests (Metal validation ON)");
    test_step.dependOn(&clear_test_run.step);
    test_step.dependOn(&sdf_test_run.step);
    test_step.dependOn(&phase3_test_run.step);
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

// Compiles src/shaders/sdf.metal to a .metallib in two stages, mirroring
// compileSwift: `xcrun metal -c` produces an .air, `xcrun metallib` links it.
// Both stages use addOutputFileArg so an edit to the shader rebuilds the lib.
fn compileMetallib(b: *std.Build) std.Build.LazyPath {
    const air = b.addSystemCommand(&.{ "xcrun", "metal", "-c", metal_std, metal_min });
    air.addFileArg(b.path("src/shaders/sdf.metal"));
    air.addArg("-o");
    const air_path = air.addOutputFileArg("sdf.air");

    const link = b.addSystemCommand(&.{ "xcrun", "metallib" });
    link.addFileArg(air_path);
    link.addArg("-o");
    return link.addOutputFileArg("sdf.metallib");
}

fn runBinary(
    b: *std.Build,
    binary: std.Build.LazyPath,
    metallib: std.Build.LazyPath,
    metal_validation: bool,
) *std.Build.Step.Run {
    const run = std.Build.Step.Run.create(b, "run swift binary");
    run.addFileArg(binary);
    run.addPrefixedFileArg("--metallib=", metallib);
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
    metallib: std.Build.LazyPath,
    metal_validation: bool,
) void {
    const run = runBinary(b, binary, metallib, metal_validation);
    // User args follow the injected --metallib= so e.g. `zig build bench --
    // --write-reference` reaches the binary after the metallib path.
    if (b.args) |args| run.addArgs(args);
    b.step(step_name, description).dependOn(&run.step);
}
