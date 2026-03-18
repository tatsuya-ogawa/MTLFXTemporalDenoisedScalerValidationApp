/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
The implementation of the cross-platform view controller.
*/
#import "ViewController.h"
#import "../Renderer/Renderer.h"

@implementation ViewController
{
    MTKView *_view;

    Renderer *_renderer;

#if TARGET_OS_IPHONE
    UIView *_metalFXPanel;
    UILabel *_metalFXStatusLabel;
    UIButton *_denoiserModeButton;
    UIButton *_renderModeToggleButton;
    UIButton *_metalFXExposureModeButton;
    UILabel *_metalFXExposureValueLabel;
    UISlider *_metalFXExposureSlider;
    UILabel *_sppLabel;
    UISegmentedControl *_sppControl;
    UIButton *_hdrToggleButton;
    NSArray<UIButton *> *_metalFXOptionalButtons;

    UILabel *_materialRoughnessLabel;
    UISlider *_materialRoughnessSlider;

    UILabel *_materialSpecularLabel;
    UISlider *_materialSpecularSlider;
#else
    NSView *_metalFXPanel;
    NSTextField *_metalFXStatusLabel;
    NSButton *_denoiserModeButton;
    NSButton *_renderModeToggleButton;
    NSButton *_metalFXExposureModeButton;
    NSTextField *_metalFXExposureValueLabel;
    NSSlider *_metalFXExposureSlider;

    NSTextField *_materialRoughnessLabel;
    NSSlider *_materialRoughnessSlider;

    NSTextField *_materialSpecularLabel;
    NSSlider *_materialSpecularSlider;

    NSTextField *_sppLabel;
    NSSegmentedControl *_sppControl;

    NSArray<NSButton *> *_metalFXOptionalButtons;
    NSButton *_hdrToggleButton;
#endif

    NSLayoutConstraint *_panelLeadingConstraint;
    BOOL _isPanelStowed;
#if TARGET_OS_IPHONE
    UIButton *_togglePanelButton;
    UILabel *_rawLabel;
    UILabel *_denoisedLabel;
    UILabel *_statisticsLabel;
#else
    NSButton *_togglePanelButton;
    NSTextField *_rawLabel;
    NSTextField *_denoisedLabel;
    NSTextField *_statisticsLabel;
#endif
    NSTimer *_statisticsTimer;
}

- (void)viewDidLoad
{
    [super viewDidLoad];

    _view = (MTKView *)self.view;

#if TARGET_OS_IPHONE
    _view.device = MTLCreateSystemDefaultDevice();
#else
    NSArray<id<MTLDevice>> *devices = MTLCopyAllDevices();

    id<MTLDevice> selectedDevice;

    for(id<MTLDevice> device in devices)
    {
        if(device.supportsRaytracing)
        {
            if(!selectedDevice || !device.isLowPower)
            {
                selectedDevice = device;
            }
        }
    }
    _view.device = selectedDevice;

    NSLog(@"Selected Device: %@", _view.device.name);
#endif

    // Device must support Metal and ray tracing.
    NSAssert(_view.device && _view.device.supportsRaytracing,
             @"Ray tracing isn't supported on this device");

#if TARGET_OS_IPHONE
    _view.backgroundColor = UIColor.blackColor;
#endif
    _view.colorPixelFormat = MTLPixelFormatRGBA16Float;

    Scene *scene = [Scene newInstancedCornellBoxSceneWithDevice:_view.device
                                       useIntersectionFunctions:YES];

    _renderer = [[Renderer alloc] initWithDevice:_view.device
                                           scene:scene];

    [_renderer mtkView:_view drawableSizeWillChange:_view.bounds.size];

    _view.delegate = _renderer;

    [self setupMetalFXControls];
    [self setupStatisticsOverlay];
    [self startStatisticsUpdates];
    [self updateMetalFXControls];
    [self updateStatisticsLabel];
}

