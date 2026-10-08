const stb = @import("stb");
const std = @import("std");

pub const FontError = error{
    InitializationFailed,
    GlyphNotFound,
};

/// Unscaled font metrics
pub const FontMetrics = struct {
    ascent: i32,
    descent: i32,
    line_gap: i32,
};

pub const GlyphBitmap = struct {
    width: i32,
    height: i32,
    x_offset: i32,
    y_offset: i32,
    pixels: []u8,

    pub fn deinit(self: GlyphBitmap, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }
};

pub const Font = struct {
    info: stb.stbtt_fontinfo,

    /// `font_data` must outlive the Font (stb keeps a pointer into it).
    pub fn init(font_data: []const u8) FontError!Font {
        var info: stb.stbtt_fontinfo = undefined;
        if (stb.stbtt_InitFont(&info, font_data.ptr, 0) == 0) {
            return FontError.InitializationFailed;
        }
        return .{ .info = info };
    }

    pub fn getMetrics(self: *const Font) FontMetrics {
        var ascent: c_int = 0;
        var descent: c_int = 0;
        var line_gap: c_int = 0;
        stb.stbtt_GetFontVMetrics(&self.info, &ascent, &descent, &line_gap);

        return .{
            .ascent = @intCast(ascent),
            .descent = @intCast(descent),
            .line_gap = @intCast(line_gap),
        };
    }

    /// Computes the pixel scale factor required to render at a given pixel height
    pub fn scaleForPixelHeight(self: *const Font, height_pixels: f32) f32 {
        return stb.stbtt_ScaleForPixelHeight(&self.info, height_pixels);
    }

    /// Safely return the font's internal glyph index for a codepoint.
    pub fn findGlyphIndex(self: *const Font, codepoint: u21) FontError!u32 {
        const idx = stb.stbtt_FindGlyphIndex(&self.info, @intCast(codepoint));
        if (idx == 0) return FontError.GlyphNotFound;
        return @intCast(idx);
    }

    /// Unscaled horizontal advance of a codepoint (multiply by the scale factor).
    pub fn getAdvance(self: *const Font, codepoint: u21) i32 {
        var advance: c_int = 0;
        var left_bearing: c_int = 0;
        stb.stbtt_GetCodepointHMetrics(&self.info, @intCast(codepoint), &advance, &left_bearing);
        return @intCast(advance);
    }

    /// Allocates and renders an alpha-only bitmap for a specific character,
    /// returning native types and leveraging Zig's Allocator for memory safety.
    /// Glyphs with no outline (e.g. space) return a 0x0 bitmap instead of an error.
    pub fn renderGlyphBitmap(
        self: *const Font,
        allocator: std.mem.Allocator,
        codepoint: u21,
        scale: f32,
    ) !GlyphBitmap {
        var width: c_int = 0;
        var height: c_int = 0;
        var x_offset: c_int = 0;
        var y_offset: c_int = 0;

        const c_pixels = stb.stbtt_GetCodepointBitmap(
            &self.info,
            scale,
            scale,
            @intCast(codepoint),
            &width,
            &height,
            &x_offset,
            &y_offset,
        );

        // stb returns NULL for empty glyphs such as space.
        if (c_pixels == null or width <= 0 or height <= 0) {
            if (c_pixels != null) stb.stbtt_FreeBitmap(c_pixels, null);
            return .{
                .width = 0,
                .height = 0,
                .x_offset = 0,
                .y_offset = 0,
                .pixels = try allocator.alloc(u8, 0),
            };
        }
        defer stb.stbtt_FreeBitmap(c_pixels, null);

        const total_bytes: usize = @intCast(width * height);

        const zig_pixels = try allocator.alloc(u8, total_bytes);
        errdefer allocator.free(zig_pixels);

        @memcpy(zig_pixels, c_pixels[0..total_bytes]);

        return .{
            .width = @intCast(width),
            .height = @intCast(height),
            .x_offset = @intCast(x_offset),
            .y_offset = @intCast(y_offset),
            .pixels = zig_pixels,
        };
    }
};
