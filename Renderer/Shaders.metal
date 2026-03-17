/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
The Metal shaders used for this sample.
*/
#include "ShaderTypes.h"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

using namespace raytracing;

constant unsigned int resourcesStride   [[function_constant(0)]];
constant bool useIntersectionFunctions  [[function_constant(1)]];
constant bool usePerPrimitiveData       [[function_constant(2)]];
constant bool useResourcesBuffer = !usePerPrimitiveData;

constant unsigned int primes[] = {
    2,   3,  5,  7,
    11, 13, 17, 19,
    23, 29, 31, 37,
    41, 43, 47, 53,
    59, 61, 67, 71,
    73, 79, 83, 89
};

// Returns the i'th element of the Halton sequence using the d'th prime number as a
// base. The Halton sequence is a low discrepency sequence: the values appear
// random, but are more evenly distributed than a purely random sequence. Each random
// value used to render the image uses a different independent dimension, `d`,
// and each sample (frame) uses a different index `i`. To decorrelate each pixel,
// you can apply a random offset to `i`.
float halton(unsigned int i, unsigned int d) {
    unsigned int b = primes[d];

    float f = 1.0f;
    float invB = 1.0f / b;

    float r = 0;

    while (i > 0) {
        f = f * invB;
        r = r + f * (i % b);
        i = i / b;
    }

    return r;
}

// Interpolates the vertex attribute of an arbitrary type across the surface of a triangle
// given the barycentric coordinates and triangle index in an intersection structure.
template<typename T, typename IndexType>
inline T interpolateVertexAttribute(device T *attributes,
                                    IndexType i0,
                                    IndexType i1,
                                    IndexType i2,
                                    float2 uv) {
    // Look up value for each vertex.
    const T T0 = attributes[i0];
    const T T1 = attributes[i1];
    const T T2 = attributes[i2];

    // Compute the sum of the vertex attributes weighted by the barycentric coordinates.
    // The barycentric coordinates sum to one.
    return (1.0f - uv.x - uv.y) * T0 + uv.x * T1 + uv.y * T2;
}

template<typename T>
inline T interpolateVertexAttribute(thread T *attributes, float2 uv) {
    // Look up the value for each vertex.
    const T T0 = attributes[0];
    const T T1 = attributes[1];
    const T T2 = attributes[2];

    // Compute the sum of the vertex attributes weighted by the barycentric coordinates.
    // The barycentric coordinates sum to one.
    return (1.0f - uv.x - uv.y) * T0 + uv.x * T1 + uv.y * T2;
}

// Uses the inversion method to map two uniformly random numbers to a 3D
// unit hemisphere, where the probability of a given sample is proportional to the cosine
// of the angle between the sample direction and the "up" direction (0, 1, 0).
inline float3 sampleCosineWeightedHemisphere(float2 u) {
    float phi = 2.0f * M_PI_F * u.x;

    float cos_phi;
    float sin_phi = sincos(phi, cos_phi);

    float cos_theta = sqrt(u.y);
    float sin_theta = sqrt(1.0f - cos_theta * cos_theta);

    return float3(sin_theta * cos_phi, cos_theta, sin_theta * sin_phi);
}

// Maps two uniformly random numbers to the surface of a 2D area light
// source and returns the direction to this point, the amount of light that travels
// between the intersection point and the sample point on the light source, as well
// as the distance between these two points.

inline void sampleAreaLight(constant AreaLight & light,
                            float2 u,
                            float3 position,
                            thread float3 & lightDirection,
                            thread float3 & lightColor,
                            thread float & lightDistance)
{
    // Map to -1..1
    u = u * 2.0f - 1.0f;

    // Transform into the light's coordinate system.
    float3 samplePosition = light.position +
                            light.right * u.x +
                            light.up * u.y;

    // Compute the vector from sample point on  the light source to intersection point.
    lightDirection = samplePosition - position;

    lightDistance = length(lightDirection);

    float inverseLightDistance = 1.0f / max(lightDistance, 1e-3f);

    // Normalize the light direction.
    lightDirection *= inverseLightDistance;

    // Start with the light's color.
    lightColor = light.color;

    // Light falls off with the inverse square of the distance to the intersection point.
    lightColor *= (inverseLightDistance * inverseLightDistance);

    // Light also falls off with the cosine of the angle between the intersection point
    // and the light source.
    lightColor *= saturate(dot(-lightDirection, light.forward));
}

// Aligns a direction on the unit hemisphere such that the hemisphere's "up" direction
// (0, 1, 0) maps to the given surface normal direction.
inline float3 alignHemisphereWithNormal(float3 sample, float3 normal) {
    // Set the "up" vector to the normal
    float3 up = normal;

    // Find an arbitrary direction perpendicular to the normal, which becomes the
    // "right" vector.
    float3 right = normalize(cross(normal, float3(0.0072f, 1.0f, 0.0034f)));

    // Find a third vector perpendicular to the previous two, which becomes the
    // "forward" vector.
    float3 forward = cross(right, up);

    // Map the direction on the unit hemisphere to the coordinate system aligned
    // with the normal.
    return sample.x * right + sample.y * up + sample.z * forward;
}

