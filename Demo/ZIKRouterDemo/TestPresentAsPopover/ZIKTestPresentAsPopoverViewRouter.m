//
//  ZIKTestPresentAsPopoverViewRouter.m
//  ZIKRouterDemo
//
//  Created by zuik on 2017/7/5.
//  Copyright © 2017 zuik. All rights reserved.
//

#import "ZIKTestPresentAsPopoverViewRouter.h"
#import "ZIKTestPresentAsPopoverViewController.h"

@interface ZIKTestPresentAsPopoverViewController (ZIKTestPresentAsPopoverViewRouter) <ZIKRoutableView>
@end
@implementation ZIKTestPresentAsPopoverViewController (ZIKTestPresentAsPopoverViewRouter)
@end

@implementation ZIKTestPresentAsPopoverViewRouter

+ (void)registerRoutableDestination {
    ZIKViewRouter_registerView([ZIKTestPresentAsPopoverViewController class], self);
}

- (id)destinationWithConfiguration:(__kindof ZIKRouteConfiguration *)configuration {
    UIStoryboard *sb = [UIStoryboard storyboardWithName:@"Main" bundle:nil];
    ZIKTestPresentAsPopoverViewController *destination = [sb instantiateViewControllerWithIdentifier:@"testPresentAsPopover"];;
    destination.title = @"Test PresentAsPopover";
    return destination;
}

@end
