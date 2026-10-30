#!/usr/bin/python3
"""Send gamescope_control.display_sleep over the gamescope Wayland socket.

This is exactly what Steam does when it decides the panel should sleep, so it is
the honest way to test whether the Anland backend now honours the request.
"""

import socket
import struct
import sys

# Wayland wire format helpers.
WL_DISPLAY_ID = 1
WL_REGISTRY_ID = 2


class Wayland:
    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(10)
        self.sock.connect(path)
        self.next_id = 3
        self.globals = {}

    @staticmethod
    def message(object_id, opcode, payload=b""):
        # Wayland header: object id (u32), then opcode (u16) and total size (u16)
        # in one little-endian word, so they go low-half first.
        total = 8 + len(payload)
        return struct.pack("<IHH", object_id, opcode, total) + payload

    @staticmethod
    def string(value):
        raw = value.encode() + b"\0"
        pad = (4 - len(raw) % 4) % 4
        return struct.pack("<I", len(raw)) + raw + b"\0" * pad

    def send(self, data):
        self.sock.sendall(data)

    def recv_exact(self, count):
        buf = b""
        while len(buf) < count:
            chunk = self.sock.recv(count - len(buf))
            if not chunk:
                raise EOFError("gamescope closed the connection")
            buf += chunk
        return buf

    def recv_message(self):
        header = self.recv_exact(8)
        object_id, opcode, size = struct.unpack("<IHH", header)
        if size < 8 or size > 65536:
            raise ValueError(f"bad message size {size}")
        payload = self.recv_exact(size - 8) if size > 8 else b""
        return object_id, opcode, payload

    def get_registry(self):
        # wl_display.get_registry(new_id)
        self.send(self.message(WL_DISPLAY_ID, 1, struct.pack("<I", WL_REGISTRY_ID)))
        # wl_display.sync(new_id) -- the done event for this callback id marks
        # the point where every global has been delivered.
        sync_id = self.next_id
        self.next_id += 1
        self.send(self.message(WL_DISPLAY_ID, 0, struct.pack("<I", sync_id)))
        while True:
            object_id, opcode, payload = self.recv_message()
            if object_id == WL_REGISTRY_ID and opcode == 0:
                name, iface_len = struct.unpack("<II", payload[0:8])
                self.globals[name] = payload[8:8 + iface_len - 1].decode()
                continue
            if object_id == sync_id and opcode == 0:
                return


def main(argv):
    if len(argv) != 3:
        print("usage: anland-sleep-test.py <wayland-socket> <sleep|wake>", file=sys.stderr)
        return 2

    path, action = argv[1], argv[2]
    wl = Wayland(path)
    wl.get_registry()

    control_names = [name for name, iface in wl.globals.items()
                     if iface == "gamescope_control"]
    print("globals:", {k: v for k, v in wl.globals.items() if "gamescope" in v})
    if not control_names:
        print("gamescope_control not advertised", file=sys.stderr)
        return 1

    # bind(id, interface, version, new_id). Version 4 introduced display_sleep.
    control_id = wl.next_id
    wl.next_id += 1
    version = min(4, 7)
    payload = (struct.pack("<I", control_names[0]) + wl.string("gamescope_control")
               + struct.pack("<II", version, control_id))
    wl.send(wl.message(WL_REGISTRY_ID, 0, payload))

    # display_sleep is request #3 in gamescope-control.xml (after destroy,
    # set_app_target_refresh_cycle, take_screenshot), verified against the
    # generated gamescope_control_requests[] table.
    # Args: display_type_flags (internal=0x1), flags (sleep=0x1, wake=0x2).
    DISPLAY_SLEEP_OPCODE = 3
    display_type = 0x1
    flags = 0x1 if action == "sleep" else 0x2
    wl.send(wl.message(control_id, DISPLAY_SLEEP_OPCODE,
                       struct.pack("<II", display_type, flags)))
    print(f"sent display_sleep({action}) flags={flags:#x}")

    # Drain whatever comes back so the request is definitely flushed.
    try:
        while True:
            wl.recv_message()
    except (socket.timeout, EOFError):
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))