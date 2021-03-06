//
//  ZIKServiceRouter.m
//  ZIKRouter
//
//  Created by zuik on 2017/8/9.
//  Copyright © 2017 zuik. All rights reserved.
//
//  This source code is licensed under the MIT-style license found in the
//  LICENSE file in the root directory of this source tree.
//

#import "ZIKServiceRouter.h"
#import "ZIKRouterInternal.h"
#import <objc/runtime.h>
#import <UIKit/UIKit.h>
#import "ZIKRouterRuntimeHelper.h"


NSString *const kZIKServiceRouterErrorDomain = @"ZIKServiceRouterErrorDomain";

static BOOL _assert_isLoadFinished = NO;

static CFMutableDictionaryRef g_serviceProtocolToRouterMap;
static CFMutableDictionaryRef g_configProtocolToRouterMap;
static CFMutableDictionaryRef g_serviceToRoutersMap;
static CFMutableDictionaryRef g_serviceToDefaultRouterMap;
static CFMutableDictionaryRef g_serviceToExclusiveRouterMap;
#if ZIKSERVICEROUTER_CHECK
static CFMutableDictionaryRef _check_routerToServicesMap;
static NSArray<Class> *g_routableServices;
#endif

static ZIKServiceRouteGlobalErrorHandler g_globalErrorHandler;
static dispatch_semaphore_t g_globalErrorSema;

@interface ZIKServiceRouter () <ZIKRouterProtocol>

@end

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation" 
#pragma clang diagnostic ignored "-Wobjc-designated-initializers"

@implementation ZIKServiceRouter

#pragma clang diagnostic pop

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        ZIKRouter_replaceMethodWithMethod([UIApplication class], @selector(setDelegate:),
                                          self, @selector(ZIKServiceRouter_hook_setDelegate:));
        ZIKRouter_replaceMethodWithMethodType([UIStoryboard class], @selector(storyboardWithName:bundle:), true, self, @selector(ZIKServiceRouter_hook_storyboardWithName:bundle:), true);
    });
}

+ (void)setup {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _initializeZIKServiceRouter();
    });
}

+ (void)ZIKServiceRouter_hook_setDelegate:(id<UIApplicationDelegate>)delegate {
    [ZIKServiceRouter setup];
    [self ZIKServiceRouter_hook_setDelegate:delegate];
}

+ (UIStoryboard *)ZIKServiceRouter_hook_storyboardWithName:(NSString *)name bundle:(nullable NSBundle *)storyboardBundleOrNil {
    [ZIKServiceRouter setup];
    return [self ZIKServiceRouter_hook_storyboardWithName:name bundle:storyboardBundleOrNil];
}

void _initializeZIKServiceRouter() {
    g_globalErrorSema = dispatch_semaphore_create(1);
    if (!g_serviceProtocolToRouterMap) {
        g_serviceProtocolToRouterMap = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, NULL, NULL);
    }
    if (!g_configProtocolToRouterMap) {
        g_configProtocolToRouterMap = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, NULL, NULL);
    }
#if ZIKSERVICEROUTER_CHECK
    NSMutableArray *routableServices = [NSMutableArray array];
    if (!_check_routerToServicesMap) {
        _check_routerToServicesMap = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, NULL, &kCFTypeDictionaryValueCallBacks);
    }
