const std = @import("std");
const builtin = @import("builtin");

pub const desktop_x11 = builtin.os.tag == .linux and builtin.abi != .android;

const x11 = if (desktop_x11) @cImport({
    @cInclude("X11/Xlib.h");
    @cInclude("X11/Xutil.h");
    @cInclude("X11/keysym.h");
    @cInclude("sys/mman.h");
    @cInclude("sys/prctl.h");
}) else struct {};

pub const Page = enum(u8) {
    home,
    chat,
    road,
    food,
    quantum,
    security,
    models,
};

pub const Action = enum(u8) {
    none,
    chat_submit,
    road_scan,
    food_scan,
    clef_submit,
    quantum_refresh,
    self_test,
    clear_sensitive,
    model_download,
    model_verify,
    model_cancel,
    inference_cancel,
};

pub fn usesPhoneLayout(width: u32, force_phone: bool) bool {
    return force_phone or width < 720;
}

const Theme = struct {
    bg_top: u32 = 0x08101E,
    bg_bottom: u32 = 0x130D25,
    surface: u32 = 0x111B2C,
    surface_hi: u32 = 0x19253A,
    surface_alt: u32 = 0x15132A,
    stroke: u32 = 0x2A3954,
    text: u32 = 0xF3F7FF,
    text_soft: u32 = 0xA9B7CE,
    muted: u32 = 0x6F819F,
    cyan: u32 = 0x4DE4FF,
    cyan_dim: u32 = 0x1D8195,
    violet: u32 = 0x9D7CFF,
    magenta: u32 = 0xFF78CE,
    green: u32 = 0x64F3B5,
    amber: u32 = 0xFFD166,
    red: u32 = 0xFF667D,
};

const theme = Theme{};

const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,

    fn contains(self: Rect, px: i32, py: i32) bool {
        return px >= self.x and py >= self.y and px < self.x + self.w and py < self.y + self.h;
    }
};

const WidgetKind = enum(u8) { nav, input, button };

const Widget = struct {
    rect: Rect,
    kind: WidgetKind,
    id: u8,
};

const ButtonId = enum(u8) {
    chat_send = 1,
    road_scan = 2,
    food_scan = 3,
    clef_send = 4,
    quantum_refresh = 5,
    self_test = 6,
    clear_sensitive = 7,
    open_security = 8,
    open_models = 9,
    model_download = 10,
    model_verify = 11,
    model_cancel = 12,
    inference_cancel = 13,
};

const FocusId = enum(u8) {
    none = 0,
    chat = 1,
    road_0 = 10,
    road_1 = 11,
    road_2 = 12,
    road_3 = 13,
    road_4 = 14,
    road_5 = 15,
    food_0 = 20,
    food_1 = 21,
    food_2 = 22,
    food_3 = 23,
    food_4 = 24,
    food_5 = 25,
    clef = 30,
};

fn secureZero(bytes: []u8) void {
    for (bytes) |*byte| {
        const volatile_byte: *volatile u8 = byte;
        volatile_byte.* = 0;
    }
}

const TextBuffer = struct {
    data: [2048]u8 = [_]u8{0} ** 2048,
    len: usize = 0,

    fn slice(self: *const TextBuffer) []const u8 {
        return self.data[0..self.len];
    }

    fn clear(self: *TextBuffer) void {
        secureZero(&self.data);
        self.len = 0;
    }

    fn appendAscii(self: *TextBuffer, byte: u8) void {
        if (byte < 0x20 or byte > 0x7e or self.len >= self.data.len) return;
        self.data[self.len] = byte;
        self.len += 1;
    }

    fn backspace(self: *TextBuffer) void {
        if (self.len == 0) return;
        self.len -= 1;
        self.data[self.len] = 0;
    }

    fn set(self: *TextBuffer, text: []const u8) void {
        self.clear();
        const n = @min(text.len, self.data.len);
        @memcpy(self.data[0..n], text[0..n]);
        self.len = n;
    }
};

