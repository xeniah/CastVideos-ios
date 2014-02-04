// Copyright 2014 Google Inc. All Rights Reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#import "ChromecastDeviceController.h"
#import "SimpleImageFetcher.h"

static NSString *const kReceiverAppID = @"0482E47D";  //Replace with your app id

@interface ChromecastDeviceController () {
  ChromecastControllerFeatures _features;
  UIImage *_btnImage;
  UIImage *_btnImageConnected;
  dispatch_queue_t _queue;
}

@property GCKMediaControlChannel *mediaControlChannel;
@property GCKApplicationMetadata *applicationMetadata;
@property GCKDevice *selectedDevice;
@property float deviceVolume;
@property bool deviceMuted;
@property(nonatomic) VolumeChangeController *volumeChangeController;
@property(nonatomic) NSArray *idleStateToolbarButtons;
@property(nonatomic) NSArray *playStateToolbarButtons;
@property(nonatomic) NSArray *pauseStateToolbarButtons;
@property(nonatomic) UIImageView *toolbarThumbnailImage;
@property(nonatomic) NSURL *toolbarThumbnailURL;
@property(nonatomic) UILabel *toolbarTitleLabel;
@property(nonatomic) UILabel *toolbarSubTitleLabel;
@end

@implementation ChromecastDeviceController

- (id)init {
  return [self initWithFeatures:ChromecastControllerFeaturesNone];
}

- (id)initWithFeatures:(ChromecastControllerFeatures)featureFlags {
  self = [super init];
  if (self) {
    // Remember the features.
    _features = featureFlags;

    // Init volume change controller if its requested.
    if (featureFlags & ChromecastControllerFeatureHWVolumeControl) {
      self.volumeChangeController = [[VolumeChangeController alloc] init];
      self.volumeChangeController.delegate = self;
    }

    // Initialize device scanner
    self.deviceScanner = [[GCKDeviceScanner alloc] init];

    // Initialize UI controls for navigation bar and tool bar.
    [self initControls];

    _queue = dispatch_queue_create("com.google.sample.Chromecast", NULL);

  }
  return self;
}

- (BOOL)isConnected {
  return self.deviceManager.isConnected;
}

- (BOOL)isPlayingMedia {
  return self.deviceManager.isConnected && self.mediaControlChannel &&
         self.mediaControlChannel.mediaStatus && (self.playerState == GCKMediaPlayerStatePlaying ||
                                                  self.playerState == GCKMediaPlayerStatePaused ||
                                                  self.playerState == GCKMediaPlayerStateBuffering);
}

- (void)performScan:(BOOL)start {

  if (start) {
    [self.deviceScanner addListener:self];
    [self.deviceScanner startScan];
  } else {
    [self.deviceScanner stopScan];
    [self.deviceScanner removeListener:self];
  }
}

- (void)connectToDevice:(GCKDevice *)device {
  self.selectedDevice = device;

  NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
  NSString *appIdentifier = [info objectForKey:@"CFBundleIdentifier"];
  self.deviceManager =
      [[GCKDeviceManager alloc] initWithDevice:self.selectedDevice clientPackageName:appIdentifier];
  self.deviceManager.delegate = self;
  [self.deviceManager connect];
}

- (void)disconnectFromDevice {
  NSLog(@"Disconnecting device:%@", self.selectedDevice.friendlyName);
  // New way of doing things: We're not going to stop the applicaton. We're just going
  // to leave it.
  [self.deviceManager leaveApplication];
  // If you want to force application to stop, uncomment below
  //[self.deviceManager stopApplicationWithSessionID:self.applicationMetadata.sessionID];
  [self.deviceManager disconnect];
}

- (void)updateToolbarForViewController:(UIViewController *)viewController {
  [self updateToolbarStateIn:viewController];
}

- (void)updateStatsFromDevice {
  if (self.isConnected && self.mediaControlChannel && self.mediaControlChannel.mediaStatus) {
    _streamPosition = [self.mediaControlChannel approximateStreamPosition];
    _streamDuration = self.mediaControlChannel.mediaStatus.mediaInformation.streamDuration;

    _playerState = self.mediaControlChannel.mediaStatus.playerState;
    _mediaInformation = self.mediaControlChannel.mediaStatus.mediaInformation;
  }
}

- (void)changeVolumeIncrease:(BOOL)goingUp {
  float idealVolume = self.deviceVolume + (goingUp ? 0.1 : -0.1);
  idealVolume = MIN(1.0, MAX(0.0, idealVolume));

  [self.deviceManager setVolume:idealVolume];
}

- (void)setPlaybackPercent:(float)newPercent {
  newPercent = MAX(MIN(1.0, newPercent), 0.0);

  NSTimeInterval newTime = newPercent * _streamDuration;
  if (_streamDuration > 0 && self.isConnected) {
    [self.mediaControlChannel seekToTimeInterval:newTime];
  }
}

