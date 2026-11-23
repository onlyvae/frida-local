#import "LocalFridaService.h"
#import <objc/runtime.h>

static NSString *ServiceName(NSInteger major) {
    return major == 16 ? @"dev.fridalocal.service16" : @"dev.fridalocal.service";
}

// Roothide uses the Mach-service initializers available at runtime on iOS.
NSXPCConnection *FLCreateServiceConnection(NSInteger major) {
    SEL selector = NSSelectorFromString(@"initWithMachServiceName:options:");
    Method method = class_getInstanceMethod(NSXPCConnection.class, selector);
    if (!method) return nil;
    typedef NSXPCConnection *(*Initializer)(NSXPCConnection * __attribute__((ns_consumed)), SEL,
                                             NSString *, NSXPCConnectionOptions) __attribute__((ns_returns_retained));
    return ((Initializer)method_getImplementation(method))([NSXPCConnection alloc], selector,
                                                            ServiceName(major), NSXPCConnectionPrivileged);
}

NSXPCListener *FLCreateServiceListener(NSInteger major) {
    SEL selector = NSSelectorFromString(@"initWithMachServiceName:");
    Method method = class_getInstanceMethod(NSXPCListener.class, selector);
    if (!method) return nil;
    typedef NSXPCListener *(*Initializer)(NSXPCListener * __attribute__((ns_consumed)), SEL,
                                           NSString *) __attribute__((ns_returns_retained));
    return ((Initializer)method_getImplementation(method))([NSXPCListener alloc], selector, ServiceName(major));
}
