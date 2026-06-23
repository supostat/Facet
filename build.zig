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
    "src/platform/ShelfPacker.swift",
    "src/platform/GlyphRasterizer.swift",
    "src/platform/Atlas.swift",
    "src/platform/AtlasInspector.swift",
    "src/platform/TextLayout.swift",
    "src/platform/Shaper.swift",
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
    "src/platform/ShelfPacker.swift",
    "src/platform/GlyphRasterizer.swift",
    "src/platform/Atlas.swift",
    "src/platform/AtlasInspector.swift",
    "src/platform/TextLayout.swift",
    "src/platform/Renderer.swift",
    "tests/snapshots/clear_frame_test.swift",
};

// The golden-PNG snapshot/metric test for the SDF path.
const sdf_test_sources = [_][]const u8{
    "src/platform/Instance.swift",
    "src/platform/MetallibLocator.swift",
    "src/platform/ShelfPacker.swift",
    "src/platform/GlyphRasterizer.swift",
    "src/platform/Atlas.swift",
    "src/platform/AtlasInspector.swift",
    "src/platform/TextLayout.swift",
    "src/platform/Renderer.swift",
    "tests/snapshots/PngImage.swift",
    "tests/snapshots/SnapshotComparator.swift",
    "tests/snapshots/RendererSnapshotTests.swift",
};

// The Phase 3 golden + analytic spot-assert test for the shadow/border path.
const phase3_test_sources = [_][]const u8{
    "src/platform/Instance.swift",
    "src/platform/MetallibLocator.swift",
    "src/platform/ShelfPacker.swift",
    "src/platform/GlyphRasterizer.swift",
    "src/platform/Atlas.swift",
    "src/platform/AtlasInspector.swift",
    "src/platform/TextLayout.swift",
    "src/platform/Renderer.swift",
    "tests/snapshots/PngImage.swift",
    "tests/snapshots/SnapshotComparator.swift",
    "tests/snapshots/Phase3ShadowBorderTests.swift",
};

// The bench harness: a live editable-window eye-check plus the headless
// --write-reference golden generator. Reuses the production windowing types.
const bench_sources = [_][]const u8{
    "src/platform/Instance.swift",
    "src/platform/MetallibLocator.swift",
    "src/platform/ShelfPacker.swift",
    "src/platform/GlyphRasterizer.swift",
    "src/platform/Atlas.swift",
    "src/platform/AtlasInspector.swift",
    "src/platform/TextLayout.swift",
    "src/platform/Shaper.swift",
    "src/platform/Renderer.swift",
    "src/platform/FrameLoop.swift",
    "src/platform/Window.swift",
    "tests/snapshots/PngImage.swift",
    "tests/snapshots/ReferenceAtlas.swift",
    "tests/snapshots/ReferenceText.swift",
    "harness/renderer-bench/AtlasViewer.swift",
    // Not named main.swift: swiftc treats a literal main.swift as top-level
    // code, which conflicts with the @main attribute on RendererBench.
    "harness/renderer-bench/RendererBench.swift",
};

// CoreText is required by GlyphRasterizer (the only Core Text imaging site);
// every Swift binary now links it because Renderer owns the Atlas, which pulls
// in GlyphRasterizer.
const linked_frameworks = [_][]const u8{ "Metal", "QuartzCore", "AppKit", "ImageIO", "CoreGraphics", "CoreText" };

// The glyph-atlas logic test: the four atlas files plus AtlasTests. It uses the
// test-only Atlas(device:initialSize:) and constructs no Renderer, so it links
// neither Renderer.swift nor MetallibLocator and does not need glyph.metal in
// the metallib.
const atlas_test_sources = [_][]const u8{
    "src/platform/ShelfPacker.swift",
    "src/platform/GlyphRasterizer.swift",
    "src/platform/Atlas.swift",
    "src/platform/AtlasInspector.swift",
    "tests/atlas/AtlasTests.swift",
};

// The atlas golden + metric snapshot test: the four atlas files plus Instance +
// Renderer (the shared SnapshotComparator references CapturedFrame, defined on
// Renderer), the gray PNG reader (PngImage), the shared comparator, the shared
// reference-atlas definition, and AtlasSnapshotTests. It constructs no Renderer
// and loads no metallib — Renderer is compiled only so CapturedFrame resolves;
// the golden is the R8 dump, sampled by nothing here.
const atlas_snapshot_test_sources = [_][]const u8{
    "src/platform/Instance.swift",
    "src/platform/ShelfPacker.swift",
    "src/platform/GlyphRasterizer.swift",
    "src/platform/Atlas.swift",
    "src/platform/AtlasInspector.swift",
    "src/platform/TextLayout.swift",
    "src/platform/Renderer.swift",
    "tests/snapshots/PngImage.swift",
    "tests/snapshots/SnapshotComparator.swift",
    "tests/snapshots/ReferenceAtlas.swift",
    "tests/snapshots/AtlasSnapshotTests.swift",
};

