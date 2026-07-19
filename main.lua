--[[--
@module koplugin.palmasleepscreen

Composes a sleep screen image from the current book's cover and reading progress:
the cover full-bleed across the top of the screen, and an information panel filled
with the cover's dominant colour below it.

Cover extraction and image writing follow plugins/coverimage.koplugin.
]]

local Blitbuffer = require("ffi/blitbuffer")
local DataStorage = require("datastorage")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageViewer = require("ui/widget/imageviewer")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local PathChooser = require("ui/widget/pathchooser")
local RenderImage = require("ui/renderimage")
local SpinWidget = require("ui/widget/spinwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffi = require("ffi")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local md5 = require("ffi/sha2").md5
local time = require("ui/time")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template
local Screen = Device.screen

-- The layout is specified in pixels at this reference width; everything is
-- scaled by (actual screen width / REF_WIDTH).
local REF_WIDTH = 824

local REF = {
    margin = 48,     -- side margins, and padding above/below the panel contents
    title = 54,
    author = 34,
    footer = 34,
    bar = 20,
    gap_title = 16,  -- title -> author
    gap_author = 32, -- author -> bar
    gap_bar = 20,    -- bar -> footer
    gap_footer = 24, -- footer <-> chapter, minimum
    meta = 26,       -- secondary line: chapter count, battery, timestamp
    gap_meta = 18,   -- footer -> secondary line
    tick = 2,        -- chapter mark width on the progress bar
}

-- Panel colour is pulled into this luminance band: the Kaleido 3 colour layer is
-- 150 PPI and renders near-black and near-white as flat blocks.
local LUMA_MIN, LUMA_MAX = 70, 135
-- Minimum WCAG contrast ratio between the panel and its text. Deliberately well
-- above the 4.5 web threshold: the colour layer washes out mid-tones.
local MIN_CONTRAST = 6.0
local MONO_FALLBACK = { r = 0x3A, g = 0x3C, b = 0x42 }

local RENDER_DELAY = 0.5 -- seconds; keeps the work well clear of the page-turn refresh

---------------------------------------------------------------------------
-- colour helpers
---------------------------------------------------------------------------

local function clamp8(v)
    if v < 0 then return 0 end
    if v > 255 then return 255 end
    return math.floor(v)
end

local function luminance(r, g, b)
    return 0.299 * r + 0.587 * g + 0.114 * b
end

--- Samples a cover on a coarse grid and returns its dominant colour, pulled
-- into the mid-lightness band. Returns nil if the cover is effectively
-- monochrome, so the caller can fall back.
local function dominantColour(bb)
    local w, h = bb:getWidth(), bb:getHeight()
    if w < 2 or h < 2 then return nil end

    local step = math.max(1, math.floor(math.min(w, h) / 48))
    local buckets = {}

    for y = 0, h - 1, step do
        for x = 0, w - 1, step do
            local c = bb:getPixel(x, y):getColorRGB32()
            local r, g, b = c.r, c.g, c.b
            -- discard near-white and near-black: they carry no hue and dominate
            -- the histogram of most covers
            local mx = math.max(r, g, b)
            local mn = math.min(r, g, b)
            if not (mn > 235 or mx < 32) then
                -- 8 levels per channel
                local key = math.floor(r / 32) * 64 + math.floor(g / 32) * 8 + math.floor(b / 32)
                local bucket = buckets[key]
                if bucket then
                    bucket.n = bucket.n + 1
                    bucket.r = bucket.r + r
                    bucket.g = bucket.g + g
                    bucket.b = bucket.b + b
                else
                    buckets[key] = { n = 1, r = r, g = g, b = b }
                end
            end
        end
    end

    -- Take the most frequent bucket that actually carries some hue. Picking the
    -- most frequent bucket outright loses to the large desaturated darks on
    -- covers like night skies, which would then be rejected as monochrome even
    -- though the cover has plenty of colour in it.
    local best, best_count = nil, 0
    for _key, bucket in pairs(buckets) do
        local r = bucket.r / bucket.n
        local g = bucket.g / bucket.n
        local b = bucket.b / bucket.n
        if math.max(r, g, b) - math.min(r, g, b) >= 25 and bucket.n > best_count then
            best_count = bucket.n
            best = { r = r, g = g, b = b }
        end
    end

    -- effectively monochrome: let the caller use the neutral fallback
    if not best then return nil end
    local r, g, b = best.r, best.g, best.b

    -- pull toward mid-lightness, preserving the channel ratios
    local l = luminance(r, g, b)
    if l > 0 then
        local target = math.max(LUMA_MIN, math.min(LUMA_MAX, l))
        local f = target / l
        r, g, b = r * f, g * f, b * f
    end

    return { r = clamp8(r), g = clamp8(g), b = clamp8(b) }
end

local function mix(a, b, t)
    return {
        r = clamp8(a.r + (b.r - a.r) * t),
        g = clamp8(a.g + (b.g - a.g) * t),
        b = clamp8(a.b + (b.b - a.b) * t),
    }
end

local function toColorRGB32(c)
    return Blitbuffer.ColorRGB32(c.r, c.g, c.b, 0xFF)
end

-- WCAG relative luminance (sRGB, gamma-decoded), and the contrast ratio built
-- on it. The simple 0.299/0.587/0.114 average above is fine for picking a
-- dominant colour but is not a contrast model.
local function relLuminance(c)
    local function ch(v)
        v = v / 255
        return v <= 0.03928 and v / 12.92 or ((v + 0.055) / 1.055) ^ 2.4
    end
    return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b)
end

local function contrastRatio(a, b)
    local la, lb = relLuminance(a), relLuminance(b)
    if la < lb then la, lb = lb, la end
    return (la + 0.05) / (lb + 0.05)
end

local WHITE = { r = 0xFF, g = 0xFF, b = 0xFF }
local BLACK = { r = 0x00, g = 0x00, b = 0x00 }

--- Picks black or white text for the panel, then pushes the panel colour away
-- from it until it clears MIN_CONTRAST. Choosing the text colour alone is not
-- enough: a mid-lightness panel is too close to both.
local function ensureContrast(panel)
    local use_white = contrastRatio(panel, WHITE) >= contrastRatio(panel, BLACK)
    local target = use_white and BLACK or WHITE -- direction to push the panel
    local c = { r = panel.r, g = panel.g, b = panel.b }
    -- 24 steps of 5% is enough to reach either extreme from anywhere
    for _ = 1, 24 do
        if contrastRatio(c, use_white and WHITE or BLACK) >= MIN_CONTRAST then break end
        c = mix(c, target, 0.05)
    end
    return c, use_white and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK, use_white
end

---------------------------------------------------------------------------
-- cover enhancement
---------------------------------------------------------------------------

-- The Kaleido 3 panel is two layers at different resolutions: the monochrome
-- layer runs at the full 300 PPI, the colour filter array over it at 150. So
-- luminance detail resolves at twice the resolution of chroma, and the filter
-- absorbs enough light that untouched sRGB art reads dark and washed out.
--
-- Hence the luma/chroma split below: luminance is taken sharp from the original
-- and carries the tone curve and the unsharp mask, while chroma is taken from a
-- blurred copy. Detail lands on the layer that can resolve it, and colour is fed
-- to the layer that cannot as a smooth wash.
--
-- Blurring chroma is not just free, it is the point. The panel dithers to reach
-- colours it cannot render directly, and low-amplitude chroma variation across a
-- smooth gradient -- a dusk sky, water -- dithers into visible magenta/green
-- speckle. Smoothing chroma before it ever reaches the dither removes the input
-- that produces the speckle, and the neutral gate below drops near-grey pixels
-- to true grey so they render on the monochrome layer alone.
--
-- This is also why saturation cannot be applied flat: multiplying all chroma by
-- 1.6 amplifies exactly the near-neutral noise that speckles worst. The gate
-- makes the boost proportional to how much colour a pixel actually has.
local ENHANCE_DEFAULTS = {
    saturation = 1.6,   -- chroma multiplier, compensating for the filter array
    brightness = 1.05,  -- gamma; above 1 lifts the midtones
    contrast = 0.25,    -- blend toward a smoothstep S-curve; 0 is off
    sharpness = 0.8,    -- unsharp mask amount, on luminance only
    chroma_blur = 2,    -- radius of the chroma low-pass, in pixels; 0 is off
    neutral_gate = 12,  -- chroma below this fades to grey; 0 is off
}
-- Bump when the pipeline changes shape, to invalidate every cached cover.
local ENHANCE_VERSION = 2
local SHARPEN_RADIUS = 2

