#import "LauncherPreferences.h"
#include <CommonCrypto/CommonDigest.h>

#import "ModManagerViewController.h"
#import "PLProfiles.h"
#import "UnzipKit.h"
#import "installer/modpack/ModrinthAPI.h"
#import "ios_uikit_bridge.h"
#import "utils.h"

@interface ModManagerViewController () <UISearchResultsUpdating, UISearchBarDelegate>
@property(nonatomic) NSMutableArray<NSString *> *allFiles;
@property(nonatomic) NSMutableArray<NSString *> *files;
@property(nonatomic) NSMutableDictionary<NSString *, UIImage *> *iconCache;
@property(nonatomic) NSMutableDictionary<NSString *, NSDictionary *> *metadataCache;
@property(nonatomic) NSMutableSet<NSString *> *loadingDetailFiles;
@property(nonatomic) NSMutableSet<NSString *> *loadedDetailFiles;
@property(nonatomic, strong) dispatch_queue_t modDetailsQueue;
@property(nonatomic, strong) UISearchController *searchController;
@property(nonatomic) UIImage *cachedDefaultModIcon;
@property(nonatomic) NSString *projectType;
@property(nonatomic) NSString *folderName;
@property(nonatomic) NSString *iconImageName;
@property(nonatomic) NSArray<NSString *> *managedExtensions;
@property(nonatomic) NSMutableDictionary *profile;
@property(nonatomic) NSString *modsPath;
@end

@implementation ModManagerViewController

- (id)init {
    return [self initWithProjectType:@"mod"];
}

- (instancetype)initWithProjectType:(NSString *)projectType {
    return [self initWithProjectType:projectType profile:nil];
}

- (instancetype)initWithProjectType:(NSString *)projectType profile:(NSMutableDictionary *)profile {
    self = [super init];
    self.profile = profile;
    self.projectType = projectType.length > 0 ? projectType : @"mod";
    NSDictionary *titles = @{
        @"mod": @"Mods",
        @"plugin": @"Plugins",
        @"datapack": @"Data Packs",
        @"shader": @"Shaders",
        @"resourcepack": @"Resource Packs",
        @"minecraft_java_server": @"Servers"
    };
    NSDictionary *folders = @{
        @"mod": @"mods",
        @"plugin": @"plugins",
        @"datapack": @"datapacks",
        @"shader": @"shaderpacks",
        @"resourcepack": @"resourcepacks",
        @"minecraft_java_server": @"servers"
    };
    NSDictionary *icons = @{
        @"mod": @"puzzlepiece",
        @"plugin": @"powerplug",
        @"datapack": @"shippingbox",
        @"shader": @"sun.max",
        @"resourcepack": @"paintpalette",
        @"minecraft_java_server": @"server.rack"
    };
    NSDictionary *extensions = @{
        @"mod": @[@"jar"],
        @"plugin": @[@"jar"],
        @"datapack": @[@"zip"],
        @"shader": @[@"zip"],
        @"resourcepack": @[@"zip"],
        @"minecraft_java_server": @[@"jar"]
    };
    self.title = titles[self.projectType] ?: @"Files";
    self.folderName = folders[self.projectType] ?: @"downloads";
    self.iconImageName = icons[self.projectType] ?: @"folder";
    self.managedExtensions = extensions[self.projectType] ?: @[@"jar", @"zip"];
    self.modDetailsQueue = dispatch_queue_create("net.kdt.pojavlauncher.modmanager.details", DISPATCH_QUEUE_SERIAL);
    dispatch_set_target_queue(self.modDetailsQueue, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0));
    return self;
}

- (NSString *)imageName {
    return self.iconImageName ?: @"folder";
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.searchBar.delegate = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchBar.placeholder = [NSString stringWithFormat:@"Search %@", self.title.lowercaseString];
    self.navigationItem.searchController = self.searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = YES;
    self.definesPresentationContext = YES;

    UIBarButtonItem *refreshButton = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
        target:self
        action:@selector(reloadModList)];
    UIBarButtonItem *searchButton = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemSearch
        target:self
        action:@selector(actionSearchMod)];
    self.navigationItem.rightBarButtonItems = @[refreshButton, searchButton];

    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(handleModFileDidChange:)
        name:@"ModManagerModFileDidChange"
        object:nil];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)handleModFileDidChange:(NSNotification *)notification {
    NSString *file = [notification.userInfo[@"path"] lastPathComponent];
    if (file.length > 0) {
        [self.iconCache removeObjectForKey:file];
        [self.metadataCache removeObjectForKey:file];
        [self.loadingDetailFiles removeObject:file];
        [self.loadedDetailFiles removeObject:file];
    }
    [self reloadModList];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadModList];
}

- (NSString *)selectedProfileGameDirectory {
    NSMutableDictionary *profile = self.profile ?: PLProfiles.current.selectedProfile;
    NSString *gameDir = [PLProfiles profile:profile resolveKey:@"gameDir"];
    if (gameDir.length == 0) {
        gameDir = @".";
    }
    return [[NSString stringWithFormat:@"%s/%@", getenv("POJAV_GAME_DIR"), gameDir] stringByStandardizingPath];
}

