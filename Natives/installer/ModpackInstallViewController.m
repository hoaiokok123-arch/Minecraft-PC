#import "AFNetworking.h"
#import "LauncherNavigationController.h"
#import "ModpackInstallViewController.h"
#import "PLProfiles.h"
#import "UIKit+AFNetworking.h"
#import "UIKit+hook.h"
#import "WFWorkflowProgressView.h"
#import "modpack/CurseForgeAPI.h"
#import "modpack/ModpackAPI.h"
#import "modpack/ModrinthAPI.h"
#import "config.h"
#import "ios_uikit_bridge.h"
#import "utils.h"
#include <dlfcn.h>

@interface ModpackInstallViewController()<UIContextMenuInteractionDelegate>
@property(nonatomic) UISearchController *searchController;
@property(nonatomic) UIMenu *currentMenu;
@property(nonatomic) NSMutableArray *list;
@property(nonatomic) NSMutableDictionary *filters;
@property(nonatomic) ModpackAPI *api;
@property ModrinthAPI *modrinth;
@property CurseForgeAPI *curseforge;
@property(nonatomic) NSArray<UIButton *> *sourceButtons;
@property(nonatomic) UIView *sourceHeaderView;
@end

@implementation ModpackInstallViewController

- (instancetype)initWithProjectType:(NSString *)projectType {
    return [self initWithProjectType:projectType sourceName:nil];
}

- (instancetype)initWithProjectType:(NSString *)projectType sourceName:(NSString *)sourceName {
    self = [super init];
    self.projectType = projectType;
    self.sourceName = sourceName;
    return self;
}

+ (NSString *)titleForProjectType:(NSString *)projectType {
    if (projectType.length == 0) {
        projectType = @"modpack";
    }
    NSDictionary *titles = @{
        @"modpack": @"Modpacks",
        @"mod": @"Mods",
        @"plugin": @"Plugins",
        @"datapack": @"Data Packs",
        @"shader": @"Shaders",
        @"resourcepack": @"Resource Packs",
        @"minecraft_java_server": @"Servers"
    };
    return titles[projectType] ?: @"Modrinth";
}

- (void)viewDidLoad {
    [super viewDidLoad];

    if (self.projectType.length == 0) {
        self.projectType = @"modpack";
    }
    NSString *baseTitle = [ModpackInstallViewController titleForProjectType:self.projectType];
    self.title = self.sourceName.length > 0 ? [NSString stringWithFormat:@"%@ - %@", baseTitle, self.sourceName] : baseTitle;
    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.navigationItem.searchController = self.searchController;
    self.modrinth = [ModrinthAPI new];
    self.curseforge = [CurseForgeAPI new];
    self.api = [self.sourceName isEqualToString:@"CurseForge"] ? self.curseforge : self.modrinth;
    self.filters = @{
        @"projectType": self.projectType,
        @"name": @" "
        // mcVersion
    }.mutableCopy;
    if (self.sourceName.length == 0) {
        [self configureSourceHeader];
    }
    [self updateSearchResults];
}

- (UIImage *)sourceLogoWithLetter:(NSString *)letter color:(UIColor *)color {
    CGSize size = CGSizeMake(28, 28);
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGRect rect = CGRectMake(0, 0, size.width, size.height);
        UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:7];
        [color setFill];
        [path fill];

        NSMutableParagraphStyle *style = [NSMutableParagraphStyle new];
        style.alignment = NSTextAlignmentCenter;
        NSDictionary *attrs = @{
            NSFontAttributeName: [UIFont boldSystemFontOfSize:17],
            NSForegroundColorAttributeName: UIColor.whiteColor,
            NSParagraphStyleAttributeName: style
        };
        CGRect textRect = CGRectMake(0, 3.5, size.width, size.height - 4);
        [letter drawInRect:textRect withAttributes:attrs];
    }];
}

- (UIButton *)sourceButtonWithTitle:(NSString *)title letter:(NSString *)letter color:(UIColor *)color tag:(NSInteger)tag {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.tag = tag;
    button.layer.cornerRadius = 10;
    button.layer.borderWidth = 1;
    button.contentEdgeInsets = UIEdgeInsetsMake(8, 10, 8, 10);
    button.imageEdgeInsets = UIEdgeInsetsMake(0, -2, 0, 8);
    button.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    [button setTitle:title forState:UIControlStateNormal];
    [button setImage:[[self sourceLogoWithLetter:letter color:color] imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal]
        forState:UIControlStateNormal];
    [button addTarget:self action:@selector(actionSelectSource:) forControlEvents:UIControlEventPrimaryActionTriggered];
    return button;
}

