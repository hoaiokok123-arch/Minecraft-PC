#import <UIKit/UIKit.h>

@interface ModManagerViewController : UITableViewController

- (instancetype)initWithProjectType:(NSString *)projectType;
- (instancetype)initWithProjectType:(NSString *)projectType profile:(NSMutableDictionary *)profile;
- (NSString *)imageName;

@end