- (void)reloadModList {
    self.modsPath = [[self selectedProfileGameDirectory] stringByAppendingPathComponent:self.folderName ?: @"mods"];
    [NSFileManager.defaultManager createDirectoryAtPath:self.modsPath withIntermediateDirectories:YES attributes:nil error:nil];

    NSArray *contents = [NSFileManager.defaultManager contentsOfDirectoryAtPath:self.modsPath error:nil] ?: @[];
    self.files = [NSMutableArray new];
    self.allFiles = [NSMutableArray new];
    self.iconCache = self.iconCache ?: [NSMutableDictionary new];
    self.metadataCache = self.metadataCache ?: [NSMutableDictionary new];
    self.loadingDetailFiles = self.loadingDetailFiles ?: [NSMutableSet new];
    self.loadedDetailFiles = self.loadedDetailFiles ?: [NSMutableSet new];
    for (NSString *file in contents) {
        if ([self isManagedFile:file]) {
            [self.allFiles addObject:file];
        }
    }
    [self.allFiles sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    [self trimCachedDetailsForCurrentFiles];
    [self applyInstalledModFilter];
}

- (void)trimCachedDetailsForCurrentFiles {
    NSSet<NSString *> *currentFiles = [NSSet setWithArray:self.allFiles ?: self.files];
    for (NSString *key in self.iconCache.allKeys.copy) {
        if (![currentFiles containsObject:key]) {
            [self.iconCache removeObjectForKey:key];
        }
    }
    for (NSString *key in self.metadataCache.allKeys.copy) {
        if (![currentFiles containsObject:key]) {
            [self.metadataCache removeObjectForKey:key];
        }
    }
    for (NSString *key in self.loadingDetailFiles.allObjects.copy) {
        if (![currentFiles containsObject:key]) {
            [self.loadingDetailFiles removeObject:key];
        }
    }
    for (NSString *key in self.loadedDetailFiles.allObjects.copy) {
        if (![currentFiles containsObject:key]) {
            [self.loadedDetailFiles removeObject:key];
        }
    }
}

- (void)moveCachedDetailsFromFile:(NSString *)sourceFile toFile:(NSString *)destFile {
    UIImage *icon = self.iconCache[sourceFile];
    if (icon) {
        self.iconCache[destFile] = icon;
        [self.iconCache removeObjectForKey:sourceFile];
    }
    NSDictionary *metadata = self.metadataCache[sourceFile];
    if (metadata) {
        self.metadataCache[destFile] = metadata;
        [self.metadataCache removeObjectForKey:sourceFile];
    }
    if ([self.loadedDetailFiles containsObject:sourceFile]) {
        [self.loadedDetailFiles removeObject:sourceFile];
        [self.loadedDetailFiles addObject:destFile];
    }
    [self.loadingDetailFiles removeObject:sourceFile];
}

- (NSString *)installedModSearchText {
    return [self.searchController.searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
}

- (BOOL)isFilteringInstalledMods {
    return [self installedModSearchText].length > 0;
}

- (BOOL)text:(NSString *)text matchesInstalledModSearch:(NSString *)query {
    return [text isKindOfClass:NSString.class] && [[text lowercaseString] containsString:query];
}

- (BOOL)file:(NSString *)file matchesInstalledModSearch:(NSString *)query {
    if (query.length == 0) {
        return YES;
    }

    NSDictionary *metadata = [self metadataForModFile:file];
    NSArray<NSString *> *fields = @[
        file,
        [self enabledNameForDisabledFile:file],
        [self baseNameForModFile:file],
        metadata[@"displayName"] ?: @"",
        metadata[@"name"] ?: @"",
        metadata[@"modId"] ?: @"",
        metadata[@"version"] ?: @""
    ];
    for (NSString *field in fields) {
        if ([self text:field matchesInstalledModSearch:query]) {
            return YES;
        }
    }
    return NO;
}

- (void)applyInstalledModFilter {
    NSString *query = [[self installedModSearchText] lowercaseString];
    self.files = [NSMutableArray new];
    for (NSString *file in self.allFiles ?: @[]) {
        if ([self file:file matchesInstalledModSearch:query]) {
            [self.files addObject:file];
        }
    }
    [self.tableView reloadData];
}

- (NSString *)pathForFileAtRow:(NSInteger)row {
    return [self.modsPath stringByAppendingPathComponent:self.files[row]];
}

- (BOOL)isFileEnabled:(NSString *)file {
    return ![file hasSuffix:@".disabled"];
}

- (NSString *)enabledNameForDisabledFile:(NSString *)file {
    if (![file hasSuffix:@".disabled"]) {
        return file;
    }
    return [file substringToIndex:file.length - @".disabled".length];
}

- (BOOL)isManagedFile:(NSString *)file {
    NSString *enabledName = [self enabledNameForDisabledFile:file];
    NSString *extension = enabledName.pathExtension.lowercaseString;
    return [self.managedExtensions containsObject:extension];
}

- (NSString *)baseNameForModFile:(NSString *)file {
    NSString *name = [self enabledNameForDisabledFile:file];
    NSString *extension = name.pathExtension;
    if (extension.length > 0) {
        name = [name substringToIndex:name.length - extension.length - 1];
    }
    return name;
}

- (UIImage *)imageByFittingImage:(UIImage *)image toSize:(CGSize)size {
    if (!image) {
        return nil;
    }

    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGSize sourceSize = image.size.width > 0 && image.size.height > 0 ? image.size : size;
        CGFloat scale = MIN(size.width / sourceSize.width, size.height / sourceSize.height);
        CGSize drawSize = CGSizeMake(sourceSize.width * scale, sourceSize.height * scale);
        CGRect drawRect = CGRectMake((size.width - drawSize.width) / 2, (size.height - drawSize.height) / 2,
            drawSize.width, drawSize.height);
        [image drawInRect:drawRect];
    }];
}

- (UIImage *)defaultModIcon {
    if (self.cachedDefaultModIcon) {
        return self.cachedDefaultModIcon;
    }

    UIImage *image = [UIImage systemImageNamed:@"puzzlepiece"];
    if (!image) {
        image = [UIImage imageNamed:@"DefaultProfile"];
    }
    self.cachedDefaultModIcon = [self imageByFittingImage:image toSize:CGSizeMake(40, 40)];
    return self.cachedDefaultModIcon;
}