- (void)setupMetalFXControls
{
#if TARGET_OS_IPHONE
    _metalFXPanel = [[UIView alloc] init];
    _metalFXPanel.translatesAutoresizingMaskIntoConstraints = NO;
    _metalFXPanel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.6f];
    _metalFXPanel.layer.cornerRadius = 12.0f;

    _metalFXStatusLabel = [[UILabel alloc] init];
    _metalFXStatusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _metalFXStatusLabel.textColor = UIColor.whiteColor;
    _metalFXStatusLabel.font = [UIFont systemFontOfSize:13.0f weight:UIFontWeightSemibold];
    _metalFXStatusLabel.numberOfLines = 2;

    _denoiserModeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _denoiserModeButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_denoiserModeButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    _denoiserModeButton.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.15f];
    _denoiserModeButton.layer.cornerRadius = 8.0f;
    _denoiserModeButton.contentEdgeInsets = UIEdgeInsetsMake(8.0f, 12.0f, 8.0f, 12.0f);
    [_denoiserModeButton addTarget:self action:@selector(cycleDenoiserMode:) forControlEvents:UIControlEventTouchUpInside];

    _renderModeToggleButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _renderModeToggleButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_renderModeToggleButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    _renderModeToggleButton.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.15f];
    _renderModeToggleButton.layer.cornerRadius = 8.0f;
    _renderModeToggleButton.contentEdgeInsets = UIEdgeInsetsMake(8.0f, 12.0f, 8.0f, 12.0f);
    [_renderModeToggleButton setTitle:@"Render Mode: Default" forState:UIControlStateNormal];
    [_renderModeToggleButton addTarget:self action:@selector(toggleRenderMode:) forControlEvents:UIControlEventTouchUpInside];

    _metalFXExposureModeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _metalFXExposureModeButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_metalFXExposureModeButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    _metalFXExposureModeButton.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.15f];
    _metalFXExposureModeButton.layer.cornerRadius = 8.0f;
    _metalFXExposureModeButton.contentEdgeInsets = UIEdgeInsetsMake(8.0f, 12.0f, 8.0f, 12.0f);
    [_metalFXExposureModeButton addTarget:self action:@selector(toggleMetalFXExposureMode:) forControlEvents:UIControlEventTouchUpInside];

    _metalFXExposureValueLabel = [[UILabel alloc] init];
    _metalFXExposureValueLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _metalFXExposureValueLabel.textColor = UIColor.whiteColor;
    _metalFXExposureValueLabel.font = [UIFont systemFontOfSize:12.0f weight:UIFontWeightRegular];

    _metalFXExposureSlider = [[UISlider alloc] init];
    _metalFXExposureSlider.translatesAutoresizingMaskIntoConstraints = NO;
    _metalFXExposureSlider.minimumValue = 0.25f;
    _metalFXExposureSlider.maximumValue = 4.0f;
    _metalFXExposureSlider.value = _renderer.metalFXManualExposure;
    [_metalFXExposureSlider addTarget:self action:@selector(changeMetalFXExposure:) forControlEvents:UIControlEventValueChanged];
    
    _sppLabel = [[UILabel alloc] init];
    _sppLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _sppLabel.textColor = UIColor.whiteColor;
    _sppLabel.font = [UIFont systemFontOfSize:12.0f weight:UIFontWeightRegular];
    _sppLabel.text = @"Samples Per Pixel (SPP)";

    _sppControl = [[UISegmentedControl alloc] initWithItems:@[@"1", @"2", @"4", @"8", @"16", @"32"]];
    _sppControl.translatesAutoresizingMaskIntoConstraints = NO;
    _sppControl.selectedSegmentIndex = 2;
    [_sppControl addTarget:self action:@selector(changeSPP:) forControlEvents:UIControlEventValueChanged];

    _hdrToggleButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _hdrToggleButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_hdrToggleButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    _hdrToggleButton.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.15f];
    _hdrToggleButton.layer.cornerRadius = 8.0f;
    _hdrToggleButton.contentEdgeInsets = UIEdgeInsetsMake(8.0f, 12.0f, 8.0f, 12.0f);
    [_hdrToggleButton addTarget:self action:@selector(toggleHdr:) forControlEvents:UIControlEventTouchUpInside];
    [_metalFXPanel addSubview:_hdrToggleButton];

    _materialRoughnessLabel = [[UILabel alloc] init];
    _materialRoughnessLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _materialRoughnessLabel.textColor = UIColor.whiteColor;
    _materialRoughnessLabel.font = [UIFont systemFontOfSize:12.0f weight:UIFontWeightRegular];

    _materialRoughnessSlider = [[UISlider alloc] init];
    _materialRoughnessSlider.translatesAutoresizingMaskIntoConstraints = NO;
    _materialRoughnessSlider.minimumValue = 0.0f;
    _materialRoughnessSlider.maximumValue = 1.0f;
    _materialRoughnessSlider.value = _renderer.roughness;
    [_materialRoughnessSlider addTarget:self action:@selector(changeRoughness:) forControlEvents:UIControlEventValueChanged];

    _materialSpecularLabel = [[UILabel alloc] init];
    _materialSpecularLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _materialSpecularLabel.textColor = UIColor.whiteColor;
    _materialSpecularLabel.font = [UIFont systemFontOfSize:12.0f weight:UIFontWeightRegular];

    _materialSpecularSlider = [[UISlider alloc] init];
    _materialSpecularSlider.translatesAutoresizingMaskIntoConstraints = NO;
    _materialSpecularSlider.minimumValue = 0.0f;
    _materialSpecularSlider.maximumValue = 1.0f;
    _materialSpecularSlider.value = _renderer.specularAlbedo;
    [_materialSpecularSlider addTarget:self action:@selector(changeSpecular:) forControlEvents:UIControlEventValueChanged];

    _togglePanelButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _togglePanelButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_togglePanelButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    _togglePanelButton.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.15f];
    _togglePanelButton.layer.cornerRadius = 8.0f;
    [_togglePanelButton setTitle:@"◀" forState:UIControlStateNormal];
    [_togglePanelButton addTarget:self action:@selector(togglePanel:) forControlEvents:UIControlEventTouchUpInside];
    [_metalFXPanel addSubview:_togglePanelButton];

    NSMutableArray<UIButton *> *optionalButtons = [NSMutableArray array];
    for (NSInteger parameter = RendererMetalFXOptionalParameterJitter; parameter <= RendererMetalFXOptionalParameterViewToClipMatrix; parameter++) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.translatesAutoresizingMaskIntoConstraints = NO;
        [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        button.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.12f];
        button.layer.cornerRadius = 8.0f;
        button.contentEdgeInsets = UIEdgeInsetsMake(8.0f, 12.0f, 8.0f, 12.0f);
        button.tag = parameter;
        [button addTarget:self action:@selector(toggleMetalFXOptionalParameter:) forControlEvents:UIControlEventTouchUpInside];
        [optionalButtons addObject:button];
        [_metalFXPanel addSubview:button];
    }
    _metalFXOptionalButtons = [optionalButtons copy];

    _rawLabel = [[UILabel alloc] init];
    _rawLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _rawLabel.text = @"Raw";
    _rawLabel.textColor = UIColor.whiteColor;
    _rawLabel.font = [UIFont systemFontOfSize:14.0f weight:UIFontWeightBold];
    _rawLabel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.4f];
    _rawLabel.layer.cornerRadius = 4.0f;
    _rawLabel.layer.masksToBounds = YES;
    _rawLabel.textAlignment = NSTextAlignmentCenter;
    [_view addSubview:_rawLabel];

    _denoisedLabel = [[UILabel alloc] init];
    _denoisedLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _denoisedLabel.text = @"Denoised";
    _denoisedLabel.textColor = UIColor.whiteColor;
    _denoisedLabel.font = [UIFont systemFontOfSize:14.0f weight:UIFontWeightBold];
    _denoisedLabel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.4f];
    _denoisedLabel.layer.cornerRadius = 4.0f;
    _denoisedLabel.layer.masksToBounds = YES;
    _denoisedLabel.textAlignment = NSTextAlignmentCenter;
    [_view addSubview:_denoisedLabel];
