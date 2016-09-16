////////////////////////////////////////////////////////////////////////////
//
// Copyright 2016 Realm Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
////////////////////////////////////////////////////////////////////////////

#import "RLMSyncManager_Private.hpp"

#import "RLMRealmConfiguration+Sync.h"
#import "RLMSyncConfiguration_Private.hpp"
#import "RLMSyncFileManager.h"
#import "RLMSyncSession_Private.h"
#import "RLMSyncUser_Private.hpp"
#import "RLMUtil.hpp"

#import "sync_config.hpp"
#import "sync_manager.hpp"
#import "sync_metadata.hpp"
#import "sync_session.hpp"

using namespace realm;
using Level = realm::util::Logger::Level;

namespace {

Level levelForSyncLogLevel(RLMSyncLogLevel logLevel) {
    switch (logLevel) {
        case RLMSyncLogLevelOff:    return Level::off;
        case RLMSyncLogLevelFatal:  return Level::fatal;
        case RLMSyncLogLevelError:  return Level::error;
        case RLMSyncLogLevelWarn:   return Level::warn;
        case RLMSyncLogLevelInfo:   return Level::info;
        case RLMSyncLogLevelDetail: return Level::detail;
        case RLMSyncLogLevelDebug:  return Level::debug;
        case RLMSyncLogLevelTrace:  return Level::trace;
        case RLMSyncLogLevelAll:    return Level::all;
    }
    REALM_UNREACHABLE();    // Unrecognized log level.
}

struct CocoaSyncLogger : public realm::util::RootLogger {
    void do_log(Level, std::string message) override {
        NSLog(@"Sync: %@", RLMStringDataToNSString(message));
    }
};

struct CocoaSyncLoggerFactory : public realm::SyncLoggerFactory {
    std::unique_ptr<realm::util::Logger> make_logger(realm::util::Logger::Level level) override {
        auto logger = std::make_unique<CocoaSyncLogger>();
        logger->set_level_threshold(level);
        return std::move(logger);
    }
} s_syncLoggerFactory;

} // anonymous namespace

@interface RLMSyncManager ()

- (instancetype)initPrivate NS_DESIGNATED_INITIALIZER;

@property (nonnull, nonatomic) NSMutableDictionary<NSString *, RLMSyncUser *> *activeUsers;

@end

@implementation RLMSyncManager

+ (instancetype)sharedManager {
    static RLMSyncManager *sharedManager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedManager = [[RLMSyncManager alloc] initPrivate];
    });
    return sharedManager;
}

- (RLMSyncSession *)sessionForSyncConfiguration:(RLMSyncConfiguration *)config {
    NSURL *fileURL = [RLMSyncFileManager fileURLForRawRealmURL:config.realmURL user:config.user];
    return [config.user _registerSessionForBindingWithFileURL:fileURL
                                                   syncConfig:config
                                            standaloneSession:YES
                                                 onCompletion:nil];
}

- (instancetype)initPrivate {
    if (self = [super init]) {
        // Create the global error handler.
        auto errorLambda = [=](int error_code, std::string message) {
            NSError *error = [NSError errorWithDomain:RLMSyncErrorDomain
                                                 code:RLMSyncErrorClientSessionError
                                             userInfo:@{@"description": @(message.c_str()),
                                                        @"error": @(error_code)}];
            [self _fireError:error];
        };

        // Create the static login callback. This is called whenever any Realm wishes to BIND to the Realm Object Server
        // for the first time.
        SyncLoginFunction loginLambda = [=](const std::string& path, const SyncConfig& config) {
            NSString *localFilePath = @(path.c_str());
            RLMSyncConfiguration *syncConfig = [[RLMSyncConfiguration alloc] initWithRawConfig:config];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self _handleBindRequestForSyncConfig:syncConfig
                                        localFilePath:localFilePath];
            });
        };

        self.logLevel = RLMSyncLogLevelInfo;
        realm::SyncManager::shared().set_logger_factory(s_syncLoggerFactory);

        self.activeUsers = [NSMutableDictionary dictionary];

        // Initialize the sync engine.
        SyncManager::shared().set_error_handler(errorLambda);
        SyncManager::shared().set_login_function(loginLambda);
        NSString *metadataDirectory = [[RLMSyncFileManager fileURLForMetadata] path];
        _metadata_manager = std::make_unique<SyncMetadataManager>([metadataDirectory UTF8String], true);
        [self _cleanUpMarkedUsers];
        [self _loadPersistedUsers];
        return self;
    }
    return nil;
}

- (void)setLogLevel:(RLMSyncLogLevel)logLevel {
    _logLevel = logLevel;
    realm::SyncManager::shared().set_log_level(levelForSyncLogLevel(logLevel));
}