- (NSString *)trimmedMetadataValue:(NSString *)value {
    value = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (([value hasPrefix:@"\""] && [value hasSuffix:@"\""]) ||
        ([value hasPrefix:@"'"] && [value hasSuffix:@"'"])) {
        value = [value substringWithRange:NSMakeRange(1, value.length - 2)];
    }
    return [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

- (void)setMetadataValue:(id)value forKey:(NSString *)key metadata:(NSMutableDictionary *)metadata {
    if (metadata[key]) {
        return;
    }
    if ([value isKindOfClass:NSNumber.class]) {
        value = [value stringValue];
    }
    if (![value isKindOfClass:NSString.class]) {
        return;
    }

    NSString *stringValue = [self trimmedMetadataValue:value];
    if (stringValue.length > 0) {
        metadata[key] = stringValue;
    }
}

- (id)JSONObjectFromData:(NSData *)data {
    if (!data) {
        return nil;
    }
    return [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
}

- (void)addMetadataFromFabricData:(NSData *)data metadata:(NSMutableDictionary *)metadata {
    NSDictionary *json = [self JSONObjectFromData:data];
    if (![json isKindOfClass:NSDictionary.class]) {
        return;
    }
    [self setMetadataValue:json[@"id"] forKey:@"modId" metadata:metadata];
    [self setMetadataValue:json[@"name"] forKey:@"name" metadata:metadata];
    [self setMetadataValue:json[@"version"] forKey:@"version" metadata:metadata];
}

- (void)addMetadataFromQuiltData:(NSData *)data metadata:(NSMutableDictionary *)metadata {
    NSDictionary *json = [self JSONObjectFromData:data];
    NSDictionary *loader = [json isKindOfClass:NSDictionary.class] ? json[@"quilt_loader"] : nil;
    NSDictionary *info = [loader isKindOfClass:NSDictionary.class] ? loader[@"metadata"] : nil;
    if (![loader isKindOfClass:NSDictionary.class]) {
        return;
    }
    [self setMetadataValue:loader[@"id"] forKey:@"modId" metadata:metadata];
    if ([info isKindOfClass:NSDictionary.class]) {
        [self setMetadataValue:info[@"name"] forKey:@"name" metadata:metadata];
        [self setMetadataValue:info[@"version"] forKey:@"version" metadata:metadata];
    }
}

- (void)addMetadataFromMcmodInfoData:(NSData *)data metadata:(NSMutableDictionary *)metadata {
    id json = [self JSONObjectFromData:data];
    id item = nil;
    if ([json isKindOfClass:NSArray.class]) {
        item = [json firstObject];
    } else if ([json isKindOfClass:NSDictionary.class]) {
        NSArray *modList = json[@"modList"];
        item = [modList isKindOfClass:NSArray.class] ? [modList firstObject] : json;
    }
    if (![item isKindOfClass:NSDictionary.class]) {
        return;
    }
    [self setMetadataValue:item[@"modid"] forKey:@"modId" metadata:metadata];
    [self setMetadataValue:item[@"name"] forKey:@"name" metadata:metadata];
    [self setMetadataValue:item[@"version"] forKey:@"version" metadata:metadata];
}

- (void)addMetadataFromModsTomlData:(NSData *)data metadata:(NSMutableDictionary *)metadata {
    NSString *content = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (content.length == 0) {
        content = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    }
    BOOL inFirstModBlock = NO;
    BOOL finishedFirstModBlock = NO;
    for (NSString *line in [content componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *cleanLine = line;
        NSRange commentRange = [cleanLine rangeOfString:@"#"];
        if (commentRange.location != NSNotFound) {
            cleanLine = [cleanLine substringToIndex:commentRange.location];
        }
        cleanLine = [cleanLine stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if ([cleanLine hasPrefix:@"[[mods]]"]) {
            if (inFirstModBlock) {
                finishedFirstModBlock = YES;
            }
            inFirstModBlock = YES;
            continue;
        }
        if (!inFirstModBlock || finishedFirstModBlock) {
            continue;
        }

        NSRange equalsRange = [cleanLine rangeOfString:@"="];
        if (equalsRange.location == NSNotFound) {
            continue;
        }
        NSString *key = [[cleanLine substringToIndex:equalsRange.location] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSString *value = [cleanLine substringFromIndex:equalsRange.location + 1];
        if ([key isEqualToString:@"modId"]) {
            [self setMetadataValue:value forKey:@"modId" metadata:metadata];
        } else if ([key isEqualToString:@"displayName"]) {
            [self setMetadataValue:value forKey:@"name" metadata:metadata];
        } else if ([key isEqualToString:@"version"]) {
            [self setMetadataValue:value forKey:@"version" metadata:metadata];
        }
    }
}

- (NSDictionary *)fallbackMetadataForModFile:(NSString *)file {
    NSString *baseName = [self baseNameForModFile:file];
    return @{
        @"fileName": [self enabledNameForDisabledFile:file],
        @"baseName": baseName,
        @"displayName": baseName
    };
}

- (NSDictionary *)metadataFromArchive:(UZKArchive *)archive forModFile:(NSString *)file {
    NSMutableDictionary *metadata = [[self fallbackMetadataForModFile:file] mutableCopy];
    [self addMetadataFromFabricData:[archive extractDataFromFile:@"fabric.mod.json" error:nil] metadata:metadata];
    [self addMetadataFromQuiltData:[archive extractDataFromFile:@"quilt.mod.json" error:nil] metadata:metadata];
    [self addMetadataFromMcmodInfoData:[archive extractDataFromFile:@"mcmod.info" error:nil] metadata:metadata];
    [self addMetadataFromModsTomlData:[archive extractDataFromFile:@"META-INF/mods.toml" error:nil] metadata:metadata];
    [self addMetadataFromModsTomlData:[archive extractDataFromFile:@"META-INF/neoforge.mods.toml" error:nil] metadata:metadata];
    metadata[@"displayName"] = metadata[@"name"] ?: metadata[@"modId"] ?: metadata[@"baseName"];
    return metadata;
}

- (NSDictionary *)metadataForModFile:(NSString *)file {
    NSDictionary *cachedMetadata = self.metadataCache[file];
    if (cachedMetadata) {
        return cachedMetadata;
    }
    return [self fallbackMetadataForModFile:file];
}

- (NSString *)sha1ForFileAtPath:(NSString *)path {
    NSInputStream *stream = [NSInputStream inputStreamWithFileAtPath:path];
    [stream open];
    if (stream.streamStatus == NSStreamStatusError) {
        [stream close];
        return nil;
    }

    CC_SHA1_CTX context;
    CC_SHA1_Init(&context);
    uint8_t buffer[64 * 1024];
    while (YES) {
        NSInteger read = [stream read:buffer maxLength:sizeof(buffer)];
        if (read < 0) {
            [stream close];
            return nil;
        }
        if (read == 0) {
            break;
        }
        CC_SHA1_Update(&context, buffer, (CC_LONG)read);
    }
    [stream close];

    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1_Final(digest, &context);
    NSMutableString *sha1 = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
    for (NSUInteger i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) {
        [sha1 appendFormat:@"%02x", digest[i]];
    }
    return sha1;
}

- (void)startLoadingDetailsForModFile:(NSString *)file path:(NSString *)path {
    if ([self.loadedDetailFiles containsObject:file] || [self.loadingDetailFiles containsObject:file]) {
        return;
    }
    [self.loadingDetailFiles addObject:file];

    dispatch_async(self.modDetailsQueue, ^{
        UZKArchive *archive = [[UZKArchive alloc] initWithPath:path error:nil];
        NSDictionary *metadata = [self metadataFromArchive:archive forModFile:file];
        UIImage *icon = nil;
        for (NSString *candidate in [self metadataIconCandidatesFromArchive:archive]) {
            icon = [self imageForArchive:archive candidatePath:candidate];
            if (icon) {
                break;
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [self.loadingDetailFiles removeObject:file];
            [self.loadedDetailFiles addObject:file];
            if (![self.files containsObject:file]) {
                return;
            }

            self.metadataCache[file] = metadata;
            self.iconCache[file] = icon ?: [self defaultModIcon];
            if ([self isFilteringInstalledMods]) {
                [self applyInstalledModFilter];
                return;
            }
            NSUInteger row = [self.files indexOfObject:file];
            if (row != NSNotFound) {
                NSIndexPath *indexPath = [NSIndexPath indexPathForRow:row inSection:0];
                if ([self.tableView.indexPathsForVisibleRows containsObject:indexPath]) {
                    [self.tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
                }
            }
        });
    });
}

- (BOOL)isVersionLikeSearchToken:(NSString *)token {
    NSPredicate *versionPredicate = [NSPredicate predicateWithFormat:@"SELF MATCHES[c] %@", @"^(v|r)?[0-9]+(\\.[0-9]+)*([a-z]+[0-9]*)?$"];
    return [versionPredicate evaluateWithObject:token];
}

- (NSString *)normalizedSearchQueryForValue:(NSString *)value {
    value = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (value.length == 0) {
        return nil;
    }

    NSRange parenRange = [value rangeOfString:@"("];
    if (parenRange.location != NSNotFound && parenRange.location > 0) {
        value = [value substringToIndex:parenRange.location];
    }
    value = [value stringByReplacingOccurrencesOfString:@"_" withString:@" "];
    value = [value stringByReplacingOccurrencesOfString:@"-" withString:@" "];
    value = [value stringByReplacingOccurrencesOfString:@"+" withString:@" "];
    value = [value stringByReplacingOccurrencesOfString:@"." withString:@" "];

    NSSet *ignoredTokens = [NSSet setWithArray:@[@"mod", @"mods", @"shader", @"shaders", @"resourcepack", @"resourcepacks",
        @"datapack", @"datapacks", @"plugin", @"plugins", @"server", @"servers", @"edit", @"forge", @"fabric",
        @"neoforge", @"quilt", @"paper", @"spigot", @"bukkit"]];
    NSMutableArray<NSString *> *tokens = [NSMutableArray new];
    for (NSString *rawToken in [value componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]) {
        NSString *token = [rawToken stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (token.length == 0 || [self isVersionLikeSearchToken:token] || [ignoredTokens containsObject:token.lowercaseString]) {
            continue;
        }
        [tokens addObject:token];
    }
    NSString *result = [tokens componentsJoinedByString:@" "];
    return result.length > 0 ? result : nil;
}

- (void)addSearchQueryValue:(NSString *)value toQueries:(NSMutableArray<NSString *> *)queries {
    value = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (value.length == 0 || [value hasPrefix:@"${"]) {
        return;
    }
    if (![queries containsObject:value]) {
        [queries addObject:value];
    }
    NSString *normalized = [self normalizedSearchQueryForValue:value];
    if (normalized.length > 0 && ![queries containsObject:normalized]) {
        [queries addObject:normalized];
    }
}

- (NSArray<NSString *> *)searchQueriesForModFile:(NSString *)file metadata:(NSDictionary *)metadata {
    NSMutableArray<NSString *> *queries = [NSMutableArray new];
    for (NSString *key in @[@"name", @"modId", @"displayName", @"baseName"]) {
        NSString *value = metadata[key];
        if (![value isKindOfClass:NSString.class]) {
            continue;
        }
        [self addSearchQueryValue:value toQueries:queries];
    }
    [self addSearchQueryValue:[self baseNameForModFile:file] toQueries:queries];
    return queries.count > 0 ? queries : @[[self baseNameForModFile:file]];
}

- (NSString *)searchQueryForModFile:(NSString *)file metadata:(NSDictionary *)metadata {
    return [self searchQueriesForModFile:file metadata:metadata].firstObject;
}

- (void)addIconValue:(id)value toCandidates:(NSMutableArray<NSString *> *)candidates {
    if ([value isKindOfClass:NSString.class]) {
        NSString *path = [self trimmedMetadataValue:value];
        if (path.length > 0) {
            [candidates addObject:path];
        }
    } else if ([value isKindOfClass:NSDictionary.class]) {
        NSArray *keys = [[value allKeys] sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
            return [@([b integerValue]) compare:@([a integerValue])];
        }];
        for (id key in keys) {
            [self addIconValue:value[key] toCandidates:candidates];
        }
    }
}

- (void)addIconCandidatesFromJSONData:(NSData *)data rootPath:(NSArray<NSString *> *)rootPath toCandidates:(NSMutableArray<NSString *> *)candidates {
    if (!data) {
        return;
    }

    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    id root = json;
    for (NSString *key in rootPath) {
        if (![root isKindOfClass:NSDictionary.class]) {
            root = nil;
            break;
        }
        root = root[key];
    }
    if ([root isKindOfClass:NSDictionary.class]) {
        [self addIconValue:root[@"icon"] toCandidates:candidates];
        [self addIconValue:root[@"logoFile"] toCandidates:candidates];
    } else if ([root isKindOfClass:NSArray.class]) {
        for (id item in root) {
            if ([item isKindOfClass:NSDictionary.class]) {
                [self addIconValue:item[@"icon"] toCandidates:candidates];
                [self addIconValue:item[@"logoFile"] toCandidates:candidates];
            }
        }
    }
}

- (void)addIconCandidatesFromModsTomlData:(NSData *)data toCandidates:(NSMutableArray<NSString *> *)candidates {
    NSString *content = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (content.length == 0) {
        content = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    }
    for (NSString *line in [content componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *cleanLine = line;
        NSRange commentRange = [cleanLine rangeOfString:@"#"];
        if (commentRange.location != NSNotFound) {
            cleanLine = [cleanLine substringToIndex:commentRange.location];
        }
        cleanLine = [cleanLine stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (![cleanLine hasPrefix:@"logoFile"]) {
            continue;
        }
        NSRange equalsRange = [cleanLine rangeOfString:@"="];
        if (equalsRange.location == NSNotFound) {
            continue;
        }
        NSString *path = [self trimmedMetadataValue:[cleanLine substringFromIndex:equalsRange.location + 1]];
        if (path.length > 0) {
            [candidates addObject:path];
        }
    }
}

- (NSArray<NSString *> *)metadataIconCandidatesFromArchive:(UZKArchive *)archive {
    NSMutableArray<NSString *> *candidates = [NSMutableArray new];

    [self addIconCandidatesFromJSONData:[archive extractDataFromFile:@"fabric.mod.json" error:nil]
        rootPath:@[] toCandidates:candidates];
    [self addIconCandidatesFromJSONData:[archive extractDataFromFile:@"quilt.mod.json" error:nil]
        rootPath:@[@"quilt_loader", @"metadata"] toCandidates:candidates];
    [self addIconCandidatesFromJSONData:[archive extractDataFromFile:@"mcmod.info" error:nil]
        rootPath:@[] toCandidates:candidates];
    [self addIconCandidatesFromModsTomlData:[archive extractDataFromFile:@"META-INF/mods.toml" error:nil]
        toCandidates:candidates];
    [self addIconCandidatesFromModsTomlData:[archive extractDataFromFile:@"META-INF/neoforge.mods.toml" error:nil]
        toCandidates:candidates];

    NSError *error;
    NSArray<UZKFileInfo *> *files = [archive listFileInfo:&error] ?: @[];
    for (UZKFileInfo *info in files) {
        NSString *filename = info.filename.lowercaseString;
        NSString *lastPath = filename.lastPathComponent;
        if (info.isDirectory || !([filename hasSuffix:@".png"] || [filename hasSuffix:@".jpg"] || [filename hasSuffix:@".jpeg"])) {
            continue;
        }
        if ([lastPath isEqualToString:@"icon.png"] || [lastPath isEqualToString:@"logo.png"] ||
            [lastPath isEqualToString:@"pack.png"] || [lastPath containsString:@"icon"] ||
            [lastPath containsString:@"logo"]) {
            [candidates addObject:info.filename];
        }
    }

    return candidates;
}

- (UIImage *)imageForArchive:(UZKArchive *)archive candidatePath:(NSString *)candidatePath {
    NSString *path = [[candidatePath stringByReplacingOccurrencesOfString:@"\\" withString:@"/"]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    while ([path hasPrefix:@"/"] || [path hasPrefix:@"./"]) {
        path = [path hasPrefix:@"/"] ? [path substringFromIndex:1] : [path substringFromIndex:2];
    }
    if (path.length == 0) {
        return nil;
    }

    NSData *data = [archive extractDataFromFile:path error:nil];
    UIImage *image = data ? [UIImage imageWithData:data] : nil;
    return [self imageByFittingImage:image toSize:CGSizeMake(40, 40)];
}

- (UIImage *)iconForModFile:(NSString *)file path:(NSString *)path {
    UIImage *cachedIcon = self.iconCache[file];
    if (cachedIcon) {
        return cachedIcon;
    }
    return [self defaultModIcon];
}

- (void)configurePopoverForAlert:(UIAlertController *)alert sourceView:(UIView *)sourceView {
    if (alert.preferredStyle != UIAlertControllerStyleActionSheet) {
        return;
    }
    UIView *targetView = sourceView ?: self.view;
    alert.popoverPresentationController.sourceView = targetView;
    alert.popoverPresentationController.sourceRect = sourceView ? targetView.bounds :
        CGRectMake(CGRectGetMidX(targetView.bounds), CGRectGetMidY(targetView.bounds), 1, 1);
}

- (UIAlertController *)presentLoadingAlertWithTitle:(NSString *)title {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
        message:@"Please wait..."
        preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:alert animated:YES completion:nil];
    return alert;
}

- (NSString *)safeFileName:(NSString *)fileName fallbackURL:(NSString *)url {
    NSString *result = fileName.length > 0 ? fileName : url.lastPathComponent;
    result = [result stringByRemovingPercentEncoding] ?: result;
    result = [result stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    result = [result stringByReplacingOccurrencesOfString:@"\\" withString:@"_"];
    result = [result stringByReplacingOccurrencesOfString:@":" withString:@"_"];
    if (result.length == 0) {
        NSString *extension = self.managedExtensions.firstObject ?: @"jar";
        result = [NSString stringWithFormat:@"download.%@", extension];
    }
    return result;
}

- (NSString *)targetFileNameForProject:(NSDictionary *)project atIndex:(NSUInteger)index preserveDisabledState:(BOOL)preserveDisabledState {
    NSArray *fileNames = [project[@"versionFileNames"] isKindOfClass:NSArray.class] ? project[@"versionFileNames"] : @[];
    NSArray *urls = [project[@"versionUrls"] isKindOfClass:NSArray.class] ? project[@"versionUrls"] : @[];
    NSString *fileName = index < fileNames.count ? fileNames[index] : nil;
    NSString *url = index < urls.count ? urls[index] : nil;
    NSString *targetName = [self safeFileName:fileName fallbackURL:url];
    if (preserveDisabledState && ![targetName hasSuffix:@".disabled"]) {
        targetName = [targetName stringByAppendingString:@".disabled"];
    }
    return targetName;
}

- (void)presentSearchPromptWithInitialQuery:(NSString *)initialQuery replacingFile:(NSString *)file sourceView:(UIView *)sourceView {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"Search %@", self.title ?: @"Files"]
        message:[NSString stringWithFormat:@"Find Modrinth %@ to install or use as the new version.", self.title.lowercaseString ?: @"files"]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"Name or ID";
        textField.text = initialQuery;
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"Cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Search" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *query = [alert.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (query.length == 0) {
            return;
        }
        [self searchModrinthForQuery:query replacingFile:file sourceView:sourceView ?: self.view];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)searchModrinthForQuery:(NSString *)query replacingFile:(NSString *)file sourceView:(UIView *)sourceView {
    UIAlertController *loading = [self presentLoadingAlertWithTitle:@"Searching Modrinth"];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        ModrinthAPI *api = [ModrinthAPI new];
        NSMutableArray *results = [api searchModWithFilters:@{
            @"projectType": self.projectType ?: @"mod",
            @"name": query
        } previousPageResult:nil];
        NSError *error = api.lastError;
        dispatch_async(dispatch_get_main_queue(), ^{
            [loading dismissViewControllerAnimated:YES completion:^{
                if (results.count == 0) {
                    showDialog(localize(@"Error", nil), error.localizedDescription ?: [NSString stringWithFormat:@"No matching %@ were found on Modrinth.", self.title.lowercaseString]);
                    return;
                }
                [self presentProjectChooser:results api:api query:query replacingFile:file sourceView:sourceView];
            }];
        });
    });
}

- (void)loadModrinthProjectForFileAtPath:(NSString *)path api:(ModrinthAPI *)api completion:(void (^)(NSMutableDictionary *project, NSError *error))completion {
    NSString *sha1 = [self sha1ForFileAtPath:path];
    if (sha1.length == 0) {
        NSError *error = [NSError errorWithDomain:@"ModManager"
            code:1
            userInfo:@{NSLocalizedDescriptionKey: @"Could not calculate SHA1 for this file."}];
        completion(nil, error);
        return;
    }

    NSMutableDictionary *project = [api projectForFileHash:sha1 projectType:self.projectType ?: @"mod"];
    NSError *error = api.lastError;
    if (project && ![project[@"versionDetailsLoaded"] boolValue]) {
        [api loadDetailsOfMod:project];
        error = api.lastError ?: error;
    }
    completion(project, error);
}

- (void)presentManualSearchFallbackForFile:(NSString *)file metadata:(NSDictionary *)metadata sourceView:(UIView *)sourceView {
    NSString *query = [self searchQueryForModFile:file metadata:metadata ?: @{}];
    [self presentSearchPromptWithInitialQuery:query replacingFile:file sourceView:sourceView];
}

- (NSMutableDictionary *)firstModrinthProjectForQueries:(NSArray<NSString *> *)queries api:(ModrinthAPI *)api error:(NSError **)error {
    for (NSString *query in queries) {
        NSMutableArray *results = [api searchModWithFilters:@{
            @"projectType": self.projectType ?: @"mod",
            @"name": query
        } previousPageResult:nil];
        if (api.lastError && error) {
            *error = api.lastError;
        }
        if (results.count > 0) {
            return results.firstObject;
        }
    }
    return nil;
}

- (void)updateLatestModrinthVersionForFile:(NSString *)file path:(NSString *)path metadata:(NSDictionary *)metadata sourceView:(UIView *)sourceView {
    UIAlertController *loading = [self presentLoadingAlertWithTitle:@"Checking for Update"];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        ModrinthAPI *api = [ModrinthAPI new];
        [self loadModrinthProjectForFileAtPath:path api:api completion:^(NSMutableDictionary *project, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [loading dismissViewControllerAnimated:YES completion:^{
                    if (!project) {
                        [self presentManualSearchFallbackForFile:file metadata:metadata sourceView:sourceView];
                        return;
                    }
                    NSArray *versions = [project[@"versionNames"] isKindOfClass:NSArray.class] ? project[@"versionNames"] : @[];
                    if (versions.count == 0) {
                        showDialog(localize(@"Error", nil), error.localizedDescription ?: @"No downloadable versions were found.");
                        return;
                    }
                    [self installProject:project api:api atIndex:0 replacingFile:file];
                }];
            });
        }];
    });
}

- (void)updateLatestModrinthVersionForQueries:(NSArray<NSString *> *)queries replacingFile:(NSString *)file sourceView:(UIView *)sourceView {
    UIAlertController *loading = [self presentLoadingAlertWithTitle:@"Checking for Update"];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        ModrinthAPI *api = [ModrinthAPI new];
        NSError *error = nil;
        NSMutableDictionary *project = [self firstModrinthProjectForQueries:queries api:api error:&error];
        if (project && ![project[@"versionDetailsLoaded"] boolValue]) {
            [api loadDetailsOfMod:project];
            error = api.lastError ?: error;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [loading dismissViewControllerAnimated:YES completion:^{
                if (!project) {
                    [self presentSearchPromptWithInitialQuery:queries.firstObject replacingFile:file sourceView:sourceView];
                    return;
                }
                NSArray *versions = [project[@"versionNames"] isKindOfClass:NSArray.class] ? project[@"versionNames"] : @[];
                if (versions.count == 0) {
                    showDialog(localize(@"Error", nil), error.localizedDescription ?: @"No downloadable versions were found.");
                    return;
                }
                [self installProject:project api:api atIndex:0 replacingFile:file];
            }];
        });
    });
}

- (void)updateLatestModrinthVersionForQuery:(NSString *)query replacingFile:(NSString *)file sourceView:(UIView *)sourceView {
    [self updateLatestModrinthVersionForQueries:@[query ?: @""] replacingFile:file sourceView:sourceView];
}

- (void)presentDowngradeVersionsForFile:(NSString *)file path:(NSString *)path metadata:(NSDictionary *)metadata sourceView:(UIView *)sourceView {
    UIAlertController *loading = [self presentLoadingAlertWithTitle:@"Loading Versions"];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        ModrinthAPI *api = [ModrinthAPI new];
        [self loadModrinthProjectForFileAtPath:path api:api completion:^(NSMutableDictionary *project, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [loading dismissViewControllerAnimated:YES completion:^{
                    if (!project) {
                        [self presentManualSearchFallbackForFile:file metadata:metadata sourceView:sourceView];
                        return;
                    }
                    NSArray *versions = [project[@"versionNames"] isKindOfClass:NSArray.class] ? project[@"versionNames"] : @[];
                    if (versions.count == 0) {
                        showDialog(localize(@"Error", nil), error.localizedDescription ?: @"No downloadable versions were found.");
                        return;
                    }
                    [self presentVersionActionSheetForProject:project api:api replacingFile:file sourceView:sourceView];
                }];
            });
        }];
    });
}

