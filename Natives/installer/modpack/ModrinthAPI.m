#import "AFNetworking.h"
#import "MinecraftResourceDownloadTask.h"
#import "ModrinthAPI.h"
#import "PLProfiles.h"

@implementation ModrinthAPI

- (instancetype)init {
    return [super initWithURL:@"https://api.modrinth.com/v2"];
}

- (NSString *)modrinthProjectTypeForProjectType:(NSString *)projectType {
    if ([projectType isEqualToString:@"minecraft_java_server"]) {
        return @"mod";
    }
    return projectType.length > 0 ? projectType : @"modpack";
}

- (NSArray<NSArray<NSString *> *> *)extraFacetsForProjectType:(NSString *)projectType {
    if ([projectType isEqualToString:@"minecraft_java_server"]) {
        return @[@[@"server_side:required"]];
    }
    return @[];
}

- (NSString *)facetStringForSearchFilters:(NSDictionary<NSString *, NSString *> *)searchFilters projectType:(NSString *)projectType {
    NSMutableArray<NSArray<NSString *> *> *facets = [NSMutableArray new];
    NSString *modrinthProjectType = [self modrinthProjectTypeForProjectType:projectType];
    [facets addObject:@[[NSString stringWithFormat:@"project_type:%@", modrinthProjectType]]];
    [facets addObjectsFromArray:[self extraFacetsForProjectType:projectType]];
    if (searchFilters[@"mcVersion"].length > 0) {
        [facets addObject:@[[NSString stringWithFormat:@"versions:%@", searchFilters[@"mcVersion"]]]];
    }

    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:facets options:0 error:nil];
    return [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding] ?: @"[]";
}

- (NSArray<NSString *> *)preferredFileExtensionsForProjectType:(NSString *)projectType {
    if ([projectType isEqualToString:@"shader"] ||
        [projectType isEqualToString:@"resourcepack"] ||
        [projectType isEqualToString:@"datapack"]) {
        return @[@"zip"];
    }
    if ([projectType isEqualToString:@"mod"] ||
        [projectType isEqualToString:@"plugin"] ||
        [projectType isEqualToString:@"minecraft_java_server"]) {
        return @[@"jar"];
    }
    return @[];
}

- (BOOL)file:(NSDictionary *)file matchesExtensions:(NSArray<NSString *> *)extensions {
    NSString *fileName = [file[@"filename"] isKindOfClass:NSString.class] ? file[@"filename"] : [file[@"url"] lastPathComponent];
    NSString *extension = fileName.pathExtension.lowercaseString;
    return extension.length > 0 && [extensions containsObject:extension];
}

- (NSDictionary *)preferredFileFromFiles:(NSArray<NSDictionary *> *)files projectType:(NSString *)projectType {
    NSArray<NSString *> *extensions = [self preferredFileExtensionsForProjectType:projectType];
    NSDictionary *primary = nil;
    NSDictionary *firstMatching = nil;
    for (NSDictionary *candidate in files) {
        if (![candidate isKindOfClass:NSDictionary.class]) {
            continue;
        }
        BOOL matches = extensions.count == 0 || [self file:candidate matchesExtensions:extensions];
        if (!firstMatching && matches) {
            firstMatching = candidate;
        }
        if ([candidate[@"primary"] boolValue]) {
            primary = candidate;
            if (matches) {
                return candidate;
            }
        }
    }
    id fallback = files.firstObject;
    return firstMatching ?: primary ?: ([fallback isKindOfClass:NSDictionary.class] ? fallback : nil);
}

