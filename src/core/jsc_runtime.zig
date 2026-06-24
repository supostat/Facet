const std = @import("std");
const c = @cImport({
    @cInclude("JavaScriptCore/JavaScriptCore.h");
});

// jsc_runtime.zig is the UPPER JS↔Zig seam (Р3/Р4): a minimal type-safe facade over
// the legacy JavaScriptCore C API. It is the ONLY module that touches the raw c.JS*
// symbols — the rest of the engine sees only the typed Runtime/JSString/ProtectedFn.
// It is a DISTINCT boundary from the LOWER Zig↔Swift seam (instance_seam.zig, Phase
// 13): the two seams never share a file. Dependencies point inward only — this module
// imports std + the JSC header ONLY; nothing in core imports it this phase (Phase 16's
// applyMutations is the first inward consumer → depends on this, never the reverse).
//
// The §4 JSC discipline is encapsulated as types, never ad-hoc: JSString balances
// create/release by construction; checkException is the single choke point after every
// throwing call; ProtectedFn balances JSValueProtect/Unprotect by construction; a
// debug-only assertion confines every facade entry to the main thread (the JSC context
// is not thread-safe). A Zig error NEVER unwinds across the callconv(.c) trampoline —
// it is caught and converted into the JS exception out-param.

const log = std.log.scoped(.jsc);

/// The errors the facade surfaces. JSException is a thrown JS error (its message
/// extracted for diagnostics); NotAnArrayBuffer is the fail-closed verdict on an
/// externally-shaped argument that is not an ArrayBuffer.
pub const Error = error{ JSException, NotAnArrayBuffer };

/// The leak oracle std.testing.allocator cannot see: JSC reference counts live in the
/// engine's own heap. These plain module-level counters are bumped on every JSStringRef
/// create/release (jsstring_live) and JSValueProtect/Unprotect (protect_live) the
/// facade performs, so a Debug-only leak test asserts the WITHIN-TEST delta is zero.
/// They are a shared process-wide artifact across the 10 co-located tests — never
/// asserted as a bare global == 0; tests snapshot at entry and assert exit == entry.
var jsstring_live: isize = 0;
var protect_live: isize = 0;

/// The buffer the exception choke point unpacks a JS error message into for diagnostics.
/// 256 bytes is ample for the Error.toString() of a thrown JS error; a longer message
/// is truncated by JSStringGetUTF8CString (it always NUL-terminates within the buffer).
const EXCEPTION_MESSAGE_CAPACITY = 256;

/// A native Zig function exposed to JS through exposeFunction. It receives the live
/// Runtime and the marshalled JS argument slice (zero-copy, valid only within the call)
/// and returns a JS value or a Zig error — the error becomes the JS exception out-param,
/// it never unwinds across the C-ABI trampoline.
pub const NativeFn = *const fn (runtime: *Runtime, arguments: []const c.JSValueRef) Error!c.JSValueRef;

// The single-slot registry binding the JS-visible trampoline to its Zig function. This
// is the deliberate minimal Phase-15 contract — exactly one known native fn — NOT an
// unfinished stub. FORWARD NOTE (Phase 16/17, not now): an N-function registry keyed by
// JSObjectGetPrivate over a JSClassCreate-backed object replaces these slots when the
// mutation flush and the host config register several natives at once.
var registered_fn: ?NativeFn = null;
var registered_runtime: ?*Runtime = null;

/// A JSStringRef that releases on deinit, so every string operation balances its
/// create against a release by construction and no call site hand-manages a raw
/// JSStringRef. Every create/release routes through jsstring_live so the leak oracle
/// covers it. Constructed from a sentinel-terminated slice (string literals are [:0]),
/// so JSStringCreateWithUTF8CString needs no dup.
const JSString = struct {
    ref: c.JSStringRef,

    fn initUtf8(text: [:0]const u8) JSString {
        const ref = c.JSStringCreateWithUTF8CString(text.ptr);
        jsstring_live += 1;
        return .{ .ref = ref };
    }

    /// Adopts a JSStringRef the caller already owns (e.g. JSValueToStringCopy's result),
    /// so the same balanced release path covers the exception-message string too.
    fn adopt(ref: c.JSStringRef) JSString {
        jsstring_live += 1;
        return .{ .ref = ref };
    }

    fn deinit(self: JSString) void {
        c.JSStringRelease(self.ref);
        jsstring_live -= 1;
    }
};

