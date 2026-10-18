#ifndef MISSION_CONTROL_SWIPE_H
#define MISSION_CONTROL_SWIPE_H

#include <stdbool.h>

/// Opens Mission Control (`up`) or App Exposé (`!up`) by posting a synthetic vertical Dock swipe
/// with a strong fling, which skips the zoom animation. Needs Accessibility.
bool tb_post_vertical_dock_swipe(bool up);

#endif
