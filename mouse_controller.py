#!/usr/bin/env python3
import os
import sys
import time
import ctypes
import socket
import ssl
import json
import asyncio
import threading
import subprocess
import http

# Import third-party libraries installed in the venv
try:
    import websockets
    import qrcode
    from websockets.http11 import Response
    from websockets.datastructures import Headers
except ImportError:
    print("Required packages (websockets, qrcode) not found.")
    print("Please activate your virtual environment: source .venv/bin/activate")
    sys.exit(1)

# ----------------------------------------------------
# macOS CoreGraphics Mouse & Keyboard Control via ctypes
# ----------------------------------------------------
core_graphics = ctypes.CDLL('/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices')
core_foundation = ctypes.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')

# Structs
class CGPoint(ctypes.Structure):
    _fields_ = [("x", ctypes.c_double), ("y", ctypes.c_double)]

class CGRect(ctypes.Structure):
    _fields_ = [("origin", CGPoint), ("size", CGPoint)]

# Event creation and posting signatures
core_graphics.CGEventCreate.argtypes = [ctypes.c_void_p]
core_graphics.CGEventCreate.restype = ctypes.c_void_p

core_graphics.CGEventGetLocation.argtypes = [ctypes.c_void_p]
core_graphics.CGEventGetLocation.restype = CGPoint

core_graphics.CGEventCreateMouseEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint32, CGPoint, ctypes.c_uint32]
core_graphics.CGEventCreateMouseEvent.restype = ctypes.c_void_p

core_graphics.CGEventCreateKeyboardEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint16, ctypes.c_bool]
core_graphics.CGEventCreateKeyboardEvent.restype = ctypes.c_void_p

core_graphics.CGEventKeyboardSetUnicodeString.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_void_p]
core_graphics.CGEventKeyboardSetUnicodeString.restype = None

core_graphics.CGEventCreateScrollWheelEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_int32, ctypes.c_int32]
core_graphics.CGEventCreateScrollWheelEvent.restype = ctypes.c_void_p

core_graphics.CGEventPost.argtypes = [ctypes.c_uint32, ctypes.c_void_p]
core_graphics.CGEventPost.restype = None

core_foundation.CFRelease.argtypes = [ctypes.c_void_p]
core_foundation.CFRelease.restype = None

core_graphics.CGEventSourceCreate.argtypes = [ctypes.c_int32]
core_graphics.CGEventSourceCreate.restype = ctypes.c_void_p

core_graphics.CGEventSetIntegerValueField.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_int64]
core_graphics.CGEventSetIntegerValueField.restype = None

core_graphics.CGEventSetFlags.argtypes = [ctypes.c_void_p, ctypes.c_uint64]
core_graphics.CGEventSetFlags.restype = None

# Accessibility API — text field focus detection
core_graphics.AXUIElementCreateSystemWide.argtypes = []
core_graphics.AXUIElementCreateSystemWide.restype = ctypes.c_void_p

core_graphics.AXUIElementCopyAttributeValue.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p)]
core_graphics.AXUIElementCopyAttributeValue.restype = ctypes.c_int

core_graphics.AXIsProcessTrusted.argtypes = []
core_graphics.AXIsProcessTrusted.restype = ctypes.c_bool

core_foundation.CFStringCreateWithCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32]
core_foundation.CFStringCreateWithCString.restype = ctypes.c_void_p

core_foundation.CFStringGetCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_long, ctypes.c_uint32]
core_foundation.CFStringGetCString.restype = ctypes.c_bool

kCGMouseEventClickState = 1
kCGEventFlagMaskControl = 0x40000  # Control modifier flag for CGEvent

# Accessibility / CFString constants
kCFStringEncodingUTF8 = 0x08000100
_TEXT_ROLES = {b'AXTextField', b'AXTextArea', b'AXSearchField', b'AXSecureTextField', b'AXComboBox'}

core_graphics.CGDisplayBounds.argtypes = [ctypes.c_uint32]
core_graphics.CGDisplayBounds.restype = CGRect

core_graphics.CGMainDisplayID.argtypes = []
core_graphics.CGMainDisplayID.restype = ctypes.c_uint32

core_graphics.CGGetActiveDisplayList.argtypes = [ctypes.c_uint32, ctypes.POINTER(ctypes.c_uint32), ctypes.POINTER(ctypes.c_uint32)]
core_graphics.CGGetActiveDisplayList.restype = ctypes.c_int32

