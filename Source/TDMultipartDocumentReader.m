//
//  TDMultipartDocumentReader.m
//  
//
//  Created by Jens Alfke on 3/29/12.
//  Copyright (c) 2012 Couchbase, Inc. All rights reserved.
//

#import "TDMultipartDocumentReader.h"
#import "TDDatabase+Attachments.h"
#import "TDBlobStore.h"
#import "TDInternal.h"
#import "TDBase64.h"
#import "TDMisc.h"
#import "CollectionUtils.h"


@implementation TDMultipartDocumentReader


+ (NSDictionary*) readData: (NSData*)data
                    ofType: (NSString*)contentType
                toDatabase: (TDDatabase*)database
                    status: (int*)outStatus
{
    NSDictionary* result = nil;
    TDMultipartDocumentReader* reader = [[self alloc] initWithDatabase: database];
    if ([reader setContentType: contentType]
            && [reader appendData: data]
            && [reader finish]) {
        result = [[reader.document retain] autorelease];
    }
    if (outStatus)
        *outStatus = reader.status;
    [reader release];
    return result;
}



- (id) initWithDatabase: (TDDatabase*)database
{
    Assert(database);
    self = [super init];
    if (self) {
        _database = database;
    }
    return self;
}


- (void) dealloc {
    [_curAttachment cancel];
    [_curAttachment release];
    [_multipartReader release];
    [_jsonBuffer release];
    [_document release];
    [_attachmentsByName autorelease];
    [_attachmentsByDigest autorelease];
    [super dealloc];
}


@synthesize status=_status, document=_document;


- (NSUInteger) attachmentCount {
    return _attachmentsByDigest.count;
}


- (BOOL) setContentType: (NSString*)contentType {
    if ([contentType hasPrefix: @"multipart/"]) {
        // Multipart, so initialize the parser:
        LogTo(SyncVerbose, @"%@: has attachments, %@", self, contentType);
        _multipartReader = [[TDMultipartReader alloc] initWithContentType: contentType delegate: self];
        if (_multipartReader) {
            _attachmentsByName = [[NSMutableDictionary alloc] init];
            _attachmentsByDigest = [[NSMutableDictionary alloc] init];
            return YES;
        }
    } else if (contentType == nil || [contentType hasPrefix: @"application/json"]) {
        // No multipart, so no attachments. Body is pure JSON:
        _jsonBuffer = [[NSMutableData alloc] initWithCapacity: 1024];
        return YES;
    }
    // Unknown/invalid MIME type:
    _status = 406;
    return NO;
}


- (BOOL) appendData:(NSData *)data {
    if (_multipartReader) {
        [_multipartReader appendData: data];
        if (_multipartReader.failed) {
            Warn(@"%@: received unparseable MIME multipart response", self);
            _status = 502;
            return NO;
        }
    } else {
        [_jsonBuffer appendData: data];
    }
    return YES;
}


- (BOOL) finish {
    LogTo(SyncVerbose, @"%@: Finished loading (%u attachments)", self, _attachmentsByDigest.count);
    if (_multipartReader) {
        if (!_multipartReader.finished) {
            Warn(@"%@: received incomplete MIME multipart response", self);
            _status = 502;
            return NO;
        }
        
        if (![self registerAttachments]) {
            _status = 400;
            return NO;
        }
    } else {
        if (![self parseJSONBuffer])
            return NO;
    }
    _status = 201;
    return YES;
}


#pragma mark - MIME PARSER CALLBACKS:


/** Callback: A part's headers have been parsed, but not yet its data. */
- (void) startedPart: (NSDictionary*)headers {
    // First MIME part is the document's JSON body; the rest are attachments.
    if (!_document)
        _jsonBuffer = [[NSMutableData alloc] initWithCapacity: 1024];
    else {
        LogTo(SyncVerbose, @"%@: Starting attachment #%u...", self, _attachmentsByDigest.count + 1);
        _curAttachment = [[_database attachmentWriter] retain];
        
        // See whether the attachment name is in the headers.
        NSString* disposition = [headers objectForKey: @"Content-Disposition"];
        if ([disposition hasPrefix: @"attachment; filename="]) {
            // TODO: Parse this less simplistically. Right now it assumes it's in exactly the same
            // format generated by -[TDPusher uploadMultipartRevision:]. CouchDB (as of 1.2) doesn't
            // output any headers at all on attachments so there's no compatibility issue yet.
            NSString* name = TDUnquoteString([disposition substringFromIndex: 21]);
            if (name)
                [_attachmentsByName setObject: _curAttachment forKey: name];
        }
    }
}


