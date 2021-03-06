//
//  ZIKViewConfigRoutable.h
//  ZIKRouter
//
//  Created by zuik on 2017/8/21.
//  Copyright © 2017 zuik. All rights reserved.
//
//  This source code is licensed under the MIT-style license found in the
//  LICENSE file in the root directory of this source tree.
//

#import <Foundation/Foundation.h>

/**
 Protocol inheriting from ZIKViewConfigRoutable can be used to fetch view router with ZIKViewRouterForConfig()
 @discussion
 ZIKViewConfigRoutable is for:
 1. Let module declaring routable protocol in header
 1. Checking declared protocol is correctly supported in it's view router
 
 It's safe to use protocols inheriting from ZIKViewConfigRoutable with ZIKViewRouterForConfig() and won't get nil. ZIKViewRouter will validate all ZIKViewConfigRoutable protocols and registered protocols when app launch and ZIKVIEWROUTER_CHECK is enbled. When ZIKVIEWROUTER_CHECK is disabled, the protocol doesn't need to inheriting from ZIKViewConfigRoutable.
 */
@protocol ZIKViewConfigRoutable <NSObject>

@end
