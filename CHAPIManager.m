//
//  CHAPIManager.m
//  Chess.com
//
//  Created by Super Dev on 6/23/15.


#import "CHAPIManager.h"
#import "NSString+ChessExtensions.h"
#import "CHRequestInfo.h"
#import "CHRequestToAddInABatch.h"
#import "CHDuplicateRequestManager.h"
#import "CHLoginTokenExpirationHandler.h"
#import "CHRequestsURLCreator.h"

static NSTimeInterval const kTimeoutInterval = 20;

//------------------------------------------------------------------------------
#pragma mark - Private methods declarations
//------------------------------------------------------------------------------

@interface CHAPIManager() <CHLoginTokenExpirationHandlerDelegate>

@property (nonatomic, strong) AFHTTPRequestOperationManager * manager;
@property (nonatomic, strong) AFHTTPRequestOperationManager * batchRequestsManager;
@property (nonatomic, strong) AFURLSessionManager * URLSessionManager;

@property (nonatomic, strong) NSMutableSet * requestsToRetry;
@property (nonatomic, strong) NSMutableSet * batchRequestsToRetry;
@property (nonatomic, strong) CHLoginTokenExpirationHandler* loginTokenExpirationHandler;
@property (nonatomic, strong) CHRequestsURLCreator * requestsURLCreator;
@property (nonatomic, copy) NSString * expiredLoginToken;

@end

//------------------------------------------------------------------------------
#pragma mark - CHAPIManager implementation
//------------------------------------------------------------------------------

@implementation CHAPIManager

static NSString * const kTestEnvUsername = @"bobby";
static NSString * const kTestEnvPassword = @"fischer";
static NSString * const kRequestIdKey = @"request_id";
static NSString * const kMethodHEAD = @"HEAD";

//--------------------------------------------------------------
#pragma mark - Initialization methods
//--------------------------------------------------------------

+ (CHAPIManager *)sharedInstance
{
    static CHAPIManager * instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (id)init
{
    self = [super init];
    if (self)
    {
        _requestsToRetry = [NSMutableSet new];
        _batchRequestsToRetry = [NSMutableSet new];

        _requestsURLCreator = [[CHRequestsURLCreator alloc] init];

        _manager = [AFHTTPRequestOperationManager manager];
        _manager.requestSerializer = [AFHTTPRequestSerializer serializer];
        _manager.requestSerializer.HTTPMethodsEncodingParametersInURI = [NSSet setWithObjects:[CHAPIManager methodGET], kMethodHEAD, nil];
        _manager.requestSerializer.timeoutInterval = kTimeoutInterval;

        _batchRequestsManager = [AFHTTPRequestOperationManager manager];
        _batchRequestsManager.requestSerializer = [AFJSONRequestSerializer serializer];
        _batchRequestsManager.requestSerializer.timeoutInterval = kTimeoutInterval;

        _URLSessionManager = [[AFURLSessionManager alloc] initWithSessionConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration]];
        [self setupUserAgent];

        if (![_requestsURLCreator isPointingToProductionServer])
        {
            [_batchRequestsManager.requestSerializer setAuthorizationHeaderFieldWithUsername:kTestEnvUsername
                                                                                    password:kTestEnvPassword];
         
            [_manager.requestSerializer setAuthorizationHeaderFieldWithUsername:kTestEnvUsername
                                                                       password:kTestEnvPassword];
        }
    }
    return self;
}

//--------------------------------------------------------------
#pragma mark - Request methods
//--------------------------------------------------------------

+ (NSString*)methodGET { return @"GET"; }

+ (NSString*)methodPOST { return @"POST"; }

+ (NSString*)methodPUT { return @"PUT"; }

+ (NSString*)methodDELETE { return @"DELETE"; }

//--------------------------------------------------------------
#pragma mark - Common keys
//--------------------------------------------------------------

+ (NSString*)loginTokenKey { return @"loginToken"; }

+ (NSString*)dataKey { return @"data"; }

+ (NSString*)errorCodeKey { return @"code"; }

+ (NSString*)errorMessageKey { return @"message"; }

