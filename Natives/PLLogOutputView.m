#import "PLLogOutputView.h"
#import "LauncherPreferences.h"
#import "SurfaceViewController.h"
#import "utils.h"

@interface PLLogOutputView()<UITableViewDataSource, UITableViewDelegate>
@property(nonatomic) UITableView* logTableView;
@property(nonatomic) UINavigationBar* navigationBar;
@end

@implementation PLLogOutputView
static BOOL fatalErrorOccurred;
static BOOL crashAIAnalysisInProgress;
static NSInteger lastExitCode;
static NSMutableArray* logLines;
static PLLogOutputView* current;

static NSString *const PLCrashAIBaseURLPref = @"crash_ai.base_url";
static NSString *const PLCrashAIAPIKeyPref = @"crash_ai.api_key";
static NSString *const PLCrashAIModelPref = @"crash_ai.model";
static NSString *const PLCrashAILogTailLinesPref = @"crash_ai.log_tail_lines";

- (instancetype)initWithFrame:(CGRect)frame {
    UIViewController *vc = [UIViewController new];
    vc.view = self;
    self.navController = [[UINavigationController alloc] initWithRootViewController:vc];
    self.navigationBar = self.navController.navigationBar;
    
    frame.origin.y = frame.size.height;
    self = [super initWithFrame:frame];
    frame.origin.y = 0;

    logLines = [NSMutableArray new];
    self.backgroundColor = [UIColor colorWithWhite:0 alpha:0.5];
    self.navController.view.hidden = YES;

    vc.navigationItem.rightBarButtonItems = @[
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemStop
            target:self action:@selector(actionToggleLogOutput)],
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemTrash
            target:self action:@selector(actionClearLogOutput)]
    ];
    vc.title = localize(@"game.menu.log_output", nil);

    self.logTableView = [[UITableView alloc] initWithFrame:frame];
    //self.logTableView.allowsSelection = NO;
    self.logTableView.autoresizingMask = UIViewAutoresizingFlexibleHeight | UIViewAutoresizingFlexibleWidth;
    self.logTableView.backgroundColor = UIColor.clearColor;
    self.logTableView.contentInset = UIEdgeInsetsMake(self.navigationBar.frame.size.height, 0, 0, 0);
    self.logTableView.dataSource = self;
    self.logTableView.delegate = self;
    self.logTableView.layoutMargins = UIEdgeInsetsZero;
    self.logTableView.rowHeight = 20;
    self.logTableView.separatorInset = UIEdgeInsetsZero;
    self.logTableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    [self addSubview:self.logTableView];
    [self addSubview:self.navigationBar];

    canAppendToLog = YES;
    [self actionStartStopLogOutput];

    current = self;
    return self;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return logLines.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell"];

    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"cell"];
        cell.backgroundColor = UIColor.clearColor;
        //cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.font = [UIFont fontWithName:@"Menlo-Regular" size:16];
        cell.textLabel.textColor = UIColor.whiteColor;
    }
    cell.textLabel.text = logLines[indexPath.row];

    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:NO];

    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    NSString *line = cell.textLabel.text;
    if (line.length == 0 || [line isEqualToString:@"\n"]) {
        return;
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil message:line preferredStyle:UIAlertControllerStyleActionSheet];
    alert.popoverPresentationController.sourceView = cell;
    alert.popoverPresentationController.sourceRect = cell.bounds;
    UIAlertAction *share = [UIAlertAction actionWithTitle:localize(localize(@"Share", nil), nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        UIActivityViewController *activityVC = [[UIActivityViewController alloc] initWithActivityItems:@[line] applicationActivities:nil];
        activityVC.popoverPresentationController.sourceView = _navigationBar;
        activityVC.popoverPresentationController.sourceRect = _navigationBar.bounds;
        [currentVC() presentViewController:activityVC animated:YES completion:nil];
    }];
    UIAlertAction *cancel = [UIAlertAction actionWithTitle:localize(@"Cancel", nil) style:UIAlertActionStyleCancel handler:nil];
    [alert addAction:share];
    [alert addAction:cancel];
    [currentVC() presentViewController:alert animated:YES completion:nil];
}

- (void)actionClearLogOutput {
    [logLines removeAllObjects];
    [self.logTableView reloadData];
}

- (void)actionShareLatestlog {
    NSString *latestlogPath = [NSString stringWithFormat:@"file://%s/latestlog.txt", getenv("POJAV_HOME")];
    UIActivityViewController *activityVC = [[UIActivityViewController alloc] initWithActivityItems:@[@"latestlog.txt",
        [NSURL URLWithString:latestlogPath]] applicationActivities:nil];
    activityVC.popoverPresentationController.sourceView = self.navigationBar;
        activityVC.popoverPresentationController.sourceRect = self.navigationBar.bounds;
    [currentVC() presentViewController:activityVC animated:YES completion:nil];
}

