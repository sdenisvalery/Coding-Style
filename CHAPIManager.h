//
//  CHAPIManager.h
//  Chess.com
//
//  Created by Denis on 6/23/15.


#import <Foundation/Foundation.h>
#import <AFNetworking/AFNetworking.h>

typedef void(^CHAPIResponseSuccessBlock)(AFHTTPRequestOperation *operation, id responseObject);
typedef void(^CHAPIResponseErrorBlock)(AFHTTPRequestOperation *operation, NSError *error);

@interface CHAPIManager : NSObject

+ (CHAPIManager *)sharedInstance;

// Request methods
+ (NSString*)methodGET;
+ (NSString*)methodPOST;
+ (NSString*)methodPUT;
+ (NSString*)methodDELETE;

// Common keys
+ (NSString*)loginTokenKey;
+ (NSString*)dataKey;
+ (NSString*)errorCodeKey;
+ (NSString*)errorMessageKey;
+ (NSString*)urlKey;
+ (NSString*)bodyKey;

// Mime types
+ (NSString*)multipartRequestMimeType;

// Error related
+ (NSString*)chessComErrorDomain;

// Notifications
+ (NSString*)maintenanceNotificationName;
+ (NSString*)versionExpiredNotificationName;
+ (NSString*)reloginFailedNotificationName;

@property (nonatomic, strong, readonly) AFHTTPRequestOperationManager * manager;

//--------------------------------------------------------------
#pragma mark - Download or Upload files methods
//--------------------------------------------------------------

- (void)downloadFileFromURL:(NSString *)fileURL
                 toFilePath:(NSString *)filePath
          withProgressBlock:(void(^)(CGFloat progress))progressBlock
       andCompletionHandler:(void(^)(NSURLResponse *response, NSURL *filePath, NSError *error))completionHandler;

- (NSString *) createSignatureInfoForURL:(NSString *)relativePath
                          withParameters:(NSDictionary *)parameters
                                withFile:(NSString *)fileName
                        andFileFieldName:(NSString *)fileFieldName;

//--------------------------------------------------------------
#pragma mark - Execute requests methods
//--------------------------------------------------------------

- (AFHTTPRequestOperation *)executeRequestWithAPIPath:(NSString *)apiPath
                                           HTTPmethod:(NSString *)HTTPmethod
                                           parameters:(NSDictionary *)parameters
                                         successBlock:(CHAPIResponseSuccessBlock)successBlock
                                           errorBlock:(CHAPIResponseErrorBlock)errorBlock;

- (AFHTTPRequestOperation *)executeBatchRequestWithParameters:(NSArray *)parameters
                                          withBatchedRequests:(NSArray *)allRequests
                                                 successBlock:(CHAPIResponseSuccessBlock)successBlock
                                                   errorBlock:(CHAPIResponseErrorBlock)errorBlock;

//--------------------------------------------------------------
#pragma mark - Response processing methods
//--------------------------------------------------------------

- (NSArray*)entitiesInDictionary:(NSDictionary*)dictionary withEntityClass:(Class)entityClass;
- (NSArray*)entitiesInArray:(NSArray*)array withEntityClass:(Class)entityClass;
- (NSError *)processErrorFromOperation:(AFHTTPRequestOperation *)operation
                      withDefaultError:(NSError *)error;

@end