// Return the type for a bounding box intersection function.
struct BoundingBoxIntersection {
    bool accept    [[accept_intersection]]; // Whether to accept or reject the intersection.
    float distance [[distance]];            // Distance from the ray origin to the intersection point.
};

// Resources for a piece of triangle geometry.
struct TriangleResources {
    device uint16_t *indices;
    device float3 *vertexNormals;
    device float3 *vertexColors;
};

// Resources for a piece of sphere geometry.
struct SphereResources {
    device Sphere *spheres;
};

/*
 Custom sphere intersection function. The [[intersection]] keyword marks this as an intersection
 function. The [[bounding_box]] keyword means that this intersection function handles intersecting rays
 with bounding box primitives. To create sphere primitives, the sample creates bounding boxes that
 enclose the sphere primitives.

 The [[triangle_data]] and [[instancing]] keywords indicate that the intersector that calls this
 intersection function returns barycentric coordinates for triangle intersections and traverses
 an instance acceleration structure. These keywords must match between the intersection functions,
 intersection function table, intersector, and intersection result to ensure that Metal propagates
 data correctly between stages. Using fewer tags when possible may result in better performance,
 as Metal may need to store less data and pass less data between stages. For example, if you do not
 need barycentric coordinates, omitting [[triangle_data]] means Metal can avoid computing and storing
 them.

 The arguments to the intersection function contain information about the ray, primitive to be
 tested, and so on. The ray intersector provides this datas when it calls the intersection function.
 Metal provides other built-in arguments, but this sample doesn't use them.
 */
[[intersection(bounding_box, triangle_data, instancing)]]
BoundingBoxIntersection sphereIntersectionFunction(// Ray parameters passed to the ray intersector below
                                                   float3 origin                        [[origin]],
                                                   float3 direction                     [[direction]],
                                                   float minDistance                    [[min_distance]],
                                                   float maxDistance                    [[max_distance]],
                                                   // Information about the primitive.
                                                   unsigned int primitiveIndex          [[primitive_id]],
                                                   unsigned int geometryIndex           [[geometry_intersection_function_table_offset]],
                                                   // Custom resources bound to the intersection function table.
                                                   device void *resources               [[buffer(0), function_constant(useResourcesBuffer)]]
#if SUPPORTS_METAL_3
                                                   ,const device void* perPrimitiveData [[primitive_data]]
#endif
                                                   )
{
    Sphere sphere;
#if SUPPORTS_METAL_3
    // Look up the resources for this piece of sphere geometry.
    if (usePerPrimitiveData) {
        // Per-primitive data points to data from the specified buffer as was configured in the MTLAccelerationStructureBoundingBoxGeometryDescriptor.
        sphere = *(const device Sphere*)perPrimitiveData;
    } else
#endif
    {
        device SphereResources& sphereResources = *(device SphereResources *)((device char *)resources + resourcesStride * geometryIndex);
        // Get the actual sphere enclosed in this bounding box.
        sphere = sphereResources.spheres[primitiveIndex];
    }

    // Check for intersection between the ray and sphere mathematically.
    float3 oc = origin - sphere.origin;

    float a = dot(direction, direction);
    float b = 2 * dot(oc, direction);
    float c = dot(oc, oc) - sphere.radiusSquared;

    float disc = b * b - 4 * a * c;

    BoundingBoxIntersection ret;

    if (disc <= 0.0f) {
        // If the ray missed the sphere, return false.
        ret.accept = false;
    }
    else {
        // Otherwise, compute the intersection distance.
        ret.distance = (-b - sqrt(disc)) / (2 * a);

        // The intersection function must also check whether the intersection distance is
        // within the acceptable range. Intersection functions do not run in any particular order,
        // so the maximum distance may be different from the one passed into the ray intersector.
        ret.accept = ret.distance >= minDistance && ret.distance <= maxDistance;
    }

    return ret;
}

__attribute__((always_inline))
float3 transformPoint(float3 p, float4x4 transform) {
    return (transform * float4(p.x, p.y, p.z, 1.0f)).xyz;
}

__attribute__((always_inline))
float3 transformDirection(float3 p, float4x4 transform) {
    return (transform * float4(p.x, p.y, p.z, 0.0f)).xyz;
}

