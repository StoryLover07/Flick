# Setup:
#   pip3 install pybooklid
#   python3 flick_prototype.py

"""Flick sensor-reading, gesture detection, and window-grid prototype.

This prototype watches MacBook lid angle samples and detects a quick
close-then-open trajectory, then arranges visible macOS windows.
"""

from __future__ import annotations

import argparse
from collections import deque
import ctypes
from dataclasses import dataclass
import subprocess
import sys
import time
from typing import Deque, Optional


# How often to sample the lid angle. 0.05 seconds is about 20 Hz, which is
# enough for a human hinge gesture without producing too much terminal noise.
SAMPLE_INTERVAL_SECONDS = 0.05

# How much recent history to keep for trajectory analysis. The detector only
# reasons about changes inside this rolling window, not about absolute poses.
BUFFER_WINDOW_SECONDS = 1.2

# Early-trigger tuning: detection happens as soon as a fast close reverses into
# a small, fast reopening movement. It does not wait for the lid to return to
# its original angle.
MIN_DROP_DEGREES = 20.0
MIN_EARLY_RECOVER_DEGREES = 6.0
MIN_DROP_SPEED_DEG_PER_SEC = 60.0
MIN_RECOVER_SPEED_DEG_PER_SEC = 40.0
MAX_EARLY_TRIGGER_DURATION = 0.8

# Ignore new detections briefly so one physical movement prints only once.
COOLDOWN_SECONDS = 1.5

# A window must overlap the active main screen by at least this many pixels in
# both dimensions. Tiny edge intersections are treated as off-screen.
MIN_SCREEN_INTERSECTION_PIXELS = 20
MIN_SCREEN_INTERSECTION_RATIO = 0.10

# Four-window layout tuning. 2x2 equal quarters made chat/document/browser
# combinations hard to read, so 4 windows use a side-panel plus main/support
# composition instead.
LAYOUT_GAP_PIXELS = 16
FOUR_WINDOW_SIDE_WIDTH_RATIO = 0.36
FOUR_WINDOW_MAX_SIDE_WIDTH = 620
FOUR_WINDOW_MAIN_HEIGHT_RATIO = 0.62


@dataclass(frozen=True)
class LidSample:
    """One lid angle reading."""

    timestamp: float
    angle: float


@dataclass(frozen=True)
class WindowInfo:
    """Accessibility metadata used to decide whether a window is on-screen."""

    process_name: str
    window_index: int
    x: int
    y: int
    width: int
    height: int
    process_visible: bool
    window_visible: bool
    minimized: bool
    standard: bool

    @property
    def bounds(self) -> tuple[int, int, int, int]:
        return self.x, self.y, self.x + self.width, self.y + self.height


@dataclass(frozen=True)
class WindowCollection:
    """Windows collected in one AppleScript call plus the active process."""

    windows: list[WindowInfo]
    frontmost_process: Optional[str]


@dataclass(frozen=True)
class WindowPlacement:
    """One target window and its calculated destination bounds."""

    window: WindowInfo
    bounds: tuple[int, int, int, int]


