//
//  MIT License
//
//  Copyright (c) 2014 Bob McCune http://bobmccune.com/
//  Copyright (c) 2014 TapHarmonic, LLC http://tapharmonic.com/
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.
//

#import "THPlayerController.h"
#import "THThumbnail.h"
#import <AVFoundation/AVFoundation.h>
#import "THTransport.h"
#import "THPlayerView.h"
#import "AVAsset+THAdditions.h"
#import "UIAlertView+THAdditions.h"
#import "THNotifications.h"

// AVPlayerItem's status property
#define STATUS_KEYPATH @"status"

// Refresh interval for timed observations of AVPlayer
#define REFRESH_INTERVAL 0.5f

// Define this constant for the key-value observation context.
static const NSString *PlayerItemStatusContext;


@interface THPlayerController () <THTransportDelegate>

@property (strong, nonatomic) AVAsset *asset;
@property (strong, nonatomic) AVPlayerItem *playerItem;
@property (strong, nonatomic) AVPlayer *player;
@property (strong, nonatomic) THPlayerView *playerView;

@property (weak, nonatomic) id <THTransport> transport;

@property (strong, nonatomic) id timeObserver;
@property (strong, nonatomic) id itemEndObserver;
@property (assign, nonatomic) float lastPlaybackRate;

@property (strong, nonatomic) AVAssetImageGenerator *imageGenerator;

@end

@implementation THPlayerController

#pragma mark - Setup

- (id)initWithURL:(NSURL *)assetURL {
    self = [super init];
    if (self) {
        _asset = [AVAsset assetWithURL:assetURL];                           // 1
        [self prepareToPlay];
    }
    return self;
}