- (NSString *)crashAIBaseURL {
    NSString *baseURL = getPrefObject(PLCrashAIBaseURLPref);
    if (baseURL.length == 0 && getenv("DS2API_BASE_URL")) {
        baseURL = @(getenv("DS2API_BASE_URL"));
    }
    if (baseURL.length == 0) {
        baseURL = @"http://127.0.0.1:5001/v1";
    }
    return [baseURL stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

- (BOOL)hasCrashAIBaseURLConfigured {
    NSString *baseURL = getPrefObject(PLCrashAIBaseURLPref);
    return baseURL.length > 0 || getenv("DS2API_BASE_URL") != NULL;
}

- (NSString *)crashAIAPIKey {
    NSString *apiKey = getPrefObject(PLCrashAIAPIKeyPref);
    if (apiKey.length == 0 && getenv("DS2API_API_KEY")) {
        apiKey = @(getenv("DS2API_API_KEY"));
    }
    return [apiKey stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

- (NSString *)crashAIModel {
    NSString *model = getPrefObject(PLCrashAIModelPref);
    if (model.length == 0 && getenv("DS2API_MODEL")) {
        model = @(getenv("DS2API_MODEL"));
    }
    if (model.length == 0) {
        model = @"deepseek-v4-pro";
    }
    return [model stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

- (NSURL *)crashAIChatURL {
    NSString *baseURL = [self crashAIBaseURL];
    while ([baseURL hasSuffix:@"/"]) {
        baseURL = [baseURL substringToIndex:baseURL.length - 1];
    }
    if (![baseURL hasSuffix:@"/chat/completions"]) {
        baseURL = [baseURL stringByAppendingString:@"/chat/completions"];
    }
    return [NSURL URLWithString:baseURL];
}

- (NSString *)latestLogText {
    NSString *latestlogPath = [NSString stringWithFormat:@"%s/latestlog.txt", getenv("POJAV_HOME")];
    NSString *text = [NSString stringWithContentsOfFile:latestlogPath encoding:NSUTF8StringEncoding error:nil];
    if (text.length > 0) {
        return text;
    }

    NSString *oldLogPath = [NSString stringWithFormat:@"%s/latestlog.old.txt", getenv("POJAV_HOME")];
    return [NSString stringWithContentsOfFile:oldLogPath encoding:NSUTF8StringEncoding error:nil] ?: @"";
}

- (NSString *)redactedCrashLog:(NSString *)log {
    NSMutableString *redacted = log.mutableCopy;
    NSArray<NSArray<NSString *> *> *rules = @[
        @[@"(?i)\\b(access[_-]?token|refresh[_-]?token|id[_-]?token|session[_-]?id|authorization|bearer|cookie|password)\\b\\s*[:=]\\s*[^\\s,;]+", @"$1=<redacted>"],
        @[@"(?i)Bearer\\s+[A-Za-z0-9._~+\\-/=]+", @"Bearer <redacted>"],
        @[@"(?i)[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}", @"<email>"]
    ];

    for (NSArray<NSString *> *rule in rules) {
        NSError *error;
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:rule[0] options:0 error:&error];
        if (error) {
            continue;
        }
        NSString *next = [regex stringByReplacingMatchesInString:redacted
                                                          options:0
                                                            range:NSMakeRange(0, redacted.length)
                                                     withTemplate:rule[1]];
        redacted = next.mutableCopy;
    }
    return redacted;
}

- (NSString *)crashLogTailForAI:(NSString *)log {
    NSInteger maxLines = [getPrefObject(PLCrashAILogTailLinesPref) integerValue];
    if (maxLines <= 0) {
        maxLines = 300;
    }

    NSArray<NSString *> *lines = [log componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
    NSUInteger start = lines.count > (NSUInteger)maxLines ? lines.count - (NSUInteger)maxLines : 0;
    NSString *tail = [[lines subarrayWithRange:NSMakeRange(start, lines.count - start)] componentsJoinedByString:@"\n"];
    if (tail.length > 32000) {
        tail = [tail substringFromIndex:tail.length - 32000];
    }
    return [self redactedCrashLog:tail];
}

- (void)presentCrashAIConfigPrompt {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"AI Crash Analyzer"
        message:@"Enter the DS2API endpoint reachable from this device. For an iPhone on Wi-Fi, use the PC LAN IP, not 127.0.0.1."
        preferredStyle:UIAlertControllerStyleAlert];

    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"http://192.168.x.x:5001/v1";
        textField.text = [self crashAIBaseURL];
        textField.keyboardType = UIKeyboardTypeURL;
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"API key";
        textField.text = [self crashAIAPIKey];
        textField.secureTextEntry = YES;
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"deepseek-v4-pro";
        textField.text = [self crashAIModel];
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
    }];

    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Save & Analyze" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        NSString *baseURL = [alert.textFields[0].text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSString *apiKey = [alert.textFields[1].text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSString *model = [alert.textFields[2].text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (model.length == 0) {
            model = @"deepseek-v4-pro";
        }
        setPrefObject(PLCrashAIBaseURLPref, baseURL);
        setPrefObject(PLCrashAIAPIKeyPref, apiKey);
        setPrefObject(PLCrashAIModelPref, model);
        [weakSelf actionAnalyzeCrashWithAI];
    }]];

    [currentVC() presentViewController:alert animated:YES completion:nil];
}

