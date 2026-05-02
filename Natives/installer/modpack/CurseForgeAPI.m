#import "AFNetworking.h"
#import "MinecraftResourceDownloadTask.h"
#import "PLProfiles.h"
#import "CurseForgeAPI.h"
#import "config.h"

static const NSInteger kCurseForgeGameIDMinecraft = 432;
static const NSInteger kCurseForgeClassIDBukkitPlugins = 5;
static const NSInteger kCurseForgeClassIDMods = 6;
static const NSInteger kCurseForgeClassIDResourcePacks = 12;
static const NSInteger kCurseForgeClassIDModpacks = 4471;
static const NSInteger kCurseForgeClassIDShaders = 6552;
static const NSInteger kCurseForgeClassIDDataPacks = 6945;
static const NSInteger kCurseForgeCategoryIDServerUtility = 435;

@implementation CurseForgeAPI

- (instancetype)init {
    return [super initWithURL:@"https://api.curseforge.com/v1"];
}

- (NSString *)apiKey {
    NSString *key = @CONFIG_CURSEFORGE_API_KEY;
    if (key.length == 0) {
        key = NSBundle.mainBundle.infoDictionary[@"CurseForgeAPIKey"];
    }
    return [key isKindOfClass:NSString.class] ? key : @"";
}

- (NSDictionary *)headers {
    NSString *key = [self apiKey];
    if (key.length == 0) {
        return nil;
    }
    return @{
        @"Accept": @"application/json",
        @"x-api-key": key
    };
}

- (NSError *)missingAPIKeyError {
    return [NSError errorWithDomain:@"CurseForgeAPI"
        code:401
        userInfo:@{NSLocalizedDescriptionKey: @"CurseForge API key is missing. Set CURSEFORGE_API_KEY before building."}];
}

- (id)getEndpoint:(NSString *)endpoint params:(NSDictionary *)params {
    NSDictionary *headers = [self headers];
    if (!headers) {
        self.lastError = [self missingAPIKeyError];
        return nil;
    }

    __block id result;
    dispatch_group_t group = dispatch_group_create();
    dispatch_group_enter(group);
    NSString *url = [self.baseURL stringByAppendingPathComponent:endpoint];
    AFHTTPSessionManager *manager = [AFHTTPSessionManager manager];
    [manager GET:url parameters:params headers:headers progress:nil
    success:^(NSURLSessionTask *task, id obj) {
        result = obj;
        dispatch_group_leave(group);
    } failure:^(NSURLSessionTask *operation, NSError *error) {
        self.lastError = error;
        dispatch_group_leave(group);
    }];
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
    return result;
}

- (id)postEndpoint:(NSString *)endpoint params:(NSDictionary *)params {
    NSDictionary *headers = [self headers];
    if (!headers) {
        self.lastError = [self missingAPIKeyError];
        return nil;
    }

    __block id result;
    dispatch_group_t group = dispatch_group_create();
    dispatch_group_enter(group);
    NSString *url = [self.baseURL stringByAppendingPathComponent:endpoint];
    AFHTTPSessionManager *manager = [AFHTTPSessionManager manager];
    manager.requestSerializer = [AFJSONRequestSerializer serializer];
    [manager POST:url parameters:params headers:headers progress:nil
    success:^(NSURLSessionTask *task, id obj) {
        result = obj;
        dispatch_group_leave(group);
    } failure:^(NSURLSessionTask *operation, NSError *error) {
        self.lastError = error;
        dispatch_group_leave(group);
    }];
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
    return result;
}

- (NSNumber *)classIDForProjectType:(NSString *)projectType {
    if ([projectType isEqualToString:@"modpack"]) {
        return @(kCurseForgeClassIDModpacks);
    }
    if ([projectType isEqualToString:@"plugin"]) {
        return @(kCurseForgeClassIDBukkitPlugins);
    }
    if ([projectType isEqualToString:@"datapack"]) {
        return @(kCurseForgeClassIDDataPacks);
    }
    if ([projectType isEqualToString:@"shader"]) {
        return @(kCurseForgeClassIDShaders);
    }
    if ([projectType isEqualToString:@"resourcepack"]) {
        return @(kCurseForgeClassIDResourcePacks);
    }
    return @(kCurseForgeClassIDMods);
}