/// The single owner of a JSGlobalContextRef and the entry point of the facade. Every
/// public operation takes a *Runtime and asserts main-thread confinement first. Created
/// with JSGlobalContextCreate(null) and released symmetrically in deinit, mirroring the
/// instance_seam ownership discipline (but as a NORMAL Zig type — no *anyopaque export,
/// no Swift consumer this phase).
pub const Runtime = struct {
    context: c.JSGlobalContextRef,
    main_thread_id: std.Thread.Id,

    pub fn init() Runtime {
        return .{
            .context = c.JSGlobalContextCreate(null),
            .main_thread_id = std.Thread.getCurrentId(),
        };
    }

    pub fn deinit(self: *Runtime) void {
        self.assertMainThread();
        c.JSGlobalContextRelease(self.context);
    }

    /// Debug-only thread confinement: the JSC context is not thread-safe (Р14), so
    /// every facade entry asserts it runs on the thread that created the Runtime. The
    /// assertion compiles out in release builds; the contract is documented at the type.
    fn assertMainThread(self: *const Runtime) void {
        std.debug.assert(std.Thread.getCurrentId() == self.main_thread_id);
    }

    /// Evaluates a JS source string and returns its result value. A thrown JS error is
    /// converted to error.JSException through the choke point, never a process crash.
    pub fn eval(self: *Runtime, source: [:0]const u8) Error!c.JSValueRef {
        self.assertMainThread();
        const script = JSString.initUtf8(source);
        defer script.deinit();
        var exception: c.JSValueRef = null;
        const result = c.JSEvaluateScript(self.context, script.ref, null, null, 0, &exception);
        try self.checkException(exception);
        return result;
    }

    /// The single exception choke point called after EVERY throwing JSC call. A null
    /// exception is the no-op success path. A non-null exception is logged with its
    /// extracted message (routed through JSString so jsstring_live covers this path
    /// too) and converted to error.JSException.
    fn checkException(self: *Runtime, exception: c.JSValueRef) Error!void {
        if (exception == null) return;
        var conversion_exception: c.JSValueRef = null;
        const message_ref = c.JSValueToStringCopy(self.context, exception, &conversion_exception);
        if (message_ref != null) {
            const message_string = JSString.adopt(message_ref);
            defer message_string.deinit();
            var buffer: [EXCEPTION_MESSAGE_CAPACITY]u8 = undefined;
            _ = c.JSStringGetUTF8CString(message_string.ref, &buffer, buffer.len);
            log.warn("JS exception: {s}", .{std.mem.sliceTo(&buffer, 0)});
        }
        return Error.JSException;
    }

    /// Reads a JS ArrayBuffer's backing bytes as a Zig slice that aliases the JSC-owned
    /// memory with NO copy (one shared address space, Р5). FAIL-CLOSED on the
    /// externally-shaped boundary: a non-ArrayBuffer argument yields a null object or a
    /// null bytes pointer → error.NotAnArrayBuffer, never a crash or an OOB slice. The
    /// slice is valid only while the ArrayBuffer is live and only on the main thread;
    /// the caller reads it within the call and never retains it past the facade.
    pub fn arrayBufferBytes(self: *Runtime, value: c.JSValueRef) Error![]u8 {
        self.assertMainThread();
        var object_exception: c.JSValueRef = null;
        const object = c.JSValueToObject(self.context, value, &object_exception);
        try self.checkException(object_exception);
        if (object == null) return Error.NotAnArrayBuffer;

        var length_exception: c.JSValueRef = null;
        const byte_length = c.JSObjectGetArrayBufferByteLength(self.context, object, &length_exception);
        try self.checkException(length_exception);

        var bytes_exception: c.JSValueRef = null;
        const bytes_pointer = c.JSObjectGetArrayBufferBytesPtr(self.context, object, &bytes_exception);
        try self.checkException(bytes_exception);
        const non_null_bytes = bytes_pointer orelse return Error.NotAnArrayBuffer;

        return @as([*]u8, @ptrCast(non_null_bytes))[0..byte_length];
    }

    /// Registers a native Zig function as a JS global under `name`. JS calls reach the
    /// Zig code through the C-ABI trampoline, which marshals the argument array and
    /// converts any Zig error into a JS exception rather than unwinding. The single-slot
    /// binding is the minimal Phase-15 contract (one known native fn) — see the forward
    /// note on registered_fn.
    pub fn exposeFunction(self: *Runtime, name: [:0]const u8, native: NativeFn) Error!void {
        self.assertMainThread();
        registered_fn = native;
        registered_runtime = self;
        const name_string = JSString.initUtf8(name);
        defer name_string.deinit();
        const function_object = c.JSObjectMakeFunctionWithCallback(self.context, name_string.ref, trampoline);
        const global = c.JSContextGetGlobalObject(self.context);
        var set_exception: c.JSValueRef = null;
        c.JSObjectSetProperty(self.context, global, name_string.ref, function_object, 0, &set_exception);
        try self.checkException(set_exception);
    }
};