- (void)appendAIAnalysis:(NSString *)analysis {
    [PLLogOutputView _appendToLog:@"--- AI Crash Analysis ---"];
    for (NSString *line in [analysis componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        [PLLogOutputView _appendToLog:line];
    }
}

- (void)showAIAnalysis:(NSString *)analysis {
    NSString *message = analysis.length > 5000 ? [[analysis substringToIndex:5000] stringByAppendingString:@"\n\n..."] : analysis;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"AI Crash Analysis"
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"Share", nil) style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        UIActivityViewController *activityVC = [[UIActivityViewController alloc] initWithActivityItems:@[analysis] applicationActivities:nil];
        activityVC.popoverPresentationController.sourceView = self.navigationBar;
        activityVC.popoverPresentationController.sourceRect = self.navigationBar.bounds;
        [currentVC() presentViewController:activityVC animated:YES completion:nil];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [currentVC() presentViewController:alert animated:YES completion:nil];
}

- (void)showAIError:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"AI Crash Analyzer"
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [currentVC() presentViewController:alert animated:YES completion:nil];
}

- (void)actionAnalyzeCrashWithAI {
    if (crashAIAnalysisInProgress) {
        return;
    }

    if (![self hasCrashAIBaseURLConfigured] || [self crashAIAPIKey].length == 0) {
        [self presentCrashAIConfigPrompt];
        return;
    }

    NSURL *url = [self crashAIChatURL];
    if (!url) {
        [self showAIError:@"Invalid DS2API Base URL."];
        return;
    }

    NSString *log = [self latestLogText];
    if (log.length == 0) {
        [self showAIError:@"No latestlog.txt or latestlog.old.txt content was found."];
        return;
    }

    crashAIAnalysisInProgress = YES;
    [PLLogOutputView _appendToLog:@"[AI] Analyzing crash log..."];

    NSString *logTail = [self crashLogTailForAI:log];
    NSString *systemPrompt = @"You are a Minecraft Java crash analyst for an iOS/iPadOS Amethyst/Pojav-style launcher. Reply in Vietnamese. Be concise but practical. Use the log evidence only. Structure the answer as: 1) Nguyen nhan kha nghi, 2) Bang chung trong log, 3) Cach sua cu the, 4) Can gui them gi neu chua du thong tin.";
    NSString *userPrompt = [NSString stringWithFormat:@"Exit code: %ld\n\nCrash log tail:\n```text\n%@\n```", (long)lastExitCode, logTail];
    NSDictionary *payload = @{
        @"model": [self crashAIModel],
        @"temperature": @(0.2),
        @"stream": @NO,
        @"messages": @[
            @{@"role": @"system", @"content": systemPrompt},
            @{@"role": @"user", @"content": userPrompt}
        ]
    };
    NSError *jsonError;
    NSData *body = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&jsonError];
    if (!body) {
        crashAIAnalysisInProgress = NO;
        [self showAIError:jsonError.localizedDescription ?: @"Failed to create AI request payload."];
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    request.HTTPBody = body;
    request.timeoutInterval = 60;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:[NSString stringWithFormat:@"Bearer %@", [self crashAIAPIKey]] forHTTPHeaderField:@"Authorization"];

    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                crashAIAnalysisInProgress = NO;
                if (error) {
                    [self showAIError:error.localizedDescription];
                    return;
                }

                NSInteger statusCode = [(NSHTTPURLResponse *)response statusCode];
                NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
                if (statusCode < 200 || statusCode >= 300) {
                    NSString *apiMessage = json[@"error"][@"message"];
                    if (apiMessage.length == 0) {
                        apiMessage = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                    }
                    [self showAIError:apiMessage ?: [NSString stringWithFormat:@"DS2API returned HTTP %ld.", (long)statusCode]];
                    return;
                }

                NSString *analysis = json[@"choices"][0][@"message"][@"content"];
                if (analysis.length == 0) {
                    analysis = @"AI response did not contain choices[0].message.content.";
                }
                [self appendAIAnalysis:analysis];
                [self showAIAnalysis:analysis];
            });
        }];
    [task resume];
}