#else
    _metalFXPanel = [[NSView alloc] init];
    _metalFXPanel.translatesAutoresizingMaskIntoConstraints = NO;
    _metalFXPanel.wantsLayer = YES;
    _metalFXPanel.layer.backgroundColor = [[NSColor colorWithWhite:0.0f alpha:0.6f] CGColor];
    _metalFXPanel.layer.cornerRadius = 12.0f;

    _metalFXStatusLabel = [NSTextField labelWithString:@""];
    _metalFXStatusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _metalFXStatusLabel.textColor = NSColor.whiteColor;
    _metalFXStatusLabel.font = [NSFont systemFontOfSize:13.0f weight:NSFontWeightSemibold];

    _denoiserModeButton = [NSButton buttonWithTitle:@"" target:self action:@selector(cycleDenoiserMode:)];
    _denoiserModeButton.translatesAutoresizingMaskIntoConstraints = NO;
    _denoiserModeButton.bezelStyle = NSBezelStyleRounded;

    _renderModeToggleButton = [NSButton buttonWithTitle:@"Render Mode: Default" target:self action:@selector(toggleRenderMode:)];
    _renderModeToggleButton.translatesAutoresizingMaskIntoConstraints = NO;
    _renderModeToggleButton.bezelStyle = NSBezelStyleRounded;

    _metalFXExposureModeButton = [NSButton buttonWithTitle:@"" target:self action:@selector(toggleMetalFXExposureMode:)];
    _metalFXExposureModeButton.translatesAutoresizingMaskIntoConstraints = NO;
    _metalFXExposureModeButton.bezelStyle = NSBezelStyleRounded;

    _metalFXExposureValueLabel = [NSTextField labelWithString:@""];
    _metalFXExposureValueLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _metalFXExposureValueLabel.textColor = NSColor.whiteColor;
    _metalFXExposureValueLabel.font = [NSFont systemFontOfSize:12.0f weight:NSFontWeightRegular];

    _metalFXExposureSlider = [NSSlider sliderWithValue:_renderer.metalFXManualExposure minValue:0.25 maxValue:4.0 target:self action:@selector(changeMetalFXExposure:)];
    _metalFXExposureSlider.translatesAutoresizingMaskIntoConstraints = NO;

    _materialRoughnessLabel = [NSTextField labelWithString:@""];
    _materialRoughnessLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _materialRoughnessLabel.textColor = NSColor.whiteColor;
    _materialRoughnessLabel.font = [NSFont systemFontOfSize:12.0f weight:NSFontWeightRegular];

    _materialRoughnessSlider = [NSSlider sliderWithValue:_renderer.roughness minValue:0.0 maxValue:1.0 target:self action:@selector(changeRoughness:)];
    _materialRoughnessSlider.translatesAutoresizingMaskIntoConstraints = NO;

    _materialSpecularLabel = [NSTextField labelWithString:@""];
    _materialSpecularLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _materialSpecularLabel.textColor = NSColor.whiteColor;
    _materialSpecularLabel.font = [NSFont systemFontOfSize:12.0f weight:NSFontWeightRegular];

    _materialSpecularSlider = [NSSlider sliderWithValue:_renderer.specularAlbedo minValue:0.0 maxValue:1.0 target:self action:@selector(changeSpecular:)];
    _materialSpecularSlider.translatesAutoresizingMaskIntoConstraints = NO;

    _sppLabel = [NSTextField labelWithString:@"Samples Per Pixel (SPP)"];
    _sppLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _sppLabel.textColor = NSColor.whiteColor;
    _sppLabel.font = [NSFont systemFontOfSize:12.0f weight:NSFontWeightRegular];

    _sppControl = [NSSegmentedControl segmentedControlWithLabels:@[@"1", @"2", @"4", @"8", @"16", @"32"] trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(changeSPP:)];
    _sppControl.translatesAutoresizingMaskIntoConstraints = NO;
    _sppControl.selectedSegment = 2;

    _hdrToggleButton = [NSButton buttonWithTitle:@"" target:self action:@selector(toggleHdr:)];
    _hdrToggleButton.translatesAutoresizingMaskIntoConstraints = NO;
    _hdrToggleButton.bezelStyle = NSBezelStyleRounded;
    [_metalFXPanel addSubview:_hdrToggleButton];

    _togglePanelButton = [NSButton buttonWithTitle:@"◀" target:self action:@selector(togglePanel:)];
    _togglePanelButton.translatesAutoresizingMaskIntoConstraints = NO;
    _togglePanelButton.bezelStyle = NSBezelStyleRounded;
    [_metalFXPanel addSubview:_togglePanelButton];

    NSMutableArray<NSButton *> *optionalButtons = [NSMutableArray array];
    for (NSInteger parameter = RendererMetalFXOptionalParameterJitter; parameter <= RendererMetalFXOptionalParameterViewToClipMatrix; parameter++) {
        NSButton *button = [NSButton buttonWithTitle:@"" target:self action:@selector(toggleMetalFXOptionalParameter:)];
        button.translatesAutoresizingMaskIntoConstraints = NO;
        button.bezelStyle = NSBezelStyleRounded;
        button.tag = parameter;
        [optionalButtons addObject:button];
        [_metalFXPanel addSubview:button];
    }
    _metalFXOptionalButtons = [optionalButtons copy];

    _rawLabel = [NSTextField labelWithString:@"Raw"];
    _rawLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _rawLabel.textColor = NSColor.whiteColor;
    _rawLabel.font = [NSFont systemFontOfSize:14.0f weight:NSFontWeightBold];
    _rawLabel.wantsLayer = YES;
    _rawLabel.layer.backgroundColor = [[NSColor colorWithWhite:0.0 alpha:0.4] CGColor];
    _rawLabel.layer.cornerRadius = 4.0;
    _rawLabel.alignment = NSTextAlignmentCenter;
    [_view addSubview:_rawLabel];

    _denoisedLabel = [NSTextField labelWithString:@"Denoised"];
    _denoisedLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _denoisedLabel.textColor = NSColor.whiteColor;
    _denoisedLabel.font = [NSFont systemFontOfSize:14.0f weight:NSFontWeightBold];
    _denoisedLabel.wantsLayer = YES;
    _denoisedLabel.layer.backgroundColor = [[NSColor colorWithWhite:0.0 alpha:0.4] CGColor];
    _denoisedLabel.layer.cornerRadius = 4.0;
    _denoisedLabel.alignment = NSTextAlignmentCenter;
    [_view addSubview:_denoisedLabel];
