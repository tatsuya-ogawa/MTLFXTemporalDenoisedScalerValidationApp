/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
The implementation of the renderer class that performs Metal setup and per-frame rendering.
*/

#import <simd/simd.h>
#import <QuartzCore/QuartzCore.h>

#if __has_include(<MetalFX/MetalFX.h>)
#import <MetalFX/MetalFX.h>
#define SUPPORTS_METALFX_FRAMEWORK 1
#else
#define SUPPORTS_METALFX_FRAMEWORK 0
#endif

#import "Renderer.h"
#import "Transforms.h"
#import "ShaderTypes.h"
#import "Scene.h"

using namespace simd;

static const NSUInteger maxFramesInFlight = 3;
static const size_t alignedUniformsSize = (sizeof(Uniforms) + 255) & ~255;
static const float fieldOfViewRadians = 45.0f * (M_PI / 180.0f);
static const float nearPlane = 0.05f;
static const float farPlane = 20.0f;
static const CFTimeInterval statisticsUpdateInterval = 0.25;

static float haltonJitter(NSUInteger index, NSUInteger base)
{
    float fraction = 1.0f;
    float result = 0.0f;

    while (index > 0) {
        fraction /= base;
        result += fraction * (index % base);
        index /= base;
    }

    return result;
}

static matrix_float4x4 worldToViewMatrix(vector_float3 position,
                                         vector_float3 target,
                                         vector_float3 up)
{
    vector_float3 forward = vector_normalize(target - position);
    vector_float3 right = vector_normalize(vector_cross(forward, up));
    vector_float3 correctedUp = vector_normalize(vector_cross(right, forward));

    return (matrix_float4x4) {{
        { right.x, correctedUp.x, forward.x, 0.0f },
        { right.y, correctedUp.y, forward.y, 0.0f },
        { right.z, correctedUp.z, forward.z, 0.0f },
        { -vector_dot(right, position), -vector_dot(correctedUp, position), -vector_dot(forward, position), 1.0f }
    }};
}

static matrix_float4x4 viewToClipMatrix(float aspectRatio)
{
    float yScale = -1.0f / tanf(fieldOfViewRadians * 0.5f);
    float xScale = -yScale / aspectRatio; // Should be positive to match the raytracer's X axis
    float zScale = farPlane / (farPlane - nearPlane);
    float wzScale = (-nearPlane * farPlane) / (farPlane - nearPlane);

    return (matrix_float4x4) {{
        { xScale, 0.0f, 0.0f, 0.0f },
        { 0.0f, yScale, 0.0f, 0.0f },
        { 0.0f, 0.0f, zScale, 1.0f },
        { 0.0f, 0.0f, wzScale, 0.0f }
    }};
}

@implementation Renderer
{
    id <MTLDevice> _device;
    id <MTLCommandQueue> _queue;
    id <MTLLibrary> _library;

    id <MTLBuffer> _uniformBuffer;

    id <MTLAccelerationStructure> _instanceAccelerationStructure;
    NSMutableArray *_primitiveAccelerationStructures;

    id <MTLComputePipelineState> _raytracingPipeline;
    id <MTLRenderPipelineState> _copyPipeline;
    id <MTLRenderPipelineState> _copyForwardPipeline;
    id <MTLRenderPipelineState> _copyDepthPipeline;
    id <MTLRenderPipelineState> _copySpecularPipeline;
    id <MTLRenderPipelineState> _copyRoughnessPipeline;
    id <MTLRenderPipelineState> _copyMotionPipeline;
    id <MTLRenderPipelineState> _copyNormalPipeline;

    id <MTLTexture> _accumulationTargets[2];
    id <MTLTexture> _noisyColorTexture;
    
    id <MTLRenderPipelineState> _gBufferTrianglePipeline;
    id <MTLRenderPipelineState> _gBufferSpherePipeline;
    id <MTLDepthStencilState> _gBufferDepthState;
    id <MTLTexture> _actualDepthTexture;
    id <MTLTexture> _disabledDepthTexture;
    id <MTLTexture> _motionTexture;
    id <MTLTexture> _disabledMotionTexture;
    id <MTLTexture> _diffuseAlbedoTexture;
    id <MTLTexture> _specularAlbedoTexture;
    id <MTLTexture> _normalTexture;
    id <MTLTexture> _roughnessTexture;
    id <MTLTexture> _exposureTexture;
    id <MTLTexture> _metalFXOutputTexture;
    id <MTLTexture> _randomTexture;

#if SUPPORTS_METALFX_FRAMEWORK
    id <MTLFXTemporalDenoisedScaler> _temporalDenoisedScaler;
#endif

    id <MTLBuffer> _resourceBuffer;
    id <MTLBuffer> _instanceBuffer;

    id <MTLIntersectionFunctionTable> _intersectionFunctionTable;

    dispatch_semaphore_t _sem;
    CGSize _size;
    NSUInteger _uniformBufferOffset;
    NSUInteger _uniformBufferIndex;

    unsigned int _frameIndex;
    bool _metalFXRequestedEnabled;
    bool _metalFXEnabled;
    RendererDenoiserMode _denoiserMode;
    bool _metalFXUsesJitter;
    bool _metalFXUsesDepthTexture;
    bool _metalFXUsesMotionTexture;
    bool _metalFXUsesMotionVectorScale;
    bool _metalFXUsesWorldToViewMatrix;
    bool _metalFXUsesViewToClipMatrix;
    bool _metalFXAutoExposureEnabled;
    float _metalFXManualExposure;
    bool _needsResetHistory;
    matrix_float4x4 _previousWorldToViewMatrix;
    matrix_float4x4 _previousViewToClipMatrix;
    bool _hdrEnabled;

    Scene *_scene;

    NSUInteger _resourcesStride;
    bool _useIntersectionFunctions;
    bool _usePerPrimitiveData;
    NSUInteger _samplesPerPixel;
    CFTimeInterval _lastFrameTimestamp;
    CFTimeInterval _statisticsSampleStart;
    NSUInteger _framesSinceLastStatisticsSample;
    float _averageFramesPerSecond;
    float _averageFrameTimeMS;
}

- (void)updateExposureTexture
{
    if (!_exposureTexture) {
        return;
    }

    float clampedExposure = fmaxf(0.01f, _metalFXManualExposure);
    __fp16 exposureValue = (__fp16)clampedExposure;
    [_exposureTexture replaceRegion:MTLRegionMake2D(0, 0, 1, 1)
                        mipmapLevel:0
                          withBytes:&exposureValue
                        bytesPerRow:sizeof(__fp16)];
}

- (nonnull instancetype)initWithDevice:(nonnull id<MTLDevice>)device
                                 scene:(Scene *)scene
{
    self = [super init];

    if (self)
    {
        _device = device;
        _denoiserMode = RendererDenoiserModeDenoised;
        _metalFXRequestedEnabled = true;
        _metalFXEnabled = false;
        _metalFXUsesJitter = true;
        _metalFXUsesDepthTexture = true;
        _metalFXUsesMotionTexture = true;
        _metalFXUsesMotionVectorScale = true;
        _metalFXUsesWorldToViewMatrix = true;
        _metalFXUsesViewToClipMatrix = true;
        _metalFXAutoExposureEnabled = false;
        _metalFXManualExposure = 1.0f;
        _roughness = 0.0f;
        _specularAlbedo = 0.0f;
        _needsResetHistory = true;
        _previousWorldToViewMatrix = matrix_identity_float4x4;
        _previousViewToClipMatrix = matrix_identity_float4x4;
        _hdrEnabled = true;
        _samplesPerPixel = 4;

        _sem = dispatch_semaphore_create(maxFramesInFlight);

        _scene = scene;

        [self loadMetal];
        [self createBuffers];
        [self createAccelerationStructures];
        [self createPipelines];
    }

    return self;
}

// Initialize the Metal shader library and command queue.
- (void)loadMetal
{
    _library = [_device newDefaultLibrary];

    _queue = [_device newCommandQueue];
}

// Create a compute pipeline state with an optional array of additional functions to link the compute
// function with. The sample uses this to link the ray-tracing kernel with any intersection functions.
- (id <MTLComputePipelineState>)newComputePipelineStateWithFunction:(id <MTLFunction>)function
                                                    linkedFunctions:(NSArray <id <MTLFunction>> *)linkedFunctions
{
    MTLLinkedFunctions *mtlLinkedFunctions = nil;

    // Attach the additional functions to an MTLLinkedFunctions object
    if (linkedFunctions) {
        mtlLinkedFunctions = [[MTLLinkedFunctions alloc] init];

        mtlLinkedFunctions.functions = linkedFunctions;
    }

    MTLComputePipelineDescriptor *descriptor = [[MTLComputePipelineDescriptor alloc] init];

    // Set the main compute function.
    descriptor.computeFunction = function;

    // Attach the linked functions object to the compute pipeline descriptor.
    descriptor.linkedFunctions = mtlLinkedFunctions;

    // Set to YES to allow the compiler to make certain optimizations.
    descriptor.threadGroupSizeIsMultipleOfThreadExecutionWidth = YES;

    NSError *error;

    // Create the compute pipeline state.
    id <MTLComputePipelineState> pipeline = [_device newComputePipelineStateWithDescriptor:descriptor
                                                                                   options:0
                                                                                reflection:nil
                                                                                     error:&error];
    NSAssert(pipeline, @"Failed to create %@ pipeline state: %@", function.name, error);

    return pipeline;
}