class FlickCloseDetector:
    """Detects the early recovery of a fast close-then-open trajectory.

    The detector does not trigger on a specific lid angle. Instead, it searches
    recent samples for:
      1. a meaningful fast decrease,
      2. a local minimum or direction reversal,
      3. a small, fast early recovery,
      4. all within a short time window.

    This is deliberately an early-trigger detector: arranging starts once the
    reopening intent is clear rather than after a full return to the start angle.
    """

    def __init__(
        self,
        *,
        buffer_window: float = BUFFER_WINDOW_SECONDS,
        min_drop: float = MIN_DROP_DEGREES,
        min_early_recover: float = MIN_EARLY_RECOVER_DEGREES,
        min_drop_speed: float = MIN_DROP_SPEED_DEG_PER_SEC,
        min_recover_speed: float = MIN_RECOVER_SPEED_DEG_PER_SEC,
        max_duration: float = MAX_EARLY_TRIGGER_DURATION,
        cooldown: float = COOLDOWN_SECONDS,
    ) -> None:
        self.buffer_window = buffer_window
        self.min_drop = min_drop
        self.min_early_recover = min_early_recover
        self.min_drop_speed = min_drop_speed
        self.min_recover_speed = min_recover_speed
        self.max_duration = max_duration
        self.cooldown = cooldown
        self.samples: Deque[LidSample] = deque()
        self.last_detection_time = 0.0

    def add_sample(self, timestamp: float, angle: float) -> bool:
        """Add a sample and return True when Flick Close is detected."""

        self.samples.append(LidSample(timestamp=timestamp, angle=angle))
        self._trim_old_samples(timestamp)

        if timestamp - self.last_detection_time < self.cooldown:
            return False

        if self._matches_flick_close():
            self.last_detection_time = timestamp
            return True

        return False

    def _trim_old_samples(self, now: float) -> None:
        cutoff = now - self.buffer_window
        while self.samples and self.samples[0].timestamp < cutoff:
            self.samples.popleft()

    def _matches_flick_close(self) -> bool:
        samples = list(self.samples)
        if len(samples) < 3:
            return False

        # Try each interior sample as the close-to-open turning point. Only a
        # small early recovery is needed after it, which reduces trigger delay.
        for min_index in range(1, len(samples) - 1):
            minimum = samples[min_index]
            before = samples[:min_index]
            after = samples[min_index + 1 :]

            # The highest pre-turn angle marks the start of the close. The
            # highest available post-turn sample measures recovery so far.
            start = max(before, key=lambda sample: sample.angle)
            recovery = max(after, key=lambda sample: sample.angle)

            if start.timestamp >= minimum.timestamp:
                continue
            if recovery.timestamp <= minimum.timestamp:
                continue

            duration = recovery.timestamp - start.timestamp
            if duration <= 0 or duration > self.max_duration:
                continue

            drop = start.angle - minimum.angle
            recovery_gain = recovery.angle - minimum.angle
            if drop < self.min_drop:
                continue
            if recovery_gain < self.min_early_recover:
                continue

            drop_duration = minimum.timestamp - start.timestamp
            recovery_duration = recovery.timestamp - minimum.timestamp
            if drop_duration <= 0 or recovery_duration <= 0:
                continue

            drop_speed = drop / drop_duration
            recovery_speed = recovery_gain / recovery_duration
            if drop_speed < self.min_drop_speed:
                continue
            if recovery_speed < self.min_recover_speed:
                continue

            if not self._is_local_minimum(samples, min_index):
                continue

            return True

        return False

    @staticmethod
    def _is_local_minimum(samples: list[LidSample], min_index: int) -> bool:
        """Return True if this sample is lower than nearby samples.

        A small neighborhood makes the detector tolerant of sensor noise while
        still requiring a real close-to-open turn in the trajectory.
        """

        minimum = samples[min_index]
        left = samples[max(0, min_index - 2) : min_index]
        right = samples[min_index + 1 : min(len(samples), min_index + 3)]

        return bool(left and right) and all(
            minimum.angle <= neighbor.angle for neighbor in [*left, *right]
        )


def create_lid_sensor():
    """Import and connect pybooklid, or exit cleanly with setup guidance."""

    try:
        from pybooklid import LidSensor, is_sensor_available
    except ImportError:
        print(
            "Error: pybooklid is not installed.\n"
            "Install it with:\n"
            "  pip3 install pybooklid",
            file=sys.stderr,
        )
        sys.exit(1)

    try:
        if not is_sensor_available():
            print(
                "Error: MacBook lid angle sensor is not available.\n"
                "This prototype needs a supported MacBook and macOS sensor access.",
                file=sys.stderr,
            )
            sys.exit(1)

        sensor = LidSensor(auto_connect=True)
        if hasattr(sensor, "is_connected") and not sensor.is_connected():
            sensor.connect()
        return sensor
    except Exception as exc:
        print(
            "Error: could not connect to the MacBook lid angle sensor.\n"
            f"Details: {exc}",
            file=sys.stderr,
        )
        sys.exit(1)


def read_angle(sensor) -> Optional[float]:
    """Read one angle from pybooklid and normalize unavailable values to None."""

    try:
        angle = sensor.read_angle()
    except Exception as exc:
        print(f"Error: sensor read failed: {exc}", file=sys.stderr)
        return None

    if angle is None:
        return None

    try:
        return float(angle)
    except (TypeError, ValueError):
        print(f"Error: unexpected lid angle value: {angle!r}", file=sys.stderr)
        return None


def performance_log(message: str) -> None:
    """Print a concise wall-clock timestamp for perceived-latency tracing."""

    now = time.time()
    milliseconds = int((now % 1) * 1000)
    print(f"[{time.strftime('%H:%M:%S', time.localtime(now))}.{milliseconds:03d}] {message}")