#endif

    [_metalFXPanel addSubview:_metalFXStatusLabel];
    [_metalFXPanel addSubview:_denoiserModeButton];
    [_metalFXPanel addSubview:_renderModeToggleButton];
    [_metalFXPanel addSubview:_metalFXExposureModeButton];
    [_metalFXPanel addSubview:_metalFXExposureValueLabel];
    [_metalFXPanel addSubview:_metalFXExposureSlider];
    [_metalFXPanel addSubview:_materialRoughnessLabel];
    [_metalFXPanel addSubview:_materialRoughnessSlider];
    [_metalFXPanel addSubview:_materialSpecularLabel];
    [_metalFXPanel addSubview:_materialSpecularSlider];
    [_metalFXPanel addSubview:_sppLabel];
    [_metalFXPanel addSubview:_sppControl];
    [_metalFXPanel addSubview:_hdrToggleButton];
    [_view addSubview:_metalFXPanel];

    id previousBottomAnchor = _denoiserModeButton;
    NSMutableArray<NSLayoutConstraint *> *constraints = [NSMutableArray arrayWithArray:@[
        [_metalFXPanel.topAnchor constraintEqualToAnchor:_view.safeAreaLayoutGuide.topAnchor constant:16.0],
        (_panelLeadingConstraint = [_metalFXPanel.leadingAnchor constraintEqualToAnchor:_view.safeAreaLayoutGuide.leadingAnchor constant:16.0]),
        [_togglePanelButton.topAnchor constraintEqualToAnchor:_metalFXPanel.topAnchor constant:8.0],
        [_togglePanelButton.trailingAnchor constraintEqualToAnchor:_metalFXPanel.trailingAnchor constant:-8.0],
        [_togglePanelButton.widthAnchor constraintEqualToConstant:32.0],
        [_metalFXStatusLabel.topAnchor constraintEqualToAnchor:_metalFXPanel.topAnchor constant:12.0],
        [_metalFXStatusLabel.leadingAnchor constraintEqualToAnchor:_metalFXPanel.leadingAnchor constant:12.0],
        [_metalFXStatusLabel.trailingAnchor constraintEqualToAnchor:_togglePanelButton.leadingAnchor constant:-8.0],
        [_denoiserModeButton.topAnchor constraintEqualToAnchor:_metalFXStatusLabel.bottomAnchor constant:10.0],
        [_denoiserModeButton.leadingAnchor constraintEqualToAnchor:_metalFXPanel.leadingAnchor constant:12.0],
        [_denoiserModeButton.trailingAnchor constraintEqualToAnchor:_metalFXPanel.trailingAnchor constant:-12.0],
        [_renderModeToggleButton.topAnchor constraintEqualToAnchor:_denoiserModeButton.bottomAnchor constant:10.0],
        [_renderModeToggleButton.leadingAnchor constraintEqualToAnchor:_metalFXPanel.leadingAnchor constant:12.0],
        [_renderModeToggleButton.trailingAnchor constraintEqualToAnchor:_metalFXPanel.trailingAnchor constant:-12.0],
        [_metalFXExposureModeButton.topAnchor constraintEqualToAnchor:_renderModeToggleButton.bottomAnchor constant:10.0],
        [_metalFXExposureModeButton.leadingAnchor constraintEqualToAnchor:_metalFXPanel.leadingAnchor constant:12.0],
        [_metalFXExposureModeButton.trailingAnchor constraintEqualToAnchor:_metalFXPanel.trailingAnchor constant:-12.0],
        [_metalFXExposureValueLabel.topAnchor constraintEqualToAnchor:_metalFXExposureModeButton.bottomAnchor constant:8.0],
        [_metalFXExposureValueLabel.leadingAnchor constraintEqualToAnchor:_metalFXPanel.leadingAnchor constant:12.0],
        [_metalFXExposureValueLabel.trailingAnchor constraintEqualToAnchor:_metalFXPanel.trailingAnchor constant:-12.0],
        [_metalFXExposureSlider.topAnchor constraintEqualToAnchor:_metalFXExposureValueLabel.bottomAnchor constant:6.0],
        [_metalFXExposureSlider.leadingAnchor constraintEqualToAnchor:_metalFXPanel.leadingAnchor constant:12.0],
        [_metalFXExposureSlider.trailingAnchor constraintEqualToAnchor:_metalFXPanel.trailingAnchor constant:-12.0],

        [_materialRoughnessLabel.topAnchor constraintEqualToAnchor:_metalFXExposureSlider.bottomAnchor constant:10.0],
        [_materialRoughnessLabel.leadingAnchor constraintEqualToAnchor:_metalFXPanel.leadingAnchor constant:12.0],
        [_materialRoughnessLabel.trailingAnchor constraintEqualToAnchor:_metalFXPanel.trailingAnchor constant:-12.0],
        [_materialRoughnessSlider.topAnchor constraintEqualToAnchor:_materialRoughnessLabel.bottomAnchor constant:6.0],
        [_materialRoughnessSlider.leadingAnchor constraintEqualToAnchor:_metalFXPanel.leadingAnchor constant:12.0],
        [_materialRoughnessSlider.trailingAnchor constraintEqualToAnchor:_metalFXPanel.trailingAnchor constant:-12.0],

        [_materialSpecularLabel.topAnchor constraintEqualToAnchor:_materialRoughnessSlider.bottomAnchor constant:10.0],
        [_materialSpecularLabel.leadingAnchor constraintEqualToAnchor:_metalFXPanel.leadingAnchor constant:12.0],
        [_materialSpecularLabel.trailingAnchor constraintEqualToAnchor:_metalFXPanel.trailingAnchor constant:-12.0],
        [_materialSpecularSlider.topAnchor constraintEqualToAnchor:_materialSpecularLabel.bottomAnchor constant:6.0],
        [_materialSpecularSlider.leadingAnchor constraintEqualToAnchor:_metalFXPanel.leadingAnchor constant:12.0],
        [_materialSpecularSlider.trailingAnchor constraintEqualToAnchor:_metalFXPanel.trailingAnchor constant:-12.0],

        [_sppLabel.topAnchor constraintEqualToAnchor:_materialSpecularSlider.bottomAnchor constant:10.0],
        [_sppLabel.leadingAnchor constraintEqualToAnchor:_metalFXPanel.leadingAnchor constant:12.0],
        [_sppLabel.trailingAnchor constraintEqualToAnchor:_metalFXPanel.trailingAnchor constant:-12.0],
        [_sppControl.topAnchor constraintEqualToAnchor:_sppLabel.bottomAnchor constant:6.0],
        [_sppControl.leadingAnchor constraintEqualToAnchor:_metalFXPanel.leadingAnchor constant:12.0],
        [_sppControl.trailingAnchor constraintEqualToAnchor:_metalFXPanel.trailingAnchor constant:-12.0],
        
        [_hdrToggleButton.topAnchor constraintEqualToAnchor:_sppControl.bottomAnchor constant:10.0],
        [_hdrToggleButton.leadingAnchor constraintEqualToAnchor:_metalFXPanel.leadingAnchor constant:12.0],
        [_hdrToggleButton.trailingAnchor constraintEqualToAnchor:_metalFXPanel.trailingAnchor constant:-12.0],
    ]];

    previousBottomAnchor = _hdrToggleButton;

    for (NSUInteger index = 0; index < _metalFXOptionalButtons.count; index++) {
#if TARGET_OS_IPHONE
        UIButton *button = _metalFXOptionalButtons[index];
#else
        NSButton *button = _metalFXOptionalButtons[index];
#endif
        [constraints addObject:[button.topAnchor constraintEqualToAnchor:[previousBottomAnchor bottomAnchor] constant:8.0]];
        [constraints addObject:[button.leadingAnchor constraintEqualToAnchor:_metalFXPanel.leadingAnchor constant:12.0]];
        [constraints addObject:[button.trailingAnchor constraintEqualToAnchor:_metalFXPanel.trailingAnchor constant:-12.0]];
        previousBottomAnchor = button;
    }

    [constraints addObject:[[previousBottomAnchor bottomAnchor] constraintEqualToAnchor:_metalFXPanel.bottomAnchor constant:-12.0]];

    [constraints addObjectsFromArray:@[
        [_rawLabel.topAnchor constraintEqualToAnchor:_view.safeAreaLayoutGuide.topAnchor constant:16.0],
        [_rawLabel.leadingAnchor constraintEqualToAnchor:_view.safeAreaLayoutGuide.leadingAnchor constant:140.0],
        [_rawLabel.widthAnchor constraintEqualToConstant:80.0],
        [_rawLabel.heightAnchor constraintEqualToConstant:24.0],

        [_denoisedLabel.topAnchor constraintEqualToAnchor:_view.safeAreaLayoutGuide.topAnchor constant:16.0],
        [_denoisedLabel.leadingAnchor constraintEqualToAnchor:_view.centerXAnchor constant:140.0],
        [_denoisedLabel.widthAnchor constraintEqualToConstant:80.0],
        [_denoisedLabel.heightAnchor constraintEqualToConstant:24.0],
    ]];

    [NSLayoutConstraint activateConstraints:constraints];
}

