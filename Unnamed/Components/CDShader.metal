#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// Procedural compact discs, drawn per pixel as a SwiftUI color effect.
//
// The rainbow comes from a small diffraction model: a CD's data track is a
// spiral of grooves ~1.6 µm apart, which acts as a circular diffraction
// grating. For each point we take the half vector between a light hovering
// above the screen (it follows the mouse) and the viewer, project it onto the
// grating direction (radial), and ask which wavelengths the first few
// diffraction orders send back to the eye. That's why the sheen sweeps across
// the disc as the light moves, while the disc's printed details spin.

namespace {

// Alan Zucconi's six-bump approximation of the visible spectrum.
float3 bump3y(float3 x, float3 yOffset) {
    float3 y = 1.0 - x * x;
    return saturate(y - yOffset);
}

float3 spectral(float wavelength) {
    float x = saturate((wavelength - 400.0) / 300.0);
    const float3 c1 = float3(3.54585104, 2.93225262, 2.41593945);
    const float3 x1 = float3(0.69549072, 0.49228336, 0.27699880);
    const float3 y1 = float3(0.02312639, 0.15225084, 0.52607955);
    const float3 c2 = float3(3.90307140, 3.21182957, 3.96587128);
    const float3 x2 = float3(0.11748627, 0.86755042, 0.66077860);
    const float3 y2 = float3(0.84897130, 0.88445281, 0.73949448);
    return bump3y(c1 * (x - x1), y1) + bump3y(c2 * (x - x2), y2);
}

// One disc, premultiplied: rgb * alpha, alpha.
float4 shadeDisc(float2 position, float2 center, float radius, float angle,
                 float kind, float2 light, float hover) {
    float2 p = position - center;
    float r = length(p);
    float rn = r / radius;
    float aa = 1.2 / radius;   // about one pixel, in disc units

    float alpha = (1.0 - smoothstep(1.0 - aa, 1.0, rn)) * smoothstep(0.075, 0.075 + aa, rn);
    if (alpha <= 0.0) {
        return float4(0.0);
    }

    float2 radial = p / max(r, 1e-4);
    float2 tangent = float2(-radial.y, radial.x);
    float theta = atan2(p.y, p.x) + angle;

    // A light above the screen, and a viewer straight on.
    float3 toLight = normalize(float3(light - position, radius * 1.1));
    float3 halfVector = normalize(toLight + float3(0.0, 0.0, 1.0));

    // Base: a mirror reflecting a dark room, brighter on the side facing the
    // light. Tinted for gold / blue dye discs.
    float3 tint = kind < 0.5 ? float3(1.0)
                : kind < 1.5 ? float3(1.0, 0.84, 0.52)
                             : float3(0.60, 0.80, 1.0);
    float facing = dot(radial, normalize(light - center + float2(1e-3)));
    float3 color = mix(float3(0.40, 0.42, 0.48), float3(0.80, 0.82, 0.87), smoothstep(0.15, 1.0, rn));
    color = (color + 0.10 * facing) * tint;

    // The data area: very fine rings plus slow-rotating sectors (burned
    // data), which is what makes the spin visible.
    float data = smoothstep(0.33, 0.35, rn) * (1.0 - smoothstep(0.955, 0.965, rn));
    float rings = 0.016 * sin(rn * 430.0) + 0.014 * sin(rn * 53.0 + 1.3);
    float sectors = 0.035 * sin(theta * 3.0 + rn * 7.0) + 0.02 * sin(theta * 8.0 - rn * 13.0);
    float written = smoothstep(0.62, 0.64, rn) * (1.0 - smoothstep(0.80, 0.82, rn)) * 0.05;
    color += data * (rings + sectors - written);

    // Diffraction: orders 1–3 of a 1600 nm grating.
    float u = abs(dot(halfVector.xy, radial));
    float3 rainbow = float3(0.0);
    for (int order = 1; order <= 3; order++) {
        float wavelength = 1600.0 * u / float(order);
        float visible = smoothstep(380.0, 430.0, wavelength) * (1.0 - smoothstep(660.0, 720.0, wavelength));
        rainbow += spectral(wavelength) * visible / float(order);
    }
    // Only where the grooves line up with the light (a band through the
    // centre). The silver dims under the colour so it reads saturated, the
    // way a real disc does, rather than washed out.
    float alongGrooves = dot(halfVector.xy, tangent);
    float band = exp(-alongGrooves * alongGrooves * 22.0);
    float strength = band * data * (0.75 + 0.6 * hover);
    float brightness = saturate(dot(rainbow, float3(0.3, 0.59, 0.11)) * 1.6);
    color = color * (1.0 - 0.65 * strength * brightness) + rainbow * strength * 1.35;

    // A soft glint where the light is closest.
    float glint = pow(saturate(halfVector.z), 70.0);
    color += glint * 0.55;

    // Inner mirror band and the clear plastic hub.
    float mirror = smoothstep(0.175, 0.185, rn) * (1.0 - smoothstep(0.315, 0.33, rn));
    color = mix(color, float3(0.93, 0.94, 0.97) * tint + glint * 0.5, mirror * 0.55);
    float hub = 1.0 - smoothstep(0.17, 0.17 + aa, rn);

    // Thin ridges at the hub, the data edge and the rim.
    float hubEdge = (rn - 0.17) * radius * 0.8;
    float dataEdge = (rn - 0.335) * radius * 0.8;
    float rimEdge = (rn - 0.985) * radius * 0.5;
    float ridge = exp(-hubEdge * hubEdge) * 0.22
                + exp(-dataEdge * dataEdge) * 0.10
                + exp(-rimEdge * rimEdge) * 0.18;
    color += ridge;
    color *= mix(1.0, 0.82, smoothstep(0.92, 1.0, rn));

    alpha *= mix(1.0, 0.32, hub);
    return float4(color * alpha, alpha);
}

} // namespace

