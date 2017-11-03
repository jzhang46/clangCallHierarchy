#import "b.h"
#import <Foundation/Foundation.h>

@interface A 
@end


@implementation A

- (void)f1 {
    B *b = [B alloc] initWith:nil];
    b.b1 = 5;
    [b f1];
    [B f2];
}


@end