def arrange_windows_grid(verbose: bool = False, preview: bool = False) -> None:
    """Calculate and optionally apply a layout for active-screen windows."""

    arrange_start = time.perf_counter()
    performance_log("Arrange start")

    screen_bounds = get_main_screen_bounds()
    if screen_bounds is None:
        performance_log(
            f"Total arrange time: {(time.perf_counter() - arrange_start) * 1000:.0f} ms"
        )
        return

    collection_start = time.perf_counter()
    if verbose:
        performance_log("Window collection start")
    collection = collect_visible_windows()
    collection_duration_ms = (time.perf_counter() - collection_start) * 1000
    if collection is None:
        performance_log(f"Window collection failed in {collection_duration_ms:.0f} ms")
        performance_log(
            f"Total arrange time: {(time.perf_counter() - arrange_start) * 1000:.0f} ms"
        )
        return

    performance_log(
        f"Collected {len(collection.windows)} windows in "
        f"{collection_duration_ms:.0f} ms"
    )
    if verbose:
        performance_log("Window collection end")
        print(f"Frontmost process: {collection.frontmost_process!r}")

    target_windows: list[WindowInfo] = []
    for window in collection.windows:
        skip_reason = window_skip_reason(window, screen_bounds)
        if skip_reason is not None:
            if verbose:
                print(
                    f"  skipped process={window.process_name!r} "
                    f"window_index={window.window_index} "
                    f"bounds={window.bounds}: {skip_reason}"
                )
            continue

        target_windows.append(window)
        if verbose:
            print(
                f"  collected process={window.process_name!r} "
                f"window_index={window.window_index} bounds={window.bounds}"
            )

    if not target_windows:
        print("No arrangeable windows visible on the active main screen.")
        performance_log(
            f"Total arrange time: {(time.perf_counter() - arrange_start) * 1000:.0f} ms"
        )
        return

    layout_start = time.perf_counter()
    if verbose:
        performance_log("Layout calculation start")
    ordered_windows = prioritize_active_window(
        target_windows,
        collection.frontmost_process,
    )
    placements = calculate_layout(ordered_windows, screen_bounds)
    layout_duration_ms = (time.perf_counter() - layout_start) * 1000
    performance_log(f"Layout calculated in {layout_duration_ms:.1f} ms")

    if verbose or preview:
        print(f"Final target windows: {len(placements)}")
        for placement in placements:
            print(
                f"  process={placement.window.process_name!r} "
                f"window_index={placement.window.window_index} "
                f"target_bounds={placement.bounds}"
            )

    if preview:
        performance_log(
            f"Total preview time: {(time.perf_counter() - arrange_start) * 1000:.0f} ms"
        )
        return

    bounds_start = time.perf_counter()
    if verbose:
        performance_log("Bounds setting start")
    arranged_count = set_window_bounds_batch(placements, verbose=verbose)
    bounds_duration_ms = (time.perf_counter() - bounds_start) * 1000
    performance_log(
        f"Arranged {arranged_count} windows in {bounds_duration_ms:.0f} ms"
    )
    if verbose:
        performance_log("Bounds setting end")

    performance_log(
        f"Total arrange time: {(time.perf_counter() - arrange_start) * 1000:.0f} ms"
    )


def run_applescript(script: str, *arguments: str) -> subprocess.CompletedProcess[str]:
    """Run static AppleScript source and pass dynamic values through argv."""

    return subprocess.run(
        ["osascript", "-e", script, *arguments],
        capture_output=True,
        check=False,
        text=True,
        timeout=10.0,
    )


WINDOW_COLLECTION_APPLESCRIPT = r'''
on run
    set frontmostName to ""
    set outputText to ""

    tell application "System Events"
        set visibleProcesses to every process whose visible is true

        try
            set frontmostName to name of first process whose frontmost is true
        end try

        repeat with targetProcess in visibleProcesses
            try
                set processName to name of targetProcess
                set processWindowCount to count of windows of targetProcess

                repeat with windowIndex from 1 to processWindowCount
                    try
                        set targetWindow to window windowIndex of targetProcess
                        set windowPosition to position of targetWindow
                        set windowSize to size of targetWindow
                        set windowMinimized to false

                        try
                            set windowMinimized to value of attribute "AXMinimized" of targetWindow
                        on error
                            set windowMinimized to false
                        end try

                        set outputLine to processName & tab & windowIndex & tab & item 1 of windowPosition & tab & item 2 of windowPosition & tab & item 1 of windowSize & tab & item 2 of windowSize & tab & windowMinimized

                        if outputText is "" then
                            set outputText to outputLine
                        else
                            set outputText to outputText & linefeed & outputLine
                        end if
                    on error
                        -- Skip windows that do not expose basic geometry.
                    end try
                end repeat
            on error
                -- Skip processes that do not allow their windows to be read.
            end try
        end repeat
    end tell

    if outputText is "" then
        return "FRONTMOST" & tab & frontmostName
    end if
    return "FRONTMOST" & tab & frontmostName & linefeed & outputText
end run
'''