- (void)pauseCastMedia:(BOOL)shouldPause {
  if (self.isConnected && self.mediaControlChannel && self.mediaControlChannel.mediaStatus) {
    if (shouldPause) {
      [self.mediaControlChannel pause];
    } else {
      [self.mediaControlChannel play];
    }
  }
}

- (void)stopCastMedia {
  if (self.isConnected && self.mediaControlChannel && self.mediaControlChannel.mediaStatus) {
    NSLog(@"Telling cast media control channel to stop");
    [self.mediaControlChannel stop];
  }
}

#pragma mark - GCKDeviceManagerDelegate

- (void)deviceManagerDidConnect:(GCKDeviceManager *)deviceManager {
  NSLog(@"connected!!");

  [self.deviceManager launchApplication:kReceiverAppID];
}

- (void)deviceManager:(GCKDeviceManager *)deviceManager
    didConnectToCastApplication:(GCKApplicationMetadata *)applicationMetadata
                      sessionID:(NSString *)sessionID
            launchedApplication:(BOOL)launchedApplication {

  NSLog(@"application has launched");
  self.mediaControlChannel = [[GCKMediaControlChannel alloc] init];
  self.mediaControlChannel.delegate = self;
  [self.deviceManager addChannel:self.mediaControlChannel];
  [self.mediaControlChannel requestStatus];

  self.applicationMetadata = applicationMetadata;
  [self updateCastIconButtonStates];

  if ([self.delegate respondsToSelector:@selector(didConnectToDevice:)]) {
    [self.delegate didConnectToDevice:self.selectedDevice];
  }

  // Hook to hardware volume controls.
  if (_features & ChromecastControllerFeatureHWVolumeControl) {
    [self.volumeChangeController captureVolumeButtons];
  }
}

- (void)deviceManager:(GCKDeviceManager *)deviceManager
    didFailToLaunchCastApplicationWithError:(NSError *)error {
  [self showError:error];

  [self deviceDisconnected];
  [self updateCastIconButtonStates];
  // Hook to hardware volume controls.
  if (_features & ChromecastControllerFeatureHWVolumeControl) {
    [self.volumeChangeController releaseVolumeButtons];
  }
}

- (void)deviceManager:(GCKDeviceManager *)deviceManager
    didFailToConnectWithError:(GCKError *)error {
  [self showError:error];

  [self deviceDisconnected];
  [self updateCastIconButtonStates];
  // Hook to hardware volume controls.
  if (_features & ChromecastControllerFeatureHWVolumeControl) {
    [self.volumeChangeController releaseVolumeButtons];
  }
}

- (void)deviceManager:(GCKDeviceManager *)deviceManager didDisconnectWithError:(GCKError *)error {
  NSLog(@"Received notification that device disconnected");

  if (error != nil) {
    [self showError:error];
  }

  [self deviceDisconnected];
  [self updateCastIconButtonStates];

}

- (void)deviceDisconnected {
  self.mediaControlChannel = nil;
  self.deviceManager = nil;
  self.selectedDevice = nil;

  if ([self.delegate respondsToSelector:@selector(didDisconnect)]) {
    [self.delegate didDisconnect];
  }
}

- (void)deviceManager:(GCKDeviceManager *)deviceManager
    didReceiveStatusForApplication:(GCKApplicationMetadata *)applicationMetadata {
  self.applicationMetadata = applicationMetadata;
}

- (void)deviceManager:(GCKDeviceManager *)deviceManager
    volumeDidChangeToLevel:(float)volumeLevel
                   isMuted:(BOOL)isMuted {
  NSLog(@"New volume level of %f reported!", volumeLevel);
  self.deviceVolume = volumeLevel;
  self.deviceMuted = isMuted;
}

#pragma mark - GCKDeviceScannerListener
- (void)deviceDidComeOnline:(GCKDevice *)device {
  NSLog(@"device found!! %@", device.friendlyName);
  [self updateCastIconButtonStates];
  if ([self.delegate respondsToSelector:@selector(didDiscoverDeviceOnNetwork)]) {
    [self.delegate didDiscoverDeviceOnNetwork];
  }
}

- (void)deviceDidGoOffline:(GCKDevice *)device {
  [self updateCastIconButtonStates];
}

#pragma - GCKMediaControlChannelDelegate methods

- (void)mediaControlChannel:(GCKMediaControlChannel *)mediaControlChannel
    didCompleteLoadWithSessionID:(NSInteger)sessionID {

}

- (void)mediaControlChannelDidUpdateStatus:(GCKMediaControlChannel *)mediaControlChannel {
  [self updateStatsFromDevice];
  NSLog(@"Media control channel status changed");
  if ([self.delegate respondsToSelector:@selector(didReceiveMediaStateChange)]) {
    [self.delegate didReceiveMediaStateChange];
  }
}