+ (NSString*)urlKey { return @"url"; }

+ (NSString*)bodyKey { return @"body"; }

//--------------------------------------------------------------
#pragma mark - Mime types
//--------------------------------------------------------------

+ (NSString*)multipartRequestMimeType { return @"application/octet-stream"; }

//--------------------------------------------------------------
#pragma mark - Error related
//--------------------------------------------------------------
+ (NSString*)chessComErrorDomain { return @"Chess.comDomain"; }


//--------------------------------------------------------------
#pragma mark - Notifications
//--------------------------------------------------------------
+ (NSString*)maintenanceNotificationName { return @"CHMaintenanceNotificationName"; }
+ (NSString*)versionExpiredNotificationName { return @"CHVersionExpiredNotificationName"; }
+ (NSString*)reloginFailedNotificationName { return @"CHReloginFailedNotificationName"; }

//--------------------------------------------------------------
#pragma mark - Download or Upload files methods
//--------------------------------------------------------------

- (void)downloadFileFromURL:(NSString *)fileURL
                 toFilePath:(NSString *)filePath
          withProgressBlock:(void(^)(CGFloat progress))progressBlock
       andCompletionHandler:(void(^)(NSURLResponse *response, NSURL *filePath, NSError *error))completionHandler
{
    NSURL *URL = [NSURL URLWithString:fileURL];
    NSURLRequest *request = [NSURLRequest requestWithURL:URL];

    [[self.URLSessionManager downloadTaskWithRequest:request
                                            progress:nil
                                         destination:^NSURL *(NSURL *targetPath, NSURLResponse *response) {
                                             return [NSURL fileURLWithPath:filePath];
                                         }
                                   completionHandler:completionHandler] resume];

    [self.URLSessionManager setDownloadTaskDidWriteDataBlock:^(NSURLSession *session, NSURLSessionDownloadTask *downloadTask, int64_t bytesWritten, int64_t totalBytesWritten, int64_t totalBytesExpectedToWrite) {
        progressBlock((CGFloat)totalBytesWritten / totalBytesExpectedToWrite);
    }];
}

- (NSString *) createSignatureInfoForURL:(NSString *)relativePath
                          withParameters:(NSDictionary *)parameters
                                withFile:(NSString *)fileName
                        andFileFieldName:(NSString *)fileFieldName
{
    return [self.requestsURLCreator createSignatureInfoForURL:relativePath
                                               withParameters:parameters
                                                     withFile:fileName
                                             andFileFieldName:fileFieldName
                                                       method:[CHAPIManager methodPOST]];
}

//--------------------------------------------------------------
#pragma mark - Response processing methods
//--------------------------------------------------------------

- (NSArray*)entitiesInDictionary:(NSDictionary*)dictionary withEntityClass:(Class)entityClass
{
    NSArray* entitiesData = dictionary[[CHAPIManager dataKey]];
    NSMutableArray* entities = [NSMutableArray arrayWithCapacity:entitiesData.count];

    for (NSDictionary* entityData in entitiesData)
    {
        if ([entityClass respondsToSelector:@selector(entityFromDictionary:)])
        {
            [entities addObject:[entityClass performSelector:@selector(entityFromDictionary:) withObject:entityData]];
        }
    }

    return entities;
}

- (NSArray*)entitiesInArray:(NSArray*)array withEntityClass:(Class)entityClass
{
    NSMutableArray* entities = [NSMutableArray arrayWithCapacity:array.count];

    for (NSDictionary* entityData in array)
    {
        if ([entityClass respondsToSelector:@selector(entityFromDictionary:)])
        {
            [entities addObject:[entityClass performSelector:@selector(entityFromDictionary:) withObject:entityData]];
        }
    }

    return entities;
}