- (void)configureSourceHeader {
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.tableView.bounds.size.width, 64)];
    UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectInset(header.bounds, 16, 10)];
    stack.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.spacing = 12;
    stack.distribution = UIStackViewDistributionFillEqually;

    UIButton *modrinthButton = [self sourceButtonWithTitle:@"Modrinth"
        letter:@"M"
        color:[UIColor colorWithRed:28/255.0 green:172/255.0 blue:91/255.0 alpha:1.0]
        tag:0];
    UIButton *curseForgeButton = [self sourceButtonWithTitle:@"CurseForge"
        letter:@"C"
        color:[UIColor colorWithRed:241/255.0 green:100/255.0 blue:34/255.0 alpha:1.0]
        tag:1];
    [stack addArrangedSubview:modrinthButton];
    [stack addArrangedSubview:curseForgeButton];
    [header addSubview:stack];

    self.sourceButtons = @[modrinthButton, curseForgeButton];
    self.sourceHeaderView = header;
    self.tableView.tableHeaderView = header;
    [self updateSourceButtons];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (self.sourceHeaderView && self.sourceHeaderView.frame.size.width != self.tableView.bounds.size.width) {
        CGRect frame = self.sourceHeaderView.frame;
        frame.size.width = self.tableView.bounds.size.width;
        self.sourceHeaderView.frame = frame;
        self.tableView.tableHeaderView = self.sourceHeaderView;
    }
}

- (void)updateSourceButtons {
    for (UIButton *button in self.sourceButtons) {
        BOOL selected = (button.tag == 1 && self.api == self.curseforge) ||
            (button.tag == 0 && self.api == self.modrinth);
        UIColor *tint = self.view.tintColor ?: UIColor.systemBlueColor;
        button.backgroundColor = selected ? [tint colorWithAlphaComponent:0.18] : UIColor.secondarySystemGroupedBackgroundColor;
        button.tintColor = selected ? tint : UIColor.labelColor;
        button.layer.borderColor = (selected ? tint : UIColor.separatorColor).CGColor;
    }
}

- (void)actionSelectSource:(UIButton *)sender {
    ModpackAPI *newAPI = sender.tag == 1 ? self.curseforge : self.modrinth;
    if (newAPI == self.api) {
        return;
    }
    self.api = newAPI;
    [self.filters removeObjectForKey:@"name"];
    self.list = nil;
    [self updateSourceButtons];
    [self.tableView reloadData];
    [self loadSearchResultsWithPrevList:NO];
}

- (void)loadSearchResultsWithPrevList:(BOOL)prevList {
    NSString *name = self.searchController.searchBar.text ?: @"";
    if (!prevList && [self.filters[@"name"] isEqualToString:name]) {
        return;
    }

    [self switchToLoadingState];
    ModpackAPI *api = self.api;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        self.filters[@"name"] = name;
        NSMutableArray *list = [api searchModWithFilters:self.filters previousPageResult:prevList ? self.list : nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (api != self.api) {
                return;
            }
            self.list = list;
            if (self.list) {
                [self switchToReadyState];
                [self.tableView reloadData];
            } else {
                showDialog(localize(@"Error", nil), api.lastError.localizedDescription);
                [self actionClose];
            }
        });
    });
}

- (void)updateSearchResults {
    [self loadSearchResultsWithPrevList:NO];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(updateSearchResults) object:nil];
    [self performSelector:@selector(updateSearchResults) withObject:nil afterDelay:0.5];
}

- (void)actionClose {
    [self.navigationController dismissViewControllerAnimated:YES completion:nil];
}

- (void)switchToLoadingState {
    UIActivityIndicatorView *indicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:indicator];
    [indicator startAnimating];
    self.navigationController.modalInPresentation = YES;
    self.tableView.allowsSelection = NO;
}

- (void)switchToReadyState {
    UIActivityIndicatorView *indicator = (id)self.navigationItem.rightBarButtonItem.customView;
    [indicator stopAnimating];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(actionClose)];
    self.navigationController.modalInPresentation = NO;
    self.tableView.allowsSelection = YES;
}

#pragma mark UIContextMenu

- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction configurationForMenuAtLocation:(CGPoint)location
{
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu * _Nullable(NSArray<UIMenuElement *> * _Nonnull suggestedActions) {
        return self.currentMenu;
    }];
}

- (_UIContextMenuStyle *)_contextMenuInteraction:(UIContextMenuInteraction *)interaction styleForMenuWithConfiguration:(UIContextMenuConfiguration *)configuration
{
    _UIContextMenuStyle *style = [_UIContextMenuStyle defaultStyle];
    style.preferredLayout = 3; // _UIContextMenuLayoutCompactMenu
    return style;
}

#pragma mark UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.list.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"cell"];
        cell.imageView.contentMode = UIViewContentModeScaleToFill;
        cell.imageView.clipsToBounds = YES;
    }

    NSDictionary *item = self.list[indexPath.row];
    cell.textLabel.text = item[@"title"];
    cell.detailTextLabel.text = item[@"description"];
    UIImage *fallbackImage = [UIImage imageNamed:@"DefaultProfile"];
    [cell.imageView setImageWithURL:[NSURL URLWithString:item[@"imageUrl"]] placeholderImage:fallbackImage];

    if (!self.api.reachedLastPage && indexPath.row == self.list.count-1) {
        [self loadSearchResultsWithPrevList:YES];
    }

    return cell;
}

