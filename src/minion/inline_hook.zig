const std = @import("std");
const win32 = @import("win32");

const trampoline_jmp_size: usize = 5;
const min_patch_len: usize = trampoline_jmp_size;
const max_patch_len: usize = 16;
const lookahead_bytes: usize = 16;
const nop_opcode: u8 = 0x90;
const jmp_rel32_opcode: u8 = 0xE9;

pub const Hook = struct {
    target: [*]u8,
    trampoline: [*]u8,
    original: [max_patch_len]u8,
    original_len: usize,
};

fn rel32(from: usize, to: usize) i32 {
    const delta = @as(i64, @intCast(to)) - @as(i64, @intCast(from + trampoline_jmp_size));
    return @intCast(delta);
}

fn writeJump(at: [*]u8, to: usize) void {
    at[0] = jmp_rel32_opcode;
    std.mem.writeInt(i32, at[1..5], rel32(@intFromPtr(at), to), .little);
}

// Returns the number of bytes consumed by the ModR/M byte and any SIB +
// displacement that follow. `bytes` starts at the ModR/M byte. Conservative:
// returns null when the slice is too short.
fn modrmTailLen(bytes: []const u8) ?usize {
    if (bytes.len == 0) return null;
    const modrm = bytes[0];
    const mod: u2 = @intCast(modrm >> 6);
    const rm: u3 = @intCast(modrm & 0b111);

    var len: usize = 1;
    var has_sib = false;

    if (mod != 0b11 and rm == 0b100) {
        if (bytes.len < 2) return null;
        has_sib = true;
        len += 1;
    }

    switch (mod) {
        0b00 => {
            if (rm == 0b101 and !has_sib) {
                len += 4;
            } else if (has_sib) {
                const sib = bytes[1];
                if ((sib & 0b111) == 0b101) len += 4;
            }
        },
        0b01 => len += 1,
        0b10 => len += 4,
        0b11 => {},
    }

    return len;
}

// Mini x86 length disassembler limited to opcodes we actually see in WoW 3.3.5
// function prologues. Anything outside this allow-list returns null so the
// caller refuses the patch rather than splitting a multi-byte instruction.
// rel32 control-flow ops (E8/E9) and 0F-prefixed instructions are deliberately
// rejected: copying them into the trampoline would rebase their displacement.
pub fn instructionLength(b: []const u8) ?usize {
    if (b.len == 0) return null;
    const opcode = b[0];

    return switch (opcode) {
        0x40...0x5F, nop_opcode => 1,
        0x6A => 2,
        0x68 => 5,
        0xA1, 0xA3 => 5,
        0xB8...0xBF => 5,
        0x33, 0x85, 0x89, 0x8B, 0x8D, 0xFF => modrmOpLen(b, 0),
        0x83, 0xC1 => modrmOpLen(b, 1),
        0x81, 0xC7 => modrmOpLen(b, 4),
        else => null,
    };
}

fn modrmOpLen(b: []const u8, imm_bytes: usize) ?usize {
    const tail = modrmTailLen(b[1..]) orelse return null;
    return 1 + tail + imm_bytes;
}

fn computePatchLen(bytes: []const u8) ?usize {
    var consumed: usize = 0;
    while (consumed < min_patch_len) {
        if (consumed >= bytes.len) return null;
        const len = instructionLength(bytes[consumed..]) orelse return null;
        consumed += len;
        if (consumed > max_patch_len) return null;
    }
    return consumed;
}

const max_scan_bytes: usize = max_patch_len + lookahead_bytes;

pub fn install(target_addr: usize, hook_addr: usize) !Hook {
    const target: [*]u8 = @ptrFromInt(target_addr);
    const scan_window: []const u8 = target[0..max_scan_bytes];
    const patch_len = computePatchLen(scan_window) orelse return error.UnsupportedPrologue;
    const trampoline_size = patch_len + trampoline_jmp_size;

    const mem = win32.VirtualAlloc(
        null,
        trampoline_size,
        win32.MEM_COMMIT | win32.MEM_RESERVE,
        win32.PAGE_EXECUTE_READWRITE,
    ) orelse return error.VirtualAllocFailed;
    const trampoline: [*]u8 = @ptrCast(mem);

    var original: [max_patch_len]u8 = std.mem.zeroes([max_patch_len]u8);
    @memcpy(original[0..patch_len], target[0..patch_len]);
    @memcpy(trampoline[0..patch_len], target[0..patch_len]);
    writeJump(trampoline + patch_len, target_addr + patch_len);

    var old: win32.DWORD = 0;
    if (win32.VirtualProtect(@ptrCast(target), patch_len, win32.PAGE_EXECUTE_READWRITE, &old) == 0)
        return error.VirtualProtectFailed;
    defer _ = win32.VirtualProtect(@ptrCast(target), patch_len, old, &old);

    writeJump(target, hook_addr);
    var i: usize = trampoline_jmp_size;
    while (i < patch_len) : (i += 1) target[i] = nop_opcode;
    _ = win32.FlushInstructionCache(win32.GetCurrentProcess(), @ptrCast(target), patch_len);

    return .{
        .target = target,
        .trampoline = trampoline,
        .original = original,
        .original_len = patch_len,
    };
}