__attribute__((always_inline))
float3x3 inverseTranspose3x3(float3x3 m) {
    float3 c0 = m[0];
    float3 c1 = m[1];
    float3 c2 = m[2];
    float3 r0 = cross(c1, c2);
    float3 r1 = cross(c2, c0);
    float3 r2 = cross(c0, c1);
    float determinant = dot(c0, r0);

    if (fabs(determinant) < 1e-8f) {
        return float3x3(float3(1.0f, 0.0f, 0.0f),
                        float3(0.0f, 1.0f, 0.0f),
                        float3(0.0f, 0.0f, 1.0f));
    }

    return float3x3(r0 / determinant, r1 / determinant, r2 / determinant);
}

// Main ray tracing kernel.
kernel void raytracingKernel(
     uint2                                                  tid                       [[thread_position_in_grid]],
     constant Uniforms &                                    uniforms                  [[buffer(0)]],
     texture2d<unsigned int>                                randomTex                 [[texture(0)]],
     texture2d<float>                                       prevTex                   [[texture(1)]],
     texture2d<float, access::write>                        dstTex                    [[texture(2)]],
     texture2d<float, access::write>                        noisyColorTex             [[texture(3)]],
     device void                                           *resources                 [[buffer(1), function_constant(useResourcesBuffer)]],
     constant MTLAccelerationStructureInstanceDescriptor   *instances                 [[buffer(2)]],
     constant AreaLight                                    *areaLights                [[buffer(3)]],
     instance_acceleration_structure                        accelerationStructure     [[buffer(4)]],
     intersection_function_table<triangle_data, instancing> intersectionFunctionTable [[buffer(5)]]
)
{
    // The sample aligns the thread count to the threadgroup size, which means the thread count
    // may be different than the bounds of the texture. Test to make sure this thread
    // is referencing a pixel within the bounds of the texture.
    if (tid.x < uniforms.width && tid.y < uniforms.height) {
        // The ray to cast.
        ray ray;

        // Pixel coordinates for this thread.
        float2 pixel = (float2)tid;

        // Apply a random offset to the random number index to decorrelate pixels.
        unsigned int offset = randomTex.read(tid).x;

        if (uniforms.temporalDenoiserEnabled) {
            pixel += 0.5f + uniforms.jitter;
        } else {
            // Add a random offset to the pixel coordinates for antialiasing.
            float2 r = float2(halton(offset + uniforms.frameIndex, 0),
                              halton(offset + uniforms.frameIndex, 1));
            pixel += r;
        }

        // Map pixel coordinates to -1..1.
        float2 uvBase = (float2)pixel / float2(uniforms.width, uniforms.height);
        
        float3 totalAccumulatedColor = float3(0.0f, 0.0f, 0.0f);
        
        for (unsigned int s = 0; s < uniforms.samplesPerPixel; s++) {
            float2 currentPixel = pixel;
            
            // For Halton sequence, we need a unique index for each sample.
            // We use (frameIndex * samplesPerPixel + s) to ensure sequential samples across frames.
            unsigned int sampleIndex = uniforms.frameIndex * uniforms.samplesPerPixel + s;

            if (uniforms.temporalDenoiserEnabled) {
                currentPixel += 0.5f + uniforms.jitter;
            } else {
                // Add a random offset to the pixel coordinates for antialiasing.
                float2 r = float2(halton(offset + sampleIndex, 0),
                                  halton(offset + sampleIndex, 1));
                currentPixel += r;
            }

            float2 uv = (float2)currentPixel / float2(uniforms.width, uniforms.height);
            uv = uv * 2.0f - 1.0f;

            constant Camera & camera = uniforms.camera;

            // Rays start at the camera position.
            ray.origin = camera.position;

            // Map normalized pixel coordinates into camera's coordinate system.
            ray.direction = normalize(uv.x * camera.right +
                                      uv.y * camera.up +
                                      camera.forward);

            // Don't limit intersection distance.
            ray.max_distance = INFINITY;

            // Start with a fully white color. The kernel scales the light each time the
            // ray bounces off of a surface, based on how much of each light component
            // the surface absorbs.
            float3 color = float3(1.0f, 1.0f, 1.0f);

            float3 sampleAccumulatedColor = float3(0.0f, 0.0f, 0.0f);

            // Create an intersector to test for intersection between the ray and the geometry in the scene.
            intersector<triangle_data, instancing> i;

            // If the sample isn't using intersection functions, provide some hints to Metal for
            // better performance.
            if (!useIntersectionFunctions) {
                i.assume_geometry_type(geometry_type::triangle);
                i.force_opacity(forced_opacity::opaque);
            }

            typename intersector<triangle_data, instancing>::result_type intersection;

            // Simulate up to three ray bounces. Each bounce propagates light backward along the
            // ray's path toward the camera.
            for (int bounce = 0; bounce < 3; bounce++) {
                // Get the closest intersection, not the first intersection. This is the default, but
                // the sample adjusts this property below when it casts shadow rays.
                i.accept_any_intersection(false);

                // Check for intersection between the ray and the acceleration structure. If the sample
                // isn't using intersection functions, it doesn't need to include one.
                if (useIntersectionFunctions)
                    intersection = i.intersect(ray, accelerationStructure, bounce == 0 ? RAY_MASK_PRIMARY : RAY_MASK_SECONDARY, intersectionFunctionTable);
                else
                    intersection = i.intersect(ray, accelerationStructure, bounce == 0 ? RAY_MASK_PRIMARY : RAY_MASK_SECONDARY);

                // Stop if the ray didn't hit anything and has bounced out of the scene.
                if (intersection.type == intersection_type::none)
                    break;

                unsigned int instanceIndex = intersection.instance_id;

                // Look up the mask for this instance, which indicates what type of geometry the ray hit.
                unsigned int mask = intersection.instance_id < 0xFFFFFFFF ? instances[instanceIndex].mask : 0;

                // If the ray hit a light source, set the color to white, and stop immediately.
                if (mask == GEOMETRY_MASK_LIGHT) {
                    sampleAccumulatedColor = float3(1.0f, 1.0f, 1.0f);
                    break;
                }

                // The ray hit something. Look up the transformation matrix for this instance.
                float4x4 objectToWorldSpaceTransform(1.0f);

                for (int column = 0; column < 4; column++)
                    for (int row = 0; row < 3; row++)
                        objectToWorldSpaceTransform[column][row] = instances[instanceIndex].transformationMatrix[column][row];

                // Compute the intersection point in world space.
                float3 worldSpaceIntersectionPoint = ray.origin + ray.direction * intersection.distance;

                unsigned primitiveIndex = intersection.primitive_id;
                unsigned int geometryIndex = instances[instanceIndex].accelerationStructureIndex;
                float2 barycentric_coords = intersection.triangle_barycentric_coord;

                float3 worldSpaceSurfaceNormal = 0.0f;
                float3 surfaceColor = 0.0f;

                if (mask & GEOMETRY_MASK_TRIANGLE) {
                    Triangle triangle;
                    
                    float3 objectSpaceSurfaceNormal;
    #if SUPPORTS_METAL_3
                    if (usePerPrimitiveData) {
                        // Per-primitive data points to data from the specified buffer as was configured in the MTLAccelerationStructureTriangleGeometryDescriptor.
                        triangle = *(const device Triangle*)intersection.primitive_data;
                    } else
    #endif
                    {
                        // The ray hit a triangle. Look up the corresponding geometry's normal and UV buffers.
                        device TriangleResources & triangleResources = *(device TriangleResources *)((device char *)resources + resourcesStride * geometryIndex);

                        triangle.normals[0] =  triangleResources.vertexNormals[triangleResources.indices[primitiveIndex * 3 + 0]];
                        triangle.normals[1] =  triangleResources.vertexNormals[triangleResources.indices[primitiveIndex * 3 + 1]];
                        triangle.normals[2] =  triangleResources.vertexNormals[triangleResources.indices[primitiveIndex * 3 + 2]];

                        triangle.colors[0] =  triangleResources.vertexColors[triangleResources.indices[primitiveIndex * 3 + 0]];
                        triangle.colors[1] =  triangleResources.vertexColors[triangleResources.indices[primitiveIndex * 3 + 1]];
                        triangle.colors[2] =  triangleResources.vertexColors[triangleResources.indices[primitiveIndex * 3 + 2]];
                    }
                    
                    // Interpolate the vertex normal at the intersection point.
                    objectSpaceSurfaceNormal = interpolateVertexAttribute(triangle.normals, barycentric_coords);

                    // Interpolate the vertex color at the intersection point.
                    surfaceColor = interpolateVertexAttribute(triangle.colors, barycentric_coords);

                    // Transform the normal from object to world space.
                    worldSpaceSurfaceNormal = normalize(transformDirection(objectSpaceSurfaceNormal, objectToWorldSpaceTransform));
                }
                else if (mask & GEOMETRY_MASK_SPHERE) {
                    Sphere sphere;
    #if SUPPORTS_METAL_3
                    if (usePerPrimitiveData) {
                        // Per-primitive data points to data from the specified buffer as was configured in the MTLAccelerationStructureBoundingBoxGeometryDescriptor.
                        sphere = *(const device Sphere*)intersection.primitive_data;
                    } else
    #endif
                    {
                        // The ray hit a sphere. Look up the corresponding sphere buffer.
                        device SphereResources & sphereResources = *(device SphereResources *)((device char *)resources + resourcesStride * geometryIndex);
                        sphere = sphereResources.spheres[primitiveIndex];
                    }

                    // Transform the sphere's origin from object space to world space.
                    float3 worldSpaceOrigin = transformPoint(sphere.origin, objectToWorldSpaceTransform);

                    // Compute the surface normal directly in world space.
                    worldSpaceSurfaceNormal = normalize(worldSpaceIntersectionPoint - worldSpaceOrigin);

                    // The sphere is a uniform color, so you don't need to interpolate the color across the surface.
                    surfaceColor = sphere.color;
                }

                float3 surfaceSpecularAlbedo = float3(uniforms.materialSpecular);
                float surfaceRoughness = uniforms.materialRoughness;

                // Choose a random light source to sample.
                float lightSample = halton(offset + sampleIndex, 2 + bounce * 5 + 0);
                unsigned int lightIndex = min((unsigned int)(lightSample * uniforms.lightCount), uniforms.lightCount - 1);

                // Choose a random point to sample on the light source.
                float2 r = float2(halton(offset + sampleIndex, 2 + bounce * 5 + 1),
                                  halton(offset + sampleIndex, 2 + bounce * 5 + 2));

                float3 worldSpaceLightDirection;
                float3 lightColor;
                float lightDistance;

                // Sample the lighting between the intersection point and the point on the area light.
                sampleAreaLight(areaLights[lightIndex], r, worldSpaceIntersectionPoint, worldSpaceLightDirection,
                                lightColor, lightDistance);

                // Scale the light color by the cosine of the angle between the light direction and
                // surface normal.
                lightColor *= saturate(dot(worldSpaceSurfaceNormal, worldSpaceLightDirection));

                // Scale the light color by the number of lights to compensate for the fact that
                // the sample samples only one light source at random.
                lightColor *= uniforms.lightCount;

                // Scale the ray color by the color of the surface to simulate the surface absorbing light.
                color *= surfaceColor;

                // Compute the shadow ray. The shadow ray checks whether the sample position on the
                // light source is visible from the current intersection point.
                // If it is, the kernel adds lighting to the output image.
                struct ray shadowRay;

                // Add a small offset to the intersection point to avoid intersecting the same
                // triangle again.
                shadowRay.origin = worldSpaceIntersectionPoint + worldSpaceSurfaceNormal * 1e-3f;

                // Travel toward the light source.
                shadowRay.direction = worldSpaceLightDirection;

                // Don't overshoot the light source.
                shadowRay.max_distance = lightDistance - 1e-3f;

                // Shadow rays check only whether there is an object between the intersection point
                // and the light source. Tell Metal to return after finding any intersection.
                i.accept_any_intersection(true);

                if (useIntersectionFunctions)
                    intersection = i.intersect(shadowRay, accelerationStructure, RAY_MASK_SHADOW, intersectionFunctionTable);
                else
                    intersection = i.intersect(shadowRay, accelerationStructure, RAY_MASK_SHADOW);

                // If there was no intersection, then the light source is visible from the original
                // intersection  point. Add the light's contribution to the image.
                if (intersection.type == intersection_type::none)
                    sampleAccumulatedColor += lightColor * color;

                // Choose a random direction to continue the path of the ray. This causes light to
                // bounce between surfaces. An app might evaluate a more complicated equation to
                // calculate the amount of light that reflects between intersection points.  However,
                // all the math in this kernel cancels out because this app assumes a simple diffuse
                // BRDF and samples the rays with a cosine distribution over the hemisphere (importance
                // sampling). This requires that the kernel only multiply the colors together. This
                // sampling strategy also reduces the amount of noise in the output image.
                r = float2(halton(offset + sampleIndex, 2 + bounce * 5 + 3),
                           halton(offset + sampleIndex, 2 + bounce * 5 + 4));

                float3 worldSpaceSampleDirection = sampleCosineWeightedHemisphere(r);
                worldSpaceSampleDirection = alignHemisphereWithNormal(worldSpaceSampleDirection, worldSpaceSurfaceNormal);

                ray.origin = worldSpaceIntersectionPoint + worldSpaceSurfaceNormal * 1e-3f;
                ray.direction = worldSpaceSampleDirection;
            }
            
            totalAccumulatedColor += sampleAccumulatedColor;
        }
        
        float3 currentFrameColor = totalAccumulatedColor / (float)uniforms.samplesPerPixel;

        noisyColorTex.write(float4(currentFrameColor, 1.0f), tid);

        // Average this frame's sample with all of the previous frames.
        if (uniforms.frameIndex > 0) {
            float3 prevColor = prevTex.read(tid).xyz;
            prevColor *= uniforms.frameIndex;

            currentFrameColor += prevColor;
            currentFrameColor /= (uniforms.frameIndex + 1);
        }

        dstTex.write(float4(currentFrameColor, 1.0f), tid);
    }
}