// Create a compute function, and specialize its function constants.
- (id <MTLFunction>)specializedFunctionWithName:(NSString *)name {
    // Fill out a dictionary of function constant values.
    MTLFunctionConstantValues *constants = [[MTLFunctionConstantValues alloc] init];

    // The first constant is the stride between entries in the resource buffer. The sample
    // uses this stride to allow intersection functions to look up any resources they use.
    uint32_t resourcesStride = (uint32_t)_resourcesStride;
    [constants setConstantValue:&resourcesStride type:MTLDataTypeUInt atIndex:0];

    // The second constant turns the use of intersection functions on and off.
    [constants setConstantValue:&_useIntersectionFunctions type:MTLDataTypeBool atIndex:1];

    // The third constant turns the use of intersection functions on and off.
    [constants setConstantValue:&_usePerPrimitiveData type:MTLDataTypeBool atIndex:2];

    NSError *error;

    // Load the function from the Metal library.
    id <MTLFunction> function = [_library newFunctionWithName:name constantValues:constants error:&error];

    NSAssert(function, @"Failed to create function %@: %@", name, error, function.name, error);

    return function;
}

// Create pipeline states.
- (void)createPipelines
{
    _useIntersectionFunctions = false;
#if SUPPORTS_METAL_3
    _usePerPrimitiveData = true;
#else
    _usePerPrimitiveData = false;
#endif

    // Check if any scene geometry has an intersection function.
    for (Geometry *geometry in _scene.geometries) {
        if (geometry.intersectionFunctionName) {
            _useIntersectionFunctions = true;
            break;
        }
    }

    // Maps intersection function names to actual MTLFunctions.
    NSMutableDictionary <NSString *, id <MTLFunction>> *intersectionFunctions = [NSMutableDictionary dictionary];

    // First, load all the intersection functions because the sample needs them to create the final
    // ray-tracing compute pipeline state.
    for (Geometry *geometry in _scene.geometries) {
        // Skip if the geometry doesn't have an intersection function or if the app already loaded
        // it.
        if (!geometry.intersectionFunctionName || [intersectionFunctions objectForKey:geometry.intersectionFunctionName])
            continue;

        // Specialize function constants the intersection function uses.
        id <MTLFunction> intersectionFunction = [self specializedFunctionWithName:geometry.intersectionFunctionName];

        // Add the function to the dictionary.
        intersectionFunctions[geometry.intersectionFunctionName] = intersectionFunction;
    }

    id <MTLFunction> raytracingFunction = [self specializedFunctionWithName:@"raytracingKernel"];

    // Create the compute pipeline state, which does all the ray tracing.
    _raytracingPipeline = [self newComputePipelineStateWithFunction:raytracingFunction
                                                    linkedFunctions:[intersectionFunctions allValues]];

    // Create the intersection function table.
    if (_useIntersectionFunctions) {
        MTLIntersectionFunctionTableDescriptor *intersectionFunctionTableDescriptor = [[MTLIntersectionFunctionTableDescriptor alloc] init];

        intersectionFunctionTableDescriptor.functionCount = _scene.geometries.count;

        // Create a table large enough to hold all of the intersection functions. Metal
        // links intersection functions into the compute pipeline state, potentially with
        // a different address for each compute pipeline. Therefore, the intersection
        // function table is specific to the compute pipeline state that created it, and you
        // can use it with only that pipeline.
        _intersectionFunctionTable = [_raytracingPipeline newIntersectionFunctionTableWithDescriptor:intersectionFunctionTableDescriptor];

        if (!_usePerPrimitiveData) {
            // Bind the buffer used to pass resources to the intersection functions.
            [_intersectionFunctionTable setBuffer:_resourceBuffer offset:0 atIndex:0];
        }

    // Map each piece of scene geometry to its intersection function.
        for (NSUInteger geometryIndex = 0; geometryIndex < _scene.geometries.count; geometryIndex++) {
            Geometry *geometry = _scene.geometries[geometryIndex];

            if (geometry.intersectionFunctionName) {
                id <MTLFunction> intersectionFunction = intersectionFunctions[geometry.intersectionFunctionName];

                // Create a handle to the copy of the intersection function linked into the
                // ray-tracing compute pipeline state. Create a different handle for each pipeline
                // it is linked with.
                id <MTLFunctionHandle> handle = [_raytracingPipeline functionHandleWithFunction:intersectionFunction];

                // Insert the handle into the intersection function table, which ultimately maps the
                // geometry's index to its intersection function.
                [_intersectionFunctionTable setFunction:handle atIndex:geometryIndex];
            }
        }
    }

    MTLDepthStencilDescriptor *depthDesc = [[MTLDepthStencilDescriptor alloc] init];
    depthDesc.depthCompareFunction = MTLCompareFunctionLess;
    depthDesc.depthWriteEnabled = YES;
    _gBufferDepthState = [_device newDepthStencilStateWithDescriptor:depthDesc];

    MTLRenderPipelineDescriptor *gBufferDesc = [[MTLRenderPipelineDescriptor alloc] init];
    gBufferDesc.colorAttachments[0].pixelFormat = MTLPixelFormatRG16Float;     // Motion
    gBufferDesc.colorAttachments[1].pixelFormat = MTLPixelFormatRGBA16Float;   // Diffuse
    gBufferDesc.colorAttachments[2].pixelFormat = MTLPixelFormatRGBA16Float;   // Specular
    gBufferDesc.colorAttachments[3].pixelFormat = MTLPixelFormatRGBA16Float;   // Normal
    gBufferDesc.colorAttachments[4].pixelFormat = MTLPixelFormatR16Float;      // Roughness
    gBufferDesc.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;

    NSError *error;

    gBufferDesc.vertexFunction = [_library newFunctionWithName:@"vertexGBufferTriangle"];
    gBufferDesc.fragmentFunction = [_library newFunctionWithName:@"fragmentGBufferTriangle"];
    _gBufferTrianglePipeline = [_device newRenderPipelineStateWithDescriptor:gBufferDesc error:&error];
    NSAssert(_gBufferTrianglePipeline, @"Failed to create the G-Buffer Triangle pipeline state: %@", error);

    gBufferDesc.vertexFunction = [_library newFunctionWithName:@"vertexGBufferSphere"];
    gBufferDesc.fragmentFunction = [_library newFunctionWithName:@"fragmentGBufferSphere"];
    _gBufferSpherePipeline = [_device newRenderPipelineStateWithDescriptor:gBufferDesc error:&error];
    NSAssert(_gBufferSpherePipeline, @"Failed to create the G-Buffer Sphere pipeline state: %@", error);

    // Create a render pipeline state that copies the rendered scene into the MTKView and
    // performs simple tone mapping.
    MTLRenderPipelineDescriptor *renderDescriptor = [[MTLRenderPipelineDescriptor alloc] init];

    renderDescriptor.vertexFunction = [_library newFunctionWithName:@"copyVertex"];
    renderDescriptor.fragmentFunction = [_library newFunctionWithName:@"copyFragment"];

    renderDescriptor.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;

    _copyPipeline = [_device newRenderPipelineStateWithDescriptor:renderDescriptor error:&error];
    NSAssert(_copyPipeline, @"Failed to create the copy pipeline state: %@", error);

    renderDescriptor.fragmentFunction = [_library newFunctionWithName:@"copyForwardFragment"];
    _copyForwardPipeline = [_device newRenderPipelineStateWithDescriptor:renderDescriptor error:&error];
    NSAssert(_copyForwardPipeline, @"Failed to create the copy forward pipeline state: %@", error);

    renderDescriptor.fragmentFunction = [_library newFunctionWithName:@"copyDepthFragment"];
    _copyDepthPipeline = [_device newRenderPipelineStateWithDescriptor:renderDescriptor error:&error];
    NSAssert(_copyDepthPipeline, @"Failed to create the copy depth pipeline state: %@", error);

    renderDescriptor.fragmentFunction = [_library newFunctionWithName:@"copyNormalFragment"];
    _copyNormalPipeline = [_device newRenderPipelineStateWithDescriptor:renderDescriptor error:&error];
    NSAssert(_copyNormalPipeline, @"Failed to create the copy normal pipeline state: %@", error);

    renderDescriptor.fragmentFunction = [_library newFunctionWithName:@"copySpecularFragment"];
    _copySpecularPipeline = [_device newRenderPipelineStateWithDescriptor:renderDescriptor error:&error];
    NSAssert(_copySpecularPipeline, @"Failed to create the copy specular pipeline state: %@", error);

    renderDescriptor.fragmentFunction = [_library newFunctionWithName:@"copyRoughnessFragment"];
    _copyRoughnessPipeline = [_device newRenderPipelineStateWithDescriptor:renderDescriptor error:&error];
    NSAssert(_copyRoughnessPipeline, @"Failed to create the copy roughness pipeline state: %@", error);

    renderDescriptor.fragmentFunction = [_library newFunctionWithName:@"copyMotionFragment"];
    _copyMotionPipeline = [_device newRenderPipelineStateWithDescriptor:renderDescriptor error:&error];
    NSAssert(_copyMotionPipeline, @"Failed to create the copy motion pipeline state: %@", error);
}

