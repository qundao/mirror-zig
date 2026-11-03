const Package = @This();

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Target = std.Target;
const assert = std.debug.assert;
const mem = std.mem;
const log = std.log;

const Build = std.Build;
const Step = std.Build.Step;
const Cache = std.Build.Cache;
const Module = std.Build.Module;
const LazyPath = std.Build.LazyPath;
const Configuration = std.Build.Configuration;
const ResolvedTarget = std.Build.ResolvedTarget;

install_tls: Step.TopLevel,
uninstall_tls: Step.TopLevel,
default_step: *Step,
top_level_steps: std.array_hash_map.String(*Step.TopLevel),
/// Path to the directory containing build.zig.
root: Cache.Path,
user_input_options: Options.Map,
available_options_map: std.array_hash_map.String(AvailableOption) = .empty,
invalid_user_input: bool,
dep_prefix: []const u8,
modules: std.array_hash_map.String(*Module),
named_writefiles: std.array_hash_map.String(*Step.WriteFile),
named_lazy_paths: std.array_hash_map.String(LazyPath),
/// The hash of this instance's package. `""` means that this is the root package.
pkg_hash: []const u8,
/// A mapping from dependency names to package hashes.
available_deps: AvailableDeps,

pub const Entry = struct {
    hash: []const u8,
    available: bool,
    naked: bool,
    build_root: []const u8,
    deps: Package.AvailableDeps,
    run_build: ?*const fn (*Build) void,
};

/// Build system implementation detail.
pub const map: std.StaticStringMap(Entry) = map: {
    const deps = @import("root").dependencies;
    const decl_names = @typeInfo(deps.packages).@"struct".decl_names;
    var kvs: [decl_names.len]struct { []const u8, Entry } = undefined;
    @setEvalBranchQuota(decl_names.len + 100);
    for (decl_names, &kvs) |decl_name, *kv| {
        const pkg = @field(deps.packages, decl_name);
        const available = !@hasDecl(pkg, "available") or pkg.available;
        kv.* = .{ decl_name, .{
            .hash = decl_name,
            .available = available,
            .build_root = if (available) pkg.build_root else "",
            .deps = if (@hasDecl(pkg, "deps")) pkg.deps else &.{},
            .naked = !@hasDecl(pkg, "deps"),
            .run_build = if (available and @hasDecl(pkg, "build_zig")) &struct {
                fn run(b: *Build) void {
                    b.runPackageScript(pkg.build_zig);
                }
            }.run else null,
        } };
    }
    const frozen = kvs;
    break :map .initComptime(&frozen);
};

pub const AvailableDeps = []const struct { []const u8, []const u8 };

pub const Instance = struct {
    pkg_hash: []const u8,
    options: *const Options.Map,
};

pub const AvailableOption = struct {
    type_id: Configuration.AvailableOption.Type,
    description: []const u8,
    /// If the `type_id` is `enum` or `enum_list` this provides the list of enum options
    enum_options: ?[]const []const u8,
};