// Screen filling quad in normalized device coordinates.
constant float2 quadVertices[] = {
    float2(-1, -1),
    float2(-1,  1),
    float2( 1,  1),
    float2(-1, -1),
    float2( 1,  1),
    float2( 1, -1)
};

struct CopyVertexOut {
    float4 position [[position]];
    float2 uv;
};

// Simple vertex shader that passes through NDC quad positions.
vertex CopyVertexOut copyVertex(unsigned short vid [[vertex_id]]) {
    float2 position = quadVertices[vid];

    CopyVertexOut out;

    out.position = float4(position, 0, 1);
    out.uv = position * 0.5f + 0.5f;

    return out;
}

// Simple fragment shader that copies a texture and applies a simple tonemapping function.
fragment float4 copyFragment(CopyVertexOut in [[stage_in]],
                             texture2d<float> tex)
{
    constexpr sampler sam(min_filter::nearest, mag_filter::nearest, mip_filter::none);

    float3 color = tex.sample(sam, in.uv).xyz;

    // The input is now 8-bit sRGB, so we skip the manual tonemapping.
    // color = color / (1.0f + color);

    return float4(color, 1.0f);
}

// Fragment shader that directly copies a texture without tonemapping (e.g. for Diffuse Albedo)
fragment float4 copyForwardFragment(CopyVertexOut in [[stage_in]],
                                    texture2d<float> tex)
{
    constexpr sampler sam(min_filter::nearest, mag_filter::nearest, mip_filter::none);
    float3 color = tex.sample(sam, in.uv).xyz;
    return float4(color, 1.0f);
}

