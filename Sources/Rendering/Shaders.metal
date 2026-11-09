#include <metal_stdlib>
using namespace metal;

// One grid on screen. An item's cell comes from an arrangement buffer; the cell's rectangle is
// derived from the column count and pitch. `shift` leaves that many empty cells before the first
// item, which lets a pinch keep the photo under the fingers in its column.
// Rows are measured from baseRow so float precision stays exact even 100k rows deep.
struct LayoutU {
    uint cols;
    uint shift;
    float pitch;
    float gap;
    float originX;
    float yOffset;
    int baseRow;
};

struct Uniforms {
    float2 viewport;
    float2 focal;    // where a re-sort ripple starts
    float t;         // morph progress, 0 = layout a, 1 = layout b
    float stagger;   // share of the morph spent on the ripple's delay
    float alpha;     // grid pass: opacity. morph pass: 0 when both grids are drawn underneath
    int firstRow;    // grid pass: top-left cell drawn, and how many columns per row
    int firstCol;
    uint drawCols;
    uint itemCount;
    LayoutU a;
    LayoutU b;
};

struct PhotoResidency {
    int mediumSlot;
    int largeSlot;
    float mediumAlpha;
    float largeAlpha;
};

struct TileOut {
    float4 position [[position]];
    float2 uv;
    float alpha [[flat]];
    uint photo [[flat]];
    int mediumSlot [[flat]];
    int largeSlot [[flat]];
    float mediumAlpha [[flat]];
    float largeAlpha [[flat]];
};

static float4 cellRect(constant LayoutU &layout, uint cell) {
    int row = int(cell / layout.cols);
    uint col = cell % layout.cols;
    float size = layout.pitch - layout.gap;
    return float4(layout.originX + float(col) * layout.pitch + layout.gap * 0.5,
                  layout.yOffset + float(row - layout.baseRow) * layout.pitch + layout.gap * 0.5,
                  size, size);
}

static bool onScreen(float4 r, float2 viewport) {
    return r.x < viewport.x && r.x + r.z > 0 && r.y < viewport.y && r.y + r.w > 0;
}

static float4 scaledAboutCenter(float4 r, float scale) {
    return float4(r.xy + r.zw * (1.0 - scale) * 0.5, r.zw * scale);
}

static float hash01(uint x) {
    x ^= x >> 16; x *= 0x7feb352dU;
    x ^= x >> 15; x *= 0x846ca68bU;
    x ^= x >> 16;
    return float(x) * (1.0 / 4294967295.0);
}

static float easeOut(float x) {
    float inv = 1.0 - x;
    return 1.0 - inv * inv * inv;
}

static float easeInOut(float x) {
    float inv = 1.0 - x;
    return x < 0.5 ? 8.0 * x * x * x * x : 1.0 - 8.0 * inv * inv * inv * inv;
}

static TileOut tile(float4 r, uint vid, uint item, float alpha, constant Uniforms &u,
                    const device ushort *photoOfItem, const device PhotoResidency *residency) {
    float2 corner = float2(vid & 1, vid >> 1);
    float2 p = r.xy + corner * r.zw;
    uint photo = photoOfItem[item];
    PhotoResidency res = residency[photo];
    TileOut out;
    out.position = float4(p / u.viewport * float2(2, -2) + float2(-1, 1), 0, 1);
    out.uv = corner;
    out.alpha = alpha;
    out.photo = photo;
    out.mediumSlot = res.mediumSlot;
    out.largeSlot = res.largeSlot;
    out.mediumAlpha = res.mediumAlpha;
    out.largeAlpha = res.largeAlpha;
    return out;
}

static TileOut culled() {
    TileOut out;
    out.position = float4(-2, -2, 0, 1);
    return out;
}

// Scrolling and zooming: draws one rigid grid. Only the cells on screen are submitted, so the
// cost follows what is visible, not the size of the library.
vertex TileOut gridVertex(uint vid [[vertex_id]],
                          uint instance [[instance_id]],
                          constant Uniforms &u [[buffer(0)]],
                          const device uint *itemOfCell [[buffer(1)]],
                          const device ushort *photoOfItem [[buffer(3)]],
                          const device PhotoResidency *residency [[buffer(4)]]) {
    // Columns may run past either edge of the grid: those cells show the neighbouring rows'
    // photos, which fills the screen edge while a zoom has the grid narrower than the screen.
    int row = u.firstRow + int(instance / u.drawCols);
    int col = u.firstCol + int(instance % u.drawCols);
    int cell = row * int(u.a.cols) + col - int(u.a.shift);
    if (cell < 0 || cell >= int(u.itemCount)) { return culled(); }
    float size = u.a.pitch - u.a.gap;
    float4 r = float4(u.a.originX + float(col) * u.a.pitch + u.a.gap * 0.5,
                      u.a.yOffset + float(row - u.a.baseRow) * u.a.pitch + u.a.gap * 0.5, size, size);
    return tile(r, vid, itemOfCell[cell], u.alpha, u, photoOfItem, residency);
}