- (void)actionStartStopLogOutput {
    canAppendToLog = !canAppendToLog;
    UINavigationItem* item = self.navigationBar.items[0];
    item.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:
            canAppendToLog ? UIBarButtonSystemItemPause : UIBarButtonSystemItemPlay
        target:self action:@selector(actionStartStopLogOutput)];
}

- (void)actionToggleLogOutput {
    if (fatalErrorOccurred) {
        [UIApplication.sharedApplication performSelector:@selector(suspend)];
        dispatch_group_leave(fatalExitGroup);
        return;
    }

    UIViewAnimationOptions opt = self.navController.view.hidden ? UIViewAnimationOptionCurveEaseOut : UIViewAnimationOptionCurveEaseIn;
    [UIView transitionWithView:self duration:0.4 options:UIViewAnimationOptionCurveEaseOut animations:^(void){
        CGRect frame = self.frame;
        frame.origin.y = self.navController.view.hidden ? 0 : frame.size.height;
        self.navController.view.hidden = NO;
        self.frame = frame;
    } completion: ^(BOOL finished) {
        self.navController.view.hidden = self.frame.origin.y != 0;
    }];
}

+ (void)_appendToLog:(NSString *)line {
    if (line.length == 0) {
        return;
    }

    NSIndexPath *indexPath = [NSIndexPath indexPathForRow:logLines.count inSection:0];
    [logLines addObject:line];
    UIView.animationsEnabled = NO;
    [current.logTableView beginUpdates];
    [current.logTableView
        insertRowsAtIndexPaths:@[indexPath]
        withRowAnimation:UITableViewRowAnimationNone];
    [current.logTableView endUpdates];
    UIView.animationsEnabled = YES;

    [current.logTableView 
        scrollToRowAtIndexPath:indexPath
        atScrollPosition:UITableViewScrollPositionBottom animated:NO];
}

+ (void)appendToLog:(NSString *)string {
    dispatch_async(dispatch_get_main_queue(), ^(void){
        NSArray *lines = [string componentsSeparatedByCharactersInSet:
            NSCharacterSet.newlineCharacterSet];
        for (NSString *line in lines) {
            [self _appendToLog:line];
        }
    });
}

+ (void)handleExitCode:(int)code {
    if (!current) return;
    lastExitCode = code;
    dispatch_async(dispatch_get_main_queue(), ^(void){
        if (current.navController.view.hidden) {
            [current actionToggleLogOutput];
        }
        // Cleanup navigation bar
        UINavigationBar *navigationBar = current.navigationBar;
        navigationBar.topItem.title = [NSString stringWithFormat:
            localize(@"game.title.exit_code", nil), code];
        navigationBar.items[0].leftBarButtonItem = [[UIBarButtonItem alloc]
            initWithBarButtonSystemItem:UIBarButtonSystemItemAction
            target:current action:@selector(actionShareLatestlog)];
        UIBarButtonItem *exitItem = navigationBar.items[0].rightBarButtonItems[0];
        UIBarButtonItem *aiItem = [[UIBarButtonItem alloc] initWithTitle:@"AI"
            style:UIBarButtonItemStylePlain target:current action:@selector(actionAnalyzeCrashWithAI)];
        navigationBar.items[0].rightBarButtonItems = @[exitItem, aiItem];

        if (canAppendToLog) {
            canAppendToLog = NO;
            fatalErrorOccurred = YES;
            return;
        }
        [current actionClearLogOutput];
        [self _appendToLog:@"... (latestlog.txt)"];
        NSString *latestlogPath = [NSString stringWithFormat:@"%s/latestlog.txt", getenv("POJAV_HOME")];
        NSString *linesStr = [NSString stringWithContentsOfFile:latestlogPath
            encoding:NSUTF8StringEncoding error:nil];
        NSArray *lines = [linesStr componentsSeparatedByCharactersInSet:
            NSCharacterSet.newlineCharacterSet];

        // Print last 100 lines from latestlog.txt
        for (int i = (lines.count > 100) ? lines.count - 100 : 0; i < lines.count; i++) {
            [self _appendToLog:lines[i]];
        }

        fatalErrorOccurred = YES;
    });
}

@end
