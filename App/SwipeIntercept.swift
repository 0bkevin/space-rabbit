/*
 * SwipeIntercept.swift — Instant trackpad gesture interception
 *
 * Removes the slide animation from real horizontal Space swipes and the
 * Mission Control entry and dismissal gestures.
 *
 * macOS turns 3-finger (or 4-finger, per the trackpad setting) swipes into
 * private DockSwipe events — the same event family Space Rabbit synthesizes
 * for its other features. A second CGEvent tap listens for those private
 * gesture event types and replaces supported physical gestures with complete
 * synthetic gestures posted at their committed endpoint.
 *
 *   1. Began   — start tracking, swallow (the animated switch never starts)
 *   2. Changed — first non-zero progress reveals the direction; fire the
 *                instant switch once, keep swallowing
 *   3. Ended   — fallback: if nothing fired yet (a very quick flick can
 *                skip Changed), use the final velocity's sign; reset
 *   4. Cancelled — reset without firing
 *
 * Horizontal swipes keep the existing direction-detection flow. A vertical
 * swipe is identifiable from the Began event's swipe mask/flags, so its
 * replacement is prepared and posted before the native transition gets a
 * progress sample. Downward App Exposé from the desktop remains native;
 * downward dismissal is claimed only when Mission Control is active.
 *
 * Because Space Rabbit's own synthetic gestures are posted into the same
 * session tap, they would loop right back into this tap. Every event we
 * post is stamped with `kSyntheticGestureMarker` in its source user-data
 * field and waved straight through on the way back in.
 *
 * (joshuarli/iss, from which this interception scheme is ported, counts
 * pending synthetic events instead. That cannot work here: the real
 * gesture's own Changed samples match the same event subtypes, so they
 * drain the counter before our synthetic events arrive, and the leftover
 * synthetic Ended is then read as a real swipe — firing a second switch
 * from its ±kInstantSwitchVelocity sign.)
 *
 * Unlike the keyboard tap (installed once at startup), this tap is created
 * and torn down on demand: gesture events are high-frequency while fingers
 * touch the pad, so the tap only exists while the feature is active.
 */

import CoreGraphics
import Foundation

// MARK: - Constants

/// Value of `kCGEventGestureSwipeMotion` identifying a horizontal swipe.
private let kGestureMotionHorizontal: Int64 = 1

/// Value identifying the vertical DockSwipe family used by Mission Control
/// and App Exposé.
private let kGestureMotionVertical: Int64 = 2

/// IOHID swipe-mask bits identifying vertical gesture direction.
private let kSwipeMaskUp: Int64 = 1
private let kSwipeMaskDown: Int64 = 2

// MARK: - Tap Lifecycle

/// Creates or tears down the swipe-intercept tap to match the current
/// feature state (`gEnabled` and either gesture feature enabled).
///
/// Called at startup and from every place that flips either toggle (the
/// menu bar dropdown, the master switch, and the settings window). Safe to
/// call redundantly — it no-ops when the tap already matches the state.
func updateSwipeTap() {
    let shouldRun = gEnabled
        && (gTrackpadSwipeEnabled || gInstantMissionControlEnabled)

    if shouldRun, gSwipeTap == nil {
        let mask = CGEventMask((1 << UInt64(kCGSEventGesture))
                             | (1 << UInt64(kCGSEventDockControl)))

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: swipeTapCallback,
            userInfo: nil
        ), let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
            fputs("Space Rabbit: failed to create swipe intercept tap\n", stderr)
            return
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        gSwipeTap       = tap
        gSwipeTapSource = source
        resetSwipeIntercept()
    } else if !shouldRun, let tap = gSwipeTap {
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source = gSwipeTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }

        gSwipeTap       = nil
        gSwipeTapSource = nil
        resetSwipeIntercept()
    }
}

/// Clears all per-gesture tracking state. Called whenever the tap's
/// continuity breaks (created, torn down, or re-enabled after a system
/// disable) — stale state from before the break must not leak into the
/// next gesture.
func resetSwipeIntercept() {
    gSwipeTracking               = false
    gSwipeFired                  = false
    gMissionControlSwipeTracking = false
}

// MARK: - Synthetic Event Marking

/// Stamped into `.eventSourceUserData` on every gesture event Space Rabbit
/// posts, so the swipe tap can recognise its own events on the way back in.
/// The field is carried by the event record and survives the round trip
/// through the session tap (including the macOS 27+ flatten/rebuild in
/// `augmentDockSwipeEvent`, which is applied after the stamp).
private let kSyntheticGestureMarker: Int64 = 0x5350_4152  // 'SPAR'

/// Marks an event as posted by Space Rabbit, so the swipe-intercept tap
/// passes it through instead of re-intercepting it (which would loop:
/// intercept → post → intercept → …).
///
/// Called by the gesture posting code in SpaceSwitching.swift on every
/// event before it goes out — unconditionally, whether or not the tap is
/// currently installed, so a tap installed mid-sequence still recognises
/// events already in flight.
///
/// - Parameter event: The gesture or dock-control event about to be posted.
func markSyntheticGesture(_ event: CGEvent) {
    event.setIntegerValueField(.eventSourceUserData, value: kSyntheticGestureMarker)
}