/// Build system implementation details.
pub const Options = struct {
    pub const Map = std.array_hash_map.String(UserProvided);

    pub const UserProvided = union(enum) {
        flag: void,
        scalar: []const u8,
        list: std.ArrayList([]const u8),
        map: std.array_hash_map.String(*const UserProvided),
        lazy_path: LazyPath,
        lazy_path_list: std.ArrayList(LazyPath),

        pub fn format(up: UserProvided, w: *Io.Writer) Io.Writer.Error!void {
            switch (up) {
                .scalar => |bytes| return w.print("{q}", .{bytes}),
                .flag => {},
                .list => |list| for (list.items) |s| {
                    try w.print("{q},", .{s});
                },
                .map => |*m| for (m.keys(), m.values()) |k, v| {
                    try w.print("{q}={qf},", .{ k, v });
                },
                .lazy_path => |lp| return lp.format(w),
                .lazy_path_list => |*list| for (list.items) |lp| {
                    try w.print("{qf},", .{lp});
                },
            }
        }

        pub fn eql(a: UserProvided, b: UserProvided) bool {
            if (std.meta.activeTag(a) != b) return false;
            return switch (a) {
                .flag => true,
                .scalar => |a_scalar| return mem.eql(u8, a_scalar, b.scalar),
                .list => |a_list| {
                    if (a_list.items.len != b.list.items.len) return false;
                    for (a_list.items, b.list.items) |a_elem, b_elem| {
                        if (!mem.eql(u8, a_elem, b_elem))
                            return false;
                    }
                    return true;
                },
                .map => |a_map| {
                    if (a_map.count() != b.map.count()) return false;
                    for (a_map.keys(), a_map.values(), b.map.keys(), b.map.values()) |a_key, a_val, b_key, b_val| {
                        if (!mem.eql(u8, a_key, b_key)) return false;
                        if (!a_val.eql(b_val.*)) return false;
                    }
                    return true;
                },
                .lazy_path => |a_lazy_path| return a_lazy_path.eql(b.lazy_path),
                .lazy_path_list => |a_lazy_path_list| {
                    if (a_lazy_path_list.items.len != b.lazy_path_list.items.len) return false;
                    for (a_lazy_path_list.items, b.lazy_path_list.items) |a_lp, b_lp| {
                        if (!a_lp.eql(b_lp)) return false;
                    }
                    return true;
                },
            };
        }

        pub fn hash(a: UserProvided, hasher: *std.hash.Wyhash) void {
            hasher.update(&mem.toBytes(std.meta.activeTag(a)));
            switch (a) {
                .flag => {},
                .scalar => |scalar| hasher.update(scalar),
                .list => |*list| for (list.items) |elem| hasher.update(elem),
                .map => |*m| for (m.keys(), m.values()) |key, val| {
                    hasher.update(key);
                    val.hash(hasher);
                },
                .lazy_path => |lp| lp.hash(hasher),
                .lazy_path_list => |*list| for (list.items) |lp| lp.hash(hasher),
            }
        }
    };

    fn fromArgs(arena: Allocator, m: *Options.Map, args: anytype) void {
        const args_info = @typeInfo(@TypeOf(args)).@"struct";
        inline for (args_info.field_names, args_info.field_types) |field_name, field_type| {
            if (field_type == @TypeOf(null)) continue;
            addFromArg(arena, m, field_name, field_type, @field(args, field_name));
        }
    }

    fn addFromArg(
        arena: Allocator,
        m: *Options.Map,
        field_name: [:0]const u8,
        comptime T: type,
        /// If null, the value won't be added, but `T` will still be type-checked.
        maybe_value: ?T,
    ) void {
        m.ensureUnusedCapacity(arena, 2) catch @panic("OOM");
        switch (T) {
            Target.Query => return if (maybe_value) |v| {
                m.putAssumeCapacity(field_name, .{ .scalar = v.zigTriple(arena) catch @panic("OOM") });
                m.putAssumeCapacity("cpu", .{ .scalar = v.serializeCpuAlloc(arena) catch @panic("OOM") });
            },
            ResolvedTarget => return if (maybe_value) |v| {
                m.putAssumeCapacity(field_name, .{ .scalar = v.query.zigTriple(arena) catch @panic("OOM") });
                m.putAssumeCapacity("cpu", .{ .scalar = v.query.serializeCpuAlloc(arena) catch @panic("OOM") });
            },
            std.zig.BuildId => return if (maybe_value) |v| {
                m.putAssumeCapacity(field_name, .{
                    .scalar = std.fmt.allocPrint(arena, "{f}", .{v}) catch @panic("OOM"),
                });
            },
            LazyPath => return if (maybe_value) |v| {
                m.putAssumeCapacity(field_name, .{ .lazy_path = v.dupeInner(arena) });
            },
            []const LazyPath => return if (maybe_value) |v| {
                var list: std.ArrayList(LazyPath) = .empty;
                const elems = list.addManyAsSlice(arena, v.len) catch @panic("OOM");
                for (v, elems) |lp, *elem| elem.* = lp.dupeInner(arena);
                m.putAssumeCapacity(field_name, .{ .lazy_path_list = list });
            },
            []const u8 => return if (maybe_value) |v| {
                m.putAssumeCapacity(field_name, .{ .scalar = arena.dupe(u8, v) catch @panic("OOM") });
            },
            []const []const u8 => return if (maybe_value) |v| {
                var list: std.ArrayList([]const u8) = .empty;
                const elems = list.addManyAsSlice(arena, v.len) catch @panic("OOM");
                for (v, elems) |s, *elem| elem.* = arena.dupe(u8, s) catch @panic("OOM");
                m.putAssumeCapacity(field_name, .{ .list = list });
            },
            else => switch (@typeInfo(T)) {
                .bool => return if (maybe_value) |v| {
                    m.putAssumeCapacity(field_name, .{ .scalar = if (v) "true" else "false" });
                },
                .@"enum", .enum_literal => return if (maybe_value) |v| {
                    m.putAssumeCapacity(field_name, .{ .scalar = @tagName(v) });
                },
                .comptime_int, .int => return if (maybe_value) |v| {
                    m.putAssumeCapacity(field_name, .{
                        .scalar = std.fmt.allocPrint(arena, "{d}", .{v}) catch @panic("OOM"),
                    });
                },
                .comptime_float, .float => return if (maybe_value) |v| {
                    m.putAssumeCapacity(field_name, .{
                        .scalar = std.fmt.allocPrint(arena, "{x}", .{v}) catch @panic("OOM"),
                    });
                },
                .pointer => |ptr_info| switch (ptr_info.size) {
                    .one => switch (@typeInfo(ptr_info.child)) {
                        .array => |array_info| return addFromArg(
                            arena,
                            m,
                            field_name,
                            @Pointer(.slice, .{ .@"const" = true }, array_info.child, null),
                            maybe_value orelse null,
                        ),
                        else => {},
                    },
                    .slice => switch (@typeInfo(ptr_info.child)) {
                        .@"enum" => return if (maybe_value) |v| {
                            var list: std.ArrayList([]const u8) = .empty;
                            const elems = list.addManyAsSlice(arena, v.len) catch @panic("OOM");
                            for (elems, v) |*elem, tag| elem.* = @tagName(tag);
                            m.putAssumeCapacity(field_name, .{ .list = list });
                        },
                        else => return addFromArg(
                            arena,
                            m,
                            field_name,
                            @Pointer(ptr_info.size, .{ .@"const" = true }, ptr_info.child, null),
                            maybe_value orelse null,
                        ),
                    },
                    else => {},
                },
                .null => unreachable,
                .optional => |info| switch (@typeInfo(info.child)) {
                    .optional => {},
                    else => return addFromArg(arena, m, field_name, info.child, maybe_value orelse null),
                },
                else => {},
            },
        }
        @compileError("option '" ++ field_name ++ "' has unsupported type: " ++ @typeName(T));
    }

    pub fn sort(m: *Map) void {
        m.sortUnstable(@as(struct {
            keys: []const []const u8,
            pub fn lessThan(this: @This(), a_index: usize, b_index: usize) bool {
                return mem.lessThan(u8, this.keys[a_index], this.keys[b_index]);
            }
        }, .{ .keys = m.keys() }));
    }

    pub fn eql(a: *const Map, b: *const Map) bool {
        if (a.count() != b.count()) return false;
        for (a.keys(), b.keys(), a.values(), b.values()) |a_key, b_key, a_val, b_val| {
            if (!mem.eql(u8, a_key, b_key)) return false;
            if (!a_val.eql(b_val)) return false;
        }
        return true;
    }

    pub fn logDifferences(a: *const Map, b: *const Map) void {
        const a_keys = a.keys();
        const b_keys = b.keys();
        const a_vals = a.values();
        const b_vals = b.values();
        var a_i: usize = 0;
        var b_i: usize = 0;
        while (a_i < a_keys.len and b_i < b_keys.len) {
            const a_key = a_keys[a_i];
            const b_key = b_keys[b_i];
            switch (mem.order(u8, a_key, b_key)) {
                .lt => {
                    log.info("{q}: {f} vs (missing)", .{ a_key, a_vals[a_i] });
                    a_i += 1;
                },
                .eq => {
                    const a_val = a_vals[a_i];
                    const b_val = b_vals[b_i];
                    if (!a_val.eql(b_val)) {
                        log.info("{q}: {f} vs {f}", .{ a_key, a_val, b_val });
                    }
                    a_i += 1;
                    b_i += 1;
                },
                .gt => {
                    log.info("{q}: (missing) vs {f}", .{ b_key, b_vals[b_i] });
                    b_i += 1;
                },
            }
        }
        for (a_keys[a_i..], a_vals[a_i..]) |a_key, a_val| log.info("{q}: {f} vs (missing)", .{ a_key, a_val });
        for (b_keys[b_i..], b_vals[b_i..]) |b_key, b_val| log.info("{q}: (missing) vs {f}", .{ b_key, b_val });
    }
};

