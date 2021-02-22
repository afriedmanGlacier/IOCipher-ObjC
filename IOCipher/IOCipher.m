//
//  IOCipher.m
//  Pods
//
//  Created by Christopher Ballinger on 1/20/15.
//
//

#import "IOCipher.h"
@import SQLCipher;
#import <libsqlfs/sqlfs.h>

/** Switches sign on sqlfs result codes */
static inline NSError* IOCipherPOSIXError(int code) {
    return [NSError errorWithDomain:NSPOSIXErrorDomain code:-code userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithUTF8String:strerror(code)]}];
}

@interface IOCipher()
@property (nonatomic, readonly) sqlfs_t *sqlfs;
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
        [self cleanUpWalFile:path password:password salt:nil];
        sqlfs_open_password([path UTF8String], [password UTF8String], &_sqlfs);

        _path = path;
        if (!_sqlfs) {
            return nil;
        }
    }
    
    return self;
}

- (void)cleanUpWalFile:(NSString *)path password:(NSString *)password salt:(NSString*)salt {
    NSError *error = nil;
    NSString *walPath = [path stringByAppendingString:@"-wal"];
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:walPath error:&error];

    if (error == nil && ((NSNumber *) attributes[NSFileSize]).longLongValue > 1 * 1024 * 1024) {
        // Quote from the SQLite documentation: "The only safe way to remove a WAL file is to open the database file
        // using one of the sqlite3_open() interfaces then immediately close the database using sqlite3_close()"
        if (salt != nil) {
            sqlfs_open_password_unencrypted_header([path UTF8String], [password UTF8String], [salt UTF8String], &_sqlfs);
        } else {
            sqlfs_open_password([path UTF8String], [password UTF8String], &_sqlfs);
        }
        sqlfs_close(_sqlfs);
    }
}

/** password should be UTF-8 */
- (instancetype) initWithPath:(NSString*)path password:(NSString*)password salt:(NSString*)salt {
    NSParameterAssert(path != nil);
    NSAssert(password.length > 0, @"password should have a non-zero length!");
    if (password.length == 0) {
        return nil;
    }
    
    if (self = [super init]) {
        [self cleanUpWalFile:path password:password salt:salt];
        if (salt != nil) {
            sqlfs_open_password_unencrypted_header([path UTF8String], [password UTF8String], [salt UTF8String], &_sqlfs);
        } else {
            sqlfs_open_password([path UTF8String], [password UTF8String], &_sqlfs);
        }
        _path = path;
        if (!_sqlfs) {
            return nil;
        }
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
        _path = path;
        if (!_sqlfs) {
            return nil;
        }
    }
    return self;
}

- (BOOL) setCipherCompatibility:(NSInteger)version {
    return sqlfs_set_cipher_compatibility(_sqlfs, version);
}

- (BOOL) changePassword:(NSString *)newPassword oldPassword:(NSString *)oldPassword
{
    NSParameterAssert(oldPassword != nil);
    if (sqlfs_close(self.sqlfs)) {
        _sqlfs = nil;
        int changeResult = sqlfs_change_password([self.path UTF8String], [oldPassword UTF8String], [newPassword UTF8String]);
        if (changeResult) {
            sqlfs_open_password([self.path UTF8String], [newPassword UTF8String], &_sqlfs);
            if (_sqlfs) {
                return YES;
            }
        }
    }
    return NO;
}