const Canvas = struct {
    allocator: std.mem.Allocator,
    pixels: []u32,
    width: u32,
    height: u32,

    fn init(allocator: std.mem.Allocator, width: u32, height: u32) !Canvas {
        const count = try std.math.mul(usize, @as(usize, width), @as(usize, height));
        const pixels = try allocator.alloc(u32, count);
        @memset(pixels, theme.bg_top);
        return .{ .allocator = allocator, .pixels = pixels, .width = width, .height = height };
    }

    fn deinit(self: *Canvas) void {
        const bytes = std.mem.sliceAsBytes(self.pixels);
        secureZero(bytes);
        self.allocator.free(self.pixels);
        self.* = undefined;
    }

    fn resize(self: *Canvas, width: u32, height: u32) !void {
        if (width == self.width and height == self.height) return;
        const count = try std.math.mul(usize, @as(usize, width), @as(usize, height));
        const next = try self.allocator.alloc(u32, count);
        @memset(next, theme.bg_top);
        secureZero(std.mem.sliceAsBytes(self.pixels));
        self.allocator.free(self.pixels);
        self.pixels = next;
        self.width = width;
        self.height = height;
    }

    fn clampRect(self: *const Canvas, rect: Rect) ?Rect {
        const x0 = @max(rect.x, 0);
        const y0 = @max(rect.y, 0);
        const x1 = @min(rect.x + rect.w, @as(i32, @intCast(self.width)));
        const y1 = @min(rect.y + rect.h, @as(i32, @intCast(self.height)));
        if (x1 <= x0 or y1 <= y0) return null;
        return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
    }

    fn fill(self: *Canvas, color: u32) void {
        @memset(self.pixels, color);
    }

    fn mix(a: u32, b: u32, t_num: u32, t_den: u32) u32 {
        const ar: u32 = (a >> 16) & 0xff;
        const ag: u32 = (a >> 8) & 0xff;
        const ab: u32 = a & 0xff;
        const br: u32 = (b >> 16) & 0xff;
        const bg: u32 = (b >> 8) & 0xff;
        const bb: u32 = b & 0xff;
        const r = (ar * (t_den - t_num) + br * t_num) / t_den;
        const g = (ag * (t_den - t_num) + bg * t_num) / t_den;
        const bl = (ab * (t_den - t_num) + bb * t_num) / t_den;
        return (r << 16) | (g << 8) | bl;
    }

    fn alphaBlend(dst: u32, src: u32, alpha: u8) u32 {
        const a: u32 = alpha;
        const inv: u32 = 255 - a;
        const dr: u32 = (dst >> 16) & 0xff;
        const dg: u32 = (dst >> 8) & 0xff;
        const db: u32 = dst & 0xff;
        const sr: u32 = (src >> 16) & 0xff;
        const sg: u32 = (src >> 8) & 0xff;
        const sb: u32 = src & 0xff;
        const r = (dr * inv + sr * a) / 255;
        const g = (dg * inv + sg * a) / 255;
        const b = (db * inv + sb * a) / 255;
        return (r << 16) | (g << 8) | b;
    }

    fn background(self: *Canvas, phase: u32) void {
        const h = @max(self.height, 1);
        var y: u32 = 0;
        while (y < self.height) : (y += 1) {
            const row_color = mix(theme.bg_top, theme.bg_bottom, y, h);
            const row = self.pixels[@as(usize, y) * @as(usize, self.width) .. @as(usize, y + 1) * @as(usize, self.width)];
            @memset(row, row_color);
        }
        const width_i: i32 = @intCast(self.width);
        const height_i: i32 = @intCast(self.height);
        const drift: i32 = @intCast(phase % 80);
        self.glowCircle(width_i - 90 - drift, 100 + @divTrunc(drift, 2), 250, theme.violet, 26);
        self.glowCircle(90 + @divTrunc(drift, 2), height_i - 120, 220, theme.cyan, 18);
        self.glowCircle(@divTrunc(width_i, 2), @divTrunc(height_i, 2), 300, theme.magenta, 6);
    }

    fn put(self: *Canvas, x: i32, y: i32, color: u32) void {
        if (x < 0 or y < 0) return;
        if (x >= @as(i32, @intCast(self.width)) or y >= @as(i32, @intCast(self.height))) return;
        self.pixels[@as(usize, @intCast(y)) * @as(usize, self.width) + @as(usize, @intCast(x))] = color;
    }

    fn putAlpha(self: *Canvas, x: i32, y: i32, color: u32, alpha: u8) void {
        if (x < 0 or y < 0) return;
        if (x >= @as(i32, @intCast(self.width)) or y >= @as(i32, @intCast(self.height))) return;
        const index = @as(usize, @intCast(y)) * @as(usize, self.width) + @as(usize, @intCast(x));
        self.pixels[index] = alphaBlend(self.pixels[index], color, alpha);
    }

    fn fillRect(self: *Canvas, rect: Rect, color: u32) void {
        const r = self.clampRect(rect) orelse return;
        var y = r.y;
        while (y < r.y + r.h) : (y += 1) {
            const start = @as(usize, @intCast(y)) * @as(usize, self.width) + @as(usize, @intCast(r.x));
            const end = start + @as(usize, @intCast(r.w));
            @memset(self.pixels[start..end], color);
        }
    }

    fn fillRectAlpha(self: *Canvas, rect: Rect, color: u32, alpha: u8) void {
        const r = self.clampRect(rect) orelse return;
        var y = r.y;
        while (y < r.y + r.h) : (y += 1) {
            var x = r.x;
            while (x < r.x + r.w) : (x += 1) self.putAlpha(x, y, color, alpha);
        }
    }

    fn circle(self: *Canvas, cx: i32, cy: i32, radius: i32, color: u32, alpha: u8) void {
        if (radius <= 0) return;
        var y: i32 = -radius;
        while (y <= radius) : (y += 1) {
            var x: i32 = -radius;
            while (x <= radius) : (x += 1) {
                if (x * x + y * y <= radius * radius) self.putAlpha(cx + x, cy + y, color, alpha);
            }
        }
    }

    fn glowCircle(self: *Canvas, cx: i32, cy: i32, radius: i32, color: u32, alpha: u8) void {
        if (radius <= 0 or alpha == 0) return;
        const radius_sq: i64 = @as(i64, radius) * @as(i64, radius);
        var y: i32 = -radius;
        while (y <= radius) : (y += 1) {
            var x: i32 = -radius;
            while (x <= radius) : (x += 1) {
                const dist_sq: i64 = @as(i64, x) * @as(i64, x) + @as(i64, y) * @as(i64, y);
                if (dist_sq >= radius_sq) continue;
                const falloff: i64 = radius_sq - dist_sq;
                const pixel_alpha: u8 = @intCast(@divTrunc(@as(i64, alpha) * falloff, radius_sq));
                if (pixel_alpha != 0) self.putAlpha(cx + x, cy + y, color, pixel_alpha);
            }
        }
    }

    fn roundedRect(self: *Canvas, rect: Rect, radius: i32, color: u32, alpha: u8) void {
        const r = @min(radius, @min(@divTrunc(rect.w, 2), @divTrunc(rect.h, 2)));
        if (r <= 1) {
            self.fillRectAlpha(rect, color, alpha);
            return;
        }
        self.fillRectAlpha(.{ .x = rect.x + r, .y = rect.y, .w = rect.w - 2 * r, .h = rect.h }, color, alpha);
        self.fillRectAlpha(.{ .x = rect.x, .y = rect.y + r, .w = rect.w, .h = rect.h - 2 * r }, color, alpha);
        self.circle(rect.x + r, rect.y + r, r, color, alpha);
        self.circle(rect.x + rect.w - r - 1, rect.y + r, r, color, alpha);
        self.circle(rect.x + r, rect.y + rect.h - r - 1, r, color, alpha);
        self.circle(rect.x + rect.w - r - 1, rect.y + rect.h - r - 1, r, color, alpha);
    }

    fn card(self: *Canvas, rect: Rect, accent: u32) void {
        self.roundedRect(.{ .x = rect.x + 2, .y = rect.y + 8, .w = rect.w, .h = rect.h }, 18, 0x000000, 48);
        self.roundedRect(rect, 18, theme.surface, 230);
        self.roundedRect(.{ .x = rect.x, .y = rect.y, .w = 4, .h = rect.h }, 2, accent, 220);
        self.roundedRect(.{ .x = rect.x + 1, .y = rect.y + 1, .w = rect.w - 2, .h = 1 }, 1, theme.stroke, 150);
    }

    fn gradientPill(self: *Canvas, rect: Rect, left: u32, right: u32) void {
        const r = self.clampRect(rect) orelse return;
        const radius = @max(@min(@divTrunc(r.h, 2), @divTrunc(r.w, 2)), 1);
        const center_w = @max(r.w - radius * 2, 1);
        var x: i32 = 0;
        while (x < center_w) : (x += 1) {
            const absolute = radius + x;
            const color = mix(left, right, @intCast(absolute), @intCast(@max(r.w - 1, 1)));
            self.fillRectAlpha(.{ .x = r.x + absolute, .y = r.y, .w = 1, .h = r.h }, color, 245);
        }
        self.circle(r.x + radius, r.y + @divTrunc(r.h, 2), radius, left, 245);
        self.circle(r.x + r.w - radius - 1, r.y + @divTrunc(r.h, 2), radius, right, 245);
    }
};