// Create an argument encoder that encodes references to a set of resources into a buffer.
- (id <MTLArgumentEncoder>)newArgumentEncoderForResources:(NSArray <id <MTLResource>> *)resources {
    NSMutableArray *arguments = [NSMutableArray array];

    for (id <MTLResource> resource in resources) {
        MTLArgumentDescriptor *argumentDescriptor = [MTLArgumentDescriptor argumentDescriptor];

        argumentDescriptor.index = arguments.count;
        argumentDescriptor.access = MTLBindingAccessReadOnly;

        if ([resource conformsToProtocol:@protocol(MTLBuffer)])
            argumentDescriptor.dataType = MTLDataTypePointer;
        else if ([resource conformsToProtocol:@protocol(MTLTexture)]) {
            id <MTLTexture> texture = (id <MTLTexture>)resource;

            argumentDescriptor.dataType = MTLDataTypeTexture;
            argumentDescriptor.textureType = texture.textureType;
        }

        [arguments addObject:argumentDescriptor];
    }

    return [_device newArgumentEncoderWithArguments:arguments];
}

- (void)createBuffers {
    // The uniform buffer contains a few small values, which change from frame to frame. The
    // sample can have up to three frames in flight at the same time, so allocate a range of the buffer
    // for each frame. The GPU reads from one chunk while the CPU writes to the next chunk.
    // Align the chunks to 256 bytes on macOS and 16 bytes on iOS.
    NSUInteger uniformBufferSize = alignedUniformsSize * maxFramesInFlight;

    MTLResourceOptions options = getManagedBufferStorageMode();

    _uniformBuffer = [_device newBufferWithLength:uniformBufferSize options:options];

    // Upload scene data to buffers.
    [_scene uploadToBuffers];

    _resourcesStride = 0;

    // Each intersection function has its own set of resources. Determine the maximum size over all
    // intersection functions. This size becomes the stride that intersection functions use to find
    // the starting address for their resources.
    for (Geometry *geometry in _scene.geometries) {
#if SUPPORTS_METAL_3
        if (geometry.resources.count * sizeof(uint64_t) > _resourcesStride)
            _resourcesStride = geometry.resources.count * sizeof(uint64_t);
#else
        id <MTLArgumentEncoder> encoder = [self newArgumentEncoderForResources:geometry.resources];

        if (encoder.encodedLength > _resourcesStride)
            _resourcesStride = encoder.encodedLength;
#endif
    }

    // Create the resource buffer.
    _resourceBuffer = [_device newBufferWithLength:_resourcesStride * _scene.geometries.count options:options];

    for (NSUInteger geometryIndex = 0; geometryIndex < _scene.geometries.count; geometryIndex++) {
        Geometry *geometry = _scene.geometries[geometryIndex];

#if SUPPORTS_METAL_3
        // Retrieve the list of arguments for this geometry's intersection function's resources.
        NSArray<id <MTLResource>>* resources = [geometry resources];

        // Get a pointer to the resource buffer.
        // Resources can return a gpuAddress or gpuResourceID, which are both the same size as a uint64_t.
        uint64_t *resourceHandles = (uint64_t*)((uint8_t*)_resourceBuffer.contents + _resourcesStride * geometryIndex);

        // Encode the arguments into the resource buffer.
        for (NSUInteger argumentIndex = 0; argumentIndex < resources.count; argumentIndex++) {
            id <MTLResource> resource = resources[argumentIndex];
            if ([resource conformsToProtocol:@protocol(MTLBuffer)])
                resourceHandles[argumentIndex] = [(id <MTLBuffer>)resource gpuAddress];
            else if ([resource conformsToProtocol:@protocol(MTLTexture)])
                *((MTLResourceID*)(resourceHandles + argumentIndex)) = [(id <MTLTexture>)resource gpuResourceID];
        }
#else
        // Create an argument encoder for this geometry's intersection function's resources.
        id <MTLArgumentEncoder> encoder = [self newArgumentEncoderForResources:geometry.resources];

        // Bind the argument encoder to the resource buffer at this geometry's offset.
        [encoder setArgumentBuffer:_resourceBuffer offset:_resourcesStride * geometryIndex];

        // Encode the arguments into the resource buffer.
        for (NSUInteger argumentIndex = 0; argumentIndex < geometry.resources.count; argumentIndex++) {
            id <MTLResource> resource = geometry.resources[argumentIndex];

            if ([resource conformsToProtocol:@protocol(MTLBuffer)])
                [encoder setBuffer:(id <MTLBuffer>)resource offset:0 atIndex:argumentIndex];
            else if ([resource conformsToProtocol:@protocol(MTLTexture)])
                [encoder setTexture:(id <MTLTexture>)resource atIndex:argumentIndex];
        }
#endif
    }

#if !TARGET_OS_IPHONE
    [_resourceBuffer didModifyRange:NSMakeRange(0, _resourceBuffer.length)];
#endif
}

// Create and compact an acceleration structure, given an acceleration structure descriptor.
- (id <MTLAccelerationStructure>)newAccelerationStructureWithDescriptor:(MTLAccelerationStructureDescriptor *)descriptor
{
    // Query for the sizes needed to store and build the acceleration structure.
    MTLAccelerationStructureSizes accelSizes = [_device accelerationStructureSizesWithDescriptor:descriptor];

    // Allocate an acceleration structure large enough for this descriptor. This method
    // doesn't actually build the acceleration structure, but rather allocates memory.
    id <MTLAccelerationStructure> accelerationStructure = [_device newAccelerationStructureWithSize:accelSizes.accelerationStructureSize];

    // Allocate scratch space Metal uses to build the acceleration structure.
    // Use MTLResourceStorageModePrivate for the best performance because the sample
    // doesn't need access to buffer's contents.
    id <MTLBuffer> scratchBuffer = [_device newBufferWithLength:accelSizes.buildScratchBufferSize options:MTLResourceStorageModePrivate];

    // Create a command buffer that performs the acceleration structure build.
    id <MTLCommandBuffer> commandBuffer = [_queue commandBuffer];

    // Create an acceleration structure command encoder.
    id <MTLAccelerationStructureCommandEncoder> commandEncoder = [commandBuffer accelerationStructureCommandEncoder];

    // Allocate a buffer for Metal to write the compacted accelerated structure's size into.
    id <MTLBuffer> compactedSizeBuffer = [_device newBufferWithLength:sizeof(uint32_t) options:MTLResourceStorageModeShared];

    // Schedule the actual acceleration structure build.
    [commandEncoder buildAccelerationStructure:accelerationStructure
                                    descriptor:descriptor
                                 scratchBuffer:scratchBuffer
                           scratchBufferOffset:0];

    // Compute and write the compacted acceleration structure size into the buffer. You
    // must already have a built acceleration structure because Metal determines the compacted
    // size based on the final size of the acceleration structure. Compacting an acceleration
    // structure can potentially reclaim significant amounts of memory because Metal must
    // create the initial structure using a conservative approach.

    [commandEncoder writeCompactedAccelerationStructureSize:accelerationStructure
                                                   toBuffer:compactedSizeBuffer
                                                     offset:0];

    // End encoding, and commit the command buffer so the GPU can start building the
    // acceleration structure.
    [commandEncoder endEncoding];

    [commandBuffer commit];

    // The sample waits for Metal to finish executing the command buffer so that it can
    // read back the compacted size.

    // Note: Don't wait for Metal to finish executing the command buffer if you aren't compacting
    // the acceleration structure, as doing so requires CPU/GPU synchronization. You don't have
    // to compact acceleration structures, but do so when creating large static acceleration
    // structures, such as static scene geometry. Avoid compacting acceleration structures that
    // you rebuild every frame, as the synchronization cost may be significant.

    [commandBuffer waitUntilCompleted];

    uint32_t compactedSize = *(uint32_t *)compactedSizeBuffer.contents;

    // Allocate a smaller acceleration structure based on the returned size.
    id <MTLAccelerationStructure> compactedAccelerationStructure = [_device newAccelerationStructureWithSize:compactedSize];

    // Create another command buffer and encoder.
    commandBuffer = [_queue commandBuffer];

    commandEncoder = [commandBuffer accelerationStructureCommandEncoder];

    // Encode the command to copy and compact the acceleration structure into the
    // smaller acceleration structure.
    [commandEncoder copyAndCompactAccelerationStructure:accelerationStructure
                                toAccelerationStructure:compactedAccelerationStructure];

    // End encoding and commit the command buffer. You don't need to wait for Metal to finish
    // executing this command buffer as long as you synchronize any ray-intersection work
    // to run after this command buffer completes. The sample relies on Metal's default
    // dependency tracking on resources to automatically synchronize access to the new
    // compacted acceleration structure.
    [commandEncoder endEncoding];
    [commandBuffer commit];

    return compactedAccelerationStructure;
}