pub const Fingerprint = packed struct(u64) {
    id: u32,
    checksum: u32,

    pub fn init(id: u32, name: []const u8) Fingerprint {
        return .{
            .id = id,
            .checksum = std.hash.Crc32.hash(name),
        };
    }

    pub fn generate(rng: std.Random, name: []const u8) Fingerprint {
        return .init(rng.intRangeLessThan(u32, 1, 0xffffffff), name);
    }

    pub fn validate(n: Fingerprint, name: []const u8) bool {
        switch (n.id) {
            0x00000000, 0xffffffff => return false,
            else => return std.hash.Crc32.hash(name) == n.checksum,
        }
    }

    pub fn int(n: Fingerprint) u64 {
        return @bitCast(n);
    }
};

/// A user-readable, file system safe hash that identifies an exact package snapshot, including file
/// contents.
///
/// The hash is not only to prevent collisions but must resist attacks where the adversary fully
/// controls the contents being hashed. Thus, it contains a full SHA-256 digest.
///
/// There's also a third way this structure is used. When using path rather than hash, a unique,
/// valid `Hash` is still needed, so one is computed based on the path. In this case, name and
/// version are each set to "P", size encodes another 4 bytes of the digest, and project id is set
/// to `0xffff`.
pub const Hash = struct {
    /// Maximum size of a package hash. Unused bytes at the end are filled with zeroes.
    ///
    /// Assumed to be already validated.
    bytes: [max_len]u8,

    pub const Algo = std.crypto.hash.sha2.Sha256;
    pub const Digest = [Algo.digest_length]u8;

    /// Example: "nnnn-vvvv-hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh"
    pub const max_len = 32 + 1 + 32 + 1 + (32 + 32 + 200) / 6;

    /// Asserts `s` is valid.
    pub fn fromSlice(s: []const u8) Hash {
        assert(validate(s) == .ok);
        var result: Hash = undefined;
        @memcpy(result.bytes[0..s.len], s);
        @memset(result.bytes[s.len..], 0);
        return result;
    }

    pub const Validation = enum { ok, short, long, incomplete };

    pub fn validate(s: []const u8) Validation {
        if (s.len > max_len) return .long;
        if (s.len < 44) return .short;
        const n_dashes = std.mem.countScalar(u8, s[0 .. s.len - 44], '-');
        if (n_dashes < 2) return .incomplete;
        return .ok;
    }

    test validate {
        try std.testing.expectEqual(.short, validate(""));
    }

    pub fn toSlice(ph: *const Hash) []const u8 {
        var end: usize = ph.bytes.len;
        while (true) {
            end -= 1;
            if (ph.bytes[end] != 0) return ph.bytes[0 .. end + 1];
        }
    }

    pub fn eql(a: *const Hash, b: *const Hash) bool {
        return std.mem.eql(u8, &a.bytes, &b.bytes);
    }

    /// Produces "$name-$semver-$hashplus".
    /// * name is the name field from build.zig.zon, asserted to be at most 32
    ///   bytes and assumed be a valid zig identifier
    /// * semver is the version field from build.zig.zon, asserted to be at
    ///   most 32 bytes
    /// * hashplus is the following 33-byte array, base64 encoded using -_ to make
    ///   it filesystem safe:
    ///   - (4 bytes) LE u32 Package ID
    ///   - (4 bytes) LE u32 total decompressed size in bytes, overflow saturated
    ///   - (25 bytes) truncated SHA-256 digest of hashed files of the package
    pub fn init(digest: Digest, name: []const u8, ver: []const u8, id: u32, size: u32) Hash {
        assert(name.len <= 32);
        assert(ver.len <= 32);
        var result: Hash = undefined;
        var buf: std.ArrayList(u8) = .initBuffer(&result.bytes);
        buf.appendSliceAssumeCapacity(name);
        buf.appendAssumeCapacity('-');
        buf.appendSliceAssumeCapacity(ver);
        buf.appendAssumeCapacity('-');
        var hashplus: [33]u8 = undefined;
        std.mem.writeInt(u32, hashplus[0..4], id, .little);
        std.mem.writeInt(u32, hashplus[4..8], size, .little);
        hashplus[8..].* = digest[0..25].*;
        _ = std.base64.url_safe_no_pad.Encoder.encode(buf.addManyAsArrayAssumeCapacity(44), &hashplus);
        @memset(buf.unusedCapacitySlice(), 0);
        return result;
    }

    /// Produces a unique, valid hash based on the path provided. The hash contains the name,
    /// version, and project id, but size is unknown so the field is used to encode 4 more bytes of
    /// the hash digest.
    pub fn initPath(sub_path: []const u8, is_global: bool) Hash {
        var digest: Digest = undefined;
        var hasher = Algo.init(.{});
        hasher.update(sub_path);
        hasher.update(&.{@intFromBool(is_global)});
        hasher.final(&digest);
        const size: u32 = @bitCast(digest[25..][0..4].*);
        return init(digest, "P", "P", ProjectId.no_fingerprint, size);
    }

    pub fn version(hash: *const Hash) std.SemanticVersion {
        return std.SemanticVersion.parse(versionText(hash)) catch unreachable;
    }

    pub fn versionText(hash: *const Hash) []const u8 {
        const bytes = hash.toSlice();
        const pos = std.mem.findScalar(u8, bytes, '-').? + 1;
        return bytes[pos .. bytes.len - 45];
    }

    test versionText {
        const hash: Hash = .fromSlice("pulseaudio-16.1.1-9-mk_62MZkNwBaFwiZ7ZVrYRIf_3dTqqJR5PbMRCJzSuLw");
        try std.testing.expectEqualStrings("16.1.1-9", hash.versionText());
    }

    pub fn projectId(hash: *const Hash) ProjectId {
        const bytes = hash.toSlice();
        const name = std.mem.sliceTo(bytes, '-');
        const encoded_hashplus = bytes[bytes.len - 44 ..];
        var hashplus: [33]u8 = undefined;
        std.base64.url_safe_no_pad.Decoder.decode(&hashplus, encoded_hashplus) catch unreachable;
        const fingerprint_id = std.mem.readInt(u32, hashplus[0..4], .little);
        return .init(name, fingerprint_id);
    }

    pub fn projectIdOptional(hash: *const Hash) ?ProjectId {
        const project_id = projectId(hash);
        return if (project_id.isNaked()) null else project_id;
    }

    test projectId {
        const hash: Hash = .fromSlice("pulseaudio-16.1.1-9-mk_62MZkNwBaFwiZ7ZVrYRIf_3dTqqJR5PbMRCJzSuLw");
        const project_id = hash.projectId();

        var expected_name: [32]u8 = @splat(0);
        expected_name[0.."pulseaudio".len].* = "pulseaudio".*;
        try std.testing.expectEqualSlices(u8, &expected_name, &project_id.padded_name);

        try std.testing.expectEqual(0xd8fa4f9a, project_id.fingerprint_id);
    }

    test "projectId with dashes in the base64" {
        const hash: Hash = .fromSlice("dvui-0.4.0-dev-AQFJmayi2gAKE7FeJoF61v5U1IV9-SupoEcFutIZYpkC");
        const project_id = hash.projectId();

        var expected_name: [32]u8 = @splat(0);
        expected_name[0.."dvui".len].* = "dvui".*;
        try std.testing.expectEqualSlices(u8, &expected_name, &project_id.padded_name);

        try std.testing.expectEqual(0x99490101, project_id.fingerprint_id);
    }
};