// Re-sorting: every item knows its cell in both arrangements. The change spreads as a ripple
// from the focal point. Tiles on screen at both ends fly; tiles that leave or arrive drift a
// short way while fading, so nothing streaks in from outside the screen.
vertex TileOut morphVertex(uint vid [[vertex_id]],
                           uint item [[instance_id]],
                           constant Uniforms &u [[buffer(0)]],
                           const device uint *cellsA [[buffer(1)]],
                           const device uint *cellsB [[buffer(2)]],
                           const device ushort *photoOfItem [[buffer(3)]],
                           const device PhotoResidency *residency [[buffer(4)]]) {
    float4 ra = cellRect(u.a, cellsA[item] + u.a.shift);
    float4 rb = cellRect(u.b, cellsB[item] + u.b.shift);
    bool inA = onScreen(ra, u.viewport);
    bool inB = onScreen(rb, u.viewport);
    if (!inA && !inB) { return culled(); }
    // Over an underlay the grids themselves handle tiles that only leave or arrive.
    if (u.alpha == 0.0 && !(inA && inB)) { return culled(); }

    float4 home = inB ? rb : ra;
    float2 farCorner = max(u.focal, u.viewport - u.focal);
    float wave = saturate(distance(home.xy + home.zw * 0.5, u.focal) / length(farCorner));
    float delay = u.stagger * (0.85 * wave + 0.15 * hash01(item));
    float local = saturate((u.t - delay) / (1.0 - u.stagger));

    float4 r;
    float alpha = 1.0;
    float drift = 0.1 * u.viewport.y;
    // Small tiles shrink visibly; large ones barely, or they leave thick black frames.
    float shrink = mix(0.8, 0.96, saturate((max(ra.z, rb.z) - 60.0) / 600.0));
    if (inA && inB) {
        // Tiles lift (grow) mid-flight, which also keeps the screen covered while they cross.
        float e = easeInOut(local);
        float lift = sin(e * 3.14159265);
        r = scaledAboutCenter(mix(ra, rb, e), 1.0 + 0.8 * lift);
        // Over an underlay the tile only shows while it is in the air.
        alpha = mix(saturate(lift * 3.0), 1.0, u.alpha);
    } else if (inA) {
        // Leaving: a short drift towards where it is going, shrinking and fading.
        float e = easeOut(local);
        r = scaledAboutCenter(ra, mix(1.0, shrink, e));
        r.y += sign(rb.y - ra.y) * drift * e;
        alpha = 1.0 - e;
    } else {
        // Arriving: a short drift from the side it came from, growing and fading in.
        float e = easeOut(local);
        r = scaledAboutCenter(rb, mix(shrink, 1.0, e));
        r.y += sign(ra.y - rb.y) * drift * (1.0 - e);
        alpha = e;
    }
    if (alpha <= 0.0) { return culled(); }
    return tile(r, vid, item, alpha, u, photoOfItem, residency);
}

// Every photo always has a resident thumbnail, so a tile is never blank.
// Sharper copies fade in on top once they are decoded.
fragment half4 tileFragment(TileOut in [[stage_in]],
                            texture2d_array<half> thumbs [[texture(0)]],
                            texture2d_array<half> medium [[texture(1)]],
                            texture2d_array<half> large [[texture(2)]],
                            sampler s [[sampler(0)]]) {
    half4 c = thumbs.sample(s, in.uv, in.photo);
    if (in.mediumSlot >= 0) {
        c = mix(c, medium.sample(s, in.uv, uint(in.mediumSlot)), half(in.mediumAlpha));
    }
    if (in.largeSlot >= 0) {
        c = mix(c, large.sample(s, in.uv, uint(in.largeSlot)), half(in.largeAlpha));
    }
    return half4(c.rgb, half(in.alpha));
}

// The photo view: one photo at its true shape, over a black backdrop.
struct DetailUniforms {
    float4 rect;     // x, y, width, height in pixels
    float4 uv;       // x, y, width, height of the part of the photo shown
    float2 viewport;
    float alpha;
    float solid;     // 1 = plain black (the backdrop)
};

struct DetailOut {
    float4 position [[position]];
    float2 uv;
};

vertex DetailOut detailVertex(uint vid [[vertex_id]], constant DetailUniforms &u [[buffer(0)]]) {
    float2 corner = float2(vid & 1, vid >> 1);
    float2 p = u.rect.xy + corner * u.rect.zw;
    DetailOut out;
    out.position = float4(p / u.viewport * float2(2, -2) + float2(-1, 1), 0, 1);
    out.uv = u.uv.xy + corner * u.uv.zw;
    return out;
}

fragment half4 detailFragment(DetailOut in [[stage_in]],
                              constant DetailUniforms &u [[buffer(0)]],
                              texture2d<half> photo [[texture(0)]],
                              sampler s [[sampler(0)]]) {
    if (u.solid > 0.5) { return half4(0, 0, 0, half(u.alpha)); }
    return half4(photo.sample(s, in.uv).rgb, half(u.alpha));
}
