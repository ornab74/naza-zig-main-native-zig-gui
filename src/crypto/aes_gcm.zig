const std = @import("std");

const Aes256Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

pub const key_length = Aes256Gcm.key_length;
pub const nonce_length = Aes256Gcm.nonce_length;
pub const tag_length = Aes256Gcm.tag_length;
pub const framing_overhead = nonce_length + tag_length;
pub const pbkdf2_salt_length: usize = 16;
pub const pbkdf2_rounds: u32 = 200_000;

pub const Key = [key_length]u8;
pub const Nonce = [nonce_length]u8;
pub const Tag = [tag_length]u8;
pub const Salt = [pbkdf2_salt_length]u8;
pub const StoredPassphraseKey = [pbkdf2_salt_length + key_length]u8;

pub const Error = error{
    InvalidCiphertext,
    KeyTooShort,
};

/// Generate a fresh 256-bit AES key using Zig's cryptographic RNG.
pub fn generateKey() Key {
    var key: Key = undefined;
    std.crypto.random.bytes(&key);
    return key;
}

/// Encrypt with AES-256-GCM using the exact byte framing used by `ornab74/naza`:
///
///     12-byte nonce || ciphertext || 16-byte authentication tag
///
/// No associated data is used, matching Python's `AESGCM.encrypt(nonce, data, None)`.
pub fn encryptAlloc(allocator: std.mem.Allocator, plaintext: []const u8, key: Key) ![]u8 {
    var nonce: Nonce = undefined;
    std.crypto.random.bytes(&nonce);
    return encryptWithNonceAlloc(allocator, plaintext, key, nonce);
}

/// Deterministic-nonce variant for interoperability tests. Production callers
/// should normally use `encryptAlloc`, which generates a fresh random nonce.
pub fn encryptWithNonceAlloc(
    allocator: std.mem.Allocator,
    plaintext: []const u8,
    key: Key,
    nonce: Nonce,
) ![]u8 {
    const total_len = framing_overhead + plaintext.len;
    const out = try allocator.alloc(u8, total_len);
    errdefer allocator.free(out);

    @memcpy(out[0..nonce_length], &nonce);

    const ciphertext = out[nonce_length .. nonce_length + plaintext.len];
    var tag: Tag = undefined;
    Aes256Gcm.encrypt(ciphertext, &tag, plaintext, &.{}, nonce, key);
    @memcpy(out[nonce_length + plaintext.len ..], &tag);

    return out;
}

/// Decrypt bytes emitted by Python's `aes_encrypt` or `encryptAlloc`.
/// Authentication failures are returned as `error.AuthenticationFailed` by
/// Zig's AES-GCM implementation.
pub fn decryptAlloc(allocator: std.mem.Allocator, framed: []const u8, key: Key) ![]u8 {
    if (framed.len < framing_overhead) return Error.InvalidCiphertext;

    const nonce: Nonce = framed[0..nonce_length].*;
    const ciphertext = framed[nonce_length .. framed.len - tag_length];
    const tag: Tag = framed[framed.len - tag_length ..][0..tag_length].*;

    const plaintext = try allocator.alloc(u8, ciphertext.len);
    errdefer allocator.free(plaintext);

    try Aes256Gcm.decrypt(plaintext, ciphertext, tag, &.{}, nonce, key);
    return plaintext;
}

/// Match Python's `.enc_key` compatibility behavior:
/// - 48+ bytes: treat bytes 16..48 as the AES-256 key (salt || derived key)
/// - 32..47 bytes: use the first 32 bytes as a raw AES-256 key
pub fn keyFromStoredBytes(data: []const u8) !Key {
    if (data.len >= pbkdf2_salt_length + key_length) {
        return data[pbkdf2_salt_length .. pbkdf2_salt_length + key_length].*;
    }
    if (data.len >= key_length) {
        return data[0..key_length].*;
    }
    return Error.KeyTooShort;
}

/// PBKDF2-HMAC-SHA256 parity with `ornab74/naza`:
/// 32-byte key, 16-byte salt, 200,000 iterations.
pub fn deriveKeyFromPassphrase(passphrase: []const u8, salt: Salt) !Key {
    var key: Key = undefined;
    try std.crypto.pwhash.pbkdf2(&key, passphrase, &salt, pbkdf2_rounds, HmacSha256);
    return key;
}

/// Produce the exact file payload used by the Python passphrase path:
/// `salt || derived_key` (48 bytes total).
pub fn deriveStoredPassphraseKey(passphrase: []const u8, salt: Salt) !StoredPassphraseKey {
    var key = try deriveKeyFromPassphrase(passphrase, salt);
    defer std.crypto.secureZero(u8, &key);

    var stored: StoredPassphraseKey = undefined;
    @memcpy(stored[0..pbkdf2_salt_length], &salt);
    @memcpy(stored[pbkdf2_salt_length..], &key);
    return stored;
}

pub fn generateStoredPassphraseKey(passphrase: []const u8) !StoredPassphraseKey {
    var salt: Salt = undefined;
    std.crypto.random.bytes(&salt);
    return deriveStoredPassphraseKey(passphrase, salt);
}

