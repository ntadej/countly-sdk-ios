// CountlyStarRating.m
//
// This code is provided under the MIT License.
//
// Please visit www.count.ly for more information.

#import "CountlyCommon.h"
#import <WebKit/WebKit.h>

@interface CountlyStarRating ()
#if TARGET_OS_IOS
@property (nonatomic) UIWindow* alertWindow;
@property (nonatomic) UIAlertController* alertController;
@property (nonatomic, copy) void (^ratingCompletion)(NSInteger);
#endif
@end

NSString* const kCountlyReservedEventStarRating = @"[CLY]_star_rating";
NSString* const kCountlyStarRatingStatusSessionCountKey = @"kCountlyStarRatingStatusSessionCountKey";
NSString* const kCountlyStarRatingStatusHasEverAskedAutomatically = @"kCountlyStarRatingStatusHasEverAskedAutomatically";

NSString* const kCountlySRKeyPlatform    = @"platform";
NSString* const kCountlySRKeyAppVersion  = @"app_version";
NSString* const kCountlySRKeyRating      = @"rating";
NSString* const kCountlySRKeyWidgetID    = @"widget_id";
NSString* const kCountlySRKeyDeviceID    = @"device_id";
NSString* const kCountlySRKeySDKVersion  = @"sdk_version";

NSString* const kCountlyOutputEndpoint = @"/o";
NSString* const kCountlyFeedbackEndpoint = @"/feedback";
NSString* const kCountlyWidgetEndpoint = @"/widget";

@implementation CountlyStarRating
#if TARGET_OS_IOS
{
    UIButton* btn_star[5];
}

const CGFloat kCountlyStarRatingButtonSize = 40.0;

+ (instancetype)sharedInstance
{
    if (!CountlyCommon.sharedInstance.hasStarted)
        return nil;

    static CountlyStarRating* s_sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{s_sharedInstance = self.new;});
    return s_sharedInstance;
}

- (instancetype)init
{
    if (self = [super init])
    {
        NSString* langDesignator = [NSLocale.preferredLanguages.firstObject substringToIndex:2];

        NSDictionary* dictMessage =
        @{
            @"en": @"How would you rate the app?",
            @"tr": @"Uygulamayı nasıl değerlendirirsiniz?",
            @"ja": @"あなたの評価を教えてください。",
            @"zh": @"请告诉我你的评价。",
            @"ru": @"Как бы вы оценили приложение?",
            @"cz": @"Jak hodnotíte aplikaci?",
            @"lv": @"Kā Jūs novērtētu šo lietotni?",
            @"bn": @"আপনি কিভাবে এই এপ্লিক্যাশনটি মূল্যায়ন করবেন?",
            @"hi": @"आप एप्लीकेशन का मूल्यांकन कैसे करेंगे?",
        };

        self.message = dictMessage[langDesignator];
        if (!self.message)
            self.message = dictMessage[@"en"];
    }

    return self;
}

- (void)showDialog:(void(^)(NSInteger rating))completion
{
    if (!CountlyConsentManager.sharedInstance.consentForStarRating)
        return;

    self.ratingCompletion = completion;

    self.alertController = [UIAlertController alertControllerWithTitle:@" " message:self.message preferredStyle:UIAlertControllerStyleAlert];

    CLYButton* dismissButton = [CLYButton dismissAlertButton];
    dismissButton.onClick = ^(id sender)
    {
        [self.alertController dismissViewControllerAnimated:YES completion:^
        {
            [self finishWithRating:0];
        }];
    };
    [self.alertController.view addSubview:dismissButton];

    CLYInternalViewController* cvc = CLYInternalViewController.new;
    [cvc setPreferredContentSize:(CGSize){kCountlyStarRatingButtonSize * 5, kCountlyStarRatingButtonSize * 1.5}];
    [cvc.view addSubview:[self starView]];

    @try
    {
        [self.alertController setValue:cvc forKey:@"contentViewController"];
    }
    @catch (NSException* exception)
    {
        COUNTLY_LOG(@"UIAlertController's contentViewController can not be set: \n%@", exception);
    }

    self.alertWindow = [UIWindow.alloc initWithFrame:UIScreen.mainScreen.bounds];
    self.alertWindow.rootViewController = CLYInternalViewController.new;
    self.alertWindow.windowLevel = UIWindowLevelAlert;
    [self.alertWindow makeKeyAndVisible];
    [self.alertWindow.rootViewController presentViewController:self.alertController animated:YES completion:nil];
}