#endif
    ZIKRouter_enumerateClassList(^(__unsafe_unretained Class class) {
#if ZIKSERVICEROUTER_CHECK
        if (class_conformsToProtocol(class, @protocol(ZIKRoutableService))) {
            [routableServices addObject:class];
        }
#endif
        if (ZIKRouter_classIsSubclassOfClass(class, [ZIKServiceRouter class])) {
            IMP registerIMP = class_getMethodImplementation(objc_getMetaClass(class_getName(class)), @selector(registerRoutableDestination));
            NSCAssert2(registerIMP, @"Router(%@) must implement +registerRoutableDestination to register destination with %@",class,class);
            void(*registerFunc)(Class, SEL) = (void(*)(Class,SEL))registerIMP;
            if (registerFunc) {
                registerFunc(class,@selector(registerRoutableDestination));
            }
#if ZIKSERVICEROUTER_CHECK
            CFMutableSetRef services = (CFMutableSetRef)CFDictionaryGetValue(_check_routerToServicesMap, (__bridge const void *)(class));
            NSSet *serviceSet = (__bridge NSSet *)(services);
            NSCAssert2(serviceSet.count > 0 || ZIKRouter_classIsSubclassOfClass(class, NSClassFromString(@"ZIKServiceRouteAdapter")) || class == NSClassFromString(@"ZIKServiceRouteAdapter"), @"This router class(%@) was not resgistered with any service class. Use ZIKViewRouter_registerService() to register service in Router(%@)'s +registerRoutableDestination.",class,class);
#endif
        }
    });
#if ZIKSERVICEROUTER_CHECK
    g_routableServices = routableServices;
    
    ZIKRouter_enumerateProtocolList(^(Protocol *protocol) {
        if (protocol_conformsToProtocol(protocol, @protocol(ZIKServiceRoutable)) &&
            protocol != @protocol(ZIKServiceRoutable)) {
            Class routerClass = (Class)CFDictionaryGetValue(g_serviceProtocolToRouterMap, (__bridge const void *)(protocol));
            NSCAssert1(routerClass, @"Declared service protocol(%@) is not registered with any router class!",NSStringFromProtocol(protocol));
            
            CFSetRef servicesRef = CFDictionaryGetValue(_check_routerToServicesMap, (__bridge const void *)(routerClass));
            NSSet *services = (__bridge NSSet *)(servicesRef);
            NSCAssert1(services.count > 0, @"Router(%@) didn't registered with any serviceClass", routerClass);
            for (Class serviceClass in services) {
                NSCAssert3([serviceClass conformsToProtocol:protocol], @"Router(%@)'s serviceClass(%@) should conform to registered protocol(%@)",routerClass, serviceClass, NSStringFromProtocol(protocol));
            }
        } else if (protocol_conformsToProtocol(protocol, @protocol(ZIKServiceConfigRoutable)) &&
                   protocol != @protocol(ZIKServiceConfigRoutable)) {
            Class routerClass = (Class)CFDictionaryGetValue(g_configProtocolToRouterMap, (__bridge const void *)(protocol));
            NSCAssert1(routerClass, @"Declared service config protocol(%@) is not registered with any router class!",NSStringFromProtocol(protocol));
            ZIKRouteConfiguration *config = [routerClass defaultRouteConfiguration];
            NSCAssert3([config conformsToProtocol:protocol], @"Router(%@)'s default ZIKRouteConfiguration(%@) should conform to registered config protocol(%@)",routerClass, [config class], NSStringFromProtocol(protocol));
        }
    });
#endif
    
    _assert_isLoadFinished = YES;
}

#pragma mark Dynamic Discover

extern void ZIKServiceRouter_registerService(Class serviceClass, Class routerClass) {
    NSCParameterAssert(serviceClass);
    NSCParameterAssert([serviceClass conformsToProtocol:@protocol(ZIKRoutableService)]);
    NSCParameterAssert([routerClass isSubclassOfClass:[ZIKServiceRouter class]]);
    NSCAssert(!_assert_isLoadFinished, @"Only register in +load.");
    NSCAssert([NSThread isMainThread], @"Call in main thread for thread safety.");
    
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (!g_serviceToDefaultRouterMap) {
            g_serviceToDefaultRouterMap = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, NULL, NULL);
        }
        if (!g_serviceToRoutersMap) {
            g_serviceToRoutersMap = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, NULL, &kCFTypeDictionaryValueCallBacks);
        }