- (NSArray<NSString *> *)preferredFileExtensionsForProjectType:(NSString *)projectType {
    if ([projectType isEqualToString:@"shader"] ||
        [projectType isEqualToString:@"resourcepack"] ||
        [projectType isEqualToString:@"datapack"] ||
        [projectType isEqualToString:@"modpack"]) {
        return @[@"zip"];
    }
    return @[@"jar"];
}

- (BOOL)file:(NSDictionary *)file matchesProjectType:(NSString *)projectType {
    if (![file isKindOfClass:NSDictionary.class]) {
        return NO;
    }
    if ([file[@"isAvailable"] respondsToSelector:@selector(boolValue)] &&
        ![file[@"isAvailable"] boolValue]) {
        return NO;
    }
    if ([projectType isEqualToString:@"modpack"] && [file[@"isServerPack"] boolValue]) {
        return NO;
    }

    NSString *fileName = [file[@"fileName"] isKindOfClass:NSString.class] ? file[@"fileName"] : @"";
    NSString *extension = fileName.pathExtension.lowercaseString;
    NSArray *extensions = [self preferredFileExtensionsForProjectType:projectType];
    return extensions.count == 0 || [extensions containsObject:extension];
}

- (NSString *)imageURLForProject:(NSDictionary *)project {
    NSDictionary *logo = [project[@"logo"] isKindOfClass:NSDictionary.class] ? project[@"logo"] : nil;
    NSString *image = logo[@"thumbnailUrl"];
    if (![image isKindOfClass:NSString.class] || image.length == 0) {
        image = logo[@"url"];
    }
    return [image isKindOfClass:NSString.class] ? image : @"";
}

- (NSMutableDictionary *)projectFromCurseForgeProject:(NSDictionary *)project projectType:(NSString *)projectType {
    NSString *title = project[@"name"];
    NSString *description = project[@"summary"];
    return @{
        @"apiSource": @(2),
        @"isModpack": @([projectType isEqualToString:@"modpack"]),
        @"projectType": projectType ?: @"mod",
        @"id": [project[@"id"] description] ?: @"",
        @"title": [title isKindOfClass:NSString.class] ? title : @"",
        @"description": [description isKindOfClass:NSString.class] ? description : @"",
        @"imageUrl": [self imageURLForProject:project]
    }.mutableCopy;
}