BASIC_OSASCRIPT_TEST = (
    'tell application "System Events" to get name of every process '
    "whose visible is true"
)


def collect_visible_windows() -> Optional[WindowCollection]:
    """Collect window geometry and visibility metadata from System Events."""

    try:
        result = run_applescript(WINDOW_COLLECTION_APPLESCRIPT)
    except FileNotFoundError:
        print("Error: osascript is not available on this system.", file=sys.stderr)
        return None
    except Exception as exc:
        print(f"Error: could not enumerate macOS windows: {exc}", file=sys.stderr)
        return None

    if result.returncode != 0:
        log_applescript_failure("collect visible windows", result)
        return None

    windows: list[WindowInfo] = []
    frontmost_process: Optional[str] = None
    for line in result.stdout.splitlines():
        if not line.strip():
            continue
        if line.startswith("FRONTMOST\t"):
            value = line.split("\t", 1)[1].strip()
            frontmost_process = value or None
            continue
        try:
            fields = line.rsplit("\t", 6)
            if len(fields) != 7:
                raise ValueError(f"expected 7 fields, got {len(fields)}")
            windows.append(
                WindowInfo(
                    process_name=fields[0],
                    window_index=int(fields[1]),
                    x=int(fields[2]),
                    y=int(fields[3]),
                    width=int(fields[4]),
                    height=int(fields[5]),
                    process_visible=True,
                    window_visible=True,
                    minimized=parse_applescript_boolean(fields[6]),
                    standard=True,
                )
            )
        except (ValueError, TypeError):
            print(f"Skipping unexpected window record: {line!r}", file=sys.stderr)

    return WindowCollection(
        windows=windows,
        frontmost_process=frontmost_process,
    )


def debug_window_collection_applescript() -> None:
    """Print and run only the exact AppleScript used for window collection."""

    print("Window collection AppleScript:")
    print(WINDOW_COLLECTION_APPLESCRIPT)

    try:
        result = run_applescript(WINDOW_COLLECTION_APPLESCRIPT)
    except (FileNotFoundError, OSError, subprocess.TimeoutExpired) as exc:
        print(f"Could not run osascript: {exc}", file=sys.stderr)
        return

    print(f"stdout:\n{result.stdout or '<empty>'}")
    print(f"stderr:\n{result.stderr or '<empty>'}")
    print(f"return code: {result.returncode}")


def test_osascript_basic() -> None:
    """Run the known-working minimal System Events permission test."""

    try:
        result = run_applescript(BASIC_OSASCRIPT_TEST)
    except (FileNotFoundError, OSError, subprocess.TimeoutExpired) as exc:
        print(f"Could not run osascript: {exc}", file=sys.stderr)
        return

    print(f"stdout:\n{result.stdout or '<empty>'}")
    print(f"stderr:\n{result.stderr or '<empty>'}")
    print(f"return code: {result.returncode}")


def parse_applescript_boolean(value: str) -> bool:
    """Parse AppleScript's textual true/false values."""

    normalized = value.strip().lower()
    if normalized == "true":
        return True
    if normalized == "false":
        return False
    raise ValueError(f"unexpected AppleScript boolean: {value!r}")