- (void)setupStatisticsOverlay
{
#if TARGET_OS_IPHONE
    _statisticsLabel = [[UILabel alloc] init];
    _statisticsLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _statisticsLabel.textColor = UIColor.whiteColor;
    _statisticsLabel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.55f];
    _statisticsLabel.font = [UIFont monospacedDigitSystemFontOfSize:12.0f weight:UIFontWeightMedium];
    _statisticsLabel.numberOfLines = 0;
    _statisticsLabel.layer.cornerRadius = 10.0f;
    _statisticsLabel.layer.masksToBounds = YES;
    _statisticsLabel.textAlignment = NSTextAlignmentLeft;
    _statisticsLabel.text = @"FPS --\nFrame -- ms\nResolution --\nSPP --";
    [_view addSubview:_statisticsLabel];
#else
    _statisticsLabel = [NSTextField labelWithString:@"FPS --\nFrame -- ms\nResolution --\nSPP --"];
    _statisticsLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _statisticsLabel.textColor = NSColor.whiteColor;
    _statisticsLabel.font = [NSFont monospacedDigitSystemFontOfSize:12.0f weight:NSFontWeightMedium];
    _statisticsLabel.alignment = NSTextAlignmentLeft;
    _statisticsLabel.maximumNumberOfLines = 0;
    _statisticsLabel.wantsLayer = YES;
    _statisticsLabel.layer.backgroundColor = [[NSColor colorWithWhite:0.0f alpha:0.55f] CGColor];
    _statisticsLabel.layer.cornerRadius = 10.0f;
    _statisticsLabel.lineBreakMode = NSLineBreakByWordWrapping;
    [_view addSubview:_statisticsLabel];