- (NSError *)processErrorFromOperation:(AFHTTPRequestOperation *)operation
                      withDefaultError:(NSError *)error
{
    NSError * returnError = error;
    
    if (operation.response.statusCode == kCHHTTPResponseCodeMaintenance)
    {
        CLS_LOG(@"Mainenance error");
        [[NSNotificationCenter defaultCenter] postNotificationName:[CHAPIManager maintenanceNotificationName] object:self];
        returnError = nil;
    }
    else if (operation.response.statusCode == kCHHTTPResponseCodeAccessDenied && [operation.response.allHeaderFields objectForKey:@"X-Authentication-Expires"] != nil)
    {
        CLS_LOG(@"Version expired error");
        [[NSNotificationCenter defaultCenter] postNotificationName:[CHAPIManager versionExpiredNotificationName] object:self];
        returnError = nil;
    }
    else if (operation.response.statusCode == kCHHTTPResponseCodeAccessDenied)
    {
        CLS_LOG(@"Access denied error");
        returnError = [NSError errorWithDomain:[CHAPIManager chessComErrorDomain]
                                          code:[operation.responseObject[[CHAPIManager errorCodeKey]] integerValue]
                                      userInfo:@{NSLocalizedDescriptionKey : NSLocalizedString(@"Oops. We couldn\'t authenticate with the server.", nil)}];
    }
    else if(operation.response.statusCode == kCHHTTPResponseCodeOopsDubiousMove || operation.response.statusCode == kCHHTTPResponseCodeOopsCDNIssue)
    {
        CLS_LOG(@"Dubious move error");
        returnError = [NSError errorWithDomain:[CHAPIManager chessComErrorDomain]
                                          code:[operation.responseObject[[CHAPIManager errorCodeKey]] integerValue]
                                      userInfo:@{NSLocalizedDescriptionKey : NSLocalizedString(@"Oops. Our servers just made a dubious move. Thanks for your patience.", nil)}];
    }
    else if(error.code == kCFURLErrorUserCancelledAuthentication)
    {
        CLS_LOG(@"Dubious move error");
        returnError = [NSError errorWithDomain:[CHAPIManager chessComErrorDomain]
                                          code:[operation.responseObject[[CHAPIManager errorCodeKey]] integerValue]
                                      userInfo:@{NSLocalizedDescriptionKey : NSLocalizedString(@"Access to Chess.com is blocked at your location.", nil)}];
    }
    else if (operation.responseObject[[CHAPIManager errorCodeKey]] != nil && operation.responseObject[[CHAPIManager errorMessageKey]] != nil)
    {
        CLS_LOG(@"Other error");
        returnError = [NSError errorWithDomain:[CHAPIManager chessComErrorDomain]
                                          code:[operation.responseObject[[CHAPIManager errorCodeKey]] integerValue]
                                      userInfo:@{NSLocalizedDescriptionKey : operation.responseObject[[CHAPIManager errorMessageKey]]}];
    }

    return returnError;
}

- (NSError *)processErrorsFromBatchRequestResponse:(id)response
{
    NSError * returnError = nil;
    NSArray * requestsResponses = response[[CHAPIManager dataKey]];
    for(NSDictionary * requestResponse in requestsResponses)
    {
        if (requestResponse[[CHAPIManager errorCodeKey]] != nil && requestResponse[[CHAPIManager errorMessageKey]] != nil)
        {
            returnError = [NSError errorWithDomain:[CHAPIManager chessComErrorDomain]
                                              code:[requestResponse[[CHAPIManager errorCodeKey]] integerValue]
                                          userInfo:@{NSLocalizedDescriptionKey : requestResponse[[CHAPIManager errorMessageKey]]}];
            break;
        }
    }
    return returnError;
}

- (void)distributeResponsesFromResponseObject:(id)responseObject
                                   toRequests:(NSArray *)allRequests
{
    for (id response in responseObject)
    {
        if ([response isKindOfClass:[NSDictionary class]])
        {
            NSDictionary* responseDictionary = response;
            NSNumber* requestId = responseDictionary[kRequestIdKey];
            CHRequestToAddInABatch * request = allRequests[requestId.integerValue];
            
            CLS_LOG(@"\nRequest: %@\nParameters: %@\nResponse: %@",
                    request.URL, request.parameters, response);
            
            if (responseDictionary[[CHAPIManager dataKey]])
            {
                request.responseBlock(responseDictionary[[CHAPIManager dataKey]]);
            }
            else
            {
                request.responseBlock(responseDictionary);
            }
        }
    }
}