- (void)presentDowngradeVersionsForQueries:(NSArray<NSString *> *)queries replacingFile:(NSString *)file sourceView:(UIView *)sourceView {
    UIAlertController *loading = [self presentLoadingAlertWithTitle:@"Loading Versions"];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        ModrinthAPI *api = [ModrinthAPI new];
        NSError *error = nil;
        NSMutableDictionary *project = [self firstModrinthProjectForQueries:queries api:api error:&error];
        if (project && ![project[@"versionDetailsLoaded"] boolValue]) {
            [api loadDetailsOfMod:project];
            error = api.lastError ?: error;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [loading dismissViewControllerAnimated:YES completion:^{
                if (!project) {
                    [self presentSearchPromptWithInitialQuery:queries.firstObject replacingFile:file sourceView:sourceView];
                    return;
                }
                NSArray *versions = [project[@"versionNames"] isKindOfClass:NSArray.class] ? project[@"versionNames"] : @[];
                if (versions.count == 0) {
                    showDialog(localize(@"Error", nil), error.localizedDescription ?: @"No downloadable versions were found.");
                    return;
                }
                [self presentVersionActionSheetForProject:project api:api replacingFile:file sourceView:sourceView];
            }];
        });
    });
}

- (void)presentDowngradeVersionsForQuery:(NSString *)query replacingFile:(NSString *)file sourceView:(UIView *)sourceView {
    [self presentDowngradeVersionsForQueries:@[query ?: @""] replacingFile:file sourceView:sourceView];
}