#endif

    [NSLayoutConstraint activateConstraints:@[
        [_statisticsLabel.topAnchor constraintEqualToAnchor:_view.safeAreaLayoutGuide.topAnchor constant:16.0],
        [_statisticsLabel.trailingAnchor constraintEqualToAnchor:_view.safeAreaLayoutGuide.trailingAnchor constant:-16.0],
        [_statisticsLabel.widthAnchor constraintGreaterThanOrEqualToConstant:170.0],
    ]];
}

- (void)startStatisticsUpdates
{
    [_statisticsTimer invalidate];
    _statisticsTimer = [NSTimer scheduledTimerWithTimeInterval:0.25
                                                        target:self
                                                      selector:@selector(updateStatisticsLabel)
                                                      userInfo:nil
                                                       repeats:YES];
}

- (void)updateStatisticsLabel
{
    NSString *statisticsText = _renderer.statisticsText;

#if TARGET_OS_IPHONE
    _statisticsLabel.text = statisticsText;
#else
    _statisticsLabel.stringValue = statisticsText;
#endif
}

- (void)dealloc
{
    [_statisticsTimer invalidate];
}

- (void)updateMetalFXControls
{
    if (_renderer.isMetalFXSupported) {
        NSString *modeTitle = [self titleForDenoiserMode:_renderer.denoiserMode];
        NSString *status = _renderer.isMetalFXEnabled ? @"Active" : @"Bypassed";
#if TARGET_OS_IPHONE
        _metalFXStatusLabel.text = [NSString stringWithFormat:@"MTLFXTemporalDenoisedScaler\nMode: %@ (%@)", modeTitle, status];
        [_denoiserModeButton setTitle:[NSString stringWithFormat:@"View: %@", modeTitle] forState:UIControlStateNormal];
        _denoiserModeButton.enabled = YES;
        _denoiserModeButton.alpha = 1.0f;
        NSString *exposureModeTitle = _renderer.isMetalFXAutoExposureEnabled ? @"Exposure: Auto" : @"Exposure: Manual";
        [_metalFXExposureModeButton setTitle:exposureModeTitle forState:UIControlStateNormal];
        _metalFXExposureModeButton.enabled = YES;
        _metalFXExposureModeButton.alpha = 1.0f;
        _metalFXExposureSlider.value = _renderer.metalFXManualExposure;
        _metalFXExposureSlider.enabled = !_renderer.isMetalFXAutoExposureEnabled;
        _metalFXExposureSlider.alpha = _renderer.isMetalFXAutoExposureEnabled ? 0.6f : 1.0f;
        
        NSString *hdrModeTitle = _renderer.isHdrEnabled ? @"Texture Mode: HDR" : @"Texture Mode: sRGB";
        [_hdrToggleButton setTitle:hdrModeTitle forState:UIControlStateNormal];

        _materialRoughnessLabel.text = [NSString stringWithFormat:@"Material Roughness: %.2f", _renderer.roughness];
        _materialRoughnessSlider.value = _renderer.roughness;

        _materialSpecularLabel.text = [NSString stringWithFormat:@"Material Specular: %.2f", _renderer.specularAlbedo];
        _materialSpecularSlider.value = _renderer.specularAlbedo;
#else
        _metalFXStatusLabel.stringValue = [NSString stringWithFormat:@"MTLFXTemporalDenoisedScaler\nMode: %@ (%@)", modeTitle, status];
        _denoiserModeButton.title = [NSString stringWithFormat:@"View: %@", modeTitle];
        _denoiserModeButton.enabled = YES;
        _metalFXExposureModeButton.title = _renderer.isMetalFXAutoExposureEnabled ? @"Exposure: Auto" : @"Exposure: Manual";
        _metalFXExposureModeButton.enabled = YES;
        _metalFXExposureValueLabel.stringValue = [NSString stringWithFormat:@"Manual Exposure: %.2f", _renderer.metalFXManualExposure];
        _metalFXExposureSlider.doubleValue = (double)_renderer.metalFXManualExposure;
        _metalFXExposureSlider.enabled = !_renderer.isMetalFXAutoExposureEnabled;
        
        _hdrToggleButton.title = _renderer.isHdrEnabled ? @"Texture Mode: HDR" : @"Texture Mode: sRGB";

        _materialRoughnessLabel.stringValue = [NSString stringWithFormat:@"Material Roughness: %.2f", _renderer.roughness];
        _materialRoughnessSlider.doubleValue = (double)_renderer.roughness;

        _materialSpecularLabel.stringValue = [NSString stringWithFormat:@"Material Specular: %.2f", _renderer.specularAlbedo];
        _materialSpecularSlider.doubleValue = (double)_renderer.specularAlbedo;

        _sppLabel.stringValue = [NSString stringWithFormat:@"Samples Per Pixel: %lu", (unsigned long)_renderer.samplesPerPixel];
        switch (_renderer.samplesPerPixel) {
            case 1: _sppControl.selectedSegment = 0; break;
            case 2: _sppControl.selectedSegment = 1; break;
            case 4: _sppControl.selectedSegment = 2; break;
            case 8: _sppControl.selectedSegment = 3; break;
            case 16: _sppControl.selectedSegment = 4; break;
            case 32: _sppControl.selectedSegment = 5; break;
        }
#endif

        for (NSUInteger index = 0; index < _metalFXOptionalButtons.count; index++) {
            RendererMetalFXOptionalParameter parameter = (RendererMetalFXOptionalParameter)index;
            BOOL enabled = [_renderer isMetalFXOptionalParameterEnabled:parameter];
            NSString *label = [self titleForMetalFXOptionalParameter:parameter];
            NSString *title = [NSString stringWithFormat:@"%@: %@", label, enabled ? @"On" : @"Off"];
#if TARGET_OS_IPHONE
            UIButton *button = _metalFXOptionalButtons[index];
            [button setTitle:title forState:UIControlStateNormal];
            button.enabled = _renderer.isMetalFXEnabled;
            button.alpha = _renderer.isMetalFXEnabled ? 1.0f : 0.6f;
#else
            NSButton *button = _metalFXOptionalButtons[index];
            button.title = title;
            button.enabled = _renderer.isMetalFXEnabled;
#endif
        }
    } else {
#if TARGET_OS_IPHONE
        _metalFXStatusLabel.text = @"MTLFXTemporalDenoisedScaler\nStatus: Unavailable";
        [_denoiserModeButton setTitle:@"View: Unavailable" forState:UIControlStateNormal];
        _denoiserModeButton.enabled = NO;
        _denoiserModeButton.alpha = 0.6f;
        [_metalFXExposureModeButton setTitle:@"Exposure: Unavailable" forState:UIControlStateNormal];
        _metalFXExposureModeButton.enabled = NO;
        _metalFXExposureModeButton.alpha = 0.6f;
        _metalFXExposureValueLabel.text = @"Manual Exposure: Unavailable";
        _metalFXExposureSlider.enabled = NO;
        _metalFXExposureSlider.alpha = 0.6f;

        _materialRoughnessLabel.text = @"Material Roughness: Unavailable";
        _materialRoughnessSlider.enabled = NO;
        _materialRoughnessSlider.alpha = 0.6f;

        _materialSpecularLabel.text = @"Material Specular: Unavailable";
        _materialSpecularSlider.enabled = NO;
        _materialSpecularSlider.alpha = 0.6f;
#else
        _metalFXStatusLabel.stringValue = @"MTLFXTemporalDenoisedScaler\nStatus: Unavailable";
        _denoiserModeButton.title = @"View: Unavailable";
        _denoiserModeButton.enabled = NO;
        _metalFXExposureModeButton.title = @"Exposure: Unavailable";
        _metalFXExposureModeButton.enabled = NO;
        _metalFXExposureValueLabel.stringValue = @"Manual Exposure: Unavailable";
        _metalFXExposureSlider.enabled = NO;

        _materialRoughnessLabel.stringValue = @"Material Roughness: Unavailable";
        _materialRoughnessSlider.enabled = NO;

        _materialSpecularLabel.stringValue = @"Material Specular: Unavailable";
        _materialSpecularSlider.enabled = NO;
#endif

        for (NSUInteger index = 0; index < _metalFXOptionalButtons.count; index++) {
            NSString *label = [self titleForMetalFXOptionalParameter:(RendererMetalFXOptionalParameter)index];
            NSString *title = [NSString stringWithFormat:@"%@: Unavailable", label];
#if TARGET_OS_IPHONE
            UIButton *button = _metalFXOptionalButtons[index];
            [button setTitle:title forState:UIControlStateNormal];
            button.enabled = NO;
            button.alpha = 0.6f;
#else
            NSButton *button = _metalFXOptionalButtons[index];
            button.title = title;
            button.enabled = NO;
#endif
        }
    }

    BOOL showsSplitLabels = (_renderer.denoiserMode == RendererDenoiserModeSplitScreen &&
                             _renderer.isMetalFXEnabled &&
                             _renderer.renderMode == RendererRenderModeDefault);
#if TARGET_OS_IPHONE
    _rawLabel.hidden = !showsSplitLabels;
    _denoisedLabel.hidden = !showsSplitLabels;
#else
    _rawLabel.hidden = !showsSplitLabels;
    _denoisedLabel.hidden = !showsSplitLabels;
#endif
}