const ZigGlyphEngine = struct {
    fn rows(ch: u8) [7]u8 {
        return switch (ch) {
            'A' => .{ 0x0E, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11 },
            'B' => .{ 0x1E, 0x11, 0x11, 0x1E, 0x11, 0x11, 0x1E },
            'C' => .{ 0x0E, 0x11, 0x10, 0x10, 0x10, 0x11, 0x0E },
            'D' => .{ 0x1E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x1E },
            'E' => .{ 0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x1F },
            'F' => .{ 0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x10 },
            'G' => .{ 0x0E, 0x11, 0x10, 0x17, 0x11, 0x11, 0x0F },
            'H' => .{ 0x11, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11 },
            'I' => .{ 0x0E, 0x04, 0x04, 0x04, 0x04, 0x04, 0x0E },
            'J' => .{ 0x07, 0x02, 0x02, 0x02, 0x12, 0x12, 0x0C },
            'K' => .{ 0x11, 0x12, 0x14, 0x18, 0x14, 0x12, 0x11 },
            'L' => .{ 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x1F },
            'M' => .{ 0x11, 0x1B, 0x15, 0x15, 0x11, 0x11, 0x11 },
            'N' => .{ 0x11, 0x19, 0x15, 0x13, 0x11, 0x11, 0x11 },
            'O' => .{ 0x0E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E },
            'P' => .{ 0x1E, 0x11, 0x11, 0x1E, 0x10, 0x10, 0x10 },
            'Q' => .{ 0x0E, 0x11, 0x11, 0x11, 0x15, 0x12, 0x0D },
            'R' => .{ 0x1E, 0x11, 0x11, 0x1E, 0x14, 0x12, 0x11 },
            'S' => .{ 0x0F, 0x10, 0x10, 0x0E, 0x01, 0x01, 0x1E },
            'T' => .{ 0x1F, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04 },
            'U' => .{ 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E },
            'V' => .{ 0x11, 0x11, 0x11, 0x11, 0x11, 0x0A, 0x04 },
            'W' => .{ 0x11, 0x11, 0x11, 0x15, 0x15, 0x15, 0x0A },
            'X' => .{ 0x11, 0x11, 0x0A, 0x04, 0x0A, 0x11, 0x11 },
            'Y' => .{ 0x11, 0x11, 0x0A, 0x04, 0x04, 0x04, 0x04 },
            'Z' => .{ 0x1F, 0x01, 0x02, 0x04, 0x08, 0x10, 0x1F },
            'a' => .{ 0x00, 0x00, 0x0E, 0x01, 0x0F, 0x11, 0x0F },
            'b' => .{ 0x10, 0x10, 0x16, 0x19, 0x11, 0x11, 0x1E },
            'c' => .{ 0x00, 0x00, 0x0E, 0x11, 0x10, 0x11, 0x0E },
            'd' => .{ 0x01, 0x01, 0x0D, 0x13, 0x11, 0x11, 0x0F },
            'e' => .{ 0x00, 0x00, 0x0E, 0x11, 0x1F, 0x10, 0x0E },
            'f' => .{ 0x06, 0x08, 0x08, 0x1E, 0x08, 0x08, 0x08 },
            'g' => .{ 0x00, 0x0F, 0x11, 0x11, 0x0F, 0x01, 0x0E },
            'h' => .{ 0x10, 0x10, 0x16, 0x19, 0x11, 0x11, 0x11 },
            'i' => .{ 0x04, 0x00, 0x0C, 0x04, 0x04, 0x04, 0x0E },
            'j' => .{ 0x02, 0x00, 0x06, 0x02, 0x02, 0x12, 0x0C },
            'k' => .{ 0x10, 0x10, 0x12, 0x14, 0x18, 0x14, 0x12 },
            'l' => .{ 0x0C, 0x04, 0x04, 0x04, 0x04, 0x04, 0x0E },
            'm' => .{ 0x00, 0x00, 0x1A, 0x15, 0x15, 0x15, 0x15 },
            'n' => .{ 0x00, 0x00, 0x16, 0x19, 0x11, 0x11, 0x11 },
            'o' => .{ 0x00, 0x00, 0x0E, 0x11, 0x11, 0x11, 0x0E },
            'p' => .{ 0x00, 0x00, 0x1E, 0x11, 0x1E, 0x10, 0x10 },
            'q' => .{ 0x00, 0x00, 0x0F, 0x11, 0x0F, 0x01, 0x01 },
            'r' => .{ 0x00, 0x00, 0x16, 0x19, 0x10, 0x10, 0x10 },
            's' => .{ 0x00, 0x00, 0x0F, 0x10, 0x0E, 0x01, 0x1E },
            't' => .{ 0x08, 0x08, 0x1E, 0x08, 0x08, 0x09, 0x06 },
            'u' => .{ 0x00, 0x00, 0x11, 0x11, 0x11, 0x13, 0x0D },
            'v' => .{ 0x00, 0x00, 0x11, 0x11, 0x11, 0x0A, 0x04 },
            'w' => .{ 0x00, 0x00, 0x11, 0x11, 0x15, 0x15, 0x0A },
            'x' => .{ 0x00, 0x00, 0x11, 0x0A, 0x04, 0x0A, 0x11 },
            'y' => .{ 0x00, 0x00, 0x11, 0x11, 0x0F, 0x01, 0x0E },
            'z' => .{ 0x00, 0x00, 0x1F, 0x02, 0x04, 0x08, 0x1F },
            '0' => .{ 0x0E, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0E },
            '1' => .{ 0x04, 0x0C, 0x14, 0x04, 0x04, 0x04, 0x1F },
            '2' => .{ 0x0E, 0x11, 0x01, 0x02, 0x04, 0x08, 0x1F },
            '3' => .{ 0x1E, 0x01, 0x01, 0x0E, 0x01, 0x01, 0x1E },
            '4' => .{ 0x02, 0x06, 0x0A, 0x12, 0x1F, 0x02, 0x02 },
            '5' => .{ 0x1F, 0x10, 0x10, 0x1E, 0x01, 0x01, 0x1E },
            '6' => .{ 0x0E, 0x10, 0x10, 0x1E, 0x11, 0x11, 0x0E },
            '7' => .{ 0x1F, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08 },
            '8' => .{ 0x0E, 0x11, 0x11, 0x0E, 0x11, 0x11, 0x0E },
            '9' => .{ 0x0E, 0x11, 0x11, 0x0F, 0x01, 0x01, 0x0E },
            ' ' => .{ 0, 0, 0, 0, 0, 0, 0 },
            '.' => .{ 0, 0, 0, 0, 0, 0x0C, 0x0C },
            ',' => .{ 0, 0, 0, 0, 0x0C, 0x0C, 0x08 },
            ':' => .{ 0, 0x0C, 0x0C, 0, 0x0C, 0x0C, 0 },
            ';' => .{ 0, 0x0C, 0x0C, 0, 0x0C, 0x0C, 0x08 },
            '!' => .{ 0x04, 0x04, 0x04, 0x04, 0x04, 0, 0x04 },
            '?' => .{ 0x0E, 0x11, 0x01, 0x02, 0x04, 0, 0x04 },
            '-' => .{ 0, 0, 0, 0x1F, 0, 0, 0 },
            '_' => .{ 0, 0, 0, 0, 0, 0, 0x1F },
            '/' => .{ 0x01, 0x02, 0x02, 0x04, 0x08, 0x08, 0x10 },
            '\\' => .{ 0x10, 0x08, 0x08, 0x04, 0x02, 0x02, 0x01 },
            '(' => .{ 0x02, 0x04, 0x08, 0x08, 0x08, 0x04, 0x02 },
            ')' => .{ 0x08, 0x04, 0x02, 0x02, 0x02, 0x04, 0x08 },
            '[' => .{ 0x0E, 0x08, 0x08, 0x08, 0x08, 0x08, 0x0E },
            ']' => .{ 0x0E, 0x02, 0x02, 0x02, 0x02, 0x02, 0x0E },
            '{' => .{ 0x06, 0x08, 0x08, 0x10, 0x08, 0x08, 0x06 },
            '}' => .{ 0x0C, 0x02, 0x02, 0x01, 0x02, 0x02, 0x0C },
            '<' => .{ 0x02, 0x04, 0x08, 0x10, 0x08, 0x04, 0x02 },
            '>' => .{ 0x08, 0x04, 0x02, 0x01, 0x02, 0x04, 0x08 },
            '+' => .{ 0, 0x04, 0x04, 0x1F, 0x04, 0x04, 0 },
            '=' => .{ 0, 0, 0x1F, 0, 0x1F, 0, 0 },
            '%' => .{ 0x19, 0x19, 0x02, 0x04, 0x08, 0x13, 0x13 },
            '#' => .{ 0x0A, 0x0A, 0x1F, 0x0A, 0x1F, 0x0A, 0x0A },
            '@' => .{ 0x0E, 0x11, 0x17, 0x15, 0x17, 0x10, 0x0E },
            '*' => .{ 0, 0x15, 0x0E, 0x1F, 0x0E, 0x15, 0 },
            '|' => .{ 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04 },
            '\'' => .{ 0x04, 0x04, 0x08, 0, 0, 0, 0 },
            '"' => .{ 0x0A, 0x0A, 0x0A, 0, 0, 0, 0 },
            else => .{ 0x0E, 0x11, 0x01, 0x02, 0x04, 0, 0x04 },
        };
    }

    fn draw(canvas: *Canvas, x: i32, y: i32, text: []const u8, scale: i32, color: u32) i32 {
        var cx = x;
        var cy = y;
        for (text) |ch| {
            if (ch == '\n') {
                cx = x;
                cy += 9 * scale;
                continue;
            }
            const glyph = rows(ch);
            for (glyph, 0..) |row_bits, row| {
                var col: usize = 0;
                while (col < 5) : (col += 1) {
                    const bit: u3 = @intCast(4 - col);
                    if ((row_bits & (@as(u8, 1) << bit)) == 0) continue;
                    canvas.fillRect(.{
                        .x = cx + @as(i32, @intCast(col)) * scale,
                        .y = cy + @as(i32, @intCast(row)) * scale,
                        .w = @max(scale - 1, 1),
                        .h = @max(scale - 1, 1),
                    }, color);
                }
            }
            cx += 6 * scale;
        }
        return cx;
    }

    fn drawWrapped(canvas: *Canvas, rect: Rect, text: []const u8, scale: i32, color: u32, max_lines: usize) void {
        const char_w = 6 * scale;
        const line_h = 9 * scale;
        const chars_per_line: usize = @intCast(@max(@divTrunc(rect.w, @as(i32, @intCast(@max(char_w, 1)))), 1));
        var line: usize = 0;
        var col: usize = 0;
        var x = rect.x;
        var y = rect.y;
        var word_start: usize = 0;
        var i: usize = 0;
        while (i <= text.len and line < max_lines) : (i += 1) {
            const boundary = i == text.len or text[i] == ' ' or text[i] == '\n';
            if (!boundary) continue;
            const word = text[word_start..i];
            if (col != 0 and col + word.len > chars_per_line) {
                line += 1;
                if (line >= max_lines) break;
                x = rect.x;
                y += line_h;
                col = 0;
            }
            _ = draw(canvas, x, y, word, scale, color);
            x += @as(i32, @intCast(word.len)) * char_w;
            col += word.len;
            if (i < text.len and text[i] == '\n') {
                line += 1;
                if (line >= max_lines) break;
                x = rect.x;
                y += line_h;
                col = 0;
            } else if (i < text.len) {
                if (col + 1 >= chars_per_line) {
                    line += 1;
                    if (line >= max_lines) break;
                    x = rect.x;
                    y += line_h;
                    col = 0;
                } else {
                    x += char_w;
                    col += 1;
                }
            }
            word_start = i + 1;
        }
    }
};

pub const InputKey = enum { escape, tab, enter, backspace, clear };