/// Whether an incoming event is one Space Rabbit posted itself.
///
/// - Parameter event: The event delivered to the swipe tap.
/// - Returns: `true` when the event carries `kSyntheticGestureMarker`.
private func isSyntheticGesture(_ event: CGEvent) -> Bool {
    event.getIntegerValueField(.eventSourceUserData) == kSyntheticGestureMarker
}

// MARK: - Swipe Tap Callback
//
// C-compatible global function, same constraint as eventTapCallback:
// the CGEvent API requires a plain function pointer.

/// CGEvent tap callback that intercepts real horizontal DockSwipe gestures
/// and replaces them with instant switches.
///
/// - Parameters:
///   - proxy: The event tap proxy (unused).
///   - type: The event type — the private gesture types arrive as raw
///     values 29/30, plus the tap-disabled housekeeping types.
///   - event: The intercepted event.
///   - userInfo: User-provided context pointer (unused).
/// - Returns: The event to pass downstream, or `nil` to swallow it.
func swipeTapCallback(proxy: CGEventTapProxy, type: CGEventType,
                      event: CGEvent, userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    let passthrough = Unmanaged.passUnretained(event)

    // Re-enable the tap if macOS disabled it, and drop any half-tracked
    // gesture: its remaining events were delivered while we were deaf,
    // so finishing it coherently is no longer possible.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        resetSwipeIntercept()
        if let tap = gSwipeTap { CGEvent.tapEnable(tap: tap, enable: true) }
        return passthrough
    }

    // Space Rabbit's own synthetic gestures (posted by any feature) land
    // in this same session tap — wave them straight through, or they would
    // be read as real swipes and fire a switch of their own.
    if isSyntheticGesture(event) { return passthrough }

    let subtype = event.getIntegerValueField(kCGSEventTypeField)

    // The tap is normally torn down while the master switch is off; this
    // guard covers a toggle racing with event delivery.
    guard gEnabled else {
        resetSwipeIntercept()
        return passthrough
    }

    // Once a Mission Control transition is claimed, swallow every remaining dock and
    // companion event from that physical sequence. The synthetic replacement
    // has already delivered its own complete Began/Changed/Ended sequence.
    if gMissionControlSwipeTracking {
        if subtype == kCGSEventDockControl {
            let phase = event.getIntegerValueField(kCGEventGesturePhase)
            if phase == kCGSGesturePhaseEnded || phase == kCGSGesturePhaseCancelled {
                gMissionControlSwipeTracking = false
            }
            return nil
        }
        if subtype == kCGSEventGesture { return nil }
    }

    // Claim upward swipes only from the desktop, and downward swipes only
    // while Mission Control specifically (not App Exposé or Show Desktop) is
    // active. Horizontal gestures still stand down in every overview, keeping
    // the issue #18/#20 safety behavior intact.
    if gInstantMissionControlEnabled,
       subtype == kCGSEventDockControl,
       event.getIntegerValueField(kCGEventGestureHIDType) == kIOHIDEventTypeDockSwipe,
       event.getIntegerValueField(kCGEventGestureSwipeMotion) == kGestureMotionVertical,
       event.getIntegerValueField(kCGEventGesturePhase) == kCGSGesturePhaseBegan,
       let opening = verticalSwipeOpensMissionControl(event) {
        let overviewActive = isMissionControlActive()
        let shouldHandle = opening
            ? !overviewActive
            : overviewActive && isMissionControlOverviewActive()

        guard shouldHandle else { return passthrough }

        // postInstantMissionControlGesture() constructs every phase before it
        // posts anything. If construction or augmentation fails, leave the
        // physical Began untouched so macOS performs its native transition.
        if postInstantMissionControlGesture(opening: opening) {
            gMissionControlSwipeTracking = true
            return nil
        }
        return passthrough
    }

    // Horizontal feature gates. Mission Control interception is independent
    // from both this toggle and the Space transition-speed slider.
    guard gTrackpadSwipeEnabled, !isNativeSwitchSpeed() else {
        gSwipeTracking = false
        gSwipeFired    = false
        return passthrough
    }

    // Horizontal dock swipes only; unclaimed vertical gestures and every
    // other gesture pass through unchanged.
    if subtype == kCGSEventDockControl,
       event.getIntegerValueField(kCGEventGestureHIDType) == kIOHIDEventTypeDockSwipe,
       event.getIntegerValueField(kCGEventGestureSwipeMotion) == kGestureMotionHorizontal {

        let phase = event.getIntegerValueField(kCGEventGesturePhase)

        if phase == kCGSGesturePhaseBegan {
            // Mission Control slides its own carousel from this gesture —
            // see isMissionControlActive(). Stand down for the whole swipe
            // by not tracking it: every later phase then passes through
            // untouched, so the window-list lookup runs once per gesture
            // rather than for every high-frequency sample.
            guard !isMissionControlActive() else { return passthrough }

            gSwipeTracking = true
            gSwipeFired    = false
            return nil
        }

        if phase == kCGSGesturePhaseChanged, gSwipeTracking {
            // Fire once, on the first sample that reveals the direction
            if !gSwipeFired {
                let progress = event.getDoubleValueField(kCGEventGestureSwipeProgress)
                if progress != 0 {
                    gSwipeFired = true
                    performSwipeSwitch(isRight: isRightSwipe(progress))
                }
            }
            return nil
        }

        if phase == kCGSGesturePhaseEnded, gSwipeTracking {
            // A very quick flick can end before any Changed sample carried
            // progress — fall back to the final velocity's sign.
            if !gSwipeFired {
                let velocity = event.getDoubleValueField(kCGEventGestureSwipeVelocityX)
                if velocity != 0 { performSwipeSwitch(isRight: isRightSwipe(velocity)) }
            }
            gSwipeTracking = false
            gSwipeFired    = false

            // macOS 27's Dock needs to see the gesture close to keep its
            // internal state consistent — pass the Ended event through
            // with its motion zeroed out so it cannot trigger a switch.
            if requiresEventAugmentation() {
                event.setDoubleValueField(kCGEventGestureSwipeVelocityX, value: 0)
                event.setDoubleValueField(kCGEventGestureSwipeVelocityY, value: 0)
                event.setDoubleValueField(kCGEventGestureSwipeProgress,  value: 0)
                return passthrough
            }
            return nil
        }

        if phase == kCGSGesturePhaseCancelled {
            gSwipeTracking = false
            gSwipeFired    = false
            return nil
        }

        // Any other phase belongs to us only while tracking
        return gSwipeTracking ? nil : passthrough
    }

    // Companion generic gesture envelopes paired with a tracked dock
    // swipe — swallow them so the Dock never sees half a gesture.
    if subtype == kCGSEventGesture, gSwipeTracking { return nil }

    return passthrough
}