- (void)checkFeedbackWidgetWithID:(NSString *)widgetID completionHandler:(void (^)(NSError * error))completionHandler
{
    if (!CountlyConsentManager.sharedInstance.consentForStarRating)
        return;

    if (!widgetID.length)
        return;

    NSURL* widgetCheckURL = [self widgetCheckURL:widgetID];
    NSURLRequest* feedbackWidgetCheckRequest = [NSURLRequest requestWithURL:widgetCheckURL];
    NSURLSessionTask* task = [NSURLSession.sharedSession dataTaskWithRequest:feedbackWidgetCheckRequest completionHandler:^(NSData* data, NSURLResponse* response, NSError* error)
    {
        NSDictionary* widgetInfo = nil;

        if (!error)
        {
            widgetInfo = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
        }

        if (!error)
        {
            NSMutableDictionary* userInfo = widgetInfo.mutableCopy;
            
            if (![widgetInfo[@"_id"] isEqualToString:widgetID])
            {
                userInfo[NSLocalizedDescriptionKey] = [NSString stringWithFormat:@"Feedback widget with ID %@ is not available", widgetID];
                error = [NSError errorWithDomain:@"ly.count" code:10001 userInfo:userInfo];
            }
            else if (![self isDeviceTargetedByWidget:widgetInfo])
            {
                userInfo[NSLocalizedDescriptionKey] = [NSString stringWithFormat:@"Feedback widget with ID %@ does not include this device in target devices", widgetID];
                error = [NSError errorWithDomain:@"ly.count" code:10002 userInfo:userInfo];
            }
        }

        if (error)
        {
            dispatch_async(dispatch_get_main_queue(), ^
            {
                if (completionHandler)
                    completionHandler(error);
            });
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^
        {
            [self presentFeedbackWidgetWithID:widgetID completionHandler:completionHandler];
        });
    }];

    [task resume];
}

- (void)presentFeedbackWidgetWithID:(NSString *)widgetID completionHandler:(void (^)(NSError * error))completionHandler
{
    __block UIWindow* window = [UIWindow.alloc initWithFrame:UIScreen.mainScreen.bounds];
    window.rootViewController = CLYInternalViewController.new;
    window.windowLevel = UIWindowLevelAlert;

    __block CLYInternalViewController* webVC = CLYInternalViewController.new;
    webVC.view.backgroundColor = UIColor.whiteColor;
    webVC.view.bounds = UIScreen.mainScreen.bounds;
    webVC.modalPresentationStyle = UIModalPresentationCustom;

    WKWebView* webView = [WKWebView.alloc initWithFrame:webVC.view.bounds];
    [webVC.view addSubview:webView];
    NSURL* widgetDisplayURL = [self widgetDisplayURL:widgetID];
    [webView loadRequest:[NSURLRequest requestWithURL:widgetDisplayURL]];

    CLYButton* dismissButton = [CLYButton dismissAlertButton];
    dismissButton.onClick = ^(id sender)
    {
        [webVC dismissViewControllerAnimated:YES completion:^
        {
            if (completionHandler)
                completionHandler(nil);

            window.hidden = YES;
            window = nil;
            webVC = nil;
        }];
    };
    [webVC.view addSubview:dismissButton];

    [window makeKeyAndVisible];
    [window.rootViewController presentViewController:webVC animated:YES completion:nil];
}

- (NSURL *)widgetCheckURL:(NSString *)widgetID
{
    NSString* URLString = [NSString stringWithFormat:@"%@%@%@%@?%@=%@",
                           CountlyConnectionManager.sharedInstance.host,
                           kCountlyOutputEndpoint, kCountlyFeedbackEndpoint, kCountlyWidgetEndpoint,
                           kCountlySRKeyWidgetID, widgetID];

    return [NSURL URLWithString:URLString];
}

- (NSURL *)widgetDisplayURL:(NSString *)widgetID
{
    NSString* URLString = [NSString stringWithFormat:@"%@%@?%@=%@&%@=%@&%@=%@&%@=%@",
                           CountlyConnectionManager.sharedInstance.host,
                           kCountlyFeedbackEndpoint,
                           kCountlySRKeyWidgetID, widgetID,
                           kCountlySRKeyDeviceID, CountlyDeviceInfo.sharedInstance.deviceID.cly_URLEscaped,
                           kCountlySRKeyAppVersion, CountlyDeviceInfo.appVersion,
                           kCountlySRKeySDKVersion, kCountlySDKVersion];

    return [NSURL URLWithString:URLString];
}

