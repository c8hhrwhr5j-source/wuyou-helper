//
//  TSPaths.m
//  TrollAutoTouch
//

#import "TSPaths.h"
#import <sys/stat.h>

@implementation TSPaths

+ (NSString *)rootDir {
    return @"/var/mobile/touch";
}

+ (NSString *)luaDir {
    return [@"/var/mobile/touch" stringByAppendingPathComponent:@"lua"];
}

+ (NSString *)logDir {
    return [@"/var/mobile/touch" stringByAppendingPathComponent:@"log"];
}

+ (NSString *)resDir {
    return [@"/var/mobile/touch" stringByAppendingPathComponent:@"res"];
}

+ (NSString *)runtimeDir {
    return [@"/var/mobile/touch" stringByAppendingPathComponent:@"runtime"];
}

+ (void)ensureDirectoriesExist {
    NSArray *dirs = @[ self.rootDir, self.luaDir, self.logDir, self.resDir, self.runtimeDir ];
    for (NSString *d in dirs) {
        struct stat st;
        if (stat(d.UTF8String, &st) != 0) {
            mkdir(d.UTF8String, 0755);
        }
    }
}

+ (NSString *)pathForLua:(NSString *)name {
    return [self.luaDir stringByAppendingPathComponent:name];
}

+ (NSString *)pathForLog:(NSString *)name {
    return [self.logDir stringByAppendingPathComponent:name];
}

+ (NSString *)pathForRes:(NSString *)name {
    return [self.resDir stringByAppendingPathComponent:name];
}

@end

#pragma mark - Colors

@implementation TSColors

+ (UIColor *)bg            { return [UIColor colorWithRed:0.949 green:0.949 blue:0.969 alpha:1.0]; } // #F2F2F7
+ (UIColor *)card          { return [UIColor whiteColor]; }                                            // #FFFFFF
+ (UIColor *)separator     { return [UIColor colorWithRed:0.776 green:0.776 blue:0.784 alpha:1.0]; } // #C6C6C8
+ (UIColor *)label         { return [UIColor colorWithRed:0.110 green:0.110 blue:0.118 alpha:1.0]; } // #1C1C1E
+ (UIColor *)secondaryLabel{ return [UIColor colorWithRed:0.235 green:0.235 blue:0.263 alpha:1.0]; } // #3C3C43
+ (UIColor *)tertiaryLabel { return [UIColor colorWithRed:0.557 green:0.557 blue:0.576 alpha:1.0]; } // #8E8E93
+ (UIColor *)tint          { return [UIColor colorWithRed:0.000 green:0.478 blue:1.000 alpha:1.0]; } // #007AFF
+ (UIColor *)switchOn      { return [UIColor colorWithRed:0.204 green:0.780 blue:0.349 alpha:1.0]; } // #34C759
+ (UIColor *)danger        { return [UIColor colorWithRed:1.000 green:0.231 blue:0.188 alpha:1.0]; } // #FF3B30
+ (UIColor *)warning       { return [UIColor colorWithRed:1.000 green:0.584 blue:0.000 alpha:1.0]; } // #FF9500
+ (UIColor *)success       { return [UIColor colorWithRed:0.204 green:0.780 blue:0.349 alpha:1.0]; } // #34C759
+ (UIColor *)info          { return [UIColor colorWithRed:0.000 green:0.478 blue:1.000 alpha:1.0]; } // #007AFF

@end