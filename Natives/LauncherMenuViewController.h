#import <UIKit/UIKit.h>

#define sidebarNavController ((UINavigationController *)self.splitViewController.viewControllers[0])
#define sidebarViewController ((LauncherMenuViewController *)sidebarNavController.viewControllers[0])

@interface LauncherMenuCustomItem : NSObject
@property(nonatomic) NSString *title, *imageName;
@property(nonatomic, copy) void (^action)(void);
@property(nonatomic) NSArray<UIViewController *> *vcArray;

+ (LauncherMenuCustomItem *)title:(NSString *)title imageName:(NSString *)imageName action:(id)action;
+ (LauncherMenuCustomItem *)vcClass:(Class)class;
+ (LauncherMenuCustomItem *)vc:(UIViewController *)vc;
@end

@interface LauncherMenuViewController : UITableViewController

@property NSString* listPath;
@property(nonatomic) UIButton *accountButton;
@property(nonatomic) UIBarButtonItem *accountBtnItem;
@property(nonatomic) BOOL isInitialVc;

- (void)restoreHighlightedSelection;
- (void)selectAccount:(UIButton *)sender;
- (void)updateAccountInfo;
- (UIBarButtonItem *)drawAccountButton;

@end
