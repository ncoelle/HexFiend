//
//  main.m
//  hexf
//
//  Created by Kevin Wojniak on 9/24/17.
//  Copyright © 2017 ridiculous_fish. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import "HFController.h"
#include <sys/select.h>

static NSString *kAppIdentifier = @"com.ridiculousfish.HexFiend";

@interface Controller : NSObject

@end

@implementation Controller

- (int)printUsage {
    fprintf(stderr,
            "Usage:\n"
            "\n"
            "  Open files:\n"
            "    hexf [-e insert|overwrite|readonly] file1 [file2 file3 ...]\n"
            "\n"
            "  Compare files:\n"
            "    hexf -d file1 file2\n"
            "\n"
            "  Open piped data:\n"
            "    echo hello | hexf\n"
            "\n"
            "  Show help:\n"
            "    hexf -h | --help\n"
    );
    return EXIT_FAILURE;
}

- (NSString *)standardizePath:(NSString *)path {
    NSURL *url = [NSURL fileURLWithPath:path];
    return url.path; // get absolute path
}

- (BOOL)appRunning {
    NSRunningApplication* app = [[NSRunningApplication runningApplicationsWithBundleIdentifier:kAppIdentifier] firstObject];
    return app != nil;
}

- (BOOL)launchAppWithArgs:(NSArray *)args {
    NSDictionary *config = args ? @{NSWorkspaceLaunchConfigurationArguments: args} : nil;
    NSError *err = nil;
    NSURL *url = [[NSWorkspace sharedWorkspace] URLForApplicationWithBundleIdentifier:kAppIdentifier];
    if (![[NSWorkspace sharedWorkspace] launchApplicationAtURL:url options:NSWorkspaceLaunchDefault configuration:config error:&err]) {
        fprintf(stderr, "Launch app failed: %s\n", err.localizedDescription.UTF8String);
        return NO;
    }
    return YES;
}

- (BOOL)standardInputHasData {
    fd_set rfds;
    FD_ZERO(&rfds);
    FD_SET(STDIN_FILENO, &rfds);
    struct timeval timeout = {0, 0};
    return select(1, &rfds, NULL, NULL, &timeout) == 1;
}

- (BOOL)processStandardInput {
    if (!self.standardInputHasData) {
        return NO;
    }
    NSFileHandle *inFile = [NSFileHandle fileHandleWithStandardInput];
    NSData *data = [inFile readDataToEndOfFile];
    if (data.length == 0) {
        return NO;
    }
    if (self.appRunning) {
        // App is already running so post distributed notification
        NSDictionary *userInfo = @{@"data" : data};
        [[NSDistributedNotificationCenter defaultCenter] postNotificationName:@"HFOpenDataNotification" object:nil userInfo:userInfo deliverImmediately:YES];
        return YES;
    }
    // App isn't running so launch it with custom args
    NSString *base64Str = nil;
    if (@available(macOS 10.9, *)) {
        base64Str = [data base64EncodedStringWithOptions:0];
    } else {
        NSLog(@"Feature not available on 10.8");
        return NO;
    }
    NSArray *launchArgs = @[
        @"-HFOpenData",
        base64Str,
    ];
    return [self launchAppWithArgs:launchArgs];
}

- (int)processArguments:(NSArray<NSString *> *)args {
    NSMutableArray<NSString *> *filesToOpen = [NSMutableArray array];
    const NSUInteger argsCount = args.count;
    NSString *diffLeftFile = nil;
    NSString *diffRightFile = nil;
    NSNumber *editMode = nil;
    if (argsCount == 4 && [args[1] isEqualToString:@"-d"]) {
        diffLeftFile = [self standardizePath:args[2]];
        diffRightFile = [self standardizePath:args[3]];
    } else {
        for (NSUInteger i = 1; i < argsCount; ++i) {
            NSString *arg = [args objectAtIndex:i];
            if ([arg hasPrefix:@"-"]) {
                if ([arg isEqualToString:@"-h"] || [arg isEqualToString:@"--help"]) {
                    (void)[self printUsage];
                    return EXIT_SUCCESS;
                } else if ([arg isEqualToString:@"-e"]) {
                    @try {
                        NSString *modeStr = args[i + 1];
                        if ([modeStr isEqualToString:@"insert"]) {
                            editMode = @(HFInsertMode);
                        } else if ([modeStr isEqualToString:@"overwrite"]) {
                            editMode = @(HFOverwriteMode);
                        } else if ([modeStr isEqualToString:@"readonly"]) {
                            editMode = @(HFReadOnlyMode);
                        } else {
                            return [self printUsage];
                        }
                        ++i;
                        continue;
                    } @catch (NSException *ex) {
                        // assuming array out of bounds
                        return [self printUsage];
                    }
                }
                return [self printUsage];
            }
            [filesToOpen addObject:[self standardizePath:arg]];
        }
    }
    if (self.appRunning) {
        // App is already running so post distributed notification
        NSString *name = nil;
        NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
        if (diffLeftFile && diffRightFile) {
            name = @"HFDiffFilesNotification";
            userInfo[@"files"] = @[diffLeftFile, diffRightFile];
        } else {
            name = @"HFOpenFileNotification";
            userInfo[@"files"] = filesToOpen;
            if (editMode) {
                userInfo[@"editMode"] = editMode;
            }
        }
        [[NSDistributedNotificationCenter defaultCenter] postNotificationName:name object:nil userInfo:userInfo deliverImmediately:YES];
    } else {
        // App isn't running so launch it with custom args
        NSMutableArray<NSString *> *launchArgs = [NSMutableArray array];
        if (diffLeftFile && diffRightFile) {
            [launchArgs addObject:@"-HFDiffLeftFile"];
            [launchArgs addObject:diffLeftFile];
            [launchArgs addObject:@"-HFDiffRightFile"];
            [launchArgs addObject:diffRightFile];
        } else {
            for (NSString *fileToOpen in filesToOpen) {
                [launchArgs addObject:@"-HFOpenFile"];
                [launchArgs addObject:fileToOpen];
            }
            if (editMode) {
                [launchArgs addObject:@"-HFEditFile"];
                [launchArgs addObject:editMode.stringValue];
            }
        }
        if (![self launchAppWithArgs:launchArgs]) {
            return EXIT_FAILURE;
        }
    }
    return EXIT_SUCCESS;
}

@end

int main(int argc __unused, const char * argv[] __unused) {
    @autoreleasepool {
        Controller *controller = [[Controller alloc] init];
        NSArray<NSString *> *args = [[NSProcessInfo processInfo] arguments];
        if (args.count <= 1) {
            if ([controller processStandardInput]) {
                return EXIT_SUCCESS;
            } else {
                return [controller printUsage];
            }
        }
        return [controller processArguments:args];
    }
    return EXIT_SUCCESS;
}