pub const InputEvent = union(enum) {
    close,
    resize: struct { width: u32, height: u32 },
    mouse_move: struct { x: i32, y: i32 },
    mouse_down: struct { x: i32, y: i32 },
    text: u8,
    key: InputKey,
};

const X11Backend = if (desktop_x11) struct {
    display: *x11.Display,
    window: x11.Window,
    gc: x11.GC,
    wm_delete: x11.Atom,
    image: ?*x11.XImage = null,
    width: u32,
    height: u32,

    fn init(width: u32, height: u32) !X11Backend {
        const display = x11.XOpenDisplay(null) orelse return error.DisplayUnavailable;
        errdefer _ = x11.XCloseDisplay(display);
        const screen = x11.XDefaultScreen(display);
        const root = x11.XRootWindow(display, screen);
        const window = x11.XCreateSimpleWindow(display, root, 0, 0, width, height, 0, 0, 0);
        if (window == 0) return error.WindowCreationFailed;
        const event_mask: c_long = x11.ExposureMask | x11.KeyPressMask | x11.ButtonPressMask | x11.PointerMotionMask | x11.StructureNotifyMask | x11.FocusChangeMask;
        _ = x11.XSelectInput(display, window, event_mask);
        _ = x11.XStoreName(display, window, "NAZA // QUANTUM SECURE");
        var wm_delete = x11.XInternAtom(display, "WM_DELETE_WINDOW", x11.False);
        _ = x11.XSetWMProtocols(display, window, &wm_delete, 1);
        const gc = x11.XCreateGC(display, window, 0, null) orelse return error.GraphicsContextCreationFailed;
        _ = x11.XMapWindow(display, window);
        _ = x11.XFlush(display);
        return .{ .display = display, .window = window, .gc = gc, .wm_delete = wm_delete, .width = width, .height = height };
    }

    fn destroyImage(self: *X11Backend) void {
        if (self.image) |image| {
            image.*.data = null;
            _ = x11.XFree(image);
            self.image = null;
        }
    }

    fn ensureImage(self: *X11Backend, canvas: *Canvas) !void {
        if (self.image != null and self.width == canvas.width and self.height == canvas.height) return;
        self.destroyImage();
        self.width = canvas.width;
        self.height = canvas.height;
        const screen = x11.XDefaultScreen(self.display);
        const visual = x11.XDefaultVisual(self.display, screen);
        const depth: c_uint = @intCast(x11.XDefaultDepth(self.display, screen));
        const data: [*c]u8 = @ptrCast(canvas.pixels.ptr);
        self.image = x11.XCreateImage(self.display, visual, depth, x11.ZPixmap, 0, data, canvas.width, canvas.height, 32, @intCast(canvas.width * 4)) orelse return error.ImageCreationFailed;
    }

    fn present(self: *X11Backend, canvas: *Canvas) !void {
        try self.ensureImage(canvas);
        _ = x11.XPutImage(self.display, self.window, self.gc, self.image.?, 0, 0, 0, 0, canvas.width, canvas.height);
        _ = x11.XFlush(self.display);
    }

    fn pollEvent(self: *X11Backend) ?InputEvent {
        if (x11.XPending(self.display) <= 0) return null;
        var event: x11.XEvent = undefined;
        _ = x11.XNextEvent(self.display, &event);
        switch (event.type) {
            x11.ClientMessage => {
                if (@as(x11.Atom, @intCast(event.xclient.data.l[0])) == self.wm_delete) return .close;
            },
            x11.ConfigureNotify => {
                return .{ .resize = .{
                    .width = @intCast(@max(event.xconfigure.width, 360)),
                    .height = @intCast(@max(event.xconfigure.height, 620)),
                } };
            },
            x11.MotionNotify => return .{ .mouse_move = .{ .x = event.xmotion.x, .y = event.xmotion.y } },
            x11.ButtonPress => if (event.xbutton.button == x11.Button1) return .{ .mouse_down = .{ .x = event.xbutton.x, .y = event.xbutton.y } },
            x11.KeyPress => {
                var key_buf: [16]c_char = undefined;
                var keysym: x11.KeySym = 0;
                const count = x11.XLookupString(&event.xkey, @ptrCast(&key_buf[0]), @intCast(key_buf.len), &keysym, null);
                if (keysym == x11.XK_Escape) return .{ .key = .escape };
                if (keysym == x11.XK_Tab) return .{ .key = .tab };
                if (keysym == x11.XK_Return or keysym == x11.XK_KP_Enter) return .{ .key = .enter };
                if (keysym == x11.XK_BackSpace or keysym == x11.XK_Delete) return .{ .key = .backspace };
                const control = (event.xkey.state & x11.ControlMask) != 0;
                if (control and (keysym == x11.XK_u or keysym == x11.XK_U or keysym == x11.XK_a or keysym == x11.XK_A)) return .{ .key = .clear };
                if (count > 0) {
                    const byte: u8 = @bitCast(key_buf[0]);
                    if (byte >= 0x20 and byte <= 0x7e) return .{ .text = byte };
                }
            },
            else => {},
        }
        return null;
    }

    fn deinit(self: *X11Backend) void {
        self.destroyImage();
        _ = x11.XFreeGC(self.display, self.gc);
        _ = x11.XDestroyWindow(self.display, self.window);
        _ = x11.XCloseDisplay(self.display);
    }
} else struct {};