--- Separable box blur over an 8-bit plane. Only ever feeds the unsharp mask, so
-- a box kernel is enough -- a gaussian would cost more for no visible gain.
local function boxBlur(src, dst, w, h, r)
    local tmp = ffi.new("uint8_t[?]", w * h)
    for y = 0, h - 1 do
        local row = y * w
        local sum = 0
        for x = 0, math.min(r, w - 1) do sum = sum + src[row + x] end
        for x = 0, w - 1 do
            local lo, hi = math.max(x - r, 0), math.min(x + r, w - 1)
            tmp[row + x] = sum / (hi - lo + 1)
            if x + r + 1 <= w - 1 then sum = sum + src[row + x + r + 1] end
            if x - r >= 0 then sum = sum - src[row + x - r] end
        end
    end
    for x = 0, w - 1 do
        local sum = 0
        for y = 0, math.min(r, h - 1) do sum = sum + tmp[y * w + x] end
        for y = 0, h - 1 do
            local lo, hi = math.max(y - r, 0), math.min(y + r, h - 1)
            dst[y * w + x] = sum / (hi - lo + 1)
            if y + r + 1 <= h - 1 then sum = sum + tmp[(y + r + 1) * w + x] end
            if y - r >= 0 then sum = sum - tmp[(y - r) * w + x] end
        end
    end
end

--- Applies the tone curve, unsharp mask, chroma smoothing and saturation boost
-- to `bb` in place. `bb` must be TYPE_BBRGB32.
local function enhanceCover(bb, p)
    local w, h = bb:getWidth(), bb:getHeight()
    if w < 3 or h < 3 then return end
    local n = w * h

    -- Luminance stays at full resolution; the RGB copy is what gets blurred, and
    -- chroma is read back out of it. Blurring RGB rather than chroma directly
    -- costs one plane less and gives the same offsets once its own luma is
    -- subtracted back off.
    local luma = ffi.new("uint8_t[?]", n)
    local cr = ffi.new("uint8_t[?]", n)
    local cg = ffi.new("uint8_t[?]", n)
    local cb = ffi.new("uint8_t[?]", n)
    for y = 0, h - 1 do
        local row = y * w
        for x = 0, w - 1 do
            local i = row + x
            local px = bb:getPixelP(x, y)
            local r, g, b = px.r, px.g, px.b
            luma[i] = luminance(r, g, b)
            cr[i], cg[i], cb[i] = r, g, b
        end
    end

    -- boxBlur reads its input fully into a scratch plane before writing, so the
    -- destination may alias the source.
    if p.chroma_blur > 0 then
        boxBlur(cr, cr, w, h, p.chroma_blur)
        boxBlur(cg, cg, w, h, p.chroma_blur)
        boxBlur(cb, cb, w, h, p.chroma_blur)
    end

    local blur
    if p.sharpness ~= 0 then
        blur = ffi.new("uint8_t[?]", n)
        boxBlur(luma, blur, w, h, SHARPEN_RADIUS)
    end

    -- gamma, then a blend toward a smoothstep S-curve, resolved once into a LUT
    local curve = ffi.new("uint8_t[?]", 256)
    for i = 0, 255 do
        local v = i / 255
        if p.brightness ~= 1 then v = v ^ (1 / p.brightness) end
        if p.contrast ~= 0 then
            v = v + (v * v * (3 - 2 * v) - v) * p.contrast
        end
        curve[i] = clamp8(v * 255 + 0.5)
    end

    local gate = p.neutral_gate
    for y = 0, h - 1 do
        local row = y * w
        for x = 0, w - 1 do
            local i = row + x
            local px = bb:getPixelP(x, y)

            local l = luma[i]
            local sharp = l
            if blur then
                sharp = clamp8(l + (l - blur[i]) * p.sharpness)
            end
            local l2 = curve[sharp]

            -- chroma offsets, taken around the blurred copy's own luminance
            local sr, sg, sb = cr[i], cg[i], cb[i]
            local sl = 0.299 * sr + 0.587 * sg + 0.114 * sb
            local dr, dg, db = sr - sl, sg - sl, sb - sl

            -- Saturation, faded out across the gate so near-neutral pixels land
            -- on true grey instead of being amplified into dither speckle.
            -- Smoothstep, not a hard cut: a threshold would band a gradient at
            -- whatever contour crosses it.
            local gain = p.saturation
            if gate > 0 then
                local hi = dr > dg and dr or dg; if db > hi then hi = db end
                local lo = dr < dg and dr or dg; if db < lo then lo = db end
                local c = hi - lo
                if c < gate then
                    local t = c / gate
                    gain = gain * t * t * (3 - 2 * t)
                end
            end

            px.r = clamp8(l2 + dr * gain)
            px.g = clamp8(l2 + dg * gain)
            px.b = clamp8(l2 + db * gain)
        end
    end
end

---------------------------------------------------------------------------
-- output quantization
---------------------------------------------------------------------------

-- Kaleido 3 renders 16 grey levels and 4096 colours -- 16^3, so 16 levels per
-- channel, landing on multiples of 17.
--
-- The point is not to reduce the image for its own sake. Every file format
-- produced the same result on the panel, which means the system is transforming
-- the decoded bitmap rather than reacting to the file, and one thing that
-- transform plausibly does is quantize to the panel's palette. An image already
-- sitting on that palette gives its quantizer nothing to change: every value
-- maps to itself, so the step becomes a no-op. Same reasoning as matching the
-- panel resolution exactly to avoid being rescaled.
local KALEIDO_LEVELS = 16

-- Ordered dither, so quantizing a gradient does not band it. Bayer rather than
-- error diffusion deliberately: it is positionally fixed, so quantizing an
-- already-quantized image leaves it alone. Error diffusion would keep finding
-- new residuals to push around.
local BAYER8 = {
     0, 32,  8, 40,  2, 34, 10, 42,
    48, 16, 56, 24, 50, 18, 58, 26,
    12, 44,  4, 36, 14, 46,  6, 38,
    60, 28, 52, 20, 62, 30, 54, 22,
     3, 35, 11, 43,  1, 33,  9, 41,
    51, 19, 59, 27, 49, 17, 57, 25,
    15, 47,  7, 39, 13, 45,  5, 37,
    63, 31, 55, 23, 61, 29, 53, 21,
}

--- Flattens `bb` to grey in place. `bb` must be RGB32.
--
-- Worth having on its own: the Kaleido colour layer is the part that gets
-- reprocessed, and the power-off screensaver slot is documented as monochrome
-- anyway. Dropping chroma before the system sees it removes everything its
-- colour handling could act on, and paired with 16-level quantization the result
-- lands exactly on the greys the monochrome layer renders.
local function toGreyscale(bb)
    local w, h = bb:getWidth(), bb:getHeight()
    for y = 0, h - 1 do
        for x = 0, w - 1 do
            local px = bb:getPixelP(x, y)
            local v = clamp8(luminance(px.r, px.g, px.b) + 0.5)
            px.r, px.g, px.b = v, v, v
        end
    end
end

--- Quantizes `bb` in place to `levels` values per channel. `bb` must be RGB32.
local function quantizeToPalette(bb, levels, dither)
    local w, h = bb:getWidth(), bb:getHeight()
    if levels < 2 then return end
    local step = 255 / (levels - 1)
    local top = levels - 1

    -- Exact output values, so the result really does sit on the palette rather
    -- than near it -- the whole point is that requantizing changes nothing.
    local out = {}
    for i = 0, top do out[i] = math.floor(i * step + 0.5) end

    for y = 0, h - 1 do
        local brow = (y % 8) * 8
        for x = 0, w - 1 do
            local px = bb:getPixelP(x, y)
            -- centred on zero, scaled to one quantization step
            local bias = dither and ((BAYER8[brow + (x % 8) + 1] / 64) - 0.5) * step or 0
            local r = (px.r + bias) / step + 0.5
            local g = (px.g + bias) / step + 0.5
            local b = (px.b + bias) / step + 0.5
            r = r < 0 and 0 or (r > top and top or math.floor(r))
            g = g < 0 and 0 or (g > top and top or math.floor(g))
            b = b < 0 and 0 or (b > top and top or math.floor(b))
            px.r, px.g, px.b = out[r], out[g], out[b]
        end
    end
end

---------------------------------------------------------------------------
-- test pattern
---------------------------------------------------------------------------