# Constants
kCGEventMouseMoved = 5
kCGEventLeftMouseDown = 1
kCGEventLeftMouseUp = 2
kCGEventRightMouseDown = 3
kCGEventRightMouseUp = 4
kCGEventLeftMouseDragged = 6
kCGEventRightMouseDragged = 7

kCGMouseButtonLeft = 0
kCGMouseButtonRight = 1
kCGHIDEventTap = 0
kCGEventSourceStateHIDSystemState = 1

# Special keys mapping for macOS virtual keycodes
SPECIAL_KEYS = {
    'backspace': 51,
    'enter': 36,
    'space': 49,
    'escape': 53,
    'tab': 48,
    'arrowleft': 123,
    'arrowright': 124,
    'arrowdown': 125,
    'arrowup': 126
}

# ----------------------------------------------------
# Accessibility: detect if focused element is a text field
# ----------------------------------------------------
def is_focused_on_text_field():
    """Return True if the focused macOS UI element is a text input."""
    try:
        sys_elem = core_graphics.AXUIElementCreateSystemWide()
        if not sys_elem:
            return False

        # Fetch the currently focused element
        attr_focused = core_foundation.CFStringCreateWithCString(None, b"AXFocusedUIElement", kCFStringEncodingUTF8)
        focused = ctypes.c_void_p()
        err = core_graphics.AXUIElementCopyAttributeValue(sys_elem, attr_focused, ctypes.byref(focused))
        core_foundation.CFRelease(attr_focused)
        core_foundation.CFRelease(sys_elem)
        if err != 0 or not focused.value:
            return False

        # Fetch its AXRole
        attr_role = core_foundation.CFStringCreateWithCString(None, b"AXRole", kCFStringEncodingUTF8)
        role_ref = ctypes.c_void_p()
        err = core_graphics.AXUIElementCopyAttributeValue(focused.value, attr_role, ctypes.byref(role_ref))
        core_foundation.CFRelease(attr_role)
        core_foundation.CFRelease(focused.value)
        if err != 0 or not role_ref.value:
            return False

        buf = ctypes.create_string_buffer(128)
        core_foundation.CFStringGetCString(role_ref.value, buf, 128, kCFStringEncodingUTF8)
        core_foundation.CFRelease(role_ref.value)
        return buf.raw.rstrip(b'\x00') in _TEXT_ROLES
    except Exception:
        return False

async def _check_text_focus(websocket):
    """Wait briefly after a click, then notify the client if focus is on a text field."""
    await asyncio.sleep(0.20)
    # Check Accessibility permission first
    try:
        ax_trusted = core_graphics.AXIsProcessTrusted()
    except Exception:
        ax_trusted = False
    if not ax_trusted:
        print("[AX] Accessibility permission not granted — cannot detect text field focus.")
        return
    role = None
    try:
        sys_elem = core_graphics.AXUIElementCreateSystemWide()
        if sys_elem:
            attr_focused = core_foundation.CFStringCreateWithCString(None, b"AXFocusedUIElement", kCFStringEncodingUTF8)
            focused = ctypes.c_void_p()
            err = core_graphics.AXUIElementCopyAttributeValue(sys_elem, attr_focused, ctypes.byref(focused))
            core_foundation.CFRelease(attr_focused)
            core_foundation.CFRelease(sys_elem)
            if err == 0 and focused.value:
                attr_role = core_foundation.CFStringCreateWithCString(None, b"AXRole", kCFStringEncodingUTF8)
                role_ref = ctypes.c_void_p()
                err2 = core_graphics.AXUIElementCopyAttributeValue(focused.value, attr_role, ctypes.byref(role_ref))
                core_foundation.CFRelease(attr_role)
                core_foundation.CFRelease(focused.value)
                if err2 == 0 and role_ref.value:
                    buf = ctypes.create_string_buffer(128)
                    core_foundation.CFStringGetCString(role_ref.value, buf, 128, kCFStringEncodingUTF8)
                    core_foundation.CFRelease(role_ref.value)
                    role = buf.raw.rstrip(b'\x00')
    except Exception as ex:
        print(f"[AX] Exception during focus check: {ex}")
    print(f"[AX] Focused element role after click: {role}")
    if role in _TEXT_ROLES:
        try:
            await websocket.send(json.dumps({"type": "focus_keyboard"}))
            print("[AX] Sent focus_keyboard to client")
        except Exception as ex:
            print(f"[AX] Failed to send: {ex}")

