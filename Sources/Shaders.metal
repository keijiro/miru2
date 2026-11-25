#include <metal_stdlib>
using namespace metal;

constant bool srgbTarget [[function_constant(0)]];
constexpr sampler linearClamp(coord::normalized, address::clamp_to_edge, filter::linear);

struct QuadVertex {
    float4 position [[position]];
    float2 uv;
};

vertex QuadVertex quadVertex(uint id [[vertex_id]], constant float4x4 &mvp [[buffer(0)]]) {
    float2 corners[] = {{0, 0}, {0, 1}, {1, 0}, {1, 1}};
    float2 uv = corners[id];
    return {mvp * float4(uv.x - 0.5, 0.5 - uv.y, 0, 1), uv};
}

float3 srgbToLinear(float3 v) {
    return select(v / 12.92, powr((v + 0.055) / 1.055, 2.4), v > 0.04045);
}

float4 outputColor(float4 premultiplied) {
    if (!srgbTarget || premultiplied.a <= 0) return premultiplied;
    return float4(srgbToLinear(saturate(premultiplied.rgb / premultiplied.a)) * premultiplied.a,
                  premultiplied.a);
}

fragment float4 solidFragment(QuadVertex in [[stage_in]], constant float4 &color [[buffer(0)]]) {
    return outputColor(float4(color.rgb * color.a, color.a));
}

fragment float4 imageFragment(QuadVertex in [[stage_in]], constant float4 &crop [[buffer(0)]],
                              texture2d<float> image [[texture(0)]]) {
    return outputColor(image.sample(linearClamp, crop.xy + in.uv * crop.zw));
}

struct VideoParameters {
    float4 conversion;
    float4 u;
    float4 v;
};

float4 videoColor(float2 uv, constant VideoParameters &video,
                  texture2d<float> luma, texture2d<float> chroma) {
    float3 position = float3(uv, 1);
    float2 sampleUV = float2(dot(video.u.xyz, position), dot(video.v.xyz, position));
    float y = (luma.sample(linearClamp, sampleUV).r - video.conversion.z) * video.conversion.w;
    float2 cbcr = (chroma.sample(linearClamp, sampleUV).rg - 128.0 / 255.0)
                  * (video.conversion.z == 0 ? 1.0 : 255.0 / 224.0);
    float kr = video.conversion.x, kb = video.conversion.y;
    float red = 2 * (1 - kr) * cbcr.y;
    float blue = 2 * (1 - kb) * cbcr.x;
    float green = -(kr * red + kb * blue) / (1 - kr - kb);
    float3 rgb = saturate(y + float3(red, green, blue));
    return float4(srgbTarget ? srgbToLinear(rgb) : rgb, 1);
}

fragment float4 videoFragment(QuadVertex in [[stage_in]], constant VideoParameters &video [[buffer(0)]],
                              texture2d<float> luma [[texture(0)]], texture2d<float> chroma [[texture(1)]]) {
    return videoColor(in.uv, video, luma, chroma);
}

struct PanoramaCamera {
    float4x4 eyeToPanorama;
    float4 fov;
    float4 eyeUV;
};

struct PanoramaVertex {
    float4 position [[position]];
    float3 direction;
};

vertex PanoramaVertex panoramaVertex(uint id [[vertex_id]], constant PanoramaCamera &camera [[buffer(0)]]) {
    float2 corners[] = {{-1, -1}, {3, -1}, {-1, 3}};
    float2 xy = corners[id];
    float2 uv = xy * 0.5 + 0.5;
    float3 ray = float3(mix(camera.fov.x, camera.fov.y, uv.x),
                        mix(camera.fov.z, camera.fov.w, uv.y), -1);
    return {float4(xy, 1, 1), (camera.eyeToPanorama * float4(ray, 0)).xyz};
}

fragment float4 panoramaFragment(PanoramaVertex in [[stage_in]], constant VideoParameters &video [[buffer(0)]],
                                 constant PanoramaCamera &camera [[buffer(1)]],
                                 texture2d<float> luma [[texture(0)]], texture2d<float> chroma [[texture(1)]]) {
    if (in.direction.z >= 0) discard_fragment();
    float3 ray = normalize(in.direction);
    float u = atan2(ray.x, -ray.z) / M_PI_F + 0.5;
    float v = 0.5 - asin(ray.y) / M_PI_F;
    float eyeU = clamp(camera.eyeUV.z + u * 0.5, camera.eyeUV.x, camera.eyeUV.y);
    return videoColor(float2(eyeU, v), video, luma, chroma);
}
