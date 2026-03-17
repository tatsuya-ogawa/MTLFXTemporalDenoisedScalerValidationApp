/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
The header for the renderer class that performs Metal setup and per-frame rendering.
*/

#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>

#import "Scene.h"

typedef NS_ENUM(NSUInteger, RendererMetalFXOptionalParameter) {
    RendererMetalFXOptionalParameterJitter = 0,
    RendererMetalFXOptionalParameterDepthTexture = 1,
    RendererMetalFXOptionalParameterMotionTexture = 2,
    RendererMetalFXOptionalParameterMotionVectorScale = 3,
    RendererMetalFXOptionalParameterWorldToViewMatrix = 4,
    RendererMetalFXOptionalParameterViewToClipMatrix = 5,
};

typedef NS_ENUM(NSUInteger, RendererDenoiserMode) {
    RendererDenoiserModeRaw = 0,
    RendererDenoiserModeDenoised,
    RendererDenoiserModeSplitScreen,
    RendererDenoiserModeCount
};

typedef NS_ENUM(NSUInteger, RendererRenderMode) {
    RendererRenderModeDefault = 0,
    RendererRenderModeForward,
    RendererRenderModeDepth,
    RendererRenderModeSpecular,
    RendererRenderModeRoughness,
    RendererRenderModeMotion,
    RendererRenderModeNormal,
    RendererRenderModeCount
};

@interface Renderer : NSObject <MTKViewDelegate>

- (instancetype)initWithDevice:(id<MTLDevice>)device
                         scene:(Scene *)scene;

@property (nonatomic, readonly, getter=isMetalFXSupported) BOOL metalFXSupported;
@property (nonatomic, readonly, getter=isMetalFXEnabled) BOOL metalFXEnabled;
@property (nonatomic, readonly, getter=isMetalFXAutoExposureEnabled) BOOL metalFXAutoExposureEnabled;
@property (nonatomic, readonly) RendererDenoiserMode denoiserMode;
@property (nonatomic, assign) float metalFXManualExposure;
@property (nonatomic, assign) RendererRenderMode renderMode;
@property (nonatomic, readonly, getter=isHdrEnabled) BOOL hdrEnabled;

@property (nonatomic, assign) float roughness;
@property (nonatomic, assign) float specularAlbedo;
@property (nonatomic, assign) NSUInteger samplesPerPixel;

- (void)setDenoiserMode:(RendererDenoiserMode)mode forView:(MTKView *)view;
- (void)setHdrEnabled:(BOOL)enabled forView:(MTKView *)view;
- (void)setMetalFXAutoExposureEnabled:(BOOL)enabled forView:(MTKView *)view;
- (BOOL)isMetalFXOptionalParameterEnabled:(RendererMetalFXOptionalParameter)parameter;
- (void)setMetalFXOptionalParameter:(RendererMetalFXOptionalParameter)parameter
                            enabled:(BOOL)enabled
                            forView:(MTKView *)view;

@end