// Fragment shader that visualizes 32-bit float non-linear depth as greyscale
fragment float4 copyDepthFragment(CopyVertexOut in [[stage_in]],
                                  depth2d<float> tex)
{
    constexpr sampler sam(min_filter::nearest, mag_filter::nearest, mip_filter::none);
    constexpr float debugNearPlane = 0.05f;
    constexpr float debugFarPlane = 20.0f;
    constexpr float debugVisibleDepth = 15.0f;

    float deviceDepth = tex.sample(sam, in.uv);
    if (deviceDepth >= 0.99999f) {
        return float4(0.0f, 0.0f, 0.0f, 1.0f);
    }

    float linearDepth = (debugNearPlane * debugFarPlane) /
                        max(debugFarPlane - deviceDepth * (debugFarPlane - debugNearPlane), 1e-6f);
    
    // Normalize to [0, 1] over visible range
    float depthT = saturate((linearDepth - debugNearPlane) / (debugVisibleDepth - debugNearPlane));
    // Heatmap: 1.0 (Near) = Red, 0.0 (Far) = Blue
    float t = 1.0f - depthT;
    
    float3 color;
    if (t < 0.25f) {
        color = mix(float3(0.0f, 0.0f, 1.0f), float3(0.0f, 1.0f, 1.0f), t / 0.25f);
    } else if (t < 0.5f) {
        color = mix(float3(0.0f, 1.0f, 1.0f), float3(0.0f, 1.0f, 0.0f), (t - 0.25f) / 0.25f);
    } else if (t < 0.75f) {
        color = mix(float3(0.0f, 1.0f, 0.0f), float3(1.0f, 1.0f, 0.0f), (t - 0.5f) / 0.25f);
    } else {
        color = mix(float3(1.0f, 1.0f, 0.0f), float3(1.0f, 0.0f, 0.0f), (t - 0.75f) / 0.25f);
    }

    return float4(color, 1.0f);
}