- (void)presentProjectChooser:(NSArray<NSMutableDictionary *> *)projects api:(ModrinthAPI *)api query:(NSString *)query replacingFile:(NSString *)file sourceView:(UIView *)sourceView {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"Choose %@", self.title ?: @"Project"]
        message:[NSString stringWithFormat:@"Results for \"%@\"", query]
        preferredStyle:UIAlertControllerStyleActionSheet];
    NSUInteger maxProjects = MIN(projects.count, 20);
    for (NSUInteger i = 0; i < maxProjects; i++) {
        NSMutableDictionary *project = projects[i];
        NSString *title = project[@"title"];
        if (title.length == 0) {
            title = @"Project";
        }
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [self presentVersionChooserForProject:project api:api replacingFile:file sourceView:sourceView];
        }]];
    }
    if (projects.count > maxProjects) {
        UIAlertAction *more = [UIAlertAction actionWithTitle:[NSString stringWithFormat:@"%lu more results not shown", (unsigned long)(projects.count - maxProjects)]
            style:UIAlertActionStyleDefault handler:nil];
        more.enabled = NO;
        [sheet addAction:more];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Search Again" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self presentSearchPromptWithInitialQuery:query replacingFile:file sourceView:sourceView];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:localize(@"Cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
    [self configurePopoverForAlert:sheet sourceView:sourceView];
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)presentVersionChooserForProject:(NSMutableDictionary *)project api:(ModrinthAPI *)api replacingFile:(NSString *)file sourceView:(UIView *)sourceView {
    UIAlertController *loading = [self presentLoadingAlertWithTitle:@"Loading Versions"];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        if (![project[@"versionDetailsLoaded"] boolValue]) {
            [api loadDetailsOfMod:project];
        }
        NSError *error = api.lastError;
        dispatch_async(dispatch_get_main_queue(), ^{
            [loading dismissViewControllerAnimated:YES completion:^{
                NSArray *versions = [project[@"versionNames"] isKindOfClass:NSArray.class] ? project[@"versionNames"] : @[];
                if (versions.count == 0) {
                    showDialog(localize(@"Error", nil), error.localizedDescription ?: @"No downloadable versions were found.");
                    return;
                }
                [self presentVersionActionSheetForProject:project api:api replacingFile:file sourceView:sourceView];
            }];
        });
    });
}