# ----------------------------------------------------
# Device Actions Wrappers
# ----------------------------------------------------
def get_mouse_position():
    """Retrieve the current coordinates of the cursor."""
    event = core_graphics.CGEventCreate(None)
    if not event:
        return 0.0, 0.0
    pos = core_graphics.CGEventGetLocation(event)
    core_foundation.CFRelease(event)
    return pos.x, pos.y

def post_mouse_event(event_type, x, y, button=kCGMouseButtonLeft, click_count=1):
    """Post a mouse event (move, down, up, drag) with specified click state."""
    x_min, y_min, x_max, y_max = get_virtual_desktop_bounds()
    x = max(float(x_min), min(float(x_max) - 1.0, x))
    y = max(float(y_min), min(float(y_max) - 1.0, y))
    
    source = core_graphics.CGEventSourceCreate(kCGEventSourceStateHIDSystemState)
    pos = CGPoint(x, y)
    event = core_graphics.CGEventCreateMouseEvent(source, event_type, pos, button)
    if event:
        core_graphics.CGEventSetIntegerValueField(event, kCGMouseEventClickState, click_count)
        core_graphics.CGEventPost(kCGHIDEventTap, event)
        core_foundation.CFRelease(event)
    if source:
        core_foundation.CFRelease(source)

_vd_bounds_cache = None
_vd_bounds_cache_time = 0.0

def get_virtual_desktop_bounds():
    """Return (x_min, y_min, x_max, y_max) spanning ALL active displays.
    Result is cached for 5 seconds to avoid repeated CG calls."""
    global _vd_bounds_cache, _vd_bounds_cache_time
    now = time.monotonic()
    if _vd_bounds_cache and now - _vd_bounds_cache_time < 5.0:
        return _vd_bounds_cache

    count = ctypes.c_uint32(0)
    core_graphics.CGGetActiveDisplayList(0, None, ctypes.byref(count))

    if count.value == 0:
        # Fallback: main display only
        main = core_graphics.CGMainDisplayID()
        b = core_graphics.CGDisplayBounds(main)
        _vd_bounds_cache = (0, 0, int(b.size.x), int(b.size.y))
        _vd_bounds_cache_time = now
        return _vd_bounds_cache

    display_ids = (ctypes.c_uint32 * count.value)()
    actual = ctypes.c_uint32(0)
    core_graphics.CGGetActiveDisplayList(count.value, display_ids, ctypes.byref(actual))

    x_min, y_min = float('inf'), float('inf')
    x_max, y_max = float('-inf'), float('-inf')
    for i in range(actual.value):
        b = core_graphics.CGDisplayBounds(display_ids[i])
        x_min = min(x_min, b.origin.x)
        y_min = min(y_min, b.origin.y)
        x_max = max(x_max, b.origin.x + b.size.x)
        y_max = max(y_max, b.origin.y + b.size.y)

    _vd_bounds_cache = (int(x_min), int(y_min), int(x_max), int(y_max))
    _vd_bounds_cache_time = now
    print(f"[Display] Virtual desktop: {_vd_bounds_cache} ({actual.value} display(s))")
    return _vd_bounds_cache

def get_screen_size():
    """Get dimensions of the main Mac display (kept for compatibility)."""
    main_display = core_graphics.CGMainDisplayID()
    bounds = core_graphics.CGDisplayBounds(main_display)
    return int(bounds.size.x), int(bounds.size.y)

scroll_accum_x = 0.0
scroll_accum_y = 0.0

def scroll_mouse(dy, dx=0):
    """Post a vertical and horizontal scroll event on the Mac with accumulation for smooth sub-pixel swiping."""
    global scroll_accum_x, scroll_accum_y
    if dy == 0 and dx == 0:
        return
    
    scroll_accum_x += dx
    scroll_accum_y += dy
    
    int_dx = int(scroll_accum_x)
    int_dy = int(scroll_accum_y)
    
    if int_dx != 0 or int_dy != 0:
        scroll_accum_x -= int_dx
        scroll_accum_y -= int_dy
        
        source = core_graphics.CGEventSourceCreate(kCGEventSourceStateHIDSystemState)
        # Unit 1 is Line Scrolling, wheel count is 2 to specify both vertical and horizontal wheels
        event = core_graphics.CGEventCreateScrollWheelEvent(source, 1, 2, int_dy, int_dx)
        if event:
            core_graphics.CGEventPost(kCGHIDEventTap, event)
            core_foundation.CFRelease(event)
        if source:
            core_foundation.CFRelease(source)

