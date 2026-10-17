//
//  Vendored from waydabber/AppleSiliconDDC (MIT).
//  Declares the private IOAVService C API used for DDC/CI over I2C on Apple Silicon,
//  exposed to Swift via this target's Objective-C bridging header.
//

#ifndef THETOOLBOX_APPLESILICONDDC_BRIDGING_H
#define THETOOLBOX_APPLESILICONDDC_BRIDGING_H

#import <Foundation/Foundation.h>
#import <IOKit/i2c/IOI2CInterface.h>
#import <CoreGraphics/CoreGraphics.h>

typedef CFTypeRef IOAVService;
extern IOAVService IOAVServiceCreate(CFAllocatorRef allocator);
extern IOAVService IOAVServiceCreateWithService(CFAllocatorRef allocator, io_service_t service);
extern IOReturn IOAVServiceReadI2C(IOAVService service, uint32_t chipAddress, uint32_t offset, void* outputBuffer, uint32_t outputBufferSize);
extern IOReturn IOAVServiceWriteI2C(IOAVService service, uint32_t chipAddress, uint32_t dataAddress, void* inputBuffer, uint32_t inputBufferSize);
extern CFDictionaryRef CoreDisplay_DisplayCreateInfoDictionary(CGDirectDisplayID);

// Instant space switching core, vendored from jurplel/InstantSpaceSwitcher. This is the
// target's only bridging header, so it's imported here too.
#import "../InstantSpaceSwitcher/include/ISS.h"

#endif /* THETOOLBOX_APPLESILICONDDC_BRIDGING_H */