#if ZIKSERVICEROUTER_CHECK
        if (!_check_routerToServicesMap) {
            _check_routerToServicesMap = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, NULL, &kCFTypeDictionaryValueCallBacks);
        }
#endif
    });
    NSCAssert(!g_serviceToExclusiveRouterMap ||
              (g_serviceToExclusiveRouterMap && !CFDictionaryGetValue(g_serviceToExclusiveRouterMap, (__bridge const void *)(serviceClass))), @"There is a registered exclusive router, can't use another router for this serviceClass.");
    
    if (!CFDictionaryContainsKey(g_serviceToDefaultRouterMap, (__bridge const void *)(serviceClass))) {
        CFDictionarySetValue(g_serviceToDefaultRouterMap, (__bridge const void *)(serviceClass), (__bridge const void *)(routerClass));
    }
    CFMutableSetRef routers = (CFMutableSetRef)CFDictionaryGetValue(g_serviceToRoutersMap, (__bridge const void *)(serviceClass));
    if (routers == NULL) {
        routers = CFSetCreateMutable(kCFAllocatorDefault, 0, NULL);
        CFDictionarySetValue(g_serviceToRoutersMap, (__bridge const void *)(serviceClass), routers);
    }
    CFSetAddValue(routers, (__bridge const void *)(routerClass));
    
#if ZIKSERVICEROUTER_CHECK
    CFMutableSetRef services = (CFMutableSetRef)CFDictionaryGetValue(_check_routerToServicesMap, (__bridge const void *)(routerClass));
    if (services == NULL) {
        services = CFSetCreateMutable(kCFAllocatorDefault, 0, NULL);
        CFDictionarySetValue(_check_routerToServicesMap, (__bridge const void *)(routerClass), services);
    }
    CFSetAddValue(services, (__bridge const void *)(serviceClass));
#endif
}

extern void ZIKServiceRouter_registerServiceForExclusiveRouter(Class serviceClass, Class routerClass) {
    NSCParameterAssert([serviceClass conformsToProtocol:@protocol(ZIKRoutableService)]);
    NSCParameterAssert([routerClass isSubclassOfClass:[ZIKServiceRouter class]]);
    NSCAssert(!_assert_isLoadFinished, @"Only register in +load.");
    NSCAssert([NSThread isMainThread], @"Call in main thread for thread safety.");
    
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (!g_serviceToExclusiveRouterMap) {
            g_serviceToExclusiveRouterMap = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, NULL, NULL);
        }
        if (!g_serviceToDefaultRouterMap) {
            g_serviceToDefaultRouterMap = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, NULL, NULL);
        }
        if (!g_serviceToRoutersMap) {
            g_serviceToRoutersMap = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, NULL, &kCFTypeDictionaryValueCallBacks);
        }
#if ZIKSERVICEROUTER_CHECK
        if (!_check_routerToServicesMap) {
            _check_routerToServicesMap = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, NULL, &kCFTypeDictionaryValueCallBacks);
        }
