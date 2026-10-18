// The vertical counterpart of the InstantSpaceSwitcher core's horizontal swipe (see
// Vendor/InstantSpaceSwitcher/ISS.c, `iss_post_dock_swipe`): the same events, with vertical
// motion, open Mission Control (up) or App Exposé (down) at once.

#include "MissionControlSwipe.h"
#include "../Vendor/InstantSpaceSwitcher/event_serialize.h"

#include <ApplicationServices/ApplicationServices.h>
#include <mach/mach_time.h>

static const CGEventField kCGSEventTypeField = (CGEventField)55;
static const CGEventField kCGEventGestureHIDType = (CGEventField)110;
static const CGEventField kCGEventGestureSwipeMotion = (CGEventField)123;
static const CGEventField kCGEventGestureSwipeProgress = (CGEventField)124;
static const CGEventField kCGEventGestureSwipePositionY = (CGEventField)126;
static const CGEventField kCGEventGestureSwipeVelocityX = (CGEventField)129;
static const CGEventField kCGEventGestureSwipeVelocityY = (CGEventField)130;
static const CGEventField kCGEventGesturePhase = (CGEventField)132;
static const CGEventField kCGEventGesturePhaseAlias = (CGEventField)134;
static const CGEventField kCGEventGestureZoomDeltaY = (CGEventField)138;
static const CGEventField kCGEventSourceUnixProcessIDAlias = (CGEventField)169;

static const int64_t kCGSEventGesture = 29;
static const int64_t kCGSEventDockControl = 30;
static const int64_t kIOHIDEventTypeDockSwipe = 23;
static const int64_t kGestureMotionVertical = 2;
static const int64_t kPhaseBegan = 1, kPhaseChanged = 2, kPhaseEnded = 4;

// Same magnitudes as the core: near-zero progress leaves nothing to animate, and the fling on
// the ended phase commits the gesture (16.16 fixed point on macOS 27, so it stays under ~32767).
static const double kProgress = 0.000016;
static const double kModernFlingVelocity = 9999.0;
static const double kLegacyFlingVelocity = 2000.0;

// The Dock reads the posted sign through the natural scrolling setting, like it does for spaces.
static double swipe_sign(bool up) {
    CFPreferencesAppSynchronize(kCFPreferencesAnyApplication);
    Boolean valid = false;
    Boolean natural = CFPreferencesGetAppBooleanValue(CFSTR("com.apple.swipescrolldirection"),
                                                      kCFPreferencesAnyApplication, &valid);
    const double sign = up ? 1.0 : -1.0;
    return (!valid || natural) ? -sign : sign;
}

static bool post_phase(int64_t phase, double sign) {
    const bool modern = iss_requires_event_augmentation();

    CGEventRef event = CGEventCreate(NULL);
    if (!event) {
        return false;
    }
    CGEventSetIntegerValueField(event, kCGSEventTypeField, kCGSEventDockControl);
    CGEventSetIntegerValueField(event, kCGEventGestureHIDType, kIOHIDEventTypeDockSwipe);
    CGEventSetIntegerValueField(event, kCGEventGesturePhase, phase);
    CGEventSetIntegerValueField(event, kCGEventGestureSwipeMotion, kGestureMotionVertical);
    CGEventSetDoubleValueField(event, kCGEventGestureSwipeProgress, sign * kProgress);

    if (!modern) {
        CGEventSetDoubleValueField(event, kCGEventGestureSwipeVelocityX, sign * kLegacyFlingVelocity);
        CGEventSetDoubleValueField(event, kCGEventGestureSwipeVelocityY, sign * kLegacyFlingVelocity);
        CGEventPost(kCGSessionEventTap, event);
        CFRelease(event);
        return true;
    }

    CGEventSetIntegerValueField(event, kCGEventGesturePhaseAlias, phase);
    CGEventSetDoubleValueField(event, kCGEventGestureZoomDeltaY, 3.0);
    CGEventSetDoubleValueField(event, kCGEventSourceUnixProcessIDAlias, (double)mach_absolute_time());
    CGEventSetDoubleValueField(event, kCGEventGestureSwipePositionY, 0.1);
    if (phase == kPhaseEnded) {
        CGEventSetDoubleValueField(event, kCGEventGestureSwipeVelocityY, sign * kModernFlingVelocity);
    }
    CGEventRef augmented = iss_augment_dock_swipe_event(event);
    CFRelease(event);
    if (!augmented) {
        return false;
    }

    // The Dock ignores a DockControl event without a companion gesture event.
    CGEventRef companion = CGEventCreate(NULL);
    if (!companion) {
        CFRelease(augmented);
        return false;
    }
    CGEventSetIntegerValueField(companion, kCGSEventTypeField, kCGSEventGesture);
    CGEventPost(kCGSessionEventTap, augmented);
    CGEventPost(kCGSessionEventTap, companion);
    CFRelease(augmented);
    CFRelease(companion);
    return true;
}

bool tb_post_vertical_dock_swipe(bool up) {
    const double sign = swipe_sign(up);
    return post_phase(kPhaseBegan, sign)
        && post_phase(kPhaseChanged, sign)
        && post_phase(kPhaseEnded, sign);
}