/// The C-ABI re-entry point JS calls. It recovers the registered Runtime and native fn,
/// marshals the argument array into a Zig slice (empty when argc == 0 so arguments[0..0]
/// never dereferences a null pointer), and invokes the native fn. A Zig error NEVER
/// unwinds across this callconv(.c) boundary: it is caught, converted to a JS Error in
/// the exception out-param, and undefined is returned.
fn trampoline(
    ctx: c.JSContextRef,
    function: c.JSObjectRef,
    this_object: c.JSObjectRef,
    argument_count: usize,
    arguments: [*c]const c.JSValueRef,
    exception: [*c]c.JSValueRef,
) callconv(.c) c.JSValueRef {
    _ = function;
    _ = this_object;
    const runtime = registered_runtime orelse return c.JSValueMakeUndefined(ctx);
    const native = registered_fn orelse return c.JSValueMakeUndefined(ctx);
    const argument_slice: []const c.JSValueRef = if (argument_count == 0) &.{} else arguments[0..argument_count];
    return native(runtime, argument_slice) catch |err| {
        setExceptionSlot(ctx, exception, err);
        return c.JSValueMakeUndefined(ctx);
    };
}

/// Converts a caught Zig error into the trampoline's JS exception out-param: builds a JS
/// Error whose message names the error so the JS caller sees a real thrown exception
/// rather than a silent undefined. A non-null exception is ALWAYS set on the error path —
/// if Error construction itself throws (e.g. OOM) JSObjectMakeError returns null, and the
/// plain message string (a valid JS throwable) is written instead, so the native failure
/// is never silently swallowed as a fail-open undefined return.
fn setExceptionSlot(ctx: c.JSContextRef, exception: [*c]c.JSValueRef, err: Error) void {
    if (exception == null) return;
    const message_string = JSString.initUtf8(@errorName(err));
    defer message_string.deinit();
    const message_value = c.JSValueMakeString(ctx, message_string.ref);
    var error_arguments = [_]c.JSValueRef{message_value};
    // This is the one JSC call deliberately NOT routed through checkException: the
    // trampoline error path cannot itself unwind a Zig error and has no *Runtime/Error!void
    // to route through. Its out-param is intentionally ignored — the fallback below, not
    // the choke point, guarantees a non-null thrown value regardless of construction outcome.
    var make_error_exception: c.JSValueRef = null;
    const error_object = c.JSObjectMakeError(ctx, error_arguments.len, &error_arguments, &make_error_exception);
    exception.* = if (error_object != null) error_object else message_value;
}