#endif
    });
    NSCAssert(!CFDictionaryGetValue(g_serviceToExclusiveRouterMap, (__bridge const void *)(serviceClass)), @"There is already a registered exclusive router for this serviceClass, you can only specific one exclusive router for each serviceClass. Choose the one used inside service.");
    NSCAssert(!CFDictionaryGetValue(g_serviceToDefaultRouterMap, (__bridge const void *)(serviceClass)), @"serviceClass already registered with another router by ZIKServiceRouter_registerService(), check and remove them. You shall only use the exclusive router for this serviceClass.");
    NSCAssert(!CFDictionaryContainsKey(g_serviceToRoutersMap, (__bridge const void *)(serviceClass)) ||
              (CFDictionaryContainsKey(g_serviceToRoutersMap, (__bridge const void *)(serviceClass)) &&
               !CFSetContainsValue(
                                   (CFMutableSetRef)CFDictionaryGetValue(g_serviceToRoutersMap, (__bridge const void *)(serviceClass)),
                                   (__bridge const void *)(routerClass)
                                   ))
              , @"serviceClass already registered with another router, check and remove them. You shall only use the exclusive router for this serviceClass.");
    
    CFDictionarySetValue(g_serviceToExclusiveRouterMap, (__bridge const void *)(serviceClass), (__bridge const void *)(routerClass));
    CFDictionarySetValue(g_serviceToDefaultRouterMap, (__bridge const void *)(serviceClass), (__bridge const void *)(routerClass));
    CFMutableSetRef routers = (CFMutableSetRef)CFDictionaryGetValue(g_serviceToRoutersMap, (__bridge const void *)(serviceClass));
    if (routers == NULL) {
        routers = CFSetCreateMutable(kCFAllocatorDefault, 0, NULL);
        CFDictionarySetValue(g_serviceToRoutersMap, (__bridge const void *)(serviceClass), routers);
    }
    CFSetAddValue(routers, (__bridge const void *)(routerClass));
    
#if ZIKSERVICEROUTER_CHECK
    CFMutableSetRef services = (CFMutableSetRef)CFDictionaryGetValue(_check_routerToServicesMap, (__bridge const void *)(routerClass));
    if (services == NULL) {
        services = CFSetCreateMutable(kCFAllocatorDefault, 0, NULL);
        CFDictionarySetValue(_check_routerToServicesMap, (__bridge const void *)(routerClass), services);
    }
    CFSetAddValue(services, (__bridge const void *)(serviceClass));
#endif
}

void ZIKServiceRouter_registerServiceProtocol(Protocol *serviceProtocol, Class routerClass) {
    NSCParameterAssert([routerClass isSubclassOfClass:[ZIKServiceRouter class]]);
    NSCAssert(!_assert_isLoadFinished, @"Only register in +load.");
    NSCAssert([NSThread isMainThread], @"Call in main thread for thread safety.");
    
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (!g_serviceProtocolToRouterMap) {
            g_serviceProtocolToRouterMap = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, NULL, NULL);
        }
    });
    NSCAssert(!CFDictionaryGetValue(g_serviceProtocolToRouterMap, (__bridge const void *)(serviceProtocol)) ||
              (Class)CFDictionaryGetValue(g_serviceProtocolToRouterMap, (__bridge const void *)(serviceProtocol)) == routerClass
              , @"Protocol already registered by another router, serviceProtocol should only be used by this routerClass.");
    
    CFDictionarySetValue(g_serviceProtocolToRouterMap, (__bridge const void *)(serviceProtocol), (__bridge const void *)(routerClass));
}

extern void ZIKServiceRouter_registerConfigProtocol(Protocol *configProtocol, Class routerClass) {
    NSCParameterAssert([routerClass isSubclassOfClass:[ZIKServiceRouter class]]);
    NSCAssert([[routerClass defaultRouteConfiguration] conformsToProtocol:configProtocol], @"configProtocol should be conformed by this router's defaultRouteConfiguration.");
    NSCAssert(!_assert_isLoadFinished, @"Only register in +load.");
    NSCAssert([NSThread isMainThread], @"Call in main thread for thread safety.");
    
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (!g_configProtocolToRouterMap) {
            g_configProtocolToRouterMap = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, NULL, NULL);
        }
    });
    NSCAssert(!CFDictionaryGetValue(g_configProtocolToRouterMap, (__bridge const void *)(configProtocol)) ||
              (Class)CFDictionaryGetValue(g_configProtocolToRouterMap, (__bridge const void *)(configProtocol)) == routerClass
              , @"Protocol already registered by another router, configProtocol should only be used by this routerClass.");
    
    CFDictionarySetValue(g_configProtocolToRouterMap, (__bridge const void *)(configProtocol), (__bridge const void *)(routerClass));
}


