//
//  UIStoryboardSegue+ZIKViewRouterPrivate.m
//  ZIKRouter
//
//  Created by zuik on 2017/9/18.
//  Copyright © 2017 zuik. All rights reserved.
//
//  This source code is licensed under the MIT-style license found in the
//  LICENSE file in the root directory of this source tree.
//

#import "UIStoryboardSegue+ZIKViewRouterPrivate.h"
#import <objc/runtime.h>

@implementation UIStoryboardSegue (ZIKViewRouterPrivate)
- (nullable Class)ZIK_currentClassCallingPerform {
    return objc_getAssociatedObject(self, "ZIK_CurrentClassCallingPerform");
}
- (void)setZIK_currentClassCallingPerform:(nullable Class)vcClass {
    objc_setAssociatedObject(self, "ZIK_CurrentClassCallingPerform", vcClass, OBJC_ASSOCIATION_RETAIN);
}
@end
