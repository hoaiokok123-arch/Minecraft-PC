#import <UIKit/UIKit.h>

@interface ModpackInstallViewController : UITableViewController<UISearchResultsUpdating>
@property(nonatomic) NSString *projectType;
@property(nonatomic) NSString *sourceName;

- (instancetype)initWithProjectType:(NSString *)projectType;
- (instancetype)initWithProjectType:(NSString *)projectType sourceName:(NSString *)sourceName;
+ (NSString *)titleForProjectType:(NSString *)projectType;

@end