// Create acceleration structures for the scene. The scene contains primitive acceleration
// structures and an instance acceleration structure. The primitive acceleration structures
// contain primitives, such as triangles and spheres. The instance acceleration structure contains
// copies, or instances, of the primitive acceleration structures, each with their own
// transformation matrix that describes where to place them in the scene.
- (void)createAccelerationStructures
{
    MTLResourceOptions options = getManagedBufferStorageMode();

    _primitiveAccelerationStructures = [[NSMutableArray alloc] init];

    // Create a primitive acceleration structure for each piece of geometry in the scene.
    for (NSUInteger i = 0; i < _scene.geometries.count; i++) {
        Geometry *mesh = _scene.geometries[i];

        MTLAccelerationStructureGeometryDescriptor *geometryDescriptor = [mesh geometryDescriptor];

        // Assign each piece of geometry a consecutive slot in the intersection function table.
        geometryDescriptor.intersectionFunctionTableOffset = i;

        // Create a primitive acceleration structure descriptor to contain the single piece
        // of acceleration structure geometry.
        MTLPrimitiveAccelerationStructureDescriptor *accelDescriptor = [MTLPrimitiveAccelerationStructureDescriptor descriptor];

        accelDescriptor.geometryDescriptors = @[ geometryDescriptor ];

        // Build the acceleration structure.
        id <MTLAccelerationStructure> accelerationStructure = [self newAccelerationStructureWithDescriptor:accelDescriptor];

        // Add the acceleration structure to the array of primitive acceleration structures.
        [_primitiveAccelerationStructures addObject:accelerationStructure];
    }

    // Allocate a buffer of acceleration structure instance descriptors. Each descriptor represents
    // an instance of one of the primitive acceleration structures created above, with its own
    // transformation matrix.
    _instanceBuffer = [_device newBufferWithLength:sizeof(MTLAccelerationStructureInstanceDescriptor) * _scene.instances.count options:options];

    MTLAccelerationStructureInstanceDescriptor *instanceDescriptors = (MTLAccelerationStructureInstanceDescriptor *)_instanceBuffer.contents;

    // Fill out instance descriptors.
    for (NSUInteger instanceIndex = 0; instanceIndex < _scene.instances.count; instanceIndex++) {
        GeometryInstance *instance = _scene.instances[instanceIndex];

        NSUInteger geometryIndex = [_scene.geometries indexOfObject:instance.geometry];

        // Map the instance to its acceleration structure.
        instanceDescriptors[instanceIndex].accelerationStructureIndex = (uint32_t)geometryIndex;

        // Mark the instance as opaque if it doesn't have an intersection function so that the
        // ray intersector doesn't attempt to execute a function that doesn't exist.
        instanceDescriptors[instanceIndex].options = instance.geometry.intersectionFunctionName == nil ? MTLAccelerationStructureInstanceOptionOpaque : 0;

        // Metal adds the geometry intersection function table offset and instance intersection
        // function table offset together to determine which intersection function to execute.
        // The sample mapped geometries directly to their intersection functions above, so it
        // sets the instance's table offset to 0.
        instanceDescriptors[instanceIndex].intersectionFunctionTableOffset = 0;

        // Set the instance mask, which the sample uses to filter out intersections between rays
        // and geometry. For example, it uses masks to prevent light sources from being visible
        // to secondary rays, which would result in their contribution being double-counted.
        instanceDescriptors[instanceIndex].mask = (uint32_t)instance.mask;

        // Copy the first three rows of the instance transformation matrix. Metal
        // assumes that the bottom row is (0, 0, 0, 1), which allows the renderer to
        // tightly pack instance descriptors in memory.
        for (int column = 0; column < 4; column++)
            for (int row = 0; row < 3; row++)
                instanceDescriptors[instanceIndex].transformationMatrix.columns[column][row] = instance.transform.columns[column][row];
    }

#if !TARGET_OS_IPHONE
    [_instanceBuffer didModifyRange:NSMakeRange(0, _instanceBuffer.length)];
#endif

    // Create an instance acceleration structure descriptor.
    MTLInstanceAccelerationStructureDescriptor *accelDescriptor = [MTLInstanceAccelerationStructureDescriptor descriptor];

    accelDescriptor.instancedAccelerationStructures = _primitiveAccelerationStructures;
    accelDescriptor.instanceCount = _scene.instances.count;
    accelDescriptor.instanceDescriptorBuffer = _instanceBuffer;

    // Create the instance acceleration structure that contains all instances in the scene.
    _instanceAccelerationStructure = [self newAccelerationStructureWithDescriptor:accelDescriptor];
}

- (BOOL)isMetalFXSupported
{
#if SUPPORTS_METALFX_FRAMEWORK
    if (@available(macOS 26.0, iOS 18.0, *)) {
        return [MTLFXTemporalDenoisedScalerDescriptor supportsDevice:_device];
    }
#endif
    return NO;
}

- (BOOL)isMetalFXEnabled
{
    return _metalFXEnabled;
}

- (RendererDenoiserMode)denoiserMode
{
    return _denoiserMode;
}

- (BOOL)isMetalFXAutoExposureEnabled
{
    return _metalFXAutoExposureEnabled;
}

- (float)metalFXManualExposure
{
    return _metalFXManualExposure;
}

- (void)setMetalFXManualExposure:(float)metalFXManualExposure
{
    _metalFXManualExposure = metalFXManualExposure;
    [self updateExposureTexture];
    _needsResetHistory = true;
}

- (void)setDenoiserMode:(RendererDenoiserMode)mode forView:(MTKView *)view
{
    _denoiserMode = mode;
    _metalFXRequestedEnabled = (mode != RendererDenoiserModeRaw);
    _needsResetHistory = true;

    if (!CGSizeEqualToSize(_size, CGSizeZero)) {
        [self mtkView:view drawableSizeWillChange:_size];
    }
}

- (void)setMetalFXAutoExposureEnabled:(BOOL)enabled forView:(MTKView *)view
{
    _metalFXAutoExposureEnabled = enabled;
    _needsResetHistory = true;

    if (!CGSizeEqualToSize(_size, CGSizeZero)) {
        [self mtkView:view drawableSizeWillChange:_size];
    }
}

- (BOOL)isMetalFXOptionalParameterEnabled:(RendererMetalFXOptionalParameter)parameter
{
    switch (parameter) {
        case RendererMetalFXOptionalParameterJitter:
            return _metalFXUsesJitter;
        case RendererMetalFXOptionalParameterDepthTexture:
            return _metalFXUsesDepthTexture;
        case RendererMetalFXOptionalParameterMotionTexture:
            return _metalFXUsesMotionTexture;
        case RendererMetalFXOptionalParameterMotionVectorScale:
            return _metalFXUsesMotionVectorScale;
        case RendererMetalFXOptionalParameterWorldToViewMatrix:
            return _metalFXUsesWorldToViewMatrix;
        case RendererMetalFXOptionalParameterViewToClipMatrix:
            return _metalFXUsesViewToClipMatrix;
    }

    return NO;
}