- (id)postEndpoint:(NSString *)endpoint params:(NSDictionary *)params {
    __block id result;
    dispatch_group_t group = dispatch_group_create();
    dispatch_group_enter(group);
    NSString *url = [self.baseURL stringByAppendingPathComponent:endpoint];
    AFHTTPSessionManager *manager = [AFHTTPSessionManager manager];
    manager.requestSerializer = [AFJSONRequestSerializer serializer];
    [manager POST:url parameters:params headers:nil progress:nil
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

- (NSMutableDictionary *)projectForFileHash:(NSString *)sha1 projectType:(NSString *)projectType {
    if (sha1.length == 0) {
        return nil;
    }

    NSDictionary *versions = [self postEndpoint:@"version_files" params:@{
        @"hashes": @[sha1],
        @"algorithm": @"sha1"
    }];
    NSDictionary *version = [versions isKindOfClass:NSDictionary.class] ? versions[sha1] : nil;
    if (![version isKindOfClass:NSDictionary.class]) {
        return nil;
    }

    NSString *projectId = version[@"project_id"];
    if (![projectId isKindOfClass:NSString.class] || projectId.length == 0) {
        return nil;
    }

    NSDictionary *projectResponse = [self getEndpoint:[NSString stringWithFormat:@"project/%@", projectId] params:nil];
    NSDictionary *project = [projectResponse isKindOfClass:NSDictionary.class] ? projectResponse : @{};
    NSString *hitProjectType = [project[@"project_type"] isKindOfClass:NSString.class] ? project[@"project_type"] : @"";
    NSString *effectiveProjectType = projectType.length > 0 ? projectType : (hitProjectType.length > 0 ? hitProjectType : @"mod");
    id imageUrl = project[@"featured_gallery"];
    if (![imageUrl isKindOfClass:NSString.class] || [imageUrl length] == 0) {
        imageUrl = project[@"icon_url"];
    }
    if (![imageUrl isKindOfClass:NSString.class] || [imageUrl length] == 0) {
        imageUrl = @"";
    }

    return @{
        @"apiSource": @(1),
        @"isModpack": @([effectiveProjectType isEqualToString:@"modpack"] || [hitProjectType isEqualToString:@"modpack"]),
        @"projectType": effectiveProjectType,
        @"modrinthProjectType": hitProjectType.length > 0 ? hitProjectType : effectiveProjectType,
        @"id": projectId,
        @"title": project[@"title"] ?: version[@"name"] ?: projectId,
        @"description": project[@"description"] ?: @"",
        @"imageUrl": imageUrl,
        @"matchedVersionId": version[@"id"] ?: @"",
        @"matchedFileHash": sha1
    }.mutableCopy;
}

- (NSMutableArray *)searchModWithFilters:(NSDictionary<NSString *, NSString *> *)searchFilters previousPageResult:(NSMutableArray *)modrinthSearchResult {
    int limit = 50;
    NSString *projectType = searchFilters[@"projectType"];
    if (projectType.length == 0) {
        projectType = searchFilters[@"isModpack"] ? (searchFilters[@"isModpack"].boolValue ? @"modpack" : @"mod") : @"modpack";
    }

    NSString *query = searchFilters[@"name"] ?: @"";
    NSDictionary *params = @{
        @"facets": [self facetStringForSearchFilters:searchFilters projectType:projectType],
        @"query": [query stringByReplacingOccurrencesOfString:@" " withString:@"+"],
        @"limit": @(limit),
        @"index": @"relevance",
        @"offset": @(modrinthSearchResult.count)
    };
    NSDictionary *response = [self getEndpoint:@"search" params:params];
    if (!response) {
        return nil;
    }

    NSMutableArray *result = modrinthSearchResult ?: [NSMutableArray new];
    for (NSDictionary *hit in response[@"hits"]) {
        NSString *hitProjectType = hit[@"project_type"];
        if (![hitProjectType isKindOfClass:NSString.class] || hitProjectType.length == 0) {
            hitProjectType = projectType;
        }
        BOOL isModpack = [projectType isEqualToString:@"modpack"] || [hitProjectType isEqualToString:@"modpack"];
        id imageUrl = hit[@"featured_gallery"];
        if (![imageUrl isKindOfClass:NSString.class] || [imageUrl length] == 0) {
            imageUrl = hit[@"icon_url"];
        }
        if (![imageUrl isKindOfClass:NSString.class] || [imageUrl length] == 0) {
            imageUrl = @"";
        }
        [result addObject:@{
            @"apiSource": @(1), // Constant MODRINTH
            @"isModpack": @(isModpack),
            @"projectType": projectType,
            @"modrinthProjectType": hitProjectType,
            @"id": hit[@"project_id"] ?: @"",
            @"title": hit[@"title"] ?: @"",
            @"description": hit[@"description"] ?: @"",
            @"imageUrl": imageUrl
        }.mutableCopy];
    }
    self.reachedLastPage = result.count >= [response[@"total_hits"] unsignedLongValue];
    return result;
}

- (void)loadDetailsOfMod:(NSMutableDictionary *)item {
    NSArray *response = [self getEndpoint:[NSString stringWithFormat:@"project/%@/version", item[@"id"]] params:nil];
    if (!response) {
        return;
    }
    NSMutableArray<NSString *> *names = [NSMutableArray new];
    NSMutableArray<NSString *> *mcNames = [NSMutableArray new];
    NSMutableArray<NSString *> *urls = [NSMutableArray new];
    NSMutableArray<NSString *> *hashes = [NSMutableArray new];
    NSMutableArray<NSString *> *sizes = [NSMutableArray new];
    NSMutableArray<NSString *> *fileNames = [NSMutableArray new];
    NSMutableArray<NSString *> *fileTypes = [NSMutableArray new];
    [response enumerateObjectsUsingBlock:
  ^(NSDictionary *version, NSUInteger i, BOOL *stop) {
        NSArray *versionFiles = [version[@"files"] isKindOfClass:NSArray.class] ? version[@"files"] : @[];
        NSDictionary *file = [self preferredFileFromFiles:versionFiles projectType:item[@"projectType"]];
        if (![file[@"url"] isKindOfClass:NSString.class]) {
            return;
        }

        NSString *name = version[@"name"];
        if (![name isKindOfClass:NSString.class] || name.length == 0) {
            name = version[@"version_number"];
        }
        if (![name isKindOfClass:NSString.class] || name.length == 0) {
            name = file[@"filename"];
        }
        NSString *mcVersion = [version[@"game_versions"] firstObject] ?: @"";
        NSString *loader = [version[@"loaders"] firstObject] ?: @"";
        if (loader.length > 0 && mcVersion.length > 0) {
            mcVersion = [NSString stringWithFormat:@"%@/%@", mcVersion, loader];
        }
        [names addObject:name ?: @"Download"];
        [mcNames addObject:mcVersion];
        [sizes addObject:file[@"size"] ?: @0];
        [urls addObject:file[@"url"]];
        NSDictionary *hashesMap = file[@"hashes"];
        [hashes addObject:hashesMap[@"sha1"] ?: @""];
        NSString *fileName = file[@"filename"];
        if (![fileName isKindOfClass:NSString.class] || fileName.length == 0) {
            fileName = [file[@"url"] lastPathComponent];
        }
        [fileNames addObject:fileName ?: @"download"];
        id fileType = file[@"file_type"];
        [fileTypes addObject:[fileType isKindOfClass:NSString.class] ? fileType : @""];
    }];
    if (names.count == 0) {
        self.lastError = [NSError errorWithDomain:@"ModrinthAPI"
            code:404
            userInfo:@{NSLocalizedDescriptionKey: @"No downloadable files were found for this project."}];
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

- (void)downloader:(MinecraftResourceDownloadTask *)downloader submitDownloadTasksFromPackage:(NSString *)packagePath toPath:(NSString *)destPath {
    NSError *error;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:packagePath error:&error];
    if (error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to open modpack package: %@", error.localizedDescription]];
        return;
    }

    NSData *indexData = [archive extractDataFromFile:@"modrinth.index.json" error:&error];
    NSDictionary* indexDict = [NSJSONSerialization JSONObjectWithData:indexData options:kNilOptions error:&error];
    if (error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to parse modrinth.index.json: %@", error.localizedDescription]];
        return;
    }

    for (NSDictionary *indexFile in indexDict[@"files"]) {
/*
        if ([indexFile[@"downloads"] count] > 1) {
            [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Unhandled multiple files download %@", indexFile[@"downloads"]]];
            return;
        }
*/
        NSString *url = [indexFile[@"downloads"] firstObject];
        NSString *sha = indexFile[@"hashes"][@"sha1"];
        NSString *path = [destPath stringByAppendingPathComponent:indexFile[@"path"]];
        NSUInteger size = [indexFile[@"fileSize"] unsignedLongLongValue];
        NSURLSessionDownloadTask *task = [downloader createDownloadTask:url size:size sha:sha altName:nil toPath:path];
        if (task) {
            [downloader.fileList addObject:indexFile[@"path"]];
            [task resume];
        } else if (downloader.progress.cancelled) {
            return; // cancelled
        }
    }

    [ModpackUtils archive:archive extractDirectory:@"overrides" toPath:destPath error:&error];
    if (error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to extract overrides from modpack package: %@", error.localizedDescription]];
        return;
    }

    [ModpackUtils archive:archive extractDirectory:@"client-overrides" toPath:destPath error:&error];
    if (error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to extract client-overrides from modpack package: %@", error.localizedDescription]];
        return;
    }

    // Delete package cache
    [NSFileManager.defaultManager removeItemAtPath:packagePath error:nil];

    // Download dependency client json (if available)
    NSDictionary<NSString *, NSString *> *depInfo = [ModpackUtils infoForDependencies:indexDict[@"dependencies"]];
    if (depInfo[@"json"]) {
        NSString *jsonPath = [NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json", getenv("POJAV_GAME_DIR"), depInfo[@"id"]];
        NSURLSessionDownloadTask *task = [downloader createDownloadTask:depInfo[@"json"] size:0 sha:nil altName:nil toPath:jsonPath];
        [task resume];
    }
    // TODO: automation for Forge

    // Create profile
    NSString *tmpIconPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"icon.png"];
    PLProfiles.current.profiles[indexDict[@"name"]] = @{
        @"gameDir": [NSString stringWithFormat:@"./custom_gamedir/%@", destPath.lastPathComponent],
        @"name": indexDict[@"name"],
        @"lastVersionId": depInfo[@"id"],
        @"icon": [NSString stringWithFormat:@"data:image/png;base64,%@",
            [[NSData dataWithContentsOfFile:tmpIconPath]
            base64EncodedStringWithOptions:0]]
    }.mutableCopy;
    PLProfiles.current.selectedProfileName = indexDict[@"name"];
}

@end