- (void)presentVersionActionSheetForProject:(NSMutableDictionary *)project api:(ModrinthAPI *)api replacingFile:(NSString *)file sourceView:(UIView *)sourceView {
    NSArray *versions = [project[@"versionNames"] isKindOfClass:NSArray.class] ? project[@"versionNames"] : @[];
    NSArray *mcVersions = [project[@"mcVersionNames"] isKindOfClass:NSArray.class] ? project[@"mcVersionNames"] : @[];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:project[@"title"] ?: @"Choose Version"
        message:file.length > 0 ? @"Choose the version to install for this file." : @"Choose a version to install."
        preferredStyle:UIAlertControllerStyleActionSheet];
    NSUInteger maxVersions = versions.count;
    for (NSUInteger i = 0; i < maxVersions; i++) {
        NSString *versionName = versions[i];
        NSString *mcVersion = i < mcVersions.count ? mcVersions[i] : @"";
        NSString *title = mcVersion.length > 0 ? [NSString stringWithFormat:@"%@ (%@)", versionName, mcVersion] : versionName;
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [self confirmInstallProject:project api:api atIndex:i replacingFile:file sourceView:sourceView];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:localize(@"Cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
    [self configurePopoverForAlert:sheet sourceView:sourceView];
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)installProject:(NSMutableDictionary *)project api:(ModrinthAPI *)api atIndex:(NSUInteger)index replacingFile:(NSString *)file {
    BOOL replacing = file.length > 0;
    BOOL preserveDisabledState = replacing && ![self isFileEnabled:file];
    NSMutableDictionary *detail = [project mutableCopy];
    detail[@"projectType"] = self.projectType ?: @"mod";
    detail[@"targetGameDir"] = [self selectedProfileGameDirectory];
    if (self.profile[@"name"]) {
        detail[@"targetProfileName"] = self.profile[@"name"];
    }
    if (replacing) {
        detail[@"replaceFilePath"] = [self.modsPath stringByAppendingPathComponent:file];
        detail[@"installDisabled"] = @(preserveDisabledState);
    }
    [api installProjectFromDetail:detail atIndex:index];
}

- (void)confirmInstallProject:(NSMutableDictionary *)project api:(ModrinthAPI *)api atIndex:(NSUInteger)index replacingFile:(NSString *)file sourceView:(UIView *)sourceView {
    BOOL replacing = file.length > 0;
    BOOL preserveDisabledState = replacing && ![self isFileEnabled:file];
    NSString *targetName = [self targetFileNameForProject:project atIndex:index preserveDisabledState:preserveDisabledState];
    NSString *targetPath = [self.modsPath stringByAppendingPathComponent:targetName];
    NSString *replacePath = replacing ? [self.modsPath stringByAppendingPathComponent:file] : nil;
    BOOL overwritingAnotherFile = [NSFileManager.defaultManager fileExistsAtPath:targetPath] &&
        (replacePath.length == 0 || ![targetPath isEqualToString:replacePath]);

    NSString *message;
    if (replacing) {
        message = [NSString stringWithFormat:@"Replace %@ with %@?", [self enabledNameForDisabledFile:file], targetName];
    } else {
        message = [NSString stringWithFormat:@"Install %@?", targetName];
    }
    if (overwritingAnotherFile) {
        message = [message stringByAppendingFormat:@"\n\nA file named %@ already exists and will be replaced.", targetName];
    }

    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:replacing ? @"Change Version" : @"Install"
        message:message
        preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:localize(@"Cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Install" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self installProject:project api:api atIndex:index replacingFile:file];
    }]];
    [self presentViewController:confirm animated:YES completion:nil];
}