- (void)showDetails:(NSDictionary *)details atIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];

    NSMutableArray<UIAction *> *menuItems = [[NSMutableArray alloc] init];
    NSArray *versionNames = [details[@"versionNames"] isKindOfClass:NSArray.class] ? details[@"versionNames"] : @[];
    NSArray *mcVersionNames = [details[@"mcVersionNames"] isKindOfClass:NSArray.class] ? details[@"mcVersionNames"] : @[];
    if (versionNames.count == 0) {
        showDialog(localize(@"Error", nil), @"No downloadable versions were found.");
        return;
    }
    [versionNames enumerateObjectsUsingBlock:
    ^(NSString *name, NSUInteger i, BOOL *stop) {
        NSString *nameWithVersion = name;
        NSString *mcVersion = i < mcVersionNames.count ? mcVersionNames[i] : @"";
        if (mcVersion.length > 0 && ![name hasSuffix:mcVersion]) {
            nameWithVersion = [NSString stringWithFormat:@"%@ - %@", name, mcVersion];
        }
        [menuItems addObject:[UIAction
            actionWithTitle:nameWithVersion
            image:nil identifier:nil
            handler:^(UIAction *action) {
            NSString *tmpIconPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"icon.png"];
                [UIImagePNGRepresentation([cell.imageView.image _imageWithSize:CGSizeMake(40, 40)]) writeToFile:tmpIconPath atomically:YES];
            NSMutableDictionary *detail = self.list[indexPath.row];
            if ([self shouldChooseDestinationForDetail:detail atIndex:i]) {
                [self presentDestinationChooserForDetail:detail atIndex:i sourceView:cell];
            } else {
                [self actionClose];
                [self.api installProjectFromDetail:detail atIndex:i];
            }
        }]];
    }];

    self.currentMenu = [UIMenu menuWithTitle:@"" children:menuItems];
    UIContextMenuInteraction *interaction = [[UIContextMenuInteraction alloc] initWithDelegate:self];
    cell.detailTextLabel.interactions = @[interaction];
    [interaction _presentMenuAtLocation:CGPointZero];
}

- (BOOL)shouldChooseDestinationForDetail:(NSDictionary *)detail atIndex:(NSUInteger)index {
    NSString *projectType = detail[@"projectType"];
    NSArray *fileNames = detail[@"versionFileNames"];
    NSString *fileName = index < fileNames.count ? fileNames[index] : @"";
    return ![projectType isEqualToString:@"modpack"] && ![fileName.pathExtension isEqualToString:@"mrpack"];
}

- (NSString *)gameDirectoryForProfile:(NSMutableDictionary *)profile {
    NSString *gameDir = [PLProfiles profile:profile resolveKey:@"gameDir"];
    if (gameDir.length == 0) {
        gameDir = @".";
    }
    return [[NSString stringWithFormat:@"%s/%@", getenv("POJAV_GAME_DIR"), gameDir] stringByStandardizingPath];
}

- (NSArray<NSMutableDictionary *> *)sortedProfiles {
    return [PLProfiles.current.profiles.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSString *nameA = a[@"name"] ?: @"";
        NSString *nameB = b[@"name"] ?: @"";
        return [nameA localizedCaseInsensitiveCompare:nameB];
    }];
}

- (void)installDetail:(NSMutableDictionary *)detail atIndex:(NSUInteger)index toProfile:(NSMutableDictionary *)profile {
    NSMutableDictionary *installDetail = [detail mutableCopy];
    installDetail[@"targetGameDir"] = [self gameDirectoryForProfile:profile];
    if (profile[@"name"]) {
        installDetail[@"targetProfileName"] = profile[@"name"];
    }
    [self actionClose];
    [self.api installProjectFromDetail:installDetail atIndex:index];
}

- (void)presentDestinationChooserForDetail:(NSMutableDictionary *)detail atIndex:(NSUInteger)index sourceView:(UIView *)sourceView {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Choose Destination"
        message:@"Select the profile to install into."
        preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSMutableDictionary *profile in [self sortedProfiles]) {
        NSString *name = profile[@"name"] ?: @"Profile";
        NSString *version = profile[@"lastVersionId"] ?: @"";
        NSString *title = version.length > 0 ? [NSString stringWithFormat:@"%@ - %@", name, version] : name;
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [self installDetail:detail atIndex:index toProfile:profile];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:localize(@"Cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = sourceView ?: self.view;
    sheet.popoverPresentationController.sourceRect = sourceView ? sourceView.bounds :
        CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *item = self.list[indexPath.row];
    if ([item[@"versionDetailsLoaded"] boolValue]) {
        [self showDetails:item atIndexPath:indexPath];
        return;
    }
    [tableView deselectRowAtIndexPath:indexPath animated:NO];
    [self switchToLoadingState];
    ModpackAPI *api = self.api;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [api loadDetailsOfMod:self.list[indexPath.row]];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (api != self.api) {
                return;
            }
            [self switchToReadyState];
            if ([item[@"versionDetailsLoaded"] boolValue]) {
                [self showDetails:item atIndexPath:indexPath];
            } else {
                showDialog(localize(@"Error", nil), api.lastError.localizedDescription);
            }
        });
    });
}

@end