- (void)setMetalFXOptionalParameter:(RendererMetalFXOptionalParameter)parameter
                            enabled:(BOOL)enabled
                            forView:(MTKView *)view
{
    switch (parameter) {
        case RendererMetalFXOptionalParameterJitter:
            _metalFXUsesJitter = enabled;
            break;
        case RendererMetalFXOptionalParameterDepthTexture:
            _metalFXUsesDepthTexture = enabled;
            break;
        case RendererMetalFXOptionalParameterMotionTexture:
            _metalFXUsesMotionTexture = enabled;
            break;
        case RendererMetalFXOptionalParameterMotionVectorScale:
            _metalFXUsesMotionVectorScale = enabled;
            break;
        case RendererMetalFXOptionalParameterWorldToViewMatrix:
            _metalFXUsesWorldToViewMatrix = enabled;
            break;
        case RendererMetalFXOptionalParameterViewToClipMatrix:
            _metalFXUsesViewToClipMatrix = enabled;
            break;
    }

    _needsResetHistory = true;
}

- (NSUInteger)samplesPerPixel {
    return _samplesPerPixel;
}

- (void)setSamplesPerPixel:(NSUInteger)samplesPerPixel {
    if (_samplesPerPixel != samplesPerPixel) {
        _samplesPerPixel = samplesPerPixel;
        _frameIndex = 0;
    }
}

- (float)averageFramesPerSecond
{
    return _averageFramesPerSecond;
}

- (float)averageFrameTimeMS
{
    return _averageFrameTimeMS;
}

- (NSString *)statisticsText
{
    NSString *fpsText = _averageFramesPerSecond > 0.0f ? [NSString stringWithFormat:@"%.1f", _averageFramesPerSecond] : @"--";
    NSString *frameTimeText = _averageFrameTimeMS > 0.0f ? [NSString stringWithFormat:@"%.2f", _averageFrameTimeMS] : @"--";
    NSUInteger width = MAX((NSUInteger)_size.width, 0);
    NSUInteger height = MAX((NSUInteger)_size.height, 0);

    return [NSString stringWithFormat:@"FPS %@\nFrame %@ ms\nResolution %lux%lu\nSPP %lu  Accum %u",
            fpsText,
            frameTimeText,
            (unsigned long)width,
            (unsigned long)height,
            (unsigned long)_samplesPerPixel,
            _frameIndex];
}

- (void)updateStatistics
{
    CFTimeInterval now = CACurrentMediaTime();

    if (_lastFrameTimestamp <= 0.0) {
        _lastFrameTimestamp = now;
        _statisticsSampleStart = now;
        return;
    }

    _framesSinceLastStatisticsSample++;

    CFTimeInterval elapsed = now - _statisticsSampleStart;
    if (elapsed >= statisticsUpdateInterval) {
        _averageFramesPerSecond = (float)_framesSinceLastStatisticsSample / (float)elapsed;
        _averageFrameTimeMS = _averageFramesPerSecond > 0.0f ? (1000.0f / _averageFramesPerSecond) : 0.0f;
        _statisticsSampleStart = now;
        _framesSinceLastStatisticsSample = 0;
    }

    _lastFrameTimestamp = now;
}

- (void)configureMetalFXForSize:(CGSize)size
{
#if SUPPORTS_METALFX_FRAMEWORK
    _temporalDenoisedScaler = nil;
    _metalFXEnabled = false;

    if (size.width < 1.0 || size.height < 1.0) {
        return;
    }

    if (_metalFXRequestedEnabled) {
        if (@available(macOS 26.0, iOS 18.0, *)) {
            if (![MTLFXTemporalDenoisedScalerDescriptor supportsDevice:_device]) {
                return;
            }

            MTLPixelFormat format = _hdrEnabled ? MTLPixelFormatRGBA16Float : MTLPixelFormatBGRA8Unorm_sRGB;

            MTLFXTemporalDenoisedScalerDescriptor *descriptor = [[MTLFXTemporalDenoisedScalerDescriptor alloc] init];
            descriptor.colorTextureFormat = format;
            descriptor.depthTextureFormat = MTLPixelFormatDepth32Float;
            descriptor.motionTextureFormat = MTLPixelFormatRG16Float;
            descriptor.diffuseAlbedoTextureFormat = MTLPixelFormatRGBA16Float;
            descriptor.specularAlbedoTextureFormat = MTLPixelFormatRGBA16Float;
            descriptor.normalTextureFormat = MTLPixelFormatRGBA16Float;
            descriptor.roughnessTextureFormat = MTLPixelFormatR16Float;
            descriptor.outputTextureFormat = format;
            descriptor.inputWidth = (NSUInteger)size.width;
            descriptor.inputHeight = (NSUInteger)size.height;
            descriptor.outputWidth = (NSUInteger)size.width;
            descriptor.outputHeight = (NSUInteger)size.height;
            descriptor.autoExposureEnabled = _metalFXAutoExposureEnabled;

            _temporalDenoisedScaler = [descriptor newTemporalDenoisedScalerWithDevice:_device];
            _metalFXEnabled = _temporalDenoisedScaler != nil;
        }
    }
#endif
}

- (BOOL)isHdrEnabled {
    return _hdrEnabled;
}