#pragma mark UITableView

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return MAX(self.files.count, 1);
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ModCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"ModCell"];
        cell.textLabel.numberOfLines = 0;
        cell.detailTextLabel.numberOfLines = 0;
    }
    cell.accessoryView = nil;
    cell.selectionStyle = self.files.count == 0 ? UITableViewCellSelectionStyleNone : UITableViewCellSelectionStyleDefault;
    cell.textLabel.enabled = YES;
    cell.detailTextLabel.enabled = YES;
    cell.imageView.alpha = 1.0;

    if (self.files.count == 0) {
        BOOL hasInstalledFiles = self.allFiles.count > 0;
        cell.textLabel.text = hasInstalledFiles ? [NSString stringWithFormat:@"No matching %@", self.title.lowercaseString] :
            [NSString stringWithFormat:@"No %@ installed", self.title.lowercaseString];
        cell.detailTextLabel.text = hasInstalledFiles ? [self installedModSearchText] : self.modsPath;
        cell.imageView.image = [self defaultModIcon];
        cell.imageView.alpha = 0.35;
        cell.textLabel.enabled = NO;
        cell.detailTextLabel.enabled = NO;
        return cell;
    }

    NSString *file = self.files[indexPath.row];
    BOOL enabled = [self isFileEnabled:file];
    NSString *path = [self pathForFileAtRow:indexPath.row];
    NSDictionary *metadata = [self metadataForModFile:file];
    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    NSString *size = [NSByteCountFormatter stringFromByteCount:[attrs[NSFileSize] unsignedLongLongValue]
        countStyle:NSByteCountFormatterCountStyleFile];
    NSString *version = metadata[@"version"];
    NSString *state = enabled ? @"Enabled" : @"Disabled";

    cell.textLabel.text = metadata[@"displayName"] ?: [self enabledNameForDisabledFile:file];
    cell.detailTextLabel.text = version.length > 0 ?
        [NSString stringWithFormat:@"%@ - %@ - %@", state, version, size] :
        [NSString stringWithFormat:@"%@ - %@", state, size];
    cell.textLabel.enabled = enabled;
    cell.detailTextLabel.enabled = enabled;
    cell.imageView.image = [self iconForModFile:file path:path];
    cell.imageView.alpha = enabled ? 1.0 : 0.35;
    [self startLoadingDetailsForModFile:file path:path];

    UISwitch *toggle = [UISwitch new];
    toggle.on = enabled;
    toggle.tag = indexPath.row;
    [toggle addTarget:self action:@selector(actionToggleMod:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = toggle;
    return cell;
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    return self.files.count == 0 ? UITableViewCellEditingStyleNone : UITableViewCellEditingStyleDelete;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.files.count == 0) {
        return;
    }
    [self actionManageVersionsAtIndexPath:indexPath];
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle == UITableViewCellEditingStyleDelete) {
        [self actionDeleteModAtIndexPath:indexPath];
    }
}