/// A JS function reference callable back from native, leak-proof by construction:
/// JSValueProtect at init keeps GC from collecting the function between native turns;
/// JSValueUnprotect at deinit balances it. Both route through protect_live so the leak
/// oracle covers the pair. This is the "call JS from native" op of the Р4 contract;
/// Phase 18's dispatchEvent is built on it — only ids cross the bridge later, the
/// function reference stays in JS.
pub const ProtectedFn = struct {
    runtime: *Runtime,
    function: c.JSObjectRef,

    pub fn init(runtime: *Runtime, function: c.JSObjectRef) ProtectedFn {
        runtime.assertMainThread();
        c.JSValueProtect(runtime.context, function);
        protect_live += 1;
        return .{ .runtime = runtime, .function = function };
    }

    pub fn deinit(self: *ProtectedFn) void {
        self.runtime.assertMainThread();
        c.JSValueUnprotect(self.runtime.context, self.function);
        protect_live -= 1;
    }

    /// Calls the protected JS function with `arguments` and returns its result. A thrown
    /// JS error routes through the choke point. An empty argument slice passes a null
    /// argv (JSObjectCallAsFunction's documented no-argument form).
    pub fn call(self: *ProtectedFn, arguments: []const c.JSValueRef) Error!c.JSValueRef {
        self.runtime.assertMainThread();
        const argv: [*c]const c.JSValueRef = if (arguments.len == 0) null else arguments.ptr;
        var exception: c.JSValueRef = null;
        const result = c.JSObjectCallAsFunction(self.runtime.context, self.function, null, arguments.len, argv, &exception);
        try self.runtime.checkException(exception);
        return result;
    }
};

const testing = std.testing;

test "the jsc-runtime artifact builds and links JavaScriptCore" {}

test "eval of a JS arithmetic expression returns the computed number" {
    var runtime = Runtime.init();
    defer runtime.deinit();

    const result = try runtime.eval("1 + 2");
    var conversion_exception: c.JSValueRef = null;
    const number = c.JSValueToNumber(runtime.context, result, &conversion_exception);
    try testing.expectEqual(@as(f64, 3), number);
}

test "a throwing JS program returns error.JSException and does not crash" {
    var runtime = Runtime.init();
    defer runtime.deinit();

    try testing.expectError(Error.JSException, runtime.eval("throw new Error('boom')"));
}

// The native fn under test for exposeFunction: it records the first marshalled argument
// (a number) into a module-level slot so the test can assert JS reached Zig with the
// right value.
var recorded_native_argument: f64 = 0;

fn recordFirstArgument(runtime: *Runtime, arguments: []const c.JSValueRef) Error!c.JSValueRef {
    var conversion_exception: c.JSValueRef = null;
    recorded_native_argument = c.JSValueToNumber(runtime.context, arguments[0], &conversion_exception);
    try runtime.checkException(conversion_exception);
    return c.JSValueMakeUndefined(runtime.context);
}

test "exposeFunction round-trips a JS call into the native Zig function with the argument marshalled" {
    var runtime = Runtime.init();
    defer runtime.deinit();

    recorded_native_argument = 0;
    try runtime.exposeFunction("facetNative", recordFirstArgument);
    _ = try runtime.eval("facetNative(7)");

    try testing.expectEqual(@as(f64, 7), recorded_native_argument);
}

// A native fn that always fails, to prove a Zig error becomes a catchable JS exception
// at the trampoline rather than unwinding across the C-ABI boundary.
fn alwaysFails(runtime: *Runtime, arguments: []const c.JSValueRef) Error!c.JSValueRef {
    _ = runtime;
    _ = arguments;
    return Error.NotAnArrayBuffer;
}

test "a Zig error in the native fn becomes a JS exception caught in JS, never unwinding the trampoline" {
    var runtime = Runtime.init();
    defer runtime.deinit();

    try runtime.exposeFunction("facetFails", alwaysFails);
    // JS catches the thrown exception and reports whether one was raised. If the Zig
    // error had unwound across .c the process would abort instead.
    const result = try runtime.eval(
        \\(function () {
        \\  try { facetFails(); return false; }
        \\  catch (e) { return true; }
        \\})()
    );
    try testing.expect(c.JSValueToBoolean(runtime.context, result));
}

fn makeNumber(runtime: *Runtime, number: f64) c.JSValueRef {
    return c.JSValueMakeNumber(runtime.context, number);
}