- (NSMutableArray *)searchModWithFilters:(NSDictionary<NSString *, NSString *> *)searchFilters previousPageResult:(NSMutableArray *)previousPageResult {
    int pageSize = 50;
    NSString *projectType = searchFilters[@"projectType"];
    if (projectType.length == 0) {
        projectType = searchFilters[@"isModpack"] ? (searchFilters[@"isModpack"].boolValue ? @"modpack" : @"mod") : @"modpack";
    }

    NSMutableDictionary *params = @{
        @"gameId": @(kCurseForgeGameIDMinecraft),
        @"classId": [self classIDForProjectType:projectType],
        @"pageSize": @(pageSize),
        @"index": @(previousPageResult.count)
    }.mutableCopy;
    NSString *query = [searchFilters[@"name"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    if (query.length > 0) {
        params[@"searchFilter"] = query;
    }
    if (searchFilters[@"mcVersion"].length > 0) {
        params[@"gameVersion"] = searchFilters[@"mcVersion"];
    }
    if ([projectType isEqualToString:@"minecraft_java_server"]) {
        params[@"categoryId"] = @(kCurseForgeCategoryIDServerUtility);
    }

    NSDictionary *response = [self getEndpoint:@"mods/search" params:params];
    if (!response) {
        return nil;
    }

    NSMutableArray *result = previousPageResult ?: [NSMutableArray new];
    NSArray *projects = [response[@"data"] isKindOfClass:NSArray.class] ? response[@"data"] : @[];
    for (NSDictionary *project in projects) {
        if (![project isKindOfClass:NSDictionary.class]) {
            continue;
        }
        [result addObject:[self projectFromCurseForgeProject:project projectType:projectType]];
    }

    NSDictionary *pagination = [response[@"pagination"] isKindOfClass:NSDictionary.class] ? response[@"pagination"] : @{};
    NSUInteger total = [pagination[@"totalCount"] unsignedIntegerValue];
    NSUInteger index = [pagination[@"index"] unsignedIntegerValue];
    NSUInteger count = [pagination[@"resultCount"] unsignedIntegerValue];
    self.reachedLastPage = total == 0 || index + count >= total;
    return result;
}

- (NSString *)sha1ForFile:(NSDictionary *)file {
    NSArray *hashes = [file[@"hashes"] isKindOfClass:NSArray.class] ? file[@"hashes"] : @[];
    for (NSDictionary *hash in hashes) {
        if ([hash[@"algo"] integerValue] == 1 && [hash[@"value"] isKindOfClass:NSString.class]) {
            return hash[@"value"];
        }
    }
    return @"";
}

- (NSString *)downloadURLForFile:(NSDictionary *)file {
    NSString *url = file[@"downloadUrl"];
    if ([url isKindOfClass:NSString.class] && url.length > 0) {
        return url;
    }

    NSString *modId = [file[@"modId"] description];
    NSString *fileId = [file[@"id"] description];
    if (modId.length == 0 || fileId.length == 0) {
        return @"";
    }
    NSDictionary *response = [self getEndpoint:[NSString stringWithFormat:@"mods/%@/files/%@/download-url", modId, fileId] params:nil];
    NSString *fallback = [response isKindOfClass:NSDictionary.class] ? response[@"data"] : nil;
    if ([fallback isKindOfClass:NSString.class] && fallback.length > 0) {
        return fallback;
    }

    NSString *fileName = [file[@"fileName"] isKindOfClass:NSString.class] ? file[@"fileName"] : @"";
    NSInteger numericFileId = fileId.integerValue;
    if (numericFileId <= 0 || fileName.length == 0) {
        return @"";
    }

    NSString *encodedName = [fileName stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet];
    return [NSString stringWithFormat:@"https://edge.forgecdn.net/files/%ld/%03ld/%@",
        (long)(numericFileId / 1000),
        (long)(numericFileId % 1000),
        encodedName ?: fileName];
}

- (NSString *)gameVersionSummaryForFile:(NSDictionary *)file {
    NSArray<NSString *> *gameVersions = [file[@"gameVersions"] isKindOfClass:NSArray.class] ? file[@"gameVersions"] : @[];
    NSMutableArray<NSString *> *minecraftVersions = [NSMutableArray new];
    NSMutableArray<NSString *> *loaders = [NSMutableArray new];
    NSCharacterSet *digits = NSCharacterSet.decimalDigitCharacterSet;
    for (NSString *value in gameVersions) {
        if (![value isKindOfClass:NSString.class] || value.length == 0) {
            continue;
        }
        unichar first = [value characterAtIndex:0];
        if ([digits characterIsMember:first]) {
            [minecraftVersions addObject:value];
        } else if ([value rangeOfString:@"client" options:NSCaseInsensitiveSearch].location == NSNotFound &&
                   [value rangeOfString:@"server" options:NSCaseInsensitiveSearch].location == NSNotFound) {
            [loaders addObject:value];
        }
    }

    NSString *mcVersion = minecraftVersions.firstObject ?: @"";
    NSString *loader = loaders.firstObject ?: @"";
    if (mcVersion.length > 0 && loader.length > 0) {
        return [NSString stringWithFormat:@"%@/%@", mcVersion, loader];
    }
    return mcVersion.length > 0 ? mcVersion : loader;
}

- (void)addFile:(NSDictionary *)file toNames:(NSMutableArray *)names mcNames:(NSMutableArray *)mcNames urls:(NSMutableArray *)urls hashes:(NSMutableArray *)hashes sizes:(NSMutableArray *)sizes fileNames:(NSMutableArray *)fileNames fileTypes:(NSMutableArray *)fileTypes projectType:(NSString *)projectType {
    if (![self file:file matchesProjectType:projectType]) {
        return;
    }
    NSString *url = [self downloadURLForFile:file];
    if (url.length == 0) {
        return;
    }

    NSString *name = file[@"displayName"];
    if (![name isKindOfClass:NSString.class] || name.length == 0) {
        name = file[@"fileName"];
    }
    NSString *fileName = file[@"fileName"];
    if (![fileName isKindOfClass:NSString.class] || fileName.length == 0) {
        fileName = url.lastPathComponent;
    }

    [names addObject:name ?: @"Download"];
    [mcNames addObject:[self gameVersionSummaryForFile:file] ?: @""];
    [sizes addObject:file[@"fileLength"] ?: @0];
    [urls addObject:url];
    [hashes addObject:[self sha1ForFile:file] ?: @""];
    [fileNames addObject:fileName ?: @"download"];
    [fileTypes addObject:@""];
}

- (void)loadDetailsOfMod:(NSMutableDictionary *)item {
    NSString *projectId = [item[@"id"] description];
    if (projectId.length == 0) {
        return;
    }

    NSMutableArray<NSString *> *names = [NSMutableArray new];
    NSMutableArray<NSString *> *mcNames = [NSMutableArray new];
    NSMutableArray<NSString *> *urls = [NSMutableArray new];
    NSMutableArray<NSString *> *hashes = [NSMutableArray new];
    NSMutableArray<NSString *> *sizes = [NSMutableArray new];
    NSMutableArray<NSString *> *fileNames = [NSMutableArray new];
    NSMutableArray<NSString *> *fileTypes = [NSMutableArray new];
    NSString *projectType = item[@"projectType"] ?: @"mod";

    NSUInteger index = 0;
    NSUInteger total = NSUIntegerMax;
    while (index < total) {
        NSDictionary *response = [self getEndpoint:[NSString stringWithFormat:@"mods/%@/files", projectId]
            params:@{@"pageSize": @50, @"index": @(index)}];
        if (!response) {
            return;
        }

        NSArray *files = [response[@"data"] isKindOfClass:NSArray.class] ? response[@"data"] : @[];
        for (NSDictionary *file in files) {
            [self addFile:file toNames:names mcNames:mcNames urls:urls hashes:hashes sizes:sizes fileNames:fileNames fileTypes:fileTypes projectType:projectType];
        }

        NSDictionary *pagination = [response[@"pagination"] isKindOfClass:NSDictionary.class] ? response[@"pagination"] : @{};
        total = [pagination[@"totalCount"] unsignedIntegerValue];
        NSUInteger resultCount = [pagination[@"resultCount"] unsignedIntegerValue];
        if (resultCount == 0) {
            break;
        }
        index += resultCount;
    }

    if (names.count == 0) {
        self.lastError = [NSError errorWithDomain:@"CurseForgeAPI"
            code:404
            userInfo:@{NSLocalizedDescriptionKey: @"No downloadable files were found for this CurseForge project."}];
        return;
    }

    item[@"versionNames"] = names;
    item[@"mcVersionNames"] = mcNames;
    item[@"versionSizes"] = sizes;
    item[@"versionUrls"] = urls;
    item[@"versionHashes"] = hashes;
    item[@"versionFileNames"] = fileNames;
    item[@"versionFileTypes"] = fileTypes;
    item[@"versionDetailsLoaded"] = @(YES);
}

- (NSDictionary *)modpackDependencyInfoFromManifest:(NSDictionary *)manifest {
    NSDictionary *minecraft = [manifest[@"minecraft"] isKindOfClass:NSDictionary.class] ? manifest[@"minecraft"] : @{};
    NSString *minecraftVersion = minecraft[@"version"];
    if (![minecraftVersion isKindOfClass:NSString.class] || minecraftVersion.length == 0) {
        return @{};
    }

    NSMutableDictionary *dependencies = @{@"minecraft": minecraftVersion}.mutableCopy;
    NSArray *modLoaders = [minecraft[@"modLoaders"] isKindOfClass:NSArray.class] ? minecraft[@"modLoaders"] : @[];
    NSDictionary *selectedLoader = nil;
    for (NSDictionary *loader in modLoaders) {
        if ([loader[@"primary"] boolValue]) {
            selectedLoader = loader;
            break;
        }
    }
    if (!selectedLoader) {
        selectedLoader = modLoaders.firstObject;
    }

    NSString *loaderId = [selectedLoader[@"id"] isKindOfClass:NSString.class] ? selectedLoader[@"id"] : @"";
    NSArray<NSString *> *loaderParts = [loaderId componentsSeparatedByString:@"-"];
    NSString *loaderName = loaderParts.count > 0 ? loaderParts.firstObject.lowercaseString : @"";
    NSString *loaderVersion = loaderParts.count > 1 ? [[loaderParts subarrayWithRange:NSMakeRange(1, loaderParts.count - 1)] componentsJoinedByString:@"-"] : @"";
    if ([loaderName isEqualToString:@"forge"]) {
        dependencies[@"forge"] = loaderVersion;
    } else if ([loaderName isEqualToString:@"fabric"]) {
        dependencies[@"fabric-loader"] = loaderVersion;
    } else if ([loaderName isEqualToString:@"quilt"]) {
        dependencies[@"quilt-loader"] = loaderVersion;
    } else if ([loaderName isEqualToString:@"neoforge"]) {
        dependencies[@"forge"] = loaderVersion;
    }

    NSMutableDictionary *info = [[ModpackUtils infoForDependencies:dependencies] mutableCopy];
    if (!info[@"id"]) {
        info[@"id"] = minecraftVersion;
    }
    return info;
}

- (NSDictionary *)fileForProjectID:(NSString *)projectID fileID:(NSString *)fileID {
    NSDictionary *response = [self getEndpoint:[NSString stringWithFormat:@"mods/%@/files/%@", projectID, fileID] params:nil];
    NSDictionary *file = [response isKindOfClass:NSDictionary.class] ? response[@"data"] : nil;
    return [file isKindOfClass:NSDictionary.class] ? file : nil;
}

- (NSDictionary<NSString *, NSDictionary *> *)filesByFileID:(NSArray *)fileIDs {
    NSMutableArray<NSNumber *> *uniqueFileIDs = [NSMutableArray new];
    NSMutableSet<NSString *> *seenFileIDs = [NSMutableSet new];
    for (id fileIDObject in fileIDs) {
        NSString *fileID = [fileIDObject description];
        if (fileID.length == 0 || [seenFileIDs containsObject:fileID]) {
            continue;
        }
        [seenFileIDs addObject:fileID];
        [uniqueFileIDs addObject:@(fileID.longLongValue)];
    }

    NSMutableDictionary<NSString *, NSDictionary *> *files = [NSMutableDictionary new];
    NSUInteger index = 0;
    while (index < uniqueFileIDs.count) {
        NSUInteger count = MIN((NSUInteger)50, uniqueFileIDs.count - index);
        NSArray *batch = [uniqueFileIDs subarrayWithRange:NSMakeRange(index, count)];
        NSDictionary *response = [self postEndpoint:@"mods/files" params:@{@"fileIds": batch}];
        NSArray *batchFiles = [response isKindOfClass:NSDictionary.class] && [response[@"data"] isKindOfClass:NSArray.class] ? response[@"data"] : @[];
        for (NSDictionary *file in batchFiles) {
            if (![file isKindOfClass:NSDictionary.class]) {
                continue;
            }
            NSString *fileID = [file[@"id"] description];
            if (fileID.length > 0) {
                files[fileID] = file;
            }
        }
        index += count;
    }
    return files;
}

- (void)downloader:(MinecraftResourceDownloadTask *)downloader submitDownloadTasksFromPackage:(NSString *)packagePath toPath:(NSString *)destPath {
    NSError *error;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:packagePath error:&error];
    if (error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to open CurseForge package: %@", error.localizedDescription]];
        return;
    }

    NSData *manifestData = [archive extractDataFromFile:@"manifest.json" error:&error];
    NSDictionary *manifest = manifestData ? [NSJSONSerialization JSONObjectWithData:manifestData options:kNilOptions error:&error] : nil;
    if (![manifest isKindOfClass:NSDictionary.class] || error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to parse CurseForge manifest.json: %@", error.localizedDescription ?: @"invalid manifest"]];
        return;
    }

    NSString *modsPath = [destPath stringByAppendingPathComponent:@"mods"];
    NSArray *manifestFiles = [manifest[@"files"] isKindOfClass:NSArray.class] ? manifest[@"files"] : @[];
    NSMutableArray<NSDictionary *> *requiredManifestFiles = [NSMutableArray new];
    NSMutableArray *requiredFileIDs = [NSMutableArray new];
    for (NSDictionary *manifestFile in manifestFiles) {
        if (![manifestFile isKindOfClass:NSDictionary.class]) {
            continue;
        }
        if (![manifestFile[@"required"] boolValue]) {
            continue;
        }
        id fileID = manifestFile[@"fileID"];
        if (!fileID) {
            continue;
        }
        [requiredManifestFiles addObject:manifestFile];
        [requiredFileIDs addObject:fileID];
    }

    NSDictionary<NSString *, NSDictionary *> *filesByID = [self filesByFileID:requiredFileIDs];
    for (NSDictionary *manifestFile in requiredManifestFiles) {
        NSString *projectID = [manifestFile[@"projectID"] description] ?: @"";
        NSString *fileID = [manifestFile[@"fileID"] description] ?: @"";
        NSDictionary *file = fileID.length > 0 ? filesByID[fileID] : nil;
        if (!file && projectID.length > 0 && fileID.length > 0) {
            file = [self fileForProjectID:projectID fileID:fileID];
        }
        NSString *url = file ? [self downloadURLForFile:file] : @"";
        NSString *fileName = [file[@"fileName"] isKindOfClass:NSString.class] ? file[@"fileName"] : @"";
        if (url.length == 0 || fileName.length == 0) {
            [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"CurseForge file %@/%@ is not downloadable.", projectID, fileID]];
            return;
        }
        NSString *path = [modsPath stringByAppendingPathComponent:fileName];
        NSURLSessionDownloadTask *task = [downloader createDownloadTask:url
            size:[file[@"fileLength"] unsignedLongLongValue]
            sha:[self sha1ForFile:file]
            altName:fileName
            toPath:path];
        if (task) {
            [task resume];
        } else if (downloader.progress.cancelled) {
            return;
        }
    }

    NSString *overrides = manifest[@"overrides"];
    if (![overrides isKindOfClass:NSString.class] || overrides.length == 0) {
        overrides = @"overrides";
    }
    [ModpackUtils archive:archive extractDirectory:overrides toPath:destPath error:&error];
    if (error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to extract overrides from CurseForge package: %@", error.localizedDescription]];
        return;
    }

    [NSFileManager.defaultManager removeItemAtPath:packagePath error:nil];

    NSDictionary *depInfo = [self modpackDependencyInfoFromManifest:manifest];
    if (depInfo[@"json"]) {
        NSString *jsonPath = [NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json", getenv("POJAV_GAME_DIR"), depInfo[@"id"]];
        NSURLSessionDownloadTask *task = [downloader createDownloadTask:depInfo[@"json"] size:0 sha:nil altName:nil toPath:jsonPath];
        [task resume];
    }

    NSString *profileName = manifest[@"name"] ?: destPath.lastPathComponent;
    NSString *tmpIconPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"icon.png"];
    PLProfiles.current.profiles[profileName] = @{
        @"gameDir": [NSString stringWithFormat:@"./custom_gamedir/%@", destPath.lastPathComponent],
        @"name": profileName,
        @"lastVersionId": depInfo[@"id"] ?: @"",
        @"icon": [NSString stringWithFormat:@"data:image/png;base64,%@",
            [[NSData dataWithContentsOfFile:tmpIconPath] base64EncodedStringWithOptions:0]]
    }.mutableCopy;
    PLProfiles.current.selectedProfileName = profileName;
}

@end