- (void)mediaControlChannelDidUpdateMetadata:(GCKMediaControlChannel *)mediaControlChannel {
  [self updateStatsFromDevice];
  NSLog(@"Media control channel metadata changed");

  if ([self.delegate respondsToSelector:@selector(didReceiveMediaStateChange)]) {
    [self.delegate didReceiveMediaStateChange];
  }
}

- (BOOL)loadMedia:(NSURL *)url
     thumbnailURL:(NSURL *)thumbnailURL
            title:(NSString *)title
         subtitle:(NSString *)subtitle
         mimeType:(NSString *)mimeType
        startTime:(NSTimeInterval)startTime
         autoPlay:(BOOL)autoPlay {
  if (!self.deviceManager || !self.deviceManager.isConnected) {
    return NO;
  }

  GCKMediaMetadata *metadata = [[GCKMediaMetadata alloc] init];
  if (title) {
    [metadata setString:title forKey:kGCKMetadataKeyTitle];
  }

  if (subtitle) {
    [metadata setString:subtitle forKey:kGCKMetadataKeySubtitle];
  }

  if (thumbnailURL) {
    [metadata addImage:[[GCKImage alloc] initWithURL:thumbnailURL width:200 height:100]];
  }

  GCKMediaInformation *mediaInformation =
      [[GCKMediaInformation alloc] initWithContentID:[url absoluteString]
                                          streamType:GCKMediaStreamTypeNone
                                         contentType:mimeType
                                            metadata:metadata
                                      streamDuration:0
                                          customData:nil];
  [self.mediaControlChannel loadMedia:mediaInformation autoplay:autoPlay playPosition:startTime];

  return YES;
}

#pragma mark - VolumeChangeControllerDelegate
- (void)didChangeVolumeUp {
  [self changeVolumeIncrease:YES];
}

- (void)didChangeVolumeDown {
  [self changeVolumeIncrease:NO];
}

#pragma mark - implementation

- (void)showError:(NSError *)error {
  UIAlertView *alert = [[UIAlertView alloc] initWithTitle:NSLocalizedString(@"Error", nil)
                                                  message:NSLocalizedString(error.description, nil)
                                                 delegate:nil
                                        cancelButtonTitle:NSLocalizedString(@"OK", nil)
                                        otherButtonTitles:nil];
  [alert show];
}

- (NSString *)getDeviceName {
  if (self.selectedDevice == nil)
    return @"";
  return self.selectedDevice.friendlyName;
}

- (void)initControls {
  // Create chromecast bar button.
  _btnImage = [UIImage imageNamed:@"cast_outline_white.png"];
  _btnImageConnected = [UIImage imageNamed:@"cast_solid_custom.png"];

  UIButton *chromecastButton = [UIButton buttonWithType:UIButtonTypeRoundedRect];
  [chromecastButton addTarget:self
                       action:@selector(chooseDevice:)
             forControlEvents:UIControlEventTouchDown];
  chromecastButton.frame = CGRectMake(0, 0, _btnImage.size.width, _btnImage.size.height);
  [chromecastButton setImage:_btnImage forState:UIControlStateNormal];
  chromecastButton.hidden = YES;

  _chromecastBarButton = [[UIBarButtonItem alloc] initWithCustomView:chromecastButton];

  // Create toolbar buttons for the mini player.
  CGRect frame = CGRectMake(0, 0, 49, 37);
  _toolbarThumbnailImage =
      [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"video_thumb_mini.png"]];
  _toolbarThumbnailImage.frame = frame;
  _toolbarThumbnailImage.contentMode = UIViewContentModeScaleAspectFit;
  UIButton *someButton = [[UIButton alloc] initWithFrame:frame];
  [someButton addSubview:_toolbarThumbnailImage];
  [someButton addTarget:self
                 action:@selector(showMedia)
       forControlEvents:UIControlEventTouchUpInside];
  [someButton setShowsTouchWhenHighlighted:YES];
  UIBarButtonItem *thumbnail = [[UIBarButtonItem alloc] initWithCustomView:someButton];

  UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
  [btn setFrame:CGRectMake(0, 0, 200, 45)];
  _toolbarTitleLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 185, 30)];
  _toolbarTitleLabel.backgroundColor = [UIColor clearColor];
  _toolbarTitleLabel.font = [UIFont systemFontOfSize:17];
  _toolbarTitleLabel.text = @"This is the title";
  _toolbarTitleLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
  _toolbarTitleLabel.textColor = [UIColor blackColor];
  [btn addSubview:_toolbarTitleLabel];

  _toolbarSubTitleLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 15, 185, 30)];
  _toolbarSubTitleLabel.backgroundColor = [UIColor clearColor];
  _toolbarSubTitleLabel.font = [UIFont systemFontOfSize:14];
  _toolbarSubTitleLabel.text = @"This is the sub";
  _toolbarSubTitleLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
  _toolbarSubTitleLabel.textColor = [UIColor grayColor];
  [btn addSubview:_toolbarSubTitleLabel];
  [btn addTarget:self action:@selector(showMedia) forControlEvents:UIControlEventTouchUpInside];
  UIBarButtonItem *titleBtn = [[UIBarButtonItem alloc] initWithCustomView:btn];

  UIBarButtonItem *flexibleSpaceLeft =
      [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
                                                    target:nil
                                                    action:nil];

  UIBarButtonItem *playButton =
      [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemPlay
                                                    target:self
                                                    action:@selector(playMedia)];
  playButton.tintColor = [UIColor blackColor];

  UIBarButtonItem *pauseButton =
      [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemPause
                                                    target:self
                                                    action:@selector(pauseMedia)];
  pauseButton.tintColor = [UIColor blackColor];

  _idleStateToolbarButtons = [NSArray arrayWithObjects:thumbnail, titleBtn, flexibleSpaceLeft, nil];
  _playStateToolbarButtons =
      [NSArray arrayWithObjects:thumbnail, titleBtn, flexibleSpaceLeft, pauseButton, nil];
  _pauseStateToolbarButtons =
      [NSArray arrayWithObjects:thumbnail, titleBtn, flexibleSpaceLeft, playButton, nil];
}