/// Minimum information required to identify whether a package is an artifact
/// of a given project.
pub const ProjectId = struct {
    /// Bytes after name.len are set to zero.
    padded_name: [32]u8,
    fingerprint_id: u32,

    pub const no_fingerprint: u32 = 0xffff;

    pub fn init(name: []const u8, fingerprint_id: u32) ProjectId {
        var padded_name: [32]u8 = @splat(0);
        @memcpy(padded_name[0..name.len], name);
        return .{
            .padded_name = padded_name,
            .fingerprint_id = fingerprint_id,
        };
    }

    pub fn eql(a: *const ProjectId, b: *const ProjectId) bool {
        return a.fingerprint_id == b.fingerprint_id and std.mem.eql(u8, &a.padded_name, &b.padded_name);
    }

    pub fn hash(a: *const ProjectId) u64 {
        const x: u64 = @bitCast(a.padded_name[0..8].*);
        return std.hash.int(x ^ a.fingerprint_id);
    }

    pub fn isNaked(pi: *const ProjectId) bool {
        return pi.fingerprint_id == no_fingerprint;
    }
};

test Hash {
    const example_digest: Hash.Digest = .{
        0xc7, 0xf5, 0x71, 0xb7, 0xb4, 0xe7, 0x6f, 0x3c, 0xdb, 0x87, 0x7a, 0x7f, 0xdd, 0xf9, 0x77, 0x87,
        0x9d, 0xd3, 0x86, 0xfa, 0x73, 0x57, 0x9a, 0xf7, 0x9d, 0x1e, 0xdb, 0x8f, 0x3a, 0xd9, 0xbd, 0x9f,
    };
    const result: Hash = .init(example_digest, "nasm", "2.16.1-3", 0xcafebabe, 10 * 1024 * 1024);
    try std.testing.expectEqualStrings("nasm-2.16.1-3-vrr-ygAAoADH9XG3tOdvPNuHen_d-XeHndOG-nNXmved", result.toSlice());
}

pub fn validateUserInputDidItFail(p: *Package) bool {
    for (p.user_input_options.keys()) |name| {
        if (!p.available_options_map.contains(name)) {
            for (p.available_options_map.keys(), p.available_options_map.values()) |available_name, *available| {
                log.info("available option: {q}: {s}", .{ available_name, available.description });
            }
            log.err("invalid option: {q}", .{name});
            p.invalid_user_input = true;
        }
    }
    return p.invalid_user_input;
}

pub fn findPkgHashOrFatal(p: *Package, name: []const u8) []const u8 {
    for (p.available_deps) |dep| {
        if (mem.eql(u8, dep[0], name)) return dep[1];
    }
    log.info("all dependencies used by build.zig must be declared in corresponding build.zig.zon", .{});
    if (p.pkg_hash.len == 0) std.debug.panic("no dependency named {s}", .{name});
    std.debug.panic("no dependency named {s} in {s} ({s})", .{ name, p.dep_prefix, p.pkg_hash });
}