- (BOOL)isDeviceTargetedByWidget:(NSDictionary *)widgetInfo
{
    BOOL isTablet = UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad;
    BOOL isPhone = UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPhone;
    BOOL isTabletTargeted = [widgetInfo[@"target_devices"][@"tablet"] boolValue];
    BOOL isPhoneTargeted = [widgetInfo[@"target_devices"][@"phone"] boolValue];

    return ((isTablet && isTabletTargeted) || (isPhone && isPhoneTargeted));
}

- (void)checkForAutoAsk
{
    if (!self.sessionCount)
        return;

    if (!CountlyConsentManager.sharedInstance.consentForStarRating)
        return;

    NSMutableDictionary* status = [CountlyPersistency.sharedInstance retrieveStarRatingStatus].mutableCopy;

    if (self.disableAskingForEachAppVersion && status[kCountlyStarRatingStatusHasEverAskedAutomatically])
        return;

    NSString* keyForAppVersion = [kCountlyStarRatingStatusSessionCountKey stringByAppendingString:CountlyDeviceInfo.appVersion];
    NSInteger sessionCountSoFar = [status[keyForAppVersion] integerValue];
    sessionCountSoFar++;

    if (self.sessionCount == sessionCountSoFar)
    {
        COUNTLY_LOG(@"Asking for star-rating as session count reached specified limit %d ...", (int)self.sessionCount);

        [self showDialog:self.ratingCompletionForAutoAsk];

        status[kCountlyStarRatingStatusHasEverAskedAutomatically] = @YES;
    }

    status[keyForAppVersion] = @(sessionCountSoFar);

    [CountlyPersistency.sharedInstance storeStarRatingStatus:status];
}

- (UIView *)starView
{
    UIView* vw_star = [UIView.alloc initWithFrame:(CGRect){0, 0, kCountlyStarRatingButtonSize * 5, kCountlyStarRatingButtonSize}];
    vw_star.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleBottomMargin;

    for (int i = 0; i < 5; i++)
    {
        btn_star[i] = [UIButton.alloc initWithFrame:(CGRect){i * kCountlyStarRatingButtonSize, 0, kCountlyStarRatingButtonSize, kCountlyStarRatingButtonSize}];
        btn_star[i].titleLabel.font = [UIFont fontWithName:@"Helvetica" size:28];
        [btn_star[i] setTitle:@"★" forState:UIControlStateNormal];
        [btn_star[i] setTitleColor:[self passiveStarColor] forState:UIControlStateNormal];
        [btn_star[i] addTarget:self action:@selector(onClick_star:) forControlEvents:UIControlEventTouchUpInside];

        [vw_star addSubview:btn_star[i]];
    }

    return vw_star;
}

- (void)setMessage:(NSString *)message
{
    if (!message)
        return;

    _message = message;
}

- (void)onClick_star:(id)sender
{
    UIColor* color = [self activeStarColor];
    NSInteger rating = 0;

    for (int i = 0; i < 5; i++)
    {
        [btn_star[i] setTitleColor:color forState:UIControlStateNormal];

        if (btn_star[i] == sender)
        {
            color = [self passiveStarColor];
            rating = i + 1;
        }
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^
    {
        [self.alertController dismissViewControllerAnimated:YES completion:^{ [self finishWithRating:rating]; }];
    });
}

- (void)finishWithRating:(NSInteger)rating
{
    if (self.ratingCompletion)
        self.ratingCompletion(rating);

    if (rating != 0)
    {
        NSDictionary* segmentation =
        @{
            kCountlySRKeyPlatform: CountlyDeviceInfo.osName,
            kCountlySRKeyAppVersion: CountlyDeviceInfo.appVersion,
            kCountlySRKeyRating: @(rating)
        };

        [Countly.sharedInstance recordReservedEvent:kCountlyReservedEventStarRating segmentation:segmentation];
    }

    self.alertWindow.hidden = YES;
    self.alertWindow = nil;
    self.alertController = nil;
    self.ratingCompletion = nil;
}

- (UIColor *)activeStarColor
{
    return [UIColor colorWithRed:253/255.0 green:148/255.0 blue:38/255.0 alpha:1];
}

- (UIColor *)passiveStarColor
{
    return [UIColor colorWithWhite:178/255.0 alpha:1];
}

#endif
@end