pub const App = struct {
    allocator: std.mem.Allocator,
    canvas: Canvas,
    backend: if (desktop_x11) X11Backend else void,
    page: Page = .home,
    focus: FocusId = .none,
    action: Action = .none,
    running: bool = true,
    force_phone: bool = false,
    mouse_x: i32 = 0,
    mouse_y: i32 = 0,
    widgets: [96]Widget = undefined,
    widget_count: usize = 0,
    frame_index: u32 = 0,
    memory_locked: bool = false,
    canvas_locked: bool = false,

    chat: TextBuffer = .{},
    road: [6]TextBuffer = [_]TextBuffer{.{}} ** 6,
    food: [6]TextBuffer = [_]TextBuffer{.{}} ** 6,
    clef: TextBuffer = .{},
    output: TextBuffer = .{},
    route: TextBuffer = .{},
    quantum: TextBuffer = .{},
    security: TextBuffer = .{},
    model_status: TextBuffer = .{},
    model_busy: bool = false,
    inference_busy: bool = false,

    pub fn init(allocator: std.mem.Allocator, force_phone: bool) !App {
        if (!desktop_x11) return error.GuiBackendUnavailable;
        const width: u32 = if (force_phone) 430 else 1240;
        const height: u32 = if (force_phone) 860 else 800;
        var canvas = try Canvas.init(allocator, width, height);
        errdefer canvas.deinit();
        const backend = try X11Backend.init(width, height);
        var app = App{
            .allocator = allocator,
            .canvas = canvas,
            .backend = backend,
            .force_phone = force_phone,
        };
        app.output.set("Ready. No raw prompt is persisted by the GUI.");
        app.route.set("Quantum route idle.");
        app.model_status.set("Not verified. Choose DOWNLOAD or VERIFY. Existing models are never overwritten.");
        app.security.set("SECURE UI: custom Zig renderer, no webview, no clipboard hooks, fixed buffers, explicit memory scrubbing. X11 remains an OS trust boundary; prefer an isolated desktop session for sensitive use.");
        return app;
    }

    pub fn harden(self: *App) !void {
        if (!desktop_x11) return error.GuiBackendUnavailable;
        // X11 itself is not a security boundary between same-user clients, but
        // the process can still prevent core-dump leakage and pin live GUI
        // state so prompts are not swapped to disk. Fail closed if either
        // operation is unavailable.
        if (x11.prctl(x11.PR_SET_DUMPABLE, @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0)) != 0) return error.ProcessHardeningFailed;
        if (x11.mlock(@ptrCast(self), @sizeOf(App)) != 0) return error.MemoryLockFailed;
        errdefer _ = x11.munlock(@ptrCast(self), @sizeOf(App));
        const canvas_bytes = self.canvas.pixels.len * @sizeOf(u32);
        if (x11.mlock(@ptrCast(self.canvas.pixels.ptr), canvas_bytes) != 0) return error.FramebufferMemoryLockFailed;
        errdefer _ = x11.munlock(@ptrCast(self.canvas.pixels.ptr), canvas_bytes);
        self.canvas_locked = true;
        self.memory_locked = true;
    }

    pub fn deinit(self: *App) void {
        self.clearSensitive();
        self.output.clear();
        self.route.clear();
        self.quantum.clear();
        self.security.clear();
        self.model_status.clear();
        if (desktop_x11 and self.canvas_locked) {
            _ = x11.munlock(@ptrCast(self.canvas.pixels.ptr), self.canvas.pixels.len * @sizeOf(u32));
            self.canvas_locked = false;
        }
        if (desktop_x11 and self.memory_locked) {
            self.memory_locked = false;
            _ = x11.munlock(@ptrCast(self), @sizeOf(App));
        }
        if (desktop_x11) self.backend.deinit();
        self.canvas.deinit();
    }

    pub fn isRunning(self: *const App) bool {
        return self.running;
    }

    pub const FrameView = struct {
        pixels: []const u32,
        width: u32,
        height: u32,
    };

    pub fn frameView(self: *const App) FrameView {
        return .{ .pixels = self.canvas.pixels, .width = self.canvas.width, .height = self.canvas.height };
    }

    pub fn takeAction(self: *App) Action {
        const out = self.action;
        self.action = .none;
        return out;
    }

    pub fn chatText(self: *const App) []const u8 {
        return self.chat.slice();
    }

    pub fn scanText(self: *const App, food_mode: bool, index: usize) []const u8 {
        if (index >= 6) return "";
        return if (food_mode) self.food[index].slice() else self.road[index].slice();
    }

    pub fn clefText(self: *const App) []const u8 {
        return self.clef.slice();
    }

    pub fn setOutput(self: *App, text: []const u8) void {
        self.output.set(text);
    }

    pub fn setRoute(self: *App, text: []const u8) void {
        self.route.set(text);
    }

    pub fn setQuantum(self: *App, text: []const u8) void {
        self.quantum.set(text);
    }

    pub fn setSecurity(self: *App, text: []const u8) void {
        self.security.set(text);
    }

    pub fn setModelStatus(self: *App, text: []const u8, busy: bool) void {
        self.model_status.set(text);
        self.model_busy = busy;
    }

    pub fn clearChat(self: *App) void {
        self.chat.clear();
    }

    pub fn clearClef(self: *App) void {
        self.clef.clear();
    }

    pub fn clearSensitive(self: *App) void {
        self.chat.clear();
        for (&self.road) |*field| field.clear();
        for (&self.food) |*field| field.clear();
        self.clef.clear();
        self.focus = .none;
    }

    fn isPhone(self: *const App) bool {
        return usesPhoneLayout(self.canvas.width, self.force_phone);
    }

    fn addWidget(self: *App, rect: Rect, kind: WidgetKind, id: u8) void {
        if (self.widget_count >= self.widgets.len) return;
        self.widgets[self.widget_count] = .{ .rect = rect, .kind = kind, .id = id };
        self.widget_count += 1;
    }

    fn fieldForFocus(self: *App, focus: FocusId) ?*TextBuffer {
        const raw = @intFromEnum(focus);
        if (focus == .chat) return &self.chat;
        if (raw >= @intFromEnum(FocusId.road_0) and raw <= @intFromEnum(FocusId.road_5)) return &self.road[raw - @intFromEnum(FocusId.road_0)];
        if (raw >= @intFromEnum(FocusId.food_0) and raw <= @intFromEnum(FocusId.food_5)) return &self.food[raw - @intFromEnum(FocusId.food_0)];
        if (focus == .clef) return &self.clef;
        return null;
    }

    fn submitForFocus(self: *App) void {
        if (self.focus == .chat) self.action = .chat_submit else if (self.focus == .clef) self.action = .clef_submit;
    }

    fn advanceFocus(self: *App) void {
        const raw = @intFromEnum(self.focus);
        if (raw >= @intFromEnum(FocusId.road_0) and raw < @intFromEnum(FocusId.road_5)) {
            self.focus = @enumFromInt(raw + 1);
        } else if (raw == @intFromEnum(FocusId.road_5)) {
            self.action = .road_scan;
        } else if (raw >= @intFromEnum(FocusId.food_0) and raw < @intFromEnum(FocusId.food_5)) {
            self.focus = @enumFromInt(raw + 1);
        } else if (raw == @intFromEnum(FocusId.food_5)) {
            self.action = .food_scan;
        } else {
            self.submitForFocus();
        }
    }

    fn onClick(self: *App, x: i32, y: i32) void {
        var i = self.widget_count;
        while (i > 0) {
            i -= 1;
            const widget = self.widgets[i];
            if (!widget.rect.contains(x, y)) continue;
            switch (widget.kind) {
                .nav => {
                    self.page = @enumFromInt(widget.id);
                    self.focus = .none;
                    if (self.page == .quantum) self.action = .quantum_refresh;
                },
                .input => self.focus = @enumFromInt(widget.id),
                .button => switch (@as(ButtonId, @enumFromInt(widget.id))) {
                    .chat_send => self.action = .chat_submit,
                    .road_scan => self.action = .road_scan,
                    .food_scan => self.action = .food_scan,
                    .clef_send => self.action = .clef_submit,
                    .quantum_refresh => self.action = .quantum_refresh,
                    .self_test => self.action = .self_test,
                    .clear_sensitive => self.action = .clear_sensitive,
                    .model_download => if (!self.model_busy) {
                        self.action = .model_download;
                    },
                    .model_verify => if (!self.model_busy) {
                        self.action = .model_verify;
                    },
                    .inference_cancel => self.action = .inference_cancel,
                    .model_cancel => if (self.model_busy) {
                        self.action = .model_cancel;
                    },
                    .open_models => {
                        self.page = .models;
                        self.focus = .none;
                    },
                    .open_security => {
                        self.page = .security;
                        self.focus = .none;
                    },
                },
            }
            return;
        }
        self.focus = .none;
    }

    fn onKey(self: *App, key: InputKey) void {
        switch (key) {
            .escape => {
                self.focus = .none;
                return;
            },
            .tab, .enter => {
                self.advanceFocus();
                return;
            },
            .backspace => {
                const field = self.fieldForFocus(self.focus) orelse return;
                field.backspace();
            },
            .clear => {
                const field = self.fieldForFocus(self.focus) orelse return;
                field.clear();
            },
        }
    }

    fn processEvents(self: *App) !void {
        if (!desktop_x11) return error.GuiBackendUnavailable;
        while (self.backend.pollEvent()) |event| {
            switch (event) {
                .close => self.running = false,
                .resize => |size| {
                    if (size.width != self.canvas.width or size.height != self.canvas.height) {
                        self.backend.destroyImage();
                        if (self.canvas_locked) {
                            _ = x11.munlock(@ptrCast(self.canvas.pixels.ptr), self.canvas.pixels.len * @sizeOf(u32));
                            self.canvas_locked = false;
                        }
                        try self.canvas.resize(size.width, size.height);
                        if (self.memory_locked) {
                            if (x11.mlock(@ptrCast(self.canvas.pixels.ptr), self.canvas.pixels.len * @sizeOf(u32)) != 0) return error.FramebufferMemoryLockFailed;
                            self.canvas_locked = true;
                        }
                    }
                },
                .mouse_move => |pos| {
                    self.mouse_x = pos.x;
                    self.mouse_y = pos.y;
                },
                .mouse_down => |pos| {
                    self.mouse_x = pos.x;
                    self.mouse_y = pos.y;
                    self.onClick(pos.x, pos.y);
                },
                .text => |byte| {
                    const field = self.fieldForFocus(self.focus) orelse continue;
                    field.appendAscii(byte);
                },
                .key => |key| self.onKey(key),
            }
        }
    }

    pub fn pump(self: *App) !void {
        if (!self.running) return;
        try self.processEvents();
        self.render();
        if (desktop_x11) try self.backend.present(&self.canvas);
        self.frame_index +%= 1;
        std.Thread.sleep(16 * std.time.ns_per_ms);
    }

    fn label(self: *App, x: i32, y: i32, text: []const u8, scale: i32, color: u32) void {
        _ = ZigGlyphEngine.draw(&self.canvas, x, y, text, scale, color);
    }

    fn chip(self: *App, x: i32, y: i32, text: []const u8, color: u32) void {
        const chars: i32 = @intCast(@min(@as(usize, 28), text.len));
        const width: i32 = chars * 12 + 28;
        self.canvas.roundedRect(.{ .x = x, .y = y, .w = width, .h = 30 }, 15, color, 42);
        self.label(x + 14, y + 8, text[0..@min(text.len, 28)], 2, color);
    }

    fn button(self: *App, rect: Rect, id: ButtonId, text: []const u8, accent_a: u32, accent_b: u32) void {
        const hover = rect.contains(self.mouse_x, self.mouse_y);
        self.canvas.roundedRect(.{ .x = rect.x + 1, .y = rect.y + 5, .w = rect.w, .h = rect.h }, 16, 0, 55);
        self.canvas.gradientPill(rect, accent_a, accent_b);
        if (hover) self.canvas.roundedRect(rect, 16, 0xFFFFFF, 25);
        self.label(rect.x + 18, rect.y + @divTrunc(rect.h, 2) - 7, text, 2, 0x07101C);
        self.addWidget(rect, .button, @intFromEnum(id));
    }

    fn input(self: *App, rect: Rect, focus: FocusId, label_text: []const u8, value: []const u8) void {
        const active = self.focus == focus;
        const border = if (active) theme.cyan else theme.stroke;
        self.canvas.roundedRect(rect, 14, theme.surface_hi, 220);
        self.canvas.roundedRect(.{ .x = rect.x, .y = rect.y, .w = rect.w, .h = 2 }, 1, border, if (active) 255 else 150);
        self.label(rect.x + 14, rect.y + 10, label_text, 1, if (active) theme.cyan else theme.text_soft);
        const max_chars: usize = @intCast(@max(@divTrunc(rect.w - 28, 12), 1));
        const display = if (value.len > max_chars) value[value.len - max_chars ..] else value;
        if (display.len != 0) self.label(rect.x + 14, rect.y + 30, display, 2, theme.text) else self.label(rect.x + 14, rect.y + 30, "blank", 2, theme.muted);
        if (active and ((self.frame_index / 28) % 2 == 0)) {
            const cursor_x = rect.x + 14 + @as(i32, @intCast(display.len)) * 12;
            self.canvas.fillRect(.{ .x = @min(cursor_x, rect.x + rect.w - 12), .y = rect.y + 29, .w = 2, .h = 17 }, theme.cyan);
        }
        self.addWidget(rect, .input, @intFromEnum(focus));
    }

    fn navItem(self: *App, rect: Rect, page: Page, text: []const u8, glyph: []const u8) void {
        const selected = self.page == page;
        if (selected) self.canvas.roundedRect(rect, 14, theme.cyan, 28) else if (rect.contains(self.mouse_x, self.mouse_y)) self.canvas.roundedRect(rect, 14, theme.surface_hi, 180);
        self.label(rect.x + 16, rect.y + 14, glyph, 2, if (selected) theme.cyan else theme.text_soft);
        self.label(rect.x + 48, rect.y + 14, text, 2, if (selected) theme.text else theme.text_soft);
        self.addWidget(rect, .nav, @intFromEnum(page));
    }

    fn bottomNav(self: *App, height: i32) void {
        const w: i32 = @intCast(self.canvas.width);
        const bar = Rect{ .x = 12, .y = height - 76, .w = w - 24, .h = 64 };
        self.canvas.roundedRect(bar, 24, theme.surface, 246);
        const pages = [_]Page{ .home, .chat, .road, .food, .quantum, .models };
        const labels = [_][]const u8{ "HOME", "CHAT", "ROAD", "FOOD", "Q", "MODEL" };
        const each = @divTrunc(bar.w, 6);
        for (pages, 0..) |page, i| {
            const r = Rect{ .x = bar.x + @as(i32, @intCast(i)) * each + 4, .y = bar.y + 4, .w = each - 8, .h = 56 };
            if (self.page == page) self.canvas.roundedRect(r, 18, theme.cyan, 30);
            self.label(r.x + 8, r.y + 20, labels[i], 1, if (self.page == page) theme.cyan else theme.text_soft);
            self.addWidget(r, .nav, @intFromEnum(page));
        }
    }

    fn appChrome(self: *App) Rect {
        const phone = self.isPhone();
        const w: i32 = @intCast(self.canvas.width);
        const h: i32 = @intCast(self.canvas.height);
        if (!phone) {
            self.canvas.roundedRect(.{ .x = 18, .y = 18, .w = 220, .h = h - 36 }, 24, theme.surface, 235);
            self.label(42, 46, "NAZA", 4, theme.text);
            self.label(42, 83, "QUANTUM SECURE", 1, theme.cyan);
            self.chip(38, 112, "ZIG NATIVE", theme.green);
            var y: i32 = 164;
            const nav = [_]struct { page: Page, label: []const u8, glyph: []const u8 }{
                .{ .page = .home, .label = "Home", .glyph = "#" },
                .{ .page = .chat, .label = "Chat", .glyph = ">" },
                .{ .page = .road, .label = "Road", .glyph = "=" },
                .{ .page = .food, .label = "Food", .glyph = "+" },
                .{ .page = .quantum, .label = "Quantum", .glyph = "Q" },
                .{ .page = .security, .label = "Security", .glyph = "*" },
                .{ .page = .models, .label = "Models", .glyph = "M" },
            };
            for (nav) |item| {
                self.navItem(.{ .x = 30, .y = y, .w = 196, .h = 48 }, item.page, item.label, item.glyph);
                y += 58;
            }
            self.label(42, h - 68, "LOCAL / NO WEBVIEW", 1, theme.muted);
            self.label(42, h - 48, "MEMORY SCRUB ENABLED", 1, theme.muted);
            return .{ .x = 262, .y = 22, .w = w - 284, .h = h - 44 };
        }
        self.label(22, 24, "NAZA", 3, theme.text);
        self.label(22, 52, "QUANTUM SECURE", 1, theme.cyan);
        self.bottomNav(h);
        return .{ .x = 16, .y = 86, .w = w - 32, .h = h - 176 };
    }

    fn pageHeader(self: *App, content: Rect, title: []const u8, subtitle: []const u8) i32 {
        self.label(content.x + 2, content.y + 4, title, if (self.isPhone()) 3 else 4, theme.text);
        ZigGlyphEngine.drawWrapped(&self.canvas, .{ .x = content.x + 2, .y = content.y + 44, .w = content.w - 4, .h = 60 }, subtitle, 1, theme.text_soft, 3);
        return content.y + 86;
    }

    fn homePage(self: *App, content: Rect) void {
        var y = self.pageHeader(content, "LOCAL INTELLIGENCE", "Native Zig interface for Clef routing, risk scans and cryptographic state. No browser engine in the trust boundary.");
        const phone = self.isPhone();
        const hero_h: i32 = if (phone) 160 else 190;
        const hero = Rect{ .x = content.x, .y = y, .w = content.w, .h = hero_h };
        self.canvas.card(hero, theme.violet);
        self.canvas.glowCircle(hero.x + hero.w - 100, hero.y + 70, 90, theme.magenta, 22);
        self.label(hero.x + 24, hero.y + 24, "30 CIRCUITS", if (phone) 3 else 4, theme.cyan);
        self.label(hero.x + 24, hero.y + 66, "8-14 QUBITS / STOCHASTIC RAG", if (phone) 1 else 2, theme.text);
        ZigGlyphEngine.drawWrapped(&self.canvas, .{ .x = hero.x + 24, .y = hero.y + 102, .w = hero.w - 48, .h = 60 }, "Five-profile semantic shortlist. Temperature 0.55. Clef reward updates remain local.", 1, theme.text_soft, 3);
        y += hero_h + 16;

        if (phone) {
            const cards = [_]struct { title: []const u8, body: []const u8, accent: u32 }{
                .{ .title = "ROAD", .body = "Six blank-safe evidence fields", .accent = theme.cyan },
                .{ .title = "FOOD / WATER", .body = "Same secure vertical capture", .accent = theme.green },
                .{ .title = "CLEF", .body = "Explicit local reward feedback", .accent = theme.violet },
            };
            for (cards) |item| {
                const r = Rect{ .x = content.x, .y = y, .w = content.w, .h = 86 };
                self.canvas.card(r, item.accent);
                self.label(r.x + 20, r.y + 18, item.title, 2, item.accent);
                self.label(r.x + 20, r.y + 48, item.body, 1, theme.text_soft);
                y += 98;
            }
        } else {
            const gap: i32 = 14;
            const cw = @divTrunc(content.w - gap * 2, 3);
            const cards = [_]struct { title: []const u8, body: []const u8, accent: u32 }{
                .{ .title = "ROAD", .body = "Blank-safe scan fields", .accent = theme.cyan },
                .{ .title = "FOOD / WATER", .body = "Evidence capture", .accent = theme.green },
                .{ .title = "CLEF", .body = "Feedback memory", .accent = theme.violet },
            };
            for (cards, 0..) |item, i| {
                const r = Rect{ .x = content.x + @as(i32, @intCast(i)) * (cw + gap), .y = y, .w = cw, .h = 120 };
                self.canvas.card(r, item.accent);
                self.label(r.x + 18, r.y + 18, item.title, 2, item.accent);
                self.label(r.x + 18, r.y + 52, item.body, 1, theme.text_soft);
            }
            y += 136;
        }
        const sec = Rect{ .x = content.x, .y = y, .w = @min(content.w, 360), .h = 48 };
        self.button(sec, .open_security, "SECURITY CENTER", theme.green, theme.cyan);
        self.button(.{ .x = content.x, .y = y + 60, .w = @min(content.w, 360), .h = 48 }, .open_models, "MODEL MANAGER", theme.cyan, theme.violet);
    }

    fn modelsPage(self: *App, content: Rect) void {
        var y = self.pageHeader(content, "MODEL MANAGER", "Download and verify the pinned model. Installation accepts only the compiled SHA-256. You can cancel while the interface stays responsive.");
        const identity = Rect{ .x = content.x, .y = y, .w = content.w, .h = 164 };
        self.canvas.card(identity, theme.cyan);
        self.label(identity.x + 16, y + 16, @import("model_spec.zig").label, 2, theme.cyan);
        ZigGlyphEngine.drawWrapped(&self.canvas, .{ .x = identity.x + 16, .y = y + 48, .w = identity.w - 32, .h = 100 }, "Source: HuggingFaceTB/SmolLM2-360M-Instruct-GGUF\nFile: models/smollm2-360m-instruct-q8_0.gguf\nHTTPS / max 512 MiB / private staging / no overwrite\nSHA-256:\n48ab3034d0dd401fbc721eb1df3217902\nfee7dab9078992d66431f09b7750201", 1, theme.text_soft, 10);
        y += 180;
        const button_w = @min(content.w, 280);
        if (self.model_busy) {
            self.button(.{ .x = content.x, .y = y, .w = button_w, .h = 48 }, .model_cancel, "CANCEL", theme.amber, theme.magenta);
            y += 60;
        } else {
            self.button(.{ .x = content.x, .y = y, .w = button_w, .h = 48 }, .model_download, "DOWNLOAD + VERIFY", theme.cyan, theme.green);
            self.button(.{ .x = content.x, .y = y + 60, .w = button_w, .h = 48 }, .model_verify, "VERIFY LOCAL MODEL", theme.violet, theme.cyan);
            y += 120;
        }
        const remaining = content.y + content.h - y;
        if (remaining > 50) {
            const status = Rect{ .x = content.x, .y = y, .w = content.w, .h = remaining };
            self.canvas.card(status, theme.green);
            ZigGlyphEngine.drawWrapped(&self.canvas, .{ .x = status.x + 16, .y = y + 16, .w = status.w - 32, .h = status.h - 32 }, self.model_status.slice(), 1, theme.text, @intCast(@max(@divTrunc(status.h - 32, 9), 1)));
        }
    }

    fn chatPage(self: *App, content: Rect) void {
        var y = self.pageHeader(content, "CHAT / ROUTER", "Local GGUF model replies with the 30-circuit router. STOP cancels generation. Commands /clef and /quantum also work from the CLI.");
        const phone = self.isPhone();
        const route_h: i32 = if (phone) 76 else 64;
        const route_card = Rect{ .x = content.x, .y = y, .w = content.w, .h = route_h };
        self.canvas.card(route_card, theme.violet);
        self.label(route_card.x + 18, route_card.y + 14, "ROUTE", 1, theme.violet);
        ZigGlyphEngine.drawWrapped(&self.canvas, .{ .x = route_card.x + 18, .y = route_card.y + 34, .w = route_card.w - 36, .h = route_h - 36 }, self.route.slice(), 1, theme.text_soft, if (phone) 2 else 1);
        y += route_h + 12;

        const output_h = @max(content.h - 250, 120);
        const out = Rect{ .x = content.x, .y = y, .w = content.w, .h = output_h };
        self.canvas.card(out, theme.cyan);
        self.label(out.x + 18, out.y + 14, "OUTPUT", 1, theme.cyan);
        ZigGlyphEngine.drawWrapped(&self.canvas, .{ .x = out.x + 18, .y = out.y + 40, .w = out.w - 36, .h = out.h - 54 }, self.output.slice(), if (phone) 1 else 2, theme.text, @intCast(@max(@divTrunc(out.h - 54, @as(i32, if (phone) 9 else 18)), 1)));
        y += output_h + 12;

        const input_h: i32 = 68;
        const button_w: i32 = if (phone) 96 else 136;
        self.input(.{ .x = content.x, .y = y, .w = content.w - button_w - 10, .h = input_h }, .chat, "message", self.chat.slice());
        self.button(.{ .x = content.x + content.w - button_w, .y = y + 9, .w = button_w, .h = 50 }, if (self.inference_busy) .inference_cancel else .chat_send, if (self.inference_busy) "STOP" else "SEND", theme.cyan, theme.violet);
    }

    fn scannerPage(self: *App, content: Rect, food_mode: bool) void {
        const title = if (food_mode) "FOOD / WATER" else "ROAD SCANNER";
        const subtitle = if (food_mode) "Six evidence fields. Enter leaves a field genuinely blank; no hidden fallback values." else "Six road evidence fields. Blank means blank. Road scans route through the quantum ensemble.";
        var y = self.pageHeader(content, title, subtitle);
        const phone = self.isPhone();
        const labels_road = [_][]const u8{ "location", "road type", "weather / visibility", "traffic density", "reported obstacles", "sensor notes" };
        const labels_food = [_][]const u8{ "location", "food or water type", "condition", "temperature", "cooked / frozen / uncooked", "sensor notes" };
        const labels = if (food_mode) labels_food else labels_road;
        const base_focus: u8 = if (food_mode) @intFromEnum(FocusId.food_0) else @intFromEnum(FocusId.road_0);
        const fields = if (food_mode) &self.food else &self.road;

        if (phone) {
            for (0..6) |i| {
                self.input(.{ .x = content.x, .y = y, .w = content.w, .h = 58 }, @enumFromInt(base_focus + @as(u8, @intCast(i))), labels[i], fields[i].slice());
                y += 66;
            }
        } else {
            const gap: i32 = 12;
            const fw = @divTrunc(content.w - gap, 2);
            for (0..6) |i| {
                const row: i32 = @intCast(i / 2);
                const col: i32 = @intCast(i % 2);
                self.input(.{ .x = content.x + col * (fw + gap), .y = y + row * 76, .w = fw, .h = 64 }, @enumFromInt(base_focus + @as(u8, @intCast(i))), labels[i], fields[i].slice());
            }
            y += 3 * 76;
        }

        const button_id: ButtonId = if (self.inference_busy) .inference_cancel else if (food_mode) .food_scan else .road_scan;
        const accent_a = if (food_mode) theme.green else theme.cyan;
        self.button(.{ .x = content.x, .y = y + 4, .w = @min(content.w, 220), .h = 52 }, button_id, if (self.inference_busy) "STOP" else "ANALYZE", accent_a, theme.violet);
        y += 68;
        const remaining = content.y + content.h - y;
        if (remaining > 80) {
            const out = Rect{ .x = content.x, .y = y, .w = content.w, .h = remaining };
            self.canvas.card(out, accent_a);
            self.label(out.x + 18, out.y + 14, "RESULT", 1, accent_a);
            ZigGlyphEngine.drawWrapped(&self.canvas, .{ .x = out.x + 18, .y = out.y + 38, .w = out.w - 36, .h = out.h - 48 }, self.output.slice(), 1, theme.text, @intCast(@max(@divTrunc(out.h - 48, 9), 1)));
        }
    }

    fn quantumPage(self: *App, content: Rect) void {
        var y = self.pageHeader(content, "QUANTUM ROUTER", "Historical Clef reward, entropy quality and stochastic shortlist state. Raw questions are not stored here.");
        const phone = self.isPhone();
        const out_h = @max(content.h - 205, 150);
        const out = Rect{ .x = content.x, .y = y, .w = content.w, .h = out_h };
        self.canvas.card(out, theme.violet);
        self.label(out.x + 18, out.y + 14, "CIRCUIT HISTORY", 1, theme.violet);
        ZigGlyphEngine.drawWrapped(&self.canvas, .{ .x = out.x + 18, .y = out.y + 40, .w = out.w - 36, .h = out.h - 50 }, self.quantum.slice(), 1, theme.text, @intCast(@max(@divTrunc(out.h - 50, 9), 1)));
        y += out_h + 12;
        const input_w = if (phone) content.w - 118 else @min(content.w - 250, 360);
        self.input(.{ .x = content.x, .y = y, .w = input_w, .h = 62 }, .clef, "Clef score 0-100", self.clef.slice());
        self.button(.{ .x = content.x + input_w + 10, .y = y + 7, .w = 108, .h = 48 }, .clef_send, "SCORE", theme.violet, theme.magenta);
        if (!phone) self.button(.{ .x = content.x + input_w + 128, .y = y + 7, .w = 122, .h = 48 }, .quantum_refresh, "REFRESH", theme.cyan, theme.violet);
    }

    fn securityPage(self: *App, content: Rect) void {
        var y = self.pageHeader(content, "SECURITY CENTER", "The GUI narrows the trust boundary: native X11 surface, software renderer, embedded font, no HTML engine and no clipboard hooks.");
        const items = [_]struct { name: []const u8, value: []const u8, accent: u32 }{
            .{ .name = "RENDERER", .value = "PURE ZIG SOFTWARE", .accent = theme.green },
            .{ .name = "FONT", .value = "EMBEDDED ZIGGLYPH", .accent = theme.cyan },
            .{ .name = "INPUT", .value = "FIXED BUFFER + SCRUB", .accent = theme.violet },
            .{ .name = "CLIPBOARD", .value = "DISABLED BY DESIGN", .accent = theme.amber },
            .{ .name = "WEBVIEW", .value = "NOT PRESENT", .accent = theme.green },
        };
        const phone = self.isPhone();
        for (items) |item| {
            const r = Rect{ .x = content.x, .y = y, .w = content.w, .h = if (phone) 58 else 50 };
            self.canvas.card(r, item.accent);
            self.label(r.x + 16, r.y + 13, item.name, 1, item.accent);
            self.label(r.x + @as(i32, if (phone) 16 else 180), r.y + @as(i32, if (phone) 32 else 13), item.value, 1, theme.text);
            y += r.h + 8;
        }
        self.button(.{ .x = content.x, .y = y + 4, .w = @min(content.w, 200), .h = 50 }, .self_test, "RUN SELF TEST", theme.green, theme.cyan);
        self.button(.{ .x = content.x + @min(content.w, 200) + 10, .y = y + 4, .w = @min(@max(content.w - 210, 120), 210), .h = 50 }, .clear_sensitive, "SCRUB INPUTS", theme.amber, theme.magenta);
        y += 66;
        const remaining = content.y + content.h - y;
        if (remaining > 70) {
            const out = Rect{ .x = content.x, .y = y, .w = content.w, .h = remaining };
            self.canvas.card(out, theme.green);
            ZigGlyphEngine.drawWrapped(&self.canvas, .{ .x = out.x + 16, .y = out.y + 16, .w = out.w - 32, .h = out.h - 32 }, self.security.slice(), 1, theme.text_soft, @intCast(@max(@divTrunc(out.h - 32, 9), 1)));
        }
    }

    fn render(self: *App) void {
        self.widget_count = 0;
        self.canvas.background(self.frame_index / 3);
        const content = self.appChrome();
        switch (self.page) {
            .home => self.homePage(content),
            .chat => self.chatPage(content),
            .road => self.scannerPage(content, false),
            .food => self.scannerPage(content, true),
            .quantum => self.quantumPage(content),
            .security => self.securityPage(content),
            .models => self.modelsPage(content),
        }
    }
};

