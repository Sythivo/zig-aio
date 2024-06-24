const std = @import("std");
const aio = @import("aio");
const io = @import("io.zig");
const Frame = @import("Frame.zig");
const Task = @import("Task.zig");
const common = @import("common.zig");
const options = @import("../coro.zig").options;

allocator: std.mem.Allocator,
io: aio.Dynamic,
frames: Frame.List = .{},
num_complete: usize = 0,

fn ioComplete(uop: aio.Dynamic.Uop, id: aio.Id, failed: bool) void {
    switch (uop) {
        inline else => |*op| {
            std.debug.assert(op.userdata != 0);
            if (@TypeOf(op.*) == aio.Nop) {
                if (op.domain != .coro) return;
                switch (op.ident) {
                    's' => {},
                    'r' => {},
                    else => unreachable,
                }
            } else {
                var ctx: *common.OperationContext = @ptrFromInt(op.userdata);
                var frame: *Frame = ctx.whole.frame;
                std.debug.assert(ctx.whole.num_operations > 0);
                ctx.id = id;
                ctx.completed = true;
                ctx.whole.num_operations -= 1;
                ctx.whole.num_errors += @intFromBool(failed);
                if (ctx.whole.num_operations == 0) {
                    switch (frame.status) {
                        .io, .io_cancel => frame.wakeup(frame.status),
                        else => unreachable,
                    }
                }
            }
        },
    }
}

pub const InitOptions = struct {
    /// This is a hint, the implementation makes the final call
    io_queue_entries: u16 = options.io_queue_entries,
};

pub fn init(allocator: std.mem.Allocator, opts: InitOptions) aio.Error!@This() {
    var work = try aio.Dynamic.init(allocator, opts.io_queue_entries);
    work.callback = ioComplete;
    return .{ .allocator = allocator, .io = work };
}

pub fn deinit(self: *@This()) void {
    self.run(.cancel) catch @panic("unrecovable");
    var next = self.frames.first;
    while (next) |node| {
        next = node.next;
        var frame = node.data.cast();
        frame.deinit();
    }
    self.io.deinit(self.allocator);
    self.* = undefined;
}

pub const SpawnError = Frame.Error;

pub const SpawnOptions = struct {
    stack: union(enum) {
        unmanaged: Frame.Stack,
        managed: usize,
    } = .{ .managed = options.stack_size },
};

/// Spawns a new task, the task may do local IO operations which will not block the whole process using the `io` namespace functions
/// Call `frame.complete` to collect the result and free the stack
pub fn spawn(self: *@This(), comptime func: anytype, args: anytype, opts: SpawnOptions) SpawnError!Task.Generic(func) {
    const stack = switch (opts.stack) {
        .unmanaged => |buf| buf,
        .managed => |sz| try self.allocator.alignedAlloc(u8, Frame.stack_alignment, sz),
    };
    errdefer if (opts.stack == .managed) self.allocator.free(stack);
    const frame = try Frame.init(self, stack, Task.Generic(func).Result, func, args);
    return .{ .frame = frame };
}

/// Step the scheduler by a single step.
/// If `mode` is `.blocking` will block until there is `IO` activity.
/// Returns the number of tasks running.
pub fn tick(self: *@This(), mode: aio.Dynamic.CompletionMode) aio.Error!usize {
    _ = try self.io.complete(mode);
    return self.frames.len - self.num_complete;
}

pub const CompleteMode = Frame.CompleteMode;

/// Run until all tasks are complete.
pub fn run(self: *@This(), mode: CompleteMode) aio.Error!void {
    while (true) {
        if (mode == .cancel) {
            var next = self.frames.first;
            while (next) |node| {
                next = node.next;
                _ = node.data.cast().tryCancel();
            }
        }
        if (try self.tick(.blocking) == 0) break;
    }
}