def press_key(keycode):
    """Simulate keypress (down + up) for macOS virtual keycodes."""
    source = core_graphics.CGEventSourceCreate(kCGEventSourceStateHIDSystemState)
    event_down = core_graphics.CGEventCreateKeyboardEvent(source, keycode, True)
    event_up = core_graphics.CGEventCreateKeyboardEvent(source, keycode, False)
    
    if event_down:
        core_graphics.CGEventPost(kCGHIDEventTap, event_down)
        core_foundation.CFRelease(event_down)
    if event_up:
        core_graphics.CGEventPost(kCGHIDEventTap, event_up)
        core_foundation.CFRelease(event_up)
    if source:
        core_foundation.CFRelease(source)

def type_string(text):
    """Simulate typing text using native macOS Unicode injection."""
    source = core_graphics.CGEventSourceCreate(kCGEventSourceStateHIDSystemState)
    for is_down in [True, False]:
        # virtual key 0 is 'a', acts as placeholder since we override unicode string
        event = core_graphics.CGEventCreateKeyboardEvent(source, 0, is_down)
        if event:
            utf16_bytes = text.encode('utf-16-le')
            unichars = (ctypes.c_uint16 * (len(utf16_bytes) // 2)).from_buffer_copy(utf16_bytes)
            core_graphics.CGEventKeyboardSetUnicodeString(event, len(unichars), unichars)
            core_graphics.CGEventPost(kCGHIDEventTap, event)
            core_foundation.CFRelease(event)
    if source:
        core_foundation.CFRelease(source)

# ----------------------------------------------------
# Network & SSL Helpers
# ----------------------------------------------------
def get_local_ip():
    """Retrieve the primary local IP address of this Mac."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        # Dummy connection to look up interface routing table
        s.connect(('8.8.8.8', 80))
        ip = s.getsockname()[0]
    except Exception:
        ip = '127.0.0.1'
    finally:
        s.close()
    return ip

def ensure_ssl_certs():
    """Generate local self-signed SSL certs for HTTPS and WSS."""
    script_dir = os.path.dirname(os.path.abspath(__file__))
    cert_file = os.path.join(script_dir, "cert.pem")
    key_file = os.path.join(script_dir, "key.pem")
    
    if not os.path.exists(cert_file) or not os.path.exists(key_file):
        print("Self-signed SSL certificate not found. Generating...")
        cmd = [
            "openssl", "req", "-x509", "-newkey", "rsa:2048",
            "-keyout", key_file, "-out", cert_file,
            "-sha256", "-days", "365", "-nodes",
            "-subj", "/CN=localhost"
        ]
        try:
            subprocess.run(cmd, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            print("Successfully generated cert.pem and key.pem.")
        except Exception as e:
            print(f"Error generating SSL certificate via openssl: {e}")
            sys.exit(1)
            
    return cert_file, key_file

# ----------------------------------------------------
# Combined HTTPS & WebSocket Static File Server Handler
# ----------------------------------------------------
async def process_request(connection, request):
    """Serve local static Web UI files over the same HTTPS/WebSocket port."""
    # check if upgrade request
    if "Upgrade" in request.headers and request.headers["Upgrade"].lower() == "websocket":
        return None # Let websockets library handle connection upgrade

    script_dir = os.path.dirname(os.path.abspath(__file__))
    web_dir = os.path.join(script_dir, "web")
    
    # Clean up request path query params
    clean_path = request.path.split('?')[0]
    if clean_path == '/':
        clean_path = '/index.html'
        
    file_path = os.path.join(web_dir, clean_path.lstrip('/'))
    
    # Simple directory traversal check
    real_web_dir = os.path.realpath(web_dir)
    real_file_path = os.path.realpath(file_path)
    if not real_file_path.startswith(real_web_dir):
        h = Headers([("Content-Type", "text/plain")])
        return Response(status_code=403, reason_phrase="Forbidden", headers=h, body=b"Forbidden")
        
    if os.path.exists(file_path) and os.path.isfile(file_path):
        # Resolve Content-Type header
        content_type = "text/plain"
        if file_path.endswith('.html'):
            content_type = "text/html"
        elif file_path.endswith('.css'):
            content_type = "text/css"
        elif file_path.endswith('.js'):
            content_type = "text/javascript"
        elif file_path.endswith('.png'):
            content_type = "image/png"
            
        try:
            with open(file_path, 'rb') as f:
                content = f.read()
            h = Headers([
                ("Content-Type", content_type),
                ("Content-Length", str(len(content))),
                ("Connection", "close"),
                ("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0"),
                ("Pragma", "no-cache"),
                ("Expires", "0")
            ])
            return Response(status_code=200, reason_phrase="OK", headers=h, body=content)
        except Exception:
            h = Headers([("Content-Type", "text/plain")])
            return Response(status_code=500, reason_phrase="Internal Server Error", headers=h, body=b"Internal Server Error")
            
    h = Headers([("Content-Type", "text/plain")])
    return Response(status_code=404, reason_phrase="Not Found", headers=h, body=b"Not Found")


# ----------------------------------------------------
# WebSocket Message Handlers
# ----------------------------------------------------
# Track global mouse down state
is_left_down = False
is_right_down = False

async def handle_ws_client(websocket):
    """Process incoming WebSocket packets containing telemetry & inputs."""
    global is_left_down, is_right_down
    
    remote_addr = websocket.remote_address
    addr_str = f"{remote_addr[0]}:{remote_addr[1]}" if remote_addr else "Unknown"
    print(f"\n[WebSocket] Connected client: {addr_str}")
    
    # Gyro smoothing state variables
    smoothed_dx = 0.0
    smoothed_dy = 0.0
    gyro_smoothing_factor = 0.30  # EMA alpha: higher = more responsive, lower = smoother
    
    last_packet_time = 0.0
    cursor_x, cursor_y = get_mouse_position()
    
    # S-curve acceleration for gyro:
    #   0–1.5 → dampen (0.3× at zero, ramp to 1.0×)
    #   1.5–5 → neutral (1.0×)
    #   5+    → gentle expo acceleration
    def gyro_factor(speed):
        if speed < 1.5:
            return 0.3 + (speed / 1.5) * 0.7
        elif speed > 5.0:
            return 1.0 + ((speed - 5.0) ** 1.05) * 0.09
        return 1.0
    
    async for message in websocket:
        try:
            packet = json.loads(message)
            if not isinstance(packet, dict):
                continue
            msg_type = packet.get('type')
            
            # Periodically synchronize cursor coordinate tracking with the OS cursor
            # to handle external physical mouse movement gaps
            now = time.monotonic()
            if now - last_packet_time > 0.10:
                cursor_x, cursor_y = get_mouse_position()
            last_packet_time = now
            
            if msg_type == 'trackpad':
                # Relative trackpad coordinate movements
                dx = packet.get('dx', 0.0)
                dy = packet.get('dy', 0.0)
                
                cursor_x += dx
                cursor_y += dy
                
                # Clip internally to match display bounds
                x_min, y_min, x_max, y_max = get_virtual_desktop_bounds()
                cursor_x = max(float(x_min), min(float(x_max) - 1.0, cursor_x))
                cursor_y = max(float(y_min), min(float(y_max) - 1.0, cursor_y))
                
                # Check if dragging or normal move
                event_type = kCGEventLeftMouseDragged if is_left_down else kCGEventMouseMoved
                post_mouse_event(event_type, cursor_x, cursor_y)
                
            elif msg_type == 'motion':
                # 3D Gyroscope orientation inputs (multiplied by sensitivity multiplier on client)
                rx = packet.get('rx', 0.0) # alpha rotation rate (yaw / Z-axis)
                ry = packet.get('ry', 0.0) # beta (pitch / X-axis)
                rz = packet.get('rz', 0.0) # gamma (roll / Y-axis)
                
                # Stable orientation parameters sent directly by the client browser layout
                is_landscape = packet.get('is_landscape', False)
                sign_x = packet.get('sign_x', 1.0)
                sign_y = packet.get('sign_y', 1.0)
                
                # Revert to the original optimized mappings
                if is_landscape:
                    yaw_rate = rz * sign_x
                    pitch_rate = -rx * sign_x
                else:
                    yaw_rate = -rx
                    pitch_rate = ry * sign_y
                
                raw_dx = yaw_rate
                raw_dy = -pitch_rate
                
                # S-curve pointer acceleration: dampen slow jitter, neutral mid, gently accelerate fast sweeps
                speed = (raw_dx**2 + raw_dy**2) ** 0.5
                if speed > 0:
                    factor = gyro_factor(speed)
                    raw_dx *= factor
                    raw_dy *= factor
                
                # Apply low-pass filter
                smoothed_dx = gyro_smoothing_factor * raw_dx + (1.0 - gyro_smoothing_factor) * smoothed_dx
                smoothed_dy = gyro_smoothing_factor * raw_dy + (1.0 - gyro_smoothing_factor) * smoothed_dy
                
                if abs(smoothed_dx) > 0.05 or abs(smoothed_dy) > 0.05:
                    cursor_x += smoothed_dx
                    cursor_y += smoothed_dy
                    
                    # Clip internally to match display bounds
                    x_min, y_min, x_max, y_max = get_virtual_desktop_bounds()
                    cursor_x = max(float(x_min), min(float(x_max) - 1.0, cursor_x))
                    cursor_y = max(float(y_min), min(float(y_max) - 1.0, cursor_y))
                    
                    event_type = kCGEventLeftMouseDragged if is_left_down else kCGEventMouseMoved
                    post_mouse_event(event_type, cursor_x, cursor_y)
                    
            elif msg_type == 'click':
                # Left/Right mouse clicks
                button = packet.get('button', 'left')
                action = packet.get('action', 'tap')
                cx, cy = get_mouse_position()
                cursor_x, cursor_y = cx, cy
                
                if button == 'left':
                    if action == 'down':
                        is_left_down = True
                        post_mouse_event(kCGEventLeftMouseDown, cx, cy, kCGMouseButtonLeft)
                    elif action == 'up':
                        is_left_down = False
                        post_mouse_event(kCGEventLeftMouseUp, cx, cy, kCGMouseButtonLeft)
                    elif action == 'tap':
                        post_mouse_event(kCGEventLeftMouseDown, cx, cy, kCGMouseButtonLeft)
                        await asyncio.sleep(0.01)
                        post_mouse_event(kCGEventLeftMouseUp, cx, cy, kCGMouseButtonLeft)
                        # Auto-open phone keyboard if click landed on a text field
                        asyncio.create_task(_check_text_focus(websocket))
                    elif action == 'double_tap':
                        post_mouse_event(kCGEventLeftMouseDown, cx, cy, kCGMouseButtonLeft, click_count=2)
                        await asyncio.sleep(0.01)
                        post_mouse_event(kCGEventLeftMouseUp, cx, cy, kCGMouseButtonLeft, click_count=2)
                        
                elif button == 'right':
                    if action == 'down':
                        is_right_down = True
                        post_mouse_event(kCGEventRightMouseDown, cx, cy, kCGMouseButtonRight)
                    elif action == 'up':
                        is_right_down = False
                        post_mouse_event(kCGEventRightMouseUp, cx, cy, kCGMouseButtonRight)
                    elif action == 'tap':
                        post_mouse_event(kCGEventRightMouseDown, cx, cy, kCGMouseButtonRight)
                        await asyncio.sleep(0.01)
                        post_mouse_event(kCGEventRightMouseUp, cx, cy, kCGMouseButtonRight)
                        
            elif msg_type == 'scroll':
                # Vertical and horizontal mouse scrolling
                dy = packet.get('dy', 0.0)
                dx = packet.get('dx', 0.0)
                scroll_mouse(dy, dx)
                
            elif msg_type == 'keyboard':
                # Simulates typing text
                text = packet.get('text', '')
                if text:
                    type_string(text)
                    
            elif msg_type == 'key':
                # Simulates special keystrokes
                code = packet.get('code', '')
                if code in SPECIAL_KEYS:
                    press_key(SPECIAL_KEYS[code])
                    
            elif msg_type == 'switch_desktop':
                # Use osascript / System Events to send Control+Arrow.
                # CGEvent modifier flags are silently dropped by Mission Control when injected
                # from a non-HID source; osascript routes through the AppleScript layer which
                # correctly synthesises the full modifier state.
                direction = packet.get('direction', 'right')
                keycode = 124 if direction == 'right' else 123  # Right=124, Left=123
                print(f"[Desktop] Switching {direction} (Control+{'Right' if direction == 'right' else 'Left'} Arrow)")
                script = f'tell application "System Events" to key code {keycode} using control down'
                result = subprocess.run(['osascript', '-e', script], capture_output=True, text=True)
                if result.returncode != 0 or result.stderr.strip():
                    print(f"[Desktop] osascript FAILED (code {result.returncode}): {result.stderr.strip()!r}")
                    print(f"  → Go to System Settings → Privacy & Security → Automation")
                    print(f"  → Enable 'System Events' for Terminal (or whichever app launched this server)")
                else:
                    print(f"[Desktop] Switch {direction} OK")

            elif msg_type == 'zoom':
                # Toggle / adjust macOS built-in Accessibility Zoom via keyboard shortcuts:
                #   Toggle  : ⌥⌘8  (key code 28)
                #   Zoom In : ⌥⌘0  (key code 29)
                #   Zoom Out: ⌥⌘-  (key code 27)
                # Requires "Use keyboard shortcuts to zoom" enabled in
                # System Settings → Accessibility → Zoom.
                action = packet.get('action', 'toggle')
                zoom_keycodes = {'toggle': 28, 'in': 29, 'out': 27}
                kc = zoom_keycodes.get(action)
                if kc is not None:
                    script = f'tell application "System Events" to key code {kc} using {{command down, option down}}'
                    subprocess.run(['osascript', '-e', script], capture_output=True)

            elif msg_type == 'calibrate':
                # Reset air mouse vectors
                smoothed_dx = 0.0
                smoothed_dy = 0.0
                
        except Exception as e:
            print(f"[WebSocket] Error processing packet: {e}")
            
    remote_addr = websocket.remote_address
    addr_str = f"{remote_addr[0]}:{remote_addr[1]}" if remote_addr else "Unknown"
    print(f"[WebSocket] Client disconnected: {addr_str}")
    # Reset left click state on disconnect for safety
    if is_left_down:
        cx, cy = get_mouse_position()
        post_mouse_event(kCGEventLeftMouseUp, cx, cy, kCGMouseButtonLeft)
        is_left_down = False

# ----------------------------------------------------
# Main Execution Loop
# ----------------------------------------------------
async def main():
    http_port = 8443
    ws_port = 8444
    
    # Process potential arguments for port overriding
    if len(sys.argv) > 1:
        try:
            http_port = int(sys.argv[1])
            ws_port = http_port + 1
        except ValueError:
            pass
            
    # Step 1: Ensure SSL certificates exist
    cert_path, key_path = ensure_ssl_certs()
    
    # Step 2: Configure and launch the combined HTTPS + WebSocket server on a single port
    ssl_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ssl_context.load_cert_chain(certfile=cert_path, keyfile=key_path)
    
    local_hostname = socket.gethostname()
    if not local_hostname.endswith('.local'):
        local_hostname += '.local'
    target_url = f"https://{local_hostname}:{http_port}"
    
    # Step 3: Display Pairing details & QR Code
    print("\n" + "=" * 65)
    print("           MAC REMOTE CONTROLLER SERVER ACTIVE")
    print("=" * 65)
    print(f" HTTPS & WSS Server: {target_url} (Port {http_port})")
    print("-" * 65)
    print(" NOTE: iOS Safari requires HTTPS to access motion sensors.")
    print(" The server uses a self-signed certificate. Upon scanning the QR,")
    print(" choose 'Advanced' -> 'Proceed to Page' in Safari to pair.")
    print("-" * 65)
    
    # Generate and print scannable ASCII QR Code
    print("\nScan this QR code with your iPhone Camera to connect:")
    qr = qrcode.QRCode(version=1, box_size=1, border=1)
    qr.add_data(target_url)
    qr.make(fit=True)
    # invert=True fits dark backgrounds by mapping black dots to terminal white blocks
    qr.print_ascii(invert=True)
    
    print("\nLogs:")
    print("  Listening for connections...")
    print("  If inputs do not trigger on your Mac, please verify Terminal")
    print("  has Accessibility access enabled in Settings -> Privacy & Security.")
    print("=" * 65 + "\n")
    
    async with websockets.serve(
        handle_ws_client, '::', http_port,
        ssl=ssl_context, process_request=process_request
    ):
        await asyncio.Future() # Keep loop running forever

if __name__ == "__main__":
    import time as _time
    while True:
        try:
            asyncio.run(main())
        except KeyboardInterrupt:
            print("\nStopping Mac Remote Controller Server. Goodbye.")
            sys.exit(0)
        except Exception as _e:
            print(f"\n[Server] Crashed with: {_e}. Restarting in 3s...")
            _time.sleep(3)