test "secure text buffer blank semantics" {
    var buffer = TextBuffer{};
    try std.testing.expectEqual(@as(usize, 0), buffer.slice().len);
    buffer.appendAscii('x');
    try std.testing.expectEqualStrings("x", buffer.slice());
    buffer.clear();
    try std.testing.expectEqual(@as(usize, 0), buffer.slice().len);
    for (buffer.data) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

test "responsive phone threshold" {
    try std.testing.expect(usesPhoneLayout(430, false));
    try std.testing.expect(!usesPhoneLayout(1240, false));
    try std.testing.expect(usesPhoneLayout(1240, true));
}

test "model manager renders and dispatches desktop and phone controls" {
    for ([_]bool{ false, true }) |phone| {
        var app = App{
            .allocator = std.testing.allocator,
            .canvas = try Canvas.init(std.testing.allocator, if (phone) 430 else 1240, if (phone) 860 else 800),
            .backend = undefined,
            .page = .models,
            .force_phone = phone,
        };
        defer app.canvas.deinit();
        app.model_status.set("Ready. Choose DOWNLOAD or VERIFY.");
        app.render();
        var downloads: usize = 0;
        var verifies: usize = 0;
        for (app.widgets[0..app.widget_count]) |widget| {
            if (widget.kind != .button) continue;
            try std.testing.expect(widget.rect.x >= 0 and widget.rect.y >= 0);
            try std.testing.expect(widget.rect.x + widget.rect.w <= app.canvas.width);
            try std.testing.expect(widget.rect.y + widget.rect.h <= app.canvas.height);
            app.onClick(widget.rect.x + 1, widget.rect.y + 1);
            if (widget.id == @intFromEnum(ButtonId.model_download)) {
                downloads += 1;
                try std.testing.expectEqual(Action.model_download, app.takeAction());
            } else if (widget.id == @intFromEnum(ButtonId.model_verify)) {
                verifies += 1;
                try std.testing.expectEqual(Action.model_verify, app.takeAction());
            }
        }
        try std.testing.expectEqual(@as(usize, 1), downloads);
        try std.testing.expectEqual(@as(usize, 1), verifies);

        if (std.process.getEnvVarOwned(std.testing.allocator, "NAZA_GUI_TEST_PREVIEW_DIR") catch null) |directory| {
            defer std.testing.allocator.free(directory);
            var dir = try std.fs.openDirAbsolute(directory, .{});
            defer dir.close();
            var file = try dir.createFile(if (phone) "model-phone.ppm" else "model-desktop.ppm", .{});
            defer file.close();
            var header: [64]u8 = undefined;
            try file.writeAll(try std.fmt.bufPrint(&header, "P6\n{d} {d}\n255\n", .{ app.canvas.width, app.canvas.height }));
            const pixels = try std.testing.allocator.alloc(u8, app.canvas.pixels.len * 3);
            defer std.testing.allocator.free(pixels);
            for (app.canvas.pixels, 0..) |pixel, i| {
                pixels[i * 3] = @truncate(pixel >> 16);
                pixels[i * 3 + 1] = @truncate(pixel >> 8);
                pixels[i * 3 + 2] = @truncate(pixel);
            }
            try file.writeAll(pixels);
        }

        app.model_busy = true;
        app.render();
        var cancels: usize = 0;
        for (app.widgets[0..app.widget_count]) |widget| {
            if (widget.kind != .button) continue;
            try std.testing.expectEqual(@intFromEnum(ButtonId.model_cancel), widget.id);
            app.onClick(widget.rect.x + 1, widget.rect.y + 1);
            try std.testing.expectEqual(Action.model_cancel, app.takeAction());
            cancels += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), cancels);
    }
}

test "chat and scanner busy controls stop inference on desktop and phone" {
    for ([_]bool{ false, true }) |phone| {
        for ([_]Page{ .chat, .road, .food }) |page| {
            var app = App{
                .allocator = std.testing.allocator,
                .canvas = try Canvas.init(std.testing.allocator, if (phone) 430 else 1240, if (phone) 860 else 800),
                .backend = undefined,
                .page = page,
                .force_phone = phone,
                .inference_busy = true,
            };
            defer app.canvas.deinit();
            app.render();
            var stops: usize = 0;
            for (app.widgets[0..app.widget_count]) |widget| {
                if (widget.kind == .button and widget.id == @intFromEnum(ButtonId.inference_cancel)) {
                    stops += 1;
                    app.onClick(widget.rect.x + 1, widget.rect.y + 1);
                    try std.testing.expectEqual(Action.inference_cancel, app.takeAction());
                }
            }
            try std.testing.expectEqual(@as(usize, 1), stops);
        }
    }
}
