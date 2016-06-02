/*
 
 CEDocumentAnalyzer.h
 
 CotEditor
 http://coteditor.com
 
 Created by 1024jp on 2014-12-18.

 ------------------------------------------------------------------------------
 
 © 2014-2016 1024jp
 
 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at
 
 http://www.apache.org/licenses/LICENSE-2.0
 
 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
 
 */

@import Cocoa;


// notifications
extern NSString *_Nonnull const CEAnalyzerDidUpdateFileInfoNotification;
extern NSString *_Nonnull const CEAnalyzerDidUpdateModeInfoNotification;
extern NSString *_Nonnull const CEAnalyzerDidUpdateEditorInfoNotification;


@class CEDocument;


@interface CEDocumentAnalyzer : NSObject

@property (nonatomic) BOOL needsUpdateEditorInfo;  // need to update all editor info
@property (nonatomic) BOOL needsUpdateStatusEditorInfo; // need only to update editor info in satus bar

// file info
@property (readonly, nonatomic, nullable, copy) NSDate *creationDate;
@property (readonly, nonatomic, nullable, copy) NSDate *modificationDate;
@property (readonly, nonatomic, nullable, copy) NSNumber *fileSize;
@property (readonly, nonatomic, nullable, copy) NSString *filePath;
@property (readonly, nonatomic, nullable, copy) NSString *owner;
@property (readonly, nonatomic, nullable, copy) NSNumber *permission;
@property (readonly, nonatomic, getter=isReadOnly) BOOL readOnly;

// mode info
@property (readonly, nonatomic, nullable, copy) NSString *encoding;
@property (readonly, nonatomic, nullable, copy) NSString *charsetName;
@property (readonly, nonatomic, nullable, copy) NSString *lineEndings;

// editor info
@property (readonly, nonatomic, nullable, copy) NSString *lines;
@property (readonly, nonatomic, nullable, copy) NSString *chars;
@property (readonly, nonatomic, nullable, copy) NSString *words;
@property (readonly, nonatomic, nullable, copy) NSString *length;
@property (readonly, nonatomic, nullable, copy) NSString *location;  // caret location from the beginning of document
@property (readonly, nonatomic, nullable, copy) NSString *line;      // current line
@property (readonly, nonatomic, nullable, copy) NSString *column;    // caret location from the beginning of line
@property (readonly, nonatomic, nullable, copy) NSString *unicode;   // Unicode of selected single character (or surrogate-pair)


// initializer
- (nonnull instancetype)initWithDocument:(nonnull CEDocument *)document;

// Public Methods
- (void)invalidateFileInfo;
- (void)invalidateModeInfo;

- (void)invalidateEditorInfo;

@end