test "instructionLength decodes typical prologue opcodes" {
    try std.testing.expectEqual(@as(?usize, 1), instructionLength(&[_]u8{0x55})); // push ebp
    try std.testing.expectEqual(@as(?usize, 1), instructionLength(&[_]u8{0x53})); // push ebx
    try std.testing.expectEqual(@as(?usize, 1), instructionLength(&[_]u8{0x56})); // push esi
    try std.testing.expectEqual(@as(?usize, 1), instructionLength(&[_]u8{0x57})); // push edi
    try std.testing.expectEqual(@as(?usize, 2), instructionLength(&[_]u8{ 0x8B, 0xEC })); // mov ebp, esp
    try std.testing.expectEqual(@as(?usize, 2), instructionLength(&[_]u8{ 0x8B, 0xFF })); // mov edi, edi (hotpatch nop)
    try std.testing.expectEqual(@as(?usize, 3), instructionLength(&[_]u8{ 0x83, 0xEC, 0x10 })); // sub esp, 0x10
    try std.testing.expectEqual(@as(?usize, 6), instructionLength(&[_]u8{ 0x81, 0xEC, 0x00, 0x10, 0x00, 0x00 })); // sub esp, 0x1000
    try std.testing.expectEqual(@as(?usize, 5), instructionLength(&[_]u8{ 0xB8, 0x00, 0x00, 0x00, 0x00 })); // mov eax, imm32
    try std.testing.expectEqual(@as(?usize, 5), instructionLength(&[_]u8{ 0xA1, 0x00, 0x00, 0x00, 0x00 })); // mov eax, [imm32]
    try std.testing.expectEqual(@as(?usize, 5), instructionLength(&[_]u8{ 0x68, 0x00, 0x00, 0x00, 0x00 })); // push imm32
    try std.testing.expectEqual(@as(?usize, 2), instructionLength(&[_]u8{ 0x6A, 0x00 })); // push imm8
    try std.testing.expectEqual(@as(?usize, 2), instructionLength(&[_]u8{ 0x33, 0xC0 })); // xor eax, eax
    try std.testing.expectEqual(@as(?usize, 1), instructionLength(&[_]u8{0x90})); // nop
}

test "instructionLength decodes ModR/M with SIB and displacement" {
    // mov [esp + 0x10], eax  →  89 44 24 10  (modrm=0x44 sib=0x24 disp8=0x10)
    try std.testing.expectEqual(@as(?usize, 4), instructionLength(&[_]u8{ 0x89, 0x44, 0x24, 0x10 }));
    // lea eax, [ebp - 4]     →  8D 45 FC      (modrm=0x45 disp8=0xFC)
    try std.testing.expectEqual(@as(?usize, 3), instructionLength(&[_]u8{ 0x8D, 0x45, 0xFC }));
    // mov dword ptr [esp], 0  →  C7 04 24 00 00 00 00  (modrm=0x04 sib=0x24 imm32)
    try std.testing.expectEqual(@as(?usize, 7), instructionLength(&[_]u8{ 0xC7, 0x04, 0x24, 0x00, 0x00, 0x00, 0x00 }));
}

test "instructionLength rejects unsupported opcodes" {
    try std.testing.expectEqual(@as(?usize, null), instructionLength(&[_]u8{0xE8})); // call rel32
    try std.testing.expectEqual(@as(?usize, null), instructionLength(&[_]u8{0xE9})); // jmp rel32
    try std.testing.expectEqual(@as(?usize, null), instructionLength(&[_]u8{ 0x0F, 0xB6, 0xC0 })); // movzx
    try std.testing.expectEqual(@as(?usize, null), instructionLength(&[_]u8{}));
}

test "computePatchLen consumes a real prologue" {
    const prologue = [_]u8{ 0x55, 0x8B, 0xEC, 0x83, 0xEC, 0x10, 0x53, 0x56, 0x57, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    const len = computePatchLen(&prologue);
    try std.testing.expect(len != null);
    try std.testing.expect(len.? >= min_patch_len);
    try std.testing.expect(len.? <= max_patch_len);
    try std.testing.expectEqual(@as(usize, 6), len.?); // 55 + 8B EC + 83 EC 10 = 1+2+3
}

test "computePatchLen rejects unsupported prologue early" {
    // Starts with an opcode the LDE refuses (E8 = call rel32).
    const bad = [_]u8{ 0xE8, 0x00, 0x00, 0x00, 0x00, 0x55, 0x8B, 0xEC };
    try std.testing.expect(computePatchLen(&bad) == null);
}