/// Returns whether a vertical Began event opens (`true`) or dismisses (`false`)
/// Mission Control, or `nil` when its direction is ambiguous.
///
/// Current macOS releases expose direction in the IOHID swipe mask. Events
/// that omit it encode a signed `Float` in field 135; its sign follows the
/// same macOS 27 inversion as other real DockSwipes. An ambiguous Began is
/// never intercepted.
private func verticalSwipeOpensMissionControl(_ event: CGEvent) -> Bool? {
    let mask = event.getIntegerValueField(kCGEventGestureSwipeMask)
    if mask & kSwipeMaskUp != 0 { return true }
    if mask & kSwipeMaskDown != 0 { return false }

    let rawFlags = event.getIntegerValueField(kCGEventScrollGestureFlagBits)
    let flags = Float(bitPattern: UInt32(truncatingIfNeeded: rawFlags))
    guard flags != 0 else { return nil }
    return requiresEventAugmentation() ? flags < 0 : flags > 0
}

// MARK: - Direction & Firing

/// Whether the given progress/velocity sign means "move to the space on
/// the right". The raw sign convention of REAL trackpad DockSwipe events
/// has flipped across macOS releases (independently of the posting-side
/// convention documented in SpaceSwitching.swift):
///
///   - macOS ≤ 26: positive = right
///   - macOS 27+:  negative = right (inverted on the augmented path)
///
/// The "Natural scrolling" setting needs no handling here: the window
/// server already flips the reported sign when the user turns it off, so
/// the rows above hold in both modes and the mapping from sign to space is
/// unconditional. Correcting for the setting on top of that double-flips
/// it — measured on macOS 26, natural scrolling OFF: a left-to-right swipe
/// reports progress +0.045 and must move right, same rule as ON.
///
/// - Parameter sign: A non-zero swipe progress or X velocity sample.
/// - Returns: `true` when the swipe targets the next space to the right.
private func isRightSwipe(_ sign: Double) -> Bool {
    if requiresEventAugmentation() { return sign < 0 }
    return sign > 0
}

/// Fires the instant switch replacing an intercepted swipe, mirroring the
/// keyboard path's safety rails: stand down when the space layout is
/// unknown (never post blind — issue #6), and do nothing at the edges
/// (the real gesture is already swallowed, so there is no bounce either
/// way). Velocity follows the transition-speed slider via
/// `postSwitchGesture`'s default, exactly like the keyboard feature.
///
/// - Parameter isRight: `true` to move to the next space on the right.
private func performSwipeSwitch(isRight: Bool) {
    let direction = isRight ? 1 : -1

    let (spaceIDs, currentIdx) = getSpaceList()
    guard currentIdx >= 0 else { return }

    let targetIdx = currentIdx + direction
    guard targetIdx >= 0, targetIdx < spaceIDs.count else { return }

    if postSwitchGesture(direction: direction) {
        gLastSpaceSwitchTime = Date()
        gMenu?.recordSwitch()
    }
}