/** Callback: Append data to a MIME part's body. */
- (void) appendToPart: (NSData*)data {
    if (_jsonBuffer)
        [_jsonBuffer appendData: data];
    else
        [_curAttachment appendData: data];
}


/** Callback: A MIME part is complete. */
- (void) finishedPart {
    if (_jsonBuffer) {
        [self parseJSONBuffer];
    } else {
        // Finished downloading an attachment. Remember the association from the MD5 digest
        // (which appears in the body's _attachments dict) to the blob-store key of the data.
        [_curAttachment finish];
        NSString* md5Str = _curAttachment.MD5DigestString;
#ifndef MY_DISABLE_LOGGING
        if (WillLogTo(SyncVerbose)) {
            TDBlobKey key = _curAttachment.blobKey;
            NSData* keyData = [NSData dataWithBytes: &key length: sizeof(key)];
            LogTo(SyncVerbose, @"%@: Finished attachment #%u: len=%uk, digest=%@, SHA1=%@",
                  self, _attachmentsByDigest.count+1, (unsigned)_curAttachment.length/1024,
                  md5Str, keyData);
        }
#endif
        [_attachmentsByDigest setObject: _curAttachment forKey: md5Str];
        setObj(&_curAttachment, nil);
    }
}


#pragma mark - INTERNALS:


- (BOOL) parseJSONBuffer {
    id document = [TDJSON JSONObjectWithData: _jsonBuffer
                                     options: TDJSONReadingMutableContainers
                                       error: nil];
    setObj(&_jsonBuffer, nil);
    if (![document isKindOfClass: [NSDictionary class]]) {
        Warn(@"%@: received unparseable JSON data '%@'",
             self, [_jsonBuffer my_UTF8ToString]);
        _status = 502;
        return NO;
    }
    _document = [document retain];
    return YES;
}


- (BOOL) registerAttachments {
    NSDictionary* attachments = [_document objectForKey: @"_attachments"];
    if (![attachments isKindOfClass: [NSDictionary class]]) 
        return NO;
    NSUInteger nAttachmentsInDoc = 0;
    for (NSString* attachmentName in attachments) {
        NSMutableDictionary* attachment = [attachments objectForKey: attachmentName];
        if ([[attachment objectForKey: @"follows"] isEqual: $true]) {
            // Check that each attachment in the JSON corresponds to an attachment MIME body.
            // Look up the attachment by either its MIME Content-Disposition header or MD5 digest:
            NSString* digest = [attachment objectForKey: @"digest"];
            TDBlobStoreWriter* writer = [_attachmentsByName objectForKey: attachmentName];
            if (writer) {
                NSString* actualDigest = writer.MD5DigestString;
                if (digest && !$equal(digest, actualDigest) 
                           && !$equal(digest, writer.SHA1DigestString)) {
                    Log(@"TDMultipartDocumentReader: Attachment '%@' has incorrect MD5 digest "
                         "(%@; should be %@)",
                         attachmentName, digest, actualDigest);
                    return NO;
                }
                [attachment setObject: actualDigest forKey: @"digest"];
            } else {
                writer = [_attachmentsByDigest objectForKey: digest];
                if (!writer) {
                    Warn(@"TDMultipartDocumentReader: Attachment '%@' does not appear in a MIME body",
                         attachmentName);
                    return NO;
                }
            }
            
            // Check that the length matches:
            NSNumber* lengthObj = [attachment objectForKey: @"encoded_length"]
                               ?: [attachment objectForKey: @"length"];
            if (!lengthObj)
                return NO;
            if (writer.length != [$castIf(NSNumber, lengthObj) unsignedLongLongValue])
                return NO;
            ++nAttachmentsInDoc;
        }
    }
    if (nAttachmentsInDoc < _attachmentsByDigest.count)
        return NO;  // Some MIME bodies didn't match attachments in the document
    // If everything's copacetic, hand over the (uninstalled) blobs to the database to remember:
    [_database rememberAttachmentWritersForDigests: _attachmentsByDigest];
    return YES;
}


@end