fragment float4 copyNormalFragment(CopyVertexOut in [[stage_in]],
                                   texture2d<float> tex)
{
    constexpr sampler sam(min_filter::nearest, mag_filter::nearest, mip_filter::none);
    float3 normal = tex.sample(sam, in.uv).xyz;
    // Map normal from [-1, 1] to [0, 1] for visualization
    float3 color = normal * 0.5f + 0.5f;
    return float4(color, 1.0f);
}

fragment float4 copySpecularFragment(CopyVertexOut in [[stage_in]],
                                     texture2d<float> tex)
{
    constexpr sampler sam(min_filter::nearest, mag_filter::nearest, mip_filter::none);
    float3 color = tex.sample(sam, in.uv).xyz;
    return float4(color, 1.0f);
}

fragment float4 copyRoughnessFragment(CopyVertexOut in [[stage_in]],
                                      texture2d<float> tex)
{
    constexpr sampler sam(min_filter::nearest, mag_filter::nearest, mip_filter::none);
    float roughness = tex.sample(sam, in.uv).x;
    return float4(roughness, roughness, roughness, 1.0f);
}

fragment float4 copyMotionFragment(CopyVertexOut in [[stage_in]],
                                   texture2d<float> tex)
{
    constexpr sampler sam(min_filter::nearest, mag_filter::nearest, mip_filter::none);
    float2 motion = tex.sample(sam, in.uv).xy;
    // Visualize motion vectors using red and green channels
    // Assuming motion vectors are small, scale them up for visibility, and shift to 0.5 center.
    float2 color = motion * 10.0f + 0.5f;
    return float4(color.x, color.y, 0.0f, 1.0f);
}

