// Lyricify Backgrounds — Apple Music Inspired · iOS, modern iOS background.
// Ported from https://github.com/WXRIW/Lyricify-Backgrounds
// Reference commit: cbef8a667c02a01707c78c7e76dc67d65cf161ed
// Source: Lyricify.Backgrounds.AppleMusicInspired.Ios.Shared/Resources/AppleMusicIosBackground.hlsl
// Copyright the Lyricify Backgrounds contributors. Licensed under Apache License 2.0.
// Swift/Metal port © 2026 Luma contributors. Changes: Metal translation, sRGB output.
// See Luma/Resources/Licenses/Lyricify-Apache-2.0.txt and THIRD_PARTY_NOTICES.md.
#include <metal_stdlib>
using namespace metal;

struct LyricifyFrameConstants {
    float time;
    float transitionMix;
    float2 viewScale;
    float blackScrimAlpha;
    float outputDitherStrength;
    float2 blurScale;
    float4 imageScales;
    float4 pinchTextureTransform;
    float rotationScale;
    float2 padding;
};

struct LyricifyQuadVertex {
    float4 position;
    float2 uv;
};

struct LyricifyMeshVertex {
    float2 from;
    float2 to;
    float2 uv;
};

struct LyricifyQuadOutput {
    float4 position [[position]];
    float2 uv;
};

struct LyricifyPinchOutput {
    float4 position [[position]];
    float2 uv;
    float2 screenUV;
};

constant float lyricifyBlurOffsets[77] = {
    1.499792388, 3.499515571, 5.499238755, 7.498961939, 9.498685124, 11.49840831,
    13.498131497, 15.497854684, 17.497577874, 19.497301064, 21.497024257, 23.496747451,
    25.496470647, 27.496193845, 29.495917046, 31.495640249, 33.495363455, 35.495086663,
    37.494809875, 39.49453309, 41.494256308, 43.49397953, 45.493702755, 47.493425984,
    49.493149218, 51.492872455, 53.492595697, 55.492318943, 57.492042195, 59.49176545,
    61.491488712, 63.491211978, 65.490935249, 67.490658527, 69.490381809, 71.490105098,
    73.489828393, 75.489551694, 77.489275002, 79.488998316, 81.488721637, 83.488444964,
    85.488168299, 87.487891641, 89.487614991, 91.487338348, 93.487061713, 95.486785085,
    97.486508466, 99.486231855, 101.485955253, 103.485678659, 105.485402074, 107.485125498,
    109.484848931, 111.484572373, 113.484295824, 115.484019286, 117.483742757, 119.483466238,
    121.483189729, 123.482913231, 125.482636742, 127.482360265, 129.482083798, 131.481807343,
    133.481530898, 135.481254465, 137.480978043, 139.480701633, 141.480425235, 143.480148848,
    145.479872474, 147.479596112, 149.479319763, 151.479043426, 153.0
};

constant float lyricifyBlurWeights[77] = {
    0.0187664737, 0.01871460399, 0.01862159953, 0.01848807512, 0.01831490985,
    0.01810323743, 0.01785443382, 0.01757010239, 0.01725205665, 0.01690230103,
    0.01652300989, 0.01611650499, 0.01568523193, 0.01523173574, 0.01475863601,
    0.01426860189, 0.01376432738, 0.01324850701, 0.01272381248, 0.01219287029,
    0.0116582408, 0.01112239879, 0.01058771585, 0.01005644461, 0.00953070502,
    0.00901247274, 0.00850356966, 0.0080056566, 0.00752022811, 0.0070486094,
    0.00659195523, 0.00615125069, 0.0057273138, 0.00532079962, 0.00493220595,
    0.0045618802, 0.0042100274, 0.00387671917, 0.00356190339, 0.00326541439,
    0.00298698364, 0.0027262505, 0.00248277319, 0.00225603955, 0.00204547767,
    0.00185046618, 0.00167034405, 0.00150441998, 0.0013519811, 0.00121230117,
    0.00108464796, 0.00096829001, 0.00086250273, 0.00076657363, 0.00067980702,
    0.00060152792, 0.00053108534, 0.00046785492, 0.00041124106, 0.00036067838,
    0.0003156328, 0.00027560209, 0.00024011609, 0.0002087365, 0.00018105641,
    0.00015669956, 0.00013531939, 0.00011659788, 0.0001002443, 0.00008599378,
    0.00007360593, 0.00006286326, 0.00005356972, 0.00004554915, 0.00003864377,
    0.00003271276, 0.00001440207
};