_Nullable Class ZIKServiceRouterForService(Protocol *serviceProtocol) {
    NSCParameterAssert(serviceProtocol);
    NSCAssert(g_serviceProtocolToRouterMap, @"Didn't register any protocol yet.");
    NSCAssert(_assert_isLoadFinished, @"Only get router after app did finish launch.");
#if ZIKSERVICEROUTER_CHECK
    NSCAssert(g_routableServices, @"g_routableServices should be initialized.");
    NSCAssert(ZIKRouter_subclassesComformToProtocol(g_routableServices, serviceProtocol).count <= 1, @"More than one service class conforms to this protocol, please use a unique protocol only conformed by the service class you want to fetch.");
#endif
    
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (!g_serviceProtocolToRouterMap) {
            g_serviceProtocolToRouterMap = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, NULL, NULL);
        }
    });
    if (!serviceProtocol) {
//        [ZIKServiceRouter _o_callbackError_invalidProtocolWithAction:@selector(init) errorDescription:@"ZIKServiceRouterForService() serviceProtocol is nil"];
        NSCAssert1(NO, @"ZIKServiceRouterForService() serviceProtocol is nil. callStackSymbols: %@",[NSThread callStackSymbols]);
        return nil;
    }
    
    Class routerClass = CFDictionaryGetValue(g_serviceProtocolToRouterMap, (__bridge const void *)(serviceProtocol));
    if (routerClass) {
        return routerClass;
    }
//    [ZIKServiceRouter _o_callbackError_invalidProtocolWithAction:@selector(init)
//                                             errorDescription:@"Didn't find service router for service protocol: %@, this protocol was not registered.",serviceProtocol];
    NSCAssert1(NO, @"Didn't find service router for service protocol: %@, this protocol was not registered.",serviceProtocol);
    return nil;
}

_Nullable Class ZIKServiceRouterForConfig(Protocol *configProtocol) {
    NSCParameterAssert(configProtocol);
    NSCAssert(g_configProtocolToRouterMap, @"Didn't register any protocol yet.");
    NSCAssert(_assert_isLoadFinished, @"Only get router after app did finish launch.");
    
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (!g_configProtocolToRouterMap) {
            g_configProtocolToRouterMap = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, NULL, NULL);
        }
    });
    if (!configProtocol) {
//        [ZIKServiceRouter _o_callbackError_invalidProtocolWithAction:@selector(init) errorDescription:@"ZIKServiceRouterForConfig() configProtocol is nil"];
        NSCAssert1(NO, @"ZIKServiceRouterForConfig() configProtocol is nil. callStackSymbols: %@",[NSThread callStackSymbols]);
        return nil;
    }
    
    Class routerClass = CFDictionaryGetValue(g_configProtocolToRouterMap, (__bridge const void *)(configProtocol));
    if (routerClass) {
        return routerClass;
    }
    
//    [ZIKServiceRouter _o_callbackError_invalidProtocolWithAction:@selector(init)
//                                             errorDescription:@"Didn't find service router for config protocol: %@, this protocol was not registered.",configProtocol];
    NSCAssert1(NO, @"Didn't find service router for config protocol: %@, this protocol was not registered.",configProtocol);
    return nil;
}

#pragma mark ZIKRouterProtocol

+ (void)registerRoutableDestination {
    NSAssert2(NO, @"subclass(%@) must implement +registerRoutableDestination to register destination with %@",self,self);
}

- (void)performRouteOnDestination:(id)destination configuration:(__kindof ZIKServiceRouteConfiguration *)configuration {
    [self beginPerformRoute];
    
    if (!destination) {
        [self endPerformRouteWithError:[[self class] errorWithCode:ZIKServiceRouteErrorServiceUnavailable localizedDescriptionFormat:@"Router(%@) returns nil for destination, maybe there is a bug in the router, or the configuration is invalid (%@)",self,configuration]];
        return;
    }
    if (configuration.prepareForRoute) {
        configuration.prepareForRoute(destination);
    }
    if (configuration.routeCompletion) {
        configuration.routeCompletion(destination);
    }
    [self endPerformRouteWithSuccess];
}

