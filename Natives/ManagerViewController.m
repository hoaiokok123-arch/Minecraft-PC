#import "ManagerViewController.h"
#import "ModManagerViewController.h"
#import "PLProfiles.h"
#import "UIImageView+AFNetworking.h"
#import "UIKit+hook.h"

@interface ManagerViewController ()
@property(nonatomic) NSArray<NSDictionary<NSString *, NSString *> *> *items;
@property(nonatomic) NSArray<NSMutableDictionary *> *profiles;
@property(nonatomic) NSMutableDictionary *profile;

- (instancetype)initWithProfile:(NSMutableDictionary *)profile;
@end

@implementation ManagerViewController

- (id)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        self.title = @"Manager";
        [self loadItems];
        [self reloadProfiles];
    }
    return self;
}

- (instancetype)initWithProfile:(NSMutableDictionary *)profile {
    self = [self init];
    self.profile = profile;
    self.title = profile[@"name"] ?: @"Manager";
    [self loadItems];
    return self;
}

- (NSString *)imageName {
    return @"gearshape";
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (self.profile == nil) {
        [PLProfiles updateCurrent];
        [self reloadProfiles];
        [self.tableView reloadData];
    }
}

- (void)loadItems {
    self.items = @[
        @{@"title": @"Mods", @"projectType": @"mod", @"imageName": @"puzzlepiece"},
        @{@"title": @"Plugins", @"projectType": @"plugin", @"imageName": @"powerplug"},
        @{@"title": @"Data Packs", @"projectType": @"datapack", @"imageName": @"shippingbox"},
        @{@"title": @"Shaders", @"projectType": @"shader", @"imageName": @"sun.max"},
        @{@"title": @"Resource Packs", @"projectType": @"resourcepack", @"imageName": @"paintpalette"},
        @{@"title": @"Servers", @"projectType": @"minecraft_java_server", @"imageName": @"server.rack"}
    ];
}

- (void)reloadProfiles {
    self.profiles = [PLProfiles.current.profiles.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSString *nameA = a[@"name"] ?: @"";
        NSString *nameB = b[@"name"] ?: @"";
        return [nameA localizedCaseInsensitiveCompare:nameB];
    }];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.profile ? self.items.count : self.profiles.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSString *identifier = self.profile ? @"managerCategory" : @"managerProfile";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (cell == nil) {
        UITableViewCellStyle style = self.profile ? UITableViewCellStyleDefault : UITableViewCellStyleSubtitle;
        cell = [[UITableViewCell alloc] initWithStyle:style reuseIdentifier:identifier];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.detailTextLabel.numberOfLines = 0;
    }

    if (self.profile) {
        NSDictionary *item = self.items[indexPath.row];
        cell.textLabel.text = item[@"title"];
        cell.detailTextLabel.text = nil;
        cell.imageView.image = [UIImage systemImageNamed:item[@"imageName"]];
    } else {
        NSMutableDictionary *profile = self.profiles[indexPath.row];
        cell.textLabel.text = profile[@"name"] ?: @"Profile";
        cell.detailTextLabel.text = profile[@"lastVersionId"];
        cell.imageView.layer.magnificationFilter = kCAFilterNearest;
        UIImage *fallbackImage = [[UIImage imageNamed:@"DefaultProfile"] _imageWithSize:CGSizeMake(40, 40)];
        NSString *icon = profile[@"icon"];
        NSURL *iconURL = icon.length > 0 ? [NSURL URLWithString:icon] : nil;
        [cell.imageView setImageWithURL:iconURL placeholderImage:fallbackImage];
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.profile == nil) {
        ManagerViewController *vc = [[ManagerViewController alloc] initWithProfile:self.profiles[indexPath.row]];
        vc.navigationItem.rightBarButtonItem = self.navigationItem.rightBarButtonItem;
        [self.navigationController pushViewController:vc animated:YES];
        return;
    }

    NSString *projectType = self.items[indexPath.row][@"projectType"];
    ModManagerViewController *vc = [[ModManagerViewController alloc] initWithProjectType:projectType profile:self.profile];
    vc.navigationItem.rightBarButtonItem = self.navigationItem.rightBarButtonItem;
    [self.navigationController pushViewController:vc animated:YES];
}

@end
