//
//  BXPrintSession.m
//  Boxer
//
//  Created by Alun Bestor on 04/11/2012.
//  Copyright (c) 2012 Alun Bestor and contributors. All rights reserved.
//

#import "BXPrintSession.h"

@interface BXPrintSession ()

//Overridden to make these properties read-write.
@property (assign, nonatomic) BOOL pageInProgress;
@property (assign, nonatomic, getter=isFinished) BOOL finished;
@property (assign, nonatomic) NSSize previewDPI;
@property (assign, nonatomic) NSUInteger numPages;
@property (retain, nonatomic) NSGraphicsContext *previewContext;
@property (retain, nonatomic) NSGraphicsContext *PDFContext;

//Mutable internal versions of the readonly accessors we've exposed in the public API.
@property (retain, nonatomic) NSMutableData *_mutablePDFData;
@property (retain, nonatomic) NSMutableArray *_mutablePagePreviews;

//The bitmap canvas into which to draw the current page preview.
@property (retain, nonatomic) NSBitmapImageRep *_previewCanvas;


//Called when the session is created to create a PDF context and data backing.
- (void) _preparePDFContext;

//Called when the preview context is first accessed or the preview backing has changed,
//to create a new bitmap context that will write to the backing.
- (void) _preparePreviewContext;

@end


@implementation BXPrintSession
@synthesize PDFContext = _PDFContext;
@synthesize previewContext = _previewContext;
@synthesize _previewCanvas = _previewCanvas;
@synthesize _mutablePDFData = _PDFData;
@synthesize _mutablePagePreviews = _pagePreviews;

@synthesize pageInProgress = _pageInProgress;
@synthesize finished = _finished;
@synthesize numPages = _numPages;
@synthesize previewDPI = _previewDPI;

#pragma mark -
#pragma mark Starting and ending sessions

+ (NSDictionary *) _defaultPDFInfo
{
    return [NSDictionary dictionaryWithObjectsAndKeys:
            nil];
}

- (id) init
{
    self = [super init];
    if (self)
    {
        self.numPages = 0;
        
        //Generate 72dpi previews by default.
        self.previewDPI = NSMakeSize(72.0, 72.0);
        
        //Create a catching array for our page previews.
        self._mutablePagePreviews = [NSMutableArray arrayWithCapacity: 1];
        
        //Create the PDF context for this session.
        [self _preparePDFContext];
    }
    
    return self;
}

- (void) _preparePDFContext
{
    //Create a new PDF context and its associated data object,
    //into which we shall pour PDF data from the context.
    self._mutablePDFData = [NSMutableData data];
    _PDFDataConsumer = CGDataConsumerCreateWithCFData((CFMutableDataRef)self._mutablePDFData);
    _CGPDFContext = CGPDFContextCreate(_PDFDataConsumer, NULL, (CFDictionaryRef)[self.class _defaultPDFInfo]);
    
    self.PDFContext = [NSGraphicsContext graphicsContextWithGraphicsPort: _CGPDFContext
                                                                 flipped: NO];
    
    //While we're here, set up some properties of the context.
    //Use multiply blending so that overlapping printed colors will darken each other.
    CGContextSetBlendMode(_CGPDFContext, kCGBlendModeMultiply);
}

- (void) _preparePreviewContext
{
    self.previewContext = [NSGraphicsContext graphicsContextWithBitmapImageRep: self._previewCanvas];
    _previewCanvasBacking = self._previewCanvas.bitmapData;
    
    //While we're here, set some properties of the context.
    //Use multiply blending so that overlapping printed colors will darken each other
    CGContextSetBlendMode((CGContextRef)(_previewContext.graphicsPort), kCGBlendModeMultiply);
    
    //TODO: if previewDPI does not match the default number of points per inch (72x72),
    //scale up the context transform to compensate.
}

- (void) finishSession
{
    NSAssert(!self.isFinished, @"finishSession called on an already finished print session.");
    
    //Finish up the current page if one was in progress.
    if (self.pageInProgress)
        [self finishPage];
    
    //Tear down the PDF context. This will leave our PDF data intact,
    //but ensures no more data can be written.
    CGPDFContextClose(_CGPDFContext);
    CGContextRelease(_CGPDFContext);
    CGDataConsumerRelease(_PDFDataConsumer);
    
    _CGPDFContext = nil;
    _PDFDataConsumer = nil;
    self.PDFContext = nil;
    
    self.finished = YES;
}