- (NSString *)titleForDenoiserMode:(RendererDenoiserMode)mode
{
    switch (mode) {
        case RendererDenoiserModeRaw:
            return @"Raw";
        case RendererDenoiserModeDenoised:
            return @"Denoised";
        case RendererDenoiserModeSplitScreen:
            return @"Side by Side";
        case RendererDenoiserModeCount:
            break;
    }

    return @"Unknown";
}

- (void)cycleDenoiserMode:(id)sender
{
    RendererDenoiserMode nextMode = (RendererDenoiserMode)((_renderer.denoiserMode + 1) % RendererDenoiserModeCount);
    [_renderer setDenoiserMode:nextMode forView:_view];
    [self updateMetalFXControls];
}

- (void)toggleHdr:(id)sender
{
    [_renderer setHdrEnabled:!_renderer.isHdrEnabled forView:_view];
    [self updateMetalFXControls];
}

- (NSString *)titleForMetalFXOptionalParameter:(RendererMetalFXOptionalParameter)parameter
{
    switch (parameter) {
        case RendererMetalFXOptionalParameterJitter:
            return @"Jitter";
        case RendererMetalFXOptionalParameterDepthTexture:
            return @"Depth Texture";
        case RendererMetalFXOptionalParameterMotionTexture:
            return @"Motion Texture";
        case RendererMetalFXOptionalParameterMotionVectorScale:
            return @"Motion Scale";
        case RendererMetalFXOptionalParameterWorldToViewMatrix:
            return @"WorldToView";
        case RendererMetalFXOptionalParameterViewToClipMatrix:
            return @"ViewToClip";
    }

    return @"Unknown";
}