test "a ProtectedFn survives a forced GC and calls back into JS with the expected result" {
    var runtime = Runtime.init();
    defer runtime.deinit();

    const function_value = try runtime.eval("(function (x) { return x * 2; })");
    var object_exception: c.JSValueRef = null;
    const function_object = c.JSValueToObject(runtime.context, function_value, &object_exception);
    try runtime.checkException(object_exception);

    var protected = ProtectedFn.init(&runtime, function_object);
    defer protected.deinit();

    // Force a collection: an unprotected reference here would be reclaimed and the call
    // below would crash; the protect keeps it alive.
    c.JSGarbageCollect(runtime.context);

    const argument = makeNumber(&runtime, 21);
    const result = try protected.call(&.{argument});
    var conversion_exception: c.JSValueRef = null;
    try testing.expectEqual(@as(f64, 42), c.JSValueToNumber(runtime.context, result, &conversion_exception));
}

test "ProtectedFn.call passes a null argv on the zero-argument form and returns the JS result" {
    var runtime = Runtime.init();
    defer runtime.deinit();

    const function_value = try runtime.eval("(function () { return 99; })");
    var object_exception: c.JSValueRef = null;
    const function_object = c.JSValueToObject(runtime.context, function_value, &object_exception);
    try runtime.checkException(object_exception);

    var protected = ProtectedFn.init(&runtime, function_object);
    defer protected.deinit();

    const result = try protected.call(&.{});
    var conversion_exception: c.JSValueRef = null;
    try testing.expectEqual(@as(f64, 99), c.JSValueToNumber(runtime.context, result, &conversion_exception));
}

test "no Protect leak: the protect counter is balanced across ProtectedFn init and deinit" {
    var runtime = Runtime.init();
    defer runtime.deinit();

    const protect_entry = protect_live;

    const function_value = try runtime.eval("(function () { return 1; })");
    var object_exception: c.JSValueRef = null;
    const function_object = c.JSValueToObject(runtime.context, function_value, &object_exception);
    try runtime.checkException(object_exception);

    {
        var protected = ProtectedFn.init(&runtime, function_object);
        defer protected.deinit();
    }

    try testing.expectEqual(protect_entry, protect_live);
}

test "arrayBufferBytes reads a no-copy backing buffer by pointer identity and a JS ArrayBuffer by byte equality" {
    var runtime = Runtime.init();
    defer runtime.deinit();

    // The Zig-owned backing buffer outlives the ArrayBuffer (no-copy lifetime contract).
    var backing = [_]u8{ 10, 20, 30, 40 };
    var make_exception: c.JSValueRef = null;
    const array_buffer = c.JSObjectMakeArrayBufferWithBytesNoCopy(
        runtime.context,
        &backing,
        backing.len,
        noopDeallocator,
        null,
        &make_exception,
    );
    try runtime.checkException(make_exception);

    const bytes = try runtime.arrayBufferBytes(array_buffer);
    try testing.expectEqualSlices(u8, &backing, bytes);
    // Pointer identity proves the read did not copy: the slice aliases the Zig backing.
    try testing.expectEqual(@intFromPtr(&backing[0]), @intFromPtr(bytes.ptr));

    // A JS-created ArrayBuffer is proven by byte equality against the bytes JS wrote.
    const js_buffer_value = try runtime.eval(
        \\(function () {
        \\  const b = new Uint8Array([1, 2, 3]);
        \\  return b.buffer;
        \\})()
    );
    const js_bytes = try runtime.arrayBufferBytes(js_buffer_value);
    try testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3 }, js_bytes);
}

fn noopDeallocator(bytes: ?*anyopaque, deallocator_context: ?*anyopaque) callconv(.c) void {
    _ = bytes;
    _ = deallocator_context;
}

test "arrayBufferBytes fails closed with error.NotAnArrayBuffer on a number, an object, and a string" {
    var runtime = Runtime.init();
    defer runtime.deinit();

    const number_value = try runtime.eval("42");
    try testing.expectError(Error.NotAnArrayBuffer, runtime.arrayBufferBytes(number_value));

    const object_value = try runtime.eval("({})");
    try testing.expectError(Error.NotAnArrayBuffer, runtime.arrayBufferBytes(object_value));

    const string_value = try runtime.eval("'str'");
    try testing.expectError(Error.NotAnArrayBuffer, runtime.arrayBufferBytes(string_value));
}