def window_skip_reason(
    window: WindowInfo,
    screen_bounds: tuple[int, int, int, int],
) -> Optional[str]:
    """Return why a window is not visibly present on the active main screen."""

    if not window.process_visible:
        return "application is hidden"
    if not window.window_visible:
        return "window is not visible in the active Space"
    if window.minimized:
        return "window is minimized"
    if not window.standard:
        return "window is not a standard application window"
    if window.width <= 0 or window.height <= 0:
        return "window has invalid size"

    window_left, window_top, window_right, window_bottom = window.bounds
    screen_left, screen_top, screen_right, screen_bottom = screen_bounds
    overlap_width = min(window_right, screen_right) - max(window_left, screen_left)
    overlap_height = min(window_bottom, screen_bottom) - max(window_top, screen_top)

    if overlap_width <= 0 or overlap_height <= 0:
        return "window is outside the active main screen"
    if (
        overlap_width < MIN_SCREEN_INTERSECTION_PIXELS
        or overlap_height < MIN_SCREEN_INTERSECTION_PIXELS
    ):
        return "window only touches the edge of the active main screen"

    overlap_area = overlap_width * overlap_height
    window_area = window.width * window.height
    if overlap_area / window_area < MIN_SCREEN_INTERSECTION_RATIO:
        return "too little of the window is visible on the active main screen"

    return None


def get_main_screen_bounds() -> Optional[tuple[int, int, int, int]]:
    """Read the main display bounds directly from CoreGraphics."""

    class CGPoint(ctypes.Structure):
        _fields_ = [("x", ctypes.c_double), ("y", ctypes.c_double)]

    class CGSize(ctypes.Structure):
        _fields_ = [("width", ctypes.c_double), ("height", ctypes.c_double)]

    class CGRect(ctypes.Structure):
        _fields_ = [("origin", CGPoint), ("size", CGSize)]

    try:
        core_graphics = ctypes.CDLL(
            "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics"
        )
        core_graphics.CGMainDisplayID.restype = ctypes.c_uint32
        core_graphics.CGDisplayBounds.argtypes = [ctypes.c_uint32]
        core_graphics.CGDisplayBounds.restype = CGRect
        display_id = core_graphics.CGMainDisplayID()
        bounds = core_graphics.CGDisplayBounds(display_id)
    except (AttributeError, OSError) as exc:
        print(f"Error: could not read main screen bounds: {exc}", file=sys.stderr)
        return None

    left = round(bounds.origin.x)
    top = round(bounds.origin.y)
    right = left + round(bounds.size.width)
    bottom = top + round(bounds.size.height)
    return left, top, right, bottom


def prioritize_active_window(
    windows: list[WindowInfo],
    frontmost_process: Optional[str],
) -> list[WindowInfo]:
    """Move the first window of the frontmost process to the front."""

    if not windows:
        return []
    if frontmost_process is None:
        return list(windows)

    active_index = next(
        (
            index
            for index, window in enumerate(windows)
            if window.process_name == frontmost_process
        ),
        None,
    )
    if active_index is None:
        return list(windows)

    return [windows[active_index], *windows[:active_index], *windows[active_index + 1 :]]


def calculate_layout(
    windows: list[WindowInfo],
    screen_bounds: tuple[int, int, int, int],
) -> list[WindowPlacement]:
    """Apply the Flick Arrange MVP layout policy."""

    count = len(windows)
    if count == 0:
        return []

    left, top, right, bottom = screen_bounds
    width = right - left
    height = bottom - top

    if count == 1:
        bounds = [(left, top, right, bottom)]
    elif count == 2:
        middle = left + width // 2
        bounds = [
            (left, top, middle, bottom),
            (middle, top, right, bottom),
        ]
    elif count == 3:
        middle_x = left + width // 2
        middle_y = top + height // 2
        # The active/frontmost window is first and receives the right half.
        bounds = [
            (middle_x, top, right, bottom),
            (left, top, middle_x, middle_y),
            (left, middle_y, middle_x, bottom),
        ]
    elif count == 4:
        windows, bounds = calculate_four_window_layout(windows, screen_bounds)
    else:
        bounds = calculate_compact_card_bounds(count, screen_bounds)

    return [
        WindowPlacement(window=window, bounds=target_bounds)
        for window, target_bounds in zip(windows, bounds)
    ]