- (void) dealloc
{
    if (!self.isFinished)
        [self finishSession];
    
    self._mutablePDFData = nil;
    self._mutablePagePreviews = nil;
    self._previewCanvas = nil;
    self.previewContext = nil;
    
    [super dealloc];
}

#pragma mark -
#pragma mark Starting and ending pages

- (void) beginPageWithSize: (NSSize)size
{
    NSAssert(!self.pageInProgress, @"beginPageWithSize: called while a page was already in progress.");
    NSAssert(!self.isFinished, @"beginPageWithSize: called on a session that's already finished.");
    
    if (NSEqualSizes(size, NSZeroSize))
        size = NSMakeSize(8.5, 11.0);
    
    //N.B: we could use CGPDFContextBeginPage but that has a more complicated
    //calling structure for specifying art, crop etc. boxes, and we only care
    //about the media box.
    CGRect mediaBox = CGRectMake(0, 0, size.width * 72.0, size.height * 72.0);
    CGContextBeginPage(_CGPDFContext, &mediaBox);
    
    //Prepare a new preview image
    NSSize canvasSize = NSMakeSize(ceil(size.width * self.previewDPI.width),
                                   ceil(size.height * self.previewDPI.height));
    
    //Add a custom representation to this image into which we'll draw the page preview.
    self._previewCanvas = [[[NSBitmapImageRep alloc] initWithBitmapDataPlanes: NULL
                                                                   pixelsWide: canvasSize.width
                                                                   pixelsHigh: canvasSize.height
                                                                bitsPerSample: 8
                                                              samplesPerPixel: 4
                                                                     hasAlpha: YES
                                                                     isPlanar: NO
                                                               colorSpaceName: NSDeviceRGBColorSpace
                                                                  bytesPerRow: 0
                                                                 bitsPerPixel: 0] autorelease];
    
    NSImage *preview = [[[NSImage alloc] initWithSize: canvasSize] autorelease];
    [preview addRepresentation: self._previewCanvas];
    
    //Add the new image into the array of page previews.
    [self._mutablePagePreviews addObject: preview];
    
    self.pageInProgress = YES;
    self.numPages++;
}

- (void) finishPage
{
    NSAssert(self.pageInProgress, @"finishPage called while no page was in progress.");
    
    //Close the page in the current PDF context.
    CGPDFContextEndPage(_CGPDFContext);
    
    //Tear down the current preview context.
    self.previewContext = nil;
    self._previewCanvas = nil;
    _previewCanvasBacking = NULL;
    
    self.pageInProgress = NO;
}

- (void) insertBlankPageWithSize: (NSSize)size
{
    [self beginPageWithSize: size];
    [self finishPage];
}


#pragma mark -
#pragma mark Property accessors

- (NSData *) PDFData
{
    //Do not expose PDF data until the session has been finalised.
    if (!self.isFinished)
        return nil;
    
    return self._mutablePDFData;
}

- (NSArray *) pagePreviews
{
    return self._mutablePagePreviews;
}

//Dynamically create a new preview context the first time we need one,
//or if the backing canvas has changed location since we last checked.
- (NSGraphicsContext *) previewContext
{
    if (!self.pageInProgress)
        return NULL;
    
    //Create a new graphics context with which we can draw into the canvas image.
    //IMPLEMENTATION NOTE: in 10.8, NSBitmapImageRep may sometimes change its backing on the fly
    //without telling the graphics context about it. So we also check if the backing appears to have
    //changed since the last time and if it has, we recreate the context.
    if (!_previewContext || _previewCanvasBacking != self._previewCanvas.bitmapData)
    {
        [self _preparePreviewContext];
    }
    
    return [[_previewContext retain] autorelease];
}

- (NSImage *) currentPagePreview
{
    if (self.pageInProgress)
        return self.pagePreviews.lastObject;
    else
        return nil;
}

@end