// The Phase 5 text golden + metric test: the atlas + TextLayout + Renderer stack,
// the shared comparator/PngImage, the shared ReferenceText scene definitions, and
// TextSnapshotTests. Unlike the atlas tests it DOES construct a Renderer and the
// glyph fragment branch samples the atlas texture, so it loads the metallib.
const text_test_sources = [_][]const u8{
    "src/platform/Instance.swift",
    "src/platform/MetallibLocator.swift",
    "src/platform/ShelfPacker.swift",
    "src/platform/GlyphRasterizer.swift",
    "src/platform/Atlas.swift",
    "src/platform/AtlasInspector.swift",
    "src/platform/TextLayout.swift",
    "src/platform/Shaper.swift",
    "src/platform/Renderer.swift",
    "tests/snapshots/PngImage.swift",
    "tests/snapshots/SnapshotComparator.swift",
    "tests/snapshots/ReferenceText.swift",
    "tests/snapshots/TextSnapshotTests.swift",
};

// The Phase 6 shaper golden + deterministic-position test: same atlas + Renderer
// stack as the text test, plus Shaper (the line shaper under test) and the shared
// ReferenceText scenes. Like the text test it constructs a Renderer whose glyph
// fragment branch samples the atlas, so it loads the metallib.
const shaper_test_sources = [_][]const u8{
    "src/platform/Instance.swift",
    "src/platform/MetallibLocator.swift",
    "src/platform/ShelfPacker.swift",
    "src/platform/GlyphRasterizer.swift",
    "src/platform/Atlas.swift",
    "src/platform/AtlasInspector.swift",
    "src/platform/TextLayout.swift",
    "src/platform/Shaper.swift",
    "src/platform/Renderer.swift",
    "tests/snapshots/PngImage.swift",
    "tests/snapshots/SnapshotComparator.swift",
    "tests/snapshots/ReferenceText.swift",
    "tests/snapshots/ShaperSnapshotTests.swift",
};

