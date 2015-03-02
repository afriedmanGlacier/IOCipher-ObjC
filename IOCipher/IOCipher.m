//
//  IOCipher.m
//  Pods
//
//  Created by Christopher Ballinger on 1/20/15.
//
//

#import "IOCipher.h"
#import "sqlfs.h"
#import "IOFileCopier.h"

/** Switches sign on sqlfs result codes */
static inline NSError* IOCipherPOSIXError(int code) {
    return [NSError errorWithDomain:NSPOSIXErrorDomain code:-code userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithUTF8String:strerror(code)]}];
}

@interface IOCipher()
@property (nonatomic, readonly) sqlfs_t *sqlfs;

@property (nonatomic) dispatch_queue_t isolationQueue;
@property (nonatomic, strong) NSMutableDictionary *fileCopierDictionary;

@end

@implementation IOCipher

- (void) dealloc {
    if (_sqlfs) {
        sqlfs_close(_sqlfs);
        _sqlfs = NULL;
    }
}

/** password should be UTF-8 */
- (instancetype) initWithPath:(NSString*)path password:(NSString*)password {
    NSParameterAssert(path != nil);
    NSAssert(password.length > 0, @"password should have a non-zero length!");
    if (password.length == 0) {
        return nil;
    }
    if (self = [super init]) {
        sqlfs_open_password([path UTF8String], [password UTF8String], &_sqlfs);
        if (!_sqlfs) {
            return nil;
        }
        [self commonInit];
    }
    return self;
}

/** key should be 32-bytes */
- (instancetype) initWithPath:(NSString*)path key:(NSData*)key {
    NSParameterAssert(path != nil);
    NSAssert(key.length == 32, @"key must be 32 bytes");
    if (key.length != 32) {
        return nil;
    }
    if (self = [super init]) {
        sqlfs_open_key([path UTF8String], [key bytes], key.length, &_sqlfs);
        if (!_sqlfs) {
            return nil;
        }
        [self commonInit];
    }
    return self;
}

/** Sets up self for all init methods */
- (void)commonInit
{
    self.isolationQueue = dispatch_queue_create("IOCIPHER.ISOLATION.QUEUE", 0);
}

/** Creates file at path */
- (BOOL) createFileAtPath:(NSString*)path error:(NSError**)error {
    struct fuse_file_info ffi;
    ffi.direct_io = 0;
    int result = sqlfs_proc_create(NULL, [path UTF8String], 0, &ffi);
    if (result == SQLITE_OK) {
        return YES;
    } else if (error) {
        *error = IOCipherPOSIXError(result);
    }
    return NO;
}

/** Creates folder at path */
- (BOOL) createFolderAtPath:(NSString*)path error:(NSError**)error {
    NSParameterAssert(path != nil);
    if (!path) {
        return NO;
    }
    int result = sqlfs_proc_mkdir(NULL, [path UTF8String], 0);
    if (result == SQLITE_OK) {
        return YES;
    } else if (error) {
        *error = IOCipherPOSIXError(result);
    }
    return NO;
}

/** Removes file or folder at path */
- (BOOL) removeItemAtPath:(NSString*)path error:(NSError**)error {
    NSParameterAssert(path != nil);
    if (!path) {
        return NO;
    }
    const char * cPath = [path UTF8String];
    int result = -1;
    if (sqlfs_is_dir(NULL, cPath)) {
        result = sqlfs_proc_rmdir(NULL, cPath);
    } else {
        result = sqlfs_proc_unlink(NULL, cPath);
    }
    if (result == SQLITE_OK) {
        return YES;
    } else if (error) {
        *error = IOCipherPOSIXError(result);
    }
    return NO;
}


- (BOOL) fileExistsAtPath:(NSString *)path
              isDirectory:(BOOL *)isDirectory {
    NSParameterAssert(path != nil);
    if (!path) {
        return NO;
    }
    const char * cPath = [path UTF8String];
    if (isDirectory) {
        *isDirectory = sqlfs_is_dir(NULL, cPath);
    }
    int result = sqlfs_proc_access(NULL, cPath, 0);
    if (result == SQLITE_OK) {
        return YES;
    }
    return NO;
}

/**
 *  Returns NSDictionary of file attributes similar to NSFileManager
 *
 *  Supported keys:
 *    * NSFileSize (NSNumber)
 *    * NSFileModificationDate (NSDate)
 *
 *  @param path file path
 *
 *  @return file attribute keys or nil if error
 */
- (NSDictionary*) fileAttributesAtPath:(NSString*)path error:(NSError**)error {
    NSParameterAssert(path != nil);
    struct stat sb;
    const char * cPath = [path UTF8String];
    int result = sqlfs_proc_getattr(NULL, cPath, &sb);
    if (result < 0) {
        if (error) {
            *error = IOCipherPOSIXError(result);
        }
        return nil;
    }
    NSNumber *fileSize = @(sb.st_size);
    NSDate *lastModified = [NSDate dateWithTimeIntervalSince1970:((NSTimeInterval)sb.st_mtimespec.tv_sec + (NSTimeInterval)sb.st_mtimespec.tv_nsec / 1000000000.0)];
    NSDictionary *fileAttributes = @{NSFileSize: fileSize,
                                     NSFileModificationDate: lastModified};
    return fileAttributes;
}