- (CHAPIResponseErrorBlock)requestErrorBlockWithAPIPath:(NSString *)apiPath
                                             HTTPMethod:(NSString *)HTTPMethod
                                             parameters:(NSDictionary *)parameters
                                           successBlock:(CHAPIResponseSuccessBlock)successBlock
                                             errorBlock:(CHAPIResponseErrorBlock)errorBlock
{
    return ^(AFHTTPRequestOperation *operation, NSError *error) {
        NSError * processedError = [self processErrorFromOperation:operation withDefaultError:error];
        if(processedError.code == kCHAPIErrorInvalidAccessToken)
        {
            [self handleLoginTokenExpiredForAPIPath:apiPath
                                         HTTPMethod:HTTPMethod
                                         parameters:parameters
                                       successBlock:successBlock
                                         errorBlock:errorBlock];
        }
        else if (errorBlock != nil && processedError != nil)
        {
            errorBlock(operation, processedError);
        }
    };
}

//--------------------------------------------------------------
#pragma mark - Private methods
//--------------------------------------------------------------

- (void)setupUserAgent
{
    NSString * userAgent = [NSString stringWithFormat:@"Chesscom-iOS/%@ (%@; iOS %@; chesscom-ios-developers@googlegroups.com)",
                            [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleShortVersionString"] ?: [[[NSBundle mainBundle] infoDictionary] objectForKey:(__bridge NSString *)kCFBundleVersionKey],
                            [[UIDevice currentDevice] model], [[UIDevice currentDevice] systemVersion]];

    if (userAgent) {
        if (![userAgent canBeConvertedToEncoding:NSASCIIStringEncoding]) {
            NSMutableString *mutableUserAgent = [userAgent mutableCopy];
            if (CFStringTransform((__bridge CFMutableStringRef)(mutableUserAgent), NULL, (__bridge CFStringRef)@"Any-Latin; Latin-ASCII; [:^ASCII:] Remove", false)) {
                userAgent = mutableUserAgent;
            }
        }
        [self.manager.requestSerializer setValue:userAgent forHTTPHeaderField:@"User-Agent"];
        [self.batchRequestsManager.requestSerializer setValue:userAgent forHTTPHeaderField:@"User-Agent"];
    }
}

- (CHLoginTokenExpirationHandler*)loginTokenExpirationHandler
{
    if (_loginTokenExpirationHandler == nil)
    {
        _loginTokenExpirationHandler = [[CHLoginTokenExpirationHandler alloc] init];
        _loginTokenExpirationHandler.delegate = self;
    }

    return _loginTokenExpirationHandler;
}

//--------------------------------------------------------------
#pragma mark - Login Expiration handling methods
//--------------------------------------------------------------

- (void)handleLoginTokenExpiredForAPIPath:(NSString *)apiPath
                               HTTPMethod:(NSString *)HTTPmethod
                               parameters:(NSDictionary *)parameters
                             successBlock:(CHAPIResponseSuccessBlock)successBlock
                               errorBlock:(CHAPIResponseErrorBlock)errorBlock
{
    self.expiredLoginToken = parameters[[CHAPIManager loginTokenKey]];
    CHRequestInfo * requestInfo = [CHRequestInfo new];
    requestInfo.apiPath = apiPath;
    requestInfo.HTTPMethod = HTTPmethod;
    requestInfo.parameters = [NSMutableDictionary dictionaryWithDictionary:parameters];
    requestInfo.successBlock = successBlock;
    requestInfo.errorBlock = errorBlock;
    [self.requestsToRetry addObject:requestInfo];
    [self.loginTokenExpirationHandler refreshToken];
}

- (void)handleLoginTokenExpiredForBatchRequestWithParameters:(NSArray *)parameters
                                             batchedRequests:(NSArray *)batchedRequests
                                                successBlock:(CHAPIResponseSuccessBlock)successBlock
                                                  errorBlock:(CHAPIResponseErrorBlock)errorBlock
{
    self.expiredLoginToken = [self extractLoginTokenFromBatchParameters:parameters];
    CHRequestInfo * requestInfo = [CHRequestInfo new];
    requestInfo.batchRequestParameters = [NSMutableArray arrayWithArray:parameters];
    requestInfo.successBlock = successBlock;
    requestInfo.errorBlock = errorBlock;
    requestInfo.batchedRequests = batchedRequests;
    [self.batchRequestsToRetry addObject:requestInfo];
    [self.loginTokenExpirationHandler refreshToken];
}

- (BOOL)expiredLoginTokenIsIncludedInParametersDictionary:(NSDictionary *)parameters
{
    return (parameters[[CHAPIManager loginTokenKey]] != nil && [parameters[[CHAPIManager loginTokenKey]] isEqualToString:self.expiredLoginToken]);
}

- (BOOL)expiredLoginTokenIsIncludedInParametersArray:(NSArray *)parameters
{
    NSString * parametersLoginToken = [self extractLoginTokenFromBatchParameters:parameters];
    return (parametersLoginToken != nil && [parametersLoginToken isEqualToString:self.expiredLoginToken]);
}

- (NSString *)extractLoginTokenFromBatchParameters:(NSArray *)parameters
{
    NSString * loginToken = nil;
    for (NSDictionary * requestParameters in parameters)
    {
        NSString * requestURL = requestParameters[[CHAPIManager urlKey]];
        if ([requestURL rangeOfString:[CHAPIManager loginTokenKey]].location != NSNotFound)
        {
            loginToken = [requestURL stringBetweenString:[[CHAPIManager loginTokenKey] stringByAppendingString:@"="]
                                               andString:@"&"];
            break;
        }
    }
    return loginToken;
}

- (void)replaceLoginTokenInBatchRequestInfo:(CHRequestInfo *)requestInfo
                          withNewLoginToken:(NSString*)loginToken
{
    for (NSInteger parameterIndex = 0; parameterIndex < requestInfo.batchedRequests.count; parameterIndex++)
    {
        CHRequestToAddInABatch * request = requestInfo.batchedRequests[parameterIndex];
        request.URL = [request.URL stringByReplacingOccurrencesOfString:self.expiredLoginToken
                                                             withString:loginToken];
        NSMutableDictionary * parameters = [requestInfo.batchRequestParameters[parameterIndex] mutableCopy];
        parameters[[CHAPIManager urlKey]] = request.URL;
        if(parameters[[CHAPIManager bodyKey]] != nil)
        {
            NSMutableDictionary* body = [parameters[[CHAPIManager bodyKey]] mutableCopy];
            body[[CHAPIManager loginTokenKey]] = loginToken;
            parameters[[CHAPIManager bodyKey]] = body;
        }
        requestInfo.batchRequestParameters[parameterIndex] = parameters;
    }
}

//------------------------------------------------------------------------------
#pragma mark - CHLoginTokenExpirationHandlerDelegate
//------------------------------------------------------------------------------
- (void)loginTokenExpirationHandler:(CHLoginTokenExpirationHandler*)handler
               refreshSucceededWith:(NSString*)loginToken
{
    for (CHRequestInfo * requestInfoToRetry in self.requestsToRetry)
    {
        requestInfoToRetry.parameters[[CHAPIManager loginTokenKey]] = loginToken;
        [self executeRequestWithAPIPath:requestInfoToRetry.apiPath
                             HTTPmethod:requestInfoToRetry.HTTPMethod
                             parameters:requestInfoToRetry.parameters
                           successBlock:requestInfoToRetry.successBlock
                             errorBlock:requestInfoToRetry.errorBlock];
    }

    [self.requestsToRetry removeAllObjects];

    for (CHRequestInfo * requestInfoToRetry in self.batchRequestsToRetry)
    {
        [self replaceLoginTokenInBatchRequestInfo:requestInfoToRetry withNewLoginToken:loginToken];
        [self executeBatchRequestWithParameters:requestInfoToRetry.batchRequestParameters
                            withBatchedRequests:requestInfoToRetry.batchedRequests
                                   successBlock:requestInfoToRetry.successBlock
                                     errorBlock:requestInfoToRetry.errorBlock];
    }

    [self.batchRequestsToRetry removeAllObjects];
    self.expiredLoginToken = nil;
}

- (void)loginTokenExpirationHandlerRefreshFailed:(CHLoginTokenExpirationHandler*)handler
{
    self.expiredLoginToken = nil;
    [[NSNotificationCenter defaultCenter] postNotificationName:[CHAPIManager reloginFailedNotificationName] object:nil];
}

//--------------------------------------------------------------
#pragma mark - Execute requests methods
//--------------------------------------------------------------

- (AFHTTPRequestOperation *)executeRequestWithAPIPath:(NSString *)apiPath
                                           HTTPmethod:(NSString *)HTTPmethod
                                           parameters:(NSDictionary *)parameters
                                         successBlock:(CHAPIResponseSuccessBlock)successBlock
                                           errorBlock:(CHAPIResponseErrorBlock)errorBlock
{
    AFHTTPRequestOperation * request = nil;

    if ([self expiredLoginTokenIsIncludedInParametersDictionary:parameters])
    {
        CHRequestInfo * requestInfo = [CHRequestInfo new];
        requestInfo.apiPath = apiPath;
        requestInfo.HTTPMethod = HTTPmethod;
        requestInfo.parameters = [NSMutableDictionary dictionaryWithDictionary:parameters];
        requestInfo.successBlock = successBlock;
        requestInfo.errorBlock = errorBlock;
        [self.requestsToRetry addObject:requestInfo];
    }
    else
    {
        CHAPIResponseErrorBlock failedResponseBlock = [self requestErrorBlockWithAPIPath:apiPath
                                                                              HTTPMethod:HTTPmethod
                                                                              parameters:parameters
                                                                            successBlock:successBlock
                                                                              errorBlock:errorBlock];

        BOOL requestWasMade = [[CHDuplicateRequestManager sharedInstance] addRequestWithAPIPath:apiPath
                                                                                     HTTPmethod:HTTPmethod
                                                                                     parameters:parameters
                                                                                   successBlock:successBlock
                                                                                     errorBlock:failedResponseBlock];

        if (!requestWasMade)
        {
            NSString * url;
            CHAPIResponseSuccessBlock succeedResponseBlock = ^(AFHTTPRequestOperation *operation, id responseObject) {
                [[CHDuplicateRequestManager sharedInstance] requestSucceedWithAPIPath:apiPath
                                                                           HTTPmethod:HTTPmethod
                                                                           parameters:parameters
                                                                            operation:operation
                                                                             response:responseObject];
            };

            CHAPIResponseErrorBlock errorResponseBlock = ^(AFHTTPRequestOperation *operation, NSError *error) {
                [[CHDuplicateRequestManager sharedInstance] requestFailedWithAPIPath:apiPath
                                                                          HTTPmethod:HTTPmethod
                                                                          parameters:parameters
                                                                           operation:operation
                                                                               error:error];
            };

            if ([HTTPmethod isEqualToString:[CHAPIManager methodGET]])
            {
                url = [self.requestsURLCreator createGetURLForAPIPath:apiPath
                                                           parameters:parameters];
                request = [self.manager GET:url
                                 parameters:nil
                                    success:succeedResponseBlock
                                    failure:errorResponseBlock];
            }
            else if ([HTTPmethod isEqualToString:[CHAPIManager methodPOST]])
            {
                url = [self.requestsURLCreator createSignedURLFromBaseURL:apiPath
                                                           withParameters:parameters
                                                                   method:[CHAPIManager methodPOST]];

                request = [self.manager POST:url
                                  parameters:parameters
                                     success:succeedResponseBlock
                                     failure:errorResponseBlock];
            }
            else if ([HTTPmethod isEqualToString:[CHAPIManager methodDELETE]])
            {
                url = [self.requestsURLCreator createDeleteURLWithParametersForAPIPath:apiPath
                                                                            parameters:parameters];

                request = [self.manager DELETE:url
                                    parameters:parameters
                                       success:succeedResponseBlock
                                       failure:errorResponseBlock];
            }
            else if([HTTPmethod isEqualToString:[CHAPIManager methodPUT]])
            {
                url = [self.requestsURLCreator createSignedURLFromBaseURL:apiPath
                                                           withParameters:parameters
                                                                   method:[CHAPIManager methodPUT]];

                request = [self.manager PUT:url
                                 parameters:parameters
                                    success:succeedResponseBlock
                                    failure:errorResponseBlock];
            }
        }
    }

    return request;
}

- (AFHTTPRequestOperation *)executeBatchRequestWithParameters:(NSArray *)parameters
                                          withBatchedRequests:(NSArray *)allRequests
                                                 successBlock:(CHAPIResponseSuccessBlock)successBlock
                                                   errorBlock:(CHAPIResponseErrorBlock)errorBlock
{
    AFHTTPRequestOperation * request = nil;
    if ([self expiredLoginTokenIsIncludedInParametersArray:parameters])
    {
        CHRequestInfo * requestInfo = [CHRequestInfo new];
        requestInfo.batchRequestParameters = [NSMutableArray arrayWithArray:parameters];
        requestInfo.successBlock = successBlock;
        requestInfo.errorBlock = errorBlock;
        [self.batchRequestsToRetry addObject:requestInfo];
    }
    else
    {
        NSString* urlToUse = [self.requestsURLCreator createBatchSignedURLFromParameters:parameters];
        CHDuplicateRequestManager* manager = [CHDuplicateRequestManager sharedInstance];
        
        __weak typeof(self) weakSelf = self;
        BOOL requestWasMade = [manager addRequestWithAPIPath:urlToUse
                                                  HTTPmethod:[CHAPIManager methodPOST]
                                                  parameters:parameters
                                                successBlock:^(AFHTTPRequestOperation* operation, id responseObject) {
                                                    NSError* responseError = [weakSelf processErrorsFromBatchRequestResponse:responseObject];
                                                    
                                                    if (responseError == nil || responseError.code == kCHAPIErrorResourceNotFound)
                                                    {
                                                        [weakSelf distributeResponsesFromResponseObject:responseObject[[CHAPIManager dataKey]]
                                                                                             toRequests:allRequests];
                                                        successBlock(operation, responseObject);
                                                    }
                                                    else if (responseError.code == kCHAPIErrorInvalidAccessToken)
                                                    {
                                                        [weakSelf handleLoginTokenExpiredForBatchRequestWithParameters:parameters
                                                                                                       batchedRequests:allRequests
                                                                                                          successBlock:successBlock
                                                                                                            errorBlock:errorBlock];
                                                    }
                                                    else if (errorBlock != nil)
                                                    {
                                                        errorBlock(operation, responseError);
                                                    }
                                                }
                                                  errorBlock:^(AFHTTPRequestOperation* operation, NSError* error) {
                                                      NSError* responseError = [weakSelf processErrorFromOperation:operation
                                                                                                  withDefaultError:nil];
                                                      if (errorBlock != nil)
                                                      {
                                                          errorBlock(operation, responseError);
                                                      }
                                                  }];


        if (!requestWasMade)
        {
            request = [self.batchRequestsManager POST:urlToUse
                                           parameters:parameters
                                              success:^(AFHTTPRequestOperation *operation, id responseObject) {
                                                  [[CHDuplicateRequestManager sharedInstance] requestSucceedWithAPIPath:urlToUse
                                                                                                             HTTPmethod:[CHAPIManager methodPOST]
                                                                                                             parameters:parameters
                                                                                                              operation:operation
                                                                                                               response:responseObject];
                                              }
                                              failure:^(AFHTTPRequestOperation *operation, NSError *error) {
                                                  [[CHDuplicateRequestManager sharedInstance] requestFailedWithAPIPath:urlToUse
                                                                                                            HTTPmethod:[CHAPIManager methodPOST]
                                                                                                            parameters:parameters
                                                                                                             operation:operation
                                                                                                                 error:error];
                                              }];
        }
    }
    return request;
}

@end