pub fn build(b: *std.Build) void {
    const metallib = compileMetallib(b);

    const app_binary = compileSwift(b, "facet", &app_sources, .release);
    b.getInstallStep().dependOn(&b.addInstallBinFile(app_binary, "facet").step);
    b.getInstallStep().dependOn(&b.addInstallBinFile(metallib, "sdf.metallib").step);

    addRunStep(b, "run", "Build and run the windowed app (Metal validation OFF)", app_binary, metallib, false);

    const debug_app_binary = compileSwift(b, "facet-debug", &app_sources, .debug);
    addRunStep(b, "run-debug", "Build and run the app with Metal API Validation ON", debug_app_binary, metallib, true);

    const bench_binary = compileSwift(b, "facet-bench", &bench_sources, .release);
    addRunStep(b, "bench", "Live eye-check window, --atlas for the live glyph atlas viewer, or --write-reference to regenerate goldens", bench_binary, metallib, false);

    const clear_test_binary = compileSwift(b, "clear-frame-test", &clear_test_sources, .debug);
    const clear_test_run = runBinary(b, clear_test_binary, metallib, true);
    clear_test_run.expectExitCode(0);

    const sdf_test_binary = compileSwift(b, "renderer-snapshot-test", &sdf_test_sources, .debug);
    const sdf_test_run = runBinary(b, sdf_test_binary, metallib, true);
    sdf_test_run.expectExitCode(0);

    const phase3_test_binary = compileSwift(b, "phase3-shadow-border-test", &phase3_test_sources, .debug);
    const phase3_test_run = runBinary(b, phase3_test_binary, metallib, true);
    phase3_test_run.expectExitCode(0);

    // The atlas logic test takes no metallib: it constructs no Renderer and does
    // not sample a glyph shader, only the atlas texture upload/readback path.
    const atlas_test_binary = compileSwift(b, "atlas-test", &atlas_test_sources, .debug);
    const atlas_test_run = runBinaryWithoutMetallib(b, atlas_test_binary, true);
    atlas_test_run.expectExitCode(0);

    // The atlas golden + metric test also constructs no Renderer (Renderer is
    // compiled only for the CapturedFrame type), so it loads no metallib.
    const atlas_snapshot_test_binary = compileSwift(b, "atlas-snapshot-test", &atlas_snapshot_test_sources, .debug);
    const atlas_snapshot_test_run = runBinaryWithoutMetallib(b, atlas_snapshot_test_binary, true);
    atlas_snapshot_test_run.expectExitCode(0);

    // The text test constructs a Renderer and the glyph fragment branch samples
    // the atlas texture, so it loads the metallib (unlike the atlas tests).
    const text_test_binary = compileSwift(b, "text-snapshot-test", &text_test_sources, .debug);
    const text_test_run = runBinary(b, text_test_binary, metallib, true);
    text_test_run.expectExitCode(0);

    // The shaper test constructs a Renderer and the glyph fragment branch samples
    // the atlas texture, so it loads the metallib (like the text test).
    const shaper_test_binary = compileSwift(b, "shaper-snapshot-test", &shaper_test_sources, .debug);
    const shaper_test_run = runBinary(b, shaper_test_binary, metallib, true);
    shaper_test_run.expectExitCode(0);

    // The Block-II shadow-tree engine core: a NATIVE zig test artifact (no swiftc,
    // no metallib). tree.zig pulls debug.zig, layout.zig, measure.zig, dirty.zig,
    // hit_test.zig, and instances.zig tests in via co-located imports, so this
    // single addTest runs every module's tests.
    const core_module = b.createModule(.{ .root_source_file = b.path("src/core/tree.zig"), .target = b.graph.host, .optimize = .Debug });
    const core_test = b.addTest(.{ .name = "core-test", .root_module = core_module });
    const core_test_run = b.addRunArtifact(core_test);

    const test_step = b.step("test", "Run the Swift snapshot tests and the native Zig engine-core tests (tree, layout, measure, debug, dirty, hit_test, instances; Metal validation ON)");
    test_step.dependOn(&clear_test_run.step);
    test_step.dependOn(&sdf_test_run.step);
    test_step.dependOn(&phase3_test_run.step);
    test_step.dependOn(&atlas_test_run.step);
    test_step.dependOn(&atlas_snapshot_test_run.step);
    test_step.dependOn(&text_test_run.step);
    test_step.dependOn(&shaper_test_run.step);
    test_step.dependOn(&core_test_run.step);
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

// Compiles the Metal shaders to a single .metallib in two stages, mirroring
// compileSwift: `xcrun metal -c` produces one .air per source, `xcrun metallib`
// links them all into one library. Both stages use addOutputFileArg so an edit
// to any shader rebuilds the lib. sdf.metal and glyph.metal fold into the same
// sdf.metallib; the name is unchanged so MetallibLocator/Renderer are untouched.
fn compileMetallib(b: *std.Build) std.Build.LazyPath {
    const sdf_air = compileMetalAir(b, "src/shaders/sdf.metal", "sdf.air");
    const glyph_air = compileMetalAir(b, "src/shaders/glyph.metal", "glyph.air");

    const link = b.addSystemCommand(&.{ "xcrun", "metallib" });
    link.addFileArg(sdf_air);
    link.addFileArg(glyph_air);
    link.addArg("-o");
    return link.addOutputFileArg("sdf.metallib");
}

fn compileMetalAir(b: *std.Build, source: []const u8, air_basename: []const u8) std.Build.LazyPath {
    const air = b.addSystemCommand(&.{ "xcrun", "metal", "-c", metal_std, metal_min });
    air.addFileArg(b.path(source));
    air.addArg("-o");
    return air.addOutputFileArg(air_basename);
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

// For binaries that load no Metal library (the atlas logic test constructs no
// Renderer): same Metal-validation env, no injected --metallib= and so no
// metallib build dependency.
fn runBinaryWithoutMetallib(
    b: *std.Build,
    binary: std.Build.LazyPath,
    metal_validation: bool,
) *std.Build.Step.Run {
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
    metallib: std.Build.LazyPath,
    metal_validation: bool,
) void {
    const run = runBinary(b, binary, metallib, metal_validation);
    // User args follow the injected --metallib= so e.g. `zig build bench --
    // --write-reference` reaches the binary after the metallib path.
    if (b.args) |args| run.addArgs(args);
    b.step(step_name, description).dependOn(&run.step);
}