- (void)chooseDevice:(id)sender {
  if ([self.delegate respondsToSelector:@selector(shouldDisplayModalDeviceController)]) {
    [_delegate shouldDisplayModalDeviceController];
  }
}

- (void)updateCastIconButtonStates {
  // Hide the button if there are no devices found.
  UIButton *chromecastButton = (UIButton *)self.chromecastBarButton.customView;
  if (self.deviceScanner.devices.count == 0) {
    chromecastButton.hidden = YES;
  } else {
    chromecastButton.hidden = NO;
    if (self.deviceManager && self.deviceManager.isConnected) {
      // Hilight with yellow tint color.
      [chromecastButton setTintColor:[UIColor yellowColor]];
      [chromecastButton setImage:_btnImageConnected forState:UIControlStateNormal];

    } else {
      // Remove the hilight.
      [chromecastButton setTintColor:nil];
      [chromecastButton setImage:_btnImage forState:UIControlStateNormal];
    }
  }
}

- (void)updateToolbarStateIn:(UIViewController *)viewController {
  // Ignore this view controller if it is not visible.
  if (!(viewController.isViewLoaded && viewController.view.window)) {
    return;
  }
  // Get the playing status.
  if (self.isPlayingMedia) {
    viewController.navigationController.toolbarHidden = NO;
  } else {
    viewController.navigationController.toolbarHidden = YES;
    return;
  }

  // Update the play/pause state.
  if (self.playerState == GCKMediaPlayerStateUnknown ||
      self.playerState == GCKMediaPlayerStateIdle) {
    viewController.toolbarItems = self.idleStateToolbarButtons;
  } else {
    BOOL playing = (self.playerState == GCKMediaPlayerStatePlaying ||
                    self.playerState == GCKMediaPlayerStateBuffering);
    if (playing) {
      viewController.toolbarItems = self.playStateToolbarButtons;
    } else {
      viewController.toolbarItems = self.pauseStateToolbarButtons;
    }
  }

  // Update the title.
  self.toolbarTitleLabel.text = [self.mediaInformation.metadata stringForKey:kGCKMetadataKeyTitle];
  self.toolbarSubTitleLabel.text =
      [self.mediaInformation.metadata stringForKey:kGCKMetadataKeySubtitle];

  // Update the image.
  GCKImage *img = [self.mediaInformation.metadata.images objectAtIndex:0];
  if ([img.URL isEqual:self.toolbarThumbnailURL]) {
    return;
  }

  //Loading thumbnail async
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    UIImage *image = [UIImage imageWithData:[SimpleImageFetcher getDataFromImageURL:img.URL]];

    dispatch_async(dispatch_get_main_queue(), ^{
      NSLog(@"Loaded thumbnail image");
      self.toolbarThumbnailURL = img.URL;
      self.toolbarThumbnailImage.image = image;
    });
  });
}

- (void)playMedia {
  [self pauseCastMedia:NO];
}

- (void)pauseMedia {
  [self pauseCastMedia:YES];
}

- (void)showMedia {
  if ([self.delegate respondsToSelector:@selector(shouldPresentPlaybackController)]) {
    [self.delegate shouldPresentPlaybackController];
  }
}
@end