- (void)prepareToPlay {
    NSArray *keys = @[
        @"tracks",
        @"duration",
        @"commonMetadata",
        @"availableMediaCharacteristicsWithMediaSelectionOptions"
    ];
    //PlayerItem 自动加载AVAsset中属性值（通过keys 数组）iOS 7 改进后提供的
    self.playerItem = [AVPlayerItem playerItemWithAsset:self.asset          // 2
                           automaticallyLoadedAssetKeys:keys];

    [self.playerItem addObserver:self                                       // 3
                      forKeyPath:STATUS_KEYPATH
                         options:0
                         context:&PlayerItemStatusContext];

    self.player = [AVPlayer playerWithPlayerItem:self.playerItem];          // 4

    self.playerView = [[THPlayerView alloc] initWithPlayer:self.player];    // 5
    self.transport = self.playerView.transport;
    self.transport.delegate = self;
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context {
    
    if (context == &PlayerItemStatusContext) {
        
        dispatch_async(dispatch_get_main_queue(), ^{                        // 1
            
            [self.playerItem removeObserver:self forKeyPath:STATUS_KEYPATH];
            
            if (self.playerItem.status == AVPlayerItemStatusReadyToPlay) {
                
                // Set up time observers.      添加时间播放器时间监听                             // 2
                [self addPlayerItemTimeObserver];
                [self addItemEndObserverForPlayerItem];
                //获取时长
                CMTime duration = self.playerItem.duration;
                
                // Synchronize the time display  同步播放                        // 3
                [self.transport setCurrentTime:CMTimeGetSeconds(kCMTimeZero)
                                      duration:CMTimeGetSeconds(duration)];
                
                // Set the video title. （视频标题 视频名字）
                [self.transport setTitle:self.asset.title];                 // 4
                
                [self.player play];                                         // 5
                
                [self loadMediaOptions]; //
                [self generateThumbnails]; //创建视频片段
                
            } else {
                [UIAlertView showAlertWithTitle:@"Error"
                                        message:@"Failed to load video"];
            }
        });
    }
}

//加载视频中包含备用媒体呈现方式 备用音频，视频或文本轨道 例如字慕
- (void)loadMediaOptions {
    NSString *mc = AVMediaCharacteristicLegible;  //字幕或隐藏式字幕                          // 1
    AVMediaSelectionGroup *group =
        [self.asset mediaSelectionGroupForMediaCharacteristic:mc];          // 2
    if (group) {
        NSMutableArray *subtitles = [NSMutableArray array];                 // 3
        for (AVMediaSelectionOption *option in group.options) {
            [subtitles addObject:option.displayName];
            NSLog(@"dispalay name == %@",option.displayName);
        }
        [self.transport setSubtitles:subtitles];                            // 4
    } else {
        [self.transport setSubtitles:nil];
    }
}

//设置选好的 字慕
- (void)subtitleSelected:(NSString *)subtitle {
    NSString *mc = AVMediaCharacteristicLegible;
    AVMediaSelectionGroup *group =
        [self.asset mediaSelectionGroupForMediaCharacteristic:mc];          // 1
    BOOL selected = NO;
    for (AVMediaSelectionOption *option in group.options) {
        if ([option.displayName isEqualToString:subtitle]) {
            [self.playerItem selectMediaOption:option                       // 2
                         inMediaSelectionGroup:group];
            selected = YES;
        }
    }
    if (!selected) {
        [self.playerItem selectMediaOption:nil                              // 3
                     inMediaSelectionGroup:group];
    }
}


#pragma mark - Time Observers

- (void)addPlayerItemTimeObserver {
    
    // Create 0.5 second refresh interval - REFRESH_INTERVAL == 0.5
    CMTime interval =
        CMTimeMakeWithSeconds(REFRESH_INTERVAL, NSEC_PER_SEC);              // 1
    
    // Main dispatch queue
    dispatch_queue_t queue = dispatch_get_main_queue();                     // 2
    
    // Create callback block for time observer
    __weak THPlayerController *weakSelf = self;                             // 3
    void (^callback)(CMTime time) = ^(CMTime time) {
        NSTimeInterval currentTime = CMTimeGetSeconds(time);
        NSTimeInterval duration = CMTimeGetSeconds(weakSelf.playerItem.duration);
        [weakSelf.transport setCurrentTime:currentTime duration:duration];  // 4
    };
    
    // Add observer and store pointer for future use  添加周期性的监听方法（AVPlayer）
    self.timeObserver =                                                     // 5
        [self.player addPeriodicTimeObserverForInterval:interval
                                                  queue:queue
                                             usingBlock:callback];
}

//播放条目结束监听
- (void)addItemEndObserverForPlayerItem {

    NSString *name = AVPlayerItemDidPlayToEndTimeNotification;

    //通过主队列 监听播放条目是否执行完成
    NSOperationQueue *queue = [NSOperationQueue mainQueue];

    __weak THPlayerController *weakSelf = self;                             // 1
    void (^callback)(NSNotification *note) = ^(NSNotification *notification) {
        [weakSelf.player seekToTime:kCMTimeZero                             // 2
                  completionHandler:^(BOOL finished) {
            [weakSelf.transport playbackComplete];                          // 3
        }];
    };

    self.itemEndObserver =                                                  // 4
        [[NSNotificationCenter defaultCenter] addObserverForName:name
                                                          object:self.playerItem
                                                           queue:queue
                                                      usingBlock:callback];
}

#pragma mark - THTransportDelegate Methods

- (void)play {
    [self.player play];
}

- (void)pause {
    self.lastPlaybackRate = self.player.rate;
    [self.player pause];
}

- (void)stop {
    [self.player setRate:0.0f];
    [self.transport playbackComplete];
}

- (void)jumpedToTime:(NSTimeInterval)time {
    [self.player seekToTime:CMTimeMakeWithSeconds(time, NSEC_PER_SEC)];
}

- (void)scrubbingDidStart {                                                 // 1
    self.lastPlaybackRate = self.player.rate;//保存当前播放速率
    [self.player pause]; //暂停播放
    //移除时间监控
    [self.player removeTimeObserver:self.timeObserver];
    self.timeObserver = nil;
}

- (void)scrubbedToTime:(NSTimeInterval)time {                               // 2
    [self.playerItem cancelPendingSeeks];
    [self.player seekToTime:CMTimeMakeWithSeconds(time, NSEC_PER_SEC) toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
}

- (void)scrubbingDidEnd {
    // 3
    [self addPlayerItemTimeObserver]; //添加时间监控
    if (self.lastPlaybackRate > 0.0f) {
        [self.player play];
    }
}


#pragma mark - Thumbnail Generation

- (void)generateThumbnails {
    NSLog(@"🐶🐶🐶🐶%s",__func__);
    self.imageGenerator =                                                   // 1
        [AVAssetImageGenerator assetImageGeneratorWithAsset:self.asset];
    
    // Generate the @2x equivalent
    self.imageGenerator.maximumSize = CGSizeMake(200.0f, 0.0f);             // 2

    CMTime duration = self.asset.duration;

    NSMutableArray *times = [NSMutableArray array];                         // 3
    CMTimeValue increment = duration.value / 20;
    CMTimeValue currentValue = 2.0 * duration.timescale; //开始时间端
    while (currentValue <= duration.value) {
        CMTime time = CMTimeMake(currentValue, duration.timescale);
        [times addObject:[NSValue valueWithCMTime:time]];
        currentValue += increment;
    }

    __block NSUInteger imageCount = times.count;                            // 4
    __block NSMutableArray *images = [NSMutableArray array];

    AVAssetImageGeneratorCompletionHandler handler;                         // 5
    
    handler = ^(CMTime requestedTime,
                CGImageRef imageRef,
                CMTime actualTime,
                AVAssetImageGeneratorResult result,
                NSError *error) {
        NSLog(@"======🐶 request seconds == %@  actual seconds == %@",@(CMTimeGetSeconds(requestedTime)),@(CMTimeGetSeconds(actualTime)));//循环 20次 （handler被执行 20次）
        if (result == AVAssetImageGeneratorSucceeded) {                     // 6
            UIImage *image = [UIImage imageWithCGImage:imageRef];
            id thumbnail =
                [THThumbnail thumbnailWithImage:image time:actualTime];
            [images addObject:thumbnail];
        } else {
            NSLog(@"Error: %@", [error localizedDescription]);
        }

        // If the decremented image count is at 0, we're all done.  （图片数量一直递减，直到0时，图片生成完成 发送通知）
        if (--imageCount == 0) {                                            // 7
            dispatch_async(dispatch_get_main_queue(), ^{
                NSString *name = THThumbnailsGeneratedNotification;
                NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
                [nc postNotificationName:name object:images];
            });
        }
    };

    [self.imageGenerator generateCGImagesAsynchronouslyForTimes:times       // 8
                                              completionHandler:handler];
}


#pragma mark - Housekeeping

- (UIView *)view {
    return self.playerView;
}

- (void)dealloc {
    if (self.itemEndObserver) {                                             // 5
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc removeObserver:self.itemEndObserver
                      name:AVPlayerItemDidPlayToEndTimeNotification
                    object:self.player.currentItem];
        self.itemEndObserver = nil;
    }
}


@end