constant float lyricifyBlurCenterWeight = 0.009389731878;
constant float lyricifyTwoPi = 6.2831853071795864769;

float2 lyricifyRotate(float2 value, float angle) {
    float sine = sin(angle);
    float cosine = cos(angle);
    return float2(cosine * value.x - sine * value.y,
                  sine * value.x + cosine * value.y);
}

float lyricifyModelScale(uint instanceID) {
    return instanceID == 0 ? 1.4 : 0.7;
}

float2 lyricifyModelTranslation(uint instanceID) {
    if (instanceID == 1) return float2(-0.25, 0.15);
    if (instanceID == 2) return float2(0.7, 0.7);
    return float2(0.0, 0.0);
}

float lyricifyRotationTimeScale(uint instanceID) {
    if (instanceID == 1) return 70.0;
    if (instanceID == 2) return 90.0;
    return 120.0;
}

float3 lyricifyApplySaturation(float3 color, float saturation) {
    const float3 luma = float3(0.2126, 0.7152, 0.0722);
    float3 redColumn = float3(
        luma.r + 0.7873 * saturation,
        luma.r - luma.r * saturation,
        luma.r - luma.r * saturation);
    float3 greenColumn = float3(
        luma.g - luma.g * saturation,
        luma.g + (1.0 - luma.g) * saturation,
        luma.g - luma.g * saturation);
    float3 blueColumn = float3(
        luma.b - luma.b * saturation,
        luma.b - luma.b * saturation,
        luma.b + (1.0 - luma.b) * saturation);
    return redColumn * color.r + greenColumn * color.g + blueColumn * color.b;
}

float3 lyricifyApplyTreatedMaterial(float3 color, float blackScrimAlpha) {
    color = lyricifyApplySaturation(color, 1.4);
    color = clamp(color, -0.752941, 1.25098);
    color = lyricifyApplySaturation(color, 0.70);
    return mix(color, float3(0.0), blackScrimAlpha);
}

float4 lyricifyFinishMaterial(float3 color, float2 pixelPosition, float ditherStrength) {
    float dither = fract(
        52.9829189 * fract(dot(pixelPosition, float2(0.06711056, 0.00583715)))) - 0.5;
    color += dither * (ditherStrength / 255.0);
    return float4(clamp(color, 0.07, 0.97), 1.0);
}