- (void)toggleMetalFXOptionalParameter:(id)sender
{
#if TARGET_OS_IPHONE
    UIButton *button = (UIButton *)sender;
#else
    NSButton *button = (NSButton *)sender;
#endif
    RendererMetalFXOptionalParameter parameter = (RendererMetalFXOptionalParameter)button.tag;
    BOOL enabled = ![_renderer isMetalFXOptionalParameterEnabled:parameter];
    [_renderer setMetalFXOptionalParameter:parameter enabled:enabled forView:_view];
    [self updateMetalFXControls];
}

- (void)toggleRenderMode:(id)sender
{
    RendererRenderMode nextMode = (RendererRenderMode)((_renderer.renderMode + 1) % RendererRenderModeCount);
    _renderer.renderMode = nextMode;
    
    NSString *modeName = @"Default";
    if (nextMode == RendererRenderModeForward) {
        modeName = @"Forward (Diffuse)";
    } else if (nextMode == RendererRenderModeDepth) {
        modeName = @"Depth";
    } else if (nextMode == RendererRenderModeSpecular) {
        modeName = @"Specular";
    } else if (nextMode == RendererRenderModeRoughness) {
        modeName = @"Roughness";
    } else if (nextMode == RendererRenderModeMotion) {
        modeName = @"Motion";
    } else if (nextMode == RendererRenderModeNormal) {
        modeName = @"Normal";
    }
    
#if TARGET_OS_IPHONE
    [_renderModeToggleButton setTitle:[NSString stringWithFormat:@"Render Mode: %@", modeName] forState:UIControlStateNormal];
#else
    _renderModeToggleButton.title = [NSString stringWithFormat:@"Render Mode: %@", modeName];
#endif
}

- (void)toggleMetalFXExposureMode:(id)sender
{
    [_renderer setMetalFXAutoExposureEnabled:!_renderer.isMetalFXAutoExposureEnabled forView:_view];
    [self updateMetalFXControls];
}

- (void)changeMetalFXExposure:(id)sender
{
#if TARGET_OS_IPHONE
    _renderer.metalFXManualExposure = _metalFXExposureSlider.value;
#else
    _renderer.metalFXManualExposure = (float)_metalFXExposureSlider.doubleValue;
#endif
    [self updateMetalFXControls];
}

- (void)changeRoughness:(id)sender
{
#if TARGET_OS_IPHONE
    _renderer.roughness = _materialRoughnessSlider.value;
#else
    _renderer.roughness = (float)_materialRoughnessSlider.doubleValue;
#endif
    [self updateMetalFXControls];
}

- (void)changeSpecular:(id)sender
{
#if TARGET_OS_IPHONE
    _renderer.specularAlbedo = _materialSpecularSlider.value;
#else
    _renderer.specularAlbedo = (float)_materialSpecularSlider.doubleValue;
#endif
    [self updateMetalFXControls];
}

- (void)changeSPP:(id)sender
{
    NSUInteger spp = 1;
#if TARGET_OS_IPHONE
    switch (_sppControl.selectedSegmentIndex) {
        case 0: spp = 1; break;
        case 1: spp = 2; break;
        case 2: spp = 4; break;
        case 3: spp = 8; break;
        case 4: spp = 16; break;
        case 5: spp = 32; break;
    }
#else
    switch (_sppControl.selectedSegment) {
        case 0: spp = 1; break;
        case 1: spp = 2; break;
        case 2: spp = 4; break;
        case 3: spp = 8; break;
        case 4: spp = 16; break;
        case 5: spp = 32; break;
    }
#endif
    _renderer.samplesPerPixel = spp;
    [self updateMetalFXControls];
}

- (void)togglePanel:(id)sender
{
    _isPanelStowed = !_isPanelStowed;
    
    CGFloat targetConstant = 16.0;
    NSString *buttonTitle = @"◀";
    
    if (_isPanelStowed) {
        // Calculate stowed position: -(panel width - toggle button width - margin)
        // We use a fixed offset for now, or we can use the frame size if available.
        // Since we are using Auto Layout, the frame might not be fully determined here if called immediately,
        // but it should be fine during interaction.
        targetConstant = -(_metalFXPanel.frame.size.width - _togglePanelButton.frame.size.width - 12.0);
        buttonTitle = @"▶";
    }
    
    _panelLeadingConstraint.constant = targetConstant;
    
#if TARGET_OS_IPHONE
    [_togglePanelButton setTitle:buttonTitle forState:UIControlStateNormal];
    [UIView animateWithDuration:0.3 animations:^{
        [self.view layoutIfNeeded];
    }];
#else
    _togglePanelButton.title = buttonTitle;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext * _Nonnull context) {
        context.duration = 0.3;
        context.allowsImplicitAnimation = YES;
        [_metalFXPanel.superview layoutSubtreeIfNeeded];
    }];
#endif
}

@end