// -------------------------------------------------------------------------------------------------
// G-Buffer Rasterization Shaders
// -------------------------------------------------------------------------------------------------

struct GBufferVertexOut {
    float4 position [[position]];
    float3 worldNormal;
    float3 color;
    float4 currentClipPosition;
    float4 previousClipPosition;
};

struct GBufferFragmentOut {
    float2 motion [[color(0)]];
    float4 diffuseAlbedo [[color(1)]];
    float4 specularAlbedo [[color(2)]];
    float4 normal [[color(3)]];
    float roughness [[color(4)]];
    float depth [[depth(any)]];
};

vertex GBufferVertexOut vertexGBufferTriangle(
    uint vertexID [[vertex_id]],
    constant float3 *positions [[buffer(0)]],
    constant float3 *normals   [[buffer(1)]],
    constant float3 *colors    [[buffer(2)]],
    constant float4x4 & objectToWorldTransform [[buffer(3)]],
    constant Uniforms & uniforms [[buffer(4)]])
{
    float3 position = positions[vertexID];
    float3 normal = normals[vertexID];
    float3 color = colors[vertexID];

    GBufferVertexOut out;
    float4 worldPosition = objectToWorldTransform * float4(position, 1.0f);
    
    // Use the inverse-transpose so non-uniformly scaled boxes produce correct guide normals.
    float3x3 objectToWorld3x3 = float3x3(objectToWorldTransform[0].xyz,
                                         objectToWorldTransform[1].xyz,
                                         objectToWorldTransform[2].xyz);
    float3x3 normalMatrix = inverseTranspose3x3(objectToWorld3x3);
    out.worldNormal = normalize(normalMatrix * normal);
    out.color = color;

    // Calculate clip position without jitter for geometry depth/motion
    float4 currentViewPosition = uniforms.worldToViewMatrix * worldPosition;
    float4 currentClipPosition = uniforms.viewToClipMatrix * currentViewPosition;
    out.currentClipPosition = currentClipPosition;
    
    float4 previousViewPosition = uniforms.previousWorldToViewMatrix * worldPosition;
    out.previousClipPosition = uniforms.previousViewToClipMatrix * previousViewPosition;

    // Apply jitter to rasterized position so it aligns with the raytraced noisy color pixels
    if (uniforms.temporalDenoiserEnabled) {
        currentClipPosition.xy += uniforms.jitter * 2.0f * currentClipPosition.w / float2(uniforms.width, uniforms.height);
    }
    out.position = currentClipPosition;

    return out;
}

fragment GBufferFragmentOut fragmentGBufferTriangle(
    GBufferVertexOut in [[stage_in]],
    constant Uniforms & uniforms [[buffer(0)]])
{
    GBufferFragmentOut out;
    
    float depth = 1.0f;
    float2 motion = 0.0f;
    
    // Normalized device coordinates without jitter for depth/motion calculation
    if (fabs(in.currentClipPosition.w) > 1e-5f) {
        float2 currentNDC = in.currentClipPosition.xy / in.currentClipPosition.w;
        depth = saturate(in.currentClipPosition.z / in.currentClipPosition.w);

        if (fabs(in.previousClipPosition.w) > 1e-5f) {
            float2 previousNDC = in.previousClipPosition.xy / in.previousClipPosition.w;
            float2 currentUV = currentNDC * 0.5f + 0.5f;
            float2 previousUV = previousNDC * 0.5f + 0.5f;
            motion = previousUV - currentUV;
        }
    }

    out.motion = motion;
    out.diffuseAlbedo = float4(in.color, 1.0f);
    out.specularAlbedo = float4(uniforms.materialSpecular, uniforms.materialSpecular, uniforms.materialSpecular, 1.0f);
    out.normal = float4(normalize(in.worldNormal), 1.0f);
    out.roughness = uniforms.materialRoughness;
    out.depth = depth;

    return out;
}

struct GBufferSphereVertexOut {
    float4 position [[position]];
    float3 localPos;
    float3 worldOrigin;
    float worldRadius;
    float3 sColor;
};