def calculate_four_window_layout(
    windows: list[WindowInfo],
    screen_bounds: tuple[int, int, int, int],
) -> tuple[list[WindowInfo], list[tuple[int, int, int, int]]]:
    """Arrange 4 windows as side panel, large main, and two support cards."""

    left, top, right, bottom = screen_bounds
    screen_width = right - left
    screen_height = bottom - top
    gap = LAYOUT_GAP_PIXELS

    side_index = find_side_panel_window_index(windows)
    ordered_windows = [
        windows[side_index],
        *windows[:side_index],
        *windows[side_index + 1 :],
    ]

    side_width = min(
        FOUR_WINDOW_MAX_SIDE_WIDTH,
        int(screen_width * FOUR_WINDOW_SIDE_WIDTH_RATIO),
    )
    side_width = max(420, min(side_width, screen_width - 720))
    right_left = left + side_width + gap
    main_bottom = top + int(screen_height * FOUR_WINDOW_MAIN_HEIGHT_RATIO)
    support_top = main_bottom + gap
    support_width = (right - right_left - gap) // 2

    bounds = [
        (left, top, left + side_width, bottom),
        (right_left, top, right, main_bottom),
        (right_left, support_top, right_left + support_width, bottom),
        (right_left + support_width + gap, support_top, right, bottom),
    ]
    return ordered_windows, bounds


def find_side_panel_window_index(windows: list[WindowInfo]) -> int:
    """Pick the window that reads best as a left-side communication panel."""

    side_panel_process_names = {
        "KakaoTalk",
        "Messages",
        "Discord",
        "Slack",
        "Telegram",
        "WhatsApp",
    }

    for index, window in enumerate(windows):
        if window.process_name in side_panel_process_names:
            return index

    for index, window in enumerate(windows):
        if window.height > 0 and window.width / window.height < 0.9:
            return index

    return 0