- (NSString *)appID {
    if (!_appID) {
        _appID = [[NSBundle mainBundle] bundleIdentifier] ?: @"(none)";
    }
    return _appID;
}

#pragma mark - Private API

- (void)_fireError:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.errorHandler) {
            self.errorHandler(error, nil);
        }
    });
}

- (void)_fireErrorWithCode:(int)errorCode
                   message:(NSString *)message
                   session:(RLMSyncSession *)session
                errorClass:(realm::SyncSessionError)errorClass {
    NSError *error;

    switch (errorClass) {
        case realm::SyncSessionError::UserFatal:
            // Kill the user.
            [[session parentUser] _invalidate];
            error = [NSError errorWithDomain:RLMSyncErrorDomain
                                        code:RLMSyncErrorClientUserError
                                    userInfo:@{@"description": message,
                                               @"error": @(errorCode)}];
            break;
        case realm::SyncSessionError::SessionFatal:
            // Kill the session.
            [session _invalidate];
        case realm::SyncSessionError::AccessDenied:
            error = [NSError errorWithDomain:RLMSyncErrorDomain
                                        code:RLMSyncErrorClientSessionError
                                    userInfo:@{@"description": message,
                                               @"error": @(errorCode)}];
            break;
        case realm::SyncSessionError::Debug:
            // Report the error. There's nothing the user can do about it, though.
            error = [NSError errorWithDomain:RLMSyncErrorDomain
                                        code:RLMSyncErrorClientInternalError
                                    userInfo:@{@"description": message,
                                               @"error": @(errorCode)}];
            break;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.errorHandler
            || (errorClass == realm::SyncSessionError::Debug && self.logLevel >= RLMSyncLogLevelDebug)) {
            return;
        }
        self.errorHandler(error, nil);
    });
}

- (SyncMetadataManager&)_metadataManager {
    return *_metadata_manager;
}

/// Load persisted users from the object store, and then turn them into actual users.
- (void)_loadPersistedUsers {
    @synchronized (self) {
        SyncUserMetadataResults users = _metadata_manager->all_unmarked_users();
        for (size_t i = 0; i < users.size(); i++) {
            RLMSyncUser *user = [[RLMSyncUser alloc] initWithMetadata:users.get(i)];
            self.activeUsers[user.identity] = user;
        }
    }
}

/// Clean up marked users and destroy them.
- (void)_cleanUpMarkedUsers {
    @synchronized (self) {
        SyncUserMetadataResults users_to_remove = _metadata_manager->all_users_marked_for_removal();
        for (size_t i = 0; i < users_to_remove.size(); i++) {
            auto user = users_to_remove.get(i);
            // FIXME: delete user data in a different way? (This deletes a logged-out user's data as soon as the app
            // launches again, which might not be how some apps want to treat their data.)
            [RLMSyncFileManager removeFilesForUserIdentity:@(user.identity().c_str()) error:nil];
            user.remove();
        }
    }
}

- (void)_handleBindRequestForSyncConfig:(RLMSyncConfiguration *)syncConfig
                          localFilePath:(NSString *)filePathString {
    RLMSyncUser *user = syncConfig.user;
    if (!user || !user.isValid) {
        if (auto session = SyncManager::shared().get_existing_active_session(filePathString.UTF8String)) {
            session->close_if_connecting();
        }
        return;
    }
    // FIXME: should the completion block actually do anything?
    [user _registerSessionForBindingWithFileURL:[NSURL fileURLWithPath:filePathString]
                                     syncConfig:syncConfig
                              standaloneSession:NO
                                   onCompletion:nil];
}

- (NSArray *)_allUsers {
    @synchronized (self) {
        return [self.activeUsers allValues];
    }
}

- (RLMSyncUser *)_registerUser:(RLMSyncUser *)user {
    @synchronized(self) {
        NSString *identity = user.identity;
        if (RLMSyncUser *user = [self.activeUsers objectForKey:identity]) {
            return user;
        }
        [self.activeUsers setObject:user forKey:identity];
        return nil;
    }
}

- (void)_deregisterUser:(RLMSyncUser *)user {
    @synchronized(self) {
        NSString *identity = user.identity;
        if (![self.activeUsers objectForKey:identity]) {
            @throw RLMException(@"Cannot unregister a user that isn't registered.");
        }
        [self.activeUsers removeObjectForKey:identity];
    }
}

- (RLMSyncUser *)_userForIdentity:(NSString *)identity {
    @synchronized (self) {
        return [self.activeUsers objectForKey:identity];
    }
}

@end