/**
 *  Reads data from file at path.
 *
 *  @param path   file path
 *  @param length length of data to read in bytes
 *  @param offset byte offset in file
 *  @param error  error
 *
 *  @return Data read from file, or nil if there was an error. May be less than length.
 */
- (NSData*) readDataFromFileAtPath:(NSString*)path
                            length:(NSUInteger)length
                            offset:(NSUInteger)offset
                             error:(NSError**)error {
    NSParameterAssert(path != nil);
    if (!path) {
        return nil;
    }
    struct fuse_file_info ffi;
    const char * cPath = [path UTF8String];
    uint8_t *bytes = malloc(sizeof(uint8_t) * length);
    if (!bytes) {
        return nil;
    }
    int result = sqlfs_proc_read(NULL,
                                  cPath,
                                  (char*)bytes,
                                  length,
                                  offset,
                                  &ffi);
    if (result < 0) {
        free(bytes);
        if (result != -EIO) { // sqlfs_proc_open returns EIO on end-of-file
            if (error) {
                *error = IOCipherPOSIXError(result);
            }
        }
        return nil;
    } else {
        NSData *data = [NSData dataWithBytesNoCopy:bytes length:result freeWhenDone:YES];
        return data;
    }
    return nil;
}

/**
 *  Writes data to file at path at offset.
 *
 *  @param path   file path
 *  @param data   data to write
 *  @param offset byte offset in file
 *  @param error  error
 *
 *  @return number of bytes written, or -1 if error
 */
- (NSInteger) writeDataToFileAtPath:(NSString*)path
                               data:(NSData*)data
                             offset:(NSUInteger)offset
                              error:(NSError**)error {
    NSParameterAssert(path != nil);
    NSParameterAssert(data != nil);
    if (!path || !data) {
        return NO;
    }
    struct fuse_file_info ffi;
    const char * cPath = [path UTF8String];
    int result = sqlfs_proc_write(NULL,
                                  cPath,
                                  data.bytes,
                                  data.length,
                                  offset,
                                  &ffi);
    if (result < 0) {
        if (error) {
            *error = IOCipherPOSIXError(result);
        }
        return -1;
    } else {
        return result;
    }
}

/**
 *  Truncates file at path to new length.
 *
 *  @param path   file path
 *  @param length new file length in bytes
 *  @param error  error
 *
 *  @return success or failure
 */
- (BOOL) truncateFileAtPath:(NSString*)path
                     length:(NSUInteger)length
                      error:(NSError**)error {
    NSParameterAssert(path != nil);
    const char *cPath = [path UTF8String];
    int result = sqlfs_proc_truncate(NULL, cPath, (off_t)length);
    if (result < 0) {
        if (error) {
            *error = IOCipherPOSIXError(result);
        }
        return NO;
    }
    return YES;
}

#pragma - mark File Copying

- (NSMutableDictionary *)fileCopierDictionary
{
    if (!_fileCopierDictionary) {
        _fileCopierDictionary = [[NSMutableDictionary alloc] init];
    }
    return _fileCopierDictionary;
}

- (void)setFileCopier:(IOFileCopier *)fileCopier forEncryptedFilePath:(NSString *)encryptedFilePath
{
    if (encryptedFilePath) {
        dispatch_async(self.isolationQueue, ^{
            if (fileCopier) {
                [self.fileCopierDictionary setObject:fileCopier forKey:encryptedFilePath];
            } else {
                [self.fileCopierDictionary removeObjectForKey:encryptedFilePath];
            }
            
        });
    }
}


- (void)copyItemAtFileSystemPath:(NSString *)fileSystemPath toEncryptedPath:(NSString *)encryptedPath completionQueue:(dispatch_queue_t)completionQueue completion:(void (^)(NSInteger, NSError *))completion
{
    if (!completion) {
        return;
    }
    
    if (!completionQueue) {
        completionQueue = dispatch_get_main_queue();
    }
    
    __weak typeof(self)weakSelf = self;
    __block IOFileCopier *fileCopier = [[IOFileCopier alloc] initWithFilePath:fileSystemPath toEncryptedPath:encryptedPath ioCipher:self completionQueue:dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0) completion:^(NSInteger bytesWritten, NSError *error) {
        
        __strong typeof(weakSelf)strongSelf = weakSelf;
        
        dispatch_async(completionQueue, ^{
            completion(bytesWritten, error);
        });
        
        [strongSelf setFileCopier:nil forEncryptedFilePath:fileCopier.encryptedFilePath];
        
        
    }];
    
    [self setFileCopier:fileCopier forEncryptedFilePath:fileCopier.encryptedFilePath];
    [fileCopier start];
    
}

- (NSString *)description {
    return [NSString stringWithFormat:@"%@\nOngoing Copy Operations: %lu",[super description],(unsigned long)[[self.fileCopierDictionary allKeys] count]];
}


@end