def calculate_compact_card_bounds(
    count: int,
    screen_bounds: tuple[int, int, int, int],
) -> list[tuple[int, int, int, int]]:
    """Place 5+ windows as compact cards flowing down, then to the right."""

    left, top, right, bottom = screen_bounds
    screen_width = right - left
    screen_height = bottom - top
    gap = 16

    card_width = min(520, int(screen_width * 0.33))
    card_height = min(330, int(screen_height * 0.28))
    rows_per_column = max(1, (screen_height - gap) // (card_height + gap))
    column_count = (count + rows_per_column - 1) // rows_per_column

    # Preserve the requested card caps, shrinking only when the number of
    # columns or rows would otherwise push cards beyond the screen bounds.
    max_card_width = (screen_width - gap * (column_count + 1)) // column_count
    max_card_height = (
        screen_height - gap * (rows_per_column + 1)
    ) // rows_per_column
    card_width = max(1, min(card_width, max_card_width))
    card_height = max(1, min(card_height, max_card_height))

    bounds: list[tuple[int, int, int, int]] = []
    for index in range(count):
        column = index // rows_per_column
        row = index % rows_per_column
        card_left = left + gap + column * (card_width + gap)
        card_top = top + gap + row * (card_height + gap)
        bounds.append(
            (
                card_left,
                card_top,
                card_left + card_width,
                card_top + card_height,
            )
        )

    return bounds


BATCH_SET_BOUNDS_APPLESCRIPT = r'''
on splitText(sourceText, delimiterText)
    set previousDelimiters to AppleScript's text item delimiters
    set AppleScript's text item delimiters to delimiterText
    set textParts to text items of sourceText
    set AppleScript's text item delimiters to previousDelimiters
    return textParts
end splitText

on run argv
    set payload to item 1 of argv
    set payloadLines to my splitText(payload, linefeed)
    set successCount to 0
    set errorText to ""

    tell application "System Events"
        repeat with payloadLine in payloadLines
            if payloadLine as text is not "" then
                set fields to my splitText(payloadLine as text, tab)
                if count of fields is 6 then
                    set processName to item 1 of fields
                    set windowIndex to item 2 of fields as integer
                    set leftEdge to item 3 of fields as integer
                    set topEdge to item 4 of fields as integer
                    set rightEdge to item 5 of fields as integer
                    set bottomEdge to item 6 of fields as integer

                    try
                        tell process processName
                            set position of window windowIndex to {leftEdge, topEdge}
                            set size of window windowIndex to {rightEdge - leftEdge, bottomEdge - topEdge}
                        end tell
                        set successCount to successCount + 1
                    on error errorMessage number errorNumber
                        set errorLine to processName & tab & windowIndex & tab & errorNumber & tab & errorMessage
                        if errorText is "" then
                            set errorText to errorLine
                        else
                            set errorText to errorText & linefeed & errorLine
                        end if
                    end try
                end if
            end if
        end repeat
    end tell

    if errorText is "" then
        return successCount as text
    end if
    return (successCount as text) & linefeed & errorText
end run
'''


def set_window_bounds_batch(
    placements: list[WindowPlacement],
    *,
    verbose: bool,
) -> int:
    """Apply all bounds with one osascript process and return success count."""

    payload = "\n".join(
        "\t".join(
            [
                placement.window.process_name,
                str(placement.window.window_index),
                *(str(value) for value in placement.bounds),
            ]
        )
        for placement in placements
    )

    try:
        result = run_applescript(BATCH_SET_BOUNDS_APPLESCRIPT, payload)
    except (FileNotFoundError, OSError, subprocess.TimeoutExpired) as exc:
        print(f"Error: could not batch-set window bounds: {exc}", file=sys.stderr)
        return 0

    if result.returncode != 0:
        log_applescript_failure("batch-set window bounds", result)
        return 0

    output_lines = result.stdout.splitlines()
    try:
        success_count = int(output_lines[0].strip()) if output_lines else 0
    except ValueError:
        print(
            f"Unexpected batch setter output: {result.stdout!r}",
            file=sys.stderr,
        )
        return 0

    if len(output_lines) > 1:
        for error_line in output_lines[1:]:
            print(f"Skipped window: {error_line}", file=sys.stderr)
    elif verbose and result.stderr.strip():
        print(f"AppleScript stderr: {result.stderr.strip()}", file=sys.stderr)

    return success_count


def log_applescript_failure(
    operation: str,
    result: subprocess.CompletedProcess[str],
) -> None:
    """Print AppleScript diagnostics and Accessibility setup guidance."""

    stdout = (result.stdout or "").strip()
    stderr = (result.stderr or "").strip()
    print(
        f"AppleScript failed while trying to {operation} "
        f"(exit {result.returncode}).",
        file=sys.stderr,
    )
    print(f"  stdout: {stdout or '<empty>'}", file=sys.stderr)
    print(f"  stderr: {stderr or '<empty>'}", file=sys.stderr)
    print_accessibility_help_if_needed(f"{stdout}\n{stderr}")


def print_accessibility_help_if_needed(message: str) -> None:
    """Print Accessibility setup guidance for common macOS automation failures."""

    lower_message = message.lower()
    permission_markers = [
        "assistive access",
        "accessibility",
        "not allowed",
        "not authorized",
        "not permitted",
        "operation not permitted",
        "system events got an error",
    ]

    if any(marker in lower_message for marker in permission_markers):
        print(
            "macOS may be blocking window control. Allow access here:\n"
            "  System Settings > Privacy & Security > Accessibility > Terminal",
            file=sys.stderr,
        )


def main() -> None:
    parser = argparse.ArgumentParser(description="Flick prototype")
    parser.add_argument(
        "--arrange-once",
        action="store_true",
        help="arrange visible windows immediately, then exit",
    )
    parser.add_argument(
        "--layout-preview",
        action="store_true",
        help="calculate and print the layout without moving windows",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="show collected windows, skip reasons, and target bounds",
    )
    parser.add_argument(
        "--debug-applescript",
        action="store_true",
        help="print and run only the window collection AppleScript",
    )
    parser.add_argument(
        "--test-osascript-basic",
        action="store_true",
        help="run the minimal System Events permission test",
    )
    args = parser.parse_args()

    if args.test_osascript_basic:
        test_osascript_basic()
        return

    if args.debug_applescript:
        debug_window_collection_applescript()
        return

    if args.layout_preview:
        arrange_windows_grid(verbose=args.verbose, preview=True)
        return

    if args.arrange_once:
        arrange_windows_grid(verbose=args.verbose)
        return

    print("Flick prototype")
    print("Reading lid angle. Press Ctrl+C to stop.")
    print("Gesture target: quick close partway, then reopen.")

    sensor = create_lid_sensor()
    detector = FlickCloseDetector()

    try:
        while True:
            now = time.time()
            angle = read_angle(sensor)

            if angle is None:
                print("Angle unavailable")
            else:
                print(f"{time.strftime('%H:%M:%S')}  lid angle: {angle:6.1f} deg")
                if detector.add_sample(now, angle):
                    performance_log("Flick Close detected via instant_drop")
                    arrange_windows_grid(verbose=args.verbose)

            time.sleep(SAMPLE_INTERVAL_SECONDS)
    except KeyboardInterrupt:
        print("\nStopped.")
    finally:
        disconnect = getattr(sensor, "disconnect", None)
        if callable(disconnect):
            disconnect()


if __name__ == "__main__":
    main()