test "no JSString leak: the string counter is balanced across a string-heavy round-trip including the exception path" {
    var runtime = Runtime.init();
    defer runtime.deinit();

    const jsstring_entry = jsstring_live;

    // A happy eval (one script string) and a throwing eval (script string + the
    // checkException message string) together exercise both string paths.
    _ = try runtime.eval("'a string' + ' another'");
    try testing.expectError(Error.JSException, runtime.eval("throw new Error('leak path message')"));

    try testing.expectEqual(jsstring_entry, jsstring_live);
}

fn confinementPredicate(runtime: *const Runtime, observed: *bool) void {
    observed.* = std.Thread.getCurrentId() != runtime.main_thread_id;
}

test "the main-thread confinement invariant holds: a spawned thread observes a different thread id" {
    var runtime = Runtime.init();
    defer runtime.deinit();

    // A cross-thread std.debug.assert failure aborts the whole zig test process and is
    // not catchable, so the off-thread case asserts the INVARIANT PREDICATE instead: the
    // spawned thread evaluates `getCurrentId() != main_thread_id` and returns it; the
    // main thread asserts the bool is true. assertMainThread WOULD fire off-thread.
    var observed_off_thread = false;
    const thread = try std.Thread.spawn(.{}, confinementPredicate, .{ &runtime, &observed_off_thread });
    thread.join();
    try testing.expect(observed_off_thread);
}

// The integration round-trip's native fn: it reads the ArrayBuffer argument zero-copy,
// sums its bytes, and calls the protected JS callback back with that sum, returning the
// callback's result. Exercises JS→Zig (the call + the buffer read) and Zig→JS (the
// callback) in one turn.
var round_trip_callback: ?*ProtectedFn = null;

fn sumBufferAndCallBack(runtime: *Runtime, arguments: []const c.JSValueRef) Error!c.JSValueRef {
    const bytes = try runtime.arrayBufferBytes(arguments[0]);
    var sum: f64 = 0;
    for (bytes) |byte| sum += @floatFromInt(byte);
    const callback = round_trip_callback orelse unreachable;
    const sum_value = c.JSValueMakeNumber(runtime.context, sum);
    return callback.call(&.{sum_value});
}

test "JS↔Zig↔JS round-trip: JS calls Zig, Zig reads an ArrayBuffer zero-copy and calls JS back, with both counters balanced" {
    var runtime = Runtime.init();
    defer runtime.deinit();

    const jsstring_entry = jsstring_live;
    const protect_entry = protect_live;

    // The JS callback Zig invokes back: it triples the byte sum it is handed.
    const callback_value = try runtime.eval("(function (sum) { return sum * 3; })");
    var object_exception: c.JSValueRef = null;
    const callback_object = c.JSValueToObject(runtime.context, callback_value, &object_exception);
    try runtime.checkException(object_exception);

    var protected = ProtectedFn.init(&runtime, callback_object);
    round_trip_callback = &protected;

    try runtime.exposeFunction("facetSumBuffer", sumBufferAndCallBack);

    // JS builds an ArrayBuffer [2, 3, 5] (sum 10) and hands it to Zig; Zig sums it
    // zero-copy and calls the JS callback back, which triples it → 30.
    const result = try runtime.eval(
        \\(function () {
        \\  const b = new Uint8Array([2, 3, 5]);
        \\  return facetSumBuffer(b.buffer);
        \\})()
    );
    var conversion_exception: c.JSValueRef = null;
    try testing.expectEqual(@as(f64, 30), c.JSValueToNumber(runtime.context, result, &conversion_exception));

    // Drop the protected fn explicitly (not via defer) so protect_live is back to its
    // entry snapshot BEFORE the delta assertions below.
    round_trip_callback = null;
    protected.deinit();
    try testing.expectEqual(protect_entry, protect_live);
    try testing.expectEqual(jsstring_entry, jsstring_live);
}