- (BOOL) changeKey:(NSData *)newKey oldKey:(NSData *)oldkey
{
    NSAssert(newKey.length == 32, @"key must be 32 bytes");
    NSParameterAssert(oldkey != nil);
    if (sqlfs_close(self.sqlfs)) {
        _sqlfs = nil;
        int changeResult = sqlfs_rekey([self.path UTF8String], [oldkey bytes], oldkey.length, [newKey bytes], newKey.length);
        if (changeResult) {
            sqlfs_open_key([self.path UTF8String], [newKey bytes], newKey.length, &_sqlfs);
            if (_sqlfs) {
                return YES;
            }
        }
    }
    return NO;
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

- (NSData*) readDataFromFileAtPath:(NSString *)path
                         error:(NSError **)error
{
    NSError *err = nil;
    NSDictionary *attributes = [self fileAttributesAtPath:path error:&err];
    if (err) {
        if (error) {
            *error = err;
        }
        return nil;
    }
    NSNumber *fileSize = attributes[NSFileSize];
    return [self readDataFromFileAtPath:path length:fileSize.unsignedIntegerValue offset:0 error:error];
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

- (BOOL)vacuum {
    return sqlfs_vacuum(NULL) == SQLITE_OK;
}

#pragma - mark File Copying


- (BOOL)copyItemAtFileSystemPath:(NSString *)fileSystemPath toEncryptedPath:(NSString *)encryptedPath error:(NSError *__autoreleasing *)error
{
    
    NSInputStream *inputStream = [[NSInputStream alloc] initWithFileAtPath:fileSystemPath];
    [inputStream open];
    
    NSUInteger bytesWritten = 0;
    
    BOOL success = YES;
    while (inputStream.hasBytesAvailable && success) {
        int bufferLength = 4096;
        uint8_t buf[bufferLength];
        NSInteger length = 0;
        length = [inputStream read:buf maxLength:bufferLength];
        if(length) {
            NSData *data = [NSData dataWithBytes:(const void *)buf length:length];
            NSUInteger wroteBytes = [self writeDataToFileAtPath:encryptedPath
                                            data:data
                                          offset:bytesWritten
                                           error:error];
            if (wroteBytes > 0 && !*error) {
                bytesWritten += wroteBytes;
            }
            else {
                success = NO;
            }
        }
    }
    return success;
}

//see https://github.com/sqlcipher/sqlcipher/issues/255 
const NSUInteger kSqliteHeaderLength = 32;
const NSUInteger kSQLCipherSaltLength = 16;

+ (nullable NSError *)convertDatabaseIfNecessary:(NSString *)databaseFilePath
                                databasePassword:(NSString *)databasePassword
                                       saltBlock:(IOCipherSaltBlock)saltBlock
{
    NSParameterAssert(databaseFilePath.length > 0);
    NSParameterAssert(databasePassword.length > 0);
    NSParameterAssert(saltBlock);
    
    if ([self doesDatabaseNeedToBeConverted:databaseFilePath]) {
        NSData *saltData;
        {
            NSData *headerData = [self readFirstNBytesOfDatabaseFile:databaseFilePath byteCount:kSqliteHeaderLength];
            NSParameterAssert(headerData);

            NSParameterAssert(headerData.length >= kSQLCipherSaltLength);
            saltData = [headerData subdataWithRange:NSMakeRange(0, kSQLCipherSaltLength)];

            // Make sure we successfully persist the salt (persumably in the keychain) before
            // proceeding with the database conversion or we could leave the app in an
            // unrecoverable state.
            saltBlock(saltData);
        }
        NSString *salt = [NSString stringWithFormat:@"x'%@'", [self hexadecimalStringForData:saltData]];
        
        
        sqlfs_t *sqlfstemp;
        int result = sqlfs_migrate_to_unencrypted_header([databaseFilePath UTF8String], [databasePassword UTF8String], [salt UTF8String], &sqlfstemp);
        if (result != SQLITE_OK) {
            return IOCipherPOSIXError(result);
        }
        sqlfs_close(sqlfstemp);
    }
    return nil;
}

+ (NSString *)hexadecimalStringForData:(NSData *)data {
    /* Returns hexadecimal string of NSData. Empty string if data is empty. */
    const unsigned char *dataBuffer = (const unsigned char *)[data bytes];
    if (!dataBuffer) {
        return @"";
    }
    
    NSUInteger dataLength = [data length];
    NSMutableString *hexString = [NSMutableString stringWithCapacity:(dataLength * 2)];
    
    for (NSUInteger i = 0; i < dataLength; ++i) {
        [hexString appendFormat:@"%02x", dataBuffer[i]];
    }
    return [hexString copy];
}

+ (BOOL)doesDatabaseNeedToBeConverted:(NSString *)databaseFilePath
{
    NSParameterAssert(databaseFilePath != nil);

    if (![[NSFileManager defaultManager] fileExistsAtPath:databaseFilePath]) {
        NSLog(@"database file not found.");
        return nil;
    }

    NSData *headerData = [self readFirstNBytesOfDatabaseFile:databaseFilePath byteCount:kSqliteHeaderLength];
    NSParameterAssert(headerData != nil);

    NSString *kUnencryptedHeader = @"SQLite format 3\0";
    NSData *unencryptedHeaderData = [kUnencryptedHeader dataUsingEncoding:NSUTF8StringEncoding];
    BOOL isUnencrypted = [unencryptedHeaderData
        isEqualToData:[headerData subdataWithRange:NSMakeRange(0, unencryptedHeaderData.length)]];
    if (isUnencrypted) {
        NSLog(@"doesDatabaseNeedToBeConverted; legacy database header already decrypted.");
        return NO;
    }

    return YES;
}

+ (NSData *)readFirstNBytesOfDatabaseFile:(NSString *)filePath byteCount:(NSUInteger)byteCount
{
    @autoreleasepool {
        NSError *error;
        // Use memory-mapped NSData to avoid reading the entire file into memory.
        //
        // We use NSDataReadingMappedAlways instead of NSDataReadingMappedIfSafe because
        // we know the database will always exist for the duration of this instance of NSData.
        NSData *_Nullable data = [NSData dataWithContentsOfURL:[NSURL fileURLWithPath:filePath]
                                                       options:NSDataReadingMappedAlways
                                                         error:&error];
        if (!data || error) {
            NSLog(@"Couldn't read database file header.");
            [NSException raise:@"Couldn't read database file header" format:@""];
        }
        // Pull this constant out so that we can use it in our YapDatabase fork.
        NSData *_Nullable headerData = [data subdataWithRange:NSMakeRange(0, byteCount)];
        if (!headerData || headerData.length != byteCount) {
            [NSException raise:@"Database file header has unexpected length" format:@"Database file header has unexpected length: %zd", headerData.length];
        }
        return [headerData copy];
    }
}

@end