/// discs: 6 floats per disc — centre x, centre y, radius, rotation (radians),
/// kind (0 silver, 1 gold, 2 blue), unused.
/// Works over any background, including a transparent one: the result is
/// premultiplied, like SwiftUI's colours.
[[ stitchable ]] half4 cdField(float2 position, half4 color, float2 size, float2 light,
                               float hover, device const float *discs, int count) {
    float4 result = float4(color);
    int n = count / 6;

    // Soft drop shadows first, so discs sit above the background.
    float shade = 0.0;
    for (int i = 0; i < n; i++) {
        float2 center = float2(discs[i * 6], discs[i * 6 + 1]);
        float radius = discs[i * 6 + 2];
        float d = length(position - center - float2(0.0, radius * 0.06));
        shade = max(shade, (1.0 - smoothstep(radius * 0.88, radius * 1.14, d)) * 0.5);
    }
    result = float4(0.0, 0.0, 0.0, shade) + result * (1.0 - shade);

    for (int i = 0; i < n; i++) {
        float4 disc = shadeDisc(position,
                                float2(discs[i * 6], discs[i * 6 + 1]),
                                discs[i * 6 + 2],
                                discs[i * 6 + 3],
                                discs[i * 6 + 4],
                                light, hover);
        result = disc + result * (1.0 - disc.a);
    }
    return half4(result);
}

/// A light CD sheen over an existing disc image (the collection's record):
/// the same diffraction band and glint as above, screened onto the pixels so
/// the artwork shows through. The band stays put while the disc turns under
/// it, like a real CD under a lamp.
[[ stitchable ]] half4 cdSheen(float2 position, half4 color, float2 size, float2 light, float strength) {
    if (color.a <= 0.001h) {
        return color;
    }
    float2 center = size * 0.5;
    float radius = min(size.x, size.y) * 0.5;
    float2 p = position - center;
    float r = length(p);
    float rn = r / radius;
    float2 radial = p / max(r, 1e-4);
    float2 tangent = float2(-radial.y, radial.x);

    float3 toLight = normalize(float3(light - position, radius * 1.1));
    float3 halfVector = normalize(toLight + float3(0.0, 0.0, 1.0));

    float u = abs(dot(halfVector.xy, radial));
    float3 rainbow = float3(0.0);
    for (int order = 1; order <= 3; order++) {
        float wavelength = 1600.0 * u / float(order);
        float visible = smoothstep(380.0, 430.0, wavelength) * (1.0 - smoothstep(660.0, 720.0, wavelength));
        rainbow += spectral(wavelength) * visible / float(order);
    }
    float alongGrooves = dot(halfVector.xy, tangent);
    float band = exp(-alongGrooves * alongGrooves * 22.0);
    float data = smoothstep(0.24, 0.32, rn) * (1.0 - smoothstep(0.93, 0.99, rn));
    float glint = pow(saturate(halfVector.z), 50.0);

    float3 add = saturate((rainbow * band + glint * 0.35) * data * strength);
    float3 base = float3(color.rgb);
    float alpha = float(color.a);
    // Screen blend in premultiplied space: brightens without washing out.
    float3 result = base + add * (alpha - base);
    return half4(half3(result), color.a);
}