vertex LyricifyQuadOutput lyricifyFullscreenVertex(uint vertexID [[vertex_id]]) {
    const float2 positions[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
    LyricifyQuadOutput out;
    out.position = float4(positions[vertexID], 0, 1);
    out.uv = float2((positions[vertexID].x + 1) * 0.5,
                    (1 - positions[vertexID].y) * 0.5);
    return out;
}

vertex LyricifyQuadOutput lyricifyQuadVertex(
    uint vertexID [[vertex_id]],
    constant LyricifyQuadVertex *vertices [[buffer(1)]]
) {
    LyricifyQuadVertex input = vertices[vertexID];
    LyricifyQuadOutput out;
    out.position = input.position;
    out.uv = input.uv;
    return out;
}

vertex LyricifyQuadOutput lyricifyArtworkFillVertex(
    uint vertexID [[vertex_id]],
    constant LyricifyQuadVertex *vertices [[buffer(1)]],
    constant LyricifyFrameConstants &constants [[buffer(0)]]
) {
    LyricifyQuadVertex input = vertices[vertexID];
    LyricifyQuadOutput out;
    out.position = input.position;
    out.uv = (input.uv - 0.5) / constants.viewScale + 0.5;
    return out;
}

vertex LyricifyQuadOutput lyricifyRotationVertex(
    uint vertexID [[vertex_id]],
    uint instanceID [[instance_id]],
    constant LyricifyQuadVertex *vertices [[buffer(1)]],
    constant LyricifyFrameConstants &constants [[buffer(0)]]
) {
    LyricifyQuadVertex input = vertices[vertexID];
    float angle = constants.time * constants.rotationScale * lyricifyTwoPi
        / lyricifyRotationTimeScale(instanceID);
    float2 position = lyricifyRotate(input.position.xy, angle);
    position *= lyricifyModelScale(instanceID);
    position += lyricifyModelTranslation(instanceID);
    position *= constants.viewScale;
    if (instanceID == 2) {
        float parentAngle = constants.time * constants.rotationScale * lyricifyTwoPi
            / lyricifyRotationTimeScale(0);
        position = lyricifyRotate(position, parentAngle);
    }
    position *= constants.imageScales.x;

    LyricifyQuadOutput out;
    out.position = float4(position, 0.0, 1.0);
    out.uv = input.uv;
    return out;
}

vertex LyricifyPinchOutput lyricifyPinchVertex(
    uint vertexID [[vertex_id]],
    constant LyricifyMeshVertex *vertices [[buffer(1)]],
    constant LyricifyFrameConstants &constants [[buffer(0)]]
) {
    LyricifyMeshVertex input = vertices[vertexID];
    const float pi = 3.14159265358979323846;
    // The reference uses 5s. Apple Music's lyrics mesh breathes much more slowly;
    // the caller also applies its ambient motion scale to `time`.
    const float meshWarpTimeScale = 8.0;
    float phase = acos(sin(constants.time * pi / meshWarpTimeScale)) / pi;
    float mixValue = phase * phase * (3.0 - 2.0 * phase);
    float2 warpedPosition = mix(input.from, input.to, mixValue);

    LyricifyPinchOutput out;
    out.position = float4(warpedPosition, 0.0, 1.0);
    out.uv = input.uv * constants.pinchTextureTransform.xy
        + constants.pinchTextureTransform.zw;
    out.screenUV = float2(warpedPosition.x * 0.5 + 0.5,
                          0.5 - warpedPosition.y * 0.5);
    return out;
}

fragment float4 lyricifyRotationFragment(
    LyricifyQuadOutput in [[stage_in]],
    texture2d<float> current [[texture(0)]],
    texture2d<float> previous [[texture(1)]],
    constant LyricifyFrameConstants &constants [[buffer(0)]]
) {
    constexpr sampler imageSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float3 currentColor = current.sample(imageSampler, in.uv).rgb;
    float3 previousColor = previous.sample(imageSampler, in.uv).rgb;
    float3 color = mix(previousColor, currentColor, constants.transitionMix);
    return float4(color, 1.0);
}

float4 lyricifyGaussianBlur(
    texture2d<float> source,
    sampler imageSampler,
    float2 textureCoordinate,
    float2 direction,
    bool normalizeOutput
) {
    float4 color = source.sample(imageSampler, textureCoordinate) * lyricifyBlurCenterWeight;
    for (int index = 0; index < 77; index++) {
        float2 offset = direction * lyricifyBlurOffsets[index];
        color += (source.sample(imageSampler, textureCoordinate + offset)
            + source.sample(imageSampler, textureCoordinate - offset))
            * lyricifyBlurWeights[index];
    }
    if (normalizeOutput) {
        color.rgb /= max(color.a, 1.0 / 65535.0);
        color.a = 1.0;
    }
    return color;
}

fragment float4 lyricifyBlurHorizontal(
    LyricifyQuadOutput in [[stage_in]],
    texture2d<float> source [[texture(0)]],
    constant LyricifyFrameConstants &constants [[buffer(0)]]
) {
    constexpr sampler edgeSampler(coord::normalized, address::clamp_to_zero, filter::linear);
    float width = float(source.get_width());
    return lyricifyGaussianBlur(source, edgeSampler, in.uv,
        float2(constants.blurScale.x / width, 0.0), false);
}

fragment float4 lyricifyBlurVertical(
    LyricifyQuadOutput in [[stage_in]],
    texture2d<float> source [[texture(0)]],
    constant LyricifyFrameConstants &constants [[buffer(0)]]
) {
    constexpr sampler edgeSampler(coord::normalized, address::clamp_to_zero, filter::linear);
    float height = float(source.get_height());
    return lyricifyGaussianBlur(source, edgeSampler, in.uv,
        float2(0.0, constants.blurScale.y / height), true);
}

float3 lyricifySampleUnassociated(
    texture2d<float> source,
    sampler imageSampler,
    float2 textureCoordinate
) {
    float4 sample = source.sample(imageSampler, textureCoordinate);
    return sample.rgb / max(sample.a, 1.0 / 65535.0);
}

float3 lyricifySampleTreatedMaterial(
    texture2d<float> source,
    sampler imageSampler,
    float2 textureCoordinate,
    float blackScrimAlpha
) {
    float3 color = lyricifySampleUnassociated(source, imageSampler, textureCoordinate);
    return lyricifyApplyTreatedMaterial(color, blackScrimAlpha);
}

fragment float4 lyricifyTreatedFirstFragment(
    LyricifyQuadOutput in [[stage_in]],
    texture2d<float> source [[texture(0)]]
) {
    constexpr sampler imageSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float3 color = lyricifySampleUnassociated(source, imageSampler, in.uv);
    color = lyricifyApplySaturation(color, 1.4);
    color = clamp(color, -0.752941, 1.25098);
    return float4(color, 1.0);
}

fragment float4 lyricifyTreatedSecondFragment(
    LyricifyQuadOutput in [[stage_in]],
    texture2d<float> source [[texture(0)]]
) {
    constexpr sampler imageSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float3 color = lyricifySampleUnassociated(source, imageSampler, in.uv);
    color = lyricifyApplySaturation(color, 1.4);
    color = clamp(color, -0.752941, 1.25098);
    color = lyricifyApplySaturation(color, 0.70);
    return float4(color, 1.0);
}

fragment float4 lyricifyRawFragment(
    LyricifyQuadOutput in [[stage_in]],
    texture2d<float> source [[texture(0)]]
) {
    constexpr sampler imageSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float4 sample = source.sample(imageSampler, in.uv);
    return float4(sample.rgb, 1.0);
}

fragment float4 lyricifyTreatedFragment(
    LyricifyQuadOutput in [[stage_in]],
    texture2d<float> source [[texture(0)]],
    constant LyricifyFrameConstants &constants [[buffer(0)]]
) {
    constexpr sampler imageSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float3 color = lyricifySampleTreatedMaterial(source, imageSampler, in.uv,
        constants.blackScrimAlpha);
    return lyricifyFinishMaterial(color, in.position.xy, constants.outputDitherStrength);
}

fragment float4 lyricifyPinchFragment(
    LyricifyPinchOutput in [[stage_in]],
    texture2d<float> source [[texture(0)]],
    constant LyricifyFrameConstants &constants [[buffer(0)]]
) {
    constexpr sampler imageSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float3 color = lyricifySampleTreatedMaterial(source, imageSampler, in.uv,
        constants.blackScrimAlpha);
    return lyricifyFinishMaterial(color, in.position.xy, constants.outputDitherStrength);
}