#pragma mark Actions

- (void)actionSearchMod {
    self.searchController.active = YES;
    [self.searchController.searchBar becomeFirstResponder];
}

- (void)actionManageVersionsAtIndexPath:(NSIndexPath *)indexPath {
    NSString *file = self.files[indexPath.row];
    NSString *path = [self pathForFileAtRow:indexPath.row];
    NSDictionary *metadata = [self metadataForModFile:file];
    [self startLoadingDetailsForModFile:file path:path];
    NSString *version = metadata[@"version"];
    NSString *message = version.length > 0 ?
        [NSString stringWithFormat:@"Current version: %@", version] :
        @"Choose how to change this version.";

    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:metadata[@"displayName"] ?: [self enabledNameForDisabledFile:file]
        message:message
        preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Update" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self updateLatestModrinthVersionForFile:file path:path metadata:metadata sourceView:cell ?: self.view];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"H\u1ea1 phi\u00ean b\u1ea3n" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self presentDowngradeVersionsForFile:file path:path metadata:metadata sourceView:cell ?: self.view];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:localize(@"Cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
    [self configurePopoverForAlert:sheet sourceView:cell ?: self.view];
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)actionToggleMod:(UISwitch *)sender {
    NSInteger row = sender.tag;
    if (row < 0 || row >= self.files.count) {
        return;
    }

    NSString *file = self.files[row];
    NSString *source = [self.modsPath stringByAppendingPathComponent:file];
    NSString *destName = sender.isOn ? [self enabledNameForDisabledFile:file] : [file stringByAppendingString:@".disabled"];
    NSString *dest = [self.modsPath stringByAppendingPathComponent:destName];

    if ([source isEqualToString:dest]) {
        return;
    }
    if ([NSFileManager.defaultManager fileExistsAtPath:dest]) {
        sender.on = !sender.isOn;
        showDialog(localize(@"Error", nil), [NSString stringWithFormat:@"A file named %@ already exists.", destName]);
        return;
    }

    NSError *error;
    if (![NSFileManager.defaultManager moveItemAtPath:source toPath:dest error:&error]) {
        sender.on = !sender.isOn;
        showDialog(localize(@"Error", nil), error.localizedDescription);
        return;
    }
    [self moveCachedDetailsFromFile:file toFile:destName];
    NSUInteger allFilesIndex = [self.allFiles indexOfObject:file];
    if (allFilesIndex != NSNotFound) {
        self.allFiles[allFilesIndex] = destName;
    }
    [self.allFiles sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    [self applyInstalledModFilter];
}

- (void)actionDeleteModAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
    NSString *file = self.files[indexPath.row];
    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:localize(@"preference.title.confirm", nil)
        message:[NSString stringWithFormat:@"Delete %@?", [self enabledNameForDisabledFile:file]]
        preferredStyle:UIAlertControllerStyleActionSheet];
    confirm.popoverPresentationController.sourceView = cell;
    confirm.popoverPresentationController.sourceRect = cell.bounds;
    [confirm addAction:[UIAlertAction actionWithTitle:localize(@"Cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
    [confirm addAction:[UIAlertAction actionWithTitle:localize(@"Delete", nil) style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        NSError *error;
        if (![NSFileManager.defaultManager removeItemAtPath:[self pathForFileAtRow:indexPath.row] error:&error]) {
            showDialog(localize(@"Error", nil), error.localizedDescription);
            return;
        }
        [self.allFiles removeObject:file];
        [self.files removeObject:file];
        [self.iconCache removeObjectForKey:file];
        [self.metadataCache removeObjectForKey:file];
        [self.loadingDetailFiles removeObject:file];
        [self.loadedDetailFiles removeObject:file];
        [self applyInstalledModFilter];
    }]];
    [self presentViewController:confirm animated:YES completion:nil];
}

#pragma mark Search

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    [self applyInstalledModFilter];
}

- (void)searchBarCancelButtonClicked:(UISearchBar *)searchBar {
    [self applyInstalledModFilter];
}

@end