- (void)setHdrEnabled:(BOOL)enabled forView:(MTKView *)view {
    if (_hdrEnabled != enabled) {
        _hdrEnabled = enabled;
        _needsResetHistory = true;

        if (!CGSizeEqualToSize(_size, CGSizeZero)) {
            [self mtkView:view drawableSizeWillChange:_size];
        }
    }
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size
{
    _size = size;
    _needsResetHistory = true;
    _previousWorldToViewMatrix = matrix_identity_float4x4;
    _previousViewToClipMatrix = matrix_identity_float4x4;

    [self configureMetalFXForSize:size];

    // Create a pair of textures that the ray tracing kernel uses to accumulate
    // samples over several frames.
    MTLTextureDescriptor *textureDescriptor = [[MTLTextureDescriptor alloc] init];

    textureDescriptor.pixelFormat = MTLPixelFormatRGBA32Float;
    textureDescriptor.textureType = MTLTextureType2D;
    textureDescriptor.width = size.width;
    textureDescriptor.height = size.height;

    // Store the texture in private memory because only the GPU reads or writes this texture.
    textureDescriptor.storageMode = MTLStorageModePrivate;
    textureDescriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;

    for (NSUInteger i = 0; i < 2; i++)
        _accumulationTargets[i] = [_device newTextureWithDescriptor:textureDescriptor];

    textureDescriptor.pixelFormat = _hdrEnabled ? MTLPixelFormatRGBA16Float : MTLPixelFormatBGRA8Unorm_sRGB;
    textureDescriptor.usage = MTLTextureUsageShaderWrite;
#if SUPPORTS_METALFX_FRAMEWORK
    if (_metalFXEnabled) {
        textureDescriptor.usage |= _temporalDenoisedScaler.colorTextureUsage;
    }
#endif
    _noisyColorTexture = [_device newTextureWithDescriptor:textureDescriptor];

    MTLTextureDescriptor *actualDepthDescriptor = [[MTLTextureDescriptor alloc] init];
    actualDepthDescriptor.pixelFormat = MTLPixelFormatDepth32Float;
    actualDepthDescriptor.textureType = MTLTextureType2D;
    actualDepthDescriptor.width = size.width;
    actualDepthDescriptor.height = size.height;
    actualDepthDescriptor.storageMode = MTLStorageModePrivate;
    // ShaderRead needed so copyDepthFragment can sample this texture in debug mode
    actualDepthDescriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
#if SUPPORTS_METALFX_FRAMEWORK
    if (_metalFXEnabled) {
        actualDepthDescriptor.usage |= _temporalDenoisedScaler.depthTextureUsage;
    }
#endif
    _actualDepthTexture = [_device newTextureWithDescriptor:actualDepthDescriptor];

    MTLTextureDescriptor *disabledDepthDescriptor = [actualDepthDescriptor copy];
    _disabledDepthTexture = [_device newTextureWithDescriptor:disabledDepthDescriptor];

    id<MTLCommandBuffer> clearDepthCommandBuffer = [_queue commandBuffer];
    clearDepthCommandBuffer.label = @"Initialize Disabled Depth Texture";
    MTLRenderPassDescriptor *disabledDepthPass = [MTLRenderPassDescriptor renderPassDescriptor];
    disabledDepthPass.depthAttachment.texture = _disabledDepthTexture;
    disabledDepthPass.depthAttachment.loadAction = MTLLoadActionClear;
    disabledDepthPass.depthAttachment.storeAction = MTLStoreActionStore;
    disabledDepthPass.depthAttachment.clearDepth = 1.0;
    id<MTLRenderCommandEncoder> disabledDepthEncoder =
        [clearDepthCommandBuffer renderCommandEncoderWithDescriptor:disabledDepthPass];
    [disabledDepthEncoder endEncoding];
    [clearDepthCommandBuffer commit];
    [clearDepthCommandBuffer waitUntilCompleted];

    textureDescriptor.storageMode = MTLStorageModePrivate;

    textureDescriptor.pixelFormat = MTLPixelFormatRG16Float;
    // ShaderRead needed for debug visualization and potentially denoiser
    textureDescriptor.usage = MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
#if SUPPORTS_METALFX_FRAMEWORK
    if (_metalFXEnabled) {
        textureDescriptor.usage |= _temporalDenoisedScaler.motionTextureUsage;
    }
#endif
    _motionTexture = [_device newTextureWithDescriptor:textureDescriptor];

    textureDescriptor.usage = MTLTextureUsageShaderRead;
#if SUPPORTS_METALFX_FRAMEWORK
    if (_metalFXEnabled) {
        textureDescriptor.usage |= _temporalDenoisedScaler.motionTextureUsage;
    }
#endif
#if !TARGET_OS_IPHONE
    textureDescriptor.storageMode = MTLStorageModeManaged;
#else
    textureDescriptor.storageMode = MTLStorageModeShared;
#endif
    _disabledMotionTexture = [_device newTextureWithDescriptor:textureDescriptor];

    size_t zeroMotionBytesPerRow = sizeof(uint16_t) * 2 * size.width;
    void *zeroMotionBytes = calloc(size.height, zeroMotionBytesPerRow);
    [_disabledMotionTexture replaceRegion:MTLRegionMake2D(0, 0, size.width, size.height)
                              mipmapLevel:0
                                withBytes:zeroMotionBytes
                              bytesPerRow:zeroMotionBytesPerRow];
    free(zeroMotionBytes);

    textureDescriptor.storageMode = MTLStorageModePrivate;

    textureDescriptor.pixelFormat = MTLPixelFormatRGBA16Float;
    textureDescriptor.usage = MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
#if SUPPORTS_METALFX_FRAMEWORK
    if (_metalFXEnabled) {
        textureDescriptor.usage |= _temporalDenoisedScaler.diffuseAlbedoTextureUsage;
    }
#endif
    _diffuseAlbedoTexture = [_device newTextureWithDescriptor:textureDescriptor];

    textureDescriptor.pixelFormat = MTLPixelFormatRGBA16Float;
    textureDescriptor.usage = MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
#if SUPPORTS_METALFX_FRAMEWORK
    if (_metalFXEnabled) {
        textureDescriptor.usage |= _temporalDenoisedScaler.specularAlbedoTextureUsage;
    }
#endif
    _specularAlbedoTexture = [_device newTextureWithDescriptor:textureDescriptor];

    textureDescriptor.pixelFormat = MTLPixelFormatRGBA16Float;
    textureDescriptor.usage = MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
#if SUPPORTS_METALFX_FRAMEWORK
    if (_metalFXEnabled) {
        textureDescriptor.usage |= _temporalDenoisedScaler.normalTextureUsage;
    }
#endif
    _normalTexture = [_device newTextureWithDescriptor:textureDescriptor];

    textureDescriptor.pixelFormat = MTLPixelFormatR16Float;
    textureDescriptor.usage = MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
#if SUPPORTS_METALFX_FRAMEWORK
    if (_metalFXEnabled) {
        textureDescriptor.usage |= _temporalDenoisedScaler.roughnessTextureUsage;
    }
#endif
    _roughnessTexture = [_device newTextureWithDescriptor:textureDescriptor];

    MTLTextureDescriptor *exposureDescriptor = [[MTLTextureDescriptor alloc] init];
    exposureDescriptor.pixelFormat = MTLPixelFormatR16Float;
    exposureDescriptor.textureType = MTLTextureType2D;
    exposureDescriptor.width = 1;
    exposureDescriptor.height = 1;
    exposureDescriptor.usage = MTLTextureUsageShaderRead;
#if !TARGET_OS_IPHONE
    exposureDescriptor.storageMode = MTLStorageModeManaged;
#else
    exposureDescriptor.storageMode = MTLStorageModeShared;
#endif
    _exposureTexture = [_device newTextureWithDescriptor:exposureDescriptor];
    [self updateExposureTexture];

    textureDescriptor.pixelFormat = _hdrEnabled ? MTLPixelFormatRGBA16Float : MTLPixelFormatBGRA8Unorm_sRGB;
    textureDescriptor.usage = MTLTextureUsageShaderRead;
#if SUPPORTS_METALFX_FRAMEWORK
    if (_metalFXEnabled) {
        textureDescriptor.usage |= _temporalDenoisedScaler.outputTextureUsage;
    }
#endif
    _metalFXOutputTexture = [_device newTextureWithDescriptor:textureDescriptor];

    // Create a texture that contains a random integer value for each pixel. The sample
    // uses these values to decorrelate pixels while drawing pseudorandom numbers from the
    // Halton sequence.
    textureDescriptor.pixelFormat = MTLPixelFormatR32Uint;
    textureDescriptor.usage = MTLTextureUsageShaderRead;

    // The sample initializes the data in the texture, so it can't be private.
#if !TARGET_OS_IPHONE
    textureDescriptor.storageMode = MTLStorageModeManaged;
#else
    textureDescriptor.storageMode = MTLStorageModeShared;
#endif

    _randomTexture = [_device newTextureWithDescriptor:textureDescriptor];

    // Initialize random values.
    uint32_t *randomValues = (uint32_t *)malloc(sizeof(uint32_t) * size.width * size.height);

    for (NSUInteger i = 0; i < size.width * size.height; i++)
        randomValues[i] = rand() % (1024 * 1024);

    [_randomTexture replaceRegion:MTLRegionMake2D(0, 0, size.width, size.height)
                      mipmapLevel:0
                        withBytes:randomValues
                      bytesPerRow:sizeof(uint32_t) * size.width];

    free(randomValues);

    _frameIndex = 0;
}

- (void)updateUniforms {
    _uniformBufferOffset = alignedUniformsSize * _uniformBufferIndex;

    Uniforms *uniforms = (Uniforms *)((char *)_uniformBuffer.contents + _uniformBufferOffset);

    vector_float3 position = _scene.cameraPosition;
    vector_float3 target = _scene.cameraTarget;
    vector_float3 up = _scene.cameraUp;

    vector_float3 forward = vector_normalize(target - position);
    vector_float3 right = vector_normalize(vector_cross(forward, up));
    up = vector_normalize(vector_cross(right, forward));

    uniforms->camera.position = position;
    uniforms->camera.forward = forward;
    uniforms->camera.right = right;
    uniforms->camera.up = up;

    float fieldOfView = 45.0f * (M_PI / 180.0f);
    float aspectRatio = (float)_size.width / (float)_size.height;
    float imagePlaneHeight = tanf(fieldOfView / 2.0f);
    float imagePlaneWidth = aspectRatio * imagePlaneHeight;

    uniforms->camera.right *= imagePlaneWidth;
    uniforms->camera.up *= imagePlaneHeight;

    uniforms->width = (unsigned int)_size.width;
    uniforms->height = (unsigned int)_size.height;
    uniforms->lightCount = (unsigned int)_scene.lightCount;
    uniforms->temporalDenoiserEnabled = _metalFXEnabled ? 1 : 0;
    uniforms->materialRoughness = _roughness;
    uniforms->materialSpecular = _specularAlbedo;
    uniforms->samplesPerPixel = (unsigned int)_samplesPerPixel;

    unsigned int frameNumber = (unsigned int)_frameIndex;

    // Zero out jitter when in debug render modes so the G-Buffer view is stable.
    if (_renderMode == RendererRenderModeDefault && _metalFXEnabled) {
        uniforms->jitter = vector2(haltonJitter(frameNumber + 1, 2) - 0.5f,
                                   haltonJitter(frameNumber + 1, 3) - 0.5f);
    } else {
        uniforms->jitter = vector2(0.0f, 0.0f);
    }

    float safeAspectRatio = MAX((float)_size.width / MAX((float)_size.height, 1.0f), 0.0001f);
    matrix_float4x4 currentWorldToViewMatrix = worldToViewMatrix(position, target, up);
    matrix_float4x4 currentViewToClipMatrix = viewToClipMatrix(safeAspectRatio);

    uniforms->worldToViewMatrix = currentWorldToViewMatrix;
    uniforms->viewToClipMatrix = currentViewToClipMatrix;
    uniforms->previousWorldToViewMatrix = _previousWorldToViewMatrix;
    uniforms->previousViewToClipMatrix = _previousViewToClipMatrix;
    uniforms->frameIndex = frameNumber;

#if !TARGET_OS_IPHONE
    [_uniformBuffer didModifyRange:NSMakeRange(_uniformBufferOffset, alignedUniformsSize)];
#endif

    _previousWorldToViewMatrix = currentWorldToViewMatrix;
    _previousViewToClipMatrix = currentViewToClipMatrix;
    _frameIndex++;

    // Advance to the next slot in the uniform buffer.
    _uniformBufferIndex = (_uniformBufferIndex + 1) % maxFramesInFlight;
}

- (void)drawTexture:(id<MTLTexture>)texture
      withPipeline:(id<MTLRenderPipelineState>)pipelineState
        inViewport:(MTLViewport)viewport
        scissorRect:(MTLScissorRect)scissorRect
      usingEncoder:(id<MTLRenderCommandEncoder>)renderEncoder
{
    [renderEncoder setViewport:viewport];
    [renderEncoder setScissorRect:scissorRect];
    [renderEncoder setRenderPipelineState:pipelineState];
    [renderEncoder setFragmentTexture:texture atIndex:0];
    [renderEncoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
}

- (void)drawInMTKView:(MTKView *)view {
    [self updateStatistics];

    // The sample uses the uniform buffer to stream uniform data to the GPU, so it
    // needs to wait until the GPU finishes processing the oldest GPU frame before
    // it can reuse that space in the buffer.
    dispatch_semaphore_wait(_sem, DISPATCH_TIME_FOREVER);

    // Create a command for the frame's commands.
    id <MTLCommandBuffer> commandBuffer = [_queue commandBuffer];

    __block dispatch_semaphore_t sem = _sem;

    // When the GPU finishes processing the command buffer for the frame, signal
    // the semaphore to make the space in uniform available for future frames.

    // Note: Completion handlers should be as fast as possible because the GPU
    // driver may have other work scheduled on the underlying dispatch queue.
    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> buffer) {
        dispatch_semaphore_signal(sem);
    }];

    [self updateUniforms];

    NSUInteger width = (NSUInteger)_size.width;
    NSUInteger height = (NSUInteger)_size.height;

    // Debug views also need a fresh G-buffer even when MetalFX is disabled.
    BOOL needsGBufferPass = _metalFXEnabled || _renderMode != RendererRenderModeDefault;
    if (needsGBufferPass) {
        MTLRenderPassDescriptor *gBufferPass = [MTLRenderPassDescriptor renderPassDescriptor];
        gBufferPass.colorAttachments[0].texture = _motionTexture;
        gBufferPass.colorAttachments[0].loadAction = MTLLoadActionClear;
        gBufferPass.colorAttachments[0].clearColor = MTLClearColorMake(0.0f, 0.0f, 0.0f, 0.0f);
        
        gBufferPass.colorAttachments[1].texture = _diffuseAlbedoTexture;
        gBufferPass.colorAttachments[1].loadAction = MTLLoadActionClear;
        gBufferPass.colorAttachments[1].clearColor = MTLClearColorMake(0.0f, 0.0f, 0.0f, 0.0f);
        
        gBufferPass.colorAttachments[2].texture = _specularAlbedoTexture;
        gBufferPass.colorAttachments[2].loadAction = MTLLoadActionClear;
        gBufferPass.colorAttachments[2].clearColor = MTLClearColorMake(0.0f, 0.0f, 0.0f, 0.0f);

        gBufferPass.colorAttachments[3].texture = _normalTexture;
        gBufferPass.colorAttachments[3].loadAction = MTLLoadActionClear;
        gBufferPass.colorAttachments[3].clearColor = MTLClearColorMake(0.0f, 0.0f, 1.0f, 1.0f);

        gBufferPass.colorAttachments[4].texture = _roughnessTexture;
        gBufferPass.colorAttachments[4].loadAction = MTLLoadActionClear;
        gBufferPass.colorAttachments[4].clearColor = MTLClearColorMake(1.0f, 0.0f, 0.0f, 0.0f);

        gBufferPass.depthAttachment.texture = _actualDepthTexture;
        gBufferPass.depthAttachment.loadAction = MTLLoadActionClear;
        gBufferPass.depthAttachment.clearDepth = 1.0f;
        gBufferPass.depthAttachment.storeAction = MTLStoreActionStore;

        id<MTLRenderCommandEncoder> gBufferEncoder = [commandBuffer renderCommandEncoderWithDescriptor:gBufferPass];
        [gBufferEncoder setDepthStencilState:_gBufferDepthState];
        [gBufferEncoder setCullMode:MTLCullModeNone];

        for (NSUInteger i = 0; i < _scene.instances.count; i++) {
            GeometryInstance *instance = _scene.instances[i];
            matrix_float4x4 transform = instance.transform;
            
            if ([instance.geometry isKindOfClass:[TriangleGeometry class]]) {
                TriangleGeometry *tg = (TriangleGeometry *)instance.geometry;
                [gBufferEncoder setRenderPipelineState:_gBufferTrianglePipeline];
                [gBufferEncoder setVertexBuffer:tg.vertexPositionBuffer offset:0 atIndex:0];
                [gBufferEncoder setVertexBuffer:tg.vertexNormalBuffer offset:0 atIndex:1];
                [gBufferEncoder setVertexBuffer:tg.vertexColorBuffer offset:0 atIndex:2];
                [gBufferEncoder setVertexBytes:&transform length:sizeof(matrix_float4x4) atIndex:3];
                [gBufferEncoder setVertexBuffer:_uniformBuffer offset:_uniformBufferOffset atIndex:4];

                [gBufferEncoder setFragmentBuffer:_uniformBuffer offset:_uniformBufferOffset atIndex:0];
                
                [gBufferEncoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                                           indexCount:tg.indexCount
                                            indexType:MTLIndexTypeUInt16
                                          indexBuffer:tg.indexBuffer
                                    indexBufferOffset:0];
            } else if ([instance.geometry isKindOfClass:[SphereGeometry class]]) {
                SphereGeometry *sg = (SphereGeometry *)instance.geometry;
                [gBufferEncoder setRenderPipelineState:_gBufferSpherePipeline];
                [gBufferEncoder setVertexBuffer:sg.sphereBuffer offset:0 atIndex:0];
                [gBufferEncoder setVertexBytes:&transform length:sizeof(matrix_float4x4) atIndex:1];
                [gBufferEncoder setVertexBuffer:_uniformBuffer offset:_uniformBufferOffset atIndex:2];

                [gBufferEncoder setFragmentBuffer:_uniformBuffer offset:_uniformBufferOffset atIndex:0];
                
                [gBufferEncoder drawPrimitives:MTLPrimitiveTypeTriangle
                                   vertexStart:0
                                   vertexCount:36
                                 instanceCount:sg.sphereCount];
            }
        }
        [gBufferEncoder endEncoding];
    }
    
    // Launch a rectangular grid of threads on the GPU to perform ray tracing, with one thread per
    // pixel. The sample needs to align the number of threads to a multiple of the threadgroup
    // size, because earlier, when it created the pipeline objects, it declared that the pipeline
    // would always use a threadgroup size that's a multiple of the thread execution width
    // (SIMD group size). An 8x8 threadgroup is a safe threadgroup size and small enough to be
    // supported on most devices. A more advanced app would choose the threadgroup size dynamically.
    MTLSize threadsPerThreadgroup = MTLSizeMake(8, 8, 1);
    MTLSize threadgroups = MTLSizeMake((width  + threadsPerThreadgroup.width  - 1) / threadsPerThreadgroup.width,
                                       (height + threadsPerThreadgroup.height - 1) / threadsPerThreadgroup.height,
                                       1);

    // Create a compute encoder to encode GPU commands.
    id <MTLComputeCommandEncoder> computeEncoder = [commandBuffer computeCommandEncoder];

    // Bind buffers.
    [computeEncoder setBuffer:_uniformBuffer            offset:_uniformBufferOffset atIndex:0];
    if (!_usePerPrimitiveData) {
        [computeEncoder setBuffer:_resourceBuffer           offset:0                    atIndex:1];
    }
    [computeEncoder setBuffer:_instanceBuffer           offset:0                    atIndex:2];
    [computeEncoder setBuffer:_scene.lightBuffer        offset:0                    atIndex:3];

    // Bind acceleration structure and intersection function table. These bind to normal buffer
    // binding slots.
    [computeEncoder setAccelerationStructure:_instanceAccelerationStructure atBufferIndex:4];
    [computeEncoder setIntersectionFunctionTable:_intersectionFunctionTable atBufferIndex:5];

    // Bind textures. The ray tracing kernel reads from _accumulationTargets[0], averages the
    // result with this frame's samples and writes to _accumulationTargets[1].
    [computeEncoder setTexture:_randomTexture atIndex:0];
    [computeEncoder setTexture:_accumulationTargets[0] atIndex:1];
    [computeEncoder setTexture:_accumulationTargets[1] atIndex:2];
    [computeEncoder setTexture:_noisyColorTexture atIndex:3];

    // Mark any resources used by intersection functions as "used". The sample does this because
    // it only references these resources indirectly via the resource buffer. Metal makes all the
    // marked resources resident in memory before the intersection functions execute.
    // Normally, the sample would also mark the resource buffer itself since the
    // intersection table references it indirectly. However, the sample also binds the resource
    // buffer directly, so it doesn't need to mark it explicitly.
    for (Geometry *geometry in _scene.geometries)
        for (id <MTLResource> resource in geometry.resources)
            [computeEncoder useResource:resource usage:MTLResourceUsageRead];

    // Also mark primitive acceleration structures as used since only the instance acceleration
    // structure references them.
    for (id <MTLAccelerationStructure> primitiveAccelerationStructure in _primitiveAccelerationStructures)
        [computeEncoder useResource:primitiveAccelerationStructure usage:MTLResourceUsageRead];

    // Bind the compute pipeline state.
    [computeEncoder setComputePipelineState:_raytracingPipeline];

    // Dispatch the compute kernel to perform ray tracing.
    [computeEncoder dispatchThreadgroups:threadgroups threadsPerThreadgroup:threadsPerThreadgroup];

    [computeEncoder endEncoding];

    // Swap the source and destination accumulation targets for the next frame.
    std::swap(_accumulationTargets[0], _accumulationTargets[1]);

#if SUPPORTS_METALFX_FRAMEWORK
    id<MTLTexture> displayTexture = _accumulationTargets[0];

    if (_metalFXEnabled) {
        if (@available(macOS 26.0, iOS 18.0, *)) {
            _temporalDenoisedScaler.colorTexture = _noisyColorTexture;
            _temporalDenoisedScaler.depthTexture = _metalFXUsesDepthTexture ? _actualDepthTexture : _disabledDepthTexture;
            _temporalDenoisedScaler.motionTexture = _metalFXUsesMotionTexture ? _motionTexture : _disabledMotionTexture;
            _temporalDenoisedScaler.diffuseAlbedoTexture = _diffuseAlbedoTexture;
            _temporalDenoisedScaler.specularAlbedoTexture = _specularAlbedoTexture;
            _temporalDenoisedScaler.normalTexture = _normalTexture;
            _temporalDenoisedScaler.roughnessTexture = _roughnessTexture;
            _temporalDenoisedScaler.outputTexture = _metalFXOutputTexture;
            if (_metalFXAutoExposureEnabled) {
                _temporalDenoisedScaler.exposureTexture = nil;
                _temporalDenoisedScaler.preExposure = 1.0f;
            } else {
                _temporalDenoisedScaler.exposureTexture = _exposureTexture;
                _temporalDenoisedScaler.preExposure = 1.0f;
            }
            Uniforms *currentUniforms = (Uniforms *)((char *)_uniformBuffer.contents + _uniformBufferOffset);
            _temporalDenoisedScaler.jitterOffsetX = _metalFXUsesJitter ? currentUniforms->jitter.x : 0.0f;
            _temporalDenoisedScaler.jitterOffsetY = _metalFXUsesJitter ? currentUniforms->jitter.y : 0.0f;
            _temporalDenoisedScaler.motionVectorScaleX = _metalFXUsesMotionVectorScale ? (float)currentUniforms->width : 0.0f;
            _temporalDenoisedScaler.motionVectorScaleY = _metalFXUsesMotionVectorScale ? (float)currentUniforms->height : 0.0f;
            _temporalDenoisedScaler.worldToViewMatrix = _metalFXUsesWorldToViewMatrix ? currentUniforms->worldToViewMatrix : matrix_identity_float4x4;
            _temporalDenoisedScaler.viewToClipMatrix = _metalFXUsesViewToClipMatrix ? currentUniforms->viewToClipMatrix : matrix_identity_float4x4;
            _temporalDenoisedScaler.depthReversed = NO;
            _temporalDenoisedScaler.shouldResetHistory = _needsResetHistory;
            [_temporalDenoisedScaler encodeToCommandBuffer:commandBuffer];
            displayTexture = _metalFXOutputTexture;
            _needsResetHistory = false;
        }
    }
#else
    id<MTLTexture> displayTexture = _accumulationTargets[0];
#endif

    if (view.currentDrawable) {
        // Copy the resulting image into the view using the graphics pipeline because the sample
        // can't write directly to it using the compute kernel. The sample delays getting the
        // current render pass descriptor as long as possible to avoid a lenghty stall waiting
        // for the GPU/compositor to release a drawable. The drawable may be nil if
        // the window moves off screen.
        MTLRenderPassDescriptor* renderPassDescriptor = [MTLRenderPassDescriptor renderPassDescriptor];

        renderPassDescriptor.colorAttachments[0].texture    = view.currentDrawable.texture;
        renderPassDescriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0.0f, 0.0f, 0.0f, 1.0f);

        // Create a render command encoder.
        id <MTLRenderCommandEncoder> renderEncoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];

        id<MTLRenderPipelineState> displayPipeline = _copyPipeline;
        id<MTLTexture> primaryDisplayTexture = displayTexture;

        if (_renderMode == RendererRenderModeForward) {
            displayPipeline = _copyForwardPipeline;
            primaryDisplayTexture = _diffuseAlbedoTexture;
        } else if (_renderMode == RendererRenderModeDepth) {
            displayPipeline = _copyDepthPipeline;
            primaryDisplayTexture = _actualDepthTexture;
        } else if (_renderMode == RendererRenderModeNormal) {
            displayPipeline = _copyNormalPipeline;
            primaryDisplayTexture = _normalTexture;
        } else if (_renderMode == RendererRenderModeSpecular) {
            displayPipeline = _copySpecularPipeline;
            primaryDisplayTexture = _specularAlbedoTexture;
        } else if (_renderMode == RendererRenderModeRoughness) {
            displayPipeline = _copyRoughnessPipeline;
            primaryDisplayTexture = _roughnessTexture;
        } else if (_renderMode == RendererRenderModeMotion) {
            displayPipeline = _copyMotionPipeline;
            primaryDisplayTexture = _motionTexture;
        }

        BOOL showsDenoiseComparison = (_renderMode == RendererRenderModeDefault &&
                                      _denoiserMode == RendererDenoiserModeSplitScreen &&
                                      _metalFXEnabled);
        NSUInteger drawableWidth = view.currentDrawable.texture.width;
        NSUInteger drawableHeight = view.currentDrawable.texture.height;

        if (showsDenoiseComparison && drawableWidth > 1 && drawableHeight > 0) {
            const NSUInteger dividerWidth = drawableWidth >= 8 ? 2 : 0;
            NSUInteger comparisonWidth = drawableWidth - MIN(drawableWidth, dividerWidth);
            NSUInteger leftWidth = comparisonWidth / 2;
            NSUInteger rightWidth = comparisonWidth - leftWidth;

            if (leftWidth > 0) {
                MTLViewport leftViewport = {
                    .originX = 0.0,
                    .originY = 0.0,
                    .width = (double)leftWidth,
                    .height = (double)drawableHeight,
                    .znear = 0.0,
                    .zfar = 1.0
                };
                MTLScissorRect leftScissor = {
                    .x = 0,
                    .y = 0,
                    .width = leftWidth,
                    .height = drawableHeight
                };
                [self drawTexture:_accumulationTargets[0]
                     withPipeline:_copyPipeline
                       inViewport:leftViewport
                       scissorRect:leftScissor
                     usingEncoder:renderEncoder];
            }

            if (rightWidth > 0) {
                NSUInteger rightOriginX = leftWidth + dividerWidth;
                MTLViewport rightViewport = {
                    .originX = (double)rightOriginX,
                    .originY = 0.0,
                    .width = (double)rightWidth,
                    .height = (double)drawableHeight,
                    .znear = 0.0,
                    .zfar = 1.0
                };
                MTLScissorRect rightScissor = {
                    .x = rightOriginX,
                    .y = 0,
                    .width = rightWidth,
                    .height = drawableHeight
                };
                [self drawTexture:displayTexture
                     withPipeline:_copyPipeline
                       inViewport:rightViewport
                       scissorRect:rightScissor
                     usingEncoder:renderEncoder];
            }
        } else {
            MTLViewport fullscreenViewport = {
                .originX = 0.0,
                .originY = 0.0,
                .width = (double)drawableWidth,
                .height = (double)drawableHeight,
                .znear = 0.0,
                .zfar = 1.0
            };
            MTLScissorRect fullscreenScissor = {
                .x = 0,
                .y = 0,
                .width = drawableWidth,
                .height = drawableHeight
            };
            [self drawTexture:primaryDisplayTexture
                 withPipeline:displayPipeline
                   inViewport:fullscreenViewport
                   scissorRect:fullscreenScissor
                 usingEncoder:renderEncoder];
        }

        [renderEncoder endEncoding];

        // Present the drawable to the screen.
        [commandBuffer presentDrawable:view.currentDrawable];
    }

    // Finally, commit the command buffer so that the GPU can start executing.
    [commandBuffer commit];
}

@end