test "AES-GCM framing round trip matches Python layout" {
    const allocator = std.testing.allocator;
    const key = [_]u8{0x69} ** key_length;
    const nonce = [_]u8{0x42} ** nonce_length;
    const plaintext = "Test with message only";

    const framed = try encryptWithNonceAlloc(allocator, plaintext, key, nonce);
    defer allocator.free(framed);

    try std.testing.expectEqual(@as(usize, framing_overhead + plaintext.len), framed.len);
    try std.testing.expectEqualSlices(u8, &nonce, framed[0..nonce_length]);

    const expected_ciphertext = [_]u8{
        0x5c, 0xa1, 0x64, 0x2d, 0x90, 0x00, 0x9f, 0xea,
        0x33, 0xd0, 0x1f, 0x78, 0xcf, 0x6e, 0xef, 0xaf,
        0x01, 0xd5, 0x39, 0x47, 0x2f, 0x7c,
    };
    const expected_tag = [_]u8{
        0x07, 0xcd, 0x7f, 0xc9, 0x10, 0x3e, 0x2f, 0x9e,
        0x9b, 0xf2, 0xdf, 0xaa, 0x31, 0x9c, 0xaf, 0xf4,
    };

    try std.testing.expectEqualSlices(
        u8,
        &expected_ciphertext,
        framed[nonce_length .. framed.len - tag_length],
    );
    try std.testing.expectEqualSlices(u8, &expected_tag, framed[framed.len - tag_length ..]);

    const recovered = try decryptAlloc(allocator, framed, key);
    defer allocator.free(recovered);
    try std.testing.expectEqualSlices(u8, plaintext, recovered);
}

test "AES-GCM supports empty plaintext with Python-compatible framing" {
    const allocator = std.testing.allocator;
    const key = [_]u8{0x69} ** key_length;
    const nonce = [_]u8{0x42} ** nonce_length;

    const framed = try encryptWithNonceAlloc(allocator, "", key, nonce);
    defer allocator.free(framed);
    try std.testing.expectEqual(@as(usize, framing_overhead), framed.len);

    const recovered = try decryptAlloc(allocator, framed, key);
    defer allocator.free(recovered);
    try std.testing.expectEqual(@as(usize, 0), recovered.len);
}

test "AES-GCM rejects truncated framing before parsing" {
    const allocator = std.testing.allocator;
    const key = generateKey();
    var short: [framing_overhead - 1]u8 = [_]u8{0} ** (framing_overhead - 1);
    try std.testing.expectError(Error.InvalidCiphertext, decryptAlloc(allocator, &short, key));
}

test "AES-GCM rejects modified authentication tag" {
    const allocator = std.testing.allocator;
    const key = generateKey();
    const framed = try encryptAlloc(allocator, "authenticated payload", key);
    defer allocator.free(framed);

    framed[framed.len - 1] ^= 0x01;
    try std.testing.expectError(error.AuthenticationFailed, decryptAlloc(allocator, framed, key));
}

test "AES-GCM rejects modified ciphertext" {
    const allocator = std.testing.allocator;
    const key = generateKey();
    const framed = try encryptAlloc(allocator, "authenticated payload", key);
    defer allocator.free(framed);

    framed[nonce_length] ^= 0x01;
    try std.testing.expectError(error.AuthenticationFailed, decryptAlloc(allocator, framed, key));
}

test "AES-GCM rejects the wrong key" {
    const allocator = std.testing.allocator;
    const key = [_]u8{0x11} ** key_length;
    const wrong_key = [_]u8{0x22} ** key_length;
    const framed = try encryptAlloc(allocator, "authenticated payload", key);
    defer allocator.free(framed);

    try std.testing.expectError(error.AuthenticationFailed, decryptAlloc(allocator, framed, wrong_key));
}

test "stored key parser preserves Python compatibility rules" {
    var raw: [key_length]u8 = [_]u8{0xa5} ** key_length;
    try std.testing.expectEqualSlices(u8, &raw, &(try keyFromStoredBytes(&raw)));

    var stored: StoredPassphraseKey = undefined;
    @memset(stored[0..pbkdf2_salt_length], 0x5a);
    @memset(stored[pbkdf2_salt_length..], 0xa5);
    try std.testing.expectEqualSlices(u8, &raw, &(try keyFromStoredBytes(&stored)));

    var too_short: [key_length - 1]u8 = [_]u8{0} ** (key_length - 1);
    try std.testing.expectError(Error.KeyTooShort, keyFromStoredBytes(&too_short));
}

test "PBKDF2-HMAC-SHA256 matches Python cryptography parameters" {
    const salt = [_]u8{
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
        0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
    };
    const expected = [_]u8{
        0x78, 0xc2, 0x50, 0x76, 0x5d, 0x32, 0x9b, 0x36,
        0xe5, 0xbc, 0xbf, 0x13, 0x3b, 0xf8, 0x40, 0xb4,
        0x91, 0xe2, 0x3d, 0x8d, 0x0d, 0xe1, 0xc3, 0x28,
        0x65, 0xd3, 0x55, 0x28, 0x2e, 0x8a, 0xb1, 0x2b,
    };

    const key = try deriveKeyFromPassphrase("test-passphrase", salt);
    try std.testing.expectEqualSlices(u8, &expected, &key);

    const stored = try deriveStoredPassphraseKey("test-passphrase", salt);
    try std.testing.expectEqualSlices(u8, &salt, stored[0..pbkdf2_salt_length]);
    try std.testing.expectEqualSlices(u8, &key, stored[pbkdf2_salt_length..]);
    try std.testing.expectEqualSlices(u8, &key, &(try keyFromStoredBytes(&stored)));
}