#pragma mark State

- (void)beginPerformRoute {
    NSAssert(self.state != ZIKRouterStateRouting, @"state should not be routing when begin to route.");
    [self notifyRouteState:ZIKRouterStateRouting];
}

- (void)endPerformRouteWithSuccess {
    NSAssert(self.state == ZIKRouterStateRouting, @"state should be routing when end to route.");
    [self notifyRouteState:ZIKRouterStateRouted];
    [self notifySuccessWithAction:@selector(performRoute)];
}

- (void)endPerformRouteWithError:(NSError *)error {
    NSAssert(self.state == ZIKRouterStateRouting, @"state should be routing when end to route.");
    [self notifyRouteState:ZIKRouterStateRouteFailed];
    [self notifyError:error routeAction:@selector(performRoute)];
}

- (void)beginRemoveRoute {
    NSAssert(self.state != ZIKRouterStateRemoving, @"state should not be removing when begin remove route.");
    [self notifyRouteState:ZIKRouterStateRemoving];
}

- (void)endRemoveRouteWithSuccessOnDestination:(id)destination {
    NSAssert(self.state == ZIKRouterStateRemoving, @"state should be removing when end remove route.");
    [self notifyRouteState:ZIKRouterStateRemoved];
}

- (void)endRemoveRouteWithError:(NSError *)error {
    NSAssert(self.state == ZIKRouterStateRemoving, @"state should be removing when end remove route.");
    [self notifyRouteState:ZIKRouterStateRemoveFailed];
    [self notifyError:error routeAction:@selector(removeRoute)];
}

+ (__kindof ZIKRouteConfiguration *)defaultRouteConfiguration {
    return [ZIKServiceRouteConfiguration new];
}

+ (__kindof ZIKRouteConfiguration *)defaultRemoveConfiguration {
    return [ZIKRouteConfiguration new];
}

- (NSString *)errorDomain {
    return kZIKServiceRouterErrorDomain;
}

+ (BOOL)completeSynchronously {
    return YES;
}

#pragma mark Error Handle

+ (void)setGlobalErrorHandler:(ZIKServiceRouteGlobalErrorHandler)globalErrorHandler {
    dispatch_semaphore_wait(g_globalErrorSema, DISPATCH_TIME_FOREVER);
    
    g_globalErrorHandler = globalErrorHandler;
    
    dispatch_semaphore_signal(g_globalErrorSema);
}

- (void)_o_callbackErrorWithAction:(SEL)routeAction error:(NSError *)error {
    [[self class] _o_callbackGlobalErrorHandlerWithRouter:self action:routeAction error:error];
    [super notifyError:error routeAction:routeAction];
}

+ (void)_o_callbackGlobalErrorHandlerWithRouter:(__kindof ZIKServiceRouter *)router action:(SEL)action error:(NSError *)error {
    dispatch_semaphore_wait(g_globalErrorSema, DISPATCH_TIME_FOREVER);
    
    ZIKServiceRouteGlobalErrorHandler errorHandler = g_globalErrorHandler;
    if (errorHandler) {
        errorHandler(router, action, error);
    } else {
#ifdef DEBUG
        NSLog(@"❌ZIKServiceRouter Error: router's action (%@) catch error: (%@),\nrouter:(%@)", NSStringFromSelector(action), error,router);
#endif
    }
    
    dispatch_semaphore_signal(g_globalErrorSema);
}

@end

@implementation ZIKServiceRouteConfiguration

- (id)copyWithZone:(NSZone *)zone {
    ZIKServiceRouteConfiguration *config = [super copyWithZone:zone];
    config.prepareForRoute = self.prepareForRoute;
    config.routeCompletion = self.routeCompletion;
    return config;
}

@end