vertex GBufferSphereVertexOut vertexGBufferSphere(
    uint vertexID [[vertex_id]],
    uint sphereID [[instance_id]],
    constant Sphere *spheres [[buffer(0)]],
    constant float4x4 & objectToWorldTransform [[buffer(1)]],
    constant Uniforms & uniforms [[buffer(2)]])
{
    // A standard cube's vertices covering [-1, 1] range to act as bounding box for the sphere
    float3 cubeVertices[] = {
        float3(-1, -1, -1), float3( 1, -1, -1), float3(-1,  1, -1), float3( 1,  1, -1),
        float3(-1, -1,  1), float3( 1, -1,  1), float3(-1,  1,  1), float3(  1,  1,  1)
    };
    uint faceIndices[] = {
        0, 4, 6, 0, 6, 2,  // Left
        1, 5, 7, 1, 7, 3,  // Right
        0, 1, 5, 0, 5, 4,  // Bottom
        2, 3, 7, 2, 7, 6,  // Top
        0, 2, 3, 0, 3, 1,  // Back
        4, 5, 7, 4, 7, 6   // Front
    };
    float3 localPos = cubeVertices[faceIndices[vertexID]];
    
    constant auto & sphere = spheres[sphereID];
    
    GBufferSphereVertexOut out;
    out.localPos = localPos;
    out.worldOrigin = (objectToWorldTransform * float4(sphere.origin, 1.0f)).xyz;
    out.worldRadius = sphere.radius * length(objectToWorldTransform[0].xyz);
    out.sColor = sphere.color;
    
    float3 position = sphere.origin + localPos * sphere.radius;
    float4 worldPosition = objectToWorldTransform * float4(position, 1.0f);
    
    float4 currentViewPosition = uniforms.worldToViewMatrix * worldPosition;
    float4 currentClipPosition = uniforms.viewToClipMatrix * currentViewPosition;
    
    if (uniforms.temporalDenoiserEnabled) {
        currentClipPosition.xy += uniforms.jitter * 2.0f * currentClipPosition.w / float2(uniforms.width, uniforms.height);
    }
    out.position = currentClipPosition;

    return out;
}

fragment GBufferFragmentOut fragmentGBufferSphere(
    GBufferSphereVertexOut in [[stage_in]],
    constant Uniforms & uniforms [[buffer(0)]])
{
    // For proper sphere impostor, we compute ray-sphere intersection in world space
    // Ray origin is the camera position transformed to local space
    
    // Instead of full raycasting, simplify by treating the bounding box fragment as the sphere.
    // To match raytraced accurate spheres, we must raycast from camera to the pixel.
    
    float2 pixel = float2(in.position.x, in.position.y);
    float2 uv = pixel / float2(uniforms.width, uniforms.height);
    uv = uv * 2.0f - 1.0f;
    
    // Unjitter the uv for the intersection
    if (uniforms.temporalDenoiserEnabled) {
        uv -= uniforms.jitter * 2.0f / float2(uniforms.width, uniforms.height);
    }
    
    float3 rayOrigin = uniforms.camera.position;
    float3 rayDirection = normalize(uv.x * uniforms.camera.right + uv.y * uniforms.camera.up + uniforms.camera.forward);
    
    float3 worldOrigin = in.worldOrigin;
    float3 oc = rayOrigin - worldOrigin;
    float a = dot(rayDirection, rayDirection);
    float b = 2.0f * dot(oc, rayDirection);
    float c = dot(oc, oc) - in.worldRadius * in.worldRadius;
    float disc = b * b - 4.0f * a * c;
    
    if (disc < 0.0f) {
        discard_fragment();
    }
    
    float t = (-b - sqrt(disc)) / (2.0f * a);
    float3 worldPosition = rayOrigin + rayDirection * t;
    float3 worldNormal = normalize(worldPosition - worldOrigin);
    
    GBufferFragmentOut out;
    float depth = 1.0f;
    float2 motion = 0.0f;
    
    float4 currentViewPosition = uniforms.worldToViewMatrix * float4(worldPosition, 1.0f);
    float4 currentClipPosition = uniforms.viewToClipMatrix * currentViewPosition;
    float4 previousViewPosition = uniforms.previousWorldToViewMatrix * float4(worldPosition, 1.0f);
    float4 previousClipPosition = uniforms.previousViewToClipMatrix * previousViewPosition;
    
    if (fabs(currentClipPosition.w) > 1e-5f) {
        float2 currentNDC = currentClipPosition.xy / currentClipPosition.w;
        depth = saturate(currentClipPosition.z / currentClipPosition.w);

        if (fabs(previousClipPosition.w) > 1e-5f) {
            float2 previousNDC = previousClipPosition.xy / previousClipPosition.w;
            float2 currentUV = currentNDC * 0.5f + 0.5f;
            float2 previousUV = previousNDC * 0.5f + 0.5f;
            motion = previousUV - currentUV;
        }
    }
    
    out.motion = motion;
    out.diffuseAlbedo = float4(in.sColor, 1.0f);
    out.specularAlbedo = float4(uniforms.materialSpecular, uniforms.materialSpecular, uniforms.materialSpecular, 1.0f);
    out.normal = float4(worldNormal, 1.0f);
    out.roughness = uniforms.materialRoughness;
    out.depth = depth;
    
    return out;
}
