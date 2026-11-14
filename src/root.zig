//! Bounded RE2-style boolean/full-match engine with replace support.
//! Set-lookahead `(?=set)` / `(?!set)` is supported as a deliberate extension
//! for tokenizer patterns; general lookaround remains unsupported.
//!
//! The engine was extracted from netz's xDS safe-regex implementation so it
//! can be reused independently of gRPC/xDS.
const std = @import("std");
const model = @import("regex/model.zig");
pub const Error = model.Error;
pub const Limits = model.Limits;
pub const Budget = @import("regex/budget.zig").Budget;
pub const BudgetError = @import("regex/budget.zig").Error;
pub const Workspace = @import("regex/execute.zig").Workspace;
pub const ReplaceWorkspace = @import("regex/replace.zig").Workspace;
pub const validateSubstitution = @import("regex/replace.zig").validateSubstitution;
pub const Program = @import("regex/compile.zig").Program;
/// Parse and compile directly into caller-owned storage. Callers that keep
/// the program for their whole lifetime can back it with an arena.
pub fn compile(gpa: std.mem.Allocator, pattern: []const u8, limits: Limits) Error!Program {
    const root = try @import("regex/parse.zig").parse(gpa, pattern, limits);
    return @import("regex/compile.zig").compile(gpa, root, limits);
}
pub const Regex = struct {
    arena: std.heap.ArenaAllocator,
    program: @import("regex/compile.zig").Program,
    pub fn init(gpa: std.mem.Allocator, pattern: []const u8, limits: Limits) Error!Regex {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const root = try @import("regex/parse.zig").parse(arena.allocator(), pattern, limits);
        const program = try @import("regex/compile.zig").compile(arena.allocator(), root, limits);
        return .{ .arena = arena, .program = program };
    }
    pub fn deinit(self: *Regex) void {
        self.arena.deinit();
        self.* = undefined;
    }
    pub fn matches(self: *const Regex, gpa: std.mem.Allocator, input: []const u8) std.mem.Allocator.Error!bool {
        var workspace = try Workspace.init(gpa, self.program);
        defer workspace.deinit();
        return workspace.matches(self.program, input);
    }
};
test {
    _ = @import("regex/tests.zig");
    _ = @import("regex/budget_tests.zig");
    _ = @import("regex/replace.zig");
}