-- Known input, so the system's transform can be read off the panel instead of
-- guessed at. Photograph the sleep screen and compare against the same file in
-- Preview; what differs identifies what is being done:
--
--   grey steps shift or crush ......... a tone curve
--   colour patches shift hue .......... a colour matrix, or a saturation change
--   smooth ramps gain contours ........ quantization, and at which level
--   the near-neutral band speckles .... chroma dithering
--   band edges soften ................. the image is being rescaled
local function paintTestPattern(bb, w, h)
    local function rect(x, y, rw, rh, r, g, b)
        if rw > 0 and rh > 0 then
            bb:paintRectRGB32(math.floor(x), math.floor(y), math.floor(rw), math.floor(rh),
                Blitbuffer.ColorRGB32(r, g, b, 0xFF))
        end
    end

    -- Nine bands down the screen. Every value below is exact and known, so any
    -- deviation on the panel is the system's doing.
    local bands = 9
    local bh = h / bands
    local y = 0

    -- 1: continuous grey ramp -- contouring here means quantization
    for x = 0, w - 1 do
        local v = math.floor(255 * x / (w - 1) + 0.5)
        rect(x, y, 1, bh, v, v, v)
    end
    y = y + bh

    -- 2: the 16 grey levels Kaleido 3 actually renders. These should survive
    -- untouched; if they shift, a tone curve is being applied.
    for i = 0, 15 do
        local v = i * 17
        rect(i * w / 16, y, w / 16 + 1, bh, v, v, v)
    end
    y = y + bh

    -- 3-5: continuous R, G, B ramps
    for _, ch in ipairs({ "r", "g", "b" }) do
        for x = 0, w - 1 do
            local v = math.floor(255 * x / (w - 1) + 0.5)
            rect(x, y, 1, bh,
                ch == "r" and v or 0, ch == "g" and v or 0, ch == "b" and v or 0)
        end
        y = y + bh
    end

    -- 6: primaries and secondaries at full strength
    local swatches = {
        { 255, 0, 0 }, { 0, 255, 0 }, { 0, 0, 255 },
        { 0, 255, 255 }, { 255, 0, 255 }, { 255, 255, 0 },
        { 255, 255, 255 }, { 0, 0, 0 },
    }
    for i, c in ipairs(swatches) do
        rect((i - 1) * w / #swatches, y, w / #swatches + 1, bh, c[1], c[2], c[3])
    end
    y = y + bh

    -- 7: the same hues at half strength -- saturation changes show up here
    -- far more clearly than at full strength, which tends to clip either way
    for i, c in ipairs(swatches) do
        rect((i - 1) * w / #swatches, y, w / #swatches + 1, bh,
            math.floor(c[1] * 0.5), math.floor(c[2] * 0.5), math.floor(c[3] * 0.5))
    end
    y = y + bh

    -- 8: near-neutral gradient, the case that speckles. Chroma stays within
    -- +/-6 of grey, which is where the panel's dithering is most visible.
    for x = 0, w - 1 do
        local t = x / (w - 1)
        local v = math.floor(60 + 120 * t + 0.5)
        rect(x, y, 1, bh, v + 6, v, v - 6)
    end
    y = y + bh

    -- 9: mid-grey with single-level steps around it, to reveal the finest
    -- distinction the panel still resolves after whatever it does
    for i = 0, 15 do
        local v = 128 + (i - 8) * 2
        rect(i * w / 16, y, w / 16 + 1, h - y, v, v, v)
    end
end

--- Opaque copy, for the encoders that key off the channel count. Does not free
-- the input -- the caller still owns it.
local function toRGB24(bb)
    local w, h = bb:getWidth(), bb:getHeight()
    local out = Blitbuffer.new(w, h, Blitbuffer.TYPE_BBRGB24)
    out:blitFrom(bb, 0, 0, 0, 0, w, h)
    return out
end

--- getPixelP only yields a writable ColorRGB32* on an RGB32 buffer, and the
-- decoded cover may be any type. Frees the input when it converts.
local function toRGB32(bb)
    if bb:getType() == Blitbuffer.TYPE_BBRGB32 then return bb end
    local w, h = bb:getWidth(), bb:getHeight()
    local out = Blitbuffer.new(w, h, Blitbuffer.TYPE_BBRGB32)
    out:blitFrom(bb, 0, 0, 0, 0, w, h)
    bb:free()
    return out
end

---------------------------------------------------------------------------
-- progress bar
---------------------------------------------------------------------------

-- ProgressWidget paints exclusively through bb:paintRect, which collapses any
-- colour to 8-bit grayscale, so its track would render flat grey over the
-- coloured panel. This paints through paintRectRGB32 instead.
local ProgressBar = Widget:extend{
    width = 0,
    height = 0,
    percentage = 0,
    fill_color = nil,
    track_color = nil,
    marks = nil,       -- chapter starts, as fractions of the book
    mark_color = nil,  -- painted in the panel colour, so a mark reads as a gap
    mark_width = 2,
}

function ProgressBar:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

function ProgressBar:paintTo(bb, x, y)
    bb:paintRectRGB32(x, y, self.width, self.height, self.track_color)
    local filled = math.floor(self.width * self.percentage + 0.5)
    if filled > 0 then
        bb:paintRectRGB32(x, y, math.min(filled, self.width), self.height, self.fill_color)
    end
    if not self.marks then return end
    -- Notched into the bottom edge rather than cut full height: a typical book
    -- has more chapters than the bar is tall in pixels, so full-height cuts turn
    -- the whole bar into a dashed line. Leaving the top intact keeps it reading
    -- as one bar with chapter divisions along its foot.
    local notch = math.max(2, math.floor(self.height * 0.4 + 0.5))
    for _, frac in ipairs(self.marks) do
        local mx = math.floor(self.width * frac + 0.5)
        -- keep the mark inside the bar, and skip one sitting on the very edge
        if mx > 0 and mx < self.width then
            if mx + self.mark_width > self.width then mx = self.width - self.mark_width end
            bb:paintRectRGB32(x + mx, y + self.height - notch,
                self.mark_width, notch, self.mark_color)
        end
    end
end

---------------------------------------------------------------------------
-- battery icon
---------------------------------------------------------------------------

-- Drawn rather than typeset: KOReader's own footer has no battery glyph, the
-- bundled Noto faces cannot be relied on for one, and text is greyscale-only
-- here anyway. Drawing it also lets the fill track the actual charge.
local BatteryIcon = Widget:extend{
    height = 0,
    level = 0, -- 0..1
    color = nil,
    stroke = 2,
}

function BatteryIcon:bodyWidth()
    return math.floor(self.height * 1.9 + 0.5)
end

function BatteryIcon:getSize()
    -- body plus the terminal nub on the right
    return Geom:new{ w = self:bodyWidth() + math.max(2, math.floor(self.height * 0.16 + 0.5)),
                     h = self.height }
end

function BatteryIcon:paintTo(bb, x, y)
    local w, h, s = self:bodyWidth(), self.height, self.stroke
    -- shell
    bb:paintRectRGB32(x, y, w, s, self.color)
    bb:paintRectRGB32(x, y + h - s, w, s, self.color)
    bb:paintRectRGB32(x, y, s, h, self.color)
    bb:paintRectRGB32(x + w - s, y, s, h, self.color)
    -- terminal
    local nub_w = math.max(2, math.floor(h * 0.16 + 0.5))
    local nub_h = math.max(2, math.floor(h * 0.42 + 0.5))
    bb:paintRectRGB32(x + w, y + math.floor((h - nub_h) / 2), nub_w, nub_h, self.color)
    -- charge, inset by one stroke plus a hairline of breathing room
    local pad = s + 1
    local inner_w = w - 2 * pad
    local fill = math.floor(inner_w * math.max(0, math.min(1, self.level)) + 0.5)
    if fill > 0 then
        bb:paintRectRGB32(x + pad, y + pad, fill, h - 2 * pad, self.color)
    end
end

---------------------------------------------------------------------------
-- preview
---------------------------------------------------------------------------

-- ImageViewer only closes on a tap that lands outside its frame, and in
-- fullscreen there is no outside -- a tap there toggles the button bar instead.
-- The preview is a look, not a workspace, so any tap closes it.
local PreviewViewer = ImageViewer:extend{}

function PreviewViewer:onTap()
    self:onClose()
    return true
end

---------------------------------------------------------------------------
-- plugin
---------------------------------------------------------------------------

local PalmaSleepScreen = WidgetContainer:extend{
    name = "palmasleepscreen",
    is_doc_only = true,
}

-- Output encodings. Added to test whether the Boox screensaver's re-render
-- depended on the file -- in particular whether the alpha channel in KOReader's
-- 4-channel PNG triggered a compositing path an opaque image would skip. It does
-- not: the device accepts all of these and renders them identically, so the
-- transform acts on the decoded bitmap. Kept switchable anyway, since the null
-- result is what rules the file out.
local FORMATS = {
    { id = "png",   ext = "png", label = _("PNG, with alpha (default)") },
    { id = "png24", ext = "png", label = _("PNG, no alpha") },
    { id = "jpg",   ext = "jpg", label = _("JPEG") },
    -- BMP is deliberately absent. Writing one is fine; it is Preview that
    -- crashes KOReader on it, because ImageViewer cannot decode BMP. Dropped
    -- rather than guarded: the format turned out not to affect what the panel
    -- shows, so it would be a preview hazard for no benefit.
}

local function isKnownFormat(id)
    for _, f in ipairs(FORMATS) do
        if f.id == id then return true end
    end
    return false
end

local function formatExt(id)
    for _, f in ipairs(FORMATS) do
        if f.id == id then return f.ext end
    end
    return "png"
end

--- Forces the path's extension to match the encoding. Applied on both read and
-- write, which also repairs a path saved under a different format.
local function normalizeOutputPath(path, format)
    if not path or path == "" then return path end
    local dir, name = util.splitFilePathName(path)
    if name == "" then return path end
    return dir .. (name:gsub("%.[^%.]*$", "")) .. "." .. formatExt(format)
end

local function defaultOutputPath()
    if Device.isAndroid() then
        local ok, android = pcall(require, "android")
        if ok and android then
            return android.getExternalStoragePath() .. "/palma_sleepscreen.png"
        end
    end
    return DataStorage:getDataDir() .. "/palma_sleepscreen.png"
end

function PalmaSleepScreen:init()
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/palmasleepscreen.lua")

    self.enabled = self.settings:nilOrTrue("enabled")
    self.format = self.settings:readSetting("format") or "png"
    -- A format that has since been withdrawn (BMP) would otherwise leave an
    -- existing install pinned to it with no way back.
    if not isKnownFormat(self.format) then
        self.format = "png"
        self.settings:saveSetting("format", self.format)
    end
    self.jpeg_quality = self.settings:readSetting("jpeg_quality") or 90
    self.greyscale = self.settings:isTrue("greyscale")
    self.quantize = self.settings:readSetting("quantize") or 0
    self.dither = self.settings:nilOrTrue("dither")
    self.test_pattern = self.settings:isTrue("test_pattern")
    self.output_path = normalizeOutputPath(self.settings:readSetting("output_path"), self.format)
        or normalizeOutputPath(defaultOutputPath(), self.format)
    -- Default is per-chapter, not per-page: a full-screen PNG of photographic
    -- cover art costs ~170 ms to encode here and several times that on device,
    -- which is too much to spend on every page turn.
    self.trigger = self.settings:readSetting("trigger") or "chapter"
    self.interval = self.settings:readSetting("interval") or 10
    self.text_scale = self.settings:readSetting("text_scale") or 1.0
    self.compact_meta = self.settings:isTrue("compact_meta")
    self.enhance = self.settings:isTrue("enhance")
    self.enhance_params = {}
    for key, default in pairs(ENHANCE_DEFAULTS) do
        self.enhance_params[key] = self.settings:readSetting("enhance_" .. key) or default
    end
    self.render_on_suspend = self.settings:isTrue("render_on_suspend")
    self.debug = self.settings:isTrue("debug")

    self.render_pending = false
    self.pages_since_render = 0
    self.last_chapter_idx = nil
    self.prepared = nil

    -- stable reference so it can be unscheduled
    self.deferred_render = function()
        self.render_pending = false
        self:render()
    end

    self.ui.menu:registerToMainMenu(self)
end

function PalmaSleepScreen:onCloseWidget()
    UIManager:unschedule(self.deferred_render)
    self:releasePrepared()
end

function PalmaSleepScreen:saveSetting(key, value)
    self[key] = value
    self.settings:saveSetting(key, value)
    self.settings:flush()
end

---------------------------------------------------------------------------
-- output path
---------------------------------------------------------------------------

--- Returns true, or false plus a human-readable reason.
-- Android declares MANAGE_EXTERNAL_STORAGE, but it is a runtime grant the user
-- may not have given, so probe with a real write rather than trusting the path.
function PalmaSleepScreen:checkOutputPath(path)
    if not path or path == "" then
        return false, _("No output path is set.")
    end
    local dir, name = util.splitFilePathName(path)
    if name == "" then
        return false, _("The output path has no filename.")
    end
    if lfs.attributes(dir, "mode") ~= "directory" then
        return false, T(_("The folder does not exist:\n%1"), dir)
    end
    local probe = path .. ".probe"
    local fh = io.open(probe, "wb")
    if not fh then
        local reason = _("The folder is not writable:\n%1")
        if Device.isAndroid() then
            reason = _("The folder is not writable:\n%1\n\nOn Android, grant KOReader \"All files access\" in the system app settings.")
        end
        return false, T(reason, dir)
    end
    fh:write("x")
    fh:close()
    os.remove(probe)
    return true
end

---------------------------------------------------------------------------
-- layout
---------------------------------------------------------------------------

function PalmaSleepScreen:metrics()
    local screen_w = Screen:getWidth()
    local unit = screen_w / REF_WIDTH
    -- Font:getFace() runs its size through Screen:scaleBySize(), so divide it
    -- back out to land on the pixel sizes the layout is specified in
    local face_scale = Screen:scaleBySize(1000) / 1000

    local m = {
        screen_w = screen_w,
        screen_h = Screen:getHeight(),
        unit = unit,
        face_scale = face_scale,
    }
    for key, px in pairs(REF) do
        m[key] = math.floor(px * unit + 0.5)
    end
    -- text scale applies to the type, not to the margins
    for _i, key in ipairs({ "title", "author", "footer", "meta" }) do
        m[key] = math.floor(REF[key] * unit * self.text_scale + 0.5)
    end
    return m
end

function PalmaSleepScreen:face(name, px, m)
    return Font:getFace(name, math.max(8, math.floor(px / m.face_scale + 0.5)))
end

function PalmaSleepScreen:bookData()
    local props = self.ui.doc_props or {}
    local data = {
        title = props.display_title or props.title,
        author = props.authors,
        series = props.series,
        series_index = props.series_index,
    }

    local page = self.ui.view and self.ui.view.state and self.ui.view.state.page
    local total = self.ui.document and self.ui.document:getPageCount() or 0
    if page and total > 0 then
        data.percentage = math.max(0, math.min(1, page / total))
    else
        data.percentage = 0
    end

    if page and self.ui.toc then
        local chapter = self.ui.toc:getTocTitleByPage(page)
        if chapter and chapter ~= "" then
            data.chapter = chapter
        end
        -- Chapter N of M, counted off the flattened ticks so that the index and
        -- the total come from the same list (the raw ToC index counts sub-levels
        -- and would not agree with the number of chapters).
        local ok, ticks = pcall(function() return self.ui.toc:getTocTicksFlattened() end)
        if ok and ticks and #ticks > 0 then
            local n = 0
            for _, tick in ipairs(ticks) do
                if tick <= page then n = n + 1 else break end
            end
            data.chapter_num = math.max(1, n)
            data.chapter_total = #ticks
            if total > 0 then
                local marks = {}
                for _, tick in ipairs(ticks) do
                    if tick > 1 and tick <= total then
                        table.insert(marks, tick / total)
                    end
                end
                if #marks > 0 then data.chapter_marks = marks end
            end
        end
    end

    -- Time left to finish the book. Comes from the statistics plugin's running
    -- average, so it is absent when statistics are disabled -- in which case the
    -- field is simply hidden.
    if page and self.ui.statistics and self.ui.document then
        local ok, left = pcall(function()
            return self.ui.statistics:getTimeForPages(self.ui.document:getTotalPagesLeft(page))
        end)
        if ok and left and left ~= "" then
            data.time_left = left
        end
    end

    local ok_bat, capacity = pcall(function()
        return Device:getPowerDevice():getCapacity()
    end)
    if ok_bat and capacity and capacity > 0 then
        data.battery = capacity
    end
    data.stamp = os.date("%d %b %H:%M")

    return data
end

--- Author and series on one line; either half may be missing.
local function bylineText(data)
    local series = data.series
    if series and data.series_index then
        series = string.format("%s #%s", series, tostring(data.series_index))
    end
    if data.author and series then
        return data.author .. "  ·  " .. series
    end
    return data.author or series
end

--- Builds the panel contents as a VerticalGroup of the given width. The caller
-- must :free() the result. `data` may be nil for the measuring pass.
function PalmaSleepScreen:buildPanel(width, m, fg, panel_color, data)
    local group = VerticalGroup:new{ align = "left" }

    -- Title, up to two lines then ellipsized. Unlike TextWidget, TextBoxWidget
    -- renders into its own buffer and blits it opaquely, so it needs the panel
    -- colour as bgcolor or it paints a solid block over the panel.
    local bg = toColorRGB32(panel_color)
    local title_text = data.title or _("Unknown title")
    local title_face = self:face("tfont", m.title, m)
    local title = TextBoxWidget:new{
        text = title_text,
        face = title_face,
        width = width,
        alignment = "left",
        fgcolor = fg,
        bgcolor = bg,
    }
    local max_h = 2 * title.line_height_px
    if title:getSize().h > max_h then
        title:free()
        title = TextBoxWidget:new{
            text = title_text,
            face = title_face,
            width = width,
            height = max_h,
            height_overflow_show_ellipsis = true,
            alignment = "left",
            fgcolor = fg,
            bgcolor = bg,
        }
    end
    table.insert(group, title)

    local byline = bylineText(data)
    if byline then
        table.insert(group, VerticalSpan:new{ width = m.gap_title })
        table.insert(group, TextWidget:new{
            text = byline,
            face = self:face("cfont", m.author, m),
            max_width = width,
            fgcolor = fg,
        })
    end

    table.insert(group, VerticalSpan:new{ width = m.gap_author })
    table.insert(group, ProgressBar:new{
        width = width,
        height = m.bar,
        percentage = data.percentage,
        fill_color = fg,
        track_color = toColorRGB32(mix(panel_color, { r = fg.a, g = fg.a, b = fg.a }, 0.42)),
        marks = data.chapter_marks,
        mark_color = toColorRGB32(panel_color),
        mark_width = m.tick,
    })

    table.insert(group, VerticalSpan:new{ width = m.gap_bar })

    -- A row with one item pinned left and one pinned right. Both sides take
    -- either a string or a ready-made widget; a string on the right is truncated
    -- to whatever space is left.
    local function splitRow(left_item, right_item, face)
        local left = type(left_item) == "string"
            and TextWidget:new{ text = left_item, face = face, fgcolor = fg } or left_item
        local row = HorizontalGroup:new{ align = "center", left }
        if right_item then
            local left_w = left:getSize().w
            local right = type(right_item) == "string"
                and TextWidget:new{
                    text = right_item,
                    face = face,
                    max_width = math.max(0, width - left_w - m.gap_footer),
                    fgcolor = fg,
                } or right_item
            local spacer = width - left_w - right:getSize().w
            if spacer < m.gap_footer then spacer = m.gap_footer end
            table.insert(row, HorizontalSpan:new{ width = spacer })
            table.insert(row, right)
        end
        return row
    end

    -- Primary footer: percentage left, chapter name right. The chapter name gets
    -- the whole remaining width -- it is the most useful thing here, and putting
    -- anything else on this row truncates it hard.
    local chapter_label = data.chapter
    if data.chapter_num and data.chapter_total then
        chapter_label = T(_("Chapter %1 / %2"), data.chapter_num, data.chapter_total)
    end
    local progress_label = string.format("%d%%", math.floor(data.percentage * 100 + 0.5))
    -- In compact mode the secondary line goes away entirely, so time left rides
    -- along with the percentage instead of being dropped with it.
    if self.compact_meta and data.time_left then
        progress_label = T(_("%1  ·  %2 left"), progress_label, data.time_left)
    end
    table.insert(group, splitRow(progress_label, chapter_label, self:face("cfont", m.footer, m)))

    -- Compact mode drops battery and timestamp so the Boox system status bar,
    -- which is drawn over the sleep screen, is not duplicating them.
    if self.compact_meta then
        return group
    end

    -- Secondary line: time left and chapter count on the left, battery and
    -- timestamp on the right. Deliberately smaller and last so it stays out of
    -- the way of what is actually being read.
    -- It cannot be dimmed instead: TextWidget collapses any fgcolor to greyscale
    -- (colorblitFrom -> getColor8A), so a tint would render as flat grey on the
    -- coloured panel. Size and position carry the hierarchy instead.
    local meta_face = self:face("cfont", m.meta, m)
    local meta_left = {}
    if data.time_left then
        table.insert(meta_left, T(_("%1 left"), data.time_left))
    end

    -- Right side is a group so the drawn battery icon can sit inline with the
    -- text; everything after it is plain text again.
    local meta_right, has_right = HorizontalGroup:new{ align = "center" }, false
    if data.battery then
        table.insert(meta_right, BatteryIcon:new{
            height = math.max(8, math.floor(m.meta * 0.62 + 0.5)),
            level = data.battery / 100,
            color = toColorRGB32({ r = fg.a, g = fg.a, b = fg.a }),
            stroke = math.max(1, math.floor(m.meta * 0.075 + 0.5)),
        })
        table.insert(meta_right, HorizontalSpan:new{ width = math.floor(m.meta * 0.30 + 0.5) })
        table.insert(meta_right, TextWidget:new{
            text = string.format("%d%%", data.battery), face = meta_face, fgcolor = fg,
        })
        has_right = true
    end
    if data.stamp then
        if has_right then
            table.insert(meta_right, TextWidget:new{
                text = "  ·  ", face = meta_face, fgcolor = fg,
            })
        end
        table.insert(meta_right, TextWidget:new{
            text = data.stamp, face = meta_face, fgcolor = fg,
        })
        has_right = true
    end

    if #meta_left > 0 or has_right then
        table.insert(group, VerticalSpan:new{ width = m.gap_meta })
        table.insert(group, splitRow(table.concat(meta_left, "  ·  "),
            has_right and meta_right or nil, meta_face))
    end

    return group
end

---------------------------------------------------------------------------
-- cover cache
---------------------------------------------------------------------------

-- Enhancement is a few passes over every pixel of a full-screen cover, so the
-- result is kept on disk and reused until the book, the geometry or one of the
-- parameters changes -- all of which are folded into the cache key.

local function coverCacheDir()
    return DataStorage:getDataDir() .. "/cache/palmasleepscreen"
end

function PalmaSleepScreen:coverCachePath(cover_w, cover_h)
    local file = self.ui.document and self.ui.document.file
    if not file then return nil end
    local p = self.enhance_params
    local key = string.format("%s|%s|%s|%dx%d|%d|%s|%s|%s|%s",
        file,
        tostring(lfs.attributes(file, "modification")),
        tostring(lfs.attributes(file, "size")),
        cover_w, cover_h, ENHANCE_VERSION,
        tostring(p.saturation), tostring(p.brightness),
        tostring(p.contrast), tostring(p.sharpness))
    return coverCacheDir() .. "/" .. md5(key) .. ".png"
end

--- Removes every cached cover. Called whenever a parameter changes: the key
-- changes with it, so the existing files are unreachable rather than merely stale.
function PalmaSleepScreen:clearCoverCache()
    local dir = coverCacheDir()
    if lfs.attributes(dir, "mode") ~= "directory" then return end
    for name in lfs.dir(dir) do
        if name:match("%.png$") then os.remove(dir .. "/" .. name) end
    end
end

function PalmaSleepScreen:loadCachedCover(path, cover_w, cover_h)
    if not path or lfs.attributes(path, "mode") ~= "file" then return nil end
    local ok, bb = pcall(function() return RenderImage:renderImageFile(path) end)
    if not ok or not bb then return nil end
    -- A mismatch means the file is not what the key promised; discard it.
    if bb:getWidth() ~= cover_w or bb:getHeight() ~= cover_h then
        bb:free()
        os.remove(path)
        return nil
    end
    return bb
end

function PalmaSleepScreen:saveCachedCover(bb, path)
    if not path then return end
    local dir = coverCacheDir()
    if lfs.attributes(dir, "mode") ~= "directory" then
        lfs.mkdir(DataStorage:getDataDir() .. "/cache")
        if not lfs.mkdir(dir) and lfs.attributes(dir, "mode") ~= "directory" then
            logger.warn("PalmaSleepScreen: could not create", dir)
            return
        end
    end
    -- Write and rename, so a cover interrupted mid-write is never read back.
    local tmp = path .. ".tmp"
    if bb:writeToFile(tmp, "png") and (lfs.attributes(tmp, "size") or 0) > 0 then
        os.rename(tmp, path)
    else
        os.remove(tmp)
    end
end

---------------------------------------------------------------------------
-- preparation (cached per book)
---------------------------------------------------------------------------

function PalmaSleepScreen:releasePrepared()
    if self.prepared and self.prepared.cover_bb then
        self.prepared.cover_bb:free()
    end
    self.prepared = nil
end

--- Decodes the cover, samples its dominant colour, and works out the cover
-- geometry. All of this is invariant for a given book and text scale, so it is
-- cached; only the panel contents are rebuilt per render.
function PalmaSleepScreen:prepare(m, data)
    local key = string.format("%s|%s|%s|%dx%d", tostring(self.ui.document and self.ui.document.file),
        tostring(self.text_scale), tostring(self.compact_meta), m.screen_w, m.screen_h)
    if self.prepared and self.prepared.key == key then
        return self.prepared
    end
    self:releasePrepared()

    local cover_bb
    if self.ui.bookinfo and self.ui.document then
        cover_bb = self.ui.bookinfo:getCoverImage(self.ui.document)
    end

    local panel_color = cover_bb and dominantColour(cover_bb) or nil
    if not panel_color then
        panel_color = MONO_FALLBACK
    end

    local fg
    panel_color, fg = ensureContrast(panel_color)

    -- measure the panel at this text scale to get the minimum viable height
    local panel_w = m.screen_w - 2 * m.margin
    local probe = self:buildPanel(panel_w, m, fg, panel_color, data)
    local min_panel = probe:getSize().h + 2 * m.margin
    probe:free()

    local prepared = {
        key = key,
        panel_color = panel_color,
        panel_color_rgb = toColorRGB32(panel_color),
        fg = fg,
        min_panel = min_panel,
        panel_w = panel_w,
    }

    if cover_bb then
        local iw, ih = cover_bb:getWidth(), cover_bb:getHeight()
        local max_cover_h = m.screen_h - min_panel
        if iw > 0 and ih > 0 and max_cover_h > 0 then
            local cover_w = m.screen_w
            local cover_h = math.floor(ih * (cover_w / iw) + 0.5)
            if cover_h > max_cover_h then
                -- Tall cover: scale it down until the panel reaches min_panel and
                -- centre it horizontally. This is the one case where the cover is
                -- not full width, and it beats cropping.
                cover_h = max_cover_h
                cover_w = math.floor(iw * (cover_h / ih) + 0.5)
            end
            local cache_path = self.enhance and self:coverCachePath(cover_w, cover_h) or nil
            local scaled = cache_path and self:loadCachedCover(cache_path, cover_w, cover_h) or nil
            if scaled then
                cover_bb:free()
            else
                scaled = RenderImage:scaleBlitBuffer(cover_bb, cover_w, cover_h, true)
                if self.enhance then
                    scaled = toRGB32(scaled)
                    local t = time.now()
                    enhanceCover(scaled, self.enhance_params)
                    if self.debug then
                        logger.info(string.format("PalmaSleepScreen: cover enhancement took %.1f ms",
                            time.to_ms(time.since(t))))
                    end
                    self:saveCachedCover(scaled, cache_path)
                end
            end
            prepared.cover_bb = scaled
            prepared.cover_w = cover_w
            prepared.cover_h = cover_h
            prepared.cover_x = math.floor((m.screen_w - cover_w) / 2)
        else
            cover_bb:free()
        end
    end

    self.prepared = prepared
    return prepared
end

---------------------------------------------------------------------------
-- render
---------------------------------------------------------------------------

--- Renders, returning ok plus a reason on failure.
-- `interactive` reports the outcome in the UI either way; automatic renders
-- report only the first failure, so a bad path can't fail silently forever but
-- also can't nag on every page turn.
function PalmaSleepScreen:render(interactive)
    if not self.enabled or not self.ui or not self.ui.document then
        if interactive then
            UIManager:show(InfoMessage:new{
                text = not self.enabled and _("The sleep screen is disabled.")
                    or _("No document is open."),
                show_icon = true,
            })
        end
        return false
    end

    local start = time.now()
    local ok, err = pcall(function() self:doRender() end)
    local ms = time.to_ms(time.since(start))

    if not ok then
        logger.warn("PalmaSleepScreen: render failed:", err)
        if interactive or not self.warned_failure then
            self.warned_failure = true
            UIManager:show(InfoMessage:new{
                text = T(_("Could not write the sleep screen:\n\n%1"), tostring(err)),
                show_icon = true,
            })
        end
        return false, err
    end

    self.warned_failure = false
    if self.debug then
        logger.info(string.format("PalmaSleepScreen: render took %.1f ms", ms))
    end
    if interactive then
        local size = lfs.attributes(self.output_path, "size") or 0
        UIManager:show(InfoMessage:new{
            text = T(_("Sleep screen updated (%1 ms)\n\n%2\n%3, %4, %5 kB"),
                math.floor(ms + 0.5), self.output_path, self.last_size or "?",
                self.format, math.floor(size / 1024 + 0.5)),
            timeout = 5,
        })
    end
    return true
end

--- Composes the sleep screen and returns the buffer plus its metrics. The
-- caller owns the buffer and must :free() it.
function PalmaSleepScreen:composeImage()
    local m = self:metrics()
    local data = self:bookData()
    local p = self:prepare(m, data)

    local bb = Blitbuffer.new(m.screen_w, m.screen_h, Blitbuffer.TYPE_BBRGB32)
    bb:paintRectRGB32(0, 0, m.screen_w, m.screen_h, p.panel_color_rgb)

    local panel_top
    if p.cover_bb then
        bb:blitFrom(p.cover_bb, p.cover_x, 0, 0, 0, p.cover_w, p.cover_h)
        panel_top = p.cover_h + m.margin
    else
        -- No cover: the panel is the whole screen, contents centred.
        panel_top = nil
    end

    local panel = self:buildPanel(p.panel_w, m, p.fg, p.panel_color, data)
    if panel_top == nil then
        panel_top = math.floor((m.screen_h - panel:getSize().h) / 2)
    end
    -- Padding stays constant at the top of the panel; any extra space falls at
    -- the bottom, so the text keeps a fixed distance below the cover edge.
    panel:paintTo(bb, m.margin, panel_top)
    panel:free()

    return bb, m
end

function PalmaSleepScreen:doRender()
    local bb, m
    if self.test_pattern then
        m = self:metrics()
        bb = Blitbuffer.new(m.screen_w, m.screen_h, Blitbuffer.TYPE_BBRGB32)
        paintTestPattern(bb, m.screen_w, m.screen_h)
    else
        bb, m = self:composeImage()
    end

    -- Both run last, on the finished image: quantizing before compositing would
    -- let the text and panel land back off-palette. Grey first, so quantization
    -- lands the result on the panel's grey levels rather than near them.
    if self.greyscale then
        toGreyscale(bb)
    end
    if self.quantize > 0 then
        quantizeToPalette(bb, self.quantize, self.dither)
    end

    -- reported alongside the render, so a size that is not the panel's native
    -- resolution is visible rather than assumed -- anything else gets rescaled
    -- by the system before it ever reaches the screen
    self.last_size = string.format("%d × %d", m.screen_w, m.screen_h)

    -- never leave a partial image at the output path
    local tmp = self.output_path .. ".tmp"
    local written
    if self.format == "png24" then
        -- BBRGB32:writePNG() encodes 4 channels; going through an RGB24 buffer
        -- gets the 3-channel encoder, and an opaque file.
        local rgb24 = toRGB24(bb)
        written = rgb24:writeToFile(tmp, "png")
        rgb24:free()
    elseif self.format == "jpg" then
        written = bb:writeToFile(tmp, "jpg", self.jpeg_quality)
    else
        written = bb:writeToFile(tmp, "png")
    end
    bb:free()

    -- Blitbuffer:writePNG() discards the return value of Png.encodeToFile(), so
    -- writeToFile() reports success even when nothing reached the disk. Check
    -- the file itself rather than trusting it.
    local size = lfs.attributes(tmp, "size")
    if not written or not size or size == 0 then
        os.remove(tmp)
        local dir = util.splitFilePathName(self.output_path)
        local hint = ""
        if lfs.attributes(dir, "mode") ~= "directory" then
            hint = "\n" .. T(_("The folder does not exist: %1"), dir)
        elseif Device.isAndroid() then
            hint = "\n" .. _("On Android, grant KOReader \"All files access\" in the system app settings.")
        end
        error(T(_("could not write %1"), tmp) .. hint, 0)
    end

    local ok, rename_err = os.rename(tmp, self.output_path)
    if not ok then
        os.remove(tmp)
        error(T(_("could not rename onto %1: %2"), self.output_path, tostring(rename_err)), 0)
    end
end

--- Coalescing request: if a render is already queued, drop this one. The
-- scheduled render reads current state when it fires, so nothing is lost.
function PalmaSleepScreen:requestRender()
    if not self.enabled then return end
    if self.render_pending then return end
    self.render_pending = true
    UIManager:scheduleIn(RENDER_DELAY, self.deferred_render)
end

---------------------------------------------------------------------------
-- triggers
---------------------------------------------------------------------------

function PalmaSleepScreen:onReaderReady()
    self:releasePrepared()
    self.pages_since_render = 0
    self.last_chapter_idx = nil
    self:requestRender()
end

function PalmaSleepScreen:onPageUpdate(pageno)
    if not self.enabled then return end

    if self.trigger == "chapter" then
        local idx = self.ui.toc and self.ui.toc:getTocIndexByPage(pageno) or 0
        if idx ~= self.last_chapter_idx then
            self.last_chapter_idx = idx
            self:requestRender()
        end
    elseif self.trigger == "interval" then
        self.pages_since_render = self.pages_since_render + 1
        if self.pages_since_render >= self.interval then
            self.pages_since_render = 0
            self:requestRender()
        end
    else
        self:requestRender()
    end
end

--- Rendered inline, not scheduled: there is no time left once the device is
-- going down. Note this only ever *freshens* an already-current image — see the
-- menu help for why it cannot be relied on by itself.
function PalmaSleepScreen:renderOnSuspend()
    if not self.enabled or not self.render_on_suspend then return end
    UIManager:unschedule(self.deferred_render)
    self.render_pending = false
    self:render()
end

-- generic devices (Device:suspend), and Android's APP_CMD_PAUSE
PalmaSleepScreen.onSuspend = PalmaSleepScreen.renderOnSuspend
PalmaSleepScreen.onRequestSuspend = PalmaSleepScreen.renderOnSuspend

function PalmaSleepScreen:onCloseDocument()
    -- render inline: the document is about to go away, so a scheduled render
    -- would find nothing to read
    UIManager:unschedule(self.deferred_render)
    self.render_pending = false
    self:render()
    self:releasePrepared()
end

---------------------------------------------------------------------------
-- menu
---------------------------------------------------------------------------

function PalmaSleepScreen:chooseOutputPath(touchmenu_instance)
    local dir = util.splitFilePathName(self.output_path)
    UIManager:show(PathChooser:new{
        select_directory = true,
        select_file = false,
        height = Screen:getHeight(),
        path = dir,
        onConfirm = function(dir_path)
            local _dir, name = util.splitFilePathName(self.output_path)
            local input
            input = InputDialog:new{
                title = _("Filename"),
                input = dir_path:gsub("/$", "") .. "/"
                    .. (name ~= "" and name or ("palma_sleepscreen." .. formatExt(self.format))),
                buttons = {{
                    {
                        text = _("Cancel"),
                        id = "close",
                        callback = function() UIManager:close(input) end,
                    },
                    {
                        text = _("Save"),
                        callback = function()
                            local path = normalizeOutputPath(input:getInputText(), self.format)
                            local ok, reason = self:checkOutputPath(path)
                            if not ok then
                                UIManager:show(InfoMessage:new{ text = reason, show_icon = true })
                                return
                            end
                            UIManager:close(input)
                            self:saveSetting("output_path", path)
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                            self:requestRender()
                        end,
                    },
                }},
            }
            UIManager:show(input)
            input:onShowKeyboard()
        end,
    })
end

--- Switching encoding moves the output path with it. Reported rather than
-- applied silently: the system points at one specific file, and a format change
-- that renames it out from under that setting looks exactly like "the new format
-- made no difference".
function PalmaSleepScreen:menuEntryFormat(fmt)
    return {
        text = fmt.label,
        checked_func = function() return self.format == fmt.id end,
        radio = true,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            local old_path = self.output_path
            self:saveSetting("format", fmt.id)
            local path = normalizeOutputPath(self.output_path, fmt.id)
            if path ~= self.output_path then
                self:saveSetting("output_path", path)
            end
            if touchmenu_instance then touchmenu_instance:updateItems() end
            self:render(true)
            if path ~= old_path then
                UIManager:show(InfoMessage:new{
                    text = T(_("The output file is now:\n%1\n\nPoint the system sleep screen at it — the old file is still at:\n%2"),
                        path, old_path),
                    show_icon = true,
                })
            end
        end,
    }
end

function PalmaSleepScreen:menuEntryQuantize(levels, label)
    return {
        text = label,
        checked_func = function() return self.quantize == levels end,
        radio = true,
        keep_menu_open = true,
        callback = function()
            self:saveSetting("quantize", levels)
            self:render(true)
        end,
    }
end

function PalmaSleepScreen:menuEntryTrigger(mode, label)
    return {
        text = label,
        checked_func = function() return self.trigger == mode end,
        radio = true,
        callback = function()
            self:saveSetting("trigger", mode)
            self.pages_since_render = 0
            self.last_chapter_idx = nil
            self:requestRender()
        end,
    }
end

function PalmaSleepScreen:menuEntryTextScale(scale, label)
    return {
        text = label,
        checked_func = function() return self.text_scale == scale end,
        radio = true,
        callback = function()
            self:saveSetting("text_scale", scale)
            self:releasePrepared()
            self:requestRender()
        end,
    }
end

--- A spinner over one enhancement parameter. Any change invalidates every
-- cached cover, since the parameters are part of the cache key.
function PalmaSleepScreen:menuEntryEnhanceParam(key, label, min, max, step, precision)
    precision = precision or "%.2f"
    return {
        text_func = function()
            return T(_("%1: %2"), label, string.format(precision, self.enhance_params[key]))
        end,
        enabled_func = function() return self.enhance end,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            UIManager:show(SpinWidget:new{
                value = self.enhance_params[key],
                value_min = min,
                value_max = max,
                value_step = step,
                value_hold_step = step * 4,
                precision = "%.2f",
                default_value = ENHANCE_DEFAULTS[key],
                title_text = label,
                ok_text = _("Set"),
                callback = function(spin)
                    local value = math.floor(spin.value * 100 + 0.5) / 100
                    self.enhance_params[key] = value
                    self.settings:saveSetting("enhance_" .. key, value)
                    self.settings:flush()
                    self:clearCoverCache()
                    self:releasePrepared()
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                    self:requestRender()
                end,
            })
        end,
    }
end

function PalmaSleepScreen:addToMainMenu(menu_items)
    menu_items.palmasleepscreen = {
        sorting_hint = "screen",
        text = _("Palma sleep screen"),
        checked_func = function() return self.enabled end,
        sub_item_table = {
            {
                text = _("Enabled"),
                checked_func = function() return self.enabled end,
                callback = function()
                    self:saveSetting("enabled", not self.enabled)
                    if self.enabled then self:requestRender() end
                end,
                separator = true,
            },
            {
                text_func = function()
                    return T(_("Output file: %1"), self.output_path)
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:chooseOutputPath(touchmenu_instance)
                end,
            },
            {
                text = _("Check output path"),
                keep_menu_open = true,
                callback = function()
                    local ok, reason = self:checkOutputPath(self.output_path)
                    UIManager:show(InfoMessage:new{
                        text = ok and T(_("The output path is writable:\n%1"), self.output_path) or reason,
                        show_icon = true,
                    })
                end,
                separator = true,
            },
            {
                text = _("Update"),
                sub_item_table = {
                    self:menuEntryTrigger("page", _("Every page")),
                    self:menuEntryTrigger("chapter", _("Every chapter")),
                    self:menuEntryTrigger("interval", _("Every N pages")),
                    {
                        text = _("Also update when the device sleeps"),
                        help_text = _([[Renders once more as the device suspends.

This can only freshen an image that is already up to date. The system reads the sleep screen file as it goes to sleep, and usually gets there before the render finishes — so on its own this shows the previous image, not the current one. Leave a page or chapter trigger enabled as well.]]),
                        checked_func = function() return self.render_on_suspend end,
                        callback = function()
                            self:saveSetting("render_on_suspend", not self.render_on_suspend)
                        end,
                        separator = true,
                    },
                    {
                        text_func = function()
                            return T(_("Pages between updates: %1"), self.interval)
                        end,
                        enabled_func = function() return self.trigger == "interval" end,
                        keep_menu_open = true,
                        callback = function(touchmenu_instance)
                            UIManager:show(SpinWidget:new{
                                value = self.interval,
                                value_min = 1,
                                value_max = 50,
                                default_value = 10,
                                title_text = _("Pages between updates"),
                                ok_text = _("Set"),
                                callback = function(spin)
                                    self:saveSetting("interval", spin.value)
                                    self.pages_since_render = 0
                                    if touchmenu_instance then touchmenu_instance:updateItems() end
                                end,
                            })
                        end,
                    },
                },
            },
            {
                text = _("Text size"),
                sub_item_table = {
                    self:menuEntryTextScale(0.8, _("Small")),
                    self:menuEntryTextScale(1.0, _("Medium")),
                    self:menuEntryTextScale(1.2, _("Large")),
                },
            },
            {
                text = _("Hide battery and date"),
                help_text = _([[Drops the battery level and the timestamp, and moves the time left onto the progress line.

For use with the Boox system status bar, which draws its own clock and battery over the sleep screen.]]),
                checked_func = function() return self.compact_meta end,
                callback = function()
                    self:saveSetting("compact_meta", not self.compact_meta)
                    self:releasePrepared()
                    self:requestRender()
                end,
            },
            {
                text = _("Cover enhancement"),
                help_text = _([[Adjusts the cover for the Kaleido 3 colour layer, which resolves colour at half the resolution of the monochrome layer and absorbs enough light to leave covers looking dark and washed out.

Brightness, contrast and sharpness act on luminance only, so sharpening picks up the full resolution of the monochrome layer without colouring the edges. Saturation compensates for the colour filter.

Colour smoothing and the neutral threshold work against dither speckle: the panel dithers to reach colours it cannot render, and faint colour variation across a smooth gradient turns into magenta and green flecks. Smoothing the colour, and dropping near-grey pixels to true grey, removes what the dithering feeds on. Raise both if covers look speckled; lower them if colour looks smeared.

The result is cached, so the work is done once per book rather than on every update.]]),
                sub_item_table = {
                    {
                        text = _("Enabled"),
                        checked_func = function() return self.enhance end,
                        callback = function()
                            self:saveSetting("enhance", not self.enhance)
                            self:releasePrepared()
                            self:requestRender()
                        end,
                        separator = true,
                    },
                    self:menuEntryEnhanceParam("saturation", _("Saturation"), 1.0, 2.5, 0.05),
                    self:menuEntryEnhanceParam("brightness", _("Brightness"), 0.7, 1.5, 0.05),
                    self:menuEntryEnhanceParam("contrast", _("Contrast"), 0.0, 1.0, 0.05),
                    self:menuEntryEnhanceParam("sharpness", _("Sharpness"), 0.0, 2.0, 0.1),
                    self:menuEntryEnhanceParam("chroma_blur", _("Colour smoothing"), 0, 6, 1, "%d"),
                    self:menuEntryEnhanceParam("neutral_gate", _("Neutral threshold"), 0, 40, 2, "%d"),
                    {
                        text = _("Rebuild cached covers"),
                        keep_menu_open = true,
                        callback = function()
                            self:clearCoverCache()
                            self:releasePrepared()
                            self:requestRender()
                            UIManager:show(InfoMessage:new{
                                text = _("Cached covers cleared."),
                                timeout = 2,
                            })
                        end,
                    },
                },
                separator = true,
            },
            {
                text = _("Preview"),
                help_text = _("Renders the sleep screen and shows it full screen, exactly as written. Tap anywhere to close."),
                callback = function()
                    if not self.enabled or not self.ui or not self.ui.document then
                        UIManager:show(InfoMessage:new{
                            text = not self.enabled and _("The sleep screen is disabled.")
                                or _("No document is open."),
                            show_icon = true,
                        })
                        return
                    end
                    -- render inline so the preview is the current state, and so a
                    -- queued render cannot overwrite the file behind the viewer
                    UIManager:unschedule(self.deferred_render)
                    self.render_pending = false
                    if not self:render() then return end -- render reports its own failure
                    -- Shows the written file rather than the buffer it came from:
                    -- a preview that skipped the encode could not catch a bad write.
                    UIManager:show(PreviewViewer:new{
                        file = self.output_path,
                        fullscreen = true,
                        with_title_bar = false,
                    })
                end,
            },
            {
                text = _("Refresh now"),
                keep_menu_open = true,
                callback = function() self:render(true) end,
            },
            {
                text = _("Output format"),
                help_text = _([[The Boox screensaver does not show the file untouched — it re-renders it through its own pipeline, which is why the same image looks right in Preview and wrong once the device sleeps.

These were added to find an encoding that pipeline leaves alone. None of them is: the device accepts them all and renders them identically, which means the transform acts on the decoded image rather than the file. Greyscale and quantization are the useful levers instead.

Changing this renames the output file, so re-point the system sleep screen setting at it — otherwise the system keeps showing the old file and every format will look identical.

The device may also cache the sleep screen. If a change appears to do nothing, reboot before concluding it did not work.]]),
                sub_item_table = (function()
                    local t = {}
                    for _, fmt in ipairs(FORMATS) do
                        table.insert(t, self:menuEntryFormat(fmt))
                    end
                    t[#t].separator = true
                    table.insert(t, {
                        text_func = function()
                            return T(_("JPEG quality: %1"), self.jpeg_quality)
                        end,
                        enabled_func = function() return self.format == "jpg" end,
                        keep_menu_open = true,
                        callback = function(touchmenu_instance)
                            UIManager:show(SpinWidget:new{
                                value = self.jpeg_quality,
                                value_min = 50,
                                value_max = 100,
                                default_value = 90,
                                title_text = _("JPEG quality"),
                                ok_text = _("Set"),
                                callback = function(spin)
                                    self:saveSetting("jpeg_quality", spin.value)
                                    if touchmenu_instance then touchmenu_instance:updateItems() end
                                    self:render(true)
                                end,
                            })
                        end,
                    })
                    return t
                end)(),
            },
            {
                text = _("Greyscale output"),
                help_text = _([[Drops all colour before writing the image.

The colour layer is the part the system reprocesses, and the power-off screensaver slot is monochrome regardless. Removing chroma leaves its colour handling nothing to act on.

Paired with 16-level quantization the result lands exactly on the greys the monochrome layer renders.]]),
                checked_func = function() return self.greyscale end,
                callback = function()
                    self:saveSetting("greyscale", not self.greyscale)
                    self:render(true)
                end,
            },
            {
                text = _("Colour quantization"),
                help_text = _([[Reduces the image to a fixed number of levels per channel before writing it.

Kaleido 3 renders 16 grey levels and 4096 colours — 16³, so 16 levels per channel. The system almost certainly quantizes to that palette itself. An image already sitting on the palette gives its quantizer nothing to change, which may stop it touching the image at all.

Ordered dithering keeps gradients smooth. It is positionally fixed, so quantizing an already-quantized image leaves it alone — unlike error diffusion, which would keep finding new residuals to spread.]]),
                sub_item_table = {
                    self:menuEntryQuantize(0, _("Off")),
                    self:menuEntryQuantize(KALEIDO_LEVELS, _("16 levels (Kaleido 3)")),
                    self:menuEntryQuantize(8, _("8 levels")),
                    self:menuEntryQuantize(4, _("4 levels")),
                    {
                        text = _("Ordered dithering"),
                        enabled_func = function() return self.quantize > 0 end,
                        checked_func = function() return self.dither end,
                        callback = function()
                            self:saveSetting("dither", not self.dither)
                            self:render(true)
                        end,
                        separator = true,
                    },
                },
            },
            {
                text = _("Write test pattern instead"),
                help_text = _([[Replaces the sleep screen with a card of known values: grey ramps, the 16 Kaleido grey levels, R/G/B ramps, colour swatches at full and half strength, and a near-neutral gradient.

Photograph the sleep screen and compare it against the same file in Preview. What differs identifies what the system is doing:

• grey steps shift or crush — a tone curve
• swatches shift hue — a colour matrix or saturation change
• smooth ramps gain contours — quantization, and at which level
• the near-neutral band speckles — chroma dithering
• band edges soften — the image is being rescaled

This measures the transform rather than guessing at it. Turn it off again when you are done.]]),
                checked_func = function() return self.test_pattern end,
                callback = function()
                    self:saveSetting("test_pattern", not self.test_pattern)
                    self:render(true)
                end,
            },
            {
                text = _("Log render timings"),
                checked_func = function() return self.debug end,
                callback = function() self:saveSetting("debug", not self.debug) end,
            },
        },
    }
end

return PalmaSleepScreen
